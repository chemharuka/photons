# 169 · 旋转/裁切三个老 bug + 必须重构 — lane `crop-resize`

分支 `feat/crop-resize-1030`，worktree `/Users/luyao/photons-wt/crop-resize`。
改动只在允许的四个 UI 文件 + 一个新增的纯布局文件 + 三个新测试：

| 文件 | 角色 |
|---|---|
| `Sources/PhotonsUI/CropWorkspaceLayout.swift` | **新增**：布局的唯一真相（纯函数） |
| `Sources/PhotonsUI/LoupeController.swift` | 裁切框的唯一武装入口、换图重武装、冻结画面按同一比例缩放 |
| `Sources/PhotonsUI/CropToolController.swift` | `safeCropRect` 改为调用布局；新增 `reseedForPhotoChange()` |
| `Sources/PhotonsUI/CropCanvasClamp.swift` | `maxZoom` 改为调用布局 |
| `Tests/PhotonsUITests/Crop{WindowResize,FirstStraightenDrag,PhotoSwitchKeepsTheFrame}Tests.swift` | 三条新 RED→GREEN |

`Package.swift`、`Resources/`、导出/蒙版/contrast/dehaze/点颜色/深度均未触碰。

---

## 1. 根因（改前代码，具体到行）

### 1.1 「缩放窗口时画布不动、裁切框被限制 90%，松手才一起跳」

**根因是两个几何在同一个 layout pass 里回答了两个不同的画布。**

- `LoupeController.viewDidLayout()`（HEAD `:1663`）在 live resize 的冻结分支之前，先无条件调用
  `refreshCropTool()`（HEAD `:1672`）。它走到 `syncCropOverlay()` → `clampCropFrameToCanvas()` →
  `CropToolController.clampToView()`，而 `framing()` 读的是**新的** `viewportPixels`（HEAD
  `:2853`），于是框按新视口重投影、并在必要时被新视口夹小。
- 紧接着的冻结分支（HEAD `:1697`）只做 `scheduleFrozenPresent()`，而 `rePresentFrozen()`
  （HEAD `:6041`）用的是 `frozen.window.stretched(to:from:)`（HEAD `:6044`）——067 的定义是
  **“同一张图、同样的画布像素，只换 surface，不缩放”**。所以在拖窗口的每一帧：
  **画面保持旧的像素几何（被新窗口裁掉），裁切框却按新视口缩小**。
- 松手后 `releaseFrozenCanvasIfNeeded()` 请求新 canvas 的帧；新帧一到，画面跳到新 fit，框早已在
  新 fit 上，于是用户看到「两者同时跳到调整好的位置」。

用户说的「被限制 90%」就是进入裁切时的 `0.9 × 普通 fit`：框按新 canvas 缩到 90%，而画面没缩。

### 1.2 「第一次拖动旋转，会丢失裁切框」

**根因不是 straighten 写入，而是“照片身份”簿记落后于会话。**

- `lastHandledAnchorID` 只在 `observeModel()` 初始化时写一次（HEAD `:1711`），之后只有
  `dropCropToolIfStale()` 决定“陈旧”时才写（HEAD `:3755`）。
- `beginCropTool()`（HEAD `:3624`）打开工具时**没有**同步这个字段。loupe 往往先于照片选择创建，
  所以字段可能是 `nil`（或上一张）。
- 第一次拉直的**松手**走 `CropToolController.commitStraighten()`（HEAD `:483`）写文档 →
  `editRevision` 变化 → 观察回调（HEAD `:1731`）调用 `dropCropToolIfStale()`。它看到
  `anchor != lastHandledAnchorID`（HEAD `:3751`），把这次**文档写**误判成**换图**，执行
  `cropTool.detach()` → 覆盖层隐藏、`cropOverlay.layout = nil`。这就是“第一次拖动丢框”；之后的
  拖动因为字段已被上一次误判同步，反而不丢。

### 1.3 「裁切界面里点另一张图，裁切框不出现」

同一个 `dropCropToolIfStale()`：换图时它**只会 detach**，不会为新图重新武装。所以必须切到
「调整」再切回「裁切」（`setCropWorkspaceActive(false)` → `(true)` → `enterCropToolIfNeeded()`）
才重新 `begin()` 出框。

---

## 2. 为什么 162 那轮没修掉

162（merge `ec6499b`）把「进入裁切 90%」从 `LoupeFraming` 的 overlay-only 变成**渲染也带
`fitScale`**（`job.fitScale` / `makeFrame(fitScale:)`），并新增 `CropZoomEntryTests`。

