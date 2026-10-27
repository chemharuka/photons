import XCTest
import PhotonsCore
import PhotonsUI

/// The discrete zoom ladder, as arithmetic.
///
/// The non-negotiables, all of them decided by the user:
///
///   · **nine numeric stops**, `12.5 % · 25 % · 33.3 % · 50 % · 66.7 % · 100 % · 200 % · 300 % · 400 %`,
///     and the thirds are the exact doubles `1.0/3.0` and `2.0/3.0` — only their label is 33.3 % / 66.7 %;
///     (2026-10-27 用户要求加 12.5% 档 — the ninth stop, everything else in the same order.)
///   · **`fit` is not a rung.** 适应窗口 is a mode whose ratio is a property of the window (it can be
///     0.31, 0.72, 0.88 or above 1), entered by its own action, so it is not in the table and nothing
///     here depends on it;
///   · **the snap is a floor**: a raw value lands on the largest rung *not above* it ("自动往下走一
///     级"), and below 12.5 % it stops at 12.5 % — `fit` is a separate step out, not a snap.
final class LoupeZoomLadderTests: XCTestCase {

    private let decimals: [Double] = [0.125, 0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1, 2, 3, 4]
    private let labels = ["12.5%", "25%", "33.3%", "50%", "66.7%", "100%", "200%", "300%", "400%"]

    // MARK: 1. the table itself

    /// Nine stops, ascending, and the thirds are divisions — not 0.333 / 0.667.
    func testTheTableIsNineExactStops() {
        XCTAssertEqual(LoupeViewState.zoomStops, decimals)
        XCTAssertEqual(LoupeViewState.zoomStops.count, 9)
        XCTAssertEqual(LoupeViewState.zoomStops[0], 0.125, "2026-10-27: the new 12.5 % rung is first")
        XCTAssertEqual(LoupeViewState.zoomStops[2], 1.0 / 3.0, "33.3 % is exactly one third")
        XCTAssertEqual(LoupeViewState.zoomStops[4], 2.0 / 3.0, "66.7 % is exactly two thirds")
        // The whole point of writing them as divisions: they are *not* the rounded decimals.
        XCTAssertNotEqual(LoupeViewState.zoomStops[2], 0.333)
        XCTAssertNotEqual(LoupeViewState.zoomStops[4], 0.667)
        for (a, b) in zip(LoupeViewState.zoomStops, LoupeViewState.zoomStops.dropFirst()) {
            XCTAssertLessThan(a, b, "the ladder must ascend")
        }
        // Adding a rung must not reorder the ones that were already there.
        XCTAssertEqual(Array(LoupeViewState.zoomStops.dropFirst()),
                       [0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1, 2, 3, 4].sorted(),
                       "the eight original stops keep their order")
        XCTAssertEqual(LoupeViewState.minimumZoom, 0.125)
        XCTAssertEqual(LoupeViewState.maximumZoom, 4)
        // 1:1 is still a value in the table, and still the same value (§A0's base).
        XCTAssertEqual(LoupeViewState.zoomStops[5], 1)
    }

    /// `levels` is the same nine stops and carries **no fit rung** — whatever the window does.
    func testLevelsAreTheNineStopsAndNothingElse() {
        let ladder = LoupeViewState.levels
        XCTAssertEqual(ladder.map(\.zoom), decimals)
        XCTAssertEqual(ladder.map(\.label), labels)
        // "Which rung is fit on?" has no answer any more, and the type cannot even ask: a rung is a
        // zoom value and a percent label, nothing else.
        XCTAssertEqual(Set(ladder.map(\.label)).count, 9)
        for level in ladder {
            XCTAssertNotNil(LoupeViewState.stopIndex(of: level.zoom))
            XCTAssertTrue(level.label.hasSuffix("%"))
        }
    }

    /// The menu names the same nine stops, and its item tag is the **index** — the identity that
    /// keeps `1/3` from collapsing into `0.33`.
    func testMenuStopsAreIndexedToTheExactValues() {
        XCTAssertEqual(LoupeController.menuZoomStops, decimals)
        for index in LoupeController.menuZoomStops.indices {
            let stop = LoupeController.menuZoomStops[index]
            XCTAssertEqual(LoupeViewState.stopIndex(of: stop), index, "index \(index) must be a stop")
        }
        XCTAssertEqual(LoupeController.menuZoomStops[2], 1.0 / 3.0)
        XCTAssertEqual(LoupeController.menuZoomStops[4], 2.0 / 3.0)
        XCTAssertEqual(LoupeController.menuZoomStops[0], 0.125, "the menu can name 12.5 %")
    }

    // MARK: 2. the snap table (the acceptance rows)

