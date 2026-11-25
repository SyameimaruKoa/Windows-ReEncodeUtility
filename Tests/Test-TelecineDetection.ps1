<#
.SYNOPSIS
    3:2プルダウン／逆テレシネ判定の回帰テスト。

.DESCRIPTION
    FFmpegで合成サンプルを生成し、共通モジュールの判定が期待どおりか検証する。
    ノイズ付きハードテレシネと、アニメの静止を多く含むプログレッシブ3:2を重点的に確認する。
    -RealSample を指定すると実映像でも検証する。

.PARAMETER RealSample
    任意で指定する実映像のパス。プログレッシブ3:2の検出を期待する。

.PARAMETER FFmpeg
    ffmpeg のパス。省略時は PATH から取得する。

.PARAMETER FFprobe
    ffprobe のパス。省略時は PATH から取得する。

.PARAMETER Help
    詳細な使い方を表示する。-h も使用できる。

.EXAMPLE
    pwsh -NoProfile -File ./Tests/Test-TelecineDetection.ps1

.EXAMPLE
    pwsh -NoProfile -File ./Tests/Test-TelecineDetection.ps1 -RealSample './input.mp4'
#>

param(
    [string]$RealSample,
    [string]$FFmpeg,
    [string]$FFprobe,
    [Alias('h')]
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    return
}

#region 準備

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$modulePath = Join-Path $projectRoot 'Modules/TelecineDetector.ps1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    Write-Error "判定モジュールが見つからんかった: $modulePath"
    exit 1
}
. $modulePath

if (-not $FFmpeg) { $FFmpeg = (Get-Command ffmpeg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Path }
if (-not $FFprobe) { $FFprobe = (Get-Command ffprobe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Path }
if (-not $FFmpeg -or -not $FFprobe) {
    Write-Error 'ffmpeg / ffprobe が見つからんかったぞ。'
    exit 1
}

$tempDir = Join-Path $projectRoot '.cache/tmp/telecine-tests'
if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $tempDir -Force
}

$script:Failed = 0
$script:Passed = 0

function New-TestClip {
    param([string]$Name, [string[]]$Arguments, [int]$Crf = 18)
    $path = Join-Path $tempDir "$Name.mkv"
    $fullArgs = @('-y', '-loglevel', 'error') + $Arguments + @('-c:v', 'libx264', '-crf', [string]$Crf, '-pix_fmt', 'yuv420p', $path)
    & $FFmpeg @fullArgs 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Error "サンプル生成に失敗した: $Name"
        exit 1
    }
    return $path
}

function Assert-Case {
    param([string]$Name, [object]$Assessment, [string]$Field, [bool]$Expected)

    $actual = [bool]$Assessment.$Field
    if ($actual -eq $Expected) {
        Write-Host "  PASS  $Name : $Field=$actual" -ForegroundColor Green
        $script:Passed++
    }
    else {
        Write-Host "  FAIL  $Name : $Field=$actual (期待=$Expected) / $($Assessment.Verdict)" -ForegroundColor Red
        $script:Failed++
    }
}

#endregion

#region サンプル生成

$baseFilter = 'testsrc2=size=320x240:rate=24:duration=18,gblur=sigma=6'
$src24 = New-TestClip -Name 'src24' -Arguments @('-f', 'lavfi', '-i', $baseFilter)
$hardtc = New-TestClip -Name 'hardtc' -Arguments @('-i', $src24, '-vf', 'telecine=pattern=23')
$hardtcBff = New-TestClip -Name 'hardtc_bff' -Arguments @('-i', $src24, '-vf', 'telecine=pattern=23:first_field=bottom')
$hardtcNoisy = New-TestClip -Name 'hardtc_noisy' -Arguments @('-i', $hardtc, '-vf', 'noise=alls=10:allf=t+u') -Crf 24
$dup30 = New-TestClip -Name 'dup30' -Arguments @('-i', $src24, '-vf', 'fps=30')
$animeDup30 = New-TestClip -Name 'anime_dup30' -Arguments @('-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=12:duration=18,gblur=sigma=6,fps=24,fps=30')
$native30 = New-TestClip -Name 'native30' -Arguments @('-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=30:duration=18,gblur=sigma=6')

#endregion

#region 判定の検証

function Check-File {
    param([string]$Name, [string]$Path, [hashtable]$Expectations)

    $assessment = Get-TelecineAssessment -File $Path -FFmpegExecutable $FFmpeg -FFprobeExecutable $FFprobe -Frames 180 -Full $false
    Write-Host "[$Name] $($assessment.Verdict) (確信度 $($assessment.Confidence)%)" -ForegroundColor Cyan
    foreach ($key in $Expectations.Keys) {
        Assert-Case -Name $Name -Assessment $assessment -Field $key -Expected $Expectations[$key]
    }
}

Check-File -Name '24pプログレッシブ' -Path $src24 -Expectations @{ Telecine32 = $false; Progressive32 = $false }
Check-File -Name 'ハードテレシネ(TFF)' -Path $hardtc -Expectations @{ Telecine32 = $true; IsInterlaced = $true }
Check-File -Name 'ハードテレシネ(BFF)' -Path $hardtcBff -Expectations @{ Telecine32 = $true; IsInterlaced = $true }
Check-File -Name 'ノイズ付きハードテレシネ' -Path $hardtcNoisy -Expectations @{ Telecine32 = $true; IsInterlaced = $true }
Check-File -Name '24→30pフレーム重複' -Path $dup30 -Expectations @{ Progressive32 = $true; Telecine32 = $false }
Check-File -Name 'アニメ風静止を含む3:2' -Path $animeDup30 -Expectations @{ Progressive32 = $true; Telecine32 = $false }
Check-File -Name '30pネイティブ' -Path $native30 -Expectations @{ Progressive32 = $false; Telecine32 = $false }

if ($RealSample) {
    if (-not (Test-Path -LiteralPath $RealSample -PathType Leaf)) {
        Write-Error "実サンプルが見つからんかった: $RealSample"
        exit 1
    }
    Check-File -Name '実サンプル' -Path $RealSample -Expectations @{ Progressive32 = $true }
}

#endregion

Write-Host ''
Write-Host "結果: PASS=$($script:Passed) / FAIL=$($script:Failed)" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
