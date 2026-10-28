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
    /// 5 = 派单 071: `light.blackOffset` — the additive linear black trim (±0.01, 1/1000 steps). The
    /// key is **absent** from every document that never used the control (0 encodes to nothing, the
    /// `temperature`/`tint`/`blackLevel` rule), so a schema-4 blob re-encodes byte for byte and only
    /// the version number says the schema grew. Nothing migrates: an absent key reads as 0, which is
    /// the value the old documents mean.
    /// 6 = 派单 042: `detailSettings.detail`'s travel became **0…30** (it maps to `detailAmount`
    /// 0…3, the range Apple's `CIRAWFilter.h:148-154` documents) while the other three axes keep
    /// 0…100 → 0…1. A schema-5 document stored the same amount on the old 0…100 travel, so the
    /// migration is `detail / 10` — the **amount** a document asks for is preserved (old 100 →
    /// new 10 → amount 1.0), which is to say its look is preserved. Only that one field moves; see
    /// `DetailSettings.migratePreSchema6Detail()` for why it is /10 and not a rescale to 3.
    /// 7 = 2026-10-28: 颗粒 — `effects.grainSize` (0…100, default **25**), `effects.grainRoughness`
    /// (0…100, default **50**) and `effects.grainSeed` (0…999, default 0) joined `effects.grain`,
    /// which keeps its key and is now read as the grain's **amount** (`crs:GrainAmount`). S3.7 renders
    /// all four; before this version the amount was stored and not rendered.
    ///
    /// **Nothing migrates.** The three keys are absent from every document written before this
    /// version, and an absent key reads as its default — amount 0, so a schema-6 document has
    /// `hasGrain == false`, S3.7 is not encoded for it, and its pixels are byte-identical (schema 5's
    /// `blackOffset` pattern, not schema 6's `/10`: no stored number changes *meaning* here). The
    /// version is therefore **not** stamped on such a document at decode time — it keeps the number
    /// its own file wrote, and only a document saved by this build carries 7.
    /// 8 = 2026-10-28 (P0-4): 黑白 — `color.blackAndWhite` (default `false`) and
    /// `color.bands[i].mix` (−100…100, default 0, on the **same** eight-band table the HSL panel
    /// edits: `HSLBand.mix` is the per-hue share of the grey, Lightroom's B&W mixer). S3.4 renders
    /// both; before this version neither existed.
    ///
    /// **Nothing migrates, and the encoding is additive.** `blackAndWhite` is written only when it is
    /// `true` and `mix` only when it is non-zero (the `blackOffset`/`temperature` rule), so a schema-7
    /// document re-encodes **byte for byte** and an absent key reads as its default: switch off, mixes
    /// 0, `hasBW == false`, S3.4 not encoded, pixels unchanged. Like schema 7, the version is not
    /// stamped at decode time on a document that carries neither key — a document keeps the number its
    /// own file wrote, and only a document this build saves carries 8.
    /// 9 = 2026-10-28 (P0 色彩分级): `colorGrading` — the three-way colour wheel, nine numbers
    /// (`shadows`/`midtones`/`highlights`, each 色相/饱和/亮度, all default 0). S3.8 renders them.
    ///
    /// **Nothing migrates, and the encoding is additive** — the schema-7/8 rule, read a third time.
    /// The group is written **only when it is not the neutral group** (all nine numbers 0), so every
    /// document from before this version re-encodes byte for byte; an absent key decodes to zeros,
    /// `hasGrade == false`, S3.8 is not encoded at all, and the frame is the pre-S3.8 frame by
    /// construction rather than by arithmetic. No stored number changes *meaning*, so the version is
    /// not stamped on decode — a document keeps the number its own file wrote, and only a document
    /// this build saves carries 9.
    ///
    /// 9 = 2026-10-28 (P0-6): 纹理 / 清晰度 / 去雾 — `effects.texture`, `effects.clarity` and
    /// `effects.dehaze` (−100…100, default 0), the Effects card's missing third block. S3.8 renders all
    /// three (`Kernels/s3_8_detail_fx.metal`); before this version none of them existed.
    ///
    /// **Nothing migrates, and the encoding is additive.** Each of the three is written only when it is
    /// non-zero (the `blackOffset`/`blackAndWhite` rule), so a schema-8 document re-encodes **byte for
    /// byte** and an absent key reads as its default: 0, so `hasDetailFX == false`, S3.8 is not encoded
    /// for it, and its pixels are byte-identical. Like schemas 7 and 8, the version is not stamped at
    /// decode time on a document that carries none of the three keys — a document keeps the number its
    /// own file wrote, and only a document this build saves carries 9.
    ///
    /// 9 (also) = 2026-10-28 (P0-10): 90° 旋转 — `geometry.quarterTurns` (0…3 clockwise, default 0).
    ///
    /// **Nothing migrates, and the migration is a guard, not a rewrite.** A pre-9 document cannot
    /// carry a turn (`init(from:)` reads the key as 0 below 9 — a hand-edited `quarterTurns: 1` in a
    /// schema-8 file is ignored, because v8 does not *have* the field and honouring it would rotate a
    /// picture its author never turned), and at 0 the crop rect means exactly what it meant before:
    /// the rect is measured in the turned frame, and the un-turned frame *is* the file's frame. So the
    /// stored rect, the pixels and the key of a schema-8 document are untouched, and the version is
    /// not stamped at decode time (schema 7/8's rule).
    ///
    /// What *does* change meaning is the crop rect of a document that **is** turned: schema 9 defines
    /// `crop` in the turned frame, so `EditModel.turn(clockwise:)` rewrites it (`CropMath.turned*`)
    /// and stamps the document 9 — a turn is the one edit that makes a v9 file out of a v8 one.
    /// 10 = 2026-10-28 (078 P0-1 / B9): 修复画笔 — `healSpots`, the spot list of S1.9 (heal / clone,
    /// each `HealSpot` a disk on the frame with a source offset). S1.9 renders them; before this
    /// version the tool did not exist.
    ///
    /// **Nothing migrates, and the encoding is additive** — the schema-7/8/9 rule, read a fourth
    /// time. The key is written **only when the list is non-empty**, so every document from before
    /// this version re-encodes byte for byte; an absent key decodes to `[]`, `hasHeal == false`, S1.9
    /// is not encoded at all, and the frame is the pre-S1.9 frame by construction rather than by
    /// arithmetic. No stored number changes *meaning*, so the version is not stamped on decode — a
    /// document keeps the number its own file wrote, and only a document this build saves carries 10.
    public static let currentSchemaVersion = 10
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
    /// 2026-10-28 (P0 色彩分级) — **三向色彩分级**: 阴影 / 中间调 / 高光, each 色相 + 饱和 + 亮度.
    /// S3.8 renders it; the three regions are the **luminance windows S2's own 阴影/高光 use**
    /// (`tone_shape.metal`'s `region_weights`), so 「阴影」 means one thing in the whole panel.
    ///
    /// Its own group, and its own `RenderGroup` (`colorGrading`), because it is neither the Color card
    /// (`vibrance`/`saturation`) nor the HSL card (per-*hue* bands): a double-click on Color must not
    /// undo work done here, and the timeline must be able to say 「色彩分级 阴影」.
    public var colorGrading: ColorGradingGroup
    public var detail: DetailGroup
    /// 派单 031: the four **decode-side** detail amounts (降噪 / 色彩降噪 / 细节 / 锐化), assigned to
    /// `CIRAWFilter` before it produces pixels. Deliberately not `detail`: that name has held the
    /// XMP-facing `DetailGroup` placeholders since M1 (`crs:Sharpness`, `crs:LuminanceSmoothing`),
    /// which the render graph does not consume and which export still reads. One panel, two
    /// audiences — the decoder takes these, XMP keeps those.
    public var detailSettings: DetailSettings
    /// 解码模型 (owner, 2026-10-27): the decoder version this document asks for, as **one item of the
    /// file's own `supportedDecoderVersions` list** (`"8"`, `"8.dng"`, `"9.dng"`, …) — `nil` means "ask
    /// for nothing", i.e. Apple's default, which is v8 today and is what every pre-change document gets.
    ///
    /// A spelling, not a family: this machine's SL3 DNG offers `8` **and** `8.dng`, and they are
    /// different pictures (measured `photonsctl detail`, same frame: `8` → `08193a35…`, `8.dng` →
    /// `a15055fa…`, `9.dng` → `f4d7e53b…`; bare `9` is not offered and silently reads back `8`).
    /// `RAWDecoder` assigns the string verbatim and reads it back, so a document from another body that
    /// this file cannot honour reports the fallback (`已退回 v8`) instead of pretending.
    public var decoderVersion: String?
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
    /// 2026-10-28 (078 P0-1 / B9) — **修复画笔**: the spot list S1.9 renders (heal / clone).
    ///
    /// Empty = the graph has no S1.9 at all: the key chain stays the pre-S1.9 seven-link chain (plus
    /// whatever the other conditional stages add) and the pixels are byte-identical, which is the
    /// same structural rule `masks` follows — the pass is *absent*, not neutral.
    ///
    /// Array order is **composition order** (a later spot may overwrite an earlier one), so it is part
    /// of the material. The spots themselves live in `HealSpot` (frame-normalised centre, short-edge
    /// radius and source offset — see that file for why heal is frame-anchored where a mask is
    /// source-anchored).
    public var healSpots: [HealSpot]

    public init(schemaVersion: Int = EditModel.currentSchemaVersion,
                processVersion: Int = EditModel.currentProcessVersion,
                geometry: GeometryGroup = .identity,
                light: LightGroup = .identity,
                curve: CurveGroup = .identity,
                color: ColorGroup = .identity,
                colorGrading: ColorGradingGroup = .identity,
                detail: DetailGroup = .identity,
                detailSettings: DetailSettings = .identity,
                decoderVersion: String? = nil,
                effects: EffectsGroup = .identity,
                optics: OpticsGroup = .identity,
                masks: [Mask] = [],
                showMaskID: String? = nil,
                healSpots: [HealSpot] = []) {
        self.schemaVersion = schemaVersion
        self.processVersion = processVersion
        self.geometry = geometry
        self.light = light
        self.curve = curve
        self.color = color
        self.colorGrading = colorGrading
        self.detail = detail
        self.detailSettings = detailSettings
        self.decoderVersion = decoderVersion
        self.effects = effects
        self.optics = optics
        self.masks = masks
        self.showMaskID = showMaskID
        self.healSpots = healSpots
    }

    /// The all-defaults document: renders as "decode → display encode", nothing else.
    public static let neutral = EditModel()

    // MARK: - 080 · 原图 / 对比

    /// The document **without its geometry**: full crop, no straighten, no flip, no CA.
    ///
    /// This is the document 「显示原图」(`\`) is rendered with, and the reason it is a *document* rather
    /// than a render flag alone: the camera (`LoupeFraming`) is derived from the document's crop, so
    /// a frame of the whole decode needs the framing of the whole decode too — otherwise the
    /// picture would be correct and placed as if it had been cropped.
    ///
    /// Everything else is kept: the light/curve/colour values are irrelevant to that render (it
    /// never visits their stages) but leaving them alone keeps this a *projection* of the document
    /// rather than a second document — a value changed here can never leak back into the user's.
    public var disregardingGeometry: EditModel {
        var v = self
        v.geometry = .identity
        v.optics = .identity
        return v
    }

    /// 2026-10-28 (P0-10): does the document carry a 90° turn? Judged **by value** — the same way
    /// `hasHSL`/`hasGrain` are — because a turn of 0 must leave the render path (and the key) exactly
    /// as it was.
    public var hasQuarterTurn: Bool { geometry.quarterTurns != 0 }

    /// One 90° turn of the whole document: the **one** mutation the editor's ⌘[ / ⌘] and a preset's
    /// 「导出时再转」 both apply, so they cannot disagree about the crop or about the version stamp.
    ///
    /// Touches three things and nothing else:
    ///   · `geometry` — the frame turns and the crop turns with it (`GeometryGroup.turn`);
    ///   · `schemaVersion` — a v8 document has no turn, so the first turn is what makes it v9 (the
    ///     crop rect's meaning just changed). Already-9 documents are left alone;
    ///   · nothing else: no parameter moves, and a straighten angle or a flip keeps its value (it is
    ///     measured in the frame the user sees, which is the frame that just turned).
    ///
    /// Returns `false` when there was nothing to do, so a history row is never minted for a no-op.
    @discardableResult
    public mutating func turn(clockwise: Bool) -> Bool {
        let before = geometry
        geometry.turn(clockwise: clockwise)
        guard geometry != before else { return false }
        if schemaVersion < EditModel.currentSchemaVersion {
            schemaVersion = EditModel.currentSchemaVersion
        }
        return true
    }

    /// `turn(clockwise:)` `count` times.
    ///
    /// The export side's door to the same mutation: an exporter renders the document it is handed, so
    /// "the editor turned it once" and "the document arrived with `quarterTurns = 1`" are one document
    /// and one code path — `QuarterTurnTests.testTheExportIsTheSameTurnAsTheEditor` exports both and
    /// compares the files byte for byte.
    public func turned(by count: Int) -> EditModel {
        var v = self
        for _ in 0..<GeometryGroup.normalizedQuarterTurns(count) { v.turn(clockwise: true) }
        return v
    }

    /// The document with every **parameter** group zeroed and its geometry kept.
    ///
    /// This is the spelling 「参数清零后的渲染」, i.e. exactly what `\` must *not* be: it still crops,
    /// straightens and flips, so on a cropped document it shows a differently-framed picture from the
    /// decode. It exists here — public, one definition — so the test can render it and show that the
    /// two are different pixels (`BeforeAfterTests`), and so the refutation can make `\` return *this*
    /// and watch the first assertion go red.
    public var disregardingParameters: EditModel {
        var v = self
        v.light = .identity
        v.curve = .identity
        v.color = .identity
        v.colorGrading = .identity
        v.effects = .identity
        v.optics = .identity
        v.masks = []
        v.showMaskID = nil
        // 2026-10-28 (078 P0-1): a repair is an edit like any other, so 「参数清零」 clears it too.
        v.healSpots = []
        return v
    }

    /// 派单 076 / 101: does S3.6 exist for this document? Judged **by value** — any of the 24 band
    /// numbers or the global (「全局」) triplet is non-zero — exactly the way `hasLocalColor` is judged
    /// for S3.5. A stage that is present but neutral would still move the trace and the key chain.
    public var hasHSL: Bool { color.hasBands || color.hasGlobal }

    /// 2026-10-28: does S3.7 exist for this document? Judged **by value** (the grain amount is above
    /// zero), exactly the way `hasHSL` judges S3.6 — a stage present but neutral would move the trace
    /// and the key chain for nothing.
    public var hasGrain: Bool { effects.hasGrain }

    /// 2026-10-28 (P0-6): does S3.8 exist for this document? Judged **by value** — any of the three
    /// numbers non-zero — exactly the way `hasGrain` judges S3.7. A document whose three are 0 keeps the
    /// pre-S3.8 stage list, key chain and pixels byte for byte: the pass is not encoded at all.
    public var hasDetailFX: Bool { effects.hasDetailFX }

    /// 2026-10-28 (P0-4): does S3.4 exist for this document? Judged **by value** — the 黑白 switch,
    /// not "the color group exists" and not "a mix is non-zero": a mix with the switch off is a value
    /// waiting for the switch, and it renders nothing (Lightroom behaves the same way, and it is what
    /// makes 「切回彩色」 bit-identical with the mixes still in the document).
    public var hasBlackAndWhite: Bool { color.blackAndWhite }

    /// 2026-10-28 (P0 色彩分级): does S3.8 exist for this document? Judged **by value** — any of the
    /// nine numbers non-zero — exactly the way `hasHSL`/`hasGrain` are judged. A stage present but
    /// neutral would move the trace and the key chain for nothing, and a document that never touched
    /// the card must keep the pre-S3.8 chain byte for byte.
    public var hasGrade: Bool { !colorGrading.isIdentity }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = EditModel.neutral
        v.schemaVersion = c.val("schemaVersion", v.schemaVersion)
        v.processVersion = c.val("processVersion", v.processVersion)
        v.geometry = c.val("geometry", v.geometry)
        v.light = c.val("light", v.light)
        // 069: the curve is the one group whose decode can **throw** (a coordinate outside `0…2`), so it
        // is not read through `val(...)` — that helper swallows errors and would turn "this file says
        // x = 2.5" into "this file has no curve". A range error propagates; any other malformed curve
        // still falls back to the identity, as every other group does.
        if c.contains(AnyCodingKey("curve")) {
            do {
                v.curve = try c.decode(CurveGroup.self, forKey: AnyCodingKey("curve"))
            } catch let error as CurveCoordinateOutOfRange {
                throw error
            } catch {
                v.curve = .identity
            }
        }
        v.color = c.val("color", v.color)
        // 2026-10-28 (P0 色彩分级): an absent key reads as the neutral group — nine zeros, i.e.
        // `hasGrade == false` and no S3.8 link (schema 9's additive rule).
        v.colorGrading = c.val("colorGrading", v.colorGrading)
        v.detail = c.val("detail", v.detail)
        v.detailSettings = c.val("detailSettings", v.detailSettings)
        v.decoderVersion = c.val("decoderVersion", v.decoderVersion)
        v.effects = c.val("effects", v.effects)
        v.optics = c.val("optics", v.optics)
        v.masks = c.val("masks", v.masks)
        v.showMaskID = c.val("showMaskID", v.showMaskID)
        // 派单 006: pre-schema-3 documents used `light.temperature = 6500` / `tint = 0` as "the
        // decoder's own balance". The version is the document's, so this is the only place the
        // migration can be decided.
        if v.schemaVersion < 3 { v.light.migratePreSchema3WhiteBalance() }
        // 派单 042: the 细节 slider's travel changed 0…100 → 0…30 (amount 0…3). Positions arrive
        // clamped to the *legacy* ceiling (see `DetailSettings.position(in:_:)`), so the conversion
        // has to happen here, where the document's version is known: `/10` keeps the amount — i.e.
        // the look — and touches nothing but `detail`. The `clamped()` after it then brings every
        // axis back inside its own travel (a hand-edited schema-6 `detail: 100` becomes 30,
        // amount 3.0, rather than surviving as an out-of-range position).
        //
        // The version is stamped **only when a detail position was actually converted**, because
        // `/10` is not idempotent and this file's rule is that a document keeps its own version
        // number (`BlackLevelTests` pins "a schema-4 blob re-encodes byte for byte"). Without the
        // stamp, a migrated document saved back as schema 5 would be divided by ten again on the
        // next open — amount 1.0 → 0.1. A document with no `detailSettings.detail` is not stamped,
        // so its version *and* its bytes are untouched.
        if v.schemaVersion < 6, v.detailSettings.migratePreSchema6Detail() {
            v.schemaVersion = EditModel.currentSchemaVersion
        }
        v.detailSettings = v.detailSettings.clamped()
        // 派单 078/P0-10 (schema 9): `quarterTurns` does not exist below 9, and its default (0) is
        // the identity — so there is nothing to convert, and the stored crop rect keeps its meaning
        // (at 0 the turned frame *is* the file's frame). A hand-edited `quarterTurns` in a schema-8
        // blob is ignored on purpose: v8 documents were written by code that could not turn a
        // picture, and honouring the key would rotate a photograph its author never turned. The
        // version is not stamped — schema 7/8's rule — so a v8 document re-encodes byte for byte.
        if v.schemaVersion < 9 { v.geometry.quarterTurns = 0 }
        // 2026-10-28 (078 P0-1): `healSpots` is additive (schema 7/8/9's rule): an absent key reads
        // as `[]`, which is `hasHeal == false` and no S1.9 — so there is nothing to convert and the
        // version is not stamped. A spot read back from disk is clamped for the same reason
        // `detailSettings` is: a hand-edited `radius: 9` must not draw a disk the kernels cannot
        // express.
        v.healSpots = c.val("healSpots", v.healSpots).map(\.clamped)
        self = v
    }

    public static func load(from url: URL) throws -> EditModel {
        try JSONDecoder().decode(EditModel.self, from: Data(contentsOf: url))
    }

    /// Written by hand for **one** reason, the `LightGroup`/`ColorGroup` rule at document scale:
    /// `colorGrading` is **absent** from a neutral document, so a schema-8 blob re-encodes byte for
    /// byte and the new key appears only in a document that actually uses the card.
    ///
    /// Everything else is written exactly as the synthesised conformance wrote it — every field, in
    /// declaration order, optionals via `encodeIfPresent` and `masks` as an array (an empty `masks`
    /// still encodes as `[]`). The encoder this build uses sorts keys, so the order below is not what a
    /// reader sees; it is what keeps this function readable against the property list.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(schemaVersion, forKey: AnyCodingKey("schemaVersion"))
        try c.encode(processVersion, forKey: AnyCodingKey("processVersion"))
        try c.encode(geometry, forKey: AnyCodingKey("geometry"))
        try c.encode(light, forKey: AnyCodingKey("light"))
        try c.encode(curve, forKey: AnyCodingKey("curve"))
        try c.encode(color, forKey: AnyCodingKey("color"))
        if !colorGrading.isIdentity {
            try c.encode(colorGrading, forKey: AnyCodingKey("colorGrading"))
        }
        try c.encode(detail, forKey: AnyCodingKey("detail"))
        try c.encode(detailSettings, forKey: AnyCodingKey("detailSettings"))
        try c.encodeIfPresent(decoderVersion, forKey: AnyCodingKey("decoderVersion"))
        try c.encode(effects, forKey: AnyCodingKey("effects"))
        try c.encode(optics, forKey: AnyCodingKey("optics"))
        try c.encode(masks, forKey: AnyCodingKey("masks"))
        try c.encodeIfPresent(showMaskID, forKey: AnyCodingKey("showMaskID"))
        // 2026-10-28 (078 P0-1): written **only when non-empty** (the `colorGrading` rule), so a
        // document without a spot re-encodes byte for byte.
        if !healSpots.isEmpty {
            try c.encode(healSpots, forKey: AnyCodingKey("healSpots"))
        }
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
                || light.whiteLevel != old.light.whiteLevel
                || light.blackOffset != old.light.blackOffset {
                s.insert(.sceneLinear)
            }
            if light.contrast != old.light.contrast
                || light.highlights != old.light.highlights
                || light.midtones != old.light.midtones
                || light.shadows != old.light.shadows {
                s.insert(.toneMap)
            }
        }
        if curve != old.curve { s.insert(.curve) }
        // 076: the color group is two stages now — `bands` is S3.6's, `vibrance`/`saturation` are
        // S3's — so a band drag must not report `.color` (S3 would re-run and produce the same pixels)
        // and a saturation drag must not report `.hsl` (S3.6 would re-run for nothing).
        //
        // 2026-10-28: it is three. 黑白's material is the switch plus `bands[i].mix`, so a mix drag
        // dirties S3.4 and nothing else — not S3.6 (which does not read it) and not S3 (which does not
        // read the band table at all).
        if color != old.color {
            if color.vibrance != old.color.vibrance || color.saturation != old.color.saturation {
                s.insert(.color)
            }
            // Counts are always `ColorGroup.bandCount` after `normalize`, but zip is what makes this
            // impossible to get wrong if a hand-written document ever says otherwise.
            let hslMoved = zip(color.bands, old.color.bands).contains {
                $0.hue != $1.hue || $0.saturation != $1.saturation || $0.luminance != $1.luminance
            }
            // 101: the ninth selector (「全局」) writes its own triplet — S3.6 is the only stage that
            // reads it, so it dirties exactly the stage the eight bands do.
            if hslMoved || color.global != old.color.global { s.insert(.hsl) }
            let mixMoved = zip(color.bands, old.color.bands).contains { $0.mix != $1.mix }
            if color.blackAndWhite != old.color.blackAndWhite || mixMoved { s.insert(.bw) }
        }
        // 2026-10-28 (P0 色彩分级): S3.8's own group. One stage reads all nine numbers, so the whole
        // group is one dirty bit — and the split matters the same way 076's did: a grade drag must not
        // report `.hsl` (S3.6 reads none of the nine) and a band drag must not report `.grade`.
        if colorGrading != old.colorGrading { s.insert(.grade) }
        if effects != old.effects {
            // 2026-10-28: the card is two stages. A vignette drag must not miss a cached grain (S3.7
            // reads none of those four numbers) and a grain drag must not re-run S3c — the same split
            // 076 made for Color's two stages.
            if effects.vignetteAmount != old.effects.vignetteAmount
                || effects.vignetteMidpoint != old.effects.vignetteMidpoint
                || effects.vignetteFeather != old.effects.vignetteFeather
                || effects.vignetteRoundness != old.effects.vignetteRoundness {
                s.insert(.vignette)
            }
            if effects.grain != old.effects.grain
                || effects.grainSize != old.effects.grainSize
                || effects.grainRoughness != old.effects.grainRoughness
                || effects.grainSeedValue != old.effects.grainSeedValue {
                s.insert(.grain)
            }
            // 2026-10-28 (P0-6): the card's third block is a third stage — S3.8 reads the three detail
            // numbers and none of the vignette/grain ones, so a clarity drag must dirty S3.8 alone.
            if effects.texture != old.effects.texture
                || effects.clarity != old.effects.clarity
                || effects.dehaze != old.effects.dehaze {
                s.insert(.detailFX)
            }
        }
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
        // 2026-10-28 (078 P0-1): S1.9 reads the spot list and nothing else, so one group is one dirty
        // bit. A spot's centre, radius, source offset, mode, feather or opacity all move it — and
        // adding or deleting a spot moves it too, because the list *is* the material. `HealSpot`
        // compares at the key-material resolution (see `EditParameters.areEqual(_:_:)` for the list).
        if healSpots != old.healSpots { s.insert(.heal) }
        return s
    }

    /// Canonical text for the parameters a given stage consumes. Fed into the cache-key chain;
    /// must stay stable and order-independent across processes (no dictionary iteration).
    ///
    /// P1f (079 §2.7.1): the text also names **which generation of that stage's arithmetic** produced
    /// the pixels (`StageAlgorithmVersion`, appended as `;alg=N`). Parameters alone cannot separate two
    /// kernels that read the same numbers and compute different pixels — which is how a replaced
    /// contrast curve stayed servable under an unchanged key. The token is unconditional, so a key
    /// string always answers "which algorithm wrote this", not only after the first bump; the one-time
    /// re-recording of the pinned vectors (`MaskTests`, `WindowTests`) is the price and it is paid here.
    public func keyMaterial(_ stage: RenderStage) -> String {
        keyMaterial(stage, algorithmVersion: true)
    }

    /// `algorithmVersion: false` drops the `;alg=N` token, i.e. rebuilds the **pre-P1f material**
    /// byte for byte. **Never false in the app.**
    ///
    /// `CacheVersionTests.testRemovingTheVersionFromTheKeyMaterialMakesTheClaimFail` sets it and shows
    /// what a key that does not name its own arithmetic does: the old key and the new key become the
    /// same string, which is exactly the bug (a replaced contrast curve served from a stale file). A
    /// key whose load-bearing half cannot be switched off in a test is a key nobody can trust — the
    /// same discipline as `RenderGraph.s1KeyIncludesRedGroup`.
    public func keyMaterial(_ stage: RenderStage, algorithmVersion: Bool) -> String {
        material(stage) + (algorithmVersion ? StageAlgorithmVersion.token(stage) : "")
    }

    /// The parameters a stage reads, without the algorithm-version token of `keyMaterial`.
    ///
    /// Split out because the token is a property of the *kernel*, not of the document: nothing that
    /// asks "did the document move?" should see it (a version bump is not an edit).
    private func material(_ stage: RenderStage) -> String {
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
            // 2026-10-28 (P0-10): the 90° turn. Appended **only when non-zero**, the `asp`/`car`
            // discipline: every document that has never been turned keeps the pre-9 geometry
            // material byte for byte, so the pinned keys and the recorded goldens hold. When it is
            // non-zero the *frame* changes shape, which is why this is in the geometry link and not
            // a side channel — every stage after S0 has different pixels.
            if geometry.quarterTurns != 0 { s += ";q=\(geometry.quarterTurns)" }
            // 029: lateral CA. Appended **only when non-zero**, exactly like `asp`, so every document
            // that has never touched the CA sliders keeps the pre-029 geometry material byte for
            // byte — the seven pinned keys and every recorded golden depend on that.
            //
            // 084: the token is **integer tenths of a slider unit** (`;car=25` = position 2.5), not
            // `k()`'s `%.5f`. A 0.1 grid makes α a multiple of 5e-6 and `%.5f` cannot tell
            // `0.000005` from `0.000010` (both print `0.00001`), so two adjacent positions would
            // share a key and serve each other's frames. Documents already carrying a CA edit miss
            // once on the new token and rebuild to the same pixels — a deliberate, one-time cost.
            if optics.caRed != 0 { s += ";car=\(OpticsGroup.keyDeciles(forAlpha: optics.caRed))" }
            if optics.caBlue != 0 { s += ";cab=\(OpticsGroup.keyDeciles(forAlpha: optics.caBlue))" }
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
            // 071: appended **only when non-zero**, the `asp`/`car`/`blL` discipline. A document that
            // never used the trim keeps the S1 material of every document written before 071 byte for
            // byte — the pinned vectors in `WindowTests` / `MaskTests` and every recorded golden depend
            // on it. `boff` is the clamped value, i.e. the number the kernel actually adds.
            if light.blackOffset != 0 { m += ";boff=\(k(light.clampedBlackOffset))" }
            return m

        // S1.5 / S1.6 carry two different materials on purpose: `adjustments` must not be able to
        // rebuild the atlas (§3.3 item 4), and `name` is in neither.
        case .maskAtlas:
            return "masks=\(maskSelectionMaterial)"

        case .localApply:
            return "local=\(maskApplyMaterial)"

        case .heal:
            // 2026-10-28 (078 P0-1): S1.9's own material — every spot's geometry and mode, in
            // composition order, and nothing else. Same belt-and-braces shape as `.hsl`/`.bw`: a log
            // line names what wrote the pixels, and a spot's radius or source offset moving must move
            // this key (and, through the chain, every key below it).
            return "heal=[\(healSpots.map(\.keyString).joined(separator: "@"))]"

        case .localColor:
            // 056: S3.5's own material. Redundant with the chain above it on purpose — the chain
            // already carries `maskApplyMaterial`, so a selection change moves this key too — but a
            // stage key that names the values it reads cannot silently stop tracking them if the
            // S1.6 material is ever narrowed.
            return "localcolor=\(localColorMaterial)"

        case .toneMap:
            // Contrast and the three region lifts only — the whites/blacks levels moved into the
            // `.sceneLinear` material with the maths (派单 019), so a level change must not be able to
            // miss a cached S1 output by landing in this key instead.
            //
            // 085: `md` is appended **only when non-zero**, the `asp`/`car`/`q` discipline, so a
            // document that never touched 中间调 keeps its pre-085 tone-map material byte for byte.
            var m = "con=\(k(light.contrast));hi=\(k(light.highlights));sh=\(k(light.shadows))"
            if light.midtones != 0 { m += ";md=\(k(light.midtones))" }
            return m

        case .curve:
            return curve.keyString

        case .color:
            // 076: **vibrance and saturation only.** The eight bands left this stage for S3.6, where they
            // run in OKLCh in the display-referred domain; keeping them in this material would make an
            // HSL drag miss S3 — a pass that no longer reads them — for nothing. `hsl=` below carries
            // them instead, so a band move misses exactly S3.6 and what follows it.
            return "vib=\(k(color.vibrance));sat=\(k(color.saturation))"

        case .hsl:
            // 派单 076: S3.6's own material — the 24 band numbers and nothing else (vibrance and
            // saturation are S3's). Same shape as `.localColor`: a stage key that names the values it
            // reads cannot silently stop tracking them.
            return "hsl=\(color.hslKeyString)"

        case .bw:
            // 2026-10-28 (P0-4): S3.4's own material — the switch and the eight mixes, nothing else
            // (the three HSL axes are S3.6's, and a mix value must not be able to move S3.6's key).
            // Naming the switch is redundant with the link's existence, on purpose: the same
            // belt-and-braces `bw=1` the reader of a log line needs to see why the stage is there.
            return "bw=\(color.blackAndWhite ? 1 : 0);\(color.bwMixKeyString)"

        case .vignette:
            return effects.keyString

        case .grain:
            // 2026-10-28: S3.7's own material — amount, size, roughness and the seed (as the integer
            // the kernel hashes). Same shape as `.hsl`/`.localColor`: a stage key that names the values
            // it reads cannot silently stop tracking them, and a seed change must move it.
            return effects.grainKeyString

        case .grade:
            // 2026-10-28 (P0 色彩分级): S3.8's own material — the nine numbers and nothing else. Same
            // belt-and-braces shape as `.hsl`/`.bw`: a log line names what wrote the pixels.
            return colorGrading.keyString
        case .detailFX:
            // 2026-10-28 (P0-6): S3.8's own material — the three numbers and nothing else.
            return effects.detailFXKeyString

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
    /// 90° rotation: **how many clockwise quarter turns the picture has been turned**, 0…3.
    ///
    /// This is the whole feature and it is one field, not two: the export already describes a
    /// picture's orientation as `XMPOrientation(quarterTurns:mirrored:)` (§ orientation algebra,
    /// `XMP.swift`), and that same `quarterTurns` is what `tiff:Orientation` is written from. A
    /// second "rotation for the editor" would let the editor and the sidecar disagree about which
    /// way is clockwise, so there is exactly one number and both sides read it.
    ///
    /// Semantics, in the order the user thinks:
    ///   · the **frame** turns clockwise by `quarterTurns · 90°` — the output's width and height
    ///     swap when it is odd (`orientedSource(_:)`, `outputPixels(in:)`);
    ///   · `crop` is measured **in the turned frame** — the picture the user sees and crops — so
    ///     `turn(clockwise:)` rewrites it (`CropMath.turnedClockwise`), and the crop keeps covering
    ///     the same pixels of the photograph;
    ///   · `flipHorizontal/flipVertical` and `rotationDegrees` act *inside* that frame (a flip flips
    ///     what you see; a straighten straightens the horizon you see);
    ///   · the **kernel** un-turns the position on its way to the source, between the straighten and
    ///     the crop affine (`s0_geometry.metal`): the crop rect is a rectangle of the turned picture,
    ///     and the file's pixels are not turned.
    ///
    /// Always 0…3 — `init(from:)` and `turn(clockwise:)` normalise it, so the key material, the
    /// migration and `tiff:Orientation` never have to think about 4 or −1. A document with 0 keeps
    /// the pre-9 bytes, the pre-9 key and the pre-9 pixels (schema 9's only data change is this
    /// field, and its default is the identity).
    public var quarterTurns: Int

    public static let identity = GeometryGroup(crop: .full, rotationDegrees: 0,
                                               flipHorizontal: false, flipVertical: false,
                                               aspectLock: .original, quarterTurns: 0)

    public init(crop: NormalizedRect = .full,
                rotationDegrees: Double = 0,
                flipHorizontal: Bool = false,
                flipVertical: Bool = false,
                aspectLock: AspectLock = .original,
                quarterTurns: Int = 0) {
        self.crop = crop
        self.rotationDegrees = rotationDegrees
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.aspectLock = aspectLock
        self.quarterTurns = GeometryGroup.normalizedQuarterTurns(quarterTurns)
    }

    /// `n % 4` into `0…3` — the one place a turn count is made legal.
    public static func normalizedQuarterTurns(_ n: Int) -> Int { ((n % 4) + 4) % 4 }

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
        v.quarterTurns = GeometryGroup.normalizedQuarterTurns(
            c.val("quarterTurns", v.quarterTurns))
        self = v
    }

    /// Written key by key for one reason: **`quarterTurns: 0` must not appear in the blob.**
    ///
    /// The synthesized encoder would write every stored property, and that would break the rule this
    /// file is built on (`blackOffset`, `temperature`, `blackAndWhite` all follow it): a document
    /// written before schema 9 has to re-encode **byte for byte**, and every neutral document would
    /// otherwise grow a `"quarterTurns" : 0` key the moment this build saved it. So the key is
    /// written only when the document is actually turned — the same discipline as the geometry key
    /// material's `;q=`, which is what keeps the pixels, the bytes and the cache in one story.
    /// `BlackLevelTests.testAPreBlackOffsetDocumentReadsAsZeroAndReEncodesByteForByte` pins it.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(crop, forKey: AnyCodingKey("crop"))
        try c.encode(rotationDegrees, forKey: AnyCodingKey("rotationDegrees"))
        try c.encode(flipHorizontal, forKey: AnyCodingKey("flipHorizontal"))
        try c.encode(flipVertical, forKey: AnyCodingKey("flipVertical"))
        try c.encode(aspectLock, forKey: AnyCodingKey("aspectLock"))
        if quarterTurns != 0 { try c.encode(quarterTurns, forKey: AnyCodingKey("quarterTurns")) }
    }

    // MARK: explicit crop / straighten semantics

    /// The source's pixel dimensions **as the turned frame sees them**: swapped when the quarter
    /// turn is odd.
    ///
    /// Everything that measures the picture in its own grid — the aspect lock's ratio, the crop's
    /// pixel size, the fit zoom — has to use this and not the decode's size, or a 3:2 crop of a
    /// turned frame would be fitted to 3:2 *of the portrait frame* and reshaped.
    public func orientedSource(_ source: ImageSize) -> ImageSize {
        quarterTurns % 2 == 1
            ? ImageSize(width: source.height, height: source.width)
            : source
    }

    /// The cropped picture's pixel size in the **turned** frame — 「裁剪后尺寸」, and the frame the
    /// renderer allocates.
    ///
    /// One call site per consumer: `CropMath.outputSize(renderCrop(source:), in: source)` is the
    /// pre-9 spelling and is *wrong* for an odd turn (the rect is measured in the turned frame, so
    /// its width is a fraction of the turned width). This is the same two calls with the turned
    /// size in the second one, kept in one place so no caller can forget the swap.
    public func outputPixels(in source: ImageSize) -> ImageSize {
        CropMath.outputSize(renderCrop(source: source), in: orientedSource(source))
    }

    /// One quarter turn, as a mutation of the document's geometry: the frame turns and the crop
    /// turns with it (`CropMath.turnedClockwise`), so the crop keeps covering the same pixels of the
    /// photograph.
    ///
    /// The aspect lock is inverted, not dropped: its ratio is in **pixels**, and the pixels have
    /// just swapped axes, so a 3:2 crop of a turned frame is a 2:3 rectangle (`AspectLock.matching`
    /// names it — 3:2 → `custom 0.667`, 1:1 → 1:1, `.original` → no constraint). Leaving the lock at
    /// 3:2 would let `renderCrop` reshape the rect and the "same pixels" promise would be gone at
    /// the very next render, which is the same bug class as not turning the rect at all.
    public mutating func turn(clockwise: Bool) {
        quarterTurns = GeometryGroup.normalizedQuarterTurns(quarterTurns + (clockwise ? 1 : 3))
        let turned = clockwise ? CropMath.turnedClockwise(cropRect)
                                : CropMath.turnedCounterClockwise(cropRect)
        crop = turned.normalizedRect
        if let ratio = aspectLock.ratio {
            aspectLock = AspectLock.matching(ratio: 1 / ratio)
        }
    }

    /// `turn(clockwise:)` `quarterTurns` times, clockwise — the export side's door to the same
    /// mutation, so a turn requested at export and a turn requested in the editor are the same code
    /// path and cannot disagree about the crop.
    public func turned(by count: Int) -> GeometryGroup {
        var g = self
        for _ in 0..<GeometryGroup.normalizedQuarterTurns(count) { g.turn(clockwise: true) }
        return g
    }

    /// The crop in the **file's own** (pre-turn) frame — what `crs:Crop*` is written from, because
    /// `tiff:Orientation` already carries the turn (see `XMP.swift` 1.2). The inverse of the map
    /// `turn(clockwise:)` applies, so reading a sidecar back gives the same picture.
    public var sourceCrop: CropRect {
        CropMath.sourceRect(cropRect, quarterTurns: quarterTurns)
    }

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
    ///
    /// Measured in the **turned** frame (schema 9): the lock's ratio is a pixel ratio, so it is
    /// fitted against `orientedSource`, and the rect stays a rectangle of the picture the user sees.
    /// At `quarterTurns == 0` this is byte for byte the pre-9 call.
    public func renderCrop(source: ImageSize) -> CropRect {
        CropMath.lockedCrop(aspectLock, in: cropRect, source: orientedSource(source)).clamped()
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
    /// 085 — the middle zone of S2's three-window lift, between `shadows` and `highlights`.
    /// Same envelope and direction as the other two (`+` brightens, `−` pulls down); unlike the old
    /// two-window layout there is no band between the sliders where none of them acts.
    public var midtones: Double          // -100…100, default 0
    public var shadows: Double           // -100…100, default 0
    /// 073B — the **white end point**: ±0.6 EV plus a small additive level (0.06 at full travel,
    /// quadratic so a short travel is nearly pure EV), over a 2 EV window that ends at display white
    /// and decays above it (shoulder). Both terms ride the same weight, so nothing moves below −2 EV.
    ///
    /// It used to be an affine level (`wht = 1 − whites/100·0.15`, 派单 019), which brightened the
    /// whole picture and moved the mid-tones; `+` still means "up", the shape is what changed. The
    /// affine spelling now belongs only to `whiteLevel` below, where "this sample is white" is a level.
    public var whites: Double            // -100…100, default 0; + moves the white point up
    /// 073B/073C — the **black end point**: half the travel is a multiplicative EV on the dark end
    /// (`0 → 0`), the second half blends in a black-point **level** move so the black end can really
    /// be moved — pushed down it reaches 0, pulled up it floats off the floor.
    ///
    ///     t = blacks/100,  a = |t|,  m = smoothstep(0.5, 1, a)
    ///     EV:    v *= exp2(3 · t · (1 − ½m) · wb)      wb = the 7 EV toe (full below −11.2 EV, 0 at −4.2)
    ///     level: v  = toe(v + 0.005 · t · m · wl)      wl = a 2.5 EV window, −6.9 … −4.4 EV, C¹ clip at 0
    ///
    /// Why the second half exists: a pure multiplier cannot move the black *point* (`0 → 0` for every
    /// gain), so `blacks = −100` used to leave the darkest pixels at 1/8 of their value — never at 0 —
    /// and `blacks = +100` could never float the black off the floor. The owner's brief (2026-10-27)
    /// was 「滑块开始为加减 EV，后面逐步变为修改电平」, which is exactly this blend. `m` is 0 for the
    /// whole first half, so `|blacks| ≤ 50` is 073B's arithmetic bit for bit (and `RenderGraph` even
    /// picks 073B's entry point there — see `blacksEVToLevelSplit`).
    ///
    /// It used to be an affine level (`blk = −blacks/100·0.15`), which moved every pixel, including
    /// 50 % grey — that is not what the control is for. The affine spelling now belongs only to
    /// `blackLevel` below, where "this sample is black" really is a level. `+` still lifts the shadows.
    public var blacks: Double            // -100…100, default 0

    /// 073C — where the travel switches mechanism, `|blacks| = 50`.
    ///
    /// Not a taste knob: it is the zero of the blend factor `m(a) = smoothstep(0.5, 1, a)`, so below it
    /// the level term is *exactly* zero and the kernel's 073B instantiation is the correct one. Moving
    /// this number without moving `m` would put a discontinuity in the middle of the slider; moving
    /// both would change the first half of the travel, which is pinned to be bit-identical.
    public static let blacksEVToLevelSplit: Double = 50
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
    /// here"), or `nil` = no absolute level at all (派单 030).
    ///
    /// Since 073B this is the *only* affine level left in S1, and it is the dropper's spelling on
    /// purpose: a sampled "this is black" means "make this value 0", which is a level and nothing else.
    /// The `blacks` slider is a different animal (an EV window over the dark end), so the two never
    /// coexist in one document — `levels` picks this field when it is set, and the UI clears it when the
    /// slider is dragged.
    ///
    /// Why an absolute value exists at all: a slider's travel cannot express an HDR white point. A
    /// `whiteLevel` of 2.0 (a +1 EV highlight) is not reachable by `wht ∈ [0.85, 1.15]`.
    public var blackLevel: Double?
    /// Absolute white level in scene-linear light; `nil` = no absolute level. Same rules as
    /// `blackLevel`, with `white ≥ black + 1e−3` enforced on the pair.
    public var whiteLevel: Double?

    /// 派单 071 — an **additive** black trim in scene-linear units: +0.01…−0.01, default 0.
    ///
    /// A third spelling of "where black is", and deliberately not a replacement for the other two:
    /// `blacks` is a coarse level (±0.15, and it also moves the white point's span) and `blackLevel`
    /// is an absolute dropper reading. This one is the fine trim the user asked for —「让 0 值变为
    /// ±0.01」— with 1/1000 granularity, and it is the only control that can lift the decoder's own
    /// negative samples back across zero without moving where 0 and 1 are:
    ///
    ///     v = (v − blk)/span + blackOffset        // S1, between the levels and the gain
    ///
    /// It is additive and it sits **before the exposure gain**, so the trim is scaled by the same
    /// gain the negative samples are: +0.01 at +2 EV lifts +0.04. That is what makes `+` pull the
    /// shadows out of the "the more exposure, the blacker they get" hole.
    ///
    /// The slider is an **integer** −10…+10 and the document stores `slider / 1000` (a Double, so
    /// `0.002` is expressible without a second unit in the model). `LightGroup.blackOffset(slider:)`
    /// and `sliderPosition` are the only mapping.
    public var blackOffset: Double

    public static let identity = LightGroup()

    /// The envelope of the additive trim, in scene-linear light. ±0.01 is what the user asked for
    /// (「可选到 −10 和 +10，对应于让 0 值变为 −0.01 以及 +0.01」); it is also about as far as an
    /// additive trim can go on a 0…1 scene before it turns black into grey.
    public static let blackOffsetRange: ClosedRange<Double> = -0.01...0.01
    /// The slider's travel: integers only, 0 in the middle (`slider / 1000` = the document value).
    public static let blackOffsetSliderRange: ClosedRange<Double> = -10...10

    /// The envelope the level fields are clamped into (`§7.1`): a black sample below −3 EV is noise,
    /// and a white above +4 EV is past the far end of the curve's axis (the shaper keeps going at the
    /// last slope, but nothing above it can be labelled — 044 moved the end from +6 to +4 EV; the
    /// envelope itself stays where §7.1 put it, so old documents still load).
    public static let blackLevelRange: ClosedRange<Double> = -0.05...0.5
    public static let whiteLevelRange: ClosedRange<Double> = 0.05...64

    public init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0,
                midtones: Double = 0, shadows: Double = 0, whites: Double = 0, blacks: Double = 0,
                temperature: Double? = nil, tint: Double? = nil, highlightRecovery: Double = 0,
                blackLevel: Double? = nil, whiteLevel: Double? = nil,
                blackOffset: Double = 0) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.midtones = midtones
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.temperature = temperature
        self.tint = tint
        self.highlightRecovery = highlightRecovery
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
        self.blackOffset = blackOffset
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = LightGroup.identity
        v.exposure = c.val("exposure", v.exposure)
        v.contrast = c.val("contrast", v.contrast)
        v.highlights = c.val("highlights", v.highlights)
        v.midtones = c.val("midtones", v.midtones)
        v.shadows = c.val("shadows", v.shadows)
        v.whites = c.val("whites", v.whites)
        v.blacks = c.val("blacks", v.blacks)
        v.temperature = c.val("temperature", v.temperature)
        v.tint = c.val("tint", v.tint)
        v.highlightRecovery = c.val("highlightRecovery", v.highlightRecovery)
        v.blackLevel = c.val("blackLevel", v.blackLevel)
        v.whiteLevel = c.val("whiteLevel", v.whiteLevel)
        // 071: an absent key is 0 — the pre-071 document's meaning, and the identity of the trim.
        v.blackOffset = c.val("blackOffset", v.blackOffset)
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
        try c.encode(midtones, forKey: AnyCodingKey("midtones"))
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
        // 071: **absent at 0**, not `"blackOffset": 0` — a document that never touched the control
        // re-encodes byte for byte (the `temperature`/`tint`/`blackLevel` rule). It is the same
        // discipline the kernel follows: the default path is not "the old path plus zero", it is the
        // old path.
        if blackOffset != 0 { try c.encode(blackOffset, forKey: AnyCodingKey("blackOffset")) }
    }

    public var isIdentity: Bool { self == LightGroup.identity }

    /// The black level the `blacks` slider *used to* ask for, `blk = −blacks/100·0.15` (派单 019).
    ///
    /// 073B kept the arithmetic and stopped using it for the picture: the slider is an EV window now,
    /// so this value only reaches `levels` (and from there the curve panel's reference line and the
    /// `blL`/`whL` key tokens). Reading it as "where black is" would be wrong for a 073B document; it
    /// is here because `LevelPair` is still the one place the *dropper's* level is reconciled.
    public var sliderBlackLevel: Double { -blacks / 100 * 0.15 }

    /// The white level the `whites` slider used to ask for, `wht = 1 − whites/100·0.15`. See
    /// `sliderBlackLevel`.
    public var sliderWhiteLevel: Double { 1 - whites / 100 * 0.15 }

    // MARK: - 071: the additive linear trim's mapping

    /// 071 — slider position → document value: **exactly** `position / 1000`, described on a
    /// **0.1-step** position (−10.0…+10.0).
    ///
    /// `Double(n) / 1000.0` rather than `n * 0.001`: the division is correctly rounded, so `10` gives
    /// the double nearest 0.01 (i.e. the literal `0.01`) and every step is a 1/1000 tick of the same
    /// value. The panel has no `step:` (SwiftUI would draw tick marks), so the quantization lives
    /// here: the position is snapped to a tenth of a tick (`0.1`, i.e. a 1/10 000 of linear light),
    /// which is what the owner asked for — 「取值范围是 −10 到 10，但不是只能取整数」.
    public static func blackOffset(fromSlider position: Double) -> Double {
        guard position.isFinite else { return 0 }
        let tick = min(max((position * 10).rounded() / 10, blackOffsetSliderRange.lowerBound),
                       blackOffsetSliderRange.upperBound)
        return tick / 1000
    }

    /// The slider position this document asks for — the inverse of `blackOffset(fromSlider:)`, on the
    /// same 0.1-step grid so the knob does not wobble around a value the row cannot print.
    public var blackOffsetSliderPosition: Double { (blackOffset * 1000 * 10).rounded() / 10 }

    /// The same position for any light group — the panel's binding reads it, so the knob and the model
    /// can never disagree on the grid.
    public static func blackOffsetSliderPosition(of light: LightGroup) -> Double {
        (light.blackOffset * 1000 * 10).rounded() / 10
    }

    /// The trim as the kernel gets it: clamped into the envelope, so a hand-edited document cannot
    /// push the linear buffer around by more than ±0.01.
    public var clampedBlackOffset: Double {
        guard blackOffset.isFinite else { return 0 }
        return min(max(blackOffset, LightGroup.blackOffsetRange.lowerBound),
                   LightGroup.blackOffsetRange.upperBound)
    }

    /// Where 0 and 1 are, after the absolute fields and the sliders are reconciled.
    ///
    /// One answer, one place: S1's `kLevels` entry point, the level droppers and the curve panel's
    /// reference lines all read this, so "which black point is in force" cannot be answered two ways.
    ///
    /// 073B: the **slider** half is legacy arithmetic. The sliders are EV windows now and never reach
    /// S1 as a level, so for a document without a dropper these numbers describe where an *019-era*
    /// document's level would have been — the flags in S1's `d` are 0, so the kernel ignores them. The
    /// curve panel's reference line still draws them; that is a follow-up ticket (the line should show
    /// the window, not the old level), not a second black point.
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
    /// **Nothing in the shipping pipeline uses this.** Since 派单 006 the document's Kelvin/tint go
    /// to `CIRAWFilter` and `RenderGraph`'s S1 pass runs with (1, 1, 1), because the decode has
    /// already balanced the pixels; multiplying again would apply the correction twice. It was also
    /// the mask's fit until 079 A3 — and that is why it is still here: it is the **encoded** body (it
    /// divides the 0…255 gamma-encoded black-body colour), the one that is 2.2× too weak in linear
    /// light, and `LocalWhiteBalanceTests` uses it as the counter-proof that the R/B parity assertion
    /// is falsifiable. The mask's WB is `WhiteBalanceSolver.localGain` now — the same `gain` the
    /// global solver predicts with.
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
/// The point lists keep their shape and `CurvePoint.linear` — only the meaning of the y axis
/// changed, which is exactly what `processVersion` 2 records (§10.1). (069 then moved the *storage* to
/// doubles on `0…2` — `0…1` SDR, `1…2` HDR — and the table converts with `u = x/2`; the coordinate the
/// table sees is still 0…1 and unchanged.) Old documents keep
/// their control points and get a different rendering; that is the declared migration, not a bug.
public struct CurveGroup: Sendable, Equatable, Codable {
    /// What the numbers in this group mean, written with every document (派单 069).
    ///
    /// ```json
    /// "curve": { "format": {"version":1,"type":"int","max":511,"domain":"hdr"},
    ///            "white": [{"x":0,"y":0},{"x":112,"y":87},…], "red": …, "green": …, "blue": … }
    /// ```
    ///
    /// **Why `domain: "hdr"` matters more than the other three fields.** A curve point is a coordinate
    /// on the *axis*, not a display value: since 030 the axis is `HDRCurveAxis` (log-light, +0…+4 EV
    /// above display white, half the card each) and the table it feeds runs at S1.7 on **scene-linear
    /// HDR** data. A file that said only "0…255" would be describing a display-referred curve and a
    /// future reader would be entitled to re-interpret the same integers against an SDR axis — a silent
    /// change of rendering. `domain` is what makes that illegal: the numbers below are HDR-axis
    /// coordinates, and a reader that works in another domain must convert, not re-read.
    ///
    /// ```json
    /// "curve": { "format": {"version":2,"type":"double","max":2,"domain":"hdr"},
    ///            "white": [{"x":0,"y":0},{"x":0.44,"y":0.34},…], "red": …, "green": …, "blue": … }
    /// ```
    ///
    /// **Migration rule (docs/architecture-decisions.md §069).** Any change to what `x`/`y` mean — the
    /// grid's size, the type, the axis' shape — bumps `version`. A reader that meets a version it does
    /// not know must not guess (see `CurveGroup.init(from:)`); a reader that meets a known version with
    /// a different `max` rescales instead of truncating.
    ///
    public struct CurveFormat: Sendable, Equatable, Codable {
        /// `"double"` — the only type version 2 has.
        public static let doubleType = "double"
        /// `"hdr"` — the axis the coordinates live on (see the note above).
        public static let hdrDomain = "hdr"

