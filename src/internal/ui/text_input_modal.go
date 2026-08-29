package ui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// TextInputContext identifies what the text input is for.
type TextInputContext int

const (
	InputContextNone               TextInputContext = iota
	InputContextCustomQualityValue                  // Custom CRF / CQ / GQ / QP
	InputContextCustomBitrate                       // Custom video bitrate (e.g. "8000k")
	InputContextCustomAudioVal                      // Custom audio value (TVBR, CVBR, -q, VBR, bitrate)
	InputContextCutStart                            // LosslessCut start time
	InputContextCutEnd                              // LosslessCut end time
	InputContextAdditionalVF                        // -vf string
	InputContextAdditionalArgs                      // FFmpeg CLI flags
	InputContextTemplateName                        // Template name
	InputContextPlatformMaxMB                       // Custom platform max MB
)

// TextInputState manages state for text input modal.
type TextInputState struct {
	Title       string
	Prompt      string
	Placeholder string
	Value       string
	CursorPos   int
	Context     TextInputContext
	Active      bool
}

// NewTextInputState creates an initialized text input state.
func NewTextInputState(title, prompt, initialVal, placeholder string, ctx TextInputContext) TextInputState {
	runes := []rune(initialVal)
	return TextInputState{
		Title:       title,
		Prompt:      prompt,
		Placeholder: placeholder,
		Value:       initialVal,
		CursorPos:   len(runes),
		Context:     ctx,
		Active:      true,
	}
}

// HandleKey processes a key press for text input.
// Returns (done, accepted).
func (tis *TextInputState) HandleKey(key string) (bool, bool) {
	switch key {
	case "esc":
		tis.Active = false
		return true, false

	case "enter":
		tis.Active = false
		return true, true

	case "left":
		if tis.CursorPos > 0 {
			tis.CursorPos--
		}
		return false, false

	case "right":
		runes := []rune(tis.Value)
		if tis.CursorPos < len(runes) {
			tis.CursorPos++
		}
		return false, false

	case "home", "ctrl+a":
		tis.CursorPos = 0
		return false, false

	case "end", "ctrl+e":
		tis.CursorPos = len([]rune(tis.Value))
		return false, false

	case "backspace":
		runes := []rune(tis.Value)
		if tis.CursorPos > 0 && len(runes) > 0 {
			tis.Value = string(runes[:tis.CursorPos-1]) + string(runes[tis.CursorPos:])
			tis.CursorPos--
		}
		return false, false

	case "delete":
		runes := []rune(tis.Value)
		if tis.CursorPos < len(runes) {
			tis.Value = string(runes[:tis.CursorPos]) + string(runes[tis.CursorPos+1:])
		}
		return false, false

	case "ctrl+u", "ctrl+k":
		tis.Value = ""
		tis.CursorPos = 0
		return false, false

	case "space":
		runes := []rune(tis.Value)
		tis.Value = string(runes[:tis.CursorPos]) + " " + string(runes[tis.CursorPos:])
		tis.CursorPos++
		return false, false

	default:
		// Insert printable character
		if len(key) == 1 || (len([]rune(key)) == 1 && !strings.HasPrefix(key, "ctrl+") && !strings.HasPrefix(key, "alt+")) {
			runes := []rune(tis.Value)
			insertRune := []rune(key)
			if len(insertRune) == 1 {
				tis.Value = string(runes[:tis.CursorPos]) + string(insertRune) + string(runes[tis.CursorPos:])
				tis.CursorPos++
			}
		}
		return false, false
	}
}

// RenderTextInputModal renders the text input dialog box.
func RenderTextInputModal(tis *TextInputState, totalW, totalH int) string {
	boxW := 60
	if boxW > totalW-4 {
		boxW = totalW - 4
	}

	var b strings.Builder
	b.WriteString(HeaderTitleStyle.Render(fmt.Sprintf("=== %s ===", tis.Title)))
	b.WriteString("\n\n")

	if tis.Prompt != "" {
		b.WriteString(NormalItemStyle.Render(tis.Prompt))
		b.WriteString("\n\n")
	}

	// Render input box with cursor
	runes := []rune(tis.Value)
	inputBoxW := boxW - 8
	if inputBoxW < 20 {
		inputBoxW = 20
	}

	var inputDisplay strings.Builder
	if len(runes) == 0 && tis.Placeholder != "" {
		inputDisplay.WriteString(MutedItemStyle.Render(tis.Placeholder))
	} else {
		for i, r := range runes {
			if i == tis.CursorPos {
				inputDisplay.WriteString(lipgloss.NewStyle().Reverse(true).Render(string(r)))
			} else {
				inputDisplay.WriteString(string(r))
			}
		}
		if tis.CursorPos >= len(runes) {
			inputDisplay.WriteString(lipgloss.NewStyle().Reverse(true).Render(" "))
		}
	}

	inputFieldStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(ColorPrimary).
		Padding(0, 1).
		Width(inputBoxW)

	b.WriteString(inputFieldStyle.Render(inputDisplay.String()))
	b.WriteString("\n\n")
	b.WriteString(MutedItemStyle.Render("[Enter] 決定   [Esc] キャンセル"))

	modalBox := ModalBoxStyle.Width(boxW).Render(b.String())
	return lipgloss.Place(totalW, totalH, lipgloss.Center, lipgloss.Center, modalBox)
}
