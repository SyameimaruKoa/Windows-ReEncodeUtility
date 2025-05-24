@echo off
rem ffmpeg一括再エンコードVer6.6 (最適化版)
rem 製作者：わっち
rem このバッチファイルは、複数の動画ファイルをffmpegで一括再エンコードします。
rem 最初にエンコードオプションを設定し、その後ファイルごとに処理を実行します。

rem Shift-JISに文字コードを設定 (Windowsバッチの標準的なおまじない)
chcp 932

:root
rem --- 初期設定 ---
echo ─────────────────────────────────────
echo  FFmpeg 一括再エンコード処理 開始
echo ─────────────────────────────────────
echo.

rem 外部バッチファイルでエンコードオプションを設定
echo >> エンコードオプションを設定します...
call "..\ffmpegエンコードオプション-AIOptimus.bat"
rem ↑で設定された %encoder% 変数を使用します
if "%encoder%"=="" (
    echo !!! エンコードオプションが設定されませんでした。処理を中止します。
    pause
    goto exit_script
)
echo >> エンコードオプションが設定されました: %encoder%
echo.

rem --- 出力先フォルダ設定 ---
echo 【出力先フォルダ設定】
set outputpath=
choice /m "出力先を固定しますか？（固定する場合は「C:\Users\kouki\Videos\エンコード済み」に保存されます）"
if %errorlevel%==1 (
    set outputpath=fixed
    echo >> 出力先は固定フォルダ「C:\Users\kouki\Videos\エンコード済み」です。
) else (
    echo >> 出力先は各動画ファイルの存在するフォルダ内の「ffmpeg」サブフォルダです。
)
echo.

rem --- 処理後シャットダウン設定 ---
echo 【処理後シャットダウン設定】
set shutdown=no
rem choiceコマンドの前にtimeoutを挟むことで、誤操作による即時選択を防ぐ意図があると思われる
timeout /nobreak 1 > nul
choice /m "エンコード完了後シャットダウンさせますか？"
if %errorlevel%==1 (
    echo >> エンコード完了60秒後にシャットダウンします。
    set shutdown=yes
) else (
    echo >> エンコード完了後、シャットダウンは行いません。
)
echo.

rem --- 出力拡張子設定 ---
echo 【出力拡張子設定】
set extension=mp4
rem timeout /nobreak 1 > nul
choice /m "拡張子をMP4ではなくMOVにしますか？"
if %errorlevel%==1 (
    set extension=mov
    echo >> 出力ファイルの拡張子は .mov です。
) else (
    set extension=mp4
    echo >> 出力ファイルの拡張子は .mp4 です。
)
echo.

rem --- 音声エンコード設定 ---
echo 【音声エンコード設定】
set AudioEncode=
set qaacencoder=
set af=no
set Audiofilter=

rem webm の場合は opus で強制変換 (元ロジック: if %encodernumber%==3)
rem encodernumber は ffmpegエンコードオプション.bat 内のローカル変数だったため、
rem ここでは入力ファイルの拡張子で判定する方が適切。この判定はループ内で実施。

rem 音声再エンコードの選択 (qaac, copy, null)
rem timeout /nobreak 1 > nul
echo 音声も再エンコードしますか？(qaacを使って動画処理の前にエンコードします)
choice /c yn0 /m "(Y:qaacで再エンコード, N:音声をコピー, 0:音声を削除)"
if %errorlevel%==1 (
    set AudioEncode=qaac
    echo >> 音声は qaac で再エンコードします。
    goto qaacoption
)
if %errorlevel%==2 (
    set AudioEncode=copy
    echo >> 音声はそのままコピーします (-c:a copy)。
    goto SkipAudioSettings
)
if %errorlevel%==3 (
    set AudioEncode=null
    echo >> 音声は削除します (-an)。
    goto SkipAudioSettings
)

:qaacoption
echo 【qaac オプション設定】
echo   aac-hc (標準的なAAC) を使う場合は1
echo   aac-he (HE-AAC 高効率) を使う場合は2
choice /c 12 /m "qaacのエンコーダータイプを選択してください:"
if %errorlevel%==1 (
    set qaacencoder=
    echo   >> qaacエンコーダー: aac-hc (デフォルト)
)
if %errorlevel%==2 (
    set qaacencoder= --he
    echo   >> qaacエンコーダー: aac-he (高効率)
)

