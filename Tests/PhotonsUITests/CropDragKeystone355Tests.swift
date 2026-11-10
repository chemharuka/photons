import XCTest
import CoreGraphics
import PhotonsCore
@testable import PhotonsUI

/// **355 — 旋转 + 透视下拖裁切框：跟手、零超界、不跳变。**
///
/// 用户口径：
///
///   > 应用旋转+透视后调节裁剪框大小，裁剪框不跟鼠标……框的位置总是会与鼠标有偏差。
///   > 另外打开不出像素后，仍然有机会通过放大裁剪框把裁剪框弄出去，裁剪框的大小也经常跳变
///
/// 三条症状分开量、分开修。每一条都在**视图空间**量（`CropToolLayout.corners`，即用户眼睛看到的
/// 那个框），因为「跟手」只在视图空间里有意义：
///
///   ① 拖右下角 / 右 / 下 → 被抓住的角与鼠标的差 ≤ 1.5 px（四组几何）；
///   ② 拖框整体 → 纯平移，Δwidth = Δheight = 0（310 保持）；
///   ③ 「不出像素」开 → 外拖 30 tick，框的边采样超出 `photoQuad(document:)` 的 0 %，
///     最大尺寸停在四边形内切处；
///   ④ 关「不出像素」→ 仍可进黑角（307/324 保持）；
///   ⑤ 20 tick 的相邻宽高跳变 ≤ 鼠标增量换算值 + 1 px（含一次折返，夹取只许单调压住）。
///
/// 几何全部在本文件里按闭式重推（`P → R` / `R⁻¹ → P⁻¹`、四边形符号距离、`documentView` 的相似
/// 变换），不读 `CropGeometry` 的答案，所以这里的绿不是「拿实现给自己打分」。
@MainActor
final class CropDragKeystone355Tests: XCTestCase {

    private var workDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var keptSessions: [CatalogSession] = []

    static let source = ImageSize(width: 6000, height: 4000)
    static let viewport = ImageSize(width: 1400, height: 1000)

    struct Group {
        let label: String
        let degrees: Double
        let vertical: Double
        let horizontal: Double
    }

    /// 规格 §1 的四组几何：(9°,0)、(0,+60)、(9°,+60)、(9°,+60,h=+40)。
    static let groups: [Group] = [
        Group(label: "9° v0", degrees: 9, vertical: 0, horizontal: 0),
        Group(label: "0° v+60", degrees: 0, vertical: 60, horizontal: 0),
        Group(label: "9° v+60", degrees: 9, vertical: 60, horizontal: 0),
        Group(label: "9° v+60 h+40", degrees: 9, vertical: 60, horizontal: 40),
    ]

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-355-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        suiteName = "photons.crop355.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixtures

    private func mapping(_ g: Group) -> LoupeMapping {
        LoupeFraming(viewport: Self.viewport,
                     sourceWidth: Double(Self.source.width),
                     sourceHeight: Double(Self.source.height),
                     crop: .full,
                     straightenDegrees: g.degrees,
                     perspective: PerspectiveMap(vertical: g.vertical, horizontal: g.horizontal),
                     canvasRole: .document)
            .mapping(of: LoupeViewState(mode: .fit, zoom: 1))
    }

