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
| Q5 | **历史与撤销（模型层）** | 无 | `Sources/PhotonsCore/History*.swift`、`Tests/PhotonsCoreTests/History*` | 单测：快照栈 + 游标 + 组级脏标记；`make verify` 绿 | **完成 `c50d2a7`**：EditHistory 338 行 + dirtyGroups，17 项单测 |
| Q6 | **镜头校正能力探测（按文件）** | §11.3 已实测 | `Sources/PhotonsCore/RAWDecoder.swift`（只加不改变现有行为）、`Tests/PhotonsCoreTests/Lens*` | 单测：同一机身两种文件的能力集不同；`make verify` 绿 | **完成 `753d04e`**：`probeLensCorrection` 读能力 → 切一次 → 回读 → 复位；单测守住“未复位会改像素” |
| Q7 | **裁剪/拉直（模型 + 渲染参数）** | M1 geometry 段已支持 crop/rotate | `Sources/PhotonsCore/EditModel+Geometry*`、单测 | 单测：crop 参数 → S0 参数映射；golden 覆盖 crop 一例 | **完成 `a7368ec`**：CropMath + GeometryGroup 显式字段 + 24 项单测 + crop-rot golden |
| Q8 | **缩略图实现（previewImage 通路）** | Q4 规格 | `Sources/PhotonsCore/PreviewImage*.swift`、`Sources/PhotonsCatalog/ThumbnailCache*`、单测 | 单测 + 0.2 s/张 的实测；`make verify` 绿 | **完成 `753d04e`**：ImageIO 优先（比 CIRAWFilter.previewImage 快 2.6×）、t512 冷 63/热 1.2 ms |
| Q9 | **蒙版实现（第一类值 + 线性/径向渐变）** | Q2 规格 ✅ | `Sources/PhotonsCore/Mask*.swift`、`Kernels/s15/s16*.metal`、`RenderGraph.swift`、`Stage.swift` | 单测 + 「masks 为空时 7 个旧键逐字节不变」+ 一帧 golden | **完成 005a/005b `a270f19`**（S1.5 atlas + S1.6 local，空 masks 键不变性已钉）；**005c 完成 `a7368ec`**（画笔/颜色/亮度 + amount=0 位等价）；005d 已派（第 4 轮） |
| Q10 | **XMP 导出实现** | Q3 规格 ✅ | `Sources/PhotonsExport/XMP*.swift`、`Sources/photonsctl/main.swift`、`Tests/PhotonsExportTests/`、`Package.swift` | 往返测试（写→读→比对）+ 不可映射项缺席 | **完成 `5e6993b`**：XMP.swift 835 行 + 20 项往返单测 + `photonsctl xmp export` |
| Q11 | **文档刷新** | Q1 完成 | `docs/architecture-decisions.md`（新增 §12 UI 架构）、`docs/STATUS.md` | `make verify` 仍绿（文档不动代码） | 待开工（主线写） |

| Q12 | **UI 接真数据** | Q1/Q8 | `Sources/PhotonsUI/**`、`Sources/PhotonsApp/**`、`Makefile` | ui-smoke 新增：缩略图命中、滑杆改帧、撤销回原 hash、无历史置灰 | **完成 `0b489a6`**（40 项 smoke：缩略图命中 1.000、滑杆→上屏 p50 62.4/p95 90.8 ms、撤销回原 hash） |
| Q9d | **蒙版 005d** | 005c | `Masks.swift`、`Kernels/s1_5*`、`s1_6*`、`RenderGraph.swift`（蒙版段）、`MaskTests` | tile 与全幅逐像素相等；3 蒙版 @4.1Mpx p95 ≤16.7 ms | **完成 `09cef91`**（feather+refine+tile；3 蒙版 @4.1Mpx p95 16.6 ms；MPS guided filter 实测否决改手写） |
| Q13 | **缩略图服务层** | Q8 | `Sources/PhotonsCatalog/ThumbnailService.swift`、`photonctl/thumbs.swift`、`Tests/PhotonsCatalogTests` | 同键合并一次、取消不写盘、优先级、并发上限、G 通路键不等 | **完成 `0b489a6`**（优先级/合并/取消/并发上限 + G 通路；1000 key 冷批 828 ms，前 20 onScreen 22 ms） |

| Q14 | **缩略图收敛成一套** | Q12/Q13 | `Sources/PhotonsUI/ThumbnailProvider.swift`、`FilmstripController.swift`、`UISmokeRunner.swift`、`scripts/ui-smoke.sh` | 胶片条 36/36 有图；同一 contentHash 只生成一次；DNG 请求 t1024 降级并记 dngCeiling | **完成**：ThumbnailProvider 改成 service 生产者（删自带队列）、胶片条 t256 真图、DNG t1024→t512 生效；ui-smoke **51 项** PASS |
| Q9e | **蒙版 005e** | 005d | `Masks.swift`、`EditModel.swift` 的 showMask、`RenderGraph.swift`、`Kernels/` | 语义不可用→0 覆盖不崩；showMask=nil 像素不变；showMask 一帧性能 | **完成**：语义蒙版（CIRAWFilter matte 全 nil → Vision subject 可用 640×480→512²、nonZero 0.226；sky/hair/skin/teeth/glasses 双路都无→0 覆盖）+ showMask 叠加（≤0.5 ms，showMask=nil 像素不变 `4dfed151…`）；71 项蒙版测试 |
| Q15 | **1:1 + EDR 画面侧** | M3 | `Sources/PhotonsUI/LoupeController.swift`、画布 view、`CanvasPresenter.swift`、`Tests/PhotonsUITests` | 屏幕点↔图像像素往返；倍率 1…8 钳制；逐屏 headroom；SDR 降级 | **完成**：1:1/8:1 按倍率重渲、平移/滚轮/捏合/双击回 fit；逐屏 EDR（1+(maxEDR−1)，钳 1…16）；帧耗时 1:1 首帧 941 ms（全解码）、热 2.4 ms、平移 5.8 ms、4:1 5.3 ms；39 项 UI 测试 |

