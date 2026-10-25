import Foundation

// MARK: - Document model

/// A document's complete develop settings: **one** `Codable` value with a document-level
/// `schemaVersion` and an explicit default for every field (docs/architecture-decisions.md D9).
///
/// Groups follow Lightroom's panel split (Light / Curve / Color / Detail / Effects) so a future
/// XMP `crs:` mapping is mechanical. A missing key in an older document decodes to its default —
/// never to zero, never to a decode failure.
public struct EditModel: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1
    /// Per-document processing version. Behaviour changes bump this, and old documents keep their
    /// old rendering (darktable's snapshot semantics, not RawTherapee's global version bump).
    public static let currentProcessVersion = 1

    public var schemaVersion: Int
    public var processVersion: Int
    public var geometry: GeometryGroup
    public var light: LightGroup
    public var curve: CurveGroup
    public var color: ColorGroup
    public var detail: DetailGroup
    public var effects: EffectsGroup
    /// Reserved for M4. Present in the schema from day one, empty and **not rendered** in M1.
    public var masks: [Mask]

    public init(schemaVersion: Int = EditModel.currentSchemaVersion,
                processVersion: Int = EditModel.currentProcessVersion,
                geometry: GeometryGroup = .identity,
                light: LightGroup = .identity,
                curve: CurveGroup = .identity,
                color: ColorGroup = .identity,
                detail: DetailGroup = .identity,
                effects: EffectsGroup = .identity,
                masks: [Mask] = []) {
        self.schemaVersion = schemaVersion
        self.processVersion = processVersion
        self.geometry = geometry
        self.light = light
        self.curve = curve
        self.color = color
        self.detail = detail
        self.effects = effects
        self.masks = masks
    }

    /// The all-defaults document: renders as "decode → display encode", nothing else.
    public static let neutral = EditModel()

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = EditModel.neutral
        v.schemaVersion = c.val("schemaVersion", v.schemaVersion)
        v.processVersion = c.val("processVersion", v.processVersion)
        v.geometry = c.val("geometry", v.geometry)
        v.light = c.val("light", v.light)
        v.curve = c.val("curve", v.curve)
        v.color = c.val("color", v.color)
        v.detail = c.val("detail", v.detail)
        v.effects = c.val("effects", v.effects)
        v.masks = c.val("masks", v.masks)
        self = v
    }

    public static func load(from url: URL) throws -> EditModel {
        try JSONDecoder().decode(EditModel.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }

    // MARK: dirty tracking (group level, never per parameter — D10)

    /// Which stages a change between two documents invalidates directly.
    ///
    /// Downstream invalidation is *not* listed here: the cache key chain does that, because a
    /// changed `geoKey` changes every key after it. This is the group-level dirty set a UI uses to
    /// decide what needs to be redrawn, matching `Set<Stage>` in the architecture notes.
    public func changedStages(from old: EditModel) -> Set<RenderStage> {
        if processVersion != old.processVersion || schemaVersion != old.schemaVersion {
            return Set(RenderStage.allCases)
        }
        var s: Set<RenderStage> = []
        if geometry != old.geometry { s.insert(.geometry) }
        if light != old.light {
            // Lightroom's Light panel straddles S1 (exposure, WB, highlight recovery) and
            // S2 (contrast, highlights, shadows, whites, blacks).
            if light.exposure != old.light.exposure
                || light.temperature != old.light.temperature
                || light.tint != old.light.tint
                || light.highlightRecovery != old.light.highlightRecovery {
                s.insert(.sceneLinear)
            }
            if light.contrast != old.light.contrast
                || light.highlights != old.light.highlights
                || light.shadows != old.light.shadows
                || light.whites != old.light.whites
                || light.blacks != old.light.blacks {
                s.insert(.toneMap)
            }
        }
        if curve != old.curve { s.insert(.curve) }
        if color != old.color { s.insert(.color) }
        if effects != old.effects { s.insert(.vignette) }
        // `detail` (sharpening / noise reduction) is stored but not rendered by the M1 graph:
        // those two controls will be mapped onto CIRAWFilter in the decoder, not onto a kernel.
        // `masks` is reserved for M4 and also renders nothing yet.
        return s
    }

    /// Canonical text for the parameters a given stage consumes. Fed into the cache-key chain;
    /// must stay stable and order-independent across processes (no dictionary iteration).
    public func keyMaterial(_ stage: RenderStage) -> String {
        switch stage {
        case .geometry:
            return "pv=\(processVersion);crop=\(geometry.crop.keyString)"
                + ";rot=\(k(geometry.rotationDegrees))"
                + ";flip=\(geometry.flipHorizontal ? 1 : 0)\(geometry.flipVertical ? 1 : 0)"

        case .sceneLinear:
            return "ev=\(k(light.exposure));temp=\(k(light.temperature));tint=\(k(light.tint))"
                + ";hlr=\(k(light.highlightRecovery))"

        case .toneMap:
            return "con=\(k(light.contrast));hi=\(k(light.highlights));sh=\(k(light.shadows))"
                + ";wh=\(k(light.whites));bl=\(k(light.blacks))"

        case .curve:
            return curve.keyString

        case .color:
            return color.keyString

        case .vignette:
            return effects.keyString

        case .display:
            return "primaries=\(displayKeyPrimaries)"
        }
    }

    /// Display primaries are an output property, not a develop setting; the graph overrides this.
    private var displayKeyPrimaries: String { "n/a" }
}

