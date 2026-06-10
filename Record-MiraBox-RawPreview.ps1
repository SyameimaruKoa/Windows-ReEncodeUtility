# 下にヘルプがあるぞ
<#
.SYNOPSIS
    プレビュー付きMiraBox録画用スクリプト（ハードウェアエンコード完全版）じゃ。
.DESCRIPTION
    メイン録画のハードウェア（Intel/NVIDIA/AMD）を自動検知し、
    プレビューも同じハードウェアエンコーダー（mjpeg_qsv等）にオフロードしてCPU負荷を極限まで下げる最終形態じゃ！
.EXAMPLE
    .\Record-MiraBox-Stable.ps1
#>
param([switch]$h, [switch]$help)
if ($h -or $help) { Get-Help $MyInvocation.MyCommand.Path -Detailed; exit }

#region UIユーティリティ
function Show-Menu {
    param ([string]$Title, [string[]]$Choices, [int]$DefaultIndex = 0, [switch]$NoClear)
    if (-not $NoClear) { Clear-Host }
    $currentIndex = $DefaultIndex
    $titleLines = ($Title -split "`r?`n").Count + 1
    $menuLines = $Choices.Length
    $totalLines = $titleLines + $menuLines
    try {
        $startY = $Host.UI.RawUI.CursorPosition.Y
        $windowHeight = $Host.UI.RawUI.WindowSize.Height
        if ($startY + $totalLines -ge $windowHeight - 2) {
            for ($i = 0; $i -lt $totalLines; $i++) { Write-Host "" }
            $pos = $Host.UI.RawUI.CursorPosition
            $pos.Y = [math]::Max(0, $pos.Y - $totalLines)
            $Host.UI.RawUI.CursorPosition = $pos
        }
    }
    catch {}
    $startPos = $Host.UI.RawUI.CursorPosition
    $firstDraw = $true
    $maxLen = 0
    foreach ($c in $Choices) {
        $len = 0
        foreach ($char in $c.ToCharArray()) {
            if ([int]$char -ge 0x1000) { $len += 2 } else { $len += 1 }
        }
        if ($len -gt $maxLen) { $maxLen = $len }
    }
    $padTarget = $maxLen + 6
    while ($true) {
        if (-not $firstDraw) {
            try { $Host.UI.RawUI.CursorPosition = $startPos } catch { Clear-Host }
        }
        $firstDraw = $false
        Write-Host "$Title`n"
        for ($i = 0; $i -lt $Choices.Length; $i++) {
            $line = if ($i -eq $currentIndex) { " > $($Choices[$i])" } else { "   $($Choices[$i])" }
            $currentLen = 0
            foreach ($char in $line.ToCharArray()) {
                if ([int]$char -ge 0x1000) { $currentLen += 2 } else { $currentLen += 1 }
            }
            $spacesToPad = [math]::Max(0, $padTarget - $currentLen)
            $paddedLine = $line + (" " * $spacesToPad)
            if ($i -eq $currentIndex) { Write-Host $paddedLine -ForegroundColor Black -BackgroundColor White }
            else { Write-Host $paddedLine }
        }
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        switch ($key.VirtualKeyCode) {
            38 { if ($currentIndex -gt 0) { $currentIndex-- } }
            40 { if ($currentIndex -lt ($Choices.Length - 1)) { $currentIndex++ } }
            13 { Write-Host ""; return $currentIndex }
            27 { Write-Host ""; return -1 }
        }
    }
}
Set-Item -Path function:global:Show-Menu -Value (Get-Item -LiteralPath function:Show-Menu).ScriptBlock
#endregion

#region 初期設定と設定ファイル読み込み
$global:ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($global:ScriptDir)) { $global:ScriptDir = Get-Location }
$configFilePath = Join-Path $global:ScriptDir "config.user.psd1"
if (Test-Path $configFilePath) {
    $global:Settings = Import-PowerShellDataFile -Path $configFilePath
}
else {
    $global:Settings = @{ FfmpegPath = "ffmpeg"; FfprobePath = "ffprobe" }
}
#endregion

#region 保存先の選択
$saveChoices = @("ビデオフォルダ (推奨)", "デスクトップ", "任意のフォルダを指定する")
$saveIndex = Show-Menu -Title "録画ファイルの保存先を選ぶのじゃ！" -Choices $saveChoices
$outputDir = ""
switch ($saveIndex) {
    0 { $outputDir = [Environment]::GetFolderPath('MyVideos') }
    1 { $outputDir = [Environment]::GetFolderPath('Desktop') }
    2 {
        while (-not $outputDir) {
            $inputPath = Read-Host "保存先のパスを入力するのじゃ"
            if (-not (Test-Path $inputPath)) {
                try { New-Item -Path $inputPath -ItemType Directory -ErrorAction Stop | Out-Null }
                catch { Write-Host "フォルダ作成失敗: $_" -ForegroundColor Yellow; $inputPath = "" }
            }
            $outputDir = $inputPath
        }
    }
    default { exit 0 }
}
#endregion

