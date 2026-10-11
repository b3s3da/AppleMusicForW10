// Package msix handles unpacking an Apple Music .msixbundle or .msix into a
// plain directory, and removing the MSIX signature metadata that would
// otherwise make Windows refuse to register a hand-patched package.
package msix

import (
	"archive/zip"
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Logf is called for every human-readable progress line; set it to a
// function that writes to stdout or a log file. The default is a no-op.
var Logf = func(format string, args ...interface{}) {}

func logf(format string, args ...interface{}) {
	Logf(format, args...)
}

// signatureFiles lists the MSIX signing/metadata files that must be removed
// before the package can be re-registered after a binary patch: Windows
// validates them and refuses to load a package whose content no longer
// matches its block map / signature.
var signatureFiles = []string{
	"AppxSignature.p7x",
	"AppxBlockMap.xml",
	"[Content_Types].xml",
	filepath.Join("AppxMetadata", "CodeIntegrity.cat"),
}

// ExtractOrCopySource populates destDir with the contents of source, which
// may be:
//   - a .msixbundle (a ZIP of per-architecture .msix files): the x64 .msix
//     inside is located and unpacked directly into destDir;
//   - a .msix (itself a ZIP of app files): unpacked directly into destDir;
//   - a directory: copied as-is into destDir.
func ExtractOrCopySource(source, destDir string) error {
	info, err := os.Stat(source)
	if err != nil {
		return fmt.Errorf("stat source: %w", err)
	}

	if err := os.RemoveAll(destDir); err != nil {
		return fmt.Errorf("clean dest dir: %w", err)
	}
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return fmt.Errorf("create dest dir: %w", err)
	}

	if info.IsDir() {
		logf("[*] Copying package files from folder %s -> %s ...", source, destDir)
		return copyDir(source, destDir)
	}

	zr, err := zip.OpenReader(source)
	if err != nil {
		return fmt.Errorf("open %s as zip/MSIX archive: %w", source, err)
	}
	defer zr.Close()

	var x64Entry *zip.File
	for _, f := range zr.File {
		lower := strings.ToLower(f.Name)
		if strings.HasSuffix(lower, ".msix") && strings.Contains(lower, "x64") {
			x64Entry = f
			break
		}
	}

	if x64Entry != nil {
		logf("[*] Found x64 package inside the bundle: %s", x64Entry.Name)
		logf("[*] Extracting %s into memory and unpacking into %s ...", x64Entry.Name, destDir)
		rc, err := x64Entry.Open()
		if err != nil {
			return fmt.Errorf("open inner msix %s: %w", x64Entry.Name, err)
		}
		innerBytes, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			return fmt.Errorf("read inner msix %s: %w", x64Entry.Name, err)
		}
		innerZr, err := zip.NewReader(bytes.NewReader(innerBytes), int64(len(innerBytes)))
		if err != nil {
			return fmt.Errorf("open inner msix %s as zip: %w", x64Entry.Name, err)
		}
		return extractZip(innerZr, destDir)
	}

	logf("[*] Unpacking MSIX archive %s into %s ...", source, destDir)
	return extractZip(&zr.Reader, destDir)
}

func extractZip(zr *zip.Reader, destDir string) error {
	for _, f := range zr.File {
		targetPath := filepath.Join(destDir, filepath.FromSlash(f.Name))
		if !strings.HasPrefix(targetPath, filepath.Clean(destDir)+string(os.PathSeparator)) && targetPath != filepath.Clean(destDir) {
			return fmt.Errorf("illegal zip entry path: %s", f.Name)
		}
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(targetPath, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
			return err
		}
		rc, err := f.Open()
		if err != nil {
			return fmt.Errorf("open zip entry %s: %w", f.Name, err)
		}
		out, err := os.OpenFile(targetPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
		if err != nil {
			rc.Close()
			return fmt.Errorf("create %s: %w", targetPath, err)
		}
		_, copyErr := io.Copy(out, rc)
		rc.Close()
		closeErr := out.Close()
		if copyErr != nil {
			return fmt.Errorf("write %s: %w", targetPath, copyErr)
		}
		if closeErr != nil {
			return fmt.Errorf("close %s: %w", targetPath, closeErr)
		}
	}
	return nil
}

func copyDir(src, dst string) error {
	return filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		in, err := os.Open(path)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
		if err != nil {
			return err
		}
		defer out.Close()
		_, err = io.Copy(out, in)
		return err
	})
}

// RemoveSignatureFiles deletes the MSIX signing/metadata files (if present)
// from an unpacked package directory.
func RemoveSignatureFiles(pkgDir string) {
	for _, rel := range signatureFiles {
		target := filepath.Join(pkgDir, rel)
		if _, err := os.Stat(target); err == nil {
			if err := os.Remove(target); err == nil {
				logf("    [-] Removed signature file: %s", rel)
			}
		}
	}
}
