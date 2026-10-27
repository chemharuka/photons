import AppKit
import SwiftUI

// MARK: - 派单 073: the inspector's workspaces

/// **Which cards the inspector shows** — the one thing the icon row under the histogram switches.
///
/// The user's ask (2026-10-27): 「在直方图下方加一排图标按钮，用来切换工作区」, five of them, in this
/// order: 调整 / 变换 / 色彩 / 蒙版 / 历史记录, default 调整. And the rule for the ones that do not
/// exist yet: 「如果功能没做好就先空着」 — an empty workspace is *no cards*, not a placeholder drawing,
/// not a disabled ghost, and never an error.
///
/// So a workspace is a **membership table** and nothing else (`cards`). The order of what is shown is
/// still `InspectorView.Section.allCases` — one list, one order (派单 009 A) — because the view filters
/// that list by `Set(cards)`. A workspace can decide *whether* a card appears; it cannot reorder the
/// panel, and it cannot invent a card (`Section` remains the only card list there is).
///
/// | 工作区 | 卡片 | 状态 |
/// |---|---|---|
/// | 调整 `adjust` | 白平衡 / 黑电平 / Light / Color / 细节 / 曲线 / 预设 / Decode | 既有卡片，全在这里 |
/// | 变换 `transform` | — | 旋转 / 裁切 / 校正 **还不是检查器卡片**，空着 |
/// | 色彩 `colour` | — | HSL **尚未实现**，空着 |
/// | 蒙版 `masks` | 蒙版 | 既有的蒙版卡 |
/// | 历史记录 `history` | — | **尚未实现**，空着 |
///
/// **It is view state.** Selecting a workspace touches no document: `EditModel` is not written, no
/// `EditHistory` snapshot is taken, `editRevision` does not move, and nothing is persisted. Switching
/// only decides which views SwiftUI builds. `InspectorWorkspaceStateTests` asserts exactly that.
public enum InspectorWorkspace: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// 调整 — the default, and the panel as it has always been.
    case adjust
    /// 变换 — 旋转 / 裁切 / 校正. Empty: those three are canvas tools today, not cards.
    case transform
    /// 色彩 — HSL. Empty: not implemented yet.
    case colour
    /// 蒙版 — the existing mask card, on its own.
    case masks
    /// 历史记录. Empty: not implemented yet.
    case history

    public var id: String { rawValue }

    /// The button's accessibility label and its tooltip's stem — the user's own words.
    public var title: String {
        switch self {
        case .adjust: return "调整"
        case .transform: return "变换"
        case .colour: return "色彩"
        case .masks: return "蒙版"
        case .history: return "历史记录"
        }
    }

    /// The SF Symbol the tab draws (派单 073 suggested these five; all five resolve on macOS 27 — a
    /// missing name hands `NSImage` `nil` and the tab would draw nothing, so the test checks each one).
    ///
    /// `slider.horizontal.3` = the panel's sliders, `crop.rotate` = the crop/transform tools,
    /// `paintpalette` = colour, `circle.dashed` = a mask region, `clock.arrow.circlepath` = history.
    public var symbol: String {
        switch self {
        case .adjust: return "slider.horizontal.3"
        case .transform: return "crop.rotate"
        case .colour: return "paintpalette"
        case .masks: return "circle.dashed"
        case .history: return "clock.arrow.circlepath"
        }
    }

    /// **The one 「工作区 → 卡片」 table.**
    ///
    /// Membership only. `InspectorView.sections(in:)` filters `Section.allCases` with it, so the
    /// rendered order is the enum's order in every workspace, and a card can no more appear twice than
    /// it can appear out of turn. `.histogram` is deliberately absent from every case: the histogram is
    /// pinned above the switcher and is **not** something a workspace can hide (it stays visible in an
    /// empty workspace — that is part of the ask, not an oversight).
    public var cards: [InspectorView.Section] {
        switch self {
        case .adjust:
            // Everything the panel had before this workspace existed — presets included (the ask kept
            // them here: 「以及既有的 预设 卡也留在这里」).
            return [.whiteBalance, .blackLevel, .light, .color, .detail, .curve, .presets]
        case .transform:
            return []
        case .colour:
            return []
        case .masks:
            return [.masks]
        case .history:
            return []
        }
    }

    /// True when this workspace has something to show. `false` is not an error state: the ask says
    /// 「先空着」, and the view draws no cards, no placeholder and no message.
    public var hasCards: Bool { !cards.isEmpty }

    /// What the empty workspaces are *for* — the controls that will live there once they exist. Used
    /// only for the tooltip/accessibility label (a tooltip is not a placeholder on screen), so the
    /// button can say 「变换：旋转、裁切、校正（尚未实现）」 instead of a bare icon with no story.
    public var plannedControls: [String] {
        switch self {
        case .transform: return ["旋转", "裁切", "校正"]
        case .colour: return ["HSL"]
        case .history: return ["历史记录"]
        case .adjust, .masks: return []
        }
    }

    /// The button's `.help` — a tooltip, never drawn in the panel.
    public var help: String {
        guard hasCards else {
            let planned = plannedControls
            let body = planned.isEmpty ? "" : "：\(planned.joined(separator: "、"))"
            return "\(title)\(body)（尚未实现，暂无卡片）"
        }
        return "\(title)：\(cards.map(\.title).joined(separator: "、"))"
    }
}

