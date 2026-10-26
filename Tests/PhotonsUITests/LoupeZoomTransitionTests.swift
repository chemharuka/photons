import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// The stop-change bridge: the loupe's only transition, and the numbers that keep it honest.
///
/// It exists because of a gap, not a preference: the camera jumps to the new stop the moment the user
/// asks for it (`fit ↔ 25…400 %`, and stop ↔ stop), but the pixels for that stop are not on the canvas
/// yet — 5 ms from a resident rung, 52–900 ms if a development is in the way. The bridge carries the
/// picture that is already on screen from the projection that produced it to the new camera's
/// projection in 180 ms easeOut, and the real frame replaces it when it lands (held until then).
///
/// Every wait in this file has an explicit deadline and asserts on it: a bridge that never ends must
/// fail in seconds, not hold an `xctest` window open. Nothing here waits for the **full** rung of a
/// 66 MB raw either — the bridge is about the frame that *is* resident, and which rung that is does not
/// change what the bridge claims.
@MainActor
final class LoupeZoomTransitionTests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    /// Long enough for a preview-rung render (tens of ms), far below the 52–900 ms a development can
    /// take, so a stuck path fails fast instead of hanging the window.
    private static let deadline: TimeInterval = 5
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

    /// Poll with a hard deadline. Returns whether the condition became true — every caller asserts it.
    private func waitFor(_ timeout: TimeInterval = deadline, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    /// A real window: `CanvasPresenter.present` needs a drawable, and a frame that never reaches the
    /// layer cannot be the end of a bridge. Ordered front *before* any frame is requested.
    private func makeController() -> LoupeController {
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
        return controller
    }

    private func start(_ controller: LoupeController, url: URL, identity: String) {
        controller.hashesFrames = true
        controller.frameSource = LoupeController.FrameSource(url: url, identity: identity,
                                                             viewport: Self.viewport, state: .fit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
    }

    /// The first picture on screen, at whatever rung the ladder could produce it.
    private func waitForFirstFrame(_ controller: LoupeController) {
        XCTAssertTrue(waitFor { controller.lastFrame != nil },
                      "no first frame (last error: \(controller.lastPresentError ?? "—"))")
        pump(0.1)   // and let the follow-up frame for the same camera land too
    }

    private func waitForFrame(_ controller: LoupeController, zoom: Double) {
        XCTAssertTrue(waitFor { abs((controller.lastFrame?.zoom ?? -1) - zoom) < 1e-9 },
                      "no frame presented at \(zoom) (last error: \(controller.lastPresentError ?? "—"))")
    }

    // MARK: - ① fit → 100 %: one bridge, one real frame, identical final pixels

    func testFitToActualIsBridgedAndTheRealFrameReplacesIt() throws {
        let url = try rawFixture()
        let controller = makeController()
        start(controller, url: url, identity: "transition-fit-to-actual")
        waitForFirstFrame(controller)
        XCTAssertEqual(controller.viewState.mode, .fit, "the test must start on the whole frame")
        XCTAssertEqual(controller.zoomBridgeArmedCount, 0, "nothing has crossed yet")

        // What 100 % *should* be, computed independently of the crossing: the fit view's centre.
        let framing = try XCTUnwrap(controller.framing())
        let centre = framing.visibleCenter(of: .fit)
        let expected = LoupeViewState(mode: .actual, zoom: 1, centerX: centre.x, centerY: centre.y)

        // The crossing.
        controller.zoomToActualSize()
        let bridge = try XCTUnwrap(controller.zoomBridge, "fit → 100 % must arm the bridge")
        XCTAssertEqual(controller.zoomBridgeArmedCount, 1, "exactly one bridge per crossing")
        XCTAssertEqual(controller.viewState.mode, .actual)
        XCTAssertEqual(controller.viewState.zoom, 1, accuracy: 1e-12)
        XCTAssertEqual(controller.viewState.centerX, expected.centerX, accuracy: 1e-9)
        XCTAssertEqual(controller.viewState.centerY, expected.centerY, accuracy: 1e-9)
        // The geometry it asks the canvas for: the fit rect scaled to the 1:1 rect.
        XCTAssertEqual(bridge.fromContent, framing.contentPixels(of: .fit))
        XCTAssertEqual(bridge.toContent, framing.contentPixels(of: expected))
        XCTAssertGreaterThan(bridge.scale, 1, "fit → 100 % grows the picture")
        // The carry is a **sampling window on a canvas-sized drawable** now (025), not a transform on
        // the layer: the layer keeps its geometry, and what moves is which part of the texture the
        // present pass reads.
        XCTAssertEqual(controller.zoomBridgeFrames.last?.drawable, controller.viewportPixels,
                       "the transition must draw into the canvas, not into a bigger drawable")
        XCTAssertTrue(CATransform3DIsIdentity(controller.canvasView.metalLayer.transform),
                      "the canvas layer must never be scaled — that is what covered the sidebar")

        // The real frame: the bridge goes, and it covered at least one present on the way.
        XCTAssertTrue(waitFor { controller.zoomBridge == nil },
                      "the bridge never ended (last error: \(controller.lastPresentError ?? "—"))")
        XCTAssertGreaterThanOrEqual(controller.zoomBridgeCoveredPresents, 1,
                                    "at least one frame must be presented while the bridge is up")
        XCTAssertNil(controller.canvasView.metalLayer.animation(forKey: "photons.zoomBridge"),
                     "the animation must be removed with the bridge, not left to finish over the new frame")

        waitForFrame(controller, zoom: 1)
        let final = try XCTUnwrap(controller.lastFrame)
        XCTAssertEqual(final.zoom, 1, accuracy: 1e-12, "the transition must end on the stop, not between")

        // The pixels: a direct render of the same camera, on the same rung that is on screen, must hash
        // identically. This is the assertion that the bridge never became the result.
        let direct = try controller.makeFrame(url: url, viewport: Self.viewport,
                                              decodeScale: final.decodeScale, edit: .neutral,
                                              state: expected, hashPixels: true)
        XCTAssertEqual(final.displayHash, direct.displayHash,
                       "the transition changed the pixels presented at 100 %")
        XCTAssertTrue([Float(0.5), 1].contains(final.decodeScale),
                      "unexpected rung \(final.decodeScale)")
        print("fit→100%: bridges=\(controller.zoomBridgeArmedCount) "
              + "coveredPresents=\(controller.zoomBridgeCoveredPresents) "
              + "scale=\(String(format: "%.4f", bridge.scale)) "
              + "duration=\(String(format: "%.0f", bridge.duration * 1000))ms "
              + "rung=\(final.decodeScale) hash=\((final.displayHash ?? "—").prefix(12))… == direct")
    }

    // MARK: - ④ every stop change is bridged, 100 → 200 → 300 → 400 included

    /// The five-stop ladder's whole problem: `100 → 200 %` is a 2× cut if nothing carries the picture
    /// across, and *every* stop change is now a bridged change — not just `fit ↔ actual`.
    ///
    /// The bridge holds the arriving frame until the geometry gets there (see `present`), so a stop
    /// that arms must also complete, hand the frame over, and end on the real pixels.
    func testActualToActualStopsAreBridgedAndEndOnTheRealFrame() throws {
        let url = try rawFixture()
        let controller = makeController()
        start(controller, url: url, identity: "transition-stops")
        waitForFirstFrame(controller)

        controller.zoomToActualSize()          // the one crossing of this test
        waitForFrame(controller, zoom: 1)
        XCTAssertNil(controller.zoomBridge)
        let armedAfterCrossing = controller.zoomBridgeArmedCount
        XCTAssertEqual(armedAfterCrossing, 1)
        let coveredAfterCrossing = controller.zoomBridgeCoveredPresents

        var visited: [String] = []
        var scales: [String] = []
        for stop in [2.0, 3.0, 4.0, 3.0, 2.0, 1.0] {
            let armed = controller.zoomBridgeArmedCount
            let completed = controller.zoomBridgeCompletedCount
            controller.zoom(to: stop)
            let bridge = try XCTUnwrap(controller.zoomBridge,
                                       "\(stop) is a stop change: it must arm a bridge")
            XCTAssertEqual(controller.zoomBridgeArmedCount, armed + 1, "exactly one bridge per stop")
            XCTAssertEqual(controller.zoomBridgeFrames.last?.drawable, controller.viewportPixels,
                           "\\(stop): the transition must draw into the canvas-sized drawable")
            XCTAssertTrue(CATransform3DIsIdentity(controller.canvasView.metalLayer.transform),
                          "\\(stop): the canvas layer is never scaled")
            scales.append(String(format: "→%.0f%% ×%.2f", stop * 100, bridge.scale))
            // The camera is already at the stop; the pixels are what is late.
            XCTAssertEqual(controller.viewState.zoom, stop, accuracy: 1e-12,
                           "the model jumps immediately")
            XCTAssertTrue(waitFor { controller.zoomBridge == nil },
                          "\(stop): the bridge never completed (last error: "
                          + "\(controller.lastPresentError ?? "—"))")
            XCTAssertEqual(controller.zoomBridgeCompletedCount, completed + 1)
            XCTAssertNil(controller.canvasView.metalLayer.animation(forKey: "photons.zoomBridge"))
            waitForFrame(controller, zoom: stop)
            visited.append(controller.zoomLabel)
            // The frame that ended the bridge is the stop's own frame, at the stop's own zoom.
            XCTAssertEqual(controller.lastFrame?.zoom ?? -1, stop, accuracy: 1e-12)
        }
        XCTAssertEqual(visited, ["200%", "300%", "400%", "300%", "200%", "100%"])
        XCTAssertGreaterThan(controller.zoomBridgeCoveredPresents, coveredAfterCrossing,
                             "each stop presented a frame while its bridge was up (held, then handed over)")
        XCTAssertEqual(controller.zoomBridgePendingDrops, 0, "no frame was thrown away mid-bridge")
        print("stops: armed=\(controller.zoomBridgeArmedCount) "
              + "completed=\(controller.zoomBridgeCompletedCount) "
              + "coveredPresents=\(controller.zoomBridgeCoveredPresents) "
              + "labels=\(visited.joined(separator: "→")) · \(scales.joined(separator: " "))")
    }

    // MARK: - ② no picture, no bridge

    /// Crossing with nothing on screen has nothing to scale: the bridge must not arm, and must not
    /// leave an animation on a layer that will show its first frame in a moment.
    func testCrossingWithNoPresentedFrameArmsNothing() throws {
        let url = try rawFixture()
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        _ = controller.view
        controller.frameSource = LoupeController.FrameSource(url: url, identity: "transition-cold",
                                                             viewport: Self.viewport, state: .fit)
        // `framing()` needs a decoded size: one synchronous preview rung gives it one, without
        // presenting anything.
        _ = try controller.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                     edit: .neutral, state: .fit)
        XCTAssertNil(controller.lastFrame, "nothing has been presented")

        controller.zoomToActualSize()
        XCTAssertEqual(controller.zoomBridgeArmedCount, 0)
        XCTAssertNil(controller.zoomBridge)
        XCTAssertNil(controller.canvasView.metalLayer.animation(forKey: "photons.zoomBridge"))
    }
}
