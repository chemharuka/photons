import Foundation

// MARK: - Copy/paste settings (M5)
//
// "Copy settings" is not "copy the document". Pasting a whole `EditModel` would drag along every
// field the user never touched — 57 leaves of defaults for a one-slider edit — and, worse, would
// overwrite the destination's own values with those defaults. Lightroom's copy/paste copies
// *settings*, and the UI shows a checklist of exactly which ones are non-default.
//
// So the clipboard payload is **sparse**: one optional per leaf parameter, present only when it
// differs from `EditModel`'s default value (the same defaults the document decoder falls back to,
// D9). Three consequences, each tested:
//
//  1. Copying a document that changed one slider carries exactly one field.
//  2. Pasting onto a document that already has an edit changes only those fields — the
//     destination's other values survive, which is the whole point of "paste settings".
//  3. Copying a *neutral* document carries nothing, and pasting nothing is a no-op.
//
// Masks are in this type as of P1-5 (2026-10-28), and only as a **list plus the aspect ratio of the
// frame they were measured in**. They used to be structurally absent, because a mask's geometry is
// normalised to *its own* frame and meant nothing on another photo (docs/xmp-mapping.md §1.8, D11).
// What changed is not that claim but the answer to it: `MaskFrameTransfer` re-anchors every point on
// the target's short edge, so the shape keeps its size and its relationship to the picture, and a
// paste re-identifies each mask so the destination's ids stay unique. Two consequences worth stating
// here because they are the ones a reader will look for:
//
//  · `masks` is a *patch* like every other section — absent means "the destination keeps its own
//    list", and a paste **appends** rather than replaces, so pasting two masks onto a photo that has
//    one leaves three. Replacing would be the one merge in this file that can delete something the
//    user never named.
//  · `showMaskID` is still never carried: it is view state (005e), and `MaskViewState` keeps it out
//    of snapshots on the write side too.
//
// **Known gap (2026-10-28, recorded rather than implied):** 色彩分级 (`EditModel.colorGrading`, S3.8)
// has no `ColorGradingPatch` yet, so 「复制设置」 does not carry it — a paste of 全部 leaves the
// destination's grade alone and does not overwrite it either (nothing is written, so nothing is
// lost on the destination). Presets **do** carry it (`PresetGroup.colorGrading`). The patch is the
// follow-up: nine optional numbers, one per `GradeWheel` axis, and the section table would gain a
// 「色彩分级」 row. Until then this file says so, because a group that silently is not copied is
// worse than one this header names.

/// Which fields belong to which group. Used for reporting what a clipboard payload carries.
public enum EditSnapshotGroup: String, CaseIterable, Sendable, Hashable {
    case geometry, light, curve, color, detail, effects
}

// MARK: - sections (派单 078 P0-7: 选组)

/// The **sections** a paste can be narrowed to — finer than `EditSnapshotGroup` on purpose.
///
/// `light` is split in two because white balance is not the Light panel in either implementation
/// that matters: in Lightroom the 复制设置 checklist has `White Balance` **and** `Light` as separate
/// rows, and here the two are also different *pipeline stages* — Kelvin/tint re-develop the buffer
/// (`DecodeInputs.whiteBalance`), exposure/contrast/highlights/shadows/whites/blacks re-render it.
/// One group for both would mean 「只粘曝光」 necessarily clobbering the destination's own balance,
/// which is the exact complaint this ticket exists to answer.
///
/// `masks` is a section like every other one as of P1-5 (2026-10-28). It used to be listed for
/// parity with Lightroom and refused (`isCopyable == false`) because mask geometry is framed relative
/// to the source photo. It is copyable now because `MaskFrameTransfer` re-anchors each mask on the
/// target frame's short edge — the geometry is carried *as a shape relative to the picture*, which is
/// the only portable meaning those coordinates have (the reasoning, with the numbers, is in that
/// file's header). Nothing about the copy touches the destination's own masks: a paste appends.
public enum EditSnapshotSection: String, CaseIterable, Sendable, Hashable, Codable {
    /// 裁切/拉直/翻转/比例 — the crop rect's four edges are one section (a crop is one gesture).
    case geometry
    /// 色温/色调 — the only **decode-class** section a snapshot can carry.
    case whiteBalance
    /// 曝光/对比/高光/阴影/白/黑/高光恢复 — the Light panel minus white balance.
    case light
    case curve
    case color
    case detail
    case effects
    /// 蒙版 — the mask list, re-identified and re-anchored on paste (P1-5).
    case masks