它没有修这三条，因为：

1. `CropZoomEntryTests` 只测**进入那一刻**（以及直接调 `makeFrame` 的静态图），从不模拟
   live resize，也不比较「冻结画面」与 overlay；而 resize 的错位发生在
   `viewDidLayout` 里 `refreshCropTool()` 与 `rePresentFrozen()` 的**先后/两套几何**，不在进入路径上。
2. `dropCropToolIfStale()` 在 162 完全没有被触碰；`lastHandledAnchorID` 仍然是“初始化写一次、
   判陈旧时写一次”，首次文档写/换图仍会 detach。
3. `CropWorkspaceFitTests.testFortyFiveRefitsTheWholeCanvasWithoutChangingTheCrop` 的注释自己写着
   “the headless harness drops the tool when the commit bumps the revision”——它**依赖**了 1.2 的
   detach 才能通过。修掉 detach 后这条先变红，我们按它原本的意图（>6° 整画布重取景）把
   `currentCropWorkspaceFitScale` 在 >6° 时置 1，测试不用改断言就恢复绿（见 §6.3）。

---

## 3. 改前 / 改后调用关系

### 改前

```
viewDidLayout ──► refreshCropTool ──► syncCropOverlay ──► clampCropFrameToCanvas ──► cropTool.clampToView ──► safeCropRect(自己算)
      │                                  └──────────────► cropToolLayout(framing(新 viewport))
      │
      └─(isCanvasGeometryFrozen)──► scheduleFrozenPresent ──► rePresentFrozen ──► PresentWindow.stretched(旧像素/新 surface)

photo/editRevision 观察 ──► dropCropToolIfStale ──(anchor != lastHandledAnchorID)──► cropTool.detach()
                                                  └─ lastHandledAnchorID 只在 detach 时更新
beginCropTool ──► zoomToFit ──► refreshCropTool
refreshCropTool ──► 直接写 cropOverlay.isHidden / cropBar.isHidden / 发布 mode / 摆 bar(container.bounds)
cropZoomLimit ──► CropCanvasClamp.maxZoom(自己算)
layoutCropBar ──► cropBar.layout(container.bounds)
```

### 改后

```
CropWorkspaceLayout(source, quarterTurns, straighten, canvas)
   ├─ .entry(crop:)  ──► (canvas, picture, frame, entryZoom, maxZoom)      ← 纯函数，可单测
   ├─ .maxZoom(canvas:frame:)                                             ← CropCanvasClamp.maxZoom 委托
   └─ .canvasBounds(mapping:source:)                                      ← CropToolController.safeCropRect 委托

enterCropTool / setCropWorkspaceActive(true) ─┐
refreshCropTool（draft/camera/resize/tab）────┤
handleCropPhotoChange（anchor 真变了）────────┼──► armCropFrame(reason)   ← 唯一写 isHidden / 唯一武装
loadView（mounted）──────────────────────────┘        ├─ cropTool.reseedForPhotoChange() 仅 .photoChanged
                                                       ├─ syncCropOverlay ──► clampCropFrameToCanvas ──► safeCropRect ──► CropWorkspaceLayout.canvasBounds
                                                       ├─ cropBar.sync()
                                                       └─ layoutCropBar(cropWorkspaceEntryLayout())   ← canvas 来自同一个 entry

viewDidLayout ──► refreshCropTool（新视口重投影）
      └─(frozen)──► rePresentFrozen ──► cropFrozenScale(frozen, canvas)
                                         ├─ oldRect = frozen.window.canvasRect(photoRect)   ← 画面上真实的图片矩形
                                         ├─ newRect = framing().mapping.frameView(0…source)
                                         └─ r = min(new/old)；window = scaledWindow(r, origin)  ← 画面与框同一比例

photo/editRevision 观察 ──► handleCropPhotoChange
   ├─ 只是文档写（anchor 没变）──────────────► return（不 detach）
   ├─ 离开 loupe / 不在 裁切 workspace ───────► cropTool.detach()
   └─ 仍在 裁切 + 换了图 ─────────────────────► zoomToFit + armCropFrame(.photoChanged)（新图自己的 draft/entry）
```

---

## 4. 被删掉的分支 / 代码清单（证明是拆了，不是又叠一层）

