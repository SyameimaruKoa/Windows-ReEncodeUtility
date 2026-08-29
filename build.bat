@echo off
rem ================================================================
rem [Note] このスクリプトの詳しい使い方は末尾の :show_help に記載されています。
rem ================================================================

if "%~1"=="-h" goto show_help
if "%~1"=="--help" goto show_help
if "%~1"=="/?" goto show_help

echo [BUILD] Windows-ReEncodeUtility の Pure Go ビルドを開始します...
set CGO_ENABLED=0
go build -ldflags="-s -w" -o ReEncodeUtility.exe ./src/cmd/reencode
if errorlevel 1 goto build_error

echo [SUCCESS] ビルドが正常に完了しました: ReEncodeUtility.exe
exit /b 0

:build_error
echo [ERROR] ビルド中にエラーが発生しました。
exit /b 1

:show_help
echo ================================================================================
echo   Windows-ReEncodeUtility ビルドバッチ (build.bat) ヘルプ
echo ================================================================================
echo.
echo [概要]
echo   CGO_ENABLED=0 による Go 単一バイナリ (ReEncodeUtility.exe) をビルドします。
echo   GCC などの C コンパイラ不要で、Go 1.22+ 環境で 1～2 秒でビルド可能です。
echo.
echo [使用方法]
echo   build.bat           : 本ビルドを実行します。
echo   build.bat -h        : このヘルプを表示します。
echo   build.bat --help    : このヘルプを表示します。
echo.
echo [成果物]
echo   ReEncodeUtility.exe (約 10MB ～ 12MB の単一実行バイナリ)
echo.
echo ================================================================================
exit /b 0
