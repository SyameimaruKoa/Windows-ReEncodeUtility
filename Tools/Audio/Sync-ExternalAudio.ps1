<#
.SYNOPSIS
    外部音声を動画の音声波形に同期し、ステレオ音声として合成する。
.DESCRIPTION
    動画と外部音声の録音時間が異なっても、共通の音声波形から開始オフセットを推定する。
    複数箇所が一致すれば録音クロック差も補正する。
    1秒以上の映像停止・完全無音を再接続候補として検出し、
    前後の音声波形が一致する場合だけ同期位置を段階的に補正する。
    動画の長さに合わせ、短い音声は無音で補い、長い音声は切り詰める。
    -ManualOffsetSeconds で手動同期も利用できる。
    映像は再エンコードせずコピーし、音声をOpus（ステレオ各256kbps VBR）でMKVへ書き出す。
    4ch入力ではch1/ch4をメイン、ch2/ch3を補助の2トラックにする。
.PARAMETER Video
    同期先の動画。自動同期には比較用の音声トラックが必要。
.PARAMETER Audio
    別録りの音声ファイル。1〜多チャンネル入力に対応。
.PARAMETER Output
    出力MKVの保存先。省略時は動画と同じフォルダへ _stereo_sync.mkv を付加。
.PARAMETER ManualOffsetSeconds
    動画タイムライン上の外部音声開始時刻（秒）。正なら音声が後から始まる。
    指定した場合は自動波形同期を行わない。負なら外部音声の先頭を切り詰める。
.PARAMETER NoDriftCorrection
    音声の再生速度を補正しない（開始位置のみ合わせる）。
.PARAMETER NoReconnectCorrection
    カメラ再接続の自動検出を無効にし、従来の単一区間同期を使う。
.PARAMETER LeftChannel
    ステレオ左に使用する元音声のチャンネル番号（1始まり、デフォルト1）。
.PARAMETER RightChannel
    ステレオ右に使用する元音声のチャンネル番号（1始まり）。
    省略時は4ch入力なら4、モノラルなら1、その他は2。
.PARAMETER KeepReferenceAudio
    動画側の元の音声トラックはメイン・補助より後ろに残す。
.PARAMETER FfmpegPath
    ffmpeg実行ファイルへのパス。
.PARAMETER FfprobePath
    ffprobe実行ファイルへのパス。
.PARAMETER ShowHelp
    -h または --help で詳しいヘルプを表示する。
.EXAMPLE
    .\Sync-ExternalAudio.ps1 -Video .\video.mkv -Audio .\PSCam4Win-mic.wav
.EXAMPLE
    .\Sync-ExternalAudio.ps1 -Video .\video.mkv -Audio .\microphone.wav -ManualOffsetSeconds -0.32
#>
[CmdletBinding()]
param(
    [string]$Video,
    [string]$Audio,
    [string]$Output,
    [double]$ManualOffsetSeconds = 0,
    [switch]$NoDriftCorrection,
    [switch]$NoReconnectCorrection,
    [ValidateRange(1, 256)][int]$LeftChannel = 1,
    [ValidateRange(0, 256)][int]$RightChannel = 0,
    [switch]$KeepReferenceAudio,
    [string]$FfmpegPath = 'ffmpeg',
    [string]$FfprobePath = 'ffprobe',
    [Alias('h', 'help')][switch]$ShowHelp
)

#region Help
if ($ShowHelp -or $args -contains '--help' -or -not $Video -or -not $Audio) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    exit
}
#endregion

#region Initial checks
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Import-Module (Join-Path $PSScriptRoot '..\..\Modules\Audio\AudioSync.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\Modules\Audio\AudioMixdown.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\Modules\Audio\AudioTimeline.psm1') -Force
if (-not (Test-Path -LiteralPath $Video -PathType Leaf)) { throw "動画が見つからぬ: $Video" }
if (-not (Test-Path -LiteralPath $Audio -PathType Leaf)) { throw "外部音声が見つからぬ: $Audio" }
$Video = (Resolve-Path -LiteralPath $Video).ProviderPath
$Audio = (Resolve-Path -LiteralPath $Audio).ProviderPath
if (-not $Output) {
    $dir = [System.IO.Path]::GetDirectoryName($Video)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Video)
    $Output = Join-Path $dir ($name + '_stereo_sync.mkv')
}
$Output = [System.IO.Path]::GetFullPath($Output)
if ([System.IO.Path]::GetExtension($Output).ToLowerInvariant() -ne '.mkv') {
    throw '出力コンテナはMKVを指定するのじゃ（Opus音声と映像の無劣化コピーを保持するため）。'
}
if ($Output -eq $Video -or $Output -eq $Audio) { throw '出力先と入力元が同一じゃ。' }

function Get-Streams {
    param([string]$File)
    $json = & $FfprobePath -v error -show_entries 'format=duration:stream=codec_type,channels,duration' -of json $File
    if ($LASTEXITCODE -ne 0) { throw "ffprobe解析失敗: $File" }
    return ($json -join [Environment]::NewLine | ConvertFrom-Json)
}

