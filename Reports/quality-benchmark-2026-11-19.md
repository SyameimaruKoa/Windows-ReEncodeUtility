# エンコーダー画質・速度ベンチマーク（2026-11-19）

## 目的と方法

- CPU 基準は `libx264 -preset medium -crf 28`。4素材の2秒代表クリップ（動＋静止）で目標 VMAF を算出。
- 各 HW エンコーダーは品質パラメータを二分探索し、VMAF が CPU 基準に一致する値を素材別に決定。共通値は全素材の最大偏差が最小の値。
- VMAF 目標許容差は ±0.2。範囲外／不正出力は「偏差大・不可」として記録。
- コーデック間比較は生ビットレートではなく、同一 VMAF 到達点の bpp（bits/pixel）と速度で行う。

## 基準点（2秒クリップ）

| 素材 | 目標 VMAF (CRF28) | SSIM | PSNR |
|---|---:|---:|---:|
| BD-anime | 95.45 | 0.9880 | 45.11 |
| BD-movie | 87.21 | 0.9468 | 36.73 |
| DVD-anime | 93.58 | 0.9922 | 46.81 |
| DVD-movie | 89.24 | 0.9551 | 34.24 |

## デバイス別 可否

| デバイス | OS | GPU / 系統 | 利用可 | 不可・制約 |
|---|---|---|---|---|
| 1355U (現 PC) | Windows | Iris Xe / QSV v8 | h264/hevc/vp9/mpeg2 QSV、全 SW | AV1 QSV 不可、mjpeg は品質非効、MF/Vulkan/D3D12VA 除外 |
| PS4 Pro | Linux 7.3.3 | VCE / VAAPI | h264_vaapi（VRAM 2GB 化後） | AMF ランタイム無し、HEVC VAAPI 不可、Vulkan 拡張無し |
| Switch v1 | Linux L4T | Tegra X1 nvv4l2 | h264_nvv4l2（BD のみ） | HEVC 候補不正、DVD 系は出力不正で VMAF 破綻 |
| pi335 (N3350) | Linux | Apollo Lake QSV | h264/hevc QSV | mpeg2 QSV 候補不正 |
| op3040 (6500T) | Linux | Skylake QSV | h264/hevc/mpeg2 QSV | jellyfin コンテナ内 ffmpeg 経由 |
| q508 (Z8700) | Linux | Cherry Trail VAAPI | h264_vaapi（ドライバ変更＋profile main） | QSV 初期化不可、mjpeg/mpeg2/vp8 は比較対象外 |
| tbook (7530U) | Linux | VCN 3 / VAAPI | h264/hevc VAAPI | AMF 未検出、VRAM 64MB でも2秒は動作 |
| 8750H + RTX2070 | Linux (停止前) | Coffee Lake QSV / Turing NVENC | h264/hevc/mpeg2 QSV、h264/hevc NVENC | AV1 NVENC 不可、QSV は oneVPL GPU ランタイム導入後に解決 |
| 6300U | Linux | Skylake QSV | h264/hevc/mpeg2 QSV | 上記ホストの別ハードウェアとして計測 |
| HD 5450 | 未接続 | Cedar | なし | HW エンコーダー無し |

## チューニング結果（推奨品質値と最大偏差）

