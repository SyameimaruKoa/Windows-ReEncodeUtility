#!/usr/bin/env bash
# ヘルプは下部の show_help() に実装してある。

show_help() {
    cat <<'EOF'
========================================================
 動画再エンコード スクリプト (re-encode-AIOptimus)
========================================================

使い方:
  start.sh [オプション] <動画ファイル> [動画ファイル2] ...

説明:
  FFmpeg を使用して動画ファイルを一括で再エンコードする。
  PowerShell 7 (pwsh) と ffmpeg / ffprobe が必要じゃ。
  引数なし、または -h / --help でこのヘルプを表示する。

対応モード:
  - 通常モード        : 対話形式でエンコード設定を選択
  - テンプレート      : 保存済みの設定テンプレートを使用
  - プラットフォーム  : Twitter/Discord/catbox.moe/uguu.se/GitHub 向け最適化
  - 中間ファイル      : 高画質 MKV 中間ファイルを作成
  - 分割モード        : チャプター/字幕で分割して再エンコード
  - 外部音声同期      : 外部音声を波形で同期し MKV へ合成

ハードウェア:
  Linux では VAAPI と、FFmpeg が検出した NVENC / QSV を選択できる。
  Media Foundation / D3D11VA / D3D12VA / DXVA2 は Windows 専用じゃ。

設定ファイル:
  config.user.linux.psd1  - ffmpeg / fdkaac / VAAPI デバイスの設定
  Profiles/*.psd1         - エンコード設定テンプレート

例:
  ./start.sh -h
  ./start.sh /path/to/input.mp4
  ./start.sh /path/to/video1.mkv /path/to/video2.mp4
EOF
}

case "${1:-}" in
    -h|--help|'/?')
        show_help
        exit 0
        ;;
    '')
        show_help
        exit 0
        ;;
esac

if ! command -v pwsh >/dev/null 2>&1; then
    echo "エラー: PowerShell 7 (pwsh) が見つかりません。" >&2
    echo "https://aka.ms/powershell からインストールしてください。" >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/re-encode-AIOptimus.ps1" "$@"