| # | 被删/收敛的东西 | 原来位置 | 现在 |
|---|---|---|---|
| 1 | `dropCropToolIfStale()` 整个函数 | `LoupeController` HEAD `:3748-3757` | 删；由 `handleCropPhotoChange()`（现行 `:3774`）一个决策替代 |
| 2 | `refreshCropTool()` 里内联的“写 isHidden + 发布 mode + 摆 pill + guard + sync + bar + backdrop”整段 | HEAD `:4069-4098` | 删；`refreshCropTool()` 只剩一行 `armCropFrame(.refresh)`（现行 `:4112`） |
| 3 | `layoutCropBar()` 无参版本（读 `container.bounds`） | HEAD `:4215-4218` | 删；改为 `layoutCropBar(_ entry:)`，画布来自 `CropWorkspaceLayout.Entry`（现行 `:4302`） |
| 4 | `loadView` 里两处直接写 `cropOverlay.isHidden = true` / `cropBar.isHidden = true` | HEAD `:1611`、`:1619` | 删；由 `armCropFrame(.mounted)` 独占 |
| 5 | `CropToolController.safeCropRect` 的 `framePoint` 求交/钳位实现 | HEAD `:779-800` | 删；委托 `CropWorkspaceLayout.canvasBounds`（现行 `:799`） |
| 6 | `CropCanvasClamp.maxZoom` 的 `min(cw/fw, ch/fh)` 实现 | HEAD `:71-79` | 删；委托 `CropWorkspaceLayout.maxZoom`（现行 `:74`） |
| 7 | `framing()` 两处内联 `cropTool.isActive ? 0.9 : 1` | HEAD `:2863`、`:2876` | 删；收敛为 `currentCropWorkspaceFitScale`（现行 `:3665`），render job / makeFrame 共用 |
| 8 | `lastHandledAnchorID` “只在 init / detach 时更新”的分支 | HEAD `:1711`、`:3755` | 删；`beginCropTool` 打开即同步（现行 `:3641`），观察回调只在**真换图**时动 |

新增：`CropWorkspaceLayout`（布局唯一真相）、`armCropFrame(_:)`（武装唯一入口）、
`CropToolController.reseedForPhotoChange()`（换图重播种）、`cropFrozenScale` / `scaledWindow`
（冻结画面与框同比例）。

---

## 5. RED 证据（改前，最终版测试）

命令（先把 `Sources/` 的修复暂存为 `local/out/169-fix.patch` 并 `git checkout --` 回 HEAD，只留新测试）：

```
PHOTONS_TEST_RAW=$HOME/Desktop/test/L1030433.dng \
swift test --filter 'CropWindowResizeTests|CropFirstStraightenDragTests|CropPhotoSwitchKeepsTheFrameTests'
```

完整输出：`local/out/169-red-final.txt`。4 tests / **22 failures**。

| 测试 | 失败行（`169-red-final.txt`） | 代表输出 |
|---|---|---|
| `CropFirstStraightenDragTests` | `:695-697` | `commit +2.5°: the crop mode was dropped` / `the overlay is hidden or not on screen` / `the overlay is drawing nothing` |
| `CropPhotoSwitchKeepsTheFrameTests` | `:709-711` | `photo 2 L1030434.dng: switching photos closed 裁切 mode` / `the crop overlay stayed hidden after the switch` / `the overlay is drawing nothing` |
| `CropWindowResizeTests` | `:717-732` | `1200×800: the frame and the canvas disagree on the left edge (60.0 vs 123.5)` … `1400×875` … `2000×1400` … `release` |

`CropWindowResizeTests` 的失败就是用户描述本身：框缩到新视口的 60…1140，而冻结画面仍在
123.5…1476/50…950 的旧几何上。

> 说明：`CropFirstStraightenDragTests.testTheFirstStraightenTickKeepsTheFullFrameOnScreen`
> 在 HEAD 上单独跑可能绿（纯 `setStraighten` 不写文档）；真正复现“丢框”的是同一次拖动的**松手**
> `commitStraighten()`，即同一 suite 的第二条（RED 如上）。报告不把这两条混为一谈。

---

## 6. GREEN 证据

### 6.1 三条新测试

```
PHOTONS_TEST_RAW=$HOME/Desktop/test/L1030433.dng \
swift test --filter 'CropWindowResizeTests|CropFirstStraightenDragTests|CropPhotoSwitchKeepsTheFrameTests'
```

完整输出 `local/out/169-green-final.txt`：**4 tests / 0 failures**（另外两个 target 各 0 条）。

