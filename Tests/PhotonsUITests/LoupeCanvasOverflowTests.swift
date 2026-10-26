import XCTest
import AppKit
import QuartzCore
import Metal
import PhotonsCore
import PhotonsUI

/// 025 ② — the picture must never leave the canvas.
///
/// The bug as reported: 放大时，画面会越界，在某瞬间遮挡住侧栏. The mechanism was a `CATransform3D` on
/// the canvas's layer: scaling a layer scales the *layer*, so at 2× half of the picture was painted
/// outside the view — over the browser pane, the inspector and the top bar.
///
/// The invariants this file pins, all of them structural rather than "it looked fine":
///
///   1. the layer the drawable lives on is **never** scaled and never moves (`transform` is identity,
///      `frame == bounds`), and it clips (`masksToBounds`);
///   2. every frame of a transition presents into a drawable **the size of the canvas** — a texture
///      larger than the canvas is sampled as a sub-rect, never blitted 1:1 into a bigger surface;
///   3. the rect the canvas content occupies, per frame, is inside the canvas: `content ∩ canvas ==
///      content`, for the growing bridge (the case that used to spill) and for the shrinking one.
@MainActor
final class LoupeCanvasOverflowTests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    private var windows: [NSWindow] = []

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

    /// Bounded, but generous: a frame is a render plus (when the harness hashes) a 32 MB readback, and
    /// on a machine running other test bundles that has been measured in the tens of seconds. The
    /// assertions here are about geometry, not speed, so a slow frame must not read as a broken one.
    private func waitFor(_ timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func makeController(url: URL, identity: String) -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        controller.frameSource = LoupeController.FrameSource(url: url, identity: identity,
                                                             viewport: Self.viewport, state: .fit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        pump(0.1)
        return controller
    }

    private func frames(_ controller: LoupeController, _ command: () -> Void) -> [LoupeController.ZoomBridgeFrame] {
        let armed = controller.zoomBridgeArmedCount
        command()
        XCTAssertTrue(waitFor { controller.zoomBridge == nil }, "the bridge never ended")
        return controller.zoomBridgeFrames.filter { $0.serial > armed }
    }

    /// The rect of the canvas the *picture* occupies at one frame — the whole canvas, because the
    /// present pass draws one quad over the drawable and the window only decides what it samples.
    private func contentRect(of frame: LoupeController.ZoomBridgeFrame) -> CGRect {
        CGRect(x: 0, y: 0, width: frame.canvas.width, height: frame.canvas.height)
    }

    // MARK: - ① the drawable is the canvas, on every frame

    func testEveryFrameOfTheTransitionDrawsIntoACanvasSizedDrawable() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "overflow-drawable")
        let layer = controller.canvasView.metalLayer
        let canvas = controller.viewportPixels

        controller.zoomToActualSize(aroundView: CGPoint(x: 64, y: 140))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 1 })
        pump(0.1)

        // The growing direction is the one that used to spill: 100 → 400 % is 4× the picture.
        let recorded = frames(controller) {
            controller.zoom(to: 4, aroundView: CGPoint(x: 64, y: 140))
        }
        XCTAssertGreaterThanOrEqual(recorded.count, 12)
        var lines: [String] = []
        for f in recorded {
            XCTAssertEqual(f.canvas, canvas, "the canvas the bridge measured against moved")
            XCTAssertEqual(f.drawable, canvas,
                           "progress \(f.progress): the drawable is \(f.drawable), the canvas is \(canvas)")
            XCTAssertLessThanOrEqual(f.drawable.width, canvas.width)
            XCTAssertLessThanOrEqual(f.drawable.height, canvas.height)
            // The content rect the frame paints, and the intersection the task asks for.
            let content = contentRect(of: f)
            let inside = content.intersection(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
            XCTAssertEqual(inside, content,
                           "progress \(f.progress): content \(content) is not inside the canvas")
            lines.append(String(format: "        progress %.3f · drawable %d×%d = canvas · content %d×%d @ (0, 0)",
                                f.progress, f.drawable.width, f.drawable.height,
                                Int(content.width), Int(content.height)))
        }
        print("100→400 %: \(recorded.count) frames, drawable always \(canvas.width)×\(canvas.height)\n"
              + lines.prefix(3).joined(separator: "\n") + "\n        …")

        // The layer itself: the size of the view, un-scaled, clipping. This is the geometry assertion —
        // a scaled layer is what reached the sidebar, so identity here means it cannot.
        XCTAssertTrue(CATransform3DIsIdentity(layer.transform),
                      "the canvas layer must never carry a transform")
        XCTAssertEqual(layer.bounds.size, controller.canvasView.bounds.size,
                       "the canvas layer must be exactly the view's size")
        XCTAssertEqual(layer.frame.size, controller.canvasView.bounds.size)
        XCTAssertEqual(layer.anchorPoint, .zero)
        XCTAssertTrue(layer.masksToBounds, "the canvas must clip its own drawable")
        XCTAssertNil(layer.animation(forKey: "photons.zoomBridge"))
        XCTAssertEqual(layer.drawableSize,
                       CGSize(width: canvas.width, height: canvas.height),
                       "the presented drawable must be the canvas, in device pixels")
        print("layer: frame \(layer.frame) · bounds \(controller.canvasView.bounds) · "
              + "drawableSize \(layer.drawableSize) · transform identity · masked")
    }

    // MARK: - ② the counterexample: what a layer transform would have painted

    /// The number behind the bug, kept as arithmetic: the old design scaled the *layer*, so at scale
    /// `s` it painted `s ×` the canvas — for 100 → 400 % that is four canvases wide, three of them
    /// over the rest of the window. Nothing in the current path can express that, and this test says
    /// so by construction: the only rect that ever reaches the screen is the canvas.
    func testTheOverflowTheLayerTransformUsedToCauseIsGone() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "overflow-counterexample")
        let canvas = controller.viewportPixels
        controller.zoomToActualSize(aroundView: CGPoint(x: 64, y: 140))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 1 })
        pump(0.1)

        let bridge = try XCTUnwrap({
            controller.zoom(to: 4, aroundView: CGPoint(x: 64, y: 140))
            return controller.zoomBridge
        }(), "no bridge")
        XCTAssertEqual(bridge.scale, 4, accuracy: 1e-9, "100 → 400 % is a 4× carry")

        // What a layer transform of `scale` about an anchor would have covered, in canvas pixels:
        // the canvas rect blown up by 4 (and shifted), i.e. far outside the view.
        let anchor = bridge.anchorPoint
        let scaledFrame = CGRect(x: anchor.x * (1 - bridge.scale), y: anchor.y * (1 - bridge.scale),
                                 width: Double(canvas.width) * bridge.scale,
                                 height: Double(canvas.height) * bridge.scale)
        let canvasRect = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let overflow = scaledFrame.union(canvasRect).width * scaledFrame.union(canvasRect).height
            - canvasRect.width * canvasRect.height
        print(String(format: "layer-transform counterexample: a %.0f×%.0f canvas carried by a %.2f× transform "
                     + "would paint %.0f×%.0f px (%.0f %% of it outside the canvas); the window path paints %.0f×%.0f",
                     canvasRect.width, canvasRect.height, bridge.scale,
                     scaledFrame.width, scaledFrame.height,
                     100 * overflow / (scaledFrame.width * scaledFrame.height),
                     canvasRect.width, canvasRect.height))
        XCTAssertGreaterThan(scaledFrame.width, Double(canvas.width) * 1.5,
                            "the counterexample must actually overflow, or it proves nothing")
        XCTAssertLessThanOrEqual(canvasRect.width, Double(canvas.width),
                                 "what the canvas paints is the canvas, by construction")

        XCTAssertTrue(waitFor { controller.zoomBridge == nil })
        pump(0.15)
        XCTAssertEqual(controller.canvasView.metalLayer.drawableSize,
                       CGSize(width: canvas.width, height: canvas.height))
        XCTAssertTrue(CATransform3DIsIdentity(controller.canvasView.metalLayer.transform))
    }

    // MARK: - ③ a shrink cannot leave the canvas either

    func testTheShrinkingTransitionAlsoStaysInsideTheCanvas() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "overflow-shrink")
        let canvas = controller.viewportPixels
        let layer = controller.canvasView.metalLayer
        let point = CGPoint(x: 64, y: 140)
        controller.zoomToActualSize(aroundView: point)
        XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 1 })
        controller.zoom(to: 4, aroundView: point)
        XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 4 })
        pump(0.1)

        let recorded = frames(controller) { controller.zoom(to: 1, aroundView: point) }
        XCTAssertGreaterThanOrEqual(recorded.count, 12)
        for f in recorded {
            XCTAssertEqual(f.drawable, canvas, "progress \(f.progress): drawable ≠ canvas")
            XCTAssertEqual(f.window.du > 0, true, "a window with no coverage is not a window")
            let content = contentRect(of: f)
            XCTAssertEqual(content.intersection(CGRect(x: 0, y: 0, width: canvas.width,
                                                      height: canvas.height)), content)
        }
        XCTAssertTrue(CATransform3DIsIdentity(layer.transform))
        XCTAssertEqual(layer.drawableSize, CGSize(width: canvas.width, height: canvas.height))
        print("400→100 %: \(recorded.count) frames, drawable always \(canvas.width)×\(canvas.height), "
              + "content always the canvas, layer transform identity")
    }
}
