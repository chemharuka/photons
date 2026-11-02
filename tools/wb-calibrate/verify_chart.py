#!/usr/bin/env python3
"""Machine acceptance for the synthetic 256-patch chart, from the *decoded* PNG.

Everything here is measured, nothing is assumed about the decoder:

  1. all 256 cells present          — 16×16 grid, 32 px cells, central 8×8 sampled; a missing or
                                      misaligned cell cannot be uniform, so this shows up in (4)
  2. neutral rows 0–1 (32 patches)  — chroma spread max(R,G,B) − min(R,G,B) ≤ 8 (8-bit) and
                                      luminance monotone non-decreasing with patch index (±1 jitter)
  3. colour rows 2–15 (224 patches) — at least 200 distinct 8-bit RGB triples
  4. per-cell stability             — σ of the central 8×8 ≤ 2 on every channel of every cell
  5. no clipping                    — at most 2 cells with a channel at 255
  6. orientation                    — the neutral ramp is row-major, black at the TOP-LEFT cell and
                                      near-white at row 1 col 15: pins no x-mirror, no y-flip, no
                                      transpose, no crop offset (a flipped/offset frame cannot keep
                                      the ramp ascending left→right *and* top→bottom)
  7. hue order                      — the 224 colour cells are 8 hue blocks of 28; the measured hue
                                      of block k must be strictly greater than block k−1 (circularly)
                                      and the 8 steps must close the 360° circle. Absolute hues are
                                      rotated by the camera matrix (design 135° lands near 94°), so
                                      the assertion is on ORDER, not on the design hue.

Usage: verify_chart.py <decoded.png> [--grid 16] [--inner 8] [--quiet]
Exit code 0 = all checks green.
"""
import argparse
import colorsys
import sys

try:
    import numpy as np
    from PIL import Image
except ImportError as e:                       # clear failure, not a stack trace
    sys.exit(f"verify_chart.py: missing Python dependency ({e.name}) — "
             f"pip install numpy pillow")

CHROMA_TOL = 8          # max(R,G,B) - min(R,G,B) on a neutral patch
SIGMA_TOL = 2.0         # per-cell sigma of the sampled interior
JITTER = 1              # allowed dip in the neutral luminance ramp
MIN_DISTINCT = 200      # of the 224 colour patches
MAX_CLIPPED = 2         # cells with any channel at 255
MIN_CHROMA_HUE = 12     # cells below this are too grey for a stable hue angle
HUE_SPREAD_TOL = 25.0   # hue spread inside one block (design separates blocks by 45°)
HUE_STEP = (5.0, 90.0)  # allowed circular step between consecutive blocks
PER_BLOCK = 28          # 4 saturations × 7 values
BLOCKS = 8
MIN_USABLE = 20         # cells per block with a measurable hue


