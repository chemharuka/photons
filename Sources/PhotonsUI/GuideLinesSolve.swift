import AppKit
import CoreGraphics
import PhotonsCore

// MARK: - 337 引导线: two drawn lines → the keystone that makes them parallel
//
// 334 put 画线拉直 (`level`) in the 校正 card. That one *turns* the picture: a stroke that is
// supposed to be level is measured, and `straighten` is set so that it is. This is the other
// repair the user asked for in the same sentence (「校正包括旋转、透视、以及新做的引导线UI」):
// the photograph is **converging** — two lines that are parallel in the world lean towards a
// vanishing point — and the fix is a keystone, not a rotation.
//
// The reference tools (Lightroom's Upright Guided, darktable's ashift, Photoshop's Perspective
// Warp) all ask for the same two things: draw along an edge that *should* be vertical (or
// horizontal), and search the transform's parameter for the value that makes **the drawn lines
// parallel**, never for the angle of the stroke itself. That last distinction is the whole
// arithmetic of this file, and it is why a guide line is not a level:
//
//   · `level` reads a direction off the screen, then cancels it (`s = −θ`);
//   · a guide line fixes **two material points** and asks which `(v, h)` places them so that the
//     segment's *image* is vertical (or horizontal). It is a search over the parameter, and the
//     answer depends on where the line sits in the frame — a keystone is not a translation of
//     angles, it is a projective map.
//
// ## The residual (§348 §2b)
//
// Each line gives one **deviation** — the angle its mapped direction makes with the axis it was
// drawn along, folded **relative to that axis** so a 竖 group never straddles the ±90 cut:
//
//     φᵢ = wrap(θ(P(v,h)·R(s) · lineᵢ) − targetᵢ)      target 竖 90° / 横 0°
//
// and the residual the fit minimises is **between lines**, not between a line and its axis: every
// pair inside one direction group contributes
//
//     rᵢⱼ = wrap(φᵢ − φⱼ)        Σ rᵢⱼ²  minimal  ⇔  the group is parallel
//
// That is the 348 correction. 337 measured each line against its axis, so two lines 3.5° apart
// (+2.0 and −1.5, the user's own example) had two residuals no single keystone can zero — the
// minimum still left ~1.7° — and the card said 「这些线互相矛盾」. The user was drawing
// 「these two should be parallel」; being *upright* is a rotation, not a keystone, and the two
// jobs are now separate:
//
//   1. `(v,h)` make the group parallel  → acceptance is `所有 rᵢⱼ ≤ 0.05°` **and** σmin(J) > 1e−6;
//   2. one turn `δ = −mean φᵢ` puts the group's common direction back on the axis, and is written
//      into `straighten` (±45°; beyond that `rotationOutOfRange`, and only the turn is skipped).
//
// A line whose group has no partner yet contributes no pair, so it constrains no knob — it still
// informs the turn (that is all a single stroke can say: 「让我变正」).
//
// ## The solve (§2b.3)
//
// `Σ rᵢⱼ²` over every pair, by Gauss–Newton with Levenberg damping — ≤ 2 unknowns, ≤ 40
// iterations, every step clamped to the slider's range and to `stepLimit` so one iteration can
// never jump the whole travel. Only the axes the pairs actually constrain are solved for (`v` for
// vertical groups, `h` for horizontal ones): a picture with only vertical guide lines says nothing
// about the horizontal knob, and pretending otherwise is exactly the rank-deficient fit that would
// read as `degenerate`.
//
// The starting point is the document's current `(v,h)` **plus one coarse sweep** (`seedStep`, 10
// slider units) whose best sample seeds the damped iteration. The sweep is not belt-and-braces: a
// pair whose intersection lies far outside the frame has an almost flat objective at `v = 0`
// (measured on a +5°/0° pair: 5.000° at v = 0, 4.93° at v = 86, and the true minimum 0.021° at
// v = 43.5 — so Gauss–Newton started at 0 has a zero Jacobian there and either stops at once or
// walks the wrong way). With the sweep the same pair is solved to 1e−5 in two iterations, and the
// three families §3.2 asks for land on v = 30.30 / 60.57 / 95.09.
//
// ## Why the endpoints go back to the source first (§2.4)
//
// The stroke is drawn on the screen, where the document's *current* keystone is already applied.
// The material line is what the photograph holds, so the endpoints are first walked back through
// the current composite inverse (`P_current⁻¹ · R⁻¹`, plus the crop window and the camera — that
// is `LoupeMapping.sourcePoint`). Solve in screen coordinates instead and the current keystone is
// applied twice: measured on the acceptance fixture with `perspectiveVertical = 25`, the screen
// answer leaves 2.9° of convergence behind (§4 gate ①).

// MARK: - which axis a line is meant to be

/// The axis a drawn guide line is taken to mean. Same rule as 328's fold — `|θ| ≤ 45°` is 「横」,
/// anything else is 「竖」 — because the user draws and the tool decides; there is no mode.
public enum GuideLineAxis: String, Sendable, Equatable, Hashable, CaseIterable {
    case vertical
    case horizontal

    /// The document field this axis' solve writes.
    public var title: String {
        switch self {
        case .vertical: return "垂直透视"
        case .horizontal: return "水平透视"
        }
    }

    /// The direction the line has to end up at, in degrees (y-down): ±90 for 竖, 0 for 横.
    public var targetDegrees: Double {
        switch self {
        case .vertical: return 90
        case .horizontal: return 0
        }
    }
}

// MARK: - one drawn line

/// One 引导线 gesture: the two ends in **source pixels** — what the photograph holds — plus how the
/// stroke was read (its screen angle at the moment it was drawn, which decides the axis).
///
/// **354 — the endpoints are the only geometry stored.** Before this task the line also cached the
/// two ends in *view* points at the moment it was drawn, and the overlay stroked those; a zoom, a
/// pan, a fit, a keystone or a straighten then left the line where the old camera had put it
/// (measured: 4220.3 px at 400 %, 144.7 px at `s = 9°`, 31.9 px at `P = +60` — see
/// `docs/reports/354-guide-display.md` §1). View points are a *projection* of these numbers, never a
/// second copy of them: the one entry is `GuideLineProjection.screenPoint`.
public struct GuideLine: Equatable, Sendable {
    /// The two ends in **source pixels** (`Double` precision) of the oriented source frame.
    public var a: CGPoint
    public var b: CGPoint
    /// The stroke's angle **on the screen when it was drawn**, folded into `(−90°, +90°]` — the
    /// number the axis decision uses. A fact about the hand, not about where the line is now.
    public var viewAngle: Double
    /// Which axis the fold put it on.
    public var axis: GuideLineAxis
    /// The stroke's length **on the screen when it was drawn**, in view points — 328's 20 pt misfire
    /// threshold is a question about the gesture, so it is measured once, where the gesture is.
    public var viewLength: Double

