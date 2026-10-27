import AppKit
import SwiftUI
import PhotonsCore

// MARK: - 051: the curve card — visible and draggable, nothing else
//
// The S1.7 HDR curve engine has existed since `6c8d5b8` (`CurveLUT.buildOne`, 4096 entries, monotone
// cubic) and `HDRCurveAxis` since `de71e26` (+4 EV at `u = 1`), but until now **no view in the library
// wrote `EditModel.curve`**: the maths was testable and unreachable. This file is the reach — the
// panel, and a testable editor model behind it. It changes no kernel, no axis and no mount point.
//
// Three rules shape the whole file:
//
//   1. **The preview is the engine's table, not a second interpolation.** `CurveEditorModel.preview`
//      is `CurveLUT.buildOne(points)` — the *same* 4096-entry table `RenderGraph` uploads. A private
//      spline here would be a picture that disagrees with the pixels, and that class of bug is the
//      hardest to see: both look like "a curve". This is why `CurveLUT.buildOne` is called and not
//      re-implemented, and why the test compares the two arrays element by element.
//
//   2. **The axis labels are positions on `HDRCurveAxis`, never numbers in this file.** The five
//      ticks are 0, 18 % grey, display white, +2 EV and +4 EV, and *where* each of them sits is the
//      shaper's answer — SDR white is a quarter of the way from the right edge, 18 % grey is a little
//      past the halfway point, and the last tick is the right edge itself. Typing any of those
//      positions here would be a second copy of the shaper's answer, and the day the axis moves the
//      card would draw its ticks somewhere the curve does not bend. `CurveAxisTicks` *derives* all
//      five from the axis; the test asserts equality to 1e-9 and greps this file for the literals.
//
//   3. **W is a luma gain, not a fourth per-channel table.** `CurveGroup.white` is applied as one
//      exposure offset to the pixel's luma (the kernel's rule), which preserves hue and saturation;
//      `red`/`green`/`blue` are separable per-channel maps. The two operators differ by up to 137
//      8-bit codes on a saturated HDR pixel, so the tab's tooltip says which one it is (030 §5.2).
//
// What is deliberately absent, per 051: black/white-point verticals (042's second half), the three
// eyedroppers, and any change to the gamma stage the curve sits in.

// MARK: - the four channels

/// The four tables of `CurveGroup`, as the four tabs.
///
/// Order is the buffer order (`W` first: `CurveLUT` builds `[white, red, green, blue]`), which is also
/// Lightroom's order, and `W` is the default selection because it is the one a tone curve is.
public enum CurveChannel: String, CaseIterable, Identifiable, Sendable {
    case white
    case red
    case green
    case blue

    public var id: String { rawValue }

    /// The tab's letter. `W` and not `RGB`, so the four tabs stay one row at the inspector's 244 pt
    /// minimum (4 × ~28 pt of segment is 112 pt of a 244 pt card).
    public var label: String {
        switch self {
        case .white: return "W"
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        }
    }

    /// The channel's name, for undo labels and the tooltip.
    public var name: String {
        switch self {
        case .white: return "亮度"
        case .red: return "红"
        case .green: return "绿"
        case .blue: return "蓝"
        }
    }

    /// Which table of the document this tab edits — the one place the four fields are named.
    public var keyPath: WritableKeyPath<CurveGroup, [CurvePoint]> {
        switch self {
        case .white: return \CurveGroup.white
        case .red: return \CurveGroup.red
        case .green: return \CurveGroup.green
        case .blue: return \CurveGroup.blue
        }
    }

    /// The tooltip. W's wording is not cosmetic: it is a *gain*, and calling it a channel table would
    /// misdescribe what the kernel does with it.
    public var help: String {
        switch self {
        case .white: return "W 是亮度增益：整像素按 luma 平移，保色相，不是第四张逐通道表"
        case .red: return "R 通道曲线（逐通道映射）"
        case .green: return "G 通道曲线（逐通道映射）"
        case .blue: return "B 通道曲线（逐通道映射）"
        }
    }

    /// The drawn colour. W is the panel's foreground colour, so it reads on both appearances.
    public var tint: Color {
        switch self {
        case .white: return .primary
        case .red: return Color(red: 0.87, green: 0.27, blue: 0.24)
        case .green: return Color(red: 0.24, green: 0.66, blue: 0.33)
        case .blue: return Color(red: 0.25, green: 0.47, blue: 0.88)
        }
    }
}

