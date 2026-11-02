#!/usr/bin/env python3
"""Inject a controlled CFA pattern into the raw IFD of a dnglab-written UNCOMPRESSED DNG.

dnglab's file keeps the raw in an IFD whose PhotometricInterpretation is CFA (32803); tifffile only
surfaces the 8-bit thumbnail, so this walks the IFD chain by hand (IFD0 → next → SubIFDs) and patches
the strip bytes of the CFA IFD only.

Usage: inject_raw_ifd.py <uncompressed.dng> <out.dng>
"""
import sys, struct
try:
    import numpy as np
except ImportError:
    sys.exit("inject_raw_ifd.py: missing Python dependency (numpy) — pip install numpy")

if len(sys.argv) < 3:
    sys.exit("usage: inject_raw_ifd.py <uncompressed.dng> <out.dng>")
src, out = sys.argv[1], sys.argv[2]
data = bytearray(open(src, "rb").read())
bo = "<" if data[:2] == b"II" else ">"

TYPES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8}

def read_ifd(off):
    n = struct.unpack_from(bo + "H", data, off)[0]
    tags = {}
    for i in range(n):
        e = off + 2 + i * 12
        tag, typ, cnt = struct.unpack_from(bo + "HHI", data, e)
        size = TYPES.get(typ, 1) * cnt
        if size <= 4:
            raw = data[e + 8:e + 8 + size]
        else:
            ptr = struct.unpack_from(bo + "I", data, e + 8)[0]
            raw = data[ptr:ptr + size]
        if typ == 3:
            vals = list(struct.unpack_from(bo + f"{cnt}H", raw))
        elif typ in (4, 13):
            vals = list(struct.unpack_from(bo + f"{cnt}I", raw))
        elif typ == 1:
            vals = list(raw)
        else:
            vals = None
        tags[tag] = (typ, cnt, vals, raw)
    nxt = struct.unpack_from(bo + "I", data, off + 2 + n * 12)[0]
    return tags, nxt

# collect every IFD: main chain + SubIFDs (330)
queue, seen, found = [struct.unpack_from(bo + "I", data, 4)[0]], set(), None
while queue:
    off = queue.pop(0)
    if off <= 0 or off in seen:
        continue
    seen.add(off)
    tags, nxt = read_ifd(off)
    if nxt:
        queue.append(nxt)
    if 330 in tags and tags[330][2]:
        queue.extend(tags[330][2])
    if 262 in tags and tags[262][2] and tags[262][2][0] == 32803:
        found = (off, tags)
        break

if not found:
    sys.exit("no CFA IFD (photometric 32803) found — is this file uncompressed?")
off, tags = found
W = tags[256][2][0] if 256 in tags else tags[257][2][0]
H = tags[257][2][0]
offsets = tags[273][2]
counts = tags[279][2]
rps = tags[278][2][0] if 278 in tags else H
print(f"CFA IFD at {off}: {W}×{H}, {len(offsets)} strips, rows/strip {rps}, "
      f"total {sum(counts)/1e6:.1f} MB")

img = np.zeros((H, W), dtype=np.uint16)
yy, xx = np.mgrid[0:H, 0:W]
ey, ex = (yy % 2 == 0), (xx % 2 == 0)

def paint(y0, y1, x0, x1, r, g, b):
    sl = (slice(y0, y1), slice(x0, x1))
    img[sl][ey[sl] & ex[sl]] = r
    img[sl][ey[sl] & ~ex[sl]] = g
    img[sl][~ey[sl] & ex[sl]] = g
    img[sl][~ey[sl] & ~ex[sl]] = b

ramp_h = H // 4
for i in range(18):
    L = int(300 + i * (13500 - 300) / 17)
    paint(0, ramp_h, i * W // 18, (i + 1) * W // 18, L, L, L)

patches = [
    (9800, 5200, 3600), (4500, 9000, 5200), (5200, 5200, 11000), (11000, 11000, 11000),
    (3000, 3000, 3000), (1200, 1200, 1200), (9000, 3000, 2600), (2600, 6200, 9000),
    (9000, 8800, 3000), (3600, 9000, 8600), (7600, 3600, 8600), (8600, 7600, 3600),
    (6400, 6400, 6400), (4800, 4800, 4800), (3200, 3200, 3200), (1600, 1600, 1600),
    (12000, 8000, 6000), (6000, 9000, 12000), (2400, 4600, 7400), (7400, 4600, 2400),
    (4600, 2400, 4600), (10500, 6400, 6400), (6400, 10500, 6400), (6400, 6400, 10500),
]
rows, cols = 4, 6
band_h = (H - ramp_h - H // 8) // rows
pw = W // cols
for k, (r, g, b) in enumerate(patches):
    cy, cx = divmod(k, cols)
    paint(ramp_h + cy * band_h, ramp_h + (cy + 1) * band_h, cx * pw, (cx + 1) * pw, r, g, b)
img[H - H // 8:, :] = 200

row = 0
for o, c in zip(offsets, counts):
    nrows = c // (W * 2)
    if nrows == 0:
        continue
    blk = img[row:row + nrows, :]
    if blk.shape[0] < nrows:
        blk = np.pad(blk, ((0, nrows - blk.shape[0]), (0, 0)))
    data[o:o + c] = blk.astype("<u2").tobytes()
    row += nrows
print(f"filled {row}/{H} rows")
open(out, "wb").write(data)
print("wrote", out)
