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

# [PS 5.1 バグ回避] 万一カレントディレクトリに [ ] が含まれているとStart-Processがクラッシュするため、
# 先に入力パスを絶対パス化してから、安全なスクリプト自身のフォルダにカレントディレクトリを移動する
$Path = @($Path | ForEach-Object {
        $p = $_.Trim('"', "'")
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path (Get-Location).ProviderPath $p }
        }
    })

# PSScriptRootの確実な取得 (PS 5.1 の Split-Path -LiteralPath バグ回避)
$global:ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($global:ScriptDir)) {
    if ($MyInvocation.MyCommand.Path) {
        $global:ScriptDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
    } elseif ($MyInvocation.MyCommand.Definition) {
        $global:ScriptDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Definition)
    } else {
        $global:ScriptDir = Get-Location
    }
}
if (-not [string]::IsNullOrEmpty($global:ScriptDir)) {
    Set-Location -LiteralPath $global:ScriptDir
}

#region 初期設定とヘルパー関数

function Resolve-DeinterlaceFilter {
    param([string]$filter)
    if ($filter -match 'nnedi') {
        $weightsFile = Join-Path $global:ScriptDir 'nnedi3_weights.bin'
        if (-not (Test-Path -LiteralPath $weightsFile)) {
            Write-Host 'nnedi用ウェイトファイル(nnedi3_weights.bin)をダウンロードします...' -ForegroundColor Cyan
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/dubhater/vapoursynth-nnedi3/master/src/nnedi3_weights.bin' -OutFile $weightsFile -UseBasicParsing
                Write-Host 'ダウンロード完了しました。' -ForegroundColor Green
            } catch {
                Write-Host "ダウンロード失敗。bwdifベースへフォールバックします: $_" -ForegroundColor Yellow
                if ($filter -match 'fieldmatch') { return 'fieldmatch,decimate' }
                return 'bwdif'
            }
        }
        $escapedWeights = $weightsFile -replace '\', '/' -replace ':', '\:'
        
        if ($filter -eq 'nnedi') {
            return "nnedi=weights='$escapedWeights'"
        }
        elseif ($filter -eq 'fieldmatch,nnedi,decimate') {
            # fieldmatchで救済できなかったコーミングフレームのみをnnediで補完し、その後間引く
            return "fieldmatch,nnedi=weights='$escapedWeights':deint=interlaced,decimate"
        }
    }
    return $filter
}

# 文字コードの問題を回避するため、コンソールのエンコーディングをUTF-8に設定じゃ
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# --- 設定ファイルの読み込み ---
$configFilePath = Join-Path $global:ScriptDir "config.user.psd1"
if (-not (Test-Path $configFilePath)) {
    Write-Error "設定ファイル (config.user.psd1) が見つからぬ！話にならんわ！"
    Read-Host "何かキーを押して終了"; exit 1
}
$global:Settings = Import-PowerShellDataFile -Path $configFilePath
$global:Settings.TemplateDir = $global:ScriptDir

# --- 依存スクリプトの確認 ---
$optionsScriptPath = Join-Path $global:ScriptDir "get-ffmpegOptions.ps1"
if (-not (Test-Path $optionsScriptPath)) {
    Write-Error "エンコードオプション設定スクリプト (get-ffmpegOptions.ps1) が見つからぬ！話にならんわ！"
    Read-Host "何かキーを押して終了"; exit 1
}

#region ロギング基盤
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
    $header | Out-File -LiteralPath $global:LogFilePath -Encoding utf8 -Force
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
        try { $logMessage | Out-File -LiteralPath $global:LogFilePath -Append -Encoding utf8 } catch {}
    }
}
#endregion

#region メディア情報取得
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

function Test-IsInterlaced {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        $file = $p.Trim('"')
        if (Test-Path -LiteralPath $file -PathType Container) {
            $file = (Get-ChildItem -LiteralPath $file -File -Include *.mp4, *.mkv, *.avi, *.mov, *.ts, *.m2ts, *.iso -Recurse | Select-Object -First 1).FullName
        }
        if ($file -and (Test-Path -LiteralPath $file -PathType Leaf)) {
            $fieldOrder = & $global:Settings.FfprobePath -v error -select_streams v:0 -show_entries stream=field_order -of default=noprint_wrappers=1:nokey=1 "$file" 2>$null | Out-String
            if ($fieldOrder.Trim() -match '^(tb|bt|tt|bb)$') {
                return $true
            }
            # Check frame attributes directly for interlaced metadata
            $frameCheck = & $global:Settings.FfprobePath -v error -select_streams v:0 -show_frames -show_entries frame=interlaced_frame -read_intervals "%+#50" "$file" 2>$null | Out-String
            if ($frameCheck -match 'interlaced_frame=1') {
                return $true
            }
            # Some DVD/ISO and MPEG2 streams are flagged progressive but actually interlaced/telecined
            # Let's perform a fast idet scan across a few hundred frames
            $idetTest = & $global:Settings.FfmpegPath -hide_banner -i "$file" -filter:v idet -frames:v 500 -an -f null - 2>&1 | Select-String "Multi frame detection" | Select-Object -Last 1 | Out-String
            if ($idetTest -match 'TFF:\s+(?<tff>\d+)\s+BFF:\s+(?<bff>\d+)') {
                if ([int]$Matches.tff -gt 0 -or [int]$Matches.bff -gt 0) {
                    return $true
                }
            }
        }
    }
    return $false
}
#endregion

