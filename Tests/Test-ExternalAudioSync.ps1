<#
.SYNOPSIS
    外部エンコーダー(qaac / nero / fdkaac)でエンコードした音声と動画のリップシンクを検証する。
.DESCRIPTION
    既知の時刻(0.5 / 1.5 / 2.5秒)にビープ音を持つ基準動画を作り、
    アプリと同じ手順で WAV 切り出し -> 外部エンコード -> 映像と mux を行い、
    最終出力のビープ音位置を実測してオフセット(ms)を求める。
    一時ファイルはすべて git 対象外の .cache 配下に作る。
#>
#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$rootDir = Split-Path -Parent $PSScriptRoot
$global:ScriptDir = $rootDir
$global:Settings = Import-PowerShellDataFile -Path (Join-Path $rootDir 'config.user.psd1')
$global:AppCacheDir = Join-Path $rootDir '.cache'
$work = Join-Path $global:AppCacheDir 'test-work\sync'
$null = New-Item -ItemType Directory -Path $work -Force
$ffmpeg = $global:Settings.FfmpegPath
$ffprobe = $global:Settings.FfprobePath

$sampleRate = 48000
$expectedBeeps = @(0.5, 1.5, 2.5)

function Write-BeepWav {
    param([string]$Path)
    $duration = 3.0
    $count = [int]($sampleRate * $duration)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $ascii = [System.Text.Encoding]::ASCII
    $bw.Write($ascii.GetBytes('RIFF'))
    $bw.Write([uint32](36 + $count * 2))
    $bw.Write($ascii.GetBytes('WAVE'))
    $bw.Write($ascii.GetBytes('fmt '))
    $bw.Write([uint32]16)
    $bw.Write([uint16]1)          # PCM
    $bw.Write([uint16]1)          # mono
    $bw.Write([uint32]$sampleRate)
    $bw.Write([uint32]($sampleRate * 2))
    $bw.Write([uint16]2)
    $bw.Write([uint16]16)
    $bw.Write($ascii.GetBytes('data'))
    $bw.Write([uint32]($count * 2))
    for ($i = 0; $i -lt $count; $i++) {
        $t = $i / [double]$sampleRate
        $v = 0.0
        foreach ($b in $expectedBeeps) {
            if ($t -ge $b -and $t -lt ($b + 0.05)) {
                $v = 0.8 * [math]::Sin(2 * [math]::PI * 1000 * ($t - $b))
                break
            }
        }
        $bw.Write([int16]([math]::Round($v * 32767)))
    }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
}

function Get-BeepTimes {
    param([string]$MediaPath)
    $raw = Join-Path $work ("raw-$([guid]::NewGuid().ToString('N')).f32")
    try {
        $null = & $ffmpeg -hide_banner -loglevel error -y -i $MediaPath -vn -ac 1 -ar $sampleRate -f f32le $raw 2>&1
        if (-not (Test-Path -LiteralPath $raw -PathType Leaf)) { return @() }
        $bytes = [System.IO.File]::ReadAllBytes($raw)
        $count = [int]($bytes.Length / 4)
        $threshold = 0.05
        $gapSamples = [int]($sampleRate * 0.05)
        $times = [System.Collections.Generic.List[double]]::new()
        $inBeep = $false; $start = 0; $lastLoud = 0
        for ($i = 0; $i -lt $count; $i++) {
            $v = [System.BitConverter]::ToSingle($bytes, $i * 4)
            if ([math]::Abs($v) -gt $threshold) {
                if (-not $inBeep) { $inBeep = $true; $start = $i }
                $lastLoud = $i
            }
            elseif ($inBeep -and ($i - $lastLoud) -gt $gapSamples) {
                $times.Add($start / [double]$sampleRate)
                $inBeep = $false
            }
        }
        if ($inBeep) { $times.Add($start / [double]$sampleRate) }
        return @($times)
    }
    finally {
        Remove-Item -LiteralPath $raw -Force -ErrorAction SilentlyContinue
    }
}

function Get-StreamInfo {
    param([string]$Path)
    try {
        $json = (& $ffprobe -v error -show_entries stream=codec_name,start_time,duration -show_entries format=duration -of json $Path 2>$null | Out-String)
        return ($json | ConvertFrom-Json)
    }
    catch { return $null }
}

$script:Rows = [System.Collections.Generic.List[object]]::new()
function Add-Row {
    param([string]$Encoder, [string]$Preset, [double[]]$Times, [string]$StreamStart, [string]$Note, [string]$Status = 'TESTED')
    $offsets = @()
    for ($i = 0; $i -lt [math]::Min($Times.Count, $expectedBeeps.Count); $i++) {
        $offsets += [math]::Round(($Times[$i] - $expectedBeeps[$i]) * 1000, 1)
    }
    $avg = if ($offsets.Count) { [math]::Round((($offsets | Measure-Object -Average).Average), 1) } else { 999.0 }
    $script:Rows.Add([pscustomobject]@{
            Encoder = $Encoder; Preset = $Preset; Beeps = $Times.Count
            OffsetsMs = ($offsets -join ', '); AvgOffsetMs = $avg
            StreamStart = $StreamStart; Note = $Note; Status = $Status
        })
    Write-Host ("  {0,-9} {1,-16} beeps={2} offsets=[{3}] ms start={4} {5}" -f $Encoder, $Preset, $Times.Count, ($offsets -join ', '), $StreamStart, $Note)
}

