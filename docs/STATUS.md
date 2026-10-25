# Status

> Checkpoint file. A new session should be able to read this plus
> `docs/architecture-decisions.md` and start working. Keep it under ~80 lines.
> Updated: 2026-10-25 深夜 · M3 done, M3.5/M4 部分落地 · 离线连续作业中（见 `docs/tasks/QUEUE.md`）

## Milestones

`make verify` → build + **179 tests** (Core 139 + Catalog 34 + UI 16 量级) + L1/L2 decode + L3 graph +
**M2 catalog acceptance (12 checks)** + bench。Separate: `make app`, `make ui-smoke`, `make ui-bench`。

| Milestone | Pinned by measurement |
|---|---|
| **M0** decode | L1 determinism `7a568ad2…`; 6 versions stable, each distinct; `max linear` 取决于解码设置：默认 1.018 / D2′ 1.695（§11.8）; ~0.5 s @60 MP ≈ 100 Mpx/s |
| **M1** editing graph | neutral == decode + sRGB OETF (max error < 0.002); S3-only change skips S0/S1/S2; p95 **4.7–6.4 ms** @4.10 Mpx (budget 16.7) |
| **M2** catalog | 1000 files → `added=900 duplicate=100` 3.8 s; `kill -9`@300 → resume 900, 0 dupes; move/offline/user_version 守卫全过；真 DNG → `camera_key=leica camera ag\|leica sl3`, `xmp_blob=21,573 B`, 不写 sidecar |
| **M3** UI skeleton | `make ui-smoke` 18 checks: 1001 行库→1001 item；1200/1600/2400→3/6/11 列且与纯布局函数一致；loupe 走 `RenderGraph`（3712×1808，首帧 526–744 ms 含 0.5 缩放解码，二次 2–3 ms）；10k 占位网格 p99 **1.87 ms**（占位图，不含解码） |
| **M3.5** thumbnails | P 通路 = **ImageIO 内嵌预览**（比 `CIRAWFilter.previewImage` 快 2.6×，§11.2）。19 张真实 RAW：t256 冷 p50 62.1/p95 111.5 ms、t512 63.3/119.1、t1024 48.6/74.1；热 p50 1.2 ms、p95 1.3 ms、命中 1.000；DNG preview 上限 t512。服务层/预取/G 通路在跑 |
| **M4** masks（进行中） | 005a/005b/005c 已落地：蒙版第一类值 + S1.5 atlas + S1.6 local；**空 masks 时 7 个旧键逐字节不变**（display `f0ac628a…`），neutral golden `93eeddc8…` 复现；`amount=0` 位等价（`abba6229…` = 无蒙版帧）；画笔（距离场/硬度/流量）、颜色范围（OKLab）、亮度范围已可用。005d（feather/refine/tile）在跑 |

## 已落地但尚未进里程碑表的部件

- **历史**：`EditHistory` 快照栈 + cursor + 深度上限 + `dirtyGroups`（组级脏标记，浮点 1e-6、masks 1e-5）。`c50d2a7`
- **XMP 导出**：`EditModel → crs:* + photons:*`，sidecar 与容器内写（JPEG/HEIC/TIFF 走 CopyImageSource 不重编码，PNG 解码重写，RAW 降级 sidecar）；不可映射项落 `photons:settings` 可无损带回。20 项往返。`5e6993b`
- **几何**：`CropMath`（cropRect 的 left/top/right/bottom 是**绝对边界**，同 XMP）+ 拉直 ±45 + 翻转；crop=full 时 neutral hash 不变。`a7368ec`
- **缩略图**：`ThumbnailCache`（内容寻址 `thumb|v1|hash|tier|pipeline|recipe`、原子写、LRU、DNG 上限）+ 镜头校正逐文件探测（探测后**必须复位**，否则改像素）。

## 解码/图像链路的硬事实（新增）

- `boostAmount=0` + `isGamutMappingEnabled=false` 是**双用途前置**：曝光严格 ×2（实测 2.0083/2.0091/2.0098）**且**保住 EDR 余量。`extendedDynamicRangeAmount` 不是杠杆。
- 非白名单机身设 v9 会**静默退回 v8** → 赋值后必须回读；`DecodeCacheKey.decodeRecipe = v1-boost0-gamutOff`。
- 缩略图"走 previewImage"要落到 **ImageIO**（`CGImageSourceCreateThumbnailAtIndex`），`CIRAWFilter` 每次构造 ~0.19 s。
- macOS 27 的 ImageIO **已内置 `crs` 前缀映射**（未注册也能写）；HEIC 的 `tiff:Orientation` 读回恒为 1（用 `irot` 承载）。

## 下一步（并行队列见 `docs/tasks/QUEUE.md`）

1. UI 接真数据：网格出真缩略图、检查器滑杆驱动重渲（防抖+单飞）、⌘Z/⇧⌘Z 接 `EditHistory`（在跑）。
2. 蒙版 005d（feather/refine/tile）→ 005e（语义蒙版 + showMask）。
3. 缩略图服务层（优先级队列/合并/取消/G 通路）。
4. 之后：1:1 交互、EDR 画面侧（只改一个布尔 + headroom 取值）、方向（EXIF orientation）映射、M5（预设/复制粘贴设置/批量导出）。

## Deferred (do not start)

HDR merge + super-resolution (**impossible**: no mosaic access), DNG export, print/slideshow/map/video,
自研 demosaic/降噪, FTS search, directory watching, Lightroom 迁库（用户定：只读内嵌 XMP，不写 sidecar）。

## How to run

```
make verify                      # the gate: build + tests + L1/L2 + L3 + M2 catalog + bench
make app | make ui-smoke | make ui-bench
make catalog | catalog-perf      # M2 acceptance (fast) | + 10k-row query timing
photonsctl library stats <pkg>   # create/import/rescan/assets/stats/verify
photonsctl thumbs <pkg> --out D --tier t512 [--reset] [--json]
photonsctl xmp export <pkg> --out D [--ids …|--rating N] [--embed] [--json]
PHOTONS_TEST_RAW=/path/to.dng swift test
```

## Pointers

- decisions + evidence: `docs/architecture-decisions.md`（§11 = 解码/EDR/镜头/XMP 的实测结论）
- specs: `docs/tasks/004-ui-skeleton.md`（M3）、`005-masks.md`（M4）、`006-thumbnails.md`（M3.5）、`xmp-mapping.md`
- 连续作业队列与文件所有权：`docs/tasks/QUEUE.md`
- research corpus (gitignored): `local/research/INDEX.md` · cross-session state: `~/.hermes/bus/photons-0985eb/`
