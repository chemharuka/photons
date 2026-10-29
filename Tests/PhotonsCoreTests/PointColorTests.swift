import XCTest
import Metal
import CryptoKit
import simd
import PhotonsCore

/// 140 — **点颜色 (Point Color)**: one sampled OKLCh colour, a hue window and three adjustments,
/// rendered by S3.6b immediately after S3.6.
///
/// The suite is organised around what can be wrong, in the order it can lie:
///
///  1. **The window.** A point colour is not a global look: the seven colours outside the sampled
///     window must be byte-identical (measured as ΔE00 < 0.5, and in fact 0 because the stage writes
///     the source pixel back when the weight is 0).
///  2. **The adjustment.** On the sampled colour the hue moves by +30° at slider +100, saturation
///     changes chroma in the right direction without dragging hue with it, and the window's shoulder
///     is C¹ — a 1°-per-pixel wheel has no step at either edge.
///  3. **Grey is exact.** The chroma gate is the **same** helper S3.4/S3.6 use, so a neutral frame is
///     bit-identical under any parameters, even though the stage is active.
///  4. **Neutral is structural.** No sample, or all three sliders at 0, means no S3.6b in the trace,
///     no link in the key chain, and the neutral frame's sha.
///  5. **The document.** Schema 12 is additive: a schema-11 blob reads `point == nil`, re-encodes byte
///     for byte, and is not stamped; a sample is one object with its own key.
final class PointColorTests: XCTestCase {