    /// The checklist order the dialog draws: the order Lightroom's own list uses.
    public static let panelOrder: [EditSnapshotSection] = [
        .whiteBalance, .light, .curve, .color, .detail, .effects, .geometry, .masks,
    ]

    /// Every section a paste can write — all of them, masks included since P1-5.
    public static var copyable: [EditSnapshotSection] { panelOrder.filter(\.isCopyable) }

    public var isCopyable: Bool { true }

    /// Does a paste of this section have to **develop again** (a new buffer), or only re-render?
    ///
    /// `whiteBalance` is `DecodeInputs.whiteBalance` and a Kelvin change is measured to move
    /// 0.15–0.40 % of samples — a new rung, not a new S1 pass (派单 006/011). Everything else here
    /// keys the render graph, and `detail` is *stored, not rendered* (`DetailGroup`'s header) so it
    /// cannot move a buffer either. The decoder model (`decoderVersion`) is not a section at all:
    /// `EditSnapshot` does not carry it (it is a per-file decoder fact, not a develop setting).
    public var requiresDecode: Bool { self == .whiteBalance }

    public var title: String {
        switch self {
        case .geometry: return "裁切"
        case .whiteBalance: return "白平衡"
        case .light: return "曝光"
        case .curve: return "曲线"
        case .color: return "颜色"
        case .detail: return "细节"
        case .effects: return "效果"
        case .masks: return "蒙版"
        }
    }

    /// The tooltip a row may carry. Every row is selectable since P1-5; 蒙版 gets a sentence that
    /// says what a mask copy actually does, because "carried across photos" alone would hide both of
    /// its non-obvious properties (new ids, short-edge anchoring).
    public var help: String? {
        self == .masks
            ? "蒙版按目标照片的短边重新锚定，粘贴时生成新的蒙版 id（目标照片自己的蒙版保留）"
            : nil
    }
}

/// The checked rows of 「选择要复制的设置」.
///
/// A value type, not a view: the dialog draws it and the session stores it, and the three answers
/// the ticket asks for — 全选 / 全不选 / 预设组合 — are `all`, `none` and `preset(_:)` here, so the
/// buttons cannot disagree with what gets pasted.
public struct CopySettingsSelection: Sendable, Equatable, Codable {

    /// 预设组合. Deliberately few and named after what a photographer is carrying around, not after
    /// the panel tree: "基本" is the tone+balance tripod, "颜色" is everything that decides colour,
    /// "几何" is the crop.
    public enum Preset: String, CaseIterable, Sendable, Hashable {
        case all
        case basic
        case color
        case geometry
        case whiteBalance
        case none

        public var title: String {
            switch self {
            case .all: return "全部"
            case .basic: return "基本：白平衡 + 曝光 + 曲线"
            case .color: return "颜色：颜色 + 细节 + 效果"
            case .geometry: return "几何：裁切"
            case .whiteBalance: return "仅白平衡"
            case .none: return "全不选"
            }
        }

        public var sections: Set<EditSnapshotSection> {
            switch self {
            case .all: return Set(EditSnapshotSection.copyable)
            case .basic: return [.whiteBalance, .light, .curve]
            case .color: return [.color, .detail, .effects]
            case .geometry: return [.geometry]
            case .whiteBalance: return [.whiteBalance]
            case .none: return []
            }
        }
    }

    /// Always a subset of `EditSnapshotSection.copyable` — every row is selectable since P1-5, so the
    /// filter in `init` is a guard rather than a rule: a section that is ever made unavailable again
    /// cannot leak into a paste through a hand-made set.
    public private(set) var sections: Set<EditSnapshotSection>

    public init(sections: Set<EditSnapshotSection> = Set(EditSnapshotSection.copyable)) {
        self.sections = sections.filter(\.isCopyable)
    }

    public init(_ preset: Preset) { self.init(sections: preset.sections) }

    public static var all: CopySettingsSelection { CopySettingsSelection(.all) }
    public static var none: CopySettingsSelection { CopySettingsSelection(.none) }

    public var isEmpty: Bool { sections.isEmpty }

    /// `.all` when every copyable row is checked, `.none` when none is, otherwise `nil` (自定义).
    public var matchingPreset: Preset? {
        let copyable = Set(EditSnapshotSection.copyable)
        if sections.isEmpty { return .none }
        if sections == copyable { return .all }
        return Preset.allCases.first { $0.sections == sections && $0 != .all && $0 != .none }
    }

    public func contains(_ section: EditSnapshotSection) -> Bool { sections.contains(section) }

    public mutating func set(_ section: EditSnapshotSection, _ on: Bool) {
        guard section.isCopyable else { return }
        if on { sections.insert(section) } else { sections.remove(section) }
    }

