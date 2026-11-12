# 詳細ヘルプは先頭のコメントベースヘルプに実装している。
<#
.SYNOPSIS
    PS4 Cameraの映像と音声をIntel QSVでMKVに録画する。
.DESCRIPTION
    PSCam4Winの仮想カメラをDirectShowで取り込み、プレビューなしで録画する。
    標準はYUY2のGPUアップロード、QSV VPPによるNV12変換、VDEnc優先のH.264エンコード。
    VDEncが使えない場合も通常QSVやソフトウェアエンコードには自動切り替えしない。
    引数なしでは設定メニューを表示し、qキーで録画を正常停止する。
    FFmpegのログは録画ファイルと同じフォルダへ保存する。
    録画後にFFprobeで実フレーム数と再生時間を検査し、目標FPSを大きく下回れば失敗として報告する。
.PARAMETER Help
    詳しいヘルプを表示して終了する。-h、-Help、--helpに対応する。
.PARAMETER Mode
    VDEnc（既定、-low_power 1）またはQSV（-low_power 0）。
.PARAMETER Codec
    H264（既定）またはHEVC。
.PARAMETER Conversion
    GPU（既定、hwuploadとvpp_qsv）またはCPU（format=nv12）。
    CPU変換を選んでも映像エンコーダーはQSVのまま。
.PARAMETER VideoDevice
    DirectShowの映像デバイス名。
.PARAMETER CaptureNegotiation
    SizeFpsは解像度とFPSだけを指定し、入力のピクセル形式はDirectShowに選ばせる。
    YUY2は解像度・FPS・YUY2をすべて要求する。
    DeviceDefault（既定）は入力の全形式をカメラ側に任せる。出力の解像度・FPSはログで確認すること。
.PARAMETER AudioDevice
    DirectShowの音声デバイス名。既定はVoicemeeter Out B2。
.PARAMETER NoAudio
    音声を録画しない。
.PARAMETER AudioCodec
    Opus（既定）、AAC、PCM（16-bit無圧縮）。
.PARAMETER AudioBitrateKbps
    OpusまたはAACの音声ビットレート。既定は256kbps。
.PARAMETER OpusComplexity
    libopusのエンコード複雑度（0～10）。既定は5。値を下げるほどCPU負荷が軽くなるが品質も下がる。
.PARAMETER Width
    録画解像度の幅。既定は2560。
.PARAMETER Height
    録画解像度の高さ。既定は800。
.PARAMETER Fps
    撮影フレームレート。既定は60。
.PARAMETER Quality
    QSVのglobal_quality値。既定は23。
.PARAMETER OutputDirectory
    録画先フォルダ。既定はWindowsのビデオフォルダ。
.PARAMETER FfmpegPath
    FFmpeg実行ファイル。未指定時はconfig.user.psd1のFfmpegPathを使う。
.PARAMETER FfprobePath
    FFprobe実行ファイル。未指定時はconfig.user.psd1のFfprobePathを使う。
.PARAMETER DurationSeconds
    指定秒数で録画を停止する。既定の0は手動停止。
.PARAMETER ListDevices
    DirectShowの映像・音声デバイス一覧を表示して終了する。
.PARAMETER ListFormats
    VideoDeviceの対応解像度・FPS・形式を表示して終了する。
.PARAMETER Interactive
    他の引数を指定していても対話メニューを表示する。
.EXAMPLE
    .\Record-PSCamera-QSV.ps1
    対話メニューから設定して録画する。
.EXAMPLE
    .\Record-PSCamera-QSV.ps1 -DurationSeconds 10
    VDEnc・GPU VPP・Opus音声で10秒間試験録画する。
.EXAMPLE
    .\Record-PSCamera-QSV.ps1 -Mode QSV -Conversion CPU -Codec HEVC
    通常QSV・CPU色変換・H.265で録画する。
.EXAMPLE
    .\Record-PSCamera-QSV.ps1 -ListDevices
    利用可能な映像・音声入力を確認する。
