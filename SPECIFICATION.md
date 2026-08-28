# Windows-ReEncodeUtility (Go + Bubble Tea TUI 版) 完全技術仕様書

本書は、`Windows-ReEncodeUtility` の PowerShell 実装（`re-encode-AIOptimus.ps1` 他 約3,500行）を Go 言語およびモダン TUI フレームワーク（`Bubble Tea` / `Lip Gloss`）へ完全移植・リニューアルするための確定技術仕様書である。
記載されている文言・選択肢・パラメータ定義は、現行 PowerShell スクリプトの記述に完全準拠する。

---

## 1. プロジェクト基本要件

| 項目 | 確定仕様 |
| :--- | :--- |
| **開発言語 / UI** | **Go 1.22+** / **Bubble Tea (`github.com/charmbracelet/bubbletea`)**<br>スタイリング: **Lip Gloss** / UI部品: **Bubbles** |
| **ビルド特性** | **`CGO_ENABLED=0` 純粋 Go 完全対応（ビルド時間 1〜2秒・GCC/Cコンパイラ不要）** |
| **バイナリ形態** | **完全自己完結型 単一バイナリ (`ReEncodeUtility.exe` 約10MB〜12MB)** |
| **操作体系** | **1画面完結型ダッシュボード (パラメータ直接設定が主役 ＋ Keyboard-First ＋ マウス完全対応)**<br>スマートデフォルトにより「起動 ➔ 即 Enter」で開始可能 |
| **テンプレートの扱い** | **テンプレートは必要な時のみオンデマンドで読込 (`F4`)・保存 (`F5`) する補助機能** |
| **数値設定の思想** | **定番の推奨プリセット選択肢から選ぶのを基本**とし、**`カスタム...` 選択時のみ数値入力ボックスが有効化**される |
| **OS 連携** | **エクスプローラー「送る (SendTo)」** および **動画右クリックメニュー (`SystemFileAssociations\video`)** 起動 |
| **多重起動制御** | **エンコード前 (Idle)**: 既存ウィンドウのキューに追加して最前面化<br>**エンコード中 (Encoding)**: 独立した別ターミナルウィンドウとして新規起動 |

---

## 2. 確定画面レイアウト設計 (4大モード別 専用UIダッシュボード)

