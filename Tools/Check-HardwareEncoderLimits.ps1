<#
.SYNOPSIS
    利用可能なハードウェア／ソフトウェア映像エンコーダーの実能力（制限）を自動プローブする。
.DESCRIPTION
    短い合成映像を使い、以下を実測して .cache/hardware-limits.json に保存する。
      - 利用可否 (256x256 でのエンコード成否)
      - サポートされる品質指定オプション (-global_quality / -q:v / -b:v / -crf / -rc 等)
      - サポートされるピクセル形式
      - エンコード可能な最大解像度 (幅 / 高さ)
      - HWデコード (hwaccel + output_format) からエンコーダーへの相互接続可否
    すべての一時ファイルは git 対象外の .cache 配下に作り、プロジェクト外には触れない。
.PARAMETER Force
    既存のハードウェアスキャンキャッシュを使わず再スキャンする。
.PARAMETER Quick
    解像度・ピクセル形式のプローブを省略し、利用可否と品質オプションのみ確認する。
#>
#requires -Version 7.0

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Quick
)

$ErrorActionPreference = 'Continue'
$scriptDir = $PSScriptRoot
$rootDir = Split-Path -Parent $scriptDir
$global:ScriptDir = $rootDir
$global:Settings = Import-PowerShellDataFile -Path (Join-Path $rootDir 'config.user.psd1')
$global:AppCacheDir = Join-Path $rootDir '.cache'
$global:AppTempDir = Join-Path $global:AppCacheDir 'tmp'
foreach ($dir in @($global:AppCacheDir, $global:AppTempDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
}

# --- ハードウェアスキャン（キャッシュ利用可） ---
if ($Force) {
    . (Join-Path $rootDir 'Get-HardwareInfo.ps1') -ForceScan | Out-Null
}
else {
    . (Join-Path $rootDir 'Get-HardwareInfo.ps1') | Out-Null
}
# Get-HardwareInfo.ps1 は AppTempDir も設定するが、念のため再設定する
$global:AppTempDir = Join-Path $global:AppCacheDir 'tmp'
$null = New-Item -ItemType Directory -Path $global:AppTempDir -Force
$ffmpeg = $global:Settings.FfmpegPath
$ffprobe = $global:Settings.FfprobePath

function Invoke-LimitProbe {
    param([string[]]$Arguments)
    try {
        $output = (& $ffmpeg @Arguments 2>&1 | Out-String)
        $code = $LASTEXITCODE
        $firstError = ''
        if ($code -ne 0) {
            $firstError = (($output -split "`r?`n") | Where-Object {
                    $_ -match '(?i)(error|invalid|unsupported|not found|failed|not supported)'
                } | Select-Object -First 1)
            if (-not $firstError) { $firstError = ($output -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1) }
        }
        return [pscustomobject]@{ Success = ($code -eq 0); Error = ([string]$firstError).Trim() }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Error = $_.Exception.Message }
    }
}

function Get-VersionSignature {
    try { return ((& $ffmpeg -version 2>&1 | Select-Object -First 1).ToString()) }
    catch { return 'unknown' }
}

# --- プローブ対象エンコーダーの列挙 ---
$encoderSet = @()
if ($global:HardwareInfo -and $global:HardwareInfo.AvailableEncoders) {
    $encoderSet = @($global:HardwareInfo.AvailableEncoders | Where-Object { $_ -match '^(?:h264|hevc|av1|vp9|vp8|mjpeg|mpeg2|mpeg2video)_(?:nvenc|qsv|amf|vulkan|d3d12va|mf)$' })
}
if ($encoderSet.Count -eq 0) {
    # スキャン結果が無い場合は ffmpeg -encoders の全候補を対象にする
    $lines = @(& $ffmpeg -hide_banner -encoders 2>&1)
    foreach ($line in $lines) {
        if ($line -match '^\s*V[.\w]+\s+((?:h264|hevc|av1|vp9|vp8|mjpeg|mpeg2|mpeg2video)_(?:nvenc|qsv|amf|vulkan|d3d12va|mf))\s+') {
            $encoderSet += $Matches[1]
        }
    }
}
$encoderSet = @($encoderSet | Sort-Object -Unique)

