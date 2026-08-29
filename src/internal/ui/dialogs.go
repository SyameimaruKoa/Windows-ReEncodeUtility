package ui

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"golang.org/x/sys/windows/registry"
)

// RegisterExplorerContextMenu registers the context menu under HKCU.
// Does NOT require Administrator / UAC.
func RegisterExplorerContextMenu(exePath string) error {
	keyPath := `Software\Classes\SystemFileAssociations\video\shell\ReEncodeUtility`
	k, _, err := registry.CreateKey(registry.CURRENT_USER, keyPath, registry.SET_VALUE)
	if err != nil {
		return fmt.Errorf("レジストリキーの作成に失敗しました: %w", err)
	}
	defer k.Close()

	_ = k.SetStringValue("", "Windows-ReEncodeUtility でエンコード")
	_ = k.SetStringValue("Icon", exePath)

	cmdKey, _, err := registry.CreateKey(registry.CURRENT_USER, keyPath+`\command`, registry.SET_VALUE)
	if err != nil {
		return fmt.Errorf("コマンドレジストリキーの作成に失敗しました: %w", err)
	}
	defer cmdKey.Close()

	cmdStr := fmt.Sprintf("\"%s\" \"%%1\"", exePath)
	return cmdKey.SetStringValue("", cmdStr)
}

// UnregisterExplorerContextMenu removes the context menu from HKCU.
func UnregisterExplorerContextMenu() error {
	keyPath := `Software\Classes\SystemFileAssociations\video\shell\ReEncodeUtility`
	_ = registry.DeleteKey(registry.CURRENT_USER, keyPath+`\command`)
	return registry.DeleteKey(registry.CURRENT_USER, keyPath)
}

// IsContextMenuRegistered checks if context menu is currently active in HKCU.
func IsContextMenuRegistered() bool {
	keyPath := `Software\Classes\SystemFileAssociations\video\shell\ReEncodeUtility\command`
	k, err := registry.OpenKey(registry.CURRENT_USER, keyPath, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	k.Close()
	return true
}

// CreateSendToShortcut creates a shortcut in %APPDATA%\Microsoft\Windows\SendTo.
func CreateSendToShortcut(exePath string) error {
	appData := os.Getenv("APPDATA")
	if appData == "" {
		return fmt.Errorf("APPDATA環境変数が未定義です")
	}
	sendToDir := filepath.Join(appData, "Microsoft", "Windows", "SendTo")
	shortcutPath := filepath.Join(sendToDir, "Windows-ReEncodeUtility.lnk")

	psScript := fmt.Sprintf(`$ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut('%s'); $s.TargetPath = '%s'; $s.Save()`, shortcutPath, exePath)
	cmd := exec.Command("powershell", "-NoProfile", "-Command", psScript)
	return cmd.Run()
}

// RemoveSendToShortcut removes the shortcut from SendTo directory.
func RemoveSendToShortcut() error {
	appData := os.Getenv("APPDATA")
	if appData == "" {
		return nil
	}
	shortcutPath := filepath.Join(appData, "Microsoft", "Windows", "SendTo", "Windows-ReEncodeUtility.lnk")
	return os.Remove(shortcutPath)
}

// IsSendToShortcutCreated checks if SendTo shortcut exists.
func IsSendToShortcutCreated() bool {
	appData := os.Getenv("APPDATA")
	if appData == "" {
		return false
	}
	shortcutPath := filepath.Join(appData, "Microsoft", "Windows", "SendTo", "Windows-ReEncodeUtility.lnk")
	_, err := os.Stat(shortcutPath)
	return err == nil
}

// execLosslessCut launches LosslessCut for the target video.
func execLosslessCut(losslessCutPath, targetFile string) error {
	cmd := exec.Command(losslessCutPath, targetFile)
	return cmd.Start()
}
