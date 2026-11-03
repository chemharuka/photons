import Foundation
import simd

// MARK: - 140 · 点颜色 (Point Color) — 285: OKLCh platform + shoulder, sample-spacing cap

/// **Point Color** — one sampled colour, an **OKLCh neighbourhood** around it, and three adjustments
/// scoped to that neighbourhood. S3.6b renders it on the display-referred frame, immediately after
/// S3.6.
///
/// ## Why the window is OKLCh (285)
///
/// 158 measured the window as a Rec.709 full-range YCbCr box, two chroma axes each ±0.10 and a luma
/// axis of ±0.06. 282 measured what that meant perceptually: the luma box covered only **±0.045**
/// OKLab L (2.8× tighter than the reference software) while the chroma box let through **±37°** of
/// hue at C = 0.12 (3.2× wider) and ±73° before it reached zero. Two samples 15° apart were then both
/// at weight 1.000 in each other's centre — the user's 「不同的点颜色调整应该是独立的」 was false by
/// construction. The axes were also crossed: a real object's shading changes L far more than hue.
///
/// 285 replaces the YUV box with the same three-axis soft box measured in **OKLCh / OKLab L**:
///
///   w = wh(Δh) · wc(ΔC) · wl(ΔL)
///
/// each axis `1 − smoothstep(d, d + shoulder, |Δ|)`, exactly 0 at `d + shoulder`. The hue axis is an
/// **angle** (wrapped, ±180°), which is the one measure that does not widen as chroma falls; chroma
/// is **relative to the sample** and luma is OKLab L. The default 范围 30 maps to:
///
///   · **hue** — platform ±10°, shoulder 5° ⇒ exactly zero at 15°, the user's smallest
///     "two different colours" spacing.
///   · **chroma** — `clamp(0.30 · C_sample, 0.02, 0.12)` (30% relative), zero at 1.5× the platform.
///   · **L** — platform ±0.08, shoulder 0.04 ⇒ ±0.06 (a shading face) is still full weight, ±0.12
///     (a different material) is zero.
///   · **过渡** only scales the shoulder (`feather/30`); it never widens the platform.
///
/// Overlap is resolved on the **stage input**, not on the previous swatch's output:
/// `w_i' = w_i / max(1, Σ w_j)`. Two full-weight boxes therefore split the pixel instead of doubling
/// the move, and the result no longer depends on the array order. The hue shoulder is additionally
/// capped in `PointColorSet` by the nearest sample's angular distance
/// (`min(shoulder, d_min − platform)`), so a transition can never reach across its neighbour.
///
/// ### The pale-colour guard
///
/// `chromaFloor = 0.02` in **OKLab C** is the hard requirement (the old YCbCr spelling
/// `chromaFloorYCbCr` remains as a source-compatible alias). A sample below it is **rejected** by the
/// dropper, and any pixel with `C < 0.5 · chromaFloor` gets weight 0 no matter what the box says. A
/// grey therefore remains bit-identical (weight 0 writes the source pixel back), and a nearly-grey
/// patch cannot be tinted by accident.
///
/// The sample stores its Y/U/V for document compatibility. `sampleHue`/`sampleChroma`/`sampleLightness`
/// are **derived** from them (working-primaries OKLCh); they are never written independently.
public struct PointColor: Sendable, Equatable, Codable {

    /// Slider units → OKLCh degrees, the number `HSLBand` and `GradeWheel` already speak: +100 is
    /// +30°, so the acceptance's “hue +30°” is the slider at +100.
    public static let degreesPerUnit: Double = 0.3

    /// 285 — hue platform at 范围 30, in OKLCh degrees. The shoulder is half of it, so the default
    /// box is exactly zero at 15° — the user's smallest "two different colours" spacing.
    public static let huePlateauDegrees: Double = 10
    /// 285 — chroma tolerance is relative to the sample: `30 %` of its own OKLab C at 范围 30.
    public static let chromaRelativeTolerance: Double = 0.30
    /// 285 — the relative tolerance is clamped into `0.02…0.12` (the lower bound also scales with
    /// 范围, so `范围 0` is still a point).
    public static let chromaToleranceMin: Double = 0.02
    public static let chromaToleranceMax: Double = 0.12
    /// 285 — OKLab L platform at 范围 30; zero at 0.12 whenever the shoulder is at its default 0.5×.
    public static let lumaPlateauWidth: Double = 0.08
    /// 285 — the soft shoulder is half the platform, per axis.
    public static let featherRatio: Double = 0.5
    /// 285 — the dropper refuses a sample below this **OKLab C** (the 158 YCbCr threshold, same
    /// number, now measured in the space the weight itself uses).
    public static let chromaFloor: Double = 0.02
    /// Source-compatible spelling of `chromaFloor` for the dropper/card and the pre-285 tests.
    public static let chromaFloorYCbCr: Double = chromaFloor