    /// The user's rule in one table: **the largest rung not above the requested value**, including the
    /// thirds, and the floor at 12.5 %.
    func testSnapIsTheLargestRungNotAboveTheTarget() {
        let rows: [(raw: Double, zoom: Double, why: String)] = [
            (0.10, 0.125, "below the floor → 12.5 %"),
            (0.124, 0.125, "just below the new rung → still 12.5 %"),
            (0.18, 0.125, "above 12.5 %, below 25 %"),
            (0.24, 0.125, "below 25 % → the 12.5 % rung, not 25 %"),
            (0.26, 0.25, "above 25 %, below 33.3 %"),
            (0.33, 0.25, "0.33 is below 1/3 (0.3333…) — the exact value decides, not the printed label"),
            (1.0 / 3.0, 1.0 / 3.0, "exactly the third"),
            (0.34, 1.0 / 3.0, "just above the third"),
            (0.49, 1.0 / 3.0, "still below 50 %"),
            (0.5, 0.5, "exactly 50 %"),
            (0.66, 0.5, "0.66 is below 2/3"),
            (2.0 / 3.0, 2.0 / 3.0, "exactly two thirds"),
            (0.9, 2.0 / 3.0, "below 100 % → 66.7 %"),
            (1.0, 1.0, "exactly 100 %"),
            (1.99, 1.0, "below 200 %"),
            (2.0, 2.0, "exactly 200 %"),
            (2.9, 2.0, "below 300 %"),
            (3.5, 3.0, "below 400 %"),
            (4.0, 4.0, "the ceiling"),
            (7.0, 4.0, "past the ceiling: the top rung, never an invented 8:1"),
        ]
        for row in rows {
            let level = LoupeViewState.snappedLevel(for: row.raw)
            XCTAssertEqual(level.zoom, row.zoom, accuracy: 1e-12, "raw \(row.raw): \(row.why)")
            XCTAssertNotNil(LoupeViewState.stopIndex(of: level.zoom),
                            "raw \(row.raw): the snap must land on a table value")
        }
    }

    /// The clamp is the same story at the ends: 0.125 … 4, never outside.
    func testZoomIsClampedToAnEighthThroughFour() {
        XCTAssertEqual(LoupeViewState.clampZoom(0.01), 0.125)
        XCTAssertEqual(LoupeViewState.clampZoom(0.125), 0.125)
        XCTAssertEqual(LoupeViewState.clampZoom(0.25), 0.25)
        XCTAssertEqual(LoupeViewState.clampZoom(1.0 / 3.0), 1.0 / 3.0)
        XCTAssertEqual(LoupeViewState.clampZoom(4), 4)
        XCTAssertEqual(LoupeViewState.clampZoom(9), 4)
        XCTAssertEqual(LoupeViewState.clampZoom(.nan), 0.125)
        XCTAssertEqual(LoupeViewState.clampZoom(.infinity), 4)
    }

    // MARK: 3. labels

    /// Whole percent for the whole stops, **one decimal** for the thirds and for 12.5 % — and only the
    /// label: the value behind `33.3%` is still `1.0/3.0`, and the value behind `12.5%` is `0.125`.
    func testLabels() {
        XCTAssertEqual(LoupeViewState.levels.map(\.label), labels)
        for (stop, label) in zip(decimals, labels) {
            XCTAssertEqual(LoupeViewState.percentLabel(of: stop), label, "\(stop)")
        }
        XCTAssertEqual(LoupeViewState.percentLabel(of: 0.62), "62%")
        XCTAssertEqual(LoupeViewState.percentLabel(of: .nan), "100%", "a broken number reads as 1:1, not NaN%")
        // The label is not the value: rounding it back would land on a different stop.
        XCTAssertNotEqual(LoupeViewState.percentLabel(of: 1.0 / 3.0), "33%")
        XCTAssertNotEqual(LoupeViewState.percentLabel(of: 2.0 / 3.0), "67%")
        // 2026-10-27 用户要求加 12.5% 档 — the label keeps its one decimal: not `13%`, not `0.125`.
        XCTAssertEqual(LoupeViewState.percentLabel(of: 0.125), "12.5%")
        XCTAssertNotEqual(LoupeViewState.percentLabel(of: 0.125), "13%")
        XCTAssertNotEqual(LoupeViewState.percentLabel(of: 0.125), "0.125")
        XCTAssertEqual(LoupeZoomLevel(zoom: 0.125).label, "12.5%", "the rung's own label")
    }

    // MARK: 4. the bridge geometry

