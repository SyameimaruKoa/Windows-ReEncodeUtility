<#
.SYNOPSIS
    FFmpegを用いたハードウェア（エンコーダー・デコーダー）の実対応スキャンを行うスクリプトじゃ。
.DESCRIPTION
    キャッシュを使用して不要な再スキャンを防ぎつつ、利用可能なHWエンコーダーのリストを $global:HardwareInfo に格納する。
    他のスクリプトからドットソースで読み込まれることを想定しておるぞ。
#>
[CmdletBinding()]
param(
    [switch]$ForceScan
)

#region ヘルプ表示
if ($args -contains "-h" -or $args -contains "--help") {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    exit
}
#endregion

# スクリプトディレクトリの確実な取得
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptDir)) {
    if ($MyInvocation.MyCommand.Path) {
        $scriptDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
    }
    else {
        $scriptDir = Get-Location
    }
}

$global:AppCacheDir = Join-Path $scriptDir '.cache'
if (-not (Test-Path -LiteralPath $global:AppCacheDir -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $global:AppCacheDir -Force
}

function Write-LogFallback {
    param([string]$Message, [string]$Level = "INFO")
    if (Get-Command "Write-Log" -ErrorAction SilentlyContinue) {
        Write-Log -Message $Message -Level $Level
    }
    else {
        $color = switch ($Level) { "ERROR" { "Red" }; "WARN" { "Yellow" }; "DEBUG" { "DarkGray" }; default { "White" } }
        Write-Host "[$Level] $Message" -ForegroundColor $color
    }
}

$ffmpegPath = "ffmpeg"
if ($global:Settings -and $global:Settings.FfmpegPath) {
    $ffmpegPath = $global:Settings.FfmpegPath
}

function Get-FfmpegSignature {
    param([string]$FfPath)
    $resolvedPath = $FfPath
    try {
        $command = Get-Command -Name $FfPath -ErrorAction Stop
        if ($command.Source) { $resolvedPath = $command.Source }
        elseif ($command.Path) { $resolvedPath = $command.Path }
    }
    catch {}

    $versionLine = ''
    try {
        $versionLine = (& $FfPath -version 2>&1 | Select-Object -First 1).ToString()
    }
    catch {}

    return "$resolvedPath|$versionLine"
}

function Get-HardwareCachePath {
    return (Join-Path $global:AppCacheDir 'hardware-scan-cache.clixml')
}

function Load-HardwareCache {
    $cachePath = Get-HardwareCachePath
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { return $null }
    try { $cached = Import-Clixml -Path $cachePath } catch { return $null }

    if (-not $cached -or $cached.SchemaVersion -ne 2) { return $null }
    if ($cached.MachineName -ne $env:COMPUTERNAME) { return $null }
    if ($cached.FfmpegSignature -ne (Get-FfmpegSignature -FfPath $ffmpegPath)) { return $null }
    if (-not $cached.ScanCompleted) { return $null }
    return $cached
}

function Save-HardwareCache {
    param([object]$HardwareInfo)
    $cachePath = Get-HardwareCachePath
    $cacheObject = [pscustomobject]@{
        SchemaVersion     = 2
        MachineName       = $env:COMPUTERNAME
        SavedAt           = Get-Date
        FfmpegSignature   = Get-FfmpegSignature -FfPath $ffmpegPath
        AvailableEncoders = @($HardwareInfo.AvailableEncoders)
        AvailableHwAccels = @($HardwareInfo.AvailableHwAccels)
        HasNvidia         = [bool]$HardwareInfo.HasNvidia
        HasIntel          = [bool]$HardwareInfo.HasIntel
        HasAMD            = [bool]$HardwareInfo.HasAMD
        HasVulkan         = [bool]$HardwareInfo.HasVulkan
        HasD3D12VA        = [bool]$HardwareInfo.HasD3D12VA
        HasMF             = [bool]$HardwareInfo.HasMF
        ScanCompleted     = [bool]$HardwareInfo.ScanCompleted
    }
    try {
        $cacheObject | Export-Clixml -Path $cachePath -Force
        return $true
    }
    catch {
        Write-LogFallback "ハードウェアスキャン結果のキャッシュ保存に失敗しました: $_" -Level "WARN"
        return $false
    }
}

# 強制スキャンでなければ、既存のメモリキャッシュやファイルキャッシュを利用する
if (-not $ForceScan.IsPresent) {
    if ($global:HardwareInfo) { return $global:HardwareInfo }
    $cachedInfo = Load-HardwareCache
    if ($cachedInfo) {
        $global:HardwareInfo = $cachedInfo
        Write-LogFallback "ハードウェアスキャン結果をキャッシュから読み込みました。" -Level "DEBUG"
        return $global:HardwareInfo
    }
}

$info = @{
    AvailableEncoders = @()
    AvailableHwAccels = @()
    HasNvidia         = $false
    HasIntel          = $false
    HasAMD            = $false
    HasVulkan         = $false
    HasD3D12VA        = $false
    HasMF             = $false
    ScanCompleted     = $false
}

try {
    $encodersList = & $ffmpegPath -hide_banner -encoders 2>&1 | Out-String
    $videoEncoders = @(); $audioEncoders = @()
    
    $regex = [regex] '(?m)^\s*([VA])[.\w]+\s+(\w+_(nvenc|qsv|amf|vulkan|mf|d3d12va))\s+'
    $matches = $regex.Matches($encodersList)
    
    foreach ($match in $matches) {
        $type = $match.Groups[1].Value
        $encName = $match.Groups[2].Value
        if ($type -eq 'V') { if ($videoEncoders -notcontains $encName) { $videoEncoders += $encName } }
        elseif ($type -eq 'A') { if ($audioEncoders -notcontains $encName) { $audioEncoders += $encName } }
    }

    foreach ($enc in $videoEncoders) {
        try {
            $null = & $ffmpegPath -hide_banner -f lavfi -i 'color=c=black:s=256x256:d=0.5:r=25' -frames:v 1 -c:v $enc -f null NUL 2>&1
            if ($LASTEXITCODE -eq 0) {
                $info.AvailableEncoders += $enc
            }
            else {
                $null = & $ffmpegPath -hide_banner -f lavfi -i 'color=c=black:s=256x256:d=0.5:r=25' -frames:v 1 -pix_fmt yuv420p -c:v $enc -f null NUL 2>&1
                if ($LASTEXITCODE -eq 0) { $info.AvailableEncoders += $enc }
            }
        }
        catch {}
    }
    
    foreach ($enc in $audioEncoders) {
        try {
            $null = & $ffmpegPath -hide_banner -f lavfi -i 'anoisesrc=d=0.5:c=2:r=48000' -c:a $enc -f null NUL 2>&1
            if ($LASTEXITCODE -eq 0) { $info.AvailableEncoders += $enc }
        }
        catch {}
    }

    $info.HasNvidia = @($info.AvailableEncoders | Where-Object { $_ -match '_nvenc$' }).Count -gt 0
    $info.HasIntel = @($info.AvailableEncoders | Where-Object { $_ -match '_qsv$' }).Count -gt 0
    $info.HasAMD = @($info.AvailableEncoders | Where-Object { $_ -match '_amf$' }).Count -gt 0
    $info.HasVulkan = @($info.AvailableEncoders | Where-Object { $_ -match '_vulkan$' }).Count -gt 0
    $info.HasD3D12VA = @($info.AvailableEncoders | Where-Object { $_ -match '_d3d12va$' }).Count -gt 0
    $info.HasMF = @($info.AvailableEncoders | Where-Object { $_ -match '_mf$' }).Count -gt 0

    $testClipPath = Join-Path ([System.IO.Path]::GetTempPath()) "hwaccel_test_$([System.IO.Path]::GetRandomFileName()).mp4"
    try {
        $null = & $ffmpegPath -hide_banner -y -f lavfi -i 'color=c=black:s=256x256:d=0.5:r=25' -frames:v 5 -pix_fmt yuv420p -c:v libx264 -preset ultrafast "$testClipPath" 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $testClipPath)) {
            $hwaccelList = @('cuda', 'qsv', 'amf', 'd3d11va', 'dxva2', 'vulkan')
            foreach ($accel in $hwaccelList) {
                try {
                    $testOut = & $ffmpegPath -hide_banner -hwaccel $accel -i "$testClipPath" -frames:v 1 -f null - 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $hasInitError = ($testOut | Out-String) -match 'Failed setup|initialisation returned error|Device does not support|No device available|Hardware device setup failed|Error creating a MFX session'
                        if (-not $hasInitError) {
                            $info.AvailableHwAccels += $accel
                        }
                        else {
                            Write-LogFallback "  HWアクセル '$accel': 初期化エラー検出 → 除外" -Level "DEBUG"
                        }
                    }
                }
                catch {}
            }
        }
        else {
            Write-LogFallback "HWアクセルテスト用クリップの生成に失敗しました。" -Level "WARN"
        }
    }
    finally {
        Remove-Item -LiteralPath $testClipPath -Force -ErrorAction SilentlyContinue
    }

    $info.ScanCompleted = $true

    Write-LogFallback "テスト結果: NVIDIA=$($info.HasNvidia) Intel=$($info.HasIntel) AMD=$($info.HasAMD) Vulkan=$($info.HasVulkan) D3D12VA=$($info.HasD3D12VA) MF=$($info.HasMF)" -Level "DEBUG"
    Write-LogFallback "  エンコーダー: [$($info.AvailableEncoders -join ', ')]" -Level "DEBUG"
    Write-LogFallback "  HWアクセル  : [$($info.AvailableHwAccels -join ', ')]" -Level "DEBUG"
}
catch {
    Write-LogFallback "ハードウェアスキャンに失敗しました: $_" -Level "WARN"
}

$global:HardwareInfo = $info
if ($info.ScanCompleted) {
    $null = Save-HardwareCache -HardwareInfo $info
}

return $info