#!/usr/bin/env bash
# Pack the hdrmerge-swift CLI into the built Photons.app.
#
#   scripts/bundle-hdrmerge.sh              # into .build/Photons.app
#   scripts/bundle-hdrmerge.sh /path/App    # into a specific bundle
#
# Additive on purpose: this script does not touch `scripts/bundle-app.sh`. Run it after
# `make app` (or add it to your own wrapper) — the app itself needs no code change to carry
# the tool, because `HDRMergeClient` resolves `Contents/Resources/bin/hdrmerge-swift` first.
#
# Licensing (see hdrmerge-swift/LICENSE-SCOPE.md): the tool is GPLv3 and ships as a **separate
# executable**. Photons stays MIT because it spawns it (Process + paths + JSON), which GPLv3 §5
# calls an aggregate — not a combined work. This script also drops the GPL text and the §6(d)
# source offer next to the binary, which is the obligation that comes with shipping it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/.build/Photons.app}"
BIN_SRC="${HDRMERGE_BIN:-$(command -v hdrmerge-swift || true)}"

if [ ! -d "$APP" ]; then
    echo "bundle-hdrmerge: no app at $APP — run 'make app' first" >&2
    exit 1
fi
if [ -z "$BIN_SRC" ] || [ ! -x "$BIN_SRC" ]; then
    echo "bundle-hdrmerge: hdrmerge-swift not found." >&2
    echo "  install it first:  cd ~/Documents/GitHub/hdrmerge-swift && ./scripts/install-to-photons.sh" >&2
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
