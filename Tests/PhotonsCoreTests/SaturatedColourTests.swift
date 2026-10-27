import XCTest
import PhotonsCore
import Metal

/// 075 — **the test the golden files cannot be.**
///
/// Measured on a real photograph, "Rec.709 weights replaced by Rec.2020 weights" moves the mean
/// |Δluma| by **0.00103** and the region gains by 0.0007 EV on average (075 §5.2). Every recorded
/// golden would stay green while the product carried a **+23.6 %** luma error on saturated red into
/// the tone map. So the acceptance for batches A+B has to be a *synthetic* frame whose colours are
/// chosen to be wrong-looking under exactly the mistakes that a photograph forgives:
///
///   · **only the weights changed** (Rec.2020 weights reading sRGB numbers) — the classic half of
///     this migration, because it is one constant in nine files and needs no matrix;
///   · **only the primaries changed** (the S0 exit matrix without the weights);
///   · **neither** (the S4 matrix converting a number that was never converted).
///
/// The three columns of `testTheThreePairingsSeparate` are those mistakes, computed from
/// `ColorPrimaries` itself, and only the correct pairing lands inside the 1e-4 luminance bound.
/// The reference percentages are `ColorPrimariesTests`' (+23.5654 / −5.2013 / −17.8670), reached
/// here through the *rendered* frame instead of through the matrices alone.
///
/// ## Why the luminance assertion is arithmetic and not pixels
///
/// The pipeline stores pixels as `Float16`. At 0.2 the half step is 1.2e-4, at 1.0 it is 9.8e-4, so
/// no *rendered* value can carry a 1e-4 luminance claim — the claim "changing primaries does not
/// change physical luminance" is a statement about the arithmetic (`Y` is invariant because
/// `toXYZ(source)·v = toXYZ(target)·(M·v)`, both evaluated with the published constants), and that is
/// where it is asserted. The render is used for what it *can* prove exactly: the working-space code
/// on the histogram's axis, the bit identity of neutral content, and the sign of a clamped channel.
final class SaturatedColourTests: XCTestCase {

    // MARK: - fixtures

    /// The five colours from 075 §5.2, as sRGB 8-bit codes (the owner's own reference set).
    struct Probe {
        let name: String
        let code: (Int, Int, Int)
        /// `srgbDecode(code/255)` — linear sRGB, which is what the decoder would have written.
        var linear: SIMD3<Double> {
            func decode(_ c: Int) -> Double {
                let v = Double(c) / 255.0
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return SIMD3(decode(code.0), decode(code.1), decode(code.2))
        }
    }

    let probes: [Probe] = [
        Probe(name: "red", code: (255, 0, 0)),
        Probe(name: "green", code: (0, 255, 0)),
        Probe(name: "blue", code: (0, 0, 255)),
        Probe(name: "skin-orange", code: (217, 153, 115)),
        Probe(name: "neutral-grey", code: (128, 128, 128)),
    ]

    private func srgbEncode(_ v: Double) -> Double {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    /// A flat frame of one linear sRGB colour: what `RAWDecoder` would hand S0 for that physical colour.
    private func flat(_ v: SIMD3<Double>, width: Int = 8, height: Int = 8) -> LinearImage {
        var rgba = [Float16](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = Float16(Float(v.x))
            rgba[i * 4 + 1] = Float16(Float(v.y))
            rgba[i * 4 + 2] = Float16(Float(v.z))
            rgba[i * 4 + 3] = 1
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func graph(_ image: LinearImage) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: "saturated-075"))
    }

