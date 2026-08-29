package runner

import (
	"bufio"
	"context"
	"fmt"
	"math"
	"math/bits"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"windows-reencode-utility/src/internal/config"
	"windows-reencode-utility/src/internal/core"
)

// Runner orchestrates batch encoding jobs.
type Runner struct {
	cfg        *config.AppConfig
	coreInfo   ProcessorCoreInfo
	taskbar    *TaskbarController
	mu         sync.Mutex
	curProc    *ProcessHandle
	isPaused   bool
	cancelFunc context.CancelFunc
}

// NewRunner creates a new Runner instance.
func NewRunner(cfg *config.AppConfig) *Runner {
	return &Runner{
		cfg:      cfg,
		coreInfo: DetectProcessorCores(),
		taskbar:  NewTaskbarController(),
	}
}

// Pause pauses the currently running encoding process.
func (r *Runner) Pause() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.curProc != nil && !r.isPaused {
		_ = r.curProc.Suspend()
		r.isPaused = true
		if r.taskbar != nil {
			r.taskbar.SetProgress(50, 100, TBPF_PAUSED)
		}
	}
}

// Resume resumes the paused encoding process.
func (r *Runner) Resume() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.curProc != nil && r.isPaused {
		_ = r.curProc.Resume()
		r.isPaused = false
		if r.taskbar != nil {
			r.taskbar.SetProgress(50, 100, TBPF_NORMAL)
		}
	}
}

// TogglePause toggles pause/resume state.
func (r *Runner) TogglePause() bool {
	r.mu.Lock()
	paused := r.isPaused
	r.mu.Unlock()
	if paused {
		r.Resume()
		return false
	}
	r.Pause()
	return true
}

// IsPaused returns current pause state.
func (r *Runner) IsPaused() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.isPaused
}

// Cancel cancels the active encoding pipeline.
func (r *Runner) Cancel() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cancelFunc != nil {
		r.cancelFunc()
	}
	if r.curProc != nil {
		_ = r.curProc.Kill()
	}
	if r.taskbar != nil {
		r.taskbar.Clear()
	}
}

// RunQueue executes encoding for all items in the queue sequentially.
func (r *Runner) RunQueue(
	ctx context.Context,
	items []*core.QueueItem,
	mode core.Mode,
	genSettings core.GeneralSettings,
	platSettings core.PlatformSettings,
	interSettings core.IntermediateSettings,
	splitSettings core.SplitSettings,
	progressChan chan<- core.ProgressUpdate,
) {
	defer close(progressChan)

	ctx, cancel := context.WithCancel(ctx)
	r.mu.Lock()
	r.cancelFunc = cancel
	r.mu.Unlock()

	startTime := time.Now()
	totalItems := len(items)
	succeeded := 0
	failed := 0

	progressChan <- core.ProgressUpdate{
		LogLevel: "INFO",
		LogLine:  fmt.Sprintf("エンコードバッチ開始: 全 %d 件の処理を開始します。", totalItems),
	}

	for i, item := range items {
		select {
		case <-ctx.Done():
			progressChan <- core.ProgressUpdate{
				LogLevel: "WARN",
				LogLine:  "エンコード処理がユーザーによって中断されました。",
			}
			if r.taskbar != nil {
				r.taskbar.Clear()
			}
			return
		default:
		}

		if item.Status == "Completed" {
			succeeded++
			continue
		}

		item.Status = "Encoding"
		progressChan <- core.ProgressUpdate{
			QueueIndex: i + 1,
			TotalQueue: totalItems,
			Percent:    0,
			LogLevel:   "INFO",
			LogLine:    fmt.Sprintf("[%d/%d] 処理開始: %s", i+1, totalItems, item.FileName),
		}

		// Determine destination folder and path
		outDir := r.determineOutputDir(item.Path)
		_ = os.MkdirAll(outDir, 0755)

		var err error
		var outPath string

		switch mode {
		case core.ModeGeneral:
			outPath, err = r.encodeGeneral(ctx, item, i, totalItems, genSettings, outDir, progressChan)
		case core.ModePlatform:
			outPath, err = r.encodePlatform(ctx, item, i, totalItems, platSettings, outDir, progressChan)
		case core.ModeIntermediate:
			outPath, err = r.encodeIntermediate(ctx, item, i, totalItems, interSettings, outDir, progressChan)
		case core.ModeSplit:
			outPath, err = r.encodeSplit(ctx, item, i, totalItems, splitSettings, genSettings, outDir, progressChan)
		}

		if err != nil {
			item.Status = "Failed"
			item.ErrorMessage = err.Error()
			failed++
			progressChan <- core.ProgressUpdate{
				QueueIndex:   i + 1,
				TotalQueue:   totalItems,
				IsError:      true,
				ErrorMessage: err.Error(),
				LogLevel:     "ERROR",
				LogLine:      fmt.Sprintf("[%d/%d] エラー発生 (%s): %s", i+1, totalItems, item.FileName, err.Error()),
			}

			if r.taskbar != nil {
				r.taskbar.SetProgress(uint64(i+1), uint64(totalItems), TBPF_ERROR)
			}

			// Notification
			RunNotifyScript(r.cfg.Tools.NotifyScriptPath, fmt.Sprintf("エンコード失敗: %s", item.FileName), "ERROR")
			SendDiscordItemNotification(r.cfg.Tools.DiscordWebhookURL, r.cfg.Tools.DiscordMentionUserID, r.cfg.Tools.DiscordMentionOn, false, item.FileName, 0, "", 0, "", err.Error())

			// Clean up incomplete output file
			if outPath != "" {
				_ = os.Remove(outPath)
			}
		} else {
			item.Status = "Completed"
			item.OutputPath = outPath
			succeeded++

			fi, _ := os.Stat(outPath)
			outSizeMB := float64(0)
			if fi != nil {
				outSizeMB = float64(fi.Size()) / (1024 * 1024)
			}

			progressChan <- core.ProgressUpdate{
				QueueIndex: i + 1,
				TotalQueue: totalItems,
				Percent:    100,
				LogLevel:   "INFO",
				LogLine:    fmt.Sprintf("[%d/%d] 完了: %s (%.2f MB)", i+1, totalItems, filepath.Base(outPath), outSizeMB),
			}

			// Notification
			SendDiscordItemNotification(r.cfg.Tools.DiscordWebhookURL, r.cfg.Tools.DiscordMentionUserID, r.cfg.Tools.DiscordMentionOn, true, item.FileName, outSizeMB, item.Info.DurationStr, item.Info.FPS, item.Info.VideoCodec, "")
		}
	}

	totalDur := time.Since(startTime)
	progressChan <- core.ProgressUpdate{
		QueueIndex: totalItems,
		TotalQueue: totalItems,
		Percent:    100,
		LogLevel:   "INFO",
		LogLine:    fmt.Sprintf("全キュー完了: 成功 %d 件, 失敗 %d 件 (総所要時間: %s)", succeeded, failed, totalDur.Round(time.Second)),
	}

	if r.cfg.Behavior.PlaySoundOnComplete {
		PlaySystemSound()
	}
	RunNotifyScript(r.cfg.Tools.NotifyScriptPath, fmt.Sprintf("全エンコード完了 (成功: %d, 失敗: %d)", succeeded, failed), "INFO")
	SendDiscordQueueNotification(r.cfg.Tools.DiscordWebhookURL, r.cfg.Tools.DiscordMentionUserID, r.cfg.Tools.DiscordMentionOn, totalItems, succeeded, failed, totalDur)

	if r.taskbar != nil {
		if failed > 0 {
			r.taskbar.SetProgress(uint64(totalItems), uint64(totalItems), TBPF_ERROR)
		} else {
			r.taskbar.SetProgress(uint64(totalItems), uint64(totalItems), TBPF_NORMAL)
		}
	}
}

