
# Windows-ReEncodeUtility

FFmpeg を使用して、ドラッグ＆ドロップした動画ファイルを対話的かつ柔軟に一括再エンコードするための PowerShell ユーティリティです。Windows に加えて Linux にも対応しています（リポジトリ名は Windows-ReEncodeUtility のまま）。

ハードウェアエンコーディング対応、複数プラットフォーム自動最適化、テンプレート機能、高度なフィルタ処理などに加え、MiraBox等を用いた録画機能も備え、プロフェッショナルな動画処理を実現します。録画機能は Windows 専用です。


## PS Camera SBSの左右交換と4ch音声同期

既存のPSVR向けプロファイルとは別に、`Profiles/PS Camera SBS - 左右交換.psd1` を追加した。**左右映像を入れ替えるだけ**で、クロップ・拡縮・レンズ補正は行わない。映像は `hevc_qsv -global_quality 25 -preset veryslow`、音声はコピー（既存PSVRプロファイルと同設定）。MKVには正式な3D識別情報 `stereo_mode=left_right` を付与する。

**メインメニューの「テンプレートから選択」→「PS Camera SBS - 左右交換」**を選ぶと、エンコード時に外部音声の自動同期または手動オフセットを指定できる。WAVを選択した場合、メイン（ch1/ch4）と補助（ch2/ch3）の2トラックを同期してMKVに合成する。音声を選択しなければ、入力音声をコピーして3D情報付きのMKVを出力する。外部音声を選択した場合はメイン・補助の2トラックをOpus（各256kbps VBR）で保存する。

さらに、**メインメニューの「外部音声同期・マルチトラック合成」**を選べば、既存動画に外部音声だけを同期して結合できる。映像は再エンコードしない。

独立実行する場合は次のツールも利用できる。

- `Tools/Audio/Convert-AudioToStereo.ps1` — 4ch WAVをメイン（ch1/ch4）と補助（ch2/ch3）の2トラックに分離してMKA/Opusで保存
- `Tools/Audio/Sync-ExternalAudio.ps1` — 動画内の同期用音声と外部WAVを波形照合し、4ch入力時はメインと補助を同じタイミングで2音声トラックとして合成

他のPSVR用SBSプロファイル4種もMKVへ変更し、同じ `stereo_mode=left_right` を付与する。映像の変換処理は従来のまま維持する。

詳しくは [音声ツールの使い方](Tools/Audio/README.md) を参照。

> **メニュー操作**: `↑` / `↓` で移動、`Enter` で決定。**`Backspace` は一つ前の選択へ戻る**、**`Delete` は設定の最初（モード選択）まで戻る**、`Esc` は終了です。すべての対話メニューに共通です。

## 📋 目次

