# 354 · 引导线：端点存源像素，显示时 `P → R → view`

状态：**已实施**（lane `354-guide-display` / `feat/guide-display`）

## 0. 用户口径与修的是什么

> 引导线端点记录的是在原始图片中的像素位置，然后呈现时，要分别应用透视和旋转，展示到屏幕中作为显示位置。
> 现在引导线在尺寸缩放后还保持不变，说明并没有对引导线应用变换。

实施前：`CropToolController.guideLines` 是 `[CropToolSegment]`（**视图坐标**），只在画线那一下写一次
（`CropToolController.swift:1213`、`:1242`），缩放/平移/透视/旋转都不重算，overlay 只做
`didSet { needsDisplay = true }`。所以线停在一个**过去的相机**上。

## 1. 先量后改：这条 bug 有多大

同一组源端点，旧实现（画线时缓存的视图坐标）与按 `P·R·view` 重算的差（1200×1200 源，fit）：

| 状态 | 差 |
|---|---|
| `P = +60` | **31.9 px** |
| `P = −60` | **69.4 px** |
| `s = +9°` | **144.7 px** |
| 缩放 400%（相对 fit 相机） | **4220.3 px** |

（`GuideLines354DisplayTests.testTheOldCachedCoordinateAndTheRecomputedOneDifferByTheBugsSize`）

## 2. 唯一投影入口

`Sources/PhotonsUI/GuideLineProjection.swift` —— `GuideLineProjection.screenPoint(_:)`（源像素 → 屏幕）
与 `GuideLineProjection.sourcePoint(viewX:viewY:)`（屏幕 → 源像素，精确逆）。

**它是裁切框 overlay 用的那个函数吗？** 是。裁切框在裁切工作区里由
`CropTool.layout`（`CropTool.swift:328-332`）画：`CropGeometry.documentPoint`（`P → R`）+
`LoupeMapping.documentView`（相机）。`GuideLineProjection` 在 `canvasRole == .document`（引导线只存在
于裁切工作区）下就是这两个调用的组合，实测差 **0.00e+00 px**（6 组状态：`P = 0/±60`、`s = 0/±9°`、
fit 与 400%）。`.export` 映射（成品文档、337/348 夹具）走 `FrameTransform.sourceToView`，因为那是
`LoupeMapping.sourcePoint` 的逆、也是全 app 每个拖拽都在用的同一份 261 投影。

**没有缓存**：`GuideLineProjection` 是由「文档 + 当前 `LoupeMapping`」构造的值，每次绘制从源坐标重算，
所以不需要失效键。

## 3. 存储与手势

- `GuideLine.a/b`：**源像素**（`Double`），视图坐标不再存；`viewAngle`/`viewLength` 只记录手势本身
  （画线那一刻的屏幕角度 → 竖/横判定；20 pt 误触阈值）。
- 持久化：`GeometryGroup.guideLines: [StoredGuideLine]`，**仅有线时才写键**（`quarterTurns`/`pvy`
  纪律，中立文档逐字节不变），且**不进几何 key material**（线不改像素，不许拆缓存）。
- 拖动：`beginGuideLineDrag` / `continueGuideLineDrag` / `endGuideLineDrag`
  —— 屏幕落点 → `sourcePoint` 反算 → 存 → 松手时**重新求解一次**。线身平移两端一起，拖端点只动一端。
- 双击线身：`deleteGuideLine`，删掉该条并按剩余线重解；`< 2 条` 保留当前参数。
- 「清除引导线」：`clearGuideLines()` + 校正卡片该行上的按钮（`inspector.crop.guideLines.clear`）。
- 历史：一次拖动 = 一次求解 = 一条历史（端点与参数在同一个 `applyEdit` 里写）。

## 4. 验收数字

| # | 要求 | 实测 |
|---|---|---|
| ① | 跟随透视 `P = 0/+60/−60` ≤ 0.01 px（三组） | **0.00 / 0.00 / 0.00 px** |
| ② | 跟随旋转 `s = 0/±9°` ≤ 0.01 px（三组） | **0.00 / 0.00 / 0.00 px** |
| ③ | 跟随缩放 | fit 1012.34 px → 100% 1201.74（相机 ×1.1871）→ 200% 2403.48（×2.3742）→ 400% 4806.96（×4.7484）；**100%→400% = ×4.0000**；回 fit 差 **0.00e+00 px** |
| ④ | 拖端点回写 | 落点 (1041.804, 1086.187) · 存 (1092.340, 1166.971) · 再投影 (1041.804, 1086.187) · **差 0.000 px**；参数 (−41.41, 0, 0) → (−13.74, 0, +1.28)，残差 0.000° |
| ⑤ | 拖一端另一端不动 | 另一端屏幕位移 **0.000 px**（源像素 Δ = (0, 0)） |
| ⑥ | 双击删除后重解 | 线 2 → 1；参数 (−41.41, 0, 0) → (−41.41, 0, 0)（`< 2 条` 保留）；其余线端点 1e−9 不变 |
| ⑦ | 持久化 | 文档编码往返 ≤ 1e−9；关裁切重进 2 条线 |
| ⑧ | 过滤套件 | `--filter "GuideLine\|Crop\|Perspective\|Straighten\|Keystone\|FrameTransform"`：PhotonsUITests `Executed 334`，唯一红是存量 `PanFollowTests.testStraightenedPictureStillPansAlongTheScreenAxis` |
| ⑨ | 反向门① 显示跳过 `P` | 出厂 0.00e+00 px · 跳过 P **66.68 px** → ①红 |
| ⑨ | 反向门② 显示跳过缩放 | 出厂 100%→400% ×4.0000 · 跳过相机 **×1.0000** → ③红 |

## 5. 不做

不改 348 的残差定义与摆正逻辑；不改 353 的行程；不改裁切框对引导线的夹取规则。
