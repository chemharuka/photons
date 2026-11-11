import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **371 — 旋转+校正后，裁切框贴边移动仍会跳动（368 的残留）。**
///
/// 用户口径：
///
///   > 另外现在旋转+校正后，裁剪框在边缘移动时还会跳动，但行为比以前好多了，说明之前的修改有效但还存在一些小问题
///
/// 368 之后中间区域已经不跳了（回弹 0.00 px、相邻 tick 与手步长偏差 0.00 px）。残留只在**贴边**：
/// 368 的每个 tick 都从**按下时**的框重算候选，再被四边形/画布夹一次。框一旦被夹住，下一 tick
/// 手继续往外走，候选又回到未夹的位置再被夹回去 —— 逐 tick 一次「夹一次、抖一下」；回拖时也要等
/// 手退回未夹的边界框才重新动，形成死区。
///
/// 371 让这一步**幂等且单调**：
///
///   · 候选 = 「手上一 tick 的位移」+「上一 tick 真正写下的框」，不是按下的框；
///   · 一旦上一 tick 结束在夹取边界上，而这一 tick 手仍在往外推，就**不写**，`draft.crop` 逐位不变；
///   · 回拖的第一 tick 从已夹住的框继续，所以框立刻跟手，没有死区。
///
/// 本文件走真实路径（`LoupeController.beginCropDrag` / `continueCropDrag`），每 tick 读 overlay
/// 实际画的 `layout.corners`，几何全部在测试里用闭式重推。
///
/// ① 轨迹 A（右下角外拖 30 tick × 12 pt）：被夹住后相邻 tick Δwidth/Δheight = 0，锯齿 = 0；
/// ② 轨迹 A 终态：框的角落在照片四边形边界上（误差 ≤ 0.5 px），不是「差一点」；
/// ③ 轨迹 B（回拖 20 tick）：第一 tick 跳变 ≤ 1.0 px，之后每 tick 与手步长偏差 ≤ 1.0 px；
/// ④ 中间区域不回退：20 tick 对角拖，跟手、无回弹；
/// ⑤ 同点连喂两次逐位相同，每 tick 一次指针投影；
/// ⑦ 反向门：把「夹取后的框写回基准」改回去，①③ 必红。
@MainActor
final class CropEdgeJitter371Tests: XCTestCase {

    static let source = ImageSize(width: 6000, height: 4000)

    private var workDir: URL!
    private var editors: [EditorWindowController] = []
    /// 「不出像素」 is a persisted preference. These tests tick it, so the value that was there
    /// before the suite must come back after each case — otherwise a test that runs later in the
    /// same process sees a checked box it never asked for.
    private var savedStaysInside: Any?

    struct Group {
        let label: String
        let degrees: Double
        let vertical: Double
    }

    /// 规格的三组几何：(9°, v=0) / (0, v=+60) / (9°, v=+60)。
    static let groups: [Group] = [
        Group(label: "9° v0", degrees: 9, vertical: 0),
        Group(label: "0° v+60", degrees: 0, vertical: 60),
        Group(label: "9° v+60", degrees: 9, vertical: 60),
    ]

    /// One tick of the real path, as the user sees it.
    private struct Tick {
        let width: Double        // drawn frame side lengths, view points (= the report's px)
        let height: Double
        let left: Double         // `draft.crop`, normalized
        let top: Double
        let corner: CGPoint      // drawn bottom-right corner, view points
        let handInset: Double    // hand's signed distance to the photo quad (positive inside)
        let pressed: Bool        // the per-tick pixel press fired on this tick
    }

