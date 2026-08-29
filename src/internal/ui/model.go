package ui

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"windows-reencode-utility/src/internal/config"
	"windows-reencode-utility/src/internal/core"
	"windows-reencode-utility/src/internal/runner"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-runewidth"
)

type UIState int

const (
	StateIdle UIState = iota
	StateEncoding
	StatePaused
	StateComplete
	StateHelpDialog
	StateContextMenuDialog
	StateLoadTemplateDialog
	StateSaveTemplateDialog
	StateShutdownCountdown
	StateDropdownDialog
)

// NamedPipeAddMsg is sent when another instance forwards video paths via Named Pipe.
type NamedPipeAddMsg struct {
	Paths []string
}

// TickMsg for background progress and timers.
type TickMsg time.Time

type ProgressMsg core.ProgressUpdate
type QueueFinishedMsg struct{}

// DropdownOption represents an item in the expanded dropdown modal.
type DropdownOption struct {
	Label string
	Value string
}

// MainModel represents the top-level Bubble Tea model.
type MainModel struct {
	cfg             *config.AppConfig
	runner          *runner.Runner
	state           UIState
	focusLeft       bool // true = left panel (queue), false = right panel (settings)
	mode            core.Mode
	width           int
	height          int
	logExpanded     bool
	logScrollOffset int

	// Queue state
	queueItems    []*core.QueueItem
	selectedQueue int

	// Mode Settings
	generalSet  core.GeneralSettings
	platformSet core.PlatformSettings
	interSet    core.IntermediateSettings
	splitSet    core.SplitSettings

	// Focus field inside right panel
	activeField int

	// Progress and Logging
	progress     core.ProgressUpdate
	logs         []LogEntry
	progressChan chan core.ProgressUpdate
	cancelFunc   context.CancelFunc

	// Dialog state
	dialogTitle     string
	dialogChoices   []string
	dialogValues    []string
	dialogIndex     int
	dropdownFieldID int

	// Shutdown countdown
	countdownSec int
}

// NewMainModel creates an initialized Bubble Tea model.
func NewMainModel(cfg *config.AppConfig, initialPaths []string) *MainModel {
	m := &MainModel{
		cfg:           cfg,
		runner:        runner.NewRunner(cfg),
		state:         StateIdle,
		focusLeft:     false,
		mode:          core.Mode(cfg.Behavior.DefaultMode),
		width:         110,
		height:        30,
		logExpanded:   false,
		selectedQueue: 0,
		activeField:   1,
		progressChan:  make(chan core.ProgressUpdate, 200),
	}

	// Initialize Default Settings
	m.generalSet = core.GeneralSettings{
		HwDecoder:    "d3d11va",
		HwEncoder:    "CPU",
		VideoCodec:   "libx264",
		QualityIndex: 1,
		SpeedPreset:  "medium",
		AudioEncoder: "internal_aac",
		AudioPreset:  "192k",
		Deinterlace:  core.DeinterlaceNone,
		OutputExt:    "mp4",
		CPULimit:     core.CPURestriction(cfg.Behavior.CPURestriction),
		Overwrite:    core.OverwriteAction(cfg.Output.OverwriteAction),
		Metadata:     core.MetadataExifTool,
		AfterPower:   core.PowerNone,
		ShowAdvanced: false,
	}

	m.platformSet = core.PlatformSettings{
		SelectedPlatform: "twitter",
		AutoSetting:      true,
		OutputExt:        "mp4",
	}

	m.interSet = core.IntermediateSettings{
		Format:      "prores_hq",
		AudioFormat: "pcm24",
		OutputExt:   "mov",
	}

	m.splitSet = core.SplitSettings{
		SplitSource: "chapter",
		NamingRule:  "text",
		OutputExt:   "mp4",
	}

	// Add initial files to queue
	if len(initialPaths) > 0 {
		m.addPathsToQueue(initialPaths)
	}

	m.addLog("INFO", "Windows-ReEncodeUtility が正常に起動しました")
	return m
}

func (m *MainModel) Init() tea.Cmd {
	return tea.Batch(
		tea.EnterAltScreen,
		tea.EnableMouseCellMotion,
	)
}

func (m *MainModel) addLog(level, message string) {
	m.logs = append(m.logs, LogEntry{
		Timestamp: time.Now(),
		Level:     level,
		Message:   message,
	})
	if len(m.logs) > 500 {
		m.logs = m.logs[len(m.logs)-500:]
	}
}

func (m *MainModel) addPathsToQueue(paths []string) {
	var expanded []string
	for _, p := range paths {
		fi, err := os.Stat(p)
		if err != nil {
			continue
		}
		if fi.IsDir() {
			files, _ := os.ReadDir(p)
			for _, f := range files {
				if !f.IsDir() {
					expanded = append(expanded, filepath.Join(p, f.Name()))
				}
			}
		} else {
			expanded = append(expanded, p)
		}
	}

	for _, p := range expanded {
		idx := len(m.queueItems) + 1
		item := &core.QueueItem{
			ID:       idx,
			Path:     p,
			FileName: filepath.Base(p),
			Status:   "Pending",
			Probing:  true,
		}
		m.queueItems = append(m.queueItems, item)

		// Asynchronously probe media info
		go func(targetItem *core.QueueItem) {
			info, err := core.ProbeMedia(m.cfg.Tools.FfprobePath, targetItem.Path)
			if err == nil {
				targetItem.Info = info
			}
			targetItem.Probing = false
		}(item)
	}
}

func (m *MainModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case NamedPipeAddMsg:
		m.addPathsToQueue(msg.Paths)
		m.addLog("INFO", fmt.Sprintf("外部から %d 件のファイルがキューに追加されました", len(msg.Paths)))
		return m, nil

	case ProgressMsg:
		m.progress = core.ProgressUpdate(msg)
		if msg.LogLine != "" {
			m.addLog(msg.LogLevel, msg.LogLine)
		}
		return m, m.waitForProgress()

	case QueueFinishedMsg:
		if m.hasFailedItems() {
			m.logExpanded = true
			for idx, it := range m.queueItems {
				if it.Status == "Failed" {
					m.selectedQueue = idx
					break
				}
			}
		}
		if m.generalSet.AfterPower != core.PowerNone && m.generalSet.AfterPower != "" && !m.hasFailedItems() {
			m.state = StateShutdownCountdown
			m.countdownSec = 60
			return m, m.tickCountdown()
		}
		m.state = StateComplete
		return m, nil

	case TickMsg:
		if m.state == StateShutdownCountdown {
			m.countdownSec--
			if m.countdownSec <= 0 {
				runner.ExecutePowerAction(m.generalSet.AfterPower)
				return m, tea.Quit
			}
			return m, m.tickCountdown()
		}
		return m, nil

	case tea.KeyMsg:
		return m.handleKeyPress(msg)
	}

	return m, nil
}

