import XCTest
import Metal
import simd
import PhotonsCore

/// 285 — the acceptance scenarios that need a real S3.6b pass:
///
///   1. **Isolation** — samples A/B 15° apart; changing B's h/s/l by +40 leaves A's centre at
///      ΔE00 < 0.5 (158's YUV box moved it noticeably).
///   2. **CPU = kernel** — the host reference and the Metal kernel on the same random OKLCh inputs,
///      including an overlapping pair, stay under ΔE00 0.05.
///   3. **Order** — swapping the swatch array leaves the rendered overlap pixel unchanged.
final class PointColorIsolationTests: XCTestCase {

    // MARK: - fixtures

    private static let toWorking = ColorPrimaries.conversion(from: .decoded, to: .working)
    private static let toSRGB = ColorPrimaries.conversion(from: .working, to: .sRGB)

    private func picture(_ width: Int, _ height: Int, identity: String,
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
                           decoderVersion: "synthetic-285")
    }

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func display(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let result = try graph.render(edit, options: RenderOptions(scale: 1, display: DisplayOptions(),
                                                                   useCache: false, wantsPixels: true))
        return try XCTUnwrap(result.display)
    }

    private static func decoded(L: Double, C: Double, hue: Double) -> SIMD3<Double> {
        toSRGB.applying(to: OKLCh.toLinear(L: L, C: C, hue: hue))
    }

    /// Sample a display-linear (decoded) colour, the same way the dropper's pre-256 path did.
    private func swatch(_ rgb: SIMD3<Double>) -> PointColor {
        let yuv = PointColor.sampleYUV(fromDecodedLinear: RGBSample(r: rgb.x, g: rgb.y, b: rgb.z))
        return PointColor(sampleY: yuv.x, sampleU: yuv.y, sampleV: yuv.z)
    }

    private static func encoded(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let srgb = toSRGB.applying(to: rgb)
        func encode(_ v: Double) -> Double {
            let c = min(max(v, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return SIMD3(encode(srgb.x), encode(srgb.y), encode(srgb.z))
    }

    private static func displayEncoded(_ img: DisplayImage, x: Int, y: Int) -> SIMD3<Double> {
        let o = (y * img.width + x) * 4
        return SIMD3(Double(img.rgba[o]), Double(img.rgba[o + 1]), Double(img.rgba[o + 2]))
    }

    private static func linearPixel(_ texture: MTLTexture, x: Int, y: Int) -> SIMD3<Double> {
        var raw = [UInt16](repeating: 0, count: 4)
        raw.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!,
                             bytesPerRow: 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        func channel(_ i: Int) -> Double { Double(Float16(bitPattern: raw[i])) }
        return SIMD3(channel(0), channel(1), channel(2))
    }

    /// Linear working primaries → encoded sRGB, the display transform's own curve.
    private static func encodeLinear(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        encoded(rgb)
    }

    // MARK: - 1. the user's 15° scenario

    func testChangingOneSampleByFortyLeavesTheOtherSamplesCentreAlone() throws {
        // Two materials at the same L and C, 15° apart — the user's smallest "two different colours".
        let aRGB = Self.decoded(L: 0.62, C: 0.10, hue: 30)
        let bRGB = Self.decoded(L: 0.62, C: 0.10, hue: 45)
        let image = picture(60, 20, identity: "285-isolation") { x, _ in
            let c = x < 30 ? aRGB : bRGB
            return (c.x, c.y, c.z)
        }
        let graph = try makeGraph(image, identity: "285-isolation")
        let neutral = try display(graph, EditModel.neutral)

        let a = swatch(aRGB)
        var b = swatch(bRGB)
        b.hue = 40
        b.saturation = 40
        b.luminance = 40

        var edit = EditModel.neutral
        edit.color.point = PointColorSet(swatches: [a, b], active: 1)
        let moved = try display(graph, edit)

        let before = Self.displayEncoded(neutral, x: 15, y: 10)
        let after = Self.displayEncoded(moved, x: 15, y: 10)
        let dE = PointColorDeltaE.deltaE00(before, after)
        XCTAssertLessThan(dE, 0.5, "B's +40 h/s/l must not touch A's centre (ΔE00 \(dE))")

        // The same claim on the host reference, so the reverse gate (putting the YUV box back)
        // fails this test even if it is run without a Metal device.
        let aWorking = OKLCh.toLinear(L: 0.62, C: 0.10, hue: 30)
        let hostOut = PointColorSet(swatches: [a, b], active: 1).apply(aWorking)
        let hostDE = PointColorDeltaE.deltaE00(Self.encoded(aWorking), Self.encoded(hostOut))
        XCTAssertLessThan(hostDE, 0.5, "the host reference must isolate A too (ΔE00 \(hostDE))")

        // Sanity: B itself did move.
        let bMoved = PointColorDeltaE.deltaE00(Self.displayEncoded(neutral, x: 45, y: 10),
                                              Self.displayEncoded(moved, x: 45, y: 10))
        XCTAssertGreaterThan(bMoved, 1.0, "B's own centre must change")
        print(String(format: "285 ISOLATION · Δh=15° · A centre ΔE00 %.4f · B centre ΔE00 %.2f",
                     dE, bMoved))
    }

    func testSwappingTheArrayOrderLeavesTheOverlapPixelAlone() throws {
        let aRGB = Self.decoded(L: 0.62, C: 0.10, hue: 20)
        let bRGB = Self.decoded(L: 0.62, C: 0.10, hue: 26)
        let mid = OKLCh.toLinear(L: 0.62, C: 0.10, hue: 23)
        let midDecoded = Self.toSRGB.applying(to: mid)
        let image = picture(30, 10, identity: "285-order") { _, _ in
            (midDecoded.x, midDecoded.y, midDecoded.z)
        }
        let graph = try makeGraph(image, identity: "285-order")

        var a = swatch(aRGB)
        a.hue = 60; a.saturation = 40; a.luminance = 20
        var b = swatch(bRGB)
        b.hue = -30; b.saturation = -20; b.luminance = -10

        var forward = EditModel.neutral
        forward.color.point = PointColorSet(swatches: [a, b], active: 0)
        var reverse = EditModel.neutral
        reverse.color.point = PointColorSet(swatches: [b, a], active: 0)

        let f = try display(graph, forward)
        let r = try display(graph, reverse)
        let dE = PointColorDeltaE.deltaE00(Self.displayEncoded(f, x: 15, y: 5),
                                          Self.displayEncoded(r, x: 15, y: 5))
        XCTAssertLessThan(dE, 0.05, "input-domain weights + normalisation are order-free")
        print(String(format: "285 ORDER · overlap pixel ΔE00(forward, reverse) = %.6f", dE))
    }

    // MARK: - 2. CPU reference = kernel

    func testTheKernelMatchesTheHostOnRandomOverlappingInputs() throws {
        // Deterministic pseudo-random OKLCh sweep — mid lightness/chroma so the display encode does
        // not amplify a one-ulp difference at black.
        var state: UInt64 = 0x2850_0000_0000_0001
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 11) & 0xFFFF_FFFF) / Double(0xFFFF_FFFF)
        }
        let width = 192
        let image = picture(width, 2, identity: "285-cpu") { _, _ in
            let L = 0.52 + 0.26 * random()
            let C = 0.04 + 0.08 * random()
            let hue = 360 * random()
            let decoded = Self.decoded(L: L, C: C, hue: hue)
            return (min(max(decoded.x, 0), 1),
                    min(max(decoded.y, 0), 1),
                    min(max(decoded.z, 0), 1))
        }
        let graph = try makeGraph(image, identity: "285-cpu")

        // Two overlapping samples (5° apart) so the normalisation branch is exercised too.
        var a = swatch(Self.decoded(L: 0.62, C: 0.10, hue: 20))
        a.hue = 50; a.saturation = 30; a.luminance = 10
        var b = swatch(Self.decoded(L: 0.62, C: 0.10, hue: 25))
        b.hue = -30; b.saturation = -15; b.luminance = -5
        let set = PointColorSet(swatches: [a, b], active: 0)

        var edit = EditModel.neutral
        edit.color.point = set
        // Read S3.6b's own output texture (linear working, Float16) rather than the S4 display
        // image: this pins the arithmetic, not the display transform on top of it.
        let result = try graph.render(edit, options: RenderOptions(scale: 1, display: DisplayOptions(),
                                                                   useCache: false, wantsPixels: false,
                                                                   stopBefore: .grade))
        let actual = try XCTUnwrap(result.output)

        var worst = 0.0
        var worstDetail = ""
        var sum = 0.0
        var count = 0
        for y in 0..<image.height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let source = SIMD3(Double(image.rgba[o]), Double(image.rgba[o + 1]),
                                   Double(image.rgba[o + 2]))
                let working = Self.toWorking.applying(to: source)
                // The host is the double-precision reference; the kernel's texture is Float16, so the
                // only residue is half an ulp of that storage — not a second arithmetic.
                let host = set.apply(working)
                let expected = Self.encodeLinear(host)
                let got = Self.encodeLinear(Self.linearPixel(actual, x: x, y: y))
                let dE = PointColorDeltaE.deltaE00(expected, got)
                if dE > worst {
                    worst = dE
                    worstDetail = "x \(x): host \(host) gpu \(Self.linearPixel(actual, x: x, y: y))"
                }
                sum += dE
                count += 1
            }
        }
        print(String(format: "285 CPU↔KERNEL · %d px · max ΔE00 %.5f · mean %.6f · %@",
                     count, worst, sum / Double(count), worstDetail))
        XCTAssertLessThan(worst, 0.05, "the kernel must be the host reference, not a lookalike")
    }
}
