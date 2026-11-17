import XCTest
import CoreGraphics
import PhotonsCore
@testable import PhotonsUI

/// **407 — 引导线 2 横 2 竖 的第 4 个自由度 `shear`（方案 A：`s` + 1 个水平切变）。**
///
/// The user's question was 「之前说过 2 横 2 竖靠三个自由度无法求解只能优化，如何提供第四个变量」, and the
/// answer the主线 拍板 is one scalar: a **horizontal** shear `(x, y) → (x + k·y, y)` in the normalized
/// frame. No direction angle (φ is absorbed by `s` — 407 §0 has the numbers), no second shear.
///
/// Everything here is synthetic lines through `GuideLinesSolve`'s public API, so the arithmetic can be
/// judged without a window. The numbers the acceptance asks for are printed by each test.
///
/// | case | what it proves |
/// |---|---|
/// | ① mixed angles | the 1.5916° the user reported is now 0, with a sane `k` |
/// | ② truth recovery | it solves **the right parameters**, not noise (k = 0.06 to 1e−3) |
/// | ③ zero-shear guard | a self-consistent 2 + 2 keeps 348's `(v, h)` bit for bit |
/// | ⑤ other shapes | 1V1H / 2V1H / 1V2H never use the shear |
/// | ⑥ travel | a set needing `|k| > shearLimit` is `.outOfRange`, not a clamped lie |
@MainActor
final class GuideLineShear407Tests: XCTestCase {

    /// 337/348's frame, and the one the mixed fixture is stated on.
    private let source = ImageSize(width: 1200, height: 1200)

    // MARK: - fixtures

    /// The two vertical strokes the frame is 2 % in from, upright in **source** pixels.
    private func verticals(inset: Double = 0.02) -> [(CGPoint, CGPoint)] {
        let w = Double(source.width), h = Double(source.height)
        return [(CGPoint(x: inset * w, y: 0), CGPoint(x: inset * w, y: h)),
                (CGPoint(x: w - inset * w, y: 0), CGPoint(x: w - inset * w, y: h))]
    }

    private func horizontals(inset: Double = 0.02) -> [(CGPoint, CGPoint)] {
        let w = Double(source.width), h = Double(source.height)
        return [(CGPoint(x: 0, y: inset * h), CGPoint(x: w, y: inset * h)),
                (CGPoint(x: 0, y: h - inset * h), CGPoint(x: w, y: h - inset * h))]
    }

    /// A segment turned about its own midpoint — how a fixture makes a line lean without moving it.
    private func ownPivot(_ segment: (CGPoint, CGPoint), _ degrees: Double) -> (CGPoint, CGPoint) {
        let pivot = CGPoint(x: (segment.0.x + segment.1.x) / 2,
                            y: (segment.0.y + segment.1.y) / 2)
        let cx = Double(pivot.x), cy = Double(pivot.y)
        let radians = degrees * .pi / 180
        func turn(_ p: CGPoint) -> CGPoint {
            let x = Double(p.x) - cx, y = Double(p.y) - cy
            return CGPoint(x: x * cos(radians) - y * sin(radians) + cx,
                           y: x * sin(radians) + y * cos(radians) + cy)
        }
        return (turn(segment.0), turn(segment.1))
    }

    private func line(_ segment: (CGPoint, CGPoint), axis: GuideLineAxis) -> GuideLine {
        GuideLine(a: segment.0, b: segment.1,
                  viewAngle: GuideLinesSolve.fold(
                    GuideLinesSolve.degrees(dx: Double(segment.1.x - segment.0.x),
                                            dy: Double(segment.1.y - segment.0.y))),
                  axis: axis)
    }

    private func lines(vertical: [(CGPoint, CGPoint)],
                       horizontal: [(CGPoint, CGPoint)]) -> [GuideLine] {
        vertical.map { line($0, axis: .vertical) } + horizontal.map { line($0, axis: .horizontal) }
    }

    /// 407 §3 ① — the user's own report: 竖 −3°/−1°, 横 +3°/−1°. A 3-DOF keystone+turne brings each
    /// **group** together but cannot put all four lines on their axes; measured worst = 1.5916°.
    private func mixedAngleFixture() -> [GuideLine] {
        let v = verticals().map { ownPivot($0, -3) }
        let v2 = [v[0], ownPivot(verticals()[1], -1)]
        let h = [ownPivot(horizontals()[0], 3), ownPivot(horizontals()[1], -1)]
        return lines(vertical: v2, horizontal: h)
    }