func (m *MainModel) waitForProgress() tea.Cmd {
	return func() tea.Msg {
		p, ok := <-m.progressChan
		if !ok {
			return QueueFinishedMsg{}
		}
		return ProgressMsg(p)
	}
}

func (m *MainModel) tickCountdown() tea.Cmd {
	return tea.Tick(time.Second, func(t time.Time) tea.Msg {
		return TickMsg(t)
	})
}

func (m *MainModel) handleKeyPress(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	key := msg.String()

	// Global Key Handlers
	switch key {
	case "ctrl+c":
		m.runner.Cancel()
		if m.cancelFunc != nil {
			m.cancelFunc()
		}
		return m, tea.Quit

	case "f1":
		m.openHelpDialog()
		return m, nil

	case "f2":
		m.openContextMenuDialog()
		return m, nil

	case "f3":
		m.logExpanded = !m.logExpanded
		return m, nil

	case "f4":
		m.openLoadTemplateDialog()
		return m, nil

	case "f5":
		m.openSaveTemplateDialog()
		return m, nil

	case "alt+d":
		if m.mode == core.ModeGeneral {
			m.generalSet.ShowAdvanced = !m.generalSet.ShowAdvanced
		}
		return m, nil
	}

	// Modal state handling
	if m.state == StateHelpDialog || m.state == StateContextMenuDialog ||
		m.state == StateLoadTemplateDialog || m.state == StateSaveTemplateDialog ||
		m.state == StateShutdownCountdown || m.state == StateDropdownDialog {
		return m.handleModalKey(key)
	}

	// Running / Paused state handling
	if m.state == StateEncoding || m.state == StatePaused {
		switch key {
		case " ":
			if m.state == StateEncoding {
				m.runner.Pause()
				m.state = StatePaused
				m.addLog("WARN", "エンコード処理を一時停止しました")
			} else {
				m.runner.Resume()
				m.state = StateEncoding
				m.addLog("INFO", "エンコード処理を再開しました")
			}
		case "esc":
			m.runner.Cancel()
			if m.cancelFunc != nil {
				m.cancelFunc()
			}
			m.addLog("WARN", "ユーザー操作によりエンコードが中断されました")
			m.state = StateIdle
		}
		return m, nil
	}

	// Complete state handling
	if m.state == StateComplete {
		if key == "r" || key == "R" {
			m.retryFailedItems()
			return m, m.waitForProgress()
		}
		if key == "tab" {
			m.focusLeft = !m.focusLeft
			m.state = StateIdle
			return m, nil
		}
		if key == "ctrl+enter" {
			m.startEncoding()
			return m, m.waitForProgress()
		}
		if key == "enter" {
			if m.hasFailedItems() {
				m.retryFailedItems()
				return m, m.waitForProgress()
			}
			return m, tea.Quit
		}
		if key == "esc" || key == "q" {
			return m, tea.Quit
		}
		return m, nil
	}

	// Idle navigation
	switch key {
	case "tab":
		m.focusLeft = !m.focusLeft

	case "up":
		if m.focusLeft {
			if m.selectedQueue > 0 {
				m.selectedQueue--
			}
		} else {
			m.prevSettingField()
		}

	case "down":
		if m.focusLeft {
			if m.selectedQueue < len(m.queueItems)-1 {
				m.selectedQueue++
			}
		} else {
			m.nextSettingField()
		}

	case "ctrl+up":
		if m.focusLeft && m.selectedQueue > 0 {
			m.queueItems[m.selectedQueue], m.queueItems[m.selectedQueue-1] = m.queueItems[m.selectedQueue-1], m.queueItems[m.selectedQueue]
			m.selectedQueue--
		}

	case "ctrl+down":
		if m.focusLeft && m.selectedQueue < len(m.queueItems)-1 {
			m.queueItems[m.selectedQueue], m.queueItems[m.selectedQueue+1] = m.queueItems[m.selectedQueue+1], m.queueItems[m.selectedQueue]
			m.selectedQueue++
		}

	case "delete", "backspace":
		if m.focusLeft && len(m.queueItems) > 0 {
			m.queueItems = append(m.queueItems[:m.selectedQueue], m.queueItems[m.selectedQueue+1:]...)
			if m.selectedQueue >= len(m.queueItems) && m.selectedQueue > 0 {
				m.selectedQueue--
			}
		}

	case "ctrl+enter", "alt+enter":
		if len(m.queueItems) > 0 {
			m.startEncoding()
			return m, m.waitForProgress()
		}

	case "left":
		if !m.focusLeft {
			m.cycleOptionValue(-1)
		}

	case "right":
		if !m.focusLeft {
			m.cycleOptionValue(1)
		}

	case "enter", " ":
		if !m.focusLeft {
			if m.activeField == 99 {
				// Clicked Start Encoding button
				if len(m.queueItems) > 0 {
					m.startEncoding()
					return m, m.waitForProgress()
				}
			} else if m.activeField == 0 {
				// Switch mode
				m.cycleMode(1)
			} else if m.activeField == 9 && m.mode == core.ModeGeneral {
				m.generalSet.ShowAdvanced = !m.generalSet.ShowAdvanced
			} else {
				// Open expanded dropdown choice dialog for easy selection!
				m.openDropdownDialog()
			}
		} else {
			// Start Encoding from Queue pane
			if key == "enter" && len(m.queueItems) > 0 {
				m.startEncoding()
				return m, m.waitForProgress()
			}
		}

	case "esc", "q":
		return m, tea.Quit
	}

	return m, nil
}

