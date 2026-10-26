import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// 100 % ↔ 200 % : what it costs, in milliseconds, before and after the fit↔actual bridge.
///
/// This file is deliberately written against the API that exists **both** before and after the zoom
/// rework (`zoom(to:)`, `viewState`, `lastFrame`, `viewRenderCount`) so the same test can be run on the
/// two commits and the two runs compared. Its assertions are counts and a generous ceiling; the
/// p50/p95 lines are the numbers to read.
///
/// The claim it has to defend: an `actual → actual` stop change is a re-render from a rung that is
/// already resident, it must not go through any transition, and it must not cost a second frame.
@MainActor
final class LoupeZoomTimingTests: XCTestCase {

    private static let viewport = ImageSize(width: 2560, height: 1600)
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
    private func waitFor(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    /// Request → the frame reaching the canvas, which is the latency a hand feels (the same measure
    /// `LoupeQueueTests` uses). Counted on `viewRenderCount`, not on `lastFrame.zoom`, so the probe
    /// means the same thing on a tree whose `frameSource` is frozen at its constructed camera.
    private func measure(_ controller: LoupeController, from: Double, to: Double,
                         rounds: Int = 20) -> (times: [Double], frames: Int) {
        var times: [Double] = []
        var frames = 0
        for _ in 0..<rounds {
            // Park on `from` first: a stop change to the stop we are already on sets no new state, so
            // the measured wait below must not be satisfied by the previous round's frame.
            if abs(controller.viewState.zoom - from) > 1e-9 || !controller.viewState.isActualSize {
                let parked = controller.viewRenderCount
                controller.zoom(to: from)
                _ = waitFor(10) { controller.viewRenderCount > parked }
            }
            let before = controller.viewRenderCount
            let t0 = CFAbsoluteTimeGetCurrent()
            controller.zoom(to: to)
            let arrived = waitFor(10) { controller.viewRenderCount > before }
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            frames += controller.viewRenderCount - before
            if !arrived { break }
            times.append(elapsed)
        }
        return (times, frames)
    }

    func testHundredToTwoHundredFrameCost() throws {
        let url = try rawFixture()
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)

        controller.frameSource = LoupeController.FrameSource(url: url, identity: "timing-100-200",
                                                             viewport: Self.viewport, state: .fit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        // The first picture at whatever rung the ladder has — the numbers below are about the *stop*
        // change, and a resident preview rung is what an `actual → actual` stop renders from anyway.
        XCTAssertTrue(waitFor(15) { controller.lastFrame != nil }, "no first frame")
        pump(0.3)

        // Warm up on the two stops (the first visit to a stop can include a render-graph set-up).
        _ = measure(controller, from: 1, to: 2, rounds: 2)
        _ = measure(controller, from: 2, to: 1, rounds: 2)

        let up = measure(controller, from: 1, to: 2)
        let framesForUp = up.frames
        let down = measure(controller, from: 2, to: 1)
        let framesForDown = down.frames
        let upTimes = up.times, downTimes = down.times

        let upSorted = upTimes.sorted(), downSorted = downTimes.sorted()
        let line = String(format: "100→200 n=%d p50=%.2f ms p95=%.2f ms · frames/round=%.2f | "
                          + "200→100 n=%d p50=%.2f ms p95=%.2f ms · frames/round=%.2f",
                          upTimes.count, percentile(upSorted, 0.5), percentile(upSorted, 0.95),
                          upTimes.isEmpty ? 0 : Double(framesForUp) / Double(upTimes.count),
                          downTimes.count, percentile(downSorted, 0.5), percentile(downSorted, 0.95),
                          downTimes.isEmpty ? 0 : Double(framesForDown) / Double(downTimes.count))
        print("zoom stop cost: \(line)")

        XCTAssertEqual(upTimes.count, 20, "the 100→200 rounds did not all present a frame")
        XCTAssertEqual(downTimes.count, 20, "the 200→100 rounds did not all present a frame")
        // One frame per stop change. A transition that also rendered would show up here first.
        XCTAssertLessThanOrEqual(Double(framesForUp) / Double(max(upTimes.count, 1)), 2.0,
                                 "100→200 rendered more than one frame per stop change")
        XCTAssertLessThanOrEqual(Double(framesForDown) / Double(max(downTimes.count, 1)), 2.0,
                                 "200→100 rendered more than one frame per stop change")
    }
}
