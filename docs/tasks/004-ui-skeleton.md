# 004 — M3：UI 骨架（网格 / 单图 / 胶片条 / 检查器）

> 定稿 2026-10-25。前置：M0 `2616e3a`、M1 `7f7d1cf`、M2 `1603ee2`。
> 本规格只覆盖 **M3**。缩略图生成（`previewImage`）**不在本阶段**，M3.5 再做。
> 依据：`docs/architecture-decisions.md` §11.4/§11.8（解码前置）、`local/research/ui-stack.md`（UI 栈核对）。

## 1. 范围（做 / 不做）

**做**

| # | 交付 | 说明 |
|---|---|---|
| 1 | `Photos.app` 外壳 | `Photons.app`（SwiftPM executable + `scripts/bundle-app.sh`），AppKit 起点 |
| 2 | 读库 | 打开 `.photonslibrary`（M2 的 `Catalog`），左栏列出来源根 + 照片计数 |
| 3 | 网格 | `NSCollectionView`，**占位图**（无缩略图），⌘/⇧ 多选、键盘导航、双击进单图 |
| 4 | 单图（loupe） | **走 M1 `RenderGraph` 真渲染**（乙方案），fit 显示；1:1 只留接口，不做交互 |
| 5 | 胶片条 | `NSCollectionView` 横向，与网格共享 selection |
| 6 | 检查器骨架 | SwiftUI（`NSHostingView`）：曲线前的 Light/Color 组字段 + 数值，改动写进文档模型 |
| 7 | 解码前置 ① ② | D2′ 能力集（全 v8 + 回读断言）、显式线性（boost=0、gamut off） |
| 8 | EDR 契约 | `DisplayOptions.headroom`（默认 1.0）；S4 不写死 clamp；画布 `CAMetalLayer`，EDR 默认关 |

**不做**：缩略图生成与缓存、`previewImage`、DNG 标定、1:1 平移/缩放交互、拖放导出、评级写入（读即可）、蒙版、导出 UI、HDR 输出。

## 2. 架构（定案，不再讨论）

- **AppKit 起点**：`@main` `AppDelegate` + `EditorWindowController`（`NSWindowController`）+ `EditorSplitViewController`（`NSSplitViewController`：左来源 / 中模块 / 右检查器）+ `NSToolbar` + 主菜单（responder validation）。
- **一个模型**：`CatalogSession`（`@MainActor @Observable`）持有 `Catalog`、当前来源、`[Asset]`、selection、`EditModel`。
  AppKit 视图用 `ObservationBridge`（`withObservationTracking` 重新注册）订阅；SwiftUI 检查器用 `@Bindable` 读同一对象。**不允许第二份状态副本。**
- **网格 = `NSCollectionView`**（`FlowLayout` + 复用 item + 占位绘制）。M3.5 若实测不够，再考虑自绘（redlamp 的 5,736 行是上界，不是起点）。
- **画布 = 自绘 `NSView` + `CAMetalLayer`**，缩放即重新渲染（`RenderOptions.scale`），不把大图塞进 `NSScrollView` 做图层缩放。
- **渲染只有一条路**：网格占位图不走渲染器；loupe / 未来的缩略图与导出都走 `RenderGraph`，只差 `scale` 与 `canvas`。

## 2b. 视觉与布局：参考 Phos（2026-10-25 改定）

> 用户改定：**放弃 Lightroom 三栏的视觉与工具栏，改参考 `Zenodeng/Phos`（Pixelmator 风格，MIT）**。
> 只取外壳与视觉语言，不搬它的编辑器语义与业务模型。本节的数字来自
> `local/src/swift-raw/Zenodeng_Phos/WINDOW_INTEGRATION.md` 与 `Sources/Phos/WorkspaceSessionState.swift`
> 的 `WorkspaceLayout.resolve`；**没有复制任何 Phos 代码，只取数值常量**，故 `THIRD_PARTY_NOTICES.md` 无需新增条目。