    public mutating func toggle(_ section: EditSnapshotSection) { set(section, !sections.contains(section)) }

    public mutating func select(_ preset: Preset) { self = CopySettingsSelection(preset) }

    public mutating func selectAll() { sections = Set(EditSnapshotSection.copyable) }
    public mutating func selectNone() { sections = [] }

    /// One line for the dialog's status label.
    public var summary: String {
        if sections.isEmpty { return "未选任何组：粘贴什么也不会发生" }
        let names = EditSnapshotSection.panelOrder.filter { sections.contains($0) }.map(\.title)
        return "将复制：\(names.joined(separator: " · "))"
    }
}

// MARK: - patches

/// Geometry, leaf by leaf. A crop rect is normally stored whole (capture sees four changed
/// components), but each edge is its own field so a paste that changes only `x` keeps the
/// destination's width.
public struct GeometryPatch: Sendable, Equatable, Codable {
    public var cropX: Double?
    public var cropY: Double?
    public var cropWidth: Double?
    public var cropHeight: Double?
    public var rotationDegrees: Double?
    public var flipHorizontal: Bool?
    public var flipVertical: Bool?
    public var aspectLock: AspectLock?
    /// 2026-10-28 (P0-10): the 90° turn. Its own leaf, not folded into the crop: a copy that carries
    /// the crop must carry the turn, or the rect would land in a frame it was not measured in. Kept
    /// `nil` when 0 so every pre-9 snapshot keeps its bytes.
    public var quarterTurns: Int?

    public init() {}

    public var fieldCount: Int {
        [cropX != nil, cropY != nil, cropWidth != nil, cropHeight != nil,
         rotationDegrees != nil, flipHorizontal != nil, flipVertical != nil,
         aspectLock != nil, quarterTurns != nil].filter { $0 }.count
    }

    public var isEmpty: Bool { fieldCount == 0 }

    /// Leaf count of the whole group in a full document (see `EditSnapshot.fullDocumentFieldCount`).
    public static let fullFieldCount = 9
}

public struct LightPatch: Sendable, Equatable, Codable {
    public var exposure: Double?
    public var contrast: Double?
    public var highlights: Double?
    public var shadows: Double?
    public var whites: Double?
    public var blacks: Double?
    public var temperature: Double?
    public var tint: Double?
    public var highlightRecovery: Double?

    public init() {}

    public var fieldCount: Int {
        [exposure != nil, contrast != nil, highlights != nil, shadows != nil, whites != nil,
         blacks != nil, temperature != nil, tint != nil, highlightRecovery != nil]
            .filter { $0 }.count
    }

    public var isEmpty: Bool { fieldCount == 0 }

    public static let fullFieldCount = 9
}

/// Tone curves: four LUTs, each stored only when it is not the identity ramp. A curve is one field
/// per channel, not 16 points — the points are the value.
public struct CurvePatch: Sendable, Equatable, Codable {
    public var rgb: [CurvePoint]?
    public var red: [CurvePoint]?
    public var green: [CurvePoint]?
    public var blue: [CurvePoint]?

    public init() {}

    public var fieldCount: Int {
        [rgb != nil, red != nil, green != nil, blue != nil].filter { $0 }.count
    }

    public var isEmpty: Bool { fieldCount == 0 }

    public static let fullFieldCount = 4
}

/// One HSL band, sparse. `index` is position in Lightroom's eight-band order and is not a field.
public struct HSLBandPatch: Sendable, Equatable, Codable {
    public var index: Int
    public var hue: Double?
    public var saturation: Double?
    public var luminance: Double?
    /// 2026-10-28 (P0-4): 黑白混合, on the same band.
    public var mix: Double?

    public init(index: Int, hue: Double? = nil, saturation: Double? = nil, luminance: Double? = nil,
                mix: Double? = nil) {
        self.index = index
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
        self.mix = mix
    }

    public var fieldCount: Int {
        [hue != nil, saturation != nil, luminance != nil, mix != nil].filter { $0 }.count
    }

    public var isEmpty: Bool { fieldCount == 0 }
}

public struct ColorPatch: Sendable, Equatable, Codable {
    public var vibrance: Double?
    public var saturation: Double?
    /// Only the bands that differ from `HSLBand()`; absent bands are the destination's.
    public var bands: [HSLBandPatch]?
    /// 2026-10-28 (P0-4): the 黑白 switch. Copied as a field of its own so "paste onto a colour photo"
    /// can carry the mode — a mix list without the switch is a look nobody asked for.
    public var blackAndWhite: Bool?

    public init() {}

