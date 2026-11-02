# 旋转 / 裁切几何：架构现状与重构记录

分支 `refactor/rotate-crop`（基线 `1e784b3`，merge 224）· 2026-11-01
范围：`CropMath` / `CropGeometry` / `CanvasSpaces`（新）/ `RenderGraph.plan` / `s0_geometry.metal` /
`LoupeZoom` / `CropTool(+Controller)`

---

## 0. 判据（用户口径）

1. 渲染管线**只**渲染屏幕显示的像素（窗口渲染）。
2. 画布 = 能包住全部照片像素的最小矩形；照片旋转后画布变大。
3. 画布有一份全尺寸低清渲染（backdrop）常驻内存，平移/缩放时盖住未算出的像素。
4. 裁切之后仍然用全尺寸低清渲染。
5. 旋转 + 裁切同时生效时有 **4 套坐标**：画布 / 旋转后的照片像素 / 裁切框 / 全尺寸低清渲染。

---

## 1. 现状：四套坐标的实际定义

| 空间 | 定义 | 代码 | 备注 |
|---|---|---|---|
| 源（文件）像素 | 解码缓冲；quarter turn 后 = `orientedSource` | `GeometryGroup.orientedSource` | 裁切矩形按**转向后**的帧归一化 |
| 照片像素 | 转向后的整张照片 = `CropGeometry.source` | `CropGeometry` | 归一化 `CropRect` 的坐标系 |
| 帧（裁切像素） | `CropMath.frameSize` | `CropMath.swift:655` | 132 起可越出照片 |
| **输出画布** | 旋转后**裁切框**的 AABB | `CropMath.canvasSize:596` | 渲染/导出的输出；`ceil` 一次 |
| **文档画布** | 旋转后**整张照片**的 AABB | 本次新增 `CropGeometry.photoCanvas` | 裁切框的合法区；与缩放/视口无关 |
| 窗口 | 输出画布上的一个整数矩形 | `RenderOptions.outputWindow` | 屏幕可见区 |
| backdrop | 整帧的低清渲染，画布坐标系 | `BackdropCache` + `framePlacement` | 归一化到输出画布 |

**关键区分**（此前代码没有名字，是多数 bug 的根源）：**输出画布** ≠ **文档画布**。
裁切 ≠ 满幅时两者不是同一个矩形：输出画布只包住「留下的照片」，文档画布包住「全部照片」。
渲染/导出用前者；裁切框的边界、backdrop 的理解、平移上限用后者。

### 1.1 同一个量曾有多份实现

| 量 | 曾经的实现 | 现状态 |
|---|---|---|
| 旋转 AABB `\|w·cos\|+\|h·sin\|` | `CropMath.canvasSize`(ceil)、`CropMath.containingExtent`、`LoupeFraming.rotatedExtent`、`LoupeMapping.canvasRect` | ✅ 收敛到 `CropGeometry.rotatedExtent`（3 处已改为委托，1 处仅读数） |
| `ceil` 规则 | `CropMath.canvasSize` 内联闭包 | ✅ `CropGeometry.canvasPixels` |
| `(canvas−frame)/2` | `CropMath.canvasOrigin`(Int)、`RenderGraph.plan` inset(Float)、`LoupeFraming.canvasOriginPixels`(Double)、`LoupeFraming.canvasOrigin`(Int→scale→round) | ⚠️ 新增 `CropGeometry.canvasInset`（连续，权威），旧拼写保留（见 §3 D1） |
| 裁切合法区 | `LoupeMapping.canvasRect`(视口∪AABB)、`CropToolController.documentCanvas`(AABB)、`CropTool.clampToCanvas`([0,1]²) | ✅ 统一为 `CropGeometry.documentCanvasCropRect`，钳制改用它 |

---

## 2. 本次已改

### 2.1 新增 `Sources/PhotonsCore/CanvasSpaces.swift`

`CropGeometry` 被补齐为「四空间坐标系」的唯一 owner：

```swift
frameSize / frameExtent / hasAngle / canvasInset / photoExtent / photoCanvas
documentCanvasRect / documentCanvasCropRect
canvasPoint(frameX:frameY:) / framePoint(canvasX:canvasY:)     // 绕帧心旋转 + inset
framePoint(photoX:photoY:) / photoPoint(frameX:frameY:) / canvasPoint(photoX:photoY:)
frameQuadInCanvas / photoQuadInCanvas / clampedToDocumentCanvas(_:)
static rotatedExtent(width:height:degrees:) / documentCanvasCropRect(in:degrees:) / canvasPixels(_:)
```

