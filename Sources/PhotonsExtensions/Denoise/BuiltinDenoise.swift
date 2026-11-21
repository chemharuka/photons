//
//  BuiltinDenoise.swift
//
//  Photons' in-process, CPU-only denoiser: a Swift port of LightCraft's built-in denoiser
//  (`crates/denoise-core/src/nlm.rs` + the noise estimator of `builtin.rs`), MIT OR Apache-2.0.
//
//  Why a port, and what it is for
//  ------------------------------
//  The user's complaint about the existing display-referred denoise is 「高光会化开」. The reason is
//  domain, not tuning: a threshold chosen for dark noise over-smooths highlights, and a threshold
//  chosen for highlights leaves grain in shadows. LightCraft measures the sensor's Poisson-Gaussian
//  noise (`variance = a · signal + b`) from the photograph itself, applies the generalised Anscombe
//  transform so every brightness has unit noise, and only then runs non-local means over four
//  colour planes together. One threshold is then correct everywhere.
//
//  What we adapted (and what we deliberately did **not** port)
//  -----------------------------------------------------------
//  * `bayer.rs` and their demosaic are **not** ported. LightCraft runs on a Bayer mosaic and
//    demosaics after denoising; we run on the four planes we already own. For the file-to-file job
//    those are the four CFA planes from `SourceDNGDecode.readMosaic` (R/G1/G2/B), which is exactly
//    LightCraft's input — the same transform and the same filter, and the DNG writer
//    (`DNGRawWriter`) is a CFA writer, so this is the only representation that round-trips.
//  * For callers that hold a **scene-linear RGB** buffer instead (the ADR's `LinearImage`), there is
//    no mosaic to feed. `fourPlanesFromRGB` therefore builds four pseudo-planes
//    `Y = (R+2G+B)/4`, `C1 = R−G`, `C2 = B−G`, `C3 = G−Y`, rotates them with the same orthonormal
//    4×4 Hadamard, and rescales each output by the reciprocal of its noise gain so unit noise stays
//    unit noise. The trade-off is worth writing down: the CFA path is the faithful port (their four
//    planes *are* R/G1/G2/B); the RGB path is an adapter for a buffer that has already been
//    demosaiced, and it cannot recover the per-site noise correlation a mosaic has. Its test
//    (`testTheRGBFourPlaneAdapterKeepsUnitNoiseUniform`) is what keeps the scaling honest.
//  * BM3D (`bm3d.rs`), Core ML inference, `bayer.rs` and LightCraft's `lcdn` cache are out of scope
//    for this ticket; this is the NLM fallback that LightCraft itself ships when BM3D is off.
//
//  Attribution: LightCraft, MIT OR Apache-2.0 — see `THIRD_PARTY_NOTICES.md` and ADR §2b.
//

import Foundation

public enum BuiltinDenoise {

    // MARK: - Tuning (LightCraft's NLM defaults)

    /// The knobs of the non-local-means filter. The defaults are LightCraft's, which is the point:
    /// the numbers were measured on their side and changing one without a render comparison is a
    /// quality regression disguised as a tweak.
    public struct Tuning: Sendable, Equatable {
        /// Search window radius, in cells, of the first pass.
        public var search: Int
        /// Search radius of the second pass (matches are found on the first pass's cleaner picture);
        /// 0 skips it.
        public var search2: Int
        /// Threshold of the first pass for a light and for a heavily noisy photo.
        public var hLight: Float
        public var hHeavy: Float
        /// Threshold of the second pass (blended in as the noise grows).
        public var h2: Float
        /// Noise at mid-grey where the stronger settings start and where they are in full.
        public var light: Float
        public var heavy: Float
        /// The colour-difference planes' own pass (guided by the cleaned brightness plane).
        public var searchC: Int
        public var hC: Float
        /// Patch radius of the first and of the later passes.
        public var half: Int
        public var half2: Int
        /// How much looser the fallback average is (a multiple of the threshold); 0 turns it off.
        public var loose: Float
        /// Matched weight below which a cell leans on that looser average, in heavy noise.
        public var few: Float