func (m *MainModel) cycleMode(dir int) {
	modes := []core.Mode{core.ModeGeneral, core.ModePlatform, core.ModeIntermediate, core.ModeSplit}
	for i, md := range modes {
		if md == m.mode {
			next := (i + dir + len(modes)) % len(modes)
			m.mode = modes[next]
			return
		}
	}
	m.mode = core.ModeGeneral
}

func (m *MainModel) prevSettingField() {
	if m.activeField == 99 {
		// Return from Start button to last active field
		if m.mode == core.ModeGeneral {
			if m.generalSet.ShowAdvanced {
				m.activeField = 18
			} else {
				m.activeField = 9
			}
		} else if m.mode == core.ModePlatform {
			m.activeField = 2
		} else if m.mode == core.ModeIntermediate {
			m.activeField = 3
		} else if m.mode == core.ModeSplit {
			m.activeField = 3
		}
		return
	}

	if m.activeField > 0 {
		m.activeField--
		// Skip AV1 engine if not AV1
		if m.activeField == 11 && !strings.Contains(strings.ToLower(m.generalSet.VideoCodec), "av1") {
			m.activeField = 10
		}
	}
}

func (m *MainModel) nextSettingField() {
	isAV1 := strings.Contains(strings.ToLower(m.generalSet.VideoCodec), "av1")

	switch m.mode {
	case core.ModeGeneral:
		if !m.generalSet.ShowAdvanced {
			if m.activeField < 9 {
				m.activeField++
			} else if m.activeField == 9 {
				m.activeField = 99 // Jump to Start button
			}
		} else {
			if m.activeField < 18 {
				m.activeField++
				// Skip AV1 engine if not AV1
				if m.activeField == 11 && !isAV1 {
					m.activeField = 12
				}
			} else if m.activeField == 18 {
				m.activeField = 99 // Jump to Start button
			}
		}

	case core.ModePlatform:
		if m.activeField < 2 {
			m.activeField++
		} else if m.activeField == 2 {
			m.activeField = 99
		}

	case core.ModeIntermediate:
		if m.activeField < 3 {
			m.activeField++
		} else if m.activeField == 3 {
			m.activeField = 99
		}

	case core.ModeSplit:
		if m.activeField < 3 {
			m.activeField++
		} else if m.activeField == 3 {
			m.activeField = 99
		}
	}
}

func (m *MainModel) cycleOptionValue(dir int) {
	switch m.mode {
	case core.ModeGeneral:
		m.cycleGeneralField(dir)
	case core.ModePlatform:
		m.cyclePlatformField(dir)
	case core.ModeIntermediate:
		m.cycleIntermediateField(dir)
	case core.ModeSplit:
		m.cycleSplitField(dir)
	}
}

func (m *MainModel) cycleGeneralField(dir int) {
	switch m.activeField {
	case 0:
		m.cycleMode(dir)
	case 1: // HW Decoder
		decoders := []string{"none", "d3d11va", "cuda", "qsv", "dxva2", "vulkan"}
		m.generalSet.HwDecoder = cycleString(decoders, m.generalSet.HwDecoder, dir)
	case 2: // HW Encoder
		encoders := []string{"CPU", "NVIDIA", "Intel", "AMD", "Vulkan", "D3D12VA", "MF"}
		m.generalSet.HwEncoder = cycleString(encoders, m.generalSet.HwEncoder, dir)
	case 3: // Video Codec
		codecs := []string{"libx264", "libx265", "libsvtav1", "libvpx-vp9"}
		m.generalSet.VideoCodec = cycleString(codecs, m.generalSet.VideoCodec, dir)
	case 4: // Quality
		m.generalSet.QualityIndex = (m.generalSet.QualityIndex + dir + 4) % 4
	case 5: // Speed Preset
		speeds := []string{"ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"}
		m.generalSet.SpeedPreset = cycleString(speeds, m.generalSet.SpeedPreset, dir)
	case 6: // Audio Encoder
		audioEncoders := []string{"copy", "internal_aac", "qaac", "nero", "fdkaac", "opus", "vorbis", "flac", "none"}
		m.generalSet.AudioEncoder = cycleString(audioEncoders, m.generalSet.AudioEncoder, dir)
	case 7: // Deinterlace
		deints := []core.DeinterlaceMode{
			core.DeinterlaceNone,
			core.DeinterlaceAuto,
			core.DeinterlaceBwdif,
			core.DeinterlaceYadif,
			core.DeinterlaceW3fdif,
			core.DeinterlaceNnedi,
			core.DeinterlaceFieldmatchDecimate,
			core.DeinterlaceFieldmatchNnediDecimate,
		}
		m.generalSet.Deinterlace = cycleDeint(deints, m.generalSet.Deinterlace, dir)
	case 8: // Output Ext
		exts := []string{"mp4", "mkv", "mov", "webm", "ts"}
		m.generalSet.OutputExt = cycleString(exts, m.generalSet.OutputExt, dir)
	case 10: // CPU Restriction
		limits := []core.CPURestriction{core.CPURestrictionAll, core.CPURestrictionPCore, core.CPURestrictionECore, core.CPURestrictionEcoQoS}
		m.generalSet.CPULimit = cycleCPULimit(limits, m.generalSet.CPULimit, dir)
	case 11: // AV1 Engine
		engines := []string{"svt-av1", "aom-av1", "rav1e"}
		m.generalSet.AV1Engine = cycleString(engines, m.generalSet.AV1Engine, dir)
	case 12: // Overwrite
		acts := []core.OverwriteAction{core.OverwriteSkip, core.OverwriteForce, core.OverwriteAutoRename}
		m.generalSet.Overwrite = cycleOverwrite(acts, m.generalSet.Overwrite, dir)
	case 13: // TwoPass
		m.generalSet.TwoPass = !m.generalSet.TwoPass
	case 14: // Metadata
		meta := []core.MetadataMode{core.MetadataExifTool, core.MetadataFfmpeg, core.MetadataNone}
		m.generalSet.Metadata = cycleMeta(meta, m.generalSet.Metadata, dir)
	case 18: // After Power
		powers := []core.PowerAction{core.PowerNone, core.PowerShutdown, core.PowerReboot, core.PowerSleep}
		m.generalSet.AfterPower = cyclePower(powers, m.generalSet.AfterPower, dir)
	}
}

