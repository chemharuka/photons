# 并行工作队列（用户离线时的连续作业清单）

> 目的：用户离开时，主 session 按本表连续派发子代理，不必等待人类决策。
> 规则：**一个工作流一组文件所有者**；同一时刻同一文件只有一个所有者；每个工作流自带可执行验收，
> 红了不许 reporting done；任何工作流都不许 `git commit`（由主 session 统一验收后提交）。
> 更新方式：每完成一项，在这里把它挪到「已完成」并写一行结果 + 验收输出摘要。

## 判定是否可开工的三条

1. 规格已落盘（`docs/tasks/*.md`），且规格里有可执行验收；
2. 不依赖另一工作流尚未合入的改动；
3. 文件所有权不与在跑的工作流重叠。

## 队列

| # | 工作流 | 前置 | 文件所有权 | 验收（必须跑） | 状态 |
|---|---|---|---|---|---|
| Q1 | **M3 UI 骨架**（004） | 004 规格 ✅ | 同上 | 同上 | **完成 `b1c58ec`**：verify ALL GREEN（60 单测、bench p95 5.67ms）、app 起窗 1600×940、ui-smoke 18 项；10k 占位网格 p99 1.87ms |
| Q2 | **M4 蒙版规格**（005） | — | `docs/tasks/005-masks.md` | 文档自洽（无代码验收） | **完成**：`docs/tasks/005-masks.md` 242 行（S1.5 atlas + S1.6 local 两段；masks 为空时键环整段省略） |
| Q3 | **XMP 映射规格** | — | `docs/xmp-mapping.md` | 文档自洽 | **完成**：`docs/xmp-mapping.md` 248 行（5 个不可映射；温度锚点只能平移不能换算） |
| Q4 | **M3.5 缩略图规格**（006） | — | `docs/tasks/006-thumbnails.md` | 文档自洽 | **完成**：`docs/tasks/006-thumbnails.md` 156 行（内容寻址 JPEG 缓存；首屏热 p95 ≤80ms） |
| Q5 | **历史与撤销（模型层）** | 无 | `Sources/PhotonsCore/History*.swift`、`Tests/PhotonsCoreTests/History*` | 单测：快照栈 + 游标 + 组级脏标记；`make verify` 绿 | 已派（第 2 轮） |
| Q6 | **镜头校正能力探测（按文件）** | §11.3 已实测 | `Sources/PhotonsCore/RAWDecoder.swift`（只加不改变现有行为）、`Tests/PhotonsCoreTests/Lens*` | 单测：同一机身两种文件的能力集不同；`make verify` 绿 | 待开工（**与 Q1 冲突，须等 Q1 完成**） |
| Q7 | **裁剪/拉直（模型 + 渲染参数）** | M1 geometry 段已支持 crop/rotate | `Sources/PhotonsCore/EditModel+Geometry*`、单测 | 单测：crop 参数 → S0 参数映射；golden 覆盖 crop 一例 | 待开工（文件与 Q1 不冲突，但 golden 与 Q1 冲突 → 排在 Q1 后） |
| Q8 | **缩略图实现（previewImage 通路）** | Q4 规格 | `Sources/PhotonsCore/PreviewImage*.swift`、`Sources/PhotonsCatalog/ThumbnailCache*`、单测 | 单测 + 0.2 s/张 的实测；`make verify` 绿 | 待 Q4 |
| Q9 | **蒙版实现（第一类值 + 线性/径向渐变）** | Q2 规格 ✅ | `Sources/PhotonsCore/Mask*.swift`、`Kernels/s15/s16*.metal`、`RenderGraph.swift`、`Stage.swift` | 单测 + 「masks 为空时 7 个旧键逐字节不变」+ 一帧 golden | 已派（第 2 轮，005a/005b） |
| Q10 | **XMP 导出实现** | Q3 规格 ✅ | `Sources/PhotonsExport/XMP*.swift`、`Sources/photonsctl/main.swift`、`Tests/PhotonsExportTests/`、`Package.swift` | 往返测试（写→读→比对）+ 不可映射项缺席 | 已派（第 2 轮） |
| Q11 | **文档刷新** | Q1 完成 | `docs/architecture-decisions.md`（新增 §12 UI 架构）、`docs/STATUS.md` | `make verify` 仍绿（文档不动代码） | 待 Q1 |

## 第 2 轮并发约定

三个代码工作流同时跑，但**各自用独立 scratch 路径**（`swift build --scratch-path /tmp/photons-<q>`），
不跑 `make verify`（`.build` 会互相踩）；由主 session 在所有分支落盘后统一跑一次 `make verify` 定档。

## 排序原则

- 先在跑的四项各自独立；Q5 是唯一**现在就能与 Q1 并行**的纯模型工作（新文件，不碰 `PhotonsCore` 现有文件）——Q1 完成后立刻派。
- Q6/Q7 都要改 `PhotonsCore` 现有文件或 golden，**必须串行**在 Q1 之后。
- Q8/Q9/Q10 依赖各自的规格文档，规格一到就派，彼此文件不重叠，可三项并行。
- 每轮最多 3 个子代理同时写代码（本机编译 8 核，再多会互相抢 CPU 且 `make verify` 变慢）。

## 明确不做（除非用户改口径）

多帧 HDR/超解析、自写 demosaic、DNG 导出、打印/幻灯片/地图/视频/人脸、AI 模型自研。
