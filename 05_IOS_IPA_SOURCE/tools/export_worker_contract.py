#!/usr/bin/env python3
"""Export the Worker surface the iOS client depends on into a checked-in fixture.

The iOS build repository does not contain `worker.js` — it holds the app source
only. The contract tests therefore read a fixture generated here, from the real
Worker, rather than reaching outside the repository at test time.

`--check` regenerates in memory and fails when the checked-in fixture no longer
matches the Worker, so a route rename or a dropped response field cannot ship
without someone noticing.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parents[1]
WORKER = SOURCE_ROOT.parent / "REDESIGN_V2" / "worker" / "worker.js"
OUTPUT = SOURCE_ROOT / "tests" / "fixtures" / "worker_contract.json"

# The response fields the client parses. Each entry is (route, fields).
RESPONSE_FIELDS = {
    "/api/license/authorize": ["featureId", "nonce", "expiresAt", "signature"],
    "/api/lockout-status": ["isLockedOut", "failedCount", "remainingSeconds", "maxAttempts"],
    # `doc` is stored as JSON by the Admin writer, so its keys are exported
    # separately below rather than looked for in the route window.
    "/api/legal": ["found", "doc", "type"],
    "/api/sensitivity": ["presets", "light", "mid", "heavy"],
    "/api/config": ["features"],
    "/api/announcement": ["announcements"],
}

ROUTE_RE = re.compile(r'url\.pathname === "([^"]+)"')
FEATURE_ID_RE = re.compile(r'id: "([a-z]+_[a-z]+_[0-9]+)"')
# The Admin legal writer is the only place the stored document schema exists.
LEGAL_DOC_RE = re.compile(
    r'JSON\.stringify\(\{ title, content, ([^}]*)\}\)')
LEGAL_DOC_FIELDS = ["title", "content", "contact", "updated_label"]


def default_config_block(source: str) -> str:
    start = source.index("const DEFAULT_CONFIG = {")
    depth = 0
    for index in range(start, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError("unterminated DEFAULT_CONFIG")


def build_contract(worker_path: Path = None) -> dict:
    source = (worker_path or WORKER).read_text(encoding="utf-8")
    routes = sorted(set(ROUTE_RE.findall(source)))
    features = sorted(set(FEATURE_ID_RE.findall(default_config_block(source))))

    fields = {}
    for route, expected in RESPONSE_FIELDS.items():
        marker = 'url.pathname === "%s"' % route
        start = source.index(marker)
        window = source[start:start + 6000]
        fields[route] = [name for name in expected if name in window]

    legal_doc = []
    match = LEGAL_DOC_RE.search(source)
    if match:
        legal_doc = [name for name in LEGAL_DOC_FIELDS if name in match.group(0)]

    return {
        "routes": routes,
        "featureIds": features,
        "responseFields": fields,
        "legalDocFields": legal_doc,
    }


def render(contract: dict) -> str:
    return json.dumps(contract, indent=2, ensure_ascii=False, sort_keys=True) + "\n"


def main() -> int:
    if not WORKER.is_file():
        print(f"FAIL: missing {WORKER}")
        return 1
    content = render(build_contract())

    if "--check" in sys.argv:
        if not OUTPUT.is_file():
            print(f"FAIL: missing {OUTPUT}")
            return 1
        if OUTPUT.read_text(encoding="utf-8") != content:
            print(f"FAIL: {OUTPUT} is stale - run tools/export_worker_contract.py")
            return 1
        print(f"OK: {OUTPUT.name} matches worker.js")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(content, encoding="utf-8", newline="\n")
    print(f"Wrote {OUTPUT} ({len(content)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
