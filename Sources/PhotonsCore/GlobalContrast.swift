import Foundation

/// 228 — **global contrast in the gain domain**, after the tone map (S2.5).
///
/// 159 replaced 0107's global bend with a multiscale, edge-aware decomposition of `Y`, and the owner's
/// report is that this is a *local* contrast: it competes with 清晰度/细节 and a smooth ramp passes
/// through untouched (measured on a 30-step EV ramp at `contrast = ±100`: every `out/in` ratio is
/// 0.9985…1.0004, i.e. the operator has no global slope). This is the restoration: one global power
/// curve on the **unexposed display luma**, applied as a per-pixel gain to all three channels.
///
///     Y    = max(dot(max(rgb, 0), lumaWeights), 1e-9)     // display linear, can exceed 1 (HDR)
///     G    = log2(Y / exposureGain)                       // EV, white = 1 = 0 EV
///     P    = log2(pivot)                                  // the mid-grey pivot, linear 0.18
///     γ    = 2^(contrast / 100 · travelEV)
///     G′   = P + γ·(G − P)
///     gain = 2^(G′ − G) = ((Y / exposureGain) / pivot)^(γ − 1)
///     rgb′ = max(rgb, 0) · gain
///
/// The gain is computed on `Y / exposureGain` and multiplied back onto the **exposed** pixel, which is
/// what makes the slider commute with S1's exposure: with a neutral curve `Y(E) = 2^E·Y(0)`, so the
/// gain field is independent of `E` and the output is `2^E` times the `E = 0` output. It is the same
/// construction 159 used (`G = log2(Y / exposureGain)`), kept here because it is the operator order
/// contract (174 §0).
///
/// **The two signs are inverse.** `γ(c)` and `γ(−c) = 1/γ(c)` are powers about the same pivot, so
/// `f₋(f₊(Y)) = Y`; on one ramp `log2(out/in)` has opposite signs and equal magnitudes.
///
/// **No clamp.** The curve is a power and a multiply, so the HDR range (`Y > 1`, up to the display's
/// 4.926× / +2.303 EV) is expanded by the same arithmetic as the SDR range. Nothing here fades the
/// gain at white or caps the output — that was 159's display shoulder and it is what made the HDR
/// segment pass through.
///
/// **Masks.** A mask's `contrast` is the same curve scoped by its coverage; a full-canvas mask is the
/// global slider (the kernel's masked entry is the only entry, and the global path binds mask count 0).
/// `079`'s 「同一滑杆蒙版内外同义」 is therefore structural, not a second body.
///
/// The constants here are passed to the kernel in its uniform (`ContrastParams.a`), so the `.metal`
/// file has no copy of them: the CPU and the GPU cannot drift.
public enum GlobalContrast {

    /// The linear display light the power curve is anchored to: mid-grey, the same 0.18 the old
    /// global bend used before 0107. `contrast = 0` is the identity at every pivot, so this number is
    /// only visible at a non-zero slider.
    ///
    /// 265 — the kernel can only see the 16-bit-float picture, where mid-grey is `half(0.18)` =
    /// 0.1800537, not this Double. `s1_8_contrast.metal` therefore rounds the pivot to that grid
    /// before taking `log2`: otherwise the flat is 4.3e-4 EV above its own pivot, the sub-code gain is
    /// stored with a truncating float→half write, and a flat frame loses one code on the negative
    /// side (measured 1474/1475 = 0.9993220 at every negative contrast). The CPU reference here stays
    /// on the exact Double so `gain(0.18, c) == 1`; the two differ by < 3e-4 relative, i.e. below one
    /// display code over the whole slider range.
    public static let pivot: Double = 0.18

    /// Full-scale travel in EV: the exponent is `2^(contrast/100 · travelEV)`. It is not a new magic
    /// number — it is the tone map's own axis normalisation (`S2Contrast.travelEV`, `8/(0−(−8))`),
    /// so "±100" means the same bend here as it did in the global version this restores.
    public static var travelEV: Double { S2Contrast.travelEV }

    /// `γ = 2^(contrast/100 · travelEV)`. Exactly `1` at `contrast = 0`, and `γ(−c) = 1/γ(c)`.
    public static func gamma(contrast: Double) -> Double {
        pow(2, contrast / 100 * travelEV)
    }

    /// `f(Y) = pivot·((Y/exposure)/pivot)^γ`: the target display luma. Exposed light goes in, the
    /// unit-exposure picture is curved, and the exposure is multiplied back out.
    public static func outputLuma(_ luma: Double, contrast: Double, exposureGain: Double = 1) -> Double {
        guard contrast != 0, luma.isFinite, exposureGain > 0 else { return luma }
        guard luma > 0 else { return luma }
        let unexposed = max(luma / exposureGain, 1e-9)
        return exposureGain * pivot * pow(max(unexposed / pivot, 1e-9), gamma(contrast: contrast))
    }

    /// The per-pixel gain `f(Y)/Y` the kernel applies to all three channels.
    public static func gain(luma: Double, contrast: Double, exposureGain: Double = 1) -> Double {
        guard contrast != 0, luma.isFinite, luma > 0 else { return 1 }
        return outputLuma(luma, contrast: contrast, exposureGain: exposureGain) / luma
    }
}
