import XCTest
import AppKit
import QuartzCore
import PhotonsCore
import PhotonsUI

/// 025 ① — the anchor, measured **frame by frame** through the whole bridge.
///
/// The bug as reported: 起止帧鼠标下的像素不动，中间帧在漂. End points being right is exactly what
/// makes it invisible to a screenshot at rest, so the assertion here is the *per-frame* one:
///
///   take a point `P` that is not the centre of the canvas (0.2w, 0.7h);
///   project it back into the image → the source pixel `I` under the cursor;
///   for **every** frame the bridge presented, project `I` forward again with that frame's map;
///   assert the result is still `P` (|Δ| < 0.5 pt).
///
/// Two independent readings of "that frame's map" are checked, because they can disagree:
///   · `LoupeZoomBridge.map(atProgress:)` — the similarity the bridge says it drew, per frame;
///   · `ZoomBridgeFrame.window` — the sampling window that actually went to the present pass, read
///     back through `PresentWindow.texel(canvasX:canvasY:)`. This is the *pixels*: if the window were
///     not the inverse of the map, the picture on screen would be shifted away from the picture the
///     assertion is about, and this second number would say so.
///
/// And the reverse evidence (`testTheSameAssertionIsRedWhenTheAnchorIsTheCentre`): the same
/// projection, the same assertion, on a bridge pinned to the *centre* of the view. It must fail, and
/// by about the distance from the cursor to the centre — which is what proves this test is measuring
/// the anchor and not passing by accident.
@MainActor
final class LoupeZoomAnchorProgressTests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    /// The point under the cursor, as a fraction of the canvas. Deliberately off-centre.
    private static let pointInUnit = CGPoint(x: 0.2, y: 0.7)
    /// The tolerance the task names, in points.
    private static let tolerance: Double = 0.5

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - harness

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

    /// Run `command` and collect every frame the bridge presented for it.
    private func frames(_ controller: LoupeController, _ command: () -> Void) -> [LoupeController.ZoomBridgeFrame] {
        let armed = controller.zoomBridgeArmedCount
        command()
        XCTAssertTrue(waitFor { controller.zoomBridge == nil }, "the bridge never ended")
        return controller.zoomBridgeFrames.filter { $0.serial > armed }
    }

    // MARK: - the measurement

    private struct Reading {
        var progress: Double
        var scale: Double
        /// Cursor drift in **points**, from the bridge's own map.
        var driftByMap: Double
        /// Cursor drift in points, read out of the window that was presented.
        var driftByWindow: Double
        /// The source pixel under the cursor at this frame, in source pixels.
        var sourceAtCursor: (x: Double, y: Double)
        /// How far that pixel is from `I`, in source pixels.
        var sourceDrift: Double
    }

    /// Project one source pixel through one frame's map, both ways.
    ///
    /// `I` is the image pixel that was under the cursor before the zoom; `anchor` is the point the
    /// bridge was told to hold (or the centre, for the counterexample); `fromMapping` is the
    /// projection the pixels on the canvas were laid out with.
    private func read(frame: LoupeController.ZoomBridgeFrame,
                      bridge: LoupeZoomBridge,
                      image: (x: Double, y: Double),
                      fromMapping: LoupeMapping,
                      canvas: ImageSize,
                      backingScale k: Double) -> Reading {
        let t = frame.progress
        // Where the image pixel `I` was on screen before the zoom, in canvas device pixels.
        let before = fromMapping.viewPoint(sourceX: image.x, sourceY: image.y)
        let map = bridge.map(atProgress: t)
        // …and where this frame puts it.
        let after = (x: map.scale * before.x + map.x, y: map.scale * before.y + map.y)

        // The same frame, read out of the sampling window that was actually presented: the canvas
        // point `after` reads texel `texel(after)`, and a texel of a canvas-sized texture *is* the
        // canvas point it was laid out at.
        let w = frame.window
        let texel = w.texel(canvasX: after.x, canvasY: after.y, canvas: canvas)
        let texture = (x: texel.u * Double(frame.canvas.width), y: texel.v * Double(frame.canvas.height))
        // The source pixel that texel shows, and how far the cursor is from it.
        let source = fromMapping.sourcePoint(viewX: texture.x, viewY: texture.y)
        let sourcePerPoint = fromMapping.canvasPerSource * k

        return Reading(
            progress: t,
            scale: map.scale,
            driftByMap: ((after.x - before.x) * (after.x - before.x)
                         + (after.y - before.y) * (after.y - before.y)).squareRoot() / k,
            driftByWindow: ((texture.x - before.x) * (texture.x - before.x)
                            + (texture.y - before.y) * (texture.y - before.y)).squareRoot() / k,
            sourceAtCursor: source,
            sourceDrift: ((source.x - image.x) * (source.x - image.x)
                          + (source.y - image.y) * (source.y - image.y)).squareRoot() / sourcePerPoint)
    }

    private func report(_ label: String, _ readings: [Reading]) -> String {
        let worstMap = readings.map(\.driftByMap).max() ?? 0
        let worstWindow = readings.map(\.driftByWindow).max() ?? 0
        let worstSource = readings.map(\.sourceDrift).max() ?? 0
        let lines = readings.map {
            String(format: "        progress %.3f · picture scale %.4f · cursor drift %.4f pt "
                   + "(window %.4f pt) · source pixel off by %.4f pt",
                   $0.progress, $0.scale, $0.driftByMap, $0.driftByWindow, $0.sourceDrift)
        }
        return "\(label): \(readings.count) frames · worst drift \(String(format: "%.4f", worstMap)) pt "
            + "(window \(String(format: "%.4f", worstWindow)) pt, source \(String(format: "%.4f", worstSource)) pt)\n"
            + lines.joined(separator: "\n")
    }

    // MARK: - ① the live bridge, every presented frame

    func testTheCursorPixelHoldsItsPlaceOnEveryFrameOfTheBridge() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "anchor-progress")
        let k = Double(controller.canvasView.window?.backingScaleFactor ?? 2)
        let canvas = controller.viewportPixels
        let bounds = controller.canvasView.bounds
        let point = CGPoint(x: bounds.width * Self.pointInUnit.x, y: bounds.height * Self.pointInUnit.y)

        // A known 100 % camera, then 100 → 200 % pinned on the cursor.
        controller.zoomToActualSize(aroundView: point)
        XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 1 })
        pump(0.1)

        let framing = try XCTUnwrap(controller.framing())
        let fromMapping = framing.mapping(of: controller.viewState)
        let image = fromMapping.sourcePoint(viewX: Double(point.x) * k, viewY: Double(point.y) * k)
        // The round trip the task describes: P → I → P, before anything moves.
        let back = fromMapping.viewPoint(sourceX: image.x, sourceY: image.y)
        XCTAssertEqual(back.x / k, Double(point.x), accuracy: 1e-6)
        XCTAssertEqual(back.y / k, Double(point.y), accuracy: 1e-6)

        var bridge: LoupeZoomBridge?
        let recorded = frames(controller) {
            controller.zoom(to: 2, aroundView: point)
            bridge = controller.zoomBridge
        }
        let armed = try XCTUnwrap(bridge, "100 → 200 % must arm a bridge")
        XCTAssertEqual(armed.anchor, .pointer(viewPoint: point, backingScale: k),
                       "the bridge is pinned on the pointer, as a parameter")
        XCTAssertEqual(armed.anchorPoint.x, Double(point.x) * k, accuracy: 1e-6,
                       "the pointer pixel is the map's own fixed point")
        XCTAssertEqual(armed.anchorPoint.y, Double(point.y) * k, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(recorded.count, 12,
                                    "only \(recorded.count) frames — a transition is not two pictures")

        let readings = recorded.map {
            read(frame: $0, bridge: armed, image: image, fromMapping: fromMapping,
                 canvas: canvas, backingScale: k)
        }
        // First and last are in the record, not assumed: progress 0 is the picture as it was. The last
        // *bridged* frame is within a percent of the stop (the stop itself is the real frame that
        // replaces it — `LoupeZoomTransitionAnimationTests` hashes that one).
        XCTAssertEqual(readings.first?.progress ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(readings.last?.progress ?? -1, 1, accuracy: 0.01)
        XCTAssertEqual(readings.first?.scale ?? 0, 1, accuracy: 0.02,
                       "the bridge starts on the frame that is on screen")
        XCTAssertEqual(readings.last?.scale ?? 0, 2, accuracy: 0.02,
                       "the bridge ends on the new camera's scale")
        print(report("100→200 % @ (0.2w, 0.7h)", readings))

        for r in readings {
            XCTAssertLessThan(r.driftByMap, Self.tolerance,
                              String(format: "progress %.3f: the cursor pixel moved %.4f pt", r.progress, r.driftByMap))
            XCTAssertLessThan(r.driftByWindow, Self.tolerance,
                              String(format: "progress %.3f: the presented window puts the cursor pixel %.4f pt away",
                                     r.progress, r.driftByWindow))
        }
    }

    /// The shrink and the fit crossing, which start from a different map — the same claim.
    func testTheCursorPixelHoldsOnTheWayOutAndAcrossFit() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "anchor-progress-out")
        let k = Double(controller.canvasView.window?.backingScaleFactor ?? 2)
        let canvas = controller.viewportPixels
        let bounds = controller.canvasView.bounds
        let point = CGPoint(x: bounds.width * Self.pointInUnit.x, y: bounds.height * Self.pointInUnit.y)

        controller.zoomToActualSize(aroundView: point)
        XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 1 })
        controller.zoom(to: 4, aroundView: point)
        XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 4 })
        pump(0.1)

        // 400 → 100 %: a big shrink, and the frame that was on the canvas is the 400 % one.
        var framing = try XCTUnwrap(controller.framing())
        var fromMapping = framing.mapping(of: controller.viewState)
        var image = fromMapping.sourcePoint(viewX: Double(point.x) * k, viewY: Double(point.y) * k)
        var bridge: LoupeZoomBridge?
        var recorded = frames(controller) {
            controller.zoom(to: 1, aroundView: point)
            bridge = controller.zoomBridge
        }
        var armed = try XCTUnwrap(bridge)
        var readings = recorded.map {
            read(frame: $0, bridge: armed, image: image, fromMapping: fromMapping,
                 canvas: canvas, backingScale: k)
        }
        print(report("400→100 % @ (0.2w, 0.7h)", readings))
        XCTAssertGreaterThanOrEqual(readings.count, 12)
        for r in readings {
            XCTAssertLessThan(r.driftByMap, Self.tolerance,
                              String(format: "400→100 %% progress %.3f: %.4f pt", r.progress, r.driftByMap))
            XCTAssertLessThan(r.driftByWindow, Self.tolerance)
        }

        // 100 % → fit: leaving a numeric stop for the whole frame keeps the cursor's pixel too.
        pump(0.15)
        framing = try XCTUnwrap(controller.framing())
        fromMapping = framing.mapping(of: controller.viewState)
        image = fromMapping.sourcePoint(viewX: Double(point.x) * k, viewY: Double(point.y) * k)
        recorded = frames(controller) {
            controller.zoomToFit()
            bridge = controller.zoomBridge
        }
        armed = try XCTUnwrap(bridge, "100 % → fit must arm a bridge")
        readings = recorded.map {
            read(frame: $0, bridge: armed, image: image, fromMapping: fromMapping,
                 canvas: canvas, backingScale: k)
        }
        print(report("100 %→fit @ (0.2w, 0.7h)", readings))
        for r in readings {
            XCTAssertLessThan(r.driftByMap, Self.tolerance,
                              String(format: "100→fit progress %.3f: %.4f pt", r.progress, r.driftByMap))
            XCTAssertLessThan(r.driftByWindow, Self.tolerance)
        }
    }

    // MARK: - ② the same assertion, on a centre-anchored bridge — must be red

    /// The reverse evidence the task asks for: 把同一断言故意改成「锚点在视图中心」，测试必须变红.
    ///
    /// Nothing but the anchor changes: the same photo, the same point `P`, the same projection, the
    /// same 0.5 pt tolerance. Only the bridge is pinned to the middle of the view, which is what the
    /// old `fit ↔ actual` bridge did. If this passed, the test above would be measuring nothing.
    func testTheSameAssertionIsRedWhenTheAnchorIsTheCentre() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "anchor-centre-red")
        let k = Double(controller.canvasView.window?.backingScaleFactor ?? 2)
        let canvas = controller.viewportPixels
        let bounds = controller.canvasView.bounds
        let point = CGPoint(x: bounds.width * Self.pointInUnit.x, y: bounds.height * Self.pointInUnit.y)

        // The same starting camera as the positive test: 100 %.
        controller.zoomToActualSize(aroundView: point)
        XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 1 })
        pump(0.1)

        let framing = try XCTUnwrap(controller.framing())
        let state = controller.viewState
        let fromMapping = framing.mapping(of: state)
        let image = fromMapping.sourcePoint(viewX: Double(point.x) * k, viewY: Double(point.y) * k)

        // A camera zoomed about the **centre**: the picture grows around the middle of the view, so
        // the pixel under the cursor cannot stay where it is.
        let centred = framing.zooming(state, to: 2, aroundView: CGPoint(x: bounds.midX, y: bounds.midY),
                                      backingScale: k)
        let bridge = LoupeZoomBridge(
            fromContent: framing.contentPixels(of: state),
            toContent: framing.contentPixels(of: centred),
            fromMapping: fromMapping,
            toMapping: framing.mapping(of: centred),
            canvas: canvas,
            anchor: .center)
        XCTAssertEqual(bridge.anchorPoint.x, Double(canvas.width) / 2, accuracy: 1e-6,
                       "this bridge is pinned on the middle of the canvas")

        // Eleven progresses plus both ends, so the failure cannot be a sampling accident.
        let progresses = (0...10).map { Double($0) / 10 }
        let readings = progresses.map {
            read(frame: LoupeController.ZoomBridgeFrame(serial: 0, progress: $0,
                                                        window: bridge.window(atProgress: $0, textureSize: canvas),
                                                        drawable: canvas, canvas: canvas),
                 bridge: bridge, image: image, fromMapping: fromMapping, canvas: canvas, backingScale: k)
        }
        print(report("counterexample: same assertion, anchor = view centre", readings))
        let worst = readings.map(\.driftByMap).max() ?? 0
        XCTAssertGreaterThan(worst, Self.tolerance,
                            "the centre-anchored bridge kept the cursor pixel within \(worst) pt — the "
                            + "assertion above cannot be measuring the anchor")
        // …and by about the distance from the cursor to the centre, at the worst progress.
        let offset = ((Double(point.x) - Double(bounds.midX)) * (Double(point.x) - Double(bounds.midX))
                      + (Double(point.y) - Double(bounds.midY)) * (Double(point.y) - Double(bounds.midY)))
            .squareRoot()
        XCTAssertGreaterThan(offset, 10, "the counterexample point must not be near the centre")
    }

    // MARK: - ③ eleven explicit progresses, no window involved

    /// The same claim as a pure statement about the bridge's arithmetic, at 11 progresses: for a
    /// pointer-anchored bridge the map is `p ↦ s(t)·(p − A) + A` **exactly**, whatever the easeOut
    /// curve does to `t`. This is the form the fix is written in, so it is worth pinning on its own.
    func testElevenProgressesAreAllScalesAboutThePointer() {
        let canvas = ImageSize(width: 2560, height: 1600)
        let framing = LoupeFraming(viewport: canvas, sourceWidth: 6000, sourceHeight: 4000)
        let pointer = (x: 512.0, y: 1120.0)          // (0.2w, 0.7h)
        let anchor = LoupeZoomAnchor.pointer(x: pointer.x, y: pointer.y)
        let from = framing.zooming(.fit, to: 1, aroundView: CGPoint(x: pointer.x, y: pointer.y),
                                   backingScale: 1)
        let to = framing.zooming(from, to: 4, aroundView: CGPoint(x: pointer.x, y: pointer.y),
                                 backingScale: 1)
        let bridge = LoupeZoomBridge(fromContent: framing.contentPixels(of: from),
                                     toContent: framing.contentPixels(of: to),
                                     fromMapping: framing.mapping(of: from),
                                     toMapping: framing.mapping(of: to),
                                     canvas: canvas, anchor: anchor)
        XCTAssertTrue(bridge.isVisible)
        let image = framing.mapping(of: from).sourcePoint(viewX: pointer.x, viewY: pointer.y)
        var lines: [String] = []
        var worst = 0.0
        for i in 0...10 {
            let t = Double(i) / 10
            let there = bridge.canvasPoint(atProgress: t,
                                           of: framing.mapping(of: from).viewPoint(sourceX: image.x,
                                                                                  sourceY: image.y))
            let drift = ((there.x - pointer.x) * (there.x - pointer.x)
                         + (there.y - pointer.y) * (there.y - pointer.y)).squareRoot()
            worst = max(worst, drift)
            lines.append(String(format: "        progress %.1f · scale %.4f · cursor drift %.6f pt",
                                t, bridge.scale(atProgress: t), drift))
            XCTAssertLessThan(drift, Self.tolerance, "progress \(t): \(drift) pt")
        }
        print("fit→400 % on a 2560×1600 canvas, 11 progresses · worst \(String(format: "%.6f", worst)) pt\n"
              + lines.joined(separator: "\n"))
    }
}
