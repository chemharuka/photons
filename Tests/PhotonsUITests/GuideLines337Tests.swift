import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **337 — 引导线**: draw two lines that should be parallel, and the keystone that makes them so.
///
/// The whole gesture is one pure fit (`GuideLinesSolve.fit`) plus one write (both perspective
/// fields, one history row), so the acceptance can be stated without a screen — the same shape 328's
/// suite has:
///
///   ① 8° of convergence, drawn at 0 error → applied: the pair is ≤ 0.05° apart (竖 and 横);
///   ② the parameter lands where a hand-drag to parallel would put it (≤ 0.5 slider units);
///   ③ four lines (2 竖 + 2 横) → all four residuals ≤ 0.05°, and each parameter within 0.5 of the
///     two-line solve;
///   ④ twenty drags while drawing move no crop dimension by more than 1e−12;
///   ⑤ one gesture is one ⌘Z, back to both keystone values from before;
///   ⑥ one line, a 0.1°-apart pair and Esc all write nothing;
///   ⑦ the row's glyph is `perspective`, and it differs from `level` and `ruler`;
///   ⑨ four lines: both parameters, four residual numbers;
///   ⑩ a line that contradicts the others is refused **whole** (`inconsistent`), and a fifth line is
///     ignored with a reason;
///   ⑪ `不出像素` on → the export's black fraction is 0.000 %, and the canvas is the quad's AABB;
///   ⑫ two reverse gates: the fit measured on the screen (no `P⁻¹ · R⁻¹`) leaves the lines crooked;
///     and a 1° tolerance lets a 1° error through.
///
/// Every fixture is calibrated by the test itself: the source pair is the **inverse image** of two
/// exact parallels under a generator keystone, found by bisection so that the pair really does
/// converge by 8.000° in source pixels. No constant in this file is a magic angle.
@MainActor
final class GuideLines337Tests: XCTestCase {

    /// The synthetic picture: a 12 × 8 grid (12 columns at 100 px, 8 rows at 150 px) on a 1200 × 1200
    /// canvas. Each guide line lies on the grid's own outermost line, 2 % in from the frame's edge —
    /// the worst case for a keystone's leverage, so an 8° convergence is *solvable* here it is
    /// solvable anywhere.
    private let source = ImageSize(width: 1200, height: 1200)
    private let viewport = ImageSize(width: 1200, height: 1200)
    private var workDir: URL!
    private var toolCount = 0

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-337-guides-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

    /// A crop session on a 12 × 8 synthetic picture. `perspective` is written **before** the tool
    /// opens, so it is the history's baseline — the state 应用/⌘Z come back to (a write inside the
    /// open crop session would fold into the session's own single row).
    private func makeTool(perspective: (vertical: Double, horizontal: Double) = (0, 0),
                          staysInsidePixels: Bool? = nil) throws -> (CatalogSession, CropToolController) {
        // Its **own** library: two sessions in one directory would reopen the first one's document,
        // and a test that draws a second gesture on a picture it did not build proves nothing.
        toolCount += 1
        let directory = workDir.appendingPathComponent("tool-\(toolCount)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (session, _) = try CropUITestSupport.makeSession(in: directory,
                                                             width: source.width,
                                                             height: source.height)
        if perspective.vertical != 0 || perspective.horizontal != 0 {
            session.applyEdit {
                $0.geometry.perspectiveVertical = perspective.vertical
                $0.geometry.perspectiveHorizontal = perspective.horizontal
            }
            _ = session.commitEdit(label: "透视", coalesce: false)
        }
        let tool = CropToolController(session: session)
        if let staysInsidePixels { _ = tool.setCropStaysInsidePixels(staysInsidePixels) }
        XCTAssertTrue(tool.begin(), "337: 进裁切模式")
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

    /// A **screen** point back in source pixels through the generator map's inverse — `P⁻¹` only,
    /// which is all the fixture needs (the generator is the document's own keystone).
    private func unWarp(_ map: PerspectiveMap, _ p: CGPoint) -> CGPoint {
        let q = map.inverse(x: Double(p.x) / Double(source.width),
                            y: Double(p.y) / Double(source.height))
        return CGPoint(x: q.x * Double(source.width), y: q.y * Double(source.height))
    }

    /// A source point turned by `degrees` about the frame's centre — how the test builds a line that
    /// *leans the wrong way* without touching the fixture's own geometry.
    private func turned(_ p: CGPoint, by degrees: Double) -> CGPoint {
        let cx = Double(source.width) / 2, cy = Double(source.height) / 2
        let radians = degrees * .pi / 180
        let x = Double(p.x) - cx, y = Double(p.y) - cy
        return CGPoint(x: x * cos(radians) - y * sin(radians) + cx,
                       y: x * sin(radians) + y * cos(radians) + cy)
    }

    /// The two **source** segments a generator map turns into two exact parallels. The screen
    /// segments are on the grid's own lines; `vergence` 8 is what §3.1 asks for.
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
        return screen.map { ($0.0, $0.1) }.map { seg in
            (unWarp(map, seg.0), unWarp(map, seg.1))
        }
    }

    private func angle(_ a: CGPoint, _ b: CGPoint) -> Double {
        GuideLinesSolve.fold(GuideLinesSolve.degrees(dx: Double(b.x - a.x), dy: Double(b.y - a.y)))
    }

    /// How far apart the two lines are, in degrees — the number §3.1 prints before and after.
    private func convergence(of pair: [(CGPoint, CGPoint)]) -> Double {
        guard pair.count == 2 else { return .nan }
        return abs(GuideLinesSolve.fold(angle(pair[0].0, pair[0].1) - angle(pair[1].0, pair[1].1)))
    }