    public init(a: CGPoint, b: CGPoint,
                viewAngle: Double, axis: GuideLineAxis,
                viewLength: Double = 0) {
        self.a = a
        self.b = b
        self.viewAngle = viewAngle
        self.axis = axis
        self.viewLength = viewLength
    }

    /// The pre-354 initializer, kept so a caller that has both spellings in hand does not have to
    /// choose: the **source** pair is what is stored, and the view pair only measures the gesture.
    public init(start: CGPoint, end: CGPoint,
                sourceStart: CGPoint, sourceEnd: CGPoint,
                viewAngle: Double, axis: GuideLineAxis) {
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        self.init(a: sourceStart, b: sourceEnd, viewAngle: viewAngle, axis: axis,
                  viewLength: (dx * dx + dy * dy).squareRoot())
    }

    /// The same two ends, under the names 337/348 gave them («the material points»).
    public var sourceStart: CGPoint { a }
    public var sourceEnd: CGPoint { b }

    /// The stroke's length as drawn, in view points — 20 pt is the misfire threshold (§4.6, 328's
    /// number).
    public var length: Double { viewLength }

    /// The line's angle in **source** pixels, folded — the angle the photograph holds, which is the
    /// one 「两条线几乎平行」 is asked about (a screen angle would answer for the keystone that is
    /// already on, not for the lines).
    public var sourceAngle: Double {
        GuideLinesSolve.fold(GuideLinesSolve.degrees(dx: Double(sourceEnd.x - sourceStart.x),
                                                     dy: Double(sourceEnd.y - sourceStart.y)))
    }
}

// MARK: - why a solve did not take

/// §2b.2's three reasons, plus the three the *gesture* can have before there is anything to solve,
/// plus 348's turn. All of them keep the document where it was — except `rotationOutOfRange`, which
/// keeps the **keystone** and drops only the turn (the two steps are independent by construction).
public enum GuideLineFailure: String, Sendable, Equatable, CaseIterable {
    /// Fewer than two lines: nothing to compare.
    case notEnoughLines
    /// A fifth line (or a third on one axis): §2b.1's 2 + 2 ceiling.
    case tooManyLines
    /// The lines are parallel already (< 0.2° apart) — kept as public API for callers that name it,
    /// but **367 no longer produces it from `fit`**: a near-parallel pair is exactly what the keystone
    /// can solve to a small value (0.02° → v = 0.41, 0.1° → v = 1.75, 0° → v = 0.00), and the user
    /// asked for 「角度很小也直接走校正，也不需要提示」.
    case nearParallel
    /// The lines disagree: no `(v, h)` brings every pair inside 0.05°.
    case inconsistent
    /// 367 — two same-axis lines whose residuals the fit could not move at all: the arithmetic has no
    /// answer (e.g. a pair 30°/34° off the axis), so the line is **kept** and the card says why
    /// instead of withdrawing it.
    case linesTooFarFromAxis
    /// The fit is rank-deficient: the new line repeats what the others already said.
    case degenerate
    /// The answer exists but is outside the slider's own `PerspectiveMap.limit` (347: ±200).
    case outOfRange
    /// 348 — the lines *can* be made parallel, but putting the group back on its axis would need a
    /// turn the straighten dial cannot hold (|s + δ| > 45°). The keystone is written; the turn is
    /// skipped and said so. This is the only member that is not a refusal.
    case rotationOutOfRange

    /// What the card says, without a measurement (the short form).
    public var message: String { message(measuredWorstPairwise: nil) }

    /// What the card says. Short enough for one row (the row is 22 pt high), and — for the two
    /// failures whose *size* is the whole point — with the number the fit measured: 348 §2.4 asked
    /// for 「说人话，并给出实测残差」 because 「互相矛盾」 alone leaves the user guessing how far.
    ///
    /// `measuredWorstPairwise` is the worst pair angle in degrees for `inconsistent`, and the turn
    /// the lines asked for in degrees for `rotationOutOfRange`.
    public func message(measuredWorstPairwise measured: Double?) -> String {
        switch self {
        case .notEnoughLines: return "再画一条（需 2 条）"
        case .tooManyLines: return "每个方向最多 2 条"
        case .nearParallel: return "两条线几乎平行，没有信息"
        case .linesTooFarFromAxis:
            guard let measured, measured.isFinite else { return "这两条线偏轴太多，校正不了（先记下）" }
            return String(format: "这两条线偏轴 %.1f°，校正不了（先记下）", measured)
        case .inconsistent:
            guard let measured, measured.isFinite else { return "这些线互相矛盾，未应用" }
            return String(format: "这些线互相矛盾（差 %.1f°），未应用", measured)
        case .degenerate: return "新线与已有线重复，未应用"
        case .outOfRange:
            let limit = Int(PerspectiveMap.limit)
            guard let measured, measured.isFinite else { return "需要的透视超出 ±\(limit)" }
            return String(format: "线间还差 %.1f°", measured) + "，透视超出 ±\(limit)"
        case .rotationOutOfRange: return "摆正超 ±45°（透视已应用）"
        }
    }
}

// MARK: - the answer

/// What one fit produced, with every number the readout and the acceptance print: the parameters it
/// wants the document to hold, the turn that puts the group upright, the residuals **after** them,
/// and how the iterations went.
public struct GuideLineSolution: Equatable, Sendable {
    /// The document's `perspectiveVertical` the fit asks for.
    public var vertical: Double
    /// The document's `perspectiveHorizontal` the fit asks for.
    public var horizontal: Double
    /// The document's `straighten` the fit asks for — 348's second step. Equal to the angle the
    /// document already had when `rotationFailure` is set (the turn is what got skipped).
    public var straighten: Double
    /// The turn the lines asked for, before the ±45° check — what 「摆正需 …°」 prints.
    public var straightenRequested: Double
    /// `.rotationOutOfRange` when the turn is beyond the dial, `nil` when it was applied.
    public var rotationFailure: GuideLineFailure?
    /// Every line's deviation from its group's **common** direction, in degrees, in the order the
    /// lines were given — 0 ⇔ the group is parallel. (The axis itself is not in this number: that is
    /// the turn's job, above.)
    public var residuals: [Double]
    /// Every within-group pair's angle, in degrees — the numbers the acceptance is stated on.
    public var pairwiseResiduals: [Double]
    /// Axes the fit actually solved for (the ones with a pair on them).
    public var axes: [GuideLineAxis]
    public var iterations: Int
    /// Smallest singular value of the Jacobian at the answer — §2b.2's rank test.
    public var smallestSingularValue: Double
    public var lineCount: Int
    /// The angle the document's `straighten` had before the fit — so `straightenDelta` is defined.
    public var previousStraighten: Double

