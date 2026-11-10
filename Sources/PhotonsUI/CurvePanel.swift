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
//   2. **The axis labels are positions on `HDRCurveAxis`, never numbers in this file.** The ticks
//      are 069's five display codes (`0 63 127 191 255`, sRGB-decoded) and — in the HDR view only,
//      user 2026-10-27 — the four stops `+1 … +4 EV`, and *where* each of them sits is the shaper's
//      answer: since 062 the axis is the histogram's own, so display white is the **middle** of the
//      card (the histogram's `sdrFraction`), the five codes fill that half, and +4 EV is the right
//      edge itself. Typing any of those
//      positions here would be a second copy of the shaper's answer, and the day the axis moves the
//      card would draw its ticks somewhere the curve does not bend. `CurveAxisTicks` *derives* every
//      one of them from the axis; the test asserts equality to 1e-9 and greps this file for the
//      literals.
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
// card's footer row (`输入 233 输出 +1.22`), and the plot can zoom into the SDR half of the axis or
// show the whole of it (`CurveViewMode`). `CurvePoint` is an integer grid cell (0…511 per axis) as of
// the same order, so "where did the point land" has exactly one answer in the document, in the
// read-out and in the key.
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
//
// 071 turns the switch into what the owner asked it to be, and the whole of it is **two spans and one
// transform**:
//
//   · **Two states, SDR and HDR — no 「全部」.** The button wears the state the card is *in* (`SDR` /
//     `HDR`; 「区域」 is gone), pressing it swaps. **SDR fills the value box with card `0…1` on both
//     axes — the SDR information only; HDR fills it with the whole axis, `0…2` — SDR *and* HDR.**
//     That sentence is the owner's own spec (「SDR 展示 SDR 信息，HDR 展示 SDR+HDR 信息」) and the
//     HDR state is a superset of the SDR one, not its other half.
//   · **One transform.** `CurvePlotGeometry.fraction(_:)` is the only `(value − lower) / (upper −
//     lower)` in this file; `x(u:)`, `y(v:)`, `yRaw(v:)`, `point(_:)`, the inverses, `isVisible`, the
//     grid, the ticks and the curve's samples all go through it. 069/070 had the picture and the dots
//     agreeing by inspection; 071 makes it a grep (`testEveryDrawingPathUsesTheOneTransform`).
//
// **2026-10-27 — the user's correction of 071's second bullet.** 071 read 「HDR 模式下只占据左下 1/2」
// as a complaint about *which span* the HDR state shows, and narrowed it to `1…2`. That was the wrong
// diagnosis: the picture was the **sampling** bug cured two paragraphs above (`u = i/(N−1)` — a table
// number, `0…1` — fed into an `x(u:)` that wants the card's `0…2`; `2·u` is what it was missing), and
// 070 already fixed it. Narrowing the span on top of that fix threw the SDR half *out* of the HDR
// state, which is the opposite of what that state means. Both halves of the mistake are undone in two
// places only: `CurveViewMode.span` (HDR = `0…maximum`) and the comment you are reading. Nothing about
// the transform, the coordinate, the read-out or the document moves — the fill comes from `2·u` /
// `2·v` in `draw`, whatever the span is.

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

// MARK: - the two view modes (069; two states since 071, whole axis since the 2026-10-27 correction)

