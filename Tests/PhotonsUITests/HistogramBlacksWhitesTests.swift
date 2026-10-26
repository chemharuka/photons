import XCTest
import CoreGraphics
import Metal
import PhotonsCore
import PhotonsUI

/// 045 — 「拖动黑色/白色 后 直方图就不更新了」, end to end.
///
/// Two scenarios, because the owner's report is true in one of them and the two need different
/// evidence:
///
///   · **fit** — the frame *is* the picture, so 034 already measures it on every frame it draws. The
///     tests below pin that a `blacks` / `whites` drag publishes on every tick, so a regression in
///     `Histogram.editDigest` (a `LightGroup` field the hand-written `encode` forgot) or in
///     `changedStages` cannot hide behind the zoomed half of this file;
///   · **1:1 / 400 %** — the frame is a **crop** of the picture, so 034 answered it with "publish
///     nothing" and the plot stood still for the whole drag. Since 045 such a frame arms one
///     **background** measurement of the whole picture: the injected low-res base when it is current
///     (`fullPictureSource`, ≈1 ms), otherwise `RenderGraph.measureHistogram` (11–24 ms). The plot
///     therefore follows the edit at any zoom, one measurement late, without a frame waiting for it.
///
/// What is pinned here, in the words of the acceptance:
///
///   ① a fit drag of five `blacks` and five `whites` values publishes **ten** times, and the card ends
///      on the last tick's numbers;
///   ② the same ten values at 1:1 publish **ten** times too, and every one of them is the whole
///      picture's numbers — bit-for-bit what `measureHistogramNow` measures for that document (the
///      new path *is* a whole-picture measurement, so this is an identity, not a tolerance);
///   ③ the frame that arms it pays nothing: no measurement inside the frame, and (bench builds only)
///      no measurable difference against a frame drawn with the card switched off;
///   ④ a pure pan at 1:1 still publishes nothing and measures nothing;
///   ⑤ the injected base is read only when its digest **is** the edit's — an older base is refused,
///      the measurement falls back to a whole-picture render, and the plot never becomes the older
///      document's.
@MainActor
final class HistogramBlacksWhitesTests: XCTestCase {

    private static let viewport = ImageSize(width: 2560, height: 1600)
    private var windows: [NSWindow] = []

    /// `PHOTONS_BENCH=1` turns the millisecond budgets on, exactly as every other bench in this suite.
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

    private func makeController() -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
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

