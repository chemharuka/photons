# 架构决策定稿（9 份源码精读 + 本机实测汇总）

> 生成：2026-10-25 · 依据：`darktable.md` `rawtherapee-art.md` `rapidraw.md` `ansel-vkdt.md` `digikam.md` `apple-raw-stack.md` `licensing.md` `lightcraft-engine.md` `lightcraft-product.md`
> 状态：M0（解码层）与 M1（编辑图）已落地并 `make verify` 全绿；结论见 §10 与 `docs/STATUS.md`

## 0. 一句话架构

**Apple 解 RAW（CIRAWFilter，v8/v9 双档）→ 一次性写成线性 16-bit 全尺寸缓冲并缓存 → 我们自己的 Metal 编辑图 → ColorSync 输出。**
不重写解码、不链 LibRaw、不链任何 copyleft；MIT 可发，含 Mac App Store。

## 1. 本机硬事实（实测，非文档）

| 项 | 值 | 出处 |
|---|---|---|
| 系统 RAW 组件 | `RawCamera.bundle` **9.51.0**，arm64e 私有 | `defaults read` |
| 解码器版本 | `6/6.dng/7/7.dng/8/8.dng/9/9.dng`，每图 `supportedDecoderVersions` 各自不同 | SDK `CIRAWFilter.h:27-36` |
| 机身覆盖 | **941** 台（含 101 个 iOS 模块）；v7=879 v8=465 **v9=69** | `supportedCameraModels(with:)` |
| 默认档 | Apple **自己默认给 v8**，不是 v9 | 三个样本实测 |
| v9 全尺寸耗时 | DNG 样本：60MP **5.05s** / 33MP 3.92s / 24MP 1.81s（v8 为 0.50/0.50/0.19s）→ **8–10×**；原生 RAW 冷启 3.9–9.1×、预热后比 v8 快（见 §11.1） | `rawcover` |
| 解码→线性纹理 | `rgba16Float` **0.566s @ 60MP = 106.5 Mpx/s**；`rgba32Float` 0.396s，|RGBAh−RGBAf|max=0.00049 | `arch` 探针 |
| EDR 余量 | **由解码开关决定，不是一个固定数**（2026-10-25 重测，见 §11.8）：同一 DNG（Leica SL3, ISO 100）线性最大值 —— 默认（`boostAmount`=1.0、`isGamutMappingEnabled`=true）**1.018**；D2′ 档（boost=0 + gamut off）**1.695**；另一文件默认 0.961 / D2′ 0.996。`extendedDynamicRangeAmount` 在 boost=0 时**无效果**，只在 boost 默认值时把上限抬到 2.32 | `edrheadroom` 探针（`local/probes/edrheadroom.swift`） |
| scaleFactor 0.5/0.25 | 0.32s / 0.26s → **约 0.2s 固定开销** | 同上 |
| 语义蒙版 | `sky/hair/skin/teeth/glasses` + `portraitEffectsMatte`（部分样本为 nil） | `rawprobe` |
| RAW 可写性 | **不可写**（ImageIO/CIRAWFilter 只能读）；导出 DNG 须自研 | `apple-raw-stack.md` |
| 元数据 | ImageIO 可**完整读写 XMP**（`xpacket` + `xmp:Rating`/`dc:subject`）→ 不需要 Exiv2 | `licensing.md` 实测 |
| 输出格式 | ImageIO 原生 22 种目标格式（含 HEIC/AVIF）→ 不需要 libheif/x265 | 同上 |

### RawCamera 内部结构（决定"能嵌多深"）

```
Resources/RawSFD/   ← CoreML **MIL 程序**（文本）+ 权重
  bayer_model.mil          32 conv  输入 image0 + noise0   权重 20.0MB
  bayer_quarter_res_model  24 conv  输入 image0 + noise0   权重 12.2MB
  quadra_* / xtrans_*      同上（按 CFA 阵列分套）
RawCamera.metallib (2.6MB)
  deBayer_v7 / v7_8bit / v8 / deBayer_draft
  deXtrans_v7 / v8 / deQuadra_draft
  denoisedPixel(... bayerPixel, noiseModel, addBackLimit, addBackOffset, phase, addBackAmount, blurredK ...)
```

**注意：metallib 里没有 `deBayer_v9`。** 见 §2 更正 B。

## 2. 更正记录（两处，含根因）

**A. "没有 mlmodelc" 与 "有 6 个 CoreML 模型" 两个说法都对，但我说得不完整。**
`RawSFD/*.mil` 是 **CoreML 的 MIL 程序文本**（CoreML Program 格式），不是编译后的 `.mlmodelc` 包。所以"找不到 .mlmodelc"字面成立，但"没有机器学习模型"是错的——模型在，只是以 MIL + 权重分离的形式落盘，运行时由 CoreML/Metal 编译。我先前那句"没有 mlmodelc"容易误导成"没有 ML"，这是我的表述缺陷。

**B. v9 是"ML 降噪"，不是"ML 去马赛克"。**
- demosaic kernel 只有 `deBayer_v7/v7_8bit/v8`、`deXtrans_v7/v8`、`deQuadra_draft` —— **无 v9 变体**
- 神经网络是 `denoisedPixel` 系列，输入是 `image0`（已解马赛克的图）+ **`noise0`（噪声模型）**，还有 `bayerPixel`/`phase`/`addBackLimit`/`addBackOffset` 参数
- 每个 CFA 阵列一套权重的原因不是"马赛克方式不同所以要神经解马赛克"，而是**降噪网需要知道 CFA 相位（`phase`）与 bayer 采样值，才能按该阵列的噪声特性建模**
- 这解释了为什么我实测 v9 vs v8 的差异小而集中在噪声指标：ISO 3200 中心区噪声 −11%，全局 MAD 仅 2.26/255

