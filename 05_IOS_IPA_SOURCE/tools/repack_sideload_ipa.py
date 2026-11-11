#!/usr/bin/env python3
"""Repackage NBTAIMLOCK into a clean, structurally valid, unsigned IPA.

Why this exists
---------------
iOS refuses to install ("Khong the cai dat, vui long thu lai sau") when the app
bundle is not internally consistent. The previous release IPA carried three
defects that a re-signing service cannot repair:

  1. Info.plist had no CFBundleSupportedPlatforms / UIRequiredDeviceCapabilities.
     installd rejects such a bundle before the signature is ever considered.
  2. CFBundleIconFiles referenced AppIcon76x76, a file that was not in the
     bundle, while the app declared UIDeviceFamily = [1, 2].
  3. The Mach-O carried a hand-written ad-hoc signature (CS_ADHOC) with a
     synthetic CodeDirectory and a stale _CodeSignature/CodeResources.

The canonical input for ESign / Sideloadly / AltStore is an unsigned IPA:
no LC_CODE_SIGNATURE, no _CodeSignature/. The signing service then builds the
whole signature from scratch with the user certificate and provisioning
profile.

Usage
-----
    python tools/repack_sideload_ipa.py --payload Payload --out dist/release.ipa
"""

from __future__ import annotations

import argparse
import hashlib
import plistlib
import shutil
import struct
import sys
import tempfile
import zipfile
from pathlib import Path

LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 0x2

APP_NAME = "NBTAimlock"
BUNDLE_ID = "com.nbtaimlock.ios"
EXECUTABLE = "NBTAimlock"

ICON_MAP = [
    ("icon_20.png", "AppIcon20x20.png"),
    ("icon_40.png", "AppIcon20x20@2x.png"),
    ("icon_60.png", "AppIcon20x20@3x.png"),
    ("icon_29.png", "AppIcon29x29.png"),
    ("icon_58.png", "AppIcon29x29@2x.png"),
    ("icon_87.png", "AppIcon29x29@3x.png"),
    ("icon_40.png", "AppIcon40x40.png"),
    ("icon_80.png", "AppIcon40x40@2x.png"),
    ("icon_120.png", "AppIcon40x40@3x.png"),
    ("icon_76.png", "AppIcon76x76.png"),
    ("icon_152.png", "AppIcon76x76@2x.png"),
    ("icon_167.png", "AppIcon83.5x83.5@2x.png"),
    ("icon_120.png", "AppIcon60x60@2x.png"),
    ("icon_180.png", "AppIcon60x60@3x.png"),
    ("icon_1024.png", "AppIcon1024.png"),
]

# The five system libraries the reviewed legacy native app links. It drives
# UIKit/Foundation through the Objective-C runtime instead of importing them,
# so any additional dylib means the bundle is not that app.
LEGACY_NATIVE_DYLIBS = frozenset({
    "/usr/lib/libSystem.B.dylib",
    "/System/Library/Frameworks/Foundation.framework/Foundation",
    "/System/Library/Frameworks/UIKit.framework/UIKit",
    "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
    "/System/Library/Frameworks/Security.framework/Security",
})

LEGACY_NATIVE_MARKERS = (
    b"NABATIMainViewController",
    b"AppDelegate",
    b"SceneDelegate",
    b"/api/license/authorize",
    b"/api/heartbeat",
)



def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def parse_commands(macho: bytes):
    if len(macho) < 32:
        raise SystemExit("not a Mach-O file")
    header = struct.unpack_from("<IiiIIIII", macho, 0)
    magic, cputype, _, filetype, ncmds, sizeofcmds, _, _ = header
    if magic != MH_MAGIC_64:
        raise SystemExit("expected a 64-bit little-endian Mach-O")
    if (cputype & 0xFFFFFFFF) != CPU_TYPE_ARM64:
        raise SystemExit("expected arm64")
    if filetype != MH_EXECUTE:
        raise SystemExit("expected MH_EXECUTE")

    commands = []
    offset = 32
    for _ in range(ncmds):
        if offset + 8 > len(macho):
            raise SystemExit("truncated load-command table")
        cmd, size = struct.unpack_from("<II", macho, offset)
        if size < 8 or offset + size > len(macho):
            raise SystemExit(f"invalid load command size {size} at {offset}")
        commands.append((cmd, size, offset))
        offset += size

    if offset > 32 + sizeofcmds:
        raise SystemExit("load commands overflow sizeofcmds")

    return header, commands, offset


