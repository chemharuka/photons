# Status

> Checkpoint file. A new session should be able to read this plus
> `docs/architecture-decisions.md` and start working. Keep it under ~80 lines.
> Updated: 2026-10-26 06:55 · M3/M3.5 done，M4 核心 done（无 UI），M2 迁到 v3 · 离线连续作业中（多路并行，按依赖排序派发）

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
| **M4** masks（核心 + UI 的画笔） | 005a/005b/005c 已落地：蒙版第一类值 + S1.5 atlas + S1.6 local；**空 masks 时 7 个旧键逐字节不变**（display `f0ac628a…`），neutral golden `93eeddc8…` 复现；`amount=0` 位等价（`abba6229…` = 无蒙版帧）；画笔（距离场/硬度/流量）、颜色范围（OKLab）、亮度范围已可用。005d/005e 也已完成：feather+refine 3 蒙版 @4.1Mpx p95 **16.6 ms**、tile 增量 == 全幅逐像素；语义蒙版本机只 subject 可用（Vision），其余 kind 0 覆盖；`showMask` 叠加 +0.4 ms。**UI 已接画笔**（画/擦/浏览、蒙版列表、showMask 开关、大小/硬度/流量）；其余形状无 UI 入口 |

## 已落地但尚未进里程碑表的部件

- **历史**：`EditHistory` 快照栈 + cursor + 深度上限 + `dirtyGroups`（组级脏标记，浮点 1e-6、masks 1e-5）。`c50d2a7`
- **XMP 导出**：`EditModel → crs:* + photons:*`，sidecar 与容器内写（JPEG/HEIC/TIFF 走 CopyImageSource 不重编码，PNG 解码重写，RAW 降级 sidecar）；不可映射项落 `photons:settings` 可无损带回。20 项往返。`5e6993b`
- **几何**：`CropMath`（cropRect 的 left/top/right/bottom 是**绝对边界**，同 XMP）+ 拉直 ±45 + 翻转；crop=full 时 neutral hash 不变。`a7368ec`
- **缩略图**：`ThumbnailCache`（内容寻址 `thumb|v1|hash|tier|pipeline|recipe`、原子写、LRU、DNG 上限）+ 镜头校正逐文件探测（探测后**必须复位**，否则改像素）。

## 2026-10-26 重要更正：解码缓冲曾经整体上下镜像

`CIContext.render(to: MTLTexture)` + `getBytes` 读回是 bottom-up，v1 落盘的线性缓冲**每个文件都上下镜像**；
M3 记的"`L1030433.dng` 少 orientation tag"是误判（tag 存在且为 1）。已修（`flipRows` + `ImageOrientation`），
`DecodeRecipe` → `v2-topdown-rows`，4 个像素 golden 重录。详见 §11.9。

## 解码/图像链路的硬事实（新增）

- `boostAmount=0` + `isGamutMappingEnabled=false` 是**双用途前置**：曝光严格 ×2（实测 2.0083/2.0091/2.0098）**且**保住 EDR 余量。`extendedDynamicRangeAmount` 不是杠杆。
- 非白名单机身设 v9 会**静默退回 v8** → 赋值后必须回读；`DecodeCacheKey.decodeRecipe = v1-boost0-gamutOff`。
- 缩略图"走 previewImage"要落到 **ImageIO**（`CGImageSourceCreateThumbnailAtIndex`），`CIRAWFilter` 每次构造 ~0.19 s。
- macOS 27 的 ImageIO **已内置 `crs` 前缀映射**（未注册也能写）；HEIC 的 `tiff:Orientation` 读回恒为 1（用 `irot` 承载）。
- **色温/色调 = 解码参数，不是 S1 增益**（派单 006）：`light.temperature/tint` 为 `Double?`，`nil` = as shot；非 nil 时喂 `CIRAWFilter.neutralTemperature/neutralTint` 并**回读断言**，S1 增益退化为 (1,1,1)。as-shot 实测：SL3 `5871.64 K / +20.35`、DC-S5 `4803.59 K / +19.97`；**把读到的 as-shot 值再赋回去不是恒等**（0.15 %/0.40 % 样本移动），所以默认路径必须完全不碰 filter —— 这也是默认像素逐字节不变的原因。量化 25 K / 1 tint，松手才提交。