echo.
choice /m "qaacで音声フィルター(af)を使いますか？（倍速等を適用する場合）"
if %errorlevel%==2 (
    echo   >> qaacで音声フィルターは使用しません。
    goto SkipAudioSettings
)
set af=yes
echo   >> qaacで音声フィルターを使用します。
echo   ffmpegの「-af」オプションとして使用するフィルターを入力してください。
echo   複数指定する場合はカンマ(,)で区切ってください (例: atempo=2.0,volume=0.5)
set /P Audiofilter="   -afフィルター文字列入力＞ "
if defined Audiofilter (
    set Audiofilter= -af "%Audiofilter%"
    echo   >> 設定された音声フィルター: %Audiofilter%
) else (
    echo   >> 音声フィルターは入力されませんでした。
    set af=no
)
goto SkipAudioSettings

:SkipAudioSettings
echo.

rem --- 動画カット設定 ---
echo 【動画カット設定】
set cut=no
set cutinfo=
set cutinfo2=
rem timeout /nobreak 1 > nul
choice /m "動画をカットしますか？ (LosslessCutを使用)"
if %errorlevel%==1 (
    set cut=yes
    echo >> 動画をカットします。後ほど開始位置と終了位置を入力します。
) else (
    echo >> 動画はカットしません。
)
echo.

rem --- 動画メタデータ保持設定 ---
echo 【動画メタデータ保持設定】
set exiftool=no
set exiftoolCommand=
rem timeout /nobreak 1 > nul
choice /c fen /m "動画のプロパティ(メタデータ)を保持しますか？ (F:ffmpegメタデータ形式, E:ExifToolで全コピー, N:保持しない)"
if %errorlevel%==1 (
    set exiftool=ffmpeg
    echo >> 動画メタデータは ffmpeg の ffmetadata 形式で一部保持・復元します。
)
if %errorlevel%==2 (
    set exiftool=yes
    echo >> 動画メタデータは ExifTool を使用して元ファイルから可能な限りコピーします。
)
if %errorlevel%==3 (
    echo >> 動画メタデータは保持しません。
)
echo.

rem --- 追加フィルター/オプション設定 ---
echo 【追加フィルター/オプション設定】
set filter=
set vf=
set argument=

choice /m "オプションなしの最小コマンドで実行しますか？"
if %errorlevel%==1 (
    set filter=alloff
    echo >> オプションなしの最小コマンドで実行します。
    goto SkipFilterSettings
)

rem 30fps→24fps変換設定
rem timeout /nobreak 1 > nul
choice /m "30fpsの動画を24fpsに変換しますか？（注意: -filter_complex は使えません）"
if %errorlevel%==1 goto Convert30to24fps
goto Skip30to24fpsConversion

:Convert30to24fps
echo   【30fps -> 24fps 変換パターン選択】
rem timeout /nobreak 1 > nul
choice /c 1234 /m "変換パターンを選択してください (1:decimate, 2:yadif+decimate, 3:mpdecimate+setpts, 4:mpdecimate)"
set filter=%errorlevel%
echo   >> 30fps->24fps変換パターン %filter% を選択しました。
goto SkipFilterSettings

:Skip30to24fpsConversion
rem 動画フィルター(vf)設定
rem timeout /nobreak 1 > nul
choice /m "vf (ビデオフィルター) を使いますか？（動画のリサイズ、色調補正など）"
if %errorlevel%==2 goto SkipVfSettings
set filter=vf
echo   >> vf (ビデオフィルター) を使用します。
echo   ffmpegの「-vf」オプションとして使用するフィルターを入力してください。
echo   (例: scale=1280:-1,setpts=PTS/2)
echo   (インターレース解除例: yadif,decimate)
set /P vf="   -vfフィルター文字列入力＞ "
if defined vf (
    set vf= -vf "%vf%"
    echo   >> 設定されたビデオフィルター: %vf%
) else (
    echo   >> ビデオフィルターは入力されませんでした。
    set filter=
)
goto SkipFilterSettings

:SkipVfSettings
rem その他の追加引数設定
echo   >> その他のffmpeg引数を追加する場合はスペース区切りで入力してください。
echo   (例: -max_muxing_queue_size 1024)
echo   ※注意: -filter_complex はこのバッチでは基本的なもの以外、直接サポートしていません。
echo   ※      -vf や上記の24fps変換とは併用が難しい場合があります。
set /P argument="   追加引数入力＞ "
if defined argument (
    set argument= %argument%
    echo   >> 追加引数が設定されました: %argument%
) else (
    echo   >> 追加引数はありません。
)

