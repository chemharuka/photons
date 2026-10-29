import Foundation

/// 098 — **contrast as a multiscale, edge-aware decomposition of `Y`**, in the scene-linear domain.
///
/// The one place for the new stage's numbers, so the kernel, the render graph and the tests cannot
/// drift apart (the same discipline as `S2Contrast` and `HDRCurve.axis`):
///
///     Y    = max(dot(max(rgb, 0), Rec2020 weights), 1e-6)
///     G    = log2(Y)
///     B_c  = GF(G,  r_c, ε_c)                 // coarse base
///     D1   = G − B_c
///     B_m  = GF(D1, r_m, ε_m)                 // mid band
///     D_f  = D1 − B_m                         // fine band (no filter)
///     G′   = P + k_c·(B_c − P) + gate·(k_m·B_m + k_f·D_f)
///     rgb′ = max(rgb, 0) · 2^(G′ − G)
///
/// The gain is a single scalar applied to all three channels, so every chroma ratio (`R/Y`, `G/Y`,
/// `B/Y`) — and therefore hue and saturation — is preserved exactly.
///
/// There is **no black or white end point**: the only anchor is the fixed pivot `P` and the three
/// multiplicative gains. Nothing here clamps above display white, so an HDR sample is expanded by
/// the same pivot arithmetic as a mid-tone (the property 079 §4 established for S2).
///
/// The `.metal` copy of these numbers is `MC_*` in `Kernels/s1_8_contrast.metal`;
/// `ContrastMultiscaleTests.testTheKernelConstantsAreTheSwiftConstants` parses the kernel and
/// asserts the two copies are equal, because a kernel cannot import Swift.
public enum MultiscaleContrast {

    /// The fixed pivot, in EV relative to display white. Deliberately not an end point: `+100`
    /// stretches the whole axis away from it, `−100` compresses towards it, and the same rule applies
    /// at `Y = 0.02` and `Y = 8`.
    public static let pivotEV: Double = -3.5

    /// The guided filter's amplitude threshold for the coarse band, in log2 units. A ±0.1 EV texture
    /// has variance ≈ 2.5e-3 and keeps ~20 % of its residual; a 0.5 EV edge has ≈ 0.25 and is treated
    /// as structure (`a → 1`).
    public static let coarseEpsilon: Double = 0.010

    /// The same threshold for the mid band. Smaller, because the mid band has already had the coarse
    /// base removed and its residual is smaller.
    public static let midEpsilon: Double = 0.004

    /// Full-scale coarse gain exponent: `k_c = 2^(1.00 · t)`.
    public static let coarseWeight: Double = 1.00
    /// Full-scale mid gain exponent: `k_m = 2^(0.50 · t)`.
    public static let midWeight: Double = 0.50
    /// Full-scale fine gain exponent: `k_f = 2^(0.25 · t)`. The cap is **intentional** (098 §6): the
    /// fine band overlaps S3.9's 清晰度, so it is given only a quarter of the coarse travel.
    public static let fineWeight: Double = 0.25

    /// The gradient gate's knees, in **log2 luma per 1/q texel** (the same construction as
    /// `s3_8_guide_coeff`). A step moves the window mean by ~0.1 per texel, a smooth gradient by
    /// ~1e-3, so this passes every gradual transition and stops every structural edge.
    public static let gateLo: Double = 0.015
    public static let gateHi: Double = 0.06

    /// Statistics block, in pixels. `4` is not a knob: a 2…8 px pattern averages out, a step edge
    /// does not.
    public static let block: Int = 4

    /// Coarse radius as a fraction of the frame's short edge, in the 1/q domain, with a cap.
    public static let coarseRadiusFraction: Double = 0.06
    public static let coarseRadiusCap: Int = 96
    /// Mid radius as a fraction of the frame's short edge, in the 1/q domain, with a cap.
    public static let midRadiusFraction: Double = 0.02
    public static let midRadiusCap: Int = 24

    /// The three bands of one pixel, in EV.
    public struct Bands: Sendable, Equatable {
        public var coarse: Double
        public var mid: Double
        public var fine: Double

        public init(coarse: Double, mid: Double, fine: Double) {
            self.coarse = coarse
            self.mid = mid
            self.fine = fine
        }
    }

    /// `t = contrast / 100` → the three multiplicative gains.
    public static func scaleGains(t: Double) -> (coarse: Double, mid: Double, fine: Double) {
        (pow(2, coarseWeight * t), pow(2, midWeight * t), pow(2, fineWeight * t))
    }

    /// Radius in the 1/q domain: `fraction · shortEdge / q`, rounded, floored at 1 and capped.
    public static func radiusQ(fraction: Double, cap: Int, shortEdge: Double) -> Int {
        let texels = (fraction * shortEdge / Double(block)).rounded()
        return min(max(Int(texels), 1), cap)
    }

    /// The gain the kernel applies to a pixel whose linear luma is `Y`, given its three bands.
    ///
    /// **147 — the pivot is read on the unexposed scale.** S1 multiplies the frame by
    /// `exposureGain = 2^EV` before this stage, so a fixed `P` slid relative to the mid-grey at every
    /// exposure and the coarse term `k_c·(B_c − P)` changed direction (measured p50 0.849 → 1.510).
    /// The kernel divides the luma by `exposureGain` *before* the `1e-6` floor and the log, which is
    /// this function's `G0 = log2(max(Y / g, 1e-6))`; `P` stays the constant above. `g == 1` is the
    /// old arithmetic bit for bit.
    ///
    /// `contrast == 0` is the exact identity (`kBands == 0` and `2^0 == 1`), which is what makes the
    /// stage's absence equivalent to its presence at zero.
    public static func gainRatio(Y: Double, bands: Bands, contrast: Double,
                                 exposureGain: Double = 1) -> Double {
        guard contrast != 0, Y.isFinite else { return 1 }
        let G = log2(max(Y / max(exposureGain, 1e-9), 1e-6))
        let k = scaleGains(t: contrast / 100)
        let gPrime = pivotEV + k.coarse * (bands.coarse - pivotEV)
            + k.mid * bands.mid + k.fine * bands.fine
        return pow(2, gPrime - G)
    }
}