    public var fieldCount: Int {
        [vibrance != nil, saturation != nil, blackAndWhite != nil].filter { $0 }.count
            + (bands ?? []).reduce(0) { $0 + $1.fieldCount }
    }

    public var isEmpty: Bool { fieldCount == 0 }

    public static let fullFieldCount = 3 + ColorGroup.bandCount * 4
}

public struct DetailPatch: Sendable, Equatable, Codable {
    public var sharpening: Double?
    public var sharpeningRadius: Double?
    public var noiseLuminance: Double?
    public var noiseColor: Double?
    public var lensCorrections: Bool?

    public init() {}

    public var fieldCount: Int {
        [sharpening != nil, sharpeningRadius != nil, noiseLuminance != nil, noiseColor != nil,
         lensCorrections != nil].filter { $0 }.count
    }

    public var isEmpty: Bool { fieldCount == 0 }

    public static let fullFieldCount = 5
}

public struct EffectsPatch: Sendable, Equatable, Codable {
    public var vignetteAmount: Double?
    public var vignetteMidpoint: Double?
    public var vignetteFeather: Double?
    public var vignetteRoundness: Double?
    public var grain: Double?
    /// 2026-10-28 (P0-6): S3.8's three numbers. Sparse like every other leaf — a copy of a
    /// vignette-only look carries no `texture`, so pasting it leaves the target's 纹理 alone.
    public var texture: Double?
    public var clarity: Double?
    public var dehaze: Double?

    public init() {}

    public var fieldCount: Int {
        [vignetteAmount != nil, vignetteMidpoint != nil, vignetteFeather != nil,
         vignetteRoundness != nil, grain != nil,
         texture != nil, clarity != nil, dehaze != nil].filter { $0 }.count
    }

    public var isEmpty: Bool { fieldCount == 0 }

    public static let fullFieldCount = 8
}

// MARK: - the snapshot

/// The mask list, plus the one number that makes it portable.
///
/// `frameAspect` is `W/H` of the **uncropped source frame** the mask coordinates were measured in
/// (after EXIF orientation — `MaskSourceFrame`'s upright frame). A document does not store its own
/// pixel size, so the clipboard payload carries the ratio itself: without it a paste cannot know
/// whether a 4:3-shaped mask is landing on a 3:2 picture, and `MaskFrameTransfer` would have to fall
/// back to copying raw fractions. `nil` means "the caller did not know the frame" and is the honest
/// fallback, not an error.
///
/// Every mask travels whole — name, enable flag, opacity, invert, feather, refine, components and
/// all eleven `LocalAdjustments` — because a mask without its adjustment is a shape with no purpose,
/// and a mask without its feather is a different picture. Only identity (ids) is replaced, at paste.
public struct MasksPatch: Sendable, Equatable, Codable {
    public var frameAspect: Double?
    public var masks: [Mask]

    public init(frameAspect: Double? = nil, masks: [Mask] = []) {
        self.frameAspect = frameAspect
        self.masks = masks
    }

    public var isEmpty: Bool { masks.isEmpty }

    /// One mask per entry — a mask is a nested document, not a slider, so it is not counted in
    /// `EditSnapshot.fieldCount` (whose job is the sparse-leaf arithmetic: 1 slider = 1 field).
    public var fieldCount: Int { masks.count }
}

/// A sparse, transferable set of develop settings: the clipboard payload of "copy settings".
public struct EditSnapshot: Sendable, Equatable, Codable {
    /// Bumped when the sparse shape changes. Independent of `EditModel.currentSchemaVersion`; a
    /// snapshot is a message, not a document.
    ///
    /// **1 → 2 (P1-5, 2026-10-28): the `masks` key.** Not because a decoder would break — every
    /// field here is read with a default, so a v1 payload still decodes (as "no masks") and a v2
    /// payload read by a v1 build simply loses its masks. It is bumped because the *shape* is what
    /// this number names, and the difference is not cosmetic in one direction: a v1 payload can only
    /// ever mean "mask list unknown/absent", while a v2 payload may carry one, and a reader that
    /// silently drops masks would report a paste as complete when it was not. `EditModel`'s own
    /// `schemaVersion` is untouched — masks already exist in the document; only the clipboard grew.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var geometry: GeometryPatch?
    public var light: LightPatch?
    public var curve: CurvePatch?
    public var color: ColorPatch?
    public var detail: DetailPatch?
    public var effects: EffectsPatch?
    public var masks: MasksPatch?

    public init() {
        self.schemaVersion = EditSnapshot.currentSchemaVersion
    }

    // MARK: capture

