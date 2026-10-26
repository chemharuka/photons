import Foundation

// MARK: - Document model

/// A document's complete develop settings: **one** `Codable` value with a document-level
/// `schemaVersion` and an explicit default for every field (docs/architecture-decisions.md D9).
///
/// Groups follow Lightroom's panel split (Light / Curve / Color / Detail / Effects) so a future
/// XMP `crs:` mapping is mechanical. A missing key in an older document decodes to its default —
/// never to zero, never to a decode failure.
public struct EditModel: Sendable, Equatable, Codable {
    /// 2 = M4: `masks` changed from the placeholder `params: [String: Double]` to the real
    /// `Mask`/`MaskComponent`/`MaskShape` union (docs/tasks/005-masks.md §2). Not released, so
    /// there is no migration; the placeholder is simply dropped.
    /// 3 = 派单 006: `light.temperature`/`light.tint` became `Double?` with `nil` = the file's
    /// as-shot white balance, replacing the nominal `6500`/`0` that S1 turned into a gain. Not
    /// released either; schema-2 documents are read back as as-shot when they carry the old
    /// sentinel (`EditModel.init(from:)` → `LightGroup.migratePreSchema3WhiteBalance()`).
    public static let currentSchemaVersion = 3
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
    /// Local masks (M4). Empty = the graph has no mask stages at all (§3.2): the key chain stays the
    /// M1 seven-link chain and the pixels are byte-identical to M1.
    public var masks: [Mask]
    /// `showMask` (§3.1, 005e): when non-nil, the frame is the image with **that mask's atlas slice**
    /// painted over 50 % red — the same buffer S1.6 consumed, not a second evaluation of the
    /// predicate. `nil` (the default) is the pre-005e frame, pixel for pixel: the field is not part
    /// of the display key while it is nil, and no overlay pass is encoded.
    public var showMaskID: String?

    public init(schemaVersion: Int = EditModel.currentSchemaVersion,
                processVersion: Int = EditModel.currentProcessVersion,
                geometry: GeometryGroup = .identity,
                light: LightGroup = .identity,
                curve: CurveGroup = .identity,
                color: ColorGroup = .identity,
                detail: DetailGroup = .identity,
                effects: EffectsGroup = .identity,
                masks: [Mask] = [],
                showMaskID: String? = nil) {
        self.schemaVersion = schemaVersion
        self.processVersion = processVersion
        self.geometry = geometry
        self.light = light
        self.curve = curve
        self.color = color
        self.detail = detail
        self.effects = effects
        self.masks = masks
        self.showMaskID = showMaskID
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
        v.showMaskID = c.val("showMaskID", v.showMaskID)
        // 派单 006: pre-schema-3 documents used `light.temperature = 6500` / `tint = 0` as "the
        // decoder's own balance". The version is the document's, so this is the only place the
        // migration can be decided.
        if v.schemaVersion < 3 { v.light.migratePreSchema3WhiteBalance() }
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
            // Lightroom's Light panel straddles S1 (exposure, highlight recovery) and S2 (contrast,
            // highlights, shadows, whites, blacks). White balance (派单 006) straddles neither: a
            // change there means a **new development**, so every stage's source pixels are new.
            //
            // 派单 011: the question "is this a new development?" is `decodeInputs`, not a hand-rolled
            // comparison of two fields — `EditModel.splitFrom(_:)` is the one place that decides, and
            // the loupe keys its rungs by the same `DecodeInputs`.
            if decodesDifferently(from: old) {
                return Set(RenderStage.allCases)
            }
            if light.exposure != old.light.exposure
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
        // Masks split across the two new stages: geometry/combination invalidates the atlas,
        // adjustments invalidate only S1.6, and a rename invalidates nothing (§3.2). Both stages go
        // dirty when a mask appears or disappears, because the keys stop existing.
        if masks != old.masks {
            var oldByID: [String: Mask] = [:]
            for m in old.masks { oldByID[m.id] = m }
            var newIDs = Set<String>()
            for m in masks {
                newIDs.insert(m.id)
                guard let o = oldByID[m.id] else {
                    s.insert(.maskAtlas); s.insert(.localApply)
                    continue
                }
                if m.selectionKey != o.selectionKey { s.insert(.maskAtlas) }
                if m.applyKey != o.applyKey { s.insert(.localApply) }
            }
            for o in old.masks where !newIDs.contains(o.id) {
                s.insert(.maskAtlas); s.insert(.localApply)
            }
        }
        // `detail` (sharpening / noise reduction) is stored but not rendered by the M1 graph:
        // those two controls will be mapped onto CIRAWFilter in the decoder, not onto a kernel.
        // 005e: showing a different mask changes only the last pass (the overlay reads the atlas the
        // mask stages already produced), so it dirties nothing but `.display`.
        if showMaskID != old.showMaskID { s.insert(.display) }
        return s
    }

