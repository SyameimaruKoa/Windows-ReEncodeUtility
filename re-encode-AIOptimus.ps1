<#
.SYNOPSIS
    動画ファイルを一括で再エンコードするPowerShellスクリプトじゃ。
.DESCRIPTION
    FFmpegを利用して、ドラッグ＆ドロップされた動画ファイルを一括で再エンコードする。
    対話形式での詳細な設定、テンプレートの利用、高品質な中間ファイルの作成、
    さらにチャプターや字幕に基づいた分割保存が可能じゃ。
    エンコード設定は get-ffmpegOptions.ps1 で行うぞ。
.PARAMETER Path
    処理対象の動画ファイルまたはフォルダのパスじゃ。複数指定も可能じゃぞ。
.NOTES
    このスクリプトの実行には、ffmpeg, ffprobe や各種外部エンコーダーが必要じゃ。
    `config.user.psd1` に各ツールのパスを正しく設定しておくのじゃぞ。
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromRemainingArguments = $true, HelpMessage = "処理対象のファイルまたはフォルダのパスを入力せい。")]
    [string[]]$Path
)

#region 初期設定とヘルパー関数
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# 文字コードの問題を回避するため、コンソールのエンコーディングをUTF-8に設定じゃ
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# --- 設定ファイルの読み込み ---
$configFilePath = Join-Path $PSScriptRoot "config.user.psd1"
if (-not (Test-Path $configFilePath)) {
    Write-Error "設定ファイル (config.user.psd1) が見つからぬ！話にならんわ！"
    Read-Host "何かキーを押して終了"; exit 1
}
$global:Settings = Import-PowerShellDataFile -Path $configFilePath
$global:Settings.TemplateDir = $PSScriptRoot

# --- 依存スクリプトの確認 ---
$optionsScriptPath = Join-Path $PSScriptRoot "get-ffmpegOptions.ps1"
if (-not (Test-Path $optionsScriptPath)) {
    Write-Error "エンコードオプション設定スクリプト (get-ffmpegOptions.ps1) が見つからぬ！話にならんわ！"
    Read-Host "何かキーを押して終了"; exit 1
}

# --- ロギング基盤 ---
$global:LogFilePath = $null

function Initialize-LogFile {
    param([string]$OutputDir)
    $logFileName = "re-encode-log-$((Get-Date).ToString('yyyyMMdd-HHmmss')).log"
    $global:LogFilePath = Join-Path $OutputDir $logFileName
    $ffmpegVer = "不明"
    try { $ffmpegVer = (& $global:Settings.FfmpegPath -version 2>&1 | Select-Object -First 1).ToString() } catch {}
    $header = @"
================================================================
  動画再エンコード ログ
  日時          : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  コンピューター: $env:COMPUTERNAME
  ユーザー      : $env:USERNAME
  OS            : $([System.Environment]::OSVersion.VersionString)
  PowerShell    : $($PSVersionTable.PSVersion)
  ffmpeg        : $ffmpegVer
================================================================
"@
    $header | Out-File -FilePath $global:LogFilePath -Encoding utf8 -Force
    Write-Log "ログファイル: $($global:LogFilePath)"
    return $global:LogFilePath
}

