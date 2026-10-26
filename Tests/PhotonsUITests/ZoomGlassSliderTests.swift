import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// The canvas' zoom control, as geometry *and* as behaviour.
///
/// The rules under test, all of them the user's:
///
///   · **the thumb can only come to rest on a rung** — `ZoomGlassSliderGeometry` maps an index to an
///     x, the view's position state for a drag is an `Int`, and `ZoomGlassSlider.select(index:)` is
///     the single place a value leaves the control (`testDragFromLeftToRightEmitsAtMostSeven…`).
///   · **适应 is on the chip, not on the ladder** — the left glass pill reads 适应 in fit and the
///     current rung otherwise, and clicking it is the pointer's way *into* fit. The thumb is then
///     drawn at the fit ratio's continuous, log-interpolated position — a display, not a stop: the
///     first pointer event on the track snaps back onto 25–400 %
///     (`testFitChipAndContinuousThumb`, `testOnePointDragFromFitDropsOntoTheLadder`).
///   · **the slider zooms around the canvas centre**, while ⌘= / ⌘− / the menu / the wheel / the
///     pinch keep their cursor anchor (`testSliderZoomsAroundTheCentreWhileTheCursorPathDoesNot`).
///
/// No Metal and no RAW fixtures except in the one anchor test, which needs a real framing.
@MainActor
final class ZoomGlassSliderTests: XCTestCase {