    public init(vertical: Double, horizontal: Double,
                straighten: Double = 0, straightenRequested: Double = 0,
                rotationFailure: GuideLineFailure? = nil,
                residuals: [Double], pairwiseResiduals: [Double] = [],
                axes: [GuideLineAxis], iterations: Int, smallestSingularValue: Double,
                lineCount: Int, previousStraighten: Double = 0) {
        self.vertical = vertical
        self.horizontal = horizontal
        self.straighten = straighten
        self.straightenRequested = straightenRequested
        self.rotationFailure = rotationFailure
        self.residuals = residuals
        self.pairwiseResiduals = pairwiseResiduals
        self.axes = axes
        self.iterations = iterations
        self.smallestSingularValue = smallestSingularValue
        self.lineCount = lineCount
        self.previousStraighten = previousStraighten
    }

    /// The turn this fit applies, signed — 0 when the group was already upright.
    public var straightenDelta: Double { straighten - previousStraighten }

    /// The worst **pair** angle — 「所有两两夹角 ≤ 0.05°」 is measured on this, and it is the number
    /// the card prints as 「残差」.
    public var worstResidual: Double { pairwiseResiduals.map(abs).max() ?? .infinity }

    /// The worst deviation from the common direction — how far the worst single line would still be
    /// off if the turn were applied. Half of `worstResidual` for a pair, never more for a group.
    public var worstLineDeviation: Double { residuals.map(abs).max() ?? .infinity }

    /// The card's readout: what the fit wrote and how flat it left the lines. Both knobs are named
    /// when both were solved — the user asked for 「滑杆读数跟着变」, and a row that printed only one
    /// of two moved sliders would be a readout that hides half the write.
    public var summary: String {
        let values: String
        switch (axes.contains(.vertical), axes.contains(.horizontal)) {
        case (true, true): values = String(format: "垂直透视 %+.1f / 水平透视 %+.1f", vertical, horizontal)
        case (true, false): values = String(format: "垂直透视 %+.1f", vertical)
        default: values = String(format: "水平透视 %+.1f", horizontal)
        }
        var text = String(format: "%@ · 残差 %.2f°", values, worstResidual)
        if rotationFailure == nil, abs(straightenDelta) >= 0.05 {
            text += String(format: " · 摆正 %+.1f°", straightenDelta)
        }
        return text
    }
}

/// A fit's outcome: either a solution or the reason there is none. Never both.
public struct GuideLineFit: Equatable, Sendable {
    public var solution: GuideLineSolution?
    public var failure: GuideLineFailure?
    /// The worst pair angle the fit measured — present on a failure too, so the card can say how far
    /// apart the lines are (§348 ③) instead of only that they disagree.
    public var measuredWorstPairwise: Double?

    public init(solution: GuideLineSolution? = nil, failure: GuideLineFailure? = nil,
                measuredWorstPairwise: Double? = nil) {
        self.solution = solution
        self.failure = failure
        self.measuredWorstPairwise = measuredWorstPairwise
    }

    public static func solved(_ solution: GuideLineSolution) -> GuideLineFit {
        GuideLineFit(solution: solution, measuredWorstPairwise: solution.worstResidual)
    }

    public static func rejected(_ failure: GuideLineFailure,
                               measured: Double? = nil) -> GuideLineFit {
        GuideLineFit(failure: failure, measuredWorstPairwise: measured)
    }
}

// MARK: - 367: the pair's verdict, and the 2 × 2 assignment search

/// What **two** lines mean — the rule of 2026-11-10 (see the task's §0):
///
///   · same axis → always try to correct, however small the angle (0.02°, even 0°, are corrections
///     the fit answers with a small value); the card shows the ordinary readout, not a warning;
///   · one vertical + one horizontal → `insufficient`: **accept, write nothing**, no red, no error.
///     Two lines can only name one direction each; that is information, not a contradiction;
///   · same axis but the arithmetic cannot move the residual at all → `unsolvable`: keep the line and
///     say 「偏轴 X°，校正不了」. The line is not withdrawn.
///   · anything else (the travel's end, a rank-deficient pair) is reported as the fit reported it.
public enum GuideLinePairOutcome: Equatable, Sendable {
    case corrected(GuideLineSolution)
    case insufficient
    case unsolvable(measured: Double)
    case rejected(GuideLineFailure, measured: Double?)
}

/// What a 3/4-line set resolved to, including the axis assignment the search picked.
public struct GuideLineGroupFit: Equatable, Sendable {
    /// The lines with the chosen axes written back (for an offending line: the ones that remain).
    public var lines: [GuideLine]
    public var solution: GuideLineSolution?
    public var failure: GuideLineFailure?
    public var measuredWorstPairwise: Double?
    /// The index, in the caller's array, of the line whose removal made the rest solvable.
    public var offendingIndex: Int?

    public init(lines: [GuideLine], solution: GuideLineSolution? = nil,
                failure: GuideLineFailure? = nil, measuredWorstPairwise: Double? = nil,
                offendingIndex: Int? = nil) {
        self.lines = lines
        self.solution = solution
        self.failure = failure
        self.measuredWorstPairwise = measuredWorstPairwise
        self.offendingIndex = offendingIndex
    }
}

// MARK: - the arithmetic

/// The pure half of 引导线: source points and a parameter in, one residual (and one `(v, h)`) out.
/// Nothing here writes a document, touches a view or reads a controller — the same rule
/// `CropDrawStraighten` follows, so the whole gesture is measurable without a window.
public enum GuideLinesSolve {

    // MARK: constants (§2, §2b)

