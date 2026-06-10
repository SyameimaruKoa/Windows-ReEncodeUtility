<#
.SYNOPSIS
    FFmpegのエンコードオプションを対話形式で設定するスクリプトじゃ。
.DESCRIPTION
    映像コーデック（H.264/5, AV1, VP9/8）と音声コーデック（AAC, Opus, Vorbis, FLAC等）を
    ハードウェアや品質に応じて選択し、設定結果を呼び出し元のスクリプトに返すぞ。
    スキャン情報がない場合は、すべての選択肢を出すようにフォールバックするのじゃ。
.PARAMETER Intermediate
    このスイッチを指定すると、編集用の中間ファイルを作成するための専用メニューが表示される。
.PARAMETER HwScanMode
    ハードウェアスキャンの挙動を選択するぞ。
    On: 必ずスキャンする
    Optional: スキャンするかどうかユーザーに選ばせる (デフォルト)
    Off: スキャンしない (全エンコーダーを強制表示)
.OUTPUTS
    System.Collections.Hashtable
    選択された映像・音声のエンコード設定を含むハッシュテーブルを返す。
#>
[CmdletBinding()]
param (
    [switch]$Intermediate,
    [ValidateSet("On", "Optional", "Off")]
    [string]$HwScanMode = "Optional"
)

#region ヘルプ表示
if ($args -contains "-h" -or $args -contains "--help") {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    exit
}
#endregion

# --- ハードウェアスキャンの実行 ---
if ($HwScanMode -ne "Off") {
    $hwScriptPath = Join-Path $PSScriptRoot "Get-HardwareInfo.ps1"
    if (Test-Path $hwScriptPath) {
        if ($HwScanMode -eq "Optional") {
            # Show-Menu がまだない可能性があるため簡易表示
            Write-Host "ハードウェアスキャンを行いますか？`n(正確な利用可能コーデックが分かりますが、少し時間がかかります)"
            Write-Host " [Y] はい (スキャンする)  [N] いいえ (スキャンせずに全ての選択肢を表示する)"
            $choice = Read-Host "選択"
            if ($choice -match "^[Yy]") {
                $null = . $hwScriptPath
            }
        }
        else {
            $null = . $hwScriptPath
        }
    }
}

# --- 対話メニュー関数 ---
# グローバルスコープに Show-Menu が定義されていない場合のみローカルで定義する
# (re-encode-AIOptimus.ps1 から呼ばれる場合は既にグローバルに存在する)
if (-not (Get-Command -Name 'Show-Menu' -CommandType Function -ErrorAction SilentlyContinue)) {
    function Show-Menu {
        param (
            [string]$Title,
            [string[]]$Choices,
            [int]$DefaultIndex = 0
        )
        $currentIndex = $DefaultIndex
        while ($true) {
            Clear-Host
            Write-Host "$Title`n"
            for ($i = 0; $i -lt $Choices.Length; $i++) {
                if ($i -eq $currentIndex) {
                    Write-Host -ForegroundColor Black -BackgroundColor White " > $($Choices[$i])"
                }
                else {
                    Write-Host "   $($Choices[$i])"
                }
            }
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            switch ($key.VirtualKeyCode) {
                38 { if ($currentIndex -gt 0) { $currentIndex-- } } # UpArrow
                40 { if ($currentIndex -lt ($Choices.Length - 1)) { $currentIndex++ } } # DownArrow
                13 { return $currentIndex } # Enter
                27 { return -1 } # Escape
            }
        }
    }
}

# --- 詳細な映像オプション選択関数 ---
function Get-DetailedVideoOption {
    param(
        [string]$BaseEncoder,
        [System.Collections.IDictionary]$QualityPresets,
        [System.Collections.IDictionary]$PresetOptions,
        [System.Collections.IDictionary]$TuneOptions
    )

    $finalOptions = @($BaseEncoder)

    # --- 1. 品質設定 ---
    $qChoices = @($QualityPresets.Keys)
    $qIndex = Show-Menu -Title "品質を選択してください。" -Choices $qChoices
    if ($qIndex -lt 0) { return $null }
    $selectedQKey = $qChoices[$qIndex]

    if ($selectedQKey -like "*カスタム*") {
        if ($selectedQKey -like "*品質*") {
            $val = Read-Host "品質値を入力"
            $finalOptions += $QualityPresets[$selectedQKey].Replace('{val}', $val)
        }
        else {
            # ビットレート
            $val = Read-Host "ビットレートを入力 (例: 8000k)"
            $finalOptions += $QualityPresets[$selectedQKey].Replace('{val}', $val)
        }
    }
    else {
        $finalOptions += $QualityPresets[$selectedQKey]
    }

    # --- 2. プリセット/速度設定 ---
    if ($PresetOptions) {
        $pChoices = @($PresetOptions.Keys)
        $pIndex = Show-Menu -Title "プリセット/速度を選択してください。" -Choices $pChoices
        if ($pIndex -lt 0) { return $null }
        $finalOptions += $PresetOptions[($pChoices[$pIndex])]
    }

    # --- 3. チューニング設定 ---
    if ($TuneOptions) {
        $tChoices = @($TuneOptions.Keys)
        $tIndex = Show-Menu -Title "チューニングを選択してください。" -Choices $tChoices
        if ($tIndex -lt 0) { return $null }
        $finalOptions += $TuneOptions[($tChoices[$tIndex])]
    }

    return $finalOptions -join ' '
}