def first_content_offset(macho: bytes, commands) -> int:
    lowest = None
    for cmd, size, offset in commands:
        if cmd != LC_SEGMENT_64:
            continue
        # segment_command_64 lays out vmaddr@24, vmsize@32, fileoff@40 — a
        # segment whose fileoff is non-zero also sits in the file.
        fileoff = struct.unpack_from("<Q", macho, offset + 40)[0]
        if fileoff:
            lowest = fileoff if lowest is None else min(lowest, fileoff)
        nsects = struct.unpack_from("<I", macho, offset + 64)[0]
        sect = offset + 72
        for _ in range(nsects):
            if sect + 80 > offset + size:
                break
            file_offset = struct.unpack_from("<I", macho, sect + 48)[0]
            if file_offset:
                lowest = file_offset if lowest is None else min(lowest, file_offset)
            sect += 80
    if lowest is None:
        raise SystemExit("could not locate section content")
    return lowest


def linked_dylibs(macho: bytes) -> list[str]:
    _, commands, _ = parse_commands(macho)
    names = []
    for cmd, size, offset in commands:
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            name_off = struct.unpack_from("<I", macho, offset + 8)[0]
            if 0 < name_off < size:
                raw = macho[offset + name_off:offset + size].split(b"\x00")[0]
                names.append(raw.decode("utf-8", "replace"))
    return names


def has_swift_sections(macho: bytes) -> bool:
    _, commands, _ = parse_commands(macho)
    for cmd, size, offset in commands:
        if cmd != LC_SEGMENT_64:
            continue
        nsects = struct.unpack_from("<I", macho, offset + 64)[0]
        sect = offset + 72
        for _ in range(nsects):
            if sect + 80 > offset + size:
                break
            sect_name = macho[sect:sect + 16].rstrip(b"\x00").decode("ascii", "replace")
            if sect_name.startswith("__swift5"):
                return True
            sect += 80
    return False


def legacy_native_problems(macho: bytes) -> list[str]:
    """Return why macho is not the reviewed legacy native app ([] when it is)."""
    problems = []
    dylibs = linked_dylibs(macho)
    if any("swift" in name.lower() for name in dylibs):
        problems.append("links the Swift runtime")
    if has_swift_sections(macho):
        problems.append("carries __swift5_* sections")
    linked = set(dylibs)
    unexpected = sorted(linked - LEGACY_NATIVE_DYLIBS)
    if unexpected:
        problems.append("links unexpected dylibs: " + ", ".join(unexpected))
    missing = sorted(LEGACY_NATIVE_DYLIBS - linked)
    if missing:
        problems.append("does not link: " + ", ".join(missing))
    for marker in LEGACY_NATIVE_MARKERS:
        if marker not in macho:
            problems.append("missing marker " + marker.decode("ascii"))
    return problems


def assert_shippable_build(macho: bytes, app_src: Path, allow_legacy_native: bool) -> str:
    """Refuse to package a binary that is not an app from this repository.

    The shipped Swift sources compile to a binary that links libswiftCore.dylib.
    A bundle linking only libSystem/UIKit/Foundation is the legacy native app:
    structurally valid, but a different implementation. It may only be shipped
    when explicitly requested, and only when its identity matches the reviewed
    app exactly - never as a wildcard "not Swift" pass.
    """
    dylibs = linked_dylibs(macho)
    if any("swift" in name.lower() for name in dylibs) or has_swift_sections(macho):
        return "swift"

    if not allow_legacy_native:
        raise SystemExit(
            f"REFUSING TO PACKAGE: {app_src} links no libswift* dylib and has no "
            f"__swift5_* sections (dylibs: {', '.join(dylibs) or 'none'}).\n"
            "This is not the Swift app in this repository. Build the Xcode project "
            "(see .github/workflows/build-ios.yml or tools/build_ios_ipa.sh), or "
            "re-run with --allow-legacy-native if this is the reviewed legacy app."
        )

    problems = legacy_native_problems(macho)
    if problems:
        raise SystemExit(
            "REFUSING TO PACKAGE: --allow-legacy-native was given but the binary is "
            "not the reviewed legacy native app: " + "; ".join(problems)
        )
    print("WARNING: packaging the legacy native app (no Swift runtime).", file=sys.stderr)
    return "legacy-native"



