package ui

import (
    "fmt"
    "strings"

    "github.com/charmbracelet/lipgloss"
    "windows-reencode-utility/src/internal/core"
)

// RenderQueueView renders the left panel: queue list and selected item media information.
func RenderQueueView(items []*core.QueueItem, selectedIdx int, outerWidth, outerHeight int, focused bool) string {
    var b strings.Builder

    innerWidth := outerWidth - 4
    if innerWidth < 10 {
        innerWidth = 10
    }

    // Header (1 line)
    header := fmt.Sprintf("[キュー] 処理対象 (%d件)", len(items))
    b.WriteString(HeaderTitleStyle.Render(PadRightDisplay(header, innerWidth)))
    b.WriteString("\n")

    listHeight := outerHeight - 10
    if listHeight < 2 {
        listHeight = 2
    }

    var listContent strings.Builder
    if len(items) == 0 {
        listContent.WriteString(MutedItemStyle.Render("キューは空です。\n(動画ファイルを指定)"))
    } else {
        start := 0
        if selectedIdx >= listHeight {
            start = selectedIdx - listHeight + 1
        }
        end := start + listHeight
        if end > len(items) {
            end = len(items)
        }

        for i := start; i < end; i++ {
            it := items[i]
            prefix := "  "
            if i == selectedIdx {
                prefix = "> "
            }

            statusTag := ""
            switch it.Status {
            case "Encoding":
                statusTag = " [処理中]"
            case "Completed":
                statusTag = " [完了]"
            case "Failed":
                statusTag = " [失敗]"
            case "Skipped":
                statusTag = " [スキップ]"
            }

            resolution := ""
            if it.Info.Width > 0 && it.Info.Height > 0 {
                resolution = fmt.Sprintf("%dx%d", it.Info.Width, it.Info.Height)
            } else if it.Probing {
                resolution = "解析中..."
            }

            rawLine := fmt.Sprintf("%s%d. %s (%s, %.1fMB)%s", prefix, i+1, it.FileName, resolution, it.Info.FileSizeMB, statusTag)
            lineItemWidth := innerWidth - 2
            if lineItemWidth < 8 {
                lineItemWidth = 8
            }
            truncatedLine := TruncateDisplay(rawLine, lineItemWidth, "...")
            paddedLine := PadRightDisplay(truncatedLine, lineItemWidth)

            if it.Status == "Failed" {
                failStyle := lipgloss.NewStyle().Foreground(ColorError).Bold(true)
                if i == selectedIdx {
                    if focused {
                        listContent.WriteString(ActiveItemStyle.Render(paddedLine))
                    } else {
                        listContent.WriteString(failStyle.Render(paddedLine))
                    }
                } else {
                    listContent.WriteString(failStyle.Render(paddedLine))
                }
            } else if i == selectedIdx {
                if focused {
                    listContent.WriteString(ActiveItemStyle.Render(paddedLine))
                } else {
                    listContent.WriteString(SelectedItemStyle.Render(paddedLine))
                }
            } else {
                listContent.WriteString(NormalItemStyle.Render(paddedLine))
            }
            if i < end-1 {
                listContent.WriteString("\n")
            }
        }
    }

    boxWidth := innerWidth - 2
    if boxWidth < 8 {
        boxWidth = 8
    }
    boxStyle := lipgloss.NewStyle().
        Border(lipgloss.NormalBorder()).
        BorderForeground(lipgloss.Color("#45475A")).
        Width(boxWidth).
        Height(listHeight)

    // Box render (listHeight + 2 lines)
    b.WriteString(boxStyle.Render(listContent.String()))
    b.WriteString("\n")

    // Queue operation hints (1 line)
    b.WriteString(MutedItemStyle.Render(PadRightDisplay("[Ctrl+↑/↓: 順序入替] [Del: 削除]", innerWidth)))
    b.WriteString("\n")

    // Selected file media info / Error header (1 line)
    if len(items) > 0 && selectedIdx >= 0 && selectedIdx < len(items) && items[selectedIdx].Status == "Failed" {
        b.WriteString(lipgloss.NewStyle().Foreground(ColorError).Bold(true).Render(PadRightDisplay("[⚠ エラー詳細 / 失敗原因]", innerWidth)))
        b.WriteString("\n")

        errMsg := items[selectedIdx].ErrorMessage
        if errMsg == "" {
            errMsg = "処理中にエラーが発生しました。"
        }
        errLine1 := fmt.Sprintf("・原因: %s", errMsg)
        b.WriteString(lipgloss.NewStyle().Foreground(ColorError).Render(PadRightDisplay(TruncateDisplay(errLine1, innerWidth, "..."), innerWidth)) + "\n")
        b.WriteString(WarningTextStyle.Render(PadRightDisplay("・対策: 右ペインで設定を変更し [R] で再試行", innerWidth)) + "\n")
        b.WriteString(MutedItemStyle.Render(PadRightDisplay("・(同名ファイルの場合は [上書き] に変更)", innerWidth)))
    } else {
        b.WriteString(HeaderTitleStyle.Render(PadRightDisplay("[選択ファイルのメディア情報]", innerWidth)))
        b.WriteString("\n")

        if len(items) > 0 && selectedIdx >= 0 && selectedIdx < len(items) {
            sel := items[selectedIdx]
            if sel.Probing {
                b.WriteString(MutedItemStyle.Render(PadRightDisplay("・メディア情報を解析中...", innerWidth)) + "\n")
                b.WriteString(MutedItemStyle.Render(PadRightDisplay("・-", innerWidth)) + "\n")
                b.WriteString(MutedItemStyle.Render(PadRightDisplay("・-", innerWidth)))
            } else if !sel.Info.HasVideo {
                b.WriteString(ErrorTextStyle.Render(PadRightDisplay("・動画ストリームが検出されませんでした", innerWidth)) + "\n")
                b.WriteString(MutedItemStyle.Render(PadRightDisplay("・-", innerWidth)) + "\n")
                b.WriteString(MutedItemStyle.Render(PadRightDisplay("・-", innerWidth)))
            } else {
                durLine := fmt.Sprintf("・長さ: %s / 解像度: %dx%d", sel.Info.DurationStr, sel.Info.Width, sel.Info.Height)
                b.WriteString(NormalItemStyle.Render(PadRightDisplay(TruncateDisplay(durLine, innerWidth, "..."), innerWidth)) + "\n")

                vidLine := fmt.Sprintf("・映像: %s, %.1ffps, %s", sel.Info.VideoCodec, sel.Info.FPS, sel.Info.PixFmt)
                b.WriteString(NormalItemStyle.Render(PadRightDisplay(TruncateDisplay(vidLine, innerWidth, "..."), innerWidth)) + "\n")

                if sel.Info.HasAudio {
                    audLine := fmt.Sprintf("・音声: %s, %dHz, %s (%dkbps)", sel.Info.AudioCodec, sel.Info.SampleRate, sel.Info.ChannelLayout, sel.Info.AudioBitrateKbps)
                    b.WriteString(NormalItemStyle.Render(PadRightDisplay(TruncateDisplay(audLine, innerWidth, "..."), innerWidth)))
                } else {
                    b.WriteString(MutedItemStyle.Render(PadRightDisplay("・音声: なし", innerWidth)))
                }
            }
        } else {
            b.WriteString(MutedItemStyle.Render(PadRightDisplay("・ファイルが選択されていません", innerWidth)) + "\n")
            b.WriteString(MutedItemStyle.Render(PadRightDisplay("・-", innerWidth)) + "\n")
            b.WriteString(MutedItemStyle.Render(PadRightDisplay("・-", innerWidth)))
        }
    }

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