#region プロセス実行・エンコード実行
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
        if (Test-Path $stdoutFile) { $stdout = (Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue) }
        if (Test-Path $stderrFile) { $stderr = (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue) }
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
        Remove-Item -LiteralPath $stderrFile, $stdoutFile -Force -ErrorAction SilentlyContinue
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
                    $progContent = Get-Content -LiteralPath $progressFile -ErrorAction SilentlyContinue
                    $outTimeLine = $progContent | Where-Object { $_ -match '^out_time=' } | Select-Object -Last 1
                    $speedLine = $progContent | Where-Object { $_ -match '^speed=' } | Select-Object -Last 1
                    $fpsLine = $progContent | Where-Object { $_ -match '^fps=' } | Select-Object -Last 1
                    $bitrateLine = $progContent | Where-Object { $_ -match '^bitrate=' } | Select-Object -Last 1
                    if ($outTimeLine) {
                        $outTime = (($outTimeLine -split '=', 2)[1]).Trim()
                        $speed = if ($speedLine) { (($speedLine -split '=', 2)[1]).Trim() } else { "N/A" }
                        $fps = if ($fpsLine) { (($fpsLine -split '=', 2)[1]).Trim() } else { "N/A" }
                        $bitrate = if ($bitrateLine) { (($bitrateLine -split '=', 2)[1]).Trim() } else { "N/A" }
                        $pct = ""
                        if ($DurationSeconds -gt 0 -and $outTime -ne "N/A") {
                            try {
                                $currentSec = [TimeSpan]::Parse($outTime).TotalSeconds
                                $pct = " ({0:F1}%)" -f [Math]::Min(100, ($currentSec / $DurationSeconds) * 100)
                            }
                            catch {}
                        }
                        Write-Host "`r  進捗: $outTime / 速度: $speed$pct / fps: $fps / bitrate: $bitrate       " -NoNewline
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
        if (Test-Path $stdoutFile) { $stdout = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue }
        if (Test-Path $stderrFile) { $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue }
        if ($stderr -and $stderr.Trim()) {
            $sLines = ($stderr -split "`r?`n") | Where-Object {
                $_ -match '(Input #|Output #|Stream #|Stream mapping|frame=.*Lsize=|video:.*audio:)'
            }
            if ($sLines) { Write-Log "[ffmpeg サマリー]`n$($sLines -join "`n")" }

            # GPU/HW処理情報をログに記録
            # NOTE: Stream mappingの "(h264 (native) -> ...)" は実際のhwaccel使用有無を正確に表さないため、
            # 実行引数(-hwaccel/-c:v/hwdownload)を優先して判定する。
            $hwLines = ($stderr -split "`r?`n") | Where-Object {
                $_ -match '(hwaccel|Hardware|hw_device|Device type|Using auto|AMF|NVENC|QSV|VAAPI|VDPAU|CUDA|D3D11|Vulkan|VideoToolbox)'
            }

            $hwAccelType = ""
            if ($Arguments -match '(?:^|\s)-hwaccel\s+(\S+)') { $hwAccelType = $Matches[1] }

            $hwOutputFmt = ""
            if ($Arguments -match '(?:^|\s)-hwaccel_output_format\s+(\S+)') { $hwOutputFmt = $Matches[1] }

            $videoEncoder = ""
            if ($Arguments -match '(?:^|\s)-c:v\s+(\S+)') { $videoEncoder = $Matches[1] }

            $decodePath = if ($hwAccelType) { "GPU ($hwAccelType)" } else { "CPU" }
            $encodePath = if ($videoEncoder -match '_(amf|nvenc|qsv|vaapi|videotoolbox)') {
                "GPU ($($Matches[1]))"
            }
            else {
                "CPU"
            }

            $transferPath = @()
            if ($Arguments -match '(?:^|\s)-vf\s+"[^"]*hwdownload') { $transferPath += "GPU→CPU転送: 有効 (hwdownload)" }
            if ($Arguments -match '(?:^|\s)-vf\s+"[^"]*hwupload') { $transferPath += "CPU→GPU転送: 有効 (hwupload)" }

            $gpuInfo = @("  デコード: $decodePath / エンコード: $encodePath")
            if ($hwOutputFmt) { $gpuInfo += "  HW出力フォーマット: $hwOutputFmt" }
            if ($videoEncoder) { $gpuInfo += "  映像エンコーダー: $videoEncoder" }
            foreach ($tp in $transferPath) { $gpuInfo += "  $tp" }

            if ($hwLines -or $gpuInfo) {
                $logMsg = "[GPU/HW処理情報]"
                if ($hwLines) { $logMsg += "`n$($hwLines -join "`n")" }
                if ($gpuInfo) { $logMsg += "`n$($gpuInfo -join "`n")" }
                Write-Log $logMsg
            }

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
        Remove-Item -LiteralPath $stderrFile, $stdoutFile, $progressFile -Force -ErrorAction SilentlyContinue
    }
}
#endregion

#region UIユーティリティ
function Show-Menu {
    param ([string]$Title, [string[]]$Choices, [int]$DefaultIndex = 0, [switch]$NoClear)
    $currentIndex = $DefaultIndex
    while ($true) {
        if (-not $NoClear) { Clear-Host }; Write-Host "$Title`n"
        for ($i = 0; $i -lt $Choices.Length; $i++) {
            if ($i -eq $currentIndex) { Write-Host -ForegroundColor Black -BackgroundColor White " > $($Choices[$i])" }
            else { Write-Host "   $($Choices[$i])" }
        }
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        switch ($key.VirtualKeyCode) {
            38 { if ($currentIndex -gt 0) { $currentIndex-- } }       # UpArrow
            40 { if ($currentIndex -lt ($Choices.Length - 1)) { $currentIndex++ } } # DownArrow
            13 { return $currentIndex } # Enter
            27 { return -1 }            # Escape
        }
    }
}

# Show-Menuをグローバルに公開 (get-ffmpegOptions.ps1 からも利用するため)
Set-Item -Path function:global:Show-Menu -Value (Get-Item -LiteralPath function:Show-Menu).ScriptBlock

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
#endregion

#region 外部エンコーダー関連
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

function Get-ExternalEncoderAvailability {
    <#
    .SYNOPSIS
        外部音声エンコーダー (qaac, nero, fdkaac) の存在をチェックし結果をハッシュテーブルで返す。
        結果はグローバルキャッシュされ、2回目以降は即座に返される。
    #>
    if ($global:ExternalEncoderCache) { return $global:ExternalEncoderCache }
    $result = @{ HasQaac = $false; HasNero = $false; HasFdkaac = $false }
    if ($global:Settings) {
        if ($global:Settings.QaacPath) { try { $null = Get-Command $global:Settings.QaacPath -ErrorAction Stop; $result.HasQaac = $true } catch {} }
        if ($global:Settings.NeroAacEncPath) { try { $null = Get-Command $global:Settings.NeroAacEncPath -ErrorAction Stop; $result.HasNero = $true } catch {} }
        if ($global:Settings.FdkaacPath) { try { $null = Get-Command $global:Settings.FdkaacPath -ErrorAction Stop; $result.HasFdkaac = $true } catch {} }
    }
    $global:ExternalEncoderCache = $result
    return $result
}

function Select-QaacOptions {
    <#
    .SYNOPSIS
        qaac音声品質選択メニューを表示し、Options/Description を含むハッシュテーブルを返す。
        キャンセル時は $null を返す。
    #>
    $qaacChoices = @("AAC-LC TVBR 91 (~192kbps)", "AAC-LC TVBR 73 (~160kbps)", "AAC-LC TVBR 64 (~128kbps)", "HE-AAC CVBR 80kbps", "HE-AAC CVBR 64kbps", "HE-AAC CVBR 48kbps", "カスタム")
    $qaacIndex = Show-Menu -Title "qaac品質を選択 (LC=TVBR / HE=CVBR)" -Choices $qaacChoices
    if ($qaacIndex -lt 0) { return $null }
    if ($qaacIndex -eq 6) {
        $profileChoices = @("AAC-LC (TVBR品質指定)", "HE-AAC (CVBRビットレート指定)")
        $pIndex = Show-Menu -Title "qaacプロファイルを選択" -Choices $profileChoices
        if ($pIndex -lt 0) { return $null }
        if ($pIndex -eq 0) {
            $tvbrVal = [int](Read-Host "TVBR値を入力 (0 ~ 127)")
            return @{ Type = "qaac"; Options = "--tvbr $tvbrVal"; Description = "qaac AAC-LC TVBR $tvbrVal" }
        }
        else {
            $cvbrVal = [int](Read-Host "CVBRビットレートを入力 (kbps, 例: 64)")
            return @{ Type = "qaac"; Options = "--he --cvbr $cvbrVal"; Description = "qaac HE-AAC CVBR ${cvbrVal}kbps" }
        }
    }
    elseif ($qaacIndex -le 2) {
        $tvbrVal = @(91, 73, 64)[$qaacIndex]
        return @{ Type = "qaac"; Options = "--tvbr $tvbrVal"; Description = "qaac AAC-LC TVBR $tvbrVal" }
    }
    else {
        $cvbrVal = @(80, 64, 48)[$qaacIndex - 3]
        return @{ Type = "qaac"; Options = "--he --cvbr $cvbrVal"; Description = "qaac HE-AAC CVBR ${cvbrVal}kbps" }
    }
}

function Select-NeroOptions {
    <#
    .SYNOPSIS
        Nero AAC品質選択メニューを表示し、Options/Description を含むハッシュテーブルを返す。
    #>
    $neroChoices = @("高品質 (-q 0.65)", "標準品質 (-q 0.50)", "通常品質 (-q 0.35)", "低品質 (-q 0.20)", "カスタム")
    $neroIndex = Show-Menu -Title "Nero AAC品質を選択 (≤-q0.40:HE / >-q0.40:LC 自動)" -Choices $neroChoices
    if ($neroIndex -lt 0) { return $null }
    $qVal = if ($neroIndex -eq 4) { [double](Read-Host "品質値を入力 (0.0 ~ 1.0)") } else { @(0.65, 0.50, 0.35, 0.20)[$neroIndex] }
    $heFlag = if ($qVal -le 0.40) { "-he " } else { "" }
    $profileName = if ($qVal -le 0.40) { "HE-AAC" } else { "AAC-LC" }
    return @{ Type = "nero"; Options = "${heFlag}-q $qVal"; Description = "Nero $profileName -q $qVal" }
}

function Select-FdkaacOptions {
    <#
    .SYNOPSIS
        fdkaac品質選択メニューを表示し、Options/Description を含むハッシュテーブルを返す。
    #>
    $fdkChoices = @("最高品質 (VBR 5)", "高品質 (VBR 4)", "標準品質 (VBR 3)", "低品質 (VBR 2)", "カスタム")
    $fdkIndex = Show-Menu -Title "fdkaac品質を選択 (≤VBR3:HE / ≥VBR4:LC 自動)" -Choices $fdkChoices
    if ($fdkIndex -lt 0) { return $null }
    $vbrVal = if ($fdkIndex -eq 4) { [int](Read-Host "VBR値を入力 (1 ~ 5)") } else { @(5, 4, 3, 2)[$fdkIndex] }
    $heFlag = if ($vbrVal -le 3) { "-p 5 " } else { "" }
    $profileName = if ($vbrVal -le 3) { "HE-AAC" } else { "AAC-LC" }
    return @{ Type = "fdkaac"; Options = "${heFlag}-m $vbrVal"; Description = "fdkaac $profileName VBR $vbrVal" }
}

function Select-OpusOptions {
    <#
    .SYNOPSIS
        Opus品質選択メニューを表示し、Options/Description を含むハッシュテーブルを返す。
    #>
    param([string[]]$BitrateChoices = @("192 kbps", "160 kbps", "128 kbps", "96 kbps", "64 kbps", "48 kbps", "カスタム"))
    $bitrateMap = @("192k", "160k", "128k", "96k", "64k", "48k")
    $opusIndex = Show-Menu -Title "Opusのビットレートを選択" -Choices $BitrateChoices
    if ($opusIndex -lt 0) { return $null }
    if ($opusIndex -ge $bitrateMap.Count) {
        $brVal = Read-Host "ビットレートを入力 (例: 32k)"
        return @{ Type = "internal"; Options = "-c:a libopus -b:a $brVal"; Description = "Opus: カスタムビットレート ($brVal)" }
    }
    $bitrate = $bitrateMap[$opusIndex]
    return @{ Type = "internal"; Options = "-c:a libopus -b:a $bitrate"; Description = "Opus: $($BitrateChoices[$opusIndex])" }
}

function Invoke-AudioEncoderFallback {
    <#
    .SYNOPSIS
        外部エンコーダー失敗時のフォールバック処理。
        ソース音声がコンテナ互換ならコピー、非互換なら音声除去を返す。
    #>
    param(
        [string]$InputFile,
        [string]$ContainerExtension,
        [string]$Reason = ""
    )
    if ($Reason) { Write-Log $Reason -Level "WARN" }
    $srcInfo = Get-SourceAudioInfo -FilePath $InputFile
    if ($srcInfo.CodecName -and (Test-AudioCodecCompatibility -CodecName $srcInfo.CodecName -ContainerExtension $ContainerExtension)) {
        Write-Log "ソース音声 ($($srcInfo.CodecName), $($srcInfo.BitrateKbps)kbps) は .$ContainerExtension と互換 → コピーモード" -Level "WARN"
        return @{ Options = "-c:a copy"; BitrateKbps = $srcInfo.BitrateKbps }
    }
    else {
        Write-Log "ソース音声 ($($srcInfo.CodecName)) は .$ContainerExtension と非互換 → 音声を除去します" -Level "WARN"
        return @{ Options = "-an"; BitrateKbps = 0 }
    }
}

function Test-HwAccelRelatedFailure {
    <#
    .SYNOPSIS
        ffmpegの標準エラー出力からHWアクセラレーション関連の失敗を検出する。
    #>
    param([string]$StdErr)
    if (-not $StdErr) { return $false }
    return ($StdErr -match 'Failed setup for format|hwaccel initialisation returned error|Error reinitializing filters|Device does not support.*VK_|hw_device_ctx.*failed|Cannot map.*surface|hwframe.*error')
}

function Remove-HwAccelFromArgs {
    <#
    .SYNOPSIS
        ffmpegの引数文字列からHWアクセル関連のオプションを除去する。
        リトライ時にHWアクセルなしで再実行するために使用。
    #>
    param([string]$ArgString)
    $result = $ArgString
    # HWアクセルパラメータを除去 (順序: output_format → hwaccel → extra_hw_frames)
    $result = $result -replace '\s*-hwaccel_output_format\s+\S+', ''
    $result = $result -replace '\s*-hwaccel\s+\S+', ''
    $result = $result -replace '\s*-extra_hw_frames\s+\d+', ''
    # -vfからhwdownloadを除去
    # Case 1: hwdownload,format=nv12 のみ → -vf自体を除去
    $result = $result -replace '\s*-vf\s+"hwdownload,format=nv12"', ''
    # Case 2: hwdownload,format=nv12,<他のフィルタ> → hwdownload部分のみ除去
    $result = $result -replace '(-vf\s+")hwdownload,format=nv12,', '$1'
    return ($result -replace '\s{2,}', ' ').Trim()
}
#endregion

#region ハードウェア検出・コーデックフィルタ
function Get-AvailableHardware {
    <#
    .SYNOPSIS
        テストエンコード/デコードを実行してハードウェア・コーデックの実対応状況を検出する。
        各エンコーダーで実際にテストエンコードし、成功したもののみ有効とする。
        結果はグローバル変数にキャッシュされ、2回目以降は即座に返される。
    #>
    if ($global:HardwareInfo) { return $global:HardwareInfo }

    $info = @{
        AvailableEncoders = @()
        AvailableHwAccels = @()
        HasNvidia         = $false
        HasIntel          = $false
        HasAMD            = $false
        ScanCompleted     = $false
    }
    
    try {
        $ffmpegPath = $global:Settings.FfmpegPath

        # --- HWエンコーダー実機検出 (テストエンコード) ---
        $testEncoders = @(
            'h264_nvenc', 'hevc_nvenc', 'av1_nvenc',
            'h264_qsv', 'hevc_qsv', 'av1_qsv', 'vp9_qsv',
            'h264_amf', 'hevc_amf', 'av1_amf'
        )

        foreach ($enc in $testEncoders) {
            try {
                $null = & $ffmpegPath -hide_banner -f lavfi -i 'color=c=black:s=256x256:d=0.5:r=25' -frames:v 1 -pix_fmt nv12 -c:v $enc -f null NUL 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $info.AvailableEncoders += $enc
                }
            } catch {}
        }

        $info.HasNvidia = @($info.AvailableEncoders | Where-Object { $_ -match '_nvenc$' }).Count -gt 0
        $info.HasIntel = @($info.AvailableEncoders | Where-Object { $_ -match '_qsv$' }).Count -gt 0
        $info.HasAMD = @($info.AvailableEncoders | Where-Object { $_ -match '_amf$' }).Count -gt 0

        # --- HWアクセル (デコード) 実機検出 ---
        $testClipPath = Join-Path ([System.IO.Path]::GetTempPath()) "hwaccel_test_$([System.IO.Path]::GetRandomFileName()).mp4"
        try {
            $null = & $ffmpegPath -hide_banner -y -f lavfi -i 'color=c=black:s=256x256:d=0.5:r=25' -frames:v 5 -pix_fmt yuv420p -c:v libx264 -preset ultrafast "$testClipPath" 2>&1
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $testClipPath)) {
                
                $hwaccelList = @('cuda', 'qsv', 'amf', 'd3d11va', 'dxva2', 'vulkan')
                foreach ($accel in $hwaccelList) {
                    try {
                        # -hwaccel を指定して実際にデコードテストを行う。
                        $testOut = & $ffmpegPath -hide_banner -hwaccel $accel -i "$testClipPath" -frames:v 1 -f null - 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            $hasInitError = ($testOut | Out-String) -match 'Failed setup|initialisation returned error|Device does not support|No device available|Hardware device setup failed|Error creating a MFX session'
                            if (-not $hasInitError) {
                                $info.AvailableHwAccels += $accel
                            } else {
                                Write-Log "  HWアクセル '$accel': 初期化エラー検出 → 除外" -Level "DEBUG"
                            }
                        }
                    } catch {}
                }
            } else {
                Write-Log "HWアクセルテスト用クリップの生成に失敗しました。" -Level "WARN"
            }
        } finally {
            Remove-Item -LiteralPath $testClipPath -Force -ErrorAction SilentlyContinue
        }
        
        # エンコーダ側で存在が確認できたなら、デコーダテスト("-hwaccel"のエラーやフォーマット非互換等)で漏れても強制追加する
        if ($info.HasNvidia -and ($info.AvailableHwAccels -notcontains 'cuda')) { $info.AvailableHwAccels += 'cuda' }
        if ($info.HasIntel  -and ($info.AvailableHwAccels -notcontains 'qsv'))  { $info.AvailableHwAccels += 'qsv' }
        if ($info.HasAMD    -and ($info.AvailableHwAccels -notcontains 'amf'))  { $info.AvailableHwAccels += 'amf' }

        $info.ScanCompleted = $true

        Write-Log "テスト結果: NVIDIA=$($info.HasNvidia) Intel=$($info.HasIntel) AMD=$($info.HasAMD)" -Level "DEBUG"
        Write-Log "  エンコーダー: [$($info.AvailableEncoders -join ', ')]" -Level "DEBUG"
        Write-Log "  HWアクセル  : [$($info.AvailableHwAccels -join ', ')]" -Level "DEBUG"
    }
    catch {
        Write-Log "ハードウェアスキャンに失敗しました: $_" -Level "WARN"
    }

    $global:HardwareInfo = $info
    return $info
}

function Get-FilteredHwChoices {
    <#
    .SYNOPSIS
        ハードウェアスキャン結果に基づき、対応するHWエンコーダーのみの選択肢を返す。
        CPUは常に含まれる。
    .OUTPUTS
        @{ Choices = [string[]]; Keys = [string[]]; OriginalIndices = [int[]] }
    #>
    $allChoices = @("NVIDIA (NVENC)", "Intel (QSV)", "AMD (AMF)", "CPU (Software)")
    $allKeys = @("NVIDIA", "Intel", "AMD", "CPU")
    $hwInfo = $global:HardwareInfo

    $filteredChoices = @()
    $filteredKeys = @()
    $filteredIndices = @()

    for ($i = 0; $i -lt $allChoices.Length; $i++) {
        $show = $true
        if ($hwInfo) {
            switch ($allKeys[$i]) {
                "NVIDIA" { $show = $hwInfo.HasNvidia }
                "Intel" { $show = $hwInfo.HasIntel }
                "AMD" { $show = $hwInfo.HasAMD }
                "CPU" { $show = $true }
            }
        }
        if ($show) {
            $filteredChoices += $allChoices[$i]
            $filteredKeys += $allKeys[$i]
            $filteredIndices += $i
        }
    }

    return @{ Choices = $filteredChoices; Keys = $filteredKeys; OriginalIndices = $filteredIndices }
}