        /// 2 = `0…2` doubles, `0…1` SDR (code) and `1…2` HDR (EV). 1 = the transient integer grid
        /// (`0…max` cells) that existed inside this order and never shipped.
        public var version: Int
        /// `"double"`. Version 1 wrote `"int"`.
        public var type: String
        /// The coordinate's upper bound: `2` for version 2, `511` for version 1.
        ///
        /// `max` is **this implementation's** bound, not a property of the formula: `EV = (x − 1)·4`
        /// keeps working above 2 (2.25 *is* +5 EV), so the day the axis grows to +5 EV the value here
        /// becomes `2.25` **and `version` goes to 3** — a reader of version 2 may keep assuming a
        /// two-stop-wide HDR half, and a reader that meets 3 must convert rather than clamp.
        public var max: Double
        /// `"hdr"` — the working domain, not a display domain.
        public var domain: String

        public init(version: Int = 2, type: String = CurveFormat.doubleType,
                    max: Double = CurvePoint.maximum, domain: String = CurveFormat.hdrDomain) {
            self.version = version
            self.type = type
            self.max = max
            self.domain = domain
        }

        /// What this build writes.
        public static let current = CurveFormat()
    }

    /// Diagnostics from decoding this group (069): a rescale, a refused future `version`, a `type` that
    /// is not `int`. **Not** part of the document and not part of `==` — it says how the value arrived,
    /// not what it is. `EditModel.load` leaves it on the loaded model, so a test, the CLI or a future
    /// "this file was migrated" notice can read it without a second parse.
    public var decodeWarnings: [String] = []

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
        var warnings: [String] = []
        // 069: the self-describing format block. A document without one predates it, and then the
        // points are the old `0…1` axis coordinates (`x·2` gets them onto this card).
        let format = (try? c.decodeIfPresent(CurveFormat.self, forKey: AnyCodingKey("format"))) ?? nil
        /// One number as it arrived, and what it means.
        enum Unit {
            /// Version 2: the coordinate itself, `0…2`.
            case coordinate
            /// Version 1 (transient, never shipped): an integer cell `0…max` on a `0…511` grid, which
            /// was the *axis*, i.e. `0…1`. `x_new = 2·cell/max`.
            case cells(max: Double)
            /// No block at all: the pre-069 `0…1` axis coordinate. `x_new = 2·v`.
            case legacyAxis
        }
        var unit = Unit.legacyAxis
        if let format {
            if format.version > CurveFormat.current.version {
                // A future version is **not** guessed at: the curve is dropped to the identity (which
                // renders, it is just neutral) and the rest of the document loads normally. Refusing
                // the whole photo because one group cannot be read would be a worse failure.
                v.decodeWarnings = ["curve.format version \(format.version) > \(CurveFormat.current.version): "
                                    + "曲线未加载（保持恒等），其余字段照常"]
                self = v
                return
            }
            unit = format.version <= 1 ? .cells(max: Swift.max(format.max, 1.0)) : .coordinate
            if format.version >= 2, format.type != CurveFormat.doubleType {
                warnings.append("curve.format type \"\(format.type)\" 不是 \"double\": 按 0…2 坐标读")
            }
            if format.version >= 2, format.max != CurvePoint.maximum {
                warnings.append("curve.format max \(format.max) ≠ \(CurvePoint.maximum): 按比例换算")
            }
        }
        /// One point as it arrived.
        struct RawPoint: Decodable {
            let x: Double
            let y: Double
            init(from decoder: any Decoder) throws {
                let d = try decoder.container(keyedBy: AnyCodingKey.self)
                x = d.val("x", 0)
                y = d.val("y", 0)
            }
        }
        func list(_ key: String) throws -> [CurvePoint]? {
            guard let raw = (try? c.decodeIfPresent([RawPoint].self, forKey: AnyCodingKey(key))) ?? nil else {
                return nil
            }
            let scale: Double
            switch unit {
            case .coordinate: scale = 1
            case .cells(let max): scale = CurvePoint.maximum / Swift.max(max, 1)
            case .legacyAxis: scale = CurvePoint.maximum
            }
            return try raw.map { try CurvePoint(validating: $0.x * scale, $0.y * scale) }
        }
        // 派单 030 / schema 4: `white` is the stored name; a schema-3 document says `rgb`. One line,
        // and the shape of the point list survives the rename untouched.
        v.white = try (list("white") ?? list("rgb")) ?? v.white
        v.red = try list("red") ?? v.red
        v.green = try list("green") ?? v.green
        v.blue = try list("blue") ?? v.blue
        v.decodeWarnings = warnings
        self = v
    }

    /// Only `white` is written: a document must not be able to carry both names.
    ///
    /// 069: the `format` block goes first and is written **every** time, so a file always says what its
    /// numbers mean. The four point lists follow in a fixed order — a fixed order and a fixed key set
    /// is what makes "write, read, write" byte-identical (`testTheCurveFormatBlockRoundTripsByteForByte`).
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(CurveFormat.current, forKey: AnyCodingKey("format"))
        try c.encode(white, forKey: AnyCodingKey("white"))
        try c.encode(red, forKey: AnyCodingKey("red"))
        try c.encode(green, forKey: AnyCodingKey("green"))
        try c.encode(blue, forKey: AnyCodingKey("blue"))
    }

    /// Equality is over the four point lists — **not** over `decodeWarnings`, which is a diagnostic of
    /// how this value arrived, not part of the document. Two documents with the same curve are equal
    /// whether or not one of them was migrated on the way in.
    public static func == (a: CurveGroup, b: CurveGroup) -> Bool {
        a.white == b.white && a.red == b.red && a.green == b.green && a.blue == b.blue
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

/// A curve coordinate outside the card (`0…2`) — thrown, never clamped, on the paths that read a
/// document or take an API value (派单 069).
///
/// The distinction is deliberate and load-bearing:
///
///   · **the interaction** clamps (`CurvePoint.clamped`), because a pointer cannot leave the plot;
///   · **a document or a caller** is told it is wrong, because silently moving a point and silently
///     dropping it are both ways to render a photo the file does not describe. `2.25` is the case this
///     exists for: it will mean **+5 EV** when the axis grows (the formula is `EV = (x − 1)·4`, not
///     "0…2 normalised to 0…4"), and today it is out of range rather than wrong.
public struct CurveCoordinateOutOfRange: Error, Equatable, CustomStringConvertible {
    public let value: Double
    /// `"x"` or `"y"`.
    public let axis: String

    public init(value: Double, axis: String) {
        self.value = value
        self.axis = axis
    }

    public var description: String {
        "曲线坐标 \(axis) = \(value) 超出 0…\(CurvePoint.maximum)"
            + "（当前只支持到 +4 EV；将来支持 +5 EV 时把最大值改成 2.25 并升 curve.format version）"
    }
}

public struct CurvePoint: Sendable, Equatable, Codable, Hashable {
    /// `x = 1` — display white. Below it the coordinate is a display code, above it an EV.
    public static let sdrBoundary = 1.0
    /// `x = 2` — +4 EV (the histogram's own tail, `HDRCurveAxis` 062). Fixed, never the display's
    /// headroom: the axis ends at +4 EV whatever the panel can show.
    public static let maximum = 2.0

    /// The input coordinate, `0…2`: **`0…1` is SDR** (`code = x·255`, `1` = display white) and
    /// **`1…2` is HDR** (`EV = (x − 1)·4`, `2` = +4 EV). 派单 069.
    ///
    /// Why two units in one number: the card's axis is the histogram's own (062) and the histogram's
    /// left half is display codes while its right half is stops. Splitting the field at `x = 1` makes
    /// the number readable on its own — `0.5` *is* code 128, `1.5` *is* +2 EV — so the panel needs no
    /// "SDR/HDR" label to say which half it is drawing, and the read-out is a multiplication rather
    /// than a table lookup.
    ///
    /// **The engine's coordinate is `u = x / 2`** (`CurveLUT`, `HDRCurveAxis`, the kernel): the axis
    /// has always been `0…1` with display white at `0.5` (062), so this is exactly twice it and the
    /// maths downstream is untouched (`CurveStorageTests.testTheNewCoordinateIsTwiceTheAxis` recomputes
    /// it for four points).
    public var x: Double
    /// The output coordinate, `0…2`, same split as `x`.
    public var y: Double

    /// The pair as the card means it, **clamped** into `0…2`. This is the interaction's space: the
    /// plot cannot hand a drag a coordinate it does not have, and a ⇧ lock can combine two in-box
    /// numbers into another in-box number, so clamping here cannot hide a mistake.
    ///
    /// A document or an API caller uses `init(validating:_:)`, which throws instead.
    public init(_ x: Double, _ y: Double) {
        self.x = min(max(x.isFinite ? x : 0, 0), CurvePoint.maximum)
        self.y = min(max(y.isFinite ? y : 0, 0), CurvePoint.maximum)
    }

    /// The pair from a **file or a caller**: out of range is an error, never a clamp (069).
    public init(validating x: Double, _ y: Double) throws {
        guard x.isFinite, x >= 0, x <= CurvePoint.maximum else {
            throw CurveCoordinateOutOfRange(value: x, axis: "x")
        }
        guard y.isFinite, y >= 0, y <= CurvePoint.maximum else {
            throw CurveCoordinateOutOfRange(value: y, axis: "y")
        }
        self.x = x
        self.y = y
    }

    /// From the engine's `0…1` axis coordinate back to the card's `0…2`.
    public init(u: Double, v: Double) {
        self.init(CurvePoint.cardCoordinate(u), CurvePoint.cardCoordinate(v))
    }

    /// `x` on the card → `u` on the engine axis. The card is **two halves** and the axis keeps the
    /// same split at any width (062/069): `0…sdrBoundary` fills `0…whiteU` and
    /// `sdrBoundary…maximum` fills `whiteU…1`.
    ///
    /// On today's card (`0…2`, `whiteU = 0.5`) this is **bit-identically** `x / 2` — a widening of the
    /// card must not move display white off the histogram's 50 %, which a bare `x / maximum` would do
    /// as soon as `maximum` grows (`CurveCoordinateOutOfRange`'s own note names `2.25`); the split is
    /// written down here once instead of as a `2` at each use site.
    /// `CurveStorageTests.testTheAxisMapIsStillXOverTwoToday` pins the bit-identity over 20 001 samples.
    public static func axisCoordinate(_ x: Double) -> Double {
        let white = HDRCurveAxis.standard.whiteU
        guard x > sdrBoundary else { return white * (x / sdrBoundary) }
        return white + (1 - white) * ((x - sdrBoundary) / (maximum - sdrBoundary))
    }

    /// The inverse of `axisCoordinate`: `u` on the axis → `x` on the card.
    public static func cardCoordinate(_ u: Double) -> Double {
        let white = HDRCurveAxis.standard.whiteU
        guard u > white else { return sdrBoundary * (u / white) }
        return sdrBoundary + (maximum - sdrBoundary) * ((u - white) / (1 - white))
    }

    /// The axis coordinate the table, the shaper and the kernel speak: `x / 2` on today's card, i.e.
    /// `CurvePoint.axisCoordinate(x)`.
    public var u: Double { CurvePoint.axisCoordinate(x) }
    /// The same for `y`.
    public var v: Double { CurvePoint.axisCoordinate(y) }

    /// Display code of an SDR-side coordinate, `0…255` (rounded) — for the read-out and the ticks.
    public static func code(_ x: Double) -> Int {
        min(max(Int((x * 255).rounded()), 0), 255)
    }

    /// A display code as a `0…1` coordinate.
    public static func from(code: Int) -> Double { Double(min(max(code, 0), 255)) / 255 }

    /// The black and white ends: no curve at all. `(0,0) … (2,2)` — zero light in, +4 EV out.
    public static let linear: [CurvePoint] = [CurvePoint(0, 0), CurvePoint(maximum, maximum)]

    /// The cache key's per-point spelling. Six decimals: the coordinate is continuous, and the key only
    /// has to answer "did the curve move".
    public var keyString: String { String(format: "%.6f,%.6f", x, y) }
}

/// Lightroom's Color panel: global saturation, vibrance, the eight HSL bands, and 黑白.
public struct ColorGroup: Sendable, Equatable, Codable {
    public var vibrance: Double      // -100…100, default 0
    public var saturation: Double    // -100…100, default 0
    /// Exactly eight bands, in Lightroom order: red, orange, yellow, green, aqua, blue, purple, magenta.
    public var bands: [HSLBand]
    /// 黑白 (2026-10-28, P0-4): Lightroom's 「黑白」 switch. `true` means S3.4 converts the colour
    /// image to monochrome; the per-hue weights that decide how bright each hue lands in the grey are
    /// `bands[i].mix`, on the **same** eight-band table the HSL panel edits.
    ///
    /// Written only when `true`, so a document that never used the switch re-encodes byte for byte
    /// (the `blackOffset` discipline) and reads back as the pre-S3.4 graph.
    public var blackAndWhite: Bool
    /// 101 — 全局: the ninth selector's triplet, applied **on top of** every band's own shift.
    ///
    /// Same units and travel as a band (`HSLBand`), but one value for all eight hues: 色相 and 饱和
    /// still ride the chroma gate (a grey has no hue to rotate and no colour to saturate), while 明度
    /// does not — the lightness axis is the one operation that is meaningful on a neutral pixel.
    ///
    /// All-zero is absent from the document's JSON and from the key material, so a document that never
    /// used the ninth button re-encodes byte for byte (the `blackAndWhite`/`blackOffset` discipline).
    /// Its `mix` field is never read: 黑白混合 is S3.4's, not this group's.
    public var global: HSLBand

    public static let bandCount = 8

    public static let identityBands: [HSLBand] = Array(repeating: HSLBand(), count: bandCount)

    public static let identity = ColorGroup()

    public init(vibrance: Double = 0, saturation: Double = 0,
                bands: [HSLBand] = ColorGroup.identityBands,
                blackAndWhite: Bool = false,
                global: HSLBand = HSLBand()) {
        self.vibrance = vibrance
        self.saturation = saturation
        self.bands = ColorGroup.normalize(bands)
        self.blackAndWhite = blackAndWhite
        self.global = global
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = ColorGroup.identity
        v.vibrance = c.val("vibrance", v.vibrance)
        v.saturation = c.val("saturation", v.saturation)
        v.bands = ColorGroup.normalize(c.val("bands", v.bands))
        v.blackAndWhite = c.val("blackAndWhite", v.blackAndWhite)
        // 101: additive — an absent key reads as the all-zero triplet, i.e. the pre-101 graph.
        v.global = c.val("global", v.global)
        self = v
    }

    /// Written by hand for one reason: `blackAndWhite` is **absent** when it is `false`, which is what
    /// keeps a schema-7 document's JSON byte-identical (§3.2 discipline, the `blackOffset` rule).
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(vibrance, forKey: AnyCodingKey("vibrance"))
        try c.encode(saturation, forKey: AnyCodingKey("saturation"))
        try c.encode(bands, forKey: AnyCodingKey("bands"))
        if blackAndWhite { try c.encode(blackAndWhite, forKey: AnyCodingKey("blackAndWhite")) }
        // 101: the ninth triplet is absent while it is all zero — the same "the new key appears only
        // in a document that uses it" rule the switch above follows.
        if !global.isIdentity { try c.encode(global, forKey: AnyCodingKey("global")) }
    }

    /// Tolerate hand-written or future documents: always eight bands, missing ones identity.
    static func normalize(_ bands: [HSLBand]) -> [HSLBand] {
        var out = Array(bands.prefix(bandCount))
        while out.count < bandCount { out.append(HSLBand()) }
        return out
    }

    /// The whole group is default — **not** the predicate any of the three stages uses. Since 076 the
    /// group feeds S3 (`vibrance`/`saturation`) and S3.6 (`bands`); since 2026-10-28 it also feeds
    /// S3.4 (`blackAndWhite` + `bands[i].mix`). This one stays what it always was: "this panel has
    /// nothing in it".
    public var isIdentity: Bool {
        vibrance == 0 && saturation == 0 && !blackAndWhite && global.isIdentity
            && bands.allSatisfy { $0.isIdentity }
    }

    /// True when any of the 24 HSL numbers (hue/saturation/luminance) is non-zero — the predicate
    /// 派单 076 makes by **value**, never by "the color group exists": S3.6 must not appear in the
    /// pipeline for a document whose bands are all 0, or the pre-076 trace, key chain and pixels would
    /// move.
    ///
    /// A `mix` value is deliberately **not** one of the 24: S3.6 reads only the three HSL axes, so a
    /// document whose only band values are mixes must not encode S3.6 for nothing (the same split 076
    /// made between `vibrance`/`saturation` and `bands`).
    public var hasBands: Bool { bands.contains { !$0.isHSLIdentity } }

    /// 101 — does the ninth selector carry a value? Judged the same way `hasBands` is: the three HSL
    /// axes only (the global triplet's unused `mix` is not S3.6's material).
    public var hasGlobal: Bool { !global.isHSLIdentity }

    /// True when any band carries a 黑白混合 value. Part of S3.4's material, not S3.6's.
    public var hasMix: Bool { bands.contains { $0.mix != 0 } }

    /// `vib=…;sat=…` — S3's material (076).
    public var keyString: String {
        "vib=\(k(vibrance));sat=\(k(saturation))"
    }

    /// `bands=…;gh=…;gs=…;gl=…` — S3.6's material (076/101). The eight-band text is **unchanged** byte
    /// for byte; the global triplet is appended only when it is non-zero, in fixed order, so a document
    /// that never used the ninth button keeps every recorded key. The mixes are **not** here: they are
    /// S3.4's, and a mix drag must not miss a cached S3.6 output (`bwGrayKeyString` carries them).
    public var hslKeyString: String {
        var s = "bands=" + bands.map(\.keyString).joined(separator: ";")
        if hasGlobal {
            s += ";gh=\(k(global.hue));gs=\(k(global.saturation));gl=\(k(global.luminance))"
        }
        return s
    }

    /// `gray=…` — S3.4's per-hue weights, in band order. All eight, always: the stage's link exists
    /// only when the switch is on, so there is no "default" spelling to preserve inside it.
    public var bwMixKeyString: String {
        "gray=" + bands.map(\.mixKeyString).joined(separator: ";")
    }
}

