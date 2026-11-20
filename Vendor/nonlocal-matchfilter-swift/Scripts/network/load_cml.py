"""Load the released weights into the Core ML-friendly network.

The upstream net stores its per-pixel FFN as `nn.Linear(C, 2C)` on (B,HW,C); here
it is a 1x1 `nn.Conv2d` on (B,C,H,W). That is the same operation, so the only
conversion needed is a reshape of the weight tensor.

`matmul=True` (the default) additionally rewrites the dense 1x1 convs per block as
matmuls. On Core ML that is 2.5x faster for the whole graph at identical output;
on torch/MPS it is 1.6x. The weights and state_dict keys are unchanged either way.

Path-independent on purpose: this module is imported by `Scripts/convert.py`,
which is run from a checkout, not from a fixed working directory.
"""

from __future__ import annotations

import sys
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from cml_net import CMLRawDenoiser  # noqa: E402
from matmul_conv import convert_to_matmul  # noqa: E402

# upstream nn.Linear weight (inner, in) -> Conv2d weight (inner, in, 1, 1)
LINEAR_SUFFIXES = ("ffn.ffn.0.weight", "ffn.ffn.4.weight")


def _state_dict_from_checkpoint(ckpt_path: str) -> dict:
    """Accept either the upstream Lightning checkpoint or the stripped weights.

    The upstream `.ckpt` is 175 MB of which only 58 MB is the network — the rest
    is optimizer state (Adam's exp_avg/exp_avg_sq, two tensors per parameter) and
    the LR scheduler, none of which affects inference. `Models/` therefore ships
    the stripped form: a dict with just `state_dict`, 58 MB and inside GitHub's
    per-file limit.
    """
    ck = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    sd = ck["state_dict"]
    # Upstream keys are prefixed with the Lightning module name.
    stripped = {k[len("model."):] if k.startswith("model.") else k: v
                for k, v in sd.items()}
    return stripped


def build_cml(
    ckpt_path: str,
    device: str = "cpu",
    matmul: bool = True,
    verbose: bool = True,
) -> CMLRawDenoiser:
    up = _state_dict_from_checkpoint(ckpt_path)
    net = CMLRawDenoiser()

    have = set(net.state_dict().keys())
    conv_keys = set()
    for key, val in list(up.items()):
        if key.endswith(LINEAR_SUFFIXES):
            conv_keys.add(key)
            if val.dim() == 2:
                up[key] = val.reshape(*val.shape, 1, 1)

    missing = have - set(up.keys())
    unexpected = set(up.keys()) - have
    if verbose and (missing or unexpected):
        print("keys in model but not checkpoint:", sorted(missing))
        print("keys in checkpoint but not model:", sorted(unexpected))

    net.load_state_dict({k: v for k, v in up.items() if k in have}, strict=True)
    net.eval()
    if verbose:
        print(f"loaded {len(have)} tensors ({len(conv_keys)} Linear->Conv2d reshaped)")

    if matmul:
        n = convert_to_matmul(net)
        if verbose:
            print(f"matmul rewrite: {n} layers")

    return net.to(device)