function Get-FilteredCodecChoices {
    <#
    .SYNOPSIS
        指定ハードウェアで利用可能なコーデックのみをフィルタして返す。
    .PARAMETER Choices
        コーデック表示名の配列 (例: @("H.265/HEVC", "H.264/AVC", "AV1"))
    .PARAMETER EncoderNames
        FFmpegエンコーダー名の配列 (例: @("hevc_nvenc", "h264_nvenc", "av1_nvenc"))
    .OUTPUTS
        @{ Choices = [string[]]; EncoderNames = [string[]]; OriginalIndices = [int[]] }
    #>
    param(
        [string[]]$Choices,
        [string[]]$EncoderNames
    )
    $hwInfo = $global:HardwareInfo
    if (-not $hwInfo -or $hwInfo.AvailableEncoders.Count -eq 0) {
        # スキャン結果なし → 全て表示
        return @{ Choices = $Choices; EncoderNames = $EncoderNames; OriginalIndices = @(0..($Choices.Length - 1)) }
    }

    $fc = @(); $fe = @(); $fi = @()
    for ($i = 0; $i -lt $Choices.Length; $i++) {
        if ($hwInfo.AvailableEncoders -contains $EncoderNames[$i]) {
            $fc += $Choices[$i]; $fe += $EncoderNames[$i]; $fi += $i
        }
    }
    return @{ Choices = $fc; EncoderNames = $fe; OriginalIndices = $fi }
}

function Get-PlatformAvailableCodecs {
    <#
    .SYNOPSIS
        指定ハードウェアとプラットフォーム許可リストに基づき、利用可能なコーデック名の配列を返す。
    .OUTPUTS
        string[] - 利用可能なコーデック名 (例: @("H.264", "H.265", "AV1"))
    #>
    param(
        [string]$HW,
        [string[]]$AllowedCodecs
    )
    $hwCodecMap = @{
        "NVIDIA" = @(@{Codec = "H.264"; Enc = "h264_nvenc" }, @{Codec = "H.265"; Enc = "hevc_nvenc" }, @{Codec = "AV1"; Enc = "av1_nvenc" })
        "Intel"  = @(@{Codec = "H.264"; Enc = "h264_qsv" }, @{Codec = "H.265"; Enc = "hevc_qsv" }, @{Codec = "VP9"; Enc = "vp9_qsv" }, @{Codec = "AV1"; Enc = "av1_qsv" })
        "AMD"    = @(@{Codec = "H.264"; Enc = "h264_amf" }, @{Codec = "H.265"; Enc = "hevc_amf" }, @{Codec = "AV1"; Enc = "av1_amf" })
        "CPU"    = @(@{Codec = "H.264"; Enc = "libx264" }, @{Codec = "H.265"; Enc = "libx265" }, @{Codec = "VP9"; Enc = "libvpx-vp9" }, @{Codec = "AV1"; Enc = "libsvtav1" })
    }
    $hwInfo = $global:HardwareInfo
    $available = @()
    foreach ($entry in $hwCodecMap[$HW]) {
        if ($AllowedCodecs -contains $entry.Codec) {
            if ($HW -eq "CPU" -or -not $hwInfo -or $hwInfo.AvailableEncoders.Count -eq 0 -or $hwInfo.AvailableEncoders -contains $entry.Enc) {
                $available += $entry.Codec
            }
        }
    }
    return $available
}
#endregion
#endregion

#region プラットフォームアップロード機能

#region 音声・ビットレート計算
function Get-AudioBitrateFromOptions {
    <#
    .SYNOPSIS
        音声オプション文字列から音声ビットレート(kbps)を取得する。
        外部エンコーダーの場合は先行エンコード後に Get-AudioBitrateFromFile で実測すること。
        コピーモードの場合は SourceBitrateKbps を渡すか、0ならffprobeで取得済みの値を使用。
    #>
    param(
        [string]$AudioOptions,
        [string]$AudioType,
        [int]$SourceBitrateKbps = 0
    )
    # 音声なしの場合
    if ($AudioType -eq "none" -or $AudioOptions -eq "-an") { return 0 }
    # 音声コピーの場合: ソースビットレートが渡されていればそれを使用
    if ($AudioType -eq "copy" -or $AudioOptions -eq "-c:a copy") {
        if ($SourceBitrateKbps -gt 0) { return $SourceBitrateKbps }
        return 128
    }
    # -b:a XXXk パターンを解析
    if ($AudioOptions -match '-b:a\s+(\d+)k') {
        return [int]$Matches[1]
    }
    # qaac --cvbr <bitrate> パターンを解析 (HE-AAC CVBR)
    if ($AudioOptions -match '--cvbr\s+(\d+)') {
        return [int]$Matches[1]
    }
    # qaac/nero/fdkaac 等の外部エンコーダーは先行エンコード後に実測するため、ここでは仮に128kbpsを返す
    if ($AudioType -eq "qaac" -or $AudioType -eq "nero" -or $AudioType -eq "fdkaac") { return 128 }
    # VBR品質指定 (libvorbis -q:a X) の場合は推定不能のため128kbpsを仮定
    return 128
}

function Get-AudioBitrateFromFile {
    <#
    .SYNOPSIS
        完成した音声ファイルのサイズと動画長からビットレート(kbps)を実測する。
    #>
    param(
        [string]$AudioFilePath,
        [double]$DurationSeconds
    )
    if (-not (Test-Path $AudioFilePath) -or $DurationSeconds -le 0) { return 128 }
    try {
        $fileSizeBytes = (Get-Item $AudioFilePath).Length
        $bitrateKbps = [math]::Round(($fileSizeBytes * 8) / ($DurationSeconds * 1000))
        if ($bitrateKbps -le 0) { return 128 }
        return $bitrateKbps
    }
    catch { return 128 }
}

function Get-SourceAudioInfo {
    <#
    .SYNOPSIS
        入力ファイルの音声ストリーム情報 (コーデック名・ビットレート) をffprobeで取得する。
    #>
    param([string]$FilePath)
    try {
        $jsonStr = & $global:Settings.FfprobePath -v quiet -print_format json -show_streams -select_streams a:0 "$FilePath" 2>$null | Out-String
        $json = $jsonStr | ConvertFrom-Json
        $stream = $json.streams | Select-Object -First 1
        if (-not $stream) { return @{ CodecName = ""; BitrateKbps = 0 } }
        $br = if ($stream.bit_rate) { [math]::Round([double]$stream.bit_rate / 1000) } else { 0 }
        return @{ CodecName = $stream.codec_name; BitrateKbps = $br }
    }
    catch { return @{ CodecName = ""; BitrateKbps = 0 } }
}

function Test-AudioCodecCompatibility {
    <#
    .SYNOPSIS
        音声コーデックが出力コンテナに対応しているかチェックする。
    #>
    param(
        [string]$CodecName,
        [string]$ContainerExtension
    )
    $compatMap = @{
        "mp4"  = @("aac", "ac3", "eac3", "mp3", "alac", "flac", "opus")
        "m4a"  = @("aac", "alac")
        "webm" = @("opus", "vorbis")
        "mkv"  = @("aac", "ac3", "eac3", "mp3", "alac", "flac", "opus", "vorbis", "pcm_s16le", "pcm_s24le", "pcm_f32le", "dts", "truehd")
        "avi"  = @("mp3", "ac3", "pcm_s16le", "aac")
        "mov"  = @("aac", "ac3", "eac3", "mp3", "alac", "flac", "opus", "pcm_s16le", "pcm_s24le")
    }
    $supported = $compatMap[$ContainerExtension]
    if (-not $supported) { return $true }  # 不明なコンテナ → 互換ありと仮定
    return ($CodecName -in $supported)
}
#endregion

#region ビットレート・映像オプション構築
function Get-TargetBitrateKbps {
    param(
        [double]$MaxFileSizeMB,
        [double]$DurationSeconds,
        [double]$AudioBitrateKbps = 128,
        [double]$MarginFactor = 0.90
    )
    if ($DurationSeconds -le 0) { return 0 }
    # コンテナオーバーヘッドとエンコーダーのビットレート超過を考慮したマージンじゃ
    # コーデック別マージン例: H.264/H.265=0.92, VP9=0.88, SVT-AV1=0.82
    $totalBitrateKbps = ($MaxFileSizeMB * $MarginFactor * 8 * 1024) / $DurationSeconds
    $videoBitrateKbps = $totalBitrateKbps - $AudioBitrateKbps
    return [math]::Max(100, [math]::Round($videoBitrateKbps))
}

function Build-PlatformVideoOptions {
    param(
        [string]$HW,              # "NVIDIA", "Intel", "AMD", "CPU"
        [string]$Codec,           # "H.264", "H.265", "VP9", "AV1"
        [string]$QualityMode,     # "CRF", "CRF+Maxrate", "Bitrate"
        [int]$QualityValue,       # CRF/CQ/QP値
        [string]$Preset,          # エンコード速度プリセット
        [int]$MaxrateKbps = 0,    # CRF+MaxrateまたはBitrateモード用
        [string]$SpecificEncoder = ""  # CPU AV1: "libsvtav1", "libaom-av1", "rav1e" を指定可
    )
    $encoderMap = @{
        "NVIDIA+H.264" = "h264_nvenc"; "NVIDIA+H.265" = "hevc_nvenc"; "NVIDIA+AV1" = "av1_nvenc"
        "Intel+H.264" = "h264_qsv"; "Intel+H.265" = "hevc_qsv"; "Intel+AV1" = "av1_qsv"; "Intel+VP9" = "vp9_qsv"
        "AMD+H.264" = "h264_amf"; "AMD+H.265" = "hevc_amf"; "AMD+AV1" = "av1_amf"
        "CPU+H.264" = "libx264"; "CPU+H.265" = "libx265"; "CPU+VP9" = "libvpx-vp9"; "CPU+AV1" = "libsvtav1"
    }
    $encoder = $encoderMap["$HW+$Codec"]
    if (-not $encoder) { return $null }
    # SpecificEncoder指定時はエンコーダーを上書き (CPU AV1で libaom-av1/rav1e を使う場合)
    if ($SpecificEncoder) { $encoder = $SpecificEncoder }

    $parts = @("-c:v $encoder")
    switch ($HW) {
        "NVIDIA" {
            switch ($QualityMode) {
                "CRF" { $parts += "-rc vbr -cq $QualityValue" }
                "CRF+Maxrate" { $parts += "-rc vbr -cq $QualityValue -maxrate ${MaxrateKbps}k -bufsize $($MaxrateKbps * 2)k" }
                "Bitrate" { $parts += "-rc vbr -b:v ${MaxrateKbps}k -maxrate ${MaxrateKbps}k -bufsize $($MaxrateKbps * 2)k" }
            }
            $parts += "-preset $Preset"
            $parts += "-tune hq"
        }
        "Intel" {
            switch ($QualityMode) {
                "CRF" { $parts += "-global_quality $QualityValue" }
                "CRF+Maxrate" { $parts += "-global_quality $QualityValue -maxrate ${MaxrateKbps}k -bufsize $($MaxrateKbps * 2)k" }
                "Bitrate" { $parts += "-b:v ${MaxrateKbps}k -maxrate ${MaxrateKbps}k -bufsize $($MaxrateKbps * 2)k" }
            }
            $parts += "-preset $Preset"
        }
        "AMD" {
            switch ($QualityMode) {
                "CRF" { $parts += "-rc cqp -qp_i $QualityValue -qp_p $QualityValue -qp_b $QualityValue" }
                "CRF+Maxrate" { $parts += "-rc vbr_peak -qp_i $QualityValue -qp_p $QualityValue -b:v ${MaxrateKbps}k -maxrate ${MaxrateKbps}k" }
                "Bitrate" { $parts += "-rc vbr_peak -b:v ${MaxrateKbps}k -maxrate ${MaxrateKbps}k" }
            }
            $parts += "-quality $Preset"
        }
        "CPU" {
            $isVPx = $Codec -match "VP"
            $isAV1 = $Codec -match "AV1"
            $isAV1Svt = $encoder -eq "libsvtav1"
            $isAV1Aom = $encoder -eq "libaom-av1"
            $isAV1Rav1e = $encoder -eq "rav1e"
            switch ($QualityMode) {
                "CRF" {
                    if ($isAV1Rav1e) { $parts += "-qp $QualityValue" }
                    else { $parts += "-crf $QualityValue" }
                    if ($isVPx -or $isAV1Aom) { $parts += "-b:v 0" }
                }
                "CRF+Maxrate" {
                    if ($isVPx) {
                        # VP8/VP9: CRF + ターゲットビットレートで制御
                        $parts += "-crf $QualityValue -b:v ${MaxrateKbps}k"
                    }
                    elseif ($isAV1Svt) {
                        # SVT-AV1: capped CRF (bufsize=maxrateで厳密に制御)
                        $parts += "-crf $QualityValue -maxrate ${MaxrateKbps}k -bufsize ${MaxrateKbps}k"
                    }
                    elseif ($isAV1Aom) {
                        # libaom-av1: constrained quality (CRF + ターゲットビットレート)
                        $parts += "-crf $QualityValue -b:v ${MaxrateKbps}k"
                    }
                    elseif ($isAV1Rav1e) {
                        # rav1e: CRF+Maxrate非対応のためビットレートモードで代替
                        $parts += "-b:v ${MaxrateKbps}k"
                    }
                    else {
                        # H.264/H.265: VBV制御
                        $parts += "-crf $QualityValue -maxrate ${MaxrateKbps}k -bufsize $($MaxrateKbps * 2)k"
                    }
                }
                "Bitrate" {
                    if ($isAV1Svt) {
                        # SVT-AV1: Bitrateモードではmaxrate/bufsize非対応。目標ビットレートのみ指定
                        $parts += "-b:v ${MaxrateKbps}k"
                    }
                    elseif ($isAV1Aom -or $isAV1Rav1e -or $isVPx) {
                        # AV1/VPx系はターゲットビットレートのみ指定
                        $parts += "-b:v ${MaxrateKbps}k"
                    }
                    else {
                        $parts += "-b:v ${MaxrateKbps}k -maxrate ${MaxrateKbps}k -bufsize $($MaxrateKbps * 2)k"
                    }
                }
            }
            # マルチスレッド設定
            if ($isAV1Aom) { $parts += "-row-mt 1 -tiles 2x2" }
            if ($isAV1Rav1e) { $parts += "-tiles 4" }
            # 速度/プリセット設定
            if ($isVPx) { $parts += "-cpu-used $Preset" }
            elseif ($isAV1Svt) { $parts += "-preset $Preset" }
            elseif ($isAV1Aom) { $parts += "-cpu-used $Preset" }
            elseif ($isAV1Rav1e) { $parts += "-speed $Preset" }
            else { $parts += "-preset $Preset" }
        }
    }

    return ($parts -join ' ')
}
#endregion

