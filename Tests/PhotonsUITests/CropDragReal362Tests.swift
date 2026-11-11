import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **362 — 355 的「跟手 / 不出像素 / 不跳变」在真实路径上重测。**
///
/// 用户口径：
///
///   > 另外 355 不跟手，会跳变，以及开启了像素内还出像素的问题，并没有解决。
///
/// 355 的验收是**自比自洽**：它拿 `CropToolController` 自己算出来的「角在哪」和鼠标比。真实交互走的是
/// `LoupeController.beginCropDrag` → `continueCropDrag`，而且用户看的是 **overlay 真正画出来的框**。
/// 所以这个文件里：
///
///   · 每一次按下都走真实路径（`beginCropDrag` / `continueCropDrag` / `endCropDrag`）；
///   · 每一 tick 读的都是 `loupe.cropOverlayLayoutForTesting` —— overlay **实际用于绘制**的那份 layout
///     （`CropTool.layout` 的输出，屏幕点），不是重新算一遍控制器的答案；
///   · 判「出像素」用的是**同一份 layout 的四角**与照片四边形在**屏幕上的投影**（该投影由本文件按
///     `P → R` 闭式重推，不读生产代码的中间量）。
///
/// 四组几何 × 三种拖动 = 12 组跟手；四组外拖 30 tick 的超界采样；四组 20 tick 的相邻宽高差。
@MainActor
final class CropDragReal362Tests: XCTestCase {

    static let source = ImageSize(width: 6000, height: 4000)

    private var workDir: URL!
    private var editors: [EditorWindowController] = []

    struct Group {
        let label: String
        let degrees: Double
        let vertical: Double
        let horizontal: Double
    }

    /// 规格 §2.3 的四组几何：(9°, 0)、(0, +60)、(9°, +60)、(9°, +60, h=+40)。
    static let groups: [Group] = [
        Group(label: "9° v0", degrees: 9, vertical: 0, horizontal: 0),
        Group(label: "0° v+60", degrees: 0, vertical: 60, horizontal: 0),
        Group(label: "9° v+60", degrees: 9, vertical: 60, horizontal: 0),
        Group(label: "9° v+60 h+40", degrees: 9, vertical: 60, horizontal: 40),
    ]

    enum Drag: String, CaseIterable {
        case corner, edge, move
    }

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-362-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for editor in editors { editor.window?.close() }
        editors.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// One file per test process, so a rerun never mixes with the previous run's numbers.
    private static let notesPath = "/tmp/362-accept-\(ProcessInfo.processInfo.processIdentifier).txt"

