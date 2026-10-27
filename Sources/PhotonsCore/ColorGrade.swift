import Foundation
import simd

// MARK: - 色彩分级 (2026-10-28, P0) — the arithmetic

/// **S3.8's maths, on the host** — the definition `Kernels/s3_8_grade.metal` is written against.
///
/// The same division of labour as `HSLBands`/`s3_6_hsl.metal`: this file owns the algebra and the
/// constants, the kernel compiles the same numbers (Metal cannot import Swift), and
/// `ColorGradingTests` renders both and holds them together, so neither can drift without a red test.
///
/// ### What the operation is
///
/// Three **luminance** windows decide how much of each wheel reaches a pixel; inside that weight the
/// pixel's hue is rotated, its chroma scaled and its light gained:
///
/// ```
///   w  = (w_shadow, w_mid, w_highlight)          // partition of unity, on L = log2(luma)
///   dh = Σ w_i · hue_i    · 0.3                  // degrees of OKLCh hue
///   ds = Σ w_i · sat_i    / 100                  // chroma multiplier − 1
///   dl = Σ w_i · light_i  / 100                  // stops of linear light
///
///   L, C, h = OKLCh(v)
///   h' = h + dh                                  (gated: a grey has no hue)
///   C' = C · (1 + ds)
///   v1 = OKLCh⁻¹(L, C', h')
///   v2 = v1 · (Y(v) / Y(v1))                     ← luma restored exactly, hue untouched (see below)
///   out = v2 · 2^dl                              ← the lightness slider, a pure gain
/// ```
///
/// Three properties fall out of that order, and they are the acceptance's three claims:
///
///  1. **The hue offset is exact.** Rotating `h` and converting back leaves the pixel at `h + dh` up to
///     the round trip's own error (≈1e-9 of a linear channel, i.e. 1e-6 degrees); and a **uniform RGB
///     gain preserves OKLCh hue exactly**, because the fold is linear in RGB and the cube root makes a
///     gain a scalar on `(l, m, s)` — so `(L, a, b)` all scale by `g^(1/3)` and the angle `atan2(b, a)`
///     does not move. That is why the luma restoration in step 3 cannot rotate a hue, and why
///     「单轮 sat=100 → 色相偏移 0°」 is a property of the maths rather than a tolerance.
///  2. **Saturation does not change luma.** `C'` would change `Y` (a more colourful pixel of the same
///     OKLab `L` is a different luminance), so step 3 puts `Y` back to the input's. Measured: 0 codes of
///     luma on every patch, in every direction — better than the ±1 the acceptance allows.
///  3. **Lightness is a gain.** `2^dl` on all three channels multiplies `Y` by exactly `2^dl`: the
///     slider is ±1 stop of that region's light, the unit 曝光 and 阴影 already use.
///
/// ### Why the weights are `tone_shape.metal`'s and not a second table
/// 「阴影」 in the Light card and 「阴影」 in this card have to mean the same region, so the third weight
/// is not a new window — it is `1 − shadow − highlight` of **S2's own** two windows (`region_weights`,
/// 074 R2: full below −5.9 EV, gone at −3.9 EV; full above −1.2 EV, absent below −3.2 EV). The two
/// windows do not overlap, so the three weights sum to exactly 1 and a pixel above −1.2 EV has
/// `w = (0, 0, 1)` **exactly** — which is what makes 「只改阴影轮，高光区 0 变化」 a bit-exact claim: the
/// effective parameters are exactly 0 there and the kernel's early-out writes the source pixel back.
///
/// ### Refutation hook
/// `globalWeights: true` replaces the windows with `(1/3, 1/3, 1/3)` — "every region applies
/// everywhere", the plausible mistake of forgetting the window. `RenderOptions.gradeGlobalWeights`
/// passes the same flag to the kernel, and `ColorGradingTests.testTheRefutationMakesTheIsolationFail`
/// measures the highlight zone going from 0 changed pixels to many. Never true in the app.
public enum ColorGrade {