**结论修正**：v9 的主体价值是"Apple 的 ML 降噪 + 噪声模型回加"。这不削弱"深度绑定 Apple 管线"的决策——反而说明**降噪这一最难自己做的部分由系统免费提供**。

**C. ImageIO 的 XMP 通道是 `CGImageMetadata`，不是 properties 字典。**
`licensing.md` 写的"ImageIO 可完整读写 XMP（`xpacket` + `xmp:Rating`/`dc:subject`）"方向对、机制错：
- `CGImageProperties.h` 里**没有任何 XMP 符号**，`kCGImagePropertyXMPDictionary` 不存在（2026-10-25 全头文件 grep 零命中）；
- `CGImageSourceCopyPropertiesAtIndex` 对本机 DNG 返回的键里没有 `{XMP}`（实测 nil），而文件里确实有 15,478 字节 XMP 包（TIFF **tag 700**，偏移 66,558,538）；
- 正确的 API 是 `CGImageSourceCopyMetadataAtIndex` → `CGImageMetadataRef`：实测从中读到 `crs:Version=18.5.1`、`crs:CameraProfile=Adobe Standard`、`exifEX:LensMake=Sigma`、`xmpMM:OriginalDocumentID` 等。
- 写回同理走 `CGImageDestinationAddImageAndMetadata`。

代价评估不变（仍不需要 Exiv2），但**M2 的元数据读取必须按这条实现**：`CGImageSourceCopyMetadataAtIndex` → `CGImageMetadataRef`（`kCGImagePropertyXMPDictionary` 在 SDK 里不存在），`crs:*` 只把原文存进 `xmp_blob`，一个都不解析。

**但要补一条反证（2026-10-25 晚，真机实测）**：在 Fuji **X-Trans** 的太阳能板细网格（迷宫伪色压力测试）上，v9 的解马赛克**确实更好**——线条更直更连续、伪色/摩尔纹更少、拖影更轻（`local/research/v9-vs-v8-measured.md` §6.6，1:1 目视确认）。
所以准确说法是：**没有名为 `deBayer_v9` 的独立 kernel，但 v9 这条渲染路径在 raw 域上确实改善了 X-Trans 的解马赛克产物**；Bayer 侧则主要表现为降噪。不要再简单地说"v9 与去马赛克无关"。

## 3. 已定决策（含依据与代价）

| # | 决策 | 依据 | 代价 / 风险 |
|---|---|---|---|
| D1 | 解码只用 `CIRAWFilter`，**不引入 LibRaw** | `licensing.md`：LibRaw 画质倒退 + LGPL/CDDL 义务；Apple 941 机型覆盖主流 | 绑 OS 版本；冷门/后背/电影机缺失；拿不到马赛克 |
| D2 | ~~交互用 v8，导出用 v9~~ **已推翻 → 见 §11.1（D2'）**：v8/v9 是两条渲染路径，v9 下 CNR/细节/摩尔纹不可用 | v9 慢 8–10×；Apple 默认 v8；v9 不支持三项控制 | 按解码器版本声明能力集，不再当作"质量档位" |
| D3 | 解码结果落盘为**线性 16-bit 全尺寸缓冲**（每图一个 cache 条目） | 60MP 解码 0.5–5s，绝不能每帧重解 | 磁盘占用：60MP×8B ≈ 0.48GB/图 → 需 LRU 上限 |
| D4 | 工作空间 = **无上界线性 float**（Rec2020 基底），显示变换放最后一步 | `ansel-vkdt.md`：Ansel 用无虚构色的线性 Rec2020；EDR 实测有 1.748 余量 | 全程 float16/32 带宽管理 |
| D5 | 管线 **5 段 + 2 个缓存键**：`S0 geometry → S1 scene-linear → S2 tone map → S3 colour → S4 display` | ART 4 stage/23 step、LightCraft 5 段、Ansel 三段职责拆分，三者收敛 | 段边界要一次定死，否则缓存键失效 |
| D6 | 缓存键三级：`geoKey / linKey / preNRKey` | LightCraft `geo/lin_key/pre_nr_key`；darktable 四哈希（basic/auto/current/mipmap） | 键算错 = 脏缓存，必须单测 |
| D7 | **数据库是唯一真相**；XMP sidecar 只做导出/导入，默认不回读 | darktable 最大坑就是 db＋XMP 双真相；digiKam 结论同为"库权威，文件是可选镜像" | 用户手动改 XMP 不会自动生效 |
| D8 | 存储 = **SQLite(GRDB)**，不是 LightCraft 的 JSON+oplog，也不是 RapidRAW 的"无库" | RapidRAW 无 catalog 是产品级不可逆错误（10 万张时相册半死链）；oplog 是为 WASM/多端，我们不需要 | 需要自己做 schema 迁移 |
| D9 | 编辑参数 = **单个 Codable JSON blob + 文档级 `schemaVersion`**，显式默认值 | darktable 六个独立版本号 = 兼容地狱；RT/ART 全局 PPVERSION 瀑布 + 无前向兼容；vkdt 参数三处手工对齐 | 每次加字段必须写默认值 |
| D10 | 历史 = **参数快照栈 + 游标**（非命令日志）；脏标记用**组级 bool** | darktable `history` 表 + `history_end` 游标；ART 把 RT 的 10,673 行逐参数 dirty 压成 94 行 | 单步撤销粒度 = 一次编辑动作 |
| D11 | 局部编辑 = **mask 为第一类值** + **补丁级重算 + 依赖闭包** | ART `Mask`（六层乘积 + guided filter）、`ipspot.cc:686`；RT 的 LocallabSpot（23,863 行）是反面教材 | v0.1 不做，但数据结构第一天就要留位 |
| D12 | 预览 = **同一函数 + scale 参数**，不是第二套实现；外加 draft→精修阶梯 | ART 四态管线 `skip×skip`；RapidRAW 草稿/精修 + 单调 jobId + 并发≤3 | 需要可取消的渲染任务模型 |

