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
//      shaper's answer — since 062 the axis is the histogram's own: display white is the **middle**
//      of the card (the histogram's `sdrFraction`), 18 % grey is a quarter of the way in, and the
//      last tick is the right edge itself. Typing any of those
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
// eyedroppers, and any change to the gamma stage the curve sits in. 061 makes the *endpoints* movable
// in x (that is the black point), and adds no handle beyond the two control points themselves.
//
// 069 adds two things and changes no gesture: the point under the hand gets its coordinates in the
// card's footer row (`输入 233 输出 +1.22`), and the plot can zoom into one half of the axis
// (`CurveViewMode`). `CurvePoint` is an integer grid cell (0…511 per axis) as of the same order, so
// "where did the point land" has exactly one answer in the document, in the read-out and in the key.
//
// 070 fixes the two things the owner found in 069's card, and both are about what he *saw*:
//
//   · **The region switch is a row of its own at the top** (`regionRow`), not the last item of the tab
//     row. There it was squeezed against 复位本通道 below and truncated to 「HDR…」, and he read it as
//     a footer control — 「在下方，复位旁边」. The card is now 区域 行 → 通道 tabs → 绘图区 →
//     读数/复位, 269 pt tall instead of 245, with the plot, the tabs and the footer rows the same
//     heights they were.
//   · **The curve is drawn on the card's axis.** The `0…2` migration moved `CurvePoint.maximum`,
//     `xSpan`, the ticks and the read-out, but `draw` kept feeding the *table's* `0…1` numbers
//     straight into `x(u:)`/`y(v:)`. Every curve was therefore drawn at half scale in the lower-left
//     quadrant, and the SDR window (`0…1`) let the whole table through — so 「切到 SDR 后曲线没有重新
//     绘制」: the layer was repainted, with a picture of the wrong region. `2·u` / `2·v` is the whole
//     of the fix, plus `yRaw` + a clip so a sample above white leaves the frame instead of stacking on
//     its top edge. `CurveRegionTests` holds all of it as pixels.

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

// MARK: - the two view modes (069)

/// Which part of the axis the plot is showing — **two states**, `all ⇄ sdr`.
///
/// 069's 「精细调节」: the card can zoom into the SDR half of the axis so a cell that is 0.5 pt wide
/// at full width is 1 pt wide. Crucially the *grid does not change* — `sdr` magnifies the lower-left
/// quadrant of the same 512 × 512 cells (cells `0…255` on each axis, 256 of them), so "the SDR view
/// is a 256 × 256 grid" is the consequence of the magnification, not a second coordinate system. One
/// coordinate space means a point's read-out, its stored cell and its table entry are identical in
/// both modes (`testTheReadoutIsTheSameTextInBothViews`), and the drag code needs no per-view branch.
///
/// **There is no HDR mode.** The owner's rule is 「按钮是两态，不单独对 HDR 做设置」: the HDR half is
/// reached by nothing, and `+0…+4` exists only as the right four of `all`'s seven ticks.
///
/// **The button's second label is 「HDR 区域」 by the owner's decision, and it is not a typo.** The
/// cycle is `all → sdr → all`, so the button in the SDR state takes you back to *all*; the owner was
/// asked which words it should wear there and answered 「全部区域就叫 HDR 区域」. Do not "fix" it to
/// 全部区域 — `testTheViewButtonSaysSdrThenHdr` pins both strings.
public enum CurveViewMode: String, CaseIterable, Identifiable, Sendable {
    /// The whole axis: 512 cells per axis, display white in the middle (062).
    case all
    /// The lower-left quadrant: input **and** output below display white — cells `0…255`.
    case sdr

    public var id: String { rawValue }

    /// The other state. Two states, so "next" and "other" are the same thing.
    public var next: CurveViewMode { self == .all ? .sdr : .all }

    public var title: String {
        switch self {
        case .all: return "全部视图"
        case .sdr: return "SDR 视图"
        }
    }

    /// What the button says — the state pressing it switches to. `sdr`'s label is 「HDR 区域」 by the
    /// owner's decision (see the type's note): the button there returns to the whole axis.
    public var buttonTitle: String {
        switch self {
        case .all: return "SDR 区域"
        case .sdr: return "HDR 区域"
        }
    }
}

// MARK: - the horizontal axis' ticks

/// One tick on the curve's x axis: where it is and what it says.
public struct CurveAxisTick: Equatable, Sendable {
    /// Position on the card's own `0…2` coordinate — **the same number as `CurvePoint.x`** (069), so
    /// the tick, the point and the read-out all speak one language. The engine's axis is `x / 2`.
    public let x: Double
    public let label: String

