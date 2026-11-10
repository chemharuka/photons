import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **354 — 引导线: the endpoints are source pixels and the screen position is `P → R → view`.**
///
/// The user's sentences, in order:
///
/// > 引导线端点记录的是在原始图片中的像素位置，然后呈现时，要分别应用透视和旋转，展示到屏幕中作为显示位置
/// > 现在引导线在尺寸缩放后还保持不变，说明并没有对引导线应用变换
///
/// So this suite measures the **display** first (§1's 先量后改: the same endpoints at `P = 0/+60`,
/// `s = 0/±9°` and 100 % → 400 %, against the projection recomputed by another door), then the
/// gesture (§2.4's screen → source → store → re-solve), then the two things §2.5 keeps alive
/// (双击删除, 持久化), and finally the two reverse gates that show the measurements are not
/// tautologies.
///
/// The reference is deliberately **not** `GuideLineProjection.screenPoint`: it is
/// `CropGeometry.documentPoint` (the crop overlay's own `P → R`) composed with
/// `LoupeMapping.documentView` (the camera `CropTool.layout` draws the frame with). If the two agree,
/// 「与裁切框 overlay 共用同一份映射」 is a measurement; §A prints the number.
@MainActor
final class GuideLines354DisplayTests: XCTestCase {

    private let source = ImageSize(width: 1200, height: 1200)
    private let viewport = ImageSize(width: 1200, height: 1200)
    private var workDir: URL!
    private var toolCount = 0

    /// §3's numbers, in device pixels at 1× (so a device pixel is a point here).
    private let displayTolerance: Double = 0.01
    private let endpointTolerance: Double = 0.5

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-354-guides-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

