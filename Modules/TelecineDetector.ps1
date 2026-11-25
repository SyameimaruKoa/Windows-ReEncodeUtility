<#
.SYNOPSIS
    3:2プルダウン／逆テレシネ判定の共通ロジック。

.DESCRIPTION
    idet を二段階の rep_thres で走査してフィールド単位のハードテレシネを検出し、
    decimate の周期ログからプログレッシブ映像のフレーム重複（24p由来の3:2）を検出する。
    ffprobe の field_order / interlaced_frame / repeat_pict も併せて評価する。
    メディア情報ツールとメイン処理の両方から利用する。
#>

#region 定数

$script:TelecineMinFrames = 50
$script:TelecineChunkFrames = 300
$script:TelecineCycleLength = 5
$script:TelecineRepeatThresholds = @(3.0, 1.5)
$script:TelecineLowRatio = 0.5
$script:TelecineDropIsMinRatio = 0.7
$script:TelecineLowCycleRatio = 0.6

#endregion

#region idet によるフィールド単位の解析

function New-TelecineChunk {
    return [pscustomobject]@{
        Frames = 0
        Top = [System.Collections.Generic.List[int]]::new()
        Bottom = [System.Collections.Generic.List[int]]::new()
        Progressive = 0
        Interlaced = 0
        Unknown = 0
    }
}

function Get-TelecinePhase {
    param([int[]]$Positions)

    if (-not $Positions -or $Positions.Count -eq 0) {
        return [pscustomobject]@{ Phase = -1; Match = 0.0 }
    }
    $histogram = @(0, 0, 0, 0, 0)
    foreach ($position in $Positions) {
        $histogram[$position % $script:TelecineCycleLength]++
    }
    $best = 0
    for ($i = 1; $i -lt $script:TelecineCycleLength; $i++) {
        if ($histogram[$i] -gt $histogram[$best]) {
            $best = $i
        }
    }
    return [pscustomobject]@{
        Phase = $best
        Match = ($histogram[$best] / [double]$Positions.Count)
    }
}

function Complete-TelecineChunk {
    param($Chunk)

    $top = $Chunk.Top.Count
    $bottom = $Chunk.Bottom.Count
    $repeats = $top + $bottom
    $phaseTop = Get-TelecinePhase -Positions $Chunk.Top.ToArray()
    $phaseBottom = Get-TelecinePhase -Positions $Chunk.Bottom.ToArray()
    $consistency = if ($repeats -gt 0) {
        ($top * $phaseTop.Match + $bottom * $phaseBottom.Match) / $repeats
    }
    else {
        0.0
    }
    $gap = ($phaseBottom.Phase - $phaseTop.Phase + $script:TelecineCycleLength) % $script:TelecineCycleLength
    $repeatRatio = if ($Chunk.Frames -gt 0) { $repeats / [double]$Chunk.Frames } else { 0.0 }
    $classified = $Chunk.Progressive + $Chunk.Interlaced
    $progFraction = if ($classified -gt 0) { $Chunk.Progressive / [double]$classified } else { 0.0 }
    return [pscustomobject]@{
        Frames = $Chunk.Frames
        Top = $top
        Bottom = $bottom
        Consistency = $consistency
        Progressive = $Chunk.Progressive
        Interlaced = $Chunk.Interlaced
        Unknown = $Chunk.Unknown
        Classified = $classified
        ProgFraction = $progFraction
        RepeatRatio = $repeatRatio
        Telecine32 = (
            $Chunk.Frames -ge $script:TelecineMinFrames -and
            $top -ge 4 -and
            $bottom -ge 4 -and
            $repeatRatio -ge 0.10 -and
            $repeatRatio -le 0.55 -and
            $consistency -ge 0.85 -and
            $gap -in @(2, 3)
        )
    }
}