    /// A 1:1 window on the picture's centre — the camera a "look at the blacks" edit is made at.
    private func oneToOne(_ step: Int = 0) -> LoupeViewState {
        LoupeViewState(mode: .actual, zoom: 1,
                       centerX: 4760 + Double(step * 16), centerY: 3168 + Double(step * 9))
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

    private static let settleDeadline: TimeInterval = 15

    /// Wait until nothing is rendering and nothing is measuring — the numbers a counter read now are
    /// the settled answer (`histogramIsIdle` covers the background picture measurement since 045).
    private func settle(_ loupe: LoupeController, timeout: TimeInterval = settleDeadline) {
        func quiet() -> Bool { !loupe.viewportRenderInFlight && loupe.histogramIsIdle }
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

    private func drain(_ turns: Int = 3) {
        for _ in 0..<turns { pump() }
    }

    /// One frame through the shipped synchronous path. `decodeScale: 1` on purpose: the histogram is
    /// always measured from the picture's **full-scale** buffer (`histogramKey`'s rung, and
    /// `measureHistogramNow`'s), so a frame drawn from the preview rung would compare two different
    /// samples and make the digest assertions below a lie.
    @discardableResult
    private func frame(_ loupe: LoupeController, url: URL, state: LoupeViewState,
                       edit: EditModel = .neutral,
                       decodeScale: Float = 1) throws -> LoupeController.FrameResult {
        try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: decodeScale,
                            edit: edit, state: state)
    }

    /// A document whose **blacks** slider is at `value` — the owner's left-hand control.
    private func blacks(_ value: Double) -> EditModel {
        var edit = EditModel.neutral
        var light = edit.light
        light.blacks = value
        edit.light = light
        return edit
    }

    /// A document whose **whites** slider is at `value`.
    private func whites(_ value: Double) -> EditModel {
        var edit = EditModel.neutral
        var light = edit.light
        light.whites = value
        edit.light = light
        return edit
    }

    /// The five ticks of one drag: 0 → 40 in the steps a slider reports.
    private static let ticks: [Double] = [8, 16, 24, 32, 40]

    /// Where the light sits in the plot, in bins: the mean SDR bin index, weighted by count. A `blacks`
    /// or `whites` tick that brightens the picture must move this number, which is the cheap way to say
    /// "the plot followed the slider" without pinning a specific distribution.
    private func meanLevel(_ histogram: Histogram) -> Double {
        let counts = histogram.luma.bins
        let total = counts.reduce(0, +)
        guard total > 0 else { return 0 }
        let weighted = counts.indices.reduce(0.0) { $0 + Double($1) * Double(counts[$1]) }
        return weighted / Double(total)
    }

    /// The picture's rect inside a frame, the way `histogramStep` computes it for a whole-picture frame.
    private func contentRect(_ frame: LoupeController.FrameResult) -> ImageRect {
        ImageRect(x: (frame.canvas.width - frame.content.width) / 2,
                  y: (frame.canvas.height - frame.content.height) / 2,
                  width: frame.content.width, height: frame.content.height)
    }

    // MARK: - ① fit: the frame is the picture, so every tick publishes

    /// Five `blacks` values and five `whites` values at fit, one frame each: ten publishes, ten
    /// measurements, and each tick's plot is brighter than the one before. This is the half of the
    /// owner's report that 034 already answered — if it ever goes quiet, the digest or the dirty-stage
    /// calculation has stopped seeing `blacks`/`whites`, and the zoom fix would only hide it.
    func testAFitDragOfBlacksAndWhitesPublishesEveryTick() throws {
        let url = try rawFixture()
        let loupe = makeController()

        try frame(loupe, url: url, state: .fit, edit: .neutral)      // warm: graph, ladder, card
        drain()
        let publishBefore = loupe.histogramPublishCount
        let refreshBefore = loupe.histogramRefreshCount

        var publishes = 0
        var blacksLevels: [Double] = []
        var whitesLevels: [Double] = []
        var digests: [String] = []
        for value in Self.ticks {
            let before = loupe.histogramPublishCount
            try frame(loupe, url: url, state: .fit, edit: blacks(value))
            XCTAssertEqual(loupe.histogramPublishCount, before + 1,
                           "blacks \(value) at fit published nothing — the plot stopped following a "
                           + "level change the picture very much has")
            publishes += 1
            let plot = try XCTUnwrap(loupe.lastHistogram)
            blacksLevels.append(meanLevel(plot))
            digests.append(plot.binsDigest())
        }
        for value in Self.ticks {
            let before = loupe.histogramPublishCount
            try frame(loupe, url: url, state: .fit, edit: whites(value))
            XCTAssertEqual(loupe.histogramPublishCount, before + 1,
                           "whites \(value) at fit published nothing")
            publishes += 1
            let plot = try XCTUnwrap(loupe.lastHistogram)
            whitesLevels.append(meanLevel(plot))
            digests.append(plot.binsDigest())
        }
        drain()

        XCTAssertEqual(publishes, 10, "ten ticks, ten publishes")
        XCTAssertEqual(loupe.histogramPublishCount - publishBefore, 10)
        XCTAssertEqual(loupe.histogramRefreshCount - refreshBefore, 10,
                       "each tick is a new picture and a fit frame measures it on the frame")
        XCTAssertEqual(Set(digests).count, 10, "every tick published its own numbers")
        // Each drag starts from a neutral document, so the two runs are compared with each other, not
        // across the reset.
        for (name, levels) in [("blacks", blacksLevels), ("whites", whitesLevels)] {
            XCTAssertEqual(levels, levels.sorted(),
                           "\(name) levels up is a brighter picture: the plot must move that way, tick "
                           + "after tick — levels \(levels.map { String(format: "%.1f", $0) })")
        }
        XCTAssertNil(loupe.lastHistogramError)

        // The numbers on the card are the picture's, not the viewport's, and they are this build's
        // per-frame grid (256 on the long edge — 034's measurement, which is why its digest is not the
        // 1024-grid digest `measureHistogramNow` returns; ② owns that identity).
        let plot = try XCTUnwrap(loupe.lastHistogram)
        XCTAssertEqual(plot.roi, ImageRect(x: 0, y: 0, width: plot.canvas.width,
                                          height: plot.canvas.height))
        XCTAssertEqual(plot.sampleSize, Histogram.frameSampleSize(for: plot.roi))
        XCTAssertNotEqual(plot.canvas, Self.viewport)

        // And the last tick's numbers are what the card still has after a full settle: 045's
        // background path must not run behind a fit frame and rewrite them.
        settle(loupe)
        XCTAssertEqual(loupe.lastHistogram?.binsDigest(), digests[9])

        print("045 fit: \(publishes) ticks → \(loupe.histogramRefreshCount - refreshBefore) "
              + "measurements / \(loupe.histogramPublishCount - publishBefore) publishes · "
              + "luma mean level blacks "
              + blacksLevels.map { String(format: "%.1f", $0) }.joined(separator: "→")
              + " · whites "
              + whitesLevels.map { String(format: "%.1f", $0) }.joined(separator: "→"))
    }

    // MARK: - ② 1:1: the picture is measured in the background, every tick

    /// One 1:1 frame of `edit`, then wait for the background measurement to reach the card. Returns the
    /// numbers it published and how long the round trip took.
    ///
    /// The frame itself is asserted to publish **nothing**: it is a crop, and a crop's bins are the
    /// crop's. What follows it is a measurement of the *picture*, which is why the wait is on a counter
    /// and not on a clock.
    private func zoomedTick(_ loupe: LoupeController, url: URL, edit: EditModel) throws
        -> (histogram: Histogram, milliseconds: Double) {
        let published = loupe.histogramPublishCount
        let refreshed = loupe.histogramRefreshCount
        let before = CFAbsoluteTimeGetCurrent()
        try frame(loupe, url: url, state: oneToOne(), edit: edit)
        XCTAssertEqual(loupe.histogramPublishCount, published,
                       "a window frame must not publish its own pixels — it is a crop of the picture")
        XCTAssertEqual(loupe.histogramRefreshCount, refreshed,
                       "…and must not measure them either: it arms the picture's measurement")
        XCTAssertTrue(waitFor { loupe.histogramPublishCount > published },
                      "the zoomed edit never reached the card: the plot stands still while the "
                      + "picture changes (the 045 report)")
        let histogram = try XCTUnwrap(loupe.lastHistogram)
        return (histogram, (CFAbsoluteTimeGetCurrent() - before) * 1000)
    }

    /// The bug itself: five `blacks` and five `whites` ticks at 1:1, each one measured and published,
    /// each one the **whole picture's** numbers.
    ///
    /// The identity asserted is exact: the new path measures the picture the way `measureHistogramNow`
    /// does (same rung, same 1024-long-edge sample, same bins), so a difference here would mean the
    /// background measurement had drifted from the shipped whole-picture reading.
    func testAZoomedDragOfBlacksAndWhitesPublishesThePictureEveryTick() throws {
        let url = try rawFixture()
        let loupe = makeController()

        try frame(loupe, url: url, state: .fit, edit: .neutral)      // warm: graph, ladder, card
        settle(loupe)
        let publishBefore = loupe.histogramPublishCount
        let refreshBefore = loupe.histogramRefreshCount
        let renderBefore = loupe.pictureRenderMeasurementCount
        let armsBefore = loupe.pictureArmCount

        var latencies: [Double] = []
        var ticks = 0
        for edit in (Self.ticks.map(blacks) + Self.ticks.map(whites)) {
            let tick = try zoomedTick(loupe, url: url, edit: edit)
            latencies.append(tick.milliseconds)
            ticks += 1
            // The card now holds the picture's numbers, measured for *this* document: the same bins
            // `measureHistogramNow` reads for it. No injected base is wired here, so this is the
            // 11–24 ms fallback — the path a build without the low-res base would take.
            let expected = try loupe.measureHistogramNow(url: url, identity: url.lastPathComponent,
                                                        edit: edit)
            XCTAssertEqual(tick.histogram.binsDigest(), expected.binsDigest(),
                           "tick \(ticks): the background measurement is not the picture's "
                           + "histogram — it drifted from measureHistogramNow")
            XCTAssertEqual(tick.histogram.canvas, expected.canvas)
            XCTAssertEqual(tick.histogram.roi, expected.roi,
                           "the numbers must cover the whole picture, not the 1:1 window")
            XCTAssertEqual(tick.histogram.sampleCount, expected.sampleCount)
            XCTAssertNil(loupe.lastHistogramError)
        }
        settle(loupe)

        XCTAssertEqual(ticks, 10, "ten ticks")
        XCTAssertEqual(loupe.pictureRenderMeasurementCount - renderBefore, 10,
                       "ten zoomed edits, ten whole-picture measurements")
        XCTAssertEqual(loupe.histogramRefreshCount - refreshBefore, 10,
                       "and each one counts as a measurement of the picture")
        XCTAssertEqual(loupe.histogramPublishCount - publishBefore, 20,
                       "ten background publishes plus the ten measureHistogramNow calls above")
        XCTAssertEqual(loupe.pictureMeasurementDropCount, 0,
                       "one tick at a time: no request was superseded")
        XCTAssertEqual(loupe.pictureArmCount - armsBefore, 10,
                       "one request per zoomed edit — and none for the fit frames")

        let p50 = percentile(latencies, 0.5), p95 = percentile(latencies, 0.95)
        print(String(format: "045 1:1 drag: 10 ticks → 10 publishes of the picture · "
                     + "tick→card p50 %.1f / p95 %.1f ms · measurement %.1f ms",
                     p50, p95, loupe.lastHistogramMilliseconds))
        if benchmarks {
            // A budget, and only a bench build may judge one (as with every other bench in this suite,
            // `PHOTONS_BENCH=1` means an optimised build: a -Onone binning pass of 0.58 Mpx is ~200 ms).
            // 045's spec is "the plot lags one measurement, not a debounce" — 30 ms is that bound with
            // room for a loaded machine.
            XCTAssertLessThanOrEqual(p95, 30, "a zoomed tick must reach the card within one measurement")
        }
    }

    // MARK: - ③ the zoomed frame pays nothing for it

    /// A 1:1 frame that arms a whole-picture measurement must cost the same as a 1:1 frame with the
    /// card switched off — the measurement is on its own queue, its own graph and its own thread.
    ///
    /// The structural half is asserted every run (the frame ran **no** measurement and published
    /// nothing); the millisecond half only under `PHOTONS_BENCH=1`.
    func testAZoomedFrameIsNotSlowedDownByTheCard() throws {
        let url = try rawFixture()
        let loupe = makeController()
        try frame(loupe, url: url, state: .fit, edit: .neutral)      // warm
        settle(loupe)
        let armsBefore = loupe.pictureArmCount
        let measurementsBefore = loupe.pictureFrameMeasurementCount
            + loupe.pictureRenderMeasurementCount
        let dropsBefore = loupe.pictureMeasurementDropCount

        var offTimes: [Double] = [], onTimes: [Double] = []
        for (index, value) in Self.ticks.enumerated() {
            // Distinct documents, one per side, so neither frame is a cache hit.
            let offEdit = blacks(-value)
            let onEdit = blacks(value)

            loupe.collectsHistogram = false
            var t0 = CFAbsoluteTimeGetCurrent()
            try frame(loupe, url: url, state: oneToOne(index), edit: offEdit)
            offTimes.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)

            let refreshed = loupe.histogramRefreshCount
            let published = loupe.histogramPublishCount
            loupe.collectsHistogram = true
            t0 = CFAbsoluteTimeGetCurrent()
            try frame(loupe, url: url, state: oneToOne(index), edit: onEdit)
            onTimes.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            // Inside the frame: nothing was measured and nothing was published — the measurement is
            // armed, not run.
            XCTAssertEqual(loupe.histogramRefreshCount, refreshed,
                           "the frame measured the histogram itself — it must only arm it")
            XCTAssertEqual(loupe.histogramPublishCount, published,
                           "a window frame published inside the frame; it must publish nothing")
        }
        settle(loupe)

        let offP50 = percentile(offTimes, 0.5), offP95 = percentile(offTimes, 0.95)
        let onP50 = percentile(onTimes, 0.5), onP95 = percentile(onTimes, 0.95)
        print(String(format: "045 1:1 frame, card on vs off: off p50 %.2f / p95 %.2f ms · "
                     + "on p50 %.2f / p95 %.2f ms · Δp50 %+.2f / Δp95 %+.2f ms",
                     offP50, offP95, onP50, onP95, onP50 - offP50, onP95 - offP95))
        // The zoomed edits all reached the card's *pipeline*: every card-on frame armed one request, and
        // the coalescing rule (one pending slot, newest wins) folded part of the burst into fewer
        // measurements — that is the "编辑再变就取消/替换上一次" half of 045, not a failure. Every request
        // is accounted for, and no request queued behind another.
        let arms = loupe.pictureArmCount - armsBefore
        let measured = (loupe.pictureFrameMeasurementCount + loupe.pictureRenderMeasurementCount)
            - measurementsBefore
        let cancelled = loupe.pictureMeasurementDropCount - dropsBefore
        let stale = loupe.pictureStaleOutcomeCount
        XCTAssertEqual(arms, 5, "one request per card-on frame")
        XCTAssertEqual(arms, measured + cancelled,
                       "every request either measured or was replaced in the pending slot — one "
                       + "measurement at a time, no queue")
        XCTAssertGreaterThanOrEqual(measured, 1,
                                    "the card-on frames armed nothing — this test would prove nothing")
        XCTAssertLessThanOrEqual(stale, measured,
                                 "more outcomes were discarded than were measured")
        XCTAssertNil(loupe.lastHistogramError)

        // And the burst settles on the newest edit, not on whichever measurement happened to win.
        let newest = try loupe.measureHistogramNow(url: url, identity: url.lastPathComponent,
                                                   edit: blacks(Self.ticks.last ?? 0))
        XCTAssertEqual(loupe.lastHistogram?.binsDigest(), newest.binsDigest(),
                       "the plot is not showing the last tick of the drag")
        print("045 1:1 burst: \(arms) requests → \(measured) measurements, \(cancelled) cancelled, "
              + "\(stale) discarded")
        if benchmarks {
            XCTAssertLessThanOrEqual(onP50 - offP50, 4.0,
                                     "a zoomed frame may not pay for the picture's measurement")
            // The tail is GPU contention with the background render (the injected base removes it
            // entirely), not the frame waiting: `histogramRefreshCount`/`histogramPublishCount` are
            // asserted unchanged around every frame above, which is the deterministic claim.
            XCTAssertLessThanOrEqual(onP95 - offP95, 30.0,
                                     "…and the tail may not turn into a stall")
        }
    }

