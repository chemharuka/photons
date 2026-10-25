# 006 — M3.5：缩略图（previewImage 快速通路 + RenderGraph 精修通路）

> 定稿 2026-10-25。前置：M0 `2616e3a`、M1 `7f7d1cf`、M2 `1603ee2`、**M3（004）落地**（`Sources/PhotonsApp` 现在还不存在，006d 直接依赖它）。
> 依据：`docs/architecture-decisions.md` §11.2（previewImage 是内嵌全尺寸 JPEG）、§11.8（EDR 由解码开关决定）、D12（同一渲染器 + scale）；`docs/tasks/003-catalog.md`（`assets.content_hash`、`previews/`、`~/Library/Caches/Photons/<libHash>/`）；`docs/tasks/004-ui-skeleton.md`（网格/胶片条接口与 bench 口径）。
> 判据一句话：**`make thumbs` 打印的四组数字全部在阈值内，且 `make verify` 全绿。**
> 本规格只新建本文件，不改源码；但 006 落地时新增的目标是 `PhotonsThumbs`（依赖 `PhotonsCore` + `PhotonsCatalog`）。

## 0. 两条通路，一条渲染器

| 通路 | 数据来源 | 成本 | 用途 | 可信度 |
|---|---|---|---|---|
| **P（preview 快速通路）** | 文件内嵌预览 JPEG（ImageIO `CGImageSourceCreateThumbnailAtIndex`，`CreateThumbnailIfAbsent=false`） | 目标是 ≤ 25 ms/张 | 网格/胶片条的**占位与首帧** | 相机（或 DNG Converter）自己锐化/降噪/曲线的产物，**不是编辑基线** |
| **G（精修通路）** | `CIRAWFilter`（v8 + `boost=0` + gamut off）→ `RenderGraph(scale:tier)` | 0.3–0.5 s/张（`scale 0.125` 仍有 0.2 s 固定开销，§1 实测表） | 编辑过的、或档位超过内嵌预览尺寸的缩略图 | 与 loupe/导出**同一函数**（D12） |

- 已实测（2026-10-25，19 个真实 RAW）：同一份内嵌 JPEG，**ImageIO 直取比 `CIRAWFilter.previewImage` 快 2.6×**（t256 冷 p50 62.1 ms vs 153 ms；t512 63.3 vs 162；t1024 48.6 vs 160），因为 `CIRAWFilter` 每次构造约 0.19 s。→ **P 通路定为 ImageIO 优先**，`CIRAWFilter.previewImage` 只作"ImageIO 无内嵌预览"时的回退；接口不变（`PreviewOutcome.source` 标注实际来源）。
- 25 ms/张的目标在大容器 RAW 上**不可达**（CR3 单张扫描 ~80 ms，ARW/DNG ~17 ms，与 `maxPixelSize` 无关）：现基线 = 冷 p50 62 ms / p95 112 ms，热 p50 1.2 ms / p95 1.3 ms（t512）。
- P 通路**只做占位**：它带着相机自己的锐化与曲线，且同一文件在默认解码设置下 EDR 余量被削 40%（§11.8）。因此：**网格不显示直方图/高光剪切警告，任何色调判断只允许在 loupe 做**。
- 两条通路产出同一个键空间的不同 `pipeline` 值；解析顺序 = `graph` → `preview` → 现生成。G 落地后**立刻删掉同档 P 文件**，保证"占位→精修"只发生一次、不来回抖。

## 1. 尺寸阶梯与设备像素比

| 档 | 长边 px | 谁请求 | 说明 |
|---|---|---|---|
| `t256` | 256 | 网格（cell ≤ 200 pt） | 导入期唯一预生成的档 |
| `t512` | 512 | 网格大 cell、胶片条（1x/2x 常见） | 首屏主力 |
| `t1024` | 1024 | 胶片条 @2x、loupe 小窗 fit | P 通路的实际天花板（ARW 1616 / RW2 1920） |
| `t2048` | 2048 | 全屏 fit @1x、5K 半屏 | P 占位的最高档（再往上收益不值体积） |
| `t4096` | 4096 | 全屏 fit @2x（6K XDR：3384 pt→3384 px×2） | **只允许 G 通路** |

