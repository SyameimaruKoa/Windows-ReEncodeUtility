@echo off
chcp 65001 >nul 2>&1
REM ヘルプは下部に実装

REM 引数なし or /? or -h or --help でヘルプ表示
if "%~1"=="" goto :show_help
if "%~1"=="/?" goto :show_help
if /I "%~1"=="-h" goto :show_help
if /I "%~1"=="--help" goto :show_help

powershell -ExecutionPolicy Bypass -File "%~dp0re-encode-AIOptimus.ps1" %*
goto :eof

:show_help
echo.
echo ========================================================
echo  動画再エンコード スクリプト (re-encode-AIOptimus)
echo ========================================================
echo.
echo 使い方:
echo  start.bat ^<動画ファイル^> [動画ファイル2] ...
echo.
echo 説明:
echo  FFmpegを利用して、動画ファイルを一括で再エンコードします。
echo  ドラッグ＆ドロップで動画ファイルを渡すか、コマンドラインから
echo  ファイルパスを指定してください。
echo.
echo 対応モード:
echo  - 通常モード  : 対話形式でエンコード設定を選択
echo  - テンプレート  : 保存済みの設定テンプレートを使用
echo  - 中間ファイル  : 高画質MKV中間ファイルを作成
echo  - 分割モード  : チャプター/字幕で分割して再エンコード
echo.
echo 対応ハードウェアエンコード:
echo  NVIDIA (NVENC), Intel (QSV), AMD (AMF), CPU (Software)
echo.
echo 設定ファイル:
echo  config.user.psd1  - ffmpeg等のパス設定
echo  *.psd1  - エンコード設定テンプレート
echo.
echo 例:
echo  start.bat "C:\Videos\input.mp4"
echo  start.bat "C:\Videos\video1.mp4" "C:\Videos\video2.mkv"
echo.
pause
