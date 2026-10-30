import Foundation
import simd

// MARK: - 140 · 点颜色 (Point Color)

/// **Point Color** — one sampled colour, one hue window around it, and three adjustments scoped to
/// that window. S3.6b renders it in OKLCh on the display-referred frame, immediately after S3.6.
///
/// The shape is deliberately the same operator family as S3.6 (派单 076/101), not a second colour
/// science:
///
///   · the window is `1 − smoothstep(range, range + feather, Δh)` on the **circular shortest** hue
///     difference, i.e. 1 on the sampled hue, exactly 0 at/after `range + feather`, with no corner
///     where it lands on zero (the same C¹ shape `hsl_chroma_gate` uses);
///   · the window is multiplied by the **same** chroma gate S3.6 and S3.4 use (`HSLBands.chromaGate`),
///     so a mathematically grey pixel gets exactly 0 and is written back bit for bit — the eight bands
///     and this stage can never disagree about what grey is;
///   · the three adjustments have the HSL card's units: `hue` is 0.3° per unit (±30° at ±100),
///     `saturation` is a multiplicative chroma scale, `luminance` is ±1 stop of perceptual lightness.
///     Unlike the eight bands' 亮度 (which stays meaningful on a grey), **all three are gated here**:
///     the acceptance for this card is “a grey is bit-identical under any parameters”.
///
/// The sample itself stores only its OKLCh hue and chroma. Sampling changes the two `sample*` fields
/// and nothing else, which is why a click after an empty document writes no pixels (there are no
/// adjustments yet, so `isActive` is false and S3.6b is not in the pipeline at all).
public struct PointColor: Sendable, Equatable, Codable {

    /// Slider units → OKLCh degrees, the number `HSLBand` and `GradeWheel` already speak: +100 is
    /// +30°, so the acceptance's “hue +30°” is the slider at +100.
    public static let degreesPerUnit: Double = 0.3

    /// Hue-window half-width, in degrees. 30° is the “一吸就选中” default from 140 §4: narrow enough
    /// to pick one garment out of a scene, wide enough that a single click does not look inert.
    public static let defaultRange: Double = 30
    /// Soft shoulder beyond `range`, in degrees. 30° means the window reaches 60° from the sample.
    public static let defaultFeather: Double = 30

    /// OKLCh hue of the sampled colour, degrees in `[0, 360)`.
    public var sampleHue: Double
    /// OKLCh chroma of the sampled colour (0…≈0.4 in the working space).
    public var sampleChroma: Double
    /// Hue-window half-width, degrees (0…180).
    public var range: Double
    /// Width of the soft shoulder beyond `range`, degrees (0…180 − `range`).
    public var feather: Double
    /// −100…100 → ±30° of OKLCh hue.
    public var hue: Double
    /// −100…100 → `C · (1 + saturation/100)` inside the window.
    public var saturation: Double
    /// −100…100 → `L · 2^(luminance/100)` inside the window.
    public var luminance: Double

    public init(sampleHue: Double = 0, sampleChroma: Double = 0,
                range: Double = PointColor.defaultRange,
                feather: Double = PointColor.defaultFeather,
                hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.sampleHue = sampleHue
        self.sampleChroma = sampleChroma
        self.range = range
        self.feather = feather
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = PointColor()
        v.sampleHue = c.val("sampleHue", v.sampleHue)
        v.sampleChroma = c.val("sampleChroma", v.sampleChroma)
        v.range = c.val("range", v.range)
        v.feather = c.val("feather", v.feather)
        v.hue = c.val("hue", v.hue)
        v.saturation = c.val("saturation", v.saturation)
        v.luminance = c.val("luminance", v.luminance)
        self = v
    }

