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
	if NeedsHwDownload("none", "CPU", false) {
		t.Errorf("Expected NeedsHwDownload to be false for none decoder")
	}
	if !NeedsHwDownload("vulkan", "CPU", false) {
		t.Errorf("Expected NeedsHwDownload to be true for vulkan decoder")
	}
	if !NeedsHwDownload("cuda", "NVIDIA", true) {
		t.Errorf("Expected NeedsHwDownload to be true for cuda with sw filters")
	}
	if NeedsHwDownload("cuda", "NVIDIA", false) {
		t.Errorf("Expected NeedsHwDownload to be false for pure cuda without sw filters")
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

func TestAudioPipelineArgs(t *testing.T) {
	// 1. qaac args test
	qaacArgs := BuildExternalAudioArgs("qaac", "tvbr91", "", "in.wav", "out.m4a")
	if len(qaacArgs) < 4 || qaacArgs[1] != "--tvbr" || qaacArgs[2] != "91" {
		t.Errorf("Expected qaac args with --tvbr 91, got: %v", qaacArgs)
	}

	qaacHeArgs := BuildExternalAudioArgs("qaac", "he64", "", "in.wav", "out.m4a")
	if len(qaacHeArgs) < 5 || qaacHeArgs[1] != "--he" || qaacHeArgs[2] != "--cvbr" || qaacHeArgs[3] != "64" {
		t.Errorf("Expected qaac args with --he --cvbr 64, got: %v", qaacHeArgs)
	}

	// 2. nero args test
	neroArgs := BuildExternalAudioArgs("nero", "q050", "", "in.wav", "out.m4a")
	if len(neroArgs) < 6 || neroArgs[0] != "-q" || neroArgs[1] != "0.50" {
		t.Errorf("Expected nero args with -q 0.50, got: %v", neroArgs)
	}

	neroHeArgs := BuildExternalAudioArgs("nero", "q035", "", "in.wav", "out.m4a")
	if len(neroHeArgs) < 7 || neroHeArgs[0] != "-he" || neroHeArgs[1] != "-q" || neroHeArgs[2] != "0.35" {
		t.Errorf("Expected nero args with -he -q 0.35, got: %v", neroHeArgs)
	}

	// 3. fdkaac args test
	fdkArgs := BuildExternalAudioArgs("fdkaac", "m4", "", "in.wav", "out.m4a")
	if len(fdkArgs) < 4 || fdkArgs[0] != "-m" || fdkArgs[1] != "4" {
		t.Errorf("Expected fdkaac args with -m 4, got: %v", fdkArgs)
	}

	fdkHeArgs := BuildExternalAudioArgs("fdkaac", "m3", "", "in.wav", "out.m4a")
	if len(fdkHeArgs) < 6 || fdkHeArgs[0] != "-p" || fdkHeArgs[1] != "5" || fdkHeArgs[2] != "-m" || fdkHeArgs[3] != "3" {
		t.Errorf("Expected fdkaac args with -p 5 -m 3, got: %v", fdkHeArgs)
	}

	// 4. Internal audio args test
	opusArgs := BuildInternalAudioArgs("opus", "192k", "")
	if len(opusArgs) < 4 || opusArgs[1] != "libopus" || opusArgs[3] != "192k" {
		t.Errorf("Expected internal opus args with 192k, got: %v", opusArgs)
	}

	flacArgs := BuildInternalAudioArgs("flac", "comp12", "")
	if len(flacArgs) < 4 || flacArgs[1] != "flac" || flacArgs[3] != "12" {
		t.Errorf("Expected internal flac args with 12, got: %v", flacArgs)
	}

	aacArgs := BuildInternalAudioArgs("internal_aac", "custom", "160k")
	if len(aacArgs) < 4 || aacArgs[1] != "aac" || aacArgs[3] != "160k" {
		t.Errorf("Expected internal aac args with 160k, got: %v", aacArgs)
	}
}

func TestGetHwAccelArgsCompatibility(t *testing.T) {
	// Matching pairs should use zero-copy format
	cudaNv := GetHwAccelArgs("cuda", "NVIDIA")
	if len(cudaNv) != 4 || cudaNv[1] != "cuda" || cudaNv[3] != "cuda" {
		t.Errorf("Expected zero-copy cuda args, got: %v", cudaNv)
	}

	qsvIntel := GetHwAccelArgs("qsv", "Intel")
	if len(qsvIntel) != 4 || qsvIntel[1] != "qsv" || qsvIntel[3] != "qsv" {
		t.Errorf("Expected zero-copy qsv args, got: %v", qsvIntel)
	}

	// Mixed combinations should NOT force incompatible GPU format
	d3d11Intel := GetHwAccelArgs("d3d11va", "Intel")
	if len(d3d11Intel) != 2 || d3d11Intel[1] != "d3d11va" {
		t.Errorf("Expected d3d11va without output format for Intel encoder, got: %v", d3d11Intel)
	}

	d3d11Nv := GetHwAccelArgs("d3d11va", "NVIDIA")
	if len(d3d11Nv) != 2 || d3d11Nv[1] != "d3d11va" {
		t.Errorf("Expected d3d11va without output format for NVIDIA encoder, got: %v", d3d11Nv)
	}
}
