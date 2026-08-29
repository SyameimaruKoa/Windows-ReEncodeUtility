package core

import "strings"

// GetHwAccelArgs returns FFmpeg input arguments for hardware decoding.
func GetHwAccelArgs(hwDecoder string) []string {
	switch hwDecoder {
	case "cuda":
		return []string{"-hwaccel", "cuda", "-hwaccel_output_format", "cuda"}
	case "qsv":
		return []string{"-hwaccel", "qsv", "-hwaccel_output_format", "qsv"}
	case "d3d11va":
		return []string{"-hwaccel", "d3d11va", "-hwaccel_output_format", "d3d11"}
	case "dxva2":
		return []string{"-hwaccel", "dxva2", "-hwaccel_output_format", "dxva2"}
	case "vulkan":
		return []string{"-hwaccel", "vulkan", "-hwaccel_output_format", "vulkan"}
	default:
		return []string{}
	}
}

// NeedsHwDownload checks if hwdownload,format=nv12 is required.
// Triggered when HW decode is used AND (SW filters exist OR CPU encoder is used OR Vulkan decode is used).
func NeedsHwDownload(hwDecoder, hwEncoder string, hasSwFilters bool) bool {
	if hwDecoder == "" || hwDecoder == "none" {
		return false
	}
	if hwDecoder == "vulkan" {
		return true
	}
	if hwEncoder == "CPU" || hwEncoder == "" {
		return true
	}
	if hasSwFilters {
		return true
	}
	return false
}

// NeedsExtraHwFrames checks if -extra_hw_frames 64 should be added.
// Triggered when HW decode is enabled and the pipeline mixes different GPU frameworks.
func NeedsExtraHwFrames(hwDecoder, hwEncoder string) bool {
	if hwDecoder == "" || hwDecoder == "none" {
		return false
	}
	// Matching pairs
	if hwDecoder == "cuda" && hwEncoder == "NVIDIA" {
		return false
	}
	if hwDecoder == "qsv" && hwEncoder == "Intel" {
		return false
	}
	return true
}

// IsHardwareError checks stderr output for common hardware acceleration failures.
func IsHardwareError(stderr string) bool {
	lower := strings.ToLower(stderr)
	indicators := []string{
		"device does not support",
		"failed setup for format",
		"hardware device setup failed",
		"error creating a mfx session",
		"cuda driver version is insufficient",
		"out of memory",
		"no device available",
		"nvenc error",
		"qsv error",
		"amf error",
		"dxva2 error",
		"d3d11va error",
		"vulkan error",
		"initialisation returned error",
	}
	for _, ind := range indicators {
		if strings.Contains(lower, ind) {
			return true
		}
	}
	return false
}