    /// The card's 范围 default (30) is the "1×" of the constants above; 0…120 scales the box.
    public static let defaultRange: Double = 30
    /// The card's 过渡 default (30) is the "1×" of `featherRatio`; 0…120 scales the shoulder.
    public static let defaultFeather: Double = 30

    /// Full-range Rec.709 YCbCr of the sampled pixel, each in 0…1 with U/V centred on 0.5.
    public var sampleY: Double
    public var sampleU: Double
    public var sampleV: Double

    /// 0…120. Scales all three radii around `30` (default = the constants above).
    public var range: Double
    /// 0…120. Scales the shoulder around `30` (default = `featherRatio · d`).
    public var feather: Double
    /// −100…100 → ±30° of OKLCh hue.
    public var hue: Double
    /// −100…100 → `C · (1 + saturation/100)` inside the box.
    public var saturation: Double
    /// −100…100 → `L · 2^(luminance/100)` inside the box.
    public var luminance: Double

    /// The sampled pixel's OKLCh hue, derived from `sampleY/U/V` (pure display furniture).
    public var sampleHue: Double {
        OKLCh.fromLinear(Self.linearWorking(from: SIMD3(sampleY, sampleU, sampleV))).hue
    }

    /// The sampled pixel's OKLCh chroma, derived from `sampleY/U/V` (pure display furniture).
    public var sampleChroma: Double {
        OKLCh.fromLinear(Self.linearWorking(from: SIMD3(sampleY, sampleU, sampleV))).C
    }

    /// The sampled pixel's OKLab L, derived from `sampleY/U/V` — the luma axis of the 285 window.
    public var sampleLightness: Double {
        OKLCh.fromLinear(Self.linearWorking(from: SIMD3(sampleY, sampleU, sampleV))).L
    }

