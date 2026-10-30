import Foundation
import simd

// MARK: - 140 · 点颜色 (Point Color) — 158: YUV box + multiple swatches

/// **Point Color** — one sampled colour, a **YCbCr neighbourhood box** around it, and three
/// adjustments scoped to that box. S3.6b renders it on the display-referred frame, immediately after
/// S3.6.
///
/// ## Why the window is a YUV box (158)
///
/// 140 selected by OKLCh hue alone: a pale pink and a saturated red at the same hue received the same
/// weight, and lightness/saturation were irrelevant to whether a pixel was "in". The user's
/// correction is explicit: 点颜色抓的是该 YUV 附近的颜色, `[Y−d1,Y+d1][U−d2,U+d2][V−d3,V+d3]`, and
/// 「不能选择饱和度很淡的区域」. So the weight is now the product of three soft boxes in Rec.709
/// full-range YCbCr:
///
///   w = wy(Y) · wu(U) · wv(V)
///
/// each axis `1 − smoothstep(d, d + feather, |Δ|)` (C¹, exactly 0 at `d + feather`). The chroma axes
/// are measured from the full-range midpoint (0.5) and the three axes multiply with **equal weight** —
/// no weighted sum, because the box is a *region*, not a score.
///
/// The three radii are perceptual constants, not a second colour theory:
///
///   · **`d1 = 0.06`** for Y (≈ ±15/255): luminance carries the detail that makes two nearby pixels
///     look like the same material, so its box is the tightest.
///   · **`d2 = d3 = 0.10`** for U/V (≈ ±13/255 of chroma): human chroma acuity is much lower, so a
///     wider chroma box is needed to catch the shading and texture inside one object.
///   · **`feather = 0.5 · d`** per axis: a soft shoulder half the radius wide, so the box has no step
///     at its boundary.
///
/// The card's existing 范围/过渡 rows keep their 0…120 travel and scale those constants around their
/// defaults (30/30), which is why a freshly sampled swatch uses exactly the numbers above.
///
/// ### The pale-colour guard
///
/// `chromaFloorYCbCr = 0.02` (≈ 5/255) is the hard requirement: a sample whose own chroma
/// `c = hypot(U − 0.5, V − 0.5)` is below it is **rejected** by the dropper, and any pixel with
/// `c < 0.5 · chromaFloorYCbCr` gets weight 0 no matter what the box says. A grey therefore remains
/// bit-identical (weight 0 writes the source pixel back), and a nearly-grey patch cannot be tinted by
/// accident.
///
/// The sample stores its Y/U/V. `sampleHue`/`sampleChroma` are **derived** from them for the card's
/// swatch display; they are never written independently.
public struct PointColor: Sendable, Equatable, Codable {

    /// Slider units → OKLCh degrees, the number `HSLBand` and `GradeWheel` already speak: +100 is
    /// +30°, so the acceptance's “hue +30°” is the slider at +100.
    public static let degreesPerUnit: Double = 0.3

    /// 158 — Rec.709 full-range luma radius (≈ ±15/255). See the type comment for why these three are
    /// constants and why luminance is the tightest axis.
    public static let lumaRadius: Double = 0.06
    /// 158 — Rec.709 full-range chroma radius on U and V (≈ ±13/255).
    public static let chromaRadius: Double = 0.10
    /// 158 — the soft shoulder is half the radius, per axis.
    public static let featherRatio: Double = 0.5
    /// 158 — the dropper refuses a sample below this chroma magnitude (≈ 5/255).
    public static let chromaFloorYCbCr: Double = 0.02

    /// The card's 范围 default (30) is the "1×" of the radii above; 0…120 scales the box.
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

    /// The sampled pixel's own YUV chroma magnitude: `hypot(U − 0.5, V − 0.5)`.
    public var sampleChromaYCbCr: Double {
        hypot(sampleU - 0.5, sampleV - 0.5)
    }

    /// A colour with a meaningful chroma was actually picked. Below `chromaFloorYCbCr` there is no
    /// colour to select (the dropper refuses to create such a swatch).
    public var isSampled: Bool {
        sampleY.isFinite && sampleU.isFinite && sampleV.isFinite
            && sampleChromaYCbCr >= Self.chromaFloorYCbCr
    }

    /// Any of the three adjustment sliders is away from zero. `range`/`feather` alone do not make a
    /// stage: they describe a window, they do not move a pixel.
    public var hasAdjustment: Bool {
        hue != 0 || saturation != 0 || luminance != 0
    }

    /// **The predicate the pipeline and the key chain use.**
    public var isActive: Bool { isSampled && hasAdjustment }