# --- 基準素材 ---
$beepWav = Join-Path $work 'beep.wav'
Write-BeepWav -Path $beepWav
$ref = Join-Path $work 'ref.mkv'
$null = & $ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=black:s=160x90:r=30:d=3' `
    -i $beepWav -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a copy $ref 2>&1
if (-not (Test-Path -LiteralPath $ref -PathType Leaf)) { throw '基準動画の生成に失敗しました。' }

Write-Host '===== 基準 (外部エンコードなし) ====='
$base = Get-BeepTimes -MediaPath $beepWav
Add-Row -Encoder 'baseline' -Preset '原WAV' -Times $base -StreamStart '-' -Note '期待値 0.5/1.5/2.5'
$refAudioWav = Join-Path $work 'ref-extracted.wav'
$null = & $ffmpeg -hide_banner -loglevel error -y -i $ref -vn -map_chapters -1 -map_metadata -1 -f wav $refAudioWav 2>&1
Add-Row -Encoder 'baseline' -Preset 'アプリのWAV抽出' -Times (Get-BeepTimes -MediaPath $refAudioWav) -StreamStart '-' -Note ''

# --- 外部エンコーダーごとの検証 ---
$external = @(
    @{ Type = 'qaac'; Exe = $global:Settings.QaacPath; Cases = @(
            @{ Opts = '--tvbr 91'; Name = 'AAC-LC TVBR91' },
            @{ Opts = '--tvbr 64'; Name = 'AAC-LC TVBR64' },
            @{ Opts = '--he --cvbr 64'; Name = 'HE-AAC CVBR64' }
        ) },
    @{ Type = 'nero'; Exe = $global:Settings.NeroAacEncPath; Cases = @(
            @{ Opts = '-q 0.50'; Name = 'AAC-LC q0.50' },
            @{ Opts = '-he -q 0.35'; Name = 'HE-AAC q0.35' }
        ) },
    @{ Type = 'fdkaac'; Exe = $global:Settings.FdkaacPath; Cases = @(
            @{ Opts = '-m 4'; Name = 'AAC-LC VBR4' },
            @{ Opts = '-p 5 -m 3'; Name = 'HE-AAC VBR3' }
        ) }
)

foreach ($e in $external) {
    $exe = $e.Exe
    if (-not $exe -or -not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        Write-Host "`n=== $($e.Type): 実行ファイルなし ==="
        foreach ($case in $e.Cases) {
            Add-Row -Encoder $e.Type -Preset $case.Name -Times @() -StreamStart '-' -Note '実行ファイルが見つからない' -Status 'SKIP'
        }
        continue
    }
    Write-Host "`n===== $($e.Type) ====="
    foreach ($case in $e.Cases) {
        $tag = "$($e.Type)-$([guid]::NewGuid().ToString('N'))"
        $m4a = Join-Path $work "$tag.m4a"
        $out = Join-Path $work "$tag-out.mkv"

        # アプリと同じ WAV 抽出 (ref から)
        $wav = Join-Path $work "$tag.wav"
        $null = & $ffmpeg -hide_banner -loglevel error -y -i $ref -vn -map_chapters -1 -map_metadata -1 -f wav $wav 2>&1

        $optParts = @($case.Opts -split '\s+')
        if ($e.Type -eq 'qaac') { $argParts = $optParts + @($wav, '-o', $m4a) }
        elseif ($e.Type -eq 'nero') { $argParts = $optParts + @('-if', $wav, '-of', $m4a) }
        else { $argParts = $optParts + @('-o', $m4a, $wav) }

        $null = & $exe @argParts 2>&1
        if (-not (Test-Path -LiteralPath $m4a -PathType Leaf)) {
            Add-Row -Encoder $e.Type -Preset $case.Name -Times @() -StreamStart '-' -Note '外部エンコード失敗'
            continue
        }

        $info = Get-StreamInfo -Path $m4a
        $start = if ($info -and $info.streams) { [string]$info.streams[0].start_time } else { '?' }
        $m4aTimes = Get-BeepTimes -MediaPath $m4a

        # アプリと同じ mux
        $null = & $ffmpeg -hide_banner -loglevel error -y -i $ref -i $m4a `
            -map 0:v:0 -map 1:a:0 -c:a copy $out 2>&1
        $outTimes = @()
        if (Test-Path -LiteralPath $out -PathType Leaf) {
            $outTimes = Get-BeepTimes -MediaPath $out
        }
        $avgM4a = if ($m4aTimes.Count) { [math]::Round((($m4aTimes | ForEach-Object { $_ }) | Measure-Object -Average).Average, 3) } else { 0 }
        Add-Row -Encoder $e.Type -Preset $case.Name -Times $outTimes -StreamStart $start `
            -Note "m4a単体beeps=$($m4aTimes.Count) start=$start"

        Remove-Item -LiteralPath $wav, $m4a, $out -Force -ErrorAction SilentlyContinue
    }
}