func (r *Runner) determineOutputDir(inputPath string) string {
	if r.cfg.Output.FixedOutputDir != "" {
		return r.cfg.Output.FixedOutputDir
	}
	inputDir := filepath.Dir(inputPath)
	subfolder := r.cfg.Output.SubfolderName
	if subfolder == "" {
		subfolder = "encoded_output"
	}
	return filepath.Join(inputDir, subfolder)
}

func (r *Runner) resolveDestinationFile(outDir, baseName, ext string, overwrite core.OverwriteAction) (string, error) {
	ext = strings.TrimPrefix(ext, ".")
	candidate := filepath.Join(outDir, fmt.Sprintf("%s.%s", baseName, ext))

	if _, err := os.Stat(candidate); os.IsNotExist(err) {
		return candidate, nil
	}

	switch overwrite {
	case core.OverwriteSkip:
		return "", fmt.Errorf("出力ファイルが既に存在するためスキップしました: %s", filepath.Base(candidate))
	case core.OverwriteForce:
		return candidate, nil
	case core.OverwriteAutoRename:
		for seq := 1; seq <= 999; seq++ {
			numbered := filepath.Join(outDir, fmt.Sprintf("%s_%02d.%s", baseName, seq, ext))
			if _, err := os.Stat(numbered); os.IsNotExist(err) {
				return numbered, nil
			}
		}
		return "", fmt.Errorf("連番ファイルの自動生成上限に達しました")
	default:
		return "", fmt.Errorf("出力ファイルが既に存在するためスキップしました: %s", filepath.Base(candidate))
	}
}

// EncodeReport holds complete metadata for creating comprehensive log files.
type EncodeReport struct {
	StartTime    time.Time
	EndTime      time.Time
	Duration     time.Duration
	Item         *core.QueueItem
	OutPath      string
	ModeName     string
	HwDecoder    string
	HwEncoder    string
	VideoCodec   string
	QualityStr   string
	SpeedPreset  string
	AudioEncoder string
	Deinterlace  string
	CPULimit     string
	AffinityMask uintptr
	AvgFPS       float64
	AvgSpeed     string
	TotalFrames  int64
	Commands     []string
	RawStderr    []string
	Success      bool
	ErrorMessage string
}

// encodeGeneral handles execution of General mode encoding.
func (r *Runner) encodeGeneral(
	ctx context.Context,
	item *core.QueueItem,
	qIdx, qTotal int,
	s core.GeneralSettings,
	outDir string,
	progressChan chan<- core.ProgressUpdate,
) (string, error) {
	startTime := time.Now()
	baseName := strings.TrimSuffix(item.FileName, filepath.Ext(item.FileName))
	outPath, err := r.resolveDestinationFile(outDir, baseName, s.OutputExt, s.Overwrite)
	if err != nil {
		return "", err
	}

	report := EncodeReport{
		StartTime:    startTime,
		Item:         item,
		OutPath:      outPath,
		ModeName:     "通常エンコード (General)",
		HwDecoder:    s.HwDecoder,
		HwEncoder:    s.HwEncoder,
		VideoCodec:   s.VideoCodec,
		QualityStr:   fmt.Sprintf("CRF %d", s.CustomCRF),
		SpeedPreset:  s.SpeedPreset,
		AudioEncoder: s.AudioEncoder,
		Deinterlace:  string(s.Deinterlace),
		CPULimit:     string(s.CPULimit),
	}
	if s.CPULimit == core.CPURestrictionECore {
		report.AffinityMask = r.coreInfo.ECoreMask
	} else if s.CPULimit == core.CPURestrictionPCore {
		report.AffinityMask = r.coreInfo.PCoreMask
	} else {
		report.AffinityMask = r.coreInfo.AllMask
	}

	// Build FFmpeg command arguments (1st pass to check externalAudio)
	args, externalAudio, err := r.buildGeneralArgs(item, s, outPath, "")
	if err != nil {
		return "", err
	}

	// Check disk space
	freeMB, errDisk := core.GetFreeDiskSpaceMB(outDir)
	if errDisk == nil && uint64(item.Info.FileSizeMB) > freeMB {
		progressChan <- core.ProgressUpdate{
			LogLevel: "WARN",
			LogLine:  fmt.Sprintf("⚠ 警告: 出力ドライブの空き容量が不足している可能性があります (空き: %d MB / 入力: %.1f MB)", freeMB, item.Info.FileSizeMB),
		}
	}

	// Handle external audio encode pipeline if configured
	tempAudioM4a := ""
	if externalAudio {
		progressChan <- core.ProgressUpdate{
			LogLevel: "INFO",
			LogLine:  fmt.Sprintf("外部音声エンコーダ (%s) による音声抽出・変換を実行中 (CPU制限: %s)...", s.AudioEncoder, s.CPULimit),
		}
		encPath := r.cfg.Tools.QaacPath
		if s.AudioEncoder == "nero" {
			encPath = r.cfg.Tools.NeroAacPath
		} else if s.AudioEncoder == "fdkaac" {
			encPath = r.cfg.Tools.FdkaacPath
		}

		m4a, cmdLogs, errAud := r.encodeExternalAudioRestricted(
			ctx,
			r.cfg.Tools.FfmpegPath,
			encPath,
			s.AudioEncoder,
			s.AudioPreset,
			s.AudioCustom,
			item.Path,
			r.cfg.Behavior.TempDir,
			string(s.CPULimit),
			func(p float64, msg string) {
				progressChan <- core.ProgressUpdate{
					QueueIndex: qIdx + 1,
					TotalQueue: qTotal,
					Percent:    p,
					LogLevel:   "INFO",
					LogLine:    msg,
				}
				if r.taskbar != nil {
					r.taskbar.SetProgress(uint64(p), 100, TBPF_NORMAL)
				}
			},
		)
		if errAud != nil {
			return "", fmt.Errorf("外部音声処理エラー: %w", errAud)
		}
		report.Commands = append(report.Commands, cmdLogs...)
		tempAudioM4a = m4a
		defer os.Remove(tempAudioM4a)

		// Rebuild args with the generated temp audio file
		args, _, _ = r.buildGeneralArgs(item, s, outPath, tempAudioM4a)
	}

	report.Commands = append(report.Commands, fmt.Sprintf("[FFmpeg 映像エンコード] \"%s\" %s", r.cfg.Tools.FfmpegPath, strings.Join(args, " ")))

	// Run FFmpeg
	avgFPS, avgSpeed, totalFrames, rawStderr, err := r.executeFFmpegProcess(ctx, r.cfg.Tools.FfmpegPath, args, item, qIdx, qTotal, s.CPULimit, outPath, progressChan)
	report.EndTime = time.Now()
	report.Duration = report.EndTime.Sub(startTime)
	report.AvgFPS = avgFPS
	report.AvgSpeed = avgSpeed
	report.TotalFrames = totalFrames
	report.RawStderr = rawStderr

	if err != nil {
		report.Success = false
		report.ErrorMessage = err.Error()
		r.writeDetailedEncodeLog(report)

		// HW Error fallback check
		if s.HwDecoder != "none" && core.IsHardwareError(err.Error()) {
			progressChan <- core.ProgressUpdate{
				LogLevel: "WARN",
				LogLine:  "HWアクセラレーション初期化エラーを検出。CPUフォールバックで再試行します...",
			}
			fallbackSettings := s
			fallbackSettings.HwDecoder = "none"
			fallbackSettings.HwEncoder = "CPU"
			fallbackSettings.VideoCodec = "libx264"
			return r.encodeGeneral(ctx, item, qIdx, qTotal, fallbackSettings, outDir, progressChan)
		}
		return "", err
	}

	report.Success = true

	// Post-processing: Metadata with ExifTool
	if s.Metadata == core.MetadataExifTool && r.cfg.Tools.ExifToolPath != "" {
		_ = core.CopyMetadataWithExifTool(r.cfg.Tools.ExifToolPath, item.Path, outPath)
	}

	// Write complete rich encode log
	r.writeDetailedEncodeLog(report)

	return outPath, nil
}