/// The selection, as a value the panel observes and a test can drive.
///
/// A tiny reference type rather than `@State var selection` inside `InspectorView` for one reason:
/// 「切到蒙版后只剩蒙版卡」 has to be a *real* switch on a *hosted* panel, not a fresh `InspectorView`
/// built with a different constant (SwiftUI keeps `@State` across a root-view swap, so an init-only
/// parameter could not flip it). With this object a test hosts the panel once, flips `selection`,
/// waits for layout, and reads the same tree back.
@MainActor
@Observable
public final class InspectorWorkspaceState {

    /// The workspace the panel is showing. **View state**: never in the document, never in history.
    public var selection: InspectorWorkspace

    public init(_ selection: InspectorWorkspace = .adjust) {
        self.selection = selection
    }

    /// The button's action. One assignment, nothing else — no `applyEdit`, no `commitEdit`.
    public func select(_ workspace: InspectorWorkspace) {
        selection = workspace
    }
}

// MARK: - the switcher row

/// The row of five icon buttons between the histogram and the scroll area (派单 073).
///
/// It is deliberately the smallest thing that can carry five targets: **20 pt** tall, 11 pt glyphs,
/// 2 pt between tabs, one equal-width cell each (so 244 pt and 364 pt both lay out without clipping —
/// there is no minimum width a tab can be starved below). The selected tab is the **system accent**
/// (`Color.accentColor` — the same 「默认参数色」 060/071 use for the sliders that follow the system
/// accent) with a soft accent wash behind it; the other four are `Color.secondary`. `tint(_:selected:)`
/// is the only place that mapping exists.
///
/// Every tab carries `.help` (what it holds, or that it is still empty) and an `accessibilityLabel`
/// (its 中文名), so the row is usable with VoiceOver and with the pointer.
public struct InspectorWorkspaceTabs: View {

    @Binding public var selection: InspectorWorkspace

    /// The row's height — the whole vertical cost of the switcher. 20 pt is a hit target small enough
    /// to leave the cards alone and still a comfortable click (the top bar's buttons are 26–28 pt, the
    /// slider rows 16 pt).
    public static let rowHeight: CGFloat = 20
    /// The glyph size. One size for selected and unselected, so the row cannot jump on a switch.
    public static let iconSize: CGFloat = 11
    /// Gap between two tabs. The cells themselves are equal-width, so this is the only horizontal
    /// constant a narrow panel has to pay for.
    public static let tabSpacing: CGFloat = 2
    /// The selected tab's wash, and the corner radius it is drawn with.
    public static let selectionCornerRadius: CGFloat = 5
    public static let selectionOpacity: Double = 0.14

    public init(selection: Binding<InspectorWorkspace>) {
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: Self.tabSpacing) {
            ForEach(InspectorWorkspace.allCases) { workspace in
                tab(workspace)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.rowHeight)
        // A container, not one control: five separate buttons, each its own accessibility element.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.workspaces")
    }

    /// One tab: an SF Symbol in a full-width cell.
    ///
    /// No text label on screen (the ask is an icon row); the name lives in `.help` and in the
    /// accessibility label. The probe behind it is the test's readback of *what was built* — the
    /// same seam `MaskListPanel` uses, because SwiftUI draws its own views and a `Text`/`Image` has no
    /// AppKit leaf to measure under `swift test`.
    private func tab(_ workspace: InspectorWorkspace) -> some View {
        let isSelected = workspace == selection
        return Button {
            selection = workspace
        } label: {
            Image(systemName: workspace.symbol)
                .font(.system(size: Self.iconSize, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Self.tint(workspace, selected: selection))
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Self.selectionCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(Self.selectionOpacity))
            }
        }
        .background {
            WorkspaceTabProbeHost(workspace: workspace, isSelected: isSelected)
        }
        .help(workspace.help)
        .accessibilityLabel(workspace.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("inspector.workspace.\(workspace.rawValue)")
    }