    /// Everything in `edit` that differs from the neutral document.
    ///
    /// `frameAspect` is passed through into `masks`: the document knows its masks but not the size of
    /// the picture they were drawn on, so only the caller (the loupe's ingested frame, or a catalog
    /// row) can supply it. Capture never drops a mask for want of it — the mask is still the user's
    /// setting; only the cross-photo anchoring degrades to "copy the fractions".
    public static func capture(_ edit: EditModel, frameAspect: Double? = nil) -> EditSnapshot {
        var s = EditSnapshot()


        var geometry = GeometryPatch()
        if differs(edit.geometry.crop.x, NormalizedRect.full.x) { geometry.cropX = edit.geometry.crop.x }
        if differs(edit.geometry.crop.y, NormalizedRect.full.y) { geometry.cropY = edit.geometry.crop.y }
        if differs(edit.geometry.crop.width, NormalizedRect.full.width) { geometry.cropWidth = edit.geometry.crop.width }
        if differs(edit.geometry.crop.height, NormalizedRect.full.height) { geometry.cropHeight = edit.geometry.crop.height }
        if edit.geometry.quarterTurns != 0 { geometry.quarterTurns = edit.geometry.quarterTurns }
        if differs(edit.geometry.rotationDegrees, 0) { geometry.rotationDegrees = edit.geometry.rotationDegrees }
        if edit.geometry.flipHorizontal { geometry.flipHorizontal = true }
        if edit.geometry.flipVertical { geometry.flipVertical = true }
        if edit.geometry.aspectLock != .original { geometry.aspectLock = edit.geometry.aspectLock }
        s.geometry = geometry.isEmpty ? nil : geometry

        var light = LightPatch()
        if differs(edit.light.exposure, 0) { light.exposure = edit.light.exposure }
        if differs(edit.light.contrast, 0) { light.contrast = edit.light.contrast }
        if differs(edit.light.highlights, 0) { light.highlights = edit.light.highlights }
        if differs(edit.light.shadows, 0) { light.shadows = edit.light.shadows }
        if differs(edit.light.whites, 0) { light.whites = edit.light.whites }
        if differs(edit.light.blacks, 0) { light.blacks = edit.light.blacks }
        // 派单 006: white balance has no neutral *number* to compare against any more — either the
        // document follows the file (`nil`, nothing to copy) or it pins a value (always copied, even
        // 6500 K, because pinning 6500 K on a 4803 K shot is a real setting).
        if let t = edit.light.temperature { light.temperature = t }
        if let i = edit.light.tint { light.tint = i }
        if differs(edit.light.highlightRecovery, 0) { light.highlightRecovery = edit.light.highlightRecovery }
        s.light = light.isEmpty ? nil : light

        var curve = CurvePatch()
        // `CurvePatch.rgb` keeps its (pre-030) name because it is the shape of the preset/snapshot
        // JSON, not of the document: the field still carries the luminance curve, now `white`.
        if !same(edit.curve.white, CurvePoint.linear) { curve.rgb = edit.curve.white }
        if !same(edit.curve.red, CurvePoint.linear) { curve.red = edit.curve.red }
        if !same(edit.curve.green, CurvePoint.linear) { curve.green = edit.curve.green }
        if !same(edit.curve.blue, CurvePoint.linear) { curve.blue = edit.curve.blue }
        s.curve = curve.isEmpty ? nil : curve

        var color = ColorPatch()
        if differs(edit.color.vibrance, 0) { color.vibrance = edit.color.vibrance }
        if differs(edit.color.saturation, 0) { color.saturation = edit.color.saturation }
        // 2026-10-28 (P0-4): the switch is a value like any other, and `false` is the destination's
        // default — so only "on" travels (「只带非默认字段」).
        if edit.color.blackAndWhite { color.blackAndWhite = true }
        var bands: [HSLBandPatch] = []
        for (i, band) in ColorGroup.normalize(edit.color.bands).enumerated() {
            var patch = HSLBandPatch(index: i)
            if differs(band.hue, 0) { patch.hue = band.hue }
            if differs(band.saturation, 0) { patch.saturation = band.saturation }
            if differs(band.luminance, 0) { patch.luminance = band.luminance }
            if differs(band.mix, 0) { patch.mix = band.mix }
            if !patch.isEmpty { bands.append(patch) }
        }
        if !bands.isEmpty { color.bands = bands }
        s.color = color.isEmpty ? nil : color

        var detail = DetailPatch()
        if differs(edit.detail.sharpening, 0) { detail.sharpening = edit.detail.sharpening }
        if differs(edit.detail.sharpeningRadius, 1.0) { detail.sharpeningRadius = edit.detail.sharpeningRadius }
        if differs(edit.detail.noiseLuminance, 0) { detail.noiseLuminance = edit.detail.noiseLuminance }
        if differs(edit.detail.noiseColor, 0) { detail.noiseColor = edit.detail.noiseColor }
        if edit.detail.lensCorrections { detail.lensCorrections = true }
        s.detail = detail.isEmpty ? nil : detail

        var effects = EffectsPatch()
        if differs(edit.effects.vignetteAmount, 0) { effects.vignetteAmount = edit.effects.vignetteAmount }
        if differs(edit.effects.vignetteMidpoint, 50) { effects.vignetteMidpoint = edit.effects.vignetteMidpoint }
        if differs(edit.effects.vignetteFeather, 50) { effects.vignetteFeather = edit.effects.vignetteFeather }
        if differs(edit.effects.vignetteRoundness, 0) { effects.vignetteRoundness = edit.effects.vignetteRoundness }
        if differs(edit.effects.grain, 0) { effects.grain = edit.effects.grain }
        if differs(edit.effects.texture, 0) { effects.texture = edit.effects.texture }
        if differs(edit.effects.clarity, 0) { effects.clarity = edit.effects.clarity }
        if differs(edit.effects.dehaze, 0) { effects.dehaze = edit.effects.dehaze }
        s.effects = effects.isEmpty ? nil : effects

        // Masks: present when the document has any. `showMaskID` is view state and stays out (see
        // `MaskViewState`), and an empty list is "nothing to copy", not "paste an empty list".
        if !edit.masks.isEmpty {
            s.masks = MasksPatch(frameAspect: frameAspect, masks: edit.masks)
        }

        return s
    }

