#!/bin/sh
# Build hdrmerge-swift and install it where Photons looks for it.
#
#   ./scripts/install-to-photons.sh                 # -> /usr/local/bin
#   ./scripts/install-to-photons.sh --in-app        # -> Photons.app/Contents/Resources/bin
#
# The binary is self-contained (no third-party dylibs), so a plain copy is enough.
set -e

APP="${PHOTONS_APP:-$HOME/Documents/GitHub/Photons/.build/Photons.app}"
if [ -w /opt/homebrew/bin ]; then DEST="/opt/homebrew/bin"; else DEST="/usr/local/bin"; fi

if [ "$1" = "--in-app" ]; then
    if [ ! -d "$APP" ]; then
        echo "no app bundle at $APP — run 'make app' in the Photons repo first" >&2
        exit 1
    fi
    DEST="$APP/Contents/Resources/bin"
fi

cd "$(dirname "$0")/.."
swift build -c release --product hdrmerge-swift
mkdir -p "$DEST"
cp .build/release/hdrmerge-swift "$DEST/hdrmerge-swift"
chmod +x "$DEST/hdrmerge-swift"
echo "installed: $DEST/hdrmerge-swift"
"$DEST/hdrmerge-swift" capabilities

if [ "$1" = "--in-app" ]; then
    echo
    echo "the bundle must be re-signed after adding a binary:"
    echo "  codesign --force --deep --sign - \"$APP\""
fi
