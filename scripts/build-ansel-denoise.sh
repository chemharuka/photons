#!/usr/bin/env bash
# Build the vendored ansel-denoise-swift and put the executable where Photons looks for it.
#
#   scripts/build-ansel-denoise.sh              # build → /opt/homebrew/bin (or /usr/local/bin)
#   scripts/build-ansel-denoise.sh --to-app     # build → .build/Photons.app/Contents/Resources/bin
#
# Why this is a script and not a SwiftPM target: `Vendor/ansel-denoise-swift` is **GPLv3**
# (derived from aurelienpierreeng/ansel-denoise) and Photons is MIT. It is a nested package the
# root `Package.swift` deliberately does not know about, so SwiftPM never adds an edge between
# the two. Shelling out to `swift build` keeps the code in one tree while keeping the build
# graphs separate — exactly as scripts/build-hdrmerge.sh does, and see
# Vendor/ansel-denoise-swift/LICENSE-SCOPE.md.
#
# The model weights are NOT built or bundled: they are fetched separately and verified by
# sha256 (see the vendor README). Without them the tool still runs and reports
# `tool_missing`-equivalent errors rather than crashing, and the app hides the feature.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/ansel-denoise-swift"
APP="${PHOTONS_APP:-$ROOT/.build/Photons.app}"
CONFIG="${CONFIG:-release}"

if [ ! -f "$VENDOR/Package.swift" ]; then
    echo "build-ansel-denoise: $VENDOR is missing its sources" >&2
    exit 1
fi

echo "ansel-denoise  building $CONFIG from Vendor/ansel-denoise-swift"
( cd "$VENDOR" && swift build -c "$CONFIG" --product ansel-denoise-swift )

BIN="$VENDOR/.build/$CONFIG/ansel-denoise-swift"
[ -x "$BIN" ] || { echo "build-ansel-denoise: no executable at $BIN" >&2; exit 1; }

if [ "${1:-}" = "--to-app" ]; then
    DEST="$APP/Contents/Resources/bin"
    mkdir -p "$DEST"
    cp "$BIN" "$DEST/ansel-denoise-swift"
    echo "ansel-denoise  → $DEST/ansel-denoise-swift"
else
    # A dev install so AnselDenoiseClient's resolution order finds it without a bundle.
    for d in /opt/homebrew/bin /usr/local/bin; do
        if [ -d "$d" ] && [ -w "$d" ]; then
            cp "$BIN" "$d/ansel-denoise-swift"
            echo "ansel-denoise  → $d/ansel-denoise-swift"
            exit 0
        fi
    done
    echo "ansel-denoise  built at $BIN (no writable bin dir; copy it yourself or use --to-app)"
fi
