# 下にヘルプがあるぞ
<#
.SYNOPSIS
    MiraBox録画用スクリプト（ハードウェアエンコード・録画専用版）じゃ。
.DESCRIPTION
    プレビュー機能を完全に排除し、純粋にMiraBoxからの映像と音声をファイルに記録するだけのシンプルなスクリプトじゃ。
    不安定な要素をなくし、確実な録画を優先したぞ。
.EXAMPLE
    .\Record-MiraBox.ps1
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

$encoderSettings = . $optionsScriptPath -HwScanMode Optional
if (-not $encoderSettings) { exit 0 }
#endregion

#region 録画処理
$outputFileName = "MiraBox_Record_$((Get-Date).ToString('yyyyMMdd_HHmmss')).mkv"

Write-Host "`n録画を開始するのじゃ！プレビューはもう出ないから、安定して記録できるはずじゃぞ！`n" -ForegroundColor Cyan

# teeやTCPの処理をすべて消し、単一ファイルへの出力に専念させるのじゃ
$ffmpegArgs = "-f dshow -video_size 1920x1080 -framerate 60 -pixel_format yuyv422 -rtbufsize 1024M -i video=`"MiraBox Video Capture`":audio=`"デジタル オーディオ インターフェイス (MiraBox Audio Capture)`" -map 0:v -map 0:a $($encoderSettings.Video) -pix_fmt nv12 $($encoderSettings.Audio) `"$outputFileName`""

Start-Process -FilePath $global:Settings.FfmpegPath -ArgumentList $ffmpegArgs -WorkingDirectory $outputDir -Wait -NoNewWindow
#endregion