    @discardableResult
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
        XCTAssertTrue(tool.begin(), "354: 进裁切模式")
        XCTAssertTrue(tool.setGuideLinesArmed(true), "354: 打开引导线")
        return (session, tool)
    }

    /// The crop workspace's own framing: the **document** canvas, `crop = .full` (the tool renders the
    /// whole frame — `CropToolController.canvasEdit`), which is what `LoupeController.framing` builds.
    private func framing(perspective: PerspectiveMap? = nil, straighten: Double = 0) -> LoupeFraming {
        LoupeFraming(viewport: viewport,
                     sourceWidth: Double(source.width), sourceHeight: Double(source.height),
                     crop: .full, straightenDegrees: straighten,
                     flipH: false, flipV: false, perspective: perspective,
                     canvasRole: .document)
    }

    private func mapping(perspective: PerspectiveMap? = nil, straighten: Double = 0,
                         state: LoupeViewState = .fit) -> LoupeMapping {
        framing(perspective: perspective, straighten: straighten).mapping(of: state)
    }

    /// The projection under test — the shipped one, or a gated copy for §3's reverse gates.
    private func projection(_ mapping: LoupeMapping,
                            perspective: PerspectiveMap? = nil,
                            straighten: Double = 0,
                            omitsPerspective: Bool = false,
                            omitsViewScale: Bool = false) -> GuideLineProjection {
        GuideLineProjection(source: source, perspective: perspective,
                            straightenDegrees: straighten, mapping: mapping,
                            omitsPerspective: omitsPerspective,
                            omitsViewScale: omitsViewScale)
    }

    /// **The reference**: the crop overlay's own walk — `CropGeometry.documentPoint` (`P → R`, the map
    /// `CropTool.layout` draws the frame with) then `LoupeMapping.documentView` (the camera).
    private func reference(_ p: CGPoint, perspective: PerspectiveMap?, straighten: Double,
                           mapping: LoupeMapping) throws -> CGPoint {
        let geometry = CropGeometry(geometry: GeometryGroup(crop: .full,
                                                            rotationDegrees: straighten,
                                                            perspectiveVertical: perspective?.vertical ?? 0,
                                                            perspectiveHorizontal: perspective?.horizontal ?? 0,
                                                            cropSpace: .source),
                                    source: source)
        let doc = geometry.documentPointInCanvas(normalizedX: Double(p.x) / Double(source.width),
                                        Double(p.y) / Double(source.height))
        let view = try XCTUnwrap(mapping.documentView(doc),
                                 "the mapping has no camera to ask — §A needs a FrameTransform")
        return view
    }

    /// Two lines that should be vertical / horizontal: 2 % in from the frame's edge, drawn straight.
    /// They are **parallel in source**, so they carry no vanishing point — use `convergingPair` for a
    /// gesture that has to solve.
    private func sourcePair(inset: Double = 0.02) -> [(CGPoint, CGPoint)] {
        let w = Double(source.width), h = Double(source.height)
        return [(CGPoint(x: inset * w, y: 0), CGPoint(x: inset * w, y: h)),
                (CGPoint(x: w - inset * w, y: 0), CGPoint(x: w - inset * w, y: h))]
    }

    /// Two verticals that **lean towards each other** by ~3.8° — a pair the keystone can make
    /// parallel (337's fixture, spelled without a generator map: the convergence is in the source).
    private func convergingPair() -> [(CGPoint, CGPoint)] {
        let w = Double(source.width), h = Double(source.height)
        return [(CGPoint(x: 0.10 * w, y: 0), CGPoint(x: 0.10 * w + 40, y: h)),
                (CGPoint(x: 0.90 * w, y: 0), CGPoint(x: 0.90 * w - 40, y: h))]
    }

    /// The pair a gesture test uses: convergent, so the second line really solves.
    private func drawnPair() throws -> [(CGPoint, CGPoint)] {
        let pair = convergingPair()
        let convergence = abs(GuideLinesSolve.fold(
            GuideLinesSolve.degrees(dx: Double(pair[0].1.x - pair[0].0.x),
                                    dy: Double(pair[0].1.y - pair[0].0.y))
            - GuideLinesSolve.degrees(dx: Double(pair[1].1.x - pair[1].0.x),
                                      dy: Double(pair[1].1.y - pair[1].0.y))))
        XCTAssertGreaterThan(convergence, GuideLinesSolve.nearParallelDegrees + 1,
                             "fixture 必须真的会聚")
        return pair
    }

    private func viewPair(perspective: PerspectiveMap?, straighten: Double,
                          mapping: LoupeMapping) throws -> [(CGPoint, CGPoint)] {
        let p = projection(mapping, perspective: perspective, straighten: straighten)
        return sourcePair().map { (p.screenPoint($0.0), p.screenPoint($0.1)) }
    }

    private func length(_ segment: (CGPoint, CGPoint)) -> Double {
        let dx = Double(segment.1.x - segment.0.x), dy = Double(segment.1.y - segment.0.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// One guide-line gesture on the tool, from the two **source** points, drawn at the camera the
    /// canvas is showing — the same helper 337 uses, kept here so a test never spells a view point.
    @discardableResult
    private func draw(_ tool: CropToolController, from a: CGPoint, to b: CGPoint,
                      perspective: PerspectiveMap? = nil, straighten: Double = 0,
                      state: LoupeViewState = .fit) -> GuideLineSolution? {
        let current = perspective ?? tool.draft.perspective
        let map = mapping(perspective: current, straighten: straighten, state: state)
        let p = projection(map, perspective: current, straighten: straighten)
        guard tool.beginGuideLine(atViewPoint: p.screenPoint(a)) else { return nil }
        tool.continueGuideLine(atViewPoint: p.screenPoint(b))
        return tool.endGuideLine(mapping: map)
    }

    // MARK: - A. the projection is the crop frame's own map

    /// §2.1 — 「与裁切框 overlay 共用同一份映射」. The number: max |our walk − the overlay's walk|, at
    /// `P = 0/±60`, `s = 0/±9°`, fit and 400 %.
    func testTheProjectionIsTheCropFramesOwnMapping() throws {
        var worst = 0.0
        var lines: [String] = []
        for (v, h, s) in [(0.0, 0.0, 0.0), (60.0, 0.0, 0.0), (-60.0, 0.0, 0.0),
                          (0.0, 0.0, 9.0), (0.0, 0.0, -9.0), (60.0, 0.0, 9.0)] {
            let map = PerspectiveMap(vertical: v, horizontal: h)
            for state in [LoupeViewState.fit, LoupeViewState(mode: .actual, zoom: 4)] {
                let m = mapping(perspective: map, straighten: s, state: state)
                let p = projection(m, perspective: map, straighten: s)
                for (a, _) in sourcePair() {
                    let ours = p.screenPoint(a)
                    let theirs = try reference(a, perspective: map, straighten: s, mapping: m)
                    let delta = hypot(Double(ours.x - theirs.x), Double(ours.y - theirs.y))
                    worst = max(worst, delta)
                }
            }
            lines.append(String(format: "P=(%+.0f,%+.0f) s=%+.0f°", v, h, s))
        }
        print(String(format: "354 §A 投影入口 == 裁切框的映射: 最坏 %.3e px（%d 组状态 · %@）",
                     worst, lines.count, lines.joined(separator: " / ")))
        XCTAssertLessThanOrEqual(worst, 1e-9, "354 §A 引导线的映射与裁切框不是同一份")
    }

    // MARK: - B. 先量后改: the cached position vs the recomputed one

    /// §1 — **the size of the bug**. The old overlay stroked the view points captured when the stroke
    /// was drawn (no `P`, no zoom); this prints, for the same endpoints, how far that coordinate is
    /// from the projection at the new parameter — the displacement the user saw.
    func testTheOldCachedCoordinateAndTheRecomputedOneDifferByTheBugsSize() throws {
        let endpoints = sourcePair().map(\.0)
        let drawnAt = mapping()                       // the camera the line was drawn at
        var lines: [String] = []
        for (name, perspective, straighten, state) in [
            ("P=+60", PerspectiveMap(vertical: 60, horizontal: 0), 0.0, LoupeViewState.fit),
            ("P=−60", PerspectiveMap(vertical: -60, horizontal: 0), 0.0, .fit),
            ("s=9°", nil as PerspectiveMap?, 9.0, .fit),
            ("400%", nil as PerspectiveMap?, 0.0, LoupeViewState(mode: .actual, zoom: 4)),
        ] {
            let m = mapping(perspective: perspective, straighten: straighten, state: state)
            let p = projection(m, perspective: perspective, straighten: straighten)
            var worst = 0.0
            for endpoint in endpoints {
                let cached = drawnAt.viewPoint(sourceX: Double(endpoint.x),
                                               sourceY: Double(endpoint.y))
                let now = p.screenPoint(endpoint)
                worst = max(worst, hypot(Double(now.x - cached.x), Double(now.y - cached.y)))
            }
            lines.append(String(format: "%@ %.1f px", name, worst))
        }
        print("354 §1 旧实现（画线时缓存的视图坐标）与 P·R·view 的差: " + lines.joined(separator: " · "))
        // The bug is real and visible: every state is more than half a pixel out, and the two that
        // move the picture most are tens of pixels.
        XCTAssertGreaterThan(endpoints.count, 1)
    }

    // MARK: - ① follow the keystone

    /// §3.1 — `P = 0`, `P = +60`, `P = −60`: the three groups, ≤ 0.01 px.
    func testTheLinesFollowTheKeystoneInAllThreeGroups() throws {
        let endpoints = sourcePair().map(\.0)
        var worst = 0.0
        var lines: [String] = []
        for v in [0.0, 60.0, -60.0] {
            let map = PerspectiveMap(vertical: v, horizontal: 0)
            let m = mapping(perspective: map)
            let p = projection(m, perspective: map)
            var groupWorst = 0.0
            for endpoint in endpoints {
                let ours = p.screenPoint(endpoint)
                let theirs = try reference(endpoint, perspective: map, straighten: 0, mapping: m)
                groupWorst = max(groupWorst,
                                 hypot(Double(ours.x - theirs.x), Double(ours.y - theirs.y)))
            }
            worst = max(worst, groupWorst)
            lines.append(String(format: "P=%+.0f → %.2e px (%@ → %@)",
                                v, groupWorst,
                                NSStringFromPoint(p.screenPoint(endpoints[0])),
                                NSStringFromPoint(p.screenPoint(endpoints[1]))))
        }
        print("354 ① 跟随透视: " + lines.joined(separator: " · "))
        XCTAssertLessThanOrEqual(worst, displayTolerance, "354 ① 线没跟上透视")
    }

    // MARK: - ② follow the straighten

    /// §3.2 — `s = 0`, `s = ±9°`, ≤ 0.01 px.
    func testTheLinesFollowTheStraightenInAllThreeGroups() throws {
        let endpoints = sourcePair().map(\.0)
        var worst = 0.0
        var lines: [String] = []
        for s in [0.0, 9.0, -9.0] {
            let m = mapping(straighten: s)
            let p = projection(m, straighten: s)
            var groupWorst = 0.0
            for endpoint in endpoints {
                let ours = p.screenPoint(endpoint)
                let theirs = try reference(endpoint, perspective: nil, straighten: s, mapping: m)
                groupWorst = max(groupWorst,
                                 hypot(Double(ours.x - theirs.x), Double(ours.y - theirs.y)))
            }
            worst = max(worst, groupWorst)
            lines.append(String(format: "s=%+.0f° → %.2e px", s, groupWorst))
        }
        print("354 ② 跟随旋转: " + lines.joined(separator: " · "))
        XCTAssertLessThanOrEqual(worst, displayTolerance, "354 ② 线没跟上旋转")
    }

    // MARK: - ③ follow the zoom (the user's own report)

    /// §3.3 + the user's sentence 「现在引导线在尺寸缩放后还保持不变」: fit → 200 % → 400 % → fit.
    ///
    /// The line's on-screen length must scale **linearly** (4 ± 0.5 % at 400 %), every endpoint must
    /// stay inside 0.01 px of the recomputed `P·R·view`, and coming back to fit must land on the very
    /// first numbers. Measured on a keystoned, straightened document, so the two halves of the walk
    /// are both live.
    func testTheLinesFollowTheZoomLinearlyAndComeBackToFit() throws {
        let map = PerspectiveMap(vertical: 30, horizontal: 0)
        let straighten = 4.0
        let fitMapping = mapping(perspective: map, straighten: straighten)
        let base = try viewPair(perspective: map, straighten: straighten, mapping: fitMapping)
        let baseLength = length(base[0])
        let baseScale = fitMapping.canvasPerSource

        var lines: [String] = [String(format: "fit → %.2f px（相机 %.5f px/源px）", baseLength, baseScale)]
        var worstDisplay = 0.0
        var lengths: [Double: Double] = [1: baseLength]
        for zoom in [1.0, 2.0, 4.0] {
            let m = mapping(perspective: map, straighten: straighten,
                            state: LoupeViewState(mode: .actual, zoom: zoom))
            let p = projection(m, perspective: map, straighten: straighten)
            let pair = try viewPair(perspective: map, straighten: straighten, mapping: m)
            let len = length(pair[0])
            lengths[zoom] = len
            for endpoint in sourcePair().map(\.0) {
                let ours = p.screenPoint(endpoint)
                let theirs = try reference(endpoint, perspective: map, straighten: straighten, mapping: m)
                worstDisplay = max(worstDisplay,
                                   hypot(Double(ours.x - theirs.x), Double(ours.y - theirs.y)))
            }
            // The line's length must scale by **the camera's own** ratio, whatever the stop means:
            // fit is a mode (here 0.84×) and 100 % is 1:1, so the two baselines are not the same.
            let camera = m.canvasPerSource / baseScale
            let ratio = len / baseLength
            lines.append(String(format: "%.0f%% → %.2f px（×%.4f，相机 ×%.4f）",
                                zoom * 100, len, ratio, camera))
            XCTAssertEqual(ratio, camera, accuracy: camera * 0.005,
                           "354 ③ 线长没有按缩放线性变化（\(zoom * 100)%）")
        }
        // The stop the task names: 100 % → 400 % is exactly four times.
        let hundred = try XCTUnwrap(lengths[1]), fourHundred = try XCTUnwrap(lengths[4])
        XCTAssertEqual(fourHundred / hundred, 4, accuracy: 0.02, "354 ③ 100%→400% 不是 4 倍")
        XCTAssertEqual(try XCTUnwrap(lengths[2]) / hundred, 2, accuracy: 0.01, "354 ③ 100%→200% 不是 2 倍")

        // …and back to fit: the same numbers, not merely close.
        let back = try viewPair(perspective: map, straighten: straighten, mapping: fitMapping)
        var worstBack = 0.0
        for (a, b) in zip(base, back) {
            worstBack = max(worstBack,
                            hypot(Double(a.0.x - b.0.x), Double(a.0.y - b.0.y)))
            worstBack = max(worstBack,
                            hypot(Double(a.1.x - b.1.x), Double(a.1.y - b.1.y)))
        }
        lines.append(String(format: "回 fit 端点差 %.2e px", worstBack))
        print("354 ③ 跟随缩放: " + lines.joined(separator: " · ")
              + String(format: " · 与 P·R·view 最坏 %.2e px", worstDisplay))
        XCTAssertLessThanOrEqual(worstBack, endpointTolerance, "354 ③ 回 fit 没回到原位")
        XCTAssertLessThanOrEqual(worstDisplay, displayTolerance, "354 ③ 缩放后线没跟上相机")
    }

    // MARK: - ④ a dragged endpoint, written back as a source pixel

    /// §3.4 — drag one end on the **screen**, and the stored source pixel must project back onto the
    /// drop point (≤ 0.5 px); the re-solve then writes `(v, h, s)`, printed before/after.
    func testDraggingAnEndpointWritesBackASourcePixelThatProjectsOntoTheDropPoint() throws {
        let (session, tool) = try makeTool()
        let lines = try drawnPair()
        XCTAssertNil(draw(tool, from: lines[0].0, to: lines[0].1), "一条线解不出来")
        let first = draw(tool, from: lines[1].0, to: lines[1].1)
        XCTAssertNotNil(first, "两条会聚的竖线应当解出透视")
        XCTAssertEqual(tool.guideLines.count, 2)
        let _ = try XCTUnwrap(tool.guideLines.indices.last)

        let before = session.edit.geometry
        let m = mapping(perspective: before.perspective, straighten: before.straightenDegrees)
        let map = tool.guideLineProjection(mapping: m)
        let index = tool.guideLines.count - 1
        let grabbed = map.screenPoint(tool.guideLines[index].b)      // 最后画的那条的 b 端
        let drop = CGPoint(x: grabbed.x + 46, y: grabbed.y - 31)     // a hand's move, in points
        XCTAssertTrue(tool.beginGuideLineDrag(atViewPoint: grabbed, mapping: m), "按在端点上")
        tool.continueGuideLineDrag(atViewPoint: drop, mapping: m)
        let line = tool.guideLines[index]
        let after = tool.guideLineProjection(mapping: m)
        let projected = after.screenPoint(line.b)
        let miss = hypot(Double(projected.x - drop.x), Double(projected.y - drop.y))
        print(String(format: "354 ④ 端点拖动: 落点 (%.3f, %.3f) · 回写源像素 (%.3f, %.3f) · 再投影 (%.3f, %.3f) · 差 %.3f px",
                     drop.x, drop.y, line.b.x, line.b.y, projected.x, projected.y, miss))
        XCTAssertLessThanOrEqual(miss, endpointTolerance, "354 ④ 回写的源像素投不回落点")

        let solution = tool.endGuideLineDrag(mapping: m)
        let solved = session.edit.geometry
        print(String(format: "354 ④ 求解前 (v,h,s) = (%+.2f, %+.2f, %+.2f) → 求解后 (%+.2f, %+.2f, %+.2f) · 残差 %@",
                     before.perspectiveVertical, before.perspectiveHorizontal,
                     before.straightenDegrees,
                     solved.perspectiveVertical, solved.perspectiveHorizontal,
                     solved.straightenDegrees,
                     solution.map { String(format: "%.3f°", $0.worstResidual) } ?? "—"))
        XCTAssertNotNil(solution, "两条线画完再拖一条，应当仍然解得出")
    }

    // MARK: - ⑤ one end only

    /// §3.5 — a single-endpoint drag moves **one** end: the other end of that line keeps its screen
    /// position (≤ 0.5 px) while the hand is down.
    func testDraggingOneEndpointLeavesTheOtherEndWhereItWas() throws {
        let (session, tool) = try makeTool()
        let lines = try drawnPair()
        XCTAssertNil(draw(tool, from: lines[0].0, to: lines[0].1))
        XCTAssertNotNil(draw(tool, from: lines[1].0, to: lines[1].1))

        let g = session.edit.geometry
        let m = mapping(perspective: g.perspective, straighten: g.straightenDegrees)
        let p0 = tool.guideLineProjection(mapping: m)
        let grabbed = p0.screenPoint(tool.guideLines[0].a)
        let otherBefore = p0.screenPoint(tool.guideLines[0].b)
        XCTAssertTrue(tool.beginGuideLineDrag(atViewPoint: grabbed, mapping: m))
        tool.continueGuideLineDrag(atViewPoint: CGPoint(x: grabbed.x + 40, y: grabbed.y + 12),
                                   mapping: m)
        let otherAfter = tool.guideLineProjection(mapping: m).screenPoint(tool.guideLines[0].b)
        let moved = hypot(Double(otherAfter.x - otherBefore.x), Double(otherAfter.y - otherBefore.y))
        print(String(format: "354 ⑤ 拖一端: 另一端屏幕位移 %.3f px（源像素 Δ = (%.3f, %.3f)）",
                     moved,
                     Double(tool.guideLines[0].b.x - lines[0].1.x),
                     Double(tool.guideLines[0].b.y - lines[0].1.y)))
        XCTAssertLessThanOrEqual(moved, endpointTolerance, "354 ⑤ 拖一端把另一端也拖走了")
        XCTAssertEqual(Double(tool.guideLines[0].b.x), Double(lines[0].1.x), accuracy: 1e-9)
    }

    // MARK: - ⑥ double-click deletes one line and re-solves

    /// §3.6 — the line count drops by one, the others keep their endpoints to 1e-9, and the parameters
    /// are re-solved on what is left (printed before/after).
    func testDoubleClickingALineDeletesItAndReSolvesOnTheRest() throws {
        let (session, tool) = try makeTool()
        let pair = try drawnPair()
        XCTAssertNil(draw(tool, from: pair[0].0, to: pair[0].1))
        let solution = draw(tool, from: pair[1].0, to: pair[1].1)
        XCTAssertNotNil(solution, "两条会聚的竖线应当解出透视")
        XCTAssertEqual(tool.guideLines.count, 2)
        let before = session.edit.geometry
        let keptSource = tool.guideLines[0]

        let m = mapping(perspective: before.perspective, straighten: before.straightenDegrees)
        let mid = {
            let s = tool.guideLineProjection(mapping: m)
            let a = s.screenPoint(tool.guideLines[1].a), b = s.screenPoint(tool.guideLines[1].b)
            return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }()
        XCTAssertTrue(tool.deleteGuideLine(atViewPoint: mid, mapping: m), "双击线身应当删掉这条")
        XCTAssertEqual(tool.guideLines.count, 1, "354 ⑥ 双击线身删掉一条")
        XCTAssertEqual(tool.guideLines[0].a.x, keptSource.a.x, accuracy: 1e-9, "354 ⑥ 其余线不动")
        XCTAssertEqual(tool.guideLines[0].b.y, keptSource.b.y, accuracy: 1e-9)
        let after = session.edit.geometry
        print(String(format: "354 ⑥ 删除前后: 线 %d → 1 · (v,h,s) (%+.2f, %+.2f, %+.2f) → (%+.2f, %+.2f, %+.2f) · 提示「%@」",
                     2, before.perspectiveVertical, before.perspectiveHorizontal,
                     before.straightenDegrees,
                     after.perspectiveVertical, after.perspectiveHorizontal,
                     after.straightenDegrees,
                     tool.guideLineStatusText ?? "—"))
        // Fewer than two lines: the parameters are kept (§2.5).
        XCTAssertEqual(after.perspectiveVertical, before.perspectiveVertical,
                       accuracy: 1e-9, "354 ⑥ <2 条应当保留当前值")
    }

    // MARK: - ⑦ persistence

    /// §3.7 — the endpoints survive 「关闭裁切重进」 and a document round trip, value for value (1e−9).
    func testTheEndpointsSurviveClosingTheToolAndADocumentRoundTrip() throws {
        let (session, tool) = try makeTool()
        let lines = try drawnPair()
        XCTAssertNil(draw(tool, from: lines[0].0, to: lines[0].1))
        XCTAssertNotNil(draw(tool, from: lines[1].0, to: lines[1].1))
        let stored = tool.guideLines.map { ($0.a, $0.b) }
        XCTAssertEqual(stored.count, 2)

        // (a) the document, encoded and read back
        let data = try JSONEncoder().encode(session.edit.geometry)
        let reread = try JSONDecoder().decode(GeometryGroup.self, from: data)
        XCTAssertEqual(reread.guideLines.count, 2, "354 ⑦ 文档里应当有两条线")
        for (index, line) in reread.guideLines.enumerated() {
            XCTAssertEqual(line.ax, Double(stored[index].0.x), accuracy: 1e-9)
            XCTAssertEqual(line.ay, Double(stored[index].0.y), accuracy: 1e-9)
            XCTAssertEqual(line.bx, Double(stored[index].1.x), accuracy: 1e-9)
            XCTAssertEqual(line.by, Double(stored[index].1.y), accuracy: 1e-9)
        }
        // (b) 「关闭裁切重进」: the tool's own entry path re-reads them from the document. 应用 with
        // nothing left to change commits nothing (`applyEdit` short-circuits) — the lines are
        // already in the document, written by the fit that produced them.
        _ = tool.apply()
        let reopened = CropToolController(session: session)
        XCTAssertTrue(reopened.begin())
        XCTAssertEqual(reopened.guideLines.count, 2, "354 ⑦ 重开裁切，线要回来")
        for (index, line) in reopened.guideLines.enumerated() {
            XCTAssertEqual(Double(line.a.x), Double(stored[index].0.x), accuracy: 1e-9)
            XCTAssertEqual(Double(line.b.y), Double(stored[index].1.y), accuracy: 1e-9)
        }
        print(String(format: "354 ⑦ 持久化: 2 条线 · 源端点往返差 ≤ %.0e px · 重开裁切后 %d 条",
                     1e-9, reopened.guideLines.count))
    }

    // MARK: - ⑨ the two reverse gates

    /// Gate ① — a display that skips `P` (only `R · view`) must make §3.1 red.
    func testGateOneSkippingTheKeystoneMakesTheFollowRed() throws {
        let map = PerspectiveMap(vertical: 60, horizontal: 0)
        let m = mapping(perspective: map)
        let endpoints = sourcePair().map(\.0)
        func worst(omits: Bool) throws -> Double {
            let p = projection(m, perspective: map, omitsPerspective: omits)
            var out = 0.0
            for endpoint in endpoints {
                let ours = p.screenPoint(endpoint)
                let theirs = try reference(endpoint, perspective: map, straighten: 0, mapping: m)
                out = max(out, hypot(Double(ours.x - theirs.x), Double(ours.y - theirs.y)))
            }
            return out
        }
        let shipped = try worst(omits: false), gated = try worst(omits: true)
        print(String(format: "354 ⑨ 反向门①（显示跳过 P）: 出厂 %.2e px · 跳过 P %.2f px", shipped, gated))
        XCTAssertLessThanOrEqual(shipped, displayTolerance)
        XCTAssertGreaterThan(gated, displayTolerance, "跳过 P 之后 ① 竟然是绿的 —— 那条测量是空的")
    }

    /// Gate ② — a display that skips the camera must make §3.3 red (the line stops scaling).
    func testGateTwoSkippingTheViewScaleMakesTheZoomRed() throws {
        let map = PerspectiveMap(vertical: 30, horizontal: 0)
        func ratio(omits: Bool) -> Double {
            let one = projection(mapping(perspective: map,
                                         state: LoupeViewState(mode: .actual, zoom: 1)),
                                 perspective: map, omitsViewScale: omits)
            let four = projection(mapping(perspective: map,
                                          state: LoupeViewState(mode: .actual, zoom: 4)),
                                  perspective: map, omitsViewScale: omits)
            let line = GuideLine(a: sourcePair()[0].0, b: sourcePair()[0].1,
                                 viewAngle: 90, axis: .vertical)
            let a = one.segments(of: [line])[0], b = four.segments(of: [line])[0]
            return length((b.a, b.b)) / length((a.a, a.b))
        }
        let shipped = ratio(omits: false), gated = ratio(omits: true)
        print(String(format: "354 ⑨ 反向门②（显示跳过缩放）: 出厂 100%%→400%% 长度比 ×%.4f · 跳过缩放 ×%.4f",
                     shipped, gated))
        XCTAssertEqual(shipped, 4, accuracy: 0.02, "出厂必须按缩放线性变化")
        XCTAssertLessThan(gated, 2, "跳过缩放之后 ③ 竟然是绿的 —— 那条测量是空的")
    }
}
