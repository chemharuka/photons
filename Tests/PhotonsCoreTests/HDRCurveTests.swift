import XCTest
import Metal
import CryptoKit
import PhotonsCore

/// 派单 030 — the HDR curve (S1.7), engine side.
///
/// The curve used to run **after** the tone map on 0…1 display data (`s3_curve`). It now runs before
/// S2, on unbounded scene-linear light, through the log1p shaper `u = log1p(x/x0)/K` on a 4 × 4096
/// table. Four families of claim, in the order they matter:
///
///   1. **Identity is the identity.** The table is `i/(N−1)` to 1.2e-7 and the kernel takes a copy
///      branch, so a document that never touched the curve renders the bytes it always did. Forced
///      through the arithmetic path the round trip is still ≤ 1.5e-6 relative (0.0002 of an 8-bit
///      code), which is 650× below the frame's own fp16 step.
///   2. **Monotone, everywhere.** Fritsch–Carlson + the tabulated `min(diff) ≥ 0` check (tolerance
///      0), and 2048 log-spaced levels through a hard S come out non-decreasing per channel: a curve
///      that folds would invert tones, and that is the one thing a curve may never do.
///   3. **The ends behave.** `x ≤ 0` passes through with its sign (018's sub-black detail), `x = 0`
///      therefore cannot be lifted, and above +4 EV the curve continues at its last segment's slope
///      instead of clamping — the pipeline's upper bound is the user's, not the code's.
///   4. **W is a luma gain, R/G/B are separable.** Hue and saturation survive the composite curve;
///      a curve on R cannot move G or B.
///
/// Millisecond numbers print on every run and are asserted only under `PHOTONS_BENCH=1` (project
/// rule: a wall-clock ceiling at these scales turns a busy machine into a red test).
final class HDRCurveTests: XCTestCase {

    private var benchmarks: Bool { ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" }

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String = "hdr-curve-test") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// `width × height`, every pixel the same linear RGB.
    private func solid(_ rgb: (Float, Float, Float), width: Int = 64, height: Int = 64) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = Float16(rgb.0)
            rgba[i + 1] = Float16(rgb.1)
            rgba[i + 2] = Float16(rgb.2)
            rgba[i + 3] = 1
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// Vertical bands, one linear grey level each — the shape every measurement below reads by band.
    private func bands(_ values: [Float], height: Int = 8) -> LinearImage {
        let width = values.count
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = Float16(values[x])
                let o = (y * width + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// `count` levels, geometrically spaced from `low` to `high` — a log scan, i.e. evenly spaced on
    /// the curve's own axis.
    private func logBands(count: Int, from low: Double, to high: Double, height: Int = 8) -> LinearImage {
        let values = (0..<count).map { i -> Float in
            let t = Double(i) / Double(max(count - 1, 1))
            return Float(low * pow(high / low, t))
        }
        return bands(values, height: height)
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel, headroom: Double = 1,
                        forceArithmetic: Bool = false) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: headroom),
                                    useCache: false, wantsPixels: true,
                                    forceCurveArithmetic: forceArithmetic)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    /// Per-band value: the centre column's red channel, in display units.
    private func bandValues(_ img: DisplayImage, count: Int) -> [Float] {
        (0..<count).map { i in
            let x = min(img.width - 1, max(0, Int((Double(i) + 0.5) * Double(img.width) / Double(count))))
            return Float(img.rgba[(img.height / 2 * img.width + x) * 4])
        }
    }

    private func channelValues(_ img: DisplayImage, count: Int, channel: Int) -> [Float] {
        (0..<count).map { i in
            let x = min(img.width - 1, max(0, Int((Double(i) + 0.5) * Double(img.width) / Double(count))))
            return Float(img.rgba[(img.height / 2 * img.width + x) * 4 + channel])
        }
    }

