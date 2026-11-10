import XCTest
import Metal
import CryptoKit
@testable import PhotonsCore

/// 346 — the 「黑」 slider is **mapped into kernel units**, so its mechanism switch sits at ±30 and the
/// two ends keep 342's bytes: new `−30` is old `−50`, new `−100` is old `−100`.
///
/// `tone_shape.metal` is untouched. Its travel is still `t = k/100` with 073B's pure-EV knee inside
/// `|k| ≤ 50`, 073C's level on top of it, and 342's second, wider level on the crush side:
///
///     k = LightGroup.blacksKernelValue(blacks)        ← the only new arithmetic (CPU, in the key too)
///     |x| ≤ 30:  k = x·5/3        (slider 0…30   → kernel 0…50)
///     else:      k = sign·(50 + (|x|−30)·5/7)         (slider 30…100 → kernel 50…100)
///
///     t = k/100,  a = |t|,  m = smoothstep(0.2, 1, a)
///     EV:    v *= exp2(3 · t · wb)
///     level: v  = toe(v + B_LEV·t·m·wl)                    (073C)
///     342:   v  = toe(v + B_LEV·t·m·wl − B_LEV_CRUSH·a·m₅·wl₂)
///
/// Because the map is exact at the named points (`±30 → ±50`, `±100 → ±100`, `±15 → ±25`), the four
/// equivalences are **byte** equalities of a whole display render, and this file pins them against the
/// hashes recorded from 342's own code (the `pre-346` column), not against a re-render.
///
/// Every number printed here comes from a **render** of the shipped kernel through `RenderGraph`, not
/// from a transcription of the arithmetic.
final class BlacksTravelTests: XCTestCase {

    // MARK: - the grid of the acceptance table

    private static let codes = [0, 8, 16, 32, 48, 64, 80, 96, 128, 192, 255]
    private static let sliders: [Double] = [-100, -75, -50, -30, -15, -10, 0, 10, 15, 30, 50, 75, 100]

