import Foundation

/// 0107 — **the contrast bend's axis**: log2 EV, pinned at the two end points of the display range.
///
/// `s2_tone_map.metal` used to bend contrast with a *linear-light power*:
///
///     γ = 2^(contrast / 100 · 2.0)                      // the 2.0 was magic
///     v' = sign(v) · 0.18 · (|v| / 0.18)^γ               // pivot 0.18, no upper asymptote
///
/// Three things were wrong with it, and only the first is about taste:
///
///   1. **It shears, it does not bend.** One exponent over the whole range is a slope of γ
///      *everywhere* — 4× at `contrast = +100` — so the curve has no shape that separates the
///      mid-tones from the ends; it is a gain that happens to live in log space.
///   2. **It is unbounded above.** `0.18·(v/0.18)^4 = 1` at `v = 0.2765` (mid-grey + 0.62 EV), so
///      every sample brighter than that lands on display white. Measured on the four reference
///      frames at `contrast = +100` (R channel, 8-bit): **12.51 % / 3.05 % / 1.46 % / 12.85 %** of
///      the samples at code 255, and the median fell 86 → 30 / 81 → 22 / 69 → 7 / 93 → 43 codes.
///   3. **Its `−100` was a toe lift, not a flattening.** γ = ¼ pushed the median *up* (86 → 109 on
///      `L1030402`): the picture got brighter in the shadows and nothing got compressed.
///
/// This type is the CPU side of the replacement — one place for the axis constants, so the kernel,
/// the render graph and the tests cannot drift (the same discipline as `HDRCurve.axis`).
///
/// ## The curve
///
/// `L = log2(max(luma, 1e-9))` — EV relative to display white, the histogram card's own axis. The
/// bend is a **displacement in EV**, applied as a gain `v ·= 2^Δ`, over a **held core**:
///
///     Δ(L) = t · travel · ( SHOULDER · bump(L; shLo, 0) − TOE · toe(L; black, black + 3) )
///     t    = contrast / 100
///
///   · **the core `[−5.0, −3.2]` EV is held**: `Δ = 0` exactly, slope exactly 1. That band is where
///     the four reference frames' median lives (measured p50 ∈ `[−4.07, −3.19]` EV), which is why
///     `contrast = ±100` moves the median by **0 codes** on all four (the old power moved it by −56
///     at `+100` and +23 at `−100` on `L1030402`).
///
///     This is not decoration: a *point* pivot cannot do it. A bounded sigmoid (tanh, full gain 2×)
///     hinged at the middle of the range moves these medians by **+10.5 / +5.9 / −3.4 / +16.7**
///     codes — one static curve cannot put its fixed point on four different medians, and a fixed
///     point off by 0.5 EV costs ~13 codes. A held *band* is the honest version of "the mid-tones do
///     not move", and it is the same construction 074's region windows use ("neither slider acts
///     between −3.9 and −3.2 EV").
///   · **the toe is a *shift*** (`1 − smoothstep(black, black + 3, L)`): a gain below the black knee,
///     so it can never fold (slope stays ≥ 1 − 1.5·toeFraction·travel/w = 0.575 at full travel) and it
///     keeps 0 at 0 — no manufactured grey. The price is stated rather than hidden: at `+100` the
///     samples between −8 and −5 EV are halved, which took the deepest frame from 0.97 % to 1.14 % of
///     dead black (+0.17 points; the old curve took the same frame to 23.9 %). Its window is anchored
///     to `blackEV`.
///   · **the shoulder is a *bump*** (`4u(1−u)`, 0 at both ends of `[−3.2, 0]`): it *lands on display
///     white*, so nothing at or below white can be pushed past it. Measured margin: the bump's peak
///     displacement is 0.55 EV against 1.6 EV of headroom at the peak, so the "≤1 % on the ceiling"
///     criterion is met with a 2.9× margin (measured: 0.00–0.01 %, i.e. the neutral frame's own
///     ceiling count).
///   · both terms are 0 for `L ≥ 0`, so **HDR samples above white pass through bit for bit** (074's
///     four-EV tail, `HeadroomTests`) and 079 §4's "no upper clamp in S2" is respected — the bound is
///     the *shape*, not a `min()`.
///
/// ## Where `travel` comes from
///
/// The old constant was `2.0` inside `exp2(...)`, i.e. "at ±100 the log distance from the pivot is
/// doubled" — a number with no relation to anything. The bend's size is now **derived from the two
/// end points of the axis**:
///
///     travel = 8 / (whiteEV − blackEV)        // EV of displacement at |contrast| = 100
///
/// which is darktable's normalisation (`filmicrgb.c:409`, `contrast *= 8/(white_ev − black_ev)`) with
/// our own axis: an 8 EV span ⇒ 1.0 EV of full-scale bend. Narrow the axis (a different `blackEV`)
/// and the same slider moves the picture less, because the slider's job is "bend the range", not
/// "multiply a slope".
///
/// **The document's `levels.black/white` are deliberately not used here.** They are S1's end points
/// (073B) in *linear* units and have already been applied by the time S2 runs; converting them again
/// would double-count, and the default `levels.black = 0` has no log (`−∞`). The pin is on the
/// *axis*, which is what the two constants below are.
///
/// The `.metal` copy of these numbers is `CT_*` in `s2_tone_map.metal`;
/// `ContrastLogDomainTests.testTheKernelConstantsAreTheSwiftConstants` parses the kernel and asserts the two
/// copies are equal, because a kernel cannot import Swift.
public enum S2Contrast {

