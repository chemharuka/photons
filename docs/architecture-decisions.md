# 架构决策定稿（9 份源码精读 + 本机实测汇总）

> 生成：2026-10-25 · 依据：`darktable.md` `rawtherapee-art.md` `rapidraw.md` `ansel-vkdt.md` `digikam.md` `apple-raw-stack.md` `licensing.md` `lightcraft-engine.md` `lightcraft-product.md`
> 状态：可行范围已验证（探针可复跑）；**代码一行未写**

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
| v9 全尺寸耗时 | 60MP **5.05s** / 33MP 3.92s / 24MP 1.81s（v8 为 0.50/0.50/0.19s）→ **8–10×** | `rawcover` |
| 解码→线性纹理 | `rgba16Float` **0.566s @ 60MP = 106.5 Mpx/s**；`rgba32Float` 0.396s，|RGBAh−RGBAf|max=0.00049 | `arch` 探针 |
| EDR 余量 | 线性最大值 **1.748**，45027 个采样 >1.0 | 同上 |
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

**结论修正**：v9 的价值是"Apple 的 ML 降噪 + 噪声模型回加"，而非重做去马赛克。这不削弱"深度绑定 Apple 管线"的决策——反而说明**降噪这一最难自己做的部分由系统免费提供**，而 demosaic 本来就是 v8 级别的成熟实现。

## 3. 已定决策（含依据与代价）

| # | 决策 | 依据 | 代价 / 风险 |
|---|---|---|---|
| D1 | 解码只用 `CIRAWFilter`，**不引入 LibRaw** | `licensing.md`：LibRaw 画质倒退 + LGPL/CDDL 义务；Apple 941 机型覆盖主流 | 绑 OS 版本；冷门/后背/电影机缺失；拿不到马赛克 |
| D2 | **交互用 v8，导出用 v9**，作为用户可见的"质量档位" | v9 慢 8–10×；Apple 自己默认 v8 | 两档画质差异要在 UI 说清 |
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

- `v9-vs-v8-measured.md`（白名单机身的真实 RAW 对比）仍在跑
- Apple 解码器的**确定性**未实测 → M0 第一件事
- `linearSpaceFilter` 的语义（能否把我们的处理插进 Apple 管线内部）未实验 → 决定"捆绑深度"上限
