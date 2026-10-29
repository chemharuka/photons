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
/// Each slider is a displacement in EV (`+` brightens that zone, 派单 008 A), with full travel
/// 0.90 / 0.70 / 0.60 EV. Three independent travels can fold the map when they have opposite signs
/// (e.g. shadows +100 and midtones −100), so `travelEV` compresses all three by one common factor when
/// the worst derivative budget exceeds `1 − minSlope`. The scale is positive and symmetric about zero,
/// so the identity and the direction of every slider are untouched; only extreme opposite-sign
/// combinations are reduced.
public enum S2Regions {

    /// Full travel at |slider| = 100, in EV.
    public static let shadowTravel: Double = 0.90
    public static let midTravel: Double = 0.70
    public static let highTravel: Double = 0.60

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