// MARK: - the horizontal axis' five ticks

/// One tick on the curve's x axis: where it is (in `u`) and what it says.
public struct CurveAxisTick: Equatable, Sendable {
    /// Position in the curve's own coordinate, `0…1` — the same unit as `CurvePoint.x` and as the
    /// table's index, so the tick, the point and the pixel all speak one language.
    public let u: Double
    public let label: String

    public init(u: Double, label: String) {
        self.u = u
        self.label = label
    }
}

/// The five ticks, **derived** from `HDRCurveAxis` and from nothing else.
///
/// `0` at the left edge (`u = 0` ↔ `x = 0`), 18 % grey, display white, and the two HDR stops the
/// histogram measures (+2 EV, +4 EV at the right edge). There is no `+6 EV` tick: 044 fixed the axis
/// at `xHI = 16`, and `u(stops: 4)` is exactly 1.
public enum CurveAxisTicks {

    /// 18 % grey — the one input value the axis labels. It is the *input* the tick stands for (what
    /// the label prints); the position is `axis.forward` of it, which is what keeps this file free of
    /// the shaper's answers.
    public static let middleGrey = 0.18

    public static func ticks(_ axis: HDRCurveAxis = .standard) -> [CurveAxisTick] {
        [
            CurveAxisTick(u: axis.forward(0), label: "0"),
            CurveAxisTick(u: axis.forward(middleGrey), label: "0.18"),
            CurveAxisTick(u: axis.forward(1), label: "1"),
            CurveAxisTick(u: axis.u(stops: 2), label: "+2"),
            CurveAxisTick(u: axis.u(stops: 4), label: "+4"),
        ]
    }

    /// The one grey line under the plot. The right end is read off the axis (`stops(at: 1)`) rather
    /// than typed as `+4`, for the same reason the ticks are.
    public static func footnote(_ axis: HDRCurveAxis = .standard) -> String {
        String(format: "横轴为曝光，右端 +%.0f EV", axis.stops(at: 1))
    }
}

// MARK: - the plot's geometry (pure, so the tests can hold it)

/// Where a `(u, y)` pair lands inside the plot rect, and which control point is under the pointer.
///
/// Both directions live here — `x(u:)` / `u(atX:)` are inverses, and `y(v:)` flips because AppKit's y
/// grows down while a curve's y grows up. Keeping this out of the `Canvas` closure is what lets the
/// tests ask "where is the +2 tick, in points" without a window.
public struct CurvePlotGeometry: Equatable {

    public let plot: CGRect

    public init(plot: CGRect) { self.plot = plot }

    /// A `u` in 0…1 → an x in the plot. Clamped: a drag that leaves the card still lands on an edge.
    public func x(u: Double) -> CGFloat {
        plot.minX + CGFloat(min(max(u.isFinite ? u : 0, 0), 1)) * plot.width
    }

    /// The curve's value (0…1, 1 = brighter) → a y in the plot (y grows *down*).
    public func y(v: Double) -> CGFloat {
        plot.maxY - CGFloat(min(max(v.isFinite ? v : 0, 0), 1)) * plot.height
    }

    public func point(_ p: CurvePoint) -> CGPoint { CGPoint(x: x(u: p.x), y: y(v: p.y)) }

    /// Inverse of `x(u:)`. Outside the plot it answers 0 or 1, never a number off the axis.
    public func u(atX x: CGFloat) -> Double {
        guard plot.width > 0 else { return 0 }
        return Double(min(max((x - plot.minX) / plot.width, 0), 1))
    }

    /// Inverse of `y(v:)`.
    public func v(atY y: CGFloat) -> Double {
        guard plot.height > 0 else { return 0 }
        return Double(min(max((plot.maxY - y) / plot.height, 0), 1))
    }

    /// Where each tick's line goes, in points — `x(u:)` of the axis-derived positions.
    public func tickPositions(_ ticks: [CurveAxisTick] = CurveAxisTicks.ticks()) -> [CGFloat] {
        ticks.map { x(u: $0.u) }
    }

