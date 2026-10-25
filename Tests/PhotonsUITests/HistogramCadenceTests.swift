import XCTest
import CoreGraphics
import Metal
import PhotonsCore
import PhotonsUI

/// Q30 — the histogram's **cadence**: a measurement is a reading of a picture, and a picture sliding
/// under the plot cannot be read. Before this the card cost a 1:1 pan **8 ms per frame in release and
/// 104 ms in a debug build** (0.65 Mpx of CPU binning plus a 5.1 MB readback), i.e. 20× the frame it
/// was measuring; the pan budget the repo quotes (4–5 ms) was only true with the histogram switched
/// off, which is not the configuration the app ships.
///
/// The rules this file defends:
///
///   ① a frame whose camera moved **does not measure** (20 pans → at most two measurements, and the
///      frame that confirms the camera is the one that does);
///   ② the card is refreshed **once**, ~60 ms after the hand stops, on a frame that is measured but
///      not presented — so the numbers are of the picture on screen, and no second picture appears;
///   ③ the card keeps the last numbers while a pan is in flight (it must not blank out);
///   ④ the pan frames themselves cost the same with the card on as with it off;
///   ⑤ the numbers still line up with an independent measurement of the same pixels (asserted in
///      `HistogramTests.testWindowFrameAndFullFrameAgreeOnTheSameROI`, where the pixels are known).
@MainActor
final class HistogramCadenceTests: XCTestCase {

    private static let viewport = ImageSize(width: 2560, height: 1600)
    private var windows: [NSWindow] = []

    /// `PHOTONS_BENCH=1` turns the absolute millisecond budgets on, exactly as the Q29 benches do.
    private var benchmarks: Bool { ProcessInfo.processInfo.environment["PHOTONS_BENCH"] != nil }

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - fixtures

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

