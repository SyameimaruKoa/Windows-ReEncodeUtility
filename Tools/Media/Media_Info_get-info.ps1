#region ヘルプ
<#
.SYNOPSIS
    メディアファイルの情報を表示します（ffprobe/ffmpegを使用）。

.DESCRIPTION
    指定したメディアファイルごとに、一般情報（hide_banner出力）を表示します。
    ffprobe が利用可能な場合は、r_frame_rate と avg_frame_rate の詳細、
    さらに先頭10フレームの表示時間からVFR傾向の目安も併せて表示します。
    また、映像の走査方式（インターレース／プログレッシブ）とフィールド順、
    先頭10フレームの走査方式フラグも表示します。
    FFmpegで複数区間の3:2プルダウン周期を解析し、逆テレシネの要否を推定します。
    簡易解析ではidetを最大4区間、decimateを6区間（混在時は中間を追加して最大11区間）走査します。
    Shift起動または -FullAnalysis で全編解析します。
    FFplayで元映像・逆テレシネ・Bwdif・nnedi3・差分を比較する説明付きボタンを、3:2プル判定より先に表示します。

.PARAMETER filePaths
    情報を表示したいメディアファイルのパスを1つ以上指定します。

.PARAMETER AnalysisFrames
    通常解析で各区間から調べるフレーム数（既定180、60～1200）。

.PARAMETER FullAnalysis
    Shift起動と同様に全編解析を有効化します。

.PARAMETER SkipCadenceAnalysis
    負荷の大きい実映像解析をスキップします。

.PARAMETER Help
    詳細な使い方を表示します。-h も使用できます。

.EXAMPLE
    PS> .\Media_Info_get-info.ps1 video.mp4 audio.m4a
    2つのファイルの一般情報と、可能であればフレームレート詳細を表示します。

.EXAMPLE
    PS> .\Media_Info_get-info.ps1 -FullAnalysis '.\動画[01].m2ts'
    全フレームを解析します。

.EXAMPLE
    PS> .\Media_Info_get-info.ps1 -AnalysisFrames 300 '.\動画[01].mkv'
    動画全体の約25%・75%地点を中心に各300フレーム解析します。

.EXAMPLE
    PS> .\Media_Info_get-info.ps1 -SkipCadenceAnalysis '.\動画[01].mkv'
    旧来の高速な情報表示だけを行います。

.EXAMPLE
    PS> .\Media_Info_get-info.ps1 -h
    ヘルプを表示します。

.NOTES
    ・ffprobe または ffmpeg が PATH に通っている必要があります。
    ・ドラッグ＆ドロップでも実行できます。
    ・Shiftを押したまま起動すると全編解析します。
    ・判定はあくまで映像からの推定です。2:2などの完全判定は対象外です。
    ・FFplay比較は Windows では Windows Forms、Linux では GTK のボタンGUIで表示します。GTK が無い場合はコマンド例、ffplay が無い環境や headless 環境では比較のみスキップします。
#>
#endregion

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$filePaths,

    [ValidateRange(60, 1200)]
    [int]$AnalysisFrames = 180,

    [switch]$FullAnalysis,

    [switch]$SkipCadenceAnalysis,

    [Alias('h')]
    [switch]$Help
)

# 標準入力がリダイレクトされている環境（CI等）ではキー待ちを省略する。
$interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

if ($Help -or -not $filePaths -or $filePaths.Count -eq 0) {
    Get-Help -Name $PSCommandPath -Detailed
    return
}

# 起動直後にShift状態を検出。押し続けられない場合は -FullAnalysis で代用できる。
$runFullAnalysis = [bool]$FullAnalysis
if (-not $runFullAnalysis) {
    try {
        if (-not ('MediaInfoKeyboard' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MediaInfoKeyboard {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int virtualKey);
}
'@ -ErrorAction Stop
        }
        $runFullAnalysis = (([MediaInfoKeyboard]::GetAsyncKeyState(0x10) -band 0x8000) -ne 0)
    }
    catch {
        # Windows以外ではShift検出を省略する
    }
}

#region 3:2プルダウン解析（共通モジュール）

$telecineModulePath = Join-Path $PSScriptRoot '..\..\Modules\TelecineDetector.ps1'
if (Test-Path -LiteralPath $telecineModulePath -PathType Leaf) {
    . $telecineModulePath
}
else {
    Write-Host '[WARN] Modules\TelecineDetector.ps1 が見つからないため、3:2判定をスキップします。' -ForegroundColor Yellow
}

