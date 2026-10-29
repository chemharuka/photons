import XCTest
import Metal
import PhotonsCore

/// 120b — the depth-assisted dehaze (`effects.dehazeDepth`).
///
/// The depth map only changes the **distribution** of the veil: far pixels keep the measured `A`/`t`
/// (full correction), near pixels shrink towards no haze (`A → 0`, `t → 1`). 130's hue-preserving
/// luminance recovery and 135's airlight ceiling stay in charge. `depthStrength == 0` takes the
/// pre-120b branch verbatim, so a frame with a depth map and strength 0 is byte-identical to one
/// rendered with no depth at all.
final class DehazeDepthTests: XCTestCase {

    // MARK: fixtures

    private func makeGraph(_ image: LinearImage, depth: MTLTexture?) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: "dehaze-depth-tests",
                                                  depth: depth, depthKey: "depth-fixture"))
    }

    /// Left half = far (0), right half = near (1). The scene is the same on both sides, so the only
    /// difference between the two regions is the depth map.
    private func scene(width: Int = 400, height: Int = 200) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                // A bright band gives the dark-channel prior a real airlight (A ≈ 1); the rest is a
                // dark textured surface under a 0.4 veil. The pattern is identical in both halves.
                let base: Double = y < height / 6 ? 1.0 : 0.12
                let v = base * 0.6 + 0.4
                let i = (y * width + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v)
                rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func halfDepth(_ device: MTLDevice, width: Int = 400, height: Int = 200) throws -> MTLTexture {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2D
        desc.pixelFormat = .r16Float
        desc.width = width
        desc.height = height
        desc.mipmapLevelCount = 1
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: desc))
        var values = [Float16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                values[y * width + x] = x < width / 2 ? 0 : 1
            }
        }
        values.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: width * 2)
        }
        return texture
    }

    private func edit(dehaze: Double, depth: Double) -> EditModel {
        var e = EditModel.neutral
        e.effects.dehaze = dehaze
        e.effects.dehazeDepth = depth
        return e
    }

    private func linearRender(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let display = DisplayOptions(primaries: .rec2020, bitDepth: 16, headroom: 1,
                                     linearOutput: true)
        let result = try graph.render(edit, options: RenderOptions(
            scale: 1, display: display, useCache: false, wantsPixels: true))
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    /// Mean `min(R,G,B)` of one half, away from the seam and the bright estimation band.
    private func darkMean(_ image: DisplayImage, leftHalf: Bool) -> Double {
        let w = image.width
        let x0 = leftHalf ? w / 8 : w / 2 + w / 8
        let x1 = leftHalf ? w / 2 - w / 8 : w - w / 8
        let y0 = image.height / 3
        let y1 = image.height - image.height / 8
        var sum = 0.0
        var n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * w + x) * 4
                sum += Double(min(image.rgba[i], image.rgba[i + 1], image.rgba[i + 2]))
                n += 1
            }
        }
        return sum / Double(max(n, 1))
    }

    // MARK: 4 — far gets the correction, near is left alone

    func testFarDarkensWhileNearIsUnchanged() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let depth = try halfDepth(device)
        let graph = try makeGraph(scene(), depth: depth)
        let off = try linearRender(graph, edit(dehaze: 80, depth: 0))
        let on = try linearRender(graph, edit(dehaze: 80, depth: 100))

        let farOff = darkMean(off, leftHalf: true)
        let farOn = darkMean(on, leftHalf: true)
        let nearOff = darkMean(off, leftHalf: false)
        let nearOn = darkMean(on, leftHalf: false)

        let farDrop = (farOff - farOn) / max(farOff, 1e-9)
        let nearChange = abs(nearOff - nearOn) / max(nearOff, 1e-9)
        print("DEHAZE DEPTH · far \(farOff) → \(farOn) (\(farDrop * 100)%) · "
              + "near \(nearOff) → \(nearOn) (\(nearChange * 100)%)")
        XCTAssertGreaterThanOrEqual(farDrop, 0.15,
                                   "far (depth p10–p30) must lose ≥ 15 % of its dark channel")
        XCTAssertLessThanOrEqual(nearChange, 0.05,
                                "near (depth p70–p90) must move ≤ 5 %")
        XCTAssertLessThan(farOn, nearOn, "far is corrected more than near")
    }

    // MARK: 5 — strength 0 is today's dehaze, byte for byte

    func testZeroStrengthIsByteIdenticalWithOrWithoutADepthMap() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let depth = try halfDepth(device)
        let withDepth = try makeGraph(scene(), depth: depth)
        let withoutDepth = try makeGraph(scene(), depth: nil)
        let e = edit(dehaze: 60, depth: 0)
        let a = try linearRender(withDepth, e)
        let b = try linearRender(withoutDepth, e)
        XCTAssertEqual(a.sha256(), b.sha256(),
                       "depthStrength == 0 must not let the bound depth texture move a pixel")
    }

    /// The stage's key names the strength only when it is non-zero (the `boff` discipline): a
    /// document that never touched the row keeps the pre-120b `dz=` text.
    func testDehazeKeyNamesTheDepthStrengthOnlyWhenMoved() {
        XCTAssertEqual(edit(dehaze: 40, depth: 0).effects.dehazeKeyString, "dz=40.00000")
        XCTAssertTrue(edit(dehaze: 40, depth: 25).effects.dehazeKeyString.contains("dd=25.00000"))
        XCTAssertFalse(edit(dehaze: 40, depth: 0).effects.usesDepthDehaze)
        XCTAssertTrue(edit(dehaze: 40, depth: 25).effects.usesDepthDehaze)
        XCTAssertFalse(edit(dehaze: 0, depth: 25).effects.usesDepthDehaze,
                       "a strength with no dehaze has nothing to modulate")
    }

    /// 141 still holds when the assist is off: exposure and dehaze commute exactly on this frame.
    func testExposureAndDehazeStillCommuteAtZeroStrength() throws {        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let depth = try halfDepth(device)
        let graph = try makeGraph(scene(), depth: depth)
        var base = edit(dehaze: 50, depth: 0)
        var exposed = base
        exposed.light.exposure = 1.0
        let zero = try linearRender(graph, base)
        let plusOne = try linearRender(graph, exposed)
        // `render(E=1) == 2 · render(E=0)` on the linear exit.
        var worst = 0.0
        for i in stride(from: 0, to: zero.rgba.count, by: 4) {
            for c in 0..<3 {
                let expected = Double(zero.rgba[i + c]) * 2
                let got = Double(plusOne.rgba[i + c])
                let tolerance = max(1e-6, abs(expected) * 2e-3)
                worst = max(worst, abs(got - expected) / max(abs(expected), 1e-9))
                XCTAssertLessThanOrEqual(abs(got - expected), tolerance)
            }
        }
        XCTAssertLessThan(worst, 2e-3)
        base.effects.dehaze = 0
    }
}
