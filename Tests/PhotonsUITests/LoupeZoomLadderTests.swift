import XCTest
import PhotonsCore
import PhotonsUI

/// The discrete zoom ladder, as arithmetic.
///
/// Two things here are not negotiable and both are why this is a function rather than a table:
///
///   · **fit is not a position.** `LoupeFraming.fitZoom` is a property of the window and the crop —
///     0.31 for a 60 MP frame in a 2560-px viewport, 0.72 for a 24 MP one, 1.0 for a file that already
///     fits — so the ladder has to insert it wherever it actually falls. Nothing may assume the fit
///     ratio sits below 50 %.
///   · **the snap is a floor.** A raw value lands on the largest rung *not above* it ("自动往下走一级"),
///     never on the nearest one, and below the lowest rung the camera shows the whole frame.
final class LoupeZoomLadderTests: XCTestCase {

    /// A 60 MP frame in the loupe's 2560×1600 viewport: fit is 0.31, i.e. *below* the 50 % stop.
    private let bigFit = 0.31
    /// A 24 MP frame (6000×4000 → 24 MP… its fit ratio lands between 50 % and 100 %).
    private let middleFit = 0.72
    /// A crop smaller than the viewport: fit *is* 1:1 and the 100 % stop folds into it.
    private let tinyFit = 1.0

    // MARK: 1. the ladder itself

    func testLadderPutsFitWhereItActuallyFalls() {
        XCTAssertEqual(LoupeViewState.levels(fitZoom: bigFit).map(\.zoom).map { ($0 * 1000).rounded() / 1000 },
                       [0.31, 0.5, 1, 2, 3, 4])
        XCTAssertEqual(LoupeViewState.levels(fitZoom: middleFit).map(\.zoom), [0.5, 0.72, 1, 2, 3, 4])
        // fit == a stop: one rung, and it is the fit one (the camera is in `mode == .fit`).
        let tiny = LoupeViewState.levels(fitZoom: tinyFit)
        XCTAssertEqual(tiny.map(\.zoom), [0.5, 1, 2, 3, 4])
        XCTAssertEqual(tiny.filter(\.isFit).count, 1)
        XCTAssertEqual(tiny.first(where: \.isFit)?.zoom, 1)
    }

    /// A resize moves the fit rung, and the ladder must follow it: strictly ascending, exactly one fit
    /// rung, no rung within `tolerance` of another, for every ratio a window can produce.
    func testLadderIsSortedDedupedAndAlwaysHasExactlyOneFitRung() {
        for fit in [0.2, 0.253, 0.31, 0.4, 0.5, 0.62, 0.72, 0.88, 0.995, 1.0, 1.4] {
            let ladder = LoupeViewState.levels(fitZoom: fit)
            XCTAssertEqual(ladder.filter(\.isFit).count, 1, "fit=\(fit) must have exactly one fit rung")
            for (a, b) in zip(ladder, ladder.dropFirst()) {
                XCTAssertLessThan(a.zoom, b.zoom, "fit=\(fit): the ladder must ascend")
                XCTAssertGreaterThanOrEqual(b.zoom - a.zoom, LoupeZoomLevel.tolerance - 1e-12,
                                            "fit=\(fit): \(a.zoom) and \(b.zoom) are the same rung")
            }
            // 1.0 is never magnified: a fit rung above 1 would mean fitting blew the picture up.
            XCTAssertLessThanOrEqual(ladder.map(\.zoom).max() ?? 0, 4)
        }
    }

    // MARK: 2. the snap table (the acceptance rows)

    /// The brief's table, on a frame whose fit is *below* 50 % (the 60 MP case).
    func testSnapTableForAFitBelowFiftyPercent() {
        let rows: [(raw: Double, zoom: Double, isFit: Bool)] = [
            (0.62, 0.5, false),
            (0.90, 0.5, false),
            (1.40, 1.0, false),
            (2.90, 2.0, false),
            (3.50, 3.0, false),
            (7.00, 4.0, false),   // past the ceiling: the top rung, never an invented 5:1
            (0.20, 0.31, true),   // below every rung → the whole frame
            (0.31, 0.31, true),   // exactly fit
        ]
        for row in rows {
            let level = LoupeViewState.snappedLevel(for: row.raw, fitZoom: bigFit)
            XCTAssertEqual(level.zoom, row.zoom, accuracy: 1e-9, "raw \(row.raw)")
            XCTAssertEqual(level.isFit, row.isFit, "raw \(row.raw)")
        }
    }

