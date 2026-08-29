package ui

import (
	"fmt"
	"strings"

	"windows-reencode-utility/src/internal/core"

	"github.com/charmbracelet/lipgloss"
)

// RenderPlatformView renders the settings panel for Platform Mode.
func RenderPlatformView(s *core.PlatformSettings, selItem *core.QueueItem, activeField int, outerWidth, outerHeight int, focused bool) string {
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
	title := "モード: [ プラットフォーム向け (Platform) ]"
	if activeField == 0 && focused {
		b.WriteString(ActiveItemStyle.Render(PadRightDisplay(title, innerWidth)))
	} else {
		b.WriteString(HeaderTitleStyle.Render(title))
	}
	b.WriteString("\n\n")

	preset := core.FindPlatformPreset(s.SelectedPlatform)

	// Platform choice (Field 1)
	platName := s.SelectedPlatform
	if preset != nil {
		platName = preset.Name
	}
	platFormatted := FormatDropdownField("投稿先プラットフォーム", platName, fieldWidth, true)
	if activeField == 1 && focused {
		b.WriteString(ActiveItemStyle.Render(PadRightDisplay(platFormatted, innerWidth)))
	} else {
		b.WriteString(NormalItemStyle.Render(platFormatted))
	}
	b.WriteString("\n")

	// Auto calculate toggle (Field 2)
	autoFormatted := FormatDropdownField("おまかせ自動逆算設定  ", formatBoolToggle(s.AutoSetting), fieldWidth, false)
	if activeField == 2 && focused {
		b.WriteString(ActiveItemStyle.Render(PadRightDisplay(autoFormatted, innerWidth)))
	} else {
		b.WriteString(NormalItemStyle.Render(autoFormatted))
	}
	b.WriteString("\n\n")

	divLine := "▼ おまかせ自動設定サマリー (ファイル長から自動計算) ──"
	b.WriteString(HeaderTitleStyle.Render(divLine))
	b.WriteString("\n")

	durSec := float64(60)
	if selItem != nil && selItem.Info.DurationSec > 0 {
		durSec = selItem.Info.DurationSec
	}
	targetMaxMB := float64(512)
	audioBitrate := 128
	if preset != nil {
		targetMaxMB = preset.MaxFileSizeMB
		audioBitrate = preset.AudioBitrateKbps
	}
	if s.SelectedPlatform == "custom" && s.CustomMaxMB > 0 {
		targetMaxMB = s.CustomMaxMB
	}
	targetKbps := core.CalculateTargetBitrate(targetMaxMB, durSec, int64(audioBitrate))

	resStr := "元動画と同じ (自動調整)"
	if preset != nil && preset.TargetMaxWidth > 0 && preset.TargetMaxHeight > 0 {
		resStr = fmt.Sprintf("最大 %dx%d (自動縮小)", preset.TargetMaxWidth, preset.TargetMaxHeight)
	}

	b.WriteString(NormalItemStyle.Render(fmt.Sprintf("・解像度         : %s\n", resStr)))
	b.WriteString(NormalItemStyle.Render(fmt.Sprintf("・目標ビットレート: %d kbps (自動逆算)\n", targetKbps)))
	b.WriteString(NormalItemStyle.Render(fmt.Sprintf("・音声           : AAC (%d kbps)\n", audioBitrate)))
	b.WriteString(NormalItemStyle.Render(fmt.Sprintf("・出力形式       : .%s\n", s.OutputExt)))
	b.WriteString(NormalItemStyle.Render(fmt.Sprintf("・目標上限サイズ : %.1f MB (安全マージン 1.5%% 適用)\n", targetMaxMB)))

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

func formatBoolToggle(v bool) string {
	if v {
		return "有効 (自動ビットレート・解像度制限)"
	}
	return "手動設定"
}
