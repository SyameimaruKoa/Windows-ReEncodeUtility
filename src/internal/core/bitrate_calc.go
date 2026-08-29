package core

import "math"

// GetPlatformPresets returns all pre-configured platform profiles.
func GetPlatformPresets() []PlatformPreset {
	return []PlatformPreset{
		{
			ID:               "twitter",
			Name:             "Twitter (上限 512MB / 720p / H.264)",
			MaxFileSizeMB:    512,
			TargetMaxWidth:   1280,
			TargetMaxHeight:  720,
			MaxFPS:           60,
			DefaultCodec:     "libx264",
			AudioBitrateKbps: 128,
			NoMaxRate:        false,
			Description:      "Twitter / X アップロード用最適化 (H.264 必須, 720p自動縮小)",
		},
		{
			ID:               "discord",
			Name:             "Discord (上限 10MB / 低ビットレート)",
			MaxFileSizeMB:    10,
			TargetMaxWidth:   0,
			TargetMaxHeight:  0,
			MaxFPS:           0,
			DefaultCodec:     "libx264",
			AudioBitrateKbps: 64,
			NoMaxRate:        false,
			Description:      "Discord 無料枠 (10MB) 向け",
		},
		{
			ID:               "catbox",
			Name:             "catbox.moe (上限 200MB)",
			MaxFileSizeMB:    200,
			TargetMaxWidth:   0,
			TargetMaxHeight:  0,
			MaxFPS:           0,
			DefaultCodec:     "libx264",
			AudioBitrateKbps: 128,
			NoMaxRate:        false,
			Description:      "catbox.moe ファイルホスティング用",
		},
		{
			ID:               "uguu",
			Name:             "uguu.se (上限 64MB)",
			MaxFileSizeMB:    64,
			TargetMaxWidth:   0,
			TargetMaxHeight:  0,
			MaxFPS:           0,
			DefaultCodec:     "libx264",
			AudioBitrateKbps: 96,
			NoMaxRate:        false,
			Description:      "uguu.se 一時共有用",
		},
		{
			ID:               "github",
			Name:             "GitHub (上限 100MB / WebM・MP4)",
			MaxFileSizeMB:    100,
			TargetMaxWidth:   0,
			TargetMaxHeight:  0,
			MaxFPS:           0,
			DefaultCodec:     "libx264",
			AudioBitrateKbps: 128,
			NoMaxRate:        false,
			Description:      "GitHub Issue / PR 添付用 (100MB)",
		},
		{
			ID:               "github_release",
			Name:             "GitHub Release (上限 2GB / CRF品質優先)",
			MaxFileSizeMB:    2048,
			TargetMaxWidth:   0,
			TargetMaxHeight:  0,
			MaxFPS:           0,
			DefaultCodec:     "libx264",
			AudioBitrateKbps: 192,
			NoMaxRate:        true,
			Description:      "GitHub Release アセット用 (CRF 18 高画質優先)",
		},
		{
			ID:               "custom",
			Name:             "カスタム (任意容量指定)",
			MaxFileSizeMB:    100,
			TargetMaxWidth:   0,
			TargetMaxHeight:  0,
			MaxFPS:           0,
			DefaultCodec:     "libx264",
			AudioBitrateKbps: 128,
			NoMaxRate:        false,
			Description:      "任意の目標ファイルサイズ (MB) を指定",
		},
	}
}

// FindPlatformPreset searches for a preset by its ID.
func FindPlatformPreset(id string) *PlatformPreset {
	presets := GetPlatformPresets()
	for _, p := range presets {
		if p.ID == id {
			return &p
		}
	}
	return &presets[0]
}

// CalculateTargetBitrate computes target video bitrate in kbps based on file size target and duration.
// Formula: TargetBitrate = ((MaxFileSizeMB * 1024 * 8 * 0.985) - (AudioBitrateKbps * DurationSec)) / DurationSec
func CalculateTargetBitrate(maxSizeMB float64, durationSec float64, audioBitrateKbps int64) int64 {
	if durationSec <= 0 || maxSizeMB <= 0 {
		return 2000
	}

	totalTargetBits := maxSizeMB * 1024.0 * 1024.0 * 8.0 * 0.985
	audioTotalBits := float64(audioBitrateKbps*1000) * durationSec

	videoTotalBits := totalTargetBits - audioTotalBits
	if videoTotalBits <= 0 {
		// Fallback to minimum viable video bitrate
		return 100
	}

	videoBitrateBps := videoTotalBits / durationSec
	videoBitrateKbps := int64(math.Floor(videoBitrateBps / 1000.0))
	if videoBitrateKbps < 64 {
		videoBitrateKbps = 64
	}
	return videoBitrateKbps
}

// IsOverTargetSize checks whether the produced file size exceeded the platform limit.
func IsOverTargetSize(actualSizeBytes int64, targetMaxMB float64) bool {
	if targetMaxMB <= 0 {
		return false
	}
	targetBytes := int64(targetMaxMB * 1024.0 * 1024.0)
	return actualSizeBytes > targetBytes
}