- `CropGeometry` 新增 `perspective` 存储属性（此前只在 `init` 里用一次就丢，导致任何按类型取像素尺寸的
  调用方都拿不到 keystone 后的 frame）。
- `hasAngle` 把「真的转了」定义成「不是 90° 的整数倍」，与 162 的 `canvasSize` 早退同一判据。

### 2.2 旋转 AABB 一次性收敛

`CropMath.containingExtent`、`CropMath.canvasSize`（ceil 部分）、`LoupeFraming.rotatedExtent` 全部改为
委托 `CropGeometry.rotatedExtent`。右角度（0/90/180/270）**原样返回输入**（不是 `w·1+h·0`），
所以未拉直的文档一个数都不动。

### 2.3 裁切合法区：规则搬进类型（应用侧 2026-11-02 已切换，见 §6）

`CropGeometry.documentCanvasCropRect(in:degrees:)` 已经把「文档画布」算出来了，并配了
`clampedToDocumentCanvas(_:)` 与 5 条类型级测试。但 `CropTool.clampToCanvas` 的**判定仍然是
`[0,1]²`**（224 的口径），原因写在下一条：

- 把判定换成文档画布，会让 224 / 190 的验收套件成片变红（`CropClampDocument224Tests` 的
  `A frame ten canvas widths away`、`CropZoomBound190Tests` 的 25% 覆盖律、`CropBoundsTests` 的
  「8° 时必须留在 [0,1]²」等）——这些是用户 2026-11-01 亲自定的口径，切换属产品决策，不由重构单方面执行。
- 切换的实际差值是：8° 时合法左边从 0 放到 −0.0415，45° 时到 −0.118（x）/ −0.325（y）（6000×4500）。
- 切换需要三处一起改：① `CropTool.clampToCanvas` 的 body 换成文档画布（现成）；
  ② `CropToolController.clampToView` / `continueDrag` 把草稿角度传进来；
  ③ 上面那几套验收按同一 API 重写期望值。

`CropToolController.documentCanvas`（190 的覆盖度读数）已改为
`CropGeometry.documentCanvasCropRect` 派生——读数与钳制至少来自同一个函数，不会再各说一套。

### 2.4 修掉的真 bug：90°/270° 的帧方向

`CropToolController.sourceSize` 已是**转过 90°**的帧，而 `CropGeometry.init(geometry:source:)` 自己会再
orient 一次 —— 奇数 quarter turn 下裁切工具的 `source / frameSize / canvas` 描述的是**未转**的文档，
`RenderGraph` 描述的是转过的：同一张截图两个宽高比（帧的像素读数、入口取景、`effectiveCanvas` 都错）。
没有测试钉它。已修：`CropToolController.uprightSource`（未转帧）只喂给 `CropGeometry` / `TransformSession`，
`sourceSize` 仍是转过的、给拖动与读数用；新增 `CropGeometryOrientationTests`（2 条，0/90/180/270 全覆盖）。

### 2.5 B1 审计后的收尾

- `CropMath.canvasSize` 现在真的走 `CropGeometry.rotatedExtent`（此前只有 `ceil` 搬了过去，乘法仍是内联）。
- `LoupeFraming.panning` 的 `R(θ)` 改用 `CropGeometry.RotationMatrix`（app 里第四份 cos/sin 拼写）。
- 仍在的重复（有意保留，见 §5）：`CropMath.fitsInsideSource / fitsInsideRotatedFrame / scale`、
  `Masks.swift` 的 cos/sin 走位（蒙版不在本次范围）、`CropMath.canvasOrigin`（D1 的整数拼写）。

### 2.6 测试

| 文件 | 内容 |
|---|---|
| `Tests/PhotonsCoreTests/CanvasSpacesTests.swift`（新，11 条） | 与 `CropMath` 在 {3 尺寸}×{4 裁切}×{7 角度}×{2 转向} 上逐位相等；右角度不扩画布；frame⇄canvas 互逆 1e-9；文档画布与裁切无关、随角度变大；黑角合法、越界被拉回；θ=0 时一切退化为恒等 |
| `Tests/PhotonsUITests/CropCanvasIsTheDocumentCanvasTests.swift` | **已删**：它断言的是切换后的口径，而应用侧按本轮决定仍走 224。切换时把它恢复（git 历史里在 `5a5da16`），与 224/190 的改写一起提交 |

---

## 3. 诊断出但**没有**在这次改的（及其原因）

### D1 · `(canvas − frame)/2` 的半像素奇偶差 — **已修（2026-11-01）**

