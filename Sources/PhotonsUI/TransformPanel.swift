import AppKit
import CoreGraphics
import PhotonsCore
import SwiftUI

// MARK: - 变换工作区：第一张卡是裁切（2026-10-27，082 重写为四个分区）
//
// 用户的两次原话（2026-10-27 / 2026-10-28）：
//
//   > 将裁切下拉菜单中的相关功能，移动到右侧第二栏「变换」，变换包括裁切、旋转等功能；点开变换窗口，
//   > **第一个卡片是裁切**；点按**直角尺图标**后进入裁切模式，出现裁切框；长宽比选择以及值的输入，
//   > UI 类似于调节栏。
//
//   > 右侧裁切模式的 UI 要重写，裁切、角度、旋转、镜像等要区分更大，现在挤在一起。
//   > 裁切模式下方悬浮栏的调节功能全部移动到右侧面板，只保留比例，像素，角度的信息。
//
// 于是这张卡是裁切工具的**全部**控件，四个分区，每区一条分隔线 + 11 pt 次级小标题：
//
//     裁切   比例（含 自定义… / ⇄ 交换）、应用 / 取消、九宫格
//     角度   滑块角度（−45…+45 的行）+ 实际角度（只读读数）
//     旋转   逆时针 90° / 方向徽标 / 顺时针 90°（⌘[ / ⌘]，同一个动词）
//     镜像   水平 / 垂直
//
// 分区之间 12 pt，小标题与自己的内容之间 6 pt：244 pt 的面板里四区不换行、不重叠、任何两行不相交
// （`CropCardSectionsTests` 量的是真实 frame）。
//
// ## 卡里不存第二份状态
//
// 每一个值都只读写两个地方，没有第三个：
//
//   · **草稿**（裁切框、滑块角度、比例锁）→ `CropToolController.draft`。应用时那一次 `apply()` 是唯一
//     写文档的地方（`CropToolController.apply`）。
//   · **文档**（水平/垂直翻转、`quarterTurns`、`straightenDegrees`）→ `session.edit.geometry`，和 072 §F
//     说的一样只有一份：卡、菜单、裁切栏、⌘[ / ⌘] 读的是同一批字段。
//   · **纯视图态**（九宫格）→ `CropToolController.showsGrid`，不进文档、不进历史。
//
// `CropToolController` 是 `@Observable`，`CatalogSession` 本来就是，所以草稿的一个 tick、模式的一次
// 切换、文档的一次翻转/旋转都会让这张卡自己重画 —— 不需要调用方记得 `sync()`。
//
// ## 两个角度
//
// 「滑块角度」是 `draft.straighten`（−45…+45，行的滑杆）；「实际角度」= 滑块角度 + 90 × quarterTurns
// （`CropToolController.actualAngle`）。只读读数印在一行里，两个词都写全：`实际角度 92.5° · 滑块角度
// +2.5°`。悬浮栏的 `角度` 段印的是**同一个实际角度**，所以栏和卡永远说同一个数。
//
// ## 直角尺为什么是 `crop` 而不是 `ruler`
//
// 用户要的是「直角尺图标」。SF Symbols 里 `crop` 画的是**两个 L 形直角括号**（裁切框的四个角），正是
// 直角尺的形状，而且和工作区标签上的 `crop.rotate` 同一族；`ruler` 画的是一把斜放的直尺，读起来是
// 「量尺寸」，不是「框住画面」。082 起它不再是唯一入口（进变换工作区就进模式），但仍然是显式开关。

extension InspectorView {

    /// 「变换」的第一张卡（今天是唯一一张）：裁切，四个分区。
    var cropTransformCard: some View {
        let tool = loupe?.cropTool
        let geometry = session.edit.geometry
        return InspectorCardShell(title: Section.crop.title,
                                  reset: { resets.cropGeometry() },
                                  accessory: {
                                      CropModeButtonHost(isOn: tool?.isActive ?? false,
                                                         isEnabled: tool != nil,
                                                         action: { loupe?.toggleCropTool() })
                                  }) {
            VStack(alignment: .leading, spacing: Self.cropSectionGap) {
                cropAspectSection(tool)
                cropAngleSection(tool)
                cropRotationSection(geometry: geometry, tool: tool)
                cropMirrorSection(geometry: geometry, tool: tool)
            }
        }
        // The card's own frame (「卡片清单第一张 = 裁切」 is measured on it) — behind the chrome, so the
        // number is the card's, not its content's.
        .background(CropRowProbeHost(rowID: CropCardID.card))
    }

