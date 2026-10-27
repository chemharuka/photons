# 裁切与旋转 — 诊断（根因、证据、改动清单）

工作区：`/tmp/photons-wt-cropfix`（分支 `feat/cropfix`，基点 `main@73eca0b`）。基线未修。
本文只写结论与证据，不写代码。所有数字都是在本机上用 XCTest 跑出来的（探针：`Tests/PhotonsUITests/CropShearProbeTests.swift`、
`Tests/PhotonsUITests/CropToolWiringProbeTests.swift`）。

---

## 0. 一句话根因

**旋转被写在「各轴分别归一化」的坐标里，而不是「像素等度」的坐标里** —— 对 `(u−0.5, v−0.5)` 做 R(θ) 时，
u 除以的是宽、v 除以的是高，于是 R 之后又被两个不同的尺度乘回去，几何上等于
`rot(θ) ∘ aniso(W/H)`。这不是相似变换：两个基向量既不等长也不正交，所以画面是**被剪切（shear）**的，
框是**被剪切又转过去**的（不是纯旋转），竖屏因为 W/H 取倒数，剪切方向也反了。

同一个错误在两个地方各写了一遍（两处同源）：

| 位置 | 代码事实 |
|---|---|
| `Sources/PhotonsUI/LoupeZoom.swift:991-1001` | `u = (viewX−originX)/contentWidth`，`v = (viewY−originY)/contentHeight`，然后 `o=(u−.5, v−.5)`、`R(θ)`、再 `× cropWidth / × cropHeight` |
| `Sources/PhotonsCore/Kernels/s0_geometry.metal:112-121` | `uv = framePx / frameSize`（逐轴），`o = uv − 0.5`，`R(θ)`，然后 `px = (crop.xy + r·crop.zw)·srcSize`（逐轴） |

这是**像素级**的：S0 是唯一把旋转落到像素上的地方，所以屏幕上「看起来像倾斜 + 旋转」的那张图就是它出来的；
`LoupeMapping` 是同一套错误约定的逆，因此 overlay 的框、命中测试、拖拽手感同时错。

---

## 1. 症状 3（横屏也 shear）— 同一根因，矩阵级证据

`main@73eca0b`，`LoupeMapping.sourcePoint` 的两个基向量（view 的 1 px 步长映射到 source 的位移）：

| 用例 | \|e1\| | \|e2\| | \|e2\|/\|e1\| | cos(e1,e2) | 结论 |
|---|---|---|---|---|---|
| 1200×800, 9°, viewport 1200×800 | 0.993179 | 1.015180 | **1.0222** | **−0.1277** | 不等长、不正交 → shear |
| 1200×800, 9°, viewport 1000×800 | 1.191815 | 1.218216 | 1.0222 | −0.1277 | 同上（缩放无关） |
| 1200×800, 45° | 0.849837 | 1.274755 | **1.5000** | **−0.3846** | W/H = 1.5，完全暴露 |

正确口径：相似变换要求 `|e1| = |e2|` 且 `cos(e1,e2) = 0`（行列式 > 0，纯旋转 + 等比缩放）。
按修好的口径，9° 应给出 `e1 = (cos9°, sin9°)·s`，即 ratio = 1.000000、cos = 0.000000。

---

## 2. 症状 4（裁切框跟着转）— 与症状 3 同源，且比「转」更糟：是斜的平行四边形

overlay 的四角来自 `Sources/PhotonsUI/CropTool.swift:209-216`（`layout(…).view()` → `mapping.viewPoint`），
和照片共用同一个带剪切的逆映射，所以框不是「轴对齐矩形」，也不是「纯旋转的矩形」，而是**平行四边形**。
实测（1200×800，crop = (0.1, 0.2, 0.5, 0.4)，9°）：

```
corners = [(256.76, 267.00), (849.38, 216.94), (943.24, 533.00), (350.62, 583.06)]
topEdge  = (592.61, −50.06)      leftEdge = (93.86, 316.06)
dot(top,left) = 39801.4          （矩形要求 ≈ 0）
```

口径（已按用户要求定）：**照片 = 纯旋转 + 等比缩放；overlay 的手柄框 = 屏幕坐标系里轴对齐的矩形**。
实现上这要求 crop 矩形活在「已拉直的 frame 空间」里（S0 的输出空间），view↔frame 的映射必须是
**无旋转的等比缩放**；旋转只出现在 frame→source 那一步（给取色/蒙版用），不进 overlay。

---

## 3. 症状 2（竖屏）— 同一根因的镜像面，且更严重

竖屏下 W/H 取倒数，剪切方向反过来（cos 由 −0.1277 变 +0.1277，ratio 由 1.0222 变 0.9783）：

