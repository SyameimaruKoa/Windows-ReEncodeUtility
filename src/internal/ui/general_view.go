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

	// Basic Settings fields (1-8)
	fields := []struct {
		label string
		value string
		idx   int
	}{
		{"HWデコード   ", formatHwDecoder(s.HwDecoder), 1},
		{"HWエンコーダ ", formatHwEncoder(s.HwEncoder), 2},
		{"映像コーデック", formatCodec(s.VideoCodec), 3},
		{"品質 (CRF)   ", formatQuality(s.QualityIndex, s.CustomCRF, s.CustomBitrate), 4},
		{"速度プリセット", s.SpeedPreset, 5},
		{"音声設定     ", formatAudioEncoder(s.AudioEncoder, s.AudioPreset), 6},
		{"インターレース", formatDeinterlace(s.Deinterlace), 7},
		{"コンテナ形式 ", strings.ToUpper(s.OutputExt), 8},
	}

	for _, f := range fields {
		formatted := FormatDropdownField(f.label, f.value, fieldWidth, true)
		if f.idx == activeField && focused {
			items = append(items, ScrollableItem{f.idx, ActiveItemStyle.Render(PadRightDisplay(formatted, innerWidth))})
		} else {
			items = append(items, ScrollableItem{f.idx, NormalItemStyle.Render(formatted)})
		}
	}

	// Advanced settings toggle (Field 9)
	advToggle := "[▼ 詳細設定・リソース制御 を閉じる (Alt+D)]"
	if !s.ShowAdvanced {
		advToggle = "[▶ 詳細設定・リソース制御 を開く (Alt+D)]"
	}
	if activeField == 9 && focused {
		items = append(items, ScrollableItem{9, ActiveItemStyle.Render(PadRightDisplay(advToggle, innerWidth))})
	} else {
		items = append(items, ScrollableItem{9, SelectedItemStyle.Render(advToggle)})
	}

	if s.ShowAdvanced {
		isAV1 := strings.Contains(strings.ToLower(s.VideoCodec), "av1")

		advFields := []struct {
			label       string
			value       string
			idx         int
			hasDropdown bool
		}{
			{"・CPU制限    ", formatCPULimit(s.CPULimit), 10, true},
		}

		if isAV1 {
			advFields = append(advFields, struct {
				label       string
				value       string
				idx         int
				hasDropdown bool
			}{"・AV1エンジン ", s.AV1Engine, 11, true})
		}

		advFields = append(advFields, []struct {
			label       string
			value       string
			idx         int
			hasDropdown bool
		}{
			{"・同名ファイル", string(s.Overwrite), 12, true},
			{"・2-Pass モード", formatTwoPass(s.TwoPass), 13, false},
			{"・メタデータ  ", string(s.Metadata), 14, true},
			{"・カット区間  ", fmt.Sprintf("開始 [%s] 終了 [%s] [LosslessCut]", s.CutStart, s.CutEnd), 15, false},
			{"・追加 VF    ", s.AdditionalVF, 16, false},
			{"・追加 引数   ", s.AdditionalArgs, 17, false},
			{"・完了後電源  ", formatPower(s.AfterPower), 18, true},
		}...)

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
	if contentHeight < 10 {
		contentHeight = 10
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

func formatQuality(idx int, customCRF int, customBitrate string) string {
	switch idx {
	case 0:
		return "最高画質 (CRF 18 / アーカイブ)"
	case 1:
		return "高画質   (CRF 22 / 推奨)"
	case 2:
		return "標準画質 (CRF 26 / 軽量)"
	case 3:
		return "低画質   (CRF 30 / 超軽量)"
	case 4:
		if customCRF > 0 {
			return fmt.Sprintf("カスタム (CRF %d)", customCRF)
		} else if customBitrate != "" {
			return fmt.Sprintf("カスタム (%s)", customBitrate)
		}
		return "カスタム"
	default:
		return "高画質   (CRF 22 / 推奨)"
	}
}

func formatAudioEncoder(enc, preset string) string {
	switch enc {
	case "copy":
		return "音声をそのままコピー (-c:a copy)"
	case "internal_aac":
		return fmt.Sprintf("内蔵 AAC (%s)", preset)
	case "qaac":
		return fmt.Sprintf("qaac: AAC-LC (%s)", preset)
	case "nero":
		return fmt.Sprintf("neroAacEnc: AAC (%s)", preset)
	case "fdkaac":
		return fmt.Sprintf("fdkaac: AAC (%s)", preset)
	case "opus":
		return "Opus (libopus 128k)"
	case "vorbis":
		return "Vorbis (libvorbis q4)"
	case "flac":
		return "FLAC (ロスレス無劣化)"
	case "none":
		return "音声なし (-an)"
	default:
		return enc
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
