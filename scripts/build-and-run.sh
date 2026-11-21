#!/bin/zsh
# Build Photons into its default location and launch it.
#
#   scripts/build-and-run.sh              # compile, then (only on success) close + relaunch
#   scripts/build-and-run.sh --no-launch  # compile only; a running app is never touched
#   PHOTONS_LIBRARY=/path/to/lib.photonslibrary scripts/build-and-run.sh
#
# Run this from the **main checkout** only. A lane worktree's `.build` is a per-lane snapshot of the
# app; launching one looks exactly like "the app regressed" (it has, several times).
#
# Two phases, in this order on purpose:
#
#   1. **compile** - writes only into `.build` and `Vendor/*/.build`. A running Photons must
#      survive a failed build: the copy on screen is the last one that worked.
#   2. **bundle** - copies the tools into `Photons.app` and re-signs it. This cannot run while
#      the app is up (codesign answers "Operation not permitted" for a bundle whose executable
#      is running), so an app that is running is closed here, after the compile succeeded.
#
# `--no-launch` keeps a running app alive; since the bundle phase would fail against it, the
# script stops after compiling and says so.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/.build/Photons.app"
LIBRARY="${PHOTONS_LIBRARY:-$HOME/Documents/photons-demo.photonslibrary}"
LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    --no-launch) LAUNCH=0 ;;
    *) print -u2 "unknown flag: $arg"; exit 2 ;;
  esac
done

cd "$REPO"
if [ "$(git status --porcelain | wc -l | tr -d ' ')" != "0" ]; then
  print -u2 "note: building an uncommitted working tree"
fi

app_running() { pgrep -x Photons >/dev/null 2>&1; }

# -- 1. compile ----------------------------------------------------------------------------------
# The HDR merge tool ships inside the app, and `make app` packs it (scripts/bundle-app.sh does so
# right before the signature). But `make app` cannot *build* it: that source is a nested GPLv3
# package the root Package.swift deliberately does not mention, so SwiftPM has no edge to it.
# Compile it here, from source, every time - a stale binary that still runs is indistinguishable
# from a working one until you press the menu item.
print "compile   hdrmerge-swift"
swift build -c release --package-path Vendor/hdrmerge-swift --product hdrmerge-swift

# Same rule for the denoise tool, and here it has already bitten once (2026-11-12): the pointer
# protocol went 1 -> 2 (`image-dng`) in `Vendor/ansel-denoise-swift`, but `bundle-ansel-denoise.sh`
# only copies `Vendor/.build/release/ansel-denoise-swift`. A build made before that change still
# answered `capabilities`, so `AnselDenoiseJob` rejected it as "tool too old".
print "compile   ansel-denoise-swift"
swift build -c release --package-path Vendor/ansel-denoise-swift --product ansel-denoise-swift

# The nonlocal denoiser is a real SwiftPM edge (`Package.swift` -> `Vendor/nonlocal-matchfilter-swift`),
# so the app build compiles it anyway. Building it first puts a half-synced vendor tree on a step whose
# name says where to look, instead of failing inside the app build at a target nobody was editing.
# Own scratch path, so the app's incremental build stays valid.
print "compile   nonlocal-matchfilter-swift"
swift build -c release --package-path Vendor/nonlocal-matchfilter-swift \
            --scratch-path .build/vendor-nonlocal --product NonlocalMatchFilter

print "compile   Photons"
swift build -c release

# -- 2. bundle ----------------------------------------------------------------------------------─
if [ "$LAUNCH" = "0" ] && app_running; then
  print "note      compiled; Photons is running, so packaging and signing are skipped"
  print "          (--no-launch never touches a running app)"
  print "          quit the app and run this script again to install it into the bundle"
  exit 0
fi

if [ "$LAUNCH" = "1" ] && app_running; then
  osascript -e 'tell application "Photons" to quit' >/dev/null 2>&1 || pkill -x Photons || true
  for _ in {1..20}; do app_running || break; sleep 0.25; done
  if app_running; then
    print -u2 "old instance did not quit; killing"
    pkill -x Photons || true
    sleep 0.5
  fi
  print "closed    previous instance (compile had succeeded)"
fi

scripts/build-hdrmerge.sh
scripts/build-ansel-denoise.sh --to-app
make app

# The icon comes from Resources/AppIcon.icon (Icon Composer document) plus the classic icns
# baked by scripts/appicon.py: macOS 26+ uses the .icon liquid glass, older versions fall back
# to AppIcon.icns inside the bundle.
ICNS="$APP/Contents/Resources/AppIcon.icns"
if [ -f "$ICNS" ]; then
  print "icon    AppIcon.icns  $(stat -f%z "$ICNS" | numfmt --to=iec 2>/dev/null || stat -f%z "$ICNS") bytes"
else
  print -u2 "icon    missing $ICNS"
fi

REV="$(/usr/libexec/PlistBuddy -c 'Print :PhotonsGitRevision' "$APP/Contents/Info.plist" 2>/dev/null || git rev-parse --short HEAD)"
print "built  $REV  ($(git rev-parse --abbrev-ref HEAD))"

if [ "$LAUNCH" = "1" ]; then
  open "$APP" --args --library "$LIBRARY"
  sleep 2
  if app_running; then
    print "launched  pid $(pgrep -x Photons | head -1)  library $LIBRARY"
  else
    print -u2 "launch failed"; exit 1
  fi
fi
