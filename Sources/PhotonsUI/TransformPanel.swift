import AppKit
import CoreGraphics
import PhotonsCore
import SwiftUI

// MARK: - 变换工作区：三张卡 —— 裁切 / 校正 / 变换（334）
//
// 用户的历次原话（2026-10-27 / 2026-10-28 / 2026-11-10）：
//
//   > 将裁切下拉菜单中的相关功能，移动到右侧第二栏「变换」，变换包括裁切、旋转等功能；点开变换窗口，
//   > **第一个卡片是裁切**；点按**直角尺图标**后进入裁切模式，出现裁切框。
//
//   > 右侧裁切模式的 UI 要重写，裁切、角度、旋转、镜像等要区分更大，现在挤在一起。
//
//   > 画线拉直的UI在哪？做到变换窗口中，另外变换窗口的卡片要重新改：透视从裁切中拿出来，现在有三个
//   > 卡片：裁切，校正，变换。裁切只含宽高比，常见比例的按钮(1:1 4:3 16:9 2:3)都放出来，不要做成
//   > 点击切换的模式。此外需要一个自定义比例的输入框。校正包括旋转、透视、以及新做的引导线UI，变换
//   > 包括旋转和镜像。旋转旁边的画线确定水平面功能，UI LOGO要改一下…用来和引导线UI区分开。
//
// 于是这张工作区是**三张卡**，顺序就是用户说的那三张：
//
//     裁切   宽高比（1:1 · 4:3 · 16:9 · 2:3 四个按钮常显）· 原始 / 自由 · 自定义比例
//            不出像素 · 九宫格          （336：取消 / 应用 已移到面板的固定页脚）
//     校正   拉直（滑杆 + 读数）· 画线拉直（水平仪 `level`）· 透视 垂直 · 透视 水平
//     变换   左转 / 右转 90° · 镜像 水平 / 垂直
//
// 336 — 取消 / 应用 不在任何一张卡里：它们是变换工作区的**固定页脚**（`CropApplyFooter`），与
// `ScrollView` 并列、贴在检查器右下角，滚卡片时不动。语义不变（应用 = 一次草稿 + 一条历史，
// 取消 = 文档一个字节不动）。
//
// 每张卡声明的 section 就是它的全部内容（`TransformCardSpec`），卡名双击复位的是那张卡 section
// 的字段并集 —— 三张卡互不越界。分区之间 12 pt，小标题与自己的内容之间 6 pt：244 pt 的面板里
// 不换行、不重叠、任何两行不相交（`CropCardSectionsTests` 量的是真实 frame）。
//
// ## 进变换就进裁切，卡头不再有开关
//
// 086：卡片名右边的直角尺按钮删掉了。进入「变换」工作区即进入裁切模式（幂等入口
// `LoupeController.enterCropToolIfNeeded()`），所以卡里的每一件都不再按 `isActive` 置灰；切出变换
// 工作区**不**强制退出裁切（用户没要求，087/088 再动）。
//
// ## 卡里不存第二份状态
//
// 每一个值都只读写两个地方，没有第三个：
//
//   · **草稿**（裁切框、滑块角度、比例锁）→ `CropToolController.draft`。应用时那一次 `apply()` 是唯一
//     写文档的地方（`CropToolController.apply`）。
//   · **文档**（水平/垂直翻转、`quarterTurns`、`straightenDegrees`、透视）→ `session.edit.geometry`，和
//     072 §F 说的一样只有一份：卡、菜单、裁切栏、⌘[ / ⌘] 读的是同一批字段。
//   · **纯视图态**（九宫格）→ `CropToolController.showsGrid`，不进文档、不进历史。
//
// `CropToolController` 是 `@Observable`，`CatalogSession` 本来就是，所以草稿的一个 tick、模式的一次
// 切换、文档的一次翻转/旋转都会让这些卡自己重画 —— 不需要调用方记得 `sync()`。
//
// ## 两个角度
//
// 「滑块角度」是 `draft.straighten`（−45…+45，校正卡的「拉直」行）；「实际角度」= 滑块角度 +
// 90 × quarterTurns（`CropToolController.actualAngle`）。093 起卡片上不再印只读读数 —— 滑块行自身
// 只显示滑块角度，悬浮栏的 `角度` 段仍印**实际角度**。

extension InspectorView {

    // MARK: - 第一张卡：裁切 —— 只有宽高比（334）

    /// 「裁切」: 宽高比 · 自定义比例 · 不出像素 · 九宫格 · 取消 / 应用.
    ///
    /// 334 (user): 「裁切只含宽高比…画线拉直的UI在哪？…变换窗口的卡片要重新改：透视从裁切中拿出来」.
    /// So this card owns **only** `CropSection.crop`: the four common ratios as four buttons that are
    /// always on screen (no cycling chip), 原始 / 自由, and a typed-ratio field. The straighten, the
    /// draw-a-line switch and the two keystone sliders are the 校正 card's, one card below.
    ///
    /// The title reset is the card's own `TransformCardSpec` union — `.cropRect + .aspectLock` — so a
    /// double-click here can no longer undo a straighten (that is 校正's).
    var cropTransformCard: some View {
        let tool = loupe?.cropTool
        let spec = TransformCardSpec.cropCard
        return InspectorCardShell(title: spec.title,
                                  reset: { resets.cropCard(spec) },
                                  accessory: { EmptyView() }) {
            VStack(alignment: .leading, spacing: Self.cropSectionGap) {
                CropAspectRow(tool: tool,
                              onReset: {
                                  _ = resets.reset(fields: CropSection.crop.fields,
                                                   label: CropSection.crop.title)
                              })
                cropStaysInsideRow(tool)
                // 336: 取消 / 应用 left this card — it is now the workspace's **fixed footer**
                // (`CropApplyFooter`, a sibling of the `ScrollView`), so the pair no longer scrolls
                // away with the cards. The card ends with 九宫格.
            }
        }
        // The card's own frame (「卡片清单第一张 = 裁切」 is measured on it) — behind the chrome, so the
        // number is the card's, not its content's.
        .background(CropRowProbeHost(rowID: CropCardID.card))
    }

    // MARK: - 第二张卡：校正 —— 拉直 + 画线拉直 + 透视（334）

    /// 「校正」: 拉直 → 画线拉直 → 垂直透视 → 水平透视.
    ///
    /// 334: the four geometry *repairs*. 328's 画线拉直 lives here now — the user asked where it was
    /// while it sat between two perspective sliders inside 裁切, so it gets its own row, under the
    /// slider it is the shortcut for, before the two keystone knobs.
    ///
    /// The title reset is `.straightenDegrees + .perspectiveVertical + .perspectiveHorizontal`; the
    /// crop rect and the turn keep what they hold.
    var correctionTransformCard: some View {
        let tool = loupe?.cropTool
        let spec = TransformCardSpec.correctionCard
        return InspectorCardShell(title: spec.title,
                                  reset: { resets.cropCard(spec) },
                                  accessory: { EmptyView() }) {
            VStack(alignment: .leading, spacing: Self.cropSectionGap) {
                cropStraightenSection(tool)
                cropDrawStraightenRow(tool)
                cropGuideLinesRow(tool)
                cropPerspectiveSection()
            }
        }
        .background(CropRowProbeHost(rowID: CropCardID.correctionCard))
    }

    // MARK: - 第三张卡：变换 —— 转向 + 镜像

    /// 「变换」 (087/093, re-titled by 334): 左转 / 右转 90° + 水平 / 垂直镜像。没有应用 / 取消 ——
    /// 旋转与镜像是一次文档动作，Esc 才是回退。其 title reset 是 `.rotation + .mirror`；比例、校正
    /// 属于前面两张卡，不被它碰。
    var angleTransformCard: some View {
        let tool = loupe?.cropTool
        let geometry = session.edit.geometry
        let spec = TransformCardSpec.rotationCard
        return InspectorCardShell(title: spec.title,
                                  reset: { resets.cropCard(spec) },
                                  accessory: { EmptyView() }) {
            VStack(alignment: .leading, spacing: Self.cropSectionGap) {
                cropRotationSection(geometry: geometry, tool: tool)
                cropMirrorSection(geometry: geometry, tool: tool)
            }
        }
        .background(CropRowProbeHost(rowID: CropCardID.angleCard))
    }

    /// 分区之间 12 pt（082 的「拉开间距」）。
    static let cropSectionGap: CGFloat = 12
    /// 小标题与其内容之间 6 pt。
    static let cropSectionTitleGap: CGFloat = 6

    // MARK: 底部：不出像素 / 九宫格