// encodeExternalAudioRestricted executes the audio pipeline strictly bound to CPU restrictions.
func (r *Runner) encodeExternalAudioRestricted(
	ctx context.Context,
	ffmpegPath, encoderPath, encoderType, preset, customVal, inputVideo, tempDir, restriction string,
	onProgress core.AudioProgressCallback,
) (string, []string, error) {
	if tempDir == "" {
		tempDir = os.TempDir()
	}

	var cmdLogs []string
	wavFile := filepath.Join(tempDir, fmt.Sprintf("temp_audio_%d.wav", os.Getpid()))
	m4aFile := filepath.Join(tempDir, fmt.Sprintf("temp_audio_%d.m4a", os.Getpid()))

	if onProgress != nil {
		onProgress(5.0, fmt.Sprintf("一時WAV音声を抽出中: %s", filepath.Base(inputVideo)))
	}

	// Step 1: Extract temporary WAV using StartProcessRestricted
	wavArgs := []string{"-hide_banner", "-y", "-i", inputVideo, "-vn", "-map_chapters", "-1", "-map_metadata", "-1", "-f", "wav", wavFile}
	cmdLogs = append(cmdLogs, fmt.Sprintf("[Step 1: WAV抽出] \"%s\" %s", ffmpegPath, strings.Join(wavArgs, " ")))

	wavProc, err := StartProcessRestricted(ffmpegPath, wavArgs, nil, "", restriction, r.coreInfo)
	if err != nil {
		return "", nil, fmt.Errorf("一時WAV抽出プロセスの起動に失敗: %w", err)
	}
	r.mu.Lock()
	r.curProc = wavProc
	r.mu.Unlock()

	doneChan := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = wavProc.Kill()
		case <-doneChan:
		}
	}()

	_, _ = wavProc.Wait()
	close(doneChan)
	wavProc.Close()

	r.mu.Lock()
	r.curProc = nil
	r.mu.Unlock()

	if ctx.Err() != nil {
		return "", nil, ctx.Err()
	}
	defer os.Remove(wavFile)

	if onProgress != nil {
		onProgress(15.0, fmt.Sprintf("外部音声エンコーダ (%s) を開始します...", encoderType))
	}

	// Step 2: Encode with external tool using StartProcessRestricted
	audArgs := core.BuildExternalAudioArgs(encoderType, preset, customVal, wavFile, m4aFile)
	cmdLogs = append(cmdLogs, fmt.Sprintf("[Step 2: 外部音声エンコード] \"%s\" %s", encoderPath, strings.Join(audArgs, " ")))

	audProc, err := StartProcessRestricted(encoderPath, audArgs, nil, "", restriction, r.coreInfo)
	if err != nil {
		return "", nil, fmt.Errorf("外部音声エンコーダプロセスの起動に失敗: %w", err)
	}

	r.mu.Lock()
	r.curProc = audProc
	r.mu.Unlock()

	audDoneChan := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = audProc.Kill()
		case <-audDoneChan:
		}
	}()

	// Monitor progress
	go func() {
		scanner := bufio.NewScanner(audProc.StderrReader)
		splitFunc := func(data []byte, atEOF bool) (advance int, token []byte, err error) {
			if atEOF && len(data) == 0 {
				return 0, nil, nil
			}
			for i, b := range data {
				if b == '\n' || b == '\r' {
					return i + 1, data[:i], nil
				}
			}
			if atEOF {
				return len(data), data, nil
			}
			return 0, nil, nil
		}
		scanner.Split(splitFunc)

		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" {
				continue
			}
			if onProgress != nil {
				if strings.Contains(line, "%") {
					onProgress(50.0, fmt.Sprintf("[%s 音声変換中] %s", encoderType, line))
				}
			}
		}
	}()

	_, _ = audProc.Wait()
	close(audDoneChan)
	audProc.Close()

	r.mu.Lock()
	r.curProc = nil
	r.mu.Unlock()

	if ctx.Err() != nil {
		return "", nil, ctx.Err()
	}

	if fi, errStat := os.Stat(m4aFile); errStat != nil || fi.Size() == 0 {
		if onProgress != nil {
			onProgress(50.0, "外部音声エンコード失敗。内蔵AACにフォールバックします...")
		}
		// Fallback to internal AAC
		fbArgs := []string{"-hide_banner", "-y", "-i", wavFile, "-c:a", "aac", "-b:a", "192k", m4aFile}
		cmdLogs = append(cmdLogs, fmt.Sprintf("[Step 3: 内蔵AACフォールバック] \"%s\" %s", ffmpegPath, strings.Join(fbArgs, " ")))

		fbProc, errFb := StartProcessRestricted(ffmpegPath, fbArgs, nil, "", restriction, r.coreInfo)
		if errFb != nil {
			return "", nil, fmt.Errorf("内蔵AACフォールバックの起動に失敗: %w", errFb)
		}
		_, _ = fbProc.Wait()
		fbProc.Close()
	}

	if onProgress != nil {
		onProgress(100.0, fmt.Sprintf("外部音声エンコード完了 (%s)", encoderType))
	}

	return m4aFile, cmdLogs, nil
}