#>
[CmdletBinding()]
param(
    [Alias('h', '-help')][switch]$Help,
    [ValidateSet('VDEnc', 'QSV')][string]$Mode = 'VDEnc',
    [ValidateSet('H264', 'HEVC')][string]$Codec = 'H264',
    [ValidateSet('GPU', 'CPU')][string]$Conversion = 'GPU',
    [string]$VideoDevice = 'PS4 Camera (Windows 仮想カメラ)',
    [ValidateSet('SizeFps', 'YUY2', 'DeviceDefault')][string]$CaptureNegotiation = 'DeviceDefault',
    [string]$AudioDevice = 'Voicemeeter Out B2 (VB-Audio Voicemeeter VAIO)',
    [switch]$NoAudio,
    [ValidateSet('Opus', 'AAC', 'PCM')][string]$AudioCodec = 'Opus',
    [ValidateRange(32, 1024)][int]$AudioBitrateKbps = 256,
    [ValidateRange(0, 10)][int]$OpusComplexity = 5,
    [ValidateRange(2, 8192)][int]$Width = 2560,
    [ValidateRange(2, 4320)][int]$Height = 800,
    [ValidateRange(1, 240)][int]$Fps = 60,
    [ValidateRange(1, 51)][int]$Quality = 23,
    [string]$OutputDirectory,
    [string]$FfmpegPath,
    [string]$FfprobePath,
    [ValidateRange(0, 86400)][int]$DurationSeconds = 0,
    [switch]$ListDevices,
    [switch]$ListFormats,
    [switch]$Interactive
)

#region ヘルプ
if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}
#endregion

#region メニュー
function Read-Selection {
    param(
        [string]$Title,
        [string[]]$Choices,
        [int]$DefaultIndex = 0
    )
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    for ($index = 0; $index -lt $Choices.Count; $index++) {
        $suffix = if ($index -eq $DefaultIndex) { ' [既定]' } else { '' }
        Write-Host ("  {0}. {1}{2}" -f ($index + 1), $Choices[$index], $suffix)
    }
    while ($true) {
        $inputText = Read-Host '番号を入力（Enterで既定）'
        if ([string]::IsNullOrWhiteSpace($inputText)) {
            return $DefaultIndex
        }
        $number = 0
        if ([int]::TryParse($inputText, [ref]$number) -and $number -ge 1 -and $number -le $Choices.Count) {
            return ($number - 1)
        }
        Write-Host '選択番号が正しくないのじゃ。' -ForegroundColor Yellow
    }
}

function Show-RecordingMenu {
    $script:Mode = @('VDEnc', 'QSV')[(Read-Selection 'エンコードモード' @('VDEnc（省電力を優先）', '通常QSV') ([array]::IndexOf(@('VDEnc', 'QSV'), $script:Mode)))]
    $script:Codec = @('H264', 'HEVC')[(Read-Selection '映像コーデック' @('H.264', 'H.265 / HEVC') ([array]::IndexOf(@('H264', 'HEVC'), $script:Codec)))]
    $script:Conversion = @('GPU', 'CPU')[(Read-Selection 'YUY2からNV12への変換' @('QSV VPP（GPU優先）', 'CPU（互換性検証用）') ([array]::IndexOf(@('GPU', 'CPU'), $script:Conversion)))]
    $audioChoice = Read-Selection '音声' @('音声も録画する', '映像のみ') ([int][bool]$script:NoAudio)
    $script:NoAudio = [bool]($audioChoice -eq 1)
    if (-not $script:NoAudio) {
        $deviceName = Read-Host ("音声デバイス名（Enterで {0}）" -f $script:AudioDevice)
        if (-not [string]::IsNullOrWhiteSpace($deviceName)) {
            $script:AudioDevice = $deviceName
        }
        $script:AudioCodec = @('Opus', 'AAC', 'PCM')[(Read-Selection '音声コーデック' @('Opus（既定・省CPU設定）', 'AAC', 'PCM無圧縮') ([array]::IndexOf(@('Opus', 'AAC', 'PCM'), $script:AudioCodec)))]
    }
    $directory = Read-Host ("保存先（Enterで {0}）" -f $script:OutputDirectory)
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        $script:OutputDirectory = $directory
    }
    Write-Host ""
    Write-Host ("入力: {0} / {1}x{2} / {3}fps / {4}" -f $script:VideoDevice, $script:Width, $script:Height, $script:Fps, $script:CaptureNegotiation)
    Write-Host ("映像: {0}, {1}, 変換={2}, 品質={3}" -f $script:Codec, $script:Mode, $script:Conversion, $script:Quality)
    if ($script:NoAudio) {
        Write-Host '音声: なし'
    } else {
        Write-Host ("音声: {0} ({1})" -f $script:AudioDevice, $script:AudioCodec)
    }
    if ((Read-Host '録画を開始する場合はEnter、キャンセルはN') -match '^[Nn]$') {
        exit 0
    }
}
#endregion

