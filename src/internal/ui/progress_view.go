package ui

import (
	"fmt"
	"strings"

	"windows-reencode-utility/src/internal/core"
)

// RenderProgressView renders the bottom progress bar and real-time encode statistics.
// outerWidth is the total width of the panel including border.
func RenderProgressView(p core.ProgressUpdate, isComplete bool, outerWidth int) string {
	var b strings.Builder

	innerWidth := outerWidth - 4
	if innerWidth < 20 {
		innerWidth = 20
	}

	curDurStr := core.FormatDuration(p.CurrentSec)
	totDurStr := core.FormatDuration(p.TotalSec)
	timeStats := fmt.Sprintf("%3.0f%% (%s / %s)", p.Percent, curDurStr, totDurStr)
	if isComplete {
		timeStats = "100% [完了]"
	} else if p.TotalSec == 0 && p.Percent > 0 {
		timeStats = fmt.Sprintf("%3.0f%%", p.Percent)
	}

	// Overhead: "進捗: [" (7) + "] " (2) + timeStats
	fixedLen := 9 + len(timeStats)
	barWidth := innerWidth - fixedLen - 1
	if barWidth > 60 {
		barWidth = 60
	}
	if barWidth < 6 {
		barWidth = 6
	}

	filledCount := int(float64(barWidth) * (p.Percent / 100.0))
	if filledCount > barWidth {
		filledCount = barWidth
	}
	if filledCount < 0 {
		filledCount = 0
	}
	emptyCount := barWidth - filledCount

	filledBar := strings.Repeat("█", filledCount)
	emptyBar := strings.Repeat("░", emptyCount)

	var barLine string
	if isComplete {
		barLine = fmt.Sprintf("進捗: [%s] %s", ProgressFilledStyle.Render(strings.Repeat("█", barWidth)), timeStats)
	} else {
		barLine = fmt.Sprintf("進捗: [%s%s] %s",
			ProgressFilledStyle.Render(filledBar),
			ProgressEmptyStyle.Render(emptyBar),
			timeStats,
		)
	}
	b.WriteString(PadRightDisplay(barLine, innerWidth))
	b.WriteString("\n")

	// Statistics line
	speedStr := p.Speed
	if speedStr == "" {
		speedStr = "-"
	}
	outMB := float64(p.OutBytes) / (1024 * 1024)
	remStr := core.FormatDuration(float64(p.RemainingSec))
	etaStr := "-"
	if p.RemainingSec > 0 {
		etaStr = p.ETA.Format("15:04:05")
	}

	var statsLine string
	if strings.Contains(p.LogLine, "音声") || strings.Contains(p.LogLine, "qaac") || strings.Contains(p.LogLine, "nero") || strings.Contains(p.LogLine, "fdkaac") {
		statsLine = fmt.Sprintf("状態: %s │ 進捗: %.1f%%", p.LogLine, p.Percent)
	} else {
		statsLine = fmt.Sprintf("速度: %-6s │ fps: %-4.0f │ 出力サイズ: %-7.1fMB │ 残り時間: %-8s (完了予定: %s)",
			speedStr,
			p.FPS,
			outMB,
			remStr,
			etaStr,
		)
	}
	b.WriteString(MutedItemStyle.Render(PadRightDisplay(TruncateDisplay(statsLine, innerWidth, "..."), innerWidth)))
	b.WriteString("\n")

	hintLine := "※ Windows タスクバーに進捗率（緑バー / 一時停止時黄バー / エラー時赤バー）をリアルタイム同期表示"
	if isComplete {
		hintLine = "※ 全エンコード完了: タスクバーアイコンおよび通知を確認してください"
	}
	b.WriteString(MutedItemStyle.Render(PadRightDisplay(TruncateDisplay(hintLine, innerWidth, "..."), innerWidth)))

	contentWidth := outerWidth - 2
	if contentWidth < 10 {
		contentWidth = 10
	}
	return PanelStyle.Width(contentWidth).Render(b.String())
}