    /// A stroke shorter than this is a misfire, in view points (328's number, the same unit the hit
    /// radii use).
    public static let minimumLengthPoints: Double = 20
    /// §2.4 — the fit is accepted when every **pair** is this close to parallel.
    public static let toleranceDegrees: Double = 0.05
    /// §2.6 — two lines this close to each other say nothing about a vanishing point.
    public static let nearParallelDegrees: Double = 0.2
    /// §2b.1 — at most four lines, at most two per axis.
    public static let maxLines = 4
    public static let maxLinesPerAxis = 2
    /// §2b.3 — Gauss–Newton's iteration cap and step cap (slider units).
    public static let maxIterations = 40
    public static let stepLimit: Double = 25
    /// The finite-difference step for the Jacobian, in slider units.
    public static let jacobianStep: Double = 0.5
    /// §2b.3 — the coarse sweep that seeds the iteration: one sample per this many slider units.
    public static let seedStep: Double = 10
    /// §2b.3 — the iteration drives to this and the *acceptance* is judged on `toleranceDegrees`.
    /// Two different numbers on purpose: 「解到多准」 is the solver's business, 「接不接受」 is the
    /// user's, and a 1° tolerance (the reverse gate) must not also make a sloppy solve look fine.
    public static let solveTargetDegrees: Double = 1e-4
    /// §2b.2 — the rank threshold on the Jacobian's smallest singular value.
    public static let minimumSingularValue: Double = 1e-6
    /// §2.3 — two groups further apart than this are 「混合方向」, and only the bigger one is solved.
    public static let mixedDirectionDegrees: Double = 30
    /// §2.2 — the stroke stays at full opacity for 0.3 s, then fades (328's flash).
    public static let holdSeconds: Double = 0.3
    public static let fadeSeconds: Double = 0.15
    /// 348 §2.2 — the turn is the straighten dial's own range; beyond it there is no field to write.
    public static var straightenLimit: Double { GeometryGroup.straightenLimit }

    // MARK: angles (328's conventions, unchanged)

    /// `atan2` in degrees, y down.
    public static func degrees(dx: Double, dy: Double) -> Double {
        atan2(dy, dx) * 180 / .pi
    }

    /// A line has no direction: fold into `(−90°, +90°]`.
    public static func fold(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var value = degrees.truncatingRemainder(dividingBy: 180)
        if value > 90 { value -= 180 }
        if value <= -90 { value += 180 }
        return value
    }

    /// §2.3 — `|θ| ≤ 45°` is 「这条线本该是横的」, anything else is 「本该是竖的」. The same boundary
    /// `CropDrawStraighten.axis(forFoldedAngle:)` uses: it is the diagonal, the only angle equally
    /// far from both axes.
    public static func axis(forFoldedAngle degrees: Double) -> GuideLineAxis {
        abs(degrees) <= CropDrawStraighten.axisBoundaryDegrees ? .horizontal : .vertical
    }

    // MARK: the map one point is measured through

    /// A **source** pixel through the document's own `P(v, h)` and then its rotation `R`, in pixels.
    ///
    /// The order and the pivot are `CropMath.perspectiveCanvas`'s (P on the photograph's normalized
    /// domain, then a turn about the photograph's centre), because that is the walk the renderer
    /// takes; the crop window and the camera after it are similarities, so they cannot change
    /// whether two lines are parallel — which is why the acceptance can measure in this space and
    /// mean the screen.
    public static func mapped(_ point: CGPoint, source: ImageSize,
                              vertical: Double, horizontal: Double,
                              straightenDegrees: Double) -> CGPoint {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        let map = PerspectiveMap(vertical: vertical, horizontal: horizontal)
        let warped = map.forward(x: Double(point.x) / w, y: Double(point.y) / h)
        let px = warped.x * w - w / 2, py = warped.y * h - h / 2
        let radians = (straightenDegrees.isFinite ? straightenDegrees : 0) * .pi / 180
        let c = cos(radians), s = sin(radians)
        return CGPoint(x: px * c - py * s + w / 2, y: px * s + py * c + h / 2)
    }

    /// The direction a line's **image** has at `(v, h, s)`, folded — the one number both the
    /// deviation and the pair angle are built from.
    public static func mappedAngle(of line: GuideLine, source: ImageSize,
                                   vertical: Double, horizontal: Double,
                                   straightenDegrees: Double) -> Double {
        let a = mapped(line.sourceStart, source: source, vertical: vertical,
                       horizontal: horizontal, straightenDegrees: straightenDegrees)
        let b = mapped(line.sourceEnd, source: source, vertical: vertical,
                       horizontal: horizontal, straightenDegrees: straightenDegrees)
        return fold(degrees(dx: Double(b.x - a.x), dy: Double(b.y - a.y)))
    }

    /// §2b — one line's **deviation** from the axis it was drawn along, in degrees. Folded relative
    /// to the target, so a 竖 group's −88° and +88.5° are −2° and +1.5° and not 176° apart.
    public static func deviation(of line: GuideLine, source: ImageSize,
                                 vertical: Double, horizontal: Double,
                                 straightenDegrees: Double) -> Double {
        fold(mappedAngle(of: line, source: source, vertical: vertical, horizontal: horizontal,
                         straightenDegrees: straightenDegrees) - line.axis.targetDegrees)
    }

    /// The name 337 gave the same number (「线到轴的残差」). Kept because it is the readout's word;
    /// since 348 it is no longer what the fit minimises or accepts — `pairs(of:)` is.
    public static func residual(of line: GuideLine, source: ImageSize,
                                vertical: Double, horizontal: Double,
                                straightenDegrees: Double) -> Double {
        deviation(of: line, source: source, vertical: vertical, horizontal: horizontal,
                  straightenDegrees: straightenDegrees)
    }

    // MARK: grouping (§2.3, §348)

    /// The lines of one direction, in the card's order (vertical first), each group carrying the
    /// indices it holds **in the caller's array** — so a residual can be reported back in the order
    /// the lines were drawn.
    public static func groups(of lines: [GuideLine]) -> [(axis: GuideLineAxis, indices: [Int])] {
        GuideLineAxis.allCases.compactMap { axis in
            let indices = lines.indices.filter { lines[$0].axis == axis }
            return indices.isEmpty ? nil : (axis, indices)
        }
    }

    /// §348 — every pair **inside one direction group**, as index pairs, vertical group first.
    /// A vertical and a horizontal line are never a pair: they are meant to be perpendicular, and
    /// asking them to be parallel would be the same category error as 「混合方向」.
    public static func pairs(of lines: [GuideLine]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for group in groups(of: lines) {
            for i in group.indices {
                for j in group.indices where j > i { out.append((i, j)) }
            }
        }
        return out
    }

    // MARK: degenerate input the gesture owns (§2.6, §2b.1)

    /// §2.6 — two lines closer than `nearParallelDegrees` (in **source** pixels, i.e. the lines the
    /// photograph holds) say nothing: any keystone can satisfy two lines that already agree.
    /// Only the pairs of the **same axis** are compared; a vertical and a horizontal line are never
    /// "parallel" for this purpose.
    public static func hasNoInformation(_ lines: [GuideLine]) -> Bool {
        let byAxis = Dictionary(grouping: lines, by: \.axis)
        for (_, group) in byAxis {
            for i in group.indices {
                for j in group.indices where j > i {
                    let delta = abs(fold(group[i].sourceAngle - group[j].sourceAngle))
                    if delta < nearParallelDegrees { return true }
                }
            }
        }
        return false
    }