## 已落地（本轮）

- **M2 迁移 v3**：`edit_history` 表 + `develop_json`/`edit_time` 真正落库；损坏 blob 进 `develop_quarantine`（原字节保留）；
  `photonsctl library develop get|set|history`；1000 资产读 p50 0.117 ms。`9e39800`
- **outputWindow**：1:1 取景不再用 crop 模拟，暗角/feather 回整帧归一化；与整帧裁切**逐像素一致**，`nil` 时 7 键不变。`9c962d5`
- **方向**：8 值 `ImageOrientation` + 解码/预览同结论；方向进 geoKey 不进 EditModel。

## M5 已落地部分

- **预设与复制粘贴**：`Preset`（6 组、应用只覆盖子集，不抹其它组）/ `EditSnapshot` 稀疏快照（全量 57 叶，改 9 处 → 22 叶）；
  Catalog 迁移 **v4**（`presets` 表 + name NOCASE 唯一 + 单默认约束，未 ALTER 既有表，迁移前快照实测 `library.bak-v3.db`）。
- **批量导出**：`ExportPreset`（jpeg/heic/tiff/png/avif、长边不放大、质量、sRGB/P3、XMP、命名模板）+ `BatchExporter`
  （并发 2，实测 1.7×；逐张 outcome，失败隔离；同名 `-1/-2` 不覆盖）。20×60MP → 6000×3993：总 **19.36 s**、每张 p50 **1.91 s**。
  峰值 RSS 5.0 GB；**debug 构建不能用于性能**（同批 60 s/张）。
- **UI**：导出弹窗与开发预设面板正在做（第 8 轮）。

## 第 9 轮（UI 收口 + 性能）

- **decode ladder**：进 1:1 的首帧 **1231 → 52 ms**（fit 已建 0.5 graph 时 4.9 ms），全分辨率就绪 860 ms，
  平移 3.95–5.5 ms，切回 fit **0 次解码**；fit↔1:1 的解码次数从 4 降到 2。解码本身 1032 → **762 ms**（−26%），
  原因是把尾部 `[UInt16]` 暂存 + `map{Float16(bitPattern:)}` + 逐元素 flip（344–451 ms）换成直读 Float16 + 按字翻转（83 ms）。
  已实测否决“只栅格化窗口”（平移每个新窗口 p50 35 ms，超预算 6–13×）。
- **UI**：直方图卡片（四组 + 削顶，点数字切高光警告）、六种蒙版可建（线性/径向可拖拽）、loupe 倍率菜单
  （适应/1:1/2:1/4:1/8:1 + ⌘0/⌘=/⌘−）。`ui-smoke` 87 → **108 项**。
- 已知：0.5 阶段平移被全解码串行挡住（画面冻结 ~800 ms，不出错），真并发需第二条队列。

## 第 10 轮

- **蒙版参数面板**（`387a897`）：蒙版级 opacity/feather/refine/invert/混合 + 15 个局部调整滑杆 + 改名/排序；
  拖动只重渲、松手才提交。实测 feather 0→0.4 单像素最大跳变 0.2881→**0.0237**、invert 覆盖 0.1868→**0.8131**（互为补集）、
  opacity 减半时**面积不动**、0 EV 与无蒙版帧**位精确相等**。`ui-smoke` 108 → **119**。
- **解码/渲染拆两条队列**（`760e2ce`）：`DecodeQueue` 专用解码串行队列（同键去重、generation 回传、可取消）；
  渲染只用已驻留 rung。全解码期间 20 帧平移从 **5816 ms 串联 → render p50 4.0–4.5 ms / 20-20 ≤ 8 ms**；
  1:1 首帧 24–26 ms（基线 52）；fit↔1:1 仍只解码 2 次。墙钟断言改为可数断言（解码次数/rungArrivals/viewRenderCount）。

## 第 11 轮 · 080 原图 / 前后对比（`\` / Y / ⇧Y）