实测行（`local/out/169-green-final.txt` 的 `169 resize` 行）：

```
169 resize · entry · canvas {0,0,1600,1000} · frame {123.86,50.00,1352.27,900}
169 resize · 1200×800 · frame {60.00,40.61,1080,718.79} · picture {60,40.5,1080,719}
169 resize · 1400×875 · frame {108.38,43.75,1183.24,787.5} · picture {108.5,44,1183,787}
169 resize · 2000×1400 · frame {100,101.01,1800,1197.98} · picture {100,101,1800,1198}
169 resize · release  · frame {100,101.01,1800,1197.98} · picture {100,101,1800,1198}
```

`169 photo-switch` 行：photo 1 `3000×2000` → 框 990×660；photo 2 `2000×3000` → 456×684；
photo 3 `2400×1600` → 990×660；三张都在 1100×760 画布内，且各自等于新照片的宽高比。

### 6.2 现有裁切/旋转套件（收工条件 3）

```
PHOTONS_TEST_RAW=$HOME/Desktop/test/L1030433.dng \
swift test --filter 'CropZoomEntryTests|CropCanvasExpandTests|CropBoundsTests|CropToolProjectionTests|CropBarLayoutTests|CropToolTests|QuarterTurnTests|TransformPanelTests'
```

`local/out/169-required-green.txt`：**53 tests / 0 failures**
（PhotonsUITests 42 + PhotonsCoreTests 11 = CropCanvasExpand 4 + QuarterTurn 7）。

### 6.3 更大范围回归（额外自检）

```
swift test --filter 'Crop|WindowResize|Resize|BackdropStraighten|BackdropSwitch|BackdropWiring|BackdropTransform'
```

PhotonsUITests **162 tests / 0 failures**（2 条既有 skip，不是本单新增）+ PhotonsCoreTests 50 / 0。
其中 `WindowResizeTests`（非裁切模式）仍断言冻结画面 `pictureQuad` 不变——我们的缩放只在
`cropTool.isActive` 时进入，普通 loupe 的 067 行为逐位不变。

`CropWorkspaceFitTests.testFortyFiveRefitsTheWholeCanvasWithoutChangingTheCrop` 在修掉“首次文档写
误 detach”后先变红（`refit 0.09986 vs aabbFit 0.11095`），因为它原本依赖工具被 detach。
按它自己的注释与 132 §10 的意图（>6° 整画布重取景），把 `currentCropWorkspaceFitScale` 在
`|θ| > LoupeFraming.cropRefitDegrees` 时置 1；**测试断言未改**，现在绿。

### 6.4 构建

```
swift build --build-tests     # Build complete!
```

---

## 7. 测试里必须说明的一处事实

`CropWindowResizeTests` 为了把“画面”落到可测的 `FrameResult`，调用
`loupe.makeFrame(...)` + `presentForTesting(...)`。`present` 在 HEAD 会把**解码 rung 的尺寸**
（`0.5×` = `4760×3168`）发布成 `session.ingestedSourceFrame`，而 `framing()` 用的是
`decoded / decodeScale = 9520×6336`；两者不一致会让裁切框只画一半。测试在 `present` 之后把
`ingestedSourceFrame` 恢复成资产的全尺寸再测量（只影响测试夹具）。

这是与本单无关的既存“rung 尺寸 vs 全尺寸”发布口径问题，未在允许的文件范围内修改，也未用它
来绕过任何断言；测试比较的是 **presented pictureQuad** 与覆盖层，恢复口径只是为了两者都量
同一张全尺寸照片。

---

## 8. 测试 / 复现的最小步骤

- 图：`~/Desktop/test/L1030433.dng`（`9520×6336`）。
- 窗口缩放：进入 裁切（`⌘R` 或变换页），拖窗口边缘 1600×1000 → 1200×800 → 2000×1400；
  每帧框 ⊆ 画布、宽高比不变、中心相对位置不变，画面与框同比例缩。
- 首次拉直：进入 裁切（draft = `.full`），角度滑块拖到 +2.5° 后松手；覆盖层仍在、框非空、在画布内。
- 换图：停在 裁切 页，点左侧第 2/3 张；新图立刻有框，不需要切「调整」再回来。

所有 UI 测试均带 `PHOTONS_TEST_RAW=$HOME/Desktop/test/L1030433.dng`，编译只用
`swift build --build-tests`（debug），未运行 `make verify|test|app`，未 push / merge / rebase。