    /// §2.3 / §348 — the axes a set of lines constrains: the ones with **a pair** on them.
    ///
    /// A lone line has no `rᵢⱼ`, so it contributes no row to the fit and cannot constrain its knob
    /// (a single stroke cannot tell a keystone anything — it can only ask to be turned upright, which
    /// is `straighten`'s half of the answer). Keeping the axis anyway would leave a column of zeros
    /// in the Jacobian, i.e. exactly the σmin = 0 that reads as `degenerate`.
    public static func constrainedAxes(of lines: [GuideLine]) -> [GuideLineAxis] {
        groups(of: lines).filter { $0.indices.count >= 2 }.map(\.axis)
    }

    /// §2.3 — the groups are 「混合方向」 when their mean directions are more than 30° apart.
    /// A single-axis set is never mixed.
    public static func isMixedDirection(_ lines: [GuideLine]) -> Bool {
        let byAxis = Dictionary(grouping: lines, by: \.axis)
        guard let vertical = byAxis[.vertical], let horizontal = byAxis[.horizontal],
              !vertical.isEmpty, !horizontal.isEmpty else { return false }
        // Distance from vertical of the vertical group, from horizontal of the horizontal one:
        // both are "how far off the axis it is meant to be", so a mixed set is one where the two
        // groups are not nearly perpendicular.
        let vMean = vertical.map { abs(fold($0.sourceAngle - 90)) }.reduce(0, +) / Double(vertical.count)
        let hMean = horizontal.map { abs($0.sourceAngle) }.reduce(0, +) / Double(horizontal.count)
        return (90 - vMean - hMean) > mixedDirectionDegrees
    }

    // MARK: the fit (§2b.3)

    /// Every pair's angle squared, minimised over the parameters the pairs constrain, then one turn.
    ///
    /// `current` is the document's `(v, h)` — the starting point's neighbourhood (§2b.3: 初值取当前)
    /// and the value the untouched axis keeps. `tolerance` is injectable **only** so the reverse gate
    /// can widen it to 1° and watch the ≤0.05° acceptance go red; the shipped value is
    /// `toleranceDegrees`. It judges the answer, it does not steer the solve (`solveTargetDegrees`).
    public static func fit(lines: [GuideLine],
                           current: PerspectiveMap,
                           source: ImageSize,
                           straightenDegrees: Double,
                           tolerance: Double = GuideLinesSolve.toleranceDegrees,
                           maxIterations: Int = GuideLinesSolve.maxIterations) -> GuideLineFit {
        guard lines.count >= 2 else { return .rejected(.notEnoughLines) }
        guard lines.count <= maxLines else { return .rejected(.tooManyLines) }

        let axes = constrainedAxes(of: lines)
        guard !axes.isEmpty else { return .rejected(.notEnoughLines) }
        let columns = axes.map { $0 == .vertical ? 0 : 1 }
        let pairRows = pairs(of: lines)
        guard !pairRows.isEmpty else { return .rejected(.notEnoughLines) }

        let previousStraighten = straightenDegrees

        // The parameter vector, in the card's order (vertical, horizontal) — only the constrained
        // axes. `x` is always the full pair so the untouched axis is written back unchanged.
        var x = [current.vertical, current.horizontal]

        func deviations(_ values: [Double]) -> [Double] {
            lines.map {
                deviation(of: $0, source: source, vertical: values[0], horizontal: values[1],
                          straightenDegrees: previousStraighten)
            }
        }
        func residuals(_ values: [Double]) -> [Double] {
            let d = deviations(values)
            return pairRows.map { fold(d[$0.0] - d[$0.1]) }
        }
        func worst(_ values: [Double]) -> Double { residuals(values).map(abs).max() ?? .infinity }

        // §2b.3 — the coarse sweep: one sample per `seedStep` over every free parameter, the best
        // sample is where the damped iteration starts. Cheap (≤ 441 evaluations of two line maps)
        // and it is what keeps a pair with a far-away intersection from stalling at its start.
        var seed = x
        var seedWorst = worst(seed)
        func sweep(_ depth: Int) {
            if depth == columns.count {
                let candidate = worst(x)
                if candidate < seedWorst { seedWorst = candidate; seed = x }
                return
            }
            var value = -PerspectiveMap.limit
            while value <= PerspectiveMap.limit {
                x[columns[depth]] = value
                sweep(depth + 1)
                value += seedStep
            }
        }
        sweep(0)
        x = seed

        var lambda = 1e-9
        var iterations = 0
        var r = residuals(x)
        for step in 0..<maxIterations {
            iterations = step + 1
            if (r.map(abs).max() ?? .infinity) <= solveTargetDegrees { break }

            // The numeric Jacobian of the **pair** rows: one derivative per line, then the
            // difference — `∂(φᵢ − φⱼ)/∂p = ∂φᵢ/∂p − ∂φⱼ/∂p`, so a pair costs no extra map.
            var perLine = [[Double]](repeating: [Double](repeating: 0, count: columns.count),
                                     count: lines.count)
            for row in lines.indices {
                for (col, index) in columns.enumerated() {
                    var plus = x, minus = x
                    let h = jacobianStep
                    var denominator = 2 * h
                    if x[index] + h > PerspectiveMap.limit {
                        // One-sided at the slider's end — the same fallback 337 shipped.
                        plus[index] = x[index]
                        minus[index] = x[index] - h
                        denominator = h
                    } else {
                        plus[index] = x[index] + h
                        minus[index] = x[index] - h
                    }
                    let a = deviations(plus), b = deviations(minus)
                    perLine[row][col] = (a[row] - b[row]) / denominator
                }
            }
            let jacobian = pairRows.map { row in
                (0..<columns.count).map { perLine[row.0][$0] - perLine[row.1][$0] }
            }

            // `(JᵀJ + λI) δ = −Jᵀr`, the normal equations of Levenberg's damped Gauss–Newton.
            let n = columns.count
            var normal = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var gradient = [Double](repeating: 0, count: n)
            for a in 0..<n {
                for b in 0..<n {
                    normal[a][b] = jacobian.reduce(0) { $0 + $1[a] * $1[b] }
                }
                gradient[a] = zip(jacobian, r).reduce(0) { $0 + $1.0[a] * $1.1 }
                normal[a][a] += lambda
            }
            let delta: [Double]
            if n == 1 {
                guard abs(normal[0][0]) > 1e-18 else { break }
                delta = [-gradient[0] / normal[0][0]]
            } else {
                let det = normal[0][0] * normal[1][1] - normal[0][1] * normal[1][0]
                guard abs(det) > 1e-18 else { break }
                delta = [(-gradient[0] * normal[1][1] + gradient[1] * normal[0][1]) / det,
                         (-gradient[1] * normal[0][0] + gradient[0] * normal[1][0]) / det]
            }

            // §2b.3 — the step is clamped to the slider's range *and* to `stepLimit`, so one
            // iteration can never leap the whole travel and land in the wrong basin.
            var next = x
            for (col, index) in columns.enumerated() {
                let stepValue = min(max(delta[col], -stepLimit), stepLimit)
                next[index] = min(max(x[index] + stepValue, -PerspectiveMap.limit),
                                  PerspectiveMap.limit)
            }
            let candidate = worst(next)
            if candidate > worst(x) {
                // A damped step that would climb: raise λ and try again on the next iteration.
                lambda = max(lambda * 10, 1e-6)
                continue
            }
            lambda = max(lambda / 5, 1e-12)
            let moved = zip(next, x).map { abs($0 - $1) }.max() ?? 0
            x = next
            r = residuals(x)
            if moved < 1e-12 { break }
        }

        r = residuals(x)
        let achieved = r.map(abs).max() ?? .infinity
        let sigmaMin = smallestSingularValue(jacobianAt: x, lines: lines, pairRows: pairRows,
                                             columns: columns, source: source,
                                             straightenDegrees: previousStraighten)

        if achieved > tolerance {
            // §2b.2 — a fit pinned at the end of the travel is 「超界」, not 「矛盾」.
            let atLimit = columns.contains { abs(abs(x[$0]) - PerspectiveMap.limit) < 1e-9 }
            return .rejected(atLimit ? .outOfRange : .inconsistent, measured: achieved)
        }
        guard sigmaMin > minimumSingularValue else {
            return .rejected(.degenerate, measured: achieved)
        }

        // §348 §2.2 — the second step: one turn, `δ = −mean φ`, so the group's common direction
        // comes back onto the axis. Averaged over **groups**, so a 2 + 2 set is not secretly
        // weighted by whichever group drew more strokes; a single group is just its own mean.
        let d = deviations(x)
        let allGroups = groups(of: lines)
        var deltas: [Double] = []
        var perLine = [Double](repeating: 0, count: lines.count)
        for group in allGroups {
            let mean = group.indices.reduce(0.0) { $0 + d[$1] } / Double(group.indices.count)
            deltas.append(-mean)
            for index in group.indices { perLine[index] = fold(d[index] - mean) }
        }
        let delta = deltas.isEmpty ? 0 : deltas.reduce(0, +) / Double(deltas.count)
        let requested = previousStraighten + delta
        let rotationFailure: GuideLineFailure? =
            abs(requested) > straightenLimit + 1e-9 ? .rotationOutOfRange : nil
        let straighten = rotationFailure == nil ? requested : previousStraighten

        return .solved(GuideLineSolution(vertical: x[0], horizontal: x[1],
                                         straighten: straighten,
                                         straightenRequested: requested,
                                         rotationFailure: rotationFailure,
                                         residuals: perLine, pairwiseResiduals: r,
                                         axes: axes, iterations: iterations,
                                         smallestSingularValue: sigmaMin,
                                         lineCount: lines.count,
                                         previousStraighten: previousStraighten))
    }

