<#
.SYNOPSIS
    FFmpegのエンコードオプションを対話形式で設定するスクリプトじゃ。
.DESCRIPTION
    映像コーデック（H.264/5, AV1, VP9/8）と音声コーデック（AAC, Opus, Vorbis等）を
    ハードウェアや品質に応じて選択し、設定結果を呼び出し元のスクリプトに返すぞ。
.PARAMETER Intermediate
    このスイッチを指定すると、編集用の中間ファイルを作成するための専用メニューが表示される。
.OUTPUTS
    System.Collections.Hashtable
    選択された映像・音声のエンコード設定を含むハッシュテーブルを返す。
#>
[CmdletBinding()]
param (
    [switch]$Intermediate
)

# --- 対話メニュー関数 ---
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


# --- メイン処理 ---
function Get-EncoderSettings {
    # --- 1. 音声コーデック選択 ---
    $audioMenuTitle = "--- 音声エンコード設定 ---"
    $audioChoices = @(
        "音声をコピー (-c:a copy)", "音声なし (-an)", "qaac (外部 AAC)", "Nero AAC (外部 AAC)", "Opus (libopus)", "Vorbis (libvorbis)"
    )
    $audioIndex = Show-Menu -Title $audioMenuTitle -Choices $audioChoices
    if ($audioIndex -lt 0) { return $null }

    $audioSetting = @{ Type = "copy"; Options = "-c:a copy"; Description = "音声をコピー (-c:a copy)" }
    switch ($audioIndex) {
        0 {
            # デフォルト値を使用するため何もしない
        }
        1 {
            $audioSetting.Type = "none"
            $audioSetting.Options = "-an"
            $audioSetting.Description = "音声なし (-an)"
        }
        2 {
            # qaac
            $qaacChoices = @("AAC-LC (標準)", "HE-AAC")
            $qaacIndex = Show-Menu -Title "qaacタイプを選択" -Choices $qaacChoices
            if ($qaacIndex -lt 0) { return $null }
            $qaacType = if ($qaacIndex -eq 1) { "--he" } else { "" }
            $audioSetting.Type = "qaac"
            $audioSetting.Options = $qaacType
            $audioSetting.Description = "qaac: $($qaacChoices[$qaacIndex])"
        }
        3 {
            # Nero AAC
            $neroChoices = @("高品質 (-q 0.65)", "標準品質 (-q 0.50)", "通常品質 (-q 0.35)", "カスタム")
            $neroIndex = Show-Menu -Title "NeroAACの品質を選択" -Choices $neroChoices
            if ($neroIndex -lt 0) { return $null }
            $audioSetting.Type = "nero"
            if ($neroIndex -eq 3) {
                $qVal = Read-Host "品質値を入力 (0.0 ~ 1.0)"
                $audioSetting.Options = "-q $qVal"
                $audioSetting.Description = "Nero AAC: カスタム品質 (-q $qVal)"
            }
            else {
                $audioSetting.Options = @("-q 0.65", "-q 0.50", "-q 0.35")[$neroIndex]
                $audioSetting.Description = "Nero AAC: $($neroChoices[$neroIndex])"
            }
        }
        4 {
            # Opus
            $opusChoices = @("192 kbps", "160 kbps", "128 kbps", "カスタム")
            $opusIndex = Show-Menu -Title "Opusのビットレートを選択" -Choices $opusChoices
            if ($opusIndex -lt 0) { return $null }
            $audioSetting.Type = "internal"
            if ($opusIndex -eq 3) {
                $brVal = Read-Host "ビットレートを入力 (例: 128k)"
                $audioSetting.Options = "-c:a libopus -b:a $brVal"
                $audioSetting.Description = "Opus: カスタムビットレート ($brVal)"
            }
            else {
                $bitrate = @("192k", "160k", "128k")[$opusIndex]
                $audioSetting.Options = "-c:a libopus -b:a $bitrate"
                $audioSetting.Description = "Opus: $($opusChoices[$opusIndex])"
            }
        }
        5 {
            # Vorbis
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
    }

    # --- 2. 映像ハードウェア選択 ---
    $hwMenuTitle = "--- 映像エンコードに使用するハードウェア ---"
    $hwChoices = @("NVIDIA (NVENC)", "Intel (QSV)", "AMD (AMF)", "CPU (Software)")
    $hwIndex = Show-Menu -Title $hwMenuTitle -Choices $hwChoices
    if ($hwIndex -lt 0) { return $null }

    $videoSetting = ""
    switch ($hwIndex) {
        0 {
            # NVIDIA
            $codecChoices = @("H.265/HEVC", "H.264/AVC", "AV1", "VP9"); $codecMap = @("hevc_nvenc", "h264_nvenc", "av1_nvenc", "vp9_nvenc")
            $codecIndex = Show-Menu -Title "NVIDIAコーデックを選択" -Choices $codecChoices; if ($codecIndex -lt 0) { return $null }
            $baseEncoder = "-c:v $($codecMap[$codecIndex])"
            $qPresets = [ordered]@{ "高品質 (CQ:23)" = "-rc vbr -cq 23"; "中品質 (CQ:28)" = "-rc vbr -cq 28"; "高速 (CQ:32)" = "-rc vbr -cq 32"; "カスタム品質 (CQ)" = "-rc vbr -cq {val}"; "カスタムビットレート" = "-rc vbr -b:v {val}" }
            $pPresets = [ordered]@{ "P1 (最速)" = "-preset p1"; "P2" = "-preset p2"; "P3" = "-preset p3"; "P4 (標準)" = "-preset p4"; "P5" = "-preset p5"; "P6" = "-preset p6"; "P7 (最高品質)" = "-preset p7" }
            $tPresets = [ordered]@{ "HQ (高品質)" = "-tune hq"; "LL (低遅延)" = "-tune ll"; "ULL (超低遅延)" = "-tune ull" }
            $videoSetting = Get-DetailedVideoOption -BaseEncoder $baseEncoder -QualityPresets $qPresets -PresetOptions $pPresets -TuneOptions $tPresets
        }
        1 {
            # Intel
            $codecChoices = @("H.265/HEVC", "H.264/AVC", "AV1", "VP9"); $codecMap = @("hevc_qsv", "h264_qsv", "av1_qsv", "vp9_qsv")
            $codecIndex = Show-Menu -Title "Intelコーデックを選択" -Choices $codecChoices; if ($codecIndex -lt 0) { return $null }
            $baseEncoder = "-c:v $($codecMap[$codecIndex])"
            $qPresets = [ordered]@{ "高品質 (GQ:20)" = "-global_quality 20"; "中品質 (GQ:25)" = "-global_quality 25"; "低品質 (GQ:30)" = "-global_quality 30"; "カスタム品質 (GQ)" = "-global_quality {val}"; "カスタムビットレート" = "-b:v {val}" }
            $pPresets = [ordered]@{ "veryslow (最高品質)" = "-preset veryslow"; "slower" = "-preset slower"; "slow" = "-preset slow"; "medium (標準)" = "-preset medium"; "fast" = "-preset fast"; "faster" = "-preset faster"; "veryfast (最速)" = "-preset veryfast" }
            $videoSetting = Get-DetailedVideoOption -BaseEncoder $baseEncoder -QualityPresets $qPresets -PresetOptions $pPresets
        }
        2 {
            # AMD
            $codecChoices = @("H.265/HEVC", "H.264/AVC", "AV1"); $codecMap = @("hevc_amf", "h264_amf", "av1_amf")
            $codecIndex = Show-Menu -Title "AMDコーデックを選択" -Choices $codecChoices; if ($codecIndex -lt 0) { return $null }
            $baseEncoder = "-c:v $($codecMap[$codecIndex])"
            $qPresets = [ordered]@{ "高品質 (QP:22)" = "-rc cqp -qp_i 22 -qp_p 22 -qp_b 22"; "中品質 (QP:28)" = "-rc cqp -qp_i 28 -qp_p 28 -qp_b 28"; "低品質 (QP:35)" = "-rc cqp -qp_i 35 -qp_p 35 -qp_b 35"; "カスタム品質 (QP)" = "-rc cqp -qp_i {val} -qp_p {val} -qp_b {val}"; "カスタムビットレート" = "-rc vbr_peak -b:v {val}" }
            $pPresets = [ordered]@{ "Quality (高品質)" = "-quality quality"; "Balanced (標準)" = "-quality balanced"; "Speed (速度優先)" = "-quality speed" }
            $videoSetting = Get-DetailedVideoOption -BaseEncoder $baseEncoder -QualityPresets $qPresets -PresetOptions $pPresets
        }
        3 {
            # CPU
            $codecChoices = @("H.265/HEVC (libx265)", "H.264/AVC (libx264)", "AV1 (libsvtav1)", "AV1 (libaom-av1)", "VP9 (libvpx-vp9)", "VP8 (libvpx)")
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
                $pPresets = [ordered]@{ "0 (最高品質)" = "-cpu-used 0"; "1" = "-cpu-used 1"; "2" = "-cpu-used 2"; "3" = "-cpu-used 3"; "4 (標準)" = "-cpu-used 4"; "5" = "-cpu-used 5"; "6" = "-cpu-used 6"; "7" = "-cpu-used 7"; "8 (最速)" = "-cpu-used 8" }
                $videoSetting = Get-DetailedVideoOption -BaseEncoder $baseEncoder -QualityPresets $qPresets -PresetOptions $pPresets
            }
            elseif ($codecName -match "AV1") {
                $qPresets = [ordered]@{ "高品質 (CRF:20)" = "-crf 20 -b:v 0"; "中品質 (CRF:30)" = "-crf 30 -b:v 0"; "カスタム品質 (CRF)" = "-crf {val} -b:v 0" }
                $speedParam = if ($codecName -match "svt") { "-preset" } else { "-cpu-used" }
                $pPresets = [ordered]@{ "0 (最高品質)" = "$speedParam 0"; "1" = "$speedParam 1"; "2" = "$speedParam 2"; "3" = "$speedParam 3"; "4 (標準)" = "$speedParam 4"; "5" = "$speedParam 5"; "6" = "$speedParam 6"; "7" = "$speedParam 7"; "8 (最速)" = "$speedParam 8" }
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
    $pIndex = Show-Menu -Title "エンコード速度のプリセットを選択" -Choices @($pPresets.Keys); if ($pIndex -lt 0) { return $null }
    $presetOption = $pPresets[($pPresets.Keys)[$pIndex]]

    $videoSetting = "$baseEncoder $pixFmtOption $crfOption $presetOption"

    Clear-Host
    Write-Host "--- 最終確認 ---"
    Write-Host "映像: $videoSetting"
    Write-Host "音声: 音声コピー"
    $confirm = Show-Menu -Title "この設定でよろしいですか？" -Choices @("はい", "いいえ、やり直します")
    if ($confirm -eq 1) { return Get-IntermediateSettings }

    return @{ Video = $videoSetting; Audio = "-c:a copy"; AudioType = "copy" }
}

# --- スクリプトのエントリーポイント ---
if ($Intermediate.IsPresent) {
    return Get-IntermediateSettings
}
else {
    return Get-EncoderSettings
}