function Invoke-TelecineIdetScan {
    param(
        [string]$File,
        [string]$FFmpegExecutable,
        [double]$Start,
        [int]$Frames,
        [bool]$Full,
        [double]$RepeatThreshold = 3.0
    )

    $maxChunk = if ($Full) { $script:TelecineChunkFrames } else { $Frames }
    $state = [pscustomobject]@{
        Chunk = (New-TelecineChunk)
        Reports = [System.Collections.Generic.List[object]]::new()
        FrameCount = [long]0
    }
    $thresholdText = $RepeatThreshold.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
    $arguments = @('-hide_banner', '-loglevel', 'info', '-nostats', '-nostdin')
    if (-not $Full -and $Start -gt 0) {
        $arguments += @('-ss', $Start.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture))
    }
    $arguments += @(
        '-i', $File, '-map', '0:v:0',
        '-vf', "idet=rep_thres=$thresholdText,metadata=mode=print:key=lavfi.idet.repeated.current_frame,metadata=mode=print:key=lavfi.idet.single.current_frame"
    )
    if (-not $Full) {
        $arguments += @('-frames:v', [string]$Frames)
    }
    $arguments += @('-an', '-sn', '-dn', '-f', 'null', '-')

    & $FFmpegExecutable @arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        if ($line -match 'lavfi\.idet\.repeated\.current_frame=(neither|top|bottom)') {
            if ($state.Chunk.Frames -ge $maxChunk) {
                $state.Reports.Add((Complete-TelecineChunk -Chunk $state.Chunk))
                $state.Chunk = New-TelecineChunk
            }
            if ($Matches[1] -eq 'top') {
                $state.Chunk.Top.Add([int]$state.Chunk.Frames)
            }
            elseif ($Matches[1] -eq 'bottom') {
                $state.Chunk.Bottom.Add([int]$state.Chunk.Frames)
            }
            $state.Chunk.Frames++
            $state.FrameCount++
        }
        elseif ($line -match 'lavfi\.idet\.single\.current_frame=(tff|bff|progressive|undetermined)') {
            # single がフレーム単位の分類。multiple は履歴によるフィールド順の推定なので使わない。
            switch ($Matches[1]) {
                'progressive' { $state.Chunk.Progressive++; break }
                'tff' { $state.Chunk.Interlaced++; break }
                'bff' { $state.Chunk.Interlaced++; break }
                default { $state.Chunk.Unknown++; break }
            }
        }
    }
    $scanExitCode = $LASTEXITCODE
    if ($state.Chunk.Frames -gt 0) {
        $state.Reports.Add((Complete-TelecineChunk -Chunk $state.Chunk))
    }
    return [pscustomobject]@{
        Success = ($scanExitCode -eq 0 -and $state.FrameCount -ge $script:TelecineMinFrames)
        ExitCode = $scanExitCode
        FrameCount = $state.FrameCount
        RepeatThreshold = $RepeatThreshold
        Reports = @($state.Reports.ToArray() | Where-Object { $_.Frames -ge $script:TelecineMinFrames })
    }
}

function Test-TelecineIdetReports {
    param([object[]]$Reports)

    foreach ($report in $Reports) {
        if ($report.Telecine32) { return $true }
    }
    return $false
}

#endregion

#region decimate によるプログレッシブ3:2（フレーム重複）の解析

function New-TelecineDecimateChunk {
    return [pscustomobject]@{
        Cycles = [System.Collections.Generic.List[object]]::new()
        Frames = 0
    }
}

function Complete-TelecineDecimateChunk {
    param($Chunk)

    $cycles = @($Chunk.Cycles.ToArray())
    if ($cycles.Count -eq 0) {
        return [pscustomobject]@{
            Frames = $Chunk.Frames
            Cycles = 0
            DropIsMin = 0
            LowRatio = 0
            RatioMedian = 0.0
            Phase = -1
            PhaseMatch = 0.0
            Periodic32 = $false
        }
    }
    $dropIsMin = @($cycles | Where-Object { $_.DropIsMin }).Count
    $lowRatio = @($cycles | Where-Object { $_.Ratio -le $script:TelecineLowRatio }).Count
    $sortedRatios = @($cycles | ForEach-Object { $_.Ratio } | Sort-Object)
    $ratioMedian = $sortedRatios[[int][math]::Floor($sortedRatios.Count / 2)]
    $phase = Get-TelecinePhase -Positions @($cycles | ForEach-Object { $_.DropIndex })
    return [pscustomobject]@{
        Frames = $Chunk.Frames
        Cycles = $cycles.Count
        DropIsMin = $dropIsMin
        LowRatio = $lowRatio
        RatioMedian = $ratioMedian
        Phase = $phase.Phase
        PhaseMatch = $phase.Match
        Periodic32 = (
            $cycles.Count -ge 20 -and
            ($dropIsMin / [double]$cycles.Count) -ge $script:TelecineDropIsMinRatio -and
            ($lowRatio / [double]$cycles.Count) -ge $script:TelecineLowCycleRatio -and
            $ratioMedian -le $script:TelecineLowRatio
        )
    }
}

