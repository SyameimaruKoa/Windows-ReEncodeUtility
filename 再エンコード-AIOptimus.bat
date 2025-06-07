@echo off
rem ffmpeg一括再エンコードVer7.1 (わっち改修版・変数利用対策)
rem このバッチファイルは、複数の動画ファイルをffmpegで一括再エンコードします。
rem 最初にエンコードオプションを設定し、その後ファイルごとに処理を実行します。

rem --- 文字コード設定 ---
chcp 932

rem --- ループ内で変数を正しく扱うためのおまじない ---
setlocal enabledelayedexpansion

rem --- ▼ ユーザー設定 ▼ ---
rem LosslessCutや通知アプリのパスを自分の環境に合わせて設定してください。
set losslesscut_path="C:\Path\To\LosslessCut\LosslessCut.exe"
set notify_script_path=""
rem --- ▲ ユーザー設定 ▲ ---


:root
rem --- 初期設定 ---
echo ─────────────────────────────────────
echo  FFmpeg 一括再エンコード処理 開始 (わっち改修版)
echo ─────────────────────────────────────
echo.

rem 外部バッチファイルでエンコードオプションを設定
echo エンコードオプションを設定します...
call "%~dp0ffmpegエンコードオプション-AIOptimus.bat"
if "!encoder!"=="" (
    echo エラー: エンコードオプションが設定されませんでした。処理を中止します。
    pause
    exit /b
)
echo エンコードオプションが設定されました: !encoder!
echo.

rem --- 出力先フォルダ設定 ---
set output_mode=subfolder
choice /m "出力先を固定しますか？ (Y:固定 / N:入力元と同じ階層のsubfolder)"
if %errorlevel%==1 (
    set /p output_fixed_path="固定出力先のパスを入力してください > "
    if not defined output_fixed_path (
        echo エラー: パスが入力されませんでした。処理を中止します。
        pause
        exit /b
    )
    if not exist "!output_fixed_path!" mkdir "!output_fixed_path!"
    set output_mode=fixed
    echo 出力先は固定フォルダ「!output_fixed_path!」です。
) else (
    echo 出力先は各動画ファイルの存在するフォルダ内の「encoded_output」サブフォルダです。
)
echo.

rem --- 処理後アクション設定 ---
set after_process_action=none
choice /c srh /m "エンコード完了後どうしますか？ (S:シャットダウン, R:再起動, H:休止)"
if %errorlevel%==1 set after_process_action=shutdown
if %errorlevel%==2 set after_process_action=reboot
if %errorlevel%==3 set after_process_action=hibernate
if "!after_process_action!"=="none" (
    echo エンコード完了後、何もしません。
) else (
    echo エンコード完了60秒後に !after_process_action! します。
)
echo.

rem --- 出力拡張子設定 ---
set extension=mp4
choice /m "拡張子をMOVにしますか？ (Y:MOV / N:MP4)"
if %errorlevel%==1 (
    set extension=mov
    echo 出力ファイルの拡張子は .mov です。
) else (
    echo 出力ファイルの拡張子は .mp4 です。
)
echo.

rem --- 音声エンコード設定 ---
set AudioEncode=
set qaacencoder=
set Audiofilter=
echo --- 音声エンコード設定 ---
choice /c yn0 /m "音声も再エンコードしますか？ (Y:qaac / N:音声をコピー / 0:音声を削除)"
if %errorlevel%==1 set AudioEncode=qaac
if %errorlevel%==2 set AudioEncode=copy
if %errorlevel%==3 set AudioEncode=null

if "!AudioEncode!"=="qaac" (
    echo 音声は qaac で再エンコードします。
    goto qaacoption
)
if "!AudioEncode!"=="copy" (
    set "msg=音声はそのままコピーします (-c:a copy)。"
    echo !msg!
    goto SkipAudioSettings
)
if "!AudioEncode!"=="null" (
    set "msg=音声は削除します (-an)。"
    echo !msg!
    goto SkipAudioSettings
)

:qaacoption
echo --- qaac オプション設定 ---
choice /c 12 /m "qaacのエンコーダータイプを選択 (1:AAC-LC / 2:HE-AAC)"
if %errorlevel%==1 set qaacencoder=
if %errorlevel%==2 set qaacencoder=--he

