//
//  DetailGate.swift
//  NonlocalMatchFilter
//
//  Coherence-gated fine-band blend — 564.
//
//  The network's residual is not equally trustworthy at every scale. Measured on
//  L1040080 (Leica SL3, ISO 3200, a Monet in a museum), the blend keeps 99–100 %
//  of the 3–6 px and coarser bands and only 69 % of the 1–3 px band. That finest
//  band is also where canvas weave lives (3.37 px), and its amplitude there is
//  the same as the grain's, so no per-pixel amplitude test can separate them.
//
//  What does separate them is *coherence*: a weave line is narrow-band, grain is
//  not. High-pass the input at the fine scale, average its squared envelope over
//  a 33 plane-px box, and normalise it by the frame's own grain floor:
//
//      r  = d − i
//      f  = r − G(sigma_f)(r)                  the residual's fine band
//      fi = i − G(sigma_f)(i)                  the input's fine band
//      env = sqrt(boxmean(fi², 2·BOX+1 plane px))
//      b  = brightness bin of boxmean(i, 2·BOX+1 plane px)
//      floor(b) = 15th percentile of env over pixels in brightness bin b
//      c0 = median(env_white) / p15(env_white)   for a unit white-noise field
//      C  = env / (floor(bin(x)) · c0)
//      w  = wMax · smoothstep(kneeLo, kneeHi, C)
//      out = i + s·(1 − w)·f + s·(r − f)
//
//  which is the same as `i + s·(r − w·f)`. With `wMax = 0` this is exactly the
//  historical `i + s·(d − i)`, bit for bit; that is the rollback switch.
//
//  The defaults are deliberately mild: `wMax = 0.35`, knee 1.00–1.40, and the
//  weight is flattened with two 257-px box means. A gate at 0.85 was visible as
//  a patch — one area denoised, its neighbour not — because the weight follows
//  the content (texture vs flat paint) and no smoothing can remove that. The
//  mild gate keeps the *difference* in denoising power under the eye's
//  threshold while still lifting the fine band in the shadows. Measured on
//  L1040080 the 64-px block standard deviation of `w` is 0.091 on this build,
//  against 0.313 at the 0.85 default in the dispatch.
//
//  Why a floor and not sigma(x): the first version divided env by the sensor's
//  sigma(x). That made the gate depend on whichever estimator produced `a`/`b`,
//  and the probe's curve and the engine's measured curve differ by 1.33× at the
//  weave's brightness — enough to close the gate. The floor is taken from the
//  flattest pixels of *this frame* at the same brightness (the noise estimator's
//  15 %-lower-envelope idea, moved onto `env`), so a different sigma model
//  cannot move it.
//
//  Why the bins use a box mean: grain pushes individual samples back and forth
//  across a brightness edge, so per-sample bins let a bright bin inherit the low
//  envelope tail of its neighbours and sink its p15 floor; a flat wall then
//  opens. The local mean over the same 33-px window as the envelope is the
//  brightness the scene actually has there, and it keeps the wall closed
//  (measured on L1040080: broad wall ROI +7.8 % -> +1.8 %, the narrow §4
//  window +14.1 % -> +3.6 %).
//
//  Why `c0` as well: the floor is the 15th percentile of the *same* distribution
//  that `env` comes from, so a flat area's median lands at p50/p15 ≈ 1.03, not
//  at 1.0. With a knee at 1.05 that puts a white wall inside the gate. `c0` is
//  measured once by running the identical fine-band + box operator on a unit
//  white-noise field, and divides it out, so the flattest pixels of any frame
//  sit at C = 1.0 and only pixels that are coherent *above* their own grain
//  floor open the gate. Measured on L1040080 the white wall sits at C ≈ 1.0
//  (p50) and the weave window at ≈ 1.3.
//
//  Units. This gate works on one CFA plane at a time: a mosaic is gathered per
//  site, gated, and scattered back by the pipeline. Filtering the interleaved
//  mosaic directly mixes colours into a 2-px checkerboard and makes every pixel
//  look coherent, so `sigma`, `box` and the smoothing are all in plane pixels
//  here (1.5, 16 and 12 respectively; the coherence window is 2·16+1 = 33 px).
//

import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

public enum DetailGate {

