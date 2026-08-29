package core

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// IsExternalAudioEncoder checks if the audio encoder name refers to an external tool.
func IsExternalAudioEncoder(enc string) bool {
	return enc == "qaac" || enc == "nero" || enc == "fdkaac"
}

// BuildExternalAudioArgs returns CLI arguments for external audio encoders according to PS1 specification.
func BuildExternalAudioArgs(encoder, preset, customVal, inputWav, outputM4a string) []string {
	switch encoder {
	case "qaac":
		args := []string{"--ignorelength"}
		switch preset {
		case "tvbr91", "192k":
			args = append(args, "--tvbr", "91")
		case "tvbr73", "160k":
			args = append(args, "--tvbr", "73")
		case "tvbr64", "128k":
			args = append(args, "--tvbr", "64")
		case "he80":
			args = append(args, "--he", "--cvbr", "80")
		case "he64":
			args = append(args, "--he", "--cvbr", "64")
		case "he48":
			args = append(args, "--he", "--cvbr", "48")
		case "custom", "custom_tvbr":
			if customVal != "" {
				if strings.HasPrefix(customVal, "-") {
					args = append(args, strings.Fields(customVal)...)
				} else {
					args = append(args, "--tvbr", customVal)
				}
			} else {
				args = append(args, "--tvbr", "91")
			}
		case "custom_he", "custom_cvbr":
			if customVal != "" {
				val := strings.TrimSuffix(strings.TrimSpace(customVal), "k")
				args = append(args, "--he", "--cvbr", val)
			} else {
				args = append(args, "--he", "--cvbr", "64")
			}
		default:
			if strings.HasPrefix(preset, "--") {
				args = append(args, strings.Fields(preset)...)
			} else {
				args = append(args, "--tvbr", "91")
			}
		}
		args = append(args, inputWav, "-o", outputM4a)
		return args

	case "nero":
		// neroAacEnc -if <in> -of <out> [-he] -q <val>
		args := []string{"-if", inputWav, "-of", outputM4a}
		switch preset {
		case "q065", "high":
			args = append(args, "-q", "0.65")
		case "q050", "standard":
			args = append(args, "-q", "0.50")
		case "q035", "normal_he":
			args = append(args, "-he", "-q", "0.35")
		case "q020", "low_he":
			args = append(args, "-he", "-q", "0.20")
		case "custom":
			if customVal != "" {
				if strings.HasPrefix(customVal, "-") {
					args = append(args, strings.Fields(customVal)...)
				} else {
					if q, err := strconv.ParseFloat(customVal, 64); err == nil && q <= 0.40 {
						args = append(args, "-he", "-q", customVal)
					} else {
						args = append(args, "-q", customVal)
					}
				}
			} else {
				args = append(args, "-q", "0.50")
			}
		default:
			args = append(args, "-q", "0.50")
		}
		return args

	case "fdkaac":
		// fdkaac [-p 5] -m <val> -o <out> <in>
		args := []string{}
		switch preset {
		case "m5", "vbr5":
			args = append(args, "-m", "5")
		case "m4", "vbr4":
			args = append(args, "-m", "4")
		case "m3", "vbr3_he":
			args = append(args, "-p", "5", "-m", "3")
		case "m2", "vbr2_he":
			args = append(args, "-p", "5", "-m", "2")
		case "custom":
			if customVal != "" {
				if strings.HasPrefix(customVal, "-") {
					args = append(args, strings.Fields(customVal)...)
				} else {
					if m, err := strconv.Atoi(customVal); err == nil && m <= 3 {
						args = append(args, "-p", "5", "-m", customVal)
					} else {
						args = append(args, "-m", customVal)
					}
				}
			} else {
				args = append(args, "-m", "4")
			}
		default:
			args = append(args, "-m", "4")
		}
		args = append(args, "-o", outputM4a, inputWav)
		return args

	default:
		return []string{"-o", outputM4a, inputWav}
	}
}

// AudioProgressCallback is called when external audio encoder emits progress.
type AudioProgressCallback func(percent float64, message string)

