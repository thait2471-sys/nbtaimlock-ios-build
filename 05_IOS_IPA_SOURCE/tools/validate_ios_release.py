#!/usr/bin/env python3
"""Gate an iOS .ipa before it is published to customers.

An IPA that fails this check cannot be installed on a stock iPhone, so publishing
its URL in Admin would only produce "Không thể cài đặt / Please try again later".

Exit code 0 = installable candidate, 1 = rejected.

Usage:
    python validate_ios_release.py <path-to.ipa> [--json]
"""

import hashlib
import io
import json
import plistlib
import struct
import sys
import zipfile
from datetime import datetime, timezone

CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSMAGIC_BLOBWRAPPER = 0xFADE0B01
CSSLOT_ENTITLEMENTS = 5
CSSLOT_SIGNATURESLOT = 0x10000
CS_ADHOC = 0x00000002
CS_HASHTYPE_SHA256 = 2
PLATFORM_IOS = 2


class Report:
    def __init__(self, path):
        self.path = path
        self.checks = []

    def add(self, name, ok, detail=""):
        self.checks.append({"name": name, "ok": bool(ok), "detail": detail})
        return ok

    @property
    def ok(self):
        return all(c["ok"] for c in self.checks)

    def as_dict(self):
        return {
            "path": self.path,
            "installable": self.ok,
            "checks": self.checks,
            "failed": [c["name"] for c in self.checks if not c["ok"]],
        }


def fail(report, name, detail):
    report.add(name, False, detail)
    print(json.dumps(report.as_dict(), indent=2) if "--json" in sys.argv
          else format_report(report))
    sys.exit(1)


def format_report(report):
    lines = [f"IPA: {report.path}", ""]
    for c in report.checks:
        mark = "PASS" if c["ok"] else "FAIL"
        lines.append(f"  [{mark}] {c['name']}" + (f" — {c['detail']}" if c["detail"] else ""))
    lines.append("")
    lines.append("RESULT: " + ("INSTALLABLE CANDIDATE" if report.ok else "REJECTED"))
    return "\n".join(lines)


def extract_plist(blob):
    """Pull the XML plist out of an Apple CMS/DER blob or a bare plist.

    `embedded.mobileprovision` is a CMS SignedData wrapper whose payload is a
    plaintext XML plist, so the XML is found by scanning rather than assuming
    the file starts with `<?xml`. A bare `.plist` works through the same path.
    """
    start = blob.find(b"<?xml")
    if start < 0:
        start = blob.find(b"<plist")
    if start < 0:
        raise ValueError("no XML plist found in blob")
    end = blob.find(b"</plist>", start)
    if end < 0:
        raise ValueError("plist is truncated (no closing </plist>)")
    return plistlib.loads(blob[start:end + len(b"</plist>")])


def profile_kind(prof_plist):
    """Classify the provisioning profile the way a device would experience it."""
    if prof_plist.get("ProvisionsAllDevices"):
        return "enterprise", "installs on any device (In-House / enterprise)"
    devices = prof_plist.get("ProvisionedDevices") or []
    if devices:
        return "ad-hoc", f"installs only on {len(devices)} registered UDID(s)"
    return "app-store", "App Store profile — no UDID list, cannot be installed directly over OTA"


