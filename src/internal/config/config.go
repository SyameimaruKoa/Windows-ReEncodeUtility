package config

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ToolsConfig defines external tool executable paths.
type ToolsConfig struct {
	FfmpegPath           string `json:"ffmpeg_path"`
	FfprobePath          string `json:"ffprobe_path"`
	QaacPath             string `json:"qaac_path"`
	NeroAacPath          string `json:"nero_aac_path"`
	FdkaacPath           string `json:"fdkaac_path"`
	ExifToolPath         string `json:"exiftool_path"`
	LosslessCutPath      string `json:"losslesscut_path"`
	NotifyScriptPath     string `json:"notify_script_path"`
	DiscordWebhookURL    string `json:"discord_webhook_url"`
	DiscordMentionUserID string `json:"discord_mention_user_id"`
	DiscordMentionOn     string `json:"discord_mention_on"`
}

// OutputConfig defines file output behavior.
type OutputConfig struct {
	DefaultMode       string `json:"default_mode"`
	FixedOutputDir    string `json:"fixed_output_dir"`
	SubfolderName     string `json:"subfolder_name"`
	OverwriteAction   string `json:"overwrite_action"`
	OpenDirOnComplete bool   `json:"open_dir_on_complete"`
}

// BehaviorConfig defines runtime execution options.
type BehaviorConfig struct {
	DefaultMode              string `json:"default_mode"`
	CPURestriction           string `json:"cpu_restriction"`
	PlaySoundOnComplete      bool   `json:"play_sound_on_complete"`
	KeepWindowOpenOnComplete bool   `json:"keep_window_open_on_complete"`
	TempDir                  string `json:"temp_dir"`
}

// AppConfig represents the entire configuration structure.
type AppConfig struct {
	Tools    ToolsConfig    `json:"tools"`
	Output   OutputConfig   `json:"output"`
	Behavior BehaviorConfig `json:"behavior"`

	// Runtime-derived properties
	AppDir       string `json:"-"`
	ConfigPath   string `json:"-"`
	TemplatesDir string `json:"-"`
	CacheDir     string `json:"-"`
}

// DefaultConfig returns the standard default configuration.
func DefaultConfig() *AppConfig {
	return &AppConfig{
		Tools: ToolsConfig{
			FfmpegPath:           "ffmpeg",
			FfprobePath:          "ffprobe",
			QaacPath:             "qaac64",
			NeroAacPath:          "neroAacEnc",
			FdkaacPath:           "fdkaac",
			ExifToolPath:         "exiftool",
			LosslessCutPath:      "",
			NotifyScriptPath:     "",
			DiscordWebhookURL:    "",
			DiscordMentionUserID: "",
			DiscordMentionOn:     "QueueCompleteOnly",
		},
		Output: OutputConfig{
			DefaultMode:       "General",
			FixedOutputDir:    "",
			SubfolderName:     "encoded_output",
			OverwriteAction:   "Skip",
			OpenDirOnComplete: false,
		},
		Behavior: BehaviorConfig{
			DefaultMode:              "General",
			CPURestriction:           "All",
			PlaySoundOnComplete:      true,
			KeepWindowOpenOnComplete: true,
			TempDir:                  "",
		},
	}
}

// GetExecutableDir retrieves the absolute directory of the current running binary.
func GetExecutableDir() (string, error) {
	exePath, err := os.Executable()
	if err != nil {
		return os.Getwd()
	}
	return filepath.Dir(exePath), nil
}

// EnsureWritableDir checks if the target directory is writable by writing a test file.
func EnsureWritableDir(dir string) error {
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("ディレクトリを作成できません (%s): %w", dir, err)
	}
	testFile := filepath.Join(dir, fmt.Sprintf(".write_test_%d.tmp", os.Getpid()))
	if err := os.WriteFile(testFile, []byte("ok"), 0644); err != nil {
		return fmt.Errorf("ディレクトリへの書き込み権限がありません (%s): %w", dir, err)
	}
	_ = os.Remove(testFile)
	return nil
}

