# Status

> Checkpoint file. A new session should be able to read this plus
> `docs/architecture-decisions.md` and start working. Keep it under ~80 lines.
> Updated: 2026-10-25 · session `s-20261025-2020-2a33`

## M0 — acceptance harness · **DONE (green)**

`make verify` → build + 6 unit tests + L1 determinism + L2 golden, all pass.

| Check | Result |
|---|---|
| unit tests | 6/6 pass, 16.9 s |
| L1 determinism (two processes) | PASS `7a568ad29960bf14…` |
| L2 golden | recorded `Tests/Golden/L1030433-v8-s1.0.json` |
| per-version determinism | all 6 offered versions stable, each with a **distinct** digest |
| EDR headroom through our own pipeline | `max linear = 1.019`, 0.001 % of samples > 1.0 |
| decode throughput (v8, 60 MP, full) | ~0.5 s ≈ 100 Mpx/s |

## Facts pinned by measurement (do not re-derive)

- `CIRAWFilter` on this Mac: **941** camera models; offered versions for the Leica SL3 DNG are
  `6.dng, 7, 7.dng, 8, 8.dng, 9.dng`; **Apple defaults to v8**, not v9.
- v9 costs **8–10×** v8 (60 MP: 5.05 s vs 0.50 s) and covers only 69 bodies + the generic DNG path.
- v9 is **ML denoise**, not ML demosaic: `RawCamera.metallib` ships `deBayer_v7/v7_8bit/v8`,
  `deXtrans_v7/v8`, and `denoisedPixel(…)`; the CoreML programs are `RawSFD/*.mil` with inputs
  `image0 + noise0`.
- RAW is **read-only** through the system stack; DNG export would need our own writer.
- `CGColorSpace(name:)` needs the CFString constant (`kCGColorSpaceExtendedLinearSRGB`), not a
  friendly name — a friendly name silently returns nil.

## Next — M1: editing graph skeleton

Spec: `docs/tasks/002-editing-graph.md`. Scope is *one* end-to-end path:
linear buffer → geometry → tone map → display encode → JPEG, with cache keys, no UI.

## Deferred (do not start)

Local masks (v0.3), catalog/import (M2), HDR merge and super-resolution (**impossible**: no mosaic
access), DNG export (v0.9+), print/slideshow/map/video.

## How to run

```
make verify                                   # the gate
make info  RAW=~/Desktop/test/L1030433.dng     # what the system reports
make cache                                    # linear cache size; --evict --limit-gb
PHOTONS_TEST_RAW=/path/to.dng swift test       # point tests at your own sample
```

## Pointers

- decisions + evidence: `docs/architecture-decisions.md`
- workspace conventions for research/probes/fixtures: `local/README.md`
- cross-session state: `~/.hermes/bus/photons-0985eb/` (skill `photons-session-bus`)
