package core

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

type ffprobeChapterTags struct {
	Title string `json:"title"`
}

type ffprobeChapterItem struct {
	ID        int                `json:"id"`
	StartTime string             `json:"start_time"`
	EndTime   string             `json:"end_time"`
	Tags      ffprobeChapterTags `json:"tags"`
}

type ffprobeChaptersResult struct {
	Chapters []ffprobeChapterItem `json:"chapters"`
}

// SanitizeFileName removes invalid Windows file name characters and replaces them with '_'.
func SanitizeFileName(name string) string {
	invalidChars := regexp.MustCompile(`[\\/:*?"<>|\r\n\t]+`)
	sanitized := invalidChars.ReplaceAllString(name, "_")
	sanitized = strings.TrimSpace(sanitized)
	sanitized = strings.Trim(sanitized, "._")
	if sanitized == "" {
		sanitized = "segment"
	}
	return sanitized
}

// ExtractChapters extracts chapter markers using ffprobe.
func ExtractChapters(ffprobePath, videoPath string) ([]ChapterInfo, error) {
	cmd := exec.Command(ffprobePath, "-v", "quiet", "-print_format", "json", "-show_chapters", videoPath)
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("チャプター情報の取得に失敗しました: %w", err)
	}

	var res ffprobeChaptersResult
	if err := json.Unmarshal(out, &res); err != nil {
		return nil, fmt.Errorf("チャプター情報のJSONパースに失敗しました: %w", err)
	}

	chapters := make([]ChapterInfo, 0, len(res.Chapters))
	for i, ch := range res.Chapters {
		start, _ := strconv.ParseFloat(ch.StartTime, 64)
		end, _ := strconv.ParseFloat(ch.EndTime, 64)
		title := ch.Tags.Title
		if title == "" {
			title = fmt.Sprintf("Chapter %02d", i+1)
		}
		chapters = append(chapters, ChapterInfo{
			ID:       i + 1,
			StartSec: start,
			EndSec:   end,
			Title:    title,
		})
	}

	return chapters, nil
}

// ParseSRT extracts subtitle timestamps and text to use as split markers.
func ParseSRT(srtPath string) ([]ChapterInfo, error) {
	file, err := os.Open(srtPath)
	if err != nil {
		return nil, fmt.Errorf("SRTファイルのオープンに失敗しました: %w", err)
	}
	defer file.Close()

	var chapters []ChapterInfo
	scanner := bufio.NewScanner(file)

	timeRegex := regexp.MustCompile(`(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})`)

	currentID := 1
	var currentStart, currentEnd float64
	var currentText []string
	inSubtitle := false

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			if inSubtitle {
				title := strings.Join(currentText, " ")
				if title == "" {
					title = fmt.Sprintf("Subtitle %02d", currentID)
				}
				chapters = append(chapters, ChapterInfo{
					ID:       currentID,
					StartSec: currentStart,
					EndSec:   currentEnd,
					Title:    title,
				})
				currentID++
				currentText = nil
				inSubtitle = false
			}
			continue
		}

		if matches := timeRegex.FindStringSubmatch(line); len(matches) > 0 {
			h1, _ := strconv.ParseFloat(matches[1], 64)
			m1, _ := strconv.ParseFloat(matches[2], 64)
			s1, _ := strconv.ParseFloat(matches[3], 64)
			ms1, _ := strconv.ParseFloat(matches[4], 64)
			currentStart = h1*3600 + m1*60 + s1 + ms1/1000.0

			h2, _ := strconv.ParseFloat(matches[5], 64)
			m2, _ := strconv.ParseFloat(matches[6], 64)
			s2, _ := strconv.ParseFloat(matches[7], 64)
			ms2, _ := strconv.ParseFloat(matches[8], 64)
			currentEnd = h2*3600 + m2*60 + s2 + ms2/1000.0

			inSubtitle = true
			currentText = nil
			continue
		}

		if inSubtitle {
			// Remove HTML/formatting tags
			tagRegex := regexp.MustCompile(`<[^>]*>`)
			cleaned := tagRegex.ReplaceAllString(line, "")
			cleaned = strings.TrimSpace(cleaned)
			if cleaned != "" {
				currentText = append(currentText, cleaned)
			}
		}
	}

	if inSubtitle {
		title := strings.Join(currentText, " ")
		if title == "" {
			title = fmt.Sprintf("Subtitle %02d", currentID)
		}
		chapters = append(chapters, ChapterInfo{
			ID:       currentID,
			StartSec: currentStart,
			EndSec:   currentEnd,
			Title:    title,
		})
	}

	return chapters, scanner.Err()
}

// BuildSegmentOutputName formats the segment filename based on naming rule.
func BuildSegmentOutputName(baseName string, ch ChapterInfo, namingRule string, ext string) string {
	ext = strings.TrimPrefix(ext, ".")
	if namingRule == "text" && ch.Title != "" {
		sanitizedTitle := SanitizeFileName(ch.Title)
		return fmt.Sprintf("%s_%s.%s", baseName, sanitizedTitle, ext)
	}
	return fmt.Sprintf("%s_%02d.%s", baseName, ch.ID, ext)
}

// FindMatchingSRT checks if an .srt file exists with the same base name next to video.
func FindMatchingSRT(videoPath string) string {
	ext := filepath.Ext(videoPath)
	srtCandidate := strings.TrimSuffix(videoPath, ext) + ".srt"
	if _, err := os.Stat(srtCandidate); err == nil {
		return srtCandidate
	}
	return ""
}
