// Command applemusic-patcher unpacks, patches and registers Apple Music
// for Windows (AppleInc.AppleMusicWin) so it runs on Windows 10 (version
// 21H2 / build 19044 and newer), where Apple's installer otherwise refuses
// to run even though nothing in the app actually requires Windows 11.
//
// See the repository README for the full technical explanation. In short:
// the official package declares a Windows-11-only minimum OS version in
// its manifest, and AMP.Utils.dll independently re-checks the OS build
// number at runtime. Windows 10 and Windows 11 share the same NT kernel
// and the app uses no Windows-11-exclusive API, so both checks are patched
// out rather than worked around.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"applemusicforw10/internal/msix"
	"applemusicforw10/internal/patcher"
	"applemusicforw10/internal/register"
)

func printf(format string, args ...interface{}) {
	fmt.Printf(format+"\n", args...)
}

func findDefaultSource(scriptDir string) (string, error) {
	entries, err := os.ReadDir(scriptDir)
	if err != nil {
		return "", err
	}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(strings.ToLower(e.Name()), ".msixbundle") {
			return filepath.Join(scriptDir, e.Name()), nil
		}
	}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(strings.ToLower(e.Name()), "_x64.msix") {
			return filepath.Join(scriptDir, e.Name()), nil
		}
	}
	for _, e := range entries {
		if e.IsDir() && strings.Contains(strings.ToLower(e.Name()), "musicpackage") && strings.HasSuffix(strings.ToLower(e.Name()), "_x64") {
			return filepath.Join(scriptDir, e.Name()), nil
		}
	}
	return "", fmt.Errorf("no AppleMusic.msixbundle, *_x64.msix, or unpacked package folder found next to the executable; pass -source explicitly")
}

func defaultDest() string {
	localAppData := os.Getenv("LOCALAPPDATA")
	if localAppData == "" {
		localAppData = os.Getenv("USERPROFILE") + `\AppData\Local`
	}
	return filepath.Join(localAppData, "Programs", "AppleMusic")
}

func main() {
	exe, _ := os.Executable()
	scriptDir := filepath.Dir(exe)

	source := flag.String("source", "", "Path to AppleMusic.msixbundle, *_x64.msix, or an unpacked package folder (default: auto-detect next to the executable)")
	dest := flag.String("dest", defaultDest(), "Installation directory")
	inPlace := flag.Bool("in-place", false, "Patch and register directly inside -source without copying")
	launch := flag.Bool("launch", false, "Launch Apple Music after installation")
	flag.Parse()

	msix.Logf = printf
	patcher.Logf = printf
	register.Logf = printf

	src := *source
	if src == "" {
		found, err := findDefaultSource(scriptDir)
		if err != nil {
			fmt.Fprintln(os.Stderr, "[!]", err)
			os.Exit(1)
		}
		src = found
	}

	srcAbs, err := filepath.Abs(src)
	must(err)

	destAbs := srcAbs
	if !*inPlace {
		destAbs, err = filepath.Abs(*dest)
		must(err)
	}

	printf(strings.Repeat("=", 68))
	printf("Source     : %s", srcAbs)
	printf("Install to : %s", destAbs)
	printf(strings.Repeat("=", 68))

	register.StopRunningProcesses()

	if !*inPlace && srcAbs != destAbs {
		must(msix.ExtractOrCopySource(srcAbs, destAbs))
	}

	printf("[*] Cleaning up MSIX signature files...")
	msix.RemoveSignatureFiles(destAbs)

	printf("[*] Patching AppxManifest.xml...")
	must(patcher.PatchManifestFile(filepath.Join(destAbs, "AppxManifest.xml")))

	printf("[*] Patching AMP.Utils.dll (exports + signatures + package string)...")
	must(patcher.PatchAmpUtilsFile(filepath.Join(destAbs, "AMP.Utils.dll")))

	must(register.Package(filepath.Join(destAbs, "AppxManifest.xml")))

	if *launch {
		register.Launch()
	}

	printf("[+] Done!")
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "[!]", err)
		os.Exit(1)
	}
}
