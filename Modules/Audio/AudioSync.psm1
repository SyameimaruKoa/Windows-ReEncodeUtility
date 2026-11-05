# AudioSync.psm1 — Video/audio waveform alignment independent of the encoder.
Set-StrictMode -Version Latest

function Get-AudioSyncAlignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ReferencePath,
        [Parameter(Mandatory = $true)][string]$ExternalPath,
        [string]$FfmpegPath = 'ffmpeg',
        [int]$SampleRate = 100
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
                '-af', 'highpass=f=120,lowpass=f=3200,aresample=8000,aeval=abs(val(0)),lowpass=f=25,aresample=100',
                '-ac', '1', '-f', 'f32le', $files[$i]
            )
            & $FfmpegPath @arguments
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $files[$i])) {
                throw "Could not decode audio waveform: $($sources[$i])"
            }
        }
        $video = [ReEncodeUtility.Audio.FingerprintMatcher]::ReadSamples($files[0])
        $external = [ReEncodeUtility.Audio.FingerprintMatcher]::ReadSamples($files[1])
        return [ReEncodeUtility.Audio.FingerprintMatcher]::Find($video, $external, $SampleRate)
    }
    finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Get-AudioSyncAlignment
