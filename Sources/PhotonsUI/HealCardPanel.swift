import SwiftUI
import PhotonsCore

// MARK: - 221: 修复 is its own card, next to the mask card

/// The 蒙版 workspace's two cards, declared once.
///
/// `reset` is a **declaration**, not a missing branch (214's rule): `.none` says the card has no
/// "default" to go back to, so a future reader cannot mistake "no reset" for "forgot the reset".
/// The 蒙版 card resets the selected mask (`PanelResets.maskCard(_:)`); the 修复 card deliberately
/// has no double-click verb — its spots are a list, and "the default list" is not a thing.
public struct MaskWorkspaceCardSpec: Equatable, Sendable {

    public enum Reset: String, Equatable, Sendable {
        /// Double-click puts the **selected mask** back in one snapshot.
        case selectedMask
        /// Explicitly none: the 修复 card has no defaults to restore.
        case none
    }

    public let title: String
    public let reset: Reset

    public init(title: String, reset: Reset) {
        self.title = title
        self.reset = reset
    }

    /// 蒙版 — title and reset scope unchanged (`Section.masks.title`).
    public static let mask = MaskWorkspaceCardSpec(title: InspectorView.Section.masks.title,
                                                   reset: .selectedMask)

    /// 修复 — the card this task split out of 蒙版. No reset by design.
    public static let heal = MaskWorkspaceCardSpec(title: "修复", reset: .none)

    /// Top-to-bottom, the order `InspectorView` mounts them.
    public static let all: [MaskWorkspaceCardSpec] = [.mask, .heal]

    /// The title's double-click action, derived from `reset` — the same value the view uses, so the
    /// declaration and the gesture cannot disagree.
    @MainActor
    public func resetAction(session: CatalogSession) -> (() -> Void)? {
        switch reset {
        case .none:
            return nil
        case .selectedMask:
            return {
                guard let id = session.selectedMaskID else { return }
                _ = PanelResets(session: session).maskCard(id)
            }
        }
    }
}

/// The 修复 card: the tool button, the count, the mode picker, 自动取源, the last source status, and
/// one row per spot — everything 078 put inside the mask card, now in its own card.
///
/// It keeps the same chrome as every other card (`InspectorCardShell`: glass, hairline, the
/// `WorkspaceLayout.cardInset*` paddings and corner radius), and it renders **always** — an empty
/// document is an empty card with its controls still usable, not a missing card.
public struct HealCardPanel: View {

    @Bindable public var session: CatalogSession
    /// Kept for symmetry with `MaskListPanel` and for a future eyedropper-style source picker; the
    /// card's current controls are all session/view state and do not need the canvas.
    public let loupe: LoupeController?

    public init(session: CatalogSession, loupe: LoupeController? = nil) {
        self.session = session
        self.loupe = loupe
    }

