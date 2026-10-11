// Package patcher contains the actual patch logic applied to an unpacked
// Apple Music MSIX package: the manifest rewrite and the AMP.Utils.dll
// binary patch that removes the artificial Windows 11 check.
package patcher

import (
	"bytes"
	"fmt"
	"os"
	"regexp"
	"unicode/utf16"

	"applemusicforw10/internal/pe"
)

// OrigPackageName and NewPackageName must have the same length (22 UTF-16
// code units). Windows' package-identity machinery is strict about package
// family names being stable once registered; on a system where the
// unmodified "AppleInc.AppleMusicWin" package family was already attempted
// (and left a broken, NULL-Publisher row behind in the StateRepository
// database), re-registering under the exact same name never recovers.
// Using a different-but-same-length name forces a clean StateRepository row.
const (
	OrigPackageName  = "AppleInc.AppleMusicWin"
	NewPackageName   = "AppleInc.AppleMusicW10"
	TargetMinVersion = "10.0.19044.0"
)

func init() {
	if len(OrigPackageName) != len(NewPackageName) {
		panic("OrigPackageName and NewPackageName must have equal length")
	}
}

// patchRetTrue is "mov al, 1; ret" (B0 01 C3): it replaces each OS-version
// gate with a function that unconditionally returns TRUE.
var patchRetTrue = []byte{0xB0, 0x01, 0xC3}

// win11CheckSig matches the x64 code pattern Apple's AMP.Utils.dll uses for
// every "is this Windows 11 (or newer feature update)?" check:
//
//	48 83 EC 38              sub  rsp, 38h
//	48 8D 4C 24 20           lea  rcx, [rsp+20h]
//	E8 xx xx xx xx           call GetOSVersion
//	81 7C 24 20 xx xx 00 00  cmp  dword ptr [rsp+20h], <build_number>
//	0F 93 C0                 setae al
//	48 83 C4 38              add  rsp, 38h
//	C3                       ret
//
// The build number differs per check (21996 for 11 21H2, 22621 for 22H2,
// 26100 for 24H2, ...), so it is captured instead of hard-coded.
var win11CheckSig = regexp.MustCompile(
	`(?s)\x48\x83\xEC\x38` +
		`\x48\x8D\x4C\x24\x20` +
		`\xE8.{4}` +
		`\x81\x7C\x24\x20(..)\x00\x00` +
		`\x0F\x93\xC0` +
		`\x48\x83\xC4\x38` +
		`\xC3`,
)

// Logf is called for every human-readable progress line the patcher
// produces. Callers may set it to a function that writes to stdout, a log
// file, or a GUI console; the default is a no-op.
var Logf = func(format string, args ...interface{}) {}

func logf(format string, args ...interface{}) {
	Logf(format, args...)
}

// utf16leString encodes s as UTF-16LE, the encoding Windows PE string and
// resource data use.
func utf16leString(s string) []byte {
	units := utf16.Encode([]rune(s))
	out := make([]byte, len(units)*2)
	for i, u := range units {
		out[i*2] = byte(u)
		out[i*2+1] = byte(u >> 8)
	}
	return out
}

// PatchManifestFile rewrites AppxManifest.xml in place:
//   - lowers MinVersion to TargetMinVersion so Windows 10 21H2+ (build
//     19044 and newer) accepts the package instead of rejecting it for
//     requiring a Windows 11 build;
//   - renames the package Identity from OrigPackageName to NewPackageName.
func PatchManifestFile(path string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read manifest: %w", err)
	}
	text := string(raw)

	identityRe := regexp.MustCompile(`(<Identity\s+[^>]*?Name=")` + regexp.QuoteMeta(OrigPackageName) + `(")`)
	if identityRe.MatchString(text) {
		text = identityRe.ReplaceAllString(text, "${1}"+NewPackageName+"${2}")
		logf("    [+] AppxManifest.xml: Identity Name changed %s -> %s", OrigPackageName, NewPackageName)
	} else if bytes.Contains([]byte(text), []byte(NewPackageName)) {
		logf("    [=] AppxManifest.xml: Identity Name is already %s", NewPackageName)
	} else {
		return fmt.Errorf("could not find <Identity Name=%q> in AppxManifest.xml", OrigPackageName)
	}

	minVerRe := regexp.MustCompile(`MinVersion="10\.0\.\d+\.\d+"`)
	n := len(minVerRe.FindAllString(text, -1))
	text = minVerRe.ReplaceAllString(text, `MinVersion="`+TargetMinVersion+`"`)
	logf("    [+] AppxManifest.xml: set MinVersion=%q (replacements: %d)", TargetMinVersion, n)

	return os.WriteFile(path, []byte(text), 0o644)
}

