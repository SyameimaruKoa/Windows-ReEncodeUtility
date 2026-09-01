package ui

import (
	"fmt"
	"strings"

	"windows-reencode-utility/src/internal/core"

	"github.com/charmbracelet/lipgloss"
)

// RenderGeneralView renders the settings panel for General Mode.
func RenderGeneralView(s *core.GeneralSettings, activeField int, outerWidth, outerHeight int, focused bool) string {
	innerWidth := outerWidth - 4
	if innerWidth < 20 {
		innerWidth = 20
	}
	fieldWidth := innerWidth
	if fieldWidth > 64 {
		fieldWidth = 64
	}

	var items []ScrollableItem

	// Title line (Field 0)
	title := "モード: [ 通常エンコード (General) ]"
	if activeField == 0 && focused {
		items = append(items, ScrollableItem{0, ActiveItemStyle.Render(PadRightDisplay(title, innerWidth))})
	} else {
		items = append(items, ScrollableItem{0, HeaderTitleStyle.Render(title)})
	}

	// Basic Settings fields (1-5)
	fields := []struct {
		label string
		value string
		idx   int
	}{
		{"映像設定     ", formatCombinedVideoSetting(s), 1},
		{"音声設定     ", formatCombinedAudioSetting(s), 2},
		{"HWデコード   ", formatHwDecoder(s.HwDecoder), 3},
		{"インターレース", formatDeinterlace(s.Deinterlace), 4},
		{"コンテナ形式 ", strings.ToUpper(s.OutputExt), 5},
	}

	for _, f := range fields {
		formatted := FormatDropdownField(f.label, f.value, fieldWidth, true)
		if f.idx == activeField && focused {
			items = append(items, ScrollableItem{f.idx, ActiveItemStyle.Render(PadRightDisplay(formatted, innerWidth))})
		} else {
			items = append(items, ScrollableItem{f.idx, NormalItemStyle.Render(formatted)})
		}
	}

	// Advanced settings toggle (Field 6)
	advToggle := "[▼ 詳細設定・リソース制御 を閉じる (Alt+D)]"
	if !s.ShowAdvanced {
		advToggle = "[▶ 詳細設定・リソース制御 を開く (Alt+D)]"
	}
	if activeField == 6 && focused {
		items = append(items, ScrollableItem{6, ActiveItemStyle.Render(PadRightDisplay(advToggle, innerWidth))})
	} else {
		items = append(items, ScrollableItem{6, SelectedItemStyle.Render(advToggle)})
	}

	if s.ShowAdvanced {
		advFields := []struct {
			label       string
			value       string
			idx         int
			hasDropdown bool
		}{
			{"・CPU制限    ", formatCPULimit(s.CPULimit), 7, true},
			{"・同名ファイル", string(s.Overwrite), 8, true},
			{"・2-Pass モード", formatTwoPass(s.TwoPass), 9, false},
			{"・メタデータ  ", string(s.Metadata), 10, true},
			{"・カット区間  ", fmt.Sprintf("開始 [%s] 終了 [%s] [LosslessCut]", s.CutStart, s.CutEnd), 11, false},
			{"・追加 VF    ", s.AdditionalVF, 12, false},
			{"・追加 引数   ", s.AdditionalArgs, 13, false},
			{"・完了後電源  ", formatPower(s.AfterPower), 14, true},
		}

		for _, af := range advFields {
			formatted := FormatDropdownField(af.label, af.value, fieldWidth, af.hasDropdown)
			if af.idx == activeField && focused {
				items = append(items, ScrollableItem{af.idx, ActiveItemStyle.Render(PadRightDisplay(formatted, innerWidth))})
			} else {
				items = append(items, ScrollableItem{af.idx, NormalItemStyle.Render(formatted)})
			}
		}
	}

	// Prominent Start Button (Field 99)
	startBtnText := "▶ [ エンコード開始 (Enter / Ctrl+Enter) ]"
	startBtnStyle := lipgloss.NewStyle().Foreground(ColorSuccess).Bold(true)
	if activeField == 99 && focused {
		items = append(items, ScrollableItem{99, ActiveItemStyle.Render(PadRightDisplay(startBtnText, innerWidth))})
	} else {
		items = append(items, ScrollableItem{99, startBtnStyle.Render(startBtnText)})
	}

	contentWidth := outerWidth - 2
	contentHeight := outerHeight - 2
	if contentWidth < 10 {
		contentWidth = 10
	}
	if contentHeight < 4 {
		contentHeight = 4
	}

	renderedContent := RenderScrollableLines(items, activeField, contentHeight)

	panel := PanelStyle
	if focused {
		panel = PanelFocusStyle
	}
	return panel.Width(contentWidth).Height(contentHeight).Render(renderedContent)
}

