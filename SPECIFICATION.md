# Windows-ReEncodeUtility (Go + Bubble Tea TUI 版) 完全技術仕様書

本書は、`Windows-ReEncodeUtility` の PowerShell 実装（`re-encode-AIOptimus.ps1` 他 約3,500行）を Go 言語およびモダン TUI フレームワーク（`Bubble Tea` / `Lip Gloss`）へ完全移植・リニューアルするための確定技術仕様書である。
記載されている文言・選択肢・パラメータ定義・内部ロジックは、現行 PowerShell スクリプトの記述およびこれまでの全決定事項に完全準拠する。

---

## 1. プロジェクト基本要件

| 項目 | 確定仕様 |
| :--- | :--- |
| **開発言語 / UI** | **Go 1.22+** / **Bubble Tea (`github.com/charmbracelet/bubbletea`)**<br>スタイリング: **Lip Gloss** / UI部品: **Bubbles** |
| **ビルド特性** | **`CGO_ENABLED=0` 純粋 Go 完全対応（ビルド時間 1〜2秒・GCC/Cコンパイラ不要）** |
| **バイナリ形態** | **完全自己完結型 単一バイナリ (`ReEncodeUtility.exe` 約10MB〜12MB)** |
| **配置・ポータビリティ** | **`config.json` および `Templates/` は実行ファイルと同階層に完全集約**（作成不可時は警告を表示して起動中止） |
| **ビルド自動化** | **`build.bat` (Shift-JIS / -h/--help対応 / 完了時一時停止) のみで完結**（ps1廃止） |
| **文字コード・パス対応** | **Windows UTF-16 Wide API (`CreateProcessW`) により、日本語・特殊記号・長パスの文字化けを完全防止** |
| **操作体系** | **1画面完結型ダッシュボード (4大モード別専用UI ＋ Keyboard-First ＋ マウス完全対応)**<br>スマートデフォルトにより「起動 ➔ 即 Enter」で開始可能 |
| **キュー処理の思想** | **キューに存在するすべての動画が同一設定でエンコード対象**（非動画は自動除外・不要な動画は `Delete` キーで削除） |
| **テンプレートの扱い** | **テンプレートは必要な時のみオンデマンドで読込 (`F4`)・保存 (`F5`) する補助機能**（テンプレート使用前提を撤廃） |
| **数値設定の思想** | **定番の推奨プリセット選択肢から選ぶのを基本**とし、**`カスタム...` 選択時のみ数値入力ボックスが有効化**される |
| **初期セットアップ** | **`config.json` 未存在時は PATH / 一般配置場所を自動走査して同階層に生成**（FFmpeg未検出時は警告ダイアログ表示） |
| **ログ保存** | **エンコード完了時、出力動画と同階層に `<出力名>_encode.log` を自動生成**（完全コマンド、実行時間、平均fps、HW使用状況、エラーログを記録） |
| **通知機能** | **完了通知音 (System Sound)**、**外部通知スクリプト (`notify_script_path`)**、および **Discord WebHook 通知 (`discord_webhook_url`, 完了時メンション対応)** に対応 |
| **OS 連携** | **エクスプローラー「送る (SendTo)」** および **動画右クリックメニュー (`SystemFileAssociations\video`)** 起動（UAC管理者権限不要で `F2` から登録・解除可能） |
| **多重起動制御** | **エンコード前 (Idle)**: 既存ウィンドウのキューに追加して最前面化 (`Named Pipe`)<br>**エンコード中 (Encoding)**: 独立した別ターミナルウィンドウとして新規起動 |

---

## 2. 確定画面レイアウト設計 (4大モード別 専用UIダッシュボード)

