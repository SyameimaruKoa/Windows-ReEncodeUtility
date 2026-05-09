# Windows-ReEncodeUtility

ドラッグ＆ドロップした動画ファイルを、FFmpeg を使って一括で再エンコードするための PowerShell ユーティリティです。

## 概要

- `re-encode-AIOptimus.ps1` がメインの実行スクリプトです。
- `get-ffmpegOptions.ps1` で映像・音声のエンコード設定を対話的に選びます。
- `config.user.psd1` に FFmpeg / FFprobe / 外部エンコーダーのパスを設定します。
- テンプレート、事前チェック、ログ出力、中間ファイル作成、チャプターや SRT に基づく分割処理に対応しています。

## 使い方

1. `config.user.psd1` で各種パスを設定します。
2. `start.bat` か `re-encode-AIOptimus.ps1` を実行します。
3. 処理対象の動画ファイルまたはフォルダを指定します。
4. 対話メニューで映像・音声・ハードウェア・分割方式などを選択します。

## 主なファイル

- `re-encode-AIOptimus.ps1` - 再エンコード本体
- `get-ffmpegOptions.ps1` - エンコード設定メニュー
- `config.user.psd1` - 環境依存設定
- `start.bat` - 起動用バッチ

## 実装履歴

詳細は [IMPLEMENTATION_HISTORY.md](IMPLEMENTATION_HISTORY.md) を参照してください。