/// Which part of the axis the plot is showing — **two states, `sdr ⇄ hdr`**: the SDR half, or the
/// whole card axis (SDR **and** HDR).
///
/// 069's 「精细调节」 wanted a magnified SDR half so a cell that is 0.5 pt wide at full width is 1 pt
/// wide. 069 shipped it as a window *onto* a full-axis view, with a button that named the state you
/// would get **next**; 071 replaced both halves of that idea, because the owner's report was two
/// complaints about the same thing:
///
///   · 「SDR 区域 HDR 区域去掉区域两个字，且交换一下，即显示 SDR 区域就显示 SDR 部分」 — the button now
///     wears the state you are **in** (`SDR` / `HDR`, no 「区域」), and pressing it swaps to the other.
///     There is no 「全部」 state and no third view: `allCases.count == 2`, `next` is an involution.
///   · 「SDR 展示 SDR 信息，HDR 展示 SDR+HDR 信息」 — the two spans, and the whole of what a state
///     means: `sdr` is `0…1` (the SDR information alone), `hdr` is `0…2` (**the SDR half plus the HDR
///     half**), each stretched across the value box exactly as the other is. The HDR state is a
///     *superset*, not the other half — 071 had it as `1…2` and the owner corrected that on
///     2026-10-27 (see the file header: the 「只占据左下 1/2」 he reported was the `2·u`/`2·v` sampling
///     bug, not the meaning of the view).
///
/// Crucially the *coordinate does not change*: a point's `x`/`y` stay `0…2` doubles, so the grid is
/// the same 4 × 4 in both states, the read-out is the same text, and the drag code needs no per-view
/// branch. `span` is the only thing the state contributes, and every pixel the card draws — curve,
/// grid, diagonal, dots, ticks, hit test — goes through `CurvePlotGeometry`, which reads it here
/// (071: the ratio is computed in exactly one place, `CurvePlotGeometry.fraction(_:)`).
///
/// **Display white (`x = 1`) is in both spans**, so the white point is visible and draggable in either
/// state: it sits on the box's **right edge** in SDR and in the **middle** in HDR, and that is the one
/// thing that tells the two pictures apart at a glance.
public enum CurveViewMode: String, CaseIterable, Identifiable, Sendable {
    /// The SDR half **only**: input **and** output below display white — `0…1` on each axis. The
    /// HDR half's points are not drawn and cannot be hit (they are still in the document and still
    /// bend the table).
    case sdr
    /// **The whole axis**: `0…2` on each axis — the SDR half (`0…1`) **plus** the HDR half (`1…2`,
    /// +0…+4 EV). Every legal point is drawn, because the span is the coordinate's own range.
    case hdr

    public var id: String { rawValue }

    /// The other state. Two states, so "next" and "other" are the same thing, and pressing twice is
    /// the identity (071 — the owner's 「按下就互切」).
    public var next: CurveViewMode { self == .sdr ? .hdr : .sdr }

    /// The part of the card's `0…2` coordinate this state fills the value box with.
    ///
    /// The owner's rule, verbatim: **「SDR 展示 SDR 信息，HDR 展示 SDR+HDR 信息」**. So `sdr` is
    /// `0…sdrBoundary` (display white is the right edge) and `hdr` is `0…maximum` — the whole axis,
    /// SDR half included, white in the middle. The HDR state is a **superset** of the SDR state; 071
    /// shipped `sdrBoundary…maximum` here and the owner corrected it on 2026-10-27 (the half-empty
    /// picture he reported was the `2·u`/`2·v` sampling bug, not the view).
    ///
    /// Both axes share it: input and output are the same axis, so a separate y-span would be a second
    /// copy of these numbers — and the first place the two could drift apart.
    public var span: ClosedRange<Double> {
        switch self {
        case .sdr: return 0...CurvePoint.sdrBoundary
        case .hdr: return 0...CurvePoint.maximum
        }
    }

    public var title: String {
        switch self {
        case .sdr: return "SDR 视图"
        case .hdr: return "HDR 视图"
        }
    }

