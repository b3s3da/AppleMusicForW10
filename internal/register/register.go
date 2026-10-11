// Package register wraps the PowerShell AppX cmdlets needed to unregister
// the stock Apple Music package and register the patched one in its place.
// There is no public, documented Win32 API for package registration that
// is simpler than shelling out to PowerShell's Appx module, so this is the
// same approach a human following Microsoft's own troubleshooting docs
// would use.
package register

import (
	"fmt"
	"os/exec"

	"applemusicforw10/internal/patcher"
)

// Logf is called for every human-readable progress line; set it to a
// function that writes to stdout or a log file. The default is a no-op.
var Logf = func(format string, args ...interface{}) {}

func logf(format string, args ...interface{}) {
	Logf(format, args...)
}

func runPowerShell(script string) (string, string, error) {
	cmd := exec.Command("powershell", "-NoProfile", "-Command", script)
	var stdout, stderr []byte
	outPipe, _ := cmd.StdoutPipe()
	errPipe, _ := cmd.StderrPipe()
	if err := cmd.Start(); err != nil {
		return "", "", err
	}
	stdout, _ = readAll(outPipe)
	stderr, _ = readAll(errPipe)
	err := cmd.Wait()
	return string(stdout), string(stderr), err
}

func readAll(r interface{ Read([]byte) (int, error) }) ([]byte, error) {
	buf := make([]byte, 0, 4096)
	chunk := make([]byte, 4096)
	for {
		n, err := r.Read(chunk)
		if n > 0 {
			buf = append(buf, chunk[:n]...)
		}
		if err != nil {
			break
		}
	}
	return buf, nil
}

// StopRunningProcesses force-stops AppleMusic.exe and AMPLibraryAgent.exe
// if they are currently running, so their files can be overwritten and the
// package can be unregistered cleanly.
func StopRunningProcesses() {
	logf("[*] Stopping running Apple Music processes...")
	_, _, _ = runPowerShell(
		"Get-Process AppleMusic, AMPLibraryAgent -ErrorAction SilentlyContinue | Stop-Process -Force",
	)
}

// Package removes the broken stock registration of the *original* Apple
// package identity, if present (first-run migration only -- see
// docs/root-cause-analysis.md for why that registration is unrecoverable),
// then registers the package whose manifest lives at manifestPath.
//
// It deliberately does NOT remove any existing registration of
// patcher.NewPackageName: Add-AppxPackage -Register re-registering the
// same package family in place is what Windows treats as an ordinary app
// update, which preserves LocalState (Apple ID sign-in, cached library,
// etc.) across repeated runs of this tool. Removing it first would wipe
// that data on every single re-run/update.
func Package(manifestPath string) error {
	logf("[*] Removing the broken stock registration (%s), if present (first-run migration only)...", patcher.OrigPackageName)
	removeScript := fmt.Sprintf(
		"Get-AppxPackage '%s*' | Remove-AppxPackage -ErrorAction SilentlyContinue",
		patcher.OrigPackageName,
	)
	_, _, _ = runPowerShell(removeScript)

	logf("[*] Registering package from %s ...", manifestPath)
	registerScript := fmt.Sprintf("Add-AppxPackage -Register '%s'", manifestPath)
	stdout, stderr, err := runPowerShell(registerScript)
	if err != nil {
		return fmt.Errorf("Add-AppxPackage -Register failed: %w\nstdout: %s\nstderr: %s", err, stdout, stderr)
	}

	logf("[+] Package registered successfully.")
	return nil
}

// Launch starts the Apple Music app via its shell:AppsFolder alias.
func Launch() {
	logf("[*] Launching Apple Music...")
	aumid := patcher.NewPackageName + "_nzyj5cx40ttqa!App"
	_, _, _ = runPowerShell(fmt.Sprintf("Start-Process 'shell:AppsFolder\\%s'", aumid))
}
