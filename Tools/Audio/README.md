# 音声同期・チャンネル抽出ツール

Windows PowerShell 5.1以降、FFmpeg、FFprobeを使用。追加のPythonパッケージは不要。
2つのコマンドは独立しており、既存の再エンコード処理を書き換えない。

## 1. 4chから左右端だけを抽出する

```powershell
.\Tools\Audio\Convert-AudioToStereo.ps1 -Input ".\PSCam4Win-mic.wav"
```

4ch音声は、既定で **ch1 → 左、ch4 → 右** とする。ch2とch3はミックスしない。
チャンネル順は音声ストリームの順番であり、マイクの実際の左右配置は実機で確認すること。

別のチャンネルを選ぶ場合:

```powershell
.\Tools\Audio\Convert-AudioToStereo.ps1 -Input ".\recording.wav" -LeftChannel 2 -RightChannel 3
```

出力は `*_stereo.flac`。元の4ch WAVは変更しない。

## 2. 動画と外部音声を自動同期する

動画には比較用の音声が入っている必要がある。PSCam4Winのモノラル音声などでよい。

```powershell
.\Tools\Audio\Sync-ExternalAudio.ps1 -Video ".\capture.mkv" -Audio ".\PSCam4Win-mic.wav"
```

処理の流れ:

1. 動画内の音声と外部音声を、FFmpegでモノラル音量エンベロープに正規化する。48,028 Hzなどの入力音声は**再生速度を誤って指定し直さず**リサンプリングする。
2. 長さが**短い方**から複数の特徴的な区間を抜き出し、長い方の録音全体を探索する。音声の開始順・長さに依存しない。
3. 波形一致位置から開始オフセットを求める。複数の一致区間が十分離れていれば、録音クロックの差も推定して補正する。誤一致や無音が続く場合は自動同期を中止する。
4. 外部音声を2chへ変換。4ch入力の場合、既定でch1とch4を使用する。
5. **動画の長さ**に合わせる。外部音声が先に始まれば前部を切り、後から始まれば先頭に無音を追加する。外部音声が先に終わるなら末尾に無音を補い、長ければ末尾を切る。
6. 映像をストリームコピーし、新たなステレオFLAC音声と合成してMKVを出力する。

出力は `*_stereo_sync.mkv`。元動画と元WAVを維持する。

自動同期できない（動画に比較用音声がない、共通する音がない、極端に短いなど）場合は手動で指定する。

```powershell
.\Tools\Audio\Sync-ExternalAudio.ps1 -Video ".\capture.mkv" -Audio ".\recording.wav" -ManualOffsetSeconds -0.35
```

- 正の値: 外部音声を遅く配置し、先頭に無音を追加。
- 負の値: 外部音声が動画より前に開始したので、その分を前から切り捨てる。
- `-NoDriftCorrection`: 再生速度は変更せず開始オフセットだけを使用。
- `-KeepReferenceAudio`: 元動画の比較用音声を追加音声トラックとして残す。
- `-LeftChannel` / `-RightChannel`: 使用するチャンネル番号を変更。
- `-FfmpegPath` / `-FfprobePath`: 実行ファイルのパスを指定。
- `-h` / `--help`、または引数なし: 詳しいヘルプ。

## 3. PS CameraのSBS左右交換

テンプレートモードから `PS Camera SBS - 左右交換` を選択する。

- 元のSBSの左右半分を入れ替える。元のフル解像度、縦横比、フレームレートを維持。
- 画質設定は既存PSVRプロファイルと同じ `hevc_qsv -global_quality 25 -preset veryslow`。
- PSVR向けのレンズ補正やクロップは適用しない。
- 入力動画の音声はそのままコピー。別録り音声を合成したい場合は、本ページの同期コマンドを出力動画に適用。

## 補足

ch2とch3を録音しておけば、後からノイズ低減・音源方向推定・ビームフォーミングなどに使える余地がある。完成済みのステレオ動画に必須ではないので、既定では使わない。元の4ch WAVを保存しておくのがよい。

自動同期は**動画内の参照音声と外部録音に共通する音があること**が条件。実機との組み合わせによって一致率が変わるため、重要な撮影では同期結果と動画終盤の口の動きも確認すること。