    /// sRGB EOTF: the scene-linear value whose **display** code is `code` at `blacks = 0`.
    private static func linear(_ code: Int) -> Float {
        let c = Double(code) / 255
        return Float(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
    }

    /// Display code 0…255 of a display value.
    private static func code(_ v: Double) -> Double { 255 * max(v, 0) }

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// One 4 px band per 8-bit code, 0…255: the ramp the acceptance table is read from.
    private func ramp() -> LinearImage {
        let bands = 4, width = 256 * bands, height = 8
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = Float16(Self.linear(x / bands))
                let o = (y * width + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func flat(_ value: Float, width: Int = 64, height: Int = 64) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = Float16(value); rgba[i + 1] = Float16(value)
            rgba[i + 2] = Float16(value); rgba[i + 3] = 1
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

    private func withBlacks(_ blacks: Double) -> EditModel {
        var edit = EditModel.neutral
        edit.light.blacks = blacks
        return edit
    }

    /// Display code of every band of the ramp.
    private func bandCodes(_ image: DisplayImage) -> [Double] {
        let bands = 256
        let bandWidth = image.width / bands
        return (0..<bands).map { band in
            let x = band * bandWidth + bandWidth / 2
            var sum = 0.0
            for y in 0..<image.height {
                let o = (y * image.width + x) * 4
                sum += 0.2126 * Double(image.rgba[o]) + 0.7152 * Double(image.rgba[o + 1])
                    + 0.0722 * Double(image.rgba[o + 2])
            }
            return Self.code(sum / Double(image.height))
        }
    }

    /// The **highest** code that has reached 0 — "−100 只能让 32/255 变 0" is a statement about this
    /// number (`0…N` are crushed, `N + 1` is not).
    private func lastZero(_ codes: [Double]) -> Int? {
        codes.lastIndex { $0 <= 0.5 }
    }

    // MARK: - ① the table (both sides of the change are in the lane's report)

    func testTheTravelTable() throws {
        let image = ramp()
        let graph = try makeGraph(image, identity: "blacks-travel-table")
        print("346 table — columns: \(Self.codes)")

        for blacks in Self.sliders {
            let rendered = try render(graph, withBlacks(blacks))
            let codes = bandCodes(rendered)
            let cells = Self.codes.map { String(format: "%6.1f", codes[$0]) }.joined(separator: " ")
            print(String(format: "346 blacks %5.0f (k %+7.3f) |%@| lastZero %@ sha %@", blacks,
                         LightGroup.blacksKernelValue(blacks), cells,
                         lastZero(codes).map(String.init) ?? "-", rendered.sha256()))
            // The whole travel has to stay a monotone function of the input code — the level is a
            // black-point *move*, and a move whose slope dips below 0 would fold the shadows.
            for i in 1..<codes.count {
                XCTAssertGreaterThanOrEqual(codes[i], codes[i - 1] - 1e-9,
                                            "blacks \(blacks): ramp folds at code \(i)")
            }
        }
    }

    // MARK: - ② the four named equivalences, and the midpoint

    /// sha256 of the whole display render of the 0…255 ramp, recorded from **342's code** (slider and
    /// kernel were the same number there). Each `expected` is what that kernel value wrote, so the
    /// assertion is the acceptance's own words: new `−30` ≡ old `−50`, new `±100` ≡ old `±100`, and
    /// the linear midpoint new `−15` ≡ old `−25`.
    ///
    /// The mapping is exact at these four points (`30·5/3 == 50`, `70·5/7 == 50`, `15·5/3 == 25`), so
    /// "byte identical" is a claim about the same kernel argument, not about a tolerance.
    private static let preEquivalences: [(slider: Double, oldKernel: Double, hash: String)] = [
        (-30, -50, "9f46cda232ca33799d3cefaa27cc9f57519b182de77d7c06a6a7ddd03828e280"),
        (-100, -100, "336f60c33cef748c19d8675dca3e645db32e8adcf3a54d27414491015b8047a0"),
        (30, 50, "4c1bacf6278590a438b5345fc1431d5e88ae6681834a9cb6055d81db5fae8bbd"),
        (100, 100, "8a221f49c2d3a5ecef93c04b0de52ce55d71422abefe5e9b0c31dda9b8a1297a"),
    ]

    func testTheNamedEquivalencesAreByteIdentical() throws {
        let graph = try makeGraph(ramp(), identity: "blacks-travel-equivalence")
        for row in Self.preEquivalences {
            XCTAssertEqual(LightGroup.blacksKernelValue(row.slider), row.oldKernel,
                           "\(row.slider) must map to the old kernel value \(row.oldKernel)")
            let rendered = try render(graph, withBlacks(row.slider))
            let hash = rendered.sha256()
            print(String(format: "346 new %5.0f (old kernel %5.0f): %@  %@", row.slider,
                         row.oldKernel, hash, hash == row.hash ? "≡" : "≠"))
            XCTAssertEqual(hash, row.hash,
                           "new \(row.slider) is not byte-identical to old \(row.oldKernel)")
        }
    }

    /// The linear midpoint, `new −15 ≡ old −25` (both −15·5/3 and 25 are the same kernel argument).
    ///
    /// Whole-image hashes differ in **one band**: true black. Old −25 ran the hybrid instantiation,
    /// whose lift goes through `s1_toe`, so a `0` sample comes back at code 0.5; new −15 is inside the
    /// EV half and dispatches the knee, which leaves `0` at `0`. That is the same kernel-side exception
    /// `BlacksBoundaryTests` documents (0.82 code at |k| ≤ 20), not a curve difference — bands 1…255
    /// are compared against the **pre-346 numbers**, recorded from 342's build.
    func testTheMidpointMatchesOldMinusTwentyFive() throws {
        let graph = try makeGraph(ramp(), identity: "blacks-travel-midpoint")
        // The recorded pre-346 column for blacks = −25, at codes 0/8/…/128.
        let old: [Double] = [0.5, 5.3, 12.0, 27.7, 43.9, 60.4, 77.0, 93.6, 126.9]
        let codes = bandCodes(try render(graph, withBlacks(-15)))
        let printed = Self.codes.prefix(old.count).map { String(format: "%5.1f", codes[$0]) }.joined(separator: " ")
        print("346 −15 (old −25 curve): |\(printed)|")
        XCTAssertEqual(codes[0], 0, accuracy: 1e-9, "the knee keeps true black at 0")
        for (i, code) in old.enumerated() where i > 0 {
            XCTAssertEqual(codes[Self.codes[i]], code, accuracy: 0.05,
                           "new −15 differs from old −25 at code \(Self.codes[i]): \(codes[Self.codes[i]]) vs \(code)")
        }
        print(String(format: "346 −15 vs old −25 true black: 0.0 vs %.1f (Δ 0.5 code, the documented toe)", old[0]))
    }

    // MARK: - ③ −100 still takes code 64 to 0; −30 only reaches old −50's depth

    func testMinus100CrushesTheSixtyFourthCode() throws {
        let graph = try makeGraph(ramp(), identity: "blacks-travel-key")
        let codes = bandCodes(try render(graph, withBlacks(-100)))
        print(String(format: "346 −100: code64 %.2f, code96 %.2f, lastZero %@",
                     codes[64], codes[96], lastZero(codes).map(String.init) ?? "-"))
        XCTAssertEqual(codes[64], 0, accuracy: 0.5,
                       "blacks −100 left code 64 at \(codes[64]) — the level half must reach 64/255")
        XCTAssertGreaterThan(codes[96], 0.5,
                             "blacks −100 ate the whole dark end: code 96 → \(codes[96])")
        // The pre-342 curve stopped at code 24; 342's brief names 64 and 65 as the boundary.
        XCTAssertEqual(lastZero(codes), 64, "the crushed band does not end at code 64")
        XCTAssertGreaterThan(codes[65], 0.5, "code 65 is crushed too — the black point overshot")

        // 346: the same statement for the new switch point. New −30 is the *old −50* curve, i.e. it
        // must NOT crush like −100 — that is the whole reason the slider was re-mapped.
        let atThirty = bandCodes(try render(graph, withBlacks(-30)))
        print(String(format: "346 −30 : code64 %.2f, lastZero %@",
                     atThirty[64], lastZero(atThirty).map(String.init) ?? "-"))
        XCTAssertGreaterThan(atThirty[64], 0.5, "new −30 must not crush code 64 (that is −100's job)")
        if let n = lastZero(atThirty) {
            XCTAssertLessThan(n, 24, "new −30 crushes to code \(n) — that is deeper than old −50")
        }
    }

    // MARK: - ④ 18 % grey does not move

    /// Display code of a flat 18 % grey (`v = 0.18`) at `blacks = −100`, recorded **before** 342 touched
    /// the level half. The slider's own EV knee already moves 18 % grey by ~5.9 codes against `blacks = 0`
    /// — that is 073B, not this change — so the assertion is "the change moved it by ≤ 2 codes".
    private static let pinned18Percent = 111.74926757812499

    func testEighteenPercentGreyDoesNotMove() throws {
        let graph = try makeGraph(flat(0.18), identity: "blacks-travel-18")
        var codes: [Double] = []
        for blacks in [-100.0, -30, 0] {
            let img = try render(graph, withBlacks(blacks))
            let o = ((img.height / 2) * img.width + img.width / 2) * 4
            codes.append(Self.code(0.2126 * Double(img.rgba[o]) + 0.7152 * Double(img.rgba[o + 1])
                                   + 0.0722 * Double(img.rgba[o + 2])))
        }
        print(String(format: "346 18%% grey: −100 %.2f, −30 %.2f, 0 %.2f (Δ vs 0: %.2f)",
                     codes[0], codes[1], codes[2], codes[0] - codes[2]))
        XCTAssertLessThanOrEqual(abs(codes[0] - Self.pinned18Percent), 2,
                                 "blacks −100 moved 18 % grey by \(codes[0] - Self.pinned18Percent) codes")
    }

    // MARK: - ⑤ the positive travel still lifts, and stays under 64/255

    func testThePositiveTravelStillLiftsBlackUnderSixtyFour() throws {
        let graph = try makeGraph(flat(0), identity: "blacks-travel-lift")
        var codes: [Double] = []
        for blacks in [0.0, 30, 100] {
            let img = try render(graph, withBlacks(blacks))
            let o = ((img.height / 2) * img.width + img.width / 2) * 4
            codes.append(Self.code(0.2126 * Double(img.rgba[o]) + 0.7152 * Double(img.rgba[o + 1])
                                   + 0.0722 * Double(img.rgba[o + 2])))
        }
        print(String(format: "346 +travel on true black: 0 %.2f, +30 %.2f, +100 %.2f",
                     codes[0], codes[1], codes[2]))
        XCTAssertGreaterThan(codes[2], codes[0] + 5, "blacks +100 no longer lifts the black point")
        XCTAssertLessThanOrEqual(codes[2], 64, "blacks +100 lifted true black to \(codes[2])/255")
    }

    // MARK: - ⑥ a mask is the same curve

    /// A full-coverage disc (`feather = 0`, radius 0.45 of the short edge) with the mask's own blacks.
    private func discMask(blacks: Double) -> Mask {
        Mask(id: "m-346",
             components: [MaskComponent(id: "c", feather: 0,
                                        shape: .radialGradient(RadialGradientShape(
                                            center: NormalizedPoint(0.5, 0.5),
                                            radius: NormalizedPoint(0.45, 0.45))))],
             adjustments: LocalAdjustments(amount: 100, blacks: blacks))
    }

    func testTheMaskRunsTheSameCurveAsTheGlobalSlider() throws {
        for (value, blacks) in [(Float(0.18), -100.0), (Float(0.0513), -100), (Float(0.005), -100),
                                (Float(0.18), -30), (Float(0.0513), -30), (Float(0.005), -30)] {
            let image = flat(value, width: 96, height: 96)
            let graph = try makeGraph(image, identity: "blacks-travel-mask")
            var masked = EditModel.neutral
            masked.masks = [discMask(blacks: blacks)]
            let maskImage = try render(graph, masked)
            let globalImage = try render(graph, withBlacks(blacks))

            let cx = maskImage.width / 2, cy = maskImage.height / 2
            let o = (cy * maskImage.width + cx) * 4
            func lum(_ img: DisplayImage) -> Double {
                Self.code(0.2126 * Double(img.rgba[o]) + 0.7152 * Double(img.rgba[o + 1])
                          + 0.0722 * Double(img.rgba[o + 2]))
            }
            print(String(format: "346 mask vs global at v = %.4f, bl %.0f: %.2f vs %.2f (Δ %.2f)",
                         value, blacks, lum(maskImage), lum(globalImage),
                         abs(lum(maskImage) - lum(globalImage))))
            XCTAssertLessThanOrEqual(abs(lum(maskImage) - lum(globalImage)), 1,
                                     "the masked blacks is not the global curve at v = \(value)")
        }
    }

    // MARK: - ⑦ the key carries the kernel value

    /// Acceptance ⑦: `blacks == 0`'s key is byte-identical to the document's neutral key, and
    /// `blacks = −30` prints the text old `−50` printed (`bl=-50.00000`) — the cache entry of the old
    /// −50 render, which is the same picture.
    func testTheKeyCarriesTheKernelValue() {
        let neutral = EditModel.neutral
        let zero = withBlacks(0)
        XCTAssertEqual(zero.keyMaterial(.sceneLinear), neutral.keyMaterial(.sceneLinear),
                       "blacks = 0 must not move a byte of S1's material")
        XCTAssertTrue(zero.keyMaterial(.sceneLinear).hasSuffix(";bl=0.00000;alg=10"),
                      "got \(zero.keyMaterial(.sceneLinear))")

        let pairs: [(Double, String)] = [(-30, "bl=-50.00000"), (-100, "bl=-100.00000"),
                                         (30, "bl=50.00000"), (100, "bl=100.00000"),
                                         (-15, "bl=-25.00000"), (15, "bl=25.00000")]
        for (blacks, token) in pairs {
            let material = withBlacks(blacks).keyMaterial(.sceneLinear)
            print("346 key bl \(blacks): \(material)")
            XCTAssertTrue(material.contains(";\(token);"),
                          "blacks \(blacks) must key on the kernel value (\(token)), got \(material)")
        }
        // Two adjacent slider values still get two keys (the mapping is injective on 1/64ths).
        XCTAssertNotEqual(withBlacks(29.9).keyMaterial(.sceneLinear),
                          withBlacks(30.1).keyMaterial(.sceneLinear))
        // The mask's own key follows the same rule.
        XCTAssertEqual(LocalAdjustments(amount: 100, blacks: -30).keyString
                        .contains(";bl=-50.00000;"), true)
        XCTAssertEqual(LocalAdjustments(amount: 100, blacks: 0).keyString
                        .contains(";bl=0.00000;"), true)
    }
}