/// 101 — the ninth selector's name lives in the core alongside the eight (`HSLBands.bandNames`), so the
/// card does not hard-write a name a future rename would leave behind.
extension HSLBands {
    public static let globalBandName = "全局"
}

public struct HSLBand: Sendable, Equatable, Codable, Hashable {
    public var hue: Double         // -100…100 → ±30°
    public var saturation: Double  // -100…100
    public var luminance: Double   // -100…100
    /// 黑白混合 (2026-10-28, P0-4): this hue's share of the grey, −100…100, default 0.
    ///
    /// Lightroom's B&W mixer lives on the same eight hues as its HSL mixer — the panel swaps, the
    /// bands do not — so it is stored on the band rather than in a second eight-band table. Rendered
    /// only when `ColorGroup.blackAndWhite` is on (S3.4); a value left behind by a document that has
    /// since switched back to colour is inert **and encodes nothing**, which is what makes the return
    /// to colour bit-identical.
    public var mix: Double

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0, mix: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
        self.mix = mix
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = HSLBand()
        v.hue = c.val("hue", v.hue)
        v.saturation = c.val("saturation", v.saturation)
        v.luminance = c.val("luminance", v.luminance)
        v.mix = c.val("mix", v.mix)
        self = v
    }

    /// `mix` is written only when it is non-zero — a schema-7 document's band list re-encodes byte for
    /// byte, which is the same rule `LightGroup.blackOffset` follows and the reason S3.6's key material
    /// (`keyString`, three numbers) did not have to move when the fourth arrived.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(hue, forKey: AnyCodingKey("hue"))
        try c.encode(saturation, forKey: AnyCodingKey("saturation"))
        try c.encode(luminance, forKey: AnyCodingKey("luminance"))
        if mix != 0 { try c.encode(mix, forKey: AnyCodingKey("mix")) }
    }

    /// The three **HSL** axes only — what S3.6 reads, and the predicate `hasBands` asks.
    public var isHSLIdentity: Bool { hue == 0 && saturation == 0 && luminance == 0 }

    /// The whole band is default, mix included: "this band has nothing in it" (`ColorGroup.isIdentity`).
    public var isIdentity: Bool { isHSLIdentity && mix == 0 }

    /// `h,s,l` — S3.6's key material for this band (076), unchanged by 黑白.
    public var keyString: String { "\(k(hue)),\(k(saturation)),\(k(luminance))" }

    /// `m` — S3.4's key material for this band.
    public var mixKeyString: String { k(mix) }
}

