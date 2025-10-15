# re-encode-AIOptimus.ps1 の設定ファイルじゃ。
# 各ツールの実行ファイル(.exe)へのパスを "" の中に記述せよ。
# 環境変数PATHが通っておる場合は "ffmpeg" のように名前だけでよいぞ。
@{
    # --- 必須プログラムのパス ---
    FfmpegPath       = "ffmpeg"
    FfprobePath      = "ffprobe"

    # --- 音声エンコーダー (オプション) ---
    # 使用しない場合は空欄 "" のままにしておけ。
    QaacPath         = "qaac64"
    NeroAacEncPath   = "neroAacEnc"
    FdkaacPath       = "fdkaac"

    # --- 補助ツール (オプション) ---
    ExifToolPath     = "exiftool"
    LosslessCutPath  = "C:\Users\kouki\OneDrive\PortableApps\LosslessCutPortable\LosslessCutPortable.exe"

    # --- その他 ---
    NotifyScriptPath = "" # エラー通知などに使うスクリプトのパスじゃ。
}