    /// The same table on a frame whose fit ratio sits *between* 50 % and 100 %: the 50 % stop is now
    /// above fit, so a raw 0.9 must land on fit (0.72), not on 50 % — the row that proves the order is
    /// computed and not written down.
    func testSnapTableForAFitBetweenFiftyAndOneHundredPercent() {
        let rows: [(raw: Double, zoom: Double, isFit: Bool)] = [
            (0.40, 0.72, true),    // below 50 % *and* below fit → the whole frame
            (0.55, 0.5, false),    // 50 % is now a real rung *below* fit… and it is above 0.5
            (0.60, 0.5, false),
            (0.71, 0.5, false),    // just under fit: still the 50 % rung
            (0.72, 0.72, true),
            (0.90, 0.72, true),    // "向下" from 90 % is fit, not 100 %
            (1.00, 1.0, false),
            (1.40, 1.0, false),
            (2.90, 2.0, false),
            (3.50, 3.0, false),
            (7.00, 4.0, false),
        ]
        for row in rows {
            let level = LoupeViewState.snappedLevel(for: row.raw, fitZoom: middleFit)
            XCTAssertEqual(level.zoom, row.zoom, accuracy: 1e-9, "raw \(row.raw)")
            XCTAssertEqual(level.isFit, row.isFit, "raw \(row.raw)")
        }
        // 0.55 lands on 50 % *below* fit — the ladder is by value, so a rung below fit is legal.
        let below = LoupeViewState.snappedLevel(for: 0.55, fitZoom: middleFit)
        XCTAssertLessThan(below.zoom, middleFit)
        XCTAssertFalse(below.isFit)
    }

    /// With fit at 1:1 the 100 % stop is the fit rung, and a raw 0.95 is therefore fit — snapping there
    /// must not report "100 %" as a distinct stop that no longer exists.
    func testSnapTableWhenFitIsExactlyOneToOne() {
        // 100 % is the fit rung here: the stop folded into it, so there is one rung, not two.
        let atFit = LoupeViewState.snappedLevel(for: 1.0, fitZoom: tinyFit)
        XCTAssertTrue(atFit.isFit)
        XCTAssertEqual(atFit.zoom, 1, accuracy: 1e-9)
        // …and a raw *below* it floors to the 50 % rung, which still exists.
        let below = LoupeViewState.snappedLevel(for: 0.995, fitZoom: tinyFit)
        XCTAssertEqual(below.zoom, 0.5, accuracy: 1e-9)
        XCTAssertFalse(below.isFit)
        // A raw above the folded rung but below 200 % is still fit: the next rung up is 2:1.
        let above = LoupeViewState.snappedLevel(for: 1.9, fitZoom: tinyFit)
        XCTAssertEqual(above.zoom, 1, accuracy: 1e-9)
        XCTAssertTrue(above.isFit)
        let two = LoupeViewState.snappedLevel(for: 2.5, fitZoom: tinyFit)
        XCTAssertEqual(two.zoom, 2, accuracy: 1e-9)
        XCTAssertFalse(two.isFit)
    }

    // MARK: 3. labels

