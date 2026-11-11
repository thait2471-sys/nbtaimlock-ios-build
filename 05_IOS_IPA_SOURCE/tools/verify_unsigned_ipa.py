#!/usr/bin/env python3
"""Structural gate for an unsigned (sideload-input) iOS IPA."""

from __future__ import annotations

import argparse
import plistlib
import struct
import sys
import zipfile
from pathlib import Path, PurePosixPath

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 0x2
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x02
LC_DYSYMTAB = 0x0B
LC_CODE_SIGNATURE = 0x1D
LC_FUNCTION_STARTS = 0x26
LC_DATA_IN_CODE = 0x29
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_MAIN = 0x80000028
LC_BUILD_VERSION = 0x32
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F

REQUIRED_ICONS = {
    "AppIcon60x60@2x.png",
    "AppIcon60x60@3x.png",
    "AppIcon76x76@2x.png",
    "AppIcon83.5x83.5@2x.png",
}

# The repository ships two app implementations:
#
#   * Swift/SwiftUI (NBTAimlock/**/*.swift) - the target app, compiled by Xcode
#     and signed by sign-ios.yml. It always links libswiftCore.dylib.
#   * Legacy native - the compact app that has actually been distributed. It
#     drives UIKit/Foundation through the Objective-C runtime, so its Mach-O
#     links only the five system libraries below and carries no Swift metadata.
#
# A binary that is neither is not from this repository and must never be packed
# into a release. --legacy-native therefore does not mean "accept any non-Swift
# binary": it means "accept exactly the reviewed legacy app", and the identity
# below is what makes that check positive rather than a wildcard.
LEGACY_NATIVE_DYLIBS = frozenset({
    "/usr/lib/libSystem.B.dylib",
    "/System/Library/Frameworks/Foundation.framework/Foundation",
    "/System/Library/Frameworks/UIKit.framework/UIKit",
    "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
    "/System/Library/Frameworks/Security.framework/Security",
})

# Strings only the legacy app embeds: its screen controller class, its two
# Objective-C runtime class names, and the licence endpoints it talks to.
LEGACY_NATIVE_MARKERS = (
    b"NABATIMainViewController",
    b"AppDelegate",
    b"SceneDelegate",
    b"/api/license/authorize",
    b"/api/heartbeat",
)



class Failure(Exception):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def parse_commands(macho: bytes):
    check(len(macho) >= 32, "Mach-O too small")
    magic, cputype, _, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<IiiIIIII", macho, 0)
    check(magic == MH_MAGIC_64, "not 64-bit little-endian Mach-O")
    check((cputype & 0xFFFFFFFF) == CPU_TYPE_ARM64, "not arm64")
    check(filetype == MH_EXECUTE, "not MH_EXECUTE")
    check(bool(flags & 0x200000), "MH_PIE is not set")
    commands = []
    offset = 32
    for _ in range(ncmds):
        check(offset + 8 <= len(macho), "truncated command table")
        cmd, size = struct.unpack_from("<II", macho, offset)
        check(size >= 8 and offset + size <= len(macho), f"bad command size {size}")
        commands.append((cmd, size, offset))
        offset += size
    check(offset == 32 + sizeofcmds, "sizeofcmds mismatch")
    return commands, offset