- **「显示原图」是解码，不是参数清零后的渲染**。`RenderOptions.source = .decoded` 让 `RenderGraph` 走
  `S0（identity 几何）→ S4`：S0 仍做 decoded(sRGB)→working(Rec.2020) 的出口矩阵，所以这一帧就是
  `OETF(M_working→out · M_decoded→working · decode)`，没有第二个渲染路径。
  - 合成图（200×150，渐变 + 硬边 + 超白）：原图 `6329e95c…`、参数清零 `5e7c5480…`，**maxΔ 254.88 码**（画框都不同）；
  - 与 CPU 参考（解码 + 两条基色矩阵 + sRGB OETF + clamp）逐码 **maxΔ 0.274 码**（90 000 个通道，阈值 1 码）；
  - **诚实的边界**：文档没有几何改动时，解码与 neutral 渲染本来就是同一张图（实测 **maxΔ 0.000 码**，
    管线在 neutral 处逐级恒等）。所以「两种做法像素不同」只有带裁剪/拉直/翻转的文档才可证；测试把两个事实都印出来了。
  - 真实 RAW（L1030433，1280×800 fit）：同一次运行内原图 / 编辑后 / 参数清零是**三个不同 SHA**（测试打印三者；
    绝对值随面板 headroom 变，所以这里不写死，只钉「互不相同」）。
- **前后对比**：`CompareSplit`（axis + fraction，除数是画布像素数）→ `s5_before_after`（读两帧已编码的 S4 输出、写一帧；
  分界线 2 px、0.5 码、`CompareSide.divider` 不属于任何一侧）。1280×800、50 % 时分界线在列 **640**：
  十个采样点的归属与 `CompareSplit.side(x:y:)` 逐一相符（左右各 5 点，含 letterbox 的 0 像素）；⇧Y 换成上下（行 400）。
- **不写文档、不产生历史、不停渲染**：拖动分界线 50 %→30 %（列 640→**384**）并进出模式，`documentHash` 不变、
  `history.count` 不变、`RAWDecoder.decodeCounts()` 预热后 **2 → 2**；退出（原图 / 对比 / 拖过分界线）后重渲的帧 SHA
  与进入前**逐位相同**——同一次运行内比较，三个模式退出后都是同一个值。
- **代价**：原图帧 2 个 pass（S0/S4），对比帧 两帧 + 1 个合成 pass；都不新增解码。
- **菜单**：显示 ▸ 显示原图（`\`）/ 前后对比（Y，标题带「左右 50 %」）/ 对比方向（⇧Y）；勾选与标题由
  `validateMenuItem` 按 `LoupeFrameMode` 给，`\` 与 Y 都是无修饰键（与 星级 一行同样的约定）。
- **反证**：`RenderOptions.originalRendersAsParametersCleared`（仅测试）把 `\` 换成「参数清零后走整条管线」→
  与原图**同字节**（`5e7c5480…`，maxΔ 0.000），于是「两者不同」这条断言必红。
- **套件**：`BeforeAfterTests`（7）、`BeforeAfterUITests`（6）、`RenderTests`（19）、`LoupeRenderTests`（6）、
  `LayoutContractTests`（12）全绿。

## 已知待修（下一轮）

1. ~~直方图窗口帧 +104 ms~~ → **已修并更正**（`b55e4de`）：104 ms 只存在于 **debug** 构建（`-Onone` 下 CPU binning 94 ms），
   release 稳态是 **+8.2 ms**。修法是“手势中不采集 + 停手 60 ms 后一次测量专用帧 + kernel 进程级共享”，
   平移额外成本降到 **−0.5 ms**（off p50 5.69 → on 5.21），补采 11.3 ms、卡片滞后 71 ms。
2. 蒙版面板改名会产生 1 条历史（`masks` 按值比较含名字），像素与 `selectionKey` 都不变——语义可选，待定。
3. `LocalAdjustments` 没有 sharpen 字段，面板只露出 amount 作“强度”。

## 下一步（按依赖排序，可并行派发）

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
- specs: `docs/xmp-mapping.md`（XMP 映射，入库）；M3/M4/M3.5 的规格只留在本机、不入库，结论已写进本文件与 `architecture-decisions.md`
- 连续作业的文件所有权规则：一个工作流一组文件所有者，同一时刻同一文件只有一个所有者；队列不入库
- research corpus (gitignored): `local/research/INDEX.md` · cross-session state: `~/.hermes/bus/photons-0985eb/`
