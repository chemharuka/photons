import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 072 §E — 防误触：权限隔离.
///
/// The user's report was 「同时拖侧栏与裁切框时，侧栏被调节」: while the crop frame was being dragged, a
/// drag that landed on the right-hand panel still reached the panel, so one gesture was split between
/// two controls and the document changed under a crop that had not been applied. The fix has to be at
/// the **event layer** (a greyed slider still swallows the press), and it has to leave exactly one
/// thing alive: the 缩放控制条 (§E4).
///
/// Five claims, each measured on the real workspace (`EditorWindowController` → `WorkspaceRootView` →
/// `InspectorHostingView` + `LoupeCanvasView`), never on a stub:
///
///   1. 侧栏 in 裁切 mode: `inspectorHost.hitTest` is `nil` for every point inside it, so **no** AppKit
///      control inside it can be pressed or dragged — and a 200 pt drag dispatched there writes nothing
///      (document hash and history both unchanged, 0 document writes);
///   2. 裁切框最高优先: the same drag sequence with the hand on the frame *and* on the panel moves the
///      frame only (a two-sided delta table);
///   3. 缩放条 stays live (visible, hit-testable, and `zoomFromSlider` really moves the camera);
///   4. 退出裁切 the panel is live again on the very next event;
///   5. the outermost grip's **hit rect** and the panel's rect do not intersect (rectangles printed).
@MainActor
final class CropPermissionsTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-permissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - 1 + 2. the panel is inert, the frame is live

    func testADragOnTheInspectorWritesNothingWhileTheFrameKeepsItsDrag() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let window = try XCTUnwrap(editor.window)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let root = editor.rootView!
        let session = editor.session
        let loupe = root.loupeController
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false

        // The panel's own rect, in window coordinates, and a point a slider would be under. Recomputed
        // on every ask: a layout pass between two assertions must not leave a stale point behind.
        let inspector = root.inspectorHost
        XCTAssertEqual(inspector.frame.width, root.currentInspectorWidth, accuracy: 0.5)
        func panelPoint() -> NSPoint {
            let r = inspector.convert(inspector.bounds, to: nil)
            return NSPoint(x: r.midX, y: r.midY)
        }
        /// Does a press at `panelPoint()` land on any view **inside** the panel?
        func reachesPanel() -> Bool {
            guard let hit = root.hitTest(root.convert(panelPoint(), from: nil)) else { return false }
            return hit === inspector || hit.isDescendant(of: inspector)
        }
        func hostHit() -> NSView? { inspector.hitTest(inspector.convert(panelPoint(), from: nil)) }

        // Before: the panel takes the press (the control — without this the "after" would prove nothing).
        print("E1 before · reaches panel = \(reachesPanel()), host hit = \(String(describing: hostHit()))")
        XCTAssertTrue(reachesPanel(), "with no tool armed, a press in the panel belongs to the panel")

        // Enter 裁切 through the menu's own path (a real anchor photo, a real camera).
        XCTAssertTrue(loupe.beginCropTool())
        XCTAssertTrue(loupe.isCropToolActive)
        CropUITestSupport.pump(0.02)

        print("E1 after · reaches panel = \(reachesPanel()), host hit = \(String(describing: hostHit())), "
              + "gated = \(inspector.isEditingGated)")
        XCTAssertTrue(inspector.isEditingGated, "§E1: the gate is on with the tool")
        XCTAssertNil(hostHit(), "§E1: the panel's hit test answers nil — event layer, not a greyed row")
        XCTAssertFalse(reachesPanel(), "§E1: a press there cannot reach any panel view")

        // A real 200 pt drag dispatched at the panel while a crop drag is live.
        let hashBefore = CropUITestSupport.documentHash(session)
        let historyBefore = session.history.snapshots.count
        let cropBefore = loupe.cropTool.draft.crop

        // First hand: down on the frame's bottom-right corner.
        let layout = try XCTUnwrap(loupe.cropToolLayout())
        let corner = try XCTUnwrap(layout.grips.first { $0.kind == .bottomRight }).point
        let cornerInWindow = root.loupeController.canvasView.convert(corner, to: nil)
        let canvas = loupe.canvasView
        canvas.mouseDown(with: CropUITestSupport.mouse(.leftMouseDown, at: cornerInWindow, in: window))
        XCTAssertTrue(loupe.cropTool.isDragging, "the frame took the press")

        // Second hand: a 200 pt drag on the panel. Every one of these events is dispatched through the
        // window, i.e. through `hitTest`, which is exactly where the gate lives.
        window.sendEvent(CropUITestSupport.mouse(.leftMouseDown, at: panelPoint(), in: window))
        for step in 1...10 {
            let p = NSPoint(x: panelPoint().x, y: panelPoint().y - CGFloat(step) * 20)
            window.sendEvent(CropUITestSupport.mouse(.leftMouseDragged, at: p, in: window))
        }
        window.sendEvent(CropUITestSupport.mouse(.leftMouseUp, at: panelPoint(), in: window))

        // The panel drag alone must not have moved the frame.
        let cropAfterPanel = loupe.cropTool.draft.crop
        let panelDelta = (width: cropAfterPanel.width - cropBefore.width,
                          height: cropAfterPanel.height - cropBefore.height)

        // …and the first hand keeps dragging the frame.
        let target = NSPoint(x: corner.x - 120, y: corner.y - 80)
        canvas.mouseDragged(with: CropUITestSupport.mouse(.leftMouseDragged,
                                                          at: canvas.convert(target, to: nil), in: window))
        canvas.mouseUp(with: CropUITestSupport.mouse(.leftMouseUp, at: canvas.convert(target, to: nil),
                                                      in: window))

        let cropAfter = loupe.cropTool.draft.crop
        let cropDelta = (width: cropAfter.width - cropAfterPanel.width,
                         height: cropAfter.height - cropAfterPanel.height)
        let docChanged = CropUITestSupport.documentHash(session) != hashBefore
        let historyDelta = session.history.snapshots.count - historyBefore

        // The two-sided table §E wants.
        print("""
        E table · 侧栏 200 pt drag → document changed: \(docChanged), history Δ\(historyDelta), \
        crop width Δ\(String(format: "%+.6f", panelDelta.width)), height Δ\(String(format: "%+.6f", panelDelta.height)) \
        · 裁切框 120×80 pt drag → crop width Δ\(String(format: "%+.6f", cropDelta.width)), \
        height Δ\(String(format: "%+.6f", cropDelta.height)) · handle \(String(describing: loupe.cropTool.lastHandle))
        """)
        XCTAssertFalse(docChanged, "§E1: a drag on the panel writes nothing")
        XCTAssertEqual(historyDelta, 0, "§E1: and no history entry")
        XCTAssertLessThan(abs(panelDelta.width), 1e-9, "the panel drag must not resize the frame")
        XCTAssertLessThan(abs(panelDelta.height), 1e-9, "the panel drag must not resize the frame")
        XCTAssertLessThan(cropDelta.width, -1e-4, "the frame's own drag did move it")

        loupe.cancelCropTool()
        CropUITestSupport.pump(0.02)
        print("E1 restore · gated = \(inspector.isEditingGated), active = \(loupe.isCropToolActive), "
              + "reaches panel = \(reachesPanel()), host hit = \(String(describing: hostHit()))")
        XCTAssertFalse(inspector.isEditingGated, "§E1: 退出裁切 opens the gate again")
        XCTAssertTrue(reachesPanel(), "§E1: exiting 裁切 hands the panel back on the next event")
    }

    /// The corner drag alone moves the frame (the control for the test above: it must be capable of
    /// changing the draft, or "0 change" would prove nothing).
    func testTheFrameDragItselfMovesTheDraft() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let window = try XCTUnwrap(editor.window)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let root = editor.rootView!
        let loupe = root.loupeController
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        XCTAssertTrue(loupe.beginCropTool())

        let layout = try XCTUnwrap(loupe.cropToolLayout())
        let corner = try XCTUnwrap(layout.grips.first { $0.kind == .bottomRight }).point
        let canvas = loupe.canvasView
        let before = loupe.cropTool.draft.crop
        print("E control diag · owner \(loupe.gestureOwner(atViewPoint: corner)) corner \(corner) "
              + "source \(loupe.cropSourceSize) viewport \(loupe.viewportPixels)")
        canvas.mouseDown(with: CropUITestSupport.mouse(.leftMouseDown,
                                                        at: canvas.convert(corner, to: nil), in: window))
        print("E control diag · handle \(String(describing: loupe.cropTool.lastHandle)) dragging \(loupe.cropTool.isDragging)")
        let target = NSPoint(x: corner.x - 120, y: corner.y - 80)
        canvas.mouseDragged(with: CropUITestSupport.mouse(.leftMouseDragged,
                                                          at: canvas.convert(target, to: nil), in: window))
        canvas.mouseUp(with: CropUITestSupport.mouse(.leftMouseUp,
                                                      at: canvas.convert(target, to: nil), in: window))
        let after = loupe.cropTool.draft.crop
        print(String(format: "E control · frame drag: width %.5f → %.5f, height %.5f → %.5f",
                     before.width, after.width, before.height, after.height))
        XCTAssertLessThan(after.width, before.width - 1e-4, "the frame really shrank under the hand")
        XCTAssertLessThan(after.height, before.height - 1e-4)
        loupe.cancelCropTool()
    }

    // MARK: - 3. §E4 the zoom pill stays live

    func testTheZoomPillStaysUsableInCropMode() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let window = try XCTUnwrap(editor.window)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let root = editor.rootView!
        let loupe = root.loupeController
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        loupe.zoomToFit()
        XCTAssertFalse(loupe.zoomSlider.isHidden)

        XCTAssertTrue(loupe.beginCropTool())
        CropUITestSupport.pump(0.02)
        XCTAssertFalse(loupe.zoomSlider.isHidden, "§E4: the zoom control bar is not hidden by 裁切 mode")
        // `hitTest` speaks its superview's coordinates; the pill's own centre is inside both pills.
        let pill = loupe.zoomSlider
        XCTAssertNotNil(pill.hitTest(NSPoint(x: pill.frame.midX, y: pill.frame.midY)),
                        "and it is still a hit target inside its own pill")

        // 082 (追加) — the pill still moves the camera, but a crop session's ceiling is
        // 「裁切框恰好内接于画布」: a full-frame crop in this window stops at the fit level, so the
        // numbers below are the *clamped* ones. That is a spec change, not a regression: §E4 said the
        // pill must stay usable, and it is (mode moves to `.actual`, the readout is the real value).
        let ceiling = try XCTUnwrap(loupe.cropZoomLimit(), "082: 裁切模式没有上限？")
        let before = loupe.viewState
        loupe.zoomFromSlider(to: 1)
        let after = loupe.viewState
        print("E4 · zoom pill in 裁切 mode: \(before.zoomLabel) → \(after.zoomLabel) "
              + "(mode \(after.mode.rawValue), zoom \(after.zoom)) · 上限 \(ceiling)")
        XCTAssertEqual(after.mode, .actual, "the pill really moved the camera")
        XCTAssertEqual(after.zoom, min(1, ceiling), accuracy: 1e-12,
                       "082: 100% 的请求被钳在「框内接于画布」那一级")

        // A 25 % stop through the same door, so it is not a one-off.
        loupe.zoomFromSlider(to: 0.25)
        XCTAssertEqual(loupe.viewState.zoom, min(0.25, ceiling), accuracy: 1e-12)
        // …and the readout is the value the camera actually holds.
        XCTAssertEqual(loupe.zoomSlider.labelText,
                       LoupeViewState.percentLabel(of: loupe.viewState.zoom))
        loupe.cancelCropTool()
    }

    // MARK: - 5. no handle can reach the panel

    func testNoGripHitRectTouchesTheInspectorRect() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let window = try XCTUnwrap(editor.window)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let root = editor.rootView!
        let loupe = root.loupeController
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        XCTAssertTrue(loupe.beginCropTool())
        CropUITestSupport.pump(0.02)

        let layout = try XCTUnwrap(loupe.cropToolLayout())
        // The grips are in canvas points (y down). Converted one at a time into window coordinates by
        // the canvas itself, so a flipped view and a non-flipped window cannot disagree.
        let canvas = loupe.canvasView
        let inspectorRect = root.inspectorHost.convert(root.inspectorHost.bounds, to: nil)
        print("E5 diag · canvas frame \(canvas.frame) bounds \(canvas.bounds) viewport \(loupe.viewportPixels) "
              + "corners \(layout.corners)")

        var unionInWindow = NSRect.null
        for grip in layout.grips {
            let radius = grip.kind.isCorner ? CropTool.cornerHitRadiusPoints : CropTool.edgeHitRadiusPoints
            let centre = canvas.convert(grip.point, to: nil)
            let raw = NSRect(x: centre.x - radius, y: centre.y - radius,
                             width: radius * 2, height: radius * 2)
            // A press outside the canvas can never reach the canvas' own hit test, so the *effective*
            // rect is the raw one clipped to the canvas (AppKit clips at the view's bounds).
            let inWindow = raw.intersection(canvas.convert(canvas.bounds, to: nil))
            unionInWindow = unionInWindow.union(inWindow)
            print("E5 grip \(grip.kind) raw \(raw) clipped \(inWindow)")
        }
        print("E5 · grips union \(unionInWindow) vs inspector \(inspectorRect) · "
              + "intersection \(NSIntersectionRect(unionInWindow, inspectorRect))")
        XCTAssertFalse(unionInWindow.isEmpty)
        XCTAssertTrue(NSIntersectionRect(unionInWindow, inspectorRect).isEmpty,
                      "§E5: the grip hit rects and the panel must not overlap")
        XCTAssertLessThanOrEqual(unionInWindow.maxX, inspectorRect.minX,
                                 "every grip is left of the panel")

        // §E2: inside the frame the canvas still owns the press, panel or no panel.
        for u in [0.25, 0.5, 0.75] {
            for v in [0.25, 0.5, 0.75] {
                let point = CGPoint(x: layout.corners[0].x + (layout.corners[1].x - layout.corners[0].x) * u,
                                    y: layout.corners[0].y + (layout.corners[3].y - layout.corners[0].y) * v)
                XCTAssertEqual(loupe.gestureOwner(atViewPoint: point), .cropTool)
            }
        }
        loupe.cancelCropTool()
    }
}
