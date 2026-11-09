import Foundation

/// 085 — the three region lifts of S2 (阴影 / 中间调 / 高光), in EV.
///
/// **306 (2026-11-09): the complementary smoothstep windows became three normalized Gaussians.**
/// The old windows were disjoint, so a slider next to the one the user dragged did not move at all
/// and the local slope on a window seam fell to **0.30** (`mid = ±100`). The user's brief is
/// 「中间调以中间为主，但也能带动阴影和高光；其他也类似，避免局部对比度损失」, so the weights are now
/// a partition of unity with overlap:
///
///     c = (−6.8, −3.6, +0.2) EV
///     σ = 1.9 EV
///     b_i = exp(−((L − c_i)/σ)² / 2)
///     w_i = b_i / Σ_j b_j          ⇒  Σ_i w_i ≡ 1
///
/// Every weight is C^∞ and has full support, so each slider moves all three zones (§2.1). The middle
/// band sits on the reference frames' median (p50 ≈ −3.6 EV) and its peak weight is 0.726; the
/// shadow / high centres see 0.195 / 0.119 of the middle band. A convex combination cannot ring
/// (darktable's un-normalized `toneequal` is the cautionary tale), and the weights are normalized by
/// the exact denominator, not by a fitted constant.
///
/// **306b (2026-11-09): 高光 joins the band term too.** All three displacements now enter the
/// convex combination, so the high slider drags 阴影 and 中间调 as well — the user's 「其他的也类似」
/// is not half-done any more. Above white the band term approaches the constant `d_high` (every
/// low weight decays to 0, `w_high → 1`). 299's `+4 EV → +1 EV` tail needs a *further* −3.0 EV, so
/// the shoulder only has to supply the **difference**:
///
///     Δ_total(L) = Σ_i w_i(L)·d_i + S(L)
///     S(L) = 0                                             L ≤ 0
///     S(L) = (k−1)(L − w(1 − e^{−L/w}))                    L > 0,  w = 0.25 EV
///
/// `S(0) = 0` and `S'(0) = 0`, so the white point is C¹. `k = 1 + c·h` no longer uses 299's fixed
/// 0.8: `c` is solved numerically so that `h = −1, shadows = mid = 0, L = +4` lands on
/// `Δ_total = −3.0` (the band already contributes `−0.827947`, the shoulder supplies `−2.172053`).
/// The solve is in `highSlopeCoefficient` below; the GPU only receives the finished `k`.
///
/// **Travel recalibration.** The Gaussian peak is 0.726, so the old full travels (0.90 / 0.70 / 0.60)
/// were multiplied by 1/0.726 to keep the displacement at each band's **centre** unchanged:
/// 1.24 / 0.96 / 0.83 EV. The mask path (`s1_6_local`) still uses 074's two windows and therefore
/// keeps the old 0.90 / 0.70 / 0.60 (`maskTravelEV`); the two paths are deliberately unsynchronised
/// until a later task unifies them (§4 of 306).
public enum S2Regions {

    /// Full travel at |slider| = 100, in EV, for the **global** normalized-Gaussian bands.
    public static let shadowTravel: Double = 1.24
    public static let midTravel: Double = 0.96
    /// The global 高光 displacement is the gate's third band; the visible HDR tail is the shoulder.
    /// The mask path reads `maskHighTravel` instead.
    public static let highTravel: Double = 0.83

    /// 074's travels, kept **verbatim** for `s1_6_local` (`region_weights3` + `region_gain3`).
    public static let maskShadowTravel: Double = 0.90
    public static let maskMidTravel: Double = 0.70
    public static let maskHighTravel: Double = 0.60

    /// The three Gaussian centres and their width, in EV relative to display white.
    public static let bandCentres: (shadow: Double, mid: Double, high: Double) = (-6.8, -3.6, 0.2)
    public static let bandSigma: Double = 1.9

    /// 306b — 高光 is both a band and the 299 slope shoulder. The slider is still a slope above
    /// display white, but its coefficient is solved from the tail promise rather than pinned at 0.8.
    ///
    ///     h = clamp(highlights, −100, 100) / 100
    ///     k(h) = 1 + c·h            k(−100) = 0.420786, k(0) = 1 (exact identity), k(+100) = 1.579214
    ///
    /// `Δ_total(L) = Σ w_i(L)·d_i + (k−1)·(L − w·(1 − e^{−L/w}))` for `L > 0`.
    /// At `h = −100, shadows = mid = 0, L = +4`: the band already supplies
    /// `w_h(+4)·(−0.83) = −0.827947`, so the shoulder must supply the remaining `−2.172053`, i.e.
    /// `c = (3.0 + band(+4)) / 3.75 = 0.579214093…`. The constant is found by bisection below; the
    /// closed form is kept only as a comment so the two cannot drift.
    public static let highKneeWidthEV: Double = 0.25