    private func encode(_ v: Float) -> Float {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    /// S4's OETF in `Double`, for expectations computed analytically.
    private func encodeD(_ v: Double) -> Double {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    /// S4's OETF, inverted: display units → linear light. The expectations in this file are stated
    /// in linear light, because that is where the shaper and the curve live.
    private func decode(_ c: Float) -> Double {
        let v = Double(c)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private func table(_ points: [CurvePoint], size: Int? = nil) -> [Float] {
        CurveLUT.buildOne(points, size: size)
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // Tests/PhotonsCoreTests/HDRCurveTests.swift
            .deletingLastPathComponent()     // Tests/PhotonsCoreTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // repo root
    }

    /// The first capture group of `pattern` in `text`, as a `Double`; `nil` when the pattern is absent.
    private func number(_ pattern: String, in text: String) throws -> Double? {
        let re = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Double(text[r])
    }

    // MARK: - ⓪ the axis itself, and the numbers the kernel documents

    /// 派单 044 moved the right end of the axis from 030's +6 EV to **+4 EV** (`xHI = 16`), to land on
    /// the histogram's own four-stop HDR tail (`Histogram.swift:189` `maxStops = 4`). Four positions
    /// are pinned here because the docs, the kernel header and (later) the curve panel all quote them:
    /// `u(0) = 0` exactly, `u(0.18) = 0.5955`, `u(1.0) = 0.7500`, `u(16) = 1` exactly.
    ///
    /// The kernel writes **no** constant of its own — it reads `x0`/`K`/stops-per-u out of
    /// `HDRCurveParams`, so the two sides cannot disagree in the arithmetic. What *can* drift is the
    /// header comment, which is the documentation a reader (and the next task) trusts; so it is
    /// parsed and compared with `HDRCurveAxis` instead, the same discipline `ChromaticAberrationTests`
    /// applies to `S0Params`.
    func testAxisIsFourStopsAndTheKernelHeaderAgrees() throws {
        let axis = HDRCurve.axis
        XCTAssertEqual(axis.x0, 1.0 / 4096.0)
        XCTAssertEqual(axis.xHI, 16, "044: the right end is +4 EV, xHI = 2^+4")
        XCTAssertEqual(axis.K, 11.0903701476, accuracy: 1e-9, "K = ln(1 + 16/x0) = ln(65537)")
        XCTAssertEqual(axis.stops, 16.0000220, accuracy: 1e-6, "K/ln 2 — the stops the axis spans")

        // The four pinned positions.
        XCTAssertEqual(axis.forward(0), 0, "u(0) must be exactly 0, or the black end cannot bend to 0")
        XCTAssertEqual(axis.forward(0.18), 0.5955, accuracy: 1e-4, "u(18 % grey)")
        XCTAssertEqual(axis.forward(1.0), 0.7500, accuracy: 1e-4,
                       "u(SDR white) — a quarter from the right end")
        XCTAssertEqual(axis.forward(axis.xHI), 1.0, accuracy: 1e-9, "u(+4 EV) = 1 exactly")
        XCTAssertEqual(axis.u(stops: 4), 1.0, accuracy: 1e-9, "…the same statement in stops")
        XCTAssertEqual(axis.u(stops: 0), 0.7500, accuracy: 1e-4, "SDR white is 0 EV")
        XCTAssertEqual(axis.forward(1.0 / 4096.0), 0.0625, accuracy: 1e-6,
                       "the black foot (0 … 2^-12) is 6.25 % of u")
        XCTAssertGreaterThan(axis.u(stops: 8), 1.0, "+8 EV is past u = 1 and still answers")
        XCTAssertEqual(axis.inverse(axis.forward(37.5)), 37.5, accuracy: 1e-9, "x → u → x")

        // The `.metal` header, parsed: xHI, K, both tabulated u positions, and stops per u.
        let url = Self.repoRoot.appendingPathComponent("Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("x0 = 2^-12"), "the kernel header must state x0")
        let docXHI = try XCTUnwrap(try number("K = ln\\(1 \\+ ([0-9.]+)/x0\\)", in: source),
                                   "the kernel header must state K = ln(1 + <xHI>/x0)")
        XCTAssertEqual(docXHI, axis.xHI, "the kernel header's xHI is not the axis's")
        let docK = try XCTUnwrap(try number("K = ln\\(1 \\+ [0-9.]+/x0\\) = ([0-9.]+)", in: source))
        XCTAssertEqual(docK, axis.K, accuracy: 1e-6, "the kernel header's K is not the axis's")
        let docGrey = try XCTUnwrap(try number("u\\(0\\.18\\) = ([0-9.]+)", in: source))
        XCTAssertEqual(docGrey, axis.forward(0.18), accuracy: 1e-4)
        let docWhite = try XCTUnwrap(try number("u\\(1\\.0\\) = ([0-9.]+)", in: source))
        XCTAssertEqual(docWhite, axis.forward(1.0), accuracy: 1e-4)
        let docEnd = try XCTUnwrap(try number("u = 1 ↔ \\+([0-9]+) EV", in: source))
        XCTAssertEqual(docEnd, 4, "the kernel header still claims a different right end")
        let docStops = try XCTUnwrap(try number("K/ln 2 = ([0-9.]+)", in: source))
        XCTAssertEqual(docStops, axis.stops, accuracy: 1e-6, "stops per unit u")

        // …and no stale +6 EV number survives in the file.
        for stale in ["0.5293", "0.6667", "12.4766531", "18.0000055", "64/x0"] {
            XCTAssertFalse(source.contains(stale), "the kernel header still says \(stale)")
        }
        print(String(format: "044 axis: xHI=%.0f K=%.7f stops=%.7f, u(0.18)=%.4f u(1)=%.4f u(16)=%.9f",
                     axis.xHI, axis.K, axis.stops, axis.forward(0.18), axis.forward(1.0),
                     axis.forward(axis.xHI)))
    }

    // MARK: - ① the identity table and the identity pixels

    /// The table is `i/(N−1)` to within double→single rounding, and an identity document renders the
    /// bytes a neutral one does: the kernel's rule 1 is a copy, so nothing is measured, rounded or
    /// rewritten.
    func testIdentityTableAndIdentityPixelsAreExact() throws {
        let t = table(CurvePoint.linear)
        XCTAssertEqual(t.count, CurveLUT.size)
        XCTAssertEqual(t[0], 0, "the first entry must be exactly 0")
        XCTAssertEqual(t[CurveLUT.size - 1], 1, "the last entry must be exactly 1")
        var worst: Float = 0
        for i in 0..<CurveLUT.size {
            worst = max(worst, abs(t[i] - Float(i) / Float(CurveLUT.size - 1)))
        }
        print("030 identity table: N=\(CurveLUT.size), max |table − i/(N−1)| = \(worst)")
        XCTAssertLessThanOrEqual(worst, 1.2e-7, "double→single rounding is the whole budget")
        XCTAssertTrue(CurveLUT.tablesAreIdentity(CurveLUT.build(.identity)))

        // Pixels: the copy branch is byte-for-byte.
        let graph = try makeGraph(solid((0.18, 0.1, 0.02)))
        var identityEdit = EditModel.neutral
        identityEdit.curve = CurveGroup(white: [CurvePoint(0, 0), CurvePoint(1, 1)])
        let neutral = try render(graph, .neutral)
        let identity = try render(graph, identityEdit)
        print("030 identity curve: neutral \(neutral.sha256().prefix(16))… vs identity \(identity.sha256().prefix(16))…")
        XCTAssertEqual(neutral.sha256(), identity.sha256(),
                       "an identity curve must not move one byte — the kernel takes the copy branch")
    }

    // MARK: - ② the arithmetic is (almost) the identity too

    /// Forced through the shaper (`identity = 0`), the round trip `x → u → table → u → x` stays within
    /// 1e-5 relative over four decades — the measured worst is 1.42e-6, i.e. 0.0002 of an 8-bit code,
    /// two orders below the fp16 storage it lands in.
    func testIdentityArithmeticRoundTrip() throws {
        let axis = HDRCurve.axis
        let t = table(CurvePoint.linear)
        let slope = CurveLUT.slope(of: t)

        var worst = 0.0
        var worstAt = 0.0
        // f32, like the kernel: the claim is about the GPU's arithmetic, not about `Double`.
        for i in 0...4000 {
            let x = pow(10.0, -6 + Double(i) / 4000 * (log10(64.0) + 6))
            let u = axis.forwardFloat(Float(x))
            let v = Float(HDRCurve.lutValue(t, slope: slope, u: Double(u)))
            let back = Double(axis.inverseFloat(v))
            let rel = abs(back - x) / x
            if rel > worst { worst = rel; worstAt = x }
        }
        // The same error as an 8-bit code, at the bright end where a code is worth the most.
        let codeError = abs(encodeD(1.0 * (1 + worst)) - encodeD(1.0)) * 255
        print(String(format: "030 identity arithmetic: max relative error %.3e at x = %.4g "
                     + "(≈%.4f 8-bit codes at white)", worst, worstAt, codeError))
        XCTAssertLessThanOrEqual(worst, 1e-5, "the shaper round trip, in f32")

        // The same claim through a real dispatch: the picture is the copy-path picture to within the
        // arithmetic's own error. headroom 64 keeps the tail visible.
        let values: [Float] = [1e-4, 3e-3, 0.02, 0.18, 0.5, 1, 2, 4, 8, 16, 32, 64]
        let graph = try makeGraph(bands(values))
        let copied = bandValues(try render(graph, .neutral, headroom: 64), count: values.count)
        let arithmetic = bandValues(try render(graph, .neutral, headroom: 64, forceArithmetic: true),
                                    count: values.count)
        var worstPixel = 0.0
        for (a, b) in zip(copied, arithmetic) where a > 0 {
            worstPixel = max(worstPixel, abs(Double(b - a)) / Double(a))
        }
        print(String(format: "030 identity arithmetic (GPU): max |Δ| %.3e relative over %d levels",
                     worstPixel, values.count))
        XCTAssertLessThanOrEqual(worstPixel, 1e-2,
                                 "copy path vs arithmetic path agree to within fp16 + shaper error")
    }

    // MARK: - ③ monotone by construction

    /// Five named shapes plus 20 random legal ones (2 % spacing, monotone y), on all four tables:
    /// `zip(lut, lut.dropFirst()).allSatisfy { $1 >= $0 }` with **tolerance 0**.
    func testEveryTableIsMonotone() {
        let shapes: [(String, [CurvePoint])] = [
            ("identity", CurvePoint.linear),
            ("S mild", [CurvePoint(0, 0), CurvePoint(0.25, 0.20), CurvePoint(0.75, 0.80), CurvePoint(1, 1)]),
            ("S hard", [CurvePoint(0, 0), CurvePoint(0.2, 0.03), CurvePoint(0.4, 0.22),
                        CurvePoint(0.6, 0.78), CurvePoint(0.8, 0.97), CurvePoint(1, 1)]),
            ("0.36-stop cliff", [CurvePoint(0, 0), CurvePoint(0.4, 0.35), CurvePoint(0.42, 0.75),
                                 CurvePoint(1, 1)]),
            ("roll-off", [CurvePoint(0, 0), CurvePoint(1, 0.86)]),
            ("black end lifted", [CurvePoint(0, 0.3), CurvePoint(1, 1)]),
        ]

        var seed: UInt64 = 0x5DEECE66D
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        var randoms: [(String, [CurvePoint])] = []
        for r in 0..<20 {
            var pts = [CurvePoint(0, Double(next()) * 0.2)]
            var x = 0.02
            var y = pts[0].y
            while x < 0.98 {
                y = min(1, y + next() * 0.25)
                pts.append(CurvePoint(x, y))
                x += 0.02 + next() * 0.08
            }
            pts.append(CurvePoint(1, min(1, y + next() * 0.2)))
            randoms.append(("random \(r)", pts))
        }

        for (name, points) in shapes + randoms {
            for (tableIndex, tableName) in ["W", "R", "G", "B"].enumerated() {
                var group = CurveGroup.identity
                switch tableIndex {
                case 0: group.white = points
                case 1: group.red = points
                case 2: group.green = points
                default: group.blue = points
                }
                let built = CurveLUT.build(group)[tableIndex * CurveLUT.size..<(tableIndex + 1) * CurveLUT.size]
                XCTAssertTrue(zip(built, built.dropFirst()).allSatisfy { $1 >= $0 },
                              "\(name) / \(tableName) is not monotone")
            }
        }
        print("030 monotonicity: \(shapes.count + randoms.count) shapes × 4 tables, tolerance 0 — all non-decreasing")
    }

    // MARK: - ④ monotone through pixels

    /// 2048 log-spaced levels (1e-5 … 64) through a hard S: the display values must never step back
    /// down. Per channel, because the tables are per channel.
    func testPixelMonotonicityThroughAHardS() throws {
        let count = 2048
        let image = logBands(count: count, from: 1e-5, to: 64)
        let graph = try makeGraph(image)
        let sCurve = [CurvePoint(0, 0), CurvePoint(0.2, 0.03), CurvePoint(0.4, 0.22),
                      CurvePoint(0.6, 0.78), CurvePoint(0.8, 0.97), CurvePoint(1, 1)]

        for (name, channel) in [("W", 0), ("R", 1), ("G", 2), ("B", 3)] {
            var edit = EditModel.neutral
            edit.curve = CurveGroup.identity
            switch channel {
            case 0: edit.curve.white = sCurve
            case 1: edit.curve.red = sCurve
            case 2: edit.curve.green = sCurve
            default: edit.curve.blue = sCurve
            }
            let values = channelValues(try render(graph, edit, headroom: 64), count: count,
                                       channel: channel)
            var drops = 0
            var worstDrop: Float = 0
            for i in 1..<count where values[i] < values[i - 1] {
                drops += 1
                worstDrop = max(worstDrop, values[i - 1] - values[i])
            }
            print(String(format: "030 pixel monotonicity (%@): %d levels, %d drops, worst %.3e",
                         name, count, drops, worstDrop))
            XCTAssertEqual(drops, 0, "\(name) curve folded over \(drops) of \(count) levels")
        }
    }

    // MARK: - ⑤ the ends

    /// Endpoint behaviour, measured where it is observable: `out(0) = 0` always (rule 3), the white
    /// end at `0.86` puts 64 (u = 1.125, two stops past +4 EV) at `64·2^(-0.14·1.125·16) ≈ 11.2`,
    /// and a black end pressed down still lets a 1e-4 pixel through (smaller than its input, but > 0).
    func testEndpointsBehave() throws {
        let values: [Float] = [1e-4, 0.18, 64]
        let graph = try makeGraph(bands(values))

        // Identity: 64 → 64, 1e-4 → 1e-4 (in display units, via S4 with a headroom that keeps it).
        let identity = bandValues(try render(graph, .neutral, headroom: 64), count: 3)
        // In linear light: the stored value is an fp16 sRGB code, and the encode's own rounding is
        // 5e-4 (`HeadroomTests` documents the same 0.9995 for a clamped 1.0).
        XCTAssertEqual(decode(identity[2]) / 64, 1, accuracy: 2e-3, "out(64) must be 64")

        // Black end lifted to 0.10: an exact 0 input still comes out 0 (rule 3), not 0.0012.
        let zeroImage = bands([0, 1e-4])
        let zeroGraph = try makeGraph(zeroImage, identity: "hdr-curve-zero")
        var lifted = EditModel.neutral
        lifted.curve.white = [CurvePoint(0, 0.10), CurvePoint(1, 1)]
        let liftedOut = bandValues(try render(zeroGraph, lifted, headroom: 64), count: 2)
        print(String(format: "030 endpoints: lifted (0,0.10): x=0 → %.6f, x=1e-4 → %.6f",
                     liftedOut[0], liftedOut[1]))
        XCTAssertEqual(liftedOut[0], 0, "rule 3: an exact 0 cannot be lifted by the curve")
        XCTAssertGreaterThan(liftedOut[1], encode(1e-4), "but a 1e-4 pixel is lifted, and by a lot")

        // White end rolled off to 0.86: out(64) = 64·2^(-0.14·18).
        var rolled = EditModel.neutral
        rolled.curve.white = [CurvePoint(0, 0), CurvePoint(1, 0.86)]
        let rolledOut = bandValues(try render(graph, rolled, headroom: 64), count: 3)
        // 64 is +6 EV — **past** the axis's right end (u(64) = 1.125), so the roll-off continues on
        // rule 4's slope: for `(0,0)…(1,1−r)` the map above u = 1 is `v = (1−r)·u`, i.e. a shift of
        // `−r·u`, not `−r`. Only at u = 1 (i.e. x = xHI = 16) are the two the same.
        let u64 = HDRCurve.axis.forward(64)
        let expected = 64 * pow(2.0, -0.14 * u64 * HDRCurve.axis.stops)
        print(String(format: "030 endpoints: roll-off (1,0.86): x=64 → %.4f (analytic %.4f)",
                     Double(rolledOut[2]), expected))
        XCTAssertEqual(Double(rolledOut[2]), encodeD(expected), accuracy: 0.01 * encodeD(expected),
                       "the white end's roll-off must land where the shaper says")

        // Black end pressed *and* the middle pulled down: 1e-4 gets smaller but stays positive.
        var pressed = EditModel.neutral
        pressed.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, 0.3), CurvePoint(1, 1)]
        let pressedOut = bandValues(try render(graph, pressed, headroom: 64), count: 3)
        XCTAssertGreaterThan(pressedOut[0], 0, "a pressed curve must not delete the 1e-4 level")
        XCTAssertLessThan(pressedOut[0], identity[0], "…it must make it darker")
    }

    // MARK: - ⑥ the HDR tail is not clamped

    /// Eight levels including the far tail, through the **arithmetic** path (the copy branch would
    /// make this vacuous): every level comes back as itself, and S4 with headroom 16 keeps them
    /// strictly increasing.
    func testHDRExtendIsNotClamped() throws {
        let values: [Float] = [0.5, 1, 2, 4, 8, 16, 32, 64]
        let graph = try makeGraph(bands(values))
        let out = bandValues(try render(graph, .neutral, headroom: 64, forceArithmetic: true),
                             count: values.count)
        for (i, v) in values.enumerated() {
            let linear = decode(out[i])
            XCTAssertEqual(linear, Double(v), accuracy: Double(v) * 1e-2,
                           "level \(v) came back as \(linear)")
        }

        // S4 clamps at `headroom`, so the "strictly increasing" half uses a ladder that fits under
        // it (0.125 … 16) — otherwise 32 and 64 land on the same 16.0 and the test would be
        // measuring the ceiling it just set, not the curve.
        let ladder: [Float] = [0.125, 0.25, 0.5, 1, 2, 4, 8, 16]
        let ladderGraph = try makeGraph(bands(ladder), identity: "hdr-curve-ladder")
        let headroom16 = bandValues(try render(ladderGraph, .neutral, headroom: 16), count: ladder.count)
        for i in 1..<ladder.count {
            XCTAssertGreaterThan(headroom16[i], headroom16[i - 1],
                                 "level \(ladder[i]) did not survive S4 at headroom 16")
        }

        // The counter-example: a white end at 0.5 is a *user-drawn* ceiling — everything above
        // u = 0.5 (x > 0.125) collapses onto one value, and that is correct behaviour.
        let ceiling = [Float(0.2), 0.5, 1, 2, 4, 8, 16, 32, 64]
        let ceilGraph = try makeGraph(bands(ceiling), identity: "hdr-curve-ceiling")
        var ceilEdit = EditModel.neutral
        ceilEdit.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, 0.5), CurvePoint(1, 0.5)]
        let ceilOut = bandValues(try render(ceilGraph, ceilEdit, headroom: 64), count: ceiling.count)
        print("030 ceiling curve (1,0.5): " + ceilOut.map { String(format: "%.4f", $0) }.joined(separator: " "))
        for i in 2..<ceiling.count {
            XCTAssertEqual(ceilOut[i], ceilOut[1], accuracy: 1e-4,
                           "above the user's ceiling every level lands on the same value")
        }
    }