    // MARK: - fixtures

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func picture(_ width: Int, _ height: Int, identity: String = "point-colour",
                         _ body: (Int, Int) -> (Double, Double, Double)) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = body(x, y)
                let o = (y * width + x) * 4
                rgba[o] = Float16(r); rgba[o + 1] = Float16(g)
                rgba[o + 2] = Float16(b); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB",
                           decoderVersion: "synthetic-140")
    }

    private static let toWorking = ColorPrimaries.conversion(from: ColorPrimaries.decoded,
                                                             to: ColorPrimaries.working)
    private static let toSRGB = ColorPrimaries.conversion(from: ColorPrimaries.working, to: .sRGB)
    private static let fromSRGB = ColorPrimaries.conversion(from: .sRGB, to: ColorPrimaries.working)

    /// Eight colour blocks, 45° apart on the OKLCh wheel. 45° spacing means a 15°/15° window (the
    /// outside test) selects one block and leaves seven untouched; the default 30°/30° window is used
    /// by the movement and no-step tests.
    private static let blockHues: [Double] = (0..<8).map {
        (24.78 + 45.0 * Double($0)).truncatingRemainder(dividingBy: 360)
    }

    private func blocks() -> LinearImage {
        picture(64, 32) { x, _ in
            let hsl = OKLCh.toLinear(L: 0.62, C: 0.08, hue: Self.blockHues[x / 8])
            let srgb = Self.toSRGB.applying(to: hsl)
            return (srgb.x, srgb.y, srgb.z)
        }
    }

    /// A 360-column wheel, one OKLCh degree per column, for the seam/shoulder sweep.
    private func wheel(height: Int = 8, L: Double = 0.60, C: Double = 0.06) -> LinearImage {
        picture(360, height) { x, _ in
            let working = OKLCh.toLinear(L: L, C: C, hue: Double(x))
            let srgb = Self.toSRGB.applying(to: working)
            return (srgb.x, srgb.y, srgb.z)
        }
    }

    private func display(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, display: DisplayOptions(),
                                    useCache: false, wantsPixels: true)
        return try XCTUnwrap(graph.render(edit, options: options).display)
    }

    /// A document whose point card is sampled and adjusted.
    private func document(sampleHue: Double = 24.78, sampleChroma: Double = 0.08,
                          range: Double = 30, feather: Double = 30,
                          hue: Double = 0, saturation: Double = 0,
                          luminance: Double = 0) -> EditModel {
        var edit = EditModel.neutral
        edit.color.point = PointColor(sampleHue: sampleHue, sampleChroma: sampleChroma,
                                      range: range, feather: feather,
                                      hue: hue, saturation: saturation, luminance: luminance)
        return edit
    }

    private static func code(_ v: Float16) -> Int { Int((Double(v) * 255).rounded()) }

    /// One display pixel decoded back to linear sRGB then the working primaries.
    private static func workingPixel(_ img: DisplayImage, x: Int, y: Int) -> SIMD3<Double> {
        let o = (y * img.width + x) * 4
        func decode(_ v: Float16) -> Double {
            let c = Double(v)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let srgb = SIMD3(decode(img.rgba[o]), decode(img.rgba[o + 1]), decode(img.rgba[o + 2]))
        return fromSRGB.applying(to: srgb)
    }

    private static func oklch(_ img: DisplayImage, x: Int, y: Int) -> (L: Double, C: Double, h: Double) {
        let lch = OKLCh.fromLinear(workingPixel(img, x: x, y: y))
        return (lch.L, lch.C, lch.hue)
    }

    private static func signedHueDelta(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    // MARK: - ΔE00 (the acceptance's own unit)

    private static func lab(_ img: DisplayImage, x: Int, y: Int) -> SIMD3<Double> {
        let o = (y * img.width + x) * 4
        func decode(_ v: Float16) -> Double {
            let c = Double(v)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = decode(img.rgba[o]), g = decode(img.rgba[o + 1]), b = decode(img.rgba[o + 2])
        let X = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let Y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let Z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        func f(_ t: Double) -> Double {
            let d = 6.0 / 29.0
            return t > d * d * d ? cbrt(t) : t / (3 * d * d) + 4.0 / 29.0
        }
        let fx = f(X / 0.95047), fy = f(Y / 1.0), fz = f(Z / 1.08883)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIEDE2000, the formula the acceptance names. Only used on 8-bit display pixels; the numbers
    /// that matter in these tests (an untouched block) are exactly 0 because the pixels are identical.
    private static func deltaE00(_ p: SIMD3<Double>, _ q: SIMD3<Double>) -> Double {
        let c1 = (p.y * p.y + p.z * p.z).squareRoot()
        let c2 = (q.y * q.y + q.z * q.z).squareRoot()
        let cBar = (c1 + c2) / 2
        let cBar7 = pow(cBar, 7)
        let g = 0.5 * (1 - (cBar7 / (cBar7 + pow(25, 7))).squareRoot())
        let a1 = (1 + g) * p.y, a2 = (1 + g) * q.y
        let cp1 = (a1 * a1 + p.z * p.z).squareRoot()
        let cp2 = (a2 * a2 + q.z * q.z).squareRoot()
        func hue(_ b: Double, _ a: Double) -> Double {
            guard a != 0 || b != 0 else { return 0 }
            var h = atan2(b, a) * 180 / .pi
            if h < 0 { h += 360 }
            return h
        }
        let h1 = hue(p.z, a1), h2 = hue(q.z, a2)
        let dL = q.x - p.x
        let dC = cp2 - cp1
        var dh = h2 - h1
        if cp1 * cp2 == 0 { dh = 0 }
        else if dh > 180 { dh -= 360 }
        else if dh < -180 { dh += 360 }
        let dH = 2 * (cp1 * cp2).squareRoot() * sin(dh * .pi / 360)
        let lBar = (p.x + q.x) / 2
        let cpBar = (cp1 + cp2) / 2
        let hBar: Double
        if cp1 * cp2 == 0 { hBar = h1 + h2 }
        else if abs(h1 - h2) <= 180 { hBar = (h1 + h2) / 2 }
        else if h1 + h2 < 360 { hBar = (h1 + h2 + 360) / 2 }
        else { hBar = (h1 + h2 - 360) / 2 }
        let t = 1 - 0.17 * cos((hBar - 30) * .pi / 180)
            + 0.24 * cos(2 * hBar * .pi / 180)
            + 0.32 * cos((3 * hBar + 6) * .pi / 180)
            - 0.20 * cos((4 * hBar - 63) * .pi / 180)
        let dTheta = 30 * exp(-pow((hBar - 275) / 25, 2))
        let cpBar7 = pow(cpBar, 7)
        let rc = 2 * (cpBar7 / (cpBar7 + pow(25, 7))).squareRoot()
        let sl = 1 + 0.015 * pow(lBar - 50, 2) / (20 + pow(lBar - 50, 2)).squareRoot()
        let sc = 1 + 0.045 * cpBar
        let sh = 1 + 0.015 * cpBar * t
        let rt = -sin(2 * dTheta * .pi / 180) * rc
        let l = dL / sl, c = dC / sc, h = dH / sh
        return (l * l + c * c + h * h + rt * c * h).squareRoot()
    }

    // MARK: - ① the window

    /// **The acceptance.** Sample the red block, shift its hue, and the other seven blocks do not
    /// move. The window here is 15°/15° because the fixture's ladder is 45° apart; the default 30°/30°
    /// window would legitimately reach into the neighbouring block.
    func testOutsideTheRangeIsUntouched() throws {
        let image = blocks()
        let graph = try makeGraph(image, identity: "140-outside")
        let neutral = try display(graph, EditModel.neutral)
        let moved = try display(graph, document(range: 15, feather: 15, hue: 30))
        XCTAssertTrue(try graph.render(document(range: 15, feather: 15, hue: 30),
                                       options: RenderOptions(scale: 1, useCache: false,
                                                              wantsPixels: true))
            .trace.executed.contains(.pointColour))

        var worstOutside = 0.0
        for i in 0..<8 {
            let x = i * 8 + 4
            let before = Self.lab(neutral, x: x, y: 16)
            let after = Self.lab(moved, x: x, y: 16)
            let dE = Self.deltaE00(before, after)
            if i == 0 {
                XCTAssertGreaterThan(dE, 0.5, "the sampled block must move")
            } else {
                worstOutside = max(worstOutside, dE)
                XCTAssertLessThan(dE, 0.5, "block \(i) is outside the window and must not move")
                // Stronger than ΔE00: every channel is the same Float16 bit pattern.
                for c in 0..<4 {
                    XCTAssertEqual(moved.rgba[(16 * moved.width + x) * 4 + c],
                                   neutral.rgba[(16 * neutral.width + x) * 4 + c],
                                   "block \(i) channel \(c) is not bit-identical")
                }
            }
        }
        print("POINT OUTSIDE · worst ΔE00 on the seven outside blocks = "
              + String(format: "%.6f", worstOutside))
    }

    // MARK: - ② the adjustment

    func testInsideTheRangeMovesHue() throws {
        let image = blocks()
        let graph = try makeGraph(image, identity: "140-inside")
        let neutral = try display(graph, EditModel.neutral)
        let moved = try display(graph, document(hue: 100))

        let x = 4
        let before = Self.oklch(neutral, x: x, y: 16)
        let after = Self.oklch(moved, x: x, y: 16)
        let delta = Self.signedHueDelta(before.h, after.h)
        print(String(format: "POINT HUE · %.2f° + 30° → %.2f° (Δ %.2f°)", before.h, after.h, delta))
        XCTAssertEqual(delta, 30, accuracy: 1, "hue +100 must deliver +30° on the sampled colour")
        XCTAssertEqual(after.L, before.L, accuracy: 0.01, "a hue rotation must not brighten it")
        XCTAssertEqual(after.C, before.C, accuracy: 0.01, "…nor change its chroma")

        // Saturation ±50 changes chroma in the right direction and does not drag the hue.
        let up = try display(graph, document(saturation: 50))
        let down = try display(graph, document(saturation: -50))
        let cUp = Self.oklch(up, x: x, y: 16)
        let cDown = Self.oklch(down, x: x, y: 16)
        XCTAssertGreaterThan(cUp.C, before.C, "saturation +50 must raise chroma")
        XCTAssertLessThan(cDown.C, before.C, "saturation −50 must lower chroma")
        XCTAssertLessThanOrEqual(abs(Self.signedHueDelta(before.h, cUp.h)), 2,
                                 "a chroma scale must not rotate the hue")
        XCTAssertLessThanOrEqual(abs(Self.signedHueDelta(before.h, cDown.h)), 2,
                                 "…in either direction")
        print(String(format: "POINT SAT · C %.4f → +50: %.4f · −50: %.4f", before.C, cUp.C, cDown.C))
    }

    /// **No hard edge.** One OKLCh degree per pixel, default 30°/30° window, +30° rotation: adjacent
    /// columns must not step. Both the `range` and `range + feather` shoulders are crossed in one
    /// sweep, seam included.
    func testNoHardEdgeAtTheBoundary() throws {
        let image = wheel()
        let graph = try makeGraph(image, identity: "140-edge")
        let moved = try display(graph, document(sampleHue: 40, sampleChroma: 0.06,
                                                range: 30, feather: 30, hue: 100))
        var worst = 0.0
        for x in 0..<(moved.width - 1) {
            let a = Self.lab(moved, x: x, y: 4)
            let b = Self.lab(moved, x: x + 1, y: 4)
            worst = max(worst, Self.deltaE00(a, b))
        }
        // The wrap from 359° back to 0° is the same physical step as any other.
        let seamA = Self.lab(moved, x: moved.width - 1, y: 4)
        let seamB = Self.lab(moved, x: 0, y: 4)
        worst = max(worst, Self.deltaE00(seamA, seamB))
        print(String(format: "POINT EDGE · worst adjacent ΔE00 on a 1°/px wheel = %.3f", worst))
        XCTAssertLessThan(worst, 2, "the window's shoulders (and the 0°/360° seam) must not step")
    }

    // MARK: - ③ grey is exact

    func testGreyPixelsAreBitIdentical() throws {
        // A neutral ramp: every pixel is r = g = b, so the OKLab fold lands within 1e-8 of C = 0 and
        // the shared gate is exactly 0.
        let image = picture(32, 32) { x, _ in
            let v = 0.03 + Double(x) / 31 * 0.75
            return (v, v, v)
        }
        let graph = try makeGraph(image, identity: "140-grey")
        let neutral = try display(graph, EditModel.neutral)
        for edit in [document(hue: 100, saturation: 100, luminance: 100),
                     document(sampleHue: 200, sampleChroma: 0.12,
                              range: 0, feather: 180, hue: -100, saturation: -100,
                              luminance: -100)] {
            let out = try display(graph, edit)
            XCTAssertEqual(out.sha256(), neutral.sha256(),
                           "a neutral pixel has no hue: S3.6b must leave it bit-identical")
        }
        XCTAssertEqual(HSLBands.chromaGate(for: 0), 0)
        XCTAssertEqual(HSLBands.chromaGate(for: 1e-7), 0)
        print("POINT GREY · every parameter set leaves the grey ramp byte-identical")
    }

    // MARK: - ④ neutral is structural

    func testNeutralDocumentAddsNoPass() throws {
        let image = blocks()
        let graph = try makeGraph(image, identity: "140-neutral")
        let plain = try graph.render(EditModel.neutral,
                                     options: RenderOptions(scale: 1, useCache: false,
                                                            wantsPixels: true))
        let neutral = try XCTUnwrap(plain.display)

        let unsampled = document(sampleChroma: 0, hue: 100)
        let unadjusted = document(hue: 0, saturation: 0, luminance: 0)
        let allZero = EditModel.neutral
        for edit in [unsampled, unadjusted, allZero] {
            let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                       wantsPixels: true))
            XCTAssertFalse(result.trace.executed.contains(.pointColour),
                           "no sample or no adjustment means no S3.6b pass")
            XCTAssertEqual(try XCTUnwrap(result.display).sha256(), neutral.sha256(),
                           "the frame must be the pre-140 frame byte for byte")
            let dims = ImageSize(width: image.width, height: image.height)
            let links = RenderKeyChain.links(identity: "140-neutral", sourceSize: dims,
                                             canvas: dims, content: dims,
                                             edit: edit, display: DisplayOptions())
            XCTAssertNil(links.pointColour, "no point link without a sampled-and-adjusted point")
            XCTAssertEqual(links.pipeline, RenderStage.allCases)
        }

        // The active document is the other half: one extra pass, one extra link, and the stage sits
        // between S3.6 and S3.8.
        let active = document(hue: 100)
        let result = try graph.render(active, options: RenderOptions(scale: 1, useCache: false,
                                                                     wantsPixels: true))
        XCTAssertTrue(result.trace.executed.contains(.pointColour))
        XCTAssertNotNil(result.keys.pointColour)
        let order = RenderStage.order
        XCTAssertEqual(order[try XCTUnwrap(order.firstIndex(of: .pointColour)) - 1], .hsl)
        XCTAssertEqual(order[try XCTUnwrap(order.firstIndex(of: .pointColour)) + 1], .grade)
        print("POINT NEUTRAL · trace \(result.trace.csv)")
    }

    // MARK: - ⑤ the key contains the window

    func testKeyContainsTheWindow() throws {
        let dims = ImageSize(width: 64, height: 64)
        func link(_ point: PointColor) -> (link: String, material: String) {
            var edit = EditModel.neutral
            edit.color.point = point
            let links = RenderKeyChain.links(identity: "140-key", sourceSize: dims,
                                             canvas: dims, content: dims,
                                             edit: edit, display: DisplayOptions())
            return (links.pointColour ?? "", edit.keyMaterial(.pointColour))
        }
        let base = PointColor(sampleHue: 24.78, sampleChroma: 0.08,
                              range: 30, feather: 30, hue: 100)
        let reference = link(base)
        XCTAssertFalse(reference.link.isEmpty, "an active point must have a link")
        XCTAssertTrue(reference.material.contains("sampleH=24.78000"), reference.material)
        XCTAssertTrue(reference.material.contains("sampleC=0.08000"), reference.material)
        XCTAssertTrue(reference.material.contains("range=30.00000"), reference.material)
        XCTAssertTrue(reference.material.contains("feather=30.00000"), reference.material)

        // Each of the four window numbers must miss the cache **on its own**.
        var hue = base; hue.sampleHue += 1
        var chroma = base; chroma.sampleChroma += 0.01
        var range = base; range.range += 1
        var feather = base; feather.feather += 1
        for (name, variant) in [("sampleHue", hue), ("sampleChroma", chroma),
                                ("range", range), ("feather", feather)] {
            let other = link(variant)
            XCTAssertNotEqual(other.link, reference.link, "\(name) moved but the stage key did not")
            XCTAssertNotEqual(other.material, reference.material,
                              "\(name) moved but the material did not")
        }
        print("POINT KEY · \(reference.material)")
    }

    // MARK: - ⑥ the document

    func testSchemaTwelveKeepsOldDocuments() throws {
        var old = EditModel.neutral
        old.schemaVersion = 11
        old.light.exposure = 0.5
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let first = try encoder.encode(old)
        let text = String(decoding: first, as: UTF8.self)
        XCTAssertFalse(text.contains("\"point\""), "a schema-11 document must not grow a point key")
        let reloaded = try JSONDecoder().decode(EditModel.self, from: first)
        XCTAssertEqual(reloaded.schemaVersion, 11, "the additive key must not stamp the version")
        XCTAssertNil(reloaded.color.point)
        XCTAssertEqual(try encoder.encode(reloaded), first, "schema-11 bytes must be identical")

        var sampled = EditModel.neutral
        sampled.color.point = PointColor(sampleHue: 24.78, sampleChroma: 0.08,
                                         range: 30, feather: 30, hue: 100)
        let data = try encoder.encode(sampled)
        let sampledText = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(sampledText.contains("\"point\""))
        XCTAssertEqual(sampled.schemaVersion, EditModel.currentSchemaVersion)
        XCTAssertEqual(EditModel.currentSchemaVersion, 12)
        let back = try JSONDecoder().decode(EditModel.self, from: data)
        XCTAssertEqual(back.color.point, sampled.color.point)
        XCTAssertEqual(try encoder.encode(back), data)
        print("POINT SCHEMA · schema-11 blob → \(first.count) bytes → identical · schema-12 round-trip")
    }

    /// The dropper's two fields are the **only** thing a sample writes, and a sample without an
    /// adjustment does not move a pixel. (The history half of “one click = one row” is
    /// `PointColorPanelTests`.)
    func testSamplingWritesNoPixelsUntilAnAdjustmentExists() throws {
        let image = blocks()
        let graph = try makeGraph(image, identity: "140-sample")
        let neutral = try display(graph, EditModel.neutral)
        var sampled = EditModel.neutral
        sampled.color.point = PointColor(sampleHue: 24.78, sampleChroma: 0.08,
                                         range: 30, feather: 30)
        let result = try graph.render(sampled, options: RenderOptions(scale: 1, useCache: false,
                                                                      wantsPixels: true))
        XCTAssertFalse(result.trace.executed.contains(.pointColour))
        XCTAssertEqual(try XCTUnwrap(result.display).sha256(), neutral.sha256())
        XCTAssertEqual(sampled.changedStages(from: .neutral), [.pointColour],
                       "a sample is S3.6b's own material, not a band drag")
        print("POINT SAMPLE · sample-only document → no pass, neutral frame sha")
    }

    // MARK: - ⑦ CPU reference vs kernel

    /// The CPU reference is the definition (`PointColor.apply`); the kernel is checked against it on a
    /// 360° wheel so the two cannot drift without a red test.
    func testTheKernelIsTheCPUReference() throws {
        let image = wheel(height: 6, L: 0.60, C: 0.08)
        let graph = try makeGraph(image, identity: "140-cpu")
        let point = PointColor(sampleHue: 40, sampleChroma: 0.08,
                               range: 30, feather: 30, hue: 80, saturation: 40, luminance: 20)
        var edit = EditModel.neutral
        edit.color.point = point
        let actual = try display(graph, edit)

        var worst = 0
        var total = 0
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let o = (y * image.width + x) * 4
                let src = SIMD3(Double(image.rgba[o]), Double(image.rgba[o + 1]),
                                Double(image.rgba[o + 2]))
                let working = Self.toWorking.applying(to: src)
                let out = point.apply(working)
                let srgb = Self.toSRGB.applying(to: out)
                func encode(_ v: Double) -> Int {
                    let c = min(max(v, 0), 1)
                    let e = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
                    return Int((e * 255).rounded())
                }
                for c in 0..<3 {
                    let expected = encode(c == 0 ? srgb.x : (c == 1 ? srgb.y : srgb.z))
                    let got = Self.code(actual.rgba[o + c])
                    worst = max(worst, abs(expected - got))
                    total += abs(expected - got)
                    count += 1
                }
            }
        }
        print("POINT CPU↔GPU · max |Δcode| \(worst), mean "
              + String(format: "%.3f", Double(total) / Double(count)) + " over \(count) channels")
        XCTAssertLessThanOrEqual(worst, 2, "the kernel must be the CPU reference, not a lookalike")
    }
}