    /// 317 — 「不出像素」，卡片中间那一行（334: 它不再是「底部行」的一份子，应用/取消单独占最底一行）.
    @ViewBuilder
    private func cropStaysInsideRow(_ tool: CropToolController?) -> some View {
        // 343 (user): 「九宫格和不出像素做到同一行内，不出像素左对齐，九宫格右对齐」—— 两行并成一行，
        // 检查框占左边、九宫格 chip 贴右沿，中间是弹性空隙。
        HStack(spacing: 6) {
            StaysInsidePixelsCheckbox(isOn: tool?.cropStaysInsidePixels ?? false,
                                      onToggle: { tool?.setCropStaysInsidePixels($0) })
                .fixedSize()
                .background(CropRowProbeHost(rowID: CropCardID.staysInsidePixels))
            Spacer(minLength: 8)
            CropChip(title: "九宫格", on: tool?.showsGrid ?? true,
                     help: "裁切框上的三分线（视图态，不进文档）",
                     action: { loupe?.cropTool.toggleGrid() })
                .background(CropRowProbeHost(rowID: CropCardID.grid))
        }
    }

    /// 九宫格 — 视图态（`CropToolController.showsGrid`），不进文档、不进历史。334 起它自己一行，
    /// 在「不出像素」之下、应用/取消之上；id 沿用 086 的那一个。
    @ViewBuilder
    private func cropGridRow(_ tool: CropToolController?) -> some View {
        HStack(spacing: 6) {
            CropChip(title: "九宫格", on: tool?.showsGrid ?? true,
                     help: "裁切框上的三分线（视图态，不进文档）",
                     action: { loupe?.cropTool.toggleGrid() })
            Spacer(minLength: 4)
        }
        .background(CropRowProbeHost(rowID: CropCardID.grid))
    }

    // MARK: 拉直

    /// 拉直 — 滑杆 + 读数，行标签「拉直」（334: 原来是「角度」；校正卡里它说的是「把照片摆直」）。
    ///
    /// 087: the value is **live** — every tick writes the document, release commits one row
    /// (`onEditingChanged(false)`), so there is nothing left for 应用 to do. The crop frame keeps 086's
    /// draft semantics: only the straighten is written here.
    @ViewBuilder
    private func cropStraightenSection(_ tool: CropToolController?) -> some View {
        let straighten = Binding<Double>(get: { tool?.angleUIValue ?? 0 },
                                         set: { tool?.setAngle(uiValue: $0) })
        // 122 A: the old 「转动」 sub-header is gone — the straighten row sits directly under the card
        // title. The row keeps its reset, wired to the section's declaration.
        VStack(alignment: .leading, spacing: Self.cropSectionTitleGap) {
            sliderRow(CorrectionCardRow.straighten.title,
                      straighten,
                      -CropTool.straightenLimit ... CropTool.straightenLimit,
                      "%+.1f°",
                      decimals: 1,
                      enabled: true,
                      accessibilityID: "inspector.crop.angle",
                      onReset: {
                          _ = resets.reset(fields: CropSection.angle.fields,
                                           label: CropSection.angle.title)
                      },
                      onEditingChanged: { editing in
                          // 356 — press opens the gesture's session; the release writes the angle and
                          // closes it (`commitStraighten` → one row). Neither end asks the history.
                          if editing { session.beginToolGesture(tool: "裁切", label: "转动") }
                          else { _ = tool?.commitStraighten() }
                      })
        }
        .background(CropRowProbeHost(rowID: CorrectionCardRow.straighten.probeID))
    }

    // MARK: 画线拉直（328）

