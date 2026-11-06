# AudioSync.psm1 — Video/audio waveform alignment independent of the encoder.
Set-StrictMode -Version Latest


function Get-AudioReconnectEvents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VideoPath,
        [Parameter(Mandatory = $true)][string]$FfmpegPath,
        [Parameter(Mandatory = $true)][double]$VideoDuration
    )
    $detectors = @(
        @{
            Name = 'freeze'
            Args = @('-map', '0:v:0', '-vf',
                'fps=4,scale=320:-2,freezedetect=n=-45dB:d=1,metadata=mode=print:file=-', '-an')
        },
        @{
            Name = 'silence'
            Args = @('-map', '0:a:0', '-af',
                'aresample=async=1000:first_pts=0,silencedetect=n=-70dB:d=1,ametadata=mode=print:file=-', '-vn')
        }
    )
    $events = [System.Collections.Generic.List[object]]::new()
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($detector in $detectors) {
        $arguments = @('-hide_banner', '-nostdin', '-nostats', '-v', 'error', '-i', $VideoPath)
        $arguments += $detector.Args
        $arguments += @('-f', 'null', '-')
        $output = @(& $FfmpegPath @arguments 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw "Reconnect detection failed ($($detector.Name)) for $VideoPath"
        }
        $start = $null
        $startPattern = if ($detector.Name -eq 'freeze') {
            'lavfi\.freezedetect\.freeze_start=([-+]?\d+(?:\.\d+)?)'
        } else { 'lavfi\.silence_start=([-+]?\d+(?:\.\d+)?)' }
        $endPattern = if ($detector.Name -eq 'freeze') {
            'lavfi\.freezedetect\.freeze_end=([-+]?\d+(?:\.\d+)?)'
        } else { 'lavfi\.silence_end=([-+]?\d+(?:\.\d+)?)' }
        foreach ($line in $output) {
            $text = [string]$line
            if ($text -match $startPattern) {
                $start = [double]::Parse($Matches[1], $inv)
            }
            elseif ($text -match $endPattern -and $null -ne $start) {
                $end = [double]::Parse($Matches[1], $inv)
                if ($end - $start -ge 1.0) {
                    $events.Add([pscustomobject]@{ Start = $start; End = $end; Source = $detector.Name })
                }
                $start = $null
            }
        }
        if ($null -ne $start -and $VideoDuration - $start -ge 1.0) {
            $events.Add([pscustomobject]@{ Start = $start; End = $VideoDuration; Source = $detector.Name })
        }
    }
    return $events.ToArray()
}

function Get-AudioSyncAlignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ReferencePath,
        [Parameter(Mandatory = $true)][string]$ExternalPath,
        [string]$FfmpegPath = 'ffmpeg',
        [int]$SampleRate = 100,
        [Parameter(Mandatory = $true)][double]$VideoDuration,
        [switch]$NoReconnectCorrection
    )
    if ($SampleRate -ne 100) {
        throw 'The current envelope filter requires SampleRate=100.'
    }
    $matcherType = 'ReEncodeUtility.Audio.FingerprintMatcher' -as [type]
    if (-not $matcherType) {
        Add-Type -Path (Join-Path $PSScriptRoot 'AudioFingerprint.cs') -ErrorAction Stop
    }
    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('reencode-audiosync-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $temporary -ItemType Directory -ErrorAction Stop | Out-Null
    try {
        $files = @((Join-Path $temporary 'reference.f32'), (Join-Path $temporary 'external.f32'))
        $sources = @($ReferencePath, $ExternalPath)
        for ($i = 0; $i -lt 2; $i++) {
            $arguments = @(
                '-hide_banner', '-nostdin', '-v', 'error', '-y',
                '-i', $sources[$i], '-map', '0:a:0', '-vn',
                '-af', 'aresample=async=1000:first_pts=0,highpass=f=120,lowpass=f=3200,aresample=8000,aeval=abs(val(0)),lowpass=f=25,aresample=100',
                '-ac', '1', '-f', 'f32le', $files[$i]
            )
            & $FfmpegPath @arguments
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $files[$i])) {
                throw "Could not decode audio waveform: $($sources[$i])"
            }
        }
        $video = [ReEncodeUtility.Audio.FingerprintMatcher]::ReadSamples($files[0])
        $external = [ReEncodeUtility.Audio.FingerprintMatcher]::ReadSamples($files[1])
        if ($NoReconnectCorrection) {
            return [ReEncodeUtility.Audio.FingerprintMatcher]::Find($video, $external, $SampleRate)
        }
        $events = @(Get-AudioReconnectEvents -VideoPath $ReferencePath -FfmpegPath $FfmpegPath -VideoDuration $VideoDuration)
        $starts = [double[]]@($events | ForEach-Object { [double]$_.Start })
        $ends = [double[]]@($events | ForEach-Object { [double]$_.End })
        Write-Host ("再接続候補: {0}区間（映像停止1秒以上／完全無音1秒以上）" -f $events.Count)
        return [ReEncodeUtility.Audio.FingerprintMatcher]::FindSegmented(
            $video, $external, $SampleRate, $starts, $ends, $VideoDuration)
    }
    finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Get-AudioSyncAlignment