#region プラットフォーム自動設定
function Get-PlatformAutoSettings {
    param(
        [hashtable]$PlatformConfig,
        [string]$HW,
        [string]$Codec
    )
    # プラットフォーム特性に応じた自動設定を返す
    # 方針: 容量に収めることが最優先 → CRF+Maxrate で品質と容量を両立
    $codec = $Codec; $qualityValue = 0; $preset = ""; $audioSetting = $null; $scaleFilter = ""; $extension = ""
    if (-not $codec) { return $null }

    # --- 品質値 (CRF/CQ/QP) --- maxrateが容量制限するため高品質ベースラインを使用
    $qualityValue = switch ($codec) { "H.264" { 18 }; "H.265" { 22 }; "VP9" { 25 }; "AV1" { 23 } }

    # --- プリセット --- バランス型
    $preset = switch ($HW) {
        "NVIDIA" { "p4" }; "Intel" { "medium" }; "AMD" { "balanced" }
        "CPU" { if ($codec -match "VP|AV1") { "4" } else { "medium" } }
    }

    # --- コンテナ --- (音声判定で必要なため先に決定)
    $extension = $PlatformConfig.Extension
    if (-not $extension) {
        $extension = switch ($codec) { "VP9" { "webm" }; "AV1" { "webm" }; default { "mp4" } }
    }

    # --- 音声 --- MP4コンテナ時の優先度: qaac > fdkaac > NeroAAC > ffmpeg内蔵AAC / WebM時: Opus
    $extEnc = Get-ExternalEncoderAvailability

    # HE-AAC/AAC-LC 自動判定: qaac HE=CVBR/LC=TVBR, fdkaac VBR≤3=HE/≥4=LC, nero -q≤0.40=HE/>0.40=LC
    $needsAAC = ($extension -eq "mp4")
    if ($PlatformConfig.MaxFileSizeMB -le 50) {
        if ($needsAAC) {
            # MP4コンテナ: 外部エンコーダー優先 (小容量向け低ビットレート → HE-AAC CVBR)
            if ($extEnc.HasQaac) {
                $audioSetting = @{ Type = "qaac"; Options = "--he --cvbr 64"; Description = "qaac HE-AAC CVBR 64kbps (自動)" }
            }
            elseif ($extEnc.HasFdkaac) {
                $audioSetting = @{ Type = "fdkaac"; Options = "-p 5 -m 3"; Description = "fdkaac HE-AAC VBR 3 (自動)" }
            }
            elseif ($extEnc.HasNero) {
                $audioSetting = @{ Type = "nero"; Options = "-he -q 0.35"; Description = "Nero HE-AAC -q 0.35 (自動)" }
            }
            else {
                $audioSetting = @{ Type = "internal"; Options = "-c:a aac -b:a 96k"; Description = "AAC-LC 96kbps (自動/HE非対応)" }
            }
        }
        else {
            $audioSetting = @{ Type = "internal"; Options = "-c:a libopus -b:a 64k"; Description = "Opus 64kbps (自動)" }
        }
    }
    else {
        if ($needsAAC) {
            # MP4コンテナ: 外部エンコーダー優先 (通常品質 → AAC-LC自動)
            if ($extEnc.HasQaac) {
                $audioSetting = @{ Type = "qaac"; Options = "--tvbr 64"; Description = "qaac AAC-LC TVBR 64 (自動)" }
            }
            elseif ($extEnc.HasFdkaac) {
                $audioSetting = @{ Type = "fdkaac"; Options = "-m 4"; Description = "fdkaac AAC-LC VBR 4 (自動)" }
            }
            elseif ($extEnc.HasNero) {
                $audioSetting = @{ Type = "nero"; Options = "-q 0.50"; Description = "Nero AAC-LC -q 0.50 (自動)" }
            }
            else {
                $audioSetting = @{ Type = "internal"; Options = "-c:a aac -b:a 128k"; Description = "AAC-LC 128kbps (自動)" }
            }
        }
        else {
            $audioSetting = @{ Type = "internal"; Options = "-c:a libopus -b:a 128k"; Description = "Opus 128kbps (自動)" }
        }
    }

    # --- 解像度 ---
    if ($PlatformConfig.MaxResolution -eq "720p") {
        $scaleFilter = "scale=1280:-2"
    }
    elseif ($PlatformConfig.MaxFileSizeMB -le 50) {
        $scaleFilter = "scale=854:-2" # Discord等: 480pに縮小
    }
    else {
        $scaleFilter = "scale=1280:-2" # catbox等: 720p
    }

    return @{
        Codec = $codec; QualityValue = $qualityValue; Preset = $preset
        AudioSetting = $audioSetting; ScaleFilter = $scaleFilter; Extension = $extension
    }
}
#endregion

#region プラットフォームセットアップUI
function Invoke-PlatformUploadSetup {
    Write-Log "プラットフォーム向けアップロード設定を開始します..."

    # --- 1. プラットフォーム選択 ---
    $platformChoices = @(
        "Twitter        (上限: 512MB, H.264固定, 720p)",
        "Discord        (上限: 10MB, コーデック選択可)",
        "catbox.moe     (上限: 200MB, コーデック選択可)",
        "uguu.se       (上限: 64MB, コーデック選択可)",
        "GitHub         (上限: 100MB, コーデック選択可)",
        "GitHub Release (上限: 2GB, ビットレート上限なし)",
        "カスタム       (上限サイズを自由に指定)"
    )
    $platformIndex = Show-Menu -Title "アップロード先のプラットフォームを選択してください。" -Choices $platformChoices
    if ($platformIndex -lt 0) { return $null }

    $platformConfig = switch ($platformIndex) {
        0 { @{ Name = "Twitter"; MaxFileSizeMB = 512; MaxResolution = "720p"; ForcedCodec = "H.264"; AllowedCodecs = @("H.264"); Extension = "mp4"; NoMaxrate = $false } }
        1 { @{ Name = "Discord"; MaxFileSizeMB = 10; MaxResolution = $null; ForcedCodec = $null; AllowedCodecs = @("H.264", "H.265", "VP9", "AV1"); Extension = $null; NoMaxrate = $false } }
        2 { @{ Name = "catbox.moe"; MaxFileSizeMB = 200; MaxResolution = $null; ForcedCodec = $null; AllowedCodecs = @("H.264", "H.265", "VP9", "AV1"); Extension = $null; NoMaxrate = $false } }
        3 { @{ Name = "uguu.se"; MaxFileSizeMB = 64; MaxResolution = $null; ForcedCodec = $null; AllowedCodecs = @("H.264", "H.265", "VP9", "AV1"); Extension = $null; NoMaxrate = $false } }
        4 { @{ Name = "GitHub"; MaxFileSizeMB = 100; MaxResolution = $null; ForcedCodec = $null; AllowedCodecs = @("H.264", "H.265", "VP9", "AV1"); Extension = $null; NoMaxrate = $false } }
        5 { @{ Name = "GitHub Release"; MaxFileSizeMB = 2048; MaxResolution = $null; ForcedCodec = $null; AllowedCodecs = @("H.264", "H.265", "VP9", "AV1"); Extension = $null; NoMaxrate = $true } }
        6 {
            $customSize = 0
            while ($customSize -le 0) {
                $input = Read-Host "ファイルサイズ上限をMB単位で入力してください (例: 50)"
                if ([double]::TryParse($input, [ref]$customSize) -and $customSize -gt 0) { break }
                Write-Host "  → 0より大きい数値を入力してください。" -ForegroundColor Yellow
                $customSize = 0
            }
            @{ Name = "カスタム (${customSize}MB)"; MaxFileSizeMB = $customSize; MaxResolution = $null; ForcedCodec = $null; AllowedCodecs = @("H.264", "H.265", "VP9", "AV1"); Extension = $null; NoMaxrate = $false }
        }
    }

    # --- 2. 簡単/詳細モード選択 ---
    $setupModeIndex = Show-Menu -Title "$($platformConfig.Name) (上限: $($platformConfig.MaxFileSizeMB) MB)`n`nセットアップ方法を選択してください。" -Choices @(
        "おまかせ (容量に収まるよう自動設定)",
        "カスタマイズ (品質・コーデック等を自分で選択)"
    )
    if ($setupModeIndex -lt 0) { return $null }

    if ($setupModeIndex -eq 0) {
        return Invoke-PlatformAutoSetup -PlatformConfig $platformConfig
    }
    else {
        return Invoke-PlatformDetailedSetup -PlatformConfig $platformConfig
    }
}

