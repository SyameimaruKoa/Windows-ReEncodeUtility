# Windows-ReEncodeUtility (Go + Fyne 版) 完全技術仕様書

本書は、`Windows-ReEncodeUtility` の PowerShell 実装（`re-encode-AIOptimus.ps1` 他 約3,500行）を Go 言語および Fyne (v2) GUI フレームワークへ完全移植・リニューアルするための確定技術仕様書である。

---

## 1. プロジェクト基本要件

| 項目 | 確定仕様 |
| :--- | :--- |
| **開発言語 / GUI** | **Go 1.22+** / **Fyne (v2)** |
| **描画バックエンド** | **DirectX / OpenGL (Fyne 独自 GPU 描画)**<br>※ Microsoft Edge / Chromium / WebView2 は **一切不使用** |
| **バイナリ形態** | **完全自己完結型 単一バイナリ (`ReEncodeUtility.exe` 約18MB)**<br>`-ldflags="-H windowsgui"` により黒いコンソール画面を完全非表示 |
| **内蔵フォント** | **`Noto Sans JP` (Regular / Bold)** を `//go:embed` でバイナリ直接埋め込み（文字化け完全防止） |
| **操作体系** | **1画面完結型ダッシュボード (Keyboard-First ＋ フルマウス両対応)**<br>スマートデフォルトにより「起動 ➔ 即 Enter」で開始可能 |
| **OS 連携** | **エクスプローラー「送る (SendTo)」** および **動画右クリックメニュー (`SystemFileAssociations\video`)** 起動 |
| **多重起動制御** | **エンコード前 (Idle)**: 既存ウィンドウのキューに追加して最前面化<br>**エンコード中 (Encoding)**: 独立した別ウィンドウとして新規起動 |

---

## 2. 確定画面レイアウト設計

```
+----------------------------------------------------------------------------------------------------+
|  Windows-ReEncodeUtility                                      [⚙ 連携登録 (右クリック/SendTo)] [F1] |
+---------------------------------------------+------------------------------------------------------+
|  [キュー] 処理対象 (2件 - フォルダ自動展開)   |  [エンコード設定]                                     |
|  +---------------------------------------+  |  ① モード   : (o)通常  ( )プラットフォーム  ( )中間  ( )分割 |
|  | [x] 1. sample_video.mp4 (1080p, 2.1GB)|  |  ② プロファイル: [ Twitter (512MB / 720p / H264)   v] [💾保存]|
|  | [x] 2. clip_4k.mkv      (4K,   5.4GB) |  |                                                      |
|  |                                       |  |  ▼ モード別・基本パラメータ ───────────────────────── |
|  |                                       |  |  ハードウェア : [ NVIDIA (NVENC)                   v]|
|  +---------------------------------------+  |  映像コーデック: [ H.264 (自動選択)                v]|
|  [Ctrl+↑/↓: 順序入替] [▲][▼]              |  品質 (CRF)   : [ 18 (容量内で最大品質)   ] [スライダー] |
|                                             |  エンコード速度: [ P4 (標準)                       v]|
|  [選択ファイルのメディア情報]               |  音声設定     : [ AAC (128kbps)                   v]|
|  ・長さ: 00:03:45 / 解像度: 1920x1080       |  インターレース: [ 自動検出 (idet解析)             v]|
|  ・映像: h264, 60.0 fps, yuv420p            |  出力形式     : [ mp4                             v]|
|  ・音声: aac, 48000Hz, stereo               |                                                      |
|                                             |  [▼ 詳細設定・リソース制御 を開く (Alt+D)]           |
|                                             |  ・CPU制限    : [ 全コア使用 (標準)               v] |
|                                             |                 [ Pコアのみ (性能優先)             ] |
|                                             |                 [ Eコアのみ (静音・裏作業用)       ] |
|                                             |                 [ EcoQoS / 省電力低優先度         ] |
|                                             |  ・同名ファイル: [ スキップ (Skip)                 v] |
|                                             |                 [ 自動連番 (AutoRename)          ] |
|                                             |                 [ 上書き (Overwrite)             ] |
|                                             |  ・2-Pass モード: [ OFF ]                            |
|                                             |  ・メタデータ保持: [ ExifToolで全コピー            v] |
|                                             |  ・カット区間  : 開始 [ 00:00:00 ] 終了 [ 00:00:00 ] |
|                                             |  ・追加 VF    : [ scale=1280:-2                   ] |
|                                             |  ・追加 引数   : [ -max_muxing_queue_size 1024     ] |
|                                             |  ・完了後電源  : [ 何もしない                     v] |
+---------------------------------------------+------------------------------------------------------+
|  進捗: [============================>                  ] 58%  (00:02:10 / 00:03:45)                 |
|  速度: 3.20x | fps: 192 | 出力予測: 485 MB / 512 MB (上限OK) | 残り時間: 00:00:29 (完了予定: 21:12)  |
|  ※ Windows タスクバーに進捗率（緑バー / エラー時赤バー）をリアルタイム同期表示                         |
+----------------------------------------------------------------------------------------------------+
|  [▼ ログコンソール (F3キー / クリックで展開)]                                                      |
|  [INFO ] [2026-08-25 21:15:00] 入力ファイル情報取得完了: sample_video.mp4                          |
|  [INFO ] [2026-08-25 21:15:01] HWデコード互換: hwdownload,format=nv12 を自動挿入                  |
|  [DEBUG] [2026-08-25 21:15:02] [CMD] "ffmpeg" -hide_banner -y -hwaccel cuda ...                  |
|  [INFO ] [2026-08-25 21:15:03] [GPU/HW処理情報] デコード: GPU (cuda) / エンコード: GPU (nvenc)   |
+----------------------------------------------------------------------------------------------------+
|  [Tab] 項目移動   [Space] 一時停止/再開   [Del] 削除  |  [Esc] 中断/終了     [Enter] エンコード開始 |
+----------------------------------------------------------------------------------------------------+
```

