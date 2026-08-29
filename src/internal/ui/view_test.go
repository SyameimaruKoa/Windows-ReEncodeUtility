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

func TestRenderScrollableLines(t *testing.T) {
	items := []ScrollableItem{
		{0, "Line 0 (Title)"},
		{1, "Line 1 (HW Decoder)"},
		{2, "Line 2 (HW Encoder)"},
		{3, "Line 3 (Video Codec)"},
		{4, "Line 4 (Quality)"},
		{5, "Line 5 (Speed)"},
		{6, "Line 6 (Audio)"},
		{7, "Line 7 (Deinterlace)"},
		{8, "Line 8 (Ext)"},
		{9, "Line 9 (Advanced Toggle)"},
		{10, "Line 10 (CPU)"},
		{11, "Line 11 (AV1)"},
		{12, "Line 12 (Overwrite)"},
		{13, "Line 13 (TwoPass)"},
		{14, "Line 14 (Metadata)"},
		{15, "Line 15 (Cut)"},
		{16, "Line 16 (VF)"},
		{17, "Line 17 (Args)"},
		{18, "Line 18 (Power)"},
		{99, "Line 99 (Start)"},
	}

	maxLines := 8

	// When selecting bottom item (Field 99)
	outBottom := RenderScrollableLines(items, 99, maxLines)
	linesBottom := strings.Split(outBottom, "\n")
	if len(linesBottom) != maxLines {
		t.Errorf("Expected %d lines, got %d", maxLines, len(linesBottom))
	}
	if !strings.Contains(outBottom, "Line 99 (Start)") {
		t.Errorf("Expected outBottom to contain Line 99 (Start), got %s", outBottom)
	}

	// When selecting top item (Field 0)
	outTop := RenderScrollableLines(items, 0, maxLines)
	linesTop := strings.Split(outTop, "\n")
	if len(linesTop) != maxLines {
		t.Errorf("Expected %d lines, got %d", maxLines, len(linesTop))
	}
	if !strings.Contains(outTop, "Line 0 (Title)") {
		t.Errorf("Expected outTop to contain Line 0 (Title), got %s", outTop)
	}

	// When selecting middle item (Field 10)
	outMid := RenderScrollableLines(items, 10, maxLines)
	if !strings.Contains(outMid, "Line 10 (CPU)") {
		t.Errorf("Expected outMid to contain Line 10 (CPU), got %s", outMid)
	}
}

func TestRenderGeneralViewScrolling(t *testing.T) {
	s := core.GeneralSettings{
		HwDecoder:    "d3d11va",
		HwEncoder:    "Intel",
		VideoCodec:   "libx264",
		QualityIndex: 1,
		SpeedPreset:  "medium",
		AudioEncoder: "internal_aac",
		AudioPreset:  "192k",
		Deinterlace:  core.DeinterlaceNone,
		OutputExt:    "mp4",
		ShowAdvanced: true,
		CPULimit:     core.CPURestrictionAll,
		Overwrite:    core.OverwriteSkip,
		TwoPass:      false,
		Metadata:     core.MetadataExifTool,
		CutStart:     "00:00:10",
		CutEnd:       "00:01:00",
		AfterPower:   core.PowerNone,
	}

	// Test height that is smaller than total items (approx 18 items)
	smallHeight := 10
	renderedBottom := RenderGeneralView(&s, 99, 70, smallHeight, true)
	if !strings.Contains(renderedBottom, "エンコード開始") {
		t.Errorf("Expected RenderGeneralView with activeField 99 to contain start button, got:\n%s", renderedBottom)
	}

	renderedTop := RenderGeneralView(&s, 0, 70, smallHeight, true)
	if !strings.Contains(renderedTop, "通常エンコード") {
		t.Errorf("Expected RenderGeneralView with activeField 0 to contain title, got:\n%s", renderedTop)
	}

	renderedCut := RenderGeneralView(&s, 15, 70, smallHeight, true)
	if !strings.Contains(renderedCut, "カット区間") {
		t.Errorf("Expected RenderGeneralView with activeField 15 to contain cut field, got:\n%s", renderedCut)
	}
}

func TestCustomVideoAndAudioFormatting(t *testing.T) {
	s := core.GeneralSettings{
		HwDecoder:          "d3d11va",
		HwEncoder:          "NVIDIA",
		VideoCodec:         "h264_nvenc",
		QualityIndex:       1,
		CustomQualityValue: "25",
		SpeedPreset:        "p5",
		AudioEncoder:       "qaac",
		AudioPreset:        "tvbr91",
		Deinterlace:        core.DeinterlaceNone,
		OutputExt:          "mp4",
	}

	// Test custom CQ format
	qStr := formatQuality(&s)
	if !strings.Contains(qStr, "CQ 25") {
		t.Errorf("Expected formatQuality to contain 'CQ 25', got: %s", qStr)
	}

	// Test custom Bitrate format
	s.CustomQualityValue = ""
	s.CustomBitrate = "8000k"
	qStr2 := formatQuality(&s)
	if !strings.Contains(qStr2, "8000k") {
		t.Errorf("Expected formatQuality to contain '8000k', got: %s", qStr2)
	}

	// Test audio encoder name formatting
	nameStr := formatAudioEncoderName(s.AudioEncoder)
	if !strings.Contains(nameStr, "qaac") {
		t.Errorf("Expected formatAudioEncoderName to contain 'qaac', got: %s", nameStr)
	}

	// Test audio quality formatting
	qAudStr := formatAudioQuality(&s)
	if !strings.Contains(qAudStr, "TVBR 91") {
		t.Errorf("Expected formatAudioQuality to contain 'TVBR 91', got: %s", qAudStr)
	}

	// Test custom audio quality formatting
	s.AudioEncoder = "opus"
	s.AudioPreset = "custom"
	s.AudioCustom = "96k"
	qAudStr2 := formatAudioQuality(&s)
	if !strings.Contains(qAudStr2, "カスタム (96k)") {
		t.Errorf("Expected formatAudioQuality to contain 'カスタム (96k)', got: %s", qAudStr2)
	}
}

func TestTextInputModalState(t *testing.T) {
	tis := NewTextInputState("カスタム品質入力", "CRF値を入力してください", "22", "22", InputContextCustomQualityValue)
	if tis.Value != "22" {
		t.Errorf("Expected initial value '22', got '%s'", tis.Value)
	}

	// Test typing a character
	tis.HandleKey("5")
	if tis.Value != "225" {
		t.Errorf("Expected value '225', got '%s'", tis.Value)
	}

	// Test backspace
	tis.HandleKey("backspace")
	if tis.Value != "22" {
		t.Errorf("Expected value '22' after backspace, got '%s'", tis.Value)
	}

	// Test enter
	done, accepted := tis.HandleKey("enter")
	if !done || !accepted {
		t.Errorf("Expected done=true, accepted=true on enter")
	}

	// Test modal rendering
	rendered := RenderTextInputModal(&tis, 80, 24)
	if !strings.Contains(rendered, "カスタム品質入力") {
		t.Errorf("Expected RenderTextInputModal to contain title, got: %s", rendered)
	}
}
