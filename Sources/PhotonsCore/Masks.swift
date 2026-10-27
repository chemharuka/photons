import Foundation

// MARK: - M4 local masks: the value layer
//
// Masks are **first-class values** (docs/architecture-decisions.md D11): everything the renderer
// needs is a parameter, nothing is a bitmap. Coordinates are normalised to the **uncropped source
// image** and distances are divided by `min(W, H)`, so one document produces the same shape at
// thumbnail, fit, 1:1 and export scale — which is the whole reason a mask never stores a bitmap.
//
// Field defaults are explicit and every decoder falls back to them (D9): a missing key never becomes
// zero and never fails the document.

// MARK: - combination

/// How a component joins the running selection. The first component's `op` is ignored.
public enum CombineOp: String, Codable, Sendable, CaseIterable {
    /// Union: `max(acc, a)`. The same "max is a union, joints do not double-expose" rule as the
    /// brush accumulation blend, where a stroke is one render pass of per-segment quads blended with
    /// `MTLBlendOperation.max` (max is a union, so joints never double-expose).
    case add
    /// `acc · (1 − a)` — the erase blend (`a_d · (1 − a_s)`) applied to a whole component.
    case subtract
    /// `acc · a` — the product rule ART uses for stacked masks (§4.6).
    case intersect
}

// MARK: - local adjustments

/// The eleven local sliders plus `amount`. Parameter-only; applied in S1.6 and S3.5, **never** in
/// S1.5, so a mask's atlas layer does not depend on its own adjustments (§3.3 item 4).
///
/// 派单 056 split the two stages by **domain**: exposure, temperature/tint and the tone shaping are
/// scene-linear gains and stay in S1.6 (before the curve and the tone map); `hue` and `saturation`
/// are display-referred operations and moved to S3.5, where they run the same `color_hsl.metal`
/// include the global S3 slider does. The stored fields did not move — only which stage reads them.
public struct LocalAdjustments: Sendable, Equatable, Codable {
    /// 0…100. The whole adjustment is lerped by this (100 = full).
    public var amount: Double
    /// −4…4 EV, applied in scene-linear light before S2 (a display-side gain cannot recover
    /// highlights S2 already compressed).
    public var exposure: Double
    /// −100…100 relative shift, mapped onto the M1-7 Planckian approximation (`6500 K + 30 K/unit`).
    public var temperature: Double
    /// −100…100, positive = magenta. Same mapping as `LightGroup.tint`.
    public var tint: Double
    public var contrast: Double
    public var highlights: Double
    public var shadows: Double
    public var whites: Double
    public var blacks: Double
    public var hue: Double
    public var saturation: Double

    public static let identity = LocalAdjustments()

    public init(amount: Double = 100, exposure: Double = 0,
                temperature: Double = 0, tint: Double = 0,
                contrast: Double = 0, highlights: Double = 0, shadows: Double = 0,
                whites: Double = 0, blacks: Double = 0,
                hue: Double = 0, saturation: Double = 0) {
        self.amount = amount
        self.exposure = exposure
        self.temperature = temperature
        self.tint = tint
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.hue = hue
        self.saturation = saturation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = LocalAdjustments()
        v.amount = c.val("amount", v.amount)
        v.exposure = c.val("exposure", v.exposure)
        v.temperature = c.val("temperature", v.temperature)
        v.tint = c.val("tint", v.tint)
        v.contrast = c.val("contrast", v.contrast)
        v.highlights = c.val("highlights", v.highlights)
        v.shadows = c.val("shadows", v.shadows)
        v.whites = c.val("whites", v.whites)
        v.blacks = c.val("blacks", v.blacks)
        v.hue = c.val("hue", v.hue)
        v.saturation = c.val("saturation", v.saturation)
        self = v
    }

    /// True when S1.6 must take the real identity branch (`dst = src`, bit-exact — M1-6 discipline).
    /// `amount == 0` means "this mask renders nothing", which is also the identity.
    public var isIdentity: Bool {
        amount <= 0 || (exposure == 0 && temperature == 0 && tint == 0 && contrast == 0
                        && highlights == 0 && shadows == 0 && whites == 0 && blacks == 0
                        && hue == 0 && saturation == 0)
    }

    /// True when a mask carries a hue or a saturation value — the **only** predicate that makes the
    /// S3.5 stage exist for a render (派单 056 §验收 7: by value, not by "there is a mask").
    public var contributesLocalColor: Bool { hue != 0 || saturation != 0 }

    /// True when **S1.6** has real work: the scene-linear gain and the tone shaping, minus hue and
    /// saturation, which moved to S3.5. A mask whose only sliders are hue/saturation must leave
    /// S1.6's identity branch alone — running it through `local_adjust`'s neutral arithmetic would
    /// round the pixel (`0.18 · pow(v / 0.18, 1)`) for a stage with nothing to do, and "a mask with
    /// no S1.6 adjustment is bit-exact against no mask" is a contract (§3.3 item 3).
    public var hasSceneLinearWork: Bool {
        amount > 0 && (exposure != 0 || temperature != 0 || tint != 0 || contrast != 0
                       || highlights != 0 || shadows != 0 || whites != 0 || blacks != 0)
    }

    /// Scene-linear RGB gain from exposure plus the M1-7 white-balance approximation.
    /// Reusing `LightGroup` keeps one Planckian fit in the codebase instead of two that drift.
    public var gain: (r: Float, g: Float, b: Float) {
        let ev = Float(pow(2.0, min(max(exposure, -4), 4)))
        let kelvin = 6500 + min(max(temperature, -100), 100) * 30
        let wb = LightGroup(temperature: kelvin, tint: min(max(tint, -100), 100)).whiteBalanceGains
        return (ev * wb.r, ev * wb.g, ev * wb.b)
    }

    public var keyString: String {
        "amt=\(k(amount));ev=\(k(exposure));temp=\(k(temperature));tint=\(k(tint))"
            + ";con=\(k(contrast));hi=\(k(highlights));sh=\(k(shadows))"
            + ";wh=\(k(whites));bl=\(k(blacks));hue=\(k(hue));sat=\(k(saturation))"
    }
}

// MARK: - shapes

/// A point in normalised source coordinates (0…1, origin top-left), encoded as `[x, y]`.
public struct NormalizedPoint: Sendable, Equatable, Codable, Hashable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let xy = try? single.decode([Double].self) {
            self.init(xy.count > 0 ? xy[0] : 0.5, xy.count > 1 ? xy[1] : 0.5)
            return
        }
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.init(c.val("x", 0.5), c.val("y", 0.5))
    }

    public func encode(to encoder: any Encoder) throws {
        var s = encoder.singleValueContainer()
        try s.encode([x, y])
    }

    public var keyString: String { "\(k(x)),\(k(y))" }
}

/// §4.2 — a gradient between two lines. `start` and `end` are the centres of the two lines; the
/// shape is evaluated analytically, so it is exact at every scale and needs no raster.
public struct LinearGradientShape: Sendable, Equatable, Codable {
    public var start: NormalizedPoint
    public var end: NormalizedPoint
    /// Moves the 50 % point along the ramp: `t' = t^(log 0.5 / log m)` (§4.2).
    public var midpoint: Double

    public static let `default` = LinearGradientShape()

    public init(start: NormalizedPoint = NormalizedPoint(0.5, 0),
                end: NormalizedPoint = NormalizedPoint(0.5, 1),
                midpoint: Double = 0.5) {
        self.start = start
        self.end = end
        self.midpoint = midpoint
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = LinearGradientShape.default
        v.start = c.val("start", v.start)
        v.end = c.val("end", v.end)
        v.midpoint = c.val("midpoint", v.midpoint)
        self = v
    }

    public var keyString: String {
        "lin(start=\(start.keyString);end=\(end.keyString);mid=\(k(midpoint)))"
    }
}

/// §4.3 — a rotated ellipse. `radius` is in short-edge units and is **effectively equal for both
/// axes** unless the caller wants an ellipse; `angle` is in degrees, positive = clockwise on screen.
public struct RadialGradientShape: Sendable, Equatable, Codable {
    public var center: NormalizedPoint
    public var radius: NormalizedPoint
    public var angle: Double

    public static let `default` = RadialGradientShape()