### 2.1 【モード①】通常モード (`General`) 専用UI —— フルパラメータ直接設定
```text
┌─ Windows-ReEncodeUtility ───────── [📂 テンプレート読込 (F4)] [💾 保存 (F5)] [⚙ 連携登録 (F2)] [F1: ヘルプ] ─┐
│  [キュー] 処理対象 (2件 - フォルダ自動展開)   │  [エンコード設定: 通常モード]                                     │
│  ┌───────────────────────────────────────┐  │  実行モード   : (o)通常  ( )プラットフォーム  ( )中間  ( )分割             │
│  │ 1. sample_video.mp4 (1080p, 2.1GB)    │  │                                                                  │
│  │ 2. clip_4k.mkv      (4K,   5.4GB)     │  │  ▼ パラメータ設定 ────────────────────────────────────────────── │
│  │                                       │  │  HWデコード   : [ 推奨・Windows標準 (d3d11va)                  ▼]│
│  └───────────────────────────────────────┘  │  HWエンコーダ : [ NVIDIA (NVENC)                               ▼]│
│  [Ctrl+↑/↓: 順序入替] [Del: 削除] [▲][▼]   │  映像コーデック: [ H.264                                       ▼]│
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
│                                             │                 [ libaom-av1 (最高品質/超低速)                ] │
│                                             │                 [ rav1e (中速/実験的)                         ] │
│                                             │  ・同名ファイル: [ スキップ (Skip)                             ▼] │
│                                             │                 [ 自動連番 (AutoRename)                       ] │
│                                             │                 [ 上書き (Overwrite)                          ] │
│                                             │  ・2-Pass モード: [ [ ] OFF (※CPU時のみ有効) ]                    │
│                                             │  ・メタデータ保持: [ ExifToolで全コピー                        ▼] │
│                                             │  ・カット区間  : 開始 [ 00:00:00 ] 終了 [ 00:00:00 ] [LosslessCut]│
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
**保存場所は実行ファイルと同階層の `Templates/` フォルダ固定**とする。

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

### 4.3 映像品質（CRF / ビットレート）選択肢
- `最高画質 (CRF 18 / アーカイブ向け)`
- `高画質   (CRF 22 / 推奨バランス)`
- `標準画質 (CRF 26 / 容量重視)`
- `低画質   (CRF 30 / プレビュー向け)`
- `カスタム CRF指定...` ➔ 選択時、隣の数値入力ボックスが有効化（例: `[ 20 ]`）
- `カスタム ビットレート指定...` ➔ 選択時、隣のビットレート入力が有効化（例: `[ 8000 ] kbps`）

### 4.4 ハードウェア別 速度プリセット選択肢
- **NVIDIA (NVENC)**: `P1 (最速)`, `P2`, `P3`, `P4 (標準)`, `P5`, `P6`, `P7 (最高品質)`
- **Intel (QSV)**: `veryfast (最速)`, `fast`, `medium (標準)`, `slow`, `veryslow (最高品質)`
- **AMD (AMF)**: `speed (速度優先)`, `balanced (標準)`, `quality (品質優先)`
- **CPU (x264 / x265)**: `ultrafast (最速)`, `veryfast`, `fast`, `medium (標準)`, `slow`, `veryslow (最高品質)`
- **CPU (SVT-AV1)**: `0 (最高品質/極遅)`, `2`, `4 (標準)`, `6`, `8`, `10 (最速)`
- **CPU (VP9)**: `0 (最高品質/極遅)`, `2`, `4 (標準)`, `6`, `8 (最速)`
- **Vulkan / D3D12VA / MF**: 速度プリセットなし（固定）

### 4.5 インターレース選択肢 (`Select-DeinterlaceOption`)
- `行わない (スキップ)`
- `自動判定する (動画解析を実行)` (ffprobe `field_order`/`interlaced_frame` ＋ ffmpeg `idet` 500フレーム実走査)
- `手動で選択する (解析をスキップして直接フィルター指定)`
  - `bwdif (標準 / 推奨)`
  - `yadif (軽量)`
  - `w3fdif (シンプル)`
  - `nnedi (高品質 / ニューラルネットワーク)`
  - `fieldmatch,decimate (24fpsアニメ・映画向け逆テレシネ)`
  - `fieldmatch,nnedi,decimate (24fps逆テレシネ + コーミング補完)`

### 4.6 音声エンコーダ選択肢 (`get-ffmpegOptions.ps1`)
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

### 4.7 メタデータ保持・後処理選択肢
- **メタデータ**: `ExifToolで全コピー`, `ffmpeg形式で一部保持`, `保持しない`
- **完了後電源**: `何もしない`, `シャットダウン` (60秒キャンセルダイアログ), `再起動`, `休止`
- **出力先モード**: `入力元と同じ階層のsubfolder (encoded_output)`, `固定フォルダを指定`

---

## 5. コアロジック & エッジケース確定仕様

### 5.1 エンコード実行中の操作ロック
- エンコード開始と同時にパラメータ設定パネルは自動ロック。
- 実行中に受け付ける操作は `Space` (一時停止/再開), `Esc` (中断), `F3` (ログ展開/スクロール), `Alt+D` (詳細確認) のみに限定。

### 5.2 キュー連続実行 & エラーハンドリング
- キュー内のファイルがエンコードエラーになった場合、エラーログを出力し、通知スクリプト（`notify_script_path`）および Discord WebHook（`discord_webhook_url`）を実行した上で**スキップし、残りのファイルのエンコードを自動継続**。

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
- **プラットフォーム別コーデック制限**:
  - **Twitter**: H.264 のみ（最大 1280x720 自動縮小、最大 60fps、音声 AAC）。非対応コーデックは選択肢から自動除外。
  - **Discord**: H.264 / H.265 / AV1 / VP9（10MB上限）。
  - **catbox.moe / uguu.se / GitHub**: 汎用。
  - **GitHub Release (2GB)**: CRF 18 高画質優先（`no_maxrate: true`）。
- **パラメータ設定**:
  - `-maxrate <TargetBitrate>k -bufsize <TargetBitrate * 2>k` を自動付与。
  - `音声コピー` 時は ffprobe で実測した音声ビットレートを使用。
  - `音声なし` 時は 音声 0MB として全容量を映像に配分。

### 5.6 ハードウェア検出 & デコード/転送制御 (`internal/core/hw_scanner.go`, `hw_compat.go`)
- **対応HW**: NVIDIA (NVENC/CUDA), Intel (QSV), AMD (AMF), Vulkan, D3D12VA, MediaFoundation (MF), CPU (Software)
- **キャッシュ**: `.cache/hardware-scan-cache.json`（マシン名・FFmpegシグネチャ検証）
- **HWデコード出力形式**: `cuda`, `qsv`, `d3d11`, `dxva2`, `vulkan`
- **GPU→CPU転送自動挿入**: HWデコード出力使用時かつ（ソフトウェアフィルタ使用時 または CPUエンコーダ使用時 または Vulkanデコード時）に `hwdownload,format=nv12` を自動挿入。
- **extra_hw_frames 制御**: 同一GPU系統（CUDAデコード+NVENC、QSVデコード+QSVエンコード）以外の組み合わせ時に `-extra_hw_frames 64` を自動付与。
- **HWエラー自動リトライ**: stderr からドライバ/GPUエラー（DXVA/CUDA/QSV failure）を検知した場合、自動的に `-hwaccel` を除外して CPU/標準フォールバックで即座に1回再実行。

### 5.7 インターレース検出 & 解除 (`internal/core/deinterlace.go`)
- **選択肢**: `行わない (スキップ)` / `自動判定する (動画解析を実行)` / `手動で選択する (解析をスキップして直接フィルター指定)`
- **自動検出フロー**:
  1. `ffprobe` による `field_order` (tb, bt, tt, bb) および `interlaced_frame=1` 検証。
  2. `ffmpeg -filter:v idet -frames:v 500` による複数フレーム実走査（TFF/BFFカウント判定）。
- **解除フィルタ**:
  - `bwdif`, `yadif`, `w3fdif`, `nnedi`
  - `fieldmatch,decimate` (24fps 逆テレシネ)
  - `fieldmatch,nnedi=weights='...':deint=interlaced,decimate`
- **nnedi3 自動取得とエラー時挙動**: `nnedi3_weights.bin` が未存在の場合、公式リポジトリから自動ダウンロードを試行。**ダウンロード失敗時はフォールバックせずエラーとして該当動画をスキップ**する。

### 5.8 外部音声エンコーダ & 特殊チャンネル処理 (`internal/core/audio_pipeline.go`, `audio_mapping.go`)
- **外部エンコーダパイプライン**:
  1. `qaac` / `neroAacEnc` / `fdkaac` 選択時、FFmpeg で一時 WAV を切り出し（`-vn -map_chapters -1 -map_metadata -1 -f wav`）。
  2. 外部エンコーダで `.m4a` エンコード。
  3. 失敗時は即座に FFmpeg 内蔵 `aac` へ自動フォールバック。
  4. FFmpeg で映像と音声を結合（`-map 0:v:0 -map 1:a:0 -c:a copy`）。
- **Opus特殊チャンネルマッピング**:
  - Ambisonics (`ambisonic`): 適切なチャンネル数なら `-mapping_family 2`、その他は `-mapping_family 255`。
  - 3ch以上の非標準/unknown レイアウト: `-mapping_family 255` を自動付与。

### 5.9 チャプター & 字幕分割エンジン (`internal/core/split_engine.go`)
- **分割ソース**:
  - `内部チャプター`: `ffprobe -show_chapters` から開始/終了時間を抽出。
  - `外部SRT字幕`: 入力動画と同名の `.srt` ファイルからタイムコードとテキストを正規表現パース。
- **命名規則**: `チャプター/字幕のテキストを使用 (元名_チャプター名.ext)` または `連番のみを使用 (元名_01.ext)`。
- **ファイル名禁止文字サニタイズ**: チャプター名やSRTテキストに含まれる Windows禁止文字（`\`, `/`, `:`, `*`, `?`, `"`, `<`, `>`, `|`）や改行を安全な `_` に自動置換。
- **セグメント個別エンコード**: 各セグメントごとに `-ss` / `-to` を指定し、個別に出力・ログ記録。

