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
    /// `Mask`/`MaskComponent`/`MaskShape` union — one mask is a list of components, each a shape
    /// plus its own adjustments. Not released, so
    /// there is no migration; the placeholder is simply dropped.
    /// 3 = 派单 006: `light.temperature`/`light.tint` became `Double?` with `nil` = the file's
    /// as-shot white balance, replacing the nominal `6500`/`0` that S1 turned into a gain. Not
    /// released either; schema-2 documents are read back as as-shot when they carry the old
    /// sentinel (`EditModel.init(from:)` → `LightGroup.migratePreSchema3WhiteBalance()`).
    /// 4 = 派单 030: `curve.rgb` became `curve.white` (the luminance curve, under a name that says
    /// so) and `light` gained the absolute `blackLevel`/`whiteLevel`. A schema-3 document's `rgb`
    /// key is read into `white` (`CurveGroup.init(from:)`), so the **shape** survives; only the name
    /// is new. Not released.
    public static let currentSchemaVersion = 4
    /// Per-document processing version. Behaviour changes bump this, and old documents keep their
    /// old rendering (darktable's snapshot semantics, not RawTherapee's global version bump).
    ///
    /// 2 = 派单 030: the curve moved from S3 (display-referred, after the tone map) to S1.7
    /// (scene-referred, log-light axis). The same control points now render differently — that is a
    /// change of meaning, exactly what this field is for. `pv=` is in the geometry key material, so
    /// a version bump also moves every key: pixels of an **identity** curve are unchanged, pixels of
    /// a shaped one are not, and the version number is the document's declaration of which it got.
    public static let currentProcessVersion = 2

    public var schemaVersion: Int
    public var processVersion: Int
    public var geometry: GeometryGroup
    public var light: LightGroup
    public var curve: CurveGroup
    public var color: ColorGroup
    public var detail: DetailGroup
    /// 派单 031: the four **decode-side** detail amounts (降噪 / 色彩降噪 / 细节 / 锐化), assigned to
    /// `CIRAWFilter` before it produces pixels. Deliberately not `detail`: that name has held the
    /// XMP-facing `DetailGroup` placeholders since M1 (`crs:Sharpness`, `crs:LuminanceSmoothing`),
    /// which the render graph does not consume and which export still reads. One panel, two
    /// audiences — the decoder takes these, XMP keeps those.
    public var detailSettings: DetailSettings
    public var effects: EffectsGroup
    /// Optics: lateral chromatic aberration (029). Its own group, **not** a field in `DetailGroup`:
    /// `keyMaterial` has no `.detail` branch, so a slider parked there would change no key and would
    /// silently render nothing.
    public var optics: OpticsGroup
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
                detailSettings: DetailSettings = .identity,
                effects: EffectsGroup = .identity,
                optics: OpticsGroup = .identity,
                masks: [Mask] = [],
                showMaskID: String? = nil) {
        self.schemaVersion = schemaVersion
        self.processVersion = processVersion
        self.geometry = geometry
        self.light = light
        self.curve = curve
        self.color = color
        self.detail = detail
        self.detailSettings = detailSettings
        self.effects = effects
        self.optics = optics
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
        v.detailSettings = c.val("detailSettings", v.detailSettings)
        v.effects = c.val("effects", v.effects)
        v.optics = c.val("optics", v.optics)
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
        // 派单 031: the decode inputs are not all inside `light` any more (the white balance is; the
        // four detail amounts are not), so the question "is this a new development?" is asked once,
        // over `decodeInputs`, before any group is compared. A new development means every stage's
        // source pixels are new — the same answer the white balance gets, for the same reason.
        if decodesDifferently(from: old) {
            return Set(RenderStage.allCases)
        }
        var s: Set<RenderStage> = []
        if geometry != old.geometry { s.insert(.geometry) }
        if light != old.light {
            // Lightroom's Light panel straddles S1 (blacks/whites levels, exposure, highlight
            // recovery) and S2 (contrast, highlights, shadows). Blacks/whites are a **level** — the
            // 0 and 1 points of the scene-linear buffer — so they dirty `.sceneLinear` like exposure
            // does: the linear buffer itself is what changed (派单 019). White balance (派单 006)
            // straddles neither: it was already answered above, by `decodeInputs`.
            //
            // 030: the absolute `blackLevel`/`whiteLevel` are the same level under a second name
            // (one control, two handles — the sliders and the curve panel's reference lines), so
            // they dirty exactly the stage the sliders do. Nothing else: the mask atlas is
            // downstream of `.sceneLinear`'s key, which the chain handles.
            if light.exposure != old.light.exposure
                || light.highlightRecovery != old.light.highlightRecovery
                || light.whites != old.light.whites
                || light.blacks != old.light.blacks
                || light.blackLevel != old.light.blackLevel
                || light.whiteLevel != old.light.whiteLevel {
                s.insert(.sceneLinear)
            }
            if light.contrast != old.light.contrast
                || light.highlights != old.light.highlights
                || light.shadows != old.light.shadows {
                s.insert(.toneMap)
            }
        }
        if curve != old.curve { s.insert(.curve) }
        if color != old.color { s.insert(.color) }
        if effects != old.effects { s.insert(.vignette) }
        // 029: `α` is a geometry parameter — it moves where R and B are sampled out of the source —
        // so it dirties S0 and, through the key chain, everything below it.
        if optics != old.optics { s.insert(.geometry) }
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
            // 056: hue/saturation are S3.5's parameters now, so a move of one of them dirties that
            // stage. Reported only when the *local colour* material actually moved, so an exposure
            // drag still reports `.localApply` alone.
            if localColorMaterial != old.localColorMaterial { s.insert(.localColor) }
        }
        // `detail` (the XMP-facing `DetailGroup`) is stored but not rendered by the graph. 派单 031
        // put the real controls next to it: `detailSettings` is a **decode** input and was answered
        // above, so — like the white balance — it never appears as a dirty *stage*.
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
            // 029: lateral CA. Appended **only when non-zero**, exactly like `asp`, so every document
            // that has never touched the CA sliders keeps the pre-029 geometry material byte for
            // byte — the seven pinned keys and every recorded golden depend on that.
            if optics.caRed != 0 { s += ";car=\(k(optics.caRed))" }
            if optics.caBlue != 0 { s += ";cab=\(k(optics.caBlue))" }
            return s

        case .sceneLinear:
            // `temp=shot` when the document follows the file (派单 006): the key has to change when
            // the *decode* changes, and it must not claim "6500" for a file shot at 4803 K.
            //
            // `wh`/`bl` are here, not in `.toneMap`, since 派单 019: a black/white level normalises the
            // scene-linear buffer itself (`(v − blk)/max(wht − blk, 1e−3)` before the gain), so the S1
            // output changes and everything below it must miss. The tokens are the same ones S2 used
            // to carry, in the same order, so a document's numbers read the same in a log line.
            //
            // 030 appends the absolute levels **only when they are set** (§3.2 discipline): a
            // document that never used a level dropper keeps its S1 material byte for byte, and a
            // document that did can never serve a cached S1 buffer levelled somewhere else.
            var m = "ev=\(k(light.exposure));temp=\(light.temperature.map { k($0) } ?? "shot")"
                + ";tint=\(light.tint.map { k($0) } ?? "shot")"
                + ";hlr=\(k(light.highlightRecovery))"
                + ";wh=\(k(light.whites));bl=\(k(light.blacks))"
            if let bl = light.blackLevel { m += ";blL=\(k(bl))" }
            if let wh = light.whiteLevel { m += ";whL=\(k(wh))" }
            return m

        // S1.5 / S1.6 carry two different materials on purpose: `adjustments` must not be able to
        // rebuild the atlas (§3.3 item 4), and `name` is in neither.
        case .maskAtlas:
            return "masks=\(maskSelectionMaterial)"

        case .localApply:
            return "local=\(maskApplyMaterial)"

        case .localColor:
            // 056: S3.5's own material. Redundant with the chain above it on purpose — the chain
            // already carries `maskApplyMaterial`, so a selection change moves this key too — but a
            // stage key that names the values it reads cannot silently stop tracking them if the
            // S1.6 material is ever narrowed.
            return "localcolor=\(localColorMaterial)"

        case .toneMap:
            // Contrast and the two region lifts only — the whites/blacks levels moved into the
            // `.sceneLinear` material with the maths (派单 019), so a level change must not be able to
            // miss a cached S1 output by landing in this key instead.
            return "con=\(k(light.contrast));hi=\(k(light.highlights));sh=\(k(light.shadows))"

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

    /// Absolute black level in **scene-linear** light (`0.18` means "the 18 % grey patch reads
    /// here"), or `nil` = use the `blacks` slider's mapping (派单 030).
    ///
    /// Why an absolute value exists at all: a slider's travel cannot express an HDR white point. The
    /// sliders reach `blk ∈ [−0.15, +0.15]` (plenty — a black sample is always below −3 EV) and
    /// `wht ∈ [0.85, 1.15]` (**not** plenty — a +1 EV highlight needs `wht = 2.0`).
    ///
    /// **Exactly one of the two spellings is in force**: this field when non-nil, the slider
    /// otherwise. The slider clears this to `nil` when it is dragged, so two black points cannot
    /// exist (`temperature`'s `nil` discipline, 派单 006).
    public var blackLevel: Double?
    /// Absolute white level in scene-linear light; `nil` = the `whites` slider's mapping. Same rules
    /// as `blackLevel`, with `white ≥ black + 1e-3` enforced on the pair.
    public var whiteLevel: Double?

    public static let identity = LightGroup()

    /// The envelope the level fields are clamped into (`§7.1`): a black sample below −3 EV is noise,
    /// and a white above +4 EV is past the far end of the curve's axis (the shaper keeps going at the
    /// last slope, but nothing above it can be labelled — 044 moved the end from +6 to +4 EV; the
    /// envelope itself stays where §7.1 put it, so old documents still load).
    public static let blackLevelRange: ClosedRange<Double> = -0.05...0.5
    public static let whiteLevelRange: ClosedRange<Double> = 0.05...64

    public init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0,
                shadows: Double = 0, whites: Double = 0, blacks: Double = 0,
                temperature: Double? = nil, tint: Double? = nil, highlightRecovery: Double = 0,
                blackLevel: Double? = nil, whiteLevel: Double? = nil) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.temperature = temperature
        self.tint = tint
        self.highlightRecovery = highlightRecovery
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
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
        v.blackLevel = c.val("blackLevel", v.blackLevel)
        v.whiteLevel = c.val("whiteLevel", v.whiteLevel)
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
        // 030: absent, not `null` — a document that never set a level encodes byte-identically to
        // the pre-030 JSON (the `temperature`/`tint` rule again).
        try c.encodeIfPresent(blackLevel, forKey: AnyCodingKey("blackLevel"))
        try c.encodeIfPresent(whiteLevel, forKey: AnyCodingKey("whiteLevel"))
    }

    public var isIdentity: Bool { self == LightGroup.identity }

    /// The black level the `blacks` slider asks for, `blk = −blacks/100·0.15` (派单 019, unchanged).
    public var sliderBlackLevel: Double { -blacks / 100 * 0.15 }

    /// The white level the `whites` slider asks for, `wht = 1 − whites/100·0.15`.
    public var sliderWhiteLevel: Double { 1 - whites / 100 * 0.15 }

    /// Where 0 and 1 are, after the absolute fields and the sliders are reconciled.
    ///
    /// One answer, one place: S1, the level droppers and the curve panel's reference lines all read
    /// this, so "which black point is in force" cannot be answered two ways.
    public var levels: LevelPair {
        let blk = min(max(blackLevel ?? sliderBlackLevel,
                          LightGroup.blackLevelRange.lowerBound), LightGroup.blackLevelRange.upperBound)
        let whtRaw = min(max(whiteLevel ?? sliderWhiteLevel,
                             LightGroup.whiteLevelRange.lowerBound), LightGroup.whiteLevelRange.upperBound)
        // `max(…, 1e-3)` on the span, exactly as S1's remap does: a pair that crossed over would
        // divide by ≤ 0 and invert the picture.
        return LevelPair(black: blk, white: max(whtRaw, blk + 1e-3))
    }

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

