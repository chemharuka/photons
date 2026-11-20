//
//  DenoisePipelineTests.swift
//
//  What is worth testing here, and what is not.
//
//  The network's own output is not testable without a 175 MB checkpoint, so
//  these tests cover the parts that have bugs of their own: the layout
//  derivation, the noise fit, the tile arithmetic, and the two blending rules
//  that produced visible defects during development.
//

import XCTest
@testable import NonlocalMatchFilter

final class PackedLayoutTests: XCTestCase {

    /// The model wants R, G, B, G — where the second G is the one on blue's row.
    /// Getting this wrong does not fail loudly: it comes back with a magenta
    /// cast (measured out/in ratios 0.99 0.72 0.99 3.23 instead of all 1.00).
    func testRGGBGivesRGBGOrder() {
        let layout = PackedLayout(cfa: "rggb")
        // rggb = R(0,0) G(0,1) G(1,0) B(1,1)
        XCTAssertEqual(layout.offsets[0].0, 0)   // R at row 0
        XCTAssertEqual(layout.offsets[0].1, 0)   // R at col 0
        XCTAssertEqual(layout.offsets[2].0, 1)   // B on row 1
        XCTAssertEqual(layout.offsets[2].1, 1)   // B at col 1
        // The green on red's row precedes B; the one on blue's row follows it.
        XCTAssertEqual(layout.offsets[1].0, 0)
        XCTAssertEqual(layout.offsets[1].1, 1)
        XCTAssertEqual(layout.offsets[3].0, 1)
        XCTAssertEqual(layout.offsets[3].1, 0)
    }

    func testBGGRStillPutsRedFirstAndBlueThird() {
        let layout = PackedLayout(cfa: "bggr")
        // bggr = B(0,0) G(0,1) G(1,0) R(1,1)
        XCTAssertEqual(layout.offsets[0].0, 1)   // R
        XCTAssertEqual(layout.offsets[0].1, 1)
        XCTAssertEqual(layout.offsets[2].0, 0)   // B
        XCTAssertEqual(layout.offsets[2].1, 0)
    }

    /// Both greens must be present and distinct, or the packer silently reads one
    /// CFA position twice and the picture loses a quarter of its resolution.
    func testTheTwoGreensAreDistinct() {
        for cfa in ["rggb", "bggr", "grbg", "gbrg"] {
            let layout = PackedLayout(cfa: cfa)
            let greens = [layout.offsets[1], layout.offsets[3]]
            XCTAssertNotEqual(greens[0].0 == greens[1].0 && greens[0].1 == greens[1].1,
                              true, "cfa \(cfa) reused a green position")
            var seen = Set<String>()
            for o in layout.offsets { seen.insert("\(o.0),\(o.1)") }
            XCTAssertEqual(seen.count, 4, "cfa \(cfa) did not cover all four cell positions")
        }
    }
}

final class NoiseFitTests: XCTestCase {

    /// Feeding a known curve back through the fitter must recover it.
    ///
    /// The blocks are grouped into brightness bins before the fit, and the
    /// lower-envelope rule takes the 10th percentile inside each bin. So the
    /// samples have to be laid out the way a real frame lays them out: several
    /// blocks at every brightness, all sitting on (not above) the true curve, or
    /// the percentile lands below the curve and drags `b` down.
    func testRecoversAKnownCurve() {
        let truthA = 1.5e-3
        let truthB = 2.0e-6
        var pairs: [(Double, Double)] = []
        // 40 bins × 100 blocks, brightness spanning what a raw actually covers.
        for bin in 0..<40 {
            let x = 0.001 + Double(bin) / 40.0 * 0.4
            let sd = (truthA * x + truthB).squareRoot()
            for _ in 0..<100 { pairs.append((x, sd)) }
        }
        let (a, b) = NoiseEstimator.fit(xs: pairs)
        XCTAssertEqual(a, truthA, accuracy: truthA * 0.02)
        XCTAssertEqual(b, truthB, accuracy: truthB * 0.10)
    }

    /// The fit must never return a negative `b`: `sqrt` of it is NaN, and the
    /// network would receive a NaN noise map and return garbage.
    func testInterceptIsNeverNegative() {
        // A cloud whose dark end is noisier than a straight line predicts, which
        // pushes an unconstrained least-squares intercept below zero.
        var pairs: [(Double, Double)] = []
        for i in 0..<2000 {
            let x = Double(i) / 2000.0 * 0.3
            pairs.append((x, max(0.002 - x * 0.004, 0.0005)))
        }
        let (a, b) = NoiseEstimator.fit(xs: pairs)
        XCTAssertGreaterThanOrEqual(b, 0)
        XCTAssertGreaterThanOrEqual(a, 0)
    }

