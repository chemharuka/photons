# hdrmerge-swift

A Swift port of [HDRMerge](https://github.com/jcelaya/hdrmerge): merge bracketed RAW exposures into
**one Bayer (CFA) DNG**.

**DNG in, DNG out.** The output is still a mosaic — never demosaiced — so it goes back into the same
RAW pipeline as the frames it came from. Alignment, exposure-ratio estimation and blending all
happen in the CFA domain, at the sensor's full resolution.

Used by [Photons](https://github.com/chemharuka/photons) as an external plugin: a child process,
never linked into the MIT-licensed app.

- Repository: <https://github.com/chemharuka/hdrmerge-swift>
- License: **GPL-3.0-or-later** (`LICENSE`). HDRMerge is © 2012 Javier Celaya; this port keeps the
  same license and the same algorithm structure. `LICENSE-SCOPE.md` explains the process-boundary
  arrangement.

## What it does

| Input | Output |
|---|---|
| 1…n CFA DNGs (photometric 32803, compression 1 or 7) | One CFA DNG: aligned, merged, `DefaultCropSize` = the frames' common photo rectangle |

Per frame it decodes the mosaic, estimates the exposure ratio against the darkest frame, computes a
saturation mask and a feathered layer index, then composes one mosaic. The output inherits its
EXIF/DNG metadata (colour matrices, crop, GPS, preview) from the least exposed frame unless
`--metadata-from` says otherwise, and its `CFAPattern` is re-phased so index (0,0) is the photo's
top-left sample.

Frames that do not share size, CFA pattern or CFA phase are refused (exit 4) rather than merged into
something wrong. Same for linear DNGs (Lightroom "Merge to HDR", Apple ProRAW), which have no mosaic
to merge at all.

## Usage

```
hdrmerge-swift merge -o out.dng --headroom 4 --compress a.dng b.dng c.dng
hdrmerge-swift inspect a.dng b.dng c.dng
```

| Flag | Meaning |
|---|---|
| `-o PATH` | Output DNG, written atomically. Required. |
| `-b 16\|32` | Bits per sample. 16 (integer DNG) is the default and what hosts should use. |
| `--headroom N` | Container top = N × input white level. `4` with 16 bits keeps the input scale bit-exact and leaves +2 stops of recovered highlight room. |
| `--compress` | Store samples as SOF3 lossless JPEG (Compression = 7). Noticeably smaller — 121 MB → 50–74 MB on a 60 MP frame, bit-exact, accepted by both LibRaw and Core Image. |
| `--feather N` | Mask feather radius (default 3). |
| `--metadata-from PATH` | Take EXIF/DNG metadata from this frame instead of the least exposed one. |
| `--white N` | Override the detected saturation level. |
| `--json` / `--progress` | Host protocol: one JSON object on stdout / NDJSON events on stderr. |

Other commands: `capabilities` (protocol version + feature list, for negotiation), `inspect`
(geometry, CFA, levels, EXIF — a cheap pre-flight), `decode` (16-bit PGM of the mosaic, usable as a
decoder oracle), `synth` (test aid: fake a shorter exposure).

## Photons side

- Client: `Host/Photons/HDRMergeClient.swift` — **MIT**, because it only spawns the process and
  parses JSON. It is copied into PhotonsCore; edit it here first and sync.
- Protocol: `PROTOCOL.md` — one JSON object on stdout, stable `error.code` strings, NDJSON progress,
  atomic write, exit codes 0/2/3/4/5/6.
- Install: `./scripts/install-to-photons.sh` (→ `/opt/homebrew/bin`), or `--in-app` for
  `Photons.app/Contents/Resources/bin`.
- In the app the feature is **right-click ▸ HDR 合成…** on two or more DNGs. The result lands beside
  the originals as `<least-exposed-stem>-merged.dng` and is stacked with the frames that made it.
  A missing tool greys the row out with the reason; nothing else in the app changes.

`Package.swift` makes this a standalone SPM package. Photons' `Vendor/hdrmerge-swift/` is a mirror of
this repository, kept so the app builds from one tree — it is never a SwiftPM dependency, and
importing `HDRMergeCore` from Photons code would put the whole app under GPLv3.

## Status

| Piece | State |
|---|---|
| DNG / TIFF reader (CFA plane, tags, strips + tiles) | works |
| Lossless JPEG (Compression = 7, 1…4 components, 1×1 sampling) | works |
| Uncompressed (Compression = 1) | works |
| SOF3 write (Compression = 7) | works, bit-exact |
| Ward MTB alignment (6-level 2×2-binned pyramid) | works |
| Exposure ratio, saturation mask, feather + compose | works |
| CFA DNG writer (16-bit integer, 32-bit float) | works |
| Deflate (Compression = 8), JPEG XL, BigTIFF, CR3/NEF/ARW/RAF | not yet |
| Qt GUI, mask editing, preview | out of scope |

## Build

```
swift build -c release
.build/release/hdrmerge-swift capabilities
```

macOS 13+, no third-party dependencies: the RAW path is pure Swift (no LibRaw), so the binary has no
runtime deps beyond the system frameworks. `swift test` runs the core suite — alignment, crop
geometry, CFA generality, compression round trips.

## Deviations from upstream HDRMerge

See `PORTING.md`. Short version: exposure ratio uses least squares instead of the penalised spline
response fit (identical for linear sensor data), and the mask fattening filter is square rather than
a disk. Everything else follows `Image.cpp` / `ImageStack.cpp` / `DngFloatWriter.cpp` closely,
including the "normalise the brightest pixel to the white level" step in `compose()`.
