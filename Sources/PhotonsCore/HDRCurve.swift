import Foundation

// MARK: - the HDR curve axis (派单 030)
//
// One curve, in the log-light domain, between S1.6 and S2. `HDRCurve` is the **single** home of the
// shaper constants: the kernel receives `x0`/`K`/the luma weights in its uniform, so "the CPU solver
// and the GPU shaper agree" is true by construction rather than by comment (`s1_7_hdr_curve.metal`
// writes no constants of its own).
//
// It is also the analytic reference the tests measure the LUT against: `evaluate` is the kernel's
// arithmetic in `Double`, and a render must agree with it to within the table's own interpolation
// error. Anything the kernel does that this file cannot reproduce is a bug in one of them.

/// The linear → log-light axis: `u(x) = log1p(x/x0)/K`, `x(u) = x0·expm1(u·K)`.
///
/// `u = 0 ↔ x = 0` exactly, `u(0.18) = 0.5955`, `u(1) = 0.7500` (SDR white sits a quarter from the
/// right edge — the axis deliberately spends its last quarter on HDR), `u = 1 ↔ +4 EV`, and beyond
/// +4 EV `u` keeps growing with the same local slope (`du/dx = 1/(K·(x0+x))`), which is what lets the
/// kernel continue a curve past the right end instead of clamping.
///
/// **Why +4 EV and not the +6 that 030 first wrote (派单 044).** The only headroom the project
/// actually states is the histogram's HDR tail: `Histogram.swift:189` `maxStops = 4` with
/// `hdrBinsPerStop = 64`, i.e. **four** stops above SDR white (that `64` is bins per stop, never a
/// 64× of anything). 030 §2/§4 picked `xHI = 2^+6 = 64` on its own — no rule asked for it — and 042
/// copied the 6 EV. `xHI = 16` puts the axis exactly where the histogram already measures, spends
/// 6.25 % of `u` on the black foot (was 5.56 %), and gives every stop above white a wider slice of
/// the table, which is where the curve is coarsest (fp16 at +4 EV is 16 codes).
public struct HDRCurveAxis: Sendable, Equatable {
    /// `u = 0`. −12 EV relative to SDR white. Exact in `Float` (a power of two).
    public let x0: Double
    /// `u = 1`. +4 EV.
    public let xHI: Double
    /// `ln(1 + xHI/x0)` — the normalisation that makes `u(xHI) == 1`.
    ///
    /// **This is a natural log, and the distinction is load-bearing.** `docs/tasks/030` §4.1 writes
    /// `K = log2(1 + xHI/x0) = 18.0000055`, but every number that section tabulates is the ln one:
    /// `u(2^-12) = 0.0625`, `u(0.18) = 0.5955`, `u(1.0) = 0.7500`, `u(16) = 1.0000`, and
    /// `dlog2(x)/du = 16.02 / 16.00 / 16.000` at 0.18 / 1.0 / 16.0. With K = log2 = 16.0000220 those
    /// four positions come out 0.0433 / 0.4128 / 0.5199 / 0.6931 — i.e. +4 EV would land at
    /// u = 0.69 and the axis would never reach 1. The 18.0000055 is exactly `K/ln2 = log2(1+xHI/x0)`,
    /// the **number of stops the axis spans** (16.0000220 = +4 EV − (−12 EV)), which is why it
    /// looked like K. So: `K = ln(1 + 2^16) = ln(65537) = 11.0903701`, and 16.0000220 is `K/ln 2`.
    ///
    /// Note it is `ln(1 + x)`, not `ln(x)`: 16.0000220 instead of 16.0 exactly, because
    /// `xHI/x0 = 2^16` and the shaper is `log1p`, whose argument is `1 + x/x0`.
    public let K: Double

    public init(x0: Double = 1.0 / 4096.0, xHI: Double = 16) {
        self.x0 = x0
        self.xHI = xHI
        self.K = log(1 + xHI / x0)
    }

    /// The shipped axis: −12…+4 EV, `K = 11.0903701`.
    public static let standard = HDRCurveAxis()

    /// Stops the axis spans — `K/ln 2 = 16.0000220`, the number §4.1 quotes as `K`.
    public var stops: Double { K / log(2) }

