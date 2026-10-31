#!/usr/bin/env python3
"""Check every external link in the whitepaper.

Workers were asked to verify links themselves, but a self-report is not a
verification. This script re-checks every http(s) URL found in
docs/whitepaper/*.md, concurrently, and prints the final URL and status.

Usage:
    python3 scripts/whitepaper/check_links.py            # report only
    python3 scripts/whitepaper/check_links.py --strict   # exit 1 on any failure
"""

from __future__ import annotations

import concurrent.futures as futures
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "docs" / "whitepaper"
URL = re.compile(r"https?://[^\s<>\)\]\"'，。；、]+")

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                  "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
    "Accept": "text/html,application/xhtml+xml,application/pdf;q=0.9,*/*;q=0.8",
}


def collect() -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    seen: set[str] = set()
    for path in sorted(SRC.glob("*.md")):
        for match in URL.finditer(path.read_text(encoding="utf-8")):
            url = match.group(0).rstrip(".,;:")
            if url in seen:
                continue
            seen.add(url)
            found.append((path.name, url))
    return found


def check(item: tuple[str, str]) -> tuple[str, str, str]:
    page, url = item
    request = urllib.request.Request(url, headers=HEADERS, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return page, url, f"{response.status} {response.geturl()}"
    except urllib.error.HTTPError as error:
        return page, url, f"HTTP {error.code}"
    except Exception as error:  # noqa: BLE001 - a link check reports, never raises
        return page, url, f"{type(error).__name__}: {error}"


def main() -> int:
    strict = "--strict" in sys.argv[1:]
    links = collect()
    if not links:
        print("no external links found")
        return 0

    failures = 0
    with futures.ThreadPoolExecutor(max_workers=8) as pool:
        for page, url, result in pool.map(check, links):
            ok = result.startswith("2") or result.startswith("3")
            if not ok:
                failures += 1
            print(f"{'ok  ' if ok else 'FAIL'} {page:28s} {result:60s} {url}")
    print(f"\n{len(links)} unique link(s), {failures} failure(s)")
    return 1 if failures and strict else 0


if __name__ == "__main__":
    sys.exit(main())