    /// What the button says: **the state the card is in** (071), not the one pressing it would reach.
    ///
    /// The owner's sentence is the spec here — 「显示 SDR 区域就显示 SDR 部分」: a control that names
    /// its target reads as a label of the *other* state, and the two words 「区域」 only made it longer.
    /// `testTheViewButtonSaysSdrThenHdr` pins both strings and greps 「区域」 out of them.
    public var buttonTitle: String {
        switch self {
        case .sdr: return "SDR"
        case .hdr: return "HDR"
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
/// white), `1…2` is `+0…+4 EV` — and cancelled the stops: the ticks were **five**, the display codes
/// the owner asked for (`0 63 127 191 255`).
///
/// There is no "SDR / HDR" label on the axis either: `255` ends the code half and that edge *is* the
/// boundary (「这样也不需要 sdr/hdr 标示了」).
///
/// **2026-10-27 — the user asked for the stops back, in the HDR view only.** 069's 「stops 标记取消」
/// is not undone as a *rule*, it is superseded for one state: in `HDR` (the whole axis `0…2`) the
/// right half carries `+1 +2 +3 +4`, because that half is the EV half and it was the only unlabelled
/// stretch of the card (071's own note — 「left the whole-axis view looking unlabelled」 — was the
/// earlier sighting of the same complaint). In `SDR` (`0…1`) the card shows the display-code region
/// and **nothing is added**: the stops are not in that span, so a `+1` there would name a coordinate
/// the box does not show.
///
/// **Both states print the same five codes, at the same coordinates.** Every one of them is a
/// position on the axis the card draws, so it is true in either span: in `SDR` the `255` is the box's
/// right edge, in `HDR` (the whole axis) it is the box's **middle** — the same code at the same
/// coordinate, and the point where the codes end and the EV half begins.
///
/// A display code `c` is the *encoded* value `c/255`; the axis takes **linear** input, so the code is
/// decoded first and the position is `2·forward(displayCode(c))`, which is exactly `c/255` because
/// `encode` and `decode` are inverses — the test asserts that equality, so "the tick sits at its own
/// code" is a fact rather than a rounding coincidence. A stop `e` is `2·u(stops: e)`, i.e. the
/// shaper's own answer for "`e` EV above white": `+1 → 1.25`, `+2 → 1.5`, `+3 → 1.75`, `+4 → 2.0`
/// card coordinates. `+4` landing exactly on `2` is the axis' arithmetic (`u(16) = 1`), not a clamp
/// here.
public enum CurveAxisTicks {

    /// The five SDR codes the owner asked for — **the same list in both states**, at the same
    /// positions. 069's 「stops 标记取消」 still governs *this* list: it has no `+1 … +4` in it and the
    /// x positions come from the axis, never from a literal here. The stops live in `stops(_:)`.
    public static func codes(_ axis: HDRCurveAxis = .standard) -> [CurveAxisTick] {
        [0, 63, 127, 191, 255].map { code in
            CurveAxisTick(x: 2 * axis.forward(displayCode(Double(code))), label: "\(code)")
        }
    }

    /// The HDR half's four stops — `+1 +2 +3 +4` — at the axis' own `u(stops:)`.
    ///
    /// Added 2026-10-27 at the user's request (「HDR 视图下没有 +1 +2 +3 +4 的刻度」), which supersedes
    /// 069's 「stops 标记取消」 **for the HDR view only** — `ticks(for:)` never hands these to `SDR`.
    /// The label is the EV number and nothing else; the position is
    /// `2 · axis.u(stops: e)`, so the stops follow the shaper if `whiteU` / `xHI` ever move (062's
    /// 反证 axis puts white at 0.75 and every one of these four moves with it).
    public static func stops(_ axis: HDRCurveAxis = .standard) -> [CurveAxisTick] {
        (1...4).map { stop in
            CurveAxisTick(x: 2 * axis.u(stops: Double(stop)), label: "+\(stop)")
        }
    }

    /// What one **view** draws: the five codes, plus the four stops when the box shows the whole axis.
    ///
    /// This is the only place the two sets are put side by side, and the only place the view enters
    /// the ticking. `SDR` = `codes` exactly (069's five, untouched); `HDR` = `codes + stops`, i.e.
    /// ascending in x (the codes end at `x = 1`, the stops start at `x = 1.25`), which is what lets
    /// `layout(for:in:)` walk them left to right and drop only what does not fit.
    public static func ticks(for view: CurveViewMode,
                             axis: HDRCurveAxis = .standard) -> [CurveAxisTick] {
        switch view {
        case .sdr: return codes(axis)
        case .hdr: return codes(axis) + stops(axis)
        }
    }

    /// An 8-bit display code as scene-linear light — what the axis' `forward` expects.
    public static func displayCode(_ code: Double) -> Double {
        HDRCurveAxis.srgbDecode(code / 255)
    }

    // MARK: how a label is hung under the box (so 9 of them cannot overlap)

    /// Where a label's own box starts relative to its tick's x.
    public enum LabelAnchor: Equatable, Sendable {
        /// The label's left edge is on the tick (the leftmost tick, so it cannot hang off the card).
        case leading
        case centre
        /// The label's right edge is on the tick (the rightmost one, same reason).
        case trailing

        /// The `UnitPoint` `GraphicsContext.draw(_:at:anchor:)` wants.
        public var unitPoint: UnitPoint {
            switch self {
            case .leading: return .topLeading
            case .centre: return .top
            case .trailing: return .topTrailing
            }
        }

        /// The label box's left edge for a tick at `x` and a label `width` wide.
        public func leftEdge(of x: CGFloat, width: CGFloat) -> CGFloat {
            switch self {
            case .leading: return x
            case .centre: return x - width / 2
            case .trailing: return x - width
            }
        }
    }

    /// One tick as the card draws it: the line's x, the label's width, and how the label hangs.
    public struct Placement: Equatable, Sendable {
        public let tick: CurveAxisTick
        public let x: CGFloat
        public let labelWidth: CGFloat
        public let anchor: LabelAnchor
    }

    /// The width of a label in the type the card draws it with — **measured, not guessed**, with the
    /// same `tickLabelSize` the `Canvas` uses. This is what makes "the two sets do not overlap" a
    /// number the tests can hold instead of an impression.
    public static func labelWidth(_ label: String,
                                  font: NSFont? = nil) -> CGFloat {
        let face = font ?? NSFont.systemFont(ofSize: CurvePanelMetrics.tickLabelSize)
        return (label as NSString).size(withAttributes: [.font: face]).width
    }

    /// The ticks this view draws **and their labels' boxes**, left to right, with any label that
    /// would touch its neighbour dropped.
    ///
    /// The rule, in one sentence: a label is kept only if its box starts at least `gap` to the right
    /// of the last kept label's end. Because `ticks(for:)` is ascending in x, that is a single walk
    /// and the surviving order is the axis' own. Dropping is **left to right, keeping the earlier
    /// tick**, which is the priority the card wants: the five codes are the scale (069's, unchanged),
    /// the stops are the addition, so a narrow card loses `+3`/`+4` before it loses `191`.
    ///
    /// At the shipped 274 pt card nothing is dropped (measured: 32.7…33.3 pt between neighbours, widest
    /// label `255` at 15.33 pt — `CurveReadoutTests.testTheTicksAreFiveCodesInSdrAndNineMarksInHdr`);
    /// the rule exists so a card narrower than the inspector's minimum could never print two labels on
    /// top of one another.
    public static func layout(for view: CurveViewMode,
                              in geometry: CurvePlotGeometry,
                              axis: HDRCurveAxis = .standard,
                              font: NSFont? = nil,
                              gap: CGFloat = 2) -> [Placement] {
        let box = geometry.valueBox
        var out: [Placement] = []
        var lastMaxX = -CGFloat.greatestFiniteMagnitude
        for tick in ticks(for: view, axis: axis) {
            let x = geometry.x(u: tick.x)
            let width = labelWidth(tick.label, font: font)
            let half = width / 2
            // Hang a label inward at the box's ends, centred everywhere else — the rule the draw
            // code used to apply by index; by position it also survives a dropped tick.
            let anchor: LabelAnchor = x - half < box.minX ? .leading
                : (x + half > box.maxX ? .trailing : .centre)
            let left = anchor.leftEdge(of: x, width: width)
            guard left >= lastMaxX + gap else { continue }
            out.append(Placement(tick: tick, x: x, labelWidth: width, anchor: anchor))
            lastMaxX = left + width
        }
        return out
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
/// shows; `fraction(_:)` maps *that* span onto `0…1` and every other function here is built on it, so
/// `sdr` (`0…1`) is exactly twice as fine as the whole axis, and `hdr` is the whole axis (`0…2`) —
/// the same picture 069 drew at full width, now filling the box because `draw` feeds it card
/// coordinates (`2·u`), not table ones. `u`/`v` remain the only coordinate: a point's stored cell, its
/// position here and its read-out are the same number in both modes.
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

    /// Which part of the axis the box shows (071, corrected 2026-10-27): `sdr` is `0…1`, `hdr` is the
    /// whole axis `0…2`.
    public let view: CurveViewMode

    public init(plot: CGRect, inset: CGFloat = CurvePanelMetrics.pointInset,
                view: CurveViewMode = .sdr) {
        self.plot = plot
        self.inset = max(inset, 0)
        self.view = view
    }

    /// The box the values live in: `plot` inset by `inset` on every side. The grid, the frame and the
    /// y = x diagonal are all drawn on *this* box, so "the grid does not touch its frame" cannot happen.
    public var valueBox: CGRect { plot.insetBy(dx: inset, dy: inset) }

    /// The `0…2` span the box shows — **both axes**, since the curve's two axes are the same axis.
    ///
    /// 071: this is the whole of what a view state means. `sdr` is `0…1` and `hdr` is `0…2` (the whole
    /// axis: SDR **and** HDR), each stretched across the full width and the full height — so `sdr` is
    /// the clean 2× magnification one cell gets (`testEachViewFillsTheBoxWithItsOwnAxis`) and `hdr` is
    /// the coordinate's own range, not a half of it.
    public var span: ClosedRange<Double> { view.span }

    // MARK: the one transform (071)

    /// The view's span as `(origin, width)` — **the only place the span's arithmetic is written down.**
    ///
    /// 071 asked for "one transform" as a source fact, so the subtraction lives here and nowhere else:
    /// `grep -c "span.upperBound - span.lowerBound" Sources/PhotonsUI/CurvePanel.swift` is 1, and every
    /// pixel the card draws or hit-tests goes through the two functions below.
    private var spanOriginAndWidth: (origin: Double, width: Double) {
        let span = self.span
        return (span.lowerBound, span.upperBound - span.lowerBound)
    }

    /// A card coordinate (`0…2`, the same number as `CurvePoint.x` / `.y`) → **0…1** through this
    /// view's span. Unclamped and unflipped: it answers "how far into the span", which is the one
    /// arithmetic the card has.
    ///
    /// **This is the only ratio in the file** — `(… - origin) / width`, counted once by
    /// `testEveryDrawingPathUsesTheOneTransform`. Every pixel the card draws or hit-tests — the curve,
    /// the grid, the diagonal, the control points, the ticks, the drag target, the visibility test —
    /// reaches the box through `x(u:)` / `y(v:)` / `yRaw(v:)` / `point(_:)`, and all of them are this
    /// function plus the box. A second copy is how the curve and the dots came to disagree in 069/070.
    private func fraction(_ value: Double) -> Double {
        let (origin, width) = spanOriginAndWidth
        return ((value.isFinite ? value : origin) - origin) / width
    }

    /// The inverse: **0…1** → a card coordinate in this view's span. `fraction(_:)`'s opposite
    /// direction, built from the same `(origin, width)` pair, so the two cannot drift apart.
    private func coordinate(_ t: Double) -> Double {
        let (origin, width) = spanOriginAndWidth
        return origin + t * width
    }

    /// A coordinate in the view's span — **the card's own `CurvePoint.x`, `0…2`** (the parameter keeps
    /// its old label `u` for the call sites; the engine's `u` is half of it) → an x in the value box:
    /// `x(1) == width − inset` in the SDR view, `x(1) == the box's middle` in the HDR view, and
    /// `x(2) == width − inset` there. Clamped: a drag that leaves the card still lands on an edge.
    public func x(u: Double) -> CGFloat {
        let box = valueBox
        let span = self.span
        let finite = u.isFinite ? u : span.lowerBound
        let t = fraction(min(max(finite, span.lowerBound), span.upperBound))
        return box.minX + CGFloat(t) * max(box.width, 0)
    }

    /// The curve's value — **the card's `0…2` coordinate**, the same number as `CurvePoint.y` → a y in
    /// the value box (y grows *down*). Clamped into the view's span, which is what a **drag** wants: a
    /// pointer that leaves the box still lands on an edge.
    public func y(v: Double) -> CGFloat {
        let span = self.span
        let value = v.isFinite ? v : span.lowerBound
        return yRaw(v: min(max(value, span.lowerBound), span.upperBound))
    }

    /// The same mapping **without** the clamp, for the drawing.
    ///
    /// 070: the windowed view needs this. A sample whose *output* is outside the view — `v > 1` in the
    /// SDR box (a point lifted above white) — belongs outside the frame; clamped — which is right for
    /// a hand — every such sample would pile onto an edge and the plot would carry a horizontal line
    /// along it that is not in the table. (The HDR box is the whole `0…2` range, so nothing can leave
    /// it in y; only the SDR box clips.) Unclamped, the polyline leaves the frame and the clip in
    /// `draw` cuts it there.
    public func yRaw(v: Double) -> CGFloat {
        let box = valueBox
        return box.maxY - CGFloat(fraction(v)) * max(box.height, 0)
    }

    public func point(_ p: CurvePoint) -> CGPoint { CGPoint(x: x(u: p.x), y: y(v: p.y)) }

    /// Whether this point is inside the view — the drawing and the hit test both ask, so a point the
    /// card does not show cannot be dragged by pressing where it is not drawn (069).
    ///
    /// The test is on the point's own `x`/`y`, i.e. on the same numbers `fraction(_:)` uses, so
    /// "drawn" and "hittable" cannot disagree with "where it maps". `sdr` holds `0…1`, so the HDR
    /// half's points are outside it; `hdr` holds `0…2`, the coordinate's whole range, so every legal
    /// `CurvePoint` is in it. Display white `x = 1` is in both — the SDR box's right edge, the HDR
    /// box's middle.
    public func isVisible(_ p: CurvePoint) -> Bool {
        span.contains(p.x) && span.contains(p.y)
    }

    /// Inverse of `x(u:)`. Outside the value box it answers the view's own ends, never a number off
    /// the axis.
    public func u(atX x: CGFloat) -> Double {
        let box = valueBox
        guard box.width > 0 else { return span.lowerBound }
        return coordinate(Double(min(max((x - box.minX) / box.width, 0), 1)))
    }

    /// Inverse of `y(v:)`.
    public func v(atY y: CGFloat) -> Double {
        let box = valueBox
        guard box.height > 0 else { return span.lowerBound }
        return coordinate(Double(min(max((box.maxY - y) / box.height, 0), 1)))
    }

    /// Where each tick's line goes, in points — `x(u:)` of the axis-derived positions, for this view.
    public func tickPositions(_ ticks: [CurveAxisTick] = CurveAxisTicks.codes()) -> [CGFloat] {
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
    /// would grab a point living in the HDR half, which the SDR card does not show. (The HDR view is
    /// the whole axis, so there the filter lets every point through.)
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
    /// *view*, so the SDR view's grid is 4 × 4 over its 256 code cells and the HDR view's is 4 × 4
    /// over the whole `0…2` axis (069).
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

    /// The **last** segment's slope ceiling, in the card's own coordinate (派单 080 / 079 A5).
    ///
    /// It is `HDRCurve.tailSlopeLimit` — the number the kernel clamps the extrapolation above +4 EV
    /// with — and never a second copy of it: the drag limit and the render limit must be one number,
    /// or the card would let the user draw a slope the pixels silently cap (which is what [0, 1] on
    /// the kernel side did to every steeper end before this task).
    ///
    /// Card coordinates need no conversion here: the engine's `u = x/2` and `v = y/2` scale both axes
    /// by the same 2, so the last segment's slope **is** the number in the uniform.
    public static let tailSlopeLimit = HDRCurve.tailSlopeLimit

    /// The last segment's slope for a candidate last point: `Δy/Δx` in the card's coordinate, or
    /// `nil` when there is no last segment to speak of (one point, or no room between them).
    ///
    /// The card prints nothing from this yet; the tests read it, and it is the definition the clamp
    /// below is written against (one rule, one place, so "drag limit 2" and "tail slope 2" cannot
    /// drift apart).
    public static func tailSlope(atLast point: CurvePoint, in points: [CurvePoint]) -> Double? {
        guard points.count >= 2 else { return nil }
        let prev = points[points.count - 2]
        let span = point.x - prev.x
        guard span > 0 else { return nil }
        return (point.y - prev.y) / span
    }

    /// Hold the **tail segment** inside `±tailSlopeLimit` while one of its two endpoints is dragged.
    ///
    /// Only the last segment is limited, and only because it is the only segment whose slope leaves
    /// the table: everything to the left of the last point is interpolated inside `v ∈ [0, 1]` (where
    /// a steep segment is a legitimate midtone S, not an overshoot) and rule 4 never reads it.
    /// Both ends of the tail move on the plot, so both are clamped: dragging the white point up is
    /// capped at `prev.y + 2·Δx`, and dragging the point *before* it down is floored at
    /// `last.y − 2·Δx`. A descending tail (`slope < 0`) is left alone — the kernel already flattens it
    /// to a ceiling (`HDRCurve.tailSlopeFloor`), and taking the white point below its neighbour has
    /// been legal since 061.
    public static func clampTail(_ y: Double, x: Double, index: Int, in points: [CurvePoint]) -> Double {
        guard points.count >= 2 else { return y }
        let last = points.count - 1
        let prev = points[last - 1]
        if index == last {
            let span = x - prev.x
            guard span > 0 else { return y }
            return min(y, prev.y + tailSlopeLimit * span)
        }
        if index == last - 1 {
            let span = points[last].x - x
            guard span > 0 else { return y }
            return max(y, points[last].y - tailSlopeLimit * span)
        }
        return y
    }

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
    ///
    /// 080: the **x clamp comes first**, because the tail's slope ceiling is a function of `x` (the
    /// segment can be made steeper by pulling its right end left, not only by pulling `y` up) — so
    /// `clampTail` is applied to the x that will actually be written, not to the pointer's.
    public static func movedPoint(_ target: CurvePoint, index: Int, in points: [CurvePoint],
                                  from origin: CurvePoint, lock: CurveAxisLock) -> CurvePoint {
        guard points.indices.contains(index) else { return target }
        let locked: CurvePoint
        switch lock {
        case .free: locked = target
        case .x: locked = CurvePoint(target.x, origin.y)
        case .y: locked = CurvePoint(origin.x, target.y)
        }
        let x = clampX(locked.x, index: index, in: points)
        return CurvePoint(x, clampTail(locked.y, x: x, index: index, in: points))
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
///     a display code 0–255, i.e. `255·u/whiteU`; above white it is not a code at all, so the reading
///     speaks in **stops** there (`+1.22`) rather than inventing a 300th code.
///   · **输出** — the point's `y` as stops relative to display white, always (`stops(v)`), because
///     the y axis is the full +0…+4 EV axis in every mode: 零光 has no stop count, hence `−∞`.
///
/// **2026-10-27 — no `EV` suffix, in either half.** 069 wrote `+2.00 EV` on the input side above white
/// and the bare `+2.00` on the output side; the owner's report is that the word does not fit the row
/// (「放不下」), so both halves now spell a stop count the same way, `+1.22`, and the row has **one**
/// shape in every state: `输入 233 输出 +1.22`. Nothing else moved: two decimals, 四舍五入, U+2212 for
/// negatives, and the reading is still a function of the point alone.
///
/// The view mode is deliberately absent from this type: the same point reads the same in both views
/// (`testTheReadoutIsTheSameTextInBothViews`), which is the property that makes zooming
/// safe — a read-out that changed when you zoomed would be a second coordinate system.
public enum CurvePointReadout {

    /// `输入 233 输出 +1.22` — one space, no colon, no brackets (the owner's own spelling).
    public static func text(for point: CurvePoint) -> String {
        "输入 \(input(point)) 输出 \(output(point))"
    }

    /// The x reading: a display code `0…255` while the point is in the SDR half, the stop count
    /// above it (above white there is no code to print — the axis says stops there, so the reading
    /// does too). **Bare `+1.22`, no `EV`** (2026-10-27, same as `output`).
    public static func input(_ point: CurvePoint) -> String {
        point.x <= CurvePoint.sdrBoundary
            ? "\(CurvePoint.code(point.x))"
            : ev(stops(point.x))
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
    @State private var viewMode: CurveViewMode = .sdr

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
        // zooming cannot change what a point says (`testTheReadoutIsTheSameTextInBothViews`).
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
            // 071 — the label is the state the card is **in** (`SDR` / `HDR`, the owner's 「去掉区域
            // 两个字」), not the one pressing it reaches: 「显示 SDR 区域就显示 SDR 部分」. Two states,
            // so the press is its own inverse. `.fixedSize` is not cosmetic: squeezed into the tab row
            // the label truncated to 「HDR…」, which reads as a broken control.
            CurvePanelButton(mode.buttonTitle, identifier: "curve.view") {
                viewMode = viewMode.next
            }
            .fixedSize()
            .help("视图：\(mode.title)。SDR 只显示 x 0…1（显示码 0–255），HDR 显示整条 x 0…2"
                  + "（SDR 半区 0…1 加 HDR 半区 1…2 / +0…+4 EV），两个视图都把各自的轴铺满绘图区；"
                  + "再按一次切到另一个")
            .accessibilityLabel("区域 \(mode.buttonTitle)")
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
            .help("拖动控制点：末段（最后两点之间）的斜率上限 2.0 —— +4 EV 以上的高光尾巴"
                  + "可以画得比 1× 更陡，渲染与拖动用同一个上限；其它段不受这个上限约束"
                  + "（它们只在表内插值，不会外延）")
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
        let span = geometry.span

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
        // identity *within the view*, which is true in both modes (069/071).
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
        // that factor is the whole of this loop's arithmetic (071 keeps it untouched: it is the
        // table's unit, not a view's). Leaving it out — which is what the `0…2` migration did — draws
        // every curve at half scale into the lower-left quadrant whatever the span is, and that
        // **sampling** bug is what the owner saw as 「HDR 模式下只占据左下 1/2」. 071 read that picture
        // as the meaning of the HDR state and narrowed its span to `1…2`; the owner corrected that on
        // 2026-10-27 — the state is the whole axis, and the fill is this `2·u` / `2·v`, nothing else.
        //
        // 061: the ends are why this needs no special case. The table's first entries are all
        // `first.y` and its last all `last.y` (`CurveLUT.buildOne`), so a moved endpoint draws as a
        // **horizontal** segment into the corner — the black clip / white clip, as RapidRAW draws it
        // (`M 0 y L points[0].x y`, `src/components/adjustments/Curves.tsx:157-182`). A curve that
        // joined (0, 0) back to a raised first point would draw a ramp the pixels do not have.
        //
        // 069/071: only the samples inside the view are drawn, and the two calls below are the *same*
        // `x(u:)`/`yRaw(v:)` the dots and the hit test use — the curve cannot be drawn in a different
        // place from the points that shape it. (071 asks for that as a grep: one ratio in the file.)
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
                // The SDR view can cut the curve in y (a point whose *output* is lifted above white);
                // clip to the value box so the line **leaves** the frame instead of being clamped onto
                // an edge, where it would read as a stretch of the table that does not exist. (The HDR
                // view is the whole `0…2` range, so there is nothing left to cut there.)
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

        // The ticks, at the axis' own positions — 069's five display codes in **both** views, plus the
        // four stops `+1 … +4` in the **HDR** view only (user 2026-10-27: 「HDR 视图下没有 +1 +2 +3 +4
        // 的刻度」, which supersedes 069's 「stops 标记取消」 for the whole-axis state). They are
        // positions on the axis being drawn: the `255` is the SDR view's right edge and the HDR view's
        // middle, and the stops are the EV half's only numbers. `layout(for:in:)` is what decides how
        // many the box has room for — 9 at this card's width, fewer if it ever gets narrower, never
        // two labels on top of one another.
        // The label stays under the **outer** rect (its old y); only the
        // little tick line reaches up to the inset frame, so the 4 pt margin is bridged rather than
        // left floating.
        for placement in CurveAxisTicks.layout(for: geometry.view, in: geometry) {
            let x = placement.x
            var line = Path()
            line.move(to: CGPoint(x: x, y: box.maxY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY + 3))
            context.stroke(line, with: .color(Color.primary.opacity(0.35)), lineWidth: 0.7)

            context.draw(Text(placement.tick.label)
                            .font(.system(size: CurvePanelMetrics.tickLabelSize))
                            .foregroundStyle(Color.secondary),
                         at: CGPoint(x: x, y: plot.maxY + 3), anchor: placement.anchor.unitPoint)
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