function Write-Log {
    param(
        [string]$Message,
        [switch]$NoTimestamp,
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO"
    )
    $logMessage = if ($NoTimestamp) { $Message } else { "[{0}] [{1,-5}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message }
    switch ($Level) {
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
        "WARN" { Write-Host $logMessage -ForegroundColor Yellow }
        "DEBUG" { Write-Host $logMessage -ForegroundColor DarkGray }
        default { Write-Host $logMessage }
    }
    if ($global:LogFilePath) {
        try { $logMessage | Out-File -FilePath $global:LogFilePath -Append -Encoding utf8 } catch {}
    }
}

function Get-MediaInfoString {
    param([string]$FilePath)
    $lines = @()
    try {
        $jsonStr = & $global:Settings.FfprobePath -v quiet -print_format json -show_format -show_streams "$FilePath" 2>$null | Out-String
        $json = $jsonStr | ConvertFrom-Json
        $fmt = $json.format
        $fileSize = [math]::Round([double]$fmt.size / 1MB, 2)
        $duration = [TimeSpan]::FromSeconds([double]$fmt.duration).ToString("hh\:mm\:ss\.ff")
        $bitrate = [math]::Round([double]$fmt.bit_rate / 1000)
        $lines += "ファイル    : $(Split-Path -Leaf $FilePath)"
        $lines += "パス        : $FilePath"
        $lines += "サイズ      : ${fileSize} MB"
        $lines += "長さ        : $duration"
        $lines += "ビットレート: ${bitrate} kbps"
        $lines += "フォーマット: $($fmt.format_long_name)"
        foreach ($s in $json.streams) {
            if ($s.codec_type -eq "video") {
                $lines += "映像        : $($s.codec_long_name) ($($s.codec_name)), $($s.width)x$($s.height), $($s.r_frame_rate) fps, pix_fmt=$($s.pix_fmt)"
            }
            elseif ($s.codec_type -eq "audio") {
                $abr = if ($s.bit_rate) { "$([math]::Round([double]$s.bit_rate / 1000)) kbps" } else { "N/A" }
                $lines += "音声        : $($s.codec_long_name) ($($s.codec_name)), $($s.sample_rate) Hz, $($s.channel_layout), $abr"
            }
        }
    }
    catch { $lines += "メディア情報の取得に失敗: $_" }
    return ($lines -join "`n")
}

function Get-InputDuration {
    param([string]$FilePath)
    try {
        $durationStr = & $global:Settings.FfprobePath -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$FilePath" 2>$null
        return [double]$durationStr
    }
    catch { return 0 }
}

function Invoke-ExternalProcess {
    param(
        [string]$FilePath,
        [string]$Arguments,
        [string]$Label = ""
    )
    if ($Label) { Write-Log $Label }
    Write-Log "[CMD] `"$FilePath`" $Arguments" -Level "DEBUG"
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) "re-enc-stderr-$([System.IO.Path]::GetRandomFileName())"
    $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) "re-enc-stdout-$([System.IO.Path]::GetRandomFileName())"
    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments `
            -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile
        $stdout = ""; $stderr = ""
        if (Test-Path $stdoutFile) { $stdout = (Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue) }
        if (Test-Path $stderrFile) { $stderr = (Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue) }
        if ($stdout -and $stdout.Trim()) { Write-Log "[stdout]`n$($stdout.TrimEnd())" -Level "DEBUG" }
        if ($stderr -and $stderr.Trim()) {
            $lvl = if ($proc.ExitCode -ne 0) { "ERROR" } else { "DEBUG" }
            Write-Log "[stderr]`n$($stderr.TrimEnd())" -Level $lvl
        }
        $lvl2 = if ($proc.ExitCode -ne 0) { "ERROR" } else { "DEBUG" }
        Write-Log "終了コード: $($proc.ExitCode)" -Level $lvl2
        return @{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr }
    }
    finally {
        Remove-Item $stderrFile, $stdoutFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-FfmpegEncode {
    param(
        [string]$Arguments,
        [double]$DurationSeconds = 0
    )
    $ffmpegPath = $global:Settings.FfmpegPath
    Write-Log "[CMD] `"$ffmpegPath`" $Arguments" -Level "DEBUG"
    $progressFile = Join-Path ([System.IO.Path]::GetTempPath()) "ffprogress-$([System.IO.Path]::GetRandomFileName())"
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) "re-enc-stderr-$([System.IO.Path]::GetRandomFileName())"
    $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) "re-enc-stdout-$([System.IO.Path]::GetRandomFileName())"
    $startTime = Get-Date
    try {
        $fullArgs = "$Arguments -progress `"$progressFile`""
        $proc = Start-Process -FilePath $ffmpegPath -ArgumentList $fullArgs `
            -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile
        # PS 5.1ではハンドルを事前にキャッシュしないと終了後にExitCodeがnullになる
        $null = $proc.Handle
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 500
            if (Test-Path $progressFile) {
                try {
                    $progContent = Get-Content $progressFile -ErrorAction SilentlyContinue
                    $outTimeLine = $progContent | Where-Object { $_ -match '^out_time=' } | Select-Object -Last 1
                    $speedLine = $progContent | Where-Object { $_ -match '^speed=' } | Select-Object -Last 1
                    if ($outTimeLine) {
                        $outTime = (($outTimeLine -split '=', 2)[1]).Trim()
                        $speed = if ($speedLine) { (($speedLine -split '=', 2)[1]).Trim() } else { "N/A" }
                        $pct = ""
                        if ($DurationSeconds -gt 0 -and $outTime -ne "N/A") {
                            try {
                                $currentSec = [TimeSpan]::Parse($outTime).TotalSeconds
                                $pct = " ({0:F1}%)" -f [Math]::Min(100, ($currentSec / $DurationSeconds) * 100)
                            }
                            catch {}
                        }
                        Write-Host "`r  進捗: $outTime / 速度: $speed$pct       " -NoNewline
                    }
                }
                catch {}
            }
        }
        $proc.WaitForExit()
        $elapsed = (Get-Date) - $startTime
        Write-Host "`r  完了 (所要時間: $($elapsed.ToString('hh\:mm\:ss')))                         "
        Write-Log "エンコード所要時間: $($elapsed.ToString('hh\:mm\:ss'))"
        $stdout = ""; $stderr = ""
        if (Test-Path $stdoutFile) { $stdout = Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue }
        if (Test-Path $stderrFile) { $stderr = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue }
        if ($stderr -and $stderr.Trim()) {
            $sLines = ($stderr -split "`r?`n") | Where-Object {
                $_ -match '(Input #|Output #|Stream #|Stream mapping|frame=.*Lsize=|video:.*audio:)'
            }
            if ($sLines) { Write-Log "[ffmpeg サマリー]`n$($sLines -join "`n")" }
            $errLines = ($stderr -split "`r?`n") | Where-Object {
                $_ -match '(Error|Could not|Invalid|No such|Unknown|Unrecognized|not found)'
            }
            if ($errLines) { Write-Log "[ffmpeg エラー/警告]`n$($errLines -join "`n")" -Level "WARN" }
            $lvl = if ($proc.ExitCode -ne 0) { "ERROR" } else { "DEBUG" }
            Write-Log "[ffmpeg 全出力]`n$($stderr.TrimEnd())" -Level $lvl
        }
        $lvl2 = if ($proc.ExitCode -ne 0) { "ERROR" } else { "INFO" }
        Write-Log "ffmpeg 終了コード: $($proc.ExitCode)" -Level $lvl2
        return @{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr }
    }
    finally {
        Remove-Item $stderrFile, $stdoutFile, $progressFile -Force -ErrorAction SilentlyContinue
    }
}

