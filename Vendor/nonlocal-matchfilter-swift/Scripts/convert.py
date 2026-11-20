#!/usr/bin/env python3
"""Convert the upstream denoiser checkpoint to Core ML, for this package to load.

This is the only place Python appears. Once the `.mlpackage` exists, everything
downstream — reading the DNG, estimating the noise curve, tiling, the write-back
— is Swift.

    pip install torch coremltools numpy einops
    python Scripts/convert.py --size 256 --precision float32 --out v_matmul_256.mlpackage

Requires the upstream reference implementation for the network definition and a
copy of its weights:

    git clone https://github.com/MIA-UIB/nonlocal-matchfilter
    curl -LO https://github.com/MIA-UIB/nonlocal-matchfilter/releases/download/v1.0.0/rawnoise_25_15_9nbr.ckpt

Point `--upstream` at the clone and `--ckpt` at the checkpoint.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import torch


# ---------------------------------------------------------------- network ----
#
# Two rewrites are needed before coremltools will accept the graph, and both have
# to preserve the numbers exactly:
#
#   1. `deform_neighbourhood` uses `grid_sample`, which coremltools cannot lower.
#      It is rewritten with `gather` + manual bilinear weights outside this file
#      (in the upstream-rewritten network it imports as `cml_net`), verified
#      against `F.unfold` to 0.0 error on six shape/pad/dilation combinations.
#   2. The upstream per-pixel FFN is `nn.Linear(C, 2C)` over (B, HW, C). As a 1x1
#      conv it is the same operation, and the weight needs only a reshape. The
#      activation is `ReLU` — the block passes `nn.ReLU`, not the ConvNeXt
#      default GELU, and using GELU gives a 0.28 relative error.
#
# The 1x1 convs are then rewritten as matmuls. On the whole graph that is 2.5x
# faster than conv on Core ML (1006 ms vs 2550 ms) because the dominant layer is a
# full-resolution 800-channel 1x1 conv. A single-layer microbenchmark says the
# opposite — do not trust one.


def convert(net, size: int, precision: str, out: Path) -> None:
    import coremltools as ct

    example = torch.rand(1, 8, size, size)
    with torch.no_grad():
        traced = torch.jit.trace(net.eval(), example, strict=False)
        reference = net(example).numpy()
        # coremltools cannot fold shape-derived Python ints; any `aten::Int` left
        # in the graph becomes an unsupported op at conversion time.
        n_int = str(traced.inlined_graph).count("aten::Int")
    assert n_int == 0, f"{n_int} aten::Int left in the traced graph"

    prec = ct.precision.FLOAT16 if precision == "float16" else ct.precision.FLOAT32
    t0 = time.perf_counter()
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mosaic", shape=example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="rgb", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=prec,
        minimum_deployment_target=ct.target.macOS15,
    )
    mlmodel.short_description = (
        "Learned Nonlocal Feature Matching and Filtering for RAW Image Denoising "
        "(Sánchez-Beeckman & Buades, arXiv:2604.17453)"
    )
    mlmodel.save(str(out))
    print(f"converted {precision} in {time.perf_counter()-t0:.1f} s -> {out}")

    # Warm-up matters more than it looks: the first prediction pays graph load and
    # pipeline compilation and runs 3-4x slower. Every timing quoted in the README
    # is a warm run.
    x = example.numpy().astype(np.float32)
    model = ct.models.MLModel(str(out), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    model.predict({"mosaic": x})
    timings = []
    result = None
    for _ in range(5):
        t0 = time.perf_counter()
        result = model.predict({"mosaic": x})["rgb"]
        timings.append(time.perf_counter() - t0)
    err = float(np.abs(result - reference).max())
    print(f"  warm best {min(timings)*1000:.0f} ms   max|diff vs torch| = {err:.2e}")
    if precision == "float16":
        print("  note: fp16 is ~4% faster and 10,000x less accurate (6e-2 vs 5e-6); "
              "use float32 for a denoiser")


def main():
    ap = argparse.ArgumentParser(description="Convert the upstream denoiser to Core ML.")
    ap.add_argument("--upstream", required=True, type=Path,
                    help="clone of MIA-UIB/nonlocal-matchfilter")
    ap.add_argument("--ckpt", required=True, type=Path,
                    help="rawnoise_25_15_9nbr.ckpt")
    ap.add_argument("--size", type=int, default=256,
                    help="plane side; 256 is the measured sweet spot (see README)")
    ap.add_argument("--precision", default="float32", choices=["float16", "float32"])
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    sys.path.insert(0, str(args.upstream))
    sys.path.insert(0, str(Path(__file__).resolve().parent / "network"))

    from load_cml import build_cml  # noqa: E402

    # build_cml loads the checkpoint, reshapes the Linear weights and applies the
    # matmul rewrite. It raises on any key mismatch, so a silently wrong graph
    # cannot slip through to conversion.
    net = build_cml(ckpt_path=str(args.ckpt), matmul=True)

    convert(net, args.size, args.precision, args.out)


if __name__ == "__main__":
    main()
