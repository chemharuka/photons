import XCTest
import Metal
import simd
@testable import PhotonsCore

/// 365 §3/§4 — the six-group A/B, measured through the shipped graph on the three real files the
/// ticket names. Every number printed here is a real render; nothing is simulated.
///
/// Groups (same file, same crop, same sharpen setting — 314's default is left untouched):
///
///   A0  blackOffset 0, no denoise                     the pre-365 frame + the negative-value baseline
///   A   blackOffset = automatic (094's estimator)      separates "lifting the black" from "denoise"
///   B   blackOffset 0, S3.9 luma NR 50                 today's display-domain baseline
///   C0  blackOffset 0, S1.65 luma 50                   the reverse gate: what the clamp loses
///   C   blackOffset = automatic, S1.65 luma 50         the ticket's protagonist
///   D   blackOffset = automatic, S1.65 luma 50 + S3.9 chroma 50
///
/// The file paths are the ticket's. A machine without them skips; the synthetic suite above still
/// proves the kernels.
final class LinearDenoiseABTests: XCTestCase {

    private struct Photo {
        let name: String
        let url: URL
    }

    private let photos = [
        Photo(name: "L1030994", url: URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/boston/L1030994.dng")),
        Photo(name: "L1030437", url: URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/test/L1030437.dng")),
        Photo(name: "L1030428", url: URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/test/L1030428.dng")),
    ]

    private let scale = 0.25

    // MARK: - documents

    private func document(offset: Double, linear: Double, lumaNR: Double, chromaNR: Double) -> EditModel {
        var e = EditModel.neutral
        e.light.blackOffset = offset
        e.linearDenoiseLuma = linear
        e.effects.nonBayerLuminanceNR = lumaNR
        e.effects.nonBayerColorNR = chromaNR
        return e
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> (DisplayImage, Double) {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        let image = try XCTUnwrap(result.display)
        let ms = result.trace.gpuMilliseconds
        if let t = result.output { graph.recycle(output: t) }
        return (image, ms)
    }

    // MARK: - measurements on display codes

    private func luma(_ image: DisplayImage) -> [Double] {
        var out = [Double](repeating: 0, count: image.width * image.height)
        for i in 0..<out.count {
            let o = i * 4
            out[i] = 255 * (0.2126 * Double(image.rgba[o])
                            + 0.7152 * Double(image.rgba[o + 1])
                            + 0.0722 * Double(image.rgba[o + 2]))
        }
        return out
    }

    private struct Block { let x: Int; let y: Int }

    private func blockMean(_ luma: [Double], w: Int, _ b: Block, tile: Int = 64) -> Double {
        var s = 0.0, n = 0.0
        for y in b.y..<(b.y + tile) {
            for x in b.x..<(b.x + tile) { s += luma[y * w + x]; n += 1 }
        }
        return s / n
    }

    /// 64 × 64 blocks, ranked by the standard deviation of their luma (sampled every second pixel —
    /// the ranking only has to find flats, the final σ is measured on every pixel).
    private func flattest(_ luma: [Double], w: Int, h: Int, count: Int,
                          lumaRange: ClosedRange<Double> = 4...250) -> [Block] {
        let tile = 64
        var candidates: [(Block, Double, Double)] = []
        var y = 8
        while y + tile < h - 8 {
            var x = 8
            while x + tile < w - 8 {
                var s = 0.0, s2 = 0.0, n = 0.0
                var yy = y
                while yy < y + tile {
                    var xx = x
                    while xx < x + tile {
                        let v = luma[yy * w + xx]
                        s += v; s2 += v * v; n += 1
                        xx += 2
                    }
                    yy += 2
                }
                let mean = s / n
                let variance = max(s2 / n - mean * mean, 0)
                if lumaRange.contains(mean) {
                    candidates.append((Block(x: x, y: y), variance, mean))
                }
                x += tile
            }
            y += tile
        }
        return candidates.sorted { $0.1 < $1.1 }.prefix(count).map(\.0)
    }

    private func highPassSigma(_ luma: [Double], w: Int, h: Int, _ b: Block,
                               tile: Int = 64, radius: Int = 2) -> Double {
        func at(_ x: Int, _ y: Int) -> Double {
            luma[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)]
        }
        var sum = 0.0, n = 0
        for y in b.y..<(b.y + tile) {
            for x in b.x..<(b.x + tile) {
                var s = 0.0, c = 0
                for dy in -radius...radius {
                    for dx in -radius...radius { s += at(x + dx, y + dy); c += 1 }
                }
                let d = at(x, y) - s / Double(c)
                sum += d * d; n += 1
            }
        }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    private func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[s.count / 2]
    }

    /// Laplacian RMS over the pixels that A calls shadow (`luma < 25` display codes).
    private func shadowDetail(_ luma: [Double], w: Int, h: Int, mask: [Bool]) -> Double {
        func at(_ x: Int, _ y: Int) -> Double { luma[y * w + x] }
        var sum = 0.0, n = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                guard mask[y * w + x] else { continue }
                let lap = 4 * at(x, y) - at(x - 1, y) - at(x + 1, y) - at(x, y - 1) - at(x, y + 1)
                sum += lap * lap; n += 1
            }
        }
        return n > 0 ? (sum / Double(n)).squareRoot() : 0
    }

    private struct RGB { var r = 0.0; var g = 0.0; var b = 0.0 }

    private func meanRGB(_ image: DisplayImage, _ b: Block, tile: Int = 32) -> RGB {
        var out = RGB()
        var n = 0.0
        for y in b.y..<min(b.y + tile, image.height) {
            for x in b.x..<min(b.x + tile, image.width) {
                let o = (y * image.width + x) * 4
                out.r += Double(image.rgba[o]); out.g += Double(image.rgba[o + 1])
                out.b += Double(image.rgba[o + 2]); n += 1
            }
        }
        out.r /= n; out.g /= n; out.b /= n
        return out
    }

    /// Five 32 × 32 blocks of A with the least chroma — the "neutral patches" the colour cast is
    /// measured on. ΔE00 is CIEDE2000 on encoded sRGB, the same helper the W/B suite uses.
    private func neutralBlocks(_ image: DisplayImage) -> [Block] {
        let tile = 32
        var candidates: [(Block, Double)] = []
        var y = 8
        while y + tile < image.height - 8 {
            var x = 8
            while x + tile < image.width - 8 {
                var s = RGB(), n = 0.0
                for yy in y..<(y + tile) {
                    for xx in x..<(x + tile) {
                        let o = (yy * image.width + xx) * 4
                        s.r += Double(image.rgba[o]); s.g += Double(image.rgba[o + 1])
                        s.b += Double(image.rgba[o + 2]); n += 1
                    }
                }
                s.r /= n; s.g /= n; s.b /= n
                let mean = 255 * (0.2126 * s.r + 0.7152 * s.g + 0.0722 * s.b)
                let chroma = 255 * (max(s.r, max(s.g, s.b)) - min(s.r, min(s.g, s.b)))
                if mean >= 20 && mean <= 220 {
                    candidates.append((Block(x: x, y: y), chroma))
                }
                x += tile
            }
            y += tile
        }
        return candidates.sorted { $0.1 < $1.1 }.prefix(5).map(\.0)
    }

    private func deltaE(_ a: RGB, _ b: RGB) -> Double {
        PointColorDeltaE.deltaE00(SIMD3(a.r, a.g, a.b), SIMD3(b.r, b.g, b.b))
    }

    // MARK: - black level, 094's own estimator

    /// 094's measurement, in the working space, on the **decode buffer** — not on a Core Image
    /// render (which clamps the negatives away, §1.5.1b).
    private func blackLevel(_ image: LinearImage) -> (darkest: Float, offset: Double, before: Double, after: Double) {
        let darkest = image.darkestBelowBlack(sampleStride: 1)
        let raw = darkest >= 0 ? 0 : -Double(darkest)
        let stepped = (raw * 1000).rounded(.up) / 1000
        let offset = min(max(stepped, LightGroup.blackOffsetRange.lowerBound),
                         LightGroup.blackOffsetRange.upperBound)

        let m = ColorPrimaries.conversion(from: .decoded, to: .working)
        var before = 0, after = 0, total = 0
        for i in stride(from: 0, to: image.width * image.height, by: 2) {
            let o = i * 4
            let v = m.applying(to: SIMD3(Double(image.rgba[o]),
                                         Double(image.rgba[o + 1]),
                                         Double(image.rgba[o + 2])))
            if v.x < 0 && v.y < 0 && v.z < 0 { before += 1 }
            if v.x + offset < 0 && v.y + offset < 0 && v.z + offset < 0 { after += 1 }
            total += 1
        }
        return (darkest, offset,
                Double(before) / Double(max(total, 1)),
                Double(after) / Double(max(total, 1)))
    }

    // MARK: - the A/B

    /// The kernel's own full-frame model, read back from a shared copy of the decode — the same
    /// numbers `s1_65_apply` clamps with.
    private struct ProbeParams {
        var canvas: SIMD4<Int32>
        var grid: SIMD4<Int32>
        var n: SIMD4<Float>
        var fit: SIMD4<Float>
    }

    private func noiseModel(_ image: LinearImage) throws -> SIMD4<Float> {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                            width: image.width,
                                                            height: image.height,
                                                            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let src = try XCTUnwrap(device.makeTexture(descriptor: desc))
        // The kernel runs on S1.6's buffer, which is the **working** primaries: convert the decode
        // the same way S0 does, so the fit the report quotes is the fit the pass used (§1.5.1b's rule
        // — never measure a Core Image render, which clamps the negatives away).
        let m = ColorPrimaries.conversion(from: .decoded, to: .working)
        var work = [Float16](repeating: 0, count: image.width * image.height * 4)
        for i in 0..<(image.width * image.height) {
            let o = i * 4
            let v = m.applying(to: SIMD3(Double(image.rgba[o]),
                                         Double(image.rgba[o + 1]),
                                         Double(image.rgba[o + 2])))
            work[o] = Float16(v.x); work[o + 1] = Float16(v.y); work[o + 2] = Float16(v.z)
            work[o + 3] = image.rgba[o + 3]
        }
        work.withUnsafeBytes { raw in
            src.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: image.width * 8)
        }
        let mdesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                                                             width: 1, height: 1, mipmapped: false)
        mdesc.usage = [.shaderRead, .shaderWrite]
        mdesc.storageMode = .shared
        let model = try XCTUnwrap(device.makeTexture(descriptor: mdesc))
        var p = ProbeParams(canvas: SIMD4(Int32(image.width), Int32(image.height), 8, 40),
                            grid: SIMD4(0, 0, 0, 0),
                            n: SIMD4(0.5, Float(1.0 / 65536.0), -16, 4),
                            fit: .zero)
        let pipeline = try KernelLibrary(device: device)
            .pipeline(file: "s1_65_denoise", function: "s1_65_noise_model")
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
        return SIMD4(fit[0], fit[1], fit[2], fit[3])
    }

    // MARK: - full-size cost (opt-in: PHOTONS_A365_FULL=1)

    /// The ticket's §4.6 number: the new pass at 9520 × 6336, and its share of the whole frame.
    /// Opt-in because a 60 Mpx decode plus two 300 MB grids is not something every test run should
    /// pay for; the three-file A/B above is the always-on acceptance.
    func testFullSizeStageCost() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_A365_FULL"] != nil else {
            throw XCTSkip("set PHOTONS_A365_FULL=1 for the 60 Mpx cost probe")
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let url = photos[1].url
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no L1030437") }
        let decoded = try RAWDecoder().decodeForMeasurement(url, scale: 1)
        let graph = try RenderGraph(input: RenderInput(image: decoded, identity: "ab365-full",
                                                       sourceURL: url))
        let a = document(offset: 0, linear: 0, lumaNR: 0, chromaNR: 0)
        let (_, frameMS) = try render(graph, a)

        let w = decoded.width, h = decoded.height
        let srcDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                               width: w, height: h, mipmapped: false)
        srcDesc.usage = [.shaderRead, .shaderWrite]
        srcDesc.storageMode = .shared
        let src = try XCTUnwrap(device.makeTexture(descriptor: srcDesc))
        decoded.rgba.withUnsafeBytes { raw in
            src.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: w * 8)
        }
        let cell = 8, zBins = 40
        let gW = (w + cell - 1) / cell, gH = (h + cell - 1) / cell
        func tex(_ px: MTLPixelFormat, _ tw: Int, _ th: Int, _ td: Int = 1) throws -> MTLTexture {
            let d = MTLTextureDescriptor()
            d.textureType = td > 1 ? .type3D : .type2D
            d.pixelFormat = px
            d.width = tw; d.height = th
            if td > 1 { d.depth = td }
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = td > 1 ? .private : .shared
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        let model = try tex(.rgba32Float, 1, 1)
        let gridA = try tex(.rgba16Float, gW, gH, zBins)
        let gridB = try tex(.rgba16Float, gW, gH, zBins)
        let dst = try tex(.rgba16Float, w, h)
        var p = ProbeParams(canvas: SIMD4(Int32(w), Int32(h), Int32(cell), Int32(zBins)),
                            grid: SIMD4(Int32(gW), Int32(gH), 0, 0),
                            n: SIMD4(0.5, Float(1.0 / 65536.0), -16, 4),
                            fit: .zero)
        let lib = KernelLibrary(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        do {
            let e = try XCTUnwrap(cb.makeComputeCommandEncoder())
            e.setComputePipelineState(try lib.pipeline(file: "s1_65_denoise",
                                                       function: "s1_65_noise_model"))
            e.setTexture(src, index: 0); e.setTexture(model, index: 1)
            e.setBytes(&p, length: MemoryLayout<ProbeParams>.stride, index: 0)
            e.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            e.endEncoding()
        }
        do {
            let e = try XCTUnwrap(cb.makeComputeCommandEncoder())
            e.setComputePipelineState(try lib.pipeline(file: "s1_65_denoise",
                                                       function: "s1_65_splat"))
            e.setTexture(src, index: 0); e.setTexture(model, index: 1)
            e.setTexture(gridA, index: 2)
            e.setBytes(&p, length: MemoryLayout<ProbeParams>.stride, index: 0)
            e.dispatchThreadgroups(MTLSize(width: gW, height: gH, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: cell, height: cell, depth: 1))
            e.endEncoding()
        }
        do {
            let e = try XCTUnwrap(cb.makeComputeCommandEncoder())
            e.setComputePipelineState(try lib.pipeline(file: "s1_65_denoise",
                                                       function: "s1_65_blur_xy"))
            e.setTexture(gridA, index: 0); e.setTexture(gridB, index: 1)
            e.setBytes(&p, length: MemoryLayout<ProbeParams>.stride, index: 0)
            e.dispatchThreadgroups(MTLSize(width: (gW + 15) / 16, height: (gH + 15) / 16,
                                           depth: zBins),
                                   threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            e.endEncoding()
        }
        do {
            let e = try XCTUnwrap(cb.makeComputeCommandEncoder())
            e.setComputePipelineState(try lib.pipeline(file: "s1_65_denoise",
                                                       function: "s1_65_apply"))
            e.setTexture(src, index: 0); e.setTexture(model, index: 1)
            e.setTexture(gridB, index: 2); e.setTexture(dst, index: 3)
            e.setBytes(&p, length: MemoryLayout<ProbeParams>.stride, index: 0)
            e.dispatchThreadgroups(MTLSize(width: (w + 31) / 32, height: (h + 31) / 32, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: 32, height: 32, depth: 1))
            e.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)
        let stageMS = (cb.gpuEndTime - cb.gpuStartTime) * 1000
        print(String(format: "AB365 full %dx%d · S1.65 %.2f ms · frame %.2f ms · share %.1f%%",
                     w, h, stageMS, frameMS, 100 * stageMS / max(frameMS, 1e-9)))
    }

    func testSixGroupABOnTheThreeFiles() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let available = photos.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !available.isEmpty else { throw XCTSkip("none of the three RAW files is present") }

        let decoder = try RAWDecoder()
        for photo in available {
            let decoded = try decoder.decodeForMeasurement(photo.url, scale: scale)
            let bl = blackLevel(decoded)
            let fit = try noiseModel(decoded)
            print(String(format: "\nAB365 · %@ · darkest %.6f · auto blackOffset %+.4f · all-negative %.4f%% → %.4f%%",
                         photo.name, bl.darkest, bl.offset, bl.before * 100, bl.after * 100))
            print(String(format: "AB365 model · a %.6g · b %.6g · residual %.6g · entry-clamped %.4f%%",
                         fit.x, fit.y, fit.z, fit.w * 100))

            let graph = try RenderGraph(input: RenderInput(image: decoded, identity: "ab365-\(photo.name)",
                                                           sourceURL: photo.url))
            let docs: [(String, EditModel)] = [
                ("A0", document(offset: 0, linear: 0, lumaNR: 0, chromaNR: 0)),
                ("A", document(offset: bl.offset, linear: 0, lumaNR: 0, chromaNR: 0)),
                ("B", document(offset: 0, linear: 0, lumaNR: 50, chromaNR: 0)),
                ("C0", document(offset: 0, linear: 0.5, lumaNR: 0, chromaNR: 0)),
                ("C", document(offset: bl.offset, linear: 0.5, lumaNR: 0, chromaNR: 0)),
                ("D", document(offset: bl.offset, linear: 0.5, lumaNR: 0, chromaNR: 50)),
            ]

            // Warm the graph once; the first frame pays the kernel-pipeline compile.
            _ = try render(graph, docs[0].1)
            var images: [String: DisplayImage] = [:]
            var lumas: [String: [Double]] = [:]
            var costs: [String: Double] = [:]
            for (name, edit) in docs {
                let (image, ms) = try render(graph, edit)
                images[name] = image
                lumas[name] = luma(image)
                costs[name] = ms
            }

            let w = decoded.width, h = decoded.height
            let aLuma = lumas["A"]!
            let flats = flattest(aLuma, w: w, h: h, count: 5)
            let darkFlats = flattest(aLuma, w: w, h: h, count: 5, lumaRange: 2...60)
            let highs = flattest(aLuma, w: w, h: h, count: 5, lumaRange: 200...255)
            let shadowMask = aLuma.map { $0 < 25 }
            let neutral = neutralBlocks(images["A"]!)
            let aMeans = neutral.map { meanRGB(images["A"]!, $0) }
            print("AB365 flats · " + flats.map {
                String(format: "(%d,%d)%.1f", $0.x, $0.y, blockMean(aLuma, w: w, $0))
            }.joined(separator: " ")
                + " · highs " + (highs.isEmpty ? "none" : highs.map {
                    String(format: "(%d,%d)%.1f", $0.x, $0.y, blockMean(aLuma, w: w, $0))
                }.joined(separator: " ")))

            var flatSigma: [String: Double] = [:]
            var highSigma: [String: Double] = [:]
            var shadowE: [String: Double] = [:]
            var cast: [String: Double] = [:]
            for (name, _) in docs {
                let l = lumas[name]!
                flatSigma[name] = median(flats.map { highPassSigma(l, w: w, h: h, $0) })
                highSigma[name] = highs.isEmpty ? 0
                    : median(highs.map { highPassSigma(l, w: w, h: h, $0) })
                shadowE[name] = shadowDetail(l, w: w, h: h, mask: shadowMask)
                let means = neutral.map { meanRGB(images[name]!, $0) }
                cast[name] = zip(means, aMeans).map(deltaE).reduce(0, +) / Double(max(means.count, 1))
            }

            print("AB365 group  all-neg%  flatσ  flat/A  shadow/A  ΔE00(A)  highσ  gpu ms  ΔvsA")
            for (name, _) in docs {
                let neg = name == "A0" || name == "B" || name == "C0" ? bl.before : bl.after
                let fs = flatSigma[name]!
                let sa = shadowE["A"]! > 0 ? shadowE[name]! / shadowE["A"]! : 0
                let hs = highSigma[name]!
                let ha = highSigma["A"]! > 0 ? hs / highSigma["A"]! : 0
                print(String(format: "AB365 %-4@ %8.4f %7.3f %7.3f %8.3f %8.3f %7.3f %7.2f %7.2f",
                             name as NSString, neg * 100, fs, fs / max(flatSigma["A"]!, 1e-9),
                             sa, cast[name]!, ha, costs[name]!, costs[name]! - costs["A"]!))
            }
            if !darkFlats.isEmpty {
                let sig = ["A0", "A", "C0", "C"].map { name in
                    median(darkFlats.map { highPassSigma(lumas[name]!, w: w, h: h, $0) })
                }
                print(String(format: "AB365 dark flats · A0 %.3f · A %.3f · C0 %.3f · C %.3f",
                             sig[0], sig[1], sig[2], sig[3]))
            }
            // Acceptance §5.3 — the same document, a fresh graph: the off path must be the same bytes.
            let fresh = try RenderGraph(input: RenderInput(image: decoded,
                                                            identity: "ab365-\(photo.name)-fresh",
                                                            sourceURL: photo.url))
            let (a0Again, _) = try render(fresh, docs[0].1)
            print("AB365 off sha \(images["A0"]!.sha256()) / \(a0Again.sha256())")
            XCTAssertEqual(images["A0"]!.sha256(), a0Again.sha256())
            // The ticket's directional targets, on the group it names.
            if let aSigma = flatSigma["A"], let cSigma = flatSigma["C"] {
                XCTAssertLessThan(cSigma, aSigma, "C must be quieter than A on flat patches")
            }
            if let cE = cast["C"] { XCTAssertLessThan(cE, 3.0, "C's neutral ΔE00 should stay near 0") }
            // And the reverse gate: removing the black offset must bring the quadruple-negatives back.
            XCTAssertEqual(bl.after, 0, accuracy: 1e-9,
                           "the automatic offset covers every three-channel-negative sample")
        }
    }
}
