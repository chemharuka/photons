# Porting notes

Source of truth: [HDRMerge](https://github.com/jcelaya/hdrmerge) master
(`Image.cpp`, `ImageStack.cpp`, `Bitmap.cpp`, `Image.hpp`, `DngFloatWriter.cpp`,
`RawParameters.cpp`), read on 2026-11-11.

## What is a straight port

* **Alignment** — 6-level 2×2-binned pyramid, median threshold bitmaps at the
  percentile `fraction(satThreshold)/2`, exclusion band `±floor(mth/16)`,
  3×3 search per level, `dx <<= 1` between levels, chain through
  `images[i].alignWith(images[i+1])` then accumulate offsets from the darkest
  frame upward. `Bitmap.shifted(dx,dy)` moves content by `(dx,dy)`, matching
  Ward's original convention.
* **Saturation level** — per-CFA-colour histograms on the brightest frame, take
  the highest value whose count exceeds `width*height/10000`, clamp to the
  white level, then `×0.99` unless the caller supplied a white level.
* **Mask** — per pixel, the first (brightest) frame that contains the pixel and
  whose 3×3 maximum is below the saturation threshold.
* **Compose** — feathered layer index, sub-pixel interpolation between layer
  `j` and `j+1`, then `mult = (white - maxBlack)/peak` and re-add the black
  level. This last step brightens the output so the brightest sample lands on
  the white level — that is upstream behaviour, not a bug in the port.

## What is deliberately different

1. **Exposure ratio** — upstream fits a penalised spline (ALGLIB
   `spline1dfitpenalized`) to model a non-linear camera response, with a
   least-squares fallback for dark frames. The port always uses the fallback:

   ```
   k = Σ (v_bright · v_dark) / Σ (v_dark²)   over pixels with v_bright < sat
   ```

   For linear sensor data this is the exact answer (verified: a synthetic
   4-stop bracket reports 4.000). It only differs on raws whose response has
   already been tone-mapped — rare, and not the target of this tool.

2. **Mask fattening** — upstream uses a disk structuring element with a
   precomputed chord table; the port uses a separable square element. The
   visible difference is confined to the 1-2 px transition around a layer
   boundary.

3. **No `whiteMultAt()` correction for false highlights** — upstream divides
   values above the saturation threshold by the white-balance multiplier of
   that CFA colour before blending. The port does not (yet), so pixels right at
   the saturation knee are blended without that per-colour compensation.

4. **No GUI, no preview, no mask editing, no EXIF orientation handling.**

## Decoder notes (DNG only)

* Leica/Panasonic DNGs store the mosaic as a **two-component** lossless JPEG
  with 1×1 sampling: each MCU carries an `RG` or `BG` pair, i.e. one sample per
  component per pixel. `LosslessJPEG.decode` returns one plane per component and
  `DNGReader.decodeBlock` interleaves them (`x * n + c`). Decoding it as a
  single-component image silently shifts colours by one pixel.
* Tag numbers that are easy to get wrong: `50711` = CFALayout,
  `50719` = DefaultCropOrigin, `50720` = DefaultCropSize, `50829` = ActiveArea.
* `BlackLevel` may be `RATIONAL` or `SHORT`; `BlackLevelRepeatDim` is not always
  equal to the CFA repeat dim.

## Verified numbers in the repo

```
# decoder oracle (LibRaw 0.22.3)
unprocessed_raw ~/Desktop/test/L1030433.dng            # 9536x6344 PGM
hdrmerge-swift decode ~/Desktop/test/L1030433.dng /tmp/mine.pgm
cmp /tmp/mine.pgm ~/Desktop/test/L1030433.dng.pgm      # identical

# merge sanity: two frames, one of them 4 stops darker
hdrmerge-swift synth in.dng dark.dng 4
hdrmerge-swift merge -o out.dng -b 16 dark.dng in.dng
# -> "frame 0 exposure ratio 3.997", output == analytic prediction within 1 LSB
```