    /// 分区之间 12 pt（082 的「拉开间距」）。
    static let cropSectionGap: CGFloat = 12
    /// 小标题与其内容之间 6 pt。
    static let cropSectionTitleGap: CGFloat = 6

    // MARK: 裁切

    /// 裁切 — 比例（六个预设 + 自定义… + ⇄）、应用 / 取消、九宫格。
    @ViewBuilder
    private func cropAspectSection(_ tool: CropToolController?) -> some View {
        VStack(alignment: .leading, spacing: Self.cropSectionTitleGap) {
            CropSectionHeader(title: CropSection.crop.title, isFirst: true,
                              reset: { resets.cropSection(.crop) })
            CropAspectRow(tool: tool)
            HStack(spacing: 6) {
                CropChip(title: "九宫格", on: tool?.showsGrid ?? true,
                         help: "裁切框上的三分线（视图态，不进文档）",
                         action: { tool?.toggleGrid() })
                Spacer(minLength: 4)
                CropApplyRow(active: tool?.isActive ?? false,
                             onApply: { loupe?.applyCropTool() },
                             onCancel: { loupe?.cancelCropTool() })
            }
        }
    }

    // MARK: 角度

    /// 角度 — 滑块角度（行）+ 实际角度（只读）。
    ///
    /// The row is the panel's own `sliderRow` (typing, double-click-to-reset, one input = one draft
    /// tick) with the label 「滑块角度」 — the user's two words, spelled out rather than abbreviated.
    /// The read-out under it is a real AppKit label (`CropAngleReadoutLabel`) so a test can read the
    /// string the panel drew, not a string the test computed.
    @ViewBuilder
    private func cropAngleSection(_ tool: CropToolController?) -> some View {
        let straighten = Binding<Double>(get: { tool?.draft.straighten ?? 0 },
                                         set: { tool?.setStraighten($0) })
        VStack(alignment: .leading, spacing: Self.cropSectionTitleGap) {
            CropSectionHeader(title: CropSection.angle.title, isFirst: false,
                              reset: { resets.cropSection(.angle) })
            VStack(alignment: .leading, spacing: Self.cropSectionTitleGap) {
                sliderRow("滑块角度",
                          straighten,
                          -CropTool.straightenLimit ... CropTool.straightenLimit,
                          "%+.1f°",
                          decimals: 1,
                          enabled: tool?.isActive ?? false,
                          accessibilityID: "inspector.crop.angle",
                          onReset: { tool?.setStraighten(0) },
                          // 草稿没有「提交」：一 tick 改一次草稿，应用时才是一次 `applyEdit` + 一次快照。
                          onEditingChanged: { _ in })
                CropAngleReadoutHost(actual: tool?.angleText() ?? "—",
                                     slider: tool?.sliderAngleText() ?? "—")
            }
            .background(CropRowProbeHost(rowID: CropCardID.angle))
        }
    }

    // MARK: 旋转

    /// 旋转 — 逆时针 / 徽标 / 顺时针。文档动作，⌘[ / ⌘] 同一个动词。
    @ViewBuilder
    private func cropRotationSection(geometry: GeometryGroup, tool: CropToolController?) -> some View {
        VStack(alignment: .leading, spacing: Self.cropSectionTitleGap) {
            CropSectionHeader(title: CropSection.rotation.title, isFirst: false,
                              reset: { resets.cropSection(.rotation) })
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
                              reset: { resets.cropSection(.mirror) })
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
        if let loupe {
            if horizontal { loupe.flipHorizontal() } else { loupe.flipVertical() }
            return
        }
        guard let tool else { return }
        if horizontal { tool.toggleFlipHorizontal() } else { tool.toggleFlipVertical() }
    }
}

// MARK: - 082: the four section names

/// The card's four sections — one spelling for the header, the reset verb and the tests.
public enum CropSection: String, CaseIterable, Sendable, Hashable {
    case crop
    case angle
    case rotation
    case mirror

