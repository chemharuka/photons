import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// The histogram card's **axis** (2026-10-26): SDR codes on the left, then a fixed 30 pt-per-stop
/// exponential tail of 4 stops, with the display ceiling marked at `log2(headroom)` stops.
///
/// These are geometry claims, so they are tested as arithmetic on `HistogramAxis` rather than by
/// reading pixels: the smoke asserts the same numbers on a laid-out card (`lastAxis`), and this file
/// asserts them without a window at all.
final class HistogramAxisTests: XCTestCase {

    private let plot = NSRect(x: 0, y: 0, width: 300, height: 58)

    /// 30 pt per stop, 4 stops, and the SDR segment takes the rest of the card.
    func testTheTailIsThirtyPointsPerStopAndFourStopsWide() {
        let axis = HistogramAxis(plot: plot)
        XCTAssertEqual(axis.stops, 4)
        XCTAssertEqual(axis.stopWidth, 30, accuracy: 1e-9)
        XCTAssertEqual(axis.hdrWidth, 120, accuracy: 1e-9)
        XCTAssertEqual(axis.sdrWidth, 180, accuracy: 1e-9)
        XCTAssertEqual(axis.x(stopsAboveWhite: 1) - axis.x(stopsAboveWhite: 0), 30, accuracy: 1e-9)
        XCTAssertEqual(axis.x(stopsAboveWhite: 4), plot.maxX, accuracy: 1e-9)
        // The tail's own bins are uniform inside the tail: 256 bins over 120 pt (0.469 pt each).
        XCTAssertEqual(axis.hdrBinCount, 256)
        XCTAssertEqual(axis.x(hdrBin: 1) - axis.x(hdrBin: 0), 120.0 / 256.0, accuracy: 1e-9)
    }

    /// The inspector's minimum card width still holds 30 pt per stop: 244 − 60 pt of code = 184 pt, and
    /// a 4-stop tail is only 120 pt. This is the arithmetic that decides the card's layout, so it is
    /// asserted, not assumed.
    func testTheNarrowestShippedCardStillHoldsTheFullTailAtThirtyPointsPerStop() {
        let narrowest = HistogramAxis(plot: NSRect(x: 0, y: 0, width: 244, height: 58))
        XCTAssertEqual(narrowest.stopWidth, 30, accuracy: 1e-9,
                       "244 pt − 60 pt of SDR = 184 pt ≥ 120 pt, so no scale-down is needed")
        XCTAssertEqual(narrowest.hdrWidth, 120, accuracy: 1e-9)
        XCTAssertEqual(narrowest.sdrWidth, 124, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(narrowest.sdrWidth, HistogramAxis.minimumSDRWidth)
    }

    /// The ceiling tick is `log2(headroom)` stops into the tail — the *same* unit the stops are in,
    /// which is the reason the tail is in linear stops rather than code doublings.
    func testTheCeilingTickIsAtLogTwoOfHeadroom() {
        let axis = HistogramAxis(plot: plot)
        XCTAssertEqual(axis.x(ceiling: 1), axis.sdrMaxX, accuracy: 1e-9, "SDR: the tick *is* the boundary")
        XCTAssertEqual(axis.x(ceiling: 1.695),
                       axis.sdrMaxX + CGFloat(log2(1.695)) * 30, accuracy: 1e-9)
        XCTAssertEqual(axis.x(ceiling: 1.695), axis.sdrMaxX + 22.85, accuracy: 0.02)
        XCTAssertEqual(axis.x(ceiling: 16), plot.maxX, accuracy: 1e-9,
                       "headroom 16 is 4 stops — exactly the tail's end")
        // A ceiling past what the tail can hold is clamped to its right edge, never drawn outside.
        XCTAssertEqual(axis.x(ceiling: 64), plot.maxX, accuracy: 1e-9)
        XCTAssertEqual(axis.x(ceiling: 256), plot.maxX, accuracy: 1e-9)
    }

    /// A card too narrow for 60 pt of SDR shrinks the *stop scale*, not the SDR segment: the code axis
    /// is where a photograph's distribution lives.
    func testATooNarrowCardShrinksTheStopScaleInsteadOfTheSDRSegment() {
        let narrow = HistogramAxis(plot: NSRect(x: 0, y: 0, width: 100, height: 58))
        XCTAssertEqual(narrow.sdrWidth, HistogramAxis.minimumSDRWidth, accuracy: 1e-9)
        XCTAssertEqual(narrow.stopWidth, 40.0 / 4.0, accuracy: 1e-9)
        XCTAssertEqual(narrow.hdrWidth, 40, accuracy: 1e-9)
    }

    /// One path covers both segments: 256 code bins, then 256 tail bins, then the baseline corner.
    func testOnePathCoversBothSegments() {
        let channel = HistogramChannel(bins: [Int](repeating: 1, count: 256),
                                       hdrBins: [Int](repeating: 1, count: 256),
                                       clippedHigh: 0, clippedCeiling: 0, clippedLow: 0)
        let axis = HistogramAxis(plot: plot)
        let points = HistogramCardFormat.points(channel, binCount: 256, axis: axis,
                                                peak: HistogramCardFormat.scalePeak(channel))
        XCTAssertEqual(points.count, 256 + 256 + 2)
        // points[0] is the baseline corner, so bin 255 is index 256 and tail bin 0 is index 257.
        XCTAssertLessThan(points[256].x, axis.sdrMaxX, "the last code bin stays left of white")
        XCTAssertGreaterThan(points[257].x, axis.sdrMaxX, "the first tail bin is right of white")
        // Monotone in x across the seam: the path never doubles back.
        for i in 1..<points.count {
            XCTAssertGreaterThanOrEqual(points[i].x, points[i - 1].x - 1e-9,
                                        "point \(i) doubles back")
        }
    }

    /// The vertical scale ignores the drawn path's two ends: a clipped spike in the last tail bin
    /// must not flatten the picture into a line.
    func testAPeakInTheCeilingBinDoesNotFlattenThePlot() {
        var sdr = [Int](repeating: 0, count: 256)
        sdr[100] = 40
        var hdr = [Int](repeating: 0, count: 96)
        hdr[0] = 5
        hdr[95] = 10_000
        let channel = HistogramChannel(bins: sdr, hdrBins: hdr, clippedHigh: 1,
                                       clippedCeiling: 1, clippedLow: 0)
        XCTAssertEqual(HistogramCardFormat.scalePeak(channel), 40)
    }
}