- 选档：`px = ceil(longEdgePt × window.backingScaleFactor)`，档 = 阶梯中 **≥ px 的最小档**，上限 `t4096`。不做 1.5×/2.5× 之类的插值档——档位是缓存键的一部分，多一档就多一份磁盘与一份失效面。
- **禁止放大**：`tier > sourceLongEdge` 时 P 通路不可用，必须走 G。实测内嵌预览尺寸 CR3 8192×5464 / RAF 4416×2944 / ARW **1616×1080** / RW2 1920×1280 → ARW 与 RW2 的占位只到 `t1024`，6K 全屏必须渲染。把 1616 拉到 2048 是"看起来有细节"的假象，验收里有专门断言。
- 1:1 **不是缩略图**：`t4096` 之上走解码缓存（`LinearImageStore`，按 `DecodeCacheKey`），不进本缓存，避免两套"全尺寸副本"。
- 颜色：一律 8-bit sRGB JPEG（q=0.82）。内嵌预览可能是 AdobeRGB，**必须读其 ICC 并 ColorSync 转到 sRGB**，否则网格整体偏色；`CGImageSourceCreateThumbnailWithTransform=true` 处理 EXIF 方向，我们自己不再转一次。网格不需要 P3/EDR，也就不需要 16-bit。
- 内存只用 32 MB 的 LRU 存**当前窗口 ±1 行**的已解码 `CGImage`；主线程只做 `layer.contents = cgImage`，文件读取与 JPEG 解码全在 job queue。

## 2. 生成时机：导入期只做 `t256`，其余惰性

M2 实测导入 260 文件/s（1000 个 3.8 s）。即使 P 通路 25 ms/张，串行内联也会把吞吐打到 ~40/s；**缩略图是纯派生物，不能进导入事务**（darktable 的教训：缓存进事务 = 崩溃后面临"库说有、盘上没有"）。

| 时机 | 做什么 | 约束 |
|---|---|---|
| 导入期（M2 `import_files` 状态机） | 单文件事务 **COMMIT 之后**投递一个 `t256` 生成任务；`outcome ∈ {added, moved}` 才投递（`duplicate/unchanged` 已有缓存，命中即可） | 不阻塞、不参与事务；会话 `finished` 的判据仍是"行已提交"，另报 `thumbsPending` 计数 |
| 首次显示 | `tier > t256` 或 `t256` 缺失 → 立即返回 P 占位（若有），同时投 G | 先上屏再精修，格子不空 |
| 编辑提交后 | 见 §4 | 惰性优先：不在可见范围就不排队 |
| 恢复在线 | 离线根转 online 时，只对**当前筛选结果内可见项**补生成，其余等滚动 | 优先级最低 |

**失败与超时**
- P 失败（无内嵌预览/损坏/ImageIO 返回 nil）→ 记 `(contentHash, "preview", reason)`，直接退 G；G 也失败 → 格子画 kind 图标 + 文件名，**不重试超过 5 次**，退避 1 min / 10 min / 1 h / 1 d。
- 单张 G 超时 **3 s**（60 MP 冷启 v8 ≈ 1 s，留 3× 余量）→ 丢弃结果、不写缓存、释放 job；同一 `(contentHash,tier)` 连续 2 次超时则该档降级为"只用 P"。
- 每批预算：连续 20 张 G 若累计 > 10 s 就让出队列 200 ms，避免长时间占满 3 个并发槽把 loupe 挤掉。
- 失败状态**只存内存**（进程内字典），不落库：库是真相，缓存是派生，重启后重试一次是正确行为。

**离线根**：`status=offline` 时缓存**照常命中**（这正是离线仍能浏览的依据）；缺失则画"不可用"占位，**绝不**因此软删资产、绝不把 `develop_json` 清空（M2 §4.5）。

## 3. 缓存布局：内容寻址文件，不是 SQLite BLOB

**决策：文件**，落在 `~/Library/Caches/Photons/<sha1(库包绝对路径)>/thumbs/`，**不**放库包内 `previews/`。

理由（按权重排序）：
1. **库包必须可搬、可备份**。10k 张 × 5 档 × ~120 KB ≈ 6 GB；塞进 `<Name>.photonslibrary/` 会让"拷一个 item 就搬家"变成拷 6 GB，也会让 M2 的迁移前 `library.bak-v<n>.db` 快照（整库复制）从 20 MB 涨到 GB 级。
2. **BLOB 的 delete 不等于回收**：SQLite 删除只进 freelist，空间不还给文件系统，`VACUUM` 要独占锁；而缩略图天然是 LRU 抖动最频繁的数据。
3. 文件系统直接给到我们要的三件事：原子 `rename`、按 `mtime` 的 LRU、`lstat` 判存在（一次 syscall，不需要索引表）。
4. 反向代价只有一条——库搬到另一台机器要重建缩略图（10k 约 2 min 后台）。接受。

