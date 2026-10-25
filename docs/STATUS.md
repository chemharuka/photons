# Status

> Checkpoint file. A new session should be able to read this plus
> `docs/architecture-decisions.md` and start working. Keep it under ~80 lines.
> Updated: 2026-10-25 · session `s-20261025-2119-ca2c` (M2)

## Milestones · all **DONE (green)**

`make verify` → build + **40 tests** (23 core + 17 catalog) + L1/L2 decode + L3 graph +
**M2 catalog acceptance (12 checks)** + bench.

| Milestone | Pinned by measurement |
|---|---|
| **M0** decode | L1 determinism `7a568ad2…`; 6 decoder versions stable, each distinct; `max linear = 1.019`; ~0.5 s @60 MP ≈ 100 Mpx/s |
| **M1** editing graph | neutral document == decode + sRGB OETF (max error < 0.002); JPEG sha `f7374388…`; S3-only change skips S0/S1/S2; p95 **4.9–5.9 ms** @4.10 Mpx (budget 16.7); S0→S4 @2380×1584 + JPEG ≈ 7 ms |
| **M2** catalog | 1000 files → `added=900 duplicate=100`, 3.8 s ≈ 260 files/s; re-import `added=0 unchanged=900`; `kill -9` at 300 → resume to 900, **0 duplicate hashes**, `verify` CLEAN; move → `moved=5` with edits kept; root renamed → `offline`, 900 rows intact; `user_version=999` refused; queries 6.8/6.6/5.8 ms @900 rows and 6.7/8.0/7.5 ms @10k; real DNG → `camera_key=leica camera ag\|leica sl3`, `xmp_blob=21,573 B` (135 `crs:*` raw, not parsed), **no `.xmp` written** |

M2 schema (user decision A): wide `assets` + 1:1 `asset_metadata` for cold columns; keywords and albums
normalised (real many-to-many); camera/lens are **text columns** + `camera_key` index.
Single third-party dependency: **GRDB 7.11.1** (MIT), verified as 1 pin in `Package.resolved`.

## Facts pinned by measurement (do not re-derive)

- `CIRAWFilter` here: **941** models; the Leica SL3 DNG offers `6.dng,7,7.dng,8,8.dng,9.dng`; Apple
  defaults to **v8**. v9 is **ML denoise** (`deBayer_v7/v7_8bit/v8` only; CoreML is `denoisedPixel`,
  inputs `image0 + noise0`) and costs 8–10× (60 MP: 5.05 s vs 0.50 s, 69 bodies).
- RAW is **read-only** through the system stack; DNG export would need our own writer.
- `CGColorSpace(name:)` needs the CFString constant, not a friendly name (silently nil otherwise).
- SwiftPM has no usable `.metal` build step: kernels ship as **copied resources**, compiled with
  `MTLLibrary(source:)` on first use (~0.2 s/process, never inside a frame).
- rgba16Float round trip via `getBytes` is exact; the only lossy step is the half store between
  stages, bounded at < 0.002 display units by the identity test.
- **XMP comes only from `CGImageMetadata`** (`CGImageSourceCopyMetadataAtIndex` +
  `CGImageMetadataCopyTagWithPath`). `kCGImagePropertyXMPDictionary` does not exist, `{XMP}` is nil
  even for a DNG carrying a 15,478-byte packet, and enumerating tags returns child-tag *descriptions*
  for arrays (that is how keywords get named `<CGImageMetadataTag 0x…>`). Details: §2 correction C.

## Next — M3: UI skeleton

规格尚未写（网格 + 单图 + 胶片条 + 左右栏，搭在 M1 的渲染图与 M2 的库上；**不要**新增第二套渲染路径，D12）。
`docs/tasks/003-catalog.md` 里有 M2 的实测结果与 6 条偏差说明；`develop_json` 是 `EditModel` 的 blob，
加字段时 bump `schemaVersion` 并给显式默认值。

M3 开工前必须先做这四条解码侧前置（`architecture-decisions.md` §11，别跳过）：

1. **D2' 能力集**：默认全 v8；`EditModel` 增加 `decoderCapabilities`。v9 导出档门控 `ISO ≥ ~800` 且机身 ∈
   69 台白名单；启用时 CNR/细节/摩尔纹置灰。**赋值后必须回读 `decoderVersion` 断言**（非白名单会静默退回 v8）。
2. **解码显式置线性**：`boostAmount = 0` + `isGamutMappingEnabled = false`，否则曝光不是严格 ×2。
3. **缩略图走 `previewImage`**：内嵌全尺寸 JPEG（CR3 8192×5464），比真解码快约 4×。
4. **别拿 DNG 标定原生管线**：DNG 能到的版本是 `9.dng`，比 `9` 约 25% 更噪。

## Deferred (do not start)

Local masks (M4), HDR merge + super-resolution (**impossible**: no mosaic access), DNG export,
print/slideshow/map/video, sharpening/NR (they belong on `CIRAWFilter`), FTS search, directory
watching, Lightroom migration (user decision: embedded XMP only, never sidecars).

## How to run

```
make verify                      # the gate: build + tests + L1/L2 + L3 + M2 catalog + bench
make catalog | catalog-perf      # M2 acceptance (fast) | + 10k-row query timing
make render | bench              # one edited JPEG + stage trace | frame budget only
photonsctl library stats <pkg>   # M2 has no UI: library create/import/rescan/assets/stats/verify
PHOTONS_TEST_RAW=/path/to.dng swift test
```

## Pointers

- decisions + evidence: `docs/architecture-decisions.md` (§10 = what M1 pinned down)
- M2 spec + measured result: `docs/tasks/003-catalog.md` · M1: `docs/tasks/002-editing-graph.md`
- how to work here (tools, worker, worktrees, env traps): `docs/collaboration.md`
- research corpus index (gitignored material): `local/research/INDEX.md`
- cross-session state: `~/.hermes/bus/photons-0985eb/` (skill `photons-session-bus`)
