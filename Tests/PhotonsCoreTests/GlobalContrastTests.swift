import XCTest
import Metal
@testable import PhotonsCore

/// 228 — the acceptance for **global contrast in the gain domain** (S2.5, after the tone map).
///
/// The operator is one power curve on the unexposed display luma:
///
///     gain(Y) = ((Y / e) / 0.18)^(γ − 1),   γ = 2^(contrast/100 · travel)
///
/// and the five claims the ticket asks for are, in order:
///
///   ① `contrast = 0` is the bit-exact identity;
///   ② `+100` and `−100` are inverse powers on the EV axis (opposite `log2(out/in)`, equal magnitude);
///   ③ both the SDR (≤1) and the HDR (>1, to 4.926 = +2.303 EV) segments move, with no clamp at 1;
///   ④ exposure × contrast commute to ≤2 % (the old local operator's open question);
///   ⑤ one gain on R/G/B preserves the channel ratios (hue and saturation) to one 16-bit code.
final class GlobalContrastTests: XCTestCase {

    // MARK: - plumbing

    private func graph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel,
                        headroom: Double = 8) throws -> DisplayImage {
        var display = DisplayOptions(headroom: headroom)
        display.linearOutput = true
        let result = try graph.render(edit, options: RenderOptions(scale: 1, display: display,
                                                                 useCache: false, wantsPixels: true))
        defer { if let t = result.output { graph.recycle(output: t) } }
        return try XCTUnwrap(result.display)
    }

    private func luma(_ image: DisplayImage, _ x: Int, _ y: Int) -> Double {
        let i = (y * image.width + x) * 4
        return 0.2627 * Double(image.rgba[i]) + 0.6780 * Double(image.rgba[i + 1])
            + 0.0593 * Double(image.rgba[i + 2])
    }

    private func contrast(_ c: Double, exposure: Double = 0) -> EditModel {
        var e = EditModel.neutral
        e.light.contrast = c
        e.light.exposure = exposure
        return e
    }

    private func frame(width: Int, height: Int,
                       value: (Int, Int) -> (Float, Float, Float)) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = value(x, y)
                let i = (y * width + x) * 4
                rgba[i] = Float16(c.0); rgba[i + 1] = Float16(c.1)
                rgba[i + 2] = Float16(c.2); rgba[i + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// A ramp whose steps are equally spaced in **EV**, from 0.002 to 4.926 linear (+2.303 EV).
    private let rampValues: [Double] = {
        let lo = log2(0.002), hi = log2(4.926)
        return (0..<30).map { pow(2.0, lo + (hi - lo) * Double($0) / 29.0) }
    }()

    private func rampImage(cell: Int = 40) -> LinearImage {
        let width = rampValues.count * cell
        return frame(width: width, height: 64) { x, _ in
            let v = Float(rampValues[x / cell])
            return (v, v, v)
        }
    }

    // MARK: - ① neutral is the bit-exact identity

    func testNeutralIsTheBitExactIdentity() throws {
        // CPU side: `contrast = 0` takes the return-before-log branch.
        for y in [1e-4, 0.002, 0.18, 1.0, 4.926] {
            XCTAssertEqual(GlobalContrast.gain(luma: y, contrast: 0), 1.0, accuracy: 0,
                           "contrast 0 must be exactly 1 at Y = \(y)")
            XCTAssertEqual(GlobalContrast.outputLuma(y, contrast: 0), y, accuracy: 0,
                           "contrast 0 must not move Y = \(y)")
        }
        XCTAssertEqual(GlobalContrast.gamma(contrast: 0), 1.0, accuracy: 0)
        XCTAssertEqual(GlobalContrast.gamma(contrast: 100) * GlobalContrast.gamma(contrast: -100),
                       1.0, accuracy: 1e-15, "the two signs must be reciprocal powers")
        // Zero light stays zero: the kernel floors `Y` only to keep `log2` finite, and the pixel it
        // multiplies is `max(rgb, 0) == 0`. The CPU reference must agree.
        XCTAssertEqual(GlobalContrast.outputLuma(0, contrast: 100), 0, accuracy: 0)
        XCTAssertEqual(GlobalContrast.outputLuma(0, contrast: -100), 0, accuracy: 0)
        XCTAssertEqual(GlobalContrast.gain(luma: 0, contrast: 100), 1, accuracy: 0)

        // GPU side: the kernel is not even encoded (`hasContrastStage`), and two neutral renders are
        // byte-identical. This is the "structurally absent, not neutral arithmetic" contract.
        let image = frame(width: 48, height: 32) { _, _ in (0.18, 0.18, 0.18) }
        let g = try graph(image, identity: "gc-neutral")
        let once = try render(g, .neutral)
        let twice = try render(g, .neutral)
        XCTAssertEqual(once.sha256(), twice.sha256())
        let result = try g.render(.neutral, options: RenderOptions(scale: 1, wantsPixels: false))
        XCTAssertFalse(result.trace.executed.contains(.contrast))
        XCTAssertFalse(result.trace.skipped.contains(.contrast))
        XCTAssertNil(result.keys.contrast)
    }

    // MARK: - ② ± are inverse on the EV axis

    func testPlusAndMinusAreInversePowers() throws {
        for x in [0.002, 0.02, 0.18, 1.0, 4.926] {
            let up = GlobalContrast.outputLuma(x, contrast: 100)
            let back = GlobalContrast.outputLuma(up, contrast: -100)
            XCTAssertEqual(back, x, accuracy: max(x * 1e-12, 1e-15),
                           "−100 must undo +100 at Y = \(x) (got \(back))")

            let dPlus = log2(up / x)
            let dMinus = log2(back / up)
            print(String(format: "GC ② Y %.5f · +100 %.6f EV · −100 at that output %.6f EV", x, dPlus, dMinus))
            XCTAssertEqual(abs(dPlus + dMinus), 0, accuracy: abs(dPlus) * 0.02 + 1e-12,
                           "the forward and return EV shifts must have opposite signs and equal magnitude")
            XCTAssertEqual(dMinus, -dPlus, accuracy: abs(dPlus) * 0.02 + 1e-12)
        }

        // On the same input the two signs move in opposite directions about the pivot, which is what
        // a user sees: +100 pushes a highlight up, −100 pulls it down.
        for x in [0.002, 0.02, 0.18, 1.0, 4.926] {
            let up = GlobalContrast.outputLuma(x, contrast: 100)
            let down = GlobalContrast.outputLuma(x, contrast: -100)
            if x > GlobalContrast.pivot * (1 + 1e-12) {
                XCTAssertGreaterThan(up, x)
                XCTAssertLessThan(down, x)
            } else if x < GlobalContrast.pivot * (1 - 1e-12) {
                XCTAssertLessThan(up, x)
                XCTAssertGreaterThan(down, x)
            } else {
                XCTAssertEqual(up, x, accuracy: 1e-15)
                XCTAssertEqual(down, x, accuracy: 1e-15)
            }
            print(String(format: "GC ② same input Y %.5f · +100 → %.5f · −100 → %.5f", x, up, down))
        }
    }

    // MARK: - ③ SDR and HDR both move, monotone, no clamp at 1

    func testSDRAndHDRBothMoveAndNothingClampsAtOne() throws {
        let image = rampImage()
        let g = try graph(image, identity: "gc-ramp")
        let base = try render(g, .neutral)
        let cell = 40
        let h = image.height

        // 30 steps from 0.002 to 4.926; take three points inside each segment.
        let sdr = [4, 12, 21]    // ≈ 0.006 … 0.56 linear
        let hdr = [25, 27, 29]   // ≈ 1.7 … 4.926 linear
        let samples = sdr + hdr
        let input = samples.map { i in luma(base, i * cell + cell / 2, h / 2) }

        for c in [100.0, -100.0] {
            let out = try render(g, contrast(c))
            let ratios = samples.map { i -> Double in
                let v = luma(out, i * cell + cell / 2, h / 2)
                return v / input[samples.firstIndex(of: i)!]
            }
            print(String(format: "GC ③ c=%+.0f · SDR ratios %@ · HDR ratios %@",
                         c, sdr.enumerated().map { String(format: "%.4f", ratios[$0.offset]) }.joined(separator: " "),
                         (hdr.count..<ratios.count).map { String(format: "%.4f", ratios[$0]) }.joined(separator: " ")))

            // Every sampled point really moves (the local operator left a ramp at 1.0000).
            for (k, r) in ratios.enumerated() {
                XCTAssertGreaterThan(abs(log2(r)), 0.10,
                                     "c = \(c): step \(samples[k]) did not move (ratio \(r))")
            }

            // Monotone in the same direction inside each segment; + raises the ratio with Y, − lowers it.
            func assertMonotone(_ range: Range<Int>, _ label: String) {
                for k in range.dropFirst() {
                    if c > 0 {
                        XCTAssertGreaterThan(ratios[k], ratios[k - 1] * (1 + 1e-9), "\(label) not increasing")
                    } else {
                        XCTAssertLessThan(ratios[k], ratios[k - 1] * (1 - 1e-9), "\(label) not decreasing")
                    }
                }
            }
            assertMonotone(0..<sdr.count, "SDR")
            assertMonotone(sdr.count..<ratios.count, "HDR")

            // No clamp at 1: at +100 the top HDR step is expanded by (4.926/0.18) ≈ 27×, not passed
            // through, and S4's linear exit carries the value above 1 intact.
            if c > 0 {
                let top = luma(out, 29 * cell + cell / 2, h / 2)
                print(String(format: "GC ③ top HDR step +100 · in %.4f → out %.4f linear", input[5], top))
                XCTAssertGreaterThan(top, input[5] * 10,
                                     "the HDR segment must be expanded, not clamped at 1")
                XCTAssertEqual(top, GlobalContrast.outputLuma(input[5], contrast: 100),
                               accuracy: max(top * 0.03, 0.2),
                               "the rendered HDR step must follow the global power")
            }
        }
    }

    // MARK: - ④ exposure × contrast

    private func texture(width: Int = 300, height: Int = 180) -> LinearImage {
        frame(width: width, height: height) { x, y in
            let u = Float(x) / Float(width - 1), v = Float(y) / Float(height - 1)
            let base = 0.01 + 1.6 * u
            let tex = 0.05 * Float((x * 7 + y * 13) % 11) / 10
            return (base + tex, base * 0.95 + tex * 0.8, base * 0.85 + tex * 0.6 * (0.8 + 0.4 * v))
        }
    }

    func testExposureAndContrastCommute() throws {
        let image = texture()
        let g = try graph(image, identity: "gc-commute")
        let w = image.width, h = image.height
        var worstCode = 0.0
        var worstRelative = 0.0

        for c in [-50.0, 50.0] {
            let zero = try render(g, contrast(c, exposure: 0))
            for ev in [1.0, -1.0] {
                let exposed = try render(g, contrast(c, exposure: ev))
                let gain = pow(2.0, ev)
                var code = 0.0, rel = 0.0
                for y in stride(from: 0, to: h, by: 2) {
                    for x in stride(from: 0, to: w, by: 2) {
                        let i = (y * w + x) * 4
                        for ch in 0..<3 {
                            let expected = Double(zero.rgba[i + ch]) * gain
                            let got = Double(exposed.rgba[i + ch])
                            code = max(code, abs(expected - got) * 65535)
                            if expected > 1e-5 {
                                rel = max(rel, abs(expected - got) / expected)
                            }
                        }
                    }
                }
                worstCode = max(worstCode, code)
                worstRelative = max(worstRelative, rel)
                print(String(format: "GC ④ c=%+.0f E=%+.0f · max |Δ| %.3f codes16 · max rel %.4f %%",
                             c, ev, code, rel * 100))
                XCTAssertLessThanOrEqual(rel, 0.02,
                                         "E \(ev) c \(c): exposure and contrast must commute to ≤2 %")
            }
        }
        print(String(format: "GC ④ worst over all · %.3f codes16 · %.4f %%", worstCode, worstRelative * 100))
    }

    // MARK: - ⑤ one gain on R/G/B, ratios preserved

    func testHueAndChannelRatiosArePreservedByTheSingleGain() throws {
        let colours: [(Float, Float, Float)] = [
            (0.60, 0.20, 0.10), (0.05, 0.20, 0.50), (0.30, 0.50, 0.10),
            (0.80, 0.30, 0.30), (0.10, 0.35, 0.15), (0.45, 0.25, 0.60),
            (0.90, 0.70, 0.05), (0.02, 0.05, 0.20), (0.18, 0.18, 0.18),
            (1.00, 2.00, 3.00), (4.00, 1.00, 0.50),
        ]
        let cell = 8
        let width = colours.count * cell, height = cell
        var rgba = [Float]()
        for _ in 0..<height {
            for x in 0..<width {
                let c = colours[x / cell]
                rgba += [c.0, c.1, c.2, 1]
            }
        }
        let harness = try ContrastKernelHarness()
        let base = try harness.run(rgba, width: width, height: height, contrast: 0)

        func ratios(_ px: [Float], _ i: Int) -> (r: Double, g: Double, b: Double) {
            let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
            let y = 0.2627 * r + 0.6780 * g + 0.0593 * b
            return (r / y, g / y, b / y)
        }

        for c in [100.0, -100.0] {
            let out = try harness.run(rgba, width: width, height: height, contrast: c)
            var worst = 0.0
            for y in stride(from: 2, to: height, by: 3) {
                for x in stride(from: 2, to: width, by: 3) {
                    let i = (y * width + x) * 4
                    let a = ratios(base, i), b = ratios(out, i)
                    worst = max(worst, max(abs(a.r - b.r), max(abs(a.g - b.g), abs(a.b - b.b))))
                }
            }
            print(String(format: "GC ⑤ c=%+.0f · worst |channel ratio Δ| %.3e (%.4f of a 16-bit code)",
                         c, worst, worst * 65535))
            XCTAssertLessThanOrEqual(worst * 65535, 1.0,
                                     "one scalar gain must keep R:G:B to one 16-bit code at c = \(c)")
        }

        // The pure grey has R = G = B before and after (the gain is one number).
        let i = ((height / 2) * width + (8 * cell) + cell / 2) * 4
        for c in [100.0, -100.0] {
            let out = try harness.run(rgba, width: width, height: height, contrast: c)
            XCTAssertEqual(Double(out[i]), Double(out[i + 1]), accuracy: 1e-6)
            XCTAssertEqual(Double(out[i + 1]), Double(out[i + 2]), accuracy: 1e-6)
        }
        print("GC ⑤ grey stays R = G = B; the non-neutral samples keep their ratios")
    }

    // MARK: - constants

    func testTheCurveConstantsAreTheOnesTheTicketNames() {
        XCTAssertEqual(GlobalContrast.pivot, 0.18, accuracy: 0)
        XCTAssertEqual(GlobalContrast.travelEV, S2Contrast.travelEV, accuracy: 0,
                       "228's travel is the tone map's axis normalisation, not a new magic number")
        XCTAssertEqual(GlobalContrast.gamma(contrast: 100), pow(2, GlobalContrast.travelEV), accuracy: 1e-15)
        // The kernel takes all three from `ContrastParams.a`; it has no `constant float GC_*` copy to
        // drift. This test is therefore the one place the numbers are stated.
        let source = try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsCore/Kernels/s1_8_contrast.metal"), encoding: .utf8)
        XCTAssertNotNil(source)
        XCTAssertFalse(source?.contains("constant float MC_") ?? true,
                       "228 removed the multiscale constants")
        XCTAssertTrue(source?.contains("s1_8_g_contrast_apply_masked") ?? false)
        XCTAssertFalse(source?.contains("s1_8_g_contrast_coeff") ?? true,
                       "the multiscale coefficient path is gone")
    }
}

