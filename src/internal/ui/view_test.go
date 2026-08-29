package ui

import (
	"strings"
	"testing"

	"windows-reencode-utility/src/internal/config"
	"windows-reencode-utility/src/internal/core"

	tea "github.com/charmbracelet/bubbletea"
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

	// Test HW Decoder backward cycling (Field 3)
	m.generalSet.HwDecoder = "none"
	m.activeField = 3
	m.cycleGeneralField(-1)
	if m.generalSet.HwDecoder == "none" {
		t.Errorf("Expected HwDecoder to change on -1 from none")
	}

	// Test Video HW Encoder backward cycling (Field 1)
	m.generalSet.HwEncoder = "CPU"
	m.activeField = 1
	m.cycleGeneralField(-1)
	if m.generalSet.HwEncoder == "CPU" {
		t.Errorf("Expected HwEncoder to change on -1 from CPU")
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

	renderedCut := RenderGeneralView(&s, 11, 70, smallHeight, true)
	if !strings.Contains(renderedCut, "カット区間") {
		t.Errorf("Expected RenderGeneralView with activeField 11 to contain cut field, got:\n%s", renderedCut)
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

	// Test combined video setting formatting
	combinedVideo := formatCombinedVideoSetting(&s)
	if !strings.Contains(combinedVideo, "[NVIDIA]") || !strings.Contains(combinedVideo, "8000k") {
		t.Errorf("Expected formatCombinedVideoSetting to contain NVIDIA and 8000k, got: %s", combinedVideo)
	}

	// Test combined audio setting formatting
	combinedAudio := formatCombinedAudioSetting(&s)
	if !strings.Contains(combinedAudio, "qaac") || !strings.Contains(combinedAudio, "TVBR 91") {
		t.Errorf("Expected formatCombinedAudioSetting to contain qaac and TVBR 91, got: %s", combinedAudio)
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

func TestVideoAndAudioWizardFlow(t *testing.T) {
	cfg := &config.AppConfig{}
	cfg.Behavior.DefaultMode = "general"
	m := NewMainModel(cfg, nil)
	m.mode = core.ModeGeneral

	// 1. Test Video Wizard Flow: HW -> Codec -> Quality -> Speed -> Finish
	m.activeField = 1
	m.openDropdownDialog()

	if m.videoWizardStep != 1 || m.state != StateDropdownDialog {
		t.Fatalf("Expected videoWizardStep=1 and StateDropdownDialog, got step=%d, state=%d", m.videoWizardStep, m.state)
	}

	// Select NVIDIA (value "NVIDIA")
	m.dialogIndex = 1 // NVIDIA
	m.applyDropdownChoice()

	if m.videoWizardStep != 2 || m.generalSet.HwEncoder != "NVIDIA" {
		t.Fatalf("Expected videoWizardStep=2 and HwEncoder=NVIDIA, got step=%d, enc=%s", m.videoWizardStep, m.generalSet.HwEncoder)
	}

	// Select H.264 (value "h264_nvenc")
	m.dialogIndex = 0
	m.applyDropdownChoice()

	if m.videoWizardStep != 3 || m.generalSet.VideoCodec != "h264_nvenc" {
		t.Fatalf("Expected videoWizardStep=3 and VideoCodec=h264_nvenc, got step=%d, codec=%s", m.videoWizardStep, m.generalSet.VideoCodec)
	}

	// Select Quality CQ:28 (value "cq_28")
	m.dialogIndex = 1
	m.applyDropdownChoice()

	if m.videoWizardStep != 4 || m.generalSet.QualityIndex != 1 {
		t.Fatalf("Expected videoWizardStep=4 and QualityIndex=1, got step=%d, qIdx=%d", m.videoWizardStep, m.generalSet.QualityIndex)
	}

	// Select Speed P4 (value "p4")
	m.dialogIndex = 3
	m.applyDropdownChoice()

	if m.videoWizardStep != 0 || m.state != StateIdle || m.generalSet.SpeedPreset != "p4" {
		t.Fatalf("Expected video wizard completed (step=0, StateIdle, SpeedPreset=p4), got step=%d, state=%d, speed=%s", m.videoWizardStep, m.state, m.generalSet.SpeedPreset)
	}

	// 2. Test Audio Wizard Flow: Encoder -> Quality -> Finish
	m.activeField = 2
	m.openDropdownDialog()

	if m.audioWizardStep != 1 || m.state != StateDropdownDialog {
		t.Fatalf("Expected audioWizardStep=1 and StateDropdownDialog, got step=%d, state=%d", m.audioWizardStep, m.state)
	}

	// Select qaac (value "qaac")
	m.dialogIndex = 1
	m.applyDropdownChoice()

	if m.audioWizardStep != 2 || m.generalSet.AudioEncoder != "qaac" {
		t.Fatalf("Expected audioWizardStep=2 and AudioEncoder=qaac, got step=%d, enc=%s", m.audioWizardStep, m.generalSet.AudioEncoder)
	}

	// Select TVBR 73 (value "tvbr73")
	m.dialogIndex = 1
	m.applyDropdownChoice()

	if m.audioWizardStep != 0 || m.state != StateIdle || m.generalSet.AudioPreset != "tvbr73" {
		t.Fatalf("Expected audio wizard completed (step=0, StateIdle, AudioPreset=tvbr73), got step=%d, state=%d, preset=%s", m.audioWizardStep, m.state, m.generalSet.AudioPreset)
	}

	// 3. Test Audio Copy Flow: copy terminates wizard immediately
	m.activeField = 2
	m.openDropdownDialog()
	m.dialogIndex = 7 // copy
	m.applyDropdownChoice()

	if m.audioWizardStep != 0 || m.state != StateIdle || m.generalSet.AudioEncoder != "copy" {
		t.Fatalf("Expected copy to finish audio wizard immediately, got step=%d, state=%d, enc=%s", m.audioWizardStep, m.state, m.generalSet.AudioEncoder)
	}
}

func TestInterruptAndModifySettingsFlow(t *testing.T) {
	cfg := &config.AppConfig{}
	cfg.Behavior.DefaultMode = "general"
	m := NewMainModel(cfg, nil)
	m.mode = core.ModeGeneral
	m.queueItems = []*core.QueueItem{
		{
			ID:     1,
			Path:   "C:\\test.mp4",
			Status: "Pending",
		},
	}

	// 1. Start encoding
	m.state = StateEncoding

	// 2. User presses ESC to interrupt
	m.handleKeyPress(tea.KeyMsg{Type: tea.KeyEsc})
	if m.state != StateIdle {
		t.Fatalf("Expected StateIdle after Esc, got %d", m.state)
	}

	// 3. Background process finishes and sends QueueFinishedMsg
	m.Update(QueueFinishedMsg{})
	if m.state != StateIdle {
		t.Fatalf("Expected state to stay StateIdle after QueueFinishedMsg following an interrupt, got %d", m.state)
	}

	// 4. User moves to Video Setting (Field 1) and presses Enter
	m.activeField = 1
	m.handleKeyPress(tea.KeyMsg{Type: tea.KeyEnter})

	// Must open wizard, NOT quit!
	if m.state != StateDropdownDialog || m.videoWizardStep != 1 {
		t.Fatalf("Expected StateDropdownDialog and videoWizardStep=1 on Enter, got state=%d, step=%d", m.state, m.videoWizardStep)
	}

	// Cancel wizard with Esc
	m.handleModalKey("esc")
	if m.state != StateIdle {
		t.Fatalf("Expected StateIdle after modal Esc, got %d", m.state)
	}

	// 5. User moves to Start button (Field 99) and presses Enter to re-run
	m.activeField = 99
	m.handleKeyPress(tea.KeyMsg{Type: tea.KeyEnter})

	if m.state != StateEncoding {
		t.Fatalf("Expected StateEncoding after clicking Start button, got %d", m.state)
	}
}

func TestRetryFailedItemsOnKeyR(t *testing.T) {
	cfg := &config.AppConfig{}
	cfg.Behavior.DefaultMode = "general"
	m := NewMainModel(cfg, nil)
	m.mode = core.ModeGeneral
	m.queueItems = []*core.QueueItem{
		{
			ID:     1,
			Path:   "C:\\test1.mp4",
			Status: "Completed",
		},
		{
			ID:     2,
			Path:   "C:\\test2.mp4",
			Status: "Failed",
		},
	}

	// Set state to Complete
	m.state = StateComplete

	// Press 'R' to retry
	m.handleKeyPress(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'R'}})

	if m.state != StateEncoding {
		t.Fatalf("Expected state=StateEncoding after pressing R on failed item, got %d", m.state)
	}

	if m.queueItems[0].Status != "Completed" {
		t.Errorf("Expected item 0 to remain Completed, got %s", m.queueItems[0].Status)
	}

	if m.queueItems[1].Status != "Pending" {
		t.Errorf("Expected item 1 to be reset to Pending, got %s", m.queueItems[1].Status)
	}

	// Verify channel is open and receiving updates without panic
	m.Update(ProgressMsg{Percent: 50})
	m.Update(QueueFinishedMsg{})
	if m.state != StateComplete {
		t.Fatalf("Expected state=StateComplete after finish, got %d", m.state)
	}
}
