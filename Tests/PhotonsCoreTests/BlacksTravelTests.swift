import XCTest
import Metal
import CryptoKit
@testable import PhotonsCore

/// 342 — the second half of the 「黑」 travel is doubled: `blacks = −100` must take **8-bit code 64** to 0,
/// not the code ~24 the pre-342 curve reached.
///
/// The curve is `tone_shape.metal`'s `s1_end_points` (073B's pure EV knee for `|blacks| ≤ 20`, 073C's
/// hybrid instantiation above it), and the *level* half is what moves the black point:
///
///     t = blacks/100,  a = |t|,  m = smoothstep(0.2, 1, a)
///     EV:    v *= exp2(3 · t · wb)
///     level: v  = toe(v + B_LEV·t·m·wl)                    (unchanged, 073C)
///     342:   v  = toe(v + B_LEV·t·m·wl + EXTRA)            (the second half's own, wider level)
///
/// `EXTRA` rides `m₅ = smoothstep(0.5, 1, a)` — **exactly 0 for `|blacks| ≤ 50`** — so the whole first
/// half of the slider (including ±25 and ±50, which are already on the hybrid entry) keeps 073C's bytes.
///
/// Every number printed here comes from a **render** of the shipped kernel through `RenderGraph`, not
/// from a transcription of the arithmetic.
final class BlacksTravelTests: XCTestCase {

    // MARK: - the grid of the acceptance table

    private static let codes = [0, 8, 16, 32, 48, 64, 80, 96, 128, 192, 255]
    private static let sliders: [Double] = [-100, -75, -50, -25, 0, 25, 50, 75, 100]

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

    // MARK: - ① the table (both sides of the change are recorded in the lane's report)

    func testTheTravelTable() throws {
        let image = ramp()
        let graph = try makeGraph(image, identity: "blacks-travel-table")
        print("342 table — columns: \(Self.codes)")

        for blacks in Self.sliders {
            let rendered = try render(graph, withBlacks(blacks))
            let codes = bandCodes(rendered)
            let cells = Self.codes.map { String(format: "%6.1f", codes[$0]) }.joined(separator: " ")
            print(String(format: "342 blacks %5.0f |%@| lastZero %@ sha %@", blacks, cells,
                         lastZero(codes).map(String.init) ?? "-", rendered.sha256()))
            // The whole travel has to stay a monotone function of the input code — the new level is a
            // black-point *move*, and a move whose slope dips below 0 would fold the shadows.
            for i in 1..<codes.count {
                XCTAssertGreaterThanOrEqual(codes[i], codes[i - 1] - 1e-9,
                                            "blacks \(blacks): ramp folds at code \(i)")
            }
        }
    }

    // MARK: - ② the key point: −100 takes code 64 to 0, code 96 survives

    func testMinus100CrushesTheSixtyFourthCode() throws {
        let graph = try makeGraph(ramp(), identity: "blacks-travel-key")
        let codes = bandCodes(try render(graph, withBlacks(-100)))
        print(String(format: "342 −100: code64 %.2f, code96 %.2f, lastZero %@",
                     codes[64], codes[96], lastZero(codes).map(String.init) ?? "-"))
        XCTAssertEqual(codes[64], 0, accuracy: 0.5,
                       "blacks −100 left code 64 at \(codes[64]) — the level half must reach 64/255")
        XCTAssertGreaterThan(codes[96], 0.5,
                             "blacks −100 ate the whole dark end: code 96 → \(codes[96])")
        // The pre-342 curve stopped at code 24; the brief names 64 and 65 must survive.
        XCTAssertEqual(lastZero(codes), 64, "the crushed band does not end at code 64")
        XCTAssertGreaterThan(codes[65], 0.5, "code 65 is crushed too — the black point overshot")
    }

    // MARK: - ③ the first half is byte-identical

    /// sha256 of the whole display render of the 0…255 ramp, recorded from the code **before** 342
    /// touched the level half. `|blacks| ≤ 50` must stay exactly these bytes: 342 adds a level term
    /// that rides `smoothstep(0.5, 1, |blacks|/100)`, which is exactly 0 up to and including 50.
    private static let pinnedFirstHalf: [(blacks: Double, hash: String)] = [
        (0, "90dda1222491c1620f5b02fdd34ba628194b895a96fa69cfdce8770fb5350250"),
        (-25, "a0c11a7c167aeff41fa8e9ae8f0f5e033ad20d7c70daf7617f3875b16b843bf0"),
        (25, "71e10a43639d355103c3e4e76092f62c331cc10db1ba674d685cc040e7088cde"),
        (-50, "9f46cda232ca33799d3cefaa27cc9f57519b182de77d7c06a6a7ddd03828e280"),
        (50, "4c1bacf6278590a438b5345fc1431d5e88ae6681834a9cb6055d81db5fae8bbd"),
    ]

