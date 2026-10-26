import XCTest
import CoreGraphics
import Metal
import PhotonsCore
import PhotonsUI

/// The histogram's **cadence**, after 005 (2026-10-26): the numbers are of the picture, so a frame
/// measures nothing and a gesture cannot cost one.
///
/// Q30 measured a frame and paid 8 ms per 1:1 pan frame (release; 104 ms in a debug build) for a plot
/// nobody can read while the picture slides. 005 removed the coupling at the root instead of scheduling
/// around it: the measurement is its own whole-picture render, keyed by
/// `hist(rung, editDigest, bins)`, debounced 120 ms behind the key and *never* behind the camera.
///
/// The rules this file defends:
///
///   ① no frame carries a histogram at all, whatever the camera does —
///      `histogramSkippedFrames` counts the frames, `histogramRefreshCount` the measurements;
///   ② the card follows the **edit**, once, and a pan between edits publishes nothing;
///   ③ the card keeps the last numbers while the picture moves (it must not blank out);
///   ④ the pan frames themselves cost the same with the card on as with it off;
///   ⑤ the measurement is of the picture, not of the viewport the camera happens to be showing.
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
    private func waitFor(_ timeout: TimeInterval = settleDeadline, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    /// Deadlines, not budgets. A deadline only says "this never finished"; both are far above what a
    /// loaded machine (a parallel `swift build` next door) needs, so neither can turn into a flake.
    private static let settleDeadline: TimeInterval = 5
    /// The first develop of the 60 MP fixture is ~0.3–1.4 s quiet; under a compile it is several
    /// times that. A deadline, never an assertion about speed.
    private static let openDeadline: TimeInterval = 15

    /// Wait until the loupe is **quiet**: no viewport frame rendering or waiting, nothing armed,
    /// nothing measuring. This replaces "pump 0.3 s and hope the queue got there": every counter the
    /// assertions below read is only meaningful once the queue is empty, and *when* it emptied is not
    /// something this file asserts.
    private func settle(_ loupe: LoupeController, timeout: TimeInterval = settleDeadline) {
        func quiet() -> Bool { !loupe.viewportRenderInFlight && loupe.histogramIsIdle }
        // Two consecutive quiet turns: a frame that just finished dispatches its key check as its own
        // main-queue block, so one quiet turn can be the turn *before* that block ran.
        var streak = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            streak = quiet() ? streak + 1 : 0
            if streak >= 2 { return }
            pump(0.01)
        }
        XCTAssertTrue(quiet(),
                      "the loupe never went quiet (rendering \(loupe.viewportRenderInFlight), "
                      + "histogram idle \(loupe.histogramIsIdle), "
                      + "error \(loupe.lastHistogramError ?? "—"))")
    }

    /// Let the main queue deliver the blocks a synchronous frame left behind (`noteHistogramKey` hops
    /// to main). No claim about how long that takes: with the renderer off none of them can measure
    /// anything, which is exactly what is being asserted.
    private func drain(_ turns: Int = 3) {
        for _ in 0..<turns { pump() }
    }

    private func percentile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }

    private func frame(_ loupe: LoupeController, url: URL, state: LoupeViewState,
                       edit: EditModel = .neutral) throws -> LoupeController.FrameResult {
        try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                            edit: edit, state: state)
    }

    /// A document that differs from neutral by one develop setting.
    private func brighter(_ stops: Double) -> EditModel {
        var edit = EditModel.neutral
        var light = edit.light
        light.exposure += stops
        edit.light = light
        return edit
    }

    // MARK: - ① no frame measures, whatever the camera does

    func testNoFrameCarriesAHistogramAtAnyCamera() throws {
        let url = try rawFixture()
        let loupe = makeController()

        _ = try frame(loupe, url: url, state: .fit)
        for step in 1...20 {
            _ = try frame(loupe, url: url, state: pannedState(step))
        }
        // Let the main queue deliver what those 21 frames left behind before reading the counters.
        drain()
        // 21 frames, 21 non-measurements. With `autoRenderEnabled` off nothing arms the debounce, so
        // this is also the proof that a frame is not what triggers a measurement.
        XCTAssertEqual(loupe.histogramSkippedFrames, 21)
        XCTAssertEqual(loupe.histogramRefreshCount, 0, "no measurement may run off a frame")
        XCTAssertEqual(loupe.histogramPublishCount, 0, "and none may reach the card")
        XCTAssertNil(loupe.lastHistogram)
        print("frames without a histogram: \(loupe.histogramSkippedFrames) (fit + 20 pans), "
              + "measurements \(loupe.histogramRefreshCount)")
    }

    /// The measurement itself is of the picture: the viewport the camera is showing is not in it.
    func testTheMeasurementIsOfThePictureNotTheViewport() throws {
        let url = try rawFixture()
        let loupe = makeController()

        let atFit = try frame(loupe, url: url, state: .fit)
        let histogram = try loupe.measureHistogramNow(url: url, identity: "cadence", edit: .neutral)

        XCTAssertEqual(loupe.histogramPublishCount, 1)
        XCTAssertEqual(loupe.lastHistogram, histogram)
        // 2560 × 1600 is the viewport; the picture is neither that size nor its aspect.
        XCTAssertNotEqual(histogram.canvas, Self.viewport)
        XCTAssertTrue(histogram.sampleCount > 0)
        XCTAssertEqual(histogram.sampleCount, histogram.sampleSize.pixelCount)
        XCTAssertEqual(histogram.sampleSize, Histogram.sampleSize(for: histogram.roi))
        XCTAssertEqual(histogram.roi, ImageRect(x: 0, y: 0, width: histogram.canvas.width,
                                                height: histogram.canvas.height),
                       "the measurement covers the whole picture")
        XCTAssertGreaterThan(histogram.canvas.width, 0)

        // A second call — same document — is the same numbers, at any camera.
        _ = try frame(loupe, url: url, state: pannedState(7))
        let again = try loupe.measureHistogramNow(url: url, identity: "cadence", edit: .neutral)
        XCTAssertEqual(again.binsDigest(), histogram.binsDigest())
        XCTAssertEqual(again.sampleCount, histogram.sampleCount)
        print("histogram of the picture: \(histogram.canvas.width)×\(histogram.canvas.height) picture → "
              + "\(histogram.sampleCount) px on \(histogram.sampleSize.width)×\(histogram.sampleSize.height), "
              + "digest \(histogram.binsDigest().prefix(16))…")
    }

    // MARK: - ②③ the debounced measurement, through the shipped queue path

    func testTheCardFollowsTheEditAndNotTheCamera() throws {
        let url = try rawFixture()
        let loupe = makeController(autoRender: true)
        loupe.frameSource = LoupeController.FrameSource(url: url, identity: "cadence",
                                                        viewport: Self.viewport, state: .fit)
        loupe.scheduleRender()
        XCTAssertTrue(waitFor(Self.openDeadline) { loupe.lastHistogram != nil },
                      "opening a photo must produce a measurement")
        // Not "sleep until it feels done": wait until the card has its numbers **and** the loupe has
        // nothing armed. A count read while a debounce is still pending is a sample, not an answer.
        settle(loupe)
        let publishedOnOpen = loupe.histogramPublishCount
        let measurementsOnOpen = loupe.histogramRefreshCount
        let framesOnOpen = loupe.histogramSkippedFrames
        let firstHistogram = try XCTUnwrap(loupe.lastHistogram)

        // Twenty pans, driven the way the canvas drives them: a new camera, one request each. How
        // long any one of them takes is the machine's business — the claim is about what they count.
        for step in 1...20 {
            loupe.frameSource = LoupeController.FrameSource(url: url, identity: "cadence",
                                                            viewport: Self.viewport,
                                                            state: pannedState(step))
            loupe.requestViewportRender()
            pump(0.008)
        }
        settle(loupe)
        XCTAssertGreaterThan(loupe.histogramSkippedFrames, framesOnOpen,
                             "the pans must have rendered — otherwise this proves nothing")
        XCTAssertEqual(loupe.lastHistogram, firstHistogram,
                       "the card keeps the numbers it has while the picture moves")
        XCTAssertEqual(loupe.histogramPublishCount, publishedOnOpen,
                       "a pan may not publish a measurement")
        XCTAssertEqual(loupe.histogramRefreshCount, measurementsOnOpen,
                       "and may not run one — during the pans, and not after the hand stops either")

        // The edit: one debounced measurement, and the card follows.
        loupe.frameSource = LoupeController.FrameSource(url: url, identity: "cadence",
                                                        viewport: Self.viewport,
                                                        state: pannedState(20),
                                                        edit: brighter(1))
        loupe.requestViewportRender()
        XCTAssertTrue(waitFor(Self.settleDeadline) { loupe.histogramPublishCount > publishedOnOpen },
                      "the edit was never measured")
        settle(loupe)
        if benchmarks {
            // A budget, and only a bench build may judge one: 400 ms from "the picture changed" to
            // "the card has it", debounce included.
            XCTAssertLessThanOrEqual(loupe.lastHistogramLatency, 400,
                                     "the card must catch up shortly after the edit stops")
        }
        XCTAssertEqual(loupe.histogramPublishCount - publishedOnOpen, 1,
                       "one edit is one measurement, however many ticks it took")
        let edited = try XCTUnwrap(loupe.lastHistogram)
        XCTAssertNotEqual(edited.binsDigest(), firstHistogram.binsDigest(),
                          "a brighter document is a different distribution")
        // And the numbers are of the *picture*: whole canvas, whole roi, the same invariants the
        // synchronous path asserts — no viewport in them, whatever rung the ladder had resident.
        XCTAssertNotEqual(edited.canvas, Self.viewport)
        XCTAssertEqual(edited.roi, ImageRect(x: 0, y: 0, width: edited.canvas.width,
                                             height: edited.canvas.height),
                       "the measurement covers the whole picture, not the window")

        print(String(format: "005 cadence: %d frames, %d measurements · edit→card %.1f ms "
                     + "· measurement %.1f ms · %d publishes",
                     loupe.histogramSkippedFrames, loupe.histogramRefreshCount,
                     loupe.lastHistogramLatency, loupe.lastHistogramMilliseconds,
                     loupe.histogramPublishCount))

        // A slider drag is a burst of edits 8 ms apart: one measurement, for the last one.
        //
        // The window is set here instead of being assumed: the invariant is "a burst **inside the
        // window** is one measurement", so the window has to be wide enough that the burst is inside
        // it by construction — otherwise the test is a stopwatch on the scheduler, which is exactly
        // the thing that flakes under a compile. The shipped 120 ms is a taste decision; the print
        // below records how a real burst compares to it.
        loupe.histogramDebounceInterval = 2.0
        let beforeDrag = loupe.histogramPublishCount
        let dragStarted = CFAbsoluteTimeGetCurrent()
        for tick in 1...10 {
            loupe.frameSource = LoupeController.FrameSource(url: url, identity: "cadence",
                                                            viewport: Self.viewport,
                                                            state: pannedState(20),
                                                            edit: brighter(1 + Double(tick) * 0.1))
            loupe.requestViewportRender()
            pump(0.008)
        }
        let dragMilliseconds = (CFAbsoluteTimeGetCurrent() - dragStarted) * 1000
        settle(loupe, timeout: Self.openDeadline)   // the window is 2 s: the wait is window + develop
        let dragPublishes = loupe.histogramPublishCount - beforeDrag
        XCTAssertEqual(dragPublishes, 1, "a ten-tick drag must collapse into one measurement")
        // Ten edits, one measurement — and the numbers on the card are the burst's, not the picture
        // that was there before the drag started. (A digest is compared, not a rung: which decode
        // buffer is resident is the ladder's business, and it can change under any test.)
        let afterDrag = try XCTUnwrap(loupe.lastHistogram)
        XCTAssertNotEqual(afterDrag.binsDigest(), edited.binsDigest(),
                          "the burst must leave its own numbers on the card")
        print(String(format: "005 drag: ten ticks over %.0f ms (the shipped window is 120 ms) → %d "
                     + "measurement", dragMilliseconds, dragPublishes))
    }

    // MARK: - ④ the pan frames pay nothing for the card

    /// Twenty 1:1 pans, the card on and off, interleaved so drift cannot favour either side. With the
    /// measurement decoupled there is nothing left for the card to cost a frame, and this is the number
    /// that says so: **Δp50 and Δp95 ≤ 1.5 ms** in a bench build.
    ///
    /// The number is *recorded* here and asserted only under `PHOTONS_BENCH=1`: a debug build on a
    /// loaded machine cannot judge a frame budget, and a test that does is a test that goes red for
    /// reasons that have nothing to do with the product. The structural half — the frames measured
    /// nothing at all, card on or off — is asserted every run, and it is the claim that matters.
    func testPanFramesCostNothingForTheCard() throws {
        let url = try rawFixture()
        let loupe = makeController()
        // Warm: the graph, the ladder, the pool (and one measurement, so nothing is armed).
        _ = try frame(loupe, url: url, state: pannedState(0))
        _ = try loupe.measureHistogramNow(url: url, identity: "cadence", edit: .neutral)
        drain()

        let framesBefore = loupe.histogramSkippedFrames
        let measurementsBefore = loupe.histogramRefreshCount

        var offTimes: [Double] = [], onTimes: [Double] = []
        for step in 0..<20 {
            loupe.collectsHistogram = false
            var t0 = CFAbsoluteTimeGetCurrent()
            _ = try frame(loupe, url: url, state: pannedState(100 + step * 2))
            offTimes.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)

            loupe.collectsHistogram = true
            t0 = CFAbsoluteTimeGetCurrent()
            _ = try frame(loupe, url: url, state: pannedState(100 + step * 2 + 1))
            onTimes.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        drain()

        let offP50 = percentile(offTimes, 0.5), offP95 = percentile(offTimes, 0.95)
        let onP50 = percentile(onTimes, 0.5), onP95 = percentile(onTimes, 0.95)
        // Recorded, never judged outside a bench build.
        print(String(format: "005 1:1 pan, 20 frames, card on vs off: off p50 %.2f / p95 %.2f ms · "
                        + "on p50 %.2f / p95 %.2f ms · Δp50 %+.2f / Δp95 %+.2f ms",
                     offP50, offP95, onP50, onP95, onP50 - offP50, onP95 - offP95))

        // The structural claim: forty frames, forty non-measurements, and the card's numbers did not
        // move — with the card on *and* off. No clock in it.
        XCTAssertEqual(loupe.histogramSkippedFrames - framesBefore, 40,
                       "every frame must have carried no histogram — on and off alike")
        XCTAssertEqual(loupe.histogramRefreshCount, measurementsBefore,
                       "a pan may not run a measurement, whether the card is on or off")
        if benchmarks {
            XCTAssertLessThanOrEqual(onP50 - offP50, 1.5, "Δp50 must fit in 1.5 ms")
            XCTAssertLessThanOrEqual(onP95 - offP95, 1.5, "Δp95 must fit in 1.5 ms")
        }
    }
}
