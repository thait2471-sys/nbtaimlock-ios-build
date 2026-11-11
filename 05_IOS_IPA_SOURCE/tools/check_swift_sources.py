#!/usr/bin/env python3
"""Static sanity checks on the Swift sources that no Windows toolchain can compile.

The iOS app can only be compiled on macOS, so a source-level typo stays invisible
until CI runs. These checks catch the failures that would break the build for a
structural reason — unbalanced braces or parentheses outside strings/comments,
duplicate top-level declarations, and iOS-version-gated API used inside a target
that still deploys to iOS 14 — without needing Xcode.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parents[1]
APP_DIR = SOURCE_ROOT / "NBTAimlock"
DEPLOYMENT_TARGET = (14, 0)

# (pattern, minimum iOS major version, human label)
IOS_15_ONLY = [
    (re.compile(r"\.animation\([^)]*\bvalue\s*:"), 15, ".animation(_:value:)"),
    (re.compile(r"(?<![A-Za-z_])\.tint\("), 15, ".tint(_:)"),
    (re.compile(r"\bforegroundStyle\("), 15, ".foregroundStyle(_:)"),
    (re.compile(r"\bscrollContentBackground\("), 16, ".scrollContentBackground(_:)"),
    (re.compile(r"\bNavigationStack\b"), 16, "NavigationStack"),
    (re.compile(r"\bpresentationDetents\("), 16, ".presentationDetents(_:)"),
    (re.compile(r"\bAsyncImage\b"), 15, "AsyncImage"),
    (re.compile(r"(?<![A-Za-z_])\.refreshable\b"), 15, ".refreshable"),
]


def strip_literals_and_comments(source: str) -> str:
    """Blank out strings and comments while keeping line structure intact."""
    out = []
    i = 0
    n = len(source)
    while i < n:
        ch = source[i]
        two = source[i:i + 2]
        if two == "//":
            end = source.find("\n", i)
            if end < 0:
                break
            out.append(" " * (end - i))
            i = end
            continue
        if two == "/*":
            end = source.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append("".join(c if c == "\n" else " " for c in source[i:end]))
            i = end
            continue
        if ch == '"':
            # Swift allows """ multiline strings; treat both the same way.
            triple = source[i:i + 3] == '"""'
            quote = '"""' if triple else '"'
            j = i + len(quote)
            while j < n:
                if source[j] == "\\":
                    j += 2
                    continue
                if source[j:j + len(quote)] == quote:
                    j += len(quote)
                    break
                j += 1
            out.append("".join(c if c == "\n" else " " for c in source[i:j]))
            i = j
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def swift_files() -> list[Path]:
    return sorted(APP_DIR.rglob("*.swift"))


def check_balance(files: list[Path]) -> list[str]:
    problems = []
    for path in files:
        code = strip_literals_and_comments(path.read_text(encoding="utf-8"))
        rel = path.relative_to(SOURCE_ROOT).as_posix()
        for opening, closing, label in (("{", "}", "braces"), ("(", ")", "parentheses"),
                                        ("[", "]", "brackets")):
            delta = code.count(opening) - code.count(closing)
            if delta:
                problems.append(f"{rel}: {label} unbalanced by {delta:+d}")
    return problems


DECL = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+|final\s+|@objc(?:\([^)]*\))?\s+)*"
    r"(class|struct|enum|protocol|typealias)\s+([A-Za-z_]\w*)",
    re.MULTILINE,
)


def check_duplicate_types(files: list[Path]) -> list[str]:
    seen: dict[str, list[str]] = {}
    for path in files:
        code = strip_literals_and_comments(path.read_text(encoding="utf-8"))
        rel = path.relative_to(SOURCE_ROOT).as_posix()
        for match in DECL.finditer(code):
            seen.setdefault(match.group(2), []).append(rel)
    return [
        f"type {name} declared in {', '.join(sorted(set(paths)))}"
        for name, paths in sorted(seen.items())
        if len(set(paths)) > 1
    ]


AVAILABILITY_GUARD = re.compile(
    r"if\s+#available\(\s*iOS\s+(?P<version>\d+(?:\.\d+)*)"
)


def availability_guarded_offsets(code: str) -> list[tuple[int, int]]:
    """Return (start, end) ranges covered by `if #available(iOS N, *) { ... }`."""
    ranges = []
    for match in AVAILABILITY_GUARD.finditer(code):
        brace = code.find("{", match.end())
        if brace < 0:
            continue
        depth = 0
        for index in range(brace, len(code)):
            if code[index] == "{":
                depth += 1
            elif code[index] == "}":
                depth -= 1
                if depth == 0:
                    ranges.append((brace, index))
                    break
    return ranges


def check_ios_version_apis(files: list[Path]) -> list[str]:
    problems = []
    for path in files:
        raw = path.read_text(encoding="utf-8")
        code = strip_literals_and_comments(raw)
        guarded = availability_guarded_offsets(code)
        rel = path.relative_to(SOURCE_ROOT).as_posix()
        for pattern, required, label in IOS_15_ONLY:
            if required <= DEPLOYMENT_TARGET[0]:
                continue
            for match in pattern.finditer(code):
                if any(start < match.start() < end for start, end in guarded):
                    continue
                line = code.count("\n", 0, match.start()) + 1
                problems.append(
                    f"{rel}:{line}: {label} requires iOS {required} "
                    f"but the target deploys to iOS {DEPLOYMENT_TARGET[0]} and the call "
                    f"is outside an `if #available(iOS {required}, *)` branch"
                )
    return problems


def main() -> int:
    files = swift_files()
    if not files:
        print(f"FAIL: no Swift sources under {APP_DIR}")
        return 1
    problems = []
    problems += check_balance(files)
    problems += check_duplicate_types(files)
    problems += check_ios_version_apis(files)

    result = {
        "source_root": str(SOURCE_ROOT),
        "swift_files": len(files),
        "deployment_target": f"{DEPLOYMENT_TARGET[0]}.{DEPLOYMENT_TARGET[1]}",
        "problems": problems,
        "ok": not problems,
    }
    if "--json" in sys.argv:
        print(json.dumps(result, indent=2))
    else:
        print(f"Swift sources : {len(files)} files under {APP_DIR.name}/")
        print(f"iOS target    : {DEPLOYMENT_TARGET[0]}.{DEPLOYMENT_TARGET[1]}")
        if problems:
            print("")
            for problem in problems:
                print(f"  [FAIL] {problem}")
            print("\nRESULT: REJECTED")
        else:
            print("  [PASS] braces/parentheses/brackets balanced")
            print("  [PASS] no duplicate top-level type declarations")
            print("  [PASS] no unguarded iOS 15+ API in an iOS 14 target")
            print("\nRESULT: SOURCE SANE")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
