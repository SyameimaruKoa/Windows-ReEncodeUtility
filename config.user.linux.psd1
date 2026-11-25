# Linux 用の設定ファイルじゃ。
# 各ツールの実行ファイルへのパスを "" の中に記述せよ。
# PATH が通っておる場合は "ffmpeg" のように名前だけでもよい。
@{
    # --- 必須プログラムのパス ---
    FfmpegPath       = "ffmpeg"
    FfprobePath      = "ffprobe"

    # --- 音声エンコーダー (オプション) ---
    # Linux では qaac / Nero は未設定のままにし、fdkaac を使用する。
    # 未検出時は FFmpeg 内蔵 AAC / Opus へフォールバックする。
    QaacPath         = ""
    NeroAacEncPath   = ""
    FdkaacPath       = "fdkaac"

    # --- 補助ツール (オプション) ---
    ExifToolPath     = "exiftool"
    # 空欄なら PATH を検索し、見つからなければ最新の AppImage を .cache/losslesscut に取得する。
    LosslessCutPath  = ""

    # --- その他 ---
    NotifyScriptPath = ""
    VaapiDevicePath  = "/dev/dri/renderD128"
}
