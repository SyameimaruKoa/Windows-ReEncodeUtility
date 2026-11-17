#region 中間ファイル用ハードウェアエンコード
function Get-IntermediateEncoderHelp {
    param([string]$Encoder, [string]$Ffmpeg)
    return ((& $Ffmpeg -hide_banner -h "encoder=$Encoder" 2>&1 | Out-String))
}

function Test-IntermediateEncoderOption {
    param([string]$HelpText, [string]$Name)
    return ($HelpText -match ('(?m)^\s*-' + [regex]::Escape($Name) + '\s+'))
}

function Get-IntermediateChipOptions {
    param([string]$Encoder, [string]$HelpText, [bool]$ChipOnly)
    $options = @()
    if ($Encoder -match '_mf$') {
        if (-not (Test-IntermediateEncoderOption -HelpText $HelpText -Name 'hw_encoding')) {
            throw 'Media Foundationでハードウェア強制指定を利用できません。'
        }
        $options += @('-hw_encoding', '1')
    }
    if ($Encoder -match '_qsv$' -and (Test-IntermediateEncoderOption -HelpText $HelpText -Name 'low_power')) {
        $options += @('-low_power', $(if ($ChipOnly) { '1' } else { '0' }))
    }
    if (-not $ChipOnly) { return $options }

    $disable = switch -Regex ($Encoder) {
        '_nvenc$' { @('rc-lookahead', 'spatial-aq', 'temporal-aq', 'weighted_pred', 'tf_level', 'multipass') }
        '_qsv$' { @('look_ahead', 'look_ahead_depth', 'extbrc', 'mbbrc', 'rdo') }
        '_amf$' { @('preanalysis', 'preencode', 'vbaq', 'high_motion_quality_boost_enable', 'aq_mode') }
        default { @() }
    }
    foreach ($name in $disable) {
        if (Test-IntermediateEncoderOption -HelpText $HelpText -Name $name) {
            $value = if ($name -eq 'multipass') { 'disabled' } else { '0' }
            $options += @("-$name", $value)
        }
    }
    return $options
}

function Get-IntermediateUploadDevice {
    param([string]$Encoder)
    if ($Encoder -match '_vulkan$') { return 'vulkan' }
    if ($Encoder -match '_d3d12va$') { return 'd3d12va' }
    return ''
}

function Test-IntermediateHardwareEncode {
    param([string]$Ffmpeg, [string]$VideoOptions, [string]$PixelFormat = '', [string]$UploadDevice = '')
    $argsList = @('-hide_banner', '-loglevel', 'warning')
    if ($UploadDevice) {
        $argsList += @('-init_hw_device', "$UploadDevice=intermediate_encode", '-filter_hw_device', 'intermediate_encode')
    }
    $argsList += @('-f', 'lavfi', '-i', 'color=c=black:s=256x256:r=25:d=0.4', '-frames:v', '4', '-an')
    if ($UploadDevice) { $argsList += @('-vf', "format=$PixelFormat,hwupload") }
    elseif ($PixelFormat) { $argsList += @('-vf', "format=$PixelFormat") }
    $argsList += @($VideoOptions -split '\s+' | Where-Object { $_ })
    $argsList += @('-f', 'null', '-')
    try {
        $output = & $Ffmpeg @argsList 2>&1 | Out-String
        $success = ($LASTEXITCODE -eq 0) -and ($output -notmatch '(?i)incompatible pixel format|auto-selecting format|option .* has not been used|low.?power.*(?:unsupported|not supported|ignored)')
        return @{ Success = $success; Output = $output }
    }
    catch { return @{ Success = $false; Output = [string]$_ } }
}