        public init(search: Int = 3, search2: Int = 5,
                    hLight: Float = 0.3, hHeavy: Float = 0.45, h2: Float = 0.1,
                    light: Float = 0.03, heavy: Float = 0.14,
                    searchC: Int = 7, hC: Float = 1.0,
                    half: Int = 1, half2: Int = 1,
                    loose: Float = 4.0, few: Float = 0.6) {
            self.search = search
            self.search2 = search2
            self.hLight = hLight
            self.hHeavy = hHeavy
            self.h2 = h2
            self.light = light
            self.heavy = heavy
            self.searchC = searchC
            self.hC = hC
            self.half = half
            self.half2 = half2
            self.loose = loose
            self.few = few
        }

        /// 0 for a lightly noisy photo up to 1 for a heavily noisy one (LightCraft's smoothstep).
        public func strength(_ noise: Float) -> Float {
            let span = max(heavy - light, 1e-6)
            let x = min(max((noise - light) / span, 0), 1)
            return x * x * (3 - 2 * x)
        }
    }

    // MARK: - Anscombe stabilisation

    /// The generalised Anscombe transform for noise of variance `a · v + b`.
    ///
    /// After `forward` every value has noise of variance ≈1, so one threshold is equally correct in
    /// the shadows and in the highlights. `inverse` carries the usual bias correction for averaged
    /// data (LightCraft's `nlm.rs`).
    public struct Stabiliser: Sendable, Equatable {
        public let a: Float
        public let b: Float

        /// Below this the noise has no signal-dependent part worth modelling.
        static let minGain: Float = 1e-6

        public init(a: Float, b: Float) {
            self.a = a.isFinite ? max(a, 0) : 0
            self.b = b.isFinite ? max(b, 1e-12) : 1e-12
        }

        public func forward(_ v: Float) -> Float {
            guard a >= Self.minGain else { return v / b.squareRoot() }
            let x = (v + b / a) / a
            return 2 * max(x + 0.375, 0).squareRoot()
        }

        public func inverse(_ y: Float) -> Float {
            guard a >= Self.minGain else { return y * b.squareRoot() }
            let x: Float
            if y >= 1.5 {
                let i1 = 1 / y
                let i2 = 1 / (y * y)
                let root15 = Float(1.5).squareRoot()
                x = y * y / 4 + 0.25 * root15 * i1 - 11 / 8 * i2
                    + 5 / 8 * root15 * i2 * i1 - 0.125
            } else {
                x = y * y / 4 - 0.375
            }
            return a * x - b / a
        }
    }

    // MARK: - Four planes

