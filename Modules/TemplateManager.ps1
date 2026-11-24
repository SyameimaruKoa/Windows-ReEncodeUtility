#requires -Version 5.1
if (-not (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue)) {
    $global:IsWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    $global:IsLinux = -not $global:IsWindows
    $global:IsMacOS = $false
}
#region 共通テンプレート
function Get-SettingsTemplate {
    param([ValidateSet('Encoding', 'Filter')][string]$Kind)
    $folder = if ($Kind -eq 'Encoding') { $global:Settings.EncodingTemplateDir } else { $global:Settings.FilterTemplateDir }
    $templates = @(Get-ChildItem -LiteralPath $folder -Filter '*.psd1' -File | Sort-Object Name)
    if ($templates.Count -eq 0) {
        Write-Host "利用可能なテンプレートがありません: $Kind" -ForegroundColor Yellow
        return $null
    }
    $index = Show-Menu -Title "$Kind テンプレートを選択してください。" -Choices @($templates | ForEach-Object { $_.BaseName })
    if ($index -lt 0) { return $null }
    try {
        $template = Import-Clixml -LiteralPath $templates[$index].FullName -ErrorAction Stop
        if (-not ($template -is [hashtable]) -or $template.TemplateType -ne $Kind) {
            throw "テンプレート種別が一致しません。"
        }
        if ($Kind -eq 'Encoding' -and (-not ($template.EncoderSettings -is [hashtable]) -or -not $template.EncoderSettings.Video)) {
            throw "映像エンコード設定がありません。"
        }
        if ($Kind -eq 'Filter' -and -not $template.ContainsKey('AdditionalVF')) {
            throw "映像フィルター設定がありません。"
        }
        Write-Log "テンプレート読込: $($templates[$index].FullName)"
        return $template
    }
    catch {
        Write-Log "テンプレートの読込失敗: $_" -Level 'ERROR'
        return $null
    }
}

function Select-EncoderProfile {
    param([switch]$Intermediate)
    $existing = @(Get-ChildItem -LiteralPath $global:Settings.EncodingTemplateDir -Filter '*.psd1' -File)
    if ($existing.Count -gt 0) {
        $choice = Show-Menu -Title 'エンコード設定を選択してください。' -Choices @(
            '対話形式で新規設定する',
            'エンコードテンプレートから読み込む'
        )
        if ($choice -lt 0) { return $null }
        if ($choice -eq 1) {
            $preset = Get-SettingsTemplate -Kind Encoding
            if (-not $preset) { return $null }
            return $preset.EncoderSettings
        }
    }
    if ($Intermediate) { return (. $optionsScriptPath -Intermediate -HwScanMode On) }
    return (. $optionsScriptPath -HwScanMode On)
}

function Save-SettingsTemplate {
    param([ValidateSet('Encoding', 'Filter', 'Legacy')][string]$Kind, [hashtable]$Config)
    $folder = switch ($Kind) {
        'Encoding' { $global:Settings.EncodingTemplateDir }
        'Filter'   { $global:Settings.FilterTemplateDir }
        default    { $global:Settings.TemplateDir }
    }
    $name = (Read-Host '保存するテンプレート名（空欄でキャンセル）').Trim()
    if (-not $name) { return }
    if ($name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $name -in @('.', '..')) {
        Write-Host 'テンプレート名に使えない文字が含まれています。' -ForegroundColor Yellow
        return
    }
    $target = Join-Path $folder "$name.psd1"
    if (Test-Path -LiteralPath $target) {
        $overwrite = Show-Menu -Title '同名テンプレートが存在します。' -Choices @('上書きしない', '上書きする')
        if ($overwrite -ne 1) { return }
    }
    switch ($Kind) {
        'Encoding' {
            if (-not $Config.EncoderSettings -or -not $Config.EncoderSettings.Video) {
                Write-Host 'エンコード設定がありません。' -ForegroundColor Yellow
                return
            }
            $data = @{ TemplateType = 'Encoding'; EncoderSettings = $Config.EncoderSettings }
        }
        'Filter' {
            $filterArgs = ''
            if ($Config.AdditionalArgs) {
                $choice = Show-Menu -Title '追加のFFmpeg引数もフィルターテンプレートに含めますか？' -Choices @(
                    '含めない（-vfのみ保存）',
                    '含める（-filter_complexなども保存）'
                )
                if ($choice -lt 0) { return }
                if ($choice -eq 1) { $filterArgs = [string]$Config.AdditionalArgs }
            }
            $data = @{
                TemplateType = 'Filter'
                AdditionalVF = [string]$Config.AdditionalVF
                AdditionalArgs = $filterArgs
            }
        }
        default {
            $data = $Config
        }
    }
    $data | Export-Clixml -LiteralPath $target -Encoding UTF8
    Write-Log "テンプレート保存: $target"
}

