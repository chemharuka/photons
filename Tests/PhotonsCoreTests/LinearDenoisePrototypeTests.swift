import XCTest
import Metal
@testable import PhotonsCore

/// 365 — the **linear-domain (scene-referred) luminance denoise** prototype.
///
/// The shipped path is untouched: this file only ever sets `EditModel.linearDenoiseLuma`, a hidden
/// field that is not Codable and does not exist in any document. The acceptance is measured on real
/// renders of the Metal kernels, not on a CPU model.
final class LinearDenoisePrototypeTests: XCTestCase {

    private struct Noise {
        var seed: UInt32
        init(_ s: UInt32) { seed = s }
        mutating func next() -> Double {
            seed = seed &* 1664525 &+ 1013904223
            return Double(seed >> 8) / Double(1 << 24)
        }
        mutating func symmetric(_ amplitude: Double) -> Double { (next() - 0.5) * 2 * amplitude }
    }

    private func makeGraph(_ image: LinearImage, identity: String = "linear-denoise-365") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    /// A flat grey field with deterministic luminance noise, plus one hard vertical step so the
    /// "does it smear an edge?" check has something to lose.
    private func noisyStep(w: Int = 320, h: Int = 240) -> LinearImage {
        var rng = Noise(0x365)
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let scene = x < w / 2 ? 0.10 : 0.28
                let v = scene * (1 + rng.symmetric(0.12))
                let i = (y * w + x) * 4
                rgba[i] = Float16(v)
                rgba[i + 1] = Float16(v)
                rgba[i + 2] = Float16(v)
                rgba[i + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-365")
    }

    private func luma(_ image: DisplayImage) -> [Double] {
        var out = [Double](repeating: 0, count: image.width * image.height)
        for i in 0..<out.count {
            let b = i * 4
            out[i] = 255 * (0.2126 * Double(image.rgba[b])
                            + 0.7152 * Double(image.rgba[b + 1])
                            + 0.0722 * Double(image.rgba[b + 2]))
        }
        return out
    }

    /// σ of `luma − 5×5 mean`, on display codes. The same high-pass `DetailDenoiseTests` uses.
    private func highPassSigma(_ luma: [Double], w: Int, h: Int,
                               x0: Int, x1: Int, y0: Int, y1: Int, radius: Int = 2) -> Double {
        func at(_ x: Int, _ y: Int) -> Double {
            luma[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)]
        }
        var sum = 0.0
        var n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                var s = 0.0
                var c = 0
                for dy in -radius...radius {
                    for dx in -radius...radius { s += at(x + dx, y + dy); c += 1 }
                }
                let d = at(x, y) - s / Double(c)
                sum += d * d
                n += 1
            }
        }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    // MARK: - identity

    func testTheSwitchOffIsThePre365FrameAndKey() throws {
        let image = noisyStep()
        var edit = EditModel.neutral
        edit.light.exposure = 0.3
        let graph = try makeGraph(image)
        let off = try render(graph, edit)
        XCTAssertFalse(edit.keyMaterial(.curve).contains("lindn="),
                       "a zero amount may not add a key token")
        XCTAssertFalse(edit.hasLinearDenoise)
        // …and the hidden switch is not part of the document: encoding a document that carries it
        // writes no key, so a save/load round trip cannot smuggle a prototype into a file.
        var hidden = edit
        hidden.linearDenoiseLuma = 0.5
        let json = String(decoding: try JSONEncoder().encode(hidden), as: UTF8.self)
        XCTAssertFalse(json.contains("linearDenoise"), "the prototype switch must stay out of JSON")
        // The same document rendered twice is the same bytes; the switch is not a second path.
        let again = try render(graph, edit)
        XCTAssertEqual(off.sha256(), again.sha256())
        XCTAssertTrue(off.rgba.allSatisfy { $0.isFinite })
    }

    func testTheSwitchOnRendersTheSameCanvasWithNoNaN() throws {
        let image = noisyStep()
        var edit = EditModel.neutral
        edit.light.exposure = 0.3
        edit.linearDenoiseLuma = 0.5
        let graph = try makeGraph(image)
        let on = try render(graph, edit)
        XCTAssertEqual(on.width, image.width)
        XCTAssertEqual(on.height, image.height)
        XCTAssertTrue(on.rgba.allSatisfy { $0.isFinite })
        XCTAssertTrue(edit.keyMaterial(.curve).contains("lindn="))
    }

    func testLuminanceNoiseFallsWhileTheStepKeepsItsHeight() throws {
        let image = noisyStep()
        var offEdit = EditModel.neutral
        offEdit.light.exposure = 0.3
        var onEdit = offEdit
        onEdit.linearDenoiseLuma = 0.7

        let graph = try makeGraph(image)
        let off = luma(try render(graph, offEdit))
        let on = luma(try render(graph, onEdit))

        let w = image.width, h = image.height
        // Far from the step (x = 160): 32 px of quiet on the left half.
        let offSigma = highPassSigma(off, w: w, h: h, x0: 24, x1: 120, y0: 40, y1: 200)
        let onSigma = highPassSigma(on, w: w, h: h, x0: 24, x1: 120, y0: 40, y1: 200)
        print(String(format: "S1.65 synthetic · flat σ off %.4f · on %.4f · ratio %.3f",
                     offSigma, onSigma, onSigma / max(offSigma, 1e-9)))
        XCTAssertLessThan(onSigma, offSigma * 0.8,
                          "flat-region σ \(onSigma) (on) vs \(offSigma) (off)")

        // The step's 10→90 % width must stay within a pixel of the original.
        func stepWidth(_ px: [Double]) -> Double {
            let row = 120
            let lo = px[row * w + 24]
            let hi = px[row * w + 300]
            var p10 = 24.0, p90 = 300.0
            for x in 24..<300 {
                let t = (px[row * w + x] - lo) / max(hi - lo, 1e-6)
                if t >= 0.10 && p10 == 24.0 { p10 = Double(x) }
                if t >= 0.90 { p90 = Double(x); break }
            }
            return p90 - p10
        }
        print(String(format: "S1.65 synthetic · step width off %.1f px · on %.1f px",
                     stepWidth(off), stepWidth(on)))
        XCTAssertLessThan(abs(stepWidth(on) - stepWidth(off)), 2.0,
                          "the step's 10→90 % width moved: \(stepWidth(off)) → \(stepWidth(on))")
    }

    // MARK: - the kernel's noise model, directly

    /// Mirror of `S1_65Params` in `s1_65_denoise.metal`, for the readback harness only.
    private struct ProbeParams {
        var canvas: SIMD4<Int32>
        var grid: SIMD4<Int32>
        var n: SIMD4<Float>
        var fit: SIMD4<Float>
    }

    func testTheNoiseModelFitsSigmaSquaredAffineInIntensity() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let w = 256, h = 256
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w,
                                                            height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let src = try XCTUnwrap(device.makeTexture(descriptor: desc))
        var rng = Noise(0x365_1234)
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let v = 0.18 + rng.symmetric(0.05)
            let o = i * 4
            rgba[o] = Float16(v); rgba[o + 1] = Float16(v); rgba[o + 2] = Float16(v)
            rgba[o + 3] = 1
        }
        rgba.withUnsafeBytes { raw in
            src.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: w * 8)
        }
        let mdesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                                                             width: 1, height: 1, mipmapped: false)
        mdesc.usage = [.shaderRead, .shaderWrite]
        mdesc.storageMode = .shared
        let model = try XCTUnwrap(device.makeTexture(descriptor: mdesc))

        var p = ProbeParams(canvas: SIMD4(Int32(w), Int32(h), 8, 40),
                            grid: SIMD4(0, 0, 0, 0),
                            n: SIMD4(0.5, Float(1.0 / 65536.0), -16, 4),
                            fit: .zero)
        let library = KernelLibrary(device: device)
        let pipeline = try library.pipeline(file: "s1_65_denoise", function: "s1_65_noise_model")
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setTexture(src, index: 0)
        enc.setTexture(model, index: 1)
        enc.setBytes(&p, length: MemoryLayout<ProbeParams>.stride, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)

        var fit = [Float](repeating: 0, count: 4)
        model.getBytes(&fit, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        print(String(format: "S1.65 noise model · a=%.6f b=%.8f residual=%.8f clamped=%.4f%%",
                     fit[0], fit[1], fit[2], fit[3] * 100))
        XCTAssertGreaterThanOrEqual(fit[0], 0)
        XCTAssertGreaterThan(fit[1], 0)
        XCTAssertGreaterThan(fit[0] * 0.18 + fit[1], 0)
        XCTAssertLessThan(fit[2], 0.01, "the affine fit should describe a flat noisy field")
    }
}

// MARK: - the six-group A/B on real RAW files (365 §3/§4)

