import Foundation

/// 143 — **our own white-balance estimate**, in scene-linear light.
///
/// The pipeline no longer predicts what `CIRAWFilter` would do with a `(Kelvin, tint)` request: the
/// decoder is left at the file's as-shot balance, and every explicit white balance is a gain **we**
/// compute and apply in S1 (`v *= gain · wb`). That removes the reason 118's measured gain table
/// existed — there is nothing to predict, so there is nothing to tabulate.
///
/// Two halves, both analytic:
///
///   1. **The illuminant** of the frame on screen. It is estimated from the decoded scene-linear
///      buffer by three independent white-point estimators — white patch, grey world and grey edge —
///      and their **per-channel median** is used. Each estimator has percentile clipping (the spec's
///      "上/下百分位裁剪"), so a hot pixel, a black corner or one saturated object cannot decide the
///      answer.
///   2. **The gain** for a requested `(Kelvin, tint)`. The request is a point in CIE 1960 uv on the
///      Planckian locus (Kim et al.'s analytic approximation) plus a perpendicular tint displacement;
///      uv → XYZ, and a **Bradford** adaptation to the working space's D65 white
///      (`ColorPrimaries.whitePoint`, never a literal here) gives the 3×3 matrix. The **channel
///      gains** are then the *one body* the mask and the eyedropper already use:
///      `WhiteBalanceSolver.gain` (linear-light Planckian fit, `WhiteBalanceSolver.localGain` on the
///      mask side). The measured illuminant only chooses the solver's reference pair — via the
///      Planckian projection — which is the part 143 adds. There is no second gain formula.
///
/// **One source of constants.** The temperature range and the nominal 6500 K are
/// `WhiteBalanceSolver`'s (`searchRange`, `nominalTemperature`); the D65 white point is
/// `ColorPrimaries.whitePoint`; the working primaries are `ColorPrimaries.working`. Nothing in this
/// file invents a second white point, a second range or a second set of primaries.
///
/// `relativeMatrix` exposes the full Bradford product for the tests and for a reader who wants the
/// cross-channel terms; the shipped S1 slot is a per-channel multiplier (061/173: `v *= gain · wb`,
/// `0 → 0`), so what crosses the CPU/GPU boundary is the solver's three normalised numbers.
public enum WhiteBalanceEstimate {

    // MARK: - values

    /// A measured illuminant in scene-linear **working** RGB, normalised so `g = 1`.
    ///
    /// `g = 1` is the same normalisation `WhiteBalanceSolver.gain` uses, so the two can be compared
    /// without a second convention. A non-finite or empty estimate is the identity (neutral).
    public struct Illuminant: Sendable, Equatable {
        public var r: Double
        public var g: Double
        public var b: Double

        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        public static let neutral = Illuminant(r: 1, g: 1, b: 1)

        /// Normalised so green is exactly 1, with a floor so a black frame cannot divide by zero.
        public var normalized: Illuminant {
            guard r.isFinite, g.isFinite, b.isFinite, g > 1e-9 else { return .neutral }
            let nr = min(max(r / g, 1.0 / 20), 20)
            let nb = min(max(b / g, 1.0 / 20), 20)
            return Illuminant(r: nr, g: 1, b: nb)
        }

        /// Largest channel deviation from the mean, as a fraction of the mean. 0 = neutral.
        public var chroma: Double {
            let m = (r + g + b) / 3
            guard m > 1e-9 else { return 0 }
            return max(abs(r - m), max(abs(g - m), abs(b - m))) / m
        }

        public var simd: SIMD3<Double> { SIMD3(r, g, b) }
    }

    /// A requested pair, already decoded from the document.
    public struct Request: Sendable, Equatable {
        public var temperature: Double
        public var tint: Double

        public init(temperature: Double, tint: Double) {
            self.temperature = temperature
            self.tint = tint
        }
    }

    // MARK: - estimation

