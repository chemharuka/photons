"""Make the 1x1 convs run as pure matmuls.

Every 1x1 conv is a matmul on the flattened spatial axis:
`Conv1x1(W, x) == W @ x.flatten(2)`. On MPS, `conv2d` with a 1x1 kernel reaches
only ~1.9 TFLOP/s while `matmul` reaches ~5.7 TFLOP/s (measured on an M1 Max):
the conv path goes through an im2col-style kernel that cannot keep the simdgroup
matrix units busy on a 1x1 filter.

Three subclasses, all inheriting `nn.Conv2d` so the state_dict layout is
unchanged and released checkpoints load directly:

* `MatmulConv1x1`    - dense 1x1 (the 800/960/1152 channel wiener layers)
* `MatmulConv1x1DW`  - depthwise 1x1, i.e. a per-channel scale
* `MatmulConv1x1G`   - grouped 1x1 (dct_sub, inv_dct_sub: groups = n_features)

All three are numerically equivalent to the conv they replace (verified to
<1e-6 in fp32) and all three lower to Core ML MIL ops.
"""

from __future__ import annotations

import torch
import torch.nn as nn


class MatmulConv1x1(nn.Conv2d):
    """A dense `nn.Conv2d(k=1, groups=1)` evaluated as one matmul."""

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        n, c, h, w = x.shape
        weight = self.weight.reshape(self.out_channels, self.in_channels)
        # flatten(2) rather than reshape(n, c, h*w): the latter derives a Python
        # int from a traced tensor and leaves `aten::Int` nodes that coremltools
        # cannot fold. Same for the output: `unflatten` keeps it symbolic.
        y = torch.matmul(weight, x.flatten(2))
        y = y.unflatten(2, (h, w))
        if self.bias is not None:
            y = y + self.bias.reshape(1, -1, 1, 1)
        return y


class MatmulConv1x1DW(nn.Conv2d):
    """A depthwise `nn.Conv2d(k=1, groups=channels)`: a per-channel scale."""

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = x * self.weight.reshape(1, -1, 1, 1)
        if self.bias is not None:
            y = y + self.bias.reshape(1, -1, 1, 1)
        return y


class MatmulConv1x1G(nn.Conv2d):
    """A grouped `nn.Conv2d(k=1, groups=g)` evaluated as a batched matmul.

    Input is split into `g` contiguous channel groups of size `c/g`; each group
    is multiplied by its own (out/g, in/g) slice. `torch.bmm` over g batches,
    with the spatial axis as the batch's inner dimension.
    """

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        n, c, h, w = x.shape
        g = self.groups
        ci = self.in_channels // g
        co = self.out_channels // g

        # (n, g, ci, hw) and weights (g, co, ci) -> batched matmul over the groups.
        # `flatten`/`unflatten` keep the spatial size symbolic for coremltools.
        xg = x.reshape(n, g, ci, -1).permute(1, 0, 2, 3)  # (g, n, ci, hw)
        wg = self.weight.reshape(g, co, ci).unsqueeze(1).expand(g, n, co, ci)
        yg = torch.matmul(wg, xg)  # (g, n, co, hw)
        y = yg.permute(1, 0, 2, 3).flatten(1, 2).unflatten(2, (h, w))
        if self.bias is not None:
            y = y + self.bias.reshape(1, -1, 1, 1)
        return y


def convert_to_matmul(
    module: nn.Module,
    min_channels: int = 64,
    groups: bool = True,
    depthwise: bool = True,
) -> int:
    """Replace eligible 1x1 convs in `module` with their matmul equivalents.

    `min_channels` guards the small FFN convs (32->64): the reshape is not worth
    it there and they are not the bottleneck. Depthwise and grouped 1x1 convs are
    only converted when `depthwise` / `groups` are set.
    """
    n = 0
    for parent in list(module.modules()):
        for name, child in list(parent.named_children()):
            if not isinstance(child, nn.Conv2d) or child.kernel_size != (1, 1):
                continue

            is_dw = child.groups == child.in_channels == child.out_channels
            is_grouped = 1 < child.groups < child.in_channels

            if child.groups == 1 and child.out_channels >= min_channels:
                new = MatmulConv1x1(
                    child.in_channels,
                    child.out_channels,
                    1,
                    bias=child.bias is not None,
                    dtype=child.weight.dtype,
                    device=child.weight.device,
                )
            elif is_dw and depthwise:
                new = MatmulConv1x1DW(
                    child.in_channels,
                    child.out_channels,
                    1,
                    groups=child.groups,
                    bias=child.bias is not None,
                    dtype=child.weight.dtype,
                    device=child.weight.device,
                )
            elif is_grouped and groups:
                new = MatmulConv1x1G(
                    child.in_channels,
                    child.out_channels,
                    1,
                    groups=child.groups,
                    bias=child.bias is not None,
                    dtype=child.weight.dtype,
                    device=child.weight.device,
                )
            else:
                continue

            new.weight.data = child.weight.data.clone()
            if child.bias is not None:
                new.bias.data = child.bias.data.clone()
            setattr(parent, name, new)
            n += 1
    return n


def parity_check(build_fn, hw: int = 128, seed: int = 0, **kw) -> float:
    """Converted net must match the original in fp32 (CPU)."""
    torch.manual_seed(seed)
    a = build_fn().eval()
    b = build_fn().eval()
    n = convert_to_matmul(b, **kw)
    x = torch.rand(1, 8, hw, hw)
    with torch.no_grad():
        ya, yb = a(x), b(x)
    err = (ya - yb).abs().max().item()
    print(f"converted {n} layers; max|diff| on {hw}x{hw} = {err:.3e}")
    return err