// LoadConfig loads config.json from the executable directory or generates it if missing.
func LoadConfig() (*AppConfig, error) {
	appDir, err := GetExecutableDir()
	if err != nil {
		return nil, fmt.Errorf("アプリケーション実行パスの取得に失敗しました: %w", err)
	}

	if err := EnsureWritableDir(appDir); err != nil {
		return nil, fmt.Errorf("実行ディレクトリの書き込み検証に失敗しました: %w", err)
	}

	cfg := DefaultConfig()
	cfg.AppDir = appDir
	cfg.ConfigPath = filepath.Join(appDir, "config.json")
	cfg.TemplatesDir = filepath.Join(appDir, "Templates")
	cfg.CacheDir = filepath.Join(appDir, ".cache")

	_ = os.MkdirAll(cfg.TemplatesDir, 0755)
	_ = os.MkdirAll(cfg.CacheDir, 0755)

	if _, err := os.Stat(cfg.ConfigPath); os.IsNotExist(err) {
		// Try to import from legacy psd1 if present
		legacyPsd1 := filepath.Join(appDir, "legacy", "config.user.psd1")
		if _, errLegacy := os.Stat(legacyPsd1); errLegacy == nil {
			importLegacyConfig(legacyPsd1, cfg)
		} else {
			rootLegacyPsd1 := filepath.Join(appDir, "config.user.psd1")
			if _, errRoot := os.Stat(rootLegacyPsd1); errRoot == nil {
				importLegacyConfig(rootLegacyPsd1, cfg)
			}
		}

		// Auto-detect tool binaries
		autoDetectTools(cfg)

		// Save generated config.json
		if err := SaveConfig(cfg); err != nil {
			return nil, fmt.Errorf("初期設定ファイル config.json の生成に失敗しました: %w", err)
		}
		return cfg, nil
	}

	data, err := os.ReadFile(cfg.ConfigPath)
	if err != nil {
		return nil, fmt.Errorf("config.json の読み込みに失敗しました: %w", err)
	}

	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("config.json の解析に失敗しました (JSON構文エラー): %w", err)
	}

	cfg.AppDir = appDir
	cfg.ConfigPath = filepath.Join(appDir, "config.json")
	cfg.TemplatesDir = filepath.Join(appDir, "Templates")
	cfg.CacheDir = filepath.Join(appDir, ".cache")

	return cfg, nil
}

// SaveConfig writes the configuration to config.json with 4-space indentation.
func SaveConfig(cfg *AppConfig) error {
	data, err := json.MarshalIndent(cfg, "", "    ")
	if err != nil {
		return fmt.Errorf("設定のJSONエンコードに失敗しました: %w", err)
	}
	return os.WriteFile(cfg.ConfigPath, data, 0644)
}

func importLegacyConfig(psd1Path string, cfg *AppConfig) {
	data, err := os.ReadFile(psd1Path)
	if err != nil {
		return
	}
	content := string(data)
	lines := strings.Split(content, "\n")
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") || !strings.Contains(trimmed, "=") {
			continue
		}
		parts := strings.SplitN(trimmed, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		val := strings.TrimSpace(parts[1])
		if idx := strings.Index(val, "#"); idx != -1 {
			val = strings.TrimSpace(val[:idx])
		}
		val = strings.Trim(val, "\"'")

		switch strings.ToLower(key) {
		case "ffmpegpath":
			if val != "" {
				cfg.Tools.FfmpegPath = val
			}
		case "ffprobepath":
			if val != "" {
				cfg.Tools.FfprobePath = val
			}
		case "qaacpath":
			if val != "" {
				cfg.Tools.QaacPath = val
			}
		case "neroaacencpath":
			if val != "" {
				cfg.Tools.NeroAacPath = val
			}
		case "fdkaacpath":
			if val != "" {
				cfg.Tools.FdkaacPath = val
			}
		case "exiftoolpath":
			if val != "" {
				cfg.Tools.ExifToolPath = val
			}
		case "losslesscutpath":
			if val != "" {
				cfg.Tools.LosslessCutPath = val
			}
		case "notifyscriptpath":
			if val != "" {
				cfg.Tools.NotifyScriptPath = val
			}
		}
	}
}

func autoDetectTools(cfg *AppConfig) {
	if findTool(cfg.Tools.FfmpegPath) == "" {
		if path := findTool("ffmpeg.exe"); path != "" {
			cfg.Tools.FfmpegPath = path
		}
	}
	if findTool(cfg.Tools.FfprobePath) == "" {
		if path := findTool("ffprobe.exe"); path != "" {
			cfg.Tools.FfprobePath = path
		}
	}
	if findTool(cfg.Tools.QaacPath) == "" {
		if path := findTool("qaac64.exe"); path != "" {
			cfg.Tools.QaacPath = path
		} else if path := findTool("qaac.exe"); path != "" {
			cfg.Tools.QaacPath = path
		}
	}
	if findTool(cfg.Tools.NeroAacPath) == "" {
		if path := findTool("neroAacEnc.exe"); path != "" {
			cfg.Tools.NeroAacPath = path
		}
	}
	if findTool(cfg.Tools.FdkaacPath) == "" {
		if path := findTool("fdkaac.exe"); path != "" {
			cfg.Tools.FdkaacPath = path
		}
	}
	if findTool(cfg.Tools.ExifToolPath) == "" {
		if path := findTool("exiftool.exe"); path != "" {
			cfg.Tools.ExifToolPath = path
		}
	}
}

func findTool(toolName string) string {
	if toolName == "" {
		return ""
	}
	if _, err := os.Stat(toolName); err == nil {
		return toolName
	}
	if path, err := exec.LookPath(toolName); err == nil {
		return path
	}
	return ""
}
