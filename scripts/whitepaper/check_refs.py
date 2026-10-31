#!/usr/bin/env python3
"""Check the whitepaper's citations and internal links.

Every factual sentence in the whitepaper ends with `path/to/File.ext:LINE`.
This script resolves those references against the working tree and fails when
one of them points at a file that does not exist or a line that is out of range.
It does not (and cannot) prove the *claim* is true at that line — that is what
review is for — but it makes a stale or invented citation impossible to merge.

Usage:
    python3 scripts/whitepaper/check_refs.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "docs" / "whitepaper"

REFERENCE = re.compile(
    r"((?:Sources|Tests|scripts|docs)/[A-Za-z0-9_./\-]+\.(?:swift|metal|md|json|sh)):(\d+)"
)
INTERNAL_LINK = re.compile(r"\]\(([A-Za-z0-9_\-]+)\.html(#[^)]*)?\)")


def main() -> int:
    nav = json.loads((SRC / "nav.json").read_text(encoding="utf-8"))
    slugs = {chapter["slug"] for chapter in nav["chapters"]}
    problems: list[str] = []
    checked = 0

    for chapter in nav["chapters"]:
        path = SRC / chapter["file"]
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        for match in REFERENCE.finditer(text):
            target, line_text = match.group(1), match.group(2)
            file = ROOT / target
            checked += 1
            if not file.exists():
                problems.append(f"{path.name}: missing file {target}")
                continue
            lines = file.read_text(encoding="utf-8", errors="replace").count("\n") + 1
            line = int(line_text)
            if line < 1 or line > lines:
                problems.append(f"{path.name}: {target}:{line} out of range (file has {lines} lines)")
        for match in INTERNAL_LINK.finditer(text):
            slug = match.group(1)
            if slug not in slugs:
                problems.append(f"{path.name}: link to unknown page {slug}.html")

    for problem in problems:
        print(f"FAIL {problem}")
    print(f"checked {checked} citations, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