### キーボードショートカット一覧 & フォーカス視認性
- **フォーカスリング**: `Tab` キー移動時、アクティブなウィジェット外枠に**鮮やかなシアン（水色）のハイライトリング**を表示し、現在位置を瞬時に視認可能。

| キー | 動作 |
| :--- | :--- |
| **`Enter` / `Ctrl+Enter`** | エンコード開始 |
| **`Escape`** | 実行中のエンコード中断（中途半端な出力ファイル・一時ファイルを即座に自動削除）、またはアプリ終了 |
| **`Space`** | エンコード中の一時停止（サスペンド）/ 再開（レジューム） |
| **`Ctrl + ↑` / `Ctrl + ↓`** | キュー内で選択中の動画ファイルの処理順序を上下に入れ替え |
| **`Delete`** | キューから選択中の動画ファイルを削除 |
| **`Tab` / `Shift+Tab`** | 設定項目のフォーカス順次移動 |
| **`↑` / `↓`** | ドロップダウンの選択肢変更、キュー一覧のカーソル移動 |
| **`Alt + D`** | 詳細設定アコーディオンの展開 / 格納 |
| **`F3`** | インライン・ログコンソールの展開 / 格納 |
| **`F1`** | ヘルプ・ショートカット一覧ダイアログ表示 |

---

## 3. 初期同梱プロファイル（Profiles/*.json）完全定義

### 3.1 通常モード用 (`Profiles/general/`)
1. **`high_quality_av1.json`**:
   - 映像: AV1 / CRF: 22 / プリセット: 標準 / 音声: Opus 160kbps / 出力: mkv
2. **`psvr_sbs_full.json`**:
   - 映像: H.264 / CRF: 18 / フィルタ: SBS変換 / 音声: AAC 192kbps / 出力: mp4
3. **`psvr_sbs_half.json`**:
   - 映像: H.264 / CRF: 18 / フィルタ: ハーフSBS変換 / 音声: AAC 192kbps / 出力: mp4
4. **`psvr_sbs_crop_16_9.json`**:
   - 映像: H.264 / CRF: 18 / フィルタ: 16:9 クロップ ＋ SBS / 出力: mp4
5. **`psvr_sbs_crop_4_3.json`**:
   - 映像: H.264 / CRF: 18 / フィルタ: 4:3 クロップ ＋ SBS / 出力: mp4

### 3.2 プラットフォームモード用 (`Profiles/platform/`)
1. **`twitter_512mb.json`**:
   - 上限: 512MB / 最大解像度: 1280x720 / 映像: H.264 / CRF: 18 (maxrate逆算) / 音声: AAC 128kbps / 出力: mp4
2. **`discord_10mb.json`**:
   - 上限: 10MB / 映像: H.264またはAV1 / CRF: 24 (maxrate逆算) / 音声: Opus 64kbps または HE-AAC 48kbps / 出力: mp4
