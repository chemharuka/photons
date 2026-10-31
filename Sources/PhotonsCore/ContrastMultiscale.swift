import Foundation

/// 159 — **contrast as a multiscale, edge-aware decomposition of `Y`**, in the **display-referred**
/// domain (S2.5, after S2 and before S3). 098 put the same decomposition in the scene-linear domain
/// with a fixed pivot of −3.5 EV; 142 measured that this made `exposure × contrast` non-commutative
/// (p50 gain 0.666 at E0 vs 2.695 at E+2, 74 % of pixels changing sign) and 155 measured that the
/// masked contrast was a *different* operator. Both are consequences of anchoring a gain to an
/// absolute scene-linear level. This is the display-domain replacement, and it is deliberately
/// **homogeneous**: every term is a residual of the multiscale decomposition, so multiplying the
/// picture by an exposure gain shifts `G` and `B_c` together and leaves the contrast gain untouched.
///
/// The one place for the stage's numbers, so the kernel, the render graph and the tests cannot drift
/// apart (the same discipline as `S2Contrast` and `HDRCurve.axis`):
///
///     Y    = max(dot(max(rgb, 0), Rec2020 weights), 1e-6)      // display Y, white = 1 = 0 EV
///     G    = log2(Y)
///     B_c  = GF(G,  r_c, ε_c)                 // coarse base
///     D1   = G − B_c
///     B_m  = GF(D1, r_m, ε_m)                 // mid band
///     D_f  = D1 − B_m                         // fine band (no filter)
///     G′   = G + gate·(W_m·B_m + W_f·D_f)     // residuals only: a level anchor is the 142 bug
///     rgb′ = max(rgb, 0) · 2^(G′ − G)
///
/// `W_m`/`W_f` carry the slider: `W = t · w`, `t = contrast/100`, so `contrast = 0` is exactly the
/// identity (`2^0 = 1`) and the stage at +100 multiplies the mid/fine residuals by `w` in EV. The
/// display-domain log amplitude of a scene is about a quarter of the scene-linear one (a tone-mapped
/// frame spans ~2.3 EV where the scene spans 4+), so a pure ×4 on 098's band travels is the *floor*:
/// the shipped pair is ×15 (`0.50 → 7.50`, `0.25 → 3.75`), because the display-domain ε (0.80/0.32)
/// leaves a much larger fraction of the window's variance in the residual than 098's 0.010/0.004 did,
/// and the weight has to grow with the residual it has to move. The ε thresholds are squared log2
/// units and are ×80 098's (0.010/0.004 → 0.80/0.32), which is the "keep the residual" half of the
/// same rule; the gradient gate is log2-per-texel and is *not* on that rule (0.015/0.06 → 0.05/2.00,
/// see `gateLo`). Those numbers are what make the same slider produce the same local detail in the
/// new domain — A4/A5 of 159 pin them, `testA4StepEdgeResponseIsConfinedAndDoesNotRing` /
/// `testA5CoarseGradientIsUntouchedAndBothBandsExpand` re-take the measurement.
///
/// The gain is a single scalar applied to all three channels, so every chroma ratio (`R/Y`, `G/Y`,
/// `B/Y`) — and therefore hue and saturation — is preserved exactly.
///
/// There is **no black or white end point** and no fixed level anchor. Nothing here clamps above
/// display white, so an HDR sample is expanded by the same residual arithmetic as a mid-tone (the
/// property 079 §4 established for S2).
///
/// The `.metal` copy of these numbers is `MC_*` in `Kernels/s1_8_contrast.metal`;
/// `ContrastMultiscaleTests.testTheKernelConstantsAreTheSwiftConstants` parses the kernel and
/// asserts the two copies are equal, because a kernel cannot import Swift.
public enum MultiscaleContrast {

    /// The pivot, in EV relative to display white (`0` = display white). 159: the stage is
    /// display-referred, so the coordinate's origin is white, not 098's scene-linear −3.5 EV. The
    /// kernel does not add the pivot back — the gain is built from residuals — but the number stays
    /// in the uniform so a log line names the coordinate the bands were measured in.
    public static let pivotEV: Double = 0

    /// The guided filter's amplitude threshold for the coarse band, in squared display-log2 units.
    /// 098's 0.010 measured a scene log whose local variance is ~16× larger; a threshold that small
    /// in the display coordinate makes `a → 1` (`B_c → G`), i.e. the decomposition has no residual
    /// left to shape. 0.25 keeps the same *fraction* of a window's variance as structure.
    public static let coarseEpsilon: Double = 0.80