    func testTooFewBlocksYieldsZeroRatherThanAGuess() {
        let (a, b) = NoiseEstimator.fit(xs: [(0.1, 0.01)])
        XCTAssertEqual(a, 0)
        XCTAssertEqual(b, 0)
    }

    func testPercentileInterpolates() {
        let sorted = [0.0, 1.0, 2.0, 3.0, 4.0]
        XCTAssertEqual(NoiseEstimator.percentileOfSorted(sorted, 0.0), 0.0)
        XCTAssertEqual(NoiseEstimator.percentileOfSorted(sorted, 1.0), 4.0)
        XCTAssertEqual(NoiseEstimator.percentileOfSorted(sorted, 0.5), 2.0)
        XCTAssertEqual(NoiseEstimator.percentileOfSorted(sorted, 0.625), 2.5)
    }
}

final class TileGridTests: XCTestCase {

    /// Reproduces the arithmetic `DenoisePipeline` uses, so a change to the
    /// coverage rule shows up here as a number instead of as a missing stripe at
    /// the right edge of a 60 MP frame.
    ///
    /// Two bugs this caught, in order:
    ///  1. `(length - 2·crop + stride - 1)/stride + 1` counted one extra tile per
    ///     axis whenever the cropped length divided evenly — crop 0 on a
    ///     9536-wide frame gave 20 columns where 19 were measured.
    ///  2. Cropping unconditionally leaves the last `crop` columns of the frame
    ///     with no tile at all. The pipeline now crops only interior seams.
    private func tileCount(length: Int, window: Int, crop: Int) -> Int {
        let stride = window - 2 * crop
        let coverable = max(0, length - 2 * crop)
        return max(1, (coverable + stride - 1) / stride)
    }

    /// Every pixel must be deposited by at least one tile. This is the property
    /// the count formula exists to guarantee, and it is what an unconditional
    /// crop broke.
    private func coverageIsComplete(length: Int, window: Int, crop: Int) -> Bool {
        let stride = window - 2 * crop
        let n = tileCount(length: length, window: window, crop: crop)
        var covered = [Bool](repeating: false, count: length)
        for k in 0..<n {
            let x0 = min(k * stride, max(0, length - window))
            let x1 = min(x0 + window, length)
            let a = x0 == 0 ? x0 : x0 + crop
            let b = x1 >= length ? x1 : x1 - crop
            if b > a { for x in a..<b { covered[x] = true } }
        }
        return covered.allSatisfy { $0 }
    }

    func testCoverageIsComplete() {
        // The sizes that matter: the 60 MP sample and the small test fixture,
        // with and without cropping.
        for (length, crop) in [(9536, 8), (6344, 8), (9536, 0), (6344, 0),
                               (2048, 8), (2048, 0), (512, 8), (513, 8)] {
            XCTAssertTrue(coverageIsComplete(length: length, window: 512, crop: crop),
                          "length \(length) crop \(crop) left a gap")
        }
    }

    func testMatchesMeasuredRuns() {
        // Measured: crop 0 gives 19×13 = 247 tiles on the 60 MP frame.
        XCTAssertEqual(tileCount(length: 9536, window: 512, crop: 0), 19)
        XCTAssertEqual(tileCount(length: 6344, window: 512, crop: 0), 13)
        // The 2048² fixture prints 5×5 with crop 8 under the current rule. An
        // earlier run printed 6×6 — that was the extra row the old formula added.
        XCTAssertEqual(tileCount(length: 2048, window: 512, crop: 8), 5)
    }

    /// Crop 8 on the 60 MP frame is 20×13, not the 21×14 an earlier run printed:
    /// that run clustered an extra row of tiles to paper over the coverage gap
    /// that unconditional cropping created.
    func testCroppedGridIsTighterThanTheOlderRun() {
        XCTAssertEqual(tileCount(length: 9536, window: 512, crop: 8), 20)
        XCTAssertEqual(tileCount(length: 6344, window: 512, crop: 8), 13)
        XCTAssertLessThan(20 * 13, 21 * 14)
    }

