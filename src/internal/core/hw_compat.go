package core

import "strings"

// GetHwAccelArgs returns FFmpeg input arguments for hardware decoding matching the target encoder.
func GetHwAccelArgs(hwDecoder, hwEncoder string) []string {
	if hwDecoder == "" || hwDecoder == "none" {
		return []string{}
	}

	// Direct native zero-copy matches
	if hwDecoder == "cuda" && hwEncoder == "NVIDIA" {
		return []string{"-hwaccel", "cuda", "-hwaccel_output_format", "cuda"}
	}
	if hwDecoder == "qsv" && hwEncoder == "Intel" {
		return []string{"-hwaccel", "qsv", "-hwaccel_output_format", "qsv"}
	}

	// For all other combinations (d3d11va, dxva2, vulkan, or mixed decoder/encoder frameworks),
	// use standard -hwaccel <type> without forcing an incompatible GPU surface format.
	// This decodes on GPU and cleanly passes NV12 system memory frames to ANY encoder (QSV/NVENC/AMF/CPU).
	return []string{"-hwaccel", hwDecoder}
}

// NeedsHwDownload checks if hwdownload,format=nv12 is required.
func NeedsHwDownload(hwDecoder, hwEncoder string, hasSwFilters bool) bool {
	if hwDecoder == "" || hwDecoder == "none" {
		return false
	}
	if hwDecoder == "vulkan" {
		return true
	}
	if (hwDecoder == "cuda" && hwEncoder == "NVIDIA") || (hwDecoder == "qsv" && hwEncoder == "Intel") {
		return hasSwFilters
	}
	return false
}

// NeedsExtraHwFrames checks if -extra_hw_frames should be added.
func NeedsExtraHwFrames(hwDecoder, hwEncoder string) bool {
	return false
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
