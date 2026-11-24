#requires -Version 5.1
if (-not (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue)) {
    $global:IsWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    $global:IsLinux = -not $global:IsWindows
    $global:IsMacOS = $false
}
#region HWフィルター自動置換

$script:HwFilterAvailability = $null
$script:HwFilterProbeCache = $null
$script:HwFilterProbeOverride = @{}

function Get-HwFilterFFmpegPath {
    if ($global:Settings -and $global:Settings.FfmpegPath) { return [string]$global:Settings.FfmpegPath }
    return 'ffmpeg'
}

function Get-HwFilterList {
    if ($null -eq $script:HwFilterAvailability) {
        $script:HwFilterAvailability = @{}
        $lines = @(& (Get-HwFilterFFmpegPath) -hide_banner -filters 2>$null)
        foreach ($line in $lines) {
            if ($line -match '^\s*\S+\s+(?<name>[A-Za-z0-9_]+)\s+') {
                $script:HwFilterAvailability[$Matches['name']] = $true
            }
        }
    }
    return $script:HwFilterAvailability
}

function Test-HwFilterAvailable {
    param([string]$Name)
    if (-not $Name) { return $false }
    return (Get-HwFilterList).ContainsKey($Name)
}

function Get-HwFilterSignature {
    param([string]$FfPath = '')
    if (-not $FfPath) { $FfPath = Get-HwFilterFFmpegPath }
    $resolvedPath = $FfPath
    try {
        $command = Get-Command -Name $FfPath -ErrorAction Stop
        if ($command.Source) { $resolvedPath = $command.Source }
        elseif ($command.Path) { $resolvedPath = $command.Path }
    }
    catch {}
    $versionLine = ''
    try { $versionLine = (& $FfPath -version 2>&1 | Select-Object -First 1).ToString() } catch {}
    return "$resolvedPath|$versionLine"
}

function Get-HwFilterCachePath {
    if (-not $global:AppCacheDir) { return '' }
    return (Join-Path $global:AppCacheDir 'hardware-filter-cache.clixml')
}

