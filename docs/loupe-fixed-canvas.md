# Loupe 渲染架构决策：固定画布 + 可见窗口

状态：**提案，待 spike 验收**
日期：2026-10-31
适用：`Sources/PhotonsUI/LoupeController.swift` 及其帧路径
前置：P1–P3、P5a 已合入（`LoupeViewport` / `LoupeCamera` / `LoupeFrameRequest` / `LoupeCompareSession`）

---

## 0. 与现状对照

| 维度 | 现状：混合式 + backdrop + bridge | 新方案：固定画布 + 窗口 |
|---|---|---|
| 渲染路径 | 两条（fit 全幅缩比 / actual 窗口）+ 三套连续性机制 | **一条**（canvas / window / scale） |
| 每帧输出像素 | fit = 视口；1:1 = 视口 | 交互 4K（8.3 MP）；停手 6K（≤20 MP） |
| 60 MP 每帧 | 约 8–10 ms | 约 8–12 ms |
| 150 MP 每帧 | 窗口约 10–20 ms；fit 约 20–30 ms | 约 8–12 ms（4K）；停手 20–28 ms |
| 内存（60 MP） | 解码 482 MB + 窗口纹理 | 482 MB + 66 MB + 160 MB ≈ 0.7 GB |
| 内存（150 MP） | 1.21 GB + 窗口纹理 | 1.21 GB + 66 MB + 160 MB ≈ 1.45 GB |
| 连续性 | backdrop 填边 + 180 ms 缩放桥 + stale 丢弃 | 上一张完整画布原样兜底；**不做几何变换** |
| 黑边/脱影 | 靠 backdrop 掩盖；机制失效时出现 | **结构上不可能**（每帧满覆盖） |
| 1:1 / 400% 画质 | 原生 `scale = zoom` 重采样 | 相同（同一 window + scale） |
| 直方图 | 屏幕帧 + window frame 后台整图测量补丁 | 独立 fit 小渲染，按 key 缓存 |
| 窗口 resize | 触发合并重渲 + 旧画布丢弃 | **不重渲**，图层缩放 |
| 缩放过渡 | 180 ms 相似变换动画 | 直接切（无动画；可加透明度过渡） |
| 高 DPI 屏幕 | 每次按视口设备像素出帧，锐 | 交互档略软，停手档补齐 |
| 代码规模 | `LoupeController` 6,916 行 | 约 5,500–5,800 行（删 1,000–1,500） |
| 复杂度所在 | **时序**（桥、backdrop、in-flight、stale） | **坐标**（window 传参），局部且可测 |
| 成熟度 / 风险 | 已验证，行为稳定 | 需 spike；有 `LoupeRenderMode.current` 可回退 |
| 适合场景 | 稳定优先、短期不动机器 | 150 MP 长期、想删掉补偿机制 |

**现状的优点**：fit 与 1:1 各自只算必要的像素；缩放有动画、观感连续；直方图已有可用实现；所有边界都被 2,000+ 测试踩过。

**现状的缺点**：三套补偿机制互相咬合，黑边/旧帧错位一类 bug 依赖时序复现；resize 必须重渲；window 帧不能直接出直方图；代码与不变量数量都到顶。

**新方案的优点**：单一渲染形状；每帧满覆盖，黑边从状态机里消失；resize 免费；成本与源图像素数解耦（150 MP 与 60 MP 同价）；直方图与导出路径统一；预计少 1,200 行。

**新方案的缺点**：交互档在 6K 屏上略软，需要停手档补；每帧都渲染，GPU 占用比「只渲窗口 + 复用」略高；没有缩放动画，观感更「硬」；150 MP 下 4K 是否真能 ≤ 12 ms 必须实测；重写帧路径本身有回归风险。

---

## 1. 要解决的问题

现在的 loupe 有两条渲染路径：

- **fit**：`canvas = viewport`、`outputWindow = nil`、`scale = fitZoom`，整幅缩比
- **1:1 及以上**：`canvas = viewport`、`outputWindow = 可见源矩形`、`scale = zoom`，只出窗口

两条路径本身不复杂。复杂的是**连续性**：新帧没到时，屏幕上那张旧图覆盖的是旧视口，相机一动，新视口就有一块没有像素——用户看到的「黑色脱影」。

为了填这块，现在有三套机制：

| 机制 | 作用 |
|---|---|
| backdrop（整幅低清渲染） | 任何新视口都能取到像素 |
| zoom bridge（180 ms 相似变换） | 缩放切换时把旧图摆到新位置 |
| `canvasSizeBox` + stale canvas 丢弃 | resize 后丢掉旧画布的帧 |