function Invoke-TelecineDecimateScan {
    param(
        [string]$File,
        [string]$FFmpegExecutable,
        [double]$Start,
        [int]$Frames,
        [bool]$Full
    )

    $maxFrames = if ($Full) { $script:TelecineChunkFrames } else { $Frames }
    $state = [pscustomobject]@{
        Chunk = (New-TelecineDecimateChunk)
        Pending = [System.Collections.Generic.List[object]]::new()
        Reports = [System.Collections.Generic.List[object]]::new()
        FrameCount = [long]0
    }
    $arguments = @('-hide_banner', '-loglevel', 'debug', '-nostats', '-nostdin')
    if (-not $Full -and $Start -gt 0) {
        $arguments += @('-ss', $Start.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture))
    }
    $filter = if ($Full) { 'decimate=cycle=5' } else { "trim=end_frame=$Frames,decimate=cycle=5" }
    $arguments += @('-i', $File, '-map', '0:v:0', '-vf', $filter, '-an', '-sn', '-dn', '-f', 'null', '-')

    & $FFmpegExecutable @arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        if ($line -match 'Parsed_decimate_\d+.*#(?<idx>\d+):\s+totdiff=(?<diff>[0-9a-fA-F]+)\s+maxbdiff=(?<max>[0-9a-fA-F]+)(?<rest>.*)') {
            $state.Pending.Add([pscustomobject]@{
                Diff = [Convert]::ToUInt64($Matches['diff'], 16)
                Drop = ($Matches['rest'] -match '\[DROP\]')
            })
            $state.FrameCount++
            if ($state.Pending.Count -eq $script:TelecineCycleLength) {
                $cycle = @($state.Pending.ToArray())
                $state.Pending.Clear()
                $dropIndex = -1
                for ($i = 0; $i -lt $cycle.Count; $i++) {
                    if ($cycle[$i].Drop) { $dropIndex = $i; break }
                }
                if ($dropIndex -ge 0) {
                    $dropDiff = $cycle[$dropIndex].Diff
                    $others = @()
                    $minimum = $dropDiff
                    for ($i = 0; $i -lt $cycle.Count; $i++) {
                        if ($i -ne $dropIndex) {
                            $others += $cycle[$i].Diff
                            if ($cycle[$i].Diff -lt $minimum) { $minimum = $cycle[$i].Diff }
                        }
                    }
                    $sorted = @($others | Sort-Object)
                    $median = $sorted[[int][math]::Floor($sorted.Count / 2)]
                    $ratio = if ($median -gt 0) { ($dropDiff / [double]$median) } else { 0.0 }
                    [void]$state.Chunk.Cycles.Add([pscustomobject]@{
                        DropIndex = $dropIndex
                        Ratio = $ratio
                        DropIsMin = ($dropDiff -le $minimum)
                    })
                    $state.Chunk.Frames += $script:TelecineCycleLength
                    if ($state.Chunk.Frames -ge $maxFrames) {
                        $state.Reports.Add((Complete-TelecineDecimateChunk -Chunk $state.Chunk))
                        $state.Chunk = New-TelecineDecimateChunk
                    }
                }
            }
        }
    }
    $scanExitCode = $LASTEXITCODE
    if ($state.Chunk.Frames -gt 0) {
        $state.Reports.Add((Complete-TelecineDecimateChunk -Chunk $state.Chunk))
    }
    return [pscustomobject]@{
        Success = ($scanExitCode -eq 0 -and $state.FrameCount -ge $script:TelecineMinFrames)
        ExitCode = $scanExitCode
        FrameCount = $state.FrameCount
        Reports = @($state.Reports.ToArray() | Where-Object { $_.Cycles -ge 10 })
    }
}

#endregion

#region メタデータの取得