function Show-TelecineAssessment {
    param(
        [string]$File,
        [string]$FFmpegExecutable,
        [string]$FFprobeExecutable,
        [int]$Frames,
        [bool]$Full
    )

    Write-Host ''
    Write-Host '[ プルダウン・逆テレシネ判定（実映像解析） ]' -ForegroundColor Cyan
    if (-not (Get-Command Get-TelecineAssessment -ErrorAction SilentlyContinue)) {
        Write-Host '判定モジュールがないため解析できないのじゃ。' -ForegroundColor Yellow
        return
    }

    $assessment = Get-TelecineAssessment -File $File -FFmpegExecutable $FFmpegExecutable -FFprobeExecutable $FFprobeExecutable -Frames $Frames -Full $Full
    $windowCount = if ($assessment.Meta.AvgFps -gt 0) { 2 } else { 1 }
    $decimateText = if ($assessment.DecimateReports.Count -gt 0) { "decimate最大$($assessment.DecimateReports.Count)区間" } else { 'decimate解析なし' }
    $modeText = if ($Full) { '全編解析' } else { "簡易解析（idet最大${windowCount}区間 / $decimateText × $Frames フレーム）" }
    Write-Host "モード: $modeText" -ForegroundColor Cyan

    $i = 0
    foreach ($report in $assessment.IdetReports) {
        $i++
        $description = if ($report.Telecine32) { '3:2周期あり' } else { '3:2周期は未検出' }
        $matching = if (($report.Top + $report.Bottom) -ge 10) { '{0:P0}' -f $report.Consistency } else { '算出保留（反復が少ない）' }
        Write-Host "idet[$i] : $description / Top=$($report.Top) / Bottom=$($report.Bottom) / 周期一致=$matching"
    }
    $i = 0
    foreach ($report in $assessment.DecimateReports) {
        $startText = if ($i -lt $assessment.DecimateStarts.Count) { "$($assessment.DecimateStarts[$i])秒" } else { '位置不明' }
        $i++
        $description = if ($report.Periodic32) { '3:2周期あり' } else { '3:2周期は未検出' }
        Write-Host "decimate[$i]($startText) : $description / 周期=$($report.Cycles) / 最小diff=$($report.DropIsMin) / 低比率=$($report.LowRatio) / 比率=$($report.RatioMedian.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture))"
    }

    $classified = 0
    $progressive = 0
    $interlaced = 0
    foreach ($report in $assessment.IdetReports) {
        $classified += $report.Classified
        $progressive += $report.Progressive
        $interlaced += $report.Interlaced
    }
    $progFraction = if ($classified -gt 0) { $progressive / [double]$classified } else { 0.0 }
    $interlacedFraction = if ($classified -gt 0) { $interlaced / [double]$classified } else { 0.0 }
    Write-Host "判定区間=$($assessment.IdetReports.Count) / 3:2検出=$(@($assessment.IdetReports | Where-Object { $_.Telecine32 }).Count) / 周期重複=$(@($assessment.DecimateReports | Where-Object { $_.Periodic32 }).Count)"
    Write-Host ("実映像の傾向: Progressive={0:P0} / Interlaced={1:P0}" -f $progFraction, $interlacedFraction)

    $color = if ($assessment.Verdict -match '^推奨') { 'Green' } elseif ($assessment.Verdict -match '^不要') { 'Green' } else { 'Yellow' }
    Write-Host "逆テレシネ判定: $($assessment.Verdict)（確信度 $($assessment.Confidence)%）" -ForegroundColor $color
    Write-Host '  根拠:'
    foreach ($line in ($assessment.Evidence -split "`n")) {
        Write-Host "    $line"
    }
    if ($assessment.RecommendedFilter) {
        Write-Host "  処理候補: $($assessment.RecommendedFilter)"
    }
    if ($assessment.Telecine32) {
        Write-Host '  縞・フレーム欠落は映像でも確認するのじゃ。'
    }
    Write-Host 'この判定は映像の特徴からの推定であり、全編解析でも完全保証ではないぞ。'
}

#endregion

#region FFplayによるフィルター確認

$script:previewNnediFilter = $null
$script:previewNnediBobFilter = $null

function Resolve-PreviewNnediFilter {
    $projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $weightsFile = Join-Path $projectRoot 'nnedi3_weights.bin'
    if (-not (Test-Path -LiteralPath $weightsFile -PathType Leaf)) {
        Write-Host 'nnedi用ウェイトファイル(nnedi3_weights.bin)をダウンロードします...' -ForegroundColor Cyan
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/dubhater/vapoursynth-nnedi3/master/src/nnedi3_weights.bin' -OutFile $weightsFile -UseBasicParsing
        }
        catch {
            Write-Host "ダウンロード失敗。nnedi比較は使えません: $_" -ForegroundColor Yellow
            return
        }
    }
    $escapedWeights = $weightsFile.Replace('\', '/').Replace(':', '\:')
    $script:previewNnediFilter = "nnedi=weights='$escapedWeights'"
    $script:previewNnediBobFilter = "nnedi=weights='$escapedWeights':field=tf"
}