/// 2026-10-28 (P0 色彩分级) — **one wheel**: 色相 + 饱和 + 亮度, the three axes a colour wheel has.
///
/// Travel is the panel's own ±100 on all three, and the units are the ones the rest of the app already
/// speaks, so 「+30」 means the same thing in this card as in HSL:
///
/// | axis | ±100 means | the kernel's spelling |
/// |---|---|---|
/// | `hue` | ±30° of OKLCh hue (`ColorGrade.degreesPerUnit` = 0.3, the HSL card's own number) | `h += 0.3·hue` |
/// | `saturation` | ×2 / ×0 of **chroma** (`C · (1 + s/100)`) | `C *= 1 + s/100` |
/// | `lightness` | ±1 stop of **linear** light (`2^(l/100)`) — the unit 曝光 and 阴影 use | `rgb *= 2^(l/100)` |
///
/// ### Why a hue *offset* and not a wheel *angle*
/// Lightroom stores an absolute wheel angle (0…360°) per region and darktable's `colorbalance rgb` does
/// the same. This card stores an offset from the pixel's own hue, for three reasons:
///
///  1. the region cross-fade needs to interpolate the parameter, and an absolute angle needs circular
///     interpolation (a 350° and a 10° wheel are 20° apart, not 340°) while an offset is just a number
///     to lerp — the same reason `HSLBand.hue` is a shift;
///  2. an absolute angle applied to a *region* (many hues at once) is ambiguous — 「shadows are orange」
///     would have to mean "rotate every shadow pixel *to* orange", which destroys the picture's own
///     colour variety; an offset tints the region without flattening it;
///  3. 「中性 = 0」 then really is the neutral: with an absolute angle, 0° (red) would be a real setting
///     and there would be no value a fresh document could hold that means "leave the hue alone".
public struct GradeWheel: Sendable, Equatable, Codable, Hashable {
    /// −100…100 → ±30° of OKLCh hue. Positive rotates the region's hue counter-clockwise on the
    /// OKLCh hue circle, i.e. red → orange → yellow.
    public var hue: Double
    /// −100…100 → the region's **chroma** multiplied by `1 + saturation/100` (−100 = grey, +100 = twice
    /// as colourful). Multiplicative, never additive: a grey pixel has `C = 0` and stays exactly grey,
    /// which is what keeps a neutral ramp from being tinted (and what makes the hue slider inert on a
    /// grey — there is no hue to rotate).
    public var saturation: Double
    /// −100…100 → the region's light multiplied by `2^(lightness/100)`: a pure gain, so `0` is the
    /// identity exactly and the luma comes out scaled by exactly that factor.
    public var lightness: Double

