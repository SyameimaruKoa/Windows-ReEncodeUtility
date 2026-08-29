package core

import "time"

// Mode represents the encoding mode.
type Mode string

const (
	ModeGeneral      Mode = "General"
	ModePlatform     Mode = "Platform"
	ModeIntermediate Mode = "Intermediate"
	ModeSplit        Mode = "Split"
)

// OverwriteAction represents behavior when destination file exists.
type OverwriteAction string

const (
	OverwriteSkip       OverwriteAction = "Skip"
	OverwriteAutoRename OverwriteAction = "AutoRename"
	OverwriteForce      OverwriteAction = "Overwrite"
)

// CPURestriction represents CPU affinity/priority settings.
type CPURestriction string

const (
	CPURestrictionAll    CPURestriction = "All"
	CPURestrictionPCore  CPURestriction = "PCore"
	CPURestrictionECore  CPURestriction = "ECore"
	CPURestrictionEcoQoS CPURestriction = "EcoQoS"
)

// PowerAction represents post-encoding power actions.
type PowerAction string

const (
	PowerNone     PowerAction = "None"
	PowerShutdown PowerAction = "Shutdown"
	PowerReboot   PowerAction = "Reboot"
	PowerSleep    PowerAction = "Sleep"
)

// MetadataMode represents metadata handling strategy.
type MetadataMode string

const (
	MetadataExifTool MetadataMode = "ExifTool"
	MetadataFfmpeg   MetadataMode = "Ffmpeg"
	MetadataNone     MetadataMode = "None"
)

// DeinterlaceMode represents deinterlacing option.
type DeinterlaceMode string

const (
	DeinterlaceNone                    DeinterlaceMode = "none"
	DeinterlaceAuto                    DeinterlaceMode = "auto"
	DeinterlaceBwdif                   DeinterlaceMode = "bwdif"
	DeinterlaceYadif                   DeinterlaceMode = "yadif"
	DeinterlaceW3fdif                  DeinterlaceMode = "w3fdif"
	DeinterlaceNnedi                   DeinterlaceMode = "nnedi"
	DeinterlaceFieldmatchDecimate      DeinterlaceMode = "fieldmatch,decimate"
	DeinterlaceFieldmatchNnediDecimate DeinterlaceMode = "fieldmatch,nnedi,decimate"
)

// QualityPreset represents video quality preset.
type QualityPreset struct {
	Label   string
	Type    string // "crf", "bitrate", "custom_crf", "custom_bitrate", "q", "cq", "qp"
	Param   string // e.g. "-crf 18"
	Value   int
	Bitrate string
}

// MediaInfo holds probed media information.
type MediaInfo struct {
	DurationSec      float64
	DurationStr      string
	FileSizeMB       float64
	BitrateKbps      int64
	FormatName       string
	HasVideo         bool
	VideoCodec       string
	VideoCodecLong   string
	Width            int
	Height           int
	FPS              float64
	PixFmt           string
	FieldOrder       string
	IsInterlaced     bool
	HasAudio         bool
	AudioCodec       string
	AudioCodecLong   string
	SampleRate       int
	Channels         int
	ChannelLayout    string
	AudioBitrateKbps int64
}

// ChapterInfo holds chapter metadata.
type ChapterInfo struct {
	ID       int
	StartSec float64
	EndSec   float64
	Title    string
}

// QueueItem represents a single file in the batch queue.
type QueueItem struct {
	ID           int
	Path         string
	FileName     string
	Info         MediaInfo
	Probing      bool
	ProbeError   string
	Status       string // "Pending", "Encoding", "Completed", "Failed", "Skipped"
	ErrorMessage string
	OutputPath   string
	Segments     []ChapterInfo
}

// HardwareInfo caches detected hardware encoders and decoders.
type HardwareInfo struct {
	MachineName       string   `json:"machine_name"`
	FfmpegSignature   string   `json:"ffmpeg_signature"`
	AvailableEncoders []string `json:"available_encoders"`
	AvailableHwAccels []string `json:"available_hwaccels"`
	HasNvidia         bool     `json:"has_nvidia"`
	HasIntel          bool     `json:"has_intel"`
	HasAMD            bool     `json:"has_amd"`
	HasVulkan         bool     `json:"has_vulkan"`
	HasD3D12VA        bool     `json:"has_d3d12va"`
	HasMF             bool     `json:"has_mf"`
	ScanCompleted     bool     `json:"scan_completed"`
}

