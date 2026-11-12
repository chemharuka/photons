# Vendored: hdrmerge-swift (GPLv3, not linked)

`Vendor/hdrmerge-swift/` is a **verbatim** copy of
<https://github.com/chemharuka/hdrmerge-swift>.

| | |
|---|---|
| Vendored commit | see `Vendor/hdrmerge-swift/VERSION.txt` |
| License | **GPL-3.0-or-later** — the full text is `Vendor/hdrmerge-swift/LICENSE` |
| Patches | none |
| Role in Photons | build-time source for an **external executable**, never a link edge |

Licensing summary, the obligations it creates, and the argument for why Photons stays MIT:
**`THIRD_PARTY_NOTICES.md`** at the repository root. That is the file to edit when the vendored
commit changes.

## Why the source is here but the binary is not

Photons is MIT; `hdrmerge-swift` is GPLv3. They coexist because the GPL program is only ever a
**separate process**: `Sources/PhotonsExtensions/HDR/HDRMergeClient.swift` spawns the executable
and talks JSON over pipes. GPLv3 §5 (last paragraph) says including a covered work in an *aggregate*
does not extend the license to the other parts, and the GNU GPL FAQ (`#MereAggregation`) draws the
line at "pipes, sockets and command-line arguments" versus "linked together in a shared address
space".

The vendored source makes the build self-contained (`git clone` + build produces a working app) and
makes the §6(d) source offer point at something the recipient already has. The binary itself stays
out of the tree: it is a build product, it would be a 400 KB binary diff on every upgrade, and a
committed binary drifts away from the source it claims to be built from.

## Two rules that keep this an aggregate, not a combined work

1. **Never reference this package from the root `Package.swift`** — no `dependencies:` entry, no
   `.package(path: "Vendor/hdrmerge-swift")`. A nested `Package.swift` under a directory SwiftPM
   does not know about is simply an ordinary file, which is why `swift package describe` reports one
   dependency (GRDB) and no hdrmerge target.
2. **Never `#if canImport(HDRMergeCore)` or `import HDRMergeCore` in Photons code.** Importing the
   module is linking, and linking is what the aggregate clause does not cover.

Either one would put all of Photons under GPLv3.

## Build path

```sh
scripts/build-and-run.sh              # the one build entry point: make app + the tool + pack + sign
```

`build-and-run.sh` is the only thing you need to run; everything below is what it does in order.

`scripts/bundle-hdrmerge.sh` then **generates** the three artefacts the licence requires into
`Contents/Resources/licenses/` and `Contents/Resources/bin/`: the GPL text (copied from
`Vendor/hdrmerge-swift/LICENSE`, so there is one copy in the tree and it cannot drift), a §6(d)
source offer carrying this build's commit and binary sha256, and that sha256. There is deliberately
no second, hand-maintained copy of either text under `Resources/`.

## Updating

```sh
rsync -a --exclude .build --exclude .git --exclude '*.dng' --exclude '*.pgm' \
      ~/Documents/GitHub/hdrmerge-swift/ Vendor/hdrmerge-swift/
# refresh Vendor/hdrmerge-swift/VERSION.txt with the upstream commit
```

Keep it verbatim. Local patches belong upstream in the public repo, so "this is the source of that
binary" stays literally true. If a patch is ever unavoidable, record it in `VERSION.txt` and ship
the patch file next to the source.

## Not from upstream

Two files in this tree are ours, not the upstream project's:

- `Vendor/hdrmerge-swift/VERSION.txt` — the vendoring record (upstream says nothing about it).
- this README — kept at the repository root, outside `Vendor/`, so that directory stays a verbatim copy.

`Vendor/hdrmerge-swift/Host/Photons/HDRMergeClient.swift` *is* upstream's copy of the MIT host
client (upstream carries it for convenience). The one Photons compiles is
`Sources/PhotonsExtensions/HDR/HDRMergeClient.swift`; the vendored copy is inert and exists so a
`Vendor` checkout is self-describing.
