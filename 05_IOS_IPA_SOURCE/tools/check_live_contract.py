#!/usr/bin/env python3
"""Read-only live check of the public endpoints the iOS client parses.

This is not part of CI: it talks to production, so it runs on demand. It never
sends a KEY, a device id or a session token, and it only issues GETs against
public routes, so it cannot change a customer record.

Each assertion mirrors one parser in `NBTAimlock/` — the point is to catch a
Worker change that would make a shipped binary read the wrong field or type,
which no amount of Swift compilation can reveal.

    python tools/check_live_contract.py
"""

from __future__ import annotations

import importlib.util
import json
import sys
import urllib.request
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parents[1]
TOOLS_ROOT = SOURCE_ROOT / "tools"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def base_url() -> str:
    strings = load_module("obf", TOOLS_ROOT / "obfuscate_strings.py").STRINGS
    return next(value for name, value in strings if name == "baseURL")


def fetch(path: str) -> tuple[int, dict, str]:
    request = urllib.request.Request(
        base_url() + path,
        headers={
            "Accept": "application/json",
            "User-Agent": "NBTAimlock/4.2.0 (iOS)",
            "X-Client-Platform": "ios",
            "X-App-Version": "4.2.0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read().decode("utf-8", "replace")
            status = response.status
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")
        status = error.code
    try:
        payload = json.loads(body)
    except ValueError:
        payload = {}
    return status, payload, body


class Checks:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.checked = 0

    def require(self, label: str, condition: bool, detail: str = "") -> None:
        self.checked += 1
        if condition:
            print(f"  [PASS] {label}")
        else:
            print(f"  [FAIL] {label}{(' — ' + detail) if detail else ''}")
            self.failures.append(label)

    def is_type(self, label: str, value, kinds: tuple, detail: str = "") -> None:
        self.require(label, isinstance(value, kinds), detail or f"got {type(value).__name__}")


def check_config(checks: Checks) -> None:
    print("GET /api/config")
    status, payload, body = fetch("/api/config")
    checks.require("HTTP 200", status == 200, f"status {status}")
    checks.is_type("success is bool", payload.get("success"), (bool,))
    cfg = payload.get("config")
    checks.is_type("config is an object", cfg, (dict,), body[:80])
    if not isinstance(cfg, dict):
        return
    for key in ("appName", "appSub", "announcement"):
        checks.is_type(f"config.{key} is a string", cfg.get(key), (str,))
    # `optimizeAnimation` is optional: the Admin config may omit it, and the
    # client then keeps its shipped default (animation on). Only a present key
    # must have the right type.
    for key in ("showAnnouncement", "optimizeAnimation"):
        if key in cfg:
            checks.is_type(f"config.{key} is a bool", cfg[key], (bool,))
        else:
            print(f"  [INFO] config.{key} absent — client falls back to its default")
    features = cfg.get("features")
    checks.is_type("config.features is a list", features, (list,))
    if isinstance(features, list) and features:
        checks.require("features[] non-empty", len(features) >= 8, f"{len(features)} rows")
        ids = [row.get("id") for row in features if isinstance(row, dict)]
        checks.require("every feature has an id", all(isinstance(i, str) and i for i in ids), str(ids))
        checks.require(
            "the eight shipped ids are still offered",
            {"feat_aim_1", "feat_aim_2", "feat_aim_3", "feat_aim_4",
             "feat_dev_1", "feat_dev_2", "feat_dev_3", "feat_dev_4"}.issubset(set(ids)),
            str(sorted(set(ids))),
        )


def check_announcement(checks: Checks) -> None:
    print("GET /api/announcement")
    status, payload, _ = fetch("/api/announcement")
    checks.require("HTTP 200", status == 200, f"status {status}")
    rows = payload.get("announcements")
    checks.is_type("announcements is a list", rows, (list,))
    for index, row in enumerate(rows if isinstance(rows, list) else []):
        checks.is_type(f"announcements[{index}].title is a string", row.get("title"), (str,))


def check_sensitivity(checks: Checks) -> None:
    print("GET /api/sensitivity?model=iPhone 13")
    status, payload, body = fetch("/api/sensitivity?model=iPhone%2013")
    checks.require("HTTP 200", status == 200, f"status {status}")
    checks.is_type("found is bool", payload.get("found"), (bool,))
    if payload.get("found") is True:
        checks.is_type("brand is a string", payload.get("brand"), (str,))
        checks.is_type("model is a string", payload.get("model"), (str,))
        # The client reads presets.light / mid / heavy, not top-level keys.
        presets = payload.get("presets")
        checks.is_type("presets is an object", presets, (dict,), body[:80])
        for tier in ("light", "mid", "heavy"):
            entry = (presets or {}).get(tier) if isinstance(presets, dict) else None
            checks.is_type(f"presets.{tier} is an object", entry, (dict,), body[:80])
            if isinstance(entry, dict):
                checks.is_type(f"{tier}.name is a string", entry.get("name"), (str,))
                checks.require(f"{tier}.value is a string or number",
                               isinstance(entry.get("value"), (str, int, float)),
                               f"got {type(entry.get('value')).__name__}")
                checks.is_type(f"{tier}.params is an object", entry.get("params"), (dict,))
    else:
        checks.is_type("suggestions is a list", payload.get("suggestions", []), (list,))


def check_service_status(checks: Checks) -> None:
    print("GET /api/service-status")
    status, payload, body = fetch("/api/service-status")
    checks.require("HTTP 200", status == 200, f"status {status}")
    checks.is_type("success is bool", payload.get("success"), (bool,))
    state = payload.get("state")
    checks.is_type("state is an object", state, (dict,), body[:80])
    if isinstance(state, dict):
        checks.is_type("state.mode is a string", state.get("mode"), (str,))
        for key in ("applies", "active", "retryEnabled", "blockAuth", "updateCenterEnabled"):
            if key in state:
                checks.is_type(f"state.{key} is a bool", state[key], (bool,))


def check_legal(checks: Checks) -> None:
    for kind in ("terms", "privacy", "about", "guide"):
        print(f"GET /api/legal?type={kind}")
        status, payload, _ = fetch(f"/api/legal?type={kind}")
        checks.require("HTTP 200", status == 200, f"status {status}")
        checks.is_type("found is bool", payload.get("found"), (bool,))
        doc = payload.get("doc")
        if payload.get("found") is True:
            checks.is_type("doc is an object", doc, (dict,))
            if isinstance(doc, dict):
                for key in ("title", "content"):
                    checks.is_type(f"doc.{key} is a string", doc.get(key), (str,))


def main() -> int:
    checks = Checks()
    for step in (check_config, check_announcement, check_sensitivity, check_service_status, check_legal):
        try:
            step(checks)
        except Exception as error:  # network or shape exploded
            print(f"  [FAIL] {step.__name__}: {error}")
            checks.failures.append(step.__name__)
    passed = checks.checked - len(checks.failures)
    print()
    print(f"{passed}/{checks.checked} checks passed")
    return 1 if checks.failures else 0


if __name__ == "__main__":
    sys.exit(main())