func formatHwDecoder(d string) string {
	switch d {
	case "none":
		return "使用しない (CPUデコード)"
	case "cuda":
		return "NVIDIA (cuda)"
	case "qsv":
		return "Intel (qsv)"
	case "d3d11va":
		return "推奨・Windows標準 (d3d11va)"
	case "dxva2":
		return "Windows汎用 (dxva2)"
	case "vulkan":
		return "Vulkan (vulkan)"
	default:
		return "推奨・Windows標準 (d3d11va)"
	}
}

func formatHwEncoder(e string) string {
	switch e {
	case "CPU":
		return "CPU (Software)"
	case "NVIDIA":
		return "NVIDIA (NVENC)"
	case "Intel":
		return "Intel (QSV)"
	case "AMD":
		return "AMD (AMF)"
	case "Vulkan":
		return "Vulkan"
	case "D3D12VA":
		return "D3D12VA"
	case "MF":
		return "MediaFoundation (MF)"
	default:
		return "CPU (Software)"
	}
}

func formatCodec(c string) string {
	switch c {
	case "libx264", "h264_nvenc", "h264_qsv", "h264_amf", "h264_mf":
		return "H.264 / AVC"
	case "libx265", "hevc_nvenc", "hevc_qsv", "hevc_amf", "hevc_mf":
		return "H.265 / HEVC"
	case "libsvtav1", "av1_nvenc", "av1_qsv", "av1_amf":
		return "AV1"
	case "libvpx-vp9":
		return "VP9"
	default:
		return c
	}
}