### 2.1 【モード①】通常モード (`General`) 専用UI
```text
┌─ Windows-ReEncodeUtility ───────── [📂 テンプレート読込 (F4)] [💾 保存 (F5)] [⚙ 連携登録 (F2)] [F1: ヘルプ] ─┐
│  [キュー] 処理対象 (2件 - フォルダ自動展開)   │  [エンコード設定: 通常モード]                                     │
│  ┌───────────────────────────────────────┐  │  実行モード   : (o)通常  ( )プラットフォーム  ( )中間  ( )分割             │
│  │ [x] 1. sample_video.mp4 (1080p, 2.1GB)|  │                                                                  │
│  │ [x] 2. clip_4k.mkv      (4K,   5.4GB) │  │  ▼ パラメータ設定 ────────────────────────────────────────────── │
│  │                                       │  │  HWデコード   : [ 推奨・Windows標準 (d3d11va)                  ▼]│
│  └───────────────────────────────────────┘  │  HWエンコーダ : [ NVIDIA (NVENC)                               ▼]│
│  [Ctrl+↑/↓: 順序入替] [▲][▼]              │  映像コーデック: [ H.264                                       ▼]│
│                                             │  品質設定     : [ 高画質 (CRF 22)                              ▼]│
│  [選択ファイルのメディア情報]               │  エンコード速度: [ P4 (標準)                                   ▼]│
│  ・長さ: 00:03:45 / 解像度: 1920x1080       │  音声設定     : [ qaac: AAC-LC 標準 (tvbr 90)                  ▼]│
│  ・映像: h264, 60.0 fps, yuv420p            │  インターレース: [ 自動判定する (動画解析を実行)               ▼]│
│  ・音声: aac, 48000Hz, stereo               │  出力形式     : [ mp4                                         ▼]│
│                                             │                                                                  │
│                                             │  [▼ 詳細設定・リソース制御 を開く (Alt+D)]                       │
│                                             │  ・CPU制限    : [ 全コア使用 (標準)                           ▼] │
│                                             │                 [ Pコアのみ (性能優先)                         ] │
│                                             │                 [ Eコアのみ (静音・裏作業用)                   ] │
│                                             │                 [ EcoQoS / 省電力低優先度                     ] │
│                                             │  ・AV1エンジン : [ libsvtav1 (推奨)                            ▼] │
│                                             │  ・同名ファイル: [ スキップ (Skip)                             ▼] │
│                                             │                 [ 自動連番 (AutoRename)                       ] │
│                                             │                 [ 上書き (Overwrite)                          ] │
│                                             │  ・2-Pass モード: [ [ ] OFF (※CPU時のみ有効) ]                    │
│                                             │  ・メタデータ保持: [ ExifToolで全コピー                        ▼] │
│                                             │  ・カット (LosslessCut): 開始 [ 00:00:00 ] 終了 [ 00:00:00 ]    │
│                                             │  ・追加 VF    : [ scale=1280:-2                               ] │
│                                             │  ・追加 引数   : [ -max_muxing_queue_size 1024                 ] │
│                                             │  ・完了後電源  : [ 何もしない                                 ▼] │
├─────────────────────────────────────────────┴──────────────────────────────────────────────────────────────────┤
│  進捗: [████████████████████████████████░░░░░░░░░░░░░░░░] 58% (00:02:10 / 00:03:45)                             │
│  速度: 3.20x │ fps: 192 │ 出力予測: 485 MB / 512 MB (上限OK) │ 残り時間: 00:00:29 (完了予定: 21:12)               │
│  ※ Windows タスクバーに進捗率（緑バー / エラー時赤バー）をリアルタイム同期表示                                 │
├────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│  [▼ ログコンソール (F3キー / クリックで展開)]                                                                  │
│  [INFO ] [2026-08-28 14:30:00] 入力ファイル情報取得完了: sample_video.mp4                                      │
│  [INFO ] [2026-08-28 14:30:01] HWデコード互換: hwdownload,format=nv12 を自動挿入                              │
│  [DEBUG] [2026-08-28 14:30:02] [CMD] "ffmpeg" -hide_banner -y -hwaccel cuda ...                              │
│  [INFO ] [2026-08-28 14:30:03] [GPU/HW処理情報] デコード: GPU (cuda) / エンコード: GPU (nvenc)               │
├────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│  [Tab] 項目移動   [Space] 一時停止/再開   [Del] 削除  │  [Esc] 中断/終了     [Enter] エンコード開始             │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 【モード②】プラットフォーム向けアップロード (`Platform`) 専用UI
```text
┌─ [エンコード設定: プラットフォーム向けアップロード] ──────────────────────────┐
│  実行モード       : ( )通常  (o)プラットフォーム  ( )中間  ( )分割             │
│                                                                              │
│  プラットフォーム : [ Twitter (上限 512MB / 720p / H.264)                  ▼]│
│                    [ Discord (上限 10MB / 低ビットレート)                   ]│
│                    [ catbox.moe (上限 200MB)                                ]│
│                    [ uguu.se (上限 64MB)                                    ]│
│                    [ GitHub (上限 100MB / WebM・MP4)                         ]│
│                    [ GitHub Release (上限 2GB / CRF品質優先)                ]│
│                    [ カスタム (任意容量指定)                                ]│
│  設定方式         : (o) おまかせ自動設定          ( ) 詳細設定               │
│                                                                              │
│  ▼ おまかせ自動設定サマリー (ファイル長から自動計算) ─────────────────────── │
│  ・解像度         : 1280x720 (自動調整)                                      │
│  ・CRFベースライン: 18                                                       │
│  ・音声           : qaac (HE-AAC / AAC-LC 自動選択)                          │
│  ・出力形式       : .mp4                                                     │
│  ・推定サイズ     : 485 MB / 上限 512 MB (maxrate自動設定)                   │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 2.3 【モード③】中間ファイル作成モード (`Intermediate`) 専用UI
```text
┌─ [エンコード設定: 中間ファイル作成モード (高画質・MKV・音声設定可)] ────────┐
│  実行モード       : ( )通常  ( )プラットフォーム  (o)中間  ( )分割             │
│                                                                              │
│  中間フォーマット : [ ProRes 422 HQ (yuv422p10le)                          ▼]│
│                    [ DNxHR HQX (yuv422p10le)                                ]│
│                    [ FFV1 (完全ロスレス / yuv444p)                          ]│
│  音声形式         : [ PCM 24-bit (非圧縮)                                   ▼]│
│                    [ FLAC (ロスレス)                                        ]│
│  出力コンテナ     : [ mkv                                                   ▼]│
│                    [ mov                                                    ]│
└──────────────────────────────────────────────────────────────────────────────┘
```

