<#
.SYNOPSIS
    Modules/EncodeFallback.ps1 の回帰テスト。
.PARAMETER WithVideo
    実動画を使った事前検証プローブの実行も行う（既定のテスト動画を使用）。
#>
#requires -Version 7.0

[CmdletBinding()]
param(
    [switch]$WithVideo,
    [string]$VideoPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.cache\Azahar 2126.2 _ SUPER MARIO 3D LAND 2026-11-16 19-03-51.mp4')
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$rootDir = Split-Path -Parent $scriptDir

. (Join-Path $rootDir 'Modules\EncodeFallback.ps1')

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    # テスト中は黙る
}

# メインスクリプト相当の実行関数（監視なしの軽量実行で代替）
function Invoke-QsvEncodeWithDepthFallback {
    param([string]$Arguments, [double]$DurationSeconds = 0)
    return Invoke-ProbeFfmpeg -Arguments $Arguments
}

$global:Settings = @{ FfmpegPath = 'ffmpeg'; FfprobePath = 'ffprobe' }
# 作業領域は git 対象外のプロジェクト内 .cache\test-work に限定する
$workRoot = Join-Path $rootDir '.cache\test-work'
$global:AppCacheDir = Join-Path $workRoot "test-$([System.IO.Path]::GetRandomFileName())"
$null = New-Item -ItemType Directory -Path $global:AppCacheDir -Force

$script:Passed = 0
$script:Failed = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ($Expected -eq $Actual) {
        $script:Passed++
        "  PASS: $Name"
    }
    else {
        $script:Failed++
        "  FAIL: $Name (expected=[$Expected] actual=[$Actual])"
    }
}
function Assert-True {
    param([bool]$Condition, [string]$Name)
    Assert-Equal -Expected $true -Actual ([bool]$Condition) -Name $Name
}