// encodePlatform handles execution of Platform upload mode.
func (r *Runner) encodePlatform(
	ctx context.Context,
	item *core.QueueItem,
	qIdx, qTotal int,
	s core.PlatformSettings,
	outDir string,
	progressChan chan<- core.ProgressUpdate,
) (string, error) {
	startTime := time.Now()
	preset := core.FindPlatformPreset(s.SelectedPlatform)
	targetMaxMB := preset.MaxFileSizeMB
	if s.SelectedPlatform == "custom" && s.CustomMaxMB > 0 {
		targetMaxMB = s.CustomMaxMB
	}

	baseName := strings.TrimSuffix(item.FileName, filepath.Ext(item.FileName))
	ext := "mp4"
	outPath, err := r.resolveDestinationFile(outDir, baseName, ext, core.OverwriteSkip)
	if err != nil {
		return "", err
	}

	audioBitrate := preset.AudioBitrateKbps
	if audioBitrate <= 0 {
		audioBitrate = 128
	}

	targetVBR := core.CalculateTargetBitrate(targetMaxMB, item.Info.DurationSec, int64(audioBitrate))

	codec := preset.DefaultCodec
	if codec == "" {
		codec = "libx264"
	}

	args := []string{"-hide_banner", "-y", "-i", item.Path}

	if preset.TargetMaxHeight > 0 && item.Info.Height > preset.TargetMaxHeight {
		args = append(args, "-vf", fmt.Sprintf("scale=-2:%d", preset.TargetMaxHeight))
	}

	args = append(args, "-c:v", codec)

	if !preset.NoMaxRate && targetVBR > 0 {
		args = append(args, "-b:v", fmt.Sprintf("%dk", targetVBR))
		args = append(args, "-maxrate", fmt.Sprintf("%dk", targetVBR))
		args = append(args, "-bufsize", fmt.Sprintf("%dk", targetVBR*2))
	} else {
		args = append(args, "-crf", "18")
	}

	if preset.MaxFPS > 0 && item.Info.FPS > float64(preset.MaxFPS) {
		args = append(args, "-r", strconv.Itoa(preset.MaxFPS))
	}

	// Audio options
	args = append(args, "-c:a", "aac", "-b:a", fmt.Sprintf("%dk", audioBitrate))

	// DASH PTS fix if needed
	if core.NeedsGenPTS(item.Info.FormatName) {
		args = append([]string{"-fflags", "+genpts"}, args...)
	}

	args = append(args, "-progress", "pipe:1", outPath)

	report := EncodeReport{
		StartTime:    startTime,
		Item:         item,
		OutPath:      outPath,
		ModeName:     fmt.Sprintf("プラットフォーム (%s)", preset.Name),
		HwDecoder:    "none",
		HwEncoder:    "CPU",
		VideoCodec:   codec,
		QualityStr:   fmt.Sprintf("Target %dkbps", targetVBR),
		SpeedPreset:  "medium",
		AudioEncoder: "aac",
		Deinterlace:  "none",
		CPULimit:     "All",
		Commands:     []string{fmt.Sprintf("[FFmpeg 映像エンコード] \"%s\" %s", r.cfg.Tools.FfmpegPath, strings.Join(args, " "))},
	}

	avgFPS, avgSpeed, totalFrames, rawStderr, err := r.executeFFmpegProcess(ctx, r.cfg.Tools.FfmpegPath, args, item, qIdx, qTotal, core.CPURestrictionAll, outPath, progressChan)
	report.EndTime = time.Now()
	report.Duration = report.EndTime.Sub(startTime)
	report.AvgFPS = avgFPS
	report.AvgSpeed = avgSpeed
	report.TotalFrames = totalFrames
	report.RawStderr = rawStderr

	if err != nil {
		report.Success = false
		report.ErrorMessage = err.Error()
		r.writeDetailedEncodeLog(report)
		return "", err
	}

	report.Success = true
	r.writeDetailedEncodeLog(report)

	// Check size limit warning
	fi, _ := os.Stat(outPath)
	if fi != nil && core.IsOverTargetSize(fi.Size(), targetMaxMB) {
		actualMB := float64(fi.Size()) / (1024 * 1024)
		progressChan <- core.ProgressUpdate{
			LogLevel: "WARN",
			LogLine:  fmt.Sprintf("⚠ [WARN] ファイルサイズ上限超過: %.2f MB > 目標 %.2f MB", actualMB, targetMaxMB),
		}
	}

	return outPath, nil
}

