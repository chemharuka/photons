import XCTest
import Metal
import PhotonsCore

/// 派单 073B — blacks/whites are **end points**, not levels: a pure multiplicative EV at the dark end
/// (±3 EV, a 7 EV toe) and EV + a small level at the white end, both weighted by an EV window so the
/// mid-tones are outside the knee.
///
/// **What changed, and therefore which assertions changed** (the old file pinned 019's *level*
/// semantics; every rewrite below is a semantic difference, not a re-recorded number):
///
/// | old assertion (019) | new assertion (073B) | why the old one is gone |
/// |---|---|---|
/// | ① `blacks +10` lifts `v = −0.01` above zero, so exposure does not eat it | ① the same lift is **positive-scaled by the exposure** and never crosses zero: `blacks` is multiplicative, so `−0.01` stays negative | a pure gain cannot manufacture grey at 0 or below; pulling sub-black back across zero is 071's `blackOffset`, not the blacks slider |
/// | ② no pixel darkens as exposure rises | ② unchanged, and now true by construction (`v·gain` then `·2^k`) | — |
/// | ③ a pixel's side of `blk = −0.015` never moves | ③ **deleted**: there is no black point to be on a side of | the affine level is gone from the slider path |
/// | ④ neutral/pinned hashes | ④ unchanged, plus "the knee entry at 0/0 is bit-identical to the default entry" | the default path must stay byte-identical (074/073 acceptance 1) |
/// | ⑤ `blacks +100` separates a six-step **sub-black** staircase in the display image | ⑤ `blacks +100` separates six **shadow** bands (code 0.01…0.18) and leaves code ≥ 0.29 bit-identical | sub-black bands are all clamped by S2; a multiplier keeps their *order* but not their visibility |
///
/// The numbers are measured on the **shipped kernel**, compiled here (`MetalKernelHarness`), and on the
/// four reference frames of the contract (`~/Desktop/test/L10304*.dng`), so nothing below is quoted.
final class BwLevelsTests: XCTestCase {

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String = "bw-levels") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// A flat scene-linear patch. `value` may be negative: that is the band the decoder really
    /// produces, and the only place a black *end point* differs from a black *offset*.
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

    // MARK: - the real frames

    /// The four reference frames of the contract, decoded at 1/8 and handed to the kernel as float32.
    /// Skips (like every other real-RAW test) when the fixtures are missing.
    private static let frames = ["L1030402", "L1030405", "L1030408", "L1030433"]

    static func frameURL(_ name: String) -> URL? {
        let candidates = [
            name + ".dng",
            NSString(string: "~/Desktop/test/\(name).dng").expandingTildeInPath,
        ]
        guard let hit = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }
        return URL(fileURLWithPath: hit)
    }

    private struct Frame {
        let name: String
        let width: Int, height: Int
        let rgba: [Float]
        /// Luma percentiles 1/5/20/30/50/70/90/95/99, in EV relative to display white.
        let ev: [Double]
        let code: [Double]

        func luma(_ percentiles: [Double]) -> [Double] { percentiles.map { $0 } }
    }

    private static let percentiles = [0.01, 0.05, 0.2, 0.3, 0.5, 0.7, 0.9, 0.95, 0.99]

    private func loadFrames() throws -> [Frame] {
        var out: [Frame] = []
        for name in Self.frames {
            guard let url = Self.frameURL(name) else { continue }
            let img = try RAWDecoder().decode(url, options: DecodeOptions(decoderVersion: nil, scale: 0.125))
            var px = [Float](repeating: 0, count: img.rgba.count)
            var lumas: [Double] = []
            lumas.reserveCapacity(img.width * img.height)
            for i in stride(from: 0, to: px.count, by: 4) {
                for c in 0..<4 { px[i + c] = Float(img.rgba[i + c]) }
                lumas.append(0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2]))
            }
            lumas.sort()
            let ev = Self.percentiles.map { p -> Double in
                let v = lumas[min(lumas.count - 1, Int(p * Double(lumas.count - 1)))]
                return log2(max(v, 1e-12))
            }
            let code = ev.map { Self.code(Self.evToLinear($0)) }
            out.append(Frame(name: name, width: img.width, height: img.height, rgba: px,
                             ev: ev, code: code))
        }
        if out.isEmpty { throw XCTSkip("no RAW fixtures; set PHOTONS_TEST_RAW or copy L10304*.dng to ~/Desktop/test") }
        return out
    }

    /// `2^L`: a scene-linear value from an EV position (display white = 0 EV).
    static func evToLinear(_ L: Double) -> Double { pow(2, L) }

    /// sRGB code 0…255 of a linear value (the contract's 8-bit yardstick).
    static func code(_ v: Double) -> Double {
        let x = max(v, 0)
        let e = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return e * 255
    }

    // MARK: - ① the default path is byte-identical

    /// The two sha256 values were recorded from the **pre-019** code, so they are the strongest form of
    /// "the default path did not move": the neutral path (identity branch) and the same document with
    /// `exposure = +1` (S1's maths path, levels at 0/1).
    ///
    /// 073B adds the second half: the **knee** entry point, which production picks as soon as
    /// `blacks != 0 || whites != 0`, is bit-identical to the default entry when both are 0. There is no
    /// `if (blacks != 0)` in either of them — the arithmetic is either in the compiled function or it is
    /// not (071's lesson), and this is the assertion that the "not" case really is the old bytes.
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

        print("073B ① identity: blacks=whites=exposure=0 → \(neutralHash)")
        print("073B ① identity: blacks=whites=0, exposure=+1 → \(exposureHash)")

        // Determinism: the same document twice is the same bytes (so the pinned value means something).
        XCTAssertEqual(neutralHash, try render(graph, neutral).sha256())
        XCTAssertEqual(neutralHash, Self.pinnedNeutralHash,
                       "the neutral path moved — blacks/whites at 0 must be the identity")
        XCTAssertEqual(exposureHash, Self.pinnedExposureHash,
                       "zero levels with a gain moved — S1's default arithmetic must not have changed")
    }

    /// The knee entry point at `blacks = whites = 0` writes the same bytes as the default entry: no new
    /// arithmetic leaks into the default path even when the CPU picks the "new" function.
    func testTheKneeEntryIsBitIdenticalToTheDefaultEntryAtZero() throws {
        let harness = try MetalKernelHarness()
        var values: [Float] = [-0.02, -0.001, 0, 1e-6, 0.002, 0.01, 0.05, 0.18, 0.5, 1.0, 3.0]
        var v: Float = 1e-6
        while v < 4 { values.append(v); v *= 1.05 }

        let plain = try harness.run(values, blacks: 0, whites: 0, entry: .default)
        let knee = try harness.run(values, blacks: 0, whites: 0, entry: .knee)
        for i in 0..<values.count {
            XCTAssertEqual(plain[i].bitPattern, knee[i].bitPattern,
                           "sample \(values[i]): the knee entry moved a pixel at 0/0")
        }
        print("073B ① knee entry at 0/0: \(values.count) samples, all bit-identical to the default entry")
    }

    // MARK: - ② the knee's outside is bit-identical (the "strictly no mid-tone" claim)

    /// `blacks = ±100` must not touch anything at or above the knee's end (−4.2 EV = code 0.29) and
    /// `whites = ±100` must not touch anything at or below its start (−2 EV = code 0.537). Bit-equal,
    /// not "less than 1 %": inside those regions the weight is exactly 0, `exp2(0) = 1` and `v·1 + 0`
    /// is `v`.
    func testTheKneeLeavesEverythingOutsideItBitIdentical() throws {
        let harness = try MetalKernelHarness()
        let blackOutside: [Float] = [0.30, 0.35, 0.5, 0.75, 1.0, 2.0, 4.0]   // code ≥ 0.30, i.e. L > −4.2
        let whiteOutside: [Float] = [-0.01, 0, 0.001, 0.05, 0.15, 0.25]      // code ≤ 0.537, i.e. L < −2

        for slider in [100.0 as Float, -100] {
            let out = try harness.run(blackOutside, blacks: slider, whites: 0)
            for (i, v) in blackOutside.enumerated() {
                XCTAssertEqual(out[i].bitPattern, v.bitPattern,
                               "blacks \(slider) moved \(v) — that is above the knee")
            }
            let w = try harness.run(whiteOutside, blacks: 0, whites: slider)
            for (i, v) in whiteOutside.enumerated() {
                XCTAssertEqual(w[i].bitPattern, v.bitPattern,
                               "whites \(slider) moved \(v) — that is below the white knee")
            }
        }
        print("073B ② blacks ±100: \(blackOutside.count) samples above the knee unchanged · "
              + "whites ±100: \(whiteOutside.count) samples below it unchanged")
    }

    // MARK: - ③ monotone: min d(log2 v')/d(log2 v) over the whole axis

    /// The owner's criterion ("the darkest part must never come out brighter than the mid-tones") as a
    /// number: `d(log2 v′)/d(log2 v) > 0.3` on a geometric grid from 1e−6 to 16, for both sliders at
    /// both ends and for the two sliders together.
    ///
    /// It is a *closed form* here: `v′ = v·2^(B·Δ·w(L))` with `w` a smoothstep over 7 EV, so
    /// `slope = 1 + B·Δ·w′(L)` and the worst case is the middle of the toe: `1 − 3.0·1.5/7.0 = 0.357`.
    /// The measured numbers are printed; the assertion is `> 0.30` (the contract's threshold, §6-7).
    func testTheKneeIsMonotoneInTheWholeAxis() throws {
        let harness = try MetalKernelHarness()
        var grid: [Float] = []
        var v: Float = 1e-6
        while v <= 16 { grid.append(v); v *= 1.02 }

        var rows: [(String, Double, Double)] = []
        for (label, blacks, whites) in [("blacks +100", 100.0 as Float, 0.0 as Float),
                                        ("blacks +50", 50, 0), ("blacks -50", -50, 0),
                                        ("blacks -100", -100, 0),
                                        ("whites +100", 0, 100), ("whites +50", 0, 50),
                                        ("whites -50", 0, -50), ("whites -100", 0, -100),
                                        ("both +100", 100, 100), ("both -100", -100, -100)] {
            let out = try harness.run(grid, blacks: blacks, whites: whites)
            var worst = Double.infinity
            var at: Float = 0
            for i in 0..<(grid.count - 1) {
                let dy = log2(Double(max(out[i + 1], 1e-30))) - log2(Double(max(out[i], 1e-30)))
                let dx = log2(Double(grid[i + 1])) - log2(Double(grid[i]))
                let s = dy / dx
                if s < worst { worst = s; at = grid[i] }
            }
            rows.append((label, worst, Self.code(Double(at)) / 255))
        }
        print("073B ③ min d(log2 v')/d(log2 v), grid 1e−6…16 step 1.02:")
        for (label, slope, code) in rows {
            print(String(format: "   %-12@ min %+.3f at code %.3f", label as NSString, slope, code))
            XCTAssertGreaterThan(slope, 0.30, "\(label) folds the map: min slope \(slope) at code \(code)")
        }
        // The endpoint really is ±3 EV: `blacks = +100` at the very bottom.
        let bottom = try harness.run([1e-6, 1e-4], blacks: 100, whites: 0)
        for (i, source) in [1e-6, 1e-4].enumerated() {
            let gain = log2(Double(bottom[i]) / source)
            XCTAssertEqual(gain, 3.0, accuracy: 0.01, "blacks +100 must be +3 EV at the bottom")
        }
    }

    // MARK: - ④ the affected band on real frames (p1…p99)

    /// Where the lift actually lands, measured on the four reference frames: `blacks = +100` is an EV
    /// gain on the darkest 1–5 %, a fraction of a stop at p20, and **exactly zero** at the median —
    /// which is what "an end point, not a global gain" means numerically (the old affine moved the
    /// median by +25 code and 100 % of the pixels, contract §4.4).
    ///
    /// The `p1` column is a `3.00` on a frame whose p1 sits below −14 EV: the travel is the *endpoint*
    /// gain, and a real frame's darkest percentile is 1.8–3.0 EV of it, not 3. Given a 3 EV travel, a
    /// p50 that does not move **and** a slope above 0.3 cannot all hold for the same pixel band — the
    /// slope budget forces the toe to be ≥ 4.5/0.7 = 6.4 EV wide, and a toe that wide cannot be at full
    /// weight at p5 while being at zero at p50 (they are 2.9 EV apart). The design keeps the owner's
    /// hard constraints (monotone, no plastic toe) and gives up "p5 = +3 EV".
    func testBlacksIsAnEVGainAtTheDarkEndAndZeroAtTheMedian() throws {
        let frames = try loadFrames()
        let harness = try MetalKernelHarness()

        // One dispatch for every percentile value of every frame: the map is a function of the value.
        var probes: [Float] = []
        for f in frames { probes += f.ev.map { Float(Self.evToLinear($0)) } }
        let lifted = try harness.run(probes, blacks: 100, whites: 0)
        let lowered = try harness.run(probes, blacks: -100, whites: 0)
        let codeOut = lifted.map { Self.code(Double($0)) }
        let codeLow = lowered.map { Self.code(Double($0)) }

        print("073B ④ blacks ±100 on the four reference frames (EV gain / Δ8-bit code):")
        var base = 0
        for f in frames {
            var row = "   \(f.name)"
            for (k, p) in Self.percentiles.enumerated() {
                let j = base + k
                let v = Self.evToLinear(f.ev[k])
                let gain = log2(Double(max(lifted[j], 1e-12)) / v)
                let low = log2(Double(max(lowered[j], 1e-12)) / v)
                row += String(format: "  p%.0f %+.2f/%+.0f (down %+.2f/%+.0f)",
                              p * 100, gain, codeOut[j] - f.code[k], low, codeLow[j] - f.code[k])
            }
            print(row)
            // The median is outside the knee by construction: exactly zero, not "small".
            let gain50 = log2(Double(max(lifted[base + 4], 1e-12)) / Self.evToLinear(f.ev[4]))
            XCTAssertLessThanOrEqual(abs(gain50), 0.02, "\(f.name): blacks +100 moved the median")
            XCTAssertLessThanOrEqual(abs(codeOut[base + 4] - f.code[4]), 1.0,
                                     "\(f.name): the median moved by more than one 8-bit code")
            if f.ev[4] > -4.2 { XCTAssertEqual(gain50, 0, accuracy: 1e-6,
                                              "\(f.name): a median above the knee must be bit-still") }
            base += Self.percentiles.count
        }

        // p5 gets a real lift (0.7…1.0 EV measured — the contract's 1.5 EV design measured 0.84…1.01),
        // p20 a small one, and nothing at the median. Bands, not exact numbers: the four frames differ.
        base = 0
        for f in frames {
            let p5 = log2(Double(max(lifted[base + 1], 1e-12)) / Self.evToLinear(f.ev[1]))
            let p20 = log2(Double(max(lifted[base + 2], 1e-12)) / Self.evToLinear(f.ev[2]))
            XCTAssertGreaterThan(p5, 0.5, "\(f.name): blacks +100 must lift p5")
            XCTAssertLessThan(p5, 1.6, "\(f.name): p5 is in the toe, not at full travel")
            XCTAssertLessThan(p20, 0.5, "\(f.name): p20 must be near the end of the knee")
            base += Self.percentiles.count
        }

        // Nothing that is already black may become grey, and nothing may go negative.
        for (j, v) in probes.enumerated() {
            XCTAssertGreaterThanOrEqual(lowered[j], 0, "blacks −100 made a sample negative")
        }
        let crush = try harness.run([0, 1e-6, 1e-4, 0.001], blacks: -100, whites: 0)
        XCTAssertEqual(crush[0], 0, "blacks −100 must keep true black at black")
        for v in crush.dropFirst() { XCTAssertGreaterThan(v, 0, "a positive sample was zeroed by blacks −100") }
    }

    /// `whites = ±100` on the same frames: the white point moves (p99 by +3…+27 code, p95 by 0…+8),
    /// the median does not move at all. The frames with a low white end (405/408) get less — that is the
    /// honest cost of a **fixed** anchor, which the owner chose over image adaptation (073 拍板 5).
    func testWhitesMovesTheWhitePointAndLeavesTheMedianAlone() throws {
        let frames = try loadFrames()
        let harness = try MetalKernelHarness()
        var probes: [Float] = []
        for f in frames { probes += f.ev.map { Float(Self.evToLinear($0)) } }
        let up = try harness.run(probes, blacks: 0, whites: 100)
        let down = try harness.run(probes, blacks: 0, whites: -100)

        print("073B ⑤ whites ±100: 8-bit Δ at p99 / p95 / p50")
        var i = 0
        for f in frames {
            let p99 = Self.code(Double(up[i + 8])) - f.code[8]
            let p95 = Self.code(Double(up[i + 7])) - f.code[7]
            let p50 = Self.code(Double(up[i + 4])) - f.code[4]
            let d99 = Self.code(Double(down[i + 8])) - f.code[8]
            print(String(format: "   %@ p99 %+.0f / %+.0f   p95 %+.0f   p50 %+.0f",
                         f.name as NSString, p99, d99, p95, p50))
            XCTAssertGreaterThanOrEqual(p99, 2.5, "\(f.name): whites +100 must be visible at p99")
            XCTAssertLessThanOrEqual(d99, -2.5, "\(f.name): whites −100 must be visible at p99")
            XCTAssertEqual(p50, 0, accuracy: 0.5, "\(f.name): whites +100 moved the median")
            i += Self.percentiles.count
        }
    }

    // MARK: - ⑤ direction (派单 008's criterion, still Lightroom's)

    /// Six shadow bands, `blacks = +100`: the bands must stay ordered and **separated**, and the code
    /// above the knee must be untouched. Replaces 019's sub-black staircase (see the table at the top):
    /// with a multiplier a sub-black band stays sub-black, and S2's clamp — not this slider — is what
    /// deletes it.
    func testBlacksPlusSeparatesTheShadowStaircaseInSixSteps() throws {
        let values: [Float] = [0.0005, 0.001, 0.002, 0.004, 0.008, 0.016]
        let graph = try makeGraph(bands(values, bandsPerValue: 8))
        var edit = EditModel.neutral
        edit.light.blacks = 100

        let means = bandMeans(try render(graph, edit), bands: 6)
        print("073B ⑤ blacks +100 band means:", means.map { String(format: "%.5f", $0) })
        for i in 1..<means.count {
            XCTAssertGreaterThan(means[i], means[i - 1],
                                 "band \(i) did not separate from band \(i-1): \(means)")
        }
        XCTAssertGreaterThan(means.last! - means.first!, 0.02,
                             "the staircase collapsed — the toe is not separating the shadows")
    }

    /// `whites` keeps Lightroom's direction: `+` brightens (moves the white point), `−` darkens, and
    /// the series is monotone across the whole travel. The fixture is a **bright** patch now: at
    /// `code ≤ 0.537` the white knee is exactly zero (that is the point of 073B), so `flat(0.25)` — the
    /// old fixture — would measure nothing at all.
    func testWhitesDirectionIsUnchanged() throws {
        // code 0.70 / −1.15 EV: inside the white knee and far enough from display white that a +100
        // travel does not clip (the old fixture was `flat(0.25)`, which is 0 weight now).
        let graph = try makeGraph(flat(0.45))
        func mean(whites: Double, exposure: Double) throws -> Double {
            var edit = EditModel.neutral
            edit.light.whites = whites
            edit.light.exposure = exposure
            return meanLuma(try render(graph, edit))
        }

        for exposure in [0.0, 0.25] {
            let base = try mean(whites: 0, exposure: exposure)
            let up = try mean(whites: 50, exposure: exposure)
            let down = try mean(whites: -50, exposure: exposure)
            print("073B ⑤ whites at exposure \(exposure): +50 = \(up), 0 = \(base), −50 = \(down)")
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

    /// `blacks` and `whites` are different ends of the same picture and must not be aliases: on a dark
    /// patch only `blacks` moves, on a bright patch only `whites`. (019's version asserted both on
    /// 0.18 — which is now outside both knees, by design.)
    func testBlacksAndWhitesTouchDifferentEndsAtNonZeroExposure() throws {
        let dark = try makeGraph(flat(0.01), identity: "bw-dark")       // −6.6 EV: inside the black knee
        let bright = try makeGraph(flat(0.45), identity: "bw-bright")   // −1.15 EV: inside the white knee
        func mean(_ g: RenderGraph, blacks: Double = 0, whites: Double = 0) throws -> Double {
            var edit = EditModel.neutral
            edit.light.blacks = blacks
            edit.light.whites = whites
            edit.light.exposure = 0.25   // +0.25 EV: the bright patch stays below display white
            return meanLuma(try render(g, edit))
        }
        let darkBase = try mean(dark)
        XCTAssertGreaterThan(try mean(dark, blacks: 50), darkBase, "blacks + must lift the dark end")
        XCTAssertLessThan(try mean(dark, blacks: -50), darkBase, "blacks − must crush the dark end")
        XCTAssertEqual(try mean(dark, whites: 100), darkBase, accuracy: 1e-6,
                       "whites must not touch a −6.6 EV patch")

        let brightBase = try mean(bright)
        XCTAssertGreaterThan(try mean(bright, whites: 50), brightBase, "whites + must brighten the top")
        XCTAssertLessThan(try mean(bright, whites: -50), brightBase, "whites − must darken the top")
        XCTAssertEqual(try mean(bright, blacks: 100), brightBase, accuracy: 1e-6,
                       "blacks must not touch a −1.15 EV patch")
    }

    // MARK: - ⑥ cost

    /// The contract's acceptance 10: the whole model must stay inside the texture-copy bandwidth. One
    /// pass over a 2560×1600 float32 frame (4.10 Mpx), median of 40, default entry vs knee entry. A
    /// *budget*, not a benchmark: the assertion is loose enough for a loaded machine, and the measured
    /// number is printed so a regression is visible in the log.
    func testTheKneeCostsNothingOnAFullFrame() throws {
        let w = 2560, h = 1600
        var px = [Float](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            let t = Float(i) / Float(px.count)
            px[i] = t; px[i + 1] = t; px[i + 2] = t; px[i + 3] = 1
        }
        let harness = try MetalKernelHarness()
        let base = try harness.time(px, width: w, height: h, blacks: 0, whites: 0, entry: .default)
        let knee = try harness.time(px, width: w, height: h, blacks: 100, whites: 100, entry: .knee)
        print(String(format: "073B ⑥ 4.10 Mpx S1 pass: default %.3f ms, knee %.3f ms, Δ %+.3f ms",
                     base, knee, knee - base))
        XCTAssertLessThan(knee - base, 0.5, "the knee pass must stay inside the copy's bandwidth")
    }
}

// MARK: - the harness: the shipped kernel, compiled here

/// Compiles the **real** `s1_scene_linear.metal` (the file in the repo, not a copy) in the test process
/// and feeds it float32 pixels, so the assertions above are about the arithmetic the app runs.
///
/// float32 textures (the product pipeline is float16) because this measures the maths, not half-float
/// quantisation. `S1Params` is mirrored field for field — Metal and Swift share no declaration, so a
/// field that drifts shows up as a number, and the stride assertion catches the gross case.
struct MetalKernelHarness {
    enum Entry { case `default`, knee, trim, kneeTrim, levels, levelsTrim, auto }

    struct Params {
        var a: SIMD4<Float>   // gain, wbR, wbG, wbB
        var b: SIMD4<Float>   // recovery, identity, blacks, whites
        var c: SIMD4<Float>   // contentOrigin.xy, contentSize.xy
        var d: SIMD4<Float>   // blackLevel, whiteLevel, hasBlack, hasWhite
        var e: SIMD4<Float>   // 071: blackOffset, pad, pad, pad
    }

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PhotonsCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root

    let device: MTLDevice
    let queue: MTLCommandQueue
    private var pipelines: [String: MTLComputePipelineState] = [:]

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        self.device = device
        let url = Self.repoRoot.appendingPathComponent("Sources/PhotonsCore/Kernels/s1_scene_linear.metal")
        let source = try String(contentsOf: url, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        for name in ["s1_scene_linear", "s1_scene_linear_knee", "s1_scene_linear_trim",
                     "s1_scene_linear_knee_trim", "s1_scene_linear_levels",
                     "s1_scene_linear_levels_trim"] {
            guard let fn = library.makeFunction(name: name) else {
                throw XCTSkip("\(name) is not in the shipped source")
            }
            pipelines[name] = try device.makeComputePipelineState(function: fn)
        }
        guard let q = device.makeCommandQueue() else { throw XCTSkip("no command queue") }
        self.queue = q
        XCTAssertEqual(MemoryLayout<Params>.stride, 80, "S1Params' mirror must be as wide as Metal's")
    }

    private func entryName(_ entry: Entry, blacks: Float, whites: Float) -> String {
        switch entry {
        case .default: return "s1_scene_linear"
        case .knee: return "s1_scene_linear_knee"
        case .trim: return "s1_scene_linear_trim"
        case .kneeTrim: return "s1_scene_linear_knee_trim"
        case .levels: return "s1_scene_linear_levels"
        case .levelsTrim: return "s1_scene_linear_levels_trim"
        case .auto: return blacks != 0 || whites != 0 ? "s1_scene_linear_knee" : "s1_scene_linear"
        }
    }

    /// Grey samples in, grey samples out (the red channel; all three are the same value).
    func run(_ values: [Float], blacks: Float, whites: Float, gain: Float = 1,
             recovery: Float = 0, offset: Float = 0, entry: Entry = .auto) throws -> [Float] {
        var source = [Float]()
        for v in values { source += [v, v, v, 1] }
        let out = try execute(source: source, width: values.count, height: 1, gain: gain,
                              blacks: blacks, whites: whites, recovery: recovery, offset: offset,
                              entry: entry, levels: nil)
        return stride(from: 0, to: out.count, by: 4).map { out[$0] }
    }

    /// A whole frame (RGBA float32) in, the same shape out.
    func runFrame(_ source: [Float], width: Int, height: Int,
                  blacks: Float, whites: Float) throws -> [Float] {
        try execute(source: source, width: width, height: height, gain: 1, blacks: blacks,
                    whites: whites, recovery: 0, offset: 0, entry: .auto, levels: nil)
    }

    private func execute(source: [Float], width: Int, height: Int, gain: Float,
                         blacks: Float, whites: Float, recovery: Float, offset: Float,
                         entry: Entry, levels: (black: Float, white: Float)?) throws -> [Float] {
        let name = entryName(entry, blacks: blacks, whites: whites)
        let pso = try XCTUnwrap(pipelines[name])
        let src = try texture(width: width, height: height)
        let dst = try texture(width: width, height: height)
        source.withUnsafeBytes { buf in
            src.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: buf.baseAddress!, bytesPerRow: width * 16)
        }
        var p = Params(a: SIMD4(gain, 1, 1, 1),
                       b: SIMD4(recovery, 0, blacks, whites),
                       c: SIMD4(0, 0, Float(width), Float(height)),
                       d: SIMD4(levels?.black ?? 0, levels?.white ?? 1,
                                levels == nil ? 0 : 1, levels == nil ? 0 : 1),
                       e: SIMD4(offset, 0, 0, 0))
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else {
            throw XCTSkip("no command buffer")
        }
        enc.setComputePipelineState(pso)
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: min(pso.maxTotalThreadsPerThreadgroup, 32),
                                                           height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertEqual(cb.status, .completed, "the S1 dispatch did not complete")

        var out = [Float](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { buf in
            dst.getBytes(buf.baseAddress!, bytesPerRow: width * 16,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return out
    }

    /// Median GPU time of a **pass** — `runs` dispatches batched into one command buffer, so the
    /// wall-clock floor of a single submit (≈1.5 ms on this machine) does not swamp a 0.4 ms kernel.
    /// This is the same instrument the contract's standalone probe used (`probe_oetf_cost.swift`).
    func time(_ source: [Float], width: Int, height: Int, blacks: Float, whites: Float,
              entry: Entry, batches: Int = 30, perBatch: Int = 20) throws -> Double {
        let name = entryName(entry, blacks: blacks, whites: whites)
        let pso = try XCTUnwrap(pipelines[name])
        let src = try texture(width: width, height: height)
        let dst = try texture(width: width, height: height)
        source.withUnsafeBytes { buf in
            src.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: buf.baseAddress!, bytesPerRow: width * 16)
        }
        var p = Params(a: SIMD4(1, 1, 1, 1), b: SIMD4(0, 0, blacks, whites),
                       c: SIMD4(0, 0, Float(width), Float(height)), d: SIMD4(0, 0, 0, 0),
                       e: SIMD4(0, 0, 0, 0))
        var samples: [Double] = []
        for _ in 0..<batches {
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            for _ in 0..<perBatch {
                let enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
                enc.setComputePipelineState(pso)
                enc.setTexture(src, index: 0)
                enc.setTexture(dst, index: 1)
                enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
                enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(pso.maxTotalThreadsPerThreadgroup, 32),
                                                                   height: 1, depth: 1))
                enc.endEncoding()
            }
            let start = DispatchTime.now().uptimeNanoseconds
            cb.commit()
            cb.waitUntilCompleted()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(perBatch))
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    private func texture(width: Int, height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                                                         width: width, height: height,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw XCTSkip("no texture") }
        return t
    }
}
