rem ffmpegエンコーダー選択Ver.4.7 (最適化版)
rem 製作者：わっち
rem このバッチファイルは、FFmpegのエンコードオプションを設定します。
rem ───────────────────────────────────────────────────────────────
:home
rem 文字コードをShift-JISに設定
chcp 932
rem 画面をクリアし、変数を初期化
cls
set hardwarenumber=
set encodernumber=
set compressionnumber=
set encoder=
set quality=
set bitrate=

echo ───────────────────────────────────────────────────────────────
echo  FFmpeg エンコードオプション設定
echo ───────────────────────────────────────────────────────────────
echo エンコード方式＆使用プロセッサ
echo         │     Intel (I)    │   NVIDIA (N)    │        CPU (C)        │ AMD (A) (NVIDIAの所)
echo         ├──────────────────┴──────────┬──────┴──────────┬┬───────────┤
echo         │  Intel→LA-ICQ NVIDIA→CQP    │        LA        ││   VP9(W)  │
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

rem ハードウェアの選択
echo 【ハードウェア選択】
choice /c INCA /m "エンコードに使用するハードウェアを選んでください (I:Intel, N:NVIDIA, C:CPU, A:AMD)"
set hardwarenumber=%errorlevel%
echo 選択されたハードウェア番号: %hardwarenumber%
echo.

rem エンコーダーの選択
echo 【エンコーダー選択】
choice /c MHW /m "エンコーダーを選んでください (M:H.264, H:H.265, W:VP9)"
set encodernumber=%errorlevel%
echo 選択されたエンコーダー番号: %encodernumber%
echo.

rem 圧縮率の選択
echo 【圧縮率選択】
choice /c 123456 /m "圧縮率を指定してください (詳細は表を参照)"
set compressionnumber=%errorlevel%
echo 選択された圧縮率番号: %compressionnumber%
echo.
echo ───────────────────────────────────────────────────────────────

rem --- ハードウェアごとの設定分岐 ---
if %hardwarenumber%==1 (
    echo >> Intel QSV 設定に進みます...
    goto Intel
) else if %hardwarenumber%==2 (
    echo >> NVIDIA NVENC 設定に進みます...
    goto NVIDIA
) else if %hardwarenumber%==3 (
    echo >> CPU (libx/libvpx) 設定に進みます...
    goto CPU
) else if %hardwarenumber%==4 (
    echo >> AMD AMF 設定に進みます...
    goto AMD
) else (
    echo !!! 無効なハードウェアが選択されました。処理を終了します。
    pause
    exit /b 1
)

rem --- Intel QSV 設定 ---
:Intel
echo 【Intel QSV コーデック設定】
rem Intel QSV エンコーダーの選択
if %encodernumber%==1 (
    echo H.264 (h264_qsv) を選択しました。
    set qsv=-c:v h264_qsv -quality quality
) else if %encodernumber%==2 (
    echo H.265/HEVC (hevc_qsv) を選択しました。
    set qsv=-c:v hevc_qsv -quality quality
) else if %encodernumber%==3 (
    echo !!! Intel QSV は VP9 エンコードに対応していません。
    echo 設定を初めからやり直してください。
    pause
    goto home
) else (
    echo !!! 無効なエンコーダー番号です。処理を終了します。
    pause
    exit /b 1
)
echo 基本エンコーダオプション: %qsv%

rem Intel QSV 圧縮率の選択
if %compressionnumber%==1 (
    echo 圧縮率: Vlow (global_quality 20) を選択。
    set encoder=%qsv%-global_quality 20
) else if %compressionnumber%==2 (
    echo 圧縮率: low (global_quality 25) を選択。
    set encoder=%qsv%-global_quality 25
) else if %compressionnumber%==3 (
    echo 圧縮率: (global_quality 30) を選択。 (H.265向けの高圧縮オプションの想定)
    set encoder=%qsv%-global_quality 30
) else if %compressionnumber%==4 (
    echo 圧縮率: Custom (品質指定) を選択。
    echo 品質を入力してください（数字が小さいほど高画質、例: 20=高品質, 35=低品質）。
    set /P quality=">> 品質値 (例: 23): "
    set encoder=%qsv%-global_quality %quality%
) else if %compressionnumber%==5 (
    echo 圧縮率: Custom (ビットレート指定) を選択。
    echo ビットレートをK単位で入力してください (例: 8000k)。
    set /P bitrate=">> ビットレート (例: 8000k): "
    set encoder=%qsv%-b:v %bitrate%
) else if %compressionnumber%==6 (
    echo 圧縮率: 10000k (固定ビットレート) を選択。
    set encoder=%qsv%-b:v 10000k
) else (
    echo !!! 無効な圧縮率番号です。処理を終了します。
    pause
    exit /b 1
)
goto SetFpsMode

