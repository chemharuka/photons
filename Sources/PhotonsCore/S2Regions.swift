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
/// Above display white the three Gaussians are **not** frozen at `L = 0`. S2's global 高光 is 299's
/// C¹ slope shoulder (`highSlope` / `highShoulderEV`), and the band term only carries the shadow and
/// middle displacements: as `L → +∞` the two low weights decay to exactly 0, so `Δ_bands → 0` and the
/// HDR tail is the shoulder alone. Freezing (`L* = min(L, 0)`) would add a constant band offset to the
/// whole HDR tail; 299's `+4 EV → +1 EV` promise would be lost.
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

    /// 299 — the global 高光 slider is a slope above display white, not an EV displacement.
    ///
    ///     h = clamp(highlights, −100, 100) / 100
    ///     k(h) = 1 + 0.8·h          k(−100) = 0.20, k(0) = 1 (exact identity), k(+100) = 1.80
    ///
    /// `Δ(L) = (k−1)·(L − w·(1 − e^{−L/w}))` for `L > 0`, `Δ(L) = 0` otherwise, with the C¹ knee
    /// width `w = 0.25 EV`. At `L = +4`, `Δ = −0.8·(4 − 0.25·(1 − e^{−16})) = −3.0`, so `y = +1.0`.
    public static let highSlopeFull: Double = 0.20
    public static let highKneeWidthEV: Double = 0.25

    /// The asymptotic log2 slope above display white for one 高光 slider position.
    public static func highSlope(highlights: Double) -> Double {
        let h = min(max(highlights, -100), 100) / 100
        return 1 + (1 - highSlopeFull) * h
    }

    /// The log2-domain shoulder displacement, in EV, for a sample at `L` EV.
    ///
    /// `L ≤ 0` is the identity (the display-white knee is exactly at 0), and `L > 0` starts with
    /// slope 1 (C¹ at the knee) and asymptotes to `k`. Because `0 ≤ w(1 − e^{−L/w}) < L`, the output
    /// `y = L + Δ(L)` stays in `[kL, L]`: never negative, so an SDR value still clips to white and
    /// the headroom-1 render is unchanged.
    public static func highShoulderEV(L: Double, highlights: Double) -> Double {
        guard L > 0 else { return 0 }
        let k = highSlope(highlights: highlights)
        let w = highKneeWidthEV
        return (k - 1) * (L - w * (1 - exp(-L / w)))
    }

    /// The steepest slope `d(log2 v′)/dL` the gate is allowed to produce.
    ///
    /// 306's normalized Gaussians have a much softer worst case than 085's disjoint windows; with the
    /// recalibrated travels the measured minimum over `L ∈ [−12, 0]` is above 0.50 for every slider
    /// combination, so the gate is a safety net rather than a shaper (`limiterDisabled` still exists
    /// for the refutation test).
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
    /// 1, so the band term vanishes without a clamp; see the type comment for why freezing at 0 would
    /// break 299's HDR tail.
    public static func weights(L: Double) -> (shadow: Double, mid: Double, high: Double) {
        let bs = gaussian(L, bandCentres.shadow)
        let bm = gaussian(L, bandCentres.mid)
        let bh = gaussian(L, bandCentres.high)
        let sum = bs + bm + bh
        return (bs / sum, bm / sum, bh / sum)
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
