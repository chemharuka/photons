#!/bin/zsh
# Build Photons into its default location and launch it.
#
#   scripts/build-and-run.sh              # release build + relaunch with the demo library
#   scripts/build-and-run.sh --no-launch  # build only
#   PHOTONS_LIBRARY=/path/to/lib.photonslibrary scripts/build-and-run.sh
#
# Run this from the **main checkout** only. A lane worktree's `.build` is a per-lane snapshot of the
# app; launching one looks exactly like "the app regressed" (it has, several times).
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

# A running copy keeps the old binary on screen, which then gets blamed on the new build.
if pgrep -x Photons >/dev/null 2>&1; then
  osascript -e 'tell application "Photons" to quit' >/dev/null 2>&1 || pkill -x Photons || true
  for _ in {1..20}; do pgrep -x Photons >/dev/null 2>&1 || break; sleep 0.25; done
fi

# The HDR merge tool ships inside the app, and `make app` packs it (scripts/bundle-app.sh does so
# right before the signature). But `make app` cannot *build* it: that source is a nested GPLv3
# package the root Package.swift deliberately does not mention, so SwiftPM has no edge to it.
# Compile it **first**, otherwise the bundle step packs whatever binary was left from last time —
# which is exactly the failure that let a stale tool answer for the app.
scripts/build-hdrmerge.sh

# Same rule for the denoise tool, and here it has already bitten once (2026-11-12): the pointer
# protocol went 1 → 2 (`image-dng`) in `Vendor/ansel-denoise-swift`, but `bundle-ansel-denoise.sh`
# only copies `Vendor/.build/release/ansel-denoise-swift`. A build made before that change still
# answered `capabilities`, so `AnselDenoiseJob` refused it as "工具太旧" — the 「降噪中」框 appeared
# and vanished in one frame with the GPU never waking up. Compile from source every time: a stale
# binary that still runs is indistinguishable from a working one until you press the menu item.
scripts/build-ansel-denoise.sh --to-app

make app

# 图标来自 Resources/AppIcon.icon（Icon Composer 文档）+ 由 scripts/appicon.py 烘出的经典 icns。
# 26+ 用 .icon 的液态玻璃，低版本自动回退到 bundle 里的 AppIcon.icns。
ICNS="$APP/Contents/Resources/AppIcon.icns"
if [ -f "$ICNS" ]; then
  print "icon    AppIcon.icns  $(stat -f%z "$ICNS" | numfmt --to=iec 2>/dev/null || stat -f%z "$ICNS") bytes"
else
  print -u2 "icon    缺失 $ICNS"
fi

REV="$(/usr/libexec/PlistBuddy -c 'Print :PhotonsGitRevision' "$APP/Contents/Info.plist" 2>/dev/null || git rev-parse --short HEAD)"
print "built  $REV  ($(git rev-parse --abbrev-ref HEAD))"

if [ "$LAUNCH" = "1" ]; then
  open "$APP" --args --library "$LIBRARY"
  sleep 2
  if pgrep -x Photons >/dev/null 2>&1; then
    print "launched  pid $(pgrep -x Photons | head -1)  library $LIBRARY"
  else
    print -u2 "launch failed"; exit 1
  fi
fi