function Use-FilterTemplate {
    param([hashtable]$Config)
    $preset = Get-SettingsTemplate -Kind Filter
    if (-not $preset) { return }
    $incomingVF = [string]$preset.AdditionalVF
    $incomingArgs = [string]$preset.AdditionalArgs
    if (-not $incomingVF -and -not $incomingArgs) {
        Write-Host 'フィルターが空です。' -ForegroundColor Yellow
        return
    }
    $oldVF = [string]$Config.AdditionalVF
    $oldArgs = [string]$Config.AdditionalArgs
    $oldComplex = ($oldArgs -match '(?:^|\s)-filter_complex\b')
    $incomingComplex = ($incomingArgs -match '(?:^|\s)-filter_complex\b')
    $graphConflict = (($oldComplex -and $incomingVF) -or ($incomingComplex -and ($oldVF -or $oldComplex)))
    if ($graphConflict -and $Config.PlatformMode) {
        Write-Host 'プラットフォームの自動フィルターと複雑なフィルターグラフを併用できません。' -ForegroundColor Yellow
        return
    }
    $replace = $false
    if ($oldVF -or $oldArgs) {
        if ($Config.PlatformMode) {
            Write-Host 'プラットフォーム側の自動フィルターを維持して合成します。'
        }
        elseif ($graphConflict) {
            $choice = Show-Menu -Title '-vfと-filter_complexが競合します。既存フィルターを置き換えますか？' -Choices @(
                '既存フィルターを置き換える',
                'キャンセル'
            )
            if ($choice -ne 0) { return }
            $replace = $true
        }
        else {
            $choice = Show-Menu -Title '既存フィルターの扱いを選択してください。' -Choices @(
                '既存フィルターと合成する',
                '既存フィルターを置き換える',
                'キャンセル'
            )
            if ($choice -eq 2 -or $choice -lt 0) { return }
            $replace = ($choice -eq 1)
        }
    }
    if ($replace) {
        $Config.AdditionalVF = $incomingVF
        $Config.AdditionalArgs = $incomingArgs
    }
    else {
        if ($incomingVF) {
            if (-not $oldVF) { $Config.AdditionalVF = $incomingVF }
            elseif ($Config.PlatformMode) {
                $Config.AdditionalVF = "$incomingVF,$oldVF"
            }
            else {
                $Config.AdditionalVF = "$oldVF,$incomingVF"
            }
        }
        if ($incomingArgs) {
            $Config.AdditionalArgs = if ($oldArgs) { "$oldArgs $incomingArgs" } else { $incomingArgs }
        }
    }
    Write-Log "フィルターテンプレートを適用: $($Config.AdditionalVF)"
}

function Invoke-TemplateOptions {
    param([hashtable]$Config)
    while ($true) {
        $choices = @(
            'この設定で処理を開始する',
            'フィルターテンプレートを読み込む',
            'フィルターテンプレートを保存する',
            'エンコードテンプレートを保存する',
            '従来形式（一体型）のテンプレートを保存する'
        )
        if (-not $Config.PlatformMode) { $choices += 'エンコードテンプレートを読み込む' }
        $index = Show-Menu -Title "共通テンプレート設定（Escで終了 / Backspaceで一つ戻る / Deleteで最初へ）`n映像フィルター: $($Config.AdditionalVF)" -Choices $choices
        switch ($index) {
            0 { return $true }
            1 { Use-FilterTemplate -Config $Config }
            2 { Save-SettingsTemplate -Kind Filter -Config $Config }
            3 { Save-SettingsTemplate -Kind Encoding -Config $Config }
            4 { Save-SettingsTemplate -Kind Legacy -Config $Config }
            5 {
                $preset = Get-SettingsTemplate -Kind Encoding
                if ($preset) {
                    $Config.EncoderSettings = $preset.EncoderSettings
                    Write-Log 'エンコードテンプレートを適用しました。'
                }
            }
            -2 { continue } # Backspace: このメニューを再表示（設定は保持したまま）
            -3 { return $false } # Delete: 最初へ（呼び出し側がモード選択に戻す）
            -1 { return $false } # Esc: 終了
            default { return $false }
        }
    }
}
#endregion