function Get-PreviewNnediModes {
    if (-not $script:previewNnediFilter) { return @() }
    return @(
        @{
            Name        = '9  nnedi3（30p・高品質）'
            Filter      = $script:previewNnediFilter
            Rate        = 1.0
            Bob         = $false
            Description = 'nnedi3_weights.binの学習ウェイトで縞を消し、約30pで見る。Bwdifより高品質だが非常に重い。'
        },
        @{
            Name        = '10  nnedi3 Bob（60p・高品質・最重）'
            Filter      = $script:previewNnediBobFilter
            Rate        = 2.0
            Bob         = $true
            Description = '両フィールドから2枚を生成し、約60pの動きを残す。高品質だがリアルタイム再生が厳しい。軽さ優先なら5のBwdif Bobを使う。'
        }
    )
}

# Linux では GTK のボタンGUIで比較モードを選択させる。
function Show-GtkComparison {
    param(
        [string]$VideoPath,
        [string]$FFprobeExecutable,
        [string]$FFplayExecutable
    )

    if (-not ('GtkNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GtkNative {
    [DllImport("libgtk-3.so.0")] public static extern void gtk_init(ref int argc, ref IntPtr argv);
    [DllImport("libgtk-3.so.0")] public static extern IntPtr gtk_window_new(int type);
    [DllImport("libgtk-3.so.0")] public static extern void gtk_window_set_title(IntPtr w, string title);
    [DllImport("libgtk-3.so.0")] public static extern void gtk_window_set_default_size(IntPtr w, int width, int height);
    [DllImport("libgtk-3.so.0")] public static extern IntPtr gtk_vbox_new(bool homogeneous, int spacing);
    [DllImport("libgtk-3.so.0")] public static extern void gtk_container_add(IntPtr c, IntPtr w);
    [DllImport("libgtk-3.so.0")] public static extern void gtk_container_set_border_width(IntPtr c, uint width);
    [DllImport("libgtk-3.so.0")] public static extern void gtk_box_pack_start(IntPtr box, IntPtr child, bool expand, bool fill, uint padding);
    [DllImport("libgtk-3.so.0")] public static extern IntPtr gtk_button_new_with_label(string label);
    [DllImport("libgtk-3.so.0")] public static extern IntPtr gtk_label_new(string text);
    [DllImport("libgtk-3.so.0")] public static extern void gtk_label_set_line_wrap(IntPtr label, bool wrap);
    [DllImport("libgtk-3.so.0")] public static extern void gtk_widget_show_all(IntPtr w);
    [DllImport("libgtk-3.so.0")] public static extern void gtk_main();
    [DllImport("libgtk-3.so.0")] public static extern void gtk_main_quit();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void SignalCallback(IntPtr widget, IntPtr data);
    [DllImport("libgtk-3.so.0")] public static extern ulong g_signal_connect_data(IntPtr instance, string signal, SignalCallback callback, IntPtr data, IntPtr destroy, int flags);
}
'@
    }

    # Windows 版と同じく冒頭3秒の PTS から入力 fps を推定する。
    $observedFps = 0.0
    if ($FFprobeExecutable) {
        $ptsLines = @(& $FFprobeExecutable -v error -select_streams v:0 -read_intervals '%+3' -show_entries frame=best_effort_timestamp_time -of 'csv=p=0' -i $VideoPath 2>$null)
        if ($LASTEXITCODE -eq 0 -and $ptsLines.Count -ge 12) {
            $stamps = [System.Collections.Generic.List[double]]::new()
            foreach ($line in $ptsLines) {
                $value = [double]0.0
                if ([double]::TryParse(([string]$line).Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
                    $stamps.Add($value)
                }
            }
            $deltas = [System.Collections.Generic.List[double]]::new()
            for ($i = 1; $i -lt $stamps.Count; $i++) {
                $delta = $stamps[$i] - $stamps[$i - 1]
                if ($delta -gt 0.001 -and $delta -lt 1) { $deltas.Add($delta) }
            }
            if ($deltas.Count -ge 10) {
                $sorted = @($deltas.ToArray() | Sort-Object)
                $medianDelta = [double]$sorted[[int][math]::Floor($sorted.Count / 2)]
                if ($medianDelta -gt 0) { $observedFps = 1.0 / $medianDelta }
            }
        }
    }

    $modes = @(
        @{ Name = '1  元映像'; Filter = ''; Rate = 1.0; Bob = $false; Description = '加工しない映像を見て、元の縞模様やカクつきを確認する。' },
        @{ Name = '2  逆テレシネ'; Filter = 'fieldmatch=order=tff,decimate'; Rate = 0.8; Bob = $false; Description = '3:2プルダウンを戻し、約24pの自然な動きを復元できるか確認する。' },
        @{ Name = '3  30pの重複を除去（24p系）'; Filter = 'decimate=cycle=5'; Rate = 0.8; Bob = $false; Description = 'プログレッシブ30pの周期重複を除く。フィールド再構成は行わない。' },
        @{ Name = '4  Bwdif（30p系 / send_frame）'; Filter = 'bwdif=mode=send_frame:parity=tff:deint=interlaced'; Rate = 1.0; Bob = $false; Description = '1入力フレームから1枚を生成し、約30pのまま縞を取り除く。' },
        @{ Name = '5  Bwdif Bob（60p系 / send_field）'; Filter = 'bwdif=mode=send_field:parity=tff:deint=interlaced'; Rate = 2.0; Bob = $true; Description = '各フィールドから1枚ずつ生成し、約60pの動きを残せるか確認する。' },
        @{ Name = '6  逆テレシネ + Bwdif'; Filter = 'fieldmatch=order=tff:combmatch=full,bwdif=mode=send_frame:parity=tff:deint=interlaced,decimate'; Rate = 0.8; Bob = $false; Description = '逆テレシネ後に残る縞も解除し、約24pで自然に再生できるか見る。' },
        @{ Name = '7  隣接フレームの差分（元映像）'; Filter = 'tblend=all_mode=difference'; Rate = 1.0; Bob = $false; Description = '元の隣接フレームの差分を表示し、縞や画素の変化を調べる。' },
        @{ Name = '8  隣接フレームの差分（Bob後）'; Filter = 'bwdif=mode=send_field:parity=tff:deint=interlaced,tblend=all_mode=difference'; Rate = 2.0; Bob = $true; Description = 'Bob後の隣接フレームの差分を表示し、点滅や補間差を見る。' }
    )
    $nnediModes = Get-PreviewNnediModes
    if ($nnediModes.Count -gt 0) { $modes += $nnediModes }

    $fitScreen = "scale='min(1880,iw)':'min(1000,ih)':force_original_aspect_ratio=decrease"
    $buttons = @()
    foreach ($mode in $modes) {
        $suffix = ''
        if ($observedFps -gt 0) {
            if ($mode.Rate -lt 1.0 -and ($observedFps -lt 29.5 -or $observedFps -gt 30.7)) {
                $suffix = ' | 30fps系素材向け'
            }
            else {
                $rateValue = ($observedFps * [double]$mode.Rate).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
                $suffix = " | 約$rateValue fps"
                if ($mode.Bob) { $suffix += '（i判定時）' }
            }
        }
        $buttons += @{
            label = $mode.Name + $suffix
            description = $mode.Description
            filter = $(if ($mode.Filter) { "$($mode.Filter),$fitScreen" } else { $fitScreen })
        }
    }

    $argc = 0
    $argv = [IntPtr]::Zero
    [GtkNative]::gtk_init([ref]$argc, [ref]$argv)

    $window = [GtkNative]::gtk_window_new(0)
    [GtkNative]::gtk_window_set_title($window, 'FFplay比較 - ' + [IO.Path]::GetFileName($VideoPath))
    [GtkNative]::gtk_window_set_default_size($window, 760, 980)
    [GtkNative]::gtk_container_set_border_width($window, 12)
    $box = [GtkNative]::gtk_vbox_new($false, 4)
    [GtkNative]::gtk_container_add($window, $box)

    $inputRateLabel = if ($observedFps -gt 0) {
        '冒頭PTSから推定した入力fps: ' + $observedFps.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
    }
    else { '入力fps: 時刻情報から推定できませんでした' }
    $infoText = $inputRateLabel + [Environment]::NewLine + '各モードのfpsは推定出力値（実描画FPSではありません）。'
    $infoLabel = [GtkNative]::gtk_label_new($infoText)
    [GtkNative]::gtk_label_set_line_wrap($infoLabel, $true)
    [GtkNative]::gtk_box_pack_start($box, $infoLabel, $false, $false, 6)

    foreach ($item in $buttons) {
        $button = [GtkNative]::gtk_button_new_with_label($item.label)
        $exe = $FFplayExecutable
        $quoteArg = { param([string]$v) '"' + $v + '"' }
        $arguments = @(
            '-hide_banner', '-an', '-sn',
            '-window_title', (& $quoteArg $item.label),
            '-vf', (& $quoteArg $item.filter),
            '-i', (& $quoteArg $VideoPath)
        )
        $callback = [GtkNative+SignalCallback]({
            param($w, $d)
            try {
                Start-Process -FilePath $exe -ArgumentList $arguments -ErrorAction Stop
            }
            catch {
                # GTK のコールバック内で例外を投げると PowerShell 全体が終了するため握る。
            }
        }.GetNewClosure())
        [void][GtkNative]::g_signal_connect_data($button, 'clicked', $callback, [IntPtr]::Zero, [IntPtr]::Zero, 0)
        [GtkNative]::gtk_box_pack_start($box, $button, $false, $false, 0)

        $note = [GtkNative]::gtk_label_new($item.description)
        [GtkNative]::gtk_label_set_line_wrap($note, $true)
        [GtkNative]::gtk_box_pack_start($box, $note, $false, $false, 4)
    }

    $helpText = '各ボタンでFFplayが起動する。S: 1コマ進む　Space: 再生/停止　左右: 10秒移動　Q/Esc: 終了' + [Environment]::NewLine + '差分は変化が少ないほど暗くなる。静止場面や圧縮ノイズに注意。'
    $helpLabel = [GtkNative]::gtk_label_new($helpText)
    [GtkNative]::gtk_label_set_line_wrap($helpLabel, $true)
    [GtkNative]::gtk_box_pack_start($box, $helpLabel, $false, $false, 8)

    $quit = [GtkNative+SignalCallback]{ param($w, $d) [GtkNative]::gtk_main_quit() }
    [void][GtkNative]::g_signal_connect_data($window, 'destroy', $quit, [IntPtr]::Zero, [IntPtr]::Zero, 0)

    Write-Host ''
    Write-Host '[ FFplay比較 (GTK) ]' -ForegroundColor Cyan
    Write-Host 'ボタンを押すと別ウィンドウでFFplayが起動する。'

    [GtkNative]::gtk_widget_show_all($window)
    [GtkNative]::gtk_main()
}

function Show-FFplayVerification {
    param([string]$VideoPath, [string]$FFprobeExecutable)

    $ffplay = Get-Command ffplay -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $headless = $env:OS -ne 'Windows_NT' -and -not $env:DISPLAY -and -not $env:WAYLAND_DISPLAY
    if (-not $ffplay -or $headless) {
        $reason = if (-not $ffplay) { 'ffplayが見つからない' } else { 'ディスプレイがなくffplayを起動できない（headless）' }
        Write-Host ($reason + '。FFplay比較はスキップするのじゃ。') -ForegroundColor Yellow
        return
    }
    if ($FFprobeExecutable) {
        $videoStream = & $FFprobeExecutable -v error -select_streams v:0 -show_entries stream=index -of 'csv=p=0' -i $VideoPath
        if ($LASTEXITCODE -eq 0 -and -not $videoStream) { return }
    }

    Resolve-PreviewNnediFilter

    # Media_Action_play.bat の既定の画面サイズ調整を維持する
    $screenWidth = 1920
    $screenHeight = 1080
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $screenWidth = $area.Width
        $screenHeight = $area.Height
    }
    catch {
        # Linux で GTK が使えればボタンGUIを出す。
        if ($env:OS -ne 'Windows_NT') {
            try {
                Show-GtkComparison -VideoPath $VideoPath -FFprobeExecutable $FFprobeExecutable -FFplayExecutable $ffplay.Path
                return
            }
            catch {
                # GTK が使えない場合はコマンド例にフォールバックする。
            }
        }
        # Windows Forms も GTK も使えない環境では、比較用コマンドを表示する。
        Write-Host 'Windows Forms も GTK も使えないため、以下のコマンドでFFplay比較ができるのじゃ。' -ForegroundColor Yellow
        $cliQuote = { param([string]$v) "'" + $v.Replace("'", "''") + "'" }
        $cliFit = "scale='min(1880,iw)':'min(1000,ih)':force_original_aspect_ratio=decrease"
        $cliModes = @(
            @{ Name = '1  元映像'; Filter = '' },
            @{ Name = '2  逆テレシネ'; Filter = 'fieldmatch=order=tff,decimate' },
            @{ Name = '3  30pの重複を除去（24p系）'; Filter = 'decimate=cycle=5' },
            @{ Name = '4  Bwdif（30p系 / send_frame）'; Filter = 'bwdif=mode=send_frame:parity=tff:deint=interlaced' },
            @{ Name = '5  Bwdif Bob（60p系 / send_field）'; Filter = 'bwdif=mode=send_field:parity=tff:deint=interlaced' },
            @{ Name = '6  逆テレシネ + Bwdif'; Filter = 'fieldmatch=order=tff:combmatch=full,bwdif=mode=send_frame:parity=tff:deint=interlaced,decimate' },
            @{ Name = '7  隣接フレームの差分（元映像）'; Filter = 'tblend=all_mode=difference' },
            @{ Name = '8  隣接フレームの差分（Bob後）'; Filter = 'bwdif=mode=send_field:parity=tff:deint=interlaced,tblend=all_mode=difference' }
        )
        $nnediModes = Get-PreviewNnediModes
        if ($nnediModes.Count -gt 0) { $cliModes += $nnediModes }
        Write-Host ''
        Write-Host '[ FFplay比較コマンド（Windows Forms 非対応環境用） ]' -ForegroundColor Cyan
        foreach ($cliMode in $cliModes) {
            $cliFilter = if ($cliMode.Filter) { "$($cliMode.Filter),$cliFit" } else { $cliFit }
            Write-Host ('  ' + $cliMode.Name + ': ' + (& $cliQuote $ffplay.Path) + ' -hide_banner -an -sn -vf ' + (& $cliQuote $cliFilter) + ' -i ' + (& $cliQuote $VideoPath))
        }
        return
    }
    $maxWidth = [math]::Max(64, $screenWidth - 40)
    $maxHeight = [math]::Max(64, $screenHeight - 80)
    $fitScreen = "scale='min($maxWidth,iw)':'min($maxHeight,ih)':force_original_aspect_ratio=decrease"

    # 60i素材ではavg_frame_rateがフィールド側の59.94を示すこともある。
    # そこで冒頭3秒の復号後PTS間隔から実際の入力フレーム頻度を推定する。
    $observedFps = 0.0
    if ($FFprobeExecutable) {
        $ptsLines = @(& $FFprobeExecutable -v error -select_streams v:0 -read_intervals '%+3' -show_entries frame=best_effort_timestamp_time -of 'csv=p=0' -i $VideoPath 2>$null)
        if ($LASTEXITCODE -eq 0 -and $ptsLines.Count -ge 12) {
            $stamps = [System.Collections.Generic.List[double]]::new()
            foreach ($line in $ptsLines) {
                $value = [double]0.0
                if ([double]::TryParse(([string]$line).Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
                    $stamps.Add($value)
                }
            }
            $deltas = [System.Collections.Generic.List[double]]::new()
            for ($i = 1; $i -lt $stamps.Count; $i++) {
                $delta = $stamps[$i] - $stamps[$i - 1]
                if ($delta -gt 0.001 -and $delta -lt 1) { $deltas.Add($delta) }
            }
            if ($deltas.Count -ge 10) {
                $sorted = @($deltas.ToArray() | Sort-Object)
                $medianDelta = [double]$sorted[[int][math]::Floor($sorted.Count / 2)]
                if ($medianDelta -gt 0) { $observedFps = 1.0 / $medianDelta }
            }
        }
    }

    # 確認用フィルターは短く保つ。59.94pと29.97pのBwdifを両方用意。
    $modes = @(
        @{ Name = '1  元映像'; Filter = ''; Rate = 1.0; Bob = $false; Description = '加工しない映像を見て、元の縞模様やカクつきを確認する。' },
        @{ Name = '2  逆テレシネ'; Filter = 'fieldmatch=order=tff,decimate'; Rate = 0.8; Bob = $false; Description = '3:2プルダウンを戻し、約24pの自然な動きを復元できるか確認する。' },
        @{ Name = '3  30pの重複を除去（24p系）'; Filter = 'decimate=cycle=5'; Rate = 0.8; Bob = $false; Description = 'プログレッシブ30pの周期重複を除く。フィールド再構成は行わない。' },
        @{ Name = '4  Bwdif（30p系 / send_frame）'; Filter = 'bwdif=mode=send_frame:parity=tff:deint=interlaced'; Rate = 1.0; Bob = $false; Description = '1入力フレームから1枚を生成し、約30pのまま縞を取り除く。' },
        @{ Name = '5  Bwdif Bob（60p系 / send_field）'; Filter = 'bwdif=mode=send_field:parity=tff:deint=interlaced'; Rate = 2.0; Bob = $true; Description = '各フィールドから1枚ずつ生成し、約60pの動きを残せるか確認する。' },
        @{ Name = '6  逆テレシネ + Bwdif'; Filter = 'fieldmatch=order=tff:combmatch=full,bwdif=mode=send_frame:parity=tff:deint=interlaced,decimate'; Rate = 0.8; Bob = $false; Description = '逆テレシネ後に残る縞も解除し、約24pで自然に再生できるか見る。' },
        @{ Name = '7  隣接フレームの差分（元映像）'; Filter = 'tblend=all_mode=difference'; Rate = 1.0; Bob = $false; Description = '元の隣接フレームの差分を表示し、縞や画素の変化を調べる。' },
        @{ Name = '8  隣接フレームの差分（Bob後）'; Filter = 'bwdif=mode=send_field:parity=tff:deint=interlaced,tblend=all_mode=difference'; Rate = 2.0; Bob = $true; Description = 'Bob後の隣接フレームの差分を表示し、点滅や補間差を見る。' }
    )
    $nnediModes = Get-PreviewNnediModes
    if ($nnediModes.Count -gt 0) { $modes += $nnediModes }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'FFplay比較 - ' + [IO.Path]::GetFileName($VideoPath)
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(690, 930)
    $form.MinimumSize = New-Object System.Drawing.Size(690, 930)
    $form.MaximizeBox = $false

    $info = New-Object System.Windows.Forms.Label
    $info.SetBounds(15, 12, 650, 42)
    $inputRateLabel = if ($observedFps -gt 0) {
        '冒頭PTSから推定した入力fps: ' + $observedFps.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
    }
    else { '入力fps: 時刻情報から推定できませんでした' }
    $info.Text = $inputRateLabel + [Environment]::NewLine + '各モードのfpsは推定出力値（実描画FPSではありません）。'
    $form.Controls.Add($info)

    $psQuote = { param([string]$v) "'" + $v.Replace("'", "''") + "'" }
    $index = 0
    foreach ($mode in $modes) {
        $suffix = ''
        if ($observedFps -gt 0) {
            if ($mode.Rate -lt 1.0 -and ($observedFps -lt 29.5 -or $observedFps -gt 30.7)) {
                # 逆テレシネとプログレッシブ重複除去は30fps前後の素材向け。
                $suffix = ' | 30fps系素材向け'
            }
            else {
                $rateValue = ($observedFps * [double]$mode.Rate).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
                $suffix = " | 約$rateValue fps"
                if ($mode.Bob) { $suffix += '（i判定時）' }
            }
        }

        $button = New-Object System.Windows.Forms.Button
        $button.SetBounds(15, (68 + $index * 74), 650, 32)
        $button.Text = $mode.Name + $suffix
        $button.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $button.UseVisualStyleBackColor = $true

        $filter = if ($mode.Filter) { "$($mode.Filter),$fitScreen" } else { $fitScreen }
        $execution = '& ' + (& $psQuote $ffplay.Path) +
            ' -hide_banner -an -sn -window_title ' + (& $psQuote ($mode.Name + $suffix)) +
            ' -vf ' + (& $psQuote $filter) +
            ' -i ' + (& $psQuote $VideoPath)
        $button.Tag = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($execution))
        $button.Add_Click({
            param($sender, $eventArgs)
            # 元のログへffplayの出力を混ぜないよう別ターミナルで起動
            $pwshExe = (Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue).Path
            if (-not $pwshExe) { $pwshExe = Join-Path $PSHOME 'pwsh.exe' }
            Start-Process -FilePath $pwshExe -ArgumentList ("-NoProfile -EncodedCommand " + [string]$sender.Tag) -WindowStyle Normal
        })
        $form.Controls.Add($button)

        # 各ボタンの目的を一文で示す（ツールチップだけに依存しない）。
        $explanation = New-Object System.Windows.Forms.Label
        $explanation.SetBounds(28, (103 + $index * 74), 630, 27)
        $explanation.Text = [string]$mode.Description
        $form.Controls.Add($explanation)
        $index++
    }

    $help = New-Object System.Windows.Forms.Label
    $help.SetBounds(15, 820, 650, 55)
    $help.Text = 'S: 1コマ進む　Space: 再生/停止　左右: 10秒移動　Q/Esc: 終了' +
        [Environment]::NewLine +
        '差分は変化が少ないほど暗くなる。静止場面や圧縮ノイズに注意。'
    $form.Controls.Add($help)

    Write-Host ''
    Write-Host '[ FFplay比較ボタン ]' -ForegroundColor Cyan
    Write-Host 'クリックすると別のPowerShellウィンドウでFFplayが起動する。'
    Write-Host '累積フレーム番号は表示しない。fpsは冒頭のPTSからの推定値。'
    [void]$form.ShowDialog()
    $form.Dispose()
}

