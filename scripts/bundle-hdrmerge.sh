#!/usr/bin/env bash
# Pack the hdrmerge-swift CLI into the built Photons.app.
#
#   scripts/bundle-hdrmerge.sh              # into .build/Photons.app
#   scripts/bundle-hdrmerge.sh /path/App    # into a specific bundle
#
# Additive on purpose: this script does not touch `scripts/bundle-app.sh`. `scripts/build-and-run.sh`
# calls it right after `make app`, so a normal build already carries the tool. The app itself
# needs no code change to carry the tool, because `HDRMergeClient` resolves
# `Contents/Resources/bin/hdrmerge-swift` first.
#
# The binary comes from `Vendor/hdrmerge-swift` by default (scripts/build-hdrmerge.sh); an
# installed copy on PATH is only a fallback, so a fresh clone does not need a second checkout.
#
# Licensing (see hdrmerge-swift/LICENSE-SCOPE.md): the tool is GPLv3 and ships as a **separate
# executable**. Photons stays MIT because it spawns it (Process + paths + JSON), which GPLv3 §5
# calls an aggregate — not a combined work. This script also drops the GPL text and the §6(d)
# source offer next to the binary, which is the obligation that comes with shipping it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/.build/Photons.app}"
VENDOR_BIN="$ROOT/Vendor/hdrmerge-swift/.build/${CONFIG:-release}/hdrmerge-swift"
BIN_SRC="${HDRMERGE_BIN:-}"
if [ -z "$BIN_SRC" ] && [ -x "$VENDOR_BIN" ]; then BIN_SRC="$VENDOR_BIN"; fi
if [ -z "$BIN_SRC" ]; then BIN_SRC="$(command -v hdrmerge-swift || true)"; fi

if [ ! -d "$APP" ]; then
    echo "bundle-hdrmerge: no app at $APP — run 'make app' first" >&2
    exit 1
fi
if [ -z "$BIN_SRC" ] || [ ! -x "$BIN_SRC" ]; then
    echo "bundle-hdrmerge: hdrmerge-swift not built." >&2
    echo "  build it from the vendored source:  scripts/build-hdrmerge.sh --to-app" >&2
    exit 1
fi

DEST="$APP/Contents/Resources/bin"
mkdir -p "$DEST" "$APP/Contents/Resources/licenses"

cp "$BIN_SRC" "$DEST/hdrmerge-swift"
chmod +x "$DEST/hdrmerge-swift"
( cd "$DEST" && shasum -a 256 hdrmerge-swift > hdrmerge-swift.sha256 )

# The GPL text comes straight from the vendored source — one copy in the tree, not two — so it is
# impossible for the license shipped in the bundle to drift from the code it covers.
cp "$ROOT/Vendor/hdrmerge-swift/LICENSE" \
   "$APP/Contents/Resources/licenses/hdrmerge-swift-GPL-3.0.txt"

# §6(d) source offer. Generated rather than kept as a second file for the same reason: the commit
# and the sha256 it names are facts about *this* build, and a hand-maintained copy goes stale.
VENDOR_COMMIT="$(awk '/^commit/{print $2}' "$ROOT/Vendor/hdrmerge-swift/VERSION.txt" 2>/dev/null || echo unknown)"
BINARY_SHA="$(awk '{print $1}' "$DEST/hdrmerge-swift.sha256" 2>/dev/null || echo unknown)"
cat > "$APP/Contents/Resources/licenses/hdrmerge-swift-SOURCE-OFFER.txt" <<OFFER
hdrmerge-swift — source code notice (GPLv3 section 6)

Photons ships the executable \`Contents/Resources/bin/hdrmerge-swift\`.
  binary sha256   $BINARY_SHA

Corresponding source code for that exact binary is included in this distribution:

    Vendor/hdrmerge-swift/          (upstream commit $VENDOR_COMMIT)

That directory is a verbatim copy of the upstream project with no local patches,
and it builds the shipped binary with:

    scripts/build-hdrmerge.sh --to-app

Upstream, for reference:

    https://github.com/chemharuka/hdrmerge-swift

Both copies are offered at no charge and from the same location as Photons.

This program is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. It is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details:
Contents/Resources/licenses/hdrmerge-swift-GPL-3.0.txt

Scope: the Photons application itself is MIT-licensed and does not link this
program — it launches it as a separate process and exchanges file paths and JSON,
which GPLv3 section 5 treats as an aggregate. Only this executable and the sources
under Vendor/hdrmerge-swift/ are GPLv3. See THIRD_PARTY_NOTICES.md.

hdrmerge-swift is a Swift port of HDRMerge (Copyright 2012 Javier Celaya), also
GPLv3: https://github.com/jcelaya/hdrmerge
OFFER

# A binary inside the bundle changes the code directory, so the signature has to be redone.
# Ad-hoc, exactly like bundle-app.sh does it for the app itself.
xattr -cr "$APP/Contents/Resources/bin" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    || codesign --force --sign - "$APP"

printf 'hdrmerge   %s → %s\n' "$BIN_SRC" "$DEST/hdrmerge-swift"
"$DEST/hdrmerge-swift" capabilities
codesign -v "$APP" && echo "signature  OK"