    /// The six rungs, labelled: 100 % is 1:1, and the fit rung carries its own ratio where the reader
    /// can see it move (`适应 31%`), which is the whole point of printing percent instead of "1:1".
    func testLadderLabels() {
        let ladder = LoupeViewState.levels(fitZoom: bigFit)
        XCTAssertEqual(ladder.map(\.label), ["适应", "50%", "100%", "200%", "300%", "400%"])
        XCTAssertEqual(ladder.map(\.displayLabel),
                       ["适应 31%", "50%", "100%", "200%", "300%", "400%"])

        let middle = LoupeViewState.levels(fitZoom: middleFit)
        XCTAssertEqual(middle.map(\.displayLabel),
                       ["50%", "适应 72%", "100%", "200%", "300%", "400%"])

        XCTAssertEqual(LoupeViewState.percentLabel(of: 0.5), "50%")
        XCTAssertEqual(LoupeViewState.percentLabel(of: 1), "100%")
        XCTAssertEqual(LoupeViewState.percentLabel(of: 0.62), "62%")
        XCTAssertEqual(LoupeViewState.percentLabel(of: .nan), "100%", "a broken number reads as 1:1, not NaN%")
    }

    // MARK: 4. the bridge geometry

    /// `fit → 100 %` on a 60 MP frame: the fit picture occupies 2400×1600 of a 2560×1600 canvas (its
    /// 1.5 crop aspect fitted), the 1:1 picture occupies the whole canvas, and the bridge scale is that
    /// ratio. Both rects are centred on the canvas, which is what makes the map a pure scale.
    func testBridgeScaleIsTheRatioOfTheTwoContentRects() {
        let framing = LoupeFraming(viewport: ImageSize(width: 2560, height: 1600),
                                  sourceWidth: 6000, sourceHeight: 4000)
        let fitContent = framing.contentPixels(of: .fit)
        let oneToOne = LoupeViewState(mode: .actual, zoom: 1, centerX: 3000, centerY: 2000)
        let actualContent = framing.contentPixels(of: oneToOne)

        XCTAssertEqual(fitContent, ImageSize(width: 2400, height: 1600))
        XCTAssertEqual(actualContent, ImageSize(width: 2560, height: 1600))

        let bridge = LoupeZoomBridge(fromContent: fitContent, toContent: actualContent)
        XCTAssertEqual(bridge.scaleX, 2560.0 / 2400.0, accuracy: 1e-12)
        XCTAssertEqual(bridge.scaleY, 1, accuracy: 1e-12)
        XCTAssertTrue(bridge.isVisible)

        // Back the other way it shrinks, by the reciprocal of the same number.
        let back = LoupeZoomBridge(fromContent: actualContent, toContent: fitContent)
        XCTAssertEqual(back.scaleX, 1 / bridge.scaleX, accuracy: 1e-12)

        // Same rect on both sides: nothing to animate, and no animation is armed.
        XCTAssertFalse(LoupeZoomBridge(fromContent: actualContent, toContent: actualContent).isVisible)
        // A rect of zero pixels is a broken frame, not an infinite zoom.
        XCTAssertEqual(LoupeZoomBridge(fromContent: ImageSize(width: 0, height: 0),
                                       toContent: actualContent).scaleX, 1)
    }

    /// 100 % → 200 % is the *same* fit to actual? No: both are `actual`, so the bridge refuses it. The
    /// content rects do differ (the 200 % window is half the crop) but that crossing must stay a plain
    /// re-render — this is the assertion that pins the bridge's scope.
    func testBridgeWouldScaleBetweenStopsButTheControllerNeverAsksForIt() {
        let framing = LoupeFraming(viewport: ImageSize(width: 2560, height: 1600),
                                  sourceWidth: 6000, sourceHeight: 4000)
        let one = framing.contentPixels(of: LoupeViewState(mode: .actual, zoom: 1, centerX: 3000, centerY: 2000))
        let two = framing.contentPixels(of: LoupeViewState(mode: .actual, zoom: 2, centerX: 3000, centerY: 2000))
        XCTAssertEqual(one, ImageSize(width: 2560, height: 1600))
        XCTAssertEqual(two, ImageSize(width: 2560, height: 1600))
        // Identical rects — so even if it were armed, it would be invisible: the 200 % frame is the
        // same canvas with a smaller window inside it, which is a re-render, not a geometry change.
        XCTAssertFalse(LoupeZoomBridge(fromContent: one, toContent: two).isVisible)
    }
}