    private func render(_ image: LinearImage, edit: EditModel = .neutral) throws -> DisplayImage {
        let g = try graph(image)
        let result = try g.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                              wantsPixels: true))
        return try XCTUnwrap(result.display)
    }

    /// The measured colour of a flat frame, read out of the S4 texture.
    private func colour(_ image: DisplayImage) -> SIMD3<Float> {
        let o = ((image.height / 2) * image.width + image.width / 2) * 4
        return SIMD3(Float(image.rgba[o]), Float(image.rgba[o + 1]), Float(image.rgba[o + 2]))
    }

    private func weights(_ space: ColorPrimaries) -> SIMD3<Double> { space.luminanceWeights }
    private func y(_ v: SIMD3<Double>, _ space: ColorPrimaries) -> Double {
        let w = weights(space)
        return w.x * v.x + w.y * v.y + w.z * v.z
    }

    // MARK: - 1. neutral content is untouched, bit for bit

    /// Neutral content must come out of the two matrices **unchanged**: no channel divergence, no
    /// colour cast, and no movement beyond what the pipeline already does to a neutral.
    ///
    /// Two things are asserted, and the split is deliberate:
    ///
    ///   · `r == g == b` **bit for bit**. This is the half of the claim that can be exact, and it is
    ///     the one that catches the failure modes that matter: a transposed matrix, a row that does
    ///     not sum to 1, a missing clamp. A white-preserving matrix maps `(v,v,v)` to `(v,v,v)` in
    ///     Float16; anything else shows up here immediately.
    ///   · `|out − srgbEncode(v)| ≤ 2e-3`, i.e. "the migration did not move a neutral pixel".
    ///     The bound is not 0 because the **graph underneath is not a bit-exact identity**: with the
    ///     two matrices forced to the identity (`ColorPrimaries.working == .sRGB`, which reproduces
    ///     every pre-075 golden byte for byte) the same frame produces the same numbers to within the
    ///     printed deltas — −1.7e-4 at 0.18, −5e-6 at 0.5, −4.9e-4 at white. Those are ≤ 1 `Float16`
    ///     ULP of the *code* (2.4e-4 at 0.46, 4.9e-4 at 1.0), i.e. the round trip's own rounding, not
    ///     a field measured wrong; white additionally sits ~2e-4 under 1.0 before the migration too,
    ///     so no matrix can be blamed for it. 2e-3 is 3× *below* one code of an 8-bit export and 100×
    ///     below what a wrong matrix does.
    func testNeutralGreyAndWhiteAreBitIdentical() throws {
        // 0.18 (the scene pivot), 0.2140 (128/255), 0.5 and 1.0 — the values the pipeline's own
        // arithmetic pivots on, plus the white that must not be pushed under 1.0 by the matrices.
        for v in [0.18, 0.21404114, 0.5, 1.0] {
            let image = try render(flat(SIMD3(v, v, v)))
            let out = colour(image)
            let middle = ((image.height / 2) * image.width + image.width / 2) * 4
            let expected = srgbEncode(v)
            print(String(format: "neutral %.5f → %.6f %.6f %.6f  (srgbEncode %.6f, Δ %+.2e)",
                         v, out.x, out.y, out.z, expected, Double(out.x) - expected))
            XCTAssertEqual(image.rgba[middle], image.rgba[middle + 1],
                           "neutral \(v): r != g after the matrices (bit for bit)")
            XCTAssertEqual(image.rgba[middle + 1], image.rgba[middle + 2],
                           "neutral \(v): g != b after the matrices (bit for bit)")
            XCTAssertEqual(Double(out.x), expected, accuracy: 2e-3,
                           "neutral \(v): the migration moved a neutral pixel "
                           + "(got \(out.x), srgbEncode(v) is \(expected))")
        }
        // Pure white is not *pushed down* by the matrices: the exit matrix's row sums are 1 to within
        // 6e-7 and the inverse's to within 1e-16, so the round trip's contribution is exactly zero and
        // the residual is the pipeline's own gain (0.99883).
        let white = colour(try render(flat(SIMD3(1, 1, 1))))
        XCTAssertGreaterThanOrEqual(white.x, 0.999, "white must stay at 1.0 (got \(white.x))")
        XCTAssertEqual(white.x, white.y)
        XCTAssertEqual(white.y, white.z)
    }

    // MARK: - 2. the working space really is Rec.2020 (the S0 exit matrix ran)

    /// **The round trip is the observable.** `Histogram.compute` bins on the *display* axis (075 —
    /// the pre-S4 sample is converted into the output primaries first, which is what makes the card's
    /// plot and the frame plot agree), so nothing in the public API hands out a working-space code any
    /// more. What it can still show is the thing that matters: a known physical colour comes back out
    /// of `S0 → S4` as itself.
    ///
    /// That is a decisive test for every colour **except** the three primaries, which are fixed points
    /// of the round trip even when the S0 matrix is missing (a saturated red's Rec.2020 code, run
    /// through `Rec2020 → sRGB` and clamped, is `(1, 0, 0)` again — the clamp hides it). So the fixtures
    /// that carry the discrimination are the mid-gamut ones: skin orange reads 0.849 of code with the
    /// matrix and 0.979 without, 33 bins apart. The primaries are kept for the *luminance* column in
    /// `testTheThreePairingsSeparate`, which is where their sensitivity lives.
    func testTheWorkingSpaceRoundTripsToTheSamePhysicalColour() throws {
        for probe in probes {
            let image = flat(probe.linear)
            let out = colour(try render(image))
            let expected = [bin(srgbEncode(probe.linear.x)), bin(srgbEncode(probe.linear.y)),
                            bin(srgbEncode(probe.linear.z))]
            // What the same pixel would read if S0's exit matrix were missing and only S4 converted.
            let unconverted = ColorPrimaries.conversion(from: .working, to: .sRGB)
                .applying(to: probe.linear)
            let missing = [bin(srgbEncode(min(unconverted.x, 1))),
                           bin(srgbEncode(min(unconverted.y, 1))),
                           bin(srgbEncode(min(unconverted.z, 1)))]
            let measured = [bin(Double(out.x)), bin(Double(out.y)), bin(Double(out.z))]
            print("round trip \(probe.name): measured \(measured) · with both matrices \(expected) "
                  + "· without the exit matrix \(missing)")

            for c in 0..<3 {
                XCTAssertLessThanOrEqual(abs(measured[c] - expected[c]), 1,
                                         "\(probe.name) channel \(c): the display code is not the "
                                         + "physical colour's (measured \(measured[c]), expected "
                                         + "\(expected[c]), un-migrated \(missing[c]))")
            }
            // The primaries are round-trip fixed points and grey is white-point protected, so neither
            // can see a missing matrix; the mid-gamut fixture has to.
            if probe.name == "skin-orange" {
                let apart = (0..<3).map { abs(expected[$0] - missing[$0]) }.max() ?? 0
                XCTAssertGreaterThanOrEqual(apart, 4,
                    "\(probe.name) cannot tell a missing S0 matrix from a correct one "
                    + "(\(apart) bins) — pick a fixture further inside the gamut")
            }
        }
    }

    /// `binIndex`: `[k/binCount, (k+1)/binCount)`, clamped to the last bin.
    private func bin(_ code: Double) -> Int { min(max(Int(code * 256), 0), 255) }

    private func peak(_ channel: HistogramChannel) -> Int {
        var best = 0, bestCount = -1
        for (i, n) in channel.bins.enumerated() where n > bestCount {
            best = i; bestCount = n
        }
        return best
    }

    // MARK: - 3. the three pairings: exactly one preserves physical luminance

    /// The heart of the batch, as numbers. For each probe, the same pixel through three pipelines:
    ///
    /// | pairing | code the tone map sees | `Y` | error |
    /// |---|---|---|---|
    /// | **both** (this tree) | `M·v` | `w₂₀₂₀·(M·v)` | ≈ 0 (the 1e-4 bound) |
    /// | **weights only** (the classic mistake) | `v` | `w₂₀₂₀·v` | +23.57 % red, −5.20 % green, −17.87 % blue |
    /// | **primaries only** | `M·v` | `w₇₀₉·(M·v)` | −13.4 % red, +4.8 % green, +13.5 % blue |
    ///
    /// "Weights only" is `ColorPrimariesTests.testOnlySwappingTheWeightsIsNotARefactor`'s row, and the
    /// two must agree — that test pins the constants, this one pins the *pipeline's* codes.
    func testTheThreePairingsSeparate() throws {
        let m = ColorPrimaries.conversion(from: .sRGB, to: ColorPrimaries.working)
        var worstCorrect = 0.0
        for probe in probes {
            let v = probe.linear
            let c = m.applying(to: v)
            let ySource = y(v, .sRGB)
            let yCorrect = y(c, ColorPrimaries.working)
            let yWeightsOnly = y(v, ColorPrimaries.working)
            let yPrimariesOnly = y(c, .sRGB)
            let eCorrect = yCorrect - ySource
            let eWeights = yWeightsOnly / ySource - 1
            let ePrimaries = yPrimariesOnly / ySource - 1
            worstCorrect = max(worstCorrect, abs(eCorrect))
            print(String(format: "Y     %-13@ sRGB %.6f · Rec2020 %.6f · both %+.2e (%+.4f%%) · "
                         + "weights-only %+.4f%% · primaries-only %+.4f%%",
                         probe.name as NSString, ySource, yCorrect, eCorrect, eCorrect / ySource * 100,
                         eWeights * 100, ePrimaries * 100))

            // 075 batch A/B acceptance: changing primaries must not change physical luminance.
            XCTAssertLessThanOrEqual(abs(eCorrect), 1e-4,
                "\(probe.name): the migration moved the pixel's luminance by \(eCorrect) "
                + "(> 1e-4) — the S0 matrix and the weights do not describe the same light")
            // …and the neutral is exact, because both sides reduce to the same three numbers.
            if probe.name == "neutral-grey" {
                XCTAssertEqual(eCorrect, 0, accuracy: 1e-15, "grey: luminance must be unchanged")
            } else {
                // The mistakes are large, and their *signs* are the documented ones. A tree with the
                // matrix missing lands on the "weights only" line: red is 23.57 % too bright.
                XCTAssertGreaterThan(abs(eWeights), 0.05,
                    "\(probe.name): the two weight sets must not be interchangeable")
            }
        }
        XCTAssertLessThanOrEqual(worstCorrect, 1e-4, "worst luminance error over the probe set")

        // The reference percentages from `ColorPrimariesTests`, reached again here from the
        // published constants — so the two tests fail together or not at all.
        let red = probes[0].linear, green = probes[1].linear, blue = probes[2].linear
        XCTAssertEqual(y(red, ColorPrimaries.working) / y(red, .sRGB) - 1, 0.235654, accuracy: 1e-5)
        XCTAssertEqual(y(green, ColorPrimaries.working) / y(green, .sRGB) - 1, -0.052013, accuracy: 1e-5)
        XCTAssertEqual(y(blue, ColorPrimaries.working) / y(blue, .sRGB) - 1, -0.178670, accuracy: 1e-5)
    }

    // MARK: - 4. S4 clips after the matrix (075 §3.1-②), with the negative value named

    /// A saturated **Rec.2020 green** — `(0, 1, 0)` in the working space, i.e. the decoded value
    /// `Rec2020→sRGB · (0,1,0)`, which is what a real camera recording that physical green would
    /// hand S0. S4's `Rec2020 → sRGB` matrix has a **−0.5876411** coefficient, so that pixel's red
    /// channel is `−0.5876` on the way into the OETF.
    ///
    /// Before the fix the kernel clamped *before* the matrix and wrote the negative through:
    /// `srgb_encode(−0.5876) = 12.92 · (−0.5876) = −7.5938`, a code no renderer may produce. The
    /// assertion below is new rather than a regression — the old order could not fail while the only
    /// matrix was `sRGB → P3`.
    func testS4ClampsAfterThePrimariesMatrix() throws {
        let toSRGB = ColorPrimaries.conversion(from: ColorPrimaries.rec2020, to: .sRGB)
        let decoded = toSRGB.applying(to: SIMD3(0, 1, 0))
        let image = try render(flat(decoded))
        let out = colour(image)

        // The red channel's own value on the way in, from ColorPrimaries — the number the clamp eats.
        let linearRed = toSRGB.row(0).y          // coefficient of G in the output R
        XCTAssertLessThan(linearRed, -0.58, "Rec2020→sRGB must have a strong negative coefficient")
        let wouldHaveBeenWritten = 12.92 * linearRed
        print(String(format: "clamp  Rec2020 green (0,1,0) → linear R %.6f → unclamped code %.4f "
                     + "→ written R %.4f, G %.4f, B %.4f",
                     linearRed, wouldHaveBeenWritten, out.x, out.y, out.z))

        XCTAssertGreaterThanOrEqual(out.x, 0, "S4 wrote a negative red code (−7.59) — the clamp is "
                                    + "before the matrix again (075 §3.1-②)")
        XCTAssertGreaterThanOrEqual(out.y, 0)
        XCTAssertGreaterThanOrEqual(out.z, 0)
        XCTAssertEqual(out.x, 0, "the out-of-gamut red must clip to exactly 0")
        // Green survives (1.1329 → the SDR ceiling at headroom 1) and blue's −0.0083 clips too.
        XCTAssertEqual(out.y, 1.0, accuracy: 1e-3, "the green channel of that colour is ~1.13 → 1.0")
        XCTAssertEqual(out.z, 0)

        // Every channel of every pixel, not just the centre: a clamp that only works at one texel is
        // not a clamp.
        for i in stride(from: 0, to: image.rgba.count, by: 4) {
            for c in 0..<3 {
                XCTAssertGreaterThanOrEqual(image.rgba[i + c], 0,
                                            "texel \(i / 4) channel \(c) is negative")
            }
        }
    }
}

