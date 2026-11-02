#!/usr/bin/env python3
"""Synthetic CFA DNG with a **48-patch** chart (agrees with the user's "24 不够") + a 21-step ramp.

Pipeline (proven 2026-10-29):
  1. write a small CFA TIFF/DNG ourselves (this script),
  2. `dnglab convert -c lossless|uncompressed` to give it a container Apple accepts,
  3. `probe.swift` to read nativeSize / decoderVersion / WB response.

Patch set: 24 ColourChecker-like patches + 24 extra (6 hues × 4 saturations at one luminance), plus
21 neutral steps and a near-black band. Values are RAW COUNTS (0…16383) for an RGGB CFA: the same
value on every site of a patch gives it a neutral colour; per-channel values give it a hue.

Usage: make_patch_dng.py <real.dng> <out-raw.dng> [W] [H]
"""
import sys, json, shutil, subprocess
try:
    import numpy as np
    import tifffile
except ImportError as e:                       # clear failure, not a stack trace
    sys.exit(f"make_patch_dng.py: missing Python dependency ({e.name}) — "
             f"pip install numpy tifffile")

if len(sys.argv) < 3:
    sys.exit("usage: make_patch_dng.py <real.dng> <out-raw.dng> [W] [H]")
real, out = sys.argv[1], sys.argv[2]
W = int(sys.argv[3]) if len(sys.argv) > 3 else 1024
H = int(sys.argv[4]) if len(sys.argv) > 4 else 768

WHITE = 16383
BLACK = 200

def srgb_to_raw(r, g, b, scale=0.60):
    def lin(v):
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    peak = max(lin(r), lin(g), lin(b), 1e-6)
    k = (WHITE - BLACK) * scale / peak          # normalise the brightest channel of each patch
    return tuple(int(BLACK + lin(v) * k) for v in (r, g, b))

# ── 24 ColourChecker-ish (sRGB approximations) ──────────────────────────────────────────────
MACBETH = [
    (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67),
    (133, 128, 177), (103, 189, 170), (214, 126, 44), (80, 91, 166),
    (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
    (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31),
    (187, 86, 149), (8, 133, 161), (243, 243, 242), (200, 200, 200),
    (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
]
patches = [srgb_to_raw(*p) for p in MACBETH]

# ── 24 extra: 6 hues × 4 saturations at one luminance (same peak each row, so hue is the variable)
import colorsys
for row in range(4):
    for k in range(6):
        h = k / 6.0
        s = 0.25 + row * 0.22
        v = 0.92
        r, g, b = colorsys.hsv_to_rgb(h, s, v)
        patches.append(srgb_to_raw(r, g, b))

COLS, ROWS = 8, 6                                  # 48 patches
assert len(patches) >= COLS * ROWS

img = np.zeros((H, W), dtype=np.uint16)
yy, xx = np.mgrid[0:H, 0:W]
ey, ex = (yy % 2 == 0), (xx % 2 == 0)

def paint(y0, y1, x0, x1, r, g, b):
    sl = (slice(y0, y1), slice(x0, x1))
    img[sl][ey[sl] & ex[sl]] = r
    img[sl][ey[sl] & ~ex[sl]] = g
    img[sl][~ey[sl] & ex[sl]] = g
    img[sl][~ey[sl] & ~ex[sl]] = b

STEPS = 21
ramp_h = H // 5
for i in range(STEPS):
    L = int(BLACK + i * (WHITE - 4 * BLACK) / (STEPS - 1))
    paint(0, ramp_h, i * W // STEPS, (i + 1) * W // STEPS, L, L, L)

band_h = (H - ramp_h - H // 10) // ROWS
pw = W // COLS
for idx, (r, g, b) in enumerate(patches[: COLS * ROWS]):
    cy, cx = divmod(idx, COLS)
    paint(ramp_h + cy * band_h, ramp_h + (cy + 1) * band_h, cx * pw, (cx + 1) * pw, r, g, b)
img[H - H // 10:, :] = 100

if shutil.which("exiftool") is None:
    sys.exit("make_patch_dng.py: `exiftool` is not on PATH (brew install exiftool)")
info = json.loads(subprocess.run(["exiftool", "-j", "-G1", real], capture_output=True, text=True).stdout)[0]
def tag(name):
    for k, v in info.items():
        if k.split(":")[-1] == name:
            return v
def nums(s):
    return [float(x) for x in str(s).replace("[", " ").replace("]", " ").replace(";", " ").split()]

cm1 = nums(tag("ColorMatrix1") or "1 0 0 0 1 0 0 0 1")
asn = nums(tag("AsShotNeutral") or "0.42 1 0.58")
ILLUM = {"Standard Light A": 17, "Standard Light B": 18, "Standard Light C": 19,
         "D55": 20, "D65": 21, "D75": 22, "D50": 23, "Daylight": 1}

def rat(x, den=1000000): return (int(round(x * den)), den)
def srat(x, den=10000): return (int(round(x * den)), den)

extratags = [
    (50706, "B", 4, (1, 4, 0, 0)),
    (50707, "B", 4, (1, 1, 0, 0)),
    (50708, "s", 0, str(tag("UniqueCameraModel") or "Synthetic Camera")),
    (50710, "B", 3, (0, 1, 2)),
    (50711, "H", 1, 1),
    (50713, "H", 2, (2, 2)),
    (50714, "H", 4, (0, 0, 0, 0)),
    (50717, "I", 1, WHITE),
    (50721, "2i", 9, [x for v in cm1 for x in srat(v)]),
    (50728, "2I", 3, [x for v in asn for x in rat(v)]),
    (50778, "H", 1, ILLUM.get(str(tag("CalibrationIlluminant1")), 21)),
    (33421, "H", 2, (2, 2)),
    (33422, "B", 4, (0, 1, 1, 2)),
    (271, "s", 0, str(tag("Make") or "Synthetic")),
    (272, "s", 0, str(tag("Model") or "Synthetic Body")),
]

tifffile.imwrite(out, img, photometric="minisblack", bitspersample=16,
                 compression=None, extratags=extratags, metadata=None, rowsperstrip=H)
b = bytearray(open(out, "rb").read())
bo = "<" if b[:2] == b"II" else ">"
off = int.from_bytes(b[4:8], "little" if bo == "<" else "big")
n = int.from_bytes(b[off:off + 2], "little" if bo == "<" else "big")
for i in range(n):
    e = off + 2 + i * 12
    if int.from_bytes(b[e:e + 2], "little" if bo == "<" else "big") == 262:
        b[e + 8:e + 10] = (32803).to_bytes(2, "little" if bo == "<" else "big")
open(out, "wb").write(b)
print(f"wrote {out}: {W}×{H}, {COLS*ROWS} patches + {STEPS}-step ramp")
