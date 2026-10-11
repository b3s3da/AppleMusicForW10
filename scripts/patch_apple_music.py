#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Reference Python implementation of the AppleMusicForW10 patcher.

Standard-library only (argparse, re, struct, subprocess, zipfile) -- no
`pip install` needed. Produces byte-identical output to the Go CLI in
cmd/applemusic-patcher (verified with Get-FileHash during development).

What it does:
1. Accepts as input:
   - an AppleMusic.msixbundle archive (automatically extracts the inner
     *_x64.msix package),
   - a *_x64.msix archive,
   - or an already-unpacked package folder.
2. Unpacks / copies the files into a permanent directory
   (default: %LOCALAPPDATA%\\Programs\\AppleMusic).
3. Removes the MSIX signature files (AppxSignature.p7x, AppxBlockMap.xml,
   AppxMetadata\\CodeIntegrity.cat, [Content_Types].xml) that would
   otherwise make Windows refuse to load a modified package as tampered.
4. Patches AppxManifest.xml:
   - lowers MinVersion to 10.0.19044.0 (Windows 10 21H2/LTSC and newer)
   - renames Identity Name from AppleInc.AppleMusicWin to
     AppleInc.AppleMusicW10 (same length, 22 characters) to force a clean
     StateRepository row instead of reusing a broken one left behind by any
     earlier install attempt under the original name.
5. Patches AMP.Utils.dll using two independent techniques:
   - by PE export table (every ?IsMachineWindows11*@SharedUtils@@YA_NXZ
     function)
   - by byte signature in the .text section (fallback, in case Apple
     renames or inlines a check in a future build):
     48 83 EC 38 48 8D 4C 24 20 E8 ?? ?? ?? ?? 81 7C 24 20 <build_u16> 00 00
     0F 93 C0 48 83 C4 38 C3
   - replaces the UTF-16LE package-name string AppleInc.AppleMusicWin with
     AppleInc.AppleMusicW10.
6. Re-registers the package via PowerShell `Add-AppxPackage -Register`.