$videoInfo = Get-Streams -File $Video
$audioInfo = Get-Streams -File $Audio
$videoStream = @($videoInfo.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1)
$referenceAudio = @($videoInfo.streams | Where-Object { $_.codec_type -eq 'audio' })
$externalAudio = @($audioInfo.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1)
if ($videoStream.Count -eq 0) { throw '動画ストリームが見つからぬ。' }
if ($externalAudio.Count -eq 0) { throw '外部音声ストリームが見つからぬ。' }
$durationText = if ($videoStream[0].duration -and $videoStream[0].duration -ne 'N/A') {
    $videoStream[0].duration
} else {
    $videoInfo.format.duration
}
$videoDuration = [double]::Parse([string]$durationText, [System.Globalization.CultureInfo]::InvariantCulture)
if ($videoDuration -le 0) { throw '動画の長さを取得できぬ。' }
$inputChannels = [int]$externalAudio[0].channels
$panFilter = Get-AudioStereoPanFilter -InputChannels $inputChannels -LeftChannel $LeftChannel -RightChannel $RightChannel
$auxiliaryChannels = @(Get-AudioAuxiliaryChannelPair -InputChannels $inputChannels -LeftChannel $LeftChannel -RightChannel $RightChannel)
$hasAuxiliaryTrack = ($auxiliaryChannels.Count -eq 2)
if ($hasAuxiliaryTrack) {
    $auxiliaryPanFilter = Get-AudioStereoPanFilter -InputChannels $inputChannels -LeftChannel $auxiliaryChannels[0] -RightChannel $auxiliaryChannels[1]
}
#endregion

#region Alignment
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$externalDuration = [double]::Parse([string]$audioInfo.format.duration, $inv)
if ($externalDuration -le 0) { throw '外部音声の長さが取得できぬ。' }

if ($PSBoundParameters.ContainsKey('ManualOffsetSeconds')) {
    $pieces = @([pscustomobject]@{
        VideoStart = 0.0
        VideoEnd = $videoDuration
        OffsetSeconds = $ManualOffsetSeconds
        TimeScale = 1.0
        Confidence = 1.0
    })
    Write-Host ("手動オフセット: {0:+0.000;-0.000;0.000}秒" -f $ManualOffsetSeconds)
} else {
    if ($referenceAudio.Count -eq 0) {
        throw '映像に同期基準の音声トラックがないため、自動同期できぬ。映像停止だけでは絶対的な音声位置を確定できない。-ManualOffsetSeconds を指定せよ。'
    }
    $match = Get-AudioSyncAlignment -ReferencePath $Video -ExternalPath $Audio -FfmpegPath $FfmpegPath -VideoDuration $videoDuration -NoReconnectCorrection:$NoReconnectCorrection
    if ($null -ne $match.PSObject.Properties['Pieces']) {
        $pieces = @($match.Pieces)
        Write-Host ("再接続候補 {0}箇所 / 補正確定 {1}箇所 / 信頼度 {2:F3}" -f $match.EventCount, $match.CorrectedDiscontinuities, $match.Confidence)
    } else {
        $pieces = @([pscustomobject]@{
            VideoStart = 0.0
            VideoEnd = $videoDuration
            OffsetSeconds = $match.OffsetSeconds
            TimeScale = $match.TimeScale
            Confidence = $match.Confidence
        })
        Write-Host ('波形一致: {0}箇所 / 信頼度 {1:F3}' -f $match.MatchedAnchors, $match.Confidence)
    }
}
if ($pieces.Count -eq 0) { throw '同期可能な音声区間が見つからぬ。' }
$timeline = @(New-AudioSyncTimeline -Pieces $pieces -VideoDuration $videoDuration -ExternalDuration $externalDuration -NoDriftCorrection:$NoDriftCorrection)
foreach ($part in $pieces) {
    Write-Host ('同期区間: 映像 {0:F3}～{1:F3}秒 / 開始オフセット {2:+0.000;-0.000;0.000}秒 / 倍率 {3:F8}' -f $part.VideoStart, $part.VideoEnd, $part.OffsetSeconds, $part.TimeScale)
}
#endregion

#region Composition
$graph = Get-AudioSyncGraph -Timeline $timeline -MainPanFilter $panFilter -AuxiliaryPanFilter $(if ($hasAuxiliaryTrack) { $auxiliaryPanFilter } else { '' }) -VideoDuration $videoDuration
$trackCount = if ($hasAuxiliaryTrack) { 2 } else { 1 }
$arguments = @(
    '-hide_banner', '-nostdin', '-y', '-i', $Video, '-i', $Audio,
    '-filter_complex', $graph,
    '-map', '0:v:0', '-map', '[synced]'
)
if ($hasAuxiliaryTrack) { $arguments += @('-map', '[aux_synced]') }
if ($KeepReferenceAudio -and $referenceAudio.Count -gt 0) {
    $arguments += @('-map', '0:a?')
}
$arguments += @(
    '-map', '0:s?', '-map_metadata', '0', '-map_chapters', '0',
    '-c:v', 'copy', '-c:a:0', 'libopus', '-b:a:0', '256k', '-c:s', 'copy'
)
if ($hasAuxiliaryTrack) {
    $mainRightChannel = if ($RightChannel -eq 0) { 4 } else { $RightChannel }
    $arguments += @(
        '-c:a:1', 'libopus', '-b:a:1', '256k',
        '-metadata:s:a:0', "title=Main stereo (CH$LeftChannel/CH$mainRightChannel)",
        '-metadata:s:a:1', "title=Auxiliary stereo (CH$($auxiliaryChannels[0])/CH$($auxiliaryChannels[1]))",
        '-disposition:a:0', 'default', '-disposition:a:1', '0'
    )
}
if ($KeepReferenceAudio -and $referenceAudio.Count -gt 0) {
    for ($i = $trackCount; $i -lt ($trackCount + $referenceAudio.Count); $i++) {
        $arguments += @("-c:a:$i", 'copy')
    }
}
$arguments += $Output
Write-Host ("再接続の前後を区間別に同期したOpus音声を書き出すのじゃ: {0}" -f $Output)
& $FfmpegPath @arguments
if ($LASTEXITCODE -ne 0) { throw 'FFmpegによる音声同期・合成に失敗した。' }
Write-Host '音声同期・合成完了じゃ。'
#endregion