再加上 `pictureCoverage`、window frame 不出版直方图、045 的整图后台测量，这一整套都是「帧慢 + 帧覆盖不全」的衍生品。

**根因不是渲染慢，而是呈现了覆盖不全的帧。**

---

## 2. 决策

**固定画布 + 可见窗口渲染，单一路径；每帧都覆盖整个画布。**

```
canvas  = 交互 4K（固定长边 3840，约 8.3 MP）
        / 停手 窗口设备像素（上限 6K，约 20 MP）
window  = 相机可见的源像素矩形；fit 时 = 整幅裁切
scale   = zoom（canvas 像素 / 源像素）
每帧一次 graph.render(edit, canvas, window, scale)
呈现    = 纹理铺满画布；新帧未到时保留上一张完整画布，不做几何变换
```

- fit 不再是模式，只是 `window = 整幅` 的一种相机状态
- 1:1 / 400% 也是同一条：`window` 变小、`scale` 变大
- 画布固定，窗口 resize **不触发渲染**，只缩放图层
- 因为每帧都覆盖画布，**不存在「未渲染区域被移进来」这个状态**，backdrop 与桥没有存在理由

### 2.1 为什么不是另外两种

| 方案 | 150 MP 下的问题 |
|---|---|
| 一次渲染 + 位图变换（RapidRAW 式） | 常驻 1.21 GB 输出 + 1.21 GB 输入；每次编辑 70–90 ms；1:1 只看 20 MP 却付 150 MP |
| 全局按比例（RawTherapee 式） | 1:1 要渲染整幅 150 MP；成本随像素数涨，而视口不变 |
| **固定画布 + 窗口** | 成本 ∝ 画布像素，与源图 60/150 MP 无关 |

---

## 3. 架构细节

### 3.1 坐标系

沿用 `LoupeFraming` / `LoupeViewState` 现有约定：

- `zoom` = 画布像素 / 源像素
- `center` = 落在画布中心的源像素；fit 时中心被忽略
- `window` = 源像素矩形，由 `framing.outputWindow(of:)` 给出；fit 时为整幅 crop
- `scale` 直接等于 `zoom`，不是 1

`LoupeViewport` 增补一个纯方法（P1 的 seam 上补，不新建类型）：

```swift
public func window(for canvas: ImageSize) -> ImageRect?   // fit 返回 nil，其余同 framing.outputWindow
```

### 3.2 画布档位

| 档 | 尺寸 | 用途 | 60 MP 实测/推算 | 150 MP 推算 |
|---|---|---|---|---|
| 交互 | 长边 3840（8.3 MP） | 拖动、缩放、滑杆 | 8–12 ms | 8–12 ms |
| 停手 | 窗口设备像素，上限 6K | 停手后的清晰画面 | 20–28 ms | 20–28 ms |
| 导出 | 全幅 crop × scale | 导出 | 57 ms（60 MP 全幅） | 70–90 ms |

- 交互档与停手档**调用形状完全相同**，只是 canvas 不同
- 画布不随窗口尺寸变化；窗口变大时由合成器放大（轻微软），超过阈值（如 1.25×）才重建停手帧
- 150 MP 下 4K 画布的成本主要由输出像素决定，不与源图线性相关；实测需用 §5.4 的压力跑法确认

### 3.3 兜底帧

- 保存「最后一张完整呈现的纹理 + 它的 canvas」
- 相机变化后、新帧到达前，**原样呈现**（不按相机位移变换）
- 效果：画面最多滞后半帧到一帧，但**永远满覆盖，不会露黑**
- 不做「变换上一帧」：那正是黑边来源；也不做 backdrop

### 3.4 直方图与测量

- 直方图不再从屏幕帧取：每次编辑 key 变化后，单独渲染一次 **fit 比例的小画布**（长边 1024–2048），从它的线性纹理测量
- `Histogram.cacheKey`（rung + edit digest + bins）继续做缓存键
- 删除：`pictureCoverage`、`histogramWholePictureCoverage`、window frame 的 `"window frame"` 失败标记、`PictureRequest` 后台测量整条支线
- 收益：任何缩放下的直方图都是整幅，不再有「窗口帧不出数」的分支

### 3.5 裁切 / 蒙版 / 暗角

- 仍然必须传对 `window`：这些 stage 在整幅坐标里定义，渲染时按窗口采样
- `LoupeFraming` 的投影、`cropZoomLimit`、裁切框「⊆ 画布」的钳制**不动**
- `fitScale`（裁切工作区 90%）继续进 `RenderOptions.neverUpscalesContent`
- 这是删不掉的局部复杂度；但错了表现为「蒙版位置偏」，不是「偶发黑边」