    /// The nearest control point within `radius` of `location`, or `nil` in the empty area.
    ///
    /// Nearest, not first: two points can sit inside the hit radius of one another (the clamp only
    /// limits x, and a drag can put two points on the same y), and "first match in array order" would
    /// then grab the wrong one — the classic "why does this point jump to that one" bug.
    public func hitIndex(_ points: [CurvePoint], at location: CGPoint,
                         radius: CGFloat = CurvePanelMetrics.hitRadius) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (i, p) in points.enumerated() {
            let c = point(p)
            let d = hypot(c.x - location.x, c.y - location.y)
            guard d <= radius else { continue }
            if best == nil || d < best!.distance { best = (i, d) }
        }
        return best?.index
    }

    /// The 4 × 4 grid's lines (5 vertical + 5 horizontal, including the frame).
    public func gridLines(divisions: Int = CurvePanelMetrics.gridDivisions)
        -> (vertical: [CGFloat], horizontal: [CGFloat]) {
        let n = max(divisions, 1)
        let xs = (0...n).map { plot.minX + CGFloat($0) / CGFloat(n) * plot.width }
        let ys = (0...n).map { plot.minY + CGFloat($0) / CGFloat(n) * plot.height }
        return (xs, ys)
    }
}

// MARK: - point-list editing (pure)

/// ⇧ drag: which coordinate is allowed to move.
///
/// Named after the *value* that moves, not after the screen direction: `.x` means "only x changed",
/// which is what a mostly-horizontal drag asks for.
public enum CurveAxisLock: Sendable {
    case free
    /// x only (a horizontal drag): y stays where the press found it.
    case x
    /// y only (a vertical drag): x stays where the press found it.
    case y

    /// The lock a drag asks for: ⇧ picks the dominant direction, and `.free` without ⇧.
    ///
    /// The threshold is the same 2 pt `dragThreshold` the gesture uses, so a ⇧ drag that has not yet
    /// committed to a direction keeps both axes (nothing jumps on the first pixel of movement).
    public static func from(translation: CGSize, shift: Bool,
                            threshold: CGFloat = CurvePanelMetrics.dragThreshold) -> CurveAxisLock {
        guard shift else { return .free }
        let dx = abs(translation.width), dy = abs(translation.height)
        guard max(dx, dy) >= threshold else { return .free }
        return dx >= dy ? .x : .y
    }
}

/// The point-list operations, as functions of `[CurvePoint]`.
///
/// Pure on purpose: these are the four interactions the card offers (insert / clamp / move / delete),
/// and the tests drive them directly instead of trying to inject mouse events into a SwiftUI view —
/// `swift test` has no window session, and an accessibility tree is empty (047's known limit).
public enum CurveEditor {

    /// The gap the clamp keeps between neighbours. 1e-3 of the table's 4096 entries is ~4 samples, so
    /// two points can never land on the same sample and produce a zero-width segment — `buildOne`
    /// rejects those (`h > 1e-9`) and would silently fall back to the identity table.
    public static let minimumGap = 1e-3

    /// Keep a dragged point inside its neighbours, with `minimumGap` on each side.
    ///
    /// Endpoints are pinned horizontally: the first point is `x = 0` and the last is `x = 1`, because
    /// the table is *defined* on `0…1` and a curve whose first point sits at 0.2 would answer a
    /// constant below it (that is a black clip, not a curve). They can still move vertically.
    public static func clampX(_ x: Double, index: Int, in points: [CurvePoint]) -> Double {
        guard points.indices.contains(index) else { return min(max(x, 0), 1) }
        if index == 0 { return 0 }
        if index == points.count - 1 { return 1 }
        let lower = points[index - 1].x + minimumGap
        let upper = points[index + 1].x - minimumGap
        // Neighbours closer than 2 × the gap leave no legal x: stay where we are rather than jumping
        // to one side (the caller's `next != current` guard then writes nothing at all).
        guard upper >= lower else { return points[index].x }
        return min(max(x, lower), upper)
    }

    /// The point a drag produces: ⇧'s axis lock, then the clamp, then the unit square.
    public static func movedPoint(_ target: CurvePoint, index: Int, in points: [CurvePoint],
                                  from origin: CurvePoint, lock: CurveAxisLock) -> CurvePoint {
        guard points.indices.contains(index) else { return target }
        let locked: CurvePoint
        switch lock {
        case .free: locked = target
        case .x: locked = CurvePoint(target.x, origin.y)
        case .y: locked = CurvePoint(origin.x, target.y)
        }
        return CurvePoint(clampX(locked.x, index: index, in: points),
                          min(max(locked.y, 0), 1))
    }

