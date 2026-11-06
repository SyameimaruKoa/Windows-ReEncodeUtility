# AudioReconnect.psm1 — waveform-verified discontinuities at video freezes or muted audio.
Set-StrictMode -Version Latest

function Get-ReferenceInterruptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ReferencePath,
        [Parameter(Mandatory = $true)][double]$VideoDuration,
        [string]$FfmpegPath = 'ffmpeg'
    )
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $arguments = @(
            '-hide_banner', '-nostdin', '-nostats', '-loglevel', 'info', '-i', $ReferencePath,
            '-map', '0:v:0', '-map', '0:a:0',
            '-vf', 'fps=4,scale=320:-2:flags=fast_bilinear,freezedetect=n=-60dB:d=1',
            '-af', 'silencedetect=n=-80dB:d=1',
            '-f', 'null', '-'
        )
        $messages = @(& $FfmpegPath @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) { throw '映像停止・無音区間の検出に失敗した。' }
    $active = @{}
    $found = New-Object 'System.Collections.Generic.List[object]'
    $number = '[-+]?(?:\d+(?:\.\d*)?|\.\d+)'
    foreach ($entry in $messages) {
        $line = [string]$entry
        foreach ($kind in @('freeze', 'silence')) {
            if ($line -match ($kind + '_start:\s*(' + $number + ')')) {
                $active[$kind] = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
            }
            if ($line -match ($kind + '_end:\s*(' + $number + ')') -and $active.ContainsKey($kind)) {
                $end = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
                $start = [double]$active[$kind]
                $null = $active.Remove($kind)
                if ($end - $start -ge 1.0 -and $start -ge 0 -and $end -le $VideoDuration + 0.5) {
                    $found.Add([pscustomobject]@{ Start = $start; End = [Math]::Min($end, $VideoDuration); Reason = $kind })
                }
            }
        }
    }
    $sorted = @($found | Sort-Object Start, End)
    $merged = New-Object 'System.Collections.Generic.List[object]'
    foreach ($range in $sorted) {
        if ($merged.Count -gt 0 -and $range.Start -le $merged[$merged.Count - 1].End + 0.3) {
            $current = $merged[$merged.Count - 1]
            $current.End = [Math]::Max($current.End, $range.End)
            $current.Reason += '+' + $range.Reason
        }
        else {
            $merged.Add([pscustomobject]@{
                Start = [double]$range.Start
                End = [double]$range.End
                Reason = [string]$range.Reason
            })
        }
    }
    if ($merged.Count -gt 40) {
        throw "停止・無音区間が多すぎる（$($merged.Count)箇所）。安全な自動再同期はできぬ。"
    }
    return @($merged.ToArray())
}

