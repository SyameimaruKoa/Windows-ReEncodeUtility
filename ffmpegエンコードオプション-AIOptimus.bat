@echo off
rem ffmpegエンコーダー選択Ver.8.0 (わっち改修版・統合最終版)
rem このバッチファイルは、FFmpegのエンコードオプションを設定します。
rem 呼び出し元のバッチファイルに `encoder` 変数を返します。
chcp 932

:home
cls
setlocal enabledelayedexpansion
set encoder=
set hardware_choice=
set codec_choice=
set quality_choice=
set preset_option=
set tune_option=

echo ───────────────────────────────────────────────────────────────
echo  FFmpeg エンコードオプション設定 (わっち改修版)
echo ───────────────────────────────────────────────────────────────
echo.
echo     [Available Options]
echo.
echo ┌─────────────────────────────────────────────────────────────────────┐
echo │ NVIDIA (N)                                                          │
echo ├─────────────┬───────────────────────────────────────────────────────┤
echo │ Codec       │ H.265/HEVC (H), H.264/AVC (W)                         │
echo │ Quality(CQ) │ High(23), Mid(28), Fast(32), Custom, Bitrate          │
echo │ Preset      │ P1(Fastest), P2, P3, P4(Default), P5, P6, P7(Highest) │
echo │ Tune        │ HQ(High Quality/Rec.), LL(Low Latency), ULL(Ultra LL) │
echo └─────────────┴───────────────────────────────────────────────────────┘
echo ┌───────────────────────────────────────────────────────────┐
echo │ Intel (I)                                                 │
echo ├─────────────┬─────────────────────────────────────────────┤
echo │ Codec       │ H.265/HEVC (H), H.264/AVC (W)               │
echo │ Quality(GQ) │ High(20), Mid(25), Low(30), Custom, Bitrate │
echo │ Preset      │ veryfast - veryslow                         │
echo └─────────────┴─────────────────────────────────────────────┘
echo ┌───────────────────────────────────────────────────────────────┐
echo │ CPU (C)                                                       │
echo ├─────────┬─────────────────────────────────────────────────────┤
echo │ H.26x   │ Quality(CRF): High(18), Mid(23), Low(28), Custom    │
echo │         │ Preset:      ultrafast(Fastest) - placebo(Not Rec.) │
echo ├─────────┼─────────────────────────────────────────────────────┤
echo │ VP9 (V) │ Quality(CRF): High(30), Mid(35), Custom             │
echo └─────────┴─────────────────────────────────────────────────────┘
echo ┌───────────────────────────────────────────────────────────┐
echo │ AMD (A)                                                   │
echo ├─────────────┬─────────────────────────────────────────────┤
echo │ Codec       │ H.265/HEVC (H), H.264/AVC (W)               │
echo │ Quality(QP) │ High(22), Mid(28), Low(35), Custom, Bitrate │
echo │ Preset      │ Speed, Balanced, Quality                    │
echo └─────────────┴─────────────────────────────────────────────┘
echo.
echo --- 1. ハードウェア選択 ---
choice /c INCA /m "エンコードに使用するハードウェア (I:Intel, N:NVIDIA, C:CPU, A:AMD)"
set hardware_choice=%errorlevel%
echo.

echo --- 2. コーデック選択 ---
choice /c HWV /m "使用するコーデック (H:HEVC, W:AVC, V:VP9)"
set codec_choice=%errorlevel%
echo.

rem --- ハードウェアとコーデックの組み合わせに応じて分岐 ---
if %hardware_choice%==1 goto Intel_QSV
if %hardware_choice%==2 goto NVIDIA_NVENC
if %hardware_choice%==3 goto CPU_X26X
if %hardware_choice%==4 goto AMD_AMF
goto home