    public init(center: NormalizedPoint = NormalizedPoint(0.5, 0.5),
                radius: NormalizedPoint = NormalizedPoint(0.25, 0.25),
                angle: Double = 0) {
        self.center = center
        self.radius = radius
        self.angle = angle
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = RadialGradientShape.default
        v.center = c.val("center", v.center)
        v.radius = c.val("radius", v.radius)
        v.angle = c.val("angle", v.angle)
        self = v
    }

    public var keyString: String {
        "rad(c=\(center.keyString);r=\(radius.keyString);ang=\(k(angle)))"
    }
}

/// One brush stroke: a flat polyline walked as a capsule chain (§4.1). Coverage is a distance field
/// over the S1.5 atlas: `alpha = 1 − smoothstep(r(1−f), r, distToSegment)`, accumulated with `max`
/// inside one stroke so joints never double-expose.
public struct Stroke: Sendable, Equatable, Codable {
    /// Flat `[x0, y0, x1, y1, …]`, normalised to the uncropped source.
    public var points: [Float]
    /// Empty = no pressure. Non-empty has one entry per point and only scales the radius.
    public var pressure: [Float]
    /// Short-edge units. Already includes the brush's `size`.
    public var radius: Double
    /// 0…1; the hard core is `1 − feather`.
    public var feather: Double
    /// 0…1, a per-stroke alpha multiplier.
    public var flow: Double
    public var erase: Bool
    /// Joins the last point back to the first (§2/§4.1: "one stroke, several segments, closable").
    public var closed: Bool

    public static let `default` = Stroke()

    public init(points: [Float] = [], pressure: [Float] = [], radius: Double = 0.06,
                feather: Double = 0.5, flow: Double = 1, erase: Bool = false,
                closed: Bool = false) {
        self.points = points
        self.pressure = pressure
        self.radius = radius
        self.feather = feather
        self.flow = flow
        self.erase = erase
        self.closed = closed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = Stroke.default
        v.points = c.val("points", v.points)
        v.pressure = c.val("pressure", v.pressure)
        v.radius = c.val("radius", v.radius)
        v.feather = c.val("feather", v.feather)
        v.flow = c.val("flow", v.flow)
        v.erase = c.val("erase", v.erase)
        v.closed = c.val("closed", v.closed)
        self = v
    }

    /// Radius actually painted, short-edge units. A stroke carries its own radius (§2); `size` is
    /// only the UI's current diameter and is the fallback for a stroke that carries none.
    public func resolvedRadius(fallbackSize size: Double) -> Double {
        radius > 0 ? radius : max(size, 0) * 0.5
    }

    public var keyString: String {
        // 5 decimals is the 1e-5 coordinate quantisation of §2 (~0.6 px at 60 MP).
        let p = points.map { k(Double($0)) }.joined(separator: ",")
        let pr = pressure.isEmpty ? "" : pressure.map { k(Double($0)) }.joined(separator: ",")
        return "st(r=\(k(radius));f=\(k(feather));fl=\(k(flow));e=\(erase ? 1 : 0);c=\(closed ? 1 : 0);p=[\(p)];pr=[\(pr)])"
    }
}

public struct BrushShape: Sendable, Equatable, Codable {
    /// The UI's current diameter (short-edge units). Each stroke carries its own radius, which is
    /// what the renderer paints with (§2).
    public var size: Double
    public var strokes: [Stroke]

    public static let `default` = BrushShape()

    public init(size: Double = 0.06, strokes: [Stroke] = []) {
        self.size = size
        self.strokes = strokes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = BrushShape.default
        v.size = c.val("size", v.size)
        v.strokes = c.val("strokes", v.strokes)
        self = v
    }

    public var keyString: String {
        "brush(size=\(k(size));s=[\(strokes.map(\.keyString).joined(separator: "|"))])"
    }
}

/// §4.4 — up to eight sRGB sample colours, nearest-colour distance in OKLab.
public struct ColorRangeShape: Sendable, Equatable, Codable {
    public static let maxSamples = 8
    /// sRGB 0…1 triples.
    public var samples: [[Double]]
    /// Soft threshold in OKLab metric units (see `OKLabMetric`).
    public var tolerance: Double
    /// Width of the value-domain transition, as a fraction of the remaining distance to the far end
    /// of the ramp: `alpha = 1 − smoothstep(tol, tol + smooth·(0.5 − tol), d)` (§4.4).
    public var smoothness: Double

    public static let `default` = ColorRangeShape()

    public init(samples: [[Double]] = [], tolerance: Double = 0.30, smoothness: Double = 0.50) {
        self.samples = Array(samples.prefix(ColorRangeShape.maxSamples))
        self.tolerance = tolerance
        self.smoothness = smoothness
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = ColorRangeShape.default
        v.samples = Array(c.val("samples", v.samples).prefix(ColorRangeShape.maxSamples))
        v.tolerance = c.val("tolerance", v.tolerance)
        v.smoothness = c.val("smoothness", v.smoothness)
        self = v
    }

    /// The metric-space coordinates the shader compares against: `(L, a/0.4, b/0.4)` per sample.
    /// Samples are stored sRGB-encoded (§2), so they are decoded to linear before OKLab — the same
    /// transform the pixel side takes, which keeps one comparison space (§4.4).
    public var metricSamples: [[Double]] {
        samples.map { s in
            guard s.count >= 3 else { return [0, 0, 0] }
            let lab = OKLabMetric.fromSRGB(s[0], s[1], s[2])
            return [lab.L, lab.a / OKLabMetric.chromaSpan, lab.b / OKLabMetric.chromaSpan]
        }
    }

    public var keyString: String {
        let s = samples.map { $0.map { k($0) }.joined(separator: ",") }.joined(separator: ";")
        return "colour(n=\(samples.count);s=[\(s)];tol=\(k(tolerance));smo=\(k(smoothness)))"
    }
}

/// §4.5 — OKLab L with two-sided feather.
public struct LuminanceRangeShape: Sendable, Equatable, Codable {
    public var low: Double
    public var high: Double
    public var lowFeather: Double
    public var highFeather: Double

    public static let `default` = LuminanceRangeShape()

    public init(low: Double = 0, high: Double = 1,
                lowFeather: Double = 0.10, highFeather: Double = 0.10) {
        self.low = low
        self.high = high
        self.lowFeather = lowFeather
        self.highFeather = highFeather
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = LuminanceRangeShape.default
        v.low = c.val("low", v.low)
        v.high = c.val("high", v.high)
        v.lowFeather = c.val("lowFeather", v.lowFeather)
        v.highFeather = c.val("highFeather", v.highFeather)
        self = v
    }

    public var isOrdered: Bool { !(low > high) }

    /// `low`/`high` with the documented repair for an inverted pair: the two bounds swap **with
    /// their own feathers**, so a mirrored range renders as the mirror of the original — never as
    /// an empty selection and never with the feathers silently exchanged (§4.5).
    public var ordered: (low: Double, high: Double, lowFeather: Double, highFeather: Double) {
        guard low > high else { return (low, high, lowFeather, highFeather) }
        return (high, low, highFeather, lowFeather)
    }

    public var keyString: String {
        "luma(lo=\(k(low));hi=\(k(high));loF=\(k(lowFeather));hiF=\(k(highFeather)))"
    }
}

// MARK: - the OKLab metric (§4.4)

/// Ottosson's OKLab (2020) — two matrices and a cube root, written from the published formulas.
/// Neither this nor any other file copies an in-tree implementation: ART, RawTherapee, darktable
/// (GPL-3.0) and RapidRAW (AGPL-3.0) stay read-only (§7).
///
/// **Metric space.** `L` is the OKLab lightness, which is already 0…1 for in-gamut colours. `a`/`b`
/// span roughly ±0.4 for sRGB, so they are divided by `chromaSpan` — one tolerance number then means
/// "this fraction of the gamut on either axis", and the two ranges are comparable (§4.4).
public enum OKLabMetric {
    /// The natural half-span of OKLab `a`/`b` for sRGB primaries.
    public static let chromaSpan = 0.4