function Show-Menu {
    param ([string]$Title, [string[]]$Choices, [int]$DefaultIndex = 0)
    $currentIndex = $DefaultIndex
    while ($true) {
        Clear-Host; Write-Host "$Title`n"
        for ($i = 0; $i -lt $Choices.Length; $i++) {
            if ($i -eq $currentIndex) { Write-Host -ForegroundColor Black -BackgroundColor White " > $($Choices[$i])" }
            else { Write-Host "   $($Choices[$i])" }
        }
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        switch ($key.VirtualKeyCode) {
            38 { if ($currentIndex -gt 0) { $currentIndex-- } }
            40 { if ($currentIndex -lt ($Choices.Length - 1)) { $currentIndex++ } }
            13 { return $currentIndex }
        }
    }
}

function Sanitize-FileName {
    param ([string]$Name)
    # 禁則文字を全角に置換するのじゃ
    return $Name -replace '\\', '＼' `
        -replace '/', '／' `
        -replace ':', '：' `
        -replace '\*', '＊' `
        -replace '\?', '？' `
        -replace '"', '”' `
        -replace '<', '＜' `
        -replace '>', '＞' `
        -replace '\|', '｜' `
        -replace '[\r\n]', '' # 改行も削除
}

function Test-CommandExists {
    param ([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    # パスとして存在するか、またはコマンドとして認識できるか (PATH環境変数含む)
    if (Test-Path $Command) { return $true }
    if (Get-Command $Command -ErrorAction SilentlyContinue) { return $true }
    return $false
}

function Get-EncoderPath {
    param ([string]$Type)
    # 設定ファイル(config.user.psd1)のキー名とマッピングする
    # qaac -> QaacPath, fdkaac -> FdkaacPath, nero -> NeroAacEncPath
    $configKey = "$($Type)Path"
    if ($Type -eq "nero") { $configKey = "NeroAacEncPath" }
    
    return $global:Settings[$configKey]
}
#endregion

#region メイン処理
function Start-MainProcess {
    # ログ出力先が変わるため、ここでのTranscriptは廃止し、各処理関数内で開始する
    Write-Log -Message "=============== エンコード処理開始 ===============" -NoTimestamp

    # --- ハードウェアデコード選択 ---
    $hwAccelChoices = @("使用しない (CPUデコード)", "NVIDIA (cuda)", "Intel (qsv)", "AMD (d3d11va)", "Windows汎用 (dxva2)")
    $hwAccelMap = @("", "cuda", "qsv", "d3d11va", "dxva2")
    $hwAccelIndex = Show-Menu -Title "使用するハードウェアデコードを選択してください。" -Choices $hwAccelChoices
    $hwAccelOption = ""
    if ($hwAccelIndex -gt 0) {
        $selectedHwAccel = $hwAccelMap[$hwAccelIndex]
        $hwAccelOption = "-hwaccel $selectedHwAccel"
        # d3d11va/dxva2 使用時は出力フォーマットを指定してGPUメモリ上に保持する
        if ($selectedHwAccel -eq "d3d11va") {
            $hwAccelOption += " -hwaccel_output_format d3d11"
        }
    }

    # --- 実行モード選択 ---
    $modeChoices = @("通常モード (一つずつ対話形式で設定)", "テンプレートから選択", "中間ファイル作成モード (高画質・MKV・音声コピー)", "チャプター/字幕分割モード (分割して再エンコード)")
    $selectedMode = Show-Menu -Title "実行モードを選択してください。" -Choices $modeChoices
    
    $config = $null
    switch ($selectedMode) {
        0 { $config = Invoke-InteractiveSetup }
        1 { $config = Invoke-TemplateSelect }
        2 { $config = Invoke-IntermediateMode }
        3 { $config = Invoke-SplitModeSetup }
    }
    if (-not $config) { Write-Log "設定がキャンセルされたため、処理を中断します。"; return }

    $fileCount = 0; $totalFiles = $Path.Count
    foreach ($inputFile in $Path) {
        $inputFile = $inputFile.Trim('"')
        $fileCount++
        Clear-Host
        Write-Log "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -NoTimestamp
        Write-Log " [ $fileCount / $totalFiles 個目のファイル処理開始 ]"
        Write-Log " ファイル名: $(Split-Path -Leaf $inputFile)"
        Write-Log "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -NoTimestamp
        
        if ($config.IsSplitMode) {
            Invoke-SplitEncodeFile -InputFile $inputFile -Config $config -HwAccelOption $hwAccelOption
        }
        else {
            Invoke-EncodeFile -InputFile $inputFile -Config $config -HwAccelOption $hwAccelOption
        }
    }
    Write-Log "================ 全ての処理が完了しました ================" -NoTimestamp
    Invoke-AfterProcessAction -Action $config.AfterProcessAction
}

function Invoke-InteractiveSetup {
    $encoderSettings = . $optionsScriptPath
    if (-not $encoderSettings) { Write-Log "エンコード設定が中止されました。"; return $null }

    $outputMode = "Subfolder"; $outputFixedPath = ""
    if ((Show-Menu -Title "出力先を固定しますか？" -Choices @("いいえ (入力元と同じ階層のsubfolder)", "はい (固定フォルダを指定)")) -eq 1) {
        while (-not $outputFixedPath) {
            $outputFixedPath = Read-Host "固定出力先のパスを入力してください"
            if (-not (Test-Path $outputFixedPath)) {
                try { New-Item -Path $outputFixedPath -ItemType Directory -ErrorAction Stop | Out-Null }
                catch { Write-Warning "フォルダの作成に失敗しました: $_"; $outputFixedPath = "" }
            }
        }
        $outputMode = "Fixed"
    }
    
    $afterProcessAction = @("None", "Shutdown", "Reboot", "Hibernate")[(Show-Menu -Title "エンコード完了後どうしますか？" -Choices @("何もしない", "シャットダウン", "再起動", "休止"))]
    $extension = @("mp4", "mov", "mkv", "webm")[(Show-Menu -Title "出力ファイルの拡張子を選択してください。" -Choices @("mp4", "mov", "mkv", "webm"))]
    $cut = @("No", "Yes")[(Show-Menu -Title "動画をカットしますか？ (LosslessCutを使用)" -Choices @("いいえ", "はい"))]
    $metadata = @("ExifTool", "Ffmpeg", "None")[(Show-Menu -Title "動画のメタデータ(撮影日時など)を保持しますか？" -Choices @("ExifToolで全コピー", "ffmpeg形式で一部保持", "保持しない"))]

    $additionalVF = ""; $additionalArgs = ""
    if ((Show-Menu -Title "追加のビデオフィルター(-vf)やオプションを使いますか？" -Choices @("いいえ", "はい")) -eq 1) {
        $additionalVF = Read-Host "ffmpegの「-vf」として使用するフィルターを入力 (例: scale=1280:-1)"
        $additionalArgs = Read-Host "その他のffmpeg引数を追加 (例: -max_muxing_queue_size 1024)"
    }

    $currentConfig = @{
        IsSplitMode = $false
        EncoderSettings = $encoderSettings; OutputMode = $outputMode; OutputFixedPath = $outputFixedPath
        AfterProcessAction = $afterProcessAction; Extension = $extension; Cut = $cut; Metadata = $metadata
        AdditionalVF = $additionalVF; AdditionalArgs = $additionalArgs
    }

    if ((Show-Menu -Title "この設定をテンプレートとして保存しますか？" -Choices @("いいえ", "はい")) -eq 1) {
        $templateName = Read-Host "テンプレート名を入力してください"
        if ($templateName) {
            $templatePath = Join-Path $global:Settings.TemplateDir "$templateName.psd1"
            $currentConfig | Export-CliXml -Path $templatePath
            Write-Log "設定を $templatePath に保存しました。"
        }
    }
    return $currentConfig
}

function Invoke-TemplateSelect {
    $templates = Get-ChildItem -Path $global:Settings.TemplateDir -Filter "*.psd1" | Where-Object { $_.Name -notmatch "^config.*\.psd1$" }
    if (-not $templates) { Write-Log "テンプレートファイルが見つかりませぬ..."; Read-Host "何かキーを押して戻る"; return $null }
    $templateNames = $templates | ForEach-Object { $_.BaseName }
    $selectedIndex = Show-Menu -Title "使用するテンプレートを選択してください。" -Choices $templateNames
    if ($selectedIndex -lt 0) { return $null }
    $selectedTemplatePath = $templates[$selectedIndex].FullName
    Write-Log "`"$($templateNames[$selectedIndex])`" を読み込みます..."
    return (Import-CliXml -Path $selectedTemplatePath)
}

