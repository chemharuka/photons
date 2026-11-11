import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsCore
@testable import PhotonsUI

/// **380 — 「不出像素」开着时，整体拖动裁切框仍然「乱跳 + 出界」。**
///
/// 用户口径（2026-11-11）：
///
///   > 现在校正+旋转后，打开不出像素再拖动裁剪框，还是会导致尺寸乱跳+出界。拖动裁剪框的侧边做
///   > 拉长/变窄不会
///
/// 371 修的是**尺寸手柄**（`draggedEdges != nil`）。整体拖动是 `.inside`，它走的是另一条路：
/// `translatedInsidePhotoQuad` 每 tick 重新做一次「哪个方向最快回到区域、要走多远」的**方向扫描 +
/// 60 次采样二分**（步长 0.02、上限 2.5 归一化）。于是画面上看到的位移不是手的增量，而是搜索的输出 ——
/// 一跳可以是几十到几千像素；而 `limit` 网格上的近似解又每 tick 落在区域外一点点。
///
/// 380 把整体拖动的约束做成**投影**：平移不改形状，所以「框 ⊆ 画布 ∩ 照片」等价于「四个角都在两个
/// 区域里」= 4 角 × 4 边 × 2 区域 = 32 条线性不等式，`t` 是框自己的归一化单位。手落在可行集内 →
/// 原样采用；落在外面 → 取最近点。闭式、无采样、幂等。
///
/// 本文件走真实路径（`LoupeController.beginCropDrag` / `continueCropDrag`），几何用测试自己的闭式
/// 重推（同 362/368/371），**不**读被测代码的 quad。
///
/// ① 轨迹 A（外拖 30 tick × 12 pt）：被钉住后相邻 tick 的 `Δleft/Δtop` **逐位** = 0；
/// ② 轨迹 A：**每个 tick** 都量四角到照片四边形的越界量，最大越界 ≤ 0.5 px；
/// ③ 轨迹 B（回拖 20 tick）：第一 tick 跳变 ≤ 1.0 px，之后每 tick |位移 − 手步长| ≤ 1.0 px；
/// ④ 幂等：同一 tick 连喂两次 `draft.crop` 逐位相同；`project(project(t)) == project(t)`（6 个点）；
/// ⑤ 不做搜索：`directionScans == 0`，每 tick 一次指针投影；
/// ⑩ 网格自洽：`documentQuad(of: .full)` 与 `photoQuadInDocumentPixels380()` 是同一组点（§5.1）；
/// ⑨ 反向门：把 `.inside` 换回搜索式（`searchesMoves380`）→ ①②③ 必红。
@MainActor
final class CropMovePixelPress380Tests: XCTestCase {

    static let source = ImageSize(width: 6000, height: 4000)

    private var workDir: URL!
    private var editors: [EditorWindowController] = []
    private var savedStaysInside: Any?

    struct Geometry {
        let label: String
        let degrees: Double
        let vertical: Double
        /// 规格 §3 的「cropSpace 两种各跑一遍」。规格的三组几何里只有 `v == 0` 的那组能选
        /// (`liveCropSpace` 在带透视的文档上一律回答 `.canvas`)，所以透视组只跑 `.canvas`。
        let space: CropSpace
    }

    static let geometries: [Geometry] = [
        Geometry(label: "9° v0 source", degrees: 9, vertical: 0, space: .source),
        Geometry(label: "9° v0 canvas", degrees: 9, vertical: 0, space: .canvas),
        Geometry(label: "0° v+60", degrees: 0, vertical: 60, space: .canvas),
        Geometry(label: "9° v+60", degrees: 9, vertical: 60, space: .canvas),
    ]

    /// 轨迹 A 的几何参数：每 tick 的手步长（pt）与 tick 数。
    static let outwardStep = 12.0
    static let outwardTicks = 30
    static let returnTicks = 20