#region 実行環境
try {
    if (-not $FfmpegPath) {
        $settingsPath = Join-Path $PSScriptRoot 'config.user.psd1'
        if (Test-Path -LiteralPath $settingsPath) {
            $settings = Import-PowerShellDataFile -Path $settingsPath
            if ($settings.FfmpegPath) {
                $FfmpegPath = [string]$settings.FfmpegPath
            }
            if (-not $FfprobePath -and $settings.FfprobePath) {
                $FfprobePath = [string]$settings.FfprobePath
            }
        }
    }
    if (-not $FfmpegPath) {
        $FfmpegPath = 'ffmpeg'
    }
    if (-not $FfprobePath) {
        $FfprobePath = 'ffprobe'
    }
    $ffmpegCommand = Get-Command -Name $FfmpegPath -CommandType Application -ErrorAction Stop
    $ffmpegExecutable = $ffmpegCommand.Source

    if ($ListDevices) {
        & $ffmpegExecutable -hide_banner -list_devices true -f dshow -i dummy
        exit 0
    }
    if ($ListFormats) {
        & $ffmpegExecutable -hide_banner -list_options true -f dshow -i "video=$VideoDevice"
        exit 0
    }

    if (-not $OutputDirectory) {
        $OutputDirectory = [Environment]::GetFolderPath('MyVideos')
    }
    if ($PSBoundParameters.Count -eq 0 -or $Interactive) {
        Show-RecordingMenu
    }

    if (($Width % 2) -ne 0 -or ($Height % 2) -ne 0) {
        throw 'QSV用の幅と高さは偶数を指定するのじゃ。'
    }
    $encoder = if ($Codec -eq 'HEVC') { 'hevc_qsv' } else { 'h264_qsv' }
    $availableEncoders = (& $ffmpegExecutable -hide_banner -encoders 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $availableEncoders -notmatch [regex]::Escape($encoder)) {
        throw "FFmpegに $encoder が存在しないのじゃ。"
    }
    if (-not $NoAudio -and $AudioCodec -eq 'Opus' -and $availableEncoders -notmatch '\blibopus\b') {
        throw 'FFmpegにlibopusエンコーダーが存在しないのじゃ。'
    }
    if ($Conversion -eq 'GPU') {
        $availableFilters = (& $ffmpegExecutable -hide_banner -filters 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or $availableFilters -notmatch '\bvpp_qsv\b') {
            throw 'FFmpegにvpp_qsvが存在しないのじゃ。'
        }
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
}
catch {
    Write-Host ("準備失敗: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
#endregion

#region FFmpeg引数
$timeStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$baseName = "PSCamera_$timeStamp"
$outputFile = Join-Path $OutputDirectory "$baseName.mkv"
$logFile = Join-Path $OutputDirectory "$baseName.log"
$lowPower = if ($Mode -eq 'VDEnc') { '1' } else { '0' }

$ffmpegArgs = @('-hide_banner', '-report', '-stats_period', '5', '-n')
if ($Conversion -eq 'GPU') {
    $ffmpegArgs += @(
        '-init_hw_device', 'qsv=hw,child_device_type=d3d11va',
        '-filter_hw_device', 'hw'
    )
}
$ffmpegArgs += @(
    '-f', 'dshow',
    '-thread_queue_size', '128',
    '-rtbufsize', '256M'
)
if ($CaptureNegotiation -ne 'DeviceDefault') {
    $ffmpegArgs += @(
        '-video_size', ('{0}x{1}' -f $Width, $Height),
        '-framerate', "$Fps"
    )
}
if ($CaptureNegotiation -eq 'YUY2') {
    $ffmpegArgs += @('-pixel_format', 'yuyv422')
}
$inputName = "video=$VideoDevice"
if (-not $NoAudio) {
    $inputName += ":audio=$AudioDevice"
}
$ffmpegArgs += @('-i', $inputName, '-map', '0:v:0')
if (-not $NoAudio) {
    $ffmpegArgs += @('-map', '0:a:0')
}
$filter = if ($Conversion -eq 'GPU') {
    'hwupload=extra_hw_frames=16,vpp_qsv=format=nv12'
} else {
    'format=nv12'
}
$ffmpegArgs += @(
    '-vf', $filter,
    '-c:v', $encoder,
    '-low_power', $lowPower,
    '-preset', 'fast',
    '-bf', '0',
    '-global_quality', "$Quality",
    '-fps_mode:v', 'passthrough'
)
if ($NoAudio) {
    $ffmpegArgs += '-an'
} elseif ($AudioCodec -eq 'PCM') {
    $ffmpegArgs += @('-c:a', 'pcm_s16le', '-ar', '48000', '-ac', '2')
} elseif ($AudioCodec -eq 'Opus') {
    $ffmpegArgs += @(
        '-c:a', 'libopus',
        '-b:a', ('{0}k' -f $AudioBitrateKbps),
        '-compression_level:a', "$OpusComplexity",
        '-ar', '48000',
        '-ac', '2'
    )
} else {
    $ffmpegArgs += @(
        '-c:a', 'aac',
        '-b:a', ('{0}k' -f $AudioBitrateKbps),
        '-ar', '48000',
        '-ac', '2'
    )
}
if ($DurationSeconds -gt 0) {
    $ffmpegArgs += @('-t', "$DurationSeconds")
}
$ffmpegArgs += $outputFile
#endregion

#region 録画
$priorReport = [Environment]::GetEnvironmentVariable('FFREPORT', 'Process')
$env:FFREPORT = 'file={0}.log:level=32' -f $baseName
Write-Host ("録画開始: {0}" -f $outputFile) -ForegroundColor Cyan
Write-Host ("モード: {0} / {1} / {2} / 入力設定={3}" -f $Mode, $Codec, $Conversion, $CaptureNegotiation)
if ($NoAudio) {
    Write-Host '音声: なし'
} else {
    Write-Host ("音声: {0} ({1})" -f $AudioDevice, $AudioCodec)
}
Write-Host 'プレビューなし。手動停止はFFmpegのコンソールで q を押すのじゃ。'
$exitCode = 1
Push-Location -LiteralPath $OutputDirectory
try {
    & $ffmpegExecutable @ffmpegArgs
    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
    [Environment]::SetEnvironmentVariable('FFREPORT', $priorReport, 'Process')
}
if ($exitCode -ne 0) {
    Write-Host ("録画失敗 (FFmpeg終了コード {0})。ログ: {1}" -f $exitCode, $logFile) -ForegroundColor Red
    Write-Host 'DirectShowの「Could not set video options」が出たら、-ListFormatsで対応形式を確認するのじゃ。' -ForegroundColor Yellow
    Write-Host '入力形式の強制指定時に失敗する場合は -CaptureNegotiation DeviceDefault で再試行するのじゃ。' -ForegroundColor Yellow
    exit $exitCode
}
#region 出力検証
$probeCommand = Get-Command -Name $FfprobePath -CommandType Application -ErrorAction SilentlyContinue
if ($null -eq $probeCommand) {
    Write-Host 'FFprobeが見つからないためフレーム数の検証を省略したのじゃ。' -ForegroundColor Yellow
} else {
    try {
        $probeLines = & $probeCommand.Source -v error -count_frames -select_streams 'v:0' -show_entries 'stream=nb_read_frames' -show_entries 'format=duration' -of json -i $outputFile
        if ($LASTEXITCODE -ne 0) {
            throw 'FFprobeによるファイル解析に失敗した'
        }
        $probe = ($probeLines | Out-String | ConvertFrom-Json)
        $frames = [double]::Parse([string]$probe.streams[0].nb_read_frames, [Globalization.CultureInfo]::InvariantCulture)
        $seconds = [double]::Parse([string]$probe.format.duration, [Globalization.CultureInfo]::InvariantCulture)
        if ($seconds -le 0) {
            throw '録画時間を取得できない'
        }
        $actualFps = $frames / $seconds
        $capturePercent = 100.0 * $actualFps / $Fps
        Write-Host ("映像検証: {0}フレーム / {1:N2}秒 / 実効{2:N2}fps（目標{3}fpsの{4:N1}%）" -f $frames, $seconds, $actualFps, $Fps, $capturePercent)
        if ($capturePercent -lt 90.0) {
            Write-Host '録画異常: 目標フレームレートの90%に達しておらぬ。録画を正常扱いしないのじゃ。' -ForegroundColor Red
            Write-Host ("録画ファイル: {0}" -f $outputFile)
            Write-Host ("ログ: {0}" -f $logFile)
            exit 2
        }
    }
    catch {
        Write-Host ("FFprobe検証失敗: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}
#endregion
Write-Host ("録画完了: {0}" -f $outputFile) -ForegroundColor Green
Write-Host ("ログ: {0}" -f $logFile)
#endregion
