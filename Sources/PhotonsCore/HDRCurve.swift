import Foundation

// MARK: - the HDR curve axis (派单 030, re-shaped by 派单 062)
//
// One curve, in the log-light domain, between S1.6 and S2. `HDRCurve` is the **single** home of the
// shaper constants: the kernel receives them in its uniform, so "the CPU solver and the GPU shaper
// agree" is true by construction rather than by comment (`s1_7_hdr_curve.metal` writes no axis
// constant of its own).
//
// It is also the analytic reference the tests measure the LUT against: `evaluate` is the kernel's
// arithmetic in `Double`, and a render must agree with it to within the table's own interpolation
// error. Anything the kernel does that this file cannot reproduce is a bug in one of them.

/// The linear → **histogram-aligned** axis (派单 062).
///
/// The card's x axis is now the histogram's own axis, split in half:
///
/// ```
/// u(x) = whiteU · srgbEncode(x)                 0 < x ≤ 1     SDR: display code 0–255, 50 % of u
/// u(x) = whiteU + hdrPerStop · log2(x)          1 < x         HDR: +0…+4 EV, 12.5 % of u per stop
/// ```
///
/// so `u(0) = 0`, `u(0.18) = 0.2307`, **`u(1) = 0.5000`** (SDR white sits exactly in the middle —
/// that is the histogram's `sdrFraction = 256/(256+256)`), `u(2) = 0.625`, `u(4) = 0.7500` (+2 EV),
/// `u(16) = 1.0000` (+4 EV).
///
/// **Why the shape changed (062).** 044's axis was `u = log1p(x/x0)/K`, which put SDR white at
/// `u = 0.7500`: the left three quarters of the card were spent on the SDR range and only the last
/// quarter on the histogram's four-stop HDR tail. The owner's rule is that the curve must read like
/// the histogram it sits under — 0–255 on the left half, +0…+4 EV on the right half — so the shaper
/// is now piecewise: the sRGB transfer in the SDR half (that *is* "display code 0–255", the same
/// encoding S4 writes and the histogram bins) and `log2` in the HDR half, one stop per `hdrPerStop`
/// of `u`.
///
/// Beyond +4 EV nothing is clamped: `u(x) = whiteU + hdrPerStop·log2(x)` keeps its local slope
/// (`du/dx = hdrPerStop/(x·ln 2)`, i.e. the same slope as at +4 EV) for every `x > xHI`, so `u(64)`
/// — two stops past the right end — is `1.25` and the kernel's rule 4 continues a curve there
/// instead of flattening it. That rule is 044's, unchanged.
///
/// The two halves meet at `u = whiteU` with the same value from both formulas, and both are strictly
/// increasing on `x > 0`, so `u` and `x(u)` are strictly monotone over the whole axis — including
/// across the sRGB transfer's own break (`x = srgbKnee ≈ 0.0031307`, `u = 0.0202`), where the linear
/// and the power branch meet to the last bit *because the knee is solved for continuity* (see
/// `srgbKnee`; the standard's printed `0.0031308` leaves a 2.85e-8 fold, and a fold on the axis
/// would let a curve invert neighbouring tones).
public struct HDRCurveAxis: Sendable, Equatable {
    /// `u = 1`: +4 EV above SDR white. `xHI = 16`, the histogram's own HDR tail (`maxStops = 4`).
    public let xHI: Double
    /// Where SDR white (`x = 1`) sits, and the width the SDR half gets: `0.5` (派单 062).
    ///
    /// It is one number on purpose: the tick positions, the card's caption and the kernel's uniform
    /// all read it, so "SDR is half the card" cannot drift between them. A value other than 0.5 is
    /// **not** a supported alternative axis — it exists so a test can put white back at 044's 0.75
    /// and watch the tick assertions and the pixel table go red (062's 反证).
    public let whiteU: Double

    public init(whiteU: Double = 0.5, xHI: Double = 16) {
        self.whiteU = whiteU
        self.xHI = xHI
    }

    /// The shipped axis: SDR 50 % (display code 0–255), HDR 50 % (+0…+4 EV).
    public static let standard = HDRCurveAxis()

    /// Stops the HDR half spans: `log2(xHI) = 4`.
    public var hdrStops: Double { log2(xHI) }

    /// The width of one stop on the axis: `(1 − whiteU)/hdrStops = 0.125` for the shipped axis.
    ///
    /// This is the number 044 called "stops per unit u" (`K/ln 2`); it is no longer a single
    /// constant over the whole axis (the SDR half is display-encoded, where one unit of `u` is a
    /// varying number of stops), which is why the W curve's gain is now measured as the *ratio* of
    /// two light values rather than by multiplying a `u` difference by this number. See
    /// `HDRCurve.pixel`.
    public var hdrPerStop: Double { (1 - whiteU) / hdrStops }

