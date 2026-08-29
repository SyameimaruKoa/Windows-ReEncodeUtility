package ui

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-runewidth"
)

// Styles definitions using Lip Gloss
var (
	ColorPrimary   = lipgloss.Color("#7D56F4")
	ColorSecondary = lipgloss.Color("#00D7FF")
	ColorSuccess   = lipgloss.Color("#00FF87")
	ColorWarning   = lipgloss.Color("#FFD700")
	ColorError     = lipgloss.Color("#FF5F5F")
	ColorMuted     = lipgloss.Color("#6C7086")
	ColorText      = lipgloss.Color("#CDD6F4")
	ColorHighlight = lipgloss.Color("#F38BA8")
	ColorBgFocus   = lipgloss.Color("#313244")

	// Panel border styles
	PanelStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("#45475A"))

	PanelFocusStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(ColorPrimary)

	HeaderTitleStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(ColorSecondary)

	HeaderKeyStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#A6ADC8"))

	HeaderKeyHighlight = lipgloss.NewStyle().
				Bold(true).
				Foreground(ColorPrimary)

	// Option item styles
	ActiveItemStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#11111B")).
			Background(ColorPrimary)

	SelectedItemStyle = lipgloss.NewStyle().
				Foreground(ColorSecondary).
				Bold(true)

	NormalItemStyle = lipgloss.NewStyle().
			Foreground(ColorText)

	MutedItemStyle = lipgloss.NewStyle().
			Foreground(ColorMuted)

	WarningTextStyle = lipgloss.NewStyle().
				Foreground(ColorWarning).
				Bold(true)

	ErrorTextStyle = lipgloss.NewStyle().
			Foreground(ColorError).
			Bold(true)

	// Progress Bar styles
	ProgressFilledStyle = lipgloss.NewStyle().
				Foreground(ColorSuccess)

	ProgressEmptyStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#45475A"))

	// Modal dialog style
	ModalBoxStyle = lipgloss.NewStyle().
			Border(lipgloss.DoubleBorder()).
			BorderForeground(ColorSecondary).
			Background(lipgloss.Color("#181825")).
			Padding(1, 2)
)

var ansiRegex = regexp.MustCompile(`\x1b\[[0-9;]*[a-zA-Z]|\x1b\][^\x1b]*\x1b\\`)

// StripANSI removes all ANSI escape sequences from a string.
func StripANSI(str string) string {
	return ansiRegex.ReplaceAllString(str, "")
}

// RuneVisualWidth returns the exact terminal cell width of a rune.
func RuneVisualWidth(r rune) int {
	if r >= 0x2500 && r <= 0x259F {
		return 1
	}
	if r == '※' {
		return 1
	}
	if r == '▼' || r == '▶' {
		return 2
	}
	return runewidth.RuneWidth(r)
}

// StringVisualWidth returns exact East Asian terminal visual width ignoring ANSI sequences.
func StringVisualWidth(s string) int {
	clean := StripANSI(s)
	w := 0
	for _, r := range clean {
		w += RuneVisualWidth(r)
	}
	return w
}

// PadRightDisplay pads a string with spaces to reach target visual width.
func PadRightDisplay(s string, targetWidth int) string {
	w := StringVisualWidth(s)
	if w >= targetWidth {
		return s
	}
	return s + strings.Repeat(" ", targetWidth-w)
}

// TruncateDisplay truncates a string to fit within max visual width.
func TruncateDisplay(s string, maxWidth int, tail string) string {
	clean := StripANSI(s)
	if StringVisualWidth(clean) <= maxWidth {
		return clean
	}

	tailW := StringVisualWidth(tail)
	targetW := maxWidth - tailW
	if targetW <= 0 {
		return tail
	}

	var b strings.Builder
	curW := 0
	for _, r := range clean {
		rw := RuneVisualWidth(r)
		if curW+rw > targetW {
			break
		}
		b.WriteRune(r)
		curW += rw
	}
	b.WriteString(tail)
	return b.String()
}

// FormatDropdownField formats label and value cleanly with visual width.
func FormatDropdownField(label, value string, totalWidth int, hasDropdown bool) string {
	arrow := ""
	if hasDropdown {
		arrow = " ▼"
	}

	labelW := StringVisualWidth(label)
	arrowW := StringVisualWidth(arrow)
	valMaxW := totalWidth - labelW - arrowW - 4
	if valMaxW < 8 {
		valMaxW = 8
	}

	truncVal := TruncateDisplay(value, valMaxW, "...")
	valPadded := PadRightDisplay(truncVal, valMaxW)

	boxContent := fmt.Sprintf("[%s%s]", valPadded, arrow)
	return fmt.Sprintf("%s: %s", label, boxContent)
}

// ClampHeight limits the string to at most maxH lines.
func ClampHeight(s string, maxH int) string {
	if maxH <= 0 {
		return ""
	}
	lines := strings.Split(s, "\n")
	if len(lines) > maxH {
		lines = lines[:maxH]
	}
	return strings.Join(lines, "\n")
}
