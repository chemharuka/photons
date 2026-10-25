# Status

> Checkpoint file. A new session should be able to read this plus
> `docs/architecture-decisions.md` and start working. Keep it under ~80 lines.
> Updated: 2026-10-25 · session `s-20261025-2035-0dca` (M1)

## M0 — acceptance harness · **DONE (green)**

`make verify` → build + unit tests + L1 determinism + L2 golden, all pass.

| Check | Result |
|---|---|
| unit tests | 6/6 pass |
| L1 determinism (two processes) | PASS `7a568ad29960bf14…` |
| L2 golden | recorded `Tests/Golden/L1030433-v8-s1.0.json` |
| per-version determinism | all 6 offered versions stable, each with a **distinct** digest |
| EDR headroom through our own pipeline | `max linear = 1.019`, 0.001 % of samples > 1.0 |
| decode throughput (v8, 60 MP, full) | ~0.5 s ≈ 100 Mpx/s |

## M1 — editing graph skeleton · **DONE (green)**

`make verify` → build + **23 tests** + L1 + L2 + L3 (graph) + bench, all pass.

| Check | Result |
|---|---|
| neutral document is the identity path | rendered pixels == decode + sRGB OETF, max error < 0.002 |
| L3 determinism (two processes) | PASS, JPEG sha `f7374388e3e3814e…` |
| edit sensitivity | `edit-push` ≠ `edit-neutral` (JPEG sha differs) |
| stage cache | an S3-only change skips S0/S1/S2 (asserted in `make l3` and in a unit test) |
| L2 render goldens | `Tests/Golden/render-edit-{neutral,push}-s0.25.json` (pixels + file) |
| frame budget, 4.10 Mpx (2404×1600) | **p50 4.19 ms / p95 5.48 ms** (budget 16.7 ms), GPU-only p95 4.71 ms, M1 Pro |
| S0→S4 at 2380×1584, JPEG out | ~7 ms for the pushed edit |

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
- SwiftPM has no usable `.metal` build step here: kernels ship as **copied resources** and are
  compiled with `MTLLibrary(source:)` at first use (~0.2 s per process, outside any frame budget).
- An rgba16Float round trip through `getBytes` is exact; the only lossy step in the graph is the
  half-precision store between stages, which the identity test bounds at < 0.002 in display units.

## Next — M2: catalog / import

SQLite (+GRDB, the one allowed package) with `docs/architecture-decisions.md` §6 schema, full-file
SHA-256 de-duplication, copy/reference import, date-foldered storage, crash-safe WAL. The render
graph from M1 is the thing the catalog points at (`develop_json` → `EditModel`), so schema work and
`EditModel` evolution must not drift apart: bump `schemaVersion` when a field is added, and give it
an explicit default.

## Deferred (do not start)

Local masks (M4/v0.3), HDR merge and super-resolution (**impossible**: no mosaic access), DNG export
(v0.9+), print/slideshow/map/video, sharpening/NR (they belong on `CIRAWFilter`, not on a kernel).

## How to run

```
make verify                                   # the gate: build + tests + L1 + L2 + L3 + bench
make render                                   # one edited JPEG + stage trace
make bench                                    # frame budget only
make info  RAW=~/Desktop/test/L1030433.dng     # what the system reports
photonsctl render RAW --edit Tests/Fixtures/edit-push.json --out /tmp/a.jpg --scale 0.25 --trace-stages
PHOTONS_TEST_RAW=/path/to.dng swift test       # point tests at your own sample
```

## Pointers

- decisions + evidence: `docs/architecture-decisions.md` (§10 = what M1 pinned down)
- the M1 spec and its measured outcome: `docs/tasks/002-editing-graph.md`
- workspace conventions for research/probes/fixtures: `local/README.md`
- cross-session state: `~/.hermes/bus/photons-0985eb/` (skill `photons-session-bus`)
