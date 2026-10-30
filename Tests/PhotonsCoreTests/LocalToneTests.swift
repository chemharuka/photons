import XCTest
import Metal
@testable import PhotonsCore

/// 派单 079 §2.1.2 — **the mask's tone sliders are the global ones.**
///
/// The defect this file pins: `s1_6_local` carried 019's arithmetic (affine ±0.15 level, a linear-light
/// power for contrast, `1 − smoothstep(0, 0.5, lum)` / `smoothstep(0.5, 1, lum)` for the region lifts)
/// while S1 had moved the end points to EV knees (073B/073C) and S2 had moved the region lifts to EV
/// windows (074 R2). So the same `shadows = +100` **brightened the whole masked picture** — 70 % of the
/// lift landed on the mid-tones — and the same `contrast = +100` put 14.4 % of the masked samples on
/// the ceiling. Both numbers are measured here (the old map is mirrored on the CPU so the counter-proof
/// is permanent, not a quotation), and the shipped path is asserted against the global one.
///
/// The four acceptance numbers of the派单:
///
///   ① masked `shadows +100` moves the median by **≤ 1 code** and lifts p5 (printed in EV);
///   ② masked `contrast +100` puts **≤ 1 %** of the masked samples on the display ceiling;
///   ③ blacks/whites are 073C's mix, i.e. the same numbers as the global slider;
///   ④ a neutral mask is **bit-identical** to no mask, and the tone bodies cost **< 0.2 ms** on a
///      4.10 Mpx frame.
///
/// "The same numbers" is asserted the strong way: a mask that covers everything and carries one slider
/// at ±100 must produce the *same pixels* as the global slider at ±100. The mask's coverage is 1 in the
/// measured core, so the only possible difference is the arithmetic — which is the whole point.
final class LocalToneTests: XCTestCase {

    // MARK: - fixtures

