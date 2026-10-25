import Foundation

// MARK: - M4 local masks: the value layer
//
// Masks are **first-class values** (docs/architecture-decisions.md D11): everything the renderer
// needs is a parameter, nothing is a bitmap. Coordinates are normalised to the **uncropped source
// image** and distances are divided by `min(W, H)`, so one document produces the same shape at
// thumbnail, fit, 1:1 and export scale — that is the precondition for "store parameters, not pixels"
// (docs/tasks/005-masks.md §2/§4).
//
// Field defaults are explicit and every decoder falls back to them (D9): a missing key never becomes
// zero and never fails the document.

// MARK: - combination

/// How a component joins the running selection. The first component's `op` is ignored.
public enum CombineOp: String, Codable, Sendable, CaseIterable {
    /// Union: `max(acc, a)`. The same "max is a union, joints do not double-expose" rule as the
    /// brush accumulation blend (docs/tasks/005-masks.md §4.1).
    case add
    /// `acc · (1 − a)` — the erase blend of §4.1 applied to a whole component.
    case subtract
    /// `acc · a` — the product rule ART uses for stacked masks (§4.6).
    case intersect
}

// MARK: - local adjustments

/// The eleven local sliders plus `amount`. Parameter-only; applied in S1.6, **never** in S1.5, so a
/// mask's atlas layer does not depend on its own adjustments (§3.3 item 4).
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

/// One brush stroke: a flat polyline walked as a capsule chain (§4.1). Present in the schema from
/// day one so documents need no migration when the brush lands; **not rendered by the 005b pass**
/// (see `MaskShape.isRenderableNow`).
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

    public static let `default` = Stroke()

    public init(points: [Float] = [], pressure: [Float] = [], radius: Double = 0.06,
                feather: Double = 0.5, flow: Double = 1, erase: Bool = false) {
        self.points = points
        self.pressure = pressure
        self.radius = radius
        self.feather = feather
        self.flow = flow
        self.erase = erase
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
        self = v
    }

    public var keyString: String {
        // 5 decimals is the 1e-5 coordinate quantisation of §2 (~0.6 px at 60 MP).
        let p = points.map { k(Double($0)) }.joined(separator: ",")
        let pr = pressure.isEmpty ? "" : pressure.map { k(Double($0)) }.joined(separator: ",")
        return "st(r=\(k(radius));f=\(k(feather));fl=\(k(flow));e=\(erase ? 1 : 0);p=[\(p)];pr=[\(pr)])"
    }
}

public struct BrushShape: Sendable, Equatable, Codable {
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

/// §4.4 — up to eight sRGB sample colours, nearest-colour distance in OKLab. Schema only for now.
public struct ColorRangeShape: Sendable, Equatable, Codable {
    public static let maxSamples = 8
    /// sRGB 0…1 triples.
    public var samples: [[Double]]
    public var tolerance: Double
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

    public var keyString: String {
        let s = samples.map { $0.map { k($0) }.joined(separator: ",") }.joined(separator: ";")
        return "colour(n=\(samples.count);s=[\(s)];tol=\(k(tolerance));smo=\(k(smoothness)))"
    }
}

/// §4.5 — OKLab L with two-sided feather. Schema only for now.
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

    public var keyString: String {
        "luma(lo=\(k(low));hi=\(k(high));loF=\(k(lowFeather));hiF=\(k(highFeather)))"
    }
}

public enum SemanticKind: String, Codable, Sendable, CaseIterable {
    case sky, foreground, person, skin, hair
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

    /// Shapes this build can actually evaluate. The other kinds decode, round-trip and key
    /// correctly but contribute **zero coverage** until their pass lands (005c–e); the renderer is
    /// explicit about that instead of pretending a brush is a gradient.
    public var isRenderableNow: Bool {
        switch self {
        case .linearGradient, .radialGradient: return true
        default: return false
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