    public static let travel: ClosedRange<Double> = -100...100

    public init(hue: Double = 0, saturation: Double = 0, lightness: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = GradeWheel()
        v.hue = c.val("hue", v.hue)
        v.saturation = c.val("saturation", v.saturation)
        v.lightness = c.val("lightness", v.lightness)
        self = v
    }

    /// Written field by field (all three always), because `ColorGradingGroup` decides whether the
    /// *group* is written at all — inside a group that exists there is no absent-key spelling to keep.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(hue, forKey: AnyCodingKey("hue"))
        try c.encode(saturation, forKey: AnyCodingKey("saturation"))
        try c.encode(lightness, forKey: AnyCodingKey("lightness"))
    }

    /// All three at 0 — "this region is left alone".
    public var isIdentity: Bool { hue == 0 && saturation == 0 && lightness == 0 }

    /// `h,s,l` in slider units — S3.8's key material, one wheel at a time.
    public var keyString: String { "\(k(hue)),\(k(saturation)),\(k(lightness))" }
}

/// 2026-10-28 (P0 色彩分级) — **三向色彩分级**: 阴影 / 中间调 / 高光, one `GradeWheel` each.
///
/// ### The three regions are luminance windows, and they are S2's own
/// Which pixels a wheel reaches is decided by `region_weights` in `Kernels/tone_shape.metal` — the
/// function S2's 阴影 and 高光 sliders already call, on the same coordinate (`L = log2(luma)` in EV
/// relative to display white, luma in the working primaries). **No second table of region boundaries
/// exists in this app**: shadows are full weight at and below −5.9 EV and fade out at −3.9 EV,
/// highlights fade in from −3.2 EV and are full at −1.2 EV, and the mid-tones are `1 − shadow −
/// highlight`, i.e. everything the other two do not own. The three weights therefore form a partition
/// of unity at every pixel (the two windows do not overlap: −3.9 < −3.2), which is what makes
/// "a region's slider means the same thing wherever the pixel sits" true and lets the isolation claim
/// be exact: a pixel in the highlight zone has `w = (0, 0, 1)` and a shadow-only document leaves it
/// **bit-identical** (the kernel's early-out, not a tolerance).
///
/// The consequence to know about: 18 % grey (code 118) reads −2.44 EV, so it sits at
/// `(0, 0.70, 0.30)` — the 中间调 wheel owns most of it and the 高光 wheel starts to reach it. That is
/// the same overlap the 高光 slider has had since 074 R2, and it is deliberate: one table of "where
/// the regions are" for the whole panel is worth more than a second, prettier one that disagrees.
public struct ColorGradingGroup: Sendable, Equatable, Codable {
    public var shadows: GradeWheel
    public var midtones: GradeWheel
    public var highlights: GradeWheel

