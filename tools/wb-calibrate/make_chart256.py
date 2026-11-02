#!/usr/bin/env python3
"""512×512 synthetic CFA chart with **256 patches** (user's spec: 8×8 stable interior per patch).

Layout — 16 × 16 cells, each cell 32 × 32 px, sample the central 8 × 8:
  · rows 0–1   : 32 neutral steps (sRGB 0.04 … 0.96)
  · rows 2–15  : 224 colour patches = 8 hues × 4 saturations × 7 values

Container: this writes the raw CFA file; run `dnglab convert -c lossless` afterwards to get a container
Apple's decoder accepts (see README).

Two hard constraints, both measured (README §「合成图表的两条硬约束」):
  · a neutral in camera raw is proportional to **AsShotNeutral**, not R=G=B — the decoder multiplies
    by 1/AsShotNeutral, so equal raw counts come out as a colour cast;
  · **one global scale** for the whole chart — per-patch normalisation flattens the luminance steps.

Usage: make_chart256.py <real.dng> <out-raw.dng> [peak]
"""
import colorsys
import sys

try:
    import numpy as np
    import tifffile
except ImportError as e:                       # clear failure, not a stack trace
    sys.exit(f"make_chart256.py: missing Python dependency ({e.name}) — "
             f"pip install numpy tifffile")

import dngmeta

if len(sys.argv) < 3:
    sys.exit("usage: make_chart256.py <real.dng> <out-raw.dng> [peak]")
real, out = sys.argv[1], sys.argv[2]
PEAK = float(sys.argv[3]) if len(sys.argv) > 3 else 0.88

W = H = 512
CELL = 32                     # 16 cells per axis
GRID = W // CELL              # 16
WHITE, BLACK = 16383, 0

ASN = dngmeta.asn_effective(real)
# One global scale for the whole chart, so luminance differences between patches survive.
K = (WHITE - BLACK) * PEAK / max(ASN)


def lin(v):
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def raw_from_srgb(r, g, b):
    return tuple(int(BLACK + lin(v) * ASN[i] * K) for i, v in enumerate((r, g, b)))


cells = []                                   # row-major, 16 × 16 = 256
for i in range(32):                          # 32 neutral steps
    v = 0.04 + i * (0.96 - 0.04) / 31
    cells.append(raw_from_srgb(v, v, v))
for hue_i in range(8):
    for sat_i in range(4):
        for val_i in range(7):
            h = hue_i / 8.0
            s = 0.15 + sat_i * 0.28
            # 0.25 + 0.12 reached 0.97 and the decoder's matrix/saturation boost clipped the
            # primary corner (measured: 8 patches with a channel at 255). 0.22 + 0.10 tops out at
            # 0.82, which the pipeline holds without clipping (README「颜色」).
            v = 0.22 + val_i * 0.10
            cells.append(raw_from_srgb(*colorsys.hsv_to_rgb(h, s, v)))
assert len(cells) == 256, len(cells)

img = np.zeros((H, W), dtype=np.uint16)
yy, xx = np.mgrid[0:H, 0:W]
ey, ex = (yy % 2 == 0), (xx % 2 == 0)
# RGGB: R at (even,even) · G at (even,odd) and (odd,even) · B at (odd,odd)
PLANE = [ey & ex, (ey & ~ex) | (~ey & ex), ~ey & ~ex]


def paint(y0, y1, x0, x1, r, g, b):
    sl = (slice(y0, y1), slice(x0, x1))
    for plane, val in zip(PLANE, (r, g, b)):
        img[sl][plane[sl]] = val


for idx, (r, g, b) in enumerate(cells):
    cy, cx = divmod(idx, GRID)
    paint(cy * CELL, (cy + 1) * CELL, cx * CELL, (cx + 1) * CELL, r, g, b)

tifffile.imwrite(out, img, photometric="minisblack", bitspersample=16, compression=None,
                 extratags=dngmeta.extratags(real, black_level=BLACK, white_level=WHITE),
                 metadata=None, rowsperstrip=H)

# tifffile writes PhotometricInterpretation=1 (minisblack); DNG needs 32803 (CFA).
b = bytearray(open(out, "rb").read())
le = b[:2] == b"II"
off = int.from_bytes(b[4:8], "little" if le else "big")
n = int.from_bytes(b[off:off + 2], "little" if le else "big")
for i in range(n):
    e = off + 2 + i * 12
    if int.from_bytes(b[e:e + 2], "little" if le else "big") == 262:
        b[e + 8:e + 10] = (32803).to_bytes(2, "little" if le else "big")
open(out, "wb").write(b)
print(f"wrote {out}: {W}×{H}, 256 cells of {CELL}×{CELL} px (sample the central 8×8), "
      f"PEAK {PEAK}, ASN {['%.4f' % v for v in ASN]}")
