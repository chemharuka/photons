# Photons

A native macOS RAW photo workflow — import a folder, cull it, develop it non-destructively, export
it — written in Swift, released under **MIT**.

Photons does not ship a RAW decoder. The camera-specific half (demosaic, lens correction,
machine-learning denoise) is **Apple's**: `CIRAWFilter` over the system's `RawCamera` bundle.
Everything above it is ours: a SQLite catalog, a Metal editing graph, masking, colour management,
XMP and export.

The evidence for that split — and for deliberately *not* linking LibRaw, Exiv2, libheif or lensfun —
is in [docs/architecture-decisions.md](docs/architecture-decisions.md); each claim there is backed by
a measurement on a real file or a read of the shipped framework.

## What works today

Pre-1.0 and moving fast, but nothing below is aspirational: every item is exercised by
`make verify` / `make ui-smoke` rather than planned in a ticket.

**Library** — a `.photonslibrary` package (SQLite/WAL). Import by copy or by reference; files are
deduplicated by content hash, and an import killed with `kill -9` part-way resumes to the same set
of assets with no duplicates. Folder tree, a 15-dimension filter bar (rating, flag,
colour label, camera, lens, ISO, focal length, shutter, aperture, month/day, extension, serial, flash,
GPS), star/pick/reject/colour-label metadata, a missing-file finder, and a content-addressed
thumbnail cache.

**Develop** — five inspector workspaces over one non-destructive document:

| Workspace | Cards |
|---|---|
| 调整 | 白平衡 · 黑电平 · 光线（曝光/对比/高光/阴影/白色/黑色）· 色彩（自然饱和/饱和）· 黑白（每色相混合）· 细节（降噪/色彩降噪/锐化/细节 + 色差 R/B）· 曲线（HDR 域控制点）· 效果（暗角 · 纹理/清晰度/去雾 · 颗粒）· 预设 |
| 变换 | 裁切（比例、拉直 ±45°、翻转）、90° 旋转 |
| 色彩 | HSL 八色带 · 三向色彩分级（阴影/中间调/高光 × 色相/饱和/亮度） |
| 蒙版 | 画笔 · 线性渐变 · 径向渐变 · 颜色范围 · 亮度范围 · 语义（Vision 主体）；每张蒙版有 opacity/羽化/refine/反相/混合与 10 个局部滑杆（曝光/温度/色调/对比/高光/阴影/白色/黑色/色相/饱和） |
| 历史记录 | 时间线，点击回到任意快照 |

