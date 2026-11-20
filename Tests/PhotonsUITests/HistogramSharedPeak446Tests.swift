import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// 446 — the three curves share **one** height ceiling.
///
/// Before this the card passed each channel its own `scalePeak`, so every colour was normalised to
/// 100 % on its own and a tall red bin flattened green and blue. The owner's rule:
/// 「直方图现在 RGB 分别取最高的为 100% 高度，要求共用同一个上限」. These tests pin the arithmetic
/// that makes the three heights comparable: one peak for R/G/B, only the tallest channel reaching the
/// top, and equal counts landing at equal y on every colour.
final class HistogramSharedPeak446Tests: XCTestCase {

    private let binCount = 256
    private let plot = NSRect(x: 0, y: 0, width: 300, height: 58)

    /// A channel with `counts` samples in the named code bins and nothing elsewhere.
    private func channel(_ counts: [Int: Int]) -> HistogramChannel {
        HistogramChannel(bins: (0..<binCount).map { counts[$0] ?? 0 },
                         hdrBins: [],
                         clippedHDR: 0, clippedScreen: 0, clippedBlack: 0)
    }

    private func points(_ channel: HistogramChannel, peak: Int, axis: HistogramAxis) -> [CGPoint] {
        HistogramCardFormat.points(channel, binCount: binCount, axis: axis, peak: peak)
    }

    /// The y of a code bin in the returned path: point 0 is the baseline corner.
    private func y(ofBin bin: Int, in points: [CGPoint]) -> CGFloat {
        points[bin + 1].y
    }

    // MARK: - the shared peak

    /// The fixture from the dispatch: R peaks at 100, G at 50, B at 25 — the shared ceiling is 100,
    /// while the old single-channel entry points keep their per-channel answers.
    func testTheSharedPeakIsTheTallestInteriorBinAcrossChannels() {
        let red = channel([10: 100])
        let green = channel([20: 50])
        let blue = channel([30: 25])

        XCTAssertEqual(HistogramCardFormat.scalePeak([red, green, blue]), 100)
        // The old entry's semantics are unchanged: 5 existing call sites keep their answers.
        XCTAssertEqual(HistogramCardFormat.scalePeak(red), 100)
        XCTAssertEqual(HistogramCardFormat.scalePeak(green), 50)
        XCTAssertEqual(HistogramCardFormat.scalePeak(blue), 25)
    }

    /// Only the channel that owns the shared peak reaches 100 %; the others sit at the fractions of
    /// that same ceiling (50/100 and 25/100).
    func testOnlyTheTallestChannelReachesTheTop() {
        let red = channel([10: 100])
        let green = channel([20: 50])
        let blue = channel([30: 25])
        let axis = HistogramAxis(plot: plot)
        let peak = HistogramCardFormat.scalePeak([red, green, blue])

        let redPoints = points(red, peak: peak, axis: axis)
        let greenPoints = points(green, peak: peak, axis: axis)
        let bluePoints = points(blue, peak: peak, axis: axis)

        let bottom = axis.plot.maxY
        let height = axis.plot.height
        XCTAssertEqual(redPoints.map(\.y).min()!, bottom - height, accuracy: 1e-9)
        XCTAssertEqual(greenPoints.map(\.y).min()!, bottom - height * 0.5, accuracy: 1e-9)
        XCTAssertEqual(bluePoints.map(\.y).min()!, bottom - height * 0.25, accuracy: 1e-9)
    }

    /// The machine-checkable form of "shared ceiling": the same count lands at the same y on all
    /// three curves, whatever colour owns the peak.
    func testTheSameCountMapsToTheSameHeightOnEveryChannel() {
        let red = channel([10: 50, 15: 100])   // owns the shared peak
        let green = channel([20: 50])
        let blue = channel([30: 50])
        let axis = HistogramAxis(plot: plot)
        let peak = HistogramCardFormat.scalePeak([red, green, blue])
        XCTAssertEqual(peak, 100)

        let redY = y(ofBin: 10, in: points(red, peak: peak, axis: axis))
        let greenY = y(ofBin: 20, in: points(green, peak: peak, axis: axis))
        let blueY = y(ofBin: 30, in: points(blue, peak: peak, axis: axis))

        XCTAssertEqual(redY, greenY, accuracy: 1e-9)
        XCTAssertEqual(greenY, blueY, accuracy: 1e-9)
        XCTAssertEqual(redY, axis.plot.maxY - axis.plot.height * 0.5, accuracy: 1e-9)
    }

    /// Reverse control, same file, no product change: scale green by its *own* peak and it reaches
    /// 100 % too. This is what the card used to do for every colour — and why the claim above is not
    /// vacuous.
    func testPerChannelPeakWouldPutGreenAtTheTopAsWell() {
        let green = channel([20: 50])
        let axis = HistogramAxis(plot: plot)
        let ownPeak = HistogramCardFormat.scalePeak(green)
        XCTAssertEqual(ownPeak, 50)

        let greenPoints = points(green, peak: ownPeak, axis: axis)
        XCTAssertEqual(greenPoints.map(\.y).min()!, axis.plot.maxY - axis.plot.height, accuracy: 1e-9)
    }
}
