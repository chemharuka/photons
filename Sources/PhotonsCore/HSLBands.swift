import Foundation
import simd

// MARK: - OKLCh (派单 076)

/// **OKLCh** — OKLab re-read as (lightness, chroma, hue) — and the eight-band maths the HSL stage
/// runs on it.
///
/// This file is the **CPU reference** for `Kernels/s3_6_hsl.metal`: the kernel is written against the
/// numbers and the algebra here, `HSLTests` renders both and holds them together, and the UI reads
/// `centresDegrees` so the eight selector dots sit where the maths actually puts the bands. It is not
/// a second implementation the way `LocalColorStageTests`' HSL helpers are (that one is deliberately
/// independent); this one is the *definition*, and the kernel is checked against it.
///
/// ### Why this space (079 结论 4)
/// The graph's old band maths ran `rgb_to_hsl` on **linear** Rec.2020 values. HSL is a device-space
/// construction: its `l` is `(max + min)/2` of whatever three numbers it is handed, so on linear light
/// pure blue and pure yellow both read `l = 0.5` while their actual luminance differs by 6.9×
/// (0.0722 vs 0.500 with Rec.2020 weights) — one luminance slider, two different meanings. OKLab's `L`
/// is designed to be perceptually even, and measured on the same two colours it gives 0.452 and 0.968,
/// i.e. an order that matches what an eye sees. darktable (`colorzones` in Lab/LCh) and
/// `colorbalancergb` (Filmlight Ych) both refuse linear HSL for the same reason; **no** vendor in
/// 079's survey runs HSL in linear light.
///
/// The conversion is the graph's own `OKLabMetric.lmsFold` — the Rec.2020 fold 075 derived — so the
/// stage agrees with the mask atlas about what a colour is, to the last digit.
public enum OKLCh {

    /// Linear **working primaries** → OKLCh. `hue` is degrees in `[0, 360)`.
    ///
    /// `a`/`b` are the raw Ottosson axes (not divided by `OKLabMetric.chromaSpan`): a chroma here is
    /// the real OKLCh `C`, which is what a saturation slider has to multiply and what the neutral gate
    /// is measured against.
    public static func fromLinear(_ rgb: SIMD3<Double>) -> (L: Double, C: Double, hue: Double) {
        let lab = OKLabMetric.fromLinear(rgb.x, rgb.y, rgb.z)
        let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        var h = atan2(lab.b, lab.a) * 180 / .pi
        if h < 0 { h += 360 }
        // `atan2(0, 0)` is 0 by IEEE, so a neutral pixel answers "red's direction" — meaningless, and
        // harmless because every consumer multiplies by a chroma gate that is exactly 0 there.
        return (lab.L, c, h)
    }

    /// OKLCh → linear working primaries.
    ///
    /// The inverse of `OKLabMetric.fromLinear`: `M₂⁻¹` (the published Ottosson OKLab matrix, inverted),
    /// cube, then `fold⁻¹`. Both are nine literals derived once (`HSLTests` pins the round trip and the
    /// primaries), mirroring the kernel's own three matrices so the two cannot drift.
    public static func toLinear(L: Double, C: Double, hue: Double) -> SIMD3<Double> {
        let h = hue * .pi / 180
        let a = C * cos(h), b = C * sin(h)
        let l_ = 0.9999999985 * L + 0.3963377922 * a + 0.2158037581 * b
        let m_ = 1.0000000089 * L - 0.1055613423 * a - 0.0638541748 * b
        let s_ = 1.0000000547 * L - 0.0894841821 * a - 1.2914855379 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return SIMD3(2.1399067200 * l - 1.2463894955 * m + 0.1064827755 * s,
                     -0.8847358342 * l + 2.1632309414 * m - 0.2784951073 * s,
                     -0.0485737534 * l - 0.4545031404 * m + 1.5030768938 * s)
    }
}

// MARK: - the eight bands