/// The pair of linear levels S1 applies — "where 0 is" and "where white is".
///
/// One value type rather than two loose numbers, because three things must agree about it: the S1
/// remap `(v − black)/span`, the droppers' cross-constraint (a black sample may not be pushed onto
/// the white level) and `keyMaterial`'s envelope. §13.1 asks for exactly this: the mapping lives in
/// one place so a later change to the level form (stops instead of linear, say) is one edit.
public struct LevelPair: Sendable, Equatable {
    /// Input value that maps to 0.
    public var black: Double
    /// Input value that maps to 1.
    public var white: Double

    public init(black: Double, white: Double) {
        self.black = black
        self.white = white
    }

    public static let identity = LevelPair(black: 0, white: 1)

    /// The divisor, floored exactly as `s1_scene_linear.metal` floors it: a pair that crossed over
    /// must not invert the picture.
    public var span: Double { max(white - black, 1e-3) }

    /// The affine remap S1 performs, in `Double` — for solvers and tests, not for the GPU.
    public func normalised(_ v: Double) -> Double { (v - black) / span }

    /// True when this pair maps `0 → 0` and `1 → 1` exactly: no levelling at all.
    public var isIdentity: Bool { black == 0 && white == 1 }
}

/// Lightroom's tone curve. Four monotone-cubic LUTs: **W** (luminance) plus per-channel R/G/B.
///
/// 派单 030 moved this curve from S3 (after the tone map, on 0…1 display data) to **S1.7** (before
/// the tone map, on unbounded scene-linear light), so the two axes mean new things:
///
///   · x is the **axis coordinate** `u` of `HDRCurveAxis` — since 062 the histogram's own axis, so
///     the left half of the card is SDR display code 0–255 (`u = 0` is zero light, `u = 0.5000` is
///     SDR white) and the right half is +0…+4 EV (`u = 1`);
///   · y is the same coordinate, i.e. the curve answers "map this u to that u".
///
/// The point lists keep their shape, their 0…1 range and `CurvePoint.linear` — only the meaning of
/// the y axis changed, which is exactly what `processVersion` 2 records (§10.1). Old documents keep
/// their control points and get a different rendering; that is the declared migration, not a bug.
public struct CurveGroup: Sendable, Equatable, Codable {
    /// The luminance curve. Was called `rgb` — and was *not* the composite-per-channel curve that
    /// name suggests: it is a gain on the pixel's luma, which keeps hue and saturation. The old name
    /// is kept as a deprecated alias so the ~12 call sites in tests and export keep compiling, but
    /// nothing should be written against it: on a saturated HDR pixel the two operators differ by
    /// 137 8-bit codes (§5.2).
    public var white: [CurvePoint]
    public var red: [CurvePoint]
    public var green: [CurvePoint]
    public var blue: [CurvePoint]