    private let stops: [Double] = [0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1, 2, 3, 4]
    private let labels = ["25%", "33.3%", "50%", "66.7%", "100%", "200%", "300%", "400%"]
    private let viewport = ImageSize(width: 2560, height: 1600)
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    /// A laid-out control, no window. `layout()` is called explicitly: the frame of the track is
    /// what the pointer helpers measure against, and an offscreen view has no layout pass of its own.
    private func makeSlider() -> ZoomGlassSlider {
        let slider = ZoomGlassSlider(frame: NSRect(x: 0, y: 0, width: 210, height: 30))
        slider.layout()
        return slider
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitFor(_ timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func rawFixture() throws -> URL {
        for c in [ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
                  NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath]
            .compactMap({ $0 }) where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    // MARK: - 1. geometry

    /// Eight ticks, evenly spaced **by index** — `25 → 400 %` over seven equal gaps, not a linear
    /// scale of the ratios (which would put 200 % twice as far from 100 % as 100 % is from 50 %).
    func testTicksAreEvenlySpacedByIndex() {
        let g = ZoomGlassSliderGeometry()
        XCTAssertEqual(g.levels, stops, "the ladder is the controller's eight exact stops")
        XCTAssertEqual(g.lastIndex, 7)
        XCTAssertEqual(g.edges.count, 8)
        // `[适应 54] [gap 8] [track 148]` → 10 pt of air at each end → 128 pt of travel.
        XCTAssertEqual(g.width, 148, accuracy: 1e-9)
        XCTAssertEqual(g.usableWidth, 128, accuracy: 1e-9)
        XCTAssertEqual(g.x(forIndex: 0), 10, accuracy: 1e-9)
        XCTAssertEqual(g.x(forIndex: 7), 138, accuracy: 1e-9)
        for index in 1...7 {
            XCTAssertEqual(g.x(forIndex: index) - g.x(forIndex: index - 1), 128.0 / 7.0,
                           accuracy: 1e-9, "every gap is one step")
        }
        // Eight rungs and nothing after them: the track ends past 400 %, it does not continue to fit.
        XCTAssertEqual(g.edges.first, g.x(forIndex: 0))
        XCTAssertEqual(g.edges.last, g.x(forIndex: 7))
    }

    /// `x(forIndex:)` and `index(forX:)` are inverse, including at both clamps.
    func testXAndIndexRoundTripIncludingClamps() {
        let g = ZoomGlassSliderGeometry()
        for index in 0...7 {
            XCTAssertEqual(g.index(forX: g.x(forIndex: index)), index,
                           "x → index must return the tick it came from (\(index))")
        }
        XCTAssertEqual(g.index(forX: -10_000), 0, "left of the track clamps to 25 %, never to fit")
        XCTAssertEqual(g.index(forX: 10_000), 7, "right of the track clamps to 400 %")
        // And the x side clamps too, so `point(forIndex:)` cannot be handed an out-of-range index.
        XCTAssertEqual(g.x(forIndex: -3), g.x(forIndex: 0))
        XCTAssertEqual(g.x(forIndex: 99), g.x(forIndex: 7))
    }

    /// Halfway between two ticks is a tie, and the tie goes to the **lower** index: the thumb does
    /// not move until the pointer has passed the midpoint (and a click dead-centre reads as the
    /// rung you are already on, not as the next one).
    func testTieBreaksToTheLowerIndex() {
        let g = ZoomGlassSliderGeometry()
        for lower in 0..<7 {
            let mid = (g.x(forIndex: lower) + g.x(forIndex: lower + 1)) / 2
            XCTAssertEqual(g.index(forX: mid), lower,
                           "the midpoint between \(lower) and \(lower + 1) is a tie → lower index")
            // A hair to the right of the midpoint is the next rung.
            XCTAssertEqual(g.index(forX: mid + 0.01), lower + 1)
        }
        // The same rule for a ratio tie: 1.5 is equidistant from 100 % and 200 %.
        XCTAssertEqual(g.nearestIndex(forZoom: 1.5), 4)
    }

    /// A degenerate track (1 pt wide, or NaN) must not crash and must still be monotone: a view can
    /// be laid out at zero size during window construction, and a NaN there would poison the thumb.
    func testDegenerateWidthsDoNotCrashAndEdgesStayMonotone() {
        for width in [CGFloat(1), CGFloat(0), CGFloat(-40), CGFloat.nan, CGFloat.infinity] {
            let g = ZoomGlassSliderGeometry(width: width)
            let edges = g.edges
            XCTAssertEqual(edges.count, 8)
            for edge in edges {
                XCTAssertTrue(edge.isFinite, "width \(width) produced a non-finite edge")
            }
            for (a, b) in zip(edges, edges.dropFirst()) {
                XCTAssertLessThanOrEqual(a, b, "width \(width) put the ticks out of order")
            }
            for index in 0...7 {
                XCTAssertTrue((0...7).contains(g.index(forX: g.x(forIndex: index))),
                              "width \(width) produced an out-of-range index")
            }
            XCTAssertEqual(g.index(forX: .nan), 0)
            // The fit display must survive it too, and stay inside the track.
            let fitX = g.fitThumbCenter(forZoom: 0.31)
            XCTAssertTrue(fitX.isFinite, "width \(width) produced a non-finite fit position")
            XCTAssertGreaterThanOrEqual(fitX, min(g.thumbLeftLimit, g.thumbRightLimit))
            XCTAssertLessThanOrEqual(fitX, max(g.thumbLeftLimit, g.thumbRightLimit))
        }
    }

    /// A numeric zoom that is not exactly on the table (a pinch, a bridge ratio) snaps to the
    /// nearest rung — the thirds at their exact values (`1.0/3.0`, not 0.333).
    func testAnOffTableNumericZoomSnapsToTheNearestRung() {
        let g = ZoomGlassSliderGeometry()
        XCTAssertEqual(g.nearestIndex(forZoom: 0.26), 0)          // 25 %
        XCTAssertEqual(g.nearestIndex(forZoom: 0.31), 1)          // 33.3 %
        XCTAssertEqual(g.nearestIndex(forZoom: 0.45), 2)          // 50 %
        XCTAssertEqual(g.nearestIndex(forZoom: 0.66), 3)          // 66.7 %
        XCTAssertEqual(g.nearestIndex(forZoom: 0.72), 3)          // 66.7 % again
        XCTAssertEqual(g.nearestIndex(forZoom: 3.9), 7)           // 400 %
        XCTAssertEqual(g.nearestIndex(forZoom: .nan), 4)          // a NaN ratio reads as 1:1 → 100 %
        XCTAssertEqual(g.levels[g.nearestIndex(forZoom: 1.0 / 3.0)], 1.0 / 3.0)
    }

    /// The fit display: log interpolation between the two rungs the ratio sits between, and the
    /// track's **ends** (not the first/last rung) outside 25–400 %.
    func testFitDisplayIsLogInterpolatedAndClampsToTheTrackEnds() {
        let g = ZoomGlassSliderGeometry()
        XCTAssertEqual(g.thumbLeftLimit, 7, accuracy: 1e-9, "half a thumb in from the left edge")
        XCTAssertEqual(g.thumbRightLimit, 141, accuracy: 1e-9)

        // 18 % is below the ladder: the thumb's left edge is the track's left edge.
        XCTAssertEqual(g.fitThumbCenter(forZoom: 0.18), g.thumbLeftLimit, accuracy: 1e-12)
        // 620 % is above it: the right end.
        XCTAssertEqual(g.fitThumbCenter(forZoom: 6.2), g.thumbRightLimit, accuracy: 1e-12)
        // Ends, not rungs — the ends are outside the first/last tick.
        XCTAssertLessThan(g.thumbLeftLimit, g.x(forIndex: 0))
        XCTAssertGreaterThan(g.thumbRightLimit, g.x(forIndex: 7))

        // 31 % sits between 25 % and 33.3 %: strictly inside the first gap, at the log position.
        let x = g.fitThumbCenter(forZoom: 0.31)
        XCTAssertGreaterThan(x, g.x(forIndex: 0))
        XCTAssertLessThan(x, g.x(forIndex: 1))
        let t = log(0.31 / 0.25) / log((1.0 / 3.0) / 0.25)
        let expected = g.x(forIndex: 0) + CGFloat(t) * (g.x(forIndex: 1) - g.x(forIndex: 0))
        XCTAssertEqual(x, expected, accuracy: 0.01)
        XCTAssertEqual(x, 23.67, accuracy: 0.5, "log-interpolated, not linear in the ratio")

        // The log rule is measurable inside a gap whose ratios spread: 150 % sits at
        // log(1.5)/log(2) = 58.5 % of the 100 %→200 % gap, ~1.6 pt right of its linear midpoint.
        let mid = g.fitThumbCenter(forZoom: 1.5)
        XCTAssertGreaterThan(mid, g.x(forIndex: 4))
        XCTAssertLessThan(mid, g.x(forIndex: 5))
        let t15 = log(1.5) / log(2.0)
        XCTAssertEqual(mid, g.x(forIndex: 4) + CGFloat(t15) * (g.x(forIndex: 5) - g.x(forIndex: 4)),
                       accuracy: 0.01)
        let linearMid = g.x(forIndex: 4) + 0.5 * (g.x(forIndex: 5) - g.x(forIndex: 4))
        XCTAssertGreaterThan(mid - linearMid, 1.0, "log, not linear in the ratio")
    }

    // MARK: - 2. the control's furniture

    /// `[适应 54] [8] [track 148]` on one 30 pt row, both pills on the same baseline.
    func testTheControlIsAChipAndATrackOnOneRow() {
        let slider = makeSlider()
        XCTAssertEqual(slider.frame.size, CGSize(width: 210, height: 30))
        XCTAssertEqual(slider.geometry.edges.count, 8)
        XCTAssertEqual(slider.chipFrame, CGRect(x: 0, y: 0, width: 54, height: 30))
        XCTAssertEqual(slider.trackFrame.minX, 62, accuracy: 0.01, "chip + 8 pt gap")
        XCTAssertEqual(slider.trackFrame.width, 148, accuracy: 0.01)
        XCTAssertEqual(slider.trackFrame.height, 30, accuracy: 0.01)
        XCTAssertEqual(slider.chipLabelFrame.width, 38, accuracy: 0.01)
        XCTAssertEqual(slider.geometry.levels, stops)
        XCTAssertEqual(slider.geometry.levels.map { LoupeViewState.percentLabel(of: $0) }, labels)
        // The two paths, and which one this machine is on (macOS 26+ ships the glass one).
        XCTAssertTrue(slider.backdropKind == .glass || slider.backdropKind == .visualEffect)
    }

    /// **The drag test.** Left tick to right tick in 120 small steps: the emit list must be ≤ 7
    /// long, every value in it a table value, no repeats, and the thumb on a tick after every single
    /// event — never once between two.
    func testDragFromLeftToRightEmitsAtMostSevenValuesAllOnTheLadder() {
        let slider = makeSlider()
        var emitted: [Double] = []
        slider.onZoom = { emitted.append($0) }
        slider.update(zoomStop: 0.25, fitZoom: nil)
        XCTAssertEqual(emitted, [], "adopting the camera's stop is not a stop change")

        let start = slider.point(forIndex: 0)
        let end = slider.point(forIndex: 7)
        slider.pointerDown(at: start)

        var thumbXs: [CGFloat] = [slider.thumbCenterX]
        for step in 1...120 {
            let t = CGFloat(step) / 120
            slider.pointerDragged(at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y))
            thumbXs.append(slider.thumbCenterX)
        }
        // Past the end: clamped, still one rung (400 %), and no extra emission.
        slider.pointerDragged(at: CGPoint(x: end.x + 300, y: start.y))
        thumbXs.append(slider.thumbCenterX)
        slider.pointerUp()

        XCTAssertLessThanOrEqual(emitted.count, 7,
                                 "a 128 pt drag crosses seven gaps → at most seven stop changes, got \(emitted)")
        XCTAssertEqual(emitted.count, 7, "…and it does cross all seven: \(emitted)")
        for value in emitted {
            XCTAssertTrue(stops.contains { abs($0 - value) < 1e-12 },
                          "\(value) is not a rung — the control must never name an intermediate zoom")
        }
        XCTAssertEqual(emitted, Array(stops.dropFirst()), "the emitted sequence is the ladder itself")
        XCTAssertEqual(slider.currentIndex, 7)
        XCTAssertEqual(slider.thumbCenterX, slider.geometry.x(forIndex: 7))

        // The hard invariant, sampled at every event: the thumb is *on* a tick.
        let edges = slider.geometry.edges
        for x in thumbXs {
            XCTAssertTrue(edges.contains { abs($0 - x) < 1e-9 },
                          "thumb at \(x) is not on a tick (edges: \(edges)) — 拖动中不存在中间值")
        }
        XCTAssertEqual(thumbXs.count, 122)
    }

    /// A drag back down the ladder emits the same way (and a drag that stays inside one gap emits
    /// nothing at all — that is what "only when the index changes" means).
    func testReverseDragAndAStallInOneGap() {
        let slider = makeSlider()
        var emitted: [Double] = []
        slider.onZoom = { emitted.append($0) }
        slider.update(zoomStop: 4, fitZoom: nil)
        XCTAssertEqual(slider.currentIndex, 7)
        XCTAssertEqual(slider.labelText, "400%")

        // Wiggle inside the last gap: no emission.
        let inside = slider.geometry.x(forIndex: 7) - slider.geometry.usableWidth / 7 / 4
        slider.pointerDown(at: slider.point(forIndex: 7))
        for offset in stride(from: CGFloat(0), through: 3, by: 0.5) {
            slider.pointerDragged(at: CGPoint(x: slider.trackFrame.minX + inside - offset, y: 15))
        }
        XCTAssertEqual(emitted, [], "a drag that never crosses a midpoint is not a stop change")

        // Then all the way down to 25 %: seven steps, each a rung.
        for index in stride(from: 7, through: 0, by: -1) {
            slider.pointerDragged(at: slider.point(forIndex: index))
        }
        slider.pointerUp()
        // 400 % was adopted, not emitted (the press landed on the rung it was already on), so the
        // walk down is the seven changes below it.
        XCTAssertEqual(emitted, Array(stops.reversed().dropFirst()),
                       "the reverse walk is the ladder, rung by rung")
        XCTAssertEqual(slider.labelText, "25%")
    }

    /// A single click on a tick: exactly one call, with that tick's value. Clicking the tick it is
    /// already on, or the chip, is not a stop change.
    func testClickOnATickEmitsExactlyOnceWithThatStop() {
        let slider = makeSlider()
        var emitted: [Double] = []
        var fitRequests = 0
        slider.onZoom = { emitted.append($0) }
        slider.onFit = { fitRequests += 1 }
        slider.update(zoomStop: 0.25, fitZoom: nil)

        slider.pointerDown(at: slider.point(forIndex: 4))
        slider.pointerUp()
        XCTAssertEqual(emitted, [stops[4]], "one click → one call → the tick it landed on (100 %)")
        XCTAssertEqual(slider.labelText, "100%")
        XCTAssertEqual(slider.accentedTickCount, 5, "the rung and everything left of it")

        // Same tick again: no change, no call.
        slider.pointerDown(at: slider.point(forIndex: 4))
        slider.pointerUp()
        XCTAssertEqual(emitted.count, 1)

        // The chip is the other gesture: it asks for fit and emits no stop.
        slider.activateChip()
        XCTAssertEqual(fitRequests, 1)
        XCTAssertEqual(emitted.count, 1, "the chip never zooms to a rung")
    }

    /// **The chip + the continuous fit thumb.** In fit the chip reads 适应, no tick is accented, and
    /// the thumb is drawn at the fit ratio's log position (track ends outside 25–400 %). None of
    /// that is a stop: `thumbIndex` is nil.
    func testFitChipAndContinuousThumb() {
        let slider = makeSlider()
        var emitted: [Double] = []
        slider.onZoom = { emitted.append($0) }

        slider.update(zoomStop: nil, fitZoom: 0.18)
        XCTAssertNil(slider.zoomStop)
        XCTAssertTrue(slider.showingFit)
        XCTAssertEqual(slider.labelText, "适应")
        XCTAssertEqual(slider.accentedTickCount, 0, "fit marks no rung")
        XCTAssertNil(slider.thumbIndex, "the fit thumb is not on a rung")
        XCTAssertEqual(slider.thumbRect.minX, 0, accuracy: 0.01, "18 % → the track's left end")

        slider.update(zoomStop: nil, fitZoom: 6.2)
        XCTAssertEqual(slider.thumbRect.maxX, slider.geometry.width, accuracy: 0.01,
                       "620 % → the track's right end")
        XCTAssertEqual(slider.labelText, "适应")

        slider.update(zoomStop: nil, fitZoom: 0.31)
        XCTAssertGreaterThan(slider.thumbCenterX, slider.geometry.x(forIndex: 0))
        XCTAssertLessThan(slider.thumbCenterX, slider.geometry.x(forIndex: 1))
        XCTAssertEqual(slider.thumbCenterX, 23.67, accuracy: 0.5)
        XCTAssertEqual(emitted, [], "displaying fit is not a stop change")
    }

    /// From fit, the **first** pointer event drops onto the ladder — one press, one rung — and never
    /// back into fit. Off the left end it is 25 %, off the right end 400 %.
    func testOnePointDragFromFitDropsOntoTheLadder() {
        let slider = makeSlider()
        var emitted: [Double] = []
        slider.onZoom = { emitted.append($0) }
        slider.update(zoomStop: nil, fitZoom: 0.31)
        XCTAssertEqual(slider.labelText, "适应")

        // 1 pt of movement — far from the next gap (18.3 pt).
        let startX = slider.trackFrame.minX + slider.thumbCenterX
        slider.pointerDown(at: CGPoint(x: startX, y: slider.bounds.midY))
        slider.pointerDragged(at: CGPoint(x: startX + 1, y: slider.bounds.midY))
        slider.pointerUp()
        XCTAssertEqual(emitted.count, 1, "the first event is already a stop change")
        XCTAssertNotNil(slider.zoomStop, "dragging from fit leaves fit at once")
        XCTAssertFalse(slider.showingFit)
        XCTAssertTrue(stops.contains { abs($0 - emitted[0]) < 1e-12 },
                      "\(emitted[0]) must be a rung")
        XCTAssertEqual(slider.labelText, LoupeViewState.percentLabel(of: emitted[0]))

        // Every rung is reachable in one press from fit.
        for index in 0...7 {
            let fresh = makeSlider()
            var out: [Double] = []
            fresh.onZoom = { out.append($0) }
            fresh.update(zoomStop: nil, fitZoom: 0.31)
            fresh.pointerDown(at: fresh.point(forIndex: index))
            fresh.pointerUp()
            XCTAssertEqual(out, [stops[index]], "one press from fit → \(labels[index])")
            XCTAssertEqual(fresh.thumbIndex, index)
            XCTAssertEqual(fresh.labelText, labels[index])
            XCTAssertEqual(fresh.accentedTickCount, index + 1)
        }

        // Dragged past the left end: 25 %, still numeric, never fit.
        let edge = makeSlider()
        var out: [Double] = []
        edge.onZoom = { out.append($0) }
        edge.update(zoomStop: nil, fitZoom: 0.31)
        edge.pointerDown(at: edge.point(forIndex: 3))
        for target in stride(from: CGFloat(0), through: -400, by: -20) {
            edge.pointerDragged(at: CGPoint(x: edge.trackFrame.minX + target, y: 15))
        }
        edge.pointerUp()
        XCTAssertEqual(out.last, 0.25, "the far left of the track is 25 %, never 适应")
        XCTAssertEqual(edge.zoomStop, LoupeViewState.minimumZoom)
        XCTAssertEqual(edge.labelText, "25%")

        // …and past the right end: 400 %.
        let right = makeSlider()
        var rightOut: [Double] = []
        right.onZoom = { rightOut.append($0) }
        right.update(zoomStop: 1, fitZoom: nil)
        right.pointerDown(at: right.point(forIndex: 4))
        for target in stride(from: CGFloat(700), through: 1_200, by: 50) {
            right.pointerDragged(at: CGPoint(x: right.trackFrame.minX + target, y: 15))
        }
        right.pointerUp()
        XCTAssertEqual(rightOut.last, 4.0, "the far right is 400 %")
        XCTAssertEqual(right.labelText, "400%")
    }

    /// The chip's round trip: from a rung, clicking it goes back to the fit **display** — 适应, no
    /// accent, thumb on the continuous fit position (the controller's `zoomToFit()` → `update`).
    func testChipTakesARungBackToTheFitDisplay() {
        let slider = makeSlider()
        var fitRequests = 0
        slider.onFit = { [weak slider] in
            fitRequests += 1
            slider?.update(zoomStop: nil, fitZoom: 0.31)   // what the controller's sync does after ⌘0
        }
        slider.update(zoomStop: 2, fitZoom: nil)
        XCTAssertEqual(slider.labelText, "200%")
        XCTAssertEqual(slider.thumbCenterX, slider.geometry.x(forIndex: 5))
        XCTAssertEqual(slider.accentedTickCount, 6)

        slider.activateChip()
        XCTAssertEqual(fitRequests, 1)
        XCTAssertEqual(slider.labelText, "适应")
        XCTAssertNil(slider.thumbIndex, "back to a display, not a rung")
        XCTAssertEqual(slider.thumbCenterX, 23.67, accuracy: 0.5,
                       "the fit thumb returns to the ratio's continuous position")
        XCTAssertEqual(slider.accentedTickCount, 0)
        XCTAssertGreaterThan(slider.thumbCenterX, slider.geometry.x(forIndex: 0),
                             "…inside the first gap, not on a tick")
        XCTAssertLessThan(slider.thumbCenterX, slider.geometry.x(forIndex: 1))
        XCTAssertNotEqual(slider.thumbCenterX, slider.geometry.x(forIndex: 0),
                          "the fit position must not collapse onto 25 %")
    }

    /// An external zoom (⌘=, ⌘−, the wheel, a pinch, ⌘0) is pushed in through `update`; the chip,
    /// the tints and the thumb all follow it, in both directions, repeatedly.
    func testExternalZoomChangesAreAdoptedInBothDirections() {
        let slider = makeSlider()
        var emitted: [Double] = []
        slider.onZoom = { emitted.append($0) }

        for (index, stop) in stops.enumerated() {
            slider.update(zoomStop: stop, fitZoom: nil)
            XCTAssertEqual(slider.labelText, labels[index])
            XCTAssertEqual(slider.currentIndex, index)
            XCTAssertEqual(slider.thumbIndex, index)
            XCTAssertEqual(slider.thumbCenterX, slider.geometry.x(forIndex: index))
            XCTAssertEqual(slider.accentedTickCount, index + 1)
        }
        for index in stride(from: 7, through: 0, by: -1) {
            slider.update(zoomStop: stops[index], fitZoom: nil)
            XCTAssertEqual(slider.currentIndex, index)
            XCTAssertEqual(slider.labelText, labels[index])
        }
        // ⌘0: back to fit → 适应 and the continuous fit thumb.
        slider.update(zoomStop: nil, fitZoom: 0.72)
        XCTAssertEqual(slider.labelText, "适应")
        XCTAssertEqual(slider.accentedTickCount, 0)
        XCTAssertNil(slider.thumbIndex)
        XCTAssertEqual(emitted, [], "the camera telling the control where it is is not the control zooming")
    }

    /// Outside the control the view is not there at all: a press next to it belongs to the canvas'
    /// pan, not to the slider.
    func testHitTestIsNilOutsideTheControl() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let slider = ZoomGlassSlider(frame: NSRect(x: 100, y: 100, width: 210, height: 30))
        container.addSubview(slider)
        slider.layout()

        XCTAssertTrue(container.hitTest(NSPoint(x: 150, y: 110)) === slider,
                      "inside the control is ours — the chip and the track alike")
        XCTAssertTrue(container.hitTest(NSPoint(x: 250, y: 110)) === slider,
                      "the track pill too")
        XCTAssertNil(slider.hitTest(NSPoint(x: 99, y: 110)), "left of it")
        XCTAssertNil(slider.hitTest(NSPoint(x: 311, y: 110)), "right of it")
        XCTAssertNil(slider.hitTest(NSPoint(x: 150, y: 99)), "below it")
        XCTAssertNil(slider.hitTest(NSPoint(x: 150, y: 131)), "above it")
        // The canvas around it still answers for itself (a pan may start there); it is only the
        // *control* that must vanish from the hit test.
        let canvasHit = container.hitTest(NSPoint(x: 150, y: 60))
        XCTAssertFalse(canvasHit === slider, "the canvas around the control is untouched")
    }

    // MARK: - 3. the controller wiring

    /// The control exists, is the topmost subview of the canvas, and is pinned 16 pt into the
    /// bottom-right corner with the autoresizing mask that keeps it there.
    func testTheControlIsPinnedToTheCanvasBottomRight() {
        let controller = LoupeController(session: CatalogSession())
        let root = controller.view
        root.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        if controller.zoomSlider.frame.maxX < 0 { controller.viewDidLayout() }

        let slider = controller.zoomSlider
        XCTAssertNotNil(slider.superview)
        XCTAssertTrue(slider.superview?.subviews.last === slider, "the control is the topmost chrome")
        XCTAssertEqual(slider.frame.width, 210, accuracy: 0.01)
        XCTAssertEqual(slider.frame.height, 30, accuracy: 0.01)
        XCTAssertEqual(slider.frame.maxX, 1000 - 16, accuracy: 0.01)
        XCTAssertEqual(slider.frame.minY, 16, accuracy: 0.01)
        XCTAssertTrue(slider.autoresizingMask.contains(.minXMargin))
        XCTAssertTrue(slider.autoresizingMask.contains(.maxYMargin))
        XCTAssertFalse(slider.autoresizingMask.contains(.width), "a resized canvas must not stretch it")
    }

    /// Both gestures are wired at load (`onZoom` → `zoomFromSlider`, `onFit` → `zoomToFit`), the
    /// wheel still belongs to the canvas, and the control starts on the camera's state.
    func testTheControllerWiresBothGestures() {
        let controller = LoupeController(session: CatalogSession())
        _ = controller.view
        XCTAssertNotNil(controller.zoomSlider.onZoom, "the track's only output is wired at load")
        XCTAssertNotNil(controller.zoomSlider.onFit, "the chip is wired at load")
        XCTAssertTrue(controller.zoomSlider.wheelTarget === controller.canvasView,
                      "the wheel/pinch over the control still belongs to the loupe")
        XCTAssertEqual(controller.zoomSlider.labelText, "适应")
        XCTAssertEqual(controller.zoomSlider.accentedTickCount, 0)
        XCTAssertEqual(controller.zoomSlider.geometry.levels, LoupeController.zoomStops,
                       "the control names the menu's rungs, exactly")
    }

    /// The chip is the pointer's way into fit: clicking it runs `zoomToFit()`, so `currentZoomStop`
    /// becomes nil and the chip reads 适应.
    func testClickingTheChipEntersFit() {
        let controller = LoupeController(session: CatalogSession())
        _ = controller.view
        controller.zoomToFit()
        XCTAssertNil(controller.currentZoomStop)
        XCTAssertEqual(controller.zoomSlider.labelText, "适应")
        XCTAssertNil(controller.zoomSlider.thumbIndex)

        // Still fit after another layout/status pass — nothing invents a rung for it.
        controller.zoomSlider.activateChip()
        XCTAssertNil(controller.currentZoomStop, "the chip enters fit, it cannot leave it into a rung")
        XCTAssertEqual(controller.zoomSlider.labelText, "适应")
    }

    /// **The anchor rule.** The slider zooms around the canvas **centre**; the cursor-anchored path
    /// (⌘= / ⌘− / the menu) keeps the pixel under the pointer. Both are measured as the source pixel
    /// under a view point, before and after.
    func testSliderZoomsAroundTheCentreWhileTheCursorPathDoesNot() throws {
        let url = try rawFixture()
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        controller.reducesMotion = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)

        controller.frameSource = LoupeController.FrameSource(url: url, identity: "zoom-slider-anchor",
                                                             viewport: viewport, state: .fit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        pump(0.1)

        let canvas = controller.canvasView.bounds
        let centre = CGPoint(x: canvas.midX, y: canvas.midY)
        let corner = CGPoint(x: canvas.maxX - 2, y: canvas.maxY - 2)

        // 100 % around the centre as the common starting point.
        controller.zoom(to: 1, aroundView: nil)
        pump(0.02)
        let before = try XCTUnwrap(controller.sourcePoint(forViewPoint: centre))
        let beforeCorner = try XCTUnwrap(controller.sourcePoint(forViewPoint: corner))

        // 1. The slider's path → 200 %, anchored on the centre.
        controller.zoomFromSlider(to: 2)
        pump(0.02)
        XCTAssertEqual(controller.currentZoomStop, 2, "the slider's stop is the ladder's 200 %")
        let afterCentre = try XCTUnwrap(controller.sourcePoint(forViewPoint: centre))
        XCTAssertEqual(afterCentre.x, before.x, accuracy: 0.5,
                       "the centre pixel must not move: the slider zooms from the centre")
        XCTAssertEqual(afterCentre.y, before.y, accuracy: 0.5)
        let sliderCentre = (controller.viewState.centerX, controller.viewState.centerY)

        // 2. The cursor-anchored path (what ⌘= does with `cursorAnchor()`) → 200 % at a corner.
        controller.zoom(to: 1, aroundView: nil)
        pump(0.02)
        controller.zoom(to: 2, aroundView: corner)
        pump(0.02)
        let afterCorner = try XCTUnwrap(controller.sourcePoint(forViewPoint: corner))
        XCTAssertEqual(afterCorner.x, beforeCorner.x, accuracy: 0.5,
                       "the cursor path keeps the pixel under the pointer")
        XCTAssertEqual(afterCorner.y, beforeCorner.y, accuracy: 0.5)
        let cursorCentre = (controller.viewState.centerX, controller.viewState.centerY)

        // 3. The two anchors are different — otherwise the first assertion would be vacuous.
        XCTAssertGreaterThan(abs(sliderCentre.0 - cursorCentre.0) + abs(sliderCentre.1 - cursorCentre.1),
                             1.0,
                             "the slider must not be using the cursor anchor")
        let centreAfterCursorPath = try XCTUnwrap(controller.sourcePoint(forViewPoint: centre))
        XCTAssertGreaterThan(abs(centreAfterCursorPath.x - before.x) + abs(centreAfterCursorPath.y - before.y),
                             1.0,
                             "around-the-corner moves the centre; around-the-centre does not")
    }
}