:Intel_QSV
    if %codec_choice%==1 (
        set "base_encoder=-c:v hevc_qsv -pix_fmt nv12"
    ) else if %codec_choice%==2 (
        set "base_encoder=-c:v h264_qsv -pix_fmt nv12"
    ) else if %codec_choice%==3 (
        echo エラー: Intel QSVはVP9エンコードに非対応です。やり直してください。
        pause & goto home
    )
    echo --- 3. Intel QSV 品質設定 ---
    echo    1: 高品質 (global_quality 20)
    echo    2: 中品質 (global_quality 25)
    echo    3: 低品質 (global_quality 30)
    echo    4: カスタム品質 (手動入力)
    echo    5: カスタムビットレート (手動入力)
    choice /c 12345 /m "品質を選択してください"
    set quality_choice=%errorlevel%
    if %quality_choice%==1 set "encoder=%base_encoder% -global_quality 20"
    if %quality_choice%==2 set "encoder=%base_encoder% -global_quality 25"
    if %quality_choice%==3 set "encoder=%base_encoder% -global_quality 30"
    if %quality_choice%==4 (
        set /p val="品質値(1-51) > "
        set "encoder=!base_encoder! -global_quality !val!"
    )
    if %quality_choice%==5 (
        set /p val="ビットレート(例:8000k) > "
        set "encoder=!base_encoder! -b:v !val!"
    )

    echo.
    echo --- 3b. Intel QSV プリセット選択 ---
    echo    1: veryfast (最速)  2: faster  3: fast  4: medium (標準)
    echo    5: slow      6: slower  7: veryslow (最高品質)
    choice /c 1234567 /m "プリセットを選択"
    set preset_choice=%errorlevel%
    if %preset_choice%==1 set "preset_option=-preset veryfast"
    if %preset_choice%==2 set "preset_option=-preset faster"
    if %preset_choice%==3 set "preset_option=-preset fast"
    if %preset_choice%==4 set "preset_option=-preset medium"
    if %preset_choice%==5 set "preset_option=-preset slow"
    if %preset_choice%==6 set "preset_option=-preset slower"
    if %preset_choice%==7 set "preset_option=-preset veryslow"
    set "encoder=!encoder! !preset_option!"
    goto end_options

:NVIDIA_NVENC
    if %codec_choice%==1 set "base_encoder=-c:v hevc_nvenc"
    if %codec_choice%==2 set "base_encoder=-c:v h264_nvenc"
    if %codec_choice%==3 (
        echo エラー: NVIDIA NVENCはVP9エンコードに非対応です。やり直してください。
        pause
        goto home
    )
    echo --- 3. NVIDIA NVENC 品質設定 ---
    echo    1: 高品質 (CQ:23)  2: 中品質 (CQ:28)  3: 高速 (CQ:32)
    echo    4: カスタム品質 (CQ値を手動入力)
    echo    5: カスタムビットレート (手動入力)
    choice /c 12345 /m "品質を選択してください"
    set quality_choice=%errorlevel%
    if %quality_choice%==1 set "encoder=%base_encoder% -rc vbr -qmin 0 -qmax 99 -cq 23"
    if %quality_choice%==2 set "encoder=%base_encoder% -rc vbr -qmin 0 -qmax 99 -cq 28"
    if %quality_choice%==3 set "encoder=%base_encoder% -rc vbr -qmin 0 -qmax 99 -cq 32"
    if %quality_choice%==4 (
        set /p val="品質値(CQ 1-51) > "
        set "encoder=!base_encoder! -rc vbr -qmin 0 -qmax 99 -cq !val!"
    )
    if %quality_choice%==5 (
        set /p val="ビットレート(例:6000k) > "
        set "encoder=!base_encoder! -rc vbr -b:v !val!"
    )

    echo.
    echo --- 3b. NVIDIA NVENC プリセット選択 ---
    echo    1: P1 (最速) 2: P2 3: P3 4: P4 (標準) 5: P5 6: P6 7: P7 (最高品質)
    choice /c 1234567 /m "プリセットを選択"
    set preset_choice=%errorlevel%
    if %preset_choice%==1 set "preset_option=-preset p1"
    if %preset_choice%==2 set "preset_option=-preset p2"
    if %preset_choice%==3 set "preset_option=-preset p3"
    if %preset_choice%==4 set "preset_option=-preset p4"
    if %preset_choice%==5 set "preset_option=-preset p5"
    if %preset_choice%==6 set "preset_option=-preset p6"
    if %preset_choice%==7 set "preset_option=-preset p7"
    set "encoder=!encoder! !preset_option!"

    echo.
    echo --- 3c. NVIDIA NVENC チューニング選択 ---
    echo    1: 高品質 (推奨)  2: 低遅延 (配信向け)  3: 超低遅延 (高速配信向け)
    choice /c 123 /m "チューニングを選択"
    set tune_choice=%errorlevel%
    if %tune_choice%==1 set "tune_option=-tune hq"
    if %tune_choice%==2 set "tune_option=-tune ll"
    if %tune_choice%==3 set "tune_option=-tune ull"
    set "encoder=!encoder! !tune_option!"
    goto end_options

:CPU_X26X
    if %codec_choice%==1 set "base_encoder=-c:v libx265"
    if %codec_choice%==2 set "base_encoder=-c:v libx264"
    if %codec_choice%==3 (
        set "base_encoder=-c:v libvpx-vp9"
        goto CPU_VP9_MENU
    )
    goto CPU_H26X_MENU

