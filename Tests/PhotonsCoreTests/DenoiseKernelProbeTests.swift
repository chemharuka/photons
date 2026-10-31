@testable import PhotonsCore
import XCTest
import Metal

/// 171 — a direct harness on the three bilateral-grid kernels, outside `RenderGraph`.
///
/// The grid is the one place where a sign, a channel or a bin index can be wrong without the frame
/// looking obviously broken, and `RenderGraph` gives no readback. This probe runs `s3_9_nr_sigma`,
/// `s3_9_nr_splat` and `s3_9_nr_blur` on a synthetic 64 × 64 frame and prints what actually lands in
/// the 3-D texture, so the slice's arithmetic can be checked against something other than the picture.
final class DenoiseKernelProbeTests: XCTestCase {

    private let w = 64
    private let h = 64
    private let cell = 8

    private func texture(_ device: MTLDevice, _ fd: MTLTextureDescriptor) throws -> MTLTexture {
        try XCTUnwrap(device.makeTexture(descriptor: fd))
    }

    func testGridHoldsTheCellsMeanLuma() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let library = KernelLibrary(device: device)

        // 64×64: left half luma 0.10, right half 0.50 — one step at x = 32, i.e. inside cell 4.
        let srcDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w,
                                                              height: h, mipmapped: false)
        srcDesc.usage = [.shaderRead, .shaderWrite]
        srcDesc.storageMode = .shared
        let src = try texture(device, srcDesc)
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = Float16(x < w / 2 ? 0.10 : 0.50)
                let i = (y * w + x) * 4
                rgba[i] = v; rgba[i + 1] = v; rgba[i + 2] = v; rgba[i + 3] = 1
            }
        }
        rgba.withUnsafeBytes { raw in
            src.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: w * 8)
        }

        let sigDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                                                              width: 1, height: 1, mipmapped: false)
        sigDesc.usage = [.shaderRead, .shaderWrite]
        sigDesc.storageMode = .shared
        let sig = try texture(device, sigDesc)

        let gW = (w + cell - 1) / cell, gH = (h + cell - 1) / cell, gZ = 40
        let gDesc = MTLTextureDescriptor()
        gDesc.textureType = .type3D
        gDesc.pixelFormat = .rgba16Float
        gDesc.width = gW
        gDesc.height = gH
        gDesc.depth = gZ
        gDesc.mipmapLevelCount = 1
        gDesc.usage = [.shaderRead, .shaderWrite]
        gDesc.storageMode = .shared
        let gridA = try texture(device, gDesc)
        let gridB = try texture(device, gDesc)

        var dp = DenoiseProbeParams(canvas: SIMD4(Int32(w), Int32(h), Int32(cell), Int32(gZ)),
                                    grid: SIMD4(Int32(gW), Int32(gH), 0, 0),
                                    n: SIMD4(1, 0, 0, 0))

        guard let cb = device.makeCommandQueue()?.makeCommandBuffer() else {
            throw XCTSkip("no command queue")
        }

        // P0 — sigma.
        do {
            let p = try library.pipeline(file: "s3_9_denoise", function: "s3_9_nr_sigma")
            let e = try XCTUnwrap(cb.makeComputeCommandEncoder())
            e.setComputePipelineState(p)
            e.setTexture(src, index: 0)
            e.setTexture(sig, index: 1)
            e.setBytes(&dp, length: MemoryLayout<DenoiseProbeParams>.stride, index: 0)
            e.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            e.endEncoding()
        }
        // P1 — splat (with the z five-tap inside).
        do {
            let p = try library.pipeline(file: "s3_9_denoise", function: "s3_9_nr_splat")
            let e = try XCTUnwrap(cb.makeComputeCommandEncoder())
            e.setComputePipelineState(p)
            e.setTexture(src, index: 0)
            e.setTexture(sig, index: 1)
            e.setTexture(gridA, index: 2)
            e.setBytes(&dp, length: MemoryLayout<DenoiseProbeParams>.stride, index: 0)
            e.dispatchThreadgroups(MTLSize(width: gW, height: gH, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            e.endEncoding()
        }
        // P2 / P3 — the separable x, y five-tap on a **copy** (the reference), then the shipped
        // one-pass `s3_9_nr_blur_xy` on the original: the two must agree texel for texel.
        let gridC = try texture(device, gDesc)
        let gridD = try texture(device, gDesc)
        do {
            let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
            blit.copy(from: gridA, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: gW, height: gH, depth: gZ),
                      to: gridC, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        for (axis, from, to) in [(Int32(0), gridA, gridB), (Int32(1), gridB, gridA)] {
            dp.grid.z = axis
            let p = try library.pipeline(file: "s3_9_denoise", function: "s3_9_nr_blur")
            let e = try XCTUnwrap(cb.makeComputeCommandEncoder())
            e.setComputePipelineState(p)
            e.setTexture(from, index: 0)
            e.setTexture(to, index: 1)
            e.setBytes(&dp, length: MemoryLayout<DenoiseProbeParams>.stride, index: 0)
            e.dispatchThreadgroups(MTLSize(width: (gW + 7) / 8, height: (gH + 7) / 8, depth: gZ),
                                   threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            e.endEncoding()
        }
        do {
            let p = try library.pipeline(file: "s3_9_denoise", function: "s3_9_nr_blur_xy")
            let e = try XCTUnwrap(cb.makeComputeCommandEncoder())
            e.setComputePipelineState(p)
            e.setTexture(gridC, index: 0)
            e.setTexture(gridD, index: 1)
            e.setBytes(&dp, length: MemoryLayout<DenoiseProbeParams>.stride, index: 0)
            e.dispatchThreadgroups(MTLSize(width: (gW + 15) / 16, height: (gH + 15) / 16, depth: gZ),
                                   threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            e.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()

        // Slice at the two plateaus, exactly as `s3_8_guide_apply` does.
        var sigmaRaw = SIMD4<Float>(repeating: 0)
        sig.getBytes(&sigmaRaw, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        let r = min(max((0.4 + 0.6 * 1.0) * Double(sigmaRaw.x), 0.010), 0.050)

        let count = gW * gH * gZ
        func readback(_ t: MTLTexture) -> [Float16] {
            var raw = [Float16](repeating: 0, count: count * 4)
            raw.withUnsafeMutableBytes { buf in
                t.getBytes(buf.baseAddress!, bytesPerRow: gW * 8, bytesPerImage: gW * gH * 8,
                           from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                           size: MTLSize(width: gW, height: gH, depth: gZ)),
                           mipmapLevel: 0, slice: 0)
            }
            return raw
        }
        let twoPass = readback(gridA)       // P3 already wrote the reference back into gridA
        let onePass = readback(gridD)
        var maxDiff = 0.0
        for i in 0..<twoPass.count { maxDiff = max(maxDiff, abs(Double(twoPass[i]) - Double(onePass[i]))) }
        print(String(format: "PROBE · fused xy blur vs two-pass: max |Δ| %.6f over %d texels",
                     maxDiff, count))
        XCTAssertLessThanOrEqual(maxDiff, 1e-3, "一次过的 x/y 模糊必须与两趟逐 texel 相同")

        let blurred = onePass
        func texel(_ gx: Int, _ gy: Int, _ z: Int) -> [Double] {
            let i = ((z * gH + gy) * gW + gx) * 4
            return (0..<4).map { Double(blurred[i + $0]) }
        }
        func slice(_ px: Int, _ py: Int, _ L: Double) -> [Double] {
            let cx = (Double(px) + 0.5) / Double(cell) - 0.5
            let cy = (Double(py) + 0.5) / Double(cell) - 0.5
            let cz = min(max(L / r, 0), 39)
            let x0 = Int(cx.rounded(.down)), y0 = Int(cy.rounded(.down)), z0 = Int(cz.rounded(.down))
            let tx = cx - Double(x0), ty = cy - Double(y0), tz = cz - Double(z0)
            var acc = [Double](repeating: 0, count: 4)
            for (dz, wz) in [(0, 1 - tz), (1, tz)] {
                for (dy, wy) in [(0, 1 - ty), (1, ty)] {
                    for (dx, wx) in [(0, 1 - tx), (1, tx)] {
                        let t = texel(min(max(x0 + dx, 0), gW - 1), min(max(y0 + dy, 0), gH - 1),
                                      min(max(z0 + dz, 0), gZ - 1))
                        for c in 0..<4 { acc[c] += wx * wy * wz * t[c] }
                    }
                }
            }
            let wsum = max(acc[3], 1e-6)
            return [acc[0] / wsum, acc[1] / wsum, acc[2] / wsum, acc[3]]
        }
        print(String(format: "PROBE · r_sigma %.4f", r))
        let darkMean = slice(16, 32, 0.10)
        let brightMean = slice(48, 32, 0.50)
        print(String(format: "PROBE · slice @ dark (0.10): Lbar %.4f abar %.4f bbar %.4f wsum %.3f",
                     darkMean[0], darkMean[1], darkMean[2], darkMean[3]))
        print(String(format: "PROBE · slice @ bright (0.50): Lbar %.4f abar %.4f bbar %.4f wsum %.3f",
                     brightMean[0], brightMean[1], brightMean[2], brightMean[3]))
        XCTAssertEqual(darkMean[0], 0.10, accuracy: 0.02, "暗侧的 slice 必须回到 0.10")
        XCTAssertEqual(brightMean[0], 0.50, accuracy: 0.02, "亮侧的 slice 必须回到 0.50")
    }
}

/// 171 — the grid's own cost at the acceptance's 4.10 Mpx, measured in isolation.
///
/// `DetailFXTests.testEachNonBayerControlEntersTheStageOnceAndAddsNoPass` gates the **marginal
/// frame** as a *shape* (the stage enters once, adds no pass, is absent at amount 0) and only prints
/// its milliseconds — on a shared machine that marginal is a load-dependent number, and it goes
/// **negative** often enough that no threshold on it means anything. This test times the three grid
/// passes themselves on a command buffer's GPU timestamps — a number that does not depend on what
/// else is running, and one that can be compared against the bandwidth estimate in `local/REPORT.md`.
final class DenoiseGridCostTests: XCTestCase {

    func testGridPassesAtFourMegapixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let library = KernelLibrary(device: device)
        let w = 1500, h = 2731, cell = 8, gZ = 40
        let gW = (w + cell - 1) / cell, gH = (h + cell - 1) / cell

        let srcDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w,
                                                              height: h, mipmapped: false)
        srcDesc.usage = [.shaderRead, .shaderWrite]
        srcDesc.storageMode = .private
        let src = try XCTUnwrap(device.makeTexture(descriptor: srcDesc))

        let sigDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1,
                                                              height: 1, mipmapped: false)
        sigDesc.usage = [.shaderRead, .shaderWrite]
        sigDesc.storageMode = .private
        let sig = try XCTUnwrap(device.makeTexture(descriptor: sigDesc))

        let gDesc = MTLTextureDescriptor()
        gDesc.textureType = .type3D
        gDesc.pixelFormat = .rgba16Float
        gDesc.width = gW
        gDesc.height = gH
        gDesc.depth = gZ
        gDesc.mipmapLevelCount = 1
        gDesc.usage = [.shaderRead, .shaderWrite]
        gDesc.storageMode = .private
        let gridA = try XCTUnwrap(device.makeTexture(descriptor: gDesc))
        let gridB = try XCTUnwrap(device.makeTexture(descriptor: gDesc))

        var dp = DenoiseProbeParams(canvas: SIMD4(Int32(w), Int32(h), Int32(cell), Int32(gZ)),
                                    grid: SIMD4(Int32(gW), Int32(gH), 0, 0),
                                    n: SIMD4(1, 0, 0, 0))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let sigmaP = try library.pipeline(file: "s3_9_denoise", function: "s3_9_nr_sigma")
        let splatP = try library.pipeline(file: "s3_9_denoise", function: "s3_9_nr_splat")
        let blurP = try library.pipeline(file: "s3_9_denoise", function: "s3_9_nr_blur_xy")

        func encode() throws -> MTLCommandBuffer {
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            do {
                let e = try XCTUnwrap(cb.makeComputeCommandEncoder())
                e.setComputePipelineState(sigmaP)
                e.setTexture(src, index: 0); e.setTexture(sig, index: 1)
                e.setBytes(&dp, length: MemoryLayout<DenoiseProbeParams>.stride, index: 0)
                e.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                e.endEncoding()
            }
            do {
                let e = try XCTUnwrap(cb.makeComputeCommandEncoder())
                e.setComputePipelineState(splatP)
                e.setTexture(src, index: 0); e.setTexture(sig, index: 1); e.setTexture(gridA, index: 2)
                e.setBytes(&dp, length: MemoryLayout<DenoiseProbeParams>.stride, index: 0)
                e.dispatchThreadgroups(MTLSize(width: gW, height: gH, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                e.endEncoding()
            }
            do {
                let e = try XCTUnwrap(cb.makeComputeCommandEncoder())
                e.setComputePipelineState(blurP)
                e.setTexture(gridA, index: 0); e.setTexture(gridB, index: 1)
                e.setBytes(&dp, length: MemoryLayout<DenoiseProbeParams>.stride, index: 0)
                e.dispatchThreadgroups(MTLSize(width: (gW + 15) / 16, height: (gH + 15) / 16, depth: gZ),
                                       threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                e.endEncoding()
            }
            return cb
        }

        for _ in 0..<5 { let warm = try encode(); warm.commit(); warm.waitUntilCompleted() }
        var samples: [Double] = []
        for _ in 0..<30 {
            let cb = try encode()
            cb.commit()
            cb.waitUntilCompleted()
            samples.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
        }
        samples.sort()
        let grid = Double(gW * gH * gZ)
        print(String(format: "171 COST · grid %d×%d×%d (%.2f M texels, %.1f MB, cell %d) · "
                     + "sigma+splat+blur_xy min %.2f ms · p50 %.2f ms · median-of-best-10 %.2f ms",
                     gW, gH, gZ, grid / 1e6, grid * 8 / 1e6, cell,
                     samples.first ?? -1, samples[samples.count / 2],
                     samples.prefix(10).reduce(0, +) / 10))
        XCTAssertLessThan(samples[samples.count / 2], 2.0, "网格三趟本身必须 < 2 ms")
    }
}

/// Mirror of the kernel
/// `DenoiseParams` (the real one is private to `RenderGraph`).
struct DenoiseProbeParams {
    var canvas: SIMD4<Int32>
    var grid: SIMD4<Int32>
    var n: SIMD4<Float>
}
