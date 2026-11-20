#!/usr/bin/env python3
"""Prove a Swift "move code out of a big file" commit is a move, not a rewrite.

The claim a split commit makes is mechanical: *these declarations left the host file and
landed, byte for byte, in the new files*. This checks exactly that claim and nothing else.

    scripts/verify_pure_move.py --old Sources/PhotonsUI/LoupeController.swift \
        --new Sources/PhotonsUI/Loupe/LoupeController+Masks.swift \
        --base main

What it compares, per path, from `git diff --base..HEAD`:

  * **removed** lines from `--old`  (payload: non-blank, non-`import`)
  * **added**   lines to the `--new` files
  * **added**   lines to `--old`     (a pure move should add none, except access-level
                                      widening — see `--widen`)

Access modifiers (`private` / `fileprivate` / `internal` / `public` / `private(set)`) are
normalised away on both sides before the multiset comparison, because a `private` member
that the host or a sibling file calls *must* become `internal` when it moves into an
`extension` in another file (Swift `private` is file-scoped). Every such line is then
reported, so the widening can be checked against the task's table instead of being
noticed by the compiler.

Structural lines a new file must add — `import …`, `extension Host {`, and the closing
`}` — are excluded, and the script asserts that the only surplus `}` per new file is that
one closing brace.

Exit codes: 0 move verified, 1 drift, 2 usage/git error.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import Counter

ACCESS = re.compile(r"\b(private\(set\)|private|fileprivate|internal|public|open)\b\s*")
EXTENSION = re.compile(r"^extension\s+\w+\s*\{\s*$")


def git(*args: str) -> str:
    out = subprocess.run(["git", *args], capture_output=True, text=True)
    if out.returncode != 0:
        sys.stderr.write(out.stderr)
        raise SystemExit(2)
    return out.stdout


def side_lines(base: str, rev: str, path: str) -> tuple[list[str], list[str]]:
    text = git("diff", "-U0", f"{base}..{rev}", "--", path)
    removed, added = [], []
    for line in text.splitlines():
        if line.startswith(("---", "+++")):
            continue
        if line.startswith("-"):
            removed.append(line[1:])
        elif line.startswith("+"):
            added.append(line[1:])
    return removed, added


def payload(lines) -> list[str]:
    keep = []
    for line in lines:
        s = line.strip()
        if not s or s.startswith("import "):
            continue
        keep.append(line)
    return keep


def normalise(line: str) -> str:
    """Drop access keywords so `private var x` and `internal var x` compare equal."""
    return ACCESS.sub("", line)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", required=True)
    ap.add_argument("--new", nargs="+", required=True)
    ap.add_argument("--base", default="main")
    ap.add_argument("--rev", default="HEAD")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    ok = True
    say = (lambda *a: None) if args.quiet else print

    removed_raw, added_to_old_raw = side_lines(args.base, args.rev, args.old)
    removed = payload(removed_raw)
    added_to_old = payload(added_to_old_raw)

    new_lines: list[str] = []
    per_file: dict[str, list[str]] = {}
    for path in args.new:
        _, added = side_lines(args.base, args.rev, path)
        if not added:
            print(f"FAIL: {path} gained no lines between {args.base} and {args.rev} — "
                  f"wrong path, or the file already existed at the base revision")
            ok = False
        body = payload(added)
        per_file[path] = body
        new_lines.extend(body)

    # structural lines a moved block carries with it are filtered from both sides;
    # the only surplus is one `extension Host {` + one `}` per new file.
    def structural(line: str) -> bool:
        return line.strip() == "}" or bool(EXTENSION.match(line.strip()))

    new_code = [l for l in new_lines if not structural(l)]
    removed_code = [l for l in removed if not structural(l)]
    closes_new = len([l for l in new_lines if l.strip() == "}"])
    closes_old = len([l for l in removed if l.strip() == "}"])
    surplus_closes = closes_new - closes_old
    # a moved *type* brings its own braces (balanced); a moved *extension* adds one pair
    extensions = (len([l for l in new_lines if EXTENSION.match(l.strip())])
                  - len([l for l in removed if EXTENSION.match(l.strip())]))

    say(f"old file: {len(removed)} code lines removed, {len(added_to_old)} added")
    say(f"new files: {len(new_lines)} lines, {extensions} extension header(s), "
        f"closing braces +{surplus_closes} (expect +{extensions})")
    if surplus_closes != extensions:
        ok = False
        say(f"FAIL: expected +{extensions} closing braces, found +{surplus_closes}")

    # 1. the host must not gain code, only access-level changes on existing declarations
    widening = []
    for line in added_to_old:
        widening.append(line)
    if widening:
        say(f"{len(widening)} line(s) ADDED to the host — every one must be access widening:")
        for line in widening[:40]:
            say(f"  + {line.strip()}")
        widened_removed = Counter(normalise(l) for l in removed_code)
        for line in widening:
            if normalise(line) not in widened_removed:
                ok = False
                say(f"FAIL: host gained a real line (not a widening of a removed one): "
                    f"{line.strip()}")

    # 2. the move itself: identical content once access keywords are ignored
    missing = Counter(normalise(l) for l in removed_code) - Counter(normalise(l) for l in new_code)
    extra = Counter(normalise(l) for l in new_code) - Counter(normalise(l) for l in removed_code)
    if missing or extra:
        ok = False
        say("FAIL: content drifted between the host and the new files")
        for line, n in list(missing.items())[:10]:
            say(f"  missing x{n}: {line}")
        for line, n in list(extra.items())[:10]:
            say(f"  extra   x{n}: {line}")

    # 3. access level changes actually introduced, by name, for the task's widening table
    def names(lines):
        out = {}
        for line in lines:
            m = re.search(r"\b(?:var|let|func|struct|class|enum)\s+(\w+)", line)
            if m:
                out[m.group(1)] = line.strip()
        return out

    old_access = {}
    for line in removed:
        m = re.search(r"\b(?:var|let|func)\s+(\w+)", line)
        if m:
            a = ACCESS.search(line)
            old_access[m.group(1)] = (a.group(1) if a else "internal")
    widened = []
    for line in list(new_code) + list(widening):
        m = re.search(r"\b(?:var|let|func)\s+(\w+)", normalise(line))
        if not m:
            continue
        name = m.group(1)
        a = ACCESS.search(line)
        new_a = a.group(1) if a else "internal"
        if name in old_access and old_access[name] in ("private", "fileprivate") \
                and new_a in ("internal", "public"):
            widened.append((name, old_access[name], new_a))
    if widened:
        say(f"{len(widened)} member(s) widened "
            f"(must match the task's table):")
        for name, a, b in widened:
            say(f"  {name}: {a} -> {b}")

    if ok:
        say("OK: the commit is a pure move (access keywords normalised away)")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