```
~/Library/Caches/Photons/<libHash>/thumbs/
  <k0..1>/<k2..3>/<key>.jpg        # 8-bit sRGB, q0.82, 无 EXIF/GPS
```
- `key = sha256("thumb|v1|<contentHash>|<tier>|<pipeline>|<recipeDigest>")`，`pipeline ∈ {preview, graph}`。
  - 用 **`contentHash`（全文件 SHA-256）而不是 assetID**：移动/改名/重复副本共享同一份缓存（M2 的 `moved` 语义直接受益）。
  - `pipeline=preview` 时 `recipeDigest = "-"`：**占位不随编辑失效**，首帧永远有东西可画。
  - `pipeline=graph` 时 `recipeDigest = sha256(canonical(develop_json) | decoderRecipe | graphVersion)`，`decoderRecipe = "v8/boost0/gamutOff"`（M3 的前置 ①②），`graphVersion` 是 kernel 语义版本常量。
- 写入：`.tmp` → `rename`（同卷原子）。**不 fsync**：丢了重建即可，为派生数据付 I/O 屏障是亏的。
- 无 sidecar、无索引库：尺寸/方向从 JPEG 头读；"某资产有哪些档"用 `lstat`。清理时的全目录遍历（50k 文件 ≈ 100 ms）在启动 5 s 后后台做一次，之后每小时一次。
- **清理与上限**：默认预算 **2 GB**（可配 512 MB–20 GB，`settings` 里存）。淘汰顺序：① 已有 `graph` 对照的 `preview` 文件；② `t2048/t4096` 且 30 天未用；③ 全局 LRU（`mtime`，命中时**每会话最多 touch 一次**并批量刷，避免每次读都写 inode）。**10 分钟内写过的文件不淘汰**（防抖：别把用户正在看的窗口淘汰掉）。

## 4. 与编辑的关系

- 编辑提交（history commit）时，`assets.develop_json / develop_version / render_version` 在**同一事务**里更新；`render_version` 是单调计数器，只用于 UI 快速判断"内存里这一格是不是旧配方"，**不是缓存键**。
- **缓存键用 `recipeDigest` 而不是 `render_version`**：`render_version` 会在 A→B→A（撤销、复制粘贴设置）时冲突，而 digest 天然幂等——撤销回 A 直接命中 A 的旧文件。这是"不产生第三份缩略图"的结构性保证。
- 重渲时机（三条，全部可选做；正确性不依赖它们）：
  1. 该资产**在可见网格内**且编辑已提交 → 300 ms 防抖后重渲当前请求的档；
  2. 从 loupe 返回网格 → 立即重渲该资产的可见档，目标 **≤ 600 ms 内新图替换旧图**；
  3. 不在可见范围 → **不渲**。下次显示时按新 key 自然生成（惰性），旧文件留给 LRU 淘汰。
- **防抖/队列纪律**：单飞 per `(contentHash, tier)`（重复请求合并到一个 job）；`isInteracting == true`（拖动、缩放进行中）时**禁止**投递缩略图 job；防抖窗口 300 ms 内多次提交只保留**最后一次** `recipeDigest`（中间配方直接丢弃，不排队）；jobId 单调递增，同级按 jobId 先来先做；**并发上限 3**（LightCraft 同值）。
- 优先级（高→低）：① loupe 当前帧；② 可见网格/胶片条；③ 屏外一行预取；④ 可见项的编辑重渲；⑤ 导入补 `t256` / 离线恢复补生成。
- 抖动防线：占位与精修复用同一个 `NSCollectionViewItem` 的 layer，**替换时不改 cell 尺寸、不触发 `invalidateLayout`**；新图尺寸与旧图档位一致，替换即像素替换，不做淡入动画（淡入会让"编辑生效了吗"难以判断）。

## 5. 预取与取消

- 预取范围：**可见 + 上下一行**（按 §1 的纯布局函数算，不按像素猜）。滚动中只做可见，**滚动停止 150 ms 后**才放开屏外预取。
- 取消语义：每次可见范围变化递增 `generation`；队列里 `generation` 过期的 job 直接丢弃；**在飞的解码不可中断**（`CIRAWFilter` 无法取消）→ 让它跑完并写盘（不浪费），但结果不推给 UI。取消率与在飞数必须可观测（`thumbs bench` 打印 `cancelled/inflight`）。
- 预热速率：单 worker 路径 ≤ 30 张/s，整机 CPU < 1 核；用户有输入时暂停，电池供电且电量 < 30% 暂停。
- **目标数字**（口径同已有 bench：3 帧预热后取 p50/p95，60 次迭代，打印实测值不打印估算）：