    // MARK: - 367: two lines, then 2 × 2

    /// 367 §2.2 — what a pair means. Same axis → correct it (near-parallel included); one of each →
    /// accept without writing; same axis but no movable residual → keep the line and say so.
    public static func pairOutcome(_ lines: [GuideLine],
                                   current: PerspectiveMap,
                                   source: ImageSize,
                                   straightenDegrees: Double,
                                   tolerance: Double = GuideLinesSolve.toleranceDegrees)
        -> GuideLinePairOutcome {
        guard lines.count == 2 else { return .insufficient }
        guard lines[0].axis == lines[1].axis else { return .insufficient }
        let fit = fit(lines: lines, current: current, source: source,
                      straightenDegrees: straightenDegrees, tolerance: tolerance)
        if let solution = fit.solution { return .corrected(solution) }
        let measured = fit.measuredWorstPairwise ?? 0
        let input = abs(fold(lines[0].sourceAngle - lines[1].sourceAngle))
        // 「校正不动」 is the one case where the fit's measured angle is *exactly* the input angle:
        // the parameters moved nothing. No empirical 20°/45° threshold — the residual's own answer.
        if fit.failure == .inconsistent, abs(measured - input) < 0.05 {
            return .unsolvable(measured: measured)
        }
        return .rejected(fit.failure ?? .inconsistent, measured: fit.measuredWorstPairwise)
    }

    /// 367 §2.3 — 「2 横 2 竖」 is the only target the card accepts. For three lines there are six
    /// assignments (which two share an axis × two axes); for four, three 2+2 partitions × two axes.
    /// Each assignment is fitted, the successful one with the smallest worst pair-angle wins, and the
    /// chosen axes are written back into the returned lines.
    ///
    /// A successful assignment must also be **2 横 2 竖 in spirit**: the two groups have to be nearly
    /// perpendicular (`isMixedDirection`). Without that, a 45° stroke would pass as a lone horizontal
    /// line next to a vertical pair (a lone line contributes no pair residual), which is exactly the
    /// 「异常线」 the user asked to be named. When every assignment fails, each line is dropped in turn;
    /// if dropping one makes the rest solvable, that is the offending line.
    public static func groupFit(_ lines: [GuideLine],
                                current: PerspectiveMap,
                                source: ImageSize,
                                straightenDegrees: Double,
                                tolerance: Double = GuideLinesSolve.toleranceDegrees)
        -> GuideLineGroupFit {
        guard lines.count >= 2 else {
            return GuideLineGroupFit(lines: lines, failure: .notEnoughLines)
        }
        guard lines.count <= maxLines else {
            return GuideLineGroupFit(lines: lines, failure: .tooManyLines)
        }
        guard lines.count >= 3 else {
            switch pairOutcome(lines, current: current, source: source,                               straightenDegrees: straightenDegrees, tolerance: tolerance) {
            case .corrected(let solution):
                return GuideLineGroupFit(lines: lines, solution: solution,
                                         measuredWorstPairwise: solution.worstResidual)
            case .insufficient:
                return GuideLineGroupFit(lines: lines, failure: .notEnoughLines)
            case .unsolvable(let measured):
                return GuideLineGroupFit(lines: lines, failure: .linesTooFarFromAxis,
                                         measuredWorstPairwise: measured)
            case .rejected(let failure, let measured):
                return GuideLineGroupFit(lines: lines, failure: failure,
                                         measuredWorstPairwise: measured)
            }
        }

        if let best = bestAssignment(lines, current: current, source: source,
                                     straightenDegrees: straightenDegrees, tolerance: tolerance) {
            return GuideLineGroupFit(lines: best.lines, solution: best.solution,
                                     measuredWorstPairwise: best.solution.worstResidual)
        }

        // All assignments failed: find the one line whose absence makes the rest solvable.
        var offender: (index: Int, lines: [GuideLine], solution: GuideLineSolution)?
        for index in lines.indices {
            var remaining = lines
            remaining.remove(at: index)
            guard let best = bestAssignment(remaining, current: current, source: source,
                                            straightenDegrees: straightenDegrees,
                                            tolerance: tolerance) else { continue }
            if offender == nil
                || best.solution.worstResidual < offender!.solution.worstResidual {
                offender = (index, best.lines, best.solution)
            }
        }
        if let offender {
            return GuideLineGroupFit(lines: offender.lines, solution: offender.solution,
                                     failure: .inconsistent,
                                     measuredWorstPairwise: offender.solution.worstResidual,
                                     offendingIndex: offender.index)
        }

        // No single line to blame: the groups contradict each other. Say by how much, from the lines
        // as they were drawn (the caller keeps its previous valid set and withdraws only the new one).
        return GuideLineGroupFit(lines: lines, failure: .inconsistent,
                                 measuredWorstPairwise: worstPairwiseAngle(of: lines))
    }