rem --- NVIDIA NVENC 設定 ---
:NVIDIA
echo 【NVIDIA NVENC コーデック設定】
rem NVIDIA NVENC エンコーダーの選択
if %encodernumber%==1 (
    echo H.264 (h264_nvenc) を選択しました。
    set nvenc=-c:v h264_nvenc -quality quality
) else if %encodernumber%==2 (
    echo H.265/HEVC (hevc_nvenc) を選択しました。
    set nvenc=-c:v hevc_nvenc -quality quality
) else if %encodernumber%==3 (
    echo !!! NVIDIA NVENC は VP9 エンコードに対応していません。
    echo 設定を初めからやり直してください。
    pause
    goto home
) else (
    echo !!! 無効なエンコーダー番号です。処理を終了します。
    pause
    exit /b 1
)
echo 基本エンコーダオプション: %nvenc%

rem NVIDIA NVENC 圧縮率の選択
if %compressionnumber%==1 (
    echo 圧縮率: High (CRF 20相当のCQP) を選択。 (H.264向け高品質)
    set encoder=%nvenc%-cq 20 -rc constqp
) else if %compressionnumber%==2 (
    echo 圧縮率: (CRF 25相当のCQP) を選択。 (H.264向け中品質)
    set encoder=%nvenc%-cq 25 -rc constqp
) else if %compressionnumber%==3 (
    echo 圧縮率: High (CRF 28相当のCQP) を選択。 (H.265向け高品質)
    set encoder=%nvenc%-cq 28 -rc constqp
) else if %compressionnumber%==4 (
    echo 圧縮率: Custom (品質指定 CQP) を選択。
    echo 品質(CQP値)を入力してください（数字が小さいほど高画質、例: 20=高品質, 35=低品質）。
    set /P quality=">> CQP値 (例: 23): "
    set encoder=%nvenc%-cq %quality% -rc constqp
) else if %compressionnumber%==5 (
    echo 圧縮率: Custom (ビットレート指定) を選択。
    echo ビットレートをK単位で入力してください (例: 6000k)。
    set /P bitrate=">> ビットレート (例: 6000k): "
    set encoder=%nvenc%-b:v %bitrate% -rc vbr
) else if %compressionnumber%==6 (
    echo 圧縮率: qp 0 (ロスレスに近い設定) を選択。 (H.265向け)
    set encoder=%nvenc%-qp 0 -rc constqp
) else (
    echo !!! 無効な圧縮率番号です。処理を終了します。
    pause
    exit /b 1
)
goto SetFpsMode

rem --- CPU (libx/libvpx) 設定 ---
:CPU
echo 【CPU コーデック設定】
rem CPU エンコーダーの選択
if %encodernumber%==1 (
    echo H.264 (libx264) を選択しました。
    set libx=-c:v libx264
) else if %encodernumber%==2 (
    echo H.265/HEVC (libx265) を選択しました。
    set libx=-c:v libx265
) else if %encodernumber%==3 (
    echo VP9 (libvpx-vp9) を選択しました。
    goto CPUVP9
) else (
    echo !!! 無効なエンコーダー番号です。処理を終了します。
    pause
    exit /b 1
)
echo 基本エンコーダオプション: %libx%

rem CPU H.264/H.265 圧縮率の選択
if %compressionnumber%==1 (
    echo 圧縮率: CRF 20 を選択。
    set encoder=%libx%-crf 20
) else if %compressionnumber%==2 (
    echo 圧縮率: CRF 25 を選択。
    set encoder=%libx%-crf 25
) else if %compressionnumber%==3 (
    echo 圧縮率: CRF 30 を選択。
    set encoder=%libx%-crf 30
) else if %compressionnumber%==4 (
    echo 圧縮率: Custom (品質指定 CRF) を選択。
    echo 品質(CRF値)を入力してください（数字が小さいほど高画質、例: 18=高品質, 28=低品質）。
    set /P quality=">> CRF値 (例: 23): "
    set encoder=%libx%-crf %quality%
) else if %compressionnumber%==5 (
    echo 圧縮率: Custom (ビットレート指定) を選択。
    echo ビットレートをK単位で入力してください (例: 5000k)。
    set /P bitrate=">> ビットレート (例: 5000k): "
    set encoder=%libx%-b:v %bitrate%
) else if %compressionnumber%==6 (
    echo 圧縮率: 10000k (固定ビットレート) を選択。
    set encoder=%libx%-b:v 10000k
) else (
    echo !!! 無効な圧縮率番号です。処理を終了します。
    pause
    exit /b 1
)
goto SetFpsMode