    /// The four lines **as the photograph holds them** for a true camera shear `k`: a picture that is
    /// exactly right under `S(k)` is wrong in the source by `x ↦ x − k·y`.
    ///
    /// Taking the axis-aligned screen segments and pulling them back through `S(−k)` gives source lines
    /// whose image under `S(+k)` is exactly upright — so the fit's answer is known in advance, which is
    /// what makes ② a test of the *parameters* rather than of the residual.
    private func truthFixture(k: Double) -> [GuideLine] {
        func back(_ segment: (CGPoint, CGPoint)) -> (CGPoint, CGPoint) {
            let w = Double(source.width), h = Double(source.height)
            func pull(_ p: CGPoint) -> CGPoint {
                let y = Double(p.y) / h
                return CGPoint(x: Double(p.x) - k * y * w, y: Double(p.y))
            }
            return (pull(segment.0), pull(segment.1))
        }
        return lines(vertical: verticals().map(back), horizontal: horizontals().map(back))
    }

    private func fit(_ lines: [GuideLine],
                     current: PerspectiveMap = PerspectiveMap(vertical: 0, horizontal: 0),
                     straighten: Double = 0) -> GuideLineFit {
        GuideLinesSolve.fit(lines: lines, current: current, source: source,
                            straightenDegrees: straighten)
    }

    /// Each line's deviation from **its own** axis at a parameter set — the acceptance number.
    private func deviations(_ lines: [GuideLine], _ solution: GuideLineSolution) -> [Double] {
        lines.map {
            GuideLinesSolve.deviation(of: $0, source: source,
                                      vertical: solution.vertical,
                                      horizontal: solution.horizontal,
                                      straightenDegrees: solution.straighten,
                                      shear: solution.shear)
        }
    }

    /// What the 3-DOF answer leaves behind — the number the ticket quotes as 1.5916°, reproduced here
    /// so the improvement is measured against **this build's** `fitPairwise`, not a remembered figure.
    private func legacyWorst(_ lines: [GuideLine]) -> (worst: Double, solution: GuideLineSolution) {
        let solution = GuideLinesSolve.fitPairwise(lines: lines,
                                                   current: PerspectiveMap(vertical: 0, horizontal: 0),
                                                   source: source, straightenDegrees: 0).solution!
        let worst = lines.map {
            abs(GuideLinesSolve.deviation(of: $0, source: source,
                                          vertical: solution.vertical,
                                          horizontal: solution.horizontal,
                                          straightenDegrees: solution.straighten))
        }.max() ?? .infinity
        return (worst, solution)
    }

    // MARK: - ① the reported 2 竖 + 2 横

    func testTwoPlusTwoWithMixedAnglesIsNowSolvedExactly() throws {
        let lines = mixedAngleFixture()
        let before = legacyWorst(lines)
        let fit = fit(lines)
        let solution = try XCTUnwrap(fit.solution,
                                     "407 ① 混合偏角的 2 竖 + 2 横必须解出来："
                                     + "\(String(describing: fit.failure))")
        let d = deviations(lines, solution)

        print(String(format: "407 ① 改前 %.4f°（v %+.3f h %+.3f s %+.3f, k 恒 0）→ 改后 v %+.4f h %+.4f "
                     + "s %+.4f k %+.5f · 四条偏差 %@ → 最大 %.2e°",
                     before.worst, before.solution.vertical, before.solution.horizontal,
                     before.solution.straighten,
                     solution.vertical, solution.horizontal, solution.straighten, solution.shear,
                     d.map { String(format: "%+.2e", $0) }.joined(separator: " / "),
                     d.map(abs).max() ?? .nan))

        XCTAssertGreaterThan(before.worst, 1.0, "407 ① 该 fixture 在 3 自由度下本来就只能到 ~1.59°")
        XCTAssertEqual(d.count, 4, "407 ① 四条线各一个偏差")
        XCTAssertLessThanOrEqual(d.map(abs).max() ?? .infinity, 0.05,
                                 "407 ① 四条线都要归到自己的轴（≤0.05°）")
        XCTAssertLessThanOrEqual(abs(solution.shear), 0.1,
                                 "407 ① sanity：不该需要极大的切变（实测 |k| ≈ 0.05）")
        XCTAssertEqual(solution.axes, [.vertical, .horizontal])
        // 348's readout must keep meaning what it meant: the pair angles are still there and still 0.
        XCTAssertLessThanOrEqual(solution.worstResidual, 0.05)
        XCTAssertEqual(solution.pairwiseResiduals.count, 2, "407 ① 两组各一对")
    }

    // MARK: - ② the truth is recovered, not fitted