function Invoke-PlatformAutoSetup {
    param([hashtable]$PlatformConfig)

    # --- HWエンコーダー選択 (対応HWのみ表示) ---
    $hwFiltered = Get-FilteredHwChoices
    $hwIndex = Show-Menu -Title "使用するハードウェアを選択してください。" -Choices $hwFiltered.Choices
    if ($hwIndex -lt 0) { return $null }
    $selectedHW = $hwFiltered.Keys[$hwIndex]

    # --- コーデック選択 (HWスキャン結果で更にフィルタ) ---
    $selectedCodec = $null
    if ($PlatformConfig.ForcedCodec) {
        $selectedCodec = $PlatformConfig.ForcedCodec
        Write-Host "`n  コーデック: $selectedCodec (プラットフォーム制限により固定)`n"
    }
    else {
        $availableCodecs = Get-PlatformAvailableCodecs -HW $selectedHW -AllowedCodecs $PlatformConfig.AllowedCodecs
        if ($availableCodecs.Count -eq 0) {
            Write-Log "選択したハードウェアで使用可能なコーデックがありません。" -Level "ERROR"
            return $null
        }
        elseif ($availableCodecs.Count -eq 1) {
            $selectedCodec = $availableCodecs[0]
            Write-Host "`n  コーデック: $selectedCodec`n"
        }
        else {
            $codecIndex = Show-Menu -Title "コーデックを選択してください。" -Choices $availableCodecs
            if ($codecIndex -lt 0) { return $null }
            $selectedCodec = $availableCodecs[$codecIndex]
        }
    }

    # --- 自動設定を取得 ---
    $auto = Get-PlatformAutoSettings -PlatformConfig $PlatformConfig -HW $selectedHW -Codec $selectedCodec
    if (-not $auto) {
        Write-Log "設定の生成に失敗しました。" -Level "ERROR"
        return $null
    }

    # NoMaxrateが有効なプラットフォーム (GitHub Release等) はCRFのみでビットレート上限を設定しない
    $qualityMode = if ($PlatformConfig.NoMaxrate) { "CRF" } else { "CRF+Maxrate" }
    $videoOptions = Build-PlatformVideoOptions -HW $selectedHW -Codec $auto.Codec -QualityMode $qualityMode -QualityValue $auto.QualityValue -Preset $auto.Preset -MaxrateKbps 0

    # --- 確認画面 ---
    $qualityDesc = if ($PlatformConfig.NoMaxrate) { "CRF (品質優先・ビットレート上限なし)" } else { "CRF+Maxrate (容量内で最大品質を自動確保)" }
    $sizeDisp = if ($PlatformConfig.MaxFileSizeMB -ge 1024) { "$([math]::Round($PlatformConfig.MaxFileSizeMB / 1024, 1)) GB" } else { "$($PlatformConfig.MaxFileSizeMB) MB" }
    Clear-Host
    Write-Host "============= おまかせ自動設定 ============="
    Write-Host "  プラットフォーム : $($PlatformConfig.Name) (上限: $sizeDisp)"
    Write-Host "  品質方式         : $qualityDesc"
    Write-Host "  ハードウェア     : $selectedHW"
    Write-Host "  コーデック       : $($auto.Codec)"
    Write-Host "  CRFベースライン  : $($auto.QualityValue)"
    Write-Host "  プリセット       : $($auto.Preset) (標準速度)"
    Write-Host "  音声             : $($auto.AudioSetting.Description)"
    Write-Host "  解像度           : $($auto.ScaleFilter)"
    Write-Host "  出力形式         : .$($auto.Extension)"
    if (-not $PlatformConfig.NoMaxrate) { Write-Host "  ※maxrateはファイル長から自動計算されます" }
    Write-Host "============================================"

    $confirm = Show-Menu -Title "この設定でよろしいですか？" -Choices @("はい", "いいえ、やり直します")
    if ($confirm -eq 1) { return Invoke-PlatformUploadSetup }

    $isInterlaced = (Get-Command Test-IsInterlaced -ErrorAction SilentlyContinue) -and (Test-IsInterlaced -Paths $script:Path)
    if ($isInterlaced) {
        $deinterlace = @("None", "fieldmatch,decimate", "fieldmatch,nnedi,decimate", "bwdif", "nnedi", "w3fdif")[(Show-Menu -Title "インターレース解除を行いますか？" -Choices @("行わない", "fieldmatch,decimate (逆テレシネ: 通常のアニメ等に)", "fieldmatch,nnedi,decimate (逆テレシネ: 極高品質 ※重い)", "bwdif (実写/アニメ: 高品質で標準的な解除 ※現在推奨)", "nnedi (極高品質: 学習ウェイトDL必要 ※重い)", "w3fdif (実写等: 高速で標準的なインターレース解除 ※ビデオカメラ等に推奨)"))]
    }
    else {
        $deinterlace = @("None", "fieldmatch,decimate", "fieldmatch,nnedi,decimate", "bwdif", "nnedi", "w3fdif")[(Show-Menu -Title "特定フレームの除去 (プログレッシブと判定済 / 強制インタレ解除も可)" -Choices @("行わない", "fieldmatch,decimate (強制逆テレシネ: 通常)", "fieldmatch,nnedi,decimate (強制逆テレシネ: 極高品質 ※重い)", "bwdif (強制インターレース解除: 高品質)", "nnedi (強制インターレース解除: 極高品質 ※重い)", "w3fdif (強制インターレース解除: 標準・高速)"))]
    }

    $deinterlace = Resolve-DeinterlaceFilter -filter $deinterlace
    $finalVF = $auto.ScaleFilter
    if ($deinterlace -ne "None") {
        if ($finalVF) {
            $finalVF = "$deinterlace,$finalVF"
        }
        else {
            $finalVF = $deinterlace
        }
    }

    return @{
        IsSplitMode        = $false
        PlatformMode       = $true
        TwoPassMode        = $false
        PlatformName       = $PlatformConfig.Name
        MaxFileSizeMB      = $PlatformConfig.MaxFileSizeMB
        QualityMode        = $qualityMode
        QualityValue       = $auto.QualityValue
        HWEncoder          = $selectedHW
        CodecName          = $auto.Codec
        PresetValue        = $auto.Preset
        SpecificEncoder    = ""
        EncoderSettings    = @{
            Video     = $videoOptions
            Audio     = $auto.AudioSetting.Options
            AudioType = $auto.AudioSetting.Type
        }
        OutputMode         = "Subfolder"
        OutputFixedPath    = ""
        AfterProcessAction = "None"
        Extension          = $auto.Extension
        Cut                = "No"
        Metadata           = "None"
        AdditionalVF       = $finalVF
        AdditionalArgs     = ""
    }
}