    /// 328 — 画线拉直：**自己一行**（334），水平仪图标 + 显示名. 进入「画线」状态后画布上的拖动
    /// 变成画一条线，松手按线的方向摆正；再点一次或 `Esc` 取消。
    @ViewBuilder
    private func cropDrawStraightenRow(_ tool: CropToolController?) -> some View {
        HStack(spacing: 6) {
            CropDrawStraightenToggle(on: tool?.isDrawStraightenArmed ?? false,
                                     enabled: tool?.isActive ?? false,
                                     action: { _ = tool?.toggleDrawStraighten() })
                .fixedSize()
            Text(CorrectionCardRow.drawStraighten.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
        }
        .background(CropRowProbeHost(rowID: CorrectionCardRow.drawStraighten.probeID))
    }

    // MARK: 引导线（337）

    /// 337 — 引导线：**自己一行**，紧贴「画线拉直」之下（用户：「校正包括旋转、透视、以及新做的
    /// 引导线UI」；§2.1 把行放在这里，图标 `perspective` 与 `level`、`ruler` 三者互不相同）。
    ///
    /// 开关 + 名字 + 一行读数：读数就是 `guideLineStatusText` —— 解出来的 `(v,h)` 与最坏残差，
    /// 或者这次为什么没生效（「这些线互相矛盾，未应用」「每个方向最多 2 条」…）。读数与按钮都有
    /// 自己的探针，`GuideLines337Tests` 按行量的是这一行。
    @ViewBuilder
    private func cropGuideLinesRow(_ tool: CropToolController?) -> some View {
        HStack(spacing: 6) {
            CropGuideLinesToggle(on: tool?.isGuideLinesArmed ?? false,
                                 enabled: tool?.isActive ?? false,
                                 action: { _ = tool?.toggleGuideLines() })
                .fixedSize()
            Text(CorrectionCardRow.guideLines.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let tool, !tool.guideLines.isEmpty {
                // 354 §2.5 — 「清除引导线」: every line goes, the picture stays (the lines are on the
                // card's own row, next to the switch, so it cannot be mistaken for Esc — which also
                // drops the tool — or for 双击线身, which deletes one line and re-solves).
                Button {
                    _ = tool.clearGuideLines()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("清除引导线")
                .accessibilityIdentifier(CorrectionCardRow.guideLines.clearID)
            }
            if let status = tool?.guideLineStatusText {
                Text(status)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier(CorrectionCardRow.guideLines.statusID)
            }
        }
        .background(CropRowProbeHost(rowID: CorrectionCardRow.guideLines.probeID))
    }

    // MARK: 透视

    /// 透视 — 垂直 / 水平两条滑杆（183）。两个字段都是**文档**（`GeometryGroup` 的那一对），
    /// 拖动时逐 tick 写、松手提交一行历史；0 是恒等，所以从未碰过的编辑不会多出行。
    ///
    /// 347 — 行程直接取 `PerspectiveMap.limit`（现在 ±200）：滑杆与夹取是**同一个数**，而强度
    /// 的分母是另一条常量（`strengthUnit` = 100），所以把行程拉宽只多出「更远处」，不改变已有读数
    /// 的含义。读数格式、双击复位、行的布局都是 183 原样。
    @ViewBuilder
    private func cropPerspectiveSection() -> some View {
        VStack(alignment: .leading, spacing: Self.cropSectionTitleGap) {
            CropSectionHeader(title: CropSection.perspective.title, isFirst: false, reset: {
                _ = resets.reset(fields: CropSection.perspective.fields,
                                 label: CropSection.perspective.title)
            })
            sliderRow(CorrectionCardRow.perspectiveVertical.title,
                      Binding(get: { session.edit.geometry.perspectiveVertical },
                              set: { value in
                                  session.applyEdit { $0.geometry.perspectiveVertical = value }
                              }),
                      -PerspectiveMap.limit ... PerspectiveMap.limit,
                      "%+.0f",
                      decimals: 0,
                      enabled: true,
                      accessibilityID: "inspector.crop.perspective.vertical",
                      onReset: {
                          session.applyEdit { $0.geometry.perspectiveVertical = 0 }
                          _ = session.commitEdit(label: "透视", coalesce: false)
                      },
                      onEditingChanged: { editing in
                          // 356 — the drag is the gesture: press opens its session, release closes it
                          // with one row. Nothing has to know whether a session happened to be open.
                          if editing { session.beginToolGesture(tool: "透视", label: "透视") }
                          else { session.endToolGesture(label: "透视", coalesce: true) }
                      })
                .background(CropRowProbeHost(rowID: CorrectionCardRow.perspectiveVertical.probeID))
            sliderRow(CorrectionCardRow.perspectiveHorizontal.title,
                      Binding(get: { session.edit.geometry.perspectiveHorizontal },
                              set: { value in
                                  session.applyEdit { $0.geometry.perspectiveHorizontal = value }
                              }),
                      -PerspectiveMap.limit ... PerspectiveMap.limit,
                      "%+.0f",
                      decimals: 0,
                      enabled: true,
                      accessibilityID: "inspector.crop.perspective.horizontal",
                      onReset: {
                          session.applyEdit { $0.geometry.perspectiveHorizontal = 0 }
                          _ = session.commitEdit(label: "透视", coalesce: false)
                      },
                      onEditingChanged: { editing in
                          // 356 — the same two ends as 垂直透视.
                          if editing { session.beginToolGesture(tool: "透视", label: "透视") }
                          else { session.endToolGesture(label: "透视", coalesce: true) }
                      })
                .background(CropRowProbeHost(rowID: CorrectionCardRow.perspectiveHorizontal.probeID))
        }
    }

    // MARK: 旋转

    /// 旋转 — 左旋 / 右旋 / 最右的角度。文档动作，⌘[ / ⌘] 同一个动词。
    @ViewBuilder
    private func cropRotationSection(geometry: GeometryGroup, tool: CropToolController?) -> some View {
        VStack(alignment: .leading, spacing: Self.cropSectionTitleGap) {
            CropSectionHeader(title: CropSection.rotation.title, isFirst: false,
                              reset: { resets.reset(fields: CropSection.rotation.fields,
                                                    label: CropSection.rotation.title) })
            CropTurnRow(turns: loupe?.quarterTurns ?? tool?.quarterTurns ?? geometry.quarterTurns,
                        isEnabled: loupe != nil || tool != nil,
                        onCounterClockwise: { turn(clockwise: false, tool: tool) },
                        onClockwise: { turn(clockwise: true, tool: tool) })
                .background(CropRowProbeHost(rowID: CropCardID.turn))
        }
    }

    // MARK: 镜像

    /// 镜像 — 水平 / 垂直。文档动作，和 072 §F 的菜单项同一个位。
    @ViewBuilder
    private func cropMirrorSection(geometry: GeometryGroup, tool: CropToolController?) -> some View {
        VStack(alignment: .leading, spacing: Self.cropSectionTitleGap) {
            CropSectionHeader(title: CropSection.mirror.title, isFirst: false,
                              reset: { resets.reset(fields: CropSection.mirror.fields,
                                                    label: CropSection.mirror.title) })
            CropMirrorRow(horizontal: geometry.flipHorizontal,
                          vertical: geometry.flipVertical,
                          onHorizontal: { flip(horizontal: true, tool: tool) },
                          onVertical: { flip(horizontal: false, tool: tool) })
                .background(CropRowProbeHost(rowID: CropCardID.mirror))
        }
    }

    // MARK: the two document verbs

    /// 逆时针 / 顺时针旋转 90° — **文档动作** (P0-10), with a loupe the verb goes through it (one
    /// document write, one history row, one render); without one (the panel hosted on its own) it
    /// writes the same document through the tool's session. Never a second state: `quarterTurns` is
    /// `GeometryGroup`'s field.
    private func turn(clockwise: Bool, tool: CropToolController?) {
        if let loupe {
            _ = loupe.rotateQuarter(clockwise: clockwise)
            return
        }
        _ = tool?.rotateQuarter(clockwise: clockwise)
    }

    /// 水平 / 垂直翻转 — **文档动作**，和 072 §F 的菜单项、裁切栏的两个开关同一个位。
    private func flip(horizontal: Bool, tool: CropToolController?) {
        // 087: inside the transform workspace a crop session is open, and `CropToolController.flip`
        // is the door that closes/reopens it around its own row — `LoupeController.flip` would leave
        // the change uncommitted until 应用.
        if let tool {
            if horizontal { tool.toggleFlipHorizontal() } else { tool.toggleFlipVertical() }
            return
        }
        if let loupe {
            if horizontal { loupe.flipHorizontal() } else { loupe.flipVertical() }
        }
    }
}

/// The 校正 card's rows, in the order they are stacked (334) — one spelling for the row labels, the
/// probes and the acceptance.
///
/// 334 (user): 「校正包括旋转、透视、以及新做的引导线UI」 → 拉直 → 画线拉直 → 垂直透视 → 水平透视.
/// The probe ids are the ones 328/183 already used, so nothing that measured a perspective slider
/// moved: only the card the rows live in did.
public enum CorrectionCardRow: String, CaseIterable, Sendable, Hashable {
    case straighten = "angle"
    case drawStraighten = "drawStraighten"
    /// 337 — 「引导线」, directly under 画线拉直 and above the two keystone sliders. It is a *row*,
    /// not a section: it changes the same two fields 透视 does, and the card's section list is
    /// unchanged (`CropSection.perspective` still owns both sliders and the fit writes their values).
    case guideLines = "guideLines"
    case perspectiveVertical = "perspective.vertical"
    case perspectiveHorizontal = "perspective.horizontal"

    /// The row's display name — what the card prints next to its slider / button.
    public var title: String {
        switch self {
        case .straighten: return "拉直"
        case .drawStraighten: return "画线拉直"
        case .guideLines: return "引导线"
        case .perspectiveVertical: return "垂直透视"
        case .perspectiveHorizontal: return "水平透视"
        }
    }

    /// The `CropRowProbe` id the row's own frame is measured under.
    public var probeID: String { rawValue }

    /// 337 — the row's status label (the fit's `(v,h)` and residual, or why it did not take).
    public var statusID: String { "inspector.crop.\(rawValue).status" }

    /// 354 — 「清除引导线」, on the same row (only drawn while there are lines).
    public var clearID: String { "inspector.crop.\(rawValue).clear" }
}

// MARK: - 082: the section names

/// The card's sections — one spelling for the header, the reset verb and the tests. 214: each case
/// also declares the geometry fields it owns (`TransformCardSpec.swift`), and the cards declare which
/// sections they contain.
public enum CropSection: String, CaseIterable, Sendable, Hashable {
    case crop
    case angle
    case perspective
    case rotation
    case mirror

    public var title: String {
        switch self {
        // 086: the first section's small title is the user's new word. The *card* title (「裁切」) is
        // `InspectorView.Section.crop.title` and is not this enum, so it does not move with this.
        case .crop: return "宽高比"
        case .angle: return "角度"
        // 183: 透视 — the two keystone knobs. It is a first-class section (not a bare header inside
        // the panel) so that "nothing else calls itself a section" (082 §4) stays checkable.
        case .perspective: return "透视"
        case .rotation: return "旋转"
        case .mirror: return "镜像"
        }
    }

    /// The order they are stacked in, top to bottom — 214: the cards' own declarations are the source,
    /// so a section that moves between cards moves here too.
    public static var displayOrder: [CropSection] { TransformCardSpec.all.flatMap(\.sections) }

    /// 087 / 214: the second card's sections, in the user's order.
    public static var angleCardOrder: [CropSection] { TransformCardSpec.rotationCard.sections }

    /// The accessibility / probe id of the section's small title.
    public var headerID: String { "inspector.crop.section.\(rawValue)" }
}

// MARK: - the section header

/// One section's small title: a hairline, then an 11 pt secondary label.
///
/// The hairline is the 「视觉分隔线」 the user asked for (the sections have to *look* separated, not
/// only be spaced); the first section has none, because the card's own top edge is the line above it.
/// Double-clicking the title is the section's reset — the same `ResetOnDoubleClick` gesture every
/// other card uses, wired to that section's `fields` (`PanelResets.reset(fields:)`).
struct CropSectionHeader: View {

    let title: String
    let isFirst: Bool
    let reset: () -> Void

    static let titleFontSize: CGFloat = 11
    static let hairlineOpacity: Double = 0.08

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isFirst {
                Rectangle()
                    .fill(Color.primary.opacity(Self.hairlineOpacity))
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
            CropSectionTitle(title: title, reset: reset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CropRowProbeHost(rowID: "section.\(title)"))
    }
}

/// One section's small title, on its own or at the head of a row (086: 宽高比 shares its line with the
/// ratio picker and ⇄).
struct CropSectionTitle: View {

    let title: String
    let reset: () -> Void

    var body: some View {
        Text(title)
            .font(.system(size: CropSectionHeader.titleFontSize, weight: .medium))
            .foregroundStyle(.secondary)
            .modifier(ResetOnDoubleClick(action: reset, help: "双击复位「\(title)」"))
            .accessibilityIdentifier("inspector.crop.section.\(title)")
    }
}

// MARK: - the 宽高比 row（334: four buttons + 原始/自由 + typed ratio）

/// 334 — 宽高比: 小标题「宽高比」· **1:1 · 4:3 · 16:9 · 2:3 四个按钮并排常显** · 原始 / 自由 · 自定义比例.
///
/// The user (2026-11-10): 「裁切只含宽高比，常见比例的按钮(1:1 4:3 16:9 2:3)都放出来，不要做成点击
/// 切换的模式。此外需要一个自定义比例的输入框」. So 104's cycling chip — one button that walked
/// `原始 → 1:1 → 4:3 → 3:2 → 16:9 → 自由` — is gone: every common ratio is a button of its own, the
/// current lock is drawn as that button's pressed state, and 原始 / 自由 keep their own two buttons
/// because they are the ways *out* of a lock (without them the frame could never be released).
///
/// Nothing here stores state: the buttons call `CropToolController.setAspect` / `setCustomRatio` (the
/// same verbs the chip and the old popup called), and the typed ratio goes through
/// `CropRatioPanels.commit` — parse, write, or beep and change nothing.
struct CropAspectRow: View {

    let tool: CropToolController?
    /// 小标题「宽高比」的双击复位（`PanelResets.reset(fields: CropSection.crop.fields)`）—— the row
    /// cannot reach `resets` itself, so the card hands it in.
    let onReset: () -> Void

    /// 行 id —— 测试按它找这一行真实的 frame（四个比例按钮那一行）.
    static let probeID = "aspect"
    /// 原始 / 自由 那一行.
    static let extrasProbeID = "aspect.extras"
    /// 自定义比例那一行.
    static let customProbeID = "aspect.custom"

    /// 四个常见比例，用户的顺序（334）.
    static let ratioButtons: [RatioButton] = [.square, .fourThree, .sixteenNine, .twoThree]
    /// 每个按钮的最小宽度：验收要求 244 pt 卡宽下同排、每颗 ≥ 40 pt.
    static let minimumButtonWidth: CGFloat = 40
    static let buttonHeight: CGFloat = 18
    static let customFieldWidth: CGFloat = 76

    /// 「原始」 / 「自由」 的 id.
    static let originalID = "inspector.crop.ratio.original"
    static let freeID = "inspector.crop.ratio.free"
    /// 自定义比例字段的 id（334：`crop.ratio.custom`）.
    static let customID = "inspector.crop.ratio.custom"
    /// 自定义比例的图标 —— **不是**画线拉直的水平仪（`level`）：334 要求两者的 LOGO 一眼分得开.
    static let customSymbol = "ruler"

    /// ⇄ 交换长宽的 id 与命中尺寸 —— 344 之前的 086 版本就住在这两个名字上，spec 与验收都按它找.
    static let swapID = "inspector.crop.ratio.swap"
    static let swapProbeID = "aspect.swap"
    static let swapHitSize: CGFloat = 18

    @State private var typed: String = ""
    /// 334: bumped on **every** commit attempt — including a refused one, whose text does not change.
    /// Without it SwiftUI sees no state change and the field would keep the junk string on screen.
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorView.cropSectionTitleGap) {
            HStack(spacing: 6) {
                CropSectionTitle(title: CropSection.crop.title, reset: onReset)
                    .background(CropRowProbeHost(rowID: CropCardID.section(.crop)))
                Spacer(minLength: 2)
            }

            // 四个比例按钮：并排常显、等宽（不是点一下轮换的 chip）.
            HStack(spacing: 6) {
                ForEach(Self.ratioButtons, id: \.self) { button in
                    RatioPresetButtonHost(title: button.title,
                                          isOn: Self.isOn(button, tool: tool),
                                          isEnabled: tool != nil,
                                          identifierID: button.identifier,
                                          action: { button.apply(to: tool) })
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.buttonHeight)
                }
            }
            .background(CropRowProbeHost(rowID: Self.probeID))
            .accessibilityIdentifier("inspector.crop.row.\(Self.probeID)")
            // 086/334: the readback seam that proves a ratio row is never greyed out with no tool either.
            .background(DetailRowEnabledProbe(title: CropSection.crop.title))

            // 原始 / 自由：两道解掉约束的门。
            // 343 (user): 「原始和自由的宽度和 1:1 4:3 这些保持一致」—— 它们排在**同一个四列栅格**里
            // （各占一格、后两格留空），所以宽度由同一套 `maxWidth: .infinity` 算出，不会比比例按钮窄。
            HStack(spacing: 6) {
                RatioPresetButtonHost(title: CropAspectPreset.original.displayName,
                                      isOn: tool?.aspectPreset() == .original,
                                      isEnabled: tool != nil,
                                      identifierID: Self.originalID,
                                      action: { tool?.setAspect(.original) })
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.buttonHeight)
                RatioPresetButtonHost(title: CropAspectPreset.free.displayName,
                                      isOn: tool?.isAspectFree ?? true,
                                      isEnabled: tool != nil,
                                      identifierID: Self.freeID,
                                      action: { tool?.setAspect(.free) })
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.buttonHeight)
                ForEach(0..<2, id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity).frame(height: Self.buttonHeight)
                }
            }
            .background(CropRowProbeHost(rowID: Self.extrasProbeID))

            // 自定义比例：`ruler` + 可键入字段（`5:4` / `1.85`）+ ⇄ 交换（2026-11-12 用户）.
            //
            // 用户口径：「⇄ 放在九宫格上方，自定义比例同一行」. It came back here after 334 dropped the
            // 086 version that sat next to the ratio popup: the four-button row is a full four-column
            // grid now, so the swap lives on this row, right-aligned after the typed field.
            HStack(spacing: 6) {
                Image(systemName: Self.customSymbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                CustomRatioFieldHost(text: typed,
                                     revision: revision,
                                     onCommit: { commit($0) },
                                     onCancel: {
                                         typed = Self.fieldText(for: tool)
                                         revision &+= 1
                                     })
                    .frame(width: Self.customFieldWidth, height: Self.buttonHeight)
                Spacer(minLength: 4)
                // ⇄ — 交换长宽 (§C1). A *value* operation on the current lock, not another preset: one
                // press makes 2:3 into 3:2 (and back), whatever the frame's own orientation is.
                SwapAspectButtonHost(isEnabled: tool != nil,
                                     action: {
                                         _ = tool?.swapAspect()
                                         // The typed field mirrors the lock; a swap changes it (`2:3` ⇄ `3:2`).
                                         typed = Self.fieldText(for: tool)
                                         revision &+= 1
                                     })
                    .frame(width: Self.swapHitSize, height: Self.swapHitSize)
                    .help("交换长宽")
                    .background(CropRowProbeHost(rowID: Self.swapProbeID))
            }
            .background(CropRowProbeHost(rowID: Self.customProbeID))
        }
        .onAppear { typed = Self.fieldText(for: tool) }
    }

    /// Is this button the lock in force?
    ///
    /// 2:3 is an explicit `custom(2/3)` or `custom(3/2)` (there is no named case for either), and which
    /// one it lights up for is the **document's** current lock — not the frame's orientation. That
    /// matters: after clicking 2:3 on a landscape frame the lock is `custom(1.5)`, the button stays
    /// lit, and pressing ⇄ once makes it `custom(2/3)` — still the same button, still lit, now portrait.
    ///
    /// `.original` (自由) carries **no** ratio, so none of the four is in force and all four are off.
    /// That is not the same as 原始: 原始 writes `.matching(source:)`, a real constraint (3:2 on a 3:2
    /// frame), and the button for it lights up. Only 自由 has nothing to show.
    static func isOn(_ button: RatioButton, tool: CropToolController?) -> Bool {
        guard let tool else { return false }
        guard let current = tool.draft.lock.ratio else { return false }
        // Compare by ratio, not by spelling: `custom(1.5)` and `.threeTwo` are the same constraint, so
        // the 2:3 button stays lit across a swap into 3:2 — and it is lit for **both** orientations of
        // the 3:2 family, because which one the button would produce depends on the frame, not on the
        // document's current spelling.
        switch button {
        case .square:
            return abs(current - 1) <= 1e-6
        case .fourThree:
            return abs(current - 4.0 / 3.0) <= 1e-6
        case .sixteenNine:
            return abs(current - 16.0 / 9.0) <= 1e-6
        case .twoThree:
            return abs(abs(current) - 3.0 / 2.0) <= 1e-6
        }
    }

    /// What the typed field shows: the custom ratio in force as `W:H`, else empty (the placeholder
    /// says what to type). Read from the draft — the field keeps no second copy of the lock.
    static func fieldText(for tool: CropToolController?) -> String {
        guard let tool, case .custom(let ratio) = tool.draft.lock,
              ratio.isFinite, ratio > 0 else { return "" }
        return customRatioText(ratio)
    }

    /// `1.25 → 5:4`, `16/9 → 16:9`, `0.01 → 1:100`; denominators up to 100 (the parser's limit keeps
    /// a typed `W:H` in that neighbourhood), else a `%.4g:1` fallback.
    static func customRatioText(_ ratio: Double) -> String {
        guard ratio.isFinite, ratio > 0 else { return "—" }
        for denominator in 1...100 {
            let numerator = (ratio * Double(denominator)).rounded()
            guard numerator >= 1 else { continue }
            let error = abs(ratio - numerator / Double(denominator))
            if error <= 1e-9 * Double(denominator) {
                return "\(Int(numerator)):\(denominator)"
            }
        }
        return String(format: "%.4g:1", ratio)
    }

    /// One `W:H` / decimal commit, in the same place whether it came from the keyboard or a test:
    /// parse, write, or beep and change nothing. The field then shows what the draft now holds, so a
    /// refused string leaves the old text.
    private func commit(_ text: String) {
        if let tool { _ = CropRatioPanels.shared.commit(text, to: tool) }
        typed = Self.fieldText(for: tool)
        revision &+= 1
    }
}

