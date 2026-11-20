"""Load the Buades/Sanchez-Beeckman trained network without the CUDA-only ops.

The upstream package imports `deform_neighbourhood_sampling` (a C++/CUDA torch
extension) and `patchmatch` (CUDA-only) at module import time. The multiscale
checkpoint (`rawnoise_25_15_9nbr.ckpt`, SimpleBlockMatchingUNet) needs only
`deform_neighbourhood`, which we reimplement here with gather + arithmetic so
that it runs on CPU, on Metal (MPS), and converts to Core ML (a `grid_sample`
would not convert).
"""

from __future__ import annotations

import sys
import types

import torch


# ---------------------------------------------------------------- stub modules
def install_stubs():
    """Fake out the two extension packages before importing the networks."""
    if "deform_neighbourhood_sampling" not in sys.modules:
        pkg = types.ModuleType("deform_neighbourhood_sampling")
        ops = types.ModuleType("deform_neighbourhood_sampling.ops")
        ops.deform_neighbourhood = deform_neighbourhood
        pkg.ops = ops
        sys.modules["deform_neighbourhood_sampling"] = pkg
        sys.modules["deform_neighbourhood_sampling.ops"] = ops

    if "patchmatch" not in sys.modules:
        pkg = types.ModuleType("patchmatch")

        def _unavailable(*_a, **_k):
            raise NotImplementedError("patchmatch (CUDA-only) is not used by the ms model")

        pkg.patch_match = _unavailable
        pkg.stack_matches = _unavailable
        sys.modules["patchmatch"] = pkg


def _bilinear_zero_pad(x: torch.Tensor, y: torch.Tensor, xq: torch.Tensor) -> torch.Tensor:
    """Bilinear sample of x (B,C,H,W) at (y, xq) of shape (1,H,W), zero outside.

    Matches the CUDA kernel's `bilinear_interpolate`: any tap that falls outside
    the image contributes zero, and the four weights are the plain bilinear ones.

    Every tensor here is 4-D and every reshape uses `.flatten(2)` / `-1` so that
    tracing never turns `h * w` into a tensor-derived Python int (coremltools
    cannot constant-fold `aten::Int`).
    """
    b, c, h_, w_ = x.shape

    y0 = torch.floor(y)
    x0 = torch.floor(xq)
    ly = y - y0
    lx = xq - x0

    y0i = y0.long()
    x0i = x0.long()

    flat = x.flatten(2)  # (B, C, H*W)

    def tap(yy: torch.Tensor, xx: torch.Tensor) -> torch.Tensor:
        inb = (yy >= 0) & (yy < h_) & (xx >= 0) & (xx < w_)
        idx = yy.clamp(0, h_ - 1) * w_ + xx.clamp(0, w_ - 1)
        idx = idx.flatten(1).unsqueeze(1).expand(-1, c, -1)  # (B, C, H*W)
        v = torch.gather(flat, 2, idx).reshape(b, c, h_, w_)
        return v * inb.to(x.dtype).unsqueeze(1).expand_as(v)

    v1 = tap(y0i, x0i)
    v2 = tap(y0i, x0i + 1)
    v3 = tap(y0i + 1, x0i)
    v4 = tap(y0i + 1, x0i + 1)

    wy1 = (1 - ly).unsqueeze(1)
    wx1 = (1 - lx).unsqueeze(1)
    wy2 = ly.unsqueeze(1)
    wx2 = lx.unsqueeze(1)

    return v1 * wy1 * wx1 + v2 * wy1 * wx2 + v3 * wy2 * wx1 + v4 * wy2 * wx2


def deform_neighbourhood(
    x: torch.Tensor,
    offset: torch.Tensor,
    neighbourhood_size,
    stride,
    padding,
    dilation,
    offset_groups: int,
) -> torch.Tensor:
    """Sampled-neighbourhood im2col, matching the CUDA `deform_neighbourhood`.

    x:        (B, C, H, W)
    offset:   (B, groups*2*kh*kw, H, W), offsets in pixels
    returns:  (B, C*kh*kw, H, W), channel order (c, i, j) as in the CUDA kernel
              (`out_c = in_c * kh * kw`, neighbour index innermost).
    """
    if isinstance(neighbourhood_size, int):
        neighbourhood_size = (neighbourhood_size, neighbourhood_size)
    if isinstance(stride, int):
        stride = (stride, stride)
    if isinstance(padding, int):
        padding = (padding, padding)
    if isinstance(dilation, int):
        dilation = (dilation, dilation)

    kh, kw = neighbourhood_size
    sh, sw = stride
    ph, pw = padding
    dh, dw = dilation

    b, c, h, w = x.shape
    k = kh * kw
    if offset_groups != 1:
        raise NotImplementedError("offset_groups > 1 is not used by the ms model")
    if sh != 1 or sw != 1:
        raise NotImplementedError("stride != 1 is not used by the ms model")

    off = offset.reshape(b, k, 2, h, w)

    yy = torch.arange(h, device=x.device, dtype=x.dtype)
    xx = torch.arange(w, device=x.device, dtype=x.dtype)
    grid_y, grid_x = torch.meshgrid(yy, xx, indexing="ij")

    out = []
    for i in range(kh):
        for j in range(kw):
            idx = i * kw + j
            y = grid_y + (i * dh - ph) + off[:, idx, 0]
            xq = grid_x + (j * dw - pw) + off[:, idx, 1]
            out.append(_bilinear_zero_pad(x, y, xq))

    # (B, C, k, H, W) -> (B, C*k, H, W) with the neighbour index innermost, as
    # the CUDA kernel's `out_c = in_c * kh * kw`. `flatten(1, 2)` (not a
    # `reshape(b, c * k, ...)`) keeps tracing from deriving a Python int.
    return torch.stack(out, dim=2).flatten(1, 2)


install_stubs()