### 2.4 【モード④】チャプター/字幕分割モード (`Split`) 専用UI
```text
┌─ [エンコード設定: チャプター/字幕分割モード (分割して再エンコード)] ─────────┐
│  実行モード       : ( )通常  ( )プラットフォーム  ( )中間  (o)分割             │
│                                                                              │
│  分割ソース       : (o) 内部チャプターを使用  ( ) 外部SRT字幕ファイルを使用 │
│  命名規則         : (o) チャプター/字幕のテキストを使用  ( ) 連番のみを使用  │
│  検出セグメント   : 全 12 セグメントを検出                                   │
│  出力ファイルの拡張子: [ mp4                                                ▼]│
│                        [ mkv                                                ]│
│                        [ mov                                                ]│
│                        [ webm                                               ]│
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 初期同梱テンプレート完全定義 (`Templates/`)

PS1の `Profiles/` ディレクトリに存在したテンプレートを完全移行。

1. **`PSVR SBS - フル.json`**:
   - 映像: H.264 / CRF: 18 / 速度: slow / 音声: AAC 192k / 出力: mp4
   - フィルタ: SBS変換
2. **`PSVR SBS - ハーフ.json`**:
   - 映像: H.264 / CRF: 18 / 速度: slow / 音声: AAC 192k / 出力: mp4
   - フィルタ: ハーフSBS変換
3. **`PSVR SBS - フル - クロップ - 16：9.json`**:
   - 映像: H.264 / CRF: 18 / 速度: slow / 音声: AAC 192k / 出力: mp4
   - フィルタ: 16:9 クロップ ＋ SBS変換
4. **`PSVR SBS - フル - クロップ - 4：3.json`**:
   - 映像: H.264 / CRF: 18 / 速度: slow / 音声: AAC 192k / 出力: mp4
   - フィルタ: 4:3 クロップ ＋ SBS変換

---

## 4. 選択肢・パラメータ定義一覧（PS1完全準拠）

### 4.1 ハードウェアデコード選択肢 (`Get-HardwareInfo.ps1`)
- `使用しない (CPUデコード)` (`-hwaccel` なし)
- `NVIDIA (cuda)` (`-hwaccel cuda -hwaccel_output_format cuda`)
- `Intel (qsv)` (`-hwaccel qsv -hwaccel_output_format qsv`)
- `推奨・Windows標準 (d3d11va)` (`-hwaccel d3d11va -hwaccel_output_format d3d11`)
- `Windows汎用 (dxva2)` (`-hwaccel dxva2 -hwaccel_output_format dxva2`)
- `Vulkan (vulkan)` (`-hwaccel vulkan -hwaccel_output_format vulkan`)

### 4.2 ハードウェアエンコーダ選択肢
- `NVIDIA (NVENC)` (`h264_nvenc`, `hevc_nvenc`, `av1_nvenc`)
- `Intel (QSV)` (`h264_qsv`, `hevc_qsv`, `vp9_qsv`, `av1_qsv`)
- `AMD (AMF)` (`h264_amf`, `hevc_amf`, `av1_amf`)
- `Vulkan` (`h264_vulkan`, `hevc_vulkan`, `av1_vulkan`)
- `D3D12VA` (`h264_d3d12va`, `hevc_d3d12va`, `av1_d3d12va`)
- `MediaFoundation (MF)` (`h264_mf`, `hevc_mf`, `av1_mf`)
- `CPU (Software)` (`libx264`, `libx265`, `libvpx-vp9`, `libsvtav1`, `libaom-av1`, `rav1e`)

### 4.3 インターレース選択肢 (`Select-DeinterlaceOption`)
- `行わない (スキップ)`
- `自動判定する (動画解析を実行)` (ffprobe `field_order`/`interlaced_frame` ＋ ffmpeg `idet` 500フレーム実走査)
- `手動で選択する (解析をスキップして直接フィルター指定)`
  - `bwdif (標準 / 推奨)`
  - `yadif (軽量)`
  - `w3fdif (シンプル)`
  - `nnedi (高品質 / ニューラルネットワーク)`
  - `fieldmatch,decimate (24fpsアニメ・映画向け逆テレシネ)`
  - `fieldmatch,nnedi,decimate (24fps逆テレシネ + コーミング補完)`

### 4.4 音声エンコーダ選択肢 (`get-ffmpegOptions.ps1`)
- **外部エンコーダ (自動検出)**:
  - **qaac**: `AAC-LC 高品質 (tvbr 110)`, `AAC-LC 標準 (tvbr 90)`, `HE-AAC (cvbr 48k)`, `カスタム`
  - **neroAacEnc**: `高品質 (-q 0.50)`, `標準 (-q 0.40)`, `カスタム`
  - **fdkaac**: `最高品質 (VBR 5)`, `標準 (VBR 4)`, `カスタム`
- **FFmpeg内蔵**:
  - **AAC**: `64k`, `96k`, `128k`, `160k`, `192k`, `256k`, `320k`, `カスタム`
  - **Opus**: `64k`, `96k`, `128k`, `160k`, `192k`, `カスタム` (Ambisonics/3ch以上非標準は `-mapping_family 2 / 255` 自動付与)
  - **Vorbis**: `品質指定 (-q:a 1〜10)`
  - **FLAC / PCM**: ロスレス
  - `音声コピー (-c:a copy)` / `音声なし (-an)`

### 4.5 メタデータ保持・後処理選択肢
- **メタデータ**: `ExifToolで全コピー`, `ffmpeg形式で一部保持`, `保持しない`
- **完了後電源**: `何もしない`, `シャットダウン` (60秒キャンセルダイアログ), `再起動`, `休止`
- **出力先モード**: `入力元と同じ階層のsubfolder (encoded_output)`, `固定フォルダを指定`

---

## 5. コアロジック & エッジケース確定仕様

### 5.1 エンコード実行中の操作ロック
- エンコード開始と同時にパラメータ設定パネルは自動ロック。
- 実行中に受け付ける操作は `Space` (一時停止/再開), `Esc` (中断), `F3` (ログ展開/スクロール), `Alt+D` (詳細確認) のみに限定。

### 5.2 キュー連続実行 & エラーハンドリング
- キュー内のファイルがエンコードエラーになった場合、エラーログを出力し、通知スクリプト（`notify_script_path`）を実行した上で**スキップし、残りのファイルのエンコードを自動継続**。

### 5.3 中断（キャンセル）時の自動クリーンアップ
- エンコード途中で中断された場合、FFmpeg プロセスを即座に安全キルし、**書き込み途中の不完全な出力ファイルおよび一時ファイル（WAV、2-Passログ等）を自動的に即座に削除**。

### 5.4 出力ファイル名衝突（重複）ハンドリング
- 出力先に同名ファイルが既に存在する場合の挙動：
  - **デフォルト**: `Skip`（スキップ）
  - **切替可能**: メイン画面の詳細設定および `config.json` 内で `AutoRename`（連番 `_01`, `_02`）または `Overwrite`（強制上書き）に切り替え可能。

### 5.5 プラットフォーム容量逆算ロジック (`bitrate_calc.go`)
- **計算式**:
  $$\text{TargetBitrate (kbps)} = \frac{(\text{MaxFileSizeMB} \times 1024 \times 8 \times 0.985) - (\text{AudioBitrateKbps} \times \text{DurationSec})}{\text{DurationSec}}$$
  ※ コンテナオーバーヘッドとして $1.5\%$ を安全マージンとして差し引く。
- **パラメータ設定**:
  - `-maxrate <TargetBitrate>k -bufsize <TargetBitrate * 2>k` を自動付与。
  - `音声コピー` 時は ffprobe で実測した音声ビットレートを使用。
  - `音声なし` 時は 音声 0MB として全容量を映像に配分。

### 5.6 HWエラー自動リトライ
- stderr からドライバ/GPUエラー（DXVA/CUDA/QSV failure）を検知した場合、自動的に `-hwaccel` を除外して CPU/標準フォールバックで即座に1回再実行。

### 5.7 ファイル名禁止文字サニタイズ (`Sanitize-FileName`)
- 分割モード時、チャプター名やSRTテキストに含まれる Windows禁止文字（`\`, `/`, `:`, `*`, `?`, `"`, `<`, `>`, `|`）や改行を安全な `_` に自動置換。