    /// Canonical text for the parameters a given stage consumes. Fed into the cache-key chain;
    /// must stay stable and order-independent across processes (no dictionary iteration).
    public func keyMaterial(_ stage: RenderStage) -> String {
        switch stage {
        case .geometry:
            // Byte-identical to the M1 material for every document that predates `aspectLock`
            // (the lock is only appended when it actually constrains the rect), so the pinned key
            // vector in MaskTests keeps holding.
            var s = "pv=\(processVersion);crop=\(geometry.crop.keyString)"
                + ";rot=\(k(geometry.straightenDegrees))"
                + ";flip=\(geometry.flipHorizontal ? 1 : 0)\(geometry.flipVertical ? 1 : 0)"
            if geometry.aspectLock.ratio != nil {
                s += ";asp=\(geometry.aspectLock.code)"
            }
            return s

        case .sceneLinear:
            // `temp=shot` when the document follows the file (派单 006): the key has to change when
            // the *decode* changes, and it must not claim "6500" for a file shot at 4803 K.
            return "ev=\(k(light.exposure));temp=\(light.temperature.map { k($0) } ?? "shot")"
                + ";tint=\(light.tint.map { k($0) } ?? "shot")"
                + ";hlr=\(k(light.highlightRecovery))"

        // S1.5 / S1.6 carry two different materials on purpose: `adjustments` must not be able to
        // rebuild the atlas (§3.3 item 4), and `name` is in neither.
        case .maskAtlas:
            return "masks=\(maskSelectionMaterial)"

        case .localApply:
            return "local=\(maskApplyMaterial)"

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
///
/// The document stores the crop as `crop` (origin + size) because that is the key the first
/// documents were written with; `cropRect` is the *same* rectangle viewed as four edges
/// (`right`/`bottom` are boundaries, XMP `crs:Crop*` order) and is the form the crop math speaks.
/// One stored truth, two spellings — a document can never carry two crop rects that disagree.
public struct GeometryGroup: Sendable, Equatable, Codable {
    /// The straighten control's range: a dial that turns the picture more than 45° is a rotate, and
    /// rotation lives in `orientation` (future), not here.
    public static let straightenLimit = 45.0

    public var crop: NormalizedRect
    /// Straighten angle in degrees, positive = clockwise. Applied *inside* the crop rect (the crop
    /// stays the output frame, so over-rotating reveals clamped edges rather than growing the canvas).
    /// Stored as given; `straightenDegrees` is the value S0 actually consumes (clamped to ±45).
    public var rotationDegrees: Double
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    /// Ratio the crop is constrained to. `.original` (the default) means "no constraint": the stored
    /// rect is the frame, which is what keeps pre-existing documents pixel-identical.
    public var aspectLock: AspectLock

    public static let identity = GeometryGroup(crop: .full, rotationDegrees: 0,
                                               flipHorizontal: false, flipVertical: false,
                                               aspectLock: .original)

    public init(crop: NormalizedRect = .full,
                rotationDegrees: Double = 0,
                flipHorizontal: Bool = false,
                flipVertical: Bool = false,
                aspectLock: AspectLock = .original) {
        self.crop = crop
        self.rotationDegrees = rotationDegrees
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.aspectLock = aspectLock
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = GeometryGroup.identity
        v.crop = c.val("crop", v.crop)
        // Edge-spelled crop (the XMP-facing form). When both keys are present the explicit edges win:
        // a writer that emits both writes them consistently, and a hand-edited document says what it
        // means once, in the newer spelling.
        if let edges = try? c.decodeIfPresent(CropRect.self, forKey: AnyCodingKey("cropRect")) {
            v.crop = edges.clamped().normalizedRect
        }
        v.rotationDegrees = c.val("rotationDegrees", v.rotationDegrees)
        v.flipHorizontal = c.val("flipHorizontal", v.flipHorizontal)
        v.flipVertical = c.val("flipVertical", v.flipVertical)
        v.aspectLock = c.val("aspectLock", v.aspectLock)
        self = v
    }

    // MARK: explicit crop / straighten semantics

    /// The crop as four edges in normalized source coordinates (0…1). `right`/`bottom` are
    /// boundaries, so `cropRect.full` is `(0, 0, 1, 1)` and not `(0, 0, 0, 0)`.
    public var cropRect: CropRect {
        get { CropRect(crop) }
        set { crop = newValue.clamped().normalizedRect }
    }

    public var flipH: Bool {
        get { flipHorizontal }
        set { flipHorizontal = newValue }
    }

    public var flipV: Bool {
        get { flipVertical }
        set { flipVertical = newValue }
    }

    /// Straighten angle as S0 uses it: the stored value clamped to ±`straightenLimit`.
    public var straightenDegrees: Double {
        min(max(rotationDegrees, -GeometryGroup.straightenLimit), GeometryGroup.straightenLimit)
    }

    /// The rect the renderer feeds to S0: the stored crop, re-shaped by `aspectLock` when the lock
    /// names a ratio (the lock wins over a rect that disagrees with it), then clamped.
    public func renderCrop(source: ImageSize) -> CropRect {
        CropMath.lockedCrop(aspectLock, in: cropRect, source: source).clamped()
    }

    /// `renderCrop` in the stored `NormalizedRect` form.
    public func renderCropRect(source: ImageSize) -> NormalizedRect {
        renderCrop(source: source).normalizedRect
    }

    public var isIdentity: Bool {
        self == GeometryGroup.identity
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
    public var whites: Double            // -100…100, default 0; + expands the white point (brighter)
    public var blacks: Double            // -100…100, default 0; + lifts the black point (brighter)
    /// Absolute white balance in Kelvin, fed to `CIRAWFilter.neutralTemperature` — **not** a gain on
    /// S1 (派单 006 B). `nil` = as shot: the decoder is left alone and the inspector shows the number
    /// the file reports (`DecoderCapabilities.asShotTemperature`).
    ///
    /// It used to be a nominal 6500 with a Planckian S1 gain. That was a lie in two ways: the number
    /// in the panel was not the file's, and the pixels moved through a fit rather than through the
    /// decoder. The literal `6500` is **not** a sentinel any more, and `nil` is distinct from it.
    public var temperature: Double?      // 2000…12000, default nil (as shot)
    /// Absolute tint (−150…150, positive = magenta), same rules as `temperature`.
    public var tint: Double?             // default nil (as shot)
    /// Soft shoulder for values above ~0.8; 0 = untouched, 1 = asymptote at 1.0.
    public var highlightRecovery: Double // 0…1, default 0

    public static let identity = LightGroup()

    public init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0,
                shadows: Double = 0, whites: Double = 0, blacks: Double = 0,
                temperature: Double? = nil, tint: Double? = nil, highlightRecovery: Double = 0) {
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

    /// Read a pre-006 document's `6500 K / tint 0` back into the as-shot state it meant.
    ///
    /// Called by `EditModel.init(from:)`, which is the only place that knows the **document's**
    /// `schemaVersion` — a `LightGroup` container has no version of its own, so the migration cannot
    /// live in `init(from:)` above (a first attempt did, and silently never fired).
    ///
    /// Why it matters: `6500` used to mean "no change", where the pixels came from Apple's as-shot
    /// decode. Reading it as an *explicit* 6500 K would re-decode the file at 6500 K and change every
    /// pixel of every pre-006 document — measured: assigning any value, including the one the filter
    /// reports, is not a no-op.
    mutating func migratePreSchema3WhiteBalance() {
        if temperature == 6500 { temperature = nil }
        if tint == 0 { tint = nil }
    }

    /// Written without the as-shot fields: `nil` is the default, and a document that says
    /// `"temperature": null` would be indistinguishable from a missing key anyway (D9's rule).
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(exposure, forKey: AnyCodingKey("exposure"))
        try c.encode(contrast, forKey: AnyCodingKey("contrast"))
        try c.encode(highlights, forKey: AnyCodingKey("highlights"))
        try c.encode(shadows, forKey: AnyCodingKey("shadows"))
        try c.encode(whites, forKey: AnyCodingKey("whites"))
        try c.encode(blacks, forKey: AnyCodingKey("blacks"))
        try c.encodeIfPresent(temperature, forKey: AnyCodingKey("temperature"))
        try c.encodeIfPresent(tint, forKey: AnyCodingKey("tint"))
        try c.encode(highlightRecovery, forKey: AnyCodingKey("highlightRecovery"))
    }

    public var isIdentity: Bool { self == LightGroup.identity }

    /// S1 exposure gain. 1.0 at 0 EV.
    public var exposureGain: Float { Float(pow(2.0, exposure)) }

    /// The decoder-side white balance this document asks for. `.asShot` when both are `nil`.
    public var whiteBalance: WhiteBalance {
        WhiteBalance(temperature: temperature, tint: tint)
    }

    /// S1 white-balance gains, normalized so that 6500 K / tint 0 is exactly (1, 1, 1).
    ///
    /// **The global white balance no longer uses this.** Since 派单 006 the document's Kelvin/tint go
    /// to `CIRAWFilter` and `RenderGraph`'s S1 pass runs with (1, 1, 1), because the decode has
    /// already balanced the pixels; multiplying again would apply the correction twice. What is left
    /// is the local-adjustment approximation (`MaskAdjustment.gain`), where a ±100 WB slider is a
    /// cheap scene-linear nudge on a masked region rather than a second development. As shot
    /// (`nil`) is the neutral of *that* fit, i.e. (1, 1, 1).
    public var whiteBalanceGains: (r: Float, g: Float, b: Float) {
        let reference = Self.planckianRGB(6500)
        let current = Self.planckianRGB(min(max(temperature ?? 6500, 2000), 12000))
        var r = reference.0 / max(current.0, 1e-4)
        var g = reference.1 / max(current.1, 1e-4)
        var b = reference.2 / max(current.2, 1e-4)
        let norm = max(g, 1e-4)
        r /= norm; g /= norm; b /= norm
        // Tint: positive = magenta, i.e. pull green down and hand the difference to R and B.
        let tintScale = 1 + min(max(tint ?? 0, -150), 150) / 150 * 0.5
        g /= tintScale
        let comp = tintScale.squareRoot()
        r *= comp; b *= comp
        return (Float(r), Float(g), Float(b))
    }

    static func planckianRGB(_ kelvin: Double) -> (Double, Double, Double) {
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