    /// Everything the gate needs. `gate` is the maximum fraction of the residual's
    /// fine band to suppress; `knee` is in units of the normalised envelope.
    public struct Parameters: Sendable, Equatable {
        /// `wMax`; 0 disables the gate and reproduces the old blend exactly.
        public var gate: Double
        /// Lower and upper knees of the smoothstep on the coherence envelope.
        public var kneeLow: Double
        public var kneeHigh: Double
        /// Gaussian sigma for the fine band, in **plane** pixels (1.5 = 3 mosaic px).
        public var sigma: Double
        /// Coherence box **half-width** in plane pixels; the window is
        /// `2·box + 1`. The box averages the squared fine band, so a larger box
        /// makes the envelope steadier; 16 gives the 33-px window measured on
        /// L1040080.
        public var box: Int

        public init(gate: Double = 0.35,
                    kneeLow: Double = 1.00,
                    kneeHigh: Double = 1.40,
                    sigma: Double = 1.5,
                    box: Int = 16) {
            self.gate = gate
            self.kneeLow = kneeLow
            self.kneeHigh = kneeHigh
            self.sigma = sigma
            self.box = box
        }

        public static let off = Parameters(gate: 0)

        public var isActive: Bool { gate > 0 && sigma > 0 }
    }

    /// Extra smoothing radius (plane px) on the finished weight.
    ///
    /// A narrow smoothing only removes the box-sized ripple; it cannot hide the
    /// *content* pattern (textured canvas vs flat wall), and the gate then reads
    /// as a patch. Two successive box means of half-width 128 plane px (a
    /// 257-px window each; Gaussian-equivalent to sigma ≈ 128) spread the weight
    /// over hundreds of pixels, which is what caps the 64-px block standard
    /// deviation of `w` at 0.091 on L1040080 (564 §9). The cost is O(N) per
    /// pass regardless of the radius.
    static let weightSmoothing = 128
    static let weightSmoothingPasses = 2

    /// Brightness bins used by the floor. Boundaries are brightness quantiles of
    /// the plane, so every bin holds roughly the same number of pixels and none
    /// is empty by construction.
    static let brightnessBins = 32
    /// Fraction of a brightness bin that defines its grain floor.
    static let floorPercentile = 0.15

    // MARK: - Public entry points

    /// Apply the gate to one CFA plane, in place.
    ///
    /// - Parameters:
    ///   - input: one CFA plane of the mosaic the network saw (`i`), row-major.
    ///   - denoised: the model field (`d`), same layout; replaced by the blend.
    ///   - strength: the per-pixel blend weight `s(x)`. The historical paths use
    ///     a constant or a taper of the input value.
    ///   - mask: optional per-pixel validity (e.g. `wsum`). Pixels whose mask is
    ///     not positive are left exactly as they were.
    /// - Returns: mean gate weight over the frame (for the report).
    @discardableResult
    public static func blend(input: [Float],
                             denoised: inout [Float],
                             width: Int,
                             height: Int,
                             strength: (Float) -> Float,
                             parameters: Parameters,
                             mask: [Float]? = nil) -> Double {
        return blend(input: input, denoised: &denoised, width: width,
                     height: height, strength: strength,
                     parameters: parameters, mask: mask, weights: nil)
    }

    /// Same as `blend`, but also returns the finished weight field `w(x)`.
    /// Used by `--dump-gate` to measure the gate's spatial smoothness without
    /// running the filter a second time.
    public static func blendRecordingWeights(
        input: [Float],
        denoised: inout [Float],
        width: Int,
        height: Int,
        strength: (Float) -> Float,
        parameters: Parameters,
        mask: [Float]? = nil
    ) -> (meanWeight: Double, weights: [Float]) {
        var weights = [Float](repeating: 0, count: max(0, width * height))
        let mean = weights.withUnsafeMutableBufferPointer { buf in
            blend(input: input, denoised: &denoised, width: width,
                  height: height, strength: strength, parameters: parameters,
                  mask: mask, weights: buf.baseAddress)
        }
        return (mean, weights)
    }