:CPU_VP9_MENU
    echo --- 3. CPU (VP9) 品質設定 ---
    echo    1: 高品質(CRF:30) 2: 中品質(CRF:35) 3: カスタム
    choice /c 123 /m "品質を選択"
    set quality_choice=%errorlevel%
    if %quality_choice%==1 set "encoder=%base_encoder% -crf 30 -b:v 0 -cpu-used 4"
    if %quality_choice%==2 set "encoder=%base_encoder% -crf 35 -b:v 0 -cpu-used 4"
    if %quality_choice%==3 (
        set /p val="CRF値 > "
        set "encoder=!base_encoder! -crf !val! -b:v 0 -cpu-used 4"
    )
    goto end_options

:CPU_H26X_MENU
    echo --- 3. CPU (H.26x) 品質設定 ---
    echo    1: 高品質(CRF:18) 2: 中品質(CRF:23) 3: 低品質(CRF:28) 4: カスタム
    choice /c 1234 /m "品質を選択"
    set quality_choice=%errorlevel%
    if %quality_choice%==1 set "encoder=%base_encoder% -crf 18"
    if %quality_choice%==2 set "encoder=%base_encoder% -crf 23"
    if %quality_choice%==3 set "encoder=%base_encoder% -crf 28"
    if %quality_choice%==4 ( set /p val="CRF値 > " & set "encoder=!base_encoder! -crf !val!" )

    echo.
    echo --- 3b. CPU (H.26x) プリセット選択 ---
    echo    1: ultrafast (最速) 2: superfast 3: veryfast 4: faster   5: fast
    echo    6: medium (標準)    7: slow      8: slower   9: veryslow (最高品質)
    echo    0: placebo (非推奨:激遅)
    choice /c 1234567890 /m "プリセットを選択"
    set preset_choice=%errorlevel%
    if %preset_choice%==1 set "preset_option=-preset ultrafast"
    if %preset_choice%==2 set "preset_option=-preset superfast"
    if %preset_choice%==3 set "preset_option=-preset veryfast"
    if %preset_choice%==4 set "preset_option=-preset faster"
    if %preset_choice%==5 set "preset_option=-preset fast"
    if %preset_choice%==6 set "preset_option=-preset medium"
    if %preset_choice%==7 set "preset_option=-preset slow"
    if %preset_choice%==8 set "preset_option=-preset slower"
    if %preset_choice%==9 set "preset_option=-preset veryslow"
    if %preset_choice%==10 set "preset_option=-preset placebo"
    set "encoder=!encoder! !preset_option!"
    goto end_options

:AMD_AMF
    if %codec_choice%==1 set "base_encoder=-c:v hevc_amf"
    if %codec_choice%==2 set "base_encoder=-c:v h264_amf"
    if %codec_choice%==3 (
        echo エラー: AMD AMFはVP9エンコードに非対応です。やり直してください。
        pause
        goto home
    )
    echo --- 3. AMD AMF 品質設定 ---
    echo    1: 高品質 (QP:22)  2: 中品質 (QP:28)  3: 低品質 (QP:35)
    echo    4: カスタム品質 (QP値を手動入力)
    echo    5: カスタムビットレート (手動入力)
    choice /c 12345 /m "品質を選択してください"
    set quality_choice=%errorlevel%
    if %quality_choice%==1 set "encoder=%base_encoder% -rc cqp -qp_i 22 -qp_p 22 -qp_b 22"
    if %quality_choice%==2 set "encoder=%base_encoder% -rc cqp -qp_i 28 -qp_p 28 -qp_b 28"
    if %quality_choice%==3 set "encoder=%base_encoder% -rc cqp -qp_i 35 -qp_p 35 -qp_b 35"
    if %quality_choice%==4 (
        set /p val="QP値 > "
    set "encoder=%base_encoder% -rc cqp -qp_i %val% -qp_p %val% -qp_b %val%"
    )
    if %quality_choice%==5 (
        set /p val="ビットレート(例:7000k) > "
    set "encoder=%base_encoder% -rc vbr_peak -b:v %val%"
    )

    echo.
    echo --- 3b. AMD AMF プリセット選択 ---
    choice /c sbq /m "プリセットを選択 (S:Speed, B:Balanced, Q:Quality)"
    set preset_choice=%errorlevel%
    if %preset_choice%==1 set "preset_option=-quality speed"
    if %preset_choice%==2 set "preset_option=-quality balanced"
    if %preset_choice%==3 set "preset_option=-quality quality"
    set "encoder=!encoder! !preset_option!"
    goto end_options

:end_options
echo.
echo ───────────────────────────────────────────────────────────────
echo --- 最終確認 ---
echo 以下のエンコードオプションが設定されました:
echo.
echo !encoder!
echo.
choice /m "この設定でよろしいですか？ (Y:はい / N:やり直す)"
if %errorlevel%==2 (
    echo 設定を最初からやり直します...
    goto home
)
goto Finalize

:Finalize
echo 設定が完了しました。メインのバッチファイルに戻ります。
(
    endlocal
    set "encoder=%encoder%"
)