    /// Insert a point at `(x, y)` in x order. The new x is clamped into the stretch it fell in, so a
    /// click near an endpoint cannot land *outside* the endpoints.
    ///
    /// Returns `nil` when there is no legal room — two endpoints closer than `2 × minimumGap`, which a
    /// document can only reach through a hand-written JSON blob.
    public static func insert(_ point: CurvePoint, into points: [CurvePoint]) -> (points: [CurvePoint], index: Int)? {
        guard points.count >= 2 else { return nil }
        let sorted = points.sorted { $0.x < $1.x }
        let y = min(max(point.y, 0), 1)
        // Which stretch does x fall in?
        var slot = sorted.count - 1
        for (i, p) in sorted.enumerated() where p.x > point.x { slot = i; break }
        let prev = sorted[max(slot - 1, 0)]
        let next = sorted[min(slot, sorted.count - 1)]
        let lower = prev.x + minimumGap
        let upper = next.x - minimumGap
        guard slot > 0, upper >= lower else { return nil }
        let x = min(max(point.x, lower), upper)
        var out = sorted
        out.insert(CurvePoint(x, y), at: slot)
        return (out, slot)
    }

    /// Remove one point. `nil` = refused, and the only refusal is an endpoint: the table needs a
    /// value at 0 and at 1, so deleting either would leave the curve undefined at an end.
    public static func deleting(_ index: Int, from points: [CurvePoint]) -> [CurvePoint]? {
        guard points.indices.contains(index), index != 0, index != points.count - 1 else { return nil }
        var out = points
        out.remove(at: index)
        return out
    }

    /// Strictly increasing x — the invariant `buildOne` depends on (`h > 1e-9`).
    public static func isOrdered(_ points: [CurvePoint]) -> Bool {
        zip(points, points.dropFirst()).allSatisfy { $0.x < $1.x }
    }
}

// MARK: - the editor model (what the tests and the view both drive)

/// The panel's model: the selected channel, the four verbs, and the preview table.
///
/// A value type over the session, created per body evaluation — it holds no document state of its own.
/// Every write goes through `CatalogSession.applyEdit` (which is the commit-free path: it bumps
/// `editRevision`, so the frame redraws, and pushes **no** snapshot), and one gesture ends with exactly
/// one `commitEdit(label:)`. That pairing *is* 047's "一次拖动 = 一条历史": a drag's ten intermediate
/// positions are ten `applyEdit`s and one snapshot.
@MainActor
public struct CurveEditorModel {

    public let session: CatalogSession
    public var channel: CurveChannel

    public init(session: CatalogSession, channel: CurveChannel = .white) {
        self.session = session
        self.channel = channel
    }

    // MARK: reading

    /// The selected channel's control points, in the document.
    public var points: [CurvePoint] { session.edit.curve[keyPath: channel.keyPath] }

    /// **The preview**: the engine's own 4096-entry table for these points.
    ///
    /// Not a second interpolation. `CurveLUT.buildOne` is what `RenderGraph` uploads, monotone-cubic
    /// overshoot clamp and identity fallback included, so the line on screen is the line in the pixels.
    public var preview: [Float] { CurveLUT.buildOne(points) }

    /// Which of the four tables are the identity — what the kernel's copy branch keys on.
    public var tablesAreIdentity: Bool { CurveLUT.isIdentity(session.edit.curve) }

    public var isCurrentChannelIdentity: Bool { points == CurvePoint.linear }

    /// The curve's value at `u`, read **out of the table** (nearest sample: the table is 4096 entries
    /// over 0…1, so a sample is 2.4e-4 wide — finer than the pixel the click landed on).
    ///
    /// This is what a click in empty space gives its new point: `y` is the curve's value there, not 0.
    /// A point born at 0 would drop the curve to black at that x, which is a tone change the user did
    /// not ask for — the click was "put a handle here".
    public func value(atU u: Double) -> Double {
        let table = preview
        guard !table.isEmpty else { return min(max(u, 0), 1) }
        let t = min(max(u, 0), 1) * Double(table.count - 1)
        return Double(table[min(max(Int(t.rounded()), 0), table.count - 1)])
    }

    // MARK: writing

    private func write(_ next: [CurvePoint]) {
        session.applyEdit { model in
            model.curve[keyPath: channel.keyPath] = next
        }
    }

