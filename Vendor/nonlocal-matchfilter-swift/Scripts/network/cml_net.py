"""Core ML-friendly reimplementation of SimpleBlockMatchingUNet.

Same parameter names and same math as the upstream network, but with:

* no einops `rearrange` (its `int()` casts block coremltools' tracer),
* `nn.Linear` on (B, HW, C) replaced by 1x1 convolutions on (B, C, H, W),
  which is the identical operation per pixel,
* no `InputPadder` (static padding, computed from the fixed input size),
* `deform_neighbourhood` implemented with gather instead of `grid_sample`.

`load_state_dict(upstream_state_dict, strict=True)` must succeed: that is the
parity check that this really is the same network.
"""

from __future__ import annotations

import torch
import torch.nn as nn

from nlmf_shim import deform_neighbourhood


class CMLConvNeXtBlock(nn.Module):
    """ConvNeXt block: 7x7 depthwise conv, then a per-pixel GLU-less FFN."""

    def __init__(self, channels: int, ratio: int = 2):
        super().__init__()
        self.dwconv = nn.Conv2d(
            channels, channels, 7, stride=1, padding=3, bias=False, groups=channels
        )
        # upstream: Linear(C, ratio*C) -> ReLU -> Linear(ratio*C, C)
        # (the NonlocalBlock passes activation=nn.ReLU, not the ConvNeXt default GELU)
        self.ffn = nn.Module()
        self.ffn.ffn = nn.Sequential(
            nn.Conv2d(channels, ratio * channels, 1, bias=False),
            nn.ReLU(),
            nn.Identity(),
            nn.Dropout(0.0),
            nn.Conv2d(ratio * channels, channels, 1, bias=False),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return x + self.ffn.ffn(self.dwconv(x))


def _offset_cnn(in_ch: int, emb: int, n_off: int) -> nn.Sequential:
    """The upstream OffsetCNN stack, keeping its conv indices 0,2,4,6,8,10."""
    leaky = lambda: nn.LeakyReLU(negative_slope=0.1, inplace=False)  # noqa: E731
    return nn.Sequential(
        nn.Conv2d(in_ch, emb, 1),  # 0
        leaky(),  # 1
        nn.Conv2d(emb, emb, 3, padding=1),  # 2
        leaky(),  # 3
        nn.Conv2d(emb, emb, 3, padding=1),  # 4
        leaky(),  # 5
        nn.Conv2d(emb, emb, 3, padding=1),  # 6
        leaky(),  # 7
        nn.Conv2d(emb, emb, 3, padding=1),  # 8
        leaky(),  # 9
        nn.Conv2d(emb, n_off, 1),  # 10
    )


class CMLNonlocalBlock(nn.Module):
    """One learned block-matching stage: match, transform, Wiener, inverse."""

    def __init__(
        self,
        n_features: int,
        neighbours: tuple[int, int],
        max_search_dist: float,
    ):
        super().__init__()
        self.num_features = n_features
        self.neighbours = neighbours
        self.max_search_dist = max_search_dist
        k = neighbours[0] * neighbours[1]
        n = n_features * k

        self.encoder = nn.Sequential(CMLConvNeXtBlock(n_features))
        self.decoder = nn.Sequential(CMLConvNeXtBlock(n_features))
        self.offset_cnn = nn.Module()
        self.offset_cnn.cnn = _offset_cnn(n_features, n_features, 2 * k)

        # upstream: groups = n_features // <block groups> (1) = n_features, i.e.
        # one group per feature channel, spanning its k matched neighbours
        groups = n_features
        self.dct_sub = nn.Conv2d(n, n, 1, groups=groups, bias=False)
        # The three dense 1x1 convs below are ~93 % of the network's MACs. They
        # run as matmuls on MPS (`apply_matmul`), which is 1.6x faster end to end
        # with no accuracy change: the weight layout is identical to nn.Conv2d,
        # so a released checkpoint loads the same keys either way.
        self.wiener_sub = nn.Sequential(
            nn.Conv2d(n, n, 1, bias=False),  # 0
            nn.Conv2d(n, n, 3, padding=1, groups=n, bias=False),  # 1
            nn.ReLU(),  # 2
            nn.Conv2d(n, n, 1, bias=False),  # 3
            nn.Conv2d(n, n, 3, padding=1, groups=n, bias=False),  # 4
            nn.ReLU(),  # 5
            nn.Conv2d(n, n, 1, bias=False),  # 6
            nn.Conv2d(n, n, 3, padding=1, groups=n, bias=False),  # 7
            nn.Sigmoid(),  # 8
        )
        self.inv_dct_sub = nn.Sequential(
            nn.Conv2d(n, n, 1, groups=groups, bias=False),  # 0
            nn.Conv2d(n, n_features, 1, bias=False),  # 1
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        kh, kw = self.neighbours
        x = self.encoder(x)

        offsets = torch.tanh(self.offset_cnn.cnn(x)) * self.max_search_dist
        x_blocks = deform_neighbourhood(
            x, offsets, self.neighbours, 1, (kh // 2, kw // 2), 1, 1
        )

        wiener = self.wiener_sub(x_blocks)
        dct = self.dct_sub(x_blocks)
        return self.decoder(self.inv_dct_sub(wiener * dct))


def _pad_to_multiple(size: int, m: int) -> tuple[int, int]:
    total = (m - size % m) % m
    first = total // 2
    return first, total - first


class CMLRawDenoiser(nn.Module):
    """SimpleBlockMatchingUNet (multiscale, 25/15/9 neighbours)."""

    def __init__(
        self,
        input_channels: int = 8,
        output_channels: int = 4,
        n_features: int = 32,
        neighbours: dict | None = None,
        max_search_dist: float = 9.0,
        pad_to: int = 4,
    ):
        super().__init__()
        neighbours = neighbours or {
            "scale1": [5, 5],
            "scale2": [3, 5],
            "scale3": [3, 3],
        }
        f = n_features
        self.pad_to = pad_to
        self.in_channels = input_channels
        self.out_channels = output_channels

        self.head = nn.Conv2d(input_channels, f, 3, padding=1, bias=False)

        self.down1 = nn.Sequential(
            CMLNonlocalBlock(f, tuple(neighbours["scale1"]), max_search_dist),
            nn.Conv2d(f, f * 2, 2, stride=2, bias=False),
        )
        self.down2 = nn.Sequential(
            CMLNonlocalBlock(f * 2, tuple(neighbours["scale2"]), max_search_dist),
            nn.Conv2d(f * 2, f * 4, 2, stride=2, bias=False),
        )
        self.body = nn.Sequential(
            CMLNonlocalBlock(f * 4, tuple(neighbours["scale3"]), max_search_dist)
        )
        self.up2 = nn.Sequential(
            nn.ConvTranspose2d(f * 4, f * 2, 2, stride=2, bias=False),
            CMLNonlocalBlock(f * 2, tuple(neighbours["scale2"]), max_search_dist),
        )
        self.up1 = nn.Sequential(
            nn.ConvTranspose2d(f * 2, f, 2, stride=2, bias=False),
            CMLNonlocalBlock(f, tuple(neighbours["scale1"]), max_search_dist),
        )
        self.tail = nn.Conv2d(f, output_channels, 3, padding=1, bias=False)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        h, w = x.shape[-2], x.shape[-1]
        pt, pb = _pad_to_multiple(h, self.pad_to)
        pl, pr = _pad_to_multiple(w, self.pad_to)
        if pt or pb or pl or pr:
            x = nn.functional.pad(x, (pl, pr, pt, pb), mode="reflect")

        f0 = self.head(x)
        f1 = self.down1(f0)
        f2 = self.down2(f1)
        f2 = self.body(f2) + f2
        f1 = self.up2(f2) + f1
        f0 = self.up1(f1) + f0
        out = self.tail(f0)

        if pt or pb or pl or pr:
            out = out[:, :, pt : out.shape[-2] - pb, pl : out.shape[-1] - pr]
        return out
