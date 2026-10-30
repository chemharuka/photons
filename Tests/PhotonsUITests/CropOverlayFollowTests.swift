import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// ① / ② / ⑤ / ⑥ — the **one** framing-change path, and the chrome that hangs off it.
///
/// The bug as reported (①):
/// > 点击缩放条时，裁切指示框不跟着缩放 … 照片缩放了但 overlay 的裁切指示框尺寸/位置不跟着变
///
/// The cause was a missing edge, not a wrong number: `viewState` is the only thing the projection is
/// built from, and `setViewState` repainted the status chip and the zoom pill but never the crop
/// overlay. `refreshCropTool()` — the only writer of `cropOverlay.layout` — ran on draft changes, mode
/// changes and layout passes, so every *camera* change (pill, ⌘=/⌘−, ⌘0, double-click, wheel, pinch,
/// two-finger scroll) left the frame at the old projection.
///
/// What is measured here, on a real window with a real `LoupeController`:
///
///   1. at fit / 50 % / 1:1 the frame the **view is drawing** equals the frame the projection gives
///      (≤0.02 pt), and its four sides keep their position relative to the photo's sides (≤0.5 pt of
///      that rung's scale);
///   2. the anti-proof: with `syncsCropOverlayOnCameraChange = false` the same check goes red;
///   3. ⑤/⑥: a scroll and a pinch reach the camera while the tool is on, the frame follows, and
///      `editRevision` / `history.count` / `cropRect` do not move;
///   4. ②: in **both** modes (裁切 and ordinary) the zoom pill is in the top-right corner of the canvas
///      — clear of the crop bar, the top bar, the inspector and the filmstrip. 2026-10-27 用户要求普通
///      模式也放上方; the bottom-right rectangle it used to occupy is still measured, as the overlap
///      the move removes.
@MainActor
final class CropOverlayFollowTests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []

    /// 3000×2000 keeps fit below 1:1 on a 900×600 pt canvas (fit 0.6, 50 %, 1:1 are three different
    /// projections) and lets a 30 % crop stay on screen at 1:1 — so ① can be measured **with** ⑦'s
    /// clamp switched on, which is the shipped configuration.
    private static let source = (width: 3000, height: 2000)
    private static let canvas = NSSize(width: 900, height: 600)
    private static let crop = CropRect(left: 0.35, top: 0.35, right: 0.65, bottom: 0.65)

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-follow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

    private func makeLoupe(width: Int = CropOverlayFollowTests.source.width,
                           height: Int = CropOverlayFollowTests.source.height,
                           canvas: NSSize = CropOverlayFollowTests.canvas)
        throws -> (loupe: LoupeController, session: CatalogSession, window: NSWindow) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir, width: width, height: height)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 220, y: 220), size: canvas),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = loupe.view
        window.orderFront(nil)
        loupe.view.layoutSubtreeIfNeeded()
        windows.append(window)
        CropUITestSupport.pump(0.05)
        // The anchor is published by an observation bridge, so wait for it rather than assume it:
        // `beginCropTool` refuses without one, and a flaky "the tool did not open" would look like a
        // failure of the thing under test.
        let deadline = Date().addingTimeInterval(2)
        while session.mode != .loupe || session.anchorAsset == nil, Date() < deadline {
            CropUITestSupport.pump(0.01)
        }
        return (loupe, session, window)
    }

    /// The rect the frame occupies on the canvas, from the **view's** own layout (y-down points).
    private func frameRect(_ layout: CropToolLayout) -> NSRect {
        let xs = layout.corners.map(\.x), ys = layout.corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Where the photo is on the canvas, in the same space (y-down points), from the live projection.
    private func photoRect(_ loupe: LoupeController) throws -> NSRect {
        let framing = try XCTUnwrap(loupe.framing())
        let mapping = framing.mapping(of: loupe.viewState)
        let scale = loupe.backingScale
        let a = mapping.frameView(frameX: 0, frameY: 0)
        let b = mapping.frameView(frameX: framing.sourceWidth, frameY: framing.sourceHeight)
        return NSRect(x: min(a.x, b.x) / scale, y: min(a.y, b.y) / scale,
                      width: abs(b.x - a.x) / scale, height: abs(b.y - a.y) / scale)
    }

    /// The four sides as a fraction of the photo's own extent — the "相对位置" ① asks about, which is
    /// what has to stay put when the projection changes.
    private func relativeInsets(frame: NSRect, photo: NSRect) -> (l: Double, t: Double, r: Double, b: Double) {
        let w = max(photo.width, 1e-9), h = max(photo.height, 1e-9)
        return (Double((frame.minX - photo.minX) / w), Double((frame.minY - photo.minY) / h),
                Double((photo.maxX - frame.maxX) / w), Double((photo.maxY - frame.maxY) / h))
    }

    /// Does the view's frame equal the projection's, corner for corner?
    private func overlayMatchesProjection(_ loupe: LoupeController) -> (matches: Bool, worst: CGFloat) {
        guard let drawn = loupe.cropOverlayLayoutForTesting,
              let projected = loupe.cropToolLayout(),
              drawn.corners.count == 4, projected.corners.count == 4 else { return (false, .infinity) }
        var worst: CGFloat = 0
        for (a, b) in zip(drawn.corners, projected.corners) {
            worst = max(worst, hypot(a.x - b.x, a.y - b.y))
        }
        return (worst <= 0.02, worst)
    }

    private func zoomStates(_ loupe: LoupeController) -> [(String, CGPoint)] {
        [("fit", .zero), ("50%", CGPoint(x: 450, y: 300)), ("1:1", CGPoint(x: 450, y: 300))]
    }

    private func apply(zoom named: String, to loupe: LoupeController) {
        switch named {
        case "50%": loupe.zoom(to: 0.5, aroundView: CGPoint(x: 450, y: 300))
        case "1:1": loupe.zoom(to: 1, aroundView: CGPoint(x: 450, y: 300))
        default: loupe.zoomToFit()
        }
        CropUITestSupport.pump(0.01)
    }

    // MARK: - ①

    /// fit / 50 % / 1:1 — the frame the view draws is the projection's frame, and its four sides keep
    /// their place on the photo.
    func testTheCropFrameFollowsEveryZoomStop() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        CropUITestSupport.openCropTool(loupe, session)
        loupe.cropTool.draft = CropToolController.Draft(crop: Self.crop)
        loupe.refreshCropTool()

        var rows: [(name: String, frame: NSRect, photo: NSRect, rel: (l: Double, t: Double, r: Double, b: Double), worst: CGFloat)] = []
        for (name, _) in zoomStates(loupe) {
            apply(zoom: name, to: loupe)
            let match = overlayMatchesProjection(loupe)
            let layout = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
            let frame = frameRect(layout)
            let photo = try photoRect(loupe)
            rows.append((name, frame, photo, relativeInsets(frame: frame, photo: photo), match.worst))
            print(String(format: "① %@ · frame %@ · photo %@ · overlay↔projection %.4f pt",
                         name, NSStringFromRect(frame), NSStringFromRect(photo), match.worst))
        }

        // (a) the view is drawing **this** projection at every rung.
        for row in rows {
            XCTAssertTrue(row.worst <= 0.02,
                          "①: at \\(row.name) the overlay is \\(row.worst) pt away from the projection")
            // (b) the frame is on the canvas (⑦) — not a coincidence: the crop is legal at all three.
            XCTAssertGreaterThanOrEqual(row.frame.minX, -0.5, "①/\u{2460}: \\(row.name) frame left of canvas")
            XCTAssertGreaterThanOrEqual(row.frame.minY, -0.5, "①/\u{2460}: \\(row.name) frame above canvas")
            XCTAssertLessThanOrEqual(row.frame.maxX, Self.canvas.width + 0.5, "① · \\(row.name) right")
            XCTAssertLessThanOrEqual(row.frame.maxY, Self.canvas.height + 0.5, "① · \\(row.name) bottom")
        }
        // (c) 框每边与照片边界的相对位置不变，误差 ≤0.5 pt at that rung's own scale.
        let first = try XCTUnwrap(rows.first)
        XCTAssertGreaterThan(Set(rows.map { $0.frame.width.rounded() }).count, 1,
                             "①: the three rungs must be three different sizes, or nothing was measured")
        for row in rows {
            let w = Double(row.photo.width), h = Double(row.photo.height)
            XCTAssertLessThanOrEqual(abs(row.rel.l - first.rel.l) * w, 0.5, "① \\(row.name): left inset moved")
            XCTAssertLessThanOrEqual(abs(row.rel.t - first.rel.t) * h, 0.5, "① \\(row.name): top inset moved")
            XCTAssertLessThanOrEqual(abs(row.rel.r - first.rel.r) * w, 0.5, "① \\(row.name): right inset moved")
            XCTAssertLessThanOrEqual(abs(row.rel.b - first.rel.b) * h, 0.5, "① \\(row.name): bottom inset moved")
            // …and the number is the draft's own 0.35 / 0.35 / 0.65 / 0.65 (the "valueBox 比例").
            XCTAssertEqual(row.rel.l, 0.35, accuracy: 1e-6, "① \\(row.name): left is not the draft's")
            XCTAssertEqual(row.rel.t, 0.35, accuracy: 1e-6, "① \\(row.name): top is not the draft's")
            XCTAssertEqual(row.rel.r, 0.35, accuracy: 1e-6, "① \\(row.name): right is not the draft's")
            XCTAssertEqual(row.rel.b, 0.35, accuracy: 1e-6, "① \\(row.name): bottom is not the draft's")
            // The frame's own share of the photo: 0.30 of each axis, at every rung.
            XCTAssertEqual(Double(row.frame.width / row.photo.width), 0.30, accuracy: 1e-6)
            XCTAssertEqual(Double(row.frame.height / row.photo.height), 0.30, accuracy: 1e-6)
        }
        print("① · 相对位置 l/t/r/b = \(first.rel) at all three rungs (draft 0.35/0.35/0.65/0.65)")
    }

    /// The anti-proof: the very same check is red when the camera change no longer reaches the overlay.
    func testWithoutTheCameraToOverlayEdgeTheFrameIsStale() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        CropUITestSupport.openCropTool(loupe, session)
        loupe.cropTool.draft = CropToolController.Draft(crop: Self.crop)
        loupe.refreshCropTool()

        apply(zoom: "fit", to: loupe)
        let fitFrame = frameRect(try XCTUnwrap(loupe.cropOverlayLayoutForTesting))
        XCTAssertTrue(overlayMatchesProjection(loupe).matches)

        loupe.syncsCropOverlayOnCameraChange = false
        apply(zoom: "1:1", to: loupe)
        let staleFrame = frameRect(try XCTUnwrap(loupe.cropOverlayLayoutForTesting))
        let match = overlayMatchesProjection(loupe)
        print(String(format: "① anti-proof · fit frame %@ · after 1:1 the view still draws %@ "
                     + "(projection wants %@) · %.1f pt off, matches=%@",
                     NSStringFromRect(fitFrame), NSStringFromRect(staleFrame),
                     NSStringFromRect(frameRect(try XCTUnwrap(loupe.cropToolLayout()))),
                     match.worst, match.matches ? "yes" : "NO"))
        XCTAssertFalse(match.matches, "① anti-proof: with the edge cut the overlay must be stale")
        XCTAssertGreaterThan(match.worst, 1, "① anti-proof: and visibly so")

        loupe.syncsCropOverlayOnCameraChange = true
        apply(zoom: "50%", to: loupe)
        XCTAssertTrue(overlayMatchesProjection(loupe).matches, "①: putting the edge back fixes it")
    }

    // MARK: - ⑤ / ⑥ (the gestures)

    /// A scroll event built from a `CGEvent` — the only public way to make a scroll-wheel / trackpad
    /// scroll event in a test. `units: .pixel` is the trackpad's own form (`hasPreciseScrollingDeltas`).
    private func scrollEvent(deltaX: Int32, deltaY: Int32) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: deltaY, wheel2: deltaX, wheel3: 0) else { return nil }
        return NSEvent(cgEvent: cg)
    }

    /// ⑥ — a two-finger scroll pans in 裁切 mode exactly as it does in the loupe, the frame follows,
    /// and the document, the history and the draft's rect do not move.
    func testTwoFingerScrollStillPansInCropMode() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        CropUITestSupport.openCropTool(loupe, session)
        loupe.cropTool.draft = CropToolController.Draft(crop: Self.crop)
        loupe.refreshCropTool()
        // A pan is a 1:1 gesture (the same rule the loupe has always had): the window has to be
        // smaller than the picture for it to have anywhere to go.
        apply(zoom: "1:1", to: loupe)

        let revisionBefore = session.editRevision
        let historyBefore = session.history.snapshots.count
        let cropBefore = session.edit.geometry.cropRect

        // Four directions, 100 pt each, from the same camera: the picture has to move with the hand
        // (same sign, same distance) and the frame is a rect of the picture, so it travels with it.
        //
        // `scrollPan` normalises on `NSEvent.isDirectionInvertedFromDevice`, because that flag is what
        // says whose direction the deltas are: with 「自然滚动」 on they already describe the **content**,
        // with it off they describe the **device**, which is the other way round. A CGEvent carries the
        // non-inverted form, so the expectation is `−delta` here — the distance is unchanged, and this
        // loop is about the frame following the picture, not about which way round it is.
        // `PanFollowTests.testScrollIsTheSameGestureWhicheverWayTheSystemIsSet` pins the direction
        // itself, both ways round.
        let home = loupe.viewState
        var previous = try photoRect(loupe)
        var previousFrame = frameRect(try XCTUnwrap(loupe.cropOverlayLayoutForTesting))
        for (name, dx, dy) in [("left", Int32(-100), Int32(0)),
                               ("right", Int32(100), Int32(0)),
                               ("up", Int32(0), Int32(-100)),
                               ("down", Int32(0), Int32(100))] {
            // Back to the same camera before each direction, so "100 pt" is measured from a known place.
            loupe.zoom(to: 1, aroundView: CGPoint(x: 450, y: 300))
            loupe.panImage(byPoints: CGSize(width: -home.centerX + 1500, height: -home.centerY + 1000))
            CropUITestSupport.pump(0.01)
            previous = try photoRect(loupe)
            previousFrame = frameRect(try XCTUnwrap(loupe.cropOverlayLayoutForTesting))

            guard let event = scrollEvent(deltaX: dx, deltaY: dy) else {
                throw XCTSkip("this OS will not hand back a scroll NSEvent from a CGEvent")
            }
            let sign: Double = event.isDirectionInvertedFromDevice ? 1 : -1
            let expected = (Double(dx) * sign, Double(dy) * sign)
            loupe.canvasView.scrollWheel(with: event)
            CropUITestSupport.pump(0.01)
            let after = try photoRect(loupe)
            let frameAfter = frameRect(try XCTUnwrap(loupe.cropOverlayLayoutForTesting))
            let delta = (after.minX - previous.minX, after.minY - previous.minY)
            print(String(format: "⑥ scroll %@ · photo origin Δ (%.2f, %.2f) pt · frame origin Δ "
                         + "(%.2f, %.2f) pt · overlay↔projection %.4f pt",
                         name, delta.0, delta.1,
                         frameAfter.minX - previousFrame.minX, frameAfter.minY - previousFrame.minY,
                         overlayMatchesProjection(loupe).worst))
            XCTAssertEqual(delta.0, expected.0, accuracy: 1, "⑥ \(name): the picture did not follow the hand")
            XCTAssertEqual(delta.1, expected.1, accuracy: 1, "⑥ \(name): the picture did not follow the hand")
            XCTAssertEqual(frameAfter.minX - previousFrame.minX, delta.0, accuracy: 0.5,
                           "⑥ \(name): the frame moves with the picture it is a rect of")
            XCTAssertEqual(frameAfter.minY - previousFrame.minY, delta.1, accuracy: 0.5)
            XCTAssertTrue(overlayMatchesProjection(loupe).matches, "⑥ \(name): same refresh path as ①")
        }

        // Pure view state.
        XCTAssertEqual(session.editRevision, revisionBefore, "⑥: a pan writes no document")
        XCTAssertEqual(session.history.snapshots.count, historyBefore, "⑥: and no snapshot")
        XCTAssertEqual(session.edit.geometry.cropRect, cropBefore, "⑥: and the committed crop is untouched")
        XCTAssertEqual(loupe.cropTool.draft.crop, Self.crop, "⑥: the draft's rect is untouched too")
    }

    /// ⑤/⑥ — the pinch zooms in 裁切 mode, and the frame follows it in the same turn.
    ///
    /// (`NSEvent` has no public initialiser for a magnify gesture, so the gesture is delivered to the
    /// method `LoupeCanvasView.magnify(with:)` calls — the view's own line is a one-line forward with
    /// no gate left in it, which is the change ⑤/⑥ made.)
    func testPinchZoomsInCropModeAndTheFrameFollows() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        CropUITestSupport.openCropTool(loupe, session)
        loupe.cropTool.draft = CropToolController.Draft(crop: Self.crop)
        loupe.refreshCropTool()
        apply(zoom: "50%", to: loupe)

        let revisionBefore = session.editRevision
        let historyBefore = session.history.snapshots.count
        let cropBefore = session.edit.geometry.cropRect
        let zoomBefore = loupe.effectiveZoom
        let frameBefore = frameRect(try XCTUnwrap(loupe.cropOverlayLayoutForTesting))

        loupe.magnify(by: 2, at: CGPoint(x: 450, y: 300))
        CropUITestSupport.pump(0.01)

        let zoomAfter = loupe.effectiveZoom
        let frameAfter = frameRect(try XCTUnwrap(loupe.cropOverlayLayoutForTesting))
        print(String(format: "⑥ pinch · zoom %.3f → %.3f · frame %@ → %@ · overlay↔projection %.4f pt",
                     zoomBefore, zoomAfter, NSStringFromRect(frameBefore),
                     NSStringFromRect(frameAfter), overlayMatchesProjection(loupe).worst))
        XCTAssertGreaterThan(zoomAfter, zoomBefore, "⑥: the pinch zoomed in")
        XCTAssertNotEqual(frameAfter, frameBefore, "⑥: the frame followed the zoom")
        XCTAssertTrue(overlayMatchesProjection(loupe).matches, "⑥: through the same refresh path")
        XCTAssertEqual(session.editRevision, revisionBefore, "⑥: a pinch writes no document")
        XCTAssertEqual(session.history.snapshots.count, historyBefore, "⑥: no snapshot")
        XCTAssertEqual(session.edit.geometry.cropRect, cropBefore, "⑥: committed crop untouched")

        // …and the pill agrees with the camera afterwards (the continuity check: no jump on the next
        // slider press).
        XCTAssertEqual(loupe.zoomSlider.zoomStop.map { LoupeViewState.clampZoom($0) },
                       loupe.currentZoomStop, "⑥: the pill and the camera still agree after the pinch")
    }

    // MARK: - ② (the pill's corner)

    private func makeEditor(size: NSSize = NSSize(width: 1600, height: 940))
        throws -> (editor: EditorWindowController, root: WorkspaceRootView, window: NSWindow) {
        let library = try CropUITestSupport.makeLibrary(in: workDir)
        let editor = EditorWindowController(size: size)
        try editor.openLibrary(at: library.package)
        editor.session.selectOnly(library.assetID)
        editor.session.mode = .loupe
        editor.rootView.loupeController.autoRenderEnabled = false
        editor.rootView.loupeController.collectsHistogram = false
        let window = try XCTUnwrap(editor.window)
        window.setContentSize(size)
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        editor.rootView.needsLayout = true
        editor.rootView.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        editor.rootView.layoutSubtreeIfNeeded()
        windows.append(window)
        return (editor, editor.rootView, window)
    }

    /// One line of evidence per size: where the pill is, where the bar is, and the intersections that
    /// must all be empty. `expectsBar` is `false` in ordinary mode, where the bar is hidden and has no
    /// rectangle of its own to clear.
    private func reportPlacement(_ root: WorkspaceRootView, _ window: NSWindow, size: String,
                                 expectsBar: Bool = true) throws {
        let loupe = root.loupeController
        // The bar is placed from the canvas' bounds by `refreshCropTool` — the app's own layout path.
        // Driving it here means a measurement never depends on whether AppKit chose to send
        // `viewDidLayout` to a controller that lives in a window the test resized by hand.
        loupe.refreshCropTool()
        let slider = loupe.zoomSlider.convert(loupe.zoomSlider.bounds, to: root)
        let bar = loupe.cropBar.convert(loupe.cropBar.bounds, to: root)
        let canvas = loupe.view.convert(loupe.view.bounds, to: root)
        let geometry = root.geometry
        let topBar = geometry.topBar
        let inspector = geometry.inspector
        let filmstrip = geometry.filmstrip ?? .zero

        print("② \(size) · slider \(NSStringFromRect(slider)) · bar \(NSStringFromRect(bar)) · "
              + "canvas \(NSStringFromRect(canvas)) · topBar \(NSStringFromRect(topBar)) · "
              + "inspector \(NSStringFromRect(inspector)) · filmstrip \(NSStringFromRect(filmstrip))")
        print("② \(size) · ∩bar \(NSStringFromRect(slider.intersection(bar))) · "
              + "∩topBar \(NSStringFromRect(slider.intersection(topBar))) · "
              + "∩inspector \(NSStringFromRect(slider.intersection(inspector))) · "
              + "∩filmstrip \(NSStringFromRect(slider.intersection(filmstrip))) · "
              + "right gap \(canvas.maxX - slider.maxX) pt · top gap \(slider.minY - canvas.minY) pt")

        if expectsBar {
            XCTAssertTrue(slider.intersection(bar).isEmpty,
                          "② \(size): the pill must not overlap the crop bar")
        }
        XCTAssertTrue(slider.intersection(topBar).isEmpty, "② \(size): …nor the top bar")
        XCTAssertTrue(slider.intersection(inspector).isEmpty, "② \(size): …nor the inspector")
        XCTAssertTrue(slider.intersection(filmstrip).isEmpty, "② \(size): …nor the filmstrip")
        XCTAssertGreaterThanOrEqual(canvas.maxX - slider.maxX, 8, "② \(size): right margin")
        XCTAssertGreaterThanOrEqual(slider.minY - canvas.minY, 8, "② \(size): the pill is inside the top")
        XCTAssertLessThanOrEqual(slider.maxY, canvas.maxY + 0.5, "② \(size): and not clipped by the top")
        XCTAssertLessThanOrEqual(slider.maxX, canvas.maxX + 0.5, "② \(size): nor by the right")
        XCTAssertGreaterThanOrEqual(slider.minX, canvas.minX - 0.5, "② \(size): nor by the left")
        // The bar's own placement is `CropBarLayoutTests`' contract; here it must only be **clear of
        // the pill** (they are in two different corners at every width).
        // Root-view coordinates are flipped (y grows downwards), so "the bar is below the pill" is
        // `bar.minY >= slider.maxY`.
        if expectsBar {
            XCTAssertGreaterThanOrEqual(bar.minY, slider.maxY,
                                        "② \(size): the bar must be entirely below the pill")
        }
    }

    /// ② — 裁切 mode moves the pill to the top-right corner; the bar keeps its own rectangle.
    func testTheZoomPillSitsInTheTopRightCornerInCropMode() throws {
        let (editor, root, window) = try makeEditor()
        defer { window.orderOut(nil) }
        let loupe = root.loupeController

        // Normal mode first: the rectangle this control has always had.
        let restingFrame = loupe.zoomSlider.frame
        // 182 — the pill's place is a *canvas-relative* corner, so the resting state is recorded as
        // the two gaps it keeps from the canvas' top-right corner (16 pt each, `Metrics.edgeInset`)
        // rather than as an absolute x: the harness' window width, and therefore the canvas' width,
        // is not the same at the start and at the end of this test (see the comment at the end).
        let restingRightGap = loupe.view.bounds.maxX - restingFrame.maxX
        let restingTopGap = loupe.view.bounds.maxY - restingFrame.maxY
        print("② normal · slider \(NSStringFromRect(restingFrame)) (loupe coords) · canvas "
              + "\(NSStringFromRect(loupe.view.bounds)) · gaps \(restingRightGap)/\(restingTopGap) pt")

        CropUITestSupport.openCropTool(loupe, editor.session)
        CropUITestSupport.pump(0.02)
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(loupe.zoomSlider.placement, .topRight, "②: 裁切 mode parks the pill top-right")
        let barWidthBefore = loupe.cropBar.barWidth
        try reportPlacement(root, window, size: "1600×940")

        // Before/after for the report: put the pill back where it used to live (the bottom-right
        // corner) and measure the same two rectangles. This is the overlap the move removes.
        //
        // 082: the bar lost its controls and is much narrower (three readouts, 320 pt), so at 1600 pt
        // the old corner no longer meets it. The overlap the ② note is about is measured where it still
        // happens — the narrowest window this harness can lay out — so the assertion keeps failing if
        // the bar ever grows back into that corner.
        window.setContentSize(NSSize(width: 1000, height: 700))
        root.layoutSubtreeIfNeeded()
        loupe.zoomSlider.placement = .bottomRight
        loupe.zoomSlider.layout(in: loupe.view.bounds)
        let oldPill = loupe.zoomSlider.convert(loupe.zoomSlider.bounds, to: root)
        let barNow = loupe.cropBar.convert(loupe.cropBar.bounds, to: root)
        print("② before (pill forced to the old bottom-right corner) · slider "
              + "\(NSStringFromRect(oldPill)) · bar \(NSStringFromRect(barNow)) · ∩ "
              + "\(NSStringFromRect(oldPill.intersection(barNow)))")
        XCTAssertFalse(oldPill.intersection(barNow).isEmpty,
                       "②: the old corner really did overlap the bar — that is the bug being fixed")
        loupe.refreshCropTool()      // back to 裁切 mode's top-right corner

        // The bar did not move a point to make room (the ② rule the user replaced: 别动下面操作栏).
        XCTAssertEqual(loupe.cropBar.barWidth, barWidthBefore, accuracy: 0.001,
                       "②: the bar's width is not a function of the pill's corner")

        // Minimum window: still clear, still on the canvas.
        window.setContentSize(WorkspaceLayout.minimumWindowSize)
        window.contentView?.layoutSubtreeIfNeeded()
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        root.layoutSubtreeIfNeeded()
        loupe.view.layoutSubtreeIfNeeded()
        try reportPlacement(root, window, size: "1200×780 (minimum)")

        // Leaving the tool changes nothing about where the pill is: one corner in every mode
        // (2026-10-27 用户要求普通模式也放上方), so entering and leaving 裁切 does not move it.
        //
        // 182 — "does not move it" has to be read in the canvas' own coordinates. This harness' window
        // is not the same width at the two ends of the test: `setFrameAutosaveName` restores the frame
        // when the window is first ordered front, and AppKit clamps it to the **screen** — the xctest
        // process gets a 1609 pt-wide screen, the saved frame is `55 52 1600 940`, and 55 + 1600 = 1655
        // exceeds it by 46, so the window is ordered front 1554 pt wide. The `setContentSize(1600, 940)`
        // below *is* honoured, so the canvas starts the test 976 pt wide (1554 − 212 − 1 − 364 − 1) and
        // ends it 1022 pt wide: the old value-for-value comparison of an absolute x reported that
        // 46 pt canvas delta (1022 − 976 = 46 = 1655 − 1609) as a pill that had moved. It had not —
        // it is 16 pt in from the canvas' right edge in both: 976 − 16 − 210 = 750 and
        // 1022 − 16 − 210 = 796 (both measured, `right gap 16.0 pt` in every line above).
        loupe.cancelCropTool()
        CropUITestSupport.pump(0.02)
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(loupe.zoomSlider.placement, .topRight,
                       "②: ordinary mode keeps the same top-right corner (2026-10-27)")
        window.setContentSize(NSSize(width: 1600, height: 940))
        window.contentView?.layoutSubtreeIfNeeded()
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        print("② after the round trip · slider \(NSStringFromRect(loupe.zoomSlider.frame)) (loupe "
              + "coords) · canvas \(NSStringFromRect(loupe.view.bounds)) · gaps "
              + "\(loupe.view.bounds.maxX - loupe.zoomSlider.frame.maxX)/"
              + "\(loupe.view.bounds.maxY - loupe.zoomSlider.frame.maxY) pt "
              + "(resting \(restingFrame) in \(restingRightGap)/\(restingTopGap) pt gaps)")
        XCTAssertEqual(loupe.zoomSlider.frame.size, restingFrame.size,
                       "②: the pill never moved — same size, value for value")
        XCTAssertEqual(loupe.view.bounds.maxX - loupe.zoomSlider.frame.maxX, restingRightGap,
                       accuracy: 0.5,
                       "②: nor did its 16 pt gap to the canvas' right edge (裁切 and out of it)")
        XCTAssertEqual(loupe.view.bounds.maxY - loupe.zoomSlider.frame.maxY, restingTopGap,
                       accuracy: 0.5,
                       "②: nor its 16 pt gap to the canvas' top")
    }

    /// ② — **ordinary mode**, at both window sizes the task names: the pill is in the canvas'
    /// top-right corner (16 pt in from the canvas' top and right edges, i.e. the same margins as in
    /// 裁切 mode) and intersects none of the chrome. 2026-10-27 用户要求普通模式也放上方.
    func testTheZoomPillSitsInTheTopRightCornerInNormalModeToo() throws {
        let (_, root, window) = try makeEditor(size: NSSize(width: 1600, height: 940))
        defer { window.orderOut(nil) }
        let loupe = root.loupeController

        XCTAssertFalse(loupe.cropTool.isActive, "this is ordinary mode — no crop tool")
        XCTAssertEqual(loupe.zoomSlider.placement, .topRight, "②: 普通模式 parks the pill top-right")
        XCTAssertFalse(loupe.cropBar.isHidden == false, "the crop bar is not up")
        try reportPlacement(root, window, size: "1600×940 普通模式", expectsBar: false)
        // The rectangle is the canvas' corner, not the window's: 16 pt in from both edges.
        let canvas = loupe.view.convert(loupe.view.bounds, to: root)
        let slider = loupe.zoomSlider.convert(loupe.zoomSlider.bounds, to: root)
        XCTAssertEqual(canvas.maxX - slider.maxX, 16, accuracy: 0.5,
                       "②: the right margin is the control's own 16 pt")
        XCTAssertEqual(slider.minY - canvas.minY, 16, accuracy: 0.5,
                       "②: and so is the top margin")

        window.setContentSize(WorkspaceLayout.minimumWindowSize)
        window.contentView?.layoutSubtreeIfNeeded()
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        root.layoutSubtreeIfNeeded()
        loupe.view.layoutSubtreeIfNeeded()
        try reportPlacement(root, window, size: "1200×780 最小 普通模式", expectsBar: false)
        let smallCanvas = loupe.view.convert(loupe.view.bounds, to: root)
        let smallSlider = loupe.zoomSlider.convert(loupe.zoomSlider.bounds, to: root)
        XCTAssertEqual(smallCanvas.maxX - smallSlider.maxX, 16, accuracy: 0.5)
        XCTAssertEqual(smallSlider.minY - smallCanvas.minY, 16, accuracy: 0.5)
    }
}