## 4. v0.1 范围（11 项，全部可验收）

**做**
1. 打开/新建库、崩溃安全持久化（SQLite + WAL）
2. 导入：哈希去重（头尾 100KB MD5 已证明不够 → 全文件 SHA-256）、复制/引用、按日期分目录、重命名模板
3. 解码：RAW（DNG/CR3/RAF/NEF/ARW/RW2/ORF…）+ JPEG/HEIC，v8 交互档
4. 界面骨架：网格 + 单图 + 胶片条 + 左栏来源 + 右栏调整面板
5. 评级与筛选（星级/旗标/色标）
6. 调整：曝光 / 白平衡（吸管）/ 高光恢复 / 曲线 / HSL / 锐化 / 降噪 / 暗角（多数映射到 CIRAWFilter，曲线与 HSL 自研 Metal）
7. 裁剪 + 拉直
8. 历史与撤销（快照栈 + 游标）
9. 预设 + 复制粘贴设置
10. 导出 JPEG/HEIC/TIFF（8/16-bit，sRGB/Display P3），导出用 v9 档
11. 三级预览缓存（缩略图 / 屏幕 / 1:1）+ 线性缓冲磁盘缓存

**不做（并说明原因）**
| 不做 | 原因 |
|---|---|
| 自己写 demosaic / 降噪 | Apple 免费且更好（§2） |
| LibRaw / Exiv2 / libheif / lensfun 库 | 许可证（`licensing.md`）；ImageIO 已覆盖 |
| **HDR/多帧合成、超解析** | **无马赛克数据，物理上做不了**（`apple-raw-stack.md` 实测 `cvPixelBuffer:properties:` 返回 0×0 惰性空壳） |
| DNG 导出 / 写 RAW | RAW 不可写，须自研 DNG 写入器（v0.9+） |
| 镜头 profile 库 | Lensfun 数据 CC BY-SA 会传染；v0.3 再做"手动畸变/TCA/暗角" |
| 打印 / 幻灯片 / 地图 / 视频 / 人脸 | 与"开发 RAW"无关，v1.0 之后 |
| AI 主体/天空蒙版 | v0.1 免费拿语义蒙版可用，但画笔蒙版 v0.3 |

## 5. 验收链（三层，M0 就要立起来）

| 层 | 内容 | 判定 |
|---|---|---|
| L1 确定性 | 同一 RAW 同一参数渲染两次，缓冲 SHA-256 相同 | 必须完全相等（LightCraft 已验证它自己确定；Apple 侧待验——**M0 第一件事**） |
| L2 golden image | 参数组合 → 输出图，基线入库，改动后逐像素比 | 允许阈值（half 精度），超阈值即失败 |
| L3 统计兜底 | 与系统"预览"/LightCraft 的 PSNR + 直方图距离 | 仅报警，不作判据 |

**明确作废**：早前设想的"用 LightCraft CLI 做像素级 oracle"——我们走 Apple 解码器，两者 demosaic/降噪本质不同，逐像素比对无意义。LightCraft 只保留两个用途：**参数契约参考**、**L3 统计兜底**。

## 6. 数据模型草案（SQLite）

> **已被 M2 的定稿取代**（2026-10-25）：单库 SQLite+GRDB、宽主表 `assets`
> + 1:1 卫星表 `asset_metadata`、相机/镜头为文本列 + `camera_key`（不建字典表）、
> 关键词与相册多对多、`source_roots` 用卷 UUID、`import_sessions`/`import_files` 台账。
> 本节保留为早期草案与推理依据。

```
folders(id, volume_uuid, path, name)              -- 卷用 UUID 不用路径（digiKam）
photos(id, folder_id, filename, ext, content_hash, size, mtime,
       width, height, capture_time, camera_id, lens_id,
       rating, flag, color_label, develop_json, develop_version,
       render_version, edit_time)
camera(id, make, model)  lens(id, make, model)
albums(id, parent_id, name, sort)                 -- 闭包表 + depth
album_photos(album_id, photo_id, position)
keywords(id, parent_id, name)  photo_keywords(photo_id, keyword_id)
edit_history(photo_id, seq, develop_json, label, created_at)   -- 快照栈
presets(id, name, develop_json)
masks(photo_id, mask_id, kind, params_json)       -- 预留，v0.3 启用
```

- 主表只放**热列**，EXIF 全量、位置、镜头等拆**卫星表**（digiKam 的"会变/不会变"分流）
- 删除一律软删（`photos.deleted_at`），因为 digiKam `Images` 无 creationDate 导致 `INNER JOIN` 静默丢图是真实事故
- `develop_json` 是**唯一真相**；XMP 只在用户显式"写入文件"时生成
- `render_version` + `develop_version` 双版本号用于缓存失效，不用浮点/时间戳