def strip_code_signature(macho: bytes) -> bytes:
    """Remove LC_CODE_SIGNATURE and the trailing blob without moving content."""
    header, commands, table_end = parse_commands(macho)
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, reserved = header

    sig = None
    for cmd, size, offset in commands:
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack_from("<II", macho, offset + 8)
            sig = (offset, size, dataoff, datasize)
            break
    if sig is None:
        return macho

    _, cmd_size, dataoff, datasize = sig
    if dataoff + datasize != len(macho):
        raise SystemExit("code signature is not the trailing blob; refusing to guess")
    if datasize < 8:
        raise SystemExit("empty code signature blob")

    content_offset = first_content_offset(macho, commands)
    if table_end > content_offset:
        raise SystemExit("load commands overlap section content")

    new_ncmds = ncmds - 1
    new_sizeofcmds = sizeofcmds - cmd_size
    new_table_end = 32 + new_sizeofcmds
    if new_table_end > content_offset:
        raise SystemExit("not enough header padding to reclaim the command")

    out = bytearray(macho)
    out[0:32] = struct.pack(
        "<IiiIIIII", magic, cputype, cpusub, filetype, new_ncmds, new_sizeofcmds, flags, reserved
    )

    body = bytearray()
    for cmd, size, offset in commands:
        if cmd == LC_CODE_SIGNATURE:
            continue
        if cmd == LC_SEGMENT_64:
            raw = bytearray(macho[offset:offset + size])
            name = bytes(raw[8:24]).rstrip(b"\x00")
            if name == b"__LINKEDIT":
                old_fileoff = struct.unpack_from("<Q", raw, 40)[0]
                new_filesize = dataoff - old_fileoff
                if new_filesize <= 0:
                    raise SystemExit("invalid linkedit size after removing signature")
                struct.pack_into("<Q", raw, 48, new_filesize)
                vmsize = struct.unpack_from("<Q", raw, 32)[0]
                if vmsize < new_filesize:
                    struct.pack_into("<Q", raw, 32, align_up(new_filesize, 0x4000))
            body.extend(raw)
        else:
            body.extend(macho[offset:offset + size])

    if len(body) != new_sizeofcmds:
        raise SystemExit("internal error: rebuilt command table has wrong size")

    out[32:32 + len(body)] = body
    gap_start = 32 + len(body)
    if gap_start < content_offset:
        out[gap_start:content_offset] = b"\x00" * (content_offset - gap_start)

    del out[dataoff:]
    return bytes(out)


