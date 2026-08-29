package runner

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"time"

	"golang.org/x/sys/windows"
)

var (
	user32DLL       = windows.NewLazySystemDLL("user32.dll")
	procMessageBeep = user32DLL.NewProc("MessageBeep")
)

// PlaySystemSound emits a default system alert sound.
func PlaySystemSound() {
	_, _, _ = procMessageBeep.Call(0xFFFFFFFF)
}

// RunNotifyScript executes the external notification script if configured.
func RunNotifyScript(scriptPath, message, level string) {
	if scriptPath == "" {
		return
	}
	cmd := exec.Command(scriptPath, message, level)
	_ = cmd.Start()
}

type discordEmbedField struct {
	Name   string `json:"name"`
	Value  string `json:"value"`
	Inline bool   `json:"inline"`
}

type discordEmbed struct {
	Title       string              `json:"title"`
	Description string              `json:"description,omitempty"`
	Color       int                 `json:"color"`
	Fields      []discordEmbedField `json:"fields,omitempty"`
	Timestamp   string              `json:"timestamp,omitempty"`
}

type discordPayload struct {
	Content string         `json:"content,omitempty"`
	Embeds  []discordEmbed `json:"embeds"`
}

// SendDiscordItemNotification sends Discord embed for a single completed/failed file.
func SendDiscordItemNotification(webhookURL, mentionUserID, mentionOn string, success bool, fileName string, sizeMB float64, durStr string, avgFPS float64, codec string, errMsg string) {
	if webhookURL == "" {
		return
	}

	mention := ""
	shouldMention := false
	if mentionUserID != "" {
		if mentionOn == "All" || (!success && mentionOn == "ErrorOnly") {
			shouldMention = true
			mention = fmt.Sprintf("<@%s>", mentionUserID)
		}
	}

	var embed discordEmbed
	if success {
		embed = discordEmbed{
			Title:     fmt.Sprintf("✅ エンコード完了: %s", fileName),
			Color:     0x00FF87, // Green
			Timestamp: time.Now().UTC().Format(time.RFC3339),
			Fields: []discordEmbedField{
				{Name: "出力サイズ", Value: fmt.Sprintf("%.2f MB", sizeMB), Inline: true},
				{Name: "所要時間", Value: durStr, Inline: true},
				{Name: "平均 FPS", Value: fmt.Sprintf("%.1f fps", avgFPS), Inline: true},
				{Name: "コーデック", Value: codec, Inline: true},
			},
		}
	} else {
		embed = discordEmbed{
			Title:       fmt.Sprintf("❌ エンコード失敗: %s", fileName),
			Description: errMsg,
			Color:       0xFF5F5F, // Red
			Timestamp:   time.Now().UTC().Format(time.RFC3339),
		}
	}

	payload := discordPayload{
		Embeds: []discordEmbed{embed},
	}
	if shouldMention {
		payload.Content = mention
	}

	sendDiscordPayload(webhookURL, payload)
}

// SendDiscordQueueNotification sends Discord embed for the entire batch completion.
func SendDiscordQueueNotification(webhookURL, mentionUserID, mentionOn string, total, succeeded, failed int, totalDuration time.Duration) {
	if webhookURL == "" {
		return
	}

	shouldMention := false
	if mentionUserID != "" {
		if mentionOn == "All" || mentionOn == "QueueCompleteOnly" || (failed > 0 && mentionOn == "ErrorOnly") {
			shouldMention = true
		}
	}

	color := 0x00FF87
	if failed > 0 {
		color = 0xFFA500 // Orange
	}

	embed := discordEmbed{
		Title:     "🎉 全キューの処理が完了しました",
		Color:     color,
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		Fields: []discordEmbedField{
			{Name: "総処理数", Value: fmt.Sprintf("%d 件", total), Inline: true},
			{Name: "成功", Value: fmt.Sprintf("%d 件", succeeded), Inline: true},
			{Name: "失敗", Value: fmt.Sprintf("%d 件", failed), Inline: true},
			{Name: "総所要時間", Value: totalDuration.Round(time.Second).String(), Inline: true},
		},
	}

	payload := discordPayload{
		Embeds: []discordEmbed{embed},
	}
	if shouldMention {
		payload.Content = fmt.Sprintf("<@%s>", mentionUserID)
	}

	sendDiscordPayload(webhookURL, payload)
}

func sendDiscordPayload(webhookURL string, payload discordPayload) {
	data, err := json.Marshal(payload)
	if err != nil {
		return
	}

	go func() {
		req, err := http.NewRequest("POST", webhookURL, bytes.NewBuffer(data))
		if err != nil {
			return
		}
		req.Header.Set("Content-Type", "application/json")
		client := &http.Client{Timeout: 10 * time.Second}
		resp, err := client.Do(req)
		if err == nil && resp != nil {
			_ = resp.Body.Close()
		}
	}()
}