    // MARK: - ④ an injected base is read only when it is this edit's

    /// The injected low-res full-picture base (037/039) makes the zoomed measurement ≈1 ms. A base
    /// rendered for **this** document is read on every tick; the numbers that reach the card are then
    /// the base's own sample — 256 on the long edge — rather than the 1024-grid render.
    func testAZoomedEditMeasuresTheInjectedFullPictureBase() throws {
        let url = try rawFixture()
        let loupe = makeController()
        try frame(loupe, url: url, state: .fit, edit: .neutral)      // warm
        settle(loupe)

        let frameBefore = loupe.pictureFrameMeasurementCount
        let renderBefore = loupe.pictureRenderMeasurementCount
        let box = BaseBox()
        loupe.fullPictureSource = { box.offer($0) }

        var publishes = 0
        var lastEdit = EditModel.neutral
        var lastPlot: Histogram?
        for value in Self.ticks {
            let edit = blacks(value)
            lastEdit = edit
            // The base: the whole picture, rendered with the *same* document. The card is switched off
            // for it, so producing a base is not an edit frame and measures nothing.
            loupe.collectsHistogram = false
            let base = try frame(loupe, url: url, state: .fit, edit: edit)
            loupe.collectsHistogram = true
            let content = contentRect(base)
            box.add(base.texture, content: content, digest: Histogram.editDigest(edit))

            let published = loupe.histogramPublishCount
            try frame(loupe, url: url, state: oneToOne(), edit: edit)
            XCTAssertTrue(waitFor { loupe.histogramPublishCount > published },
                          "the injected base was never measured: black \(value) never reached "
                          + "the card")
            let plot = try XCTUnwrap(loupe.lastHistogram)
            // The tell that the base was read: the sample grid is the *frame* grid (256 over the
            // picture's rect inside the base), not the whole-picture render's 1024.
            XCTAssertEqual(plot.sampleSize, Histogram.frameSampleSize(for: content),
                           "the card's numbers are not the injected base's sample")
            XCTAssertEqual(plot.roi, ImageRect(x: 0, y: 0, width: plot.canvas.width,
                                              height: plot.canvas.height))
            XCTAssertGreaterThan(plot.canvas.width, 0)
            lastPlot = plot
            publishes += 1
        }
        settle(loupe)

        XCTAssertEqual(publishes, 5)
        XCTAssertEqual(loupe.pictureFrameMeasurementCount - frameBefore, 5,
                       "five ticks with a current base: five ≈1 ms measurements, no render")
        XCTAssertEqual(loupe.pictureRenderMeasurementCount - renderBefore, 0,
                       "nothing had to render the picture — the base was current every time")
        XCTAssertEqual(box.askedDigests.count, 5,
                       "the base was asked for once per zoomed edit")
        XCTAssertTrue(box.askedDigests.allSatisfy(box.knownDigests.contains),
                      "and always for the edit being measured, never for an older one")

        // The same document measured the shipped way labels the same picture and samples a finer grid:
        // 256 (a frame sample) here, 1024 (`measureHistogramNow`) there. The plot is read *before* that
        // call, because `measureHistogramNow` publishes too — it is a reference reading, not the card.
        let base = try XCTUnwrap(lastPlot)
        let reference = try loupe.measureHistogramNow(url: url, identity: url.lastPathComponent,
                                                      edit: lastEdit)
        XCTAssertEqual(base.canvas, reference.canvas,
                       "the base's measurement must be labelled with the picture's own grid")
        XCTAssertNotEqual(base.sampleSize, reference.sampleSize,
                          "the card's numbers came from the base's frame sample, not from a render")
        XCTAssertEqual(base.sampleSize.width, Histogram.frameSampleLongEdge,
                       "the base is sampled at 256 on the long edge, as 027's frame pass does")

        print("045 injected base: \(publishes) ticks → "
              + "\(loupe.pictureFrameMeasurementCount - frameBefore) frame measurements · last "
              + String(format: "%.2f", loupe.lastHistogramMilliseconds) + " ms")
    }

