package core

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// DetectInterlacing performs ffprobe check and 500-frame idet scan to determine if video is interlaced.
func DetectInterlacing(ffmpegPath, ffprobePath, filePath string) (bool, error) {
	// 1. ffprobe field_order check
	cmdProbe := exec.Command(ffprobePath, "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=field_order", "-of", "default=noprint_wrappers=1:nokey=1", filePath)
	outProbe, _ := cmdProbe.Output()
	order := strings.TrimSpace(string(outProbe))
	if order == "tb" || order == "bt" || order == "tt" || order == "bb" {
		return true, nil
	}

	// 2. ffprobe interlaced_frame flag check
	cmdFrames := exec.Command(ffprobePath, "-v", "error", "-select_streams", "v:0", "-show_frames", "-show_entries", "frame=interlaced_frame", "-read_intervals", "%+#50", filePath)
	outFrames, _ := cmdFrames.Output()
	if strings.Contains(string(outFrames), "interlaced_frame=1") {
		return true, nil
	}

	// 3. ffmpeg idet 500-frame analysis
	cmdIdet := exec.Command(ffmpegPath, "-hide_banner", "-i", filePath, "-filter:v", "idet", "-frames:v", "500", "-an", "-f", "null", "-")
	outIdet, _ := cmdIdet.CombinedOutput()
	re := regexp.MustCompile(`TFF:\s*(\d+)\s+BFF:\s*(\d+)`)
	matches := re.FindAllStringSubmatch(string(outIdet), -1)
	if len(matches) > 0 {
		lastMatch := matches[len(matches)-1]
		tff, _ := strconv.Atoi(lastMatch[1])
		bff, _ := strconv.Atoi(lastMatch[2])
		if tff > 10 || bff > 10 {
			return true, nil
		}
	}

	return false, nil
}

// EnsureNnediWeights ensures nnedi3_weights.bin exists in the application directory.
// Returns error if download fails (specification: do not fallback on download failure).
func EnsureNnediWeights(appDir string) (string, error) {
	targetPath := filepath.Join(appDir, "nnedi3_weights.bin")
	if _, err := os.Stat(targetPath); err == nil {
		return targetPath, nil
	}

	url := "https://raw.githubusercontent.com/dubhater/vapoursynth-nnedi3/master/src/nnedi3_weights.bin"
	resp, err := http.Get(url)
	if err != nil {
		return "", fmt.Errorf("nnedi3_weights.bin のダウンロードに失敗しました: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("nnedi3_weights.bin ダウンロード時のHTTPエラー: %s", resp.Status)
	}

	tmpPath := targetPath + ".tmp"
	out, err := os.Create(tmpPath)
	if err != nil {
		return "", fmt.Errorf("nnedi3_weights.bin 保存先ファイルの作成に失敗しました: %w", err)
	}
	defer out.Close()

	if _, err := io.Copy(out, resp.Body); err != nil {
		_ = os.Remove(tmpPath)
		return "", fmt.Errorf("nnedi3_weights.bin の書き込みに失敗しました: %w", err)
	}
	out.Close()

	if err := os.Rename(tmpPath, targetPath); err != nil {
		return "", fmt.Errorf("nnedi3_weights.bin の配置に失敗しました: %w", err)
	}

	return targetPath, nil
}

// BuildDeinterlaceFilter resolves the filter string for the selected deinterlace mode.
func BuildDeinterlaceFilter(mode DeinterlaceMode, appDir string) (string, error) {
	switch mode {
	case DeinterlaceNone:
		return "", nil
	case DeinterlaceBwdif:
		return "bwdif", nil
	case DeinterlaceYadif:
		return "yadif", nil
	case DeinterlaceW3fdif:
		return "w3fdif", nil
	case DeinterlaceFieldmatchDecimate:
		return "fieldmatch,decimate", nil
	case DeinterlaceNnedi:
		weightsPath, err := EnsureNnediWeights(appDir)
		if err != nil {
			return "", err
		}
		escapedWeights := strings.ReplaceAll(weightsPath, "\\", "/")
		escapedWeights = strings.ReplaceAll(escapedWeights, ":", "\\:")
		return fmt.Sprintf("nnedi=weights='%s'", escapedWeights), nil
	case DeinterlaceFieldmatchNnediDecimate:
		weightsPath, err := EnsureNnediWeights(appDir)
		if err != nil {
			return "", err
		}
		escapedWeights := strings.ReplaceAll(weightsPath, "\\", "/")
		escapedWeights = strings.ReplaceAll(escapedWeights, ":", "\\:")
		return fmt.Sprintf("fieldmatch,nnedi=weights='%s':deint=interlaced,decimate", escapedWeights), nil
	default:
		return "", nil
	}
}