3. **`catbox_200mb.json`**:
   - 上限: 200MB / 映像: 任意 / CRF: 20 (maxrate逆算) / 音声: 128kbps / 出力: mp4
4. **`uguu_64mb.json`**:
   - 上限: 64MB / 映像: 任意 / CRF: 22 (maxrate逆算) / 音声: 96kbps / 出力: mp4
5. **`github_100mb.json`**:
   - 上限: 100MB / 映像: 任意 / CRF: 20 (maxrate逆算) / 音声: 128kbps / 出力: webm / mp4
6. **`github_release_2gb.json`**:
   - 上限: 2048MB / **`no_maxrate: true`** (ビットレート制限なし・CRF 18 高品質優先) / 出力: mkv

### 3.3 中間ファイルモード用 (`Profiles/intermediate/`)
1. **`prores_422hq.json`**:
   - 映像: ProRes 422 HQ (`prores_ks -profile:v 3`) / ピクセル形式: `yuv422p10le` / 音声: PCM / 出力: mkv / mov
2. **`dnxhr_hqx.json`**:
   - 映像: DNxHR HQX (`dnxhd -profile:v dnxhr_hqx`) / ピクセル形式: `yuv422p10le` / 音声: PCM / 出力: mkv / mov
3. **`lossless_flac.json`**:
   - 映像: FFV1 (`ffv1 -level 3`) / ピクセル形式: `yuv444p` / 音声: FLAC / 出力: mkv

### 3.4 分割モード用 (`Profiles/split/`)
1. **`chapter_text_name.json`**:
   - 分割ソース: 内部チャプター / 命名規則: テキスト名 (`元名_チャプター名.ext`)
2. **`srt_number_name.json`**:
   - 分割ソース: 外部SRT字幕 / 命名規則: 連番 (`元名_01.ext`)

---

## 4. コアロジック & エッジケース確定仕様

### 4.1 キュー連続実行 & エラーハンドリング
- キュー内のファイルがエンコードエラーになった場合、そのファイルのエラーログを出力・記録し、通知スクリプト（`notify_script_path`）を実行した上で**スキップし、残りのファイルのエンコードを自動継続**する。

### 4.2 中断（キャンセル）時の自動クリーンアップ
- エンコード途中で `Escape` キーまたは `[中断]` ボタンが押された場合、FFmpeg プロセスを即座に安全キルし、**書き込み途中の不完全な出力ファイルおよび一時ファイル（WAV、2-Passログ等）を自動的に即座に削除**する。

### 4.3 出力ファイル名衝突（重複）ハンドリング
- 出力先に同名ファイルが既に存在する場合の挙動：
  - **デフォルト**: `Skip`（スキップ）
  - **切替可能**: メイン画面の詳細設定および `config.json` 内で `AutoRename`（連番 `_01`, `_02`）または `Overwrite`（強制上書き）に切り替え可能。

### 4.4 電源アクション安全カウントダウン
- シャットダウン / 再起動 / 休止 が選択されている場合、全処理完了時に画面中央に **60秒の安全カウントダウンダイアログ** を表示。
- カウントダウン中に **`[キャンセル (Esc)]`** を押すと即座に電源アクションを阻止し、GUI待機状態に復帰。

### 4.5 メディア情報解析 (ffprobe) の非同期実行
- メディア情報解析（`ffprobe`）は非同期 goroutine で実行され、ネットワークドライブや巨大ファイルでも**タイムアウトによる強制打ち切りは行わず、確実に解析完了まで待機**する。GUI メインスレッドは一切ブロックされない。

### 4.6 カット時間指定の柔軟パース
- 開始時間・終了時間入力欄は、以下の多様な書式を自動パース：
  - `00:01:23.500`（時:分:秒.ミリ秒）
  - `01:23`（分:秒 ➔ `00:01:23`）
  - `83` / `83.5`（秒数直打ち ➔ 秒数として解釈）
  - 空欄または `00:00:00` の場合は `-ss` / `-to` 引数を付与しない。

### 4.7 ディスク空き容量事前チェック
- エンコード開始前、出力先ドライブの空き容量を自動取得し、不足（入力サイズ未満等）の場合は事前に警告ダイアログを表示。