    // MARK: - ⑦ beyond +4 EV

    /// Rule 4: the slope continues. Identity is identity at 1000 (through the arithmetic path), a
    /// slope of 0 is a hard ceiling at 16, and 128 comes back as 128 at slope 1.
    func testBeyondPlusFourEVContinues() throws {
        let values: [Float] = [128, 1000]
        let graph = try makeGraph(bands(values))
        let out = bandValues(try render(graph, .neutral, headroom: 4096, forceArithmetic: true),
                             count: 2)
        let back128 = decode(out[0])
        let back1000 = decode(out[1])
        print(String(format: "030 beyond +4 EV: 128 → %.4f, 1000 → %.4f", back128, back1000))
        // Display values above 1 are the sRGB encode continued; decode through the analytic curve in
        // linear space instead, where the claim is stated.
        XCTAssertEqual(back128 / 128, 1, accuracy: 1e-2, "x = 128 at slope 1 must stay 128")
        XCTAssertEqual(back1000 / 1000, 1, accuracy: 1e-2, "x = 1000 at slope 1 must stay 1000")

        // Slope 0: the user's ceiling at xHI (+4 EV).
        XCTAssertEqual(CurveLUT.slope(of: table([CurvePoint(0, 0), CurvePoint(0.99, 1), CurvePoint(1, 1)])),
                       0, accuracy: 1e-6, "a flat last segment has slope 0")

        var hardTop = EditModel.neutral
        hardTop.curve.white = [CurvePoint(0, 0), CurvePoint(0.99, 1), CurvePoint(1, 1)]
        let topOut = bandValues(try render(graph, hardTop, headroom: 4096), count: 2)
        let top1000 = decode(topOut[1])
        print(String(format: "030 ceiling at the white end: 1000 → %.4f", top1000))
        XCTAssertEqual(top1000, 16, accuracy: 0.5, "slope 0 means 16 (+4 EV) and no further")
    }

