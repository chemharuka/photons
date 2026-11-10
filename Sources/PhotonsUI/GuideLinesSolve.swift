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
// ## The residual (§2b)
//
// Each line gives one residual: its two **source** endpoints, pushed through the document's own
// `P(v,h)` and then its rotation `R` (the order S0 uses: perspective, then turn), give a direction;
// the residual is that direction's signed angle from the axis the line is meant to be on.
//
//     vertical line    r = wrap(θ(P·R(s₁), P·R(s₂)) − 90°)
//     horizontal line  r = wrap(θ(…) − 0°)
//
// ## The solve (§2b)
//
// `Σ rᵢ²` over every line, by Gauss–Newton with Levenberg damping — 2 unknowns, ≤ 40 iterations,
// start at the document's current `(v, h)`, every step clamped to the slider's range and to
// `stepLimit` so one iteration can never jump the whole travel. Only the axes the lines actually
// constrain are solved for (`v` for vertical lines, `h` for horizontal ones): a picture with only
// vertical guide lines says nothing about the horizontal knob, and pretending otherwise is exactly
// the rank-deficient fit that would read as `degenerate`.
//
// **Acceptance is all-or-nothing** (§2b.2): every `|rᵢ| ≤ 0.05°` **and** the smallest singular
// value of the Jacobian at the answer `> 1e−6`. Anything else keeps the previous value and says
// why (`inconsistent` / `degenerate` / `outOfRange`). Half a correction is worse than none.
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

/// One 引导线 gesture: the stroke as drawn (view points), the same two points in **source** pixels
/// (what the photograph holds — the material line the fit is about), and how it was read.
public struct GuideLine: Equatable, Sendable {
    /// The stroke as drawn, in view points — what the overlay strokes.
    public var start: CGPoint
    public var end: CGPoint
    /// The same two ends in source pixels, through the current composite inverse
    /// (`P_current⁻¹ · R⁻¹` + crop + camera). The fit never looks at the view points again.
    public var sourceStart: CGPoint
    public var sourceEnd: CGPoint
    /// The stroke's angle **on the screen**, folded into `(−90°, +90°]` — the number the axis
    /// decision and the readout use.
    public var viewAngle: Double
    /// Which axis the fold put it on.
    public var axis: GuideLineAxis

    public init(start: CGPoint, end: CGPoint,
                sourceStart: CGPoint, sourceEnd: CGPoint,
                viewAngle: Double, axis: GuideLineAxis) {
        self.start = start
        self.end = end
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.viewAngle = viewAngle
        self.axis = axis
    }

    /// The stroke's length in **view points** — 20 pt is the misfire threshold (§4.6, 328's number).
    public var length: Double {
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The line's angle in **source** pixels, folded — the angle the photograph holds, which is the
    /// one 「两条线几乎平行」 is asked about (a screen angle would answer for the keystone that is
    /// already on, not for the lines).
    public var sourceAngle: Double {
        GuideLinesSolve.fold(GuideLinesSolve.degrees(dx: Double(sourceEnd.x - sourceStart.x),
                                                     dy: Double(sourceEnd.y - sourceStart.y)))
    }
}

// MARK: - why a solve did not take

/// §2b.2's three reasons, plus the three the *gesture* can have before there is anything to solve.
/// All six keep the document where it was; the card prints `message`.
public enum GuideLineFailure: String, Sendable, Equatable, CaseIterable {
    /// Fewer than two lines: nothing to compare.
    case notEnoughLines
    /// A fifth line (or a third on one axis): §2b.1's 2 + 2 ceiling.
    case tooManyLines
    /// The lines are parallel already (< 0.2° apart) — no information about a vanishing point.
    case nearParallel
    /// The lines disagree: no `(v, h)` brings every residual inside 0.05°.
    case inconsistent
    /// The fit is rank-deficient: the new line repeats what the others already said.
    case degenerate
    /// The answer exists but is outside the slider's own `PerspectiveMap.limit` (347: ±200).
    case outOfRange

    /// What the card says. Short enough for one row (the row is 22 pt high).
    public var message: String {
        switch self {
        case .notEnoughLines: return "再画一条（需 2 条）"
        case .tooManyLines: return "每个方向最多 2 条"
        case .nearParallel: return "两条线几乎平行，没有信息"
        case .inconsistent: return "这些线互相矛盾，未应用"
        case .degenerate: return "新线与已有线重复，未应用"
        case .outOfRange: return "需要的透视超出 ±\(Int(PerspectiveMap.limit))"
        }
    }
}

// MARK: - the answer

/// What one fit produced, with every number the readout and the acceptance print: the two
/// parameters it wants the document to hold, the per-line residuals **after** them, and how the
/// iterations went.
public struct GuideLineSolution: Equatable, Sendable {
    /// The document's `perspectiveVertical` the fit asks for.
    public var vertical: Double
    /// The document's `perspectiveHorizontal` the fit asks for.
    public var horizontal: Double
    /// Every line's residual, in degrees, in the order the lines were given.
    public var residuals: [Double]
    /// Axes the fit actually solved for (the ones the lines constrain).
    public var axes: [GuideLineAxis]
    public var iterations: Int
    /// Smallest singular value of the Jacobian at the answer — §2b.2's rank test.
    public var smallestSingularValue: Double
    public var lineCount: Int