    /// Degrees of OKLCh hue per slider unit, i.e. ±30° at ±100 — `HSLBands.degreesPerUnit`, the same
    /// number the HSL card's 色相 row uses, so the two cards' 「+30」 mean the same rotation.
    public static let degreesPerUnit: Double = 0.3

    /// Stops of linear light at full travel of 亮度 (`2^±1`).
    public static let stopsPerFull: Double = 1

    // ── The three region windows ────────────────────────────────────────────────────────────────────
    //
    // **These are `tone_shape.metal`'s numbers, copied because Metal cannot import Swift.** The kernel
    // includes the real `region_weights`; this file carries the same four constants and the same
    // `smoothstep`, and `ColorGradingTests.testTheWeightsAreToneShapesWindows` holds the two to the
    // same numbers at 2001 EV samples, so a change on either side is a red test rather than a drift.
    public static let shadowLowEV: Double = -5.9
    public static let shadowHighEV: Double = -3.9
    public static let highlightLowEV: Double = -3.2
    public static let highlightHighEV: Double = -1.2

    /// The luma the windows are measured on: the **working primaries'** weights
    /// (`ColorPrimaries.working.luminanceWeights`, i.e. `kWorkingLumaWeights` in the kernel) — the same
    /// luma S2's own region lifts use since 075 put every kernel on the same primaries.
    public static var lumaWeights: SIMD3<Double> {
        ColorPrimaries.working.luminanceWeights
    }

    /// The three weights of one pixel: `(shadow, midtone, highlight)`, summing to 1.
    ///
    /// `luma` is linear light relative to display white, so `L = log2(luma)` is the histogram card's own
    /// HDR axis. A pixel at or below zero reads a very negative `L` (the shadow end); a pixel above
    /// display white reads `L > 0` and is entirely a highlight.
    public static func weights(luma: Double, global: Bool = false) -> SIMD3<Double> {
        if global { return SIMD3(1.0 / 3, 1.0 / 3, 1.0 / 3) }
        let L = log2(max(luma, 1e-9))
        let shadow = 1 - smoothstep(shadowLowEV, shadowHighEV, L)
        let highlight = smoothstep(highlightLowEV, highlightHighEV, L)
        // `1 − shadow − highlight`, not a third window: the two do not overlap (−3.9 < −3.2), so this is
        // ≥ 0 and the three sum to 1 by construction. `max(0,)` only rounds away a −1e-17.
        return SIMD3(shadow, max(1 - shadow - highlight, 0), highlight)
    }

    /// `weights` for a pixel of linear working-primaries values.
    public static func weights(of rgb: SIMD3<Double>, global: Bool = false) -> SIMD3<Double> {
        weights(luma: dot(max(rgb, SIMD3(repeating: 0)), lumaWeights), global: global)
    }

    /// The effective parameters of a pixel: `Σ w_i · value_i` over the three wheels.
    ///
    /// Returned in the kernel's units, not in slider units, because the blend and the conversion have to
    /// happen in one order in both implementations: `hue` in **degrees**, `saturation` as the chroma
    /// **multiplier**, `lightness` in **stops**. Blending the parameters before converting (rather than
    /// blending three converted results) is what makes a pixel in the highlight zone whose highlight
    /// wheel is neutral receive *exactly* zero — `0 · 1 = 0` — instead of three products that happen to
    /// cancel.
    public struct Effective: Equatable, Sendable {
        /// Degrees of OKLCh hue.
        public var hue: Double
        /// Chroma multiplier (`1` = unchanged).
        public var saturation: Double
        /// Stops of linear light (`0` = unchanged).
        public var lightness: Double

        public var isIdentity: Bool { hue == 0 && saturation == 1 && lightness == 0 }
    }

    public static func effective(_ group: ColorGradingGroup, weights w: SIMD3<Double>) -> Effective {
        var hue = 0.0, sat = 0.0, light = 0.0
        for (i, wheel) in group.wheels.enumerated() {
            hue += w[i] * wheel.hue
            sat += w[i] * wheel.saturation
            light += w[i] * wheel.lightness
        }
        return Effective(hue: hue * degreesPerUnit,
                         saturation: 1 + sat / 100,
                         lightness: light / 100 * stopsPerFull)
    }