    public var body: some View {
        let card = MaskWorkspaceCardSpec.heal
        InspectorCardShell(title: card.title,
                           reset: card.resetAction(session: session),
                           titleAccessibilityID: "inspector.card.heal.title",
                           accessory: { EmptyView() }) {
            content
        }
        .accessibilityIdentifier("inspector.card.heal")
        // 221 readback seam: the AX tree is empty in `swift test`, so the card publishes its own
        // title/count and the tool button's frame for a hosted test.
        .background(alignment: .topLeading) {
            HealCardProbeHost(title: card.title, spotCount: session.edit.healSpots.count)
                .frame(width: 1, height: 1)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    session.healTool.toggle()
                    // One canvas gesture at a time: arming the spot tool disarms the brush.
                    if session.healTool { session.maskTool = .off }
                } label: {
                    Label("修复", systemImage: "bandage")
                        .font(.system(size: 10, weight: .medium))
                }
                // 276 — `.plain` drew no AppKit button leaf, so the hosted test's synthetic click
                // reached only the hosting view and never the SwiftUI action. `.borderless` keeps
                // 253's look (no bezel; the fill is ours) but keeps the real clickable control —
                // the same style the card's other tool buttons already use.
                .buttonStyle(.borderless)
                .controlSize(.mini)
                // 253 — the visible blue is the fill, not `.tint` (a bordered button's tint never
                // paints its bezel). One style for every tool button: `ToolActiveStyle`.
                .toolActive(session.healTool)
                .accessibilityIdentifier("inspector.heal.tool")
                .help("点画布 = 在点击处加一个修复点；源点自动搜索，关掉自动取源则取右边一个半径。⌥+滚轮 或 [ / ] 调大小")
                // Its frame is the button's, so a hosted test can click the real SwiftUI button
                // (AX is empty under `swift test`). `hitTest` is nil: the probe never eats a click.
                .background(HealToolProbeHost(isArmed: session.healTool))

                Text("\(session.edit.healSpots.count)/\(HealSpot.maxCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                if session.healToolMode == .heal {
                    Picker("", selection: healModeBinding) {
                        ForEach(HealMode.allCases, id: \.rawValue) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .labelsHidden()
                    .frame(width: 86)
                    .accessibilityIdentifier("inspector.heal.mode")
                }
            }
            // 229 — 修复 / 红眼. One card, two presets of the same spot tool.
            //
            // 253 — built from `ToolSegmentButton` instead of the native segmented Picker so the
            // selected preset is the same accent fill + white text as every other armed tool.
            HStack(spacing: 2) {
                ForEach(HealToolMode.allCases, id: \.rawValue) { mode in
                    ToolSegmentButton(title: mode.label,
                                      active: session.healTool && session.healToolMode == mode) {
                        healToolModeBinding.wrappedValue = mode
                    }
                    .accessibilityIdentifier("inspector.redeye.mode.\(mode.rawValue)")
                }
            }
            .accessibilityIdentifier("inspector.redeye.mode")
            .help("红眼是 修复 的一个预设：点一次找红瞳并修正，拖动连续修补")
            if session.healToolMode == .redeye {
                redEyeControls
            }
            Toggle("自动取源", isOn: Binding(get: { session.autoHealSource },
                                            set: { session.autoHealSource = $0 }))
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
                .controlSize(.mini)
                .accessibilityIdentifier("inspector.heal.autoSource")
                .help("搜索缺陷周围 2–4 个半径的环形带，取边界最像的一块做源；关掉 = 老行为（右移一个半径）")
            if let source = session.lastHealSource {
                Text(healSourceStatus(source))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("inspector.heal.sourceStatus")
            }
            if session.edit.healSpots.isEmpty {
                Text("还没有修复点")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("inspector.heal.empty")
            } else {
                ForEach(session.edit.healSpots) { spot in
                    healRow(spot)
                }
            }
        }
    }

    /// 229 — the two controls that only mean something for 红眼. Shown when that segment is on.
    private var redEyeControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("半径")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: redEyeRadiusBinding, in: RedEye.radiusPointsRange)
                    .controlSize(.mini)
                    .accessibilityIdentifier("inspector.redeye.radius")
                Text(String(format: "%.1f pt", session.redEyeRadiusPoints))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            HStack(spacing: 6) {
                Text("强度")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: redEyeStrengthBinding, in: 0 ... 100)
                    .controlSize(.mini)
                    .accessibilityIdentifier("inspector.redeye.strength")
                Text("\(Int((session.redEyeStrength * 100).rounded()))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Text("点一下修一只红眼；拖动连续修补")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("inspector.redeye.hint")
        }
    }

    private func healRow(_ spot: HealSpot) -> some View {
        HStack(spacing: 6) {
            Text(spot.kind == .redeye ? "红眼" : spot.mode.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            Slider(value: Binding(get: { spot.radius },
                                  set: { session.setHealRadius($0, for: spot.id, commit: false) }),
                   in: HealSpot.radiusRange,
                   onEditingChanged: { editing in
                       if !editing { session.commitEdit(label: "修复 半径") }
                   })
            .controlSize(.mini)
            Text(String(format: "%.3f", spot.radius))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Button {
                session.deleteHealSpot(spot.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .accessibilityIdentifier("inspector.heal.delete.\(spot.id)")
            .help("删除这个修复点")
        }
        .accessibilityIdentifier("inspector.heal.row.\(spot.id)")
    }

    /// One line of truth about where the last new spot's source came from — the search never
    /// silently falls back, so the panel says which answer the user actually got.
    private func healSourceStatus(_ source: HealSourceResult) -> String {
        switch source.status {
        case .found:
            return String(format: "源：自动（%.1f 个半径）", source.distanceInRadii)
        case .noCandidateAccepted:
            return "源：带内无可用源，用默认"
        case .searchSkipped:
            return "源：默认"
        }
    }

    private var healToolModeBinding: Binding<HealToolMode> {
        Binding(get: { session.healToolMode }, set: { session.healToolMode = $0 })
    }

    private var redEyeRadiusBinding: Binding<Double> {
        Binding(get: { session.redEyeRadiusPoints },
                set: { session.redEyeRadiusPoints = min(max($0,
                                                             RedEye.radiusPointsRange.lowerBound),
                                                          RedEye.radiusPointsRange.upperBound) })
    }

    private var redEyeStrengthBinding: Binding<Double> {
        Binding(get: { session.redEyeStrength * 100 },
                set: { session.redEyeStrength = min(max($0, 0), 100) / 100 })
    }

    private var healModeBinding: Binding<HealMode> {
        Binding(get: { session.healMode },
                set: { mode in
                    session.healMode = mode
                    // A mode picked in the panel applies to the spot the panel is pointed at too —
                    // otherwise the segmented control would look like it did nothing on an existing
                    // spot.
                    if let id = session.selectedHealSpotID ?? session.edit.healSpots.last?.id {
                        session.setHealMode(mode, for: id)
                    }
                })
    }
}

// MARK: - the readback seam

/// What the 修复 card reports when the AX tree is unavailable (`swift test` is not a trusted
/// accessibility client): the declared title and how many spots the card is drawing.
public final class HealCardProbe: NSView {
    public private(set) var title: String = ""
    public private(set) var spotCount: Int = 0
    public var isEmpty: Bool { spotCount == 0 }

    /// Never a hit target and never drawn: it exists to be read.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var isOpaque: Bool { false }

    public func publish(title: String, spotCount: Int) {
        self.title = title
        self.spotCount = spotCount
    }
}

struct HealCardProbeHost: NSViewRepresentable {
    var title: String
    var spotCount: Int

    func makeNSView(context: Context) -> HealCardProbe {
        let probe = HealCardProbe()
        probe.publish(title: title, spotCount: spotCount)
        return probe
    }

    func updateNSView(_ probe: HealCardProbe, context: Context) {
        probe.publish(title: title, spotCount: spotCount)
    }
}

/// The 修复 tool button's own frame. Full-size on purpose (a 1 × 1 probe would give a test no target
/// to click), never a hit target, never drawn.
public final class HealToolProbe: NSView {
    public private(set) var isArmed: Bool = false

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var isOpaque: Bool { false }

    public func publish(isArmed: Bool) { self.isArmed = isArmed }
}

struct HealToolProbeHost: NSViewRepresentable {
    var isArmed: Bool

    func makeNSView(context: Context) -> HealToolProbe {
        let probe = HealToolProbe()
        probe.publish(isArmed: isArmed)
        return probe
    }

    func updateNSView(_ probe: HealToolProbe, context: Context) {
        probe.publish(isArmed: isArmed)
    }
}