### 4.8 ハードウェア検出 & デコード/転送制御 (`internal/core/hw_scanner.go`, `hw_compat.go`)
- **対応HW**: NVIDIA (NVENC/CUDA), Intel (QSV), AMD (AMF), Vulkan, D3D12VA, MediaFoundation (MF), CPU (Software)
- **キャッシュ**: `.cache/hardware-scan-cache.json`（マシン名・FFmpegシグネチャ検証）
- **HWデコード出力形式**: `cuda`, `qsv`, `d3d11`, `dxva2`, `vulkan`
- **GPU→CPU転送自動挿入**: HWデコード出力使用時かつ（ソフトウェアフィルタ使用時 または CPUエンコーダ使用時 または Vulkanデコード時）に `hwdownload,format=nv12` を自動挿入。
- **extra_hw_frames 制御**: 同一GPU系統（CUDAデコード+NVENC、QSVデコード+QSVエンコード）以外の組み合わせ時に `-extra_hw_frames 64` を自動付与。
- **エラー自動リトライ**: stderr からドライバ/GPUエラー（DXVA/CUDA/QSV failure）を検知した場合、自動的に `-hwaccel` を除外して CPU/標準フォールバックで即座に1回再実行。

### 4.9 プラットフォーム容量逆算ロジック (`internal/core/bitrate_calc.go`)
- **計算式**:
  $$\text{TargetBitrate (kbps)} = \frac{(\text{MaxFileSizeMB} \times 1024 \times 8 \times 0.985) - (\text{AudioBitrateKbps} \times \text{DurationSec})}{\text{DurationSec}}$$
  ※ コンテナオーバーヘッドとして $1.5\%$ を安全マージンとして差し引く。
- **パラメータ設定**:
  - `-maxrate <TargetBitrate>k -bufsize <TargetBitrate * 2>k` を自動付与。

### 4.10 インターレース検出 & 解除 (`internal/core/deinterlace.go`)
- **選択肢**: `なし (スキップ)` / `自動検出 (idet解析)` / `手動指定 (個別フィルタ)`
- **自動検出フロー**:
  1. `ffprobe` による `field_order` (tb, bt, tt, bb) および `interlaced_frame=1` 検証。
  2. `ffmpeg -filter:v idet -frames:v 500` による複数フレーム実走査（TFF/BFFカウント判定）。
- **解除フィルタ**:
  - `bwdif`, `yadif`, `w3fdif`, `nnedi`
  - `fieldmatch,decimate` (24fps 逆テレシネ)
  - `fieldmatch,nnedi=weights='...':deint=interlaced,decimate`
