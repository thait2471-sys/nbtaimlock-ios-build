#!/usr/bin/env python3
"""Regression tests for the iOS IPA build/signing gates.

These tests intentionally use the checked-in unsigned IPA as a structural fixture.
They never create a signing identity, provisioning profile, KEY, or production
artifact.  A real Apple CMS signature can only be produced on macOS with the
team's certificate and provisioning profile.
"""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path


SOURCE_ROOT = Path(__file__).resolve().parents[1]
TOOLS_ROOT = SOURCE_ROOT / "tools"
IPA_PATH = SOURCE_ROOT / "nbtaimlock-release-unsigned.ipa"

# The IPA checked into this repository is a legacy Objective-C bundle. It is a
# useful structural fixture (real arm64 Mach-O, real archive layout) but it is
# *not* the app this repository ships, and the unsigned gate now rejects it on
# purpose. Tests about packaging therefore run against a copy whose binary
# carries the one load command a Swift build always has.
SWIFT_DYLIB = "/usr/lib/swift/libswiftCore.dylib"


def load_tool(name: str):
    path = TOOLS_ROOT / name
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_fixture(source: Path, mutate=None) -> Path:
    """Copy an IPA to a temporary path, optionally replacing its entries."""
    tmp = tempfile.NamedTemporaryFile(prefix="nbt-ipa-test-", suffix=".ipa", delete=False)
    tmp.close()
    output = Path(tmp.name)
    with zipfile.ZipFile(source, "r") as src, zipfile.ZipFile(output, "w") as dst:
        seen = set()
        for item in src.infolist():
            name = item.filename
            data = src.read(name)
            if mutate:
                replacement = mutate(name, data)
                if replacement is None:
                    continue
                data = replacement
            dst.writestr(item, data)
            seen.add(name)
        if mutate:
            for name, data in mutate("__ADD__", b"") or []:
                if name not in seen:
                    info = zipfile.ZipInfo(name)
                    info.create_system = 3
                    info.external_attr = (0o100644 if not name.endswith("/") else 0o40755) << 16
                    dst.writestr(info, data)
    return output


def add_dylib_command(binary: bytes, dylib: str) -> bytes:
    """Write an LC_LOAD_DYLIB into the Mach-O header padding, in place.

    Real Swift binaries link libswiftCore.dylib; the checked-in fixture is an
    Objective-C build. Patching the load-command table is what lets the
    packaging tests exercise the Swift gate without a Mac.

    The command is written into the slack between the end of the command table
    and the first section, and the file length is left untouched: inserting
    bytes would shift every section and make the fixture structurally invalid.
    """
    buf = bytearray(binary)
    magic, _ct, _st, _ft, ncmds, sizeofcmds, _fl, _rs = struct.unpack_from("<IiiIIIII", buf, 0)
    if magic != 0xFEEDFACF:
        raise AssertionError("fixture is not a 64-bit little-endian Mach-O")
    name = dylib.encode("utf-8") + b"\x00"
    cmdsize = (24 + len(name) + 7) // 8 * 8
    command = bytearray(cmdsize)
    struct.pack_into("<IIIIII", command, 0, 0xC, cmdsize, 24, 0, 0x10000, 0x10000)
    command[24:24 + len(name)] = name

    end = 32 + sizeofcmds
    # Lowest real content offset: first section or segment with a file range.
    lowest = None
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", buf, off)
        if cmd == 0x19:
            # segment_command_64: segname@8, vmaddr@24, vmsize@32, fileoff@40.
            fileoff = struct.unpack_from("<Q", buf, off + 40)[0]
            if fileoff:
                lowest = fileoff if lowest is None else min(lowest, fileoff)
            nsects = struct.unpack_from("<I", buf, off + 64)[0]
            sect = off + 72
            for _ in range(nsects):
                sect_off = struct.unpack_from("<I", buf, sect + 48)[0]
                if sect_off:
                    lowest = sect_off if lowest is None else min(lowest, sect_off)
                sect += 80
        off += size
    if lowest is None or end + cmdsize > lowest:
        raise AssertionError("no header padding for an extra load command")

    buf[end:end + cmdsize] = command
    struct.pack_into("<I", buf, 16, ncmds + 1)
    struct.pack_into("<I", buf, 20, sizeofcmds + cmdsize)
    return bytes(buf)