    public var title: String {
        switch self {
        case .crop: return "裁切"
        case .angle: return "角度"
        case .rotation: return "旋转"
        case .mirror: return "镜像"
        }
    }

    /// The order they are stacked in, top to bottom.
    public static var displayOrder: [CropSection] { [.crop, .angle, .rotation, .mirror] }

    /// The accessibility / probe id of the section's small title.
    public var headerID: String { "inspector.crop.section.\(rawValue)" }
}

// MARK: - the section header

/// One section's small title: a hairline, then an 11 pt secondary label.
///
/// The hairline is the 「视觉分隔线」 the user asked for (the four sections have to *look* separated,
/// not only be spaced); the first section has none, because the card's own top edge is the line
/// above it. Double-clicking the title is the section's reset — the same `ResetOnDoubleClick` gesture
/// every other card uses, wired to one `PanelResets` verb per section.
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
            Text(title)
                .font(.system(size: Self.titleFontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .modifier(ResetOnDoubleClick(action: reset, help: "双击复位「\(title)」"))
                .accessibilityIdentifier("inspector.crop.section.\(title)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CropRowProbeHost(rowID: "section.\(title)"))
    }
}

// MARK: - the rows

/// 「比例」行：六个预设 + 「自定义…」+ ⇄（交换长宽）。
///
/// 这是**唯一**一张比例表（`CropAspectPreset.allCases`），点击只走 `CropToolController.setAspect`
/// —— 和 082 之前浮动栏的下拉是同一个动词、同一份草稿（下拉本身已经搬进这张卡，栏里只剩读数）。
/// 自定义走 ⑨ 的居中面板（`CropRatioPanels`），输入 `5:4` 存进草稿的是 `AspectLock.custom(1.25)`。
///
/// 未进入裁切时置灰（0.42 的不透明度，和「解码模型」行的既有写法一致）：草稿只在裁切模式里存在。
struct CropAspectRow: View {

    let tool: CropToolController?

    /// 行 id —— 测试按它找这一行真实的 frame。
    static let probeID = "aspect"

    /// The six presets, in the order the row lists them.
    static var items: [CropAspectPreset] { CropAspectPreset.allCases }

    /// The **自定义…** item — a door to the ⑨ panel, not a seventh ratio.
    static let customTitle = "自定义…"

    var body: some View {
        HStack(spacing: 6) {
            Text("比例")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Menu {
                ForEach(Self.items, id: \.self) { preset in
                    Button(preset.displayName) { tool?.setAspect(preset) }
                }
                Divider()
                Button(Self.customTitle) { CropRatioPanels.shared.present(for: tool) }
            } label: {
                Text(Self.title(for: tool))
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.mini)
            .fixedSize()
            .help(Self.help(for: tool))
            .accessibilityLabel("比例")
            .accessibilityIdentifier("inspector.crop.aspect")
            // ⇄ — 交换长宽 (§C1). A separate door from the popup because a swap is a *value*
            // operation on the current lock, not another preset.
            Button {
                _ = tool?.swapAspect()
            } label: {
                Text("⇄").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help("交换长宽")
            .accessibilityLabel("交换长宽")
            .accessibilityIdentifier("inspector.crop.swap")
        }
        .background(CropRowProbeHost(rowID: Self.probeID))
        .disabled(!(tool?.isActive ?? false))
        .opacity(tool?.isActive == true ? 1 : 0.42)
        .accessibilityIdentifier("inspector.crop.row.\(Self.probeID)")
    }

    /// What the row prints: the preset's own name, or the custom ratio the user typed.
    ///
    /// 自定义锁不显示「自由」——`CropAspectPreset(lock:)` 会把任何非预设比值折成 `.free`，而那个名字
    /// 会让用户以为约束被丢掉了。反过来，「原始」锁在 3:2 的机身上就是一个 `custom(1.5)`（`.matching`），
    /// 那一份**先**问预设，问不到才说「自定义」——否则「原始」会被印成「自定义 1.503:1」。
    static func title(for tool: CropToolController?) -> String {
        guard let tool else { return "—" }
        let preset = tool.aspectPreset()
        if preset == .free, case .custom(let ratio) = tool.draft.lock,
           ratio.isFinite, ratio > 0 {
            return "自定义 " + String(format: "%.4g:1", ratio)
        }
        return preset.displayName
    }

    static func help(for tool: CropToolController?) -> String {
        guard let tool else { return "裁切比例（进入裁切模式后可用）" }
        return "裁切比例：\(tool.draft.lock.displayName) · 点开可换预设或输入宽:高"
    }
}

/// 镜像：水平 / 垂直两片（082 — 九宫格搬到「裁切」区，这里只剩镜像）。
struct CropMirrorRow: View {

    let horizontal: Bool
    let vertical: Bool
    let onHorizontal: () -> Void
    let onVertical: () -> Void

    static let probeID = "mirror"

    var body: some View {
        HStack(spacing: 6) {
            CropChip(title: "水平", on: horizontal, help: "水平翻转（文档动作，一次 ⌘Z）",
                     action: onHorizontal)
            CropChip(title: "垂直", on: vertical, help: "垂直翻转（文档动作，一次 ⌘Z）",
                     action: onVertical)
            Spacer(minLength: 4)
        }
        .accessibilityIdentifier("inspector.crop.row.\(Self.probeID)")
    }
}

/// 旋转 90°：左 / 右两个按钮，中间是**当前方向的徽标**（P0-10）。
///
/// 三个值，一份真相：`turns` 是文档的 `GeometryGroup.quarterTurns`（0…3 顺时针），两个按钮只调
/// `LoupeController.rotateQuarter(clockwise:)` —— 和菜单的 ⌘[ / ⌘] 同一个动词，所以按钮、快捷键、
/// 徽标、`tiff:Orientation` 不会各说一套。
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
            Text("方向")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            // `.fixedSize()`: the three leaves are `NSView`s, and without it SwiftUI proposes the
            // row's width and AppKit stretches them (measured: two 88 pt buttons in a 308 pt card).
            TurnButtonHost(symbol: "rotate.left", title: "逆时针旋转 90°",
                           identifierID: Self.counterClockwiseID,
                           isEnabled: isEnabled, action: onCounterClockwise)
                .fixedSize()
            TurnBadgeHost(text: LoupeController.quarterTurnBadge(for: turns),
                          isTurned: GeometryGroup.normalizedQuarterTurns(turns) != 0)
                .fixedSize()
            TurnButtonHost(symbol: "rotate.right", title: "顺时针旋转 90°",
                           identifierID: Self.clockwiseID,
                           isEnabled: isEnabled, action: onClockwise)
                .fixedSize()
        }
        .accessibilityIdentifier("inspector.crop.row.\(Self.probeID)")
    }
}