    /// sRGB EOTF: encoded 0…1 → linear 0…1.
    public static func sRGBToLinear(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Linear **working primaries** (Rec.2020 since 075) → OKLab.
    ///
    /// **075 §2.2.** The nine numbers used to be Ottosson's *sRGB* LMS matrix
    /// (`0.4122214708, 0.5363325363, 0.0514459929, …`), which was right while the graph's working
    /// space was linear sRGB and is a silent colour error now that it is Rec.2020: the same
    /// coefficients applied to Rec.2020 codes fold the *wrong* light. Measured on a saturated red,
    /// the error is **0.1252** in OKLab against a `chromaSpan` of 0.4 — 31 % of the tolerance span,
    /// gradually wrong, and invisible in a golden.
    ///
    /// It is derived, not copied: `M1 · toXYZ(ColorPrimaries.working)`, i.e. Ottosson's normative
    /// LMS matrix times the working primaries' own RGB→XYZ. The kernel's copy
    /// (`s1_5_mask_atlas.metal`) has the resulting nine literals, and three tests hold the pair
    /// together: the CPU/GPU agreement test, and the two fixed-coverage tests, whose expected values
    /// are what a *correct* fold produces for known sRGB colours. Base invariance is the property
    /// being preserved: a correct fold gives the same OKLab for the same physical colour whichever
    /// base the numbers are written in, so the metric stays comparable with 005c/056's measurements.
    public static let lmsFold: Matrix3 = {
        let ottossonLMS = Matrix3(rows: [[0.8189330101, 0.3618667424, -0.1288597137],
                                        [0.0329845436, 0.9293118715, 0.0361456387],
                                        [0.0482003018, 0.2643662691, 0.6338517070]])
        // Rows normalised to sum to 1, exactly as Ottosson's published sRGB matrix is: white
        // `(1,1,1)` is the LMS triple of D65 and must fold to `L = 1, a = b = 0`, not to 0.999999.
        // (`MaskTests.testOKLabMetricMatchesPublishedValues` pins that at 1e-6.)
        let m = ottossonLMS * ColorPrimaries.working.toXYZ
        let s = m.rowSums
        return Matrix3(rows: (0..<3).map { r in (0..<3).map { c in m[r, c] / s[r] } })
    }()

    /// Linear working primaries → OKLab.
    public static func fromLinear(_ r: Double, _ g: Double, _ b: Double)
        -> (L: Double, a: Double, b: Double) {
        let f = lmsFold
        let l = f[0, 0] * r + f[0, 1] * g + f[0, 2] * b
        let m = f[1, 0] * r + f[1, 1] * g + f[1, 2] * b
        let s = f[2, 0] * r + f[2, 1] * g + f[2, 2] * b
        let l_ = cbrt(max(l, 0)), m_ = cbrt(max(m, 0)), s_ = cbrt(max(s, 0))
        return (L: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }

    /// sRGB-encoded 0…1 (the storage space of `ColorRangeShape.samples`) → OKLab.
    ///
    /// The decode lands in linear sRGB, so the sRGB → working conversion runs here, once per stored
    /// sample: a picked colour is an sRGB triple by contract (the picker reads display codes) and the
    /// metric is defined on the working space.
    public static func fromSRGB(_ r: Double, _ g: Double, _ b: Double)
        -> (L: Double, a: Double, b: Double) {
        let toWorking = ColorPrimaries.conversion(from: .sRGB, to: ColorPrimaries.working)
        let v = SIMD3(sRGBToLinear(r), sRGBToLinear(g), sRGBToLinear(b))
        let w = toWorking.applying(to: v)
        return fromLinear(w.x, w.y, w.z)
    }

    /// Distance in the normalised metric space, i.e. what the colour range compares against its
    /// tolerance.
    public static func distance(_ p: (L: Double, a: Double, b: Double),
                                _ q: (L: Double, a: Double, b: Double)) -> Double {
        let dL = p.L - q.L
        let da = (p.a - q.a) / chromaSpan
        let db = (p.b - q.b) / chromaSpan
        return (dL * dL + da * da + db * db).squareRoot()
    }
}

/// §5 — which system model answers a semantic mask.
///
/// The order is the documented one of 005e (§5.1 then §5.2): `sky`, `hair`, `skin`, `teeth`,
/// `glasses` and `person` can come from `CIRAWFilter`'s read-only mattes; `subject` is the Vision
/// foreground instance mask. `foreground` is the pre-005e spelling of `subject` and is kept so an
/// existing document round-trips byte for byte — it resolves through the same Vision request.
public enum SemanticKind: String, Codable, Sendable, CaseIterable {
    case sky, subject, person, hair, skin, teeth, glasses
    /// Legacy spelling of `subject`, kept so a document written before the seven kinds were named
    /// round-trips byte for byte. Same route, same raster: it is an alias, not a second model.
    case foreground
}

public enum SemanticProvider: String, Codable, Sendable, CaseIterable {
    case systemMatte, visionForeground
}

/// §5 — intent plus a digest of the raster the OS produced. The bitmap itself never enters the
/// document (RapidRAW's base64 PNG sidecar is the counter-example).
///
/// Wire note: the sub-kind travels as `subject`, not `kind`, because `kind` is the union
/// discriminator of `MaskShape` — two `kind` keys in one JSON object is not a document, it is a
/// coin flip. The decoder still accepts `kind` as a fallback so a hand-written file is not lost.
public struct SemanticShape: Sendable, Equatable, Codable {
    public var kind: SemanticKind
    public var provider: SemanticProvider
    public var softEdge: Double
    /// SHA-256 of the generated raster; a change means "the OS model changed", which the UI
    /// surfaces instead of silently re-cutting the selection.
    public var rasterDigest: String?

    public static let `default` = SemanticShape()

    private enum CodingKeys: String, CodingKey {
        case subject, provider, softEdge, rasterDigest
    }

    public init(kind: SemanticKind = .foreground, provider: SemanticProvider = .visionForeground,
                softEdge: Double = 0.20, rasterDigest: String? = nil) {
        self.kind = kind
        self.provider = provider
        self.softEdge = softEdge
        self.rasterDigest = rasterDigest
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = SemanticShape.default
        // `kind` is the fallback spelling of `subject` (see the wire note above).
        v.kind = c.val("subject", c.val("kind", v.kind))
        v.provider = c.val("provider", v.provider)
        v.softEdge = c.val("softEdge", v.softEdge)
        v.rasterDigest = c.val("rasterDigest", v.rasterDigest)
        self = v
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .subject)
        try c.encode(provider, forKey: .provider)
        try c.encode(softEdge, forKey: .softEdge)
        try c.encodeIfPresent(rasterDigest, forKey: .rasterDigest)
    }

    public var keyString: String {
        "sem(\(kind.rawValue);\(provider.rawValue);edge=\(k(softEdge));digest=\(rasterDigest ?? "-"))"
    }
}

/// The tagged union of §2. Hand-written `Codable`: `kind` is the discriminator, and an unknown
/// `kind` is preserved verbatim as `.unsupported` so a newer document re-encodes unchanged instead
/// of losing its selection (forward compatibility is a D9 requirement, not a nicety).
public enum MaskShape: Sendable, Equatable {
    case linearGradient(LinearGradientShape)
    case radialGradient(RadialGradientShape)
    case brush(BrushShape)
    case colorRange(ColorRangeShape)
    case luminanceRange(LuminanceRangeShape)
    case semantic(SemanticShape)
    case unsupported(kind: String, payload: JSONValue)

    public static let linearKind = "linearGradient"
    public static let radialKind = "radialGradient"
    public static let brushKind = "brush"
    public static let colorRangeKind = "colorRange"
    public static let luminanceRangeKind = "luminanceRange"
    public static let semanticKind = "semantic"

    /// The `kind` string written to the document.
    public var kind: String {
        switch self {
        case .linearGradient: return MaskShape.linearKind
        case .radialGradient: return MaskShape.radialKind
        case .brush: return MaskShape.brushKind
        case .colorRange: return MaskShape.colorRangeKind
        case .luminanceRange: return MaskShape.luminanceRangeKind
        case .semantic: return MaskShape.semanticKind
        case .unsupported(let kind, _): return kind
        }
    }

    /// Shapes this build can evaluate. `semantic` joined the list in 005e: it is evaluated from a
    /// raster the OS produced (see `MaskSemantics.swift`), and when no route can produce one it
    /// contributes zero coverage with a recorded reason instead of an approximation.
    public var isRenderableNow: Bool {
        switch self {
        case .linearGradient, .radialGradient, .brush, .colorRange, .luminanceRange, .semantic:
            return true
        case .unsupported: return false
        }
    }

