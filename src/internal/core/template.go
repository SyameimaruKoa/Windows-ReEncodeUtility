package core

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ListTemplates scans the Templates/ directory and returns available template names.
func ListTemplates(templatesDir string) ([]string, error) {
	entries, err := os.ReadDir(templatesDir)
	if err != nil {
		return nil, err
	}

	var names []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(strings.ToLower(e.Name()), ".json") {
			baseName := strings.TrimSuffix(e.Name(), filepath.Ext(e.Name()))
			names = append(names, baseName)
		}
	}
	return names, nil
}

// LoadTemplate loads a template by name from Templates/ directory.
func LoadTemplate(templatesDir, name string) (*Template, error) {
	if !strings.HasSuffix(name, ".json") {
		name = name + ".json"
	}
	path := filepath.Join(templatesDir, name)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("テンプレートファイルの読込に失敗しました: %w", err)
	}

	var tpl Template
	if err := json.Unmarshal(data, &tpl); err != nil {
		return nil, fmt.Errorf("テンプレートのJSONパースに失敗しました: %w", err)
	}
	return &tpl, nil
}

// SaveTemplate saves a template to Templates/ directory.
func SaveTemplate(templatesDir string, tpl *Template) error {
	_ = os.MkdirAll(templatesDir, 0755)
	fileName := tpl.Name
	if !strings.HasSuffix(fileName, ".json") {
		fileName = fileName + ".json"
	}
	path := filepath.Join(templatesDir, fileName)

	data, err := json.MarshalIndent(tpl, "", "    ")
	if err != nil {
		return fmt.Errorf("テンプレートのシリアライズに失敗しました: %w", err)
	}

	return os.WriteFile(path, data, 0644)
}
