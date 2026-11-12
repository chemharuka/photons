#!/usr/bin/env bash
# Build the vendored hdrmerge-swift and put the executable where Photons looks for it.
#
#   scripts/build-hdrmerge.sh              # build → .build/Photons.app/Contents/Resources/bin
#   scripts/build-hdrmerge.sh --to-app     # same thing (kept so existing callers keep working)
#   scripts/build-hdrmerge.sh --to-path    # build → /opt/homebrew/bin (dev-only escape hatch)
#
# The default is the app bundle, not a system directory: hdrmerge-swift ships **inside** Photons
# and nowhere else. `HDRMergeClient` resolves `Contents/Resources/bin/hdrmerge-swift` first, so a
# copy in /opt/homebrew/bin adds nothing for users and silently shadows the bundled one on a
# developer machine — a stale install there makes the app run last week's merge code without any
# sign of it. Install to a system path only when debugging the tool on its own, on purpose.
#
# Why this is a script and not a SwiftPM target: `Vendor/hdrmerge-swift` is **GPLv3** and Photons is
# MIT. It is a nested package the root `Package.swift` deliberately does not know about, so SwiftPM
# never adds an edge between the two. Shelling out to `swift build` keeps the code in one tree (no
# hunting for a second checkout) while keeping the build graphs separate — see
# VENDOR-hdrmerge-swift.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/hdrmerge-swift"
APP="${PHOTONS_APP:-$ROOT/.build/Photons.app}"
CONFIG="${CONFIG:-release}"

if [ ! -f "$VENDOR/Package.swift" ]; then
    echo "build-hdrmerge: $VENDOR is missing its sources" >&2
    exit 1
fi

echo "hdrmerge    building $CONFIG from Vendor/hdrmerge-swift ($(awk '/^commit/{print $2}' "$VENDOR/VERSION.txt"))"
( cd "$VENDOR" && swift build -c "$CONFIG" --product hdrmerge-swift )

BIN="$VENDOR/.build/$CONFIG/hdrmerge-swift"
[ -x "$BIN" ] || { echo "build-hdrmerge: no executable at $BIN" >&2; exit 1; }

case "${1:-}" in
    ""|--to-app)
        [ -d "$APP" ] || { echo "build-hdrmerge: no app at $APP — run 'make app' first" >&2; exit 1; }
        DEST="$APP/Contents/Resources/bin"
        ;;
    --to-path)
        echo "build-hdrmerge: installing to a system path on purpose (dev only)" >&2
        if [ -w /opt/homebrew/bin ]; then DEST="/opt/homebrew/bin"; else DEST="/usr/local/bin"; fi
        ;;
    *)
        echo "build-hdrmerge: unknown option '$1'" >&2
        echo "  (no option)  install into the app bundle   [default]" >&2
        echo "  --to-path    install into a system bin dir  [dev only]" >&2
        exit 2
        ;;
esac

mkdir -p "$DEST"
cp "$BIN" "$DEST/hdrmerge-swift"
chmod +x "$DEST/hdrmerge-swift"
( cd "$DEST" && shasum -a 256 hdrmerge-swift > hdrmerge-swift.sha256 )
printf 'installed   %s\n' "$DEST/hdrmerge-swift"
"$DEST/hdrmerge-swift" capabilities