function Select-FlacOptions {
    $flacChoices = @("高圧縮 (圧縮レベル12)", "標準 (圧縮レベル8)", "高速 (圧縮レベル5)", "カスタム")
    $flacLevels = @(12, 8, 5)
    $flacIndex = Show-Menu -Title "FLACの圧縮レベルを選択" -Choices $flacChoices
    if ($flacIndex -lt 0) { return $null }

    $level = if ($flacIndex -eq 3) { [int](Read-Host "圧縮レベルを入力 (0 ~ 12)") } else { $flacLevels[$flacIndex] }
    return @{ Type = "internal"; Options = "-c:a flac -compression_level $level"; Description = "FLAC: 圧縮レベル $level" }
}


# --- メイン処理 ---
function Get-EncoderSettings {
    $hwInfo = $global:HardwareInfo

    # --- 1. 音声コーデック選択 (利用可能なもののみ表示) ---
    $audioMenuTitle = "--- 音声エンコード設定 ---"

    # 外部エンコーダーの存在チェック
    $hasQaac = $false; $hasNero = $false; $hasFdkaac = $false
    if (Get-Command -Name 'Get-ExternalEncoderAvailability' -CommandType Function -ErrorAction SilentlyContinue) {
        $extEnc = Get-ExternalEncoderAvailability
        $hasQaac = $extEnc.HasQaac; $hasNero = $extEnc.HasNero; $hasFdkaac = $extEnc.HasFdkaac
    }
    elseif ($global:Settings) {
        if ($global:Settings.QaacPath) { try { $null = Get-Command $global:Settings.QaacPath -ErrorAction Stop; $hasQaac = $true } catch {} }
        if ($global:Settings.NeroAacEncPath) { try { $null = Get-Command $global:Settings.NeroAacEncPath -ErrorAction Stop; $hasNero = $true } catch {} }
        if ($global:Settings.FdkaacPath) { try { $null = Get-Command $global:Settings.FdkaacPath -ErrorAction Stop; $hasFdkaac = $true } catch {} }
    }

    # 動的メニュー構築
    $audioMenu = @()
    $audioMenu += @{ Key = "copy"; Label = "音声をコピー (-c:a copy)" }
    $audioMenu += @{ Key = "none"; Label = "音声なし (-an)" }
    if ($hasQaac) { $audioMenu += @{ Key = "qaac"; Label = "qaac (AAC 自動HE/LC)" } }
    if ($hasNero) { $audioMenu += @{ Key = "nero"; Label = "Nero AAC (外部 自動HE/LC)" } }
    if ($hasFdkaac) { $audioMenu += @{ Key = "fdkaac"; Label = "fdkaac (外部 自動HE/LC)" } }
    $audioMenu += @{ Key = "opus"; Label = "Opus (libopus)" }
    $audioMenu += @{ Key = "vorbis"; Label = "Vorbis (libvorbis)" }
    $audioMenu += @{ Key = "flac"; Label = "FLAC (flac)" }

    # ハードウェア/API 音声エンコーダーの追加（フォールバック付き）
    if ($hwInfo -and $hwInfo.AvailableEncoders) {
        foreach ($enc in $hwInfo.AvailableEncoders) {
            if ($enc -match "^(aac|ac3|mp3|flac|opus|vorbis)_(mf|amf|nvenc|qsv|d3d12va|vulkan)$") {
                $audioMenu += @{ Key = $enc; Label = "$enc (ハードウェア/OS API)" }
            }
        }
    }
    else {
        # スキャン情報がない場合は代表的なものをすべて表示するのじゃ！
        $audioMenu += @{ Key = "aac_mf"; Label = "aac_mf (MediaFoundation)" }
        $audioMenu += @{ Key = "ac3_mf"; Label = "ac3_mf (MediaFoundation)" }
        $audioMenu += @{ Key = "mp3_mf"; Label = "mp3_mf (MediaFoundation)" }
        $audioMenu += @{ Key = "aac_amf"; Label = "aac_amf (AMD AMF)" }
    }

    $audioChoices = @($audioMenu | ForEach-Object { $_.Label })
    $audioIndex = Show-Menu -Title $audioMenuTitle -Choices $audioChoices
    if ($audioIndex -lt 0) { return $null }
    $selectedAudioKey = $audioMenu[$audioIndex].Key

    $audioSetting = @{ Type = "copy"; Options = "-c:a copy"; Description = "音声をコピー (-c:a copy)" }
    switch ($selectedAudioKey) {
        "copy" {
            # デフォルト値を使用するため何もしない
        }
        "none" {
            $audioSetting.Type = "none"
            $audioSetting.Options = "-an"
            $audioSetting.Description = "音声なし (-an)"
        }
        "qaac" {
            $result = Select-QaacOptions; if (-not $result) { return $null }
            $audioSetting = $result
        }
        "nero" {
            $result = Select-NeroOptions; if (-not $result) { return $null }
            $audioSetting = $result
        }
        "fdkaac" {
            $result = Select-FdkaacOptions; if (-not $result) { return $null }
            $audioSetting = $result
        }
        "opus" {
            $result = Select-OpusOptions; if (-not $result) { return $null }
            $audioSetting = $result
        }
        "flac" {
            $result = Select-FlacOptions; if (-not $result) { return $null }
            $audioSetting = $result
        }
        "vorbis" {
            $vorbisChoices = @("高品質 (q:a 6)", "標準品質 (q:a 4)", "カスタム")
            $vorbisIndex = Show-Menu -Title "Vorbisの品質を選択" -Choices $vorbisChoices
            if ($vorbisIndex -lt 0) { return $null }
            $audioSetting.Type = "internal"
            if ($vorbisIndex -eq 2) {
                $qVal = Read-Host "品質値を入力 (-1 ~ 10)"
                $audioSetting.Options = "-c:a libvorbis -q:a $qVal"
                $audioSetting.Description = "Vorbis: カスタム品質 (q:a $qVal)"
            }
            else {
                $audioSetting.Options = "-c:a libvorbis " + @("-q:a 6", "-q:a 4")[$vorbisIndex]
                $audioSetting.Description = "Vorbis: $($vorbisChoices[$vorbisIndex])"
            }
        }
        default {
            if ($selectedAudioKey -match "_") {
                $brChoices = @("320k", "256k", "192k", "128k", "96k", "カスタム")
                $brIndex = Show-Menu -Title "$selectedAudioKey のビットレートを選択" -Choices $brChoices
                if ($brIndex -lt 0) { return $null }
                if ($brIndex -eq 5) {
                    $brVal = Read-Host "ビットレートを入力 (例: 128k)"
                }
                else {
                    $brVal = $brChoices[$brIndex]
                }
                $audioSetting = @{ Type = "internal"; Options = "-c:a $selectedAudioKey -b:a $brVal"; Description = "$($selectedAudioKey): $brVal" }
            }
        }
    }

    # --- 2. 映像ハードウェア選択 (対応HWのみ表示/情報がなければすべて) ---
    $hwMenuTitle = "--- 映像エンコードに使用するハードウェア ---"
    $allHwChoices = @("NVIDIA (NVENC)", "Intel (QSV)", "AMD (AMF)", "Vulkan", "D3D12VA", "MediaFoundation (MF)", "CPU (Software)")
    $allHwKeys = @("NVIDIA", "Intel", "AMD", "Vulkan", "D3D12VA", "MF", "CPU")
    $hwChoices = @(); $hwKeys = @()
    for ($i = 0; $i -lt $allHwChoices.Length; $i++) {
        $show = $true
        if ($hwInfo) {
            switch ($allHwKeys[$i]) {
                "NVIDIA" { $show = $hwInfo.HasNvidia }
                "Intel" { $show = $hwInfo.HasIntel }
                "AMD" { $show = $hwInfo.HasAMD }
                "Vulkan" { $show = $hwInfo.HasVulkan }
                "D3D12VA" { $show = $hwInfo.HasD3D12VA }
                "MF" { $show = $hwInfo.HasMF }
                "CPU" { $show = $true }
            }
        }
        if ($show) { $hwChoices += $allHwChoices[$i]; $hwKeys += $allHwKeys[$i] }
    }
    $hwIndex = Show-Menu -Title $hwMenuTitle -Choices $hwChoices
    if ($hwIndex -lt 0) { return $null }
    $selectedHW = $hwKeys[$hwIndex]

    $videoSetting = ""
    if ($selectedHW -in @("NVIDIA", "Intel", "AMD", "Vulkan", "D3D12VA", "MF")) {
        $suffix = switch ($selectedHW) {
            "NVIDIA" { "_nvenc" }
            "Intel" { "_qsv" }
            "AMD" { "_amf" }
            "Vulkan" { "_vulkan" }
            "D3D12VA" { "_d3d12va" }
            "MF" { "_mf" }
        }
        
        $codecChoices = @()
        $codecMap = @()
        
        if ($hwInfo -and $hwInfo.AvailableEncoders) {
            foreach ($enc in $hwInfo.AvailableEncoders) {
                # 音声エンコーダーを除外
                if ($enc -like "*$suffix" -and $enc -notmatch "^(aac|ac3|mp3|flac|opus|vorbis|alac)_") {
                    $codecName = ($enc -replace $suffix, "").ToUpper()
                    if ($codecName -eq "HEVC") { $codecName = "H.265/HEVC" }
                    if ($codecName -eq "H264") { $codecName = "H.264/AVC" }
                    
                    $codecChoices += $codecName
                    $codecMap += $enc
                }
            }
        }
        else {
            # スキャン情報がない場合のフォールバックじゃ！
            switch ($selectedHW) {
                "NVIDIA" {
                    $codecChoices = @("H.264/AVC", "H.265/HEVC", "AV1")
                    $codecMap = @("h264_nvenc", "hevc_nvenc", "av1_nvenc")
                }
                "Intel" {
                    $codecChoices = @("H.264/AVC", "H.265/HEVC", "VP9", "AV1", "MJPEG")
                    $codecMap = @("h264_qsv", "hevc_qsv", "vp9_qsv", "av1_qsv", "mjpeg_qsv")
                }
                "AMD" {
                    $codecChoices = @("H.264/AVC", "H.265/HEVC", "AV1")
                    $codecMap = @("h264_amf", "hevc_amf", "av1_amf")
                }
                "Vulkan" {
                    $codecChoices = @("H.264/AVC", "H.265/HEVC", "AV1")
                    $codecMap = @("h264_vulkan", "hevc_vulkan", "av1_vulkan")
                }
                "D3D12VA" {
                    $codecChoices = @("H.264/AVC", "H.265/HEVC", "AV1")
                    $codecMap = @("h264_d3d12va", "hevc_d3d12va", "av1_d3d12va")
                }
                "MF" {
                    $codecChoices = @("H.264/AVC", "H.265/HEVC", "AV1")
                    $codecMap = @("h264_mf", "hevc_mf", "av1_mf")
                }
            }
        }

        if ($codecChoices.Count -eq 0) { Write-Host "利用可能な $selectedHW コーデックがありません。" -ForegroundColor Red; return $null }
        $codecIndex = Show-Menu -Title "$selectedHW コーデックを選択" -Choices $codecChoices; if ($codecIndex -lt 0) { return $null }
        $baseEncoder = "-c:v $($codecMap[$codecIndex])"
        
        if ($selectedHW -eq "NVIDIA") {
            $qPresets = [ordered]@{ "高品質 (CQ:23)" = "-rc vbr -cq 23"; "中品質 (CQ:28)" = "-rc vbr -cq 28"; "高速 (CQ:32)" = "-rc vbr -cq 32"; "カスタム品質 (CQ)" = "-rc vbr -cq {val}"; "カスタムビットレート" = "-rc vbr -b:v {val}" }
            $pPresets = [ordered]@{ "P1 (最速)" = "-preset p1"; "P2" = "-preset p2"; "P3" = "-preset p3"; "P4 (標準)" = "-preset p4"; "P5" = "-preset p5"; "P6" = "-preset p6"; "P7 (最高品質)" = "-preset p7" }
            $tPresets = [ordered]@{ "HQ (高品質)" = "-tune hq"; "LL (低遅延)" = "-tune ll"; "ULL (超低遅延)" = "-tune ull" }
            $videoSetting = Get-DetailedVideoOption -BaseEncoder $baseEncoder -QualityPresets $qPresets -PresetOptions $pPresets -TuneOptions $tPresets
        }
        elseif ($selectedHW -eq "Intel") {
            if ($codecMap[$codecIndex] -eq "vp9_qsv") {
                $qPresets = [ordered]@{ "高品質 (Q:25)" = "-q:v 25"; "中品質 (Q:30)" = "-q:v 30"; "低品質 (Q:40)" = "-q:v 40"; "カスタム品質 (Q)" = "-q:v {val}"; "カスタムビットレート" = "-b:v {val}" }
            }
            elseif ($codecMap[$codecIndex] -eq "mjpeg_qsv") {
                $qPresets = [ordered]@{ "高品質 (Q:5)" = "-q:v 5"; "標準品質 (Q:10)" = "-q:v 10"; "カスタム品質 (Q)" = "-q:v {val}" }
            }
            else {
                $qPresets = [ordered]@{ "高品質 (GQ:20)" = "-global_quality 20"; "中品質 (GQ:25)" = "-global_quality 25"; "低品質 (GQ:30)" = "-global_quality 30"; "カスタム品質 (GQ)" = "-global_quality {val}"; "カスタムビットレート" = "-b:v {val}" }
            }
            $pPresets = [ordered]@{ "veryslow (最高品質)" = "-preset veryslow"; "slower" = "-preset slower"; "slow" = "-preset slow"; "medium (標準)" = "-preset medium"; "fast" = "-preset fast"; "faster" = "-preset faster"; "veryfast (最速)" = "-preset veryfast" }
            $videoSetting = Get-DetailedVideoOption -BaseEncoder $baseEncoder -QualityPresets $qPresets -PresetOptions $pPresets
        }
        elseif ($selectedHW -eq "AMD") {
            $qPresets = [ordered]@{ "高品質 (QP:22)" = "-rc cqp -qp_i 22 -qp_p 22 -qp_b 22"; "中品質 (QP:28)" = "-rc cqp -qp_i 28 -qp_p 28 -qp_b 28"; "低品質 (QP:35)" = "-rc cqp -qp_i 35 -qp_p 35 -qp_b 35"; "カスタム品質 (QP)" = "-rc cqp -qp_i {val} -qp_p {val} -qp_b {val}"; "カスタムビットレート" = "-rc vbr_peak -b:v {val}" }
            $pPresets = [ordered]@{ "Quality (高品質)" = "-quality quality"; "Balanced (標準)" = "-quality balanced"; "Speed (速度優先)" = "-quality speed" }
            $videoSetting = Get-DetailedVideoOption -BaseEncoder $baseEncoder -QualityPresets $qPresets -PresetOptions $pPresets
        }
        else {
            # Vulkan, D3D12VA, MF など
            $qPresets = [ordered]@{ "高品質" = "-b:v 8000k"; "標準品質" = "-b:v 4000k"; "カスタムビットレート" = "-b:v {val}" }
            $videoSetting = Get-DetailedVideoOption -BaseEncoder $baseEncoder -QualityPresets $qPresets
        }
    }
    elseif ($selectedHW -eq "CPU") {
        # CPU
        $codecChoices = @("H.265/HEVC (libx265)", "H.264/AVC (libx264)", "AV1 (libsvtav1) ※高速", "AV1 (libaom-av1) ※高品質・非常に低速", "AV1 (rav1e) ※中速", "VP9 (libvpx-vp9)", "VP8 (libvpx)")
        $codecIndex = Show-Menu -Title "CPUコーデックを選択" -Choices $codecChoices; if ($codecIndex -lt 0) { return $null }
        $codecName = $codecChoices[$codecIndex]
        $baseEncoder = "-c:v $($codecName.Split(' ')[1].Trim('()'))"

        if ($codecName -match "H.26") {
            $qPresets = [ordered]@{ "高品質 (CRF:18)" = "-crf 18"; "中品質 (CRF:23)" = "-crf 23"; "低品質 (CRF:28)" = "-crf 28"; "カスタム品質 (CRF)" = "-crf {val}" }
            $pPresets = [ordered]@{ "placebo (非推奨)" = "-preset placebo"; "veryslow" = "-preset veryslow"; "slower" = "-preset slower"; "slow" = "-preset slow"; "medium (標準)" = "-preset medium"; "fast" = "-preset fast"; "faster" = "-preset faster"; "superfast" = "-preset superfast"; "ultrafast (最速)" = "-preset ultrafast" }
            $videoSetting = Get-DetailedVideoOption -BaseEncoder $baseEncoder -QualityPresets $qPresets -PresetOptions $pPresets
        }
        elseif ($codecName -match "VP") {
            $qPresets = [ordered]@{ "高品質 (CRF:30)" = "-crf 30 -b:v 0"; "中品質 (CRF:35)" = "-crf 35 -b:v 0"; "カスタム品質 (CRF)" = "-crf {val} -b:v 0" }
            $pPresets = [ordered]@{ "0 (最高品質 / 非常に遅い)" = "-cpu-used 0"; "1 (高品質)" = "-cpu-used 1"; "2" = "-cpu-used 2"; "3 (バランス型)" = "-cpu-used 3"; "4 (標準)" = "-cpu-used 4"; "5 (やや速い)" = "-cpu-used 5"; "6 (速い)" = "-cpu-used 6"; "7 (かなり速い)" = "-cpu-used 7"; "8 (最速 / 品質低下)" = "-cpu-used 8" }
            $videoSetting = Get-DetailedVideoOption -BaseEncoder $baseEncoder -QualityPresets $qPresets -PresetOptions $pPresets
        }
        elseif ($codecName -match "AV1") {
            if ($codecName -match "svt") {
                # libsvtav1: 高速AV1エンコーダー (自動マルチスレッド)
                $qPresets = [ordered]@{ "高品質 (CRF:20)" = "-crf 20"; "中品質 (CRF:30)" = "-crf 30"; "カスタム品質 (CRF)" = "-crf {val}" }
                $pPresets = [ordered]@{ "0 (最高品質 / 非常に遅い)" = "-preset 0"; "2 (高品質寄り)" = "-preset 2"; "4 (標準)" = "-preset 4"; "6 (速い)" = "-preset 6"; "8 (かなり速い)" = "-preset 8"; "10 (最速寄り)" = "-preset 10"; "13 (最速 / 品質低下)" = "-preset 13" }
                $videoSetting = Get-DetailedVideoOption -BaseEncoder $baseEncoder -QualityPresets $qPresets -PresetOptions $pPresets
            }
            elseif ($codecName -match "aom") {
                # libaom-av1: リファレンス実装 (高品質だが非常に低速)
                Write-Host "`n  ⚠ 警告: libaom-av1は非常に低速です。" -ForegroundColor Yellow
                Write-Host "  エンコード時間がlibsvtav1の10倍以上かかる場合があります。" -ForegroundColor Yellow
                Write-Host "  品質を最優先する場合にのみ推奨します。`n" -ForegroundColor Yellow
                Read-Host "  Enterキーで続行"
                # マルチスレッド設定: 行ベース並列化 + タイル分割
                $baseEncoder += " -row-mt 1 -tiles 2x2"
                $qPresets = [ordered]@{ "高品質 (CRF:20)" = "-crf 20 -b:v 0"; "中品質 (CRF:30)" = "-crf 30 -b:v 0"; "カスタム品質 (CRF)" = "-crf {val} -b:v 0" }
                $pPresets = [ordered]@{ "0 (最高品質 / 極めて遅い)" = "-cpu-used 0"; "1 (高品質 / 非常に遅い)" = "-cpu-used 1"; "2 (高品質寄り / 遅い)" = "-cpu-used 2"; "3 (バランス型)" = "-cpu-used 3"; "4 (標準)" = "-cpu-used 4"; "5 (やや速い)" = "-cpu-used 5"; "6 (速い)" = "-cpu-used 6"; "8 (最速 / 品質低下)" = "-cpu-used 8" }
                $videoSetting = Get-DetailedVideoOption -BaseEncoder $baseEncoder -QualityPresets $qPresets -PresetOptions $pPresets
            }
            elseif ($codecName -match "rav1e") {
                # rav1e: Rust製AV1エンコーダー (中速)
                Write-Host "`n  ℹ rav1eはlibsvtav1より低速ですが、libaom-av1よりは高速です。" -ForegroundColor Cyan
                Write-Host "  品質指定はQP (Quantizer Parameter: 0-255) を使用します。`n" -ForegroundColor Cyan
                # マルチスレッド設定: タイル分割
                $baseEncoder += " -tiles 4"
                $qPresets = [ordered]@{ "高品質 (QP:80)" = "-qp 80"; "中品質 (QP:120)" = "-qp 120"; "低品質 (QP:160)" = "-qp 160"; "カスタム品質 (QP 0-255)" = "-qp {val}" }
                $pPresets = [ordered]@{ "0 (最高品質 / 非常に遅い)" = "-speed 0"; "2 (高品質寄り)" = "-speed 2"; "4 (バランス型)" = "-speed 4"; "6 (標準)" = "-speed 6"; "8 (速い)" = "-speed 8"; "10 (最速 / 品質低下)" = "-speed 10" }
                $videoSetting = Get-DetailedVideoOption -BaseEncoder $baseEncoder -QualityPresets $qPresets -PresetOptions $pPresets
            }
        }
    }

    if (-not $videoSetting) { return $null } # 途中でキャンセルされた場合

    Clear-Host
    Write-Host "--- 最終確認 ---"
    Write-Host "映像: $videoSetting"
    Write-Host "音声: $($audioSetting.Description)"
    $confirm = Show-Menu -Title "この設定でよろしいですか？" -Choices @("はい", "いいえ、やり直します")
    if ($confirm -eq 1) { return Get-EncoderSettings }

    return @{ Video = $videoSetting; Audio = $audioSetting.Options; AudioType = $audioSetting.Type }
}