- **nnedi3 自動取得**: `nnedi3_weights.bin` が未存在の場合、公式リポジトリから自動ダウンロードし、パスを安全にエスケープ（`\` ➔ `/`, `:` ➔ `\:`) して埋め込み。

### 4.11 外部音声エンコーダ & 特殊チャンネル処理 (`internal/core/audio_pipeline.go`, `audio_mapping.go`)
- **外部エンコーダパイプライン**:
  1. `qaac` / `neroAacEnc` / `fdkaac` 選択時、FFmpeg で一時 WAV を切り出し（`-vn -map_chapters -1 -map_metadata -1 -f wav`）。
  2. 外部エンコーダで `.m4a` エンコード。
  3. 失敗時は即座に FFmpeg 内蔵 `aac` へ自動フォールバック。
  4. FFmpeg で映像と音声を結合（`-map 0:v:0 -map 1:a:0 -c:a copy`）。
- **Opus特殊チャンネルマッピング**:
  - Ambisonics (`ambisonic`): 適切なチャンネル数なら `-mapping_family 2`、その他は `-mapping_family 255`。
  - 3ch以上の非標準/unknown レイアウト: `-mapping_family 255` を自動付与。

### 4.12 チャプター & 字幕分割エンジン (`internal/core/split_engine.go`)
- **分割ソース**:
  - `内部チャプター`: `ffprobe -show_chapters` から開始/終了時間を抽出。
  - `外部SRT字幕`: 入力動画と同名の `.srt` ファイルからタイムコードとテキストを正規表現パース。
- **命名規則**: `テキスト名 (元名_チャプター名.ext)` または `連番 (元名_01.ext)`。
- **セグメント個別エンコード**: 各セグメントごとに `-ss` / `-to` を指定し、個別に出力・ログ記録。

### 4.13 メタデータ & 編集 & DASH PTS補正 (`internal/core/metadata.go`)
- **ExifTool**: `-api largefilesupport=1 -tagsfromfile <Input> -all:all -overwrite_original <Output>`
- **ffmetadata**: `ffmpeg -f ffmetadata` 経由でのメタデータコピー。
- **DASH PTS補正**: 入力が DASH または断片化 MP4 の場合、`-fflags +genpts` を自動付与。

---

## 5. 高度なリソース・OS制御仕様

### 5.1 CPU 制限 (P-Core / E-Core / EcoQoS) (`internal/runner/cpu_control.go`)
- **Windows API 連携**:
  - `GetLogicalProcessorInformationEx` (RelationProcessorCore) により、PコアとEコアの論理プロセッサマスクを自動判別。
  - `SetProcessAffinityMask(procHandle, mask)` により、FFmpeg プロセスを指定コアにのみバインド。
  - `SetPriorityClass(procHandle, BELOW_NORMAL_PRIORITY_CLASS | IDLE_PRIORITY_CLASS)`。
  - `SetProcessInformation` (ProcessPowerThrottling: EcoQoS / Windows 11 Efficiency Mode)。

### 5.2 Windows タスクバー進捗表示 (`internal/runner/taskbar.go`)
- `ITaskbarList3` COM インターフェースにより、タスクバーアイコンに進捗率を同期。
  - 通常時: `TBPF_NORMAL` (緑色プログレスバー)
  - 一時停止時: `TBPF_PAUSED` (黄色プログレスバー)
  - エラー時: `TBPF_ERROR` (赤色プログレスバー)

### 5.3 プロセス一時停止 / 再開 (`internal/runner/process.go`)
- `NtSuspendProcess` / `NtResumeProcess` により、FFmpeg プロセスを即座に一時停止 / 再開。

### 5.4 エクスプローラー連携ワンクリック登録 (`internal/ui/context_menu_dialog.go`)
- レジストリキー: `HKEY_CURRENT_USER\Software\Classes\SystemFileAssociations\video\shell\ReEncodeUtility`
- コマンド: `"C:\path\to\ReEncodeUtility.exe" "%1"`
- アイコン設定および SendTo ショートカット（`%APPDATA%\Microsoft\Windows\SendTo\ReEncodeUtility.lnk`）の自動生成・削除。

---

## 6. 設定ファイル `config.json` 完全仕様

```json
{
    "tools": {
        "ffmpeg_path": "ffmpeg",
        "ffprobe_path": "ffprobe",
        "qaac_path": "qaac64",
        "nero_aac_path": "neroAacEnc",
        "fdkaac_path": "fdkaac",
        "exiftool_path": "exiftool",
        "losslesscut_path": "",
        "notify_script_path": ""
    },
    "output": {
        "default_mode": "Subfolder",
        "fixed_output_dir": "",
        "subfolder_name": "encoded_output",
        "overwrite_action": "Skip",
        "open_dir_on_complete": false
    },
    "behavior": {
        "default_mode": "General",
        "default_profile": "high_quality_av1",
        "cpu_restriction": "All",
        "play_sound_on_complete": true,
        "keep_window_open_on_complete": true,
        "temp_dir": ""
    }
}
```

---

## 7. ディレクトリ構成 & ソースコード構成

```
Windows-ReEncodeUtility/
├── SPECIFICATION.md                # 本仕様書
├── config.json                     # 設定ファイル
├── assets/
│   └── fonts/
│       └── NotoSansJP-Regular.ttf  # //go:embed 埋め込み日本語フォント
├── Profiles/
│   ├── general/                    # 通常モード用プロファイル (high_quality_av1, psvr_sbs_*)
│   ├── platform/                   # プラットフォームモード用プロファイル (twitter, discord, catbox, uguu, github_*)
│   ├── intermediate/               # 中間ファイルモード用プロファイル (prores_422hq, dnxhr_hqx, lossless_flac)
│   └── split/                      # 分割モード用プロファイル (chapter_text_name, srt_number_name)
├── cmd/
│   └── reencode/
│       └── main.go                 # エントリポイント・Named Pipe 判定
└── internal/
    ├── config/                     # config.json 読み書き & パス探索
    ├── ui/                         # Fyne 1画面ダッシュボード・インラインログ・キーバインド
    ├── core/                       # HWスキャン・互換制御・P/Eコア検出・引数生成・各モードロジック
    └── runner/                     # FFmpeg実行・進捗解析・一時停止・タスクバー同期・電源制御
```