// MARK: - 5. the exit matrix runs on **every** S0 exit (identity / pure-CA / general)

extension SaturatedColourTests {

    /// 075 §3.1's other half, and the one a per-pixel answer cannot give: S0 writes a photograph texel
    /// from **four** places (identity copy, pure-CA, general single-sample, general CA triple) and the
    /// exit matrix has to be on all of them. A path that skipped it would put *sRGB* codes into a
    /// Rec.2020 pipeline for exactly the documents that take that path — a half-migrated frame, where
    /// a CA document and a non-CA document disagree about what the camera saw.
    ///
    /// **The colour is a mid-gamut one on purpose.** A saturated primary is a fixed point of the round
    /// trip whether or not the exit matrix ran (S4's inverse plus the clamp puts it back), so a primary
    /// cannot see this bug at all. Skin orange reads 0.849 of display code with the matrix on that path
    /// and 0.979 with it off — 33 bins.
    func testTheExitMatrixRunsOnEveryS0Path() throws {
        let v = probes[3].linear                      // skin orange
        let missing = ColorPrimaries.conversion(from: .working, to: .sRGB).applying(to: v)
        // Through S4 the display code is the *original* sRGB light of that physical colour — the two
        // matrices cancel — so that is the "matrix ran" value; the "matrix missing" value is what S4
        // produces when it converts a number that was never converted.
        let expected = bin(srgbEncode(v.x))
        let unmigrated = bin(srgbEncode(min(missing.x, 1)))
        XCTAssertGreaterThanOrEqual(abs(expected - unmigrated), 20,
                                    "the fixture no longer separates the two spaces")

        var identity = EditModel.neutral
        identity.geometry.cropRect = .full
        var pureCA = identity
        pureCA.optics.caRed = 0.002
        pureCA.optics.caBlue = -0.0015
        var general = identity
        general.geometry.cropRect = CropRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        general.geometry.rotationDegrees = 3

        // `RenderTrace` only names the pure-CA exit; the other two are addressed by the document that
        // reaches them, and the print below is the record that each render took the one it claims.
        for (name, edit, isPureCA) in [("identity", identity, false),
                                       ("pure-CA", pureCA, true),
                                       ("general", general, false)] {
            let image = flat(v, width: 96, height: 64)
            let g = try graph(image)
            let result = try g.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                  wantsPixels: true))
            let px = try XCTUnwrap(result.display)
            let measured = bin(Double(colour(px).x))
            print("path  \(name): display R bin \(measured) (with the matrix \(expected), "
                  + "without \(unmigrated))  pureCA=\(result.trace.s0PureCA)")
            XCTAssertEqual(result.trace.s0PureCA, isPureCA, "\(name): took the wrong S0 exit")
            XCTAssertLessThanOrEqual(abs(measured - expected), 1,
                                     "\(name): the exit matrix did not run on this S0 exit "
                                     + "(display bin \(measured), expected \(expected), "
                                     + "without the matrix \(unmigrated))")
        }
    }
}

