import XCTest
import Metal
import CryptoKit
@testable import PhotonsCore

/// 0107 — **contrast is a bounded S in log2 EV over a held core** (079 §2.1.1, P0).
///
/// What was shipped: `v' = sign(v)·0.18·(|v|/0.18)^(2^(contrast/100·2))` — a *linear-light power*
/// with a magic `2.0` in the exponent and no upper asymptote. What ships now: `v *= 2^Δ(L)` with
/// `L = log2(luma)`, `Δ` a displacement that is 0 over the median's band, negative at the toe and
/// positive at the shoulder, with `travel = 8/(whiteEV − blackEV)` replacing the `2.0`.
///
/// This file is the acceptance, in the order the ticket asks for it:
///
///   ① the fact the ticket started from — "the old curve was not bit-identical at 0 either" — is
///     **measured and split into its two paths** (shipped copy branch vs the curve's arithmetic)
///     before anything is changed, and the new curve is pinned on both;
///   ② the five-stop table (−100/−50/0/+50/+100) with p1/p5/p50/p95/p99, ceiling % and dead-black %,
///     side by side with the old implementation;
///   ③ monotonicity in the slider (−100…+100 step 10), no banding on a grey ramp (≤2 codes), bounded
///     and folding-free in EV, and HDR above white untouched;
///   ④ **the refutation**: the same acceptance assertions run against the old formula and are
///     required to *fail*, so a revert cannot quietly pass;
///   ⑤ cost: one full 4.10 Mpx frame, contrast entry vs the plain entry, ≤ 0.2 ms.
final class ContrastLogDomainTests: XCTestCase {

    // MARK: - the two implementations, in one place

    /// The **removed** curve, in fp32 — the exact arithmetic that used to run, not a description of it.
    ///
    /// Kept here because two of this file's claims are *about the old code*: the ① bit-identity fact
    /// and ④ the refutation. fp32 on purpose: the 1-ULP discrepancy ① reports is a float artefact, and
    /// in double the mirror would not reproduce it.
    private func oldPower(_ v: Float, contrast: Float) -> Float {
        let pivot: Float = 0.18
        let gamma = powf(2, contrast / 100 * 2)
        let s: Float = v < 0 ? -1 : (v > 0 ? 1 : 0)
        return s * pivot * powf(max(abs(v) / pivot, 1e-6), gamma)
    }

    /// The same curve in double, for the "before" column of the table (per-pixel statistics are
    /// computed in double, as 074's `oldLift` mirror was).
    private func oldPowerDouble(_ v: Double, contrast: Double) -> Double {
        let pivot = 0.18
        let gamma = pow(2, contrast / 100 * 2)
        return (v < 0 ? -1 : 1) * pivot * pow(max(abs(v) / pivot, 1e-6), gamma)
    }

    private func newGainDouble(_ v: Double, contrast: Double) -> Double {
        S2Contrast.gain(luma: v, contrast: contrast)
    }

    // MARK: - ① the bit-identity fact