func (m *MainModel) cyclePlatformField(dir int) {
	switch m.activeField {
	case 0:
		m.cycleMode(dir)
	case 1:
		keys := []string{"twitter", "discord", "catbox", "uguu", "github", "release", "custom"}
		m.platformSet.SelectedPlatform = cycleString(keys, m.platformSet.SelectedPlatform, dir)
	case 2:
		m.platformSet.AutoSetting = !m.platformSet.AutoSetting
	}
}

func (m *MainModel) cycleIntermediateField(dir int) {
	switch m.activeField {
	case 0:
		m.cycleMode(dir)
	case 1:
		fmts := []string{"prores_hq", "dnxhr_hqx", "ffv1"}
		m.interSet.Format = cycleString(fmts, m.interSet.Format, dir)
	case 2:
		auds := []string{"pcm24", "flac"}
		m.interSet.AudioFormat = cycleString(auds, m.interSet.AudioFormat, dir)
	case 3:
		exts := []string{"mov", "mkv", "avi"}
		m.interSet.OutputExt = cycleString(exts, m.interSet.OutputExt, dir)
	}
}

func (m *MainModel) cycleSplitField(dir int) {
	switch m.activeField {
	case 0:
		m.cycleMode(dir)
	case 1:
		if m.splitSet.SplitSource == "chapter" {
			m.splitSet.SplitSource = "srt"
		} else {
			m.splitSet.SplitSource = "chapter"
		}
	case 2:
		if m.splitSet.NamingRule == "text" {
			m.splitSet.NamingRule = "index"
		} else {
			m.splitSet.NamingRule = "text"
		}
	case 3:
		exts := []string{"mp4", "mkv", "mov", "ts"}
		m.splitSet.OutputExt = cycleString(exts, m.splitSet.OutputExt, dir)
	}
}

func cycleString(list []string, current string, dir int) string {
	for i, v := range list {
		if v == current {
			next := (i + dir + len(list)) % len(list)
			return list[next]
		}
	}
	if len(list) > 0 {
		if dir < 0 {
			return list[len(list)-1]
		}
		return list[0]
	}
	return current
}

func cycleDeint(list []core.DeinterlaceMode, current core.DeinterlaceMode, dir int) core.DeinterlaceMode {
	for i, v := range list {
		if v == current {
			next := (i + dir + len(list)) % len(list)
			return list[next]
		}
	}
	if len(list) > 0 {
		if dir < 0 {
			return list[len(list)-1]
		}
		return list[0]
	}
	return current
}

func cycleCPULimit(list []core.CPURestriction, current core.CPURestriction, dir int) core.CPURestriction {
	for i, v := range list {
		if v == current {
			next := (i + dir + len(list)) % len(list)
			return list[next]
		}
	}
	if len(list) > 0 {
		if dir < 0 {
			return list[len(list)-1]
		}
		return list[0]
	}
	return current
}

func cycleOverwrite(list []core.OverwriteAction, current core.OverwriteAction, dir int) core.OverwriteAction {
	for i, v := range list {
		if v == current {
			next := (i + dir + len(list)) % len(list)
			return list[next]
		}
	}
	if len(list) > 0 {
		if dir < 0 {
			return list[len(list)-1]
		}
		return list[0]
	}
	return current
}

func cycleMeta(list []core.MetadataMode, current core.MetadataMode, dir int) core.MetadataMode {
	for i, v := range list {
		if v == current {
			next := (i + dir + len(list)) % len(list)
			return list[next]
		}
	}
	if len(list) > 0 {
		if dir < 0 {
			return list[len(list)-1]
		}
		return list[0]
	}
	return current
}

func cyclePower(list []core.PowerAction, current core.PowerAction, dir int) core.PowerAction {
	for i, v := range list {
		if v == current {
			next := (i + dir + len(list)) % len(list)
			return list[next]
		}
	}
	if len(list) > 0 {
		if dir < 0 {
			return list[len(list)-1]
		}
		return list[0]
	}
	return current
}

func (m *MainModel) hasFailedItems() bool {
	for _, it := range m.queueItems {
		if it.Status == "Failed" {
			return true
		}
	}
	return false
}

func (m *MainModel) retryFailedItems() {
	for _, it := range m.queueItems {
		if it.Status == "Failed" {
			it.Status = "Pending"
			it.ErrorMessage = ""
		}
	}
	m.startEncoding()
}