    public static let identity = CurveGroup()

    public init(white: [CurvePoint] = CurvePoint.linear,
                red: [CurvePoint] = CurvePoint.linear,
                green: [CurvePoint] = CurvePoint.linear,
                blue: [CurvePoint] = CurvePoint.linear) {
        self.white = white
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The pre-030 spelling. `white`, under its old name — not a fifth curve, and not a composite.
    @available(*, deprecated, message: "`rgb` is the luminance curve `white` under its old name")
    public init(rgb: [CurvePoint],
                red: [CurvePoint] = CurvePoint.linear,
                green: [CurvePoint] = CurvePoint.linear,
                blue: [CurvePoint] = CurvePoint.linear) {
        self.init(white: rgb, red: red, green: green, blue: blue)
    }

    @available(*, deprecated, message: "`rgb` is the luminance curve `white` under its old name")
    public var rgb: [CurvePoint] {
        get { white }
        set { white = newValue }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = CurveGroup.identity
        // 派单 030 / schema 4: `white` is the stored name; a schema-3 document says `rgb`. One line,
        // and the shape of the point list survives the rename untouched.
        v.white = c.val("white", c.val("rgb", v.white))
        v.red = c.val("red", v.red)
        v.green = c.val("green", v.green)
        v.blue = c.val("blue", v.blue)
        self = v
    }

    /// Only `white` is written: a document must not be able to carry both names.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(white, forKey: AnyCodingKey("white"))
        try c.encode(red, forKey: AnyCodingKey("red"))
        try c.encode(green, forKey: AnyCodingKey("green"))
        try c.encode(blue, forKey: AnyCodingKey("blue"))
    }