def main():
    ap = argparse.ArgumentParser(description="Verify a decoded 16×16 synthetic chart PNG.")
    ap.add_argument("png", help="decoded PNG written by probe2.swift")
    ap.add_argument("--grid", type=int, default=16, help="cells per axis (default 16)")
    ap.add_argument("--inner", type=int, default=8, help="central sample size per cell (default 8)")
    ap.add_argument("--quiet", action="store_true", help="only the check table")
    opt = ap.parse_args()

    n, inner = opt.grid, opt.inner
    try:
        a = np.asarray(Image.open(opt.png).convert("RGB")).astype(float)
    except OSError as e:
        sys.exit(f"verify_chart.py: cannot read {opt.png}: {e}")
    h, w = a.shape[:2]
    ch, cw = h // n, w // n
    oy, ox = (ch - inner) // 2, (cw - inner) // 2

    mean = np.zeros((n, n, 3))
    sigma = np.zeros((n, n))
    for r in range(n):
        for c in range(n):
            blk = a[r * ch + oy:r * ch + oy + inner, c * cw + ox:c * cw + ox + inner]
            v = blk.reshape(-1, 3)
            mean[r, c] = v.mean(0)
            sigma[r, c] = v.std(0).max()          # worst channel

    neutral = mean[:2].reshape(-1, 3)             # rows 0–1, 32 patches (row-major = patch order)
    chroma = neutral.max(1) - neutral.min(1)
    lum = neutral.mean(1)
    colour = mean[2:].reshape(-1, 3)              # 224 patches
    triples = {tuple(int(round(v)) for v in p) for p in colour}
    clipped = int((mean.max(2) == 255).sum())

    report = []

    def check(name, passed, detail):
        report.append((name, passed, detail))

    check("cells", w % n == 0 and h % n == 0 and cw > inner and ch > inner,
          f"{w}×{h}, {n}×{n} cells of {cw}×{ch} px, sampled centre {inner}×{inner}")
    check("neutral chroma ≤ %d" % CHROMA_TOL, chroma.max() <= CHROMA_TOL,
          f"max {chroma.max():.1f} at patch {int(chroma.argmax())} "
          f"(mean {chroma.mean():.1f}, p95 {np.percentile(chroma, 95):.1f})")
    dips = np.diff(lum)
    check("neutral monotone (±%d)" % JITTER, dips.min() >= -JITTER,
          f"min step {dips.min():+.1f}, {int((dips < 0).sum())} negative steps, "
          f"range {lum[0]:.0f} → {lum[-1]:.0f}")
    check("≥%d distinct colour patches" % MIN_DISTINCT, len(triples) >= MIN_DISTINCT,
          f"{len(triples)} distinct of {len(colour)}")
    check("σ ≤ %.1f" % SIGMA_TOL, sigma.max() <= SIGMA_TOL,
          f"max {sigma.max():.2f} at cell {np.unravel_index(sigma.argmax(), sigma.shape)} "
          f"(mean {sigma.mean():.2f})")
    check("clipped ≤ %d" % MAX_CLIPPED, clipped <= MAX_CLIPPED,
          f"{clipped} cells with a channel at 255")

    # ---- orientation: the neutral ramp must run row-major from the top-left cell ---------------
    # Anything that mirrors x, flips y, transposes, or shifts the crop by one cell breaks at least
    # one of these four orderings (the ramp is 32 consecutive steps spread over 2 rows of 16).
    lum_grid = mean.mean(2)
    darkest = np.unravel_index(lum_grid.argmin(), (n, n))
    darkest = (int(darkest[0]), int(darkest[1]))
    tl, tr = lum_grid[0, 0], lum_grid[0, -1]
    bl, br = lum_grid[1, 0], lum_grid[1, -1]
    orient_ok = (tl < tr < bl < br) and darkest == (0, 0) and lum[-1] == lum.max()
    check("orientation (row/col)", orient_ok,
          f"TL {tl:.0f} < TR {tr:.0f} < BL {bl:.0f} < BR {br:.0f}; "
          f"darkest cell {darkest}, brightest neutral {lum[-1]:.0f}")

    # ---- hue order: 8 blocks of 28 cells, block hue must advance around the wheel --------------
    hues, spread, usable = [], [], []
    for b in range(BLOCKS):
        blk = colour[b * PER_BLOCK:(b + 1) * PER_BLOCK]
        hh = []
        for p in blk:
            if p.max() - p.min() >= MIN_CHROMA_HUE:          # grey cells have no stable hue
                hh.append(colorsys.rgb_to_hsv(*(p / 255.0))[0] * 360.0)
        usable.append(len(hh))
        if not hh:
            hues.append(float("nan"))
            spread.append(float("nan"))
            continue
        # circular mean, so block 0 straddling 0°/360° does not read as split
        ang = np.radians(hh)
        mean_h = np.degrees(np.arctan2(np.sin(ang).mean(), np.cos(ang).mean())) % 360.0
        hues.append(mean_h)
        d = (np.array(hh) - mean_h + 180.0) % 360.0 - 180.0
        spread.append(float(d.max() - d.min()))

    steps = [(hues[(b + 1) % BLOCKS] - hues[b]) % 360.0 for b in range(BLOCKS)]
    hue_ok = (not np.isnan(hues).any()
              and all(HUE_STEP[0] <= s <= HUE_STEP[1] for s in steps)
              and abs(sum(steps) - 360.0) <= HUE_SPREAD_TOL
              and max(spread) <= HUE_SPREAD_TOL
              and min(usable) >= MIN_USABLE)
    check("hue order (8 blocks)", hue_ok,
          f"steps {['%.0f' % s for s in steps]} (sum {sum(steps):.0f}°), "
          f"worst in-block spread {max(spread):.0f}°, usable {min(usable)}–{max(usable)}/{PER_BLOCK}")

    print(f"verify_chart.py  {opt.png}")
    for name, passed, detail in report:
        print(f"  [{'PASS' if passed else 'FAIL'}] {name:26s} {detail}")

    if not opt.quiet:
        print("\n  neutral rows 0–1 (32 patches, mean R/G/B, chroma spread):")
        for i in range(0, 32, 4):
            print("   " + "  ".join(f"{neutral[k][0]:3.0f}/{neutral[k][1]:3.0f}/{neutral[k][2]:3.0f}"
                                    f"±{chroma[k]:2.0f}" for k in range(i, i + 4)))
        print("\n  first 8 colour patches (row 2):")
        print("   " + "  ".join(f"{colour[k][0]:3.0f}/{colour[k][1]:3.0f}/{colour[k][2]:3.0f}"
                                for k in range(8)))
        print("\n  hue blocks (design hue → measured hue ± in-block spread, cells with chroma ≥ %d):"
              % MIN_CHROMA_HUE)
        for b in range(BLOCKS):
            print(f"   block {b}  design {b * 45:3d}°  measured {hues[b]:6.1f}°  "
                  f"spread {spread[b]:4.0f}°  {usable[b]:2d}/{PER_BLOCK} cells")
        print("\n  orientation: neutral corner luminance TL/TR/BL/BR = "
              f"{tl:.0f}/{tr:.0f}/{bl:.0f}/{br:.0f}, darkest cell {darkest}")

    failed = [name for name, passed, _ in report if not passed]
    if failed:
        print(f"\n  VIOLATIONS: {', '.join(failed)}")
        return 1
    print("\n  ALL GREEN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