    public init(x: Double, label: String) {
        self.x = x
        self.label = label
    }
}

/// The ticks, **derived** from `HDRCurveAxis` and from nothing else.
///
/// 069 redrew the axis in the card's `0…2` coordinate — `0…1` is display code `0…255` (`x = 1` is
/// white), `1…2` is `+0…+4 EV` — so the ticks are **nine**: the five codes the owner asked for
/// (`0 63 127 191 255`) and the four stops (`+1 +2 +3 +4`, with `+4` on the right edge at `x = 2`).
///
/// There is no "SDR / HDR" label on the axis: the numbers say it. `255` is followed by `+1`, and that
/// jump *is* the boundary — the owner's 「这样也不需要 sdr/hdr 标示了」.
///
/// A display code `c` is the *encoded* value `c/255`; the axis takes **linear** input, so the code is
/// decoded first and the position is `2·forward(displayCode(c))`, which is exactly `c/255` because
/// `encode` and `decode` are inverses — the test asserts that equality, so "the tick sits at its own
/// code" is a fact rather than a rounding coincidence. The stops are `2·u(stops: s) = 1 + 0.25·s`.
public enum CurveAxisTicks {

    /// The five SDR codes the owner asked for — **and nothing on the HDR half**.
    ///
    /// 069: 「stops 标记取消」. The right half of the card is left blank: no `+1 … +4`, no `SDR`/`HDR`
    /// words, no divider. It is still the +0…+4 EV half (the positioning maths did not change), it
    /// simply carries no label — the numbers `0 … 255` already say where display white is.
    public static func ticks(_ axis: HDRCurveAxis = .standard,
                             view: CurveViewMode = .all) -> [CurveAxisTick] {
        _ = view      // both views label the same five codes; the SDR view just magnifies them
        return [0, 63, 127, 191, 255].map { code in
            CurveAxisTick(x: 2 * axis.forward(displayCode(Double(code))), label: "\(code)")
        }
    }

    /// An 8-bit display code as scene-linear light — what the axis' `forward` expects.
    public static func displayCode(_ code: Double) -> Double {
        HDRCurveAxis.srgbDecode(code / 255)
    }
}

// MARK: - the plot's geometry (pure, so the tests can hold it)

/// Where a `(u, y)` pair lands inside the plot rect, and which control point is under the pointer.
///
/// Both directions live here — `x(u:)` / `u(atX:)` are inverses, and `y(v:)` flips because AppKit's y
/// grows down while a curve's y grows up. Keeping this out of the `Canvas` closure is what lets the
/// tests ask "where is the +2 tick, in points" without a window.
///
/// **069 — the view is a window on the same axis, not a second one.** `view` names the span the box
/// shows; `x(u:)` maps *that* span onto the box, so `.all` is the identity mapping it always was and
/// `.sdr` is exactly twice as fine (half the axis across the same width). `u`/`v` remain the only
/// coordinate: a point's stored cell, its position here and its read-out are the same number in both
/// modes.
public struct CurvePlotGeometry: Equatable {

    /// The plot's own rect — the card's frame, the tick band's top. **Not** where the values land.
    public let plot: CGRect

    /// How far the *value box* is pulled in from `plot`: one point radius plus 1 pt of breathing room
    /// (064). `u = 0/1` and `v = 0/1` land one radius inside `plot`, so the control point's circle is
    /// drawn whole instead of half (on an edge) or a quarter (in a corner).
    ///
    /// This is the fix, and it is deliberately *not* "clamp the circle into the frame": clamping draws
    /// a point at `u = 0` at `x = 4` while it still reads 0 — the picture and the number would disagree.
    /// Insetting the box the values map into keeps the circle's centre **exactly** where the value is.
    public let inset: CGFloat

    /// Which cells the box shows (069). `.all` is the whole axis.
    public let view: CurveViewMode

    public init(plot: CGRect, inset: CGFloat = CurvePanelMetrics.pointInset,
                view: CurveViewMode = .all) {
        self.plot = plot
        self.inset = max(inset, 0)
        self.view = view
    }

    /// The box the values live in: `plot` inset by `inset` on every side. The grid, the frame and the
    /// y = x diagonal are all drawn on *this* box, so "the grid does not touch its frame" cannot happen.
    public var valueBox: CGRect { plot.insetBy(dx: inset, dy: inset) }