function Select-IntermediateHardwareVideo {
    param([string[]]$AvailableEncoders, [bool]$ScanCompleted)
    $ffmpeg = if ($global:Settings -and $global:Settings.FfmpegPath) { $global:Settings.FfmpegPath } else { 'ffmpeg' }
    $listed = @()
    try {
        $lines = & $ffmpeg -hide_banner -encoders 2>&1
        foreach ($line in $lines) {
            if ([string]$line -match '^\s*V[.\w]+\s+((?:h264|hevc|av1|vp9|vp8|mjpeg|mpeg2|mpeg2video)_(?:nvenc|qsv|amf|vulkan|d3d12va|mf))\s+') {
                $listed += $Matches[1]
            }
        }
    } catch {}
    $candidates = @()
    foreach ($encoder in @($listed | Sort-Object -Unique)) {
        if (-not $ScanCompleted) { $candidates += $encoder; continue }
        $device = Get-IntermediateUploadDevice -Encoder $encoder
        if ($device) {
            # GPUフレーム専用エンコーダーは既存のシステムメモリ入力スキャンでは検出できない場合がある。
            $hwFormat = if ($device -eq 'vulkan') { 'vulkan' } else { 'd3d12' }
            $probe = Test-IntermediateHardwareEncode -Ffmpeg $ffmpeg -VideoOptions "-c:v $encoder -pix_fmt $hwFormat -b:v 5M" -PixelFormat 'nv12' -UploadDevice $device
            if ($probe.Success) { $candidates += $encoder }
        }
        elseif ($encoder -match '_mf$') {
            # ソフトウェアMFTの検出だけではハードウェアエンコードが可能とは限らない。
            $probe = Test-IntermediateHardwareEncode -Ffmpeg $ffmpeg -VideoOptions "-c:v $encoder -hw_encoding 1 -b:v 5M" -PixelFormat 'nv12'
            if ($probe.Success) { $candidates += $encoder }
        }
        elseif ($encoder -in $AvailableEncoders) { $candidates += $encoder }
    }
    $hardware = [ordered]@{ 'NVIDIA (NVENC)' = '_nvenc'; 'Intel (QSV)' = '_qsv'; 'AMD (AMF)' = '_amf'; 'Vulkan Video' = '_vulkan'; 'D3D12VA' = '_d3d12va'; 'Media Foundation (MF)' = '_mf' }
    $choices = @('CPU (Software)')
    $suffixes = @('')
    foreach ($label in $hardware.Keys) {
        if (@($candidates | Where-Object { $_.EndsWith($hardware[$label]) }).Count -gt 0) {
            $choices += $label
            $suffixes += $hardware[$label]
        }
    }
    $selected = Show-Menu -Title '中間ファイルの映像エンコーダーを選択' -Choices $choices
    if ($selected -lt 0) { return $null }
    if ($selected -eq 0) { return @{ Software = $true } }

    $suffix = $suffixes[$selected]
    $encoders = @($candidates | Where-Object { $_.EndsWith($suffix) })
    $codecIndex = Show-Menu -Title '中間ファイル用コーデックを選択' -Choices $encoders
    if ($codecIndex -lt 0) { return $null }
    $encoder = $encoders[$codecIndex]
    $helpText = Get-IntermediateEncoderHelp -Encoder $encoder -Ffmpeg $ffmpeg

    $modeIndex = Show-Menu -Title 'ハードウェアエンコード方式を選択' -Choices @(
        '専用エンコード回路優先（補助演算を抑制・既定）',
        '通常のハードウェアエンコード'
    ) -DefaultIndex 0
    if ($modeIndex -lt 0) { return $null }
    $chipOnly = ($modeIndex -eq 0)
    if ($chipOnly -and ($suffix -in @('_vulkan', '_d3d12va', '_mf') -or ($suffix -eq '_qsv' -and -not (Test-IntermediateEncoderOption -HelpText $helpText -Name 'low_power')))) {
        Write-Host 'このAPI/コーデックは専用回路以外の演算を完全に禁止する指定を公開していません。ハードウェア経路を使用します。' -ForegroundColor Yellow
    }

    $uploadDevice = Get-IntermediateUploadDevice -Encoder $encoder
    $pixelFormats = @()
    if ($uploadDevice) {
        $pixelFormats = @('nv12', 'p010le')
    }
    elseif ($helpText -match '(?m)^\s*Supported pixel formats:\s*([^\r\n]+)') {
        $supported = @($Matches[1].Trim() -split '\s+')
        $preferred = @('yuv444p16le', 'yuv444p10le', 'yuv444p', 'p410le', 'p210le', 'yuv422p10le', 'yuv422p', 'nv16', 'p016le', 'p010le', 'yuv420p10le', 'nv12', 'yuv420p', 'yuyv422', 'yuvj420p', 'yuvj422p', 'yuvj444p')
        $pixelFormats = @($preferred | Where-Object { $_ -in $supported })
    }
    $formatChoices = @()
    if (-not $uploadDevice) { $formatChoices += '自動（入力・エンコーダーに合わせる）' }
    $formatChoices += $pixelFormats
    $formatIndex = Show-Menu -Title '中間ファイルのピクセルフォーマットを選択' -Choices $formatChoices
    if ($formatIndex -lt 0) { return $null }
    $pixelFormat = if (-not $uploadDevice -and $formatIndex -eq 0) { '' } else { $formatChoices[$formatIndex] }

    $videoArgs = @('-c:v', $encoder)
    if ($uploadDevice) {
        $videoArgs += @('-pix_fmt', $(if ($uploadDevice -eq 'vulkan') { 'vulkan' } else { 'd3d12' }))
    }
    elseif ($pixelFormat) { $videoArgs += @('-pix_fmt', $pixelFormat) }

    $hasQp = ($suffix -in @('_nvenc', '_qsv', '_amf')) -or (Test-IntermediateEncoderOption -HelpText $helpText -Name 'qp')
    if ($hasQp) {
        $maxQp = if ($encoder -eq 'mjpeg_qsv') { 31 } elseif ($encoder -match '^av1_') { $(if ($suffix -eq '_nvenc') { 63 } elseif ($suffix -eq '_qsv') { 51 } else { 255 }) } else { 51 }
        $levels = if ($encoder -eq 'mjpeg_qsv') { @(2, 5, 10, 15) } else { @(5, 10, 15, 20) }
        $qualityChoices = @($levels | ForEach-Object { "固定品質 (QP/品質値: $_)" }) + @('カスタム')
        $qualityIndex = Show-Menu -Title '中間ファイルの固定品質を選択（低い値ほど高品質）' -Choices $qualityChoices -DefaultIndex 1
        if ($qualityIndex -lt 0) { return $null }
        if ($qualityIndex -lt $levels.Count) { $qp = $levels[$qualityIndex] }
        else {
            $qp = 0
            $entered = Read-Host "品質値 (1-$maxQp)"
            if (-not [int]::TryParse($entered, [ref]$qp) -or $qp -lt 1 -or $qp -gt $maxQp) { Write-Host '品質値が範囲外です。' -ForegroundColor Yellow; return $null }
        }
        switch ($suffix) {
            '_nvenc' { $videoArgs += @('-rc', 'constqp', '-qp', "$qp") }
            '_qsv' { $videoArgs += @('-q:v', "$qp") }
            '_amf' {
                $videoArgs += @('-rc', 'cqp')
                foreach ($name in @('qp_i', 'qp_p', 'qp_b')) {
                    if (Test-IntermediateEncoderOption -HelpText $helpText -Name $name) { $videoArgs += @("-$name", "$qp") }
                }
            }
            default { $videoArgs += @('-qp', "$qp") }
        }
    }
    elseif ($suffix -eq '_mf' -and (Test-IntermediateEncoderOption -HelpText $helpText -Name 'rate_control') -and (Test-IntermediateEncoderOption -HelpText $helpText -Name 'quality')) {
        $qualityIndex = Show-Menu -Title 'Media Foundationの品質を選択' -Choices @('最高品質 (100)', '高品質 (90)', '高品質 (80)')
        if ($qualityIndex -lt 0) { return $null }
        $videoArgs += @('-rate_control', 'quality', '-quality', "$(@(100, 90, 80)[$qualityIndex])")
    }
    else {
        $qualityIndex = Show-Menu -Title '中間ファイルの映像ビットレートを選択' -Choices @('100 Mbps', '200 Mbps', '50 Mbps', 'カスタム')
        if ($qualityIndex -lt 0) { return $null }
        $bitrate = if ($qualityIndex -eq 3) { Read-Host 'ビットレート (例: 100M)' } else { @('100M', '200M', '50M')[$qualityIndex] }
        if ($bitrate -notmatch '^\d+(?:\.\d+)?[kKmM]?$') { return $null }
        $videoArgs += @('-b:v', $bitrate)
    }

    $presets = @()
    $presetName = ''
    if ($suffix -eq '_nvenc' -and (Test-IntermediateEncoderOption -HelpText $helpText -Name 'preset')) {
        $presetName = 'preset'; $presets = @('p7', 'p6', 'p5', 'p4', 'p3', 'p2', 'p1')
    }
    elseif ($suffix -eq '_qsv' -and (Test-IntermediateEncoderOption -HelpText $helpText -Name 'preset')) {
        $presetName = 'preset'; $presets = @('veryslow', 'slower', 'slow', 'medium', 'fast', 'faster', 'veryfast')
    }
    elseif ($suffix -eq '_amf' -and (Test-IntermediateEncoderOption -HelpText $helpText -Name 'quality')) {
        $presetName = 'quality'; $presets = @('quality', 'balanced', 'speed')
    }
    if ($presets.Count -gt 0) {
        $presetIndex = Show-Menu -Title 'エンコード回路の品質/速度プリセットを選択' -Choices $presets
        if ($presetIndex -lt 0) { return $null }
        $videoArgs += @("-$presetName", $presets[$presetIndex])
    }
    if ($suffix -eq '_nvenc' -and (Test-IntermediateEncoderOption -HelpText $helpText -Name 'tune')) {
        $videoArgs += @('-tune', 'hq')
    }
    try { $videoArgs += @(Get-IntermediateChipOptions -Encoder $encoder -HelpText $helpText -ChipOnly $chipOnly) }
    catch { Write-Host $_ -ForegroundColor Red; return $null }

    $videoSetting = $videoArgs -join ' '
    Write-Host "選択したエンコーダー設定を短いテスト映像で確認しています: $videoSetting"
    $test = Test-IntermediateHardwareEncode -Ffmpeg $ffmpeg -VideoOptions $videoSetting -PixelFormat $pixelFormat -UploadDevice $uploadDevice
    if (-not $test.Success) {
        Write-Host "選択したハードウェア設定を使用できません。通常モードや別フォーマットへ自動変更しません。`n$($test.Output)" -ForegroundColor Red
        $retry = Show-Menu -Title '中間ファイル設定を選び直しますか？' -Choices @('はい', '中止')
        if ($retry -eq 0) { return Select-IntermediateHardwareVideo -AvailableEncoders $AvailableEncoders -ScanCompleted $ScanCompleted }
        return $null
    }
    return @{ Video = $videoSetting; IntermediatePixelFormat = $pixelFormat; IntermediateUploadDevice = $uploadDevice; IntermediateChipPreferred = $chipOnly }
}
#endregion