// PlatformPreset defines presets for platform uploads.
type PlatformPreset struct {
	ID               string
	Name             string
	MaxFileSizeMB    float64
	TargetMaxWidth   int
	TargetMaxHeight  int
	MaxFPS           int
	DefaultCodec     string
	AudioBitrateKbps int
	NoMaxRate        bool
	Description      string
}

// Template represents a saved user template.
type Template struct {
	Name           string          `json:"name"`
	Mode           Mode            `json:"mode"`
	HwDecoder      string          `json:"hw_decoder"`
	HwEncoder      string          `json:"hw_encoder"`
	VideoCodec     string          `json:"video_codec"`
	QualityMode    string          `json:"quality_mode"`
	CRF            int             `json:"crf"`
	BitrateKbps    int             `json:"bitrate_kbps"`
	SpeedPreset    string          `json:"speed_preset"`
	AudioEncoder   string          `json:"audio_encoder"`
	AudioBitrate   string          `json:"audio_bitrate"`
	Deinterlace    DeinterlaceMode `json:"deinterlace"`
	OutputExt      string          `json:"output_ext"`
	TwoPass        bool            `json:"two_pass"`
	MetadataMode   MetadataMode    `json:"metadata_mode"`
	AdditionalVF   string          `json:"additional_vf"`
	AdditionalArgs string          `json:"additional_args"`
	AfterPower     PowerAction     `json:"after_power"`
}

// GeneralSettings defines parameters for General mode.
type GeneralSettings struct {
	HwDecoder      string // "none", "cuda", "qsv", "d3d11va", "dxva2", "vulkan"
	HwEncoder      string // "NVIDIA", "Intel", "AMD", "Vulkan", "D3D12VA", "MF", "CPU"
	VideoCodec     string // "libx264", "h264_nvenc", "h264_qsv", etc.
	QualityIndex   int
	CustomCRF      int
	CustomBitrate  string
	SpeedPreset    string
	AudioEncoder   string // "copy", "none", "qaac", "nero", "fdkaac", "opus", "vorbis", "flac", "internal_aac"
	AudioPreset    string
	Deinterlace    DeinterlaceMode
	OutputExt      string // "mp4", "mkv", "mov", "webm"
	CPULimit       CPURestriction
	AV1Engine      string // "libsvtav1", "libaom-av1", "rav1e"
	Overwrite      OverwriteAction
	TwoPass        bool
	Metadata       MetadataMode
	CutStart       string
	CutEnd         string
	AdditionalVF   string
	AdditionalArgs string
	AfterPower     PowerAction
	ShowAdvanced   bool
}

// PlatformSettings defines parameters for Platform upload mode.
type PlatformSettings struct {
	SelectedPlatform string // "twitter", "discord", "catbox", "uguu", "github", "github_release", "custom"
	CustomMaxMB      float64
	AutoSetting      bool // true = automatic simple, false = advanced details
	HwEncoder        string
	VideoCodec       string
	OutputExt        string
	AudioOption      string
	CustomCRF        int
}

// IntermediateSettings defines parameters for Intermediate creation mode.
type IntermediateSettings struct {
	Format      string // "prores_hq", "dnxhr_hqx", "ffv1"
	AudioFormat string // "pcm24", "flac"
	OutputExt   string // "mkv", "mov"
}

// SplitSettings defines parameters for Split mode.
type SplitSettings struct {
	SplitSource string // "chapters", "srt"
	NamingRule  string // "text", "index"
	OutputExt   string // "mp4", "mkv", "mov", "webm"
	SRTPath     string
}

// ProgressUpdate represents a single progress state report from runner.
type ProgressUpdate struct {
	QueueIndex          int
	TotalQueue          int
	Percent             float64
	CurrentSec          float64
	TotalSec            float64
	Speed               string
	FPS                 float64
	OutBytes            int64
	EstTotalBytes       int64
	PredictedBytes      int64
	PredictedBitrateBps float64
	DiffBytes           int64
	RemainingSec        int64
	ETA                 time.Time
	IsPaused            bool
	IsError             bool
	ErrorMessage        string
	LogLine             string
	LogLevel            string // "INFO", "WARN", "ERROR", "DEBUG"
}