    override func setUpWithError() throws {
        savedStaysInside = UserDefaults.standard.object(forKey: CropToolController.staysInsidePixelsKey)
        UserDefaults.standard.removeObject(forKey: CropToolController.staysInsidePixelsKey)
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-380-\(UUID().uuidString)", isDirectory: true)
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

    private func makeLoupe(_ g: Geometry) throws -> (LoupeController, CatalogSession) {
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
            edit.geometry.perspectiveHorizontal = 0
            edit.geometry.cropSpace = g.vertical == 0 ? g.space : .canvas
        }
        CropUITestSupport.pump(0.02)
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, editor.session),
                      "\(g.label): 裁切 mode 没打开")
        CropUITestSupport.pump(0.05)
        return (loupe, editor.session)
    }

    /// A frame of `span` about the centre, 「不出像素」 on.
    private func seed(_ loupe: LoupeController, _ span: Double) {
        loupe.cropTool.draft.crop = CropRect(left: 0.5 - span / 2, top: 0.5 - span / 2,
                                             right: 0.5 + span / 2, bottom: 0.5 + span / 2)
        _ = loupe.cropTool.setCropStaysInsidePixels(true)
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.01)
    }

    private func drawn(_ loupe: LoupeController) throws -> [CGPoint] {
        let layout = try XCTUnwrap(loupe.cropOverlayLayoutForTesting,
                                   "overlay 没在画框（layout == nil）")
        XCTAssertEqual(layout.corners.count, 4, "框不是四边形")
        return layout.corners
    }

    private func centre(_ c: [CGPoint]) -> CGPoint {
        CGPoint(x: c.reduce(0) { $0 + $1.x } / 4, y: c.reduce(0) { $0 + $1.y } / 4)
    }

    // MARK: - the picture's quad in view points (the test's own closed form, as 362/368/371)

    private func photoQuadDocumentPixels(_ g: Geometry) -> [DocumentPoint] {
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

    private func photoQuadPhotoPixels(_ g: Geometry) -> [(x: Double, y: Double)] {
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

    /// §7 —— **the frame's own corners, in the same grid as the picture's quad.**
    ///
    /// A `.source` crop is a rectangle of the *photograph's pixel grid* and the overlay draws it
    /// un-turned; the picture's quad is that same grid **rotated by θ**. So both live in photo
    /// pixels and both start at `(0, 0)` — there is no `documentOrigin` in this comparison, and
    /// subtracting one (as `photoQuadDocumentPixels` legitimately does for the *canvas* grid) is what
    /// produced the −275.93 px = `documentOrigin.x` false alarm this helper exists to remove.
    private func frameCornersPhotoPixels(_ crop: CropRect) -> [(x: Double, y: Double)] {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        return [(crop.left, crop.top), (crop.right, crop.top),
                (crop.right, crop.bottom), (crop.left, crop.bottom)]
            .map { (x: $0.0 * w, y: $0.1 * h) }
    }

    private func photoQuadInView(_ g: Geometry, _ loupe: LoupeController) throws -> [CGPoint] {
        let framing = try XCTUnwrap(loupe.framing(), "no framing")
        let mapping = framing.mapping(of: loupe.viewState)
        let scale = loupe.backingScale
        if g.vertical != 0 || g.space == .canvas {
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

    // MARK: - one tick

    private struct MoveTick {
        let crop: CropRect
        let corners: [CGPoint]
        /// worst corner inset to the photo quad, in points (= px at this zoom)
        let minInset: Double
        /// 归一化「出界」量：`[0,1]²` 之外多少。`.source` 的合法区域就是这个式子（§6.2），
        /// `.canvas` 的合法区域是画布（同一个式子，两种空间都以自己的归一化单位表示）。
        let outside: Double
        let pressed: Bool
    }

    private func tick(_ loupe: LoupeController, quad: [CGPoint],
                      pressesBefore: Int) throws -> MoveTick {
        let corners = try drawn(loupe)
        return MoveTick(crop: loupe.cropTool.draft.crop,
                        corners: corners,
                        minInset: corners.map { inset($0, quad: quad) }.min() ?? 0,
                        outside: outsideUnitSquare(loupe.cropTool.draft.crop),
                        pressed: loupe.cropTool.pixelPresses > pressesBefore)
    }

    // MARK: - trajectories

    /// 按下框中心（`.inside`），外拖 `outwardTicks` × `outwardStep`。
    private func startMove(_ g: Geometry, span: Double = 0.45)
        throws -> (LoupeController, [CGPoint], CGPoint) {
        let (loupe, _) = try makeLoupe(g)
        loupe.cropTool.setAspect(.original)
        seed(loupe, span)
        loupe.cropTool.setAspect(.original)
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.01)
        let quad = try photoQuadInView(g, loupe)
        let corners = try drawn(loupe)
        let grab = centre(corners)
        XCTAssertTrue(loupe.beginCropDrag(atViewPoint: grab),
                      "\(g.label): 框中心的按下没有被接住")
        XCTAssertEqual(loupe.cropTool.lastHandle, .inside,
                       "\(g.label): 按下的不是 .inside（整体拖动）")
        return (loupe, quad, grab)
    }

    private func outward(_ loupe: LoupeController, from start: CGPoint,
                         quad: [CGPoint]) throws -> (ticks: [MoveTick], mouse: CGPoint) {
        var mouse = start
        var ticks = [try tick(loupe, quad: quad, pressesBefore: Int.max)]
        for _ in 1...Self.outwardTicks {
            mouse.x += CGFloat(Self.outwardStep)
            mouse.y += CGFloat(Self.outwardStep)
            let before = loupe.cropTool.pixelPresses
            loupe.continueCropDrag(atViewPoint: mouse)
            ticks.append(try tick(loupe, quad: quad, pressesBefore: before))
        }
        return (ticks, mouse)
    }

    // MARK: - ① / ② 轨迹 A

    func testOneOncePinnedTheMoveIsFrozenAndNeverLeavesThePhoto() throws {
        for g in Self.geometries {
            let (loupe, quad, start) = try startMove(g)
            _ = KeystoneTranslationProbe380.takeDirectionScans()
            let run = try outward(loupe, from: start, quad: quad)
            let ticks = run.ticks
            loupe.endCropDrag()
            let scans = KeystoneTranslationProbe380.takeDirectionScans()

            let pinned = try XCTUnwrap(ticks.firstIndex { $0.pressed },
                                       "\(g.label): \(Self.outwardTicks) tick 没有一次夹取 —— 没有判别力")
            XCTAssertLessThanOrEqual(pinned, ticks.count - 2,
                                     "\(g.label): 夹取只发生在最后一 tick —— 量不到「钉住之后」")

            // ① 被钉住之后逐位不变。
            var maxFrozenDelta = 0.0
            var bitwise = true
            for index in (pinned + 1)..<ticks.count {
                let a = ticks[index].crop, b = ticks[index - 1].crop
                if !(a.left == b.left && a.top == b.top && a.right == b.right && a.bottom == b.bottom) {
                    bitwise = false
                }
                maxFrozenDelta = max(maxFrozenDelta,
                                     abs(a.left - b.left), abs(a.top - b.top))
            }
            // ② 每个 tick 都量，不只量终点。
            //
            // 两种空间量的是**两种区域**，都要量：
            //   · 归一化越界（`[0,1]²`）—— `.source` 的全部判据就是这个（§6.2），`.canvas` 是画布；
            //   · 视图空间的四角内距（照片四边形）—— 这是 `.canvas` 的判据（框 = `documentQuad`，与照片
            //     同一个旋转网格）。`.source` 的框是**不旋转**的（overlay 画的就是它），把它拿来跟
            //     **旋转后**的照片四边形比，是 §6.3 指出的那个错位 —— 所以 `.source` 不量这条。
            let overflow = ticks.map(\.minInset).min() ?? 0
            let outside = ticks.map(\.outside).max() ?? 0
            let pinnedTicks = ticks.filter(\.pressed).count

            print(String(format: "380 ① %@ · tick %d · 钉住 %d tick（第 %d tick 起）· 夹后 max|Δleft/Δtop| %.3e · 逐位 %@ · directionScans %d",
                         g.label, ticks.count, pinnedTicks, pinned, maxFrozenDelta,
                         bitwise ? "是" : "否", scans))
            print(String(format: "380 ② %@ · 归一化越界 max %.3e（%.1f px）· 视图四角最小内距 %.3f px（末 tick %.3f）",
                         g.label, outside, outside * Double(Self.source.width),
                         overflow, ticks.last?.minInset ?? 0))

            XCTAssertTrue(bitwise,
                          "\(g.label): 钉住之后框还在动（max|Δ| \(maxFrozenDelta)）—— 这就是「乱跳」")
            XCTAssertEqual(maxFrozenDelta, 0,
                           "\(g.label): 钉住之后 Δleft/Δtop 不是逐位 0（\(maxFrozenDelta)）")
            XCTAssertLessThanOrEqual(outside, 1e-9,
                "\(g.label): 轨迹里有一 tick 的框跑出合法区域 \(outside)（归一化，[0,1]²）")
            if g.space == .canvas {
                XCTAssertGreaterThanOrEqual(overflow, -0.5,
                    "\(g.label): 轨迹里有一 tick 的角跑出照片四边形 \(overflow) px —— 这就是「出界」")
            }
            XCTAssertEqual(scans, 0,
                "\(g.label): 整体拖动路径上调了 \(scans) 次方向扫描（translated 的搜索）")
        }
    }

    // MARK: - ③ 轨迹 B：回拖从钉住的位置继续，跟手

    func testTwoReturningFollowsTheHandWithoutADeadZone() throws {
        let step = hypot(Self.outwardStep, Self.outwardStep)
        for g in Self.geometries {
            let (loupe, quad, start) = try startMove(g)
            let outwardRun = try outward(loupe, from: start, quad: quad)
            let pinned = try XCTUnwrap(outwardRun.ticks.firstIndex { $0.pressed },
                                       "\(g.label): 没有夹住 —— 回拖验收没有判别力")
            _ = pinned

            var mouse = CGPoint(x: start.x + CGFloat(Self.outwardStep) * CGFloat(Self.outwardTicks),
                                y: start.y + CGFloat(Self.outwardStep) * CGFloat(Self.outwardTicks))
            var previous = try drawn(loupe)
            var deviations: [Double] = []
            for _ in 1...Self.returnTicks {
                mouse.x -= CGFloat(Self.outwardStep)
                mouse.y -= CGFloat(Self.outwardStep)
                loupe.continueCropDrag(atViewPoint: mouse)
                let now = try drawn(loupe)
                let moved = hypot(Double(centre(now).x - centre(previous).x),
                                  Double(centre(now).y - centre(previous).y))
                deviations.append(abs(moved - step))
                previous = now
            }
            let after = try drawn(loupe)
            loupe.endCropDrag()

            let first = deviations[0]
            let worst = deviations.dropFirst().max() ?? 0
            let travelled = hypot(Double(centre(after).x - centre(previous).x),
                                  Double(centre(after).y - centre(previous).y))
            _ = travelled
            print(String(format: "380 ③ %@ · 首 tick 跳变 %.3f px · 之后 max|位移−手步长| %.3f px · 手步长 %.2f px · 回拖 %d tick",
                         g.label, first, worst, step, Self.returnTicks))
            XCTAssertLessThanOrEqual(first, 1.0,
                "\(g.label): 回拖第一 tick 与手步长差 \(first) px —— 框没从钉住的位置继续")
            XCTAssertLessThanOrEqual(worst, 1.0,
                "\(g.label): 回拖每 tick |位移 − 手步长| 最大 \(worst) px")
        }
    }

    // MARK: - ④ 幂等

    func testThreeTheProjectionIsIdempotent() throws {
        // (a) 几何函数本身：6 个点，`project(project(t)) == project(t)`（逐位）。
        for g in Self.geometries {
            let geometry = Self.cropGeometry(g, crop: NormalizedRect(x: 0.3, y: 0.3,
                                                                     width: 0.3, height: 0.3))
            let set = try XCTUnwrap(geometry.moveFeasibleSet380(of: geometry.crop),
                                    "\(g.label): 没有可行集")
            let points: [(Double, Double)] = [(0.45, 0.45), (-0.45, 0.45), (0.45, -0.45),
                                              (-0.45, -0.45), (0.0, 0.0), (0.9, -0.2)]
            for p in points {
                let once = try XCTUnwrap(set.project(x: p.0, y: p.1),
                                         "\(g.label): project(\(p)) == nil")
                let twice = try XCTUnwrap(set.project(x: once.x, y: once.y),
                                          "\(g.label): project∘project == nil")
                XCTAssertEqual(twice.x, once.x, "\(g.label): project 不幂等 x @ \(p)")
                XCTAssertEqual(twice.y, once.y, "\(g.label): project 不幂等 y @ \(p)")
                XCTAssertTrue(set.isFeasible(x: once.x, y: once.y, tolerance: 1e-9),
                              "\(g.label): project 的结果自己不可行 @ \(p)")
            }
            print(String(format: "380 ④ %@ · 6 点 project∘project == project（逐位）· 约束 %d 条",
                         g.label, set.constraints.count))
        }

        // (b) 真实路径：同一个屏幕点连喂两次，`draft.crop` 逐位相同；每 tick 一次指针投影。
        for g in Self.geometries {
            let (loupe, quad, start) = try startMove(g)
            let run = try outward(loupe, from: start, quad: quad)
            _ = quad
            var mouse = run.mouse
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
            print(String(format: "380 ④b %@ · 同点两次逐位相同 %@ · 每 tick 指针投影 %d 次",
                         g.label, first == second ? "是" : "否", worstProjections))
            XCTAssertEqual(first, second,
                "\(g.label): 同一个屏幕点连喂两次，draft.crop 变了（不幂等）")
            XCTAssertEqual(worstProjections, 1,
                "\(g.label): 一个 tick 走了 \(worstProjections) 次指针投影（必须 1）")
        }
    }

    // MARK: - ⑩ / §5.1 网格自洽（同一原点）

    private static func cropGeometry(_ g: Geometry, crop: NormalizedRect) -> CropGeometry {
        let group = GeometryGroup(crop: crop, rotationDegrees: g.degrees,
                                  perspectiveVertical: g.vertical, perspectiveHorizontal: 0,
                                  cropSpace: g.vertical == 0 ? g.space : .canvas)
        return CropGeometry(geometry: group, source: source)
    }

    /// ⑩ —— 同一批「照片的四个角」在两条走法下必须是同一组点：`photoQuadInDocumentPixels380()`
    /// （本次投影用的那组）与 `warpedTurnedPhotoCorners − documentOrigin`（324 的 `photoQuad()` 的算术，
    /// 这条路的**另一个**拼写）。两条都扣同一个 `documentOrigin`，差必须 ≤ 1e-9。
    ///
    /// 判别力在下面这段：把 `origin: o` 去掉（回到单入口的默认 origin），在 364 的反向门
    /// （`foldsDocumentOriginIntoCanvas = false`）下两边**必然**裂开一个 `documentOrigin`（本机实测
    /// 242–614 px）。默认值恰好等于 `documentOrigin` 时这条恒等式看不出差别 —— 所以门必须翻；这也是
    /// 我不靠默认值、把 `origin: o` 写死的原因。
    func testFourThePhotoQuadAndTheDocumentQuadAgreeOnOneGrid() {
        for g in Self.geometries {
            let geometry = Self.cropGeometry(g, crop: .full)
            let o = geometry.documentOrigin
            let picture = geometry.warpedTurnedPhotoCorners
                .map { DocumentPoint($0.x - o.x, $0.y - o.y) }
            let region = DocumentRegion(picture)
            let canvas = DocumentRegion.axisAligned(width: geometry.photoQuadExtent.width,
                                                    height: geometry.photoQuadExtent.height)
            let fromPhoto = geometry.photoQuadInDocumentPixels380()
            XCTAssertEqual(fromPhoto.count, 4)

            var worst = 0.0
            for (a, b) in zip(picture, fromPhoto) {
                worst = max(worst, abs(a.x - b.x), abs(a.y - b.y),
                            abs(region.inset(a) - region.inset(b)))
            }
            // 同一网格的第二个说法：`.source` 的整幅 rect 就是照片本身，所以 `documentQuad(.full)`
            // 也落在同一组点上。`.canvas` 的整幅 rect 是画布（不是照片），这条不成立、也不该成立。
            var quadWorst = 0.0
            if g.vertical == 0, g.space == .source {
                for (a, b) in zip(geometry.documentQuad(of: .full), fromPhoto) {
                    quadWorst = max(quadWorst, abs(a.x - b.x), abs(a.y - b.y))
                }
            }
            print(String(format: "380 ⑩ %@ · photoQuadInDocumentPixels380 vs warpedTurned−origin · 最大差 %.3e px · documentQuad(.full) 差 %.3e · documentOrigin (%.3f, %.3f)",
                         g.label, worst, quadWorst, o.x, o.y))
            XCTAssertLessThanOrEqual(worst, 1e-9,
                "\(g.label): 两组「照片四角」不在同一网格上（差 \(worst) px）—— §5.1 的缺陷形状")
            XCTAssertLessThanOrEqual(quadWorst, 1e-9,
                "\(g.label): `.source` 的 documentQuad(.full) 与照片四角差 \(quadWorst) px")

            // §5.1 的自检：crop (0.3,0.3,0.6,0.6)、t = (0.45,0.45)，四角 inset 全部 ≥ −1e-6。
            let probe = Self.cropGeometry(g, crop: NormalizedRect(x: 0.3, y: 0.3,
                                                                  width: 0.3, height: 0.3))
            let set = probe.moveFeasibleSet380(of: probe.crop)
            if let set {
                let p = set.project(x: 0.45, y: 0.45)
                XCTAssertNotNil(p, "\(g.label): project(0.45,0.45) == nil")
                if let p {
                    let moved = CropRect(left: probe.crop.left + p.x, top: probe.crop.top + p.y,
                                         right: probe.crop.right + p.x,
                                         bottom: probe.crop.bottom + p.y)
                    // The frame's own four corners, in the space it lives in (§5.2/§6.3):
                    // · `.canvas` — `documentQuad`, i.e. turned exactly like the picture, so the
                    //   photo's quad in document pixels is the right region;
                    // · `.source` — the frame is **not** turned (§6.3): its legality is the plain
                    //   `[0,1]²` of the photograph's own normalized grid. Measuring it against the
                    //   turned quad would be this task's own bug, in a test.
                    let photoInset: Double
                    if g.vertical == 0, g.space == .source {
                        photoInset = -max(0, -moved.left, -moved.top,
                                          moved.right - 1, moved.bottom - 1)
                            * Double(Self.source.width)
                    } else {
                        photoInset = probe.documentQuad(of: moved).map { region.inset($0) }.min() ?? 0
                    }
                    let canvasInset: Double
                    if g.vertical == 0, g.space == .source {
                        let legal = probe.documentCanvasCropRect
                        canvasInset = -max(0, legal.left - moved.left, moved.right - legal.right,
                                           legal.top - moved.top, moved.bottom - legal.bottom)
                            * Double(Self.source.width)
                    } else {
                        canvasInset = probe.documentQuad(of: moved).map { canvas.inset($0) }.min() ?? 0
                    }
                    print(String(format: "380 §5.1 %@ · project(0.45,0.45) = (%.9f, %.9f) · 四角最小 inset 照片 %.6f / 画布 %.6f px",
                                 g.label, p.x, p.y, photoInset, canvasInset))
                    XCTAssertGreaterThanOrEqual(photoInset, -1e-6,
                        "\(g.label): 投影说可行，框出了照片 \(photoInset) px（§5.1）")
                    XCTAssertGreaterThanOrEqual(canvasInset, -1e-6,
                        "\(g.label): 投影说可行，框出了画布 \(canvasInset) px")
                }
            }

            // 门：默认 origin 在 364 的门翻过来以后与显式 origin 差一个 `documentOrigin`。
            DocumentCanvasConvention364.foldsDocumentOriginIntoCanvas = false
            defer { DocumentCanvasConvention364.foldsDocumentOriginIntoCanvas = true }
            let defaulted = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map {
                geometry.documentPointInCanvas(normalizedX: $0.0, $0.1)
            }
            let explicit = geometry.photoQuadInDocumentPixels380()
            if max(abs(o.x), abs(o.y)) > 1.0 {
                let divergence = zip(defaulted, explicit)
                    .map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
                print(String(format: "380 ⑩ 门 %@ · 默认 origin 与显式 origin 的最大差 %.3f px（必须 > 1，否则 ⑩ 没有判别力）",
                             g.label, divergence))
                XCTAssertGreaterThan(divergence, 1.0,
                    "\(g.label): 去掉 origin: o 竟然没有差别 —— ⑩ 没有判别力")
            }
        }
    }

    // MARK: - ⑥ 371 的尺寸手柄不回退（数字见验收日志；这里只钉住「它不是这条路」）

    func testFiveTheSizeHandlesStillGoThroughTheirOwnPress() throws {
        for g in Self.geometries {
            let (loupe, _) = try makeLoupe(g)
            seed(loupe, 0.5)
            let corners = try drawn(loupe)
            XCTAssertTrue(loupe.beginCropDrag(atViewPoint: corners[2]))
            XCTAssertNotNil(loupe.cropTool.lastHandle?.draggedEdges,
                            "\(g.label): 角上的按下必须是尺寸手柄（371 的路），不是整体拖动")
            loupe.endCropDrag()
        }
    }

    // MARK: - ⑨ 反向门：换回搜索式，①②③ 必红

    func testGateTheSearchStillJittersAndLeavesThePhoto() throws {
        let g = Self.geometries[3]                     // 9° + v60：搜索式在这里最坏
        let (loupe, quad, start) = try startMove(g)
        loupe.cropTool.searchesMoves380 = true
        let run = try outward(loupe, from: start, quad: quad)
        let ticks = run.ticks

        // 判别力就在这里：搜索式被钉住之后**不是**逐位冻结的 —— 它每 tick 从候选重新扫一个方向、
        // 二分一个距离，于是框沿边界往后creep（本机实测 0.0007→0.0056 归一化 ≈ 5–37 px）。投影式
        // 的对应数字是 0.000e+00（①）。用「第一次贴到边界」而不是 `pixelPresses` 定位，因为搜索式
        // 的 `.inside` 分支（`pressedToPixels` 的 `edges == nil` 早退）根本不涨 `pixelPresses`。
        let touching = ticks.firstIndex { $0.minInset <= 1.0 }
        var maxFrozenDelta = 0.0
        if let touching, touching + 1 < ticks.count {
            for index in (touching + 1)..<ticks.count {
                maxFrozenDelta = max(maxFrozenDelta,
                                     abs(ticks[index].crop.left - ticks[index - 1].crop.left),
                                     abs(ticks[index].crop.top - ticks[index - 1].crop.top))
            }
        }
        let overflow = ticks.map(\.minInset).min() ?? 0

        // 回拖：搜索式每 tick 重新挑方向/距离，第一 tick 会跳。
        var mouse = run.mouse
        var previous = try drawn(loupe)
        var firstJump = 0.0
        for index in 1...Self.returnTicks {
            mouse.x -= CGFloat(Self.outwardStep)
            mouse.y -= CGFloat(Self.outwardStep)
            loupe.continueCropDrag(atViewPoint: mouse)
            let now = try drawn(loupe)
            let moved = hypot(Double(centre(now).x - centre(previous).x),
                              Double(centre(now).y - centre(previous).y))
            if index == 1 { firstJump = abs(moved - hypot(Self.outwardStep, Self.outwardStep)) }
            previous = now
        }
        loupe.endCropDrag()
        loupe.cropTool.searchesMoves380 = false

        print(String(format: "380 ⑨ 门 %@ · 搜索式 · 贴边后 max|Δ| %.6f（归一化）· 轨迹最小内距 %.3f px · 回拖首 tick 跳变 %.3f px（①②③ 必须红）",
                     g.label, maxFrozenDelta, overflow, firstJump))
        XCTAssertTrue(maxFrozenDelta > 1e-9 || overflow < -0.5 || firstJump > 1.0,
            "门：换回搜索式竟然不跳也不出界 —— ①②③ 没有判别力")
    }

    // MARK: - ⑪ ⑫ ⑬ ⑭ §6.4 —— `.source` 在自己的归一化坐标里投影

    /// ⑪ 与 ⑫ 的两条轨迹几何：`.source` 空间，θ = 0° 与 9°（§6.2 主线探针的那两组）。
    static let sourceGeometries: [Geometry] = [
        Geometry(label: "0° v0 source", degrees: 0, vertical: 0, space: .source),
        Geometry(label: "9° v0 source", degrees: 9, vertical: 0, space: .source),
    ]

    private struct MoveLaw380 {
        let ticks: [CropRect]
        /// 逐 tick 的最大越界量（归一化单位，`0` = 一直在 `[0,1]²` 里）。
        let worstOutside: Double
        /// 后 10 tick 里 `draft.crop` 逐位不变的 tick 数（旧口径，保留打印用）。
        let frozen: Int
        /// 全程 30 tick 里逐位不变的 tick 数（与 §6.2 探针的 `frozen ticks x/30` 同一口径）。
        let frozenTotal: Int
        /// §7 —— **钉住之后**逐位不变的 tick 数（⑫ 的分子）。与「后 10 tick」无关：一条 30 tick 的
        /// 轨迹可能在第 27 tick 才碰到边界，用「后 10 tick ≥ 8」判定的话任何正确实现都过不了。
        let frozenAfterPin: Int
        /// §7 —— 钉住之后剩下的 tick 数（⑫ 的分母）。
        let ticksAfterPin: Int
        let pinnedAt: Int?
        /// §7 —— 轨迹中途可行集变空（`project` 返回 `nil`）。那是既有透视几何缺陷，不是 380 的
        /// 投影算错：同一帧连 `isFeasible(0,0)` 都是 `false`，即「当前框自己就不可行」。
        let ranOutOfFeasibleSet: Bool
        let stoppedAt: Int?
    }

    private func translated(_ r: CropRect, by t: (x: Double, y: Double)) -> CropRect {
        CropRect(left: r.left + t.x, top: r.top + t.y,
                 right: r.right + t.x, bottom: r.bottom + t.y)
    }

    /// 一个裁切 rect 离开 `[0,1]²` 的量，归一化单位。`.source` 的 rect 是照片自己的归一化坐标、
    /// `.canvas` 的 rect 是画布的归一化坐标 —— 两条都是「自己空间里的轴对齐矩形」，判据同一个式子
    /// （§6.2：`.source` 的合法区域就是 `0 ≤ left, top` 且 `right, bottom ≤ 1`）。
    private func outsideUnitSquare(_ r: CropRect) -> Double {
        max(0, -r.left, -r.top, r.right - 1, r.bottom - 1)
    }

    /// 一条 30 tick 的外推轨迹，逐 tick 与 `CropToolController.projectedMove380` **逐字同构**：
    /// `follows` 写手给的 rect、`pressed` 写投影、`held`（钉住后还在往外推）什么都不写。
    ///
    /// 几何参数取 §6.2 主线探针的那一组：base `(0.3, 0.3, 0.6, 0.6)`，手每 tick `+0.015`（对角线）。
    private func moveLaw380(_ g: Geometry, insidePhotoPixels: Bool = true) throws -> MoveLaw380 {
        let block = NormalizedRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3)
        let geometry = Self.cropGeometry(g, crop: block)
        let base0 = geometry.crop
        var base = base0
        var hand = (x: 0.0, y: 0.0)
        var pinned = false
        var pinnedAt: Int?
        var ticks: [CropRect] = [base]
        var stoppedAt: Int?
        for index in 1...Self.outwardTicks {
            hand.x += 0.015
            hand.y += 0.015
            let handRect = translated(base0, by: hand)
            let set = try XCTUnwrap(geometry.moveFeasibleSet380(of: base,
                                                                insidePhotoPixels: insidePhotoPixels),
                                    "\(g.label): tick \(index) 没有可行集")
            let t = (x: handRect.left - base.left, y: handRect.top - base.top)
            guard let p = set.project(x: t.x, y: t.y) else {
                // §7 —— 可行集是空集（透视 + 旋转下「这张框已经放不进任何位置」）。记录并停止，
                // 由调用方决定：`.source` 判红（那是本单的缺陷），`.canvas` 记账（既有几何问题）。
                stoppedAt = index
                break
            }
            if p.x == t.x, p.y == t.y {
                base = handRect                              // follows：手给的 rect 原样采用
                pinned = false
            } else if pinned {
                // held：钉住后手还在往外推 → 一个字节都不写（`ticks` 里原样重复上一帧）
            } else {
                base = translated(base, by: p)               // pressed：写在边界上
                pinned = true
                pinnedAt = pinnedAt ?? index
            }
            ticks.append(base)
        }
        var frozen = 0, frozenTotal = 0
        for i in 1..<ticks.count {
            if ticks[i] == ticks[i - 1] {
                frozenTotal += 1
                if i >= ticks.count - 10 { frozen += 1 }
            }
        }
        // §7 —— the freeze that matters is "after the frame is pinned, it does not move again".
        // Measured over `[pinnedAt, last]`, so a trajectory that only reaches the boundary at tick 27
        // is still judged on the property, not on how long it happened to run.
        var frozenAfterPin = 0
        var ticksAfterPin = 0
        if let pinnedAt {
            for i in (pinnedAt + 1)..<ticks.count {
                ticksAfterPin += 1
                if ticks[i] == ticks[i - 1] { frozenAfterPin += 1 }
            }
        }
        return MoveLaw380(ticks: ticks,
                          worstOutside: ticks.map(outsideUnitSquare).max() ?? 0,
                          frozen: frozen, frozenTotal: frozenTotal,
                          frozenAfterPin: frozenAfterPin, ticksAfterPin: ticksAfterPin,
                          pinnedAt: pinnedAt,
                          ranOutOfFeasibleSet: stoppedAt != nil, stoppedAt: stoppedAt)
    }

    /// ⑪ + ⑫ —— `.source`：θ=9° 与 θ=0° 各跑一遍同一条轨迹。
    ///
    /// 改前（§6.2 主线探针）：θ=9° `worst outside 0.03936513…`（≈ 236 px）、`frozen ticks 0/30`；
    /// θ=0° `0.0` / `3/30`。修法（§6.3 方案 A）之后 θ=9° 的出界必须是 0。
    ///
    /// **⑫ 的判据已按 §7 修正**（主线 2026-11-11 18:0x 实测）：原来写「后 10 tick 里 ≥ 8 个冻结」，
    /// 但 30 tick × 0.015 的轨迹在**第 27 tick 才碰到边界**，剩下只有 3 个 tick —— 任何正确实现都
    /// 不可能冻结 8 个。正确的性质是「**钉住之后**逐位不动」，与钉住发生在第几 tick 无关：
    /// 量 `[pinnedAt, 末 tick]` 这一段里逐位不变的 tick 数，并要求它等于这一段的全长。
    func testSixSourceSpaceStaysInsideThePhotoAndFreezes() throws {
        for g in Self.sourceGeometries {
            let run = try moveLaw380(g)
            let px = run.worstOutside * Double(Self.source.width)
            let sample = Self.cropGeometry(g, crop: NormalizedRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3))
            let rows = sample.moveFeasibleSet380(of: sample.crop)?.constraints.count ?? 0
            print(String(format: "380 ⑪ %@ · %d tick 逐 tick 最大越界 %.9e（归一化，≈ %.1f px）· 首次钉住在第 %@ tick",
                         g.label, run.ticks.count - 1, run.worstOutside, px,
                         run.pinnedAt.map { String($0) } ?? "—"))
            print(String(format: "380 ⑫ %@ · 钉住后逐位不变 %d/%d · 全程冻结 %d/%d · 约束 %d 条",
                         g.label, run.frozenAfterPin, run.ticksAfterPin,
                         run.frozenTotal, run.ticks.count - 1, rows))

            XCTAssertNotNil(run.pinnedAt, "\(g.label): 30 tick 一次都没被夹住 —— ⑫ 没有判别力")
            XCTAssertLessThanOrEqual(run.worstOutside, 1e-9,
                "\(g.label): 有一 tick 的框跑出照片 \(run.worstOutside)（归一化，\(px) px）—— 这就是「出界」")
            // ⑫（§7 修正）—— 钉住之后必须**每一个** tick 都逐位不变，而不是「后 10 tick 里凑够 8 个」。
            XCTAssertGreaterThanOrEqual(run.ticksAfterPin, 3,
                "\(g.label): 钉住后只剩 \(run.ticksAfterPin) 个 tick，测不出冻结 —— 轨迹太短")
            XCTAssertEqual(run.frozenAfterPin, run.ticksAfterPin,
                "\(g.label): 钉住后 \(run.ticksAfterPin) 个 tick 里只有 \(run.frozenAfterPin) 个逐位不变 —— 这就是「尺寸乱跳」")
        }
    }

    /// ⑬ —— `.canvas` 空间不回归：θ=9° 同样两条判据，且四角到照片四边形的 `photoInset ≥ −1e-6` px。
    /// （`.canvas` 分支一行没改；这条是「别把它改坏」的哨兵。）
    ///
    /// **⑬ 已按 §7 收窄**（主线 2026-11-11 18:0x 实测）：`θ=9° v=+60` 的轨迹到第 24 tick 时
    /// `project` 返回 `nil`，且同一帧 `isFeasible(0,0) == false` —— **当前框自己就不可行**，可行集是
    /// 空集。这是透视 + 旋转下「框已经放不进任何位置」的既有几何问题（324/370 的领域），
    /// **不是 380 引入的**，也不该由 380 的投影去修。本单的口径：这一组只断言**它能跑完的那一段**
    /// 不出界、且钉住后冻结；`nil` 单独记账进 `QUEUE-DISPATCH.md` 的风险表，等一张透视几何单。
    func testSevenCanvasSpaceDoesNotRegress() throws {
        for g in Self.geometries where g.space == .canvas {
            let run = try moveLaw380(g)
            let geometry = Self.cropGeometry(g, crop: .full)
            let picture = DocumentRegion(photoQuadDocumentPixels(g))
            var minInset = Double.infinity
            for rect in run.ticks {
                let quad = geometry.documentQuad(of: rect)
                minInset = min(minInset, quad.map { picture.inset($0) }.min() ?? 0)
            }
            print(String(format: "380 ⑬ %@ · 逐 tick 最大越界 %.9e（归一化）· 四角最小 photoInset %.6f px · 钉住后冻结 %d/%d · 全程 %d/%d · 可行集空 %@",
                         g.label, run.worstOutside, minInset,
                         run.frozenAfterPin, run.ticksAfterPin,
                         run.frozenTotal, run.ticks.count - 1,
                         run.ranOutOfFeasibleSet ? "是" : "否"))
            XCTAssertLessThanOrEqual(run.worstOutside, 1e-9,
                "\(g.label): `.canvas` 出界 \(run.worstOutside)（归一化）")
            XCTAssertGreaterThanOrEqual(minInset, -1e-6,
                "\(g.label): `.canvas` 四角出了照片 \(minInset) px（回归）")
            if run.ranOutOfFeasibleSet {
                // 既有几何缺陷（见上）：这一段跑不完，只要求它停下之前没有出界，冻结无从判定。
                // 不是「通过」，是**记账** —— 队列风险表里点名等透视几何单。
                print("380 ⑬ \(g.label) —— 可行集在第 \(run.stoppedAt ?? -1) tick 变空（既有几何缺陷，非 380）：本组不判冻结")
            } else {
                XCTAssertGreaterThanOrEqual(run.ticksAfterPin, 3,
                    "\(g.label): 钉住后只剩 \(run.ticksAfterPin) 个 tick，测不出冻结")
                XCTAssertEqual(run.frozenAfterPin, run.ticksAfterPin,
                    "\(g.label): `.canvas` 钉住后 \(run.ticksAfterPin) 个 tick 里只有 \(run.frozenAfterPin) 个逐位不变（回归）")
            }
        }
    }

    /// ⑭ —— 反向门：「不出像素」关掉（`moveFeasibleSet380(insidePhotoPixels: false)`，正是
    /// `staysInsidePixels` 在这个函数里的参数）→ ⑪ 的判据必须红。同一条轨迹、同一个投影，
    /// 只少那四条照片约束；`worst outside` 回到 §6.2 的 0.03x 量级就说明 ⑪ 不是恒真。
    func testGateWithoutThePixelConstraintTheSourceMoveLeavesThePhoto() throws {
        let g = Self.sourceGeometries[1]                       // 9° `.source`
        let on = try moveLaw380(g)
        let off = try moveLaw380(g, insidePhotoPixels: false)
        let px = off.worstOutside * Double(Self.source.width)
        print(String(format: "380 ⑭ 门 %@ · staysInsidePixels 关 → 最大越界 %.9e（归一化，≈ %.1f px）· 开 %.9e",
                     g.label, off.worstOutside, px, on.worstOutside))
        XCTAssertLessThanOrEqual(on.worstOutside, 1e-9, "⑭ 前提：开的时候必须是不出界")
        XCTAssertGreaterThan(off.worstOutside, 1e-3,
            "门：关掉「不出像素」后框仍不出界（\(off.worstOutside)）—— ⑪ 没有判别力")
    }

    /// ⑪ ⑫ 的真实路径版：`LoupeController.beginCropDrag` / `continueCropDrag`，θ=9°、`.source`、
    /// 12 pt/tick × 30 tick。这里的数字直接读 `draft.crop`（用户看到的那一帧）。
    func testEightSourceSpaceHoldsUnderTheRealDrag() throws {
        let g = Geometry(label: "9° v0 source", degrees: 9, vertical: 0, space: .source)
        let (loupe, quad, start) = try startMove(g)
        let run = try outward(loupe, from: start, quad: quad)
        let ticks = run.ticks
        loupe.endCropDrag()

        let outside = ticks.map { outsideUnitSquare($0.crop) }.max() ?? 0
        var frozen = 0, frozenTotal = 0
        for i in 1..<ticks.count {
            if ticks[i].crop == ticks[i - 1].crop {
                frozenTotal += 1
                if i >= ticks.count - 10 { frozen += 1 }
            }
        }
        let pinned = ticks.firstIndex { $0.pressed }
        print(String(format: "380 ⑪/⑫ 真实拖动 %@ · 逐 tick 最大越界 %.9e（归一化，≈ %.1f px）· 后 10 tick 冻结 %d 个 · 全程 %d/%d · 首次夹取第 %@ tick",
                     g.label, outside, outside * Double(Self.source.width), frozen,
                     frozenTotal, ticks.count - 1,
                     pinned.map { String($0) } ?? "—"))
        XCTAssertLessThanOrEqual(outside, 1e-9,
            "\(g.label): 真实拖动里框出了照片 \(outside)（归一化）")
        XCTAssertGreaterThanOrEqual(frozen, 8,
            "\(g.label): 真实拖动里后 10 tick 只冻结了 \(frozen) 个")
    }
}