| エンコーダー | 素材別 最適値 (偏差) | 共通値 | 最大偏差 |
|---|---|---|---:|
| h264_qsv (1355U, normal) | 29(+0.03) / 29(-0.37) / 29(-0.29) / 29(-0.62) | 29 | 0.62 |
| h264_qsv (1355U, chip) | 29(+0.05) / 35(+1.51) / 29(+0.60) / 33(+0.03) | 33 | 0.03 |
| hevc_qsv (1355U, normal) | 29(-0.23) / 29(+0.87) / 29(-0.08) / 29(-0.10) | 29 | 0.87 |
| hevc_qsv (1355U, chip) | 28(+0.43) / 34(-0.50) / 31(-0.23) / 33(-0.33) | 31 | 0.23 |
| mpeg2_qsv (1355U, normal/chip) | 15 / 27 / 17 / 25 | 21 / 25 | 3.89 / 0.05 |
| vp9_qsv (1355U, 例外ビットレート) | 1.55 / 3.3 / 0.237 / 1.05 Mbps | 3.3 Mbps | 0.15 |
| h264_qsv (8750H) | 29 / 29 / 29 / 29 | 29 | 0.66 |
| hevc_qsv (8750H) | 29 / 29 / 29 / 29 | 29 | 1.56 |
| mpeg2_qsv (8750H) | 15 / 27 / 17 / 25 | 21 | 3.89 |
| h264_nvenc (RTX2070) | 33 / 35 / 35 / 31 | 33 | 2.55 |
| hevc_nvenc (RTX2070) | 33 / 35 / 33 / 33 | 33 | 3.34 |
| h264_qsv (6300U) | 27 / 29 / 25 / 29 | 29 | 1.50 |
| hevc_qsv (6300U) | 27 / 29 / 25 / 29 | 29 | 1.69 |
| mpeg2_qsv (6300U) | 15 / 25 / 15 / 25 | 21 | 3.02 |
| h264_qsv (pi335) | 29 / 29 / 29 / 29 | 29 | 0.62 |
| hevc_qsv (pi335) | 29 / 29 / 29 / 29 | 29 | 0.87 |
| h264_vaapi (PS4) | 25 / 31 / 29 / 31 | 29 | 4.69 |
| h264_vaapi (q508) | 27 / 33 / 25 / 33 | 29 | 4.90 |
| h264_vaapi (tbook) | 27 / 33 / 23 / 33 | 29 | 6.08 |
| hevc_vaapi (tbook) | 27 / 33 / 23 / 33 | 29 | 5.62 |
| h264_nvv4l2 (NS, BD のみ) | 5.0 / 8.0 Mbps（DVD 不可） | 3.0 Mbps | 93.04（DVD を含む） |
| libx264 (medium) | 30 / 29 / 30 / 29 | 29 | 0.65 |
| libx265 (medium) | 30 / 30 / 29 / 30 | 31 | 0.52 |
| libsvtav1 | 48 / 48 / 57 / 52 | 57 | 0.03 |
| libaom-av1 | 48 / 45 / 53 / 46 | 53 | 0.01 |
| librav1e | 126 / 140 / 121 / 127 | 140 | 0.05 |
| libvpx-vp9 | 33 / 46 / 43 / 45 | 33 | 0.19 |
| libvpx (VP8, 例外ビットレート) | 2.8 / 5.55 / 0.113 / 1.675 Mbps | 1.675 Mbps | 0.04 |
| mjpeg_qsv | 品質指定が VMAF にほぼ影響せず | 25 | 27.47 |

素材別の値は BD-anime / BD-movie / DVD-anime / DVD-movie の順。単位は特記なければ品質パラメータ値。

## 本番速度（1355U / 10秒クリップ、共通値使用）

| エンコーダー | モード | BD-anime fps | BD-movie fps | DVD-anime fps | DVD-movie fps |
|---|---|---:|---:|---:|---:|
| h264_qsv | normal | 27.38 | 31.88 | 111.47 | 109.31 |
| h264_qsv | chip | 27.34 | 30.54 | 102.96 | 92.53 |
| hevc_qsv | normal | 35.87 | 32.40 | 79.34 | 74.61 |
| hevc_qsv | chip | 31.25 | 31.48 | 87.18 | 92.29 |
| libx264 | medium | 17.33 | 10.26 | 122.85 | 91.64 |
| libx265 | medium | 10.75 | 10.97 | 55.92 | 38.34 |
| libsvtav1 | - | 24.75 | 15.14 | 95.22 | 48.81 |
| libaom-av1 | - | 3.00 | 4.67 | 18.57 | 18.89 |
| librav1e | - | 2.12 | 1.41 | 8.34 | 6.48 |
| libvpx-vp9 | - | 7.48 | 4.63 | 28.24 | 21.83 |

## 総合表（推奨）

| 用途 | 推奨エンコーダー | 設定 | 理由 |
|---|---|---|---|
| 最速 HW (1355U) | h264_qsv normal | global_quality 29 | 偏差 0.62 以内、BD 27fps / DVD 110fps |
| 専用回路優先 (1355U) | h264_qsv chip | global_quality 33 | 偏差最小 0.03、mpeg2 も chip が安定 |
| 最高 HW 画質 (1355U) | hevc_qsv normal | global_quality 29 | 偏差 0.87、速度 32〜79fps |
| AV1 (CPU) | libaom-av1 | crf 53 | 偏差 0.01、速度は遅い |
| AV1 高速 (CPU) | libsvtav1 | crf 57 | 偏差 0.03、libaom より速い |
| VP9 (CPU) | libvpx-vp9 | crf 33 | 偏差 0.19 |
| 互換性重視 | libx264 | crf 29 / medium | 偏差 0.65、速度十分 |
| 低ビットレート HW | vp9_qsv | 3.3 Mbps | 品質モードが目標に届かない例外 |
| 非推奨 | mjpeg_qsv | - | 品質指定が効かず VMAF 偏差 27 |

## データ置き場所

- 生データ: `.cache/quality-benchmark/analysis/`
- 候補ファイル: `.cache/quality-benchmark/encoded/variants/`
- ログ: `.cache/logs/`
- ランナー: `Tools/QualityBenchmark.py`