// MARK: - Groups

/// S0 — geometry: crop, straighten, flips.
public struct GeometryGroup: Sendable, Equatable, Codable {
    public var crop: NormalizedRect
    /// Straighten angle in degrees, positive = clockwise. Applied *inside* the crop rect (the crop
    /// stays the output frame, so over-rotating reveals clamped edges rather than growing the canvas).
    public var rotationDegrees: Double
    public var flipHorizontal: Bool
    public var flipVertical: Bool

    public static let identity = GeometryGroup(crop: .full, rotationDegrees: 0,
                                               flipHorizontal: false, flipVertical: false)

    public init(crop: NormalizedRect = .full,
                rotationDegrees: Double = 0,
                flipHorizontal: Bool = false,
                flipVertical: Bool = false) {
        self.crop = crop
        self.rotationDegrees = rotationDegrees
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = GeometryGroup.identity
        v.crop = c.val("crop", v.crop)
        v.rotationDegrees = c.val("rotationDegrees", v.rotationDegrees)
        v.flipHorizontal = c.val("flipHorizontal", v.flipHorizontal)
        v.flipVertical = c.val("flipVertical", v.flipVertical)
        self = v
    }
}

/// Crop rect in normalized source coordinates (0…1, origin top-left).
public struct NormalizedRect: Sendable, Equatable, Codable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func clamped() -> NormalizedRect {
        let w = min(max(width, 0.001), 1)
        let h = min(max(height, 0.001), 1)
        let cx = min(max(x, 0), 1 - w)
        let cy = min(max(y, 0), 1 - h)
        return NormalizedRect(x: cx, y: cy, width: w, height: h)
    }

    public var keyString: String {
        String(format: "%.5f,%.5f,%.5f,%.5f", x, y, width, height)
    }
}

/// Lightroom's Light panel. Splits across S1 (scene linear) and S2 (tone map).
public struct LightGroup: Sendable, Equatable, Codable {
    /// Stops of gain applied in S1. Never a re-decode: one decode at 0 EV, then arithmetic.
    public var exposure: Double          // -5…+5,  default 0
    public var contrast: Double          // -100…100, default 0
    public var highlights: Double        // -100…100, default 0
    public var shadows: Double           // -100…100, default 0
    public var whites: Double            // -100…100, default 0
    public var blacks: Double            // -100…100, default 0
    /// Relative white balance in kelvin. 6500 = the decode's own neutral, i.e. no change.
    public var temperature: Double       // 2000…12000, default 6500
    public var tint: Double              // -150…150, default 0 (positive = magenta)
    /// Soft shoulder for values above ~0.8; 0 = untouched, 1 = asymptote at 1.0.
    public var highlightRecovery: Double // 0…1, default 0

    public static let identity = LightGroup()