    /// The contract that makes the base safe to hand over: a base rendered for **another** document —
    /// the state a stale backdrop is in — is refused. The measurement falls back to a whole-picture
    /// render of the edit being asked about, and the plot is that edit's, not the base's.
    func testAnInjectedBaseOfAnOlderEditIsRefused() throws {
        let url = try rawFixture()
        let loupe = makeController()
        try frame(loupe, url: url, state: .fit, edit: .neutral)
        settle(loupe)
        let frameBefore = loupe.pictureFrameMeasurementCount
        let renderBefore = loupe.pictureRenderMeasurementCount

        // A base of a different document: +2 EV, which the plot would show instantly if it were read.
        var brighter = EditModel.neutral
        var light = brighter.light
        light.exposure += 2
        brighter.light = light
        loupe.collectsHistogram = false
        let stale = try frame(loupe, url: url, state: .fit, edit: brighter)
        loupe.collectsHistogram = true
        let staleDigest = Histogram.editDigest(brighter)
        let staleContent = contentRect(stale)
        let offers = Counter()

        loupe.fullPictureSource = { _ in
            offers.bump()
            // An honest digest — of the *older* edit. This is exactly what a stale backdrop returns,
            // and the controller must not measure it for the edit it is asked about.
            return (stale.texture, staleContent, staleDigest)
        }

        let edit = blacks(40)
        let tick = try zoomedTick(loupe, url: url, edit: edit)
        settle(loupe)

        XCTAssertEqual(offers.value, 1, "the base was offered for this measurement")
        XCTAssertEqual(loupe.pictureFrameMeasurementCount - frameBefore, 0,
                       "a base of another document was measured — the plot would be the wrong "
                       + "picture")
        XCTAssertEqual(loupe.pictureRenderMeasurementCount - renderBefore, 1,
                       "a mismatched base must fall back to a whole-picture render of *this* edit")

        let expected = try loupe.measureHistogramNow(url: url, identity: url.lastPathComponent,
                                                     edit: edit)
        XCTAssertEqual(tick.histogram.binsDigest(), expected.binsDigest(),
                       "the numbers on the card are not the edit's picture")
        let staleNumbers = try loupe.measureHistogramNow(url: url, identity: url.lastPathComponent,
                                                         edit: brighter)
        XCTAssertNotEqual(tick.histogram.binsDigest(), staleNumbers.binsDigest(),
                          "the card is showing the stale base's document")
        print("045 stale base: \(offers.value) offer refused · the fallback measured the picture in "
              + String(format: "%.1f", loupe.lastHistogramMilliseconds) + " ms")
    }