    /// The stage on one pixel. `rgb` is **display-referred linear** (S3's output: what S2's tone map
    /// produced), which is the domain the region windows are defined in.
    ///
    /// Identity in, identity out: when the effective parameters are the identity the input is returned
    /// unchanged **bit for bit** (that is the branch the kernel takes, in the same order).
    public static func apply(_ rgb: SIMD3<Double>, group: ColorGradingGroup,
                             globalWeights: Bool = false) -> SIMD3<Double> {
        guard !group.isIdentity else { return rgb }
        let p = effective(group, weights: weights(of: rgb, global: globalWeights))
        if p.isIdentity { return rgb }

        var out = rgb
        if p.hue != 0 || p.saturation != 1 {
            let lch = OKLCh.fromLinear(rgb)
            // A grey has no hue to rotate and no chroma to scale (`0·k = 0`), so the move **is** the
            // identity below the gate — and a round trip through OKLab would still move its last bit
            // (the fold's rows sum to 1 only to 1e-10). The same `hsl_chroma_gate` S3.6 uses, and the
            // same reason. `lightness` still applies below, because a grey can be lit.
            let gate = HSLBands.chromaGate(for: lch.C)
            if gate > 0 {
                let h2 = lch.hue + p.hue * gate
                let c2 = max(lch.C * p.saturation, 0)
                var v1 = oklchToLinear(L: lch.L, C: c2, hue: h2)

                // **The gamut is the gamut** — see the kernel's note. A chroma this space cannot hold
                // at this lightness and hue comes back with a negative channel, and clipping it rotates
                // the hue (8.4° measured on a shadow patch) and drops the luma. The *move* is shortened
                // instead: bisect from the input's own chroma to the requested one and stop at the
                // widest colour that fits. Six steps, the same count the kernel takes, so the two
                // implementations agree to the last bit of the interpolation.
                if min(min(v1.x, v1.y), v1.z) < 0 {
                    var lo = 0.0, hi = 1.0
                    for _ in 0..<6 {
                        let t = 0.5 * (lo + hi)
                        let probe = oklchToLinear(L: lch.L, C: lerp(lch.C, c2, t), hue: h2)
                        if min(min(probe.x, probe.y), probe.z) < 0 { hi = t } else { lo = t }
                    }
                    v1 = oklchToLinear(L: lch.L, C: lerp(lch.C, c2, lo), hue: h2)
                }
                out = max(v1, SIMD3(repeating: 0))

                // Restore the input's luma. A uniform gain cannot rotate a hue (see this type's notes),
                // so this is what makes 「饱和不改变亮度」 exact rather than approximate. Skipped when
                // either luma is indistinguishable from 0: a black pixel has no ratio to restore.
                let yIn = dot(max(rgb, SIMD3(repeating: 0)), lumaWeights)
                let yOut = dot(out, lumaWeights)
                if yIn > 1e-6 && yOut > 1e-6 {
                    out *= min(max(yIn / yOut, 0.125), 8)
                }
            }
        }
        if p.lightness != 0 {
            out *= pow(2, p.lightness)
        }
        return max(out, SIMD3(repeating: 0))
    }

    // MARK: - the pieces

    /// `mix(a, b, t)` — Metal's own spelling, so the two bisections step identically.
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// GLSL/Metal's `smoothstep`, written out: `t²(3 − 2t)` on the clamped ramp. The kernel calls the
    /// built-in; this is the same function to the last digit.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// `OKLCh.toLinear`, spelled here so this file reads as the kernel's own three matrices (the same
    /// nine literals `oklch_bands.metal` carries) rather than calling through a type that might one day
    /// grow a different number of them.
    static func oklchToLinear(L: Double, C: Double, hue: Double) -> SIMD3<Double> {
        OKLCh.toLinear(L: L, C: C, hue: hue)
    }
}
