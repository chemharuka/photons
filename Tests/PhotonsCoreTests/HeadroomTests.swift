import XCTest
import PhotonsCore
import Metal

/// M3 EDR contract (`DisplayOptions.headroom`, default 1, part of `keyString`;
/// docs/architecture-decisions.md §11.8).
///
/// The point of the test is that headroom is a *shape* fixed now, not a display feature: S4 must
/// stop clamping at 1 so a later EDR switch is one boolean plus one number. A synthetic image keeps
/// the test independent of any display, GPU capability beyond Metal, or RAW fixture.
final class HeadroomTests: XCTestCase {

    /// 8 columns spanning SDR and above-unity values, repeated down the rows.
    private func syntheticImage() -> LinearImage {
        let values: [Float] = [0.05, 0.18, 0.5, 0.9, 1.0, 1.5, 2.5, 3.5]
        let width = values.count * 4, height = 8
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = values[x / 4]
                let o = (y * width + x) * 4
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v); rgba[o + 2] = Float16(v); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func render(headroom: Double) throws -> DisplayImage {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let image = syntheticImage()
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "headroom-test"))
        let result = try graph.render(.neutral, options: RenderOptions(
            canvas: nil, scale: 1, display: DisplayOptions(headroom: headroom),
            useCache: false, wantsPixels: true))
        return try XCTUnwrap(result.display)
    }

    /// sRGB OETF as the kernel applies it, so the expectations below are derived, not pasted.
    private func encode(_ v: Float) -> Float {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    private func component(_ pixels: DisplayImage, column: Int, row: Int = 0, channel: Int = 0) -> Float {
        Float(pixels.rgba[(row * pixels.width + column) * 4 + channel])
    }

    /// headroom = 1 must be the old behaviour: values above unity clamp to exactly 1.0.
    func testHeadroomOneClampsLikeTheOldDisplayStage() throws {
        let pixels = try render(headroom: 1)
        XCTAssertEqual(pixels.width, 32)
        for i in stride(from: 0, to: pixels.rgba.count, by: 4) {
            for c in 0..<3 {
                XCTAssertLessThanOrEqual(Float(pixels.rgba[i + c]), 1.0 + 1e-6)
            }
        }
        // Columns 16…31 carry 1.0 / 1.5 / 2.5 / 3.5: all four sit at the ceiling.
        // One half-ulp of slack: the store rounds `1.055 - 0.055 = 0.99999994` down to the largest
        // half below 1, which is 0.99951172 (measured; also why goldens read 0.9995…).
        for column in 16..<32 {
            XCTAssertEqual(component(pixels, column: column), 1.0, accuracy: 1e-3)
            XCTAssertLessThanOrEqual(component(pixels, column: column), 1.0 + 1e-6)
        }
        XCTAssertEqual(component(pixels, column: 12), encode(0.9), accuracy: 1e-3)  // columns 12…15 = 0.9
    }

    /// headroom = 4 must keep > 1: that is the whole contract. Encoded sRGB is monotone above 1.
    func testHeadroomFourPreservesValuesAboveUnity() throws {
        let pixels = try render(headroom: 4)
        for (column, linear) in [(20, Float(1.5)), (24, 2.5), (28, 3.5)] {
            let got = component(pixels, column: column)
            XCTAssertGreaterThan(got, 1.0, "headroom = 4 lost the >1 sample (value \(linear))")
            XCTAssertEqual(got, encode(linear), accuracy: 0.01, "sRGB encoding above unity changed")
        }
        // Nothing may exceed what headroom = 4 itself encodes to.
        let ceiling = encode(4)
        for i in stride(from: 0, to: pixels.rgba.count, by: 4) {
            XCTAssertLessThanOrEqual(Float(pixels.rgba[i + 2]), ceiling + 1e-3)
        }
    }

    /// SDR pixels must be untouched by the headroom: same pixels, different ceiling.
    func testHeadroomDoesNotChangePixelsBelowUnity() throws {
        let one = try render(headroom: 1)
        let four = try render(headroom: 4)
        for i in stride(from: 0, to: one.rgba.count, by: 4) {
            guard Float(one.rgba[i]) < 0.999 else { continue }   // skip the clamped groups
            for c in 0..<3 {
                XCTAssertEqual(one.rgba[i + c], four.rgba[i + c],
                               "headroom changed an SDR sample at index \(i + c)")
            }
        }
    }

    /// The key must move with the headroom, or the stage cache hands back SDR pixels for an EDR
    /// request (D6: a key that misses a pixel-affecting input is a dirty cache).
    func testHeadroomParticipatesInTheCacheKey() {
        XCTAssertNotEqual(DisplayOptions().keyString, DisplayOptions(headroom: 4).keyString)
        XCTAssertEqual(DisplayOptions(headroom: 1).keyString, DisplayOptions(headroom: 1.0).keyString)
        XCTAssertEqual(DisplayOptions().headroom, 1, "SDR must be the default")
    }
}