| 场景 | 10k 行 | 50k 行 |
|---|---|---|
| 首屏 20 张可见，冷（需生成）p95 | ≤ 400 ms | ≤ 400 ms |
| 首屏 20 张可见，热（全命中）p95 | ≤ 80 ms | ≤ 80 ms |
| 滚动主线程 p99（60 fps 预算 16.7 ms 的一半内） | **≤ 8 ms** | **≤ 10 ms**，且 ≤ 10k 值 + 2 ms |
| 队列峰值 / 在飞 | ≤ 预取窗口的 2 倍 / ≤ 3 | 同（**不随行数增长**） |
| 整库预热 `t256` | ≤ 120 s | ≤ 600 s |
| 稳态命中率（完整滚一遍后再滚一遍） | ≥ 99% | ≥ 99% |

50k 的"≤ 10k + 2 ms"是这套设计的核心断言：它证明开销是 O(可见) 而不是 O(N)。

## 6. DNG 不标定（前置 ④）在缩略图上的具体含义

`docs/STATUS.md` 第 4 条：DNG 能到的是 `9.dng`，比 `9` 约 25% 更噪——**DNG 源的测量不能用来标定原生 RAW 管线**。落到缩略图上，有四条具体后果：

1. **P 通路对 DNG 更不可信**：DNG 的内嵌预览是 Adobe DNG Converter 自己渲的（带 `crs:CameraProfile` 的观感），与 Apple 管线差得比原生 RAW 更远。仍允许当占位，但必须带 `pipeline=preview` 标记，且 **`tier ≥ 1024` 不接受 DNG 的 P 占位**（不允许"用 Adobe 的观感充当我们的首屏大图"）。
2. **不能用 DNG 做缩略图 golden/bench 的唯一样本**：`thumbs bench` 的参考样本必须分别覆盖 CR3/RAF/ARW/RW2 与 DNG 两类，报告里分列——否则 ARW 1616 的内嵌预览上限与 DNG 的 8192 会被平均成一个假数字。
3. **解码配方锁死 v8**：`decoderRecipe = "v8/boost0/gamutOff"` 是常量，键里没有任何 `decoderVersion` 参数。缩略图**永不**走 `9`/`9.dng`，所以"同一文件两种后缀出图不同"不会漏进网格。单测断言 `ThumbRecipe.decoderRecipe == "v8/boost0/gamutOff"` 且键生成函数不接受版本入参。
4. **DNG 渲不出图但预览存在**（无 profile / 冷门机型）→ 网格显示 P 占位 + "不支持"角标，loupe 报 `DecodeError`，**行保留**。这是产品上合法的稳态，不是错误路径。

## 7. 验收（可执行断言，不写"看起来对"）

`make thumbs`（脚本 `Tests/thumbs-acceptance.sh`，退出码即结论）跑 1000 行 fixtures + 4 个真实样本；`make thumbs-perf` 另跑 10k/50k 合成库。

| # | 断言 | 手段 | 判据 |
|---|---|---|---|
| 1 | **命中率** | `photonsctl thumbs scroll <pkg> --rows 200` 跑两遍 | 第二遍 `hitRatio(t256) == 1.000`；10k 全库滚两遍后 `≥ 0.99`；`missReason` 只允许 `absent`，出现 `corrupt` 即失败 |
| 2 | **首屏耗时** | `photonsctl thumbs first-screen --tiers 256,512 --repeat 20` | 冷 p95 ≤ 400 ms、热 p95 ≤ 80 ms（打印两行实测值） |
| 3 | **滚动主线程 p99** | `thumbs bench --grid 10000 --scroll 30` / `--grid 50000` | 10k ≤ 8 ms；50k ≤ 10 ms **且** 50k − 10k ≤ 2 ms |
| 4 | **重渲正确性** | 3 张图各 `exposure += 1`，等 settled，取 `t512` 与 `RenderGraph(scale=t512/长边, wantsPixels)` 直渲对比 | meanAbs ≤ 0.004 且 PSNR ≥ 45 dB（JPEG 有损，不能比 hash）；`pipeline == graph` 且文件 `mtime > commit 时刻` |
| 5 | **键幂等** | A→B→撤销回 A，扫 `thumbs/` 下该 `contentHash` 的文件数 | 恰好 2 个 `graph` 文件（A、B），第三个不出现；A 的旧文件被命中（读计数 +1 且 mtime 不变） |
| 6 | **禁止放大** | ARW 样本请求 `t2048` | 返回 `pipeline=graph`；断言 `sourceLongEdge ≥ 2048`，缓存里无 `preview@t2048` 条目 |
| 7 | **取消与泄漏** | 快速滚 200 行后停 1 s | 在飞 `inflight ≤ 3`；`cancelled ≥ 60%`；队列长度 ≤ 预取窗口数；进程 RSS 增长 < 50 MB |
| 8 | **配方锁死** | 单测 + `grep` 缓存目录断言 | 无任何 `9`/`9.dng` 配方产物；`ThumbRecipe.decoderRecipe` 常量断言通过 |
| 9 | **清理** | `--budget 64MB` 灌 1000 张后触发清理 | 总大小 ≤ 预算 + 单文件最大；可见窗口内的 `t256` 一个不少；`preview` 优先被淘汰 |
| 10 | **离线** | 改名 root 后 `thumbs scroll` | 已有缓存全部命中、无新生成、资产数不变；恢复后补生成数 = 缺失数 |
| 11 | 全链 | `make verify` | build + 单测 + L1/L2/L3 + catalog + thumbs 全绿 |