#endregion FFplayによるフィルター確認

# まずはffprobeかffmpegが使えるか確認するのじゃ
$ffprobePath = Get-Command -Name ffprobe -ErrorAction SilentlyContinue | Select-Object -First 1
$ffmpegPath = Get-Command -Name ffmpeg -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $ffprobePath -and -not $ffmpegPath) {
    Write-Host "エラー: ffprobe も ffmpeg も見つからんかったぞ！ Pathが通っているか確認せい！" -ForegroundColor Red
    if ($interactive) { Read-Host "何かキーを押すと終了する" }
    exit
}

foreach ($filePath in $filePaths) {
    if (Test-Path -LiteralPath $filePath -PathType Leaf) {
        Write-Host "--- $($filePath) の詳細情報 ---" -ForegroundColor Yellow

        # === 通常情報表示 ===
        Write-Host "[ 通常情報 ]" -ForegroundColor Cyan
        if ($ffprobePath) {
            # ffprobeがあればそちらで表示
            & $ffprobePath.Path -hide_banner -i $filePath
        }
        else {
            # なければffmpegで代用
            & $ffmpegPath.Path -hide_banner -i $filePath
        }
        Write-Host ""

        # === フレームレート詳細表示 (ffprobeがある場合のみ) ===
        if ($ffprobePath) {
            Write-Host "[ フレームレート詳細 ]" -ForegroundColor Cyan
            # ストリーム情報から分数表記のフレームレートを取得
            $streamInfo = & $ffprobePath.Path -v error -select_streams v:0 -show_entries "stream=r_frame_rate,avg_frame_rate" -of "default=noprint_wrappers=1:nokey=0" -i $filePath
            Write-Host $streamInfo

            # 最初の10フレームの表示時間を調べてVFRかどうかを判断
            Write-Host "--- 最初の10フレームの表示時間(秒) ---"
            $frameDurations = @(& $ffprobePath.Path -v error -select_streams v:0 -show_entries "frame=duration_time" -of "default=noprint_wrappers=1:nokey=1" -read_intervals "%+2" -i $filePath) | Select-Object -First 10
            Write-Host $frameDurations
            Write-Host "(これはフレームdurationの参考値。VFRの厳密判定にはPTS間隔の確認が必要じゃ)"

            # === 走査方式（インターレース／プログレッシブ） ===
            Write-Host ""
            Write-Host "[ 走査方式 ]" -ForegroundColor Cyan
            # ストリームのフィールド順と、先頭10フレームの走査方式フラグを取得
            $scanInfoJson = & $ffprobePath.Path -v error -select_streams v:0 -show_entries "stream=field_order:frame=interlaced_frame,top_field_first" -read_intervals "%+2" -of json -i $filePath
            $scanInfo = $null
            if ($LASTEXITCODE -eq 0 -and $scanInfoJson) {
                try {
                    $scanInfo = ($scanInfoJson -join "`n") | ConvertFrom-Json
                }
                catch {
                    Write-Host "走査方式の解析に失敗したのじゃ。" -ForegroundColor Yellow
                }
            }

            if ($scanInfo -and $scanInfo.streams -and $scanInfo.streams.Count -gt 0) {
                $fieldOrder = [string]$scanInfo.streams[0].field_order
                switch ($fieldOrder) {
                    "progressive" { $streamScan = "プログレッシブ"; break }
                    "tt"          { $streamScan = "インターレース（TFF：トップフィールド優先）"; break }
                    "bb"          { $streamScan = "インターレース（BFF：ボトムフィールド優先）"; break }
                    "tb"          { $streamScan = "インターレース（TB：上位フィールドを先に符号化、下位を先に表示）"; break }
                    "bt"          { $streamScan = "インターレース（BT：下位フィールドを先に符号化、上位を先に表示）"; break }
                    default       { $streamScan = "不明"; break }
                }
                if (-not $fieldOrder) { $fieldOrder = "unknown" }
                Write-Host "ストリーム情報: $streamScan (field_order=$fieldOrder)"

                $flaggedFrames = @($scanInfo.frames | Select-Object -First 10 | Where-Object { $null -ne $_ -and $null -ne $_.interlaced_frame })
                if ($flaggedFrames.Count -gt 0) {
                    $interlacedCount = @($flaggedFrames | Where-Object { $_.interlaced_frame -eq 1 }).Count
                    $progressiveCount = @($flaggedFrames | Where-Object { $_.interlaced_frame -eq 0 }).Count
                    Write-Host "先頭$($flaggedFrames.Count)フレーム: インターレース $interlacedCount / プログレッシブ $progressiveCount"

                    if ($interlacedCount -gt 0) {
                        $tffCount = @($flaggedFrames | Where-Object { $_.interlaced_frame -eq 1 -and $_.top_field_first -eq 1 }).Count
                        $bffCount = @($flaggedFrames | Where-Object { $_.interlaced_frame -eq 1 -and $_.top_field_first -eq 0 }).Count
                        Write-Host "インターレースフレームのフィールド順: TFF $tffCount / BFF $bffCount"
                    }
                    if (($fieldOrder -eq "progressive" -and $interlacedCount -gt 0) -or
                        ($fieldOrder -in @("tt", "bb", "tb", "bt") -and $progressiveCount -gt 0)) {
                        Write-Host "注意: ストリーム情報とフレームのフラグに差異があるのじゃ。" -ForegroundColor Yellow
                    }
                }
                else {
                    Write-Host "フレーム単位の走査方式フラグは取得できなかったのじゃ。"
                }
            }
            else {
                Write-Host "映像ストリームがないか、走査方式の情報を取得できなかったのじゃ。"
            }
            Write-Host "（これはメタデータ／デコード時のフラグで、映像内の縞模様を実測した結果ではないぞ）"

        }
        else {
            Write-Host "[ フレームレート詳細 ]" -ForegroundColor DarkGray
            Write-Host "（ffprobeが見つからんため、このセクションはスキップするのじゃ）"
            Write-Host "[ 走査方式 ]" -ForegroundColor DarkGray
            Write-Host "（ffprobeが見つからんため、このセクションはスキップするのじゃ）"
        }

        # 実映像の比較を先に見せてから、3:2プル判定の解析を実行する。
        Show-FFplayVerification -VideoPath $filePath -FFprobeExecutable $(if ($ffprobePath) { $ffprobePath.Path } else { $null })

        if (-not $SkipCadenceAnalysis) {
            $exe = if ($ffmpegPath) { $ffmpegPath.Path } else { $null }
            $probe = if ($ffprobePath) { $ffprobePath.Path } else { $null }
            Show-TelecineAssessment -File $filePath -FFmpegExecutable $exe -FFprobeExecutable $probe -Frames $AnalysisFrames -Full $runFullAnalysis
        }

        Write-Host "======================================================================`n"
    }
    else {
        Write-Host "エラー: `"$($filePath)`" はファイルではない、または見つからんかったぞ。" -ForegroundColor Red
    }
}

if ($interactive) {
    Write-Host "処理が完了したぞ。Enterキーを押せば閉じるのじゃ。" -ForegroundColor Green
    # CtrlキーやCtrl+Cで閉じないように、Enterのキーダウンだけを終了条件とする
    do {
        $pressedKey = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown,AllowCtrlC")
    } while ($pressedKey.VirtualKeyCode -ne 13)
}
else {
    Write-Host "処理が完了したぞ。" -ForegroundColor Green
}