function Invoke-IntermediateMode {
    Write-Log "中間ファイル用のエンコードオプションを設定します..."
    $encoderSettings = . $optionsScriptPath -Intermediate
    if (-not $encoderSettings) { Write-Log "エンコード設定が中止されました。"; return $null }
    return @{
        IsSplitMode = $false
        EncoderSettings = $encoderSettings; OutputMode = "Subfolder"; OutputFixedPath = ""
        AfterProcessAction = "None"; Extension = "mkv"; Cut = "No"; Metadata = "ExifTool"
        AdditionalVF = ""; AdditionalArgs = ""
    }
}

function Invoke-SplitModeSetup {
    Write-Log "チャプター/字幕分割モードの設定を行います。"
    $encoderSettings = . $optionsScriptPath
    if (-not $encoderSettings) { Write-Log "エンコード設定が中止されました。"; return $null }

    $splitSource = @("InternalChapter", "ExternalSRT")[(Show-Menu -Title "分割に使用するソースを選択してください" -Choices @("内部チャプターを使用", "外部SRT字幕ファイルを使用"))]
    
    $namingStyle = @("Text", "Number")[(Show-Menu -Title "分割後のファイル名規則を選択してください" -Choices @("チャプター/字幕のテキストを使用 (例: 元名_チャプター名.mp4)", "連番のみを使用 (例: 元名_01.mp4)"))]

    $extension = @("mp4", "mov", "mkv", "webm")[(Show-Menu -Title "出力ファイルの拡張子を選択してください。" -Choices @("mp4", "mov", "mkv", "webm"))]
    $afterProcessAction = @("None", "Shutdown", "Reboot", "Hibernate")[(Show-Menu -Title "エンコード完了後どうしますか？" -Choices @("何もしない", "シャットダウン", "再起動", "休止"))]

    return @{
        IsSplitMode        = $true
        EncoderSettings    = $encoderSettings
        SplitSource        = $splitSource
        NamingStyle        = $namingStyle
        Extension          = $extension
        AfterProcessAction = $afterProcessAction
    }
}

