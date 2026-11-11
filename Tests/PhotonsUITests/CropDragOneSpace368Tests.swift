import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **368 — 拖裁切框：一个空间、一块矩形、一次夹取。**
///
/// 用户口径：
///
///   > 校正+旋转后，拖动裁剪框，裁剪框尺寸一直在跳变。裁剪框是作用在文档画布上的，就是个标准矩形，
///   > 为什么会跳变？
///
/// 旧链每 tick 在 view / normalized / document / quad 之间来回换，并且三套限制轮流改同一个矩形：
/// 比例锁绕中心 reshape 一次、被拖的边按候选框**另一端**重新采样四边形、整框再平移一次。
/// 368 的 tick 只剩一个矩形表示、一次候选、一次夹取、一次写入。
///
/// 这个文件走**真实路径**（`LoupeController.beginCropDrag` / `continueCropDrag`），读的是 overlay
/// 实际画的 `layout.corners`，几何全部在测试里用闭式重推，不拿实现给自己打分。
///
/// ① 相邻 tick 的尺寸：在夹取边界上不许「回弹」（向外拖时宽/高只许停住或收缩，回弹 ≤ 1 px）；
/// ② 不出像素：外拖 30 tick，四边形外采样 0 %，宽度单调不增；
/// ③ 幂等：同一个屏幕点连喂两次，`draft.crop` 逐位相同；
/// ④ 一个空间：每个 tick 的指针投影计数 = 1；
/// ⑤ 比例锁：3:2 开着时逐 tick 比例恒定，且不逐 tick 变窄；
/// ⑦ 反向门：把 355 的双端采样放回去，② 的单调性必红。
@MainActor
final class CropDragOneSpace368Tests: XCTestCase {

    static let source = ImageSize(width: 6000, height: 4000)

    private var workDir: URL!
    private var editors: [EditorWindowController] = []

    struct Group {
        let label: String
        let degrees: Double
        let vertical: Double
    }

    /// 规格 ①/② 的三组几何：(9°, v=0) / (0, v=+60) / (9°, v=+60)。
    static let groups: [Group] = [
        Group(label: "9° v0", degrees: 9, vertical: 0),
        Group(label: "0° v+60", degrees: 0, vertical: 60),
        Group(label: "9° v+60", degrees: 9, vertical: 60),
    ]

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-368-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for editor in editors { editor.window?.close() }
        editors.removeAll()
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

    // MARK: - the picture's quad in view points (test's own closed form, as in 362)

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

    // MARK: - ① 相邻 tick：夹取边界不回弹

    /// 三组几何，默认的 3:2 锁开着，右下角沿对角线向外拖 20 tick（每 tick 12 pt），「不出像素」开着。
    ///
    /// 判「跳变」用的是**回弹**：一旦宽度开始停住/收缩（已经贴到四边形），后续 tick 不许再变宽
    /// 超过 1 px。旧链在这里会把宽度缩几 tick 再猛跳回去（实测 +10.89 / +9.95 px），这正是用户看到的
    /// 「尺寸一直在跳变」。同时贴边之前的每一 tick 必须跟手（Δw / Δh 与鼠标步长的差 ≤ 1 px）。
    func testOneTheSizeNeverBouncesAtTheClamp() throws {
        for g in Self.groups {
            let (loupe, _) = try makeLoupe(g)
            loupe.cropTool.setAspect(.original)
            seed(loupe, 0.85, pixels: true)
            loupe.cropTool.setAspect(.original)
            loupe.refreshCropTool()
            CropUITestSupport.pump(0.01)

            let corners = try drawn(loupe)
            XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
            var mouse = corners[2]
            var previous = size(try drawn(loupe))
            var widths: [Double] = [previous.w]
            var bounced = 0.0
            var worstFree = 0.0
            var stopped = false
            var pressed = false
            let lock = try XCTUnwrap(loupe.cropTool.draft.lock.ratio)
            let expectedH = 12.0 / lock
            for _ in 1...20 {
                mouse.x += 12
                mouse.y += 12
                let pressesBefore = loupe.cropTool.pixelPresses
                loupe.continueCropDrag(atViewPoint: mouse)
                if loupe.cropTool.pixelPresses > pressesBefore { pressed = true }
                let now = size(try drawn(loupe))
                widths.append(now.w)
                let dw = now.w - previous.w
                let dh = now.h - previous.h
                if dw <= 0.5 { stopped = true }
                if stopped {
                    bounced = max(bounced, dw)
                } else if !pressed {
                    worstFree = max(worstFree, max(abs(dw - 12), abs(dh - expectedH)))
                }
                previous = now
            }
            loupe.endCropDrag()
            XCTAssertTrue(stopped, "\(g.label): 20 tick 没有到达夹取边界 —— 这条验收没有判别力")
            XCTAssertGreaterThan(loupe.cropTool.pixelPresses, 0,
                                 "\(g.label): 一次都没夹 —— 这条验收没有判别力")
            XCTAssertLessThanOrEqual(worstFree, 1.0,
                "\(g.label): 贴边之前尺寸与手差 \(worstFree) px")
            XCTAssertLessThanOrEqual(bounced, 1.0,
                "\(g.label): 贴边之后宽度回弹了 \(bounced) px —— 尺寸在跳变")
            print(String(format: "368 ① %@ · 夹前跟手 %.2f px · 回弹 %.2f px · 停住 %@ · 宽度 %.1f→%.1f",
                         g.label, worstFree, bounced, stopped ? "是" : "否",
                         widths.first ?? 0, widths.last ?? 0))
        }
    }