    // MARK: reading the payload

    /// Number of stored leaves. The point of the type: a one-slider copy is 1, the document it came
    /// from is `fullDocumentFieldCount` (70). Masks are counted separately (`maskCount`): a mask is a
    /// nested document, and folding it into this arithmetic would make "1 slider + 1 mask" read as
    /// 2 leaves of 70 — a fraction that means nothing.
    public var fieldCount: Int {
        (geometry?.fieldCount ?? 0) + (light?.fieldCount ?? 0) + (curve?.fieldCount ?? 0)
            + (color?.fieldCount ?? 0) + (detail?.fieldCount ?? 0) + (effects?.fieldCount ?? 0)
    }

    /// How many masks the payload carries. 0 = a paste leaves the destination's list alone.
    public var maskCount: Int { masks?.masks.count ?? 0 }

    public var isEmpty: Bool { fieldCount == 0 && maskCount == 0 }

    /// Leaves a full `EditModel` carries — the denominator `fieldCount` is compared against.
    /// geometry 9 (4 crop edges + straighten + 2 flips + aspect lock + `quarterTurns`) + light 9
    /// + curve 4 + color 26 (2 + 8 bands × 3) + detail 5 + effects 5.
    public static let fullDocumentFieldCount =
        GeometryPatch.fullFieldCount + LightPatch.fullFieldCount + CurvePatch.fullFieldCount
        + ColorPatch.fullFieldCount + DetailPatch.fullFieldCount + EffectsPatch.fullFieldCount

    /// Groups with at least one field present, for a "copied: Light, Color" line.
    public var groups: Set<RenderGroup> {
        var out: Set<RenderGroup> = []
        if geometry != nil { out.insert(.geometry) }
        if light != nil { out.insert(.light) }
        if curve != nil { out.insert(.curve) }
        if color != nil { out.insert(.color) }
        if detail != nil { out.insert(.detail) }
        if effects != nil { out.insert(.effects) }
        if maskCount > 0 { out.insert(.masks) }
        return out
    }

    // MARK: sections (选组)

    /// What this payload carries, in `EditSnapshotSection` terms — `light` appears twice
    /// (`.whiteBalance` / `.light`) when the payload has both a Kelvin pin and a tone slider.
    public var sections: Set<EditSnapshotSection> {
        var out: Set<EditSnapshotSection> = []
        if geometry != nil { out.insert(.geometry) }
        if let l = light {
            if l.temperature != nil || l.tint != nil { out.insert(.whiteBalance) }
            if l.exposure != nil || l.contrast != nil || l.highlights != nil || l.shadows != nil
                || l.whites != nil || l.blacks != nil || l.highlightRecovery != nil {
                out.insert(.light)
            }
        }
        if curve != nil { out.insert(.curve) }
        if color != nil { out.insert(.color) }
        if detail != nil { out.insert(.detail) }
        if effects != nil { out.insert(.effects) }
        if maskCount > 0 { out.insert(.masks) }
        return out
    }