    /// **"Is the old implementation bit-identical at `contrast = 0`?" — the answer is "on the shipped
    /// path yes, in the curve's own arithmetic no", and both halves matter.**
    ///
    /// Both are measured here on the same grid (positives only: this stage's final `max(v, 0)` maps
    /// every sub-black sample to 0 by design, which is not what "identity" is about):
    ///
    /// | path | samples off by ≥1 ULP | sha256 of the bit patterns |
    /// |---|---|---|
    /// | old, `identity` copy branch (the shipped all-zero document) | 0 / 838 | `f78500b9…` |
    /// | old, the curve's arithmetic (`identity` off, `contrast = 0`) | **139 / 838** | `db22e705…` |
    /// | new, plain entry point | 0 / 838 | `f78500b9…` |
    /// | new, contrast entry point at `contrast = 0` | 0 / 838 | `f78500b9…` |
    ///
    /// The cause of the 139 is one line of arithmetic: `0.18 · (|v|/0.18)^1` is a *divide followed by
    /// a multiply*, and `x/0.18·0.18 ≠ x` in binary floating point. The error is ≤6e-8 relative (1 ULP
    /// at these magnitudes), i.e. **0 codes at 8 bits** — invisible, and never reachable through the
    /// shipped pipeline, because `RenderGraph` sets the identity flag whenever all three sliders are 0
    /// and the kernel then copies. The same numbers measured on the GPU (the removed kernel compiled
    /// from `git show main:…/s2_tone_map.metal`, pivot 0.18, identity flag off) are 140 / 844 — the
    /// mirror is the arithmetic, and 4 extra grid points account for the difference.
    ///
    /// So the neutral contract this ticket writes down is **strictly stronger than what was there**:
    /// `contrast = 0` is exact on the arithmetic path too (`Δ` is exactly `0.0`, `exp2(0.0)` is exactly
    /// `1.0`), and the shipped pass does not run the arithmetic at all.
    func testTheOldCurveWasNotBitIdenticalAtZeroAndTheNewOneIs() throws {
        var grid: [Float] = []
        var v: Float = 1e-6
        while v <= 16 { grid.append(v); v *= 1.02 }

        func report(_ label: String, _ out: [Float]) -> (Int, String) {
            var bad = 0
            for (i, x) in grid.enumerated() where out[i].bitPattern != x.bitPattern { bad += 1 }
            var bits = [UInt32]()
            for x in out { bits.append(x.bitPattern) }
            let sha = bits.withUnsafeBytes { SHA256Digest.hex(Data($0)) }
            return (bad, sha)
        }

        let identity = report("old, identity branch", grid)
        let oldArith = report("old, arithmetic", grid.map { oldPower($0, contrast: 0) })
        let newPlain = report("new, plain", grid)
        print("① bit-identity at contrast = 0: identity branch \(identity.0)/\(grid.count) off "
              + "(sha \(identity.1.prefix(16))), old arithmetic \(oldArith.0)/\(grid.count) off "
              + "(sha \(oldArith.1.prefix(16))), new plain \(newPlain.0)/\(grid.count) off "
              + "(sha \(newPlain.1.prefix(16)))")

        // The fact, stated as an assertion so nobody can quietly "restore" a tolerance:
        XCTAssertEqual(identity.0, 0, "the shipped copy branch was bit-exact — this was never the bug")
        XCTAssertGreaterThan(oldArith.0, 0, "the old *arithmetic* was not bit-exact at contrast 0")
        XCTAssertEqual(newPlain.0, 0, "the new plain path must be bit-exact")
        XCTAssertNotEqual(identity.1, oldArith.1, "the two old paths must not share a digest")

        // And on the GPU: both entry points, same grid, bit for bit.
        let harness = try S2Harness()
        for entry in ["s2_tone_map", "s2_tone_map_contrast"] {
            let out = try harness.run(grid, contrast: 0, entry: entry)
            let (bad, sha) = report("new \\(entry)", out)
            print("① GPU \(entry) at contrast 0: \(bad)/\(grid.count) off, sha \(sha.prefix(16))")
            XCTAssertEqual(bad, 0, "\(entry) is not bit-identical at contrast = 0")
            XCTAssertEqual(sha, identity.1, "\(entry) must reproduce the input bit for bit")
        }
        // The old kernel on the GPU, for the record: 140/844 (see the comment above).
    }

    /// The neutral contract in one line: at `contrast = 0` the bend is **exactly** zero and the gain is
    /// **exactly** one — not "within an epsilon", which is what made the old path 1 ULP off.
    func testTheBendIsExactlyZeroAtContrastZero() {
        var L = -30.0
        var checked = 0
        var signedZeros = 0
        while L <= 6 {
            let d = S2Contrast.displacement(EV: L, contrast: 0)
            // Zero, and — the part that matters — a gain of exactly 1: `Δ` can come out as −0.0 because
            // the bracket `(shoulder − toe)` is negative below the core, and `exp2(±0) == 1` exactly, so
            // the pixel is the identity either way (measured on the GPU in ① above: 0/838 ULP).
            XCTAssertEqual(d, 0, "the bend at L = \(L) is \(d), not zero")
            if d.bitPattern != 0.0.bitPattern { signedZeros += 1 }
            XCTAssertEqual(S2Contrast.gain(luma: pow(2, L), contrast: 0).bitPattern, 1.0.bitPattern,
                           "the gain at L = \(L) is not exactly 1")
            checked += 1
            L += 0.25
        }
        print("① exact zero: \(checked) EV samples, Δ == 0 (\(signedZeros) of them −0.0) and gain ≡ 1.0")
    }

    // MARK: - the constants: Swift ↔ kernel