    /// False only for kinds this build does not know at all.
    public var isKnownKind: Bool {
        if case .unsupported = self { return false }
        return true
    }

    public var keyString: String {
        switch self {
        case .linearGradient(let s): return s.keyString
        case .radialGradient(let s): return s.keyString
        case .brush(let s): return s.keyString
        case .colorRange(let s): return s.keyString
        case .luminanceRange(let s): return s.keyString
        case .semantic(let s): return s.keyString
        // Sorted keys and shortest-round-trip numbers: the same text in every process.
        case .unsupported(let kind, let payload): return "unknown(\(kind);\(payload.canonicalText))"
        }
    }
}

extension MaskShape: Codable {
    private enum Key {
        static let kind = "kind"
    }

    public init(from decoder: any Decoder) throws {
        let whole = try decoder.singleValueContainer()
        if let probe = try? whole.decode([String: JSONValue].self), probe[Key.kind] == nil {
            // No discriminator: treat the object as an unknown shape, preserving every byte.
            self = .unsupported(kind: "", payload: .object(probe))
            return
        }
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let kind: String = c.val(Key.kind, "")
        switch kind {
        case MaskShape.linearKind: self = .linearGradient(try LinearGradientShape(from: decoder))
        case MaskShape.radialKind: self = .radialGradient(try RadialGradientShape(from: decoder))
        case MaskShape.brushKind: self = .brush(try BrushShape(from: decoder))
        case MaskShape.colorRangeKind: self = .colorRange(try ColorRangeShape(from: decoder))
        case MaskShape.luminanceRangeKind: self = .luminanceRange(try LuminanceRangeShape(from: decoder))
        case MaskShape.semanticKind: self = .semantic(try SemanticShape(from: decoder))
        default: self = .unsupported(kind: kind, payload: .object(try Self.payload(from: decoder)))
        }
    }

    /// Everything except `kind`, captured as raw JSON so an unknown shape survives a round trip.
    private static func payload(from decoder: any Decoder) throws -> [String: JSONValue] {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var out: [String: JSONValue] = [:]
        for key in c.allKeys where key.stringValue != Key.kind {
            out[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
        return out
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(kind, forKey: AnyCodingKey(Key.kind))
        switch self {
        case .linearGradient(let s): try s.encode(to: encoder)
        case .radialGradient(let s): try s.encode(to: encoder)
        case .brush(let s): try s.encode(to: encoder)
        case .colorRange(let s): try s.encode(to: encoder)
        case .luminanceRange(let s): try s.encode(to: encoder)
        case .semantic(let s): try s.encode(to: encoder)
        case .unsupported(_, let payload):
            guard case .object(let fields) = payload else { return }
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) where key != Key.kind {
                try c.encode(value, forKey: AnyCodingKey(key))
            }
        }
    }
}

// MARK: - components

public struct MaskComponent: Sendable, Equatable, Codable {
    public var id: String
    /// Ignored for the first component.
    public var op: CombineOp
    /// Applied to this component's coverage before combining (§3.3: invert is per component).
    public var invert: Bool
    /// The shape's own transition width, short-edge normalised (0…0.1 expected, 1 = the whole ramp).
    public var feather: Double
    public var shape: MaskShape

    public static let fallback = MaskComponent(id: "", op: .add, invert: false,
                                              feather: 0.5, shape: .linearGradient(.default))

    public init(id: String = "", op: CombineOp = .add, invert: Bool = false,
                feather: Double = 0.5, shape: MaskShape = .linearGradient(.default)) {
        self.id = id
        self.op = op
        self.invert = invert
        self.feather = feather
        self.shape = shape
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = MaskComponent.fallback
        v.id = c.val("id", v.id)
        v.op = c.val("op", v.op)
        v.invert = c.val("invert", v.invert)
        v.feather = c.val("feather", v.feather)
        v.shape = c.val("shape", v.shape)
        self = v
    }

    public var keyString: String {
        "\(op.rawValue)/\(invert ? 1 : 0)/\(k(feather))/\(shape.keyString)"
    }
}

// MARK: - mask

public struct Mask: Sendable, Equatable, Codable, Identifiable {
    /// Hard cap from §7: 60 MB per layer at 60 MP, 4 MB at preview size.
    public static let maxCount = 12

    /// `"m-<uuid>"`. Stable, and the only part of the identity that reaches a cache key.
    public var id: String
    /// Free text. Deliberately **not** in any key: renaming must not invalidate a render.
    public var name: String
    public var isEnabled: Bool
    /// 1.0 = full. Multiplies the combined selection (§3.1).
    public var opacity: Double
    /// Applies to the combined selection: `1 − a`.
    public var invert: Bool
    /// Spatial blur of the combined selection, short-edge normalised (0…0.1).
    /// Keyed but **not yet applied** — a blur is a neighbourhood operator and belongs to 005d's
    /// `TileDependency` bookkeeping (see `s1_5_mask_atlas.metal`).
    public var feather: Double
    /// 0…1 guided-filter strength of the atlas (0 = off).
    public var refine: Double
    /// Order is combination order. Empty = no selection.
    public var components: [MaskComponent]
    /// Only affects S1.6, never the atlas (§3.2).
    public var adjustments: LocalAdjustments

    /// Decode fallback: a **constant** id, never a fresh UUID, so an id-less document keys the same
    /// in every process.
    public static let fallback = Mask(id: "", name: "Mask 1", isEnabled: true, opacity: 1,
                                      invert: false, feather: 0, refine: 0,
                                      components: [], adjustments: .identity)

    public init(id: String = "m-\(UUID().uuidString)", name: String = "Mask 1",
                isEnabled: Bool = true, opacity: Double = 1.0, invert: Bool = false,
                feather: Double = 0.0, refine: Double = 0.0,
                components: [MaskComponent] = [],
                adjustments: LocalAdjustments = .identity) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.opacity = opacity
        self.invert = invert
        self.feather = feather
        self.refine = refine
        self.components = components
        self.adjustments = adjustments
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = Mask.fallback
        v.id = c.val("id", v.id)
        v.name = c.val("name", v.name)
        v.isEnabled = c.val("isEnabled", v.isEnabled)
        v.opacity = c.val("opacity", v.opacity)
        v.invert = c.val("invert", v.invert)
        v.feather = c.val("feather", v.feather)
        v.refine = c.val("refine", v.refine)
        v.components = c.val("components", v.components)
        v.adjustments = c.val("adjustments", v.adjustments)
        // §2: a shape this build cannot interpret keeps its bytes but must never render a guess.
        if v.components.contains(where: { !$0.shape.isKnownKind }) { v.isEnabled = false }
        self = v
    }

    /// Atlas layer identity: everything that changes the selection, nothing that changes the edit.
    /// `selectionKey(mask) = id|kind|components[op,invert,feather,shape…]|invert|opacity|feather|refine|isEnabled`
    public var selectionKey: String {
        "m=\(id);kind=\(components.first?.shape.kind ?? "-")"
            + ";comp=[\(components.map(\.keyString).joined(separator: "@"))]"
            + ";inv=\(invert ? 1 : 0);op=\(k(opacity));fea=\(k(feather));ref=\(k(refine))"
            + ";en=\(isEnabled ? 1 : 0)"
    }

    /// S1.6 identity: the adjustments plus the enable flag, and **nothing geometric**.
    public var applyKey: String {
        "m=\(id);adj=\(adjustments.keyString);en=\(isEnabled ? 1 : 0)"
    }

    public var isIdentityAdjustment: Bool { !isEnabled || adjustments.isIdentity }
}

// MARK: - document helpers

extension EditModel {
    /// Masks that participate in a render, in atlas order (id ascending — locale-free, so two
    /// processes and the disk cache agree, D6).
    public var activeMasks: [Mask] {
        masks.filter { $0.isEnabled }.sorted { $0.id < $1.id }
    }

    public var hasActiveMasks: Bool { masks.contains { $0.isEnabled } }

    /// `"masks"` material of the atlas key: all enabled masks' selection keys, id sorted.
    public var maskSelectionMaterial: String {
        activeMasks.map(\.selectionKey).joined(separator: "#")
    }

    /// `applyKey` material of the local stage: all enabled masks' adjustment keys, id sorted.
    public var maskApplyMaterial: String {
        activeMasks.map(\.applyKey).joined(separator: "#")
    }