    /// Would pasting this payload have to develop again? True only when it carries a white balance:
    /// the Kelvin/tint pair is assigned inside `CIRAWFilter` (`DecodeInputs.whiteBalance`), so the
    /// buffer itself is a different picture. Every other field is a GPU-stage change — and `detail`
    /// is stored, not rendered, so a paste of it moves no pixels and no buffer.
    public var requiresDecode: Bool { sections.contains(where: \.requiresDecode) }

    /// The payload narrowed to `sections` — the whole point of 「选组」.
    ///
    /// Field-level, not group-level, for the one place it has to be: `light` and `.whiteBalance`
    /// live in the *same* `LightPatch`, so narrowing to `.light` keeps the tone leaves and drops
    /// `temperature`/`tint`. Dropping a section drops its leaves only: the destination's values for
    /// it are never read, never written, so they cannot be reset.
    public func filtered(to sections: Set<EditSnapshotSection>) -> EditSnapshot {
        var out = EditSnapshot()
        if sections.contains(.geometry) { out.geometry = geometry }
        if let l = light {
            var p = LightPatch()
            if sections.contains(.whiteBalance) {
                p.temperature = l.temperature
                p.tint = l.tint
            }
            if sections.contains(.light) {
                p.exposure = l.exposure
                p.contrast = l.contrast
                p.highlights = l.highlights
                p.shadows = l.shadows
                p.whites = l.whites
                p.blacks = l.blacks
                p.highlightRecovery = l.highlightRecovery
            }
            out.light = p.isEmpty ? nil : p
        }
        if sections.contains(.curve) { out.curve = curve }
        if sections.contains(.color) { out.color = color }
        if sections.contains(.detail) { out.detail = detail }
        if sections.contains(.effects) { out.effects = effects }
        if sections.contains(.masks) { out.masks = masks }
        return out
    }

    /// The payload narrowed by a checklist.
    public func filtered(to selection: CopySettingsSelection) -> EditSnapshot {
        filtered(to: selection.sections)
    }

    /// Groups whose values are semantically identical between the payload and `target` (i.e. a
    /// paste of those groups would change nothing). For a "nothing to paste" message.
    public func unchangedGroups(in target: EditModel) -> Set<RenderGroup> {
        let dirty = EditHistory.dirtyGroups(from: target, to: applied(to: target))
        return groups.subtracting(dirty)
    }

    // MARK: pasting