def parse_macho(binary):
    """Return the Mach-O facts needed by the installability gate.

    The 64-bit Mach-O header is eight 32-bit fields including ``magic``.  Keep
    the unpack format in sync with that layout; accepting a parser exception as
    a signing failure makes the CI gate look successful until a device tries to
    install the IPA.
    """
    if len(binary) < 32:
        raise ValueError("Mach-O header is truncated")
    magic, cputype, _subtype, filetype, ncmds, sizeofcmds, _flags, _reserved = \
        struct.unpack_from("<IiiIIIII", binary, 0)
    if magic != 0xFEEDFACF:
        raise ValueError(f"not a 64-bit Mach-O (magic=0x{magic:08x})")
    command_end = 32 + sizeofcmds
    if command_end > len(binary):
        raise ValueError(
            f"load-command table exceeds Mach-O (end={command_end}, size={len(binary)})"
        )

    info = {
        "cputype": cputype & 0xFFFFFFFF,
        "platform": None,
        "code_sig": None,
        "linkedit": None,
        "ncmds": ncmds,
        "sizeofcmds": sizeofcmds,
        "dylibs": [],
        "swift_sections": [],
    }
    off = 32
    for index in range(ncmds):
        if off + 8 > command_end:
            raise ValueError(f"truncated load command {index} at {off}")
        cmd, cmdsize = struct.unpack_from("<II", binary, off)
        if cmdsize < 8 or cmdsize % 8 or off + cmdsize > command_end:
            raise ValueError(
                f"corrupt load command {index} at {off} (cmdsize={cmdsize})"
            )
        if cmd == 0x19:  # LC_SEGMENT_64
            if cmdsize < 72:
                raise ValueError(f"truncated LC_SEGMENT_64 at {off}")
            segname = binary[off + 8:off + 24].split(b"\x00")[0].decode("ascii", "replace")
            fileoff, filesize = struct.unpack_from("<QQ", binary, off + 40)
            if fileoff + filesize > len(binary):
                raise ValueError(
                    f"segment {segname} exceeds Mach-O (end={fileoff + filesize}, size={len(binary)})"
                )
            if segname == "__LINKEDIT":
                info["linkedit"] = (fileoff, filesize)
            # Walk sections for Swift metadata. A statically linked Swift binary
            # carries no Swift dylib but always has __swift5_* sections, so this
            # is the reliable signal.
            nsects = struct.unpack_from("<I", binary, off + 64)[0]
            sect_off = off + 72
            for _ in range(nsects):
                if sect_off + 80 > off + cmdsize:
                    break
                sect_name = binary[sect_off:sect_off + 16].split(b"\x00")[0]
                if sect_name.startswith(b"__swift5"):
                    info["swift_sections"].append(sect_name.decode("ascii", "replace"))
                sect_off += 80
        elif cmd == 0x32:  # LC_BUILD_VERSION
            if cmdsize < 24:
                raise ValueError(f"truncated LC_BUILD_VERSION at {off}")
            platform, _minos, _sdk, ntools = struct.unpack_from("<IIII", binary, off + 8)
            # 24 bytes fixed + 8 per tool. Padding inside cmdsize is tolerated
            # (some linkers align the command), truncation is not.
            expected = 24 + ntools * 8
            if cmdsize < expected:
                raise ValueError(
                    f"malformed LC_BUILD_VERSION: cmdsize={cmdsize} but ntools={ntools} requires {expected}"
                )
            if info["platform"] is not None and info["platform"] != platform:
                raise ValueError("Mach-O contains conflicting LC_BUILD_VERSION platforms")
            info["platform"] = platform
        elif cmd == 0x1D:  # LC_CODE_SIGNATURE
            if cmdsize < 16:
                raise ValueError(f"truncated LC_CODE_SIGNATURE at {off}")
            if info["code_sig"] is not None:
                raise ValueError("Mach-O contains duplicate LC_CODE_SIGNATURE commands")
            dataoff, datasize = struct.unpack_from("<II", binary, off + 8)
            if not datasize or dataoff + datasize > len(binary):
                raise ValueError(
                    f"code signature exceeds Mach-O (offset={dataoff}, size={datasize}, file={len(binary)})"
                )
            info["code_sig"] = (dataoff, datasize)
        elif cmd in (0xC, 0x8000001F):  # LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB
            name_off = struct.unpack_from("<I", binary, off + 8)[0]
            if name_off < cmdsize:
                raw = binary[off + name_off:off + cmdsize].split(b"\x00")[0]
                info["dylibs"].append(raw.decode("utf-8", "replace"))
        off += cmdsize

    if off != command_end:
        raise ValueError(f"load-command table ends at {off}, expected {command_end}")
    if info["code_sig"] and info["linkedit"]:
        sig_off, sig_size = info["code_sig"]
        link_off, link_size = info["linkedit"]
        if sig_off < link_off or sig_off + sig_size > link_off + link_size:
            raise ValueError("LC_CODE_SIGNATURE is outside __LINKEDIT")
    return info


