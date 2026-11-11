#!/usr/bin/env bash
# Pack the hdrmerge-swift CLI into the built Photons.app.
#
#   scripts/bundle-hdrmerge.sh              # into .build/Photons.app
#   scripts/bundle-hdrmerge.sh /path/App    # into a specific bundle
#
# Additive on purpose: this script does not touch `scripts/bundle-app.sh`. Run it after
# `make app`, or just use `scripts/make-app-with-hdr.sh` which chains everything. The app itself
# needs no code change to carry the tool, because `HDRMergeClient` resolves
# `Contents/Resources/bin/hdrmerge-swift` first.
#
# The binary comes from `Vendor/hdrmerge-swift` by default (scripts/build-hdrmerge.sh); an
# installed copy on PATH is only a fallback, so a fresh clone does not need a second checkout.
#
# Licensing (see hdrmerge-swift/LICENSE-SCOPE.md): the tool is GPLv3 and ships as a **separate
# executable**. Photons stays MIT because it spawns it (Process + paths + JSON), which GPLv3 §5
# calls an aggregate — not a combined work. This script also drops the GPL text and the §6(d)
# source offer next to the binary, which is the obligation that comes with shipping it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/.build/Photons.app}"
VENDOR_BIN="$ROOT/Vendor/hdrmerge-swift/.build/${CONFIG:-release}/hdrmerge-swift"
BIN_SRC="${HDRMERGE_BIN:-}"
if [ -z "$BIN_SRC" ] && [ -x "$VENDOR_BIN" ]; then BIN_SRC="$VENDOR_BIN"; fi
if [ -z "$BIN_SRC" ]; then BIN_SRC="$(command -v hdrmerge-swift || true)"; fi

if [ ! -d "$APP" ]; then
    echo "bundle-hdrmerge: no app at $APP — run 'make app' first" >&2
    exit 1
fi
if [ -z "$BIN_SRC" ] || [ ! -x "$BIN_SRC" ]; then
    echo "bundle-hdrmerge: hdrmerge-swift not built." >&2
    echo "  build it from the vendored source:  scripts/build-hdrmerge.sh --to-app" >&2
    exit 1
fi

DEST="$APP/Contents/Resources/bin"
mkdir -p "$DEST" "$APP/Contents/Resources/licenses"

cp "$BIN_SRC" "$DEST/hdrmerge-swift"
chmod +x "$DEST/hdrmerge-swift"
( cd "$DEST" && shasum -a 256 hdrmerge-swift > hdrmerge-swift.sha256 )

cp "$ROOT/Resources/hdrmerge-swift-LICENSE.txt" \
   "$APP/Contents/Resources/licenses/hdrmerge-swift-GPL-3.0.txt"
cp "$ROOT/Resources/hdrmerge-swift-SOURCE-OFFER.txt" \
   "$APP/Contents/Resources/licenses/hdrmerge-swift-SOURCE-OFFER.txt"

# A binary inside the bundle changes the code directory, so the signature has to be redone.
# Ad-hoc, exactly like bundle-app.sh does it for the app itself.
xattr -cr "$APP/Contents/Resources/bin" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    || codesign --force --sign - "$APP"

printf 'hdrmerge   %s → %s\n' "$BIN_SRC" "$DEST/hdrmerge-swift"
"$DEST/hdrmerge-swift" capabilities
codesign -v "$APP" && echo "signature  OK"
