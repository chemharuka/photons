//
//  NoiseEstimate.swift
//
//  Estimate a sensor's Poisson-Gaussian noise curve from a single raw file.
//
//  The denoiser takes `a` and `b` per CFA plane with `Var = a·x + b` on
//  [0,1]. Those are not cosmetic: they set how hard the network filters. Fed a
//  curve ~2x too high it over-smooths the shadows; fed one that is too low it
//  leaves grain behind.
//
//  Two choices decide whether the numbers are right:
//
//  1. **Measure on diagonal differences inside one CFA plane.** Neighbouring
//     mosaic samples are different colours, so their difference is dominated by
//     the scene's colour, not by noise. Diagonals of a 2×2 cell share a colour,
//     so a difference there is pure noise plus a little scene structure.
//
//  2. **Take the lower envelope of the cloud, not its mean.** Texture only ever
//     *adds* variance, so the honest noise level at a given brightness is a low
//     percentile of the estimates that land in that brightness bin. Fitting a
//     least-squares line through binned means over-estimates badly: on
//     L1030580 it produced σ 2.7× too high in the midtones, which visibly
//     over-smoothed the picture.
//
//  The MAD → σ rule is `MAD / 0.6745 / √2`: 0.6745 converts a MAD to a standard
//  deviation for a normal distribution, and √2 undoes the doubling of variance
//  that a difference of two independent samples introduces.
//

import Foundation

public struct NoiseModel: Sendable {
    /// `Var = a·x + b`, per plane, in the model's R, G, B, G order.
    public let a: [Double]
    public let b: [Double]
    /// Diagnostics worth printing: how many blocks fed each plane's fit.
    public let blocks: [Int]
    public let seconds: Double

    public func sigma(_ x: Double, plane: Int) -> Double {
        let v = a[plane] * x + b[plane]
        return v > 0 ? v.squareRoot() : 0
    }
}

public enum NoiseEstimateError: Error, CustomStringConvertible {
    case noPlanes
    case tooFewBlocks(plane: Int, blocks: Int)

    public var description: String {
        switch self {
        case .noPlanes: return "the file has no CFA planes to measure"
        case .tooFewBlocks(let p, let n):
            return "plane \(p) only yielded \(n) flat blocks; the fit would be unreliable"
        }
    }
}

/// How much of the network's answer to keep, as a function of how noisy the frame is.
///
/// The same `strength` cannot serve every ISO: 1.0 plastifies fine texture, but a
/// low value leaves a high-ISO frame's grain half-removed, and that grain is what
/// looks like detail. So the default is derived from the measured curve instead of
/// being a constant.
///
/// Anchors come from a scan of 190 Leica SL3 frames, ISO 800–3200, each fitted on
/// its own (`nlmf-lab --measure-only`). Medians of σ at 5 % brightness, green
/// plane: 800 → 0.00355, 1250 → 0.00465, 1600 → 0.00477, 2000 → 0.00569,
/// 2500 → 0.00614, 3200 → 0.00680.
public enum NLMFStrength {

    /// Brightness at which σ is compared — the same midtone point the estimator
    /// reports, so the anchors above are directly usable.
    public static let reference = 0.05

    public static let sigmaLow = 0.00355
    public static let sigmaHigh = 0.00680
    public static let strengthLow = 0.70
    public static let strengthHigh = 0.90

    /// Linear in log σ between the anchors, clamped outside them.
    ///
    /// Logs because shot noise grows with ISO multiplicatively and the eye judges
    /// grain by ratio, so a fixed σ step should move strength by a fixed amount.
    /// Keying on σ rather than on the ISO tag is deliberate: a bright ISO 3200
    /// frame measures less noise than a dark ISO 800 one, and it should be treated
    /// as the quieter frame it is. The ceiling stays at 0.90 — 1.0 plastifies.
    public static func strength(forSigma sigma: Double) -> Double {
        guard sigma > 0, sigma.isFinite else { return strengthLow }
        let t = (log(sigma) - log(sigmaLow)) / (log(sigmaHigh) - log(sigmaLow))
        return strengthLow + (strengthHigh - strengthLow) * min(max(t, 0), 1)
    }

    /// `strength` for a resolved `Var = a·x + b`, green plane.
    public static func strength(shot: [Double], read: [Double]) -> Double {
        guard shot.count > 1, read.count > 1 else { return strengthLow }
        let v = shot[1] * reference + read[1]
        return strength(forSigma: v > 0 ? v.squareRoot() : 0)
    }
}

public enum NoiseEstimator {

    /// Block edge in plane pixels. 32 gives 32×32 samples inside one CFA plane,
    /// which is large enough for a stable MAD and small enough that a block
    /// rarely straddles a texture boundary.
    public static let block = 32

    /// Brightness bins across the histogram.
    public static let bins = 40

    /// Percentile taken inside each bin — the lower envelope.
    public static let lowPercentile = 10.0

