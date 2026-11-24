@echo off
chcp 932 >nul 2>&1
REM ヘルプは下部に実装

if "%~1"=="" goto :show_help
if "%~1"=="/?" goto :show_help
if /I "%~1"=="-h" goto :show_help
if /I "%~1"=="--help" goto :show_help
if /I "%~1"=="--check" goto :check

echo エラー: 不明なオプション '%~1'。
goto :show_help

:check
echo 必須:
call :check_command pwsh "winget install Microsoft.PowerShell"
call :check_command ffmpeg "winget install Gyan.FFmpeg"
call :check_command ffprobe "ffmpeg に付属。PATH を確認"

echo.
echo オプション:
call :check_command python "winget install Python.Python.3.12 (tkinter 同梱)"
call :check_python_tk
call :check_command ffplay "ffmpeg に付属。PATH を確認"
call :check_command exiftool "winget install ExifTool.ExifTool"
goto :eof

:check_command
where %~1 >nul 2>&1
if errorlevel 1 (
    echo   [不足] %~1  %~2
) else (
    echo   [OK]   %~1
)
goto :eof

:check_python_tk
where python >nul 2>&1
if errorlevel 1 (
    echo   [不足] tkinter  Python をインストールすると同梱される
    goto :eof
)
python -c "import tkinter" >nul 2>&1
if errorlevel 1 (
    echo   [不足] tkinter  Python インストール時に tcl/tk を有効にする
) else (
    echo   [OK]   tkinter
)
goto :eof

:show_help
echo.
echo ========================================================
echo  動画再エンコード 依存関係チェック (Windows)
echo ========================================================
echo.
echo 使い方:
echo  install.bat [--check]
echo.
echo オプション:
echo  --check       依存関係をチェックして結果を表示する。
echo  -h, --help    このヘルプを表示して終了する。
echo  (引数なし)    このヘルプを表示して終了する。
echo.
echo 説明:
echo  必須・オプションのコマンドを調べ、不足しているものの
echo  インストール方法を表示する。実際のインストールは行わない。
echo.
echo 必須:
echo  pwsh, ffmpeg, ffprobe
echo.
echo オプション:
echo  python + tkinter (FFplay比較GUI), ffplay, exiftool
echo.
pause
goto :eof
