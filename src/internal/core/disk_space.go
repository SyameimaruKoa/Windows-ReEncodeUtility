package core

import (
	"path/filepath"
	"syscall"
	"unsafe"
)

var (
	kernel32             = syscall.NewLazyDLL("kernel32.dll")
	procGetDiskFreeSpace = kernel32.NewProc("GetDiskFreeSpaceExW")
)

// GetFreeDiskSpaceMB returns available disk space in MB for the drive containing path.
func GetFreeDiskSpaceMB(path string) (uint64, error) {
	absPath, err := filepath.Abs(path)
	if err != nil {
		absPath = path
	}
	vol := filepath.VolumeName(absPath)
	if vol == "" {
		vol = "C:"
	}
	volRoot := vol + "\\"

	volRootUTF16, err := syscall.UTF16PtrFromString(volRoot)
	if err != nil {
		return 0, err
	}

	var freeBytesAvailable, totalBytes, totalFreeBytes uint64
	r1, _, errSys := procGetDiskFreeSpace.Call(
		uintptr(unsafe.Pointer(volRootUTF16)),
		uintptr(unsafe.Pointer(&freeBytesAvailable)),
		uintptr(unsafe.Pointer(&totalBytes)),
		uintptr(unsafe.Pointer(&totalFreeBytes)),
	)

	if r1 == 0 {
		return 0, errSys
	}

	return freeBytesAvailable / (1024 * 1024), nil
}