| 用例 | \|e2\|/\|e1\| | cos(e1,e2) |
|---|---|---|
| 800×1200, 9°（物理竖幅） | 0.978328 | **+0.127703** |

除此之外竖屏**没有**第二个独立的宽高交换 bug：所有 crop 几何都走 `CatalogSession.maskSourceSize`
（`LoupeController.swift:2529`, `CropToolController.swift:175`），那是渲染器 ingest 之后的正立帧，
不是 `asset.width/height`；`CropToolTests` 里已有两条竖屏用例（`testTheCornerYouDragLandsUnderTheHandInPortraitToo`,
`testTheStoredFrameWouldPutTheCornerSomewhereElse`）在基线上是绿的。所以竖屏要修的是「等度」，
不是「换轴」。EXIF orientation 6/8（横幅像素 + 转置）和物理竖幅在 ingest 之后是同一件事（都由
`maskSourceSize` 表达），修好后两者用同一组断言覆盖。

---

## 4. 症状 6（框内拖动方向反了）— 独立的一处符号，不与上面同源

代码采用的是「**照片固定、框移动**」的模型（`previewEdit` 把 crop 置 `.full`，整幅图按 fit 画在画布上，
框是 overlay）。但 `Sources/PhotonsUI/CropTool.swift:487-494` 的 `.inside` 分支写的是

```swift
left = min(max(base.left - dx, 0), 1 - width)   // dx = 手的位置 − 抓取点
```

`− dx` 让框与手**反向**走：手往左 100 pt，框往右 100 pt。用户在屏幕上读到的就是「拖的是画布，而且方向是反的」。
正确口径：框跟手同号、等幅（手往左 100 pt，框左边界往左 100 pt），到边界按既有 clamp 停住；
框不再被钉在一处（现在它反而在动，但是反向），所以「框一直居中」的错觉也一起消失。

---

## 5. 症状 1（完全看不到）— 在 73eca0b 上无法复现为接线 bug；真问题是没有任何测试钉住这条路径

用**真实的** `EditorWindowController` + 真实 `WorkspaceRootView` + 真实 `NSWindow` 复现菜单路径（`CropToolWiringProbeTests`）：

```
item enabled=true
responder chain = LoupeCanvasView -> NSView -> LoupeController -> NSView -> WorkspaceRootView -> NSWindow -> EditorWindowController
afterAction active=true
overlay hidden=false frame=(0.0, 0.0, 896.0, 864.0) super=NSView
overlay layout corners=[(148,232),(748,232),(748,632),(148,632)]
cropBar hidden=false frame=(137.0, 12.0, 622.0, 34.0)
```

即：菜单项、responder chain、`loadView` 的挂载、`refreshCropTool` 的显示、bar 的布局，全部在 HEAD 上是通的。
（唯一返回 `false` 的是 headless 里 `NSApp.sendAction(to: nil)`——因为测试进程没有 key window，属测量伪影，不是 app 行为。）

所以「看不到」的**可复现缺口**是覆盖缺口 + 静默早退，不是丢失的挂载：

* `LoupeController.swift:2545` 的 `guard session.mode == .loupe, session.anchorID != nil else { return false }`
  与 `EditorWindowController.swift:295` 的校验条件相同 —— 在「没有 anchor / 不在单图」的窗口里，⌘R 和菜单项
  会**静默失效**（菜单变灰、快捷键无反馈），用户看到的就是「按了没反应」。
* `Tests/PhotonsUITests/CropToolTests.swift` 的 19 条全部绕过 `beginCropTool()`/`loadView`
  （直接 `loupe.cropTool.begin()` 或只测 `CropToolController`），所以「overlay 有没有上屏」从来没被断言过 ——
  这正是这条 bug 能活下来的原因。

处置：① 增加一条**真挂载**回归（overlay superview 非空、`isHidden == false`、frame 非零、layout 四角有限、
叠加顺序在 canvasView 之上）；② `beginCropTool()` 早退时给出可见反馈而不是静默（beep + 状态行），
让"按了没反应"不再可能无声发生。

---

## 6. 已改（都在我的独占范围内；`LoupeZoom.swift` 里就是 `LoupeMapping`，属几何/呈现，已列入清单）

