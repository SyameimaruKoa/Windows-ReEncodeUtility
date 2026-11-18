<#
.SYNOPSIS
    通常の網羅テストでは未検証のエンコーダー（Vulkan / D3D12VA / MF音声 / 外部音声）を詳細テストする。
.DESCRIPTION
    失敗時は ffmpeg の最初のエラー行を記録し、.cache/untested-encoders.json に保存する。
    一時ファイルはすべて git 対象外の .cache 配下に作り、プロジェクト外は触らない。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$rootDir = Split-Path -Parent $PSScriptRoot
$global:ScriptDir = $rootDir
$global:Settings = Import-PowerShellDataFile -Path (Join-Path $rootDir 'config.user.psd1')
$global:AppCacheDir = Join-Path $rootDir '.cache'
$global:AppTempDir = Join-Path $global:AppCacheDir 'test-work\untested'
foreach ($d in @($global:AppCacheDir, $global:AppTempDir)) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { $null = New-Item -ItemType Directory -Path $d -Force }
}
$ffmpeg = $global:Settings.FfmpegPath
$ffprobe = $global:Settings.FfprobePath

$script:Results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Category, [string]$Name, [bool]$Success, [string]$Detail = '')
    $script:Results.Add([pscustomobject]@{ Category = $Category; Name = $Name; Success = $Success; Detail = $Detail })
    $mark = if ($Success) { 'PASS' } else { 'FAIL' }
    Write-Host ("  [{0}] {1} :: {2}" -f $mark, $Name, $Detail)
}

function Invoke-Probe {
    param([string[]]$Arguments, [string]$FilePath = '')
    try {
        $output = (& $Arguments[0] @($Arguments[1..($Arguments.Count - 1)]) 2>&1 | Out-String)
        $code = $LASTEXITCODE
        $errorLine = ''
        if ($code -ne 0) {
            $errorLine = (($output -split "`r?`n") | Where-Object {
                    $_ -match '(?i)(error|invalid|unsupported|not found|failed|not supported|cannot|could not)'
                } | Select-Object -First 1)
            if (-not $errorLine) { $errorLine = ($output -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1) }
        }
        $exists = $true
        if ($FilePath) { $exists = Test-Path -LiteralPath $FilePath -PathType Leaf }
        return [pscustomobject]@{ Success = ($code -eq 0 -and $exists); Error = ([string]$errorLine).Trim(); Output = $output }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Error = $_.Exception.Message; Output = '' }
    }
}

function Test-EncoderOption {
    param([string]$Encoder, [string]$Option)
    $help = (& $ffmpeg -hide_banner -h "encoder=$Encoder" 2>&1 | Out-String)
    return ($help -match ('(?m)^\s*-' + [regex]::Escape($Option) + '\s+'))
}

# --- 入力素材（実動画があればそれを短く切り出し、無ければ合成） ---
$sourceVideo = 'C:\Users\kouki\Documents\MyApp\Windows-ReEncodeUtility\.cache\Azahar 2126.2 _ SUPER MARIO 3D LAND 2026-11-16 19-03-51.mp4'
$clip = Join-Path $global:AppTempDir 'src.mkv'
if (Test-Path -LiteralPath $sourceVideo -PathType Leaf) {
    $null = & $ffmpeg -hide_banner -loglevel error -y -ss 0 -t 2 -i $sourceVideo -c copy $clip 2>&1
}
if (-not (Test-Path -LiteralPath $clip -PathType Leaf)) {
    $null = & $ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=blue:s=640x360:r=30:d=2' `
        -f lavfi -i 'sine=frequency=440:duration=2' -c:v libx264 -preset ultrafast -c:a aac -shortest $clip 2>&1
}
$wav = Join-Path $global:AppTempDir 'src.wav'
$null = & $ffmpeg -hide_banner -loglevel error -y -i $clip -vn -ac 2 -ar 48000 -c:a pcm_s16le $wav 2>&1
Write-Host "入力: $clip / $wav`n"

