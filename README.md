# Windows-ReEncodeUtility

FFmpeg を使用して、ドラッグ＆ドロップした動画ファイルを対話的かつ柔軟に一括再エンコードするための PowerShell ユーティリティです。  
ハードウェアエンコーディング対応、複数プラットフォーム自動最適化、テンプレート機能、高度なフィルタ処理など、プロフェッショナルな動画処理を実現します。

---

## 📋 目次

- [特徴](#特徴)
- [必要なもの（依存関係）](#必要なもの依存関係)
- [セットアップ](#セットアップ)
- [使い方](#使い方)
- [主要機能](#主要機能)
- [設定ファイル](#設定ファイル)
- [ファイル構成](#ファイル構成)
- [よくある質問](#よくある質問)
- [実装履歴](#実装履歴)

---

## ✨ 特徴

### 💻 ハードウェアエンコーディング対応

| ハードウェア | 対応コーデック | 備考 |
|-----------|---------------|------|
| **NVIDIA NVENC** | H.264, H.265, AV1, VP9 | 最新RTX/GeForceで高速エンコード可能 |
| **Intel QSV** | H.264, H.265, AV1, VP9 | 統合GPU/Arc/Xe での快適エンコード |
| **AMD AMF** | H.264, H.265, AV1 | RDNA 以降で AV1 対応 |
| **CPU (Software)** | H.264, H.265, AV1, VP9, VP8 | libx264/libx265/libsvtav1/libaom-av1/rav1e/libvpx など |

### 🎯 プラットフォーム自動最適化

下記プラットフォーム向けに、ファイルサイズ上限・品質・コーデックを自動計算し、容量内で最大品質を実現：

| プラットフォーム | 上限 | 推奨設定 |
|------------|------|--------|
| **Twitter** | 512MB | H.264 固定, 720p, AAC |
| **Discord** | 10MB | 低ビットレート + HE-AAC/Opus |
| **catbox.moe** | 200MB | 任意コーデック選択可 |
| **uguu.se** | 64MB | 小容量向け最適化 |
| **GitHub** | 100MB | WebM/MP4 選択可 |
| **GitHub Release** | 2GB | 制限なし、高品質優先 |
| **カスタム** | 任意指定 | ユーザー定義サイズ |

### 🎞️ 高度なフィルター・処理機能

- **インターレース自動検出・解除** - MPEG2/古いビデオカメラの逆テレシネ、複雑なコーミング自動対応
- **スケーリング** - 解像度自動調整による容量最適化
- **チャプター分割** - 章立てで自動分割・個別エンコード
- **字幕分割** - SRT/ASS ベースの分割処理
- **中間ファイル作成** - yuv444p/yuv422p の高品質中間形式（編集用）
- **カスタムフィルタ** - FFmpeg フィルタグラフ直接指定対応

### 🎛️ 柔軟なエンコード制御

**品質方式を用途に応じて選択：**
- **CRF（Constant Rate Factor）** - 品質ベース、可変ビットレート
- **CRF+Maxrate** - 品質 + ファイルサイズ上限（プラットフォーム対応）
- **ビットレート** - 固定ビットレート
- **2 Pass Bitrate** - CPU エンコーダーの容量精密制御

### 📋 テンプレート機能

よく使う設定をテンプレートに保存・再利用可能：
- ハードウェア・コーデック・品質・プリセット・フィルタを一括保存
- テンプレート切り替えで即座に設定適用
- 複数テンプレートで用途別運用

### 🔊 多彩な音声エンコード対応

**外部エンコーダー（自動検出・利用可能なもののみ表示）：**
- **qaac** - Apple M1 以降の高速 AAC エンコーダー（HE-AAC/AAC-LC 自動選択）
- **Nero AAC Encoder** - 高品質 AAC（-q 0.20 ～ 0.65）
- **fdkaac** - Fraunhofer FDK ベース（VBR 1-5）

**FFmpeg 内蔵：**
- **AAC（libfdk_aac/libfdk_aac）** - HE-AAC/AAC-LC, ビットレート指定
- **Opus** - 最新フォーマット（libopus）
- **Vorbis** - WebM 用（libvorbis）
- **FLAC** - ロスレス音声（高品質中間ファイル用）

### 📊 詳細ログ出力

- エンコード進捗（現在時刻、速度、fps, ビットレート）
- GPU/HW 処理情報（NVENC/QSV/AMF の実行状況）
- FFmpeg 標準エラー・警告の色付け記録
- 環境情報（OS, PowerShell, FFmpeg バージョン）

### ⚙️ その他機能

- **複数ファイル一括処理** - 複数動画を連続エンコード可能
- **フォルダ指定対応** - ディレクトリ内の動画を自動検出
- **後処理アクション** - エンコード完了後の自動整理・移動・削除
- **メタデータ保持・抽出** - exiftool 統合で作成日時等の保持
- **詳細なエラーハンドリング** - エンコード失敗時の自動フォールバック・リトライ

---

## 📦 必要なもの（依存関係）

### 必須

| ツール | 用途 | インストール |
|--------|------|-----------|
| **FFmpeg** | 動画エンコーディング | [ffmpeg.org](https://ffmpeg.org/download.html) または PATH 環境変数に登録 |
| **FFprobe** | 動画情報取得 | FFmpeg に付属 |
| **PowerShell 5.1 以上** | スクリプト実行 | Windows 10/11 に含まれる |

### オプション（外部音声エンコーダー）

利用可能なもののみ自動検出され、メニューに表示されます：

| ツール | 用途 | URL | 備考 |
|--------|------|-----|------|
| **qaac** | AAC エンコーディング（高速） | [GitHub](https://github.com/nu774/qaac) | M1 Mac で転送されたコアを活用 |
| **Nero AAC Encoder** | 高品質 AAC | [Nero](https://www.nero.com/jpn/tools-nerodigitalaudiolabs.html) | 古いが高評価、品質 -q で細かく制御 |
| **fdkaac** | Fraunhofer FDK ベース AAC | [GitHub](https://github.com/mstorsjo/fdk-aac) | VBR/HE-AAC 対応 |

### オプション（補助ツール）

| ツール | 用途 | インストール | 必須度 |
|--------|------|-----------|-------|
| **exiftool** | メタデータ処理 | [exiftool.org](https://exiftool.org/) | 低（メタデータ保持機能を使う場合のみ） |
| **LosslessCut** | ビジュアル編集補助 | [MaCleaner 12 / GitHub](https://github.com/mifi/lossless-cut) | 低（設定例のみ） |

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
    LosslessCutPath  = "C:\path\to\LosslessCutPortable.exe"

    # --- その他 ---
    NotifyScriptPath = ""                 # エラー通知用スクリプトのパス
}
```

### 3. 実行権限の確認（必要に応じて）

```powershell
# PowerShell を 管理者 で起動後：
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 4. 起動テスト

```powershell
# コマンドラインで実行（引数なしでヘルプ表示）
.\start.bat -h
```

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

### インタラクティブメニュー詳細

#### 【メイン】モード選択
```
1. 通常モード        → 対話式で詳細設定を選択
2. テンプレートモード  → 保存済みテンプレートから選択
3. プラットフォームモード → Twitter/Discord/GitHub 向け自動最適化
4. 中間ファイルモード   → yuv444p/yuv422p 高品質編集用中間ファイル作成
5. 分割モード        → チャプター/字幕で分割してエンコード
```

#### 【通常モード】ハードウェア選択

```
実際のテスト結果に基づき、対応ハードウェアのみが表示されます：

✓ NVIDIA (NVENC) - 検出済み
✓ Intel (QSV)    - 検出済み
✓ AMD (AMF)      - 検出済み
✓ CPU (Software) - 常に利用可能
```

#### 【通常モード】コーデック選択（例：NVIDIA）

```
H.265/HEVC     - 最新標準、高圧縮
H.264/AVC      - 互換性最高
AV1 NVENC      - 次世代、極高圧縮（NVIDIA 限定）
VP9            - WebM 用
```

#### 【通常モード】品質設定例

**NVIDIA エンコーダーの場合：**
```
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
```
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

```
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

### 1. ハードウェア自動検出

スクリプト開始時に各 HW エンコーダーでテストエンコードを実行し、実対応状況を検出：

```powershell
# ログ出力例
テスト結果: NVIDIA=True Intel=True AMD=False
  エンコーダー: [h264_nvenc, hevc_nvenc, av1_nvenc, h264_qsv, hevc_qsv]
  HWアクセル  : [cuda, qsv, d3d11va]
```

未対応のハードウェア・コーデックは自動除外。

### 2. インターレース自動検出・解除

古い映像形式（MPEG2、PAル映像、ビデオカメラ）の逆テレシネ・デインターレース：

```
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

容量上限に収めながら最高品質を自動計算：

**例：Discord (10MB 上限)**
```
入力：60秒 動画
計算プロセス：
  1. 総ビットレート上限 = (10MB × 0.90) × 8 × 1024 / 60秒
  2. 音声: Opus 64kbps → 音声ビットレート = 64kbps
  3. 映像ビットレート = 総上限 - 音声
  4. CRF値自動計算：内部的に maxrate で制御
  
結果：H.265 CRF:22 + maxrate:1024k で 9.8MB に収束
```

**計算メトリクス：**
```
マージンファクタ：
  ├─ H.264/H.265 = 0.90
  ├─ VP9 = 0.88
  ├─ SVT-AV1 = 0.82
  └─ libaom-av1 = 0.80
```

### 4. 外部音声エンコーダー統合

外部エンコーダーが利用可能な場合、自動的にメニューに追加：

**qaac の例：**
```
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

### 5. ログ記録

```
ログ格納場所：<出力フォルダ>/re-encode-log-YYYYMMdd-HHmmss.log

含まれる情報：
  ├─ 実行環境（Windows版, PS版, FFmpeg版）
  ├─ エンコード進捗（タイムコード, 速度, fps, ビットレート）
  ├─ GPU/HW処理情報（NVENC/QSV/AMF のアクティブ状況）
  ├─ FFmpeg 警告・エラー（カラー分類）
  └─ 所要時間・エンコード完了情報
```

### 6. エラーハンドリング

**HW アクセルエラー自動リトライ：**
```
HW アクセルでエラー発生
  → CPU へ自動フォールバック（-hwaccel削除）
  → 再エンコード実行
```

**音声エンコーダー失敗時：**
```
外部エンコーダー実行失敗
  → ソース音声互換性チェック
  → コピーまたは除去へ自動切り替え
```

---

## ⚙️ 設定ファイル

### config.user.psd1

```powershell
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
```

### テンプレートファイル（template/*.psd1）

```powershell
# テンプレート例：templates/Twitter.psd1

@{
    HWEncoder       = "NVIDIA"         # NVIDIA / Intel / AMD / CPU
    CodecName       = "H.264"
    PresetValue     = "p4"             # NVIDIA: p1-p7, Intel: medium など
    QualityValue    = 23               # CRF値
    Extension       = "mp4"
    AudioOptions    = "--tvbr 64"      # 音声オプション（qaac, libopus など）
}
```

---

## 📂 ファイル構成

```
動画再エンコード/
├── start.bat                     # 起動用バッチファイル
├── re-encode-AIOptimus.ps1      # メイン処理スクリプト
├── get-ffmpegOptions.ps1        # エンコード設定メニュー
├── config.user.psd1             # 環境設定ファイル（要編集）
├── README.md                     # このファイル
├── IMPLEMENTATION_HISTORY.md     # 実装变遷記録
└── templates/                    # テンプレート保存先（自動生成）
    ├── Twitter.psd1
    ├── Discord.psd1
    └── ...
```

---

## ❓ よくある質問

### Q1. PowerShell スクリプトが実行できない

**A:** 以下で実行権限を許可してください：

```powershell
# PowerShell を【管理者実行】で開く
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

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

### Q3. NVIDIA/Intel/AMD エンコーダーが認識されない

**A:** スクリプト実行時に自動テストが行われます。対応 GPU がない場合は CPU でのエンコードになります。

### Q4. 外部音声エンコーダー（qaac など）が検出されない

**A:** config.user.psd1 のパスを確認：

```powershell
# PATH に登録済みの場合
QaacPath = "qaac64"

# ローカルインストール
QaacPath = "C:\path\to\qaac64.exe"
```

### Q5. エンコード中止したい

**A:** Ctrl+C で中断可能。ただし既出力ファイルは残ります。

### Q6. テンプレートを作成したい

**A:** メニューで設定後、テンプレート保存オプションで保存。templates/ フォルダに自動生成されます。

### Q7. 2-Pass エンコードを使いたい

**A:** CPU エンコーダー（H.264/H.265）でのみ対応。メニュー内で「2-pass Bitrate」を選択。

---

## 📚 実装履歴

詳細な変更履歴は [IMPLEMENTATION_HISTORY.md](IMPLEMENTATION_HISTORY.md) を参照してください。

このスクリプトは初期版の GistHub コード を AI で最適化し、以来継続的に改善されています。

---

## 📄 ライセンス

このプロジェクトはオープンソースです。自由に使用・改造・配布してください。  
ただし FFmpeg や各外部ツールのライセンスに従うこと。

---

## 🤝 貢献

改善提案・バグ報告は Issue / Pull Request でお願いします。

---

**最終更新：** 2026年5月9日
