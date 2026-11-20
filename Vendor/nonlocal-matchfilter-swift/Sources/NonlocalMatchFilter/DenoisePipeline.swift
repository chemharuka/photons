//
//  DenoisePipeline.swift
//
//  DNG in, DNG out, through Core ML.
//
//      read DNG            (SourceDNG + SourceDNGDecode)
//        → black/white/CFA from the file, never hard-coded   (DNGMetadata)
//        → normalise to [0,1]
//        → run the tile grid through Core ML                  (CoreMLDenoiser)
//        → de-normalise to UInt16
//        → write a DNG that copies every tag but the pixel tags (DNGRawWriter)
//
//  Geometry invariants (the same ones the reference implementation documents,
//  because they are what turns a mosaic into a checkerboard if broken):
//
//    1. padding is right/bottom only, so the CFA phase at (0,0) never moves;
//    2. the crop back to the original size is exact;
//    3. the CFA handed to the packer describes *this* mosaic's (0,0);
//    4. the samples handed to the writer are in the same UInt16 range as the
//       ones read, i.e. black and white levels are the file's own.
//

import Foundation

public struct DenoiseRequest {
    public var input: URL
    public var output: URL
    public var mlpackage: String
    /// Per-CFA-plane Poisson-Gaussian coefficients, `Var = a·x + b` on [0,1],
    /// in the model's R, G, B, G plane order.
    public var a: [Double]
    public var b: [Double]
    /// `out = in + strength·(denoised − in)` in the normalised domain.
    ///
    /// `nil` (the default) derives it from the frame's own curve via
    /// `NLMFStrength` — the same value cannot suit ISO 800 and ISO 3200. The
    /// report says which value was used.
    public var strength: Double?
    /// Unreliable border to discard from each tile, in **plane** pixels.
    ///
    /// The network's edge pixels disagree with a differently-anchored grid
    /// because it cannot see past the tile. Measured decay (dark region of
    /// L1030580, seam error vs. interior baseline): 9.0× at 0–1 px, 5.2× at
    /// 2–4 px, 3.0× at 4–8 px, 1.05× by 8–16 px. Two mosaic pixels per plane
    /// pixel, so `crop: 4` discards 8 mosaic pixels a side.
    public var crop: Int
    /// Measure the noise curve from this frame instead of trusting `a`/`b`.
    public var estimateNoise: Bool
    /// Sample half the blocks on a checkerboard when estimating. Halves the
    /// measurement cost; see `NoiseEstimator.blockStats`.
    public var checkerboardNoise: Bool
    /// Write both mosaics into one DNG: the untouched input as IFD0 and the
    /// denoised result as the alternate image behind `330 SubIFDs`.
    ///
    /// Standard readers (ImageIO, `CIRAWFilter`, Lightroom) see IFD0, i.e. the
    /// original — nothing about their behaviour changes, the denoised layer is
    /// additive. Off by default so existing callers get exactly the file they
    /// got before.
    public var dualRaw: Bool

    public init(input: URL, output: URL, mlpackage: String,
                a: [Double], b: [Double], strength: Double? = nil,
                crop: Int = 0, estimateNoise: Bool = false,
                checkerboardNoise: Bool = false, dualRaw: Bool = false) {
        self.input = input
        self.output = output
        self.mlpackage = mlpackage
        self.a = a
        self.b = b
        self.strength = strength
        self.crop = crop
        self.estimateNoise = estimateNoise
        self.checkerboardNoise = checkerboardNoise
        self.dualRaw = dualRaw
    }
}

public struct DenoiseReport: Sendable {
    public let width: Int
    public let height: Int
    public let cfa: String
    public let blackMean: Double
    public let white: Double
    public let tiles: Int
    public let tilesX: Int
    public let tilesY: Int
    public let readSeconds: Double
    public let inferenceSeconds: Double
    public let writeSeconds: Double
    public let seconds: Double
    public let outputBytes: Int
    /// Strength actually applied: the caller's, or the value `NLMFStrength` chose.
    public let strength: Double
    /// Green-plane σ at 5 % brightness that the strength was derived from.
    public let sigma: Double
    public let writerTiles: Int
    /// True when the output carries both the original (IFD0) and the denoised
    /// (SubIFD) mosaic.
    public let hasAlternate: Bool
    public let alternateBytes: Int
}