/// The HSL stage's band geometry and weights — the thing the kernel computes per pixel, on the host.
///
/// ### The eight bands, and why eight (076 §2)
/// The selector is Lightroom's: 红 / 橙 / 黄 / 绿 / 青 / 蓝 / 紫 / 品红. Fewer bands cannot separate
/// "warm skin" from "orange sunset" (both live inside one wide orange band) and cannot name cyan at
/// all — the four-colour wheels photographers actually talk in (red/green/blue plus the secondaries)
/// come out of 8 as the six primaries/secondaries plus the two in-between hues; more than eight becomes
/// a hue curve and stops being a band selector (darktable's `colorzones` *is* a hue curve, with 8
/// control nodes — 079 §2.6.2 — which is the same eight).
///
/// ### The centres are OKLCh angles, not sRGB HSL angles
/// A hue angle is not a colour; it is a direction in whichever basis the three numbers live in. The
/// existing wheel's `bandCentresDegrees` solved exactly this problem once already (075: it re-derived
/// Lightroom's `[0, 30, 60, 120, 180, 240, 285, 315]` in the working primaries). The same eight
/// *physical* colours — `hsl(h, 0.85, 0.5)` in sRGB, converted to the working space — now get their
/// angle **in OKLCh**, which is the space the maths runs in:
///
/// | band | sRGB HSL | OKLCh hue | gap to next |
/// |---|---|---|---|
/// | 红   |   0° |  24.78° | 55.25° |
/// | 橙   |  30° |  80.03° | 29.39° |
/// | 黄   |  60° | 109.42° | 33.58° |
/// | 绿   | 120° | 143.00° | 52.00° |
/// | 青   | 180° | 195.00° | 79.46° |
/// | 蓝   | 240° | 274.46° | 46.38° |
/// | 紫   | 285° | 320.84° | 14.17° |
/// | 品红 | 315° | 335.01° | (49.77° back to 红) |
///
/// The gaps are **not** uniform, and that is a finding rather than an oversight: OKLCh hue is
/// perceptually even, so Lightroom's wheel — laid out in HSL, which is not — has 55° of it between red
/// and orange and only 14° between violet and magenta. Bands have to be spaced where the *colours* are,
/// not where the degrees are, or 紫 would act on pink and 品红 on nothing. The weights below adapt to
/// the local gap instead of assuming an eighth of a turn.
///
/// ### The weight function: a partition of unity, not eight overlapping tents
/// 079 结论 5 measured the old scheme: eight tents of ±45° renormalised **only when the sum exceeded
/// one**, so green at +100 delivered 25.93 units at 90°/150° and 100 at 120° — a 4× ripple around the
/// colour wheel, and 75°/165° got *nothing* from green at all.
///
/// This one is a partition of unity by construction. For each gap between two adjacent centres, the
/// two bands own the gap with a **complementary pair of smoothsteps**:
///
/// ```
/// w_i(h) = S(d_left / gap_left) + S(d_right / gap_right),      S(t) = 1 − smoothstep(t)
/// ```
///
/// Each term falls from 1 at `i`'s centre to exactly 0 at the neighbour's centre, the two terms in a
/// gap are `S(t)` and `S(1−t)`, and `smoothstep(t) + smoothstep(1−t) = 1` — so **Σw = 1 everywhere**,
/// including across the 0°/360° seam (the gaps are measured circularly). Consequences, all of which
/// `HSLTests` measures on a 1° sweep of the whole wheel:
///
///  * a band at its own centre has weight exactly 1 and no neighbour has any, so `+100` delivers
///    **100**, not 100 diluted by its neighbours;
///  * all eight bands at the same value deliver that value at **every** hue (measured ripple 0.00 %);
///  * the weights are `C¹` — no seam, no corner — so a hue gradient cannot band (measured: the whole
///    1°-per-pixel sweep moves by ≤ 1 code between neighbours).
///
/// The unconditional normalisation 076 asks for (`w_i /= Σw`) is still applied in both the kernel and
/// `shift(...)` below: `Σw` is 1 up to float rounding, the division is what makes that a guarantee
/// rather than a hope, and it also covers a caller that hand-writes a document with NaN bands.
public enum HSLBands {

    /// The eight band centres, in **OKLCh hue degrees**, as `Float` — the type the kernel is handed, so
    /// the CPU reference and the GPU see the same numbers bit for bit.
    public static let centresDegrees: [Float] = {
        // The same eight physical colours the wheel has always named (075 option A): Lightroom's HSL
        // angles at s = 0.85, l = 0.5, measured in OKLCh.
        let lightroom: [Double] = [0, 30, 60, 120, 180, 240, 285, 315]
        let toWorking = ColorPrimaries.conversion(from: .sRGB, to: ColorPrimaries.working)
        return lightroom.map { degrees in
            let w = toWorking.applying(to: ColorGroup.linearHSL(h: degrees / 360, s: 0.85, l: 0.5))
            return Float(OKLCh.fromLinear(w).hue)
        }
    }()

