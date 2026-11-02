import XCTest
import Metal
import simd
import PhotonsCore

/// 256 — the point-colour probe: **S3.6b's input**, one pixel, no whole-frame render.
///
/// The probe is a 1 × 1 window render that stops before `.pointColour`. These tests pin the three
/// things that make it the right sample rather than a new one:
///
///   1. **Order**: `.pointColour` is immediately after `.hsl` in `RenderStage.order`.
///   2. **Same pixel**: the 1 × 1 probe equals the same texel of a whole-frame render to that cutoff.
///   3. **Same domain**: the value is working-primaries linear light after S3.6 (HSL and exposure are
///      in it), and a neutral pixel is below the YCbCr chroma floor.
final class PointColorProbeTests: XCTestCase {

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func picture(_ width: Int, _ height: Int, identity: String = "point-probe",
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
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-256")
    }

    private static let toDecoded = ColorPrimaries.conversion(from: .working, to: .sRGB)

    /// A working-primaries OKLCh colour, written into the decoded buffer the graph expects.
    private static func decodedPixel(L: Double, C: Double, hue: Double) -> (Double, Double, Double) {
        let rgb = toDecoded.applying(to: OKLCh.toLinear(L: L, C: C, hue: hue))
        return (rgb.x, rgb.y, rgb.z)
    }

    /// Four quadrants: TL red (OKLCh hue 0), TR green (140°), BL blue (260°), BR neutral.
    private func quadrants(side: Int = 64) -> LinearImage {
        picture(side, side, identity: "point-probe-quadrants") { x, y in
            switch (x < side / 2, y < side / 2) {
            case (true, true): return Self.decodedPixel(L: 0.62, C: 0.18, hue: 0)
            case (false, true): return Self.decodedPixel(L: 0.62, C: 0.18, hue: 140)
            case (true, false): return Self.decodedPixel(L: 0.58, C: 0.16, hue: 260)
            case (false, false): return (0.5, 0.5, 0.5)
            }
        }
    }

    private static func pixel(_ texture: MTLTexture, x: Int, y: Int) -> RGBSample {
        var raw = [UInt16](repeating: 0, count: 4)
        raw.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!,
                             bytesPerRow: 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        func channel(_ i: Int) -> Double { Double(Float16(bitPattern: raw[i])) }
        return RGBSample(r: channel(0), g: channel(1), b: channel(2))
    }

