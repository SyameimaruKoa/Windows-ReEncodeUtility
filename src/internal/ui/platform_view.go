package ui

import (
	"fmt"

	"windows-reencode-utility/src/internal/core"

	"github.com/charmbracelet/lipgloss"
)

// RenderPlatformView renders the settings panel for Platform Mode.
func RenderPlatformView(s *core.PlatformSettings, selItem *core.QueueItem, activeField int, outerWidth, outerHeight int, focused bool) string {
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
	title := "モード: [ プラットフォーム向け (Platform) ]"
	if activeField == 0 && focused {
		items = append(items, ScrollableItem{0, ActiveItemStyle.Render(PadRightDisplay(title, innerWidth))})
	} else {
		items = append(items, ScrollableItem{0, HeaderTitleStyle.Render(title)})
	}

	preset := core.FindPlatformPreset(s.SelectedPlatform)

	// Platform choice (Field 1)
	platName := s.SelectedPlatform
	if preset != nil {
		platName = preset.Name
	}
	platFormatted := FormatDropdownField("投稿先プラットフォーム", platName, fieldWidth, true)
	if activeField == 1 && focused {
		items = append(items, ScrollableItem{1, ActiveItemStyle.Render(PadRightDisplay(platFormatted, innerWidth))})
	} else {
		items = append(items, ScrollableItem{1, NormalItemStyle.Render(platFormatted)})
	}

	// Auto calculate toggle (Field 2)
	autoFormatted := FormatDropdownField("おまかせ自動逆算設定  ", formatBoolToggle(s.AutoSetting), fieldWidth, false)
	if activeField == 2 && focused {
		items = append(items, ScrollableItem{2, ActiveItemStyle.Render(PadRightDisplay(autoFormatted, innerWidth))})
	} else {
		items = append(items, ScrollableItem{2, NormalItemStyle.Render(autoFormatted)})
	}

	divLine := "▼ おまかせ自動設定サマリー (ファイル長から自動計算) ──"
	items = append(items, ScrollableItem{-1, HeaderTitleStyle.Render(divLine)})

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

	items = append(items, ScrollableItem{-1, NormalItemStyle.Render(fmt.Sprintf("・解像度         : %s", resStr))})
	items = append(items, ScrollableItem{-1, NormalItemStyle.Render(fmt.Sprintf("・目標ビットレート: %d kbps (自動逆算)", targetKbps))})
	items = append(items, ScrollableItem{-1, NormalItemStyle.Render(fmt.Sprintf("・音声           : AAC (%d kbps)", audioBitrate))})
	items = append(items, ScrollableItem{-1, NormalItemStyle.Render(fmt.Sprintf("・出力形式       : .%s", s.OutputExt))})
	items = append(items, ScrollableItem{-1, NormalItemStyle.Render(fmt.Sprintf("・目標上限サイズ : %.1f MB (安全マージン 1.5%% 適用)", targetMaxMB))})

	// Start button (Field 99)
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

func formatBoolToggle(v bool) string {
	if v {
		return "有効 (自動ビットレート・解像度制限)"
	}
	return "手動設定"
}
