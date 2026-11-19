#requires -Version 7.0

<#
.SYNOPSIS
    Modules/HardwareFilterResolver.ps1 の回帰テスト。
.DESCRIPTION
    実プローブはスタブ化し、マッピング・パラメータ変換・フォールバック・キャッシュ無効化を検証する。
#>

$root = Split-Path -Parent $PSScriptRoot
$global:AppCacheDir = Join-Path $root '.cache\test-work\hw-filter-resolver'
$null = New-Item -ItemType Directory -Path $global:AppCacheDir -Force
. (Join-Path $root 'Modules\HardwareFilterResolver.ps1')

$script:PassCount = 0
$script:FailCount = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ($Expected -eq $Actual) { $script:PassCount++ }
    else {
        $script:FailCount++
        Write-Host "FAIL: $Name (expected=[$Expected] actual=[$Actual])" -ForegroundColor Red
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:PassCount++ }
    else {
        $script:FailCount++
        Write-Host "FAIL: $Name" -ForegroundColor Red
    }
}

# フィルター存在判定はテスト中は常にtrueとする
function Test-HwFilterAvailable {
    param([string]$Name)
    return $true
}

Write-Host '== HWフィルター置換ルール =='
foreach ($format in @('qsv', 'cuda', 'amf', 'd3d11', 'vulkan', 'vaapi')) {
    Assert-True (@(Get-HwFilterRules -FrameFormat $format).Count -gt 0) "$format のルールが存在する"
}
Assert-True (@(Get-HwFilterRules -FrameFormat 'unknown').Count -eq 0) '未知のHW形式はルールなし'

Write-Host '== パラメータ変換 =='
$scaleCuda = Convert-HwFilterExpression -Expr 'scale=1280:-2' -Candidate 'scale_cuda' -Converter 'Scale'
Assert-Equal 'scale_cuda=w=1280:h=trunc(ih*1280/iw/2)*2' $scaleCuda 'scale → scale_cuda (-2の展開)'
$scaleD3d = Convert-HwFilterExpression -Expr 'scale=1280:720' -Candidate 'scale_d3d11' -Converter 'Scale'
Assert-Equal 'scale_d3d11=width=1280:height=720:format=nv12' $scaleD3d 'scale → scale_d3d11'
$padCuda = Convert-HwFilterExpression -Expr 'pad=1920:1080:240:0:black' -Candidate 'pad_cuda' -Converter 'Passthrough'
Assert-Equal 'pad_cuda=1920:1080:240:0:black' $padCuda 'pad → pad_cuda'
$yadifCuda = Convert-HwFilterExpression -Expr 'yadif=0:-1:0' -Candidate 'yadif_cuda' -Converter 'Deinterlace'
Assert-Equal 'yadif_cuda=0:-1:0' $yadifCuda 'yadif → yadif_cuda'
Assert-Equal '' (Convert-HwFilterExpression -Expr 'yadif=1:-1:0' -Candidate 'deinterlace_qsv' -Converter 'Deinterlace') 'QSVは非既定引数を変換しない'

Write-Host '== フィルターグラフ置換 =='
$hwOpt = '-hwaccel cuda -hwaccel_output_format cuda'
$vo = '-c:v h264_nvenc'
$result = Resolve-HardwareFilterGraph -Filter 'scale=1280:720,yadif=0:-1:0,lenscorrection=cx=0.5' `
    -FrameFormat 'cuda' -HwAccelOption $hwOpt -VideoOptions $vo -SkipProbe
Assert-Equal 'scale_cuda=w=1280:h=720,yadif_cuda=0:-1:0,lenscorrection=cx=0.5' $result.Filter '対象のみ置換、非対象は維持'
Assert-Equal 2 $result.Replacements.Count '置換数'

Write-Host '== プローブ失敗時のフォールバック =='
$key = "$hwOpt|$vo|scale_cuda=w=1280:h=720"
$script:HwFilterProbeOverride[$key] = $false
$fallback = Resolve-HardwareFilterGraph -Filter 'scale=1280:720' -FrameFormat 'cuda' `
    -HwAccelOption $hwOpt -VideoOptions $vo
Assert-Equal 'scale=1280:720' $fallback.Filter 'プローブ失敗時はCPUフィルターを維持'
Assert-Equal 0 $fallback.Replacements.Count 'プローブ失敗時は置換なし'
$script:HwFilterProbeOverride[$key] = $true

$qsvOpt = '-hwaccel qsv -hwaccel_output_format qsv'
$qsvVo = '-c:v hevc_qsv'
$scaleQsvKey = "$qsvOpt|$qsvVo|scale_qsv=w=1280:h=720"
$script:HwFilterProbeOverride[$scaleQsvKey] = $false
$vppKey = "$qsvOpt|$qsvVo|vpp_qsv=w=1280:h=720"
$script:HwFilterProbeOverride[$vppKey] = $true
$qsv = Resolve-HardwareFilterGraph -Filter 'scale=1280:720' -FrameFormat 'qsv' `
    -HwAccelOption $qsvOpt -VideoOptions $qsvVo
Assert-Equal 'vpp_qsv=w=1280:h=720' $qsv.Filter '第1候補失敗時に第2候補へ切り替え'

Write-Host '== HW形式なし／キャッシュ無効化 =='
$none = Resolve-HardwareFilterGraph -Filter 'scale=1280:720' -FrameFormat '' -SkipProbe
Assert-Equal 'scale=1280:720' $none.Filter 'HW形式なしでは変更しない'

$cachePath = Get-HwFilterCachePath
$invalid = [pscustomobject]@{
    SchemaVersion   = 1
    MachineName     = $env:COMPUTERNAME
    SavedAt         = Get-Date
    FfmpegSignature = 'invalid-signature'
    Results         = @{ 'old' = $true }
}
$invalid | Export-Clixml -LiteralPath $cachePath -Force
$loaded = Load-HwFilterProbeCache -Signature (Get-HwFilterSignature)
Assert-True ($null -eq $loaded) 'FFmpegシグネチャ不一致のキャッシュは無効'
Clear-HwFilterProbeCache
Assert-True (-not (Test-Path -LiteralPath $cachePath)) 'キャッシュクリア'

Write-Host "結果: PASS=$($script:PassCount) FAIL=$($script:FailCount)"
if ($script:FailCount -gt 0) { exit 1 }