## 7. 风险清单

| 风险 | 影响 | 缓解 |
|---|---|---|
| Apple 解码器输出随 OS 更新而变 | golden image 全红 | 记录 `render_version` + OS 版本；基线按大版本分组 |
| 新机型 profile 需按需下载 | 打开新机 RAW 返回 nil | 调 `downloadResources(timeout:)`，UI 显式提示 |
| 线性缓冲磁盘占用 | 60MP ≈ 0.48GB/图 | LRU + 可配置上限 + 自动清理 |
| v9 只有 69 机身 | "最高画质"对多数用户等于 v8 | UI 明确标注当前档位与实际生效版本 |
| 无马赛克数据 | 无法做 HDR 合成/超解析/自定义降噪 | 产品上不承诺这些功能 |
| 单 session 上下文被撑爆 | 效率崩 | 规格落盘 + worker 只回 diff --stat + 每 3–5 任务 checkpoint |

## 8. 可直接复用的资产

- 本机探针：`probes/rawprobe.swift`（属性面 dump + 逐版本渲染）、`probes/rawcover.swift`（覆盖度 + 真实计时）、`probes/arch/`（CIRAWFilter→纹理→自写 kernel 端到端）、`probes/noise_pair.py`
- 子进程探针：`probes/` 下 4 个 Swift 探针 + 5 个 CI kernel + `build.sh`/`run-all.sh`
- 现成的 Lightroom 迁移参考：darktable `src/develop/lightroom.c`（1620 行，LR 目录/XMP 参数映射）
- 现成的功能需求清单：`lightcraft-product.md`（27 模块 / 578 行 / 122 条控件 id+范围+默认）

## 9. 未决

- ~~`v9-vs-v8-measured.md`（白名单机身的真实 RAW 对比）仍在跑~~ **已作废**：该子进程从未交付；这个问题已由 `local/research/swift-raw-ecosystem.md` §0.2 的本机实测回答（结论见 §11.1）
- Apple 解码器的**确定性**：已在 M0 实测为确定（同进程/跨进程 digest 相同，见 `docs/STATUS.md`）
- `linearSpaceFilter` 的语义（能否把我们的处理插进 Apple 管线内部）未实验 → 决定"捆绑深度"上限

## 10. M1 落地时定下的实现细节（代码即如此）

| # | 结论 | 依据 / 代价 |
|---|---|---|
| M1-1 | **kernel 以资源形式随包发布，运行时 `MTLLibrary(source:)` 编译** | SwiftPM 没有可靠的 `.metal` 构建步骤；Metal toolchain 是网络下载（本机失败过）。代价：每进程首次 ~0.2 s，永不在帧内 |
| M1-2 | **S0 输出的是 canvas，不是 crop**：`canvas` 与 `content` 分离，视口比例不同时照片居中留空（alpha 0），导出时二者相等 | 同一 kernel 覆盖"屏幕"与"导出"，不产生第二套实现（D12）。content 之外的像素写 0，不做 clamp |
| M1-3 | **`--scale` 相对全分辨率**；解码走阶梯 `1 / 0.5 / 0.25 / 0.125`，选刚好覆盖输出的一档，剩余缩放交给 S0 | 只重采样一次。解码过细 = 白花 0.5 s 与 480 MB；过粗 = 重采样两次 |
| M1-4 | **缓存键链 6 环**：`geo → lin(S1) → preNR(S2) → curve → color → vignette → display` | D6 的三级是下界；每个阶段边界都要能单独命中。上游键变则下游键必变，所以"S3 改动不重跑 S1"是结构性的，不是特例分支（单测断言只执行 s3-color / s3-vignette / s4） |
| M1-5 | **S4 永不进缓存**：它的纹理要交给调用方（或回读），缓存它等于把池里的纹理借出去 | 避免下一帧复用到正在被读的纹理 |
| M1-6 | **"中性"是 kernel 里的真实分支**，不是近似：参数全零时直接 `dst.write(src.read(uv))` | 否则"不编辑"会与"解码"缓慢漂移，golden 与 UI 都失去基准。identity 测试把偏差钉在 < 0.002（显示单位） |
| M1-7 | **白平衡在 M1 是相对近似**：Planckian 拟合（1000–15000 K），以 6500 K 归一 → 解码结果即中性参考 | 真正的 WB 应从 as-shot 元数据做 Bradford 适应，等解码侧吐出该元数据（M2）。宁可写"近似"，也不假装是相机白平衡 |
| M1-8 | **S2 解析式而非 LUT**：blacks/whites 重映射 → 绕 0.18 中灰的对比 → 按输出亮度加权的阴影/高光提升 | 每个滑块单调、零值恒等、没有需要同步的表。用户控制点的曲线才用 LUT（`CurveLUT`，单调三次插值防折叠） |
| M1-9 | **bench 量上屏路径**：不读回 CPU（2560×1600 一帧 32 MB）、关缓存、3 帧预热，`gpu only` 单列 | 读回会让 16.7 ms 预算失真；开缓存则第 2 帧起测的是命中而不是渲染 |
| M1-10 | **`detail`（锐化/降噪）不进图**：将来映射到 `CIRAWFilter`（`sharpnessAmount` / `luminanceNoiseReductionAmount`），属解码侧变更 | 存字段、不渲染，避免"两处降噪、结果不一致" |


## 11. 实现层的实测修正（来自 Swift 生态调研，改的是决策不是细节）

