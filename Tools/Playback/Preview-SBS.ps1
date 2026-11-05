<#
.SYNOPSIS
    WindowsのXREAL 1SでSBS 3D動画をffplayで全画面再生する。
.DESCRIPTION
    接続済みの3840x1080ディスプレイを探し、左右それぞれを1920x1080へ
    アスペクト比を維持して収め、Full SBSとして全画面表示する。
    PS Cameraの2560x800映像は各眼1728x1080となり、両端に黒帯が入る。
    出力済み動画は左右を交換しない。元の左右逆SBSを確認する場合だけ
    -SwapEyes を指定する。映像ファイルの書き換えや再エンコードは行わない。
.PARAMETER VideoPath
    再生する動画ファイル。-Pathという別名も使用可能。
.PARAMETER SwapEyes
    表示時だけ左右の映像を入れ替える。未変換のPS Camera SBS用。
.PARAMETER Windowed
    ウィンドウ表示。XREAL 1Sの3840x1080画面がなくても確認できる。
.PARAMETER DisplayIndex
    使用するWindows画面の番号（0から始まる）。未指定時は3840x1080の画面を自動検出。
.PARAMETER FfplayPath
    ffplay実行ファイルのパス。未指定時はPATH上のffplayを使用。
.PARAMETER ShowHelp
    -h、--helpまたは引数なしで詳しいヘルプを表示する。
.EXAMPLE
    .\Tools\Playback\Preview-SBS.ps1 -VideoPath ".\encoded_output\capture.mkv"
.EXAMPLE
    .\Tools\Playback\Preview-SBS.ps1 -VideoPath ".\raw_capture.mkv" -SwapEyes
.EXAMPLE
    .\Tools\Playback\Preview-SBS.ps1 -VideoPath ".\raw_capture.mkv" -SwapEyes -Windowed
#>
[CmdletBinding()]
param(
    [Alias('Path')][string]$VideoPath,
    [switch]$SwapEyes,
    [switch]$Windowed,
    [ValidateRange(-1, 255)][int]$DisplayIndex = -1,
    [string]$FfplayPath = 'ffplay',
    [Alias('h', 'help')][switch]$ShowHelp
)

#region Help
if ($ShowHelp -or $args -contains '--help' -or -not $VideoPath) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    exit
}
#endregion

#region Prepare
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if (-not (Test-Path -LiteralPath $VideoPath -PathType Leaf)) {
    throw "入力動画が見つからぬ: $VideoPath"
}
$VideoPath = (Resolve-Path -LiteralPath $VideoPath).ProviderPath
if ($env:OS -ne 'Windows_NT') {
    throw 'このプレビューはWindows上のXREAL 1S向けじゃ。'
}
Add-Type -AssemblyName System.Windows.Forms
$displays = @([System.Windows.Forms.Screen]::AllScreens)
if ($displays.Count -eq 0) { throw '使用可能なディスプレイが見つからぬ。' }
$selectedDisplay = $null
if ($DisplayIndex -ge 0) {
    if ($DisplayIndex -ge $displays.Count) {
        throw "画面番号 $DisplayIndex は存在しない。接続中の画面数: $($displays.Count)"
    }
    $selectedDisplay = $displays[$DisplayIndex]
}
else {
    $matchingScreens = @($displays | Where-Object { $_.Bounds.Width -eq 3840 -and $_.Bounds.Height -eq 1080 })
    if ($matchingScreens.Count -gt 0) {
        $selectedDisplay = @($matchingScreens | Sort-Object Primary)[0]
    }
}
if (-not $selectedDisplay) {
    if (-not $Windowed) {
        throw '3840x1080の3D画面が見つからぬ。XREALをFull SBSモードにするか、-Windowedを指定せよ。'
    }
    $selectedDisplay = [System.Windows.Forms.Screen]::PrimaryScreen
}
#endregion

#region Full SBS layout
$firstHalf = 'split=2[left_source][right_source];'
$left = '[left_source]crop=iw/2:ih:0:0,scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black[left];'
$right = '[right_source]crop=iw/2:ih:iw/2:0,scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black[right];'
$stack = if ($SwapEyes) { '[right][left]hstack=inputs=2,setsar=1' } else { '[left][right]hstack=inputs=2,setsar=1' }
$filter = $firstHalf + $left + $right + $stack
$title = if ($SwapEyes) { 'SBS Preview - Swapped Eyes' } else { 'SBS Preview - Encoded Output' }
$arguments = @('-hide_banner', '-loglevel', 'warning', '-autoexit', '-window_title', $title, '-vf', $filter)
if ($Windowed) {
    $arguments += @('-x', '1280', '-y', '360')
}
else {
    $arguments += @('-left', [string]$selectedDisplay.Bounds.X, '-top', [string]$selectedDisplay.Bounds.Y, '-fs')
}
$arguments += $VideoPath
Write-Host ("再生対象: {0}" -f $VideoPath)
Write-Host ("画面: {0} ({1}x{2}, {3},{4})" -f $selectedDisplay.DeviceName, $selectedDisplay.Bounds.Width, $selectedDisplay.Bounds.Height, $selectedDisplay.Bounds.X, $selectedDisplay.Bounds.Y)
Write-Host ("表示時の左右交換: {0}" -f $(if ($SwapEyes) { '有効（未変換動画）' } else { '無効（完成品）' }))
Write-Host 'ffplayを終了するにはEscまたはQを押すのじゃ。'
& $FfplayPath @arguments
if ($LASTEXITCODE -ne 0) {
    throw "ffplayが異常終了した（終了コード $LASTEXITCODE）。"
}
#endregion