    // MARK: - ② 不出像素：外拖 30 tick，零出界，宽度只收缩

    func testTwoStaysInsidePixelsShrinksMonotonically() throws {
        for g in Self.groups {
            let (loupe, _) = try makeLoupe(g)
            seed(loupe, 0.9, pixels: true)
            XCTAssertTrue(loupe.cropTool.cropStaysInsidePixels)
            let corners = try drawn(loupe)
            XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
            var previous = size(corners).w
            var samples = 0, outside = 0
            var grew = 0.0
            var worst = Double.infinity
            var mouse = corners[2]
            for _ in 1...30 {
                mouse.x += 12
                mouse.y += 12
                loupe.continueCropDrag(atViewPoint: mouse)
                let frame = try drawn(loupe)
                let width = size(frame).w
                grew = max(grew, width - previous)
                previous = width
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
            print(String(format: "368 ② %@ · 采样 %d · 超出 %d · 最差内距 %.3f px · 宽度回长 %.2f px · 夹 %d",
                         g.label, samples, outside, worst, grew, loupe.cropTool.pixelPresses))
            XCTAssertEqual(outside, 0,
                "\(g.label): 「不出像素」开着，画出来的框还有 \(outside)/\(samples) 个采样在照片外")
            XCTAssertLessThanOrEqual(grew, 1.0,
                "\(g.label): 外拖时宽度回长了 \(grew) px（只许停住或收缩）")
            XCTAssertGreaterThan(loupe.cropTool.pixelPresses, 0,
                                 "\(g.label): 30 tick 一次都没夹 —— 这条验收没有判别力")
        }
    }

    // MARK: - ③ 幂等：同一个屏幕点两次，逐位相同

    func testThreeTheSamePointIsBitIdentical() throws {
        for g in Self.groups {
            let (loupe, _) = try makeLoupe(g)
            seed(loupe, 0.7, pixels: true)
            let corners = try drawn(loupe)
            XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
            var mouse = corners[2]
            for _ in 1...5 {
                mouse.x += 7
                mouse.y += 5
                loupe.continueCropDrag(atViewPoint: mouse)
            }
            loupe.continueCropDrag(atViewPoint: mouse)
            let first = loupe.cropTool.draft.crop
            loupe.continueCropDrag(atViewPoint: mouse)
            let second = loupe.cropTool.draft.crop
            loupe.endCropDrag()
            XCTAssertEqual(first, second,
                "\(g.label): 同一个屏幕点连喂两次，draft.crop 变了（不幂等）")
            print("368 ③ \(g.label) · \(first.left),\(first.top),\(first.right),\(first.bottom)")
        }
    }

    // MARK: - ④ 一个空间：每 tick 一次指针投影

    func testFourOneProjectionPerTick() throws {
        for g in Self.groups {
            let (loupe, _) = try makeLoupe(g)
            seed(loupe, 0.6)
            let corners = try drawn(loupe)
            XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
            var mouse = corners[2]
            var worst = 0
            for _ in 1...20 {
                let before = loupe.cropTool.projectionRoundTrips
                mouse.x += 4
                mouse.y += 4
                loupe.continueCropDrag(atViewPoint: mouse)
                worst = max(worst, loupe.cropTool.projectionRoundTrips - before)
            }
            loupe.endCropDrag()
            XCTAssertEqual(worst, 1, "\(g.label): 一个 tick 走了 \(worst) 次指针投影（必须 1）")
            print("368 ④ \(g.label) · 每 tick 投影 \(worst) 次")
        }
    }

    // MARK: - ⑤ 比例锁：3:2 逐 tick 恒定，且不变窄

    func testFiveTheRatioStaysExactAndDoesNotNarrow() throws {
        for g in Self.groups {
            let (loupe, _) = try makeLoupe(g)
            loupe.cropTool.setAspect(.original)
            seed(loupe, 0.55)
            loupe.cropTool.setAspect(.original)
            loupe.refreshCropTool()
            CropUITestSupport.pump(0.01)
            let lock = try XCTUnwrap(loupe.cropTool.draft.lock.ratio)
            let corners = try drawn(loupe)
            XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
            var previousW = size(corners).w
            var worstRatio = 0.0
            var narrow = 0.0
            var mouse = corners[2]
            for _ in 1...20 {
                mouse.x += 6
                mouse.y += 4
                loupe.continueCropDrag(atViewPoint: mouse)
                let now = size(try drawn(loupe))
                worstRatio = max(worstRatio, abs(now.w / now.h - lock))
                narrow = max(narrow, previousW - now.w)
                previousW = now.w
            }
            loupe.endCropDrag()
            print(String(format: "368 ⑤ %@ · 比例偏差 %.3e · 逐 tick 变窄 %.3f px · 锁定 %.3f",
                         g.label, worstRatio, narrow, lock))
            XCTAssertLessThanOrEqual(worstRatio, 1e-9,
                "\(g.label): 画出来的框偏离锁定比例 \(worstRatio)")
            XCTAssertLessThanOrEqual(narrow, 1e-9,
                "\(g.label): 顺着手的锁定框逐 tick 变窄了 \(narrow) px（362 的 11 % 问题）")
        }
    }

    // MARK: - ⑦ 反向门

    /// 把 355 的双端采样放回去（`pressesWithBothEndpoints`），② 的「宽度只收缩」必须红：旧压法在贴边
    /// 之后会把宽度缩几 tick 再跳回去。这条保证 ② 有判别力，而不是「新实现自己说自己绿」。
    func testGateTheOldTwoEndpointPressBounces() throws {
        let g = Self.groups[2]
        let (loupe, _) = try makeLoupe(g)
        seed(loupe, 0.9, pixels: true)
        loupe.cropTool.pressesWithBothEndpoints = true
        let corners = try drawn(loupe)
        XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
        var previous = size(corners).w
        var grew = 0.0
        var mouse = corners[2]
        for _ in 1...30 {
            mouse.x += 12
            mouse.y += 12
            loupe.continueCropDrag(atViewPoint: mouse)
            let width = size(try drawn(loupe)).w
            grew = max(grew, width - previous)
            previous = width
        }
        loupe.endCropDrag()
        loupe.cropTool.pressesWithBothEndpoints = false
        print(String(format: "368 ⑦ 门·双端采样 %@ · 宽度回长 %.2f px（必须 > 1）", g.label, grew))
        XCTAssertGreaterThan(grew, 1.0,
            "门：把双端采样放回去竟然也不回弹 —— 验收 ② 没有判别力")
    }

    /// 把 317 的整框平移接回**每 tick**：它只能移动已经合法的框，尺寸与②的包含都不变 —— 这就是
    /// 368 删掉它的依据（一个 tick 只该有一次写入）。
    func testGateTheTranslationIsARedundantWrite() throws {
        for g in Self.groups {
            let (loupe, _) = try makeLoupe(g)
            seed(loupe, 0.9, pixels: true)
            loupe.cropTool.translatesSizeDragsInsidePixels = true
            let corners = try drawn(loupe)
            XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
            var mouse = corners[2]
            for _ in 1...10 {
                mouse.x += 8
                mouse.y += 8
                loupe.continueCropDrag(atViewPoint: mouse)
            }
            let gated = loupe.cropTool.draft.crop
            loupe.endCropDrag()

            seed(loupe, 0.9, pixels: true)
            loupe.cropTool.translatesSizeDragsInsidePixels = false
            let again = try drawn(loupe)
            XCTAssertTrue(loupe.beginCropDrag(atViewPoint: again[2]))
            var m = again[2]
            for _ in 1...10 {
                m.x += 8
                m.y += 8
                loupe.continueCropDrag(atViewPoint: m)
            }
            let plain = loupe.cropTool.draft.crop
            loupe.endCropDrag()
            print("368 ⑦ 门·每 tick 平移 · 与只有按压的结果差 "
                  + "\(abs(gated.left - plain.left) + abs(gated.top - plain.top))")
            XCTAssertEqual(gated.left, plain.left, accuracy: 1e-9,
                "\(g.label): 框已经合法时，317 的整框平移是一次多余的写")
            XCTAssertEqual(gated.top, plain.top, accuracy: 1e-9)
            XCTAssertEqual(gated.width, plain.width, accuracy: 1e-9)
            XCTAssertEqual(gated.height, plain.height, accuracy: 1e-9)
        }
    }
}