    /// A controller whose **document** carries the group's rotation and keystone — the draft is seeded
    /// by `begin()`, exactly like entering 裁切 on that document.
    private func makeController(_ g: Group, crop: CropRect) throws -> (CropToolController, LoupeMapping) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                            width: Self.source.width,
                                                            height: Self.source.height)
        keptSessions.append(session)
        session.applyEdit { edit in
            edit.geometry.rotationDegrees = g.degrees
            edit.geometry.perspectiveVertical = g.vertical
            edit.geometry.perspectiveHorizontal = g.horizontal
        }
        let controller = CropToolController(session: session, defaults: defaults)
        XCTAssertTrue(controller.begin())
        XCTAssertEqual(controller.sourceSize, Self.source)
        let map = mapping(g)
        controller.draft.crop = crop
        controller.draft.lock = .original
        _ = controller.clampToView(mapping: map, source: Self.source)
        return (controller, map)
    }

    private func canvasGeometry(_ crop: CropRect, _ g: Group) -> CropGeometry {
        CropGeometry(
            geometry: GeometryGroup(crop: crop.normalizedRect,
                                    rotationDegrees: g.degrees,
                                    aspectLock: .original,
                                    quarterTurns: 0,
                                    perspectiveVertical: g.vertical,
                                    perspectiveHorizontal: g.horizontal,
                                    cropSpace: .canvas),
            source: Self.source)
    }

    private func centred(_ span: Double) -> CropRect {
        CropRect(left: 0.5 - span / 2, top: 0.5 - span / 2,
                 right: 0.5 + span / 2, bottom: 0.5 + span / 2)
    }

    /// Document pixels per view point — the one scale the «mouse increment» is converted with.
    private func scale(_ map: LoupeMapping) -> Double {
        let a = map.documentView(DocumentPoint(0, 0))!
        let b = map.documentView(DocumentPoint(100, 0))!
        return (b.x - a.x) / 100
    }

    /// The unit the draft rect's normalized width/height are multiplied by to reach **pixels** — the
    /// photograph's own grid for a `.source` rect, the document canvas' (`photoQuadExtent`) for a
    /// `.canvas` one. 9° / 6000×4000: 6000 vs 6553, i.e. 9 % — reading the wrong one makes a perfectly
    /// following drag look 9 % / 22 % wrong.
    private func sizeUnit(_ g: Group) -> (w: Double, h: Double) {
        if g.vertical == 0 && g.horizontal == 0 {
            return (Double(Self.source.width), Double(Self.source.height))
        }
        let e = canvasGeometry(.full, g).photoQuadExtent
        return (e.width, e.height)
    }

    private func layout(_ controller: CropToolController, _ map: LoupeMapping) -> CropToolLayout {
        controller.layout(mapping: map, source: Self.source)
    }

    /// The frame's own screen axes (unit vectors), read off the drawn corners: `u` along the top edge,
    /// `v` down the left edge. The mouse increment projected on them is the expected Δwidth/Δheight.
    private func axes(_ controller: CropToolController, _ map: LoupeMapping) -> (u: CGPoint, v: CGPoint) {
        let c = layout(controller, map).corners
        func unit(_ dx: Double, _ dy: Double) -> CGPoint {
            let length = max((dx * dx + dy * dy).squareRoot(), 1e-12)
            return CGPoint(x: dx / length, y: dy / length)
        }
        return (unit(Double(c[1].x - c[0].x), Double(c[1].y - c[0].y)),
                unit(Double(c[3].x - c[0].x), Double(c[3].y - c[0].y)))
    }

    private func note(_ line: String) { print(line) }

    // MARK: - ① 拖右下角跟手（四组 × 两段位移）

    /// 从**画出来的**右下角按下（`layout.corners[2]`，就是手抓的那个像素），鼠标在视图空间走
    /// `(+100,+80)` 再 `(−60,+40)`，每 tick（20 步）量「画出来的右下角 − 鼠标」。
    func testOneCornerDragFollowsTheMouse() throws {
        var worstAll = 0.0
        for g in Self.groups {
            let (controller, map) = try makeController(g, crop: centred(0.55))
            let grab = layout(controller, map).corners[2]
            XCTAssertTrue(controller.beginDrag(atViewPoint: grab, mapping: map, source: Self.source))
            XCTAssertEqual(controller.lastHandle, .bottomRight,
                           "\(g.label): 按住画出来的右下角必须拿到 .bottomRight")

            let snapshot = controller.draft.crop
            let u = axes(controller, map).u, v = axes(controller, map).v
            let s = scale(map)
            var mouse = grab
            var worst = 0.0
            for (dx, dy) in [(100.0, 80.0), (-60.0, 40.0)] {
                for _ in 1...20 {
                    mouse.x += CGFloat(dx / 20)
                    mouse.y += CGFloat(dy / 20)
                    controller.continueDrag(atViewPoint: mouse, mapping: map, source: Self.source)
                    let drawn = layout(controller, map).corners[2]
                    worst = max(worst, hypot(Double(drawn.x - mouse.x),
                                              Double(drawn.y - mouse.y)))
                }
            }
            controller.endDrag()
            let after = controller.draft.crop
            let unit = sizeUnit(g)
            // Net mouse = (+40, +120); expected Δwidth/Δheight = the projection on the frame's own axes.
            let net = CGPoint(x: 40, y: 120)
            let expectedW = (Double(net.x) * Double(u.x) + Double(net.y) * Double(u.y)) / s
            let expectedH = (Double(net.x) * Double(v.x) + Double(net.y) * Double(v.y)) / s
            let ratioW = (after.width - snapshot.width) * unit.w / expectedW
            let ratioH = (after.height - snapshot.height) * unit.h / expectedH
            worstAll = max(worstAll, worst)
            note(String(format: "355 ① · %@ · 跟手 max %.3f px · 尺寸比 w %.4f h %.4f",
                        g.label, worst, ratioW, ratioH))
            XCTAssertLessThanOrEqual(worst, 1.5,
                "\(g.label): 被抓住的角与鼠标差 \(worst) px（>1.5 就是不跟手）")
            XCTAssertEqual(ratioW, 1.0, accuracy: 0.03,
                "\(g.label): Δwidth ÷ 鼠标增量 = \(ratioW)（≠1 说明两个空间不是一对）")
            XCTAssertEqual(ratioH, 1.0, accuracy: 0.03,
                "\(g.label): Δheight ÷ 鼠标增量 = \(ratioH)")
        }
        note(String(format: "355 ① · 四组跟手 max %.3f px", worstAll))
    }

    // MARK: - ①b 拖边（右、下）跟手

    func testOneBEdgeDragsFollowTheMouse() throws {
        var worstAll = 0.0
        for g in Self.groups {
            for edge in ["right", "bottom"] {
                let (controller, map) = try makeController(g, crop: centred(0.55))
                let corners = layout(controller, map).corners
                let grab: CGPoint
                if edge == "right" {
                    grab = CGPoint(x: (corners[1].x + corners[2].x) / 2,
                                   y: (corners[1].y + corners[2].y) / 2)
                } else {
                    grab = CGPoint(x: (corners[2].x + corners[3].x) / 2,
                                   y: (corners[2].y + corners[3].y) / 2)
                }
                XCTAssertTrue(controller.beginDrag(atViewPoint: grab, mapping: map,
                                                   source: Self.source))
                XCTAssertEqual(controller.lastHandle, edge == "right" ? .right : .bottom,
                               "\(g.label)/\(edge): 按住边中点必须拿到那条边")

                func drawnMid() -> CGPoint {
                    let c = layout(controller, map).corners
                    return edge == "right"
                        ? CGPoint(x: (c[1].x + c[2].x) / 2, y: (c[1].y + c[2].y) / 2)
                        : CGPoint(x: (c[2].x + c[3].x) / 2, y: (c[2].y + c[3].y) / 2)
                }
                var mouse = grab
                var worst = 0.0
                for _ in 1...20 {
                    if edge == "right" { mouse.x += 4 } else { mouse.y += 4 }
                    controller.continueDrag(atViewPoint: mouse, mapping: map, source: Self.source)
                    let drawn = drawnMid()
                    worst = max(worst, hypot(Double(drawn.x - mouse.x),
                                              Double(drawn.y - mouse.y)))
                }
                controller.endDrag()
                worstAll = max(worstAll, worst)
                note(String(format: "355 ①b · %@ / %@ · 跟手 max %.3f px", g.label, edge, worst))
                XCTAssertLessThanOrEqual(worst, 1.5, "\(g.label)/\(edge): 边与鼠标差 \(worst) px")
            }
        }
        note(String(format: "355 ①b · 四组 × 两边 · 跟手 max %.3f px", worstAll))
    }

    // MARK: - ② 拖框整体 = 纯平移（310）

    func testTwoMovingTheFrameDoesNotResizeIt() throws {
        for g in Self.groups {
            let (controller, map) = try makeController(g, crop: centred(0.5))
            let grab = layout(controller, map).center
            XCTAssertTrue(controller.beginDrag(atViewPoint: grab, mapping: map, source: Self.source))
            XCTAssertEqual(controller.lastHandle, .inside)
            let snapshot = controller.draft.crop
            var mouse = grab
            for _ in 1...20 {
                mouse.x += 5
                mouse.y += 3
                controller.continueDrag(atViewPoint: mouse, mapping: map, source: Self.source)
            }
            controller.endDrag()
            let after = controller.draft.crop
            let dw = abs(after.width - snapshot.width), dh = abs(after.height - snapshot.height)
            note(String(format: "355 ② · %@ · 纯平移 Δw %.3e Δh %.3e · 中心 (%.4f,%.4f) → (%.4f,%.4f)",
                        g.label, dw, dh, snapshot.centerX, snapshot.centerY,
                        after.centerX, after.centerY))
            XCTAssertLessThanOrEqual(dw, 1e-12, "\(g.label): 310 —— 拖动不改尺寸")
            XCTAssertLessThanOrEqual(dh, 1e-12, "\(g.label): 310 —— 拖动不改尺寸")
            XCTAssertNotEqual(after.centerX, snapshot.centerX, "\(g.label): 框必须真的动了")
        }
    }

    // MARK: - ⑤ 跳变：相邻 tick 的宽高变化（含折返）

    /// 拖右下角 20 tick：10 tick 向外（+4,+4）、10 tick 折返（−4,−4）。每 tick 的宽高换成**文档
    /// 像素**，相邻差与「鼠标增量在该帧自己的轴上的投影」比；夹取只许压住，不许弹回。
    func testFiveTheSizeNeverJumps() throws {
        for g in Self.groups {
            let (controller, map) = try makeController(g, crop: centred(0.5))
            _ = controller.setCropStaysInsidePixels(true)
            let grab = layout(controller, map).corners[2]
            XCTAssertTrue(controller.beginDrag(atViewPoint: grab, mapping: map, source: Self.source))
            let unit = sizeUnit(g)
            let u = axes(controller, map).u, v = axes(controller, map).v
            let s = scale(map)

            var mouse = grab
            var previous = controller.draft.crop
            var worstW = 0.0, worstH = 0.0, worstTick = 0
            var expectedWorst = 0.0
            for tick in 1...20 {
                let step = tick <= 10 ? 4.0 : -4.0
                mouse.x += CGFloat(step)
                mouse.y += CGFloat(step)
                controller.continueDrag(atViewPoint: mouse, mapping: map, source: Self.source)
                let now = controller.draft.crop
                let dw = abs(now.width - previous.width) * unit.w
                let dh = abs(now.height - previous.height) * unit.h
                let expectedW = abs(step * Double(u.x) + step * Double(u.y)) / s
                let expectedH = abs(step * Double(v.x) + step * Double(v.y)) / s
                expectedWorst = max(expectedWorst, max(expectedW, expectedH))
                if dw > worstW { worstW = dw; worstTick = tick }
                worstH = max(worstH, dh)
                previous = now
            }
            controller.endDrag()
            note(String(format: "355 ⑤ · %@ · max|Δw| %.2f px (tick %d) · max|Δh| %.2f px"
                        + " · 期望 %.2f px · 夹取 %d 次 · 末端 %.1f×%.1f",
                        g.label, worstW, worstTick, worstH, expectedWorst,
                        controller.pixelPresses,
                        controller.draft.crop.width * unit.w,
                        controller.draft.crop.height * unit.h))
            XCTAssertLessThanOrEqual(worstW, expectedWorst + 1,
                "\(g.label): 相邻 Δwidth \(worstW) px > \(expectedWorst + 1)")
            XCTAssertLessThanOrEqual(worstH, expectedWorst + 1,
                "\(g.label): 相邻 Δheight \(worstH) px > \(expectedWorst + 1)")
        }
    }

    // MARK: - ③ 「不出像素」：外拖 30 tick，零超界

    /// 框从画布中央 0.5 开始，勾上「不出像素」，右下角一路外拖 30 tick（每 tick 8 px）。每 tick 把
    /// 画出来的框的四条边各采样 11 点，统计落在 `photoQuad(document:)` 外的比例；末端尺寸与「四边形
    /// 内切」的宽高对照（最大尺寸停在四边形上）。
    func testThreeThePixelClampHoldsAtEveryTick() throws {
        for g in Self.groups where g.vertical != 0 || g.horizontal != 0 {
            let (controller, map) = try makeController(g, crop: centred(0.7))
            _ = controller.setCropStaysInsidePixels(true)
            XCTAssertTrue(controller.cropStaysInsidePixels)
            let grab = layout(controller, map).corners[2]
            XCTAssertTrue(controller.beginDrag(atViewPoint: grab, mapping: map, source: Self.source))

            var mouse = grab
            var samples = 0, outside = 0
            var worstInset = Double.infinity
            for _ in 1...30 {
                mouse.x += 12
                mouse.y += 12
                controller.continueDrag(atViewPoint: mouse, mapping: map, source: Self.source)
                let rect = controller.draft.crop
                let geometry = canvasGeometry(rect, g)
                let tickRegion = DocumentRegion(geometry.photoQuad())
                let quad = geometry.documentQuad(of: rect)
                for index in 0..<4 {
                    let a = quad[index], b = quad[(index + 1) % 4]
                    for step in 0...10 {
                        let t = Double(step) / 10
                        let p = DocumentPoint(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
                        samples += 1
                        let inset = tickRegion.inset(p)
                        worstInset = min(worstInset, inset)
                        if inset < -1e-6 { outside += 1 }
                    }
                }
            }
            controller.endDrag()

            let after = controller.draft.crop
            let geometry = canvasGeometry(after, g)
            let region = DocumentRegion(geometry.photoQuad())
            let inscribed = geometry.inscribedInPhotoQuad(after)
            let fraction = Double(outside) / Double(max(samples, 1))
            let unit = sizeUnit(g)
            note(String(format: "355 ③ · %@ · 采样 %d 点 · 超出 %d (%.3f %%) · 最差内距 %.3f px"
                        + " · 末端 %.1f×%.1f px · 内切上界 %.1f×%.1f px · 夹取 %d 次",
                        g.label, samples, outside, fraction * 100, worstInset,
                        after.width * unit.w, after.height * unit.h,
                        inscribed.width * unit.w, inscribed.height * unit.h,
                        controller.pixelPresses))
            XCTAssertEqual(outside, 0,
                "\(g.label): 「不出像素」开了还有 \(outside)/\(samples) 个采样在四边形外")
            XCTAssertGreaterThanOrEqual(worstInset, -1e-6, "\(g.label): 最差内距 \(worstInset) px")
            XCTAssertGreaterThan(controller.pixelPresses, 0,
                                 "\(g.label): 30 tick 一次都没夹 —— 这条验收没有判别力")
            // 「最大尺寸停在四边形上」：至少一条边贴到四边形（内切处），不是保守地缩在中间。
            let flush = geometry.documentQuad(of: after).map { region.inset($0) }.min() ?? 1
            XCTAssertLessThanOrEqual(flush, 1.0,
                "\(g.label): 末端没有贴住四边形（最近角内距 \(flush) px）")
        }
    }

    // MARK: - ④ 关「不出像素」仍可进黑角（307/324 保持）

    func testFourUncheckedStillAllowsTheBlackCorners() throws {
        let g = Self.groups[2]
        let (controller, map) = try makeController(g, crop: .full)
        XCTAssertFalse(controller.cropStaysInsidePixels)
        let grab = layout(controller, map).corners[2]
        XCTAssertTrue(controller.beginDrag(atViewPoint: grab, mapping: map, source: Self.source))
        var mouse = grab
        for _ in 1...20 {
            mouse.x += 20
            mouse.y += 20
            controller.continueDrag(atViewPoint: mouse, mapping: map, source: Self.source)
        }
        controller.endDrag()
        let after = controller.draft.crop
        let geometry = canvasGeometry(after, g)
        let region = DocumentRegion(geometry.photoQuad())
        let quad = geometry.documentQuad(of: after)
        let worst = quad.map { region.inset($0) }.min() ?? 0
        note(String(format: "355 ④ · %@ 未勾选 · 框 L %.4f T %.4f R %.4f B %.4f · 最差角内距 %.1f px",
                    g.label, after.left, after.top, after.right, after.bottom, worst))
        XCTAssertLessThan(worst, -1.0, "未勾选必须还能盖住 000000（307/324 不许被 355 改掉）")
    }

    // MARK: - 反向门

    /// 门 ①：夹取退回「视图空间夹」——只把框夹到屏幕上看得见的窗口里。同一个 30 tick 外拖，
    /// 应该有采样落到四边形外（验收 ③ 必须有判别力）。
    func testGateOneViewSpaceClampTurnsAcceptanceThreeRed() throws {
        let g = Self.groups[2]
        let (controller, map) = try makeController(g, crop: centred(0.7))
        XCTAssertTrue(controller.setCropStaysInsidePixels(true))
        controller.clampsPixelsInViewSpace = true
        let grab = layout(controller, map).corners[2]
        XCTAssertTrue(controller.beginDrag(atViewPoint: grab, mapping: map, source: Self.source))
        var mouse = grab
        var samples = 0, outside = 0
        var worst = Double.infinity
        for _ in 1...30 {
            mouse.x += 12
            mouse.y += 12
            controller.continueDrag(atViewPoint: mouse, mapping: map, source: Self.source)
            let rect = controller.draft.crop
            let geometry = canvasGeometry(rect, g)
            let region = DocumentRegion(geometry.photoQuad())
            for p in geometry.documentQuad(of: rect) {
                samples += 1
                let inset = region.inset(p)
                worst = min(worst, inset)
                if inset < -1e-6 { outside += 1 }
            }
        }
        controller.endDrag()
        note(String(format: "355 门① · 视图空间夹取 · 角点超出 %d/%d · 最差内距 %.1f px（必须 < −1 才算红）",
                    outside, samples, worst))
        XCTAssertGreaterThan(outside, 0, "门①：视图空间夹取竟然也零超界 —— 验收 ③ 没有判别力")
        XCTAssertLessThan(worst, -1.0, "门①：最差角内距 \(worst) px")
    }

    /// 门 ②：拖动走 `framePoint`（不含 `P`），绘制走 `documentPoint` + 画布尺度 —— 一手一图。
    func testGateTwoMixedMappingTurnsFollowRed() throws {
        let g = Self.groups[2]
        let (controller, map) = try makeController(g, crop: centred(0.55))
        controller.dragMapsThroughFramePoint = true
        let grab = layout(controller, map).corners[2]
        XCTAssertTrue(controller.beginDrag(atViewPoint: grab, mapping: map, source: Self.source))
        var mouse = grab
        var worst = 0.0
        for _ in 1...20 {
            mouse.x += 5
            mouse.y += 4
            controller.continueDrag(atViewPoint: mouse, mapping: map, source: Self.source)
            let drawn = layout(controller, map).corners[2]
            worst = max(worst, hypot(Double(drawn.x - mouse.x), Double(drawn.y - mouse.y)))
        }
        controller.endDrag()
        note(String(format: "355 门② · 拖动 framePoint / 绘制画布 · 跟手 max %.3f px（必须 > 1.5 才算红）", worst))
        XCTAssertGreaterThan(worst, 1.5, "门②：两个空间混用竟然跟手 —— 验收 ① 没有判别力")
    }

    /// 门 ③：夹取后**不回写增量** —— 每 tick 都走 317/324 那次绕中心的一次性内切
    /// （`inscribesPixelsOnEveryTick`），而不是只压被拖的那条边。夹一次、整框缩一次、对面边跟着动 ⇒
    /// 尺寸的相邻差超过鼠标增量的换算值。
    func testGateThreeNoIncrementWriteBackTurnsJumpRed() throws {
        let g = Self.groups[2]
        let (controller, map) = try makeController(g, crop: centred(0.8))
        _ = controller.setCropStaysInsidePixels(true)
        controller.inscribesPixelsOnEveryTick = true
        let grab = layout(controller, map).corners[2]
        XCTAssertTrue(controller.beginDrag(atViewPoint: grab, mapping: map, source: Self.source))
        let unit = sizeUnit(g)
        let u = axes(controller, map).u
        let s = scale(map)
        let expected = abs(12 * Double(u.x) + 12 * Double(u.y)) / s
        var mouse = grab
        var previous = controller.draft.crop
        var worst = 0.0
        for _ in 1...20 {
            mouse.x += 12
            mouse.y += 12
            controller.continueDrag(atViewPoint: mouse, mapping: map, source: Self.source)
            let now = controller.draft.crop
            worst = max(worst, abs(now.width - previous.width) * unit.w)
            previous = now
        }
        controller.endDrag()
        note(String(format: "355 门③ · 不回写增量 · max|Δwidth| %.1f px · 期望 %.1f px（必须 > 期望+1 才算红）",
                    worst, expected))
        XCTAssertGreaterThan(worst, expected + 1,
                             "门③：不回写增量竟然不跳 —— 验收 ⑤ 没有判别力")
    }
}