    // MARK: - ⑧ sub-black passes through

    /// 018's staircase, through a curve that would lift it if it could: the negative bands stay at
    /// the display's 0 while the positive band moves. The CPU reference says the same thing exactly:
    /// `channel(x) == x` for every `x ≤ 0`, bit for bit.
    func testNegativeInputsPassThrough() throws {
        let values: [Float] = [-0.004, -0.003, -0.002, -0.001, 0.0, 0.001]
        let graph = try makeGraph(bands(values))

        var lifted = EditModel.neutral
        lifted.curve.white = [CurvePoint(0, 0.4), CurvePoint(1, 1)]

        let base = bandValues(try render(graph, .neutral), count: values.count)
        let curved = bandValues(try render(graph, lifted), count: values.count)
        for i in 0..<5 {
            XCTAssertEqual(curved[i], base[i],
                           "band \(values[i]) moved: a curve must not touch sub-black or 0")
            XCTAssertEqual(curved[i], 0, "S4 clamps the negative band to 0, as it always did")
        }
        XCTAssertGreaterThan(curved[5], base[5], "the positive band must still follow the curve")

        // The reference arithmetic: sign-preserving, exact.
        let t = table([CurvePoint(0, 0.4), CurvePoint(1, 1)])
        let slope = CurveLUT.slope(of: t)
        for x in [-0.039, -0.004, -1e-9, 0.0] {
            XCTAssertEqual(HDRCurve.channel(x, table: t, slope: slope), x,
                           "channel(\(x)) must be \(x)")
        }
    }

    // MARK: - ⑧b (061) a raised black point is a clip — in the table and in the pixels

