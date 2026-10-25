#!/usr/bin/env bash
# `make ui-smoke` — the M3 acceptance harness that needs a real window.
#
#   1000 synthetic photos + 1 real RAW  →  library  →  Photons --ui-smoke
#
# The app asserts, in order: grid item count == library rows; three window widths produce the
# columns/row height of the pure layout function; the grid draws real thumbnails from
# `ThumbnailCache` (tier = cell edge × DPR, warm pass = memory hits only, off-screen loads
# cancelled, worker queue bounded); the filmstrip mirrors the library and shares the selection
# **and draws its own real thumbnails** (74 × 50 pt cells at the DPR tier, every cell the sweep
# showed has an image, ≥ 36 of them, nothing left queued for cells that scrolled away); the grid
# and the strip turn out to share one `ThumbnailProvider`/`ThumbnailService` (no cache key — and
# no `contentHash` — is ever generated twice, and re-asking from the other view is a memory hit);
# a `t1024` DNG request is downgraded to `t512` with `skipReason= dngCeiling` and leaves no
# `t1024` file behind (006 §6.1); the loupe renders a frame through RenderGraph; a slider drag
# changes the presented frame hash, ⌘Z returns it to the previous hash and ⇧⌘Z returns it again;
# the undo/redo menu items validate to disabled with an empty history. Screenshots land in
# local/out/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
RAW="${RAW:-$HOME/Desktop/test/L1030433.dng}"
OUT="$ROOT/local/out"
BIN="$ROOT/.build/$CONFIG/photonsctl"
APP="$ROOT/.build/Photons.app"
LIB="$OUT/ui-smoke.photonslibrary"
SRC="$OUT/ui-smoke-src"
COUNT="${COUNT:-1000}"

[ -x "$BIN" ] || { echo "ui-smoke: build first (make build)" >&2; exit 1; }
[ -x "$APP/Contents/MacOS/Photons" ] || { echo "ui-smoke: no app bundle (make app)" >&2; exit 1; }

mkdir -p "$OUT"
rm -rf "$LIB" "$SRC"
mkdir -p "$SRC"

echo "fixtures    $COUNT synthetic photos → $SRC"
"$BIN" fixtures "$SRC" --count "$COUNT" --dupes 0 --size 320x240 >/dev/null

# The loupe needs one real RAW (the fixtures are JPEGs), and it must be imported from the *same*
# directory as the fixtures: a reference import takes its source root from the first import of the
# volume (roots are volume-identified, not path-identified — the M2 rule), so a second directory on
# the same disk would attach its rows to the first root and every relPath would point at nothing.
if [ -f "$RAW" ]; then
    cp "$RAW" "$SRC/$(basename "$RAW")"
else
    echo "ui-smoke: no RAW at $RAW — the loupe will have no real photo to render" >&2
fi

"$BIN" library create "$LIB" >/dev/null
"$BIN" library import "$LIB" "$SRC" --mode reference --json >/dev/null

ROWS="$("$BIN" library stats "$LIB" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["assets"])')"
echo "library     $LIB"
echo "rows        $ROWS"

set +e
"$APP/Contents/MacOS/Photons" --ui-smoke "$LIB" --expect-rows "$ROWS" --shots "$OUT"
CODE=$?
set -e

if [ $CODE -ne 0 ]; then
    echo "ui-smoke    FAIL (exit $CODE)" >&2
    exit $CODE
fi
echo "ui-smoke    PASS  (screenshots in $OUT/ui-smoke-*.png)"
