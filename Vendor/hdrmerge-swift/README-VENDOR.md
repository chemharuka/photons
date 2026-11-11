# Vendor/hdrmerge-swift — GPLv3, vendored source (NOT linked)

This directory is a verbatim copy of <https://github.com/chemharuka/hdrmerge-swift>.

| | |
|---|---|
| Upstream commit | `c9b3eba` (see `VERSION.txt`) |
| License | **GPL-3.0-or-later** — `LICENSE` here is the whole text |
| Role in Photons | **build-time source for an external executable**, never a link edge |

## Why the source is in this repo but the binary is not

Photons is MIT. `hdrmerge-swift` is GPLv3. They coexist because the GPL program is only ever a
**separate process**: `PhotonsExtensions/HDR/HDRMergeClient.swift` spawns the executable and talks
JSON over pipes. GPLv3 §5 (last paragraph) says including a covered work in an *aggregate* does not
extend the license to the other parts, and the GNU GPL FAQ (`#MereAggregation`) draws the line at
"pipes, sockets and command-line arguments" versus "linked together in a shared address space".

Consequences that this directory must respect:

* **`Package.swift` (the one at the repo root) never mentions this package.** It is not a SwiftPM
  dependency, so SwiftPM never builds it as part of Photons' graph and no `.a`/`.dylib` is produced.
  A nested `Package.swift` under a directory SwiftPM does not know about is simply an ordinary file.
* The build lives in `scripts/build-hdrmerge.sh`, which shells out to `swift build` **inside this
  directory** and copies the resulting binary to `Photons.app/Contents/Resources/bin/`.
* Shipping the app therefore ships a GPL executable. The obligation that comes with it is discharged
  by `scripts/bundle-hdrmerge.sh`: the GPL text, a §6(d) source offer, and the binary's sha256 all
  travel inside the bundle. And now the *source itself* is in this repo, so the offer points at
  something the recipient already has.
* **Table stakes: do not add `Vendor/hdrmerge-swift` to `dependencies:` in the root `Package.swift`,
  and do not `#if canImport(HDRMergeCore)` in Photons code.** Either one turns the aggregate into a
  combined work and puts all of Photons under GPLv3.

## Updating

```sh
rsync -a --exclude .build --exclude .git --exclude '*.dng' --exclude '*.pgm' \
      ~/Documents/GitHub/hdrmerge-swift/ Vendor/hdrmerge-swift/
# then refresh VERSION.txt with the upstream commit
```

Keep this a **verbatim** copy. Local patches belong upstream in the public repo, so the §6(d) offer
("this is the source of that binary") stays literally true. If a patch is ever unavoidable, record
it in `VERSION.txt` and ship the patch file next to the source.

## What is *not* from upstream

`Host/Photons/HDRMergeClient.swift` is upstream's copy of the **MIT** host client (it lives in the
upstream repo only as a convenience). The live one Photons compiles is
`Sources/PhotonsExtensions/HDR/HDRMergeClient.swift`; this file is here so a `Vendor` checkout is
self-describing, and `scripts/build-hdrmerge.sh` ignores it.
