import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// The `fit ↔ actual` bridge: the loupe's **only** transition, and the numbers that keep it honest.
///
/// The defect it fixes is a decode, not a preference: crossing `fit → 100 %` can need a full-size
/// development (52–900 ms) while the canvas still lays the old picture out for the old camera, so the
/// change reads as a cut. The bridge scales the picture that is already on screen from the rect it
/// occupies to the rect the new camera will occupy, and the first real frame replaces it.
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
        // The geometry it asks the layer for: the fit rect scaled to the 1:1 rect.
        XCTAssertEqual(bridge.fromContent, framing.contentPixels(of: .fit))
        XCTAssertEqual(bridge.toContent, framing.contentPixels(of: expected))
        XCTAssertGreaterThan(bridge.scaleX, 1, "fit → 100 % grows the picture")
        XCTAssertNotNil(controller.canvasView.metalLayer.animation(forKey: "photons.zoomBridge"),
                        "the layer must be carrying the bridge")

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
              + "scale=\(String(format: "%.4f×%.4f", bridge.scaleX, bridge.scaleY)) "
              + "rung=\(final.decodeScale) hash=\((final.displayHash ?? "—").prefix(12))… == direct")
    }

    // MARK: - ④ 100 → 200 → 300 → 400 is untouched

    func testActualToActualStopsNeverArmABridge() throws {
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
        for stop in [2.0, 3.0, 4.0, 3.0, 2.0, 1.0] {
            controller.zoom(to: stop)
            waitForFrame(controller, zoom: stop)
            visited.append(controller.zoomLabel)
            XCTAssertEqual(controller.zoomBridgeArmedCount, armedAfterCrossing,
                           "\(stop) is an actual→actual stop: it must not arm a bridge")
            XCTAssertNil(controller.zoomBridge)
            XCTAssertNil(controller.canvasView.metalLayer.animation(forKey: "photons.zoomBridge"))
        }
        XCTAssertEqual(visited, ["200%", "300%", "400%", "300%", "200%", "100%"])
        XCTAssertEqual(controller.zoomBridgeCoveredPresents, coveredAfterCrossing,
                       "an actual→actual stop must not present a frame under a bridge")
        print("stops: armed=\(controller.zoomBridgeArmedCount) coveredPresents=\(controller.zoomBridgeCoveredPresents) "
              + "labels=\(visited.joined(separator: "→"))")
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
