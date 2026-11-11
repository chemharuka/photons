import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **367 — 引导线只在「真校正不动」时才拒绝**: the pair/group decision, measured.
///
/// The user's four sentences (2026-11-10) say the same thing twice:
///
/// > 两条线如果角度很小，应该直接走校正，也不需要提示 … 只有不能校正时才不接受
///
/// so the acceptance is stated on the decision the controller takes, not on prose:
///
///   ④ two converging verticals still land on the same `v` (no regression);
///   ⑤ 0.02° is corrected (small value), 0° is corrected and says nothing;
///   ⑥ one vertical + one horizontal is **accepted**, nothing written, history +1;
///   ⑦ four lines with a near-parallel horizontal pair are stored whole (the old `nearParallel`
///     refusal is gone);
///   ⑧ a 45° diagonal next to a vertical pair is the offending line: the pair is applied, the third
///     line is red, `guideLineOffendingIndex == 2`.
///
/// The fixture is a 9520 × 6336 frame and lines built as the inverse image of exact screen parallels
/// under `PerspectiveMap`, so 「需要的 v/h」 is known before the fit runs — no magic constants.
@MainActor
final class GuideLineTolerance367Tests: XCTestCase {

    private let source = ImageSize(width: 9520, height: 6336)
    private let viewport = ImageSize(width: 1200, height: 800)
    private var workDir: URL!
    private var toolCount = 0

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-367-guides-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

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
        XCTAssertTrue(tool.begin(), "367: 进裁切")
        XCTAssertTrue(tool.setGuideLinesArmed(true), "367: 打开引导线")
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

    private func unWarp(_ map: PerspectiveMap, _ p: CGPoint) -> CGPoint {
        let q = map.inverse(x: Double(p.x) / Double(source.width),
                            y: Double(p.y) / Double(source.height))
        return CGPoint(x: q.x * Double(source.width), y: q.y * Double(source.height))
    }

    private func turned(_ p: CGPoint, by degrees: Double) -> CGPoint {
        let cx = Double(source.width) / 2, cy = Double(source.height) / 2
        let radians = degrees * .pi / 180
        let x = Double(p.x) - cx, y = Double(p.y) - cy
        return CGPoint(x: x * cos(radians) - y * sin(radians) + cx,
                       y: x * sin(radians) + y * cos(radians) + cy)
    }

    private func angle(_ a: CGPoint, _ b: CGPoint) -> Double {
        GuideLinesSolve.fold(GuideLinesSolve.degrees(dx: Double(b.x - a.x), dy: Double(b.y - a.y)))
    }

    /// Two exact screen parallels under `PerspectiveMap(v, h)`, in source pixels.
    private func pair(_ axis: GuideLineAxis, vertical: Double, horizontal: Double,
                      inset: Double = 0.02) -> [(CGPoint, CGPoint)] {
        let w = Double(source.width), h = Double(source.height)
        let map = PerspectiveMap(vertical: vertical, horizontal: horizontal)
        let screen: [(CGPoint, CGPoint)]
        switch axis {
        case .vertical:
            let x0 = inset * w, x1 = w - inset * w
            screen = [(CGPoint(x: x0, y: 0), CGPoint(x: x0, y: h)),
                      (CGPoint(x: x1, y: 0), CGPoint(x: x1, y: h))]
        case .horizontal:
            let y0 = inset * h, y1 = h - inset * h
            screen = [(CGPoint(x: 0, y: y0), CGPoint(x: w, y: y0)),
                      (CGPoint(x: 0, y: y1), CGPoint(x: w, y: y1))]
        }
        return screen.map { ($0.0, $0.1) }.map { (unWarp(map, $0.0), unWarp(map, $0.1)) }
    }

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

    // MARK: - ④ two converging verticals do not regress

    func testTwoConvergingVerticalsStillSolveToTheSameValue() throws {
        let (session, tool) = try makeTool()
        let rows = session.history.snapshots.count
        let lines = pair(.vertical, vertical: -74.15, horizontal: 0)
        XCTAssertNil(draw(tool, from: lines[0].0, to: lines[0].1))
        let applied = try XCTUnwrap(draw(tool, from: lines[1].0, to: lines[1].1),
                                    "367 ④ 两条会聚竖线应当解出来：\(String(describing: tool.guideLineFailure))")
        print(String(format: "367 ④ 2 竖: v %+.3f · 残差 %.6f° · 行 +%d",
                     applied.vertical, applied.worstResidual,
                     session.history.snapshots.count - rows))
        XCTAssertEqual(applied.vertical, -74.15, accuracy: 0.5)
        XCTAssertLessThanOrEqual(applied.worstResidual, 0.05)
        XCTAssertEqual(session.history.snapshots.count, rows + 1)
        XCTAssertEqual(tool.guideLines.count, 2)
    }