    /// True when at least one **enabled** mask carries a hue or a saturation value — the judgement
    /// 派单 056 makes by value, never by "there is a mask".
    public var hasLocalColor: Bool {
        masks.contains { $0.isEnabled && $0.adjustments.contributesLocalColor }
    }

    /// The `localColor=` material of S3.5: only the masks that actually contribute colour, only the
    /// values that stage consumes. `amount` is in it because it is the lerp weight; a mask that is
    /// disabled or switched to 0/0 leaves the list, which is what makes the key move when the stage
    /// stops existing for the document.
    public var localColorMaterial: String {
        activeMasks.filter { $0.adjustments.contributesLocalColor }
            .map { "m=\($0.id);hue=\(k($0.adjustments.hue));sat=\(k($0.adjustments.saturation))"
                   + ";amt=\(k($0.adjustments.amount))" }
            .joined(separator: "#")
    }
}

// MARK: - raw JSON for forward compatibility

/// Minimal lossless JSON tree. Numbers are kept as `Double` (the only numbers a document contains),
/// objects keep no ordering; `canonicalText` sorts keys so the same document always produces the
/// same key material.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer()
        if s.decodeNil() { self = .null; return }
        if let b = try? s.decode(Bool.self) { self = .bool(b); return }
        if let n = try? s.decode(Double.self) { self = .number(n); return }
        if let t = try? s.decode(String.self) { self = .string(t); return }
        if let a = try? s.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? s.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: s, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: any Encoder) throws {
        var s = encoder.singleValueContainer()
        switch self {
        case .null: try s.encodeNil()
        case .bool(let b): try s.encode(b)
        case .number(let n): try s.encode(n)
        case .string(let t): try s.encode(t)
        case .array(let a): try s.encode(a)
        case .object(let o): try s.encode(o)
        }
    }

    /// Deterministic text: sorted keys, Swift's shortest round-trip number formatting.
    public var canonicalText: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : "\(n)"
        case .string(let t): return "\"\(t.replacingOccurrences(of: "\"", with: "\\\""))\""
        case .array(let a): return "[" + a.map(\.canonicalText).joined(separator: ",") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { "\"\($0)\":" + o[$0]!.canonicalText }.joined(separator: ",") + "}"
        }
    }
}

// MARK: - 005d: canvas-space bounds, tiles and the dependency closure
//
// The patch-recompute geometry, made a value layer so it is testable without a GPU:
//
//     bounds(mask)  = AABB(components) ⊕ featherRadius ⊕ guidedRadius     (canvas pixels)
//     dirtyRect(s)  = ∪ bounds(m ∈ dirty(s))
//     tile          = 128 px (scale < 1) | 256 px (export), 8 px aligned
//     closure(D)    = D ∪ descendants(D)      (Kahn topological order)
//
// The one hard criterion (§3.4, 005d): a tiled pass and a full-frame pass of the *same* document
// must produce the same bytes — not "the same picture". `RenderGraph` therefore keeps the atlas a
// full-frame pass (its neighbourhood operators need a complete input) and tiles only S1.6, which is
// pointwise by construction; `TilePlan.isFullFrame` is what a test asserts against, so a bound that
// is too small shows up as a *missing pixel*, not as a slower frame.

/// A half-open integer rectangle in **canvas** pixels: `[x0, x1) × [y0, y1)`.
///
/// Half-open everywhere so that `union` and tile alignment are exact integer arithmetic and two
/// rectangles that share an edge do not overlap by one row (the classic off-by-one that makes a
/// tiled render differ from a full-frame one only at the seams).
public struct MaskRect: Sendable, Equatable, Hashable {
    public var x0: Int
    public var y0: Int
    public var x1: Int
    public var y1: Int

    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }

    public static let empty = MaskRect(x0: 0, y0: 0, x1: 0, y1: 0)

    public init(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) { self.init(x0: x0, y0: y0, x1: x1, y1: y1) }

    public var isEmpty: Bool { x1 <= x0 || y1 <= y0 }
    public var width: Int { max(0, x1 - x0) }
    public var height: Int { max(0, y1 - y0) }
    public var pixelCount: Int { width * height }
    public var keyString: String { "\(x0),\(y0),\(x1),\(y1)" }

    public func union(_ other: MaskRect) -> MaskRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return MaskRect(x0: min(x0, other.x0), y0: min(y0, other.y0),
                        x1: max(x1, other.x1), y1: max(y1, other.y1))
    }

    public func intersects(_ other: MaskRect) -> Bool {
        !isEmpty && !other.isEmpty && x0 < other.x1 && other.x0 < x1 && y0 < other.y1 && other.y0 < y1
    }

    public func contains(_ other: MaskRect) -> Bool {
        other.isEmpty || (!isEmpty && x0 <= other.x0 && y0 <= other.y0
                          && x1 >= other.x1 && y1 >= other.y1)
    }

    /// Grow by `n` canvas pixels on every side — the halo a neighbourhood operator needs (§3.4).
    public func grown(by n: Int) -> MaskRect {
        guard n != 0 else { return self }
        if isEmpty { return self }
        return MaskRect(x0: x0 - n, y0: y0 - n, x1: x1 + n, y1: y1 + n)
    }

    /// Intersection with the canvas; a rectangle entirely outside it becomes `.empty`.
    public func clamped(to size: ImageSize) -> MaskRect {
        guard !isEmpty else { return .empty }
        let r = MaskRect(x0: max(0, x0), y0: max(0, y0),
                         x1: min(size.width, x1), y1: min(size.height, y1))
        return r.isEmpty ? .empty : r
    }

    /// Outward alignment to a multiple of `a` (step 4 of §3.4: 8 px, so a tile boundary never lands
    /// on a tensor's half-pixel), clipped to the canvas.
    public func aligned(to a: Int, canvas: ImageSize) -> MaskRect {
        guard a > 1, !isEmpty else { return clamped(to: canvas) }
        let ax0 = (x0 / a) * a
        let ay0 = (y0 / a) * a
        let ax1 = ((x1 + a - 1) / a) * a
        let ay1 = ((y1 + a - 1) / a) * a
        return MaskRect(x0: ax0, y0: ay0, x1: ax1, y1: ay1).clamped(to: canvas)
    }

    /// Bounding box of a point set, rounded **outward** so a rounding mistake can only make the
    /// rectangle bigger (the failure mode of a bound that is too large is a slower frame; the
    /// failure mode of one that is too small is a wrong picture).
    public static func aabb(of points: [(x: Double, y: Double)]) -> MaskRect? {
        guard let first = points.first else { return nil }
        var lo = (x: first.x, y: first.y), hi = lo
        for p in points.dropFirst() {
            if !p.x.isFinite || !p.y.isFinite { continue }
            lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y)
            hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y)
        }
        guard lo.x.isFinite, hi.x.isFinite else { return nil }
        return MaskRect(x0: Int(lo.x.rounded(.down)), y0: Int(lo.y.rounded(.down)),
                        x1: Int(hi.x.rounded(.up)), y1: Int(hi.y.rounded(.up)))
    }
}

/// A set of rectangles with an **exact** union area (a y-sweep, not a sum of areas — two overlapping
/// tiles must not be counted twice, or "the tile plan is cheaper" becomes a lie).
public struct RectSet: Sendable, Equatable {
    public private(set) var rects: [MaskRect]

    public init(_ rects: [MaskRect] = []) {
        self.rects = []
        for r in rects where !r.isEmpty { insert(r) }
    }

    public static let empty = RectSet()

    public var isEmpty: Bool { rects.isEmpty }

    /// Union of everything inside, as one rectangle (may cover holes).
    public var bounds: MaskRect { rects.reduce(.empty) { $0.union($1) } }

    /// Exact area of the union, in pixels.
    public var unionPixelCount: Int {
        guard !rects.isEmpty else { return 0 }
        var ys = Set<Int>()
        for r in rects { ys.insert(r.y0); ys.insert(r.y1) }
        let rows = ys.sorted()
        var total = 0
        for i in 0..<(rows.count - 1) {
            let yTop = rows[i], yBottom = rows[i + 1]
            guard yBottom > yTop else { continue }
            var spans: [(Int, Int)] = []
            for r in rects where r.y0 <= yTop && r.y1 >= yBottom {
                spans.append((r.x0, r.x1))
            }
            guard !spans.isEmpty else { continue }
            spans.sort { $0.0 < $1.0 }
            var covered = 0
            var cursor = spans[0].0
            var end = spans[0].1
            for (a, b) in spans.dropFirst() {
                if a > end { covered += end - cursor; cursor = a; end = b }
                else { end = max(end, b) }
            }
            covered += end - cursor
            total += covered * (yBottom - yTop)
        }
        return total
    }