    /// 061 ①：首端点右移到 `u = 0.2` → 表里 `u < 0.2` 是常量，渲染上整段暗部被压到**同一个**输出。
    ///
    /// `u = 0.2` 是 `x = x0·expm1(0.2·K) ≈ 2.0e-3`，所以下面五个输入都在段内。三条通道给同一条曲线，
    /// 灰色带因此整段变成同一个灰值 —— 相等是像素级的，不是"红通道大致相同"。
    /// **反证**：同一条曲线把首点放回 0（051 只能画出的形状），同样的五个输入是斜坡，不是常量。
    func testRaisedBlackPointFlattensTheShadowFootToOneValueInPixels() throws {
        let axis = HDRCurve.axis
        let edge = axis.inverse(0.2)
        print(String(format: "061 black point: u = 0.2 ↔ x = %.6f linear（段内输入都在它下面）", edge))
        XCTAssertGreaterThan(edge, 1.5e-3, "1.5e-3 必须真的在 u = 0.2 以下")

        let below: [Float] = [8e-5, 2e-4, 5e-4, 1e-3, 1.5e-3]
        let above: [Float] = [4e-3, 0.02, 0.18, 1.0]
        let values = below + above
        let graph = try makeGraph(bands(values))

        let raised: [CurvePoint] = [CurvePoint(0.2, 0.3), CurvePoint(0.6, 0.5), CurvePoint(1, 1)]
        var edit = EditModel.neutral
        edit.curve.red = raised
        edit.curve.green = raised
        edit.curve.blue = raised
        let out = bandValues(try render(graph, edit), count: values.count)

        let flat = Set(out.prefix(below.count))
        XCTAssertEqual(flat.count, 1, "u < 0.2 的每个输入都必须映射到同一个输出，实际 \(flat.sorted())")
        XCTAssertEqual(out[0], out[below.count - 1], "段的两端也必须相等")
        // 不是"整张图变黑"：段外仍在上升，且被裁到的那个值确实抬高了暗部
        XCTAssertGreaterThan(out[below.count + 1], out[below.count], "0.2 之上必须还在上升")

        // 整帧的 min/max/mean：暗部的下限被抬到那个常量上，均值随之上升 —— "压平"看得见
        let clippedImage = try render(graph, edit)
        let neutralImage = try render(graph, .neutral)
        func stats(_ img: DisplayImage) -> (min: Float, max: Float, mean: Double) {
            var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
            var sum = 0.0
            let n = img.width * img.height
            for i in 0..<n {
                let v = Double(img.rgba[i * 4])
                lo = min(lo, v); hi = max(hi, v); sum += v
            }
            return (Float(lo), Float(hi), sum / Double(max(n, 1)))
        }
        let clippedStats = stats(clippedImage), neutralStats = stats(neutralImage)
        XCTAssertGreaterThan(clippedStats.min, neutralStats.min, "最暗的像素必须被抬起来（裁到 first.y）")
        XCTAssertEqual(clippedStats.min, out[0], accuracy: 1e-5, "整帧最暗值 == 段内的常量")
        print(String(format: "061 frame min/max/mean: neutral %.4f/%.4f/%.4f → 抬黑点 %.4f/%.4f/%.4f",
                     neutralStats.min, neutralStats.max, neutralStats.mean,
                     clippedStats.min, clippedStats.max, clippedStats.mean))

        // **反证**：051 的形状（首点钉在 0），同样的五个输入是斜坡
        var pinned = EditModel.neutral
        let pinnedCurve: [CurvePoint] = [CurvePoint(0, 0), CurvePoint(0.6, 0.5), CurvePoint(1, 1)]
        pinned.curve.red = pinnedCurve
        pinned.curve.green = pinnedCurve
        pinned.curve.blue = pinnedCurve
        let pinnedOut = bandValues(try render(graph, pinned), count: values.count)
        XCTAssertGreaterThan(Set(pinnedOut.prefix(below.count)).count, 1,
                             "钉死的端点：暗部是斜坡，不是常量")

        // 表与 CPU 参考说的是同一件事
        let t = table(raised)
        XCTAssertEqual(Set((0..<100).map { t[$0 * (Int(0.2 * Double(CurveLUT.size)) / 100)] }).count, 1,
                       "表里 u < 0.2 的 100 个抽样全等")
        XCTAssertEqual(HDRCurve.channel(1e-4, table: t, slope: CurveLUT.slope(of: t), blackPoint: 0.2),
                       axis.inverse(Double(t[0])), accuracy: 1e-12)

        print(String(format: "061 clip: 段内 5 个输入 → %d 个显示值（%.4f）；钉死则 %d 个（%.4f…%.4f）",
                     flat.count, out[0], Set(pinnedOut.prefix(below.count)).count,
                     pinnedOut[0], pinnedOut[below.count - 1]))
    }

    /// 061 ⑤：**两种 sub-black 情况**，一条都不许被"裁切"顺手删掉。
    ///
    ///   · `first.x == 0` → 018 的阶梯原样穿过（负值不动、0 不动）；
    ///   · `first.x == 0.2` → 负值也落到表里 `u = 0` 的那个常量上：抬黑点是一次**裁切**，不是一次
    ///     只对正值生效的暗部拉伸。
    func testSubBlackIsClippedOnlyWhenTheBlackPointMoves() throws {
        let values: [Float] = [-0.004, -0.003, -0.002, -0.001, 0.0, 0.001]
        let graph = try makeGraph(bands(values))
        let base = bandValues(try render(graph, .neutral), count: values.count)

        // (a) 018：曲线起于零光 → 负值与 0 一个字节都不动
        var startsAtZero = EditModel.neutral
        startsAtZero.curve.white = [CurvePoint(0, 0.4), CurvePoint(1, 1)]
        let atZero = bandValues(try render(graph, startsAtZero), count: values.count)
        for i in 0..<5 {
            XCTAssertEqual(atZero[i], base[i], "first.x == 0：band \(values[i]) 被动了（018 回归）")
        }
        XCTAssertGreaterThan(atZero[5], base[5], "正值那一带仍随曲线走")

        // (b) 061：黑点右移到 0.2 → 整段（负值 + 0）裁到同一个常量
        let lifted: [CurvePoint] = [CurvePoint(0.2, 0.3), CurvePoint(1, 1)]
        var raised = EditModel.neutral
        raised.curve.red = lifted
        raised.curve.green = lifted
        raised.curve.blue = lifted
        let clipped = bandValues(try render(graph, raised), count: values.count)
        XCTAssertEqual(Set(clipped.prefix(5)).count, 1,
                       "负值与 0 必须是同一个输出（裁切不能有洞），实际 \(clipped.prefix(5))")
        XCTAssertGreaterThan(clipped[0], base[0], "被裁到 first.y 的常量上，不是穿过去再被 S2 压成 0")

        // CPU 参考：同一条规则，两种结果
        let t = table(lifted)
        let slope = CurveLUT.slope(of: t)
        let clip = HDRCurve.axis.inverse(Double(t[0]))
        for x in [-0.004, -0.001, 0.0] {
            XCTAssertEqual(HDRCurve.channel(x, table: t, slope: slope, blackPoint: 0.2), clip,
                           accuracy: 1e-12, "\(x) 必须等于常量 \(clip)")
            XCTAssertEqual(HDRCurve.channel(x, table: t, slope: slope, blackPoint: 0), x,
                           "反证：同一个表按 first.x == 0 走，\(x) 会原样穿过（两条路必须不同）")
        }

        print(String(format: "061 sub-black: 0 黑点 → 阶梯不动（%d 个值）；0.2 黑点 → 常量 %.5f",
                     5, clipped[0]))
    }

    // MARK: - ⑨ W is a luma gain

    /// A saturated pixel through a W-only curve keeps its hue: `r/g` and `b/g` are invariant, and a
    /// grey pixel moves by exactly the curve's own exposure offset.
    func testWhiteIsALumaGain() throws {
        let colour: (Float, Float, Float) = (0.6, 0.2, 0.1)
        let graph = try makeGraph(solid(colour))
        var edit = EditModel.neutral
        edit.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]

        let base = try render(graph, .neutral, headroom: 64)
        let curved = try render(graph, edit, headroom: 64)

        func linear(_ img: DisplayImage) -> (Double, Double, Double) {
            (decode(Float(img.rgba[0])), decode(Float(img.rgba[1])), decode(Float(img.rgba[2])))
        }
        let a = linear(base), b = linear(curved)
        let ratioRG = (b.0 / b.1) / (a.0 / a.1)
        let ratioBG = (b.2 / b.1) / (a.2 / a.1)
        print(String(format: "030 W luma gain: r/g ratio %.6f, b/g ratio %.6f (both must be 1)",
                     ratioRG, ratioBG))
        XCTAssertEqual(ratioRG, 1, accuracy: 2e-3, "the composite curve changed saturation")
        XCTAssertEqual(ratioBG, 1, accuracy: 2e-3, "the composite curve changed saturation")