    public init(sampleY: Double = 0.5, sampleU: Double = 0.5, sampleV: Double = 0.5,
                range: Double = PointColor.defaultRange,
                feather: Double = PointColor.defaultFeather,
                hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.sampleY = sampleY
        self.sampleU = sampleU
        self.sampleV = sampleV
        self.range = range
        self.feather = feather
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    /// Convenience for hand-written tests and the pre-158 decoder: synthesise a YUV sample that
    /// displays as this OKLCh hue/chroma at the swatch's fixed lightness (0.72).
    public init(sampleHue: Double, sampleChroma: Double,
                range: Double = PointColor.defaultRange,
                feather: Double = PointColor.defaultFeather,
                hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        let working = OKLCh.toLinear(L: 0.72, C: sampleChroma, hue: sampleHue)
        let yuv = PointColor.yuv(fromLinearWorking: working)
        self.init(sampleY: yuv.x, sampleU: yuv.y, sampleV: yuv.z,
                  range: range, feather: feather,
                  hue: hue, saturation: saturation, luminance: luminance)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = PointColor()
        if c.contains(AnyCodingKey("sampleY")) {
            v.sampleY = c.val("sampleY", v.sampleY)
            v.sampleU = c.val("sampleU", v.sampleU)
            v.sampleV = c.val("sampleV", v.sampleV)
        } else {
            // Pre-158 document: it stored only the OKLCh sample. Reconstruct a display-referred YUV
            // at the swatch lightness so the swatch still shows the same colour.
            let old = PointColor(sampleHue: c.val("sampleHue", 0.0),
                                 sampleChroma: c.val("sampleChroma", 0.0))
            v.sampleY = old.sampleY
            v.sampleU = old.sampleU
            v.sampleV = old.sampleV
        }
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
        try c.encode(sampleY, forKey: AnyCodingKey("sampleY"))
        try c.encode(sampleU, forKey: AnyCodingKey("sampleU"))
        try c.encode(sampleV, forKey: AnyCodingKey("sampleV"))
        try c.encode(range, forKey: AnyCodingKey("range"))
        try c.encode(feather, forKey: AnyCodingKey("feather"))
        try c.encode(hue, forKey: AnyCodingKey("hue"))
        try c.encode(saturation, forKey: AnyCodingKey("saturation"))
        try c.encode(luminance, forKey: AnyCodingKey("luminance"))
    }

    /// The sampled pixel's own YUV chroma magnitude: `hypot(U − 0.5, V − 0.5)`. Kept as the stored-
    /// field diagnostic; the **predicate** is now `sampleChroma` in OKLab (285).
    public var sampleChromaYCbCr: Double {
        hypot(sampleU - 0.5, sampleV - 0.5)
    }

    /// A colour with a meaningful chroma was actually picked. Below `chromaFloor` there is no colour
    /// to select (the dropper refuses to create such a swatch).
    public var isSampled: Bool {
        sampleY.isFinite && sampleU.isFinite && sampleV.isFinite
            && sampleChroma >= Self.chromaFloor
    }

    /// Any of the three adjustment sliders is away from zero. `range`/`feather` alone do not make a
    /// stage: they describe a window, they do not move a pixel.
    public var hasAdjustment: Bool {
        hue != 0 || saturation != 0 || luminance != 0
    }

    /// **The predicate the pipeline and the key chain use.**
    public var isActive: Bool { isSampled && hasAdjustment }

    /// The card's 范围 slider as a linear multiplier around its default (30 = 1×).
    public var rangeScale: Double { max(range, 0) / Self.defaultRange }
    /// The card's 过渡 slider as a shoulder-only multiplier around its default (30 = 1×).
    public var featherScale: Double { max(feather, 0) / Self.defaultFeather }

    /// 285 — hue platform at this 范围 (degrees).
    public var huePlateau: Double { Self.huePlateauDegrees * rangeScale }
    /// 285 — hue shoulder before the sample-spacing cap (`PointColorSet` applies that cap).
    public var hueShoulder: Double { Self.featherRatio * huePlateau * featherScale }
    /// 285 — chroma platform: 30 % of the sample's own C, clamped to `0.02…0.12`.
    public var chromaTolerance: Double {
        let relative = Self.chromaRelativeTolerance * sampleChroma * rangeScale
        let low = Self.chromaToleranceMin * rangeScale
        return min(max(relative, low), Self.chromaToleranceMax)
    }
    /// 285 — chroma shoulder (same 0.5 × platform shape as the other axes).
    public var chromaShoulder: Double {
        Self.featherRatio * chromaTolerance * featherScale
    }
    /// 285 — OKLab L platform at this 范围.
    public var lumaPlateau: Double { Self.lumaPlateauWidth * rangeScale }
    /// 285 — OKLab L shoulder.
    public var lumaShoulder: Double { Self.featherRatio * lumaPlateau * featherScale }

    /// The wrapped angular distance `((a − b + 540) mod 360) − 180`, in `[−180, 180)`.
    ///
    /// This is the one hue operation that must not be re-spelled per caller: the host and the kernel
    /// both take it from exactly this formula (`PointColorTests` pins the wrap).
    public static func angularDistance(_ a: Double, _ b: Double) -> Double {
        var d = (a - b + 540).truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d - 180
    }

    /// One axis of the soft box: 1 through `d`, `1 − smoothstep(d, d + shoulder, |Δ|)` beyond.
    public static func boxWeight(_ delta: Double, d: Double, shoulder: Double) -> Double {
        let x = abs(delta)
        if x <= d { return 1 }
        guard shoulder > 0, x < d + shoulder else { return 0 }
        let t = (x - d) / shoulder
        return 1 - t * t * (3 - 2 * t)
    }

    /// The full weight at one **stage-input** OKLCh triple.
    ///
    /// The pale guard comes first: a pixel with `C < 0.5 · chromaFloor` is exactly 0, so a grey and a
    /// nearly-grey gradient are written back bit for bit.
    ///
    /// `hueShoulder` is an override so `PointColorSet` can hand in the neighbour-capped shoulder; the
    /// single-swatch path uses the card's own value.
    public func weight(l: Double, c: Double, hue: Double,
                       hueShoulder: Double? = nil) -> Double {
        guard c >= 0.5 * Self.chromaFloor else { return 0 }
        let wh = Self.boxWeight(Self.angularDistance(hue, sampleHue),
                                d: huePlateau, shoulder: hueShoulder ?? self.hueShoulder)
        let wc = Self.boxWeight(c - sampleChroma,
                                d: chromaTolerance, shoulder: chromaShoulder)
        let wl = Self.boxWeight(l - sampleLightness,
                                d: lumaPlateau, shoulder: lumaShoulder)
        return wh * wc * wl
    }

    /// The whole S3.6b step for one **display-referred linear working-primaries** pixel — the CPU
    /// reference the kernel is written against (`s3_6b_point_colour.metal`).
    ///
    /// 285: the weight is evaluated on the same OKLCh triple the adjustment already needs — no YUV
    /// round trip inside the stage.
    public func apply(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        guard isActive else { return rgb }
        let lch = OKLCh.fromLinear(rgb)
        let w = weight(l: lch.L, c: lch.C, hue: lch.hue)
        guard w > 0 else { return rgb }
        let h = lch.hue + w * hue * Self.degreesPerUnit
        let c = max(lch.C * (1 + w * saturation / 100), 0)
        let l = lch.L * pow(2, w * luminance / 100)
        let out = OKLCh.toLinear(L: l, C: c, hue: h)
        return SIMD3(max(out.x, 0), max(out.y, 0), max(out.z, 0))
    }

    // MARK: - Rec.709 full-range YCbCr

    /// Linear working primaries → Rec.709 full-range YCbCr.
    ///
    /// The display-referred frame is **linear working (Rec.2020)** light; Rec.709 YCbCr is defined on
    /// display-encoded sRGB codes, so this converts primaries first and applies the sRGB OETF before
    /// the luma matrix. That is also what makes the `≈ ±15/255` reading of `d1` true.
    ///
    /// The luma is measured on the **Rec.709 / sRGB encoded** triple, so its weights are the working
    /// primaries' (`ColorPrimaries.working.luminanceWeights`, `kWorkingLumaWeights` in the kernel) —
    /// never a hard-coded Rec.709 copy.
    public static func yuv(fromLinearWorking rgb: SIMD3<Double>) -> SIMD3<Double> {
        let linear = ColorPrimaries.conversion(from: ColorPrimaries.working, to: .sRGB)
            .applying(to: rgb)
        let r = srgbEncode(linear.x)
        let g = srgbEncode(linear.y)
        let b = srgbEncode(linear.z)
        let w = ColorPrimaries.working.luminanceWeights
        let y = w.x * r + w.y * g + w.z * b
        let u = (b - y) / 1.8556 + 0.5
        let v = (r - y) / 1.5748 + 0.5
        return SIMD3(y, u, v)
    }

    /// The inverse: Rec.709 full-range YCbCr → linear working primaries.
    public static func linearWorking(from yuv: SIMD3<Double>) -> SIMD3<Double> {
        let y = yuv.x
        let cb = yuv.y - 0.5
        let cr = yuv.z - 0.5
        let b = y + 1.8556 * cb
        let r = y + 1.5748 * cr
        let w = ColorPrimaries.working.luminanceWeights
        let g = (y - w.x * r - w.z * b) / w.y
        let linear = SIMD3(srgbDecode(r), srgbDecode(g), srgbDecode(b))
        return ColorPrimaries.conversion(from: .sRGB, to: ColorPrimaries.working)
            .applying(to: linear)
    }

    /// The sampled YUV of a **decoded linear** RGB sample (the dropper's buffer), put through the same
    /// decode → working → display encoding the graph uses.
    ///
    /// This is the **white-balance / legacy** domain (the decode). 256's point-colour dropper reads
    /// S3.6b's own input and must use `sampleYUV(fromWorkingLinear:)` instead: using this one there
    /// would convert a working-primaries pixel as if it were a decoded one.
    public static func sampleYUV(fromDecodedLinear rgb: RGBSample) -> SIMD3<Double> {
        let decoded = SIMD3(rgb.r, rgb.g, rgb.b)
        let working = ColorPrimaries.conversion(from: ColorPrimaries.decoded,
                                                to: ColorPrimaries.working).applying(to: decoded)
        return yuv(fromLinearWorking: working)
    }

    /// 256 — the sampled YUV of an **S3.6b input** pixel: linear **working** primaries, after S1/S2/
    /// S3.4/S3.5/S3.6 and before S3.6b changes anything.
    ///
    /// Same conversion as the kernel (`s3_6b_point_colour.metal` builds its YUV from the
    /// working→sRGB matrix), so the sample the card stores and the predicate the kernel evaluates
    /// cannot come from two different colour pipelines.
    public static func sampleYUV(fromWorkingLinear rgb: RGBSample) -> SIMD3<Double> {
        yuv(fromLinearWorking: SIMD3(rgb.r, rgb.g, rgb.b))
    }

    /// Keep the 140 spelling for callers that only need the display hue/chroma.
    public static func sample(fromDecodedLinear rgb: RGBSample) -> (hue: Double, chroma: Double) {
        let lch = OKLCh.fromLinear(linearWorking(from: sampleYUV(fromDecodedLinear: rgb)))
        return (lch.hue, lch.C)
    }

    private static func srgbEncode(_ v: Double) -> Double {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    private static func srgbDecode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// `s3.6b/285/|sampleY=…;…` — S3.6b's key material.
    ///
    /// 285 changed what the stored numbers **mean** (YCbCr box → OKLCh platform/shoulder) without
    /// changing the spelling. The version prefix is the part that makes a pre-285 render cache miss
    /// instead of serving a frame the new kernel would not produce. It is a prefix rather than a
    /// `StageAlgorithmVersion` bump so the stage version list (`SharpenScaleTests`) keeps its claim
    /// that only the stage whose numbers moved owns a new generation.
    public var keyString: String {
        "s3.6b/285/|"
            + "sampleY=\(k(sampleY));sampleU=\(k(sampleU));sampleV=\(k(sampleV))"
            + ";range=\(k(range));feather=\(k(feather))"
            + ";h=\(k(hue));s=\(k(saturation));l=\(k(luminance))"
    }
}

// MARK: - 158 · multiple point-colour swatches

/// An ordered list of point-colour swatches plus the one the sliders edit.
///
/// 285 — **every** swatch is evaluated on the **stage input**, then all weights are normalised by
/// `max(1, Σw)`, so an overlap splits the pixel instead of stacking two full moves and the result is
/// independent of array order. The hue shoulder is capped here by the nearest sample's angular
/// distance (`min(shoulder, max(0, d_min − platform))`); the platform itself stays the user's 范围.
/// `active` only decides which swatch the five sliders write and never enters the stage key.
public struct PointColorSet: Sendable, Equatable, Codable {

    /// The UI refuses a ninth sample; the kernel's uniform array is sized to this.
    public static let maxSwatches = 8

    public var swatches: [PointColor]
    /// Index into `swatches`, or `nil` for "nothing selected" (the transparent slot).
    public var active: Int?

    public init(swatches: [PointColor] = [], active: Int? = nil) {
        self.swatches = swatches
        self.active = active
        if let active, !swatches.indices.contains(active) { self.active = nil }
    }

    /// Backward compatibility (M1): a pre-158 document stored one bare `PointColor` object under
    /// `point`. Reading that shape yields one swatch, selected.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        if c.contains(AnyCodingKey("swatches")) {
            let list = c.val("swatches", [PointColor]())
            let active: Int? = c.val("active", nil)
            self.init(swatches: list, active: active)
        } else {
            let one = try PointColor(from: decoder)
            self.init(swatches: [one], active: 0)
        }
    }