### 5.10 メタデータ & 編集 & DASH PTS補正 (`internal/core/metadata.go`)
- **ExifTool**: `-api largefilesupport=1 -tagsfromfile <Input> -all:all -overwrite_original <Output>`
- **ffmetadata**: `ffmpeg -f ffmetadata` 経由でのメタデータコピー。
- **DASH PTS補正**: 入力が DASH または断片化 MP4 の場合、`-fflags +genpts` を自動付与。

### 5.11 電源アクション安全カウントダウン
- シャットダウン / 再起動 / 休止 が選択されている場合、全処理完了時に画面中央に **60秒の安全カウントダウンダイアログ** を表示。
- カウントダウン中に **`[キャンセル (Esc)]`** を押すと即座に電源アクションを阻止し、TUI待機状態に復帰。

### 5.12 メディア情報解析 (ffprobe) の非同期実行 & 非動画ファイル安全スキップ
- メディア情報解析（`ffprobe`）は非同期 goroutine で実行され、ネットワークドライブや巨大ファイルでも**タイムアウトによる強制打ち切りは行わず、確実に解析完了まで待機**。TUI メイン描画スレッドは一切ブロックされない。
- **非動画ファイルの安全スキップ**: `ffprobe` 解析で動画ストリーム（`codec_type: "video"`）が検出されないファイル（テキストや破損ファイル等）は、自動的にキューから除外し、ログコンソールに `[WARN] 非動画ファイルのためスキップ: <ファイル名>` を記録。