> 来源：`local/research/swift-raw-ecosystem.md`（本机探针实测）与 `swift-raw-editors-small.md`（16 个仓库横评）。
> **本节推翻/收紧前文条目，读 §3 之前先读这里。** 原始报告在 `local/research/`，索引见 `local/research/INDEX.md`。

### 11.1 D2 被推翻：v8 / v9 不是"质量档位"，是两条渲染路径（已由真机样本定论）

两份独立实测（`swift-raw-ecosystem.md` §0.2 与 `v9-vs-v8-measured.md`，后者用 v9 白名单机身的
真实 RAW 跑完 5 个机身）合成以下结论：

- **v9 下色度降噪旋钮被关掉**：四台机身 v9 的 `chromaNR` 默认 **0.00**（v8 是 0.50），Apple 让神经层接管色度降噪；`isColorNoiseReductionSupported` / `isDetailSupported` / `isMoireReductionSupported` 在 v9 下为 **false**，写这三项对像素**零影响**。
  后果：原 D2「交互 v8 / 导出 v9」会让用户设的色度降噪、细节、摩尔纹在导出时**静默丢失**。
- **v9 是真正的 raw 域神经降噪，但收益强依赖 ISO**：
  - 基础 ISO（100–250）：**没有净收益**。降噪量落在 ±10% 噪声内，暗部在 Canon/Pana/Fuji 上反而**更噪**；换来的是高频结构 +25…46%（更锐也更颗粒）。细节确有改善（X-Trans 解马赛克更好），但不是"AI 一键干净"。
  - ISO 3200（SIGMA fp L）：**明确胜利**——平坦区噪声 −27%、暗部 −24%、色度 −19%，而 1:1 细节块 −0.1%（噪声少了、细节没丢），目视更干净且无抹平/编造纹理。
- **成本只在冷启动**：全尺寸导出冷启 **3.9–9.1×** 慢（60 MP 4.86 s vs 1.09 s）；但**同一个 filter 预热后重渲染比 v8 更快**（0.14 s vs 0.26 s）。冷 2048 px 首帧 0.84–1.70 s，不能用来做拖动预览，除非解码已缓存。
- **`9` 与 `9.dng` 是两条不同的管线**：SIGMA 同一文件两种后缀出图不同（`9.dng` 约 25% 更噪、25% 更高频）。**DNG 源的测量不能用来标定原生 RAW 管线。**

**新决策 D2'**：
1. **默认全 v8**，不做"交互 v8 / 导出 v9"的隐形切换。
2. v9 作为显式可选导出档，**门控 = `ISO ≥ 约 800` 且 `机身 ∈ v9 白名单(69)`**；不满足条件时对话框直说"v9 在基础 ISO 只换来 4–9× 时间和更多颗粒"。
3. 启用时：色度 NR / 细节 / 摩尔纹三项**置灰**并在导出报告里写明；golden 里 v8 / v9 各存一份。
4. **必须回读断言**：非白名单机身设 `9` 会**静默退回 8**（`outputImage != nil`，不报错）。`decoderVersion` 赋值后一律读回比对，不等就告警并按 v8 出图。
5. `EditModel` 不假定属性恒可用，按解码器版本声明 `decoderCapabilities`（M2 引入）。

### 11.2 `previewImage` 不是缩略图，是内嵌的全尺寸 JPEG

CR3 **8192×5464**、RAF 4416×2944、ARW 1616×1080、RW2 1920×1280；渲 4416×2944 仅 **0.192 s**，而全解码（1/4 采样）0.760 s。
→ 网格缩略图与首帧直接走它，比走解码快约 4×；M2 导入时先落这张，再后台补真解码。

**但"走 previewImage"具体指 ImageIO，不是 `CIRAWFilter`**（2026-10-25 实测，19 个真实 RAW，三档尺寸）：

| 通路 | t256 冷 p50 / p95 | t512 | t1024 |
|---|---|---|---|
| ImageIO `CGImageSourceCreateThumbnailAtIndex`（`CreateThumbnailIfAbsent=false`） | **62.1 / 111.5 ms** | 63.3 / 119.1 ms | 48.6 / 74.1 ms |
| `CIRAWFilter.previewImage` | 153 / 236 ms | 162 / 249 ms | 160 / 249 ms |

`CIRAWFilter` 每次构造约 0.19 s，把 previewImage 的收益吃掉 2.6×；同一份内嵌 JPEG 用 ImageIO 直取即可。
→ 结论：**缩略图 P 通路 = ImageIO 内嵌预览**；`CIRAWFilter.previewImage` 只作为"ImageIO 拿不到"时的回退。
25 ms/张 在大容器 RAW（CR3 单张 ~80 ms 扫描）上不可达，现基线 = 冷 p50 62 ms / 热 1.2 ms（见 `006-thumbnails.md`）。

### 11.3 镜头校正按**文件**而非按机型

`lensCorrectionEnabled` off→on 在 RW2 改动 4.13M 子像素（meanAbs 0.0663）、RAF 6.18M（0.0189）；但 CR3（EOS R5 + Sigma 50/1.4）**不支持**。能力探测必须 per-file，不能按机型缓存。

### 11.4 场景线性配方已确认，但解码侧要显式设置

`boostAmount = 0` + `isGamutMappingEnabled = false` 后 `exposure +1EV` 严格 ×2（ratio p10=p50=p90=**2.0063**）；默认参数下同一测试是 2.03–2.66（色调曲线在动）。
→ M1 的"线性缓冲"假设成立，但 **M0/M1 的解码还没有显式关掉 boost 与 gamut mapping，M2 必须补**。