**症状**：`CropMath.canvasOrigin` 整数除法、`RenderGraph.plan` Float、`LoupeFraming` 整数后再缩放；
`canvas − frame` 为奇数时窗口帧与整幅帧取样相位差半个像素（实测 75 码），`CropFullResCanvasTests`
的「窗口帧 = 整幅帧」因此只能在「两边都恰好截断」时成立。

**修法**：把相位定成**整数**，三处取同一个式子。`plan` 的 `inset` 改为
`(baseline − frame) / 2` 的整数除法；`LoupeFraming.canvasOrigin` 复现同一对 round + 同一个截断
（按渲染自己的 scale，`baseline = round(canvas·s)`、`frame = round(frameSize·s)`）；
`CropGeometry.canvasInsetPixels` 是 1:1 下的同一个量，`canvasInset`（连续）只作参考值。
代价：照片在画布里最多偏 0.5 px（画布是我们自己造的，不可见），换来窗口帧与整幅帧**逐码相等**。

**连带更新**：

- 金值 `render-edit-push-s0.25`（0.8°）与 `render-edit-crop-rot-s0.25`（−12.5°）按新相位重录
  （像素确实变了，非日期噪音）；`render-edit-neutral`、解码金值不变（0° 的 inset 恒为 0）。
- `MaskTests.testAtlasInvertsCropRotationAndFlip` 的正演模型原本用连续 `(canvas − frame)/2`，
  已改为同一整数截断——它必须描述渲染器实际画出的那一张。
- 顺带把 `PerspectiveTests` 那条「push 金值陈旧」的存量红对齐（它比的就是这两个金值）。

**未动**：`LoupeFraming.canvasOriginPixels` / `framePlacement` 仍用连续量（backdrop 的归一化在 D2
里连底数 `rotatedCropExtent` 一起改，单独动一半会让 188 的偏贴回来）。

### D2 · backdrop 的 `framePlacement` 二次推导

`framePlacement` 把窗口按 `rotatedCropExtent` 归一化、再单独套 flip（`LoupeZoom.swift:967`），
渲染侧又用 `inset`/`origin`/`kx/ky` 推一遍（`RenderGraph.swift:1912-1971`）。今天两者之所以一致，
是因为**裁切模式下 `cropTool.canvasEdit` 把帧作业也换成整帧**，于是「backdrop 的画布 = 锐帧的画布」
这一不变式成立（202 修的正是它的破坏版）。这条不变式只在注释里，没有类型保证。
把 backdrop 改成常驻「整张照片」的低清层（用户口径 4 的字面读法）会打破它——需要先把
「纹理画布」变成类型，再改语义。**本次不动，记录在此。**

### D3 · 钳制切到文档画布 — **已于 2026-11-02 切换**（见 §6）

### D3b · `LoupeMapping.canvasRect` 仍把视口并进读数

219 的 `canvasRect`（`LoupeZoom.swift:1145`）现在是**纯读数**（钳制已不用它），但仍会 union 视口，
语义上仍误导。等 `safeCropRect`/`canvasBounds` 的调用点清完再删。

### D4 · 旋转轴心

`out = crop.origin + R(θ)·(p − cropCentre)`：旋转绕**裁切框中心**，不是照片中心。数学上等价于
「照片转 + 平移」（采样点随裁切整体平移，`sample = P + R(u−P)`，`P` 平移 Δ 时结果整体平移 Δ），
所以画质与位置都对；但「照片绕自己中心转」这种直觉在这里不成立。改轴心会改所有拉直文档的像素，
属产品决策，**不改**，仅记录。

---

## 4. D3 施工清单（钳制切到文档画布时）

两个只读审计子代理（B1 扫重复、B2 盘测试）的结论，供切换时照做：

**必须重写断言值（7 条）**

| 文件 | 用例 |
|---|---|
| `CropBoundsTests` | `testAtEightDegreesTheFrameIsPulledInsideTheCanvas` |
| `CropClampDocument224Tests` | `testAFrameTenCanvasWidthsAwayIsPulledBackWithZeroError`、`testTheClampIsIdenticalAtTwoViewports`、`testFortyFiveDegreesAtFourHundredPercentAPanAndDragStayInTheDocument`、`testEveryDragTickIsInsideTheDocument`、`testPinnedFrameDoesNotMoveOnFurtherTicks` |
| `CropZoomBound190Tests` | `testASingleFarDragIsPinnedOnTheCanvasEdge` |