choice /m "qaacで音声フィルター(-af)を使いますか？"
if %errorlevel%==1 (
    set "msg=複数指定する場合はカンマ(,)で区切ってください (例: atempo=2.0,volume=0.5)"
    echo !msg!
    set /P Audiofilter="ffmpegの-afフィルター文字列入力 > "
    if defined Audiofilter (
        set Audiofilter=-af "!Audiofilter!"
        echo   設定された音声フィルター: !Audiofilter!
    )
)
goto SkipAudioSettings

:SkipAudioSettings
echo.

rem --- 動画カット設定 ---
set cut=no
set cutinfo=
set cutinfo2=
choice /m "動画をカットしますか？ (LosslessCutを使用)"
if %errorlevel%==1 (
    set cut=yes
    echo 動画をカットします。後ほど開始位置と終了位置を入力します。
) else (
    echo 動画はカットしません。
)
echo.

rem --- 動画メタデータ保持設定 ---
set exiftool=no
choice /c fen /m "動画のメタデータ(撮影日時など)を保持しますか？ (F:ffmpeg形式 / E:ExifToolで全コピー / N:保持しない)"
if %errorlevel%==1 set exiftool=ffmpeg
if %errorlevel%==2 set exiftool=yes
if "!exiftool!"=="ffmpeg" echo 動画メタデータは ffmpeg の ffmetadata 形式で一部保持・復元します。
if "!exiftool!"=="yes" echo 動画メタデータは ExifTool を使用して元ファイルから可能な限りコピーします。
if "!exiftool!"=="no" echo 動画メタデータは保持しません。
echo.

rem --- 追加フィルター/オプション設定 ---
set filter_option=none
set vf=
set argument=
choice /m "追加のビデオフィルター(-vf)やオプションを使いますか？"
if %errorlevel%==1 (
    set "msg=  ffmpegの「-vf」として使用するフィルターを入力してください (例: scale=1280:-1)。"
    echo !msg!
    set /p vf="   -vfフィルター文字列入力 > "
    if defined vf set vf=-vf "!vf!"

    set "msg=  その他のffmpeg引数を追加する場合はスペース区切りで入力してください (例: -max_muxing_queue_size 1024)。"
    echo !msg!
    set /p argument="   追加引数入力 > "
)
echo.
echo ─────────────────────────────────────
echo  全ての初期設定が完了しました。
echo  ドラッグ＆ドロップされたファイルの処理を開始します。
echo ─────────────────────────────────────
timeout /nobreak 3