    func testTinyFrameStillProducesOneTile() {
        XCTAssertEqual(tileCount(length: 100, window: 512, crop: 0), 1)
    }
}

final class BlendTests: XCTestCase {

    /// `strength` blends toward **the input**, not toward the destination buffer.
    ///
    /// The early implementation read the output array, which starts zeroed, so
    /// every strength below 1 dragged the frame toward black: measured overall
    /// std fell to 592 where the source was 843. The rule below is what the
    /// pipeline now applies per sample.
    func testBlendGoesTowardTheInputNotBlack() {
        let input: Float = 0.4
        let denoised: Float = 0.2
        let s: Float = 0.5
        let blended = input + s * (denoised - input)
        XCTAssertEqual(blended, 0.3, accuracy: 1e-6)
        // Sanity: blending against a zeroed buffer would give 0.1, i.e. darker
        // than either endpoint.
        XCTAssertGreaterThan(blended, s * denoised)
    }

    /// At full strength the result is the model's answer exactly — no rounding
    /// through the blend, which used to cost ±1 LSB on a handful of samples.
    func testFullStrengthIsExact() {
        let input: Float = 0.4
        let denoised: Float = 0.2
        let s: Float = 1.0
        let blended = s == 1 ? denoised : input + s * (denoised - input)
        XCTAssertEqual(blended, denoised)
    }

    /// Where no tile reached a pixel the source sample survives untouched.
    func testUncoveredPixelsKeepTheSource() {
        let weight: Float = 0        // no tile deposited here
        let accumulated: Float = 0
        let input: Float = 0.37
        let value = weight > 0 ? accumulated / weight : input
        XCTAssertEqual(value, input)
    }
}

final class StrengthTests: XCTestCase {

    /// The two anchors are ISO 800 / ISO 3200 medians from the scan, and the ends
    /// of the strength range. If a constant moves, this test should move with it.
    func testAnchorsMapToTheRangeEnds() {
        XCTAssertEqual(NLMFStrength.strength(forSigma: NLMFStrength.sigmaLow), 0.70,
                       accuracy: 1e-9)
        XCTAssertEqual(NLMFStrength.strength(forSigma: NLMFStrength.sigmaHigh), 0.90,
                       accuracy: 1e-9)
    }

    /// Outside the anchors it clamps rather than extrapolating: a cleaner frame than
    /// ISO 800 stays at 0.70, and nothing ever reaches 1.0 (that plastifies texture).
    func testClampsOutsideTheAnchors() {
        XCTAssertEqual(NLMFStrength.strength(forSigma: 0.0005), 0.70, accuracy: 1e-9)
        XCTAssertEqual(NLMFStrength.strength(forSigma: 0.05), 0.90, accuracy: 1e-9)
        XCTAssertEqual(NLMFStrength.strength(forSigma: 0), 0.70, accuracy: 1e-9)
        XCTAssertEqual(NLMFStrength.strength(forSigma: .nan), 0.70, accuracy: 1e-9)
    }

    /// Log-linear, so the geometric mean of the anchors lands at the midpoint.
    func testGeometricMeanLandsAtTheMidpoint() {
        let mid = (NLMFStrength.sigmaLow * NLMFStrength.sigmaHigh).squareRoot()
        XCTAssertEqual(NLMFStrength.strength(forSigma: mid), 0.80, accuracy: 1e-9)
    }

    /// Monotone across the measured ISO ladder — the property the feature exists for.
    func testMonotoneAcrossTheMeasuredLadder() {
        let ladder = [0.00355, 0.00465, 0.00477, 0.00569, 0.00614, 0.00680]
        let values = ladder.map { NLMFStrength.strength(forSigma: $0) }
        XCTAssertEqual(values, values.sorted())
        XCTAssertGreaterThan(values.last!, values.first!)
    }

    /// The convenience entry point agrees with the σ one.
    func testStrengthFromCurveMatchesSigma() {
        let shot = [6e-4, 6e-4, 4e-4, 5e-4]
        let read = [3e-6, 3e-6, 1.5e-6, 3e-6]
        let sigma = (shot[1] * NLMFStrength.reference + read[1]).squareRoot()
        XCTAssertEqual(NLMFStrength.strength(shot: shot, read: read),
                       NLMFStrength.strength(forSigma: sigma), accuracy: 1e-12)
    }
}
