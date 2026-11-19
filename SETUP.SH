#!/usr/bin/env bash
#
# このスクリプトは、自身と同じディレクトリにある .sh ファイルへの
# シンボリックリンクを /usr/local/bin に作成（接頭辞 "ReEncode_" を付与）、
# または削除する。自身は対象外じゃ。
#

show_help() {
    cat <<EOF
Usage: sudo $(basename "$0") [option]

Description:
    このディレクトリにある .sh ファイルへのシンボリックリンクを
    /usr/local/bin に作成、または削除する。
    リンク名には "ReEncode_" の接頭辞が付く。
    例: start.sh -> /usr/local/bin/ReEncode_start.sh

Options:
    -i, --install    シンボリックリンクを作成・更新する。
                     管理下から削除されたスクリプトの孤立リンクも掃除する。
    -u, --uninstall  シンボリックリンクを削除する。
    -h, --help       このヘルプを表示して終了する。

注意: システムディレクトリを変更するため root 権限 (sudo) が必要じゃ。
EOF
}

require_commands() {
    local missing=0
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "エラー: 必須コマンド '$cmd' が見つかりません。" >&2
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
}

require_commands id basename dirname readlink find ln chmod rm

# ヘルプは root 権限が無くても表示する
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_help
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "エラー: このスクリプトは root 権限で実行する必要がある。" >&2
    echo "コマンドの前に sudo を付けて再実行せよ。" >&2
    echo ""
    show_help
    exit 1
fi

self_name=$(basename "$0")
script_dir=$(dirname "$(readlink -f -- "$0")")

list_scripts() {
    find "$script_dir" -maxdepth 1 -type f -name '*.sh' -not -name "$self_name" -print0
}

cleanup_orphans() {
    echo "管理下から削除されたスクリプトの古いリンクを掃除する..."
    local cleaned=0
    local linkpath target sourcename
    for linkpath in /usr/local/bin/ReEncode_*.sh; do
        [ -L "$linkpath" ] || continue
        target=$(readlink -f -- "$linkpath" 2>/dev/null || true)
        case "$target" in
            "$script_dir"/*) ;;
            *) continue ;;
        esac
        sourcename=$(basename "$linkpath")
        sourcename=${sourcename#ReEncode_}
        if [ ! -f "$script_dir/$sourcename" ]; then
            echo "孤立リンクを削除: $sourcename"
            rm -f -- "$linkpath"
            cleaned=$((cleaned + 1))
        fi
    done
    echo "削除した孤立リンク: $cleaned 件"
}

install_links() {
    cleanup_orphans
    echo "以下のスクリプトを /usr/local/bin へリンクする:"
    list_scripts | while IFS= read -r -d '' file; do
        echo "  $(basename "$file")"
    done
    read -r -p "よろしいですか？ (y/N): " answer
    if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
        echo "処理を中断した。"
        return 0
    fi
    list_scripts | while IFS= read -r -d '' file; do
        filename=$(basename "$file")
        chmod +x "$file"
        ln -svf -- "$file" "/usr/local/bin/ReEncode_$filename"
    done
    echo "インストールが完了した。"
}

uninstall_links() {
    echo "以下のリンクを削除する:"
    list_scripts | while IFS= read -r -d '' file; do
        filename=$(basename "$file")
        linkpath="/usr/local/bin/ReEncode_$filename"
        if [ -L "$linkpath" ]; then
            echo "  $linkpath -> $(readlink -- "$linkpath")"
        fi
    done
    read -r -p "本当に削除しますか？ (y/N): " answer
    if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
        echo "処理を中断した。"
        return 0
    fi
    list_scripts | while IFS= read -r -d '' file; do
        filename=$(basename "$file")
        linkpath="/usr/local/bin/ReEncode_$filename"
        if [ -L "$linkpath" ]; then
            rm -v -- "$linkpath"
        fi
    done
    echo "アンインストールが完了した。"
}

case "${1:-}" in
    -i|--install)
        install_links
        ;;
    -u|--uninstall)
        uninstall_links
        ;;
    -h|--help)
        show_help
        ;;
    *)
        echo "エラー: オプションが指定されていない、または不明じゃ。" >&2
        show_help
        exit 1
        ;;
esac

exit 0
