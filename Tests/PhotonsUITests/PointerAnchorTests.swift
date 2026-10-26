import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// The pointer is **one** thing: where it is, and what is under it. These tests are about the first
/// half — the zoom anchor — and they are written against a real `NSWindow`, because the previous
/// generation of anchor tests injected the point straight into `LoupeFraming.zooming` and therefore
/// could not see the two places the shipped bug actually lived:
///
///   ① **the point** — `cursorAnchor()` used to be `window.mouseLocationOutsideOfEventStream` converted
///      per command, i.e. a number no test could set, so the whole "commands anchor on the pointer"
///      claim was untested through its real entry point (`zoomIn()` / `zoomOut()` / `toggleActualSize`);
///   ② **the composite** — `LoupeZoomBridge.transform` conjugated its translation by the *centre* of
///      the layer, but a view's backing layer has `anchorPoint == (0, 0)`, so the animation scaled
///      about the layer's bottom-left corner. That is the reported symptom exactly (「缩小是左下的位置
///      放大是右上位置」), it lasted the whole 180 ms of every stop change, and no test could see it
///      because every test of the bridge built its own bridge and asked it about its own assumption.
///
/// So this file drives the *commands*, on a real window, with the pointer set the way the tracking area
/// sets it — and then checks the two things a screenshot would show: the pixel under the pointer did not
/// move, and the animation's fixed point is that pixel rather than a corner or the centre.
@MainActor
final class PointerAnchorTests: XCTestCase {

    private var windows: [NSWindow] = []
    private let canvasPoints = CGSize(width: 320, height: 200)
    private var viewport: ImageSize { ImageSize(width: 640, height: 400) }

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    private func rawFixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitFor(_ timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    /// A controller with a real window and a real first frame. `reducesMotion` is left at the system
    /// value so the bridge is armed exactly as it ships — `armZoomBridge` reads the layer's geometry,
    /// which is the thing under test.
    private func makeController(url: URL, identity: String,
                                reducesMotion: Bool = false) -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        controller.reducesMotion = reducesMotion
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvasPoints),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = NSRect(origin: .zero, size: canvasPoints)
        windows.append(window)
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        controller.frameSource = LoupeController.FrameSource(url: url, identity: identity,
                                                            viewport: viewport, state: .fit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        pump(0.1)
        return controller
    }

    private func backingScale(_ controller: LoupeController) -> Double {
        Double(controller.canvasView.window?.backingScaleFactor ?? 2)
    }

    /// The source pixel under a canvas point (points, y down) in a given camera.
    private func sourcePixel(_ framing: LoupeFraming, _ state: LoupeViewState,
                             at point: CGPoint, scale k: Double) -> (x: Double, y: Double) {
        framing.mapping(of: state).sourcePoint(viewX: Double(point.x) * k, viewY: Double(point.y) * k)
    }

    // MARK: - ① the commands anchor on the pointer