### 11.5 三件可以省掉的事

- **HDR 导出免费**：`kCGImageDestinationEncodeGenerateGainMapWithBaseImage`（CGImageDestination.h）、`kCIImageRepresentationHDRImage`（CIContext.h）、`CIImage.contentHeadroom`（CIImage.h）→ 不必自研 gain map。
- **ImageIO 的 XMP 足以替代 Exiv2**（JPEG/HEIC/TIFF/PNG 四容器自定义命名空间往返成功），但两个坑：`dc:subject/title/creator` 读回是**嵌套 Tag 数组**、数字读回是**字符串**。
- `CILocalLightMapPrepare` / `CILocalLightFilter` / `CITransformMatrix` 在 macOS 27 **已不存在**（252 个 `filterNames` 里查无）；而 `CIRAWFilter` 本身也不在 `filterNames` 里却能用 `CIFilter(name:)` 构造 → **不要按 filterNames 做能力探测**。

### 11.6 竞争格局的一句实话

RAW Power 首页宣传的 "Unique Hooks into Apple's RAW Engine（Control Boost, Black Point, Moire）" 就是同一组免费可用的 `CIRAWFilter` 属性。**CIRAWFilter 是地板不是天花板**；差异只在镜头库、额外格式解码、目录规模与延迟。

### 11.7 v9 出厂的默认值不同——这才是"v9 看起来更差"的真正原因

切版本后直接读回的默认值（`v9-vs-v8-measured.md` §6.3）：

| 机身 | v8 锐化 / 亮度NR / 色度NR | v9 锐化 / 亮度NR / 色度NR |
|---|---|---|
| Canon R5 | 1.00 / 0.00 / 0.50 | 1.00 / 0.01 / **0.00** |
| Sony ILCE-7M4 | 1.00 / 0.38 / 0.50 | 1.00 / 0.01 / **0.00** |
| Panasonic S5M2 | 1.00 / 0.00 / 0.50 | 1.00 / 0.01 / **0.00** |
| Fujifilm X-T5 | 1.00 / 0.00 / 0.50 | 1.00 / 0.01 / **0.00** |
| SIGMA fp L | 0.55 / 0.01 / 0.50 | **0.93** / **0.20** / **0.00** |

- **切到 v9 必须显式写全部参数**，不能假定"默认值等于 v8 的默认值"。
- 想让 v9 只降噪、不额外加锐：`sharpnessAmount = 0`。代价是微观对比 −21…30%，需要自己补回锐化
  （唯一"免费"的机身是 ISO 3200 的 SIGMA，细节 −0.4%）。
- 版本切换不污染缓存：`v9→v8→v9` 与 `v8→v9→v8` 在 fresh filter 下都稳定。我们的 `DecodeCacheKey`
  已包含 `decoderVersion`，所以天然安全。

### 11.8 EDR 余量由解码开关决定（2026-10-25 重测，推翻"1.748 是常数"的记法）

同一文件（`L1030402.dng`，Leica SL3，ISO 100）只改 `CIRAWFilter` 的两个开关，线性输出最大值：

| `isGamutMappingEnabled` | `boostAmount` | `extendedDynamicRangeAmount` | 线性最大值 |
|---|---|---|---|
| true（默认） | 1.00（默认） | 0 | **1.018** ← M0/STATUS 记录的那个数 |
| true | 0 | 0 | 1.046 |
| false | 1.00 | 0 | 1.101 |
| **false** | **0** | 0 | **1.695** ← D2′ 档（§11.4 要求的设置） |
| true | 1.00 | 2 | 2.322 |
| false | 0 | 2 | 1.695（`extendedDynamicRangeAmount` **无效**） |

第二个文件（`L1030412.dng`）默认 0.961 / D2′ 0.996 → **绝对值随文件走**（0.96–1.70），但"默认设置削掉约 40%"这一条在两个文件上都成立。

**三条结论**
1. **§11.4 的前置 ② 有两个后果，不是一个**：除了"曝光必须严格 ×2"，它还决定 **EDR 余量是否存活**（1.695 → 1.018）。
   之前 `swift-raw-ecosystem.md` 把 1.019 vs 1.748 归因为"tone map 吃掉了余量"——**归因错了环节**：S2 不 clamp，clamp 在 S4，而削平发生在解码侧的默认 `boostAmount`/gamut mapping。
2. **`extendedDynamicRangeAmount` 不是可用的杠杆**：它只在 boost=默认值时抬高上限（会顺带改影调），boost=0 时完全无效。故不列入 EDR 实现手段。
3. **EDR 显示的"数据侧"在 M3 就定了**（随前置 ②），"画面侧"才留 M3.5：S4 的 `clamp(v,0,1)` 与画布的 `CAMetalLayer`/headroom 属于 M3 的契约，
   否则 M3.5 要同时改 S4、S2 的高光段、`DisplayOptions`、缓存键与全部 golden。

### 11.9 解码缓冲曾经整体上下镜像（2026-10-26 更正，影响所有 golden）

M3 时记录的"`L1030433.dng` 渲染成 180°，因为文件里读不到 orientation tag"**是误判**。实测：

- TIFF IFD0 `0x0112 = 1`（57 个 entry 里明确存在），5 个 SubIFD 无该 tag（默认 1）；exiftool 的
  `[IFD0]/[XMP-tiff]/[CameraIFD] Orientation` 全为 1；文件内嵌 JPEG preview 是正立的（与 Apple 全解码 corr 0.994）；
  `filter.orientation` 也报 `.up`。
