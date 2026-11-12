import XCTest
import PhotonsCore

/// 385 — the histogram's code axis is **Rec.2020**, not sRGB.
///
/// The bug 385 fixes is a *basis* bug, not an arithmetic one. `Histogram.measure` used to convert the
/// scene-linear sample from the working primaries (Rec.2020) into sRGB before counting. sRGB is a
/// **strict subset** of Rec.2020, so the conversion is not a re-encoding of colours both spaces have:
/// on the Rec.2020 green/cyan side it produces **negative** components (`Rec2020 (0,1,1) → sRGB` has
/// R = −0.6577), and `binIndex` files every value ≤ 0 into bin 0. A photograph full of saturated
/// greens and cyans therefore read as "1.96 % of the picture is pure black in red" — measured on
/// `L1030552` with the library's own edit, R bin 0 = 12288 through the sRGB matrix and 2 without it.
///
/// What is pinned here, one test per gate in the派单 (docs/tasks/385-histogram-rec2020.md §3):
///
///   · **③ a saturated Rec.2020 colour does not reach bin 0.** A cyan-family sample keeps its own
///     positive red, and a green-family one its own positive red and blue; under the sRGB matrix all
///     of those components are strongly negative. This is the assertion the reverse gate bites on.
///   · **④ the white point does not move.** Linear 1.0 is still the last SDR bin — both bases agree
///     that white is 1.0, which is why the axis needed no rescaling.
///   · **⑤ the highlight tail does not move.** It is stops of *linear light*, so no basis enters it;
///     4 stops (16× white) is still the last tail bin.
///   · **⑥ `primaries` says `.rec2020`** for a scene-linear measurement, and still reports the
///     `DisplayImage`'s own tag for an encoded one (those codes were written by S4's matrix).
///
/// Plus the property that makes all of the above one change rather than several: **the components
/// counted are the sample's own.** A pixel brighter than white on one channel sits in the tail at
/// `log2` of *its* value, not at `log2` of a matrix-mixed one.
final class HistogramBasisTests: XCTestCase {

    // MARK: - fixtures

    private func linear(_ width: Int, _ height: Int,
                        _ rgb: (Float, Float, Float)) -> LinearSample {
        var rgba = [Float16](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = Float16(rgb.0)
            rgba[i * 4 + 1] = Float16(rgb.1)
            rgba[i * 4 + 2] = Float16(rgb.2)
        }
        return LinearSample(width: width, height: height, rgba: rgba)
    }

    /// The bin a **linear** value lands in on the SDR code axis — `binIndex(srgbEncode(v))`, written
    /// out here so the expectation is the published definition and not a copy of the implementation's
    /// internals.
    private func codeBin(_ v: Float, bins: Int = 256) -> Int {
        let code = Histogram.srgbEncode(v)
        let scaled = code * Float(bins)
        if scaled >= Float(bins) { return bins - 1 }
        if !(scaled > 0) { return 0 }
        return Int(scaled)
    }

    /// Where a linear value above white lands in the 1/64-stop tail.
    private func tailBin(_ v: Float) -> Int {
        Int(log2(v) * Float(Histogram.hdrBinsPerStop))
    }

    private func occupied(_ bins: [Int]) -> [Int] {
        bins.enumerated().filter { $0.element > 0 }.map(\.offset)
    }

    // MARK: - ③ the basis: a Rec.2020 colour keeps its own components

    /// Rec.2020's cyan corner with the least red a real photograph of that colour would carry. Through
    /// the sRGB matrix the red is **−0.627** (`1.6605·0.02 − 0.5876·1 − 0.0728·1`) and lands in bin 0;
    /// on its own basis it is 0.02 and lands at `srgbEncode(0.02)·256 ≈ 38`. The 16 pixels are all in
    /// bin 0 before the fix, which is exactly the pile-up the user reported, in miniature.
    func testASaturatedRec2020CyanKeepsItsOwnRed() {
        let n = 16
        let hist = Histogram.compute(linear(4, 4, (0.02, 1.0, 1.0)))

        XCTAssertEqual(hist.red.bins[0], 0,
                       "a cyan pixel has positive red of its own; bin 0 means the sRGB matrix turned "
                       + "it negative (measured: −0.627)")
        let bin = codeBin(0.02)
        XCTAssertEqual(hist.red.bins[bin], n, "all \(n) pixels at the sample's own red, bin \(bin)")
        XCTAssertEqual(occupied(hist.red.bins), [bin])
    }

    /// The same claim on the green corner, where **two** channels are outside sRGB: Rec.2020 green
    /// gives sRGB R = −0.51 and B = −0.08 for this fixture. Both must land on their own values.
    func testASaturatedRec2020GreenKeepsItsOwnRedAndBlue() {
        let n = 16
        let hist = Histogram.compute(linear(4, 4, (0.03, 0.95, 0.04)))

        XCTAssertEqual(hist.red.bins[0], 0, "R would be −0.51 through the sRGB matrix")
        XCTAssertEqual(hist.blue.bins[0], 0, "B would be −0.08 through the sRGB matrix")
        XCTAssertEqual(hist.red.bins[codeBin(0.03)], n)
        XCTAssertEqual(hist.blue.bins[codeBin(0.04)], n)
        XCTAssertEqual(occupied(hist.green.bins), [codeBin(0.95)])
    }