    public static let identity = ColorGradingGroup()

    public init(shadows: GradeWheel = GradeWheel(), midtones: GradeWheel = GradeWheel(),
                highlights: GradeWheel = GradeWheel()) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = ColorGradingGroup.identity
        v.shadows = c.val("shadows", v.shadows)
        v.midtones = c.val("midtones", v.midtones)
        v.highlights = c.val("highlights", v.highlights)
        self = v
    }

    /// Written by hand for one reason, the same one `ColorGroup.encode` has: the group is **absent**
    /// when all nine numbers are 0, which is what keeps every pre-schema-9 document's JSON byte for
    /// byte identical (§3.2 discipline, the `blackOffset` rule). Inside a group that exists, all three
    /// wheels are written in panel order (阴影 → 中间调 → 高光), so a fixed key set and a fixed order
    /// make "write, read, write" byte-identical.
    public func encode(to encoder: any Encoder) throws {
        guard !isIdentity else { return }
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(shadows, forKey: AnyCodingKey("shadows"))
        try c.encode(midtones, forKey: AnyCodingKey("midtones"))
        try c.encode(highlights, forKey: AnyCodingKey("highlights"))
    }

    /// All nine numbers 0 — "this card has nothing in it" (`EditModel.hasGrade`).
    public var isIdentity: Bool {
        shadows.isIdentity && midtones.isIdentity && highlights.isIdentity
    }

    /// The three wheels in panel order — the order the kernel's uniform carries and the order the key
    /// spells them, so a log line reads the card top to bottom.
    public var wheels: [GradeWheel] { [shadows, midtones, highlights] }

    /// `grade=sh;mid;hi` — S3.8's material. All three, always: the link exists only when the group is
    /// not neutral, so there is no default spelling to preserve inside it.
    public var keyString: String {
        "grade=" + wheels.map(\.keyString).joined(separator: ";")
    }
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