// MARK: - 334: the four ratio buttons

/// 334 — one of the four common ratios: 1:1 · 4:3 · 16:9 · 2:3.
///
/// `AspectLock` carries three of them by name; 2:3 is the same explicit `custom(2/3)` the typed field
/// would produce, because the enum deliberately has no fourth named ratio.
enum RatioButton: String, CaseIterable, Sendable, Hashable {
    case square = "1x1"
    case fourThree = "4x3"
    case sixteenNine = "16x9"
    case twoThree = "2x3"

    var title: String {
        switch self {
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .sixteenNine: return "16:9"
        case .twoThree: return "2:3"
        }
    }

    /// The button's accessibility identifier — `crop.ratio.<n>`, one spelling for the view and the
    /// acceptance (`inspector.crop.ratio.16x9`).
    var identifier: String { "inspector.crop.ratio.\(rawValue)" }

    /// The lock this button means on a frame of a given orientation.
    ///
    /// 2026-11-12 (user): 「用户点击 2:3 时…进入的是 2:3 还是 3:2 取决于当前裁剪框的左右和上下高度比，
    /// 左右长那么就是用比例中更大的（如 3）」. So 2:3 is the **3:2 family** button: it is 3:2 on a
    /// landscape frame and 2:3 on a portrait one, read fresh on every click. The other three are
    /// symmetric in name only — 1:1 is its own reciprocal, and 4:3 / 16:9 keep their single spelling
    /// until the user asks for them to follow the frame too.
    func lock(landscape: Bool) -> AspectLock {
        switch self {
        case .square: return .square
        case .fourThree: return .fourThree
        case .sixteenNine: return .sixteenNine
        case .twoThree:
            return .custom(CropToolController.oriented(2.0 / 3.0, landscape: landscape))
        }
    }