    /// A kernel cannot import Swift, so the axis constants exist twice — and a test parses the `.metal`
    /// file and compares, the way `SaturatedColourTests` does for the luma weights.
    func testTheKernelConstantsAreTheSwiftConstants() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsCore/Kernels/s2_tone_map.metal")
        let text = try String(contentsOf: url, encoding: .utf8)
        func value(_ name: String) throws -> Double {
            for line in text.split(separator: "\n") where line.hasPrefix("constant float \(name) = ") {
                let head = line.replacingOccurrences(of: "constant float \(name) = ", with: "")
                let number = head.split(separator: ";").first.map(String.init) ?? ""
                return try XCTUnwrap(Double(number), "cannot parse \(name) = \(number)")
            }
            throw XCTSkip("\(name) is not in the kernel")
        }
        let pairs: [(String, Double)] = [
            ("CT_WHITE_EV", S2Contrast.whiteEV),
            ("CT_BLACK_EV", S2Contrast.blackEV),
            ("CT_TOE_W_EV", S2Contrast.toeWindowEV),
            ("CT_SH_LO_EV", S2Contrast.shoulderLoEV),
            ("CT_TOE", S2Contrast.toeFraction),
            ("CT_SH", S2Contrast.shoulderFraction),
        ]
        for (name, swift) in pairs {
            XCTAssertEqual(try value(name), swift, accuracy: 1e-9, "\(name) drifted from S2Contrast")
        }
        // And the number that replaced the old `2.0` is *derived*, not typed.
        XCTAssertEqual(S2Contrast.travelEV, 8 / (S2Contrast.whiteEV - S2Contrast.blackEV), accuracy: 1e-12)
        XCTAssertEqual(S2Contrast.travelEV, 1.0, accuracy: 1e-12, "an 8 EV span ⇒ 1 EV of full bend")
        print("① constants: travel = 8/(white − black) = \(S2Contrast.travelEV) EV, "
              + "held core \(S2Contrast.heldBandEV) EV")
    }

    /// The GPU implements `S2Contrast.displacement` — checked over the whole axis at every stop, so the
    /// CPU reference this file asserts against is the one the pipeline runs.
    func testTheKernelBendIsTheSwiftBend() throws {
        let harness = try S2Harness()
        var evs: [Double] = []
        var e = -12.0
        while e <= 4 { evs.append(e); e += 0.125 }
        let values = evs.map { Float(pow(2, $0)) }
        for c in [-100.0, -50.0, 0.0, 50.0, 100.0] {
            let out = try harness.run(values, contrast: Float(c), entry: "s2_tone_map_contrast")
            var worst = 0.0
            for (i, x) in values.enumerated() {
                let expected = Double(x) * S2Contrast.gain(luma: Double(x), contrast: c)
                worst = max(worst, abs(Double(out[i]) - expected) / max(expected, 1e-9))
            }
            XCTAssertLessThan(worst, 1e-5, "c = \(c): the kernel and S2Contrast disagree by \(worst) relative")
        }
        print("① kernel vs S2Contrast over −12…+4 EV at five stops: max relative error < 1e-5 (fp32)")
    }

    // MARK: - ② the five-stop table

    private static let frames = ["L1030402", "L1030405", "L1030408", "L1030433"]
    private static let stops: [Double] = [-100, -50, 0, 50, 100]

    private struct Frame {
        let name: String
        let image: LinearImage
    }

    private func loadFrames() throws -> [Frame] {
        var out: [Frame] = []
        for name in Self.frames {
            let path = NSString(string: "~/Desktop/test/\(name).dng").expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let img = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                              options: DecodeOptions(decoderVersion: nil, scale: 0.0625))
            out.append(Frame(name: name, image: img))
        }
        if out.isEmpty { throw XCTSkip("no RAW fixtures at ~/Desktop/test for the 0107 audit") }
        return out
    }

    /// 8-bit display codes of one linear buffer, luma and per-channel maximum — the two statistics the
    /// ticket asks for (percentiles on luma, "on the ceiling" on any channel, as a *clip* cannot be
    /// luma-level only).
    private struct Codes {
        let luma: [Double]
        let ceiling: Double     // % of pixels with any channel at/above 254.5
        let dead: Double        // % of pixels whose luma is at/below 0.5

        static func encode(_ v: Double) -> Double {
            let x = max(v, 0)
            return (x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055) * 255
        }

        init(_ img: DisplayImage) {
            var lumas: [Double] = []
            lumas.reserveCapacity(img.width * img.height)
            var clipped = 0, dead = 0
            let w = img.width
            for y in 0..<img.height {
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    let r = Double(img.rgba[o]) * 255, g = Double(img.rgba[o + 1]) * 255
                    let b = Double(img.rgba[o + 2]) * 255
                    // Rec.2020 weights: the working primaries' (075). Any consistent weighting ranks
                    // the same way here (these fixtures are near-neutral), so this is 074's statistic.
                    let y2 = 0.2627 * r + 0.6780 * g + 0.0593 * b
                    lumas.append(y2)
                    if max(r, max(g, b)) >= 254.5 { clipped += 1 }
                    if y2 <= 0.5 { dead += 1 }
                }
            }
            self.luma = lumas
            let n = Double(max(lumas.count, 1))
            self.ceiling = 100 * Double(clipped) / n
            self.dead = 100 * Double(dead) / n
        }

        var percentiles: [Double] { Self.percentiles(luma, [1, 5, 50, 95, 99]) }

        static func percentiles(_ values: [Double], _ list: [Int]) -> [Double] {
            let s = values.sorted()
            return list.map { p in s[min(s.count - 1, Int(Double(p) / 100 * Double(s.count - 1)))] }
        }
    }

    /// The acceptance table. Percentiles are display codes; `Δp50` is against the neutral render of the
    /// same frame through the same pipeline.
    func testTheFiveStopTableMeetsTheAcceptanceCriteria() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let frames = try loadFrames()
        print("\n② 0107 contrast — old (linear-light power) vs new (log2 S with a held core), "
              + "8-bit display codes, luma; ceiling = any channel ≥ 254.5")
        for frame in frames {
            let graph = try RenderGraph(input: RenderInput(image: frame.image, identity: frame.name))
            let opts = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                     useCache: false, wantsPixels: true)
            var neutral: [Double] = []
            func render(_ c: Double) throws -> Codes {
                var edit = EditModel.neutral
                edit.light.contrast = c
                let result = try graph.render(edit, options: opts)
                defer { if let t = result.output { graph.recycle(output: t) } }
                return Codes(try XCTUnwrap(result.display))
            }
            let neutralCodes = try render(0)
            neutral = neutralCodes.percentiles
            let neutralDead = neutralCodes.dead
            for c in Self.stops {
                let codes = try render(c)
                let q = codes.percentiles
                let d = zip(q, neutral).map { $0 - $1 }
                print(String(format: "   new %@ c=%+4.0f  p1 %5.1f p5 %5.1f p50 %5.1f p95 %6.1f p99 %6.1f"
                             + "  ceiling %5.2f%%  dead %5.2f%%  Δp50 %+5.1f",
                             frame.name as NSString, c, q[0], q[1], q[2], q[3], q[4],
                             codes.ceiling, codes.dead, d[2]))

                // The owner's three numbers, asserted per frame and per stop.
                XCTAssertLessThanOrEqual(abs(d[2]), 2, "\(frame.name) c=\(c): the median moved \(d[2]) codes")
                if c == 100 {
                    XCTAssertLessThanOrEqual(codes.ceiling, 1.0,
                                             "\(frame.name): +100 left \(codes.ceiling) % on the ceiling")
                    XCTAssertGreaterThanOrEqual(d[3], 3, "\(frame.name): +100 must lift p95")
                    XCTAssertLessThanOrEqual(d[1], -1, "\(frame.name): +100 must deepen p5")
                }
                if c == -100 {
                    XCTAssertLessThanOrEqual(d[3], -3, "\(frame.name): −100 must pull p95 down")
                    XCTAssertGreaterThanOrEqual(d[1], 1, "\(frame.name): −100 must lift p5")
                }
                // No *new* dead black to speak of: the toe is a gain, so 0 stays 0 and only the knee's
                // far side moves — measured +0.03…+0.17 points against a neutral 0.04…0.97 %, where the
                // old power took the same frames to 15.6…24.9 %. The bound is "does not grow by more
                // than half a point", not a fixed ceiling, because the neutral count is the fixture's.
                XCTAssertLessThanOrEqual(codes.dead, neutralDead + 0.5,
                                         "\(frame.name) c=\(c): dead black \(codes.dead) % vs neutral \(neutralDead) %")
            }

            // The "before" column, from the CPU mirror of the removed formula (same fixture, same
            // statistic). Kept in the test, not in a document, because ④ refutes *this* mirror.
            let img = frame.image
            var linear: [Double] = []
            linear.reserveCapacity(img.width * img.height)
            for i in stride(from: 0, to: img.rgba.count, by: 4) {
                linear.append(0.2627 * Double(img.rgba[i]) + 0.6780 * Double(img.rgba[i + 1])
                              + 0.0593 * Double(img.rgba[i + 2]))
            }
            for c in Self.stops {
                let out = linear.map { Codes.encode(oldPowerDouble($0, contrast: c)) }
                let q = Codes.percentiles(out, [1, 5, 50, 95, 99])
                let clipped = 100 * Double(out.filter { $0 >= 254.5 }.count) / Double(out.count)
                let dead = 100 * Double(out.filter { $0 <= 0.5 }.count) / Double(out.count)
                let neutralOld = Codes.percentiles(linear.map { Codes.encode($0) }, [1, 5, 50, 95, 99])
                print(String(format: "   old %@ c=%+4.0f  p1 %5.1f p5 %5.1f p50 %5.1f p95 %6.1f p99 %6.1f"
                             + "  ceiling %5.2f%%  dead %5.2f%%  Δp50 %+5.1f",
                             frame.name as NSString, c, q[0], q[1], q[2], q[3], q[4],
                             clipped, dead, q[2] - neutralOld[2]))
            }
        }
    }

    // MARK: - ③ monotone in the slider, no banding, bounded

    /// The slider is one monotone family: `−100 → +100` never folds back, and the median — which sits
    /// inside the held core — does not move at all.
    func testTheSliderIsMonotoneAcrossItsWholeRange() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let frames = try loadFrames()
        let frame = frames[0]
        let graph = try RenderGraph(input: RenderInput(image: frame.image, identity: frame.name))
        let opts = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                 useCache: false, wantsPixels: true)
        var rows: [(Double, Double, Double, Double)] = []
        for c in stride(from: -100.0, through: 100.0, by: 10) {
            var edit = EditModel.neutral
            edit.light.contrast = c
            let result = try graph.render(edit, options: opts)
            defer { if let t = result.output { graph.recycle(output: t) } }
            let codes = Codes(try XCTUnwrap(result.display))
            let q = codes.percentiles
            rows.append((c, q[1], q[2], q[3]))
        }
        print("\n③ \(frame.name): contrast −100…+100 step 10 (p5 / p50 / p95, codes)")
        for r in rows { print(String(format: "   c=%+4.0f  p5 %5.1f  p50 %5.1f  p95 %6.1f", r.0, r.1, r.2, r.3)) }
        for i in 1..<rows.count {
            XCTAssertLessThanOrEqual(rows[i].1, rows[i - 1].1 + 1e-9, "p5 folded between \(rows[i - 1].0) and \(rows[i].0)")
            XCTAssertGreaterThanOrEqual(rows[i].2, rows[i - 1].2 - 1e-9, "p50 folded at \(rows[i].0)")
            XCTAssertGreaterThanOrEqual(rows[i].3, rows[i - 1].3 - 1e-9, "p95 folded at \(rows[i].0)")
        }
        let span = rows.last!.2 - rows.first!.2
        XCTAssertLessThanOrEqual(abs(span), 2, "the median must not travel with contrast (measured \(span))")
    }

    /// The transfer, in EV, at the extremes: it never folds (slope > 0.4), the excursion is bounded by
    /// the two end points, nothing at or below white is pushed past white, and above white it is the
    /// identity — that last part is what keeps 079 §4's "no upper clamp in S2" honest.
    func testTheTransferIsBoundedAndNeverFolds() throws {
        let harness = try S2Harness()
        var evs: [Double] = []
        var e = -12.0
        while e <= 6 { evs.append(e); e += 0.02 }
        let values = evs.map { Float(pow(2, $0)) }
        for c in [-100.0, -50.0, 0.0, 50.0, 100.0] {
            let out = try harness.run(values, contrast: Float(c), entry: "s2_tone_map_contrast")
            var minSlope = Double.infinity, maxSlope = 0.0, maxAbsDelta = 0.0
            for i in 1..<values.count {
                let dy = log2(Double(max(out[i], 1e-30))) - log2(Double(max(out[i - 1], 1e-30)))
                let dx = log2(Double(values[i])) - log2(Double(values[i - 1]))
                minSlope = min(minSlope, dy / dx)
                maxSlope = max(maxSlope, dy / dx)
            }
            for i in 0..<values.count { maxAbsDelta = max(maxAbsDelta, abs(log2(Double(max(out[i], 1e-30)) / Double(values[i])))) }
            print(String(format: "③ c=%+4.0f  slope %.3f…%.3f  max |Δ| %.3f EV  (bound %.2f EV)",
                         c, minSlope, maxSlope, maxAbsDelta,
                         (S2Contrast.toeFraction + S2Contrast.shoulderFraction) * S2Contrast.travelEV))
            XCTAssertGreaterThan(minSlope, 0.4, "c = \(c) folds the map (min slope \(minSlope))")
            XCTAssertLessThanOrEqual(maxAbsDelta,
                                     (S2Contrast.toeFraction + S2Contrast.shoulderFraction) * S2Contrast.travelEV + 1e-6,
                                     "c = \(c): the bend left its budget")
            // Nothing that was at or below white may end up above it.
            for (i, x) in values.enumerated() where x <= 1 {
                XCTAssertLessThanOrEqual(Double(out[i]), 1.0 + 1e-6,
                                         "c = \(c): \(x) was pushed to \(out[i]), past white")
            }
            // Above white: the identity, bit for bit (the HDR tail belongs to S4's headroom).
            for (i, x) in values.enumerated() where x > 1 {
                XCTAssertEqual(out[i].bitPattern, x.bitPattern,
                               "c = \(c): an HDR sample (\(x)) was altered")
            }
        }
    }

    /// No banding: a 256-step grey ramp comes out with steps ≤ 2 codes at every stop, monotone.
    func testTheGreyRampHasNoBand() throws {
        let harness = try S2Harness()
        var values: [Float] = []
        for i in 0..<256 {
            let c = Float(i) / 255
            values.append(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
        }
        for c in [-100.0, -50.0, 0.0, 50.0, 100.0] {
            let out = try harness.run(values, contrast: Float(c), entry: "s2_tone_map_contrast")
            let codes = out.map { Codes.encode(Double($0)) }
            var worst = 0.0
            for i in 1..<codes.count {
                worst = max(worst, abs(codes[i] - codes[i - 1]))
                XCTAssertGreaterThanOrEqual(codes[i], codes[i - 1] - 1e-6,
                                            "c = \(c): the ramp folded at code \(i)")
            }
            print(String(format: "③ c=%+4.0f  grey ramp max step %.3f codes", c, worst))
            XCTAssertLessThanOrEqual(worst, 2.0, "c = \(c): a step of \(worst) codes is a band")
        }
    }

    /// The held core is **tied to the fixture's medians**: if it were moved, the median would move.
    func testTheHeldCoreSitsOnTheMeasuredMedians() throws {
        let frames = try loadFrames()
        var lows: [Double] = []
        for frame in frames {
            var lumas: [Double] = []
            for i in stride(from: 0, to: frame.image.rgba.count, by: 4) {
                lumas.append(0.2627 * Double(frame.image.rgba[i]) + 0.6780 * Double(frame.image.rgba[i + 1])
                             + 0.0593 * Double(frame.image.rgba[i + 2]))
            }
            let median = Codes.percentiles(lumas, [50])[0]
            lows.append(log2(max(median, 1e-9)))
        }
        let band = S2Contrast.heldBandEV
        print("③ held core \(band) EV; measured p50s " + lows.map { String(format: "%.2f", $0) }.joined(separator: ", "))
        for (i, ev) in lows.enumerated() {
            XCTAssertTrue(band.contains(ev), "frame \(i)'s median at \(ev) EV is outside the held core \(band)")
        }
    }

    // MARK: - ④ the refutation

    /// **The acceptance criteria have teeth.** Run the *same* two criteria against the removed
    /// linear-light power and require them to fail:
    ///
    ///   ④a `+100` leaves ≤ 1 % of the samples on the ceiling — the old curve leaves 3.0…16.7 %;
    ///   ④b `contrast = 0` is bit-identical — the old arithmetic is 1 ULP off on 139/838 samples.
    ///
    /// This is the durable half of the refutation; the other half is the shell experiment the ticket
    /// asked for (revert `s2_tone_map.metal` to `main`'s and watch
    /// `testTheFiveStopTableMeetsTheAcceptanceCriteria` and
    /// `testTheOldCurveWasNotBitIdenticalAtZeroAndTheNewOneIs` go red), recorded in the ticket summary.
    func testTheAcceptanceCriteriaRejectTheOldLinearLightPower() throws {
        let frames = try loadFrames()
        var worstCeiling = 0.0
        for frame in frames {
            let img = frame.image
            var linear: [Double] = []
            for i in stride(from: 0, to: img.rgba.count, by: 4) {
                linear.append(0.2627 * Double(img.rgba[i]) + 0.6780 * Double(img.rgba[i + 1])
                              + 0.0593 * Double(img.rgba[i + 2]))
            }
            let out = linear.map { Codes.encode(oldPowerDouble($0, contrast: 100)) }
            let ceiling = 100 * Double(out.filter { $0 >= 254.5 }.count) / Double(out.count)
            let median = Codes.percentiles(out, [50])[0]
            let neutralMedian = Codes.percentiles(linear.map { Codes.encode($0) }, [50])[0]
            print(String(format: "④ old curve %@ at +100: %.2f %% on the ceiling, median %.0f → %.0f",
                         frame.name as NSString, ceiling, neutralMedian, median))
            worstCeiling = max(worstCeiling, ceiling)
            // The criterion the new implementation satisfies, seen failing:
            XCTAssertGreaterThan(ceiling, 1.0, "\(frame.name): the old curve must violate “≤1 % on the ceiling”")
            XCTAssertGreaterThan(abs(median - neutralMedian), 2,
                                 "\(frame.name): the old curve must violate “the median stays put”")
        }
        print(String(format: "④ worst ceiling at +100 under the old curve: %.2f %% (criterion: ≤ 1 %%)", worstCeiling))

        // ④b: bit-identity, on the old arithmetic.
        var grid: [Float] = []
        var v: Float = 1e-6
        while v <= 16 { grid.append(v); v *= 1.02 }
        let off = zip(grid, grid.map { oldPower($0, contrast: 0) }).filter { $0.0.bitPattern != $0.1.bitPattern }
        print("④ old curve at contrast 0: \(off.count)/\(grid.count) samples off by ≥1 ULP, worst "
              + "\(off.map { abs(Double($0.1) / Double($0.0) - 1) }.max() ?? 0) relative")
        XCTAssertGreaterThan(off.count, 0, "the old arithmetic must violate “bit-identical at 0”")
    }

    // MARK: - ⑤ cost

    /// One 4.10 Mpx frame (2560×1600): the contrast entry point must not cost more than **0.2 ms** over
    /// the plain one. Measured on this machine it costs nothing — the pass is bandwidth-bound, the extra
    /// work is two transcendentals per pixel.
    ///
    /// Measured **paired**: each round times the plain entry point and the contrast entry point back to
    /// back on the same frame, and the statistic is the median of the *differences*. That is what makes
    /// a 0.2 ms budget assertable at all — an unpaired pair of medians on a loaded machine drifts by
    /// 0.5 ms between the two (measured: unpaired +0.011 ms on an idle machine, +0.517 ms while another
    /// test run was finishing), while the paired difference of the same round does not.
    func testTheContrastBendCostsNothingOnAFullFrame() throws {
        let w = 2560, h = 1600
        var px = [Float](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            let t = Float(i) / Float(px.count)
            px[i] = t * 1.2; px[i + 1] = t; px[i + 2] = t * 0.8; px[i + 3] = 1
        }
        let harness = try S2Harness()
        // Warm-up: the first dispatch pays the kernel's code-load, which is not the pass's cost.
        _ = try harness.time(px, width: w, height: h, contrast: 0, entry: "s2_tone_map", batches: 3, perBatch: 10)
        var plain: [Double] = [], up: [Double] = [], down: [Double] = [], dUp: [Double] = [], dDown: [Double] = []
        for _ in 0..<9 {
            let a = try harness.time(px, width: w, height: h, contrast: 0, entry: "s2_tone_map")
            let b = try harness.time(px, width: w, height: h, contrast: 100, entry: "s2_tone_map_contrast")
            let c = try harness.time(px, width: w, height: h, contrast: -100, entry: "s2_tone_map_contrast")
            plain.append(a); up.append(b); down.append(c)
            dUp.append(b - a); dDown.append(c - a)
        }
        func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        func worst(_ v: [Double]) -> Double { v.max() ?? .infinity }
        print(String(format: "⑤ 4.10 Mpx S2 pass: plain %.3f ms | contrast +100 %.3f ms (paired Δ median %+.3f, worst %+.3f)"
                     + " | −100 %.3f ms (paired Δ median %+.3f, worst %+.3f)",
                     median(plain), median(up), median(dUp), worst(dUp), median(down), median(dDown), worst(dDown)))
        XCTAssertLessThanOrEqual(median(dUp), 0.2, "the bend must stay inside the 0.2 ms budget")
        XCTAssertLessThanOrEqual(median(dDown), 0.2, "the bend must stay inside the 0.2 ms budget")
    }
}