- [特徴](#特徴)
- [必要なもの（依存関係）](#必要なもの依存関係)
- [セットアップ](#セットアップ)
- [使い方](#使い方)
- [主要機能](#主要機能)
- [付属ツール](#付属ツール)
- [設定ファイル](#設定ファイル)
- [ファイル構成](#ファイル構成)
- [よくある質問](#よくある質問)
- [実装履歴](#実装履歴)

---

## ✨ 特徴

### 💻 ハードウェアエンコーディング対応

| **ハードウェア**   | **対応コーデック**                   | **備考**                                               |
| ------------------ | ------------------------------------ | ------------------------------------------------------ |
| **NVIDIA NVENC**   | H.264, H.265, AV1, VP9               | 最新RTX/GeForceで高速エンコード可能                    |
| **Intel QSV**      | H.264, H.265, AV1, VP9, mpeg2 ,mjpeg | 統合GPU/Arc/Xe での快適エンコード                      |
| **AMD AMF**        | H.264, H.265, AV1                    | RDNA 以降で AV1 対応                                   |
| **CPU (Software)** | H.264, H.265, AV1, VP9, VP8          | libx264/libx265/libsvtav1/libaom-av1/rav1e/libvpx など |

### 🎯 プラットフォーム自動最適化

下記プラットフォーム向けに、ファイルサイズ上限・品質・コーデックを自動計算し、容量内で最大品質を実現：

| **プラットフォーム** | **上限** | **推奨設定**                 |
| -------------------- | -------- | ---------------------------- |
| **Twitter**          | 512MB    | H.264 固定, 720p, AAC        |
| **Discord**          | 20MB     | 低ビットレート + HE-AAC/Opus |
| **catbox.moe**       | 200MB    | 任意コーデック選択可         |
| **uguu.se**          | 64MB     | 小容量向け最適化             |
| **GitHub**           | 100MB    | WebM/MP4 選択可              |
| **GitHub Release**   | 2GB      | 制限なし、高品質優先         |
| **カスタム**         | 任意指定 | ユーザー定義サイズ           |

### 🎞️ 高度なフィルター・処理機能

- **インターレース自動検出・解除** - MPEG2/古いビデオカメラの逆テレシネ、複雑なコーミング自動対応
- **スケーリング・クロップ** - 解像度自動調整やVR向けSBS変換（PSVR等）による最適化
- **チャプター分割** - 章立てで自動分割・個別エンコード
- **字幕分割** - SRT/ASS ベースの分割処理
- **中間ファイル作成** - CPUおよびハードウェアエンコーダーによる高品質中間形式（編集用・専用エンコード回路優先）
- **カスタムフィルタ** - FFmpeg フィルタグラフ直接指定対応

#### 中間ファイル作成モードのハードウェアエンコード

CPU（従来のH.264/H.265）に加えて、NVENC・QSV・AMF・Vulkan Video・D3D12VA・Media Foundationの利用可能な映像エンコーダーを選択できます。ハードウェア選択時の既定値は「専用エンコード回路優先（補助演算を抑制）」です。「通常のハードウェアエンコード」も選択可能です。

| バックエンド | 専用回路優先時の制御 |
| --- | --- |
| NVIDIA NVENC | Lookahead、空間/時間AQ、Weighted Prediction、Temporal Filter、Multipassを無効化 |
| Intel QSV | `low_power=1`（VDEnc対応時）、Lookahead・ExtBRC・MBBRC・RDOを無効化 |
| AMD AMF | PreAnalysis・PreEncode・VBAQ・High Motion Quality Boost・AQを無効化 |
| Vulkan Video / D3D12VA | ハードウェアビデオエンコードAPIを使用。FFV1 Vulkanなどのシェーダーエンコーダーは対象外 |
| Media Foundation | `hw_encoding=1` でハードウェアに限定 |

オプションは実行中のFFmpegビルドが公開するものだけを指定します。Vulkan Video、D3D12VA、MF、および一部のQSVコーデックでは、内部の補助演算を完全に禁止するAPIがないため、専用回路のみを保証するものではありません。設定確定前に短い映像でテストエンコードし、失敗時は設定を選び直します。通常方式や下位ピクセル形式に自動変更しません。

固定QP等の高品質設定やピクセル形式を選択でき、NVENCのP7など専用回路側の品質設定も利用できます。明示したソフトウェアピクセル形式とGPUデコードの出力が競合する場合はCPUデコードに切り替え、8-bit NV12への強制変換を避けます。Vulkan Video/D3D12VAではCPUデコード・フィルター処理後に指定形式でGPUへアップロードします。エンコード設定は従来どおり独立テンプレートに保存できます。

#### 安定性の自動強化（事前検証・段階的フォールバック）

- エンコード前に、同じ設定を数フレームだけ試す**事前検証**を自動実行します。失敗する設定は本番前に検出され、成功する経路から処理を開始します。
- HWエラー時は「GPUスケール→CPUスケール」「HWアクセルなし（HWエンコーダは維持）」の順に**段階的に再試行**します。3箇所に重複していたリトライ処理を1つに集約し、ログに `[Fallback] tier N` として記録します。
- 検証結果は `.cache/encode-capability-cache.clixml` に保存され、2回目以降は即座に判定します。設定変更やFFmpeg更新時は自動的に無効化されます。手動で捨てたい場合は `re-encode-AIOptimus.ps1 -ClearEncodeCapabilityCache` を実行してください。
- D3D11VAデコード＋QSVエンコードでは、GPUフレームを維持できる経路（`scale_qsv` / `hwmap` / `vpp_qsv`）を実動画でプローブし、成功した場合のみ採用します。従来どおりCPUリサイズに戻ることもあります。

### 🎛️ 柔軟なエンコード制御

**品質方式を用途に応じて選択：**

- **CRF（Constant Rate Factor）** - 品質ベース、可変ビットレート
- **CRF+Maxrate** - 品質 + ファイルサイズ上限（プラットフォーム対応）
- **ビットレート** - 固定ビットレート
- **2 Pass Bitrate** - CPU エンコーダーの容量精密制御

### 📋 豊富なテンプレート機能

よく使う設定を**エンコード**と**フィルター**に分けて保存・再利用できます。

- `Profiles/Encoding/*.psd1`：映像・音声のエンコード設定。通常・中間・分割モードで読み込み可能。
- `Profiles/Filters/*.psd1`：映像フィルターと必要に応じた追加FFmpeg引数。通常・従来テンプレート・プラットフォーム（おまかせ/詳細）・中間・分割モードで適用可能。
- `Profiles/*.psd1`：従来の一体型テンプレート。読み込み・保存の互換性を維持。

設定の最後に開く「共通テンプレート設定」で読み込み・保存を選びます。プラットフォームモードでは既存の解像度調整フィルターを維持し、読み込んだフィルターを前段に合成します。

**各目が16:9でないSBSを16:9にする場合**

`Profiles/Filters/` の「SBS 2D - 各目16：9パッド」は、左右の映像を縮小せずに黒帯を追加し、各目を16:9（SBS全体では32:9）にします。目が縦長なら左右に、横長なら上下に黒帯を足します。

**SBSを一般的な横長動画として投稿する場合**

`Profiles/Filters/` の「VLC式アナグリフ」は、VLCの Anaglyph 3D 標準設定と同じ**赤（左眼）＋シアン（右眼）**方式で、SBSの2映像を1画面に重ねます。**左眼の赤成分と右眼の緑・青成分**を合成し、左右の映像のずれが赤／シアンの輪郭として明確に現れます。左右のフレーム切り替えではありません。フルSBSとハーフSBSを別々に用意し、ハーフSBSでは片眼の横圧縮をLanczosで補正します。

色成分をいったん16-bit RGB（`gbrp16le`）へ変換してから処理し、低精度RGBでの合成を避けます。適用時のGPUデコードは8-bit NV12への強制変換を避けるためCPUデコードに切り替わります。最終的な色深度と画質は、選択したエンコード設定・プラットフォーム側の再圧縮によります。

一般の2D画面でも単一映像として再生でき、赤シアン眼鏡を使用すれば立体視できます。眼鏡なしでは色ずれが見える方式であり、元のSBS映像の全色情報を1画面に完全保存することはできません。

X向けのMP4/H.264等の出力形式は、プラットフォームモードで指定してください。元のSBSファイルは変更しません。

### 🔊 多彩な音声エンコード対応

**外部エンコーダー（自動検出・利用可能なもののみ表示）：**

- **qaac** - Appleの高速AACエンコーダー（HE-AAC/AAC-LC 自動選択）
- **Nero AAC Encoder** - 高品質AAC（-q 0.20 ～ 0.65）
- **fdkaac** - Fraunhofer FDKベース（VBR 1-5）

**FFmpeg 内蔵：**

- **AAC** - HE-AAC/AAC-LC, ビットレート指定( **非推奨** )
- **Opus** - 最新フォーマット（libopus）。Ambisonics（`ambisonic 1`など）や非標準な多チャンネルレイアウトの入力を自動検出し、適切な `-mapping_family` オプション（アンビソニックスは `2`、その他非標準は `255`）を自動付与してエンコードエラーを防ぐ機能を搭載。
- **Vorbis** - WebM 用（libvorbis）
- **FLAC** - ロスレス音声（高品質中間ファイル用）

### 📊 詳細ログ出力

- エンコード進捗（現在時刻、速度、fps, ビットレート）
- GPU/HW 処理情報（NVENC/QSV/AMF の実行状況）
- FFmpegのPID単位でCPU・GPU使用率を記録。500ms間隔で測定し、CPUは全論理プロセッサーに対する平均・ピーク、CPU時間を出力。GPUはWindowsのPDHカウンターから取得できた全エンジンを個別に記録し、平均・ピーク・サンプル数を出力する。エンジンの種類による絞り込みは行わない。取得できない項目はN/Aとし、他プロセスの負荷は含めない。
- FFmpeg 標準エラー・警告の色付け記録
- 環境情報（OS, PowerShell, FFmpeg バージョン）

### ⚙️ その他機能

- **複数ファイル一括処理** - 複数動画を連続エンコード可能
- **フォルダ指定対応** - ディレクトリ内の動画を自動検出
- **メタデータ保持・抽出** - exiftool 統合で作成日時等の保持

---

## 📦 必要なもの（依存関係）

### 必須

| **ツール**              | **用途**             | **インストール**                                                          |
| ----------------------- | -------------------- | ------------------------------------------------------------------------- |
| **FFmpeg**              | 動画エンコーディング | [ffmpeg.org](https://ffmpeg.org/download.html) または PATH 環境変数に登録 |
| **FFprobe**             | 動画情報取得         | FFmpeg に付属                                                             |
| **PowerShell 5.1 以上 / PowerShell 7** | スクリプト実行 | Windows 10/11 に含まれる 5.1、または [7 をインストール](https://learn.microsoft.com/ja-jp/powershell/scripting/install/installing-powershell-on-windows)。どちらでも動作 |

### オプション（外部音声エンコーダー）

利用可能なもののみ自動検出され、メニューに表示されます：

| **ツール**           | **用途**                     | **URL**                                                          | **備考**                              |
| -------------------- | ---------------------------- | ---------------------------------------------------------------- | ------------------------------------- |
| **qaac**             | AAC エンコーディング（高速） | [GitHub](https://github.com/nu774/qaac)                          | 長年にAppleが熟成させている。要iTunes |
| **Nero AAC Encoder** | 高品質 AAC                   | [Nero](https://www.nero.com/jpn/tools-nerodigitalaudiolabs.html) | 古いが高評価、品質 -q で細かく制御    |
| **fdkaac**           | Fraunhofer FDK ベース AAC    | [GitHub](https://github.com/kekyo/fdk-aac-win32-builder)         | VBR/HE-AAC 対応                       |
| **fdkaac (Linux)**   | Fraunhofer FDK ベース AAC    | `apt install fdkaac`                                            | Linux ネイティブ CLI。qaac / Nero は Linux では未設定 |

Linux では qaac / Nero は未設定です。fdkaac は `Get-Command` で自動検出し、未検出時は FFmpeg 内蔵 AAC/Opus へフォールバックします（従来どおり）。

### オプション（補助ツール）

| **ツール**      | **用途**           | **インストール**                                              | **必須度**                             |
| --------------- | ------------------ | ------------------------------------------------------------- | -------------------------------------- |
| **exiftool**    | メタデータ処理     | [exiftool.org](https://exiftool.org/)                         | 低（メタデータ保持機能を使う場合のみ） |
| **LosslessCut** | ビジュアル編集補助 | [MaCleaner 12 / GitHub](https://github.com/mifi/lossless-cut) | 低（設定例のみ）                       |

Windows PowerShell 5.1（`powershell.exe`）には非対応です。`pwsh.exe` を使用してください。Linux でも PowerShell 7 (`pwsh`) / FFmpeg / ffprobe が必須です。

---

## 🔧 セットアップ

### 1. FFmpeg・FFprobe のインストール

**PATH に登録済みの場合** - そのまま利用可（下記スキップ）

**ローカルインストール** - 解凍後、パスを config.user.psd1 に記載

```powershell
# 動作確認
ffmpeg -version
ffprobe -version
```

### 2. config.user.psd1 の設定

リポジトリ直下の `config.user.psd1` を開き、各ツールのパスを設定：

```powershell
@{
    # --- 必須プログラムのパス ---
    FfmpegPath       = "ffmpeg"           # PATH に登録済みなら "ffmpeg" のままで OK
    FfprobePath      = "ffprobe"

    # --- 音声エンコーダー (オプション) ---
    # 使用しない場合は空欄 "" のままにしておけ。
    QaacPath         = "qaac64"           # または "C:\path\to\qaac64.exe"
    NeroAacEncPath   = "neroAacEnc"
    FdkaacPath       = "fdkaac"

    # --- 補助ツール (オプション) ---
    ExifToolPath     = "exiftool"
    LosslessCutPath  = "C:\path\to\LosslessCutPortableFast.bat"

    # --- その他 ---
    NotifyScriptPath = ""                 # エラー通知用スクリプトのパス
}
```

### 3. 実行権限の確認（必要に応じて）

```powershell
# PowerShell 7 (pwsh) で実行
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 4. 起動テスト

```powershell
# コマンドラインで実行（引数なしでヘルプ表示）
.\start.bat -h
```

### Linux でのセットアップ

- PowerShell 7 (`pwsh`) / FFmpeg / ffprobe をインストール（必須。Windows PowerShell 5.1 は非対応）。
- 起動は `./start.sh`（引数なし / `-h` / `--help` でヘルプ表示）。
- `sudo ./SETUP.SH -i` で `/usr/local/bin` に `ReEncode_*.sh` のシンボリックリンクを張り、`-u` で解除。PATH は `/usr/local/bin` または `~/.local/bin`。
- 設定は `config.user.linux.psd1`（`$IsLinux` 時に自動読み込み。Windows は従来の `config.user.psd1`）。
- HW は VAAPI を追加（`-vaapi_device` は `VaapiDevicePath`、既定 `/dev/dri/renderD128`）。NVENC/QSV は FFmpeg の実Detectに任せる。MF / D3D11VA / D3D12VA / DXVA2 は Linux では選択肢に出さない。Vulkan は従来どおり制限付き。
- GPU 使用率ログは Windows の PDH 依存のため Linux では N/A（CPU/GPU 監視は無効化）。
- 設定画面の描画: Windows は従来どおり画面全体をクリアするが、Linux では `Clear-Host` を使わず、メニュー行だけを ANSI エスケープで書き換える（画面全体を上書きしない）。確認画面も Linux ではクリアせず追記表示する。
- メニュー中の Ctrl+C: Linux では Ctrl+C をキー入力として受け取り（[Console]::TreatControlCAsInput）、Esc と同じくメニューをキャンセルしてスクリプトを終了する。以前は別キーを押さないと画面が更新されなかったが、Ctrl+C を押した時点で選択行を消して終了する。

---

## 🚀 使い方

### 基本的な使用方法

#### 方法 1：ドラッグ&ドロップ（推奨）

1. `start.bat` に動画ファイルをドラッグ&ドロップ
2. 対話メニューで以下を選択：
   - 映像コーデック（H.264/H.265/AV1/VP9 など）
   - ハードウェア（NVIDIA/Intel/AMD/CPU）
   - 品質・プリセット・フィルタ
   - 音声エンコーダー・ビットレート
3. エンコード開始

#### 方法 2：コマンドライン実行

```powershell
# 単一ファイル
.\re-encode-AIOptimus.ps1 "C:\Videos\input.mp4"

# 複数ファイル
.\re-encode-AIOptimus.ps1 "C:\Videos\video1.mp4" "C:\Videos\video2.mkv"

# フォルダ指定（フォルダ内の全動画を処理）
.\re-encode-AIOptimus.ps1 "C:\Videos\"

# ヘルプ表示
.\start.bat -h
```

#### 方法 3：Linux での起動

```bash
./start.sh              # 対話メニュー起動
./start.sh -h           # ヘルプ
./start.sh --help
```

動画ファイルは `./start.sh /path/to/input.mp4` のように渡せます（複数ファイル・フォルダにも対応）。`sudo ./SETUP.SH -i` で PATH にシンボリックリンクを登録しておくと、`ReEncode_start.sh` を任意のディレクトリから呼び出せます。

### QSV非同期処理数（メニュー項目なし）

QSVエンコード時は `-async_depth 24` を優先し、FFmpegがエラー終了した場合のみ `-async_depth` を指定せずに再試行します（FFmpeg既定値は4）。エンコードが正常終了していても遅い場合の自動最適化は行いません。Bフレーム設定は変更せず、DTS警告だけでは再試行しません。

初回からFFmpegの既定値で開始したい場合は、起動時に `-QsvDefaultDepth` を付けます。選択メニューに項目は追加されません。

エンコード開始時と完了時には、画面とログファイルへ `QSV非同期モード` として「高速化 (24)」「FFmpeg既定値」「手動指定」のどれを使用したか表示します。Depth 24で失敗した場合は、フォールバック開始とその結果も記録します。

```powershell
.\re-encode-AIOptimus.ps1 -QsvDefaultDepth "C:\Videos\input.mp4"
.\start.bat -QsvDefaultDepth "C:\Videos\input.mp4"
```

FFmpegの追加引数などで `-async_depth` が明示指定されている場合は、その値を優先します。この機能はQSVエンコーダーだけが対象で、その他のエンコーダーには適用しません。
### インタラクティブメニュー詳細

#### 【メイン】モード選択

```text
1. 通常モード        → 対話式で詳細設定を選択
2. テンプレートモード  → 保存済みテンプレートから選択
3. プラットフォームモード → Twitter/Discord/GitHub 向け自動最適化
4. 中間ファイルモード   → yuv444p/yuv422p 高品質編集用中間ファイル作成
5. 分割モード        → チャプター/字幕で分割してエンコード
```

#### 【通常モード】ハードウェア選択

```text
実際のテスト結果に基づき、対応ハードウェアのみが表示されます：

✓ NVIDIA (NVENC) - 自動検出
✓ Intel (QSV)    - 自動検出
✓ AMD (AMF)      - 自動検出
✓ CPU (Software) - 常に利用可能

```

#### 【通常モード】品質設定例

**NVIDIA エンコーダーの場合：**

```text
品質方式：
  ├─ CRF（可変ビットレート）
  │  └─ CQ値指定（23=高品質、28=中、32=低速）
  │
  ├─ CRF+Maxrate（品質 + ファイルサイズ上限）
  │  └─ CQ + ビットレート上限で両立
  │
  └─ ビットレート（固定）
```

**CPU エンコーダーの場合：**

```text
H.264/H.265:
  ├─ CRF（推奨）- 品質ベース
  ├─ CRF+Maxrate - 容量制限を加える
  ├─ 2-pass Bitrate - 正確な容量控制（遅い）
  └─ カスタム

AV1:
  ├─ libsvtav1 - 高速（推奨）
  ├─ libaom-av1 - 最高品質（⚠ 非常に遅い）
  └─ rav1e - 中速・実験的
```

#### 【プラットフォームモード】自動設定の流れ

```text
1. プラットフォーム選択（Twitter/Discord/catbox.moe など）
     ↓
2. セットアップ方法（簡単 / カスタマイズ）
     ↓
3. 【簡単】自動設定で OK → エンコード開始
   または
   【カスタマイズ】個別設定 → HW / コーデック / 品質 / 音声を選択
     ↓
4. インターレース検出（古いビデオカメラ/DVD 対応）
     ↓
5. エンコード開始
```

---

## 🎯 主要機能

### 1. ハードウェア自動検出とキャッシュ機構

スクリプト開始時に各 HW エンコーダーでテストエンコードを実行し、実対応状況を検出します。

結果は `.cache/hardware-scan-cache.clixml` にキャッシュされ、次回以降の起動が高速化されます。

```powershell
# ログ出力例
[2026-06-11 10:00:00] [DEBUG] テスト結果: NVIDIA=False Intel=True AMD=False Vulkan=False D3D12VA=False MF=True
[2026-06-11 10:00:00] [DEBUG]   エンコーダー: [h264_mf, h264_qsv, hevc_qsv, mjpeg_qsv, mpeg2_qsv, vp9_qsv, aac_mf, mp3_mf]
[2026-06-11 10:00:00] [DEBUG]   HWアクセル  : [qsv, d3d11va, dxva2, vulkan]
```

未対応のハードウェア・コーデックは自動除外。

HWデコード／HWエンコード使用時は、利用中のHWで使えるフィルターも自動選択する。`scale` を `scale_qsv` / `scale_cuda` / `vpp_amf` などへ、`yadif` / `bwdif` を `yadif_cuda` / `deinterlace_qsv` などへ置換する。FFmpegが公開していることに加え、短い実エンコードで成功した候補だけを採用する。判定結果は `.cache/hardware-filter-cache.clixml` にFFmpegシグネチャ付きで保存され、FFmpeg更新時や7日経過時に再判定する。等価なHWフィルターがない `lenscorrection` などはCPUのまま実行する。

`split` / `crop` / `pad` などCPU専用フィルターを含む `-filter_complex` をHWデコードと併用する場合、入力のHWフレームを `hwdownload,format=nv12` でCPUへ渡すよう自動補正する。

### 2. インターレース自動検出・解除

古い映像形式（MPEG2、NTSC/PAL映像、ビデオカメラ）の逆テレシネ・デインターレース：

```text
検出方法：
    ├─ FFprobe の field_order フィールド確認
    ├─ idet フィルタでの複数フレーム検査
    └─ フレーム属性から interlaced_frame = 1 検出

除去フィルタオプション：
    ├─ fieldmatch,decimate       - 逆テレシネ（通常アニメ）
    ├─ fieldmatch,nnedi,decimate - 高品質逆テレシネ（学習ウェイト DL）
    ├─ bwdif                     - 標準デインターレース（推奨）
    ├─ nnedi                     - 高品質（非常に重い）
    └─ w3fdif                    - 高速デインターレース
```

### 3. プラットフォーム自動最適化

容量上限に収めながら最高品質を自動計算します。

**例：Discord (20MB 上限)**

```text
入力：60秒 動画
計算プロセス：
    1. 総ビットレート上限 = (20MB × 0.90) × 8 × 1024 / 60秒
    2. 音声: Opus 64kbps → 音声ビットレート = 64kbps
    3. 映像ビットレート = 総上限 - 音声
    4. H.265 QSVの場合：品質目標22と、容量予算から算出した映像レートをQVBRへ設定

結果：H.265 QSV QVBR (品質22 + ビットレート予算) で上限20MB以内を目標に制御
```

プラットフォームへのアップロードモードでは、すべての映像コーデックをCFR（固定フレームレート）で出力します。セットアップ時の「出力FPS」でEnterを押せば従来の自動検出（ffprobeの`r_frame_rate`、取得できなければ`avg_frame_rate`）を使います。手動指定したい場合は`60`、`59.94`、`60000/1001`のようにFPSを入力してください。出力側の`-r:v`と`-fps_mode:v cfr`により、表示時刻に合わせて必要なフレームの複製・間引きを行います。自動検出に失敗した場合もCFRを有効にし、FPSはFFmpegの判定に任せます。通常のエンコードモードには影響しません。

Intel H.265 QSVは容量制限時にQVBRを使います。通常の品質優先モードはICQのままです。QVBRは品質値と目標ビットレートを併用しますが、厳しい容量上限でICQと同じ画質を保証するものではありません。実際の制御方式はFFmpegのverboseログを確認して記録します。サイズ超過時は自動再エンコードせず警告します。

Intel VP9 QSVは容量制限時にVBRを使います。動画長と上限サイズから平均ビットレートを自動算出し、最大ビットレートをその2倍に設定します。出力サイズが上限を超えた場合は、他のコーデックと同様に警告だけを表示します。通常の品質優先モード（`-q:v`）は変更しません。

**計算メトリクス：**

```text
マージンファクタ：
  ├─ H.264/H.265 = 0.90
  ├─ VP9 = 0.88
  ├─ SVT-AV1 = 0.82
  └─ libaom-av1 = 0.80
```

### 4. 外部音声エンコーダー統合

外部エンコーダーが利用可能な場合、自動的にメニューに追加：

**qaac の例：**
```text
選択フロー：
  1. qaac → ハイレベルオプション選択
  2. AAC-LC (TVBR品質) / HE-AAC (CVBR ビットレート)
  3. 品質値入力 → qaac --tvbr 73 等で実行
```

失敗時の自動フォールバック：
```
外部エンコーダー実行失敗
  → ソース音声がコンテナ互換 ?
     ├─ YES → 音声をコピー (-c:a copy)
     └─ NO → 音声を除去 (-an)
```

### 5. 高性能リアルタイム進捗とファイルサイズ予測

WebM、MKV、MP4 などのコンテナ書込みバッファリングによるサイズや予測値の更新遅延を解消し、リアルタイムで正確な進捗情報を出力します：

- **バッファ遅延の可視化**: ディスク書込みサイズ（実績値）に加えて、メモリ内にバッファされている推定サイズを `作成済: [実サイズ] + [バッファ推定差分]` として合算表示します。
- **フレーム数ベースの動的予測**: 起動時に入力動画のフレームレート（FPS）を `ffprobe` で動的取得し、エンコード済フレーム数（`frame=`）を基に1フレームごとに予測ファイルサイズ・平均レートを逆算・更新します。これにより、書き出しが発生していないエンコード初期（開始5秒間）でも表示が `"N/A"` でフリーズすることなく、開始1秒目から滑らかに予測値が動き続けます。
- **高精度フォーマット**: 進捗時間を小数点第3位（ミリ秒）に制限し、エンコード速度は小数点第2位（例: `0.24x`）まで詳細表示します。
- **画面レイアウトの崩れ防止**: 実行コンソールのウィンドウ幅を自動検出し、バッファリング警告文や進捗テキストがコンソール端で自動折り返し（改行）を起こして進捗行が崩れるのを防ぐ、スマートな動的切り捨て・パディング処理を実装しています。

### 6. ログ記録

```
ログ格納場所：<出力フォルダ>/re-encode-log-YYYYMMdd-HHmmss.log

含まれる情報：
  ├─ 実行環境（Windows版, PS版, FFmpeg版）
  ├─ エンコード進捗（タイムコード, 速度, fps, ビットレート）
  ├─ GPU/HW処理情報（NVENC/QSV/AMF のアクティブ状況）
  ├─ FFmpeg 警告・エラー（カラー分類）
  └─ 所要時間・エンコード完了情報
```

### GPUリサイズとフレーム保持

- GPUデコード中の `scale=幅:-2` は、利用可能なGPUフィルター（`scale_qsv`、`scale_cuda`、`vpp_amf`、`scale_d3d11`、`scale_vulkan` など）へ自動切替。対応フィルターは `ffmpeg -h filter=フィルター名` で直接判定します（QSVは `scale_qsv` がない場合 `vpp_qsv` を確認）。
- GPU処理に対応しないフィルターやCPUエンコーダーでは、必要な時点でのみ `hwdownload` を行います。D3D11VAデコード＋QSVエンコードでは実機検証済みの `hwdownload,format=nv12,scale` を優先します。それ以外のD3D11VAのGPUリサイズでは出力形式をNV12に明示し、実行時にテクスチャ生成などで失敗した場合はD3D11VAデコードを維持してCPUリサイズを再試行します。それでも失敗した場合は既存のCPUデコードへの再試行を行います。DXVA2はデコーダーを切り替えずに保持し、GPUスケーラーがないため `hwdownload` 後にCPUリサイズします。
- フレームレートが明示指定されていない場合は `-fps_mode:v passthrough` で元のフレーム時刻を保持します。入力がVFRなら出力もVFRになります。

### 7. エラーハンドリング

**HW アクセルエラー自動リトライ：**
```text
HW アクセルでエラー発生
  → CPU へ自動フォールバック（-hwaccel削除）
  → 再エンコード実行
```

**音声エンコーダー失敗時：**
```text
外部エンコーダー実行失敗
  → ソース音声互換性チェック
  → コピーまたは除去へ自動切り替え
```

## 📺 付属ツール

### 音声同期の検証 (`Tests/Test-ExternalAudioSync.ps1`)

外部エンコーダー（qaac / nero / fdkaac）と ffmpeg 内蔵エンコーダーについて、既知のタイミングで入れたビープ音／ノイズを基準にリップシンクを実測します。結果は `.cache/external-audio-sync.json` に保存されます。

- ffmpeg 内蔵エンコーダーはすべて **0ms**（ベースライン）
- 外部の AAC-LC と nero HE-AAC は **0ms**
- **qaac / fdkaac の HE-AAC は約 +20ms の遅延** → アプリの自動選択では使用せず、手動選択時は警告を表示

### ハードウェアエンコーダー制限チェック (`Tools/Check-HardwareEncoderLimits.ps1`)

利用可能な映像エンコーダーについて、短い合成映像で**実能力を自動プローブ**します。

```powershell
pwsh -ExecutionPolicy Bypass -File .\Tools\Check-HardwareEncoderLimits.ps1
# -Force でスキャンキャッシュを無視、 -Quick で利用可否と品質オプションのみ
```

- 利用可否、使える品質指定（`-global_quality` / `-q:v` / `-b:v` / `-crf` 等）、ピクセル形式
- エンコード可能な最大解像度（例: この環境の `mpeg2_qsv` は **1920x1080** が上限）
- HWデコード（`qsv` / `d3d11va` / `dxva2` / `vulkan`）から各エンコーダーへの接続可否

結果は `.cache/hardware-limits.json` に保存されます。一時ファイルはすべて `.cache` 配下に作られ、プロジェクト外は触りません。

### 録画＆プレビュー機能 (`Record-MiraBox-Stable.ps1`)

MiraBox等のキャプチャデバイスから映像を取り込み、**ゼロコピープレビュー付き**で録画を行うスタンドアロンスクリプトです。

- **Windows標準ハードウェアアクセラレーション (d3d11va)** を活用した軽量プレビュー(ffplay)
- **teeマルチプレクサ**を利用し、エンコード負荷を最小限に抑えながらMKV保存とUDPストリーミングを並行処理
- 面倒な設定なしで、保存先をインタラクティブに選択可能

この録画スクリプトは dshow に依存するため Windows 専用です。Linux では使用できません。

---

## ⚙️ 設定ファイル

### config.user.psd1

実行ファイル（FFmpeg、外部エンコーダー等）のパスを設定する中心ファイルです。詳細はリポジトリ内の[当該ファイル](config.user.psd1)を参照してください。Windows で使用します。

### config.user.linux.psd1

Linux 用の設定ファイルです。`$IsLinux` 時に自動読み込みされます。FFmpeg / ffprobe / 外部エンコーダーのパスに加え、VAAPI のデバイスパスを `VaapiDevicePath`（既定 `/dev/dri/renderD128`）で指定できます。Windows では従来の `config.user.psd1` を使用します。

### テンプレートファイル（Profiles/*.psd1）

従来の一体型プロファイルはこの階層に残し、新規の独立テンプレートは `Encoding/` と `Filters/` に保存します。PSVR向けの既存SBSプロファイルも引き続き使用できます。

## 📂 ファイル構成

```text
動画再エンコード/
├── start.bat                     # 起動用バッチファイル (Windows)
├── start.sh                      # 起動スクリプト (Linux。引数なし / -h / --help)
├── SETUP.SH                      # Linux 用シンボリックリンク設定 (-i 登録 / -u 解除)
├── re-encode-AIOptimus.ps1       # メイン処理スクリプト
├── get-ffmpegOptions.ps1         # エンコード設定メニュー構築スクリプト
├── Get-HardwareInfo.ps1          # ハードウェア検出スクリプト
├── Record-MiraBox-Stable.ps1     # 録画＆プレビュー用スクリプト (MiraBox対応、Windows 専用)
├── config.user.psd1              # 環境設定ファイル（要編集、Windows）
├── config.user.linux.psd1        # Linux 用環境設定ファイル（$IsLinux 時に自動読み込み）
├── README.md                     # このファイル
├── IMPLEMENTATION_HISTORY.md     # 実装変遷記録
├── .cache/                       # ハードウェアスキャン等のキャッシュ保存先
│   └── hardware-scan-cache.clixml
├── Modules/TemplateManager.ps1   # エンコード・フィルターテンプレート管理
└── Profiles/                     # テンプレート保存先
    ├── Encoding/                  # エンコード設定
    ├── Filters/                   # すべてのエンコードモードで使用する映像フィルター
    │   ├── SBS 2D - フル - VLC式アナグリフ.psd1
    │   └── SBS 2D - ハーフ - VLC式アナグリフ.psd1
    ├── PSVR SBS - フル.psd1
    ├── PSVR SBS - ハーフ.psd1
    ├── PSVR SBS - フル - クロップ - 16：9.psd1
    ├── PSVR SBS - フル - クロップ - 4：3.psd1
    ├── 暫定アニメ用-with-VP9.psd1
    └── ...
```

---

## ❓ よくある質問

### Q1. PowerShell スクリプトが実行できない

**A:** PowerShell 7 が入っているか確認し、必要なら実行権限を許可してください。

```powershell
pwsh -v
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

`powershell.exe`（Windows PowerShell 5.1）ではなく `pwsh.exe` を使ってください。

### Q2. FFmpeg / FFprobe が見つからない

**A:** 以下のいずれかを実施：

**方法 1：PATH に追加（推奨）**
```
Windows設定 → 詳細設定 → 環境変数 → PATH に FFmpeg フォルダを追加
その後 PowerShell を再起動
```

**方法 2：config.user.psd1 で直接指定**
```powershell
FfmpegPath = "C:\path\to\ffmpeg.exe"
FfprobePath = "C:\path\to\ffprobe.exe"
```

### Q3. ハードウェアエンコーダーが認識されない

**A:** スクリプト実行時の自動テスト（`.cache`を利用）で対応していないと判定されています。ドライバの更新を確認するか、CPUエンコーダーを使用してください。

### Q4. 外部音声エンコーダー（qaac など）が検出されない

**A:** config.user.psd1 のパスを確認：

```powershell
# PATH に登録済みの場合
QaacPath = "qaac64"

# ローカルインストール
QaacPath = "C:\path\to\qaac64.exe"
```

### Q5. エンコード中止したい

**A:** Ctrl+C で中断できます。ffmpeg 子プロセスも終了させますが、書きかけの出力ファイルは残ります。

### Q6. テンプレートを自作したい

**A:** 各モードの設定完了後、共通テンプレート画面で「エンコードテンプレートを保存する」または「フィルターテンプレートを保存する」を選んでください。従来の一体型プロファイルも同じ画面から保存できます。

### Q7. Linux で起動・インストールしたい

**A:** `./start.sh` で起動します（`-h` / `--help` でヘルプ）。`sudo ./SETUP.SH -i` で `/usr/local/bin` に `ReEncode_*.sh` のシンボリックリンクを張り、`-u` で解除できます。PATH に `/usr/local/bin` または `~/.local/bin` が通っている必要があります。設定は `config.user.linux.psd1` に記載します。qaac / Nero は Linux では未設定で、fdkaac は `apt install fdkaac` のネイティブ CLI を使います。

## 📚 実装履歴

詳細な変更履歴は [IMPLEMENTATION_HISTORY.md](IMPLEMENTATION_HISTORY.md) を参照してください。

このスクリプトは初期版の GitHub コード を AI で最適化し、以来継続的に改善されています。

---

## 📄 ライセンス

ライセンスとかよくわかりません。個人用を公開してるだけです。もし使う人がいるなら一般常識の範囲で自由にどうぞ。

ただし FFmpeg や各外部ツールのライセンスに従うこと。

---

## 🤝 貢献

改善提案・バグ報告は Issue / Pull Request でお願いします。

**最終更新：** 2026-11-19