    /// One click in the empty area: insert, then commit — a click is a complete action.
    @discardableResult
    public func insert(atU u: Double) -> Int? {
        let current = points
        guard let inserted = CurveEditor.insert(CurvePoint(u, value(atU: u)), into: current) else {
            return nil
        }
        write(inserted.points)
        session.commitEdit(label: InspectorView.Section.curve.title)
        return inserted.index
    }

    /// Press on a point: the snapshot the view keeps so a ⇧ drag knows which y (or x) to hold.
    public func beginDrag(at index: Int) -> CurvePoint? {
        points.indices.contains(index) ? points[index] : nil
    }

    /// One mouse-move: `applyEdit` only — **no** snapshot, however many of these fire.
    @discardableResult
    public func drag(index: Int, to target: CurvePoint, from origin: CurvePoint,
                     lock: CurveAxisLock) -> Bool {
        let current = points
        guard current.indices.contains(index) else { return false }
        var next = current
        next[index] = CurveEditor.movedPoint(target, index: index, in: current, from: origin, lock: lock)
        guard next != current else { return false }
        write(next)
        return true
    }

    /// Mouse up: the one snapshot for the whole drag. A press that never moved commits nothing
    /// (`applyEdit` short-circuits on "semantically identical", so the history has nothing to add).
    @discardableResult
    public func endDrag() -> Bool { session.commitEdit(label: InspectorView.Section.curve.title) }

    /// Double-click on a point. Endpoints refuse — silently, per 051 ("双击端点无效，不报错").
    @discardableResult
    public func delete(index: Int) -> Bool {
        let current = points
        guard let next = CurveEditor.deleting(index, from: current) else { return false }
        write(next)
        session.commitEdit(label: InspectorView.Section.curve.title)
        return true
    }

    /// 复位本通道: this table back to `CurvePoint.linear`, one snapshot, the other three untouched.
    @discardableResult
    public func resetChannel() -> Bool {
        guard !isCurrentChannelIdentity else { return false }
        session.applyEdit { $0.curve[keyPath: channel.keyPath] = CurvePoint.linear }
        return session.commitEdit(label: "复位本通道")
    }

    /// 全部复位 / double-click on the card title: all four tables back to the identity in **one**
    /// snapshot. The write itself is `PanelResets.curve()`, so the button and the title cannot diverge.
    @discardableResult
    public func resetAll() -> Bool { PanelResets(session: session).curve() }
}

// MARK: - the panel's numbers

/// The card's fixed numbers, in points. A test measures `fittingSize` at 274 pt of content width and
/// compares against these, so "the panel is 160/200 tall" is a number on both sides.
public enum CurvePanelMetrics {
    /// The plot's height. 200, not 160: the curve's interesting part is a narrow HDR tail (the last
    /// quarter of the axis, +0…+4 EV) sitting on a 60 % SDR body, and a shallow box makes a 1-stop bend
    /// above white look like a straight line. Near-square at the default 274 pt width (1.37:1).
    public static let plotHeight: CGFloat = 200
    /// Room under the plot for the tick labels (8 pt type + 1 pt of leading).
    public static let tickBand: CGFloat = 11
    /// The plot's own inset inside the drawing area, so the 1 pt frame is not clipped.
    public static let plotInset: CGFloat = 0.5
    public static let gridDivisions = 4
    /// A control point's radius (a filled dot) and the radius that counts as "on" it.
    public static let pointRadius: CGFloat = 3
    public static let hitRadius: CGFloat = 8
    /// A press has to travel this far to be a drag rather than a click.
    public static let dragThreshold: CGFloat = 2
    public static let tickLabelSize: CGFloat = 8
    public static let footnoteSize: CGFloat = 8
    public static let tabHeight: CGFloat = 18

    /// The plot rect inside a drawing area of `size` — the tick band is *inside* the area, so the
    /// Canvas and the hit test cannot disagree about where the plot is.
    public static func plotRect(in size: CGSize) -> CGRect {
        let height = max(size.height - tickBand, 1)
        return CGRect(x: plotInset, y: plotInset,
                      width: max(size.width - 2 * plotInset, 1),
                      height: max(height - plotInset, 1))
    }
}

// MARK: - the view

