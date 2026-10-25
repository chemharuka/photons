# Task 002 — M1: editing graph skeleton

**Status:** done (green) · **Depends on:** 001 (green) · **Delivered:** 2026-10-25
**Owner:** session `s-20261025-2035-0dca`

## Goal

One end-to-end path that produces a real JPEG from a RAW with our *own* adjustments applied — fast
enough that a slider would feel instant — with no UI and no catalog. If this path is right, the UI
(M2+) is assembly work; if it is wrong, everything after it is rework.

## Pipeline (the five stages from `docs/architecture-decisions.md` §3 D5)

```
linear buffer (M0 cache, half float, unbounded)
  └─ S0 geometry   crop / rotate / straighten            → geoKey
  └─ S1 scene-linear  exposure gain, WB gains, highlight recovery   → linKey
  └─ S2 tone map    parametric curve + highlights/shadows/whites/blacks   → preNRKey
  └─ S3 colour      HSL 8 bands, vibrance/saturation, RGB point curve
  └─ S4 display     output transform (sRGB / Display P3), 8- or 16-bit encode
```

Rules that are not negotiable:

- **Exposure is a gain applied in S1, not a re-decode.** v9 costs 5 s at 60 MP; a slider needs
  ~10 ms. Decode once at 0 EV and never again for an adjustment.
- **One renderer, one code path.** Thumbnail, screen preview and export differ only by an input
  scale and an output format — never by a second implementation (the ART lesson).
- **Every stage boundary is a cache key.** Re-running S3 must not re-run S0/S1.
- **No second colour space.** Linear-in, display-encode at the very end only.

## Deliverables

| File | Purpose |
|---|---|
| `Sources/PhotonsCore/EditModel.swift` | `Codable` value, document-level `schemaVersion`, explicit defaults for every field |
| `Sources/PhotonsCore/RenderGraph.swift` | stage list + cache keys + `render(scale:) -> LinearImage` |
| `Sources/PhotonsCore/Kernels/*.metal` | exposure/WB, curve, HSL, vignette as separate kernels |
| `Sources/PhotonsExport/` | display transform + JPEG/HEIC/TIFF via ImageIO |
| `Sources/photonsctl/main.swift` | new `render` subcommand |
| `Tests/PhotonsCoreTests/RenderTests.swift` | determinism, key invalidation, golden image |

## Acceptance

```
1. photonsctl render RAW --edit Tests/Fixtures/edit-neutral.json --out /tmp/a.jpg
   photonsctl render RAW --edit Tests/Fixtures/edit-neutral.json --out /tmp/b.jpg
   → sha256(a) == sha256(b)                       deterministic pipeline

2. photonsctl render RAW --edit Tests/Fixtures/edit-push.json --out /tmp/c.jpg
   → differs from a.jpg, and the golden digest for edit-push is recorded in Tests/Golden/

3. photonsctl bench RAW --viewport 2560x1600 --iterations 60
   → prints p50/p95 ms for a full S1→S4 pass at viewport resolution
   → PASS if p95 ≤ 16.7 ms (60 fps) on this machine

4. cache: changing only an S3 parameter must not re-run S0/S1
   → `photonsctl render ... --trace-stages` lists executed stages; assert S0/S1 absent

5. make verify still green
```

## Non-goals (do not drift into these)

local masks, healing, crop UI, catalog, XMP, presets UI, batch, print, video, AI, HDR merge,
DNG export, lens profiles. Masks get their data model reserved in `EditModel` (an empty
`masks: [Mask]`) but no rendering.

## Data-model notes carried over from the source study

- Parameter groups follow Lightroom's panel split (Light / Curve / Color / Detail / Effects) so a
  future XMP `crs:` mapping is mechanical — see `lightcraft-product.md` §editing for the field list.
- `ProcessVersion` is a per-document integer from day one; behaviour changes bump it and old edits
  keep their old rendering (darktable's snapshot semantics, not RawTherapee's global version bump).
- Dirty tracking is **group-level** (`Set<Stage>`), not per-parameter.

---

## Result (measured, this machine)