def verify_macho(macho: bytes) -> dict:
    commands, table_end = parse_commands(macho)
    check(all(cmd != LC_CODE_SIGNATURE for cmd, _, _ in commands), "LC_CODE_SIGNATURE still present")

    segments = []
    sections = []
    dylibs = []
    entryoff = None
    minos = None
    platform = None
    lowest = None
    for cmd, size, offset in commands:
        if cmd == LC_SEGMENT_64:
            name = macho[offset + 8:offset + 24].rstrip(b"\x00").decode("ascii", "replace")
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", macho, offset + 24)
            segments.append((name, vmaddr, vmsize, fileoff, filesize))
            check(fileoff + filesize <= len(macho), f"segment {name} exceeds file")
            nsects = struct.unpack_from("<I", macho, offset + 64)[0]
            sect = offset + 72
            for _ in range(nsects):
                check(sect + 80 <= offset + size, "section table overflow")
                sect_name = macho[sect:sect + 16].rstrip(b"\x00").decode("ascii", "replace")
                seg_name = macho[sect + 16:sect + 32].rstrip(b"\x00").decode("ascii", "replace")
                addr, ssize = struct.unpack_from("<QQ", macho, sect + 32)
                file_offset = struct.unpack_from("<I", macho, sect + 48)[0]
                if file_offset:
                    check(file_offset + ssize <= len(macho), f"section {seg_name}.{sect_name} exceeds file")
                    lowest = file_offset if lowest is None else min(lowest, file_offset)
                sections.append((seg_name, sect_name, addr, ssize, file_offset))
                sect += 80
            if fileoff:
                lowest = fileoff if lowest is None else min(lowest, fileoff)
        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", macho, offset + 8)
            check(symoff + nsyms * 16 <= len(macho), "symtab exceeds file")
            check(stroff + strsize <= len(macho), "string table exceeds file")
        elif cmd == LC_DYSYMTAB:
            fields = struct.unpack_from("<18I", macho, offset + 8)
            for value in (fields[6], fields[8], fields[10], fields[12], fields[14], fields[16]):
                if value:
                    check(value < len(macho), "dysymtab offset exceeds file")
        elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            fields = struct.unpack_from("<10I", macho, offset + 8)
            for value in (fields[0], fields[2], fields[4], fields[6], fields[8]):
                if value:
                    check(value < len(macho), "dyld info offset exceeds file")
        elif cmd in (LC_FUNCTION_STARTS, LC_DATA_IN_CODE):
            dataoff = struct.unpack_from("<I", macho, offset + 8)[0]
            if dataoff:
                check(dataoff < len(macho), "data offset exceeds file")
        elif cmd == LC_MAIN:
            entryoff = struct.unpack_from("<Q", macho, offset + 8)[0]
            check(entryoff < len(macho), "entryoff exceeds file")
            text_vmaddr = next((seg[1] for seg in segments if seg[0] == "__TEXT"), None)
            check(text_vmaddr is not None, "missing __TEXT segment")
            entry_addr = text_vmaddr + entryoff
            check(any(sect_name == "__text" and addr <= entry_addr < addr + ssize
                      for _, sect_name, addr, ssize, _ in sections), "entry point outside __text")
        elif cmd == LC_BUILD_VERSION:
            platform, minos_raw, _, _ = struct.unpack_from("<IIII", macho, offset + 8)
            minos = f"{(minos_raw >> 16) & 0xFFFF}.{(minos_raw >> 8) & 0xFF}.{minos_raw & 0xFF}"
        elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            # A build compiled from Swift always links libswiftCore.dylib (or, if
            # it were statically linked, carries __swift5_* sections). Reading the
            # dylib list lets the gate reject a stale non-Swift binary that was
            # packed into the bundle, which is exactly the failure that shipped
            # as "Không thể cài đặt" while every structural check passed.
            name_off = struct.unpack_from("<I", macho, offset + 8)[0]
            if 0 < name_off < size:
                raw = macho[offset + name_off:offset + size].split(b"\x00")[0]
                dylibs.append(raw.decode("utf-8", "replace"))

    check(platform == 2, "LC_BUILD_VERSION platform is not iOS (2)")
    check(entryoff is not None, "LC_MAIN missing")
    linkedit = [seg for seg in segments if seg[0] == "__LINKEDIT"]
    check(len(linkedit) == 1, "__LINKEDIT missing")
    check(linkedit[0][3] + linkedit[0][4] == len(macho), "file does not end at __LINKEDIT")
    check(lowest is not None and table_end <= lowest, "load commands overlap content")
    return {
        "size": len(macho),
        "segments": len(segments),
        "sections": len(sections),
        "dylibs": dylibs,
        "swift_sections": [s[1] for s in sections if s[1].startswith("__swift5")],
        "minos": minos,
        "entryoff": entryoff,
    }


