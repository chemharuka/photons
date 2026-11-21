# NonlocalMatchFilter

Core ML port of the RAW→RAW denoiser from **Learned Nonlocal Feature Matching and
Filtering for RAW Image Denoising** (Sánchez-Beeckman & Buades, [arXiv:2604.17453](https://arxiv.org/abs/2604.17453)),
packaged as a Swift library that takes a DNG in and writes a DNG out.

No Python, no subprocess, no CUDA extension: the network runs through Core ML on
the GPU, and the whole round trip — read, denoise, write — is Swift.

```swift
import NonlocalMatchFilter

let request = DenoiseRequest(
    input: sourceURL,
    output: destinationURL,
    mlpackage: modelURL,          // v_matmul_256.mlpackage
    a: [], b: [],                 // ignored when estimateNoise is set
    strength: nil,                // nil = derive it from the measured noise
    crop: 4,
    estimateNoise: true)

let report = try DenoisePipeline.run(request) { line in print(line) }
// report.seconds, .tiles, .inferenceSeconds, …
```

Measured on a Leica SL3 file (9536×6344, 60 MP, high ISO): **~86 s end to end**,
of which 7.6 s is measuring the noise curve and ~76 s is inference.

## Why a library and not a helper executable

Some denoisers cannot be linked into an app: RawNIND's weights are GPL-3.0, so
projects drive them as a separate process. This network's code and weights are
**MIT**, so it goes in-process — no subprocess protocol, no JSON envelope, no
second copy of the DNG reader.

## The model contract

```
input   mosaic  float32 [1, 8, T, T]
        planes 0..3  packed Bayer, channel order R, G, B, G
        planes 4..7  per-pixel sigma, sqrt(max(a·x + b, 0)), one a,b per CFA plane
output  rgb     float32 [1, 4, T, T]
        a denoised packed mosaic in the same order — not camera RGB, not demosaiced
```

Two things about it are easy to get wrong, and neither fails loudly:

1. **The plane order is R, G, B, G** — the second green is the one on *blue's*
   row, not `R, G1, G2, B`. The wrong order does not error; the network balances
   the channels it thinks it sees and returns a magenta cast. Measured out/in per
   plane: `0.99 0.72 0.99 3.23` in the wrong order, all `1.00` in RGBG.
2. **The spatial size is baked into the `.mlpackage`.** A 512² graph rejects
   1024² input outright, so the tile must match the model file.

A `T × T` plane is a `2T × 2T` window of mosaic, because each plane holds one
sample per 2×2 cell.

## Choosing a tile size

All figures on the 60 MP sample, `T` = plane side, mosaic window = `2T`:

| T | per tile | tiles (crop 0) | inference | notes |
|---|---|---|---|---|
| 256 | **272 ms** | 247 | **66 s** | fastest; quality indistinguishable from 512 |
| 512 | 1078 ms | 70 | 75 s | |
| 1024 | 4627 ms | 20 | 92 s | slower *and* 1.78 GB peak |

The 4× speed-up per tile does not become a 4× speed-up overall: the tile count
grows by ~3.5× at the same time. 1024 is a net loss.

Quality across tile sizes is a wash — on the dark region, high-frequency energy
was 3.177 (256) vs 3.185 (1024), and the mean absolute pixel difference between
the two renders was **0.06/255**.

## The noise curve is the quality knob

The network takes a per-pixel sigma and uses it to decide how hard to filter.
Supplying the wrong curve does not crash — it silently over- or under-smooths.

`--measure-noise` estimates `Var = a·x + b` from the frame itself in **7.6 s**
(half that with `--noise-sample checkerboard`). Two details make the numbers
right, and both were found by getting them wrong first:

- **Measure on diagonal differences inside one CFA plane.** Adjacent mosaic
  samples are different colours, so their difference measures the scene, not the
  noise. Diagonals of a 2×2 cell share a colour.
- **Fit the lower envelope, not the mean.** Texture only ever *adds* variance, so
  the honest level at a given brightness is a low percentile of the estimates in
  that brightness bin. A least-squares fit through binned means produced σ 2.7×
  too high in the midtones, which visibly over-smoothing the picture. The
  lower envelope brought that to 1.8× — and the shipped defaults were themselves
  low by 1.8×, so the two errors pointed opposite ways.

`--noise-sample checkerboard` keeps half the blocks, alternating by block index.
Unlike a coarser stride it thins every brightness level evenly, which is what the
σ²-vs-mean regression needs: a stride-based subsample drops the dark end first
(4× fewer blocks moved `a` by 4.5 %; 16× fewer made the fit collapse to zero).
Checkerboard costs 4.1 s instead of 7.6 s and moves `a` by 3.6 %.

The fitted intercept is then multiplied by `NoiseEstimator.interceptScale` (2).
The fit describes the sensor; the network works *before* the tone curve, and a
rendered picture lifts shadows 2–4×, amplifying whatever grain survives there.
Doubling `b` lifts σ only where `b` dominates — dark pixels — and is what closes
that gap: on L1030546 the deep-shadow residual fell 0.39 → 0.24 DN for ~9 % less
high-frequency energy in bright detail blocks. `b × 4` bought little more and
started smoothing dark texture.

## Seams, and why `crop` exists

A tile's border is a seam: the network conditioned its answer on a boundary that
is not in the picture. Two differently-anchored grids disagree there. Measured
on the dark region, as a ratio to the interior disagreement:

| distance from seam | error vs interior |
|---|---|
| 0–1 px | **9.0×** |
| 2–4 px | 5.2× |
| 4–8 px | 3.0× |
| 8–16 px | 1.05× |

So `crop` discards the unreliable border (in **plane** pixels; it discards twice
as many mosaic pixels). At `crop: 4` the visible seam is largely gone at the
strengths this library picks on its own.

Cropping is applied **only to interior seams**. The picture's own edge has no
seam, and cropping there would leave those pixels with no tile at all — the bug
the test suite caught, where unconditional cropping left the last 8 columns of a
9536-wide frame uncovered.

For a seam-free result, use `crop: 0` with a stride smaller than the window
(the pipeline accumulates overlapping tiles with an edge-distance weight). That
takes the seam from 9× to **1.4×** but needs 4× the tiles: ~280 s on 60 MP.

## `strength`

`out = input + strength·(denoised − input)`, applied in the normalised domain
per sample. Blend against the **input**, never against the output buffer — the
early implementation read the output array, which starts zeroed, so every
strength below 1 dragged the whole frame toward black (overall std fell to 592
where the source was 843).

`1.0` visibly over-smooths fine texture, so the default is not a constant at all:
`strength: nil` derives it from the frame's own curve, via `NLMFStrength`.

Anchors come from a scan of 190 Leica SL3 frames, ISO 800–3200, each fitted on
its own. Medians of σ at 5 % brightness (green plane): 800 → 0.00355,
1250 → 0.00465, 1600 → 0.00477, 2000 → 0.00569, 2500 → 0.00614, 3200 → 0.00680.
Between the two end anchors it interpolates linearly in **log σ** and clamps
outside them, so `strength` runs 0.70 (ISO 800 and quieter) to 0.90 (ISO 3200 and
noisier) and never reaches 1.0. Keying on σ rather than on the ISO tag matters:
within one ISO the spread is larger than between neighbouring ISOs — a bright
ISO 3200 frame measures less noise than a dark ISO 800 one, and gets less
strength for it. `DenoiseReport.strength` and `.sigma` say what was used.

Pass an explicit `strength` only to override that.

## The models are in this repository

```
Models/
  v_matmul_256.mlpackage/                    63 MB  — 256² planes, the default
  v_matmul_512.mlpackage/                    72 MB  — 512² planes, for comparison
  rawnoise_25_15_9nbr_weights.pt             58 MB  — the network weights
```

The `.mlpackage` files are the converted networks; load them directly.

`rawnoise_25_15_9nbr_weights.pt` is the upstream checkpoint with the Lightning
training state stripped. The released `.ckpt` is **175 MB**, of which only 58 MB
is the network — the rest is Adam's `exp_avg`/`exp_avg_2` (two tensors per
parameter) and the LR scheduler, none of which affects inference. That file is
over GitHub's 100 MB per-file limit, so it is not here; download it from upstream
if you need to redo the conversion:

```
https://github.com/MIA-UIB/nonlocal-matchfilter/releases/download/v1.0.0/rawnoise_25_15_9nbr.ckpt
```

Either form works as `--ckpt`; `Scripts/convert.py` accepts both.

## Building

```
swift build -c release
swift test
```

**Use `-c release`.** In a debug build the per-pixel normalise/quantise loops run
two orders of magnitude slower: reading a 60 MP frame took 42.7 s in debug and
0.2 s in release.

## CLI

```
nlmf-denoise <model.mlpackage> <in.dng> --out <out.dng>
             [--strength S] [--crop N] [--measure-noise]
             [--noise-sample checkerboard] [--a r,g,b,g2] [--b r,g,b,g2] [--json]
```

## License

MIT. See `LICENSE` for the upstream attribution.

The weights are MIT as part of the upstream repository. Note that the upstream
project **disabled its issue tracker**, so a defect reported here has no
upstream bug to point at; the sections above record what was measured instead.