    /// One click = that lock — through the preset verb where a named preset exists (so 原始's memory
    /// and the 🔒 rules behave exactly as they did), through `setCustomRatio` for 2:3.
    ///
    /// 2:3 reads the frame's orientation **at click time** (`frameIsLandscape`), so the same button
    /// gives 3:2 on a landscape frame and 2:3 on a portrait one — and `setCustomRatio` remembers the
    /// ratio it was given, so 🔓 brings back the orientation the user last chose, not the other one.
    @MainActor
    func apply(to tool: CropToolController?) {
        guard let tool else { return }
        switch self {
        case .square: tool.setAspect(.square)
        case .fourThree: tool.setAspect(.fourThree)
        case .sixteenNine: tool.setAspect(.sixteenNine)
        case .twoThree:
            _ = tool.setCustomRatio(CropToolController.oriented(2.0 / 3.0,
                                                                landscape: tool.frameIsLandscape()))
        }
    }
}

/// One ratio button. A real `NSButton` for the reason every leaf in this card is AppKit: the
/// acceptance clicks it through `performClick(_:)` and reads its pressed state without an event loop.
final class RatioPresetButton: NSButton {

    static let cornerRadius: CGFloat = 5
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

    private(set) var titleText: String = ""
    private(set) var isOn = false

    init(title: String, isOn: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: CropAspectRow.minimumButtonWidth,
                                 height: CropAspectRow.buttonHeight))
        isBordered = false
        bezelStyle = .inline
        setButtonType(.toggle)
        alignment = .center
        cell?.lineBreakMode = .byClipping       // 验收：卡宽 244 pt 下不出现「…」
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.borderWidth = 1
        target = self
        action = #selector(fire)
        setAccessibilityLabel(title)
        refresh(title: title, isOn: isOn, isEnabled: true)
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CropAspectRow.minimumButtonWidth, height: CropAspectRow.buttonHeight)
    }
    override var isFlipped: Bool { true }

    @objc private func fire() { }

    /// `isOn` is the pressed state the user asked to *see* the current lock in: accent fill + white
    /// glyph; off is the card's own material + a hairline, like the 九宫格 chip.
    func refresh(title: String, isOn: Bool, isEnabled: Bool) {
        titleText = title
        self.isOn = isOn
        self.isEnabled = isEnabled
        state = isOn ? .on : .off
        let colour: NSColor = isOn ? .white : .labelColor
        self.title = title
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Self.font,
            .foregroundColor: colour,
        ])
        layer?.backgroundColor = isOn
            ? NSColor.controlAccentColor.cgColor
            : NSColor.labelColor.withAlphaComponent(0.05).cgColor
        layer?.borderColor = isOn
            ? NSColor.controlAccentColor.cgColor
            : NSColor.tertiaryLabelColor.withAlphaComponent(0.6).cgColor
        setAccessibilityValue(isOn ? "已选中" : "未选中")
        invalidateIntrinsicContentSize()
    }
}

struct RatioPresetButtonHost: NSViewRepresentable {

    let title: String
    let isOn: Bool
    let isEnabled: Bool
    let identifierID: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> RatioPresetButton {
        let button = RatioPresetButton(title: title, isOn: isOn)
        button.setAccessibilityIdentifier(identifierID)
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.refresh(title: title, isOn: isOn, isEnabled: isEnabled)
        return button
    }

    func updateNSView(_ button: RatioPresetButton, context: Context) {
        context.coordinator.action = action
        button.setAccessibilityIdentifier(identifierID)
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.refresh(title: title, isOn: isOn, isEnabled: isEnabled)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

// MARK: - 2026-11-12: the ⇄ swap button

/// The ⇄ button — a real `NSButton`, for the same reason every leaf in this card is AppKit: the
/// acceptance clicks it through `performClick(_:)` and reads its frame, and a SwiftUI `Button` does not
/// expose either to an `NSView` walk (its identifier lands on an accessibility element, not a view).
///
/// 2026-11-12 (user): the swap disappeared with the 334 rewrite (it used to sit next to the ratio
/// popup) and came back **on the custom-ratio row**: 「⇄ 放在九宫格上方，自定义比例同一行」.
final class SwapAspectButton: NSButton {

    static let font = NSFont.systemFont(ofSize: 10)

    init(enabled: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: CropAspectRow.swapHitSize,
                                 height: CropAspectRow.swapHitSize))
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryPushIn)
        alignment = .center
        wantsLayer = true
        attributedTitle = NSAttributedString(string: "⇄", attributes: [.font: Self.font])
        setAccessibilityLabel("交换长宽")
        refresh(enabled: enabled)
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CropAspectRow.swapHitSize, height: CropAspectRow.swapHitSize)
    }
    override var isFlipped: Bool { true }

    func refresh(enabled: Bool) {
        isEnabled = enabled
        contentTintColor = enabled ? .labelColor : .tertiaryLabelColor
        setAccessibilityValue(enabled ? "可交换" : "无裁切工具")
    }
}

struct SwapAspectButtonHost: NSViewRepresentable {

    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> SwapAspectButton {
        let button = SwapAspectButton(enabled: isEnabled)
        button.setAccessibilityIdentifier(CropAspectRow.swapID)
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        return button
    }

    func updateNSView(_ button: SwapAspectButton, context: Context) {
        context.coordinator.action = action
        button.setAccessibilityIdentifier(CropAspectRow.swapID)
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.refresh(enabled: isEnabled)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

// MARK: - 334: the typed ratio (always on screen, no panel)

/// 334 — the card's **custom ratio field**: always visible (the user: 「需要一个自定义比例的输入框」),
/// `5:4` and `1.85` both accepted, `↵` commits, `Esc` **or a click elsewhere** puts the stored ratio
/// back (blur is not a commit — the angle row's rule). Junk beeps and writes nothing.
///
/// It does **not** store the ratio: `CropTool.ratio(from:)` + `CropToolController.setCustomRatio`
/// write the draft's lock, and the last text is a UI preference (`CropToolBar.lastCustomRatioText`),
/// never a document field.
final class CustomRatioField: NSTextField, NSTextFieldDelegate {

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private var finished = false

    init(text: String) {
        super.init(frame: .zero)
        stringValue = text
        placeholderString = "5:4"
        font = Self.font
        isEditable = true
        isSelectable = true
        isBezeled = true
        bezelStyle = .squareBezel
        drawsBackground = true
        controlSize = .mini
        focusRingType = .default
        alignment = .center
        toolTip = "键入比例：5:4 或 1.85（回车生效，非法输入不写入）"
        delegate = self
        target = self
        action = #selector(commitAction)
        setAccessibilityIdentifier(CropAspectRow.customID)
        setAccessibilityLabel("自定义比例")
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CropAspectRow.customFieldWidth, height: CropAspectRow.buttonHeight)
    }
    override var isFlipped: Bool { true }

    /// The card pushes the draft's text in; the field is never a second source of truth, and it does
    /// not steal focus when the workspace appears (it is not a transient editor like 104's chip swap).
    func refresh(text: String) {
        guard currentEditor() == nil, stringValue != text else { return }
        stringValue = text
    }

    @objc private func commitAction() { finish(commit: true) }

    func controlTextDidBeginEditing(_ obj: Notification) { finished = false }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            finish(commit: true)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            finish(commit: false)
            return true
        }
        return false
    }

    /// Blur is **not** a commit: it closes the editor and keeps the old ratio.
    func controlTextDidEndEditing(_ obj: Notification) {
        if !finished { finish(commit: false) }
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        if commit { onCommit?(stringValue) } else { onCancel?() }
    }

    /// `↵` for the acceptance (the real path is the field editor's `doCommandBy`).
    func commitForTesting() {
        finished = false
        finish(commit: true)
    }
    /// `Esc` / blur for the acceptance.
    func cancelForTesting() {
        finished = false
        finish(commit: false)
    }
}

struct CustomRatioFieldHost: NSViewRepresentable {

