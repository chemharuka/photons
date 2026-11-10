import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **348 — 引导线: residual = 「线与线之间的夹角」, then one turn (§2)**
///
/// The user's sentence is the spec: 「引导线只要两条线的倾斜度数稍微不同，例如一个 +2, 一个 −1.5°，就
/// 显示相互矛盾」. 337 measured every line **against its axis**, so a pair 3.5° apart had two
/// residuals no single keystone can zero — and the card said 「这些线互相矛盾」. 348 measures the
/// lines **against each other** (parallel is what the user drew) and turns the pair upright with
/// `straighten` afterwards, which is the one thing a keystone cannot do.
///
/// The acceptance, number by number:
///
///   ① the user's own pair (+2.0 / −1.5) is accepted, and after the write both lines are ≤ 0.05° from
///     vertical **and** ≤ 0.05° from each other — the `(v, straighten)` is printed;
///   ② +2/−1.5, +4/−3, +6/−5 all take, with their `(v, s)` and residuals printed;
///   ③ three verticals +5/0/−5 that do **not** meet in one point are refused (`inconsistent`) and the
///     card prints the worst pair angle;
///   ④ 337's 2 竖 + 2 横 at 8° still converges (both knobs, four residuals) — no regression;
///   ⑤ a group that would need a turn past the dial's ±45° reports `rotationOutOfRange` and the
///     keystone is still written;
///   ⑥ twenty drags while drawing move no crop dimension by more than 1e−12;
///   ⑦ one gesture is one history row, and ⌘Z puts **three** values back;
///   ⑧ the solvability block (可解性): the condition function `g = [H·p]₃`, its Jacobian's det and
///     condition number, and the four cases A/B/C/D with their measured numbers;
///   ⑨ two reverse gates: the 337 residual (line-to-axis) must turn ① red, and skipping the
///     `straighten` write must turn ①'s 「接近竖直」 red.
@MainActor
final class GuideLinesParallel348Tests: XCTestCase {

