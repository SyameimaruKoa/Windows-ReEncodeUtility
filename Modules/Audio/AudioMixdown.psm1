# AudioMixdown.psm1 — independent, lossless channel selection.
Set-StrictMode -Version Latest

function Get-AudioStereoPanFilter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 256)][int]$InputChannels,
        [ValidateRange(1, 256)][int]$LeftChannel = 1,
        [ValidateRange(0, 256)][int]$RightChannel = 0
    )
    if ($RightChannel -eq 0) {
        $RightChannel = if ($InputChannels -eq 4) { 4 } elseif ($InputChannels -eq 1) { 1 } else { 2 }
    }
    if ($LeftChannel -gt $InputChannels -or $RightChannel -gt $InputChannels) {
        throw "Channel selection is outside the input channel count ($InputChannels)."
    }
    return ('pan=stereo|c0=c{0}|c1=c{1}' -f ($LeftChannel - 1), ($RightChannel - 1))
}

function Convert-AudioToStereo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][ValidateRange(1, 256)][int]$InputChannels,
        [int]$LeftChannel = 1,
        [int]$RightChannel = 0,
        [string]$FfmpegPath = 'ffmpeg'
    )
    $pan = Get-AudioStereoPanFilter -InputChannels $InputChannels -LeftChannel $LeftChannel -RightChannel $RightChannel
    & $FfmpegPath -hide_banner -nostdin -v error -y -i $InputPath -map 0:a:0 -af $pan -c:a flac $OutputPath
    if ($LASTEXITCODE -ne 0) { throw "Audio downmix failed: $InputPath" }
    return $OutputPath
}

Export-ModuleMember -Function Get-AudioStereoPanFilter, Convert-AudioToStereo