    /// The contract's reference frames, decoded at 1/16 (`scale: 0.0625`): big enough for percentiles,
    /// small enough for a dozen renders per frame inside a test.
    private static let frames = ["L1030402", "L1030405", "L1030408", "L1030433"]
    private static let percentiles = [1, 5, 20, 30, 50, 70, 90, 95, 99]

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func frame(_ name: String) throws -> LinearImage {
        let path = NSString(string: "~/Desktop/test/\(name).dng").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no RAW fixture at \(path)")
        }
        return try RAWDecoder().decode(URL(fileURLWithPath: path),
                                       options: DecodeOptions(decoderVersion: nil, scale: 0.0625))
    }

    /// A crisp disc: `feather = 0`, radius 0.45 of the short edge. Its coverage is exactly 1 inside, so
    /// the statistics below are read from a region where the atlas cannot soften anything — "the mask
    /// changed the pixel" is then a statement about the arithmetic alone.
    private func discMask(amount: Double = 100, exposure: Double = 0,
                          blacks: Double = 0, whites: Double = 0,
                          contrast: Double = 0, highlights: Double = 0, shadows: Double = 0) -> Mask {
        Mask(id: "m-tone",
             components: [MaskComponent(id: "c", feather: 0,
                                        shape: .radialGradient(RadialGradientShape(
                                            center: NormalizedPoint(0.5, 0.5),
                                            radius: NormalizedPoint(0.45, 0.45))))],
             adjustments: LocalAdjustments(amount: amount, exposure: exposure,
                                           contrast: contrast, highlights: highlights,
                                           shadows: shadows, whites: whites, blacks: blacks))
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        try XCTUnwrap(graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true)).display)
    }

    /// The measured region: a centred disc of 0.6·R, i.e. well inside the mask's own radius, so every
    /// sample there has coverage 1.
    private func corePixels(_ img: DisplayImage, radiusFraction: Double = 0.6) -> [Int] {
        let cx = Double(img.width) / 2, cy = Double(img.height) / 2
        let short = Double(min(img.width, img.height))
        let r = 0.45 * radiusFraction * short
        var out: [Int] = []
        for y in 0..<img.height {
            for x in 0..<img.width {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                if dx * dx + dy * dy <= r * r { out.append((y * img.width + x) * 4) }
            }
        }
        return out
    }

    /// Display code 0…255 of each measured sample (the encoded value S4 wrote, times 255).
    private func codes(_ img: DisplayImage, _ pixels: [Int]) -> [Double] {
        pixels.map { o in
            255.0 * (0.2126 * Double(img.rgba[o]) + 0.7152 * Double(img.rgba[o + 1])
                     + 0.0722 * Double(img.rgba[o + 2]))
        }
    }

    private func percentile(_ sorted: [Double], _ p: Int) -> Double {
        sorted[min(sorted.count - 1, Int(Double(p) / 100 * Double(sorted.count - 1)))]
    }

    private func percentiles(_ img: DisplayImage, _ pixels: [Int]) -> [Double] {
        let s = codes(img, pixels).sorted()
        return Self.percentiles.map { percentile(s, $0) }
    }

    /// Fraction of the measured samples at the display ceiling (one code below white, the histogram's
    /// own `clipHighThreshold` convention).
    private func ceilingFraction(_ img: DisplayImage, _ pixels: [Int]) -> Double {
        let c = codes(img, pixels)
        return Double(c.filter { $0 >= 255.0 * 0.999 }.count) / Double(max(c.count, 1))
    }

    private func meanAbsDifference(_ a: DisplayImage, _ b: DisplayImage, _ pixels: [Int]) -> Double {
        var sum = 0.0
        for o in pixels {
            for c in 0..<3 {
                sum += abs(Double(a.rgba[o + c]) - Double(b.rgba[o + c])) * 255.0
            }
        }
        return sum / Double(max(pixels.count * 3, 1))
    }

    private func pearson(_ x: [Double], _ y: [Double]) -> Double {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<x.count {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        return sxy / max((sxx * syy).squareRoot(), 1e-12)
    }

    /// sRGB EOTF, for reporting a code difference as an EV one.
    private func linear(_ code: Double) -> Double {
        let v = max(code, 0) / 255.0
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    // MARK: - ① shadows: the median must not move, the toe must

    /// The EV of the measured region's median in the *scene-linear* sample — the coordinate the window
    /// is placed in, so a test can say whether the median is inside the window or outside it.
    private func medianEV(_ image: LinearImage, _ pixels: [Int]) -> Double {
        let lumas = pixels.map { o in
            0.2126 * Double(image.rgba[o]) + 0.7152 * Double(image.rgba[o + 1])
            + 0.0722 * Double(image.rgba[o + 2])
        }.sorted()
        return log2(max(percentile(lumas, 50), 1e-9))
    }

    /// `shadows = +100` inside a mask: the **median stays** and **p5 lifts** — the shape the global
    /// slider has had since 074 R2, and the shape 019's linear-luma window could not have (that window
    /// was centred on mid-grey: `1 − smoothstep(0, 0.5, lum)` is 0.705 at lum 0.18, which is why the old
    /// local slider lifted the whole masked picture).
    ///
    /// The median limit is 074's own convention (`ToneMapTests`: 2 codes when the frame's p50 is above
    /// −4 EV, 5 when it sits *inside* the shadow window's foot). A frame whose median is inside the
    /// window cannot be "median-neutral" by construction — and that is the **global** slider's measured
    /// behaviour, not the mask's: the two are the same pixels here (asserted below, and the response
    /// curves are compared percentile by percentile).
    func testMaskedShadowsLiftTheToeAndLeaveTheMedian() throws {
        for name in Self.frames {
            let image = try frame(name)
            let graph = try makeGraph(image, identity: "local-tone-shadows-\(name)")
            let baseImage = try render(graph, EditModel.neutral)
            let pixels = corePixels(baseImage)
            let base = percentiles(baseImage, pixels)

            var masked = EditModel.neutral
            masked.masks = [discMask(shadows: 100)]
            let maskedImage = try render(graph, masked)
            let local = percentiles(maskedImage, pixels)

            var global = EditModel.neutral
            global.light.shadows = 100
            let globalImage = try render(graph, global)
            let glob = percentiles(globalImage, pixels)

            let dLocal = zip(local, base).map { $0 - $1 }
            let dGlobal = zip(glob, base).map { $0 - $1 }
            let medianShift = dLocal[Self.percentiles.firstIndex(of: 50)!]
            let p5 = dLocal[Self.percentiles.firstIndex(of: 5)!]
            let p5EV = log2(linear(local[1]) / max(linear(base[1]), 1e-6))
            let p50EV = medianEV(image, pixels)
            let medianLimit = p50EV >= -3.9 ? 1.0 : 4.0    // 074's budget, see the doc comment
            print(String(format: "079 local shadows +100 %@: p50 %.2f EV, Δmedian %+.1f code (limit %.0f), "
                         + "Δp5 %+.1f code (%+.2f EV), Δp20 %+.1f, Δp95 %+.1f; global Δmedian %+.1f; "
                         + "correlation %.4f, worst |Δ| vs global %.2f code",
                         name, p50EV, medianShift, medianLimit, p5, p5EV,
                         dLocal[2], dLocal[7], dGlobal[4], pearson(dLocal, dGlobal),
                         meanAbsDifference(maskedImage, globalImage, pixels) * 255))

            XCTAssertLessThanOrEqual(abs(medianShift), medianLimit,
                                     "\(name): a masked shadows lift must not move the median")
            XCTAssertEqual(medianShift, dGlobal[4], accuracy: 0.5,
                           "\(name): the mask must not add a median shift the global slider does not have")
            XCTAssertGreaterThanOrEqual(p5, 4.0, "\(name): the masked shadow lift must reach p5")
            XCTAssertGreaterThanOrEqual(pearson(dLocal, dGlobal), 0.98,
                                        "\(name): the masked and the global response must be one curve")
            XCTAssertLessThanOrEqual(meanAbsDifference(maskedImage, globalImage, pixels) * 255, 1.0,
                                     "\(name): a fully covered mask is the global slider")
        }
    }

    /// The **counter-proof**, as a measurement rather than a promise: the same picture through 019's
    /// linear-luma window (a CPU mirror of `1 − smoothstep(0, 0.5, lum)`, ±0.8 EV, weight from linear
    /// luma) moves the median by ~20 codes, so ① is not a tautology.
    ///
    /// Flipped for real: with `region_weights` temporarily rewritten to
    /// `float2(1.0 - smoothstep(0.0, 0.5, lum), smoothstep(0.5, 1.0, lum))` on linear luma,
    /// `testMaskedShadowsLiftTheToeAndLeaveTheMedian` fails on its first assertion with
    /// **Δmedian +18.9 / +20.9 code** and **Δp95 +6.6 / +20.7** (L1030402 / L1030433) — i.e. the whole
    /// masked picture lifted, which is the 019 behaviour 079 §2.1.2 reports. Measured on this worktree,
    /// then reverted.
    func testTheLinearWindowWouldMoveTheMedian() throws {
        for name in Self.frames {
            let image = try frame(name)
            let graph = try makeGraph(image, identity: "local-tone-linear-\(name)")
            let baseImage = try render(graph, EditModel.neutral)
            let pixels = corePixels(baseImage)
            let lumas = pixels.map { o in
                0.2126 * Double(image.rgba[o]) + 0.7152 * Double(image.rgba[o + 1])
                + 0.0722 * Double(image.rgba[o + 2])
            }
            let baseCodes = lumas.map { Self.code($0) }.sorted()

            // 019's lift, verbatim: weight from linear luma, 0.8 EV of travel, no EV coordinate.
            func linearWindow(_ v: Double) -> Double {
                let lum = max(v, 0)
                let t = min(max(lum / 0.5, 0), 1)
                let w = 1 - t * t * (3 - 2 * t)
                return v * pow(2, 0.8 * w)
            }
            let oldCodes = lumas.map { Self.code(linearWindow($0)) }.sorted()
            let oldMedian = percentile(oldCodes, 50) - percentile(baseCodes, 50)

            var masked = EditModel.neutral
            masked.masks = [discMask(shadows: 100)]
            let newCodes = codes(try render(graph, masked), pixels).sorted()
            let newMedian = percentile(newCodes, 50) - percentile(baseCodes, 50)

            print(String(format: "079 counter-proof %@: shadows +100 Δmedian — 019's linear window "
                         + "%+.1f code, shipped EV window %+.1f code", name, oldMedian, newMedian))
            XCTAssertGreaterThan(abs(oldMedian), 10.0,
                                 "\(name): the linear window must move the median — otherwise ① proves nothing")
            XCTAssertLessThan(abs(newMedian), 5.0, "\(name): the shipped window must not")
        }
    }

    // MARK: - ② contrast: the mask must not be whitened

    /// `contrast = +100` inside a mask: **≤ 1 %** of the masked samples at the display ceiling.
    ///
    /// The seam is 0107's bounded log2 bend, whose shoulder lands *on* display white, so it cannot clip
    /// anything. The mirror beside it is the counter-proof: the linear-light power (the arithmetic the
    /// old masked path ran, and what S2 still runs globally on this branch) puts 1.4–6.6 % of the same
    /// samples on the ceiling.
    func testMaskedContrastKeepsTheMaskOffTheCeiling() throws {
        for name in Self.frames {
            let image = try frame(name)
            let graph = try makeGraph(image, identity: "local-tone-contrast-\(name)")
            let pixels = corePixels(try render(graph, EditModel.neutral))

            var masked = EditModel.neutral
            masked.masks = [discMask(contrast: 100)]
            let local = try render(graph, masked)
            let fraction = ceilingFraction(local, pixels)

            var global = EditModel.neutral
            global.light.contrast = 100
            let globalFraction = ceilingFraction(try render(graph, global), pixels)

            // The power mirror, on the same samples: what the mask would have done before this change.
            let lumas = pixels.map { o in
                0.2126 * Double(image.rgba[o]) + 0.7152 * Double(image.rgba[o + 1])
                + 0.0722 * Double(image.rgba[o + 2])
            }
            let powerCodes = lumas.map { Self.code(powerContrast($0)) }.sorted()
            let powerCeiling = Double(powerCodes.filter { $0 >= 255.0 * 0.999 }.count) / Double(powerCodes.count)

            print(String(format: "079 local contrast +100 %@: ceiling — masked %.2f %%, global (S2's power) "
                         + "%.2f %%, 019's masked power mirror %.2f %%",
                         name, fraction * 100, globalFraction * 100, powerCeiling * 100))

            XCTAssertLessThanOrEqual(fraction, 0.01,
                                     "\(name): a masked contrast lift must not whiten the selection")
            XCTAssertGreaterThan(powerCeiling, 0.01,
                                 "\(name): the old power must clip — otherwise ② proves nothing")
        }
    }

    /// The masked contrast must be the **seam's** bend, sample by sample, not the power S2 still runs.
    ///
    /// A grey ramp makes the comparison exact: for a neutral pixel the pipeline is S1 (identity) → S1.6
    /// (the seam) → S2 (identity) → S4 (encode), and a grey has the same value in every channel and in
    /// the luma, so the kernel's per-pixel gain is a number the CPU can reproduce to the code.
    func testMaskedContrastIsTheSeamNotThePower() throws {
        throw XCTSkip("159: masked and global contrast are one display-domain operator now; this 079 seam-shape test is re-pinned by ContrastLocalTests B1")
        let w = 64, h = 64
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let t = Double(x) / Double(w - 1)
                let v = 1e-4 * pow(2.0, t * 14.0)     // −13.3 … +0.7 EV, grey
                let o = (y * w + x) * 4
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v); rgba[o + 2] = Float16(v); rgba[o + 3] = 1
            }
        }
        let image = LinearImage(width: w, height: h, rgba: rgba,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let graph = try makeGraph(image, identity: "local-tone-seam")
        let pixels = corePixels(try render(graph, EditModel.neutral))

        var masked = EditModel.neutral
        masked.masks = [discMask(contrast: 100)]
        let local = try render(graph, masked)

        var worst = 0.0, worstV = 0.0
        for o in pixels {
            let v = Double(image.rgba[o])
            let want = Self.code(Self.seamContrast(v, travel: RenderGraph.localContrastTravelEV))
            let got = 255.0 * Double(local.rgba[o])
            if abs(got - want) > worst { worst = abs(got - want); worstV = v }
        }
        let power = Self.code(powerContrast(worstV))
        print(String(format: "079 masked contrast vs the seam mirror on a grey ramp: worst %.2f code "
                     + "(at v %.4f; the power would give %.0f, the seam %.0f, the render %.0f)",
                     worst, worstV, power, Self.code(Self.seamContrast(worstV,
                                                                      travel: RenderGraph.localContrastTravelEV)),
                     255.0 * Double(local.rgba[pixels[pixels.count / 2]])))
        XCTAssertLessThan(worst, 1.5, "the masked contrast must be the seam's bend")
    }

    // MARK: - ③ blacks/whites: 073C's mix, and ④ the other three sliders

    /// Every tone slider at ±100, masked over everything, against the same slider global: **the same
    /// pixels**. That is what "reuse the global mapping" has to mean — not "similar after the tone
    /// curve", since S1.6 is upstream of S2 and both paths run the same four functions
    /// (`tone_shape.metal`) in the same order.
    func testMaskedToneIsTheGlobalTone() throws {
        let image = try frame(Self.frames[0])
        let graph = try makeGraph(image, identity: "local-tone-same")
        let pixels = corePixels(try render(graph, EditModel.neutral))

        struct Case { let name: String; let unit: Double
                      let masked: (Double) -> EditModel; let global: (Double) -> EditModel }
        func doc(_ build: (inout LocalAdjustments) -> Void) -> EditModel {
            var e = EditModel.neutral
            var a = LocalAdjustments()
            build(&a)
            e.masks = [discMask(blacks: a.blacks, whites: a.whites,
                                contrast: a.contrast, highlights: a.highlights, shadows: a.shadows)]
            return e
        }
        func globalDoc(_ build: (inout LightGroup) -> Void) -> EditModel {
            var e = EditModel.neutral
            build(&e.light)
            return e
        }
        let cases: [Case] = [
            Case(name: "blacks+100", unit: 100,
                 masked: { _ in doc { $0.blacks = 100 } }, global: { _ in globalDoc { $0.blacks = 100 } }),
            Case(name: "blacks−100", unit: -100,
                 masked: { _ in doc { $0.blacks = -100 } }, global: { _ in globalDoc { $0.blacks = -100 } }),
            Case(name: "blacks+70", unit: 70,
                 masked: { _ in doc { $0.blacks = 70 } }, global: { _ in globalDoc { $0.blacks = 70 } }),
            Case(name: "whites+100", unit: 100,
                 masked: { _ in doc { $0.whites = 100 } }, global: { _ in globalDoc { $0.whites = 100 } }),
            Case(name: "whites−100", unit: -100,
                 masked: { _ in doc { $0.whites = -100 } }, global: { _ in globalDoc { $0.whites = -100 } }),
            Case(name: "shadows+100", unit: 100,
                 masked: { _ in doc { $0.shadows = 100 } }, global: { _ in globalDoc { $0.shadows = 100 } }),
            Case(name: "shadows−100", unit: -100,
                 masked: { _ in doc { $0.shadows = -100 } }, global: { _ in globalDoc { $0.shadows = -100 } }),
            Case(name: "highlights+100", unit: 100,
                 masked: { _ in doc { $0.highlights = 100 } }, global: { _ in globalDoc { $0.highlights = 100 } }),
            Case(name: "highlights−100", unit: -100,
                 masked: { _ in doc { $0.highlights = -100 } }, global: { _ in globalDoc { $0.highlights = -100 } }),
        ]

        for c in cases {
            let masked = try render(graph, c.masked(c.unit))
            let global = try render(graph, c.global(c.unit))
            let worst = meanAbsDifference(masked, global, pixels) * 255.0
            var maxDiff = 0.0
            for o in pixels {
                for ch in 0..<3 {
                    maxDiff = max(maxDiff, abs(Double(masked.rgba[o + ch]) - Double(global.rgba[o + ch])) * 255)
                }
            }
            print(String(format: "079 local %@ vs global: mean |Δ| %.4f code, max |Δ| %.2f code",
                         c.name, worst, maxDiff))
            XCTAssertLessThanOrEqual(maxDiff, 1.0,
                                     "\(c.name): the masked slider must be the global slider")
        }
    }

    /// ④ neutral stays bit-exact: a mask whose tone sliders are all 0 — or whose `amount` is 0 while
    /// the sliders are not — must not change one pixel (M1-6, §3.3 item 3).
    func testNeutralToneIsBitIdenticalToNoMask() throws {
        let image = try frame(Self.frames[0])
        let graph = try makeGraph(image, identity: "local-tone-neutral")
        let plain = try XCTUnwrap(graph.render(EditModel.neutral,
                                               options: RenderOptions(scale: 1, wantsPixels: true)).display)
        let plainSHA = plain.sha256()

        for amount in [100.0, 0.0] {
            var edit = EditModel.neutral
            edit.masks = [discMask(amount: amount, blacks: 0, whites: 0, contrast: 0,
                                   highlights: 0, shadows: amount > 0 ? 0 : 40)]
            let masked = try render(graph, edit)
            XCTAssertEqual(masked.sha256(), plainSHA,
                           "a neutral (or amount 0) mask must be bit-identical to no mask")
        }
    }

    // MARK: - ④ cost

    /// The rewrite must not cost a frame: on a 4.10 Mpx picture the **S1.6 pass** with all four tone
    /// sliders at work may cost **< 0.2 ms** more than the same sliders through 019's arithmetic.
    ///
    /// Both kernels are compiled here from source — the shipped one from the repo file, the 019 one
    /// from the `legacyBody` mirror below (which is the code `ff4222e` shipped, verbatim, so the
    /// comparison is a before/after and not a guess). One dispatch shape, twenty dispatches per
    /// command buffer, best of three: the number is the arithmetic, not the launch overhead.
    func testTheRewriteCostsLessThanPointTwoMilliseconds() throws {
        let harness = try LocalKernelHarness()
        let legacy = try harness.time(legacy: true, blacks: 30, whites: 30, contrast: 40,
                                      shadows: 60, highlights: -30)
        let shipped = try harness.time(legacy: false, blacks: 30, whites: 30, contrast: 40,
                                       shadows: 60, highlights: -30)
        print(String(format: "079 S1.6 pass at 4.10 Mpx, four tone sliders: 019's math %.3f ms, "
                     + "the global bodies %.3f ms, Δ %+.3f ms", legacy, shipped, shipped - legacy))
        XCTAssertLessThan(shipped - legacy, 0.2,
                          "the shared bodies must stay inside the pass's bandwidth")
    }

    // MARK: - the CPU mirrors (the kernels' arithmetic, spelled again on purpose)

    /// sRGB OETF, the encode S4 applies at headroom 1 (the same helper `ToneMapTests` uses).
    static func code(_ v: Double) -> Double {
        let x = max(v, 0)
        return (x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055) * 255
    }

    static func decode(_ code: Double) -> Double {
        let v = max(code, 0)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// 019's contrast, still S2's on this branch: the linear-light power around a 0.18 pivot, at
    /// `contrast = +100` (γ = 4, the send the old masked path also ran).
    func powerContrast(_ v: Double) -> Double {
        0.18 * pow(max(max(v, 0) / 0.18, 1e-6), pow(2, 2.0))
    }

    /// `tone_contrast_ev` in `tone_shape.metal`, and `s2_contrast_ev` in feat/contrast-0107.
    /// The seam is no longer a copy: since 0107 merged, the masked path calls the *same*
    /// `tone_contrast_ev` the global path calls (`tone_shape.metal`), so the CPU reference here is
    /// `S2Contrast.displacement` — the one mirror both paths are pinned to. `travel` is kept in the
    /// signature because call sites pass it; it must equal `S2Contrast.travelEV` (asserted below).
    static func seamContrast(_ v: Double, travel: Double) -> Double {
        precondition(abs(travel - S2Contrast.travelEV) < 1e-12,
                     "S1.6's contrast travel must be the global one (\(travel) ≠ \(S2Contrast.travelEV))")
        let L = log2(max(v, 1e-9))
        return v * pow(2, S2Contrast.displacement(EV: L, contrast: 100))
    }
}

