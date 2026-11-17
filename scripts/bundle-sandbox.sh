#!/usr/bin/env bash
# Isolated local sandbox build; does not replace Photons.app or Photons Studio.app.
# PHOTONS_SIGN_IDENTITY may name a development certificate. Ad-hoc signing supports
# local diagnostics only; it is not a TestFlight/App Store distribution identity.
set -euo pipefail
PHOTONS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHOTONS_CONFIG="${1:-release}"
PHOTONS_SANDBOX_APP="$PHOTONS_ROOT/.build/Photons Sandbox.app"
PHOTONS_SIGN_IDENTITY="${PHOTONS_SIGN_IDENTITY:--}"
swift build --package-path "$PHOTONS_ROOT" -c "$PHOTONS_CONFIG"
swift build --package-path "$PHOTONS_ROOT/Vendor/hdrmerge-swift" -c "$PHOTONS_CONFIG"
swift build --package-path "$PHOTONS_ROOT/Vendor/ansel-denoise-swift" -c "$PHOTONS_CONFIG"
PHOTONS_APP="$PHOTONS_SANDBOX_APP" CONFIG="$PHOTONS_CONFIG" "$PHOTONS_ROOT/scripts/bundle-app.sh" "$PHOTONS_CONFIG"
if [ ! -f "$PHOTONS_SANDBOX_APP/Contents/Resources/bin/models/denoise-quarter-single-v1.anselnn" ]; then
    echo "Sandbox package is incomplete: provide the model via PHOTONS_ANSEL_MODEL or local/models/." >&2
    exit 1
fi
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.leoaokma.photons.sandbox' "$PHOTONS_SANDBOX_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Photons Sandbox' "$PHOTONS_SANDBOX_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Photons Sandbox' "$PHOTONS_SANDBOX_APP/Contents/Info.plist"
for PHOTONS_HELPER in ansel-denoise-swift hdrmerge-swift photons-panorama-worker; do
    PHOTONS_BINARY="$PHOTONS_SANDBOX_APP/Contents/Resources/bin/$PHOTONS_HELPER"
    test -x "$PHOTONS_BINARY"
    codesign --force --sign "$PHOTONS_SIGN_IDENTITY" --timestamp=none \
        --entitlements "$PHOTONS_ROOT/scripts/Photons-Helper.entitlements" "$PHOTONS_BINARY"
    (cd "$PHOTONS_SANDBOX_APP/Contents/Resources/bin" && shasum -a 256 "$PHOTONS_HELPER" > "$PHOTONS_HELPER.sha256")
done
python3 "$PHOTONS_ROOT/scripts/bundle-gpl-sources.py" "$PHOTONS_SANDBOX_APP"
# Sign resource bundles before the app. Do not use --deep to invent entitlements for nested code.
for PHOTONS_RESOURCE in "$PHOTONS_SANDBOX_APP/Contents/Resources/"*.bundle; do
    test -d "$PHOTONS_RESOURCE" || continue
    codesign --force --sign "$PHOTONS_SIGN_IDENTITY" --timestamp=none "$PHOTONS_RESOURCE"
done
codesign --force --sign "$PHOTONS_SIGN_IDENTITY" --timestamp=none \
    --entitlements "$PHOTONS_ROOT/scripts/Photons-Sandbox.entitlements" "$PHOTONS_SANDBOX_APP"
codesign --verify --deep --strict "$PHOTONS_SANDBOX_APP"
codesign --display --entitlements - "$PHOTONS_SANDBOX_APP"
printf 'Sandbox app: %s\n' "$PHOTONS_SANDBOX_APP"
