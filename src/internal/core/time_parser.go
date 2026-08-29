package core

import (
	"fmt"
	"strconv"
	"strings"
)

// ParseCutTime parses flexible timecode formats and converts them into standardized FFmpeg time strings.
// Supports: "00:01:23.500", "01:23", "83", "83.5", "00:00:00".
// Returns empty string if value represents zero or is blank.
func ParseCutTime(input string) string {
	trimmed := strings.TrimSpace(input)
	if trimmed == "" || trimmed == "00:00:00" || trimmed == "00:00" || trimmed == "0" {
		return ""
	}

	// Direct seconds format (e.g. 83.5 or 83)
	if !strings.Contains(trimmed, ":") {
		if sec, err := strconv.ParseFloat(trimmed, 64); err == nil {
			if sec <= 0 {
				return ""
			}
			h := int(sec) / 3600
			m := (int(sec) % 3600) / 60
			s := sec - float64(h*3600+m*60)
			if s == float64(int(s)) {
				return fmt.Sprintf("%02d:%02d:%02d", h, m, int(s))
			}
			return fmt.Sprintf("%02d:%02d:%06.3f", h, m, s)
		}
	}

	// Colon separated format
	parts := strings.Split(trimmed, ":")
	if len(parts) == 2 {
		// mm:ss or mm:ss.xxx
		m, errM := strconv.Atoi(parts[0])
		s, errS := strconv.ParseFloat(parts[1], 64)
		if errM == nil && errS == nil {
			h := m / 60
			m = m % 60
			if s == float64(int(s)) {
				return fmt.Sprintf("%02d:%02d:%02d", h, m, int(s))
			}
			return fmt.Sprintf("%02d:%02d:%06.3f", h, m, s)
		}
	} else if len(parts) == 3 {
		// hh:mm:ss or hh:mm:ss.xxx
		h, errH := strconv.Atoi(parts[0])
		m, errM := strconv.Atoi(parts[1])
		s, errS := strconv.ParseFloat(parts[2], 64)
		if errH == nil && errM == nil && errS == nil {
			if h == 0 && m == 0 && s == 0 {
				return ""
			}
			if s == float64(int(s)) {
				return fmt.Sprintf("%02d:%02d:%02d", h, m, int(s))
			}
			return fmt.Sprintf("%02d:%02d:%06.3f", h, m, s)
		}
	}

	return trimmed
}