/// 曲线 — four tabs, one 4 × 4 grid with the y = x reference, the engine's table as the line, and
/// control points that can be inserted, dragged, ⇧-locked and double-clicked away.
///
/// The gestures are one `DragGesture(minimumDistance: 0)` rather than tap + drag recognisers: a click
/// and a drag start at the same event, and SwiftUI's tap/drag arbitration would make "click to insert"
/// and "drag a point" compete. Clicks are recognised here, on release, by distance — and the
/// double-click window is measured against `NSEvent.doubleClickInterval`, the user's own setting.
public struct CurvePanel: View {

    @Bindable public var session: CatalogSession

    /// The selected tab. View state on purpose: it is not a document fact (a channel selection is not
    /// an edit), so it never enters the history.
    @State private var channel: CurveChannel = .white

    /// The press in flight: which point, its value at press, and how far it has travelled.
    @State private var press: Press?

    /// The last click that landed on a point (for the double-click window).
    @State private var lastPointClick: (index: Int, time: TimeInterval)?

    /// The point this panel just inserted, so the second click of a double-click in empty space does
    /// not become "delete the point I just made".
    @State private var justInserted: (index: Int, time: TimeInterval)?

    private struct Press {
        /// The point under the press, `nil` in the empty area.
        let index: Int?
        let location: CGPoint
        let origin: CurvePoint?
        var travelled: CGFloat
    }

    public init(session: CatalogSession) {
        self.session = session
    }

    private var model: CurveEditorModel { CurveEditorModel(session: session, channel: channel) }

    public var body: some View {
        // The document is read **here**, in `body`, not inside the `Canvas` closure: a `Canvas` draws
        // outside the observation scope, so a curve read only at draw time would never invalidate this
        // view. The symptom would be the worst kind — the frame follows the drag, the curve does not.
        let points = model.points
        let table = model.preview
        return VStack(alignment: .leading, spacing: 6) {
            channelTabs
            plot(points: points, table: table)
            footnote
            buttons
        }
        // Greedy in width so the plot spans the card (274 pt at the default inspector, 244 at the
        // minimum) instead of collapsing to its ideal 117 pt; the height stays the fixed sum above.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: the four tabs

    private var channelTabs: some View {
        HStack(spacing: 4) {
            ForEach(CurveChannel.allCases) { candidate in
                Button { channel = candidate } label: {
                    Text(candidate.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(channel == candidate ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: CurvePanelMetrics.tabHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(channel == candidate ? 0.16 : 0.05))
                        )
                }
                .buttonStyle(.plain)
                .help(candidate.help)
                .accessibilityIdentifier("curve.channel.\(candidate.rawValue)")
                .accessibilityLabel(candidate.name)
            }
        }
    }

    // MARK: the plot

    private func plot(points: [CurvePoint], table: [Float]) -> some View {
        GeometryReader { proxy in
            let geometry = CurvePlotGeometry(plot: CurvePanelMetrics.plotRect(in: proxy.size))
            Canvas { context, _ in
                draw(into: &context, geometry: geometry, points: points, table: table)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in pressed(value, geometry: geometry) }
                    .onEnded { value in released(value, geometry: geometry) }
            )
            .accessibilityIdentifier("curve.plot")
        }
        .frame(height: CurvePanelMetrics.plotHeight)
    }

    private func draw(into context: inout GraphicsContext, geometry: CurvePlotGeometry,
                      points: [CurvePoint], table: [Float]) {
        let plot = geometry.plot
        let tint = channel.tint

        // The plot's own field, so the grid reads as graph paper rather than as card background.
        context.fill(Path(roundedRect: plot, cornerRadius: 3),
                     with: .color(Color.primary.opacity(0.04)))

        // 4 × 4 grid: 5 lines each way, the frame included (a curve needs its axes).
        let grid = geometry.gridLines()
        var gridPath = Path()
        for x in grid.vertical {
            gridPath.move(to: CGPoint(x: x, y: plot.minY))
            gridPath.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        for y in grid.horizontal {
            gridPath.move(to: CGPoint(x: plot.minX, y: y))
            gridPath.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        context.stroke(gridPath, with: .color(Color.primary.opacity(0.10)), lineWidth: 0.5)

        // y = x, dashed: the identity, so "did I change anything" is answerable by eye.
        var diagonal = Path()
        diagonal.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        diagonal.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        context.stroke(diagonal, with: .color(Color.primary.opacity(0.22)),
                       style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))

        // The curve: one polyline through the engine's 4096 samples. No smoothing here — the table is
        // already smooth (monotone cubic), and a second smoother would round the clamped knees.
        if table.count >= 2 {
            var curve = Path()
            curve.move(to: CGPoint(x: geometry.x(u: 0), y: geometry.y(v: Double(table[0]))))
            for i in 1..<table.count {
                let u = Double(i) / Double(table.count - 1)
                curve.addLine(to: CGPoint(x: geometry.x(u: u), y: geometry.y(v: Double(table[i]))))
            }
            context.stroke(curve, with: .color(tint), lineWidth: 1.4)
        }

        // Control points: 3 pt filled dots; the one under the hand gets a ring.
        for (i, p) in points.enumerated() {
            let centre = geometry.point(p)
            let r = CurvePanelMetrics.pointRadius
            let dot = Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r,
                                             width: 2 * r, height: 2 * r))
            context.fill(dot, with: .color(tint))
            if press?.index == i {
                let ringR = r + 2
                let ring = Path(ellipseIn: CGRect(x: centre.x - ringR, y: centre.y - ringR,
                                                  width: 2 * ringR, height: 2 * ringR))
                context.stroke(ring, with: .color(Color.primary.opacity(0.9)), lineWidth: 1)
            }
        }