func (m *MainModel) startEncoding() {
	if len(m.queueItems) == 0 {
		return
	}

	// Reset completed / failed items to pending if re-running
	for _, it := range m.queueItems {
		if it.Status == "Completed" || it.Status == "Failed" {
			it.Status = "Pending"
			it.ErrorMessage = ""
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	m.cancelFunc = cancel
	m.state = StateEncoding

	go m.runner.RunQueue(
		ctx,
		m.queueItems,
		m.mode,
		m.generalSet,
		m.platformSet,
		m.interSet,
		m.splitSet,
		m.progressChan,
	)
}

// Open expanded dropdown choice list for the current active field
func (m *MainModel) openDropdownDialog() {
	m.state = StateDropdownDialog
	m.dropdownFieldID = m.activeField
	m.dialogChoices = nil
	m.dialogValues = nil
	m.dialogIndex = 0

	switch m.mode {
	case core.ModeGeneral:
		switch m.activeField {
		case 1: // HW Decoder
			m.dialogTitle = "HWデコーダの選択"
			options := []DropdownOption{
				{"推奨・Windows標準 (d3d11va)", "d3d11va"},
				{"使用しない (CPUソフトウェアデコード)", "none"},
				{"NVIDIA (cuda)", "cuda"},
				{"Intel (qsv)", "qsv"},
				{"Windows汎用 (dxva2)", "dxva2"},
				{"Vulkan (vulkan)", "vulkan"},
			}
			m.setDropdownOptions(options, m.generalSet.HwDecoder)

		case 2: // HW Encoder
			m.dialogTitle = "HWエンコーダの選択"
			options := []DropdownOption{
				{"CPU (Software / 高画質・低速)", "CPU"},
				{"NVIDIA (NVENC / 高速)", "NVIDIA"},
				{"Intel (QSV / 高速)", "Intel"},
				{"AMD (AMF / 高速)", "AMD"},
				{"Vulkan", "Vulkan"},
				{"D3D12VA", "D3D12VA"},
				{"MediaFoundation (MF)", "MF"},
			}
			m.setDropdownOptions(options, m.generalSet.HwEncoder)

		case 3: // Codec
			m.dialogTitle = "映像コーデックの選択"
			options := []DropdownOption{
				{"H.264 / AVC (互換性最優先)", "libx264"},
				{"H.265 / HEVC (高圧縮・高画質)", "libx265"},
				{"AV1 (最新世代・超高圧縮)", "libsvtav1"},
				{"VP9 (Web / YouTube向け)", "libvpx-vp9"},
			}
			m.setDropdownOptions(options, m.generalSet.VideoCodec)

		case 4: // Quality
			m.dialogTitle = "品質設定 (CRF) の選択"
			options := []DropdownOption{
				{"最高画質 (CRF 18 / アーカイブ・保存向け)", "0"},
				{"高画質   (CRF 22 / 推奨バランス)", "1"},
				{"標準画質 (CRF 26 / 容量重視)", "2"},
				{"低画質   (CRF 30 / プレビュー・超軽量)", "3"},
			}
			m.setDropdownOptions(options, fmt.Sprintf("%d", m.generalSet.QualityIndex))

		case 5: // Speed
			m.dialogTitle = "エンコード速度プリセットの選択"
			options := []DropdownOption{
				{"ultrafast (最速 / プレビュー用)", "ultrafast"},
				{"superfast", "superfast"},
				{"veryfast", "veryfast"},
				{"faster", "faster"},
				{"fast", "fast"},
				{"medium (標準バランス)", "medium"},
				{"slow (高圧縮)", "slow"},
				{"slower", "slower"},
				{"veryslow (最高圧縮 / 時間重視)", "veryslow"},
			}
			m.setDropdownOptions(options, m.generalSet.SpeedPreset)

		case 6: // Audio
			m.dialogTitle = "音声設定の選択"
			options := []DropdownOption{
				{"音声をそのままコピー (-c:a copy / 最速・無劣化)", "copy"},
				{"内蔵 AAC (192kbps / 高音質・汎用)", "internal_aac"},
				{"外部 qaac (AAC-LC / 最高音質)", "qaac"},
				{"外部 neroAacEnc (AAC)", "nero"},
				{"外部 fdkaac (AAC)", "fdkaac"},
				{"Opus (libopus 128k / 高音質)", "opus"},
				{"FLAC (可逆圧縮ロスレス)", "flac"},
				{"音声なし (-an / 映像のみ)", "none"},
			}
			m.setDropdownOptions(options, m.generalSet.AudioEncoder)

		case 7: // Deinterlace
			m.dialogTitle = "インターレース解除設定の選択"
			options := []DropdownOption{
				{"行わない (スキップ / Progressive動画)", string(core.DeinterlaceNone)},
				{"自動判定する (動画を実走査して自動適用)", string(core.DeinterlaceAuto)},
				{"bwdif (標準 / 推奨 / 高品質)", string(core.DeinterlaceBwdif)},
				{"yadif (軽量 / 標準)", string(core.DeinterlaceYadif)},
				{"nnedi (ニューラルネットワーク / 最高品質)", string(core.DeinterlaceNnedi)},
				{"fieldmatch,decimate (24fpsアニメ テレシネ逆変換)", string(core.DeinterlaceFieldmatchDecimate)},
			}
			m.setDropdownOptions(options, string(m.generalSet.Deinterlace))

		case 8: // Ext
			m.dialogTitle = "出力コンテナ形式の選択"
			options := []DropdownOption{
				{"mp4 (汎用性No.1)", "mp4"},
				{"mkv (Matroska / 字幕・多重音声対応)", "mkv"},
				{"mov (QuickTime / 編集用)", "mov"},
				{"webm (Web向け)", "webm"},
				{"ts (MPEG-2 Transport Stream)", "ts"},
			}
			m.setDropdownOptions(options, m.generalSet.OutputExt)

		case 10: // CPU Restriction
			m.dialogTitle = "CPUリソース制限・優先度の選択"
			options := []DropdownOption{
				{"全コア使用 (標準)", string(core.CPURestrictionAll)},
				{"Pコアのみ使用 (性能優先 / ゲーム中等)", string(core.CPURestrictionPCore)},
				{"Eコアのみ使用 (静音・裏作業・低発熱)", string(core.CPURestrictionECore)},
				{"EcoQoS / 省電力低優先度 (Windows 11 効率モード)", string(core.CPURestrictionEcoQoS)},
			}
			m.setDropdownOptions(options, string(m.generalSet.CPULimit))

		case 12: // Overwrite
			m.dialogTitle = "同名ファイル存在時の動作"
			options := []DropdownOption{
				{"スキップ (処理を飛ばす)", string(core.OverwriteSkip)},
				{"強制上書き (上書き保存)", string(core.OverwriteForce)},
				{"リネーム (末尾に_1を付与して保存)", string(core.OverwriteAutoRename)},
			}
			m.setDropdownOptions(options, string(m.generalSet.Overwrite))

		case 18: // After Power
			m.dialogTitle = "全キュー完了後の電源動作"
			options := []DropdownOption{
				{"何もしない (そのまま待機)", string(core.PowerNone)},
				{"シャットダウン (60秒待機後自動電源OFF)", string(core.PowerShutdown)},
				{"再起動", string(core.PowerReboot)},
				{"スリープ / 休止", string(core.PowerSleep)},
			}
			m.setDropdownOptions(options, string(m.generalSet.AfterPower))

		default:
			m.state = StateIdle
		}

	case core.ModePlatform:
		if m.activeField == 1 {
			m.dialogTitle = "アップロード対象プラットフォームの選択"
			options := []DropdownOption{
				{"Twitter / X (上限 512MB / 720p / H.264)", "twitter"},
				{"Discord (上限 10MB / 自動逆算)", "discord"},
				{"catbox.moe (上限 200MB / 自動逆算)", "catbox"},
				{"uguu.se (上限 100MB / 自動逆算)", "uguu"},
				{"GitHub Release (上限 2000MB)", "release"},
				{"GitHub Issues (上限 10MB)", "github"},
				{"カスタム容量制限", "custom"},
			}
			m.setDropdownOptions(options, m.platformSet.SelectedPlatform)
		} else if m.activeField == 2 {
			m.platformSet.AutoSetting = !m.platformSet.AutoSetting
			m.state = StateIdle
		} else {
			m.state = StateIdle
		}

	case core.ModeIntermediate:
		if m.activeField == 1 {
			m.dialogTitle = "中間フォーマットの選択"
			options := []DropdownOption{
				{"ProRes 422 HQ (10-bit / 映像編集標準)", "prores_hq"},
				{"DNxHR HQX (10-bit / Avid / Premiere)", "dnxhr_hqx"},
				{"FFV1 (完全ロスレス可逆圧縮 / アーカイブ)", "ffv1"},
			}
			m.setDropdownOptions(options, m.interSet.Format)
		} else if m.activeField == 2 {
			m.dialogTitle = "音声形式の選択"
			options := []DropdownOption{
				{"PCM 24-bit (非圧縮 / スタジオ品質)", "pcm24"},
				{"FLAC (ロスレス可逆圧縮)", "flac"},
			}
			m.setDropdownOptions(options, m.interSet.AudioFormat)
		} else {
			m.state = StateIdle
		}

	case core.ModeSplit:
		if m.activeField == 1 {
			m.splitSet.SplitSource = cycleString([]string{"chapter", "srt"}, m.splitSet.SplitSource, 1)
			m.state = StateIdle
		} else if m.activeField == 2 {
			m.splitSet.NamingRule = cycleString([]string{"text", "index"}, m.splitSet.NamingRule, 1)
			m.state = StateIdle
		} else {
			m.state = StateIdle
		}
	}
}

func (m *MainModel) setDropdownOptions(options []DropdownOption, currentValue string) {
	for i, opt := range options {
		m.dialogChoices = append(m.dialogChoices, opt.Label)
		m.dialogValues = append(m.dialogValues, opt.Value)
		if opt.Value == currentValue {
			m.dialogIndex = i
		}
	}
}

func (m *MainModel) applyDropdownChoice() {
	if m.dialogIndex < 0 || m.dialogIndex >= len(m.dialogValues) {
		return
	}
	val := m.dialogValues[m.dialogIndex]

	switch m.mode {
	case core.ModeGeneral:
		switch m.dropdownFieldID {
		case 1:
			m.generalSet.HwDecoder = val
		case 2:
			m.generalSet.HwEncoder = val
		case 3:
			m.generalSet.VideoCodec = val
		case 4:
			var q int
			fmt.Sscanf(val, "%d", &q)
			m.generalSet.QualityIndex = q
		case 5:
			m.generalSet.SpeedPreset = val
		case 6:
			m.generalSet.AudioEncoder = val
		case 7:
			m.generalSet.Deinterlace = core.DeinterlaceMode(val)
		case 8:
			m.generalSet.OutputExt = val
		case 10:
			m.generalSet.CPULimit = core.CPURestriction(val)
		case 12:
			m.generalSet.Overwrite = core.OverwriteAction(val)
		case 18:
			m.generalSet.AfterPower = core.PowerAction(val)
		}

	case core.ModePlatform:
		if m.dropdownFieldID == 1 {
			m.platformSet.SelectedPlatform = val
		}

	case core.ModeIntermediate:
		if m.dropdownFieldID == 1 {
			m.interSet.Format = val
		} else if m.dropdownFieldID == 2 {
			m.interSet.AudioFormat = val
		}
	}
}

// Dialog handlers
func (m *MainModel) openHelpDialog() {
	m.state = StateHelpDialog
	m.dialogTitle = "ヘルプ / キーバインド一覧 (F1)"
	m.dialogChoices = []string{
		"Tab           : 左ペイン (キュー) と 右ペイン (設定) の切替",
		"↑ / ↓         : 項目移動 / 設定行選択",
		"← / →         : 選択肢の切り替え (前 / 次)",
		"Enter / Space : 選択肢一覧（ドロップダウン）を展開して一括選択 / エンコード開始",
		"Space         : エンコード一時停止 / 再開",
		"Del           : 選択動画をキューから削除",
		"Ctrl+↑/↓      : キュー動画の順序入れ替え",
		"Alt+D         : 詳細設定・リソース制御の展開/折りたたみ",
		"F1            : このヘルプを表示",
		"F2            : 右クリックメニュー・送る (SendTo) 連携登録",
		"F3            : インラインログコンソールの展開/折りたたみ",
		"F4            : テンプレート設定の読込",
		"F5            : 現在の設定をテンプレートとして保存",
		"Esc           : ダイアログを閉じる / エンコード中断 / 終了",
	}
	m.dialogIndex = 0
}

func (m *MainModel) openContextMenuDialog() {
	m.state = StateContextMenuDialog
	m.dialogTitle = "Windows OS 連携設定 (F2)"
	m.dialogChoices = []string{
		"右クリックメニューに登録する (HKCU レジストリ)",
		"右クリックメニューから登録解除する",
		"「送る (SendTo)」メニューに登録する",
		"「送る (SendTo)」メニューから削除する",
	}
	m.dialogIndex = 0
}

func (m *MainModel) openLoadTemplateDialog() {
	m.state = StateLoadTemplateDialog
	m.dialogTitle = "テンプレート読込 (F4)"
	list, _ := core.ListTemplates(m.cfg.TemplatesDir)
	m.dialogChoices = list
	if len(m.dialogChoices) == 0 {
		m.dialogChoices = []string{"(保存されたテンプレートはありません)"}
	}
	m.dialogIndex = 0
}

func (m *MainModel) openSaveTemplateDialog() {
	m.state = StateSaveTemplateDialog
	m.dialogTitle = "現在の設定をテンプレートとして保存 (F5)"
	m.dialogChoices = []string{
		"新規テンプレートとして保存 (ファイル名: template_custom.json)",
		"キャンセル",
	}
	m.dialogIndex = 0
}

func (m *MainModel) handleModalKey(key string) (tea.Model, tea.Cmd) {
	switch key {
	case "esc":
		m.state = StateIdle
		return m, nil

	case "up":
		if m.dialogIndex > 0 {
			m.dialogIndex--
		}

	case "down":
		if m.dialogIndex < len(m.dialogChoices)-1 {
			m.dialogIndex++
		}

	case "enter", " ":
		switch m.state {
		case StateDropdownDialog:
			m.applyDropdownChoice()
			m.state = StateIdle

		case StateHelpDialog:
			m.state = StateIdle

		case StateContextMenuDialog:
			exePath, _ := os.Executable()
			switch m.dialogIndex {
			case 0:
				err := RegisterExplorerContextMenu(exePath)
				if err == nil {
					m.addLog("INFO", "右クリックメニューに登録しました")
				} else {
					m.addLog("ERROR", fmt.Sprintf("右クリックメニュー登録失敗: %v", err))
				}
			case 1:
				err := UnregisterExplorerContextMenu()
				if err == nil {
					m.addLog("INFO", "右クリックメニューから解除しました")
				} else {
					m.addLog("ERROR", fmt.Sprintf("右クリックメニュー解除失敗: %v", err))
				}
			case 2:
				err := CreateSendToShortcut(exePath)
				if err == nil {
					m.addLog("INFO", "SendTo に登録しました")
				} else {
					m.addLog("ERROR", fmt.Sprintf("SendTo 登録失敗: %v", err))
				}
			case 3:
				err := RemoveSendToShortcut()
				if err == nil {
					m.addLog("INFO", "SendTo から削除しました")
				} else {
					m.addLog("ERROR", fmt.Sprintf("SendTo 削除失敗: %v", err))
				}
			}
			m.state = StateIdle

		case StateLoadTemplateDialog:
			if len(m.dialogChoices) > 0 && m.dialogChoices[0] != "(保存されたテンプレートはありません)" {
				selName := m.dialogChoices[m.dialogIndex]
				tmpl, err := core.LoadTemplate(m.cfg.TemplatesDir, selName)
				if err == nil {
					m.mode = tmpl.Mode
					m.generalSet.HwDecoder = tmpl.HwDecoder
					m.generalSet.HwEncoder = tmpl.HwEncoder
					m.generalSet.VideoCodec = tmpl.VideoCodec
					m.generalSet.SpeedPreset = tmpl.SpeedPreset
					m.generalSet.AudioEncoder = tmpl.AudioEncoder
					m.generalSet.Deinterlace = tmpl.Deinterlace
					m.generalSet.OutputExt = tmpl.OutputExt
					m.generalSet.TwoPass = tmpl.TwoPass
					m.generalSet.Metadata = tmpl.MetadataMode
					m.generalSet.AdditionalVF = tmpl.AdditionalVF
					m.generalSet.AdditionalArgs = tmpl.AdditionalArgs
					m.generalSet.AfterPower = tmpl.AfterPower
					m.addLog("INFO", fmt.Sprintf("テンプレート %q を読み込みました", selName))
				} else {
					m.addLog("ERROR", fmt.Sprintf("テンプレート読込失敗: %v", err))
				}
			}
			m.state = StateIdle

		case StateSaveTemplateDialog:
			if m.dialogIndex == 0 {
				tmpl := &core.Template{
					Name:           fmt.Sprintf("Template_%d", time.Now().Unix()),
					Mode:           m.mode,
					HwDecoder:      m.generalSet.HwDecoder,
					HwEncoder:      m.generalSet.HwEncoder,
					VideoCodec:     m.generalSet.VideoCodec,
					SpeedPreset:    m.generalSet.SpeedPreset,
					AudioEncoder:   m.generalSet.AudioEncoder,
					Deinterlace:    m.generalSet.Deinterlace,
					OutputExt:      m.generalSet.OutputExt,
					TwoPass:        m.generalSet.TwoPass,
					MetadataMode:   m.generalSet.Metadata,
					AdditionalVF:   m.generalSet.AdditionalVF,
					AdditionalArgs: m.generalSet.AdditionalArgs,
					AfterPower:     m.generalSet.AfterPower,
				}
				err := core.SaveTemplate(m.cfg.TemplatesDir, tmpl)
				if err == nil {
					m.addLog("INFO", fmt.Sprintf("テンプレートを保存しました: %s", tmpl.Name))
				} else {
					m.addLog("ERROR", fmt.Sprintf("テンプレート保存失敗: %v", err))
				}
			}
			m.state = StateIdle

		case StateShutdownCountdown:
			m.state = StateIdle
		}
	}
	return m, nil
}

// View combines all components and renders the entire TUI dashboard.
func (m *MainModel) View() string {
	totalW := m.width
	if totalW < 90 {
		totalW = 90
	}
	totalH := m.height
	if totalH < 26 {
		totalH = 26
	}

	// Use totalW - 1 as target layout width to guarantee no horizontal overflow in Windows Terminal
	targetW := totalW - 1

	var b strings.Builder

	// Header bar (F1-F5 links)
	headerLeftText := "┌─ Windows-ReEncodeUtility "
	headerLeft := HeaderTitleStyle.Render(headerLeftText)
	headerKeysText := " [📂 テンプレート読込 (F4)] [💾 保存 (F5)] [⚙ 連携登録 (F2)] [F1: ヘルプ] ─┐"
	headerKeys := fmt.Sprintf(" [%s] [%s] [%s] [%s] %s",
		HeaderKeyHighlight.Render("📂 テンプレート読込 (F4)"),
		HeaderKeyHighlight.Render("💾 保存 (F5)"),
		HeaderKeyHighlight.Render("⚙ 連携登録 (F2)"),
		HeaderKeyHighlight.Render("F1: ヘルプ"),
		HeaderTitleStyle.Render("─┐"),
	)

	leftLen := runewidth.StringWidth(headerLeftText)
	keysLen := runewidth.StringWidth(headerKeysText)
	dashCount := targetW - leftLen - keysLen
	if dashCount < 1 {
		// Fallback for narrow terminals
		headerKeysText = " [F4:読込] [F5:保存] [F2:連携] [F1:ヘルプ] ─┐"
		headerKeys = fmt.Sprintf(" [%s] [%s] [%s] [%s] %s",
			HeaderKeyHighlight.Render("F4:読込"),
			HeaderKeyHighlight.Render("F5:保存"),
			HeaderKeyHighlight.Render("F2:連携"),
			HeaderKeyHighlight.Render("F1:ヘルプ"),
			HeaderTitleStyle.Render("─┐"),
		)
		keysLen = runewidth.StringWidth(headerKeysText)
		dashCount = targetW - leftLen - keysLen
		if dashCount < 1 {
			dashCount = 1
		}
	}
	dashFill := HeaderTitleStyle.Render(strings.Repeat("─", dashCount))
	b.WriteString(headerLeft + dashFill + headerKeys)
	b.WriteString("\n")

	// Split Layout (Left: Queue, Right: Mode View)
	leftOuterW := 38
	if targetW >= 110 {
		leftOuterW = 44
	}
	rightOuterW := targetW - leftOuterW

	// Height calculations:
	// Header(1) + \n(1) + Progress(5) + \n(1) + Log(3 or 9) + \n(1) + Footer(1) + \n(1) = 14 (or 20)
	fixedLines := 14
	if m.logExpanded {
		fixedLines = 20
	}
	bodyOuterH := totalH - fixedLines
	if bodyOuterH < 6 {
		bodyOuterH = 6
	}

	var selectedItem *core.QueueItem
	if len(m.queueItems) > 0 && m.selectedQueue < len(m.queueItems) {
		selectedItem = m.queueItems[m.selectedQueue]
	}

	leftPane := RenderQueueView(m.queueItems, m.selectedQueue, leftOuterW, bodyOuterH, m.focusLeft)

	var rightPane string
	switch m.mode {
	case core.ModeGeneral:
		rightPane = RenderGeneralView(&m.generalSet, m.activeField, rightOuterW, bodyOuterH, !m.focusLeft)
	case core.ModePlatform:
		rightPane = RenderPlatformView(&m.platformSet, selectedItem, m.activeField, rightOuterW, bodyOuterH, !m.focusLeft)
	case core.ModeIntermediate:
		rightPane = RenderIntermediateView(&m.interSet, m.activeField, rightOuterW, bodyOuterH, !m.focusLeft)
	case core.ModeSplit:
		rightPane = RenderSplitView(&m.splitSet, selectedItem, m.activeField, rightOuterW, bodyOuterH, !m.focusLeft)
	}

	body := lipgloss.JoinHorizontal(lipgloss.Top, leftPane, rightPane)
	b.WriteString(ClampHeight(body, bodyOuterH))
	b.WriteString("\n")

	// Progress Bar
	isComplete := (m.state == StateComplete || m.state == StateShutdownCountdown)
	b.WriteString(RenderProgressView(m.progress, isComplete, targetW))
	b.WriteString("\n")

	// Log Console
	b.WriteString(RenderLogView(m.logs, m.logExpanded, targetW, m.logScrollOffset))
	b.WriteString("\n")

	// Footer
	footerStyle := lipgloss.NewStyle().
		Foreground(ColorText).
		Background(lipgloss.Color("#181825")).
		Padding(0, 1).
		Width(targetW - 2)

	footerText := "[Ctrl+Enter] エンコード開始   [Tab] キューへ   [Space/Enter] 選択肢展開   [F3/L] ログ   [Esc] 終了"
	if m.activeField == 99 {
		footerText = "[Enter / Ctrl+Enter] エンコード開始！   [Tab] キューへ   [↑] 設定へ戻る   [Esc] 終了"
	} else if m.focusLeft {
		footerText = "[Enter / Ctrl+Enter] エンコード開始   [Tab] 設定へ   [Del] 削除   [Ctrl+↑/↓] 入替   [Esc] 終了"
	}
	if m.state == StateComplete {
		if m.hasFailedItems() {
			footerText = "一部失敗あり: [R] 失敗キュー再試行   [Tab] 設定変更   [F3/L] ログ確認   [Esc] 終了"
		} else {
			footerText = "全エンコードが完了しました。[Enter/Esc] 終了   [F3/L] ログ確認"
		}
	} else if m.state == StateEncoding {
		footerText = "[Space] 一時停止   [Esc] エンコード中断   [F3/L] ログ展開/折りたたみ"
	} else if m.state == StatePaused {
		footerText = "[Space] エンコード再開   [Esc] エンコード中断   [F3/L] ログ展開/折りたたみ"
	}
	b.WriteString(footerStyle.Render(PadRightDisplay(footerText, targetW-4)))

	// Modal Overlays
	if m.state == StateHelpDialog || m.state == StateContextMenuDialog ||
		m.state == StateLoadTemplateDialog || m.state == StateSaveTemplateDialog ||
		m.state == StateShutdownCountdown || m.state == StateDropdownDialog {
		return m.renderModalOverlay(b.String())
	}

	return b.String()
}

func (m *MainModel) renderModalOverlay(baseContent string) string {
	var mb strings.Builder
	mb.WriteString(HeaderTitleStyle.Render(fmt.Sprintf("=== %s ===", m.dialogTitle)))
	mb.WriteString("\n\n")

	if m.state == StateShutdownCountdown {
		mb.WriteString(WarningTextStyle.Render(fmt.Sprintf("全エンコードが完了しました。\n%d 秒後に自動的に電源アクション (%s) を実行します。\n\n", m.countdownSec, m.generalSet.AfterPower)))
		mb.WriteString(SelectedItemStyle.Render("  [キャンセルして待機に戻る (Esc)]\n"))
	} else {
		for i, c := range m.dialogChoices {
			if i == m.dialogIndex {
				mb.WriteString(ActiveItemStyle.Render(fmt.Sprintf(" > [✓] %s ", c)))
			} else {
				mb.WriteString(NormalItemStyle.Render(fmt.Sprintf("       %s ", c)))
			}
			mb.WriteString("\n")
		}
		mb.WriteString("\n")
		mb.WriteString(MutedItemStyle.Render("[↑/↓] 選択  [Enter/Space] 決定  [Esc] キャンセルして閉じる"))
	}

	modal := ModalBoxStyle.Render(mb.String())
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, modal)
}