    /// Measure the whole frame.
    ///
    /// Cost on a 60 MP file is ~6 s out of the ~70 s the denoise itself takes,
    /// which is cheap enough that sampling is not needed for speed. Reducing
    /// blocks *does* matter for accuracy, though, and not in the direction you
    /// might expect: the fit needs blocks spread across every brightness level,
    /// because it regresses σ² on the block mean. Dropping blocks on a coarse
    /// regular grid (keeping every 4th row/column) thinned the dark end of the
    /// histogram first and moved `a` by ~4.5 %; keeping every 16th made the fit
    /// collapse to zero. See `checkerboard` for the sampling that does hold up.
    public static func measure(_ mosaic: UnsafePointer<Float>,
                              width: Int, height: Int,
                              layout: PackedLayout,
                              checkerboard: Bool = false) -> NoiseModel {
        let t0 = Date()
        var a = [Double](repeating: 0, count: 4)
        var b = [Double](repeating: 0, count: 4)
        var counts = [Int](repeating: 0, count: 4)

        for p in 0..<4 {
            let (dy, dx) = layout.offsets[p]
            // The plane, gathered once into a contiguous block so the inner loops
            // can stride without recomputing offsets.
            let ph = (height - dy + 1) / 2
            let pw = (width - dx + 1) / 2
            var plane = [Float](repeating: 0, count: ph * pw)
            for y in 0..<ph {
                let src = mosaic + (y * 2 + dy) * width + dx
                let dst = y * pw
                for x in 0..<pw { plane[dst + x] = src[x * 2] }
            }

            let stats = blockStats(plane, width: pw, height: ph,
                                   checkerboard: checkerboard)
            let (aa, bb) = fit(xs: stats)
            a[p] = aa
            b[p] = bb
            counts[p] = stats.count
            plane = []
        }

        return NoiseModel(a: a, b: b, blocks: counts,
                          seconds: Date().timeIntervalSince(t0))
    }

    /// Per-block (mean, sigma) pairs, skipping blocks with no measurable noise.
    ///
    /// `checkerboard` keeps half the blocks, alternating by block index in both
    /// axes. Unlike a coarser stride it thins every brightness level evenly —
    /// each 2×2 group of blocks still donates one — so the σ²-vs-mean
    /// regression keeps its dynamic range. Noise is spatially uncorrelated at
    /// block scale, so a checkerboard subsample is an unbiased sample of the
    /// (block mean, block sigma) cloud rather than a biased slice of it.
    static func blockStats(_ plane: [Float], width: Int, height: Int,
                           checkerboard: Bool = false)
        -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        out.reserveCapacity((width / block) * (height / block))
        var by = 0
        for y0 in stride(from: 0, to: height - block, by: block) {
            var bx = 0
            defer { by += 1 }
            for x0 in stride(from: 0, to: width - block, by: block) {
                defer { bx += 1 }
                if checkerboard && (bx + by) % 2 != 0 { continue }
                var sum = 0.0
                var diffs: [Double] = []
                diffs.reserveCapacity(2 * (block - 1) * (block - 1))
                for y in y0..<(y0 + block) {
                    let row = y * width
                    for x in x0..<(x0 + block) { sum += Double(plane[row + x]) }
                }
                for y in y0..<(y0 + block - 1) {
                    let row = y * width
                    let next = row + width
                    for x in x0..<(x0 + block - 1) {
                        diffs.append(Double(plane[next + x + 1]) - Double(plane[row + x]))
                        diffs.append(Double(plane[next + x]) - Double(plane[row + x + 1]))
                    }
                }
                guard !diffs.isEmpty else { continue }
                diffs.sort()
                let median = percentileOfSorted(diffs, 0.5)
                var dev = [Double](repeating: 0, count: diffs.count)
                for (i, d) in diffs.enumerated() { dev[i] = abs(d - median) }
                dev.sort()
                let mad = percentileOfSorted(dev, 0.5)
                let sigma = mad / 0.6744897501960817 / 2.0.squareRoot()
                let mean = sum / Double(block * block)
                out.append((mean, sigma))
            }
        }
        return out
    }

    /// Fit `Var = a·x + b` to the lower envelope of the cloud, with `a, b ≥ 0`.
    static func fit(xs pairs: [(Double, Double)]) -> (Double, Double) {
        guard pairs.count >= bins else { return (0, 0) }
        let sorted = pairs.sorted { $0.0 < $1.0 }
        let perBin = max(1, sorted.count / bins)

        var bx: [Double] = []
        var by: [Double] = []
        for start in stride(from: 0, to: sorted.count, by: perBin) {
            let slice = sorted[start..<min(start + perBin, sorted.count)]
            if slice.count < 20 { continue }
            var sigmas: [Double] = []
            var meanSum = 0.0
            for (m, s) in slice where s > 0 && s.isFinite {
                sigmas.append(s)
                meanSum += m
            }
            if sigmas.count < 10 { continue }
            sigmas.sort()
            let lo = percentileOfSorted(sigmas, lowPercentile / 100.0)
            bx.append(meanSum / Double(slice.count))
            by.append(lo * lo)          // variance
        }
        guard bx.count >= 3 else { return (0, 0) }

        // Ordinary least squares, then clamp: a negative intercept only means the
        // dark end is noisier than a straight line predicts, and a negative `a`
        // would make sigma fall with brightness, which has no physical basis.
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        let n = Double(bx.count)
        for i in 0..<bx.count {
            sx += bx[i]; sy += by[i]
            sxx += bx[i] * bx[i]; sxy += bx[i] * by[i]
        }
        let denom = n * sxx - sx * sx
        guard abs(denom) > 1e-18 else { return (0,0) }
        var a = (n * sxy - sx * sy) / denom
        var b = (sy - a * sx) / n
        if a < 0 { a = 0 }
        if b < 0 {
            // Pin the intercept to the darkest bins and refit the slope through
            // the origin offset.
            b = by.prefix(2).min() ?? 0
            var num = 0.0, den = 0.0
            for i in 0..<bx.count {
                num += bx[i] * (by[i] - b)
                den += bx[i] * bx[i]
            }
            a = den > 1e-18 ? num / den : 0
        }
        return (a, b)
    }

    /// Value at `q` of an already-sorted array (linear interpolation).
    static func percentileOfSorted(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let pos = q * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(lo + 1, sorted.count - 1)
        let t = pos - Double(lo)
        return sorted[lo] * (1 - t) + sorted[hi] * t
    }
}