    let text: String
    /// Any change re-pushes `text` into the field, even when `text` is the same string (a refused
    /// commit) — that is how the junk text gets replaced by the ratio the draft still holds.
    let revision: Int
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CustomRatioField {
        let field = CustomRatioField(text: text)
        field.onCommit = onCommit
        field.onCancel = onCancel
        return field
    }

    func updateNSView(_ field: CustomRatioField, context: Context) {
        field.onCommit = onCommit
        field.onCancel = onCancel
        field.refresh(text: text)
    }
}

/// 镜像：水平 / 垂直两个裸图标（087）。开着时图标用强调色，关着时是普通文字色。
struct CropMirrorRow: View {

    let horizontal: Bool
    let vertical: Bool
    let onHorizontal: () -> Void
    let onVertical: () -> Void

    static let probeID = "mirror"
    static let horizontalID = "inspector.crop.mirror.horizontal"
    static let verticalID = "inspector.crop.mirror.vertical"

    var body: some View {
        HStack(spacing: 6) {
            MirrorButtonHost(symbol: "flip.horizontal", title: "水平翻转", isOn: horizontal,
                             identifierID: Self.horizontalID, action: onHorizontal)
                .fixedSize()
            MirrorButtonHost(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                             title: "垂直翻转", isOn: vertical,
                             identifierID: Self.verticalID, action: onVertical)
                .fixedSize()
            Spacer(minLength: 4)
        }
        .accessibilityIdentifier("inspector.crop.row.\(Self.probeID)")
    }
}

/// 旋转 90°：左旋、右旋两个按钮，**最右侧**是当前角度（P0-10；093 挪到右边、去掉背景块）。
///
/// 三个值，一份真相：`turns` 是文档的 `GeometryGroup.quarterTurns`（0…3 顺时针），两个按钮只调
/// `LoupeController.rotateQuarter(clockwise:)` —— 和菜单的 ⌘[ / ⌘] 同一个动词，所以按钮、快捷键、
/// 角度、`tiff:Orientation` 不会各说一套。
///
/// 与「角度」区不同，这一区**不需要进入裁切模式**：旋转和两个翻转一样是文档动作，裁切框关着的时候
/// 一样能转（徽标照样读文档）。
struct CropTurnRow: View {

    let turns: Int
    let isEnabled: Bool
    let onCounterClockwise: () -> Void
    let onClockwise: () -> Void

    static let probeID = "turn"
    static let badgeID = "inspector.crop.turn.badge"
    static let counterClockwiseID = "inspector.crop.turn.ccw"
    static let clockwiseID = "inspector.crop.turn.cw"

    var body: some View {
        HStack(spacing: 6) {
            // `.fixedSize()`: the leaves are `NSView`s, and without it SwiftUI proposes the row's
            // width and AppKit stretches them (measured: two 88 pt buttons in a 308 pt card).
            TurnButtonHost(symbol: "rotate.left", title: "逆时针旋转 90°",
                           identifierID: Self.counterClockwiseID,
                           isEnabled: isEnabled, action: onCounterClockwise)
                .fixedSize()
            TurnButtonHost(symbol: "rotate.right", title: "顺时针旋转 90°",
                           identifierID: Self.clockwiseID,
                           isEnabled: isEnabled, action: onClockwise)
                .fixedSize()
            Spacer(minLength: 4)
            TurnBadgeHost(text: LoupeController.quarterTurnBadge(for: turns),
                          isTurned: GeometryGroup.normalizedQuarterTurns(turns) != 0)
                .fixedSize()
        }
        .accessibilityIdentifier("inspector.crop.row.\(Self.probeID)")
    }
}

/// 一个裸图标按钮：固定方形、无边框，只有 hover 时才出现浅底。
///
/// 087: the shape the card header's old ruler button used before 086 removed it — the two turn
/// icons and the two mirror icons are the same leaf. `contentTintColor` is the one colour decision:
/// the rotation icons stay in label colour, the mirror icons turn accent while on.
///
/// It is a real `NSButton` for the reason every leaf in this card is AppKit: the panel acceptance
/// clicks it through `performClick(_:)` and reads `isBordered` / `contentTintColor`.
class BareIconButton: NSButton {

    static let size = NSSize(width: 20, height: 20)
    static let glyphPointSize: CGFloat = 11
    static let cornerRadius: CGFloat = 5

    let symbol: String
    let titleText: String
    /// Mirror: on = accent. Rotation leaves it `false` and the tint never changes.
    var accentWhenOn = false
    var isOn = false { didSet { if isOn != oldValue { refresh() } } }

    private var hovering = false
    private var trackingArea: NSTrackingArea?

    init(symbol: String, title: String, accentWhenOn: Bool = false) {
        self.symbol = symbol
        self.titleText = title
        self.accentWhenOn = accentWhenOn
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Self.glyphPointSize,
                                                                 weight: .regular))
        toolTip = title + "（一次 ⌘Z）"
        setAccessibilityLabel(title)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var intrinsicContentSize: NSSize { Self.size }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refresh()
    }

    func refresh() {
        contentTintColor = accentWhenOn && isOn ? .controlAccentColor : .labelColor
        layer?.backgroundColor = hovering
            ? NSColor.labelColor.withAlphaComponent(0.06).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = 0
        needsDisplay = true
    }
}

/// A 90° turn button — `rotate.left` / `rotate.right`, never accent (087).
final class TurnButton: BareIconButton {

    init(symbol: String, title: String) {
        super.init(symbol: symbol, title: title, accentWhenOn: false)
        setAccessibilityIdentifier(title)
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }
}

/// A mirror button — horizontal (`flip.horizontal`) / vertical (`arrow.up.and.down.righttriangle…`),
/// accent while on (087). 093: `flip.vertical` has no glyph on this SDK, so the vertical leaf uses
/// its long-form counterpart.
final class MirrorButton: BareIconButton {

    init(symbol: String, title: String, isOn: Bool) {
        super.init(symbol: symbol, title: title, accentWhenOn: true)
        self.isOn = isOn
        setAccessibilityIdentifier(title)
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }
}

/// `TurnButton` in SwiftUI: the three inputs and the one verb behind it.
struct TurnButtonHost: NSViewRepresentable {

    let symbol: String
    let title: String
    /// The accessibility id the test looks the button up by (one spelling everywhere).
    let identifierID: String
    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> TurnButton {
        let button = TurnButton(symbol: symbol, title: title)
        button.setAccessibilityIdentifier(identifierID)
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.isEnabled = isEnabled
        return button
    }