def legacy_native_problems(macho: bytes, info: dict) -> list[str]:
    """Return why macho is not the reviewed legacy native app ([] when it is)."""
    problems = []
    if any("swift" in d.lower() for d in info["dylibs"]):
        problems.append("links the Swift runtime")
    if info["swift_sections"]:
        problems.append("carries __swift5_* sections")
    linked = set(info["dylibs"])
    unexpected = sorted(linked - LEGACY_NATIVE_DYLIBS)
    if unexpected:
        problems.append("links unexpected dylibs: " + ", ".join(unexpected))
    missing = sorted(LEGACY_NATIVE_DYLIBS - linked)
    if missing:
        problems.append("does not link: " + ", ".join(missing))
    for marker in LEGACY_NATIVE_MARKERS:
        if marker not in macho:
            problems.append("missing marker " + marker.decode("ascii"))
    if info["minos"] != "14.0.0":
        problems.append("LC_BUILD_VERSION minos is " + str(info["minos"]))
    return problems


def verify_ipa(path: Path, allow_legacy_native: bool = False) -> dict:
    check(path.is_file(), f"not a file: {path}")
    with zipfile.ZipFile(path) as zf:
        bad = zf.testzip()
        check(bad is None, f"corrupt zip entry: {bad}")
        names = zf.namelist()
        roots = {PurePosixPath(name).parts[0] for name in names if PurePosixPath(name).parts}
        check(roots == {"Payload"}, f"unexpected zip roots: {sorted(roots)}")
        apps = sorted({PurePosixPath(name).parts[1] for name in names
                       if len(PurePosixPath(name).parts) >= 2 and PurePosixPath(name).parts[0] == "Payload"})
        check(len(apps) == 1 and apps[0].endswith(".app"), f"expected one Payload/app, got {apps}")
        app = apps[0]
        prefix = f"Payload/{app}/"
        check(any(name.startswith(prefix) for name in names), "app directory empty")
        for name in names:
            if name.startswith(prefix):
                info = zf.getinfo(name)
                mode = (info.external_attr >> 16) & 0o777
                if name.endswith("/"):
                    check(mode in (0o755, 0o775, 0o777), f"dir mode {oct(mode)} on {name}")
                else:
                    check(mode in (0o644, 0o755), f"file mode {oct(mode)} on {name}")
        check(not any("_CodeSignature" in name for name in names), "_CodeSignature still in IPA")
        check(not any(name.endswith("embedded.mobileprovision") for name in names), "profile still in IPA")
        check(not any("SC_Info" in name for name in names), "SC_Info still in IPA")
        check(not any("__MACOSX" in name for name in names), "__MACOSX folder in IPA")

        info = plistlib.loads(zf.read(prefix + "Info.plist"))
        check(info.get("CFBundleIdentifier") == "com.nbtaimlock.ios", "wrong CFBundleIdentifier")
        check(info.get("CFBundleExecutable") == "NBTAimlock", "wrong CFBundleExecutable")
        check("iPhoneOS" in info.get("CFBundleSupportedPlatforms", []), "CFBundleSupportedPlatforms missing")
        check("arm64" in info.get("UIRequiredDeviceCapabilities", []), "UIRequiredDeviceCapabilities missing")
        check(info.get("MinimumOSVersion") == "14.0", "MinimumOSVersion is not 14.0")
        check(info.get("CFBundlePackageType") == "APPL", "CFBundlePackageType is not APPL")
        check(isinstance(info.get("UILaunchScreen"), dict), "UILaunchScreen missing")
        check(info.get("UIDeviceFamily") == [1, 2], "UIDeviceFamily changed")

        icons_declared = set(info.get("CFBundleIconFiles", []))
        for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
            primary = info.get(key, {}).get("CFBundlePrimaryIcon", {})
            icons_declared.update(primary.get("CFBundleIconFiles", []))
        for base in icons_declared:
            check(any(name.startswith(prefix + base) for name in names), f"declared icon {base} missing")

        # Two legitimate layouts exist and both must pass this gate:
        #   * Xcode build  — icons compiled into Assets.car, Info.plist declares
        #                    CFBundleIconName="AppIcon" and has no loose PNGs.
        #   * repacked build — loose AppIcon*.png files declared via
        #                    CFBundleIconFiles / CFBundleIcons.
        # Demanding loose PNGs would reject every real Xcode build; accepting a
        # CFBundleIconName without Assets.car would ship an iconless bundle.
        icon_name = info.get("CFBundleIconName")
        has_asset_catalog = prefix + "Assets.car" in names
        if isinstance(icon_name, str) and icon_name:
            check(
                has_asset_catalog,
                f"CFBundleIconName={icon_name!r} declared but Assets.car is missing",
            )
        else:
            for required in REQUIRED_ICONS:
                check(prefix + required in names, f"missing icon file {required}")

        binary_name = info.get("CFBundleExecutable", "NBTAimlock")
        check(prefix + binary_name in names, "executable missing")
        macho = zf.read(prefix + binary_name)
        binary_info = verify_macho(macho)
        # An unsigned IPA whose binary carries no Swift runtime and no __swift5_*
        # sections was packed from something other than the Swift app. That is
        # either a stale foreign artifact (rejected) or the reviewed legacy
        # native app (allowed only on explicit request, and only when its
        # identity matches exactly).
        is_swift_build = any("swift" in d.lower() for d in binary_info["dylibs"]) or             bool(binary_info["swift_sections"])
        if is_swift_build:
            binary_info["build"] = "swift"
        elif allow_legacy_native:
            problems = legacy_native_problems(macho, binary_info)
            check(
                not problems,
                "legacy native build does not match the reviewed app: " + "; ".join(problems),
            )
            binary_info["build"] = "legacy-native"
        else:
            raise Failure(
                "binary has no Swift runtime or __swift5 metadata - it is not the Swift "
                "build this repository ships (the stale Objective-C binary packs into a "
                "structurally valid IPA but runs the wrong code). If this is the reviewed "
                "legacy native app, re-run with --legacy-native."
            )

        binary_info["zip_entries"] = len(names)
        binary_info["icons_declared"] = sorted(icons_declared)
        binary_info["bundle"] = app
        return binary_info


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Verify an unsigned IPA ready for re-signing")
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--legacy-native",
        action="store_true",
        help="accept the reviewed legacy native app instead of the Swift build",
    )
    args = parser.parse_args(argv)
    try:
        result = verify_ipa(args.ipa, allow_legacy_native=args.legacy_native)
    except Failure as exc:
        print(f"FAIL: {exc}")
        return 1
    if args.json:
        import json
        print(json.dumps(result, indent=2))
    else:
        bundle = result["bundle"]
        size = result["size"]
        segments = result["segments"]
        sections = result["sections"]
        minos = result["minos"]
        entryoff = result["entryoff"]
        entries = result["zip_entries"]
        icons = result["icons_declared"]
        print("PASS")
        print(f"  build       : {result['build']}")
        print(f"  bundle      : Payload/{bundle}")
        print(f"  mach-o      : {size:,} bytes, {segments} segments, {sections} sections")
        print(f"  min iOS     : {minos}")
        print(f"  entryoff    : {entryoff}")
        print(f"  zip entries : {entries}")
        print(f"  icons       : {len(icons)} prefixes declared")
    return 0


if __name__ == "__main__":
    sys.exit(main())
