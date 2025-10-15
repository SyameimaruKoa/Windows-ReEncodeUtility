# config.user.psd1
@{
    # --- 必須プログラムのパス ---
    # 環境変数PATHが通っている場合は "ffmpeg" のように名前だけでよい。
    # 絶対パスを指定する場合は "C:\path\to\ffmpeg.exe" のように記述する。
    FfmpegPath      = "ffmpeg"
    FfprobePath     = "ffprobe"

    # --- 音声エンコーダー (オプション) ---
    # 使用しない場合は空欄 "" のままにしておけ。
    QaacPath        = "qaac64"
    NeroAacEncPath  = "neroAacEnc"

    # --- 補助ツール (オプション) ---
    ExifToolPath    = "exiftool"
    LosslessCutPath = "C:\Users\kouki\OneDrive\PortableApps\LosslessCutPortable\LosslessCutPortable.exe"
}