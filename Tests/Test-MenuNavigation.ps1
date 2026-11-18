<#
.SYNOPSIS
    対話メニューのキー操作（Enter / Backspace / Delete / Esc）を検証する。
    Read-MenuKey をスタブ化して実コンソール入力なしでテストする。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Get-FunctionFromAst {
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "構文エラー: $Path / $($errors[0].Message)" }
    $fn = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true) | Select-Object -First 1
    if (-not $fn) { throw "関数が見つからない: $Name" }
    return $fn.Extent.Text
}

. ([scriptblock]::Create((Get-FunctionFromAst -Path (Join-Path $root 're-encode-AIOptimus.ps1') -Name 'Read-MenuKey')))
. ([scriptblock]::Create((Get-FunctionFromAst -Path (Join-Path $root 're-encode-AIOptimus.ps1') -Name 'Show-Menu')))
. ([scriptblock]::Create((Get-FunctionFromAst -Path (Join-Path $root 'Modules\TemplateManager.ps1') -Name 'Invoke-TemplateOptions')))
. ([scriptblock]::Create((Get-FunctionFromAst -Path (Join-Path $root 're-encode-AIOptimus.ps1') -Name 'Invoke-PlatformUploadSetup')))

# 実際の HW 選択メニュー相当のサブセット（Backspace で null を返す）
function Invoke-PlatformAutoSetup {
    param([hashtable]$PlatformConfig)
    $hw = Show-Menu -Title '使用するハードウェアを選択してください。' -Choices @('Intel (QSV)','CPU (Software)')
    if ($hw -eq -2) { return $null }
    return @{ Test = $true }
}

function Write-Log { param([string]$Message, [switch]$NoTimestamp, [string]$Level = 'INFO') }
function Read-Host { param([string]$Prompt) return '' }

$script:Keys = [System.Collections.Generic.Queue[int]]::new()
function Set-TestKeys { param([int[]]$Keys) $script:Keys.Clear(); foreach ($k in $Keys) { $script:Keys.Enqueue($k) } }
$script:ReadCount = 0
function Read-MenuKey {
    if ($script:Keys.Count -eq 0) { throw 'テスト用キーが枯渇しました。' }
    $script:ReadCount++
    $vk = $script:Keys.Dequeue()
    return [pscustomobject]@{ VirtualKeyCode = $vk; Character = [char]0; KeyDown = $true }
}

$script:Pass = 0; $script:Fail = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ($Expected -eq $Actual) { $script:Pass++; "  PASS: $Name" }
    else { $script:Fail++; "  FAIL: $Name (expected=$Expected actual=$Actual)" }
}

$config = @{ AdditionalVF = 'scale=1280:-2'; PlatformMode = $true }

"== Show-Menu キー判定 =="
Set-TestKeys @(13)
Assert-Equal 0 (Show-Menu -Title 't' -Choices @('A','B') -NoClear) 'Enter は選択 index を返す'

Set-TestKeys @(8)
$global:MenuBackHandler = $true
$r = Show-Menu -Title 't' -Choices @('A','B') -NoClear
$global:MenuBackHandler = $false
Assert-Equal -2 $r '戻る先登録時: Backspace は -2'
Assert-Equal 'back' $global:MenuNav 'Backspace は MenuNav=back'

# 戻る先が未登録なら、同じメニューを再表示してキャンセルしない
Set-TestKeys @(8, 13)
$global:MenuBackHandler = $false
$r = Show-Menu -Title 't' -Choices @('A','B') -NoClear
Assert-Equal 0 $r '未登録時: Backspace は再表示されキャンセルしない'

Set-TestKeys @(46)
$r = Show-Menu -Title 't' -Choices @('A','B') -NoClear
Assert-Equal -3 $r 'Delete は -3'
Assert-Equal 'allback' $global:MenuNav 'Delete は MenuNav=allback'

Set-TestKeys @(27)
$r = Show-Menu -Title 't' -Choices @('A','B') -NoClear
Assert-Equal -1 $r 'Esc は -1'

"== 共通テンプレート設定の Backspace =="
# Backspace で再表示され、その後の Enter で開始 → false にならないこと
Set-TestKeys @(8, 13)
$global:MenuNav = ''
$result = Invoke-TemplateOptions -Config $config
Assert-Equal $true $result 'Backspace 後に Enter で開始してもキャンセルされない'

"== プラットフォーム設定: HW選択からの Backspace =="
Set-TestKeys @(13, 13, 8, 27)
$script:ReadCount = 0
$global:MenuBackHandler = $true
$global:MenuNav = ''
$result = Invoke-PlatformUploadSetup
$global:MenuBackHandler = $false
Assert-Equal $false ([bool]$result) 'HW選択でBackspace→Escでキャンセル'
Assert-Equal 4 $script:ReadCount 'キーが4回消費された（=セットアップ方法へ再表示）'

"== 共通テンプレート設定の Delete / Esc =="
Set-TestKeys @(46)
$global:MenuNav = ''
$result = Invoke-TemplateOptions -Config $config
Assert-Equal $false $result 'Delete は false を返す'
Assert-Equal 'allback' $global:MenuNav 'Delete は MenuNav=allback を維持'

Set-TestKeys @(27)
$global:MenuNav = ''
$result = Invoke-TemplateOptions -Config $config
Assert-Equal $false $result 'Esc は false を返す'

""
"結果: PASS=$($script:Pass) FAIL=$($script:Fail)"
if ($script:Fail -gt 0) { exit 1 }