### 3.6 resize / EDR / 导出

- resize：不重渲；停手帧的设备像素密度变化超过 25% 才重建
- EDR：输出仍是 half-float，`displayHeadroom` 路径不变
- 导出：原本就是全幅 canvas，不受影响；屏幕与导出共享同一条 `render(edit, canvas, window, scale)`

---

## 4. 代码变更清单

### 4.1 保留

| 文件/符号 | 理由 |
|---|---|
| `Loupe/LoupeViewport.swift` | 相机值类型，新架构的输入 |
| `Loupe/LoupeCamera.swift` | 目标状态计算；S4 可去掉档位吸附 |
| `Loupe/LoupeFrameRequest.swift` | render options 的唯一映射 |
| `Loupe/LoupeCanvasView.swift` | 画布视图 |
| `Loupe/LoupeCompareSession.swift` | 与帧路径无关 |
| `LoupeZoom.swift` 的 `LoupeFraming` / `LoupeViewState` | 投影与状态 |
| `cropTool`、蒙版叠加层、`present` 的单入口 | 行为资产 |

### 4.2 删除（S3，切默认并验收后）

- `outputWindow == nil` 的 fit 专用分支（`makeJob` / `renderFrame` 内）
- `armZoomBridge`、`movesScale`、`presentZoomBridgeFrame`、bridge 的计时与 tick
- backdrop：整幅低清渲染、`presentBackdrop`、背景 quad、`BackdropScale` 相关路径
- `canvasSizeBox`、`staleCanvasDrops`、live-resize 的「不渲染」分支
- `pictureCoverage`、`histogramWholePictureCoverage`、`"window frame"` 标记、`PictureRequest` 整图后台测量
- `requestResizeRender` / `resizeCoalesced` / `resizeRequests`
- `LoupeCamera.stepped` 的档位吸附（S4；菜单档位保留为 UI）
- `frameMode` 的 fit/actual 二元判断（fit 变成 window=整幅）

### 4.3 修改

- `renderFrame`：只保留一条 `render(edit, canvas: tier, window, scale)`；相机/文档/generation 快照机制不变
- `present`：一条路径；兜底帧不参与几何变换
- `requestViewportRender`：交互档合并请求；停手档由「120 ms 静默」触发
- `LoupeFrameRequest`：`canvas` 改为档位尺寸，`contentRect` 仍为窗口
- `Histogram`：改为独立的 fit 小渲染，按 key 缓存

### 4.4 预期规模

- 删除约 1,000–1,500 行（bridge + backdrop + resize 合并 + window 直方图分支）
- 新增约 150–250 行（档位切换、兜底帧、独立直方图小渲染）
- `LoupeController` 从 6,916 行降到约 5,500–5,800 行

---

## 5. 实施阶段

### S1 — Spike（开关，不动默认）

- 新增 `LoupeRenderMode { .current, .fixedCanvas }`，由环境变量或 `photonsctl` 参数打开
- 只实现：4K 交互画布 + 窗口渲染 + 兜底帧；**不删任何旧代码**
- 停手档暂不实现，先看交互档是否够快、画面是否正确
- `--trace-stages` 增加每帧的 canvas/window/scale 打印，便于对照

**退出条件**：fit / 100% / 200% / 400% 四张截图与现路径逐像素一致（当画布 = 视口时应当一致）；平移/缩放 p50 有数。

### S2 — 停手档与默认切换

- 120 ms 静默后按设备像素重建（上限 6K）
- 把 fixed 设为默认；旧的 window 路径保留一个版本，可回退

### S3 — 删除旧路径

- 按 §4.2 删除；跑全量 UI 套件
- `LoupeRenderTests`、`LoupeZoom*`、`Crop*`、`Histogram*`、`BeforeAfterUITests` 必须全绿

### S4 — 连续缩放（可选）

- 去掉 `LoupeCamera.stepped` 的吸附；档位只作为菜单快捷值
- 缩放不再触发 bridge（已删），连续 wheel/pinch 直接改相机

---

## 6. 验收

### 6.1 像素

- 画布 = 视口尺寸时，fixed 路径与现路径在 fit / 100% / 200% / 400% 应输出**同一 SHA**（同一 `RenderOptions` 的 `canvas/scale/outputWindow`）
- 差异只允许出现在画布档位不同（4K vs 视口）时；此时用 ΔE2000 ≤ 1 的抽样断言

### 6.2 计时（M1 Pro，release，`photonsctl bench` 口径）