## 第 2 轮并发约定（已验证有效，第 3/4/5 轮沿用）

三个代码工作流同时跑，但**各自用独立 scratch 路径**（`swift build --scratch-path /tmp/photons-<q>`），
不跑 `make verify`（`.build` 会互相踩）；由主 session 在所有分支落盘后统一跑一次 `make verify` 定档。

## 第 5 轮遗留的已知问题（必须先看，别当已修）

1. **showMask 与撤销**：`HistoryDirty.isSemanticallyIdentical` 不比 `showMaskID`，所以“只改 showMask”对 commit 是 no-op → undo 后 overlay 会被快照清掉。修法二选一：①`CatalogSession.undo/redo` 恢复快照后把当前 `showMaskID` 贴回去（推荐，showMask 是视图态不是编辑）②把它纳入比较（会让每次开关蒙版都产生历史）。**未修**，等接 UI 时一起做。
2. **1:1 的窗口是用 crop 模拟的**：`RenderGraph` 只有 `canvas`/`scale`，于是 S3c 暗角与蒙版 feather 会按可见窗口归一化；S0 的归一化旋转使 9° 拉直下的窗口投影约有 **0.29%** 偏差（已有测试量化）。正解是核心加一个 “output window rect”（见 Q21）。
3. **Vision 语义 matte 冷启 235 ms**（原估 ≤120 ms）；缓存命中 0.003 ms。若接 UI 实时预览需在导入期预热。
4. **外接 27G7K-Ultra 的 maxEDR 也是 1.2**（不是 SDR），所以现在两台屏都走 HDR 路径；SDR 降级只在 maxEDR ≤ 1 时触发。
5. UI 与 CLI 已补 `RenderInput.sourceURL`（loupe 与 `photonsctl render/bench`），否则 `CIRAWFilter` 语义路线在 App 里是死的。

## 第 6 轮候选（按依赖排序，可直接派）

| # | 工作流 | 前置 | 文件所有权 | 验收 |
|---|---|---|---|---|
| Q16 | **编辑持久化进库**：`develop_json` / `edit_history` 表落盘 + 打开库时恢复 | M2 + 历史（c50d2a7） | `Sources/PhotonsCatalog/**`（迁移 v3）、`Sources/PhotonsCore/History.swift`（只读调用） | 改一个滑杆 → 重开库 → 像素 hash 一致；`edit_history` 行 1:1 映射；迁移自动快照 |
| Q17 | **方向映射**：EXIF orientation（含 `irot`）在解码与预览两条路都应用 | M3.5 | `Sources/PhotonsCore/PreviewImage.swift`、`RAWDecoder.swift` | `L1030433.dng` 180° 修正；方向矩阵 8 种组合单测；golden 更新说明 |
| Q18 | **M5 预设 + 复制粘贴设置** | 历史 | `Sources/PhotonsCatalog/Presets*`、`Sources/PhotonsCore/EditModel.swift`（只加不改变语义） | 预设往返 Codable；复制粘贴只带非默认字段；单测 |
| Q21 | **核心 output window rect**：`RenderOptions.windowRect` 替代“用 crop 模拟取景”，暗角/feather 按整帧归一化 | Q15 | `Sources/PhotonsCore/RenderGraph.swift`、`Stage.swift`（键）、`s0_geometry.metal` | 9° 拉直下窗口中心与整帧渲染逐像素对齐（<0.001）；1:1 平移一帧 p95 不退化 |
| Q22 | **蒙版 UI**（画笔拖拽、叠加显示开关、语义蒙版菜单）+ showMask 历史修法 | Q9e | `Sources/PhotonsUI/**`（新 MaskOverlayController） | 画一笔 → 蒙版覆盖变化且可撤销；showMask 开关不进历史 |
| Q19 | **批量导出 + 导出对话框** | M5 | `Sources/PhotonsExport/**`、`Sources/PhotonsUI/**` | 20 张批量导出、命名模板、失败逐个报告 |
| Q20 | **文档 §12：UI 架构** | Q12/Q15 | `docs/architecture-decisions.md` | 只写文档；主线写，不派子代理 |

## 排序原则

- 先在跑的四项各自独立；Q5 是唯一**现在就能与 Q1 并行**的纯模型工作（新文件，不碰 `PhotonsCore` 现有文件）——Q1 完成后立刻派。
- Q6/Q7 都要改 `PhotonsCore` 现有文件或 golden，**必须串行**在 Q1 之后。
- Q8/Q9/Q10 依赖各自的规格文档，规格一到就派，彼此文件不重叠，可三项并行。
- 每轮 3 个子代理同时写代码（实测有效：终态可控、互相不踩）（本机编译 8 核，再多会互相抢 CPU 且 `make verify` 变慢）。

## 明确不做（除非用户改口径）

多帧 HDR/超解析、自写 demosaic、DNG 导出、打印/幻灯片/地图/视频/人脸、AI 模型自研。