    /// The six assignments §2.3 enumerates, as an axis per line in the caller's order.
    public static func axisAssignments(count: Int) -> [[GuideLineAxis]] {
        func flipped(_ axis: GuideLineAxis) -> GuideLineAxis {
            axis == .vertical ? .horizontal : .vertical
        }
        var out: [[GuideLineAxis]] = []
        switch count {
        case 3:
            for axis in GuideLineAxis.allCases {
                for i in 0..<3 {
                    for j in (i + 1)..<3 {
                        var assignment = [flipped(axis), flipped(axis), flipped(axis)]
                        assignment[i] = axis
                        assignment[j] = axis
                        out.append(assignment)
                    }
                }
            }
        case 4:
            let partitions = [[[0, 1], [2, 3]], [[0, 2], [1, 3]], [[0, 3], [1, 2]]]
            for partition in partitions {
                for axis in GuideLineAxis.allCases {
                    var assignment = [flipped(axis), flipped(axis), flipped(axis), flipped(axis)]
                    for index in partition[0] { assignment[index] = axis }
                    for index in partition[1] { assignment[index] = flipped(axis) }
                    out.append(assignment)
                }
            }
        default:
            break
        }
        return out
    }

    /// The best successful assignment, or `nil`. A solution counts only when the assigned groups are
    /// nearly perpendicular — the 「2 横 2 竖」 the user is asking for.
    static func bestAssignment(_ lines: [GuideLine],
                               current: PerspectiveMap,
                               source: ImageSize,
                               straightenDegrees: Double,
                               tolerance: Double)
        -> (lines: [GuideLine], solution: GuideLineSolution)? {
        guard lines.count >= 3 else {
            guard lines.count == 2 else { return nil }
            switch pairOutcome(lines, current: current, source: source,
                               straightenDegrees: straightenDegrees, tolerance: tolerance) {
            case .corrected(let solution): return (lines, solution)
            case .insufficient, .unsolvable, .rejected: return nil
            }
        }
        var best: (lines: [GuideLine], solution: GuideLineSolution)?
        for assignment in axisAssignments(count: lines.count) {
            var assigned = lines
            for index in assigned.indices { assigned[index].axis = assignment[index] }
            let fit = fit(lines: assigned, current: current, source: source,
                          straightenDegrees: straightenDegrees, tolerance: tolerance)
            guard let solution = fit.solution else { continue }
            // For three lines one group is a lone stroke; 「剩下一个垂直」 is a real condition, or a
            // 45° diagonal would pass as a lone horizontal line (it contributes no pair row). The
            // relative angle is measured in the **mapped** plane at the solution, not in the source:
            // the current keystone bends the drawn lines, which is the whole reason they are solved.
            if assigned.count == 3,
               !isNearlyPerpendicular(assigned, solution: solution, source: source,
                                      straightenDegrees: straightenDegrees) {
                continue
            }
            if best == nil
                || solution.worstResidual < best!.solution.worstResidual {
                best = (assigned, solution)
            }
        }
        return best
    }

    /// The two groups' common directions are ~90° apart **after** the keystone. A lone line that is
    /// 45° off the pair is the 「异常线」 the user asked to be named; a lone line that is roughly
    /// perpendicular is the third stroke of a 2 + 1 set.
    static func isNearlyPerpendicular(_ lines: [GuideLine], solution: GuideLineSolution,
                                      source: ImageSize,
                                      straightenDegrees: Double) -> Bool {
        let byAxis = Dictionary(grouping: lines, by: \.axis)
        guard let vertical = byAxis[.vertical], let horizontal = byAxis[.horizontal],
              !vertical.isEmpty, !horizontal.isEmpty else { return true }
        func meanOffAxis(_ group: [GuideLine], target: Double) -> Double {
            group.map {
                abs(fold(mappedAngle(of: $0, source: source,
                                     vertical: solution.vertical,
                                     horizontal: solution.horizontal,
                                     straightenDegrees: straightenDegrees) - target))
            }.reduce(0, +) / Double(group.count)
        }
        let off = meanOffAxis(vertical, target: 90) + meanOffAxis(horizontal, target: 0)
        return off <= mixedDirectionDegrees
    }

    /// The largest within-group pair angle of the lines **as they stand** — the number the card prints
    /// when the whole set is contradictory and no single line can be blamed.
    static func worstPairwiseAngle(of lines: [GuideLine]) -> Double {
        var worst = 0.0
        let byAxis = Dictionary(grouping: lines, by: \.axis)
        for (_, group) in byAxis {
            for i in group.indices {
                for j in group.indices where j > i {
                    worst = max(worst, abs(fold(group[i].sourceAngle - group[j].sourceAngle)))
                }
            }
        }
        return worst
    }