function Read-TelecineStreamFlags {
    param(
        [string]$File,
        [string]$FFprobeExecutable,
        [int]$Frames = 60
    )

    $result = [pscustomobject]@{
        Available = $false
        FieldOrder = ''
        InterlacedFrames = 0
        ProgressiveFrames = 0
        RepeatFrames = 0
        RepeatPhase = -1
        RepeatMatch = 0.0
    }
    if (-not $FFprobeExecutable) { return $result }
    $json = & $FFprobeExecutable -v error -select_streams v:0 -show_entries 'stream=field_order:frame=repeat_pict,interlaced_frame' -read_intervals "%+#$Frames" -of json -i $File 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $result }
    try {
        $data = ($json -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch { return $result }
    if ($data.streams.Count -eq 0) { return $result }
    $result.FieldOrder = [string]$data.streams[0].field_order
    $repeatPositions = [System.Collections.Generic.List[int]]::new()
    $index = 0
    foreach ($frame in @($data.frames)) {
        if ($null -eq $frame) { continue }
        if ($frame.interlaced_frame -eq 1) { $result.InterlacedFrames++ }
        elseif ($frame.interlaced_frame -eq 0) { $result.ProgressiveFrames++ }
        $repeat = 0
        if ($null -ne $frame.repeat_pict) {
            [void][int]::TryParse([string]$frame.repeat_pict, [ref]$repeat)
        }
        if ($repeat -gt 0) {
            $result.RepeatFrames++
            $repeatPositions.Add($index)
        }
        $index++
    }
    $phase = Get-TelecinePhase -Positions $repeatPositions.ToArray()
    $result.RepeatPhase = $phase.Phase
    $result.RepeatMatch = $phase.Match
    $result.Available = $true
    return $result
}

function Get-TelecineMetadata {
    param([string]$File, [string]$FFprobeExecutable)

    $meta = [pscustomobject]@{
        Duration = 0.0
        AvgFps = 0.0
        NominalFps = 0.0
    }
    if (-not $FFprobeExecutable) { return $meta }
    $data = & $FFprobeExecutable -v error -select_streams v:0 -show_entries 'format=duration:stream=avg_frame_rate,r_frame_rate' -of json -i $File 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $data) { return $meta }
    try {
        $parsed = ($data -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch { return $meta }
    if ($parsed.format.duration) {
        $meta.Duration = [double]::Parse([string]$parsed.format.duration, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($parsed.streams.Count -gt 0) {
        $fraction = [string]$parsed.streams[0].avg_frame_rate
        if ($fraction -match '^(\d+)/(\d+)$' -and [double]$Matches[2] -ne 0) {
            $meta.AvgFps = [double]$Matches[1] / [double]$Matches[2]
        }
        $nominal = [string]$parsed.streams[0].r_frame_rate
        if ($nominal -match '^(\d+)/(\d+)$' -and [double]$Matches[2] -ne 0) {
            $meta.NominalFps = [double]$Matches[1] / [double]$Matches[2]
        }
    }
    return $meta
}

#endregion

#region 統合判定

function Get-TelecineAssessment {
    <#
    .SYNOPSIS
        映像を解析して3:2プルダウン／逆テレシネの要否を返す。
    .DESCRIPTION
        idet（rep_thres 3.0 / 1.5）、decimate の周期ログ、ffprobe のフラグを統合する。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$File,
        [string]$FFmpegExecutable,
        [string]$FFprobeExecutable,
        [int]$Frames = 180,
        [bool]$Full = $false
    )

    $meta = Get-TelecineMetadata -File $File -FFprobeExecutable $FFprobeExecutable
    $flags = Read-TelecineStreamFlags -File $File -FFprobeExecutable $FFprobeExecutable
    if (-not $FFmpegExecutable) {
        return [pscustomobject]@{
            Success = $false
            IsInterlaced = ($flags.FieldOrder -in @('tt', 'bb', 'tb', 'bt') -or $flags.InterlacedFrames -gt 0)
            Telecine32 = $false
            Progressive32 = $false
            Progressive32Mixed = $false
            SoftTelecine = $false
            Verdict = '判定不能（FFmpegなし）'
            Confidence = 0
            RecommendedFilter = ''
            Evidence = ''
            Meta = $meta
            Flags = $flags
            DecimateStarts = @()
        }
    }

    $starts = @(0.0)
    if (-not $Full -and $meta.AvgFps -gt 0 -and $meta.Duration -gt ($Frames / $meta.AvgFps) * 2.5) {
        $windowSeconds = $Frames / $meta.AvgFps
        $latestStart = [math]::Max(0.0, $meta.Duration - $windowSeconds - 1.0)
        $firstStart = [math]::Min($latestStart, [math]::Max(0.0, $meta.Duration * 0.25 - $windowSeconds / 2.0))
        $secondStart = [math]::Min($latestStart, [math]::Max(0.0, $meta.Duration * 0.75 - $windowSeconds / 2.0))
        $starts = @([math]::Round($firstStart, 3), [math]::Round($secondStart, 3))
    }

    # idet は2区間でよいが、decimate は混在を拾うため多个所をサンプリングする。
    $decimateStarts = @($starts)
    if (-not $Full -and $meta.AvgFps -gt 0 -and $meta.Duration -gt ($Frames / $meta.AvgFps) * 2.5) {
        $windowSeconds = $Frames / $meta.AvgFps
        $latestStart = [math]::Max(0.0, $meta.Duration - $windowSeconds - 1.0)
        $decimateStarts = @()
        foreach ($fraction in @(0.10, 0.25, 0.40, 0.55, 0.70, 0.85)) {
            $start = [math]::Min($latestStart, [math]::Max(0.0, $meta.Duration * $fraction - $windowSeconds / 2.0))
            $decimateStarts += [math]::Round($start, 3)
        }
    }

    $idetReports = [System.Collections.Generic.List[object]]::new()
    $usedThreshold = 3.0
    $idetFailed = $false
    foreach ($threshold in $script:TelecineRepeatThresholds) {
        $idetReports.Clear()
        foreach ($start in $starts) {
            $scan = Invoke-TelecineIdetScan -File $File -FFmpegExecutable $FFmpegExecutable -Start $start -Frames $Frames -Full $Full -RepeatThreshold $threshold
            if (-not $scan.Success) { $idetFailed = $true }
            foreach ($report in $scan.Reports) { $idetReports.Add($report) }
        }
        $usedThreshold = $threshold
        if ((Test-TelecineIdetReports -Reports $idetReports.ToArray()) -or $threshold -eq $script:TelecineRepeatThresholds[-1]) {
            break
        }
    }

    $telecine32 = Test-TelecineIdetReports -Reports $idetReports.ToArray()
    $classified = 0
    $progressiveFrames = 0
    $interlacedFrames = 0
    $topRepeats = 0
    $bottomRepeats = 0
    foreach ($report in $idetReports) {
        $classified += $report.Classified
        $progressiveFrames += $report.Progressive
        $interlacedFrames += $report.Interlaced
        $topRepeats += $report.Top
        $bottomRepeats += $report.Bottom
    }
    $progFraction = if ($classified -gt 0) { $progressiveFrames / [double]$classified } else { 0.0 }
    $interlacedFraction = if ($classified -gt 0) { $interlacedFrames / [double]$classified } else { 0.0 }

    $softTelecine = ($flags.Available -and $flags.RepeatFrames -ge 4 -and $flags.RepeatMatch -ge 0.8 -and
        ($flags.RepeatFrames / [double][math]::Max(1, $flags.InterlacedFrames + $flags.ProgressiveFrames)) -ge 0.10)

    $decimateReports = [System.Collections.Generic.List[object]]::new()
    $decimateFailed = $false
    if (-not $telecine32 -and $meta.AvgFps -ge 23.9 -and $meta.AvgFps -le 31.0) {
        foreach ($start in $decimateStarts) {
            $scan = Invoke-TelecineDecimateScan -File $File -FFmpegExecutable $FFmpegExecutable -Start $start -Frames $Frames -Full $Full
            if (-not $scan.Success) { $decimateFailed = $true }
            foreach ($report in $scan.Reports) { $decimateReports.Add($report) }
        }
    }
    $positiveWindows = @($decimateReports | Where-Object { $_.Periodic32 }).Count
    $progressive32 = $positiveWindows -gt 0
    $progressive32All = ($decimateReports.Count -gt 0 -and $positiveWindows -eq $decimateReports.Count)
    $progressive32Mixed = ($positiveWindows -gt 0 -and $positiveWindows -lt $decimateReports.Count)
    $cycles = 0
    $lowRatioCycles = 0
    $dropIsMinCycles = 0
    $ratioSum = 0.0
    foreach ($report in $decimateReports) {
        $cycles += $report.Cycles
        $lowRatioCycles += $report.LowRatio
        $dropIsMinCycles += $report.DropIsMin
        $ratioSum += $report.RatioMedian * $report.Cycles
    }
    $ratioAverage = if ($cycles -gt 0) { $ratioSum / $cycles } else { 0.0 }

    $isInterlaced = ($telecine32 -or
        $flags.FieldOrder -in @('tt', 'bb', 'tb', 'bt') -or
        ($flags.Available -and $interlacedFrames -gt $progressiveFrames) -or
        ($idetFailed -and -not $softTelecine -and -not $progressive32 -and $interlacedFraction -ge 0.5))

    $verdict = ''
    $recommended = ''
    $confidence = 0
    if ($telecine32) {
        $verdict = '推奨（ハードテレシネ：全解析区間で3:2周期を検出）'
        $recommended = 'fieldmatch,decimate'
        $confidence = 92
        if ($usedThreshold -lt 3.0) { $confidence = 88 }
    }
    elseif ($progressive32All -and -not $decimateFailed) {
        $verdict = '推奨（プログレッシブ3:2：全解析区間でフレーム重複を検出。fieldmatch不要）'
        $recommended = 'decimate=cycle=5'
        $confidence = [int][math]::Min(96, 70 + (60 * (1.0 - $ratioAverage)))
    }
    elseif ($progressive32Mixed -and -not $decimateFailed) {
        $coverage = $positiveWindows / [double]$decimateReports.Count
        $verdict = "混在・要確認（一部区間でプログレッシブ3:2を検出 $positiveWindows/$($decimateReports.Count)。全編への一律decimateは非3:2部分のコマ落ちにつながる）"
        $recommended = 'decimate=cycle=5'
        $confidence = [int](55 + (35 * $coverage))
    }
    elseif ($softTelecine -and -not $idetFailed) {
        $verdict = '推奨（soft telecine：repeat_pictに3:2周期。field_orderを確認）'
        $recommended = ''
        $confidence = 80
    }
    elseif ($idetFailed -or $decimateFailed) {
        $verdict = '保留（解析できなかった区間あり）'
        $confidence = 40
    }
    elseif ($progFraction -ge 0.85 -and -not $telecine32 -and -not $progressive32 -and
        $meta.AvgFps -ge 23.9 -and $meta.AvgFps -le 24.1 -and
        $meta.NominalFps -ge 23.9 -and $meta.NominalFps -le 24.1) {
        $verdict = '不要（23.976/24fpsのプログレッシブ映像。3:2周期も未検出）'
        $confidence = 85
    }
    elseif ($interlacedFraction -ge 0.85 -and $topRepeats -eq 0 -and $bottomRepeats -eq 0) {
        $verdict = '不要寄り（3:2周期なし、通常インターレースの可能性）'
        $confidence = 60
    }
    elseif ($progFraction -ge 0.85 -and -not $progressive32) {
        $verdict = '不要寄り（3:2も周期的な重複も見当たらない）'
        $confidence = 65
    }
    else {
        $verdict = '保留（3:2周期未検出だが走査方式が不明・混在）'
        $confidence = 35
    }

    $idetDetail = "idet反復 Top=$topRepeats / Bottom=$bottomRepeats / 周期一致="
    if (($topRepeats + $bottomRepeats) -ge 10) {
        $consistencyAverage = (@($idetReports | ForEach-Object {
            if (($_.Top + $_.Bottom) -ge 10) { $_.Consistency } else { 0.0 }
        }) | Measure-Object -Average).Average
        $idetDetail += ('{0:P0}' -f $consistencyAverage)
    }
    else {
        $idetDetail += '算出保留（反復が少ない）'
    }
    if ($usedThreshold -lt 3.0 -and $telecine32) {
        $idetDetail += " / 標準しきい値では未検出→rep_thres=${usedThreshold}で検出"
    }
    $decimateDetail = if ($cycles -gt 0) {
        "decimate周期=$cycles / 最小diff=$dropIsMinCycles / 低比率=$lowRatioCycles / 比率平均=$($ratioAverage.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)) / 3:2検出区間=$positiveWindows/$($decimateReports.Count)"
    }
    else { 'decimate周期=解析なし' }
    $flagDetail = "field_order=$($flags.FieldOrder) / interlaced_frame=$($flags.InterlacedFrames) / repeat_pict=$($flags.RepeatFrames)"
    $evidence = "$idetDetail`n$decimateDetail`n$flagDetail"

    return [pscustomobject]@{
        Success = (-not $idetFailed)
        IsInterlaced = $isInterlaced
        Telecine32 = $telecine32
        Progressive32 = $progressive32
        Progressive32Mixed = $progressive32Mixed
        SoftTelecine = $softTelecine
        Verdict = $verdict
        Confidence = $confidence
        RecommendedFilter = $recommended
        Evidence = $evidence
        UsedRepeatThreshold = $usedThreshold
        IdetReports = @($idetReports.ToArray())
        DecimateReports = @($decimateReports.ToArray())
        DecimateStarts = @($decimateStarts)
        Meta = $meta
        Flags = $flags
    }
}

#endregion