| 指标 | 目标 |
|---|---|
| 交互帧 p50（4K 画布，60 MP） | ≤ 12 ms |
| 交互帧 p50（4K 画布，150 MP 压力） | ≤ 15 ms |
| 停手帧 p50（6K 画布） | ≤ 30 ms |
| 平移 1 秒内的帧数 | ≥ 50 |
| 滑杆拖动 p50 | ≤ 20 ms（沿用 preview rung） |

### 6.3 内存

- 60 MP：解码 482 MB + 4K 66 MB + 6K 160 MB ≈ 0.7 GB
- 150 MP：1.21 GB + 66 MB + 160 MB ≈ 1.45 GB
- 换图后 2 秒内释放上一张的纹理

### 6.4 150 MP 压力跑法

没有 150 MP 样张时，用 60 MP 文件跑：

```sh
.build/release/photonsctl bench ~/Desktop/test/L1030433.dng \
  --viewport 14204x10652 --scale 1 --iterations 20
.build/release/photonsctl render ~/Desktop/test/L1030433.dng \
  --edit Tests/Fixtures/edit-neutral.json --out /tmp/stress.tiff \
  --scale 2.5 --decode-scale 1 --bits 16
```

计时口径有效（输出像素与带宽同量级），画面内容不等价，只用于性能验收。

### 6.5 行为

- 快速拖动、滚轮连续缩放、捏合、双击 1:1、Z 回 fit：全程无黑边、无旧帧错位
- 裁切模式进出、90% fit、旋转/拉直、蒙版叠加层位置正确
- 对比/原图切换不受影响

---

## 7. 风险与回退

| 风险 | 触发条件 | 回退 |
|---|---|---|
| 400% 画质下降 | 4K 画布在 6K 屏上被放大 | 停手档 6K；或 400% 时按视口设备像素出帧 |
| 150 MP 下 4K 画布仍超 15 ms | 采样/带宽 | 交互档降到 3K（7 MP）或 1440p |
| 直方图小渲染与屏幕不一致 | 采样网格不同 | 保留 `Histogram.frameSampleLongEdge` 同一网格；差异 > 1% 时回退到旧路径 |
| 停手帧抖动 | 阈值过小 | 密度阈值 25%、静默 120 ms，可调 |
| 删除桥后缩放「跳」 | 帧迟到 | 兜底帧保满覆盖；若仍跳，S4 再加 80 ms 短过渡（只做透明度，不做几何） |

开关必须保留到 S3 验收通过；`LoupeRenderMode.current` 在 S3 删除前一直是可回退路径。

---

## 8. 与现有拆分的关系

- P1/P2/P3/P5a 的产物全部保留，正好是新架构的相机层与状态层
- **不要继续拆帧生产（原 P4b）**：`RenderJob` + 两个队列 + bridge/backdrop 会被整段重写，先拆等于白拆
- 蒙版编辑器、裁切会话、测量的模块化，等 S2 之后围绕新形状做，避免返工
- `LoupeController` 在 S3 之后预计 5,500–5,800 行，再继续按模块拆

---

## 9. 给派单 session 的规格提纲

S1 单独立项（建议编号 205），规格必须包含：

1. `LoupeRenderMode` 开关与环境变量名；默认 `.current`
2. fixed 路径的 `makeJob`/`renderFrame` 分支：`canvas = 3840 长边`、`window`、`scale = zoom`；不触碰旧路径
3. 兜底帧：保存最后一张完整纹理与 canvas；相机变化时原样呈现，不做变换
4. `--trace-stages` 输出 `canvas/window/scale`
5. 验收：四档截图 SHA 与现路径一致；`photonsctl bench` 计时；`LoupeRenderTests` + `LoupeZoom*` + `Crop*` 全绿
6. 明确禁止：S1 不删 backdrop/bridge、不改 `setViewState`、不动直方图路径

---

## 附录 A：2026-10-31 实测基线

| 项 | 值 |
|---|---|
| 机器 | M1 Pro，release |
| 样张 | `~/Desktop/test/L1030433.dng`，9520×6336 = 60.32 MP，解码器 v8 |
| 全幅 20 阶段 | p50 **56.8 ms**，p95 71.8 ms（`bench --viewport 9520x6336`，20 次，cache off） |
| GPU only | p50 55.3 ms |
| 解码 | 0.85–0.96 s（CLI 口径）；文档记录 0.50 s（v8）/ 5.05 s（v9） |
| 全幅导出 16-bit TIFF | 2.97–3.61 s 全程（含 353 MB 写盘） |
| 60 MP `rgba16Float` | 482 MB |
| 150 MP 推算 | 1.21 GB/帧；全幅 70–90 ms（M5 Pro）；4K 画布 8–12 ms |