func formatQuality(s *core.GeneralSettings) string {
	hw := s.HwEncoder
	codec := strings.ToLower(s.VideoCodec)

	if s.CustomBitrate != "" {
		return fmt.Sprintf("カスタムレート (%s)", s.CustomBitrate)
	}

	if s.CustomQualityValue != "" {
		if hw == "NVIDIA" {
			return fmt.Sprintf("カスタム (CQ %s)", s.CustomQualityValue)
		} else if hw == "Intel" {
			return fmt.Sprintf("カスタム (GQ %s)", s.CustomQualityValue)
		} else if hw == "AMD" {
			return fmt.Sprintf("カスタム (QP %s)", s.CustomQualityValue)
		} else if strings.Contains(codec, "rav1e") {
			return fmt.Sprintf("カスタム (QP %s)", s.CustomQualityValue)
		}
		return fmt.Sprintf("カスタム (CRF %s)", s.CustomQualityValue)
	}

	if s.CustomCRF > 0 {
		return fmt.Sprintf("カスタム (CRF %d)", s.CustomCRF)
	}

	switch hw {
	case "NVIDIA":
		switch s.QualityIndex {
		case 0:
			return "高品質 (CQ:23)"
		case 1:
			return "中品質 (CQ:28)"
		case 2:
			return "高速   (CQ:32)"
		default:
			return "中品質 (CQ:28)"
		}
	case "Intel":
		if strings.Contains(codec, "vp9") {
			switch s.QualityIndex {
			case 0:
				return "高品質 (Q:25)"
			case 1:
				return "中品質 (Q:30)"
			case 2:
				return "低品質 (Q:40)"
			default:
				return "中品質 (Q:30)"
			}
		}
		switch s.QualityIndex {
		case 0:
			return "高品質 (GQ:20)"
		case 1:
			return "中品質 (GQ:25)"
		case 2:
			return "低品質 (GQ:30)"
		default:
			return "中品質 (GQ:25)"
		}
	case "AMD":
		switch s.QualityIndex {
		case 0:
			return "高品質 (QP:22)"
		case 1:
			return "中品質 (QP:28)"
		case 2:
			return "低品質 (QP:35)"
		default:
			return "中品質 (QP:28)"
		}
	case "Vulkan", "D3D12VA", "MF":
		switch s.QualityIndex {
		case 0:
			return "高品質 (8000k)"
		case 1:
			return "標準品質 (4000k)"
		default:
			return "標準品質 (4000k)"
		}
	default: // CPU
		if strings.Contains(codec, "svt") || strings.Contains(codec, "aom") {
			switch s.QualityIndex {
			case 0:
				return "高品質 (CRF:20)"
			case 1:
				return "中品質 (CRF:30)"
			default:
				return "高品質 (CRF:20)"
			}
		} else if strings.Contains(codec, "rav1e") {
			switch s.QualityIndex {
			case 0:
				return "高品質 (QP:80)"
			case 1:
				return "中品質 (QP:120)"
			case 2:
				return "低品質 (QP:160)"
			default:
				return "中品質 (QP:120)"
			}
		} else if strings.Contains(codec, "vp") {
			switch s.QualityIndex {
			case 0:
				return "高品質 (CRF:30)"
			case 1:
				return "中品質 (CRF:35)"
			default:
				return "高品質 (CRF:30)"
			}
		}
		// x264, x265
		switch s.QualityIndex {
		case 0:
			return "最高画質 (CRF 18 / アーカイブ)"
		case 1:
			return "高画質   (CRF 22 / 推奨)"
		case 2:
			return "標準画質 (CRF 26 / 軽量)"
		case 3:
			return "低画質   (CRF 30 / 超軽量)"
		default:
			return "高画質   (CRF 22 / 推奨)"
		}
	}
}

func formatAudioEncoderName(enc string) string {
	switch enc {
	case "copy":
		return "音声をコピー (-c:a copy)"
	case "none":
		return "音声なし (-an)"
	case "internal_aac":
		return "内蔵 AAC (FFmpeg)"
	case "qaac":
		return "外部 qaac (Apple AAC)"
	case "nero":
		return "外部 neroAacEnc (Nero AAC)"
	case "fdkaac":
		return "外部 fdkaac (Fraunhofer AAC)"
	case "opus":
		return "Opus (libopus)"
	case "vorbis":
		return "Vorbis (libvorbis)"
	case "flac":
		return "FLAC (可逆圧縮ロスレス)"
	default:
		return enc
	}
}