    /// The three box radii after the card's 范围 slider (default 30 = the constants).
    public var lumaHalfWidth: Double {
        Self.lumaRadius * max(range, 0) / Self.defaultRange
    }
    public var chromaHalfWidth: Double {
        Self.chromaRadius * max(range, 0) / Self.defaultRange
    }
    /// The soft shoulder after the card's 过渡 slider (default 30 = half each axis's radius).
    public var featherScale: Double { max(feather, 0) / Self.defaultFeather }
    public var lumaFeatherWidth: Double {
        Self.featherRatio * lumaHalfWidth * featherScale
    }
    public var chromaFeatherWidth: Double {
        Self.featherRatio * chromaHalfWidth * featherScale
    }

    /// One axis of the soft box: 1 through `d`, `1 − smoothstep(d, d + shoulder, |Δ|)` beyond.
    public static func boxWeight(_ delta: Double, d: Double, shoulder: Double) -> Double {
        let x = abs(delta)
        if x <= d { return 1 }
        guard shoulder > 0, x < d + shoulder else { return 0 }
        let t = (x - d) / shoulder
        return 1 - t * t * (3 - 2 * t)
    }

    /// The full weight at one display-referred YCbCr triple.
    ///
    /// The pale guard comes first: a pixel with `c < 0.5 · chromaFloorYCbCr` is exactly 0, so a grey
    /// (U = V = 0.5) and a nearly-grey gradient are written back bit for bit.
    public func weight(yuv: SIMD3<Double>) -> Double {
        let c = hypot(yuv.y - 0.5, yuv.z - 0.5)
        guard c >= 0.5 * Self.chromaFloorYCbCr else { return 0 }
        let d1 = lumaHalfWidth
        let d2 = chromaHalfWidth
        let wy = Self.boxWeight(yuv.x - sampleY, d: d1, shoulder: lumaFeatherWidth)
        let wu = Self.boxWeight(yuv.y - sampleU, d: d2, shoulder: chromaFeatherWidth)
        let wv = Self.boxWeight(yuv.z - sampleV, d: d2, shoulder: chromaFeatherWidth)
        return wy * wu * wv
    }

    /// The whole S3.6b step for one **display-referred linear working-primaries** pixel — the CPU
    /// reference the kernel is written against (`s3_6b_point_colour.metal`).
    public func apply(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        guard isActive else { return rgb }
        let yuv = Self.yuv(fromLinearWorking: rgb)
        let w = weight(yuv: yuv)
        guard w > 0 else { return rgb }
        let lch = OKLCh.fromLinear(rgb)
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
    public static func yuv(fromLinearWorking rgb: SIMD3<Double>) -> SIMD3<Double> {
        let linear = ColorPrimaries.conversion(from: ColorPrimaries.working, to: .sRGB)
            .applying(to: rgb)
        let r = srgbEncode(linear.x)
        let g = srgbEncode(linear.y)
        let b = srgbEncode(linear.z)
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
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
        let g = (y - 0.2126 * r - 0.0722 * b) / 0.7152
        let linear = SIMD3(srgbDecode(r), srgbDecode(g), srgbDecode(b))
        return ColorPrimaries.conversion(from: .sRGB, to: ColorPrimaries.working)
            .applying(to: linear)
    }

    /// The sampled YUV of a **decoded linear** RGB sample (the dropper's buffer), put through the same
    /// decode → working → display encoding the graph uses.
    public static func sampleYUV(fromDecodedLinear rgb: RGBSample) -> SIMD3<Double> {
        let decoded = SIMD3(rgb.r, rgb.g, rgb.b)
        let working = ColorPrimaries.conversion(from: ColorPrimaries.decoded,
                                                to: ColorPrimaries.working).applying(to: decoded)
        return yuv(fromLinearWorking: working)
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

    /// `sampleY=…;sampleU=…;sampleV=…;range=…;feather=…;h=…;s=…;l=…` — S3.6b's key material.
    public var keyString: String {
        "sampleY=\(k(sampleY));sampleU=\(k(sampleU));sampleV=\(k(sampleV))"
            + ";range=\(k(range));feather=\(k(feather))"
            + ";h=\(k(hue));s=\(k(saturation));l=\(k(luminance))"
    }
}

// MARK: - 158 · multiple point-colour swatches

/// An ordered list of point-colour swatches plus the one the sliders edit.
///
/// **Every** swatch renders, in array order, each seeing the previous one's output; `active` only
/// decides which swatch the five sliders write. It deliberately does **not** enter the stage key (it
/// moves no pixel) or `isActive` (an empty/all-neutral list is no stage at all).
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

    /// The whole S3.6b stage for one pixel: each swatch in array order, each seeing the previous one's
    /// output. This is the CPU reference for the kernel's loop.
    public func apply(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        var out = rgb
        for swatch in swatches {
            out = swatch.apply(out)
        }
        return out
    }
}
