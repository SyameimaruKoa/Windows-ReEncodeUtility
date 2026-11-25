<#
.SYNOPSIS
    LosslessCut を単体で起動する。最新版の確認・取得を自動で行う。
.DESCRIPTION
    設定値・PATH 上の既存インストールを優先して使用し、見つからなければ
    最新リリースの AppImage を .cache/losslesscut に取得する。
    Windows は cmd start、Linux は利用可能なターミナルエミュレータで
    別コンソールを開きログを表示する。ログファイルは作らない。
.PARAMETER Path
    起動時に開く動画ファイル。複数指定可。省略時はファイルを開かず起動する。
.PARAMETER ForceUpdate
    取得済みの AppImage があっても最新版を再取得する。
.PARAMETER NoUpdate
    更新チェックをスキップし、取得済みの AppImage を使用する。
.EXAMPLE
    pwsh -File ./Tools/Start-LosslessCut.ps1 -h
    pwsh -File ./Tools/Start-LosslessCut.ps1 ./input.mp4
    pwsh -File ./Tools/Start-LosslessCut.ps1 -ForceUpdate ./input.mp4
#>
#requires -Version 7.0

#region パラメータ
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Path = @(),
    [switch]$ForceUpdate,
    [switch]$NoUpdate
)

if ($Path -contains '-h' -or $Path -contains '--help') {
    Get-Help -Full $PSCommandPath
    exit 0
}
#endregion

#region 初期化
$ErrorActionPreference = 'Stop'
$rootDir = Split-Path -Parent $PSScriptRoot
$global:ScriptDir = $rootDir
$global:AppCacheDir = Join-Path $rootDir '.cache'
if (-not (Test-Path -LiteralPath $global:AppCacheDir -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $global:AppCacheDir -Force
}
$configFileName = if ($IsWindows) { 'config.user.psd1' } else { 'config.user.linux.psd1' }
$configPath = Join-Path $rootDir $configFileName
if (-not (Test-Path -LiteralPath $configPath)) { $configPath = Join-Path $rootDir 'config.user.psd1' }
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Error "設定ファイルが見つかりません: $configPath"
    exit 1
}
$global:Settings = Import-PowerShellDataFile -Path $configPath
. (Join-Path $rootDir 'Modules/LosslessCut.ps1')
#endregion

#region 起動
if (-not (Start-LosslessCut -Path $Path -ForceUpdate:$ForceUpdate -NoUpdate:$NoUpdate)) {
    Write-Error 'LosslessCut を起動できませんでした。'
    exit 1
}
#endregion