def parse_superblob(binary, dataoff, datasize):
    if dataoff < 0 or datasize < 12 or dataoff + datasize > len(binary):
        raise ValueError("code signature SuperBlob is outside the Mach-O")
    blob = binary[dataoff:dataoff + datasize]
    magic, length, count = struct.unpack_from(">III", blob, 0)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        raise ValueError(f"bad SuperBlob magic 0x{magic:08x}")
    if length < 12 or length > len(blob):
        raise ValueError(f"invalid SuperBlob length {length} (available {len(blob)})")
    table_end = 12 + count * 8
    if table_end > length:
        raise ValueError("SuperBlob index table is truncated")
    slots = {}
    for i in range(count):
        slot_type, slot_off = struct.unpack_from(">II", blob, 12 + i * 8)
        if slot_off < table_end or slot_off + 8 > length:
            raise ValueError(f"SuperBlob slot {slot_type} points outside the blob")
        slot_magic, slot_length = struct.unpack_from(">II", blob, slot_off)
        if slot_length < 8 or slot_off + slot_length > length:
            raise ValueError(f"SuperBlob slot {slot_type} has invalid length {slot_length}")
        if slot_type in slots:
            raise ValueError(f"duplicate SuperBlob slot {slot_type}")
        slots[slot_type] = {
            "offset": slot_off,
            "length": slot_length,
            "magic": slot_magic,
            "blob": blob,
        }
    return blob[:length], slots


def parse_code_directory(binary, signature_blob, slot, code_sig_offset):
    """Validate the CodeDirectory and every SHA-256 code-page hash.

    Apple may publish two directories: a SHA-1 one in slot 0 for legacy tools
    and SHA-256 alternates from slot 0x1000 upward. The device uses the
    strongest it understands, so this gate must accept the same set rather than
    demanding SHA-256 specifically in slot 0 — that would reject valid binaries.
    """
    cd = signature_blob[slot["offset"]:slot["offset"] + slot["length"]]
    if len(cd) < 40:
        raise ValueError("CodeDirectory is truncated")
    magic, length, version, flags, hash_offset, ident_offset, special_slots, code_slots = \
        struct.unpack_from(">8I", cd, 0)
    if magic != CSMAGIC_CODEDIRECTORY:
        raise ValueError(f"bad CodeDirectory magic 0x{magic:08x}")
    if length < 40 or length > len(cd):
        raise ValueError(f"invalid CodeDirectory length {length}")

    # hashSize/hashType live at offset 36 and must be read before the hash
    # table bounds are computed. Sizing the table with a hard-coded 32 would
    # accept a SHA-1 directory it then "verified" against 32-byte pages.
    hash_size, hash_type, _cd_platform, page_size_exp = struct.unpack_from(">BBBB", cd, 36)
    if hash_size != 32 or hash_type != CS_HASHTYPE_SHA256:
        raise ValueError(
            f"not a SHA-256 directory (size={hash_size}, type={hash_type})"
        )

    if hash_offset < special_slots * hash_size or hash_offset + code_slots * hash_size > length:
        raise ValueError("CodeDirectory hash table is outside the blob")
    if ident_offset >= length:
        raise ValueError("CodeDirectory identifier offset is outside the blob")
    ident_end = cd.find(b"\x00", ident_offset, length)
    if ident_end < 0:
        raise ValueError("CodeDirectory identifier is not NUL terminated")
    identifier = cd[ident_offset:ident_end].decode("utf-8", "replace")

    if page_size_exp > 31:
        raise ValueError(f"invalid CodeDirectory page size exponent {page_size_exp}")
    page_size = 1 << page_size_exp
    code_limit = struct.unpack_from(">I", cd, 32)[0]
    if version >= 0x20300 and length >= 64:
        code_limit_64 = struct.unpack_from(">Q", cd, 56)[0]
        if code_limit_64:
            code_limit = code_limit_64
    if code_limit > code_sig_offset or code_limit > len(binary):
        raise ValueError(
            f"CodeDirectory codeLimit {code_limit} exceeds signed code region"
        )
    expected_slots = (code_limit + page_size - 1) // page_size
    if code_slots != expected_slots:
        raise ValueError(
            f"CodeDirectory nCodeSlots={code_slots} but codeLimit requires {expected_slots}"
        )
    for index in range(code_slots):
        start = index * page_size
        end = min(start + page_size, code_limit)
        expected = hashlib.sha256(binary[start:end]).digest()
        actual_start = hash_offset + index * hash_size
        actual = cd[actual_start:actual_start + hash_size]
        if actual != expected:
            raise ValueError(f"CodeDirectory page hash mismatch at slot {index}")

    team_identifier = ""
    # teamOffset was added in version 0x20200 and follows scatterOffset.
    if version >= 0x20200 and length >= 52:
        team_offset = struct.unpack_from(">I", cd, 48)[0]
        if team_offset:
            if team_offset >= length:
                raise ValueError("CodeDirectory team identifier offset is outside the blob")
            team_end = cd.find(b"\x00", team_offset, length)
            if team_end < 0:
                raise ValueError("CodeDirectory team identifier is not NUL terminated")
            team_identifier = cd[team_offset:team_end].decode("utf-8", "replace")

    return {
        "flags": flags,
        "identifier": identifier,
        "team_identifier": team_identifier,
        "version": version,
        "code_limit": code_limit,
        "code_slots": code_slots,
        "page_size": page_size,
    }