- **真因：`CIContext.render(to: MTLTexture)` + `getBytes` 读回是 bottom-up**。合成图案（左上角白标记）读回后
  标记落在 buffer **最后一行**；同一 CIImage 用 `getBytes` 与 `createCGImage` 对比是 **mirrorV corr 0.9998**。
  所以 `LinearImage` 的 row 0 一直是画面底部——**每个文件**都上下镜像，带文字的样张才看起来"转了 180°"。

修法与后果：

- `RAWDecoder` 读回时修正行序；`LinearImage` 新增 `ImageOrientation`（8 值 + `irot→EXIF` 映射）与 `oriented()`。
- 方向解析走 ImageIO `kCGImagePropertyOrientation` → HEIF `irot` → `CIRAWFilter.orientation` 兜底，解码与预览
  两条路必须给出**同一个**方向结论（单测断言相等）。
- **方向不是用户编辑**：不进 `EditModel`，进 `StageKeys.links(…, orientation:)`，且 `== .up` 时不追加字段
  （`.up` 的键逐字节不变）。
- `DecodeRecipe.current` → **`v2-topdown-rows`**：v1 落盘的线性缓冲是镜像的，绝不能复用。
- 全部 4 个像素 golden 已重录；`mask-*` 为合成源（不走解码）不受影响。
- 客观判据（不靠肉眼）：修复后 decode 上半区 0.1548 > 下半区 0.1152（修复前 Δ = −0.040）；端到端 `photonsctl render`
  与 `sips` 独立解码 **identity 0.9954**（修复前 mirrorV 0.9947）。
- 残留缺口：本机 12 个 HEIC 的 `irot` 全是 0，非零旋转只用合成 box 测过；`imir`（镜像 box）未实现。

### 11.10 1:1 取景要用 core 的 `outputWindow`，不能用 `cropRect` 冒充

1:1 曾用"改 `geometry.cropRect` 再按 canvas 渲"实现，后果是暗角与蒙版 feather 按**可见窗口**归一化，
且 S0 的归一化旋转使 9° 拉直下的投影差约 **0.29%**（量化过：mean 0.1926 / max 0.4978 显示单位）。

正解：`RenderOptions.outputWindow: ImageRect?`（内容像素坐标，`nil` = 整帧），S0 两阶段——全帧 crop/rotate/flip，
再取窗口；暗角与 feather 回到**整帧**归一化。结果：与"整帧渲染后裁同一区域"**逐像素一致（0.000000）**，
`nil` 时 7 个 M1 键逐字节不变，窗口只进 geoKey；1:1 平移一帧 p50 4.0–4.6 ms。

残留：`LoupeMapping`（命中测试/捏合锚点）仍是窗口形状，9° 拉直下与渲染投影差 ≤0.29%（7.5 px @2560），
属于 hit-testing 的近似，不在渲染路径上。

## 12. UI 架构（M3 定案，2026-10-25/26 落地）

**起点：AppKit 外壳 + SwiftUI 叶子。** 依据是读码而非偏好（`local/research/ui-stack.md`）：走到 LR Classic 规模的
两个开源项目（redlamp 421.8 kLOC、PixelLoupe 95.9 kLOC）UI 都落在 AppKit，SwiftUI 网格项目（LumaHarbor 等）
选择语义均被简化；redlamp 把 SwiftUI 面板改回 AppKit 后主线程占用 100% → 34%。

**一套状态，两层视图。** `CatalogSession`（`@MainActor @Observable`）是唯一模型；AppKit 视图用
`ObservationBridge`（`withObservationTracking` 重新注册，30 行）订阅，SwiftUI 卡片用 `@Bindable` 读同一对象。
不存在第二份状态副本。

**窗口与布局**（数字来自 Phos 的 `WINDOW_INTEGRATION.md`，MIT，只取数值）：自绘 36 pt 顶栏与交通灯同行
（不用 `NSToolbar`）；左列表 212 pt（196–260）/行高 46；胶片条 122 pt、缩略 74×50（⌃⌘B）；检查器 330 pt（300–364）；
大面板 matte、小组件 glass；最小安全编辑区 560×420。

**网格**：`NSCollectionView` + `FlowLayout` + 复用 item + prefetch（`NSCollectionViewPrefetching`）；
自绘图层网格（redlamp 的 5,736 行）是上界，不是起点——只有需要 justified 布局/吸顶分组/连续尺寸时才值得换。

**画布**：自绘 `NSView` + `CAMetalLayer`；缩放 = 改渲染倍率重渲，**不缩放图层**；
1:1 取景走 core 的 `outputWindow`（§11.10），不用 crop 冒充。

**EDR**：`headroom = clamp(1 + (maxEDR − 1), 1…16)`，按窗口所在屏取值；**不能**写成 `maxEDR − 1`
（1.2 会变 0.2 → 钳到 1 → 唯一 HDR 屏上 EDR 被关掉）。SDR 自动降级为 headroom 1。

**缩略图**：P 通路 = ImageIO 内嵌预览（比 `CIRAWFilter.previewImage` 快 2.6×，§11.2）；G 通路 = 同一条
`RenderGraph`（D12）；**只有一个服务层** `ThumbnailService`（优先级/同键合并/取消/并发 3），UI 的 provider
只是它的生产者适配层。DNG 的 preview 上限 t512。