    func testTheFirstHalfIsByteIdentical() throws {
        let graph = try makeGraph(ramp(), identity: "blacks-travel-firsthalf")
        for (blacks, expected) in Self.pinnedFirstHalf {
            let hash = try render(graph, withBlacks(blacks)).sha256()
            print(String(format: "342 first half blacks %5.0f: %@", blacks, hash))
            if !expected.isEmpty {
                XCTAssertEqual(hash, expected,
                               "blacks \(blacks) moved — the first half of the travel must stay byte-identical")
            }
        }
    }

    // MARK: - ④ 18 % grey does not move

    /// Display code of a flat 18 % grey (`v = 0.18`) at `blacks = −100`, recorded **before** 342 touched
    /// the level half. The slider's own EV knee already moves 18 % grey by ~5.9 codes against `blacks = 0`
    /// — that is 073B, not this change — so the assertion is "342 moved it by ≤ 2 codes".
    private static let pinned18Percent = 111.74926757812499

    func testEighteenPercentGreyDoesNotMove() throws {
        let graph = try makeGraph(flat(0.18), identity: "blacks-travel-18")
        var codes: [Double] = []
        for blacks in [-100.0, -75, 0] {
            let img = try render(graph, withBlacks(blacks))
            let o = ((img.height / 2) * img.width + img.width / 2) * 4
            codes.append(Self.code(0.2126 * Double(img.rgba[o]) + 0.7152 * Double(img.rgba[o + 1])
                                   + 0.0722 * Double(img.rgba[o + 2])))
        }
        print(String(format: "342 18%% grey: −100 %.2f, −75 %.2f, 0 %.2f (Δ vs 0: %.2f)",
                     codes[0], codes[1], codes[2], codes[0] - codes[2]))
        XCTAssertLessThanOrEqual(abs(codes[0] - Self.pinned18Percent), 2,
                                 "blacks −100 moved 18 % grey by \(codes[0] - Self.pinned18Percent) codes")
    }

    // MARK: - ⑤ the positive travel still lifts, and stays under 64/255

    func testThePositiveTravelStillLiftsBlackUnderSixtyFour() throws {
        let graph = try makeGraph(flat(0), identity: "blacks-travel-lift")
        var codes: [Double] = []
        for blacks in [0.0, 50, 100] {
            let img = try render(graph, withBlacks(blacks))
            let o = ((img.height / 2) * img.width + img.width / 2) * 4
            codes.append(Self.code(0.2126 * Double(img.rgba[o]) + 0.7152 * Double(img.rgba[o + 1])
                                   + 0.0722 * Double(img.rgba[o + 2])))
        }
        print(String(format: "342 +travel on true black: 0 %.2f, +50 %.2f, +100 %.2f", codes[0], codes[1], codes[2]))
        XCTAssertGreaterThan(codes[2], codes[0] + 5, "blacks +100 no longer lifts the black point")
        XCTAssertLessThanOrEqual(codes[2], 64, "blacks +100 lifted true black to \(codes[2])/255")
    }

    // MARK: - ⑥ a mask is the same curve

    /// A full-coverage disc (`feather = 0`, radius 0.45 of the short edge) with the mask's own blacks.
    private func discMask(blacks: Double) -> Mask {
        Mask(id: "m-342",
             components: [MaskComponent(id: "c", feather: 0,
                                        shape: .radialGradient(RadialGradientShape(
                                            center: NormalizedPoint(0.5, 0.5),
                                            radius: NormalizedPoint(0.45, 0.45))))],
             adjustments: LocalAdjustments(amount: 100, blacks: blacks))
    }

    func testTheMaskRunsTheSameCurveAsTheGlobalSlider() throws {
        for value in [Float(0.18), Float(0.0513), Float(0.005)] {
            let image = flat(value, width: 96, height: 96)
            let graph = try makeGraph(image, identity: "blacks-travel-mask")
            var masked = EditModel.neutral
            masked.masks = [discMask(blacks: -100)]
            let maskImage = try render(graph, masked)
            let globalImage = try render(graph, withBlacks(-100))

            let cx = maskImage.width / 2, cy = maskImage.height / 2
            let o = (cy * maskImage.width + cx) * 4
            func lum(_ img: DisplayImage) -> Double {
                Self.code(0.2126 * Double(img.rgba[o]) + 0.7152 * Double(img.rgba[o + 1])
                          + 0.0722 * Double(img.rgba[o + 2]))
            }
            print(String(format: "342 mask vs global at v = %.4f: %.2f vs %.2f (Δ %.2f)",
                         value, lum(maskImage), lum(globalImage), abs(lum(maskImage) - lum(globalImage))))
            XCTAssertLessThanOrEqual(abs(lum(maskImage) - lum(globalImage)), 1,
                                     "the masked blacks is not the global curve at v = \(value)")
        }
    }
}
