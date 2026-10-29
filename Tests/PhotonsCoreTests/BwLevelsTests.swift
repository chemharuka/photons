import XCTest
import Metal
import CryptoKit
@testable import PhotonsCore

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
    /// 073C's fingerprints of the **first half** of the travel, over
    /// `testTheHybridJoinsTheKneeEntryBitIdentically`'s grid (449 samples each).
    ///
    /// These are *073B's own bytes*: they were produced by the pre-073C `s1_scene_linear.metal` (the
    /// file at `HEAD` before this change) compiled standalone and fed the same grid, and the changed
    /// file reproduces them exactly — through both the `knee` and the `hybrid` instantiations. A move
    /// here means the pure-EV half of the travel moved, which 073C promises it did not.
    private static let pinnedBlacks25 = "d0a8e72f53132394b9e1afb7a1699836439eb3f2967c5d095f178e70aa798126"   // blacks +25
    private static let pinnedBlacks50 = "61c02d807a45d115e3c51157f2a4594728b0ae44f6c6d4322fe8d2af1280fcae"   // blacks +50
    private static let pinnedBlacksMinus25 = "4f5480da98c40d3c2d16ec7dc764e69bf5e4b13364c053ffa63472cb8d15bc3d"   // blacks −25
    private static let pinnedBlacksMinus50 = "1733c173f62d5098c54215d197883f5e1cb9af163c7958db4971cc14122d15d9"   // blacks −50

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
    /// both ends **of the EV half** and for the two sliders together.
    ///
    /// It is a *closed form* here: `v′ = v·2^(B·Δ·w(L))` with `w` a smoothstep over 7 EV, so
    /// `slope = 1 + B·Δ·w′(L)` and the worst case is the middle of the toe: `1 − 3.0·1.5/7.0 = 0.357`.
    /// The measured numbers are printed; the assertion is `> 0.30` (the contract's threshold, §6-7).
    ///
    /// 073C: only `|blacks| ≤ 50` is in this list. Beyond that the travel adds a level move, whose foot
    /// is *by construction* the region the slider flattened — that one is measured (and excluded from
    /// the slope criterion the same way) in `testTheHybridIsMonotoneOutsideItsFoot`.
    func testTheKneeIsMonotoneInTheWholeAxis() throws {
        let harness = try MetalKernelHarness()
        var grid: [Float] = []
        var v: Float = 1e-6
        while v <= 16 { grid.append(v); v *= 1.02 }

        var rows: [(String, Double, Double)] = []
        for (label, blacks, whites) in [("blacks +50", 50.0 as Float, 0.0 as Float),
                                        ("blacks +25", 25, 0), ("blacks -25", -25, 0),
                                        ("blacks -50", -50, 0),
                                        ("whites +100", 0, 100), ("whites +50", 0, 50),
                                        ("whites -50", 0, -50), ("whites -100", 0, -100),
                                        ("both +50", 50, 50), ("both -50", -50, -50)] {
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
        // The first half of the travel really is EV, and the travel is ±3 EV at the end of *that*
        // half: `blacks = ±50` at the very bottom.
        let bottom = try harness.run([1e-6, 1e-4], blacks: 50, whites: 0)
        let down = try harness.run([1e-6, 1e-4], blacks: -50, whites: 0)
        for (i, source) in [1e-6, 1e-4].enumerated() {
            XCTAssertEqual(log2(Double(bottom[i]) / source), 1.5, accuracy: 0.01,
                           "blacks +50 must be +1.5 EV at the bottom (half of the ±3 EV travel)")
            XCTAssertEqual(log2(Double(down[i]) / source), -1.5, accuracy: 0.01,
                           "blacks −50 must be −1.5 EV at the bottom")
        }
    }

    // MARK: - ④ the four travels on the real frames (p1/p5/p20/p50, crush, slope)

    /// The curve table the owner asked for: `a = 0.25 / 0.5 / 0.75 / 1`, each sign, on the four
    /// reference frames — the EV gain and the 8-bit Δ at p1/p5/p20, and what happens to the **median**,
    /// which must not move at all (073B's invariant, kept by 073C: both the EV toe and the level's
    /// window are exactly 0 above −4.2 EV, so a median above it is bit-still, not "small").
    ///
    /// What the table is supposed to show, in one line per travel:
    ///   · `a ≤ 0.5`  — the EV half only, and the numbers are 073B's (the entry point is 073B's too);
    ///   · `a > 0.5`  — the EV half shrinks towards 1.5 EV while the level takes over: `+` floats the
    ///     black point, `−` crushes the darkest band to exactly 0;
    ///   · p50 is 0 everywhere, which is the difference between an end point and a global gain (the old
    ///     affine moved the median by +25 code and 100 % of the pixels, contract §4.4).
    ///
    /// The `crush` column is real pixels: every pixel of the frame is run through the shipped kernel
    /// and counted at exactly 0 (`zeros`), together with how many were 0 on the way in (`zerosIn`) so
    /// the number cannot be read as "the frame was black already".
    func testTheFourTravelsOnTheReferenceFrames() throws {
        let frames = try loadFrames()
        let harness = try MetalKernelHarness()
        let travels: [(String, Float)] = [("+25", 25), ("+50", 50), ("+75", 75), ("+100", 100),
                                          ("−25", -25), ("−50", -50), ("−75", -75), ("−100", -100)]

        // One dispatch for every percentile value of every frame: the map is a function of the value.
        var probes: [Float] = []
        for f in frames { probes += f.ev.map { Float(Self.evToLinear($0)) } }

        print("073C ④ the four travels on the four reference frames "
              + "(EV gain at p1/p5/p20, Δ8-bit code at p50, crush share):")
        for (label, blacks) in travels {
            let out = try harness.run(probes, blacks: blacks, whites: 0)
            var row = String(format: "   blacks %-5@", label as NSString)
            var base = 0
            var crushTotal = 0, pixelsTotal = 0
            for f in frames {
                let gains = [1, 5, 20].map { k -> Double in
                    log2(Double(max(out[base + Self.percentileIndex(k)], 1e-12)) / Self.evToLinear(f.ev[Self.percentileIndex(k)]))
                }
                let d50 = Self.code(Double(out[base + 4])) - f.code[4]
                row += String(format: " | %@ %+.2f/%+.2f/%+.2f p50 %+.1f",
                              f.name.suffix(3) as NSString, gains[0], gains[1], gains[2], d50)

                // The whole frame, for the crush share: a *crushed* pixel is one that had light and
                // came out exactly 0. Pixels that were already 0 are counted separately (`zerosIn`)
                // so the number cannot be inflated by a frame that is black in places.
                let pixels = try harness.runFrame(f.rgba, width: f.width, height: f.height,
                                                  blacks: blacks, whites: 0)
                var zeros = 0
                for i in stride(from: 0, to: pixels.count, by: 4) {
                    if pixels[i] == 0 && f.rgba[i] > 0 { zeros += 1 }
                }
                crushTotal += zeros
                pixelsTotal += f.width * f.height
                base += Self.percentiles.count
            }
            print(row + String(format: "  crush %.2f%%", 100.0 * Double(crushTotal) / Double(max(pixelsTotal, 1))))

            // The median of every frame, at every travel. `blacks ±100` used to move it by +25 code;
            // that is what "the level only works on the dark end" buys.
            //
            // The level's own weight at every frame's median is asserted to be **exactly 0** — that is
            // the invariant, and it is why `LEV_HI_EV` sits 0.2 EV under the EV toe's top: the lowest
            // median of the four frames is −4.36 EV (L1030408), inside 073B's toe but outside the
            // level's window. What remains at p50 is 073B's own toe tail (≤ 1 code on that frame, 0 on
            // the three whose median is above −4.2 EV), unchanged by 073C.
            base = 0
            for f in frames {
                let gain50 = log2(Double(max(out[base + 4], 1e-12)) / Self.evToLinear(f.ev[4]))
                XCTAssertEqual(Self.levelWeight(atEV: f.ev[4]), 0,
                               "\(f.name): the level term has weight at the median (\(f.ev[4]) EV) — "
                               + "the level must not touch the mid-tones")
                XCTAssertLessThanOrEqual(abs(gain50), 0.02,
                                         "\(f.name): blacks \(label) moved the median")
                XCTAssertLessThanOrEqual(abs(Self.code(Double(out[base + 4])) - f.code[4]), 1.0,
                                         "\(f.name): the median moved by more than one 8-bit code")
                if f.ev[4] > -4.2 {
                    XCTAssertEqual(gain50, 0, accuracy: 1e-6,
                                   "\(f.name): a median above the toe must be bit-still")
                }
                base += Self.percentiles.count
            }

            // The two ends of the travel, as the owner stated them: down really crushes (some pixels
            // *are* 0), up really floats (no pixel is 0, and true black is no longer black).
            let share = Double(crushTotal) / Double(max(pixelsTotal, 1))
            if blacks > 0 {
                XCTAssertEqual(crushTotal, 0, "blacks \(label): a lift must not push any pixel to 0")
                // …and true black is no longer black: it floats to exactly `B_LEV · |t| · m`.
                let expected = Self.levelMagnitude * Double(blacks) / 100 * Self.blend(Double(blacks))
                let liftedZero = try harness.run([0], blacks: blacks, whites: 0)
                XCTAssertEqual(Double(liftedZero[0]), expected, accuracy: 1e-7,
                               "blacks \(label) must float true black to B_LEV·|t|·m")
            }
            if blacks == -100 { XCTAssertGreaterThan(share, 0.001, "blacks −100 must crush real pixels") }
        }
        // The crush is monotone in the travel on the negative side: −100 crushes more than −75, which
        // crushes more than −50 (which crushes nothing at all, because −50 is the pure-EV half).
        print("073C ④ crush share by travel (negative half):")
        var shares: [(Float, Double)] = []
        for blacks in [-50.0 as Float, -75, -100] {
            var zeros = 0, total = 0
            for f in frames {
                let pixels = try harness.runFrame(f.rgba, width: f.width, height: f.height,
                                                  blacks: blacks, whites: 0)
                for i in stride(from: 0, to: pixels.count, by: 4)
                where pixels[i] == 0 && f.rgba[i] > 0 { zeros += 1 }
                total += f.width * f.height
            }
            shares.append((blacks, Double(zeros) / Double(max(total, 1))))
            print(String(format: "   blacks %+.0f: %.3f %%", blacks, 100 * shares.last!.1))
        }
        XCTAssertEqual(shares[0].1, 0, "blacks −50 is the pure-EV half: a multiplier keeps 0 at 0")
        XCTAssertGreaterThan(shares[2].1, shares[1].1, "the crush must grow with the travel")
    }

    /// `percentiles` is `[0.01, 0.05, 0.2, …]`; the table asks for p1/p5/p20, i.e. the first three.
    private static func percentileIndex(_ percent: Int) -> Int {
        switch percent { case 1: return 0; case 5: return 1; default: return 2 }
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

    // MARK: - ④b 073C: the hybrid travel — the level half

    /// Mirrors of the kernel's 073C constants (Metal and Swift share no declaration; a drifted
    /// constant shows up as a number here, exactly like `S1Params`' stride assertion).
    private static let levelMagnitude = 0.005     // B_LEV, scene-linear
    private static let levelKnee = 1e-3           // LEV_KNEE, the C¹ corner's half-width
    private static let levelWindow = (-6.9, -4.4) // LEV_LO_EV … LEV_HI_EV (0.2 below the EV toe)

    /// The blend factor, exactly as the kernel spells it.
    private static func blend(_ blacks: Double) -> Double {
        let a = abs(blacks / 100)
        let t = min(max((a - 0.5) / 0.5, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The level term's weight at a given EV position, exactly as the kernel spells it. Zero above
    /// `LEV_HI_EV`, which is where the median invariant comes from — as a fact, not as a tolerance.
    private static func levelWeight(atEV ev: Double) -> Double {
        let (lo, hi) = Self.levelWindow
        let t = min(max((ev - lo) / (hi - lo), 0), 1)
        return 1 - t * t * (3 - 2 * t)
    }

    /// **The join is invisible.** `RenderGraph` switches instantiation at `|blacks| = 50`, which is the
    /// zero of the blend factor, so the level term there is ±0 and both kernels must write the same
    /// bytes. This is the assertion that the CPU-side switch cannot be seen in a picture — and the
    /// reason the switch is allowed to exist at all (no runtime `if` inside one kernel: 071's lesson).
    ///
    /// The two pinned hashes are 073B's bytes: `|blacks| ≤ 50` runs the `kKnee` instantiation, whose
    /// source is unchanged by 073C (only the template's parameter list grew), so its output is the
    /// pre-073C output. Verified against the 073B source compiled standalone as well (465 samples ×
    /// 6 configurations, all hashes equal); the hash is pinned here so a later edit that touches the
    /// first half of the travel turns red.
    func testTheHybridJoinsTheKneeEntryBitIdentically() throws {
        let harness = try MetalKernelHarness()
        var grid: [Float] = [-0.05, -0.01, -0.001, 0, 1e-6]
        var v: Float = 1e-5
        while v <= 4 { grid.append(v); v *= 1.03 }
        grid += [0.008, 0.012, 0.02, 0.0544, 0.18, 1.0, 2.0]

        // Identical bytes from the two instantiations over the whole first half of the travel.
        for blacks in [0.0 as Float, 1, 10, 25, 50, -1, -10, -25, -50] {
            for whites in [0.0 as Float, 100, -60] {
                let knee = try harness.run(grid, blacks: blacks, whites: whites, entry: .knee)
                let hybrid = try harness.run(grid, blacks: blacks, whites: whites, entry: .hybrid)
                for i in 0..<grid.count {
                    XCTAssertEqual(knee[i].bitPattern, hybrid[i].bitPattern,
                                   "blacks \(blacks) whites \(whites), sample \(grid[i]): "
                                   + "the hybrid instantiation moved a pixel inside the pure-EV half")
                }
            }
        }
        print("073C ④b join: 9 × 3 travel/whites combinations × \(grid.count) samples, "
              + "knee entry == hybrid entry, bit for bit")

        // And the 073B bytes of the first half, pinned.
        for (blacks, expected) in [(25.0 as Float, Self.pinnedBlacks25),
                                   (50, Self.pinnedBlacks50),
                                   (-25, Self.pinnedBlacksMinus25),
                                   (-50, Self.pinnedBlacksMinus50)] {
            let out = try harness.run(grid, blacks: blacks, whites: 0)
            XCTAssertEqual(Self.hash(out), expected,
                           "blacks \(blacks) moved — that is the first half of the travel, "
                           + "which 073C promises is 073B's arithmetic bit for bit")
            print("073C ④b blacks \(blacks) fingerprint (073B bytes): \(expected)")
        }

        // Continuity across the switch: 50 and 50.01 cross the dispatch boundary. The level term is
        // 1.5e-6 there (a third of a code at the very bottom), so no pixel may jump by more than one
        // 8-bit code — the switch is not a step in the picture.
        let below = try harness.run(grid, blacks: 50, whites: 0, entry: .knee)
        let above = try harness.run(grid, blacks: 50.01, whites: 0, entry: .hybrid)
        var worst = 0.0
        for i in 0..<grid.count {
            worst = max(worst, abs(Self.code(Double(above[i])) - Self.code(Double(below[i]))))
        }
        print(String(format: "073C ④b switch at 50 → 50.01: worst 8-bit step over the axis = %.3f", worst))
        XCTAssertLessThan(worst, 1.0, "crossing the dispatch boundary stepped by more than a code")
    }

    /// sha256 over the float32 **bit patterns** of a sample vector, so a 1-ULP move is visible.
    static func hash(_ v: [Float]) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(v.count * 4)
        for x in v {
            let b = x.bitPattern
            bytes += [UInt8(b & 0xff), UInt8((b >> 8) & 0xff), UInt8((b >> 16) & 0xff), UInt8(b >> 24)]
        }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// The level half, on the shipped kernel, with no picture in the way: `+` floats the black point
    /// off the floor (0 → `B_LEV`), `−` pushes the darkest band **to exactly 0** and leaves nothing
    /// negative. Both are what a multiplier cannot do, and both are the reason the second half exists.
    func testTheLevelLiftsBlackOffTheFloorAndCrushesItToZero() throws {
        let harness = try MetalKernelHarness()

        // Lift: true black becomes `B_LEV`, and the shift is monotone and never clips.
        let up = try harness.run([0, 1e-6, 1e-4, 1e-3, 0.002, 0.005, 0.02, 0.05, 0.1], blacks: 100, whites: 0)
        print("073C ④b blacks +100: 0 → \(up[0]), 1e−4 → \(up[2]), 0.02 → \(up[6]), 0.1 → \(up[8])")
        XCTAssertEqual(Double(up[0]), Self.levelMagnitude, accuracy: 1e-6,
                       "blacks +100 must float true black to B_LEV (0.005), not leave it at 0")
        XCTAssertEqual(Double(Self.code(Double(up[0]))), 15.6, accuracy: 0.2,
                       "B_LEV is calibrated to put the lifted black point at sRGB code ~16")
        for i in 1..<up.count { XCTAssertGreaterThan(up[i], up[i - 1], "the lift is not monotone") }
        XCTAssertGreaterThan(up[1], 0, "a lift must not clip the darkest sample to 0")

        // Crush: everything below the moved black point is exactly 0, nothing is negative, and the
        // map is still non-decreasing (the toe is a knee, not a fold).
        let down = try harness.run([0, 1e-6, 1e-4, 1e-3, 0.002, 0.004, 0.006, 0.008, 0.02, 0.1],
                                   blacks: -100, whites: 0)
        print("073C ④b blacks −100: " + down.map { String(format: "%.6g", $0) }.joined(separator: " → "))
        for (i, v) in down.enumerated() where v < 0 {
            XCTFail("blacks −100 made sample \(i) negative (\(v))")
        }
        XCTAssertEqual(down[0], 0, "true black stays black")
        XCTAssertEqual(down[2], 0, "blacks −100 must crush 1e−4 to exactly 0 (that is the level)")
        XCTAssertGreaterThan(down[8], 0, "blacks −100 must not crush a −5.6 EV pixel")
        for i in 1..<down.count {
            XCTAssertGreaterThanOrEqual(down[i], down[i - 1], "the crush folded: \(down)")
        }

        // The knee is C¹: the corner at 0 must not be a step. Walk the crush boundary finely.
        var fine: [Float] = []
        var x: Float = 0.004
        while x < 0.012 { fine.append(x); x += 0.00005 }
        let edge = try harness.run(fine, blacks: -100, whites: 0)
        var biggestStep = 0.0
        for i in 1..<edge.count {
            biggestStep = max(biggestStep, abs(Double(edge[i]) - Double(edge[i - 1])))
        }
        print(String(format: "073C ④b crush edge: largest step between samples 5e−5 apart = %.2e "
                     + "(a hard max() would step by the whole knee, %.0e)", biggestStep,
                     Double(Self.levelKnee)))
        XCTAssertLessThan(biggestStep, 5 * 5e-5,
                          "the clip is a step, not a C¹ knee (a step of the knee's own size, "
                          + "\(Self.levelKnee), would show up here)")
    }

    /// **Monotone outside the level's foot**, the owner's `> 0.3` criterion, at all four travels.
    ///
    /// The foot is not a get-out clause, it is the definition of a black-point move: a lift compresses
    /// everything *under* the black point (that is what raising a black point is), a crush flattens
    /// everything under the clip to 0. The criterion is therefore asserted on the pixels that carry
    /// the picture, i.e. whose output is above
    ///     `2.5 × |off|`   on the lift side (below it the map is `y = v + off`, whose log-slope is
    ///                     `v/(v+off) < 0.29` — a shift, not a fold),
    ///     `2 × LEV_KNEE`  on the crush side (below it the pixel *is* the clip's knee).
    /// The full-grid minimum is printed next to it so the excluded band cannot be hidden.
    func testTheHybridIsMonotoneOutsideItsFoot() throws {
        let harness = try MetalKernelHarness()
        var grid: [Float] = []
        var v: Float = 1e-6
        while v <= 16 { grid.append(v); v *= 1.02 }

        print("073C ④b min d(log2 v')/d(log2 v) outside the level's foot:")
        for blacks in [75.0 as Float, 100, -75, -100] {
            let out = try harness.run(grid, blacks: blacks, whites: 0)
            let m = Self.blend(Double(blacks))
            let off = Self.levelMagnitude * (Double(blacks) / 100) * m
            let foot = blacks > 0 ? 2.5 * abs(off) : 2 * Self.levelKnee
            var worst = Double.infinity, worstAt: Float = 0
            var worstAll = Double.infinity, worstAllAt: Float = 0
            var excluded = 0, pairs = 0, footTop: Float = 0
            for i in 0..<(grid.count - 1) {
                if out[i] <= 0 || out[i + 1] <= 0 { continue }
                let s = (log2(Double(out[i + 1])) - log2(Double(out[i])))
                    / (log2(Double(grid[i + 1])) - log2(Double(grid[i])))
                pairs += 1
                if s < worstAll { worstAll = s; worstAllAt = grid[i] }
                if Double(out[i]) > foot && Double(out[i + 1]) > foot {
                    if s < worst { worst = s; worstAt = grid[i] }
                } else {
                    excluded += 1
                    footTop = max(footTop, grid[i])
                }
            }
            print(String(format: "   blacks %+.0f  foot %.4f  min %+.3f at code %.2f  "
                         + "(whole axis %+.3f at code %.2f; the foot ends at code %.1f, "
                         + "%d/%d axis samples excluded)",
                         blacks, foot, worst, Self.code(Double(worstAt)),
                         worstAll, Self.code(Double(worstAllAt)),
                         Self.code(Double(footTop)), excluded, pairs))
            XCTAssertGreaterThan(worst, 0.30,
                                 "blacks \(blacks) folds the shadows above its foot: min slope \(worst)")
            // …and the foot really is a foot: it has to end inside the deep shadows, not at the
            // mid-tones. 32/255 is below every measured p20 of the four frames.
            XCTAssertLessThan(Self.code(Double(footTop)), 32,
                              "blacks \(blacks): the foot reaches code \(Self.code(Double(footTop)))")
        }
        // A multiplier can never have a foot: the pure-EV half really is monotone everywhere.
        for blacks in [25.0 as Float, 50, -25, -50] {
            let out = try harness.run(grid, blacks: blacks, whites: 0)
            var worst = Double.infinity
            for i in 0..<(grid.count - 1) where out[i] > 0 && out[i + 1] > 0 {
                let dy = log2(Double(out[i + 1])) - log2(Double(out[i]))
                let dx = log2(Double(grid[i + 1])) - log2(Double(grid[i]))
                worst = min(worst, dy / dx)
            }
            XCTAssertGreaterThan(worst, 0.30, "blacks \(blacks) folds: min slope \(worst)")
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
        let knee = try harness.time(px, width: w, height: h, blacks: 50, whites: 0, entry: .knee)
        // 073C: the level half is one smoothstep, one multiply-add, one select and (on the crush side)
        // a two-instruction toe — it must not cost a copy.
        let hybrid = try harness.time(px, width: w, height: h, blacks: 100, whites: 0, entry: .hybrid)
        let hybridDown = try harness.time(px, width: w, height: h, blacks: -100, whites: 0, entry: .hybrid)
        print(String(format: "073B ⑥ 4.10 Mpx S1 pass: default %.3f ms, knee(EV only) %.3f ms (Δ %+.3f), "
                     + "hybrid +100 %.3f ms (Δ %+.3f), hybrid −100 %.3f ms (Δ %+.3f)",
                     base, knee, knee - base, hybrid, hybrid - base, hybridDown, hybridDown - base))
        XCTAssertLessThan(knee - base, 0.5, "the knee pass must stay inside the copy's bandwidth")
        XCTAssertLessThan(hybrid - base, 0.5, "the hybrid pass must stay inside the copy's bandwidth")
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
    enum Entry { case `default`, knee, hybrid, trim, kneeTrim, hybridTrim, levels, levelsTrim, auto }

    struct Params {
        var a: SIMD4<Float>   // gain, wbR, wbG, wbB
        var b: SIMD4<Float>   // recovery, identity, blacks, whites
        var c: SIMD4<Float>   // contentOrigin.xy, contentSize.xy
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
        // 079 §2.1.2: the end points moved into `tone_shape.metal`, so the harness has to inline the
        // includes the way the app's `KernelLibrary` does — otherwise it would compile a kernel that
        // is not the one that ships.
        let source = try KernelLibrary.expandingLocalIncludes(of: url)
        let library = try device.makeLibrary(source: source, options: nil)
        for name in ["s1_scene_linear", "s1_scene_linear_knee", "s1_scene_linear_trim",
                     "s1_scene_linear_knee_trim", "s1_scene_linear_hybrid",
                     "s1_scene_linear_hybrid_trim", "s1_scene_linear_levels",
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

    /// Production's rule (073B + 073C), copied so a test cannot ask the wrong kernel by accident:
    /// the sliders at 0 are the default entry, `|blacks| ≤ 50` is 073B's knee, `|blacks| > 50` is
    /// 073C's hybrid (the level half of the travel).
    static func productionEntry(blacks: Float, whites: Float) -> String {
        guard blacks != 0 || whites != 0 else { return "s1_scene_linear" }
        return abs(blacks) > 50 ? "s1_scene_linear_hybrid" : "s1_scene_linear_knee"
    }

    private func entryName(_ entry: Entry, blacks: Float, whites: Float) -> String {
        switch entry {
        case .default: return "s1_scene_linear"
        case .knee: return "s1_scene_linear_knee"
        case .hybrid: return "s1_scene_linear_hybrid"
        case .trim: return "s1_scene_linear_trim"
        case .kneeTrim: return "s1_scene_linear_knee_trim"
        case .hybridTrim: return "s1_scene_linear_hybrid_trim"
        case .levels: return "s1_scene_linear_levels"
        case .levelsTrim: return "s1_scene_linear_levels_trim"
        case .auto: return Self.productionEntry(blacks: blacks, whites: whites)
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
                       c: SIMD4(0, 0, Float(width), Float(height)),
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
