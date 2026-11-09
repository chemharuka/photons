import Foundation

/// 085 — the three region lifts of S2 (阴影 / 中间调 / 高光), in EV.
///
/// The kernel does the weighting and one `exp2`; **the travel and its monotonicity gate live here** so
/// that "the map never folds" is a calculated property rather than a lucky choice of window width.
/// The three windows are two complementary smoothstep chains on `L = log2(luma)` (EV relative to
/// display white):
///
///     a = smoothstep(−5.4, −3.9, L)    // shadow → mid
///     b = smoothstep(−2.4, −0.9, L)    // mid → high
///     c = smoothstep(+4.0, +6.0, L)    // high → white (closes the top, outside the HDR range)
///
///     w_shadow = 1 − a
///     w_mid    = a · (1 − b)
///     w_high   = b · (1 − c)
///
/// The two rises do not overlap (`a` is 1 before `b` starts), so every luminance through the
/// shadow→high run has a full-weight owner: there is **no dead band** between the sliders (the old
/// layout had −3.9…−3.2 EV where neither acted, which is where the reference frames' median lives).
/// The shadow seam sits **below** the reference frames' median (p50 ∈ [−4.36, −3.28] EV) on purpose:
/// at the median `w_shadow` is only ≈0.13, so 阴影 ±100 moves a median by a few codes while the
/// 中间调 slider owns it — the same separation the old two-window layout had, without the gap.
///
/// **124 (2026-10-29): 高光 covers the whole HDR range.** The closure used to be
/// `smoothstep(−1.2, 0.0, L)`, so `w_high` was 0 at and above display white and a linear value above
/// 1.0 was untouched by the 高光 slider. `c` now closes at +4…+6 EV, beyond the default 2.3 EV
/// headroom (and 114's possible 4 EV), so `w_high = 1` from −0.9 EV through the whole HDR range. The
/// 阴影 / 中间调 windows are unchanged: the 0.400 slope budget is measured on their seams too.
///
/// **299 (2026-11-09): 高光 is a slope shoulder above white, not a displacement.** The user asked
/// 「+4 EV 拉回到 +1 左右」, which needs 3 EV of travel through `L > 0` — five times the old 0.60 EV
/// and impossible for a fixed displacement without a fold. So only the **global** 高光 changes: its
/// slider sets `k(h) = 1 + 0.8h`, and the kernel applies the C¹ log shoulder
/// `Δ(L) = (k−1)(L − 0.25(1 − e^{−L/0.25}))` above 0 EV. `L ≤ 0` and `h = 0` are bit-exact
/// identities, and the SDR (headroom 1) image is unchanged because `y ≥ 0`. The shadow/mid travels
/// and the gate below are untouched; the mask's `LocalAdjustU.b.y` still reads `travelEV().high`.
///
/// Each shadow/mid slider is a displacement in EV (`+` brightens that zone, 派单 008 A), with full
/// travel 0.90 / 0.70 EV. Three independent travels can fold the map when they have opposite signs
/// (e.g. shadows +100 and midtones −100), so `travelEV` compresses all three by one common factor when
/// the worst derivative budget exceeds `1 − minSlope`. The scale is positive and symmetric about zero,
/// so the identity and the direction of every slider are untouched; only extreme opposite-sign
/// combinations are reduced.
public enum S2Regions {

    /// Full travel at |slider| = 100, in EV.
    public static let shadowTravel: Double = 0.90
    public static let midTravel: Double = 0.70
    /// 299 — the **mask** path still reads this displacement (`localApply`); the global 高光 slider
    /// no longer does. See `highSlope` / `highShoulderEV` below.
    public static let highTravel: Double = 0.60

    /// 299 — the global 高光 slider is a slope above display white, not an EV displacement.
    ///
    /// A +4 EV sample must come down to +1 EV at `highlights = −100`: 3 EV of travel, five times the
    /// old 0.60 EV. A fixed displacement cannot do that without folding the map, so the slider moves
    /// the **asymptotic slope** instead:
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

    /// The steepest slope `d(log2 v′)/dL` the gate is allowed to produce. It stays 085's shipped
    /// 0.500 so the shadow/mid travel (and their measured code shifts) does not move: a single
    /// `shadows +100` is compressed from 0.90 to 0.50 EV by this number.
    ///
    /// **124** recomputed the raw budget at the +2.3 EV end: a full-travel 高光 (0.60 EV) across the
    /// 1.5 EV mid→high seam has a worst derivative of `1.5/1.5 · 0.60 = 0.60`, i.e. a raw slope floor
    /// of `1 − 0.60 = 0.400`. The gate may compress that to 0.500; both are at or above the 0.400
    /// budget the task pins.
    public static let minSlope: Double = 0.500

    /// Test-only switch: `true` skips the common compression, so a test can show that the
    /// monotonicity in `testTheRegionLiftsAreMonotoneForEveryCombination` is bought by the gate and
    /// not by the raw travel numbers.
    static var limiterDisabled = false

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The three weights of one luminance, `(shadow, mid, high)`, each 0…1.
    public static func weights(L: Double) -> (shadow: Double, mid: Double, high: Double) {
        let a = smoothstep(-5.4, -3.9, L)
        let b = smoothstep(-2.4, -0.9, L)
        let c = smoothstep(4.0, 6.0, L)
        return (1 - a, a * (1 - b), b * (1 - c))
    }

    /// The three displacements, in EV, after the monotonicity gate.
    public static func travelEV(shadows: Double, midtones: Double, highlights: Double)
        -> (shadow: Double, mid: Double, high: Double) {
        var ds = shadows / 100 * shadowTravel
        var dm = midtones / 100 * midTravel
        var dh = highlights / 100 * highTravel

        if !limiterDisabled {
            // `1.5/width` is the upper bound of a Hermite smoothstep's derivative, so each term is
            // the worst-case fold that seam can contribute. The highest one sets the scale.
            let deficit = max(
                (1.5 / 1.5) * abs(dm - ds),      // shadow↔mid seam is 1.5 EV wide
                (1.5 / 1.5) * abs(dh - dm),      // mid↔high seam is 1.5 EV wide
                (1.5 / 2.0) * abs(dh))           // 124: the high release is +4…+6 EV (2 EV wide)
            // `deficit` is the worst-case fall of the local slope (`1 − deficit`), so the gate is
            // "keep the slope at or above `minSlope`".
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
