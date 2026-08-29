package runner

import (
	"io"
	"os"
	"os/exec"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	ntdllDLL                     = windows.NewLazySystemDLL("ntdll.dll")
	procNtSuspendProcess         = ntdllDLL.NewProc("NtSuspendProcess")
	procNtResumeProcess          = ntdllDLL.NewProc("NtResumeProcess")
	procCreateJobObjectW         = kernel32DLL.NewProc("CreateJobObjectW")
	procSetInformationJobObject  = kernel32DLL.NewProc("SetInformationJobObject")
	procAssignProcessToJobObject = kernel32DLL.NewProc("AssignProcessToJobObject")
)

const (
	JobObjectExtendedLimitInformation  = 9
	JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
)

type JOBOBJECT_BASIC_LIMIT_INFORMATION struct {
	PerProcessUserTimeLimit int64
	PerJobUserTimeLimit     int64
	LimitFlags              uint32
	MinimumWorkingSetSize   uintptr
	MaximumWorkingSetSize   uintptr
	ActiveProcessLimit      uint32
	Affinity                uintptr
	PriorityClass           uint32
	SchedulingClass         uint32
}

type IO_COUNTERS struct {
	ReadOperationCount  uint64
	WriteOperationCount uint64
	OtherOperationCount uint64
	ReadTransferCount   uint64
	WriteTransferCount  uint64
	OtherTransferCount  uint64
}

type JOBOBJECT_EXTENDED_LIMIT_INFORMATION struct {
	BasicLimitInformation  JOBOBJECT_BASIC_LIMIT_INFORMATION
	IoInfo                 IO_COUNTERS
	ProcessMemoryLimit     uintptr
	JobMemoryLimit         uintptr
	PeakProcessMemoryLimit uintptr
	PeakJobMemoryLimit     uintptr
}

var globalJobHandle windows.Handle

func initGlobalJobObject() {
	if globalJobHandle != 0 {
		return
	}
	r1, _, _ := procCreateJobObjectW.Call(0, 0)
	if r1 == 0 {
		return
	}
	globalJobHandle = windows.Handle(r1)

	var info JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE

	_, _, _ = procSetInformationJobObject.Call(
		uintptr(globalJobHandle),
		uintptr(JobObjectExtendedLimitInformation),
		uintptr(unsafe.Pointer(&info)),
		uintptr(unsafe.Sizeof(info)),
	)
}

// ProcessHandle wraps Windows process information.
type ProcessHandle struct {
	ProcessHandle windows.Handle
	ThreadHandle  windows.Handle
	ProcessID     uint32
	StdoutReader  io.ReadCloser
	StderrReader  io.ReadCloser
	isSuspended   bool
}

// StartProcessWide starts a process using CreateProcessW with CPU restrictions and assigns it to a KillOnClose JobObject.
func StartProcessWide(appPath string, args []string, env []string, dir string) (*ProcessHandle, error) {
	return StartProcessRestricted(appPath, args, env, dir, "All", ProcessorCoreInfo{})
}