    /// How far each band reaches towards its neighbours: `[index] = (left, right)` in degrees, and
    /// **exactly the gap** to that neighbour — that is what puts a neighbour's weight at exactly 0 on
    /// this band's centre.
    public static let extents: [(left: Float, right: Float)] = {
        let n = centresDegrees.count
        return (0..<n).map { i in
            let next = centresDegrees[(i + 1) % n]
            let prev = centresDegrees[(i + n - 1) % n]
            let gapNext = Float(circularDistance(from: Double(centresDegrees[i]), to: Double(next)))
            let gapPrev = Float(circularDistance(from: Double(centresDegrees[i]), to: Double(prev)))
            return (left: gapPrev, right: gapNext)
        }
    }()

    /// Chroma below which the stage is exactly inert. `1e-6` is three orders below anything visible
    /// (sRGB chroma reaches ≈ 0.32), and it exists because "neutral" has to be **exact**: the OKLab
    /// fold's rows sum to 1 only to 1e-10, so a mathematically grey pixel comes back with
    /// `C ≈ 1e-8` and an arbitrary hue — enough, without this floor, to walk a grey through the
    /// conversion and change its last bit. The ramp above it is still a `smoothstep` (C¹ at both ends),
    /// so nothing steps.
    public static let chromaFloor: Double = 1e-6

    /// Chroma below which the stage fades out. `0.02` OKLCh chroma is a barely-there tint (sRGB
    /// chroma reaches ≈ 0.32), and the ramp is a `smoothstep` — so a neutral pixel gets **exactly** 0
    /// (the grey invariant, bit for bit) and a near-neutral gradient fades in smoothly instead of
    /// stepping at a threshold. 079 §2.6.3 measured the old `if (saturation > 1e-4)` switch as a
    /// visible contour between "grey" and "just past the line".
    public static let chromaGate: Double = 0.02

    /// One hue unit is 0.3°, the scale both the old band sliders and the mask hue use ("+30" = 9°).
    public static let degreesPerUnit: Double = 0.3

    public static func circularDistance(from: Double, to: Double) -> Double {
        var d = abs(from - to).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return d
    }

    /// One band's weight at `hueDeg`, the kernel's `hsl_band_weight` in Double.
    public static func weight(_ index: Int, hueDeg: Double) -> Double {
        let centre = Double(centresDegrees[index % centresDegrees.count])
        let e = extents[index % centresDegrees.count]
        var delta = (hueDeg - centre).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let reach = Double(delta >= 0 ? e.right : e.left)
        let d = abs(delta)
        guard d < reach else { return 0 }
        let t = d / reach
        return 1 - (t * t * (3 - 2 * t))
    }

    /// The eight-band shift at one hue, in **slider units** — the kernel's inner loop, on the host.
    ///
    /// Returns `(hue, saturation, luminance)` where hue is units of 0.3°, saturation and luminance are
    /// units of that slider's own mapping (see `apply`). Already gated by chroma and normalised by
    /// `Σw`; exactly `(0, 0, 0)` for a neutral pixel or a hue outside every band.
    public static func shift(hueDeg: Double, chroma: Double,
                             bands: [HSLBand]) -> (hue: Double, saturation: Double, luminance: Double) {
        let gate = chromaGate(for: chroma)
        guard gate > 0 else { return (0, 0, 0) }
        var wSum = 0.0
        var acc = (0.0, 0.0, 0.0)
        for i in 0..<min(bands.count, centresDegrees.count) {
            let w = weight(i, hueDeg: hueDeg)
            if w == 0 { continue }
            let b = bands[i]
            acc.0 += w * b.hue
            acc.1 += w * b.saturation
            acc.2 += w * b.luminance
            wSum += w
        }
        guard wSum > 0 else { return (0, 0, 0) }
        return (acc.0 / wSum * gate, acc.1 / wSum * gate, acc.2 / wSum * gate)
    }

    /// `smoothstep(chromaFloor, chromaGate, chroma)` — exactly 0 at and below the floor, exactly 1 at
    /// and above the gate.
    public static func chromaGate(for chroma: Double) -> Double {
        guard chroma > chromaFloor else { return 0 }
        if chroma >= chromaGate { return 1 }
        let t = (chroma - chromaFloor) / (chromaGate - chromaFloor)
        return t * t * (3 - 2 * t)
    }

    // MARK: - 黑白 (2026-10-28, P0-4)