    /// The four point lists in table order — W, R, G, B — which is the order the GPU buffer has.
    public var tables: [[CurvePoint]] { [white, red, green, blue] }

    public var isIdentity: Bool {
        white == CurvePoint.linear && red == CurvePoint.linear
            && green == CurvePoint.linear && blue == CurvePoint.linear
    }

    public var keyString: String {
        func one(_ p: [CurvePoint]) -> String { p.map(\.keyString).joined(separator: ";") }
        // `w=` since 030: the field is the luminance curve, and a key that still said `rgb=` would
        // invite exactly the confusion §5.2 warns about.
        return "w=\(one(white))|r=\(one(red))|g=\(one(green))|b=\(one(blue))"
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

/// Optics: lateral (transverse) chromatic aberration — 029.
///
/// The stored values are **dimensionless radial ratios**, not pixel shifts: α > 0 means that
/// channel's image is larger than green's (a longer effective focal length), and the correction
/// samples that channel at `r · (1 + α)` so the three channels line up again. A preview at 400 px
/// and an export at 9504 px therefore correct the same fraction of the radius — a pixel-valued
/// parameter could not do that (029 §4.1).
///
/// Full scale is ±0.005: LightCraft's `CA_SCALE` is 0.003, RawTherapee's post-demosaic CA slider is
/// ±0.005 in steps of 1e-4, and PixelLoupe searches ±0.5 % in steps of 0.01 % — three independent
/// implementations inside 3–5 × 10⁻³, so 5 × 10⁻³ is neither cramped nor a dead zone.
///
/// Sign convention, the one the UI copy repeats: `caRed > 0` = "the red image is bigger, pull it
/// in", i.e. a larger α samples red further out.
public struct OpticsGroup: Sendable, Equatable, Codable {
    /// |α| at full deflection of either slider.
    public static let fullScale = 0.005

    /// α_R: red relative to green, −0.005…+0.005, default 0 (+ = red image is larger).
    public var caRed: Double
    /// α_B: blue relative to green, same range and convention.
    public var caBlue: Double

    public static let identity = OpticsGroup()

    public init(caRed: Double = 0, caBlue: Double = 0) {
        self.caRed = caRed
        self.caBlue = caBlue
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = OpticsGroup.identity
        v.caRed = c.val("caRed", v.caRed)
        v.caBlue = c.val("caBlue", v.caBlue)
        self = v
    }

    /// Both sliders at zero. The graph's S0 fast path keys off exactly this.
    public var isIdentity: Bool { caRed == 0 && caBlue == 0 }

    /// Corner displacement in pixels of the render at `halfDiagonal` — a **read-out**, not a
    /// parameter: it belongs to the viewport's size, so it never enters a key.
    public func cornerPixels(halfDiagonal: Double) -> Double {
        max(abs(caRed), abs(caBlue)) * halfDiagonal
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