function Invoke-PlatformDetailedSetup {
    param([hashtable]$PlatformConfig)

    Clear-Host
    Write-Host "  プラットフォーム     : $($PlatformConfig.Name)"
    Write-Host "  ファイルサイズ上限   : $($PlatformConfig.MaxFileSizeMB) MB"
    if ($PlatformConfig.MaxResolution) { Write-Host "  最大解像度           : $($PlatformConfig.MaxResolution)" }
    Write-Host ""

    # NoMaxrateが有効なプラットフォーム (GitHub Release等) はCRFのみでビットレート上限を設定しない
    $qualityMode = if ($PlatformConfig.NoMaxrate) { "CRF" } else { "CRF+Maxrate" }
    $twoPassMode = $false

    # --- 2. ハードウェアエンコーダー選択 (対応HWのみ表示) ---
    $hwFiltered = Get-FilteredHwChoices
    $hwIndex = Show-Menu -Title "使用するハードウェアエンコーダーを選択してください。" -Choices $hwFiltered.Choices
    if ($hwIndex -lt 0) { return $null }
    $selectedHW = $hwFiltered.Keys[$hwIndex]

    # --- 3. コーデック選択 (HWスキャン結果で更にフィルタ) ---
    $selectedCodec = $null
    if ($PlatformConfig.ForcedCodec) {
        $selectedCodec = $PlatformConfig.ForcedCodec
        Write-Host "`n  コーデック: $selectedCodec (プラットフォーム制限により固定)`n"
    }
    else {
        $availableCodecs = Get-PlatformAvailableCodecs -HW $selectedHW -AllowedCodecs $PlatformConfig.AllowedCodecs
        if ($availableCodecs.Count -eq 0) {
            Write-Log "選択したハードウェアで使用可能なコーデックがありません。" -Level "ERROR"
            return $null
        }
        elseif ($availableCodecs.Count -eq 1) {
            $selectedCodec = $availableCodecs[0]
            Write-Host "`n  コーデック: $selectedCodec`n"
        }
        else {
            $codecIndex = Show-Menu -Title "コーデックを選択してください。" -Choices $availableCodecs
            if ($codecIndex -lt 0) { return $null }
            $selectedCodec = $availableCodecs[$codecIndex]
        }
    }

    # --- 3.5 AV1エンコーダー詳細選択 (CPU のみ) ---
    $specificEncoder = ""
    if ($selectedHW -eq "CPU" -and $selectedCodec -eq "AV1") {
        $av1EncoderChoices = @(
            "libsvtav1 (高速 / 推奨)",
            "libaom-av1 (最高品質 / ⚠ 非常に低速)",
            "rav1e (中速 / 実験的)"
        )
        $av1EncIndex = Show-Menu -Title "AV1エンコーダーを選択してください。" -Choices $av1EncoderChoices
        if ($av1EncIndex -lt 0) { return $null }
        $specificEncoder = @("libsvtav1", "libaom-av1", "rav1e")[$av1EncIndex]

        if ($specificEncoder -eq "libaom-av1") {
            Write-Host "`n  ⚠ 警告: libaom-av1は非常に低速です。" -ForegroundColor Yellow
            Write-Host "  エンコード時間がlibsvtav1の10倍以上かかる場合があります。" -ForegroundColor Yellow
            Write-Host "  マルチスレッド設定: -row-mt 1 -tiles 2x2 (自動適用)`n" -ForegroundColor Yellow
            Read-Host "  Enterキーで続行"
        }
        elseif ($specificEncoder -eq "rav1e") {
            Write-Host "`n  ℹ rav1eはlibsvtav1より低速ですが、libaom-av1よりは高速です。" -ForegroundColor Cyan
            Write-Host "  マルチスレッド設定: -tiles 4 (自動適用)" -ForegroundColor Cyan
            Write-Host "  ※ CRF+Maxrateモードでは品質指定なしのビットレートモードで動作します。`n" -ForegroundColor Cyan
            Read-Host "  Enterキーで続行"
        }
    }

    # --- 3.6 品質方式選択 ---
    if (-not $PlatformConfig.NoMaxrate) {
        if ($selectedHW -eq "CPU") {
            $modeChoices = @("CRF+Maxrate (1pass / 品質バランス)", "2pass Bitrate (容量優先)")
            $modeIndex = Show-Menu -Title "品質方式を選択してください。" -Choices $modeChoices -DefaultIndex 0
            if ($modeIndex -lt 0) { return $null }
            if ($modeIndex -eq 1) {
                $qualityMode = "Bitrate"
                $twoPassMode = $true
            }
        }
        else {
            Write-Host "`n  ℹ 2passはCPUエンコーダーのみ対応のため、CRF+Maxrate(1pass)を使用します。`n" -ForegroundColor Cyan
            $qualityMode = "CRF+Maxrate"
            $twoPassMode = $false
        }
    }

    # --- 4. 品質値 (CRF) は容量に収まる範囲で最大品質を自動設定 ---
    # maxrateが容量制限を保証するため、CRFは高品質ベースラインを使用
    $qualityValue = switch ($selectedCodec) {
        "H.264" { 18 }; "H.265" { 22 }; "VP9" { 25 }
        "AV1" { if ($specificEncoder -eq "rav1e") { 100 } else { 23 } }
    }

    # --- 5. プリセット (エンコード速度) 選択 ---
    $presetValue = ""
    switch ($selectedHW) {
        "NVIDIA" {
            $presetChoices = @("P1 (最速)", "P3", "P4 (標準)", "P5", "P7 (最高品質)")
            $presetMap = @("p1", "p3", "p4", "p5", "p7")
            $pIndex = Show-Menu -Title "エンコード速度を選択してください。" -Choices $presetChoices -DefaultIndex 2
            if ($pIndex -lt 0) { return $null }
            $presetValue = $presetMap[$pIndex]
        }
        "Intel" {
            $presetChoices = @("veryfast (最速)", "fast", "medium (標準)", "slow", "veryslow (最高品質)")
            $presetMap = @("veryfast", "fast", "medium", "slow", "veryslow")
            $pIndex = Show-Menu -Title "エンコード速度を選択してください。" -Choices $presetChoices -DefaultIndex 2
            if ($pIndex -lt 0) { return $null }
            $presetValue = $presetMap[$pIndex]
        }
        "AMD" {
            $presetChoices = @("Speed (速度優先)", "Balanced (標準)", "Quality (高品質)")
            $presetMap = @("speed", "balanced", "quality")
            $pIndex = Show-Menu -Title "エンコード速度を選択してください。" -Choices $presetChoices -DefaultIndex 1
            if ($pIndex -lt 0) { return $null }
            $presetValue = $presetMap[$pIndex]
        }
        "CPU" {
            if ($selectedCodec -eq "AV1" -and $specificEncoder -eq "libaom-av1") {
                $presetChoices = @("0 (最高品質 / 極めて遅い)", "1 (高品質 / 非常に遅い)", "2 (高品質寄り / 遅い)", "3 (バランス型)", "4 (標準)", "6 (速い)", "8 (最速 / 品質低下)")
                $presetMap = @("0", "1", "2", "3", "4", "6", "8")
            }
            elseif ($selectedCodec -eq "AV1" -and $specificEncoder -eq "rav1e") {
                $presetChoices = @("0 (最高品質 / 非常に遅い)", "2 (高品質寄り)", "4 (バランス型)", "6 (標準)", "8 (速い)", "10 (最速 / 品質低下)")
                $presetMap = @("0", "2", "4", "6", "8", "10")
            }
            elseif ($selectedCodec -eq "AV1") {
                # libsvtav1
                # SVT-AV1はM10+で警告(自動化用途)が出るため、実用域(0-10)に制限
                $presetChoices = @("0 (最高品質 / 非常に遅い)", "2 (高品質寄り)", "4 (標準)", "6 (速い)", "8 (かなり速い)", "10 (最速寄り)")
                $presetMap = @("0", "2", "4", "6", "8", "10")
            }
            elseif ($selectedCodec -match "VP") {
                $presetChoices = @("0 (最高品質 / 非常に遅い)", "2 (高品質寄り)", "4 (標準)", "6 (速い)", "8 (最速 / 品質低下)")
                $presetMap = @("0", "2", "4", "6", "8")
            }
            else {
                $presetChoices = @("ultrafast (最速)", "fast", "medium (標準)", "slow", "veryslow (最高品質)")
                $presetMap = @("ultrafast", "fast", "medium", "slow", "veryslow")
            }
            $pIndex = Show-Menu -Title "エンコード速度を選択してください。" -Choices $presetChoices -DefaultIndex 2
            if ($pIndex -lt 0) { return $null }
            $presetValue = $presetMap[$pIndex]
        }
    }

    # --- 6. 音声設定 (利用可能な外部エンコーダーのみ表示) ---
    $extEnc = Get-ExternalEncoderAvailability
    $audioSetting = @{ Type = "copy"; Options = "-c:a copy"; Description = "音声コピー (-c:a copy)" }
    if ($PlatformConfig.Name -eq "Twitter") {
        # Twitter: AAC必須 動的メニュー
        $twitterAudioMenu = @()
        if ($extEnc.HasQaac) { $twitterAudioMenu += @{ Key = "qaac"; Label = "qaac (AAC 自動HE/LC)" } }
        if ($extEnc.HasNero) { $twitterAudioMenu += @{ Key = "nero"; Label = "Nero AAC (外部 自動HE/LC)" } }
        if ($extEnc.HasFdkaac) { $twitterAudioMenu += @{ Key = "fdkaac"; Label = "fdkaac (外部 自動HE/LC)" } }
        $twitterAudioMenu += @{ Key = "ffaac"; Label = "ffmpeg内蔵AAC-LC (HE非対応)" }
        $twitterAudioMenu += @{ Key = "copy"; Label = "音声コピー (-c:a copy)" }

        $twitterAudioChoices = @($twitterAudioMenu | ForEach-Object { $_.Label })
        $aIndex = Show-Menu -Title "音声エンコーダーを選択してください。(Twitter = AAC必須)" -Choices $twitterAudioChoices
        if ($aIndex -lt 0) { return $null }
        switch ($twitterAudioMenu[$aIndex].Key) {
            "qaac" { $result = Select-QaacOptions; if (-not $result) { return $null }; $audioSetting = $result }
            "nero" { $result = Select-NeroOptions; if (-not $result) { return $null }; $audioSetting = $result }
            "fdkaac" { $result = Select-FdkaacOptions; if (-not $result) { return $null }; $audioSetting = $result }
            "ffaac" { $audioSetting = @{ Type = "internal"; Options = "-c:a aac -b:a 128k"; Description = "ffmpeg AAC-LC 128kbps (HE非対応)" } }
            "copy" { } # default copy
        }
    }
    else {
        # その他: 動的メニュー
        $generalAudioMenu = @()
        $generalAudioMenu += @{ Key = "copy"; Label = "音声コピー (-c:a copy)" }
        if ($extEnc.HasQaac) { $generalAudioMenu += @{ Key = "qaac"; Label = "qaac (AAC 自動HE/LC)" } }
        if ($extEnc.HasNero) { $generalAudioMenu += @{ Key = "nero"; Label = "Nero AAC (外部 自動HE/LC)" } }
        if ($extEnc.HasFdkaac) { $generalAudioMenu += @{ Key = "fdkaac"; Label = "fdkaac (外部 自動HE/LC)" } }
        $generalAudioMenu += @{ Key = "opus"; Label = "Opus (libopus)" }
        $generalAudioMenu += @{ Key = "ffaac"; Label = "ffmpeg内蔵AAC-LC (HE非対応)" }
        $generalAudioMenu += @{ Key = "none"; Label = "音声なし (-an)" }

        $generalAudioChoices = @($generalAudioMenu | ForEach-Object { $_.Label })
        $aIndex = Show-Menu -Title "音声エンコーダーを選択してください。" -Choices $generalAudioChoices
        if ($aIndex -lt 0) { return $null }
        switch ($generalAudioMenu[$aIndex].Key) {
            "copy" { } # default copy
            "qaac" { $result = Select-QaacOptions; if (-not $result) { return $null }; $audioSetting = $result }
            "nero" { $result = Select-NeroOptions; if (-not $result) { return $null }; $audioSetting = $result }
            "fdkaac" { $result = Select-FdkaacOptions; if (-not $result) { return $null }; $audioSetting = $result }
            "opus" {
                $result = Select-OpusOptions -BitrateChoices @("128 kbps", "96 kbps", "64 kbps", "48 kbps", "32 kbps", "カスタム")
                if (-not $result) { return $null }; $audioSetting = $result
            }
            "ffaac" { $audioSetting = @{ Type = "internal"; Options = "-c:a aac -b:a 128k"; Description = "ffmpeg AAC-LC 128kbps (HE非対応)" } }
            "none" { $audioSetting = @{ Type = "none"; Options = "-an"; Description = "音声なし" } }
        }
    }

    # --- 7. 解像度選択 ---
    $scaleFilter = ""
    if ($PlatformConfig.MaxResolution -eq "720p") {
        $resChoices = @("720p (1280x720) ※プラットフォーム上限", "480p (854x480)", "元の解像度のまま")
        $resIndex = Show-Menu -Title "映像の解像度を選択してください。" -Choices $resChoices
        if ($resIndex -lt 0) { return $null }
        $scaleFilter = switch ($resIndex) { 0 { "scale=1280:-2" } 1 { "scale=854:-2" } 2 { "" } }
    }
    else {
        $resChoices = @("元の解像度のまま", "1080p (1920x1080)", "720p (1280x720)", "480p (854x480)", "360p (640x360)")
        $resIndex = Show-Menu -Title "映像の解像度を選択してください。" -Choices $resChoices
        if ($resIndex -lt 0) { return $null }
        $scaleFilter = switch ($resIndex) { 0 { "" } 1 { "scale=1920:-2" } 2 { "scale=1280:-2" } 3 { "scale=854:-2" } 4 { "scale=640:-2" } }
    }

    # --- 8. 出力コンテナ形式 ---
    $extension = $PlatformConfig.Extension
    if (-not $extension) {
        $containerChoices = switch ($selectedCodec) {
            "H.264" { @("mp4", "mkv") }
            "H.265" { @("mp4", "mkv") }
            "VP9" { @("webm", "mkv") }
            "AV1" { @("mp4", "webm", "mkv") }
        }
        if ($containerChoices.Count -eq 1) {
            $extension = $containerChoices[0]
        }
        else {
            $extIndex = Show-Menu -Title "出力コンテナ形式を選択してください。" -Choices $containerChoices
            if ($extIndex -lt 0) { return $null }
            $extension = $containerChoices[$extIndex]
        }
    }

    # プレビューオプション生成 (maxrateはエンコード時にファイル長から計算)
    $previewVideoOptions = Build-PlatformVideoOptions -HW $selectedHW -Codec $selectedCodec -QualityMode $qualityMode -QualityValue $qualityValue -Preset $presetValue -MaxrateKbps 0 -SpecificEncoder $specificEncoder

    # --- 9. 最終確認 ---
    $qualityDesc = if ($PlatformConfig.NoMaxrate) {
        "CRF (品質優先・ビットレート上限なし)"
    }
    elseif ($twoPassMode) {
        "2pass Bitrate (容量内でサイズ安定を優先)"
    }
    else {
        "CRF+Maxrate (容量内で最大品質を自動確保)"
    }
    $sizeDisp = if ($PlatformConfig.MaxFileSizeMB -ge 1024) { "$([math]::Round($PlatformConfig.MaxFileSizeMB / 1024, 1)) GB" } else { "$($PlatformConfig.MaxFileSizeMB) MB" }
    $encoderDisp = if ($specificEncoder) { "$selectedCodec ($specificEncoder)" } else { $selectedCodec }
    Clear-Host
    Write-Host "============= プラットフォームアップロード設定 ============="
    Write-Host "  プラットフォーム : $($PlatformConfig.Name) (上限: $sizeDisp)"
    Write-Host "  品質方式         : $qualityDesc"
    Write-Host "  ハードウェア     : $selectedHW"
    Write-Host "  コーデック       : $encoderDisp"
    Write-Host "  品質ベースライン  : $qualityValue"
    Write-Host "  プリセット       : $presetValue"
    Write-Host "  音声             : $($audioSetting.Description)"
    Write-Host "  解像度           : $(if ($scaleFilter) { $scaleFilter } else { '元の解像度' })"
    Write-Host "  出力形式         : .$extension"
    if (-not $PlatformConfig.NoMaxrate) { Write-Host "  映像オプション   : (maxrateはファイル長から自動計算)" }
    Write-Host "============================================================"

    $confirm = Show-Menu -Title "この設定でよろしいですか？" -Choices @("はい", "いいえ、やり直します")
    if ($confirm -eq 1) { return Invoke-PlatformUploadSetup }

    $isInterlaced = (Get-Command Test-IsInterlaced -ErrorAction SilentlyContinue) -and (Test-IsInterlaced -Paths $script:Path)
    if ($isInterlaced) {
        $deinterlace = @("None", "fieldmatch,decimate", "fieldmatch,nnedi,decimate", "bwdif", "nnedi", "w3fdif")[(Show-Menu -Title "インターレース解除を行いますか？" -Choices @("行わない", "fieldmatch,decimate (逆テレシネ: 通常のアニメ等に)", "fieldmatch,nnedi,decimate (逆テレシネ: 極高品質 ※重い)", "bwdif (実写/アニメ: 高品質で標準的な解除 ※現在推奨)", "nnedi (極高品質: 学習ウェイトDL必要 ※重い)", "w3fdif (実写等: 高速で標準的なインターレース解除 ※ビデオカメラ等に推奨)"))]
    }
    else {
        $deinterlace = @("None", "fieldmatch,decimate", "fieldmatch,nnedi,decimate", "bwdif", "nnedi", "w3fdif")[(Show-Menu -Title "特定フレームの除去 (プログレッシブと判定済 / 強制インタレ解除も可)" -Choices @("行わない", "fieldmatch,decimate (強制逆テレシネ: 通常)", "fieldmatch,nnedi,decimate (強制逆テレシネ: 極高品質 ※重い)", "bwdif (強制インターレース解除: 高品質)", "nnedi (強制インターレース解除: 極高品質 ※重い)", "w3fdif (強制インターレース解除: 標準・高速)"))]
    }

    $deinterlace = Resolve-DeinterlaceFilter -filter $deinterlace
    $finalVF = $scaleFilter
    if ($deinterlace -ne "None") {
        if ($finalVF) {
            $finalVF = "$deinterlace,$finalVF"
        }
        else {
            $finalVF = $deinterlace
        }
    }

    return @{
        IsSplitMode        = $false
        PlatformMode       = $true
        TwoPassMode        = $twoPassMode
        PlatformName       = $PlatformConfig.Name
        MaxFileSizeMB      = $PlatformConfig.MaxFileSizeMB
        QualityMode        = $qualityMode
        QualityValue       = $qualityValue
        HWEncoder          = $selectedHW
        CodecName          = $selectedCodec
        PresetValue        = $presetValue
        SpecificEncoder    = $specificEncoder
        EncoderSettings    = @{
            Video     = $previewVideoOptions
            Audio     = $audioSetting.Options
            AudioType = $audioSetting.Type
        }
        OutputMode         = "Subfolder"
        OutputFixedPath    = ""
        AfterProcessAction = "None"
        Extension          = $extension
        Cut                = "No"
        Metadata           = "None"
        AdditionalVF       = $finalVF
        AdditionalArgs     = ""
    }
}
#endregion

#endregion

#region メイン処理

