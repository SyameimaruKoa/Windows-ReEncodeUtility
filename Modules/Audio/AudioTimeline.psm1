# AudioTimeline.psm1 — piecewise audio remapping and deterministic silence insertion.
Set-StrictMode -Version Latest

function Format-AudioSeconds {
    param([double]$Value)
    return $Value.ToString('0.000000', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Add-AudioSilence {
    param(
        [System.Collections.Generic.List[object]]$Timeline,
        [double]$Duration
    )
    if ($Duration -gt 0.00001) {
        $Timeline.Add([pscustomobject]@{ Type = 'Silence'; Duration = $Duration })
    }
}

function New-AudioSyncTimeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Pieces,
        [Parameter(Mandatory = $true)][double]$VideoDuration,
        [Parameter(Mandatory = $true)][double]$ExternalDuration,
        [switch]$NoDriftCorrection,
        [ValidateRange(0.003, 0.1)][double]$MaxTimeScaleDeviation = 0.003
    )
    if ($VideoDuration -le 0 -or $ExternalDuration -le 0) {
        throw '映像または外部音声の長さが不正じゃ。'
    }
    $timeline = [System.Collections.Generic.List[object]]::new()
    $cursor = 0.0
    $coverage = 0.0
    foreach ($part in @($Pieces | Sort-Object VideoStart)) {
        $begin = [double]$part.VideoStart
        $end = [double]$part.VideoEnd
        $offset = [double]$part.OffsetSeconds
        $scale = [double]$part.TimeScale
        if ($scale -le 0 -or [Math]::Abs($scale - 1.0) -gt $MaxTimeScaleDeviation) {
            throw '音声時間倍率が異常じゃ。'
        }
        if ($NoDriftCorrection) {
            $middle = ($begin + $end) / 2.0
            $externalMiddle = ($middle - $offset) / $scale
            $offset = $middle - $externalMiddle
            $scale = 1.0
        }
        if ($begin -lt $cursor - 0.01 -or $end -gt $VideoDuration + 0.01) {
            throw '音声同期区間の時間が重複しているか、動画の終端を超えておる。'
        }
        Add-AudioSilence -Timeline $timeline -Duration ($begin - $cursor)
        $cursor = [Math]::Max($cursor, $begin)
        if ($end -le $cursor) { continue }
        $externalBegin = [Math]::Max(0.0, ($begin - $offset) / $scale)
        $externalEnd = [Math]::Min($ExternalDuration, ($end - $offset) / $scale)
        if ($externalEnd -gt $externalBegin + 0.00001) {
            $audioBegin = [Math]::Max($begin, $offset + $scale * $externalBegin)
            $audioEnd = [Math]::Min($end, $offset + $scale * $externalEnd)
            if ($audioEnd -gt $audioBegin + 0.00001) {
                Add-AudioSilence -Timeline $timeline -Duration ($audioBegin - $cursor)
                $timeline.Add([pscustomobject]@{
                    Type = 'Audio'
                    Duration = $audioEnd - $audioBegin
                    ExternalStart = $externalBegin
                    ExternalEnd = $externalEnd
                    TimeScale = $scale
                })
                $coverage += $audioEnd - $audioBegin
                $cursor = $audioEnd
            }
        }
        Add-AudioSilence -Timeline $timeline -Duration ($end - $cursor)
        $cursor = [Math]::Max($cursor, $end)
    }
    Add-AudioSilence -Timeline $timeline -Duration ($VideoDuration - $cursor)
    if ($coverage -le 0.1) {
        throw '有効な音声区間が無いため合成を中止するのじゃ。'
    }
    return $timeline.ToArray()
}

function Get-AudioTrackGraph {
    param(
        [string]$InputLabel,
        [string]$PanFilter,
        [object[]]$Timeline,
        [string]$Prefix,
        [string]$OutputLabel,
        [double]$VideoDuration
    )
    $parts = [System.Collections.Generic.List[string]]::new()
    $audioItems = @($Timeline | Where-Object { $_.Type -eq 'Audio' })
    if ($audioItems.Count -lt 1) { throw '音声区間が見つからぬ。' }
    $sourceLabels = @(for ($i = 0; $i -lt $audioItems.Count; $i++) {
        '[{0}src{1}]' -f $Prefix, $i
    }) -join ''
    if ($audioItems.Count -eq 1) {
        $parts.Add($InputLabel + $PanFilter + $sourceLabels)
    } else {
        $parts.Add($InputLabel + $PanFilter + ',asplit=' + $audioItems.Count + $sourceLabels)
    }
    $timelineLabels = [System.Collections.Generic.List[string]]::new()
    $audioIndex = 0
    for ($i = 0; $i -lt $Timeline.Count; $i++) {
        $item = $Timeline[$i]
        $label = '[{0}{1}]' -f $Prefix, $i
        $timelineLabels.Add($label)
        $duration = Format-AudioSeconds -Value $item.Duration
        if ($item.Type -eq 'Silence') {
            $parts.Add('anullsrc=r=48000:cl=stereo,atrim=duration=' + $duration + ',asetpts=PTS-STARTPTS' + $label)
        } else {
            $begin = Format-AudioSeconds -Value $item.ExternalStart
            $end = Format-AudioSeconds -Value $item.ExternalEnd
            $filter = 'atrim=start=' + $begin + ':end=' + $end + ',asetpts=PTS-STARTPTS,aresample=48000'
            if ([Math]::Abs($item.TimeScale - 1.0) -gt 0.0000001) {
                $rate = Format-AudioSeconds -Value (1.0 / $item.TimeScale)
                $filter += ',atempo=' + $rate
            }
            $filter += ',apad,atrim=duration=' + $duration + ',asetpts=PTS-STARTPTS'
            $parts.Add(('[{0}src{1}]' -f $Prefix, $audioIndex) + $filter + $label)
            $audioIndex++
        }
    }
    $length = Format-AudioSeconds -Value $VideoDuration
    if ($Timeline.Count -eq 1) {
        $parts.Add($timelineLabels[0] + 'apad,atrim=duration=' + $length + ',asetpts=PTS-STARTPTS' + $OutputLabel)
    } else {
        $parts.Add(($timelineLabels -join '') + 'concat=n=' + $Timeline.Count + ':v=0:a=1,atrim=duration=' + $length + ',asetpts=PTS-STARTPTS' + $OutputLabel)
    }
    return ($parts -join ';')
}

function Get-AudioSyncGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Timeline,
        [Parameter(Mandatory = $true)][string]$MainPanFilter,
        [string]$AuxiliaryPanFilter = '',
        [Parameter(Mandatory = $true)][double]$VideoDuration
    )
    $graphs = [System.Collections.Generic.List[string]]::new()
    if ($AuxiliaryPanFilter) {
        $graphs.Add('[1:a:0]asplit=2[main_raw][aux_raw]')
        $mainSource = '[main_raw]'
        $auxSource = '[aux_raw]'
    } else {
        $mainSource = '[1:a:0]'
    }
    $graphs.Add((Get-AudioTrackGraph -InputLabel $mainSource -PanFilter $MainPanFilter -Timeline $Timeline -Prefix 'm' -OutputLabel '[synced]' -VideoDuration $VideoDuration))
    if ($AuxiliaryPanFilter) {
        $graphs.Add((Get-AudioTrackGraph -InputLabel $auxSource -PanFilter $AuxiliaryPanFilter -Timeline $Timeline -Prefix 'a' -OutputLabel '[aux_synced]' -VideoDuration $VideoDuration))
    }
    return ($graphs -join ';')
}

Export-ModuleMember -Function New-AudioSyncTimeline, Get-AudioSyncGraph