    /// S4's OETF — the 0–255 encoding the histogram bins and the SDR half of this axis counts.
    ///
    /// **The knee is solved for continuity, not typed.** The sRGB constants 12.92 / 1.055 / 0.055 /
    /// 2.4 with the standard's *printed* knee `0.0031308` are not exactly continuous: the power
    /// branch comes out `2.85e-8` **below** the linear one at the knee, i.e. the encoded value steps
    /// *down* there. Every encoder in the project inherits that (`s4_display.metal:20`,
    /// `histogram_sample.metal:33`, `Histogram.swift:641`), and for a display code it is irrelevant
    /// (7e-6 of an 8-bit step). For an *axis* it is not: one ulp of a fold is still a fold, and a
    /// curve on a folded axis can invert two neighbouring tones — the one thing a curve may never
    /// do. So the knee here is the crossing of the two branches with the same 12.92 / 1.055 / 0.055
    /// (`0.0031306684425005367`, the standard's own exact value), where `u` is strictly increasing.
    /// The price is a `1.7e-6` deviation from S4's rounded encode inside a `1.3e-7`-wide window of
    /// `x` — 4e-4 of an 8-bit code, and zero everywhere else.
    public static let srgbKnee = 0.0031306684425005367
    /// `12.92 · srgbKnee` — where the two branches meet in encoded units.
    public static let srgbKneeEncoded = 0.04044823627710693

    public static func srgbEncode(_ x: Double) -> Double {
        x <= srgbKnee ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055
    }