# ============================================================
Write-Host '===== [1/4] Vulkan 映像エンコーダー ====='
# ============================================================
foreach ($enc in @('h264_vulkan', 'hevc_vulkan', 'av1_vulkan', 'ffv1_vulkan', 'prores_ks_vulkan')) {
    # (a) 通常の CPU フレーム入力
    $r = Invoke-Probe -Arguments @($ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'color=c=black:s=256x256:r=25:d=0.4', '-frames:v', '2', '-an',
        '-c:v', $enc, '-b:v', '2000k', '-f', 'null', 'NUL')
    Add-Result -Category 'Vulkan' -Name "$enc / CPU入力" -Success $r.Success -Detail $r.Error

    # (b) Vulkan デバイスを初期化し、hwupload で GPU フレームを渡す
    $r2 = Invoke-Probe -Arguments @($ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
        '-init_hw_device', 'vulkan=vk', '-filter_hw_device', 'vk',
        '-f', 'lavfi', '-i', 'color=c=black:s=256x256:r=25:d=0.4', '-frames:v', '2', '-an',
        '-vf', 'format=nv12,hwupload', '-pix_fmt', 'vulkan', '-c:v', $enc, '-b:v', '2000k', '-f', 'null', 'NUL')
    Add-Result -Category 'Vulkan' -Name "$enc / hwupload+pix_fmt=vulkan" -Success $r2.Success -Detail $r2.Error

    # (c) Vulkan ハードウェアデコード → Vulkan エンコード
    $r3 = Invoke-Probe -Arguments @($ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
        '-hwaccel', 'vulkan', '-hwaccel_output_format', 'vulkan', '-i', $clip,
        '-frames:v', '2', '-an', '-c:v', $enc, '-b:v', '2000k', '-f', 'null', 'NUL')
    Add-Result -Category 'Vulkan' -Name "$enc / vulkanデコード" -Success $r3.Success -Detail $r3.Error
}

# ============================================================
Write-Host "`n===== [2/4] D3D12VA 映像エンコーダー ====="
# ============================================================
foreach ($enc in @('h264_d3d12va', 'hevc_d3d12va', 'av1_d3d12va')) {
    $r = Invoke-Probe -Arguments @($ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'color=c=black:s=256x256:r=25:d=0.4', '-frames:v', '2', '-an',
        '-c:v', $enc, '-b:v', '2000k', '-f', 'null', 'NUL')
    Add-Result -Category 'D3D12VA' -Name "$enc / CPU入力" -Success $r.Success -Detail $r.Error

    $r2 = Invoke-Probe -Arguments @($ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
        '-init_hw_device', 'd3d12va=d3d', '-filter_hw_device', 'd3d',
        '-f', 'lavfi', '-i', 'color=c=black:s=256x256:r=25:d=0.4', '-frames:v', '2', '-an',
        '-vf', 'format=nv12,hwupload', '-pix_fmt', 'd3d12', '-c:v', $enc, '-b:v', '2000k', '-f', 'null', 'NUL')
    Add-Result -Category 'D3D12VA' -Name "$enc / hwupload+pix_fmt=d3d12" -Success $r2.Success -Detail $r2.Error
}

# ============================================================
Write-Host "`n===== [3/4] 未テストの MediaFoundation 映像エンコーダー ====="
# ============================================================
foreach ($enc in @('hevc_mf', 'av1_mf')) {
    $r = Invoke-Probe -Arguments @($ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'color=c=black:s=256x256:r=25:d=0.4', '-frames:v', '2', '-an',
        '-c:v', $enc, '-b:v', '2000k', '-f', 'null', 'NUL')
    Add-Result -Category 'MF-Video' -Name "$enc / 基本" -Success $r.Success -Detail $r.Error

    if (Test-EncoderOption -Encoder $enc -Option 'hw_encoding') {
        $r2 = Invoke-Probe -Arguments @($ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
            '-f', 'lavfi', '-i', 'color=c=black:s=256x256:r=25:d=0.4', '-frames:v', '2', '-an',
            '-c:v', $enc, '-hw_encoding', '1', '-b:v', '2000k', '-f', 'null', 'NUL')
        Add-Result -Category 'MF-Video' -Name "$enc / hw_encoding=1" -Success $r2.Success -Detail $r2.Error
    }
    else {
        Add-Result -Category 'MF-Video' -Name "$enc / hw_encoding=1" -Success $false -Detail 'hw_encoding オプション非対応'
    }
}

