#!/usr/bin/env bash
# `make ui-bench` — 10k-row placeholder grid scroll (main-thread p99) + loupe frame timings.
#
# Honest label: these are placeholder cards. No thumbnail generation, no decode, no GPU work in the
# measured loop, so the number describes the *grid* (layout, reuse, drawing) and nothing else.
#
# The 10k library is built once and reused; delete local/out/ui-bench.photonslibrary to rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
RAW="${RAW:-$HOME/Desktop/test/L1030433.dng}"
OUT="$ROOT/local/out"
BIN="$ROOT/.build/$CONFIG/photonsctl"
APP="$ROOT/.build/Photons.app"
LIB="$OUT/ui-bench.photonslibrary"
SRC="$OUT/ui-bench-src"
COUNT="${COUNT:-10000}"

[ -x "$APP/Contents/MacOS/Photons" ] || { echo "ui-bench: no app bundle (make app)" >&2; exit 1; }
mkdir -p "$OUT"

if [ ! -d "$LIB" ]; then
    echo "fixtures    $COUNT synthetic photos → $SRC"
    rm -rf "$SRC"; mkdir -p "$SRC"
    "$BIN" fixtures "$SRC" --count "$COUNT" --dupes 0 --size 320x240 >/dev/null
    if [ -f "$RAW" ]; then cp "$RAW" "$SRC/$(basename "$RAW")"; fi
    "$BIN" library create "$LIB" >/dev/null
    echo "import      $COUNT files (one hash each) …"
    "$BIN" library import "$LIB" "$SRC" --mode reference --json >/dev/null
fi

ROWS="$("$BIN" library stats "$LIB" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["assets"])')"
echo "library     $LIB ($ROWS rows)"
"$APP/Contents/MacOS/Photons" --ui-bench "$LIB" --expect-rows "$ROWS" --shots "$OUT"
