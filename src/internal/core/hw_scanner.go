package core

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// ScanHardware detects supported video encoders and hardware acceleration methods via FFmpeg.
func ScanHardware(ffmpegPath, cacheDir string, force bool) (*HardwareInfo, error) {
	machineName, _ := os.Hostname()
	sig := getFfmpegSignature(ffmpegPath)

	cachePath := filepath.Join(cacheDir, "hardware-scan-cache.json")
	if !force {
		if info, err := loadHardwareCache(cachePath, machineName, sig); err == nil && info != nil {
			return info, nil
		}
	}

	info := &HardwareInfo{
		MachineName:       machineName,
		FfmpegSignature:   sig,
		AvailableEncoders: make([]string, 0),
		AvailableHwAccels: make([]string, 0),
	}

	// 1. Scan available encoders
	cmd := exec.Command(ffmpegPath, "-hide_banner", "-encoders")
	out, err := cmd.CombinedOutput()
	if err == nil {
		re := regexp.MustCompile(`(?m)^\s*([VA])[.\w]+\s+(\w+_(nvenc|qsv|amf|vulkan|mf|d3d12va))\s+`)
		matches := re.FindAllStringSubmatch(string(out), -1)
		for _, m := range matches {
			encType := m[1]
			encName := m[2]
			if encType == "V" {
				// Test encode 1 frame
				if testVideoEncoder(ffmpegPath, encName) {
					info.AvailableEncoders = append(info.AvailableEncoders, encName)
				}
			} else if encType == "A" {
				if testAudioEncoder(ffmpegPath, encName) {
					info.AvailableEncoders = append(info.AvailableEncoders, encName)
				}
			}
		}
	}

	// Also include standard software encoders
	swEncoders := []string{"libx264", "libx265", "libvpx-vp9", "libsvtav1", "libaom-av1", "rav1e", "prores_ks", "ffv1"}
	for _, sw := range swEncoders {
		if strings.Contains(string(out), sw) {
			info.AvailableEncoders = append(info.AvailableEncoders, sw)
		}
	}

	for _, enc := range info.AvailableEncoders {
		if strings.HasSuffix(enc, "_nvenc") {
			info.HasNvidia = true
		}
		if strings.HasSuffix(enc, "_qsv") {
			info.HasIntel = true
		}
		if strings.HasSuffix(enc, "_amf") {
			info.HasAMD = true
		}
		if strings.HasSuffix(enc, "_vulkan") {
			info.HasVulkan = true
		}
		if strings.HasSuffix(enc, "_d3d12va") {
			info.HasD3D12VA = true
		}
		if strings.HasSuffix(enc, "_mf") {
			info.HasMF = true
		}
	}

	// 2. Scan hardware decoders
	testClip := filepath.Join(os.TempDir(), fmt.Sprintf("hwaccel_test_%d.mp4", os.Getpid()))
	genCmd := exec.Command(ffmpegPath, "-hide_banner", "-y", "-f", "lavfi", "-i", "color=c=black:s=256x256:d=0.5:r=25", "-frames:v", "5", "-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "ultrafast", testClip)
	if errGen := genCmd.Run(); errGen == nil {
		defer os.Remove(testClip)
		hwList := []string{"cuda", "qsv", "amf", "d3d11va", "dxva2", "vulkan", "d3d12va"}
		for _, accel := range hwList {
			testCmd := exec.Command(ffmpegPath, "-hide_banner", "-hwaccel", accel, "-i", testClip, "-frames:v", "1", "-f", "null", "-")
			testOut, errTest := testCmd.CombinedOutput()
			outStr := string(testOut)
			if errTest == nil && !strings.Contains(outStr, "Failed setup") && !strings.Contains(outStr, "initialisation returned error") && !strings.Contains(outStr, "Device does not support") && !strings.Contains(outStr, "No device available") && !strings.Contains(outStr, "Hardware device setup failed") && !strings.Contains(outStr, "Error creating a MFX session") {
				info.AvailableHwAccels = append(info.AvailableHwAccels, accel)
			}
		}
	}

	info.ScanCompleted = true
	_ = saveHardwareCache(cachePath, info)
	return info, nil
}

func getFfmpegSignature(ffmpegPath string) string {
	resolvedPath, err := exec.LookPath(ffmpegPath)
	if err != nil {
		resolvedPath = ffmpegPath
	}
	cmd := exec.Command(ffmpegPath, "-version")
	out, err := cmd.Output()
	ver := ""
	if err == nil {
		lines := strings.Split(string(out), "\n")
		if len(lines) > 0 {
			ver = strings.TrimSpace(lines[0])
		}
	}
	return fmt.Sprintf("%s|%s", resolvedPath, ver)
}

func testVideoEncoder(ffmpegPath, enc string) bool {
	cmd1 := exec.Command(ffmpegPath, "-hide_banner", "-f", "lavfi", "-i", "color=c=black:s=256x256:d=0.5:r=25", "-frames:v", "1", "-c:v", enc, "-f", "null", "NUL")
	if err := cmd1.Run(); err == nil {
		return true
	}
	cmd2 := exec.Command(ffmpegPath, "-hide_banner", "-f", "lavfi", "-i", "color=c=black:s=256x256:d=0.5:r=25", "-frames:v", "1", "-pix_fmt", "yuv420p", "-c:v", enc, "-f", "null", "NUL")
	return cmd2.Run() == nil
}

func testAudioEncoder(ffmpegPath, enc string) bool {
	cmd := exec.Command(ffmpegPath, "-hide_banner", "-f", "lavfi", "-i", "anoisesrc=d=0.5:c=2:r=48000", "-c:a", enc, "-f", "null", "NUL")
	return cmd.Run() == nil
}

func loadHardwareCache(cachePath, machineName, sig string) (*HardwareInfo, error) {
	data, err := os.ReadFile(cachePath)
	if err != nil {
		return nil, err
	}
	var info HardwareInfo
	if err := json.Unmarshal(data, &info); err != nil {
		return nil, err
	}
	if info.MachineName != machineName || info.FfmpegSignature != sig || !info.ScanCompleted {
		return nil, fmt.Errorf("キャッシュが無効です")
	}
	return &info, nil
}

func saveHardwareCache(cachePath string, info *HardwareInfo) error {
	_ = os.MkdirAll(filepath.Dir(cachePath), 0755)
	data, err := json.MarshalIndent(info, "", "    ")
	if err != nil {
		return err
	}
	return os.WriteFile(cachePath, data, 0644)
}