/// 一个 90° 旋转按钮：SF Symbol `rotate.left` / `rotate.right`，和裁切卡的直角尺按钮同一族，
/// 同一个理由做成真 `NSButton`（见 `CropTurnRow` 的头注释）。
final class TurnButton: NSButton {

    static let size = NSSize(width: 22, height: 18)
    static let cornerRadius: CGFloat = CropChip.cornerRadius

    let symbol: String
    let titleText: String

    init(symbol: String, title: String) {
        self.symbol = symbol
        self.titleText = title
        super.init(frame: NSRect(origin: .zero, size: TurnButton.size))
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        contentTintColor = .labelColor
        toolTip = title + "（一次 ⌘Z）"
        setAccessibilityLabel(title)
        setAccessibilityIdentifier(title)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var intrinsicContentSize: NSSize { TurnButton.size }
    override var isFlipped: Bool { true }
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
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        setAccessibilityIdentifier(CropTurnRow.badgeID)
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(super.intrinsicContentSize.width + 10, 34), height: TurnBadgeLabel.height)
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

/// 裁切模式下的**应用 / 取消**。工具没开时两粒都是灰的（`isEnabled == false`），因为那时没有草稿
/// 可以应用、也没有框可以取消 —— 和 082 之前浮动栏的同一对按钮、菜单的 §D4 规则一致。
struct CropApplyRow: View {

    let active: Bool
    let onApply: () -> Void
    let onCancel: () -> Void

    static let probeID = "apply"
    /// The two keys `DetailRowEnabledLog` records them under (the panel's existing readback seam).
    static let applyProbe = "裁切.应用"
    static let cancelProbe = "裁切.取消"