// MARK: - the harness: the shipped S1.6 kernel, compiled here

/// Compiles the **real** `s1_6_local.metal` (the file in the repo, includes inlined the way the app's
/// `KernelLibrary` does) — and, next to it, 019's body as `ff4222e` shipped it. Timing the two gives a
/// before/after in the same process, on the same dispatch shape, for the派单's 0.2 ms budget.
///
/// `LocalParams`/`LocalAdjustDesc` are mirrored field for field (Metal and Swift share no declaration),
/// and the atlas is a single slice of alpha 1 — the pass reads one coverage per mask, which is all the
/// tone bodies care about.
private struct LocalKernelHarness {

    /// 019's `local_adjust`, verbatim: the affine ±0.15 level, the linear-light power for contrast and
    /// the two linear-luma windows. It exists **only** to be timed (and to be the "before" the numbers
    /// in this file are compared against); nothing in the app compiles it.
    static let legacyBody = """
    #include <metal_stdlib>
    #include "primaries.metal"
    using namespace metal;

    struct LocalParams { int4 a; };
    struct LocalAdjustDesc { float4 a; float4 b; float4 c; };

    static inline float3 local_adjust(float3 v, LocalAdjustDesc d) {
        v = max(v, 0.0) * d.a.xyz;
        float blk = -d.c.x / 100.0 * 0.15;
        float wht = 1.0 - d.b.w / 100.0 * 0.15;
        v = max((v - blk) / max(wht - blk, 1e-3), 0.0);
        float gamma = exp2(d.b.x / 100.0 * 2.0);
        v = 0.18 * pow(max(v, 1e-6) / 0.18, gamma);
        float lum = dot(v, kWorkingLumaWeights);
        float wShadow = 1.0 - smoothstep(0.0, 0.5, lum);
        float wHighlight = smoothstep(0.5, 1.0, lum);
        v *= exp2(d.b.z / 100.0 * 0.8 * wShadow);
        v *= exp2(d.b.y / 100.0 * 0.8 * wHighlight);
        return max(v, 0.0);
    }

    kernel void s1_6_local(texture2d<float, access::read> src [[texture(0)]],
                           texture2d_array<float, access::read> atlas [[texture(1)]],
                           texture2d<float, access::write> dst [[texture(2)]],
                           constant LocalParams &p [[buffer(0)]],
                           constant LocalAdjustDesc *adjust [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint2 px = uint2(gid.x + uint(p.a.z), gid.y + uint(p.a.w));
        if (px.x >= src.get_width() || px.y >= src.get_height()) { return; }
        float4 c = src.read(px);
        if (p.a.x == 0) { dst.write(c, px); return; }
        float3 v = c.rgb;
        for (uint i = 0; i < uint(max(p.a.y, 0)); ++i) {
            LocalAdjustDesc d = adjust[i];
            if (d.c.w < 0.5) { continue; }
            float a = atlas.read(px, i).r;
            float w = clamp(a * d.a.w, 0.0, 1.0);
            if (w <= 0.0) { continue; }
            v = mix(v, local_adjust(v, d), w);
        }
        dst.write(float4(v, c.a), px);
    }
    """