    public mutating func insert(_ r: MaskRect) {
        guard !r.isEmpty else { return }
        // Drop rectangles already covered, and grow one that covers a neighbour: the sweep stays
        // cheap and `unionPixelCount` stays exact either way.
        if rects.contains(where: { $0.contains(r) }) { return }
        rects.removeAll { r.contains($0) }
        rects.append(r)
    }

    public mutating func formUnion(_ other: RectSet) {
        for r in other.rects { insert(r) }
    }

    public func union(_ other: RectSet) -> RectSet {
        var s = self
        s.formUnion(other)
        return s
    }

    public func intersects(_ r: MaskRect) -> Bool { rects.contains { $0.intersects(r) } }

    /// Key material: rectangles sorted so two processes produce the same text (D6).
    public var keyString: String {
        rects.map(\.keyString).sorted().joined(separator: ";")
    }
}

/// What a stage's outputs depend on: nothing but the pixel it writes, or a neighbourhood of it.
///
/// §3.3 item 5: a stage that introduces a neighbourhood operator **must** declare it here, otherwise
/// tiling silently produces a different picture. `halo` is in canvas pixels.
public enum TileDependency: Sendable, Equatable {
    case pointwise
    case neighborhood(radius: Int)

    public var halo: Int {
        switch self {
        case .pointwise: return 0
        case .neighborhood(let r): return max(0, r)
        }
    }

    /// Two operators **in series** on the same pixels (feather then refine ⇒ the halos add).
    public func then(_ other: TileDependency) -> TileDependency {
        let h = halo + other.halo
        return h == 0 ? .pointwise : .neighborhood(radius: h)
    }

    /// Two independent masks over the same canvas: the widest halo wins. Adding them instead would
    /// inflate the declared dependency on every extra mask and make the tile bounds lie.
    public func widest(_ other: TileDependency) -> TileDependency {
        let h = max(halo, other.halo)
        return h == 0 ? .pointwise : .neighborhood(radius: h)
    }

    public var keyString: String {
        switch self {
        case .pointwise: return "pointwise"
        case .neighborhood(let r): return "halo=\(r)"
        }
    }
}

/// The tile lattice of §3.4: 128 px below 1:1, 256 px for export, 8 px alignment.
public struct TileGrid: Sendable, Equatable {
    public var tile: Int
    public var alignment: Int

    public init(tile: Int = 128, alignment: Int = 8) {
        self.tile = max(16, tile)
        self.alignment = max(1, alignment)
    }

    public static func forScale(_ scale: Double) -> TileGrid {
        TileGrid(tile: scale < 1 ? 128 : 256, alignment: 8)
    }

    /// Every tile of the lattice that touches the (already halo-grown) dirty set. Tiles are grown
    /// outward to `alignment` and clipped to the canvas; a tile touched by two dirty rectangles is
    /// dispatched **once**, so `pixelCount` is a real cost and not a doubled one.
    public func tiles(covering dirty: RectSet, canvas: ImageSize) -> [MaskRect] {
        var seen = Set<[Int]>()
        var out: [MaskRect] = []
        for r in dirty.rects {
            let clipped = r.clamped(to: canvas)
            guard !clipped.isEmpty else { continue }
            let tx0 = (clipped.x0 / tile) * tile
            let ty0 = (clipped.y0 / tile) * tile
            var ty = ty0
            while ty < clipped.y1 {
                var tx = tx0
                while tx < clipped.x1 {
                    if seen.insert([tx, ty]).inserted {
                        let t = MaskRect(x0: tx, y0: ty, x1: tx + tile, y1: ty + tile)
                            .aligned(to: alignment, canvas: canvas)
                        if !t.isEmpty { out.append(t) }
                    }
                    tx += tile
                }
                ty += tile
            }
        }
        // Sorted, so the dispatch order (and any trace of it) is the same in every process.
        return out.sorted { ($0.y0, $0.x0) < ($1.y0, $1.x0) }
    }

    public var keyString: String { "tile=\(tile);align=\(alignment)" }
}

/// The plan a stage actually dispatches: the tiles, how many pixels that is, and whether it is
/// indistinguishable from a full-frame pass.
public struct TilePlan: Sendable, Equatable {
    public var tiles: [MaskRect]
    public var pixelCount: Int
    public var canvasPixelCount: Int
    public var dependency: TileDependency
    public var tiled: Bool

    public init(tiles: [MaskRect] = [], pixelCount: Int = 0, canvasPixelCount: Int = 0,
                dependency: TileDependency = .pointwise, tiled: Bool = false) {
        self.tiles = tiles
        self.pixelCount = pixelCount
        self.canvasPixelCount = canvasPixelCount
        self.dependency = dependency
        self.tiled = tiled
    }

    public static func fullFrame(_ canvas: ImageSize, dependency: TileDependency = .pointwise) -> TilePlan {
        TilePlan(tiles: [MaskRect(0, 0, canvas.width, canvas.height)],
                 pixelCount: canvas.pixelCount, canvasPixelCount: canvas.pixelCount,
                 dependency: dependency, tiled: false)
    }

    public var fraction: Double {
        canvasPixelCount > 0 ? Double(pixelCount) / Double(canvasPixelCount) : 1
    }

    public var isFullFrame: Bool { pixelCount >= canvasPixelCount }
}

/// The pixel frame a document's normalised parameters are expressed in: the **upright**
/// (display-oriented) source, i.e. the frame `RenderGraph.sourceSize` reports after ingestion applied
/// the EXIF orientation (Q17, docs/architecture-decisions.md §11.2).
///
/// One function, because this number is where task 028's portrait bug came from. A mask is stored in
/// normalised *source* coordinates and every distance is divided by `min(W, H)`, so the number has to
/// be the size of the picture on screen. The mask UI used to build it from the catalog row's
/// `kCGImagePropertyPixelWidth/PixelHeight`, which are the **stored** dimensions: for EXIF 5…8 those
/// are transposed relative to what the user sees (a 3:2 portrait frame reads 9536×6344 while the
/// picture is 6336×9520). A radial drag then converted its rim with `W / minSide = 1.503` instead of
/// the honest `6336 / 6336 = 1`, and the rendered ellipse came out half again as wide as the one the
/// hand drew — the eye reads that as "the mask is in the wrong place".
///
/// The decoded buffer always wins, because it is the frame the GPU evaluates the mask in and no
/// metadata row may disagree with the pixels. The stored dimensions are the fallback for the window
/// before the photo's first frame has landed, and they are documented as *stored* — a caller that
/// wants them to be upright has to apply `ImageOrientation.uprightSize` itself, which only a decode
/// (or a header read) can licence.
public enum MaskSourceFrame {

    /// The upright source size a document's normalised geometry is measured against.
    ///
    /// - Parameters:
    ///   - ingested: the size the renderer ingested (`RenderGraph.sourceSize`, `LinearImage.uprightSize`).
    ///   - storedWidth/storedHeight: the catalog row's pixel dimensions, *before* orientation. Used
    ///     only when no frame has been ingested yet, or when the row has no dimensions at all.
    public static func size(ingested: ImageSize?, storedWidth: Int?, storedHeight: Int?) -> ImageSize {
        // `ImageSize` floors both edges at 1, so an "ingested" 0×0 cannot exist and needs no guard.
        if let ingested { return ingested }
        return ImageSize(width: storedWidth ?? 1, height: storedHeight ?? 1)
    }
}