---

## 6. 高度なリソース・OS制御仕様

### 6.1 CPU 制限 (P-Core / E-Core / EcoQoS)
- `GetLogicalProcessorInformationEx` により Pコア/Eコアの論理プロセッサマスクを取得。
- `SetProcessAffinityMask` で FFmpeg プロセスを指定コアにバインド。
- `SetPriorityClass` (BELOW_NORMAL / IDLE) および `SetProcessInformation` (EcoQoS)。

### 6.2 Windows タスクバー進捗表示
- `ITaskbarList3` COM インターフェースにより、タスクバーアイコンに進捗率（緑 / 黄 / 赤）を同期。

### 6.3 エクスプローラー連携ワンクリック登録
- `HKEY_CURRENT_USER\Software\Classes\SystemFileAssociations\video\shell\ReEncodeUtility`
- `%APPDATA%\Microsoft\Windows\SendTo\ReEncodeUtility.lnk`

---

## 7. 設定ファイル `config.json` 完全仕様

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
        "default_mode": "General",
        "fixed_output_dir": "",
        "subfolder_name": "encoded_output",
        "overwrite_action": "Skip",
        "open_dir_on_complete": false
    },
    "behavior": {
        "default_mode": "General",
        "cpu_restriction": "All",
        "play_sound_on_complete": true,
        "keep_window_open_on_complete": true,
        "temp_dir": ""
    }
}
```

---

## 8. ディレクトリ構成 & ソースコード構成 (Pure Go / Bubble Tea)

```
Windows-ReEncodeUtility/
├── SPECIFICATION.md                # 本仕様書 (PS1完全準拠)
├── config.json                     # 設定ファイル
├── Templates/                      # ユーザーテンプレート保存用フォルダ (.json)
│   ├── PSVR SBS - フル.json
│   ├── PSVR SBS - ハーフ.json
│   ├── PSVR SBS - フル - クロップ - 16：9.json
│   └── PSVR SBS - フル - クロップ - 4：3.json
├── cmd/
│   └── reencode/
│       └── main.go                 # エントリポイント・Named Pipe 判定
└── internal/
    ├── config/                     # config.json 読み書き & パス探索
    ├── ui/                         # Bubble Tea TUI レイヤー
    │     ├── model.go              # メイン Model (TEA State Machine)
    │     ├── view.go               # Lip Gloss レイアウト描画 (ダッシュボード)
    │     ├── queue_view.go         # 左ペイン: キュー一覧 & メディア情報
    │     ├── general_view.go       # 右ペイン①: 通常モード専用UI
    │     ├── platform_view.go      # 右ペイン②: プラットフォーム専用UI (おまかせ/詳細)
    │     ├── intermediate_view.go  # 右ペイン③: 中間ファイル専用UI
    │     ├── split_view.go         # 右ペイン④: 分割専用UI
    │     ├── template_dialog.go    # F4: テンプレート読込 / F5: テンプレート保存ダイアログ
    │     ├── progress_view.go      # 下部: プログレスバー & リアルタイム統計
    │     ├── log_view.go           # インライン・ログコンソール (F3)
    │     └── context_menu.go       # 右クリック/SendTo登録ダイアログ (F2)
    ├── core/                       # コアロジック (HWスキャン・互換制御・P/Eコア検出・引数生成・各モードロジック)
    └── runner/                     # FFmpeg実行・進捗解析・一時停止・タスクバー同期・電源制御
```
