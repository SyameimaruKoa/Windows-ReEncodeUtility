package runner

import (
	"context"
	"os"
	"path/filepath"
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
