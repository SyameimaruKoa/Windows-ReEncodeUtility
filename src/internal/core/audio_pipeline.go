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

// BuildExternalAudioArgs returns CLI arguments for external audio encoders.
func BuildExternalAudioArgs(encoder, preset, customVal, inputWav, outputM4a string) []string {
    switch encoder {
    case "qaac":
        // Default: --tvbr 90
        args := []string{"--ignorelength", "-o", outputM4a}
        switch preset {
        case "tvbr110":
            args = append(args, "--tvbr", "110")
        case "tvbr90":
            args = append(args, "--tvbr", "90")
        case "he48":
            args = append(args, "--he", "--cvbr", "48")
        case "custom":
            if customVal != "" {
                args = append(args, strings.Fields(customVal)...)
            } else {
                args = append(args, "--tvbr", "90")
            }
        default:
            args = append(args, "--tvbr", "90")
        }
        args = append(args, inputWav)
        return args

    case "nero":
        // neroAacEnc -if <in> -of <out> -q 0.40
        args := []string{"-if", inputWav, "-of", outputM4a}
        switch preset {
        case "q05":
            args = append(args, "-q", "0.50")
        case "q04":
            args = append(args, "-q", "0.40")
        case "custom":
            if customVal != "" {
                args = append(args, strings.Fields(customVal)...)
            } else {
                args = append(args, "-q", "0.40")
            }
        default:
            args = append(args, "-q", "0.40")
        }
        return args

    case "fdkaac":
        // fdkaac -m 4 -o <out> <in>
        args := []string{"-o", outputM4a}
        switch preset {
        case "m5":
            args = append(args, "-m", "5")
        case "m4":
            args = append(args, "-m", "4")
        case "custom":
            if customVal != "" {
                args = append(args, strings.Fields(customVal)...)
            } else {
                args = append(args, "-m", "4")
            }
        default:
            args = append(args, "-m", "4")
        }
        args = append(args, inputWav)
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
