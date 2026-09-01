package runner

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"windows-reencode-utility/src/internal/config"
	"windows-reencode-utility/src/internal/core"
)

func fileExists(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.Size() > 0
}

func TestRunnerExecuteGeneral(t *testing.T) {
	inputPath := filepath.Join("..", "..", "test_sample.mp4")
	absInput, err := filepath.Abs(inputPath)
	if err != nil || !fileExists(absInput) {
		t.Skip("test_sample.mp4 not found, skipping integration test")
	}

	cfg := config.DefaultConfig()
	cfg.AppDir = filepath.Dir(absInput)
	cfg.Output.SubfolderName = "test_output"

	info, errProbe := core.ProbeMedia("ffprobe", absInput)
	if errProbe != nil {
		t.Fatalf("ProbeMedia failed: %v", errProbe)
	}

	item := &core.QueueItem{
		ID:       1,
		Path:     absInput,
		FileName: filepath.Base(absInput),
		Info:     info,
		Status:   "Pending",
	}

	r := NewRunner(cfg)
	progressChan := make(chan core.ProgressUpdate, 100)

	genSettings := core.GeneralSettings{
		HwDecoder:    "none",
		HwEncoder:    "CPU",
		VideoCodec:   "libx264",
		QualityIndex: 1,
		SpeedPreset:  "ultrafast",
		AudioEncoder: "copy",
		Deinterlace:  core.DeinterlaceNone,
		OutputExt:    "mp4",
		CPULimit:     core.CPURestrictionAll,
		Overwrite:    core.OverwriteForce,
	}

	outDir := filepath.Join(cfg.AppDir, "test_output")
	_ = os.MkdirAll(outDir, 0755)
	defer os.RemoveAll(outDir)

	go r.RunQueue(
		context.Background(),
		[]*core.QueueItem{item},
		core.ModeGeneral,
		genSettings,
		core.PlatformSettings{},
		core.IntermediateSettings{},
		core.SplitSettings{},
		progressChan,
	)

	for range progressChan {
		// drain channel
	}

	if item.Status != "Completed" {
		t.Fatalf("Expected status Completed, got %s (err: %s)", item.Status, item.ErrorMessage)
	}

	if !fileExists(item.OutputPath) {
		t.Fatalf("Output file does not exist: %s", item.OutputPath)
	}

	logPath := filepath.Join(outDir, "test_sample_encode.log")
	if !fileExists(logPath) {
		t.Errorf("Encode log does not exist: %s", logPath)
	}
}

func TestDetailedEncodeLogIncludesAudioSection(t *testing.T) {
	tempDir := t.TempDir()
	outPath := filepath.Join(tempDir, "sample.mp4")
	_ = os.WriteFile(outPath, []byte("dummy video content"), 0644)

	rep := EncodeReport{
		Item: &core.QueueItem{
			FileName: "sample.mp4",
			Path:     "C:\\dummy\\sample.mp4",
			Info: core.MediaInfo{
				FileSizeMB: 100.0,
			},
		},
		OutPath:      outPath,
		ModeName:     "通常エンコード (General)",
		AudioEncoder: "nero",
		AudioRawStderr: []string{
			"[Step 1: WAV抽出 stderr] ffmpeg audio extraction complete",
			"[Step 2: nero stderr] neroAacEnc processing... 100%",
		},
		RawStderr: []string{
			"ffmpeg video encoding complete frame=1000",
		},
		Success: true,
	}

	r := &Runner{}
	r.writeDetailedEncodeLog(rep)

	logPath := filepath.Join(tempDir, "sample_encode.log")
	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("Failed to read generated encode log: %v", err)
	}

	logStr := string(content)
	if !strings.Contains(logStr, "【音声エンコード / 外部ツール ログ (Audio Process Log)】") {
		t.Errorf("Expected log to contain audio process section, got:\n%s", logStr)
	}

	if !strings.Contains(logStr, "neroAacEnc processing... 100%") {
		t.Errorf("Expected log to contain neroAacEnc log line, got:\n%s", logStr)
	}

	if !strings.Contains(logStr, "【FFmpeg 映像エンコード 生の標準エラー出力ログ (Raw Console Stderr Log)】") {
		t.Errorf("Expected log to contain video stderr section, got:\n%s", logStr)
	}
}
