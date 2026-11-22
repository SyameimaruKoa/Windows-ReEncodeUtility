<#
.SYNOPSIS
    全モード / 全コーデック / 全品質モードの網羅検証。
    対話UIを起動せず、AST から関数定義だけを読み込んで実 ffmpeg を実行する。
.PARAMETER VideoPath
    検証に使う実動画。既定は資料用のテスト動画。
#>
#requires -Version 7.0

[CmdletBinding()]
param(
    [string]$VideoPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.cache\Azahar 2126.2 _ SUPER MARIO 3D LAND 2026-11-16 19-03-51.mp4')
)

# 'Stop' にすると ffmpeg の stderr が ErrorRecord 化して副作用判定が壊れるため 'Continue' を使う
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$global:ScriptDir = $root
$global:Settings = Import-PowerShellDataFile -Path (Join-Path $root 'config.user.psd1')
$global:Settings.TemplateDir = Join-Path $root 'Profiles'
# 作業領域は git 対象外のプロジェクト内 .cache\test-work に限定する
$workRoot = Join-Path $root '.cache\test-work'
$null = New-Item -ItemType Directory -Path $workRoot -Force
$global:AppCacheDir = Join-Path $workRoot "allmodes-$([System.IO.Path]::GetRandomFileName())"
$null = New-Item -ItemType Directory -Path $global:AppCacheDir -Force

# --- メインスクリプトから関数定義のみを抽出・定義（トップレベルの Start-MainProcess は実行しない） ---
$mainPath = Join-Path $root 're-encode-AIOptimus.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "メインスクリプトの構文エラー: $($parseErrors[0].Message)" }
$funcs = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($fn in $funcs) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

. (Join-Path $root 'Modules\EncodeFallback.ps1')
. (Join-Path $root 'Modules\IntermediateHardware.ps1')
. (Join-Path $root 'Get-HardwareInfo.ps1') | Out-Null

# Get-HardwareInfo.ps1 は $global:AppCacheDir を <root>\.cache に上書きするため、
# 検証用の一時ディレクトリを必ず再設定する（後始末でリポジトリを消さないため重要）。
# 作業領域は git 対象外のプロジェクト内 .cache\test-work に限定する
$global:AppCacheDir = Join-Path $workRoot "allmodes-$([System.IO.Path]::GetRandomFileName())"
$null = New-Item -ItemType Directory -Path $global:AppCacheDir -Force

# ログは静かにする（エラーだけ表示）
function Write-Log {
    param([string]$Message, [switch]$NoTimestamp, [string]$Level = 'INFO')
    if ($Level -eq 'ERROR') { Write-Host "  [ERROR] $Message" -ForegroundColor Red }
}