function Get-IntermediateSettings {
    $hwInfo = $global:HardwareInfo

    # --- 1. コーデック選択 ---
    $codecChoices = @("H.265/HEVC (libx265)", "H.264/AVC (libx264)"); $codecMap = @("-c:v libx265", "-c:v libx264")
    $codecIndex = Show-Menu -Title "中間ファイル用コーデックを選択" -Choices $codecChoices; if ($codecIndex -lt 0) { return $null }
    $baseEncoder = $codecMap[$codecIndex]

    # --- 2. ピクセルフォーマット選択 ---
    $pixFmtChoices = @("yuv444p (最高画質)", "yuv422p (高画質)", "yuv420p (標準)"); $pixFmtMap = @("-pix_fmt yuv444p", "-pix_fmt yuv422p", "-pix_fmt yuv420p")
    $pixFmtIndex = Show-Menu -Title "ピクセルフォーマットを選択" -Choices $pixFmtChoices; if ($pixFmtIndex -lt 0) { return $null }
    $pixFmtOption = $pixFmtMap[$pixFmtIndex]

    # --- 3. 品質 (CRF) 選択 ---
    $crfChoices = @("可逆圧縮 (CRF 0)", "ほぼ無劣化 (CRF 5)", "非常に高画質 (CRF 10)", "高画質 (CRF 15)", "カスタム")
    $crfMap = @("-crf 0", "-crf 5", "-crf 10", "-crf 15")
    $crfIndex = Show-Menu -Title "品質(CRF値)を選択" -Choices $crfChoices; if ($crfIndex -lt 0) { return $null }
    $crfOption = ""
    if ($crfIndex -lt 4) { $crfOption = $crfMap[$crfIndex] } else { $val = Read-Host "カスタムCRF値を入力 (0-51)"; $crfOption = "-crf $val" }

    # --- 4. プリセット選択 ---
    $pPresets = [ordered]@{ "veryslow (最高品質)" = "-preset veryslow"; "slower" = "-preset slower"; "slow" = "-preset slow"; "medium (標準)" = "-preset medium"; "fast" = "-preset fast"; "faster" = "-preset faster"; "superfast" = "-preset superfast"; "ultrafast (最速)" = "-preset ultrafast" }
    $pChoices = @($pPresets.Keys)
    $pIndex = Show-Menu -Title "エンコード速度のプリセットを選択" -Choices $pChoices; if ($pIndex -lt 0) { return $null }
    $presetOption = $pPresets[$pChoices[$pIndex]]

    $videoSetting = "$baseEncoder $pixFmtOption $crfOption $presetOption"

    # --- 5. 音声設定 ---
    $hasQaac = $false; $hasNero = $false; $hasFdkaac = $false
    if (Get-Command -Name 'Get-ExternalEncoderAvailability' -CommandType Function -ErrorAction SilentlyContinue) {
        $extEnc = Get-ExternalEncoderAvailability
        $hasQaac = $extEnc.HasQaac; $hasNero = $extEnc.HasNero; $hasFdkaac = $extEnc.HasFdkaac
    }
    elseif ($global:Settings) {
        if ($global:Settings.QaacPath) { try { $null = Get-Command $global:Settings.QaacPath -ErrorAction Stop; $hasQaac = $true } catch {} }
        if ($global:Settings.NeroAacEncPath) { try { $null = Get-Command $global:Settings.NeroAacEncPath -ErrorAction Stop; $hasNero = $true } catch {} }
        if ($global:Settings.FdkaacPath) { try { $null = Get-Command $global:Settings.FdkaacPath -ErrorAction Stop; $hasFdkaac = $true } catch {} }
    }

    $audioMenu = @()
    $audioMenu += @{ Key = "copy"; Label = "音声をコピー (-c:a copy)" }
    $audioMenu += @{ Key = "none"; Label = "音声なし (-an)" }
    if ($hasQaac) { $audioMenu += @{ Key = "qaac"; Label = "qaac (AAC 自動HE/LC)" } }
    if ($hasNero) { $audioMenu += @{ Key = "nero"; Label = "Nero AAC (外部 自動HE/LC)" } }
    if ($hasFdkaac) { $audioMenu += @{ Key = "fdkaac"; Label = "fdkaac (外部 自動HE/LC)" } }
    $audioMenu += @{ Key = "opus"; Label = "Opus (libopus)" }
    $audioMenu += @{ Key = "vorbis"; Label = "Vorbis (libvorbis)" }
    $audioMenu += @{ Key = "flac"; Label = "FLAC (flac)" }

    if ($hwInfo -and $hwInfo.AvailableEncoders) {
        foreach ($enc in $hwInfo.AvailableEncoders) {
            if ($enc -match "^(aac|ac3|mp3|flac|opus|vorbis)_(mf|amf|nvenc|qsv|d3d12va|vulkan)$") {
                $audioMenu += @{ Key = $enc; Label = "$enc (ハードウェア/OS API)" }
            }
        }
    }
    else {
        $audioMenu += @{ Key = "aac_mf"; Label = "aac_mf (MediaFoundation)" }
        $audioMenu += @{ Key = "ac3_mf"; Label = "ac3_mf (MediaFoundation)" }
    }

    $audioChoices = @($audioMenu | ForEach-Object { $_.Label })
    $audioIndex = Show-Menu -Title "中間ファイル用の音声エンコーダーを選択" -Choices $audioChoices
    if ($audioIndex -lt 0) { return $null }

    $audioSetting = @{ Type = "copy"; Options = "-c:a copy"; Description = "音声をコピー (-c:a copy)" }
    switch ($audioMenu[$audioIndex].Key) {
        "copy" {
            # デフォルト値を使用するため何もしない
        }
        "none" {
            $audioSetting = @{ Type = "none"; Options = "-an"; Description = "音声なし (-an)" }
        }
        "qaac" {
            $result = Select-QaacOptions; if (-not $result) { return $null }
            $audioSetting = $result
        }
        "nero" {
            $result = Select-NeroOptions; if (-not $result) { return $null }
            $audioSetting = $result
        }
        "fdkaac" {
            $result = Select-FdkaacOptions; if (-not $result) { return $null }
            $audioSetting = $result
        }
        "opus" {
            $result = Select-OpusOptions; if (-not $result) { return $null }
            $audioSetting = $result
        }
        "vorbis" {
            $vorbisChoices = @("高品質 (q:a 6)", "標準品質 (q:a 4)", "カスタム")
            $vorbisIndex = Show-Menu -Title "Vorbisの品質を選択" -Choices $vorbisChoices
            if ($vorbisIndex -lt 0) { return $null }
            if ($vorbisIndex -eq 2) {
                $qVal = Read-Host "品質値を入力 (-1 ~ 10)"
                $audioSetting = @{ Type = "internal"; Options = "-c:a libvorbis -q:a $qVal"; Description = "Vorbis: カスタム品質 (q:a $qVal)" }
            }
            else {
                $qOpt = @("-q:a 6", "-q:a 4")[$vorbisIndex]
                $audioSetting = @{ Type = "internal"; Options = "-c:a libvorbis $qOpt"; Description = "Vorbis: $($vorbisChoices[$vorbisIndex])" }
            }
        }
        "flac" {
            $result = Select-FlacOptions; if (-not $result) { return $null }
            $audioSetting = $result
        }
        default {
            $selectedAudioKey = $audioMenu[$audioIndex].Key
            if ($selectedAudioKey -match "_") {
                $brChoices = @("320k", "256k", "192k", "128k", "96k", "カスタム")
                $brIndex = Show-Menu -Title "$selectedAudioKey のビットレートを選択" -Choices $brChoices
                if ($brIndex -lt 0) { return $null }
                if ($brIndex -eq 5) {
                    $brVal = Read-Host "ビットレートを入力 (例: 128k)"
                }
                else {
                    $brVal = $brChoices[$brIndex]
                }
                $audioSetting = @{ Type = "internal"; Options = "-c:a $selectedAudioKey -b:a $brVal"; Description = "$($selectedAudioKey): $brVal" }
            }
        }
    }

    Clear-Host
    Write-Host "--- 最終確認 ---"
    Write-Host "映像: $videoSetting"
    Write-Host "音声: $($audioSetting.Description)"
    $confirm = Show-Menu -Title "この設定でよろしいですか？" -Choices @("はい", "いいえ、やり直します")
    if ($confirm -eq 1) { return Get-IntermediateSettings }

    return @{ Video = $videoSetting; Audio = $audioSetting.Options; AudioType = $audioSetting.Type }
}

# --- スクリプトのエントリーポイント ---
if ($Intermediate.IsPresent) {
    return Get-IntermediateSettings
}
else {
    return Get-EncoderSettings
}