    /// The same threshold for the mid band, a quarter of the coarse one as in 098.
    public static let midEpsilon: Double = 0.32

    /// Full-scale mid-band travel, in EV per EV of display log residual. 098's `k_m` was
    /// `2^(0.5·t)`, i.e. **0.50 EV of travel at +100** in the scene-linear coordinate. The display
    /// log is ~1/4 as wide, so 0.50 × 4 = 2.00 is where equal-EV travel would put it; that is only
    /// the floor, because the residual this weight acts on is *smaller* here: with ε = 0.80 the
    /// guided filter keeps a far bigger fraction of the window than 098's 0.010 did, so `B_m` — the
    /// band the mid weight multiplies — is a quarter of the band, not half of it. 0.50 × 15 = 7.50
    /// is the travel that reproduces 098's *visible* mid-band response; A4/A5 of 159 measure that
    /// response (mid- and fine-scale detail must expand, a coarse-only gradient must not move).
    public static let midWeight: Double = 7.50
    /// Full-scale fine-band travel. 098's band ratio is kept exactly: its fine travel was 0.25 to a
    /// 0.50 mid, i.e. **half** the mid band, and 7.50 / 2 = 3.75 carries that 2:1 ratio through the
    /// ×15 above. The fine band overlaps S3.9's 清晰度, so it must not become a second clarity —
    /// that is why the cap is half the mid rather than equal to it.
    public static let fineWeight: Double = 3.75
    /// 098's coarse *level* term (`k_c·(B_c − P)`) is **gone**: a gain anchored to an absolute level
    /// is exactly what made exposure and contrast non-commutative (142). Kept as a named zero so a
    /// reader looking for it finds the reason instead of a dangling comment.
    public static let coarseWeight: Double = 0

    /// The gradient gate's knees, in **display log2 luma per 1/q texel**. 098's 0.015/0.06 measured
    /// the scene log; the display log is 1/4 as wide, so the same *relative* knee is 4× larger here
    /// — 0.06/0.24, not 0.06/4 — because dividing would shut the gate over ordinary texture. That
    /// ×4 is still the floor: the gate reads the gradient of the *window mean* in the q domain, and a
    /// real display step (A4's 0.06 → 0.50 linear = 3 EV) is ~0.8 per texel after the q = 4 block
    /// mean, i.e. **above 0.24** — a 0.24 upper knee would close the gate on exactly the edges the
    /// decomposition is supposed to leave alone. The shipped pair is 0.05/2.00: closed only for a
    /// jump of a full 2 stops per texel, so this is the one number in the block that is not the ×4
    /// rule, and the reason is the gate's input, not the domain width.
    public static let gateLo: Double = 0.05
    public static let gateHi: Double = 2.00

    /// 159/A5 — the **display black floor**, in linear light: display code `0.012` (the A5
    /// threshold). A pixel that already clears the floor is never darkened below it; a pixel under
    /// it is left where it is. This is the one absolute statement in the operator, and it is about
    /// the *output* picture, not about the gain: the residual gain itself stays homogeneous.
    public static let floorY: Double = 0.00110

    /// Statistics block, in pixels. `4` is not a knob: a 2…8 px pattern averages out, a step edge
    /// does not.
    public static let block: Int = 4

    /// 187 — the **whole-picture statistics proxy's** long edge, in picture pixels. The coefficient
    /// maps S2.5 samples are built once at this resolution and cached, so every framing (fit, 25 %,
    /// 1:1, a panned 1:1 window) samples *the same* map: the gain of a physical pixel cannot depend
    /// on where the window happens to be or on `options.scale`.
    ///
    /// 1024 is a measurement, not a guess: at 1024 the coarse radius is 0.06·1024/4 ≈ 15 q-texels of
    /// support (the decomposition still has its three bands), the map is 256×160 q-texels ≈ 1.2 MB,
    /// and a picture at or below 1024 px is *its own* proxy — `proxyScale == 1`, so those renders
    /// (every synthetic test frame, every small document) keep the pre-187 coefficients **bit for
    /// bit** through the kernel's direct-read path.
    public static let statisticsLongEdge: Int = 1024

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