    // MARK: - ⑤ a tiny angle is a correction, not a warning

    func testATinyAngleIsCorrectedAndAnExactParallelPairSaysNothing() throws {
        // (a) 0.02° apart: corrected, small value, no 「几乎平行」.
        let (session, tool) = try makeTool()
        let rows = session.history.snapshots.count
        let lines = pair(.vertical, vertical: 0, horizontal: 0)
        let nudge = 0.02
        let shifted = (CGPoint(x: lines[1].0.x, y: lines[1].0.y),
                       CGPoint(x: lines[1].1.x, y: lines[1].1.y))
        let tiny = (turned(shifted.0, by: nudge), turned(shifted.1, by: nudge))
        let before = abs(GuideLinesSolve.fold(angle(lines[0].0, lines[0].1)
                                              - angle(tiny.0, tiny.1)))
        XCTAssertEqual(before, 0.02, accuracy: 1e-9)
        XCTAssertNil(draw(tool, from: lines[0].0, to: lines[0].1))
        let solution = try XCTUnwrap(draw(tool, from: tiny.0, to: tiny.1),
                                     "367 ⑤ 0.02° 也必须校正：\(String(describing: tool.guideLineFailure))")
        print(String(format: "367 ⑤ 0.02°: v %+.4f · 残差 %.6f° · 提示「%@」 · 行 +%d",
                     solution.vertical, solution.worstResidual,
                     tool.guideLineStatusText ?? "—",
                     session.history.snapshots.count - rows))
        XCTAssertLessThanOrEqual(abs(solution.vertical), 5)
        XCTAssertLessThanOrEqual(solution.worstResidual, 0.05)
        XCTAssertNil(tool.guideLineFailure)
        XCTAssertFalse(tool.guideLineStatusText?.contains("几乎平行") ?? false)

        // (b) exactly parallel: still corrected, and the correction is numerically zero → no status.
        let (_, tool2) = try makeTool()
        let exact = pair(.vertical, vertical: 0, horizontal: 0)
        XCTAssertNil(draw(tool2, from: exact[0].0, to: exact[0].1))
        let zero = try XCTUnwrap(draw(tool2, from: exact[1].0, to: exact[1].1),
                                 "367 ⑤ 0° 也是校正：\(String(describing: tool2.guideLineFailure))")
        print(String(format: "367 ⑤ 0°: v %+.4f · 残差 %.6f° · 提示「%@」",
                     zero.vertical, zero.worstResidual, tool2.guideLineStatusText ?? "—"))
        XCTAssertLessThanOrEqual(zero.worstResidual, 0.05)
        XCTAssertNil(tool2.guideLineStatusText, "367 ⑤ 等于没动时不显示提示")
    }

    // MARK: - ⑥ one vertical + one horizontal is information, not an error

    func testOneVerticalAndOneHorizontalAreAcceptedWithoutWritingPerspective() throws {
        let (session, tool) = try makeTool()
        let rows = session.history.snapshots.count
        let vertical = pair(.vertical, vertical: 0, horizontal: 0)
        let horizontal = pair(.horizontal, vertical: 0, horizontal: 0)
        XCTAssertNil(draw(tool, from: vertical[0].0, to: vertical[0].1))
        let second = draw(tool, from: horizontal[0].0, to: horizontal[0].1)
        print("367 ⑥ 1 竖 1 横: 画完 \(tool.guideLines.count) 条 · 原因 \(String(describing: tool.guideLineFailure))"
              + " · 提示「\(tool.guideLineStatusText ?? "—")」· 行 +\(session.history.snapshots.count - rows)")
        XCTAssertNil(second, "367 ⑥ 一竖一横不产生透视解")
        XCTAssertEqual(tool.guideLines.count, 2, "367 ⑥ 两条线都要留着")
        XCTAssertNil(tool.guideLineFailure)
        XCTAssertNil(tool.rejectedGuideLine)
        XCTAssertEqual(session.edit.geometry.perspectiveVertical, 0, accuracy: 1e-12)
        XCTAssertEqual(session.edit.geometry.perspectiveHorizontal, 0, accuracy: 1e-12)
        XCTAssertEqual(session.history.snapshots.count, rows + 1, "367 ⑥ 只记引导线，也是一行历史")
        XCTAssertTrue(tool.guideLineStatusText?.contains("一竖一横") ?? false)
    }

    // MARK: - ⑦ four lines, one pair nearly parallel

