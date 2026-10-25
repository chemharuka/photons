# Status

> Checkpoint file. A new session should be able to read this plus
> `docs/architecture-decisions.md` and start working. Keep it under ~80 lines.
> Updated: 2026-10-25 · M3 (UI 骨架) landed · session `s-20261025-2119-ca2c`

## Milestones · all **DONE (green)**

`make verify` → build + **60 tests** (33 core + 17 catalog + 10 UI) + L1/L2 decode + L3 graph +
**M2 catalog acceptance (12 checks)** + bench. Separate: `make app`, `make ui-smoke`.

| Milestone | Pinned by measurement |
|---|---|
| **M0** decode | L1 determinism `7a568ad2…`; 6 decoder versions stable, each distinct; `max linear = 1.019`（默认解码设置，见 §11.8；D2′ 档同文件 1.695）; ~0.5 s @60 MP ≈ 100 Mpx/s |
| **M1** editing graph | neutral document == decode + sRGB OETF (max error < 0.002); JPEG sha `f7374388…`; S3-only change skips S0/S1/S2; p95 **4.9–5.9 ms** @4.10 Mpx (budget 16.7); S0→S4 @2380×1584 + JPEG ≈ 7 ms |
| **M2** catalog | 1000 files → `added=900 duplicate=100`, 3.8 s ≈ 260 files/s; re-import `added=0 unchanged=900`; `kill -9` at 300 → resume to 900, **0 duplicate hashes**, `verify` CLEAN; move → `moved=5` with edits kept; root renamed → `offline`, 900 rows intact; `user_version=999` refused; queries 6.8/6.6/5.8 ms @900 rows and 6.7/8.0/7.5 ms @10k; real DNG → `camera_key=leica camera ag\|leica sl3`, `xmp_blob=21,573 B` (135 `crs:*` raw, not parsed), **no `.xmp` written** |
| **M3** UI skeleton | `make ui-smoke` 18 checks: 1001-row library → grid item count 1001; widths 1200/1600/2400 → 3/6/11 columns, itemSize == pure `GridLayout.metrics`; filmstrip 1001 items @122pt sharing the selection; loupe renders 3712×1808 through `RenderGraph`; **10k placeholder grid scroll p99 1.87 ms** (placeholders only, no decode); loupe first frame **744 ms** (722 ms decode @0.5), second render **2.1 ms** (decode cache hit) |

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

## M3 landed — what it pins down

规格 `docs/tasks/004-ui-skeleton.md`（§2b = Phos 外壳合同，§8 = 实现记录与 7 条偏差）。

- **解码前置 ①② 已落地**：`RAWDecoder` 固定 `boostAmount=0` + `isGamutMappingEnabled=false`；版本请求**赋值后
  回读**，非白名单（本例请求 `9`、机身只给 `9.dng`）读回 `8` → 降级 v8 并上报 `effectiveVersion`；
  `DecoderCapabilities` 声明 v9 下 CNR/细节/摩尔纹不可用。实测曝光 ×1EV：p10/p50/p90 = **2.0083 / 2.0091 / 2.0098**。
- **`DecodeCacheKey.decodeRecipe`** = `v1-boost0-gamutOff`，旧线性缓存自然不命中（键变了，未删用户缓存）。
- **EDR 契约成形**：`DisplayOptions.headroom`（默认 1）进 keyString，S4 的 `clamp(v,0,1)` → `min(v,headroom)`；
  headroom=1 与旧输出逐像素一致（golden 重录后仍 PASS），headroom=4 时 >1 保留（单测）。
  画面侧仍关：`CAMetalLayer` 用 `extendedLinearDisplayP3` + `wantsExtendedDynamicRangeContent=false`。
- **UI 结构**：AppKit 外壳（自绘 36pt 顶栏，无 `NSToolbar`）+ `CatalogSession` 单模型 + `ObservationBridge` +
  SwiftUI 检查器（`@Bindable`）。网格/胶片条 `NSCollectionView` 复用，loupe 走 `RenderGraph` 真渲染。

golden 因解码设置变更**已重录**（3 个基线，见 004 §8）。

## Next — M3.5: thumbnails + 1:1

1. 缩略图走 `previewImage`（内嵌全尺寸 JPEG，比真解码快约 4×），替换网格占位块，并用 10k 行重测同一 p99。
2. loupe 1:1：`LoupeCanvasView.zoomToActualSize()` 已留空接口；按倍率重渲（D12），不缩放图层。
3. EDR 画面侧：只改 `wantsExtendedDynamicRangeContent` + `DisplayOptions.headroom` 取值。
4. SwiftUI 检查器接真渲染前**先实测主线程占用**（redlamp: SwiftUI 100% vs AppKit 34%）。
5. 已知未做：方向（EXIF orientation）映射；`L1030433.dng` 渲染结果 180°（文件无 orientation tag）。

## Deferred (do not start)

Local masks (M4), HDR merge + super-resolution (**impossible**: no mosaic access), DNG export,
print/slideshow/map/video, sharpening/NR (they belong on `CIRAWFilter`), FTS search, directory
watching, Lightroom migration (user decision: embedded XMP only, never sidecars).

## How to run

```
make verify                      # the gate: build + tests + L1/L2 + L3 + M2 catalog + bench
make app                         # .build/Photons.app (Info.plist + ad-hoc signed)
make ui-smoke                    # 1000-row library, layout/count/loupe asserts, local/out/ui-smoke-*.png
make ui-bench                    # 10k-row placeholder scroll p99 + loupe frame timings
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
