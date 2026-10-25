#!/usr/bin/env bash
# Assemble .build/Photons.app around the SwiftPM executable.
#
#   scripts/bundle-app.sh [debug|release]
#
# Why a script and not an Xcode project: the repo is SwiftPM-only (no .xcodeproj anywhere), the
# Metal toolchain component is not installed on this machine, and `make verify` must stay a single
# command. A bundle is just a directory layout plus Info.plist plus a signature, so 40 lines of shell
# is the whole build system we need.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP="$ROOT/.build/Photons.app"

if [ ! -x "$BUILD_DIR/Photons" ]; then
    echo "bundle-app: no executable at $BUILD_DIR/Photons" >&2
    echo "            run: swift build -c $CONFIG" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/Photons" "$APP/Contents/MacOS/Photons"
cp "$ROOT/scripts/App-Info.plist" "$APP/Contents/Info.plist"

# Kernels ship as a copied resource bundle and are compiled at runtime by Metal.framework
# (docs/architecture-decisions.md M1-1). `Bundle.module` looks in Bundle.main.resourceURL, which is
# Contents/Resources inside an app bundle — so that is the one place they go. (Copying them into
# Contents/MacOS as well would put unsigned bundles inside the code directory and break codesign.)
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

xattr -cr "$APP" 2>/dev/null || true
# Ad-hoc signature: enough to launch locally and to keep Gatekeeper quiet on this machine.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    || codesign --force --sign - "$APP" \
    || { echo "bundle-app: ad-hoc codesign failed" >&2; exit 1; }

printf 'bundle      %s\n' "$APP"
printf 'executable  %s\n' "$APP/Contents/MacOS/Photons"
printf 'resources   %s\n' "$(ls "$APP/Contents/Resources" 2>/dev/null | tr '\n' ' ')"