    /// Display white: the axis origin, and the point the shoulder lands on.
    public static let whiteEV: Double = 0

    /// The tone map's floor. 8 EV below white is where the reference frames' p1 sits
    /// (`L1030402` p1 = −8.0 EV, `L1030408` p1 = −8.6 EV): below it the OETF is linear and code 0…3
    /// is all that is left, so the toe's window starts here.
    public static let blackEV: Double = -8

    /// Width of the toe's transition, in EV. The toe reaches full travel at `blackEV + 3` = −5.0 EV,
    /// which leaves the held core its full 1.8 EV.
    public static let toeWindowEV: Double = 3

    /// The held core's top: the shoulder's window is `[shoulderLoEV, whiteEV]`, 3.2 EV wide, so its
    /// peak sits at −1.6 EV.
    public static let shoulderLoEV: Double = -3.2

    /// Full-scale displacement of the bend, in EV: the derived replacement for the old `2.0`.
    public static var travelEV: Double { 8 / (whiteEV - blackEV) }

    /// Toe travel as a fraction of `travelEV`. **0.85, not 1.0**: in the OETF's linear segment
    /// (code ≤ 10) a gain `g` multiplies code spacing by `g`, so a full 1 EV lift would sit exactly
    /// on the 2-code banding budget; 0.85 leaves 7 % for the fp16/fp32 rounding. Measured max step
    /// on a 256-step grey ramp: 1.80 codes at `−100`, 1.67 at `+100`.
    public static let toeFraction: Double = 0.85

    /// Shoulder travel as a fraction of `travelEV`. Set by the same banding budget from the other
    /// side: a `4u(1−u)` bump's steepest flank is `3.11·A/w` per EV and the code-space step is
    /// amplified by `2^(0.4167·Δ)` on the bright side, so `0.55 · 3.11/3.2 · 2^0.23 = 1.67` codes.
    public static let shoulderFraction: Double = 0.55

    /// The band in which the slider provably does nothing, in EV. Printed by the tests and quoted in
    /// the kernel header; it is what keeps the median out of the slider's reach.
    public static var heldBandEV: ClosedRange<Double> { (blackEV + toeWindowEV)...shoulderLoEV }

    /// The bend at one EV, in EV — `tone_contrast_ev` in `tone_shape.metal`, in double precision.
    ///
    /// Used by the tests as the CPU reference and by `RenderGraph` only for the identity decision
    /// (`contrast == 0` ⇒ the entry point without any of this arithmetic).
    public static func displacement(EV L: Double, contrast: Double) -> Double {
        func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        let t = contrast / 100
        let u = smoothstep(shoulderLoEV, whiteEV, L)
        let shoulder = 4 * u * (1 - u)
        let toe = 1 - smoothstep(blackEV, blackEV + toeWindowEV, L)
        return t * travelEV * (shoulderFraction * shoulder - toeFraction * toe)
    }

    /// The gain the kernel applies to a pixel whose luma is `luma` (`v ·= gain`).
    public static func gain(luma: Double, contrast: Double) -> Double {
        guard contrast != 0, luma.isFinite else { return 1 }
        return pow(2, displacement(EV: log2(max(luma, 1e-9)), contrast: contrast))
    }
}