**论证没问题、但要改判据来源（9 条）**：`CropZoomBound190Tests:testAtZoomTheFrameCannotLeaveTheCanvas`、
`:testEveryClampedResultSatisfiesItsOwnLaw`、`CropFitNinetyTests:testEveryFramingAngleAndFrameSizeStaysInsideTheCanvas`、
`:testWithoutTheClampTheSameMatrixLeavesTheCanvas`、`CropClampMatrixProbe202Tests:testTheFrameStaysInsideTheCanvas`、
`CropFrameClampTests:testTheFrameStaysOnTheCanvasWhenUpright`、
`CropRotation188Tests:testTheFrameStaysInsideTheCanvasButMayCoverTheLetterbox`、
`CropClampDocument224Tests:testAtFortyFiveDegreesTheFullFrameIsAllowedAndWarns`、`:testRatioStraightenAndCameraWritesStayInsideTheDocument`。

**已可直接用**：`CanvasSpacesTests` 里给了切换后的期望值（8° → `-0.0415/-0.0995` @3000×2000，
45° → `-0.1187/-0.325` @6000×4500）。

**切换时的三处代码**：① `CropTool.clampToCanvas` 的 body 换成 `CropGeometry.documentCanvasCropRect`；
② `CropToolController.clampToView` 与 `continueDrag` 把草稿角度传进去；③ 上面 16 条用例按同一 API 重写。

**审计另指出**（范围外，记录）：`LoupeController.union:5586` 把对比两侧都裁到 `e.result.canvas`，
而原图那一侧用另一个画布渲染；`Masks.swift:1475-1522` 有自己的一套 cos/sin 走位。

---

## 5. 验收

```
swift build --build-tests --disable-automatic-resolution
PHOTONS_TEST_RAW=~/Desktop/test/L1030433.dng swift test --skip-build --filter "Crop|Backdrop|Loupe|Window|QuarterTurn|CanvasSpaces"
.build/debug/photonsctl golden check ~/Desktop/test/L1030433.dng --dir Tests/Golden
.build/debug/photonsctl render … --edit Tests/Fixtures/edit-{neutral,push,crop-rot}.json --scale 0.25 --golden check
```

- 基线（改动前）：`Crop|Backdrop|QuarterTurn|Perspective` 71 条，1 红（`PerspectiveTests` 的
  `render-edit-push-s0.25` 金值陈旧，QUEUE L22 已记）。
- D1 之前：`Crop|…|Perspective` 463 通过 / 1 红（同上那条）。
- D1 之后：三个 render 金值与解码金值全部 `PASS`；`RenderTests`、`PerspectiveTests`、
  `CropMathTests`、`MaskTests` 全绿。L22 的「push 金值陈旧」随之关闭——根因是测试侧没把
  「解码已带该白平衡」告诉渲染图（`RenderInput.whiteBalance`），S1 二次施加，只有带 WB 的文档分叉。
- `WindowTests.testPanFrameCostDoesNotRegress` 仍是负载相关的性能阈值（load ≈ 10 时红）。

---

## 6. 2026-11-02 — 合法区切到文档画布；裁切模式 `↵` 应用

用户当天两条口径，都已在应用侧落地。

### 6.1 「旋转之后，裁剪框能移动的范围应该是画布，不是原始图片」

§2.3/§4 里挂着的那次切换做完了，三处一起改：

| 位置 | 改动 |
|---|---|
| `CropTool.clampToCanvas(_:mapping:source:degrees:tolerance:)` | 合法区 = `CropGeometry.documentCanvasCropRect(in: source, degrees:)`；缩放判据也从「大于 1」改成「大于画布」；最后一道 `.clamped(false)` → `.clamped(allowsOutsideSource: true)` |
| `CropToolController.clampToView` / `continueDrag` | 把**草稿角度** `clampStraighten(draft.straighten)` 传进钳制；新增 `canvasBounds(source:)` 给拖动用 |
| `CropTool.constrain(…, bounds:)` / `CropToolDrag.crop(…, bounds:)` | 新增 `bounds`（默认 `.full`，旧调用方数字不变）；`base = crop.clamped(allowsOutsideSource: true)`，鼠标按下时不再被照片边界拽回 |

验收：`CropClampDocument224Tests` / `CropZoomBound190Tests` / `CropBoundsTests` / `CropFitNinetyTests`
四套 16 条按新口径重写（每套自带私有 `legalRect(degrees:source:)` 独立推导，不调生产函数），
`Crop|Clamp|QuarterTurn|CanvasSpaces` 194 条全绿。重算的期望值：8° @3000×2000 →
`-0.041525 / -0.099514 / 1.041525 / 1.099514`；45° @6000×4500 →
`-0.118718 / -0.324958 / 1.118718 / 1.324958`。