    /// The same synthetic picture 337 uses: 1200 × 1200, guide lines 2 % in from the frame.
    private let source = ImageSize(width: 1200, height: 1200)
    private let viewport = ImageSize(width: 1200, height: 1200)
    private var workDir: URL!
    private var toolCount = 0

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-348-guides-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness (337's, unchanged in shape)

    private func makeTool(perspective: (vertical: Double, horizontal: Double) = (0, 0),
                          straighten: Double = 0) throws -> (CatalogSession, CropToolController) {
        toolCount += 1
        let directory = workDir.appendingPathComponent("tool-\(toolCount)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (session, _) = try CropUITestSupport.makeSession(in: directory,
                                                            width: source.width,
                                                            height: source.height)
        if perspective.vertical != 0 || perspective.horizontal != 0 || straighten != 0 {
            session.applyEdit {
                $0.geometry.perspectiveVertical = perspective.vertical
                $0.geometry.perspectiveHorizontal = perspective.horizontal
                $0.geometry.rotationDegrees = straighten
            }
            _ = session.commitEdit(label: "透视", coalesce: false)
        }
        let tool = CropToolController(session: session)
        XCTAssertTrue(tool.begin(), "348: 进裁切模式")
        return (session, tool)
    }

    private func framing(perspective: PerspectiveMap? = nil,
                         straighten: Double = 0) -> LoupeFraming {
        LoupeFraming(viewport: viewport,
                     sourceWidth: Double(source.width), sourceHeight: Double(source.height),
                     crop: .full, straightenDegrees: straighten,
                     flipH: false, flipV: false, perspective: perspective)
    }

    private func viewPoint(_ mapping: LoupeMapping, _ p: CGPoint) -> CGPoint {
        let q = mapping.viewPoint(sourceX: Double(p.x), sourceY: Double(p.y))
        return CGPoint(x: q.x, y: q.y)
    }

    /// A source point turned by `degrees` about a pivot (the frame's centre by default).
    private func turned(_ p: CGPoint, by degrees: Double,
                        about pivot: CGPoint? = nil) -> CGPoint {
        let c = pivot ?? CGPoint(x: Double(source.width) / 2, y: Double(source.height) / 2)
        let radians = degrees * .pi / 180
        let x = Double(p.x - c.x), y = Double(p.y - c.y)
        return CGPoint(x: x * cos(radians) - y * sin(radians) + Double(c.x),
                       y: x * sin(radians) + y * cos(radians) + Double(c.y))
    }

    private func angle(_ a: CGPoint, _ b: CGPoint) -> Double {
        GuideLinesSolve.fold(GuideLinesSolve.degrees(dx: Double(b.x - a.x), dy: Double(b.y - a.y)))
    }

    /// The two vertical source segments the fixture uses, `inset` in from the frame.
    private func verticals(inset: Double = 0.02) -> [(CGPoint, CGPoint)] {
        let w = Double(source.width), h = Double(source.height)
        return [(CGPoint(x: inset * w, y: 0), CGPoint(x: inset * w, y: h)),
                (CGPoint(x: w - inset * w, y: 0), CGPoint(x: w - inset * w, y: h))]
    }

    /// The pair §3.1 asks for: two vertical lines leaning `+a` and `−b` degrees in the source.
    private func leaning(_ a: Double, _ b: Double) -> [(CGPoint, CGPoint)] {
        let base = verticals()
        return [(turned(base[0].0, by: a), turned(base[0].1, by: a)),
                (turned(base[1].0, by: b), turned(base[1].1, by: b))]
    }

    /// A segment turned about its own midpoint — how a fixture builds a line that leans without
    /// moving the frame it sits in.
    private func ownPivot(_ segment: (CGPoint, CGPoint), _ degrees: Double) -> (CGPoint, CGPoint) {
        let pivot = CGPoint(x: (segment.0.x + segment.1.x) / 2,
                            y: (segment.0.y + segment.1.y) / 2)
        return (turned(segment.0, by: degrees, about: pivot),
                turned(segment.1, by: degrees, about: pivot))
    }

    private func guideLine(_ segment: (CGPoint, CGPoint),
                           axis: GuideLineAxis? = nil) -> GuideLine {
        let a = angle(segment.0, segment.1)
        return GuideLine(start: segment.0, end: segment.1,
                         sourceStart: segment.0, sourceEnd: segment.1,
                         viewAngle: a, axis: axis ?? GuideLinesSolve.axis(forFoldedAngle: a))
    }

    private func guideLines(_ segments: [(CGPoint, CGPoint)],
                            axes: [GuideLineAxis]? = nil) -> [GuideLine] {
        segments.enumerated().map { index, segment in
            guideLine(segment, axis: axes?[index])
        }
    }

    /// One guide-line gesture on the tool: the two source points as the canvas sees them at
    /// `current`, then mouse-down / move / mouse-up.
    @discardableResult
    private func draw(_ tool: CropToolController, from a: CGPoint, to b: CGPoint,
                      current: PerspectiveMap? = nil, straighten: Double = 0) -> GuideLineSolution? {
        let current = current ?? tool.draft.perspective
        let mapping = framing(perspective: current,
                              straighten: CropTool.clampStraighten(tool.draft.straighten + straighten))
            .mapping(of: .fit)
        let va = viewPoint(mapping, a), vb = viewPoint(mapping, b)
        guard tool.beginGuideLine(atViewPoint: va) else { return nil }
        tool.continueGuideLine(atViewPoint: vb)
        return tool.endGuideLine(mapping: mapping)
    }

    /// The pairwise angle and the per-line deviation from vertical **after** the write, measured with
    /// the document's own three values — the numbers §3.1 is stated on.
    private func after(segments: [(CGPoint, CGPoint)],
                       vertical: Double, horizontal: Double, straighten: Double) -> (pair: Double, axis: [Double]) {
        let angles = segments.map {
            GuideLinesSolve.mappedAngle(of: guideLine($0), source: source,
                                        vertical: vertical, horizontal: horizontal,
                                        straightenDegrees: straighten)
        }
        let pair = abs(GuideLinesSolve.fold(angles[0] - angles[1]))
        return (pair, angles.map { abs(GuideLinesSolve.fold($0 - 90)) })
    }

    private func solution(_ segments: [(CGPoint, CGPoint)],
                          current: PerspectiveMap = PerspectiveMap(vertical: 0, horizontal: 0),
                          straighten: Double = 0,
                          tolerance: Double = GuideLinesSolve.toleranceDegrees) -> GuideLineFit {
        GuideLinesSolve.fit(lines: guideLines(segments), current: current, source: source,
                            straightenDegrees: straighten, tolerance: tolerance)
    }

    // MARK: - ① the user's pair: +2.0 / −1.5, accepted, and both upright

    func testTheUserPairPlusTwoAndMinusOnePointFiveIsAcceptedAndBothLinesEndUpVertical() throws {
        let (session, tool) = try makeTool()
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        let lines = leaning(2.0, -1.5)
        let before = abs(GuideLinesSolve.fold(angle(lines[0].0, lines[0].1)
                                             - angle(lines[1].0, lines[1].1)))
        XCTAssertEqual(before, 3.5, accuracy: 1e-9, "348 ① 贴前两线相差 3.5°")

        // The 337 residual this pair used to be judged on: two numbers that cannot both be zero.
        let legacy = guideLines(lines).map {
            GuideLinesSolve.residual(of: $0, source: source, vertical: 0, horizontal: 0,
                                     straightenDegrees: 0)
        }
        print(String(format: "348 ① 贴前: 两线 %.4f° · 337 的到轴残差 %@（最小 %.4f° ≠ 0 → 旧判据必红）",
                     3.5, legacy.map { String(format: "%+.2f", $0) }.joined(separator: " / "),
                     legacy.map(abs).min() ?? .nan))

        let first = draw(tool, from: lines[0].0, to: lines[0].1)
        XCTAssertNil(first, "348 ① 一条线还解不出来")
        let applied = try XCTUnwrap(draw(tool, from: lines[1].0, to: lines[1].1),
                                    "348 ① 两条线应当解出来：\(String(describing: tool.guideLineFailure))")
        XCTAssertNil(tool.guideLineFailure, "348 ① 不许再报矛盾")
        XCTAssertNil(tool.rejectedGuideLine, "348 ① 不许把线标红撤回")

        let v = session.edit.geometry.perspectiveVertical
        let h = session.edit.geometry.perspectiveHorizontal
        let s = session.edit.geometry.rotationDegrees
        let measured = after(segments: lines, vertical: v, horizontal: h, straighten: s)
        print(String(format: "348 ① 解: v %+.4f · straighten %+.4f°（文档 s=0）· 应用后两线差 %.6f° · "
                     + "离竖直 %@ · 残差 %.6f° · %d 次迭代",
                     applied.vertical, applied.straighten,
                     measured.pair,
                     measured.axis.map { String(format: "%.6f", $0) }.joined(separator: " / "),
                     applied.worstResidual, applied.iterations))

        XCTAssertEqual(h, 0, accuracy: 1e-12, "348 ① 只解竖方向")
        XCTAssertEqual(v, applied.vertical, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(measured.pair, 0.05, "348 ① 应用后两线必须平行（≤0.05°）")
        XCTAssertLessThanOrEqual(max(measured.axis[0], measured.axis[1]), 0.05,
                                 "348 ① 应用后两条线都接近竖直（≤0.05°）")
        XCTAssertEqual(applied.rotationFailure, nil, "348 ① 这一组的摆正在 ±45° 内")
        XCTAssertNotEqual(s, 0, accuracy: 1e-9, "348 ① straighten 必须真的写了")
    }

    // MARK: - ② three families: +2/−1.5, +4/−3, +6/−5

    func testThreeLeaningFamiliesAllTake() throws {
        var printed: [String] = []
        for (a, b) in [(2.0, -1.5), (4.0, -3.0), (6.0, -5.0)] {
            let lines = leaning(a, b)
            let fit = solution(lines)
            let solved = try XCTUnwrap(fit.solution,
                                       "348 ② (+\(a)/\(b)) 应当接受：\(String(describing: fit.failure))")
            let measured = after(segments: lines, vertical: solved.vertical,
                                 horizontal: solved.horizontal, straighten: solved.straighten)
            printed.append(String(format: "%+4.1f/%+4.1f → v %+8.4f · s %+7.4f° · 残差 %.2e° · 两线 %.2e°",
                                  a, b, solved.vertical, solved.straighten,
                                  solved.worstResidual, measured.pair))
            XCTAssertEqual(solved.vertical, solved.vertical, "finite")
            XCTAssertLessThanOrEqual(solved.worstResidual, 0.05, "348 ② 残差 ≤0.05°")
            XCTAssertLessThanOrEqual(max(measured.axis[0], measured.axis[1]), 0.05,
                                     "348 ② 摆正后两条线都接近竖直")
            XCTAssertNil(solved.rotationFailure, "348 ② 摆正在 ±45° 内")
        }
        print("348 ② 三组:\n  " + printed.joined(separator: "\n  "))
    }

    // MARK: - ③ three verticals that really cannot all be parallel

    /// `+5 / 0 / −5` with **three different pivots** — the lines do not meet in one point, so no
    /// projective map can make all three parallel (three lines are parallelisable iff they are
    /// concurrent in the source). The least-squares floor is 7.5° however the knob is set, so the
    /// refusal is `inconsistent`, and the card has to say by how much.
    func testThreeVerticalsThatAreNotConcurrentAreRefusedWithTheWorstPairAngle() throws {
        let base = verticals()
        let middle = (CGPoint(x: Double(source.width) / 2, y: 0),
                      CGPoint(x: Double(source.width) / 2, y: Double(source.height)))
        let lines = [ownPivot(base[0], 5), ownPivot(base[1], 0), ownPivot(middle, -5)]

        let fit = solution(lines)
        let measured = fit.measuredWorstPairwise ?? .nan
        let text = GuideLineFailure.inconsistent.message(measuredWorstPairwise: measured)
        print(String(format: "348 ③ 三竖 +5/0/−5（不共点）: 原因 %@ · 最小二乘地板 %.4f° · 提示「%@」",
                     fit.failure?.rawValue ?? "-", measured, text))

        XCTAssertNil(fit.solution, "348 ③ 三条不共点的线不许被接受")
        XCTAssertEqual(fit.failure, .inconsistent, "348 ③ 原因必须是 inconsistent")
        XCTAssertGreaterThan(measured, 0.05, "348 ③ 实测的最坏两两残差必须 >0.05°")
        XCTAssertTrue(text.contains(String(format: "%.1f", measured)),
                      "348 ③ 提示里必须带最大两两残差（「\(text)」）")

        // The card cannot build three lines on one axis (`maxLinesPerAxis` = 2, §2b.1), so the
        // refusal the *gesture* can reach is the travel's: 347 widened that travel to ±200, so the
        // pair here leans far enough (40°) to stay out of reach, and the row still has to print how
        // far apart they are.
        let far = leaning(40.0, 0.0)
        let (_, tool) = try makeTool()
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        _ = draw(tool, from: far[0].0, to: far[0].1)
        XCTAssertNil(draw(tool, from: far[1].0, to: far[1].1), "348 ③ 需要的透视超出行程，不应用")
        XCTAssertEqual(tool.guideLineFailure, .outOfRange)
        let status = try XCTUnwrap(tool.guideLineStatusText)
        let cardMeasured = try XCTUnwrap(tool.guideLineMeasuredPairwise)
        print(String(format: "348 ③ 卡片 (40°/0°, 需要 v>200): 提示「%@」· 实测 %.4f°", status, cardMeasured))
        XCTAssertTrue(status.contains(String(format: "%.1f", cardMeasured)),
                      "348 ③ 卡片的拒绝提示也必须带实测残差")
    }

    // MARK: - ④ 337's four lines do not regress

    func testFourLinesOf337StillConvergeWithBothKnobs() throws {
        // 337's fixture: a keystone that makes each axis' screen pair converge by 8°, found by
        // bisection on the renderer's own map (the numbers are measured, not asserted).
        let (v, h) = eightDegreeFixture()
        let verticals = warpPair(vertical: v, horizontal: h, axis: .vertical)
        let horizontals = warpPair(vertical: v, horizontal: h, axis: .horizontal)
        let lines = guideLines(verticals) + guideLines(horizontals)
        XCTAssertEqual(convergence(verticals), 8, accuracy: 1e-6)
        XCTAssertEqual(convergence(horizontals), 8, accuracy: 1e-6)

        let fit = GuideLinesSolve.fit(lines: lines,
                                      current: PerspectiveMap(vertical: 0, horizontal: 0),
                                      source: source, straightenDegrees: 0)
        let solved = try XCTUnwrap(fit.solution, "348 ④ 四条线应当解出来")
        let measuredV = after(segments: verticals, vertical: solved.vertical,
                              horizontal: solved.horizontal, straighten: solved.straighten)
        let measuredH = afterSegments(horizontals, vertical: solved.vertical,
                                      horizontal: solved.horizontal, straighten: solved.straighten,
                                      target: 0)
        print(String(format: "348 ④ 2 竖 + 2 横 各 8°: v %+.4f · h %+.4f · s %+.6f° · 四条残差 %@",
                     solved.vertical, solved.horizontal, solved.straighten,
                     solved.residuals.map { String(format: "%+.2e", $0) }.joined(separator: " / ")))
        print(String(format: "348 ④ 摆正后: 竖 %.6f° / %.6f° · 横 %.6f° / %.6f° · 两两 %@",
                     measuredV.axis[0], measuredV.axis[1],
                     measuredH.axis[0], measuredH.axis[1],
                     solved.pairwiseResiduals.map { String(format: "%.2e", abs($0)) }.joined(separator: " / ")))

        XCTAssertEqual(solved.residuals.count, 4, "348 ④ 四条线各有一个偏差")
        XCTAssertLessThanOrEqual(solved.worstResidual, 0.05, "348 ④ 所有两两 ≤0.05°")
        XCTAssertEqual(solved.axes, [.vertical, .horizontal], "348 ④ 两个参数都解")
        XCTAssertLessThanOrEqual(max(measuredV.axis[0], measuredV.axis[1]), 0.05, "348 ④ 竖摆正")
        XCTAssertLessThanOrEqual(max(measuredH.axis[0], measuredH.axis[1]), 0.05, "348 ④ 横摆正")
        // 337 shipped these two numbers; they may only move within a slider unit.
        XCTAssertEqual(solved.vertical, 69.0375, accuracy: 0.5, "348 ④ 与 337 的 v 一致")
        XCTAssertEqual(solved.horizontal, 69.0375, accuracy: 0.5, "348 ④ 与 337 的 h 一致")
    }

    // MARK: - ⑤ a turn the dial cannot hold

    /// The `straighten` field is ±45° (`GeometryGroup.straightenLimit`). The document is already
    /// turned to −43° and the user draws a pair that *looks* 3° off vertical on that screen, so
    /// putting it upright needs −46°: the keystone still applies and only the turn is skipped —
    /// 「透视已应用」 is part of the answer, so the card has to say it.
    func testATurnPastTheDialIsReportedAndTheKeystoneStillLands() throws {
        // Source angles 137°/135° = on screen 94°/92° once the −43° turn is applied — what the user
        // sees when they draw, which is what the axis decision reads.
        let lines = leaning(47.0, 45.0)
        let (session, tool) = try makeTool(straighten: -43)
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        XCTAssertNil(draw(tool, from: lines[0].0, to: lines[0].1))
        XCTAssertNotNil(draw(tool, from: lines[1].0, to: lines[1].1), "348 ⑤ 手势仍然成功")
        let solved = try XCTUnwrap(tool.guideLineSolution)
        print(String(format: "348 ⑤ 文档已在 s = −43°: δ %+.4f° → 需要 s %+.4f° 超 45 → %@ · v %+.4f（照写）",
                     solved.straightenDelta, solved.straightenRequested,
                     solved.rotationFailure?.rawValue ?? "-", solved.vertical))

        XCTAssertEqual(solved.rotationFailure, .rotationOutOfRange, "348 ⑤ 原因必须是 rotationOutOfRange")
        XCTAssertEqual(tool.guideLineRotationFailure, .rotationOutOfRange)
        XCTAssertGreaterThan(abs(solved.straightenRequested), 45)
        XCTAssertEqual(solved.straighten, -43, accuracy: 1e-12, "348 ⑤ 摆正被跳过，s 不动")
        XCTAssertNotEqual(solved.vertical, 0, accuracy: 1e-6, "348 ⑤ keystone 照写")
        XCTAssertEqual(session.edit.geometry.rotationDegrees, -43, accuracy: 1e-9, "348 ⑤ 旋转没动")
        XCTAssertEqual(session.edit.geometry.perspectiveVertical, solved.vertical, accuracy: 1e-12,
                       "348 ⑤ 透视写了")

        let status = try XCTUnwrap(tool.guideLineStatusText)
        print("348 ⑤ 卡片: 「\(status)」 · 文档 (v \(session.edit.geometry.perspectiveVertical), "
              + "s \(session.edit.geometry.rotationDegrees))")
        XCTAssertTrue(status.contains("透视已应用"), "348 ⑤ 提示必须说明透视已经生效")
        XCTAssertTrue(status.contains("±45"), "348 ⑤ 提示必须说明是摆正超界")
    }

    // MARK: - ⑥ the crop frame still does not move while a line is drawn

    func testDrawingGuideLinesNeverTouchesTheCropFrame() throws {
        let (_, tool) = try makeTool()
        tool.draft.crop = CropRect(x: 0.1, y: 0.12, width: 0.6, height: 0.5)
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        let before = tool.draft.crop
        XCTAssertTrue(tool.beginGuideLine(atViewPoint: CGPoint(x: 200, y: 200)))
        var worstW = 0.0, worstH = 0.0
        for step in 1...20 {
            let t = Double(step) / 20
            tool.continueGuideLine(atViewPoint: CGPoint(x: 200 + 300 * t, y: 200 + 120 * t))
            let now = tool.draft.crop
            worstW = max(worstW, abs(now.width - before.width))
            worstH = max(worstH, abs(now.height - before.height))
        }
        print(String(format: "348 ⑥ 20 ticks: Δw %.1e, Δh %.1e", worstW, worstH))
        XCTAssertLessThanOrEqual(worstW, 1e-12)
        XCTAssertLessThanOrEqual(worstH, 1e-12)
    }

    // MARK: - ⑦ one gesture, one history row, three values back

    func testOneGestureIsOneUndoBackToAllThreeValues() throws {
        // A document that already has all three, so ⌘Z has three numbers to put back.
        let (session, tool) = try makeTool(perspective: (12, -7), straighten: 3.5)
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        let rows = session.history.snapshots.count
        let lines = leaning(2.0, -1.5)
        for (a, b) in lines { _ = draw(tool, from: a, to: b, current: PerspectiveMap(vertical: 12, horizontal: -7)) }

        let after = (session.edit.geometry.perspectiveVertical,
                     session.edit.geometry.perspectiveHorizontal,
                     session.edit.geometry.rotationDegrees)
        XCTAssertEqual(session.history.snapshots.count, rows + 1, "348 ⑦ 一次手势 = 一条历史")
        XCTAssertTrue(session.undo(), "348 ⑦ ⌘Z 可用")
        let back = (session.edit.geometry.perspectiveVertical,
                    session.edit.geometry.perspectiveHorizontal,
                    session.edit.geometry.rotationDegrees)
        print(String(format: "348 ⑦ 画前 (%+.1f, %+.1f, %+.1f) → 画后 (%+.3f, %+.3f, %+.3f) → ⌘Z (%+.1f, %+.1f, %+.1f)",
                     12.0, -7.0, 3.5, after.0, after.1, after.2, back.0, back.1, back.2))
        XCTAssertEqual(back.0, 12, accuracy: 1e-12, "348 ⑦ 垂直")
        XCTAssertEqual(back.1, -7, accuracy: 1e-12, "348 ⑦ 水平")
        XCTAssertEqual(back.2, 3.5, accuracy: 1e-12, "348 ⑦ 摆正")
        XCTAssertNotEqual(after.2, 3.5, accuracy: 1e-9, "348 ⑦ 手势确实写了 straighten")
    }

    // MARK: - ⑧ 可解性: the condition function, its Jacobian, and the four cases

    /// 「单纯靠 (v,h) 两个参数，能不能让任意 4 根引导线都平行？」 — answered with numbers.
    ///
    /// With `p = ℓ₁ × ℓ₂` (the source intersection) and `H(v,h)` the document's own map,
    /// `g = [H·p]₃` vanishes exactly when the two lines are parallel: a point's third coordinate is 0
    /// iff it is at infinity. Two groups give `F = (g_V, g_H)`: 2 equations, 2 unknowns, and
    /// `J = ∂F/∂(v,h)` at the answer decides local uniqueness (`|det| > 1e−9`, `κ < 1e6`).
    func testSolvabilityOfTheFourCases() throws {
        // A — one group, two lines: 1 equation, 2 unknowns ⇒ a one-parameter solution set.
        let a1 = leaning(2.0, -1.5)
        let a0 = try XCTUnwrap(solution(a1).solution, "348 ⑧A 两条线可解")
        let a1b = GuideLinesSolve.fit(lines: guideLines(a1),
                                      current: PerspectiveMap(vertical: 0, horizontal: 20),
                                      source: source, straightenDegrees: 0)
        let a20 = try XCTUnwrap(a1b.solution, "348 ⑧A h 换一处仍然可解")
        XCTAssertEqual(a20.horizontal, 20, accuracy: 1e-12, "348 ⑧A h 没被动过（不约束它）")
        print(String(format: "348 ⑧A 2 竖 (+2/−1.5): 1 方程 2 未知 → 一维解集；"
                     + "(v %+.4f, h 0) 残差 %.2e° · (v %+.4f, h 20) 残差 %.2e° · 两个不同的 v 都让它们平行",
                     a0.vertical, a0.worstResidual, a20.vertical, a20.worstResidual))
        XCTAssertLessThanOrEqual(a0.worstResidual, 0.05)
        XCTAssertLessThanOrEqual(a20.worstResidual, 0.05)
        XCTAssertNotEqual(a0.vertical, a20.vertical, accuracy: 1e-6, "348 ⑧A 解集是一维的")

        // B — 2 竖 + 2 横: 2 equations, 2 unknowns ⇒ an isolated answer; det and κ say so.
        let (v, h) = eightDegreeFixture()
        let verticalSegs = warpPair(vertical: v, horizontal: h, axis: .vertical)
        let horizontalSegs = warpPair(vertical: v, horizontal: h, axis: .horizontal)
        let four = guideLines(verticalSegs) + guideLines(horizontalSegs)
        let b = try XCTUnwrap(GuideLinesSolve.fit(lines: four,
                                                  current: PerspectiveMap(vertical: 0, horizontal: 0),
                                                  source: source, straightenDegrees: 0).solution)
        let pairsForB = [(guideLines(verticalSegs)[0], guideLines(verticalSegs)[1]),
                         (guideLines(horizontalSegs)[0], guideLines(horizontalSegs)[1])]
        let solvability = try XCTUnwrap(GuideLinesSolve.solvability(of: pairsForB, source: source,
                                                                    vertical: b.vertical,
                                                                    horizontal: b.horizontal))
        print(String(format: "348 ⑧B 2 竖 + 2 横 各 8°: v %+.4f · h %+.4f · det %.6e · κ %.3f · "
                     + "局部唯一可解 %@ · 两两残差 %@",
                     b.vertical, b.horizontal, solvability.determinant,
                     solvability.conditionNumber,
                     solvability.isLocallyUnique ? "是" : "否",
                     b.pairwiseResiduals.map { String(format: "%.2e", abs($0)) }.joined(separator: " / ")))
        XCTAssertTrue(solvability.isLocallyUnique, "348 ⑧B 隔离解：|det|>1e−9 且 κ<1e6")
        XCTAssertLessThanOrEqual(b.worstResidual, 0.05)

        // B′ — the same question on a fixture whose two groups have **different leverage**: the
        // vertical pair spans 96 % of the frame, the horizontal pair only 30 %. κ is what says how
        // well the two equations pin the two knobs, and equal levers (both at 2 %) give the
        // uninformative κ = 1 — the number only means something when the two equations differ.
        let v5 = generator(axis: .vertical, degrees: 8)
        let vPair5 = warpPair(vertical: v5, horizontal: 0, axis: .vertical, inset: 0.02)
        let hPair5 = warpPair(vertical: v5, horizontal: 30, axis: .horizontal, inset: 0.35)
        let bPrime = try XCTUnwrap(GuideLinesSolve.fit(lines: guideLines(vPair5) + guideLines(hPair5),
                                                       current: PerspectiveMap(vertical: 0, horizontal: 0),
                                                       source: source, straightenDegrees: 0).solution)
        let solvabilityPrime = try XCTUnwrap(
            GuideLinesSolve.solvability(of: [(guideLines(vPair5)[0], guideLines(vPair5)[1]),
                                             (guideLines(hPair5)[0], guideLines(hPair5)[1])],
                                        source: source, vertical: bPrime.vertical,
                                        horizontal: bPrime.horizontal))
        print(String(format: "348 ⑧B′ 8° 竖（幅 96%%）+ 窄横对（幅 30%%）: v %+.4f · h %+.4f · det %.6e · κ %.3f · 局部唯一可解 %@",
                     bPrime.vertical, bPrime.horizontal, solvabilityPrime.determinant,
                     solvabilityPrime.conditionNumber, solvabilityPrime.isLocallyUnique ? "是" : "否"))
        XCTAssertTrue(solvabilityPrime.isLocallyUnique, "348 ⑧B′ 不对称的一组同样局部唯一")
        XCTAssertGreaterThan(solvabilityPrime.conditionNumber, 1.0, "348 ⑧B′ κ 不是那个对称的 1")

        // B″ — 用**第四步**回答「两组消失点不正交时，旋转也救不回多少」: take the consistent 8° + 8°
        // picture and tip the two groups' *common* directions apart (verticals +3°, horizontals +8°).
        // `(v,h)` still makes each group parallel (2 equations, 2 unknowns), so the keystone is fine;
        // but one turn can only be the average of the two groups' offsets, and what is left over is
        // exactly the residual no (v,h,θ) can remove.
        let skewedVertical = guideLines(verticalSegs.map { (turned($0.0, by: 3), turned($0.1, by: 3)) })
        let skewedHorizontal = guideLines(horizontalSegs.map { (turned($0.0, by: 8), turned($0.1, by: 8)) })
        let skewedFallback = GuideLinesSolve.fit(lines: skewedVertical + skewedHorizontal,
                                                 current: PerspectiveMap(vertical: 0, horizontal: 0),
                                                 source: source, straightenDegrees: 0)
        let skewed = try XCTUnwrap(skewedFallback.solution, "348 ⑧B″ 两组各自仍可平行")
        let skewedDeviations = (skewedVertical + skewedHorizontal).map {
            GuideLinesSolve.deviation(of: $0, source: source, vertical: skewed.vertical,
                                      horizontal: skewed.horizontal,
                                      straightenDegrees: skewed.straighten)
        }
        print(String(format: "348 ⑧B″ 竖组 +3°/横组 +8°（故意不正交）: v %+.4f · h %+.4f · δ %+.4f° · "
                     + "加 θ 后四条到轴残差 %@ → 最大 %.4f° 不可消除（两组平均各差一半）",
                     skewed.vertical, skewed.horizontal, skewed.straightenDelta,
                     skewedDeviations.map { String(format: "%+.3f", $0) }.joined(separator: " / "),
                     skewedDeviations.map(abs).max() ?? .nan))
        XCTAssertLessThanOrEqual(skewed.worstResidual, 0.05, "348 ⑧B″ 各组内部仍然平行")
        XCTAssertGreaterThan(skewedDeviations.map(abs).max() ?? 0, 0.5,
                             "348 ⑧B″ 不正交 ⇒ 四条不可能同时到轴，旋转也消不掉")

        // C — three verticals that are not concurrent: infeasible.
        let base = verticals()
        let middle = (CGPoint(x: Double(source.width) / 2, y: 0),
                      CGPoint(x: Double(source.width) / 2, y: Double(source.height)))
        func ownPivot(_ segment: (CGPoint, CGPoint), _ degrees: Double) -> (CGPoint, CGPoint) {
            let pivot = CGPoint(x: (segment.0.x + segment.1.x) / 2,
                                y: (segment.0.y + segment.1.y) / 2)
            return (turned(segment.0, by: degrees, about: pivot),
                    turned(segment.1, by: degrees, about: pivot))
        }
        let cLines = [ownPivot(base[0], 5), ownPivot(base[1], 0), ownPivot(middle, -5)]
        let c = solution(cLines)
        print(String(format: "348 ⑧C 3 竖 +5/0/−5 不共点: 最小二乘地板 %.4f° > 0.05° → %@（三条同时平行 ⟺ 三条在源图共点）",
                     c.measuredWorstPairwise ?? .nan, c.failure?.rawValue ?? "-"))
        XCTAssertEqual(c.failure, .inconsistent)
        XCTAssertGreaterThan(c.measuredWorstPairwise ?? 0, 0.05)

        // D — three verticals that *are* concurrent, on a vanishing point the model can reach.
        //     (A +5/0/−5 trio through the frame's centre is concurrent too, but its vanishing point is
        //     ~11 frame units away while the knobs reach ~5: measured floor 7.5°, so 「共点」 is
        //     necessary, not sufficient. This one puts the meeting point on the reachable pre-image of
        //     the line at infinity, which is the sufficient version.)
        let trio = concurrentTrio(reachableFrom: (vertical: 60, horizontal: 40))
        let trioAngles = trio.map {
            GuideLinesSolve.mappedAngle(of: guideLine($0), source: source,
                                        vertical: 60, horizontal: 40, straightenDegrees: 0)
        }
        let trioPairs = [abs(GuideLinesSolve.fold(trioAngles[0] - trioAngles[1])),
                         abs(GuideLinesSolve.fold(trioAngles[0] - trioAngles[2])),
                         abs(GuideLinesSolve.fold(trioAngles[1] - trioAngles[2]))]
        // One knob sufficed here — the meeting point happens to sit on the *same* pre-image the vertical
        // knob alone can reach (at x = ½ the horizontal term cancels), so the shipped policy solves it.
        let shippedTrio = solution(trio)
        print(String(format: "348 ⑧D 3 竖共点，消失点在可达的无穷远原像上: 在 (v,h)=(60,40) 处三个两两夹角 %@；"
                     + "出厂只解 v 也够 ⇒ v %+.4f · 残差 %.2e°",
                     trioPairs.map { String(format: "%.2e", $0) }.joined(separator: " / "),
                     shippedTrio.solution?.vertical ?? .nan,
                     shippedTrio.measuredWorstPairwise ?? .nan))
        XCTAssertLessThanOrEqual(trioPairs.max() ?? 1, 0.05,
                                 "348 ⑧D 共点且消失点可达 ⇒ 三条线在 (60,40) 处已经精确平行")
        XCTAssertNotNil(shippedTrio.solution, "348 ⑧D 这一组真的能解出来")
        XCTAssertEqual(shippedTrio.solution?.vertical ?? .nan, 60, accuracy: 0.5,
                       "348 ⑧D 落到 v = +60")
        XCTAssertLessThanOrEqual(shippedTrio.measuredWorstPairwise ?? 1, 0.05, "348 ⑧D 残差 ≤0.05°")

        // … and the +5/0/−5 trio through the centre, for the record: the same three angles, but the
        // vanishing point is out of the model's reach ⇒ 7.5° floor, refused.
        let centre = [5.0, 0.0, -5.0].enumerated().map { index, degrees in
            let segment = index == 2 ? middle : base[min(index, 1)]
            let pivot = CGPoint(x: Double(source.width) / 2, y: Double(source.height) / 2)
            return (turned(segment.0, by: degrees, about: pivot),
                    turned(segment.1, by: degrees, about: pivot))
        }
        let centreFit = solution(centre)
        print(String(format: "348 ⑧D′ 同样 ±5° 但绕画面中心共点（消失点 ~11 格远，滑杆只到 ~5）: 地板 %.4f° → %@",
                     centreFit.measuredWorstPairwise ?? .nan, centreFit.failure?.rawValue ?? "-"))
        XCTAssertEqual(centreFit.failure, .inconsistent, "348 ⑧D′ 共点 ≠ 可达")
    }

    // MARK: - ⑨ reverse gates

    /// Gate ①: put the 337 residual back (each line against its **axis**) and the user's pair is
    /// refused exactly as they reported. Nothing else changes — the same lines, the same `(v,h)`.
    func testGateOneTheAxisResidualStillSaysTheseLinesContradictEachOther() throws {
        let lines = guideLines(leaning(2.0, -1.5))
        // 337's acceptance: every |rᵢ| ≤ 0.05° with rᵢ = φᵢ (deviation from the axis).
        let axisResiduals = lines.map {
            abs(GuideLinesSolve.residual(of: $0, source: source, vertical: 0, horizontal: 0,
                                         straightenDegrees: 0))
        }
        // The best a keystone can do under that criterion: solve the pair, then measure **to the axis**.
        let solved = try XCTUnwrap(GuideLinesSolve.fit(lines: lines,
                                                       current: PerspectiveMap(vertical: 0, horizontal: 0),
                                                       source: source, straightenDegrees: 0).solution)
        let toAxis = lines.map {
            abs(GuideLinesSolve.residual(of: $0, source: source, vertical: solved.vertical,
                                         horizontal: solved.horizontal, straightenDegrees: 0))
        }
        print(String(format: "348 ⑨① 按 337 判据（线到轴）: 贴前 %@ · 解出 v %+.3f 后仍有 %@（最小 %.4f° > 0.05° → 红）",
                     axisResiduals.map { String(format: "%.4f", $0) }.joined(separator: " / "),
                     solved.vertical,
                     toAxis.map { String(format: "%.4f", $0) }.joined(separator: " / "),
                     toAxis.min() ?? .nan))
        XCTAssertGreaterThan(toAxis.min() ?? 0, 0.05,
                             "348 ⑨① 反向门：按到轴残差判，用户这一组必须红（这正是 348 要修的病）")
        // Shipped 348: the pair criterion accepts it, with the line deviations all but zero.
        XCTAssertLessThanOrEqual(solved.worstResidual, 0.05, "348 ⑨① 两两残差这一票是绿的")
    }

    /// Gate ②: skip the `straighten` write (parallel, but not turned upright) and ①'s 「都接近竖直」
    /// goes red — the pair is parallel and still 0.25° off vertical, which is 5× the 0.05° the
    /// acceptance asks for.
    func testGateTwoSkippingTheTurnLeavesBothLinesOffVertical() throws {
        let lines = leaning(2.0, -1.5)
        let solved = try XCTUnwrap(solution(lines).solution)
        let withTurn = after(segments: lines, vertical: solved.vertical, horizontal: solved.horizontal,
                             straighten: solved.straighten)
        let without = after(segments: lines, vertical: solved.vertical, horizontal: solved.horizontal,
                            straighten: 0)
        print(String(format: "348 ⑨② 只平行不摆正: 两线 %.2e° · 离竖直 %.4f° / %.4f°（>0.05° → 红）"
                     + " · 摆正后 %.4f° / %.4f°",
                     without.pair, without.axis[0], without.axis[1], withTurn.axis[0], withTurn.axis[1]))
        XCTAssertLessThanOrEqual(without.pair, 0.05, "348 ⑨② 平行这一步是成功的")
        XCTAssertGreaterThan(max(without.axis[0], without.axis[1]), 0.05,
                             "348 ⑨② 不写 straighten，「都接近竖直」必须红")
        XCTAssertLessThanOrEqual(max(withTurn.axis[0], withTurn.axis[1]), 0.05,
                                 "348 ⑨② 写了 straighten 才绿")
    }

    // MARK: - the 337 fixture generators (same bisection, same numbers)

    private func unWarp(_ map: PerspectiveMap, _ p: CGPoint) -> CGPoint {
        let q = map.inverse(x: Double(p.x) / Double(source.width),
                            y: Double(p.y) / Double(source.height))
        return CGPoint(x: q.x * Double(source.width), y: q.y * Double(source.height))
    }

    private func screenPair(_ axis: GuideLineAxis, inset: Double = 0.02) -> [(CGPoint, CGPoint)] {
        let w = Double(source.width), h = Double(source.height)
        switch axis {
        case .vertical:
            let x0 = inset * w, x1 = w - inset * w
            return [(CGPoint(x: x0, y: 0), CGPoint(x: x0, y: h)),
                    (CGPoint(x: x1, y: 0), CGPoint(x: x1, y: h))]
        case .horizontal:
            let y0 = inset * h, y1 = h - inset * h
            return [(CGPoint(x: 0, y: y0), CGPoint(x: w, y: y0)),
                    (CGPoint(x: 0, y: y1), CGPoint(x: w, y: y1))]
        }
    }

    private func warpPair(vertical: Double, horizontal: Double,
                          axis: GuideLineAxis, inset: Double = 0.02) -> [(CGPoint, CGPoint)] {
        let map = PerspectiveMap(vertical: vertical, horizontal: horizontal)
        return screenPair(axis, inset: inset).map { ($0.0, $0.1) }.map { segment in
            (unWarp(map, segment.0), unWarp(map, segment.1))
        }
    }

    private func convergence(_ pair: [(CGPoint, CGPoint)]) -> Double {
        guard pair.count == 2 else { return .nan }
        return abs(GuideLinesSolve.fold(angle(pair[0].0, pair[0].1) - angle(pair[1].0, pair[1].1)))
    }

    private func generator(axis: GuideLineAxis, degrees: Double, other: Double = 0) -> Double {
        var low = -PerspectiveMap.limit, high = PerspectiveMap.limit
        for _ in 0..<80 {
            let mid = (low + high) / 2
            let candidate = axis == .vertical
                ? warpPair(vertical: mid, horizontal: other, axis: .vertical)
                : warpPair(vertical: other, horizontal: mid, axis: .horizontal)
            if convergence(candidate) < degrees { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// 337's 8° + 8° picture: the two knobs act on the same plane, so the calibrations alternate.
    private func eightDegreeFixture() -> (v: Double, h: Double) {
        var v = generator(axis: .vertical, degrees: 8)
        var h = generator(axis: .horizontal, degrees: 8, other: v)
        for _ in 0..<12 {
            v = generator(axis: .vertical, degrees: 8, other: h)
            h = generator(axis: .horizontal, degrees: 8, other: v)
        }
        return (v, h)
    }

    private func afterSegments(_ segments: [(CGPoint, CGPoint)],
                               vertical: Double, horizontal: Double, straighten: Double,
                               target: Double) -> (pair: Double, axis: [Double]) {
        let angles = segments.map {
            GuideLinesSolve.mappedAngle(of: guideLine($0), source: source,
                                        vertical: vertical, horizontal: horizontal,
                                        straightenDegrees: straighten)
        }
        let pair = abs(GuideLinesSolve.fold(angles[0] - angles[1]))
        return (pair, angles.map { abs(GuideLinesSolve.fold($0 - target)) })
    }

    /// Three lines through the point `(v,h)` **sends to infinity** — the reachable vanishing point.
    /// The pre-image of the line at infinity is the map's own third row, so a point on it is exactly a
    /// point the keystone can put at infinity, i.e. the sufficient case of 「三条共点」.
    private func concurrentTrio(reachableFrom map: (vertical: Double, horizontal: Double))
        -> [(CGPoint, CGPoint)] {
        let m = PerspectiveMap(vertical: map.vertical, horizontal: map.horizontal).forwardMatrix
        let a = m[2][0], b = m[2][1], c = m[2][2]
        let qx = 0.5, qy = -(a * 0.5 + c) / b      // a point of `a x + b y + c = 0`
        let w = Double(source.width), h = Double(source.height)
        return [-3.0, 0.0, 3.0].map { degrees in
            let t = tan(degrees * .pi / 180)
            return (CGPoint(x: (qx + (0 - qy) * t) * w, y: 0),
                    CGPoint(x: (qx + (1 - qy) * t) * w, y: h))
        }
    }
}
