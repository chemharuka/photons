#!/usr/bin/env bash
# Put ansel-denoise-swift and its licence paperwork into a built Photons.app.
#
# Mirrors scripts/bundle-hdrmerge.sh: the binary goes to Contents/Resources/bin, the GPL text
# and a §6(d) source offer go to Contents/Resources/licenses, and the sha256 of what was
# actually shipped is recorded next to the binary.
#
#   scripts/bundle-ansel-denoise.sh [path/to/Photons.app]
#
# Run scripts/build-ansel-denoise.sh first (it produces the executable).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/ansel-denoise-swift"
APP="${1:-${PHOTONS_APP:-$ROOT/.build/Photons.app}}"
CONFIG="${CONFIG:-release}"

SRC="$VENDOR/.build/$CONFIG/ansel-denoise-swift"
if [ ! -x "$SRC" ]; then
    echo "bundle-ansel-denoise: no built executable at $SRC" >&2
    echo "  run scripts/build-ansel-denoise.sh first" >&2
    exit 1
fi
if [ ! -d "$APP" ]; then
    echo "bundle-ansel-denoise: $APP does not exist" >&2
    exit 1
fi

DEST="$APP/Contents/Resources/bin"
LIC="$APP/Contents/Resources/licenses"
mkdir -p "$DEST" "$LIC"

cp "$SRC" "$DEST/ansel-denoise-swift"
( cd "$DEST" && shasum -a 256 ansel-denoise-swift > ansel-denoise-swift.sha256 )

cp "$VENDOR/LICENSE" "$LIC/ansel-denoise-swift-GPL-3.0.txt"

# Generate the offer instead of hand-maintaining it: the version, the sha256 it names and the
# licence text location are facts about *this* build, and a hand-written copy goes stale.
BINARY_SHA="$(awk '{print $1}' "$DEST/ansel-denoise-swift.sha256" 2>/dev/null || echo unknown)"
cat > "$LIC/ansel-denoise-swift-SOURCE-OFFER.txt" <<OFFER
ansel-denoise-swift — source offer (GPL-3.0 §6(d))

This application ships the executable

    Contents/Resources/bin/ansel-denoise-swift
    sha256 ${BINARY_SHA}

which is a Swift + Metal rewrite of the neural raw denoiser from

    https://github.com/aurelienpierreeng/ansel-denoise   (GPL-3.0-or-later)

That program is licensed under the GNU General Public License version 3. A copy of the licence
is at Contents/Resources/licenses/ansel-denoise-swift-GPL-3.0.txt.

Its complete corresponding source code is vendored in this same distribution at

    Vendor/ansel-denoise-swift/

so a recipient of this binary already has the source. It is not linked into the Photons
application: Photons starts it as a separate process and communicates over a pipe and
temporary files. See Vendor/ansel-denoise-swift/LICENSE-SCOPE.md for the aggregation argument
(GPLv3 §5, GNU GPL FAQ #MereAggregation).

The Photons application itself is MIT-licensed and contains none of the GPL code.

Model weights (.anselnn) are not included. They are published separately by the same upstream
project under models/manifest.json with per-file sha256 digests.
OFFER

echo "bundle-ansel-denoise:"
echo "  binary   → $DEST/ansel-denoise-swift  ($BINARY_SHA)"
echo "  licence  → $LIC/ansel-denoise-swift-GPL-3.0.txt"
echo "  offer    → $LIC/ansel-denoise-swift-SOURCE-OFFER.txt"