**顺带修掉的契约 bug**：`CropGeometry.photoExtent` / `documentCanvasCropRect` 在 90°/270° 返回的是
`rotatedExtent` 的交换 AABB（6000×4500 给出 `x ∈ [0.125, 0.875]`），于是「90° 的满幅框非法」——
与本文档「at every right angle the canvas is the frame」直接矛盾。已加右角度早退（`hasAngle`），
`CanvasSpacesTests.testARightAngleIsThePhotographAndNotTheSwappedBox` 钉住。拉直本身被钳在 ±45°，
所以这是一条契约修复而不是可达文档的像素变化。

**口径上仍需用户拍板的一点**：现在的合法区是「e 尺寸、以照片为中心的轴对齐矩形」，四角正好落在
画布四角，但**边会在中间鼓出画布**（45° 时最多约 1.41×）。所以数学上「框的四个角 ⊆ 画布」成立，
「框的每一条边 ⊆ 画布」不成立——后者是更紧的合法区（要按旋转后的菱形求交）。若用户要的是后者，
改 `documentCanvasCropRect` 的公式即可，钳制的三处调用不用动。

**仍在用旧判据的两条用例**（§4 的 9 条改判据清单剩下）：`CropClampMatrixProbe202Tests:173`、
`CropFrameClampTests:101`（靠 0.5 px 松弛通过），切换时未改，属读数而非钳制。

### 6.2 「旋转后照片被推到左边、右边纯黑，缩放一下才恢复」

根因不在渲染几何，在**相机**：`rotateQuarter` 只写文档、不动 `viewState` 的窗口中心。窗口中心存在
「转向后的照片像素」里，一次 90° 正好把两个轴换名，于是原来指向照片中部的数字在新坐标系里指向了
别的部位——照片被推到一边；此时渲染的 `canvasRect` 按窗口算出来落在画布之外，被裁到可见部分，剩下的
画布就是 `#0F0F0F`（用户读作「纯黑遮罩」）。`⌘0` 会从 crop 重算中心，所以看起来像「缩放修好了」。

- `rotateQuarter` 现在把中心随照片一起转：顺时针 `(x,y) ↦ (H − y, x)`，逆时针 `(x,y) ↦ (y, W − x)`，
  `W×H` 取 `framing()` 的 `sourceWidth/Height`（= `viewState.center` 的同一单位：整分辨率转向帧像素，
  **不是** `cropSourceSize` 的解码网格——0.5 档下它只有一半）。`.fit` 的中心是从 crop 推出来的，
  没有存下来的数字要搬，也不许因此把适应变成实际像素。
- 定位过程：`~/photons-diag.log`（临时诊断，已移除）里一次 25% + 转动 6° 的呈现是
  `presentRect=(0,0,1794,1600)` 而 canvas 是 2560×1600 —— 右边 766 px 就是那条黑带；同一份日志显示
  `state centre=(4760,3168)` 而 90° 之后照片中心是 `(3168,4760)`。
- 验收：`QuarterTurnKeepsTheCameraTests` 4 条（⌘] 的映射、⌘[ 的逆、照片中心仍是中心、适应不被改档）。

### 6.3 「在裁剪界面按回车没有应用更改」

`↵` / `Esc` 一直写在 `LoupeCanvasView.keyDown` 里，但那只在画布是第一响应者时才收得到键；而
变换页签、裁切卡都是画布**旁边**的 AppKit/SwiftUI 控件，点一下焦点就离开了画布，`↵` 石沉大海。

两件事，一起：

- `LoupeController.beginCropTool()` → `focusCanvasForCrop()`：进入裁切把画布设为第一响应者（正在
  打字时让位）；
- `installCropReturnMonitor()`：窗口级 `NSEvent.addLocalMonitorForEvents(.keyDown)`，在事件**分发
  之前**拦下 `↵` / 小键盘 Enter（`\u{3}`，允许 `.numericPad`/`.function`，⌘⌥⇧⌃ 都不算），焦点在
  哪里都一样；输入框编辑中（`NSTextView`）让位；`leaveCropTool()` / `deinit` 拆掉。

`handleCropReturn` 的返回值语义是**事件是否被吃下**（不是「文档变没变」：空草稿的 `↵` 也会关框）。
验收：`CropReturnKeyTests` 5 条（进入即聚焦、焦点不在画布也能应用且只写一次、小键盘 Enter、⌘↵/
别的键/框没开时不吃、监听随框存亡）。