    /// `t = contrast / 100` → the two bands' EV travels, as **additions to the residual**.
    ///
    /// The coarse slot is kept at 0 (see `coarseWeight`); a caller that wants the identity asks for
    /// `t = 0`, which is exactly `(0, 0)`.
    ///
    /// **The two signs are not the same law, and that is the 187 fix.** Above zero the slider is a
    /// travel: `k = W · t` EV of the band, applied to `B_m` and `D_f`. Below zero that formula is
    /// wrong, and catastrophically so: at `t = −1` it asks for `−7.5 · B_m`, i.e. the residual
    /// amplified 7.5× **and sign-flipped** — a negative picture, which is what the user reported
    /// ("对比拉到负现在直接变成反相"). Negative contrast is not an inverted travel; it is *less*
    /// local contrast, so the band multiplier must be a **shrink** that never changes sign:
    ///
    ///     m(t) = 1 + k(t)   with   k(t) = W · t      for t ≥ 0   (m: 1 → 1 + W)
    ///                              k(t) = 2^t − 1    for t < 0   (m: 1 → 0.5, **no W**)
    ///
    /// The `W` factors are travels — they belong to amplification only. On the shrink side the
    /// weight is in **residual units** (`2^t − 1`, multiplied by the residual itself), which is why
    /// `scaleGains` returns `(0, k, k)` there and not `(0, W_m·k, W_f·k)`: with the travel applied to
    /// a negative `k` the mid band asked for `−3.75·B_m`, still a 3.75× inversion.
    ///
    /// so `m ∈ [0.5, 1 + W]` — strictly positive and monotone in `t`, exactly 1 at `t = 0`, and at
    /// `−100` the local residual is halved (「明显 <1 但 >0」). The positive half is **unchanged**,
    /// which is why every pre-187 measurement at `c > 0` and every contrast-0 golden stays put.
    public static func scaleGains(t: Double) -> (coarse: Double, mid: Double, fine: Double) {
        guard t != 0 else { return (0, 0, 0) }
        guard t > 0 else {
            // `2^t − 1` ∈ [−0.5, 0): the residual is multiplied by `2^t`, never by a negative number.
            let k = pow(2, shrink * t) - 1
            return (0, k, k)
        }
        return (coarseWeight * t, midWeight * t, fineWeight * t)
    }

    /// The **band multipliers** `1 + k(t)` — what the picture actually multiplies its residual by.
    /// Always positive and monotone in the slider; `1` at `contrast = 0`. Exposed because the tests
    /// state the invariant in these terms ("恒正且关于 0 单调"), not in the raw travels.
    public static func bandMultipliers(t: Double) -> (mid: Double, fine: Double) {
        let k = scaleGains(t: t)
        return (1 + k.mid, 1 + k.fine)
    }

    /// 187 — how far a **negative** slider shrinks the residual: the band multiplier is
    /// `2^(shrink · t)`, so at `c = −100` the local contrast is 0.59× (and at `c = 0`, 1× exactly).
    ///
    /// 0.75 is a measurement, not a taste: `2^t` (a full halving) removes 50 % of the residual and
    /// measures a **−1.21 code** drift of the picture's mean at `−100`, over §2's ±1 code; 0.75 lands
    /// at −0.91. The point of the shrink is to take local contrast away, never light.
    public static let shrink: Double = 0.75

    /// Radius in the 1/q domain: `fraction · shortEdge / q`, rounded, floored at 1 and capped.
    public static func radiusQ(fraction: Double, cap: Int, shortEdge: Double) -> Int {
        let texels = (fraction * shortEdge / Double(block)).rounded()
        return min(max(Int(texels), 1), cap)
    }

    /// The gain the kernel applies to a pixel whose display luma is `Y`, given its three bands.
    ///
    /// `contrast == 0` is the exact identity (`0 · band == 0` and `2^0 == 1`), which is what makes the
    /// stage's absence equivalent to its presence at zero.
    public static func gainRatio(Y: Double, bands: Bands, contrast: Double) -> Double {
        guard contrast != 0, Y.isFinite else { return 1 }
        let G = log2(max(Y, 1e-6))
        let k = scaleGains(t: contrast / 100)
        var d = k.coarse * bands.coarse + k.mid * bands.mid + k.fine * bands.fine
        // The white shoulder: a positive gain fades to 0 at display white (0 EV), so it cannot
        // push a pixel that is below white over it. Darkening is not faded.
        if d > 0 {
            d *= 1 - smoothstep(-1, 0, G)
            if G < log2(0.98) { d = min(d, max(0, log2(0.98) - G)) }
        }
        let ratio = pow(2, d)
        // The display black floor (A5): a pixel that clears it is not pushed under it.
        let y = max(Y, 0)
        if ratio < 1, y >= floorY, y * ratio < floorY { return floorY / y }
        return ratio
    }

    private static func smoothstep(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
        guard hi > lo else { return x >= hi ? 1 : 0 }
        let t = min(max((x - lo) / (hi - lo), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
