import AppKit
import CoreGraphics
import PhotonsCore
import SwiftUI

// MARK: - 变换工作区：第一张卡是裁切（2026-10-27；086 起卡头无按钮、底部三件）
//
// 用户的历次原话（2026-10-27 / 2026-10-28）：
//
//   > 将裁切下拉菜单中的相关功能，移动到右侧第二栏「变换」，变换包括裁切、旋转等功能；点开变换窗口，
//   > **第一个卡片是裁切**；点按**直角尺图标**后进入裁切模式，出现裁切框；长宽比选择以及值的输入，
//   > UI 类似于调节栏。
//
//   > 右侧裁切模式的 UI 要重写，裁切、角度、旋转、镜像等要区分更大，现在挤在一起。
//   > 裁切模式下方悬浮栏的调节功能全部移动到右侧面板，只保留比例，像素，角度的信息。
//
//   > 进入变换界面后……裁切卡片名称右边的按钮删除，只要进入变换界面就提供裁切框，同时下面的功能
//   > 不能变灰。接下来二级标题是「宽高比」，取代第二个「裁切」，右边是选单和交换。九宫格/应用/取消
//   > 放在最底下。
//
// 于是这张卡是裁切工具的**全部**控件，四段，每段一条分隔线 + 11 pt 次级小标题：
//
//     宽高比   标题 · 比例选单 · ⇄ 交换（同一行）
//     角度     滑块角度（−45…+45 的行，行标签「角度」）
//     旋转     左旋 · 右旋 · 最右角度（⌘[ / ⌘]，同一个动词）
//     镜像     水平 / 垂直
//     底部     九宫格（左）· 应用 取消（右，卡片最后一行）
//
// 分区之间 12 pt，小标题与自己的内容之间 6 pt：244 pt 的面板里四区不换行、不重叠、任何两行不相交
// （`CropCardSectionsTests` 量的是真实 frame）。
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
// （`CropToolController.actualAngle`）。093 起卡片上不再印只读读数 —— 滑块行自身只显示滑块角度，
// 悬浮栏的 `角度` 段仍印**实际角度**。

extension InspectorView {

    /// 「变换」的第一张卡：宽高比 + 底部三件（087 把转动 / 旋转 / 镜像搬到第二张卡）。
    var cropTransformCard: some View {
        let tool = loupe?.cropTool
        return InspectorCardShell(title: Section.crop.title,
                                  reset: { resets.cropGeometry() },
                                  accessory: { EmptyView() }) {
            VStack(alignment: .leading, spacing: Self.cropSectionGap) {
                cropAspectSection(tool)
                cropBottomRow(tool)
            }
        }
        // The card's own frame (「卡片清单第一张 = 裁切」 is measured on it) — behind the chrome, so the
        // number is the card's, not its content's.
        .background(CropRowProbeHost(rowID: CropCardID.card))
    }

