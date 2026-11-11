# PhotonsHDR — HDR merge, without touching Photons

Merge bracketed RAW frames into **one Bayer (CFA) DNG**. This directory is additive: no file
outside it was modified, so `make verify` and the app behave exactly as before.

```
tools/PhotonsHDR/
├── Package.swift                  # a separate SwiftPM package, path-depends on ../..
├── Sources/PhotonsHDR/main.swift  # `photons-hdr` CLI
└── (uses PhotonsExtensions.HDRMergeService + HDRMergeClient, both MIT)
```

## Why a separate package

`hdrmerge-swift` is **GPLv3**; Photons is **MIT**. Two rules follow, and both are satisfied by
keeping the tool a child process:

* the GPL program is never linked — `HDRMergeClient` spawns it with `Process` and exchanges file
  paths and JSON on stdio, which GPLv3 §5's aggregate clause covers (GNU GPL FAQ #MereAggregation);
* this package depends on Photons (to reuse the MIT service), never the other way round. A GPL
  library linked into Photons would drag Photons with it; a spawned executable does not.

It also respects `PhotonsExtensions`' own rule: that module has **no dependency on `PhotonsCore`
or `PhotonsCatalog`**. The merge service is a plain file-in/file-out step — it writes the DNG and
hands the URL back through `onOutput`; adding it to a library is the caller's business.

See `~/Documents/GitHub/hdrmerge-swift/LICENSE-SCOPE.md` for the full argument and the obligations
the bundling script honours (GPL text + §6(d) source offer travel with the binary).

## Build and use

```sh
cd tools/PhotonsHDR
swift build -c release

.build/release/photons-hdr capabilities
.build/release/photons-hdr inspect ~/Desktop/austria/L1030664.dng

.build/release/photons-hdr merge -o /tmp/out \
    ~/Desktop/austria/L103066{4,5,6}.dng
```

Output is `<least-exposed-frame>-merged.dng` in `-o` (or the first frame's directory), i.e.
`L1030664-merged.dng` for the Austria bracket. Options: `--bits 16|32`, `--headroom N` (default 4 =
+2 stops of highlight room, bit-exact in 16 bits), `--feather N`, `--json`.

## Building the tool and packing it into the app

The GPLv3 source is vendored at `Vendor/hdrmerge-swift/`, so no second checkout is needed:

```sh
scripts/make-app-with-hdr.sh          # make app + build the tool + pack + re-sign
```

or step by step:

```sh
make app
scripts/build-hdrmerge.sh --to-app    # swift build inside Vendor/hdrmerge-swift → Resources/bin
scripts/bundle-hdrmerge.sh            # licenses + sha256 + re-sign the bundle
```

`Vendor/hdrmerge-swift` is a **nested** SwiftPM package that the root `Package.swift` does not
mention, so SwiftPM never adds an edge between it and Photons — `swift package describe` lists one
dependency (GRDB) and one target per Photons module, nothing else. A script shells out to build it.
See `Vendor/hdrmerge-swift/README-VENDOR.md` for why that separation is load-bearing.

That location is the first place `HDRMergeClient` looks when it resolves the tool, so once the
binary is packed, anything that links `PhotonsExtensions` — a future sheet, a script, this CLI —
gets the bundled copy with no further wiring.

## What is *not* here

No menu item, no window, no change to `AppMenu.swift` / `EditorWindowController.swift` /
`WorkspaceRootView.swift` / `bundle-app.sh`. Wiring a 文件 ▸ 合并 HDR DNG… item is a three-line
change to code that exists (`rootView` already exposes a coordinator pattern for imports), but it
is a change to existing files, so it is left to whoever owns that surface.