:SkipFilterSettings
echo.
echo ─────────────────────────────────────
echo  全ての初期設定が完了しました。
echo  ドラッグ＆ドロップされたファイルの処理を開始します。
echo ─────────────────────────────────────
timeout /nobreak 3

rem --- メイン処理ループ開始 ---
:roop
cls
rem 出力先フォルダの存在確認と作成 (固定パスの場合)
If "%outputpath%"=="fixed" (
    If not exist "C:\Users\kouki\Videos\エンコード済み" (
        echo >> 固定出力先フォルダ「C:\Users\kouki\Videos\エンコード済み」を作成します...
        mkdir "C:\Users\kouki\Videos\エンコード済み"
    )
)

set /a filecount=filecount+1
echo.
echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
echo  【 %filecount% 個目のファイル処理開始 】
echo  ファイル名: %1
echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
echo.

set Error=0
:ErrorRetry
set /a Error=Error+1
if %Error% GTR 1 (
    echo !! エンコードエラー発生。リトライします。(試行 %Error% 回目)
)

rem --- 出力ディレクトリとffmpegサブフォルダの準備 ---
set current_output_base_dir=
if "%outputpath%"=="fixed" (
    rem 固定出力先の場合、cdは不要。パスを直接指定。
    set current_output_base_dir=C:\Users\kouki\Videos\エンコード済み
    echo >> 出力先ベース: %current_output_base_dir%
) else (
    rem 入力ファイルと同じ場所に出力する場合
    set current_output_base_dir=%~dp1
    rem cd /d "%~dp1"
    echo >> 出力先ベース: %current_output_base_dir% (入力ファイルと同じ場所)
)
rem ffmpeg処理用の一時/出力サブフォルダ名 (スペースや特殊文字を避けるため、固定名が良い)
set ffmpeg_subdir_name=ffmpeg_encoded_output
set full_ffmpeg_output_path=%current_output_base_dir%%ffmpeg_subdir_name%

If not exist "%full_ffmpeg_output_path%" (
    echo >> ffmpeg出力用サブフォルダ「%full_ffmpeg_output_path%」を作成します...
    mkdir "%full_ffmpeg_output_path%"
)

rem --- メタデータファイル処理 (ffmpeg形式の場合) ---
set temp_ffmpeg_metadata_file="%full_ffmpeg_output_path%\%~n1_ffmpeg_metadata.txt"
if "%exiftool%"=="ffmpeg" (
    echo >> ffmpeg ffmetadata を作成中: %temp_ffmpeg_metadata_file%
    ffmpeg -hide_banner -i %1 -f ffmetadata %temp_ffmpeg_metadata_file%
    if errorlevel 1 (
        echo !!! ffmetadataの作成に失敗しました。メタデータなしで続行します。
        set exiftoolCommand=
    ) else (
        set exiftoolCommand=-i %temp_ffmpeg_metadata_file% -map_metadata 1
        echo    ffmetadataオプション: %exiftoolCommand%
    )
)

rem --- 動画カット処理 (LosslessCut呼び出しとタイムコード入力) ---
if "%cut%"=="yes" (
    echo 【動画カット情報入力】
    echo >> LosslessCut を起動してカット位置を確認してください...
    start "" "C:\Users\kouki\OneDrive\PortableApps\LosslessCutPortable\LosslessCutPortable.exe" %1 > nul
    echo    (LosslessCutが起動するまで少々お待ちください)
    echo.
    echo    カットしたいタイムコードを特定し、入力してください。
    echo    (エンドポイントは、指定した時間の直前のフレームまでとなります)
    echo    入力形式の例: 00:00:00.000 (時:分:秒.ミリ秒)
    echo.
    set cutstart=
    set /P cutstart="   開始位置 (例:00:01:15.000)＞ "
    rem timeout /nobreak 1 > nul
    set cutend=
    set /P cutend="   終了位置 (例:00:03:30.500)＞ "
    if defined cutstart if defined cutend (
        set cutinfo=-ss %cutstart% -to %cutend%
        set cutinfo2=-ss 0
        echo    >> カット情報が設定されました: 開始 %cutstart%, 終了 %cutend%
        echo       ffmpegオプション(入力): %cutinfo%
        echo       ffmpegオプション(出力): %cutinfo2% (タイムスタンプリセット用)
    ) else (
        echo    !!! カット位置が正しく入力されませんでした。カットせずに処理します。
        set cut=no
        set cutinfo=
        set cutinfo2=
    )
)