    /// `fit → 100 %` on a 60 MP frame: the fit picture occupies 2400×1600 of a 2560×1600 canvas (its
    /// 1.5 crop aspect fitted), the 1:1 picture occupies the whole canvas.
    ///
    /// The bridge's scale is **not** the ratio of those two rects (1.0667) — that is only how much
    /// bigger the *letterbox* gets, and scaling the fit picture by it would end the animation showing
    /// the whole frame at 43 %, which is not the frame the 100 % camera is about to draw. The scale is
    /// the ratio of the two cameras: `zoomN / zoomO = 1 / 0.4 = 2.5`.
    func testBridgeScaleIsTheRatioOfTheTwoCameras() {
        let framing = LoupeFraming(viewport: ImageSize(width: 2560, height: 1600),
                                  sourceWidth: 6000, sourceHeight: 4000)
        let fitContent = framing.contentPixels(of: .fit)
        let oneToOne = LoupeViewState(mode: .actual, zoom: 1, centerX: 3000, centerY: 2000)
        let actualContent = framing.contentPixels(of: oneToOne)

        XCTAssertEqual(fitContent, ImageSize(width: 2400, height: 1600))
        XCTAssertEqual(actualContent, ImageSize(width: 2560, height: 1600))

        let bridge = LoupeZoomBridge(fromContent: fitContent, toContent: actualContent,
                                     fromMapping: framing.mapping(of: .fit),
                                     toMapping: framing.mapping(of: oneToOne),
                                     canvas: framing.viewport)
        XCTAssertEqual(bridge.scale, 1 / framing.fitZoom, accuracy: 1e-12)
        XCTAssertEqual(bridge.scale, 2.5, accuracy: 1e-12)
        XCTAssertTrue(bridge.isVisible)

        // Back the other way it shrinks, by the reciprocal of the same number.
        let back = LoupeZoomBridge(fromContent: actualContent, toContent: fitContent,
                                   fromMapping: framing.mapping(of: oneToOne),
                                   toMapping: framing.mapping(of: .fit),
                                   canvas: framing.viewport)
        XCTAssertEqual(back.scale, 1 / bridge.scale, accuracy: 1e-12)

        // A canvas of zero pixels is a broken frame, not an infinite zoom.
        let broken = LoupeZoomBridge(fromContent: ImageSize(width: 0, height: 0), toContent: actualContent,
                                     fromMapping: framing.mapping(of: .fit),
                                     toMapping: framing.mapping(of: oneToOne),
                                     canvas: ImageSize(width: 0, height: 0))
        XCTAssertFalse(broken.isVisible)
    }

    /// `100 % → 200 %` fills the canvas at **both** stops, so the old content-rect ratio is exactly
    /// 1.0 and a bridge built on it would do nothing. The cameras still differ by 2×, and this is the
    /// stop change the ladder makes a hundred times a session — it is bridged like any other
    /// (`LoupeZoomBridge.scale == 2`), and the translation is what keeps the anchored pixel in place
    /// while it grows.
    func testTwoStopsThatFillTheSameRectStillBridgeByTwo() {
        let framing = LoupeFraming(viewport: ImageSize(width: 2560, height: 1600),
                                  sourceWidth: 6000, sourceHeight: 4000)
        let one = LoupeViewState(mode: .actual, zoom: 1, centerX: 3000, centerY: 2000)
        let two = LoupeViewState(mode: .actual, zoom: 2, centerX: 3000, centerY: 2000)
        XCTAssertEqual(framing.contentPixels(of: one), framing.contentPixels(of: two),
                       "both stops letterbox to the same canvas")
        XCTAssertEqual(framing.contentPixels(of: one), ImageSize(width: 2560, height: 1600))

        let bridge = LoupeZoomBridge(fromContent: framing.contentPixels(of: one),
                                     toContent: framing.contentPixels(of: two),
                                     fromMapping: framing.mapping(of: one),
                                     toMapping: framing.mapping(of: two),
                                     canvas: framing.viewport)
        XCTAssertEqual(bridge.scale, 2, accuracy: 1e-12)
        XCTAssertTrue(bridge.isVisible, "identical rects, two different cameras: it must still bridge")
    }

    /// The thirds bridge by their exact ratio too: `50 % → 66.7 %` is `4/3`, and `33.3 % → 66.7 %`
    /// is exactly `2`.
    func testTheThirdStopsBridgeByTheirExactRatio() {
        let framing = LoupeFraming(viewport: ImageSize(width: 2560, height: 1600),
                                  sourceWidth: 6000, sourceHeight: 4000)
        let half = LoupeViewState(mode: .actual, zoom: 0.5, centerX: 3000, centerY: 2000)
        let twoThirds = LoupeViewState(mode: .actual, zoom: 2.0 / 3.0, centerX: 3000, centerY: 2000)
        let bridge = LoupeZoomBridge(fromContent: framing.contentPixels(of: half),
                                     toContent: framing.contentPixels(of: twoThirds),
                                     fromMapping: framing.mapping(of: half),
                                     toMapping: framing.mapping(of: twoThirds),
                                     canvas: framing.viewport)
        XCTAssertEqual(bridge.scale, 4.0 / 3.0, accuracy: 1e-12)

        let third = LoupeViewState(mode: .actual, zoom: 1.0 / 3.0, centerX: 3000, centerY: 2000)
        let pair = LoupeZoomBridge(fromContent: framing.contentPixels(of: third),
                                   toContent: framing.contentPixels(of: twoThirds),
                                   fromMapping: framing.mapping(of: third),
                                   toMapping: framing.mapping(of: twoThirds),
                                   canvas: framing.viewport)
        XCTAssertEqual(pair.scale, 2, accuracy: 1e-12)
    }
}