单测（`Tests/PhotonsThumbsTests/`）：选档与 DPR（含 1x/2x/6K XDR 三例）、禁止放大、键格式与幂等、`preview/graph` 解析顺序、LRU 淘汰顺序、防抖合并（100 次提交 → 1 个 job）、取消 token、DNG 配方常量。

## 8. 分步（每步独立验收，一个 worktree 内顺序做）

- **006a 探针 + 阶梯 + 键**：`local/probes/thumbcost.swift` 测五类样本（CR3/RAF/ARW/RW2/DNG）在 256/512/1024/2048 下 ImageIO 直取 vs `CIRAWFilter.previewImage` 的真实耗时，把 §1 的阶梯表用实测数字钉死；实现 `ThumbTier`（选档/DPR/禁止放大）与 `ThumbKey`（含 `recipeDigest`）。
  **验收**：探针表落 `local/out/thumbcost.json`；选档/键单测绿；**不动 UI、不写缓存**。
- **006b 缓存 + P 通路**：`ThumbnailStore`（目录分片/原子写/LRU 预算/清理）、`PreviewThumbSource`（ImageIO + ICC→sRGB + 方向）。1000 张 fixtures 后台生成 `t256`。
  **验收**：#1（部分）、#9、#10；吞吐打印（张/s）；二次运行全命中。
- **006c G 通路 + 队列/预取/取消**：`ThumbnailService`（优先级、单飞、并发 3、generation 取消）、G 通路经 `RenderGraph(scale:)`、编辑后重渲接线（不含 UI）。
  **验收**：#2、#3、#6、#7、#4 的数据侧（直接调 service，不截图）。
- **006d 接线网格/胶片条**：`PhotosApp` 的 `NSCollectionViewItem` 用缩略图替换 M3 占位图，占位→精修无闪烁替换，编辑返回网格触发重渲；`make thumbs` 进 `make verify`。
  **验收**：#4 的 UI 侧（新图替换时间 ≤ 600 ms）、#5、#8、#11；`make ui-smoke` 截图存 `local/out/thumbs-*.png`，并把 004 的"占位图网格 p99"更新为"真缩略图 p99"两行并列。

## 9. 不做与风险

**不做**：自建缩略图格式（不用 WebP/AVIF，JPEG 够且 ImageIO 零成本）、缩略图内嵌 XMP/GPS、人脸/场景分析缩略图、HDR 缩略图、`t256` 以下的档、跨库共享缓存。

| 风险 | 处理 |
|---|---|
| ImageIO 直取内嵌预览在大 CR3 上并不比 0.192 s 快 | **已测：ImageIO 快 2.6×**，故 P 通路定为 ImageIO 优先；`CIRAWFilter.previewImage` 保留为回退（键与接口不变） |
| 内嵌预览是相机 JPEG，与 G 出图观感跳变明显 | 只在 `tier ≤ 1024` 且未编辑时用 P；G 一到即删 P；占位角标可关（默认不显示角标，避免"闪烁提示"） |
| 6 GB 缓存挤爆用户盘 | 默认 2 GB + 三种淘汰序 + `settings` 可调；清理在后台且永不删 10 分钟内写过的文件 |
| 编辑拖动时重渲风暴 | `isInteracting` 禁投 + 300 ms 防抖 + 单飞 + 并发 3 + 同级 jobId 顺序 |
| ARW/RW2 内嵌预览太小（1616/1920）导致 6K 全屏必须渲染 | 预期行为；loupe fit 先上 P 占位再 G 精修，用户看到的是"由虚到实"，不是空白 |