    /// The scene's illuminant, estimated from a decoded scene-linear buffer.
    ///
    /// The three estimators are computed on a stride-sampled set (at most `sampleLimit` pixels), then
    /// combined channel by channel with a median. The stride is deterministic (the same image always
    /// samples the same pixels), so a cached render key cannot disagree with a fresh estimate.
    public static func estimate(from image: LinearImage, sampleLimit: Int = 120_000) -> Illuminant {
        let c = components(from: image, sampleLimit: sampleLimit)
        // Per-channel median of the three answers. A median (not a mean) is the point: one estimator
        // fooled by the scene moves one of three numbers, and the middle one stays put.
        func median3(_ a: Double, _ b: Double, _ c: Double) -> Double {
            max(min(a, b), min(max(a, b), c))
        }
        return Illuminant(r: median3(c.white.r, c.grey.r, c.edge.r),
                          g: median3(c.white.g, c.grey.g, c.edge.g),
                          b: median3(c.white.b, c.grey.b, c.edge.b)).normalized
    }

    /// The three estimators' answers, before the median. Exposed to the tests so "three routes, each
    /// with its own clipping" is checkable rather than a comment.
    struct Components {
        var white: Illuminant
        var grey: Illuminant
        var edge: Illuminant
    }

    static func components(from image: LinearImage, sampleLimit: Int = 120_000) -> Components {
        let w = image.width, h = image.height
        guard w > 0, h > 0, image.rgba.count == w * h * 4 else {
            return Components(white: .neutral, grey: .neutral, edge: .neutral)
        }

        let limit = max(1_000, sampleLimit)
        let stride = max(1, Int((Double(w * h) / Double(limit)).squareRoot().rounded(.up)))
        let rgba = image.rgba

        var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
        rs.reserveCapacity(min(limit, w * h / max(stride * stride, 1)) + 1)
        gs.reserveCapacity(rs.capacity)
        bs.reserveCapacity(rs.capacity)

        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let o = (y * w + x) * 4
                let a = Double(rgba[o + 3])
                let r = Double(rgba[o]), g = Double(rgba[o + 1]), b = Double(rgba[o + 2])
                if a > 0.5, r.isFinite, g.isFinite, b.isFinite {
                    let rr = max(r, 0), gg = max(g, 0), bb = max(b, 0)
                    if rr + gg + bb > 1e-9 {
                        rs.append(rr); gs.append(gg); bs.append(bb)
                    }
                }
                x += stride
            }
            y += stride
        }
        guard !rs.isEmpty else {
            return Components(white: .neutral, grey: .neutral, edge: .neutral)
        }

        // Percentiles are computed once per channel and reused by all three estimators: the clipping
        // is the same rule ("discard the tails"), only the weighting differs.
        let r01 = percentile(rs, 0.01), r99 = percentile(rs, 0.99)
        let g01 = percentile(gs, 0.01), g99 = percentile(gs, 0.99)
        let b01 = percentile(bs, 0.01), b99 = percentile(bs, 0.99)

        // (a) white patch — p99.5 per channel, after excluding pixels whose brightest channel is at or
        // above p99.99. The exclusion is what keeps a single specular pixel from becoming "the
        // illuminant"; the p99.5 is what keeps a small highlight cluster from doing it.
        let maxima = rs.indices.map { max(rs[$0], max(gs[$0], bs[$0])) }
        let hot = percentile(maxima, 0.9999)
        var wr: [Double] = [], wg: [Double] = [], wb: [Double] = []
        wr.reserveCapacity(rs.count)
        wg.reserveCapacity(rs.count)
        wb.reserveCapacity(rs.count)
        for i in rs.indices where maxima[i] < hot || hot <= 1e-12 {
            if rs[i] >= r01, rs[i] <= r99, gs[i] >= g01, gs[i] <= g99, bs[i] >= b01, bs[i] <= b99 {
                wr.append(rs[i]); wg.append(gs[i]); wb.append(bs[i])
            }
        }
        let white: Illuminant
        if wr.isEmpty {
            white = Illuminant(r: r99, g: g99, b: b99).normalized
        } else {
            white = Illuminant(r: percentile(wr, 0.995),
                               g: percentile(wg, 0.995),
                               b: percentile(wb, 0.995)).normalized
        }

        // (b) grey world — the mean of each channel inside its own 1 %…99 % range.
        func clippedMean(_ values: [Double], _ lo: Double, _ hi: Double) -> Double {
            var sum = 0.0, n = 0.0
            for v in values where v >= lo && v <= hi { sum += v; n += 1 }
            return n > 0 ? sum / n : (lo + hi) / 2
        }
        let grey = Illuminant(r: clippedMean(rs, r01, r99),
                              g: clippedMean(gs, g01, g99),
                              b: clippedMean(bs, b01, b99)).normalized

        // (c) grey edge — a first-order gradient white. Every sample is weighted by the sum of the
        // absolute channel differences to its right and lower neighbours, so a large flat coloured
        // object contributes almost nothing while its edges still do.
        var er = 0.0, eg = 0.0, eb = 0.0, ew = 0.0
        y = 0
        while y < h {
            var x = 0
            while x < w {
                let o = (y * w + x) * 4
                let r = max(Double(rgba[o]), 0), g = max(Double(rgba[o + 1]), 0)
                let b = max(Double(rgba[o + 2]), 0)
                if r + g + b > 1e-9,
                   r >= r01, r <= r99, g >= g01, g <= g99, b >= b01, b <= b99 {
                    var weight = 0.0
                    if x + stride < w {
                        let o2 = (y * w + x + stride) * 4
                        weight += abs(Double(rgba[o2]) - Double(rgba[o]))
                            + abs(Double(rgba[o2 + 1]) - Double(rgba[o + 1]))
                            + abs(Double(rgba[o2 + 2]) - Double(rgba[o + 2]))
                    }
                    if y + stride < h {
                        let o2 = ((y + stride) * w + x) * 4
                        weight += abs(Double(rgba[o2]) - Double(rgba[o]))
                            + abs(Double(rgba[o2 + 1]) - Double(rgba[o + 1]))
                            + abs(Double(rgba[o2 + 2]) - Double(rgba[o + 2]))
                    }
                    if weight > 1e-9 {
                        er += r * weight; eg += g * weight; eb += b * weight; ew += weight
                    }
                }
                x += stride
            }
            y += stride
        }
        let edge = ew > 1e-9
            ? Illuminant(r: er / ew, g: eg / ew, b: eb / ew).normalized
            : grey

        return Components(white: white, grey: grey, edge: edge)
    }

    // MARK: - the locus and the adaptation

    /// CIE 1960 UCS `(u, v)` of a black body at `kelvin` — Kim et al.'s analytic approximation,
    /// **anchored so 6500 K is the working white**.
    ///
    /// Black-body 6500 K is not exactly D65 (D65 is a daylight illuminant, slightly above the
    /// Planckian locus). A raw converter's "6500 K / tint 0" means D65, though, and the pipeline's
    /// neutral is `ColorPrimaries.whitePoint`. So the Kim curve is shifted by the constant uv vector
    /// that puts its 6500 K point on D65. Without this, every balanced frame would measure a ~+98
    /// tint (D65's Duv divided by `tintPerUnit`) and an explicit 6500 K would not be the identity.
    ///
    /// The range is `WhiteBalanceSolver.searchRange`, the same 2000…12000 K the sliders offer, so the
    /// analytic model and the document cannot disagree about "the end of the travel".
    public static func planckianUV(_ kelvin: Double) -> (u: Double, v: Double) {
        let t = min(max(kelvin, WhiteBalanceSolver.searchRange.lowerBound),
                    WhiteBalanceSolver.searchRange.upperBound)
        let (u, v) = kimUV(t)
        let anchor = d65Anchor
        return (u + anchor.u, v + anchor.v)
    }

    /// Kim et al.'s unshifted black-body curve, in CIE 1960 uv.
    private static func kimUV(_ t: Double) -> (u: Double, v: Double) {
        let denominatorU = 1 + 8.42420235e-4 * t + 7.08145163e-7 * t * t
        let denominatorV = 1 - 2.89741816e-5 * t + 1.61456053e-7 * t * t
        let u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t)
            / max(denominatorU, 1e-12)
        let v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t)
            / max(denominatorV, 1e-12)
        return (u, v)
    }

    /// uv of the working white (D65), and the shift that makes Kim's 6500 K land on it.
    private static var workingWhiteUV: (u: Double, v: Double) {
        let c = ColorPrimaries.whitePoint
        let d = -2 * c.x + 12 * c.y + 3
        return (4 * c.x / d, 6 * c.y / d)
    }

    private static let d65Anchor: (u: Double, v: Double) = {
        let white = workingWhiteUV
        let kim = kimUV(WhiteBalanceSolver.nominalTemperature)
        return (white.u - kim.u, white.v - kim.v)
    }()

    /// UV → xy. `nil` for the degenerate denominator (a hand-edited request far outside the locus).
    public static func xy(fromUV u: Double, _ v: Double) -> Chromaticity? {
        let d = 2 * u - 8 * v + 4
        guard abs(d) > 1e-9 else { return nil }
        let x = 3 * u / d, y = 2 * v / d
        guard x.isFinite, y.isFinite, y > 1e-6 else { return nil }
        return Chromaticity(x: x, y: y)
    }

    /// The tint displacement, in CIE 1960 uv per tint unit.
    ///
    /// Lightroom's positive tint is magenta, i.e. *below* the Planckian locus in CIE 1960 (green is
    /// the higher-v side). The normal is chosen to make that true; the magnitude is a display scale,
    /// not a physical constant — ±150 is a clearly visible magenta/green correction, not a different
    /// white point.
    public static let tintPerUnit = 0.00005

    /// The illuminant XYZ for a requested pair: Planckian uv + a perpendicular tint displacement.
    public static func illuminantXYZ(temperature: Double, tint: Double) -> SIMD3<Double> {
        let t = min(max(temperature, WhiteBalanceSolver.searchRange.lowerBound),
                    WhiteBalanceSolver.searchRange.upperBound)
        let (u, v) = planckianUV(t)
        // The locus normal, from a numerical tangent. +tint is magenta, which is −v.
        let (u0, v0) = planckianUV(t - 1)
        let (u1, v1) = planckianUV(t + 1)
        var nu = -(v1 - v0), nv = u1 - u0
        let n = (nu * nu + nv * nv).squareRoot()
        if n > 1e-12 { nu /= n; nv /= n } else { nu = 0; nv = 1 }
        if nv < 0 { nu = -nu; nv = -nv }       // +tint = magenta = lower v
        let du = nu * tint * tintPerUnit
        let dv = nv * tint * tintPerUnit
        let uvU = u + du, uvV = max(v + dv, 1e-4)
        let xy = xy(fromUV: uvU, uvV) ?? ColorPrimaries.whitePoint
        return xy.xyz()
    }

    private static let bradford = Matrix3(rows: [
        [0.8951, 0.2664, -0.1614],
        [-0.7502, 1.7135, 0.0367],
        [0.0389, -0.0685, 1.0296],
    ])
    private static let bradfordInverse = bradford.inverted()

    /// Bradford adaptation from `source` to `destination`, both XYZ.
    public static func bradfordAdaptation(from source: SIMD3<Double>,
                                          to destination: SIMD3<Double>) -> Matrix3 {
        let s = bradford * source
        let d = bradford * destination
        let scale = Matrix3(rows: [
            [safeRatio(d.x, s.x), 0, 0],
            [0, safeRatio(d.y, s.y), 0],
            [0, 0, safeRatio(d.z, s.z)],
        ])
        return bradfordInverse * scale * bradford
    }

    private static func safeRatio(_ a: Double, _ b: Double) -> Double {
        guard b.isFinite, abs(b) > 1e-12, a.isFinite else { return 1 }
        return a / b
    }

    /// The D65 white the pipeline works in, as XYZ. One constant, from `ColorPrimaries`.
    public static var whitePointXYZ: SIMD3<Double> { ColorPrimaries.whitePoint.xyz() }

    /// The relative gain matrix for `request`, in the working RGB primaries.
    ///
    /// `asShot` is the measured illuminant of the frame that will be multiplied. When it is `nil` (a
    /// caller with no frame, e.g. the drag preview's ratio) the reference is the nominal 6500 K / 0
    /// the solver is centred on. A neutral frame and a 6500 K request therefore cancel to the identity.
    public static func relativeMatrix(request: Request,
                                      asShot: Illuminant? = nil) -> Matrix3 {
        let target = matrix(temperature: request.temperature, tint: request.tint)
        let reference = asShot.map(referenceMatrix) ?? matrix(temperature: WhiteBalanceSolver.nominalTemperature, tint: 0)
        return target * reference.inverted()
    }

    // MARK: - 路线 B: the anchor (2026-10-31)

    /// **The anchor the drag's relative matrix is written against.**
    ///
    /// The model is calibrated at 6000 K / tint 0, so every preview matrix is spelled as a *ratio to
    /// that point* rather than as a direct difference of two requests:
    ///
    /// ```
    /// M_anchor(X)      = M(X) · M(anchor)⁻¹           (M_anchor(anchor) = I, exactly)
    /// M_rel(W₀ → Wₜ)   = M_anchor(Wₜ) · M_anchor(W₀)⁻¹
    /// display          = base(settled @ W₀) ⊗ M_rel
    /// ```
    ///
    /// Two reasons this is the shipped spelling and not the `M(Wₜ)·M(W₀)⁻¹` shorthand:
    ///
    ///   1. **`M_anchor(anchor)` is the identity *by construction*, not by cancellation.** A pair that
    ///      lands on the anchor cannot carry a residue from the inverse, so the drag's first frame and
    ///      a drag back to the anchor are the settled frame's own bytes (`whiteBalanceMatrix` returns
    ///      `.identity` for `Wₜ == W₀` as well, which is the stronger statement the tests pin at
    ///      ≤ 1e-9 elementwise before that early return).
    ///   2. **The inverse is taken on a quantity that is near the identity**, not on a matrix that may
    ///      itself be far from it: `M_anchor(W₀)⁻¹` is the inverse of `I + (small)` for nearby pairs,
    ///      so a light drag cannot amplify arithmetic error. It is still a real 3×3 adjugate inverse
    ///      (never a transpose, never a diagonal approximation), and a determinant under `1e-6` falls
    ///      back to the identity **and is reported** (`inverseFellBack`) rather than throwing.
    ///
    /// **Boundary, and it is the whole point of 路线 B:** this matrix is the *drag preview's
    /// increment*, nothing else. The settled frame is still `CIRAWFilter`'s own answer (the pair goes
    /// into `DecodeInputs.whiteBalance`, S1's gain there is `(1, 1, 1)`), and neither this matrix nor
    /// the anchor enters a render key, a decode key or an export. If a fitted table ever replaces the
    /// analytic `M`, it slots in at `anchorMatrix` and nothing else moves.
    public static let previewAnchor = (temperature: 6000.0, tint: 0.0)

    /// `M(anchor)` and its inverse, computed once: the denominator of every `M_anchor`.
    private static let anchorRawMatrix = matrix(temperature: previewAnchor.temperature,
                                                tint: previewAnchor.tint)
    private static let anchorRawInverse = stableInverse(anchorRawMatrix) ?? .identity

    /// Is this pair the anchor itself (an unspecified tint is the anchor's 0)?
    public static func isPreviewAnchor(_ temperature: Double?, _ tint: Double?) -> Bool {
        guard let temperature else { return false }
        return abs(temperature - previewAnchor.temperature) < 1e-9
            && abs((tint ?? 0) - previewAnchor.tint) < 1e-9
    }

    /// `M_anchor(X)` — the 3×3 for a pair, expressed as a ratio to the anchor. **Exactly `I` at the
    /// anchor**, which is the property the drag's identity frame relies on.
    public static func anchorMatrix(for whiteBalance: WhiteBalance) -> Matrix3 {
        let temperature = whiteBalance.temperature ?? WhiteBalanceSolver.nominalTemperature
        let tint = whiteBalance.tint ?? 0
        if isPreviewAnchor(temperature, tint) { return .identity }
        return matrix(temperature: temperature, tint: tint) * anchorRawInverse
    }

    /// `M_anchor(W₀)⁻¹ · …` — the guarded analytic inverse.
    ///
    /// `nil` when the determinant is not usable (|det| < 1e-6 or non-finite). The caller substitutes
    /// the identity and records that it did; silently returning a matrix here is exactly the failure
    /// mode this signature exists to make impossible.
    static func stableInverse(_ m: Matrix3, floor: Double = 1e-6) -> Matrix3? {
        let det = m.determinant
        guard det.isFinite, abs(det) >= floor else { return nil }
        return m.inverted()
    }

    /// **`M_rel(W₀ → Wₜ)`** — the drag's matrix, anchor-relative.
    ///
    /// `inverseFellBack` is `true` when `M_anchor(W₀)⁻¹` was refused and the identity was used
    /// instead (the frame is then anchored on the *target* alone; it is a preview, and saying so beats
    /// a precondition trap).
    public static func anchorRelativeMatrix(from buffer: WhiteBalance, to document: WhiteBalance,
                                            asShotPair: WhiteBalance = .asShot)
        -> (matrix: Matrix3, inverseFellBack: Bool) {
        guard !document.isAsShot else { return (.identity, false) }
        let target = anchorMatrix(for: document)
        // The base is the pair the buffer **on screen** carries: the settled pair when it was
        // developed at one, the file's as-shot pair when it was not (and the nominal 6500 K when the
        // caller has no pair at all — 143/194's reference, kept so a synthetic image behaves as
        // before).
        let base: WhiteBalance
        if !buffer.isAsShot {
            base = buffer
        } else if asShotPair.isAsShot {
            base = WhiteBalance(temperature: WhiteBalanceSolver.nominalTemperature, tint: 0)
        } else {
            base = asShotPair
        }
        guard let inverse = stableInverse(anchorMatrix(for: base)) else {
            return (target, true)
        }
        return (target * inverse, false)
    }

    /// **The drag preview's matrix** — the full 3×3, not its diagonal.
    ///
    /// 194's preview reduced this product to three numbers (`gains(from:)` below takes
    /// `matrix[0,0]/[1,1]/[2,2]`), and §2 of 195 measured what that costs: 16 codes at 6500 K and
    /// **97 codes / ΔE00 8.9** at 3200 K, because the adaptation's cross-channel terms grow exactly as
    /// the request leaves neutral. `relativeMatrix` was always the complete product; this function is
    /// where the pipeline now reads it, so the preview multiplies a pixel by the same 3×3 the model
    /// always had instead of its shadow.
    ///
    /// The reference is the buffer's own balance:
    ///
    ///   · **buffer as shot** — `relativeMatrix(request:asShot:)`, i.e. the request adapted *from* the
    ///     illuminant measured on that buffer (the nominal 6500 K when the frame is neutral), which is
    ///     the same reference `gain(for:asShot:)` chose. A neutral frame asked for 6500 K therefore
    ///     cancels to the identity, exactly as before.
    ///   · **buffer settled at another pair** — `M(document) · M(buffer)⁻¹`. The as-shot reference
    ///     cancels out of that quotient algebraically, so it is not consulted: a drag from a settled
    ///     rung continues from where that rung is, and `M(x)·M(x)⁻¹` is the identity the settled frame
    ///     needs.
    public static func previewMatrix(from buffer: WhiteBalance, to document: WhiteBalance,
                                     asShotPair: WhiteBalance = .asShot) -> Matrix3 {
        // 路线 B (2026-10-31): one spelling only — `M_anchor(Wₜ) · M_anchor(W₀)⁻¹`. The inverse
        // refusal is reported through `anchorRelativeMatrix`; `RenderGraph` is the caller that turns it
        // into a diagnosis, so this door cannot hide it behind a different number.
        anchorRelativeMatrix(from: buffer, to: document, asShotPair: asShotPair).matrix
    }

    /// 195 — **is this preview matrix sane enough to multiply by?**
    ///
    /// The valve exists because the model is a *ratio of two Bradford adaptations*, and far from
    /// neutral that ratio's own extrapolation becomes violent: at 2850 K/+60 it produces a **4.06×**
    /// blue entry, which does not correct the frame — it burns the highlights (measured 218 codes,
    /// ΔE00 24). A matrix that large is not a better answer than the diagonal, it is a worse one, so
    /// the caller falls back to `relativeGain`'s three numbers for that frame.
    ///
    /// The bound is `|m| ≤ 3` on every entry, which is deliberately loose: the biggest *legitimate*
    /// entry measured across the five §3 pairs is 2.70 (3200 K's blue, whose decoder-fitted value is
    /// 1.63 — the model already over-corrects there by 1.7×), so 3 admits every pair the task names
    /// and rejects only the cells where the ratio is extrapolating.
    ///
    /// **What this is not.** It is not a "row sums must be ≈1" test, even though a chromatic
    /// adaptation suggests one: a white-balance matrix's rows sum to its **channel gains**, and the
    /// decoder's own answer at 3200 K has rows summing to 0.51 / 0.85 / 1.70 (measured — see
    /// `WhiteBalanceModelProbeTests`). A row-sum gate would reject every real request and quietly make
    /// the whole feature a no-op.
    public static func isPlausiblePreviewMatrix(_ m: Matrix3) -> Bool {
        for v in m.values where !v.isFinite || abs(v) > 3 { return false }
        let g = m[1, 1]
        return g.isFinite && abs(g) > 1e-6
    }

    /// The full 3×3 matrix for one requested pair, in working RGB: `working⁻¹ · Bradford · working`.
    public static func matrix(temperature: Double, tint: Double) -> Matrix3 {
        let src = illuminantXYZ(temperature: temperature, tint: tint)
        let adaptation = bradfordAdaptation(from: src, to: whitePointXYZ)
        return ColorPrimaries.working.fromXYZ * adaptation * ColorPrimaries.working.toXYZ
    }

    /// The reference matrix for a measured illuminant.
    ///
    /// A nearly neutral buffer uses the nominal 6500 K / 0 matrix, which is what makes "as shot" and
    /// an explicit 6500 K the identity on a balanced frame (the file's own balance is already the
    /// neutral the pipeline works in). A visibly cast buffer is projected back onto the Planckian
    /// locus in uv, so its own temperature/tint is the reference and an explicit request is relative
    /// to the cast that is actually on screen.
    public static func referenceMatrix(_ illuminant: Illuminant) -> Matrix3 {
        let e = illuminant.normalized
        if e.chroma <= 0.02 { return matrix(temperature: WhiteBalanceSolver.nominalTemperature, tint: 0) }
        let projection = planckianProjection(of: e)
        return matrix(temperature: projection.temperature, tint: projection.tint)
    }

    /// The requested pair's channel gains. **One body**: the arithmetic is
    /// `WhiteBalanceSolver.gain`'s linear-light Planckian fit, so the global S1 gain, the mask's
    /// `localGain` and the eyedropper's inverse solve are literally the same function. What 143 adds
    /// is the *reference*: the illuminant measured from the decoded buffer (via the Planckian
    /// projection), not a hard-coded "the buffer is at 6500 K".
    public static func gain(for whiteBalance: WhiteBalance,
                            asShot: Illuminant? = nil) -> (r: Double, g: Double, b: Double) {
        if whiteBalance.isAsShot { return (1, 1, 1) }
        let request = Request(temperature: whiteBalance.temperature
                                ?? WhiteBalanceSolver.nominalTemperature,
                              tint: whiteBalance.tint ?? 0)
        let reference: WhiteBalanceSolver.Reference
        if let asShot {
            let e = asShot.normalized
            if e.chroma <= 0.02 {
                reference = WhiteBalanceSolver.Reference(
                    temperature: WhiteBalanceSolver.nominalTemperature, tint: 0)
            } else {
                let p = planckianProjection(of: e)
                reference = WhiteBalanceSolver.Reference(temperature: p.temperature, tint: p.tint)
            }
        } else {
            reference = WhiteBalanceSolver.Reference(
                temperature: WhiteBalanceSolver.nominalTemperature, tint: 0)
        }
        return WhiteBalanceSolver.gain(temperature: request.temperature,
                                       tint: request.tint, reference: reference)
    }

    /// The gain that moves a frame from `from` to `to` — the preview's number.
    ///
    /// It is a ratio of two `gain` calls, so a drag and the frame it predicts share one definition.
    /// `nil` axes are the as-shot state on that axis (the solver's nominal for Kelvin, 0 for tint).
    public static func relativeGain(from: WhiteBalance, to: WhiteBalance,
                                    asShot: Illuminant? = nil) -> (r: Double, g: Double, b: Double) {
        let a = gain(for: from, asShot: asShot)
        let b = gain(for: to, asShot: asShot)
        let rg = b.g / max(abs(a.g), 1e-12)
        let r = b.r / max(abs(a.r), 1e-12) / rg
        let bb = b.b / max(abs(a.b), 1e-12) / rg
        return (clampGain(r), 1, clampGain(bb))
    }

    private static func gains(from matrix: Matrix3) -> (r: Double, g: Double, b: Double) {
        let r = matrix[0, 0], g = matrix[1, 1], b = matrix[2, 2]
        guard r.isFinite, g.isFinite, b.isFinite, abs(g) > 1e-9 else { return (1, 1, 1) }
        return (clampGain(r / g), 1, clampGain(b / g))
    }

    private static func clampGain(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return min(max(value, 1.0 / 20), 20)
    }

    // MARK: - projection back onto the locus

    /// Closest Planckian point to a measured illuminant, as `(temperature, tint)`.
    ///
    /// A coarse sweep finds the basin (the distance function is single-moded over 2000…12000 for any
    /// plausible white), then a golden-section refinement finds the minimum. `tint` is the signed
    /// perpendicular distance divided by `tintPerUnit`, so it round-trips through `illuminantXYZ`.
    public static func planckianProjection(of illuminant: Illuminant) -> (temperature: Double, tint: Double) {
        let xyz = ColorPrimaries.working.toXYZ * illuminant.simd
        let sum = xyz.x + xyz.y + xyz.z
        guard sum.isFinite, abs(sum) > 1e-9, xyz.x / sum + xyz.y / sum != 0 else {
            return (WhiteBalanceSolver.nominalTemperature, 0)
        }
        let x = xyz.x / sum, y = xyz.y / sum
        let d = -2 * x + 12 * y + 3
        guard abs(d) > 1e-9 else { return (WhiteBalanceSolver.nominalTemperature, 0) }
        let u = 4 * x / d, v = 6 * y / d

        func distance(_ t: Double) -> Double {
            let (lu, lv) = planckianUV(t)
            return (u - lu) * (u - lu) + (v - lv) * (v - lv)
        }

        let lo = WhiteBalanceSolver.searchRange.lowerBound
        let hi = WhiteBalanceSolver.searchRange.upperBound
        var best = lo, bestD = Double.infinity
        var t = lo
        while t <= hi {
            let d = distance(t)
            if d < bestD { bestD = d; best = t }
            t += 25
        }
        var a = max(lo, best - 25), b = min(hi, best + 25)
        for _ in 0..<48 {
            let m1 = a + (b - a) / 3, m2 = b - (b - a) / 3
            if distance(m1) < distance(m2) { b = m2 } else { a = m1 }
        }
        let temperature = min(max((a + b) / 2, lo), hi)
        let (lu, lv) = planckianUV(temperature)
        let (u0, v0) = planckianUV(temperature - 1)
        let (u1, v1) = planckianUV(temperature + 1)
        var nu = -(v1 - v0), nv = u1 - u0
        let n = (nu * nu + nv * nv).squareRoot()
        if n > 1e-12 { nu /= n; nv /= n } else { nu = 0; nv = 1 }
        if nv < 0 { nu = -nu; nv = -nv }        // +tint = magenta = lower v
        let signed = (u - lu) * nu + (v - lv) * nv
        return (temperature, signed / tintPerUnit)
    }
}

// MARK: - percentile

/// The sorted-order percentile used by every estimator. `p` is in 0…1.
private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
    return sorted[index]
}