func formatAudioQuality(s *core.GeneralSettings) string {
	enc := s.AudioEncoder
	preset := s.AudioPreset
	custom := s.AudioCustom

	if enc == "copy" || enc == "none" {
		return "設定不要 (パススルー/無音)"
	}

	if preset == "custom" || (custom != "" && preset == "") {
		return fmt.Sprintf("カスタム (%s)", custom)
	}

	switch enc {
	case "internal_aac":
		if preset == "" {
			preset = "192k"
		}
		return fmt.Sprintf("%s (標準・汎用)", preset)

	case "qaac":
		switch preset {
		case "tvbr91", "192k", "":
			return "AAC-LC TVBR 91 (~192k / 高音質)"
		case "tvbr73", "160k":
			return "AAC-LC TVBR 73 (~160k / 推奨)"
		case "tvbr64", "128k":
			return "AAC-LC TVBR 64 (~128k / 標準)"
		case "he80":
			return "HE-AAC CVBR 80k"
		case "he64":
			return "HE-AAC CVBR 64k"
		case "he48":
			return "HE-AAC CVBR 48k"
		default:
			return preset
		}

	case "nero":
		switch preset {
		case "q065", "high":
			return "高品質 (-q 0.65 / LC)"
		case "q050", "standard", "":
			return "標準品質 (-q 0.50 / LC)"
		case "q035", "normal_he":
			return "通常品質 (-q 0.35 / HE自動)"
		case "q020", "low_he":
			return "低品質 (-q 0.20 / HE自動)"
		default:
			return preset
		}

	case "fdkaac":
		switch preset {
		case "m5", "vbr5":
			return "最高品質 (VBR 5 / LC)"
		case "m4", "vbr4", "":
			return "高品質 (VBR 4 / LC)"
		case "m3", "vbr3_he":
			return "標準品質 (VBR 3 / HE自動)"
		case "m2", "vbr2_he":
			return "低品質 (VBR 2 / HE自動)"
		default:
			return preset
		}

	case "opus":
		if preset == "" {
			preset = "128k"
		}
		return fmt.Sprintf("%s (高音質・省容量)", preset)

	case "vorbis":
		if preset == "q6" || preset == "high" {
			return "高品質 (q:a 6)"
		}
		return "標準品質 (q:a 4)"

	case "flac":
		if preset == "comp12" || preset == "high" {
			return "高圧縮 (レベル 12)"
		} else if preset == "comp5" || preset == "fast" {
			return "高速 (レベル 5)"
		}
		return "標準 (レベル 8)"

	default:
		if preset == "" {
			preset = "192k"
		}
		return preset
	}
}

func formatDeinterlace(d core.DeinterlaceMode) string {
	switch d {
	case core.DeinterlaceNone:
		return "行わない (スキップ)"
	case core.DeinterlaceAuto:
		return "自動判定 (Auto-Detect)"
	case core.DeinterlaceBwdif:
		return "bwdif (推奨・標準)"
	case core.DeinterlaceYadif:
		return "yadif (軽量)"
	case core.DeinterlaceNnedi:
		return "nnedi (高品質)"
	case core.DeinterlaceFieldmatchDecimate:
		return "fieldmatch,decimate (24fpsテレシネ逆変換)"
	default:
		return string(d)
	}
}

func formatCPULimit(c core.CPURestriction) string {
	switch c {
	case core.CPURestrictionAll:
		return "全コア使用 (標準)"
	case core.CPURestrictionPCore:
		return "Pコアのみ (性能優先)"
	case core.CPURestrictionECore:
		return "Eコアのみ (省電力・静音)"
	case core.CPURestrictionEcoQoS:
		return "EcoQoS (低優先度効率モード)"
	default:
		return string(c)
	}
}

func formatTwoPass(v bool) string {
	if v {
		return "有効 (2パス精密レート制御)"
	}
	return "無効 (1パス)"
}

func formatPower(p core.PowerAction) string {
	switch p {
	case core.PowerNone:
		return "何もしない (待機)"
	case core.PowerShutdown:
		return "シャットダウン (60秒後)"
	case core.PowerReboot:
		return "再起動"
	case core.PowerSleep:
		return "スリープ / 休止"
	default:
		return string(p)
	}
}

func formatCombinedVideoSetting(s *core.GeneralSettings) string {
	hw := s.HwEncoder
	codec := formatCodec(s.VideoCodec)
	q := formatQuality(s)
	speed := s.SpeedPreset
	if speed == "" {
		speed = "medium"
	}
	return fmt.Sprintf("[%s] %s | %s | %s", hw, codec, q, speed)
}

func formatCombinedAudioSetting(s *core.GeneralSettings) string {
	enc := s.AudioEncoder
	if enc == "copy" {
		return "音声をそのままコピー (-c:a copy)"
	}
	if enc == "none" {
		return "音声なし (-an)"
	}
	encName := formatAudioEncoderName(enc)
	q := formatAudioQuality(s)
	return fmt.Sprintf("[%s] %s", encName, q)
}