    /// The Jacobian at an answer, and its smallest singular value (§2b.2's rank test).
    ///
    /// For an `m × n` matrix with `n ≤ 2` the singular values are the square roots of the
    /// eigenvalues of `JᵀJ` — a 2×2 closed form, so no SVD is needed and the test is exact.
    public static func smallestSingularValue(jacobianAt x: [Double], lines: [GuideLine],
                                             pairRows: [(Int, Int)], columns: [Int],
                                             source: ImageSize,
                                             straightenDegrees: Double) -> Double {
        var perLine = [[Double]](repeating: [Double](repeating: 0, count: columns.count),
                                 count: lines.count)
        for (row, line) in lines.enumerated() {
            for (col, index) in columns.enumerated() {
                let h = jacobianStep
                var plus = x, minus = x
                plus[index] = x[index] + h
                minus[index] = x[index] - h
                let a = deviation(of: line, source: source, vertical: plus[0], horizontal: plus[1],
                                  straightenDegrees: straightenDegrees)
                let b = deviation(of: line, source: source, vertical: minus[0], horizontal: minus[1],
                                  straightenDegrees: straightenDegrees)
                perLine[row][col] = (a - b) / (2 * h)
            }
        }
        let rows = pairRows.map { pair in
            (0..<columns.count).map { perLine[pair.0][$0] - perLine[pair.1][$0] }
        }
        var normal = [[Double]](repeating: [Double](repeating: 0, count: columns.count),
                                count: columns.count)
        for row in rows {
            for a in 0..<columns.count {
                for b in 0..<columns.count { normal[a][b] += row[a] * row[b] }
            }
        }
        let n = columns.count
        guard n > 0 else { return 0 }
        if n == 1 { return normal[0][0].squareRoot() }
        let trace = normal[0][0] + normal[1][1]
        let det = normal[0][0] * normal[1][1] - normal[0][1] * normal[1][0]
        let disc = max(trace * trace - 4 * det, 0)
        let small = (trace - disc.squareRoot()) / 2
        return max(small, 0).squareRoot()
    }

    // MARK: - 348 可解性: the condition function, and whether it is locally unique
    //
    // 「(v,h) 两个参数，能不能让 4 根线都平行？」 is a question about a **condition function**, and it
    // can be answered with numbers instead of prose. Two lines of one family are parallel exactly
    // when their intersection reaches the line at infinity: with `p = ℓ₁ × ℓ₂` in the source plane
    // and `H(v,h)` the document's own homography (P, then R),
    //
    //     g(v,h) = [H(v,h) · p]₃        g = 0  ⇔  the two lines are parallel
    //
    // — the third coordinate of a point is zero iff the point is at infinity. Two groups give
    // `F = (g_V, g_H)`: two equations, two unknowns. `J = ∂F/∂(v,h)` at the answer decides whether
    // that system is *locally unique*: `|det J| > 1e−9` and `κ = σmax/σmin < 1e6`.
    //
    // Reported in the acceptance's own unit — `g` is the **sine of the angle between the images** of
    // the two lines (each line normalised to a unit normal, so `a₁b₂ − a₂b₁` *is* that sine), i.e.
    // `asin(g)` degrees. `g` and `[H p]₃` vanish together and differ only by a scale, so the rank of
    // `J` — the thing the criterion tests — is the same matrix either way.

    /// 348 — the sine of the angle between two lines' **images** at `(v,h,s)`; 0 ⇔ they are parallel.
    public static func parallelism(of a: GuideLine, and b: GuideLine, source: ImageSize,
                                   vertical: Double, horizontal: Double,
                                   straightenDegrees: Double = 0) -> Double {
        func normalised(_ line: GuideLine) -> (a: Double, b: Double) {
            let p = mapped(line.sourceStart, source: source, vertical: vertical,
                           horizontal: horizontal, straightenDegrees: straightenDegrees)
            let q = mapped(line.sourceEnd, source: source, vertical: vertical,
                           horizontal: horizontal, straightenDegrees: straightenDegrees)
            // The line through p, q as (a,b,c) with a²+b² = 1: a x + b y + c = 0.
            let dx = Double(q.x - p.x), dy = Double(q.y - p.y)
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 1e-12 else { return (0, 0) }
            return (dy / length, -dx / length)
        }
        let l = normalised(a), m = normalised(b)
        return l.a * m.b - l.b * m.a
    }

    /// 348 — what `J = ∂F/∂(v,h)` says about a two-group answer: the determinant, the condition
    /// number, and the verdict 「局部唯一可解」. `nil` unless exactly two pairs (two equations).
    public struct Solvability: Equatable, Sendable {
        public var determinant: Double
        public var conditionNumber: Double
        /// |det| > 1e−9 and κ < 1e6 — the criterion the acceptance quotes.
        public var isLocallyUnique: Bool {
            abs(determinant) > 1e-9 && conditionNumber < 1e6
        }
    }

    public static func solvability(of pairs: [(GuideLine, GuideLine)], source: ImageSize,
                                   vertical: Double, horizontal: Double,
                                   straightenDegrees: Double = 0) -> Solvability? {
        guard pairs.count == 2 else { return nil }
        func degrees(_ pair: (GuideLine, GuideLine), _ v: Double, _ h: Double) -> Double {
            let g = parallelism(of: pair.0, and: pair.1, source: source, vertical: v,
                                horizontal: h, straightenDegrees: straightenDegrees)
            return asin(min(max(g, -1), 1)) * 180 / .pi
        }
        let h = jacobianStep
        var jacobian = [[Double]](repeating: [0, 0], count: 2)
        for (row, pair) in pairs.enumerated() {
            jacobian[row][0] = (degrees(pair, vertical + h, horizontal)
                                - degrees(pair, vertical - h, horizontal)) / (2 * h)
            jacobian[row][1] = (degrees(pair, vertical, horizontal + h)
                                - degrees(pair, vertical, horizontal - h)) / (2 * h)
        }
        let (a, b) = (jacobian[0][0], jacobian[0][1])
        let (c, d) = (jacobian[1][0], jacobian[1][1])
        let det = a * d - b * c
        let trace = a * a + b * b + c * c + d * d
        let disc = max(trace * trace - 4 * det * det, 0).squareRoot()
        let big = ((trace + disc) / 2).squareRoot()
        let small = (max((trace - disc) / 2, 0)).squareRoot()
        return Solvability(determinant: det,
                           conditionNumber: small > 1e-12 ? big / small : .infinity)
    }

    // MARK: the flash

    /// The line's opacity `elapsed` seconds after the hand let go: 1 for `holdSeconds`, then a
    /// linear ramp to 0 over `fadeSeconds` — 328's curve, reused so the two tools flash alike.
    public static func alpha(elapsed: Double) -> Double {
        guard elapsed.isFinite else { return 0 }
        if elapsed <= holdSeconds { return 1 }
        let faded = (elapsed - holdSeconds) / fadeSeconds
        if faded >= 1 { return 0 }
        return 1 - faded
    }
}