**编辑的三种写入通道**（不要混淆）：
1. **文档编辑** → `EditModel` → `EditHistory` 快照 → `Catalog.saveDevelop`（迁移 v3 落 `develop_json` + `asset_history`）；
2. **目录元数据**（星级/旗标/色标）→ 直接写库，**不进**开发历史，⌘Z 不撤销它；
3. **视图态**（`showMaskID`、倍率、筛选）→ 只 bump `editRevision`，**不落盘、不进历史**；撤销时用
   `restoring(_:keeping:)` 把当前视图态贴回快照。

**已知近似**：`LoupeMapping`（命中测试/捏合锚点）仍是窗口形状，9° 拉直下与渲染投影差 ≤0.29%（7.5 px @2560）；
蒙版 feather/refine 在 `outputWindow` 边缘按 halo 截断（内部精确到 5.7e-5）。

## 13. 直方图的轴：SDR + 4 stop 指数尾段 + 显示上限（2026-10-26 定案，代码即如此）

**问题**：005f 的直方图只有 `0…1` 的 256 个码值 bin。EDR 一开，S4 允许 `min(v, headroom)`，编码后可超过 1.0
（headroom 1.695 → 码值 1.259，headroom 16 → 3.14），这些像素**全部挤进 bin 255**：既看不出高光余量，也没法
回答"画面有没有用完这块屏"。同时 `fit` 帧的 ROI 取的是整个 canvas，黑边被当成黑色像素统计——一张没有死黑的
照片能读出几十个百分点的削底。

**轴 = 两段，一次测量**（`Histogram`）：

| 段 | 码值/单位 | bin | 画法 |
|---|---|---|---|
| SDR | `0…1` 均匀码值 | `binCount`（256） | 左侧线性，占剩下的宽度 |
| 尾段 | SDR 白之上，**线性光**每 1/8 stop | `maxStops × hdrBinsPerStop`（4×8=32） | **30 pt / stop，固定 4 stop = 120 pt** |

- **单位是线性光的 stop，不是码值翻倍**：S4 在**线性域**钳位（§11.8），交给它的 headroom 也是"SDR 白的线性倍数"，
  而摄影的 1 stop = 光翻倍。sRGB OETF 在白之上近似 γ2.4，码值翻倍 ≈ 2.4 stop 的光——用码值做指数轴会**
  谎报 2.4 倍**，而且显示上限的刻度就得用另一套坐标，两张轴互相矛盾。尾段 bin k 覆盖线性 `[2^(k/8), 2^((k+1)/8))`。
- **4 stop 不是任意数**：`DisplayHeadroom.maximumHeadroom` = 16 = 2⁴，所以任何屏都不可能把值推出最后一格；
  `hdrBins.last` 的含义是"4 stop 或更多"。
- **30 pt/stop 是读数标尺**：窗口 300–364 pt 变宽变窄时"+1 stop"不许跟着变，否则同一张图的高光会随窗口移动。
  只有卡片窄到 SDR 段不足 60 pt 时才压缩 stop 宽度（`HistogramAxis.minimumSDRWidth`），因为照片 95 % 的信息在 SDR 段。
- **两段共用一个峰值**（`HistogramCardFormat.scalePeak`）：排除绘制路径的首末 bin 后取最大值，所以削顶尖峰不会把整张图压平。

**显示上限刻度**：`Histogram.headroom` 随测量一起走（不是读当前屏幕），卡片画在 `log2(headroom)` stop 处
（1.695× → +0.76 stop；SDR → 正好落在 SDR/尾段分界线上）。落在刻度左边的像素这块屏全能显示，右边的是屏丢掉的部分。

**三个比例**（`HistogramChannel`）：`clippedHigh`（>0.999，超过 SDR 白，**不再等于"丢细节"**）、
`clippedCeiling`（S4 钳位处，真正丢掉的细节；headroom=1 时与前者相等）、`clippedLow`。卡片上行依次是
过白 / 削顶 / 削底，过白那个数字仍是高光警告的开关（警告阈值没变，仍按 >0.999 涂色）。

**ROI 一律是画面**：`RenderGraph` 的默认区域 = `plan.origin + plan.content`，**不是** canvas。`fit` 与 1:1
窗口都会 letterbox（`content < canvas`），而 canvas 的 ROI 会把黑边算进 bin 0。窗口帧仍然只测窗口——1:1 下
"存在的画面"就是窗口，整幅图的读数需要另一次渲染，不是换一个 ROI。

**验收**：`HistogramTests`（尾段 1/8 stop、4 stop 钳位、白/白上分界、ceiling 只在钳位处计数、headroom 只动
ceiling 比例、fit 黑边不进 bin 0）+ `HistogramAxisTests`（30 pt/stop、120 pt、窄卡压 stop、单路径跨两段、
削顶尖峰不压平）+ `--ui-smoke`（卡片实际画出的 288 bin、轴宽、上限刻度位置、ROI 不含黑边、削顶文本 = Core 值）。
`photonsctl histogram` 的 JSON 多了 `headroom` / `axis` / `hdrBase64` / `clipping.ceiling`，并新增 `--headroom`
（无 EDR 屏也能验尾段）。

**已知近似**：尾段的 1/8 stop 分辨率靠 `pow` + `log2` 逐像素算，只对白之上的像素付费；SDR 帧只多四次 ceiling 比较。
`Histogram.kernelCompileCount` 是"编译一次/进程"的可断言事实（原先靠 ±2 ms 帧时差判断，在 debug 构建下是噪声）。