function Invoke-SplitEncodeFile {
    param ([string]$InputFile, [hashtable]$Config, [string]$HwAccelOption)

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $inputDir = Split-Path -Parent $InputFile
    
    # 出力先は「元ファイル名」のフォルダ
    $outputBaseDir = Join-Path $inputDir $baseName
    if (-not (Test-Path $outputBaseDir)) { New-Item -Path $outputBaseDir -ItemType Directory | Out-Null }

    # --- ログファイル初期化 ---
    Initialize-LogFile -OutputDir $outputBaseDir

    try {
        # --- エンコード設定をログに記録 ---
        Write-Log "========= エンコード設定 (分割モード) =========" -NoTimestamp
        Write-Log "映像オプション : $($Config.EncoderSettings.Video)"
        Write-Log "音声オプション : $($Config.EncoderSettings.Audio) (タイプ: $($Config.EncoderSettings.AudioType))"
        Write-Log "分割ソース     : $($Config.SplitSource)"
        Write-Log "命名規則       : $($Config.NamingStyle)"
        Write-Log "出力形式       : .$($Config.Extension)"
        if ($HwAccelOption) { Write-Log "HWデコード     : $HwAccelOption" }

        # --- 入力ファイル情報をログに記録 ---
        Write-Log "========= 入力ファイル情報 =========" -NoTimestamp
        Write-Log (Get-MediaInfoString -FilePath $InputFile)

        $segments = @()
        $tempDir = Join-Path $outputBaseDir "temp_$baseName"
        if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory | Out-Null }

        if ($Config.SplitSource -eq "ExternalSRT") {
            $srtFile = Join-Path $inputDir "$baseName.srt"
            if (-not (Test-Path $srtFile)) {
                Write-Log "SRTファイルが見つかりません: $srtFile" -Level "ERROR"
                Write-Log "このファイルはスキップします。" -Level "ERROR"
                return
            }
            Write-Log "SRTファイルを解析中... ($srtFile)"
            $srtContent = Get-Content $srtFile -Encoding UTF8 -Raw
            $regex = [regex] '(?ms)(\d+)\s+(\d{2}:\d{2}:\d{2}[,.]\d{3})\s+-->\s+(\d{2}:\d{2}:\d{2}[,.]\d{3})\s+(.*?)(?=\r?\n\r?\n|\z)'
            $matches = $regex.Matches($srtContent)
            
            foreach ($m in $matches) {
                $startTime = $m.Groups[2].Value.Replace(',', '.')
                $endTime = $m.Groups[3].Value.Replace(',', '.')
                $text = $m.Groups[4].Value -replace '\r?\n', ' '
                $segments += @{ Start = $startTime; End = $endTime; Name = $text.Trim() }
            }
        }
        elseif ($Config.SplitSource -eq "InternalChapter") {
            Write-Log "チャプター情報を取得中..."
            $oldEncoding = [Console]::OutputEncoding
            try {
                [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                $jsonStr = & $global:Settings.FfprobePath -v quiet -print_format json -show_chapters "$InputFile" | Out-String
            }
            finally {
                [Console]::OutputEncoding = $oldEncoding
            }
            $json = $jsonStr | ConvertFrom-Json
            
            if (-not $json.chapters) {
                Write-Log "チャプター情報が見つかりません。このファイルはスキップします。" -Level "WARN"
                return
            }

            foreach ($chap in $json.chapters) {
                $segments += @{ Start = $chap.start_time; End = $chap.end_time; Name = $chap.tags.title }
            }
        }

        $count = 1
        $totalSegments = $segments.Count
        Write-Log "$totalSegments 個のセグメントを検出しました。"
        # セグメント一覧をログに記録
        foreach ($s in $segments) {
            Write-Log "  セグメント: $($s.Start) -> $($s.End) $(if ($s.Name) { "[$($s.Name)]" })" -Level "DEBUG"
        }

        foreach ($seg in $segments) {
            $suffix = ""
            if ($Config.NamingStyle -eq "Text" -and $seg.Name) {
                $safeName = Sanitize-FileName -Name $seg.Name
                $suffix = "_$safeName"
            }
            else {
                $suffix = "_{0:D2}" -f $count
            }
            
            $outputFileName = "${baseName}${suffix}.$($Config.Extension)"
            $outputFilePath = Join-Path $outputBaseDir $outputFileName
            
            if (Test-Path $outputFilePath) {
                $suffix += "_{0:D2}" -f $count
                $outputFileName = "${baseName}${suffix}.$($Config.Extension)"
                $outputFilePath = Join-Path $outputBaseDir $outputFileName
            }

            Write-Log "--- セグメント [$count/$totalSegments]: $outputFileName ($($seg.Start) -> $($seg.End)) ---"
            
            # セグメントの長さを計算 (進捗表示用)
            $segDuration = 0
            try {
                $segDuration = [TimeSpan]::Parse($seg.End).TotalSeconds - [TimeSpan]::Parse($seg.Start).TotalSeconds
            }
            catch {}

            # --- 音声処理の準備 ---
            $audioOptions = $Config.EncoderSettings.Audio
            $tempAudioOutFile = ""
            $audioEncType = $Config.EncoderSettings.AudioType
            $tempWavFile = Join-Path $tempDir "temp_audio_seg.wav"
            
            if ($audioEncType -eq "qaac" -or $audioEncType -eq "nero" -or $audioEncType -eq "fdkaac") {
                $encPath = Get-EncoderPath -Type $audioEncType

                if (-not (Test-CommandExists -Command $encPath)) {
                    Write-Log "外部エンコーダー '$encPath' が見つかりません。音声コピーモードに切り替えます。" -Level "WARN"
                    $audioOptions = "-c:a copy"
                }
                else {
                    $wavArgsStr = "-hide_banner -loglevel error -y -ss $($seg.Start) -to $($seg.End) -i `"$InputFile`" -vn -map_chapters -1 -map_metadata -1 -f wav `"$tempWavFile`""
                    $result = Invoke-ExternalProcess -FilePath $global:Settings.FfmpegPath -Arguments $wavArgsStr -Label "WAV切り出し中..."
                    
                    if ($result.ExitCode -ne 0) {
                        Write-Log "WAV変換失敗。音声をコピーします。" -Level "WARN"
                        $audioOptions = "-c:a copy"
                    }
                    else {
                        $tempAudioOutFile = Join-Path $tempDir "temp_audio_seg.m4a"
                        $encArgs = ""
                        
                        if ($audioEncType -eq "qaac") {
                            $encArgs = "$($Config.EncoderSettings.Audio) `"$tempWavFile`" -o `"$tempAudioOutFile`""
                        }
                        elseif ($audioEncType -eq "nero") {
                            $encArgs = "$($Config.EncoderSettings.Audio) -if `"$tempWavFile`" -of `"$tempAudioOutFile`""
                        }
                        elseif ($audioEncType -eq "fdkaac") {
                            $encArgs = "$($Config.EncoderSettings.Audio) -o `"$tempAudioOutFile`" `"$tempWavFile`""
                        }
                        
                        $result = Invoke-ExternalProcess -FilePath $encPath -Arguments $encArgs -Label "$($audioEncType)でエンコード処理中..."
                        if ($result.ExitCode -eq 0) {
                            $audioOptions = ""
                        }
                        else {
                            Write-Log "$($audioEncType)失敗 (終了コード: $($result.ExitCode))。音声をコピーします。" -Level "WARN"
                            $audioOptions = "-c:a copy"; $tempAudioOutFile = ""
                        }
                    }
                }
            }

            # --- 映像エンコードと結合 ---
            $ffmpegArgsList = @("-hide_banner", "-y")
            if ($HwAccelOption) { $ffmpegArgsList += $HwAccelOption.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries) }
            
            $ffmpegArgsList += @("-ss", "$($seg.Start)", "-to", "$($seg.End)")
            $ffmpegArgsList += @("-i", "`"$InputFile`"")

            if ($tempAudioOutFile) {
                $ffmpegArgsList += @("-i", "`"$tempAudioOutFile`"")
            }

            $ffmpegArgsList += @("-map_chapters", "-1", "-map_metadata", "-1")

            $splitOptions = [System.StringSplitOptions]::RemoveEmptyEntries
            $ffmpegArgsList += $Config.EncoderSettings.Video.Split(' ', $splitOptions)
            
            if ($tempAudioOutFile) {
                $ffmpegArgsList += @("-map", "0:v:0", "-map", "1:a:0", "-c:a", "copy")
            }
            else {
                $ffmpegArgsList += $audioOptions.Split(' ', $splitOptions)
            }

            $ffmpegArgsList += "`"$outputFilePath`""
            $finalArgString = $ffmpegArgsList -join ' '

            $result = Invoke-FfmpegEncode -Arguments $finalArgString -DurationSeconds $segDuration
            if ($result.ExitCode -ne 0) {
                Write-Log "セグメントエンコードエラー: $outputFileName" -Level "ERROR"
            }
            else {
                # 出力ファイルサイズを記録
                if (Test-Path $outputFilePath) {
                    $outSize = (Get-Item $outputFilePath).Length
                    Write-Log "  出力: $outputFileName ($([math]::Round($outSize / 1MB, 2)) MB)"
                }
            }
            $count++
        }
        
        # 終了後クリーンアップ
        if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force; Write-Log "一時ファイルをクリーンアップしました。" -Level "DEBUG" }
        Write-Log "全セグメントの処理が完了しました。"
    }
    catch {
        Write-Log "予期せぬエラー: $_" -Level "ERROR"
        Write-Log "スタックトレース: $($_.ScriptStackTrace)" -Level "ERROR"
    }
}

function Invoke-EncodeFile {
    param ([string]$InputFile, [hashtable]$Config, [string]$HwAccelOption)
    
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $inputDir = Split-Path -Parent $InputFile
    $outputDir = if ($Config.OutputMode -eq "Fixed") { $Config.OutputFixedPath } else { Join-Path $inputDir "encoded_output" }
    if (-not (Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory | Out-Null }
    
    # --- ログファイル初期化 ---
    Initialize-LogFile -OutputDir $outputDir

    try {
        # --- エンコード設定をログに記録 ---
        Write-Log "========= エンコード設定 =========" -NoTimestamp
        Write-Log "映像オプション : $($Config.EncoderSettings.Video)"
        Write-Log "音声オプション : $($Config.EncoderSettings.Audio) (タイプ: $($Config.EncoderSettings.AudioType))"
        Write-Log "出力形式: .$($Config.Extension) / メタデータ保持: $($Config.Metadata) / カット: $($Config.Cut)"
        if ($HwAccelOption) { Write-Log "HWデコード     : $HwAccelOption" }
        if ($Config.AdditionalVF) { Write-Log "追加フィルター : $($Config.AdditionalVF)" }
        if ($Config.AdditionalArgs) { Write-Log "追加引数       : $($Config.AdditionalArgs)" }

        # --- 入力ファイル情報をログに記録 ---
        Write-Log "========= 入力ファイル情報 =========" -NoTimestamp
        Write-Log (Get-MediaInfoString -FilePath $InputFile)
        $inputDuration = Get-InputDuration -FilePath $InputFile

        $outputFile = Join-Path $outputDir "$baseName.$($Config.Extension)"
        $tempDir = Join-Path $outputDir "temp_$baseName"; if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory | Out-Null }

        $cutInfo = ""; $useFfmpegMetadata = $false
        $ffmpegMetadataFile = Join-Path $tempDir "ffmpeg_metadata.txt"
        $splitOptions = [System.StringSplitOptions]::RemoveEmptyEntries

        if ($Config.Metadata -eq "Ffmpeg") {
            $metaArgs = "-hide_banner -loglevel error -y -i `"$InputFile`" -f ffmetadata `"$ffmpegMetadataFile`""
            $result = Invoke-ExternalProcess -FilePath $global:Settings.FfmpegPath -Arguments $metaArgs -Label "ffmetadataを作成中..."
            if ($result.ExitCode -eq 0) { $useFfmpegMetadata = $true } else { Write-Log "ffmetadataの作成に失敗しました。" -Level "WARN" }
        }

        if ($Config.Cut -eq "Yes") {
            Write-Log "LosslessCutを起動します..."; Start-Process $global:Settings.LosslessCutPath -ArgumentList "`"$InputFile`""
            $cutStart = Read-Host "開始位置 (例:00:01:15.000)"; $cutEnd = Read-Host "終了位置 (例:00:03:30.500)"
            if ($cutStart -and $cutEnd) { $cutInfo = "-ss $cutStart -to $cutEnd"; Write-Log "カット情報: 開始 $cutStart, 終了 $cutEnd" }
            else { Write-Log "カット位置が未入力のため、カットしません。" -Level "WARN" }
        }

        $audioOptions = $Config.EncoderSettings.Audio; $tempAudioOutFile = ""
        $tempWavFile = Join-Path $tempDir "temp_audio.wav"
        
        $audioEncType = $Config.EncoderSettings.AudioType
        if ($audioEncType -eq "qaac" -or $audioEncType -eq "nero" -or $audioEncType -eq "fdkaac") {
            $encPath = Get-EncoderPath -Type $audioEncType

            if (-not (Test-CommandExists -Command $encPath)) {
                Write-Log "外部エンコーダー '$encPath' が見つかりません。音声コピーモード (-c:a copy) に切り替えます。" -Level "WARN"
                $audioOptions = "-c:a copy"
            }
            else {
                $wavArgs = "-hide_banner -loglevel error -y $($cutInfo) -i `"$InputFile`" -vn -f wav `"$tempWavFile`""
                $result = Invoke-ExternalProcess -FilePath $global:Settings.FfmpegPath -Arguments $wavArgs -Label "音声ファイルをWAVに変換中..."
                if ($result.ExitCode -ne 0) {
                    Write-Log "WAV変換失敗。音声をコピーします。" -Level "WARN"; $audioOptions = "-c:a copy"
                }
                else {
                    $tempAudioOutFile = Join-Path $tempDir "temp_audio.m4a"
                    $encArgs = ""
                    if ($audioEncType -eq "qaac") {
                        $encArgs = "$($Config.EncoderSettings.Audio) `"$tempWavFile`" -o `"$tempAudioOutFile`""
                    }
                    elseif ($audioEncType -eq "nero") {
                        $encArgs = "$($Config.EncoderSettings.Audio) -if `"$tempWavFile`" -of `"$tempAudioOutFile`""
                    }
                    elseif ($audioEncType -eq "fdkaac") {
                        $encArgs = "$($Config.EncoderSettings.Audio) -o `"$tempAudioOutFile`" `"$tempWavFile`""
                    }
                    
                    $result = Invoke-ExternalProcess -FilePath $encPath -Arguments $encArgs -Label "$($audioEncType)でエンコード処理中..."
                    if ($result.ExitCode -eq 0) { $audioOptions = "" } 
                    else { Write-Log "$($audioEncType)失敗 (終了コード: $($result.ExitCode))。音声をコピーします。" -Level "WARN"; $audioOptions = "-c:a copy"; $tempAudioOutFile = "" }
                }
            }
        }

        $ffmpegArgsList = @("-hide_banner", "-y")
        if ($HwAccelOption) { $ffmpegArgsList += $HwAccelOption.Split(' ', $splitOptions) }
        $ffmpegArgsList += $cutInfo.Split(' ', $splitOptions)
        $ffmpegArgsList += @("-i", "`"$InputFile`"")

        if ($tempAudioOutFile) { $ffmpegArgsList += @("-i", "`"$tempAudioOutFile`"") }
        if ($useFfmpegMetadata) { $ffmpegArgsList += @("-i", "`"$ffmpegMetadataFile`"") }
        if ($cutInfo) { $ffmpegArgsList += @("-ss", "0") }
        $ffmpegArgsList += $Config.EncoderSettings.Video.Split(' ', $splitOptions)
        if ($Config.AdditionalVF) { $ffmpegArgsList += @("-vf", "`"$($Config.AdditionalVF)`"") }
        if ($Config.AdditionalArgs) { $ffmpegArgsList += $Config.AdditionalArgs.Split(' ', $splitOptions) }

        $inputCount = 1; $audioInputIndex = 0; $metadataInputIndex = 0
        if ($tempAudioOutFile) { $audioInputIndex = $inputCount; $inputCount++ }
        if ($useFfmpegMetadata) { $metadataInputIndex = $inputCount }
        if ($tempAudioOutFile) { $ffmpegArgsList += @("-map", "0:v:0", "-map", "${audioInputIndex}:a:0", "-c:a", "copy") }
        else { $ffmpegArgsList += $audioOptions.Split(' ', $splitOptions) }
        if ($useFfmpegMetadata) { $ffmpegArgsList += @("-map_metadata", "$metadataInputIndex") }
        $ffmpegArgsList += "`"$outputFile`""
        $finalArgString = $ffmpegArgsList -join ' '

        Write-Log "========= ffmpeg エンコード実行 =========" -NoTimestamp
        $result = Invoke-FfmpegEncode -Arguments $finalArgString -DurationSeconds $inputDuration
        
        if ($result.ExitCode -ne 0) {
            Write-Log "ffmpegエンコード失敗 (終了コード: $($result.ExitCode))" -Level "ERROR"
            if ($global:Settings.NotifyScriptPath) { & $global:Settings.NotifyScriptPath "$baseName EncodeError" }
        }
        else {
            Write-Log "ffmpegエンコードが正常に完了しました。"

            # --- 出力ファイル情報をログに記録 ---
            if (Test-Path $outputFile) {
                $outSize = (Get-Item $outputFile).Length
                $inSize = (Get-Item $InputFile).Length
                $ratio = if ($inSize -gt 0) { [math]::Round($outSize / $inSize * 100, 1) } else { 0 }
                Write-Log "========= 出力ファイル情報 =========" -NoTimestamp
                Write-Log "出力パス  : $outputFile"
                Write-Log "出力サイズ: $([math]::Round($outSize / 1MB, 2)) MB (元ファイルの ${ratio}%)"
            }

            if ($Config.Metadata -eq "ExifTool") {
                $exifArgs = "-api largefilesupport=1 -tagsfromfile `"$InputFile`" -all:all -overwrite_original `"$outputFile`""
                $result = Invoke-ExternalProcess -FilePath $global:Settings.ExifToolPath -Arguments $exifArgs -Label "ExifToolでメタデータをコピーしています..."
                if ($result.ExitCode -ne 0) {
                    Write-Log "ExifToolの実行に失敗しました。メタデータはコピーされていない可能性があります。" -Level "WARN"
                }
                Remove-Item -Path "$outputFile`_original" -ErrorAction SilentlyContinue
            }
        }

        if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force; Write-Log "一時ファイルをクリーンアップしました。" -Level "DEBUG" }
        Write-Log "ファイル「$(Split-Path -Leaf $InputFile)」の処理が完了しました。"
    }
    catch {
        Write-Log "予期せぬエラー: $_" -Level "ERROR"
        Write-Log "スタックトレース: $($_.ScriptStackTrace)" -Level "ERROR"
    }
}