| # | 合同 | 落地 |
|---|---|---|
| 1 | **不用 `NSToolbar`**；自绘顶部工具容器 **36pt**，与交通灯同一行（共享中线），按钮命中框 **28pt**、内 padding 水平 **9**、高 26–28、圆角 **7 continuous**，组间分隔线 **1×18** | `TopBarView` + `ToolButton`；窗口 `titlebarAppearsTransparent = true`、`titleVisibility = .hidden`、`.fullSizeContentView` |
| 2 | 左栏默认 **212pt**（可拖 196–260），行高 **46pt**，`NSTableView` 复用行；内容 = 来源根 + 照片列表（占位块） | `BrowserPaneController`（`NSVisualEffectView(.sidebar)` + 两个 `NSTableView`） |
| 3 | 胶片条是**可切换的第二浏览器**：底部容器高 **122pt**，缩略 **74×50**；⌃⌘B 显示/隐藏（⌃⌘A 切回列表）；与网格共享 selection | `FilmstripController`（横向 `NSCollectionView`，与网格共用 `CatalogSession.selection`） |
| 4 | 右检查器默认 **330pt**（可拖 300–364） | `InspectorView`（SwiftUI in `NSHostingView`） |
| 5 | 大面板 matte（`.underWindowBackground` / `.sidebar`，纯色 0.96 亦可），只有小组件容器 glass；卡片圆角 **9–10 continuous**，内容 inset 水平 **16** / 垂直 **10**；选中态 accent 1–2pt 描边 | 左栏 `.sidebar`、右栏 `.underWindowBackground`、顶栏 0.96 纯色；SwiftUI 卡片用 `.regularMaterial`(AppKit 侧无 `.regular`/`.thinMaterial`，等价物是 `.headerView`/`.menu`) |
| 6 | 中央画布铺满可用区（不留白边），最小安全编辑区 **560×420**；记住各栏宽度 | 画布与左栏/检查器之间只有 1pt 分隔线；宽度写 `UserDefaults`(`photons.browserWidth` / `inspectorWidth`)，窗口用 `setFrameAutosaveName` |
| 7 | 中栏语义仍是我们自己的：**网格 / 单图** 两个 module | `AssetGridController` / `LoupeController`，由 `WorkspaceRootView.showModule` 切换，同一模型 |

**与 §2 的两处结构性偏离（本节取代前文）**

- **面板不再用 `NSSplitViewController`**：Phos 的胶片条要在底部横跨「左栏 + 画布」而检查器仍通高，
  这不是三列 split 能表达的布局。改为一个自绘容器 + `WorkspaceLayout.resolve` 单一坐标源 + 两条 5pt 拖动热区
  （`WorkspaceDivider`，`resizeLeftRight` 光标）。宽度仍受 196–260 / 300–364 约束并有单测。
- **观测到的交通灯中线是 14pt，不是 30pt**：本机 28pt 标题栏 + `fullSizeContentView` 下三色灯居中在 14pt。
  容器按「中线跟交通灯」规则反解，钳制到窗口顶边后中线为 18pt（残差 4pt）；**不手动移动系统按钮**
  （Phos 自己也不在过渡中移动它们）。ui-smoke 断言该残差 ≤ 4pt。
- 胶片条模式（B）下照片行搬到条内，左栏只留来源根——这是 §2b#3「第二浏览器」的直接后果，避免两份照片列表。

## 3. 解码前置（M3 内落地，`PhotonsCore`）

1. **D2′ 能力集**：`RAWDecoder` 默认全 v8；`DecodeOptions.decoderVersion` 若给了非 v8 值，赋值后**回读断言**，不等则降级 v8 并上报 `effectiveVersion`。`DecoderCapabilities` 声明按版本可用的滑杆集合（v9 → 色度 NR / 细节 / 摩尔纹不可用）。
2. **显式线性**：解码固定 `boostAmount = 0`、`isGamutMappingEnabled = false`（§11.4：否则曝光不是严格 ×2）。
   **同一条设置还决定 EDR 余量**（§11.8：同一文件 1.018 → 1.695），故这条同时是 EDR 的数据侧前提。
