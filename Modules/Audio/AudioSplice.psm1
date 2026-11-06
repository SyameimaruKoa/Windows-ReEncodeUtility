# AudioSplice.psm1 — apply independently matched audio sections on the video timeline.
Set-StrictMode -Version Latest

function New-AudioSpliceFilterGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Sections,
        [Parameter(Mandatory = $true)][ValidateRange(0.01, 100000000)][double]$VideoDuration,
        [Parameter(Mandatory = $true)][ValidateRange(0.01, 100000000)][double]$ExternalDuration,
        [Parameter(Mandatory = $true)][string]$MainPan,
        [string]$AuxiliaryPan = '',
        [switch]$NoDriftCorrection
    )
    $pieces = New-Object 'System.Collections.Generic.List[object]'
    $cursor = 0.0
    foreach ($section in @($Sections | Sort-Object VideoStart)) {
        $start = [double]$section.VideoStart
        $end = [double]$section.VideoEnd
        if ($start -lt $cursor - 0.005 -or $end -lt $start) { throw '音声区間が重複・逆行しておる。' }
        if ($start -gt $cursor + 0.00001) {
            $pieces.Add([pscustomobject]@{ Start = $cursor; End = $start; Silence = $true })
        }
        $start = [Math]::Max($start, $cursor)
        if ($end -le $start) { continue }
        if ($section.IsSilence) {
            $pieces.Add([pscustomobject]@{ Start = $start; End = $end; Silence = $true })
        }
        else {
            $scale = if ($NoDriftCorrection) { 1.0 } else { [double]$section.TimeScale }
            if ($scale -le 0 -or [Math]::Abs($scale - 1.0) -gt 0.003) {
                throw '音声区間の時間倍率が範囲外じゃ。'
            }
            $offset = [double]$section.OffsetSeconds
            $availableStart = [Math]::Max($start, $offset)
            $availableEnd = [Math]::Min($end, $offset + $scale * $ExternalDuration)
            if ($availableEnd -le $availableStart) {
                $pieces.Add([pscustomobject]@{ Start = $start; End = $end; Silence = $true })
            }
            else {
                if ($availableStart -gt $start + 0.00001) {
                    $pieces.Add([pscustomobject]@{ Start = $start; End = $availableStart; Silence = $true })
                }
                $pieces.Add([pscustomobject]@{
                    Start = $availableStart
                    End = $availableEnd
                    Silence = $false
                    ExternalStart = ($availableStart - $offset) / $scale
                    ExternalEnd = ($availableEnd - $offset) / $scale
                    TimeScale = $scale
                })
                if ($availableEnd -lt $end - 0.00001) {
                    $pieces.Add([pscustomobject]@{ Start = $availableEnd; End = $end; Silence = $true })
                }
            }
        }
        $cursor = $end
    }
    if ($cursor -lt $VideoDuration - 0.00001) {
        $pieces.Add([pscustomobject]@{ Start = $cursor; End = $VideoDuration; Silence = $true })
    }
    if ($pieces.Count -eq 0 -or $pieces.Count -gt 100) { throw '音声区間数が不正じゃ。' }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $format = { param([double]$value) $value.ToString('0.000000000', $inv) }
    $activeCount = @($pieces | Where-Object { -not $_.Silence }).Count
    $pans = @($MainPan)
    if ($AuxiliaryPan) { $pans += $AuxiliaryPan }
    $graph = New-Object 'System.Collections.Generic.List[string]'
    if ($pans.Count -eq 2 -and $activeCount -gt 0) {
        $graph.Add('[1:a:0]asplit=2[main_raw][aux_raw]')
    }

    for ($track = 0; $track -lt $pans.Count; $track++) {
        $sourceLabels = @()
        for ($i = 0; $i -lt $activeCount; $i++) { $sourceLabels += "[t$($track)src$i]" }
        if ($activeCount -gt 0) {
            $sourceInput = if ($pans.Count -eq 2) {
                if ($track -eq 0) { '[main_raw]' } else { '[aux_raw]' }
            }
            else { '[1:a:0]' }
            if ($activeCount -eq 1) {
                $graph.Add($sourceInput + 'anull' + $sourceLabels[0])
            }
            else {
                $graph.Add($sourceInput + "asplit=$activeCount" + ($sourceLabels -join ''))
            }
        }
        $labels = @()
        $nextActive = 0
        for ($i = 0; $i -lt $pieces.Count; $i++) {
            $piece = $pieces[$i]
            $duration = & $format ($piece.End - $piece.Start)
            $outputLabel = "[t$($track)p$i]"
            $labels += $outputLabel
            if ($piece.Silence) {
                $graph.Add('anullsrc=r=48000:cl=stereo,atrim=duration=' + $duration +
                    ',asetpts=PTS-STARTPTS' + $outputLabel)
            }
            else {
                $sourceStart = & $format ([double]$piece.ExternalStart)
                $sourceEnd = & $format ([double]$piece.ExternalEnd)
                $filters = @(
                    'asetpts=PTS-STARTPTS',
                    "atrim=start=$($sourceStart):end=$sourceEnd",
                    'asetpts=PTS-STARTPTS',
                    $pans[$track],
                    'aresample=48000'
                )
                if ([Math]::Abs($piece.TimeScale - 1.0) -gt 0.0000001) {
                    $tempo = & $format (1.0 / $piece.TimeScale)
                    $filters += "atempo=$tempo"
                }
                $filters += @('apad', "atrim=duration=$duration", 'asetpts=PTS-STARTPTS')
                $graph.Add($sourceLabels[$nextActive] + ($filters -join ',') + $outputLabel)
                $nextActive++
            }
        }
        $target = if ($track -eq 0) { '[synced]' } else { '[aux_synced]' }
        $totalDuration = & $format $VideoDuration
        if ($labels.Count -eq 1) {
            $graph.Add($labels[0] + 'apad,atrim=duration=' + $totalDuration + ',asetpts=PTS-STARTPTS' + $target)
        }
        else {
            $graph.Add(($labels -join '') + "concat=n=$($labels.Count):v=0:a=1,apad,atrim=duration=$totalDuration,asetpts=PTS-STARTPTS" + $target)
        }
    }
    return ($graph -join ';')
}
Export-ModuleMember -Function New-AudioSpliceFilterGraph