    // MARK: - ⑤ a pan is still free

    /// Twenty 1:1 pans with the same document: the picture's key does not move, so nothing is armed,
    /// nothing is measured and nothing is published. 045 must not turn a pan into a measurement.
    func testAPanAtOneToOneStillPublishesNothing() throws {
        let url = try rawFixture()
        let loupe = makeController()
        try frame(loupe, url: url, state: .fit, edit: .neutral)
        let edit = blacks(24)
        _ = try zoomedTick(loupe, url: url, edit: edit)          // the edit lands first
        settle(loupe)

        let published = loupe.histogramPublishCount
        let refreshed = loupe.histogramRefreshCount
        let frameUses = loupe.pictureFrameMeasurementCount
        let renderUses = loupe.pictureRenderMeasurementCount
        let arms = loupe.pictureArmCount
        let skipped = loupe.histogramSkippedFrames
        let atEdit = try XCTUnwrap(loupe.lastHistogram)

        for step in 1...20 {
            try frame(loupe, url: url, state: oneToOne(step), edit: edit)
        }
        settle(loupe)

        XCTAssertEqual(loupe.histogramSkippedFrames - skipped, 20,
                       "twenty pan frames, twenty non-publishers")
        XCTAssertEqual(loupe.histogramPublishCount, published, "a pan may not publish")
        XCTAssertEqual(loupe.histogramRefreshCount, refreshed, "and may not measure")
        XCTAssertEqual(loupe.pictureFrameMeasurementCount, frameUses,
                       "a pan may not ask the base for the picture either")
        XCTAssertEqual(loupe.pictureRenderMeasurementCount, renderUses)
        XCTAssertEqual(loupe.pictureArmCount, arms,
                       "a pan armed a picture measurement — twenty pans would be twenty measurements")
        XCTAssertEqual(loupe.lastHistogram, atEdit, "the card keeps the picture's numbers")
        XCTAssertNil(loupe.lastHistogramError)
        print("045 1:1 pan: 20 frames → 0 publishes · "
              + "\(loupe.histogramSkippedFrames - skipped) skipped")
    }