    /// How much light `+100` of 黑白混合 adds to the grey: **one stop**.
    ///
    /// A stop is the unit the 曝光 slider uses — `grey · 2^(units/100)`, a factor of two of **linear**
    /// light — and not S3.6's 亮度, which is ±1 stop of *perceptual* lightness (`L · 2^(units/100)`,
    /// i.e. 8× the light for a mid tone). Two different jobs: 亮度 says "this colour is lighter", the
    /// 黑白混合 says "this colour deposits more light in the print", which is density, and density is
    /// linear. Multiplicative either way, so black stays black (`0 · 2^k = 0`) and a shadow cannot be
    /// lifted by a colour slider it does not contain.
    public static let mixStopsPerFull: Double = 1

    /// The eight-band mix at one hue, in **slider units** (±100 after the gate) — the kernel's inner
    /// loop, on the host, exactly like `shift(...)`.
    ///
    /// The value is `Σ w_i · mix_i / Σ w_i`, gated by chroma: a neutral pixel has no hue, so it has no
    /// share to weigh and the answer is exactly `0` (which is what makes `exp2(0) = 1` and leaves the
    /// grey at `L`). No band value at all on this hue is also `0`, for the same reason.
    public static func mix(hueDeg: Double, chroma: Double, bands: [HSLBand]) -> Double {
        let gate = chromaGate(for: chroma)
        guard gate > 0 else { return 0 }
        var wSum = 0.0
        var acc = 0.0
        for i in 0..<min(bands.count, centresDegrees.count) {
            let w = weight(i, hueDeg: hueDeg)
            if w == 0 { continue }
            acc += w * bands[i].mix
            wSum += w
        }
        guard wSum > 0 else { return 0 }
        return acc / wSum * gate
    }

    /// The whole S3.4 stage for one linear-RGB pixel — what `s3_4_bw.metal` computes, in Double.
    ///
    /// **The grey is the pixel's OKLab lightness, cubed back into linear light** (`L³` is what
    /// `OKLCh.toLinear(L: C: 0)` returns, and it is the value a neutral pixel of that lightness already
    /// has), lifted by the hue's mix: `L³ · 2^(mix/100)`. `HSLTests`/`BlackAndWhiteTests` hold the
    /// kernel to this, so a change of space, of lift or of gate cannot happen on one side only.
    public static func gray(_ rgb: SIMD3<Double>, bands: [HSLBand]) -> Double {
        let lch = OKLCh.fromLinear(rgb)
        let m = mix(hueDeg: lch.hue, chroma: lch.C, bands: bands)
        let linear = lch.L * lch.L * lch.L
        return max(linear * pow(2, m / 100 * mixStopsPerFull), 0)
    }

    /// The whole stage for one linear-RGB pixel: what S3.6 does, in Double.
    ///
    /// **The three sliders' definitions** (076 §4):
    ///  * **色相**: `h' = h + units · 0.3°` — a rotation at constant `L` and `C`, so a hue move cannot
    ///    brighten a colour (the wrap is a modulo, so 350° + 20° = 10°).
    ///  * **饱和**: `C' = C · (1 + units/100)`, floored at 0 — multiplicative, so −100 is exactly grey
    ///    and +100 doubles the distance from grey. Same shape as the global saturation slider
    ///    (`color_hsl.metal`), so the two controls mean the same thing.
    ///  * **亮度**: `L' = L · 2^(units/100)` — **±1 stop of perceptual lightness**. Multiplicative
    ///    because that is the only definition with the same meaning on every band: pure blue
    ///    (`L = 0.452`) and pure yellow (`L = 0.968`) are 6.9× apart in luminance, and an additive
    ///    lift in HSL's `l` — which is 0.5 for both — was exactly the 079 结论 4 defect.
    ///
    /// Negatives are clipped at the end (`max(rgb, 0)`): a hue rotation can leave the working gamut,
    /// and a negative channel is not a colour. Nothing is clipped at the top, so a display-referred
    /// highlight above white keeps its headroom (S4 is the only clamp, as on every other stage).
    public static func apply(_ rgb: SIMD3<Double>, bands: [HSLBand]) -> SIMD3<Double> {
        let lch = OKLCh.fromLinear(rgb)
        let s = shift(hueDeg: lch.hue, chroma: lch.C, bands: bands)
        if s.hue == 0 && s.saturation == 0 && s.luminance == 0 { return rgb }
        let h = lch.hue + s.hue * degreesPerUnit
        let c = max(lch.C * (1 + s.saturation / 100), 0)
        let l = lch.L * pow(2, s.luminance / 100)
        let out = OKLCh.toLinear(L: l, C: c, hue: h)
        return SIMD3(max(out.x, 0), max(out.y, 0), max(out.z, 0))
    }
}