public enum PipelineError: Error, CustomStringConvertible {
    case notCFA(String)
    case decode(String)
    case badMosaic(String)
    case write(String)
    case outputMissing(String)

    public var description: String {
        switch self {
        case .notCFA(let f): return "\(f) has no CFA plane (already demosaiced?)"
        case .decode(let m): return "decode: \(m)"
        case .badMosaic(let m): return "bad mosaic: \(m)"
        case .write(let m): return "write: \(m)"
        case .outputMissing(let p): return "output not written: \(p)"
        }
    }
}

public enum DenoisePipeline {

    public static func run(_ request: DenoiseRequest,
                           progress: ((String) -> Void)? = nil) throws -> DenoiseReport {
        let t0 = Date()

        // 1. read
        let doc: SourceDNG
        let decoded: (samples: [UInt16], width: Int, height: Int)
        let data: Data
        do {
            data = try Data(contentsOf: request.input, options: .alwaysMapped)
            doc = try SourceDNG(data: data)
            decoded = try doc.readMosaic(data: data)
        } catch let e as SourceDNG.ReadError {
            if case .noRawSubIFD = e { throw PipelineError.notCFA(request.input.lastPathComponent) }
            throw PipelineError.decode(e.description)
        } catch {
            throw PipelineError.decode("\(error)")
        }

        let width = decoded.width, height = decoded.height
        guard width > 0, height > 0, decoded.samples.count == width * height else {
            throw PipelineError.badMosaic("\(width)×\(height), \(decoded.samples.count) samples")
        }

        let norm = try DNGMetadata.normalization(of: doc)
        let cfa = try DNGMetadata.cfa(of: doc, width: width, height: height)
        progress?("read \(width)×\(height) \(cfa.filePattern)"
                  + (cfa.isRotated ? " (phase at mosaic origin: \(cfa.pattern))" : ""))
        let readSeconds = Date().timeIntervalSince(t0)

        // 2. normalise
        var mosaic = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                mosaic[row + x] = norm.normalize(decoded.samples[row + x], row: y, col: x)
            }
        }

        // 3. noise model: use the caller's coefficients, or measure them here.
        //
        // Estimating from the frame costs a few seconds out of the ~70 s the
        // denoise takes, and it removes the guesswork: the shipped defaults
        // assume a full-frame sensor at moderate ISO, and on a high-ISO file
        // they understate the midtone σ by ~1.8x, which visibly under-filters.
        let layout = PackedLayout(cfa: cfa.pattern)
        var shot = request.a
        var readNoise = request.b
        if request.estimateNoise {
            let model = mosaic.withUnsafeBufferPointer {
                NoiseEstimator.measure($0.baseAddress!, width: width, height: height,
                                       layout: layout,
                                       checkerboard: request.checkerboardNoise)
            }
            shot = model.a
            readNoise = model.b
            progress?(String(format: "noise model measured in %.1f s", model.seconds))
            for p in 0..<4 where model.blocks[p] > 0 {
                let s = model.sigma(0.05, plane: p)     // midtone sigma
                progress?(String(format: "  plane %d: a=%.3e b=%.3e  σ(0.05)=%.5f  (%d blocks)",
                                 p, model.a[p], model.b[p], s, model.blocks[p]))
            }
        }

        // The strength is decided here, once the curve is known: `nil` means "use
        // the frame's own noise", which is the default.
        let variance = shot[1] * NLMFStrength.reference + readNoise[1]
        let sigma = variance > 0 ? variance.squareRoot() : 0
        let strength = request.strength ?? NLMFStrength.strength(forSigma: sigma)
        progress?(String(format: "strength %.2f (σ(0.05)=%.5f%@)", strength, sigma,
                         request.strength == nil ? ", derived from the frame" : ""))

        // 4. denoise, tile by tile
        let den: CoreMLDenoiser
        do {
            den = try CoreMLDenoiser(mlpackage: request.mlpackage, layout: layout)
        } catch {
            throw PipelineError.decode("\(error)")
        }
        let W = den.mosaicWindow  // mosaic pixels per tile
        let T = den.planeSide

        // Crop the unreliable border off every tile before it is written back.
        //
        // The network's answer near a tile edge is conditioned on a scene it
        // cannot see past, so the outermost pixels disagree with what a
        // differently-anchored grid would produce. Measured on the dark region
        // of L1030580 (|A−B| between two grid origins, relative to the interior
        // baseline): 9.0× at 0–1 px, 5.2× at 2–4 px, 3.0× at 4–8 px, 1.05× by
        // 8–16 px. So `crop` is in *plane* pixels and the discard is 2× that many
        // mosaic pixels.
        let cropPlane = max(0, request.crop)
        let crop = cropPlane * 2                     // mosaic pixels to discard
        let stride = W - 2 * crop
        guard stride > 0 else {
            throw PipelineError.badMosaic("crop \(cropPlane) px is too large for a \(T)² tile")
        }

        // Enough tiles to cover the frame, with the last row/column of tiles
        // pulled back so it ends on the edge instead of hanging over it.
        // Tiles are placed every `stride` and the last one is pulled back to sit
        // flush with the far edge.
        //
        // Cropping has to be conditional, and this is the subtle part: the
        // discarded border exists because a tile's edge is a *seam* — a place
        // where the network saw a boundary that is not in the picture. At the
        // picture's own edge there is no seam, so cropping there would throw
        // away the only tile that covers those pixels. Measured on a 9536-wide
        // frame with crop 8: unconditional cropping leaves the last 8 columns
        // with no tile at all, and the fit that "fixes" it by adding a row of
        // tiles costs 294 inferences instead of 260.
        let coverable = max(0, width - 2 * crop)
        let coverableH = max(0, height - 2 * crop)
        let nx = max(1, (coverable + stride - 1) / stride)
        let ny = max(1, (coverableH + stride - 1) / stride)
        progress?("tiles: \(nx)×\(ny) = \(nx*ny) of \(W)² mosaic (\(T)² planes)"
                  + (cropPlane > 0 ? ", discarding \(cropPlane) px per side" : ""))

        // Accumulate rather than assign: where tiles overlap (any stride smaller
        // than the kept window) each pixel is the weighted mean of every tile
        // that saw it, weighted by its distance to that tile's edge. That is what
        // takes the seam from 9× down to 1.4×; hard cropping alone only reaches
        // 2.2×.
        let n = width * height
        let acc = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let wsum = UnsafeMutablePointer<Float>.allocate(capacity: n)
        acc.initialize(repeating: 0, count: n)
        wsum.initialize(repeating: 0, count: n)
        defer {
            acc.deinitialize(count: n); acc.deallocate()
            wsum.deinitialize(count: n); wsum.deallocate()
        }

        let inferStart = Date()
        var done = 0

        // Two scratch windows reused across tiles: one holds the gathered tile
        // (with the edge rows replicated), the other receives the denoised
        // result. Allocating these per tile was 2 × 4 MB of churn per tile.
        let tileBuf = UnsafeMutablePointer<Float>.allocate(capacity: W * W)
        let outBuf = UnsafeMutablePointer<Float>.allocate(capacity: W * W)
        defer {
            tileBuf.deallocate()
            outBuf.deallocate()
        }

        try mosaic.withUnsafeBufferPointer { mosaicPtr in
            for ty in 0..<ny {
                for tx in 0..<nx {
                    // Anchor the last tile flush with the far edge; all others sit
                    // at their stride position.
                    let gx = tx * stride, gy = ty * stride
                    let x0 = min(gx, max(0, width - W))
                    let y0 = min(gy, max(0, height - W))
                    let x1 = min(x0 + W, width), y1 = min(y0 + W, height)

                    // Gather the tile, replicating the last row/column at the
                    // edges so the CFA phase is preserved (a centred pad
                    // would shift it).
                    let cols = x1 - x0
                    for y in 0..<W {
                        let sy = min(y0 + y, height - 1)
                        let srcRow = mosaicPtr.baseAddress! + sy * width
                        let dstRow = tileBuf + y * W
                        if cols == W {
                            dstRow.update(from: srcRow + x0, count: W)
                        } else {
                            for x in 0..<cols { dstRow[x] = srcRow[x0 + x] }
                            // replicate the last column into the pad
                            let last = dstRow[cols - 1]
                            for x in cols..<W { dstRow[x] = last }
                        }
                    }

                    try den.denoiseWindow(tileBuf, window: W,
                                          shot: shot, read: readNoise,
                                          into: outBuf)

                    // Deposit the kept window, weighted by distance to the tile
                    // edge so overlapping tiles fade into each other.
                    //
                    // The crop is applied only on sides that are interior seams.
                    // A side that sits on the picture's own edge has no seam to
                    // hide, and cropping it would leave those pixels uncovered —
                    // see the tile-count comment above.
                    let ky0 = y0 == 0 ? y0 : y0 + crop
                    let ky1 = y1 >= height ? y1 : y1 - crop
                    let kx0 = x0 == 0 ? x0 : x0 + crop
                    let kx1 = x1 >= width ? x1 : x1 - crop
                    if ky1 > ky0 && kx1 > kx0 {
                        for y in ky0..<ky1 {
                            let local = y - y0
                            let wy = Float(min(local, W - 1 - local) + 1)
                            let srcRow = outBuf + local * W
                            let accRow = acc + y * width
                            let wRow = wsum + y * width
                            for x in kx0..<kx1 {
                                let lx = x - x0
                                let w = min(wy, Float(min(lx, W - 1 - lx) + 1))
                                accRow[x] += srcRow[lx] * w
                                wRow[x] += w
                            }
                        }
                    }

                    done += 1
                    let el = Date().timeIntervalSince(inferStart)
                    if done % 10 == 0 || done == nx * ny {
                        progress?(String(format: "  %d/%d  %.1f s  %.0f ms/tile  eta %.1f s",
                                         done, nx * ny, el, el / Double(done) * 1000,
                                         el / Double(done) * Double(nx * ny - done)))
                    }
                }
            }
        }
        let inferenceSeconds = Date().timeIntervalSince(inferStart)

        // 4. normalise the weighted sum, blend with the original, then quantise.
        //
        // `strength == 1` is the pure model output; anything less pulls each
        // sample back toward the *input* mosaic (`i + s·(d − i)`). The blend has
        // to read the input, not the destination buffer, or a partial strength
        // drags the frame toward black.
        var out = [Float](repeating: 0, count: width * height)
        out.withUnsafeMutableBufferPointer { outPtr in
            mosaic.withUnsafeBufferPointer { mosaicPtr in
                let s = Float(strength)
                for i in 0..<n {
                    let w = wsum[i]
                    // No tile reached this pixel (only possible when `crop` pushes
                    // the kept windows apart): keep the source sample.
                    var d = w > 0 ? acc[i] / w : mosaicPtr[i]
                    if d < 0 { d = 0 } else if d > 1 { d = 1 }
                    outPtr[i] = s == 1 ? d : mosaicPtr[i] + s * (d - mosaicPtr[i])
                }
            }
        }
        mosaic = []

        let quantized = norm.quantized(out, width: width, height: height)

        let writeStart = Date()
        let written: DNGRawWriter.Result
        do {
            if request.dualRaw {
                // `decoded.samples` is the mosaic as quantised *before* denoising —
                // not `mosaic` (float, normalised) and not a re-quantisation of it,
                // so the primary layer round-trips the source samples exactly.
                written = try DNGRawWriter.write(
                    primary: DNGRawWriter.Layer(samples: decoded.samples),
                    alternate: DNGRawWriter.Layer(
                        samples: quantized,
                        label: "denoised alternate: nlmf-denoise "
                             + "strength=\(request.strength)"),
                    width: width, height: height,
                    from: request.input, to: request.output)
            } else {
                written = try DNGRawWriter.write(samples: quantized, width: width, height: height,
                                                 from: request.input, to: request.output)
            }
        } catch {
            throw PipelineError.write("\(error)")
        }
        guard FileManager.default.fileExists(atPath: request.output.path) else {
            throw PipelineError.outputMissing(request.output.path)
        }
        let writeSeconds = Date().timeIntervalSince(writeStart)

        return DenoiseReport(
            width: width, height: height,
            cfa: cfa.pattern,
            blackMean: norm.meanBlack, white: norm.white,
            tiles: nx * ny, tilesX: nx, tilesY: ny,
            readSeconds: readSeconds,
            inferenceSeconds: inferenceSeconds,
            writeSeconds: writeSeconds,
            seconds: Date().timeIntervalSince(t0),
            outputBytes: written.byteCount,
            strength: strength,
            sigma: sigma,
            writerTiles: written.tileCount,
            hasAlternate: written.hasAlternate,
            alternateBytes: written.alternateByteCount)
    }
}
