<#
.SYNOPSIS
    プレビュー付きMiraBox録画用スクリプト（無圧縮プレビュー版）じゃ。
.DESCRIPTION
    FFmpegからffplayへプレビュー映像をNUTコンテナを使って無圧縮で転送し、エンコード負荷を極限まで下げるのじゃ。
    リポジトリの共通メニューを呼び出し、ハードウェアに合わせたエンコーダーを自動で選択し、空きUDPポートを自動で割り当てるのじゃ。
.EXAMPLE
    .\Record-MiraBox-RawPreview.ps1
#>
param(
    [switch]$h,
    [switch]$help
)

if ($h -or $help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    exit
}

#region 初期設定と設定ファイル読み込み
$global:ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($global:ScriptDir)) {
    $global:ScriptDir = Get-Location
}

$configFilePath = Join-Path $global:ScriptDir "config.user.psd1"
if (Test-Path $configFilePath) {
    $global:Settings = Import-PowerShellDataFile -Path $configFilePath
}
else {
    $global:Settings = @{ FfmpegPath = "ffmpeg"; FfprobePath = "ffprobe" }
}
#endregion

#region エンコードオプションの取得
$optionsScriptPath = Join-Path $global:ScriptDir "get-ffmpegOptions.ps1"
if (-not (Test-Path $optionsScriptPath)) {
    exit 1
}

$encoderSettings = . $optionsScriptPath
if (-not $encoderSettings) {
    exit 0
}
#endregion

#region 録画とプレビュー処理
$udpClient = New-Object System.Net.Sockets.UdpClient(0)
$randomPort = [int](($udpClient.Client.LocalEndPoint) -as [System.Net.IPEndPoint]).Port
$udpClient.Close()

$outputFile = "MiraBox_Record_$((Get-Date).ToString('yyyyMMdd_HHmmss')).mkv"

$ffplayPath = "ffplay"
$ffmpegDir = Split-Path $global:Settings.FfmpegPath
if ($ffmpegDir -and (Test-Path (Join-Path $ffmpegDir "ffplay.exe"))) {
    $ffplayPath = Join-Path $ffmpegDir "ffplay.exe"
}

Start-Process -FilePath $ffplayPath -ArgumentList "-window_title `"Preview`" -x 640 -an -fflags nobuffer -flags low_delay -i udp://127.0.0.1:$randomPort?fifo_size=1000000"

$ffmpegArgs = "-f dshow -rtbufsize 1024M -i video=`"MiraBox Video Capture`":audio=`"デジタル オーディオ インターフェイス (MiraBox Audio Capture)`" -filter_complex `"[0:v]split=2[rec][pre];[pre]scale=640:-1,format=yuv420p[pre_out];[rec]format=yuv420p[rec_out]`" -map `"[rec_out]`" -map 0:a $($encoderSettings.Video) $($encoderSettings.Audio) `"$outputFile`" -map `"[pre_out]`" -c:v rawvideo -f nut udp://127.0.0.1:$randomPort"

Start-Process -FilePath $global:Settings.FfmpegPath -ArgumentList $ffmpegArgs -Wait -NoNewWindow
#endregion