rem --- 音声処理分岐とコマンド設定 ---
echo 【音声処理コマンド設定】
set final_audio_input_options=-i %1
set final_audio_encode_options=
set temp_qaac_output_file="%full_ffmpeg_output_path%\%~n1_qaac_tmp.m4a"
set temp_wav_file="%full_ffmpeg_output_path%\%~n1_temp_for_audio.wav"

rem webm の場合は opus で強制変換 (再チェック)
if /i "%~x1"==".webm" (
    if "%AudioEncode%"=="qaac" (
        echo !! WebMファイルのため、音声設定を qaac から opus に変更します。
        set AudioEncode=opus
    )
)

if "%AudioEncode%"=="copy" (
    echo >> 音声処理: コピー (-c:a copy)
    set final_audio_encode_options=-c:a copy
    goto ProcessAudioDone
)
if "%AudioEncode%"=="null" (
    echo >> 音声処理: 削除 (-an)
    set final_audio_encode_options=-an
    goto ProcessAudioDone
)
if "%AudioEncode%"=="opus" (
    echo >> 音声処理: opus でエンコード (libopus, 192k)
    set final_audio_encode_options=-c:a libopus -b:a 192k%Audiofilter%
    goto ProcessAudioDone
)
if "%AudioEncode%"=="qaac" (
    echo >> 音声処理: qaac でエンコード
    rem qaac処理の前準備 (必要に応じてwavに変換)
    set needs_wav_conversion=no
    if "%cut%"=="yes" (set needs_wav_conversion=yes)
    if "%af%"=="yes" (set needs_wav_conversion=yes)
    if /i not "%~x1"==".mov" if /i not "%~x1"==".mp4" if /i not "%~x1"==".m4a" (
        set needs_wav_conversion=yes
    )

    if "%needs_wav_conversion%"=="yes" (
        echo    >> qaac前処理: 元音声を一時WAVファイルに変換します...
        echo       変換コマンド: ffmpeg -hide_banner %cutinfo% -i "%~1" %cutinfo2% -vn %Audiofilter% -f wav "%temp_wav_file%"
        ffmpeg -hide_banner %cutinfo% -i "%~1" %cutinfo2% -vn %Audiofilter% -f wav "%temp_wav_file%"
        if errorlevel 1 (
            echo    !!! 一時WAVファイルへの変換に失敗しました。音声をコピーして続行します。
            set final_audio_encode_options=-c:a copy
            goto ProcessAudioDone
        )
        echo    >> qaac処理中 (WAVからエンコード): %temp_qaac_output_file%
        qaac64%qaacencoder% "%temp_wav_file%" -o "%temp_qaac_output_file%"
        del "%temp_wav_file%"
    ) else if /i "%~x1"==".mov" (
        echo    >> qaac前処理: MOV内の音声を一時WAVファイルにコピーします...
        ffmpeg -hide_banner %cutinfo% -i "%~1" %cutinfo2% -vn -c:a copy "%temp_wav_file%"
        if errorlevel 1 (
            echo    !!! MOV音声の抽出に失敗しました。音声をコピーして続行します。
            set final_audio_encode_options=-c:a copy
            goto ProcessAudioDone
        )
        echo    >> qaac処理中 (WAVからエンコード): %temp_qaac_output_file%
        qaac64%qaacencoder% "%temp_wav_file%" -o "%temp_qaac_output_file%"
        del "%temp_wav_file%"
    ) else if /i "%~x1"==".mp4" or /i "%~x1"==".m4a" (
        echo    >> qaac処理中 (元ファイルから直接エンコード): %temp_qaac_output_file%
        qaac64%qaacencoder% "%~1" -o "%temp_qaac_output_file%"
        if errorlevel 1 (
            echo    !!! qaacエンコードに失敗しました。音声をコピーして続行します。
            set final_audio_encode_options=-c:a copy
            goto ProcessAudioDone
        )
    ) else (
        echo    !!! 未対応の音声処理パターンです。音声をコピーして続行します。
        set final_audio_encode_options=-c:a copy
        goto ProcessAudioDone
    )

    rem qaac処理成功後のffmpegオプション設定
    if exist "%temp_qaac_output_file%" (
        set final_audio_input_options=-i %1 -i "%temp_qaac_output_file%"
        set final_audio_encode_options=-c:a copy -map 0:v -map 1:a
        echo    >> qaacでエンコードされた音声を使用します。
    ) else (
        echo    !!! qaac出力ファイルが見つかりません。音声をコピーして続行します。
        set final_audio_encode_options=-c:a copy
    )
)
:ProcessAudioDone
echo    最終音声入力オプション: %final_audio_input_options%
echo    最終音声エンコードオプション: %final_audio_encode_options%
echo.

