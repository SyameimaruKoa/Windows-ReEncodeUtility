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

function Write-Log {
    param([string]$Message, [switch]$NoTimestamp)
    $logMessage = if ($NoTimestamp) { $Message } else { "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message }
    Write-Host $logMessage
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

    # --- ログ出力開始 (出力フォルダへ) ---
    $logFile = Join-Path $outputBaseDir "re-encode-log-$((Get-Date).ToString('yyyyMMdd-HHmmss')).log"
    Start-Transcript -Path $logFile -Append

    try {
        $segments = @()
        $tempDir = Join-Path $outputBaseDir "temp_$baseName"
        if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory | Out-Null }

        if ($Config.SplitSource -eq "ExternalSRT") {
            $srtFile = Join-Path $inputDir "$baseName.srt"
            if (-not (Test-Path $srtFile)) {
                Write-Warning "SRTファイルが見つかりません: $srtFile"
                Write-Warning "このファイルはスキップします。"
                return
            }
            Write-Log "SRTファイルを解析中... ($srtFile)"
            # SRT解析 (UTF-8前提)
            $srtContent = Get-Content $srtFile -Encoding UTF8 -Raw
            # 正規表現でブロックを取得: Index, TimeRange, Text
            $regex = [regex] '(?ms)(\d+)\s+(\d{2}:\d{2}:\d{2}[,.]\d{3})\s+-->\s+(\d{2}:\d{2}:\d{2}[,.]\d{3})\s+(.*?)(?=\r?\n\r?\n|\z)'
            $matches = $regex.Matches($srtContent)
            
            foreach ($m in $matches) {
                $startTime = $m.Groups[2].Value.Replace(',', '.')
                $endTime = $m.Groups[3].Value.Replace(',', '.')
                $text = $m.Groups[4].Value -replace '\r?\n', ' ' # 改行をスペースに
                $segments += @{ Start = $startTime; End = $endTime; Name = $text.Trim() }
            }
        }
        elseif ($Config.SplitSource -eq "InternalChapter") {
            Write-Log "チャプター情報を取得中..."
            # ffprobeの出力をUTF-8として読み込む (Mojibake対策)
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
                Write-Warning "チャプター情報が見つかりません。"
                Write-Warning "このファイルはスキップします。"
                return
            }

            foreach ($chap in $json.chapters) {
                $segments += @{ Start = $chap.start_time; End = $chap.end_time; Name = $chap.tags.title }
            }
        }

        $count = 1
        $totalSegments = $segments.Count
        Write-Log "$totalSegments 個のセグメントを検出しました。"

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
            
            # 同名ファイル対策
            if (Test-Path $outputFilePath) {
                $suffix += "_{0:D2}" -f $count
                $outputFileName = "${baseName}${suffix}.$($Config.Extension)"
                $outputFilePath = Join-Path $outputBaseDir $outputFileName
            }

            Write-Log "セグメント処理中 [$count/$totalSegments]: $outputFileName ($($seg.Start) -> $($seg.End))"
            
            # --- 音声処理の準備 ---
            $audioOptions = $Config.EncoderSettings.Audio
            $tempAudioOutFile = ""
            $audioEncType = $Config.EncoderSettings.AudioType
            $tempWavFile = Join-Path $tempDir "temp_audio_seg.wav"
            
            # 外部エンコーダーを使用する場合
            if ($audioEncType -eq "qaac" -or $audioEncType -eq "nero" -or $audioEncType -eq "fdkaac") {
                $encPath = Get-EncoderPath -Type $audioEncType

                if (-not (Test-CommandExists -Command $encPath)) {
                    Write-Warning "エラー: 外部エンコーダー '$encPath' が見つかりません。パスを確認してください。"
                    Write-Warning "音声をコピーモード (-c:a copy) に切り替えて続行します。"
                    $audioOptions = "-c:a copy"
                }
                else {
                    # 1. WAV切り出し (中間ファイル作成なので静かに実行)
                    # -loglevel error -stats
                    $wavArgs = @("-hide_banner", "-loglevel", "error", "-stats", "-y", "-ss", "$($seg.Start)", "-to", "$($seg.End)", "-i", "`"$InputFile`"", "-vn", "-map_chapters", "-1", "-map_metadata", "-1", "-f", "wav", "`"$tempWavFile`"")
                    $process = Start-Process $global:Settings.FfmpegPath -ArgumentList $wavArgs -Wait -NoNewWindow -PassThru
                    
                    if ($process.ExitCode -ne 0) {
                        Write-Warning "WAV変換失敗。音声をコピーします。"
                        $audioOptions = "-c:a copy"
                    }
                    else {
                        # 2. 外部エンコーダー実行
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
                        
                        try {
                            $process = Start-Process $encPath -ArgumentList $encArgs -Wait -NoNewWindow -PassThru -ErrorAction Stop
                            if ($process.ExitCode -eq 0) {
                                $audioOptions = "" # 外部エンコード成功時はffmpeg側の音声オプションは不要
                            }
                            else {
                                Write-Warning "$($audioEncType)失敗 (ExitCode: $($process.ExitCode))。音声をコピーします。"
                                $audioOptions = "-c:a copy"; $tempAudioOutFile = ""
                            }
                        }
                        catch {
                            Write-Warning "外部エンコーダー実行エラー: $_"
                            $audioOptions = "-c:a copy"; $tempAudioOutFile = ""
                        }
                    }
                }
            }

            # --- 映像エンコードと結合 ---
            # 本番エンコードなので情報を見せる (-hide_banner のみ)
            $ffmpegArgsList = @("-hide_banner", "-y")
            if ($HwAccelOption) { $ffmpegArgsList += $HwAccelOption.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries) }
            
            # 映像入力 (シーク指定: 入力前に置くことでタイムスタンプをリセット)
            $ffmpegArgsList += @("-ss", "$($seg.Start)", "-to", "$($seg.End)")
            $ffmpegArgsList += @("-i", "`"$InputFile`"")

            # 外部音声入力がある場合
            if ($tempAudioOutFile) {
                $ffmpegArgsList += @("-i", "`"$tempAudioOutFile`"")
            }

            # 重要: チャプター情報とメタデータを削除して、タイムスタンプのズレを防ぐ
            $ffmpegArgsList += @("-map_chapters", "-1", "-map_metadata", "-1")

            # 映像エンコード設定
            $splitOptions = [System.StringSplitOptions]::RemoveEmptyEntries
            $ffmpegArgsList += $Config.EncoderSettings.Video.Split(' ', $splitOptions)
            
            # 音声マッピングと設定
            if ($tempAudioOutFile) {
                # 外部音声を使う場合: 映像はInput0, 音声はInput1(既にエンコード済なのでコピー)
                $ffmpegArgsList += @("-map", "0:v:0", "-map", "1:a:0", "-c:a", "copy")
            }
            else {
                # 内部/コピーの場合
                $ffmpegArgsList += $audioOptions.Split(' ', $splitOptions)
            }

            $ffmpegArgsList += "`"$outputFilePath`""
            $finalArgString = $ffmpegArgsList -join ' '

            # コマンド引数のログ表示は削除
            
            $process = Start-Process $global:Settings.FfmpegPath -ArgumentList $finalArgString -Wait -NoNewWindow -PassThru
            if ($process.ExitCode -ne 0) {
                Write-Error "セグメントエンコードエラー: $outputFileName"
            }
            $count++
        }
        
        # 終了後クリーンアップ
        if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force }
    }
    finally {
        Stop-Transcript
    }
}

function Invoke-EncodeFile {
    param ([string]$InputFile, [hashtable]$Config, [string]$HwAccelOption)
    
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $inputDir = Split-Path -Parent $InputFile
    $outputDir = if ($Config.OutputMode -eq "Fixed") { $Config.OutputFixedPath } else { Join-Path $inputDir "encoded_output" }
    if (-not (Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory | Out-Null }
    
    # --- ログ出力開始 (出力フォルダへ) ---
    $logFile = Join-Path $outputDir "re-encode-log-$((Get-Date).ToString('yyyyMMdd-HHmmss')).log"
    Start-Transcript -Path $logFile -Append

    try {
        $outputFile = Join-Path $outputDir "$baseName.$($Config.Extension)"
        $tempDir = Join-Path $outputDir "temp_$baseName"; if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory | Out-Null }

        $cutInfo = ""; $useFfmpegMetadata = $false
        $ffmpegMetadataFile = Join-Path $tempDir "ffmpeg_metadata.txt"
        $splitOptions = [System.StringSplitOptions]::RemoveEmptyEntries

        if ($Config.Metadata -eq "Ffmpeg") {
            Write-Log "ffmetadataを作成中..."
            # 中間処理なので静かに
            $argList = "-hide_banner -loglevel error -stats -y -i `"$InputFile`" -f ffmetadata `"$ffmpegMetadataFile`""
            $process = Start-Process $global:Settings.FfmpegPath -ArgumentList $argList -Wait -NoNewWindow -PassThru
            if ($process.ExitCode -eq 0) { $useFfmpegMetadata = $true } else { Write-Warning "ffmetadataの作成に失敗しました。" }
        }

        if ($Config.Cut -eq "Yes") {
            Write-Log "LosslessCutを起動します..."; Start-Process $global:Settings.LosslessCutPath -ArgumentList "`"$InputFile`""
            $cutStart = Read-Host "開始位置 (例:00:01:15.000)"; $cutEnd = Read-Host "終了位置 (例:00:03:30.500)"
            if ($cutStart -and $cutEnd) { $cutInfo = "-ss $cutStart -to $cutEnd"; Write-Log "カット情報: 開始 $cutStart, 終了 $cutEnd" }
            else { Write-Warning "カット位置が未入力のため、カットしません。" }
        }

        $audioOptions = $Config.EncoderSettings.Audio; $tempAudioOutFile = ""
        $tempWavFile = Join-Path $tempDir "temp_audio.wav"
        
        $audioEncType = $Config.EncoderSettings.AudioType
        if ($audioEncType -eq "qaac" -or $audioEncType -eq "nero" -or $audioEncType -eq "fdkaac") {
            $encPath = Get-EncoderPath -Type $audioEncType

            if (-not (Test-CommandExists -Command $encPath)) {
                Write-Warning "エラー: 外部エンコーダー '$encPath' が見つかりません。パスを確認してください。"
                Write-Warning "音声をコピーモード (-c:a copy) に切り替えて続行します。"
                $audioOptions = "-c:a copy"
            }
            else {
                # --- 外部音声エンコーダー共通処理 ---
                Write-Log "音声ファイルをWAVに変換中..."
                # 中間処理なので静かに
                $wavArgs = "-hide_banner -loglevel error -stats -y $($cutInfo) -i `"$InputFile`" -vn -f wav `"$tempWavFile`""
                $process = Start-Process $global:Settings.FfmpegPath -ArgumentList $wavArgs -Wait -NoNewWindow -PassThru
                if ($process.ExitCode -ne 0) {
                    Write-Warning "WAV変換失敗。音声をコピーします。"; $audioOptions = "-c:a copy"
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
                    
                    Write-Log "$($audioEncType)でエンコード処理中..."
                    try {
                        $process = Start-Process $encPath -ArgumentList $encArgs -Wait -NoNewWindow -PassThru -ErrorAction Stop
                        if ($process.ExitCode -eq 0) { $audioOptions = "" } 
                        else { Write-Warning "$($audioEncType)失敗。音声をコピーします。"; $audioOptions = "-c:a copy"; $tempAudioOutFile = "" }
                    }
                    catch {
                        Write-Warning "外部エンコーダー実行エラー: $_"
                        $audioOptions = "-c:a copy"; $tempAudioOutFile = ""
                    }
                }
            }
        }

        $ffmpegArgsList = @("-hide_banner", "-y") # 本番エンコードは標準出力
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

        Write-Log "--- ffmpeg エンコード実行 ---" -NoTimestamp
        # コマンド引数のログ表示は削除
        Write-Log "エンコード処理を開始します..."

        $process = Start-Process $global:Settings.FfmpegPath -ArgumentList $finalArgString -Wait -NoNewWindow -PassThru
        
        if ($process.ExitCode -ne 0) {
            Write-Log "エラー: ffmpegエンコード中にエラーが発生しました。 (終了コード: $($process.ExitCode))"
            if ($global:Settings.NotifyScriptPath) { & $global:Settings.NotifyScriptPath "$baseName EncodeError" }
        }
        else {
            Write-Log "ffmpegエンコードが正常に完了しました。"
            if ($Config.Metadata -eq "ExifTool") {
                Write-Log "ExifToolでメタデータをコピーしています..."
                $exifArgsList = @("-api", "largefilesupport=1", "-tagsfromfile", $InputFile, "-all:all", "-overwrite_original", $outputFile)
                $exifProcess = Start-Process $global:Settings.ExifToolPath -ArgumentList $exifArgsList -Wait -NoNewWindow -PassThru
                if ($exifProcess.ExitCode -ne 0) {
                    Write-Warning "ExifToolの実行に失敗しました。メタデータはコピーされていない可能性があります。"
                }
                Remove-Item -Path "$outputFile`_original" -ErrorAction SilentlyContinue
            }
        }

        if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force; Write-Log "一時ファイルをクリーンアップしました。" }
        Write-Log "ファイル「$(Split-Path -Leaf $InputFile)」の処理が完了しました。"
    }
    finally {
        Stop-Transcript
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
    Write-Error "予期せぬエラーが発生しました: $_"
    Write-Host "エラー詳細:" -ForegroundColor Red
    Write-Host "  スクリプト: $($_.InvocationInfo.ScriptName)" -ForegroundColor Red
    Write-Host "  行番号: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    Write-Host "  コマンド: $($_.InvocationInfo.Line.Trim())" -ForegroundColor Red
    Write-Host "  スタックトレース: $($_.ScriptStackTrace)" -ForegroundColor Yellow
}
finally {
    Write-Log "処理を終了します。"
    Read-Host "何かキーを押して終了"
    # グローバルなStop-Transcriptは不要になったため削除
}