    private func wholeFrameInput(_ graph: RenderGraph, _ edit: EditModel,
                                 width: Int, height: Int) throws -> (MTLTexture, RGBSample) {
        let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                   wantsPixels: false,
                                                                   stopBefore: .pointColour))
        let texture = try XCTUnwrap(result.output)
        return (texture, Self.pixel(texture, x: width / 4, y: height / 4))
    }

    // MARK: - 1. the order pin

    func testPointColourRunsImmediatelyAfterHSL() throws {
        let order = RenderStage.order
        let hsl = try XCTUnwrap(order.firstIndex(of: .hsl))
        let point = try XCTUnwrap(order.firstIndex(of: .pointColour))
        XCTAssertEqual(point, hsl + 1,
                       "S3.6b must stay directly after S3.6: \(order.map(\.rawValue))")
        XCTAssertLessThan(point, try XCTUnwrap(order.firstIndex(of: .grade)))
        print("POINT ORDER · \(order[point - 1].short) → \(order[point].short)")
    }

    // MARK: - 2. the probe equals the whole frame's pixel

    func testTheOnePixelProbeMatchesTheWholeFrameAtTheSamePixel() throws {
        let side = 64
        let image = quadrants(side: side)
        let graph = try makeGraph(image, identity: "point-probe-match")
        var edit = EditModel.neutral
        edit.light.exposure = 1
        edit.color.global.hue = 100     // S3.6 must be in the sample
        let (whole, expected) = try wholeFrameInput(graph, edit, width: side, height: side)
        defer { graph.recycle(output: whole) }

        let probed = try XCTUnwrap(graph.samplePointColorInput(
            edit, contentPixel: (x: side / 4, y: side / 4), scale: 1))
        print(String(format: "POINT PROBE · whole %@ · probe %@", expected.text, probed.text))
        XCTAssertEqual(probed.r, expected.r, accuracy: 2e-3)
        XCTAssertEqual(probed.g, expected.g, accuracy: 2e-3)
        XCTAssertEqual(probed.b, expected.b, accuracy: 2e-3)
    }

    func testTheProbeIsDeterministic() throws {
        let graph = try makeGraph(quadrants(), identity: "point-probe-deterministic")
        var edit = EditModel.neutral
        edit.light.exposure = 0.75
        let first = try XCTUnwrap(graph.samplePointColorInput(
            edit, contentPixel: (x: 16, y: 16), scale: 1))
        let second = try XCTUnwrap(graph.samplePointColorInput(
            edit, contentPixel: (x: 16, y: 16), scale: 1))
        XCTAssertEqual(first, second, "same document, same pixel ⇒ same bytes")
    }

    // MARK: - 3. the domain and the pale guard

    func testQuadrantsSampleTheColoursTheScreenShows() throws {
        let side = 64
        let graph = try makeGraph(quadrants(side: side), identity: "point-probe-quadrants")
        let red = try XCTUnwrap(graph.samplePointColorInput(
            EditModel.neutral, contentPixel: (x: 16, y: 16), scale: 1))
        let yuv = PointColor.sampleYUV(fromWorkingLinear: red)
        let swatch = PointColor(sampleY: yuv.x, sampleU: yuv.y, sampleV: yuv.z)
        print(String(format: "POINT QUADRANT · red H %.2f° C %.3f",
                     swatch.sampleHue, swatch.sampleChroma))
        var redDelta = swatch.sampleHue.truncatingRemainder(dividingBy: 360)
        if redDelta > 180 { redDelta -= 360 }
        if redDelta < -180 { redDelta += 360 }
        XCTAssertEqual(redDelta, 0, accuracy: 10,
                       "TL red must sample in the red hue window")
        XCTAssertGreaterThan(swatch.sampleChroma, PointColor.chromaFloorYCbCr)

        let white = try XCTUnwrap(graph.samplePointColorInput(
            EditModel.neutral, contentPixel: (x: 48, y: 48), scale: 1))
        let whiteYUV = PointColor.sampleYUV(fromWorkingLinear: white)
        let whiteSwatch = PointColor(sampleY: whiteYUV.x, sampleU: whiteYUV.y,
                                     sampleV: whiteYUV.z)
        XCTAssertFalse(whiteSwatch.isSampled, "BR white is below the chroma floor")
        XCTAssertLessThan(whiteSwatch.sampleChromaYCbCr, PointColor.chromaFloorYCbCr)
    }

    func testExposureAndHSLMoveTheSample() throws {
        let graph = try makeGraph(quadrants(), identity: "point-probe-edits")
        let base = try XCTUnwrap(graph.samplePointColorInput(
            EditModel.neutral, contentPixel: (x: 16, y: 16), scale: 1))
        var exposed = EditModel.neutral
        exposed.light.exposure = 1
        let brighter = try XCTUnwrap(graph.samplePointColorInput(
            exposed, contentPixel: (x: 16, y: 16), scale: 1))
        func chroma(_ rgb: RGBSample) -> Double {
            let yuv = PointColor.sampleYUV(fromWorkingLinear: rgb)
            return hypot(yuv.y - 0.5, yuv.z - 0.5)
        }
        print(String(format: "POINT EXPOSURE · C %.4f → %.4f",
                     chroma(base), chroma(brighter)))
        XCTAssertNotEqual(chroma(base), chroma(brighter), accuracy: 1e-5,
                          "exposure is upstream of S3.6b and must move the sample")

        var rotated = EditModel.neutral
        rotated.color.global.hue = 100
        let moved = try XCTUnwrap(graph.samplePointColorInput(
            rotated, contentPixel: (x: 16, y: 16), scale: 1))
        func hue(_ rgb: RGBSample) -> Double {
            let yuv = PointColor.sampleYUV(fromWorkingLinear: rgb)
            return PointColor(sampleY: yuv.x, sampleU: yuv.y, sampleV: yuv.z).sampleHue
        }
        var delta = (hue(moved) - hue(base)).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        print(String(format: "POINT HSL · H %.2f° → %.2f° (Δ %.2f°)",
                     hue(base), hue(moved), delta))
        XCTAssertEqual(delta, 30, accuracy: 5, "S3.6's global hue +100 is in the sample")
    }
}
