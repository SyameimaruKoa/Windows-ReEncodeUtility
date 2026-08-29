package ui

import (
	"fmt"
	"strings"

	"windows-reencode-utility/src/internal/core"

	"github.com/charmbracelet/lipgloss"
)

// RenderSplitView renders the right panel for Split mode.
func RenderSplitView(s *core.SplitSettings, selItem *core.QueueItem, activeField int, outerWidth, outerHeight int, focused bool) string {
	var b strings.Builder

	innerWidth := outerWidth - 4
	if innerWidth < 20 {
		innerWidth = 20
	}
	fieldWidth := innerWidth
	if fieldWidth > 64 {
		fieldWidth = 64
	}

	// Title line
	title := "モード: [ チャプター/字幕分割 (Split) ]"
	if activeField == 0 && focused {
		b.WriteString(ActiveItemStyle.Render(PadRightDisplay(title, innerWidth)))
	} else {
		b.WriteString(HeaderTitleStyle.Render(title))
	}
	b.WriteString("\n\n")

	fields := []struct {
		label string
		value string
		idx   int
	}{
		{"分割ソース       ", formatSplitSource(s.SplitSource), 1},
		{"命名規則         ", formatSplitNaming(s.NamingRule), 2},
		{"出力拡張子       ", strings.ToUpper(s.OutputExt), 3},
	}

	for _, f := range fields {
		formatted := FormatDropdownField(f.label, f.value, fieldWidth, true)
		if f.idx == activeField && focused {
			b.WriteString(ActiveItemStyle.Render(PadRightDisplay(formatted, innerWidth)))
		} else {
			b.WriteString(NormalItemStyle.Render(formatted))
		}
		b.WriteString("\n")
	}

	segCount := 0
	if selItem != nil {
		segCount = len(selItem.Segments)
	}
	b.WriteString("\n")
	b.WriteString(NormalItemStyle.Render(fmt.Sprintf("検出セグメント   : 全 %d セグメントを検出\n", segCount)))

	b.WriteString("\n")
	startBtnText := "▶ [ エンコード開始 (Enter / Ctrl+Enter) ]"
	startBtnStyle := lipgloss.NewStyle().Foreground(ColorSuccess).Bold(true)
	if activeField == 99 && focused {
		b.WriteString(ActiveItemStyle.Render(PadRightDisplay(startBtnText, innerWidth)))
	} else {
		b.WriteString(startBtnStyle.Render(startBtnText))
	}
	b.WriteString("\n")

	panel := PanelStyle
	if focused {
		panel = PanelFocusStyle
	}
	contentWidth := outerWidth - 2
	contentHeight := outerHeight - 2
	if contentWidth < 10 {
		contentWidth = 10
	}
	if contentHeight < 10 {
		contentHeight = 10
	}
	return panel.Width(contentWidth).Height(contentHeight).Render(b.String())
}

func formatSplitSource(s string) string {
	if s == "srt" {
		return "外部SRT字幕を使用"
	}
	return "内部チャプターを使用"
}

func formatSplitNaming(n string) string {
	if n == "index" {
		return "連番のみを使用 (01, 02...)"
	}
	return "テキストを使用 (チャプター名)"
}