try {
    "== 失敗分類 =="
    Assert-Equal 'HwDecodeInit' (Get-EncodeFailureClass 'Failed setup for format cuda') 'HwDecodeInit 検出'
    Assert-Equal 'HwFilter' (Get-EncodeFailureClass 'Error initializing filter scale_qsv') 'HwFilter 検出'
    Assert-Equal 'HwEncodeInit' (Get-EncodeFailureClass 'Encoder h264_nvenc not found') 'HwEncodeInit 検出'
    Assert-Equal 'EncoderOption' (Get-EncodeFailureClass 'Unrecognized option rc-lookahead') 'EncoderOption 検出'
    Assert-Equal 'Unknown' (Get-EncodeFailureClass '') '空は Unknown'
    Assert-True (Test-IsHwRelatedFailureClass 'HwFilter') 'HwFilter はHW関連'
    Assert-True (-not (Test-IsHwRelatedFailureClass 'EncoderOption')) 'EncoderOption はHW非関連'

    "== 能力キー =="
    $key1 = Get-EncodeCapabilityKey -HwAccelOption '-hwaccel cuda' -VideoFilter 'scale=1280:720' -VideoOptions '-c:v h264_nvenc -b:v 5M'
    $key2 = Get-EncodeCapabilityKey -HwAccelOption '-hwaccel cuda' -VideoFilter 'scale=1280:720' -VideoOptions '-c:v h264_nvenc -b:v 5M'
    $key3 = Get-EncodeCapabilityKey -HwAccelOption '-hwaccel qsv' -VideoFilter 'scale=1280:720' -VideoOptions '-c:v h264_nvenc -b:v 5M'
    Assert-Equal $key1 $key2 '同一設定は同一キー'
    Assert-True ($key1 -ne $key3) '異なる hwaccel は異なるキー'

    "== 能力キャッシュ =="
    Set-EncodeCapability -Key $key1 -Status 'OK'
    $entry = Get-EncodeCapability -Key $key1
    Assert-Equal 'OK' $entry.Status '保存した OK が読める'
    Assert-Equal $true (Test-Path -LiteralPath (Get-EncodeCapabilityCachePath)) 'キャッシュファイルが存在'
    Clear-EncodeCapabilityCache
    Assert-Equal $null (Get-EncodeCapability -Key $key1) 'クリア後は未検出'

    "== 引数変換 =="
    $args = '-hide_banner -y -hwaccel d3d11va -hwaccel_output_format d3d11 -i "in.mp4" -vf "scale_d3d11=width=1280:height=720:format=nv12" -c:v h264_qsv "out.mp4"'
    $converted = Convert-GpuFilterToCpuFilter -ArgString $args
    Assert-True ($converted -match 'hwdownload,format=nv12,scale=1280:720') 'D3D11スケールをCPUスケールに変換'
    Assert-True ($converted -notmatch 'scale_d3d11') 'GPUスケールが除去された'

    $args2 = '-hide_banner -i "in.mp4" -vf "scale_cuda=w=1280:h=720,format=yuv420p" -c:v h264_nvenc "out.mp4"'
    $converted2 = Convert-GpuFilterToCpuFilter -ArgString $args2
    Assert-True ($converted2 -match 'scale=1280:720,format=yuv420p') 'CUDAスケール変換 + 後続フィルタ維持'

    $noHw = Remove-HwAccelArguments -ArgString $args
    Assert-True ($noHw -notmatch '-hwaccel') 'hwaccel が除去された'
    Assert-True ($noHw -match 'scale_d3d11') 'Remove-HwAccelArguments はスケールを触らない'

    "== フォールバック階層 =="
    $tiers = Get-FallbackArgumentTiers -Arguments $args -HwAccelOption '-hwaccel d3d11va -hwaccel_output_format d3d11'
    Assert-Equal 3 $tiers.Count '既定は3階層'
    Assert-Equal 'Requested' $tiers[0].Kind 'tier1 = 要求設定'
    Assert-Equal 'CpuFilter' $tiers[1].Kind 'tier2 = CPUスケール'
    Assert-Equal 'NoHwAccel' $tiers[2].Kind 'tier3 = HWアクセルなし'
    $tiers4 = Get-FallbackArgumentTiers -Arguments $args -HwAccelOption '-hwaccel d3d11va' -AllowCpuEncoderFallback
    Assert-Equal 4 $tiers4.Count 'CPUエンコーダ許可時は4階層'

    "== ゼロコピー判定 =="
    Assert-Equal $null (Resolve-ZeroCopyScaleFilter -InputPath 'dummy' -FrameFormat 'cuda' -Encoder 'nvenc' -VideoFilter 'scale=1280:720' -HwAccelOption '' -VideoOptions '') '非D3D11は対象外'

    "== 事前検証プローブ (lavfi) =="
    $tmpOut = Join-Path $global:AppCacheDir 'probe-out.mp4'
    $okProbe = Test-EncodeConfiguration -Arguments "-hide_banner -y -f lavfi -i `"color=c=black:s=64x64:d=1:r=25`" -c:v libx264 -pix_fmt yuv420p `"$tmpOut`""
    Assert-Equal $true $okProbe.Success '有効な設定はプローブ成功'
    Assert-True ($okProbe.ProbeArgs -match '-frames:v 8 -f null (?:NUL|-)') 'プローブ引数が軽量設定に置換された'
    Assert-True ($okProbe.ProbeArgs -notmatch 'probe-out\.mp4') '出力先が除去された'
    $badProbe = Test-EncodeConfiguration -Arguments "-hide_banner -y -f lavfi -i `"color=c=black:s=64x64:d=1:r=25`" -c:v no_such_encoder_xyz `"$tmpOut`""
    Assert-Equal $false $badProbe.Success '無効なエンコーダはプローブ失敗'
    Assert-Equal 'HwEncodeInit' $badProbe.Class '失敗クラスが分類された'

    if ($WithVideo) {
        "== 実動画での事前検証 =="
        if (-not (Test-Path -LiteralPath $VideoPath -PathType Leaf)) {
            # 動画が無い場合は合成クリップを生成して検証を継続する
            $VideoPath = Join-Path $global:AppCacheDir 'synthetic.mkv'
            $null = & 'ffmpeg' -hide_banner -loglevel error -y `
                -f lavfi -i 'color=c=blue:s=320x180:r=30:d=3' `
                -f lavfi -i 'sine=frequency=440:duration=3' `
                -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest $VideoPath 2>&1
            if (-not (Test-Path -LiteralPath $VideoPath)) { throw '合成クリップの生成に失敗しました。' }
        }
        $videoProbeArgs = "-hide_banner -y -i `"$VideoPath`" -frames:v 8 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -f mp4 `"$(Join-Path $global:AppCacheDir 'video-probe.mp4')`""
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $vp = Test-EncodeConfiguration -Arguments $videoProbeArgs
        $sw.Stop()
        Assert-Equal $true $vp.Success '実動画でプローブ成功'
        "  所要時間: $($sw.Elapsed.TotalSeconds.ToString('F2')) 秒"

        "== 実動画での統一フォールバック実行 =="
        $clip = Join-Path $global:AppCacheDir 'clip.mp4'
        $null = & 'ffmpeg' -hide_banner -loglevel error -y -ss 0 -t 3 -i $VideoPath -c copy $clip 2>&1
        Assert-True (Test-Path -LiteralPath $clip) 'テスト用クリップ作成'
        $outFile = Join-Path $global:AppCacheDir 'fallback-out.mp4'
        $encodeArgs = "-hide_banner -y -i `"$clip`" -frames:v 60 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -an `"$outFile`""
        $fr = Invoke-EncodeWithFallback -Arguments $encodeArgs -HwAccelOption '' -VideoFilter '' `
            -VideoOptions '-c:v libx264 -preset ultrafast' -DurationSeconds 3 -Label '結合テスト'
        Assert-Equal 0 $fr.ExitCode '統一フォールバックが正常終了'
        Assert-Equal 'Requested' $fr.Tier '初回は要求設定が採用された'
        Assert-True (Test-Path -LiteralPath $outFile) '出力ファイルが生成された'
        $cacheKey = Get-EncodeCapabilityKey -VideoOptions '-c:v libx264 -preset ultrafast'
        Assert-Equal 'OK' (Get-EncodeCapability -Key $cacheKey).Status '成功設定がキャッシュされた'
    }
}
finally {
    # 安全装置: .cache\test-work 配下の自分専用ディレクトリ以外は絶対に削除しない
    if ($global:AppCacheDir -and $global:AppCacheDir.StartsWith($workRoot + [IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $global:AppCacheDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Host "安全装置により削除をスキップしました: $($global:AppCacheDir)" -ForegroundColor Yellow
    }
}

""
"結果: PASS=$($script:Passed) FAIL=$($script:Failed)"
if ($script:Failed -gt 0) { exit 1 }