function Get-AudioReconnectTimeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ReferencePath,
        [Parameter(Mandatory = $true)][string]$ExternalPath,
        [Parameter(Mandatory = $true)][double]$VideoDuration,
        [string]$FfmpegPath = 'ffmpeg',
        [int]$SampleRate = 100
    )
    if ($SampleRate -ne 100) { throw '音声フィンガープリントは100Hzで処理する。' }
    $interruptions = @(Get-ReferenceInterruptions -ReferencePath $ReferencePath -VideoDuration $VideoDuration -FfmpegPath $FfmpegPath)
    if ($interruptions.Count -eq 0) {
        return [pscustomobject]@{ ReconnectCount = 0; Sections = @(); Candidates = 0 }
    }
    if (-not ('ReEncodeUtility.Audio.FingerprintMatcher' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'AudioFingerprint.cs') -ErrorAction Stop
    }
    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('reencode-reconnect-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $temporary -ItemType Directory -ErrorAction Stop | Out-Null
    try {
        $files = @((Join-Path $temporary 'reference.f32'), (Join-Path $temporary 'external.f32'))
        $sources = @($ReferencePath, $ExternalPath)
        for ($i = 0; $i -lt 2; $i++) {
            $arguments = @(
                '-hide_banner', '-nostdin', '-v', 'error', '-y', '-i', $sources[$i],
                '-map', '0:a:0', '-vn',
                '-af', 'highpass=f=120,lowpass=f=3200,aresample=8000,aeval=abs(val(0)),lowpass=f=25,aresample=100',
                '-ac', '1', '-f', 'f32le', $files[$i]
            )
            & $FfmpegPath @arguments
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $files[$i] -PathType Leaf)) {
                throw "音声フィンガープリントを作成できぬ: $($sources[$i])"
            }
        }
        $reference = [ReEncodeUtility.Audio.FingerprintMatcher]::ReadSamples($files[0])
        $external = [ReEncodeUtility.Audio.FingerprintMatcher]::ReadSamples($files[1])
        $referenceDuration = $reference.Length / [double]$SampleRate
        $confirmed = New-Object 'System.Collections.Generic.List[object]'

        foreach ($pause in $interruptions) {
            $beforeStart = [Math]::Max(0.0, $pause.Start - 24.0)
            $beforeEnd = [Math]::Max(0.0, $pause.Start - 0.2)
            $afterStart = [Math]::Min($referenceDuration, $pause.End + 0.2)
            $afterEnd = [Math]::Min($referenceDuration, $pause.End + 24.0)
            if ($beforeEnd - $beforeStart -lt 3.5 -or $afterEnd - $afterStart -lt 3.5) { continue }
            try {
                $before = [ReEncodeUtility.Audio.FingerprintMatcher]::FindRange(
                    $reference, $external, $SampleRate, $beforeStart, $beforeEnd)
                $after = [ReEncodeUtility.Audio.FingerprintMatcher]::FindRange(
                    $reference, $external, $SampleRate, $afterStart, $afterEnd)
            }
            catch {
                Write-Warning ("{0:F2}～{1:F2}秒の停止候補: 前後の波形照合に失敗: {2}" -f $pause.Start, $pause.End, $_)
                continue
            }
            $sourceBefore = ($pause.Start - $before.OffsetSeconds) / $before.TimeScale
            $sourceAfter = ($pause.End - $after.OffsetSeconds) / $after.TimeScale
            $expectedAfter = ($pause.End - $before.OffsetSeconds) / $before.TimeScale
            $jump = $sourceAfter - $expectedAfter
            if ([Math]::Abs($jump) -le 0.35) { continue }
            if ($sourceAfter -lt $sourceBefore - 0.35) {
                Write-Warning ("{0:F2}秒の停止候補は録音時刻が逆行するため採用せぬ。" -f $pause.Start)
                continue
            }
            $confirmed.Add([pscustomobject]@{
                Start = [double]$pause.Start; End = [double]$pause.End
                Reason = [string]$pause.Reason; JumpSeconds = $jump
                BeforeMatch = $before; AfterMatch = $after
            })
        }
        if ($confirmed.Count -eq 0) {
            return [pscustomobject]@{ ReconnectCount = 0; Sections = @(); Candidates = $interruptions.Count }
        }
        if ($confirmed.Count -gt 20) { throw '再接続を20回超検出したため自動合成を中止する。' }

        $sections = New-Object 'System.Collections.Generic.List[object]'
        $start = 0.0
        for ($i = 0; $i -le $confirmed.Count; $i++) {
            $end = if ($i -lt $confirmed.Count) { [double]$confirmed[$i].Start } else { $VideoDuration }
            $fallback = if ($i -eq 0) { $confirmed[0].BeforeMatch } else { $confirmed[$i - 1].AfterMatch }
            if ($end - $start -gt 4.0 -and $start -lt $referenceDuration) {
                try {
                    $match = [ReEncodeUtility.Audio.FingerprintMatcher]::FindRange(
                        $reference, $external, $SampleRate, $start, [Math]::Min($end, $referenceDuration))
                    $referencePoint = if ($i -eq 0) { $end } else { $start }
                    $matchSource = ($referencePoint - $match.OffsetSeconds) / $match.TimeScale
                    $fallbackSource = ($referencePoint - $fallback.OffsetSeconds) / $fallback.TimeScale
                    if ([Math]::Abs($matchSource - $fallbackSource) -gt 0.45) { $match = $fallback }
                }
                catch { $match = $fallback }
            }
            else { $match = $fallback }
            if ([Math]::Abs($match.TimeScale - 1.0) -gt 0.003 -or $match.TimeScale -le 0) {
                throw ("{0:F2}秒の区間で不正な時間倍率を検出した。" -f $start)
            }
            if ($end -gt $start) {
                $sections.Add([pscustomobject]@{
                    VideoStart = $start; VideoEnd = $end; OffsetSeconds = [double]$match.OffsetSeconds
                    TimeScale = [double]$match.TimeScale; IsSilence = $false
                    Confidence = [double]$match.Confidence
                })
            }
            if ($i -lt $confirmed.Count) {
                $cut = $confirmed[$i]
                Write-Host ('音声再同期: 動画 {0:F2}～{1:F2}秒 / 録音ずれ {2:+0.00;-0.00;0.00}秒 / {3}' -f $cut.Start, $cut.End, $cut.JumpSeconds, $cut.Reason)
                $sections.Add([pscustomobject]@{
                    VideoStart = [double]$cut.Start; VideoEnd = [double]$cut.End
                    OffsetSeconds = 0.0; TimeScale = 1.0; IsSilence = $true; Confidence = 1.0
                })
                $start = [double]$cut.End
            }
        }
        return [pscustomobject]@{
            ReconnectCount = $confirmed.Count; Sections = @($sections.ToArray())
            Candidates = $interruptions.Count
        }
    }
    finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Export-ModuleMember -Function Get-ReferenceInterruptions, Get-AudioReconnectTimeline