### 5.13 カット時間指定の柔軟パース & LosslessCut 連携
- 開始時間・終了時間入力欄は、以下の多様な書式を自動パース：
  - `00:01:23.500`（時:分:秒.ミリ秒）
  - `01:23`（分:秒 ➔ `00:01:23`）
  - `83` / `83.5`（秒数直打ち ➔ 秒数として解釈）
  - 空欄または `00:00:00` の場合は `-ss` / `-to` 引数を付与しない。
- **LosslessCut 連携の目的と動作**:
  - フレーム単位の正確なカットポイント確認およびタイムコード取得を支援するため、カット欄から `[LosslessCut]` を起動可能。
  - `config.json` の `"losslesscut_path"` は `.exe` だけでなく、普段使われている `.bat` や `.cmd` 経由の起動にも完全対応。

### 5.14 ディスク空き容量事前チェック
- エンコード開始前、出力先ドライブの空き容量を自動取得し、不足（入力サイズ未満等）の場合は事前に警告ダイアログを表示。

### 5.15 ログファイル出力仕様
- エンコード完了時、出力動画と同じディレクトリに `<出力動画ベース名>_encode.log` を自動出力。
- 実行した完全な FFmpeg コマンドライン、開始/終了時刻、所要時間、平均fps、HW使用情報、エラーメッセージを記録。

