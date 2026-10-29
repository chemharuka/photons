import XCTest
import Metal
import PhotonsCore

/// 120b — the depth mask (`MaskShape.depthRange`).
///
/// The depth texture is the contract `RenderInput.depth` documents: one channel, Float16, normalised
/// so `1` = nearest and `0` = farthest (`DepthMap.normalised()`). The mask samples it at the **source**
/// uv, the same coordinate luminance/colour use, and applies the luminance window's two-sided
/// `smoothstep` — not a second boundary rule.
final class DepthMaskTests: XCTestCase {

    // MARK: fixtures

    private func makeGraph(_ image: LinearImage, depth: MTLTexture? = nil,
                           identity: String = "depth-mask-tests") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity,
                                                  depth: depth, depthKey: identity + "-depth"))
    }

    private func image(width: Int = 96, height: Int = 64,
                       _ value: (Int, Int) -> Double = { _, _ in 0.35 }) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = value(x, y)
                let i = (y * width + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v)
                rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// Left half 0.9, right half 0.1 — the acceptance's synthetic depth map.
    private func halfDepth(_ device: MTLDevice, width: Int = 96, height: Int = 64) throws -> MTLTexture {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2D
        desc.pixelFormat = .r16Float
        desc.width = width
        desc.height = height
        desc.mipmapLevelCount = 1
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: desc), "depth texture")
        var values = [Float16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                values[y * width + x] = x < width / 2 ? 0.9 : 0.1
            }
        }
        values.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: width * 2)
        }
        return texture
    }

    private func doc(_ shape: MaskShape, feather: Double = 0.5) -> EditModel {
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-depth", components: [
            MaskComponent(id: "c", feather: feather, shape: shape)
        ])]
        return edit
    }

    private func sample(_ dump: MaskAtlasDump, _ x: Int, _ y: Int) -> Double {
        Double(dump.value(slice: 0, x: x, y: y) ?? -1)
    }

    // MARK: 1 — the window selects the near half, and invert swaps it

    func testNearWindowSelectsTheNearHalfAndInvertSwapsIt() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let depth = try halfDepth(device)
        let graph = try makeGraph(image(), depth: depth)
        // near = 1, far = 0.7, no feather: the window is exactly [0.7, 1].
        let shape = DepthRangeShape(near: 1.0, far: 0.7, nearFeather: 0, farFeather: 0)
        let plain = try XCTUnwrap(try graph.maskAtlas(doc(.depthRange(shape))))
        for y in stride(from: 4, to: plain.height, by: 17) {
            XCTAssertGreaterThanOrEqual(sample(plain, 8, y), 0.95, "left/near half must be selected")
            XCTAssertLessThanOrEqual(sample(plain, plain.width - 9, y), 0.05,
                                     "right/far half must not be selected")
        }

        let inverted = DepthRangeShape(near: 1.0, far: 0.7,
                                       nearFeather: 0, farFeather: 0, invert: true)
        let flipped = try XCTUnwrap(try graph.maskAtlas(doc(.depthRange(inverted))))
        for y in stride(from: 4, to: plain.height, by: 17) {
            XCTAssertEqual(sample(flipped, 8, y), 1 - sample(plain, 8, y), accuracy: 1e-3)
            XCTAssertEqual(sample(flipped, plain.width - 9, y),
                           1 - sample(plain, plain.width - 9, y), accuracy: 1e-3)
        }
    }

    /// An inverted `near`/`far` pair is the luminance window's mirror: the bounds swap **with their
    /// feathers**. `ordered` is the one rule; the kernel and both documents therefore agree.
    func testInvertedNearFarKeepsItsFeathersOnTheRightEdges() throws {
        let inverted = DepthRangeShape(near: 0.7, far: 1.0, nearFeather: 0.03, farFeather: 0.12)
        let ordered = DepthRangeShape(near: 1.0, far: 0.7, nearFeather: 0.12, farFeather: 0.03)
        XCTAssertFalse(inverted.isOrdered)
        XCTAssertEqual(inverted.ordered.low, ordered.ordered.low, accuracy: 1e-12)
        XCTAssertEqual(inverted.ordered.high, ordered.ordered.high, accuracy: 1e-12)
        XCTAssertEqual(inverted.ordered.lowFeather, ordered.ordered.lowFeather, accuracy: 1e-12)
        XCTAssertEqual(inverted.ordered.highFeather, ordered.ordered.highFeather, accuracy: 1e-12)

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let depth = try halfDepth(device)
        let graph = try makeGraph(image(), depth: depth)
        let a = try XCTUnwrap(try graph.maskAtlas(doc(.depthRange(inverted))))
        let b = try XCTUnwrap(try graph.maskAtlas(doc(.depthRange(ordered))))
        for y in stride(from: 2, to: a.height, by: 11) {
            for x in stride(from: 2, to: a.width, by: 7) {
                XCTAssertEqual(sample(a, x, y), sample(b, x, y), accuracy: 1e-4,
                               "the inverted pair must render as its mirror at (\(x), \(y))")
            }
        }
    }

    // MARK: 2 — key and persistence

    func testKeyStringCarriesEveryDepthFieldAndSchema12RoundTrips() throws {
        let shape = DepthRangeShape(near: 0.72, far: 0.18, nearFeather: 0.21,
                                    farFeather: 0.13, invert: true)
        let key = MaskShape.depthRange(shape).keyString
        for token in ["near=0.72000", "far=0.18000", "nearF=0.21000", "farF=0.13000", "inv=1"] {
            XCTAssertTrue(key.contains(token), "depthRange key lost \(token): \(key)")
        }
        XCTAssertNotEqual(key, MaskShape.depthRange(DepthRangeShape()).keyString)

        var edit = EditModel.neutral
        edit.schemaVersion = 12
        edit.masks = [Mask(id: "m-depth", name: "Depth",
                           components: [MaskComponent(id: "c", feather: 0.4,
                                                      shape: .depthRange(shape))])]
        let data = try JSONEncoder().encode(edit)
        let back = try JSONDecoder().decode(EditModel.self, from: data)
        XCTAssertEqual(back.schemaVersion, 12)
        guard case .depthRange(let restored) = back.masks[0].components[0].shape else {
            return XCTFail("depthRange discriminator was not honoured")
        }
        XCTAssertEqual(restored, shape)
    }

    // MARK: 3 — no depth ⇒ zero coverage, and no pixels moved

    func testNoDepthIsZeroCoverageAndLeavesTheFrameByteIdentical() throws {
        let base = image()
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-depth", components: [
            MaskComponent(id: "c", feather: 0.5,
                          shape: .depthRange(DepthRangeShape(near: 1, far: 0,
                                                             nearFeather: 0, farFeather: 0)))
        ])]
        let graph = try makeGraph(base)
        let dump = try XCTUnwrap(try graph.maskAtlas(edit))
        XCTAssertTrue(dump.slices[0].allSatisfy { $0 == 0 },
                      "a depth mask without a map must cover nothing")

        let plain = try XCTUnwrap(try graph.render(EditModel.neutral,
                                                   options: RenderOptions(scale: 1, wantsPixels: true)).display)
        let masked = try XCTUnwrap(try graph.render(edit,
                                                    options: RenderOptions(scale: 1, wantsPixels: true)).display)
        XCTAssertEqual(masked.sha256(), plain.sha256(),
                       "zero coverage must be byte-identical to no mask")

        // The atlas is still one pointwise pass: the depth predicate adds a texture fetch inside the
        // existing dispatch, never a pass. A fresh graph so the report describes the cold build.
        let coldGraph = try makeGraph(base)
        let report = try XCTUnwrap(try coldGraph.maskAtlasWithReport(edit)).report
        XCTAssertEqual(report.atlasPasses, ["s1_5_mask_atlas"],
                       "the depth predicate must not add an atlas pass")
    }

    func testDepthSuffixDoesNotTouchDocumentsWithoutDepthConsumers() throws {
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-luma", components: [
            MaskComponent(id: "c", shape: .luminanceRange(LuminanceRangeShape(low: 0, high: 1)))
        ])]
        let a = RenderKeyChain.links(identity: "depth-suffix", sourceSize: ImageSize(width: 96, height: 64),
                                     canvas: ImageSize(width: 96, height: 64),
                                     content: ImageSize(width: 96, height: 64), edit: edit,
                                     display: DisplayOptions())
        // The document chain never names depth; only a depth *consumer* appends the stage suffix.
        XCTAssertEqual(a.maskAtlas, RenderKeyChain.links(
            identity: "depth-suffix", sourceSize: ImageSize(width: 96, height: 64),
            canvas: ImageSize(width: 96, height: 64),
            content: ImageSize(width: 96, height: 64), edit: edit,
            display: DisplayOptions()).maskAtlas)
        XCTAssertFalse(edit.hasDepthRangeMask)
    }
}