function Invoke-AfterProcessAction {
    param ([string]$Action)
    switch ($Action) {
        "Shutdown" { Write-Host "60秒後にシャットダウン..."; Start-Sleep -Seconds 60; shutdown.exe -s -t 1 }
        "Reboot" { Write-Host "60秒後に再起動..."; Start-Sleep -Seconds 60; shutdown.exe -r -t 1 }
        "Hibernate" { Write-Host "休止モードへ移行..."; rundll32.exe powrprof.dll, SetSuspendState }
    }
}
#endregion

# --- スクリプト実行開始 ---
try {
    Start-MainProcess
}
catch {
    Write-Log "予期せぬエラーが発生しました: $_" -Level "ERROR"
    Write-Log "  スクリプト: $($_.InvocationInfo.ScriptName)" -Level "ERROR"
    Write-Log "  行番号: $($_.InvocationInfo.ScriptLineNumber)" -Level "ERROR"
    Write-Log "  コマンド: $($_.InvocationInfo.Line.Trim())" -Level "ERROR"
    Write-Log "  スタックトレース: $($_.ScriptStackTrace)" -Level "ERROR"
}
finally {
    Write-Log "処理を終了します。"
    if ($global:LogFilePath) { Write-Log "ログファイル: $($global:LogFilePath)" }
    Read-Host "何かキーを押して終了"
}