// encodeIntermediate handles execution of Intermediate format mode.
func (r *Runner) encodeIntermediate(
	ctx context.Context,
	item *core.QueueItem,
	qIdx, qTotal int,
	s core.IntermediateSettings,
	outDir string,
	progressChan chan<- core.ProgressUpdate,
) (string, error) {
	startTime := time.Now()
	baseName := strings.TrimSuffix(item.FileName, filepath.Ext(item.FileName))
	ext := s.OutputExt
	if ext == "" {
		ext = "mkv"
	}

	outPath, err := r.resolveDestinationFile(outDir, baseName, ext, core.OverwriteSkip)
	if err != nil {
		return "", err
	}

	args := []string{"-hide_banner", "-y", "-i", item.Path}

	switch s.Format {
	case "prores_hq":
		args = append(args, "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le")
	case "dnxhr_hqx":
		args = append(args, "-c:v", "dnxhd", "-profile:v", "dnxhr_hqx", "-pix_fmt", "yuv422p10le")
	case "ffv1":
		args = append(args, "-c:v", "ffv1", "-level", "3", "-pix_fmt", "yuv444p")
	default:
		args = append(args, "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le")
	}

	switch s.AudioFormat {
	case "pcm24":
		args = append(args, "-c:a", "pcm_s24le")
	case "flac":
		args = append(args, "-c:a", "flac", "-compression_level", "8")
	default:
		args = append(args, "-c:a", "pcm_s24le")
	}

	args = append(args, "-progress", "pipe:1", outPath)

	report := EncodeReport{
		StartTime:    startTime,
		Item:         item,
		OutPath:      outPath,
		ModeName:     "中間ファイル (Intermediate)",
		HwDecoder:    "none",
		HwEncoder:    "CPU",
		VideoCodec:   s.Format,
		QualityStr:   "Lossless / HQ",
		SpeedPreset:  "-",
		AudioEncoder: s.AudioFormat,
		Deinterlace:  "none",
		CPULimit:     "All",
		Commands:     []string{fmt.Sprintf("[FFmpeg 映像エンコード] \"%s\" %s", r.cfg.Tools.FfmpegPath, strings.Join(args, " "))},
	}

	avgFPS, avgSpeed, totalFrames, rawStderr, err := r.executeFFmpegProcess(ctx, r.cfg.Tools.FfmpegPath, args, item, qIdx, qTotal, core.CPURestrictionAll, outPath, progressChan)
	report.EndTime = time.Now()
	report.Duration = report.EndTime.Sub(startTime)
	report.AvgFPS = avgFPS
	report.AvgSpeed = avgSpeed
	report.TotalFrames = totalFrames
	report.RawStderr = rawStderr

	if err != nil {
		report.Success = false
		report.ErrorMessage = err.Error()
		r.writeDetailedEncodeLog(report)
		return "", err
	}

	report.Success = true
	r.writeDetailedEncodeLog(report)

	return outPath, nil
}

// encodeSplit handles execution of Split segment mode.
func (r *Runner) encodeSplit(
	ctx context.Context,
	item *core.QueueItem,
	qIdx, qTotal int,
	s core.SplitSettings,
	genSettings core.GeneralSettings,
	outDir string,
	progressChan chan<- core.ProgressUpdate,
) (string, error) {
	segments := item.Segments
	if len(segments) == 0 {
		if s.SplitSource == "srt" {
			srtFile := s.SRTPath
			if srtFile == "" {
				srtFile = core.FindMatchingSRT(item.Path)
			}
			if srtFile != "" {
				parsed, err := core.ParseSRT(srtFile)
				if err == nil {
					segments = parsed
				}
			}
		} else {
			parsed, err := core.ExtractChapters(r.cfg.Tools.FfprobePath, item.Path)
			if err == nil {
				segments = parsed
			}
		}
	}

	if len(segments) == 0 {
		return "", fmt.Errorf("分割マーカー（チャプターまたは字幕）が検出されませんでした")
	}

	baseName := strings.TrimSuffix(item.FileName, filepath.Ext(item.FileName))
	ext := s.OutputExt
	if ext == "" {
		ext = "mp4"
	}

	var firstOutput string
	for segIdx, ch := range segments {
		select {
		case <-ctx.Done():
			return "", fmt.Errorf("分割エンコードが中断されました")
		default:
		}

		segFileName := core.BuildSegmentOutputName(baseName, ch, s.NamingRule, ext)
		segOutPath := filepath.Join(outDir, segFileName)
		if firstOutput == "" {
			firstOutput = segOutPath
		}

		progressChan <- core.ProgressUpdate{
			LogLevel: "INFO",
			LogLine:  fmt.Sprintf("セグメント [%d/%d] エンコード: %s (%.1fs ~ %.1fs)", segIdx+1, len(segments), segFileName, ch.StartSec, ch.EndSec),
		}

		args := []string{"-hide_banner", "-y", "-ss", fmt.Sprintf("%.3f", ch.StartSec), "-to", fmt.Sprintf("%.3f", ch.EndSec), "-i", item.Path}
		args = append(args, "-c:v", "libx264", "-crf", "20", "-preset", "medium")
		args = append(args, "-c:a", "aac", "-b:a", "192k")
		args = append(args, "-progress", "pipe:1", segOutPath)

		_, _, _, _, err := r.executeFFmpegProcess(ctx, r.cfg.Tools.FfmpegPath, args, item, qIdx, qTotal, core.CPURestrictionAll, segOutPath, progressChan)
		if err != nil {
			return "", fmt.Errorf("セグメント %s のエンコードに失敗: %w", segFileName, err)
		}
	}

	return firstOutput, nil
}

