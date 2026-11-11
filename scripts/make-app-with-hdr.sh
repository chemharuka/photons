#!/usr/bin/env bash
# One command that produces an app WITH the HDR merge tool inside it.
#
#   scripts/make-app-with-hdr.sh [release|debug]
#
# Equivalent to:
#   make app                                  # SwiftPM build + bundle-app.sh + ad-hoc sign
#   scripts/build-hdrmerge.sh --to-app        # compile Vendor/hdrmerge-swift → Resources/bin
#   scripts/bundle-hdrmerge.sh                # licenses + sha256 + re-sign
#
# Kept as a wrapper instead of editing the Makefile so the existing `make app` keeps its exact
# contract (and its timing) for everyone who does not need the HDR tool.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
cd "$ROOT"

make app CONFIG="$CONFIG"
CONFIG="$CONFIG" scripts/build-hdrmerge.sh --to-app
scripts/bundle-hdrmerge.sh

printf '\nhint   open .build/Photons.app\n'