| 文件 | 改什么 | 对应症状 |
|---|---|---|
| `Sources/PhotonsCore/Kernels/s0_geometry.metal:116-127` | 旋转改成**像素空间**：`o=(uv−½)·frameSize` → `R(θ)` → `/frameSize+½` | 2,3 |
| `Sources/PhotonsUI/LoupeZoom.swift` | `LoupeMapping`：旋转改为像素等度（同一中心、同一顺序，只有度量变了）；新增 `framePoint/frameView`（轴对齐，给 overlay 与拖拽）与 `frameWidth/Height` | 2,3,4,6 |
| `Sources/PhotonsUI/CropTool.swift:209-217` | overlay 四角/手柄/网格走 `frameView`（**不进旋转**）；`.inside` 拖拽改同号 | 4,6 |
| `Sources/PhotonsUI/CropTool.swift` `straighten` | 去掉 `atan2(sinΔ·W, cosΔ·H)` 的 W/H 修正（那是给旧剪切打补丁），文档角 = 屏幕角 | 3 |
| `Sources/PhotonsUI/CropToolController.swift:386-396` | 指针换算走 `framePoint`（不转第二次）；`isRotatingPicture` 暴露 | 4,6 |
| `Sources/PhotonsUI/LoupeController.swift:2544` | 早退不再静默：`NSSound.beep()` | 1 |
| `Tests/PhotonsUITests/CropToolProjectionTests.swift`（新） | 6 条：相似性 / 屏幕角=文档角 / 框轴对齐 / 竖屏不转置 / 拖拽同号 / overlay 真挂载 | 1,2,3,4,6 |
| `Tests/PhotonsUITests/CropToolTests.swift` | 3 条按新口径改断言（原来钉住的是剪切与反向拖拽） | 2,3,4,6 |
| `Tests/PhotonsUITests/LoupeZoomTests.swift` | `wholeFrameMapping` 补 frame；`testStraightenAngleFollows...` 从「有 0.3% 偏差」改成「偏差 = 0」 | 3 |

**没有**改：`EditModel.swift`（任何组）、`InspectorView.swift`、`CurvePanel.swift`、任何 `s1_*.metal`、`CropMath.swift`。

### 修完的实测（都在修好后的树上跑的）

相似性（`view→source` 的基向量，修前 → 修后）：

| 用例 | 修前 \|e2\|/\|e1\| / cos | 修后 |
|---|---|---|
| 1200×800, 9° | 1.022152 / −0.127703 | **1.000000000 / 0.000000000** |
| 1200×800, 45° | 1.500000 / −0.384615 | **1.000000000 / 0.000000000** |
| 800×1200, 9°（竖屏） | 0.978328 / +0.127703 | **1.000000000 / 0.000000000** |

框（1200×800，crop=(0.1,0.2,0.5,0.4)，9°）：修前四角是平行四边形（`dot(top,left)=39801`，top=(592.61,−50.06)），
修后 top 边水平、left 边竖直、`dot = 0`、`|top|/|left| = cropW/cropH`。

拖拽（100 pt × 4 方向）：修前 `right → dLeft = −100`，修后 `right → +100 / left → −100 / down → +100 / up → −100`（误差 1e-6）。

`LoupeZoomTests` 里那条「1:1 窗口 vs 全幅投影」的偏差：修前 >0（测试断言 >0），修后 **0.000000 px / 2560 px**。

### 用户按 ⌘R 之后现在会看到
整幅画面仍然按 fit 显示，但**拉直会让照片真正转过去而不是被斜切**，而裁切框永远是一个摆正的矩形（八手柄、九宫格都贴在框边上），
框内拖动**跟着手走**；没有照片/不在单图时 ⌘R 会响一声而不是毫无反应。（0.9×fit、比例交换、信息栏定宽、菜单「变换」这些还没做，见下。）

---

## 7. 交付状态：16 条里做了 4 条，其余 12 条**没做**（不假装做了）