func (r *Runner) buildGeneralArgs(item *core.QueueItem, s core.GeneralSettings, outPath string, tempAudioM4a string) ([]string, bool, error) {
	args := []string{"-hide_banner", "-y"}

	// CPU Restriction thread count optimization
	if s.CPULimit == core.CPURestrictionECore {
		eCores := bits.OnesCount64(uint64(r.coreInfo.ECoreMask))
		if eCores > 0 {
			args = append(args, "-threads", strconv.Itoa(eCores))
		}
	} else if s.CPULimit == core.CPURestrictionPCore {
		pCores := bits.OnesCount64(uint64(r.coreInfo.PCoreMask))
		if pCores > 0 {
			args = append(args, "-threads", strconv.Itoa(pCores))
		}
	}

	// DASH PTS flag
	if core.NeedsGenPTS(item.Info.FormatName) {
		args = append(args, "-fflags", "+genpts")
	}

	// Cut start (-ss before -i for fast seek)
	cutStart := core.ParseCutTime(s.CutStart)
	if cutStart != "" {
		args = append(args, "-ss", cutStart)
	}

	// Hardware decoding arguments
	hwArgs := core.GetHwAccelArgs(s.HwDecoder)
	if len(hwArgs) > 0 {
		args = append(args, hwArgs...)
	}

	if core.NeedsExtraHwFrames(s.HwDecoder, s.HwEncoder) {
		args = append(args, "-extra_hw_frames", "64")
	}

	// Input file
	args = append(args, "-i", item.Path)

	if tempAudioM4a != "" {
		args = append(args, "-i", tempAudioM4a)
	}

	// Cut end (-to after -i)
	cutEnd := core.ParseCutTime(s.CutEnd)
	if cutEnd != "" {
		args = append(args, "-to", cutEnd)
	}

	// Video filter building
	var vfs []string
	hasSwFilter := false

	if s.Deinterlace != core.DeinterlaceNone {
		deintFilter, err := core.BuildDeinterlaceFilter(s.Deinterlace, r.cfg.AppDir)
		if err != nil {
			return nil, false, err
		}
		if deintFilter != "" {
			vfs = append(vfs, deintFilter)
			hasSwFilter = true
		}
	}

	if s.AdditionalVF != "" {
		vfs = append(vfs, s.AdditionalVF)
		hasSwFilter = true
	}

	if core.NeedsHwDownload(s.HwDecoder, s.HwEncoder, hasSwFilter) {
		vfs = append([]string{"hwdownload,format=nv12"}, vfs...)
	}

	if len(vfs) > 0 {
		args = append(args, "-vf", strings.Join(vfs, ","))
	}

	// Video codec and quality
	args = append(args, "-c:v", s.VideoCodec)

	hw := s.HwEncoder
	codecLower := strings.ToLower(s.VideoCodec)

	if s.CustomBitrate != "" {
		if hw == "AMD" {
			args = append(args, "-rc", "vbr_peak", "-b:v", s.CustomBitrate)
		} else if hw == "NVIDIA" {
			args = append(args, "-rc", "vbr", "-b:v", s.CustomBitrate)
		} else {
			args = append(args, "-b:v", s.CustomBitrate)
		}
	} else if s.CustomQualityValue != "" {
		switch hw {
		case "NVIDIA":
			args = append(args, "-rc", "vbr", "-cq", s.CustomQualityValue)
		case "Intel":
			if strings.Contains(codecLower, "vp9") || strings.Contains(codecLower, "mjpeg") {
				args = append(args, "-q:v", s.CustomQualityValue)
			} else {
				args = append(args, "-global_quality", s.CustomQualityValue)
			}
		case "AMD":
			args = append(args, "-rc", "cqp", "-qp_i", s.CustomQualityValue, "-qp_p", s.CustomQualityValue, "-qp_b", s.CustomQualityValue)
		default: // CPU
			if strings.Contains(codecLower, "rav1e") {
				args = append(args, "-qp", s.CustomQualityValue)
			} else if strings.Contains(codecLower, "aom") || strings.Contains(codecLower, "vp") {
				args = append(args, "-crf", s.CustomQualityValue, "-b:v", "0")
			} else {
				args = append(args, "-crf", s.CustomQualityValue)
			}
		}
	} else if s.CustomCRF > 0 {
		args = append(args, "-crf", strconv.Itoa(s.CustomCRF))
	} else {
		// Standard quality presets according to HW and Codec
		switch hw {
		case "NVIDIA":
			cqMap := []string{"23", "28", "32"}
			cq := "28"
			if s.QualityIndex >= 0 && s.QualityIndex < len(cqMap) {
				cq = cqMap[s.QualityIndex]
			}
			args = append(args, "-rc", "vbr", "-cq", cq)
		case "Intel":
			if strings.Contains(codecLower, "vp9") {
				qMap := []string{"25", "30", "40"}
				q := "30"
				if s.QualityIndex >= 0 && s.QualityIndex < len(qMap) {
					q = qMap[s.QualityIndex]
				}
				args = append(args, "-q:v", q)
			} else {
				gqMap := []string{"20", "25", "30"}
				gq := "25"
				if s.QualityIndex >= 0 && s.QualityIndex < len(gqMap) {
					gq = gqMap[s.QualityIndex]
				}
				args = append(args, "-global_quality", gq)
			}
		case "AMD":
			qpMap := []string{"22", "28", "35"}
			qp := "28"
			if s.QualityIndex >= 0 && s.QualityIndex < len(qpMap) {
				qp = qpMap[s.QualityIndex]
			}
			args = append(args, "-rc", "cqp", "-qp_i", qp, "-qp_p", qp, "-qp_b", qp)
		case "Vulkan", "D3D12VA", "MF":
			brMap := []string{"8000k", "4000k"}
			br := "4000k"
			if s.QualityIndex >= 0 && s.QualityIndex < len(brMap) {
				br = brMap[s.QualityIndex]
			}
			args = append(args, "-b:v", br)
		default: // CPU
			if strings.Contains(codecLower, "svt") {
				crfMap := []string{"20", "30"}
				crf := "20"
				if s.QualityIndex >= 0 && s.QualityIndex < len(crfMap) {
					crf = crfMap[s.QualityIndex]
				}
				args = append(args, "-crf", crf)
			} else if strings.Contains(codecLower, "aom") {
				crfMap := []string{"20", "30"}
				crf := "20"
				if s.QualityIndex >= 0 && s.QualityIndex < len(crfMap) {
					crf = crfMap[s.QualityIndex]
				}
				args = append(args, "-row-mt", "1", "-tiles", "2x2", "-crf", crf, "-b:v", "0")
			} else if strings.Contains(codecLower, "rav1e") {
				qpMap := []string{"80", "120", "160"}
				qp := "120"
				if s.QualityIndex >= 0 && s.QualityIndex < len(qpMap) {
					qp = qpMap[s.QualityIndex]
				}
				args = append(args, "-tiles", "4", "-qp", qp)
			} else if strings.Contains(codecLower, "vp") {
				crfMap := []string{"30", "35"}
				crf := "30"
				if s.QualityIndex >= 0 && s.QualityIndex < len(crfMap) {
					crf = crfMap[s.QualityIndex]
				}
				args = append(args, "-crf", crf, "-b:v", "0")
			} else {
				crfMap := []string{"18", "22", "26", "30"}
				crf := "22"
				if s.QualityIndex >= 0 && s.QualityIndex < len(crfMap) {
					crf = crfMap[s.QualityIndex]
				}
				args = append(args, "-crf", crf)
			}
		}
	}

	if s.SpeedPreset != "" {
		if strings.Contains(codecLower, "vp") {
			args = append(args, "-cpu-used", s.SpeedPreset)
		} else if strings.Contains(codecLower, "rav1e") {
			args = append(args, "-speed", s.SpeedPreset)
		} else if hw == "AMD" {
			args = append(args, "-quality", s.SpeedPreset)
		} else {
			args = append(args, "-preset", s.SpeedPreset)
		}
	}

	// Audio options
	isExternalAudio := core.IsExternalAudioEncoder(s.AudioEncoder)
	if !isExternalAudio {
		internalArgs := core.BuildInternalAudioArgs(s.AudioEncoder, s.AudioPreset, s.AudioCustom)
		args = append(args, internalArgs...)
		if s.AudioEncoder == "opus" {
			mapFamily := core.GetAudioMappingFamily(r.cfg.Tools.FfprobePath, item.Path)
			if mapFamily != "" {
				args = append(args, "-mapping_family", mapFamily)
			}
		}
	} else {
		if tempAudioM4a != "" {
			args = append(args, "-map", "0:v:0?", "-map", "1:a:0?", "-c:a", "copy")
		} else {
			args = append(args, "-an")
		}
	}

	// Additional custom FFmpeg CLI flags
	if s.AdditionalArgs != "" {
		args = append(args, strings.Fields(s.AdditionalArgs)...)
	}

	// Progress to stdout pipe
	args = append(args, "-progress", "pipe:1", outPath)

	return args, isExternalAudio, nil
}