See ../README.md and ../docs/root-cause-analysis.md for the full
explanation of why each of these patches is needed.
"""

import argparse
import io
import os
import re
import shutil
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

ORIG_PKG_NAME = "AppleInc.AppleMusicWin"
NEW_PKG_NAME = "AppleInc.AppleMusicW10"
TARGET_MIN_VERSION = "10.0.19044.0"

assert len(ORIG_PKG_NAME) == len(NEW_PKG_NAME) == 22

# Patch bytes: mov al, 1; ret -- makes the patched function unconditionally
# return TRUE regardless of its original logic.
PATCH_RET_TRUE = b"\xB0\x01\xC3"

# Signature shared by every "is this Windows 11 (or a specific feature
# update) or newer?" check inside AMP.Utils.dll (x64):
# 48 83 EC 38              sub rsp, 38h
# 48 8D 4C 24 20           lea rcx, [rsp+20h]
# E8 xx xx xx xx           call GetOSVersion
# 81 7C 24 20 xx xx 00 00  cmp dword ptr [rsp+20h], <build_number> (21996 / 22621 / 26100 ...)
# 0F 93 C0                 setae al
# 48 83 C4 38              add rsp, 38h
# C3                       ret
WIN11_CHECK_REGEX = re.compile(
    rb"\x48\x83\xEC\x38"
    rb"\x48\x8D\x4C\x24\x20"
    rb"\xE8.{4}"
    rb"\x81\x7C\x24\x20([\x00-\xFF]{2})\x00\x00"
    rb"\x0F\x93\xC0"
    rb"\x48\x83\xC4\x38"
    rb"\xC3",
    re.DOTALL,
)

SIGNATURE_FILES_TO_REMOVE = [
    "AppxSignature.p7x",
    "AppxBlockMap.xml",
    "[Content_Types].xml",
    os.path.join("AppxMetadata", "CodeIntegrity.cat"),
]


def parse_pe_exports_and_sections(data: bytes):
    """
    Dependency-free PE32/PE32+ export-table parser.
    Returns a list of (export_name, rva, file_offset) and a list of sections.
    """
    if data[:2] != b"MZ":
        raise ValueError("Not a valid PE file (missing MZ signature)")
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if data[e_lfanew : e_lfanew + 4] != b"PE\x00\x00":
        raise ValueError("Not a valid PE file (missing PE\\0\\0 signature)")

    coff_offset = e_lfanew + 4
    machine, num_sections, _, _, _, size_opt_hdr, _ = struct.unpack_from(
        "<HHIIIHH", data, coff_offset
    )
    opt_offset = coff_offset + 20
    magic = struct.unpack_from("<H", data, opt_offset)[0]
    if magic == 0x20B:  # PE32+ (64-bit)
        export_dir_offset = opt_offset + 112
    elif magic == 0x10B:  # PE32
        export_dir_offset = opt_offset + 96
    else:
        raise ValueError(f"Unsupported PE OptionalHeader magic: 0x{magic:X}")

    export_rva, export_size = struct.unpack_from("<II", data, export_dir_offset)

    sec_table_offset = opt_offset + size_opt_hdr
    sections = []
    for i in range(num_sections):
        sec_off = sec_table_offset + i * 40
        name_raw, virt_size, virt_addr, raw_size, raw_ptr = struct.unpack_from(
            "<8sIIII", data, sec_off
        )
        sec_name = name_raw.rstrip(b"\x00").decode("ascii", errors="replace")
        sections.append((sec_name, virt_addr, virt_size, raw_ptr, raw_size))

    def rva_to_offset(rva: int) -> int:
        for _, va, vs, ptr, rs in sections:
            span = max(vs, rs)
            if va <= rva < va + span:
                return ptr + (rva - va)
        raise ValueError(f"Could not translate RVA 0x{rva:X} to a file offset")

    exports = []
    if export_rva != 0 and export_size != 0:
        exp_off = rva_to_offset(export_rva)
        (
            _,
            _,
            _,
            _,
            _,
            _,
            num_funcs,
            num_names,
            addr_funcs_rva,
            addr_names_rva,
            addr_ords_rva,
        ) = struct.unpack_from("<IIHHIIIIIII", data, exp_off)

        funcs_off = rva_to_offset(addr_funcs_rva)
        names_off = rva_to_offset(addr_names_rva)
        ords_off = rva_to_offset(addr_ords_rva)

        for i in range(num_names):
            name_rva = struct.unpack_from("<I", data, names_off + i * 4)[0]
            ordinal_index = struct.unpack_from("<H", data, ords_off + i * 2)[0]
            func_rva = struct.unpack_from("<I", data, funcs_off + ordinal_index * 4)[0]

            # Skip forwarded exports (RVA points back inside the export directory).
            if export_rva <= func_rva < export_rva + export_size:
                continue

            name_pos = rva_to_offset(name_rva)
            end_pos = data.find(b"\x00", name_pos)
            exp_name = data[name_pos:end_pos].decode("ascii", errors="replace")
            func_file_off = rva_to_offset(func_rva)
            exports.append((exp_name, func_rva, func_file_off))

    return exports, sections


def stop_running_processes():
    """Force-stops AppleMusic.exe and AMPLibraryAgent.exe if they are running."""
    print("[*] Stopping running Apple Music processes...")
    subprocess.run(
        [
            "powershell",
            "-NoProfile",
            "-Command",
            "Get-Process AppleMusic, AMPLibraryAgent -ErrorAction SilentlyContinue | Stop-Process -Force",
        ],
        check=False,
    )


def extract_or_copy_source(source_path: Path, dest_dir: Path):
    """
    Unpacks a .msixbundle / .msix, or copies an already-unpacked folder,
    into dest_dir.
    """
    if dest_dir.exists():
        print(f"[*] Cleaning destination folder: {dest_dir}")
        shutil.rmtree(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)

    if source_path.is_dir():
        print(f"[*] Copying package files from folder {source_path} -> {dest_dir} ...")
        shutil.copytree(source_path, dest_dir, dirs_exist_ok=True)
        return

    if not zipfile.is_zipfile(source_path):
        raise RuntimeError(f"Source is neither a folder nor a ZIP/MSIX archive: {source_path}")

    with zipfile.ZipFile(source_path, "r") as zf:
        names = zf.namelist()
        # Detect whether this is a .msixbundle (contains a nested *_x64.msix)
        # or already a plain .msix.
        x64_msix_entries = [
            n for n in names if n.lower().endswith(".msix") and "x64" in n.lower()
        ]
        if x64_msix_entries:
            inner_msix_name = x64_msix_entries[0]
            print(f"[*] Found x64 package inside the bundle: {inner_msix_name}")
            print(f"[*] Extracting {inner_msix_name} into memory and unpacking into {dest_dir} ...")
            inner_bytes = zf.read(inner_msix_name)
            with zipfile.ZipFile(io.BytesIO(inner_bytes), "r") as inner_zf:
                inner_zf.extractall(dest_dir)
        else:
            print(f"[*] Unpacking MSIX archive {source_path} into {dest_dir} ...")
            zf.extractall(dest_dir)


def remove_signature_files(pkg_dir: Path):
    """Removes the MSIX signature files that would block registering a modified package."""
    for rel_path in SIGNATURE_FILES_TO_REMOVE:
        target = pkg_dir / rel_path
        if target.exists():
            target.unlink()
            print(f"    [-] Removed signature file: {rel_path}")


def patch_manifest(pkg_dir: Path):
    """Patches AppxManifest.xml: lowers MinVersion and renames Identity Name."""
    manifest_path = pkg_dir / "AppxManifest.xml"
    if not manifest_path.exists():
        raise FileNotFoundError(f"Not found: {manifest_path}")

    text = manifest_path.read_text(encoding="utf-8")

    # 1. Rename the package name in <Identity Name="...">
    text_new, count_id = re.subn(
        r'(<Identity\s+[^>]*?Name=")' + re.escape(ORIG_PKG_NAME) + r'(")',
        r"\g<1>" + NEW_PKG_NAME + r"\g<2>",
        text,
    )
    if count_id > 0:
        print(f"    [+] AppxManifest.xml: Identity Name changed {ORIG_PKG_NAME} -> {NEW_PKG_NAME}")
    elif NEW_PKG_NAME in text_new:
        print(f"    [=] AppxManifest.xml: Identity Name is already {NEW_PKG_NAME}")
    else:
        raise RuntimeError(f'Could not find <Identity Name="{ORIG_PKG_NAME}"> in AppxManifest.xml')

    # 2. Lower MinVersion to 10.0.19044.0
    text_new, count_ver = re.subn(
        r'MinVersion="10\.0\.\d+\.\d+"',
        f'MinVersion="{TARGET_MIN_VERSION}"',
        text_new,
    )
    print(f'    [+] AppxManifest.xml: set MinVersion="{TARGET_MIN_VERSION}" (replacements: {count_ver})')

    manifest_path.write_text(text_new, encoding="utf-8")


def patch_amp_utils(pkg_dir: Path):
    """
    Patches AMP.Utils.dll:
    1) Exports ?IsMachineWindows11*@SharedUtils@@YA_NXZ -> mov al, 1; ret (B0 01 C3)
    2) Byte-signature scan in .text (fallback for renamed/inlined checks)
    3) Replaces the UTF-16LE string AppleInc.AppleMusicWin -> AppleInc.AppleMusicW10
    """
    dll_path = pkg_dir / "AMP.Utils.dll"
    if not dll_path.exists():
        raise FileNotFoundError(f"Not found: {dll_path}")

    bak_path = pkg_dir / "AMP.Utils.dll.bak"
    if bak_path.exists():
        # Always remove any .bak left in the package folder so it doesn't
        # get shipped alongside the real DLL.
        bak_path.unlink()

    data = bytearray(dll_path.read_bytes())
    exports, _ = parse_pe_exports_and_sections(data)

    patched_offsets = set()

    # Step 1: patch via the PE export table.
    for exp_name, rva, file_off in exports:
        if "IsMachineWindows11" in exp_name:
            orig_bytes = bytes(data[file_off : file_off + 26])
            data[file_off : file_off + len(PATCH_RET_TRUE)] = PATCH_RET_TRUE
            patched_offsets.add(file_off)
            print(
                f"    [+] Patched export {exp_name} (RVA 0x{rva:X}, FileOff 0x{file_off:X}): "
                f"{orig_bytes[:6].hex(' ').upper()} ... -> B0 01 C3"
            )

    # Step 2: byte-signature fallback (catches additional OS-build checks).
    for match in WIN11_CHECK_REGEX.finditer(bytes(data)):
        file_off = match.start()
        build_num = struct.unpack("<H", match.group(1))[0]
        if 21996 <= build_num <= 30000 and file_off not in patched_offsets:
            data[file_off : file_off + len(PATCH_RET_TRUE)] = PATCH_RET_TRUE
            patched_offsets.add(file_off)
            print(
                f"    [+] Patched by signature (build >= {build_num} check, FileOff 0x{file_off:X}) -> B0 01 C3"
            )

    if not patched_offsets:
        print("    [!] WARNING: no unpatched Windows-11 version check found (the DLL may already be patched).")

    # Step 3: patch the UTF-16LE package-name string.
    orig_u16 = ORIG_PKG_NAME.encode("utf-16le")
    new_u16 = NEW_PKG_NAME.encode("utf-16le")
    str_count = 0
    pos = 0
    while True:
        idx = data.find(orig_u16, pos)
        if idx == -1:
            break
        data[idx : idx + len(new_u16)] = new_u16
        str_count += 1
        print(f"    [+] Patched UTF-16LE package string at offset 0x{idx:X}: {ORIG_PKG_NAME} -> {NEW_PKG_NAME}")
        pos = idx + len(new_u16)

    if str_count == 0 and data.find(new_u16) != -1:
        print(f"    [=] UTF-16LE string {NEW_PKG_NAME} is already present in AMP.Utils.dll")
    elif str_count == 0:
        raise RuntimeError("Could not find the UTF-16LE package-name string in AMP.Utils.dll!")

    dll_path.write_bytes(data)


def register_package(pkg_dir: Path):
    """Removes previous package registrations and registers the new one from pkg_dir."""
    manifest_path = pkg_dir / "AppxManifest.xml"
    print("[*] Removing previous package registrations (if any)...")
    ps_remove = (
        f"Get-AppxPackage '{NEW_PKG_NAME}*' | Remove-AppxPackage -ErrorAction SilentlyContinue; "
        f"Get-AppxPackage '{ORIG_PKG_NAME}*' | Remove-AppxPackage -ErrorAction SilentlyContinue"
    )
    subprocess.run(["powershell", "-NoProfile", "-Command", ps_remove], check=False)

    print(f"[*] Registering package from {manifest_path} ...")
    ps_register = f"Add-AppxPackage -Register '{manifest_path}'"
    res = subprocess.run(
        ["powershell", "-NoProfile", "-Command", ps_register],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        print("[!] Error while registering the package:")
        print(res.stderr or res.stdout)
        sys.exit(res.returncode)

    print("[+] Package registered successfully!")


def main():
    default_dest = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "AppleMusic"
    parser = argparse.ArgumentParser(
        description="Apple Music patcher/installer for Windows 10 21H2 (build 19044+)"
    )
    parser.add_argument(
        "-s",
        "--source",
        type=Path,
        default=None,
        help="Path to AppleMusic.msixbundle, *_x64.msix, or a package folder (default: auto-detect next to this script)",
    )
    parser.add_argument(
        "-d",
        "--dest",
        type=Path,
        default=default_dest,
        help=f"Install directory (default: {default_dest})",
    )
    parser.add_argument(
        "--in-place",
        action="store_true",
        help="Patch and register directly inside --source without copying",
    )
    parser.add_argument(
        "--launch",
        action="store_true",
        help="Launch Apple Music after installation",
    )
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    source = args.source
    if source is None:
        # Auto-detect next to the script.
        candidates = (
            list(script_dir.glob("*.msixbundle"))
            + list(script_dir.glob("*_x64.msix"))
            + [p for p in script_dir.glob("MusicPackage*_x64") if p.is_dir()]
        )
        if not candidates:
            print("[!] Could not find AppleMusic.msixbundle or a package folder. Pass --source explicitly.")
            sys.exit(1)
        source = candidates[0]

    source = source.resolve()
    dest = source if args.in_place else args.dest.resolve()

    print("=" * 68)
    print(f"Source     : {source}")
    print(f"Install to : {dest}")
    print("=" * 68)

    stop_running_processes()

    if not args.in_place and source != dest:
        extract_or_copy_source(source, dest)

    print("[*] Cleaning up MSIX signature files...")
    remove_signature_files(dest)

    print("[*] Patching AppxManifest.xml...")
    patch_manifest(dest)

    print("[*] Patching AMP.Utils.dll (exports + signatures + package string)...")
    patch_amp_utils(dest)

    register_package(dest)

    if args.launch:
        print("[*] Launching Apple Music...")
        subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-Command",
                f"Start-Process 'shell:AppsFolder\\{NEW_PKG_NAME}_nzyj5cx40ttqa!App'",
            ],
            check=False,
        )

    print("[+] Done!")


if __name__ == "__main__":
    main()
