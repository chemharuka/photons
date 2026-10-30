import XCTest
import Metal
@testable import PhotonsCore

/// 159 — B1/B2: a mask's contrast is the global slider inside the mask, and a neutral mask has no
/// second identity path.
final class ContrastLocalTests: XCTestCase {

    private func image(_ value: Float = 0.22, width: Int = 96, height: Int = 65) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let v = value * (0.55 + 0.45 * Float(x) / Float(max(width - 1, 1)))
                rgba[o] = Float16(v)
                rgba[o + 1] = Float16(v * 0.95)
                rgba[o + 2] = Float16(v * 0.9)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func graph(_ img: LinearImage, _ identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: img, identity: identity))
    }

    private func render(_ g: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        var display = DisplayOptions(headroom: 8)
        display.linearOutput = true
        let result = try g.render(edit, options: RenderOptions(scale: 1, display: display,
                                                             useCache: false, wantsPixels: true))
        defer { if let t = result.output { g.recycle(output: t) } }
        return try XCTUnwrap(result.display)
    }

    private func fullCanvasMask(contrast: Double) -> Mask {
        Mask(id: "full", components: [MaskComponent(id: "c1",
            shape: .radialGradient(RadialGradientShape(center: NormalizedPoint(0.5, 0.5),
                                                       radius: NormalizedPoint(10, 10))))],
             adjustments: LocalAdjustments(contrast: contrast))
    }

    private func oetf(_ v: Double) -> Double {
        let x = min(max(v, 0), 1)
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    /// B1 — full-canvas mask `contrast = c` and global `contrast = c` are the same picture.
    func testFullCanvasMaskEqualsTheGlobalSlider() throws {
        let g = try graph(image(), "b1")
        for c in [20.0, 50.0, 100.0] {
            var global = EditModel.neutral
            global.light.contrast = c
            var masked = EditModel.neutral
            masked.masks = [fullCanvasMask(contrast: c)]

            let a = try render(g, global), b = try render(g, masked)
            XCTAssertEqual(a.width, b.width)
            var worst = 0
            for i in 0..<(a.width * a.height) {
                for ch in 0..<3 {
                    let x = Int((oetf(Double(a.rgba[i * 4 + ch])) * 65535).rounded())
                    let y = Int((oetf(Double(b.rgba[i * 4 + ch])) * 65535).rounded())
                    worst = max(worst, abs(x - y))
                }
            }
            XCTAssertLessThanOrEqual(worst, 1,
                "B1 c=\(Int(c)): a full-canvas mask must be the global slider (max Δcode \(worst))")
        }
    }

    /// B2 — a mask whose contrast is 0 is neutral: no second identity path, no rounding.
    func testNeutralMaskContrastIsByteIdenticalToNoMask() throws {
        let g = try graph(image(), "b2")
        var plain = EditModel.neutral
        plain.light.contrast = 0
        var withMask = plain
        withMask.masks = [fullCanvasMask(contrast: 0)]

        XCTAssertFalse(withMask.hasLocalContrast,
                       "a contrast-0 mask must not make S2.5 exist")
        XCTAssertEqual(RenderStage.pipeline(hasMasks: false, hasContrast: false),
                       RenderStage.allCases)
        let a = try render(g, plain), b = try render(g, withMask)
        XCTAssertEqual(a.sha256(), b.sha256(),
                       "a neutral mask must be byte-identical to no mask")
    }
}
