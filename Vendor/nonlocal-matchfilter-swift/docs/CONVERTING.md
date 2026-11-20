# Converting the weights to Core ML

Everything in `Sources/` is Swift and needs no Python. This document covers the
one-time step that produces the `.mlpackage` — run it once, keep the output, and
never touch Python again.

## 1. Dependencies

```bash
python3 -m venv .venv
.venv/bin/pip install torch numpy einops coremltools
```

`torch==2.6.0` is what this was verified against. `coremltools` needs to be new
enough to target macOS 15 (`minimum_deployment_target=ct.target.macOS15`).

## 2. Weights

The stripped weights are in this repository:

```
Models/rawnoise_25_15_9nbr_weights.pt      58 MB
sha256 e3398750ec420ed7710c4e9b8e28b08c03ea9f08bcec4c101da45ce21c618ff5
```

To regenerate it from the upstream checkpoint (or if you need the training state
back), download the original — **175 MB, over GitHub's per-file limit, so it is
not in this repo**:

```
https://github.com/MIA-UIB/nonlocal-matchfilter/releases/download/v1.0.0/rawnoise_25_15_9nbr.ckpt
```

Original sha256: `b31bc8e21022389b0b209a9d1e6649485ed4dacc552b7ea04612df5f7515fcf2`.
Both forms work as `--ckpt`.

The stripped form drops `optimizer_states` (Adam's `exp_avg`/`exp_avg_2`, two
tensors of 15.28 M parameters each), `lr_schedulers`, `loops` and `callbacks`.
Only `state_dict` is kept. Inference output is identical — verified at
250 ms/tile and `max|diff|` 1.67e-06 against the original-checkpoint conversion.

Also clone the upstream repository for the network definition:

```bash
git clone https://github.com/MIA-UIB/nonlocal-matchfilter upstream
```

## 3. Convert

```bash
.venv/bin/python Scripts/convert.py \
    --upstream upstream \
    --ckpt rawnoise_25_15_9nbr.ckpt \
    --size 256 --precision float32 \
    --out v_matmul_256.mlpackage
```

Expected output:

```
loaded 141 tensors (20 Linear->Conv2d reshaped)
matmul rewrite: 47 layers
converted float32 in 43.9 s -> v_matmul_256.mlpackage
  warm best 244 ms   max|diff vs torch| = 1.34e-06
```

## What the conversion has to work around

Three things block a naive `ct.convert`, and each has a specific fix in
`Scripts/network/`:

**`grid_sample` is not lowerable.** `deform_neighbourhood` uses it to sample
neighbour pixels at sub-pixel offsets. `nlmf_shim.py` reimplements it with
`gather` plus explicit bilinear weights. Verified against `F.unfold` on six
shape/pad/dilation combinations at 0.0 error — including the offset-probe case
that catches a transposed offset axis.

**`aten::Int` breaks conversion.** Any Python int derived from a traced tensor
shape (`h * w`, `c * h * w` in a `reshape`) becomes an op coremltools cannot fold.
`convert.py` asserts the traced graph has none. The fix is `flatten(2)` /
`unflatten(2, (h, w))` instead of computing the product.

**`dct_sub` must use `groups = n_features`, not 32.** The grouped 1x1 conv spans
each feature channel's k neighbours. Using the wrong group count gives a 0.28
relative error that looks like a precision problem rather than a wiring one.

Also: the FFN activation is **`ReLU`**, not GELU. The upstream `NonlocalBlock`
passes `nn.ReLU`; ConvNeXt's default is GELU, and the mismatch is silent until
you compare outputs.

## Why matmul, and why you should not microbenchmark it

The dominant layer is an 800-channel 1x1 convolution at full resolution. On Core
ML, lowering that as a matmul is **2.5× faster** for the whole graph:

| variant | whole graph (512²) |
|---|---|
| conv | 2550 ms |
| matmul | **1006 ms** |

A single-layer microbenchmark says the opposite (conv 12.7 ms vs matmul 15.2 ms)
because one layer has no memory pressure and no 800-channel tensor. Trust the
whole graph.

## Precision

Use **float32**.

| precision | 512² per tile | max\|diff vs torch\| |
|---|---|---|
| float32 | 1067 ms | 3.0e-06 |
| float16 | 1107 ms | **3.7e-02** |

fp16 is 4 % faster and four orders of magnitude less accurate. For a denoiser,
whose whole job is to preserve weak signal above the noise floor, that ratio is
not a trade — it is a defect.

## Tile size

Convert for the tile size you will actually run. The spatial shape is baked into
the graph; a 512² model rejects 1024² input.

`--size 256` is the measured sweet spot on a 60 MP frame (see the README table):
272 ms per tile × 247 tiles beats 1078 ms × 70 and 4627 ms × 20.

## Verifying the result

The script prints timing and error against the PyTorch reference. To check the
Swift side end to end:

```bash
swift build -c release
.build/release/nlmf-denoise v_matmul_256.mlpackage test.dng --out out.dng \
    --measure-noise --strength 0.7 --crop 4
```

A correct run reports `max|diff|` around 1e-06 from the converter and writes a
DNG that opens in any raw processor.
