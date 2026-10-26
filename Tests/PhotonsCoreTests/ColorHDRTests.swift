import XCTest
import Metal
import PhotonsCore

/// **HDR survives the colour stage.**
///
/// The report was concrete: "动了自然饱和/饱和度就失去 HDR"。 `s3_color` used to enter HSL with
/// `clamp(c.rgb, 0, 1)` and come back through `hsl_to_rgb`, whose `l` is clamped to 1 — so any pixel
/// above white was flattened to 1.0 (i.e. 编码后的 SDR 白) the moment vibrance or saturation moved.
/// The panel's own preview then lost its EDR range while the neutral frame still had it.
///
/// The fix carries the headroom *around* the HSL maths: `n = c / max(1, max(c))` goes through HSL
/// (all clamps are on the normalised values) and the result is multiplied back by the same factor.
/// An SDR pixel has a factor of exactly 1, so nothing that used to be right moves.
///
/// These are synthetic images, so the numbers are reproducible without a RAW fixture.
final class ColorHDRTests: XCTestCase {

    private func makeGraph(_ image: LinearImage) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: "color-hdr-test"))
    }

    /// `width × height`, every pixel the same linear RGB.
    private func solid(_ rgb: (Float, Float, Float), width: Int = 32, height: Int = 32) -> LinearImage {
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

    /// Largest RGB component of the rendered picture (display-encoded, so > 1 means real headroom).
    private func maxChannel(_ img: DisplayImage) -> Float {
        var m: Float = 0
        for y in 0..<img.height {
            for x in 0..<img.width {
                let o = (y * img.width + x) * 4
                m = max(m, max(Float(img.rgba[o]), max(Float(img.rgba[o + 1]), Float(img.rgba[o + 2]))))
            }
        }
        return m
    }

    /// `headroom` is the display's EDR ceiling (`DisplayOptions.headroom`): S4 encodes up to it, so
    /// an HDR measurement needs headroom > 1 or every value is clamped to SDR white by S4 itself —
    /// which is exactly the confusion that hid this bug (S4 clamps, S3 must not).
    private func render(_ graph: RenderGraph, vibrance: Double = 0, saturation: Double = 0,
                        canvas: ImageSize? = nil, headroom: Double = 4) throws -> DisplayImage {
        var edit = EditModel.neutral
        edit.color.vibrance = vibrance
        edit.color.saturation = saturation
        let opts = RenderOptions(canvas: canvas, scale: 1,
                                 display: DisplayOptions(headroom: headroom), wantsPixels: true)
        return try XCTUnwrap(graph.render(edit, options: opts).display)
    }

    // MARK: - 1. the headroom is still there after a colour slider

    /// A 4× white pixel: saturation and vibrance must both leave it above SDR white. The old code
    /// returned exactly the SDR white here (encoded 1.0), which is what "失去 HDR" looked like.
    func testAnHDRHighlightStaysAboveWhiteWhenSaturationMoves() throws {
        let graph = try makeGraph(solid((4.0, 4.0, 4.0)))
        let neutral = try render(graph)
        let saturated = try render(graph, saturation: 100)
        let desaturated = try render(graph, saturation: -100)
        let vibrant = try render(graph, vibrance: 100)

        print(String(format: "HDR grey 4.0 → encoded max: neutral %.4f · sat+100 %.4f · sat−100 %.4f · vib+100 %.4f",
                     maxChannel(neutral), maxChannel(saturated),
                     maxChannel(desaturated), maxChannel(vibrant)))

        XCTAssertGreaterThan(maxChannel(neutral), 1.05, "the fixture must actually be HDR")
        for (name, img) in [("saturation +100", saturated),
                            ("saturation −100", desaturated),
                            ("vibrance +100", vibrant)] {
            XCTAssertGreaterThan(maxChannel(img), 1.05,
                                 "\(name) flattened the highlight to SDR white (encoded max "
                                 + "\(maxChannel(img))) — headroom must survive the colour stage")
            XCTAssertEqual(maxChannel(img), maxChannel(neutral), accuracy: 0.01,
                           "\(name): a neutral grey cannot change value under a chroma operation")
        }
    }

    /// A coloured HDR pixel (2, 1, 0.5): the brightest channel must keep its headroom even though
    /// saturation reshapes the chroma, and the boost must actually do something — normalizing an HDR
    /// pixel by its own peak would put HSL saturation at exactly 1 and make `saturation +` a no-op
    /// (that is why the scale targets a normalized peak of 0.9 instead).
    func testAColouredHDRPixelKeepsItsHeadroom() throws {
        let graph = try makeGraph(solid((2.0, 1.0, 0.5)))
        let neutral = try render(graph)
        let saturated = try render(graph, saturation: 100)
        print(String(format: "HDR (2,1,0.5) → encoded max: neutral %.4f · sat+100 %.4f",
                     maxChannel(neutral), maxChannel(saturated)))
        XCTAssertGreaterThan(maxChannel(neutral), 1.05)
        XCTAssertGreaterThan(maxChannel(saturated), 1.0,
                             "saturation clipped the highlight back to SDR white")
        // A saturation boost may legitimately push the brightest channel a little (more chroma at the
        // same HSL lightness), but it must not *collapse* it to white — the old clamp did exactly that.
        XCTAssertGreaterThan(maxChannel(saturated), maxChannel(neutral) * 1.02,
                             "saturation did nothing on an HDR pixel (HSL saturation pinned at 1)")
        XCTAssertLessThan(maxChannel(saturated), maxChannel(neutral) * 1.25,
                          "a chroma boost should not double the highlight")
    }

    // MARK: - 2. SDR is untouched, and the matte is still exactly zero

    /// The normalisation factor is 1 for every SDR pixel, so a sub-white picture must still come out
    /// of the colour stage without being pushed past white by a saturation boost.
    func testAnSDRPictureIsNotPushedPastWhite() throws {
        let graph = try makeGraph(solid((0.8, 0.4, 0.2)))
        let neutral = try render(graph, headroom: 1)
        let saturated = try render(graph, saturation: 100, headroom: 1)
        print(String(format: "SDR (0.8,0.4,0.2) → encoded max: neutral %.4f · sat+100 %.4f",
                     maxChannel(neutral), maxChannel(saturated)))
        XCTAssertLessThanOrEqual(maxChannel(neutral), 1.0 + 1e-3)
        XCTAssertLessThanOrEqual(maxChannel(saturated), 1.0 + 1e-3,
                                 "a saturation boost must not invent headroom on an SDR pixel")
    }

    /// Same guarantee as S2/S3a/S3c: the letterbox bars stay **exactly** 0 while a colour slider moves.
    func testTheMatteStaysExactlyZeroWhileSaturationMoves() throws {
        let graph = try makeGraph(solid((4.0, 2.0, 1.0), width: 540, height: 360))
        let canvas = ImageSize(width: 640, height: 360)
        for saturation in [-100.0, 100.0] {
            let img = try render(graph, saturation: saturation, canvas: canvas)
            let rectX = (640 - 540) / 2
            var matteMax: Float = 0
            var barPixels = 0
            for y in 0..<img.height {
                for x in 0..<img.width where x < rectX || x >= rectX + 540 {
                    let o = (y * img.width + x) * 4
                    matteMax = max(matteMax, max(Float(img.rgba[o]),
                                                 max(Float(img.rgba[o + 1]), Float(img.rgba[o + 2]))))
                    barPixels += 1
                }
            }
            XCTAssertGreaterThan(barPixels, 0, "the fixture must actually be letterboxed")
            XCTAssertEqual(matteMax, 0, "saturation \(saturation): the bars must stay exactly 0")
        }
    }
}
