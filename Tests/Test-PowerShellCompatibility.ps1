<#
.SYNOPSIS
    PowerShell 5.1 / 7 両対応を静的に検証する。
.DESCRIPTION
    UTF-8 BOM、PS7 固有構文の不使用、#requires が 5.1 であること、自動変数の互換初期化を確認する。
    このスクリプト自体は PS5.1 / 7 どちらでも動く構文のみを使う。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$script:Pass = 0
$script:Fail = 0
function Assert-Ok {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:Pass++; Write-Host "  PASS: $Name" }
    else { $script:Fail++; Write-Host "  FAIL: $Name" -ForegroundColor Red }
}

$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include *.ps1, *.psm1 |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.FullName -notmatch '[\\/]\.cache[\\/]' -and $_.FullName -notmatch '[\\/]\.venv[\\/]' })

Write-Host "対象: $($files.Count) ファイル"

# 1. UTF-8 BOM（PS5.1 は BOM 無い UTF-8 を ANSI として読むため必須）
$noBom = @()
foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        $noBom += $f.FullName
    }
}
Assert-Ok -Condition ($noBom.Count -eq 0) -Name "全ファイルが UTF-8 BOM 付き ($($noBom.Count) 件が未対応)"
foreach ($p in $noBom) { Write-Host "    $p" -ForegroundColor Red }

# 2. PS7 固有構文
# パターンを分割して保持し、このファイル自身が自己検出しないようにする
$ps7Patterns = @(
    '\?\?', '\?\.', ('\$PS' + 'Style'), ('Get-' + 'Error\b'),
    'Resolve-Path\s+-RelativeBasePath', 'Sort-Object\s+-Top',
    'Get-Content\s+-AsByteStream', 'ConvertTo-Json\s+-AsArray',
    'ForEach-Object\s+-Parallel', ('::Parse' + 'Input'),
    ('Test-' + 'Json\b'), ('#requires' + '\s+-Version\s+7')
)
$ps7Hits = @()
foreach ($f in $files) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    foreach ($pat in $ps7Patterns) {
        if ($text -match $pat) { $ps7Hits += "$($f.Name): $pat" }
    }
}
Assert-Ok -Condition ($ps7Hits.Count -eq 0) -Name "PS7 固有構文なし ($($ps7Hits.Count) 件)"
foreach ($h in $ps7Hits) { Write-Host "    $h" -ForegroundColor Red }

# 3. #requires が -Version 5.1 であること
$badRequires = @()
foreach ($f in $files) {
    if ($f.Name -eq 'Test-PowerShellCompatibility.ps1') { continue }
    $text = [System.IO.File]::ReadAllText($f.FullName)
    if ($text -notmatch '(?im)^#requires\s+-Version\s+5\.1\s*$') { $badRequires += $f.Name }
}
Assert-Ok -Condition ($badRequires.Count -eq 0) -Name "全ファイルが #requires -Version 5.1 ($($badRequires.Count) 件が未対応)"
foreach ($p in $badRequires) { Write-Host "    $p" -ForegroundColor Red }

# 4. $IsWindows 等を使うファイルは互換初期化を持つこと
$missingCompat = @()
foreach ($f in $files) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    if ($text -match '\$Is(Windows|Linux|MacOS)\b' -and $text -notmatch 'Get-Variable -Name IsWindows') {
        $missingCompat += $f.Name
    }
}
Assert-Ok -Condition ($missingCompat.Count -eq 0) -Name "自動変数の互換初期化あり ($($missingCompat.Count) 件が未対応)"
foreach ($p in $missingCompat) { Write-Host "    $p" -ForegroundColor Red }

# 5. PS5.1 で動作するAST構文であること（両バージョン共通の Parser で検証）
$parseErrors = @()
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { $parseErrors += "$($f.Name): $($errors[0].Message)" }
}
Assert-Ok -Condition ($parseErrors.Count -eq 0) -Name "全ファイルが構文解析成功 ($($parseErrors.Count) 件のエラー)"
foreach ($e in $parseErrors) { Write-Host "    $e" -ForegroundColor Red }

Write-Host ""
Write-Host "結果: PASS=$($script:Pass) FAIL=$($script:Fail)"
if ($script:Fail -gt 0) { exit 1 }