3. 缓存键不变（`DecodeCacheKey` 已含 `decoderVersion`），但**已落盘的旧缓冲是默认设置产物**，须让 `DecodeCacheKey` 增加一个 `decodeRecipe` 字段（v1 = `boost0-gamutOff`），否则会命中旧缓存。
4. golden 需要重录一次（解码设置变了），重录必须在 commit message 里写明原因。

## 4. EDR 契约（M3 只定形状，不开画面）

- `DisplayOptions` 增加 `headroom: Double = 1`，并入 `keyString`；`headroom = 1` 时输出与今天**逐像素一致**（S4 的 `clamp(v,0,1)` 变成 `min(v, headroom)`）。
- 画布 `CAMetalLayer`：`colorspace = extendedLinearDisplayP3`、`wantsExtendedDynamicRangeContent = false`（M3.5 打开时只改这一个布尔 + headroom 取值）。
- 数值验收：`headroom = 1` 与现有 golden 一致；`headroom = 4` 时 >1 的样本保留（单测，不依赖显示器）。

## 5. 验收

| 项 | 判据 |
|---|---|
| `make verify` | build + 40 单测 + L1/L2/L3 + M2 catalog 全绿（解码设置变更后 golden 已重录） |
| 新增单测 | ① 回读断言（非白名单机身设 v9 → 得到 v8 且 `effectiveVersion≠9`）；② 曝光 ×2 严格（p10=p50=p90∈[1.99,2.01]）；③ headroom 契约（1 → 与旧 golden 同 hash；4 → 保留 >1） |
| `make app` | 产出 `Photons.app`，`open` 可启动、窗口出现、不崩 |
| `make ui-smoke` | 用 `fixtures` 造的 1000 行库启动：网格 item 数 = 库行数；三档窗口宽度下列数/行高符合纯布局函数；loupe 渲染一帧不崩；截图存 `local/out/ui-smoke-*.png` |
| 性能 | 10k 行占位图网格滚动主线程 p99（**如实标注"占位图，不含解码"**）；loupe 首帧（含解码）与二次渲染（缓存命中）分别记录 |

## 6. 任务拆分（一个 worktree 内顺序做，各自可验收）

- **004a 外壳 + 读库**：Package 目标、bundle 脚本、菜单/工具条、左栏、`CatalogSession` 读 `assets()`、`make app` 通过。
- **004b 网格 + 胶片条**：`NSCollectionView`、占位图、选择/键盘、双击进单图、布局纯函数单测、`--ui-smoke` 的计数与布局断言。
- **004c loupe + 检查器 + 解码前置**：`RenderGraph` 接线（fit）、`CAMetalLayer` 画布、`headroom` 契约、解码前置 ①②、检查器骨架、golden 重录、全量 `make verify`。

## 7. 风险

| 风险 | 处理 |
|---|---|
| 解码设置变更使旧线性缓存失效 | `decodeRecipe` 进键，旧缓存自然不命中；不删用户缓存 |
| 60MP 全尺寸解码 0.5–1 s，loupe 首帧会明显停顿 | 首帧先用 `scale 0.5` 解码出图，随后 1:1 再解码（M3 只做 fit，天然落在低倍） |
| SwiftUI 检查器接真渲染后可能吃主线程 | M3 不接渲染；M4 前用 `--swiftui-panels` 式开关实测（redlamp 的教训） |
| AppKit 事件与 SwiftUI 焦点打架 | 焦点/键事件一律在 AppKit 侧收敛；SwiftUI 只做叶子视图，不持焦点 |

## 8. 实现记录（M3 落地，2026-10-25）

### 交付