    func updateNSView(_ button: TurnButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = isEnabled
        button.setAccessibilityIdentifier(identifierID)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

/// `MirrorButton` in SwiftUI: the two inputs (on/off) and the one verb behind it.
struct MirrorButtonHost: NSViewRepresentable {

    let symbol: String
    let title: String
    let isOn: Bool
    let identifierID: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> MirrorButton {
        let button = MirrorButton(symbol: symbol, title: title, isOn: isOn)
        button.setAccessibilityIdentifier(identifierID)
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        return button
    }

    func updateNSView(_ button: MirrorButton, context: Context) {
        context.coordinator.action = action
        button.isOn = isOn
        button.setAccessibilityIdentifier(identifierID)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

/// 当前方向的徽标 —— `0° 90° 180° 270°`（顺时针），读文档，不做第二份状态。
///
/// 一个 `NSTextField` 而不是 SwiftUI `Text`：面板验收要**读**这个字（见 `CropTurnRow`）。
final class TurnBadgeLabel: NSTextField {

    static let height: CGFloat = CropChip.height

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        isBezeled = false
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        setAccessibilityIdentifier(CropTurnRow.badgeID)
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: TurnBadgeLabel.height)
    }
    override var isFlipped: Bool { true }

    /// `turns % 4 == 0` is the neutral direction: secondary ink, like the switch labels. Anything
    /// else is a document that has been turned, and it speaks in the accent colour.
    func refresh(_ text: String, isTurned: Bool) {
        stringValue = text
        textColor = isTurned ? .controlAccentColor : .secondaryLabelColor
        toolTip = "当前方向：顺时针 \(text)（4 次回到原位，逐字节相同）"
        setAccessibilityValue(text)
        invalidateIntrinsicContentSize()
    }
}

struct TurnBadgeHost: NSViewRepresentable {

    let text: String
    let isTurned: Bool

    func makeNSView(context: Context) -> TurnBadgeLabel {
        let label = TurnBadgeLabel()
        label.refresh(text, isTurned: isTurned)
        return label
    }

    func updateNSView(_ label: TurnBadgeLabel, context: Context) {
        label.refresh(text, isTurned: isTurned)
    }
}

/// 裁切模式下的**应用 / 取消**。086：进入变换就有 tool，所以这一对不再按 `isActive` 置灰。
/// 语义不变 —— 应用提交一次草稿（一条历史），取消丢弃草稿（文档一个字节都不动）。
struct CropApplyRow: View {

    let onApply: () -> Void
    let onCancel: () -> Void

    static let probeID = "apply"
    /// 086/334: the two buttons' identifiers, one spelling for the view and the acceptance.
    static let applyID = "inspector.crop.apply"
    static let cancelID = "inspector.crop.cancel"
    /// The two keys `DetailRowEnabledLog` records them under (the panel's existing readback seam).
    static let applyProbe = "裁切.应用"
    static let cancelProbe = "裁切.取消"
    /// 336: one probe per **button**, so the acceptance can size each one instead of the pair.
    static let applyButtonProbe = "apply.button"
    static let cancelButtonProbe = "cancel.button"
    /// 336 — the two buttons' minimum size (user: 「做大一些」) and the pair's gap.
    ///
    /// `.large` rather than `.regular`: the bordered bezel at `.regular` is ~22 pt tall, under the
    /// 26 pt floor, so the size class itself has to carry the height and the `minSize` frame only
    /// guarantees it. 60 = 34 (the old `.mini` width) + 2 × 8 of label padding + 10 of slack.
    /// 339 (user): `.large` 在右栏里显得过大、不协调 —— 退一格到 `.regular`，宽度/高度也随之收小，
    /// 但仍是原 `.mini`（34×13）的近两倍，不至于又变回针尖大小。
    static let minSize = CGSize(width: 60, height: 22)
    static let controlSize: ControlSize = .regular
    static let spacing: CGFloat = 8
    static let labelInset: CGFloat = 8

    var body: some View {
        // 336: 取消 left, 应用 right — the primary verb sits at the inspector's bottom-right corner,
        // which is also the order §3.2 measures (`应用`.maxX == content right − 16).
        HStack(spacing: Self.spacing) {
            Button(action: onCancel) {
                Text("取消")
                    .padding(.horizontal, Self.labelInset)
            }
            .buttonStyle(.bordered)
            .controlSize(Self.controlSize)
            .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
            .background(DetailRowEnabledProbe(title: Self.cancelProbe))
            .background(CropRowProbeHost(rowID: Self.cancelButtonProbe))
            .help("放弃这次裁切，文档一个字节都不动")
            .accessibilityIdentifier(Self.cancelID)
            Button(action: onApply) {
                Text("应用")
                    .padding(.horizontal, Self.labelInset)
            }
            // 341 (user): 应用是主操作 —— 用强调色（蓝），取消保持普通 bordered。
            .buttonStyle(.borderedProminent)
            .controlSize(Self.controlSize)
            .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
            .background(DetailRowEnabledProbe(title: Self.applyProbe))
            .background(CropRowProbeHost(rowID: Self.applyButtonProbe))
            .help("应用裁切（一条历史，一次 ⌘Z）")
            .accessibilityIdentifier(Self.applyID)
        }
        .background(CropRowProbeHost(rowID: Self.probeID))
        .accessibilityIdentifier("inspector.crop.row.\(Self.probeID)")
    }
}

/// 336 — the transform workspace's **fixed footer**: 取消 / 应用, a sibling of the `ScrollView` rather
/// than a row of the 裁切 card, so the pair sits in the inspector's bottom-right corner and does not
/// move when the cards scroll.
///
/// Geometry (all measured in the acceptance, not asserted here):
///
///   · `应用`.maxX  == 检查器内容右沿 − 16   — the column inset 12 + the footer's own 16;
///   · row.maxY    == 检查器底边 − 12        — the footer's own bottom inset;
///   · gap above   == 10                     — the panel column's own `VStack` rhythm.
///
/// Only the transform workspace shows it: `InspectorView.body` gates it on `showsCropCard`.
struct CropApplyFooter: View {

    let onApply: () -> Void
    let onCancel: () -> Void

    /// The footer container's own probe (padding included): its bottom edge is the panel's bottom.
    static let probeID = "footer"
    /// The panel column's horizontal inset — the same 12 the cards and the pinned blocks are laid
    /// out inside (`InspectorView`).
    static let columnInset: CGFloat = 12
    /// The footer's inner right inset, measured from that column's right edge.
    static let trailingInset: CGFloat = 16
    /// The footer's bottom inset — 「页脚底 = 底边 − 12」.
    static let bottomInset: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            CropApplyRow(onApply: onApply, onCancel: onCancel)
        }
        .padding(.leading, Self.columnInset)
        .padding(.trailing, Self.columnInset + Self.trailingInset)
        .padding(.bottom, Self.bottomInset)
        .background(CropRowProbeHost(rowID: Self.probeID))
        .accessibilityIdentifier("inspector.crop.footer")
    }
}

/// 一片开关：`on` 是**系统强调色**（`Color.accentColor`，和调节栏的滑杆、工作区标签同一个色）。
///
/// The colour is a function (`fill(on:)`) and not a literal in the view, for 060's reason: the pixel
/// test renders **this** view and samples it, so deleting the accent here must break the test.
struct CropChip: View {

    let title: String
    let on: Bool
    var help: String = ""
    let action: () -> Void

    static let height: CGFloat = 18
    static let cornerRadius: CGFloat = 5

    /// 086/334: the chip's identifier, written once (`inspector.crop.chip.九宫格`).
    static func titleID(_ title: String) -> String { "inspector.crop.chip.\(title)" }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(on ? Color.white : Color.primary)
                .padding(.horizontal, 7)
                .frame(height: Self.height)
                .background(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(Self.fill(on: on)))
                .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(on ? 0 : 0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityIdentifier(Self.titleID(title))
        .background(DetailRowEnabledProbe(title: title))
    }

    /// **The one colour decision of the switches**: on = the system accent, off = nothing (the card's
    /// own material shows through, exactly like the bar's unfilled `.inline` bezel used to).
    static func fill(on: Bool) -> Color { on ? Color.accentColor : Color.clear }
}

// MARK: - 328/334 「画线拉直」

/// 334 — the 校正 card's **画线拉直** switch, on its own row under the 拉直 slider: a `level` glyph
/// (the spirit level the user asked for: 「旋转旁边的画线确定水平面功能，UI LOGO要改一下，看下有没有
/// 水平仪的LOGO，用来和引导线UI区分开」), lit while the canvas is drawing lines instead of moving
/// the frame.
///
/// 328 shipped it with `line.diagonal`, which is also the idiom for the guide lines it is *not*: the
/// two have to be told apart on sight, and a bubble level says 「这个摆平」 while a diagonal says
/// 「这里有一条线」. The custom-ratio field uses `ruler`, so no two controls in this workspace share a
/// glyph.
///
/// A real `NSButton` (334) rather than the SwiftUI `Button` it was: the acceptance has to read the
/// **image name** back, and a SwiftUI image has no `NSView` to ask.
final class DrawStraightenButton: NSButton {

    static let size = NSSize(width: 22, height: 18)
    static let cornerRadius: CGFloat = 5
    /// The symbol the panel draws — the acceptance's one readback (`image name == level`).
    static let symbol = "level"
    static let label = "画线拉直"
    static let help = "在画面上画一条线，松手后按线的方向把照片摆正（横/竖自动判断）；Esc 或再点一次取消"
    static let identifierID = "inspector.crop.drawStraighten"

    private(set) var symbolName: String = DrawStraightenButton.symbol

    init(symbol: String = DrawStraightenButton.symbol) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        symbolName = symbol
        isBordered = false
        bezelStyle = .inline
        setButtonType(.toggle)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        toolTip = Self.help
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.borderWidth = 1
        setAccessibilityIdentifier(Self.identifierID)
        target = self
        action = #selector(fire)
        refresh(symbol: symbol, on: false)
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var intrinsicContentSize: NSSize { Self.size }
    override var isFlipped: Bool { true }

    @objc private func fire() { }

    func refresh(symbol: String, on: Bool) {
        symbolName = symbol
        state = on ? .on : .off
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: Self.label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        contentTintColor = on ? .white : .labelColor
        layer?.backgroundColor = on
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(on ? 0 : 0.12).cgColor
        setAccessibilityLabel(Self.label)
        setAccessibilityValue(symbol)
    }
}

struct CropDrawStraightenToggle: NSViewRepresentable {

    let on: Bool
    var enabled: Bool = true
    let action: () -> Void
    /// 334: injectable only so the reverse gate can hand in `line.diagonal` and prove the acceptance
    /// reads the *drawn* symbol; production always uses `DrawStraightenButton.symbol`.
    var symbol: String = DrawStraightenButton.symbol

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> DrawStraightenButton {
        let button = DrawStraightenButton(symbol: symbol)
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.isEnabled = enabled
        button.refresh(symbol: symbol, on: on)
        return button
    }