    func testFourLinesWithANearParallelPairAreStoredWhole() throws {
        let (session, tool) = try makeTool()
        let vertical = pair(.vertical, vertical: -74.15, horizontal: -1.34)
        let horizontal = pair(.horizontal, vertical: -74.15, horizontal: -1.34)
        let horizontalSpread = abs(GuideLinesSolve.fold(angle(horizontal[0].0, horizontal[0].1)
                                                        - angle(horizontal[1].0, horizontal[1].1)))
        for (a, b) in vertical { _ = draw(tool, from: a, to: b) }
        for (a, b) in horizontal { _ = draw(tool, from: a, to: b) }
        let solution = try XCTUnwrap(tool.guideLineSolution,
                                     "367 ⑦ 四条应当解出来：\(String(describing: tool.guideLineFailure))")
        print(String(format: "367 ⑦ 2 竖 + 2 横（横对源角相差 %.3f°）: 存 %d 条 · v %+.3f · h %+.3f · 残差 %.6f°",
                     horizontalSpread, tool.guideLines.count,
                     solution.vertical, solution.horizontal, solution.worstResidual))
        XCTAssertEqual(tool.guideLines.count, 4)
        XCTAssertEqual(solution.vertical, -74.15, accuracy: 0.5)
        XCTAssertEqual(solution.horizontal, -1.34, accuracy: 1)
        XCTAssertLessThanOrEqual(solution.worstResidual, 0.05)
        XCTAssertNil(tool.guideLineFailure)
        XCTAssertNil(tool.rejectedGuideLine)
        XCTAssertEqual(session.edit.geometry.perspectiveVertical, solution.vertical, accuracy: 1e-12)
        XCTAssertEqual(session.edit.geometry.perspectiveHorizontal, solution.horizontal, accuracy: 1e-12)
    }

    // MARK: - ⑧ a 45° diagonal next to a vertical pair is named

    func testAFortyFiveDegreeDiagonalIsNamedAsTheOffendingLine() throws {
        let (session, tool) = try makeTool()
        _ = session
        let vertical = pair(.vertical, vertical: -74.15, horizontal: 0)
        for (a, b) in vertical { _ = draw(tool, from: a, to: b) }
        XCTAssertEqual(tool.guideLines.count, 2, "367 ⑧ 先把两条竖线解出来")
        let height = Double(source.height)
        let diagonal = (CGPoint(x: 0.2 * Double(source.width), y: 0),
                        CGPoint(x: 0.2 * Double(source.width) + height, y: height))
        let result = draw(tool, from: diagonal.0, to: diagonal.1)
        print("367 ⑧ 45° 斜线: 存 \(tool.guideLines.count) 条 · 异常线 \(String(describing: tool.guideLineOffendingIndex))"
              + " · 原因 \(String(describing: tool.guideLineFailure)) · 提示「\(tool.guideLineStatusText ?? "—")」"
              + " · 红线 \(tool.rejectedGuideLine == nil ? "无" : "有")"
              + " · v \(String(format: "%+.3f", tool.guideLineSolution?.vertical ?? .nan))")
        XCTAssertNotNil(result, "367 ⑧ 前两条仍然应用")
        XCTAssertEqual(tool.guideLines.count, 2, "367 ⑧ 斜线不存进文档")
        XCTAssertEqual(tool.guideLineOffendingIndex, 2)
        XCTAssertEqual(tool.guideLineFailure, .inconsistent)
        XCTAssertNotNil(tool.rejectedGuideLine, "367 ⑧ 异常线画红")
        let solution = try XCTUnwrap(tool.guideLineSolution)
        XCTAssertEqual(solution.vertical, -74.15, accuracy: 0.5)
        XCTAssertLessThanOrEqual(solution.worstResidual, 0.05)
        XCTAssertTrue(tool.guideLineStatusText?.contains("第 3 条") ?? false)
    }

    // MARK: - ⑨ a whole set that contradicts itself: no single line is to blame