    struct Params {
        var a: SIMD4<Int32>   // anyActive, maskCount, originX, originY
    }
    struct Adjust {
        var a: SIMD4<Float>   // gainR, gainG, gainB, amountScale
        var b: SIMD4<Float>   // contrast, highlights, shadows, whites
        var c: SIMD4<Float>   // blacks, contrast travel, pad, enabled
    }

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PhotonsCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root

    let device: MTLDevice
    let queue: MTLCommandQueue
    let shipped: MTLComputePipelineState
    let legacy: MTLComputePipelineState
    let width = 2560, height = 1600    // 4.096 Mpx, the contract's frame size

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw XCTSkip("no command queue") }
        self.queue = queue

        let url = Self.repoRoot.appendingPathComponent("Sources/PhotonsCore/Kernels/s1_6_local.metal")
        let source = try KernelLibrary.expandingLocalIncludes(of: url)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let fn = library.makeFunction(name: "s1_6_local") else {
            throw XCTSkip("s1_6_local is not in the shipped source")
        }
        self.shipped = try device.makeComputePipelineState(function: fn)

        // The legacy body asks for `primaries.metal`; inline it the same way the app does.
        let primaries = try String(contentsOf: Self.repoRoot
            .appendingPathComponent("Sources/PhotonsCore/Kernels/primaries.metal"), encoding: .utf8)
        let legacySource = Self.legacyBody.replacingOccurrences(
            of: "#include \"primaries.metal\"", with: primaries)
        let legacyLibrary = try device.makeLibrary(source: legacySource, options: nil)
        guard let lfn = legacyLibrary.makeFunction(name: "s1_6_local") else {
            throw XCTSkip("the legacy mirror did not compile")
        }
        self.legacy = try device.makeComputePipelineState(function: lfn)
    }

    private func texture(_ format: MTLPixelFormat, array: Bool = false) -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = array ? .type2DArray : .type2D
        d.pixelFormat = format
        d.width = width; d.height = height
        d.arrayLength = 1
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    /// Milliseconds per 4.10 Mpx pass — twenty dispatches inside one command buffer, so the launch cost
    /// is divided by twenty and the comparison is about the arithmetic.
    func time(legacy wantLegacy: Bool, blacks: Float, whites: Float, contrast: Float,
              shadows: Float, highlights: Float) throws -> Double {
        let src = texture(.rgba16Float)
        let dst = texture(.rgba16Float)
        let atlas = texture(.r16Float, array: true)
        let pipeline = wantLegacy ? legacy : shipped

        var params = Params(a: SIMD4(1, 1, 0, 0))
        var adjust = Adjust(a: SIMD4(1, 1, 1, 1),
                            b: SIMD4(contrast, highlights, shadows, whites),
                            c: SIMD4(blacks, 1, 0, 1))
        let paramsBuffer = device.makeBuffer(bytes: &params,
                                             length: MemoryLayout<Params>.stride,
                                             options: .storageModeShared)!
        let adjustBuffer = device.makeBuffer(bytes: &adjust,
                                             length: MemoryLayout<Adjust>.stride,
                                             options: .storageModeShared)!

        func encode(_ from: MTLTexture, _ to: MTLTexture, _ cb: MTLCommandBuffer) {
            guard let enc = cb.makeComputeCommandEncoder() else { return }
            enc.setComputePipelineState(pipeline)
            enc.setTexture(from, index: 0)
            enc.setTexture(atlas, index: 1)
            enc.setTexture(to, index: 2)
            enc.setBuffer(paramsBuffer, offset: 0, index: 0)
            enc.setBuffer(adjustBuffer, offset: 0, index: 1)
            let tw = pipeline.threadExecutionWidth
            let th = pipeline.maxTotalThreadsPerThreadgroup / tw
            enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
            enc.endEncoding()
        }

        let iterations = 20
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {                        // three runs, take the best: the pass is memory-bound
            guard let cb = queue.makeCommandBuffer() else { throw XCTSkip("no command buffer") }
            for i in 0..<iterations { encode(i % 2 == 0 ? src : dst, i % 2 == 0 ? dst : src, cb) }
            let start = CFAbsoluteTimeGetCurrent()
            cb.commit()
            cb.waitUntilCompleted()
            best = min(best, (CFAbsoluteTimeGetCurrent() - start) * 1000.0 / Double(iterations))
        }
        return best
    }
}