    /// …and its inverse, `x(u)` for `u ≤ whiteU`.
    public static func srgbDecode(_ v: Double) -> Double {
        v <= srgbKneeEncoded ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// `x → u`. Defined for `x > 0`; the kernel's rule 3 passes `x ≤ 0` through untouched, so this
    /// is only ever asked about positive light. `x = 0` answers 0, not −∞ — that is what lets the
    /// black end bend all the way to zero output.
    ///
    /// The halves split at `x = 1` **inclusive to the upper one**, so `forward(1) == whiteU`
    /// bit-exactly (`0.5·sRGB(1)` is `0.5 − 5.6e-17` in `Double`) and the white tick is the axis's
    /// own number rather than one ulp from it.
    public func forward(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x < 1 { return whiteU * HDRCurveAxis.srgbEncode(x) }
        return whiteU + hdrPerStop * log2(x)
    }

    /// `u → x`. Unbounded above: the curve owns the ceiling, not the shaper.
    public func inverse(_ u: Double) -> Double {
        if u <= whiteU { return HDRCurveAxis.srgbDecode(u / whiteU) }
        return exp2((u - whiteU) / hdrPerStop)
    }

    /// The shaper in the kernel's own precision, so a test can measure f32 rounding rather than
    /// `Double` arithmetic that the GPU never performs.
    public func forwardFloat(_ x: Float) -> Float {
        if x <= 0 { return 0 }
        let w = Float(whiteU)
        if x < 1 {
            return w * (x <= Float(HDRCurveAxis.srgbKnee)
                        ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055)
        }
        return w + Float(hdrPerStop) * log2(x)
    }

    public func inverseFloat(_ u: Float) -> Float {
        let w = Float(whiteU)
        if u <= w {
            let v = u / w
            return v <= Float(HDRCurveAxis.srgbKneeEncoded)
                ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return exp2((u - w) / Float(hdrPerStop))
    }

    /// The u of a stop (EV) relative to SDR white: `u(2^ev)`. For the axis labels the UI draws.
    /// `u(0) = whiteU` (SDR white is the middle), `u(4) = 1` (+4 EV is the right edge).
    public func u(stops ev: Double) -> Double { forward(pow(2, ev)) }

    /// The EV a u position corresponds to: `log2(x(u))`, the inverse of `u(stops:)`.
    public func stops(at u: Double) -> Double { log2(max(inverse(u), .leastNormalMagnitude)) }
}

// MARK: - the WRGB tables

/// CPU mirror of `s1_7_hdr_curve.metal`: the kernel's arithmetic in `Double`, for tests and for the
/// UI's "this point is at −6.2 EV" read-outs.
public enum HDRCurve {

    public static let axis = HDRCurveAxis.standard

    /// The **working primaries'** luminance weights — Rec.2020's `0.2627/0.6780/0.0593` since 075,
    /// read from `ColorPrimaries` so this file cannot drift from the kernels. The curve's shaper reads
    /// them off `p.d.xyz` (`s1_7_hdr_curve.metal`), so this one constant sets the luma of S1.7 on both
    /// sides; `s2_tone_map`/`s1_6_local` take the same three numbers from `Kernels/primaries.metal`.
    public static let lumaWeights = {
        let w = ColorPrimaries.working.luminanceWeights
        return (r: w.x, g: w.y, b: w.z)
    }()

    /// Rule 4's slope ceiling — the **last** segment's, and only the last one's (派单 080 / 079 A5).
    ///
    /// `2`, not `1`. `u > 1` is the only place a control-point segment is *extrapolated*, so its
    /// slope is the one number that "how steep did the user draw the end" turns into pixels with.
    /// On this axis one unit of `u` above white is 8 EV, so `s` **is** the log-log contrast above
    /// +4 EV: `s = 1` carries on, `s < 1` rolls off, `s > 1` steepens the HDR tail (the tail is
    /// *compressed* less, i.e. it keeps more of its light). 1 was a ceiling on the *user*, not on the
    /// maths — darktable's `tonecurve` extrapolates with a power law fitted to the table's end and
    /// clamps nothing (`src/iop/tonecurve.c:401`) — and 2 is where the ceiling stops being a picture
    /// decision and becomes a guard against a hand-written document: past 2 the extension climbs so
    /// fast that one table sample of error is a visible step, and no photograph has a tail there.
    ///
    /// **The ticket's 「其它段仍 ≤1」 needs no code, and must not get any.** A segment that is not the
    /// last one is *not* extrapolated: it is interpolated inside the table, where `v` is clamped to
    /// `0…1` (`buildOne`), Fritsch–Carlson keeps the interpolant monotone and the fold check falls
    /// back to the identity — so it cannot leave the card and it cannot invert, whatever its slope
    /// (a steep interior segment is a legitimate midtone S; `CurvePanelTests` has dragged `y` freely
    /// since 051/061). What this constant can do is *relax a clamp*, and the clamp exists only on the
    /// one segment that is multiplied past the table: the two `clamp(` sites in
    /// `s1_7_hdr_curve.metal` both multiply by `max(u − 1, 0)`, so `u ≤ 1` cannot see the number at
    /// all (`HDRCurveTests` measures that at 200 points per table).
    public static let tailSlopeLimit: Double = 2

    /// The other end of rule 4's clamp: a descending last segment continues **down**, up to
    /// `−tailSlopeLimit`.
    ///
    /// 派单 137: this used to be 0, which turned every inverted curve's tail into a ceiling above
    /// +4 EV even though the table itself was allowed to descend. The ticket asks for the limit to be
    /// **symmetric by absolute value** — the same `2` — so the floor is `−tailSlopeLimit`, not a second
    /// constant. The table's own samples are clamped into `0…1` by `buildOne`; this only governs the
    /// extrapolation past `u = 1`.
    public static let tailSlopeFloor: Double = -tailSlopeLimit

    /// `slope` as the kernel uses it: `clamp(slope, tailSlopeFloor, tailSlopeLimit)`.
    ///
    /// Named so the CPU (`lutValue`) and the GPU (`hdr_channel`) are the same expression, and so a
    /// document written by hand with 40 in `slopes` renders at 2 rather than at 40.
    public static func clampTailSlope(_ slope: Float) -> Float {
        Float(clampTailSlope(Double(slope)))
    }

    public static func clampTailSlope(_ slope: Double) -> Double {
        min(max(slope, tailSlopeFloor), tailSlopeLimit)
    }

    /// The table's interpolation, on CPU: clamp `u` into [0,1], lerp, plus rule 4's continuation.
    public static func lutValue(_ table: [Float], slope: Float, u: Double) -> Double {
        guard table.count >= 2 else { return u }
        let n = table.count
        let t = min(max(u, 0), 1) * Double(n - 1)
        let i0 = Int(t.rounded(.down))
        let i1 = min(i0 + 1, n - 1)
        let f = t - Double(i0)
        let v = Double(table[i0]) * (1 - f) + Double(table[i1]) * f
        return v + max(u - 1, 0) * clampTailSlope(Double(slope))
    }

    /// One channel through one table — `hdr_channel` in the kernel.
    ///
    /// `blackPoint` is the table's first control point's x (`CurveLUT.blackPoints`), and it decides
    /// **which of 061's two sub-black cases** applies:
    ///
    ///   · `0` — the curve starts at zero light, so `x ≤ 0` passes through bit for bit (018: the
    ///     decoder's measured min is −0.039 and the curve may not delete it);
    ///   · `> 0` — the black point has been raised: `x ≤ 0` lands on the table's `u = 0` entry, which
    ///     is `first.y`, exactly the value every positive sample below `first.x` already gets. One
    ///     constant for the whole segment, negatives included.
    public static func channel(_ x: Double, table: [Float], slope: Float,
                               blackPoint: Double = 0) -> Double {
        if x <= 0 {
            guard blackPoint > 0, table.count >= 2 else { return x }
            return axis.inverse(lutValue(table, slope: slope, u: 0))
        }
        return axis.inverse(lutValue(table, slope: slope, u: axis.forward(x)))
    }

    /// The exposure offset a W table asks for at luma `y`, **in stops** — the kernel's `dv`.
    ///
    /// It is `log2(x(v) / x(y))`, the ratio of the two light values the axis maps, not a `u`
    /// difference times a constant. Before 062 the two were almost the same thing (the old axis was
    /// `log1p`, so one unit of `u` was 16.0000 stops everywhere and `(v − u)·K/ln 2` was exact to
    /// 0.1 % above the black foot). The new axis is display-encoded over its left half, where one
    /// unit of `u` is 12–100 stops depending on `x`, so a single constant would have made the W
    /// curve's midtone gain up to 40 % too weak. The ratio is also the *definition* a curve already
    /// has: the table says which light the input becomes.
    ///
    /// Clamped to ±12 stops, as the kernel always did — dragging white to 1.0 from 0.5 is +9 stops
    /// and a 200-level pixel is already inf in half float.
    public static func offsetStops(from uy: Double, to vy: Double) -> Double {
        guard uy > 0 else { return 0 }
        return min(max(log2(axis.inverse(vy) / axis.inverse(uy)), -12), 12)
    }

    /// A whole pixel: W first (a luma gain, hue-preserving), then R/G/B (separable).
    ///
    /// `tables` is the 4 × `CurveLUT.size` layout the GPU buffer has: W, R, G, B.
    /// `blackPoints` is `CurveLUT.blackPoints` in the same order; the default (all zero) is the
    /// pre-061 behaviour, i.e. every curve starting at zero light.
    ///
    /// A table that *is* the identity is skipped, exactly as the kernel skips it (062): the
    /// shaper→table→shaper round trip returns such a value to within ~5e-7, and on an fp16 boundary
    /// that is one bit — `HDRCurveTests` ⑩ exists because that bit showed up.
    public static func pixel(_ rgb: (Double, Double, Double), tables: [Float],
                             slopes: [Float]? = nil,
                             blackPoints: [Float]? = [0, 0, 0, 0]) -> (Double, Double, Double) {
        let n = CurveLUT.size
        guard tables.count == CurveLUT.tableCount * n else { return rgb }
        let s = slopes ?? CurveLUT.slopes(tables)
        // Where each curve's black point sits (061): 0 = starts at zero light, > 0 = a raised black
        // point, which turns `x ≤ 0` from a pass-through into the table's own constant.
        let black = blackPoints ?? [0, 0, 0, 0]
        // Sliced, not passed whole: `lutValue` takes its length from the table it is handed, so a
        // whole 4-table buffer would interpolate across table boundaries.
        let w = Array(tables[0..<n]), r = Array(tables[n..<2 * n]), g = Array(tables[2 * n..<3 * n]),
            b = Array(tables[3 * n..<4 * n])
        var (rr, gg, bb) = rgb
        if !CurveLUT.isIdentityTable(w) {
            let y = max(rr, 0) * lumaWeights.r + max(gg, 0) * lumaWeights.g + max(bb, 0) * lumaWeights.b
            if y > 0 {
                let uy = axis.forward(y)
                let vy = lutValue(w, slope: s[0], u: uy)
                let gain = pow(2, offsetStops(from: uy, to: vy))
                rr *= gain; gg *= gain; bb *= gain
            }
        }
        // 062's identity skip and 061's black clip, together: a table with a raised black point is
        // never the identity (its `0…first.x` segment is a constant), so skipping the identity costs
        // the clip nothing.
        return (CurveLUT.isIdentityTable(r) ? rr
                    : channel(rr, table: r, slope: s[1], blackPoint: Double(black[1])),
                CurveLUT.isIdentityTable(g) ? gg
                    : channel(gg, table: g, slope: s[2], blackPoint: Double(black[2])),
                CurveLUT.isIdentityTable(b) ? bb
                    : channel(bb, table: b, slope: s[3], blackPoint: Double(black[3])))
    }

    /// The exposure offset the W curve asks for at luma `y`, in stops. What the curve panel prints.
    public static func whiteGainStops(at y: Double, table: [Float], slope: Float) -> Double {
        guard y > 0 else { return 0 }
        let uy = axis.forward(y)
        return offsetStops(from: uy, to: lutValue(table, slope: slope, u: uy))
    }
}