    func testAContradictoryFourLineSetHasNoOffendingLine() throws {
        let w = Double(source.width), h = Double(source.height)
        // Three verticals that do not meet in one point, plus a 45° diagonal — every 2 + 2 reading is
        // worse than 0.05°, and dropping any one line still leaves a set that cannot be solved.
        let base = [(CGPoint(x: 0.02 * w, y: 0), CGPoint(x: 0.02 * w, y: h)),
                    (CGPoint(x: 0.98 * w, y: 0), CGPoint(x: 0.98 * w, y: h)),
                    (CGPoint(x: 0.50 * w, y: 0), CGPoint(x: 0.50 * w, y: h))]
        func pivotTurn(_ segment: (CGPoint, CGPoint), _ degrees: Double) -> (CGPoint, CGPoint) {
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
        let segments = [pivotTurn(base[0], 5), pivotTurn(base[1], 0), pivotTurn(base[2], -5),
                        (CGPoint(x: 0.2 * w, y: 0), CGPoint(x: 0.2 * w + h, y: h))]
        let lines = segments.map { segment in
            GuideLine(start: segment.0, end: segment.1,
                      sourceStart: segment.0, sourceEnd: segment.1,
                      viewAngle: angle(segment.0, segment.1),
                      axis: GuideLinesSolve.axis(forFoldedAngle: angle(segment.0, segment.1)))
        }
        let group = GuideLinesSolve.groupFit(lines,
                                             current: PerspectiveMap(vertical: 0, horizontal: 0),
                                             source: source, straightenDegrees: 0)
        print("367 ⑨ 矛盾四条: 存 \(group.lines.count) 条 · 原因 \(String(describing: group.failure))"
              + " · 异常线 \(String(describing: group.offendingIndex))"
              + " · 实测 \(String(format: "%.3f", group.measuredWorstPairwise ?? .nan))°")
        XCTAssertNil(group.solution)
        XCTAssertEqual(group.failure, .inconsistent)
        XCTAssertNil(group.offendingIndex)
    }

    // MARK: - ⑩ a vertical + a 40° line is two axes, not a broken pair

    func testOneVerticalAndOneDiagonalAreInsufficientNotUnsolvable() throws {
        let w = Double(source.width), h = Double(source.height)
        let vertical = (CGPoint(x: 0.3 * w, y: 0.1 * h), CGPoint(x: 0.3 * w, y: 0.9 * h))
        let diagonal = (CGPoint(x: 0.5 * w, y: 0.25 * h),
                        CGPoint(x: 0.5 * w + 0.5 * h / tan(40 * .pi / 180), y: 0.75 * h))
        let lines = [vertical, diagonal].map {
            GuideLine(start: $0.0, end: $0.1, sourceStart: $0.0, sourceEnd: $0.1,
                      viewAngle: angle($0.0, $0.1),
                      axis: GuideLinesSolve.axis(forFoldedAngle: angle($0.0, $0.1)))
        }
        let outcome = GuideLinesSolve.pairOutcome(lines,
                                                  current: PerspectiveMap(vertical: 0, horizontal: 0),
                                                  source: source, straightenDegrees: 0)
        print("367 ⑪ 竖 + 斜: 轴 \(lines.map(\.axis)) → \(outcome)")
        XCTAssertEqual(lines[0].axis, .vertical)
        XCTAssertEqual(lines[1].axis, .horizontal)
        XCTAssertEqual(outcome, .insufficient)
        XCTAssertEqual(GuideLineFailure.linesTooFarFromAxis.message(measuredWorstPairwise: 4.2),
                       "这两条线偏轴 4.2°，校正不了（先记下）")
    }

    // MARK: - ⑤ (spacing) how far apart the pair sits decides whether 1° is solvable

    /// Two `vertical` lines at `x1`/`x2` whose **source** angles differ by exactly `delta`, built
    /// straight in source pixels: each leans δ/2 outward, so the pair converges below the frame.
    /// No view → source round trip — the numbers below are the numbers `fit` sees.
    private func splayedPair(x1: Double, x2: Double,
                             delta: Double) -> [GuideLine] {
        let h = Double(source.height)
        let spread = tan(delta / 2 * .pi / 180) * 0.65 * h
        let ends: [(CGPoint, CGPoint)] = [
            (CGPoint(x: x1, y: 0.85 * h), CGPoint(x: x1 - spread, y: 0.20 * h)),
            (CGPoint(x: x2, y: 0.85 * h), CGPoint(x: x2 + spread, y: 0.20 * h))
        ]
        return ends.map {
            GuideLine(a: $0.0, b: $0.1,
                      viewAngle: GuideLinesSolve.fold(GuideLinesSolve.degrees(dx: Double($0.1.x - $0.0.x),
                                                                             dy: Double($0.1.y - $0.0.y))),
                      axis: .vertical)
        }
    }

    /// 31 % of the frame apart: 0.1° / 0.5° / 1.0° all correct to a zero residual.
    func testFarApartPairIsCorrectedToZeroAtEveryTier() throws {
        for delta in [0.1, 0.5, 1.0] {
            let lines = splayedPair(x1: 3000, x2: 6000, delta: delta)
            let inputDiff = abs(GuideLinesSolve.fold(lines[0].sourceAngle - lines[1].sourceAngle))
            let fit = GuideLinesSolve.fit(lines: lines, current: PerspectiveMap(vertical: 0, horizontal: 0),
                                          source: source, straightenDegrees: 0)
            print(String(format: "367 ⑤远距 %.1f°（喂入差 %.6f°）: v %@ · 残差 %@ · 失败 %@",
                         delta, inputDiff,
                         fit.solution.map { String(format: "%+.4f", $0.vertical) } ?? "nil",
                         fit.solution.map { String(format: "%.6f", $0.worstResidual) } ?? "nil",
                         String(describing: fit.failure)))
            XCTAssertEqual(inputDiff, delta, accuracy: 1e-6, "喂进去的两条线就是相差 delta")
            XCTAssertNil(fit.failure, "367 ⑤ 远距 \\(delta)° 必须解得出")
            let solution = try XCTUnwrap(fit.solution)
            XCTAssertLessThanOrEqual(solution.worstResidual, 0.05, "367 ⑤ 远距 \\(delta)° 必须校到零")
            XCTAssertGreaterThan(abs(solution.vertical), 0, "367 ⑤ 远距 \\(delta)° 必须真的动 v")

            // And the same pair through the real door: the controller takes the correction.
            let (session, tool) = try makeTool()
            XCTAssertNil(draw(tool, from: lines[0].a, to: lines[0].b))
            let applied = try XCTUnwrap(draw(tool, from: lines[1].a, to: lines[1].b),
                                        "367 ⑤ 远距 \\(delta)° 走 endGuideLine 也要校：\\(String(describing: tool.guideLineFailure))")
            XCTAssertNil(tool.guideLineFailure)
            XCTAssertLessThanOrEqual(applied.worstResidual, 0.05)
            XCTAssertNotEqual(session.edit.geometry.perspectiveVertical, 0,
                              "367 ⑤ 远距 \\(delta)° 要写进文档")
            XCTAssertFalse(tool.guideLineStatusText?.contains("几乎平行") ?? false)
        }
    }

    /// 80 px apart (0.84 %): the travel needed is beyond ±400, and the card must blame the gap.
    func testVeryClosePairBlamesTheGapNotTheTravel() throws {
        let lines = splayedPair(x1: 3000, x2: 3080, delta: 0.5)
        let (_, tool) = try makeTool()
        XCTAssertNil(draw(tool, from: lines[0].a, to: lines[0].b))
        _ = draw(tool, from: lines[1].a, to: lines[1].b)
        let text = tool.guideLineStatusText ?? "—"
        print("367 ⑤近距 0.5°: 存 \(tool.guideLines.count) 条 · 失败 \(String(describing: tool.guideLineFailure))"
              + " · 提示「\(text)」")
        XCTAssertEqual(tool.guideLines.count, 2, "367 ⑤ 近距也要留下两条线")
        XCTAssertTrue(text.contains("挨太近"), "367 ⑤ 近距的文案要怪间距：\(text)")
        XCTAssertFalse(text.contains("透视超出"), "367 ⑤ 近距不许说行程超限：\(text)")
    }

    /// A **wide** pair whose correction lands on the slider's end is an endpoint answer, not a
    /// solution: `fit` rejects it as `.outOfRange`, and the message still blames the travel because
    /// 31 % spacing is not 「挨太近」.
    func testAPairPinnedAtTheTravelEndIsNotASolution() throws {
        let lines = splayedPair(x1: 3000, x2: 6000, delta: 40)
        let fit = GuideLinesSolve.fit(lines: lines, current: PerspectiveMap(vertical: 0, horizontal: 0),
                                      source: source, straightenDegrees: 0)
        print("367 ⑤端点 40° @31%: v "
              + (fit.solution.map { String(format: "%+.4f", $0.vertical) } ?? "nil")
              + " · 残差 " + (fit.solution.map { String(format: "%.6f", $0.worstResidual) } ?? "nil")
              + " · 失败 " + String(describing: fit.failure))
        XCTAssertNil(fit.solution, "367 ⑤ 钉在量程端点的不是解")
        XCTAssertEqual(fit.failure, .outOfRange)

        let travel = GuideLineFailure.outOfRange.message(measuredWorstPairwise: 1.2,
                                                         spacingFraction: 0.31)
        XCTAssertTrue(travel.contains("透视超出"), "367 ⑤ 远距仍怪行程：\(travel)")
        let gap = GuideLineFailure.outOfRange.message(measuredWorstPairwise: 1.2,
                                                      spacingFraction: 0.01)
        XCTAssertTrue(gap.contains("挨太近"), "367 ⑤ 近距怪间距：\(gap)")
        XCTAssertFalse(gap.contains("透视超出"), "367 ⑤ 近距不怪行程：\(gap)")
    }
}