    /// The `u` span the box shows — `0…1` for `.all`, the **SDR half** for `.sdr`.
    ///
    /// The SDR view is exactly half the axis (`0…whiteU`), which is what makes its magnification a
    /// clean 2×: one cell is `1/511` of the axis, so it is `2/511` of this span — twice the screen
    /// distance it has in `.all` (`testTheSdrViewDoublesTheGridStep`). It also puts the `255` tick
    /// (`forward(displayCode(255)) == whiteU`, 062) **exactly** on the right edge, which is the label
    /// the owner's five-tick set ends on.
    public var xSpan: ClosedRange<Double> {
        switch view {
        case .all: return 0...CurvePoint.maximum
        case .sdr: return 0...CurvePoint.sdrBoundary
        }
    }

    /// A coordinate in the view's span — **the card's own `CurvePoint.x`, `0…2`** (the parameter keeps
    /// its old label `u` for the call sites; the engine's `u` is half of it) → an x in the value box:
    /// `x(1) == width − inset` for `.all`, and the same for the view's own two ends otherwise.
    /// Clamped: a drag that leaves the card still lands on an edge.
    public func x(u: Double) -> CGFloat {
        let box = valueBox
        let span = xSpan
        let value = u.isFinite ? u : span.lowerBound
        let t = (min(max(value, span.lowerBound), span.upperBound) - span.lowerBound)
            / (span.upperBound - span.lowerBound)
        return box.minX + CGFloat(t) * max(box.width, 0)
    }

    /// The curve's value — **the card's `0…2` coordinate**, the same number as `CurvePoint.y` → a y in
    /// the value box (y grows *down*). Clamped into the view's span, which is what a **drag** wants: a
    /// pointer that leaves the box still lands on an edge.
    public func y(v: Double) -> CGFloat {
        let span = xSpan
        let value = v.isFinite ? v : span.lowerBound
        return yRaw(v: min(max(value, span.lowerBound), span.upperBound))
    }

    /// The same mapping **without** the clamp, for the drawing.
    ///
    /// 070: the windowed view needs this. A sample whose *output* is above white (`v > 1`) belongs
    /// above the SDR box; clamped — which is right for a hand — every such sample would pile onto
    /// `box.minY` and the plot would carry a horizontal black line along its top edge that is not in
    /// the table. Unclamped, the polyline leaves the frame and the clip in `draw` cuts it there.
    public func yRaw(v: Double) -> CGFloat {
        let box = valueBox
        let span = xSpan
        let value = v.isFinite ? v : span.lowerBound
        let t = (value - span.lowerBound) / (span.upperBound - span.lowerBound)
        return box.maxY - CGFloat(t) * max(box.height, 0)
    }

    public func point(_ p: CurvePoint) -> CGPoint { CGPoint(x: x(u: p.x), y: y(v: p.y)) }

    /// Whether this point is inside the view — the drawing and the hit test both ask, so a point the
    /// card does not show cannot be dragged by pressing where it is not drawn (069).
    ///
    /// The test is on the point's `u`/`v`, i.e. on the same numbers the mapping uses, so "drawn" and
    /// "hittable" cannot disagree with "where it maps". In the SDR view that is cells `0…255`: cell
    /// 255 (`255/511 = 0.49902`) is inside, cell 256 (`0.50098`) is outside.
    public func isVisible(_ p: CurvePoint) -> Bool {
        xSpan.contains(p.x) && xSpan.contains(p.y)
    }

    /// Inverse of `x(u:)`. Outside the value box it answers the view's own ends, never a number off
    /// the axis.
    public func u(atX x: CGFloat) -> Double {
        let box = valueBox
        let span = xSpan
        guard box.width > 0 else { return span.lowerBound }
        let t = Double(min(max((x - box.minX) / box.width, 0), 1))
        return span.lowerBound + t * (span.upperBound - span.lowerBound)
    }

    /// Inverse of `y(v:)`.
    public func v(atY y: CGFloat) -> Double {
        let box = valueBox
        let span = xSpan
        guard box.height > 0 else { return span.lowerBound }
        let t = Double(min(max((box.maxY - y) / box.height, 0), 1))
        return span.lowerBound + t * (span.upperBound - span.lowerBound)
    }

    /// Where each tick's line goes, in points — `x(u:)` of the axis-derived positions, for this view.
    public func tickPositions(_ ticks: [CurveAxisTick] = CurveAxisTicks.ticks()) -> [CGFloat] {
        ticks.map { x(u: $0.x) }
    }

