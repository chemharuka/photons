import Foundation

/// 085 — the three region lifts of S2 (阴影 / 中间调 / 高光), in EV.
///
/// The kernel does the weighting and one `exp2`; **the travel and its monotonicity gate live here** so
/// that "the map never folds" is a calculated property rather than a lucky choice of window width.
/// The three windows are two complementary smoothstep chains on `L = log2(luma)` (EV relative to
/// display white):
///
///     a = smoothstep(−5.0, −3.2, L)    // shadow → mid
///     b = smoothstep(−2.6, −1.0, L)    // mid → high
///     c = smoothstep(−1.2,  0.0, L)    // high → white (closes the top)
///
///     w_shadow = 1 − a
///     w_mid    = a · (1 − b)
///     w_high   = b · (1 − c)
///
/// The two rises do not overlap (`a` is 1 before `b` starts), so every luminance through the
/// shadow→high run has a full-weight owner: there is **no dead band** between the sliders (the old
/// layout had −3.9…−3.2 EV where neither acted, which is where the reference frames' median lives).
/// Above white `c = 1` ⇒ `w_high = 0` and the other two are already 0, so the gain is exactly 1 and
/// HDR samples pass through bit for bit.
///
/// Each slider is a displacement in EV (`+` brightens that zone, 派单 008 A), with full travel
/// 0.90 / 0.70 / 0.60 EV. Three independent travels can fold the map when they have opposite signs
/// (e.g. shadows +100 and midtones −100), so `travelEV` compresses all three by one common factor when
/// the worst derivative budget exceeds 0.5. The scale is positive and symmetric about zero, so the
/// identity and the direction of every slider are untouched; only extreme opposite-sign combinations
/// are reduced.
public enum S2Regions {

    /// Full travel at |slider| = 100, in EV.
    public static let shadowTravel: Double = 0.90
    public static let midTravel: Double = 0.70
    public static let highTravel: Double = 0.60

    /// The steepest slope `d(log2 v′)/dL` the gate is allowed to produce. The limiter's budget is
    /// `1.5/width` per seam, so the derivative is bounded below by `1 − 0.5`.
    public static let minSlope: Double = 0.5

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
        let a = smoothstep(-5.0, -3.2, L)
        let b = smoothstep(-2.6, -1.0, L)
        let c = smoothstep(-1.2, 0.0, L)
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
                (1.5 / 1.8) * abs(dm - ds),
                (1.5 / 1.6) * abs(dh - dm),
                (1.5 / 1.2) * abs(dh))
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