### 5.16 多重起動（Named Pipe）プロトコル仕様
- **パイプ名**: `\\.\pipe\windows-reencode-utility`
- **通信プロトコル**:
  - 新規起動時、パイプクライアントとして既存インスタンスへの接続を試行。
  - **既存が `IDLE`（待機中）の場合**:
    - `{"action": "add_queue", "paths": ["C:\\video1.mp4", ...]}` を送信。
    - 既存インスタンスがキューに追加してコンソールウィンドウを最前面化（`SetForegroundWindow`）。新規プロセスは即座に終了。
  - **既存が `ENCODING`（実行中）または未起動の場合**:
    - パイプ接続を終了し、独立した新しいターミナルウィンドウとして自ら起動。

### 5.17 Discord WebHook 通知仕様
- **設定項目**:
  - `discord_webhook_url`: WebHook URL
  - `discord_mention_user_id`: 完了時・エラー時にメンションするユーザーID（例: `<@123456789012345678>`）
  - `discord_mention_on`: メンション条件 (`"All"` / `"QueueCompleteOnly"` / `"ErrorOnly"` / `"None"`)
- **送信内容**:
  - **個別動画の成功時**: ファイル名、出力サイズ、所要時間、平均fps、コーデック（緑色 Embed: `#00FF87`）
  - **個別動画の失敗時**: ファイル名、エラー概要（赤色 Embed: `#FF5F5F`）
  - **キュー全体の完了時**: 総処理数、成功数、失敗数、総時間 ＋ 設定に応じたメンション送信

### 5.18 FFmpeg 進捗連動 TUI 描画 & 完了後待機挙動
- **進捗描画連動**:
  - FFmpeg の `-progress` 出力（`out_time_ms`, `frame`, `fps`, `speed`）を受信したタイミングに直接連動して、TUI画面とタスクバー進捗率をリアルタイム更新。
- **完了後の待機挙動**:
  - 全キュー完了時、進捗バーが `100% [完了]` に変化し、ステータスバーに `「全エンコードが完了しました。[Enter] または [Esc] で終了」` と表示してユーザーのキー入力を待機。
  - `config.json` の `"keep_window_open_on_complete": false` の場合のみ自動終了。

### 5.19 設定・テンプレート配置ポリシー & 起動安全制御
- **配置原則**: `config.json` および `Templates/` フォルダは、**実行ファイル（`ReEncodeUtility.exe`）と同じディレクトリに配置されることを前提**とする（ポータブル運用）。
- **起動安全制御**: 実行ファイルと同じ場所に書き込み権限がない場合や `config.json` を生成できない場合は、別の場所に散らばらせず、**エラー警告を表示して即座に起動を中止**する。

---

## 6. 高度なリソース・OS制御仕様

### 6.1 CPU 制限 (P-Core / E-Core / EcoQoS) (`internal/runner/cpu_control.go`)
- **Windows API 連携**:
  - `GetLogicalProcessorInformationEx` (RelationProcessorCore) により、PコアとEコアの論理プロセッサマスクを自動判別。
  - `SetProcessAffinityMask(procHandle, mask)` により、FFmpeg プロセスを指定コアにのみバインド。
  - `SetPriorityClass(procHandle, BELOW_NORMAL_PRIORITY_CLASS | IDLE_PRIORITY_CLASS)`。
  - `SetProcessInformation` (ProcessPowerThrottling: EcoQoS / Windows 11 Efficiency Mode)。