    /// Written whole, like `GradeWheel`: the object exists only when the document actually uses the
    /// card, so there is no “default” spelling to preserve inside it.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(sampleHue, forKey: AnyCodingKey("sampleHue"))
        try c.encode(sampleChroma, forKey: AnyCodingKey("sampleChroma"))
        try c.encode(range, forKey: AnyCodingKey("range"))
        try c.encode(feather, forKey: AnyCodingKey("feather"))
        try c.encode(hue, forKey: AnyCodingKey("hue"))
        try c.encode(saturation, forKey: AnyCodingKey("saturation"))
        try c.encode(luminance, forKey: AnyCodingKey("luminance"))
    }

    /// A colour with a meaningful hue was actually picked. `sampleChroma == 0` is the unsampled
    /// document, and a sampled grey (chroma at the neutral floor) has no hue to select by.
    public var isSampled: Bool {
        sampleHue.isFinite && sampleChroma > HSLBands.chromaFloor
    }

    /// Any of the three adjustment sliders is away from zero. `range`/`feather` alone do not make a
    /// stage: they describe a window, they do not move a pixel.
    public var hasAdjustment: Bool {
        hue != 0 || saturation != 0 || luminance != 0
    }

    /// **The predicate the pipeline and the key chain use.** Both halves have to be true: a sampled
    /// colour with all three sliders at 0, or three sliders moved before a sample exists, must render
    /// the pre-140 frame by construction (0 pass), not by arithmetic.
    public var isActive: Bool { isSampled && hasAdjustment }

    /// The sampled colour's hue-window half-width, clamped to a half-turn. A window wider than 180°
    /// would select the colour opposite the sample too (the circle wraps twice), which is not a
    /// “range” but the whole wheel; `feather` is clamped so `range + feather ≤ 180` for the same
    /// reason.
    public var clampedRange: Double { min(max(range, 0), 180) }
    public var clampedFeather: Double { min(max(feather, 0), 180 - clampedRange) }

    /// The window at one hue, **without** the chroma gate: 1 at the sample, 0 at/after
    /// `range + feather`. `HSLBands.circularDistance` is the same shortest-angle arithmetic S3.6's
    /// bands use, so the 0°/360° seam is not a special case here either.
    public func hueWeight(hueDeg: Double) -> Double {
        let delta = HSLBands.circularDistance(from: sampleHue, to: hueDeg)
        let inner = clampedRange
        let shoulder = clampedFeather
        if delta <= inner { return 1 }
        guard shoulder > 0, delta < inner + shoulder else { return 0 }
        let t = (delta - inner) / shoulder
        return 1 - t * t * (3 - 2 * t)
    }

    /// The full weight: hue window × the shared neutral gate. Exactly 0 for a grey (`gate == 0`), so
    /// the kernel's write-back is bit-identical, and C¹ at the window's shoulder.
    public func weight(hueDeg: Double, chroma: Double) -> Double {
        let gate = HSLBands.chromaGate(for: chroma)
        guard gate > 0 else { return 0 }
        return hueWeight(hueDeg: hueDeg) * gate
    }

    /// The whole S3.6b stage for one linear-RGB pixel — the CPU reference the kernel is written
    /// against (`s3_6b_point_colour.metal`).
    ///
    /// The adjustment is multiplied by `w`, not switched by it: at the shoulder the hue rotation,
    /// chroma scale and lightness lift all fade to exactly zero together, which is what keeps a
    /// 1°-per-pixel hue sweep free of a step at `range` and at `range + feather`.
    public func apply(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        guard isActive else { return rgb }
        let lch = OKLCh.fromLinear(rgb)
        let w = weight(hueDeg: lch.hue, chroma: lch.C)
        guard w > 0 else { return rgb }
        let h = lch.hue + w * hue * Self.degreesPerUnit
        let c = max(lch.C * (1 + w * saturation / 100), 0)
        let l = lch.L * pow(2, w * luminance / 100)
        let out = OKLCh.toLinear(L: l, C: c, hue: h)
        return SIMD3(max(out.x, 0), max(out.y, 0), max(out.z, 0))
    }

    /// The sampled hue/chroma of a **decoded linear** RGB sample (the `LinearImage` buffer the
    /// dropper reads), converted through the one decode → working matrix the graph uses.
    ///
    /// The canvas dropper already avoids the presented texture (the tone map and output primaries are
    /// not a property of the photographed colour); this finishes the same thought.
    public static func sample(fromDecodedLinear rgb: RGBSample) -> (hue: Double, chroma: Double) {
        let decoded = SIMD3(rgb.r, rgb.g, rgb.b)
        let working = ColorPrimaries.conversion(from: ColorPrimaries.decoded,
                                                to: ColorPrimaries.working).applying(to: decoded)
        let lch = OKLCh.fromLinear(working)
        return (lch.hue, lch.C)
    }

    /// `sampleH=…;sampleC=…;range=…;feather=…;h=…;s=…;l=…` — S3.6b's key material.
    ///
    /// The first four fields are the window, and the acceptance requires each of them to miss the
    /// cache on its own: moving `range`/`feather` changes which pixels are in the window, and
    /// re-sampling changes its centre. The three adjustment numbers are carried in the same
    /// canonical form as every other stage material.
    public var keyString: String {
        "sampleH=\(k(sampleHue));sampleC=\(k(sampleChroma))"
            + ";range=\(k(range));feather=\(k(feather))"
            + ";h=\(k(hue));s=\(k(saturation));l=\(k(luminance))"
    }
}
