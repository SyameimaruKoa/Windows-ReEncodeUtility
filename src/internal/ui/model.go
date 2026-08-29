package ui

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
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
	StateTextInputDialog
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

	// Dialog / Wizard state
	dialogTitle     string
	dialogChoices   []string
	dialogValues    []string
	dialogIndex     int
	dropdownFieldID int
	videoWizardStep int // 0=none, 1=HW, 2=Codec, 3=Quality, 4=Speed
	audioWizardStep int // 0=none, 1=Encoder, 2=Quality

	// Text input state
	textInput TextInputState

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
		// Only transition to Complete/Shutdown if we were actually encoding/paused
		if m.state == StateEncoding || m.state == StatePaused {
			if m.generalSet.AfterPower != core.PowerNone && m.generalSet.AfterPower != "" && !m.hasFailedItems() {
				m.state = StateShutdownCountdown
				m.countdownSec = 60
				return m, m.tickCountdown()
			}
			m.state = StateComplete
		}
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
			for _, it := range m.queueItems {
				if it.Status == "Encoding" {
					it.Status = "Failed"
					it.ErrorMessage = "ユーザーによって中断されました"
				}
			}
			m.addLog("WARN", "ユーザー操作によりエンコードが中断されました (設定を変更して再開可能)")
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
		if key == "ctrl+enter" {
			m.startEncoding()
			return m, m.waitForProgress()
		}
		if key == "enter" {
			if m.hasFailedItems() {
				m.retryFailedItems()
				return m, m.waitForProgress()
			}
			if m.activeField == 99 {
				m.startEncoding()
				return m, m.waitForProgress()
			}
			if m.hasFailedItems() && m.focusLeft {
				m.retryFailedItems()
				return m, m.waitForProgress()
			}
			// Transition to Idle and immediately handle the Enter action (e.g. open wizard/dropdown)
			m.state = StateIdle
			return m, nil
		}
		if key == "esc" || key == "q" {
			return m, tea.Quit
		}
		// Any navigation key transitions back to Idle to allow instant re-editing of settings
		if key == "tab" || key == "up" || key == "down" || key == "left" || key == "right" || key == " " {
			m.state = StateIdle
			// Fallthrough to idle navigation
		} else {
			return m, nil
		}
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
			} else if m.activeField == 6 && m.mode == core.ModeGeneral {
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
				m.activeField = 14
			} else {
				m.activeField = 6
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
	}
}