    /// `c` in `k(h) = 1 + c·h`, solved numerically so that 299's `+4 EV → +1 EV` still holds once
    /// the high band is inside the convex combination.
    ///
    /// Let `bandAt4 = w_h(+4)·(−highTravel) = −0.827947…` and `shapeAt4 = 4 − 0.25(1 − e^{−16})`.
    /// For `h = −1`, `k − 1 = −c`, so `bandAt4 − c·shapeAt4 = −3.0` and
    /// `c = (3.0 + bandAt4) / shapeAt4 = 0.579214093…`. The bisection runs on the same expression the
    /// kernel evaluates, so the constant cannot go stale if a travel or centre moves.
    public static let highSlopeCoefficient: Double = {
        let target = -3.0
        let bandAt4 = weights(L: 4).high * (-highTravel)
        let w = highKneeWidthEV
        let shapeAt4 = 4 - w * (1 - exp(-4 / w))
        var lo = 0.0, hi = 1.0
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            let delta = bandAt4 - mid * shapeAt4
            if delta > target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }()

    /// The asymptotic log2 slope above display white for one 高光 slider position.
    public static func highSlope(highlights: Double) -> Double {
        let h = min(max(highlights, -100), 100) / 100
        return 1 + highSlopeCoefficient * h
    }

    /// The log2-domain shoulder displacement `S(L)`, in EV, for a sample at `L` EV.
    ///
    /// `L ≤ 0` is exactly 0 (the band term owns the SDR side now), and `L > 0` starts with slope 0
    /// (`S'(0) = 0`, so the *total* slope at the knee is the band's) and asymptotes to `k − 1`.
    /// The shoulder alone stays in `[kL, L]`, so it never manufactures a negative value.
    public static func highShoulderEV(L: Double, highlights: Double) -> Double {
        guard L > 0 else { return 0 }
        let k = highSlope(highlights: highlights)
        let w = highKneeWidthEV
        return (k - 1) * (L - w * (1 - exp(-L / w)))
    }

    /// The steepest slope `d(log2 v′)/dL` the gate is allowed to produce.
    ///
    /// 306b puts all three bands in the slope, so the gate is a genuine three-way check. With the
    /// frozen travels the measured minimum over `L ∈ [−12, 0]` is **0.528659** at the opposite-sign
    /// corner `(+1.24, −0.96, +0.83)` (`L = −5.345`), i.e. above `minSlope` and the gate never
    /// triggers; single-slider floors are 0.717 / 0.765 / 0.774. Above white the slope is deliberately
    /// owned by the shoulder (`h = −100` asymptotes to `k = 0.421`) and is **not** gated.
    public static let minSlope: Double = 0.500

    /// Test-only switch: `true` skips the common compression, so a test can show that the
    /// monotonicity claim is bought by the gate and not by the raw travel numbers.
    static var limiterDisabled = false

    private static func gaussian(_ L: Double, _ centre: Double) -> Double {
        let z = (L - centre) / bandSigma
        return exp(-(z * z) / 2)
    }

    /// The three weights of one luminance, `(shadow, mid, high)`, each 0…1 and summing to 1.
    ///
    /// `L` is used directly. Above white the two low weights decay to 0 and the high weight tends to
    /// 1, so the band term approaches the constant `d_high` without a clamp; the shoulder `S` then
    /// supplies only the difference needed for 299's tail.
    public static func weights(L: Double) -> (shadow: Double, mid: Double, high: Double) {
        let bs = gaussian(L, bandCentres.shadow)
        let bm = gaussian(L, bandCentres.mid)
        let bh = gaussian(L, bandCentres.high)
        let sum = bs + bm + bh
        return (bs / sum, bm / sum, bh / sum)
    }

    /// The band term `Σ w_i(L)·d_i`, in EV, for one pixel.
    public static func bandEV(L: Double,
                              shadow: Double, mid: Double, high: Double) -> Double {
        let w = weights(L: L)
        return w.shadow * shadow + w.mid * mid + w.high * high
    }