    /// ⌘+ twice from `fit`, with the pointer at a known off-centre point: the pixel under it must not
    /// move, and the point must **not** be the canvas centre — a centre fallback would pass a Δ = 0 test
    /// for the wrong reason, so both claims are asserted together.
    func testZoomInAnchorsOnThePointerAndNotOnTheCentre() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "pointer-anchor-in")
        let k = backingScale(controller)
        let framing = try XCTUnwrap(controller.framing())
        let points: [(String, CGPoint)] = [
            ("upper-left ", CGPoint(x: 80, y: 50)),
            ("lower-right", CGPoint(x: 260, y: 168)),
            ("off-centre ", CGPoint(x: 96, y: 140)),
        ]
        var lines: [String] = []
        for (label, point) in points {
            controller.zoomToFit()
            XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.viewState.mode == .fit })
            pump(0.02)
            // The tracking area's answer, which is the only way the commands can learn the pointer.
            controller.pointerMoved(to: point)
            XCTAssertEqual(controller.cursorAnchor(), point, "跟踪点就是锚点，同一次调用")

            controller.zoomIn()                        // fit → 100 %
            XCTAssertEqual(controller.viewState.mode, .actual)
            XCTAssertEqual(controller.viewState.zoom, 1, accuracy: 1e-12)
            XCTAssertTrue(waitFor { controller.zoomBridge == nil })
            // The second ⌘+ is the one that tests the anchor: 100 → 200 % about a point that is
            // *not* the centre of the picture.
            let before = controller.viewState
            let p0 = sourcePixel(framing, before, at: point, scale: k)
            controller.zoomIn()                        // 100 → 200 %
            let after = controller.viewState
            XCTAssertEqual(after.zoom, 2, accuracy: 1e-12)
            let p1 = sourcePixel(framing, after, at: point, scale: k)
            let delta = ((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y)).squareRoot()

            // Not the centre: the same measurement at the canvas centre must name a different pixel,
            // so "Δ = 0" cannot be satisfied by a fallback.
            let centre = CGPoint(x: canvasPoints.width / 2, y: canvasPoints.height / 2)
            let c0 = sourcePixel(framing, before, at: centre, scale: k)
            XCTAssertGreaterThan(abs(p0.x - c0.x) + abs(p0.y - c0.y), 1,
                                 "\(label): the anchor pixel must be distinguishable from the centre's")
            XCTAssertNotEqual(point, centre)

            XCTAssertLessThanOrEqual(delta, 0.5,
                                     "\(label): the pixel under the pointer moved \(delta) src px")
            lines.append(String(format: "%@ @(%.0f,%.0f) src (%.1f, %.1f) → (%.1f, %.1f) · |Δ| = %.3f src px · centre pixel (%.1f, %.1f)",
                                label, point.x, point.y, p0.x, p0.y, p1.x, p1.y, delta, c0.x, c0.y))
        }
        print("anchor 100→200 % (real window, pointer injected through the tracking path):")
        print(lines.map { "        " + $0 }.joined(separator: "\n"))
    }

    /// ⌘− has the mirror-image failure mode, and it is the direction the user named as 「左下」.
    func testZoomOutAnchorsOnThePointer() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "pointer-anchor-out")
        let k = backingScale(controller)
        let framing = try XCTUnwrap(controller.framing())
        let point = CGPoint(x: 240, y: 60)             // upper right, far from the centre

        controller.pointerMoved(to: point)
        controller.zoomToActualSize(aroundView: point)   // 100 %, anchored (known state)
        XCTAssertEqual(controller.viewState.zoom, 1, accuracy: 1e-12)
        XCTAssertTrue(waitFor { controller.zoomBridge == nil })

        var lines: [String] = []
        for stop in [1.0 / 3.0, 0.25] {
            let before = controller.viewState
            let p0 = sourcePixel(framing, before, at: point, scale: k)
            controller.pointerMoved(to: point)
            controller.zoom(to: stop)                    // the menu path: `zoom(to:)` → `cursorAnchor()`
            let after = controller.viewState
            XCTAssertEqual(after.zoom, stop, accuracy: 1e-12)
            let p1 = sourcePixel(framing, after, at: point, scale: k)
            let delta = ((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y)).squareRoot()
            XCTAssertLessThanOrEqual(delta, 0.5, "zoom out to \(stop): moved \(delta) src px")
            lines.append(String(format: "%@ → %.1f%% · |Δ| = %.3f src px", "100%", stop * 100, delta))
            XCTAssertTrue(waitFor { controller.zoomBridge == nil })
        }
        print("anchor zoom-out (real window): " + lines.joined(separator: " · "))
    }

    /// The fallback, measured through a command: with **no** tracked pointer (the cursor is over the
    /// inspector, or the window is not the one being pointed at) `cursorAnchor()` has no answer — it
    /// must not invent one — and the command that reads it anchors on the canvas centre. That is the one
    /// case where the two answers differ, so it is asserted as a number rather than left to a comment.
    func testNoPointerOverTheCanvasAnchorsTheCommandOnTheCentre() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "pointer-anchor-none")
        controller.pointerExited()
        XCTAssertNil(controller.pointerCanvasPoint, "no tracked pointer after an exit")
        // The test window is not under the real cursor, so the live fallback finds nothing either —
        // which is exactly the "menu command while the pointer is elsewhere" state.
        let live = controller.cursorAnchor()
        print("cursorAnchor with no tracked or live pointer: \(String(describing: live))")

        let framing = try XCTUnwrap(controller.framing())
        let k = backingScale(controller)
        let centre = CGPoint(x: canvasPoints.width / 2, y: canvasPoints.height / 2)
        let corner = CGPoint(x: 40, y: 30)
        controller.pointerMoved(to: centre)
        controller.zoomToActualSize(aroundView: centre)     // a centred 100 % state
        XCTAssertTrue(waitFor { controller.zoomBridge == nil })
        controller.pointerExited()                          // …and nothing left to anchor on

        let before = controller.viewState
        let c0 = sourcePixel(framing, before, at: centre, scale: k)
        let e0 = sourcePixel(framing, before, at: corner, scale: k)
        controller.zoom(to: 2)
        let after = controller.viewState
        let c1 = sourcePixel(framing, after, at: centre, scale: k)
        let e1 = sourcePixel(framing, after, at: corner, scale: k)
        let centreDelta = ((c1.x - c0.x) * (c1.x - c0.x) + (c1.y - c0.y) * (c1.y - c0.y)).squareRoot()
        let cornerDelta = ((e1.x - e0.x) * (e1.x - e0.x) + (e1.y - e0.y) * (e1.y - e0.y)).squareRoot()
        print(String(format: "no pointer → centre anchored: |Δ centre| %.3f src px, |Δ corner| %.1f src px", centreDelta, cornerDelta))
        XCTAssertLessThanOrEqual(centreDelta, 0.5, "the fallback anchor is the canvas centre")
        XCTAssertGreaterThan(cornerDelta, 10, "…not the corner: an off-centre pixel does move")
    }

    /// The coordinate conversion itself: `convert(_:from: nil)` is "window base coordinates → this
    /// view, flipped", and a hand conversion that forgot the flip passes every Δ = 0 test above while
    /// reading the wrong half of the picture. So the two answers are compared, exactly.
    func testWindowToCanvasConversionIsFlippedNotRawTranslated() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "pointer-conversion")
        let view = controller.canvasView
        let window = try XCTUnwrap(view.window)
        // A window point near the top of the canvas: y up from the window's bottom-left.
        let windowPoint = CGPoint(x: 90, y: 155)
        let converted = view.convert(windowPoint, from: nil)
        // Hand conversion: subtract the view's frame origin, then flip y inside the view's bounds.
        let unflipped = CGPoint(x: windowPoint.x - view.frame.minX, y: windowPoint.y - view.frame.minY)
        let flipped = CGPoint(x: windowPoint.x - view.frame.minX,
                              y: view.frame.maxY - windowPoint.y)
        print("convert(window \(windowPoint)) = \(converted) · flipped \(flipped) · unflipped \(unflipped)")
        XCTAssertEqual(converted.x, flipped.x, accuracy: 1e-9)
        XCTAssertEqual(converted.y, flipped.y, accuracy: 1e-9)
        XCTAssertGreaterThan(abs(converted.y - unflipped.y), 1,
                             "the conversion must flip: unflipped would be \(unflipped.y), not \(converted.y)")
        // And the screen round trip agrees, which is what the live fallback uses.
        let screen = window.convertPoint(toScreen: windowPoint)
        let back = window.convertPoint(fromScreen: screen)
        XCTAssertEqual(back.x, windowPoint.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, windowPoint.y, accuracy: 1e-6)
    }

    // MARK: - ② the bridge's composite is anchored where the camera is

    /// The animation is a layer transform, so the picture the user watches for 180 ms has its own fixed
    /// point — and that fixed point, not the camera's, is what "zooms about the cursor" means on screen.
    ///
    /// The transform is read from the **real layer** (`anchorPoint`, `isGeometryFlipped`) rather than
    /// assumed, because that assumption was the bug: the old code conjugated by the layer's centre while
    /// the layer is anchored at `(0, 0)`, which makes every zoom scale away from the bottom-left corner.
    func testBridgeFixedPointIsThePointerPixelNotTheCorner() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "bridge-fixed-point")
        let k = backingScale(controller)
        let layer = controller.canvasView.metalLayer
        print("layer geometry: bounds \(layer.bounds) anchorPoint \(layer.anchorPoint) "
              + "geometryFlipped \(layer.isGeometryFlipped) contentsScale \(layer.contentsScale) "
              + "backing \(k)")

        let point = CGPoint(x: 80, y: 50)
        controller.pointerMoved(to: point)
        controller.zoomToActualSize(aroundView: point)
        XCTAssertTrue(waitFor { controller.zoomBridge == nil })
        pump(0.02)

        controller.zoom(to: 2)                       // 100 → 200 %, about the pointer
        let bridge = try XCTUnwrap(controller.zoomBridge, "a stop change with a picture arms a bridge")
        XCTAssertEqual(bridge.layerAnchorPoint, layer.anchorPoint, "bridge uses the layer's own anchor")
        XCTAssertEqual(bridge.layerIsFlipped, layer.isGeometryFlipped)

        let m = bridge.targetTransform(backingScale: k)
        let anchor = bridge.layerAnchor(backingScale: k)
        let s = Double(m.m11)
        // The composite's fixed point, in the layer's own points: v = a + t / (1 − s).
        let fixedX = Double(anchor.x) + Double(m.m41) / (1 - s)
        let fixedY = Double(anchor.y) + Double(m.m42) / (1 - s)
        // …and back in canvas device pixels, the space the camera and the tests speak.
        let canvasX = fixedX * k
        let canvasY = (bridge.layerIsFlipped ? fixedY : Double(bridge.canvas.height) / k - fixedY) * k
        let wanted = (x: Double(point.x) * k, y: Double(point.y) * k)
        let corner = (x: 0.0, y: 0.0)
        let centre = (x: Double(bridge.canvas.width) / 2, y: Double(bridge.canvas.height) / 2)
        let error = ((canvasX - wanted.x) * (canvasX - wanted.x)
                     + (canvasY - wanted.y) * (canvasY - wanted.y)).squareRoot()

        // What the pre-fix formula would have produced, against this same real layer: the old code
        // conjugated by the canvas **centre** while the layer is anchored at (0, 0). Printed as the
        // measured distance from the anchor, so the bug is a number and not a story.
        let w = Double(bridge.canvas.width) / k, h = Double(bridge.canvas.height) / k
        let oldM41 = bridge.offset.x / k - (1 - s) * w / 2
        let oldM42 = (1 - s) * h / 2 - bridge.offset.y / k
        let oldFixedX = (Double(anchor.x) + oldM41 / (1 - s)) * k
        let oldFixedY = (Double(anchor.y) + oldM42 / (1 - s)) * k
        let oldError = ((oldFixedX - wanted.x) * (oldFixedX - wanted.x)
                        + (oldFixedY - wanted.y) * (oldFixedY - wanted.y)).squareRoot()
        print(String(format: "pre-fix formula fixed point (%.1f, %.1f) · %.1f canvas px from the pointer (the corner-anchored drift the user saw as 「放大向右上」)", oldFixedX, oldFixedY, oldError))
        XCTAssertGreaterThan(oldError, 50, "the old formula is what this test would have caught")

        print(String(format: "bridge fixed point canvas (%.3f, %.3f) · anchor (%.1f, %.1f) · |err| %.4f px · corner (0,0) is %.0f px away · centre is %.0f px away",
                     canvasX, canvasY, wanted.x, wanted.y, error,
                     ((canvasX) * (canvasX) + (canvasY) * (canvasY)).squareRoot(),
                     ((canvasX - centre.x) * (canvasX - centre.x) + (canvasY - centre.y) * (canvasY - centre.y)).squareRoot()))
        XCTAssertLessThanOrEqual(error, 0.5, "the animation's fixed point must be the pointer pixel")
        XCTAssertGreaterThan(((canvasX - corner.x) * (canvasX - corner.x)
                              + (canvasY - corner.y) * (canvasY - corner.y)).squareRoot(), 50,
                             "…and not the layer's corner, which is what anchorPoint (0,0) without the " +
                             "anchor conjugation would give")
        XCTAssertGreaterThan(((canvasX - centre.x) * (canvasX - centre.x)
                              + (canvasY - centre.y) * (canvasY - centre.y)).squareRoot(), 50,
                             "…and not the canvas centre, which is what the old code assumed")

        // The anchored source pixel, carried by the composite, lands where the new camera puts it.
        let framing = try XCTUnwrap(controller.framing())
        let source = sourcePixel(framing, controller.viewState, at: point, scale: k)
        let oldCanvas = framing.mapping(of: controller.viewState)
            .viewPoint(sourceX: source.x, sourceY: source.y)
        let there = LoupeZoomBridge.apply(m,
                                          to: bridge.layerPoint(canvasX: oldCanvas.0,
                                                                canvasY: oldCanvas.1, backingScale: k),
                                          anchor: anchor)
        let expect = bridge.layerPoint(canvasX: wanted.x, canvasY: wanted.y, backingScale: k)
        XCTAssertEqual(there.x, expect.x, accuracy: 0.5)
        XCTAssertEqual(there.y, expect.y, accuracy: 0.5)
        controller.cancelZoomBridge()
    }
}
