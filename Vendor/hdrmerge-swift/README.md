# hdrmerge-swift

A Swift port of [HDRMerge](https://github.com/jcelaya/hdrmerge): merge a set of
RAW exposures into **one Bayer (CFA) DNG** — the output stays a mosaic, it is
never demosaiced.

```
hdrmerge-swift merge -o out.dng a.dng b.dng c.dng
hdrmerge-swift inspect out.dng
```

License: **GPL-3.0-or-later** (see `LICENSE`). HDRMerge is © 2012 Javier Celaya;
this port keeps the same license and the same algorithm structure.

仓库：<https://github.com/chemharuka/hdrmerge-swift>

## Status

| Piece | State |
|---|---|
| DNG / TIFF reader (CFA plane, tags, strips + tiles) | works |
| Lossless JPEG (Compression = 7, 1…4 components, 1×1 sampling) | works |
| Uncompressed (Compression = 1) | works |
| **SOF3 write (Compression = 7)** | works — 121 MB → 49.9 MB on 60 MP, bit-exact |
| Deflate (Compression = 8), JPEG XL, BigTIFF, CR3/NEF/ARW/RAF | not yet |
| Ward MTB alignment (6-level pyramid) | works |
| Exposure-ratio estimation, saturation mask, feather + compose | works |
| CFA DNG writer (16-bit integer, 32-bit float) | works |
| Qt GUI, mask editing, preview | no (out of scope for now) |

## Verification (this machine, 2026-11-11)

* **Decoder bit-exactness** — `L1030433.dng` (Leica SL3, 9536 × 6344, LJPEG
  stored as two interleaved components) decoded by this tool compares
  **byte-identical** to LibRaw 0.22.3's `unprocessed_raw` output (120,992,787 B
  PGM, `cmp` clean).
* **Merge** — a synthetic 4-stop bracket built from `P4270052.dng` (YI M1,
  5200 × 3902) recovers the exposure ratio as **4.000** and reproduces the
  analytic prediction to **≤ 1 LSB** (mean |Δ| 0.25, max 0) over 2.25 M samples.
* **Alignment** — a synthetic 6 px / 4 px shift is recovered, the canvas is
  cropped to 5194 × 3898, and the merged mosaic still matches the analytic
  prediction to ≤ 1 LSB.
* **Crop geometry** — a Leica SL3 DNG stores 9536 × 6344 and asks for a
  9520 × 6336 picture at (4,4); the 12 surplus columns carry sensor dummy data.
  A single-frame merge with `--headroom 4` now reproduces exactly that crop
  rectangle — **60,318,720 / 60,318,720 samples bit-identical** to
  `(sample − black) × mult + black` — with no margin pixel in the output, and
  the written DNG declares `DefaultCropSize = 9520 × 6336` at (0,0).
* **CFA generality** — nothing is pinned to 2×2 or to three colours: `CFA.rotate`
  works for any `CFARepeatPatternDim` (a 6×6 pattern is covered by a test), a
  four-plane `CFAPlaneColor` survives the merge and the write instead of being
  flattened to RGB, and a staggered `CFALayout` is refused at read time rather
  than merged as if it were rectangular. An audit of all 499 DNGs on this
  machine found every one to be 2×2 / 3-plane, which is exactly why these paths
  are tested synthetically.
* Output opens in LibRaw (`raw-identify`: "YI M1 image") and in ImageIO.

Timings (M-series, release build): decode 60 MP ≈ 2.8 s; merge 20 MP from two
frames ≈ 3.1 s.

## Build

```
swift build -c release
.build/release/hdrmerge-swift --help
```

No third-party dependencies: the RAW path is pure Swift (no LibRaw), so the
binary has no runtime deps beyond the system frameworks.

## 给宿主程序调用（Photons 等）

二进制是**独立进程**，宿主用 `Process` 起它、传路径、读 JSON，不链接任何东西——
许可上就是 GPLv3 与 MIT 的「聚合」，见 `LICENSE-SCOPE.md`。

* 协议规范：`PROTOCOL.md`（`--json` 单对象输出、稳定 `error.code`、`--progress` NDJSON、原子写盘、退出码）
* Photons 侧客户端：`Host/Photons/HDRMergeClient.swift`（**MIT**，直接丢进 PhotonsCore）
* 安装到 Photons 找得到的位置：`./scripts/install-to-photons.sh --in-app`
  （装到 `/opt/homebrew/bin` 用不带参数的那条；Photons 的 `make app` 也会自动把它拷进 bundle）

在 Photons 里就是 **文件 ▸ 合并 HDR DNG…（⇧⌘M）**：选中 2 张以上 DNG → 合并 → 结果以
`<最暗帧名>-merged.dng` 落在源目录 → 自动导入库并选中。工具没装时该菜单项置灰。

```swift
let client = try HDRMergeClient()
guard try client.protocolVersion() == 1 else { throw … }
let result = try client.merge(frameURLs, to: outURL,
                              options: .init(bits: 16, headroom: 4),
                              progress: { print($0) })
// result.width / .height / .offsets / .metadataFrom / .report
```

## Commands

```
capabilities [--json]              protocol version + feature list (host negotiation)
inspect <file.dng>... [--json]     print geometry, CFA pattern, black/white, EXIF exposure
decode  <in.dng> <out.pgm>         16-bit PGM of the raw mosaic (used as a decoder oracle)
merge   -o out.dng [options] ...   merge 1..n frames into one CFA DNG
        -b 16|32                   output bits per sample (default 16 = integer DNG)
        --headroom N               container top = N× input white (16-bit: 4 = bit-exact, +2 stops)
        --metadata-from PATH       take EXIF from this frame instead of the least exposed one
        --json / --progress        host protocol / NDJSON progress on stderr
        --feather N                mask feather radius (default 3)
        --white N                  override the white/saturation level
synth   <in> <out> <divisor> [dx dy]   test aid: fake a shorter exposure, optionally shifted
```

## Deviations from upstream HDRMerge

See `PORTING.md`. Short version: exposure ratio uses least squares instead of
the penalised spline response fit (identical for linear sensor data), and the
mask fattening filter is square rather than a disk. Everything else follows
`Image.cpp` / `ImageStack.cpp` / `DngFloatWriter.cpp` closely, including the
"normalise the brightest pixel to the white level" step in `compose()`.