### 6.2 Windows タスクバー進捗表示 (`internal/runner/taskbar.go`)
- `ITaskbarList3` COM インターフェースにより、タスクバーアイコンに進捗率を同期。
  - 通常時: `TBPF_NORMAL` (緑色プログレスバー)
  - 一時停止時: `TBPF_PAUSED` (黄色プログレスバー)
  - エラー時: `TBPF_ERROR` (赤色プログレスバー)

### 6.3 プロセス一時停止 / 再開 (`internal/runner/process.go`)
- `NtSuspendProcess` / `NtResumeProcess` により、FFmpeg プロセスを即座に一時停止 / 再開。

### 6.4 エクスプローラー連携ワンクリック登録 (`internal/ui/context_menu.go`)
- **管理者権限（UAC）不要**:
  - レジストリキー: `HKEY_CURRENT_USER\Software\Classes\SystemFileAssociations\video\shell\ReEncodeUtility`
  - コマンド: `"C:\path\to\ReEncodeUtility.exe" "%1"`
  - SendTo ショートカット: `%APPDATA%\Microsoft\Windows\SendTo\ReEncodeUtility.lnk`
  - HKCU およびユーザーの APPDATA を使用するため、管理者権限なしで `F2` から安全かつ即座に登録・削除が可能。

### 6.5 TUI モーダルダイアログ操作体系
- `F1` (ヘルプ), `F2` (連携登録), `F4` (テンプレート読込), `F5` (テンプレート保存) 押下時：
  - 画面中央に Lip Gloss 枠線付きモーダルをオーバーレイ表示。
  - `↑` / `↓` で項目移動、`Enter` で確定、`Esc` でキャンセルしてメイン画面へ復帰。

---

## 7. ビルド自動化仕様 (`build.bat`)

Pure Go ビルド用の Windows バッチファイル。PowerShell スクリプトは廃止し、本バッチファイルのみで運用する。

### 仕様要件（ルール完全準拠）
- **文字コード**: `Shift-JIS`
- **コメント構造**: 冒頭に「ヘルプがファイル下部に定義されている」旨を明記。
- **引数ハンドリング**:
  - `-h` または `--help` 実行時: 詳しい使い方（ビルドオプション、出力先、前提条件）を表示して終了。
  - 引数なし実行時: ビルド完了後、画面が勝手に閉じないよう `pause`（ユーザー入力待機）。
- **ビルドコマンド**:
  ```cmd
  set CGO_ENABLED=0
  go build -ldflags="-s -w" -o ReEncodeUtility.exe ./cmd/reencode
  ```

---

## 8. 設定ファイル `config.json` 完全仕様

```json
{
    "tools": {
        "ffmpeg_path": "ffmpeg",
        "ffprobe_path": "ffprobe",
        "qaac_path": "qaac64",
        "nero_aac_path": "neroAacEnc",
        "fdkaac_path": "fdkaac",
        "exiftool_path": "exiftool",
        "losslesscut_path": "LosslessCut.bat",
        "notify_script_path": "",
        "discord_webhook_url": "",
        "discord_mention_user_id": "",
        "discord_mention_on": "QueueCompleteOnly"
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

## 9. ディレクトリ構成 & ソースコード構成 (Pure Go / Bubble Tea)

```
Windows-ReEncodeUtility/
├── SPECIFICATION.md                # 本仕様書 (PS1完全準拠・完全網羅版)
├── build.bat                       # Pure Go ビルドバッチ (Shift-JIS / ヘルプ対応)
├── config.json                     # 設定ファイル (実行ファイルと同階層)
├── Templates/                      # ユーザーテンプレート保存用フォルダ (実行ファイルと同階層)
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
    └── runner/                     # FFmpeg実行・進捗解析・一時停止・タスクバー同期・電源制御・Discord通知
```
