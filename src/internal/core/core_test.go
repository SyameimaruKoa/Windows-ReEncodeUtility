package core

import (
	"testing"
)

func TestCalculateTargetBitrate(t *testing.T) {
	// 512MB, 60s, 128kbps audio
	// TargetBitrate = ((512 * 1024 * 8 * 0.985) - (128 * 60)) / 60
	br := CalculateTargetBitrate(512, 60, 128)
	if br <= 0 {
		t.Errorf("Expected positive bitrate, got %d", br)
	}

	// Zero or negative duration fallback
	fallbackBr := CalculateTargetBitrate(512, 0, 128)
	if fallbackBr != 2000 {
		t.Errorf("Expected 2000 fallback bitrate for 0 duration, got %d", fallbackBr)
	}
}

func TestIsOverTargetSize(t *testing.T) {
	// 100MB limit = 104,857,600 bytes
	limitMB := float64(100)
	if IsOverTargetSize(104857600, limitMB) {
		t.Errorf("Expected false for exact limit")
	}
	if !IsOverTargetSize(104857601, limitMB) {
		t.Errorf("Expected true for exceeded limit")
	}
}

func TestParseCutTime(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"", ""},
		{"00:00:00", ""},
		{"0", ""},
		{"01:23", "00:01:23"},
		{"83", "00:01:23"},
		{"83.5", "00:01:23.500"},
		{"01:23:45", "01:23:45"},
		{"01:23:45.500", "01:23:45.500"},
	}

	for _, tt := range tests {
		res := ParseCutTime(tt.input)
		if res != tt.expected {
			t.Errorf("ParseCutTime(%q) = %q, expected %q", tt.input, res, tt.expected)
		}
	}
}

func TestSanitizeFileName(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"chapter:01/intro?*", "chapter_01_intro"},
		{"test<file>name|", "test_file_name"},
		{"clean_name", "clean_name"},
		{"...", "segment"},
	}

	for _, tt := range tests {
		res := SanitizeFileName(tt.input)
		if res != tt.expected {
			t.Errorf("SanitizeFileName(%q) = %q, expected %q", tt.input, res, tt.expected)
		}
	}
}

func TestBuildSegmentOutputName(t *testing.T) {
	ch := ChapterInfo{ID: 1, Title: "Opening"}
	nameText := BuildSegmentOutputName("sample", ch, "text", "mp4")
	if nameText != "sample_Opening.mp4" {
		t.Errorf("Expected sample_Opening.mp4, got %s", nameText)
	}

	nameIndex := BuildSegmentOutputName("sample", ch, "index", "mp4")
	if nameIndex != "sample_01.mp4" {
		t.Errorf("Expected sample_01.mp4, got %s", nameIndex)
	}
}

func TestHwCompat(t *testing.T) {
	if !NeedsHwDownload("d3d11va", "CPU", false) {
		t.Errorf("Expected NeedsHwDownload to be true for CPU encoder with d3d11va decoder")
	}
	if NeedsHwDownload("none", "CPU", false) {
		t.Errorf("Expected NeedsHwDownload to be false for none decoder")
	}

	if NeedsExtraHwFrames("cuda", "NVIDIA") {
		t.Errorf("Expected false for matched CUDA + NVIDIA")
	}
	if !NeedsExtraHwFrames("d3d11va", "NVIDIA") {
		t.Errorf("Expected true for mixed d3d11va + NVIDIA")
	}
}

func TestNeedsGenPTS(t *testing.T) {
	if !NeedsGenPTS("dash") {
		t.Errorf("Expected true for dash format")
	}
	if !NeedsGenPTS("ismv") {
		t.Errorf("Expected true for ismv format")
	}
	if NeedsGenPTS("matroska,webm") {
		t.Errorf("Expected false for matroska")
	}
}