        // The five ticks, at the axis' own positions.
        let ticks = CurveAxisTicks.ticks()
        for (i, tick) in ticks.enumerated() {
            let x = geometry.x(u: tick.u)
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.maxY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY + 3))
            context.stroke(line, with: .color(Color.primary.opacity(0.35)), lineWidth: 0.7)

            let anchor: UnitPoint = i == 0 ? .topLeading : (i == ticks.count - 1 ? .topTrailing : .top)
            context.draw(Text(tick.label)
                            .font(.system(size: CurvePanelMetrics.tickLabelSize))
                            .foregroundStyle(Color.secondary),
                         at: CGPoint(x: x, y: plot.maxY + 3), anchor: anchor)
        }
    }

    // MARK: one gesture: press → drag → release

    private func pressed(_ value: DragGesture.Value, geometry: CurvePlotGeometry) {
        if press == nil {
            let hit = geometry.hitIndex(model.points, at: value.startLocation)
            press = Press(index: hit, location: value.startLocation,
                          origin: hit.flatMap { model.beginDrag(at: $0) }, travelled: 0)
        }
        guard var current = press else { return }
        current.travelled = max(current.travelled,
                                hypot(value.translation.width, value.translation.height))
        press = current

        guard let index = current.index, let origin = current.origin,
              current.travelled >= CurvePanelMetrics.dragThreshold else { return }
        let target = CurvePoint(geometry.u(atX: value.location.x),
                               geometry.v(atY: value.location.y))
        let lock = CurveAxisLock.from(translation: value.translation,
                                      shift: NSEvent.modifierFlags.contains(.shift))
        // `applyEdit` only — ten of these make one history entry, because nothing commits until `released`.
        model.drag(index: index, to: target, from: origin, lock: lock)
    }

    private func released(_ value: DragGesture.Value, geometry: CurvePlotGeometry) {
        guard let current = press else { return }
        press = nil

        if let index = current.index {
            guard current.travelled < CurvePanelMetrics.dragThreshold else {
                // One drag = one snapshot.
                model.endDrag()
                return
            }
            click(on: index)
        } else {
            // A press that travelled in the empty area is nothing (there is no pan on this card).
            guard current.travelled < CurvePanelMetrics.dragThreshold else { return }
            insert(at: geometry.u(atX: current.location.x))
        }
    }

    private func click(on index: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        if let just = justInserted, just.index == index, now - just.time < NSEvent.doubleClickInterval {
            justInserted = nil          // the second half of "double-click in empty space"
            return
        }
        if let last = lastPointClick, last.index == index, now - last.time < NSEvent.doubleClickInterval {
            lastPointClick = nil
            model.delete(index: index)  // endpoints refuse, silently
        } else {
            lastPointClick = (index, now)
        }
    }

    private func insert(at u: Double) {
        guard let index = model.insert(atU: u) else { return }
        justInserted = (index, ProcessInfo.processInfo.systemUptime)
    }

    // MARK: the footnote and the two buttons

    private var footnote: some View {
        Text(CurveAxisTicks.footnote())
            .font(.system(size: CurvePanelMetrics.footnoteSize))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            smallButton("复位本通道") { model.resetChannel() }
            smallButton("全部复位") { model.resetAll() }
        }
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("curve.button.\(title)")
    }
}
