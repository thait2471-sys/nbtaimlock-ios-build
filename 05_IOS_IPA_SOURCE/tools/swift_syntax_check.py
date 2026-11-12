#!/usr/bin/env python3
"""Parse every Swift file with a real Swift grammar.

Brace counting is not a compiler. This tool runs tree-sitter's Swift grammar
over each source file and fails when the parser reports a syntax error or a
missing token, with file and line numbers.

The parser is optional: when `tree-sitter` / `tree-sitter-swift` are not
installed the tool prints SKIP and exits 0, so a bare environment can still run
every other gate. Pass `--require` to turn a missing parser into a failure.
"""

from __future__ import annotations

import sys
from pathlib import Path

APP_DIR = Path(__file__).resolve().parents[1] / "NBTAimlock"


def load_grammar():
    try:
        import tree_sitter_swift
        from tree_sitter import Language, Parser
    except ImportError:
        return None
    language = Language(tree_sitter_swift.language())
    return Parser(language)


def parse_file(parser, path: Path):
    data = path.read_bytes()
    tree = parser.parse(data)
    problems = []
    stack = [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type == "ERROR" or node.is_missing:
            line = node.start_point[0] + 1
            problems.append((line, node.type, node.end_point[0] + 1))
        stack.extend(node.children)
    return problems


def main() -> int:
    require = "--require" in sys.argv
    parser = load_grammar()
    if parser is None:
        message = "SKIP: tree-sitter Swift grammar not installed"
        print(message)
        return 1 if require else 0

    files = sorted(APP_DIR.rglob("*.swift"))
    failed = 0
    for path in files:
        problems = parse_file(parser, path)
        if problems:
            failed += 1
            rel = path.relative_to(APP_DIR.parent)
            for line, kind, end_line in problems[:8]:
                print(f"  [FAIL] {rel}:{line} {kind} (through line {end_line})")
            if len(problems) > 8:
                print(f"  ... {len(problems) - 8} more in {rel}")

    print(f"Swift files parsed : {len(files)}")
    if failed:
        print(f"RESULT: {failed} file(s) do not parse")
        return 1
    print("RESULT: ALL FILES PARSE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