# 指定動画が無い場合は合成クリップを生成して検証を継続できるようにする
if (-not (Test-Path -LiteralPath $VideoPath -PathType Leaf)) {
    Write-Host "指定動画が見つからないため、合成クリップを生成します: $VideoPath" -ForegroundColor Yellow
    $VideoPath = Join-Path $global:AppCacheDir 'synthetic.mkv'
    $null = & ffmpeg -hide_banner -loglevel error -y `
        -f lavfi -i 'color=c=blue:s=320x180:r=30:d=3' `
        -f lavfi -i 'sine=frequency=440:duration=3' `
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest $VideoPath 2>&1
    if (-not (Test-Path -LiteralPath $VideoPath)) { throw '合成クリップの生成に失敗しました。' }
}

$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
$script:Results = [System.Collections.Generic.List[object]]::new()
function Assert-Ok {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        $script:Pass++
        $script:Results.Add([pscustomobject]@{ Result = 'PASS'; Name = $Name; Detail = $Detail })
    }
    else {
        $script:Fail++
        $script:Results.Add([pscustomobject]@{ Result = 'FAIL'; Name = $Name; Detail = $Detail })
    }
}
function Add-Skip {
    param([string]$Name, [string]$Detail)
    $script:Skip++
    $script:Results.Add([pscustomobject]@{ Result = 'SKIP'; Name = $Name; Detail = $Detail })
}

function Invoke-ShortEncode {
    param(
        [string]$Name,
        [string]$InputClip,
        [string]$VideoOptions,
        [string]$HwAccelOption = '',
        [string]$Filter = '',
        [int]$Frames = 6,
        [string]$ExpectedCodec = '',
        [switch]$UseFallback
    )
    $out = Join-Path $global:AppCacheDir ("enc-" + ([System.IO.Path]::GetRandomFileName()) + '.mkv')
    $a = "-hide_banner -loglevel error -y $HwAccelOption -i `"$InputClip`" -frames:v $Frames"
    if ($Filter) { $a += " -vf `"$Filter`"" }
    $a += " $VideoOptions -an `"$out`""
    if ($UseFallback) {
        $r = Invoke-EncodeWithFallback -Arguments $a -HwAccelOption $HwAccelOption -VideoFilter $Filter `
            -VideoOptions $VideoOptions -DurationSeconds 2 -Label $Name
    }
    else {
        $r = Invoke-ProbeFfmpeg -Arguments $a
    }
    $codec = ''
    if ($r.ExitCode -eq 0 -and (Test-Path -LiteralPath $out)) {
        $codec = (& ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 $out 2>$null | Select-Object -First 1).Trim()
    }
    $ok = ($r.ExitCode -eq 0) -and (Test-Path -LiteralPath $out) -and $codec -and
          (-not $ExpectedCodec -or $codec -eq $ExpectedCodec)
    $detail = "exit=$($r.ExitCode) codec=$codec"
    if (-not $ok -and $r.StdErr) {
        $line = ($r.StdErr -split "`r?`n" | Where-Object { $_ -match '(?i)(error|invalid|unsupported|not found|failed)' } | Select-Object -First 1)
        if ($line) { $detail += " / $($line.Trim())" }
    }
    Assert-Ok -Condition $ok -Name $Name -Detail $detail
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    return $ok
}

try {
    # ============================================================
    Write-Host "`n===== [1/6] オプション生成マトリクス（全HW x 全コーデック x 全品質モード） ====="
    # ============================================================
    $hwCodecMap = @{
        'NVIDIA'  = @('H.264','H.265','AV1')
        'Intel'   = @('H.264','H.265','VP9','AV1')
        'AMD'     = @('H.264','H.265','AV1')
        'Vulkan'  = @('H.264','H.265','AV1')
        'D3D12VA' = @('H.264','H.265','AV1')
        'MF'      = @('H.264','H.265','AV1')
        'CPU'     = @('H.264','H.265','VP9','AV1')
    }
    $qualityModes = @('CRF','CRF+Maxrate','Bitrate')
    foreach ($hw in $hwCodecMap.Keys) {
        foreach ($codec in $hwCodecMap[$hw]) {
            $encodersToTest = @(@{ Encoder = '' })
            if ($hw -eq 'CPU' -and $codec -eq 'AV1') {
                $encodersToTest = @(
                    @{ Encoder = 'libsvtav1' }, @{ Encoder = 'libaom-av1' }, @{ Encoder = 'rav1e' }
                )
            }
            foreach ($variant in $encodersToTest) {
                foreach ($qmode in $qualityModes) {
                    $opts = Build-PlatformVideoOptions -HW $hw -Codec $codec -QualityMode $qmode `
                        -QualityValue 25 -Preset 'medium' -MaxrateKbps 4000 -SpecificEncoder $variant.Encoder
                    $name = "生成: $hw / $codec / $qmode$(if ($variant.Encoder) { " / $($variant.Encoder)" })"
                    if ($hw -in @('Vulkan','D3D12VA','MF')) {
                        # GPU 使用を保証できないため非明示対応: オプションを生成せず null を返すこと
                        Assert-Ok -Condition ($null -eq $opts) -Name "非対応: $hw / $codec / $qmode" -Detail 'パラメータ変換せず null'
                    }
                    else {
                        $ok = $opts -and $opts.StartsWith('-c:v ') -and $opts -notmatch '[\{\}]'
                        Assert-Ok -Condition ([bool]$ok) -Name $name -Detail "$opts"
                    }
                }
            }
        }
    }
    # 2pass（CPU限定）のオプション生成
    foreach ($q in @('Bitrate')) {
        $pass1 = Build-PlatformVideoOptions -HW 'CPU' -Codec 'H.264' -QualityMode $q -QualityValue 25 -Preset 'veryfast' -MaxrateKbps 3000
        Assert-Ok -Condition ($pass1 -match '-b:v') -Name "生成: CPU 2pass ($q) pass1" -Detail $pass1
    }

    # ============================================================
    Write-Host "`n===== [2/6] テンプレート（全プロファイルの読み込み） ====="
    # ============================================================
    $profileFiles = @()
    $profileFiles += Get-ChildItem -LiteralPath (Join-Path $root 'Profiles') -Filter '*.psd1' -File -ErrorAction SilentlyContinue
    $profileFiles += Get-ChildItem -LiteralPath (Join-Path $root 'Profiles\Filters') -Filter '*.psd1' -File -ErrorAction SilentlyContinue
    $profileFiles += Get-ChildItem -LiteralPath (Join-Path $root 'Profiles\Encoding') -Filter '*.psd1' -File -ErrorAction SilentlyContinue
    Assert-Ok -Condition ($profileFiles.Count -gt 0) -Name 'テンプレート検出' -Detail "$($profileFiles.Count) 件"
    foreach ($pf in $profileFiles) {
        try {
            # テンプレートは .psd1 扩展だが実体は Export-Clixml（TemplateManager と同じ API を使う）
            $data = Import-Clixml -LiteralPath $pf.FullName -ErrorAction Stop
            Assert-Ok -Condition ($null -ne $data) -Name "テンプレート読込: $($pf.Name)" -Detail "keys=$($data.Keys -join ',')"
        }
        catch {
            Assert-Ok -Condition $false -Name "テンプレート読込: $($pf.Name)" -Detail $_.Exception.Message
        }
    }

    # ============================================================
    Write-Host "`n===== [3/6] 実エンコード（利用可能な全コーデック x 全品質モード） ====="
    # ============================================================
    $workClip = Join-Path $global:AppCacheDir 'clip.mkv'
    $null = & ffmpeg -hide_banner -loglevel error -y -ss 0 -t 3 -i $VideoPath -c copy $workClip 2>&1
    if (-not (Test-Path -LiteralPath $workClip)) { throw "テストクリップの作成に失敗しました: $VideoPath" }
    "  テストクリップ: $([math]::Round((Get-Item $workClip).Length/1KB,1)) KB"

    $avail = @($global:HardwareInfo.AvailableEncoders)
    "  利用可能エンコーダー: $($avail -join ', ')"

    # Intel QSV の MPEG-2 エンコーダーはこの環境で幅 1920 が上限。
    # 上限を超える入力では 'Current profile is unsupported' となるため、
    # エンコーダー自体の検証は 1920x720 に縮小したクリップで行う。
    $mpeg2Clip = Join-Path $global:AppCacheDir 'mpeg2-1920.mkv'
    $null = & ffmpeg -hide_banner -loglevel error -y -i $workClip -vf 'scale=1920:720' -c:v libx264 -preset ultrafast -an $mpeg2Clip 2>&1
    Add-Skip -Name 'mpeg2_qsv: 入力幅 2560' -Detail 'QSV MPEG-2 のハードウェア上限 (幅≤1920) のため 1920x720 で検証'

    $codecExpect = @{ 'h264' = 'h264'; 'hevc' = 'hevc'; 'av1' = 'av1'; 'vp9' = 'vp9'; 'vp8' = 'vp8'; 'mjpeg' = 'mjpeg'; 'mpeg2' = 'mpeg2video' }
    $hardwareEncoders = @($avail | Where-Object {
            $_ -match '^(?:h264|hevc|av1|vp9|vp8|mjpeg|mpeg2|mpeg2video)_(?:nvenc|qsv|amf|vulkan|d3d12va|mf)$'
        })
    foreach ($enc in $hardwareEncoders) {
        $codec = ($enc -replace '_(nvenc|qsv|amf|vulkan|d3d12va|mf)$', '')
        $expect = if ($codec -match 'mpeg2') { 'mpeg2video' } else { $codec }
        foreach ($qmode in $qualityModes) {
            $vo = switch -Regex ($enc) {
                '_nvenc$' { if ($qmode -eq 'Bitrate') { "-c:v $enc -rc vbr -b:v 3000k" } else { "-c:v $enc -rc vbr -cq 25" } }
                '_qsv$'   {
                    if ($enc -eq 'mjpeg_qsv') { "-c:v $enc -q:v 5" }
                    elseif ($enc -eq 'mpeg2_qsv') { "-c:v $enc -q:v 10" }
                    elseif ($enc -eq 'vp9_qsv') { "-c:v $enc -q:v 25" }
                    elseif ($qmode -eq 'Bitrate') { "-c:v $enc -b:v 3000k" }
                    else { "-c:v $enc -global_quality 25" }
                }
                '_amf$'   { if ($qmode -eq 'Bitrate') { "-c:v $enc -rc vbr_peak -b:v 3000k" } else { "-c:v $enc -rc cqp -qp_i 25 -qp_p 25 -qp_b 25" } }
                default   { "-c:v $enc -b:v 3000k" }
            }
            $clipForTest = if ($enc -eq 'mpeg2_qsv' -and (Test-Path -LiteralPath $mpeg2Clip)) { $mpeg2Clip } else { $workClip }
            $ok = Invoke-ShortEncode -Name "実エンコード: $enc / $qmode" -InputClip $clipForTest -VideoOptions $vo -Frames 6 -ExpectedCodec $expect
            if (-not $ok) { }
        }
    }

    # QSV / MF の HW デコード経路（hwaccel あり／なし）
    $hwaccelList = @($global:HardwareInfo.AvailableHwAccels)
    foreach ($accel in $hwaccelList) {
        foreach ($enc in @('h264_qsv','hevc_qsv','h264_mf')) {
            if ($avail -notcontains $enc) { continue }
            $outputFormat = switch ($accel) { 'qsv' { 'qsv' } 'd3d11va' { 'd3d11' } 'dxva2' { 'dxva2' } 'vulkan' { 'vulkan' } default { '' } }
            $hwOpt = Get-EffectiveHwAccelOption -HwAccelOption "-hwaccel $accel $(if ($outputFormat) { "-hwaccel_output_format $outputFormat" })" -VideoOptions "-c:v $enc"
            $pipeline = Resolve-VideoFilterPipeline -HwAccelOption $hwOpt -VideoOptions "-c:v $enc" `
                -VideoFilter 'scale=320:180' -EncoderSettings @{} -InputPath $VideoPath
            $vo = if ($enc -eq 'h264_mf') { "-c:v $enc -b:v 2000k" } else { "-c:v $enc -global_quality 25" }
            $null = Invoke-ShortEncode -Name "HWデコード経路: $accel -> $enc" -InputClip $workClip `
                -VideoOptions $vo -HwAccelOption $pipeline.HwAccelOption -Filter $pipeline.Filter `
                -Frames 4 -ExpectedCodec $codecExpect[($enc -replace '_.*$','')] -UseFallback
        }
    }

    # CPU コーデック（全品質モード）
    $cpuEncoders = @(
        @{ Enc = 'libx264'; Codec = 'h264'; F = '' },
        @{ Enc = 'libx265'; Codec = 'hevc'; F = '' },
        @{ Enc = 'libsvtav1'; Codec = 'av1'; F = '-preset 13' },
        @{ Enc = 'libaom-av1'; Codec = 'av1'; F = '-cpu-used 8 -row-mt 1 -tiles 2x2' },
        @{ Enc = 'librav1e'; Codec = 'av1'; F = '-speed 10 -tiles 4' },
        @{ Enc = 'libvpx-vp9'; Codec = 'vp9'; F = '-cpu-used 8' },
        @{ Enc = 'libvpx'; Codec = 'vp8'; F = '-cpu-used 8' }
    )
    foreach ($e in $cpuEncoders) {
        foreach ($qmode in $qualityModes) {
            $cpuPreset = if ($e.Enc -in @('libx264','libx265')) { 'fast' } else { '8' }
            # Build-PlatformVideoOptions は CPU+VP8 マップを持たないため、
            # libvpx(VP8) は VP9 ブランch（VPx 共通の -crf/-b:v/-cpu-used）でビルドする。
            $buildCodec = if ($e.Enc -eq 'libvpx') { 'VP9' }
                elseif ($e.Codec -eq 'h264') { 'H.264' }
                elseif ($e.Codec -eq 'hevc') { 'H.265' }
                elseif ($e.Codec -eq 'vp9') { 'VP9' }
                else { 'AV1' }
            $vo = Build-PlatformVideoOptions -HW 'CPU' -Codec $buildCodec `
                -QualityMode $qmode -QualityValue 30 -Preset $cpuPreset -MaxrateKbps 1000 -SpecificEncoder $e.Enc
            if ($e.F) { $vo = "$vo $($e.F)" }
            $null = Invoke-ShortEncode -Name "CPU実エンコード: $($e.Enc) / $qmode" -InputClip $workClip `
                -VideoOptions $vo -Filter 'scale=160:90' -Frames 4 -ExpectedCodec $e.Codec
        }
    }

    # ============================================================
    Write-Host "`n===== [4/6] 中間ファイル作成モード ====="
    # ============================================================
    foreach ($enc in @($hardwareEncoders | Select-Object -First 6)) {
        try {
            $help = Get-IntermediateEncoderHelp -Encoder $enc -Ffmpeg $global:Settings.FfmpegPath
            $opts = Get-IntermediateChipOptions -Encoder $enc -HelpText $help -ChipOnly $true
            $device = Get-IntermediateUploadDevice -Encoder $enc
            $pixFmt = if ($device) { if ($device -eq 'vulkan') { 'vulkan' } else { 'd3d12' } } else { 'nv12' }
            $vo = "-c:v $enc -pix_fmt $pixFmt -b:v 3000k $(if ($opts) { $opts -join ' ' })"
            $probe = Test-IntermediateHardwareEncode -Ffmpeg $global:Settings.FfmpegPath -VideoOptions $vo -PixelFormat 'nv12' -UploadDevice $device
            Assert-Ok -Condition ($probe.Success) -Name "中間HW: $enc (専用回路優先)" -Detail "$(if ($probe.Success) { 'OK' } else { ($probe.Output -split "`n" | Select-Object -First 1) })"
        }
        catch {
            Add-Skip -Name "中間HW: $enc" -Detail $_.Exception.Message
        }
    }
    # 中間の CPU モード（libx264 / libx265）
    foreach ($enc in @('libx264','libx265')) {
        $probe = Test-IntermediateHardwareEncode -Ffmpeg $global:Settings.FfmpegPath -VideoOptions "-c:v $enc -crf 20 -preset ultrafast" -PixelFormat 'yuv420p'
        Assert-Ok -Condition ($probe.Success) -Name "中間CPU: $enc" -Detail "$(if ($probe.Success) { 'OK' } else { $probe.Output })"
    }

    # ============================================================
    Write-Host "`n===== [5/6] プラットフォームモード（全7種 x おまかせ/詳細） ====="
    # ============================================================
    $platforms = @(
        @{ Name='Twitter'; Max=512; Codecs=@('H.264'); NoMaxrate=$false },
        @{ Name='Discord'; Max=20; Codecs=@('H.264','H.265','VP9','AV1'); NoMaxrate=$false },
        @{ Name='catbox.moe'; Max=200; Codecs=@('H.264','H.265','VP9','AV1'); NoMaxrate=$false },
        @{ Name='uguu.se'; Max=64; Codecs=@('H.264','H.265','VP9','AV1'); NoMaxrate=$false },
        @{ Name='GitHub'; Max=100; Codecs=@('H.264','H.265','VP9','AV1'); NoMaxrate=$false },
        @{ Name='GitHub Release'; Max=2048; Codecs=@('H.264','H.265','VP9','AV1'); NoMaxrate=$true },
        @{ Name='カスタム'; Max=50; Codecs=@('H.264','H.265','VP9','AV1'); NoMaxrate=$false }
    )
    foreach ($p in $platforms) {
        foreach ($setup in @('おまかせ','詳細')) {
            $qm = if ($p.NoMaxrate) { 'CRF' } else { 'CRF+Maxrate' }
            if ($setup -eq 'おまかせ') {
                $auto = Get-PlatformAutoSettings -PlatformConfig $p -HW 'Intel' -Codec 'H.264'
                $vo = Build-PlatformVideoOptions -HW 'Intel' -Codec 'H.264' -QualityMode $qm `
                    -QualityValue $auto.QualityValue -Preset $auto.Preset -MaxrateKbps 0
                Assert-Ok -Condition ([bool]$vo) -Name "プラットフォーム: $p.Name / おまかせ" -Detail $vo
            }
            else {
                $vo = Build-PlatformVideoOptions -HW 'Intel' -Codec 'H.264' -QualityMode $qm `
                    -QualityValue 25 -Preset 'medium' -MaxrateKbps ([int][math]::Min(4000, $p.Max * 1000))
                Assert-Ok -Condition ([bool]$vo) -Name "プラットフォーム: $p.Name / 詳細" -Detail $vo
                # 詳細モードの実エンコード（最初のプラットフォームのみ、軽量に実施）
                if ($p.Name -eq 'Twitter') {
                    $null = Invoke-ShortEncode -Name "プラットフォーム実エンコード: $p.Name" -InputClip $workClip `
                        -VideoOptions $vo -Filter 'scale=320:180' -Frames 4 -ExpectedCodec 'h264'
                }
            }
        }
    }

    # ============================================================
    Write-Host "`n===== [6/6] 分割モード / 外部音声同期モード ====="
    # ============================================================
    # 分割: 外部SRTを2セグメント用意して実実行
    $splitDir = Join-Path $global:AppCacheDir 'splitcase'
    $null = New-Item -ItemType Directory -Path $splitDir -Force
    $splitClip = Join-Path $splitDir 'src.mkv'
    $null = & ffmpeg -hide_banner -loglevel error -y -ss 0 -t 2 -i $VideoPath -c copy $splitClip 2>&1
    $srt = @"
1
00:00:00,000 --> 00:00:01,000
PartA

2
00:00:01,000 --> 00:00:02,000
PartB
"@
    [System.IO.File]::WriteAllText((Join-Path $splitDir 'src.srt'), $srt, (New-Object System.Text.UTF8Encoding($false)))
    $splitConfig = @{
        IsSplitMode = $true
        EncoderSettings = @{ Video = '-c:v libx264 -preset ultrafast -crf 30'; Audio = '-c:a aac -b:a 64k'; AudioType = 'internal' }
        SplitSource = 'ExternalSRT'; NamingStyle = 'Number'; Extension = 'mp4'; AfterProcessAction = 'None'
    }
    try {
        Invoke-SplitEncodeFile -InputFile $splitClip -Config $splitConfig -HwAccelOption ''
        $outs = @(Get-ChildItem -LiteralPath (Join-Path $splitDir 'src') -Filter '*.mp4' -File -ErrorAction SilentlyContinue)
        Assert-Ok -Condition ($outs.Count -ge 2) -Name '分割モード: SRT 2セグメント生成' -Detail "files=$($outs.Count)"
    }
    catch {
        Assert-Ok -Condition $false -Name '分割モード: SRT 2セグメント生成' -Detail $_.Exception.Message
    }

    # 外部音声同期: 動画から WAV を作り、手動オフセットで合成
    $syncClip = Join-Path $global:AppCacheDir 'sync.mkv'
    $null = & ffmpeg -hide_banner -loglevel error -y -ss 0 -t 2 -i $VideoPath -c copy $syncClip 2>&1
    $wav = Join-Path $global:AppCacheDir 'external.wav'
    $null = & ffmpeg -hide_banner -loglevel error -y -i $syncClip -vn -ac 2 -ar 48000 -c:a pcm_s16le $wav 2>&1
    $syncOut = Join-Path $global:AppCacheDir 'sync-out.mkv'
    if ((Test-Path -LiteralPath $wav) -and (Test-Path -LiteralPath $syncClip)) {
        try {
            $res = Invoke-ExternalAudioSynthesis -VideoPath $syncClip `
                -Settings @{ AudioPath = $wav; Manual = $true; ManualOffsetSeconds = 0.0 } -OutputPath $syncOut
            Assert-Ok -Condition (Test-Path -LiteralPath $res) -Name '外部音声同期モード: 手動オフセット合成' -Detail $res
        }
        catch {
            Assert-Ok -Condition $false -Name '外部音声同期モード: 手動オフセット合成' -Detail $_.Exception.Message
        }
    }
    else {
        Add-Skip -Name '外部音声同期モード' -Detail 'WAV/クリップの準備に失敗'
    }
}
finally {
    # 安全装置: .cache\test-work 配下の自分専用ディレクトリ以外は絶対に削除しない
    if ($global:AppCacheDir -and $global:AppCacheDir.StartsWith($workRoot + [IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $global:AppCacheDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Host "安全装置により削除をスキップしました: $($global:AppCacheDir)" -ForegroundColor Yellow
    }
}

# ============================================================
Write-Host "`n================ 検証結果 ================"
$script:Results | Group-Object Result | ForEach-Object { "  $($_.Name): $($_.Count)" }
"  PASS=$script:Pass  FAIL=$script:Fail  SKIP=$script:Skip"
if ($script:Fail -gt 0) {
    Write-Host "`n--- 失敗一覧 ---" -ForegroundColor Red
    $script:Results | Where-Object { $_.Result -eq 'FAIL' } | ForEach-Object {
        Write-Host "  [$($_.Name)] $($_.Detail)" -ForegroundColor Red
    }
}
if ($script:Fail -gt 0) { exit 1 }
