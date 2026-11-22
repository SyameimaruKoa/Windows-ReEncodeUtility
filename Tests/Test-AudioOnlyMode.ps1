<#
.SYNOPSIS
    音声のみエンコードモードの ffmpeg 引数構築を検証する。
.DESCRIPTION
    全トラック／一部トラック、全てエンコード／一部エンコード＋残りパススルー／全てパススルー、
    および映像ストリームが無い場合の分岐を、対話なしで静的に検証する。
#>
#requires -Version 5.1
[CmdletBinding()]
param()
if (-not (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue)) {
    $global:IsWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    $global:IsLinux = -not $global:IsWindows
    $global:IsMacOS = $false
}

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Get-FunctionFromAst {
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "構文エラー: $Path / $($errors[0].Message)" }
    $fn = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true) | Select-Object -First 1
    if (-not $fn) { throw "関数が見つからない: $Name" }
    return $fn.Extent.Text
}

. ([scriptblock]::Create((Get-FunctionFromAst -Path (Join-Path $root 're-encode-AIOptimus.ps1') -Name 'New-AudioOnlyFfmpegArguments')))
. ([scriptblock]::Create((Get-FunctionFromAst -Path (Join-Path $root 're-encode-AIOptimus.ps1') -Name 'Read-Mp4Box')))
. ([scriptblock]::Create((Get-FunctionFromAst -Path (Join-Path $root 're-encode-AIOptimus.ps1') -Name 'Get-Mp4TrackTitles')))
. ([scriptblock]::Create((Get-FunctionFromAst -Path (Join-Path $root 're-encode-AIOptimus.ps1') -Name 'Get-AudioOnlyTrackList')))
. ([scriptblock]::Create((Get-FunctionFromAst -Path (Join-Path $root 're-encode-AIOptimus.ps1') -Name 'Format-AudioOnlyTrackLabel')))

$global:Settings = @{ FfprobePath = 'ffprobe'; FfmpegPath = 'ffmpeg' }

$script:Pass = 0; $script:Fail = 0
function Assert-Contains {
    param([string]$Text, [string]$Expected, [string]$Name)
    if ($Text.Contains($Expected)) { $script:Pass++; Write-Host "  PASS: $Name" }
    else { $script:Fail++; Write-Host "  FAIL: $Name (期待: $Expected / 実際: $Text)" -ForegroundColor Red }
}
function Assert-NotContains {
    param([string]$Text, [string]$Unexpected, [string]$Name)
    if (-not $Text.Contains($Unexpected)) { $script:Pass++; Write-Host "  PASS: $Name" }
    else { $script:Fail++; Write-Host "  FAIL: $Name (不要: $Unexpected / 実際: $Text)" -ForegroundColor Red }
}

$encoder = @{ Key = 'aac'; Args = @('-c:a', 'aac', '-b:a', '192k'); Description = 'AAC 192k' }
$inputPath = 'C:\in\test.mp4'
$outputPath = 'C:\in\test_audio.mkv'

# 1. 全トラックを使用し、全てエンコード
$audioSettings = @{ SelectedTracks = @(0, 1); EncodeTracks = @(0, 1); Mode = 'all'; Encoder = $encoder; HasVideo = $true }
$args1 = New-AudioOnlyFfmpegArguments -InputPath $inputPath -OutputPath $outputPath -Settings $audioSettings
Assert-Contains $args1 '-map 0:v:0 -c:v copy' '映像は再エンコードせずコピー'
Assert-Contains $args1 '-map 0:a:0 -c:a aac -b:a 192k -map 0:a:1 -c:a aac -b:a 192k' '全トラックをエンコード'

# 2. 一部トラックを使用し、片方だけエンコード、残りはパススルー
$audioSettings = @{ SelectedTracks = @(0, 2); EncodeTracks = @(0); Mode = 'partial'; Encoder = $encoder; HasVideo = $true }
$args2 = New-AudioOnlyFfmpegArguments -InputPath $inputPath -OutputPath $outputPath -Settings $audioSettings
Assert-Contains $args2 '-map 0:a:0 -c:a aac -b:a 192k -map 0:a:2 -c:a copy' '一部エンコード＋残りパススルー'
Assert-NotContains $args2 '0:a:1' '未選択トラックは map しない'

# 3. 全トラックをパススルー
$audioSettings = @{ SelectedTracks = @(0, 1); EncodeTracks = @(); Mode = 'copy'; Encoder = $null; HasVideo = $true }
$args3 = New-AudioOnlyFfmpegArguments -InputPath $inputPath -OutputPath $outputPath -Settings $audioSettings
Assert-Contains $args3 '-map 0:a:0 -c:a copy -map 0:a:1 -c:a copy' '全てパススルー'

# 4. 映像ストリームが無い場合
$audioSettings = @{ SelectedTracks = @(0); EncodeTracks = @(0); Mode = 'all'; Encoder = $encoder; HasVideo = $false }
$args4 = New-AudioOnlyFfmpegArguments -InputPath $inputPath -OutputPath $outputPath -Settings $audioSettings
Assert-NotContains $args4 '0:v:0' '映像なしでは映像 map を出力しない'
Assert-Contains $args4 '-map 0:a:0 -c:a aac -b:a 192k' '映像なしでも音声はエンコード'

# 5. ffprobe がトラック名を返さない MP4 でもボックスを直接読んでタイトルを補完する
$tmpDir = Join-Path $root '.cache/tmp'
if (-not (Test-Path -LiteralPath $tmpDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $tmpDir -Force }
$titleTestMp4 = Join-Path $tmpDir 'audio-title-test.mp4'
$null = & ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc=duration=1:size=320x240:rate=30' -f lavfi -i 'sine=frequency=440:duration=1' -map 0:v -map 1:a -c:v libx264 -preset ultrafast -c:a aac -metadata:s:a:0 'title=Test Audio Title' -y $titleTestMp4 2>$null
$titleTracks = @(Get-AudioOnlyTrackList -FilePath $titleTestMp4)
if ($titleTracks.Count -gt 0) {
    Assert-Contains $titleTracks[0].Title 'Test Audio Title' 'MP4のnameボックスから音声トラック名を取得'
    Assert-Contains (Format-AudioOnlyTrackLabel -Track $titleTracks[0]) 'Test Audio Title' '一覧ラベルにタイトルを表示'
}

Write-Host ""
Write-Host "結果: PASS=$($script:Pass) FAIL=$($script:Fail)"
if ($script:Fail -gt 0) { exit 1 }