/// Lightroom's Effects panel: 暗角 (S3c) and 颗粒 (S3.7), both rendered.
///
/// The **ranges are the kernels' ranges** — a number the panel can produce and the shader cannot
/// honour would be a slider that lies:
///
///   · `vignetteAmount` −100…100 (`s3_vignette.metal`'s `gain`): negative darkens the corners,
///     positive brightens them, 0 is the identity (the pass copies);
///   · `vignetteMidpoint` 0…100 — where the falloff starts (`inner = mix(0.25, 1.05, mid/100)`);
///   · `vignetteFeather` 0…100 — how soft the transition is (the kernel clamps it to 2…100 %);
///   · `vignetteRoundness` −100…100 — square (max-norm) → circular (euclidean) blend;
///   · `grain` 0…100 — the grain's **amount** (standard deviation): 0 = no grain, and then S3.7 is not
///     encoded at all;
///   · `grainSize` 0…100 — the cell, in frame fractions;
///   · `grainRoughness` 0…100 — the weight of the finer octave;
///   · `grainSeed` 0…999 — the hash's only free variable (see `grainSeedValue`);
///   · `texture` −100…100 — S3.8's fine band (2…8 px), the guided filter's residual at a small radius;
///   · `clarity` −100…100 — S3.8's mid band (a few percent of the frame), the same residual at a radius
///     the kernel derives from the frame — local contrast without the halo a plain unsharp draws;
///   · `dehaze` −100…100 — S3.8's dark channel prior; negative adds a 0.4 veil back.
///
/// Nothing here is a second copy of a value the shader also holds: the defaults are the shader's
/// neutral, and `keyString`/`grainKeyString` are built from these fields only.
public struct EffectsGroup: Sendable, Equatable, Codable {
    public var vignetteAmount: Double      // -100…100, default 0 (negative = darker corners)
    public var vignetteMidpoint: Double    // 0…100, default 50
    public var vignetteFeather: Double     // 0…100, default 50
    public var vignetteRoundness: Double   // -100…100, default 0 (square → circular)
    /// 颗粒的**数量** (0…100, default 0). Kept under its original key `grain` so every document
    /// written before S3.7 re-encodes byte for byte (schema 5's `blackOffset` discipline).
    public var grain: Double
    /// 颗粒大小 (0…100, default 25 — Lightroom's own resting position, i.e. fine grain).
    public var grainSize: Double
    /// 颗粒粗糙度 (0…100, default 50).
    public var grainRoughness: Double
    /// 颗粒种子 (0…999, default 0). Stored as `Double` like every other number in the document; the
    /// kernel reads `grainSeedValue`, so the shader and the key cannot disagree about what was hashed.
    public var grainSeed: Double
    /// 纹理 (−100…100, default 0) — the **fine** detail band (2…8 px at the render's own scale):
    /// `s3_8_detail_fx.metal`'s guided-filter residual at a small radius. 0 = the band is not touched
    /// and, when the other two are 0 too, S3.8 does not exist for the document at all.
    public var texture: Double
    /// 清晰度 (−100…100, default 0) — the **mid** band (a few percent of the frame): the same
    /// guided-filter residual at a radius the kernel derives from the frame, i.e. local contrast
    /// without the halo a plain unsharp mask draws at a step edge (`DetailFXTests` measures the
    /// overshoot, and the same test measures the unsharp alternative failing that bound).
    public var clarity: Double
    /// 去雾 (−100…100, default 0) — dark-channel-prior haze removal (He/Sun/Tang 2010, simplified:
    /// airlight `A = 1`, transmission from a `1/q` dark channel). Negative **adds** the veil back.
    public var dehaze: Double

