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
    /// `effects.dehaze` (−100…100, default 0), the Effects card's missing third block. S1.9 renders it
    /// (117 moved it out of S3.9 and out of the display domain); 纹理/清晰度 stay in S3.9. Before this
    /// version none of them existed.
    ///
    /// **Nothing migrates, and the encoding is additive.** Each of the three is written only when it is
    /// non-zero (the `blackOffset`/`blackAndWhite` rule), so a schema-8 document re-encodes **byte for
    /// byte** and an absent key reads as its default: 0, so neither S3.9 nor S1.9 is encoded for it,
    /// and its pixels are byte-identical. Like schemas 7 and 8, the version is not stamped at
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
    ///
    /// **11 (2026-10-29): 030's absolute black/white levels are deleted.** `light.blackLevel` and
    /// `light.whiteLevel` were a second and third spelling of "where black is" — an artefact of the
    /// 042 dropper, whose UI is long gone (073B made the sliders an EV window, 071 added the additive
    /// trim). Nothing could set them any more, but the model, the kernel's `kLevels` entry point, the
    /// history labels and the copy sheet all still had to reason about them. They are gone: the decode
    /// drops the two keys, `s1_scene_linear_levels*` no longer exists, and `blackOffset` is the one
    /// black-point control. A document that does carry one of the keys is stamped (its bytes and its
    /// pixels both move); measured before the change, zero documents on this machine had either key.
    ///
    /// **12 (2026-10-29, 140): `color.point` — 点颜色.** An optional `PointColor`; absent means the
    /// card has never been used and S3.6b does not exist for the document. The key is additive (the
    /// `colorGrading`/`healSpots` rule): a schema-11 blob reads `nil`, re-encodes byte for byte, and
    /// is not stamped. Only a document this build saves after a point-colour edit carries 12.
    ///
    /// **158: the value under `point` became `PointColorSet`** (an ordered `swatches` array plus the
    /// `active` index). The key name and schema number stay: the decoder accepts the old single-object
    /// shape (one swatch, active 0), and the encoder writes the new shape. The schema number stays 12
    /// because no *other* key gained or changed meaning; a pre-158 reader would reject the new shape,
    /// but this build's decoder is the compatibility contract.
    ///
    /// **13 (2026-10-31): 120b is deleted model-wide — the depth-assisted 去雾 and the depth mask.**
    /// `effects.dehazeDepth` was a second strength on the dehaze stage, and `MaskShape.depthRange`
    /// was a two-sided window on the depth map; the map itself is environment, not a document. The
    /// decode drops the key and the `;dd=` token disappears with it, and a `depthRange` component is
    /// **removed** from the mask list rather than preserved as `.unsupported` (a shape the UI could
    /// neither draw nor delete would be a dead row). Stamped — but only when one of the two old
    /// forms is actually present, because a document that has neither must keep its bytes: the same
    /// rule schema 11 used when `blackLevel`/`whiteLevel` went away.
    public static let currentSchemaVersion = 13
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
    /// 185 — **自研锐化** (S3.10): 数量 / 半径 / 细节 / 蒙版, in the display-referred domain.
    ///
    /// Its own group, not four more numbers inside `EffectsGroup`, for the reason §2.2 of the brief
    /// gives and this code has to keep true: `DetailGroup.sharpening` / `sharpeningRadius` are a
    /// **decoder** input (`CIRAWFilter`, the body's own baseline sharpening — read at decode time,
    /// impossible to preview at 4 ms, and still forwarded unchanged here), while these four are a
    /// **render** input (a pass on the tone-mapped pixels, previewable, and composable with the
    /// export's output sharpening in S4). Two numbers called 「锐化」 that answer two different
    /// questions should not live in one struct: the panel draws the decoder pair on 开发 and these
    /// four on 细节, and the key material keeps them in two stages (`.detail` has no branch at all —
    /// it never renders — while `.sharpen` is S3.10).
    ///
    /// Neutral (all four at `identity`) ⇒ the group is **not encoded** in the document, no key token
    /// is appended, and S3.10 does not exist for the document at all: the strongest form of
    /// 「中性零变化」, the pass is absent rather than encoded and multiplied by zero.
    public var sharpen: SharpenGroup
    /// Optics: lateral chromatic aberration (029). Its own group, **not** a field in `DetailGroup`:
    /// `keyMaterial` has no `.detail` branch, so a slider parked there would change no key and would
    /// silently render nothing.
    public var optics: OpticsGroup
    /// 179 — **原色校准**: seven numbers (shadows' green↔magenta tint + a hue/saturation pair per
    /// primary) that become one 3×3 matrix applied at S1's exit. Its own group, and it dirties
    /// `.sceneLinear` because the matrix is part of that stage's arithmetic — not a new stage.
    ///
    /// All zero = the exact unit matrix **and no key token at all**: `matrix()` returns nil, so the
    /// graph dispatches S1's calibration-free entry point, no uniform is bound and a neutral
    /// document's S1 material is byte-identical to 178's. See `CalibrationGroup` for the derivation.
    public var calibration: CalibrationGroup
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
                sharpen: SharpenGroup = .identity,
                optics: OpticsGroup = .identity,
                calibration: CalibrationGroup = .identity,
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
        self.sharpen = sharpen
        self.optics = optics
        self.calibration = calibration
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
        // 185: the display-domain sharpen is an edit like any other, so 「参数清零」 clears it too.
        v.sharpen = .identity
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

    /// 140: does S3.6b exist for this document? **Sampled colour and a non-zero adjustment** — the
    /// same by-value predicate `hasHSL` uses. A sample alone (adjustments all 0) and adjustments
    /// dragged before a sample both keep the pre-140 pipeline, key chain and pixels byte for byte.
    public var hasPointColor: Bool { color.hasPointColor }

    /// 2026-10-28: does S3.7 exist for this document? Judged **by value** (the grain amount is above
    /// zero), exactly the way `hasHSL` judges S3.6 — a stage present but neutral would move the trace
    /// and the key chain for nothing.
    public var hasGrain: Bool { effects.hasGrain }

    /// 179: does S1 run the **calibrated** instantiation? Judged **by value** — all seven numbers at 0
    /// is the answer "no", and then there is no `;cal` token, no `CalParams` buffer and no matrix in
    /// the kernel at all. A document that has never opened the card is the pre-179 document, byte for
    /// byte (the same by-value rule `hasGrain` / `hasDetailFX` follow).
    public var hasCalibration: Bool { !calibration.isIdentity }

    /// 2026-10-28 (P0-6): does S3.9 exist for this document? Judged **by value** — 纹理 or 清晰度
    /// non-zero — exactly the way `hasGrain` judges S3.7. 117 moved 去雾 out of this stage, so it no
    /// longer contributes. A document whose two are 0 keeps the pre-S3.9 stage list, key chain and
    /// pixels byte for byte: the pass is not encoded at all.
    /// 181 — S3.9 exists for a document whose *masks* carry a local detail value too, so this is no
    /// longer `effects.hasDetailFX` alone. Still judged **by value**: a mask with both fields at 0
    /// contributes nothing and the stage does not exist for it.
    public var hasDetailFX: Bool { effects.hasDetailFX || hasLocalDetail }

    /// 185: does S3.10 exist for this document? Judged **by value** — `sharpAmount > 0`. The other
    /// three only shape a pass that already exists (a radius with amount 0 sharpens nothing, and a
    /// masking of 100 at amount 0 masks nothing), so they cannot summon the stage.
    ///
    /// A document at amount 0 keeps the pre-185 stage list, key chain and pixels byte for byte: the
    /// pass is not encoded at all (§2.1 of the brief — the `hasDetailFX` value test, not a multiplied
    /// by zero uniform).
    public var hasSharpen: Bool { sharpen.amount > 0 }

    /// 117: does S1.9 exist for this document? Judged **by value** — `effects.dehaze != 0`. It is a
    /// separate stage at the end of the linear chain, so it has its own link and its own condition.
    public var hasDehaze: Bool { effects.hasDehaze }

    /// 098: does S1.8 exist for this document? Judged **by value** — `light.contrast != 0` — exactly
    /// the way `hasDetailFX` judges S3.9. A document with contrast 0 keeps the pre-098 stage list, key
    /// chain and pixels byte for byte: the pass is not encoded at all.
    public var hasContrastStage: Bool { light.contrast != 0 }

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
        // 185: an absent key reads as the neutral group — four defaults, `hasSharpen == false`, no
        // S3.10 link (schema 9's additive rule, read for the last time). A pre-185 document therefore
        // keeps its whole key chain and its pixels byte for byte.
        v.sharpen = c.val("sharpen", v.sharpen)
        v.optics = c.val("optics", v.optics)
        // 179: absent = seven zeros = the unit matrix, no key token, no S1 instantiation change.
        v.calibration = c.val("calibration", v.calibration)
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
        // schema 11: 030's absolute levels are deleted model-wide, so a document that still carries
        // one loses the level it named. Stamped, unlike the additive schema-7/8/9/10 keys: the bytes
        // change (a key disappears) and the pixels change (019's affine level stops being applied).
        if v.schemaVersion < 11,
           let lc = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("light")),
           lc.contains(AnyCodingKey("blackLevel")) || lc.contains(AnyCodingKey("whiteLevel")) {
            v.schemaVersion = EditModel.currentSchemaVersion
        }
        // schema 13: 120b's depth-assisted dehaze is deleted model-wide. A document that still
        // carries `effects.dehazeDepth` loses the strength it named (and re-keys once, because the
        // `;dd=` token disappears). Stamped, unlike the additive schema-7…12 keys: the bytes change
        // (a key disappears) and the pixels would change had anything ever set it.
        //
        // The two halves of 13 share one version number but must both run: a document can carry
        // *both* old forms, and the first half stamps, so the second cannot test the version it is
        // about to overwrite. `incomingSchema` is what the file said, read before any stamp.
        let incomingSchema = v.schemaVersion
        if incomingSchema < 13,
           let ec = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("effects")),
           ec.contains(AnyCodingKey("dehazeDepth")) {
            v.schemaVersion = EditModel.currentSchemaVersion
        }
        // schema 13, second half: 120b's depth mask is deleted model-wide too, and such a component
        // is **removed** from the document rather than left as `.unsupported` — an unknown
        // `depthRange` row would show up in the mask list, render nothing, and have no control to
        // delete it. A mask left with no component at all goes with it (a mask with nothing to select
        // is not a mask). Stamped only when something was actually dropped: the shape's only entry
        // point was `depthAvailable`, which had no caller, so a real document cannot hold one and a
        // document that does not must keep its bytes.
        if incomingSchema < 13 {
            // `MaskShape` has no `depthRange` case any more, so the decode above turned every such
            // component into `.unsupported`; this is the one place that still knows the name.
            let retired = "depthRange"
            var kept: [Mask] = []
            var pruned = false
            kept.reserveCapacity(v.masks.count)
            for mask in v.masks {
                let components = mask.components.filter { $0.shape.kind != retired }
                guard components.count != mask.components.count else {
                    kept.append(mask)
                    continue
                }
                pruned = true
                guard !components.isEmpty else { continue }
                var m = mask
                m.components = components
                kept.append(m)
            }
            if pruned {
                v.masks = kept
                v.schemaVersion = EditModel.currentSchemaVersion
            }
        }
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
        // 185: written **only when non-neutral** (the `colorGrading`/`healSpots` rule), so every
        // document from before S3.10 re-encodes byte for byte and an absent key reads as the identity.
        if !sharpen.isIdentity {
            try c.encode(sharpen, forKey: AnyCodingKey("sharpen"))
        }
        try c.encode(optics, forKey: AnyCodingKey("optics"))
        // 179: written **only when the panel moved** (the `colorGrading`/`healSpots` rule). A neutral
        // document re-encodes byte for byte — which is not a cosmetic detail: `ThumbRecipe`'s on-disk
        // key is `sha256(canonical(develop_json) | …)`, so an unconditional key would invalidate every
        // cached thumbnail on disk for a document that never opened the card.
        if !calibration.isIdentity {
            try c.encode(calibration, forKey: AnyCodingKey("calibration"))
        }
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
            // does: the linear buffer itself is what changed (派单 019). Since 143 the white balance
            // is S1's gain slot too, so a Kelvin/tint change dirties `.sceneLinear` and nothing
            // upstream of it (there is no development any more).
            if light.exposure != old.light.exposure
                || light.highlightRecovery != old.light.highlightRecovery
                || light.whites != old.light.whites
                || light.blacks != old.light.blacks
                || light.blackOffset != old.light.blackOffset
                || light.temperature != old.light.temperature
                || light.tint != old.light.tint {
                s.insert(.sceneLinear)
            }
            if light.contrast != old.light.contrast { s.insert(.contrast) }
            if light.highlights != old.light.highlights
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
            // 140/158: S3.6b's own material is the swatch list (samples, windows, adjustments). A
            // re-sample therefore dirties exactly this stage (not S3.6). `active` is a selection, not
            // a pixel, so it is compared separately and never dirties S3.6b.
            if color.point?.swatches != old.color.point?.swatches { s.insert(.pointColour) }
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
                || effects.vignetteFeather != old.effects.vignetteFeather {
                s.insert(.vignette)
            }
            if effects.grain != old.effects.grain
                || effects.grainSize != old.effects.grainSize
                || effects.grainRoughness != old.effects.grainRoughness
                || effects.grainSeedValue != old.effects.grainSeedValue {
                s.insert(.grain)
            }
            // 2026-10-28 (P0-6): the card's third block is a third stage — S3.9 reads 纹理/清晰度 and
            // none of the vignette/grain numbers, so a clarity drag must dirty S3.9 alone.
            if effects.texture != old.effects.texture
                || effects.clarity != old.effects.clarity
                || effects.nonBayerLuminanceNR != old.effects.nonBayerLuminanceNR
                || effects.nonBayerColorNR != old.effects.nonBayerColorNR {
                s.insert(.detailFX)
            }
            // 117: 去雾 is S1.9 now, in the linear chain — its own stage and its own dirty bit, so a
            // dehaze drag must not re-run the display-referred detail filter.
            if effects.dehaze != old.effects.dehaze { s.insert(.dehaze) }
        }
        // 185: S3.10 is its own stage and its own dirty bit — a 数量 drag must not re-run S3.9, and a
        // 纹理 drag must not re-run S3.10 (neither reads the other's numbers).
        if sharpen != old.sharpen { s.insert(.sharpen) }
        // 029: `α` is a geometry parameter — it moves where R and B are sampled out of the source —
        // so it dirties S0 and, through the key chain, everything below it.
        if optics != old.optics { s.insert(.geometry) }
        // 179: the calibration's seven numbers *are* S1's arithmetic — its matrix is applied at that
        // stage's exit — so it dirties `.sceneLinear` and nothing above it. A calibration edit must
        // not evict S0's decode or the mask atlas (the same scoping `StageAlgorithmVersion` uses).
        if calibration != old.calibration { s.insert(.sceneLinear) }
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
            // 183: the two keystones, **only when non-zero** (`asp`/`car`/`q` discipline). A document
            // that never touched them keeps the pre-183 geometry material byte for byte — the pinned
            // key vectors depend on exactly that — and `;alg=2` is the only textual change it sees.
            // Tenths of a slider unit, like 084's `;car=25`: `%.5f` cannot tell 0.000005 from 0.00001,
            // and two adjacent knob positions must not share a key.
            if geometry.perspectiveVertical != 0 {
                s += ";pvy=\(Int((geometry.perspectiveVertical * 10).rounded()))"
            }
            if geometry.perspectiveHorizontal != 0 {
                s += ";phx=\(Int((geometry.perspectiveHorizontal * 10).rounded()))"
            }
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
            // schema 11: 030's `blL`/`whL` tokens are gone with the fields they named. A document
            // written by an earlier build re-keys once (the level it named no longer renders) and
            // never again — `boff` below is the one remaining black-point token.
            var m = "ev=\(k(light.exposure));temp=\(light.temperature.map { k($0) } ?? "shot")"
                + ";tint=\(light.tint.map { k($0) } ?? "shot")"
                + ";hlr=\(k(light.highlightRecovery))"
                + ";wh=\(k(light.whites));bl=\(k(light.blacks))"
            // 071: appended **only when non-zero**, the `asp`/`car`/`blL` discipline. A document that
            // never used the trim keeps the S1 material of every document written before 071 byte for
            // byte — the pinned vectors in `WindowTests` / `MaskTests` and every recorded golden depend
            // on it. `boff` is the clamped value, i.e. the number the kernel actually adds.
            if light.blackOffset != 0 { m += ";boff=\(k(light.clampedBlackOffset))" }
            // 179: the 原色校准 matrix. Appended **only when it is not the unit matrix** (the
            // `asp`/`car`/`boff` discipline): a document with all seven numbers at 0 renders through
            // S1's calibration-free instantiation, so its material — and therefore the neutral
            // goldens' pixels — is byte-identical to 178's. The seven numbers are the key's own
            // units: **integer tenths of a slider unit**, so two adjacent positions can never print
            // the same text (OpticsGroup's 084 lesson, `%.5f` cannot separate 0.1 steps).
            if let cal = calibration.keyToken { m += cal }
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
            // 098: contrast left this stage for S1.8, so its material is the three region lifts only.
            // A contrast drag must not be able to miss a cached S2 output by landing here instead.
            //
            // 085: `md` is appended **only when non-zero**, the `asp`/`car`/`q` discipline, so a
            // document that never touched 中间调 keeps its pre-085 tone-map material byte for byte.
            var m = "hi=\(k(light.highlights));sh=\(k(light.shadows))"
            if light.midtones != 0 { m += ";md=\(k(light.midtones))" }
            return m

        case .contrast:
            // 098: S1.8's own material — the contrast number and nothing else.
            return "con=\(k(light.contrast))"

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

        case .pointColour:
            // 140: S3.6b's own material — the sampled colour, the window and the three adjustments.
            // Written even when the optional is `nil` (the stage only exists when it is active, so
            // this is the safety answer for a caller asking for a stage the document does not have).
            return "point=\(color.pointKeyString)"

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
            // 2026-10-28 (P0-6): S3.9's own material — 纹理 and 清晰度 and nothing else.
            // 181: a mask's local 纹理/锐化 are S3.9's too, so they belong here and **not** in
            // `maskApplyMaterial` (S1.6 reads neither). The list is empty when no mask carries a
            // value, so every pre-181 key string is unchanged.
            var m = effects.detailFXKeyString
            let local = localDetailMaterial
            if !local.isEmpty { m += ";mloc=[\(local)]" }
            return m

        case .sharpen:
            // 185: S3.10's own material — the four numbers and nothing else. A 数量 drag must miss
            // S3.9 (which reads none of them) and a 纹理 drag must miss S3.10; naming the values it
            // reads is the same belt-and-braces shape `.hsl`/`.grain`/`.grade` use.
            //
            // The decoder's 机身基线 pair (`detail.sharpening`) is deliberately **absent** here: it is
            // not this stage's input at all (it enters at decode, `DecodeInputs`), so putting it in
            // this material would make a decode-only change evict a cached S3.10 for nothing.
            return sharpen.keyString

        case .dehaze:
            // 117: S1.9's own material — the dehaze amount and nothing else.
            return effects.dehazeKeyString

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

    /// 183 — **透视 / 梯形校正**, the two knobs of the 变换 card. −100…100, 0 = the identity.
    ///
    /// The value is a *keystone strength*, one number per axis, and the geometry it drives is
    /// `CropMath.PerspectiveMap`: a 3×3 homography in the frame's own pixel space that
    /// **fixes the near edge** and scales the far edge. `+` corrects a picture shot *from below*
    /// (vertical) / *from the left* (horizontal), i.e. it pulls the near end in and pushes the far
    /// end out — the same direction the user sees a building straighten.
    ///
    /// Full travel is **6°** of convergence on a square frame (3° at ±50), which is what makes
    /// `perspectiveVertical = +50` a one-drag fix for the 3° card in the acceptance.
    ///
    /// Stored as given; `perspective` is the map S0 actually consumes (clamped, and `nil` at 0/0).
    /// 0 keeps the pre-183 bytes **and** the pre-183 key: the two keys are written only when the
    /// document is actually keystoned, the `quarterTurns`/`asp`/`car` discipline.
    public var perspectiveVertical: Double
    public var perspectiveHorizontal: Double

    public static let identity = GeometryGroup(crop: .full, rotationDegrees: 0,
                                               flipHorizontal: false, flipVertical: false,
                                               aspectLock: .original, quarterTurns: 0)

    public init(crop: NormalizedRect = .full,
                rotationDegrees: Double = 0,
                flipHorizontal: Bool = false,
                flipVertical: Bool = false,
                aspectLock: AspectLock = .original,
                quarterTurns: Int = 0,
                perspectiveVertical: Double = 0,
                perspectiveHorizontal: Double = 0) {
        self.crop = crop
        self.rotationDegrees = rotationDegrees
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.aspectLock = aspectLock
        self.quarterTurns = GeometryGroup.normalizedQuarterTurns(quarterTurns)
        self.perspectiveVertical = perspectiveVertical
        self.perspectiveHorizontal = perspectiveHorizontal
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
            // 132: a crop may deliberately lie outside the photograph (the output frame may be
            // larger than the picture). In-range documents come back exactly as before.
            v.crop = edges.clamped(allowsOutsideSource: true).normalizedRect
        }
        v.rotationDegrees = c.val("rotationDegrees", v.rotationDegrees)
        v.flipHorizontal = c.val("flipHorizontal", v.flipHorizontal)
        v.flipVertical = c.val("flipVertical", v.flipVertical)
        v.aspectLock = c.val("aspectLock", v.aspectLock)
        v.quarterTurns = GeometryGroup.normalizedQuarterTurns(
            c.val("quarterTurns", v.quarterTurns))
        // 183: absent on every document written before this task, which reads as 0 (= no warp).
        v.perspectiveVertical = c.val("perspectiveVertical", v.perspectiveVertical)
        v.perspectiveHorizontal = c.val("perspectiveHorizontal", v.perspectiveHorizontal)
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
        // 183: only a keystoned document grows these two keys — a neutral document re-encodes byte
        // for byte, which `render-edit-neutral`'s pinned blob depends on.
        if perspectiveVertical != 0 {
            try c.encode(perspectiveVertical, forKey: AnyCodingKey("perspectiveVertical"))
        }
        if perspectiveHorizontal != 0 {
            try c.encode(perspectiveHorizontal, forKey: AnyCodingKey("perspectiveHorizontal"))
        }
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
    ///
    /// **188 — 「输出尺寸」 is the canvas the renderer allocates, so it is `CropMath.canvasSize`.**
    /// At θ ≠ 0 the canvas is the turned crop's bounding box (162), which is what the render produces
    /// and what the info bar has to report; keeping `frameSize` here made the readout and the
    /// backdrop's own scale smaller than the picture on screen. At every right angle `canvasSize`
    /// returns `outputSize` itself, so this is the pre-188 value bit for bit.
    public func outputPixels(in source: ImageSize) -> ImageSize {
        CropMath.canvasSize(crop: renderCrop(source: source), in: orientedSource(source),
                            straightenDegrees: straightenDegrees, quarterTurns: 0,
                            allowsOutsideSource: true, perspective: perspective)
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

    /// 183 — the keystone map S0 consumes, or `nil` when both knobs are at 0.
    ///
    /// `nil` is the pre-183 render path **and** the pre-183 key: the kernel's warp block is skipped
    /// entirely (the flag in `S0Params` is 0), the canvas is the crop's own pixel size, and the key
    /// material grows no token. The clamp lives in `PerspectiveMap` (finite, ±100).
    public var perspective: PerspectiveMap? {
        guard perspectiveVertical != 0 || perspectiveHorizontal != 0 else { return nil }
        return PerspectiveMap(vertical: perspectiveVertical, horizontal: perspectiveHorizontal)
    }

    /// The rect the renderer feeds to S0: the stored crop, re-shaped by `aspectLock` when the lock
    /// names a ratio (the lock wins over a rect that disagrees with it), then clamped.
    ///
    /// Measured in the **turned** frame (schema 9): the lock's ratio is a pixel ratio, so it is
    /// fitted against `orientedSource`, and the rect stays a rectangle of the picture the user sees.
    /// At `quarterTurns == 0` this is byte for byte the pre-9 call.
    public func renderCrop(source: ImageSize) -> CropRect {
        // 132: the crop is the output frame and may extend past the photograph; S0 writes those
        // pixels transparent/black. An in-range rect is unchanged by the editing clamp.
        CropMath.lockedCrop(aspectLock, in: cropRect, source: orientedSource(source),
                            allowsOutsideSource: true)
            .clamped(allowsOutsideSource: true)
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
    /// 50 % grey — that is not what the control is for. `+` still lifts the shadows.
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

    /// 派单 071 — an **additive** black trim in scene-linear units: +0.01…−0.01, default 0.
    ///
    /// The **only** spelling of "where black is" in the document (030's absolute
    /// `blackLevel`/`whiteLevel` pair was deleted in schema 11 — a second meaning of one control with
    /// no UI left to set it). `blacks` is the coarse end-point control (±3 EV of knee at the dark
    /// end); this is the fine trim the user asked for — 「让 0 值变为 ±0.01」— with 1/1000
    /// granularity, and it is the only control that can lift the decoder's own negative samples back
    /// across zero without moving where 0 and 1 are:
    ///
    ///     v = v + blackOffset        // S1, before the exposure gain
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

    public init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0,
                midtones: Double = 0, shadows: Double = 0, whites: Double = 0, blacks: Double = 0,
                temperature: Double? = nil, tint: Double? = nil, highlightRecovery: Double = 0,
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
        // schema 11: 030's absolute pair is gone; a document that still carries the keys loads
        // without them (`EditModel.init(from:)` stamps the version so the re-encode says so).
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
        // 071: **absent at 0**, not `"blackOffset": 0` — a document that never touched the control
        // re-encodes byte for byte (the `temperature`/`tint` rule). It is the same
        // discipline the kernel follows: the default path is not "the old path plus zero", it is the
        // old path.
        if blackOffset != 0 { try c.encode(blackOffset, forKey: AnyCodingKey("blackOffset")) }
    }

    public var isIdentity: Bool { self == LightGroup.identity }

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
    /// 140 — 点颜色: an ordered list of sampled OKLCh colours and the three adjustments scoped to
    /// each one. `nil` (the default) means the card has never been used: S3.6b is not in the pipeline,
    /// no key segment is added and a schema-11 blob re-encodes byte for byte. Written only when the
    /// list has at least one swatch. 158 made this an ordered set (multiple boxes; every one renders).
    public var point: PointColorSet?

    public static let bandCount = 8

    public static let identityBands: [HSLBand] = Array(repeating: HSLBand(), count: bandCount)

    public static let identity = ColorGroup()

    public init(vibrance: Double = 0, saturation: Double = 0,
                bands: [HSLBand] = ColorGroup.identityBands,
                blackAndWhite: Bool = false,
                global: HSLBand = HSLBand(),
                point: PointColorSet? = nil) {
        self.vibrance = vibrance
        self.saturation = saturation
        self.bands = ColorGroup.normalize(bands)
        self.blackAndWhite = blackAndWhite
        self.global = global
        self.point = point
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
        // 140: additive — an absent key reads as `nil`, i.e. the pre-140 graph.
        v.point = c.val("point", v.point)
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
        // 140: the point-colour object is absent while the card is unused — the same rule.
        if let point, !point.swatches.isEmpty {
            try c.encode(point, forKey: AnyCodingKey("point"))
        }
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
            && bands.allSatisfy { $0.isIdentity } && (point?.swatches.isEmpty ?? true)
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

    /// 140 — does S3.6b exist for this group? At least one swatch sampled **and** adjusted; a sample
    /// alone or three sliders without a sample is not a stage (and must not move the trace, the key or
    /// a pixel). 158: **all** swatches render, so any active one makes the stage exist; an empty list
    /// is the same as no point colour at all.
    public var hasPointColor: Bool { point?.swatches.contains { $0.isActive } ?? false }

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

    /// `point=…` — S3.6b's material (140/158): every swatch's sample, window and three adjustments,
    /// in array order. `active` is **not** here (it moves no pixel). `none` when the list is empty; the
    /// stage does not exist in that case, but the material still has to answer for a caller that asks.
    public var pointKeyString: String {
        point?.keyString ?? "none"
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
///   · `vignetteMidpoint` 0…100 — where the falloff's 50 % point sits on the half-diagonal scale:
///     0 = the centre (the whole frame darkens), 100 = the corner (`norm = 0.5·hypot(w, h)` makes
///     the corner 1.0 at every aspect ratio; 134);
///   · `vignetteFeather` 0…100 — how soft the transition is (the kernel clamps it to 2…100 %);
///
/// The vignette is always circular (134, user 2026-10-29): the removed 圆度 field is an unknown key
/// to this decoder and is ignored, so an old document still opens and renders with the pure-circle
/// model.
///   · `grain` 0…100 — the grain's **amount** (standard deviation): 0 = no grain, and then S3.7 is not
///     encoded at all;
///   · `grainSize` 0…100 — the cell, in frame fractions;
///   · `grainRoughness` 0…100 — the weight of the finer octave;
///   · `grainSeed` 0…999 — the hash's only free variable (see `grainSeedValue`);
///   · `texture` −100…100 — S3.9's fine band (2…8 px), the guided filter's residual at a small radius;
///   · `clarity` −100…100 — S3.9's mid band (a few percent of the frame), the same residual at a radius
///     the kernel derives from the frame — local contrast without the halo a plain unsharp draws;
///   · `dehaze` −100…100 — S1.9's dark channel prior in scene-linear light (117); negative adds a
///     0.4-relative veil back.
///
/// Nothing here is a second copy of a value the shader also holds: the defaults are the shader's
/// neutral, and `keyString`/`grainKeyString` are built from these fields only.
public struct EffectsGroup: Sendable, Equatable, Codable {
    public var vignetteAmount: Double      // -100…100, default 0 (negative = darker corners)
    public var vignetteMidpoint: Double    // 0…100, default 50; 100 = the corner (half diagonal)
    public var vignetteFeather: Double     // 0…100, default 50
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
    /// and, when the other two are 0 too, S3.9 does not exist for the document at all.
    public var texture: Double
    /// 清晰度 (−100…100, default 0) — the **mid** band (a few percent of the frame): the same
    /// guided-filter residual at a radius the kernel derives from the frame, i.e. local contrast
    /// without the halo a plain unsharp mask draws at a step edge (`DetailFXTests` measures the
    /// overshoot, and the same test measures the unsharp alternative failing that bound).
    public var clarity: Double
    /// 去雾 (−100…100, default 0) — **S1.9**, in scene-linear light: the dark-channel prior of
    /// He/Sun/Tang (2010) with a measured airlight `A` (`Kernels/s1_9_dehaze.metal`). Negative
    /// **adds** the veil back.
    public var dehaze: Double
    /// 164 — **去噪** (0…100, default 0): S3.9's display-referred luminance denoise. The
    /// guided filter's residual (the same statistics 纹理/清晰度 use) is subtracted from the luma at a
    /// 1–3 px radius, so flat noise is averaged while structural edges keep their step. 0 is the
    /// pre-164 frame byte for byte (the stage is not encoded when everything is 0).
    public var nonBayerLuminanceNR: Double
    /// 164 — **去彩噪** (0…100, default 0): S3.9's OKLab chroma suppression. It scales
    /// `C` only (hue and `L` are held), so a grey card stays neutral and the luma is untouched.
    public var nonBayerColorNR: Double

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

    /// Does S3.9 exist for this document? Judged **by value**: 纹理 / 清晰度 / 去噪 /
    /// 去彩噪 non-zero (117 removed 去雾 from this stage). A document with all four at 0
    /// keeps the pre-S3.9 chain byte for byte — the strongest form of 「中性零变化」, the pass is not
    /// encoded rather than encoded and multiplied by zero.
    public var hasDetailFX: Bool {
        texture != 0 || clarity != 0 || nonBayerLuminanceNR != 0 || nonBayerColorNR != 0
    }

    /// 117: does S1.9 (去雾) exist for this document? Its own stage, its own link.
    public var hasDehaze: Bool { dehaze != 0 }

    /// S3.9's material — 纹理 / 清晰度 and the two denoises, and nothing else. A clarity
    /// drag must not miss a cached vignette (S3c reads neither) and a vignette drag must not re-run
    /// S3.9. 去雾 has its own string now that it is its own stage. The newer fields append only when
    /// non-zero (the `asp`/`car` discipline): a pre-164 document keeps the exact `tx=…;cl=…` text.
    public var detailFXKeyString: String {
        var m = "tx=\(k(texture));cl=\(k(clarity))"
        if nonBayerLuminanceNR != 0 { m += ";nbl=\(k(nonBayerLuminanceNR))" }
        if nonBayerColorNR != 0 { m += ";nbc=\(k(nonBayerColorNR))" }
        return m
    }

    /// S1.9's material — the dehaze amount itself. 120b's `;dd=` token went with the field, so a
    /// document that never named a depth strength re-encodes its `dz=…` text byte for byte.
    public var dehazeKeyString: String { "dz=\(k(dehaze))" }

    public init(vignetteAmount: Double = 0, vignetteMidpoint: Double = 50,
                vignetteFeather: Double = 50,
                grain: Double = 0, grainSize: Double = 25,
                grainRoughness: Double = 50, grainSeed: Double = 0,
                texture: Double = 0, clarity: Double = 0, dehaze: Double = 0,
                nonBayerLuminanceNR: Double = 0, nonBayerColorNR: Double = 0) {
        self.vignetteAmount = vignetteAmount
        self.vignetteMidpoint = vignetteMidpoint
        self.vignetteFeather = vignetteFeather
        self.grain = grain
        self.grainSize = grainSize
        self.grainRoughness = grainRoughness
        self.grainSeed = grainSeed
        self.texture = texture
        self.clarity = clarity
        self.dehaze = dehaze
        self.nonBayerLuminanceNR = nonBayerLuminanceNR
        self.nonBayerColorNR = nonBayerColorNR
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = EffectsGroup.identity
        v.vignetteAmount = c.val("vignetteAmount", v.vignetteAmount)
        v.vignetteMidpoint = c.val("vignetteMidpoint", v.vignetteMidpoint)
        v.vignetteFeather = c.val("vignetteFeather", v.vignetteFeather)
        v.grain = c.val("grain", v.grain)
        v.grainSize = c.val("grainSize", v.grainSize)
        v.grainRoughness = c.val("grainRoughness", v.grainRoughness)
        v.grainSeed = c.val("grainSeed", v.grainSeed)
        v.texture = c.val("texture", v.texture)
        v.clarity = c.val("clarity", v.clarity)
        v.dehaze = c.val("dehaze", v.dehaze)
        v.nonBayerLuminanceNR = c.val("nonBayerLuminanceNR", v.nonBayerLuminanceNR)
        v.nonBayerColorNR = c.val("nonBayerColorNR", v.nonBayerColorNR)
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
        try c.encode(grain, forKey: AnyCodingKey("grain"))
        try c.encode(grainSize, forKey: AnyCodingKey("grainSize"))
        try c.encode(grainRoughness, forKey: AnyCodingKey("grainRoughness"))
        try c.encode(grainSeed, forKey: AnyCodingKey("grainSeed"))
        if texture != 0 { try c.encode(texture, forKey: AnyCodingKey("texture")) }
        if clarity != 0 { try c.encode(clarity, forKey: AnyCodingKey("clarity")) }
        if dehaze != 0 { try c.encode(dehaze, forKey: AnyCodingKey("dehaze")) }
        // 164: additive, absent at 0 — a pre-164 document re-encodes byte for byte.
        if nonBayerLuminanceNR != 0 {
            try c.encode(nonBayerLuminanceNR, forKey: AnyCodingKey("nonBayerLuminanceNR"))
        }
        if nonBayerColorNR != 0 {
            try c.encode(nonBayerColorNR, forKey: AnyCodingKey("nonBayerColorNR"))
        }
    }

    /// S3c's material — the three vignette numbers and nothing else. A grain drag must not miss a
    /// cached vignette (they are different stages, and `.grain` carries its own material).
    public var keyString: String {
        "vig=\(k(vignetteAmount));mid=\(k(vignetteMidpoint));fea=\(k(vignetteFeather))"
    }

    /// S3.7's material — the amount, the shape, and the **seed**, so two documents that differ only in
    /// their seed can never share a cached grain.
    public var grainKeyString: String {
        "gamt=\(k(grain));gsz=\(k(grainSize));grou=\(k(grainRoughness));gseed=\(grainSeedValue)"
    }
}

/// 185 — **自研锐化** (S3.10): 数量 / 半径 / 细节 / 蒙版.
///
/// Four numbers, one unsharp mask in the display-referred domain (`Kernels/s3_10_sharpen.metal`).
/// The ranges are the kernel's ranges — a slider the panel can produce and the shader cannot honour
/// would be a slider that lies:
///
///   · `amount` 0…150 — USM strength (`A = amount/100`). **0 means S3.10 does not exist** for the
///     document: no pass, no key token, no pixel. This is the whole neutrality contract.
///   · `radius` 0.5…3.0 px — the Gaussian's σ, in **content pixels** of the render's own grid, so a
///     0.5-scale fit preview and a 1:1 window sharpen the same picture detail (「按缩放归一」).
///   · `detail` 0…100 — the weight of the < σ/2 px band. 0 = only structures ≥ about σ/2 px; 100 =
///     the plain USM (`I + A·(I − G_σ)`), 1 px texture included.
///   · `masking` 0…100 — how much of the boost the edge mask is allowed to withhold. 0 = sharpen
///     everything (noise included), 100 = only the strong edges, so a flat area keeps its noise
///     exactly as it was.
///
/// **Not the decoder's 机身基线.** `DetailGroup.sharpening` / `sharpeningRadius` are a
/// `CIRAWFilter` input — the body's own sharpening, applied at decode, kept on the 开发 card, and
/// forwarded by this build unchanged (§2.2). These four are a render pass on the tone-mapped pixels:
/// previewable without a re-decode, and separate from S4's output sharpening at export.
public struct SharpenGroup: Sendable, Equatable, Codable {
    public var amount: Double     // 0…150
    public var radius: Double     // 0.5…3.0 px (σ, content pixels)
    public var detail: Double     // 0…100
    public var masking: Double    // 0…100

    public static let identity = SharpenGroup()

    /// The slider ranges, one place, so the panel and a clamp cannot disagree.
    public static let amountRange = 0.0 ... 150.0
    public static let radiusRange = 0.5 ... 3.0

    public init(amount: Double = 0, radius: Double = 1.0,
                detail: Double = 25, masking: Double = 0) {
        self.amount = amount
        self.radius = radius
        self.detail = detail
        self.masking = masking
    }

    /// All four at their resting values. `detail` and `masking` have non-zero defaults because they
    /// are *shape* parameters of a pass that does not exist at amount 0 — they are stored, not
    /// applied, and they cannot summon the stage (`EditModel.hasSharpen` is the amount alone).
    public var isIdentity: Bool {
        amount == 0 && radius == 1.0 && detail == 25 && masking == 0
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = SharpenGroup.identity
        v.amount = c.val("amount", v.amount)
        v.radius = c.val("radius", v.radius)
        v.detail = c.val("detail", v.detail)
        v.masking = c.val("masking", v.masking)
        self = v
    }

    /// S3.10's material — the four numbers the kernel reads, and nothing else. `%.4f` on the radius
    /// because two radii a hundredth of a pixel apart must not share a cached pass; the other three
    /// are whole numbers on their sliders.
    public var keyString: String {
        String(format: "sha=%.4f;shr=%.2f;shd=%.1f;shm=%.1f",
               amount, radius, detail, masking)
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

// MARK: - 179 · 原色校准 (Calibration)

/// 原色校准 — LightCraft's `Calibration` panel (and Lightroom's Develop ▸ 色彩 ▸ 校准): **seven
/// numbers** that become one 3×3 matrix on the working primaries, applied at S1's exit.
///
/// | number | −100…+100 | what it does |
/// |---|---|---|
/// | `shadowTint` | green ↔ magenta | only the shadows (a window in log light, luminance kept) |
/// | `redHue` / `greenHue` / `blueHue` | degrees | rotate that primary around the hue circle |
/// | `redSat` / `greenSat` / `blueSat` | chroma | push that primary toward grey / toward its edge |
///
/// ## Why a matrix, and why at S1's exit
///
/// A primary is a *direction* in linear RGB, so "move the red primary" is a 3×3 matrix `M` with
/// `M·e_r = q_r` (the new red), and no other stage can express it: S3.6's HSL bands work on already
/// tone-mapped codes, S1.8 is a luminance decomposition. The matrix is applied where the working
/// primaries are still honest — the end of S1, on `s1_scene_linear`'s own output, in the same place
/// the CPU already hands S1 a uniform. It is **not** a new stage: no new `RenderStage`, no new link
/// in the key chain, no new texture. `StageAlgorithmVersion.sceneLinear` moves 7 → 8 because the
/// stage's arithmetic grew a term.
///
/// ## The derivation (`matrix()`), and the reference
///
/// Ported from LightCraft (`crates/pipeline/src/colorops.rs#calibration_matrix` /
/// `#calibrate`, MIT OR Apache-2.0) — one function, rewritten in `Double` on `Matrix3`:
///
///   1. take the primary's unit vector `e_i` in **linear Rec.2020** (the working space,
///      `ColorPrimaries.working`) and convert it to **OkLab** (Ottosson's XYZ→LMS and LMS→Lab
///      constants, composed with `ColorPrimaries.rec2020.toXYZ`);
///   2. read it as `L, C, h`; write back `L, C·(1 + sat/100·0.6), h + hue·1°` — hue is dragged at
///      **constant OkLab lightness and constant *scaled* chroma**, which is what makes a hue slider
///      a rotation rather than a brightness move;
///   3. if the result left the cube (a primary rotated at full chroma always does), **reduce chroma
///      at that same `L, h`** until it is back inside (`0…1` per channel, 40 halvings). This is the
///      one place this port improves on the reference: LightCraft writes the out-of-gamut column and
///      clips later, and clipping *is* a hue change — measured, the red primary rotated +30° came
///      back as **+4.9°** with the clip, and **+30.00°** without it;
///   4. `P`'s columns are the three new primaries; solve `P·k = (1,1,1)` and scale column `i` by
///      `k_i`. That is the **white-point constraint**: `M·(1,1,1) = P·k = (1,1,1)` exactly, so a
///      neutral pixel is a fixed point of the whole matrix and `0.18` grey cannot take a cast.
///
/// Two consequences worth writing down, because they are theorems and not tuning:
///
///   · **A primary that does not move is untouched.** With `hue = sat = 0` the column is the unit
///     vector itself (the round trip is skipped), so `G` and `B` pixels of a red-hue move are
///     literally unchanged, and so is any colour that is only G and B (`cyan = e_g + e_b`).
///   · **The colour *opposite* a moved primary must move.** `Σ m_i = (1,1,1)` forces
///     `m_j + m_k = (1,1,1) − m_i`, so with red rotated +30° the cyan patch *has* to shift: a
///     brute-force search over every in-gamut `m` whose OkLab hue is red + 30° found no candidate
///     that keeps cyan inside 10.6°, and the constructed matrix measures **+13.4°**. That is the
///     price of the white point, not a bug in the port (see `CalibrationTests`).
///
/// ## The exact identity
///
/// `matrix()` returns **nil** when all seven numbers are 0 — not `Matrix3.identity`, and not
/// "1 ± 1e-16": there is no matrix, the graph dispatches S1's calibration-free entry point, no
/// uniform is bound, and `keyToken` is nil so the S1 key material is byte-identical to 178's. The
/// unit matrix is a *structural* fact (the branch), which is the only kind that can survive a
/// shader compiler.
public struct CalibrationGroup: Sendable, Equatable, Codable {

    /// The sliders' travel, and the unit the document stores: **−100…+100**, one number per row.
    /// The document holds the slider number itself (unlike 校正's α): a hue is a hue, and `+30` in
    /// the panel is `+30` in the file and `+30°` on the colour wheel.
    public static let sliderRange: ClosedRange<Double> = -100 ... 100

    /// Degrees of OkLab hue per slider unit: **+30 reads +30°**. LightCraft's `CALIB_HUE` is 0.5 rad
    /// at ±100 (28.6° at full travel, 8.6° at 30); the panel here is calibrated in degrees because
    /// that is the number the acceptance is written in and the number a colourist can check against
    /// a wheel.
    public static let hueDegreesPerUnit = 1.0

    /// Chroma multiplier at ±100 of a saturation row (`1 ± 0.6`, LightCraft's `CALIB_SAT`): full
    /// travel leaves 40 % of the primary's chroma, or 160 % (gamut-mapped back).
    public static let saturationScale = 0.6

    /// Green-channel change at `shadowTint = ±100` in the deepest shadows. LightCraft uses 0.3; that
    /// puts the deepest shadows (`Y = 0.004`) at Δa\* **+1.37**, under the 2-code floor the contract
    /// asks for, so the travel is 0.5 — measured **+2.47** at `Y = 0.004` and **+4.13** at
    /// `Y = 0.02`. Above `Y = 0.127` the window is exactly 0, so nothing but the shadows moves.
    public static let shadowTintScale = 0.5

    /// Shadows' green↔magenta, −100…+100.
    public var shadowTint: Double

    public var redHue: Double
    public var redSat: Double
    public var greenHue: Double
    public var greenSat: Double
    public var blueHue: Double
    public var blueSat: Double

    public static let identity = CalibrationGroup()

    public init(shadowTint: Double = 0,
                redHue: Double = 0, redSat: Double = 0,
                greenHue: Double = 0, greenSat: Double = 0,
                blueHue: Double = 0, blueSat: Double = 0) {
        self.shadowTint = shadowTint
        self.redHue = redHue
        self.redSat = redSat
        self.greenHue = greenHue
        self.greenSat = greenSat
        self.blueHue = blueHue
        self.blueSat = blueSat
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = CalibrationGroup.identity
        v.shadowTint = c.val("shadowTint", v.shadowTint)
        v.redHue = c.val("redHue", v.redHue)
        v.redSat = c.val("redSat", v.redSat)
        v.greenHue = c.val("greenHue", v.greenHue)
        v.greenSat = c.val("greenSat", v.greenSat)
        v.blueHue = c.val("blueHue", v.blueHue)
        v.blueSat = c.val("blueSat", v.blueSat)
        self = v
    }

    /// All seven at zero — the graph's S1 fast path, the key's silence and the uniform's absence all
    /// key off exactly this.
    public var isIdentity: Bool {
        shadowTint == 0 && redHue == 0 && redSat == 0
            && greenHue == 0 && greenSat == 0 && blueHue == 0 && blueSat == 0
    }

    /// The three `(hue, sat)` pairs, in `R, G, B` order — the shape `matrix()` walks.
    public var primaries: [(hue: Double, sat: Double)] {
        [(redHue, redSat), (greenHue, greenSat), (blueHue, blueSat)]
    }

    /// Clamped to the travel (a hand-edited document cannot ask for 400°), as a green multiplier
    /// factor `−1…+1` for the kernel's uniform.
    public var clampedShadowTint: Double {
        guard shadowTint.isFinite else { return 0 }
        return min(max(shadowTint, Self.sliderRange.lowerBound),
                   Self.sliderRange.upperBound) / 100
    }

    private static func clamped(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, sliderRange.lowerBound), sliderRange.upperBound)
    }

    /// The key's own units: **integer tenths of a slider unit** (`25` = position 2.5), the same
    /// resolution `OpticsGroup.keyDeciles` uses and for the same reason.
    public static func keyTenths(_ v: Double) -> Int {
        Int((clamped(v) * 10).rounded())
    }

    /// The S1 key material's `;cal=` segment, or **nil when everything is at 0** — the whole reason a
    /// neutral document's key string is unchanged. Only the non-default numbers are spelled, so a
    /// document that moved 阴影 tint alone carries one short token, not seven zeros.
    public var keyToken: String? {
        guard !isIdentity else { return nil }
        var t = ";cal"
        if shadowTint != 0 { t += ";t=\(Self.keyTenths(shadowTint))" }
        for (name, pair) in [("r", (redHue, redSat)), ("g", (greenHue, greenSat)),
                             ("b", (blueHue, blueSat))] {
            guard pair.0 != 0 || pair.1 != 0 else { continue }
            t += ";\(name)=\(Self.keyTenths(pair.0))/\(Self.keyTenths(pair.1))"
        }
        return t
    }

    // MARK: - the matrix

    /// The primaries matrix on **linear Rec.2020**, or **nil** when all seven numbers are 0.
    ///
    /// `nil` is the identity: a `Matrix3.identity` here would be "the arithmetic with zeros in it",
    /// and 071 measured what that costs (a branch in the kernel moved 2980/12309 samples by one ULP).
    /// A caller that needs nine numbers writes its own unit matrix and says why.
    public func matrix() -> Matrix3? {
        guard !isIdentity else { return nil }
        var columns: [SIMD3<Double>] = []
        columns.reserveCapacity(3)
        for (i, pair) in primaries.enumerated() {
            var e = SIMD3<Double>(0, 0, 0)
            e[i] = 1
            let hue = Self.clamped(pair.hue)
            let sat = Self.clamped(pair.sat)
            guard hue != 0 || sat != 0 else {
                // Untouched: the unit vector itself, so the other two primaries are *literally*
                // unchanged and `Σ m = (1,1,1)` stays exact.
                columns.append(e)
                continue
            }
            let lab = Self.oklab(fromRec2020: e)
            let lightness = lab.x
            let chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
            let h = atan2(lab.z, lab.y)
            let h2 = h + hue * Self.hueDegreesPerUnit * .pi / 180
            let c2 = max(chroma * (1 + sat / 100 * Self.saturationScale), 0)
            columns.append(Self.gamutMappedLightness(lightness, chroma: c2, hue: h2))
        }
        let p = Matrix3(rows: [
            [columns[0].x, columns[1].x, columns[2].x],
            [columns[0].y, columns[1].y, columns[2].y],
            [columns[0].z, columns[1].z, columns[2].z],
        ])
        // A degenerate triple (three primaries collapsed onto one line) has no white point to solve
        // for. Saturation −100 on all three rows is the only way to get near it, and the honest answer
        // there is "no matrix", not a silently-singular one.
        let det = p.determinant
        guard det.isFinite, abs(det) > 1e-6 else { return nil }
        let k = p.inverted().applying(to: SIMD3(1, 1, 1))
        let m = Matrix3(rows: (0..<3).map { r in
            (0..<3).map { c in p[r, c] * k[c] }
        })
        guard m.values.allSatisfy({ $0.isFinite }) else { return nil }
        return m
    }

    /// The matrix in the kernel's layout: three `SIMD4` rows (`xyz` used, `w` zero), plus the tint.
    ///
    /// `nil` when `isIdentity`. When only the tint moved this is the exact unit matrix *and* a
    /// non-zero tint — the two travel in one struct because they are one stage parameter, and the
    /// unit matrix costs the kernel three dot products it already had to do.
    public var uniform: (rows: (SIMD4<Double>, SIMD4<Double>, SIMD4<Double>), tint: Double)? {
        guard !isIdentity else { return nil }
        let m = matrix() ?? Matrix3(rows: [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
        return ((SIMD4(m[0, 0], m[0, 1], m[0, 2], 0),
                 SIMD4(m[1, 0], m[1, 1], m[1, 2], 0),
                 SIMD4(m[2, 0], m[2, 1], m[2, 2], 0)),
                clampedShadowTint)
    }

    // MARK: - OkLab on the working primaries (the derivation's arithmetic)

    /// Linear Rec.2020 → OkLab. Ottosson's two published matrices, composed with this project's own
    /// Rec.2020 → XYZ (`ColorPrimaries.rec2020.toXYZ`) so there is no second copy of the primaries.
    static func oklab(fromRec2020 v: SIMD3<Double>) -> SIMD3<Double> {
        let lms = toLMS.applying(to: v)
        let rooted = SIMD3(cbrt(lms.x), cbrt(lms.y), cbrt(lms.z))
        return lmsToLab.applying(to: rooted)
    }

    /// OkLab → linear Rec.2020 (the exact inverse of `oklab(fromRec2020:)`).
    static func rec2020(fromOklab lab: SIMD3<Double>) -> SIMD3<Double> {
        let rooted = labToLMS.applying(to: lab)
        let lms = SIMD3(rooted.x * rooted.x * rooted.x,
                        rooted.y * rooted.y * rooted.y,
                        rooted.z * rooted.z * rooted.z)
        return lmsToRec2020.applying(to: lms)
    }

    /// `L, C, h` at `L` and `h`, with the chroma **reduced** until the colour is inside the unit
    /// cube. Reducing chroma at constant `L` and `h` is the only move that leaves the hue (the thing
    /// the slider names) exactly where it was put — see the type's note, step 3.
    static func gamutMappedLightness(_ lightness: Double, chroma: Double, hue: Double) -> SIMD3<Double> {
        func at(_ scale: Double) -> SIMD3<Double> {
            let h = hue
            return rec2020(fromOklab: SIMD3(lightness, chroma * scale * cos(h), chroma * scale * sin(h)))
        }
        let full = at(1)
        if full.min() >= 0, full.max() <= 1 { return full }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            let q = at(mid)
            if q.min() >= 0, q.max() <= 1 { lo = mid } else { hi = mid }
        }
        return at(lo)
    }

    /// `XYZ → LMS` (Ottosson 2020), then this project's `Rec.2020 → XYZ`.
    private static let toLMS: Matrix3 = {
        Matrix3(rows: [[0.8189330101, 0.3618667424, -0.1288597137],
                       [0.0329845436, 0.9293118715, 0.0361456387],
                       [0.0482003018, 0.2643662691, 0.6338517070]]) * ColorPrimaries.rec2020.toXYZ
    }()
    private static let lmsToLab = Matrix3(rows: [[0.2104542553, 0.7936177850, -0.0040720468],
                                                [1.9779984951, -2.4285922050, 0.4505937099],
                                                [0.0259040371, 0.7827717662, -0.8086757660]])
    private static let labToLMS = lmsToLab.inverted()
    private static let lmsToRec2020 = toLMS.inverted()
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