#region モード選択・セットアップ
function Start-MainProcess {
    # ログ出力先が変わるため、ここでのTranscriptは廃止し、各処理関数内で開始する
    Write-Log -Message "=============== エンコード処理開始 ===============" -NoTimestamp

    # --- ハードウェア自動スキャン ---
    Write-Log "ハードウェアをスキャン中..."
    $null = Get-AvailableHardware

    # --- ハードウェアデコード選択 (対応HWのみ表示) ---
    $allAccelChoices = @(
        @{ Label = "使用しない (CPUデコード)"; Accel = "" },
        @{ Label = "NVIDIA (cuda)"; Accel = "cuda" },
        @{ Label = "Intel (qsv)"; Accel = "qsv" },
        @{ Label = "推奨・Windows標準 (d3d11va)"; Accel = "d3d11va" },
        @{ Label = "Windows汎用 (dxva2)"; Accel = "dxva2" },
        @{ Label = "Vulkan (vulkan)"; Accel = "vulkan" }
    )
    $hwInfo = $global:HardwareInfo
    $filteredAccel = @()
    foreach ($entry in $allAccelChoices) {
        if ($entry.Accel -eq "") {
            # CPUデコードは常に表示
            $filteredAccel += $entry
        }
        elseif ($hwInfo -and $hwInfo.ScanCompleted) {
            if ($hwInfo.AvailableHwAccels -contains $entry.Accel) {
                $filteredAccel += $entry
            }
        }
        else {
            # スキャン結果なし → 全て表示
            $filteredAccel += $entry
        }
    }
    $hwAccelChoices = @($filteredAccel | ForEach-Object { $_.Label })
    $hwAccelMap = @($filteredAccel | ForEach-Object { $_.Accel })

    $hwAccelIndex = Show-Menu -Title "ハードウェアのスキャンが完了しました。`n使用するハードウェアデコードを選択してください。" -Choices $hwAccelChoices -NoClear
    $hwAccelOption = ""
    if ($hwAccelIndex -gt 0) {
        $selectedHwAccel = $hwAccelMap[$hwAccelIndex]
        $hwAccelOption = "-hwaccel $selectedHwAccel"
        # d3d11va (AMD等) 使用時は出力フォーマットd3d11でGPUメモリ上に保持する
        # ※ソフトウェアフィルターやCPUエンコーダー使用時は hwdownload が自動挿入される
        if ($selectedHwAccel -eq "d3d11va") {
            $hwAccelOption += " -hwaccel_output_format d3d11"
        }
        # NVIDIA cuda 使用時も出力フォーマットcudaでGPUメモリ上に保持する
        if ($selectedHwAccel -eq "cuda") {
            $hwAccelOption += " -hwaccel_output_format cuda"
        }
        # Vulkan 使用時は出力フォーマットvulkanでGPUメモリ上に保持する
        if ($selectedHwAccel -eq "vulkan") {
            $hwAccelOption += " -hwaccel_output_format vulkan"
        }
        # HWデコード使用時はサーフェスプール不足を防ぐため extra_hw_frames を追加
        # デフォルトのプールサイズ(33)では60fps等の高フレームレート映像で不足するため64に拡張
        $hwAccelOption += " -extra_hw_frames 64"
    }

    # --- 実行モード選択 ---
    $modeChoices = @("通常モード (一つずつ対話形式で設定)", "テンプレートから選択", "プラットフォーム向けアップロード (Twitter/Discord/catbox.moe)", "中間ファイル作成モード (高画質・MKV・音声コピー)", "チャプター/字幕分割モード (分割して再エンコード)")
    $selectedMode = Show-Menu -Title "実行モードを選択してください。" -Choices $modeChoices
    
    $config = $null
    switch ($selectedMode) {
        0 { $config = Invoke-InteractiveSetup }
        1 { $config = Invoke-TemplateSelect }
        2 { $config = Invoke-PlatformUploadSetup }
        3 { $config = Invoke-IntermediateMode }
        4 { $config = Invoke-SplitModeSetup }
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
    
    $isInterlaced = (Get-Command Test-IsInterlaced -ErrorAction SilentlyContinue) -and (Test-IsInterlaced -Paths $script:Path)
    if ($isInterlaced) {
        $deinterlace = @("None", "fieldmatch,decimate", "fieldmatch,nnedi,decimate", "bwdif", "nnedi", "w3fdif")[(Show-Menu -Title "インターレース解除を行いますか？" -Choices @("行わない", "fieldmatch,decimate (逆テレシネ: 通常のアニメ等に)", "fieldmatch,nnedi,decimate (逆テレシネ: 極高品質 ※重い)", "bwdif (実写/アニメ: 高品質で標準的な解除 ※現在推奨)", "nnedi (極高品質: 学習ウェイトDL必要 ※重い)", "w3fdif (実写等: 高速で標準的なインターレース解除 ※ビデオカメラ等に推奨)"))]
    }
    else {
        $deinterlace = @("None", "fieldmatch,decimate", "fieldmatch,nnedi,decimate", "bwdif", "nnedi", "w3fdif")[(Show-Menu -Title "特定フレームの除去 (プログレッシブと判定済 / 強制インタレ解除も可)" -Choices @("行わない", "fieldmatch,decimate (強制逆テレシネ: 通常)", "fieldmatch,nnedi,decimate (強制逆テレシネ: 極高品質 ※重い)", "bwdif (強制インターレース解除: 高品質)", "nnedi (強制インターレース解除: 極高品質 ※重い)", "w3fdif (強制インターレース解除: 標準・高速)"))]
    }

    $additionalVF = ""; $additionalArgs = ""
    if ((Show-Menu -Title "追加のビデオフィルター(-vf)やオプションを使いますか？" -Choices @("いいえ", "はい")) -eq 1) {
        $additionalVF = Read-Host "ffmpegの「-vf」として使用するフィルターを入力 (例: scale=1280:-1)"
        $additionalArgs = Read-Host "その他のffmpeg引数を追加 (例: -max_muxing_queue_size 1024)"
    }
    
    $deinterlace = Resolve-DeinterlaceFilter -filter $deinterlace
    if ($deinterlace -ne "None") {
        if ($additionalVF) {
            $additionalVF = "$deinterlace,$additionalVF"
        }
        else {
            $additionalVF = $deinterlace
        }
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
    $templates = Get-ChildItem -LiteralPath $global:Settings.TemplateDir -Filter "*.psd1" | Where-Object { $_.Name -notmatch "^config.*\.psd1$" }
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
#endregion

#region 分割エンコード
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
            $srtContent = Get-Content -LiteralPath $srtFile -Encoding UTF8 -Raw
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
                    $fb = Invoke-AudioEncoderFallback -InputFile $InputFile -ContainerExtension $Config.Extension -Reason "外部エンコーダー '$encPath' が見つかりません。"
                    $audioOptions = $fb.Options
                }
                else {
                    $wavArgsStr = "-hide_banner -loglevel error -y -ss $($seg.Start) -to $($seg.End) -i `"$InputFile`" -vn -map_chapters -1 -map_metadata -1 -f wav `"$tempWavFile`""
                    $result = Invoke-ExternalProcess -FilePath $global:Settings.FfmpegPath -Arguments $wavArgsStr -Label "WAV切り出し中..."
                    
                    if ($result.ExitCode -ne 0) {
                        $fb = Invoke-AudioEncoderFallback -InputFile $InputFile -ContainerExtension $Config.Extension -Reason "WAV変換失敗。"
                        $audioOptions = $fb.Options
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
                            $fb = Invoke-AudioEncoderFallback -InputFile $InputFile -ContainerExtension $Config.Extension -Reason "$($audioEncType)失敗 (終了コード: $($result.ExitCode))。"
                            $audioOptions = $fb.Options
                            $tempAudioOutFile = ""
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

            # --- HWデコード (d3d11/cuda/vulkan) 使用時のフィルター互換性処理 ---
            $needsHwDownload = $HwAccelOption -match '-hwaccel_output_format\s+(d3d11|cuda|vulkan)'
            $isVulkanDecode = $HwAccelOption -match '-hwaccel\s+vulkan'
            $isHwEncoder = $Config.EncoderSettings.Video -match '-c:v\s+\S+_(amf|nvenc|qsv)'
            if ($needsHwDownload -and ($isVulkanDecode -or -not $isHwEncoder)) {
                $ffmpegArgsList += @("-vf", "`"hwdownload,format=nv12`"")
                Write-Log "HWデコード互換: hwdownload,format=nv12 を自動挿入" -Level "DEBUG"
            }

            if ($tempAudioOutFile) {
                $ffmpegArgsList += @("-map", "0:v:0", "-map", "1:a:0", "-c:a", "copy")
            }
            else {
                $ffmpegArgsList += $audioOptions.Split(' ', $splitOptions)
            }

            $ffmpegArgsList += "`"$outputFilePath`""
            $finalArgString = $ffmpegArgsList -join ' '

            $result = Invoke-FfmpegEncode -Arguments $finalArgString -DurationSeconds $segDuration

            # HWアクセル関連エラーの場合、HWアクセルなしでリトライ
            if ($result.ExitCode -ne 0 -and $HwAccelOption -and (Test-HwAccelRelatedFailure $result.StdErr)) {
                Write-Log "HWアクセル関連エラーを検出。HWアクセルなしでリトライします。(セグメント: $outputFileName)" -Level "WARN"
                $HwAccelOption = ""
                $retryArgs = Remove-HwAccelFromArgs $finalArgString
                $result = Invoke-FfmpegEncode -Arguments $retryArgs -DurationSeconds $segDuration
            }

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
        if (Test-Path $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force; Write-Log "一時ファイルをクリーンアップしました。" -Level "DEBUG" }
        Write-Log "全セグメントの処理が完了しました。"
    }
    catch {
        Write-Log "予期せぬエラー: $_" -Level "ERROR"
        Write-Log "スタックトレース: $($_.ScriptStackTrace)" -Level "ERROR"
    }
}
#endregion

#region 通常エンコード
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
        $passLogBase = ""

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

        # --- 外部エンコーダーによる先行音声エンコード ---
        $audioOptions = $Config.EncoderSettings.Audio; $tempAudioOutFile = ""
        $tempWavFile = Join-Path $tempDir "temp_audio.wav"
        $sourceAudioBitrateKbps = 0  # コピー/フォールバック時のソース音声ビットレート
        
        $audioEncType = $Config.EncoderSettings.AudioType
        if ($audioEncType -eq "qaac" -or $audioEncType -eq "nero" -or $audioEncType -eq "fdkaac") {
            $encPath = Get-EncoderPath -Type $audioEncType

            if (-not (Test-CommandExists -Command $encPath)) {
                $fb = Invoke-AudioEncoderFallback -InputFile $InputFile -ContainerExtension $Config.Extension -Reason "外部エンコーダー '$encPath' が見つかりません。"
                $audioOptions = $fb.Options
                $sourceAudioBitrateKbps = $fb.BitrateKbps
            }
            else {
                $wavArgs = "-hide_banner -loglevel error -y $($cutInfo) -i `"$InputFile`" -vn -f wav `"$tempWavFile`""
                $result = Invoke-ExternalProcess -FilePath $global:Settings.FfmpegPath -Arguments $wavArgs -Label "音声ファイルをWAVに変換中..."
                if ($result.ExitCode -ne 0) {
                    $fb = Invoke-AudioEncoderFallback -InputFile $InputFile -ContainerExtension $Config.Extension -Reason "WAV変換失敗。"
                    $audioOptions = $fb.Options
                    $sourceAudioBitrateKbps = $fb.BitrateKbps
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
                    else {
                        $fb = Invoke-AudioEncoderFallback -InputFile $InputFile -ContainerExtension $Config.Extension -Reason "$($audioEncType)失敗 (終了コード: $($result.ExitCode))。"
                        $audioOptions = $fb.Options
                        $sourceAudioBitrateKbps = $fb.BitrateKbps
                        $tempAudioOutFile = ""
                    }
                }
            }
        }

        # --- プラットフォームモード: ビットレート計算とファイルサイズ予測 ---
        # 外部エンコーダーの先行エンコード完了後に実行し、実測ビットレートを使用する
        $currentVideoOptions = $Config.EncoderSettings.Video
        if ($Config.PlatformMode) {
            $sizeDisp = if ($Config.MaxFileSizeMB -ge 1024) { "$([math]::Round($Config.MaxFileSizeMB / 1024, 1)) GB" } else { "$($Config.MaxFileSizeMB) MB" }

            if ($Config.QualityMode -eq "CRF") {
                # CRFのみ (ビットレート上限なし) - 品質優先、サイズはエンコード後に確認
                Write-Log "映像オプション: $currentVideoOptions"
                $durationStr = [TimeSpan]::FromSeconds($inputDuration).ToString("hh\:mm\:ss")
                Write-Log "========= ファイルサイズ情報 =========" -NoTimestamp
                Write-Log "プラットフォーム    : $($Config.PlatformName) (上限: $sizeDisp)"
                Write-Log "入力ファイル長      : $durationStr ($([math]::Round($inputDuration))秒)"
                Write-Log "品質方式            : CRF $($Config.QualityValue) (ビットレート上限なし)"
                Write-Log "※エンコード後にファイルサイズを確認してください"
                Write-Log ""
            }
            else {
                # CRF+Maxrate: ファイル長からmaxrateを自動計算して映像オプションを再生成
                # 外部エンコーダーで先行エンコード済みの場合は完成ファイルから実測
                $actualAudioKbps = 0
                $audioBrSource = ""
                if ($tempAudioOutFile -and (Test-Path $tempAudioOutFile)) {
                    $actualAudioKbps = Get-AudioBitrateFromFile -AudioFilePath $tempAudioOutFile -DurationSeconds $inputDuration
                    $audioBrSource = "実測"
                    Write-Log "音声ファイル実測: $tempAudioOutFile ($([math]::Round((Get-Item $tempAudioOutFile).Length / 1KB)) KB / ${actualAudioKbps} kbps)" -Level "DEBUG"
                }
                elseif ($audioOptions -eq "-c:a copy" -and $sourceAudioBitrateKbps -gt 0) {
                    # コピーモード: ffprobeで取得済みのソース音声ビットレートを使用
                    $actualAudioKbps = $sourceAudioBitrateKbps
                    $audioBrSource = "ソース実測"
                    Write-Log "ソース音声ビットレート: ${actualAudioKbps} kbps (ffprobe)" -Level "DEBUG"
                }
                elseif ($audioOptions -eq "-c:a copy") {
                    # コピーモード (ユーザー指定): ソースファイルからビットレートを取得
                    $srcInfo = Get-SourceAudioInfo -FilePath $InputFile
                    if ($srcInfo.BitrateKbps -gt 0) {
                        $actualAudioKbps = $srcInfo.BitrateKbps
                        $audioBrSource = "ソース実測"
                        Write-Log "ソース音声ビットレート: ${actualAudioKbps} kbps (ffprobe)" -Level "DEBUG"
                    }
                    else {
                        $actualAudioKbps = 128
                        $audioBrSource = "推定"
                    }
                }
                else {
                    $actualAudioKbps = Get-AudioBitrateFromOptions -AudioOptions $audioOptions -AudioType $Config.EncoderSettings.AudioType -SourceBitrateKbps $sourceAudioBitrateKbps
                    $audioBrSource = if ($audioOptions -eq "-an" -or $audioEncType -eq "none") { "音声なし" } elseif ($audioOptions -match '-b:a\s+\d+k') { "設定値" } else { "推定" }
                }
                # コーデック別のマージンファクター (SVT-AV1のcapped CRFはオーバーシュートしやすいため厳しめ)
                $marginFactor = 0.92
                $specificEnc = if ($Config.SpecificEncoder) { $Config.SpecificEncoder } else { "" }
                switch -Regex ($Config.CodecName) {
                    "AV1" { $marginFactor = if ($specificEnc -eq "libsvtav1" -or -not $specificEnc) { 0.82 } else { 0.88 } }
                    "VP9" { $marginFactor = 0.88 }
                    default { $marginFactor = 0.92 }
                }
                $targetBitrateKbps = Get-TargetBitrateKbps -MaxFileSizeMB $Config.MaxFileSizeMB -DurationSeconds $inputDuration -AudioBitrateKbps $actualAudioKbps -MarginFactor $marginFactor
                $currentVideoOptions = Build-PlatformVideoOptions -HW $Config.HWEncoder -Codec $Config.CodecName -QualityMode $Config.QualityMode -QualityValue $Config.QualityValue -Preset $Config.PresetValue -MaxrateKbps $targetBitrateKbps -SpecificEncoder $specificEnc
                Write-Log "映像オプション (自動計算): $currentVideoOptions"

                # ファイルサイズ予測表示
                $audioBrDesc = if ($actualAudioKbps -eq 0) { "音声なし" } else { "音声${actualAudioKbps}kbps (${audioBrSource})" }
                $durationStr = [TimeSpan]::FromSeconds($inputDuration).ToString("hh\:mm\:ss")
                Write-Log "========= ファイルサイズ予測 =========" -NoTimestamp
                Write-Log "プラットフォーム    : $($Config.PlatformName) (上限: $sizeDisp)"
                Write-Log "入力ファイル長      : $durationStr ($([math]::Round($inputDuration))秒)"
                Write-Log "音声ビットレート    : ${actualAudioKbps} kbps (${audioBrSource})"
                Write-Log "映像最大ビットレート: ~$targetBitrateKbps kbps (${audioBrDesc}を差し引き)"
                if ($Config.TwoPassMode) {
                    Write-Log "品質方式            : 2pass Bitrate ${targetBitrateKbps}kbps (マージン: $([math]::Round($marginFactor * 100))%)"
                }
                else {
                    Write-Log "品質方式            : CRF $($Config.QualityValue) + maxrate ${targetBitrateKbps}kbps (マージン: $([math]::Round($marginFactor * 100))%)"
                }
                Write-Log ""
            }
        }

        # --- 2passモード (CPUのみ) ---
        $isDashInput = ([System.IO.Path]::GetExtension($InputFile).ToLowerInvariant() -eq ".mpd")
        if ($Config.PlatformMode -and $Config.TwoPassMode) {
            $passLogBase = Join-Path ([System.IO.Path]::GetTempPath()) ("ff2pass-" + [System.IO.Path]::GetRandomFileName())
            $pass1VideoOptions = "$currentVideoOptions -pass 1 -passlogfile $passLogBase"
            $pass1ArgsList = @("-hide_banner", "-y")
            if ($isDashInput) {
                $pass1ArgsList += @("-fflags", "+genpts")
            }
            if ($HwAccelOption) { $pass1ArgsList += $HwAccelOption.Split(' ', $splitOptions) }
            $pass1ArgsList += $cutInfo.Split(' ', $splitOptions)
            $pass1ArgsList += @("-i", "`"$InputFile`"")
            if ($cutInfo) { $pass1ArgsList += @("-ss", "0") }
            $pass1ArgsList += $pass1VideoOptions.Split(' ', $splitOptions)

            $pass1NeedsHwDownload = $HwAccelOption -match '-hwaccel_output_format\s+(d3d11|cuda|vulkan)'
            $pass1IsVulkanDecode = $HwAccelOption -match '-hwaccel\s+vulkan'
            $pass1IsHwEncoder = $currentVideoOptions -match '-c:v\s+\S+_(amf|nvenc|qsv)'
            $pass1ResolvedVF = $Config.AdditionalVF
            if ($pass1NeedsHwDownload) {
                if ($pass1ResolvedVF) {
                    $pass1ResolvedVF = "hwdownload,format=nv12,$pass1ResolvedVF"
                }
                elseif ($pass1IsVulkanDecode -or -not $pass1IsHwEncoder) {
                    $pass1ResolvedVF = "hwdownload,format=nv12"
                }
            }
            if ($pass1ResolvedVF) { $pass1ArgsList += @("-vf", "`"$pass1ResolvedVF`"") }
            if ($Config.AdditionalArgs) { $pass1ArgsList += $Config.AdditionalArgs.Split(' ', $splitOptions) }
            $pass1ArgsList += @("-an", "-f", "null", "NUL")

            Write-Log "========= 2pass: 1st pass 実行 =========" -NoTimestamp
            $pass1Result = Invoke-FfmpegEncode -Arguments ($pass1ArgsList -join ' ') -DurationSeconds $inputDuration
            if ($pass1Result.ExitCode -ne 0) {
                # HWアクセル関連エラーの場合、HWアクセルなしでリトライ
                if ($HwAccelOption -and (Test-HwAccelRelatedFailure $pass1Result.StdErr)) {
                    Write-Log "HWアクセル関連エラーを検出。HWアクセルなしで1st passをリトライします。" -Level "WARN"
                    $HwAccelOption = ""
                    $retryArgs = Remove-HwAccelFromArgs ($pass1ArgsList -join ' ')
                    Write-Log "========= 2pass: 1st pass リトライ (HWアクセルなし) =========" -NoTimestamp
                    $pass1Result = Invoke-FfmpegEncode -Arguments $retryArgs -DurationSeconds $inputDuration
                }
                if ($pass1Result.ExitCode -ne 0) {
                    Write-Log "2pass 1st pass 失敗 (終了コード: $($pass1Result.ExitCode))" -Level "ERROR"
                    return
                }
            }

            $currentVideoOptions = "$currentVideoOptions -pass 2 -passlogfile $passLogBase"
            Write-Log "2pass: 1st pass 完了。2nd passを開始します。"
        }

        # --- エンコード実行 ---
        $ffmpegArgsList = @("-hide_banner", "-y")
        if ($isDashInput) {
            # DASH入力はタイムスタンプ欠落/逆行が発生しやすいためPTS生成を有効化
            $ffmpegArgsList += @("-fflags", "+genpts")
        }
        if ($HwAccelOption) { $ffmpegArgsList += $HwAccelOption.Split(' ', $splitOptions) }
        $ffmpegArgsList += $cutInfo.Split(' ', $splitOptions)
        $ffmpegArgsList += @("-i", "`"$InputFile`"")

        if ($tempAudioOutFile) { $ffmpegArgsList += @("-i", "`"$tempAudioOutFile`"") }
        if ($useFfmpegMetadata) { $ffmpegArgsList += @("-i", "`"$ffmpegMetadataFile`"") }
        if ($cutInfo) { $ffmpegArgsList += @("-ss", "0") }
        $ffmpegArgsList += $currentVideoOptions.Split(' ', $splitOptions)

        # --- HWデコード (d3d11/cuda/vulkan) 使用時のフィルター互換性処理 ---
        # d3d11/cuda/vulkan出力フォーマット使用時、ソフトウェアフィルターやCPUエンコーダーのために
        # hwdownload,format=nv12 を自動挿入してGPU→CPU転送を行う
        $needsHwDownload = $HwAccelOption -match '-hwaccel_output_format\s+(d3d11|cuda|vulkan)'
        $isVulkanDecode = $HwAccelOption -match '-hwaccel\s+vulkan'
        $isHwEncoder = $currentVideoOptions -match '-c:v\s+\S+_(amf|nvenc|qsv)'
        $resolvedVF = $Config.AdditionalVF

        if ($needsHwDownload) {
            if ($resolvedVF) {
                # ソフトウェアフィルターがある場合: hwdownload を先頭に挿入
                $resolvedVF = "hwdownload,format=nv12,$resolvedVF"
                Write-Log "HWデコード互換: フィルターに hwdownload,format=nv12 を自動挿入" -Level "DEBUG"
            }
            elseif ($isVulkanDecode -or -not $isHwEncoder) {
                # フィルター無し + (Vulkanデコード または CPUエンコーダー) の場合: hwdownload フィルターを追加
                $resolvedVF = "hwdownload,format=nv12"
                Write-Log "HWデコード互換: hwdownload,format=nv12 を自動挿入" -Level "DEBUG"
            }
            # HWエンコーダー + フィルター無しの場合はゼロコピーパスのため何もしない
        }

        if ($resolvedVF) { $ffmpegArgsList += @("-vf", "`"$resolvedVF`"") }
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

        # HWアクセル関連エラーの場合、HWアクセルなしでリトライ
        if ($result.ExitCode -ne 0 -and $HwAccelOption -and (Test-HwAccelRelatedFailure $result.StdErr)) {
            Write-Log "HWアクセル関連エラーを検出。HWアクセルなしでリトライします。" -Level "WARN"
            $HwAccelOption = ""
            $retryArgs = Remove-HwAccelFromArgs $finalArgString
            Write-Log "========= ffmpeg エンコード リトライ (HWアクセルなし) =========" -NoTimestamp
            $result = Invoke-FfmpegEncode -Arguments $retryArgs -DurationSeconds $inputDuration
        }

        if ($result.ExitCode -ne 0) {
            Write-Log "ffmpegエンコード失敗 (終了コード: $($result.ExitCode))" -Level "ERROR"
            if ($global:Settings.NotifyScriptPath) { & $global:Settings.NotifyScriptPath "$baseName EncodeError" }
        }
        else {
            Write-Log "ffmpegエンコードが正常に完了しました。"

            # --- 出力ファイル情報をログに記録 ---
            if (Test-Path $outputFile) {
                $outSize = (Get-Item $outputFile).Length
                $outSizeMB = [math]::Round($outSize / 1MB, 2)
                $inSize = (Get-Item $InputFile).Length
                $ratio = if ($inSize -gt 0) { [math]::Round($outSize / $inSize * 100, 1) } else { 0 }
                Write-Log "========= 出力ファイル情報 =========" -NoTimestamp
                Write-Log "出力パス  : $outputFile"
                Write-Log "出力サイズ: $outSizeMB MB (元ファイルの ${ratio}%)"

                # --- プラットフォームモード: サイズ超過時の警告 ---
                if ($Config.PlatformMode -and $outSizeMB -gt $Config.MaxFileSizeMB) {
                    $sizeDispWarn = if ($Config.MaxFileSizeMB -ge 1024) { "$([math]::Round($Config.MaxFileSizeMB / 1024, 1)) GB" } else { "$($Config.MaxFileSizeMB) MB" }
                    Write-Log "ファイルサイズ上限超過: $outSizeMB MB > $sizeDispWarn" -Level "WARN"
                    if ($Config.QualityMode -eq "CRF") {
                        Write-Log "  CRFモード (ビットレート上限なし) のため、サイズが大きくなりました。CRF値を上げてください。" -Level "WARN"
                    }
                    else {
                        Write-Log "  maxrateで制限していますが、コンテナオーバーヘッド等で超過した可能性があります。" -Level "WARN"
                    }
                }
                elseif ($Config.PlatformMode) {
                    $sizeDispOK = if ($Config.MaxFileSizeMB -ge 1024) { "$([math]::Round($Config.MaxFileSizeMB / 1024, 1)) GB" } else { "$($Config.MaxFileSizeMB) MB" }
                    Write-Log "ファイルサイズ: OK ($outSizeMB MB / 上限 $sizeDispOK)"
                }
            }

            if ($Config.Metadata -eq "ExifTool") {
                $exifArgs = "-api largefilesupport=1 -tagsfromfile `"$InputFile`" -all:all -overwrite_original `"$outputFile`""
                $result = Invoke-ExternalProcess -FilePath $global:Settings.ExifToolPath -Arguments $exifArgs -Label "ExifToolでメタデータをコピーしています..."
                if ($result.ExitCode -ne 0) {
                    Write-Log "ExifToolの実行に失敗しました。メタデータはコピーされていない可能性があります。" -Level "WARN"
                }
                Remove-Item -LiteralPath "$outputFile`_original" -ErrorAction SilentlyContinue
            }
        }

        if ($passLogBase) {
            Remove-Item -Path "$passLogBase*" -Force -ErrorAction SilentlyContinue
            Write-Log "2passログをクリーンアップしました。" -Level "DEBUG"
        }
        if (Test-Path $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force; Write-Log "一時ファイルをクリーンアップしました。" -Level "DEBUG" }
        Write-Log "ファイル「$(Split-Path -Leaf $InputFile)」の処理が完了しました。"
    }
    catch {
        Write-Log "予期せぬエラー: $_" -Level "ERROR"
        Write-Log "スタックトレース: $($_.ScriptStackTrace)" -Level "ERROR"
    }
}
#endregion

#region 後処理アクション
function Invoke-AfterProcessAction {
    param ([string]$Action)
    switch ($Action) {
        "Shutdown" { Write-Host "60秒後にシャットダウン..."; Start-Sleep -Seconds 60; shutdown.exe -s -t 1 }
        "Reboot" { Write-Host "60秒後に再起動..."; Start-Sleep -Seconds 60; shutdown.exe -r -t 1 }
        "Hibernate" { Write-Host "休止モードへ移行..."; rundll32.exe powrprof.dll, SetSuspendState }
    }
}
#endregion

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