    /// The loupe's own controller, with a real window (its `present` needs a drawable) and the card
    /// switch **on** — `LoupeQueueTests` turns it off for its pan benches, which is the configuration
    /// this file exists to cover.
    private func makeController(autoRender: Bool = false) -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = autoRender
        controller.collectsHistogram = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        return controller
    }

    /// The 1:1 window the camera shows after `step` pans of 16 source pixels (the Q29 bench's camera).
    private func pannedState(_ step: Int) -> LoupeViewState {
        LoupeViewState(mode: .actual, zoom: 1,
                       centerX: 3000 + Double(step * 16), centerY: 2000 + Double(step * 9))
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 120, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func percentile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }

    private func frame(_ loupe: LoupeController, url: URL, state: LoupeViewState) throws -> LoupeController.FrameResult {
        try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                            edit: .neutral, state: state)
    }

    // MARK: - ① the rule itself: a pan does not measure

    func testAPanDoesNotMeasureAndTheSettledCameraDoes() throws {
        let url = try rawFixture()
        let loupe = makeController()

        // The first frame of a photo is a first look, not a gesture.
        let first = try frame(loupe, url: url, state: .fit)
        XCTAssertNotNil(first.histogram, "the first frame of a photo must measure")
        XCTAssertEqual(loupe.histogramSkippedFrames, 0)

        var measuredDuringPan = 0
        for step in 1...20 {
            let pan = try frame(loupe, url: url, state: pannedState(step))
            if pan.histogram != nil { measuredDuringPan += 1 }
        }
        XCTAssertEqual(measuredDuringPan, 0, "no pan frame may carry a histogram")
        XCTAssertEqual(loupe.histogramSkippedFrames, 20)

        // The hand stops: the next frame at the same camera is the measurement.
        let settled = try frame(loupe, url: url, state: pannedState(20))
        XCTAssertNotNil(settled.histogram, "the frame that confirms the camera must measure")
        XCTAssertEqual(loupe.histogramSkippedFrames, 20, "a confirming frame is not a skip")
    }

    // MARK: - ②③ the deferred measurement, through the shipped queue path

    func testTheHandStopsAndTheCardIsRefreshedOnce() throws {
        let url = try rawFixture()
        let loupe = makeController(autoRender: true)
        loupe.frameSource = LoupeController.FrameSource(url: url, identity: "cadence",
                                                       viewport: Self.viewport, state: .fit)
        loupe.scheduleRender()
        XCTAssertTrue(waitFor(120) { loupe.lastFrame?.histogram != nil },
                      "the first frame of a photo must measure")
        let publishedOnOpen = loupe.histogramPublishCount
        let firstHistogram = loupe.lastHistogram
        XCTAssertNotNil(firstHistogram)

        // Twenty pans, driven the way the canvas drives them: a new camera, one request each.
        for step in 1...20 {
            loupe.frameSource = LoupeController.FrameSource(url: url, identity: "cadence",
                                                            viewport: Self.viewport,
                                                            state: pannedState(step))
            loupe.requestViewportRender()
            pump(0.008)
        }
        XCTAssertEqual(loupe.lastHistogram, firstHistogram,
                       "the card keeps the numbers it has while the picture moves")
        XCTAssertGreaterThanOrEqual(loupe.histogramSkippedFrames, 18,
                                    "the pan frames must have skipped the measurement")

        // The hand stops. One deferred measurement, at the camera on screen, and the card follows.
        XCTAssertTrue(waitFor(10) { loupe.histogramRefreshCount >= 1 },
                      "the settled camera was never measured")
        XCTAssertTrue(waitFor(10) { loupe.histogramPublishCount > publishedOnOpen },
                      "the card never received the settled measurement")
        XCTAssertLessThanOrEqual(loupe.histogramRefreshCount, 2,
                                 "a gesture may cost one deferred measurement, not one per gap")
        XCTAssertLessThanOrEqual(loupe.histogramPublishCount - publishedOnOpen, 2,
                                 "twenty pan frames may cost at most two measurements")
        let refreshed = try XCTUnwrap(loupe.lastHistogram)
        XCTAssertEqual(refreshed.canvas, Self.viewport,
                       "the measurement is of the canvas on screen")
        XCTAssertNotEqual(refreshed, firstHistogram, "the settled camera is a different picture")

        print(String(format: "Q30 settle: %d skipped frames → %d deferred measurement(s) · "
                        + "measurement %.1f ms · hand-stop→card %.1f ms (%d publishes)",
                     loupe.histogramSkippedFrames, loupe.histogramRefreshCount,
                     loupe.lastHistogramMilliseconds, loupe.lastHistogramLatency,
                     loupe.histogramPublishCount))

        // ③ the card's latency. The budget is a claim about the shipped (optimized) app: this build's
        // binning loop is ~20× slower in `-Onone` (94 ms vs 3.4 ms for the same grid, measured), so on
        // a debug build the wall-clock budget would measure the compiler, not the design. Measured and
        // printed either way; asserted where it means something.
        if benchmarks, optimizedBuild() {
            XCTAssertLessThanOrEqual(loupe.lastHistogramLatency, 150,
                                     "the card must catch up within 150 ms of the hand stopping")
        }
    }

    /// A debug build's `-Onone` binning is ~20× the optimized one; the arithmetic below is the same
    /// work the deferred measurement does (a 1024-long-edge grid of a viewport-sized region).
    private func optimizedBuild() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let w = 1024, h = 640
        let rgba = [Float16](repeating: Float16(0.4), count: w * h * 4)
        let image = DisplayImage(width: w, height: h, rgba: rgba, primaries: .sRGB, bitDepth: 16)
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = Histogram.compute(image)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        _ = device
        return ms < 30
    }

    // MARK: - ④ the pan frames pay nothing for the card

    /// Twenty 1:1 pans, the card on and off, interleaved so drift cannot favour either side. This is
    /// the acceptance number: **Δp50 and Δp95 ≤ 1.5 ms** — i.e. the card is free on a pan frame.
    func testPanFramesCostNothingForTheCard() throws {
        let url = try rawFixture()
        let loupe = makeController()
        // Warm: the graph, the ladder, the pool, the pipeline (the first frame measures).
        _ = try frame(loupe, url: url, state: pannedState(0))
        _ = try frame(loupe, url: url, state: pannedState(1))

        var offTimes: [Double] = [], onTimes: [Double] = []
        for step in 0..<20 {
            // Two consecutive pan steps, one with the card on and one with it off: both are a camera
            // that moved, which is the frame shape that must not measure.
            loupe.collectsHistogram = false
            var t0 = CFAbsoluteTimeGetCurrent()
            _ = try frame(loupe, url: url, state: pannedState(100 + step * 2))
            offTimes.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)

            loupe.collectsHistogram = true
            t0 = CFAbsoluteTimeGetCurrent()
            _ = try frame(loupe, url: url, state: pannedState(100 + step * 2 + 1))
            onTimes.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }

        let offP50 = percentile(offTimes, 0.5), offP95 = percentile(offTimes, 0.95)
        let onP50 = percentile(onTimes, 0.5), onP95 = percentile(onTimes, 0.95)
        print(String(format: "Q30 1:1 pan, 20 frames, card on vs off: off p50 %.2f / p95 %.2f ms · "
                        + "on p50 %.2f / p95 %.2f ms · Δp50 %+.2f / Δp95 %+.2f ms",
                     offP50, offP95, onP50, onP95, onP50 - offP50, onP95 - offP95))

        XCTAssertGreaterThanOrEqual(loupe.histogramSkippedFrames, 20,
                                    "every measured pan frame must have skipped the histogram")
        // Load-proof: 104 ms of measurement would blow through this even on a busy machine.
        XCTAssertLessThan(onP50 - offP50, 5.0, "the card must not cost a pan frame its budget")
        if benchmarks {
            XCTAssertLessThanOrEqual(onP50 - offP50, 1.5, "Δp50 must fit in 1.5 ms")
            XCTAssertLessThanOrEqual(onP95 - offP95, 1.5, "Δp95 must fit in 1.5 ms")
        }
    }
}
