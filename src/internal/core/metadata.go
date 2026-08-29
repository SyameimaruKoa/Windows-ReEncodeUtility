package core

import (
	"os"
	"os/exec"
	"strings"
)

// CopyMetadataWithExifTool copies all tags from input to output using ExifTool.
// Cleans up any leftover *_original files.
func CopyMetadataWithExifTool(exifToolPath, inputFile, outputFile string) error {
	if exifToolPath == "" {
		return nil
	}

	cmd := exec.Command(exifToolPath, "-api", "largefilesupport=1", "-tagsfromfile", inputFile, "-all:all", "-overwrite_original", outputFile)
	err := cmd.Run()

	// Clean up possible *_original artifact
	origBackup := outputFile + "_original"
	if _, errOrig := os.Stat(origBackup); errOrig == nil {
		_ = os.Remove(origBackup)
	}

	return err
}

// NeedsGenPTS checks if -fflags +genpts should be added for fragmented MP4 / DASH / live captures.
func NeedsGenPTS(formatName string) bool {
	lower := strings.ToLower(formatName)
	if strings.Contains(lower, "dash") || strings.Contains(lower, "ismv") || strings.Contains(lower, "fragmented") {
		return true
	}
	return false
}
