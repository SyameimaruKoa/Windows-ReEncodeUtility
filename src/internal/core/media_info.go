package core

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

type ffprobeFormat struct {
	Filename       string `json:"filename"`
	FormatName     string `json:"format_name"`
	FormatLongName string `json:"format_long_name"`
	Duration       string `json:"duration"`
	Size           string `json:"size"`
	BitRate        string `json:"bit_rate"`
}

type ffprobeStream struct {
	Index         int    `json:"index"`
	CodecName     string `json:"codec_name"`
	CodecLongName string `json:"codec_long_name"`
	CodecType     string `json:"codec_type"`
	Width         int    `json:"width"`
	Height        int    `json:"height"`
	PixFmt        string `json:"pix_fmt"`
	RFrameRate    string `json:"r_frame_rate"`
	FieldOrder    string `json:"field_order"`
	SampleRate    string `json:"sample_rate"`
	Channels      int    `json:"channels"`
	ChannelLayout string `json:"channel_layout"`
	BitRate       string `json:"bit_rate"`
}

type ffprobeOutput struct {
	Streams []ffprobeStream `json:"streams"`
	Format  ffprobeFormat   `json:"format"`
}

// ProbeMedia extracts full technical metadata of a media file without timeouts.
func ProbeMedia(ffprobePath, filePath string) (MediaInfo, error) {
	info := MediaInfo{}

	fi, err := os.Stat(filePath)
	if err != nil {
		return info, fmt.Errorf("ファイルが存在しません: %w", err)
	}
	info.FileSizeMB = math.Round(float64(fi.Size())/(1024*1024)*100) / 100

	cmd := exec.Command(ffprobePath, "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", filePath)
	out, err := cmd.Output()
	if err != nil {
		return info, fmt.Errorf("ffprobeの実行に失敗しました: %w", err)
	}

	var probe ffprobeOutput
	if err := json.Unmarshal(out, &probe); err != nil {
		return info, fmt.Errorf("ffprobe出力のJSONパースに失敗しました: %w", err)
	}

	info.FormatName = probe.Format.FormatName
	if dur, err := strconv.ParseFloat(probe.Format.Duration, 64); err == nil {
		info.DurationSec = dur
		info.DurationStr = FormatDuration(dur)
	}
	if br, err := strconv.ParseInt(probe.Format.BitRate, 10, 64); err == nil {
		info.BitrateKbps = br / 1000
	}

	for _, s := range probe.Streams {
		if s.CodecType == "video" && !info.HasVideo {
			info.HasVideo = true
			info.VideoCodec = s.CodecName
			info.VideoCodecLong = s.CodecLongName
			info.Width = s.Width
			info.Height = s.Height
			info.PixFmt = s.PixFmt
			info.FieldOrder = s.FieldOrder
			if s.FieldOrder == "tb" || s.FieldOrder == "bt" || s.FieldOrder == "tt" || s.FieldOrder == "bb" {
				info.IsInterlaced = true
			}

			// Parse FPS
			if strings.Contains(s.RFrameRate, "/") {
				parts := strings.Split(s.RFrameRate, "/")
				if len(parts) == 2 {
					num, _ := strconv.ParseFloat(parts[0], 64)
					den, _ := strconv.ParseFloat(parts[1], 64)
					if den > 0 {
						info.FPS = math.Round((num/den)*100) / 100
					}
				}
			} else if fpsVal, err := strconv.ParseFloat(s.RFrameRate, 64); err == nil {
				info.FPS = fpsVal
			}
		} else if s.CodecType == "audio" && !info.HasAudio {
			info.HasAudio = true
			info.AudioCodec = s.CodecName
			info.AudioCodecLong = s.CodecLongName
			info.Channels = s.Channels
			info.ChannelLayout = s.ChannelLayout
			if sr, err := strconv.Atoi(s.SampleRate); err == nil {
				info.SampleRate = sr
			}
			if abr, err := strconv.ParseInt(s.BitRate, 10, 64); err == nil {
				info.AudioBitrateKbps = abr / 1000
			}
		}
	}

	return info, nil
}

// FormatDuration formats seconds as HH:MM:SS
func FormatDuration(sec float64) string {
	if sec < 0 {
		sec = 0
	}
	totalSec := int(sec)
	h := totalSec / 3600
	m := (totalSec % 3600) / 60
	s := totalSec % 60
	return fmt.Sprintf("%02d:%02d:%02d", h, m, s)
}