| # | 要求 | 状态 | 备注 |
|---|---|---|---|
| 1 | 完全看不到 | 部分 | 在 HEAD 上无法复现为接线 bug（真实 EditorWindowController 测到 overlay 已挂载、可见、在 canvasView 之上）；补了真挂载回归 + 早退 beep。**任何**「overlay 是否上屏」的断言此前都不存在，这是它能活着的原因 |
| 2 | 竖屏 | 修好（同源） | 竖屏剪切方向随 W/H 取倒数而反向，等度化后与横屏同一组断言；`800×1200` 用例已绿 |
| 3 | 图 shear | 修好 | kernel + mapping 两处同源；数字见上表 |
| 4 | 框跟着转 | 修好 | overlay 走轴对齐 `frameView`；顺带修掉「框是平行四边形」 |
| 5 | 进入裁切 0.9×fit | **未做** | 需要新的取景态；与 11/13/14/16 是同一套「缩放生命周期」，必须一起设计（见 §8） |
| 6 | 框内拖动方向 | 修好（按更正版口径做成"框跟手"） | 更正版要的「框固定居中 + 照片跟手」在 fit 下**物理上无处可平移**（窗口 ≥ 裁切区时 `limitedCenter` 会把它钉在中心），必须先有 11 的自动缩放才有行程 —— 两条是一条设计 |
| 7 | 交换比例（16:9↔9:16） | **未做** | `AspectLock` 已有 `.custom(ratio)`，交换 = 在新锁下用 `CropMath.fittedCrop` 重排；需要先定"原始比例交换"与文档 rotation 的叠加口径 |
| 8 | 自定义比例 + 固定 | **未做** | 建议：比例进文档（`AspectLock.custom`，一条历史），"上次输入值"进 `UserDefaults` |
| 9/10 | 信息栏三段定宽 | **未做** | `sizeReadout()`(:399) 与 `straightenLabel`(:31) 都在我手上；纯排版，优先在 1–6 之后 |
| 10b | 角度双击归位 | **未做** | 复用 `ResetOnDoubleClick`；注意「一条历史」意味着要走向 `applyEdit + commitEdit` 而不是改 draft |
| 11 | 框 ≤ 视口 90% 自动缩放 | **未做** | 与 5 同一公式（满幅时 0.9·Vw/cropW == 0.9·fit），见 §8 |
| 12 | 三个开关 on 变蓝 | **未做** | `CropToolBar` 三按钮改成两态外观；先确认它们不写文档（当前只改 `CropToolController.showsGrid` / draft.flip*，flip 是 draft，不进文档 ✓） |
| 13 | 确认后缩放/画面不动 | **未做** | `applyCropTool()` 现在只 `setViewState(cropEntryState)` 恢复进入前取景（`LoupeController.swift:2578-2583`），逻辑上已对；但没有测试钉住，且没有动画，需与 14 一起做 |
| 14 | 进入/退出动画 + 全图预览 | **未做** | 需要"未裁切全幅低清"作为独立缓存键（现有 `BackdropCache` 的键带 edit digest，crop 变了就失效 —— 正是不能用的原因） |
| 15 | 顶层「变换」菜单 | **未做** | 纯 UI 批；`AppMenu.swift` 里裁切三项整段搬到新菜单，翻转做成文档级动作（读 `GeometryGroup.flipHorizontal`，与工具栏同一字段） |
| 16 | 缩放基底 = 全幅 | **未做（部分已就位）** | 本轮把 `LoupeMapping` 的旋转中心/度量理顺了，但 `fitZoom`/`windowSize` 仍以 `cropWidthPixels` 为基（`LoupeZoom.swift:631-672`），即"以裁切画布为基"，与要求 16 的"以全幅为基"不一致，见 §8 |
| 17 | 松手归位动画（平移+缩放一条合成变换） | **未做** | 与 5/11/13/14/16 是同一套动画系统（§8）：一条 `CropFramingAnimation`（180–220 ms easeOut，常量放 `CropTool*`），scale 与 offset 同一条插值；不变量「框中心下的源像素不动」用 `framePoint(center)` 前后差 ≤0.5 px 断言；打断从当前中间态接管、不叠加 |

## 8. 下一轮的口径（写清再动手，别让实现自己解释）

* **缩放基底**（16）：把 `fitZoom`/`windowSize`/`contentSize` 的基从 `crop` 改为 `frame`（`sourceWidth/Height`），crop 只做可见窗口；
  `LoupeMapping.framePoint` 已经按"frame 像素 + 窗口"写好了，替换基底时它不用动。
* **0.9 与 90% 是一个公式**（5+11）：`s = min(0.9·Vw/frameW_px_displayed, 0.9·Vh/frameH_px_displayed)`；满幅裁切时
  退化为 0.9×fit（给数：viewport 1200×800、帧 1200×800 → fit=1.0 → s=0.9；框屏幕 1080×720 = 90%）。
  自动缩放是**fit 上的一个因子**（不动 fit 基准），退出即消失 —— 与用户建议一致。
* **6 的"框固定 + 照片跟手"** 只有在 `s > fit`（框小于画布）时才有行程：进入裁切先 `s = 0.9·…`，框内拖动把 `viewState` 的
  中心按 `−R(θ)·Δ/s` 移动（`LoupeFraming.panning` 现在的符号是"窗口跟手"，要取负才是"照片跟手"），框本身纹丝不动。
* **13+14** 的终态断言复用一条：`apply` / `cancel` 之后 `viewState == cropEntryState`（值类型逐值相等），
  动画只是把这条等式在时间上铺开；动画终点必须收敛到它，否则就是抖动。

## 9. 已知未修的一条**预存**失败（与本轮无关，供核对）

`PhotonsCoreTests.WindowTests/testNilWindowKeepsTheSevenM1KeysByteForByte` 在基线上就红：它比较的 stage key **文本**
（`curve.format` 的位数与 scale）期望 4 位小数 / scale 1，实际是 6 位 / scale 2 —— 来自 `b57c794`（curve format v2）那条线，
本轮没有改任何 key 物料。`WindowTests` 其余 13 条绿。