    /// **The only colour decision in the switcher**: selected = the system accent, everything else =
    /// secondary. Written as a function so the test can render *this* view and sample its pixels
    /// (deleting the tint here must break that test), the trick 060 used for `shapeSlider`.
    public static func tint(_ workspace: InspectorWorkspace,
                            selected: InspectorWorkspace) -> Color {
        workspace == selected ? Color.accentColor : Color.secondary
    }
}

// MARK: - the two readback seams

/// One tab, as SwiftUI actually built it (per-tab, sized to the tab).
///
/// Reports the four facts a test cannot otherwise reach — which workspace the tab is, its glyph name,
/// whether that glyph resolved on this machine (`NSImage` hands back `nil` for an unknown name, and a
/// tab drawing nothing would be a silent bug), and whether it is the selected one. Its **frame** is the
/// tab's frame, which is where the 「244 pt 下不挤压、不截断」 measurement comes from.
///
/// `hitTest` answers `nil`: this view is full-size (unlike the 1 × 1 probes elsewhere) so it must not
/// eat the button's clicks.
public final class InspectorWorkspaceProbe: NSView {

    public private(set) var workspace: String = ""
    public private(set) var title: String = ""
    public private(set) var symbol: String = ""
    public private(set) var symbolResolves: Bool = false
    public private(set) var isSelected: Bool = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    public required init?(coder: NSCoder) {
        fatalError("InspectorWorkspaceProbe is created in code")
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var isOpaque: Bool { false }

    func update(_ workspace: InspectorWorkspace, isSelected: Bool) {
        self.workspace = workspace.rawValue
        self.title = workspace.title
        self.symbol = workspace.symbol
        self.symbolResolves = NSImage(systemSymbolName: workspace.symbol,
                                      accessibilityDescription: nil) != nil
        self.isSelected = isSelected
    }
}

struct WorkspaceTabProbeHost: NSViewRepresentable {
    var workspace: InspectorWorkspace
    var isSelected: Bool

    func makeNSView(context: Context) -> InspectorWorkspaceProbe {
        let probe = InspectorWorkspaceProbe()
        probe.update(workspace, isSelected: isSelected)
        return probe
    }

    func updateNSView(_ probe: InspectorWorkspaceProbe, context: Context) {
        probe.update(workspace, isSelected: isSelected)
    }
}

/// The scroll area's content, as the panel built it: which workspace, and which cards in which order.
///
/// SwiftUI `Text` has no AppKit leaf and the AX tree is empty under `swift test`, so 「切到蒙版只剩蒙版
/// 卡」 would otherwise be unfalsifiable. This probe is placed as the **background of the scrolling
/// content itself**, which gives it two jobs at once: it reports the card list, and its frame *is* the
/// scroll document — the anchor `InspectorPinnedHeaderTests` uses to prove the cards move while the
/// pinned block does not (that test used to use the mask card's own probe, which is no longer always
/// on screen now that 蒙版 has a workspace of its own).
public final class InspectorCardsProbe: NSView {

    public private(set) var workspace: String = ""
    /// Card ids in build order (`Section.rawValue`).
    public private(set) var cardIDs: [String] = []
    /// Card titles in build order — the same strings the cards are headed with.
    public private(set) var cardTitles: [String] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    public required init?(coder: NSCoder) {
        fatalError("InspectorCardsProbe is created in code")
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var isOpaque: Bool { false }

    func update(workspace: InspectorWorkspace, sections: [InspectorView.Section]) {
        self.workspace = workspace.rawValue
        self.cardIDs = sections.map(\.rawValue)
        self.cardTitles = sections.map(\.title)
    }
}

struct InspectorCardsProbeHost: NSViewRepresentable {
    var workspace: InspectorWorkspace
    var sections: [InspectorView.Section]

    func makeNSView(context: Context) -> InspectorCardsProbe {
        let probe = InspectorCardsProbe()
        probe.update(workspace: workspace, sections: sections)
        return probe
    }

    func updateNSView(_ probe: InspectorCardsProbe, context: Context) {
        probe.update(workspace: workspace, sections: sections)
    }
}