    public init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0,
                shadows: Double = 0, whites: Double = 0, blacks: Double = 0,
                temperature: Double = 6500, tint: Double = 0, highlightRecovery: Double = 0) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.temperature = temperature
        self.tint = tint
        self.highlightRecovery = highlightRecovery
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = LightGroup.identity
        v.exposure = c.val("exposure", v.exposure)
        v.contrast = c.val("contrast", v.contrast)
        v.highlights = c.val("highlights", v.highlights)
        v.shadows = c.val("shadows", v.shadows)
        v.whites = c.val("whites", v.whites)
        v.blacks = c.val("blacks", v.blacks)
        v.temperature = c.val("temperature", v.temperature)
        v.tint = c.val("tint", v.tint)
        v.highlightRecovery = c.val("highlightRecovery", v.highlightRecovery)
        self = v
    }

    public var isIdentity: Bool { self == LightGroup.identity }

    /// S1 exposure gain. 1.0 at 0 EV.
    public var exposureGain: Float { Float(pow(2.0, exposure)) }

    /// S1 white-balance gains, normalized so that 6500 K / tint 0 is exactly (1, 1, 1).
    ///
    /// M1 uses a Planckian-locus approximation (Tanner Helland's fit, 1000–15000 K) divided by the
    /// same fit evaluated at 6500 K. It is monotone, deterministic and good enough to prove the
    /// gain path end-to-end; a Bradford chromatic adaptation from the file's as-shot WB replaces it
    /// when the decoder path grows real WB metadata (M2).
    public var whiteBalanceGains: (r: Float, g: Float, b: Float) {
        let reference = Self.planckianRGB(6500)
        let current = Self.planckianRGB(min(max(temperature, 2000), 12000))
        var r = reference.0 / max(current.0, 1e-4)
        var g = reference.1 / max(current.1, 1e-4)
        var b = reference.2 / max(current.2, 1e-4)
        let norm = max(g, 1e-4)
        r /= norm; g /= norm; b /= norm
        // Tint: positive = magenta, i.e. pull green down and hand the difference to R and B.
        let tintScale = 1 + min(max(tint, -150), 150) / 150 * 0.5
        g /= tintScale
        let comp = tintScale.squareRoot()
        r *= comp; b *= comp
        return (Float(r), Float(g), Float(b))
    }

    private static func planckianRGB(_ kelvin: Double) -> (Double, Double, Double) {
        let t = min(max(kelvin, 1000), 15000) / 100
        var r: Double, g: Double, b: Double
        if t <= 66 {
            r = 255
            g = 99.4708025861 * log(t) - 161.1195681661
            b = t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
        } else {
            r = 329.698727446 * pow(t - 60, -0.1332047592)
            g = 288.1221695283 * pow(t - 60, -0.0755148492)
            b = 255
        }
        func clamp(_ v: Double) -> Double { min(max(v, 1), 255) }
        return (clamp(r), clamp(g), clamp(b))
    }
}

/// Lightroom's tone curve. Four monotone-cubic LUTs: composite RGB plus per-channel.
public struct CurveGroup: Sendable, Equatable, Codable {
    public var rgb: [CurvePoint]
    public var red: [CurvePoint]
    public var green: [CurvePoint]
    public var blue: [CurvePoint]

    public static let identity = CurveGroup()

    public init(rgb: [CurvePoint] = CurvePoint.linear,
                red: [CurvePoint] = CurvePoint.linear,
                green: [CurvePoint] = CurvePoint.linear,
                blue: [CurvePoint] = CurvePoint.linear) {
        self.rgb = rgb
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = CurveGroup.identity
        v.rgb = c.val("rgb", v.rgb)
        v.red = c.val("red", v.red)
        v.green = c.val("green", v.green)
        v.blue = c.val("blue", v.blue)
        self = v
    }

    public var isIdentity: Bool {
        self.rgb == CurvePoint.linear && self.red == CurvePoint.linear
            && self.green == CurvePoint.linear && self.blue == CurvePoint.linear
    }

    public var keyString: String {
        func one(_ p: [CurvePoint]) -> String { p.map(\.keyString).joined(separator: ";") }
        return "rgb=\(one(rgb))|r=\(one(red))|g=\(one(green))|b=\(one(blue))"
    }
}

public struct CurvePoint: Sendable, Equatable, Codable, Hashable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public static let linear: [CurvePoint] = [CurvePoint(0, 0), CurvePoint(1, 1)]

    public var keyString: String { String(format: "%.4f,%.4f", x, y) }
}

/// Lightroom's Color panel: global saturation, vibrance, and the eight HSL bands.
public struct ColorGroup: Sendable, Equatable, Codable {
    public var vibrance: Double      // -100…100, default 0
    public var saturation: Double    // -100…100, default 0
    /// Exactly eight bands, in Lightroom order: red, orange, yellow, green, aqua, blue, purple, magenta.
    public var bands: [HSLBand]

    public static let bandCount = 8

    public static let identityBands: [HSLBand] = Array(repeating: HSLBand(), count: bandCount)

    public static let identity = ColorGroup()

    public init(vibrance: Double = 0, saturation: Double = 0,
                bands: [HSLBand] = ColorGroup.identityBands) {
        self.vibrance = vibrance
        self.saturation = saturation
        self.bands = ColorGroup.normalize(bands)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = ColorGroup.identity
        v.vibrance = c.val("vibrance", v.vibrance)
        v.saturation = c.val("saturation", v.saturation)
        v.bands = ColorGroup.normalize(c.val("bands", v.bands))
        self = v
    }

    /// Tolerate hand-written or future documents: always eight bands, missing ones identity.
    static func normalize(_ bands: [HSLBand]) -> [HSLBand] {
        var out = Array(bands.prefix(bandCount))
        while out.count < bandCount { out.append(HSLBand()) }
        return out
    }

    public var isIdentity: Bool {
        vibrance == 0 && saturation == 0 && bands.allSatisfy { $0.isIdentity }
    }

    public var keyString: String {
        let b = bands.map(\.keyString).joined(separator: ";")
        return "vib=\(k(vibrance));sat=\(k(saturation));bands=\(b)"
    }
}