func (r *Runner) executeFFmpegProcess(
	ctx context.Context,
	ffmpegPath string,
	args []string,
	item *core.QueueItem,
	qIdx, qTotal int,
	cpuLimit core.CPURestriction,
	outPath string,
	progressChan chan<- core.ProgressUpdate,
) (float64, string, int64, []string, error) {
	// Start FFmpeg process suspended with CPU restrictions applied instantly before thread 0 executes
	proc, err := StartProcessRestricted(ffmpegPath, args, nil, "", string(cpuLimit), r.coreInfo)
	if err != nil {
		return 0, "", 0, nil, fmt.Errorf("FFmpeg プロセスの起動に失敗しました: %w", err)
	}
	defer proc.Close()

	r.mu.Lock()
	r.curProc = proc
	r.isPaused = false
	r.mu.Unlock()

	defer func() {
		r.mu.Lock()
		r.curProc = nil
		r.mu.Unlock()
	}()

	if r.taskbar != nil {
		r.taskbar.SetProgress(0, 100, TBPF_NORMAL)
	}

	progressChan <- core.ProgressUpdate{
		LogLevel: "DEBUG",
		LogLine:  fmt.Sprintf("[CMD] \"%s\" %s", ffmpegPath, strings.Join(args, " ")),
	}

	var rawStderrLogs []string
	var stderrMu sync.Mutex

	// Collect and stream stderr in real-time
	go func() {
		scanner := bufio.NewScanner(proc.StderrReader)
		for scanner.Scan() {
			line := scanner.Text()
			trimmed := strings.TrimSpace(line)
			if trimmed == "" {
				continue
			}

			stderrMu.Lock()
			rawStderrLogs = append(rawStderrLogs, line)
			stderrMu.Unlock()

			// Classify stderr severity for real-time log console
			lower := strings.ToLower(trimmed)
			level := "RAW"
			if strings.Contains(lower, "error") || strings.Contains(lower, "invalid") || strings.Contains(lower, "failed") || strings.Contains(lower, "no such") {
				level = "ERROR"
			} else if strings.Contains(lower, "warning") || strings.Contains(lower, "deprecated") {
				level = "WARN"
			} else if strings.Contains(line, "Stream #") || strings.Contains(line, "configuration:") || strings.Contains(line, "built with") || strings.HasPrefix(line, "[") {
				level = "DEBUG"
			}

			progressChan <- core.ProgressUpdate{
				LogLevel: level,
				LogLine:  trimmed,
			}
		}
	}()

	var maxFPS float64
	var lastSpeed string
	var maxFrames int64

	// Parse stdout for -progress key=value pairs
	go func() {
		scanner := bufio.NewScanner(proc.StdoutReader)
		var curMs int64
		var curFPS float64
		var curSpeed string
		var curBytes int64

		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" {
				continue
			}
			parts := strings.SplitN(line, "=", 2)
			if len(parts) != 2 {
				continue
			}
			k := strings.TrimSpace(parts[0])
			v := strings.TrimSpace(parts[1])

			switch k {
			case "frame":
				if f, err := strconv.ParseInt(v, 10, 64); err == nil {
					if f > maxFrames {
						maxFrames = f
					}
				}
			case "out_time_ms":
				if ms, err := strconv.ParseInt(v, 10, 64); err == nil {
					curMs = ms
				}
			case "fps":
				if fps, err := strconv.ParseFloat(v, 64); err == nil {
					curFPS = fps
					if fps > maxFPS {
						maxFPS = fps
					}
				}
			case "speed":
				curSpeed = v
				lastSpeed = v
			case "total_size":
				if b, err := strconv.ParseInt(v, 10, 64); err == nil {
					curBytes = b
				}
			case "progress":
				if v == "continue" || v == "end" {
					curSec := float64(curMs) / 1000000.0
					totalSec := item.Info.DurationSec
					percent := float64(0)
					if totalSec > 0 {
						percent = math.Min(100.0, math.Max(0.0, (curSec/totalSec)*100.0))
					}

					// ETA calculation
					remSec := int64(0)
					speedVal := parseSpeed(curSpeed)
					if speedVal > 0 && totalSec > curSec {
						remSec = int64((totalSec - curSec) / speedVal)
					}

					eta := time.Now().Add(time.Duration(remSec) * time.Second)

					progressChan <- core.ProgressUpdate{
						QueueIndex:   qIdx + 1,
						TotalQueue:   qTotal,
						Percent:      percent,
						CurrentSec:   curSec,
						TotalSec:     totalSec,
						Speed:        curSpeed,
						FPS:          curFPS,
						OutBytes:     curBytes,
						RemainingSec: remSec,
						ETA:          eta,
					}

					if r.taskbar != nil && !r.IsPaused() {
						r.taskbar.SetProgress(uint64(percent), 100, TBPF_NORMAL)
					}
				}
			}
		}
	}()

	// Monitor context cancellation to immediately kill ffmpeg process on Escape / abort
	doneChan := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = proc.Kill()
		case <-doneChan:
		}
	}()

	exitCode, errWait := proc.Wait()
	close(doneChan)

	stderrMu.Lock()
	finalStderr := make([]string, len(rawStderrLogs))
	copy(finalStderr, rawStderrLogs)
	stderrMu.Unlock()

	if ctx.Err() != nil {
		return 0, "", 0, finalStderr, ctx.Err()
	}

	if errWait != nil {
		return 0, "", 0, finalStderr, errWait
	}

	if exitCode != 0 {
		errOutput := strings.Join(finalStderr, "\n")
		return 0, "", 0, finalStderr, fmt.Errorf("FFmpegが終了コード %d で異常終了しました: %s", exitCode, truncateError(errOutput))
	}

	return maxFPS, lastSpeed, maxFrames, finalStderr, nil
}