    func testTheSolutionIsTheOneForARealCameraShear() throws {
        let truth = (v: 0.0, h: 0.0, s: 0.0, k: 0.06)
        let lines = truthFixture(k: truth.k)
        let fit = fit(lines)
        let solution = try XCTUnwrap(fit.solution, "407 ② 真值 k = 0.06 的一组必须解出来")
        let d = deviations(lines, solution)

        print(String(format: "407 ② 真值 (v %.3f, h %.3f, s %.3f, k %.3f) → 反解 (v %+.6f, h %+.6f, "
                     + "s %+.6f, k %+.6f) · 四条残差 %@",
                     truth.v, truth.h, truth.s, truth.k,
                     solution.vertical, solution.horizontal, solution.straighten, solution.shear,
                     d.map { String(format: "%+.2e", $0) }.joined(separator: " / ")))

        XCTAssertEqual(solution.shear, truth.k, accuracy: 1e-3, "407 ② k 要回到真值")
        XCTAssertEqual(solution.vertical, truth.v, accuracy: 0.01, "407 ② v 要回到真值")
        XCTAssertEqual(solution.horizontal, truth.h, accuracy: 0.01, "407 ② h 要回到真值")
        XCTAssertEqual(solution.straighten, truth.s, accuracy: 0.01, "407 ② s 要回到真值")
        XCTAssertLessThanOrEqual(d.map(abs).max() ?? .infinity, 1e-6,
                                 "407 ② 真值处残差应当是 0")
    }

    /// The same recovery on the other sign and a larger magnitude, so ② cannot pass on a lucky sign.
    func testTheTruthIsRecoveredForANegativeAndALargeShear() throws {
        for k in [-0.09, 0.35] {
            let lines = truthFixture(k: k)
            let solution = try XCTUnwrap(fit(lines).solution, "407 ②′ k = \(k) 必须解出来")
            print(String(format: "407 ②′ 真值 k %+.3f → 反解 k %+.6f · v %+.6f · h %+.6f · s %+.6f · "
                         + "最大残差 %.2e°",
                         k, solution.shear, solution.vertical, solution.horizontal,
                         solution.straighten, deviations(lines, solution).map(abs).max() ?? .nan))
            XCTAssertEqual(solution.shear, k, accuracy: 1e-3, "407 ②′ k = \(k) 要回到真值")
            XCTAssertLessThanOrEqual(deviations(lines, solution).map(abs).max() ?? .infinity, 1e-6)
        }
    }

    // MARK: - ③ a zero-shear document keeps 348's answer

    func testAZeroShearDocumentIsSolvedByTheOldPath() {
        // Two verticals and two horizontals that are **already** on their axes: 348's answer is exact,
        // so the new path must not touch it — neither the numbers nor the bits.
        let lines = lines(vertical: verticals(), horizontal: horizontals())
        let legacy = GuideLinesSolve.fitPairwise(lines: lines,
                                                 current: PerspectiveMap(vertical: 0, horizontal: 0),
                                                 source: source, straightenDegrees: 0)
        let legacySolution = legacy.solution!
        let shipped = fit(lines)
        let solution = shipped.solution!

        print(String(format: "407 ③ 自洽四线: legacy (v %.17g, h %.17g, s %.17g) · shipped (v %.17g, "
                     + "h %.17g, s %.17g, k %.17g) · k 差 %.1e",
                     legacySolution.vertical, legacySolution.horizontal, legacySolution.straighten,
                     solution.vertical, solution.horizontal, solution.straighten, solution.shear,
                     abs(solution.shear)))

        XCTAssertLessThanOrEqual(abs(solution.shear), 1e-9, "407 ③ 自洽的一组不许用上切变")
        XCTAssertEqual(solution.vertical, legacySolution.vertical, accuracy: 1e-12,
                       "407 ③ v 与 fitPairwise 相同")
        XCTAssertEqual(solution.horizontal, legacySolution.horizontal, accuracy: 1e-12,
                       "407 ③ h 与 fitPairwise 相同")
        XCTAssertEqual(solution.straighten, legacySolution.straighten, accuracy: 1e-12,
                       "407 ③ s 与 fitPairwise 相同")
    }

    /// The real gate: 348's own 8°+8° keystone fixture, whose answer **is** exact, must come back
    /// through the same entry point with the same `(v, h)` — this is 407 §2.3's promise made concrete
    /// on the fixture `testTwoPlusTwoIsUnchangedBitForBit` uses.
    func testTheEightDegreeKeystoneFixtureKeepsItsAnswer() throws {
        let v = 69.0375, h = 69.0375
        let lines = keystoneFixture(vertical: v, horizontal: h)
        let legacy = try XCTUnwrap(GuideLinesSolve.fitPairwise(
            lines: lines, current: PerspectiveMap(vertical: 0, horizontal: 0),
            source: source, straightenDegrees: 0).solution)
        let shipped = try XCTUnwrap(fit(lines).solution)

        print(String(format: "407 ③′ 8°+8° 楔形 fixture: legacy (v %.10f, h %.10f, s %.10f) · shipped "
                     + "(v %.10f, h %.10f, s %.10f, k %.2e)",
                     legacy.vertical, legacy.horizontal, legacy.straighten,
                     shipped.vertical, shipped.horizontal, shipped.straighten, shipped.shear))

        XCTAssertEqual(shipped.shear, 0, "407 ③′ 已经是 348 的精确解，不许换成切变")
        XCTAssertEqual(shipped.vertical, legacy.vertical, accuracy: 0, "407 ③′ v 逐位不变")
        XCTAssertEqual(shipped.horizontal, legacy.horizontal, accuracy: 0, "407 ③′ h 逐位不变")
        XCTAssertEqual(shipped.straighten, legacy.straighten, accuracy: 0, "407 ③′ s 逐位不变")
    }