public struct HSLBand: Sendable, Equatable, Codable, Hashable {
    public var hue: Double         // -100…100 → ±30°
    public var saturation: Double  // -100…100
    public var luminance: Double   // -100…100

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    public var isIdentity: Bool { hue == 0 && saturation == 0 && luminance == 0 }
    public var keyString: String { "\(k(hue)),\(k(saturation)),\(k(luminance))" }
}

/// Stored, not rendered: sharpening and noise reduction belong on `CIRAWFilter`
/// (`sharpnessAmount`, `luminanceNoiseReductionAmount`, …), which is a decoder-path change.
public struct DetailGroup: Sendable, Equatable, Codable {
    public var sharpening: Double          // 0…150, default 0
    public var sharpeningRadius: Double    // 0.5…3, default 1.0
    public var noiseLuminance: Double      // 0…100, default 0
    public var noiseColor: Double          // 0…100, default 0
    public var lensCorrections: Bool       // default false

    public static let identity = DetailGroup()

    public init(sharpening: Double = 0, sharpeningRadius: Double = 1.0,
                noiseLuminance: Double = 0, noiseColor: Double = 0,
                lensCorrections: Bool = false) {
        self.sharpening = sharpening
        self.sharpeningRadius = sharpeningRadius
        self.noiseLuminance = noiseLuminance
        self.noiseColor = noiseColor
        self.lensCorrections = lensCorrections
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = DetailGroup.identity
        v.sharpening = c.val("sharpening", v.sharpening)
        v.sharpeningRadius = c.val("sharpeningRadius", v.sharpeningRadius)
        v.noiseLuminance = c.val("noiseLuminance", v.noiseLuminance)
        v.noiseColor = c.val("noiseColor", v.noiseColor)
        v.lensCorrections = c.val("lensCorrections", v.lensCorrections)
        self = v
    }
}

/// Lightroom's Effects panel. Vignette renders in S3; grain is stored for later.
public struct EffectsGroup: Sendable, Equatable, Codable {
    public var vignetteAmount: Double      // -100…100, default 0 (negative = darker corners)
    public var vignetteMidpoint: Double    // 0…100, default 50
    public var vignetteFeather: Double     // 0…100, default 50
    public var vignetteRoundness: Double   // -100…100, default 0 (square → circular)
    public var grain: Double               // 0…100, default 0 — stored, not rendered in M1

    public static let identity = EffectsGroup()

    public init(vignetteAmount: Double = 0, vignetteMidpoint: Double = 50,
                vignetteFeather: Double = 50, vignetteRoundness: Double = 0,
                grain: Double = 0) {
        self.vignetteAmount = vignetteAmount
        self.vignetteMidpoint = vignetteMidpoint
        self.vignetteFeather = vignetteFeather
        self.vignetteRoundness = vignetteRoundness
        self.grain = grain
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = EffectsGroup.identity
        v.vignetteAmount = c.val("vignetteAmount", v.vignetteAmount)
        v.vignetteMidpoint = c.val("vignetteMidpoint", v.vignetteMidpoint)
        v.vignetteFeather = c.val("vignetteFeather", v.vignetteFeather)
        v.vignetteRoundness = c.val("vignetteRoundness", v.vignetteRoundness)
        v.grain = c.val("grain", v.grain)
        self = v
    }

    public var keyString: String {
        "vig=\(k(vignetteAmount));mid=\(k(vignetteMidpoint));fea=\(k(vignetteFeather))"
            + ";rou=\(k(vignetteRoundness))"
    }
}

/// M4 placeholder: masks are a first-class value from day one but render nothing in M1.
public struct Mask: Sendable, Equatable, Codable {
    public var id: String
    public var kind: String            // "brush" | "radial" | "linearGradient" | "sky" | "subject"
    public var params: [String: Double]

    public init(id: String = UUID().uuidString, kind: String, params: [String: Double] = [:]) {
        self.id = id
        self.kind = kind
        self.params = params
    }
}

// MARK: - canonical number formatting for cache keys

/// Stable text for a number in a cache key. Fixed notation, fixed precision, no locale.
public func k(_ v: Double) -> String { String(format: "%.5f", v) }

// MARK: - forgiving decode

/// Key used for `decodeWithDefaults`-style containers: the key string is the property name.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
    init(_ s: String) { self.stringValue = s; self.intValue = nil }
}

extension KeyedDecodingContainer where K == AnyCodingKey {
    /// Decode a field, falling back to the document default when it is missing or of the wrong type.
    func val<T: Decodable>(_ name: String, _ fallback: T) -> T {
        if let value = try? decodeIfPresent(T.self, forKey: AnyCodingKey(name)) {
            return value
        }
        return fallback
    }
}