function Load-HwFilterProbeCache {
    param([string]$Signature = '')
    $cachePath = Get-HwFilterCachePath
    if (-not $cachePath -or -not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { return $null }
    try { $cached = Import-Clixml -LiteralPath $cachePath -ErrorAction Stop } catch { return $null }
    if (-not $cached -or $cached.SchemaVersion -ne 2) { return $null }
    if ($cached.MachineName -ne [System.Environment]::MachineName) { return $null }
    if ($Signature -and $cached.FfmpegSignature -ne $Signature) { return $null }
    if ($cached.SavedAt -and ((Get-Date) - [datetime]$cached.SavedAt).TotalDays -gt 7) { return $null }
    return $cached
}

function Save-HwFilterProbeCache {
    param([hashtable]$Results)
    $cachePath = Get-HwFilterCachePath
    if (-not $cachePath) { return $false }
    try {
        $cacheObject = [pscustomobject]@{
            SchemaVersion   = 2
            MachineName     = [System.Environment]::MachineName
            SavedAt         = Get-Date
            FfmpegSignature = Get-HwFilterSignature
            Results         = $Results
        }
        $cacheObject | Export-Clixml -LiteralPath $cachePath -Force
        return $true
    }
    catch { return $false }
}

function Test-HwFilterProbe {
    param(
        [string]$FilterExpr,
        [string]$HwAccelOption = '',
        [string]$VideoOptions = '',
        [string]$InputPath = '',
        [switch]$SkipProbe
    )
    if (-not $FilterExpr) { return $false }
    $key = "$HwAccelOption|$VideoOptions|$FilterExpr"
    if ($SkipProbe) { return $true }
    if ($script:HwFilterProbeOverride.ContainsKey($key)) { return [bool]$script:HwFilterProbeOverride[$key] }
    if (-not $InputPath -or -not (Test-Path -LiteralPath $InputPath -PathType Leaf)) { return $false }
    if (-not $VideoOptions) { return $false }

    $signature = Get-HwFilterSignature
    $cache = $null
    if ($null -eq $script:HwFilterProbeCache) { $script:HwFilterProbeCache = Load-HwFilterProbeCache -Signature $signature }
    $cache = $script:HwFilterProbeCache
    if ($cache -and $cache.Results -and $cache.Results.ContainsKey($key)) { return [bool]$cache.Results[$key] }

    # ネイティブ引数を要素単位で正確に渡すため、この関数内のみ Standard モードを使う
    $PSNativeCommandArgumentPassing = 'Standard'

    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.Add('-hide_banner')
    $argList.Add('-loglevel')
    $argList.Add('error')
    $argList.Add('-y')
    if ($HwAccelOption) { foreach ($part in ($HwAccelOption -split '\s+')) { if ($part) { $argList.Add($part) } } }
    if (($HwAccelOption -match 'vaapi') -or ($VideoOptions -match '_vaapi\b')) {
        $vaapiDevice = if ($global:Settings -and $global:Settings.VaapiDevicePath) { $global:Settings.VaapiDevicePath } else { '/dev/dri/renderD128' }
        $argList.Add('-vaapi_device')
        $argList.Add($vaapiDevice)
    }
    $argList.Add('-ss')
    $argList.Add('0')
    $argList.Add('-t')
    $argList.Add('0.2')
    $argList.Add('-i')
    $argList.Add($InputPath)
    $argList.Add('-vf')
    $argList.Add($FilterExpr)
    foreach ($part in ($VideoOptions -split '\s+')) { if ($part) { $argList.Add($part) } }
    $argList.Add('-frames:v')
    $argList.Add('2')
    $argList.Add('-an')
    $argList.Add('-f')
    $argList.Add('null')
    $argList.Add('-')

    $null = & (Get-HwFilterFFmpegPath) @argList 2>&1
    $ok = ($LASTEXITCODE -eq 0)

    if (-not $cache) {
        $cache = [pscustomobject]@{ SchemaVersion = 2; MachineName = [System.Environment]::MachineName; SavedAt = Get-Date; FfmpegSignature = $signature; Results = @{} }
    }
    $cache.Results[$key] = $ok
    $script:HwFilterProbeCache = $cache
    $null = Save-HwFilterProbeCache -Results $cache.Results
    return $ok
}

function Convert-HwFilterScale {
    param([string]$Expr, [string]$Candidate)
    $m = [regex]::Match($Expr, '^\s*scale\s*=\s*(?:(?:w|width)=(?<w>[^:,]+):(?:h|height)=(?<h>[^:,]+)|(?<w>[^:,]+):(?<h>[^:,]+))\s*$')
    if (-not $m.Success) { return '' }
    $w = $m.Groups['w'].Value
    $h = $m.Groups['h'].Value
    if ($h -eq '-2') { $h = "trunc(ih*$w/iw/2)*2" }
    elseif ($h -eq '-1') { $h = "trunc(ih*$w/iw)" }
    if ($Candidate -eq 'scale_d3d11') { return "${Candidate}=width=$w`:height=$h`:format=nv12" }
    return "${Candidate}=w=$w`:h=$h"
}

function Convert-HwFilterPassthrough {
    param([string]$Expr, [string]$Candidate)
    $nameEnd = $Expr.IndexOf('=')
    if ($nameEnd -lt 0) { return $Candidate }
    return $Candidate + $Expr.Substring($nameEnd)
}

function Convert-HwFilterDeinterlace {
    param([string]$Expr, [string]$Candidate)
    $nameEnd = $Expr.IndexOf('=')
    $args = if ($nameEnd -ge 0) { $Expr.Substring($nameEnd + 1) } else { '' }
    # QSV/VAAPIのデインターレースは引数体系が異なるため、既定設定のみ変換する
    if ($Candidate -in @('deinterlace_qsv', 'deinterlace_vaapi')) {
        if ($args -and $args -notin @('0:-1:0', '0:-1:1')) { return '' }
        return $Candidate
    }
    if ($nameEnd -lt 0) { return $Candidate }
    return $Candidate + $Expr.Substring($nameEnd)
}

function Get-HwFilterRules {
    param([string]$FrameFormat)
    $rules = switch ($FrameFormat) {
        'qsv' {
            @(
                @{ Cpu = @('scale'); Candidates = @('scale_qsv', 'vpp_qsv'); Convert = 'Scale' }
                @{ Cpu = @('yadif', 'bwdif'); Candidates = @('deinterlace_qsv'); Convert = 'Deinterlace' }
                @{ Cpu = @('pad'); Candidates = @('pad_qsv'); Convert = 'Passthrough' }
                @{ Cpu = @('overlay'); Candidates = @('overlay_qsv'); Convert = 'Passthrough' }
            )
        }
        'cuda' {
            @(
                @{ Cpu = @('scale'); Candidates = @('scale_cuda'); Convert = 'Scale' }
                @{ Cpu = @('yadif', 'bwdif'); Candidates = @('yadif_cuda', 'bwdif_cuda'); Convert = 'Passthrough' }
                @{ Cpu = @('pad'); Candidates = @('pad_cuda'); Convert = 'Passthrough' }
                @{ Cpu = @('transpose'); Candidates = @('transpose_cuda'); Convert = 'Passthrough' }
                @{ Cpu = @('hflip'); Candidates = @('hflip_cuda'); Convert = 'Passthrough' }
                @{ Cpu = @('chromakey'); Candidates = @('chromakey_cuda'); Convert = 'Passthrough' }
                @{ Cpu = @('colorspace'); Candidates = @('colorspace_cuda'); Convert = 'Passthrough' }
                @{ Cpu = @('bilateral'); Candidates = @('bilateral_cuda'); Convert = 'Passthrough' }
                @{ Cpu = @('overlay'); Candidates = @('overlay_cuda'); Convert = 'Passthrough' }
            )
        }
        'amf' {
            @(
                @{ Cpu = @('scale'); Candidates = @('vpp_amf', 'sr_amf'); Convert = 'Scale' }
            )
        }
        'd3d11' {
            @(
                @{ Cpu = @('scale'); Candidates = @('scale_d3d11'); Convert = 'Scale' }
            )
        }
        'vulkan' {
            @(
                @{ Cpu = @('scale'); Candidates = @('scale_vulkan'); Convert = 'Scale' }
                @{ Cpu = @('yadif', 'bwdif'); Candidates = @('bwdif_vulkan'); Convert = 'Deinterlace' }
                @{ Cpu = @('transpose'); Candidates = @('transpose_vulkan'); Convert = 'Passthrough' }
                @{ Cpu = @('hflip'); Candidates = @('hflip_vulkan'); Convert = 'Passthrough' }
                @{ Cpu = @('vflip'); Candidates = @('vflip_vulkan'); Convert = 'Passthrough' }
                @{ Cpu = @('avgblur'); Candidates = @('avgblur_vulkan'); Convert = 'Passthrough' }
                @{ Cpu = @('gblur'); Candidates = @('gblur_vulkan'); Convert = 'Passthrough' }
                @{ Cpu = @('nlmeans'); Candidates = @('nlmeans_vulkan'); Convert = 'Passthrough' }
                @{ Cpu = @('overlay'); Candidates = @('overlay_vulkan'); Convert = 'Passthrough' }
            )
        }
        'vaapi' {
            @(
                @{ Cpu = @('scale'); Candidates = @('scale_vaapi'); Convert = 'Scale' }
                @{ Cpu = @('yadif', 'bwdif'); Candidates = @('deinterlace_vaapi'); Convert = 'Deinterlace' }
                @{ Cpu = @('pad'); Candidates = @('pad_vaapi'); Convert = 'Passthrough' }
                @{ Cpu = @('transpose'); Candidates = @('transpose_vaapi'); Convert = 'Passthrough' }
                @{ Cpu = @('tonemap'); Candidates = @('tonemap_vaapi'); Convert = 'Passthrough' }
                @{ Cpu = @('sharpness'); Candidates = @('sharpness_vaapi'); Convert = 'Passthrough' }
            )
        }
        'videotoolbox' {
            @(
                @{ Cpu = @('scale'); Candidates = @('scale_vt'); Convert = 'Scale' }
            )
        }
        default { @() }
    }
    return @($rules)
}

function Convert-HwFilterExpression {
    param([string]$Expr, [string]$Candidate, [string]$Converter)
    switch ($Converter) {
        'Scale'       { return Convert-HwFilterScale -Expr $Expr -Candidate $Candidate }
        'Deinterlace' { return Convert-HwFilterDeinterlace -Expr $Expr -Candidate $Candidate }
        default       { return Convert-HwFilterPassthrough -Expr $Expr -Candidate $Candidate }
    }
}

function Resolve-HardwareFilterGraph {
    param(
        [string]$Filter,
        [string]$FrameFormat = '',
        [string]$HwAccelOption = '',
        [string]$VideoOptions = '',
        [string]$InputPath = '',
        [switch]$SkipProbe
    )
    $result = @{ Filter = $Filter; Replacements = @() }
    if (-not $Filter -or -not $FrameFormat) { return $result }

    $rules = @(Get-HwFilterRules -FrameFormat $FrameFormat)
    if ($rules.Count -eq 0) { return $result }

    $parts = [regex]::Split($Filter, '(?<!\\),')
    $replaced = [System.Collections.Generic.List[string]]::new()
    foreach ($part in $parts) {
        if (-not $part) { continue }
        $name = ([regex]::Match($part, '^\s*([A-Za-z0-9_]+)')).Groups[1].Value
        $newPart = $part
        foreach ($rule in $rules) {
            if ($rule.Cpu -notcontains $name) { continue }
            foreach ($candidate in $rule.Candidates) {
                if (-not (Test-HwFilterAvailable -Name $candidate)) { continue }
                $converted = Convert-HwFilterExpression -Expr $part -Candidate $candidate -Converter $rule.Convert
                if (-not $converted) { continue }
                if (-not (Test-HwFilterProbe -FilterExpr $converted -HwAccelOption $HwAccelOption -VideoOptions $VideoOptions -InputPath $InputPath -SkipProbe:$SkipProbe)) { continue }
                $newPart = $converted
                $result.Replacements += "$name → $candidate ($FrameFormat)"
                break
            }
            if ($newPart -ne $part) { break }
        }
        $replaced.Add($newPart)
    }
    $result.Filter = $replaced -join ','
    return $result
}

function Add-HwDownloadToFilterComplex {
    <#
    .SYNOPSIS
        HWデコード時のHWフレームをCPU用フィルターへ渡すため、filter_complexの入力にhwdownloadを挿入する。
    #>
    param([string]$ArgsString, [string]$FrameFormat = '')
    if (-not $ArgsString -or -not $FrameFormat) { return $ArgsString }
    $match = [regex]::Match($ArgsString, '(?i)-filter_complex\s+"(?<graph>[^"]*)"')
    if (-not $match.Success) { return $ArgsString }
    $graph = $match.Groups['graph'].Value
    if ($graph -match 'hwdownload') { return $ArgsString }
    if ($graph -notmatch '(?i)\b(split|crop|pad|blend|hstack|vstack|xstack|lenscorrection|yadif|bwdif|nnedi|fieldmatch|decimate|setsar)\b') {
        return $ArgsString
    }
    $newGraph = [regex]::Replace($graph, '(\[\d+:v(?::\d+)?\])', '${1}hwdownload,format=nv12,')
    return $ArgsString.Replace($graph, $newGraph)
}

function Clear-HwFilterProbeCache {
    $cachePath = Get-HwFilterCachePath
    if ($cachePath -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    }
    $script:HwFilterProbeCache = $null
}
#endregion
