import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// Entering the loupe must show the photo **without any camera change**.
///
/// Reported bug (2026-10-26): clicking a photo opened the editor on a black canvas; the picture only
/// appeared after a scroll/zoom. Root cause: the first frame after the module switch reaches
/// `CanvasPresenter.present` before the `CAMetalLayer` has a drawable — a layer hands drawables out
/// only once it is in a **visible** window with a non-zero size — and a settled layout schedules no
/// further frame, so nothing ever retried. `LoupeController.retryPresentLater()` is the fix, and this
/// file is the assertion: the window is ordered in *after* the first render was requested, and the
/// photo must still arrive on its own.
@MainActor
final class LoupeFirstFrameTests: XCTestCase {

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

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 60, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    /// The reported sequence: request the frame while the canvas is not yet drawable, then put the
    /// window on screen. No zoom, no pan, no second `scheduleRender`.
    func testThePhotoAppearsWithoutTouchingTheCamera() throws {
        let url = try rawFixture()
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = true
        controller.collectsHistogram = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        windows.append(window)
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
        controller.frameSource = LoupeController.FrameSource(
            url: url, identity: "first-frame",
            viewport: ImageSize(width: 1280, height: 800), state: .fit)

        // Ordered *out*: the layer has no drawable, so this frame cannot be presented.
        controller.scheduleRender()
        pump(0.05)
        XCTAssertNil(controller.lastFrame, "a frame cannot be presented off-screen")

        // The user's window appears. From here on nothing touches the camera.
        window.orderFront(nil)
        let appeared = waitFor(30) { controller.lastFrame != nil }
        let stats = controller.developmentStats
        XCTContext.runActivity(named: "first frame diagnostics") { _ in
            print("first-frame: appeared=\(appeared) presentError=\(controller.lastPresentError ?? "—") "
                  + "decodes=\(stats.decodes) deliveries=\(stats.deliveries) drops=\(stats.drops) "
                  + "rungArrivals=\(controller.rungArrivals) viewRenderCount=\(controller.viewRenderCount) "
                  + "viewport=\(controller.viewportPixels.width)×\(controller.viewportPixels.height) "
                  + "stale=\(controller.staleFrameDrops) empty=\(controller.emptyFrameDrops) "
                  + "requests=\(controller.viewRenderRequests) starts=\(controller.viewRenderStarts) "
                  + "coalesced=\(controller.viewRenderCoalesced) rungs=\(controller.residentRungScales)")
        }
        XCTAssertTrue(appeared,
                      "the photo never appeared on its own (last error: \(controller.lastPresentError ?? "—"))")
        XCTAssertNil(controller.lastPresentError)
        // Since 005 the first frame *arms* the measurement instead of carrying one: the histogram is
        // a picture-level render, debounced behind the picture's key, so it lands a moment later.
        let measured = waitFor(120) { controller.lastHistogram != nil }
        XCTAssertTrue(measured, "the first look at a photo must produce a histogram")
        XCTAssertGreaterThan(controller.histogramRefreshCount, 0, "and it must be a real measurement")
    }
}