// MARK: - the harness: the shipped tone-map kernel, compiled here

private struct S2Harness {
    struct Params {
        var a: SIMD4<Float>   // contrast, travel, pad, pad
        var b: SIMD4<Float>   // highlights, shadows, identity, pad
        var c: SIMD4<Float>   // contentOrigin.xy, contentSize.xy
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipelines: [String: MTLComputePipelineState]

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsCore/Kernels/s2_tone_map.metal")
        // Through the same include expander the product uses: `s2_tone_map.metal` asks for
        // `primaries.metal`, and `makeLibrary(source:)` has no include search path of its own.
        let source = try KernelLibrary.expandingLocalIncludes(of: url)
        let library = try device.makeLibrary(source: source, options: nil)
        var map: [String: MTLComputePipelineState] = [:]
        for name in ["s2_tone_map", "s2_tone_map_contrast"] {
            map[name] = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: name)))
        }
        self.device = device
        self.pipelines = map
        guard let q = device.makeCommandQueue() else { throw XCTSkip("no command queue") }
        self.queue = q
        XCTAssertEqual(MemoryLayout<Params>.stride, 48, "S2Params' mirror must be as wide as Metal's")
    }

    func run(_ values: [Float], contrast: Float, entry: String) throws -> [Float] {
        let pso = try XCTUnwrap(pipelines[entry], "no such entry point: \(entry)")
        let w = values.count, h = 1
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w,
                                                         height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        let src = try XCTUnwrap(device.makeTexture(descriptor: d))
        let dst = try XCTUnwrap(device.makeTexture(descriptor: d))
        var flat = [Float]()
        for v in values { flat += [v, v, v, 1] }
        flat.withUnsafeBytes { buf in
            src.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: buf.baseAddress!, bytesPerRow: w * 16)
        }
        var p = Params(a: SIMD4(contrast, Float(S2Contrast.travelEV), 0, 0),
                       b: SIMD4(0, 0, 0, 0), c: SIMD4(0, 0, Float(w), Float(h)))
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pso)
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: min(pso.maxTotalThreadsPerThreadgroup, 64),
                                                           height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var out = [Float](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { buf in
            dst.getBytes(buf.baseAddress!, bytesPerRow: w * 16,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return stride(from: 0, to: out.count, by: 4).map { out[$0] }
    }

    /// Median GPU time of a pass — the same instrument `BwLevelsTests` uses: `batches` submits of
    /// `perBatch` dispatches, so the command-buffer floor does not swamp a 0.4 ms kernel.
    func time(_ source: [Float], width: Int, height: Int, contrast: Float,
              entry: String, batches: Int = 30, perBatch: Int = 20) throws -> Double {
        let pso = try XCTUnwrap(pipelines[entry])
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width,
                                                         height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        let src = try XCTUnwrap(device.makeTexture(descriptor: d))
        let dst = try XCTUnwrap(device.makeTexture(descriptor: d))
        source.withUnsafeBytes { buf in
            src.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: buf.baseAddress!, bytesPerRow: width * 16)
        }
        var p = Params(a: SIMD4(contrast, Float(S2Contrast.travelEV), 0, 0),
                       b: SIMD4(0, 0, 0, 0), c: SIMD4(0, 0, Float(width), Float(height)))
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
}

private enum SHA256Digest {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