$qualityCandidates = @(
    @{ Name = 'global_quality'; Args = @('-global_quality', '25') },
    @{ Name = 'q:v'; Args = @('-q:v', '25') },
    @{ Name = 'b:v'; Args = @('-b:v', '3000k') },
    @{ Name = 'crf'; Args = @('-crf', '25') },
    @{ Name = 'rc=vbr+cq'; Args = @('-rc', 'vbr', '-cq', '25') },
    @{ Name = 'rc=cqp'; Args = @('-rc', 'cqp', '-qp_i', '25', '-qp_p', '25', '-qp_b', '25') },
    @{ Name = 'qp'; Args = @('-qp', '25') }
)
$pixelFormats = @('yuv420p', 'nv12', 'yuv420p10le', 'p010le', 'yuv444p')
$resolutions = @(
    @{ W = 3840; H = 2160 }, @{ W = 2560; H = 1440 }, @{ W = 2560; H = 720 },
    @{ W = 2048; H = 1080 }, @{ W = 1920; H = 1080 }, @{ W = 1280; H = 720 }, @{ W = 640; H = 360 }
)

$results = [ordered]@{}
$probeCount = 0

foreach ($enc in $encoderSet) {
    Write-Host "`n=== $enc ===" -ForegroundColor Cyan
    $entry = [ordered]@{
        Encoder              = $enc
        Available            = $false
        QualityOptions       = @()
        PixelFormats         = @()
        MaxWidth             = 0
        MaxHeight            = 0
        WorkingResolutions   = @()
        HwDecodePaths        = @()
        Notes                = @()
    }

    # 1. 基本利用可否
    $baseArgs = @('-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'color=c=black:s=256x256:r=25:d=0.4',
        '-frames:v', '2', '-an', '-c:v', $enc, '-b:v', '2000k', '-f', 'null', 'NUL')
    $base = Invoke-LimitProbe -Arguments $baseArgs
    $probeCount++
    $entry.Available = $base.Success
    if (-not $base.Success) {
        $entry.Notes += "基本エンコード失敗: $($base.Error)"
        $results[$enc] = $entry
        Write-Host "  利用不可: $($base.Error)" -ForegroundColor Red
        continue
    }
    Write-Host "  利用可" -ForegroundColor Green

    # 2. 品質指定オプション
    foreach ($q in $qualityCandidates) {
        $a = @('-hide_banner', '-loglevel', 'error', '-y',
            '-f', 'lavfi', '-i', 'color=c=black:s=256x256:r=25:d=0.4',
            '-frames:v', '2', '-an', '-c:v', $enc) + $q.Args + @('-f', 'null', 'NUL')
        $r = Invoke-LimitProbe -Arguments $a
        $probeCount++
        if ($r.Success) { $entry.QualityOptions += $q.Name }
    }
    Write-Host "  品質オプション: [$($entry.QualityOptions -join ', ')]"

    if (-not $Quick) {
        # 3. ピクセル形式
        foreach ($pf in $pixelFormats) {
            $a = @('-hide_banner', '-loglevel', 'error', '-y',
                '-f', 'lavfi', '-i', 'color=c=black:s=256x256:r=25:d=0.4',
                '-frames:v', '2', '-an', '-vf', "format=$pf", '-pix_fmt', $pf,
                '-c:v', $enc, '-b:v', '2000k', '-f', 'null', 'NUL')
            $r = Invoke-LimitProbe -Arguments $a
            $probeCount++
            if ($r.Success) { $entry.PixelFormats += $pf }
        }
        Write-Host "  ピクセル形式: [$($entry.PixelFormats -join ', ')]"

        # 4. 最大解像度（大きなものから順に、初めて成功したものを采用）
        foreach ($res in $resolutions) {
            $a = @('-hide_banner', '-loglevel', 'error', '-y',
                '-f', 'lavfi', '-i', "color=c=black:s=$($res.W)x$($res.H):r=25:d=0.2",
                '-frames:v', '2', '-an', '-c:v', $enc, '-b:v', '3000k', '-f', 'null', 'NUL')
            $r = Invoke-LimitProbe -Arguments $a
            $probeCount++
            if ($r.Success) {
                $entry.WorkingResolutions += "$($res.W)x$($res.H)"
                if ($entry.MaxWidth -lt $res.W) { $entry.MaxWidth = $res.W }
                if ($entry.MaxHeight -lt $res.H) { $entry.MaxHeight = $res.H }
                break
            }
            else {
                $entry.Notes += "$($res.W)x$($res.H) 失敗: $($r.Error)"
            }
        }
        Write-Host "  最大成功解像度: $($entry.MaxWidth)x$($entry.MaxHeight)"

        # 5. HWデコード → エンコードの相互接続
        $probeInput = Join-Path $global:AppTempDir "limit-probe-$([System.IO.Path]::GetRandomFileName()).mkv"
        $null = & $ffmpeg -hide_banner -loglevel error -y `
            -f lavfi -i 'color=c=blue:s=320x180:r=25:d=0.4' `
            -c:v libx264 -preset ultrafast -pix_fmt yuv420p $probeInput 2>&1
        if (Test-Path -LiteralPath $probeInput) {
            $accels = @($global:HardwareInfo.AvailableHwAccels)
            foreach ($accel in $accels) {
                $of = switch ($accel) { 'qsv' { 'qsv' } 'd3d11va' { 'd3d11' } 'dxva2' { 'dxva2' } 'vulkan' { 'vulkan' } default { '' } }
                $a = @('-hide_banner', '-loglevel', 'error', '-y', '-hwaccel', $accel)
                if ($of) { $a += @('-hwaccel_output_format', $of) }
                $a += @('-i', $probeInput, '-frames:v', '2', '-an', '-vf', 'hwdownload,format=nv12,scale=320:180',
                    '-c:v', $enc, '-b:v', '2000k', '-f', 'null', 'NUL')
                $r = Invoke-LimitProbe -Arguments $a
                $probeCount++
                $entry.HwDecodePaths += [pscustomobject]@{
                    Accel        = $accel
                    OutputFormat = $of
                    Success      = $r.Success
                    Error        = if ($r.Success) { '' } else { $r.Error }
                }
            }
            Remove-Item -LiteralPath $probeInput -Force -ErrorAction SilentlyContinue
        }
    }

    $results[$enc] = $entry
}