# ============================================================
Write-Host "`n===== [4/4] 音声エンコーダー ====="
# ============================================================
foreach ($enc in @('aac_mf', 'ac3_mf', 'mp3_mf')) {
    $r = Invoke-Probe -Arguments @($ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
        '-i', $wav, '-vn', '-frames:a', '2', '-c:a', $enc, '-b:a', '128k', '-f', 'null', 'NUL')
    Add-Result -Category 'MF-Audio' -Name "$enc / 基本" -Success $r.Success -Detail $r.Error

    if (Test-EncoderOption -Encoder $enc -Option 'hw_encoding') {
        $r2 = Invoke-Probe -Arguments @($ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
            '-i', $wav, '-vn', '-frames:a', '2', '-c:a', $enc, '-hw_encoding', '1', '-b:a', '128k', '-f', 'null', 'NUL')
        Add-Result -Category 'MF-Audio' -Name "$enc / hw_encoding=1" -Success $r2.Success -Detail $r2.Error
    }
}

# 外部音声エンコーダー（アプリと同じ引数形式）
$external = @(
    @{ Type = 'qaac'; Exe = $global:Settings.QaacPath; Cases = @(
            @{ Opts = '--tvbr 91'; Name = 'AAC-LC TVBR91' },
            @{ Opts = '--tvbr 64'; Name = 'AAC-LC TVBR64' },
            @{ Opts = '--he --cvbr 64'; Name = 'HE-AAC CVBR64' }
        ) },
    @{ Type = 'nero'; Exe = $global:Settings.NeroAacEncPath; Cases = @(
            @{ Opts = '-q 0.50'; Name = 'AAC-LC q0.50' },
            @{ Opts = '-he -q 0.35'; Name = 'HE-AAC q0.35' }
        ) },
    @{ Type = 'fdkaac'; Exe = $global:Settings.FdkaacPath; Cases = @(
            @{ Opts = '-m 4'; Name = 'AAC-LC VBR4' },
            @{ Opts = '-p 5 -m 3'; Name = 'HE-AAC VBR3' }
        ) }
)
foreach ($e in $external) {
    $exe = $e.Exe
    if (-not $exe -or -not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        Add-Result -Category 'External-Audio' -Name "$($e.Type)" -Success $false -Detail '実行ファイルが見つからない'
        continue
    }
    foreach ($case in $e.Cases) {
        $out = Join-Path $global:AppTempDir "$($e.Type)-$([guid]::NewGuid().ToString('N')).m4a"
        $optParts = @($case.Opts -split '\s+')
        if ($e.Type -eq 'qaac') {
            $argParts = $optParts + @($wav, '-o', $out)
        }
        elseif ($e.Type -eq 'nero') {
            $argParts = $optParts + @('-if', $wav, '-of', $out)
        }
        else {
            $argParts = $optParts + @('-o', $out, $wav)
        }
        $r = Invoke-Probe -Arguments (@($exe) + $argParts) -FilePath $out
        $codec = ''
        if ($r.Success) {
            $codec = (& $ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 $out 2>$null | Select-Object -First 1).Trim()
        }
        Add-Result -Category 'External-Audio' -Name "$($e.Type) / $($case.Name)" -Success ($r.Success -and $codec -eq 'aac') -Detail "$(if ($r.Success) { "codec=$codec" } else { $r.Error })"
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}

# --- 結果保存 ---
$report = [ordered]@{
    GeneratedAt = (Get-Date).ToString('o')
    MachineName = $env:COMPUTERNAME
    Results     = @($script:Results)
}
$jsonPath = Join-Path $global:AppCacheDir 'untested-encoders.json'
try { $report | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $jsonPath -Encoding utf8 -Force }
catch { Write-Host "結果保存失敗: $_" -ForegroundColor Red }

$ok = @($script:Results | Where-Object { $_.Success }).Count
Write-Host "`n================ サマリー ================"
Write-Host "PASS=$ok / FAIL=$($script:Results.Count - $ok)"
Write-Host "詳細: $jsonPath"
if ($script:Results.Count - $ok -gt 0) {
    Write-Host "`n--- 失敗一覧 ---" -ForegroundColor Red
    $script:Results | Where-Object { -not $_.Success } | ForEach-Object {
        Write-Host "  [$($_.Category)] $($_.Name) :: $($_.Detail)" -ForegroundColor Red
    }
}