rem --- CPU VP9 設定 ---
:CPUVP9
echo 【CPU VP9 (libvpx-vp9) コーデック設定】
if %compressionnumber%==1 (
    echo VP9 圧縮率: CRF 20, 高速プリセット を選択。
    set encoder=-c:v libvpx-vp9 -crf 20 -b:v 0 -cpu-used 2 -threads 3 -row-mt 1
) else if %compressionnumber%==2 (
    echo VP9 圧縮率: CRF 25, 高速プリセット を選択。
    set encoder=-c:v libvpx-vp9 -crf 25 -b:v 0 -cpu-used 2 -threads 3 -row-mt 1
) else if %compressionnumber%==3 (
    echo VP9 圧縮率: CRF 30, 高速プリセット を選択。
    set encoder=-c:v libvpx-vp9 -crf 30 -b:v 0 -cpu-used 2 -threads 3 -row-mt 1
) else if %compressionnumber%==4 (
    echo VP9 圧縮率: Custom (品質指定 CRF) を選択。
    echo 品質(CRF値)を入力してください（数字が小さいほど高画質、例: 20=高品質, 35=低品質）。
    set /P quality=">> CRF値 (例: 30): "
    set encoder=-c:v libvpx-vp9 -crf %quality% -b:v 0 -cpu-used 2 -threads 3 -row-mt 1
) else (
    echo !!! CPU VP9ではこれ以降の数字は使われていません。
    echo 設定を初めからやり直してください。
    pause
    goto home
)
goto SetFpsMode

rem --- AMD AMF 設定 ---
:AMD
echo 【AMD AMF コーデック設定】
rem AMD AMF エンコーダーの選択
if %encodernumber%==1 (
    echo H.264 (h264_amf) を選択しました。
    set amd=-c:v h264_amf -quality quality
) else if %encodernumber%==2 (
    echo H.265/HEVC (hevc_amf) を選択しました。
    set amd=-c:v hevc_amf -quality quality
) else if %encodernumber%==3 (
    echo !!! AMD AMF は VP9 エンコードに対応していません。
    echo 設定を初めからやり直してください。
    pause
    goto home
) else (
    echo !!! 無効なエンコーダー番号です。処理を終了します。
    pause
    exit /b 1
)
echo 基本エンコーダオプション: %amd%

rem AMD AMF 圧縮率の選択
if %compressionnumber%==1 (
    echo 圧縮率: CQP (QP I=25, P=25) を選択。
    set encoder=%amd%-rc cqp -qp_i 25 -qp_p 25
) else if %compressionnumber%==2 (
    echo 圧縮率: CQP (QP I=30, P=30) を選択。
    set encoder=%amd%-rc cqp -qp_i 30 -qp_p 30
) else if %compressionnumber%==3 (
    echo 圧縮率: CQP (QP I=35, P=35) を選択。
    set encoder=%amd%-rc cqp -qp_i 35 -qp_p 35
) else if %compressionnumber%==4 (
    echo 圧縮率: Custom (品質指定 CQP) を選択。
    echo 品質(QP値)を入力してください（IフレームとPフレームに同じ値を設定します）。
    set /P quality=">> QP値 (例: 28): "
    set encoder=%amd%-rc cqp -qp_i %quality% -qp_p %quality%
) else if %compressionnumber%==5 (
    echo 圧縮率: Custom (ビットレート指定) を選択。
    echo ビットレートをK単位で入力してください (例: 7000k)。
    set /P bitrate=">> ビットレート (例: 7000k): "
    set encoder=%amd%-b:v %bitrate%
) else if %compressionnumber%==6 (
    echo 圧縮率: CQP (QP I=0, P=0 ロスレスに近い設定) を選択。
    set encoder=%amd%-rc cqp -qp_i 0 -qp_p 0
) else (
    echo !!! 無効な圧縮率番号です。処理を終了します。
    pause
    exit /b 1
)
goto SetFpsMode


rem --- FPSモード設定 ---
:SetFpsMode
echo.
echo ───────────────────────────────────────────────────────────────
echo 【FPSモード設定】
choice /c cvpa /m "固定fps[C] 可変fps[V] パススルー[P] 自動[A]" /n
if errorlevel 4 (
    set encoder=%encoder% -fps_mode auto
    echo FPSモード: オートでエンコードします。
) else if errorlevel 3 (
    set encoder=%encoder% -fps_mode passthrough
    echo FPSモード: パススルーでエンコードします。
) else if errorlevel 2 (
    set encoder=%encoder% -fps_mode vfr
    echo FPSモード: 可変fpsでエンコードします。
) else if errorlevel 1 (
    set encoder=%encoder% -fps_mode cfr
    echo FPSモード: 固定fpsでエンコードします。
)
echo.
echo 最終エンコードオプション(FPSモード含む):
echo %encoder%
echo ───────────────────────────────────────────────────────────────
echo.

rem --- 設定確認 ---
:ConfirmSettings
echo 【最終確認】
echo 以下のエンコードオプションが設定されました:
echo %encoder%
echo.
choice /m "この設定でよろしいですか？ (Y:はい / N:やり直す)"
if %errorlevel%==2 (
    echo >> 設定を最初からやり直します...
    goto home
)

echo >> 設定が完了しました。メインのエンコードバッチファイルに戻ります。
rem メインバッチに encoder 変数を渡して終了
exit /b 0

rem ───────────────────────────────────────────────────────────────
rem 過去の tune オプションに関する記述は ffmpeg 5.0 で使えなくなったため削除しました。
rem (元コメント: ──────ffmpeg 5.0で使えなくなりました。──────)
rem ───────────────────────────────────────────────────────────────