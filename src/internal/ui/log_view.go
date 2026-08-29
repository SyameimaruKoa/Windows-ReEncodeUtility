package ui

import (
    "fmt"
    "strings"
    "time"

    "github.com/charmbracelet/lipgloss"
)

type LogEntry struct {
    Timestamp time.Time
    Level     string
    Message   string
}

// RenderLogView renders the inline collapsible log console with scroll support and raw stderr display.
func RenderLogView(logs []LogEntry, expanded bool, outerWidth int, scrollOffset int) string {
    var b strings.Builder

    innerWidth := outerWidth - 4
    if innerWidth < 20 {
        innerWidth = 20
    }

    toggleText := "[▶ ログコンソールを展開 (F3 / Lキー)]"
    if expanded {
        toggleText = fmt.Sprintf("[▼ ログコンソール (F3/L: 閉じる | Shift+↑/↓・PgUp/PgDn: スクロール | 全 %d 行)]", len(logs))
    }
    b.WriteString(SelectedItemStyle.Render(PadRightDisplay(toggleText, innerWidth)))

    if expanded {
        maxLines := 6
        total := len(logs)
        end := total - scrollOffset
        if end > total {
            end = total
        }
        if end < 0 {
            end = 0
        }
        start := end - maxLines
        if start < 0 {
            start = 0
        }

        var lines []string
        for i := start; i < end; i++ {
            entry := logs[i]
            timeStr := entry.Timestamp.Format("15:04:05")

            levelStyle := NormalItemStyle
            prefix := fmt.Sprintf("[%s] [%-5s] ", timeStr, entry.Level)

            switch entry.Level {
            case "ERROR":
                levelStyle = lipgloss.NewStyle().Foreground(ColorError).Bold(true)
            case "WARN":
                levelStyle = lipgloss.NewStyle().Foreground(ColorWarning)
            case "DEBUG":
                levelStyle = lipgloss.NewStyle().Foreground(ColorMuted)
            case "RAW":
                levelStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#CDD6F4"))
                prefix = fmt.Sprintf("[%s] [RAW] ", timeStr)
            default:
                levelStyle = lipgloss.NewStyle().Foreground(ColorSecondary)
            }

            rawLine := prefix + entry.Message
            truncated := TruncateDisplay(rawLine, innerWidth, "...")
            lines = append(lines, levelStyle.Render(PadRightDisplay(truncated, innerWidth)))
        }

        for len(lines) < maxLines {
            lines = append(lines, PadRightDisplay("", innerWidth))
        }

        for _, l := range lines {
            b.WriteString("\n")
            b.WriteString(l)
        }
    }

    contentWidth := outerWidth - 2
    if contentWidth < 10 {
        contentWidth = 10
    }
    return PanelStyle.Width(contentWidth).Render(b.String())
}