```
make verify
  build                                    OK
  unit tests                               23 tests, 0 failures (17 in RenderTests)
  L1  determinism (two processes)          PASS  7a568ad29960bf14…
  L2  decode golden                        PASS  L1030433.dng v8 s1.0
  L3  render determinism (two processes)   PASS  JPEG sha f7374388e3e3814e…
  L3  edit sensitivity                     PASS  edit-push ≠ edit-neutral
  L3  stage cache (S3-only change)         PASS  s0/s1/s2 skipped
  L3  render goldens                       PASS  render-edit-{neutral,push}-s0.25.json
  bench  4.10 Mpx (2404×1600 canvas)       p50 4.19 ms   p95 5.48 ms   GPU-only p95 4.71 ms
                                           PASS (budget 16.7 ms) on M1 Pro
```

### What was built

| File | Lines | Role |
|---|---|---|
| `Sources/PhotonsCore/EditModel.swift` | ~540 | the document: groups light/curve/color/detail/effects + `masks`, explicit defaults, group-level `changedStages`, canonical key material |
| `Sources/PhotonsCore/EditCurve.swift` | ~140 | control points → 4×1024 monotone-cubic LUTs (composite + per channel) |
| `Sources/PhotonsCore/Stage.swift` | ~180 | `RenderStage`, `ImageSize`, `DisplayOptions`, key chain, `RenderTrace` |
| `Sources/PhotonsCore/RenderGraph.swift` | ~560 | plan → keys → 7 passes in one command buffer, stage cache, texture pool, readback |
| `Sources/PhotonsCore/KernelLibrary.swift` | ~110 | runtime `MTLLibrary(source:)` per kernel, pipeline cache |
| `Sources/PhotonsCore/Kernels/*.metal` | 7 files | s0 geometry, s1 scene-linear, s2 tone map, s3 curve, s3 color, s3 vignette, s4 display |
| `Sources/PhotonsExport/Export.swift` | ~180 | `CGImage` packing (8/16-bit) + JPEG/HEIC/TIFF via ImageIO |
| `Sources/photonsctl/main.swift` | +300 | `render` (multi-edit, `--trace-stages`, `--golden`) and `bench` |
| `Tests/PhotonsCoreTests/RenderTests.swift` | ~330 | identity, determinism, key invalidation, parameter behaviour, model round trip, LUT, export, goldens |

### Decisions taken while implementing (record in `architecture-decisions.md` §10 if they age)

1. **Kernels are copied resources, compiled at runtime.** SwiftPM has no dependable `.metal` build
   step, and the Metal toolchain is a network download that already failed here. Cost is ~0.2 s once
   per process, never inside a frame.
2. **S0 outputs a canvas, not a crop.** `canvas` and `content` are separate: a viewport letterboxes
   the photograph (transparent outside), export passes `canvas == content`. Same kernel both ways.
3. **`--scale` is relative to full resolution.** The decoder runs on a ladder (`1, 0.5, 0.25, …`)
   chosen to just cover the requested output, and the graph renders the remainder — one resample,
   not two.
4. **Key chain is six links**, not three: `geo → lin → preNR(tone) → curve → color → vignette →
   display`. Each stage's own key is its cache identity; a changed upstream key propagates by
   construction, which is what makes "S3-only changes never re-run S1" structural rather than a
   special case.
5. **S4 is never cached.** Its texture is handed to the caller (or read back), so caching it would
   hand out a texture the pool could later reuse.
6. **Identity is a real branch, not an approximation.** Every kernel early-outs when its parameters
   are neutral, so the neutral document is bit-identical to decode + OETF (bounded at < 0.002 in
   display units by a test). Without that, "no edit" would drift from "decode".
7. **White balance is relative and approximate in M1**: Planckian fit normalized at 6500 K, so the
   decoded image is the neutral reference and the slider is a relative shift. A Bradford adaptation
   from real as-shot WB replaces it when the decoder exposes that metadata (M2).
8. **Tone map is analytic** (blacks/whites remap → contrast about the 0.18 pivot → luminance-weighted
   shadow/highlight lifts). Monotone in every slider, identity at zero, no LUT to keep in sync.
9. **Bench measures the on-screen path**: no CPU readback (32 MB per frame at 2560×1600), cache off,
   3 warm-up frames. `gpu only` is reported separately so the two cannot be confused.
10. **`detail` (sharpening/NR) is stored and does not enter the graph** — those belong on
    `CIRAWFilter`, which is a decoder-path change, not a kernel.

### Not done (explicitly)

`grain` is stored but not rendered; `masks` is schema-only; crop/straighten render but have no UI;
DNG export untouched. Nothing from the non-goal list was started.