// EncodeExternalAudio performs the 3-step audio pipeline with context cancellation support:
// 1. Extract audio to temporary WAV with FFmpeg
// 2. Encode with external audio encoder (qaac, nero, fdkaac)
// 3. Fallback to FFmpeg native AAC if external encoder fails
func EncodeExternalAudio(
	ctx context.Context,
	ffmpegPath, encoderPath, encoderType, preset, customVal, inputVideo, tempDir string,
	onProgress AudioProgressCallback,
) (string, bool, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if tempDir == "" {
		tempDir = os.TempDir()
	}

	wavFile := filepath.Join(tempDir, fmt.Sprintf("temp_audio_%d.wav", os.Getpid()))
	m4aFile := filepath.Join(tempDir, fmt.Sprintf("temp_audio_%d.m4a", os.Getpid()))

	if onProgress != nil {
		onProgress(5.0, fmt.Sprintf("一時WAV音声を抽出中: %s", filepath.Base(inputVideo)))
	}

	// Step 1: Extract temporary WAV
	extractCmd := exec.CommandContext(ctx, ffmpegPath, "-hide_banner", "-y", "-i", inputVideo, "-vn", "-map_chapters", "-1", "-map_metadata", "-1", "-f", "wav", wavFile)
	if err := extractCmd.Run(); err != nil {
		if ctx.Err() != nil {
			return "", false, ctx.Err()
		}
		return "", false, fmt.Errorf("一時WAV音声の切り出しに失敗しました: %w", err)
	}
	defer os.Remove(wavFile)

	select {
	case <-ctx.Done():
		return "", false, ctx.Err()
	default:
	}

	if onProgress != nil {
		onProgress(15.0, fmt.Sprintf("外部音声エンコーダ (%s) を開始します...", encoderType))
	}

	// Step 2: Encode with external tool
	args := BuildExternalAudioArgs(encoderType, preset, customVal, wavFile, m4aFile)
	encCmd := exec.CommandContext(ctx, encoderPath, args...)

	stderrPipe, errPipe := encCmd.StderrPipe()
	if errPipe == nil {
		_ = encCmd.Start()
		go monitorAudioStderr(stderrPipe, encoderType, onProgress)
		_ = encCmd.Wait()
	} else {
		_ = encCmd.Run()
	}

	select {
	case <-ctx.Done():
		return "", false, ctx.Err()
	default:
	}

	if !fileExists(m4aFile) {
		if onProgress != nil {
			onProgress(50.0, "外部音声エンコード失敗。内蔵AACにフォールバックします...")
		}
		// Step 3: Fallback to FFmpeg internal AAC
		fallbackCmd := exec.CommandContext(ctx, ffmpegPath, "-hide_banner", "-y", "-i", wavFile, "-c:a", "aac", "-b:a", "192k", m4aFile)
		if errFb := fallbackCmd.Run(); errFb != nil {
			if ctx.Err() != nil {
				return "", false, ctx.Err()
			}
			return "", false, fmt.Errorf("外部音声エンコード失敗および内蔵AACフォールバック失敗: %w", errFb)
		}
		return m4aFile, true, nil
	}

	if onProgress != nil {
		onProgress(100.0, fmt.Sprintf("外部音声エンコード完了 (%s)", encoderType))
	}

	return m4aFile, false, nil
}

func monitorAudioStderr(r io.Reader, encType string, cb AudioProgressCallback) {
	scanner := bufio.NewScanner(r)
	// qaac uses carriage return '\r' for updating progress in-place
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
		if cb != nil {
			pct := parseAudioPercent(line, encType)
			if pct > 0 {
				cb(pct, fmt.Sprintf("[%s 音声変換中] %s", encType, line))
			}
		}
	}
}

var qaacPercentRegex = regexp.MustCompile(`\[\s*([0-9.]+)%\]`)

func parseAudioPercent(line, encType string) float64 {
	matches := qaacPercentRegex.FindStringSubmatch(line)
	if len(matches) == 2 {
		if p, err := strconv.ParseFloat(matches[1], 64); err == nil {
			return p
		}
	}
	return 0
}

func fileExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir() && fi.Size() > 0
}

// BuildInternalAudioArgs builds FFmpeg audio arguments for internal codecs (AAC, Opus, Vorbis, FLAC, etc.)
func BuildInternalAudioArgs(encoder, preset, customVal string) []string {
	switch encoder {
	case "copy":
		return []string{"-c:a", "copy"}
	case "none":
		return []string{"-an"}
	case "opus":
		br := preset
		if br == "custom" && customVal != "" {
			br = customVal
		} else if br == "" || br == "default" {
			br = "128k"
		}
		if !strings.HasSuffix(br, "k") && !strings.HasSuffix(br, "K") {
			if _, err := strconv.Atoi(br); err == nil {
				br += "k"
			}
		}
		return []string{"-c:a", "libopus", "-b:a", br}

	case "vorbis":
		if preset == "q6" || preset == "high" {
			return []string{"-c:a", "libvorbis", "-q:a", "6"}
		} else if preset == "q4" || preset == "standard" || preset == "" {
			return []string{"-c:a", "libvorbis", "-q:a", "4"}
		} else if preset == "custom" && customVal != "" {
			return []string{"-c:a", "libvorbis", "-q:a", customVal}
		}
		return []string{"-c:a", "libvorbis", "-q:a", "4"}

	case "flac":
		lvl := "8"
		if preset == "comp12" || preset == "high" {
			lvl = "12"
		} else if preset == "comp8" || preset == "standard" || preset == "" {
			lvl = "8"
		} else if preset == "comp5" || preset == "fast" {
			lvl = "5"
		} else if preset == "custom" && customVal != "" {
			lvl = customVal
		}
		return []string{"-c:a", "flac", "-compression_level", lvl}

	case "internal_aac":
		fallthrough
	default:
		br := preset
		if br == "custom" && customVal != "" {
			br = customVal
		} else if br == "" || br == "default" {
			br = "192k"
		}
		if !strings.HasSuffix(br, "k") && !strings.HasSuffix(br, "K") {
			if _, err := strconv.Atoi(br); err == nil {
				br += "k"
			}
		}
		codec := "aac"
		if encoder != "internal_aac" && strings.Contains(encoder, "_") {
			codec = encoder
		}
		return []string{"-c:a", codec, "-b:a", br}
	}
}