        // A grey pixel moves by the curve's own offset, read off the analytic reference.
        let grey = try makeGraph(solid((0.18, 0.18, 0.18)), identity: "hdr-curve-grey")
        let tables = CurveLUT.build(edit.curve)
        let slopes = CurveLUT.slopes(tables)
        let expected = HDRCurve.pixel((0.18, 0.18, 0.18), tables: tables, slopes: slopes).0
        let got = try render(grey, edit, headroom: 64)
        let gotLinear = decode(Float(got.rgba[0]))
        print(String(format: "030 W gain on 0.18 grey: expected %.6f linear, got %.6f (%.3f stops)",
                     expected, gotLinear, log2(gotLinear / 0.18)))
        XCTAssertEqual(gotLinear / expected, 1, accuracy: 5e-3)
    }

    // MARK: - ⑩ R/G/B are separable

    /// A curve on R only: G and B come out of the curve stage untouched, so the display bytes for
    /// those channels are the ones the neutral render had.
    func testChannelsAreIndependent() throws {
        let graph = try makeGraph(solid((0.35, 0.45, 0.55)))
        var redOnly = EditModel.neutral
        redOnly.curve.red = [CurvePoint(0, 0), CurvePoint(0.5, 0.3), CurvePoint(1, 1)]

        let base = try render(graph, .neutral, headroom: 64)
        let curved = try render(graph, redOnly, headroom: 64)
        for channel in 1...2 {
            XCTAssertEqual(curved.rgba[channel].bitPattern, base.rgba[channel].bitPattern,
                           "channel \(channel) moved when only R had a curve")
        }
        XCTAssertNotEqual(curved.rgba[0].bitPattern, base.rgba[0].bitPattern,
                          "the R curve must actually change R")
    }

    // MARK: - ⑪ LUT precision (the gate on N = 4096)

    /// A 2 %-wide cliff — the narrowest gesture the editor allows — measured against the same spline
    /// sampled 16× finer, in 8-bit sRGB codes. Two worst cases are reported, because 044 changed what
    /// the scan's far end means: `inside` is the error where the table interpolates (`u ≤ 1`, the
    /// axis), and `all` includes the rule-4 extrapolation above +4 EV, where the value is not
    /// interpolated at all but continued at each table's own estimate of the last slope.
    ///
    /// At N = 4096 the error **inside the axis** is 0.045 codes — it was 0.085 on the +6 EV axis (the
    /// same scan with `xHI = 64`), because the shorter axis spends 11.09 instead of 12.48 of `K` per
    /// unit `u`, i.e. fewer stops per table entry; the worst sample moves to x = 0.025, the cliff's own
    /// shoulder. The `all` figure is 0.131 and its worst sample is x = 64 — two stops past the right end
    /// since 044 — where the two tables' last-slope estimates disagree, so it measures rule 4's
    /// continuation, not the interpolation. At N = 1024 the same measurement is 1.218 codes on the old
    /// axis and 0.705 now, which is why the assertion still has teeth (and N = 2048, 0.179, sits
    /// between them).
    func testTablePrecisionIsWhy4096() {
        let cliff = [CurvePoint(0, 0), CurvePoint(0.4, 0.35), CurvePoint(0.42, 0.75), CurvePoint(1, 1)]
        let reference = table(cliff, size: 65536)
        let referenceSlope = CurveLUT.slope(of: reference)

        /// `(all, inside u ≤ 1)` worst 8-bit code error at `n` entries, plus the `x` that produced each.
        func worstCodeError(_ n: Int) -> (all: Double, inside: Double, allAt: Double, insideAt: Double) {
            let t = table(cliff, size: n)
            let slope = CurveLUT.slope(of: t)
            var all = 0.0, inside = 0.0, allAt = 0.0, insideAt = 0.0
            let samples = 4000
            for i in 0...samples {
                let x = pow(10.0, -4 + Double(i) / Double(samples) * (log10(64.0) + 4))
                let u = HDRCurve.axis.forward(x)
                let a = HDRCurve.axis.inverse(HDRCurve.lutValue(t, slope: slope, u: u))
                let b = HDRCurve.axis.inverse(HDRCurve.lutValue(reference, slope: referenceSlope, u: u))
                let e = abs(encodeD(a) - encodeD(b)) * 255
                if e > all { all = e; allAt = x }
                if u <= 1, e > inside { inside = e; insideAt = x }
            }
            return (all, inside, allAt, insideAt)
        }

        let e1024 = worstCodeError(1024)
        let e2048 = worstCodeError(2048)
        let e4096 = worstCodeError(4096)
        print(String(format: "030 table precision (2%% cliff, 8-bit codes): N=1024 %.3f, N=2048 %.3f, "
                     + "N=4096 %.3f (inside the axis: %.3f / %.3f / %.3f); worst sample at x = %.4g "
                     + "(N=4096, all) and x = %.4g (N=4096, inside)",
                     e1024.all, e2048.all, e4096.all, e1024.inside, e2048.inside, e4096.inside,
                     e4096.allAt, e4096.insideAt))
        XCTAssertLessThanOrEqual(e4096.all, 0.3, "N = 4096 must stay under 0.3 codes")
        XCTAssertLessThanOrEqual(e4096.inside, 0.3, "…and inside the axis too")
        XCTAssertGreaterThan(e1024.inside, 0.3, "if this passes, the assertion above proves nothing")
        XCTAssertGreaterThan(e2048.inside, e4096.inside, "the error must fall with N, or the measurement is broken")
    }

    // MARK: - ⑫ the mount point

    /// `.curve` sits between S1.6 and S2, its own key material moves when the curve does, and nothing
    /// above it does — that is the whole reason it is a stage and not a second dispatch in S1.
    func testMountPointAndKeyChain() throws {
        let order = RenderStage.order
        let curveIndex = try XCTUnwrap(order.firstIndex(of: .curve))
        XCTAssertEqual(order[curveIndex - 1], .localApply, "the curve must read S1.6's output")
        XCTAssertEqual(order[curveIndex + 1], .toneMap, "S2 must read the curve's output")
        XCTAssertEqual(RenderStage.allCases.firstIndex(of: .curve), 2)
        XCTAssertEqual(RenderStage.curve.short, "s1.7")
        XCTAssertEqual(RenderStage.curve.rawValue, "s1.7-hdr-curve")

        func links(_ edit: EditModel) -> RenderKeyChain.Links {
            RenderKeyChain.links(identity: "mount", sourceSize: ImageSize(width: 4000, height: 3000),
                                 canvas: ImageSize(width: 1500, height: 1000),
                                 content: ImageSize(width: 1500, height: 1000),
                                 edit: edit, display: DisplayOptions())
        }

        var withMask = EditModel.neutral
        withMask.masks = [Mask(id: "m", components: [MaskComponent(id: "c", shape: .linearGradient(.default))])]
        var curved = withMask
        curved.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]

        let a = links(withMask), b = links(curved)
        XCTAssertNotEqual(a.curve, b.curve, "a curve change must move its own key")
        XCTAssertEqual(a.sceneLinear, b.sceneLinear, "…and not S1's")
        XCTAssertEqual(a.maskAtlas, b.maskAtlas, "…and not rebuild the atlas")
        XCTAssertEqual(a.localApply, b.localApply, "…nor the local stage")
        XCTAssertNotEqual(a.toneMap, b.toneMap, "…but S2 reads the curve, so it must miss")

        // The chain: exposure moves everything below it, including the curve's key.
        var brighter = withMask
        brighter.light.exposure = 1
        XCTAssertNotEqual(links(brighter).curve, a.curve, "an exposure change must move the curve's key")
    }

    // MARK: - black / white level fields

    /// The two absolute level fields are the *level*, not the curve: `blackLevel` puts 0 exactly where
    /// the sample was, `whiteLevel` puts 1 there, and the absolute spelling wins over the slider.
    func testAbsoluteLevelsPlaceZeroAndOne() throws {
        // 2^-6 = 0.015625: a level the fp16 fixture can hold *exactly*, so "the sampled point maps to
        // exactly 0" is a claim about the renderer and not about the fixture's rounding.
        let values: [Float] = [0.001875, 0.0078125, 0.015625, 0.05, 0.18]
        let graph = try makeGraph(bands(values))

        var levelled = EditModel.neutral
        levelled.light.blackLevel = 0.015625
        levelled.light.blacks = 100          // deliberately contradictory: the absolute field wins
        let out = bandValues(try render(graph, levelled), count: values.count)
        print("030 blackLevel 0.015625: " + out.map { String(format: "%.4f", $0) }.joined(separator: " "))
        XCTAssertEqual(out[2], 0, "the sampled point must land on exactly 0")
        XCTAssertEqual(out[0], 0, "anything darker is 0 too")
        XCTAssertEqual(out[1], 0, "anything darker is 0 too")
        XCTAssertGreaterThan(out[3], 0)
        XCTAssertGreaterThan(out[4], out[3], "brighter input must stay brighter")
        XCTAssertEqual(levelled.light.levels.black, 0.015625, "the absolute field wins over `blacks`")

        let whiteValues: [Float] = [0.5, 1.0, 2.0]
        let whiteGraph = try makeGraph(bands(whiteValues), identity: "hdr-curve-white")
        var whited = EditModel.neutral
        whited.light.whiteLevel = 2.0
        let whiteOut = bandValues(try render(whiteGraph, whited), count: 3)
        print("030 whiteLevel 2.0: " + whiteOut.map { String(format: "%.4f", $0) }.joined(separator: " "))
        // 0.9995 rather than 1.0 is the fp16 store of `1.055 − 0.055`, not a levelling error — the
        // same half-ulp `HeadroomTests` pins for a clamped 1.0.
        XCTAssertEqual(whiteOut[2], 1, accuracy: 1e-3, "+1 EV must be display white")
        XCTAssertEqual(whiteOut[1], encode(0.5), accuracy: 2e-3, "1.0 → 0.5 linear")
        XCTAssertEqual(whiteOut[0], encode(0.25), accuracy: 2e-3, "0.5 → 0.25 linear")

        // Envelope and cross-constraint, in one place (`LightGroup.levels`).
        var out0 = EditModel.neutral
        out0.light.blackLevel = 99
        XCTAssertEqual(out0.light.levels.black, LightGroup.blackLevelRange.upperBound)
        var crossed = EditModel.neutral
        crossed.light.blackLevel = 0.4
        crossed.light.whiteLevel = 0.4
        XCTAssertGreaterThanOrEqual(crossed.light.levels.white - crossed.light.levels.black, 1e-3)
    }

    /// 061 ③：**曲线端点和黑电平是两件事，顺序是先电平后曲线** —— 而且它们**不合并**。
    ///
    /// `light.blackLevel` 是 S1 的线性电平（019），`first.x` 是曲线域的裁切（061）。S1 在 S1.7 之前
    /// （`RenderStage.order`），所以曲线看到的是**已经电平过的**值：黑电平 0.10 把 0.1011 压到 0.0012，
    /// 而曲线黑点的裁切边是 `u = 0.2 ↔ x = 2.0e-3` —— 于是这一带正好被曲线裁成同一个值。
    /// **反证**：黑电平归零时同样的输入在裁切边之上，曲线一个都不裁。
    func testBlackLevelRunsBeforeTheCurveSoTheBlackPointSeesTheLevelledValue() throws {
        let values: [Float] = [0.1011, 0.1012, 0.105, 0.15, 0.5]
        let graph = try makeGraph(bands(values), identity: "curve-levels")

        let lifted: [CurvePoint] = [CurvePoint(0.2, 0), CurvePoint(0.6, 0.45), CurvePoint(1, 1)]
        var both = EditModel.neutral
        both.light.blackLevel = 0.10          // +10 % of white, in S1's linear units
        both.curve.red = lifted
        both.curve.green = lifted
        both.curve.blue = lifted
        let out = bandValues(try render(graph, both), count: values.count)

        // S1 first: 0.1011 → (0.1011 − 0.10)/0.9 = 1.2e-3, below the curve's 2.0e-3 edge → clipped.
        XCTAssertEqual(out[0], 0, "S1 电平把它压到裁切边之下 → 曲线裁成 0")
        XCTAssertEqual(out[1], 0)
        XCTAssertGreaterThan(out[2], 0, "0.105 电平后仍高于裁切边，曲线不裁")
        XCTAssertGreaterThan(out[3], out[2])
        XCTAssertGreaterThan(out[4], out[3], "曲线仍单调")

        // 反证：同一个曲线，黑电平归零 → 同样的输入全在裁切边之上，一个都不裁
        var curveOnly = EditModel.neutral
        curveOnly.curve.red = lifted
        curveOnly.curve.green = lifted
        curveOnly.curve.blue = lifted
        let plain = bandValues(try render(graph, curveOnly), count: values.count)
        XCTAssertGreaterThan(plain[0], 0.02, "没有电平，0.1011 远在 2.0e-3 之上 → 不裁")
        XCTAssertNotEqual(plain[0], 0)

        // 两条规则各自只脏自己那一级：电平整 S1，曲线整 S1.7 —— 谁也不是谁的别名
        XCTAssertEqual(both.changedStages(from: curveOnly), [.sceneLinear])
        XCTAssertEqual(curveOnly.changedStages(from: .neutral), [.curve])

        print("061 levels+curve · blackLevel 0.10 + first.x 0.2: "
              + out.map { String(format: "%.4f", $0) }.joined(separator: " ")
              + " · 只有曲线: " + plain.map { String(format: "%.4f", $0) }.joined(separator: " "))
    }

    /// The fields are a level (S1), so they dirty exactly what the sliders do — and the curve dirties
    /// only itself. `changedStages` is group-level by design (D10): downstream is the key chain's job.
    func testDirtyStages() {
        var base = EditModel.neutral
        base.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]

        var newer = base
        newer.light.blackLevel = 0.02
        XCTAssertEqual(newer.changedStages(from: base), [.sceneLinear])

        var whiteNext = base
        whiteNext.light.whiteLevel = 2
        XCTAssertEqual(whiteNext.changedStages(from: base), [.sceneLinear])

        var curved = base
        curved.curve.white = [CurvePoint(0, 0), CurvePoint(0.6, 0.4), CurvePoint(1, 1)]
        XCTAssertEqual(curved.changedStages(from: base), [.curve])

        var warm = base
        warm.light.temperature = 5200
        XCTAssertEqual(warm.changedStages(from: base), Set(RenderStage.allCases),
                       "a decode change is every stage, as always")
    }

    /// The level fields write `blL`/`whL` into S1's material **only when set**, so a document that
    /// never touched them keeps its key (§3.2 discipline), and one that did can never share a cached
    /// S1 buffer.
    func testLevelFieldsJoinTheSceneLinearKeyOnlyWhenSet() {
        let plain = EditModel.neutral.keyMaterial(.sceneLinear)
        XCTAssertFalse(plain.contains("blL"), "an unset level must not appear in the key")
        XCTAssertFalse(plain.contains("whL"))

        var withBlack = EditModel.neutral
        withBlack.light.blackLevel = 0.013
        XCTAssertTrue(withBlack.keyMaterial(.sceneLinear).contains("blL=0.01300"))
        XCTAssertFalse(withBlack.keyMaterial(.sceneLinear).contains("whL"))

        var withWhite = EditModel.neutral
        withWhite.light.whiteLevel = 2
        XCTAssertTrue(withWhite.keyMaterial(.sceneLinear).contains("whL=2.00000"))
        XCTAssertFalse(withWhite.keyMaterial(.sceneLinear).contains("blL"))
    }

    // MARK: - the model: names and versions

    /// `curve.white` is the stored name, a schema-3 document's `rgb` reads back into it, and only
    /// `white` is written. `schemaVersion` 4 / `processVersion` 2 record the meaning change.
    func testCurveModelNamingAndVersion() throws {
        XCTAssertEqual(EditModel.currentSchemaVersion, 4)
        XCTAssertEqual(EditModel.currentProcessVersion, 2)

        let legacy = Data(#"""
        { "schemaVersion": 3, "processVersion": 1,
          "curve": { "rgb": [ {"x":0,"y":0}, {"x":0.5,"y":0.62}, {"x":1,"y":1} ] } }
        """#.utf8)
        let old = try JSONDecoder().decode(EditModel.self, from: legacy)
        XCTAssertEqual(old.curve.white.count, 3, "the schema-3 `rgb` key must land in `white`")
        XCTAssertEqual(old.curve.white[1], CurvePoint(0.5, 0.62))

        let encoded = try JSONEncoder().encode(old.curve)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("\"white\""), "white is the stored name: \(text)")
        XCTAssertFalse(text.contains("\"rgb\""), "the old name must not be written back: \(text)")

        let round = try JSONDecoder().decode(CurveGroup.self, from: encoded)
        XCTAssertEqual(round, old.curve)
    }

    // MARK: - bench

    /// The numbers §6.4 and §12.4 ask for, printed on every run and asserted only under
    /// `PHOTONS_BENCH=1`: the table build (one table and all four) and one S1.7 pass at 4.10 Mpx and
    /// at 60 MP.
    ///
    /// The GPU number is measured as the **difference** between the arithmetic path and the copy
    /// path on the same canvas: the copy branch is what "no curve" costs, so the delta is the pass
    /// the curve actually adds.
    func testFrameAndTableCosts() throws {
        // Tables: one changed table, then all four (a document switch).
        let pointSets: [[CurvePoint]] = [
            [CurvePoint(0, 0), CurvePoint(0.2, 0.05), CurvePoint(0.5, 0.5), CurvePoint(0.8, 0.95), CurvePoint(1, 1)],
            [CurvePoint(0, 0), CurvePoint(0.3, 0.25), CurvePoint(1, 1)],
            [CurvePoint(0, 0), CurvePoint(0.6, 0.55), CurvePoint(1, 1)],
            [CurvePoint(0, 0), CurvePoint(0.5, 0.4), CurvePoint(1, 1)],
        ]
        var one = 0.0
        for _ in 0..<20 {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = CurveLUT.buildOne(pointSets[0])
            one = max(one, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        var all = 0.0
        for _ in 0..<10 {
            let t0 = CFAbsoluteTimeGetCurrent()
            for points in pointSets { _ = CurveLUT.buildOne(points) }
            all = max(all, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        print(String(format: "BENCH 030 table build: 1 table %.3f ms (worst of 20), 4 tables %.3f ms (worst of 10)",
                     one, all))
        // Printed from a **Debug** (`-Onone`) build, which is how `swift test` runs: the same work
        // under `swiftc -O` measures 0.023 ms (one table, p95 0.024) and 0.099 ms (four, p95 0.35),
        // i.e. well inside §6.4's 0.5 ms / 2 ms budgets. Debug is ~100× slower on this loop, so the
        // assertion below is a structural ceiling that a real regression would still break.
        if benchmarks {
            XCTAssertLessThan(one, 30, "a single table rebuild is a drag-path cost (Debug ceiling)")
            XCTAssertLessThan(all, 90, "four tables is a document-switch cost (Debug ceiling)")
        }

        func frameCost(label: String, image: LinearImage, canvas: ImageSize,
                       iterations: Int, useCache: Bool) throws -> Double {
            let graph = try RenderGraph(input: RenderInput(image: image, identity: "bench-\(label)"))
            var curved = EditModel.neutral
            curved.curve.white = [CurvePoint(0, 0), CurvePoint(0.25, 0.18),
                                  CurvePoint(0.75, 0.82), CurvePoint(1, 1)]
            func measure(_ edit: EditModel, force: Bool) throws -> [Double] {
                var times: [Double] = []
                for _ in 0..<iterations {
                    // The cache is out of the measurement either way: with it on, a second identical
                    // frame is a hit and measures nothing.
                    graph.invalidateCache()
                    let result = try graph.render(edit, options: RenderOptions(
                        canvas: canvas, scale: 1, useCache: useCache, wantsPixels: false,
                        forceCurveArithmetic: force))
                    if let t = result.output { graph.recycle(output: t) }
                    times.append(result.trace.gpuMilliseconds)
                }
                return times
            }
            // Warm up (kernel compile, texture pool) before either measurement.
            _ = try measure(.neutral, force: false)
            // The identity frame takes the **copy branch** (that is what the product does), the
            // curved one takes the arithmetic: the difference is what the shaper, the four table
            // lookups and the three `exp` cost on top of one pointwise pass over the canvas.
            let identityTimes = try measure(.neutral, force: false)
            let curvedTimes = try measure(curved, force: false)
            // Paired: iteration *i* of each, so a machine that speeds up or slows down during the
            // measurement moves both samples together and the difference stays the pass's own cost.
            let deltas = zip(curvedTimes, identityTimes).map { $0 - $1 }.sorted()
            let idMedian = identityTimes.sorted()[identityTimes.count / 2]
            let curveMedian = curvedTimes.sorted()[curvedTimes.count / 2]
            let delta = deltas[deltas.count / 2]
            print(String(format: "BENCH 030 S1.7 %@ (%d×%d = %.2f Mpx): frame copy-branch %.2f ms, "
                         + "frame arithmetic %.2f ms, S1.7 ≈ %+.2f ms (paired median of %d)",
                         label, canvas.width, canvas.height, Double(canvas.pixelCount) / 1e6,
                         idMedian, curveMedian, delta, deltas.count))
            return delta
        }

        // 4.10 Mpx — the canvas `MaskTests` budgets against (1500 × 2731), full S0→S4, cache off.
        let small = try frameCost(label: "4.10Mpx",
                                  image: bands(Array(repeating: 0.18, count: 240), height: 160),
                                  canvas: ImageSize(width: 1500, height: 2731),
                                  iterations: 40, useCache: false)
        XCTAssertLessThan(small, 4, "S1.7 at 4.10 Mpx must be a fraction of a frame (§12.4: 0.5 ms)")

        // 60 MP — a real 9504×6336 frame. The source is tiny on purpose (the pass is the subject,
        // not the fixture); the cache is on so the peak stays near its 1.5 GB budget instead of the
        // six live intermediates a cache-off frame would hold (2.9 GB at 60 MP).
        if benchmarks {
            let big = try frameCost(label: "60MP",
                                    image: bands(Array(repeating: 0.18, count: 240), height: 160),
                                    canvas: ImageSize(width: 9504, height: 6336),
                                    iterations: 3, useCache: true)
            XCTAssertLessThan(big, 60, "S1.7 at 60 MP is 15× the pixels of a 4.10 Mpx canvas")
        }
    }
}