/// The forward half of S0's mapping: normalised **source** point → continuous canvas pixel.
///
/// The kernel walks this backwards (`source_uv` in `s1_5_mask_atlas.metal`); the bounds code needs
/// the forward direction, and if the two disagree by a sign a mask's dirty rectangle lands on the
/// wrong side of a rotated frame — invisible on an uncropped, unrotated test and wrong everywhere
/// else. `MaskRotationPixelsTests.testMaskCanvasMappingTurnsPixels` pins them against each other
/// (including *which space* the turn happens in — a bounds map that shears in step with a shearing
/// kernel agrees with it and is worth nothing, which is exactly how the atlas's normalised turn
/// survived 073).
public struct MaskCanvasMapping: Sendable, Equatable {
    public var source: ImageSize
    public var content: ImageSize
    public var canvas: ImageSize
    public var originX: Double
    public var originY: Double
    public var crop: CropRect
    public var cosTheta: Double
    public var sinTheta: Double
    /// `straightenDegrees != 0`: whether this map has a turn in it at all.
    ///
    /// The same condition `RenderGraph` dispatches S0's `s0_geometry_rot` and the atlas's
    /// `s1_5_mask_atlas_rot` on — and here, as there, the θ = 0 path must not contain the
    /// `× frameSize` / `÷ frameSize` round trip, or a merely cropped document's bounds would land an
    /// ulp (and then a whole tile) away from the ones every recorded dirty rectangle came from.
    public var rotates: Bool
    public var flipH: Bool
    public var flipV: Bool

    public init(geometry: GeometryGroup, source: ImageSize, content: ImageSize,
                canvas: ImageSize, origin: (x: Double, y: Double)) {
        let crop = geometry.renderCrop(source: source)
        self.source = source
        self.content = content
        self.canvas = canvas
        self.originX = origin.x
        self.originY = origin.y
        self.crop = crop
        let t = geometry.straightenDegrees * .pi / 180
        self.cosTheta = cos(t)
        self.sinTheta = sin(t)
        self.rotates = geometry.straightenDegrees != 0
        self.flipH = geometry.flipHorizontal
        self.flipV = geometry.flipVertical
    }

    /// Continuous canvas pixel centre-space position of a normalised source point. Points outside
    /// the crop map outside the content rectangle (they are clipped later, not clamped — clamping
    /// here would fold a mask that lives entirely outside the crop onto the visible frame).
    public func canvasPoint(_ p: NormalizedPoint) -> (x: Double, y: Double) {
        // source → position inside the crop (0…1), the inverse of `src = crop.xy + r·crop.zw`.
        let rx = (p.x - crop.left) / max(crop.width, 1e-9) - 0.5
        let ry = (p.y - crop.top) / max(crop.height, 1e-9) - 0.5
        // Un-rotate (`s0_geometry` applies `R(θ)`, so the forward direction applies `R(−θ)`).
        //
        // In **pixels**, about the frame's centre — the same turn `s0_geometry` and
        // `s1_5_mask_atlas` compile from `frame_turn.metal`. Turning `(rx, ry)` directly is
        // `rot ∘ aniso(W/H)`: a rotation of normalised coordinates is followed by the non-uniform
        // scale back to pixels, which is a *shear* (073's bug, and until 派单 080 the mapping the
        // atlas still used, so this map was shearing in step with it and agreeing with the wrong
        // answer). A bounds test that agrees with a faulty kernel is worth nothing, so this is
        // spelled the way the shader is.
        let ox: Double, oy: Double
        if rotates {
            let fx = Double(content.width), fy = Double(content.height)
            let px = rx * fx, py = ry * fy
            ox = (px * cosTheta + py * sinTheta) / fx
            oy = (-px * sinTheta + py * cosTheta) / fy
        } else {
            ox = rx * cosTheta + ry * sinTheta
            oy = -rx * sinTheta + ry * cosTheta
        }
        var u = ox + 0.5
        var v = oy + 0.5
        if flipH { u = 1 - u }
        if flipV { v = 1 - v }
        return (u * Double(content.width) + originX - 0.5,
                v * Double(content.height) + originY - 0.5)
    }
}

/// §4.6 / §2 — the two radii, as one place. Host and kernel read the same numbers because the same
/// function produced the descriptor (`MaskDescU.misc`).
public enum MaskRadius {
    /// A full-strength feather is **10 % of the short edge**. The document's field is documented as
    /// 0…0.1 (a fraction of the short edge); the UI range is 0…1, so `feather = 1` is the whole
    /// documented span and `feather = 0.1` is the usual small softening. Normalising to the *content*
    /// short edge (canvas pixels) keeps one parameter identical at thumbnail, fit, 1:1 and export
    /// scale — the same rule as every other distance in §4.
    public static func featherPixels(_ feather: Double, content: ImageSize) -> Double {
        min(max(feather, 0), 1) * 0.1 * Double(min(content.width, content.height))
    }

    /// §4.6: `kernelDiameter = odd(clamp(2·round(max(W,H)/30) + 1, 3, 65))` — radius ≈ max/30,
    /// clamped to the 3…65 window MPS/box implementations are comfortable with.
    public static func guidedKernelDiameter(_ content: ImageSize) -> Int {
        let raw = 2 * Int((Double(max(content.width, content.height)) / 30).rounded()) + 1
        let clamped = min(max(raw, 3), 65)
        return clamped % 2 == 1 ? clamped : clamped + 1
    }

    /// Kernel **radius** in canvas pixels (0 when `refine == 0`, i.e. the pass does not exist).
    public static func guidedRadiusPixels(_ refine: Double, content: ImageSize) -> Double {
        guard refine > 0 else { return 0 }
        return Double((guidedKernelDiameter(content) - 1) / 2)
    }

    /// §4.6: `epsilon = 0.01 · 10^(−refine)` — 0.01 at "barely on", 1e−3 at full strength (the
    /// task text's 1e−3 endpoint; its `10^(−2·refine)` would give 1e−4, i.e. ten times sharper than
    /// the number it prints next to it).
    public static func guidedEpsilon(_ refine: Double) -> Double {
        0.01 * pow(10, -min(max(refine, 0), 1))
    }

    /// Both halos, in canvas pixels: what `bounds` must be grown by (§3.4 step 1).
    public static func haloPixels(of mask: Mask, content: ImageSize) -> Int {
        let f = featherPixels(mask.feather, content: content)
        let g = guidedRadiusPixels(mask.refine, content: content)
        return Int((f + g).rounded(.up))
    }

    /// The dependency the atlas declares for one mask: a box blur of radius r then a guided filter of
    /// radius g, i.e. `neighborhood(r + g)`. S1.6 reads that result at a single pixel and is
    /// `.pointwise`.
    public static func atlasDependency(of mask: Mask, content: ImageSize) -> TileDependency {
        let halo = haloPixels(of: mask, content: content)
        return halo > 0 ? .neighborhood(radius: halo) : .pointwise
    }
}