    /// `x → u`. Defined for `x > 0`; the kernel's rule 3 passes `x ≤ 0` through untouched, so this
    /// is only ever asked about positive light. `x = 0` answers 0, not −∞, which is the whole point
    /// of log1p here.
    public func forward(_ x: Double) -> Double {
        x <= 0 ? 0 : log1p(x / x0) / K
    }

    /// `u → x`. Unbounded above: the curve owns the ceiling, not the shaper.
    public func inverse(_ u: Double) -> Double { x0 * expm1(u * K) }

    /// The shaper in the kernel's own precision, so a test can measure f32 rounding rather than
    /// `Double` arithmetic that the GPU never performs.
    public func forwardFloat(_ x: Float) -> Float {
        x <= 0 ? 0 : log1p(x / Float(x0)) / Float(K)
    }

    public func inverseFloat(_ u: Float) -> Float {
        Float(x0) * expm1(u * Float(K))
    }

    /// The u of a stop (EV) relative to SDR white: `u(2^ev)`. For the axis labels the UI draws.
    public func u(stops ev: Double) -> Double { forward(pow(2, ev)) }

    /// The EV a u position corresponds to. `log2(x(u))` — the inverse of `u(stops:)` above −12 EV.
    public func stops(at u: Double) -> Double { log2(max(inverse(u), .leastNormalMagnitude)) }
}

// MARK: - the WRGB tables

/// CPU mirror of `s1_7_hdr_curve.metal`: the kernel's arithmetic in `Double`, for tests and for the
/// UI's "this point is at −6.2 EV" read-outs.
public enum HDRCurve {

    public static let axis = HDRCurveAxis.standard

    /// Rec709 luminance weights — the same convention `s2_tone_map.metal:81` uses. The camera's
    /// working space is **linear sRGB** (`s4_display.metal`, `RenderGraph.primariesMatrix`), so
    /// these are the weights for the space the numbers are actually in.
    public static let lumaWeights = (r: 0.2126, g: 0.7152, b: 0.0722)

    /// The table's interpolation, on CPU: clamp `u` into [0,1], lerp, plus rule 4's continuation.
    public static func lutValue(_ table: [Float], slope: Float, u: Double) -> Double {
        guard table.count >= 2 else { return u }
        let n = table.count
        let t = min(max(u, 0), 1) * Double(n - 1)
        let i0 = Int(t.rounded(.down))
        let i1 = min(i0 + 1, n - 1)
        let f = t - Double(i0)
        let v = Double(table[i0]) * (1 - f) + Double(table[i1]) * f
        return v + max(u - 1, 0) * Double(min(max(slope, 0), 1))
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

    /// A whole pixel: W first (a luma gain, hue-preserving), then R/G/B (separable).
    ///
    /// `tables` is the 4 × `CurveLUT.size` layout the GPU buffer has: W, R, G, B.
    /// `blackPoints` is `CurveLUT.blackPoints` in the same order; the default (all zero) is the
    /// pre-061 behaviour, i.e. every curve starting at zero light.
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
        let y = max(rr, 0) * lumaWeights.r + max(gg, 0) * lumaWeights.g + max(bb, 0) * lumaWeights.b
        if y > 0 {
            let uy = axis.forward(y)
            let vy = lutValue(w, slope: s[0], u: uy)
            // u units → stops: `axis.stops` (= K/ln 2 = 16.0000…), not `K`.
            let dv = min(max((vy - uy) * axis.stops, -12), 12)
            let gain = pow(2, dv)
            rr *= gain; gg *= gain; bb *= gain
        }
        return (channel(rr, table: r, slope: s[1], blackPoint: Double(black[1])),
                channel(gg, table: g, slope: s[2], blackPoint: Double(black[2])),
                channel(bb, table: b, slope: s[3], blackPoint: Double(black[3])))
    }

    /// The exposure offset the W curve asks for at luma `y`, in stops. What the curve panel prints.
    public static func whiteGainStops(at y: Double, table: [Float], slope: Float) -> Double {
        guard y > 0 else { return 0 }
        let uy = axis.forward(y)
        return lutValue(table, slope: slope, u: uy) - uy
    }
}