rem --- ffmpeg エンコードコマンド実行 ---
echo 【ffmpeg エンコード実行】
set ffmpeg_output_filename="%full_ffmpeg_output_path%\%~n1.%extension%"
set ffmpeg_common_opts=-g 150 -qcomp 0.7 -qmin 0 -qmax 80 -qdiff 4 -subq 6 -me_range 16 -i_qfactor 0.714286 -map_chapters -1
rem %tune% は ffmpeg 5.0 以降非推奨のため、基本的には空または削除。ここでは元バッチの構造を維持。
set tune_option=

set final_ffmpeg_command=ffmpeg -hide_banner %cutinfo% %final_audio_input_options% %exiftoolCommand% %cutinfo2% %encoder% %ffmpeg_common_opts%

if "%filter%"=="alloff" (
    echo >> フィルター: オプションなしの最小コマンド
    set final_ffmpeg_command=%final_ffmpeg_command% %final_audio_encode_options% %argument% %ffmpeg_output_filename%
) else if "%filter%"=="vf" (
    echo >> フィルター: カスタムビデオフィルター (%vf%)
    set final_ffmpeg_command=%final_ffmpeg_command% %vf% %final_audio_encode_options% %argument% %ffmpeg_output_filename%
) else if "%filter%"=="1" (
    echo >> フィルター: 30->24fps (パターン1: decimate)
    set final_ffmpeg_command=%final_ffmpeg_command% -vf decimate=cycle=5:dupthresh=1.1:scthresh=15:blockx=32:blocky=32:ppsrc=0:chroma=1 %final_audio_encode_options% %argument% %ffmpeg_output_filename%
) else if "%filter%"=="2" (
    echo >> フィルター: 30->24fps (パターン2: yadif,decimate)
    set final_ffmpeg_command=%final_ffmpeg_command% -vf yadif=0:-1:1,decimate %final_audio_encode_options% %argument% %ffmpeg_output_filename%
) else if "%filter%"=="3" (
    echo >> フィルター: 30->24fps (パターン3: mpdecimate,setpts)
    set final_ffmpeg_command=%final_ffmpeg_command% -vf mpdecimate,setpts=N/FRAME_RATE/TB %final_audio_encode_options% %argument% %ffmpeg_output_filename%
) else if "%filter%"=="4" (
    echo >> フィルター: 30->24fps (パターン4: mpdecimate)
    set final_ffmpeg_command=%final_ffmpeg_command% -vf mpdecimate %final_audio_encode_options% %argument% %ffmpeg_output_filename%
) else (
    rem デフォルト (フィルター指定なし、または引数のみ)
    echo >> フィルター: 指定なし (基本フィルターまたは追加引数のみ)
    rem 元バッチではこの場合に -filter_complex setpts=PTS-SkipStartPTS%tune% があった
    rem tune_option は空なので、実質 -filter_complex setpts=PTS-SkipStartPTS
    rem ただし、他の -vf との競合や、-ss 0 (cutinfo2) との役割重複の可能性あり。
    rem ここでは元に倣いつつ、もし %argument% に -filter_complex があればそちらを優先するイメージ。
    if not defined argument if not defined vf (
        echo    (デフォルトのタイムスタンプ調整フィルター -filter_complex setpts=PTS-STARTPTS を適用)
        set final_ffmpeg_command=%final_ffmpeg_command% -filter_complex setpts=PTS-STARTPTS %final_audio_encode_options% %argument% %ffmpeg_output_filename%
    ) else (
        set final_ffmpeg_command=%final_ffmpeg_command% %final_audio_encode_options% %argument% %ffmpeg_output_filename%
    )
)

echo.
echo    実行するffmpegコマンド (長いため主要部のみ表示の可能性あり):
echo    %final_ffmpeg_command%
echo.
echo    エンコード処理を開始します... しばらくお待ちください。
@echo on
%final_ffmpeg_command%
@echo off

if errorlevel 1 (
    echo !!! ffmpegエンコード中にエラーが発生しました。 (エラーコード: %errorlevel%)
    goto ErrorRe
)
echo >> ffmpegエンコードが正常に完了しました: %ffmpeg_output_filename%
:ffmpegend

