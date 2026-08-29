package runner

import (
    "fmt"
    "os"
    "syscall"
    "unsafe"

    "golang.org/x/sys/windows"
)

var (
    ole32                        = windows.NewLazySystemDLL("ole32.dll")
    kernel32                     = windows.NewLazySystemDLL("kernel32.dll")
    procCoInitializeEx           = ole32.NewProc("CoInitializeEx")
    procCoCreateInstance         = ole32.NewProc("CoCreateInstance")
    procGetConsoleWindow         = kernel32.NewProc("GetConsoleWindow")
    procGetAncestor              = user32DLL.NewProc("GetAncestor")
    procEnumWindows              = user32DLL.NewProc("EnumWindows")
    procGetWindowThreadProcessId = user32DLL.NewProc("GetWindowThreadProcessId")
    procGetClassNameW            = user32DLL.NewProc("GetClassNameW")
    procIsWindowVisible          = user32DLL.NewProc("IsWindowVisible")
)

const (
    TBPF_NOPROGRESS    = 0x0
    TBPF_INDETERMINATE = 0x1
    TBPF_NORMAL        = 0x2
    TBPF_ERROR         = 0x4
    TBPF_PAUSED        = 0x8
    GA_ROOTOWNER       = 3
)

var (
    CLSID_TaskbarList = windows.GUID{
        Data1: 0x56FDF344,
        Data2: 0xFD6D,
        Data3: 0x11D0,
        Data4: [8]byte{0x95, 0x8A, 0x00, 0x60, 0x97, 0xC9, 0xA0, 0x90},
    }
    IID_ITaskbarList3 = windows.GUID{
        Data1: 0xEA1AFB91,
        Data2: 0x9E28,
        Data3: 0x4B86,
        Data4: [8]byte{0x90, 0xE9, 0x9E, 0x9F, 0x8A, 0x5E, 0xEF, 0xAF},
    }
)

type iTaskbarList3Vtbl struct {
    QueryInterface       uintptr
    AddRef               uintptr
    Release              uintptr
    HrInit               uintptr
    AddTab               uintptr
    DeleteTab            uintptr
    ActivateTab          uintptr
    SetActiveAlt         uintptr
    MarkFullscreenWindow uintptr
    SetProgressValue     uintptr
    SetProgressState     uintptr
}

type ITaskbarList3 struct {
    lpVtbl *iTaskbarList3Vtbl
}

// TaskbarController manages Windows Taskbar progress states.
type TaskbarController struct {
    hwnd        uintptr
    taskbarList *ITaskbarList3
}

func findTerminalTopLevelHWND() uintptr {
    hwnd, _, _ := procGetConsoleWindow.Call()
    if hwnd != 0 {
        rootHwnd, _, _ := procGetAncestor.Call(hwnd, GA_ROOTOWNER)
        if rootHwnd != 0 {
            return rootHwnd
        }
        return hwnd
    }

    // Fallback: search visible window of current process or parent process
    var topHwnd uintptr
    myPID := uint32(os.Getpid())
    parentPID := uint32(os.Getppid())

    cb := syscall.NewCallback(func(h uintptr, lparam uintptr) uintptr {
        var pid uint32
        _, _, _ = procGetWindowThreadProcessId.Call(h, uintptr(unsafe.Pointer(&pid)))

        vis, _, _ := procIsWindowVisible.Call(h)
        if vis == 0 {
            return 1
        }

        var className [256]uint16
        _, _, _ = procGetClassNameW.Call(h, uintptr(unsafe.Pointer(&className[0])), 256)
        cls := syscall.UTF16ToString(className[:])

        if cls == "CASCADIA_HOSTING_WINDOW_CLASS" {
            topHwnd = h
            return 0
        }

        if pid == myPID || pid == parentPID {
            if topHwnd == 0 {
                topHwnd = h
            }
        }
        return 1
    })

    _, _, _ = procEnumWindows.Call(cb, 0)
    return topHwnd
}

// NewTaskbarController initializes COM and obtains an ITaskbarList3 instance.
func NewTaskbarController() *TaskbarController {
    _ = windows.CoInitializeEx(0, windows.COINIT_APARTMENTTHREADED)

    hwnd := findTerminalTopLevelHWND()

    var obj *ITaskbarList3
    r1, _, _ := procCoCreateInstance.Call(
        uintptr(unsafe.Pointer(&CLSID_TaskbarList)),
        0,
        1, // CLSCTX_INPROC_SERVER
        uintptr(unsafe.Pointer(&IID_ITaskbarList3)),
        uintptr(unsafe.Pointer(&obj)),
    )

    if r1 == 0 && obj != nil && obj.lpVtbl != nil && obj.lpVtbl.HrInit != 0 {
        _, _, _ = syscall.SyscallN(obj.lpVtbl.HrInit, uintptr(unsafe.Pointer(obj)))
    }

    return &TaskbarController{
        hwnd:        hwnd,
        taskbarList: obj,
    }
}

// SetProgress sets taskbar progress percentage and color state.
func (t *TaskbarController) SetProgress(completed, total uint64, state int) {
    if t == nil {
        return
    }

    percent := 0
    if total > 0 {
        percent = int((float64(completed) / float64(total)) * 100.0)
    }
    if percent > 100 {
        percent = 100
    }
    if percent < 0 {
        percent = 0
    }

    // 1. Send OSC 9;4 VT sequence (Windows Terminal taskbar protocol)
    oscState := 1
    switch state {
    case TBPF_NOPROGRESS:
        oscState = 0
    case TBPF_NORMAL:
        oscState = 1
    case TBPF_ERROR:
        oscState = 2
    case TBPF_PAUSED:
        oscState = 4
    case TBPF_INDETERMINATE:
        oscState = 3
    }

    if oscState == 0 {
        fmt.Fprintf(os.Stdout, "\x1b]9;4;0;0\x1b\\")
    } else {
        fmt.Fprintf(os.Stdout, "\x1b]9;4;%d;%d\x1b\\", oscState, percent)
    }

    // 2. COM ITaskbarList3 for Windows Taskbar icon filling
    if t.taskbarList != nil && t.taskbarList.lpVtbl != nil {
        if t.hwnd == 0 {
            t.hwnd = findTerminalTopLevelHWND()
        }
        if t.hwnd != 0 {
            _, _, _ = syscall.SyscallN(
                t.taskbarList.lpVtbl.SetProgressState,
                uintptr(unsafe.Pointer(t.taskbarList)),
                t.hwnd,
                uintptr(state),
            )

            if state != TBPF_NOPROGRESS && total > 0 {
                _, _, _ = syscall.SyscallN(
                    t.taskbarList.lpVtbl.SetProgressValue,
                    uintptr(unsafe.Pointer(t.taskbarList)),
                    t.hwnd,
                    uintptr(completed),
                    uintptr(total),
                )
            }
        }
    }
}

// Clear clears taskbar progress.
func (t *TaskbarController) Clear() {
    t.SetProgress(0, 0, TBPF_NOPROGRESS)
}
