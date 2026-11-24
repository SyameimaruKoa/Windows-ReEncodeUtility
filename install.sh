#!/usr/bin/env bash
# ヘルプは下部の show_help() に実装してある。

show_help() {
    cat <<'EOF'
========================================================
 動画再エンコード 依存関係チェック (Linux)
========================================================

使い方:
  ./install.sh [option]

オプション:
  --check       依存関係をチェックして結果を表示する。
  -h, --help    このヘルプを表示して終了する。
  (引数なし)    このヘルプを表示して終了する。

説明:
  必須・オプションのコマンドを調べ、不足しているものの
  インストール方法を表示する。実際のインストールは行わない。

必須:
  pwsh      PowerShell 7
  ffmpeg    動画エンコード
  ffprobe   動画情報取得

オプション:
  python3   FFplay比較GUIの実行
  tkinter   FFplay比較GUI (apt install python3-tk)
  ffplay    FFplay比較 (ffmpeg に付属)
  exiftool  メタデータ保持
  fdkaac    Linux ネイティブ AAC エンコーダー

シンボリックリンク登録:
  sudo ./SETUP.SH -i
EOF
}

case "${1:-}" in
    --check)
        ;;
    -h|--help|'')
        show_help
        exit 0
        ;;
    *)
        echo "エラー: 不明なオプション '$1'。" >&2
        show_help
        exit 1
        ;;
esac

check_command() {
    local label="$1"
    local cmd="$2"
    local hint="$3"
    if command -v "$cmd" >/dev/null 2>&1; then
        printf '  [OK]   %-10s %s\n' "$label" "$(command -v "$cmd")"
    else
        printf '  [不足] %-10s %s\n' "$label" "$hint"
    fi
}

echo "必須:"
check_command pwsh pwsh "https://aka.ms/powershell から PowerShell 7 をインストール"
check_command ffmpeg ffmpeg "apt install ffmpeg または https://ffmpeg.org/download.html"
check_command ffprobe ffprobe "ffmpeg に付属。PATH を確認"

echo ""
echo "オプション:"
check_command python3 python3 "apt install python3"
if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import tkinter' >/dev/null 2>&1; then
        echo "  [OK]   tkinter    $(python3 -c 'import tkinter; print(tkinter.__file__)')"
    else
        echo "  [不足] tkinter    apt install python3-tk"
    fi
else
    echo "  [不足] tkinter    apt install python3-tk"
fi
check_command ffplay ffplay "ffmpeg に付属。PATH を確認"
check_command exiftool exiftool "apt install libimage-exiftool-perl"
check_command fdkaac fdkaac "apt install fdkaac"