    /// The nearest control point within `radius` of `location`, or `nil` in the empty area.
    ///
    /// Nearest, not first: two points can sit inside the hit radius of one another (the clamp only
    /// limits x, and a drag can put two points on the same y), and "first match in array order" would
    /// then grab the wrong one — the classic "why does this point jump to that one" bug.
    ///
    /// 069: points outside the view are skipped. They are still drawn nowhere, and their clamped
    /// screen position sits *on* the frame — without this filter a press on the SDR view's right edge
    /// would grab a point living in the HDR half.
    public func hitIndex(_ points: [CurvePoint], at location: CGPoint,
                         radius: CGFloat = CurvePanelMetrics.hitRadius) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (i, p) in points.enumerated() where isVisible(p) {
            let c = point(p)
            let d = hypot(c.x - location.x, c.y - location.y)
            guard d <= radius else { continue }
            if best == nil || d < best!.distance { best = (i, d) }
        }
        return best?.index
    }

    /// The 4 × 4 grid's lines (5 vertical + 5 horizontal, including the frame) — on the **value box**,
    /// so the outermost lines are exactly the box the values map into. The divisions are of the
    /// *view*, so the SDR quadrant's grid is 4 × 4 over 256 cells (069).
    public func gridLines(divisions: Int = CurvePanelMetrics.gridDivisions)
        -> (vertical: [CGFloat], horizontal: [CGFloat]) {
        let n = max(divisions, 1)
        let box = valueBox
        let xs = (0...n).map { box.minX + CGFloat($0) / CGFloat(n) * max(box.width, 0) }
        let ys = (0...n).map { box.minY + CGFloat($0) / CGFloat(n) * max(box.height, 0) }
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
///
/// 069: every operation is on the **grid**, so "1e-3 of u" became "one cell"
/// (`minimumGapSteps`) and the clamp's answer is a cell, never a coordinate between two.
public enum CurveEditor {

    /// The gap the clamp keeps between neighbours, in the card's own coordinate (`0…2`, 069).
    ///
    /// 051 asked for `1e-3` of the axis so two points can never share a table sample (4096 samples,
    /// `buildOne` rejects a zero-width segment and would fall back to the identity table). The number
    /// is kept as it was and now means `1e-3` of the `0…2` coordinate — half as much of the axis as
    /// before, i.e. a *tighter* clamp, and still far wider than one table sample (2.4e-4).
    public static let minimumGap = 1e-3

    /// Keep a dragged point inside its neighbours, one gap away on each side.
    ///
    /// **061: the endpoints move in x too.** 051 pinned the first point at `x = 0` and the last at
    /// `x = 1`, which is why "push the black point right" (Lightroom's own black point, and the left
    /// handle in RapidRAW/LightCraft) was impossible: every endpoint drag became a pure y move. The
    /// first point may now sit anywhere in `[0, next − gap]` and the last anywhere in
    /// `[prev + gap, 2]` — the same two rules as `RapidRAW src/components/adjustments/Curves.tsx:448-453`
    /// (`minX = index === 0 ? 0 : prevX + 0.01`, `maxX = index === last ? 255 : nextX - 0.01`) and
    /// `LightCraft crates/ui-egui/src/panels/edit/curve.rs:349-357` (`lo = if i == 0 { 0.0 }`,
    /// `hi = if i + 1 >= v.len() { 1.0 }`). What the moved endpoint *means* is the table's business:
    /// `CurveLUT.buildOne` holds a constant left of the first point (= a black clip) and right of the
    /// last (= a white clip), so `x` is where the clip begins, not a value the curve cannot leave.
    public static func clampX(_ x: Double, index: Int, in points: [CurvePoint]) -> Double {
        let maximum = CurvePoint.maximum
        guard points.indices.contains(index) else { return min(max(x, 0), maximum) }
        // Endpoints: one side is the edge of the table, the other is the neighbour.
        if index == 0 {
            let upper = points.count > 1 ? points[1].x - minimumGap : maximum
            // A neighbour closer than the gap leaves no legal x: stay where we are (the caller's
            // `next != current` guard then writes nothing), the same rule the interior takes below.
            guard upper >= 0 else { return points[0].x }
            return min(max(x, 0), upper)
        }
        if index == points.count - 1 {
            let lower = points[points.count - 2].x + minimumGap
            guard lower <= maximum else { return points[index].x }
            return min(max(x, lower), maximum)
        }
        let lower = points[index - 1].x + minimumGap
        let upper = points[index + 1].x - minimumGap
        // Neighbours closer than 2 × the gap leave no legal x: stay where we are rather than jumping
        // to one side (the caller's `next != current` guard then writes nothing at all).
        guard upper >= lower else { return points[index].x }
        return min(max(x, lower), upper)
    }

    /// The point a drag produces: ⇧'s axis lock, then the clamp, then the card's square.
    public static func movedPoint(_ target: CurvePoint, index: Int, in points: [CurvePoint],
                                  from origin: CurvePoint, lock: CurveAxisLock) -> CurvePoint {
        guard points.indices.contains(index) else { return target }
        let locked: CurvePoint
        switch lock {
        case .free: locked = target
        case .x: locked = CurvePoint(target.x, origin.y)
        case .y: locked = CurvePoint(origin.x, target.y)
        }
        return CurvePoint(clampX(locked.x, index: index, in: points), locked.y)
    }

    /// Insert a point at `(x, y)` in x order. The new x is clamped into the stretch it fell in, so a
    /// click near an endpoint cannot land *outside* the endpoints.
    ///
    /// Returns `nil` when there is no legal room — two endpoints closer than `2 × minimumGap`, which a
    /// document can only reach through a hand-written JSON blob.
    public static func insert(_ point: CurvePoint, into points: [CurvePoint]) -> (points: [CurvePoint], index: Int)? {
        guard points.count >= 2 else { return nil }
        let sorted = points.sorted { $0.x < $1.x }
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
        out.insert(CurvePoint(x, point.y), at: slot)
        return (out, slot)
    }

    /// Remove one point. `nil` = refused, and the only refusal is an endpoint: they are the black and
    /// the white point (061 — their x is where each clip begins), and a table needs two points to be a
    /// curve at all (`buildOne` answers the identity below that, i.e. the whole curve would vanish).
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

// MARK: - the point's coordinates, as the card prints them (069)

/// The one line the card shows while a point is under the hand: `输入 233 输出 +1.22`.
///
/// Two readings, both derived from the axis and from nothing else:
///
///   · **输入** — the point's `x` as the *histogram's* number. In the SDR half (`u ≤ whiteU`) that is
///     a display code 0–255, i.e. `255·u/whiteU`; **above white it is not a code at all**, so the
///     reading speaks EV there (`+1.50 EV`) rather than inventing a 300th code.
///   · **输出** — the point's `y` as stops relative to display white, always (`stops(v)`), because
///     the y axis is the full +0…+4 EV axis in every mode: 零光 has no stop count, hence `−∞`.
///
/// The view mode is deliberately absent from this type: the same point reads the same in all three
/// views (`testTheReadoutIsTheSameTextInAllThreeViews`), which is the property that makes zooming
/// safe — a read-out that changed when you zoomed would be a second coordinate system.
public enum CurvePointReadout {

    /// `输入 233 输出 +1.22` — one space, no colon, no brackets (the owner's own spelling).
    public static func text(for point: CurvePoint) -> String {
        "输入 \(input(point)) 输出 \(output(point))"
    }

    /// The x reading: a display code `0…255` while the point is in the SDR half, `+x.xx EV` above it
    /// (above white there is no code to print — the axis says stops there, so the reading does too).
    public static func input(_ point: CurvePoint) -> String {
        point.x <= CurvePoint.sdrBoundary
            ? "\(CurvePoint.code(point.x))"
            : ev(stops(point.x)) + " EV"
    }

    /// The y reading, by the same rule: a code on the SDR side, stops above white.
    public static func output(_ point: CurvePoint) -> String {
        point.y <= CurvePoint.sdrBoundary ? "\(CurvePoint.code(point.y))" : ev(stops(point.y))
    }

    /// `0…2` → stops above display white: the HDR half is `EV = (x − 1)·4` (069), the SDR half is the
    /// negative answer the axis gives (`log2` of the light `x/255` stands for).
    public static func stops(_ coordinate: Double) -> Double {
        coordinate <= CurvePoint.sdrBoundary
            ? log2(max(Double(CurvePoint.code(coordinate)) / 255, 1e-9))
            : (coordinate - 1) * 4
    }

    /// Two decimals, half **away from zero** (四舍五入), `+` on a positive value, U+2212 on a negative
    /// one, and no sign at all on zero.
    ///
    /// Formatted from the rounded hundredths as integers rather than through `String(format:)`: a printf
    /// conversion rounds to nearest-*even*, so `0.125` would print `0.12` where the owner asked for
    /// 四舍五入 (`0.125 → 0.13`, `testTheReadingRoundsHalfAwayFromZeroOnTheBoundary`).
    public static func ev(_ value: Double) -> String {
        guard value.isFinite else { return value < 0 ? "\u{2212}∞" : "∞" }
        let scaled = (value * 100).rounded()
        guard scaled != 0 else { return "0.00" }
        let cents = min(Int(abs(scaled)), 99_999_999)
        let body = "\(cents / 100)." + String(format: "%02d", cents % 100)
        return (scaled > 0 ? "+" : "\u{2212}") + body
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

    /// The curve's value at `x`, read **out of the table** (nearest sample: the table is 4096 entries
    /// over 0…1, so a sample is 2.4e-4 wide — finer than the pixel the click landed on).
    ///
    /// This is what a click in empty space gives its new point: `y` is the curve's value there, not 0.
    /// Both arguments and the answer are the card's `0…2` coordinate (069); the `/2` to the table's
    /// axis happens here and nowhere else.
    /// A point born at 0 would drop the curve to black at that x, which is a tone change the user did
    /// not ask for — the click was "put a handle here".
    public func value(atX x: Double) -> Double {
        let table = preview
        // The table runs over the engine's `0…1` axis, i.e. half the card's `0…2` coordinate.
        let u = min(max(x / 2, 0), 1)
        guard !table.isEmpty else { return u * 2 }
        let t = u * Double(table.count - 1)
        return 2 * Double(table[min(max(Int(t.rounded()), 0), table.count - 1)])
    }

    // MARK: writing

    private func write(_ next: [CurvePoint]) {
        session.applyEdit { model in
            model.curve[keyPath: channel.keyPath] = next
        }
    }

    /// One click in the empty area: insert, then commit — a click is a complete action.
    @discardableResult
    public func insert(atX x: Double) -> Int? {
        let current = points
        guard let inserted = CurveEditor.insert(CurvePoint(x, value(atX: x)), into: current) else {
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
    /// How far the value box is inset from the plot rect (064): one point radius plus 1 pt of air, so a
    /// point sitting on `u = 0/1` or `v = 0/1` draws a **whole** circle inside the frame. Derived from
    /// `pointRadius`, never typed as a number: raise the radius and the inset follows.
    public static var pointInset: CGFloat { pointRadius + 1 }
    /// A press has to travel this far to be a drag rather than a click.
    public static let dragThreshold: CGFloat = 2
    public static let tickLabelSize: CGFloat = 8
    public static let tabHeight: CGFloat = 18
    /// The region switch's own row (070) — 「区域」 + the two-state capsule, above the tabs.
    ///
    /// Same 18 pt as a tab row, so the card's height is a sum of two equal rows and one plot rather
    /// than a number that drifts: 18 + 6 + 18 + 6 + `plotHeight` + 6 + `footerHeight` = 269 pt at 274 pt
    /// of width. The row exists because the switch, sitting at the tail of the tab row, was read as a
    /// footer control ("在下方，复位旁边") and had its label truncated to 「HDR…」.
    public static let modeRowHeight: CGFloat = 18
    /// The footer row's height (069), and therefore the height of the coordinates line in **both**
    /// states: the row is the two buttons' height whether or not a point is under the hand, so
    /// 「行高不变、不许跳动」 is a constant here rather than a consequence of the text happening to be
    /// shorter than a button. `CurvePanelTests` measures the two states and compares them.
    public static let footerHeight: CGFloat = 15

    /// The plot rect inside a drawing area of `size` — the tick band is *inside* the area, so the
    /// Canvas and the hit test cannot disagree about where the plot is.
    public static func plotRect(in size: CGSize) -> CGRect {
        let height = max(size.height - tickBand, 1)
        return CGRect(x: plotInset, y: plotInset,
                      width: max(size.width - 2 * plotInset, 1),
                      height: max(height - plotInset, 1))
    }
}

// MARK: - the card's furniture

/// A 9 pt secondary-capsule button — the card's one button style (tabs' 区域 switch, 复位本通道,
/// 全部复位), so the three controls cannot drift apart.
public struct CurvePanelButton: View {
    public let title: String
    public let identifier: String
    public let action: () -> Void

    public init(_ title: String, identifier: String, action: @escaping () -> Void) {
        self.title = title
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
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
        .accessibilityIdentifier(identifier)
    }
}

/// The card's footer row: the point under the hand at the left, `复位本通道` / `全部复位` at the right.
///
/// 069 — the owner's 「和「复位本通道」在同一行，坐标在左侧，颜色字体参考直方图下方的 RGB 显示」:
///
///   · the face and colour are the histogram's own — `HistogramCardView.numberFont` (9.5 pt semibold
///     monospaced digits) and the secondary label colour. **Not a copy of the numbers**: the same
///     constant the histogram's `R 245 G 128 B 64` row paints with, asserted in source
///     (`testTheReadingUsesTheHistogramsOwnNumberFont`). If the histogram's row changes size, this
///     line changes with it, which is what "各界面一致" means as an invariant;
///   · the row's height is `footerHeight` in **both** states — no reading, or the longest reading —
///     so pressing a point never nudges the cards below (`testTheReadoutRowKeepsItsHeight`).
public struct CurvePanelFooter: View {

    /// `输入 233 输出 +1.22`, or `nil` when nothing is under the hand.
    public let reading: String?
    public let resetChannel: () -> Void
    public let resetAll: () -> Void

    public init(reading: String?, resetChannel: @escaping () -> Void,
                resetAll: @escaping () -> Void) {
        self.reading = reading
        self.resetChannel = resetChannel
        self.resetAll = resetAll
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(reading ?? "")
                .font(Font(HistogramCardView.numberFont))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: CurvePanelMetrics.footerHeight, alignment: .leading)
                .accessibilityIdentifier("curve.readout")
            Spacer(minLength: 6)
            CurvePanelButton("复位本通道", identifier: "curve.button.复位本通道", action: resetChannel)
            CurvePanelButton("全部复位", identifier: "curve.button.全部复位", action: resetAll)
        }
        .frame(height: CurvePanelMetrics.footerHeight)
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

    /// The plot's zoom (069). View state as well, and for the same reason: switching the region
    /// changes nothing in the document, the history or the sidecar.
    @State private var viewMode: CurveViewMode = .all

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
        // 069: the reading is a function of the point and of nothing else — not of the view, so
        // zooming cannot change what a point says (`testTheReadoutIsTheSameTextInAllThreeViews`).
        let reading = press.flatMap { p -> String? in
            guard let index = p.index, points.indices.contains(index) else { return nil }
            return CurvePointReadout.text(for: points[index])
        }
        let mode = viewMode
        return VStack(alignment: .leading, spacing: 6) {
            // 070 — the region switch is the card's **first row**, above the four channel tabs and a
            // whole plot away from the footer's 读数/复位 row. It used to sit at the end of the tab
            // row, where 274 pt of card left it squeezed against 复位本通道 below and truncating its
            // label to 「HDR…」; the owner read it as a footer control ("在下方，复位旁边"). One row of
            // its own is the fix that cannot be misread: 区域 行 → 通道 tabs → 绘图区 → 读数/复位.
            regionRow(mode: mode)
            channelTabs()
            plot(points: points, table: table, mode: mode)
            CurvePanelFooter(reading: reading,
                             resetChannel: { model.resetChannel() },
                             resetAll: { model.resetAll() })
        }
        // Greedy in width so the plot spans the card (274 pt at the default inspector, 244 at the
        // minimum) instead of collapsing to its ideal 117 pt; the height stays the fixed sum above.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: the region switch — its own row (070)

    /// 「区域」 + the two-state capsule, on a line of its own.
    ///
    /// The caption is what makes the row read as *the plot's* switch rather than as another button in
    /// the card's furniture; the capsule is right-aligned so the row's left half stays empty and the
    /// eye lands on it as a header control. The height is `modeRowHeight`, a constant, so the row
    /// cannot steal height from the plot or shift the footer's line.
    private func regionRow(mode: CurveViewMode) -> some View {
        HStack(spacing: 4) {
            Text("区域")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("curve.region.label")
            Spacer(minLength: 4)
            // 069 — the label is the **next** state: 「SDR 区域」 in the whole view, 「HDR 区域」 in the
            // SDR view (the owner's wording; pressing it there returns to the whole axis — see
            // `CurveViewMode`). `.fixedSize` is not cosmetic: squeezed into the tab row the label
            // truncated to 「HDR…」, which reads as a broken control.
            CurvePanelButton(mode.buttonTitle, identifier: "curve.view") {
                viewMode = viewMode.next
            }
            .fixedSize()
            .help("区域：\(mode.title)。SDR 视图把 x 0…1（显示码 0–255）铺满绘图区，右半区按住 ⇧ 可以回到全部视图看 +0…+4 EV")
            .accessibilityLabel("区域 \(mode.title)")
        }
        .frame(height: CurvePanelMetrics.modeRowHeight)
    }

    // MARK: the four channel tabs

    private func channelTabs() -> some View {
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

    private func plot(points: [CurvePoint], table: [Float], mode: CurveViewMode) -> some View {
        GeometryReader { proxy in
            let geometry = CurvePlotGeometry(plot: CurvePanelMetrics.plotRect(in: proxy.size),
                                             view: mode)
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
        // 064: the values (grid, frame, diagonal, curve, points) live in the inset value box; only the
        // tick labels still hang off the outer rect, at their old y.
        let box = geometry.valueBox
        let tint = channel.tint
        let span = geometry.xSpan

        // The plot's own field, so the grid reads as graph paper rather than as card background.
        context.fill(Path(roundedRect: plot, cornerRadius: 3),
                     with: .color(Color.primary.opacity(0.04)))

        // 4 × 4 grid: 5 lines each way, the frame included (a curve needs its axes) — on the value box.
        let grid = geometry.gridLines()
        var gridPath = Path()
        for x in grid.vertical {
            gridPath.move(to: CGPoint(x: x, y: box.minY))
            gridPath.addLine(to: CGPoint(x: x, y: box.maxY))
        }
        for y in grid.horizontal {
            gridPath.move(to: CGPoint(x: box.minX, y: y))
            gridPath.addLine(to: CGPoint(x: box.maxX, y: y))
        }
        context.stroke(gridPath, with: .color(Color.primary.opacity(0.10)), lineWidth: 0.5)

        // y = x, dashed: the identity, so "did I change anything" is answerable by eye. It is the
        // identity *within the view*, which is true in all three modes (069).
        var diagonal = Path()
        diagonal.move(to: CGPoint(x: box.minX, y: box.maxY))
        diagonal.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        context.stroke(diagonal, with: .color(Color.primary.opacity(0.22)),
                       style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))

        // 070 — the curve is drawn in the **card's** `0…2` coordinate, and the table is not.
        //
        // `CurveLUT.buildOne` samples the *engine's* axis: sample `i` sits at `u = i/(N−1)` and its
        // value is `v`, both `0…1`, and the engine's axis is half the card's (`CurvePoint.u == x/2`).
        // So a sample's card coordinate is **twice** its own number — `2·u` across, `2·v` up — and
        // that factor is the whole of this loop's arithmetic. Leaving it out (which is what the
        // `0…2` migration did) draws every curve at half scale into the lower-left quadrant: in the
        // all view the identity curve stops halfway and leaves the dashed identity diagonal it is
        // supposed to lie on, and in the SDR view the window (`xSpan` `0…1`) lets **every** sample
        // through and squeezes the whole curve — the +0…+4 EV half included — into the SDR box. The
        // region switch then repaints a picture of the wrong region, which is why 「切到 SDR 后曲线
        // 没有重新绘制」: the layer *was* repainted, with the whole table in an SDR window.
        //
        // 061: the ends are why this needs no special case. The table's first entries are all
        // `first.y` and its last all `last.y` (`CurveLUT.buildOne`), so a moved endpoint draws as a
        // **horizontal** segment into the corner — the black clip / white clip, as RapidRAW draws it
        // (`M 0 y L points[0].x y`, `src/components/adjustments/Curves.tsx:157-182`). A curve that
        // joined (0, 0) back to a raised first point would draw a ramp the pixels do not have.
        //
        // 069: only the samples inside the view are drawn. A zoomed view would otherwise clamp every
        // outside sample onto the frame and paint a line along the edge that is not in the table.
        if table.count >= 2 {
            var curve = Path()
            var started = false
            for i in 0..<table.count {
                let cardX = 2 * (Double(i) / Double(table.count - 1))
                guard span.contains(cardX) else { continue }
                let p = CGPoint(x: geometry.x(u: cardX), y: geometry.yRaw(v: 2 * Double(table[i])))
                if started { curve.addLine(to: p) } else { curve.move(to: p); started = true }
            }
            if started {
                // The window can cut the curve in y as well (an SDR point whose *output* is above
                // white): clip to the value box so the line **leaves** the frame instead of being
                // clamped onto its top edge, where it would read as a stretch of the table that does
                // not exist. In the all view nothing is outside the box, so this changes no pixel.
                var plotContext = context
                plotContext.clip(to: Path(box))
                plotContext.stroke(curve, with: .color(tint), lineWidth: 1.4)
            }
        }

        // Control points: 3 pt filled dots; the one under the hand gets a ring. 069: a point outside
        // the view is not drawn (it would sit on the frame), but it is still in the document and still
        // bends the curve through the samples above.
        for (i, p) in points.enumerated() where geometry.isVisible(p) {
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

        // The ticks, at the axis' own positions — for this view's half of the axis (069). The label
        // stays under the **outer** rect (its old y); only the little tick line reaches up to the
        // inset frame, so the 4 pt margin is bridged rather than left floating. The labels speak the
        // histogram's language: display codes on the SDR half (`0 / 127 / 255`), EV on the HDR half
        // (`+0 … +4`).
        let ticks = CurveAxisTicks.ticks(.standard, view: geometry.view)
        for (i, tick) in ticks.enumerated() {
            let x = geometry.x(u: tick.x)
            var line = Path()
            line.move(to: CGPoint(x: x, y: box.maxY))
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
        // 069: the target is the card's own `0…2` coordinate, and the geometry has already clamped it
        // into the box — a drag can land anywhere in `0…2` (no grid, no quantisation).
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
            insert(atX: geometry.u(atX: current.location.x))
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

    private func insert(atX x: Double) {
        guard let index = model.insert(atX: x) else { return }
        justInserted = (index, ProcessInfo.processInfo.systemUptime)
    }
}