    /// The full log2 displacement, in EV, including the 306b difference shoulder.
    public static func totalEV(L: Double, shadow: Double, mid: Double, high: Double,
                               highlights: Double) -> Double {
        bandEV(L: L, shadow: shadow, mid: mid, high: high)
            + highShoulderEV(L: L, highlights: highlights)
    }

    /// The weights and their analytic `L`-derivatives (for the monotonicity gate).
    private static func weightsAndSlopes(L: Double)
        -> (w: (shadow: Double, mid: Double, high: Double),
            dw: (shadow: Double, mid: Double, high: Double)) {
        let bs = gaussian(L, bandCentres.shadow)
        let bm = gaussian(L, bandCentres.mid)
        let bh = gaussian(L, bandCentres.high)
        let sum = bs + bm + bh
        let ws = bs / sum, wm = bm / sum, wh = bh / sum
        // d/dx exp(−((x−c)/σ)²/2) = −(x−c)/σ² · b
        let inv = 1 / (bandSigma * bandSigma)
        let ss = -(L - bandCentres.shadow) * inv
        let sm = -(L - bandCentres.mid) * inv
        let sh = -(L - bandCentres.high) * inv
        let mean = ws * ss + wm * sm + wh * sh
        return ((ws, wm, wh),
                (ws * (ss - mean), wm * (sm - mean), wh * (sh - mean)))
    }

    /// `d(log2 v′)/dL = 1 + Σ w_i′(L)·d_i` for one set of band displacements.
    static func bandSlope(L: Double,
                          shadow: Double, mid: Double, high: Double) -> Double {
        let (_, dw) = weightsAndSlopes(L: L)
        return 1 + dw.shadow * shadow + dw.mid * mid + dw.high * high
    }

    /// The minimum of `bandSlope` on the gate's own grid: `L ∈ [−12, 0]`, step 0.05 EV.
    static func worstBandSlope(shadow: Double, mid: Double, high: Double) -> Double {
        var worst = Double.infinity
        var L = -12.0
        while L <= 1e-9 {
            worst = min(worst, bandSlope(L: L, shadow: shadow, mid: mid, high: high))
            L += 0.05
        }
        return worst
    }

    /// The three global displacements, in EV, after the monotonicity gate.
    public static func travelEV(shadows: Double, midtones: Double, highlights: Double)
        -> (shadow: Double, mid: Double, high: Double) {
        var ds = shadows / 100 * shadowTravel
        var dm = midtones / 100 * midTravel
        var dh = highlights / 100 * highTravel

        if !limiterDisabled {
            let worst = worstBandSlope(shadow: ds, mid: dm, high: dh)
            if worst < minSlope {
                // `1 − worst` is the amount the raw bands ate from the identity slope; scale the
                // displacements so the minimum lands exactly on `minSlope`.
                let scale = (1 - minSlope) / (1 - worst)
                ds *= scale
                dm *= scale
                dh *= scale
            }
        }
        return (ds, dm, dh)
    }

    /// The mask path's travels: 074's two windows and 074's gate, **unchanged by 306**.
    ///
    /// `s1_6_local` reads `region_weights3` / `region_gain3` and the third EV displacement, so this
    /// deliberately keeps 0.90 / 0.70 / 0.60 and the old `deficit` approximation. §4 of 306: the
    /// global and masked meanings of the same slider stay different until a later task unifies them.
    public static func maskTravelEV(shadows: Double, midtones: Double, highlights: Double)
        -> (shadow: Double, mid: Double, high: Double) {
        var ds = shadows / 100 * maskShadowTravel
        var dm = midtones / 100 * maskMidTravel
        var dh = highlights / 100 * maskHighTravel

        if !limiterDisabled {
            let deficit = max(
                (1.5 / 1.5) * abs(dm - ds),      // shadow↔mid seam is 1.5 EV wide
                (1.5 / 1.5) * abs(dh - dm),      // mid↔high seam is 1.5 EV wide
                (1.5 / 2.0) * abs(dh))           // 124: the high release is +4…+6 EV (2 EV wide)
            if deficit > 1 - minSlope {
                let scale = minSlope / deficit
                ds *= scale
                dm *= scale
                dh *= scale
            }
        }
        return (ds, dm, dh)
    }
}