    /// The generator that makes this axis' pair converge by exactly `degrees` in source pixels,
    /// the other knob held at `other`. A bisection over the slider's own range, on the renderer's
    /// map — the fixture is *measured* to be 8°, never asserted to be.
    private func generator(_ axis: GuideLineAxis, degrees: Double,
                           other: Double = 0) -> Double {
        var low = -PerspectiveMap.limit, high = PerspectiveMap.limit
        for _ in 0..<80 {
            let mid = (low + high) / 2
            let candidate = axis == .vertical ? pair(axis, vertical: mid, horizontal: other)
                                              : pair(axis, vertical: other, horizontal: mid)
            if convergence(of: candidate) < degrees { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// One guide-line gesture on the tool: the two source points as the canvas sees them at
    /// `current`, then mouse-down / move / mouse-up.
    @discardableResult
    private func draw(_ tool: CropToolController, from a: CGPoint, to b: CGPoint,
                      current: PerspectiveMap? = nil) -> GuideLineSolution? {
        // The stroke is drawn on the **screen**, where the document's current keystone is already
        // applied — so the view points come from the document's own `(v, h)`, the way the canvas
        // shows them. (Without this the second pair of a four-line gesture would be drawn on a
        // picture the user is not looking at.)
        let current = current ?? tool.draft.perspective
        let mapping = framing(perspective: current).mapping(of: .fit)
        let va = viewPoint(mapping, a), vb = viewPoint(mapping, b)
        guard tool.beginGuideLine(atViewPoint: va) else { return nil }
        tool.continueGuideLine(atViewPoint: vb)
        return tool.endGuideLine(mapping: mapping)
    }

    /// The convergence the document's own renderer shows for the pair — the 「贴前/后」 number.
    private func renderedConvergence(_ pair: [(CGPoint, CGPoint)],
                                     perspective: PerspectiveMap?) -> Double {
        let mapping = framing(perspective: perspective).mapping(of: .fit)
        let points = pair.map { (viewPoint(mapping, $0.0), viewPoint(mapping, $0.1)) }
        return convergence(of: points)
    }

    // MARK: - ① vertical: two lines, 8° of convergence, ≤ 0.05° after

    func testTwoVerticalGuideLinesLeaveThePairWithinAFiftiethOfADegree() throws {
        let (session, tool) = try makeTool()
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        let v = generator(.vertical, degrees: 8)
        let lines = pair(.vertical, vertical: v, horizontal: 0)
        print(String(format: "337 ① fixture: 竖 8° needs v = %.3f on a 12×8 grid; source pair %@ / %@",
                     v, NSStringFromPoint(lines[0].0), NSStringFromPoint(lines[1].1)))

        let before = renderedConvergence(lines, perspective: nil)
        XCTAssertEqual(before, 8, accuracy: 1e-6, "337 ① 贴前必须是 8°")

        XCTAssertNil(draw(tool, from: lines[0].0, to: lines[0].1), "337 ① 一条线还解不出来")
        XCTAssertEqual(tool.guideLines.count, 1, "337 ① 第一条线留着等第二条")
        let applied = draw(tool, from: lines[1].0, to: lines[1].1)
        XCTAssertNotNil(applied, "337 ① 两条线应当解出来：\(String(describing: tool.guideLineFailure))")
        let solution = try XCTUnwrap(applied)
        let map = PerspectiveMap(vertical: session.edit.geometry.perspectiveVertical,
                                horizontal: session.edit.geometry.perspectiveHorizontal)
        let after = renderedConvergence(lines, perspective: map.hasWarp ? map : nil)
        print(String(format: "337 ① 竖: 前 %.6f° → v %+8.3f (滑杆单位 ±100) → 后 %.6f° · 残差 %.6f° · %d 次迭代 · σmin %.3e",
                     before, solution.vertical, after, solution.worstResidual,
                     solution.iterations, solution.smallestSingularValue))

        XCTAssertEqual(session.edit.geometry.perspectiveHorizontal, 0, accuracy: 1e-12,
                       "337 ① 只解竖方向")
        XCTAssertLessThanOrEqual(after, 0.05, "337 ① 应用后两条线必须平行（≤0.05°）")
    }

    // MARK: - ① horizontal: the same, on the other knob

    func testTwoHorizontalGuideLinesLeaveThePairWithinAFiftiethOfADegree() throws {
        let (session, tool) = try makeTool()
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        let h = generator(.horizontal, degrees: 8)
        let lines = pair(.horizontal, vertical: 0, horizontal: h)
        print(String(format: "337 ① fixture: 横 8° needs h = %.3f", h))

        let before = renderedConvergence(lines, perspective: nil)
        XCTAssertEqual(before, 8, accuracy: 1e-6)

        var solution: GuideLineSolution?
        for (a, b) in lines { solution = draw(tool, from: a, to: b) }
        let unwrapped = try XCTUnwrap(solution)
        let map = PerspectiveMap(vertical: session.edit.geometry.perspectiveVertical,
                                horizontal: session.edit.geometry.perspectiveHorizontal)
        let after = renderedConvergence(lines, perspective: map.hasWarp ? map : nil)
        print(String(format: "337 ① 横: 前 %.6f° → h %+8.3f → 后 %.6f° · 残差 %.6f° · %d 次迭代",
                     before, unwrapped.horizontal, after, unwrapped.worstResidual,
                     unwrapped.iterations))
        XCTAssertEqual(session.edit.geometry.perspectiveVertical, 0, accuracy: 1e-12,
                       "337 ① 只解横方向")
        XCTAssertLessThanOrEqual(after, 0.05, "337 ① 水平方向同样 ≤0.05°")
    }

    // MARK: - ② the parameter lands where the slider would

    func testTheSolvedParameterIsWhereDraggingTheSliderToParallelLands() throws {
        let (session, tool) = try makeTool()
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        let v = generator(.vertical, degrees: 8)
        let lines = pair(.vertical, vertical: v, horizontal: 0)
        for (a, b) in lines { _ = draw(tool, from: a, to: b) }
        let solved = session.edit.geometry.perspectiveVertical
        XCTAssertNotEqual(solved, 0, accuracy: 1e-9, "337 ② 必须先真的解出来")

        // 「手工把滑杆拖到平行」: a blind scan of the slider, measuring the **rendered** pair's
        // convergence — no residual function, no solver, just the renderer's own numbers.
        var best = 0.0, bestError = Double.infinity
        var value = -PerspectiveMap.limit
        while value <= PerspectiveMap.limit {
            let error = renderedConvergence(lines, perspective: PerspectiveMap(vertical: value,
                                                                               horizontal: 0))
            if error < bestError { bestError = error; best = value }
            value += 0.01
        }
        print(String(format: "337 ② 参数落点: 求解 v = %+8.4f · 手拖到平行 v = %+8.4f · 差 %.4f（滑杆单位 ±100）",
                     solved, best, abs(solved - best)))
        XCTAssertLessThanOrEqual(abs(solved - best), 0.5,
                                 "337 ② 与「手工拖到平行」差 ≤0.5（滑杆单位）")
    }

    // MARK: - ③ / ⑨ four lines: both knobs, four residuals

    func testFourGuideLinesSolveBothKnobsAndAgreeWithTheTwoLineSolves() throws {
        let (session, tool) = try makeTool()
        XCTAssertTrue(tool.setGuideLinesArmed(true))

        // One picture, both directions converging by 8° — the generator is found by alternating the
        // two calibrations, because the knobs act on the same plane.
        var v = generator(.vertical, degrees: 8)
        var h = generator(.horizontal, degrees: 8, other: v)
        for _ in 0..<12 {
            v = generator(.vertical, degrees: 8, other: h)
            h = generator(.horizontal, degrees: 8, other: v)
        }
        let vertical = pair(.vertical, vertical: v, horizontal: h)
        let horizontal = pair(.horizontal, vertical: v, horizontal: h)
        print(String(format: "337 ⑨ fixture: 2 竖 + 2 横 各 8°（生成器 v %+.3f, h %+.3f）· 实际 %.4f° / %.4f°",
                     v, h, convergence(of: vertical), convergence(of: horizontal)))
        XCTAssertEqual(convergence(of: vertical), 8, accuracy: 1e-6)
        XCTAssertEqual(convergence(of: horizontal), 8, accuracy: 1e-6)

        for (a, b) in vertical { _ = draw(tool, from: a, to: b) }
        let afterTwo = (session.edit.geometry.perspectiveVertical,
                        session.edit.geometry.perspectiveHorizontal)
        for (a, b) in horizontal { _ = draw(tool, from: a, to: b) }

        let solution = try XCTUnwrap(tool.guideLineSolution, "337 ⑨ 四条线应当解出来")
        let map = PerspectiveMap(vertical: session.edit.geometry.perspectiveVertical,
                                horizontal: session.edit.geometry.perspectiveHorizontal)
        let vAfter = renderedConvergence(vertical, perspective: map.hasWarp ? map : nil)
        let hAfter = renderedConvergence(horizontal, perspective: map.hasWarp ? map : nil)
        print(String(format: "337 ⑨ 四条: v %+8.3f · h %+8.3f · 四条残差 %@ ≤0.05° · 竖 %.6f° 横 %.6f°",
                     solution.vertical, solution.horizontal,
                     solution.residuals.map { String(format: "%+.4f", $0) }.joined(separator: " / "),
                     vAfter, hAfter))
        XCTAssertEqual(solution.residuals.count, 4)
        XCTAssertLessThanOrEqual(solution.worstResidual, 0.05, "337 ⑨ 四条残差全部 ≤0.05°")
        XCTAssertLessThanOrEqual(max(vAfter, hAfter), 0.05, "337 ⑨ 两个方向都真的平行了")
        XCTAssertTrue(solution.axes.contains(.vertical) && solution.axes.contains(.horizontal),
                      "337 ⑨ 四条线同时约束两个参数")

        // 「只画那 2 条」: the vertical pair on its own (document at 0) …
        let (session2, tool2) = try makeTool()
        XCTAssertTrue(tool2.setGuideLinesArmed(true))
        var vOnly = 0.0, hOnly = 0.0
        for (a, b) in vertical { _ = draw(tool2, from: a, to: b) }
        vOnly = session2.edit.geometry.perspectiveVertical

        // … and the horizontal pair on its own, on the document the vertical pair already put v on
        // (which is what 「只画那 2 条」 means after the first gesture: the fit starts from the
        // current values, §2b.3).
        let (session3, tool3) = try makeTool(perspective: (vOnly, 0))
        XCTAssertTrue(tool3.setGuideLinesArmed(true))
        let current = PerspectiveMap(vertical: vOnly, horizontal: 0)
        for (a, b) in horizontal { _ = draw(tool3, from: a, to: b, current: current) }
        hOnly = session3.edit.geometry.perspectiveHorizontal

        print(String(format: "337 ⑨ 对照: 只画 2 竖 v %+8.4f、只画 2 横 h %+8.4f（v 已在）· 差 %.4f / %.4f",
                     vOnly, hOnly, abs(solution.vertical - vOnly), abs(solution.horizontal - hOnly)))
        XCTAssertLessThanOrEqual(abs(solution.vertical - vOnly), 0.5)
        XCTAssertLessThanOrEqual(abs(solution.horizontal - hOnly), 0.5)
        _ = afterTwo
    }

    // MARK: - ④ the crop frame does not move while a line is drawn

    func testDrawingGuideLinesNeverTouchesTheCropFrame() throws {
        let (_, tool) = try makeTool()
        tool.draft.crop = CropRect(x: 0.1, y: 0.12, width: 0.6, height: 0.5)
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        let before = tool.draft.crop

        XCTAssertTrue(tool.beginGuideLine(atViewPoint: CGPoint(x: 200, y: 200)))
        XCTAssertFalse(tool.isDragging, "337 ④ 画线不是拖框")
        XCTAssertNil(tool.lastHandle, "337 ④ 画线不抓柄")

        var worstW = 0.0, worstH = 0.0
        for step in 1...20 {
            let t = Double(step) / 20
            tool.continueGuideLine(atViewPoint: CGPoint(x: 200 + 300 * t, y: 200 + 120 * t))
            let now = tool.draft.crop
            worstW = max(worstW, abs(now.width - before.width))
            worstH = max(worstH, abs(now.height - before.height))
            XCTAssertEqual(now, before, "337 ④ tick \(step): 裁切框动了")
        }
        print(String(format: "337 ④ 20 ticks: Δw %.1e, Δh %.1e, 框 %.4f×%.4f",
                     worstW, worstH, before.width, before.height))
        XCTAssertLessThanOrEqual(worstW, 1e-12)
        XCTAssertLessThanOrEqual(worstH, 1e-12)
        XCTAssertEqual(tool.guideLineStroke?.b, CGPoint(x: 500, y: 320), "337 ④ 线跟着手走")
    }

    // MARK: - ⑤ one gesture is one ⌘Z

    func testOneGuideLineGestureIsOneUndoBackToBothKeystones() throws {
        // A keystone already on the document, so ⌘Z has two numbers to put back.
        let (session, tool) = try makeTool(perspective: (12, -7))
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        let rows = session.history.snapshots.count
        let v = generator(.vertical, degrees: 8)
        let lines = pair(.vertical, vertical: v, horizontal: 0)
        let current = PerspectiveMap(vertical: 12, horizontal: -7)
        for (a, b) in lines { _ = draw(tool, from: a, to: b, current: current) }

        let after = (session.edit.geometry.perspectiveVertical,
                     session.edit.geometry.perspectiveHorizontal)
        XCTAssertEqual(session.history.snapshots.count, rows + 1, "337 ⑤ 一次手势 = 一条历史")
        XCTAssertNotEqual(after.0, 12, accuracy: 1e-6)
        XCTAssertTrue(session.undo(), "337 ⑤ ⌘Z 可用")
        let back = (session.edit.geometry.perspectiveVertical,
                    session.edit.geometry.perspectiveHorizontal)
        print(String(format: "337 ⑤ 撤销: 画前 (%+.1f, %+.1f) → 画后 (%+.3f, %+.3f) → ⌘Z (%+.1f, %+.1f)",
                    12.0, -7.0, after.0, after.1, back.0, back.1))
        XCTAssertEqual(back.0, 12, accuracy: 1e-12, "337 ⑤ ⌘Z 回到画引导线之前的垂直")
        XCTAssertEqual(back.1, -7, accuracy: 1e-12, "337 ⑤ ⌘Z 回到画引导线之前的水平")
    }

    // MARK: - ⑥ 误触 / 退化 / Esc

    func testOneLineAParallelPairAndEscapeAllApplyNothing() throws {
        let (session, tool) = try makeTool()
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        let rows = session.history.snapshots.count
        let v = generator(.vertical, degrees: 8)
        let lines = pair(.vertical, vertical: v, horizontal: 0)

        // (a) one line: not enough information.
        XCTAssertNil(draw(tool, from: lines[0].0, to: lines[0].1), "337 ⑥ 一条线不应用")
        XCTAssertEqual(tool.guideLineFailure, .notEnoughLines)
        XCTAssertEqual(session.edit.geometry.perspectiveVertical, 0, accuracy: 1e-12)

        // (b) a second line 0.1° from the first — 337 §2.6 used to call this 「没有信息」 and refuse
        // the whole pair. **367 changed the rule** (用户：「角度很小也直接走校正，也不需要提示」):
        // a small angle is a small correction (measured v ≈ −12.5, s ≈ −4.7°), not a failure.
        // (Shifted sideways first, so the two are different lines.)
        let a0 = lines[0].0, b0 = lines[0].1
        let shifted = (CGPoint(x: a0.x + 80, y: a0.y), CGPoint(x: b0.x + 80, y: b0.y))
        let nearlyParallel = (turned(shifted.0, by: 0.1), turned(shifted.1, by: 0.1))
        XCTAssertNotNil(draw(tool, from: nearlyParallel.0, to: nearlyParallel.1),
                        "367 ⑥ 0.1° 的小夹角也要走校正")
        XCTAssertNil(tool.guideLineFailure, "367 ⑥ 不许再报 nearParallel")
        XCTAssertFalse(tool.guideLineStatusText?.contains("几乎平行") ?? false,
                       "367 ⑥ 状态行不许再提示「几乎平行」")
        XCTAssertEqual(tool.guideLines.count, 2, "367 ⑥ 第二条线留在画布上")
        let solution = try XCTUnwrap(tool.guideLineSolution)
        XCTAssertEqual(solution.vertical, -12.54, accuracy: 0.5, "367 ⑥ 0.1° 的校正值")
        XCTAssertEqual(solution.straightenDelta, -4.72, accuracy: 0.5, "367 ⑥ 摆正")
        XCTAssertLessThanOrEqual(solution.worstResidual, 0.05, "367 ⑥ 残差 ≤0.05°")

        // (c) Esc: the gesture stops, nothing more is written. **361 §2.2** flipped the other half
        // of this: since the lines are document data, Esc keeps the ones that were kept — the single
        // accepted line of (a) is still there, which is 「Esc 退出引导线模式，线保留」. 367 — (b) did
        // write one row, so the count is `rows + 1` (the old expectation was `rows`).
        _ = tool.setGuideLinesArmed(true)
        let keptBeforeEscape = tool.guideLines.count
        XCTAssertTrue(tool.cancelGuideLines(), "337 ⑥ Esc 收掉工具")
        XCTAssertFalse(tool.isGuideLinesArmed)
        XCTAssertEqual(tool.guideLines.count, keptBeforeEscape, "361 ⑥ Esc 不清线")
        XCTAssertEqual(session.history.snapshots.count, rows + 1, "367 ⑥ 0.1° 校正已写一条历史，Esc 不再写")
        print("367 ⑥ 退化改口径: 1 条 → notEnoughLines；0.1° → 已校正（提示「\(tool.guideLineStatusText ?? "-")」）；"
              + "Esc → 行数 \(session.history.snapshots.count)（画前 \(rows)，0.1° 校正 +1）· 夹角 "
              + String(format: "%.2f°", abs(GuideLinesSolve.fold(angle(nearlyParallel.0, nearlyParallel.1)
                                                                 - angle(lines[0].0, lines[0].1)))))
    }

    // MARK: - ⑦ the row and its glyph

    func testTheGuideLinesRowUsesThePerspectiveGlyphAndSitsUnderDrawStraighten() throws {
        let (panel, loupe) = try transformPanel(width: 330)
        defer { panel.window.contentView = nil }
        XCTAssertTrue(loupe.isCropToolActive || loupe.beginCropTool())

        let correction = try XCTUnwrap(panel.row(CropCardID.correctionCard))
        let guide = try XCTUnwrap(panel.row(CorrectionCardRow.guideLines.probeID),
                                  "337 ⑦ 引导线这一行没有画出来")
        let draw = try XCTUnwrap(panel.row(CorrectionCardRow.drawStraighten.probeID))
        let vertical = try XCTUnwrap(panel.row(CorrectionCardRow.perspectiveVertical.probeID))
        XCTAssertTrue(correction.contains(CGPoint(x: guide.midX, y: guide.midY)),
                      "337 ⑦ 引線行必须在校正卡里")
        XCTAssertGreaterThan(guide.minY, draw.maxY - 1e-6, "337 ⑦ 引导线在画线拉直之下")
        XCTAssertLessThan(guide.maxY, vertical.minY, "337 ⑦ 引导线在垂直透视之上")

        let button = try XCTUnwrap(panel.view(GuideLinesButton.self,
                                              identifier: GuideLinesButton.identifierID),
                                   "337 ⑦ 引导线按钮不在树上")
        let symbols = [GuideLinesButton.symbol, DrawStraightenButton.symbol,
                       CropAspectRow.customSymbol]
        for symbol in symbols {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                            "337 ⑦ 本机必须有 \(symbol) 这个符号")
        }
        XCTAssertEqual(button.symbolName, "perspective", "337 ⑦ 引导线必须用 perspective")
        XCTAssertEqual(button.accessibilityLabel(), "引导线")
        XCTAssertEqual(Set(symbols).count, 3, "337 ⑦ level / ruler / perspective 三者互不相等")
        print("337 ⑦ 行 y \(guide.minY)·\(guide.height) · 图标 \(button.symbolName) · 三者 \(symbols)")
    }

    // MARK: - ⑩ a contradictory line is refused whole, a fifth is ignored

    /// Three lines that agree (2 竖 + 1 横) are applied; the fourth is the second horizontal line
    /// turned by **40°** — far more than the ±100 travel can absorb (the least-squares floor over
    /// the whole travel is 17.4°). Nothing is applied, the new line is withdrawn (red), and the
    /// reason is `outOfRange`. §2b.2: 「不许只应用一半」.
    ///
    /// 348 changed this fixture: it used to be 6°. Under 348's **pair** residual a 6° disagreement
    /// is not a disagreement at all — the two horizontals are only asked to be *parallel*, and `h`
    /// reaches that exactly (measured: h = +20.66, worst pair 6e−4°). That is the user's own
    /// complaint fixed, so the refusal this test is about has to be one the travel cannot reach.
    func testAContradictoryLineIsRefusedWholeAndAFifthLineIsIgnored() throws {
        let (session, tool) = try makeTool()
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        var v = generator(.vertical, degrees: 8)
        var h = generator(.horizontal, degrees: 8, other: v)
        for _ in 0..<12 {
            v = generator(.vertical, degrees: 8, other: h)
            h = generator(.horizontal, degrees: 8, other: v)
        }
        let vertical = pair(.vertical, vertical: v, horizontal: h)
        let horizontal = pair(.horizontal, vertical: v, horizontal: h)
        for (a, b) in vertical { _ = draw(tool, from: a, to: b) }
        XCTAssertNotNil(draw(tool, from: horizontal[0].0, to: horizontal[0].1),
                        "337 ⑩ 两竖一横应当先解出来")
        let accepted = (session.edit.geometry.perspectiveVertical,
                        session.edit.geometry.perspectiveHorizontal)
        let rows = session.history.snapshots.count
        XCTAssertNotEqual(accepted.0, 0, accuracy: 1e-9)

        // 353 — the travel doubled to ±400, and that is exactly the change this fixture feels: the
        // 40° turn that 347's ±200 refused (it asks for h ≈ +264) now **solves**. The widening is
        // the point of 353, so the test records the acceptance, not an older refusal.
        let wider = (turned(horizontal[1].0, by: 40), turned(horizontal[1].1, by: 40))
        XCTAssertNotNil(draw(tool, from: wider.0, to: wider.1),
                        "353 ⑩ 40° 的线在 ±400 内已可解（347 的 ±200 会判 outOfRange）")
        let acceptedWide = (session.edit.geometry.perspectiveVertical,
                            session.edit.geometry.perspectiveHorizontal)
        let rowsWide = session.history.snapshots.count
        print(String(format: "353 ⑩ 40° 线已接受: v %+.3f h %+.3f",
                     acceptedWide.0, acceptedWide.1))

        // The refusal that is still reachable at this travel is the classification's: a line that
        // leans out of both axes. It must be withdrawn whole — no state, no history, the four lines
        // already in place stay.
        let contradictory = (turned(horizontal[1].0, by: 78), turned(horizontal[1].1, by: 78))
        XCTAssertNil(draw(tool, from: contradictory.0, to: contradictory.1),
                     "337 ⑩ 无法归类的线不许应用")
        XCTAssertNotNil(tool.guideLineFailure, "337 ⑩ 拒了就要给原因")
        // 「标红撤回」只在解算失败那几条原因上有；`tooManyLines` 是分类阶段就拒了，没有待撤的红线。
        XCTAssertEqual(tool.guideLines.count, 4, "337 ⑩ 只撤新线，已经有效的那四条留着")
        XCTAssertEqual(session.edit.geometry.perspectiveVertical, acceptedWide.0, accuracy: 1e-12,
                       "337 ⑩ (v,h) 保持上一次有效值")
        XCTAssertEqual(session.edit.geometry.perspectiveHorizontal, acceptedWide.1, accuracy: 1e-12)
        XCTAssertEqual(session.history.snapshots.count, rowsWide, "337 ⑩ 不生效 = 不写历史")
        print("337 ⑩ 矛盾线: 原因 \(tool.guideLineFailure?.rawValue ?? "-") · "
              + "提示「\(tool.guideLineStatusText ?? "-")」 · v 仍 \(session.edit.geometry.perspectiveVertical) · "
              + "行数 \(session.history.snapshots.count)（\(rowsWide)）")

        // The ceiling: four lines accepted, the fifth (a third vertical) ignored with a reason.
        // (The session is held here on purpose: `CropToolController.session` is **weak**, so a
        // discarded session would leave every write a no-op and the second pair drawn on a screen the
        // user is not looking at.)
        let (session2, tool2) = try makeTool()
        XCTAssertTrue(tool2.setGuideLinesArmed(true))
        for (a, b) in vertical { _ = draw(tool2, from: a, to: b) }
        for (a, b) in horizontal { _ = draw(tool2, from: a, to: b) }
        XCTAssertEqual(tool2.guideLines.count, 4, "337 ⑩ 一竖一横两条一对应当都收下")
        let applied = tool2.guideLineApplyCount
        XCTAssertNil(draw(tool2, from: vertical[0].0, to: vertical[0].1), "337 ⑩ 第 5 条忽略")
        XCTAssertEqual(tool2.guideLineFailure, .tooManyLines)
        XCTAssertEqual(tool2.ignoredGuideLineCount, 1)
        XCTAssertEqual(tool2.guideLines.count, 4, "337 ⑩ 不接受第 5 条")
        XCTAssertEqual(tool2.guideLineApplyCount, applied, "337 ⑩ 第 5 条不产生新解")
        print("337 ⑩ 第 5 条: 忽略 · 提示「\(tool2.guideLineStatusText ?? "-")」 · 仍有 \(tool2.guideLines.count) 条"
              + " · (v,h) = (\(String(format: "%.2f", session2.edit.geometry.perspectiveVertical)), "
              + "\(String(format: "%.2f", session2.edit.geometry.perspectiveHorizontal)))")
    }

    // MARK: - ⑪ the canvas strategy (Constrain Crop, no new switch)

    func testTheDefaultInscriptionLeavesNoBlackPixelInTheExport() throws {
        // 317 ships this preference **off** (its own acceptance asserts 「默认关」), so the test turns
        // it on the way the user would — §2c's condition is 「若勾着」, and the inscription is gated
        // on it.
        let (session, tool) = try makeTool(staysInsidePixels: true)
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        XCTAssertTrue(tool.cropStaysInsidePixels)
        let v = generator(.vertical, degrees: 8)
        let lines = pair(.vertical, vertical: v, horizontal: 0)
        for (a, b) in lines { _ = draw(tool, from: a, to: b) }

        let map = PerspectiveMap(vertical: session.edit.geometry.perspectiveVertical,
                                horizontal: session.edit.geometry.perspectiveHorizontal)
        let geometry = tool.cropGeometry
        let quad = geometry.photoQuad()
        let frame = bounds(of: geometry.documentQuad(of: tool.draft.crop))
        let black = blackFraction(frame: frame, photo: quad)
        let extent = geometry.photoQuadExtent
        let canvas = geometry.canvas(.document)
        let export = geometry.canvas(.export)
        print(String(format: "337 ⑪ 不出像素=开: 黑像素 %.4f%% · 画布(文档) %d×%d · 四边形 AABB %.1f×%.1f"
                     + " · 导出画布 %d×%d · 导出框 %.1f×%.1f px",
                     black * 100, canvas.width, canvas.height, extent.width, extent.height,
                     export.width, export.height,
                     (frame[2].x - frame[0].x), (frame[2].y - frame[0].y)))
        XCTAssertEqual(black, 0, accuracy: 1e-9, "337 ⑪ 默认内切后导出黑像素必须是 0.000 %")
        XCTAssertLessThanOrEqual(abs(Double(canvas.width) - extent.width), 1,
                                 "337 ⑪ 画布 = 透视四边形 AABB（±1 px）")
        XCTAssertLessThanOrEqual(abs(Double(canvas.height) - extent.height), 1)
        XCTAssertTrue(map.hasWarp, "337 ⑪ 800 分钟后文档确实带着 keystone")

        // 取消勾选: the frame may stay on the black corners — the same rule as before, no new switch.
        let (session2, tool2) = try makeTool(staysInsidePixels: false)
        XCTAssertTrue(tool2.setGuideLinesArmed(true))
        XCTAssertFalse(tool2.cropStaysInsidePixels)
        for (a, b) in lines { _ = draw(tool2, from: a, to: b) }
        let geometry2 = tool2.cropGeometry
        let export2 = bounds(of: geometry2.documentQuad(of: tool2.draft.crop))
        let black2 = blackFraction(frame: export2, photo: geometry2.photoQuad())
        let canvas2 = geometry2.canvas(.document)
        print(String(format: "337 ⑪ 不出像素=关: 黑像素 %.4f%% · 画布 %d×%d · 导出 %.1f×%.1f px · 框仍整幅 %.2f×%.2f",
                     black2 * 100, canvas2.width, canvas2.height,
                     (export2[2].x - export2[0].x), (export2[2].y - export2[0].y),
                     tool2.draft.crop.width, tool2.draft.crop.height))
        XCTAssertGreaterThan(black2, 0.0001, "337 ⑪ 关掉勾选后黑角可以出现")
        XCTAssertEqual(tool2.draft.crop, .full, "337 ⑪ 关掉勾选就不内切（框不动）")
        XCTAssertEqual(session2.edit.geometry.perspectiveVertical, session.edit.geometry.perspectiveVertical,
                       accuracy: 1e-9, "337 ⑪ 勾选与否解出来的 v 是同一个")
    }

    /// The axis-aligned bounding box of a document-canvas quad. For a **canvas-spaced** frame the quad
    /// is already a rectangle (the export canvas itself); for a source-spaced one it is the warped
    /// rect, and its AABB is the canvas `CropMath.perspectiveCanvas` allocates — the region the file
    /// gets. One rule for both spaces.
    private func bounds(of quad: [DocumentPoint]) -> [DocumentPoint] {
        let xs = quad.map(\.x), ys = quad.map(\.y)
        let x0 = xs.min() ?? 0, x1 = xs.max() ?? 0
        let y0 = ys.min() ?? 0, y1 = ys.max() ?? 0
        return [DocumentPoint(x0, y0), DocumentPoint(x1, y0),
                DocumentPoint(x1, y1), DocumentPoint(x0, y1)]
    }

    /// The fraction of `frame` (document-canvas pixels, TL/TR/BR/BL) lying **outside** `photo` — the
    /// `000000` an export would contain. Bilinear samples over the frame's own quad, so it measures
    /// the region, not four corners.
    private func blackFraction(frame: [DocumentPoint], photo: [DocumentPoint],
                               samples: Int = 64) -> Double {
        guard frame.count == 4, photo.count == 4 else { return .nan }
        let tl = frame[0], tr = frame[1], br = frame[2], bl = frame[3]
        var outside = 0
        for j in 0..<samples {
            for i in 0..<samples {
                let u = (Double(i) + 0.5) / Double(samples)
                let v = (Double(j) + 0.5) / Double(samples)
                let x = (1 - u) * (1 - v) * tl.x + u * (1 - v) * tr.x + u * v * br.x + (1 - u) * v * bl.x
                let y = (1 - u) * (1 - v) * tl.y + u * (1 - v) * tr.y + u * v * br.y + (1 - u) * v * bl.y
                if !inside(x: x, y: y, quad: photo) { outside += 1 }
            }
        }
        return Double(outside) / Double(samples * samples)
    }

    private func inside(x: Double, y: Double, quad: [DocumentPoint]) -> Bool {
        var positive = false, negative = false
        for index in quad.indices {
            let a = quad[index], b = quad[(index + 1) % quad.count]
            let cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)
            if cross > 1e-9 { positive = true }
            if cross < -1e-9 { negative = true }
        }
        return !(positive && negative)
    }

    // MARK: - ⑫ reverse gate ①: the fit must start from the source, not the screen

    /// With a keystone already on the document, the stroke's screen angle is not the photograph's.
    /// The shipped path walks the endpoints back through `P⁻¹ · R⁻¹` and leaves the pair parallel;
    /// the gate uses the view points as if they were source pixels (the screen reading) and leaves
    /// degrees behind. Printed verbatim, then asserted both ways.
    func testTheFitMustMapBackToTheSourceNotMeasureTheScreen() throws {
        let v = generator(.vertical, degrees: 8)
        let lines = pair(.vertical, vertical: v, horizontal: 0)
        let current = PerspectiveMap(vertical: 25, horizontal: 0)

        // Shipped: the endpoints come back through the current composite inverse.
        let (session, tool) = try makeTool(perspective: (25, 0))
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        for (a, b) in lines { _ = draw(tool, from: a, to: b, current: current) }
        let shipped = PerspectiveMap(vertical: session.edit.geometry.perspectiveVertical,
                                     horizontal: session.edit.geometry.perspectiveHorizontal)
        let shippedAfter = renderedConvergence(lines, perspective: shipped.hasWarp ? shipped : nil)
        let shippedValue = session.edit.geometry.perspectiveVertical

        // Gate: no inverse — the stroke is used as if it were in source pixels.
        let (session2, tool2) = try makeTool(perspective: (25, 0))
        XCTAssertTrue(tool2.setGuideLinesArmed(true))
        tool2.guideLinesMapBackToSource = false
        for (a, b) in lines { _ = draw(tool2, from: a, to: b, current: current) }
        let gated = PerspectiveMap(vertical: session2.edit.geometry.perspectiveVertical,
                                   horizontal: session2.edit.geometry.perspectiveHorizontal)
        let gatedAfter = renderedConvergence(lines, perspective: gated.hasWarp ? gated : nil)
        let gatedValue = session2.edit.geometry.perspectiveVertical

        print(String(format: "337 ⑫① 本单: v %+8.3f → 屏幕上剩 %.4f°", shippedValue, shippedAfter))
        print(String(format: "337 ⑫① 去掉映回源空间: v %+8.3f → 屏幕上剩 %.4f°", gatedValue, gatedAfter))
        XCTAssertLessThanOrEqual(shippedAfter, 0.05, "337 ⑫① 本单必须平行")
        XCTAssertGreaterThan(gatedAfter, 0.5, "337 ⑫① 直接用屏幕端点解就会留下肉眼可见的歪")
        XCTAssertNotEqual(gatedValue, shippedValue, accuracy: 1e-6)
    }

    // MARK: - ⑫ reverse gate ②: a 1° tolerance must fail the 0.05° acceptance

    /// The tolerance is the fit's **acceptance** threshold (§2b.2), so widening it to 1° is what lets
    /// a 1°-scale error through. The fixture is three lines of one direction with the third 0.4° off
    /// the second — a set whose least-squares floor is 0.400° and which therefore puts the tolerance
    /// in charge:
    ///
    ///   · 0.05° (shipped): no `(v,h)` brings every **pair** inside it → `inconsistent`, nothing
    ///     applied;
    ///   · 1° (gate): the same set is accepted, and the two lines the user drew stay 0.4° apart —
    ///     eight times too wide for acceptance ①, which is the red the gate asks for.
    ///
    /// (On a *perfectly* consistent pair Gauss–Newton reaches 1e−4° whatever the tolerance says, so a
    /// gate built on that fixture would prove nothing: this one puts the tolerance in charge, which is
    /// the only place it can matter.)
    ///
    /// 348 moved this gate off the window and onto the pure fit: three lines on one axis is not a
    /// gesture the card allows (2 per direction, §2b.1), so the set that has a least-squares floor
    /// between 0.05° and 1° can only be built below the gesture. The tolerance is still the only
    /// difference between the two fits, which is what the gate is about.
    func testWithAToleranceOfOneDegreeTheAcceptanceGoesRed() throws {
        var v = generator(.vertical, degrees: 8)
        var h = generator(.horizontal, degrees: 8, other: v)
        for _ in 0..<12 {
            v = generator(.vertical, degrees: 8, other: h)
            h = generator(.horizontal, degrees: 8, other: v)
        }
        let pair = pair(.vertical, vertical: v, horizontal: h)
        // The third line: the second vertical turned by 0.4° about the frame's centre. Two pair rows,
        // one knob — 0.4° is what is left over, whatever `v` is chosen.
        let third = (turned(pair[1].0, by: 0.4), turned(pair[1].1, by: 0.4))
        let verticalPair = pair
        let lines = [verticalPair[0], verticalPair[1], third].map {
            GuideLine(start: $0.0, end: $0.1, sourceStart: $0.0, sourceEnd: $0.1,
                      viewAngle: angle($0.0, $0.1),
                      axis: GuideLinesSolve.axis(forFoldedAngle: angle($0.0, $0.1)))
        }

        // Shipped tolerance: the set is refused and there is no answer to write.
        let shipped = GuideLinesSolve.fit(lines: lines,
                                          current: PerspectiveMap(vertical: 0, horizontal: 0),
                                          source: source, straightenDegrees: 0)
        XCTAssertNil(shipped.solution, "337 ⑫② 0.4° 的第三条线在 0.05° 容差下必须被拒")
        XCTAssertEqual(shipped.failure, .inconsistent)

        // The gate: 1° tolerance, same three lines.
        let gate = GuideLinesSolve.fit(lines: lines,
                                       current: PerspectiveMap(vertical: 0, horizontal: 0),
                                       source: source, straightenDegrees: 0, tolerance: 1.0)
        let solution = try XCTUnwrap(gate.solution, "337 ⑫② 1° 容差下这一组被接受了")
        let map = PerspectiveMap(vertical: solution.vertical, horizontal: solution.horizontal)
        let after = renderedConvergence([pair[0], pair[1]], perspective: map.hasWarp ? map : nil)
        print(String(format: "337 ⑫② 0.05°: 拒绝（inconsistent，最坏两两 %.4f°）· 1°: 接受 v %+.3f h %+.3f，"
                     + "最坏两两 %.4f° > 0.05° · 竖对 %.4f°（要求 ≤0.05° → 红）",
                     shipped.measuredWorstPairwise ?? .nan, solution.vertical, solution.horizontal,
                     solution.worstResidual, after))
        XCTAssertLessThanOrEqual(solution.worstResidual, 1.0, "宽容差下这次解「成功」了")
        XCTAssertGreaterThan(solution.worstResidual, 0.05,
                             "337 ⑫② 1° 容差放过了 >0.05° 的残差 —— 验收「所有残差 ≤0.05°」必须红")
        XCTAssertGreaterThan(after, 0.05, "337 ⑫② 应用后仍有一对线歪着 >0.05°")
    }


    // MARK: - 347 · 行程 ±200（强度分母仍是 100）

    /// **347 ⑤** — 面板真正交给行的行程是 ±200：键入 `200` 落在文档里（不是被夹到 100），读数
    /// `+200`，双击标题复位回 0。
    ///
    /// The range is read from the **field SwiftUI built** (`NumberFieldController.row.range`) rather
    /// than from a constant here, so a panel left at ±100 is red no matter what core says.
    func testThePerspectiveSlidersTravelToTheLimit() throws {
        let (panel, _) = try transformPanel(width: 330)
        defer { panel.window.contentView = nil }
        let session = try XCTUnwrap(panel.session)
        TestWindows.show(panel.window, key: true)

        let vertical = try XCTUnwrap(panel.view(NumberTextField.self,
                                                identifier: "inspector.crop.perspective.vertical"),
                                     "347 ⑤ 垂直透视的读数没有画出来")
        let horizontal = try XCTUnwrap(panel.view(NumberTextField.self,
                                                  identifier: "inspector.crop.perspective.horizontal"),
                                       "347 ⑤ 水平透视的读数没有画出来")
        let row = try XCTUnwrap(vertical.controller?.row, "347 ⑤ 读数没有控制器")
        let rowH = try XCTUnwrap(horizontal.controller?.row)
        print("347 ⑤ 滑杆行程: 垂直 \(row.range) · 水平 \(rowH.range) · 读数格式 \(row.format)")
        XCTAssertEqual(row.range, -500 ... 500, "353b ⑤ 垂直透视的行程必须是 −500…500")
        XCTAssertEqual(rowH.range, -500 ... 500, "353b ⑤ 水平透视的行程必须是 −500…500")
        XCTAssertEqual(row.range, -PerspectiveMap.limit ... PerspectiveMap.limit,
                       "347 ⑤ 滑杆 = 夹取那一个数")

        // 键入 200 — the readout's own commit path (the drag's, in the drag's order).
        let rowsBeforeTyping = session.history.count
        XCTAssertTrue(panel.window.makeFirstResponder(vertical), "347 ⑤ 读数必须能成为第一响应者")
        let editor = try XCTUnwrap(vertical.currentEditor() as? NSTextView, "347 ⑤ 没有 field editor")
        editor.insertText("400", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "400")
        vertical.controller?.commit()

        print("353 ⑤ 键入 400 → 文档 \(session.edit.geometry.perspectiveVertical)"
              + " · 读数「\(vertical.stringValue)」· 强度 "
              + String(format: "%.17g", PerspectiveMap(vertical: 400, horizontal: 0).verticalStrength))
        XCTAssertEqual(session.edit.geometry.perspectiveVertical, 400, accuracy: 1e-12,
                       "353 ⑤ 400 必须落进文档，不许被夹到 200")
        XCTAssertEqual(vertical.stringValue, "+400", "353 ⑤ 读数必须是 +400")

        // 双击标题复位：透视这一节的两个字段一起回 0，至少一条历史（拖动的合并行可能还开着，
        // 所以这里说的是「有东西被记下」而不是「恰好 +1」——「一次双击 = 一条」由 179/214 钉住）。
        let resets = PanelResets(session: session)
        let rows = session.history.count
        XCTAssertTrue(resets.reset(fields: CropSection.perspective.fields, label: "透视"),
                      "347 ⑤ 双击「透视」必须有东西可复位")
        XCTAssertEqual(session.edit.geometry.perspectiveVertical, 0, accuracy: 1e-12, "347 ⑤ 回 0")
        XCTAssertEqual(session.edit.geometry.perspectiveHorizontal, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(session.history.count, rows, "347 ⑤ 复位必须留下一条历史")
        let afterReset = session.history.count
        XCTAssertFalse(resets.reset(fields: CropSection.perspective.fields, label: "透视"),
                       "347 ⑤ 已经是 0 了，不许写空快照")
        XCTAssertEqual(session.history.count, afterReset, "347 ⑤ 空复位不写历史")
        print("347 ⑤ 双击「透视」→ v = \(session.edit.geometry.perspectiveVertical)"
              + " · 历史 \(rowsBeforeTyping)→\(rows)→\(afterReset)"
              + "（键入 200 +\(rows - rowsBeforeTyping) · 复位 +\(afterReset - rows)"
              + " · 第二次 +\(session.history.count - afterReset)）")
    }

    /// **347 ⑥** — 引导线求解器不再在 100 处停住：一张**需要 v = 150** 才能摆正的图。
    ///
    /// The fixture is 337's own generator, at a stop the old travel could not reach: two exact
    /// parallels under `v = +150`, mapped back to source. The fit has to come back within ±1 of it
    /// and leave the pair ≤ 0.05°, which it could not do while `PerspectiveMap.limit` was 100 (the
    /// solve then returned `.outOfRange` at the cap).
    func testTheFitGoesPastOneHundredWhenThePictureNeedsIt() throws {
        let (session, tool) = try makeTool()
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        let v = 150.0
        let lines = pair(.vertical, vertical: v, horizontal: 0)
        let before = renderedConvergence(lines, perspective: nil)
        // What the old travel could do — printed, so 「不再停住」 is a number, not a claim.
        let atTheOldCap = renderedConvergence(lines, perspective: PerspectiveMap(vertical: 100,
                                                                                horizontal: 0))
        print(String(format: "347 ⑥ fixture: 贴前 %.6f° · 滑杆停在旧上限 100 时仍剩 %.6f°", before,
                     atTheOldCap))
        XCTAssertGreaterThan(atTheOldCap, 0.05, "347 ⑥ 这张图在 100 处确实摆不正（否则这条测试什么也没证明）")

        XCTAssertNil(draw(tool, from: lines[0].0, to: lines[0].1), "347 ⑥ 一条线还解不出来")
        let applied = draw(tool, from: lines[1].0, to: lines[1].1)
        XCTAssertNotNil(applied, "347 ⑥ 两条线应当解出来：\(String(describing: tool.guideLineFailure))")
        let solution = try XCTUnwrap(applied)
        let map = PerspectiveMap(vertical: session.edit.geometry.perspectiveVertical,
                                 horizontal: session.edit.geometry.perspectiveHorizontal)
        let after = renderedConvergence(lines, perspective: map.hasWarp ? map : nil)
        print(String(format: "347 ⑥ 求解 v %+8.3f（h %+8.3f）· 残差 %.6f° · 应用后 %.6f° · "
                     + "%d 次迭代 · 提示「%@」",
                     solution.vertical, solution.horizontal, solution.worstResidual, after,
                     solution.iterations, tool.guideLineStatusText ?? "-"))

        XCTAssertEqual(solution.vertical, v, accuracy: 1, "347 ⑥ 求解值必须 ≈ +150")
        XCTAssertGreaterThan(solution.vertical, 100, "347 ⑥ 不再在 100 处停住")
        XCTAssertLessThanOrEqual(solution.worstResidual, 0.05, "347 ⑥ 残差 ≤ 0.05°")
        XCTAssertLessThanOrEqual(after, 0.05, "347 ⑥ 应用后两条线必须平行")
        XCTAssertEqual(session.edit.geometry.perspectiveHorizontal, 0, accuracy: 1e-12)
    }

    /// **347 ⑦** — `v = 200` + 「不出像素」→ 导出黑像素 0.000 %；关掉 → 有黑角。
    ///
    /// 337 ⑪'s two-sided measurement, at the new end of the travel: the inscription is what keeps a
    /// doubled keystone out of the file, and with the box off the same frame is allowed to sit on the
    /// `000000` corners.
    func testTwoHundredLeavesNoBlackPixelWithConstrainCrop() throws {
        let (_, tool) = try makeTool(perspective: (200, 0), staysInsidePixels: true)
        XCTAssertTrue(tool.cropStaysInsidePixels)
        let geometry = tool.cropGeometry
        let frame = bounds(of: geometry.documentQuad(of: tool.draft.crop))
        let black = blackFraction(frame: frame, photo: geometry.photoQuad())
        let canvas = geometry.canvas(.document)
        print(String(format: "347 ⑦ 不出像素=开: v 200 · 黑像素 %.4f%% · 画布 %d×%d · 框 %.3f×%.3f（文档单位）",
                     black * 100, canvas.width, canvas.height,
                     frame[2].x - frame[0].x, frame[2].y - frame[0].y))
        XCTAssertEqual(black, 0, accuracy: 1e-9, "347 ⑦ 内切之后导出必须没有黑像素")

        let (_, tool2) = try makeTool(perspective: (200, 0), staysInsidePixels: false)
        XCTAssertFalse(tool2.cropStaysInsidePixels)
        let geometry2 = tool2.cropGeometry
        let frame2 = bounds(of: geometry2.documentQuad(of: tool2.draft.crop))
        let black2 = blackFraction(frame: frame2, photo: geometry2.photoQuad())
        print(String(format: "347 ⑦ 不出像素=关: 黑像素 %.4f%% · 框仍整幅 %.2f×%.2f",
                     black2 * 100, tool2.draft.crop.width, tool2.draft.crop.height))
        XCTAssertGreaterThan(black2, 0.0001, "347 ⑦ 关掉勾选后黑角可以出现")
        XCTAssertEqual(tool2.draft.crop, .full, "347 ⑦ 关掉勾选就不内切（框不动）")
    }

    // MARK: - the panel harness (334's, trimmed to what ⑦ reads)

    private struct Panel {
        let host: NSHostingView<InspectorView>
        let window: NSWindow
        let state: InspectorWorkspaceState
        /// 347 — the session behind the card, so a test can read back what a typed slider value wrote.
        var session: CatalogSession?

        var cards: InspectorCardsProbe {
            views(ofType: InspectorCardsProbe.self).first ?? InspectorCardsProbe(frame: .zero)
        }

        var probes: [CropRowProbe] { views(ofType: CropRowProbe.self) }

        func row(_ id: String) -> CGRect? {
            probes.first { $0.rowID == id }.map { $0.convert($0.bounds, to: host) }
        }

        func view<T: NSView>(_ type: T.Type, identifier: String) -> T? {
            views(ofType: type).first { $0.accessibilityIdentifier() == identifier }
        }

        func views<T: NSView>(ofType: T.Type) -> [T] {
            var found: [T] = []
            func walk(_ root: NSView) {
                if let match = root as? T { found.append(match) }
                for sub in root.subviews { walk(sub) }
            }
            walk(host)
            return found
        }
    }

    private func transformPanel(width: CGFloat) throws -> (Panel, LoupeController) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view

        _ = NSApplication.shared
        let state = InspectorWorkspaceState()
        let host = NSHostingView(rootView: InspectorView(session: session, loupe: loupe,
                                                         workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let window = TestWindows.make(contentRect: host.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.4)
        host.layoutSubtreeIfNeeded()
        state.select(.transform)
        let panel = Panel(host: host, window: window, state: state, session: session)
        _ = try waitFor { panel.cards.cardIDs == ["crop", "transformCorrection", "angle"] }
        return (panel, loupe)
    }

    @discardableResult
    private func waitFor(_ predicate: () -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if predicate() { return true }
            CropUITestSupport.pump(0.05)
        }
        return predicate()
    }
}