    /// The orthonormal 4 × 4 Hadamard transform across four planes (its own inverse).
    public static func hadamard(_ planes: [[Float]]) -> [[Float]] {
        let n = planes.first?.count ?? 0
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: 4)
        guard n > 0 else { return out }
        for c in 0..<4 {
            let p = c < planes.count ? planes[c] : [Float](repeating: 0, count: n)
            for i in 0..<n { out[c][i] = p[i] }
        }
        for i in 0..<n {
            let r = out[0][i], g1 = out[1][i], g2 = out[2][i], b = out[3][i]
            out[0][i] = (r + g1 + g2 + b) / 2
            out[1][i] = (r - g1 + g2 - b) / 2
            out[2][i] = (r + g1 - g2 - b) / 2
            out[3][i] = (r - g1 - g2 + b) / 2
        }
        return out
    }

    /// Build LightCraft's four planes from a scene-linear RGB buffer: `Y`, `C1`, `C2`, `C3` above,
    /// rotated by the same Hadamard, then divided by each rotation's noise gain.
    ///
    /// With independent unit-noise RGB the four raw planes have variances 0.375, 2, 2, 0.375, so the
    /// rotation does **not** leave them unit: the four outputs come out at 0.75, 0.625, 0.625, 2.75
    /// times the input variance. The constants below are `1/sqrt` of exactly those numbers; the unit
    /// test recomputes the spread from synthetic noise instead of trusting this comment.
    public static func fourPlanesFromRGB(_ rgb: [[Float]]) -> [[Float]] {
        let n = rgb.first?.count ?? 0
        guard n > 0, rgb.count >= 3 else {
            return [[Float]](repeating: [Float](repeating: 0, count: n), count: 4)
        }
        var raw = [[Float]](repeating: [Float](repeating: 0, count: n), count: 4)
        let r = rgb[0], g = rgb[1], b = rgb[2]
        for i in 0..<n {
            let y = (r[i] + 2 * g[i] + b[i]) / 4
            raw[0][i] = y
            raw[1][i] = r[i] - g[i]
            raw[2][i] = b[i] - g[i]
            raw[3][i] = g[i] - y
        }
        var out = hadamard(raw)
        // 0.75, 0.625, 0.625, 2.75 — see the comment above.
        let gains: [Float] = [0.75, 0.625, 0.625, 2.75]
        for c in 0..<4 {
            let scale = 1 / gains[c].squareRoot()
            for i in 0..<n { out[c][i] *= scale }
        }
        return out
    }

    // MARK: - Noise estimation (builtin.rs: noise_model / fit_noise)

    /// The smallest variance used, so a clean tile is left alone instead of divided by zero.
    static let minVariance: Float = 1e-10
    /// Side of the blocks the noise level is measured over.
    static let block = 16
    /// Blocks with a mean above this (white = 1) may be clipped and say nothing about the noise.
    static let clipped: Float = 0.9

    /// `(a, b)` with `variance = a · signal + b`, measured from four planes.
    ///
    /// Each 16-cell block gives its mean and the variance of its cells' difference from their four
    /// neighbours (texture and edges only raise it), the quieter part of the variances at each
    /// brightness is the noise, and a line is fitted through those points — LightCraft's
    /// `noise_model` in `builtin.rs`.
    ///
    /// A plane is not necessarily square (a full frame is `width/2 × height/2`), so the dimensions
    /// are explicit; passing the width as both would read past a landscape plane.
    public static func estimateNoise(planes: [[Float]], width: Int, height: Int) -> (a: Float, b: Float) {
        var blocks: [(Float, Float)] = []
        blocks.reserveCapacity(planes.count * max(1, height / block) * max(1, width / block))
        for p in planes {
            guard p.count >= width * height, width > block + 1, height > block + 1 else { continue }
            p.withUnsafeBufferPointer { buf in
                var by = 1
                while by + block < height {
                    var bx = 1
                    while bx + block < width {
                        var sum: Double = 0
                        var sq: Double = 0
                        for y in by..<(by + block) {
                            for x in bx..<(bx + block) {
                                let c = buf[y * width + x]
                                let r = c - 0.25 * (buf[y * width + x - 1] + buf[y * width + x + 1]
                                                    + buf[(y - 1) * width + x] + buf[(y + 1) * width + x])
                                sum += Double(c)
                                sq += Double(r * r)
                            }
                        }
                        let cells = Double(block * block)
                        let mean = Float(sum / cells)
                        // A cell minus the mean of four neighbours has 1.25 times the variance.
                        let variance = Float(sq / cells / 1.25)
                        if mean < clipped && mean.isFinite && variance.isFinite {
                            blocks.append((mean, variance))
                        }
                        bx += block
                    }
                    by += block
                }
            }
        }
        return fitNoise(blocks)
    }

    /// Square-plane convenience (tiles are square; a full frame should pass both dimensions).
    public static func estimateNoise(planes: [[Float]], t: Int) -> (a: Float, b: Float) {
        estimateNoise(planes: planes, width: t, height: t)
    }

    /// Measure the noise of a whole mosaic (four CFA planes, row-major `width × height`).
    public static func estimateNoise(mosaic: [Float], width: Int, height: Int) -> (a: Float, b: Float) {
        guard width >= 2 * (block + 1), height >= 2 * (block + 1),
              width * height == mosaic.count, width % 2 == 0, height % 2 == 0 else {
            return (0, minVariance)
        }
        let (pw, ph) = (width / 2, height / 2)
        var planes = [[Float]](repeating: [Float](repeating: 0, count: pw * ph), count: 4)
        for c in 0..<4 {
            let (dx, dy) = (c % 2, c / 2)
            for y in 0..<ph {
                let row = (2 * y + dy) * width
                let dst = y * pw
                for x in 0..<pw {
                    planes[c][dst + x] = mosaic[row + 2 * x + dx]
                }
            }
        }
        return estimateNoise(planes: planes, width: pw, height: ph)
    }

    /// Fit `variance = a · signal + b` through `(mean, variance)` blocks: at each brightness the
    /// lower quarter of the variances is the noise, and a line is fitted through them.
    static func fitNoise(_ input: [(Float, Float)]) -> (a: Float, b: Float) {
        var blocks = input
        guard !blocks.isEmpty else { return (0, minVariance) }
        blocks.sort { $0.0 < $1.0 }
        let groups = min(max(blocks.count / 8, 1), 6)
        var points: [(Double, Double)] = []
        for g in 0..<groups {
            let lo = g * blocks.count / groups
            let hi = (g + 1) * blocks.count / groups
            guard lo < hi else { continue }
            let slice = blocks[lo..<hi]
            let mean = slice.reduce(0.0) { $0 + Double($1.0) } / Double(slice.count)
            var variances = slice.map(\.1)
            variances.sort()
            let quiet = variances[min(variances.count / 4, variances.count - 1)]
            points.append((mean, Double(quiet)))
        }
        return fitLine(points)
    }

    /// The line `variance = a · signal + b` through `(signal, variance)` points, neither negative.
    static func fitLine(_ points: [(Double, Double)]) -> (a: Float, b: Float) {
        guard !points.isEmpty else { return (0, minVariance) }
        let n = Double(points.count)
        let sx = points.reduce(0.0) { $0 + $1.0 }
        let sy = points.reduce(0.0) { $0 + $1.1 }
        let sxx = points.reduce(0.0) { $0 + $1.0 * $1.0 }
        let sxy = points.reduce(0.0) { $0 + $1.0 * $1.1 }
        let det = n * sxx - sx * sx
        var a: Double
        var b: Double
        if points.count >= 2 && abs(det) > 1e-12 {
            a = (n * sxy - sx * sy) / det
            b = (sy - a * sx) / n
        } else {
            a = 0
            b = sy / n
        }
        if a < 0 {
            a = 0
            b = sy / n
        } else if b < 0 {
            a = sxx > 0 ? sxy / sxx : 0
            b = 0
        }
        let af = Float(max(a, 0))
        let bf = b.isFinite ? max(Float(b), minVariance) : minVariance
        return (af.isFinite ? af : 0, bf)
    }

    // MARK: - Two-pass non-local means (nlm.rs)

    /// Denoise four unit-noise planes of `t × t` cells; `noise` is the photo's noise at mid-grey.
    public static func filter(planes: [[Float]], t: Int, tuning: Tuning, noise: Float) -> [[Float]] {
        let y = hadamard(planes)
        let k = tuning.strength(noise.isFinite ? noise : 0)
        // Two noisy views of one signal differ by 2 in mean square: the floor the excess counts from.
        let h1 = tuning.hLight + (tuning.hHeavy - tuning.hLight) * k
        let first = pass(guide: y, data: y, t: t,
                         p: Pass(radius: tuning.search, half: tuning.half, h: h1,
                                 floor: 2, loose: tuning.loose, few: tuning.few * k))
        if tuning.search2 == 0 || k <= 0 {
            return hadamard(first)
        }
        // The first pass's picture still carries a little noise, so the floor is 0 and the threshold
        // alone decides; the result is blended in as the noise grows.
        let second = pass(guide: first, data: y, t: t,
                          p: Pass(radius: tuning.search2, half: tuning.half2, h: tuning.h2,
                                  floor: 0, loose: 0, few: 0))
        var blended = [[Float]](repeating: [Float](repeating: 0, count: t * t), count: 4)
        for c in 0..<4 {
            for i in 0..<(t * t) {
                blended[c][i] = first[c][i] + (second[c][i] - first[c][i]) * k
            }
        }
        if tuning.searchC > 0 {
            // Matches found on the cleaned brightness plane alone, so colour is only averaged across
            // like brightness (colour noise is the cheapest to remove without losing texture).
            let guide = Array(blended[..<1])
            let colour = pass(guide: guide, data: Array(y[1...]), t: t,
                              p: Pass(radius: tuning.searchC, half: tuning.half2, h: tuning.hC,
                                      floor: 0, loose: 0, few: 0))
            for c in 1..<4 {
                for i in 0..<(t * t) {
                    let clean = colour[c - 1][i]
                    blended[c][i] += (clean - blended[c][i]) * k
                }
            }
        }
        return hadamard(blended)
    }

    /// What one pass is run with.
    struct Pass {
        let radius: Int
        let half: Int
        let h: Float
        let floor: Float
        let loose: Float
        let few: Float
    }

    /// One pass: every cell becomes the weighted average of the cells within `radius` whose patch
    /// (over all `guide` planes) is like its own. `guide` holds the planes the patches are compared
    /// on; `data` the planes that are averaged. Weights are `exp(-(excess) / h)`, `excess` being how
    /// far the mean squared patch difference is above `floor`.
    static func pass(guide: [[Float]], data: [[Float]], t: Int, p: Pass) -> [[Float]] {
        let radius = max(p.radius, 0)
        let half = max(p.half, 0)
        let pad = radius + half
        let wd = t + 2 * pad
        let paddedGuide = guide.map { padded($0, t: t, pad: pad) }
        let paddedData = data.map { padded($0, t: t, pad: pad) }
        let n = t * t
        let region = t + 2 * half
        let span = 2 * half + 1
        let planes = max(data.count, 1)
        let guideCount = max(guide.count, 1)
        let norm = 1 / (Float(span * span) * Float(guideCount))
        let wide = p.loose > 0 ? p.loose : 1

        var num = [Float](repeating: 0, count: planes * n)
        var den = [Float](repeating: 0, count: n)
        var numLoose = p.loose > 0 ? [Float](repeating: 0, count: planes * n) : []
        var denLoose = p.loose > 0 ? [Float](repeating: 0, count: n) : []
        var d = [Float](repeating: 0, count: region * region)
        var rows = [Float](repeating: 0, count: region * t)

        for oy in -radius...radius {
            for ox in -radius...radius where !(ox == 0 && oy == 0) {
                let shift = oy * wd + ox
                // Squared differences over the guide planes, for the cells and the ring the patch reaches.
                d.withUnsafeMutableBufferPointer { db in
                    for gi in 0..<guideCount {
                        paddedGuide[gi].withUnsafeBufferPointer { gp in
                            for j in 0..<region {
                                let base = (j + pad - half) * wd + pad - half
                                for i in 0..<region {
                                    let pos = base + i
                                    let other = pos + shift
                                    let diff = gp[pos] - gp[other]
                                    db[j * region + i] += diff * diff
                                }
                            }
                        }
                    }
                }
                // Sum over each cell's patch: along rows, then down columns (separable box).
                for j in 0..<region {
                    for x in 0..<t {
                        var s: Float = 0
                        for i in 0..<span { s += d[j * region + x + i] }
                        rows[j * t + x] = s
                    }
                }
                for y in 0..<t {
                    for x in 0..<t {
                        var patch: Float = 0
                        for j in 0..<span { patch += rows[(y + j) * t + x] }
                        patch *= norm
                        let excess = max(patch - p.floor, 0)
                        // Beyond this the weight is below 5e-5: not worth the exponential and sums.
                        guard excess <= 10 * p.h * wide else { continue }
                        let k = y * t + x
                        let pos = (y + pad) * wd + x + pad
                        let other = pos + shift
                        if excess <= 10 * p.h {
                            let w = expf(-excess / p.h)
                            den[k] += w
                            for c in 0..<planes {
                                num[c * n + k] += w * paddedData[c][other]
                            }
                        }
                        if p.loose > 0 {
                            let w = expf(-excess / (p.h * p.loose))
                            denLoose[k] += w
                            for c in 0..<planes {
                                numLoose[c * n + k] += w * paddedData[c][other]
                            }
                        }
                    }
                }
                // `d` accumulates one offset only, so clear it for the next offset.
                for i in 0..<d.count { d[i] = 0 }
            }
        }

        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: planes)
        for c in 0..<planes {
            for k in 0..<n {
                let own = paddedData[c][(k / t + pad) * wd + k % t + pad]
                let tight = (num[c * n + k] + own) / (den[k] + 1)
                if p.loose > 0 {
                    let loose = (numLoose[c * n + k] + own) / (denLoose[k] + 1)
                    let lean = p.few > 0 ? p.few / (den[k] + p.few) : 0
                    out[c][k] = tight + (loose - tight) * lean
                } else {
                    out[c][k] = tight
                }
            }
        }
        return out
    }

    /// A plane with `pad` cells mirrored round every edge (`t + 2 · pad` on a side).
    static func padded(_ src: [Float], t: Int, pad: Int) -> [Float] {
        let wd = t + 2 * pad
        var out = [Float](repeating: 0, count: wd * wd)
        guard t > 0 else { return out }
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<wd {
                    let sy = reflect(y - pad, t)
                    for x in 0..<wd {
                        let sx = reflect(x - pad, t)
                        o[y * wd + x] = s[sy * t + sx]
                    }
                }
            }
        }
        return out
    }

    /// Mirror an index round a plane's edges (no repeated edge cell).
    static func reflect(_ i: Int, _ n: Int) -> Int {
        guard n > 1 else { return 0 }
        let period = 2 * (n - 1)
        var v = i % period
        if v < 0 { v += period }
        return v < n ? v : period - v
    }
}