    var body: some View {
        HStack(spacing: 6) {
            Button("应用", action: onApply)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .background(DetailRowEnabledProbe(title: Self.applyProbe))
                .help("应用裁切（一条历史，一次 ⌘Z）")
                .accessibilityIdentifier("inspector.crop.apply")
            Button("取消", action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .background(DetailRowEnabledProbe(title: Self.cancelProbe))
                .help("放弃这次裁切，文档一个字节都不动")
                .accessibilityIdentifier("inspector.crop.cancel")
        }
        .background(CropRowProbeHost(rowID: Self.probeID))
        .disabled(!active)
        .accessibilityIdentifier("inspector.crop.row.\(Self.probeID)")
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
        .accessibilityIdentifier("inspector.crop.chip.\(title)")
    }

    /// **The one colour decision of the switches**: on = the system accent, off = nothing (the card's
    /// own material shows through, exactly like the bar's unfilled `.inline` bezel used to).
    static func fill(on: Bool) -> Color { on ? Color.accentColor : Color.clear }
}

// MARK: - 082: the two-angle readout (read-only)

/// 「实际角度 92.5° · 滑块角度 +2.5°」 — one line, both words spelled out, **read-only**.
///
/// An `NSTextField` label and not a SwiftUI `Text` for the reason every leaf in this card is AppKit:
/// the acceptance reads the string the panel *drew* (and the accessibility tree is empty under
/// `swift test`). It carries no gesture: 082's angle reset belongs to the section title and the row's
/// own label, so a stray click on a number can never write anything.
final class CropAngleReadoutLabel: NSTextField {

    static let identifier = "inspector.crop.angle.readout"
    static let fontSize: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        alignment = .left
        font = .monospacedDigitSystemFont(ofSize: Self.fontSize, weight: .regular)
        textColor = .secondaryLabelColor
        lineBreakMode = .byTruncatingTail
        setAccessibilityIdentifier(Self.identifier)
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var isFlipped: Bool { true }

    /// The one formatter both numbers go through: 「实际角度 90.0° · 滑块角度 +0.0°」.
    static func text(actual: String, slider: String) -> String {
        "实际角度 \(actual) · 滑块角度 \(slider)"
    }

    func refresh(actual: String, slider: String) {
        stringValue = Self.text(actual: actual, slider: slider)
        toolTip = "实际角度 = 滑块角度 + 90 × 旋转圈数"
        setAccessibilityValue(stringValue)
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width, height: max(size.height, 14))
    }
}

struct CropAngleReadoutHost: NSViewRepresentable {

    let actual: String
    let slider: String

    func makeNSView(context: Context) -> CropAngleReadoutLabel {
        let label = CropAngleReadoutLabel()
        label.refresh(actual: actual, slider: slider)
        return label
    }

    func updateNSView(_ label: CropAngleReadoutLabel, context: Context) {
        label.refresh(actual: actual, slider: slider)
    }
}

// MARK: - 卡头的直角尺（AppKit：它要能被真的点一下）

/// The card's ruler button, as a real `NSButton`.
///
/// Why not a SwiftUI `Button`: the acceptance for this card is 「点按直角尺图标后进入裁切模式，出现裁切框」
/// measured on a **hosted, laid-out** panel — and a SwiftUI `Button` has no AppKit leaf in this app's
/// test process (no accessibility tree either), so a click on it cannot be dispatched. An `NSButton`
/// gives the test the same three things the floating bar's controls used to give it: a real frame, a
/// real `isEnabled`, and `performClick(_:)` through the real target/action.
///
/// 082: it is no longer the *only* way in (the workspace is), but it stays the explicit 「再点一次退出」
/// switch the user asked to keep.
final class CropModeButton: NSButton {

    /// **直角尺 = `crop`** (see this file's header): the two L-shaped corner brackets of a crop frame
    /// — a try square's shape, and the same icon family as the workspace tab's `crop.rotate`.
    /// `ruler` is a diagonal measuring ruler: measurement, not framing.
    static let symbol = "crop"
    static let glyphPointSize: CGFloat = 11
    static let size = NSSize(width: 20, height: 18)

