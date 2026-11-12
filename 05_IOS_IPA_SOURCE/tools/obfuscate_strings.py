#!/usr/bin/env python3
"""Generate NABATIObfuscationTables.swift from the strings we want hidden.

Why: the iOS binary ships as a stripped Mach-O, and stripping removes symbols
but not the `__cstring` section. A repackaged IPA is trivially patched by
grepping for "/api/license/authorize" or the keychain service name and editing
the neighbouring bytes. Storing those literals as XOR-masked byte arrays means
`strings` finds nothing and a patch requires reversing the mask first.

This is *obfuscation*, not encryption, and the generated file says so: the mask
is a per-string SHA-256 keystream derived from the string itself, so it is
deterministic (the file can be regenerated and diffed) and needs no secret. It
raises the cost of casual patching; the actual authority remains the server.

Usage:
    python3 tools/obfuscate_strings.py          # regenerate tables
    python3 tools/obfuscate_strings.py --check  # fail if tables are stale
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parents[1]
OUTPUT = SOURCE_ROOT / "NBTAimlock" / "Obfuscation" / "NABATIObfuscationTables.swift"

# Symbol name in Swift -> plaintext. Keep this list to strings that only need
# to be hidden from a static scan. Never add a real secret here: anything in
# this file is recoverable at runtime by design.
STRINGS = [
    ("apiVerify", "/api/verify"),
    ("apiHeartbeat", "/api/heartbeat"),
    ("apiAuthorize", "/api/license/authorize"),
    ("apiConfig", "/api/config"),
    ("apiServiceStatus", "/api/service-status"),
    ("apiLockoutStatus", "/api/lockout-status"),
    ("apiAnnouncement", "/api/announcement"),
    ("apiSensitivity", "/api/sensitivity"),
    ("apiLegal", "/api/legal"),
    ("installManifestPath", "/api/ios/install-manifest.plist"),
    ("keychainService", "com.nbtaimlock.ios.vault"),
    ("baseURL", "https://nbtaimlockshopcom.thait2471.workers.dev"),
    ("clientPlatform", "ios_ipa"),
]


def keystream(text: bytes) -> bytes:
    """Deterministic mask: SHA-256(text || counter) blocks, truncated to len."""
    out = bytearray()
    counter = 0
    while len(out) < len(text):
        block = hashlib.sha256(text + counter.to_bytes(8, "little")).digest()
        out.extend(block)
        counter += 1
    return bytes(out[: len(text)])


def swift_bytes(values: bytes) -> str:
    return "[" + ", ".join(f"0x{b:02X}" for b in values) + "]"


def render() -> str:
    lines = [
        "// GENERATED FILE — do not edit by hand.",
        "// Regenerate with: python3 tools/obfuscate_strings.py",
        "//",
        "// Each pair is (masked bytes, mask). XOR the two to recover the UTF-8",
        "// literal. See NABATIObfuscation.swift for why these are stored this way:",
        "// it is obfuscation against static patching, not encryption, and no secret",
        "// is involved. Server-side verification remains the only authority.",
        "",
        "import Foundation",
        "",
        "enum NABATIObfuscationTables {",
    ]

    for symbol, text in STRINGS:
        raw = text.encode("utf-8")
        mask = keystream(raw)
        masked = bytes(a ^ b for a, b in zip(raw, mask))
        lines.append(f"    // {len(raw)} bytes")
        lines.append(f"    static let {symbol}Cipher: [UInt8] = {swift_bytes(masked)}")
        lines.append(f"    static let {symbol}Mask: [UInt8] = {swift_bytes(mask)}")
        lines.append("")

    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    content = render()
    check_only = "--check" in sys.argv

    if check_only:
        if not OUTPUT.is_file():
            print(f"FAIL: missing {OUTPUT}")
            return 1
        if OUTPUT.read_text(encoding="utf-8") != content:
            print(f"FAIL: {OUTPUT} is stale — run python3 tools/obfuscate_strings.py")
            return 1
        print(f"OK: {OUTPUT.name} matches {len(STRINGS)} obfuscated strings")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(content, encoding="utf-8", newline="\n")
    print(f"Wrote {OUTPUT} ({len(STRINGS)} strings, {len(content)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
