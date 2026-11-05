<#
.SYNOPSIS
    任意の多チャンネル音声から左右2チャンネルを選んでFLACへ変換する。
.DESCRIPTION
    4ch入力ではch1/ch4をメイン、ch2/ch3を補助として2トラックに分離する。
    既定出力はMKA（FLAC×2）。元ファイルは変更しない。
    出力ファイルをFLACに指定した場合は従来どおりメインの2chのみ抽出する。
.PARAMETER Input
    入力の音声ファイル。
.PARAMETER Output
    出力先。4ch入力の既定は _stereo.mka、それ以外は _stereo.flac。
.PARAMETER LeftChannel
    左へ割り当てる入力チャンネル番号（1始まり、既定1）。
.PARAMETER RightChannel
    右へ割り当てる入力チャンネル番号（1始まり、4chでは既定4）。
.PARAMETER ShowHelp
    -h または --help で使い方を表示。
.EXAMPLE
    .\Convert-AudioToStereo.ps1 -Input .\PSCam4Win-mic.wav
#>
[CmdletBinding()]
param(
    [Alias("Input")][string]$InputPath,
    [string]$Output,
    [ValidateRange(1, 256)][int]$LeftChannel = 1,
    [ValidateRange(0, 256)][int]$RightChannel = 0,
    [string]$FfmpegPath = 'ffmpeg',
    [string]$FfprobePath = 'ffprobe',
    [Alias('h', 'help')][switch]$ShowHelp
)

#region Help
if ($ShowHelp -or $args -contains '--help' -or -not $InputPath) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    exit
}
#endregion

#region Convert
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Import-Module (Join-Path $PSScriptRoot '..\..\Modules\Audio\AudioMixdown.psm1') -Force
if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) { throw "入力音声が見つからぬ: $InputPath" }
$InputPath = (Resolve-Path -LiteralPath $InputPath).ProviderPath
$probe = & $FfprobePath -v error -select_streams a:0 -show_entries stream=channels -of 'default=noprint_wrappers=1:nokey=1' $InputPath
if ($LASTEXITCODE -ne 0) { throw '入力チャンネル数を取得できぬ。' }
$channels = [int]($probe | Select-Object -First 1)
if (-not $Output) {
    $ext = if ($channels -eq 4) { '.mka' } else { '.flac' }
    $Output = Join-Path ([System.IO.Path]::GetDirectoryName($InputPath)) ([System.IO.Path]::GetFileNameWithoutExtension($InputPath) + '_stereo' + $ext)
}
if ([System.IO.Path]::GetFullPath($Output) -eq $InputPath) { throw '出力先と入力が同一じゃ。' }
Convert-AudioToStereo -InputPath $InputPath -OutputPath $Output -InputChannels $channels -LeftChannel $LeftChannel -RightChannel $RightChannel -FfmpegPath $FfmpegPath
#endregion