#region エンコードオプションの取得
$optionsScriptPath = Join-Path $global:ScriptDir "get-ffmpegOptions.ps1"
if (-not (Test-Path $optionsScriptPath)) { exit 1 }
$encoderSettings = . $optionsScriptPath
if (-not $encoderSettings) { exit 0 }
#endregion

#region プレビューエンコーダーの動的判定
$previewFormat = "mpegts"
$previewVideo = "-c:v libx264 -preset ultrafast -tune zerolatency" # デフォルトのフォールバック

if ($encoderSettings.Video -match "qsv") {
    Write-Host "`nIntel QSVを検出したぞ！神コーデック『mjpeg_qsv』をプレビューに降臨させるのじゃ！" -ForegroundColor Green
    $previewVideo = "-c:v mjpeg_qsv -q:v 5"
    $previewFormat = "mjpeg"
}
elseif ($encoderSettings.Video -match "nvenc") {
    Write-Host "`nNVIDIA NVENCを検出したぞ！超低遅延の『h264_nvenc』を使うのじゃ！" -ForegroundColor Green
    $previewVideo = "-c:v h264_nvenc -preset p1 -tune ull -b:v 2M"
}
elseif ($encoderSettings.Video -match "amf") {
    Write-Host "`nAMD AMFを検出したぞ！爆速の『h264_amf』を使うのじゃ！" -ForegroundColor Green
    $previewVideo = "-c:v h264_amf -usage ultrafast -b:v 2M"
}
#endregion

#region 録画とプレビュー処理
$udpClient = New-Object System.Net.Sockets.UdpClient(0)
$randomPort = [int](($udpClient.Client.LocalEndPoint) -as [System.Net.IPEndPoint]).Port
$udpClient.Close()

Write-Host "ポート番号 $randomPort で安全に通信を開始するのじゃ！`n" -ForegroundColor Cyan

$outputFileName = "MiraBox_Record_$((Get-Date).ToString('yyyyMMdd_HHmmss')).mkv"
$outputFilePath = Join-Path $outputDir $outputFileName

$ffmpegCmd = Get-Command -Name $global:Settings.FfmpegPath -ErrorAction SilentlyContinue
$ffmpegDir = ""
if ($ffmpegCmd) {
    if ($ffmpegCmd.Source) { $ffmpegDir = Split-Path $ffmpegCmd.Source }
    elseif ($ffmpegCmd.Path) { $ffmpegDir = Split-Path $ffmpegCmd.Path }
}

$ffplayPath = "ffplay"
if ($ffmpegDir -and (Test-Path (Join-Path $ffmpegDir "ffplay.exe"))) {
    $ffplayPath = Join-Path $ffmpegDir "ffplay.exe"
}

$ffplayArgsArray = @("-window_title", "Preview", "-x", "640", "-an", "-fflags", "nobuffer", "-flags", "low_delay", "-i", "udp://127.0.0.1:$randomPort")
$ffplayProc = Start-Process -FilePath $ffplayPath -ArgumentList $ffplayArgsArray -PassThru

Start-Sleep -Seconds 1

try {
    # 動的判定した $previewVideo と $previewFormat をコマンドに組み込むのじゃ！
    $ffmpegArgs = "-f dshow -rtbufsize 1024M -i video=`"MiraBox Video Capture`":audio=`"デジタル オーディオ インターフェイス (MiraBox Audio Capture)`" -filter_complex `"[0:v]split=2[rec][pre];[pre]scale=640:-1,format=yuv420p,fps=60,setpts=PTS-STARTPTS[pre_out];[rec]format=yuv420p[rec_out]`" -map `"[rec_out]`" -map 0:a $($encoderSettings.Video) $($encoderSettings.Audio) `"$outputFilePath`" -map `"[pre_out]`" $previewVideo -f $previewFormat udp://127.0.0.1:$randomPort"
    Start-Process -FilePath $global:Settings.FfmpegPath -ArgumentList $ffmpegArgs -Wait -NoNewWindow
}
finally {
    if ($ffplayProc -and -not $ffplayProc.HasExited) {
        Stop-Process -Id $ffplayProc.Id -Force -ErrorAction SilentlyContinue
    }
}
#endregion