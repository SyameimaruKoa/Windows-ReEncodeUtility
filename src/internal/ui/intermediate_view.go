package ui

import (
	"strings"

	"windows-reencode-utility/src/internal/core"

	"github.com/charmbracelet/lipgloss"
)

// RenderIntermediateView renders the right panel for Intermediate mode.
func RenderIntermediateView(s *core.IntermediateSettings, activeField int, outerWidth, outerHeight int, focused bool) string {
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
	title := "モード: [ 中間ファイル作成 (Intermediate) ]"
	if activeField == 0 && focused {
		items = append(items, ScrollableItem{0, ActiveItemStyle.Render(PadRightDisplay(title, innerWidth))})
	} else {
		items = append(items, ScrollableItem{0, HeaderTitleStyle.Render(title)})
	}

	fields := []struct {
		label string
		value string
		idx   int
	}{
		{"中間フォーマット", formatInterFormat(s.Format), 1},
		{"音声形式        ", formatInterAudio(s.AudioFormat), 2},
		{"出力コンテナ    ", strings.ToUpper(s.OutputExt), 3},
	}

	for _, f := range fields {
		formatted := FormatDropdownField(f.label, f.value, fieldWidth, true)
		if f.idx == activeField && focused {
			items = append(items, ScrollableItem{f.idx, ActiveItemStyle.Render(PadRightDisplay(formatted, innerWidth))})
		} else {
			items = append(items, ScrollableItem{f.idx, NormalItemStyle.Render(formatted)})
		}
	}

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

func formatInterFormat(f string) string {
	switch f {
	case "prores_hq":
		return "ProRes 422 HQ (yuv422p10le)"
	case "dnxhr_hqx":
		return "DNxHR HQX (yuv422p10le)"
	case "ffv1":
		return "FFV1 (完全ロスレス / yuv444p)"
	default:
		return "ProRes 422 HQ (yuv422p10le)"
	}
}

func formatInterAudio(a string) string {
	switch a {
	case "pcm24":
		return "PCM 24-bit (非圧縮)"
	case "flac":
		return "FLAC (ロスレス)"
	default:
		return "PCM 24-bit (非圧縮)"
	}
}