    /// 「变换」的第二张卡（087）：转动 / 旋转 / 镜像。没有整卡复位，也没有应用 / 取消 ——
    /// 转动松手即写、旋转与镜像是一次文档动作，Esc 才是回退。
    var angleTransformCard: some View {
        let tool = loupe?.cropTool
        let geometry = session.edit.geometry
        return InspectorCardShell(title: Section.angle.title,
                                  reset: nil,
                                  accessory: { EmptyView() }) {
            VStack(alignment: .leading, spacing: Self.cropSectionGap) {
                cropAngleSection(tool)
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

    // MARK: 宽高比

    /// 宽高比 — 小标题、比例选单、⇄ 交换在**同一行**（086）。
    @ViewBuilder
    private func cropAspectSection(_ tool: CropToolController?) -> some View {
        HStack(spacing: 6) {
            CropSectionTitle(title: CropSection.crop.title,
                             reset: { resets.cropSection(.crop) })
                .background(CropRowProbeHost(rowID: CropCardID.section(.crop)))
            Spacer(minLength: 2)
            CropAspectRow(tool: tool)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 底部三件

    /// 九宫格 / 应用 / 取消 — 卡片最后一行（086）。
    @ViewBuilder
    private func cropBottomRow(_ tool: CropToolController?) -> some View {
        HStack(spacing: 6) {
            CropChip(title: "九宫格", on: tool?.showsGrid ?? true,
                     help: "裁切框上的三分线（视图态，不进文档）",
                     action: { loupe?.cropTool.toggleGrid() })
                .background(CropRowProbeHost(rowID: CropCardID.grid))
            Spacer(minLength: 4)
            CropApplyRow(onApply: { loupe?.completeCropTool() },
                         onCancel: { loupe?.cancelCropTool() })
        }
    }

    // MARK: 角度

    /// 转动 — 只有滑杆；行标签是「角度」，卡片上不印只读读数。
    ///
    /// 087: the value is **live** — every tick writes the document, release commits one row
    /// (`onEditingChanged(false)`), so there is nothing left for 应用 to do. The crop frame keeps 086's
    /// draft semantics: only the straighten is written here.
    @ViewBuilder
    private func cropAngleSection(_ tool: CropToolController?) -> some View {
        let straighten = Binding<Double>(get: { tool?.angleUIValue ?? 0 },
                                         set: { tool?.setAngle(uiValue: $0) })
        VStack(alignment: .leading, spacing: Self.cropSectionTitleGap) {
            CropSectionHeader(title: CropSection.angle.title, isFirst: true,
                              reset: { resets.cropSection(.angle) })
            VStack(alignment: .leading, spacing: Self.cropSectionTitleGap) {
                sliderRow("角度",
                          straighten,
                          -CropTool.straightenLimit ... CropTool.straightenLimit,
                          "%+.1f°",
                          decimals: 1,
                          enabled: true,
                          accessibilityID: "inspector.crop.angle",
                          onReset: {
                              tool?.setAngle(uiValue: 0)
                              _ = tool?.commitStraighten()
                          },
                          onEditingChanged: { editing in
                              guard !editing else { return }
                              _ = tool?.commitStraighten()
                          })
            }
            .background(CropRowProbeHost(rowID: CropCardID.angle))
        }
    }

    // MARK: 旋转

    /// 旋转 — 左旋 / 右旋 / 最右的角度。文档动作，⌘[ / ⌘] 同一个动词。
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

// MARK: - 082: the four section names

/// The card's four sections — one spelling for the header, the reset verb and the tests.
public enum CropSection: String, CaseIterable, Sendable, Hashable {
    case crop
    case angle
    case rotation
    case mirror

    public var title: String {
        switch self {
        // 086: the first section's small title is the user's new word. The *card* title (「裁切」) is
        // `InspectorView.Section.crop.title` and is not this enum, so it does not move with this.
        case .crop: return "宽高比"
        case .angle: return "角度"
        case .rotation: return "旋转"
        case .mirror: return "镜像"
        }
    }

    /// The order they are stacked in, top to bottom (all four, across both cards).
    public static var displayOrder: [CropSection] { [.crop, .angle, .rotation, .mirror] }

    /// 087: the second card's three sections, in the user's order.
    public static var angleCardOrder: [CropSection] { [.angle, .rotation, .mirror] }

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

// MARK: - the rows

/// 104 — 宽高比 row: 小标题 · 🔒/🔓 · 比例 chip · ✎ · ⇄.
///
/// The menu is gone. The chip **is** the picker — one click advances the fixed cycle, ⇧-click steps
/// back — and the pencil swaps the chip for an inline `W:H` field **in place** (no `Menu`, no
/// `NSPanel`, no popover). Every write still goes through `CropToolController.setAspect` /
/// `setCustomRatio`, the verbs the old popup called; the chip is an entry, not a second state.
struct CropAspectRow: View {

    let tool: CropToolController?

    /// 行 id —— 测试按它找这一行真实的 frame。
    static let probeID = "aspect"
    /// The four leaves' own frames on the title's line (104).
    static let chipProbeID = "aspect.chip"
    static let lockProbeID = "aspect.lock"
    static let editProbeID = "aspect.edit"
    static let swapProbeID = "aspect.swap"
    /// 086's layout test still asks for the picker under this id.
    static let menuProbeID = chipProbeID

    /// The accessibility ids every acceptance run uses.
    static let chipID = "inspector.crop.ratioChip"
    static let lockID = "inspector.crop.ratioLock"
    static let fieldID = "inspector.crop.ratioField"
    static let editID = "inspector.crop.ratioEdit"
    static let swapID = "inspector.crop.swap"

    /// The six presets, in the order the chip cycles them.
    static var items: [CropAspectPreset] { CropAspectPreset.allCases }

    /// 086: the swap button's minimum hit target (the spec's 18 × 18 pt).
    static let swapHitSize: CGFloat = 18
    /// One width for the chip and the field that replaces it, so the row does not jump when typing.
    static let controlWidth: CGFloat = 58

    @State private var editing = false

    var body: some View {
        HStack(spacing: 6) {
            RatioLockButtonHost(symbol: Self.lockSymbol(for: tool),
                                isEnabled: tool != nil,
                                identifierID: Self.lockID,
                                action: { tool?.toggleAspectLock() })
                .fixedSize()
                .background(CropRowProbeHost(rowID: Self.lockProbeID))

            if editing {
                RatioInlineFieldHost(initial: Self.editingText(for: tool),
                                     onCommit: { text in commit(text) },
                                     onCancel: { editing = false })
                    .frame(width: Self.controlWidth, height: 18)
                    .background(CropRowProbeHost(rowID: Self.chipProbeID))
            } else {
                RatioChipButtonHost(title: Self.title(for: tool),
                                    isEnabled: tool != nil,
                                    identifierID: Self.chipID,
                                    onCycle: { backward in tool?.cycleAspect(backward: backward) })
                    .frame(width: Self.controlWidth, height: 18)
                    .help(Self.help(for: tool))
                    .background(CropRowProbeHost(rowID: Self.chipProbeID))
                    .background(DetailRowEnabledProbe(title: "宽高比"))
            }

            RatioIconButtonHost(symbol: "pencil",
                                title: "键入比例",
                                identifierID: Self.editID,
                                isEnabled: tool != nil,
                                action: { editing = true })
                .fixedSize()
                .background(CropRowProbeHost(rowID: Self.editProbeID))

            // ⇄ — 交换长宽 (§C1). A separate door from the chip because a swap is a *value* operation
            // on the current lock, not another preset.
            Button {
                _ = tool?.swapAspect()
            } label: {
                Text("⇄")
                    .font(.system(size: 10))
                    .frame(minWidth: Self.swapHitSize, minHeight: Self.swapHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help("交换长宽")
            .accessibilityLabel("交换长宽")
            .accessibilityIdentifier(Self.swapID)
            .background(CropRowProbeHost(rowID: Self.swapProbeID))
        }
        .background(CropRowProbeHost(rowID: Self.probeID))
        .accessibilityIdentifier("inspector.crop.row.\(Self.probeID)")
    }

    /// 104 — `lock.fill` while a ratio constrains the frame, `lock.open` only for 自由
    /// (`AspectLock.original`, the one spelling with `ratio == nil`).
    static func lockSymbol(for tool: CropToolController?) -> String {
        (tool?.isAspectFree ?? true) ? "lock.open" : "lock.fill"
    }

    /// What the chip prints: the preset's own name, or the typed ratio as `W:H` (e.g. `5:4`).
    ///
    /// 自定义锁不显示「自由」——`CropAspectPreset(lock:)` 会把任何非预设比值折成 `.free`，而那个名字
    /// 会让用户以为约束被丢掉了。反过来，「原始」锁在 3:2 的机身上就是一个 `custom(1.5)`（`.matching`），
    /// 那一份**先**问预设，问不到才说 `W:H` —— 否则「原始」会被印成「3:2」。
    static func title(for tool: CropToolController?) -> String {
        guard let tool else { return "—" }
        let preset = tool.aspectPreset()
        if preset == .free, case .custom(let ratio) = tool.draft.lock,
           ratio.isFinite, ratio > 0 {
            return customRatioText(ratio)
        }
        return preset.displayName
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

    /// What the inline field starts from: the typed ratio if one is in force, else the last `W:H`
    /// (the same UI preference the old centred panel used).
    static func editingText(for tool: CropToolController?) -> String {
        if let tool, tool.aspectPreset() == .free, case .custom(let ratio) = tool.draft.lock,
           ratio.isFinite, ratio > 0 {
            return customRatioText(ratio)
        }
        return CropToolBar.lastCustomRatioText
    }

    static func help(for tool: CropToolController?) -> String {
        guard let tool else { return "宽高比（进入变换后可用）" }
        return "宽高比：\(title(for: tool)) · 单击换下一个，⇧ 单击换上一个"
    }

    /// One `W:H` commit, in the same place whether it came from the keyboard or a test: parse, write,
    /// or beep and change nothing. The chip then re-renders from the draft, so a refused string shows
    /// the old ratio again.
    private func commit(_ text: String) {
        _ = CropRatioPanels.shared.commit(text, to: tool)
        editing = false
    }
}

// MARK: - 104: the chip, the lock, the pencil and the inline field (AppKit leaves)

/// The ratio chip itself. A real `NSButton` for the same reason every leaf in this card is AppKit:
/// the acceptance clicks it and reads the **text** back without an event loop.
final class RatioChipButton: NSButton {

    static let height: CGFloat = 18
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

    var onCycle: ((Bool) -> Void)?
    private var backward = false

    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: CropAspectRow.controlWidth, height: Self.height))
        self.title = title
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        font = Self.font
        alignment = .center
        lineBreakMode = .byClipping
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.6).cgColor
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        target = self
        action = #selector(fire)
        setAccessibilityLabel("宽高比")
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CropAspectRow.controlWidth, height: Self.height)
    }
    override var isFlipped: Bool { true }

    /// ⇧-click steps the cycle backwards. The flag is captured on mouse-down; `performClick` (what
    /// the tests use) keeps the default forward direction.
    override func mouseDown(with event: NSEvent) {
        backward = event.modifierFlags.contains(.shift)
        super.mouseDown(with: event)
    }

    @objc private func fire() {
        onCycle?(backward)
        backward = false
    }

    /// The ⇧-click path without an `NSEvent` (the same door a keyboard shortcut would use).
    func click(backward: Bool) {
        self.backward = backward
        performClick(nil)
    }

    func refresh(title: String, isEnabled: Bool) {
        self.title = title
        self.isEnabled = isEnabled
        setAccessibilityValue(title)
        invalidateIntrinsicContentSize()
    }
}

struct RatioChipButtonHost: NSViewRepresentable {

    let title: String
    let isEnabled: Bool
    let identifierID: String
    let onCycle: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCycle: onCycle) }

    func makeNSView(context: Context) -> RatioChipButton {
        let button = RatioChipButton(title: title)
        button.setAccessibilityIdentifier(identifierID)
        button.onCycle = context.coordinator.fire
        button.refresh(title: title, isEnabled: isEnabled)
        return button
    }

    func updateNSView(_ button: RatioChipButton, context: Context) {
        context.coordinator.onCycle = onCycle
        button.onCycle = context.coordinator.fire
        button.setAccessibilityIdentifier(identifierID)
        button.refresh(title: title, isEnabled: isEnabled)
    }

    final class Coordinator: NSObject {
        var onCycle: (Bool) -> Void
        init(onCycle: @escaping (Bool) -> Void) { self.onCycle = onCycle }
        func fire(_ backward: Bool) { onCycle(backward) }
    }
}

/// A bordered-free 18 × 18 icon leaf (🔒 / 🔓 / ✎). Same shape as `BareIconButton`, but the symbol is
/// mutable: the lock flips between `lock.fill` and `lock.open` as the ratio enters/leaves 自由.
final class RatioIconButton: NSButton {

    static let size = NSSize(width: 18, height: 18)
    static let glyphPointSize: CGFloat = 10

    private(set) var symbol: String
    var onActivate: (() -> Void)?

    init(symbol: String, title: String) {
        self.symbol = symbol
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        toolTip = title
        setAccessibilityLabel(title)
        target = self
        action = #selector(fire)
        refresh(symbol: symbol, title: title)
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var intrinsicContentSize: NSSize { Self.size }
    override var isFlipped: Bool { true }

    @objc private func fire() { onActivate?() }

    func refresh(symbol: String, title: String) {
        self.symbol = symbol
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Self.glyphPointSize,
                                                                 weight: .regular))
        setAccessibilityLabel(title)
        setAccessibilityValue(symbol)
    }
}

struct RatioIconButtonHost: NSViewRepresentable {

    let symbol: String
    let title: String
    let identifierID: String
    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> RatioIconButton {
        let button = RatioIconButton(symbol: symbol, title: title)
        button.setAccessibilityIdentifier(identifierID)
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.isEnabled = isEnabled
        return button
    }

    func updateNSView(_ button: RatioIconButton, context: Context) {
        context.coordinator.action = action
        button.setAccessibilityIdentifier(identifierID)
        button.isEnabled = isEnabled
        button.refresh(symbol: symbol, title: title)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

/// The lock leaf: `lock.fill` / `lock.open`, one click = 自由 ⇄ last locked.
struct RatioLockButtonHost: NSViewRepresentable {

    let symbol: String
    let isEnabled: Bool
    let identifierID: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> RatioIconButton {
        let button = RatioIconButton(symbol: symbol, title: "比例锁")
        button.setAccessibilityIdentifier(identifierID)
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.isEnabled = isEnabled
        return button
    }

    func updateNSView(_ button: RatioIconButton, context: Context) {
        context.coordinator.action = action
        button.setAccessibilityIdentifier(identifierID)
        button.isEnabled = isEnabled
        let title = symbol == "lock.open" ? "比例锁：自由（单击恢复上一次比例）" : "比例锁：已锁定（单击改为自由）"
        button.refresh(symbol: symbol, title: title)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

/// 104 — the inline `W:H` field: the chip **becomes** this field in place. `↵` commits, `Esc`
/// cancels, and **losing focus cancels too** (the same rule the angle number field has: blur is not a
/// commit). Nothing here creates a window: it is an `NSTextField` inside the card's row.
final class RatioInlineField: NSTextField, NSTextFieldDelegate {

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private var finished = false
    private var requestedFocus = false

    init(text: String) {
        super.init(frame: .zero)
        stringValue = text
        font = Self.font
        isEditable = true
        isSelectable = true
        isBezeled = true
        bezelStyle = .squareBezel
        drawsBackground = true
        controlSize = .mini
        focusRingType = .default
        alignment = .center
        delegate = self
        target = self
        action = #selector(commitAction)
        setAccessibilityIdentifier(CropAspectRow.fieldID)
        setAccessibilityLabel("自定义比例")
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CropAspectRow.controlWidth, height: 18)
    }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !requestedFocus else { return }
        requestedFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.currentEditor()?.selectAll(nil)
        }
    }

    @objc private func commitAction() { finish(commit: true) }

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

    /// Blur is **not** a commit (the angle field's rule); it closes the editor and keeps the old ratio.
    func controlTextDidEndEditing(_ obj: Notification) {
        if !finished { finish(commit: false) }
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        if commit { onCommit?(stringValue) } else { onCancel?() }
    }

    /// `↵` for the acceptance (the real path is the field editor's `doCommandBy`).
    func commitForTesting() { finish(commit: true) }
    /// `Esc` / blur for the acceptance.
    func cancelForTesting() { finish(commit: false) }
}

struct RatioInlineFieldHost: NSViewRepresentable {

    let initial: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RatioInlineField {
        let field = RatioInlineField(text: initial)
        field.onCommit = onCommit
        field.onCancel = onCancel
        return field
    }

    func updateNSView(_ field: RatioInlineField, context: Context) {
        field.onCommit = onCommit
        field.onCancel = onCancel
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
        .background(DetailRowEnabledProbe(title: title))
    }

    /// **The one colour decision of the switches**: on = the system accent, off = nothing (the card's
    /// own material shows through, exactly like the bar's unfilled `.inline` bezel used to).
    static func fill(on: Bool) -> Color { on ? Color.accentColor : Color.clear }
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
    /// 087: the 角度 card's own frame (the second card of the workspace).
    static let angleCard = "angle.card"
    static let aspect = CropAspectRow.probeID
    static let angle = "angle"
    static let turn = CropTurnRow.probeID
    static let mirror = CropMirrorRow.probeID
    static let apply = CropApplyRow.probeID
    /// 086: the bottom row's 九宫格 half (the apply probe is the other half's frame).
    static let grid = "grid"

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
