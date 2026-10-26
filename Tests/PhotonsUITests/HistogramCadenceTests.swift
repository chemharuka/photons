import XCTest
import CoreGraphics
import Metal
import PhotonsCore
import PhotonsUI

/// The histogram's **cadence**, after 034 (2026-10-26): the numbers are the picture's, and they are
/// measured out of the frame that drew the picture.
///
/// 005 made the plot a picture-level measurement but kept it behind a 120 ms edit debounce and a
/// second thumbnail render (≈11 ms), so a slider drag moved the picture while the plot stood still
/// (the owner's report: 「拖动调节条结束后再更新」). 027 added
/// `RenderGraph.measureFrameHistogram(fromFrame:)` (engine p50 1.38 / p95 3.21 ms, 0.29 MB readback)
/// and 034 wires it in: a key change is measured **on that frame**, with no debounce at all.
///
/// The rules this file defends, each with the counter that can be asked:
///
///   ① a burst of edits measures **every frame it renders**, and the card ends on the last edit's
///      numbers (`histogramRefreshCount`, `histogramPublishCount`);
///   ② a pan measures nothing and publishes nothing (`histogramRefreshCount` unchanged, the frames
///      counted in `histogramSkippedFrames`);
///   ③ a frame that is only a *window* into the picture (1:1) publishes nothing and marks
///      `lastHistogramError == "window frame"`, and the card keeps the whole-picture numbers it had —
///      zooming must neither move the plot nor blank it;
///   ④ A → B → A is two measurements: the third frame is a cache hit on `Histogram.cacheKey`;
///   ⑤ a pan frame costs the same with the card on as with it off.
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

    /// Wait until the loupe is **quiet**: no viewport frame rendering or waiting, nothing measuring.
    /// This replaces "pump 0.3 s and hope the queue got there": every counter the assertions below
    /// read is only meaningful once the queue is empty, and *when* it emptied is not something this
    /// file asserts.
    private func settle(_ loupe: LoupeController, timeout: TimeInterval = settleDeadline) {
        func quiet() -> Bool { !loupe.viewportRenderInFlight && loupe.histogramIsIdle }
        // Two consecutive quiet turns: a frame dispatched its histogram step to main as its own block
        // (034 — apply on main), so one quiet turn can be the turn *before* that block ran.
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

    /// Let the main queue deliver the blocks a frame left behind. No claim about how long that takes.
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

    // MARK: - ① a drag measures every frame it renders (the 120 ms debounce is gone)

    /// Ten ticks of a slider, ten frames, ten measurements — 005 collapsed the same burst into **one**
    /// (that is the defect this file now pins from the other side), and the card ends on the numbers of
    /// the *last* tick, not of some earlier one.
    ///
    /// The frames are drawn synchronously (`makeFrame`), which is the shipped synchronous path and the
    /// one `--ui-smoke` uses: every call is one frame, so "one measurement per frame" is a claim about
    /// the cadence and not about the scheduler's luck. The queue-driven version of the same claim is
    /// `testTheCardFollowsTheEditAndNotTheCamera`.
    func testADragMeasuresEveryFrameItRenders() throws {
        let url = try rawFixture()
        let loupe = makeController()

        // Warm: the first frame of a picture is a new key, so it measures. This is the baseline.
        _ = try frame(loupe, url: url, state: .fit, edit: brighter(1))
        drain()
        let refreshBefore = loupe.histogramRefreshCount
        let publishBefore = loupe.histogramPublishCount
        let collectedBefore = loupe.histogramCollectedFrames
        let warmDigest = try XCTUnwrap(loupe.lastHistogram).binsDigest()

        var digests: [String] = []
        var measurementMs: [Double] = []
        for tick in 1...10 {
            _ = try frame(loupe, url: url, state: .fit,
                          edit: brighter(1 + Double(tick) * 0.1))
            let current = try XCTUnwrap(loupe.lastHistogram,
                                        "tick \(tick) published nothing — the plot is not following the drag")
            digests.append(current.binsDigest())
            measurementMs.append(loupe.lastHistogramMilliseconds)
        }
        drain()

        // Ten frames that changed the picture, ten measurements. Asserted exactly: each tick is a
        // different document, so there is nothing here for a cache hit or a skipped frame to hide in.
        let refreshDelta = loupe.histogramRefreshCount - refreshBefore
        XCTAssertEqual(refreshDelta, 10,
                       "a ten-tick drag must measure ten frames — 005's answer was one")
        XCTAssertGreaterThanOrEqual(refreshDelta, 9, "and never fewer than the frames it drew")
        XCTAssertEqual(loupe.histogramPublishCount - publishBefore, 10,
                       "one publish per measured frame: the card follows every tick")
        XCTAssertEqual(loupe.histogramCollectedFrames - collectedBefore, 10)
        XCTAssertNil(loupe.lastHistogramError)

        // The numbers on the card are the last tick's, and each tick's were its own (ten distinct
        // documents, ten distinct distributions — the digest is the plot's identity).
        XCTAssertEqual(try XCTUnwrap(loupe.lastHistogram).binsDigest(), digests[9],
                       "the card must end on the last tick's numbers")
        XCTAssertEqual(Set(digests).count, 10,
                       "every tick published its own numbers, not a stale pair of them")
        XCTAssertNotEqual(digests[9], warmDigest)

        print(String(format: "034 drag: 10 ticks → %d measurements / %d publishes · measurement "
                     + "p50 %.2f / p95 %.2f ms · latency %.1f ms",
                     refreshDelta, loupe.histogramPublishCount - publishBefore,
                     percentile(measurementMs, 0.5), percentile(measurementMs, 0.95),
                     loupe.lastHistogramLatency))

        // The per-frame cost of the measurement, judged only by a bench build (a debug build on a
        // loaded machine cannot judge 2 ms).
        if benchmarks {
            XCTAssertLessThanOrEqual(percentile(measurementMs, 0.5), 2.0,
                                     "the measurement must fit in 2 ms at p50")
            XCTAssertLessThanOrEqual(percentile(measurementMs, 0.95), 4.0,
                                     "and in 4 ms at p95")
        }
    }

    /// The same ten edits with the card **on** and **off**, interleaved so drift cannot favour either
    /// side: this is the per-frame price a slider drag now pays for a live plot.
    func testADragFrameCostsTheSameWithTheCardOff() throws {
        let url = try rawFixture()
        let loupe = makeController()
        _ = try frame(loupe, url: url, state: .fit)          // warm: graph, ladder, pool
        drain()

        var offTimes: [Double] = [], onTimes: [Double] = []
        for tick in 0..<10 {
            // The same document measured twice would be a cache hit, so each pair is its own edit —
            // off first, on second, both at the same key.
            let edit = brighter(3 + Double(tick) * 0.1)

            loupe.collectsHistogram = false
            var t0 = CFAbsoluteTimeGetCurrent()
            _ = try frame(loupe, url: url, state: .fit, edit: edit)
            offTimes.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)

            loupe.collectsHistogram = true
            t0 = CFAbsoluteTimeGetCurrent()
            _ = try frame(loupe, url: url, state: .fit, edit: edit)
            onTimes.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        drain()

        let offP50 = percentile(offTimes, 0.5), offP95 = percentile(offTimes, 0.95)
        let onP50 = percentile(onTimes, 0.5), onP95 = percentile(onTimes, 0.95)
        print(String(format: "034 drag frame, card on vs off: off p50 %.2f / p95 %.2f ms · "
                     + "on p50 %.2f / p95 %.2f ms · Δp50 %+.2f / Δp95 %+.2f ms",
                     offP50, offP95, onP50, onP95, onP50 - offP50, onP95 - offP95))
        if benchmarks {
            XCTAssertLessThanOrEqual(onP50 - offP50, 2.0, "Δp50 must fit in 2 ms")
            XCTAssertLessThanOrEqual(onP95 - offP95, 4.0, "Δp95 must fit in 4 ms")
        }
    }

    // MARK: - ② a pan measures nothing (and the counters say so)

    /// Twenty 1:1 pans after a fit frame: the picture's key does not move, so neither does anything
    /// else. The card keeps the numbers it has, and the pan frames are counted as non-measurements.
    func testAPanMeasuresNothingAndPublishesNothing() throws {
        let url = try rawFixture()
        let loupe = makeController()

        _ = try frame(loupe, url: url, state: .fit)
        drain()
        let atFit = try XCTUnwrap(loupe.lastHistogram, "opening a photo must produce a histogram")
        let refreshBefore = loupe.histogramRefreshCount
        let publishBefore = loupe.histogramPublishCount
        let skippedBefore = loupe.histogramSkippedFrames
        XCTAssertEqual(refreshBefore, 1, "the first frame of a picture is one measurement")

        for step in 1...20 {
            _ = try frame(loupe, url: url, state: pannedState(step))
        }
        drain()

        XCTAssertEqual(loupe.histogramSkippedFrames - skippedBefore, 20,
                       "twenty pan frames, twenty non-measurements")
        XCTAssertEqual(loupe.histogramRefreshCount, refreshBefore,
                       "a pan may not run a measurement")
        XCTAssertEqual(loupe.histogramPublishCount, publishBefore,
                       "and may not publish one")
        XCTAssertEqual(loupe.lastHistogram, atFit, "the card keeps the picture's numbers")
        XCTAssertNil(loupe.lastHistogramError,
                     "a pan is not a window frame: the key did not move, so nothing is wrong")

        print("034 pan: \(loupe.histogramSkippedFrames - skippedBefore) frames skipped · "
              + "\(loupe.histogramRefreshCount) measurements total · "
              + "canvas \(atFit.canvas.width)×\(atFit.canvas.height)")
    }

    // MARK: - ③ a window frame publishes nothing (and does not blank the plot)

    /// At 1:1 the frame is a **crop** of the picture, so its pixels are not the picture's. 034 measures
    /// nothing there, publishes nothing, and says why; the card keeps the whole-picture numbers it had.
    /// Back at fit the same edit measures — the plot must not be stuck on the pre-zoom numbers.
    func testAWindowFramePublishesNothingAndMarksIt() throws {
        let url = try rawFixture()
        let loupe = makeController()

        _ = try frame(loupe, url: url, state: .fit, edit: .neutral)
        drain()
        let whole = try XCTUnwrap(loupe.lastHistogram)
        let refreshBefore = loupe.histogramRefreshCount
        let publishBefore = loupe.histogramPublishCount
        // The fit frame is the picture: its ROI is the whole canvas it was labelled with.
        XCTAssertEqual(whole.roi, ImageRect(x: 0, y: 0, width: whole.canvas.width,
                                            height: whole.canvas.height))

        // The edit that would move the plot — but the camera is at 1:1, so the frame is a window.
        _ = try frame(loupe, url: url, state: pannedState(0), edit: brighter(1))
        drain()

        XCTAssertEqual(loupe.lastHistogramError, "window frame",
                       "a window frame must say what it is, not silently publish the crop's numbers")
        XCTAssertEqual(loupe.histogramRefreshCount, refreshBefore,
                       "the crop is not the picture: it must not even be measured")
        XCTAssertEqual(loupe.histogramPublishCount, publishBefore,
                       "and nothing may reach the card")
        XCTAssertEqual(loupe.lastHistogram, whole,
                       "switching fit → 1:1 must not blank the plot (no flash, no empty card)")
        let windowMark = loupe.lastHistogramError

        // …and the camera returning to fit publishes the edit it withheld. This is the half that would
        // break if the window frame had (wrongly) remembered the key.
        _ = try frame(loupe, url: url, state: .fit, edit: brighter(1))
        drain()
        XCTAssertNil(loupe.lastHistogramError, "a publish answers the mark")
        XCTAssertEqual(loupe.histogramRefreshCount, refreshBefore + 1)
        let atFit = try XCTUnwrap(loupe.lastHistogram)
        XCTAssertNotEqual(atFit.binsDigest(), whole.binsDigest(),
                          "the withheld edit must be measured once the whole picture is on screen")

        print("034 window: 1:1 frame marked \"\(windowMark ?? "—")\" · "
              + "measurements \(refreshBefore) → \(loupe.histogramRefreshCount) after returning to fit")
    }

    // MARK: - ④ A → B → A is two measurements

    /// The cache is still keyed by `Histogram.cacheKey`, so sliding a slider back to where it was must
    /// publish the numbers it already has instead of measuring them again.
    func testReturningToAPreviousEditHitsTheCache() throws {
        let url = try rawFixture()
        let loupe = makeController()

        _ = try frame(loupe, url: url, state: .fit, edit: .neutral)
        let first = try XCTUnwrap(loupe.lastHistogram)
        let a = first.binsDigest()
        let refreshAfterA = loupe.histogramRefreshCount
        let publishAfterA = loupe.histogramPublishCount

        _ = try frame(loupe, url: url, state: .fit, edit: brighter(1))
        let b = try XCTUnwrap(loupe.lastHistogram).binsDigest()
        XCTAssertNotEqual(b, a, "B is a different document")
        XCTAssertEqual(loupe.histogramRefreshCount, refreshAfterA + 1)
        XCTAssertEqual(loupe.histogramPublishCount, publishAfterA + 1)

        // Back to A: same picture, same key.
        _ = try frame(loupe, url: url, state: .fit, edit: .neutral)
        drain()
        XCTAssertEqual(try XCTUnwrap(loupe.lastHistogram).binsDigest(), a,
                       "the card is showing A again")
        XCTAssertEqual(loupe.histogramRefreshCount, refreshAfterA + 1,
                       "the third frame must be a cache hit, not a third measurement")
        XCTAssertEqual(loupe.histogramPublishCount, publishAfterA + 2,
                       "but it does publish: the card came back to A")

        print("034 cache: A → B → A = \(loupe.histogramRefreshCount) measurements, "
              + "\(loupe.histogramPublishCount) publishes")
    }

    // MARK: - the measurement itself is of the picture (005, unchanged)

    /// The measurement `--ui-smoke` asserts on: the viewport the camera is showing is not in it.
    func testTheMeasurementIsOfThePictureNotTheViewport() throws {
        let url = try rawFixture()
        let loupe = makeController()

        _ = try frame(loupe, url: url, state: .fit)
        let histogram = try loupe.measureHistogramNow(url: url, identity: "cadence", edit: .neutral)

        XCTAssertGreaterThanOrEqual(loupe.histogramPublishCount, 1)
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

    // MARK: - the shipped queue path: the card follows the edit, not the camera

    func testTheCardFollowsTheEditAndNotTheCamera() throws {
        let url = try rawFixture()
        let loupe = makeController(autoRender: true)
        loupe.frameSource = LoupeController.FrameSource(url: url, identity: "cadence",
                                                        viewport: Self.viewport, state: .fit)
        loupe.scheduleRender()
        XCTAssertTrue(waitFor(Self.openDeadline) { loupe.lastHistogram != nil },
                      "opening a photo must produce a measurement")
        // Not "sleep until it feels done": wait until the card has its numbers **and** the loupe has
        // nothing in flight. A count read mid-frame is a sample, not an answer.
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

        // The edit — at fit, because at 1:1 the frame is a window and a window frame never publishes
        // (that is `testAWindowFramePublishesNothingAndMarksIt`'s claim; here the camera comes back to
        // the whole picture and the edit is measured on the frame that shows it). One edit is one
        // measurement, on the frame that changed the picture: no debounce, so the plot lands with the
        // pixels instead of 120 ms after them.
        loupe.frameSource = LoupeController.FrameSource(url: url, identity: "cadence",
                                                        viewport: Self.viewport,
                                                        state: .fit,
                                                        edit: brighter(1))
        loupe.requestViewportRender()
        XCTAssertTrue(waitFor(Self.settleDeadline) { loupe.histogramPublishCount > publishedOnOpen },
                      "the edit was never measured")
        settle(loupe)
        if benchmarks {
            // A budget, and only a bench build may judge one. It used to be 400 ms because it included
            // the 120 ms debounce plus an 11 ms second render; the measurement now rides the frame, so
            // 120 ms is the frame-time budget and nothing else.
            XCTAssertLessThanOrEqual(loupe.lastHistogramLatency, 120,
                                     "the card must follow the frame the edit drew, not settle later")
        }
        XCTAssertEqual(loupe.histogramPublishCount - publishedOnOpen, 1,
                       "one edit is one measurement")
        let edited = try XCTUnwrap(loupe.lastHistogram)
        XCTAssertNotEqual(edited.binsDigest(), firstHistogram.binsDigest(),
                          "a brighter document is a different distribution")
        // And the numbers are of the *picture*: whole canvas, whole roi, the same invariants the
        // synchronous path asserts — no viewport in them, whatever rung the ladder had resident.
        XCTAssertNotEqual(edited.canvas, Self.viewport)
        XCTAssertEqual(edited.roi, ImageRect(x: 0, y: 0, width: edited.canvas.width,
                                             height: edited.canvas.height),
                       "the measurement covers the whole picture, not the window")

        print(String(format: "034 cadence: %d frames skipped, %d measurements · edit→card %.1f ms "
                     + "· measurement %.1f ms · %d publishes",
                     loupe.histogramSkippedFrames, loupe.histogramRefreshCount,
                     loupe.lastHistogramLatency, loupe.lastHistogramMilliseconds,
                     loupe.histogramPublishCount))
    }

    // MARK: - ⑤ the pan frames pay nothing for the card

    /// Twenty 1:1 pans, the card on and off, interleaved so drift cannot favour either side. A pan
    /// cannot change the picture's key, so there is nothing for the card to cost a frame: **Δp50 and
    /// Δp95 ≤ 1.5 ms** in a bench build.
    ///
    /// The number is *recorded* here and asserted only under `PHOTONS_BENCH=1`: a debug build on a
    /// loaded machine cannot judge a frame budget, and a test that does is a test that goes red for
    /// reasons that have nothing to do with the product. The structural half — the frames measured
    /// nothing at all, card on or off — is asserted every run, and it is the claim that matters.
    func testPanFramesCostNothingForTheCard() throws {
        let url = try rawFixture()
        let loupe = makeController()
        // Warm: the graph, the ladder, the pool, and one measurement (so no key is new).
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
        print(String(format: "034 1:1 pan, 20 frames, card on vs off: off p50 %.2f / p95 %.2f ms · "
                        + "on p50 %.2f / p95 %.2f ms · Δp50 %+.2f / Δp95 %+.2f ms",
                     offP50, offP95, onP50, onP95, onP50 - offP50, onP95 - offP95))

        // The structural claim: forty frames, forty non-measurements, and the card's numbers did not
        // move — with the card on *and* off. No clock in it.
        XCTAssertEqual(loupe.histogramSkippedFrames - framesBefore, 40,
                       "every pan frame must have published nothing — on and off alike")
        XCTAssertEqual(loupe.histogramRefreshCount, measurementsBefore,
                       "a pan may not run a measurement, whether the card is on or off")
        if benchmarks {
            XCTAssertLessThanOrEqual(onP50 - offP50, 1.5, "Δp50 must fit in 1.5 ms")
            XCTAssertLessThanOrEqual(onP95 - offP95, 1.5, "Δp95 must fit in 1.5 ms")
        }
    }
}