def swift_fixture(mutate=None) -> Path:
    """Copy of the structural fixture whose binary carries the Swift dylib."""
    app_prefix = "Payload/NBTAimlock.app/"

    def patched(name, data):
        if name == app_prefix + "NBTAimlock":
            return add_dylib_command(data, SWIFT_DYLIB)
        return mutate(name, data) if mutate else data

    return write_fixture(IPA_PATH, patched)


class IosIpaToolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not IPA_PATH.is_file():
            raise unittest.SkipTest(f"missing structural fixture: {IPA_PATH}")
        cls.validator = load_tool("validate_ios_release.py")
        cls.unsigned = load_tool("verify_unsigned_ipa.py")

    def test_macho_header_parser_accepts_arm64_fixture(self):
        with zipfile.ZipFile(IPA_PATH) as ipa:
            binary = ipa.read("Payload/NBTAimlock.app/NBTAimlock")
        info = self.validator.parse_macho(binary)
        self.assertEqual(info["cputype"], 0x0100000C)
        self.assertEqual(info["platform"], 2)
        self.assertIsNone(info["code_sig"])

    def test_unsigned_fixture_is_rejected_by_signed_gate_with_actionable_message(self):
        result = subprocess.run(
            [sys.executable, str(TOOLS_ROOT / "validate_ios_release.py"), str(IPA_PATH), "--json"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("clean UNSIGNED sideload input", result.stdout)
        self.assertNotIn("too many values to unpack", result.stdout)

    def test_validator_cli_accepts_the_flag_before_the_path(self):
        """`--legacy-native x.ipa` must not be read as a file named --legacy-native."""
        for argv in (
            ["--legacy-native", str(IPA_PATH)],
            [str(IPA_PATH), "--legacy-native"],
        ):
            result = subprocess.run(
                [sys.executable, str(TOOLS_ROOT / "validate_ios_release.py"), *argv],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=False,
            )
            self.assertNotIn("Traceback", result.stderr, argv)
            self.assertIn("clean UNSIGNED sideload input", result.stdout, argv)

    def test_unsigned_fixture_passes_unsigned_gate(self):
        fixture = swift_fixture()
        self.addCleanup(fixture.unlink, missing_ok=True)
        result = self.unsigned.verify_ipa(fixture)
        self.assertEqual(result["bundle"], "NBTAimlock.app")
        self.assertEqual(result["minos"], "14.0.0")

    def test_legacy_objc_fixture_is_rejected_by_unsigned_gate(self):
        """The checked-in IPA is the ObjC build that shipped as 'Không thể cài đặt'.

        Every structural check passes on it, so without the Swift gate a stale
        bundle would be published as a release. This pins that rejection.
        """
        with self.assertRaises(self.unsigned.Failure) as ctx:
            self.unsigned.verify_ipa(IPA_PATH)
        self.assertIn("no Swift runtime", str(ctx.exception))

    def test_reviewed_legacy_app_passes_with_explicit_flag(self):
        """--legacy-native accepts the reviewed legacy app when asked explicitly."""
        result = self.unsigned.verify_ipa(IPA_PATH, allow_legacy_native=True)
        self.assertEqual(result["build"], "legacy-native")
        self.assertEqual(result["minos"], "14.0.0")
        self.assertIn("/System/Library/Frameworks/UIKit.framework/UIKit", result["dylibs"])

    def test_legacy_mode_still_rejects_an_unreviewed_binary(self):
        """The flag is an identity check, not a wildcard for any non-Swift binary."""
        marker = b"NABATIMainViewController"

        def mutate(name, data):
            if name == "Payload/NBTAimlock.app/NBTAimlock":
                at = data.find(marker)
                self.assertGreater(at, 0)
                return data[:at] + bytes(len(marker)) + data[at + len(marker):]
            return data

        fixture = write_fixture(IPA_PATH, mutate)
        self.addCleanup(fixture.unlink, missing_ok=True)
        with self.assertRaises(self.unsigned.Failure) as ctx:
            self.unsigned.verify_ipa(fixture, allow_legacy_native=True)
        self.assertIn("does not match the reviewed app", str(ctx.exception))
        self.assertIn("NABATIMainViewController", str(ctx.exception))

    def test_signing_script_treats_only_a_real_wildcard_as_wildcard(self):
        """A concrete App ID must not be classified as a wildcard.

        The shell glob `*".*"` used to match every concrete identifier
        (com.nbtaimlock.ios), which turned off the bundle-id check and let a
        profile for another app be used. That pair is exactly what iOS answers
        with "Unable to Install, please try again later".
        """
        script = (TOOLS_ROOT / "sign_existing_ipa.sh").read_text(encoding="utf-8")
        self.assertNotIn('== *"."*', script)
        self.assertIn('if [[ "$PROFILE_SUFFIX" == "*" ]]', script)
        # The rule is re-asserted in Python where suffix splitting is exact.
        self.assertIn("suffix == \"*\"", script)
        self.assertIn("suffix != bundle_id", script)

    def test_signing_script_gates_the_legacy_app_instead_of_rejecting_it(self):
        """The final gate must accept the app this script actually signs.

        sign_existing_ipa.sh signs the reviewed legacy native binary, which has
        no Swift runtime. Calling validate_ios_release.py without --legacy-native
        made every successful signing run exit 1 on its last step, so an operator
        who does not check the exit code publishes an IPA the gate rejected.
        The script must decide from the binary, not from an assumption.
        """
        script = (TOOLS_ROOT / "sign_existing_ipa.sh").read_text(encoding="utf-8")
        self.assertIn("GATE_FLAGS+=(--legacy-native)", script)
        # The decision comes from the binary the bundle actually declares, so a
        # mismatched executable name cannot silently pick the wrong gate.
        self.assertIn('info["CFBundleExecutable"]', script)
        self.assertIn('b"libswift" in binary', script)
        # The unpinned call that rejected every successful legacy signing run.
        self.assertNotIn(
            '"\n  --legacy-native "$IPA_OUT"', script,
            "the gate must not pass --legacy-native unconditionally",
        )

    def test_repack_requires_explicit_opt_in_for_the_legacy_binary(self):
        """Packaging must never silently drop a foreign binary into a release."""
        repack = load_tool("repack_sideload_ipa.py")
        with zipfile.ZipFile(IPA_PATH) as ipa:
            binary = ipa.read("Payload/NBTAimlock.app/NBTAimlock")
        with self.assertRaises(SystemExit) as ctx:
            repack.assert_shippable_build(binary, Path("NBTAimlock.app"), False)
        self.assertIn("REFUSING TO PACKAGE", str(ctx.exception))
        self.assertEqual(
            repack.assert_shippable_build(binary, Path("NBTAimlock.app"), True),
            "legacy-native",
        )


    def test_xcode_asset_catalog_bundle_is_accepted_without_loose_pngs(self):
        app_prefix = "Payload/NBTAimlock.app/"

        def mutate(name, data):
            if name == "__ADD__":
                return [(app_prefix + "Assets.car", b"compiled asset catalog")]
            if name == app_prefix + "Info.plist":
                info = plistlib.loads(data)
                info["CFBundleIconName"] = "AppIcon"
                for key in ("CFBundleIconFiles", "CFBundleIcons", "CFBundleIcons~ipad"):
                    info.pop(key, None)
                return plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=False)
            if name.startswith(app_prefix + "AppIcon") and name.endswith(".png"):
                return None
            return data

        fixture = swift_fixture(mutate)
        self.addCleanup(fixture.unlink, missing_ok=True)
        result = self.unsigned.verify_ipa(fixture)
        self.assertEqual(result["bundle"], "NBTAimlock.app")
        self.assertEqual(result["icons_declared"], [])

    def test_profile_present_unsigned_binary_reports_missing_code_signature(self):
        app_prefix = "Payload/NBTAimlock.app/"
        team = "ABCDEFG123"
        profile = {
            "UUID": "00000000-0000-0000-0000-000000000000",
            "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=1),
            "ProvisionedDevices": ["0000000000000000000000000000000000000000"],
            "Entitlements": {
                "application-identifier": f"{team}.com.nbtaimlock.ios",
                "com.apple.developer.team-identifier": team,
            },
        }
        profile_xml = plistlib.dumps(profile, fmt=plistlib.FMT_XML)

        def mutate(name, data):
            if name == "__ADD__":
                return [
                    (app_prefix + "embedded.mobileprovision", profile_xml),
                    (app_prefix + "_CodeSignature/CodeResources", b"<?xml version=\"1.0\"?><plist><dict/></plist>"),
                ]
            return data

        fixture = write_fixture(IPA_PATH, mutate)
        self.addCleanup(fixture.unlink, missing_ok=True)
        result = subprocess.run(
            [sys.executable, str(TOOLS_ROOT / "validate_ios_release.py"), str(fixture), "--json"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("LC_CODE_SIGNATURE missing", result.stdout)
        self.assertNotIn("too many values to unpack", result.stdout)

    def test_app_dir_is_derived_when_zip_has_no_directory_entries(self):
        """`zip` without -r omits directory records; the IPA is still valid."""
        def mutate(name, data):
            if name.endswith("/"):
                return None
            return data

        fixture = swift_fixture(mutate)
        self.addCleanup(fixture.unlink, missing_ok=True)
        with zipfile.ZipFile(fixture) as zf:
            self.assertFalse([n for n in zf.namelist() if n.endswith("/")])
        result = self.unsigned.verify_ipa(fixture)
        self.assertEqual(result["bundle"], "NBTAimlock.app")

    def test_resource_fork_entries_are_rejected(self):
        """__MACOSX / ._* entries make iOS refuse the archive."""
        app_prefix = "Payload/NBTAimlock.app/"

        def mutate(name, data):
            if name == "__ADD__":
                return [("__MACOSX/" + app_prefix + "._Info.plist", b"\x00\x05\x16\x07junk")]
            return data

        fixture = write_fixture(IPA_PATH, mutate)
        self.addCleanup(fixture.unlink, missing_ok=True)
        result = subprocess.run(
            [sys.executable, str(TOOLS_ROOT / "validate_ios_release.py"), str(fixture), "--json"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("__MACOSX", result.stdout)

    # --- synthetic code-signature fixture -----------------------------------
    #
    # The signing path of validate_ios_release.py can be exercised without an
    # Apple certificate by building a Mach-O whose LC_CODE_SIGNATURE contains a
    # real SuperBlob / CodeDirectory with correct SHA-256 page hashes, plus a
    # deliberately invalid CMS slot. That is exactly the shape a broken or
    # ad-hoc signer produces, so it pins the checks that reject such a build.

    def _build_signed_binary(self, adhoc=True, cms_payload=b"placeholder",
                             extra_dylib=None, ents_team="ABCDEFG123"):
        with zipfile.ZipFile(IPA_PATH) as ipa:
            binary = bytearray(ipa.read("Payload/NBTAimlock.app/NBTAimlock"))

        magic, _ct, _st, _ft, ncmds, sizeofcmds, _fl, _rs = struct.unpack_from("<IiiIIIII", binary, 0)
        self.assertEqual(magic, 0xFEEDFACF)

        # Locate __LINKEDIT so the signature can be appended after it.
        off = 32
        linkedit_cmd_off = None
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", binary, off)
            if cmd == 0x19:
                seg = bytes(binary[off + 8:off + 24]).split(b"\x00")[0]
                if seg == b"__LINKEDIT":
                    linkedit_cmd_off = off
            off += cmdsize
        self.assertIsNotNone(linkedit_cmd_off)

        # Order matters and mirrors `codesign`: every load-command edit must be
        # complete *before* the page hashes are computed, because the load
        # commands live inside page 0 and any later write invalidates the hash.
        new_commands = b""
        if extra_dylib:
            name = extra_dylib.encode("utf-8") + b"\x00"
            raw_len = 24 + len(name)
            dylib_size = (raw_len + 7) // 8 * 8
            command = bytearray(dylib_size)
            struct.pack_into("<IIIIII", command, 0, 0xC, dylib_size, 24, 0, 0x10000, 0x10000)
            command[24:24 + len(name)] = name
            new_commands += bytes(command)
        sig_cmd_size = 16
        new_commands += b"\x00" * sig_cmd_size

        added = (1 if extra_dylib else 0) + 1
        cmds_end = 32 + sizeofcmds
        binary[cmds_end:cmds_end] = new_commands
        struct.pack_into("<I", binary, 16, ncmds + added)
        struct.pack_into("<I", binary, 20, sizeofcmds + len(new_commands))
        sig_cmd_off = cmds_end + len(new_commands) - sig_cmd_size

        sig_offset = len(binary)
        code_limit = sig_offset
        page = 4096
        n_code_slots = (code_limit + page - 1) // page

        identifier = b"com.nbtaimlock.ios\x00"
        team_identifier = b"ABCDEFG123\x00"
        header_size = 88  # CodeDirectory version 0x20400
        ident_offset = header_size
        team_offset = ident_offset + len(identifier)
        hash_offset = team_offset + len(team_identifier)
        cd_length = hash_offset + n_code_slots * 32

        cd = bytearray(cd_length)
        struct.pack_into(">8I", cd, 0,
                         0xFADE0C02, cd_length, 0x20400, 0x2 if adhoc else 0x0,
                         hash_offset, ident_offset, 0, n_code_slots)
        struct.pack_into(">I", cd, 32, code_limit)
        struct.pack_into(">BBBB", cd, 36, 32, 2, 0, 12)
        # teamOffset (v0x20200+) must carry the real team, otherwise the gate
        # compares an empty signature team against the profile team.
        struct.pack_into(">I", cd, 48, team_offset)
        struct.pack_into(">QQQ", cd, 64, 0, 0, 0)
        cd[ident_offset:ident_offset + len(identifier)] = identifier
        cd[team_offset:team_offset + len(team_identifier)] = team_identifier

        cms = struct.pack(">II", 0xFADE0B01, 8 + len(cms_payload)) + cms_payload
        ents_plist = plistlib.dumps(
            {"application-identifier": f"{ents_team}.com.nbtaimlock.ios",
             "com.apple.developer.team-identifier": ents_team},
            fmt=plistlib.FMT_XML,
        )
        ents = struct.pack(">II", 0xFADE7171, 8 + len(ents_plist)) + ents_plist

        blobs = [(0, bytes(cd)), (5, ents), (0x10000, cms)]
        index_size = 12 + len(blobs) * 8
        body = bytearray()
        entries = []
        for slot_type, blob in blobs:
            entries.append((slot_type, index_size + len(body)))
            body += blob
        superblob = bytearray(index_size + len(body))
        struct.pack_into(">III", superblob, 0, 0xFADE0CC0, len(superblob), len(blobs))
        for i, (slot_type, slot_off) in enumerate(entries):
            struct.pack_into(">II", superblob, 12 + i * 8, slot_type, slot_off)
        superblob[index_size:] = body

        # Fill in the LC_CODE_SIGNATURE and grow __LINKEDIT so the signature
        # lies inside it, as AMFI expects. Both are load-command writes, so
        # they must land before hashing.
        struct.pack_into("<IIII", binary, sig_cmd_off, 0x1D, 16, sig_offset, len(superblob))
        vmaddr, vmsize, fileoff, _filesize = struct.unpack_from("<QQQQ", binary, linkedit_cmd_off + 24)
        new_filesize = sig_offset + len(superblob) - fileoff
        new_vmsize = ((new_filesize + 0x3FFF) // 0x4000) * 0x4000
        struct.pack_into("<Q", binary, linkedit_cmd_off + 32, max(new_vmsize, vmsize))
        struct.pack_into("<Q", binary, linkedit_cmd_off + 48, new_filesize)

        # Now the file image is final up to sig_offset — hash the pages.
        for index in range(n_code_slots):
            start = index * page
            end = min(start + page, code_limit)
            digest = hashlib.sha256(bytes(binary[start:end])).digest()
            at = hash_offset + index * 32
            cd[at:at + 32] = digest

        # Rebuild the SuperBlob with the filled CodeDirectory and append it.
        blobs[0] = (0, bytes(cd))
        body = bytearray()
        entries = []
        for slot_type, blob in blobs:
            entries.append((slot_type, index_size + len(body)))
            body += blob
        superblob = bytearray(index_size + len(body))
        struct.pack_into(">III", superblob, 0, 0xFADE0CC0, len(superblob), len(blobs))
        for i, (slot_type, slot_off) in enumerate(entries):
            struct.pack_into(">II", superblob, 12 + i * 8, slot_type, slot_off)
        superblob[index_size:] = body
        # The reservations above used these same sizes, so byte offsets hold.
        self.assertEqual(
            struct.unpack_from("<II", binary, sig_cmd_off + 8), (sig_offset, len(superblob))
        )

        binary += superblob
        return bytes(binary)

    def _signed_fixture(self, binary, module_qualified_scene=False, profile_mode="ad-hoc"):
        app_prefix = "Payload/NBTAimlock.app/"
        team = "ABCDEFG123"
        profile = {
            "UUID": "11111111-2222-3333-4444-555555555555",
            "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=30),
            "TeamIdentifier": [team],
            "Entitlements": {
                "application-identifier": f"{team}.com.nbtaimlock.ios",
                "com.apple.developer.team-identifier": team,
            },
        }
        if profile_mode == "enterprise":
            profile["ProvisionsAllDevices"] = True
        elif profile_mode == "app-store":
            pass  # neither ProvisionedDevices nor ProvisionsAllDevices
        else:
            profile["ProvisionedDevices"] = ["0" * 40]
        profile_xml = plistlib.dumps(profile, fmt=plistlib.FMT_XML)

        def mutate(name, data):
            if name == "__ADD__":
                return [
                    (app_prefix + "embedded.mobileprovision", profile_xml),
                    (app_prefix + "_CodeSignature/CodeResources",
                     b"<?xml version=\"1.0\"?><plist><dict/></plist>"),
                ]
            if name == app_prefix + "NBTAimlock":
                return binary
            if name == app_prefix + "Info.plist" and module_qualified_scene:
                info = plistlib.loads(data)
                configs = info["UIApplicationSceneManifest"]["UISceneConfigurations"]
                for entries in configs.values():
                    for entry in entries:
                        if entry.get("UISceneDelegateClassName") == "SceneDelegate":
                            entry["UISceneDelegateClassName"] = "NBTAimlock.SceneDelegate"
                return plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=False)
            return data

        fixture = write_fixture(IPA_PATH, mutate)
        self.addCleanup(fixture.unlink, missing_ok=True)
        return fixture

    def _run_validator(self, fixture):
        return subprocess.run(
            [sys.executable, str(TOOLS_ROOT / "validate_ios_release.py"), str(fixture), "--json"],
            capture_output=True, text=True, encoding="utf-8", errors="replace", check=False,
        )

    def test_code_directory_page_hashes_are_accepted(self):
        """A structurally complete signature must get past the CodeDirectory."""
        fixture = self._signed_fixture(self._build_signed_binary(adhoc=False))
        out = self._run_validator(fixture).stdout
        self.assertIn("code_directory_pages", out)
        self.assertNotIn("CodeDirectory page hash mismatch", out)
        self.assertNotIn("hash table is outside the blob", out)

    def test_adhoc_signature_is_rejected(self):
        fixture = self._signed_fixture(self._build_signed_binary(adhoc=True))
        result = self._run_validator(fixture)
        self.assertEqual(result.returncode, 1)
        self.assertIn("CS_ADHOC", result.stdout)

    def test_placeholder_cms_is_rejected(self):
        """This is the exact shape produced by a 'signer' that only writes a stub."""
        fixture = self._signed_fixture(self._build_signed_binary(adhoc=False))
        result = self._run_validator(fixture)
        self.assertEqual(result.returncode, 1)
        self.assertIn("apple_cms_signature", result.stdout)
        self.assertIn("not a DER SEQUENCE", result.stdout)

    def test_cms_without_signed_data_oid_is_rejected(self):
        der_without_oid = b"\x30\x0c\x06\x08\x2a\x86\x48\x86\xf7\x0d\x01\x07\x01\x00"
        fixture = self._signed_fixture(
            self._build_signed_binary(adhoc=False, cms_payload=der_without_oid)
        )
        result = self._run_validator(fixture)
        self.assertEqual(result.returncode, 1)
        self.assertIn("signedData OID", result.stdout)

    def _failed_checks(self, fixture):
        result = self._run_validator(fixture)
        payload = json.loads(result.stdout)
        return payload["failed"], payload["checks"]

    def test_enterprise_profile_is_accepted_as_installable(self):
        """An In-House profile installs on any device and must not be rejected."""
        fixture = self._signed_fixture(
            self._build_signed_binary(adhoc=False), profile_mode="enterprise"
        )
        failed, checks = self._failed_checks(fixture)
        self.assertNotIn("profile_kind", failed)
        detail = next(c["detail"] for c in checks if c["name"] == "profile_kind")
        self.assertIn("enterprise", detail)

    def test_app_store_profile_is_rejected(self):
        """App Store profiles carry no UDID list, so direct install is impossible."""
        fixture = self._signed_fixture(
            self._build_signed_binary(adhoc=False), profile_mode="app-store"
        )
        failed, _ = self._failed_checks(fixture)
        self.assertIn("profile_kind", failed)

    def test_entitlement_team_mismatch_is_rejected(self):
        """A signature whose entitlements name another team is rejected at launch."""
        fixture = self._signed_fixture(
            self._build_signed_binary(adhoc=False, ents_team="ZZZZZZZ999")
        )
        failed, _ = self._failed_checks(fixture)
        self.assertIn("entitlement_team_matches_profile", failed)

    def test_bare_scene_delegate_is_rejected_for_swift_build(self):
        """Swift registers classes module-qualified; a bare name launches black."""
        swift_binary = self._build_signed_binary(
            adhoc=False, extra_dylib="/usr/lib/swift/libswiftCore.dylib"
        )
        fixture = self._signed_fixture(swift_binary, module_qualified_scene=False)
        failed, checks = self._failed_checks(fixture)
        self.assertTrue(any(c["name"] == "binary_is_swift_build" for c in checks))
        self.assertIn("scene_delegate_module_qualified", failed)

    def test_signed_legacy_release_reports_legacy_build_kind(self):
        """The signed gate accepts the reviewed legacy app only with the flag."""
        fixture = self._signed_fixture(self._build_signed_binary(adhoc=False))

        strict = json.loads(self._run_validator(fixture).stdout)
        self.assertIn("binary_is_swift_build", strict["failed"])
        self.assertNotIn("build_kind", {c["name"] for c in strict["checks"]})

        relaxed = subprocess.run(
            [sys.executable, str(TOOLS_ROOT / "validate_ios_release.py"), str(fixture),
             "--json", "--legacy-native"],
            capture_output=True, text=True, encoding="utf-8", errors="replace", check=False,
        )
        payload = json.loads(relaxed.stdout)
        checks = {c["name"]: c for c in payload["checks"]}
        self.assertIn("build_kind", checks)
        self.assertTrue(checks["build_kind"]["ok"], checks["build_kind"]["detail"])
        self.assertEqual(checks["build_kind"]["detail"], "legacy-native")
        self.assertNotIn("binary_is_swift_build", payload["failed"])

    def test_module_qualified_scene_delegate_passes(self):
        swift_binary = self._build_signed_binary(
            adhoc=False, extra_dylib="/usr/lib/swift/libswiftCore.dylib"
        )
        fixture = self._signed_fixture(swift_binary, module_qualified_scene=True)
        failed, _ = self._failed_checks(fixture)
        self.assertNotIn("scene_delegate_module_qualified", failed)


class SwiftSourceTargetTests(unittest.TestCase):
    """The regression that shipped once: a file on disk that compiles nowhere.

    Nine Swift files, including the whole AIMLOCK dashboard, existed in the
    repository but were absent from the app target. Every test passed, the
    build passed, and the feature was simply missing from the IPA. These tests
    pin the guard that makes that impossible to ship again.
    """

    SYNTHETIC_PROJECT = """// !$*UTF8*$!
{{
	objects = {{
		AE000000000000000000002C /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				AA000000000000000000001A /* {compiled} in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		AA000000000000000000001A /* {compiled} in Sources */ = {{isa = PBXBuildFile; fileRef = AB000000000000000000001B /* {compiled} */; }};
		AB000000000000000000001B /* {compiled} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {compiled}; sourceTree = "<group>"; }};
	}};
}}
"""

    @classmethod
    def setUpClass(cls):
        cls.checker = load_tool("check_swift_sources.py")

    def _project(self, compiled: str) -> Path:
        handle = tempfile.NamedTemporaryFile(
            "w", suffix=".pbxproj", delete=False, encoding="utf-8"
        )
        handle.write(self.SYNTHETIC_PROJECT.format(compiled=compiled))
        handle.close()
        path = Path(handle.name)
        self.addCleanup(path.unlink, missing_ok=True)
        return path

    def test_real_project_compiles_every_swift_file(self):
        result = subprocess.run(
            [sys.executable, str(TOOLS_ROOT / "check_swift_sources.py"), "--json"],
            capture_output=True, text=True, encoding="utf-8", errors="replace", check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["ok"], payload["problems"])
        self.assertGreaterEqual(payload["swift_files"], 20)

    def test_file_missing_from_the_target_is_reported(self):
        project = self._project("Included.swift")
        problems = self.checker.check_project_membership(
            [Path("Included.swift"), Path("Forgotten.swift")], project
        )
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("Forgotten.swift", problems[0])
        self.assertIn("not compiled", problems[0])

    def test_reference_to_a_file_that_does_not_exist_is_reported(self):
        project = self._project("Ghost.swift")
        problems = self.checker.check_project_membership([], project)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("Ghost.swift", problems[0])
        self.assertIn("not on disk", problems[0])

    def test_consistent_project_has_no_problems(self):
        project = self._project("Only.swift")
        self.assertEqual(
            self.checker.check_project_membership([Path("Only.swift")], project), []
        )


class SwiftSyntaxTests(unittest.TestCase):
    """A real Swift grammar, not brace counting. Optional dependency: the tests
    skip when the tree-sitter grammar is absent so the suite still runs on a
    bare machine."""

    @classmethod
    def setUpClass(cls):
        cls.tool = load_tool("swift_syntax_check.py")
        cls.parser = cls.tool.load_grammar()

    def setUp(self):
        if self.parser is None:
            self.skipTest("tree-sitter Swift grammar not installed")

    def test_every_shipped_source_parses(self):
        failures = {}
        for path in sorted(self.tool.APP_DIR.rglob("*.swift")):
            problems = self.tool.parse_file(self.parser, path)
            if problems:
                failures[path.name] = problems
        self.assertEqual(failures, {})

    def test_a_broken_source_is_reported_with_a_line(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Broken.swift"
            path.write_text("struct A { func f() { let x = } }\n", encoding="utf-8")
            problems = self.tool.parse_file(self.parser, path)
            self.assertTrue(problems, "parser accepted invalid Swift")
            self.assertEqual(problems[0][0], 1)


class ObfuscationTableTests(unittest.TestCase):
    """The table file is generated. Editing the string list without
    regenerating leaves the shipped endpoints stale — or, worse, keeps the old
    plaintext layout while the source looks changed."""

    @classmethod
    def setUpClass(cls):
        cls.tool = load_tool("obfuscate_strings.py")

    def test_checked_in_tables_match_the_generator(self):
        expected = self.tool.render()
        actual = self.tool.OUTPUT.read_text(encoding="utf-8")
        self.assertEqual(actual, expected, "run tools/obfuscate_strings.py")

    def test_every_endpoint_is_obfuscated(self):
        source = self.tool.OUTPUT.read_text(encoding="utf-8")
        for symbol, text in self.tool.STRINGS:
            with self.subTest(symbol=symbol):
                self.assertNotIn(text, source)
                self.assertIn(f"{symbol}Cipher", source)


if __name__ == "__main__":
    unittest.main()