    /// Written in the **new** shape (`swatches` array + `active`) — the recommended spelling in the
    /// dispatch. The decoder still accepts the old single-object shape above.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(swatches, forKey: AnyCodingKey("swatches"))
        try c.encodeIfPresent(active, forKey: AnyCodingKey("active"))
    }

    /// Does any swatch carry a sample **and** a non-zero adjustment?
    public var isActive: Bool { swatches.contains { $0.isActive } }

    /// The one the sliders read, when the index is still valid.
    public var activeSwatch: PointColor? {
        guard let active, swatches.indices.contains(active) else { return nil }
        return swatches[active]
    }

    public var isFull: Bool { swatches.count >= Self.maxSwatches }

    /// Append a sampled swatch and select it. Returns the new index, or `nil` when the swatch has no
    /// usable chroma (K4) or the eight-swatch cap is reached.
    @discardableResult
    public mutating func append(_ swatch: PointColor) -> Int? {
        guard swatch.isSampled, !isFull else { return nil }
        swatches.append(swatch)
        active = swatches.count - 1
        return active
    }

    /// Select without touching any pixel. Out-of-range answers "nothing selected".
    public mutating func select(_ index: Int?) {
        guard let index, swatches.indices.contains(index) else {
            active = nil
            return
        }
        active = index
    }

    /// Delete exactly one swatch (double-click). Selection falls back to the previous index, floor 0;
    /// deleting the first leaves the old second selected; deleting the last returns to no selection.
    @discardableResult
    public mutating func remove(at index: Int) -> Bool {
        guard swatches.indices.contains(index) else { return false }
        let wasActive = active
        swatches.remove(at: index)
        if swatches.isEmpty {
            active = nil
        } else if let wasActive {
            if wasActive == index {
                active = max(0, index - 1)
            } else if wasActive > index {
                active = wasActive - 1
            }
        } else {
            active = nil
        }
        return true
    }

    /// The stage material: **all** swatch parameters in array order, and never `active`.
    public var keyString: String {
        guard !swatches.isEmpty else { return "none" }
        return "swatches=" + swatches.map { "{\($0.keyString)}" }.joined(separator: ";")
    }

    /// 285 — each swatch's hue shoulder after the sample-spacing cap. Indexed exactly like
    /// `swatches`, so the stage builder and the CPU reference upload/evaluate the same number.
    ///
    /// A transition may not reach across its nearest neighbour: `shoulder_i = min(shoulder_i,
    /// max(0, d_min_i − platform_i))`. The bound is the **sample spacing**, not the chroma radius:
    /// a pale sample keeps its shoulder even though its chroma tolerance is small.
    public static func effectiveHueShoulders(for swatches: [PointColor]) -> [Double] {
        swatches.indices.map { i in
            let s = swatches[i]
            var nearest = Double.infinity
            for j in swatches.indices where j != i {
                nearest = min(nearest,
                              abs(PointColor.angularDistance(s.sampleHue, swatches[j].sampleHue)))
            }
            guard nearest.isFinite else { return s.hueShoulder }
            return min(s.hueShoulder, max(0, nearest - s.huePlateau))
        }
    }

    /// The instance spelling of `effectiveHueShoulders(for:)`.
    public var effectiveHueShoulders: [Double] {
        Self.effectiveHueShoulders(for: swatches)
    }

    /// The whole S3.6b stage for one pixel.
    ///
    /// 285 — two passes: every weight is measured on the **input** (never on the previous swatch's
    /// output), then normalised by `max(1, Σw)` and applied in array order. A single swatch (Σw ≤ 1)
    /// is exactly its own `PointColor.apply`; two full-weight boxes each take half, so the total move
    /// does not double. The L/C scalings commute with the H addition, so swapping the array order
    /// does not move the pixel (to floating-point precision).
    public func apply(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        guard isActive else { return rgb }
        let lch = OKLCh.fromLinear(rgb)
        let shoulders = effectiveHueShoulders
        var weights = [Double](repeating: 0, count: swatches.count)
        var sum = 0.0
        for (i, swatch) in swatches.enumerated() where swatch.isActive {
            let w = swatch.weight(l: lch.L, c: lch.C, hue: lch.hue,
                                  hueShoulder: shoulders[i])
            weights[i] = w
            sum += w
        }
        guard sum > 0 else { return rgb }

        let divisor = max(1, sum)
        var l = lch.L
        var c = lch.C
        var h = lch.hue
        for (i, swatch) in swatches.enumerated() where swatch.isActive {
            let w = weights[i] / divisor
            guard w > 0 else { continue }
            h += w * swatch.hue * PointColor.degreesPerUnit
            c = max(c * (1 + w * swatch.saturation / 100), 0)
            l *= pow(2, w * swatch.luminance / 100)
        }
        let out = OKLCh.toLinear(L: l, C: c, hue: h)
        return SIMD3(max(out.x, 0), max(out.y, 0), max(out.z, 0))
    }
}