    public static let identity = EffectsGroup()

    /// The seed the kernel actually hashes: rounded and clamped into 0…999. One instantiation, so
    /// `keyString` and the uniform cannot drift (a `-0.4` and a `0` seed are the same noise).
    public var grainSeedValue: Int {
        guard grainSeed.isFinite else { return 0 }
        return min(max(Int(grainSeed.rounded()), 0), 999)
    }

    /// Does S3.7 exist for this document? Judged **by value** (the amount is above zero), exactly the
    /// way `hasHSL` judges S3.6 — a stage that is present but neutral would move the trace and the key
    /// chain for nothing, and a document with no grain must keep the pre-S3.7 chain byte for byte.
    public var hasGrain: Bool { grain > 0 }

    /// Does S3.8 exist for this document? Judged **by value**: any of the three numbers non-zero. A
    /// document with all three at 0 keeps the pre-S3.8 chain byte for byte — the strongest form of
    /// 「中性零变化」, the pass is not encoded rather than encoded and multiplied by zero.
    public var hasDetailFX: Bool { texture != 0 || clarity != 0 || dehaze != 0 }

    /// S3.8's material — the three numbers and nothing else. A clarity drag must not miss a cached
    /// vignette (S3c reads none of them) and a vignette drag must not re-run S3.8.
    public var detailFXKeyString: String {
        "tx=\(k(texture));cl=\(k(clarity));dz=\(k(dehaze))"
    }

    public init(vignetteAmount: Double = 0, vignetteMidpoint: Double = 50,
                vignetteFeather: Double = 50, vignetteRoundness: Double = 0,
                grain: Double = 0, grainSize: Double = 25,
                grainRoughness: Double = 50, grainSeed: Double = 0,
                texture: Double = 0, clarity: Double = 0, dehaze: Double = 0) {
        self.vignetteAmount = vignetteAmount
        self.vignetteMidpoint = vignetteMidpoint
        self.vignetteFeather = vignetteFeather
        self.vignetteRoundness = vignetteRoundness
        self.grain = grain
        self.grainSize = grainSize
        self.grainRoughness = grainRoughness
        self.grainSeed = grainSeed
        self.texture = texture
        self.clarity = clarity
        self.dehaze = dehaze
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = EffectsGroup.identity
        v.vignetteAmount = c.val("vignetteAmount", v.vignetteAmount)
        v.vignetteMidpoint = c.val("vignetteMidpoint", v.vignetteMidpoint)
        v.vignetteFeather = c.val("vignetteFeather", v.vignetteFeather)
        v.vignetteRoundness = c.val("vignetteRoundness", v.vignetteRoundness)
        v.grain = c.val("grain", v.grain)
        v.grainSize = c.val("grainSize", v.grainSize)
        v.grainRoughness = c.val("grainRoughness", v.grainRoughness)
        v.grainSeed = c.val("grainSeed", v.grainSeed)
        v.texture = c.val("texture", v.texture)
        v.clarity = c.val("clarity", v.clarity)
        v.dehaze = c.val("dehaze", v.dehaze)
        self = v
    }

    /// Hand-written for the same reason `ColorGroup.encode` is: the three schema-9 keys are **absent**
    /// when they are 0, so a schema-8 document re-encodes byte for byte (§3.2 discipline, the
    /// `blackOffset` rule). The eight older keys are written unconditionally, exactly as the synthesized
    /// encoder wrote them, so no pre-existing document's JSON moves.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(vignetteAmount, forKey: AnyCodingKey("vignetteAmount"))
        try c.encode(vignetteMidpoint, forKey: AnyCodingKey("vignetteMidpoint"))
        try c.encode(vignetteFeather, forKey: AnyCodingKey("vignetteFeather"))
        try c.encode(vignetteRoundness, forKey: AnyCodingKey("vignetteRoundness"))
        try c.encode(grain, forKey: AnyCodingKey("grain"))
        try c.encode(grainSize, forKey: AnyCodingKey("grainSize"))
        try c.encode(grainRoughness, forKey: AnyCodingKey("grainRoughness"))
        try c.encode(grainSeed, forKey: AnyCodingKey("grainSeed"))
        if texture != 0 { try c.encode(texture, forKey: AnyCodingKey("texture")) }
        if clarity != 0 { try c.encode(clarity, forKey: AnyCodingKey("clarity")) }
        if dehaze != 0 { try c.encode(dehaze, forKey: AnyCodingKey("dehaze")) }
    }

    /// S3c's material — the four vignette numbers and nothing else. A grain drag must not miss a
    /// cached vignette (they are different stages, and `.grain` carries its own material).
    public var keyString: String {
        "vig=\(k(vignetteAmount));mid=\(k(vignetteMidpoint));fea=\(k(vignetteFeather))"
            + ";rou=\(k(vignetteRoundness))"
    }

    /// S3.7's material — the amount, the shape, and the **seed**, so two documents that differ only in
    /// their seed can never share a cached grain.
    public var grainKeyString: String {
        "gamt=\(k(grain));gsz=\(k(grainSize));grou=\(k(grainRoughness));gseed=\(grainSeedValue)"
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

    // MARK: - the panel's units (2026-10-28, 078 B8; 0.1 grid 2026-10-28, 084)

    /// The sliders' travel: **−100…+100, 0 in the middle** — the number the user reads and types,
    /// and not the α the kernel takes.
    ///
    /// Why the panel does not show α: ±0.005 is a ratio, and a readout of `0.00250` is not a number
    /// anyone compares two frames with. −100…+100 is what Lightroom's 去边 sliders show, and it makes
    /// 「拖到尽头」, 「拖到一半」 and a typed `5` mean the same thing on every photo, at every preview
    /// size — which is the whole reason the model stores a ratio in the first place (see the type's
    /// note above). The same split as 黑电平 (071): the row is in slider units, the document is in the
    /// parameter's own units, and the conversion below is the only place they meet.
    public static let sliderRange: ClosedRange<Double> = -100 ... 100

    /// The α **one slider unit** is worth: `fullScale / 100` = 5 × 10⁻⁵, so a full deflection is
    /// exactly `fullScale` and the two ends of the row are the two ends of the envelope.
    public static let alphaPerSliderUnit: Double = fullScale / 100

    /// The panel's step: **0.1 of a slider unit** (用户 2026-10-28, 084). One step = 5 × 10⁻⁶ of α,
    /// so the thumb can sit on 2.5 while the readout still prints an integer (`%.0f`). The grid lives
    /// here, not in a `Slider` `step:` — 046 forbids the tick marks that would draw.
    public static let sliderStep: Double = 0.1

    /// Snap a raw step count onto the travel's 0.1 grid and clamp it to the ends.
    ///
    /// Both directions go through this one function so the knob and the document cannot land on two
    /// different grids (`blackOffsetSliderPosition`'s rule).
    private static func snappedSteps(_ raw: Double) -> Double {
        let lower = sliderRange.lowerBound / sliderStep
        let upper = sliderRange.upperBound / sliderStep
        return min(max(raw.rounded(), lower), upper)
    }

    /// Slider position → α, on the row's own 0.1-unit grid.
    ///
    /// Quantized **here**, not by a `step:` on the `Slider` (046 forbids tick marks): a position of
    /// `2.54` stores `2.5 × 5e-5` so the thumb never sits between two values the cache can tell
    /// apart. The readout is still an integer — that is `caRows`' format, not this grid.
    public static func alpha(fromSlider position: Double) -> Double {
        guard position.isFinite else { return 0 }
        let steps = snappedSteps(position / sliderStep)
        return steps * sliderStep * alphaPerSliderUnit
    }

    /// The inverse: the slider position this α asks for, on the same 0.1 grid (so a hand-edited α
    /// is pulled to a grid point rather than leaving `2.5000001` under the knob).
    public static func sliderPosition(forAlpha alpha: Double) -> Double {
        guard alpha.isFinite else { return 0 }
        let steps = snappedSteps((alpha / alphaPerSliderUnit) / sliderStep)
        return min(max(steps * sliderStep, sliderRange.lowerBound), sliderRange.upperBound)
    }

    /// The key's own units: **integer tenths of a slider unit**, e.g. `25` for position 2.5.
    ///
    /// `k()`'s `%.5f` cannot separate 0.1 steps (α = 5e-6: `0.000005` and `0.000010` both print
    /// `0.00001`), so a 0.1 grid would let two positions share one geometry key. Integer text has no
    /// rounding/locale ambiguity. Only used when α ≠ 0 (the `asp`/`car` discipline), so a document
    /// that never touched the sliders keeps its old geometry material byte for byte; a document that
    /// did misses once and rebuilds with the same pixels.
    public static func keyDeciles(forAlpha alpha: Double) -> Int {
        guard alpha.isFinite else { return 0 }
        return Int(((alpha / alphaPerSliderUnit) / sliderStep).rounded())
    }

    /// The two rows' positions, for the panel's bindings — the knob and the document can never
    /// disagree on the grid (`LightGroup.blackOffsetSliderPosition(of:)`'s rule).
    public var caRedSliderPosition: Double { Self.sliderPosition(forAlpha: caRed) }
    public var caBlueSliderPosition: Double { Self.sliderPosition(forAlpha: caBlue) }

    /// True when both sliders are on 0 — the panel's own statement of `isIdentity`, in the units it
    /// draws (a document hand-edited to `1e-9` is not "at zero" for either of them).
    public var slidersAtRest: Bool { caRedSliderPosition == 0 && caBlueSliderPosition == 0 }
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