    public init(vertical: Double, horizontal: Double, residuals: [Double],
                axes: [GuideLineAxis], iterations: Int, smallestSingularValue: Double,
                lineCount: Int) {
        self.vertical = vertical
        self.horizontal = horizontal
        self.residuals = residuals
        self.axes = axes
        self.iterations = iterations
        self.smallestSingularValue = smallestSingularValue
        self.lineCount = lineCount
    }

    /// The worst residual — what 「所有残差 ≤ 0.05°」 is measured on.
    public var worstResidual: Double { residuals.map(abs).max() ?? .infinity }

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
        return String(format: "%@ · 残差 %.2f°", values, worstResidual)
    }
}

/// A fit's outcome: either a solution or the reason there is none. Never both.
public struct GuideLineFit: Equatable, Sendable {
    public var solution: GuideLineSolution?
    public var failure: GuideLineFailure?

    public init(solution: GuideLineSolution? = nil, failure: GuideLineFailure? = nil) {
        self.solution = solution
        self.failure = failure
    }

    public static func solved(_ solution: GuideLineSolution) -> GuideLineFit {
        GuideLineFit(solution: solution)
    }

    public static func rejected(_ failure: GuideLineFailure) -> GuideLineFit {
        GuideLineFit(failure: failure)
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
    /// §2.4 — the fit is accepted when every line is this close to its axis.
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
    /// §2b.2 — the rank threshold on the Jacobian's smallest singular value.
    public static let minimumSingularValue: Double = 1e-6
    /// §2.3 — two groups further apart than this are 「混合方向」, and only the bigger one is solved.
    public static let mixedDirectionDegrees: Double = 30
    /// §2.2 — the stroke stays at full opacity for 0.3 s, then fades (328's flash).
    public static let holdSeconds: Double = 0.3
    public static let fadeSeconds: Double = 0.15

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

    /// §2b.3 — one line's signed residual, in degrees, at `(vertical, horizontal)`.
    public static func residual(of line: GuideLine, source: ImageSize,
                                vertical: Double, horizontal: Double,
                                straightenDegrees: Double) -> Double {
        let a = mapped(line.sourceStart, source: source, vertical: vertical,
                       horizontal: horizontal, straightenDegrees: straightenDegrees)
        let b = mapped(line.sourceEnd, source: source, vertical: vertical,
                       horizontal: horizontal, straightenDegrees: straightenDegrees)
        let theta = fold(degrees(dx: Double(b.x - a.x), dy: Double(b.y - a.y)))
        return fold(theta - line.axis.targetDegrees)
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

    /// §2.3 — the axes a set of lines constrains, in the card's order (vertical first).
    public static func constrainedAxes(of lines: [GuideLine]) -> [GuideLineAxis] {
        GuideLineAxis.allCases.filter { axis in lines.contains { $0.axis == axis } }
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

    /// Every line's residual squared, minimised over the parameters the lines constrain.
    ///
    /// `current` is the document's `(v, h)` — the starting point (§2b.3: 初值取当前) and the value
    /// the untouched axis keeps. `tolerance` is injectable **only** so the reverse gate can widen it
    /// to 1° and watch the ≤0.05° acceptance go red; the shipped value is `toleranceDegrees`.
    public static func fit(lines: [GuideLine],
                           current: PerspectiveMap,
                           source: ImageSize,
                           straightenDegrees: Double,
                           tolerance: Double = GuideLinesSolve.toleranceDegrees,
                           maxIterations: Int = GuideLinesSolve.maxIterations) -> GuideLineFit {
        guard lines.count >= 2 else { return .rejected(.notEnoughLines) }
        guard lines.count <= maxLines else { return .rejected(.tooManyLines) }
        if hasNoInformation(lines) { return .rejected(.nearParallel) }

        let axes = constrainedAxes(of: lines)
        guard !axes.isEmpty else { return .rejected(.notEnoughLines) }

        // The parameter vector, in the card's order (vertical, horizontal) — only the constrained
        // axes. `x` is always the full pair so the untouched axis is written back unchanged.
        var x = [current.vertical, current.horizontal]
        let columns = axes.map { $0 == .vertical ? 0 : 1 }

        func residuals(_ values: [Double]) -> [Double] {
            lines.map {
                residual(of: $0, source: source, vertical: values[0], horizontal: values[1],
                         straightenDegrees: straightenDegrees)
            }
        }
        func worst(_ values: [Double]) -> Double { residuals(values).map(abs).max() ?? .infinity }

        var lambda = 1e-9
        var iterations = 0
        var r = residuals(x)
        for step in 0..<maxIterations {
            iterations = step + 1
            if (r.map(abs).max() ?? .infinity) <= tolerance { break }

            // The numeric Jacobian: m lines × n parameters, central differences (one-sided at the
            // slider's end), in degrees per slider unit.
            var jacobian = [[Double]](repeating: [Double](repeating: 0, count: columns.count),
                                      count: lines.count)
            for (row, line) in lines.enumerated() {
                for (col, index) in columns.enumerated() {
                    var plus = x, minus = x
                    let h = jacobianStep
                    if x[index] + h > PerspectiveMap.limit {
                        plus[index] = x[index]
                        minus[index] = x[index] - h
                        jacobian[row][col] = (residual(of: line, source: source,
                                                       vertical: x[0], horizontal: x[1],
                                                       straightenDegrees: straightenDegrees)
                            - residual(of: line, source: source, vertical: minus[0],
                                       horizontal: minus[1],
                                       straightenDegrees: straightenDegrees)) / h
                    } else {
                        plus[index] = x[index] + h
                        minus[index] = x[index] - h
                        jacobian[row][col] = (residual(of: line, source: source,
                                                       vertical: plus[0], horizontal: plus[1],
                                                       straightenDegrees: straightenDegrees)
                            - residual(of: line, source: source, vertical: minus[0],
                                       horizontal: minus[1],
                                       straightenDegrees: straightenDegrees)) / (2 * h)
                    }
                }
            }

            // `(JᵀJ + λI) δ = −Jᵀr`, the normal equations of Levenberg's damped Gauss–Newton.
            let n = columns.count
            var normal = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var gradient = [Double](repeating: 0, count: n)
            for a in 0..<n {
                for b in 0..<n {
                    normal[a][b] = zip(jacobian, lines.indices).reduce(0) { $0 + jacobian[$1.1][a] * jacobian[$1.1][b] }
                }
                gradient[a] = zip(jacobian, r).reduce(0) { $0 + $1.0[a] * $1.1 }
                normal[a][a] += lambda
            }
            let delta: [Double]
            if n == 1 {
                guard abs(normal[0][0]) > 0 else { break }
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
        let sigmaMin = smallestSingularValue(jacobianAt: x, lines: lines, columns: columns,
                                             source: source, straightenDegrees: straightenDegrees)

        if achieved > tolerance {
            // §2b.2 — a fit pinned at the end of the travel is 「超界」, not 「矛盾」.
            let atLimit = columns.contains { abs(abs(x[$0]) - PerspectiveMap.limit) < 1e-9 }
            return .rejected(atLimit ? .outOfRange : .inconsistent)
        }
        guard sigmaMin > minimumSingularValue else { return .rejected(.degenerate) }

        return .solved(GuideLineSolution(vertical: x[0], horizontal: x[1],
                                         residuals: r, axes: axes,
                                         iterations: iterations,
                                         smallestSingularValue: sigmaMin,
                                         lineCount: lines.count))
    }

    /// The Jacobian at an answer, and its smallest singular value (§2b.2's rank test).
    ///
    /// For an `m × n` matrix with `n ≤ 2` the singular values are the square roots of the
    /// eigenvalues of `JᵀJ` — a 2×2 closed form, so no SVD is needed and the test is exact.
    public static func smallestSingularValue(jacobianAt x: [Double], lines: [GuideLine],
                                             columns: [Int], source: ImageSize,
                                             straightenDegrees: Double) -> Double {
        var normal = [[Double]](repeating: [Double](repeating: 0, count: columns.count),
                                count: columns.count)
        for line in lines {
            var row = [Double](repeating: 0, count: columns.count)
            for (col, index) in columns.enumerated() {
                let h = jacobianStep
                var plus = x, minus = x
                plus[index] = x[index] + h
                minus[index] = x[index] - h
                row[col] = (residual(of: line, source: source, vertical: plus[0], horizontal: plus[1],
                                     straightenDegrees: straightenDegrees)
                    - residual(of: line, source: source, vertical: minus[0], horizontal: minus[1],
                               straightenDegrees: straightenDegrees)) / (2 * h)
            }
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