// MARK: - the shipped apply kernel, compiled here

/// Runs `s1_8_g_contrast_apply_masked` on a shared-memory float32 texture with mask count 0. Used by
/// ⑤ because the display readback is Float16 (~2e-3), coarser than the one-16-bit-code budget.
private final class ContrastKernelHarness {
    struct Params {
        var a: SIMD4<Float>     // contrast, pivot, exposure gain, travel EV
        var luma: SIMD4<Float>  // Rec2020 luma weights
        var rect: SIMD4<Float>  // contentOrigin.xy, contentSize.xy
        var d: SIMD4<Int32>     // canvasW, canvasH, mask count, pad
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard let queue = device.makeCommandQueue() else { throw XCTSkip("no command queue") }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsCore/Kernels/s1_8_contrast.metal")
        let source = try KernelLibrary.expandingLocalIncludes(of: url)
        let library = try device.makeLibrary(source: source, options: nil)
        let fn = try XCTUnwrap(library.makeFunction(name: "s1_8_g_contrast_apply_masked"))
        self.device = device
        self.queue = queue
        self.pipeline = try device.makeComputePipelineState(function: fn)
        XCTAssertEqual(MemoryLayout<Params>.stride, 64, "ContrastParams' mirror must match Metal's")
    }

    func run(_ rgba: [Float], width w: Int, height h: Int, contrast: Double) throws -> [Float] {
        let lw = ColorPrimaries.working.luminanceWeights
        var p = Params(
            a: SIMD4(Float(contrast), Float(GlobalContrast.pivot), 1, Float(GlobalContrast.travelEV)),
            luma: SIMD4(Float(lw.x), Float(lw.y), Float(lw.z), 0),
            rect: SIMD4(0, 0, Float(w), Float(h)),
            d: SIMD4(Int32(w), Int32(h), 0, 0))

        let src = try texture(w, h, .rgba32Float)
        let dst = try texture(w, h, .rgba32Float)
        src.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: rgba, bytesPerRow: w * 16)

        let atlasDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float,
                                                                 width: 1, height: 1, mipmapped: false)
        atlasDesc.textureType = .type2DArray
        atlasDesc.arrayLength = 1
        atlasDesc.usage = [.shaderRead]
        atlasDesc.storageMode = .shared
        let atlas = try XCTUnwrap(device.makeTexture(descriptor: atlasDesc))
        let adjust = try XCTUnwrap(device.makeBuffer(length: 64, options: .storageModeShared))

        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let e = try XCTUnwrap(cb.makeComputeCommandEncoder())
        e.setComputePipelineState(pipeline)
        e.setTexture(src, index: 0)
        e.setTexture(dst, index: 1)
        e.setTexture(atlas, index: 2)
        e.setBuffer(adjust, offset: 0, index: 1)
        e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        let tw = pipeline.threadExecutionWidth
        let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        e.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        e.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)

        var out = [Float](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { raw in
            dst.getBytes(raw.baseAddress!, bytesPerRow: w * 16,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return out
    }

    private func texture(_ w: Int, _ h: Int, _ format: MTLPixelFormat) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }
}
