import XCTest
import Metal
import PhotonsCore

/// 派单 019 — blacks/whites are **linear black/white levels** and belong to S1, not to S2.
///
/// The bug the owner reported: the decoder hands us scene-linear samples that go below zero, exposure
/// is a *multiplicative* gain in S1, and blacks/whites used to be an *affine* remap in S2. Stacked in
/// that order the same pixel gets more negative as exposure rises while the lift `|blk|` stays put, so
/// `blacks +` detail that sat above zero fell back below it at higher exposure and was deleted by S2's
/// final `max(v, 0)`: **the more exposure, the blacker the shadows** (detail lost, not darkened).
///
/// The fix is an order: `v = (v − blk)/max(wht − blk, 1e−3)` runs in S1 *before* the gain, so the gain
/// acts on "brightness relative to the black point" and a pixel's side of the black point no longer
/// depends on exposure. S2 keeps contrast/highlights/shadows and the final clamp.
///
/// The slider mapping is unchanged (`blk = −blacks/100·0.15`, `wht = 1 − whites/100·0.15`), so every
/// number a user has in a document means the same thing it did before.
///
/// What is pinned here, in the order of the spec's table:
///   ① `blacks +` detail survives any exposure (this is the reported bug, and it fails on the old
///     order: the values are printed so the two orders can be compared without re-running anything);
///   ② every pixel is monotone in exposure, on a synthetic sub-black block **and** on a real RAW
///     patch — the criterion that cannot be satisfied by an affine remap downstream of the gain;
///   ③ a pixel's side of the black point is exposure-invariant;
///   ④ `blacks = whites = exposure = 0` is byte-identical to what the pre-019 code produced (the two
///     sha256 values were recorded from that code on the fixture below);
///   ⑤ direction is unchanged: `blacks +100` separates six sub-black bands, `whites ±` brightens and
///     darkens the way it always did.
final class BwLevelsTests: XCTestCase {

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String = "bw-levels") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// A flat scene-linear patch. `value` may be negative: that is the band the decoder really
    /// produces and the only place a black *level* differs from a black *offset*.
    private func flat(_ value: Float, width: Int = 64, height: Int = 32) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = Float16(value)
            rgba[i + 1] = Float16(value)
            rgba[i + 2] = Float16(value)
            rgba[i + 3] = 1
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// Vertical bands, one value each, `bandsPerValue` columns per band.
    private func bands(_ values: [Float], bandsPerValue: Int = 8, height: Int = 32) -> LinearImage {
        let width = values.count * bandsPerValue
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = Float16(values[min(values.count - 1, x / bandsPerValue)])
                let o = (y * width + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    /// Column mean of one band, in display units.
    private func bandMeans(_ image: DisplayImage, bands count: Int) -> [Double] {
        (0..<count).map { band in
            let x = (image.width * (band * 2 + 1)) / (count * 2)
            var sum = 0.0
            for y in 0..<image.height {
                sum += Double(image.rgba[(y * image.width + x) * 4])
            }
            return sum / Double(max(image.height, 1))
        }
    }

    private func meanLuma(_ image: DisplayImage) -> Double {
        var sum = 0.0
        for i in stride(from: 0, to: image.rgba.count, by: 4) {
            sum += (Double(image.rgba[i]) + Double(image.rgba[i + 1]) + Double(image.rgba[i + 2])) / 3
        }
        return sum / Double(max(image.width * image.height, 1))
    }

    /// The real RAW, decoded once at 1/8, cropped to the **darkest** 96×64 patch on a coarse grid.
    ///
    /// The patch is what the test needs: the decoder's own sub-black samples (a synthetic block can only
    /// imitate them) at a size that keeps seventeen renders cheap. The darkest patch is chosen because
    /// that is where the negative samples are — the block means of a bright region average them away, and
    /// a patch without them would make the monotonicity assertion vacuous. How many it found is printed,
    /// so "the raw case was empty" cannot hide behind a green tick. Skips when the fixture is missing,
    /// like every other real-RAW test.
    private func realRawPatch() throws -> LinearImage {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
        }
        let decoded = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                              options: DecodeOptions(decoderVersion: nil, scale: 0.125))
        let w = min(96, decoded.width), h = min(64, decoded.height)
        var best = (x: 0, y: 0, mean: Double.infinity)
        for y0 in stride(from: 0, through: max(0, decoded.height - h), by: 16) {
            for x0 in stride(from: 0, through: max(0, decoded.width - w), by: 16) {
                var sum = 0.0
                for y in stride(from: 0, to: h, by: 4) {
                    for x in stride(from: 0, to: w, by: 4) {
                        let o = ((y0 + y) * decoded.width + (x0 + x)) * 4
                        sum += Double(decoded.rgba[o])
                    }
                }
                if sum < best.mean { best = (x0, y0, sum) }
            }
        }
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let src = ((best.y + y) * decoded.width + (best.x + x)) * 4
                let dst = (y * w + x) * 4
                for c in 0..<4 { rgba[dst + c] = decoded.rgba[src + c] }
            }
        }
        let patch = LinearImage(width: w, height: h, rgba: rgba,
                                colorSpace: decoded.colorSpace, decoderVersion: decoded.decoderVersion)
        var lo = Float.infinity, negatives = 0, samples = 0
        for i in stride(from: 0, to: patch.rgba.count, by: 4) {
            let v = Float(patch.rgba[i])
            lo = min(lo, v)
            if v < 0 { negatives += 1 }
            samples += 1
        }
        print("019 ② raw patch \(w)×\(h) at (\(best.x),\(best.y)) of \(decoded.width)×\(decoded.height): "
              + "min = \(lo), negative samples = \(negatives)/\(samples)")
        return patch
    }

    /// Worst per-pixel decrease of `after` against `before` (display units) and where it happened.
    @discardableResult
    private func worstDecrease(_ after: DisplayImage, _ before: DisplayImage,
                               _ label: String) -> Float {
        var worst: Float = 0
        var where_ = ""
        for y in 0..<after.height {
            for x in 0..<after.width {
                let o = (y * after.width + x) * 4
                for c in 0..<3 {
                    let d = Float(after.rgba[o + c]) - Float(before.rgba[o + c])
                    if d < worst { worst = d; where_ = "(\(x),\(y)) ch\(c)" }
                }
            }
        }
        print("019 monotone \(label): worst decrease = \(worst) at \(where_.isEmpty ? "none" : where_)")
        return worst
    }

    // MARK: - ① exposure must not eat what blacks lifted

    /// The reported bug, at its smallest. `v = −0.01` with `blacks = +10` ⇒ `blk = −0.015`, so the
    /// pixel is *above* the black point and is lifted to `+0.0049` (linear). Exposure then multiplies
    /// it, so 0 / +1 / +2 EV must give three positive, increasing values.
    ///
    /// On the pre-019 order the same three exposure settings give −0.01 → −0.02 → −0.04, all below
    /// the black point, all clamped to 0: the detail is deleted, and the more exposure the blacker.
    func testExposureDoesNotEatDetailLiftedByBlacks() throws {
        let graph = try makeGraph(flat(-0.01))
        var edit = EditModel.neutral
        edit.light.blacks = 10          // blk = −0.015, so −0.01 is above the black point

        var ladder: [(Double, Double)] = []
        for ev in [0.0, 1.0, 2.0] {
            var e = edit
            e.light.exposure = ev
            ladder.append((ev, try XCTUnwrap(Double(Float(try render(graph, e).rgba[0])))))
        }
        print("019 ① blacks +10 on v = −0.01, display output by exposure:")
        for (ev, out) in ladder { print("   \(ev >= 0 ? "+" : "")\(ev) EV → \(out)") }

        for (ev, out) in ladder {
            XCTAssertGreaterThan(out, 0, "exposure \(ev) EV: blacks +10 detail was clamped away")
        }
        for i in 1..<ladder.count {
            XCTAssertGreaterThanOrEqual(ladder[i].1, ladder[i - 1].1,
                                        "output fell from \(ladder[i - 1].1) to \(ladder[i].1)")
        }
    }

    // MARK: - ② monotone in exposure, per pixel

    /// **The criterion the old order cannot meet.** `blacks = +50`, `whites = 0`, exposure from −2 to
    /// +2 EV in ½-stop steps: no pixel may get darker from one step to the next.
    ///
    /// An affine black point *after* the gain adds light only in proportion to nothing — the same
    /// `|blk|` against a value that grew with the gain — so a sub-black pixel crosses from "lifted
    /// above zero" to "clamped" as exposure rises, which is exactly a decrease.
    func testEveryPixelIsMonotoneInExposureOnASyntheticSubBlackBlock() throws {
        let values: [Float] = [-0.04, -0.02, -0.01, -0.005, -0.002, 0, 0.001, 0.02, 0.18]
        let graph = try makeGraph(bands(values))
        var edit = EditModel.neutral
        edit.light.blacks = 50

        var previous: DisplayImage?
        var worstSoFar: Float = 0
        var previousEV = 0.0
        for ev in stride(from: -2.0, through: 2.0, by: 0.5) {
            var e = edit
            e.light.exposure = ev
            let image = try render(graph, e)
            if let p = previous {
                worstSoFar = min(worstSoFar, worstDecrease(image, p, "synthetic, \(previousEV) → \(ev) EV"))
            }
            previous = image
            previousEV = ev
        }
        XCTAssertGreaterThanOrEqual(worstSoFar, -1e-6,
                                    "a pixel darkened as exposure rose: worst \(worstSoFar)")
    }

    /// The same sweep on the decoder's own pixels, so the sub-black band is not a synthetic guess.
    func testEveryPixelIsMonotoneInExposureOnARealRawPatch() throws {
        let patch = try realRawPatch()
        let graph = try makeGraph(patch, identity: "bw-levels-raw")

        var edit = EditModel.neutral
        edit.light.blacks = 50

        var previous: DisplayImage?
        var worstSoFar: Float = 0
        var previousEV = 0.0
        for ev in stride(from: -2.0, through: 2.0, by: 0.5) {
            var e = edit
            e.light.exposure = ev
            let image = try render(graph, e)
            if let p = previous {
                worstSoFar = min(worstSoFar, worstDecrease(image, p, "raw, \(previousEV) → \(ev) EV"))
            }
            previous = image
            previousEV = ev
        }
        XCTAssertGreaterThanOrEqual(worstSoFar, -1e-6,
                                    "a RAW pixel darkened as exposure rose: worst \(worstSoFar)")
    }

    // MARK: - ③ which side of the black point a pixel is on does not move

    /// `blk = −0.015` (`blacks = +10`). Two samples: one below the black point (−0.02) and one above
    /// it (−0.01). Whatever the exposure, the first stays below zero after the level normalisation
    /// (so S2's clamp writes 0) and the second stays above it — the *membership* is a property of the
    /// sample, not of the gain, which is the whole point of doing the levels first.
    func testAPixelsSideOfTheBlackPointDoesNotMoveWithExposure() throws {
        let graph = try makeGraph(bands([-0.02, -0.01], bandsPerValue: 16))
        var edit = EditModel.neutral
        edit.light.blacks = 10
        // Column 0 is inside the −0.02 band, column 31 inside the −0.01 band.
        let below = 0, above = 31

        var rows: [(Double, Double, Double)] = []
        for ev in [-3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0] {
            var e = edit
            e.light.exposure = ev
            let image = try render(graph, e)
            let y = image.height / 2
            rows.append((ev,
                         Double(image.rgba[(y * image.width + below) * 4]),
                         Double(image.rgba[(y * image.width + above) * 4])))
        }
        print("019 ③ side of blk = −0.015 by exposure (v = −0.02 below / −0.01 above):")
        for (ev, b, a) in rows { print("   \(ev) EV → below \(b), above \(a)") }

        for (ev, b, a) in rows {
            XCTAssertEqual(b, 0, accuracy: 1e-6,
                           "exposure \(ev): a below-black sample reached the picture")
            XCTAssertGreaterThan(a, 1e-4, "exposure \(ev): an above-black sample lost its lift")
            XCTAssertLessThan(b, a, "exposure \(ev): the two sides swapped")
        }
    }

    // MARK: - ④ identity

    /// The two sha256 values were recorded from the **pre-019** code (the affine S2 remap) on the
    /// fixture below, and must still hold: with `blacks = whites = 0` a level normalisation is
    /// `(v − 0)/max(1 − 0, 1e−3)`, i.e. an exact division by one, and S2's identity branch keeps
    /// writing the pixel through. Byte identity, not "looks the same".
    ///
    /// A GPU-family change can move these; re-record deliberately and say why, never to make a red
    /// test green.
    private static let pinnedNeutralHash = "496bfbc9bfa7292ab6259d65a1f9817f7669a71df3f851ef7ba5ca9c1615bde8"
    private static let pinnedExposureHash = "efcea998f18e88fa6d09abbbebad3a002e3471acdbd760d7e591e01c56cc59db"

    func testNeutralLevelsAreByteIdenticalToTheRecordedIdentity() throws {
        // Mixed fixture: true black, sub-black, mid-grey, near-white.
        let image = bands([-0.01, 0, 0.001, 0.02, 0.18, 0.5, 0.9, 0.99], bandsPerValue: 8)
        let graph = try makeGraph(image, identity: "bw-levels-identity")

        var neutral = EditModel.neutral
        neutral.light.blacks = 0
        neutral.light.whites = 0
        neutral.light.exposure = 0
        let neutralHash = try render(graph, neutral).sha256()

        var exposure = neutral
        exposure.light.exposure = 1      // S1 takes its maths path, levels still zero
        let exposureHash = try render(graph, exposure).sha256()

        print("019 ④ identity: blacks=whites=exposure=0 → \(neutralHash)")
        print("019 ④ identity: blacks=whites=0, exposure=+1 → \(exposureHash)")

        // Determinism: the same document twice is the same bytes (so the pinned value means something).
        XCTAssertEqual(neutralHash, try render(graph, neutral).sha256())
        XCTAssertEqual(neutralHash, Self.pinnedNeutralHash,
                       "the neutral path moved — blacks/whites at 0 must be the identity")
        XCTAssertEqual(exposureHash, Self.pinnedExposureHash,
                       "zero levels with a gain moved — the normalisation must be exact at 0/1")
    }

    // MARK: - ⑤ direction (派单 008's criterion, unchanged)

    /// Six bands entirely at or below black, `blacks = +100` (`blk = −0.15`): the bands must be
    /// ordered and separated, i.e. the sub-black signal is *lifted*, not clamped.
    func testBlacksPlusSeparatesTheSubBlackStaircaseInSixSteps() throws {
        let values: [Float] = [-0.004, -0.003, -0.002, -0.001, 0.0, 0.001]
        let graph = try makeGraph(bands(values, bandsPerValue: 8))
        var edit = EditModel.neutral
        edit.light.blacks = 100

        let means = bandMeans(try render(graph, edit), bands: 6)
        print("019 ⑤ blacks +100 band means:", means.map { String(format: "%.5f", $0) })

        for i in 1..<means.count {
            XCTAssertGreaterThan(means[i], means[i - 1],
                                 "band \(i) did not separate from band \(i - 1): \(means)")
        }
        XCTAssertGreaterThan(means.last! - means.first!, 0.001,
                             "the staircase collapsed — the sub-black signal is being clamped")
    }

    /// `whites` keeps Lightroom's direction: `+` brightens (pulls the white point in), `−` darkens,
    /// and the series is monotone across the whole range. The white level now also runs before the
    /// gain, so the fixture is checked at a non-zero exposure as well: the order must not flip a sign.
    func testWhitesDirectionIsUnchanged() throws {
        let graph = try makeGraph(flat(0.25))
        func mean(whites: Double, exposure: Double) throws -> Double {
            var edit = EditModel.neutral
            edit.light.whites = whites
            edit.light.exposure = exposure
            return meanLuma(try render(graph, edit))
        }

        for exposure in [0.0, 1.0] {
            let base = try mean(whites: 0, exposure: exposure)
            let up = try mean(whites: 50, exposure: exposure)
            let down = try mean(whites: -50, exposure: exposure)
            print("019 ⑤ whites at exposure \(exposure): +50 = \(up), 0 = \(base), −50 = \(down)")
            XCTAssertGreaterThan(up, base + 0.005, "whites +50 must brighten")
            XCTAssertLessThan(down, base - 0.005, "whites −50 must darken")

            var series: [Double] = []
            for w in stride(from: -100.0, through: 100.0, by: 25.0) {
                series.append(try mean(whites: w, exposure: exposure))
            }
            for i in 1..<series.count {
                XCTAssertGreaterThan(series[i], series[i - 1],
                                     "whites folded at exposure \(exposure): \(series)")
            }
        }
    }

    /// `blacks` and `whites` together stay monotone in each slider at a fixed exposure — the two
    /// levels move opposite ends of the same normalisation, so a sign error in one shows up here.
    func testBlacksAndWhitesStayIndependentAtNonZeroExposure() throws {
        let graph = try makeGraph(flat(0.18))
        func mean(blacks: Double = 0, whites: Double = 0) throws -> Double {
            var edit = EditModel.neutral
            edit.light.blacks = blacks
            edit.light.whites = whites
            edit.light.exposure = 1
            return meanLuma(try render(graph, edit))
        }
        let base = try mean()
        let blacksUp = try mean(blacks: 50), blacksDown = try mean(blacks: -50)
        let whitesUp = try mean(whites: 50), whitesDown = try mean(whites: -50)
        print("019 ⑤ 0.18 at exposure +1: base \(base), blacks +50 \(blacksUp), blacks −50 \(blacksDown), "
              + "whites +50 \(whitesUp), whites −50 \(whitesDown)")
        XCTAssertGreaterThan(blacksUp, base, "blacks + must lift")
        XCTAssertLessThan(blacksDown, base, "blacks − must crush")
        XCTAssertGreaterThan(whitesUp, base, "whites + must brighten")
        XCTAssertLessThan(whitesDown, base, "whites − must darken")
    }
}