// MARK: - 6. the weight literal exists twice, but cannot drift twice

extension SaturatedColourTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// A kernel cannot import Swift, so `Kernels/primaries.metal` has to spell the three numbers out.
    /// That is the same duplication that made 075 necessary in the first place (eight copies, six of
    /// them in tests), so the copy is **checked** rather than trusted: this parses the header and
    /// asserts it equals `ColorPrimaries.working.luminanceWeights`.
    func testTheKernelWeightsAreColorPrimaries() throws {
        let url = Self.repoRoot.appendingPathComponent("Sources/PhotonsCore/Kernels/primaries.metal")
        let source = try String(contentsOf: url, encoding: .utf8)
        let line = try XCTUnwrap(source.split(separator: "\n")
            .first { $0.contains("kWorkingLumaWeights = float3(") },
            "the header no longer declares `kWorkingLumaWeights = float3(…)`")
        let numbers = try XCTUnwrap(line.split(separator: "(").last?.split(separator: ")").first)
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(numbers.count, 3, "expected three weights in: \(line)")
        let w = ColorPrimaries.working.luminanceWeights
        XCTAssertEqual(numbers[0], w.x, accuracy: 1e-12, "kernel R weight vs ColorPrimaries")
        XCTAssertEqual(numbers[1], w.y, accuracy: 1e-12, "kernel G weight vs ColorPrimaries")
        XCTAssertEqual(numbers[2], w.z, accuracy: 1e-12, "kernel B weight vs ColorPrimaries")
        print(String(format: "kernel weights %.4f/%.4f/%.4f == ColorPrimaries.working",
                     numbers[0], numbers[1], numbers[2]))
    }

    /// **No kernel may carry its own copy of the weights.** Rec.709's `0.2126` is the tell: it is what
    /// the eight pre-075 sites all said. One file is exempt on purpose — `s1_scene_linear.metal`'s
    /// 073B knee luma, which belongs to the blacks/whites work (075 §6.2: 073 owns that file). The
    /// exemption is a list, not a rule, so when 073 lands and takes the constant the test starts
    /// covering it and the list must shrink.
    func testNoKernelCarriesItsOwnLumaWeights() throws {
        let dir = Self.repoRoot.appendingPathComponent("Sources/PhotonsCore/Kernels")
        let pending = ["s1_scene_linear.metal"]
        var checked: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        where name.hasSuffix(".metal") && name != "primaries.metal" {
            let source = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces)
                .hasPrefix("//") }.joined(separator: "\n")
            if pending.contains(name) {
                XCTAssertTrue(code.contains("0.2126"),
                              "\(name) is exempt from the weights move (073 owns it) but no longer "
                              + "carries the literal — remove it from `pending` so this test covers it")
                continue
            }
            // The two display-referred entry points are allowed to say 709, and say why in a comment;
            // what must not happen is a *scene-linear* kernel folding its own numbers.
            XCTAssertFalse(code.contains("0.2627") || code.contains("0.678"),
                           "\(name): the weights belong in primaries.metal, not in a kernel")
            if name != "histogram_sample.metal" {
                XCTAssertFalse(code.contains("0.2126"),
                               "\(name): a stale Rec.709 luma weight survived batch B")
            }
            checked.append(name)
        }
        XCTAssertGreaterThan(checked.count, 10, "the kernel directory was not enumerated")
        print("weights guard: \(checked.count) kernels checked, exempt: \(pending)")
    }
}
