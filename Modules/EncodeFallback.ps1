<#
.SYNOPSIS
    エンコードの能力キャッシュ、事前検証、段階的フォールバック、ゼロコピー経路判定を提供する。
.DESCRIPTION
    re-encode-AIOptimus.ps1 からドットソースで読み込まれることを想定している。
    Write-Log / $global:Settings / $global:AppCacheDir は呼び出し側で定義されていること。
    すべての新経路はプローブ（短い実エンコード）に成功した場合のみ採用され、
    失敗時は従来の動作（CPUリサイズ／HWアクセルなし）へ戻る。
#>
#requires -Version 5.1
if (-not (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue)) {
    $global:IsWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    $global:IsLinux = -not $global:IsWindows
    $global:IsMacOS = $false
}
#region 能力キャッシュ (SchemaVersion 1)

$script:EncodeCapabilityCache = $null

function Get-FfmpegSignatureForCapability {
    param([string]$FfPath = '')
    if (-not $FfPath -and $global:Settings -and $global:Settings.FfmpegPath) {
        $FfPath = $global:Settings.FfmpegPath
    }
    if (-not $FfPath) { $FfPath = 'ffmpeg' }
    $resolved = $FfPath
    try {
        $cmd = Get-Command -Name $FfPath -ErrorAction Stop
        if ($cmd.Source) { $resolved = $cmd.Source }
        elseif ($cmd.Path) { $resolved = $cmd.Path }
    }
    catch {}
    $versionLine = ''
    try {
        $versionLine = (& $FfPath -version 2>&1 | Select-Object -First 1).ToString()
    }
    catch {}
    return "$resolved|$versionLine"
}

function Get-EncodeCapabilityCachePath {
    $dir = $global:AppCacheDir
    if (-not $dir) { $dir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '.cache' }
    return (Join-Path $dir 'encode-capability-cache.clixml')
}

function Import-EncodeCapabilityCache {
    if ($script:EncodeCapabilityCache) { return $script:EncodeCapabilityCache }

    $path = Get-EncodeCapabilityCachePath
    $signature = Get-FfmpegSignatureForCapability
    $cache = $null
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try { $cache = Import-Clixml -Path $path -ErrorAction Stop }
        catch { $cache = $null }
    }
    $valid = $cache -and $cache.SchemaVersion -eq 1 -and
             $cache.MachineName -eq [System.Environment]::MachineName -and
             $cache.FfmpegSignature -eq $signature -and
             $cache.Entries
    if (-not $valid) {
        $cache = [pscustomobject]@{
            SchemaVersion   = 1
            MachineName     = [System.Environment]::MachineName
            SavedAt         = Get-Date
            FfmpegSignature = $signature
            Entries         = @{}
        }
    }
    $script:EncodeCapabilityCache = $cache
    return $cache
}

function Get-EncodeCapability {
    param([string]$Key)
    if (-not $Key) { return $null }
    $cache = Import-EncodeCapabilityCache
    if ($cache.Entries -and $cache.Entries.ContainsKey($Key)) {
        $entry = $cache.Entries[$Key]
        # 7日より古いエントリは無効とみなす（ドライバ更新などの変化に追従するため）
        try {
            if ($entry.TestedAt -and ((Get-Date) - [datetime]$entry.TestedAt).TotalDays -gt 7) {
                return $null
            }
        }
        catch {}
        return $entry
    }
    return $null
}

function Set-EncodeCapability {
    param(
        [string]$Key,
        [string]$Status,
        [string]$FailureClass = ''
    )
    if (-not $Key) { return }
    $cache = Import-EncodeCapabilityCache
    if (-not $cache.Entries) { $cache.Entries = @{} }
    $cache.Entries[$Key] = [pscustomobject]@{
        Status       = $Status
        FailureClass = $FailureClass
        TestedAt     = Get-Date
    }
    $cache.SavedAt = Get-Date
    try {
        Export-Clixml -InputObject $cache -Path (Get-EncodeCapabilityCachePath) -Force -ErrorAction Stop
    }
    catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "エンコード能力キャッシュの保存に失敗しました: $_" -Level 'WARN'
        }
    }
}