/// Canvas-space bounds of one mask, including the halo its neighbourhood operators spread (§3.4).
public enum MaskBounds {
    /// The shape's own extent in **normalised source** coordinates, before crop/rotate. `nil` = the
    /// shape cannot contribute coverage in this build (semantic matte, unknown kind, no strokes).
    ///
    /// Content-dependent predicates (colour range, luminance range) return the whole frame: their
    /// extent is a property of the picture, not of the parameters, and a bound that guesses would be
    /// a bound that is sometimes too small.
    public static func sourceExtent(of component: MaskComponent, source: ImageSize) -> MaskRect? {
        let w = Double(source.width), h = Double(source.height)
        let minSide = min(w, h)
        switch component.shape {
        case .linearGradient(let g):
            // `alpha > 0` above the line where `t' = lo`. `t' = t^(log ½ / log m)`, so
            // `t_cut = lo^(log m / log ½)` — the exact inverse of the kernel's midpoint remap.
            let f = min(max(component.feather, 0), 1)
            let lo = 0.5 - 0.5 * f
            let m = min(max(g.midpoint, 0.02), 0.98)
            let exponent = log(0.5) / log(m)
            let tCut = lo <= 0 ? 0 : pow(lo, 1 / exponent)
            let quad = [(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]
            let ax = g.start.x * w, ay = g.start.y * h
            let dx = g.end.x * w - ax, dy = g.end.y * h - ay
            let denom = max(dx * dx + dy * dy, 1e-12)
            // Sutherland–Hodgman against the single half-plane `t ≥ t_cut`.
            var poly: [(x: Double, y: Double)] = []
            for i in 0..<quad.count {
                let a = quad[i], b = quad[(i + 1) % quad.count]
                let ta = ((a.0 - ax) * dx + (a.1 - ay) * dy) / denom
                let tb = ((b.0 - ax) * dx + (b.1 - ay) * dy) / denom
                let inA = ta >= tCut, inB = tb >= tCut
                if inA { poly.append(a) }
                if inA != inB {
                    let s = (tCut - ta) / (tb - ta)
                    poly.append((a.0 + (b.0 - a.0) * s, a.1 + (b.1 - a.1) * s))
                }
            }
            return MaskRect.aabb(of: poly)
        case .radialGradient(let g):
            // Radii are short-edge units, i.e. already pixels: `rx · minSide`.
            let rx = max(abs(g.radius.x), 0) * minSide
            let ry = max(abs(g.radius.y), 0) * minSide
            let t = g.angle * .pi / 180
            let cs = abs(cos(t)), sn = abs(sin(t))
            // Support function of a rotated ellipse: exact half-extents, not the circle's radius.
            let hx = (rx * cs * rx * cs + ry * sn * ry * sn).squareRoot()
            let hy = (rx * sn * rx * sn + ry * cs * ry * cs).squareRoot()
            // The kernel's rim sits at r = 1 and coverage is zero beyond it (feather narrows the
            // window *inside* the rim), so the rim is the bound — no growth by the feather.
            let cx = g.center.x * w, cy = g.center.y * h
            return MaskRect.aabb(of: [(cx - hx, cy - hy), (cx + hx, cy + hy)])
        case .brush(let b):
            var box: MaskRect = .empty
            for s in b.strokes {
                let n = s.points.count / 2
                guard n > 0 else { continue }
                let r = min(max(s.resolvedRadius(fallbackSize: b.size), 0), 1) * minSide
                var lo = (x: Double.infinity, y: Double.infinity)
                var hi = (x: -Double.infinity, y: -Double.infinity)
                for i in 0..<n {
                    let x = Double(s.points[i * 2]) * w, y = Double(s.points[i * 2 + 1]) * h
                    lo.x = min(lo.x, x); lo.y = min(lo.y, y)
                    hi.x = max(hi.x, x); hi.y = max(hi.y, y)
                }
                // The radius is a short-edge length, so it is the same pixel distance on both axes.
                box = box.union(MaskRect.aabb(of: [(lo.x - r, lo.y - r), (hi.x + r, hi.y + r)]) ?? .empty)
            }
            return box.isEmpty ? nil : box
        case .colorRange, .luminanceRange:
            // Content-dependent: the extent is a property of the picture, not of the parameters, so
            // the honest bound is the frame. A guess here would be a bound that is sometimes small.
            return MaskRect(0, 0, source.width, source.height)
        case .semantic:
            // 005e: the matte comes from the picture too, and its extent is whatever the OS model
            // found — so it gets the same honest answer as the content-dependent predicates. (A
            // document whose matte is unavailable therefore declares the whole frame as dirty; the
            // tile plan then falls back to a full pass, which is a cost, never a wrong pixel.)
            return MaskRect(0, 0, source.width, source.height)
        case .unsupported:
            return nil   // no coverage: a kind this build cannot interpret
        }
    }

    /// The canvas rectangle a mask can touch, already grown by `featherRadius + guidedRadius`.
    public static func canvasRect(for mask: Mask, mapping: MaskCanvasMapping) -> MaskRect? {
        guard mask.isEnabled, !mask.components.isEmpty else { return nil }
        let halo = MaskRadius.haloPixels(of: mask, content: mapping.content)
        let w = Double(mapping.source.width), h = Double(mapping.source.height)

        var dirty = RectSet()
        for c in mask.components {
            guard let extent = sourceExtent(of: c, source: mapping.source), !extent.isEmpty else { continue }
            // Source-space rectangle → its four mapped corners → AABB in canvas pixels. The image of
            // a rectangle under S0's affine map is a parallelogram, and the AABB of a parallelogram
            // is the AABB of its vertices: conservative by construction, exact when unrotated.
            let corners = [(extent.x0, extent.y0), (extent.x1, extent.y0),
                           (extent.x1, extent.y1), (extent.x0, extent.y1)].map { p in
                mapping.canvasPoint(NormalizedPoint(Double(p.0) / w, Double(p.1) / h))
            }
            guard var box = MaskRect.aabb(of: corners) else { continue }
            box = box.grown(by: halo).clamped(to: mapping.canvas)
            guard !box.isEmpty else { continue }
            dirty.insert(box)
        }
        guard !dirty.isEmpty else { return nil }
        return dirty.bounds
    }

    /// `∪ bounds(m)` for a set of masks — the dirty rectangle of a stage (§3.4 step 2).
    public static func dirtySet(_ masks: [Mask], mapping: MaskCanvasMapping) -> RectSet {
        var set = RectSet()
        for m in masks {
            if let r = canvasRect(for: m, mapping: mapping) { set.insert(r) }
        }
        return set
    }
}

/// §3.4 step 4 — `producer → consumer` edges and the closure that makes a patch recomputation
/// correct once masks can reference each other (linked masks, spots whose source lies inside another
/// mask's target).
///
/// M4 ships no user-reachable edges, which is exactly why this is a value type with a synthetic test
/// rather than a comment: the day a producer arrives, "dirty A" must mean "recompute A, then B, then
/// C" and a cycle must be reported at **decode** time, not thrown mid-render.
public struct MaskGraph: Sendable, Equatable {
    public struct Edge: Sendable, Equatable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    /// Ids in atlas order.
    public var ids: [String]
    public var edges: [Edge]

    public init(ids: [String], edges: [Edge] = []) {
        self.ids = ids
        self.edges = edges
    }

    public func successors(of id: String) -> [String] {
        edges.filter { $0.from == id }.map(\.to)
    }

    public func predecessors(of id: String) -> [String] {
        edges.filter { $0.to == id }.map(\.from)
    }

    /// `D ∪ descendants(D)`, restricted to known ids.
    public func closure(of dirty: Set<String>) -> Set<String> {
        var seen = dirty.intersection(ids)
        var queue = Array(seen)
        while let id = queue.popLast() {
            for next in successors(of: id) where !seen.contains(next) {
                seen.insert(next)
                queue.append(next)
            }
        }
        return seen
    }

    /// Kahn's algorithm, ties broken by atlas order so the execution order is deterministic.
    /// `nil` when the graph has a cycle (the caller reports `mask.cycle` and disables the mask).
    public func topologicalOrder() -> [String]? {
        var indegree = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        for e in edges where indegree[e.to] != nil && indegree[e.from] != nil {
            indegree[e.to, default: 0] += 1
        }
        var ready = ids.filter { (indegree[$0] ?? 0) == 0 }
        var order: [String] = []
        while !ready.isEmpty {
            let id = ready.removeFirst()
            order.append(id)
            for next in successors(of: id) {
                guard var d = indegree[next] else { continue }
                d -= 1
                indegree[next] = d
                if d == 0 { ready.append(next) }
            }
            // Atlas order, not insertion order.
            ready.sort { (ids.firstIndex(of: $0) ?? 0) < (ids.firstIndex(of: $1) ?? 0) }
        }
        return order.count == ids.count ? order : nil
    }

    /// The masks a set of dirty ids actually forces to re-run, in execution order. Empty when the
    /// graph has a cycle: a cyclic document must be refused, not half-rendered.
    public func executionOrder(for dirty: Set<String>) -> [String] {
        guard let order = topologicalOrder() else { return [] }
        let set = closure(of: dirty)
        return order.filter { set.contains($0) }
    }

    /// One cycle (as a path) when there is one, for the decode-time error message.
    public var cycle: [String]? {
        var colour: [String: Int] = [:]   // 1 = on stack, 2 = done
        var stack: [String] = []
        func dfs(_ id: String) -> [String]? {
            colour[id] = 1
            stack.append(id)
            for next in successors(of: id) where ids.contains(next) {
                if colour[next] == 1 {
                    if let i = stack.firstIndex(of: next) { return Array(stack[i...]) + [next] }
                    return [next, next]
                }
                if colour[next] == nil, let found = dfs(next) { return found }
            }
            colour[id] = 2
            _ = stack.popLast()
            return nil
        }
        for id in ids where colour[id] == nil {
            if let c = dfs(id) { return c }
        }
        return nil
    }

    /// The graph a document implies: one node per enabled mask, no edges in M4.
    public static func from(_ masks: [Mask]) -> MaskGraph {
        MaskGraph(ids: masks.filter(\.isEnabled).sorted { $0.id < $1.id }.map(\.id))
    }
}