func parseSpeed(speedStr string) float64 {
	trimmed := strings.TrimSuffix(strings.TrimSpace(speedStr), "x")
	val, err := strconv.ParseFloat(trimmed, 64)
	if err != nil {
		return 0
	}
	return val
}

func truncateError(errStr string) string {
	lines := strings.Split(errStr, "\n")
	if len(lines) > 6 {
		return strings.Join(lines[len(lines)-6:], "\n")
	}
	return errStr
}

// writeDetailedEncodeLog creates a rich, complete report conforming to SPECIFICATION.md.
func (r *Runner) writeDetailedEncodeLog(rep EncodeReport) {
	logPath := strings.TrimSuffix(rep.OutPath, filepath.Ext(rep.OutPath)) + "_encode.log"

	statusStr := "成功 (完了)"
	if !rep.Success {
		statusStr = fmt.Sprintf("失敗 (エラー: %s)", rep.ErrorMessage)
	}

	outSizeMB := float64(0)
	var outSizeBytes int64
	fi, errFi := os.Stat(rep.OutPath)
	if errFi == nil && fi != nil {
		outSizeBytes = fi.Size()
		outSizeMB = float64(outSizeBytes) / (1024 * 1024)
	}

	ratioStr := "-"
	if rep.Item.Info.FileSizeMB > 0 && outSizeMB > 0 {
		ratio := (outSizeMB / rep.Item.Info.FileSizeMB) * 100.0
		reduction := 100.0 - ratio
		ratioStr = fmt.Sprintf("%.2f MB (%.2f%% / 削減率 -%.2f%%)", outSizeMB, ratio, reduction)
	}

	var b strings.Builder
	b.WriteString("================================================================================\n")
	b.WriteString("  Windows-ReEncodeUtility エンコード実行ログ (v2.0 Pure Go)\n")
	b.WriteString("================================================================================\n\n")

	b.WriteString("【基本情報】\n")
	b.WriteString(fmt.Sprintf("  実行ステータス: %s\n", statusStr))
	b.WriteString(fmt.Sprintf("  開始日時      : %s\n", rep.StartTime.Format("2006-01-02 15:04:05")))
	b.WriteString(fmt.Sprintf("  終了日時      : %s\n", rep.EndTime.Format("2006-01-02 15:04:05")))
	b.WriteString(fmt.Sprintf("  所要時間      : %s (%.1f 秒)\n", rep.Duration.Round(time.Second), rep.Duration.Seconds()))
	b.WriteString("\n")

	b.WriteString("【入力ファイル情報】\n")
	b.WriteString(fmt.Sprintf("  ファイルパス  : %s\n", rep.Item.Path))
	b.WriteString(fmt.Sprintf("  ファイルサイズ: %.2f MB\n", rep.Item.Info.FileSizeMB))
	b.WriteString(fmt.Sprintf("  動画時間      : %s (%.1f 秒)\n", rep.Item.Info.DurationStr, rep.Item.Info.DurationSec))
	b.WriteString(fmt.Sprintf("  解像度 / FPS  : %dx%d @ %.2f fps\n", rep.Item.Info.Width, rep.Item.Info.Height, rep.Item.Info.FPS))
	b.WriteString(fmt.Sprintf("  映像コーデック: %s (%s)\n", rep.Item.Info.VideoCodec, rep.Item.Info.PixFmt))
	if rep.Item.Info.HasAudio {
		b.WriteString(fmt.Sprintf("  音声情報      : %s, %d Hz, %s (%d kbps)\n", rep.Item.Info.AudioCodec, rep.Item.Info.SampleRate, rep.Item.Info.ChannelLayout, rep.Item.Info.AudioBitrateKbps))
	} else {
		b.WriteString("  音声情報      : 音声なし\n")
	}
	b.WriteString("\n")

	b.WriteString("【出力ファイル情報】\n")
	b.WriteString(fmt.Sprintf("  ファイルパス  : %s\n", rep.OutPath))
	b.WriteString(fmt.Sprintf("  ファイルサイズ: %s\n", ratioStr))
	b.WriteString("\n")

	b.WriteString("【エンコード設定詳細】\n")
	b.WriteString(fmt.Sprintf("  動作モード    : %s\n", rep.ModeName))
	b.WriteString(fmt.Sprintf("  HWデコード    : %s\n", rep.HwDecoder))
	b.WriteString(fmt.Sprintf("  HWエンコーダ  : %s\n", rep.HwEncoder))
	b.WriteString(fmt.Sprintf("  映像コーデック: %s\n", rep.VideoCodec))
	b.WriteString(fmt.Sprintf("  画質設定      : %s\n", rep.QualityStr))
	b.WriteString(fmt.Sprintf("  速度プリセット: %s\n", rep.SpeedPreset))
	b.WriteString(fmt.Sprintf("  音声設定      : %s\n", rep.AudioEncoder))
	b.WriteString(fmt.Sprintf("  インターレース: %s\n", rep.Deinterlace))
	b.WriteString(fmt.Sprintf("  CPU制限       : %s [Affinity Mask: 0x%X]\n", rep.CPULimit, rep.AffinityMask))
	b.WriteString("\n")

	b.WriteString("【パフォーマンス統計】\n")
	b.WriteString(fmt.Sprintf("  平均エンコード速度: %s\n", rep.AvgSpeed))
	b.WriteString(fmt.Sprintf("  最大フレームレート: %.1f fps\n", rep.AvgFPS))
	b.WriteString(fmt.Sprintf("  総処理フレーム数  : %d frames\n", rep.TotalFrames))
	b.WriteString("\n")

	b.WriteString("【実行完全コマンドライン】\n")
	for _, cmd := range rep.Commands {
		b.WriteString(fmt.Sprintf("  %s\n", cmd))
	}
	b.WriteString("\n")

	b.WriteString("【FFmpeg / 外部ツール 生の標準エラー出力ログ (Raw Console Stderr Log)】\n")
	if len(rep.RawStderr) > 0 {
		for _, line := range rep.RawStderr {
			b.WriteString(fmt.Sprintf("  [stderr] %s\n", line))
		}
	} else {
		b.WriteString("  (標準エラー出力なし)\n")
	}
	b.WriteString("\n")

	b.WriteString("================================================================================\n")

	_ = os.WriteFile(logPath, []byte(b.String()), 0644)
}