# --- ベースライン: FFmpeg 内蔵音声エンコーダー ---
# アプリの内蔵音声パイプラインは映像と音声を1つの ffmpeg コマンドでエンコードするため、
# 同じ形（入力動画 -> -c:v copy -c:a <codec> -> 出力）でリップシンクを測る。
Write-Host "`n===== ffmpeg 内蔵音声エンコーダー (ベースライン) ====="
$internalCases = @(
    @{ Codec = 'aac'; Opts = @('-c:a', 'aac', '-b:a', '128k'); Name = 'AAC-LC 128k' },
    @{ Codec = 'aac_he'; Opts = @('-c:a', 'aac', '-profile:a', 'aac_he', '-b:a', '64k'); Name = 'HE-AAC 64k' },
    @{ Codec = 'opus'; Opts = @('-c:a', 'libopus', '-b:a', '128k'); Name = 'Opus 128k' },
    @{ Codec = 'vorbis'; Opts = @('-c:a', 'libvorbis', '-q:a', '4'); Name = 'Vorbis q4' },
    @{ Codec = 'flac'; Opts = @('-c:a', 'flac'); Name = 'FLAC' },
    @{ Codec = 'ac3'; Opts = @('-c:a', 'ac3', '-b:a', '192k'); Name = 'AC3 192k' },
    @{ Codec = 'mp3'; Opts = @('-c:a', 'libmp3lame', '-b:a', '128k'); Name = 'MP3 128k' }
)
foreach ($c in $internalCases) {
    $out = Join-Path $work "internal-$($c.Codec)-out.mkv"
    $a = @('-hide_banner', '-loglevel', 'error', '-y', '-i', $ref, '-c:v', 'copy') +
        $c.Opts + @($out)
    $null = & $ffmpeg @a 2>&1
    if (-not (Test-Path -LiteralPath $out -PathType Leaf)) {
        Add-Row -Encoder 'ffmpeg' -Preset $c.Name -Times @() -StreamStart '-' -Note 'エンコード失敗'
        continue
    }
    $info = Get-StreamInfo -Path $out
    $streams = @($info.streams | Where-Object { $_.codec_name -ne 'h264' })
    $start = if ($streams.Count) { [string]$streams[0].start_time } else { '?' }
    $actualCodec = if ($streams.Count) { [string]$streams[0].codec_name } else { '?' }
    Add-Row -Encoder 'ffmpeg' -Preset $c.Name -Times (Get-BeepTimes -MediaPath $out) `
        -StreamStart $start -Note "codec=$actualCodec"
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
}

# --- 結果保存 ---
$report = [ordered]@{
    GeneratedAt = (Get-Date).ToString('o')
    ExpectedBeepsSec = $expectedBeeps
    Results = @($script:Rows)
}
$jsonPath = Join-Path $global:AppCacheDir 'external-audio-sync.json'
try { $report | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $jsonPath -Encoding utf8 -Force }
catch { Write-Host "結果保存失敗: $_" -ForegroundColor Red }

Write-Host "`n================ サマリー ================"
$script:Rows | Format-Table -AutoSize | Out-Host

# 対策後の期待値: 自動選択で使うプリセットと内蔵エンコーダーは同期ズレなし (|offset| <= 5ms)
$zeroPresets = @(
    'AAC-LC TVBR91', 'AAC-LC TVBR64', 'AAC-LC q0.50', 'HE-AAC q0.35',
    'AAC-LC VBR4', 'AAC-LC 128k', 'Opus 128k', 'Vorbis q4', 'FLAC', 'AC3 192k', 'MP3 128k'
)
$skipped = @($script:Rows | Where-Object { $_.Status -eq 'SKIP' })
$bad = @($script:Rows | Where-Object {
        $_.Status -ne 'SKIP' -and $_.Preset -in $zeroPresets -and [math]::Abs($_.AvgOffsetMs) -gt 5
    })
if ($bad.Count -gt 0) {
    Write-Host "FAIL: 同期ズレがあるプリセット: $($bad.Preset -join ', ')" -ForegroundColor Red
}
elseif ($skipped.Count -gt 0) {
    Write-Host "SKIP: 外部エンコーダー未検出のため $($skipped.Count) 件を検証できていません: $($skipped.Preset -join ', ')" -ForegroundColor Yellow
}
else {
    Write-Host 'PASS: 自動選択プリセットと内蔵エンコーダーはすべて |offset| <= 5ms' -ForegroundColor Green
}
Write-Host "詳細: $jsonPath"