function Clear-EncodeCapabilityCache {
    $script:EncodeCapabilityCache = $null
    $path = Get-EncodeCapabilityCachePath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Get-EncodeCapabilityKey {
    param(
        [string]$HwAccelOption = '',
        [string]$VideoFilter = '',
        [string]$VideoOptions = ''
    )
    $normalized = "$HwAccelOption|$VideoFilter|$VideoOptions"
    $normalized = $normalized -replace '\s+', ' '
    $normalized = $normalized -replace '-passlogfile\s+\S+', '-passlogfile X'
    $normalized = $normalized -replace '-pass\s+[12]\b', '-pass X'
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

#endregion

#region 失敗分類

function Get-EncodeFailureClass {
    <#
    .SYNOPSIS
        ffmpeg の stderr から失敗クラスを判定する。
        HwDecodeInit / HwFilter / HwEncodeInit のみHW関連としてフォールバック対象。
    #>
    param([string]$StdErr)
    if ([string]::IsNullOrWhiteSpace($StdErr)) { return 'Unknown' }

    if ($StdErr -match '(?i)(Failed setup for format|hwaccel initialisation returned error|hw_device_ctx|Error creating a MFX session|No device available|Device does not support|Failed to create.*device|Cannot map.*surface|hwframe.*error|Failed to configure output for pix_fmt)') {
        return 'HwDecodeInit'
    }
    if ($StdErr -match '(?i)(Error (parsing|initializing|setting) filter|No such filter|Filter .*not found|Error reinitializing filters|scale_qsv|vpp_qsv|scale_cuda|vpp_amf|scale_d3d11|scale_vulkan|hwdownload|hwupload|Impossible to convert between the formats|format=.*(not supported|invalid))') {
        return 'HwFilter'
    }
    if ($StdErr -match '(?i)(Encoder .*not found|Error.*initializing encoder|Failed to initialize encoder|Codec AVOption|Specified pixel format .*is not supported|not supported.*encoder|Error while opening encoder)') {
        return 'HwEncodeInit'
    }
    if ($StdErr -match '(?i)(Option .*not found|Unrecognized option|Invalid value|Undefined constant|Error setting option|Invalid argument)') {
        return 'EncoderOption'
    }
    return 'Unknown'
}

function Test-IsHwRelatedFailureClass {
    param([string]$Class)
    return ($Class -in @('HwDecodeInit', 'HwFilter', 'HwEncodeInit'))
}

#endregion

#region 引数変換

function Remove-HwAccelArguments {
    param([string]$ArgString)
    $result = $ArgString
    $result = $result -replace '\s*-hwaccel_output_format\s+\S+', ''
    $result = $result -replace '\s*-hwaccel\s+\S+', ''
    $result = $result -replace '\s*-extra_hw_frames\s+\d+', ''
    $result = $result -replace 'hwdownload,format=nv12,', ''
    $result = $result -replace ',hwdownload,format=nv12', ''
    $result = $result -replace '\s*-vf\s+"hwdownload,format=nv12"', ''
    $result = $result -replace '\s*-vf\s+""', ''
    return ($result -replace '\s{2,}', ' ').Trim()
}

function Convert-GpuFilterToCpuFilter {
    <#
    .SYNOPSIS
        -vf 内の GPU スケーラーを CPU の scale + hwdownload に置き換える（汎用版）。
    #>
    param([string]$ArgString)
    $vfMatch = [regex]::Match($ArgString, '(?i)(-vf\s+")([^"]*)(")')
    if (-not $vfMatch.Success) { return $ArgString }
    $vf = $vfMatch.Groups[2].Value
    if ($vf -notmatch '(?i)\b(scale_qsv|vpp_qsv|scale_cuda|vpp_amf|scale_d3d11|scale_vulkan|scale_vaapi|scale_vt)\b') {
        return $ArgString
    }
    $sizeMatch = [regex]::Match($vf, '(?i)(?:w|width)=(?<w>[^:,\s]+):(?:h|height)=(?<h>[^:,\s]+)')
    if (-not $sizeMatch.Success) { return $ArgString }
    $w = $sizeMatch.Groups['w'].Value
    $h = $sizeMatch.Groups['h'].Value

    $remainder = [regex]::Replace($vf, '(?i)(?:^|,)(?:scale_qsv|vpp_qsv|scale_cuda|vpp_amf|scale_d3d11|scale_vulkan|scale_vaapi|scale_vt)=[^,]*', '')
    $remainder = $remainder.Trim(',')
    # VAAPI エンコーダは VAAPI surface のみを受け付けるため、CPU スケール後に再度 hwupload する
    $isVaapiEncode = $ArgString -match '(?i)-c:v(?::\w+)?\s+\S+_vaapi\b'
    $download = if ($isVaapiEncode) { 'format=nv12,hwupload,' } elseif ($remainder -match 'hwdownload') { '' } else { 'hwdownload,format=nv12,' }
    $newVf = "$download" + "scale=$w`:$h" + $(if ($remainder) { ",$remainder" } else { '' })

    return [regex]::Replace($ArgString, '(?<=-vf\s+")[^"]*(?=")', { $newVf })
}

function Get-FallbackArgumentTiers {
    param(
        [string]$Arguments,
        [string]$HwAccelOption = '',
        [switch]$AllowCpuEncoderFallback
    )
    $tiers = [System.Collections.Generic.List[object]]::new()
    $tiers.Add([pscustomobject]@{ Name = '要求設定'; Args = $Arguments; Kind = 'Requested' })

    $cpuFilterArgs = Convert-GpuFilterToCpuFilter -ArgString $Arguments
    if ($cpuFilterArgs -ne $Arguments) {
        $tiers.Add([pscustomobject]@{ Name = 'GPUスケール→CPUスケール'; Args = $cpuFilterArgs; Kind = 'CpuFilter' })
    }

    if ($HwAccelOption -match '-hwaccel\s+\S+') {
        $noHwArgs = Remove-HwAccelArguments -ArgString $cpuFilterArgs
        if ($noHwArgs -ne $cpuFilterArgs) {
            $tiers.Add([pscustomobject]@{ Name = 'HWアクセルなし (HWエンコーダ維持)'; Args = $noHwArgs; Kind = 'NoHwAccel' })
        }
    }

    if ($AllowCpuEncoderFallback) {
        $cpuArgs = Remove-HwAccelArguments -ArgString $cpuFilterArgs
        $cpuArgs = [regex]::Replace($cpuArgs, '(?i)-c:v\s+\S+_(nvenc|qsv|amf|vulkan|d3d12va|mf)\b', '-c:v libx264')
        $cpuArgs = $cpuArgs -replace '(?i)\s+-(?:rc|preset|tune|global_quality|qp|cq|b:v|maxrate|bufsize)\s+\S+', ''
        if ($cpuArgs -ne $cpuFilterArgs) {
            $tiers.Add([pscustomobject]@{ Name = 'CPUエンコーダ (libx264)'; Args = $cpuArgs; Kind = 'CpuEncoder' })
        }
    }

    # 単一要素でも配列として返す（PowerShell のパイプライン展開を防ぐ）
    return ,$tiers.ToArray()
}

#endregion

#region 事前検証 / プローブ

function Invoke-ProbeFfmpeg {
    <#
    .SYNOPSIS
        軽量な ffmpeg 実行（進捗監視なし）。stderr と ExitCode を返す。
    #>
    param([string]$Arguments)

    $ffmpegPath = $global:Settings.FfmpegPath
    # 一時ファイルはプロジェクト内の git 対象外ディレクトリに限定する
    $tempDir = Join-Path $global:AppCacheDir 'tmp'
    if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $tempDir -Force
    }
    $stderrFile = Join-Path $tempDir "re-enc-probe-err-$([System.IO.Path]::GetRandomFileName())"
    $stdoutFile = Join-Path $tempDir "re-enc-probe-out-$([System.IO.Path]::GetRandomFileName())"
    try {
        $proc = Start-Process -FilePath $ffmpegPath -ArgumentList $Arguments `
            -PassThru -NoNewWindow `
            -RedirectStandardError $stderrFile `
            -RedirectStandardOutput $stdoutFile
        $null = $proc.Handle
        $proc.WaitForExit()
        $stderr = ''
        if (Test-Path -LiteralPath $stderrFile) {
            $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
        }
        return @{ ExitCode = $proc.ExitCode; StdErr = $stderr }
    }
    catch {
        return @{ ExitCode = -1; StdErr = $_.Exception.Message }
    }
    finally {
        # Ctrl+C 等で中断された場合、別プロセスの ffmpeg が残らぬよう終了させる
        if ($proc -and -not $proc.HasExited) {
            try { $proc.Kill($true) } catch {}
        }
        Remove-Item -LiteralPath $stderrFile, $stdoutFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-EncodeConfiguration {
    <#
    .SYNOPSIS
        本番と同一のデコード/フィルタ/エンコード設定を数フレームだけ試し、成否を返す。
    #>
    param(
        [string]$Arguments,
        [int]$Frames = 8
    )
    $probe = $Arguments
    $probe = $probe -replace '(?i)\s+-pass\s+[12]\b', ''
    $probe = $probe -replace '(?i)\s+-passlogfile\s+\S+', ''
    $probe = $probe -replace '(?i)\s+-progress\s+\S+', ''
    $probe = $probe -replace '(?i)\s+-f\s+null\s+(?:NUL|-)\s*$', ''
    # 末尾の「引用符付き出力ファイル指定」のみを除去する。
    # 2pass の 1st pass は -f null - (Windows は NUL) で終わるため、素のトークンを除去すると
    # 直後のオプション（-an 等）を誤って消してしまう。
    if ($probe -match '(?s)^(.*\S)\s+"[^"]+"\s*$') {
        $probe = $Matches[1]
    }
    $probe = "$probe -an -frames:v $Frames -f null -"

    $result = Invoke-ProbeFfmpeg -Arguments $probe
    $class = if ($result.ExitCode -eq 0) { '' } else { Get-EncodeFailureClass -StdErr $result.StdErr }
    return @{ Success = ($result.ExitCode -eq 0); StdErr = $result.StdErr; Class = $class; ProbeArgs = $probe }
}

function Test-ZeroCopyPath {
    <#
    .SYNOPSIS
        実際の入力ファイルを使って GPU フレーム経路が成立するか短くプローブする。
    #>
    param(
        [string]$InputPath,
        [string]$HwAccelOption = '',
        [string]$VideoFilter = '',
        [string]$VideoOptions = '',
        [int]$Frames = 2
    )
    if (-not $InputPath -or -not (Test-Path -LiteralPath $InputPath -PathType Leaf)) { return $false }

    $probeArgs = "-hide_banner -y $HwAccelOption -ss 0 -i `"$InputPath`" -an"
    if ($VideoFilter) { $probeArgs += " -vf `"$VideoFilter`"" }
    $probeArgs += " -frames:v $Frames $VideoOptions -f null -"

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "ゼロコピー経路プローブ: $VideoFilter / $HwAccelOption" -Level 'DEBUG'
    }
    $result = Invoke-ProbeFfmpeg -Arguments $probeArgs
    return ($result.ExitCode -eq 0)
}

function Resolve-ZeroCopyScaleFilter {
    <#
    .SYNOPSIS
        D3D11VA デコード + QSV エンコードで GPU フレームを維持できる経路を探す。
        成功実績のある経路はキャッシュし、失敗経路は再プローブしない。
    #>
    param(
        [string]$InputPath,
        [string]$FrameFormat,
        [string]$Encoder,
        [string]$VideoFilter,
        [string]$HwAccelOption,
        [string]$VideoOptions
    )
    if ($FrameFormat -ne 'd3d11' -or $Encoder -notmatch '_qsv$') { return $null }

    $match = [regex]::Match($VideoFilter, '(?i)^\s*scale=(?<w>-?\d+):(?<h>-2|-1|\d+)(?:,(?<tail>.*))?\s*$')
    if (-not $match.Success -or $match.Groups['tail'].Value) { return $null }

    $w = $match.Groups['w'].Value
    $hRaw = $match.Groups['h'].Value
    $h = if ($hRaw -eq '-2') { "trunc(ih*$w/iw/2)*2" }
         elseif ($hRaw -eq '-1') { "trunc(ih*$w/iw)" }
         else { $hRaw }

    # hwmap=mode=direct はドライバによっては ffmpeg 本体が ACCESS_VIOLATION で
    # 落ちることが確認されたため候補から除外する（安全性を優先）。
    $candidates = @(
        "scale_qsv=w=$w`:h=$h",
        "vpp_qsv=w=$w`:h=$h"
    )

    foreach ($candidate in $candidates) {
        $key = Get-EncodeCapabilityKey -HwAccelOption "$HwAccelOption|$FrameFormat|$Encoder" `
                                       -VideoFilter $candidate -VideoOptions $VideoOptions
        $cached = Get-EncodeCapability -Key $key
        if ($cached -and $cached.Status -eq 'Failed') { continue }
        if (-not $cached) {
            $ok = Test-ZeroCopyPath -InputPath $InputPath -HwAccelOption $HwAccelOption `
                                    -VideoFilter $candidate -VideoOptions $VideoOptions
            Set-EncodeCapability -Key $key -Status $(if ($ok) { 'OK' } else { 'Failed' }) `
                                 -FailureClass $(if ($ok) { '' } else { 'ZeroCopyProbe' })
            if (-not $ok) { continue }
        }
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "D3D11VA→QSV ゼロコピー経路を採用: $candidate" -Level 'DEBUG'
        }
        return $candidate
    }
    return $null
}

#endregion

#region 統一フォールバック

function Invoke-EncodeWithFallback {
    <#
    .SYNOPSIS
        事前検証 → 段階的フォールバック付きで ffmpeg エンコードを実行する。
    #>
    param(
        [string]$Arguments,
        [string]$HwAccelOption = '',
        [string]$VideoFilter = '',
        [string]$VideoOptions = '',
        [double]$DurationSeconds = 0,
        [string]$Label = 'エンコード',
        [switch]$SkipPreflight,
        [switch]$AllowCpuEncoderFallback
    )

    $key = Get-EncodeCapabilityKey -HwAccelOption $HwAccelOption `
                                   -VideoFilter $VideoFilter -VideoOptions $VideoOptions
    $tiers = Get-FallbackArgumentTiers -Arguments $Arguments -HwAccelOption $HwAccelOption `
                                       -AllowCpuEncoderFallback:$AllowCpuEncoderFallback

    $startIndex = 0
    $cached = Get-EncodeCapability -Key $key
    if (-not $SkipPreflight -and -not $cached) {
        for ($i = 0; $i -lt $tiers.Count; $i++) {
            $probe = Test-EncodeConfiguration -Arguments $tiers[$i].Args
            if ($probe.Success) {
                Set-EncodeCapability -Key $key -Status 'OK'
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log "[Preflight] $($Label): tier $($i + 1) ($($tiers[$i].Name)) で検証成功" -Level 'DEBUG'
                }
                $startIndex = $i
                break
            }
            Set-EncodeCapability -Key "$key|tier$i" -Status 'Failed' -FailureClass $probe.Class
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log "[Preflight] $($Label): tier $($i + 1) ($($tiers[$i].Name)) 検証失敗 ($($probe.Class))" -Level 'WARN'
            }
        }
    }

    $lastResult = $null
    for ($i = $startIndex; $i -lt $tiers.Count; $i++) {
        $tier = $tiers[$i]
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "[Fallback] $Label tier $($i + 1)/$($tiers.Count) ($($tier.Name)) 実行" -Level 'INFO'
        }
        if (Get-Command Invoke-QsvEncodeWithDepthFallback -ErrorAction SilentlyContinue) {
            $lastResult = Invoke-QsvEncodeWithDepthFallback -Arguments $tier.Args -DurationSeconds $DurationSeconds
        }
        else {
            $lastResult = Invoke-FfmpegEncode -Arguments $tier.Args -DurationSeconds $DurationSeconds
        }

        if ($lastResult.ExitCode -eq 0) {
            $lastResult['Tier'] = $tier.Kind
            $lastResult['TierName'] = $tier.Name
            if ($i -gt 0 -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
                Write-Log "[Fallback] $($Label): tier $($i + 1) で成功" -Level 'WARN'
            }
            return $lastResult
        }

        $class = Get-EncodeFailureClass -StdErr $lastResult.StdErr
        if (-not (Test-IsHwRelatedFailureClass -Class $class)) {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log "[Fallback] $($Label): HW非関連エラー ($class) のためフォールバックを停止" -Level 'WARN'
            }
            break
        }
    }
    return $lastResult
}

#endregion

# ドットソースで読み込むため Export-ModuleMember は使用しない。