func (m *MainModel) nextSettingField() {
	switch m.mode {
	case core.ModeGeneral:
		if !m.generalSet.ShowAdvanced {
			if m.activeField < 6 {
				m.activeField++
			} else if m.activeField == 6 {
				m.activeField = 99 // Jump to Start button
			}
		} else {
			if m.activeField < 14 {
				m.activeField++
			} else if m.activeField == 14 {
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
	case 1: // Video HW Encoder
		encoders := []string{"CPU", "NVIDIA", "Intel", "AMD", "Vulkan", "D3D12VA", "MF"}
		m.generalSet.HwEncoder = cycleString(encoders, m.generalSet.HwEncoder, dir)
	case 2: // Audio Encoder
		audioEncoders := []string{"internal_aac", "qaac", "nero", "fdkaac", "opus", "vorbis", "flac", "copy", "none"}
		m.generalSet.AudioEncoder = cycleString(audioEncoders, m.generalSet.AudioEncoder, dir)
	case 3: // HW Decoder
		decoders := []string{"none", "d3d11va", "cuda", "qsv", "dxva2", "vulkan"}
		m.generalSet.HwDecoder = cycleString(decoders, m.generalSet.HwDecoder, dir)
	case 4: // Deinterlace
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
	case 5: // Output Ext
		exts := []string{"mp4", "mkv", "mov", "webm", "ts"}
		m.generalSet.OutputExt = cycleString(exts, m.generalSet.OutputExt, dir)
	case 6: // Advanced toggle
		m.generalSet.ShowAdvanced = !m.generalSet.ShowAdvanced
	case 7: // CPU Restriction
		limits := []core.CPURestriction{core.CPURestrictionAll, core.CPURestrictionPCore, core.CPURestrictionECore, core.CPURestrictionEcoQoS}
		m.generalSet.CPULimit = cycleCPULimit(limits, m.generalSet.CPULimit, dir)
	case 8: // Overwrite
		acts := []core.OverwriteAction{core.OverwriteSkip, core.OverwriteForce, core.OverwriteAutoRename}
		m.generalSet.Overwrite = cycleOverwrite(acts, m.generalSet.Overwrite, dir)
	case 9: // TwoPass
		m.generalSet.TwoPass = !m.generalSet.TwoPass
	case 10: // Metadata
		meta := []core.MetadataMode{core.MetadataExifTool, core.MetadataFfmpeg, core.MetadataNone}
		m.generalSet.Metadata = cycleMeta(meta, m.generalSet.Metadata, dir)
	case 14: // After Power
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
	if len(m.queueItems) == 0 {
		return
	}
	hasFailed := false
	for _, it := range m.queueItems {
		if it.Status == "Failed" || it.Status == "Canceled" {
			it.Status = "Pending"
			it.ErrorMessage = ""
			hasFailed = true
		}
	}
	if !hasFailed {
		// If nothing was marked failed, re-run all
		for _, it := range m.queueItems {
			it.Status = "Pending"
			it.ErrorMessage = ""
		}
	}

	m.launchEncoding()
}

func (m *MainModel) startEncoding() {
	if len(m.queueItems) == 0 {
		return
	}

	// Reset all non-pending items to pending if re-running all
	for _, it := range m.queueItems {
		if it.Status != "Pending" {
			it.Status = "Pending"
			it.ErrorMessage = ""
		}
	}

	m.launchEncoding()
}

func (m *MainModel) launchEncoding() {
	ctx, cancel := context.WithCancel(context.Background())
	m.cancelFunc = cancel
	m.state = StateEncoding
	m.progressChan = make(chan core.ProgressUpdate, 200)

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
	m.dropdownFieldID = m.activeField
	m.dialogChoices = nil
	m.dialogValues = nil
	m.dialogIndex = 0

	switch m.mode {
	case core.ModeGeneral:
		switch m.activeField {
		case 1: // 映像設定 (HW -> Codec -> Quality -> Speed を連続で聞く)
			m.startVideoWizard()

		case 2: // 音声設定 (Encoder -> Quality を連続で聞く)
			m.startAudioWizard()

		case 3: // HW Decoder
			m.state = StateDropdownDialog
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

		case 4: // Deinterlace
			m.state = StateDropdownDialog
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

		case 5: // Ext
			m.state = StateDropdownDialog
			m.dialogTitle = "出力コンテナ形式の選択"
			options := []DropdownOption{
				{"mp4 (汎用性No.1)", "mp4"},
				{"mkv (Matroska / 字幕・多重音声対応)", "mkv"},
				{"mov (QuickTime / 編集用)", "mov"},
				{"webm (Web向け)", "webm"},
				{"ts (MPEG-2 Transport Stream)", "ts"},
			}
			m.setDropdownOptions(options, m.generalSet.OutputExt)

		case 6: // Advanced Toggle
			m.generalSet.ShowAdvanced = !m.generalSet.ShowAdvanced
			m.state = StateIdle

		case 7: // CPU Restriction
			m.state = StateDropdownDialog
			m.dialogTitle = "CPUリソース制限・優先度の選択"
			options := []DropdownOption{
				{"全コア使用 (標準)", string(core.CPURestrictionAll)},
				{"Pコアのみ使用 (性能優先 / ゲーム中等)", string(core.CPURestrictionPCore)},
				{"Eコアのみ使用 (静音・裏作業・低発熱)", string(core.CPURestrictionECore)},
				{"EcoQoS / 省電力低優先度 (Windows 11 効率モード)", string(core.CPURestrictionEcoQoS)},
			}
			m.setDropdownOptions(options, string(m.generalSet.CPULimit))

		case 8: // Overwrite
			m.state = StateDropdownDialog
			m.dialogTitle = "同名ファイル存在時の動作"
			options := []DropdownOption{
				{"スキップ (処理を飛ばす)", string(core.OverwriteSkip)},
				{"強制上書き (上書き保存)", string(core.OverwriteForce)},
				{"リネーム (末尾に_1を付与して保存)", string(core.OverwriteAutoRename)},
			}
			m.setDropdownOptions(options, string(m.generalSet.Overwrite))

		case 9: // TwoPass
			m.generalSet.TwoPass = !m.generalSet.TwoPass
			m.state = StateIdle

		case 10: // Metadata
			m.state = StateDropdownDialog
			m.dialogTitle = "メタデータ保持設定の選択"
			options := []DropdownOption{
				{"ExifTool で完全保持・復元 (推奨)", string(core.MetadataExifTool)},
				{"FFmpeg 標準コピー (-map_metadata 0)", string(core.MetadataFfmpeg)},
				{"メタデータを破棄 (-map_metadata -1)", string(core.MetadataNone)},
			}
			m.setDropdownOptions(options, string(m.generalSet.Metadata))

		case 11: // Cut
			m.state = StateDropdownDialog
			m.dialogTitle = "カット区間 (LosslessCut連携) の設定"
			options := []DropdownOption{
				{"開始時間を入力する", "set_start"},
				{"終了時間を入力する", "set_end"},
				{"LosslessCut を起動して位置を確認", "launch_lossless"},
				{"カット設定を解除 (全編エンコード)", "clear_cut"},
			}
			m.setDropdownOptions(options, "set_start")

		case 12: // Additional VF
			m.openTextInputDialog("追加ビデオフィルター (-vf) の入力", "適用するビデオフィルター文字列を入力してください (例: scale=1280:-1,fps=30):", m.generalSet.AdditionalVF, "scale=1280:-1", InputContextAdditionalVF)

		case 13: // Additional Args
			m.openTextInputDialog("追加 FFmpeg 引数の入力", "追加のコマンドライン引数を入力してください (例: -max_muxing_queue_size 1024):", m.generalSet.AdditionalArgs, "-max_muxing_queue_size 1024", InputContextAdditionalArgs)

		case 14: // After Power
			m.state = StateDropdownDialog
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

// Video Wizard implementation
func (m *MainModel) startVideoWizard() {
	m.videoWizardStep = 1
	m.openVideoHWDialog()
}

func (m *MainModel) openVideoHWDialog() {
	m.state = StateDropdownDialog
	m.dialogChoices = nil
	m.dialogValues = nil
	m.dialogIndex = 0
	m.dialogTitle = "[1/4] 映像ハードウェア (HW/SW) の選択"
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
}

func (m *MainModel) openVideoCodecDialog() {
	m.state = StateDropdownDialog
	m.dialogChoices = nil
	m.dialogValues = nil
	m.dialogIndex = 0
	m.dialogTitle = fmt.Sprintf("[2/4] %s コーデックの選択", m.generalSet.HwEncoder)
	switch m.generalSet.HwEncoder {
	case "NVIDIA":
		options := []DropdownOption{
			{"H.264 / AVC (h264_nvenc)", "h264_nvenc"},
			{"H.265 / HEVC (hevc_nvenc)", "hevc_nvenc"},
			{"AV1 (av1_nvenc)", "av1_nvenc"},
		}
		m.setDropdownOptions(options, m.generalSet.VideoCodec)
	case "Intel":
		options := []DropdownOption{
			{"H.264 / AVC (h264_qsv)", "h264_qsv"},
			{"H.265 / HEVC (hevc_qsv)", "hevc_qsv"},
			{"AV1 (av1_qsv)", "av1_qsv"},
			{"VP9 (vp9_qsv)", "vp9_qsv"},
		}
		m.setDropdownOptions(options, m.generalSet.VideoCodec)
	case "AMD":
		options := []DropdownOption{
			{"H.264 / AVC (h264_amf)", "h264_amf"},
			{"H.265 / HEVC (hevc_amf)", "hevc_amf"},
			{"AV1 (av1_amf)", "av1_amf"},
		}
		m.setDropdownOptions(options, m.generalSet.VideoCodec)
	case "Vulkan", "D3D12VA", "MF":
		options := []DropdownOption{
			{"H.264 / AVC", "h264"},
			{"H.265 / HEVC", "hevc"},
			{"AV1", "av1"},
		}
		m.setDropdownOptions(options, m.generalSet.VideoCodec)
	default: // CPU
		options := []DropdownOption{
			{"H.264 / AVC (libx264 / 互換性最優先)", "libx264"},
			{"H.265 / HEVC (libx265 / 高圧縮・高画質)", "libx265"},
			{"AV1 (libsvtav1 / 高速・高効率)", "libsvtav1"},
			{"AV1 (libaom-av1 / 最高品質・非常に低速)", "libaom-av1"},
			{"AV1 (rav1e / 中速)", "rav1e"},
			{"VP9 (libvpx-vp9 / Web・YouTube向け)", "libvpx-vp9"},
		}
		m.setDropdownOptions(options, m.generalSet.VideoCodec)
	}
}

func (m *MainModel) openVideoQualityDialog() {
	m.state = StateDropdownDialog
	m.dialogChoices = nil
	m.dialogValues = nil
	m.dialogIndex = 0

	hw := m.generalSet.HwEncoder
	codec := strings.ToLower(m.generalSet.VideoCodec)

	switch hw {
	case "NVIDIA":
		m.dialogTitle = "[3/4] NVENC 品質設定の選択"
		options := []DropdownOption{
			{"高品質 (CQ:23 / 高画質保存)", "cq_23"},
			{"中品質 (CQ:28 / 推奨バランス)", "cq_28"},
			{"高速   (CQ:32 / 容量重視)", "cq_32"},
			{"カスタム品質 (CQ値を直接数値入力)", "custom_cq"},
			{"カスタムビットレート (例: 8000k, 12M)", "custom_bitrate"},
		}
		m.setDropdownOptions(options, "cq_28")

	case "Intel":
		if strings.Contains(codec, "vp9") {
			m.dialogTitle = "[3/4] QSV VP9 品質設定の選択"
			options := []DropdownOption{
				{"高品質 (Q:25 / 高画質)", "q_25"},
				{"中品質 (Q:30 / 標準)", "q_30"},
				{"低品質 (Q:40 / 軽量)", "q_40"},
				{"カスタム品質 (Q値を直接数値入力)", "custom_q"},
				{"カスタムビットレート (例: 8000k)", "custom_bitrate"},
			}
			m.setDropdownOptions(options, "q_30")
		} else {
			m.dialogTitle = "[3/4] QSV 品質設定の選択"
			options := []DropdownOption{
				{"高品質 (GQ:20 / 高画質保存)", "gq_20"},
				{"中品質 (GQ:25 / 推奨バランス)", "gq_25"},
				{"低品質 (GQ:30 / 容量重視)", "gq_30"},
				{"カスタム品質 (GQ値を直接数値入力)", "custom_gq"},
				{"カスタムビットレート (例: 8000k, 12M)", "custom_bitrate"},
			}
			m.setDropdownOptions(options, "gq_25")
		}

	case "AMD":
		m.dialogTitle = "[3/4] AMF 品質設定の選択"
		options := []DropdownOption{
			{"高品質 (QP:22 / 高画質保存)", "qp_22"},
			{"中品質 (QP:28 / 推奨バランス)", "qp_28"},
			{"低品質 (QP:35 / 容量重視)", "qp_35"},
			{"カスタム品質 (QP値を直接数値入力)", "custom_qp"},
			{"カスタムビットレート (例: 8000k, 12M)", "custom_bitrate"},
		}
		m.setDropdownOptions(options, "qp_28")

	case "Vulkan", "D3D12VA", "MF":
		m.dialogTitle = "[3/4] ビットレート品質設定の選択"
		options := []DropdownOption{
			{"高品質 (8000 kbps)", "br_8000k"},
			{"標準品質 (4000 kbps)", "br_4000k"},
			{"カスタムビットレート (例: 6000k, 10M)", "custom_bitrate"},
		}
		m.setDropdownOptions(options, "br_4000k")

	default: // CPU
		if strings.Contains(codec, "svt") || strings.Contains(codec, "aom") {
			m.dialogTitle = "[3/4] AV1 品質設定 (CRF) の選択"
			options := []DropdownOption{
				{"高品質 (CRF 20 / 高精細)", "crf_20"},
				{"中品質 (CRF 30 / 標準バランス)", "crf_30"},
				{"カスタム品質 (CRF値を直接入力)", "custom_crf"},
				{"カスタムビットレート (例: 4000k)", "custom_bitrate"},
			}
			m.setDropdownOptions(options, "crf_20")
		} else if strings.Contains(codec, "rav1e") {
			m.dialogTitle = "[3/4] rav1e 品質設定 (QP) の選択"
			options := []DropdownOption{
				{"高品質 (QP:80 / 高画質)", "qp_80"},
				{"中品質 (QP:120 / 標準バランス)", "qp_120"},
				{"低品質 (QP:160 / 軽量)", "qp_160"},
				{"カスタム品質 (QP 0~255)", "custom_qp"},
			}
			m.setDropdownOptions(options, "qp_120")
		} else if strings.Contains(codec, "vp") {
			m.dialogTitle = "[3/4] VP9 品質設定 (CRF) の選択"
			options := []DropdownOption{
				{"高品質 (CRF 30 / 高画質)", "crf_30"},
				{"中品質 (CRF 35 / 標準バランス)", "crf_35"},
				{"カスタム品質 (CRF値を直接入力)", "custom_crf"},
			}
			m.setDropdownOptions(options, "crf_30")
		} else {
			m.dialogTitle = "[3/4] 品質設定 (CRF) の選択"
			options := []DropdownOption{
				{"最高画質 (CRF 18 / アーカイブ・保存向け)", "crf_18"},
				{"高画質   (CRF 22 / 推奨バランス)", "crf_22"},
				{"標準画質 (CRF 26 / 容量重視)", "crf_26"},
				{"低画質   (CRF 30 / プレビュー・超軽量)", "crf_30_low"},
				{"カスタム品質 (CRF 0~51 を直接入力)", "custom_crf"},
				{"カスタムビットレート (例: 5000k, 8M)", "custom_bitrate"},
			}
			m.setDropdownOptions(options, "crf_22")
		}
	}
}

func (m *MainModel) openVideoSpeedDialog() {
	m.state = StateDropdownDialog
	m.dialogChoices = nil
	m.dialogValues = nil
	m.dialogIndex = 0

	hw := m.generalSet.HwEncoder
	codec := strings.ToLower(m.generalSet.VideoCodec)

	switch hw {
	case "NVIDIA":
		m.dialogTitle = "[4/4] NVENC プリセット (速度/画質) の選択"
		options := []DropdownOption{
			{"P1 (最速 / プレビュー)", "p1"},
			{"P2", "p2"},
			{"P3", "p3"},
			{"P4 (標準 / 推奨バランス)", "p4"},
			{"P5 (高画質)", "p5"},
			{"P6 (超高画質)", "p6"},
			{"P7 (最高画質 / 低速)", "p7"},
		}
		m.setDropdownOptions(options, m.generalSet.SpeedPreset)

	case "Intel":
		m.dialogTitle = "[4/4] QSV 速度プリセットの選択"
		options := []DropdownOption{
			{"veryslow (最高品質)", "veryslow"},
			{"slower", "slower"},
			{"slow", "slow"},
			{"medium (標準バランス)", "medium"},
			{"fast", "fast"},
			{"faster", "faster"},
			{"veryfast (最速)", "veryfast"},
		}
		m.setDropdownOptions(options, m.generalSet.SpeedPreset)

	case "AMD":
		m.dialogTitle = "[4/4] AMF 速度・品質プリセットの選択"
		options := []DropdownOption{
			{"Quality (高品質)", "quality"},
			{"Balanced (標準バランス)", "balanced"},
			{"Speed (速度優先)", "speed"},
		}
		m.setDropdownOptions(options, m.generalSet.SpeedPreset)

	default: // CPU
		if strings.Contains(codec, "vp") {
			m.dialogTitle = "[4/4] VP9 cpu-used (速度) の選択"
			options := []DropdownOption{
				{"0 (最高品質 / 非常に遅い)", "0"},
				{"1 (高品質)", "1"},
				{"2", "2"},
				{"3 (バランス型)", "3"},
				{"4 (標準 / 推奨)", "4"},
				{"5 (やや速い)", "5"},
				{"6 (速い)", "6"},
				{"7 (かなり速い)", "7"},
				{"8 (最速 / 品質低下)", "8"},
			}
			m.setDropdownOptions(options, "4")
		} else if strings.Contains(codec, "rav1e") {
			m.dialogTitle = "[4/4] rav1e speed (速度) の選択"
			options := []DropdownOption{
				{"0 (最高品質 / 非常に遅い)", "0"},
				{"2 (高品質寄り)", "2"},
				{"4 (バランス型)", "4"},
				{"6 (標準 / 推奨)", "6"},
				{"8 (速い)", "8"},
				{"10 (最速)", "10"},
			}
			m.setDropdownOptions(options, "6")
		} else {
			m.dialogTitle = "[4/4] エンコード速度プリセットの選択"
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
		}
	}
}

// Audio Wizard implementation
func (m *MainModel) startAudioWizard() {
	m.audioWizardStep = 1
	m.openAudioEncoderDialog()
}

func (m *MainModel) openAudioEncoderDialog() {
	m.state = StateDropdownDialog
	m.dialogChoices = nil
	m.dialogValues = nil
	m.dialogIndex = 0
	m.dialogTitle = "[1/2] 音声エンコーダの選択"
	options := []DropdownOption{
		{"内蔵 AAC (汎用・標準)", "internal_aac"},
		{"外部 qaac (AAC 自動HE/LC / Apple最高音質)", "qaac"},
		{"外部 neroAacEnc (AAC 自動HE/LC)", "nero"},
		{"外部 fdkaac (AAC 自動HE/LC)", "fdkaac"},
		{"Opus (libopus / 高音質・省容量)", "opus"},
		{"Vorbis (libvorbis)", "vorbis"},
		{"FLAC (可逆圧縮ロスレス・完全無劣化)", "flac"},
		{"音声をそのままコピー (-c:a copy / 最速・無劣化)", "copy"},
		{"音声なし (-an / 映像のみ)", "none"},
	}
	m.setDropdownOptions(options, m.generalSet.AudioEncoder)
}

func (m *MainModel) openAudioQualitySubDialog() {
	m.state = StateDropdownDialog
	m.dialogChoices = nil
	m.dialogValues = nil
	m.dialogIndex = 0

	switch m.generalSet.AudioEncoder {
	case "qaac":
		m.dialogTitle = "[2/2] qaac 音声品質の選択 (LC=TVBR / HE=CVBR)"
		options := []DropdownOption{
			{"AAC-LC TVBR 91 (~192kbps / 高音質)", "tvbr91"},
			{"AAC-LC TVBR 73 (~160kbps / 推奨)", "tvbr73"},
			{"AAC-LC TVBR 64 (~128kbps / 標準)", "tvbr64"},
			{"HE-AAC CVBR 80kbps", "he80"},
			{"HE-AAC CVBR 64kbps", "he64"},
			{"HE-AAC CVBR 48kbps", "he48"},
			{"カスタム: AAC-LC (TVBR 0~127 品質指定)", "custom_tvbr"},
			{"カスタム: HE-AAC (CVBR kbps ビットレート指定)", "custom_cvbr"},
		}
		m.setDropdownOptions(options, m.generalSet.AudioPreset)

	case "nero":
		m.dialogTitle = "[2/2] Nero AAC 音声品質の選択 (≤-q0.40:HE / >-q0.40:LC 自動)"
		options := []DropdownOption{
			{"高品質 (-q 0.65 / AAC-LC)", "q065"},
			{"標準品質 (-q 0.50 / AAC-LC)", "q050"},
			{"通常品質 (-q 0.35 / HE-AAC 自動適用)", "q035"},
			{"低品質 (-q 0.20 / HE-AAC 自動適用)", "q020"},
			{"カスタム品質 (-q 0.0 ~ 1.0)", "custom"},
		}
		m.setDropdownOptions(options, m.generalSet.AudioPreset)

	case "fdkaac":
		m.dialogTitle = "[2/2] fdkaac 音声品質の選択 (≤VBR3:HE / ≥VBR4:LC 自動)"
		options := []DropdownOption{
			{"最高品質 (VBR 5 / AAC-LC)", "m5"},
			{"高品質   (VBR 4 / AAC-LC)", "m4"},
			{"標準品質 (VBR 3 / HE-AAC 自動適用)", "m3"},
			{"低品質   (VBR 2 / HE-AAC 自動適用)", "m2"},
			{"カスタム (VBR 1 ~ 5)", "custom"},
		}
		m.setDropdownOptions(options, m.generalSet.AudioPreset)

	case "opus":
		m.dialogTitle = "[2/2] Opus ビットレートの選択"
		options := []DropdownOption{
			{"192 kbps (最高音質)", "192k"},
			{"160 kbps (高音質)", "160k"},
			{"128 kbps (標準・推奨)", "128k"},
			{"96 kbps (軽量)", "96k"},
			{"64 kbps (低容量)", "64k"},
			{"48 kbps (超軽量)", "48k"},
			{"カスタムビットレート (例: 32k)", "custom"},
		}
		m.setDropdownOptions(options, m.generalSet.AudioPreset)

	case "vorbis":
		m.dialogTitle = "[2/2] Vorbis 品質 (-q:a) の選択"
		options := []DropdownOption{
			{"高品質 (q:a 6)", "q6"},
			{"標準品質 (q:a 4)", "q4"},
			{"カスタム品質 (-1 ~ 10)", "custom"},
		}
		m.setDropdownOptions(options, m.generalSet.AudioPreset)

	case "flac":
		m.dialogTitle = "[2/2] FLAC 圧縮レベルの選択"
		options := []DropdownOption{
			{"高圧縮 (圧縮レベル 12)", "comp12"},
			{"標準   (圧縮レベル 8)", "comp8"},
			{"高速   (圧縮レベル 5)", "comp5"},
			{"カスタム圧縮レベル (0 ~ 12)", "custom"},
		}
		m.setDropdownOptions(options, m.generalSet.AudioPreset)

	case "internal_aac":
		fallthrough
	default:
		m.dialogTitle = fmt.Sprintf("[2/2] %s ビットレートの選択", m.generalSet.AudioEncoder)
		options := []DropdownOption{
			{"320 kbps (最高音質)", "320k"},
			{"256 kbps (高音質)", "256k"},
			{"192 kbps (標準・推奨)", "192k"},
			{"128 kbps (軽量)", "128k"},
			{"96 kbps (低容量)", "96k"},
			{"64 kbps (超軽量)", "64k"},
			{"カスタムビットレート (例: 160k)", "custom"},
		}
		m.setDropdownOptions(options, m.generalSet.AudioPreset)
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

func (m *MainModel) openTextInputDialog(title, prompt, initialVal, placeholder string, ctx TextInputContext) {
	m.state = StateTextInputDialog
	m.textInput = NewTextInputState(title, prompt, initialVal, placeholder, ctx)
}

func (m *MainModel) applyTextInput() {
	val := strings.TrimSpace(m.textInput.Value)
	switch m.textInput.Context {
	case InputContextCustomQualityValue:
		m.generalSet.CustomQualityValue = val
		m.generalSet.CustomBitrate = ""
		m.generalSet.CustomCRF = 0
		if num, err := strconv.Atoi(val); err == nil {
			m.generalSet.CustomCRF = num
		}
		m.addLog("INFO", fmt.Sprintf("映像品質カスタム値を設定しました: %s", val))
		if m.videoWizardStep == 3 {
			m.videoWizardStep = 4
			m.openVideoSpeedDialog()
			return
		}

	case InputContextCustomBitrate:
		if val != "" && !strings.HasSuffix(val, "k") && !strings.HasSuffix(val, "K") && !strings.HasSuffix(val, "M") && !strings.HasSuffix(val, "m") {
			if _, err := strconv.Atoi(val); err == nil {
				val += "k"
			}
		}
		m.generalSet.CustomBitrate = val
		m.generalSet.CustomQualityValue = ""
		m.generalSet.CustomCRF = 0
		m.addLog("INFO", fmt.Sprintf("映像カスタムビットレートを設定しました: %s", val))
		if m.videoWizardStep == 3 {
			m.videoWizardStep = 4
			m.openVideoSpeedDialog()
			return
		}

	case InputContextCustomAudioVal:
		m.generalSet.AudioCustom = val
		m.addLog("INFO", fmt.Sprintf("音声カスタム品質値を設定しました: %s", val))
		if m.audioWizardStep == 2 {
			m.audioWizardStep = 0
			m.state = StateIdle
			m.addLog("INFO", "音声エンコード設定を更新しました")
			return
		}

	case InputContextCutStart:
		m.generalSet.CutStart = val
		m.addLog("INFO", fmt.Sprintf("カット開始時間を設定しました: %s", val))

	case InputContextCutEnd:
		m.generalSet.CutEnd = val
		m.addLog("INFO", fmt.Sprintf("カット終了時間を設定しました: %s", val))

	case InputContextAdditionalVF:
		m.generalSet.AdditionalVF = val
		m.addLog("INFO", fmt.Sprintf("追加ビデオフィルター (-vf) を設定しました: %s", val))

	case InputContextAdditionalArgs:
		m.generalSet.AdditionalArgs = val
		m.addLog("INFO", fmt.Sprintf("追加 FFmpeg 引数を設定しました: %s", val))

	case InputContextTemplateName:
		if val == "" {
			val = fmt.Sprintf("Template_%d", time.Now().Unix())
		}
		tmpl := &core.Template{
			Name:           val,
			Mode:           m.mode,
			HwDecoder:      m.generalSet.HwDecoder,
			HwEncoder:      m.generalSet.HwEncoder,
			VideoCodec:     m.generalSet.VideoCodec,
			SpeedPreset:    m.generalSet.SpeedPreset,
			AudioEncoder:   m.generalSet.AudioEncoder,
			AudioBitrate:   m.generalSet.AudioPreset,
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
			m.addLog("INFO", fmt.Sprintf("テンプレートを保存しました: %s", val))
		} else {
			m.addLog("ERROR", fmt.Sprintf("テンプレート保存失敗: %v", err))
		}

	case InputContextPlatformMaxMB:
		if mb, err := strconv.ParseFloat(val, 64); err == nil && mb > 0 {
			m.platformSet.CustomMaxMB = mb
			m.addLog("INFO", fmt.Sprintf("プラットフォーム目標容量を設定しました: %.1f MB", mb))
		}
	}
	m.state = StateIdle
}

func (m *MainModel) applyDropdownChoice() {
	if m.dialogIndex < 0 || m.dialogIndex >= len(m.dialogValues) {
		return
	}
	val := m.dialogValues[m.dialogIndex]

	// 1. Audio Wizard Flow
	if m.audioWizardStep == 1 {
		m.generalSet.AudioEncoder = val
		if val == "copy" || val == "none" {
			m.generalSet.AudioPreset = ""
			m.generalSet.AudioCustom = ""
			m.audioWizardStep = 0
			m.state = StateIdle
			m.addLog("INFO", fmt.Sprintf("音声設定を更新しました: %s", val))
			return
		}
		// Set default preset and advance to Step 2
		switch val {
		case "qaac":
			m.generalSet.AudioPreset = "tvbr91"
		case "nero":
			m.generalSet.AudioPreset = "q050"
		case "fdkaac":
			m.generalSet.AudioPreset = "m4"
		case "opus":
			m.generalSet.AudioPreset = "128k"
		case "vorbis":
			m.generalSet.AudioPreset = "q4"
		case "flac":
			m.generalSet.AudioPreset = "comp8"
		case "internal_aac":
			m.generalSet.AudioPreset = "192k"
		}
		m.generalSet.AudioCustom = ""
		m.audioWizardStep = 2
		m.openAudioQualitySubDialog()
		return
	} else if m.audioWizardStep == 2 {
		m.generalSet.AudioPreset = val
		if val == "custom" || val == "custom_tvbr" || val == "custom_cvbr" {
			prompt := "カスタム品質値を入力してください:"
			placeholder := "91"
			if val == "custom_tvbr" {
				prompt = "TVBR値 (0 ~ 127) を入力してください:"
				placeholder = "91"
			} else if val == "custom_cvbr" {
				prompt = "HE-AAC ビットレート (kbps, 例: 64) を入力してください:"
				placeholder = "64"
			} else if m.generalSet.AudioEncoder == "nero" {
				prompt = "Nero -q 値 (0.0 ~ 1.0) を入力してください (≤0.40は自動HE):"
				placeholder = "0.50"
			} else if m.generalSet.AudioEncoder == "fdkaac" {
				prompt = "FDK VBR 値 (1 ~ 5) を入力してください (≤3は自動HE):"
				placeholder = "4"
			} else if m.generalSet.AudioEncoder == "opus" || m.generalSet.AudioEncoder == "internal_aac" {
				prompt = "ビットレートを入力してください (例: 128k, 192k):"
				placeholder = "192k"
			} else if m.generalSet.AudioEncoder == "vorbis" {
				prompt = "Vorbis 品質値 (-1 ~ 10) を入力してください:"
				placeholder = "4"
			} else if m.generalSet.AudioEncoder == "flac" {
				prompt = "FLAC 圧縮レベル (0 ~ 12) を入力してください:"
				placeholder = "8"
			}
			m.openTextInputDialog("音声カスタム品質入力", prompt, m.generalSet.AudioCustom, placeholder, InputContextCustomAudioVal)
			return
		}
		m.audioWizardStep = 0
		m.state = StateIdle
		m.addLog("INFO", "音声エンコード設定を更新しました")
		return
	}

	// 2. Video Wizard Flow
	if m.videoWizardStep == 1 { // HW Encoder selected
		m.generalSet.HwEncoder = val
		// Set sensible default codec
		switch val {
		case "NVIDIA":
			m.generalSet.VideoCodec = "h264_nvenc"
			m.generalSet.SpeedPreset = "p4"
		case "Intel":
			m.generalSet.VideoCodec = "h264_qsv"
			m.generalSet.SpeedPreset = "medium"
		case "AMD":
			m.generalSet.VideoCodec = "h264_amf"
			m.generalSet.SpeedPreset = "balanced"
		case "Vulkan", "D3D12VA", "MF":
			m.generalSet.VideoCodec = "h264"
			m.generalSet.SpeedPreset = "medium"
		default: // CPU
			m.generalSet.VideoCodec = "libx264"
			m.generalSet.SpeedPreset = "medium"
		}
		m.videoWizardStep = 2
		m.openVideoCodecDialog()
		return
	} else if m.videoWizardStep == 2 { // Codec selected
		m.generalSet.VideoCodec = val
		m.videoWizardStep = 3
		m.openVideoQualityDialog()
		return
	} else if m.videoWizardStep == 3 { // Quality selected
		m.generalSet.CustomQualityValue = ""
		m.generalSet.CustomBitrate = ""
		m.generalSet.CustomCRF = 0

		switch val {
		case "custom_cq":
			m.openTextInputDialog("カスタム品質 (CQ) の入力", "CQ値 (例: 23, 28) を入力してください:", "", "28", InputContextCustomQualityValue)
			return
		case "custom_gq":
			m.openTextInputDialog("カスタム品質 (GQ) の入力", "GQ値 (例: 20, 25) を入力してください:", "", "25", InputContextCustomQualityValue)
			return
		case "custom_q":
			m.openTextInputDialog("カスタム品質 (Q) の入力", "Q値 (例: 25, 30) を入力してください:", "", "30", InputContextCustomQualityValue)
			return
		case "custom_qp":
			m.openTextInputDialog("カスタム品質 (QP) の入力", "QP値 (例: 22, 28, 80) を入力してください:", "", "28", InputContextCustomQualityValue)
			return
		case "custom_crf":
			m.openTextInputDialog("カスタム品質 (CRF) の入力", "CRF値 (例: 18, 22, 26) を入力してください:", "", "22", InputContextCustomQualityValue)
			return
		case "custom_bitrate":
			m.openTextInputDialog("カスタムビットレートの入力", "ビットレート (例: 8000k, 12M) を入力してください:", "", "8000k", InputContextCustomBitrate)
			return
		case "cq_23", "gq_20", "qp_22", "qp_80", "crf_18", "crf_20", "br_8000k", "q_25":
			m.generalSet.QualityIndex = 0
		case "cq_28", "gq_25", "qp_28", "qp_120", "crf_22", "crf_35", "br_4000k", "q_30":
			m.generalSet.QualityIndex = 1
		case "cq_32", "gq_30", "qp_35", "qp_160", "crf_26", "q_40":
			m.generalSet.QualityIndex = 2
		case "crf_30_low", "crf_30":
			m.generalSet.QualityIndex = 3
		}

		m.videoWizardStep = 4
		m.openVideoSpeedDialog()
		return
	} else if m.videoWizardStep == 4 { // Speed preset selected
		m.generalSet.SpeedPreset = val
		m.videoWizardStep = 0
		m.state = StateIdle
		m.addLog("INFO", "映像エンコード設定を更新しました")
		return
	}

	// 3. Other General Settings
	switch m.mode {
	case core.ModeGeneral:
		switch m.dropdownFieldID {
		case 3:
			m.generalSet.HwDecoder = val
		case 4:
			m.generalSet.Deinterlace = core.DeinterlaceMode(val)
		case 5:
			m.generalSet.OutputExt = val
		case 7:
			m.generalSet.CPULimit = core.CPURestriction(val)
		case 8:
			m.generalSet.Overwrite = core.OverwriteAction(val)
		case 10:
			m.generalSet.Metadata = core.MetadataMode(val)
		case 11:
			switch val {
			case "set_start":
				m.openTextInputDialog("カット開始時間の入力", "開始位置を入力してください (例: 00:01:15.000):", m.generalSet.CutStart, "00:00:00.000", InputContextCutStart)
				return
			case "set_end":
				m.openTextInputDialog("カット終了時間の入力", "終了位置を入力してください (例: 00:03:30.500):", m.generalSet.CutEnd, "00:00:00.000", InputContextCutEnd)
				return
			case "launch_lossless":
				if len(m.queueItems) > 0 && m.selectedQueue < len(m.queueItems) {
					targetFile := m.queueItems[m.selectedQueue].Path
					if m.cfg.Tools.LosslessCutPath != "" {
						_ = execLosslessCut(m.cfg.Tools.LosslessCutPath, targetFile)
						m.addLog("INFO", fmt.Sprintf("LosslessCut を起動しました: %s", filepath.Base(targetFile)))
					} else {
						m.addLog("WARN", "LosslessCut のパスが設定されていません")
					}
				}
			case "clear_cut":
				m.generalSet.CutStart = ""
				m.generalSet.CutEnd = ""
				m.addLog("INFO", "カット区間をクリアしました")
			}
		case 14:
			m.generalSet.AfterPower = core.PowerAction(val)
		}

	case core.ModePlatform:
		if m.dropdownFieldID == 1 {
			m.platformSet.SelectedPlatform = val
			if val == "custom" {
				m.openTextInputDialog("カスタム容量上限 (MB)", "目標ファイルサイズ (MB) を入力してください (例: 100):", "100", "MB", InputContextPlatformMaxMB)
				return
			}
		}

	case core.ModeIntermediate:
		if m.dropdownFieldID == 1 {
			m.interSet.Format = val
		} else if m.dropdownFieldID == 2 {
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
	m.state = StateIdle
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
	m.openTextInputDialog("テンプレート保存 (F5)", "保存するテンプレート名を入力してください:", fmt.Sprintf("template_%d", time.Now().Unix()), "template_name", InputContextTemplateName)
}

func (m *MainModel) handleModalKey(key string) (tea.Model, tea.Cmd) {
	if m.state == StateTextInputDialog {
		done, accepted := m.textInput.HandleKey(key)
		if done {
			if accepted {
				m.applyTextInput()
			} else {
				m.videoWizardStep = 0
				m.audioWizardStep = 0
				m.state = StateIdle
			}
		}
		return m, nil
	}

	switch key {
	case "esc":
		m.videoWizardStep = 0
		m.audioWizardStep = 0
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
					m.generalSet.AudioPreset = tmpl.AudioBitrate
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
	if m.state == StateTextInputDialog {
		return RenderTextInputModal(&m.textInput, m.width, m.height)
	}

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