# The reviewed legacy native app: it drives UIKit through the Objective-C
# runtime, so it links exactly these five system libraries and no Swift runtime.
# Kept in sync with tools/verify_unsigned_ipa.py.
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


def legacy_native_problems(binary, macho):
    """Return why this is not the reviewed legacy native app ([] when it is)."""
    problems = []
    if any("swift" in d.lower() for d in macho["dylibs"]):
        problems.append("links the Swift runtime")
    if macho["swift_sections"]:
        problems.append("carries __swift5_* sections")
    linked = set(macho["dylibs"])
    unexpected = sorted(linked - LEGACY_NATIVE_DYLIBS)
    if unexpected:
        problems.append("links unexpected dylibs: " + ", ".join(unexpected))
    missing = sorted(LEGACY_NATIVE_DYLIBS - linked)
    if missing:
        problems.append("does not link: " + ", ".join(missing))
    for marker in LEGACY_NATIVE_MARKERS:
        if marker not in binary:
            problems.append("missing marker " + marker.decode("ascii"))
    return problems



def check_ipa(path, allow_legacy_native=False):
    report = Report(path)

    with open(path, "rb") as fh:
        raw = fh.read()
    report.add("sha256", True, hashlib.sha256(raw).hexdigest())
    report.add("size_bytes", True, str(len(raw)))

    try:
        zf = zipfile.ZipFile(io.BytesIO(raw))
    except zipfile.BadZipFile as exc:
        return report, f"not a valid zip: {exc}"
    bad = zf.testzip()
    if bad:
        return report, f"corrupt zip entry: {bad}"

    names = zf.namelist()
    # Derive the app directory from file entries, not from a "Payload/X.app/"
    # directory record: several packers (and `zip` without -r) omit directory
    # entries, and rejecting a structurally fine IPA because of a missing
    # directory record would block a perfectly installable build.
    app_dirs = sorted({
        "/".join(n.split("/")[:2]) + "/"
        for n in names
        if n.count("/") >= 2 and n.split("/")[0] == "Payload" and n.split("/")[1].endswith(".app")
    })
    if len(app_dirs) != 1:
        return report, f"expected exactly one Payload/*.app, found {app_dirs}"
    app_dir = app_dirs[0]
    report.add("bundle_root", True, app_dir)

    # AppleDouble / resource-fork entries are a documented cause of
    # "Unable to Install, please try again later" — the device refuses to treat
    # the archive as a valid bundle.
    junk = [n for n in names if "__MACOSX" in n or "/._" in n or n.startswith("._")]
    report.add(
        "no_resource_fork_entries",
        not junk,
        "clean" if not junk else f"{len(junk)} junk entry/entries, e.g. {junk[:3]}",
    )
    if junk:
        return report, "archive contains __MACOSX / AppleDouble entries — repack with ditto --norsrc"


    info_name = app_dir + "Info.plist"
    if info_name not in names:
        return report, "Info.plist missing from bundle"
    info = plistlib.loads(zf.read(info_name))
    report.add("info_plist", True, "parsed")

    bundle_id = info.get("CFBundleIdentifier", "")
    report.add("bundle_id", bundle_id == "com.nbtaimlock.ios", bundle_id)

    exe = info.get("CFBundleExecutable", "")
    exe_name = app_dir + exe
    if exe_name not in names:
        return report, f"CFBundleExecutable {exe!r} not present in bundle"
    report.add("executable_present", True, exe)

    platforms = info.get("CFBundleSupportedPlatforms")
    report.add(
        "supported_platforms",
        isinstance(platforms, list) and "iPhoneOS" in platforms,
        str(platforms),
    )

    profile_name = app_dir + "embedded.mobileprovision"
    if profile_name not in names:
        # Two very different files reach this branch. A clean unsigned IPA is a
        # valid ESign / Sideloadly input and must be judged by
        # verify_unsigned_ipa.py instead. A build intended for OTA install must
        # carry the profile; without it iOS refuses with "Cannot install".
        signed_markers = [n for n in names if n.endswith("/_CodeSignature/CodeResources")]
        if not signed_markers:
            return report, (
                "embedded.mobileprovision missing — this looks like a clean UNSIGNED "
                "sideload input. Validate it with verify_unsigned_ipa.py. A build for "
                "OTA install must be signed first."
            )
        return report, "embedded.mobileprovision missing — device cannot authorise this build"
    profile = zf.read(profile_name)
    report.add("provisioning_profile", len(profile) > 0, f"{len(profile)} bytes")
    try:
        prof_plist = extract_plist(profile)
    except Exception as exc:
        return report, f"provisioning profile plist unparseable: {exc}"
    report.add("profile_plist", True, "parsed")

    kind, kind_detail = profile_kind(prof_plist)
    report.add("profile_kind", kind in ("enterprise", "ad-hoc"), f"{kind} — {kind_detail}")
    report.add(
        "profile_entitlements",
        isinstance(prof_plist.get("Entitlements"), dict),
        "Entitlements present" if isinstance(prof_plist.get("Entitlements"), dict) else "missing",
    )
    expires = prof_plist.get("ExpirationDate")
    not_expired = False
    if isinstance(expires, datetime):
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=timezone.utc)
        not_expired = expires > datetime.now(timezone.utc)
    report.add(
        "profile_expiry",
        not_expired,
        f"expires {expires}" if expires else "missing ExpirationDate",
    )
    profile_uuid = str(prof_plist.get("UUID", "")).strip()
    report.add("profile_uuid", bool(profile_uuid), profile_uuid or "missing UUID")
    profile_app_id = str((prof_plist.get("Entitlements") or {}).get("application-identifier", ""))
    profile_suffix = profile_app_id.split(".", 1)[-1] if "." in profile_app_id else ""
    profile_is_wildcard = profile_suffix == "*" or profile_suffix.endswith(".*")
    report.add(
        "profile_app_identifier",
        profile_suffix == "com.nbtaimlock.ios" or profile_is_wildcard,
        profile_app_id + (" (wildcard)" if profile_is_wildcard else ""),
    )

    binary = zf.read(exe_name)
    try:
        macho = parse_macho(binary)
    except ValueError as exc:
        return report, str(exc)
    report.add("macho_arm64", macho["cputype"] == 0x0100000C, f"cputype=0x{macho['cputype']:08x}")
    report.add(
        "macho_ios_platform",
        macho["platform"] == PLATFORM_IOS,
        f"platform={macho['platform']} (2=iOS, 1=macOS)",
    )

    # A Swift class is registered with its module prefix. If the app is Swift
    # but UIApplicationSceneManifest names a bare class such as "SceneDelegate",
    # NSClassFromString returns nil and the app launches to a black screen —
    # which users report as "installed but broken".
    links_swift_runtime = any("swift" in d.lower() for d in macho["dylibs"])
    is_swift = links_swift_runtime or bool(macho["swift_sections"])
    scene_manifest = info.get("UIApplicationSceneManifest") or {}
    scene_classes = []
    for role, configs in (scene_manifest.get("UISceneConfigurations") or {}).items():
        for entry in configs or []:
            name = entry.get("UISceneDelegateClassName") or ""
            if name:
                scene_classes.append(name)
    if is_swift and scene_classes:
        bare = [c for c in scene_classes if "." not in c and "$" not in c]
        report.add(
            "scene_delegate_module_qualified",
            not bare,
            "ok: " + ", ".join(scene_classes)
            if not bare
            else f"{bare} must be '<Module>.{bare[0]}' for a Swift build",
        )

    if not macho["code_sig"]:
        return report, "LC_CODE_SIGNATURE missing — build is unsigned"

    dataoff, datasize = macho["code_sig"]
    try:
        blob, slots = parse_superblob(binary, dataoff, datasize)
    except ValueError as exc:
        return report, str(exc)

    cd_slot = slots.get(0)
    if not cd_slot:
        return report, "CodeDirectory missing from signature"
    # Prefer the SHA-256 directory. Slot 0 is often SHA-1 for legacy tooling,
    # with the SHA-256 copy published as an alternate (0x1000+).
    candidate_slots = [0] + sorted(
        s for s in slots if isinstance(s, int) and 0x1000 <= s < 0x1005
    )
    code_directory = None
    cd_errors = []
    for candidate in candidate_slots:
        slot = slots.get(candidate)
        if not slot:
            continue
        try:
            code_directory = parse_code_directory(binary, blob, slot, dataoff)
            break
        except ValueError as exc:
            cd_errors.append(f"slot {candidate}: {exc}")
    if code_directory is None:
        return report, "CodeDirectory invalid: " + "; ".join(cd_errors)
    report.add(
        "code_directory_pages",
        True,
        f"{code_directory['code_slots']} page(s) @ {code_directory['page_size']}B, "
        f"codeLimit={code_directory['code_limit']}, version=0x{code_directory['version']:x}",
    )
    cd_flags = code_directory["flags"]
    report.add(
        "not_adhoc_signed",
        not (cd_flags & CS_ADHOC),
        f"cdFlags=0x{cd_flags:08x}" + (" (CS_ADHOC)" if cd_flags & CS_ADHOC else ""),
    )
    report.add(
        "code_directory_identifier",
        code_directory["identifier"] == "com.nbtaimlock.ios",
        code_directory["identifier"] or "missing",
    )

    cms = slots.get(CSSLOT_SIGNATURESLOT)
    cms_ok = False
    cms_detail = "missing — Apple cannot verify the signer"
    if cms and cms["magic"] == CSMAGIC_BLOBWRAPPER:
        cms_body = blob[cms["offset"] + 8:cms["offset"] + cms["length"]]
        if not cms_body:
            cms_detail = "CMS wrapper is empty — the signature slot carries no certificate"
        elif cms_body[0] != 0x30:
            cms_detail = (
                f"CMS payload is not a DER SEQUENCE (first byte 0x{cms_body[0]:02x}) — "
                "the slot holds something other than a CMS SignedData"
            )
        else:
            # OID 1.2.840.113549.1.7.2 (signedData) encoded in DER. An ad-hoc or
            # placeholder signature never contains it, and such an IPA installs
            # but cannot be launched, or is rejected outright.
            signed_data_oid = b"\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x07\x02"
            if signed_data_oid not in cms_body:
                cms_detail = "CMS payload lacks the signedData OID — not an Apple signature"
            else:
                cms_ok = True
                cms_detail = f"CMS SignedData present ({len(cms_body)} bytes)"
    report.add("apple_cms_signature", cms_ok, cms_detail)

    ent = slots.get(CSSLOT_ENTITLEMENTS)
    if not ent:
        return report, "embedded entitlements missing"
    report.add(
        "entitlements_blob_magic",
        ent["magic"] == CSMAGIC_EMBEDDED_ENTITLEMENTS,
        f"0x{ent['magic']:08x} (must be 0x{CSMAGIC_EMBEDDED_ENTITLEMENTS:08x})",
    )
    try:
        entitlements_slot = blob[ent["offset"]:ent["offset"] + ent["length"]]
        entitlements = extract_plist(entitlements_slot)
    except Exception as exc:
        return report, f"embedded entitlements unparseable: {exc}"
    report.add("embedded_entitlements", True, "parsed")

    # The signature, the embedded entitlements and the profile are three
    # independent records that a device cross-checks. Any disagreement means
    # amfid rejects the launch even when the IPA installs.
    profile_team = str(prof_plist.get("TeamIdentifier", [""])[0]) if prof_plist.get("TeamIdentifier") else ""
    cd_team = code_directory["team_identifier"]
    report.add(
        "signature_team_matches_profile",
        bool(profile_team) and cd_team == profile_team,
        f"signature team={cd_team or 'missing'}, profile team={profile_team or 'missing'}",
    )

    # A development profile legitimately carries get-task-allow=true and still
    # installs on the UDIDs listed in the profile. Only a build that claims
    # get-task-allow but has no provisioned devices is suspicious.
    has_provisioned_devices = bool(prof_plist.get("ProvisionedDevices") or [])
    report.add(
        "get_task_allow_installable",
        entitlements.get("get-task-allow") is not True or has_provisioned_devices,
        f"get-task-allow={entitlements.get('get-task-allow')}, provisioned_devices={len(prof_plist.get('ProvisionedDevices') or [])}",
    )
    app_id = str(entitlements.get("application-identifier", ""))
    report.add(
        "application_identifier_team_prefixed",
        "." in app_id and app_id.split(".", 1)[1] == "com.nbtaimlock.ios" and len(app_id.split(".", 1)[0]) >= 8,
        app_id,
    )
    report.add(
        "team_identifier_present",
        bool(entitlements.get("com.apple.developer.team-identifier")),
        str(entitlements.get("com.apple.developer.team-identifier", "")),
    )
    # A signature whose embedded entitlements name a different team than the
    # profile is rejected by amfid at launch even though the IPA installs. The
    # launcher then shows a dead icon, which customers report as a broken app.
    ent_team = str(entitlements.get("com.apple.developer.team-identifier", ""))
    report.add(
        "entitlement_team_matches_profile",
        bool(profile_team) and ent_team == profile_team,
        f"entitlements team={ent_team or 'missing'}, profile team={profile_team or 'missing'}",
    )

    # Entitlements must match the profile the device will verify against.
    prof_ents = prof_plist.get("Entitlements") or {}
    prof_app_id = str(prof_ents.get("application-identifier", ""))
    prof_suffix = prof_app_id.split(".", 1)[-1] if "." in prof_app_id else ""
    prof_wildcard = prof_suffix == "*" or prof_suffix.endswith(".*")
    wildcard_match = False
    if prof_wildcard and "." in app_id and "." in prof_app_id:
        wildcard_match = app_id.split(".", 1)[0] == prof_app_id.split(".", 1)[0] and app_id.split(".", 1)[1] == "com.nbtaimlock.ios"
    report.add(
        "entitlements_match_profile",
        prof_app_id == app_id or wildcard_match,
        f"profile={prof_app_id}{' (wildcard)' if prof_wildcard else ''} bundle={app_id}",
    )

    resources_name = app_dir + "_CodeSignature/CodeResources"
    report.add("code_resources", resources_name in names,
               "present" if resources_name in names else "missing")

    # Identity of the code that is about to be published. The target app is
    # Swift/SwiftUI; the compact legacy native app is the one that has actually
    # been distributed and is accepted only on explicit request, and only when
    # every marker and dylib matches. A binary that is neither is a foreign
    # artifact and must not ship.
    if is_swift:
        report.add("binary_is_swift_build", True, "Swift runtime/metadata present")
        report.add("build_kind", True, "swift")
    elif allow_legacy_native:
        problems = legacy_native_problems(binary, macho)
        report.add(
            "build_kind",
            not problems,
            "legacy-native" if not problems else "legacy native identity mismatch: " + "; ".join(problems),
        )
    else:
        report.add(
            "binary_is_swift_build",
            False,
            "no Swift runtime or __swift5 metadata - this binary predates the "
            "Swift/SwiftUI sources (re-run with --legacy-native if it is the "
            "reviewed legacy app)",
        )

    return report, None


def main():
    # Flags may appear before or after the path (`--legacy-native x.ipa` is as
    # natural as `x.ipa --legacy-native`). Taking sys.argv[1] blindly made the
    # flag itself the path and crashed with FileNotFoundError instead of
    # reporting anything useful.
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not args:
        print(__doc__)
        sys.exit(2)
    # Windows consoles default to a legacy code page; keep the report readable.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    path = args[0]
    report, fatal = check_ipa(path, allow_legacy_native="--legacy-native" in sys.argv)
    if fatal:
        report.add("fatal", False, fatal)
    out = json.dumps(report.as_dict(), indent=2) if "--json" in sys.argv else format_report(report)
    print(out)
    sys.exit(0 if report.ok else 1)


if __name__ == "__main__":
    main()