    // MARK: - helpers

    private func percentile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }

    /// A box the background measurement can write to. `fullPictureSource` is called on the measurement
    /// queue, so a plain array in the test would be a data race on the very wiring under test.
    private final class BaseBox {
        private let lock = NSLock()
        private var bases: [(texture: MTLTexture, content: ImageRect, digest: String)] = []
        private var asks: [String] = []

        /// The closure's body: record what was asked for, answer with the newest base of that document.
        func offer(_ edit: EditModel) -> (texture: MTLTexture, content: ImageRect, digest: String)? {
            let digest = Histogram.editDigest(edit)
            lock.lock()
            defer { lock.unlock() }
            asks.append(digest)
            return bases.last { $0.digest == digest }
        }

        func add(_ texture: MTLTexture, content: ImageRect, digest: String) {
            lock.lock()
            defer { lock.unlock() }
            bases.append((texture, content, digest))
        }

        var askedDigests: [String] {
            lock.lock()
            defer { lock.unlock() }
            return asks
        }

        var knownDigests: [String] {
            lock.lock()
            defer { lock.unlock() }
            return bases.map(\.digest)
        }
    }

    /// A counter a background closure may bump.
    private final class Counter {
        private let lock = NSLock()
        private var count = 0
        func bump() {
            lock.lock()
            count += 1
            lock.unlock()
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
}