    func updateNSView(_ button: DrawStraightenButton, context: Context) {
        context.coordinator.action = action
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.isEnabled = enabled
        button.refresh(symbol: symbol, on: on)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

// MARK: - 337 「引导线」

/// 337 — the 校正 card's **引导线** switch: a `perspective` glyph (the same picture-plane idiom the
/// keystone sliders' section uses), lit while the canvas is drawing guide lines.
///
/// It has to be distinguishable from its two neighbours at a glance, which is why the glyph is a
/// third one (334: `level` for 画线拉直, `ruler` for the custom ratio): a bubble level says 「把这张
/// 摆平」, a ruler says 「量一下」, and a converging trapezoid says 「把透视扳正」 — the thing this row
/// is for. A real `NSButton` for the same reason 334's is: the acceptance reads the *drawn* image
/// name back, and a SwiftUI `Image` has no `NSView` to ask.
final class GuideLinesButton: NSButton {

    static let size = NSSize(width: 22, height: 18)
    static let cornerRadius: CGFloat = 5
    /// The symbol the panel draws — the acceptance's one readback (`image name == perspective`).
    static let symbol = "perspective"
    static let label = "引导线"
    static let help = "沿本该竖直/水平的边画两条线，松手后解出透视（2 竖 + 2 横，最多 4 条）；"
        + "Esc 或再点一次取消"
    static let identifierID = "inspector.crop.guideLines"

    private(set) var symbolName: String = GuideLinesButton.symbol

    init(symbol: String = GuideLinesButton.symbol) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        symbolName = symbol
        isBordered = false
        bezelStyle = .inline
        setButtonType(.toggle)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        toolTip = Self.help
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.borderWidth = 1
        setAccessibilityIdentifier(Self.identifierID)
        target = self
        action = #selector(fire)
        refresh(symbol: symbol, on: false)
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var intrinsicContentSize: NSSize { Self.size }
    override var isFlipped: Bool { true }

    @objc private func fire() { }

    func refresh(symbol: String, on: Bool) {
        symbolName = symbol
        state = on ? .on : .off
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: Self.label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        contentTintColor = on ? .white : .labelColor
        layer?.backgroundColor = on
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(on ? 0 : 0.12).cgColor
        setAccessibilityLabel(Self.label)
        setAccessibilityValue(symbol)
    }
}

struct CropGuideLinesToggle: NSViewRepresentable {

    let on: Bool
    var enabled: Bool = true
    let action: () -> Void
    /// Injectable only so a reverse gate can hand in another glyph; production always uses
    /// `GuideLinesButton.symbol`.
    var symbol: String = GuideLinesButton.symbol

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> GuideLinesButton {
        let button = GuideLinesButton(symbol: symbol)
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.isEnabled = enabled
        button.refresh(symbol: symbol, on: on)
        return button
    }

    func updateNSView(_ button: GuideLinesButton, context: Context) {
        context.coordinator.action = action
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.isEnabled = enabled
        button.refresh(symbol: symbol, on: on)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

// MARK: - 317 「不出像素」

/// The 裁切 card's **「不出像素」** checkbox — a real `NSButton(checkboxWithTitle:)`, like every other
/// leaf in this card, so the panel acceptance can find it, read its state and click it without an
/// accessibility tree.
///
/// The checkbox owns **no state**: `isOn` is `CropToolController.cropStaysInsidePixels` (a preference,
/// `photons.cropStaysInsidePixels`) and the click goes back through `setCropStaysInsidePixels`, which
/// is also where the one-shot inscription lives. A second copy here would let the box and the law
/// disagree, which is 082's rule for every row of this card.
struct StaysInsidePixelsCheckbox: NSViewRepresentable {

    static let title = "不出像素"
    static let identifier = "inspector.crop.staysInsidePixels"

    let isOn: Bool
    let onToggle: (Bool) -> Void

    func makeNSView(context: Context) -> NSButton {
        let box = NSButton(checkboxWithTitle: Self.title, target: context.coordinator,
                           action: #selector(Coordinator.fire(_:)))
        box.setButtonType(.switch)
        box.controlSize = .small
        box.font = .systemFont(ofSize: 11)
        box.state = isOn ? .on : .off
        box.toolTip = "勾选后裁切框只能在照片像素内移动（不出黑角），尺寸不变"
        box.setAccessibilityIdentifier(Self.identifier)
        return box
    }

    func updateNSView(_ box: NSButton, context: Context) {
        context.coordinator.onToggle = onToggle
        box.state = isOn ? .on : .off
    }

    func makeCoordinator() -> Coordinator { Coordinator(onToggle: onToggle) }

    final class Coordinator: NSObject {
        var onToggle: (Bool) -> Void
        init(onToggle: @escaping (Bool) -> Void) { self.onToggle = onToggle }
        @objc func fire(_ sender: NSButton) { onToggle(sender.state == .on) }
    }
}

// MARK: - 键入的自定义比例（104: 内联字段取代居中面板）

/// The one `W:H` commit. 104 replaced the centred `CropRatioPrompt` panel with the inline field in
/// `CropAspectRow`; this seam stayed because it is where the rule lives, not because a panel does.
///
/// ⑨'s original reason for a **centred panel** (kept here on purpose, as history): AppKit places a
/// sheet under the window's title bar, `NSAlert.runModal()` centres on the **screen** and blocks the
/// run loop, and the ask was 「浮层中心 = 窗口中心」. The panel answered it by placing a borderless
/// child window from `parent.frame` at open time. The user's 2026-10-29 instruction — 「长宽比键入不要
/// 做成弹出的框，直接在面板中多一个比例指示」 — retires that answer: the field now lives in the card,
/// so there is no window to centre. The invalid-input semantics are unchanged: parse first, refuse
/// with one beep, write nothing.
///
/// It **does not store the ratio**: `CropTool.ratio(from:)` + `CropToolController.setCustomRatio`
/// write the draft's lock, and the last text is a UI preference (`CropToolBar.lastCustomRatioText`),
/// never a document field.
@MainActor
final class CropRatioPanels {

    static let shared = CropRatioPanels()

    /// 104: no panel exists any more. The handle stays for the acceptance's readback —
    /// 「内联输入提交路径上不创建任何 NSWindow / NSPanel」.
    var prompt: NSPanel? { nil }

    /// `W:H` → 草稿的比例锁. Refused input beeps and writes nothing, so a typo leaves the old ratio.
    @discardableResult
    func commit(_ text: String, to tool: CropToolController?) -> Bool {
        guard let tool, let ratio = CropTool.ratio(from: text), tool.setCustomRatio(ratio) else {
            NSSound.beep()                    // refused: nothing written, the old ratio stays
            return false
        }
        CropToolBar.lastCustomRatioText = text
        return true
    }
}

// MARK: - the readback seams (what SwiftUI actually built)

/// The ids the card's probes report, one per round of layout.
///
/// Strings, not an enum, because they are also the accessibility ids: one spelling everywhere.
enum CropCardID {
    /// The whole 裁切 card — 「卡片清单第一张 = 裁切」 is measured on this frame.
    static let card = "card"
    /// 334: the 校正 card's own frame (the second card of the workspace).
    static let correctionCard = "correction.card"
    /// 087: the 变换 card's own frame (the third card of the workspace).
    static let angleCard = "angle.card"
    static let aspect = CropAspectRow.probeID
    static let angle = "angle"
    /// 328: the 画线拉直 switch, on the 角度 row (no row of its own — it is that row's second control).
    static let drawStraighten = "drawStraighten"
    static let turn = CropTurnRow.probeID
    static let mirror = CropMirrorRow.probeID
    /// 183: the two keystone sliders' frames.
    static let perspectiveVertical = "perspective.vertical"
    static let perspectiveHorizontal = "perspective.horizontal"
    static let apply = CropApplyRow.probeID
    /// 086: the bottom row's 九宫格 half (the apply probe is the other half's frame).
    static let grid = "grid"
    /// 317: the 「不出像素」 checkbox, in the same bottom row, left of 九宫格.
    static let staysInsidePixels = "staysInsidePixels"

    /// 082: the four section titles, in the order they are stacked.
    static var sections: [String] { CropSection.displayOrder.map(\.rawValue) }
    static func section(_ section: CropSection) -> String { "section.\(section.title)" }
}

/// One row (or the whole card) of the crop card, in the panel's own coordinates.
///
/// SwiftUI draws its rows itself — there is no AppKit leaf to measure and no accessibility tree under
/// `swift test` — so `CropRowProbeHost` is placed as each row's **background**, which gives the test
/// that row's real frame. `hitTest` answers `nil`: a probe must never eat a click meant for the picker,
/// the slider or the buttons in front of it.
final class CropRowProbe: NSView {

    private(set) var rowID: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError("CropRowProbe is created in code") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func update(_ id: String) {
        rowID = id
        recordWindow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recordWindow()
    }

    /// The card's probe is the one that knows the window: the 自定义比例 panel has to be centred on it
    /// (⑨), and a SwiftUI button action has no other way to reach an `NSWindow`.
    private func recordWindow() {
        guard rowID == CropCardID.card else { return }
        CropCardHost.shared.window = window
    }
}

struct CropRowProbeHost: NSViewRepresentable {

    let rowID: String

    func makeNSView(context: Context) -> CropRowProbe {
        let probe = CropRowProbe()
        probe.update(rowID)
        return probe
    }

    func updateNSView(_ probe: CropRowProbe, context: Context) {
        probe.update(rowID)
    }
}

/// The card's window, for the one thing a SwiftUI action cannot get at by itself.
@MainActor
final class CropCardHost {
    static let shared = CropCardHost()
    weak var window: NSWindow?
}
