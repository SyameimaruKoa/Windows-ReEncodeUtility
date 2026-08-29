package ui

import (
	"strings"
	"testing"

	"windows-reencode-utility/src/internal/config"
	"windows-reencode-utility/src/internal/core"
)

func TestProgressBarRendering(t *testing.T) {
	widths := []int{90, 110, 140}
	percents := []float64{0, 5, 14, 25, 50, 75, 99, 100}

	for _, w := range widths {
		for _, pct := range percents {
			p := core.ProgressUpdate{
				Percent:      pct,
				CurrentSec:   16.0,
				TotalSec:     113.0,
				Speed:        "1.11x",
				FPS:          27,
				OutBytes:     4 * 1024 * 1024,
				RemainingSec: 91,
			}

			rendered := RenderProgressView(p, false, w)
			lines := strings.Split(rendered, "\n")
			if len(lines) != 5 {
				t.Errorf("Expected 5 lines for ProgressView, got %d for (w=%d, pct=%.0f)", len(lines), w, pct)
			}

			// Verify rendered line has correct outer visual width
			for lineIdx, line := range lines {
				visWidth := StringVisualWidth(line)
				if visWidth != w {
					t.Errorf("Line %d visual width mismatch: got %d, expected %d for (w=%d, pct=%.0f)\nLine: %q", lineIdx+1, visWidth, w, w, pct, line)
				}
			}
		}
	}
}

func TestModelViewLayout(t *testing.T) {
	cfg := config.DefaultConfig()
	m := NewMainModel(cfg, nil)

	item := &core.QueueItem{
		ID:       1,
		FileName: "00005.m2ts",
		Path:     `C:\Users\kouki\Downloads\新しいフォルダー\00005.m2ts`,
		Info: core.MediaInfo{
			HasVideo:         true,
			VideoCodec:       "h264",
			DurationStr:      "00:01:53",
			Width:            1920,
			Height:           1080,
			FPS:              24.0,
			PixFmt:           "yuv420p",
			HasAudio:         true,
			AudioCodec:       "pcm_bluray",
			SampleRate:       48000,
			ChannelLayout:    "stereo",
			AudioBitrateKbps: 2304,
			FileSizeMB:       539.08,
		},
		Status: "Pending",
	}
	m.queueItems = append(m.queueItems, item)

	widths := []int{90, 110, 140, 200}
	heights := []int{26, 30, 35, 45, 60}

	for _, h := range heights {
		for _, w := range widths {
			m.width = w
			m.height = h

			// 1. Log collapsed test
			m.logExpanded = false
			out := m.View()
			lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
			if len(lines) > h {
				t.Errorf("View lines count %d exceeds terminal height %d for (w=%d, h=%d)", len(lines), h, w, h)
			}

			// 2. Log expanded test
			m.logExpanded = true
			outExp := m.View()
			linesExp := strings.Split(strings.TrimRight(outExp, "\n"), "\n")
			if len(linesExp) > h {
				t.Errorf("Expanded log View lines count %d exceeds terminal height %d for (w=%d, h=%d)", len(linesExp), h, w, h)
			}
		}
	}
}

func TestFormatDropdownField(t *testing.T) {
	res := FormatDropdownField("HWデコード   ", "推奨・Windows標準 (d3d11va)", 60, true)
	w := StringVisualWidth(res)
	if w != 60 {
		t.Errorf("Expected visual width 60, got %d for %q", w, res)
	}

	res2 := FormatDropdownField("HWエンコーダ ", "NVIDIA (NVENC)", 60, true)
	w2 := StringVisualWidth(res2)
	if w2 != 60 {
		t.Errorf("Expected visual width 60, got %d for %q", w2, res2)
	}

	res3 := FormatDropdownField("音声設定     ", "qaac: AAC-LC 標準 (tvbr 90)", 60, true)
	w3 := StringVisualWidth(res3)
	if w3 != 60 {
		t.Errorf("Expected visual width 60, got %d for %q", w3, res3)
	}
}

func TestCycleNavigation(t *testing.T) {
	cfg := config.DefaultConfig()
	m := NewMainModel(cfg, nil)

	// Test mode backward cycling
	m.mode = core.ModeGeneral
	m.cycleMode(-1)
	if m.mode != core.ModeSplit {
		t.Errorf("Expected ModeSplit on -1 from General, got %s", m.mode)
	}
	m.cycleMode(1)
	if m.mode != core.ModeGeneral {
		t.Errorf("Expected ModeGeneral on +1 from Split, got %s", m.mode)
	}

	// Test HW Decoder backward cycling
	m.generalSet.HwDecoder = "none"
	m.activeField = 1
	m.cycleGeneralField(-1)
	if m.generalSet.HwDecoder == "none" {
		t.Errorf("Expected HwDecoder to change on -1 from none")
	}
}