    /// 裁切模式开着 —— 按钮是强调色实底的（和开关同一个「打开变蓝」）。
    var isOn = false {
        didSet { if isOn != oldValue { refresh() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .inline
        // The **tool** owns the mode: the button is a push button, its face is `isOn`, and the tool's
        // `isActive` is what flips it back (no momentary state to disagree with the tool).
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        image = NSImage(systemSymbolName: Self.symbol, accessibilityDescription: "裁切")
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var intrinsicContentSize: NSSize { Self.size }

    override var isFlipped: Bool { true }

    /// The face: accent fill + white glyph while the frame is up, a plain secondary glyph when it is
    /// not. `contentTintColor` is what AppKit uses to tint a template symbol image.
    func refresh() {
        contentTintColor = isOn ? .white : .secondaryLabelColor
        layer?.backgroundColor = isOn ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        toolTip = isOn ? "退出裁切（⌘R）" : "进入裁切（⌘R）"
        setAccessibilityLabel(isOn ? "退出裁切" : "进入裁切")
        needsDisplay = true
    }
}

/// `CropModeButton` in SwiftUI: the button's two inputs and the one verb behind it.
struct CropModeButtonHost: NSViewRepresentable {

    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> CropModeButton {
        let button = CropModeButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.isOn = isOn
        button.isEnabled = isEnabled
        return button
    }

    func updateNSView(_ button: CropModeButton, context: Context) {
        context.coordinator.action = action
        button.isOn = isOn
        button.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) { self.action = action }

        @objc func fire() { action() }
    }
}

// MARK: - 自定义比例：⑨ 的那个居中面板，卡里的这扇门

/// 把「自定义…」接到 ⑨ 的面板上：窄面板里也能用，行为与 082 之前浮动栏的下拉逐条一致。
///
/// 它**不存比例**：面板只负责问，`commit(_:)` 走 `CropTool.ratio(from:)` + `setCustomRatio`
/// 写进草稿的比例锁（非法输入一声响，什么都不写），最后一次输入的文本记在
/// `CropToolBar.lastCustomRatioText` 里（UI 偏好，不是文档字段）。
@MainActor
final class CropRatioPanels {

    static let shared = CropRatioPanels()

    /// The panel currently asking for `W:H`, if any — the handle the tests measure and commit.
    private(set) var prompt: CropRatioPrompt?
    private weak var tool: CropToolController?

    /// Present the panel centred on the **window** the card lives in (⑨), with the same initial value
    /// the floating bar used.
    @discardableResult
    func present(for tool: CropToolController?,
                 initial: String = CropToolBar.lastCustomRatioText) -> Bool {
        guard let tool, let window = CropCardHost.shared.window ?? Self.frontWindow() else {
            NSSound.beep()
            return false
        }
        // Never two at once: the old panel is cancelled (its own `finish` unparents it).
        prompt?.cancelOperation(nil)
        self.tool = tool
        let panel = CropRatioPrompt(initial: initial)
        panel.onCommit = { [weak self] text in
            self?.prompt = nil
            self?.commit(text)
        }
        panel.onCancel = { [weak self] in self?.prompt = nil }
        prompt = panel
        panel.present(centredOn: window)
        return true
    }

    /// `W:H` → 草稿的比例锁。 Exactly the bar's verb, so the two doors cannot disagree.
    @discardableResult
    func commit(_ text: String) -> Bool {
        guard let tool, let ratio = CropTool.ratio(from: text), tool.setCustomRatio(ratio) else {
            NSSound.beep()                    // refused: nothing written, the old ratio stays
            return false
        }
        CropToolBar.lastCustomRatioText = text
        return true
    }

    /// The window to centre on when the card has not been laid out yet (a preview, a first frame):
    /// the editor window, never the screen (⑨: 「浮层中心 = 窗口中心」).
    static func frontWindow() -> NSWindow? {
        if let window = NSApp.keyWindow { return window }
        if let window = NSApp.mainWindow { return window }
        return NSApp.windows.first { $0.windowController is EditorWindowController }
    }
}

// MARK: - the readback seams (what SwiftUI actually built)

/// The ids the card's probes report, one per round of layout.
///
/// Strings, not an enum, because they are also the accessibility ids: one spelling everywhere.
enum CropCardID {
    /// The whole card — 「卡片清单第一张 = 裁切」 is measured on this frame.
    static let card = "card"
    static let aspect = CropAspectRow.probeID
    static let angle = "angle"
    static let turn = CropTurnRow.probeID
    static let mirror = CropMirrorRow.probeID
    static let apply = CropApplyRow.probeID

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