    /// Two exact screen parallels under `PerspectiveMap(v, h)`, pulled back to source pixels — 348's
    /// fixture shape, rebuilt here so this file does not depend on that class's private harness.
    private func keystoneFixture(vertical: Double, horizontal: Double) -> [GuideLine] {
        let map = PerspectiveMap(vertical: vertical, horizontal: horizontal)
        let w = Double(source.width), h = Double(source.height)
        func unWarp(_ p: CGPoint) -> CGPoint {
            let q = map.inverse(x: Double(p.x) / w, y: Double(p.y) / h)
            return CGPoint(x: q.x * w, y: q.y * h)
        }
        let inset = 0.02
        let v: [(CGPoint, CGPoint)] = [
            (CGPoint(x: inset * w, y: 0), CGPoint(x: inset * w, y: h)),
            (CGPoint(x: w - inset * w, y: 0), CGPoint(x: w - inset * w, y: h)),
        ].map { (unWarp($0.0), unWarp($0.1)) }
        let hz: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 0, y: inset * h), CGPoint(x: w, y: inset * h)),
            (CGPoint(x: 0, y: h - inset * h), CGPoint(x: w, y: h - inset * h)),
        ].map { (unWarp($0.0), unWarp($0.1)) }
        return lines(vertical: v, horizontal: hz)
    }

    // MARK: - ⑤ every other shape keeps k = 0

    func testShearIsZeroForEveryOtherLineSet() throws {
        // 1V1H — one vertical, one horizontal (400's mode II).
        let mixed = [line(verticals()[0], axis: .vertical),
                     line(horizontals()[0], axis: .horizontal)]
        let oneVOneH = try XCTUnwrap(fit(mixed).solution, "407 ⑤ 1 竖 1 横要解出来")
        XCTAssertEqual(oneVOneH.shear, 0, accuracy: 0, "407 ⑤ 1V1H 不许用切变")

        // 2V1H — a vertical pair plus one horizontal.
        let twoVOneH = try XCTUnwrap(
            fit([line(verticals()[0], axis: .vertical),
                 line(verticals()[1], axis: .vertical),
                 line(ownPivot(horizontals()[0], 2), axis: .horizontal)]).solution,
            "407 ⑤ 2 竖 1 横要解出来")
        XCTAssertEqual(twoVOneH.shear, 0, accuracy: 0, "407 ⑤ 2V1H 不许用切变")

        // 1V2H — the mirror image.
        let oneVTwoH = try XCTUnwrap(
            fit([line(verticals()[0], axis: .vertical),
                 line(horizontals()[0], axis: .horizontal),
                 line(horizontals()[1], axis: .horizontal)]).solution,
            "407 ⑤ 1 竖 2 横要解出来")
        XCTAssertEqual(oneVTwoH.shear, 0, accuracy: 0, "407 ⑤ 1V2H 不许用切变")

        print(String(format: "407 ⑤ 其它档位 k: 1V1H %.1e · 2V1H %.1e · 1V2H %.1e",
                     oneVOneH.shear, twoVOneH.shear, oneVTwoH.shear))
    }

    // MARK: - ⑥ the travel

    func testTheShearTravelIsClamped() {
        // k = 0.8 is what this set needs; `shearLimit` is 0.5. The fit must refuse rather than hand
        // back a k the slider cannot hold (and the document must not be written).
        let lines = truthFixture(k: 0.8)
        let fit = fit(lines)
        print("407 ⑥ 需要 k = 0.8 的一组（行程 ±\(PerspectiveMap.shearLimit)）→ "
              + (fit.solution.map { String(format: "解出 k %+.4f", $0.shear) } ?? "拒绝")
              + " · 原因 \(String(describing: fit.failure))"
              + " · 实测 \(String(format: "%.4f", fit.measuredWorstPairwise ?? .nan))°")
        XCTAssertNil(fit.solution, "407 ⑥ 超出行程的切变不许当解")
        XCTAssertEqual(fit.failure, .outOfRange, "407 ⑥ 原因必须是超界")
        XCTAssertLessThanOrEqual(abs(fit.solution?.shear ?? 0), PerspectiveMap.shearLimit,
                                 "407 ⑥ 任何返回值都不许超程")
    }
}