def copytree(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def fix_info_plist(plist: dict) -> dict:
    plist["CFBundleIdentifier"] = BUNDLE_ID
    plist["CFBundleExecutable"] = EXECUTABLE
    plist["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
    plist["UIRequiredDeviceCapabilities"] = ["arm64"]
    plist.setdefault("MinimumOSVersion", "14.0")
    plist.setdefault("DTPlatformName", "iphoneos")
    plist.setdefault("UIDeviceFamily", [1, 2])
    plist.setdefault("LSRequiresIPhoneOS", True)
    plist.setdefault("UILaunchScreen", {})

    iphone_icons = ["AppIcon60x60"]
    ipad_icons = ["AppIcon60x60", "AppIcon76x76", "AppIcon83.5x83.5"]
    plist["CFBundleIcons"] = {
        "CFBundlePrimaryIcon": {
            "CFBundleIconFiles": iphone_icons,
            "UIPrerenderedIcon": False,
        }
    }
    plist["CFBundleIcons~ipad"] = {
        "CFBundlePrimaryIcon": {
            "CFBundleIconFiles": ipad_icons,
            "UIPrerenderedIcon": False,
        }
    }
    plist["CFBundleIconFiles"] = ["AppIcon60x60", "AppIcon76x76", "AppIcon83.5x83.5"]
    plist.pop("CFBundleIconName", None)
    return plist


def install_icons(bundle: Path, icons_dir: Path | None) -> list[str]:
    installed = []
    if icons_dir and icons_dir.is_dir():
        for source_name, dest_name in ICON_MAP:
            source = icons_dir / source_name
            if not source.is_file():
                continue
            shutil.copyfile(source, bundle / dest_name)
            installed.append(dest_name)
    for required in ("AppIcon60x60@2x.png", "AppIcon60x60@3x.png",
                     "AppIcon76x76@2x.png", "AppIcon83.5x83.5@2x.png"):
        if not (bundle / required).is_file():
            raise SystemExit(f"missing required icon {required}")
    return installed


def zip_write(zf: zipfile.ZipFile, arcname: str, data: bytes, mode: int, mtime) -> None:
    info = zipfile.ZipInfo(arcname, date_time=mtime)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = (mode & 0xFFFF) << 16
    zf.writestr(info, data)


def build(payload_dir: Path, out_path: Path, icons_dir: Path | None, allow_legacy_native: bool = False) -> dict:
    app_src = payload_dir / f"{APP_NAME}.app"
    if not app_src.is_dir():
        raise SystemExit(f"payload app not found: {app_src}")

    binary_src = app_src / EXECUTABLE
    if not binary_src.is_file():
        raise SystemExit(f"executable not found: {binary_src}")

    with tempfile.TemporaryDirectory(prefix="nbt_ipa_") as tmp:
        stage_root = Path(tmp) / "Payload"
        stage_app = stage_root / f"{APP_NAME}.app"
        stage_root.mkdir(parents=True)
        copytree(app_src, stage_app)

        shutil.rmtree(stage_app / "_CodeSignature", ignore_errors=True)
        (stage_app / "embedded.mobileprovision").unlink(missing_ok=True)
        shutil.rmtree(stage_app / "SC_Info", ignore_errors=True)
        (stage_app / ".DS_Store").unlink(missing_ok=True)

        # Check the source binary before stripping, so the error names the real
        # problem (wrong bundle) rather than a later symptom.
        build_kind = assert_shippable_build(binary_src.read_bytes(), app_src, allow_legacy_native)

        unsigned_binary = strip_code_signature(binary_src.read_bytes())
        (stage_app / EXECUTABLE).write_bytes(unsigned_binary)

        info_path = stage_app / "Info.plist"
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
        info = fix_info_plist(info)
        with info_path.open("wb") as handle:
            plistlib.dump(info, handle, fmt=plistlib.FMT_BINARY, sort_keys=False)

        icons = install_icons(stage_app, icons_dir)

        out_path.parent.mkdir(parents=True, exist_ok=True)
        if out_path.exists():
            out_path.unlink()

        mtime = (2026, 1, 1, 0, 0, 0)
        with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
            zip_write(zf, "Payload/", b"", 0o40755, mtime)
            zip_write(zf, f"Payload/{APP_NAME}.app/", b"", 0o40755, mtime)
            for path in sorted(stage_app.rglob("*")):
                if path.is_dir():
                    continue
                rel = f"Payload/{APP_NAME}.app/{path.relative_to(stage_app).as_posix()}"
                mode = 0o100755 if path.name == EXECUTABLE else 0o100644
                zip_write(zf, rel, path.read_bytes(), mode, mtime)

    digest = hashlib.sha256(out_path.read_bytes()).hexdigest()
    return {
        "out": str(out_path),
        "size": out_path.stat().st_size,
        "sha256": digest,
        "icons": icons,
        "unsigned_macho_size": len(unsigned_binary),
        "build": build_kind,
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Build a clean unsigned IPA for sideload signing")
    parser.add_argument("--payload", default="Payload", type=Path,
                        help="directory containing NBTAimlock.app")
    parser.add_argument("--out", default="dist/nbtaimlock-release-unsigned.ipa", type=Path)
    parser.add_argument("--icons-dir",
                        default=Path("NBTAimlock/Assets.xcassets/AppIcon.appiconset"),
                        type=Path,
                        help="appiconset directory used to refresh the loose icon files")
    parser.add_argument("--allow-legacy-native", action="store_true",
                        help="package the reviewed legacy native app when no Swift build exists")
    args = parser.parse_args(argv)

    icons_dir = args.icons_dir if args.icons_dir.is_dir() else None
    result = build(args.payload, args.out, icons_dir, args.allow_legacy_native)
    out = result["out"]
    size = result["size"]
    sha = result["sha256"]
    macho_size = result["unsigned_macho_size"]
    icon_count = len(result["icons"])
    print(f"Build    : {result['build']}")
    print(f"IPA      : {out}")
    print(f"Size     : {size:,} bytes")
    print(f"SHA-256  : {sha}")
    print(f"Mach-O   : {macho_size:,} bytes (no LC_CODE_SIGNATURE)")
    if icon_count:
        print(f"Icons    : {icon_count} loose PNG files")
    else:
        print("Icons    : kept existing bundle icons")
    return 0


if __name__ == "__main__":
    sys.exit(main())
