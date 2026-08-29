package runner

import (
    "math/bits"
    "unsafe"

    "golang.org/x/sys/windows"
)

var (
    kernel32DLL                   = windows.NewLazySystemDLL("kernel32.dll")
    procGetLogicalProcessorInfoEx = kernel32DLL.NewProc("GetLogicalProcessorInformationEx")
    procSetProcessInformation     = kernel32DLL.NewProc("SetProcessInformation")
    procSetProcessAffinityMask    = kernel32DLL.NewProc("SetProcessAffinityMask")
)

const (
    RelationProcessorCore                    = 0
    ProcessPowerThrottling                   = 4
    POWER_THROTTLING_PROCESS_EXECUTION_SPEED = 0x1
)

type PROCESS_POWER_THROTTLING_STATE struct {
    Version     uint32
    ControlMask uint32
    StateMask   uint32
}

// ProcessorCoreInfo holds logical core affinity masks for P-cores and E-cores.
type ProcessorCoreInfo struct {
    AllMask   uintptr
    PCoreMask uintptr
    ECoreMask uintptr
    HasHybrid bool
}

type GROUP_AFFINITY struct {
    Mask     uintptr
    Group    uint16
    Reserved [3]uint16
}

type PROCESSOR_CORE_INFORMATION struct {
    Flags           byte
    EfficiencyClass byte
    Reserved        [20]byte
    GroupCount      uint16
    GroupMask       [1]GROUP_AFFINITY
}

type SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX struct {
    Relationship uint32
    Size         uint32
    Union        [64]byte
}

// DetectProcessorCores scans system processor topology to differentiate P-cores and E-cores.
func DetectProcessorCores() ProcessorCoreInfo {
    info := ProcessorCoreInfo{}

    var bufSize uint32
    _, _, _ = procGetLogicalProcessorInfoEx.Call(
        uintptr(RelationProcessorCore),
        0,
        uintptr(unsafe.Pointer(&bufSize)),
    )

    if bufSize == 0 {
        info.AllMask = ^uintptr(0)
        info.PCoreMask = info.AllMask
        info.ECoreMask = info.AllMask
        return info
    }

    buf := make([]byte, bufSize)
    r1, _, _ := procGetLogicalProcessorInfoEx.Call(
        uintptr(RelationProcessorCore),
        uintptr(unsafe.Pointer(&buf[0])),
        uintptr(unsafe.Pointer(&bufSize)),
    )

    if r1 == 0 {
        info.AllMask = ^uintptr(0)
        info.PCoreMask = info.AllMask
        info.ECoreMask = info.AllMask
        return info
    }

    var distinctClasses []byte
    var offset uint32

    for offset < bufSize {
        entry := (*SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX)(unsafe.Pointer(&buf[offset]))
        if entry.Relationship == RelationProcessorCore {
            core := (*PROCESSOR_CORE_INFORMATION)(unsafe.Pointer(&entry.Union[0]))
            mask := uintptr(core.GroupMask[0].Mask)
            info.AllMask |= mask

            // Track distinct efficiency classes
            found := false
            for _, c := range distinctClasses {
                if c == core.EfficiencyClass {
                    found = true
                    break
                }
            }
            if !found {
                distinctClasses = append(distinctClasses, core.EfficiencyClass)
            }

            // EfficiencyClass > 0 indicates P-core on Intel hybrid architecture
            if core.EfficiencyClass > 0 {
                info.PCoreMask |= mask
            } else {
                info.ECoreMask |= mask
            }
        }
        offset += entry.Size
    }

    if len(distinctClasses) > 1 && info.PCoreMask != 0 && info.ECoreMask != 0 {
        info.HasHybrid = true
    } else {
        // Non-hybrid CPU (e.g. AMD Ryzen or pure Intel P-cores)
        // Divide cores: PCore = first half, ECore = second half or all with EcoQoS
        info.HasHybrid = false
        totalCores := bits.OnesCount64(uint64(info.AllMask))
        if totalCores > 2 {
            half := totalCores / 2
            var pMask, eMask uintptr
            curBit := 0
            for i := 0; i < 64; i++ {
                bit := uintptr(1) << i
                if (info.AllMask & bit) != 0 {
                    if curBit < half {
                        pMask |= bit
                    } else {
                        eMask |= bit
                    }
                    curBit++
                }
            }
            info.PCoreMask = pMask
            info.ECoreMask = eMask
        } else {
            info.PCoreMask = info.AllMask
            info.ECoreMask = info.AllMask
        }
    }

    return info
}

func setAffinity(handle windows.Handle, mask uintptr) {
    if mask != 0 {
        _, _, _ = procSetProcessAffinityMask.Call(uintptr(handle), mask)
    }
}

// ApplyCPURestriction sets CPU affinity, priority, and EcoQoS for a process handle.
func ApplyCPURestriction(procHandle windows.Handle, restriction string, coreInfo ProcessorCoreInfo) {
    if procHandle == 0 {
        return
    }

    switch restriction {
    case "PCore":
        setAffinity(procHandle, coreInfo.PCoreMask)
        _ = windows.SetPriorityClass(procHandle, windows.HIGH_PRIORITY_CLASS)

    case "ECore":
        // Restrict strictly to E-cores and set lowest priority (IDLE) + EcoQoS
        setAffinity(procHandle, coreInfo.ECoreMask)
        _ = windows.SetPriorityClass(procHandle, windows.IDLE_PRIORITY_CLASS)

        state := PROCESS_POWER_THROTTLING_STATE{
            Version:     1,
            ControlMask: POWER_THROTTLING_PROCESS_EXECUTION_SPEED,
            StateMask:   POWER_THROTTLING_PROCESS_EXECUTION_SPEED,
        }
        _, _, _ = procSetProcessInformation.Call(
            uintptr(procHandle),
            uintptr(ProcessPowerThrottling),
            uintptr(unsafe.Pointer(&state)),
            uintptr(unsafe.Sizeof(state)),
        )

    case "EcoQoS":
        setAffinity(procHandle, coreInfo.AllMask)
        _ = windows.SetPriorityClass(procHandle, windows.BELOW_NORMAL_PRIORITY_CLASS)

        state := PROCESS_POWER_THROTTLING_STATE{
            Version:     1,
            ControlMask: POWER_THROTTLING_PROCESS_EXECUTION_SPEED,
            StateMask:   POWER_THROTTLING_PROCESS_EXECUTION_SPEED,
        }
        _, _, _ = procSetProcessInformation.Call(
            uintptr(procHandle),
            uintptr(ProcessPowerThrottling),
            uintptr(unsafe.Pointer(&state)),
            uintptr(unsafe.Sizeof(state)),
        )

    case "All":
        fallthrough
    default:
        setAffinity(procHandle, coreInfo.AllMask)
        _ = windows.SetPriorityClass(procHandle, windows.NORMAL_PRIORITY_CLASS)
    }
}
