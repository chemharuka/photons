#!/usr/bin/env bash
# Pack the denoise model into the **ansel-denoise-swift module's own directory** inside the app.
#
#   scripts/bundle-ansel-models.sh              # into .build/Photons.app
#   scripts/bundle-ansel-models.sh /path/App    # into a specific bundle
#
# Where it goes, and why:
#   Contents/Resources/bin/ansel-denoise-swift        ← the GPL-3.0 executable (separate tool)
#   Contents/Resources/bin/models/<...>.anselnn       ← its weights, right next to it
#
# The weights belong to that tool, not to Photons. Photons never links or reads them: it spawns the
# executable and passes the model path on the command line (`batch <model> <input>`, see
# Vendor/ansel-denoise-swift/Sources/AnselDenoiseCLI/main.swift:255). Keeping the weight inside the
# tool's directory keeps the licensing boundary visible in the bundle layout — top-level
# `Contents/Resources/` is Photons' (MIT) own data, `Contents/Resources/bin/` is the GPL aggregate,
# and the pair can be replaced or removed as a unit without touching anything Photons owns.
#
# Only ONE variant ships (user decision 2026-11-12「打包最小的.anselnn 进app」): the four weights
# together are 98 MB and would roughly double the app for variants nobody launches by default.
# `quarter`'s `-single` weight is 1.9 MB and is exactly what `AnselDenoiseOptions.variant` already
# defaults to, so shipping that makes the feature work on a fresh machine without changing any
# default. A user who wants half/large drops that file in
# `~/Library/Application Support/Photons/models` and the app picks it up there — the bundle never
# has to change.
#
# Licensing: the executable is GPL-3.0 (`bundle-ansel-denoise.sh` writes its licence text and the
# §6(d) source offer). The `.anselnn` is data, not code — upstream's training-data licence
# (ATDL-1.1) states the resulting weights are the trainer's to license as they see fit, including
# commercially, and `Vendor/ansel-denoise-swift/LICENSE-SCOPE.md` records that upstream attaches no
# further restriction while advising a commercial shipper to confirm. We ship the 1.9 MB default and
# write its provenance next to it so the claim is auditable rather than assumed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-${PHOTONS_APP:-$ROOT/.build/Photons.app}}"

# The one variant we ship. A literal (not "the smallest on disk") so a future weight that happens to
# be smaller cannot silently change what the app carries.
MODEL_NAME="denoise-quarter-single-v1.anselnn"

CANDIDATES=()
[ -n "${PHOTONS_ANSEL_MODEL:-}" ] && CANDIDATES+=("$PHOTONS_ANSEL_MODEL")
CANDIDATES+=(
    "$HOME/Library/Application Support/Photons/models/$MODEL_NAME"
    "$HOME/workspace/ansel-probe/$MODEL_NAME"
    "$HOME/workspace/ansel-probe/ansel-denoise-src/models/$MODEL_NAME"
    "$ROOT/Vendor/ansel-denoise-swift/models/$MODEL_NAME"
)

SRC=""
for candidate in "${CANDIDATES[@]}"; do
    if [ -f "$candidate" ]; then SRC="$candidate"; break; fi
done

if [ ! -d "$APP" ]; then
    echo "bundle-ansel-models: no app at $APP — run 'make app' first" >&2
    exit 1
fi
if [ -z "$SRC" ]; then
    echo "bundle-ansel-models: $MODEL_NAME not found. Looked in:" >&2
    printf '  %s\n' "${CANDIDATES[@]}" >&2
    echo "  put it anywhere above, or set PHOTONS_ANSEL_MODEL to its path" >&2
    exit 1
fi

# Next to the executable — see the header for why this is not `Contents/Resources/models`.
DEST="$APP/Contents/Resources/bin/models"
LIC="$APP/Contents/Resources/licenses"
mkdir -p "$DEST" "$LIC"

cp "$SRC" "$DEST/$MODEL_NAME"
MODEL_SHA="$(cd "$DEST" && shasum -a 256 "$MODEL_NAME" | awk '{print $1}')"
printf '%s  %s\n' "$MODEL_SHA" "$MODEL_NAME" > "$DEST/$MODEL_NAME.sha256"

cat > "$LIC/ansel-denoise-models.txt" <<NOTICE
ansel-denoise model weights — provenance

Photons ships exactly one weight file, inside the ansel-denoise-swift module:

    Contents/Resources/bin/ansel-denoise-swift
    Contents/Resources/bin/models/$MODEL_NAME
    sha256  $MODEL_SHA

The weight is AnselDenoiseVariant.quarter's single-pass model and is the one
\`AnselDenoiseOptions.variant\` defaults to. half/large/multi are NOT shipped; a
user who wants one places it in
~/Library/Application Support/Photons/models/ and the app picks it up there.

The model is data for the ansel-denoise-swift program, not part of Photons:
Photons spawns that executable and passes the model path as an argument
(\`batch <model> <input>\`). It never links it and never reads the weights itself,
which is what keeps Photons MIT while the tool is GPL-3.0.

Training data licence (ATDL-1.1), as recorded in
Vendor/ansel-denoise-swift/LICENSE-DATA.md:

    The resulting weights are yours — license them however you see fit, in
    open-source or commercial.

Vendor/ansel-denoise-swift/LICENSE-SCOPE.md adds that upstream attaches no
additional restriction to the weights themselves, that the vendored repository
does not distribute them, and that a commercial shipper should confirm the weight
licence with upstream. That confirmation is the distributor's call, not this
script's; the vendored documents are the authority and ship in
Vendor/ansel-denoise-swift/ for anyone auditing this bundle.

The executable's own GPL-3.0 text and §6(d) source offer live in
Contents/Resources/licenses/ansel-denoise-swift-*.
NOTICE

# A file inside the bundle changes the code directory, so the signature is redone — ad-hoc, the
# same way bundle-app.sh does it for the app itself.
xattr -cr "$APP/Contents/Resources/bin" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    || codesign --force --sign - "$APP"

MODEL_BYTES="$(wc -c < "$DEST/$MODEL_NAME" | tr -d ' ')"
printf 'model       %s\n' "$SRC"
printf '            → %s (%s bytes, sha256 %s)\n' "$DEST/$MODEL_NAME" "$MODEL_BYTES" "${MODEL_SHA:0:16}…"
