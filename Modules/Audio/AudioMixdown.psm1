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

function Get-AudioAuxiliaryChannelPair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 256)][int]$InputChannels,
        [ValidateRange(1, 256)][int]$LeftChannel = 1,
        [ValidateRange(0, 256)][int]$RightChannel = 0
    )
    if ($InputChannels -ne 4) { return @() }
    $resolvedRight = if ($RightChannel -eq 0) { 4 } else { $RightChannel }
    if ($LeftChannel -eq $resolvedRight) {
        throw '4chの全音声を保存するには、メイン左右に異なるチャンネルを指定する必要がある。'
    }
    return @(1..4 | Where-Object { $_ -ne $LeftChannel -and $_ -ne $resolvedRight })
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
    $auxiliaryChannels = @(Get-AudioAuxiliaryChannelPair -InputChannels $InputChannels -LeftChannel $LeftChannel -RightChannel $RightChannel)
    $extension = [System.IO.Path]::GetExtension($OutputPath).ToLowerInvariant()
    if ($auxiliaryChannels.Count -eq 2 -and $extension -in @('.mka', '.mkv')) {
        $auxiliaryPan = Get-AudioStereoPanFilter -InputChannels $InputChannels -LeftChannel $auxiliaryChannels[0] -RightChannel $auxiliaryChannels[1]
        $graph = '[0:a:0]asplit=2[main_source][aux_source];[main_source]' + $pan + '[main];[aux_source]' + $auxiliaryPan + '[aux]'
        $resolvedRight = if ($RightChannel -eq 0) { 4 } else { $RightChannel }
        & $FfmpegPath -hide_banner -nostdin -v error -y -i $InputPath -filter_complex $graph -map '[main]' -map '[aux]' -c:a flac -metadata:s:a:0 "title=Main stereo (CH$LeftChannel/CH$resolvedRight)" -metadata:s:a:1 "title=Auxiliary stereo (CH$($auxiliaryChannels[0])/CH$($auxiliaryChannels[1]))" -disposition:a:0 default -disposition:a:1 0 $OutputPath
    }
    else {
        & $FfmpegPath -hide_banner -nostdin -v error -y -i $InputPath -map 0:a:0 -af $pan -c:a flac $OutputPath
    }
    if ($LASTEXITCODE -ne 0) { throw "Audio downmix failed: $InputPath" }
    return $OutputPath
}

Export-ModuleMember -Function Get-AudioStereoPanFilter, Get-AudioAuxiliaryChannelPair, Convert-AudioToStereo