    private static func blend(input: [Float],
                              denoised: inout [Float],
                              width: Int,
                              height: Int,
                              strength: (Float) -> Float,
                              parameters: Parameters,
                              mask: [Float]?,
                              weights: UnsafeMutablePointer<Float>?) -> Double {
        let n = width * height
        guard width > 0, height > 0,
              input.count == n, denoised.count == n else { return 0 }

        // `gate == 0` is the rollback switch. Reproduce the historical loop
        // exactly, including its `s == 1` shortcut, rather than relying on
        // arithmetic that happens to round the same way.
        guard parameters.isActive else {
            input.withUnsafeBufferPointer { iPtr in
                denoised.withUnsafeMutableBufferPointer { dPtr in
                    for p in 0..<n {
                        if let mask, !(mask[p] > 0) { continue }
                        let i = iPtr[p]
                        let d = dPtr[p]
                        let s = strength(i)
                        dPtr[p] = s == 1 ? d : i + s * (d - i)
                    }
                }
            }
            return 0
        }

        let kernel = gaussianKernel(sigmaMosaic: parameters.sigma)
        let boxHalf = max(1, parameters.box)
        let k0 = parameters.kneeLow
        let k1 = max(parameters.kneeHigh, parameters.kneeLow + 1e-9)
        let gate = parameters.gate

        var fine = [Float](repeating: 0, count: n)
        var work = [Float](repeating: 0, count: n)

        // f = r − G(r), with r = d − i.
        for p in 0..<n { fine[p] = denoised[p] - input[p] }
        work.withUnsafeMutableBufferPointer { dst in
            fine.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress!, count: n)
            }
            blurInPlace(dst.baseAddress!, width: width, height: height, kernel: kernel)
        }
        for p in 0..<n { fine[p] = (denoised[p] - input[p]) - work[p] }

        // env = sqrt(boxmean((i − G(i))²)), then C = env / (floor(bin)·c0).
        let c0 = whiteNoiseFloorRatio(sigmaMosaic: parameters.sigma, boxHalf: boxHalf)
        var coherence = inputEnvelope(input, width: width, height: height,
                                      kernel: kernel, boxHalf: boxHalf)
        // The bins are equal-population brightness bins of the *local mean*, not
        // of single samples: grain scatters individual samples across a
        // brightness edge, which lets a bright bin inherit the low envelope tail
        // of its neighbours and sink its p15 floor, opening the gate on a flat
        // wall. The local mean over the same 33-px window is the brightness the
        // scene has there. `work` still holds the blurred residual, which is no
        // longer needed, so this reuses its storage instead of allocating a
        // fourth full-plane buffer.
        work = input
        work.withUnsafeMutableBufferPointer { buf in
            boxMeanInPlace(buf.baseAddress!, width: width, height: height,
                           half: boxHalf)
        }
        normaliseToFloor(&coherence, brightness: work,
                         binCount: brightnessBins, zeroPoint: c0)

        // Turn C into the weight, then soften it. The box already makes the
        // field continuous; the extra smoothing removes the box-sized ripple of
        // a periodic texture (a 6.8 px weave samples the 33 px window
        // unevenly) so adjacent pixels never step visibly.
        for p in 0..<n {
            coherence[p] = Float(gate * smoothstep(Double(coherence[p]), k0, k1))
        }
        coherence.withUnsafeMutableBufferPointer { buf in
            let ptr = buf.baseAddress!
            for _ in 0..<weightSmoothingPasses {
                boxMeanInPlace(ptr, width: width, height: height,
                               half: weightSmoothing)
            }
        }

        var sumWeight = 0.0
        var counted = 0
        input.withUnsafeBufferPointer { iPtr in
            denoised.withUnsafeMutableBufferPointer { dPtr in
                fine.withUnsafeBufferPointer { fPtr in
                    coherence.withUnsafeBufferPointer { wPtr in
                        for y in 0..<height {
                            let row = y * width
                            for x in 0..<width {
                                let p = row + x
                                let w = wPtr[p]
                                weights?[p] = w
                                if let mask, !(mask[p] > 0) { continue }
                                let i = iPtr[p]
                                let d = dPtr[p]
                                let s = strength(i)
                                if w > 0 {
                                    let r = d - i
                                    dPtr[p] = i + s * (r - w * fPtr[p])
                                } else {
                                    // Exact historical value at zero weight.
                                    dPtr[p] = s == 1 ? d : i + s * (d - i)
                                }
                                sumWeight += Double(w)
                                counted += 1
                            }
                        }
                    }
                }
            }
        }
        return counted > 0 ? sumWeight / Double(counted) : 0
    }

    /// Coherence envelope `C` for a field, before the smoothstep. Exposed for
    /// measurements; `blend` uses the same path.
    public static func envelope(input: [Float], width: Int, height: Int,
                                parameters: Parameters) -> [Float] {
        let n = width * height
        guard parameters.isActive, width > 0, height > 0, n == input.count else {
            return [Float](repeating: 0, count: n)
        }
        let kernel = gaussianKernel(sigmaMosaic: parameters.sigma)
        let boxHalf = max(1, parameters.box)
        let c0 = whiteNoiseFloorRatio(sigmaMosaic: parameters.sigma, boxHalf: boxHalf)
        var c = inputEnvelope(input, width: width, height: height,
                              kernel: kernel, boxHalf: boxHalf)
        let brightness = boxMean(input, width: width, height: height,
                                 half: boxHalf)
        normaliseToFloor(&c, brightness: brightness, binCount: brightnessBins,
                         zeroPoint: c0)
        return c
    }

    /// Weight field `w(x)`, for continuity checks.
    public static func weights(input: [Float], width: Int, height: Int,
                               parameters: Parameters) -> [Float] {
        var w = envelope(input: input, width: width, height: height,
                         parameters: parameters)
        guard parameters.isActive, width > 0, height > 0 else { return w }
        let k0 = parameters.kneeLow
        let k1 = max(parameters.kneeHigh, parameters.kneeLow + 1e-9)
        for p in 0..<w.count {
            w[p] = Float(parameters.gate * smoothstep(Double(w[p]), k0, k1))
        }
        w.withUnsafeMutableBufferPointer { buf in
            let ptr = buf.baseAddress!
            for _ in 0..<weightSmoothingPasses {
                boxMeanInPlace(ptr, width: width, height: height,
                               half: weightSmoothing)
            }
        }
        return w
    }

    /// Write a mosaic-sized weight field as `<prefix>.f32` (little-endian
    /// `Float32`, row-major) plus a `<prefix>.txt` sidecar holding
    /// `width height`. This is the `--dump-gate` diagnostic: it is how the patch
    /// metric (std of 64- and 256-px block means) is measured on a real frame.
    public static func writeDump(_ weights: [Float], width: Int, height: Int,
                                 toPrefix url: URL) throws {
        // Darwin hosts are little-endian; the dump contract is little-endian
        // float32, matching every other `.f32` the tools read.
        let data = weights.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url.appendingPathExtension("f32"))
        try Data("\(width) \(height)\n".utf8)
            .write(to: url.appendingPathExtension("txt"))
    }

    // MARK: - Coherence

    /// `sqrt(boxmean(fi²))`, with `fi = i − G(sigma)(i)`.
    private static func inputEnvelope(_ input: [Float], width: Int, height: Int,
                                      kernel: [Float], boxHalf: Int) -> [Float] {
        let n = width * height
        var work = input
        work.withUnsafeMutableBufferPointer { dst in
            blurInPlace(dst.baseAddress!, width: width, height: height, kernel: kernel)
            for p in 0..<n {
                let fi = input[p] - dst[p]
                dst[p] = fi * fi
            }
            boxMeanInPlace(dst.baseAddress!, width: width, height: height, half: boxHalf)
            for p in 0..<n { dst[p] = dst[p].squareRoot() }
        }
        return work
    }

    /// Divide `env` by the per-brightness-bin grain floor and the white-noise
    /// zero point, in place. With `zeroPoint` measured by the same operator on
    /// white noise, flat grain lands at C = 1.0 rather than at p50/p15.
    private static func normaliseToFloor(_ env: inout [Float],
                                         brightness: [Float],
                                         binCount: Int,
                                         zeroPoint: Double) {
        let n = env.count
        guard n > 0, binCount > 0 else { return }
        let bins = brightnessBinMap(brightness, binCount: binCount)
        let floors = percentileFloors(env: env, bins: bins, binCount: binCount)
        let c0 = Float(zeroPoint > 0 ? zeroPoint : 1)
        for p in 0..<n {
            let scale = floors[Int(bins[p])] * c0
            env[p] = scale > 0 ? env[p] / scale : 0
        }
    }

    // MARK: - White-noise zero point

    /// `median(env_white) / p15(env_white)` for a unit white-noise field run
    /// through the same fine-band + box operator. Measured once per
    /// (sigma, box), which is O(1) for every later plane and frame.
    ///
    /// The ratio is a property of the *operator*, not of the sensor, so a
    /// different noise estimator cannot move it. Measured here at the defaults
    /// (sigma 1.5 plane px, box half 16) it is ≈1.03.
    static func whiteNoiseFloorRatio(sigmaMosaic: Double, boxHalf: Int) -> Double {
        let half = max(1, boxHalf)
        let key = "\(sigmaMosaic)|\(half)"
        cacheLock.lock()
        if let cached = zeroPointCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let value = measureWhiteNoiseFloorRatio(sigmaMosaic: sigmaMosaic, boxHalf: half)

        cacheLock.lock()
        zeroPointCache[key] = value
        cacheLock.unlock()
        return value
    }

    private static func measureWhiteNoiseFloorRatio(sigmaMosaic: Double,
                                                    boxHalf: Int) -> Double {
        // A few hundred px per side is plenty for a percentile ratio and keeps
        // the one-time cost well under a frame's gate budget. The seed is fixed
        // so the cached value is reproducible across runs.
        let side = 384
        let n = side * side
        var rng = WhiteNoiseRNG(state: 0x9E37_79B9_7F4A_7C15)
        var field = [Float](repeating: 0, count: n)
        for p in 0..<n { field[p] = Float(rng.normal()) }

        let kernel = gaussianKernel(sigmaMosaic: sigmaMosaic)
        var env = inputEnvelope(field, width: side, height: side,
                                kernel: kernel, boxHalf: boxHalf)
        env.sort()
        let p15 = env[min(n - 1, Int(Double(n) * floorPercentile))]
        let p50 = env[n / 2]
        return p15 > 0 ? Double(p50) / Double(p15) : 1
    }

    /// Deterministic normal sampler for the zero-point field (xorshift + Box–
    /// Muller, same construction as the unit tests).
    private struct WhiteNoiseRNG {
        var state: UInt64
        mutating func next() -> Double {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            let v = state &* 268_582_165_773_633_8717
            return (Double(v >> 11) + 0.5) / Double(1 << 53)
        }
        mutating func normal() -> Double {
            let u1 = next(), u2 = next()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    private static let cacheLock = NSLock()
    private static var zeroPointCache: [String: Double] = [:]

    /// Assign every pixel to one of `binCount` equal-population brightness bins.
    private static func brightnessBinMap(_ values: [Float], binCount: Int) -> [UInt8] {
        let resolution = 4096
        let n = values.count
        var hist = [Int](repeating: 0, count: resolution)
        for v in values { hist[bucket(v, resolution)] += 1 }

        // Map a fine brightness bucket to its bin by walking the cumulative
        // count. All pixels in a bucket share a bin, so the bins are equal to
        // within one brightness bucket.
        var map = [UInt8](repeating: 0, count: resolution)
        var bin = 0
        var cumulative = 0
        for b in 0..<resolution {
            map[b] = UInt8(min(bin, binCount - 1))
            cumulative += hist[b]
            while bin < binCount - 1 && cumulative >= (bin + 1) * n / binCount {
                bin += 1
            }
        }
        var out = [UInt8](repeating: 0, count: n)
        for p in 0..<n { out[p] = map[bucket(values[p], resolution)] }
        return out
    }

    /// 15th percentile of `env` inside each brightness bin. Each bin gets its
    /// own histogram range, so a bright textured area cannot coarsen the
    /// resolution of the floor in the shadows.
    private static func percentileFloors(env: [Float], bins: [UInt8],
                                         binCount: Int) -> [Float] {
        let n = env.count
        guard n > 0, binCount > 0 else { return [] }

        var binMax = [Float](repeating: 0, count: binCount)
        var globalMax: Float = 0
        for p in 0..<n {
            let b = Int(bins[p])
            if b < binCount && env[p] > binMax[b] { binMax[b] = env[p] }
            if env[p] > globalMax { globalMax = env[p] }
        }

        let buckets = 2048
        var hist = [Int](repeating: 0, count: binCount * buckets)
        var totals = [Int](repeating: 0, count: binCount)
        var globalHist = [Int](repeating: 0, count: buckets)
        for p in 0..<n {
            let b = Int(bins[p])
            if b < binCount {
                let q = quantise(env[p], max: binMax[b], buckets: buckets)
                hist[b * buckets + q] += 1
                totals[b] += 1
            }
            globalHist[quantise(env[p], max: globalMax, buckets: buckets)] += 1
        }

        let globalFloor = percentile(globalHist, total: n,
                                     max: globalMax, buckets: buckets)
        var floors = [Float](repeating: globalFloor, count: binCount)
        for b in 0..<binCount where totals[b] > 0 {
            let target = max(1, Int(Double(totals[b]) * floorPercentile))
            var cumulative = 0
            var q = 0
            let base = b * buckets
            while q < buckets {
                cumulative += hist[base + q]
                if cumulative >= target { break }
                q += 1
            }
            floors[b] = value(q, max: binMax[b], buckets: buckets)
        }
        return floors
    }

    @inline(__always)
    private static func bucket(_ value: Float, _ resolution: Int) -> Int {
        var x = value
        if !(x > 0) { x = 0 } else if x > 1 { x = 1 }
        return min(resolution - 1, Int(x * Float(resolution)))
    }

    @inline(__always)
    private static func quantise(_ value: Float, max upper: Float,
                                 buckets: Int) -> Int {
        guard upper > 0 else { return 0 }
        var x = value
        if !(x > 0) { x = 0 } else if x > upper { x = upper }
        return min(buckets - 1, Int(x / upper * Float(buckets)))
    }

    @inline(__always)
    private static func value(_ bucket: Int, max upper: Float,
                              buckets: Int) -> Float {
        guard upper > 0, buckets > 0 else { return 0 }
        // Centre of the bucket; the 0.5 keeps a floor measured at bucket 0 from
        // being exactly zero.
        return (Float(bucket) + 0.5) * upper / Float(buckets)
    }

    private static func percentile(_ hist: [Int], total: Int,
                                   max upper: Float, buckets: Int) -> Float {
        guard total > 0, upper > 0 else { return 0 }
        let target = max(1, Int(Double(total) * floorPercentile))
        var cumulative = 0
        var q = 0
        while q < buckets {
            cumulative += hist[q]
            if cumulative >= target { break }
            q += 1
        }
        return value(q, max: upper, buckets: buckets)
    }

    // MARK: - Filtering

    /// Gaussian kernel, in plane pixels, symmetric and normalised to sum 1.
    static func gaussianKernel(sigmaMosaic: Double) -> [Float] {
        let sigma = max(sigmaMosaic, 0.05)
        let radius = max(1, Int((3 * sigma).rounded(.up)))
        var k = [Float](repeating: 0, count: 2 * radius + 1)
        var sum = 0.0
        for i in 0..<k.count {
            let d = Double(i - radius)
            let v = exp(-(d * d) / (2 * sigma * sigma))
            k[i] = Float(v)
            sum += v
        }
        let inv = Float(1 / sum)
        for i in 0..<k.count { k[i] *= inv }
        return k
    }

    /// Separable Gaussian, in place, with edge replication. Both passes are
    /// contiguous reads: the vertical one gathers each column into the same
    /// scratch line, so the image needs no transpose and no second full buffer.
    static func blurInPlace(_ data: UnsafeMutablePointer<Float>,
                            width: Int, height: Int, kernel: [Float]) {
        guard width > 0, height > 0, kernel.count > 1 else { return }
        let radius = kernel.count / 2
        let n = width * height
        var scratch = [Float](repeating: 0, count: max(width, height))
        var vertical = [Float](repeating: 0, count: n)
        vertical.withUnsafeMutableBufferPointer { vBuf in
        scratch.withUnsafeMutableBufferPointer { sBuf in
            let line = sBuf.baseAddress!
            let vout = vBuf.baseAddress!
            kernel.withUnsafeBufferPointer { kBuf in
                let k = kBuf.baseAddress!
                let count = kernel.count

                // Horizontal: contiguous row in, contiguous row out.
                for y in 0..<height {
                    let row = data + y * width
                    line.update(from: row, count: width)
                    horizontalConvolve(row: row, line: line, width: width,
                                       radius: radius, kernel: k, count: count)
                }

                // Vertical: accumulate whole rows. Doing this per column through
                // vDSP's strided output was ~10x slower on a 60 MP frame; rows are
                // contiguous and vectorize.
                for y in 0..<height {
                    for x in 0..<width { line[x] = 0 }
                    for t in 0..<count {
                        let sy = min(max(y + t - radius, 0), height - 1)
                        let src = data + sy * width
                        let kv = k[t]
                        for x in 0..<width { line[x] += kv * src[x] }
                    }
                    (vout + y * width).update(from: line, count: width)
                }
            }
        }
        }
        data.update(from: vertical, count: n)
    }

    /// Box mean of a field, out of place, with the same edge-clamped window as
    /// `boxMeanInPlace`.
    static func boxMean(_ input: [Float], width: Int, height: Int,
                        half: Int) -> [Float] {
        var out = input
        out.withUnsafeMutableBufferPointer { buf in
            boxMeanInPlace(buf.baseAddress!, width: width, height: height,
                           half: half)
        }
        return out
    }

    /// Box mean, in place, with edge-clamped windows. Prefix sums per line keep
    /// this O(N) rather than O(N·box).
    static func boxMeanInPlace(_ data: UnsafeMutablePointer<Float>,
                               width: Int, height: Int, half: Int) {
        guard width > 0, height > 0, half > 0 else { return }
        let longest = max(width, height)
        var lineBuf = [Float](repeating: 0, count: longest)
        var prefixBuf = [Float](repeating: 0, count: longest + 1)
        lineBuf.withUnsafeMutableBufferPointer { lBuf in
            prefixBuf.withUnsafeMutableBufferPointer { pBuf in
                let line = lBuf.baseAddress!
                let prefix = pBuf.baseAddress!
                // Horizontal.
                for y in 0..<height {
                    let row = data + y * width
                    prefix[0] = 0
                    for x in 0..<width { prefix[x + 1] = prefix[x] + row[x] }
                    for x in 0..<width {
                        let lo = max(0, x - half)
                        let hi = min(width - 1, x + half)
                        let sum = prefix[hi + 1] - prefix[lo]
                        row[x] = sum / Float(hi - lo + 1)
                    }
                }
                // Vertical.
                for x in 0..<width {
                    for y in 0..<height { line[y] = data[y * width + x] }
                    prefix[0] = 0
                    for y in 0..<height { prefix[y + 1] = prefix[y] + line[y] }
                    for y in 0..<height {
                        let lo = max(0, y - half)
                        let hi = min(height - 1, y + half)
                        let sum = prefix[hi + 1] - prefix[lo]
                        data[y * width + x] = sum / Float(hi - lo + 1)
                    }
                }
            }
        }
    }

    /// Convolve one contiguous row, writing the interior with vDSP and the
    /// clamped edges by hand.
    @inline(__always)
    private static func horizontalConvolve(row: UnsafeMutablePointer<Float>,
                                           line: UnsafePointer<Float>,
                                           width: Int, radius: Int,
                                           kernel: UnsafePointer<Float>, count: Int) {
        let interior = width - 2 * radius
        #if canImport(Accelerate)
        if interior > 0 {
            vDSP_conv(line, 1, kernel, 1, row + radius, 1,
                      vDSP_Length(interior), vDSP_Length(count))
        }
        #else
        if interior > 0 {
            for x in radius..<(width - radius) {
                row[x] = dotClamped(line, center: x, limit: width,
                                    radius: radius, kernel: kernel, count: count)
            }
        }
        #endif
        let left = min(radius, width)
        for x in 0..<left {
            row[x] = dotClamped(line, center: x, limit: width,
                                radius: radius, kernel: kernel, count: count)
        }
        let rightStart = max(radius, width - radius)
        for x in rightStart..<width {
            row[x] = dotClamped(line, center: x, limit: width,
                                radius: radius, kernel: kernel, count: count)
        }
    }

    @inline(__always)
    private static func dotClamped(_ line: UnsafePointer<Float>,
                                   center: Int, limit: Int, radius: Int,
                                   kernel: UnsafePointer<Float>, count: Int) -> Float {
        var sum: Float = 0
        for t in 0..<count {
            let idx = min(max(center + t - radius, 0), limit - 1)
            sum += line[idx] * kernel[t]
        }
        return sum
    }

    // MARK: - Helpers

    @inline(__always)
    static func smoothstep(_ x: Double, _ a: Double, _ b: Double) -> Double {
        guard b > a else { return x >= b ? 1 : 0 }
        var t = (x - a) / (b - a)
        t = t < 0 ? 0 : (t > 1 ? 1 : t)
        return t * t * (3 - 2 * t)
    }
}