    override func setUpWithError() throws {
        savedStaysInside = UserDefaults.standard.object(forKey: CropToolController.staysInsidePixelsKey)
        UserDefaults.standard.removeObject(forKey: CropToolController.staysInsidePixelsKey)
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-371-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for editor in editors { editor.window?.close() }
        editors.removeAll()
        if let savedStaysInside {
            UserDefaults.standard.set(savedStaysInside,
                                      forKey: CropToolController.staysInsidePixelsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CropToolController.staysInsidePixelsKey)
        }
        savedStaysInside = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

    private func makeLoupe(_ g: Group) throws -> (LoupeController, CatalogSession) {
        let library = try CropUITestSupport.makeLibrary(in: workDir,
                                                       width: Self.source.width,
                                                       height: Self.source.height)
        let editor = EditorWindowController(size: NSSize(width: 1000, height: 720))
        try editor.openLibrary(at: library.package)
        editor.session.selectOnly(library.assetID)
        editor.session.mode = .loupe
        let loupe = editor.rootView.loupeController
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        TestWindows.show(editor.window!)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        editor.rootView.needsLayout = true
        editor.rootView.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        editor.rootView.layoutSubtreeIfNeeded()
        editors.append(editor)
        let deadline = Date().addingTimeInterval(3)
        while editor.session.mode != .loupe || editor.session.anchorAsset == nil, Date() < deadline {
            CropUITestSupport.pump(0.01)
        }
        editor.session.applyEdit { edit in
            edit.geometry.rotationDegrees = g.degrees
            edit.geometry.perspectiveVertical = g.vertical
        }
        CropUITestSupport.pump(0.02)
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, editor.session),
                      "\(g.label): 裁切 mode 没打开")
        CropUITestSupport.pump(0.05)
        return (loupe, editor.session)
    }

    private func seed(_ loupe: LoupeController, _ span: Double, pixels: Bool = false) {
        loupe.cropTool.draft.crop = CropRect(left: 0.5 - span / 2, top: 0.5 - span / 2,
                                             right: 0.5 + span / 2, bottom: 0.5 + span / 2)
        _ = loupe.cropTool.setCropStaysInsidePixels(pixels)
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.01)
    }

    private func drawn(_ loupe: LoupeController) throws -> [CGPoint] {
        let layout = try XCTUnwrap(loupe.cropOverlayLayoutForTesting,
                                   "overlay 没在画框（layout == nil）")
        XCTAssertEqual(layout.corners.count, 4, "框不是四边形")
        return layout.corners
    }

    private func size(_ c: [CGPoint]) -> (w: Double, h: Double) {
        (hypot(Double(c[1].x - c[0].x), Double(c[1].y - c[0].y)),
         hypot(Double(c[3].x - c[0].x), Double(c[3].y - c[0].y)))
    }

    // MARK: - the picture's quad in view points (test's own closed form, as in 362/368)

    private func photoQuadDocumentPixels(_ g: Group) -> [DocumentPoint] {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let perspective = PerspectiveMap(vertical: g.vertical, horizontal: 0)
        let rotation = CropGeometry.RotationMatrix(degrees: g.degrees)
        var turned: [(x: Double, y: Double)] = []
        for corner in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)] {
            var nx = corner.0, ny = corner.1
            if perspective.hasWarp {
                let p = perspective.forward(x: nx, y: ny)
                nx = p.x; ny = p.y
            }
            let t = rotation.apply(x: nx * w - w / 2, y: ny * h - h / 2)
            turned.append((x: t.x + w / 2, y: t.y + h / 2))
        }
        let originX = turned.map(\.x).min() ?? 0
        let originY = turned.map(\.y).min() ?? 0
        return turned.map { DocumentPoint($0.x - originX, $0.y - originY) }
    }

    private func photoQuadPhotoPixels(_ g: Group) -> [(x: Double, y: Double)] {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let perspective = PerspectiveMap(vertical: g.vertical, horizontal: 0)
        let rotation = CropGeometry.RotationMatrix(degrees: g.degrees)
        return [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map { corner in
            var nx = corner.0, ny = corner.1
            if perspective.hasWarp {
                let p = perspective.forward(x: nx, y: ny)
                nx = p.x; ny = p.y
            }
            let t = rotation.apply(x: nx * w - w / 2, y: ny * h - h / 2)
            return (x: t.x + w / 2, y: t.y + h / 2)
        }
    }

    private func photoQuadInView(_ g: Group, _ loupe: LoupeController) throws -> [CGPoint] {
        let framing = try XCTUnwrap(loupe.framing(), "no framing")
        let mapping = framing.mapping(of: loupe.viewState)
        let scale = loupe.backingScale
        let canvasSpaced = loupe.cropTool.draft.cropSpace == .canvas
        let warped = g.vertical != 0
        if canvasSpaced || warped {
            return try photoQuadDocumentPixels(g).map { p in
                let v = try XCTUnwrap(mapping.documentView(p), "documentView nil")
                return CGPoint(x: Double(v.x) / scale, y: Double(v.y) / scale)
            }
        }
        return try photoQuadPhotoPixels(g).map { p in
            let v = mapping.frameView(frameX: p.x, frameY: p.y)
            return CGPoint(x: v.x / scale, y: v.y / scale)
        }
    }

    /// Signed distance of `p` to the convex quad (positive inside), in points.
    private func inset(_ p: CGPoint, quad: [CGPoint]) -> Double {
        var worst = Double.infinity
        let cx = quad.reduce(0) { $0 + Double($1.x) } / 4
        let cy = quad.reduce(0) { $0 + Double($1.y) } / 4
        for i in quad.indices {
            let a = quad[i], b = quad[(i + 1) % quad.count]
            let ex = Double(b.x - a.x), ey = Double(b.y - a.y)
            let length = (ex * ex + ey * ey).squareRoot()
            guard length > 1e-12 else { continue }
            var nx = ey / length, ny = -ex / length
            if nx * (cx - Double(a.x)) + ny * (cy - Double(a.y)) > 0 { nx = -nx; ny = -ny }
            worst = min(worst, nx * (Double(a.x) - Double(p.x)) + ny * (Double(a.y) - Double(p.y)))
        }
        return worst
    }

    // MARK: - trajectory helpers

    private func tick(_ loupe: LoupeController, mouse: CGPoint, quad: [CGPoint],
                      pressesBefore: Int) throws -> Tick {
        let corners = try drawn(loupe)
        let s = size(corners)
        let crop = loupe.cropTool.draft.crop
        return Tick(width: s.w, height: s.h,
                    left: crop.left, top: crop.top,
                    corner: corners[2],
                    handInset: inset(mouse, quad: quad),
                    pressed: loupe.cropTool.pixelPresses > pressesBefore)
    }

    /// The mouse-down frame plus 30 outward ticks of 12 pt on both axes (the report's trajectory A).
    private func outwardTrajectory(_ loupe: LoupeController, start: CGPoint,
                                   quad: [CGPoint]) throws -> [Tick] {
        var mouse = start
        var ticks = [try tick(loupe, mouse: mouse, quad: quad, pressesBefore: Int.max)]
        for _ in 1...30 {
            mouse.x += 12
            mouse.y += 12
            let before = loupe.cropTool.pixelPresses
            loupe.continueCropDrag(atViewPoint: mouse)
            ticks.append(try tick(loupe, mouse: mouse, quad: quad, pressesBefore: before))
        }
        return ticks
    }

    /// A frame measured from the overlay, with 「不出像素」 on and 原始 (3:2) locked, as the
    /// report's groups are.
    private func startOutward(_ g: Group) throws -> (LoupeController, [CGPoint], CGPoint) {
        let (loupe, _) = try makeLoupe(g)
        loupe.cropTool.setAspect(.original)
        seed(loupe, 0.8, pixels: true)
        loupe.cropTool.setAspect(.original)
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.01)
        let quad = try photoQuadInView(g, loupe)
        let corners = try drawn(loupe)
        XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
        return (loupe, quad, corners[2])
    }

    /// Sign changes in consecutive non-zero steps — the report's 「锯齿计数」.
    private func reversals(_ values: [Double], epsilon: Double = 1e-9) -> Int {
        var count = 0
        var lastSign = 0
        for index in 1..<values.count {
            let delta = values[index] - values[index - 1]
            guard abs(delta) > epsilon else { continue }
            let sign = delta > 0 ? 1 : -1
            if lastSign != 0, sign != lastSign { count += 1 }
            lastSign = sign
        }
        return count
    }

    private func firstIndex(of ticks: [Tick], where predicate: (Tick) -> Bool) -> Int? {
        ticks.firstIndex(where: predicate)
    }

    // MARK: - ① / ② 轨迹 A：夹住之后逐位不变，终态贴住四边形

    func testOneOnceClampedTheFrameIsFrozen() throws {
        for g in Self.groups {
            let (loupe, quad, start) = try startOutward(g)
            let ticks = try outwardTrajectory(loupe, start: start, quad: quad)
            let finished = try drawn(loupe)
            loupe.endCropDrag()

            let clamped = try XCTUnwrap(firstIndex(of: ticks) { $0.pressed },
                                        "\(g.label): 30 tick 没有到达夹取边界 —— 这条验收没有判别力")
            XCTAssertLessThanOrEqual(clamped, ticks.count - 2,
                                     "\(g.label): 夹取只发生在最后一 tick —— 无法量「夹住之后」")

            var maxFrozenDelta = 0.0
            var widths: [Double] = [], heights: [Double] = []
            for index in 1..<ticks.count {
                let dw = ticks[index].width - ticks[index - 1].width
                let dh = ticks[index].height - ticks[index - 1].height
                widths.append(ticks[index].width)
                heights.append(ticks[index].height)
                if index > clamped {
                    maxFrozenDelta = max(maxFrozenDelta, abs(dw), abs(dh))
                }
            }
            let zigzag = reversals(widths) + reversals(heights)
            let clampedTicks = ticks.filter(\.pressed).count

            // ② the frozen frame must be ON the allowed limit, not a pixel short of it.
            let insets = finished.map { inset($0, quad: quad) }
            let nearest = insets.map(abs).min() ?? 0   // closest corner to the boundary: 0 = touching
            let outside = insets.min() ?? 0

            print(String(format: "371 ① %@ · 夹住 %d tick（第 %d tick 起）· 夹后 max|Δw/h| %.3e px · 锯齿 %d · 终态 宽 %.1f 高 %.1f · 手到边界 %.1f px",
                         g.label, clampedTicks, clamped, maxFrozenDelta, zigzag,
                         ticks.last?.width ?? 0, ticks.last?.height ?? 0,
                         ticks.last?.handInset ?? 0))
            print(String(format: "371 ② %@ · 四角内距 %.3f…%.3f px · 最近边 %.3f px（0 = 贴住边界）",
                         g.label, outside, insets.max() ?? 0, nearest))

            XCTAssertEqual(maxFrozenDelta, 0, accuracy: 1e-9,
                "\(g.label): 被夹住之后每 tick 还在改尺寸（max|Δ| \(maxFrozenDelta) px）—— 这就是贴边跳动")
            XCTAssertEqual(zigzag, 0,
                "\(g.label): 外拖轨迹的方向反转了 \(zigzag) 次（锯齿）")
            XCTAssertGreaterThanOrEqual(outside, -0.5,
                "\(g.label): 终态框有角跑出照片四边形 \(outside) px")
            XCTAssertLessThanOrEqual(nearest, 0.5,
                "\(g.label): 终态框没有一条边贴住边界（最近 \(nearest) px）—— 不是允许的极值")
        }
    }

    // MARK: - ③ 轨迹 B：回拖从已夹住的框继续，没有死区

    func testTwoReturningFromTheEdgeFollowsTheHand() throws {
        for g in Self.groups {
            let (loupe, quad, start) = try startOutward(g)
            let ticks = try outwardTrajectory(loupe, start: start, quad: quad)
            let clamped = try XCTUnwrap(firstIndex(of: ticks) { $0.pressed },
                                        "\(g.label): 没有夹住 —— 回拖验收没有判别力")

            _ = clamped
            var mouse = CGPoint(x: start.x + 360, y: start.y + 360)
            var previous = ticks.last!
            var deltas: [(w: Double, h: Double)] = []
            for _ in 1...20 {
                mouse.x -= 12
                mouse.y -= 12
                loupe.continueCropDrag(atViewPoint: mouse)
                let now = try tick(loupe, mouse: mouse, quad: quad, pressesBefore: Int.max)
                deltas.append((now.width - previous.width, now.height - previous.height))
                previous = now
            }
            loupe.endCropDrag()

            // 「与手步长偏差」: the hand's step as the frame experiences it at the edge is the
            // steady return step (the hand steps 12 pt every tick, so the frame must too). The first
            // tick is where the old chain sat still in its dead zone; the rest are the reference.
            let tail = Array(deltas.dropFirst())
            let steadyW = tail.reduce(0) { $0 + $1.w } / Double(tail.count)
            let steadyH = tail.reduce(0) { $0 + $1.h } / Double(tail.count)
            let first = deltas[0]
            let firstJump = max(abs(first.w - steadyW), abs(first.h - steadyH))
            let worstJump = tail.reduce(0.0) {
                max($0, abs($1.w - steadyW), abs($1.h - steadyH))
            }
            let moved = abs(first.w) + abs(first.h)
            let reversedWidth = deltas.map(\.w).max() ?? 0

            print(String(format: "371 ③ %@ · 首 tick 跳变 %.3f px · 之后 max %.3f px · 首 tick 移动 %.1f px · 手步长 %.2f/%.2f · 回拖回弹 %.3f px",
                         g.label, firstJump, worstJump, moved, steadyW, steadyH, reversedWidth))
            XCTAssertLessThan(steadyW, -1.0,
                "\(g.label): 回拖 20 tick 框都没有缩小（死区）")
            XCTAssertGreaterThan(moved, 1.0,
                "\(g.label): 回拖第一 tick 框原地不动 —— 手已经退回来了")
            XCTAssertLessThanOrEqual(firstJump, 1.0,
                "\(g.label): 回拖第一 tick 跳变 \(firstJump) px —— 框没从已夹住的位置继续")
            XCTAssertLessThanOrEqual(worstJump, 1.0,
                "\(g.label): 回拖每 tick 与手步长偏差 \(worstJump) px")
            XCTAssertLessThanOrEqual(reversedWidth, 1e-9,
                "\(g.label): 回拖时框反而向外弹了 \(reversedWidth) px")
        }
    }

    // MARK: - ④ 中间区域：368 已修的不许回退

    func testThreeTheMiddleStillTracksWithoutRebound() throws {
        for g in Self.groups {
            let (loupe, _) = try makeLoupe(g)
            loupe.cropTool.setAspect(.free)      // no ratio: the drawn corner IS the hand
            seed(loupe, 0.5)
            loupe.cropTool.setAspect(.free)
            loupe.refreshCropTool()
            CropUITestSupport.pump(0.01)

            let corners = try drawn(loupe)
            XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
            var mouse = corners[2]
            var previous = size(corners)
            var worstFollow = 0.0
            var rebound = 0.0
            for _ in 1...20 {
                mouse.x += 6
                mouse.y += 6
                loupe.continueCropDrag(atViewPoint: mouse)
                let now = try drawn(loupe)
                let s = size(now)
                worstFollow = max(worstFollow,
                                  hypot(Double(now[2].x - mouse.x), Double(now[2].y - mouse.y)))
                rebound = max(rebound, previous.w - s.w, previous.h - s.h)
                previous = s
            }
            loupe.endCropDrag()
            print(String(format: "371 ④ %@ · 跟手偏差 %.3e px · 回弹 %.3e px",
                         g.label, worstFollow, rebound))
            XCTAssertLessThanOrEqual(worstFollow, 0.05,
                "\(g.label): 中间区域画出来的角离手 \(worstFollow) px")
            XCTAssertLessThanOrEqual(rebound, 1e-9,
                "\(g.label): 中间区域回弹了 \(rebound) px（368 已修，不许回退）")
        }
    }

    // MARK: - ⑤ 同点幂等 + 每 tick 一次投影

    func testFourTheSamePointIsBitIdenticalAndOneProjection() throws {
        for g in Self.groups {
            let (loupe, _) = try makeLoupe(g)
            seed(loupe, 0.7, pixels: true)
            let corners = try drawn(loupe)
            XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
            var mouse = corners[2]
            var worstProjections = 0
            for _ in 1...5 {
                let before = loupe.cropTool.projectionRoundTrips
                mouse.x += 7
                mouse.y += 5
                loupe.continueCropDrag(atViewPoint: mouse)
                worstProjections = max(worstProjections,
                                       loupe.cropTool.projectionRoundTrips - before)
            }
            loupe.continueCropDrag(atViewPoint: mouse)
            let first = loupe.cropTool.draft.crop
            loupe.continueCropDrag(atViewPoint: mouse)
            let second = loupe.cropTool.draft.crop
            loupe.endCropDrag()
            print(String(format: "371 ⑤ %@ · 同点两次逐位相同 %@ · 每 tick 投影 %d 次",
                         g.label, first == second ? "是" : "否", worstProjections))
            XCTAssertEqual(first, second,
                "\(g.label): 同一个屏幕点连喂两次，draft.crop 变了（不幂等）")
            XCTAssertEqual(worstProjections, 1,
                "\(g.label): 一个 tick 走了 \(worstProjections) 次指针投影（必须 1）")
        }
    }

    // MARK: - ⑦ 反向门：把「夹取后的框写回基准」改回去，①③ 必红

    func testGateRestartingFromMouseDownJittersAtTheEdge() throws {
        let g = Self.groups[2]
        // 自由比例：368 的按 tick 重读在斜四边形上会让候选的「从锚点出发的射线」每 tick 变一点，
        // 夹取结果随之漂移（锁定 3:2 时射线方向恰好不变，所以门必须关掉比例锁才看得见）。
        let (loupe, _) = try makeLoupe(g)
        loupe.cropTool.setAspect(.free)
        seed(loupe, 0.8, pixels: true)
        loupe.cropTool.setAspect(.free)
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.01)
        let quad = try photoQuadInView(g, loupe)
        let corners = try drawn(loupe)
        XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
        let start = corners[2]
        loupe.cropTool.restartsSizeDragsFromMouseDown = true
        let ticks = try outwardTrajectory(loupe, start: start, quad: quad)
        let clamped = try XCTUnwrap(firstIndex(of: ticks) { $0.pressed },
                                    "门：没有夹住，无法判别")

        var postDelta = 0.0
        var widths: [Double] = [], heights: [Double] = []
        for index in 1..<ticks.count {
            widths.append(ticks[index].width)
            heights.append(ticks[index].height)
            if index > clamped {
                postDelta = max(postDelta,
                                abs(ticks[index].width - ticks[index - 1].width),
                                abs(ticks[index].height - ticks[index - 1].height))
            }
        }

        var mouse = CGPoint(x: start.x + 360, y: start.y + 360)
        var previous = ticks.last!
        var deltas: [(w: Double, h: Double)] = []
        for _ in 1...20 {
            mouse.x -= 12
            mouse.y -= 12
            loupe.continueCropDrag(atViewPoint: mouse)
            let now = try tick(loupe, mouse: mouse, quad: quad, pressesBefore: Int.max)
            deltas.append((now.width - previous.width, now.height - previous.height))
            previous = now
        }
        loupe.endCropDrag()
        loupe.cropTool.restartsSizeDragsFromMouseDown = false

        let tail = Array(deltas.dropFirst())
        let steadyW = tail.reduce(0) { $0 + $1.w } / Double(tail.count)
        let steadyH = tail.reduce(0) { $0 + $1.h } / Double(tail.count)
        let firstJump = max(abs(deltas[0].w - steadyW), abs(deltas[0].h - steadyH))

        print(String(format: "371 ⑦ 门 %@ · 夹后 max|Δ| %.3f px · 锯齿 %d · 首 tick 跳变 %.3f px · 回拖步长 %.2f/%.2f（①③ 必须红）",
                     g.label, postDelta, reversals(widths) + reversals(heights),
                     firstJump, steadyW, steadyH))
        XCTAssertGreaterThan(postDelta, 1e-6,
            "门：按回 368 的每 tick 重读，夹住之后尺寸竟然逐位不变 —— ① 没有判别力")
        XCTAssertTrue(firstJump > 1.0 || steadyW > -1.0,
            "门：按回 368 的每 tick 重读，回拖竟然没有跳变也没有死区 —— ③ 没有判别力")
    }
}
