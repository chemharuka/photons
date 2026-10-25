# Task 002 — M1: editing graph skeleton

**Status:** todo · **Depends on:** 001 (green) · **Est.:** one focused session
**Owner:** unclaimed (claim it: `bus.py claim --task 002`)

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
