import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **082 (追加) — 裁切模式的缩放 / 平移钳位：任何时候「裁切框 ⊆ 画布」.**
///
/// 用户的原话（2026-10-28，两条追加 + 一条语义澄清）：
///
///   > 裁切模式下，缩放与平移合成一个不变式：任何时候 裁切框 ⊆ 画布（图像）。
///   > ① 先算最大可放级别：maxZoom = min(canvasW / frameW, canvasH / frameH)（以裁切框为准，取两轴更紧
///   >   的那个）。② 缩放请求超界就钳住：请求超过 maxZoom → 实际停在 maxZoom，读数显示 maxZoom。
///   >   ③ 没超界但框被挤出边缘 → 自动平移：把画面平移量与框一起挪回 frame ⊆ canvas（不是只挪框）。
///
/// 于是 `CropCanvasClamp` 是唯一的几何（`fit(zoom:center:canvas:frame:)`），相机写入的唯一入口
/// （`LoupeController.setViewState`）套用它 —— 滚轮、捏合、pill、⌘=/⌘−、双击、拖拽平移、两指滚动
/// 都经过那一行。这一份钉六件事：
///
///   1. **maxZoom 数值**：2400×1600 画布 / 1200×800 框 → **2.000**，请求 250% → 实际 200.0%；
///      第二组尺寸（窗口/换照片）另给一个数，证明它不是常量。
///   2. **自动平移**：放大到框贴右边之后再请求 +10%，被钳住且框仍贴边不出界（四边坐标差 0 px）。
///   3. **四方向**：上/下/左/右各贴一次，`frame ⊆ canvas` 恒真。
///   4. **反证**：只钳缩放、不做自动平移 → 「框贴边不出界」必红，并贴出超出多少 px。
///   5. **平移手势走同一个函数**：拖到尽头不再动、反向 40 pt 立刻回 40 pt、自然滚动开/关结果相同。
///   6. **退出裁切恢复自由**：同一手势在普通模式下不受此限制（给进/出前后对照）。
@MainActor
final class CropCanvasClampTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-clamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - 1. the number

    /// `maxZoom = min(canvasW / frameW, canvasH / frameH)` — the level where the crop frame is exactly
    /// inscribed in the canvas. Two different size pairs, because the user said in so many words that it
    /// must not be a constant.
    func testMaxZoomIsTheFrameInscribedInTheCanvas() {
        // ① the pair from the acceptance: canvas 2400×1600, frame 1200×800 → 2.000
        let canvasA = CGSize(width: 2400, height: 1600)
        let frameA = CGRect(x: 600, y: 400, width: 1200, height: 800)
        XCTAssertEqual(CropCanvasClamp.maxZoom(canvas: canvasA, frame: frameA), 2.0, accuracy: 1e-12)

        // 250% is clamped to 200%, and the *readout* is the clamped value (that is what the camera stores).
        let requested = 2.5
        let actual = CropCanvasClamp.clampZoom(requested, canvas: canvasA, frame: frameA)
        print(String(format: "082 clamp · canvas %.0f×%.0f · frame %.0f×%.0f · maxZoom %.3f · "
                     + "requested %.0f%% → actual %.1f%%",
                     canvasA.width, canvasA.height, frameA.width, frameA.height,
                     CropCanvasClamp.maxZoom(canvas: canvasA, frame: frameA),
                     requested * 100, actual * 100))
        XCTAssertEqual(actual, 2.0, accuracy: 1e-12, "082: 请求 250% → 实际 200%")
        XCTAssertEqual(LoupeViewState.percentLabel(of: actual), "200%")
        XCTAssertEqual(LoupeViewState.percentLabel(of: CropCanvasClamp.clampZoom(4.0, canvas: canvasA,
                                                                                frame: frameA)), "200%")

        // Below the ceiling the request stands.
        XCTAssertEqual(CropCanvasClamp.clampZoom(1.5, canvas: canvasA, frame: frameA), 1.5, accuracy: 1e-12)

        // ② a different window and a different frame: the number follows both, it is not a constant.
        let canvasB = CGSize(width: 1600, height: 1600)      // narrower canvas
        let frameB = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let limitB = CropCanvasClamp.maxZoom(canvas: canvasB, frame: frameB)
        print(String(format: "082 clamp · canvas %.0f×%.0f · frame %.0f×%.0f · maxZoom %.3f",
                     canvasB.width, canvasB.height, frameB.width, frameB.height, limitB))
        XCTAssertEqual(limitB, 1600.0 / 1200.0, accuracy: 1e-12, "取两轴更紧的那个（宽）")
        XCTAssertNotEqual(limitB, 2.0)

        let canvasC = CGSize(width: 2400, height: 1600)
        let frameC = CGRect(x: 0, y: 0, width: 600, height: 400)   // half the crop → twice the ceiling
        XCTAssertEqual(CropCanvasClamp.maxZoom(canvas: canvasC, frame: frameC), 4.0, accuracy: 1e-12,
                       "框小一半，可放级别大一倍（并且被 400% 的阶梯顶住）")
        XCTAssertEqual(CropCanvasClamp.maxZoom(canvas: .zero, frame: frameA), 0, "退化输入没有合法相机")
    }

    // MARK: - 2 + 3 + 4. auto-pan, four directions, anti-proof (pure geometry)

    /// The frame flush on each of the four edges, then one more zoom request: the zoom is honoured (it is
    /// below the ceiling) and the **picture** is moved so the frame stays flush and inside — 0 px past.
    func testAutoPanKeepsTheFrameFlushOnEveryEdge() {
        let canvas = CGSize(width: 2400, height: 1600)
        let frame = CGRect(x: 600, y: 400, width: 1200, height: 800)
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let limit = CropCanvasClamp.maxZoom(canvas: canvas, frame: frame)

        /// Where the centre must sit for the frame to be flush on that edge, at `zoom`.
        func flush(_ edge: String, zoom: Double) -> (x: Double, y: Double) {
            let l = CropCanvasClamp.panLimits(canvas: canvas, frame: frame, zoom: zoom)
            let mid = (frame.midX, frame.midY)
            switch edge {
            case "right": return (l.x.lower, mid.1)
            case "left": return (l.x.upper, mid.1)
            case "top": return (mid.0, l.y.upper)
            default: return (mid.0, l.y.lower)
            }
        }

        for edge in ["right", "left", "top", "bottom"] {
            // ① flush at 100 %, then ask for 110 %: allowed by the ceiling, and the auto-pan has to move
            //    the picture so the frame does not run off the edge.
            let start = flush(edge, zoom: 1)
            let startRect = CropCanvasClamp.frameRect(canvas: canvas, frame: frame, zoom: 1, center: start)
            XCTAssertTrue(CropCanvasClamp.contains(startRect, in: canvasRect, tolerance: 0.001),
                          "082 §3 \(edge): 起点必须已经贴边且不出界 \(startRect)")

            let zoomOnly = CropCanvasClamp.clampZoom(1.1, canvas: canvas, frame: frame)
            let fitted = CropCanvasClamp.fit(zoom: 1.1, center: start, canvas: canvas, frame: frame)
            let rect = CropCanvasClamp.frameRect(canvas: canvas, frame: frame,
                                                 zoom: fitted.zoom, center: (fitted.centerX, fitted.centerY))
            print("082 §2 \(edge) · 请求 110%% → zoom \(String(format: "%.3f", fitted.zoom)) "
                  + "· pan (\(String(format: "%.2f", start.x))→\(String(format: "%.2f", fitted.centerX)), "
                  + "\(String(format: "%.2f", start.y))→\(String(format: "%.2f", fitted.centerY))) "
                  + "· 框 \(NSStringFromRect(rect)) · 画布 \(NSStringFromRect(canvasRect))")
            XCTAssertEqual(fitted.zoom, zoomOnly, accuracy: 1e-12, "110% 未超上限，缩放不该被改")
            XCTAssertTrue(CropCanvasClamp.contains(rect, in: canvasRect, tolerance: 0.001),
                          "082 §2 \(edge): 自动平移后框必须还在画布里 \(rect)")
            switch edge {
            case "right": XCTAssertEqual(rect.maxX, canvasRect.maxX, accuracy: 0.001)
            case "left": XCTAssertEqual(rect.minX, canvasRect.minX, accuracy: 0.001)
            case "top": XCTAssertEqual(rect.minY, canvasRect.minY, accuracy: 0.001)
            default: XCTAssertEqual(rect.maxY, canvasRect.maxY, accuracy: 0.001)
            }

            // ② now the ceiling itself: the frame exactly fills the canvas, all four edges coincide.
            let atLimit = CropCanvasClamp.fit(zoom: 9, center: start, canvas: canvas, frame: frame)
            let limitRect = CropCanvasClamp.frameRect(canvas: canvas, frame: frame,
                                                      zoom: atLimit.zoom,
                                                      center: (atLimit.centerX, atLimit.centerY))
            XCTAssertEqual(atLimit.zoom, limit, accuracy: 1e-12, "082 §3 \(edge): 天花板就是 maxZoom")
            XCTAssertEqual(limitRect.minX, canvasRect.minX, accuracy: 0.001)
            XCTAssertEqual(limitRect.maxX, canvasRect.maxX, accuracy: 0.001)
            XCTAssertEqual(limitRect.minY, canvasRect.minY, accuracy: 0.001)
            XCTAssertEqual(limitRect.maxY, canvasRect.maxY, accuracy: 0.001)
            print("082 §3 \(edge) · 上限 \(String(format: "%.3f", atLimit.zoom))× 时框 "
                  + "\(NSStringFromRect(limitRect)) —— 四边与画布重合，差 0 px")
        }

        // ④ anti-proof: the same request with the zoom clamp only (no auto-pan of the picture).
        let start = flush("right", zoom: 1)
        let zoomOnly = CropCanvasClamp.clampZoom(1.1, canvas: canvas, frame: frame)
        let unpanned = CropCanvasClamp.frameRect(canvas: canvas, frame: frame, zoom: zoomOnly, center: start)
        let over = unpanned.maxX - canvasRect.maxX
        print("082 §2 anti-proof · 只钳缩放不自动平移：框 \(NSStringFromRect(unpanned)) 超出画布右边界 "
              + "\(String(format: "%.1f", over)) px")
        XCTAssertFalse(CropCanvasClamp.contains(unpanned, in: canvasRect, tolerance: 0.5),
                       "082 §2 反证：没有自动平移时框必须出界")
        XCTAssertGreaterThan(over, 1)
    }

    // MARK: - 5 + 6. the real camera: zoom ceiling, pan gesture, freedom on exit

    /// A headless loupe with a canvas it can believe in: 900×600 points, backing scale 2 → a
    /// 1800×1200-device-pixel viewport. The fixture photo is 9520×6336.
    private func makeLoupe() throws -> (loupe: LoupeController, session: CatalogSession,
                                       window: NSWindow) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        // A real window with a real canvas: the projection is `bounds × backingScale`, and a canvas
        // that was never laid out has no size (every number below would be degenerate).
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = loupe.view
        window.orderFront(nil)
        loupe.canvasView.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        loupe.view.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        loupe.canvasView.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        return (loupe, session, window)
    }

    /// The crop frame's rect on screen, in **points**, from the shipped projection (`cropToolLayout`).
    private func frameOnScreen(_ loupe: LoupeController) throws -> CGRect {
        let layout = try XCTUnwrap(loupe.cropToolLayout(), "082: 没有裁切框")
        let xs = layout.corners.map(\.x), ys = layout.corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!,
                      width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    private func canvas(_ loupe: LoupeController) -> CGRect {
        CGRect(origin: .zero, size: loupe.canvasView.bounds.size)
    }

    /// The ceiling holds on the **real** camera: zoom in as far as the ladder allows, the frame lands
    /// flush inside the canvas, the pill prints the value it actually stopped at, and nothing moves on
    /// a second request.
    func testTheRealCameraStopsAtTheFrameInscribedLevel() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        _ = session
        // Half-frame draft, so the ceiling is a real number rather than "fit".
        loupe.cropTool.draft = CropToolController.Draft(
            crop: CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), straighten: 0, lock: .original)
        loupe.zoomToFit()

        let limit = try XCTUnwrap(loupe.cropZoomLimit(), "082: 没有上限？")
        print(String(format: "082 §1 · 真实相机 · canvas %.0f×%.1f pt · 框 %.0f×%.0f src px · maxZoom %.4f",
                     canvas(loupe).width, canvas(loupe).height,
                     loupe.cropFrameRect()!.width, loupe.cropFrameRect()!.height, limit))
        XCTAssertEqual(limit, min(1800.0 / loupe.cropFrameRect()!.width,
                                  1200.0 / loupe.cropFrameRect()!.height), accuracy: 1e-9)

        // Ask for 400 % — four ladder steps past the ceiling.
        loupe.zoom(to: 4, aroundView: CGPoint(x: 450, y: 300))
        let after = loupe.viewState
        let rect = try frameOnScreen(loupe)
        print("082 §1 · 请求 400% → 实际 \(after.zoomLabel) (zoom "
              + String(format: "%.4f", after.zoom) + ") · 框 \(NSStringFromRect(rect)) · 画布 "
              + "\(NSStringFromRect(canvas(loupe)))")
        XCTAssertEqual(after.zoom, limit, accuracy: 1e-9, "082: 请求超界 → 停在 maxZoom")
        XCTAssertEqual(loupe.zoomSlider.labelText, LoupeViewState.percentLabel(of: limit),
                       "082 §1: pill 显示钳位后的真实值")
        XCTAssertTrue(CropCanvasClamp.contains(rect, in: canvas(loupe), tolerance: 0.5),
                      "082: 框 ⊆ 画布（0.5 pt 是排版的半个像素）")

        // A second identical request changes nothing at all (no bounce, no drift).
        let zoomBefore = after.zoom, xBefore = after.centerX, yBefore = after.centerY
        loupe.zoom(to: 4, aroundView: CGPoint(x: 450, y: 300))
        XCTAssertEqual(loupe.viewState.zoom, zoomBefore, accuracy: 1e-12, "082 §1: 钳位后不再变化")
        XCTAssertEqual(loupe.viewState.centerX, xBefore, accuracy: 1e-9)
        XCTAssertEqual(loupe.viewState.centerY, yBefore, accuracy: 1e-9)

        // At the ceiling the frame is exactly inscribed: the tighter axis is flush on both sides.
        let canvasRect = canvas(loupe)
        let flushAxes = [abs(rect.minX - canvasRect.minX) < 0.5 || abs(rect.maxX - canvasRect.maxX) < 0.5,
                         abs(rect.minY - canvasRect.minY) < 0.5 || abs(rect.maxY - canvasRect.maxY) < 0.5]
        XCTAssertTrue(flushAxes.contains(true), "082: 上限那一级框必须贴到画布边")
    }

    /// The pan gesture goes through the same clamp: four directions to the end, the frame stays inside
    /// and stops moving; reversing 40 pt moves it 40 pt again (no sticky edge); natural scrolling on and
    /// off give the same answer.
    func testThePanStopsAtTheEdgeAndBacksOffImmediately() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        _ = session
        loupe.cropTool.draft = CropToolController.Draft(
            crop: CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), straighten: 0, lock: .original)
        // Half the ceiling: the frame is 600 pt wide in a 900 pt canvas, so there is room to move.
        let limit = try XCTUnwrap(loupe.cropZoomLimit())
        loupe.zoom(to: limit / 2, aroundView: CGPoint(x: 450, y: 300))
        XCTAssertTrue(loupe.viewState.isActualSize)
        let canvasRect = canvas(loupe)

        var reports: [String] = []
        for direction in ["right", "left", "up", "down"] {
            // Five 200 pt drags in one direction: the first few move, the last one cannot.
            var displaced: [Double] = []
            for _ in 0..<6 {
                let before = (loupe.viewState.centerX, loupe.viewState.centerY)
                let delta: CGSize
                switch direction {
                case "right": delta = CGSize(width: 200, height: 0)
                case "left": delta = CGSize(width: -200, height: 0)
                case "up": delta = CGSize(width: 0, height: 200)
                default: delta = CGSize(width: 0, height: -200)
                }
                loupe.panImage(byPoints: delta)
                displaced.append(hypot(loupe.viewState.centerX - before.0,
                                       loupe.viewState.centerY - before.1))
            }
            let rect = try frameOnScreen(loupe)
            XCTAssertTrue(CropCanvasClamp.contains(rect, in: canvasRect, tolerance: 0.5),
                          "082 §5 \(direction): 拖到尽头后框仍在画布里 \(rect)")
            reports.append("\(direction) 位移 "
                           + displaced.map { String(format: "%.2f", $0) }.joined(separator: "/")
                           + " · 框 \(NSStringFromRect(rect))")
            XCTAssertEqual(displaced.last ?? 1, 0, accuracy: 1e-9,
                           "082 §5 \(direction): 到尽头后不再移动（最后一次 \(displaced.last!)）")

            // Reverse 40 pt: the picture moves again immediately, by 40 pt worth of content.
            let beforeReverse = (loupe.viewState.centerX, loupe.viewState.centerY)
            let reverse: CGSize
            switch direction {
            case "right": reverse = CGSize(width: -40, height: 0)
            case "left": reverse = CGSize(width: 40, height: 0)
            case "up": reverse = CGSize(width: 0, height: -40)
            default: reverse = CGSize(width: 0, height: 40)
            }
            loupe.panImage(byPoints: reverse)
            let moved = hypot(loupe.viewState.centerX - beforeReverse.0,
                              loupe.viewState.centerY - beforeReverse.1)
            XCTAssertGreaterThan(moved, 1e-6, "082 §5 \(direction): 反向拖必须立刻恢复，不许粘住")
            reports.append("回头 40 pt → 位移 \(String(format: "%.2f", moved)) src px")
        }
        print("082 §5 · 平移钳位 " + reports.joined(separator: " ‖ "))

        // 自然滚动开 / 关：同一个手势（同一组 delta，同一方向）必须落在同一个位置。
        func wheelPosition(inverted: Bool) throws -> (Double, Double, CGRect) {
            loupe.zoomToFit()
            loupe.zoom(to: limit / 2, aroundView: CGPoint(x: 450, y: 300))
            // The same **finger** movement: with 自然滚动 on the event deltas already describe the
            // content (picture moves +delta); with it off they are the device's own direction, so the
            // same fingers report the opposite sign. Passing the same raw delta to both would be two
            // different gestures.
            let delta: CGFloat = inverted ? 120 : -120
            for _ in 0..<8 {
                loupe.scrollPan(deltaX: 0, deltaY: delta, precise: false, inverted: inverted)
            }
            return (loupe.viewState.centerX, loupe.viewState.centerY, try frameOnScreen(loupe))
        }
        let on = try wheelPosition(inverted: true)
        let off = try wheelPosition(inverted: false)
        print(String(format: "082 §5 · 自然滚动 开 → centre (%.3f, %.3f) · 关 → (%.3f, %.3f)",
                     on.0, on.1, off.0, off.1))
        XCTAssertEqual(on.0, off.0, accuracy: 1e-9, "082 §5: 自然滚动开关不该改变钳位结果")
        XCTAssertEqual(on.1, off.1, accuracy: 1e-9)
        XCTAssertEqual(on.2, off.2, "082 §5: 两条路径的框逐点相同")
        XCTAssertTrue(CropCanvasClamp.contains(on.2, in: canvasRect, tolerance: 0.5))
    }

    /// **The anti-proof**: with the clamp switched off, the same two requests go through — the zoom
    /// runs past the ceiling and the frame ends up outside the canvas. The numbers are the failure the
    /// user reported, measured.
    func testWithoutTheClampTheZoomPassesTheCeilingAndTheFrameLeavesTheCanvas() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        _ = session
        loupe.cropTool.draft = CropToolController.Draft(
            crop: CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), straighten: 0, lock: .original)
        let limit = try XCTUnwrap(loupe.cropZoomLimit())
        loupe.zoomToFit()

        let cropBefore = loupe.cropTool.draft.crop

        // ① With the clamp: 400 % stops at the ceiling, the frame stays inside, and the **crop the user
        //    drew is untouched** (that is the whole point — the camera gives way, not the frame).
        loupe.zoom(to: 4, aroundView: CGPoint(x: 450, y: 300))
        let clamped = try frameOnScreen(loupe)
        XCTAssertEqual(loupe.viewState.zoom, limit, accuracy: 1e-9)
        XCTAssertTrue(CropCanvasClamp.contains(clamped, in: canvas(loupe), tolerance: 0.5))
        XCTAssertEqual(loupe.cropTool.draft.crop.keyString, cropBefore.keyString,
                       "082: 缩放不许偷偷改裁切框")

        // ② Camera clamp off, ⑦ (the older 「框太大就缩小框」 clamp) still on: the zoom runs to 400 % and
        //    the frame is kept on the canvas by **shrinking the crop** — the silent re-crop the user
        //    reported as 「框自己变小了」. Numbers: the draft rect before → after.
        loupe.clampsCropCamera = false
        loupe.zoomToFit()
        loupe.zoom(to: 4, aroundView: CGPoint(x: 450, y: 300))
        let shrunk = loupe.cropTool.draft.crop
        print("082 anti-proof · 只关相机钳位（⑦ 还在）：请求 400% → 实际 \(loupe.viewState.zoomLabel) "
              + "· 草稿框 \(cropBefore.keyString) → \(shrunk.keyString)")
        XCTAssertEqual(loupe.viewState.zoom, 4, accuracy: 1e-9, "082 反证：没有上限，请求原样通过")
        XCTAssertNotEqual(shrunk.keyString, cropBefore.keyString,
                          "082 反证：没有相机钳位时是**裁切框**被迫缩小（不是相机让路）")

        // ③ Both clamps off: nothing keeps the frame on the canvas any more — the failure the invariant
        //    forbids, in pixels.
        loupe.cropTool.clampsFrameToView = false
        loupe.zoomToFit()
        loupe.cropTool.draft = CropToolController.Draft(crop: cropBefore, straighten: 0, lock: .original)
        loupe.zoom(to: 4, aroundView: CGPoint(x: 450, y: 300))
        let unclamped = try frameOnScreen(loupe)
        let canvasRect = canvas(loupe)
        let over = max(canvasRect.minX - unclamped.minX,
                       max(unclamped.maxX - canvasRect.maxX,
                           max(canvasRect.minY - unclamped.minY, unclamped.maxY - canvasRect.maxY)))
        print("082 anti-proof · 两个钳位都关：请求 400% → 实际 \(loupe.viewState.zoomLabel) · 框 "
              + "\(NSStringFromRect(unclamped)) vs 画布 \(NSStringFromRect(canvasRect)) · "
              + "每边最多出界 \(String(format: "%.1f", over)) px")
        XCTAssertFalse(CropCanvasClamp.contains(unclamped, in: canvasRect, tolerance: 0.5),
                       "082 反证：两个钳位都没有时，框必须跑出画布 —— 这正是被修掉的那一版")
        XCTAssertGreaterThan(over, 100, "082 反证：出界要量得出来（现在 \(over) px）")
        loupe.cropTool.clampsFrameToView = true
        loupe.clampsCropCamera = true
    }

    /// Outside 裁切 mode the same gestures are unlimited again — the clamp belongs to the tool.
    func testLeavingCropModeRestoresFreeZoomAndPan() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        _ = session
        loupe.cropTool.draft = CropToolController.Draft(
            crop: CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), straighten: 0, lock: .original)
        let limit = try XCTUnwrap(loupe.cropZoomLimit())

        loupe.zoom(to: 4, aroundView: CGPoint(x: 450, y: 300))
        let inside = loupe.viewState
        loupe.cancelCropTool()
        XCTAssertFalse(loupe.isCropToolActive)
        XCTAssertNil(loupe.cropZoomLimit(), "没有裁切模式就没有上限")

        // The same request, now unclamped: it reaches the ladder's own 400 %.
        loupe.zoom(to: 4, aroundView: CGPoint(x: 450, y: 300))
        let outside = loupe.viewState
        print(String(format: "082 §6 · 裁切内 请求 400%% → %.4f（上限 %.4f）", inside.zoom, limit)
              + " · 退出后 请求 400% → " + outside.zoomLabel
              + String(format: " (%.4f)", outside.zoom))
        XCTAssertEqual(inside.zoom, limit, accuracy: 1e-9)
        XCTAssertEqual(outside.zoom, 4.0, accuracy: 1e-9, "082 §6: 退出裁切后缩放恢复自由")
        XCTAssertGreaterThan(outside.zoom, inside.zoom * 4)

        // Pan too: outside the tool the window may walk over the picture (½ coverage rule), and nothing
        // clamps it to a crop frame any more.
        loupe.panImage(byPoints: CGSize(width: 200, height: 0))
        let panOutside = loupe.viewState.centerX
        loupe.panImage(byPoints: CGSize(width: 200, height: 0))
        let freedom = loupe.viewState.centerX - panOutside
        XCTAssertNotEqual(freedom, 0, "082 §6: 普通模式下平移照旧")
        print(String(format: "082 §6 · 普通模式 200 pt 平移 → centre 位移 %.3f src px", freedom))
    }
}
