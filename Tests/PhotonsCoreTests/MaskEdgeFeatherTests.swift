import XCTest
import Metal
@testable import PhotonsCore

/// 215 §6 (user, 2026-11-01): **the feather works along the shape's own boundary, never along the
/// canvas edge.** Pixels outside the frame do not exist, so every read past the border is clamped
/// (replicate) and no extra taper to 0 is stacked on top of the shape's own falloff. Four claims,
/// each printed with its number:
///
///   1. a mask that covers the whole frame is exactly 1.0 on the four border-inside-1-px rings, at
///      component `feather` 0 **and** 1, with and without the mask-level blur;
///   2. a linear gradient's coverage is a function of `t` only: the outermost row and the 10th row in
///      agree to one code at the same `t`;
///   3. the mask-level box blur is edge-clamped: at `feather = 1` a border column and the middle
///      column of a y-only ramp agree to one code (zero padding would darken both edges);
///   4. the shape's support (`MaskBounds.rasterRect`) never cuts the frame when the shape covers it —
///      a box that ended at the frame edge would clip the falloff, and that is *not* a taper to add.
final class MaskEdgeFeatherTests: XCTestCase {

    // MARK: - fixtures

    private func flatImage(_ value: Double = 0.4, width: Int = 96, height: Int = 64) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = Float16(value)
            rgba[i * 4 + 1] = Float16(value)
            rgba[i * 4 + 2] = Float16(value)
            rgba[i * 4 + 3] = 1
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-215")
    }

    private func makeGraph(_ image: LinearImage) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: "mask-edge-215"))
    }

    private func atlas(_ shape: MaskShape, componentFeather: Double, maskFeather: Double,
                       _ image: LinearImage) throws -> MaskAtlasDump {
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-edge", opacity: 1, feather: maskFeather, refine: 0,
                           components: [MaskComponent(id: "c", feather: componentFeather, shape: shape)],
                           adjustments: LocalAdjustments(exposure: 0.5))]
        return try XCTUnwrap(try makeGraph(image).maskAtlas(edit, options: RenderOptions(scale: 1)))
    }

    private func sample(_ dump: MaskAtlasDump, _ x: Int, _ y: Int) -> Double {
        Double(dump.value(slice: 0, x: x, y: y) ?? -1)
    }

    // MARK: - 1. a full-cover mask stays 1.0 right up to the frame

    /// The user's "羽化会应用在画布边缘": whatever the component feather says, a shape that covers the
    /// frame must not lose coverage on a ring near the border. `radial r = 1.5` reaches every corner
    /// (the farthest is 0.90 short edges) and the linear case is past its end line everywhere.
    func testFullCoverMaskIsOneOnEveryBorderRing() throws {
        let image = flatImage()
        let covering: [(String, MaskShape)] = [
            ("radial r=1.5", .radialGradient(RadialGradientShape(center: NormalizedPoint(0.5, 0.5),
                                                                 radius: NormalizedPoint(1.5, 1.5)))),
            ("linear past its end", .linearGradient(LinearGradientShape(
                start: NormalizedPoint(0.5, -0.6), end: NormalizedPoint(0.5, -0.5)))),
        ]
        for (name, shape) in covering {
            for f in [0.0, 1.0] {
                for maskFeather in [0.0, 1.0] {
                    let dump = try atlas(shape, componentFeather: f, maskFeather: maskFeather, image)
                    var worst = 1.0
                    for (x, y) in Self.borderRing(dump.width, dump.height) {
                        worst = min(worst, sample(dump, x, y))
                    }
                    print("215 EDGE full-cover \(name) · component feather \(f) · mask feather "
                          + "\(maskFeather): min on the border-inside-1-px ring = \(worst)")
                    XCTAssertEqual(worst, 1.0, accuracy: 1.0 / 255.0,
                                   "\(name), f = \(f), maskFeather = \(maskFeather): the canvas edge "
                                   + "must not taper a mask that covers the frame")
                }
            }
        }
    }

    /// The four rings one pixel inside the frame, without the corners twice.
    private static func borderRing(_ width: Int, _ height: Int) -> [(Int, Int)] {
        var ring: [(Int, Int)] = []
        for x in [1, width - 2] { for y in 1...(height - 2) { ring.append((x, y)) } }
        for y in [1, height - 2] { for x in 1...(width - 2) { ring.append((x, y)) } }
        return ring
    }

    // MARK: - 2. the ramp is a function of t, not of the row

    /// A horizontal ramp has the same `t` in every row at a given column — so the outermost row and the
    /// 10th row in (top and bottom) must carry the same coverage. A taper added at the canvas edge
    /// would show up here as a difference between them.
    func testLinearCoverageIgnoresTheCanvasEdge() throws {
        let image = flatImage()
        let shape = MaskShape.linearGradient(LinearGradientShape(start: NormalizedPoint(0, 0.5),
                                                                 end: NormalizedPoint(1, 0.5)))
        for f in [0.0, 0.5, 1.0] {
            let dump = try atlas(shape, componentFeather: f, maskFeather: 0, image)
            var worstTop = 0.0, worstBottom = 0.0
            for x in 0..<dump.width {
                worstTop = max(worstTop, abs(sample(dump, x, 0) - sample(dump, x, 10)))
                worstBottom = max(worstBottom, abs(sample(dump, x, dump.height - 1)
                                                   - sample(dump, x, dump.height - 11)))
            }
            print(String(format: "215 EDGE linear f=%.1f · max|row0 − row10| = %.6f · "
                         + "max|rowH−1 − rowH−11| = %.6f", f, worstTop, worstBottom))
            XCTAssertLessThanOrEqual(worstTop, 1.0 / 255.0,
                                     "f = \(f): the top row is tapered against the 10th row at the same t")
            XCTAssertLessThanOrEqual(worstBottom, 1.0 / 255.0,
                                     "f = \(f): the bottom row is tapered against the 10th row at the same t")
        }
    }

    // MARK: - 3. the mask-level blur is edge-clamped

    /// A vertical ramp is constant along x, so every column must carry the same profile — including
    /// the two border columns. With zero padding the blur would pull both edges toward 0, which is the
    /// "feather applied at the canvas edge" the user objects to.
    func testMaskBlurClampsAtTheCanvasEdge() throws {
        let image = flatImage()
        let shape = MaskShape.linearGradient(LinearGradientShape(start: NormalizedPoint(0.5, 0),
                                                                 end: NormalizedPoint(0.5, 1)))
        let dump = try atlas(shape, componentFeather: 0.5, maskFeather: 1, image)
        var worstLeft = 0.0, worstRight = 0.0
        for y in 0..<dump.height {
            worstLeft = max(worstLeft, abs(sample(dump, 0, y) - sample(dump, dump.width / 2, y)))
            worstRight = max(worstRight, abs(sample(dump, dump.width - 1, y)
                                            - sample(dump, dump.width / 2, y)))
        }
        print(String(format: "215 EDGE blur feather=1 · max|col0 − colW/2| = %.6f · "
                     + "max|colW−1 − colW/2| = %.6f", worstLeft, worstRight))
        XCTAssertLessThanOrEqual(worstLeft, 1.0 / 255.0, "the left column was pulled toward 0")
        XCTAssertLessThanOrEqual(worstRight, 1.0 / 255.0, "the right column was pulled toward 0")
    }

    // MARK: - 4. the guided refine upsamples with a clamped sampler

    /// The refine's coefficient upsample is the atlas path's bilinear sampler
    /// (`s1_7_mask_neighbourhood.metal:302`, `address::clamp_to_edge`). A uniform `p = 1` field must
    /// stay 1 everywhere — including the border ring — even when the *guide* varies across the frame,
    /// because a clamped read cannot see a zero outside the canvas.
    func testRefineUpsampleClampsAtTheCanvasEdge() throws {
        // A diagonal picture ramp, so the guide is not constant and the sampler is really exercised.
        var rgba = [Float16](repeating: 0, count: 96 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<96 {
                let v = Float16(0.1 + 0.8 * Double(x + y) / Double(96 + 64))
                let o = (y * 96 + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        let image = LinearImage(width: 96, height: 64, rgba: rgba,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-215")
        let covering = MaskShape.radialGradient(RadialGradientShape(center: NormalizedPoint(0.5, 0.5),
                                                                    radius: NormalizedPoint(1.5, 1.5)))
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-edge", opacity: 1, feather: 0, refine: 1,
                           components: [MaskComponent(id: "c", feather: 1, shape: covering)],
                           adjustments: LocalAdjustments(exposure: 0.5))]
        let dump = try XCTUnwrap(try makeGraph(image).maskAtlas(edit, options: RenderOptions(scale: 1)))
        var worst = 1.0
        for (x, y) in Self.borderRing(dump.width, dump.height) {
            worst = min(worst, sample(dump, x, y))
        }
        print("215 EDGE refine=1 on a varying guide: min on the border-inside-1-px ring = \(worst)")
        XCTAssertEqual(worst, 1.0, accuracy: 1.0 / 255.0,
                       "the refine's clamped upsample must not darken the frame's edge")
    }

    // MARK: - 5. the raster box does not clip the frame

    /// `MaskBounds.rasterRect` is the box the kernel evaluates in: coverage outside it is not computed.
    /// A full-cover shape therefore needs the full canvas at every feather — a box that stopped at the
    /// frame edge would cut the falloff, and it is the box that would be wrong, never the ramp.
    func testRasterBoxIsTheWholeCanvasForAFullCoverShape() throws {
        let image = flatImage()
        let frame = ImageSize(width: image.width, height: image.height)
        let mapping = MaskCanvasMapping(geometry: EditModel.neutral.geometry, source: frame,
                                        content: frame, canvas: frame, origin: (0, 0))
        let full = MaskRect(0, 0, image.width, image.height)
        let covering: [(String, MaskShape)] = [
            ("radial r=1.5", .radialGradient(RadialGradientShape(center: NormalizedPoint(0.5, 0.5),
                                                                 radius: NormalizedPoint(1.5, 1.5)))),
            ("linear past its end", .linearGradient(LinearGradientShape(
                start: NormalizedPoint(0.5, -0.6), end: NormalizedPoint(0.5, -0.5)))),
        ]
        for (name, shape) in covering {
            for f in [0.0, 1.0] {
                let mask = Mask(id: "m-edge", opacity: 1, feather: 0,
                                components: [MaskComponent(id: "c", feather: f, shape: shape)],
                                adjustments: .identity)
                let box = MaskBounds.rasterRect(for: mask, mapping: mapping)
                print("215 EDGE box \(name) f=\(f): \(box.keyString) (canvas "
                      + "\(full.keyString))")
                XCTAssertEqual(box, full, "\(name), f = \(f): the raster box must not clip the frame")
            }
        }
    }
}