// PatchAmpUtilsFile patches AMP.Utils.dll in place using three independent,
// mutually reinforcing techniques:
//
//  1. Export-table patch: every exported symbol whose name contains
//     "IsMachineWindows11" is overwritten at its very first instruction
//     with "mov al, 1; ret", making it unconditionally report "yes".
//  2. Signature scan: as a fallback (and to catch any check Apple did not
//     export, or renamed in a future build), the whole .text section is
//     scanned for the win11CheckSig byte pattern and every match is
//     patched the same way.
//  3. String patch: the UTF-16LE package-name string embedded in the DLL
//     (used by SharedUtils::IsMusicPackage / GetMusicAppUserModelId /
//     LaunchMusicApp for package-identity checks) is rewritten from
//     OrigPackageName to NewPackageName to match the renamed manifest
//     Identity.
func PatchAmpUtilsFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read AMP.Utils.dll: %w", err)
	}

	file, err := pe.Parse(data)
	if err != nil {
		return fmt.Errorf("parse AMP.Utils.dll as PE: %w", err)
	}

	patched := map[uint32]bool{}

	// Step 1: patch every export containing "IsMachineWindows11".
	for _, exp := range file.Exports {
		if bytes.Contains([]byte(exp.Name), []byte("IsMachineWindows11")) {
			off := exp.FileOffset
			orig := append([]byte{}, data[off:off+6]...)
			copy(data[off:off+uint32(len(patchRetTrue))], patchRetTrue)
			patched[off] = true
			logf("    [+] Patched export %s (RVA 0x%X, FileOff 0x%X): % X ... -> B0 01 C3",
				exp.Name, exp.RVA, off, orig)
		}
	}

	// Step 2: signature scan fallback over the whole file.
	for _, loc := range win11CheckSig.FindAllSubmatchIndex(data, -1) {
		off := uint32(loc[0])
		if patched[off] {
			continue
		}
		buildLo, buildHi := uint32(data[loc[2]]), uint32(data[loc[2]+1])
		build := buildLo | (buildHi << 8)
		if build < 21996 || build > 30000 {
			continue
		}
		copy(data[off:off+uint32(len(patchRetTrue))], patchRetTrue)
		patched[off] = true
		logf("    [+] Patched by signature (build >= %d check, FileOff 0x%X) -> B0 01 C3", build, off)
	}

	if len(patched) == 0 {
		logf("    [!] WARNING: no unpatched Windows-11 version check found (the DLL may already be patched).")
	}

	// Step 3: patch the UTF-16LE package-name string.
	origU16 := utf16leString(OrigPackageName)
	newU16 := utf16leString(NewPackageName)
	count := 0
	pos := 0
	for {
		idx := bytes.Index(data[pos:], origU16)
		if idx == -1 {
			break
		}
		idx += pos
		copy(data[idx:idx+len(newU16)], newU16)
		count++
		logf("    [+] Patched UTF-16LE package string at offset 0x%X: %s -> %s", idx, OrigPackageName, NewPackageName)
		pos = idx + len(newU16)
	}

	if count == 0 {
		if bytes.Contains(data, newU16) {
			logf("    [=] UTF-16LE string %s is already present in AMP.Utils.dll", NewPackageName)
		} else {
			return fmt.Errorf("could not find the UTF-16LE package-name string in AMP.Utils.dll")
		}
	}

	return os.WriteFile(path, data, 0o644)
}