# --- 結果を保存 ---
$report = [ordered]@{
    GeneratedAt     = (Get-Date).ToString('o')
    MachineName     = $env:COMPUTERNAME
    FfmpegSignature = Get-VersionSignature
    QuickMode       = [bool]$Quick
    ProbeCount      = $probeCount
    Encoders        = $results
}
$jsonPath = Join-Path $global:AppCacheDir 'hardware-limits.json'
try {
    $report | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $jsonPath -Encoding utf8 -Force
    Write-Host "`n結果を保存しました: $jsonPath" -ForegroundColor Green
}
catch {
    Write-Host "`n結果の保存に失敗しました: $_" -ForegroundColor Red
}

Write-Host "`n===== サマリー (プローブ数: $probeCount) ====="
Write-Host ("{0,-16} {1,-6} {2,-10} {3,-12} {4}" -f 'Encoder', 'Use', 'MaxRes', 'Quality', 'PixelFormats')
foreach ($key in $results.Keys) {
    $e = $results[$key]
    Write-Host ("{0,-16} {1,-6} {2,-10} {3,-12} {4}" -f $e.Encoder, $(if ($e.Available) { 'YES' } else { 'NO' }),
        "$($e.MaxWidth)x$($e.MaxHeight)", $e.QualityOptions.Count, $e.PixelFormats.Count)
}