    /// The corner itself: Rec.2020 `(0, 1, 1)` has **R = 0**, and 0 is black on any axis — bin 0 is
    /// the right answer there and stays the right answer (385 does not change `binIndex`'s "≤ 0 goes
    /// to bin 0" rule). Pinned so that the fix cannot be read as "cyan must not be in bin 0 at all".
    func testTheExactRec2020CyanCornerHasZeroRedWhichIsBinZero() {
        let hist = Histogram.compute(linear(4, 4, (0.0, 1.0, 1.0)))
        XCTAssertEqual(hist.red.bins[0], 16, "R = 0 is black, not a negative")
        XCTAssertEqual(hist.green.bins[255], 16)
        XCTAssertEqual(hist.blue.bins[255], 16)
    }

    /// The components are the sample's own, above white too: `log2` of *its* value, not of a mixed one.
    /// Through the sRGB matrix this sample's red would be 2.36 (tail bin 79) instead of 1.5 (bin 37).
    func testTheTailIsLogTwoOfTheSamplesOwnComponents() {
        let hist = Histogram.compute(linear(4, 4, (1.5, 0.2, 0.2)))
        XCTAssertEqual(hist.red.hdrBins[tailBin(1.5)], 16)
        XCTAssertEqual(hist.red.hdrBins.reduce(0, +), 16, "one tail bin occupied, the sample's own")
        XCTAssertEqual(tailBin(1.5), 37)
    }

    // MARK: - ④ the white point does not move

    func testWhiteIsStillTheLastSDRBin() {
        let n = 64
        let hist = Histogram.compute(linear(8, 8, (1.0, 1.0, 1.0)))
        for channel in Histogram.Channel.allCases {
            XCTAssertEqual(hist[channel].bins[255], n, "\(channel): 1.0 is white on either basis")
            XCTAssertEqual(hist[channel].bins[254], 0, "\(channel): nothing spilled below white")
            XCTAssertEqual(hist[channel].hdrTotal, 0, "\(channel): white is not in the tail")
            XCTAssertEqual(hist[channel].clippedHigh, 1, "\(channel): 1.0 still counts as clipped high")
        }
        XCTAssertEqual(hist.primaries, .rec2020)
    }

    // MARK: - ⑤ the highlight tail does not move

    func testFourStopsIsStillTheLastTailBin() {
        let n = 16
        let fourStops = Histogram.compute(linear(4, 4, (16, 16, 16)))
        for channel in Histogram.Channel.allCases {
            XCTAssertEqual(fourStops[channel].hdrBins.last, n,
                           "\(channel): 16× white (4 stops) is the last tail bin")
            XCTAssertEqual(fourStops[channel].hdrBins.dropLast().reduce(0, +), 0,
                           "\(channel): everything at or past 4 stops piles onto the last bin")
            XCTAssertEqual(fourStops[channel].bins.reduce(0, +), 0, "\(channel): nothing in the SDR half")
        }

        // The tail is 1/64 stop, so 2× (one stop) and 4× (two stops) are named bins, and neither
        // depends on a primaries basis — this is the check that the axis' *geometry* is untouched.
        XCTAssertEqual(Histogram.compute(linear(2, 2, (2, 2, 2))).red.hdrBins[64], 4)
        XCTAssertEqual(Histogram.compute(linear(2, 2, (4, 2, 2))).red.hdrBins[128], 4)
    }

    // MARK: - ⑥ the label follows the pixels

    func testASceneLinearMeasurementReportsRec2020() {
        XCTAssertEqual(Histogram.compute(linear(2, 2, (0.5, 0.5, 0.5))).primaries, .rec2020)
        XCTAssertEqual(Histogram.compute(LinearSample(width: 2, height: 2,
                                                      rgba: [Float16](repeating: 0.5, count: 16)))
                        .primaries, .rec2020)
    }

    /// An **encoded** sample's codes were written by S4's primaries matrix, so its label is whatever
    /// the texture said — the histogram must not relabel pixels it did not convert.
    func testAnEncodedMeasurementKeepsItsOwnTag() {
        var rgba = [Float16](repeating: 1, count: 16)
        for i in 0..<4 { rgba[i * 4] = 0.5; rgba[i * 4 + 1] = 0.25; rgba[i * 4 + 2] = 0.75 }
        for primaries in [OutputPrimaries.sRGB, .displayP3, .rec2020] {
            let image = DisplayImage(width: 2, height: 2, rgba: rgba, primaries: primaries, bitDepth: 8)
            XCTAssertEqual(Histogram.computeEncoded(image).primaries, primaries)
        }
    }

    // MARK: - the measurement as a whole

    /// A picture made only of wide-gamut colour has **nothing** in bin 0 on any channel, while staying
    /// a picture whose clipping ratios are ordinary — the two numbers that told the user something was
    /// wrong were R bin 0 and R `clippedLow`, and both are quiet here.
    func testAWideGamutPictureHasNoNegativeComponentAtAll() {
        let w = 64, h = 4
        var rgba = [Float16](repeating: 1, count: w * h * 4)
        let colours: [(Float, Float, Float)] = [(0.02, 1.0, 1.0), (0.03, 0.95, 0.04),
                                                (0.05, 0.9, 0.1), (0.5, 0.95, 0.02)]
        for i in 0..<(w * h) {
            let c = colours[i % colours.count]
            rgba[i * 4] = Float16(c.0)
            rgba[i * 4 + 1] = Float16(c.1)
            rgba[i * 4 + 2] = Float16(c.2)
        }
        let hist = Histogram.compute(LinearSample(width: w, height: h, rgba: rgba))
        XCTAssertEqual(hist.sampleCount, w * h)
        for channel in Histogram.Channel.allCases {
            XCTAssertEqual(hist[channel].bins[0], 0, "\(channel): no pixel was made negative")
            XCTAssertEqual(hist[channel].clippedLow, 0, "\(channel): nothing reads as clipped low")
        }
        XCTAssertEqual(hist.primaries, .rec2020)
    }
}