rem --- 後処理 ---
echo 【後処理実行】
if "%cut%"=="yes" (
    echo >> カット処理完了通知 (C:\Users\kouki\OneDrive\CUIApplication\notify.bat の呼び出しを想定)
    rem call C:\Users\kouki\OneDrive\CUIApplication\notify.bat [%filecount%]Next_Cut
)

rem 日付等追加データを以前のファイルからコピー (ExifTool)
if "%exiftool%"=="yes" (
    echo >> ExifToolを使用してメタデータをコピーしています...
    exiftool -api largefilesupport=1 -tagsfromfile %1 -all:all -overwrite_original %ffmpeg_output_filename%
    echo    ExifTool処理完了。
)
rem 一時メタデータファイルの削除
if "%exiftool%"=="ffmpeg" (
    if exist %temp_ffmpeg_metadata_file% (
        echo >> 一時ffmpegメタデータファイル %temp_ffmpeg_metadata_file% を削除します。
        del %temp_ffmpeg_metadata_file%
    )
)
rem 一時qaac出力ファイルの削除
if exist %temp_qaac_output_file% (
    echo >> 一時qaac音声ファイル %temp_qaac_output_file% を削除します。
    del %temp_qaac_output_file%
)

echo.
echo  ファイル「%~n1%~x1」の処理が完了しました。
echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
echo.

shift
if not "%~1"=="" (
    echo >> 次のファイルの処理へ移ります...
    goto roop
)

echo >> 全てのファイルの処理が完了しました。
goto exit_sequence

rem --- エラーリトライ処理 ---
:ErrorRe
if "%Error%"=="2" (
    echo !!! エンコードエラーが2回発生したため、このファイルの処理をスキップします。
    echo    通知: [%filecount%]EncodeError_next (C:\Users\kouki\OneDrive\CUIApplication\notify.bat の呼び出しを想定)
    rem call C:\Users\kouki\OneDrive\CUIApplication\notify.bat [%filecount%]EncodeError_next
    goto ffmpegend rem 後処理は行う
)
echo !! エンコードエラーのため、5秒後にリトライします。
echo    通知: [%filecount%]EncodeError_Retry (C:\Users\kouki\OneDrive\CUIApplication\notify.bat の呼び出しを想定)
rem call C:\Users\kouki\OneDrive\CUIApplication\notify.bat [%filecount%]EncodeError_Retry
timeout /nobreak 5
goto ErrorRetry


rem --- 終了処理シーケンス ---
:exit_sequence
echo.
echo ─────────────────────────────────────
echo  全処理終了
echo ─────────────────────────────────────
echo    通知: [%filecount%]encode_end (C:\Users\kouki\OneDrive\CUIApplication\notify.bat の呼び出しを想定)
rem call C:\Users\kouki\OneDrive\CUIApplication\notify.bat [%filecount%]encode_end

rem シャットダウンをする場合
if "%shutdown%"=="yes" (
    echo >> シャットダウンシーケンス開始...
    echo    通知: go_shutdown (C:\Users\kouki\OneDrive\CUIApplication\notify.bat の呼び出しを想定)
    rem call C:\Users\kouki\OneDrive\CUIApplication\notify.bat go_shutdown
    echo    20秒後にシャットダウンします。キャンセルする場合はコマンドプロンプトを閉じてください。
    shutdown -s -t 20
    echo    (15秒間の待機後、バッチを終了します)
    timeout /nobreak 15
    goto exit_script
)

rem 何も指定していない場合 (休止モード移行オプション)
echo.
echo 【終了オプション】
echo 3分以内にZキーを押すと、このウィンドウを閉じずに待機します。
echo それ以外のキーを押すか、何も操作しない場合、休止モードに移行します。
choice /c zh /m "[Z]キーで待機 / [H]キー(またはタイムアウト)で休止モード" /n /t 180 /d h
if %errorlevel%==1 (
    echo >> Zキーが押されました。休止モードへの移行をキャンセルし、待機します。
)
if %errorlevel%==2 (
    echo >> 休止モードへ移行します...
    echo    通知: go_hibernate_mode (C:\Users\kouki\OneDrive\CUIApplication\notify.bat の呼び出しを想定)
    rem call C:\Users\kouki\OneDrive\CUIApplication\notify.bat go_hibernate_mode
    rundll32.exe PowrProf.dll,SetSuspendState
    rem 休止から復帰後、ここに処理が戻る場合がある
)

:exit_script
echo >> バッチ処理を終了します。
pause
exit