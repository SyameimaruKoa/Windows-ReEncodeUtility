@echo off
rem ffmpegエンコーダー選択Ver.5.4 (わっち改修版・分岐ロジック修正)
rem このバッチファイルは、FFmpegのエンコードオプションを設定します。
rem 呼び出し元のバッチファイルに `encoder` 変数を返します。
chcp 932

:home
cls
set encoder=
set hardware_choice=
set codec_choice=
set quality_choice=

echo ───────────────────────────────────────────────────────────────
echo  FFmpeg エンコードオプション設定 (わっち改修版)
echo ───────────────────────────────────────────────────────────────
echo エンコード方式＆使用プロセッサ
echo         │     Intel (I)    │   NVIDIA (N)    │        CPU (C)        │ AMD (A) (NVIDIAの所)
echo         ├──────────────────┴──────────┬──────┴──────────┬┬───────────┤
echo         │  Intel→LA-ICQ NVIDIA→CQP    │        LA       ││   VP9(W)  │
echo ┌───────┼──────────────┬──────────────┼─────────────────┤├───────────┤
echo │ H.264 │ 1 (Vlow)     │ 3 (High)     │ 5 Custom        ││ 1 crf20   │
echo │  (M)  ├──────────────┼──────────────┼─────────────────┤├───────────┤
echo │       │ 2 (low)      │ 4 Custom     │ 6 10000k        ││ 2 crf25   │
echo ├───────┼──────────────┼──────────────┼─────────────────┤├───────────┤
echo │ H.265 │ 1 (Vlow)     │ 3 (High)     │ 5 Custom        ││ 3 crf30   │
echo │  (H)  ├──────────────┼──────────────┼─────────────────┤├───────────┤
echo │       │ 2 (low)      │ 4 Custom     │ 6 qp 0          ││ 4 Custom  │
echo └───────┴──────────────┴──────────────┴─────────────────┘└───────────┘
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
        set base_encoder=-c:v hevc_qsv
    ) else if %codec_choice%==2 (
        set base_encoder=-c:v h264_qsv
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
    if %quality_choice%==1 (
        set encoder=%base_encoder% -global_quality 20 -preset slow
    ) else if %quality_choice%==2 (
        set encoder=%base_encoder% -global_quality 25 -preset medium
    ) else if %quality_choice%==3 (
        set encoder=%base_encoder% -global_quality 30 -preset fast
    ) else if %quality_choice%==4 (
        set /p val="品質値(1-51) > "
        set encoder=%base_encoder% -global_quality %val%
    ) else if %quality_choice%==5 (
        set /p val="ビットレート(例:8000k) > "
        set encoder=%base_encoder% -b:v %val%
    )
    goto end_options

:NVIDIA_NVENC
    if %codec_choice%==1 set base_encoder=-c:v hevc_nvenc
    if %codec_choice%==2 set base_encoder=-c:v h264_nvenc
    if %codec_choice%==3 (
        echo エラー: NVIDIA NVENCはVP9エンコードに非対応です。やり直してください。
        pause & goto home
    )
    echo --- 3. NVIDIA NVENC 品質設定 ---
    echo    1: 高品質 (CQ:23 Preset:P5)
    echo    2: 中品質 (CQ:28 Preset:P5)
    echo    3: 高速 (CQ:32 Preset:P1)
    echo    4: カスタム品質 (CQ値を手動入力)
    echo    5: カスタムビットレート (手動入力)
    choice /c 12345 /m "品質を選択してください"
    set quality_choice=%errorlevel%
    if %quality_choice%==1 (
        set encoder=%base_encoder% -rc vbr -cq 23 -qmin 0 -qmax 99 -preset p5 -tune hq
    ) else if %quality_choice%==2 (
        set encoder=%base_encoder% -rc vbr -cq 28 -qmin 0 -qmax 99 -preset p5 -tune hq
    ) else if %quality_choice%==3 (
        set encoder=%base_encoder% -rc vbr -cq 32 -qmin 0 -qmax 99 -preset p1 -tune ll
    ) else if %quality_choice%==4 (
        set /p val="品質値(CQ 1-51) > "
        set encoder=%base_encoder% -rc vbr -cq %val% -qmin 0 -qmax 99 -preset p5 -tune hq
    ) else if %quality_choice%==5 (
        set /p val="ビットレート(例:6000k) > "
        set encoder=%base_encoder% -rc vbr -b:v %val% -preset p5 -tune hq
    )
    goto end_options

:CPU_X26X
    if %codec_choice%==1 set base_encoder=-c:v libx265
    if %codec_choice%==2 set base_encoder=-c:v libx264
    if %codec_choice%==3 set base_encoder=-c:v libvpx-vp9
    echo --- 3. CPUエンコード 品質設定 ---
    rem --- [修正箇所] 信頼性の高いGOTO文による分岐に変更 ---
    if "%codec_choice%"=="3" goto CPU_VP9_MENU
    goto CPU_H26X_MENU

:CPU_VP9_MENU
    echo.
    echo    --- VP9 品質 ---
    echo       1: 高品質 (CRF:30)
    echo       2: 中品質 (CRF:35)
    echo       3: カスタム
    choice /c 123 /m "品質を選択"
    set quality_choice=%errorlevel%
    if %quality_choice%==1 (
        set encoder=%base_encoder% -crf 30 -b:v 0 -cpu-used 4
    ) else if %quality_choice%==2 (
        set encoder=%base_encoder% -crf 35 -b:v 0 -cpu-used 4
    ) else if %quality_choice%==3 (
        set /p val="CRF値 > "
        set encoder=%base_encoder% -crf %val% -b:v 0
    )
    goto end_options

:CPU_H26X_MENU
    echo.
    echo    --- H.26x 品質 ---
    echo       1: 高品質 (CRF:18)
    echo       2: 中品質 (CRF:23)
    echo       3: 低品質 (CRF:28)
    echo       4: カスタム
    choice /c 1234 /m "品質を選択"
    set quality_choice=%errorlevel%
    if %quality_choice%==1 (
        set encoder=%base_encoder% -crf 18 -preset slow
    ) else if %quality_choice%==2 (
        set encoder=%base_encoder% -crf 23 -preset medium
    ) else if %quality_choice%==3 (
        set encoder=%base_encoder% -crf 28 -preset fast
    ) else if %quality_choice%==4 (
        set /p val="CRF値 > "
        set encoder=%base_encoder% -crf %val% -preset medium
    )
    goto end_options

:AMD_AMF
    if %codec_choice%==1 set base_encoder=-c:v hevc_amf
    if %codec_choice%==2 set base_encoder=-c:v h264_amf
    if %codec_choice%==3 (
        echo エラー: AMD AMFはVP9エンコードに非対応です。やり直してください。
        pause & goto home
    )
    echo --- 3. AMD AMF 品質設定 ---
    echo    1: 高品質 (QP I/P/B: 22)
    echo    2: 中品質 (QP I/P/B: 28)
    echo    3: 低品質 (QP I/P/B: 35)
    echo    4: カスタム品質 (QP値を手動入力)
    echo    5: カスタムビットレート (手動入力)
    choice /c 12345 /m "品質を選択してください"
    set quality_choice=%errorlevel%
    if %quality_choice%==1 (
        set encoder=%base_encoder% -rc cqp -qp_i 22 -qp_p 22 -qp_b 22 -quality quality
    ) else if %quality_choice%==2 (
        set encoder=%base_encoder% -rc cqp -qp_i 28 -qp_p 28 -qp_b 28 -quality quality
    ) else if %quality_choice%==3 (
        set encoder=%base_encoder% -rc cqp -qp_i 35 -qp_p 35 -qp_b 35 -quality quality
    ) else if %quality_choice%==4 (
        set /p val="QP値 > "
        set encoder=%base_encoder% -rc cqp -qp_i %val% -qp_p %val% -qp_b %val% -quality quality
    ) else if %quality_choice%==5 (
        set /p val="ビットレート(例:7000k) > "
        set encoder=%base_encoder% -rc vbr_peak -b:v %val% -quality quality
    )
    goto end_options

:end_options
echo.
echo ───────────────────────────────────────────────────────────────
echo --- 最終確認 ---
echo 以下のエンコードオプションが設定されました:
echo.
echo %encoder%
echo.
choice /m "この設定でよろしいですか？ (Y:はい / N:やり直す)"
if %errorlevel%==2 (
    echo 設定を最初からやり直します...
    goto home
)

echo 設定が完了しました。メインのバッチファイルに戻ります。

rem 呼び出し元に encoder 変数を渡して終了
(
    endlocal
    set "encoder=%encoder%"
)
