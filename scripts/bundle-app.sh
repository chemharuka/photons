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

# 应用图标：**先用 actool 编译 Resources/AppIcon.icon**，它会把 Icon Composer 的分层文档烘成
# `Assets.car`（macOS 26 的液态玻璃）**和**一份回退用的经典 `AppIcon.icns`，两样都带上。
#
# 2026-10-30 实测（不是猜）：`xcrun actool Resources/AppIcon.icon --compile <dir> --platform macosx
# --minimum-deployment-target 26.0 --app-icon AppIcon` 在命令行就能跑通，输出 AppIcon.icns(54 KB)
# + Assets.car(1.8 MB)，**不需要打开 Xcode、也不需要 Xcode 工程**。原注释「actool 会静默跳过」
# 是错的 —— 缺的只是 `--app-icon` 和把 `.icon` 目录当输入这两点。
#
# actool 不存在时（只装了命令行工具、没有 Xcode）回退到仓库里那份 `Resources/AppIcon.icns`
# （由 `scripts/appicon.py` 按 macOS 图标规范自己糊的 824/1024 圆角版）。
ICON_TMP="$(mktemp -d)"
if xcrun --find actool >/dev/null 2>&1 && [[ -d "$ROOT/Resources/AppIcon.icon" ]]; then
    if xcrun actool "$ROOT/Resources/AppIcon.icon" \
        --compile "$ICON_TMP" \
        --platform macosx \
        --minimum-deployment-target 26.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$ICON_TMP/partial.plist" >"$ICON_TMP/actool.log" 2>&1; then
        [[ -f "$ICON_TMP/Assets.car" ]] && cp "$ICON_TMP/Assets.car" "$APP/Contents/Resources/Assets.car"
        [[ -f "$ICON_TMP/AppIcon.icns" ]] && cp "$ICON_TMP/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
        echo "icon        AppIcon.icon → Assets.car + AppIcon.icns（actool）"
    else
        echo "bundle-app: actool 编译 .icon 失败，回退到 Resources/AppIcon.icns" >&2
        sed -n '1,6p' "$ICON_TMP/actool.log" >&2 || true
    fi
fi
if [[ ! -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
    if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
        cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
        echo "icon        AppIcon.icns（回退，未编译 .icon）"
    else
        echo "bundle-app: 缺少 Resources/AppIcon.icns — 先跑 scripts/appicon.py" >&2
    fi
fi
rm -rf "$ICON_TMP"

# 047: the build stamp. The owner reads the top-right corner to answer "is this the build that has
# the merge I just asked for?", so the revision is captured **at bundle time** (i.e. after the
# compile) straight from git, and `-dirty` says the tree had uncommitted changes when it was built.
REVISION="$(git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
if ! git -C "$ROOT" diff --quiet 2>/dev/null || ! git -C "$ROOT" diff --cached --quiet 2>/dev/null; then
    REVISION="${REVISION}-dirty"
fi
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PhotonsGitRevision string ${REVISION}" "$PLIST" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Set :PhotonsGitRevision ${REVISION}" "$PLIST" >/dev/null 2>&1
printf 'revision    %s\n' "$REVISION"

# Kernels ship as a copied resource bundle and are compiled at runtime by Metal.framework
# (docs/architecture-decisions.md M1-1). `Bundle.module` looks in Bundle.main.resourceURL, which is
# Contents/Resources inside an app bundle — so that is the one place they go. (Copying them into
# Contents/MacOS as well would put unsigned bundles inside the code directory and break codesign.)
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

# 387 — the denoise module rides inside the bundle in **two pieces that belong together**:
#
#     Contents/Resources/bin/ansel-denoise-swift              ← GPL-3.0 executable
#     Contents/Resources/bin/models/denoise-quarter-single…    ← its 1.9 MB weight
#
# The weight is that program's data, so it lives in the program's directory — top-level
# `Contents/Resources/` stays Photons' own (MIT) data. Keeping the pair in one place also means the
# whole feature can be removed or replaced as a unit.
#
# Ordering matters: `rm -rf "$APP"` forty lines up wipes the bundle, so both must be re-added
# **after** that point and **before** the signature. Get it wrong and `make app` still succeeds —
# the only symptom is a greyed-out 「模型降噪…」 menu item.
#
# Both steps are optional on purpose: a checkout with neither the built tool nor the weight still
# produces a working app, and the menu explains what is missing. That keeps `make app` usable as
# the everyday build command instead of turning it into a "you must vendor everything" gate.
if [ -x "$ROOT/scripts/bundle-ansel-denoise.sh" ]; then
    "$ROOT/scripts/bundle-ansel-denoise.sh" "$APP" || \
        echo "denoise     skipped（没有构建好的 ansel-denoise-swift；「模型降噪…」会退到 Homebrew）" >&2
fi
if [ -x "$ROOT/scripts/bundle-ansel-models.sh" ]; then
    "$ROOT/scripts/bundle-ansel-models.sh" "$APP" || \
        echo "model       skipped（没有 denoise-quarter-single-v1.anselnn；「模型降噪…」会退到 ~/Library/Application Support/Photons/models）" >&2
fi

# hdrmerge-swift (GPLv3, a separate executable — never linked). Same rule as the denoise tool: it
# must be re-added after the `rm -rf "$APP"` above and before the signature, or `make app` wipes
# it and the only symptom is a greyed-out 「HDR 合并…」 menu item.
#
# The tool ships inside the app and nowhere else. A copy in /opt/homebrew/bin would be *looked at*
# by `HDRMergeClient` only as a last resort, but having one on the machine is what let a stale
# binary answer for the app in the first place — so the build no longer installs there.
if [ -x "$ROOT/scripts/build-hdrmerge.sh" ] && [ -x "$ROOT/scripts/bundle-hdrmerge.sh" ]; then
    "$ROOT/scripts/bundle-hdrmerge.sh" "$APP" || \
        echo "hdrmerge    skipped（没有构建好的 hdrmerge-swift；「HDR 合并…」会显示未找到工具）" >&2
fi

xattr -cr "$APP" 2>/dev/null || true

# Ad-hoc signature: enough to launch locally and to keep Gatekeeper quiet on this machine.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    || codesign --force --sign - "$APP" \
    || { echo "bundle-app: ad-hoc codesign failed" >&2; exit 1; }

printf 'bundle      %s\n' "$APP"
printf 'executable  %s\n' "$APP/Contents/MacOS/Photons"
printf 'resources   %s\n' "$(ls "$APP/Contents/Resources" 2>/dev/null | tr '\n' ' ')"