| 目标 | 内容 |
|---|---|
| `Sources/PhotonsCore` | `DecoderCapabilities.swift`（D2′ 能力集 + 纯函数解析）、`CanvasPresenter.swift`（S4 纹理 → `CAMetalLayer`）、`Kernels/present.metal`；`RAWDecoder` 加 `decodeDetailed`（回读断言）、`DecodeCacheKey.decodeRecipe`、`DisplayOptions.headroom`、S4 `min(v, headroom)` |
| `Sources/PhotonsUI`（新 library） | `CatalogSession`（唯一 `@MainActor @Observable` 模型）、`ObservationBridge`（15 行）、`WorkspaceLayout`/`GridLayout`（纯函数）、`WorkspaceRootView`、`TopBarView`/`ToolButton`/`WorkspaceDivider`、`BrowserPaneController`、`AssetGridController`、`FilmstripController`、`LoupeController`、`InspectorView`、`EditorWindowController`、`MainMenu`、`UISmokeRunner` |
| `Sources/PhotonsApp`（新 executable） | `@main` + `AppDelegate` + 启动参数（`--library` / `--ui-smoke` / `--ui-bench` / `--seconds`） |
| `scripts/` | `bundle-app.sh`（Info.plist + 资源 bundle + ad-hoc 签名）、`App-Info.plist`、`ui-smoke.sh`、`ui-bench.sh` |
| `Makefile` | `app` / `ui-smoke` / `ui-bench`；**`verify` 未改**（仍是单命令，且不构建 app） |

### 实测（本机 Apple M1 Pro，macOS 27）

- `make verify` → ALL GREEN；单测 **60**（core 33 + catalog 17 + UI 10）。
- `make ui-smoke` → **SMOKE PASS (18 checks)**：1001 行库 → 网格 item 1001；三档窗口（1200/1600/2400）
  列数 3/6/11 且 itemSize 与 `GridLayout.metrics` 完全一致；filmstrip 1001、容器 122pt、共享 selection；
  loupe 渲出 3712×1808（= viewport）真帧。
- 10k 行占位网格滚动（**占位图，不含解码**，140 步）主线程 **p50 1.45 / p95 1.71 / p99 1.87 ms**，max 2.06 ms。
- loupe：首帧 **744 ms（解码 722 ms @scale 0.5 + 渲染 ~22 ms）**，二次渲染 **2.1 ms（解码缓存命中）**；
  进程内首帧的 S4 渲染含 kernel 首次编译（~0.9 s 的一次性成本，M1-1 已记录）。

### 偏差与取舍（除 §2b 已列的三条）

1. **多了一个 `PhotonsUI` library target**：纯布局函数与模型要能被 `PhotonsUITests` 单测；`PhotonsApp` 只留
   `@main` + `AppDelegate`（本机对「testTarget 依赖 executableTarget」不稳，不赌）。
2. **loupe 的呈现格式**：`CAMetalLayer` 首选 `rgba16Float` + `extendedLinearDisplayP3`（present shader 先做
   sRGB EOTF 反变换，>1 保留），拿不到 drawable 时一次性降级到 `bgra8Unorm` + sRGB 并重渲一帧。
   `wantsExtendedDynamicRangeContent = false` 常量，M3.5 只改这一个布尔 + `headroom`。
3. **ui-smoke 的 RAW 必须先复制进 fixtures 目录**：reference 导入的 root 按**卷**识别（M2 规则），
   同盘第二个目录的行会挂到第一个 root 上，relPath 全部指空。这是 M2 的既有行为，未改 M2。
4. **loupe 只做 fit**；`LoupeCanvasView.zoomToActualSize()` 留空接口，1:1 交互按规格不做。
5. **检查器不接渲染**（改字段只写模型）；SwiftUI 面板的主线程占用留给 M4 接真渲染前实测量。
6. golden 重录：`Tests/Golden/L1030433-v8-s1.0.json`、`render-edit-neutral-s0.25.json`、
   `render-edit-push-s0.25.json`（原因：解码固定 `boostAmount=0` + gamut off，解码输出变了）。
7. 观察到 `L1030433.dng` 渲染出来是 180°（`sips` 读不到 orientation tag，解码/渲染链路无从应用）；
   M3 不做方向映射，如实记录，未当作本阶段缺陷修。
