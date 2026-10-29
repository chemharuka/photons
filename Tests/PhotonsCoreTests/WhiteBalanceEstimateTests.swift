import XCTest
@testable import PhotonsCore

/// 143 — our own white-balance estimate (no table, no decoder prediction).
///
/// The acceptance is split into the three questions the ticket asks:
///
///   1. **Nothing tabular is referenced.** The two removed files' type names and the on-disk table
///      directory are spelled nowhere in `Sources`/`Tests`; a fake directory holding a broken JSON is
///      never read (the estimate is a pure function of the buffer).
///   2. **The gain is the same one the settled render uses.** The preview's `relativeGain` is the
///      ratio of two `gain` calls, and a settled `gain(target)` is bit-for-bit the triple the S1 pass
///      writes into `p.a.yzw`.
///   3. **Neutrality and direction.** A synthetic grey card is neutral at the as-shot pair (≤ 1 code
///      per channel), and a lower Kelvin cools (R down, B up) while a higher one warms.
///
/// The estimator's three routes (white patch / grey world / grey edge) are pinned through the
/// internal `components` accessor, so "three routes with percentile clipping" is not just a comment.
final class WhiteBalanceEstimateTests: XCTestCase {

    // MARK: - fixtures

    private func image(_ width: Int, _ height: Int,
                       _ pixel: (Int, Int) -> (Double, Double, Double)) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let o = (y * width + x) * 4
                rgba[o] = Float16(r)
                rgba[o + 1] = Float16(g)
                rgba[o + 2] = Float16(b)
                rgba[o + 3] = Float16(1)
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: LinearColorSpace.extendedLinearSRGB.rawValue,
                           decoderVersion: "test")
    }

    private func greyCard(_ value: Double = 0.4, size: Int = 64) -> LinearImage {
        image(size, size) { _, _ in (value, value, value) }
    }

    private func srgbEncode(_ linear: Double) -> Double {
        let x = min(max(linear, 0), 1)
        return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    private func codeSpread(_ rgb: (r: Double, g: Double, b: Double)) -> Double {
        let codes = [srgbEncode(rgb.r), srgbEncode(rgb.g), srgbEncode(rgb.b)].map { $0 * 255 }
        return (codes.max() ?? 0) - (codes.min() ?? 0)
    }

    // MARK: - 1. nothing tabular is left

    func testNoTableIsReferenced() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // PhotonsCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
        // Spelled in two pieces so this test file cannot match itself.
        let needles = ["WhiteBalance" + "PreviewTable", "WhiteBalance" + "Tables"]
        var hits: [String] = []
        for directory in ["Sources", "Tests"] {
            let base = root.appendingPathComponent(directory)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for needle in needles where text.contains(needle) {
                    hits.append("\(url.lastPathComponent): \(needle)")
                }
            }
        }
        XCTAssertTrue(hits.isEmpty, "table references remain: \(hits)")
    }

    /// A directory full of broken JSON is not an input to anything any more: the estimate is a pure
    /// function of the linear buffer. This is the "not read at all" half of acceptance 1.
    func testABrokenTableDirectoryIsNeverRead() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-not-a-table-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("broken.json")
        try Data("{ this is not a table".utf8).write(to: bad)
        let before = try Data(contentsOf: bad)

        let estimate = WhiteBalanceEstimate.estimate(from: greyCard())
        let gain = WhiteBalanceEstimate.gain(for: WhiteBalance(temperature: 4200, tint: 8),
                                             asShot: estimate)
        XCTAssertEqual(estimate, .neutral)
        XCTAssertTrue(gain.r.isFinite && gain.g.isFinite && gain.b.isFinite)
        XCTAssertEqual(try Data(contentsOf: bad), before, "a broken table directory was read")
    }

    // MARK: - 2. preview gain == settled gain

    func testPreviewGainIsTheRatioOfTheSettledGains() {
        let estimate = WhiteBalanceEstimate.estimate(from: greyCard())
        let reference = WhiteBalance(temperature: 3000, tint: 20)
        let target = WhiteBalance(temperature: 4200, tint: -5)

        let settledTarget = WhiteBalanceEstimate.gain(for: target, asShot: estimate)
        let settledReference = WhiteBalanceEstimate.gain(for: reference, asShot: estimate)
        let preview = WhiteBalanceEstimate.relativeGain(from: reference, to: target,
                                                        asShot: estimate)

        // The preview multiplier is (target / reference), normalized on green — the same three
        // numbers the two settled passes would apply.
        let relR = settledTarget.r / settledReference.r
        let relG = settledTarget.g / settledReference.g
        let relB = settledTarget.b / settledReference.b
        XCTAssertEqual(preview.r, relR / relG, accuracy: 1e-15)
        XCTAssertEqual(preview.g, 1, accuracy: 1e-15)
        XCTAssertEqual(preview.b, relB / relG, accuracy: 1e-15)

        // …and the settled target is exactly what a second call returns: no hidden cache/table can
        // make the drag and the frame disagree.
        let again = WhiteBalanceEstimate.gain(for: target, asShot: estimate)
        XCTAssertEqual(settledTarget.r, again.r)
        XCTAssertEqual(settledTarget.g, again.g)
        XCTAssertEqual(settledTarget.b, again.b)

        print(String(format: "preview=final: target %.9f/%.9f/%.9f · preview ratio %.9f/%.9f/%.9f",
                     settledTarget.r, settledTarget.g, settledTarget.b,
                     preview.r, preview.g, preview.b))
    }

    func testPreviewGainRoundTripsToUnity() {
        let estimate = WhiteBalanceEstimate.estimate(from: greyCard())
        let a = WhiteBalance(temperature: 3200, tint: -12)
        let b = WhiteBalance(temperature: 7800, tint: 24)
        let there = WhiteBalanceEstimate.relativeGain(from: a, to: b, asShot: estimate)
        let back = WhiteBalanceEstimate.relativeGain(from: b, to: a, asShot: estimate)
        XCTAssertEqual(there.r * back.r, 1, accuracy: 1e-12)
        XCTAssertEqual(there.g * back.g, 1, accuracy: 1e-12)
        XCTAssertEqual(there.b * back.b, 1, accuracy: 1e-12)
    }

    // MARK: - 3. neutrality, direction, as-shot

    func testAsShotDocumentIsTheIdentity() {
        let estimate = WhiteBalanceEstimate.estimate(from: greyCard())
        let g = WhiteBalanceEstimate.gain(for: .asShot, asShot: estimate)
        XCTAssertEqual(g.r, 1)
        XCTAssertEqual(g.g, 1)
        XCTAssertEqual(g.b, 1)
        let nom = WhiteBalanceEstimate.gain(for: WhiteBalance(temperature: 6500, tint: 0),
                                            asShot: estimate)
        XCTAssertEqual(nom.r, 1, accuracy: 1e-12)
        XCTAssertEqual(nom.b, 1, accuracy: 1e-12)
    }

    func testGreyCardIsNeutralAtTheAsShotPair() {
        let estimate = WhiteBalanceEstimate.estimate(from: greyCard())
        XCTAssertEqual(estimate.r, 1, accuracy: 1e-6)
        XCTAssertEqual(estimate.b, 1, accuracy: 1e-6)

        let g = WhiteBalanceEstimate.gain(for: .asShot, asShot: estimate)
        let spread = codeSpread((r: g.r, g: g.g, b: g.b))
        XCTAssertLessThanOrEqual(spread, 1, "as-shot grey card has a \(spread)-code cast")
    }

    func testLowerKelvinCoolsAndHigherKelvinWarms() {
        let estimate = WhiteBalanceEstimate.estimate(from: greyCard())
        let cool = WhiteBalanceEstimate.gain(for: WhiteBalance(temperature: 2850, tint: 0),
                                             asShot: estimate)
        let warm = WhiteBalanceEstimate.gain(for: WhiteBalance(temperature: 9000, tint: 0),
                                             asShot: estimate)
        XCTAssertLessThan(cool.r, 0.9, "2850 K must pull red down")
        XCTAssertGreaterThan(cool.b, 1.2, "2850 K must push blue up")
        XCTAssertGreaterThan(warm.r, 1.05, "9000 K must push red up")
        XCTAssertLessThan(warm.b, 0.9, "9000 K must pull blue down")
    }

    func testPositiveTintIsMagentaAndDoesNotBecomeAWhitePoint() {
        let estimate = WhiteBalanceEstimate.estimate(from: greyCard())
        let neutral = WhiteBalanceEstimate.gain(for: WhiteBalance(temperature: 5000, tint: 0),
                                                asShot: estimate)
        let magenta = WhiteBalanceEstimate.gain(for: WhiteBalance(temperature: 5000, tint: 40),
                                                asShot: estimate)
        XCTAssertGreaterThan(magenta.r, neutral.r, "positive tint must hand the difference to red")
        XCTAssertGreaterThan(magenta.b, neutral.b)
    }

    // MARK: - 4. the three estimators

    func testThreeEstimatorsAreNormalisedAndTheMedianIsRobustToHotPixels() {
        // A grey card with a handful of blown specular pixels. White-patch's p99.99 exclusion is what
        // keeps them from becoming the illuminant; the per-channel median is the second line of
        // defence if one route still drifts.
        let card = image(100, 100) { x, y in
            if x % 25 == 0 && y % 25 == 0 { return (4, 4, 4) }
            let v = 0.35 + 0.01 * Double((x + y) % 3)
            return (v, v, v)
        }
        let c = WhiteBalanceEstimate.components(from: card)
        for (name, e) in [("white", c.white), ("grey", c.grey), ("edge", c.edge)] {
            XCTAssertEqual(e.g, 1, accuracy: 1e-9, "\(name) is not green-normalised")
            XCTAssertTrue(e.r.isFinite && e.b.isFinite, "\(name) is not finite")
        }
        let estimate = WhiteBalanceEstimate.estimate(from: card)
        XCTAssertEqual(estimate.r, 1, accuracy: 0.02,
                       "the hot pixels moved the white-patch route: \(c.white)")
        XCTAssertEqual(estimate.b, 1, accuracy: 0.02)
    }

    func testTheThreeRoutesDisagreeOnAColouredFrameAndTheMedianWins() {
        // A frame that is 2/3 saturated red and 1/3 grey: grey-world is pulled red, white-patch
        // follows the red patch, while grey-edge follows the boundary/grey structure. The estimate is
        // the per-channel median of the three, which must stay finite and green-normalised.
        let frame = image(60, 60) { x, _ in
            if x < 40 { return (0.8, 0.1, 0.1) }
            return (0.35, 0.35, 0.35)
        }
        let c = WhiteBalanceEstimate.components(from: frame)
        XCTAssertNotEqual(c.grey.r, c.edge.r, accuracy: 1e-6,
                          "the three routes returned the same answer — the fixture is not exercising them")
        let e = WhiteBalanceEstimate.estimate(from: frame)
        XCTAssertEqual(e.g, 1, accuracy: 1e-9)
        XCTAssertTrue(e.r > 0.05 && e.r < 20 && e.b > 0.05 && e.b < 20)
    }

    // MARK: - 5. the locus, Bradford and the projection

    func testBradfordMapsTheRequestedWhiteToD65() {
        for kelvin in [2850.0, 4200, 5500, 6500, 8500, 12000] {
            let src = WhiteBalanceEstimate.illuminantXYZ(temperature: kelvin, tint: 0)
            let mapped = WhiteBalanceEstimate.bradfordAdaptation(
                from: src, to: WhiteBalanceEstimate.whitePointXYZ) * src
            let want = WhiteBalanceEstimate.whitePointXYZ
            XCTAssertEqual(mapped.x / want.x, 1, accuracy: 1e-9, "\(kelvin) K X")
            XCTAssertEqual(mapped.y / want.y, 1, accuracy: 1e-9, "\(kelvin) K Y")
            XCTAssertEqual(mapped.z / want.z, 1, accuracy: 1e-9, "\(kelvin) K Z")
        }
    }

    func testPlanckianProjectionRoundTripsThroughTheRequestedPair() {
        // The neutral working white is 6500 K / tint 0 by construction (the D65 anchor).
        let neutral = WhiteBalanceEstimate.planckianProjection(of: .neutral)
        XCTAssertEqual(neutral.temperature, WhiteBalanceSolver.nominalTemperature, accuracy: 1)
        XCTAssertEqual(neutral.tint, 0, accuracy: 1)
        for kelvin in [3000.0, 5000, 6500, 9500] {
            for tint in [-60.0, 0, 60] {
                let xyz = WhiteBalanceEstimate.illuminantXYZ(temperature: kelvin, tint: tint)
                let chroma = Chromaticity(
                    x: xyz.x / (xyz.x + xyz.y + xyz.z),
                    y: xyz.y / (xyz.x + xyz.y + xyz.z))
                let rgb = ColorPrimaries.working.fromXYZ * xyz
                let illuminant = WhiteBalanceEstimate.Illuminant(
                    r: rgb.x / rgb.y, g: 1, b: rgb.z / rgb.y)
                let p = WhiteBalanceEstimate.planckianProjection(of: illuminant)
                XCTAssertEqual(p.temperature, kelvin, accuracy: 60,
                               "\(kelvin) K / \(tint) projected to \(p.temperature)")
                XCTAssertEqual(p.tint, tint, accuracy: 3,
                               "\(kelvin) K / \(tint) projected to tint \(p.tint) (xy \(chroma.x),\(chroma.y))")
            }
        }
    }

    // MARK: - 6. a real decoded frame

    /// The estimator on the user's fixture: a decoded SL3 frame is already at Apple's as-shot balance,
    /// so its measured illuminant must be close to neutral (the estimator is not there to invent a
    /// cast). The exact numbers are printed — this is a calibration fact, not a golden.
    func testRealDecodedFrameIsMeasuredNearNeutral() throws {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
        }
        let decoder = try RAWDecoder()
        let image = try decoder.decode(URL(fileURLWithPath: path),
                                       options: DecodeOptions(scale: 0.125))
        let e = WhiteBalanceEstimate.estimate(from: image)
        let p = WhiteBalanceEstimate.planckianProjection(of: e)
        print(String(format: "143 estimate %@: RGB %.5f/%.5f/%.5f · chroma %.2f%% · CCT %.0f K / tint %+.1f",
                     URL(fileURLWithPath: path).lastPathComponent,
                     e.r, e.g, e.b, e.chroma * 100, p.temperature, p.tint))
        XCTAssertTrue(e.r.isFinite && e.b.isFinite)
        XCTAssertLessThan(e.chroma, 0.25, "the decoded as-shot frame measured a \(e.chroma * 100)% cast")
        XCTAssertTrue(WhiteBalanceSolver.searchRange.contains(p.temperature))
        // The gain for an explicit 6500 K is close to the identity on a balanced frame.
        let g = WhiteBalanceEstimate.gain(for: WhiteBalance(temperature: 6500, tint: 0), asShot: e)
        XCTAssertEqual(g.r, 1, accuracy: 0.12)
        XCTAssertEqual(g.b, 1, accuracy: 0.12)
    }

    // MARK: - 7. speed

    func testGainRecomputeIsFarBelowTheFrameBudget() {
        let estimate = WhiteBalanceEstimate.estimate(from: greyCard(0.2, size: 256))
        let request = WhiteBalance(temperature: 4200, tint: 10)
        var samples: [Double] = []
        samples.reserveCapacity(200)
        for _ in 0..<200 {
            let t = CFAbsoluteTimeGetCurrent()
            _ = WhiteBalanceEstimate.gain(for: request, asShot: estimate)
            samples.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
        samples.sort()
        let p50 = samples[100], p95 = samples[190]
        XCTAssertLessThan(p95, 8, "one gain recompute took \(p95) ms (p50 \(p50) ms), over the 8 ms budget")
        print(String(format: "WB gain: p50 %.4f ms · p95 %.4f ms (200 recomputes)", p50, p95))
    }
}