// StartProcessRestricted starts a process suspended, applies CPU affinity/priority, then resumes.
func StartProcessRestricted(appPath string, args []string, env []string, dir string, restriction string, coreInfo ProcessorCoreInfo) (*ProcessHandle, error) {
	initGlobalJobObject()

	resolvedApp := appPath
	if resolvedApp != "" {
		if lp, err := exec.LookPath(resolvedApp); err == nil {
			resolvedApp = lp
		}
	}

	cmdArgs := make([]string, len(args))
	copy(cmdArgs, args)
	if len(cmdArgs) > 0 && resolvedApp != "" {
		cmdArgs[0] = resolvedApp
	}

	var cmdLine string
	if len(cmdArgs) > 0 {
		cmdLine = windows.ComposeCommandLine(cmdArgs)
	}

	cmdLinePtr, err := syscall.UTF16PtrFromString(cmdLine)
	if err != nil {
		return nil, err
	}

	var appPathPtr *uint16
	if resolvedApp != "" {
		appPathPtr, err = syscall.UTF16PtrFromString(resolvedApp)
		if err != nil {
			return nil, err
		}
	}

	var dirPtr *uint16
	if dir != "" {
		dirPtr, err = syscall.UTF16PtrFromString(dir)
		if err != nil {
			return nil, err
		}
	}

	// Create stdout pipe
	var stdoutRead, stdoutWrite windows.Handle
	sa := windows.SecurityAttributes{
		Length:             uint32(unsafe.Sizeof(windows.SecurityAttributes{})),
		InheritHandle:      1,
		SecurityDescriptor: nil,
	}
	if err := windows.CreatePipe(&stdoutRead, &stdoutWrite, &sa, 0); err != nil {
		return nil, err
	}
	_ = windows.SetHandleInformation(stdoutRead, windows.HANDLE_FLAG_INHERIT, 0)

	// Create stderr pipe
	var stderrRead, stderrWrite windows.Handle
	if err := windows.CreatePipe(&stderrRead, &stderrWrite, &sa, 0); err != nil {
		_ = windows.CloseHandle(stdoutRead)
		_ = windows.CloseHandle(stdoutWrite)
		return nil, err
	}
	_ = windows.SetHandleInformation(stderrRead, windows.HANDLE_FLAG_INHERIT, 0)

	var si windows.StartupInfo
	si.Cb = uint32(unsafe.Sizeof(si))
	si.Flags = windows.STARTF_USESTDHANDLES
	si.StdOutput = stdoutWrite
	si.StdErr = stderrWrite

	var pi windows.ProcessInformation

	// Start process in suspended state to ensure 0 CPU cycles on forbidden cores before affinity is set
	creationFlags := uint32(windows.CREATE_NO_WINDOW | windows.CREATE_UNICODE_ENVIRONMENT | windows.CREATE_SUSPENDED)

	err = windows.CreateProcess(
		appPathPtr,
		cmdLinePtr,
		nil,
		nil,
		true,
		creationFlags,
		nil,
		dirPtr,
		&si,
		&pi,
	)

	_ = windows.CloseHandle(stdoutWrite)
	_ = windows.CloseHandle(stderrWrite)

	if err != nil {
		_ = windows.CloseHandle(stdoutRead)
		_ = windows.CloseHandle(stderrRead)
		return nil, err
	}

	// Assign process to Job Object so that terminating terminal kills ffmpeg automatically
	if globalJobHandle != 0 {
		_, _, _ = procAssignProcessToJobObject.Call(uintptr(globalJobHandle), uintptr(pi.Process))
	}

	// Apply CPU restrictions immediately while process is still suspended
	if restriction != "" && restriction != "All" {
		ApplyCPURestriction(pi.Process, restriction, coreInfo)
	}

	// Resume process main thread
	_, _ = windows.ResumeThread(pi.Thread)

	return &ProcessHandle{
		ProcessHandle: pi.Process,
		ThreadHandle:  pi.Thread,
		ProcessID:     pi.ProcessId,
		StdoutReader:  os.NewFile(uintptr(stdoutRead), "stdout"),
		StderrReader:  os.NewFile(uintptr(stderrRead), "stderr"),
		isSuspended:   false,
	}, nil
}

// Suspend pauses the process via NtSuspendProcess.
func (p *ProcessHandle) Suspend() error {
	if p.isSuspended || p.ProcessHandle == 0 {
		return nil
	}
	r1, _, err := procNtSuspendProcess.Call(uintptr(p.ProcessHandle))
	if r1 != 0 {
		return err
	}
	p.isSuspended = true
	return nil
}

// Resume resumes the paused process via NtResumeProcess.
func (p *ProcessHandle) Resume() error {
	if !p.isSuspended || p.ProcessHandle == 0 {
		return nil
	}
	r1, _, err := procNtResumeProcess.Call(uintptr(p.ProcessHandle))
	if r1 != 0 {
		return err
	}
	p.isSuspended = false
	return nil
}

// Kill terminates the process immediately.
func (p *ProcessHandle) Kill() error {
	if p.ProcessHandle == 0 {
		return nil
	}
	if p.isSuspended {
		_ = p.Resume()
	}
	return windows.TerminateProcess(p.ProcessHandle, 1)
}

// Wait waits for the process to exit and returns exit code.
func (p *ProcessHandle) Wait() (uint32, error) {
	if p.ProcessHandle == 0 {
		return 0, nil
	}
	_, err := windows.WaitForSingleObject(p.ProcessHandle, windows.INFINITE)
	if err != nil {
		return 1, err
	}
	var exitCode uint32
	if err := windows.GetExitCodeProcess(p.ProcessHandle, &exitCode); err != nil {
		return 1, err
	}
	return exitCode, nil
}

// Close closes all open process and thread handles.
func (p *ProcessHandle) Close() {
	if p.StdoutReader != nil {
		_ = p.StdoutReader.Close()
	}
	if p.StderrReader != nil {
		_ = p.StderrReader.Close()
	}
	if p.ThreadHandle != 0 {
		_ = windows.CloseHandle(p.ThreadHandle)
		p.ThreadHandle = 0
	}
	if p.ProcessHandle != 0 {
		_ = windows.CloseHandle(p.ProcessHandle)
		p.ProcessHandle = 0
	}
}
