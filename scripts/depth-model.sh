#!/bin/bash
# Compile the bundled Depth Anything V2 (Small, F16) Core ML package into the app bundle.
#
# SwiftPM cannot process an `.mlpackage` directory, so the weight ships as a plain repo resource
# (`Resources/DepthAnythingV2SmallF16.mlpackage`) and is compiled here by the Core ML compiler, then
# copied into `Contents/Resources` of the bundle `scripts/bundle-app.sh` just produced.
#
# Idempotent: skips the compile when the `.mlmodelc` is newer than the package's weight file.
set -euo pipefail
cd "$(dirname "$0")/.."

PKG="Resources/DepthAnythingV2SmallF16.mlpackage"
OUT=".build/depth-model"
APP=".build/Photons.app/Contents/Resources"
NAME="$(basename "$PKG" .mlpackage)"

if [[ ! -d "$PKG" ]]; then
    echo "depth-model: $PKG 缺失 —— 权重没有随仓库分发（见 Sources/PhotonsDepth/README.md）" >&2
    exit 1
fi

if [[ -d "$APP/$NAME.mlmodelc" && -f "$OUT/$NAME.mlmodelc/coremldata.bin" \
      && "$OUT/$NAME.mlmodelc/coremldata.bin" -nt "$PKG/Data/com.apple.CoreML/weights/weight.bin" ]]; then
    echo "depth-model: 已是最新（$(du -sh "$OUT/$NAME.mlmodelc" | cut -f1)）"
    exit 0
fi

mkdir -p "$OUT"
rm -rf "$OUT/$NAME.mlmodelc"
xcrun coremlcompiler compile "$PKG" "$OUT"
mkdir -p "$APP"
rm -rf "$APP/$NAME.mlmodelc"
cp -R "$OUT/$NAME.mlmodelc" "$APP/"
echo "depth-model: $(du -sh "$APP/$NAME.mlmodelc" | cut -f1) -> $APP/$NAME.mlmodelc"