    private static func note(_ line: String) {
        let url = URL(fileURLWithPath: notesPath)
        let data = (line + "\n").data(using: .utf8)!
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - harness

    /// A real editor window on a 6000×4000 library, the group's rotation + keystone **written into the
    /// document**, then 裁切 opened the way the menu opens it.
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
            edit.geometry.perspectiveHorizontal = g.horizontal
        }
        CropUITestSupport.pump(0.02)
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, editor.session),
                      "\\(g.label): 裁切 mode 没打开")
        CropUITestSupport.pump(0.05)
        return (loupe, editor.session)
    }

    /// The frame's rect for a case, re-seeded and re-clamped — the mouse-down state every case starts
    /// from.
    private func seed(_ loupe: LoupeController, _ span: Double, pixels: Bool = false) {
        loupe.cropTool.draft.crop = CropRect(left: 0.5 - span / 2, top: 0.5 - span / 2,
                                             right: 0.5 + span / 2, bottom: 0.5 + span / 2)
        _ = loupe.cropTool.setCropStaysInsidePixels(pixels)
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.01)
    }

    /// The overlay's own corners — **what the user sees**, in view points.
    private func drawn(_ loupe: LoupeController) throws -> [CGPoint] {
        let layout = try XCTUnwrap(loupe.cropOverlayLayoutForTesting,
                                   "overlay 没在画框（layout == nil）")
        XCTAssertEqual(layout.corners.count, 4, "框不是四边形")
        return layout.corners
    }

    private func centre(_ corners: [CGPoint]) -> CGPoint {
        CGPoint(x: corners.reduce(0) { $0 + $1.x } / 4, y: corners.reduce(0) { $0 + $1.y } / 4)
    }

    private func edgeMid(_ corners: [CGPoint]) -> CGPoint {
        CGPoint(x: (corners[1].x + corners[2].x) / 2, y: (corners[1].y + corners[2].y) / 2)
    }

    // MARK: - the picture's own screen quad (closed form, the test's own arithmetic)

    /// The photograph's four corners in **photo pixels** after `P → R` about the photo's centre, then
    /// the document origin removed (the `.document` canvas' top-left), in the test's own arithmetic.
    private func photoQuadDocumentPixels(_ g: Group) -> [DocumentPoint] {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let perspective = PerspectiveMap(vertical: g.vertical, horizontal: g.horizontal)
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

    /// The same quad **on screen**, in view points — through the camera the overlay draws with.
    ///
    /// Each space has its own camera exit, and the test uses the **same one the overlay uses in that
    /// branch**: a `.canvas` frame is drawn through `documentView` (document-canvas pixels), a
    /// `.source` frame through `frameView` (the turned frame's pixels). They differ by the canvas'
    /// whole-pixel `ceil` (0.04 px here), and comparing one against the other would report the
    /// rounding as 「出像素」.
    private func photoQuadInView(_ g: Group, _ loupe: LoupeController) throws -> [CGPoint] {
        let framing = try XCTUnwrap(loupe.framing(), "no framing")
        let mapping = framing.mapping(of: loupe.viewState)
        let scale = loupe.backingScale
        let quadrant = try photoQuadPhotoPixels(g)
        let canvasSpaced = loupe.cropTool.draft.cropSpace == .canvas
        let warped = g.vertical != 0 || g.horizontal != 0
        if canvasSpaced || warped {
            return try photoQuadDocumentPixels(g).map { p in
                let v = try XCTUnwrap(mapping.documentView(p), "documentView nil")
                return CGPoint(x: Double(v.x) / scale, y: Double(v.y) / scale)
            }
        }
        return quadrant.map { p in
            let v = mapping.frameView(frameX: p.x, frameY: p.y)
            return CGPoint(x: v.x / scale, y: v.y / scale)
        }
    }

    /// The photograph's four corners in **photo pixels** after `P → R`, the photo's own centre kept —
    /// the grid `frameView` speaks.
    private func photoQuadPhotoPixels(_ g: Group) throws -> [(x: Double, y: Double)] {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let perspective = PerspectiveMap(vertical: g.vertical, horizontal: g.horizontal)
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

    // MARK: - ① 跟手：四组几何 × 三种拖动

    /// 每一步都从 overlay 画出来的那个角/边/中心按下，每 tick 量「画出来的那个点 − 鼠标」。
    func testATheDrawnFrameFollowsTheMouse() throws {
        var worstAll = 0.0
        var rows: [String] = []
        for g in Self.groups {
            let (loupe, _) = try makeLoupe(g)
            for drag in Drag.allCases {
                seed(loupe, drag == .move ? 0.5 : 0.55)
                let corners = try drawn(loupe)
                let grab = drag == .corner ? corners[2] : (drag == .edge ? edgeMid(corners) : centre(corners))
                XCTAssertTrue(loupe.beginCropDrag(atViewPoint: grab),
                              "\\(g.label)/\\(drag.rawValue): 真实路径没收下这次按下")
                let expectedHandle: CropToolHandle = drag == .corner ? .bottomRight
                    : (drag == .edge ? .right : .inside)
                XCTAssertEqual(loupe.cropTool.lastHandle, expectedHandle,
                               "\\(g.label)/\\(drag.rawValue): 抓错了把手")

                let step: (Double, Double) = drag == .corner ? (5, 4) : (drag == .edge ? (5, 0) : (3, 2))
                var mouse = grab
                var worst = 0.0
                for _ in 1...20 {
                    mouse.x += CGFloat(step.0)
                    mouse.y += CGFloat(step.1)
                    loupe.continueCropDrag(atViewPoint: mouse)
                    let now = try drawn(loupe)
                    let tracked = drag == .corner ? now[2] : (drag == .edge ? edgeMid(now) : centre(now))
                    worst = max(worst, hypot(Double(tracked.x - mouse.x),
                                             Double(tracked.y - mouse.y)))
                }
                loupe.endCropDrag()
                worstAll = max(worstAll, worst)
                rows.append(String(format: "362 ① %@/%@ max %.3f px", g.label, drag.rawValue, worst))
                Self.note(rows.last!)
                XCTAssertLessThanOrEqual(worst, 1.5,
                    "\\(g.label)/\\(drag.rawValue): overlay 画出来的点与鼠标差 \\(worst) px —— 不跟手")
            }
        }
        Self.note(String(format: "362 ① 十二组跟手 max %.3f px", worstAll))
    }

    /// **With the shipped ratio lock on** (原始 = the sensor's own 3:2). 355's suite always set the
    /// lock to 自由, which is exactly the configuration that skips every size re-cut — and the size
    /// law used to convert the lock's ratio with the **photograph's** dimensions even for a `.canvas`
    /// rect: at 9°/+60 the canvas is 6553×4909 against the photo's 6000×4000, so a locked frame was
    /// re-cut to 1.335 (11 % narrower) **on every tick**. That is the reported 「框的大小经常跳变」,
    /// so this case measures the drawn size's per-tick change and the drawn ratio — not 「跟手」, which
    /// a ratio lock legitimately bends along its constrained direction.
    func testALockedFrameDoesNotJumpOrDriftOffItsRatio() throws {
        for g in Self.groups {
            let (loupe, _) = try makeLoupe(g)
            loupe.cropTool.setAspect(.original)
            seed(loupe, 0.55)
            loupe.cropTool.setAspect(.original)
            loupe.refreshCropTool()
            CropUITestSupport.pump(0.01)
            let lock = try XCTUnwrap(loupe.cropTool.draft.lock.ratio, "\(g.label): 原始 应当锁定")
            func size(_ c: [CGPoint]) -> (w: Double, h: Double) {
                (hypot(Double(c[1].x - c[0].x), Double(c[1].y - c[0].y)),
                 hypot(Double(c[3].x - c[0].x), Double(c[3].y - c[0].y)))
            }
            // The drawn width/height are both in points on the same uniform camera, so their ratio
            // **is** the rect's pixel ratio — no unit conversion, and nothing to get wrong.
            let corners = try drawn(loupe)
            XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
            var previous = size(corners)
            var worst = 0.0
            var worstRatio = abs(previous.w / previous.h - lock)
            var mouse = corners[2]
            for _ in 1...20 {
                mouse.x += 12
                mouse.y += 8
                loupe.continueCropDrag(atViewPoint: mouse)
                let now = size(try drawn(loupe))
                worst = max(worst, max(abs(now.w - previous.w), abs(now.h - previous.h)))
                worstRatio = max(worstRatio, abs(now.w / now.h - lock))
                previous = now
            }
            loupe.endCropDrag()
            Self.note(String(format: "362 ①锁 %@ · max|Δ| %.2f px · 比例偏差 %.4f · 锁定 %.2f",
                             g.label, worst, worstRatio, lock))
            XCTAssertLessThanOrEqual(worst, 20.0,
                "\(g.label) 锁定: 相邻 tick 的框尺寸跳了 \(worst) px（鼠标只走了 12 pt）")
            XCTAssertLessThanOrEqual(worstRatio, 0.02,
                "\(g.label) 锁定: 画出来的框偏离锁定比例 \(worstRatio)")

            // **反向门 ④** — the size law converting with the photograph's dimensions instead of the
            // rect's own (355's spelling). It only bites where the two grids differ: a `.canvas` rect
            // on a **turned** document (6553×4909 against 6000×4000). At 0° the warped photograph's
            // AABB keeps the sensor's aspect, and a `.source` rect is measured in the photograph
            // anyway — neither has anything to jump, which is why 355's cases could not expose this.
            if loupe.cropTool.draft.cropSpace == .canvas, g.degrees != 0 {
                seed(loupe, 0.55)
                loupe.cropTool.setAspect(.original)
                loupe.refreshCropTool()
                CropUITestSupport.pump(0.01)
                loupe.cropTool.convertsTheLockInSourceUnits = true
                let start = try drawn(loupe)
                XCTAssertTrue(loupe.beginCropDrag(atViewPoint: start[2]))
                var m = start[2]
                var gateWorst = 0.0
                var gatePrevious = size(start)
                for _ in 1...20 {
                    m.x += 12
                    m.y += 8
                    loupe.continueCropDrag(atViewPoint: m)
                    let now = size(try drawn(loupe))
                    gateWorst = max(gateWorst, max(abs(now.w - gatePrevious.w),
                                                   abs(now.h - gatePrevious.h)))
                    gatePrevious = now
                }
                loupe.endCropDrag()
                loupe.cropTool.convertsTheLockInSourceUnits = false
                Self.note(String(format: "362 ①锁门 %@ · 源尺寸换算 · max|Δ| %.2f px（必须 > 20）",
                                 g.label, gateWorst))
                XCTAssertGreaterThan(gateWorst, 20.0,
                    "\(g.label): 用照片尺寸换算锁定比例竟然不跳 —— 这条验收没有判别力")
            }
        }
    }

    // MARK: - ② 「不出像素」：外拖 30 tick，零超界（用画出来的框判）

    func testBStaysInsidePixelsNeverLeavesThePhoto() throws {
        for g in Self.groups {
            let (loupe, _) = try makeLoupe(g)
            seed(loupe, 0.7, pixels: true)
            XCTAssertTrue(loupe.cropTool.cropStaysInsidePixels)
            let corners = try drawn(loupe)
            XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
            var mouse = corners[2]
            var samples = 0, outside = 0
            var worst = Double.infinity
            for _ in 1...30 {
                mouse.x += 12
                mouse.y += 12
                loupe.continueCropDrag(atViewPoint: mouse)
                let frame = try drawn(loupe)
                let quad = try photoQuadInView(g, loupe)
                for index in 0..<4 {
                    let a = frame[index], b = frame[(index + 1) % 4]
                    for step in 0...10 {
                        let t = CGFloat(step) / 10
                        let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                        samples += 1
                        let d = inset(p, quad: quad)
                        worst = min(worst, d)
                        if d < -1e-6 { outside += 1 }
                    }
                }
            }
            loupe.endCropDrag()
            Self.note(String(format: "362 ② %@ 采样 %d · 超出 %d · 最差内距 %.3f px · 夹取 %d",
                             g.label, samples, outside, worst, loupe.cropTool.pixelPresses))
            XCTAssertEqual(outside, 0,
                "\(g.label): 「不出像素」开着，画出来的框还有 \(outside)/\(samples) 个采样在照片外")
            XCTAssertGreaterThan(loupe.cropTool.pixelPresses, 0,
                                 "\(g.label): 30 tick 一次都没夹 —— 这条验收没有判别力")

            // **反向门 ③** — 355 的每 tick 夹取只做 `.canvas` 矩形。把那条路放回去，同一个外拖必须
            // 漏像素（这就是用户说的「开启了像素内还出像素」），否则这条验收没有判别力。
            if loupe.cropTool.draft.cropSpace != .canvas {
                seed(loupe, 0.7, pixels: true)
                loupe.cropTool.pressesOnlyCanvasPixels = true
                let again = try drawn(loupe)
                XCTAssertTrue(loupe.beginCropDrag(atViewPoint: again[2]))
                var m = again[2]
                var gateOutside = 0, gateSamples = 0
                for _ in 1...30 {
                    m.x += 12
                    m.y += 12
                    loupe.continueCropDrag(atViewPoint: m)
                    let frame = try drawn(loupe)
                    let quad = try photoQuadInView(g, loupe)
                    for index in 0..<4 {
                        let a = frame[index], b = frame[(index + 1) % 4]
                        for step in 0...10 {
                            let t = CGFloat(step) / 10
                            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                            gateSamples += 1
                            if inset(p, quad: quad) < -1e-6 { gateOutside += 1 }
                        }
                    }
                }
                loupe.endCropDrag()
                loupe.cropTool.pressesOnlyCanvasPixels = false
                Self.note(String(format: "362 ②门 %@ 只夹 .canvas · 超出 %d/%d（必须 > 0）",
                                 g.label, gateOutside, gateSamples))
                XCTAssertGreaterThan(gateOutside, 0,
                    "\(g.label): 只夹 .canvas 竟然也不漏像素 —— 验收 ② 没有判别力")
            }
        }
    }

    // MARK: - ③ 跳变：相邻 tick 的宽高差

    func testCTheDrawnSizeNeverJumps() throws {
        for g in Self.groups {
            let (loupe, _) = try makeLoupe(g)
            seed(loupe, 0.5, pixels: true)
            let corners = try drawn(loupe)
            XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
            var mouse = corners[2]
            func size(_ c: [CGPoint]) -> (w: Double, h: Double) {
                (hypot(Double(c[1].x - c[0].x), Double(c[1].y - c[0].y)),
                 hypot(Double(c[3].x - c[0].x), Double(c[3].y - c[0].y)))
            }
            var previous = size(try drawn(loupe))
            var worstW = 0.0, worstH = 0.0
            for _ in 1...20 {
                mouse.x += 12
                mouse.y += 12
                loupe.continueCropDrag(atViewPoint: mouse)
                let now = size(try drawn(loupe))
                worstW = max(worstW, abs(now.w - previous.w))
                worstH = max(worstH, abs(now.h - previous.h))
                previous = now
            }
            loupe.endCropDrag()
            // The mouse moves (12, 12) pt per tick; a corner drag's two edges can therefore each grow
            // by at most 12·√2 pt, plus one pixel of rounding.
            let budget = (144.0 + 144.0).squareRoot() + 1
            Self.note(String(format: "362 ③ %@ max|Δw| %.2f px · max|Δh| %.2f px · 预算 %.2f px",
                             g.label, worstW, worstH, budget))
            XCTAssertLessThanOrEqual(worstW, budget,
                "\\(g.label): 相邻 tick 的宽跳了 \\(worstW) px（鼠标只走了 12 pt）")
            XCTAssertLessThanOrEqual(worstH, budget,
                "\\(g.label): 相邻 tick 的高跳了 \\(worstH) px（鼠标只走了 12 pt）")
        }
    }

    // MARK: - ④ 输入映射 == 绘制映射（同一函数）

    /// 同一个 view 点，经**两条路径**得到同一个数值：
    ///
    ///   · A = `cropBoxPoint` —— 拖动读指针的那条；
    ///   · B = `drawingProjection(...).normalized` —— overlay 绘制用的那份投影的逆。
    ///
    /// 两条都必须 ≤1e−12。再加一条只用 overlay layout 的检查：把鼠标按在**画出来的右下角**上，
    /// 拖动写下来的归一化坐标必须就是那个角的坐标（≤1e−9）—— 这就是「手抓到的」与「画出来的」是
    /// 同一个东西。
    func testDTheInputMapIsTheDrawingMap() throws {
        for g in Self.groups {
            let (loupe, _) = try makeLoupe(g)
            seed(loupe, 0.55)
            let scale = loupe.backingScale
            let framing = try XCTUnwrap(loupe.framing())
            let mapping = framing.mapping(of: loupe.viewState)
            let source = loupe.cropSourceSize
            let corners = try drawn(loupe)
            let box = try XCTUnwrap(loupe.cropTool.cropBoxPoint(fromView: corners[2], mapping: mapping,
                                                                source: source, pointScale: scale),
                                    "\(g.label): cropBoxPoint 对画出来的角返回 nil")
            let effective = loupe.cropTool.effectiveCrop(source: source)
            let cornerError = max(abs(box.x - effective.right), abs(box.y - effective.bottom))
            Self.note(String(format: "362 ④ %@ 画出来的右下角 → (%.12f,%.12f) · draft (%.12f,%.12f) · 差 %.3e",
                             g.label, box.x, box.y, effective.right, effective.bottom, cornerError))
            XCTAssertLessThanOrEqual(cornerError, 1e-9,
                "\(g.label): 按住画出来的角，拖动读到的归一化坐标差了 \(cornerError)")

            var worst = 0.0, worstBack = 0.0
            let mid = centre(corners)
            for i in -2...2 {
                for j in -2...2 {
                    let p = CGPoint(x: mid.x + CGFloat(i) * 12, y: mid.y + CGFloat(j) * 12)
                    let a = try XCTUnwrap(loupe.cropTool.cropBoxPoint(fromView: p, mapping: mapping,
                                                                      source: source, pointScale: scale))
                    let projection = loupe.cropTool.drawingProjection(source: source, mapping: mapping,
                                                                       pointScale: scale)
                    let b = try XCTUnwrap(projection.normalized(viewX: Double(p.x),
                                                               viewY: Double(p.y)))
                    worst = max(worst, max(abs(a.x - b.x), abs(a.y - b.y)))
                    let back = projection.view(a.x, a.y)
                    worstBack = max(worstBack, hypot(Double(back.x - p.x), Double(back.y - p.y)))
                }
            }
            Self.note(String(format: "362 ④ %@ 两条路径最大差 %.3e · 往返最大差 %.3e px",
                             g.label, worst, worstBack))
            XCTAssertLessThanOrEqual(worst, 1e-12,
                "\(g.label): 输入映射与绘制映射不是同一个函数（差 \(worst)）")
            XCTAssertLessThanOrEqual(worstBack, 1e-9,
                "\(g.label): 画出来的点经这条映射走回来差了 \(worstBack) px")
        }
    }

    // MARK: - ⑤ 反向门：输入退回 355 之前那条路，(9°,+60) 必红

    /// 355 之前 `continueDrag` 把指针读成 **frame space**（`framePoint` + `R⁻¹`，不含 `P`），而 overlay
    /// 照旧按文档画布的网格画。门把输入切回那条路，验收 ① 的 (9°,+60) 组必须红。
    func testGateTheOldPointerReadTurnsTheKeystoneGroupRed() throws {
        let g = Self.groups[2]
        let (loupe, _) = try makeLoupe(g)
        seed(loupe, 0.55)
        loupe.cropTool.dragMapsThroughFramePoint = true
        let corners = try drawn(loupe)
        XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
        var mouse = corners[2]
        var worst = 0.0
        for _ in 1...20 {
            mouse.x += 5
            mouse.y += 4
            loupe.continueCropDrag(atViewPoint: mouse)
            let now = try drawn(loupe)
            worst = max(worst, hypot(Double(now[2].x - mouse.x), Double(now[2].y - mouse.y)))
        }
        loupe.endCropDrag()
        Self.note(String(format: "362 ⑤ 门·旧指针映射 %@ 跟手 max %.3f px（必须 > 1.5）",
                        g.label, worst))
        XCTAssertGreaterThan(worst, 1.5,
            "门：把输入退回 355 之前的 frame-space 读法竟然还跟手 —— 验收 ① 没有判别力")
    }
}