rem --- メイン処理ループ開始 ---
set filecount=0
for %%F in (%*) do (
    set /a filecount+=1
    cls
    echo.
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    echo  [ !filecount! / %~#* 個目のファイル処理開始 ]
    echo  ファイル名: "%%~nxF"
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    echo.

    set input_file="%%~F"
    set input_dir="%%~dpF"
    set input_name="%%~nF"

    rem --- 出力パスの決定 ---
    set output_dir=
    if "!output_mode!"=="fixed" (
        set output_dir="!output_fixed_path!"
    ) else (
        set output_dir="!input_dir!encoded_output"
        if not exist !output_dir! mkdir !output_dir!
    )
    set output_file="!output_dir!\!input_name!.!extension!"
    set temp_dir="!output_dir!\temp_!input_name!"
    if not exist !temp_dir! mkdir !temp_dir!

    rem --- 各種設定のリセットと準備 ---
    set current_cutinfo=
    set current_cutinfo2=
    set exiftoolCommand=
    set final_audio_input_options=-i !input_file!
    set final_audio_encode_options=
    set temp_qaac_output_file="!temp_dir!\qaac_tmp.m4a"
    set temp_wav_file="!temp_dir!\temp_audio.wav"
    set temp_ffmpeg_metadata_file="!temp_dir!\ffmpeg_metadata.txt"

    rem --- メタデータファイル処理 (ffmpeg形式) ---
    if "!exiftool!"=="ffmpeg" (
        echo ffmetadataを作成中...
        ffmpeg -hide_banner -i !input_file! -f ffmetadata "!temp_ffmpeg_metadata_file!"
        if not errorlevel 1 (
            set exiftoolCommand=-i "!temp_ffmpeg_metadata_file!" -map_metadata 1
            echo    ffmetadataオプション: !exiftoolCommand!
        ) else (
            echo 警告: ffmetadataの作成に失敗しました。
        )
    )

    rem --- 動画カット処理 ---
    if "!cut!"=="yes" (
        echo --- 動画カット情報入力 ---
        echo LosslessCutを起動します。カット位置を確認してください...
        start "" !losslesscut_path! !input_file!
        echo.
        set /p cutstart="   開始位置 (例:00:01:15.000) > "
        set /p cutend="   終了位置 (例:00:03:30.500) > "
        if defined cutstart if defined cutend (
            set current_cutinfo=-ss !cutstart! -to !cutend!
            set current_cutinfo2=-ss 0
            echo    カット情報: 開始 !cutstart!, 終了 !cutend!
        ) else (
            echo    警告: カット位置が未入力のため、カットしません。
        )
    )

    rem --- 音声処理 ---
    echo --- 音声処理コマンド設定 ---
    set use_audio_option=!AudioEncode!
    if /i "%%~xF"==".webm" if "!use_audio_option!"=="qaac" (
        echo 情報: WebMファイルのため、音声をqaacからopusに強制変更します。
        set use_audio_option=opus
    )

    if "!use_audio_option!"=="copy" (
        set final_audio_encode_options=-c:a copy
    ) else if "!use_audio_option!"=="null" (
        set final_audio_encode_options=-an
    ) else if "!use_audio_option!"=="opus" (
        set final_audio_encode_options=-c:a libopus -b:a 192k !Audiofilter!
    ) else if "!use_audio_option!"=="qaac" (
        echo qaacでエンコード処理中...
        rem qaacはパイプ非対応なので一時ファイルを作成する
        echo    一時WAVファイルに変換しています...
        ffmpeg -hide_banner !current_cutinfo! -i !input_file! -vn !Audiofilter! -f wav "!temp_wav_file!"
        if not errorlevel 1 (
            qaac64 !qaacencoder! "!temp_wav_file!" -o "!temp_qaac_output_file!"
            if not errorlevel 1 (
                set final_audio_input_options=-i !input_file! -i "!temp_qaac_output_file!"
                set final_audio_encode_options=-c:a copy -map 0:v:0 -map 1:a:0
                echo    qaacでエンコードされた音声を使用します。
            ) else (
                echo エラー: qaacエンコードに失敗。音声をコピーします。
                set final_audio_encode_options=-c:a copy
            )
        ) else (
            echo エラー: 一時WAVへの変換に失敗。音声をコピーします。
            set final_audio_encode_options=-c:a copy
        )
    )
    echo    最終音声オプション: !final_audio_encode_options!

    rem --- ffmpeg エンコードコマンド実行 ---
    echo --- ffmpeg エンコード実行 ---
    set final_ffmpeg_command=ffmpeg -hide_banner !current_cutinfo! !final_audio_input_options! !exiftoolCommand! !current_cutinfo2! !encoder! !vf! !argument! !final_audio_encode_options! !output_file!
    
    echo.
    echo    実行コマンド:
    echo    !final_ffmpeg_command!
    echo.
    echo    エンコード処理を開始します...
    @echo on
    !final_ffmpeg_command!
    @echo off

    if not errorlevel 1 (
        echo ffmpegエンコードが正常に完了しました。
        
        rem --- 後処理 ---
        echo --- 後処理実行 ---
        if "!exiftool!"=="yes" (
            echo ExifToolでメタデータをコピーしています...
            exiftool -api largefilesupport=1 -tagsfromfile "%%~F" -all:all -overwrite_original !output_file!
        )
        rem 一時フォルダの削除
        if exist "!temp_dir!" (
            rd /s /q "!temp_dir!"
            echo 一時ファイルをクリーンアップしました。
        )
        if exist "!output_dir!\*.*_original" del "!output_dir!\*.*_original"

    ) else (
        echo エラー: ffmpegエンコード中にエラーが発生しました。
        if exist !notify_script_path! call !notify_script_path! "!filecount! EncodeError"
    )

    echo.
    echo  ファイル「%%~nxF」の処理が完了しました。
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    echo.
    pause
)

echo.
echo ─────────────────────────────────────
echo  全てのファイルの処理が完了しました。
echo ─────────────────────────────────────
if exist !notify_script_path! call !notify_script_path! "All encode ended"

rem --- 終了処理 ---
if "!after_process_action!"=="shutdown" (
    echo 60秒後にシャットダウンします。
    shutdown -s -t 60
) else if "!after_process_action!"=="reboot" (
    echo 60秒後に再起動します。
    shutdown -r -t 60
) else if "!after_process_action!"=="hibernate" (
    echo 休止モードへ移行します...
    rundll32.exe PowrProf.dll,SetSuspendState
)

:exit_script
echo バッチ処理を終了します。
pause
exit
