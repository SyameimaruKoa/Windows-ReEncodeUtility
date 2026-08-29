package core

import (
	"encoding/json"
	"os/exec"
	"strings"
)

type probeAudioStream struct {
	Channels      int    `json:"channels"`
	ChannelLayout string `json:"channel_layout"`
}

type probeAudioResult struct {
	Streams []probeAudioStream `json:"streams"`
}

// GetAudioMappingFamily checks if Opus mapping_family parameter is required.
func GetAudioMappingFamily(ffprobePath, filePath string) string {
	cmd := exec.Command(ffprobePath, "-v", "quiet", "-print_format", "json", "-show_streams", "-select_streams", "a:0", filePath)
	out, err := cmd.Output()
	if err != nil || len(out) == 0 {
		return ""
	}

	var res probeAudioResult
	if err := json.Unmarshal(out, &res); err != nil || len(res.Streams) == 0 {
		return ""
	}

	stream := res.Streams[0]
	layout := strings.ToLower(stream.ChannelLayout)
	channels := stream.Channels

	if strings.Contains(layout, "ambisonic") {
		validAmbisonic := []int{1, 4, 9, 16, 25, 36, 49, 64, 81, 100, 121, 144, 169, 196, 225}
		for _, v := range validAmbisonic {
			if channels == v {
				return "-mapping_family 2"
			}
		}
		return "-mapping_family 255"
	}

	standardLayouts := []string{
		"mono", "stereo", "2.1", "3.0", "3.0(back)", "4.0", "quad", "5.0", "5.0(side)",
		"5.1", "5.1(side)", "6.0", "6.0(front)", "hexagonal", "6.1", "6.1(back)",
		"6.1(front)", "7.0", "7.0(front)", "7.1", "7.1(wide)", "7.1(wide-side)", "octagonal",
	}

	if channels > 2 {
		if layout == "" || layout == "unknown" || layout == "unspecified" {
			return "-mapping_family 255"
		}
		isStandard := false
		for _, std := range standardLayouts {
			if layout == std {
				isStandard = true
				break
			}
		}
		if !isStandard {
			return "-mapping_family 255"
		}
	}

	return ""
}
