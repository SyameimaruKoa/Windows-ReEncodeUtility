package runner

import (
	"os/exec"

	"windows-reencode-utility/src/internal/core"
)

// ExecutePowerAction executes the designated OS power command.
func ExecutePowerAction(action core.PowerAction) error {
	switch action {
	case core.PowerShutdown:
		return exec.Command("shutdown", "/s", "/t", "0").Run()
	case core.PowerReboot:
		return exec.Command("shutdown", "/r", "/t", "0").Run()
	case core.PowerSleep:
		return exec.Command("shutdown", "/h").Run()
	default:
		return nil
	}
}