    /// `target` with the payload's fields written over it. Fields the payload does not carry keep
    /// the destination's value; `showMaskID`, `schemaVersion` and `processVersion` are always the
    /// destination's.
    ///
    /// **Masks are appended, not written over.** `masks` names a *list*, and the destination's list
    /// is the user's own work — a paste that dropped it would be the one destructive merge in this
    /// type. So the payload's masks are added after the destination's (`target.masks + copies`),
    /// each re-identified against the ids already in use and re-anchored by `MaskFrameTransfer`:
    /// `destinationAspect` is `W/H` of *this* photo's source frame, and `nil` (unknown) copies the
    /// normalised fractions verbatim. `Mask.maxCount` is respected — a paste onto a document with
    /// eleven masks takes one, and the rest are dropped rather than producing an unrenderable
    /// document (§7's cap is what the atlas layer budget is built on).
    public func applied(to target: EditModel, destinationAspect: Double? = nil) -> EditModel {
        var out = target

        if let p = geometry {
            // 2026-10-28 (P0-10): a quarter turn is a **transform**, not a free-standing number. If
            // the payload carries the turn but none of the four crop edges, the rect it leaves alone
            // is measured in a *different* frame — so it is turned by the same delta first, exactly
            // the way `GeometryGroup.turn` does it. A payload that carries edges speaks absolute
            // coordinates in the returned frame and wins (that is what 「复制设置」 stores when the
            // source itself was cropped).
            let carriesCrop = p.cropX != nil || p.cropY != nil
                || p.cropWidth != nil || p.cropHeight != nil
            if let turns = p.quarterTurns, !carriesCrop {
                let delta = GeometryGroup.normalizedQuarterTurns(
                    turns - out.geometry.quarterTurns)
                out.geometry = out.geometry.turned(by: delta)
            }
            if let v = p.cropX { out.geometry.crop.x = v }
            if let v = p.cropY { out.geometry.crop.y = v }
            if let v = p.cropWidth { out.geometry.crop.width = v }
            if let v = p.cropHeight { out.geometry.crop.height = v }
            if let v = p.rotationDegrees { out.geometry.rotationDegrees = v }
            if let v = p.flipHorizontal { out.geometry.flipHorizontal = v }
            if let v = p.flipVertical { out.geometry.flipVertical = v }
            if let v = p.aspectLock { out.geometry.aspectLock = v }
            if let v = p.quarterTurns { out.geometry.quarterTurns = v }
        }

        if let p = light {
            if let v = p.exposure { out.light.exposure = v }
            if let v = p.contrast { out.light.contrast = v }
            if let v = p.highlights { out.light.highlights = v }
            if let v = p.shadows { out.light.shadows = v }
            if let v = p.whites { out.light.whites = v }
            if let v = p.blacks { out.light.blacks = v }
            if let v = p.temperature { out.light.temperature = v }
            if let v = p.tint { out.light.tint = v }
            if let v = p.highlightRecovery { out.light.highlightRecovery = v }
        }

        if let p = curve {
            if let v = p.rgb { out.curve.white = v }
            if let v = p.red { out.curve.red = v }
            if let v = p.green { out.curve.green = v }
            if let v = p.blue { out.curve.blue = v }
        }

        if let p = color {
            if let v = p.vibrance { out.color.vibrance = v }
            if let v = p.saturation { out.color.saturation = v }
            if let v = p.blackAndWhite { out.color.blackAndWhite = v }
            // Bands are indexed into the eight-band array; an out-of-range index cannot exist in a
            // payload this build wrote, and is ignored if a hand-written one carries it.
            for patch in p.bands ?? [] {
                guard out.color.bands.indices.contains(patch.index) else { continue }
                var band = out.color.bands[patch.index]
                if let v = patch.hue { band.hue = v }
                if let v = patch.saturation { band.saturation = v }
                if let v = patch.luminance { band.luminance = v }
                if let v = patch.mix { band.mix = v }
                out.color.bands[patch.index] = band
            }
        }

        if let p = detail {
            if let v = p.sharpening { out.detail.sharpening = v }
            if let v = p.sharpeningRadius { out.detail.sharpeningRadius = v }
            if let v = p.noiseLuminance { out.detail.noiseLuminance = v }
            if let v = p.noiseColor { out.detail.noiseColor = v }
            if let v = p.lensCorrections { out.detail.lensCorrections = v }
        }

        if let p = effects {
            if let v = p.vignetteAmount { out.effects.vignetteAmount = v }
            if let v = p.vignetteMidpoint { out.effects.vignetteMidpoint = v }
            if let v = p.vignetteFeather { out.effects.vignetteFeather = v }
            if let v = p.vignetteRoundness { out.effects.vignetteRoundness = v }
            if let v = p.grain { out.effects.grain = v }
            if let v = p.texture { out.effects.texture = v }
            if let v = p.clarity { out.effects.clarity = v }
            if let v = p.dehaze { out.effects.dehaze = v }
        }

        if let p = masks, !p.masks.isEmpty {
            var taken = Set(out.masks.map(\.id))
            var added: [Mask] = []
            for source in p.masks {
                guard out.masks.count + added.count < Mask.maxCount else { break }
                let copy = MaskFrameTransfer.copied(source,
                                                    from: p.frameAspect,
                                                    to: destinationAspect,
                                                    takenIDs: taken)
                taken.insert(copy.id)
                added.append(copy)
            }
            out.masks.append(contentsOf: added)
        }

        return out
    }

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.schemaVersion = c.val("schemaVersion", EditSnapshot.currentSchemaVersion)
        self.geometry = c.val("geometry", GeometryPatch?.none)
        self.light = c.val("light", LightPatch?.none)
        self.curve = c.val("curve", CurvePatch?.none)
        self.color = c.val("color", ColorPatch?.none)
        self.detail = c.val("detail", DetailPatch?.none)
        self.effects = c.val("effects", EffectsPatch?.none)
        // P1-5: absent in every v1 payload, and absent means "the destination keeps its own masks".
        self.masks = c.val("masks", MasksPatch?.none)
    }

    // MARK: tolerant comparison

    /// Same tolerance as `EditHistory.dirtyTolerance`: a value that was through JSON is the same
    /// value, so a re-encoded document is not reported as edited.
    static func differs(_ a: Double, _ b: Double) -> Bool {
        if a == b { return false }
        if a.isNaN && b.isNaN { return false }
        return abs(a - b) > EditHistory.dirtyTolerance
    }

    static func same(_ a: [CurvePoint], _ b: [CurvePoint]) -> Bool {
        guard a.count == b.count else { return false }
        // 069: integer cells — exact, for the same reason `HistoryDirty.areEqual` is.
        for (x, y) in zip(a, b) where x != y { return false }
        return true
    }
}