Plus **before/after** (`\` shows the decoded original, `Y` splits the frame, `⇧Y` flips the split
axis), **presets**, grouped **copy/paste settings** (masks included, anchored by short edge), and a
histogram pinned above every workspace.

**Export** — JPEG / HEIC / TIFF (8 or 16-bit) / PNG / AVIF, long-edge resize without upscaling,
sRGB or Display P3, quality, `{seq}-{name}` filename templates, batch with an outcome per file
(one bad file does not fail the rest), and XMP either embedded or written as a sidecar.

Everything is batched through one `RenderGraph`, so the picture on screen and the exported file are
the same arithmetic. The same document renders the same bytes, twice, in two processes — that is a
test, not an aspiration.

## Requirements

- macOS 14 or newer (the newest `RawCamera` decoder versions need the newest macOS; this tree is
  built and measured on macOS 27 / Xcode 27 / Swift 6).
- One third-party dependency, resolved by SwiftPM: [GRDB](https://github.com/groue/GRDB.swift) 7
  (MIT) for SQLite. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- No `.xcodeproj` anywhere. Metal kernels ship as **resources** and are compiled by
  `Metal.framework` at launch, because SwiftPM has no dependable `.metal` build step.
- Your own RAW file for the fixtures (the repo vendors no photos): `PHOTONS_TEST_RAW=…` or
  `make verify RAW=…`.

## Build and run

```sh
make app                    # release build + bundle + ad-hoc sign → .build/Photons.app
open .build/Photons.app
```

On first launch: 文件 ▸ 打开库… to create a `.photonslibrary`, then ⇧⌘I to import a folder. Caches
(decoded linear buffers, thumbnails) are per library, under `~/Library/Caches/Photons/<library-hash>/`.

## The gate

```sh
make verify                 # the one command: build + unit tests + L1/L2/L3 + catalog + bench
```

| Level | What it proves |
|---|---|
| unit tests | 1 652 test cases (Core 658 · Catalog 179 · Export 44 · UI 771): decode contract, render graph, masks, catalog, XMP, export, UI layout |
| **L1** determinism | two independent processes decode the same file to the same digest |
| **L2** golden | recorded pixel digests, per OS version, so "the system changed" is distinguishable from "we broke it" |
| **L3** graph | neutral == decode + sRGB OETF; an S3-only change skips S0/S1/S2; edit sensitivity; render goldens |
| catalog | 12 acceptance checks against a real package: dedupe, resume after `kill -9`, move, offline, migrations |
| bench | full S0→S4 at viewport size inside the 60 fps frame budget |

Window-level acceptance is separate, because it needs a real window:

```sh
make ui-smoke               # 1 000-photo library driven through the shipped UI: grid, filmstrip,
                            # thumbnails, loupe, undo/redo, export, presets, masks, ratings, filters
make ui-bench               # 10k-row placeholder scroll p99 + loupe frame timings
```

## Commands

`make` targets:

```
make app | ui-smoke | ui-bench     the app bundle and the windowed harness
make verify                        everything that does not need a window
make catalog | catalog-perf        catalog acceptance (fast) | + 10k-row query timing
make info | cache | render | bench one-off probes against your own RAW
make record                        re-record the golden baselines (only when the change is intended)
```

`photonsctl` — the same engine without a window, and the only implementation of every verb:

```sh
.build/release/photonsctl info   path/to/file.dng
.build/release/photonsctl hash   path/to/file.dng --version 9.dng --ev 0.5
.build/release/photonsctl render path/to/file.dng --edit Tests/Fixtures/edit-push.json \
                                 --out /tmp/out.jpg --scale 0.25 --trace-stages
.build/release/photonsctl library create  ~/Pictures/New.photonslibrary
.build/release/photonsctl library import  ~/Pictures/New.photonslibrary ~/Pictures/2026-10 --mode reference
.build/release/photonsctl library assets  ~/Pictures/New.photonslibrary --rating 4 --json
.build/release/photonsctl preset  save    ~/Pictures/New.photonslibrary "Portrait" --asset 12 --groups light,curve
.build/release/photonsctl export  batch   ~/Pictures/New.photonslibrary --out /tmp/x --preset p.json --json
.build/release/photonsctl xmp     export  ~/Pictures/New.photonslibrary --out /tmp/x --embed
.build/release/photonsctl thumbs  ~/Pictures/New.photonslibrary --out /tmp/t --tier grid
```

Run `photonsctl` with no arguments for the full list, including the `decode`, `golden`, `histogram`,
`detail` and `fixtures` commands the gate uses.

## How it is built

One graph, fifteen stages, and every stage boundary is a cache key:

```
S0  geometry        orientation, crop, straighten, flip, 90° turns, 1:1 output window
S1  scene-linear    white-balance gains, black level                    (linear light, 16-bit float)
S1.5 mask atlas     one slice per enabled mask
S1.6 local apply    exposure/contrast/… inside masks, in light
S1.7 HDR curve      the tone curve, in the log1p scene-linear domain
S2  tone map        exposure, contrast, highlights, shadows, whites, blacks
S3  colour          vibrance, saturation
S3.4 黑白           monochrome + per-hue mix                            (conditional)
S3.5 local colour   a mask's hue/saturation, display-referred           (conditional)
S3.6 HSL            eight bands in OKLCh                                (conditional)
S3.8 grade          shadows / midtones / highlights, luminance windows   (conditional)
S3.9 detail FX      texture, clarity, dehaze
S3c vignette
S3.7 grain
S4  display         encode: histogram measurement, EDR headroom, output primaries
```

Two properties are load-bearing and are tested, not assumed:

- **A slider that only touches S3 cannot re-run S1.** Keys are per stage, not per document, and the
  trace prints which stages ran and which came from cache.
- **An untouched control changes nothing, byte for byte.** Conditional stages exist only when their
  predicate holds, so adding a mask with no edits, or a document with all 24 HSL bands at zero,
  renders exactly the pre-feature pixels. Most of the goldens exist to keep that true.

## Layout

```
Sources/PhotonsCore/       decode, linear buffers, RenderGraph, kernels (no AppKit)
Sources/PhotonsCatalog/    SQLite catalog, import, thumbnails, presets, metadata
Sources/PhotonsExport/     render + encode, batch export, XMP
Sources/PhotonsUI/         AppKit/SwiftUI shell, inspector, canvas, crop, masks
Sources/PhotonsApp/        @main + AppDelegate + menu (thin)
Sources/photonsctl/        the dependency-free acceptance harness
Tests/                     four test targets, golden baselines, edit fixtures
docs/                      decisions, status, XMP mapping, task specs
scripts/                   bundle, ui-smoke, ui-bench
local/                     gitignored session workspace (notes, probes, samples)
```

## Not in scope

Not "not yet" — decided against, with the reason recorded:

- **HDR merge and super-resolution.** Both need the mosaic, and `CIRAWFilter` only hands back a
  demosaiced image. There is no honest way to do either on top of this pipeline.
- **DNG export.** ImageIO can read RAW but not write it; DNG output would mean writing a DNG
  encoder from scratch.
- **Our own demosaic / denoise.** That is the one thing Apple's stack is genuinely better at.
- **Print, slideshow, map, video.** A photo workflow does not need to be a publishing suite.
- **Writing sidecar `.xmp` next to RAWs on import.** Metadata is read from the file's embedded XMP;
  the catalog owns the truth.

## Docs

- [docs/STATUS.md](docs/STATUS.md) — where the project actually is, with the measurements behind it.
- [docs/architecture-decisions.md](docs/architecture-decisions.md) — why each choice was made, and
  what would have to be true for it to be wrong.
- [docs/xmp-mapping.md](docs/xmp-mapping.md) — the `crs:*` / `photons:*` mapping and its round trips.
- [docs/collaboration.md](docs/collaboration.md) — how this machine is set up and how work is queued.
- [docs/tasks/](docs/tasks/) — the specs, one per feature.

## Licence

MIT — see [LICENSE](LICENSE). Third-party notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
