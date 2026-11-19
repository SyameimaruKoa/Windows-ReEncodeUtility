<#
.SYNOPSIS
    中間ファイル用ハードウェアエンコードの設定生成を検証する。
.DESCRIPTION
    GPUを使わず設定生成とフィルター経路を確認する。
    実際のGPUでのエンコードはアプリケーションの設定選択時に検証する。
.PARAMETER ShowHelp
    使い方を表示する。
.EXAMPLE
    pwsh -File .\Tests\Test-IntermediateHardware.ps1
#>
#requires -Version 7.0

[CmdletBinding()]
param(
    [Alias('h', 'help')]
    [switch]$ShowHelp
)
#region ヘルプ
if ($ShowHelp -or $args -contains '--help') {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    return
}
#endregion

#region 構文と設定生成
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$asts = @{}
foreach ($file in @('get-ffmpegOptions.ps1', 're-encode-AIOptimus.ps1', 'Modules/IntermediateHardware.ps1')) {
    $tokens = $null
    $parseErrors = $null
    $asts[$file] = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "$file : $($parseErrors -join '; ')" }
}
. (Join-Path $root 'Modules/IntermediateHardware.ps1')

function Assert-Options {
    param([string]$Encoder, [string[]]$Names, [bool]$ChipOnly, [string]$Expected)
    $helpText = ($Names | ForEach-Object { "  -$_ <int> E.. Option" }) -join "`n"
    $actual = @(Get-IntermediateChipOptions -Encoder $Encoder -HelpText $helpText -ChipOnly $ChipOnly) -join ' '
    if ($actual -ne $Expected) { throw "$Encoder : expected [$Expected], got [$actual]" }
}

$nvenc = @('rc-lookahead', 'spatial-aq', 'temporal-aq', 'weighted_pred', 'tf_level', 'multipass')
Assert-Options 'hevc_nvenc' $nvenc $true '-rc-lookahead 0 -spatial-aq 0 -temporal-aq 0 -weighted_pred 0 -tf_level 0 -multipass disabled'
Assert-Options 'hevc_nvenc' $nvenc $false ''
Assert-Options 'h264_nvenc' @('rc-lookahead') $true '-rc-lookahead 0'

$qsv = @('low_power', 'look_ahead', 'look_ahead_depth', 'extbrc', 'mbbrc', 'rdo')
Assert-Options 'h264_qsv' $qsv $true '-low_power 1 -look_ahead 0 -look_ahead_depth 0 -extbrc 0 -mbbrc 0 -rdo 0'
Assert-Options 'h264_qsv' $qsv $false '-low_power 0'
Assert-Options 'mjpeg_qsv' @() $true ''

$amf = @('preanalysis', 'preencode', 'vbaq', 'high_motion_quality_boost_enable', 'aq_mode')
Assert-Options 'hevc_amf' $amf $true '-preanalysis 0 -preencode 0 -vbaq 0 -high_motion_quality_boost_enable 0 -aq_mode 0'
Assert-Options 'hevc_amf' $amf $false ''
Assert-Options 'h264_mf' @('hw_encoding') $true '-hw_encoding 1'
Assert-Options 'h264_mf' @('hw_encoding') $false '-hw_encoding 1'
Assert-Options 'h264_vulkan' @() $true ''
Assert-Options 'hevc_d3d12va' @() $true ''
if ((Get-IntermediateUploadDevice -Encoder 'hevc_vulkan') -ne 'vulkan') { throw 'Vulkan device mismatch' }
if ((Get-IntermediateUploadDevice -Encoder 'hevc_d3d12va') -ne 'd3d12va') { throw 'D3D12VA device mismatch' }
#endregion

#region フィルター経路
function Write-Log { param([string]$Message, [string]$Level) }

$pipelineAst = $asts['re-encode-AIOptimus.ps1'].Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-VideoFilterPipeline'
}, $true)
. ([scriptblock]::Create($pipelineAst.Extent.Text))

$pipeline = Resolve-VideoFilterPipeline -HwAccelOption '' -VideoOptions '-c:v libx264' -VideoFilter 'scale=1280:-2'
if ($pipeline.Filter -ne 'scale=1280:-2' -or $pipeline.HwAccelOption) { throw 'Existing CPU path changed' }

$pipeline = Resolve-VideoFilterPipeline -HwAccelOption '-hwaccel cuda -hwaccel_output_format cuda' -VideoOptions '-c:v hevc_nvenc -pix_fmt p010le' -VideoFilter '' -EncoderSettings @{ IntermediatePixelFormat = 'p010le' }
if ($pipeline.HwAccelOption) { throw 'Explicit 10-bit format should not be routed through NV12' }

foreach ($device in @('vulkan', 'd3d12va')) {
    $settings = @{ IntermediatePixelFormat = 'p010le'; IntermediateUploadDevice = $device }
    $pipeline = Resolve-VideoFilterPipeline -HwAccelOption '-hwaccel cuda -hwaccel_output_format cuda' -VideoOptions '-c:v hevc' -VideoFilter 'scale=1280:-2' -EncoderSettings $settings
    if ($pipeline.HwAccelOption -ne "-init_hw_device $device=intermediate_encode -filter_hw_device intermediate_encode") { throw 'Upload device mismatch' }
    if ($pipeline.Filter -ne 'scale=1280:-2,format=p010le,hwupload') { throw 'Upload filter order mismatch' }
}
Write-Host '中間ファイル用ハードウェア設定の検証完了。' -ForegroundColor Green
#endregion
