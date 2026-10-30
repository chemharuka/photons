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
// **Known gaps, recorded rather than implied (081, 2026-10-28):**
//  · 色彩分级 (`EditModel.colorGrading`, S3.8) **is** carried now (`ColorGradingPatch`, this file) and
//    is its own section. Until 081 it was not copied at all; a paste of 全部 left the destination's
//    grade alone. That gap is closed, and a preset carries the same nine numbers through `Preset`.
//  · `decoderVersion` is still not a section: it is a per-file decoder fact, not a develop setting.

/// Which fields belong to which group. Used for reporting what a clipboard payload carries.
public enum EditSnapshotGroup: String, CaseIterable, Sendable, Hashable {
    case geometry, light, curve, color, detail, effects
}

// MARK: - sections (派单 081: 卡片粒度)

/// The **cards** a paste can be narrowed to — one row per card of the inspector.
///
/// 081 (2026-10-28) replaced the eight Lightroom-shaped groups with the twelve cards the panel
/// actually draws, because the user's words were 「按卡片选择复制哪些调整内容」. 白平衡 and 黑电平 are
/// cards of their own in this app (派单 009 A / 071), and 黑白 / HSL / 色彩分级 are three separate
/// colour cards (S3.4 / S3.6 / S3.8). A checklist offering one 「颜色」 row for four cards the user
/// can see separately was answering a question nobody asked.
///
/// The raw values of the eight pre-081 sections are **unchanged** (`geometry`, `whiteBalance`,
/// `light`, `curve`, `color`, `detail`, `effects`, `masks`): they are the stored spelling of
/// `settings.copySelection.v1` and of every `EditSnapshot` already on disk, so renaming one would be
/// a data migration for a label change. The four new cases are new names.
///
/// Sections stay **field-level**, never group-level, and that is the part a reader must not miss:
/// `whiteBalance`, `blackLevel` and `light` live in the *same* `LightPatch`, and `color`, `hsl` and
/// `blackAndWhite` in the *same* `ColorPatch`. Narrowing to a section keeps its own leaves and drops
/// the rest (`filtered`), which is why 「只勾黑电平」 cannot move 曝光 even though both are one group
/// of the document.
public enum EditSnapshotSection: String, CaseIterable, Sendable, Hashable, Codable {
    /// 裁切/拉直/翻转/比例/旋转 — the crop rect's four edges are one section (a crop is one gesture).
    case geometry
    /// 色温/色调 — the only **decode-class** section a snapshot can carry.
    case whiteBalance
    /// 黑电平 — `light.blackOffset`, the additive linear black trim (派单 071). Its own card, so its
    /// own row: 「只勾黑电平」 must paste the offset and not one tone slider.
    case blackLevel
    /// 曝光/对比/高光/阴影/白/黑/高光恢复 — the Light card minus white balance and black level.
    case light
    case curve
    /// Color card — 自然饱和度 + 饱和度.
    case color
    /// 黑白 — the switch plus the eight 黑白混合 numbers (S3.4). One card, one row.
    case blackAndWhite
    /// HSL — 色相/饱和度/亮度 of the eight bands (S3.6).
    case hsl
    /// 色彩分级 — the nine wheel numbers (S3.8).
    case colorGrading
    case detail
    /// 校正 — 色差 R / 色差 B (`optics.caRed` / `optics.caBlue`, 096/116). Its own card in the panel,
    /// so its own row here: 「只勾校正」 must carry the two CA ratios and no detail or effect leaf.
    /// Between 细节 and 效果, exactly where the inspector draws it.
    case correction
    case effects
    /// 蒙版 — the mask list, re-identified and re-anchored on paste (P1-5).
    case masks

    /// The checklist order — `InspectorView.Section.allCases`' render order, not a second list.
    /// 白平衡 → 黑电平 → Light → Color → 黑白 → HSL → 色彩分级 → 曲线 → 细节 → 校正 → 效果 → 裁切 → 蒙版.
    /// (曲线 above 细节 since 2026-10-28 — the user's own panel order; 校正 between 细节 and 效果
    /// since 096, and carried by copy/paste since 156.)
    ///
    /// A test (`CopySheetCardTests`) compares it against `InspectorView.cardTitles(in: .adjust)` +
    /// the two cards that live in other workspaces, so a card that moves in the panel moves here or
    /// the test goes red.
    public static let panelOrder: [EditSnapshotSection] = [
        .whiteBalance, .blackLevel, .light, .color, .blackAndWhite, .hsl, .colorGrading,
        .curve, .detail, .correction, .effects, .geometry, .masks,
    ]

    /// Every section a paste can write — all of them, masks included since P1-5.
    public static var copyable: [EditSnapshotSection] { panelOrder.filter(\.isCopyable) }

    public var isCopyable: Bool { true }

    /// Does a paste of this section have to **develop again** (a new buffer), or only re-render?
    ///
    /// Since 143 nothing here requires a development: the white balance is an S1 gain computed from
    /// the decoded buffer, and the decoder is always at as-shot. The property stays (the copy sheet
    /// asks it) because a future decode-side section would need exactly one place to say so.
    public var requiresDecode: Bool { false }

    /// The card's title — **the inspector card's own string**, so the sheet's rows and the panel's
    /// headers cannot drift apart (`CopySheetCardTests` holds them to `InspectorView`'s titles).
    public var title: String {
        switch self {
        case .geometry: return "裁切"
        case .whiteBalance: return "白平衡"
        case .blackLevel: return "黑电平"
        case .light: return "Light"
        case .curve: return "曲线"
        case .color: return "Color"
        case .blackAndWhite: return "黑白"
        case .hsl: return "HSL"
        case .colorGrading: return "色彩分级"
        case .detail: return "细节"
        case .correction: return "校正"
        case .effects: return "效果"
        case .masks: return "蒙版"
        }
    }

    /// The card's parameters, typed and enumerable — **present but not drawn** by default
    /// (`CopySettingsSheet.showsChildren == false`). 081 §2: 「子项存在但不展示」, so the structure is
    /// there for the day the user asks for it, and a test opens the switch to prove it draws and
    /// filters.
    public var children: [EditSnapshotChild] {
        EditSnapshotChild.allCases.filter { $0.section == self }
    }

    /// The tooltip a row may carry. 蒙版 gets a sentence that says what a mask copy actually does,
    /// because "carried across photos" alone would hide both of its non-obvious properties (new ids,
    /// short-edge anchoring).
    public var help: String? {
        self == .masks
            ? "蒙版按目标照片的短边重新锚定，粘贴时生成新的蒙版 id（目标照片自己的蒙版保留）"
            : nil
    }
}

/// One adjustable **parameter** of a card — the row `CopySettingsSheet.showsChildren` would draw
/// under it, and the leaf `EditSnapshot.filtered(to:)` narrows to.
///
/// Typed rather than a `[String]` on purpose: 「以后要」 must not mean 「rewrite the sheet」. A child
/// names (a) its card, (b) the label the row would carry, and (c) — through `filtered`'s table — the
/// leaves of the patch it governs, so checking 曝光 alone really does keep 对比 out of the payload.
///
/// `rawValue`s are wire-stable: they are what the sheet's tags and a future persisted child set
/// would be spelled with.
public enum EditSnapshotChild: String, CaseIterable, Sendable, Hashable, Codable {
    case temperature, tint
    case blackOffset
    case exposure, contrast, highlights, midtones, shadows, whites, blacks, highlightRecovery
    case vibrance, saturation
    case blackAndWhiteSwitch, blackAndWhiteMix
    case hslHue, hslSaturation, hslLuminance
    case gradeShadows, gradeMidtones, gradeHighlights
    case sharpening, sharpeningRadius, noiseLuminance, noiseColor, lensCorrections
    case caRed, caBlue
    case curveWhite, curveRed, curveGreen, curveBlue
    case vignette, grain, texture, clarity, dehaze
    case crop, straighten, flips, aspectLock, quarterTurns

    /// The card this parameter belongs to. Declaration order of `allCases` is the panel order of
    /// `EditSnapshotSection.panelOrder`, so `section.children` needs no second ordering table.
    public var section: EditSnapshotSection {
        switch self {
        case .temperature, .tint: return .whiteBalance
        case .blackOffset: return .blackLevel
        case .exposure, .contrast, .highlights, .midtones, .shadows, .whites, .blacks, .highlightRecovery:
            return .light
        case .vibrance, .saturation: return .color
        case .blackAndWhiteSwitch, .blackAndWhiteMix: return .blackAndWhite
        case .hslHue, .hslSaturation, .hslLuminance: return .hsl
        case .gradeShadows, .gradeMidtones, .gradeHighlights: return .colorGrading
        case .sharpening, .sharpeningRadius, .noiseLuminance, .noiseColor, .lensCorrections:
            return .detail
        case .caRed, .caBlue: return .correction
        case .curveWhite, .curveRed, .curveGreen, .curveBlue: return .curve
        case .vignette, .grain, .texture, .clarity, .dehaze: return .effects
        case .crop, .straighten, .flips, .aspectLock, .quarterTurns: return .geometry
        }
    }

    /// The row label — the inspector's own row name where the panel has one.
    public var title: String {
        switch self {
        case .temperature: return "色温"
        case .tint: return "色调"
        case .blackOffset: return "黑电平"
        case .exposure: return "曝光"
        case .contrast: return "对比"
        case .highlights: return "高光"
        case .midtones: return "中间调"
        case .shadows: return "阴影"
        case .whites: return "白"
        case .blacks: return "黑"
        case .highlightRecovery: return "高光恢复"
        case .vibrance: return "自然饱和度"
        case .saturation: return "饱和度"
        case .blackAndWhiteSwitch: return "开关"
        case .blackAndWhiteMix: return "混合"
        case .hslHue: return "色相"
        case .hslSaturation: return "饱和度"
        case .hslLuminance: return "亮度"
        case .gradeShadows: return "阴影"
        case .gradeMidtones: return "中间调"
        case .gradeHighlights: return "高光"
        case .sharpening: return "锐化"
        case .sharpeningRadius: return "锐化半径"
        case .noiseLuminance: return "降噪"
        case .noiseColor: return "色彩降噪"
        case .lensCorrections: return "镜头校正"
        case .caRed: return "色差 R"
        case .caBlue: return "色差 B"
        case .curveWhite: return "白色"
        case .curveRed: return "红"
        case .curveGreen: return "绿"
        case .curveBlue: return "蓝"
        case .vignette: return "暗角"
        case .grain: return "颗粒"
        case .texture: return "纹理"
        case .clarity: return "清晰度"
        case .dehaze: return "去雾"
        case .crop: return "裁切"
        case .straighten: return "拉直"
        case .flips: return "翻转"
        case .aspectLock: return "比例"
        case .quarterTurns: return "旋转"
        }
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
            case .basic: return "基本：白平衡 + 黑电平 + 曝光 + 曲线"
            case .color: return "颜色：颜色 + 黑白 + HSL + 色彩分级 + 细节 + 效果"
            case .geometry: return "几何：裁切"
            case .whiteBalance: return "仅白平衡"
            case .none: return "全不选"
            }
        }

        public var sections: Set<EditSnapshotSection> {
            switch self {
            case .all: return Set(EditSnapshotSection.copyable)
            // 081: 黑电平 joined 基本 — it is a black trim like 黑, and a combination that says
            // 「基本」 while leaving one of the panel's two first cards out would be a surprise.
            case .basic: return [.whiteBalance, .blackLevel, .light, .curve]
            // 081: the three colour cards are colour. Leaving them out of 「颜色」 meant the popup had
            // no combination that carried 黑白 at all.
            case .color: return [.color, .blackAndWhite, .hsl, .colorGrading, .detail, .effects]
            case .geometry: return [.geometry]
            case .whiteBalance: return [.whiteBalance]
            case .none: return []
            }
        }
    }

    /// Always a subset of `EditSnapshotSection.copyable`: a section that is ever made unavailable
    /// cannot leak into a paste through a hand-made set.
    public private(set) var sections: Set<EditSnapshotSection>

    /// The **parameters** the paste is narrowed to, when the sheet's `showsChildren` switch is on.
    ///
    /// Default is every child of every section, which is what makes 「checked card = whole card」 the
    /// behaviour of a build that never draws the child rows. The set is the authority for
    /// `EditSnapshot.filtered(to: selection)`: a child outside it is dropped from the payload even
    /// when its card is checked. `set(_ child:)` keeps the two halves coherent — checking a child
    /// checks its card in, and unchecking a card unchecks all of its children.
    public private(set) var children: Set<EditSnapshotChild>

    public init(sections: Set<EditSnapshotSection> = Set(EditSnapshotSection.copyable),
                children: Set<EditSnapshotChild> = Set(EditSnapshotChild.allCases)) {
        let kept = sections.filter(\.isCopyable)
        self.sections = kept
        // Coherence on the way in: a child whose card was not checked is not a selection of
        // anything. (A caller may still hand in a superset; the paste asks `sections` first.)
        self.children = children.filter { kept.contains($0.section) }
    }

    public init(_ preset: Preset) {
        self.init(sections: preset.sections,
                  children: Set(preset.sections.flatMap(\.children)))
    }

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

    /// True when every parameter of every checked card is on — i.e. the child rows (if drawn) all
    /// agree with the card rows, so a paste is the whole card.
    public var coversWholeCards: Bool {
        Set(sections.flatMap(\.children)).isSubset(of: children)
    }

    public func contains(_ section: EditSnapshotSection) -> Bool { sections.contains(section) }
    public func contains(_ child: EditSnapshotChild) -> Bool {
        sections.contains(child.section) && children.contains(child)
    }

    public mutating func set(_ section: EditSnapshotSection, _ on: Bool) {
        guard section.isCopyable else { return }
        if on {
            sections.insert(section)
            children.formUnion(section.children)     // a freshly checked card is the whole card
        } else {
            sections.remove(section)
            children.subtract(section.children)
        }
    }

    public mutating func toggle(_ section: EditSnapshotSection) { set(section, !sections.contains(section)) }

    /// Check one **parameter**. Checking it checks its card in; unchecking it leaves the card checked
    /// (its other parameters are still on) unless it was the last one, in which case the card would
    /// claim to copy something it does not carry — so an empty card is unchecked.
    public mutating func set(_ child: EditSnapshotChild, _ on: Bool) {
        if on {
            sections.insert(child.section)
            children.insert(child)
        } else {
            children.remove(child)
            if !child.section.children.contains(where: { children.contains($0) }) {
                sections.remove(child.section)
            }
        }
    }

    public mutating func toggle(_ child: EditSnapshotChild) { set(child, !contains(child)) }

    public mutating func select(_ preset: Preset) { self = CopySettingsSelection(preset) }

    public mutating func selectAll() {
        sections = Set(EditSnapshotSection.copyable)
        children = Set(EditSnapshotChild.allCases)
    }

    public mutating func selectNone() {
        sections = []
        children = []
    }

    /// One line for the dialog's status label.
    public var summary: String {
        if sections.isEmpty { return "未选任何组：粘贴什么也不会发生" }
        let names = EditSnapshotSection.panelOrder.filter { sections.contains($0) }.map(\.title)
        return "将复制：\(names.joined(separator: " · "))"
    }
}

// MARK: - 081 §3: the selection lives in the library

extension CopySettingsSelection {

    /// The `settings` key the checklist is stored under. Versioned because a future change to what a
    /// name means must be able to start over instead of reinterpreting old rows.
    ///
    /// It is a **row in the library**, not a `UserDefaults` key: the same machine holds several
    /// libraries, and 「A 库选 3 项、B 库选 7 项」 has to survive reopening either one (081 §3).
    public static let storageKey = "settings.copySelection.v1"

    /// `["whiteBalance","light","curve"]` — a JSON array of raw values **in render order**, so the
    /// stored bytes are stable and a human with `sqlite3` can read them.
    public var storageValue: String {
        let names = EditSnapshotSection.panelOrder.filter { sections.contains($0) }.map(\.rawValue)
        guard let data = try? JSONEncoder().encode(names),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// Read a stored value back. **Every failure is 全部**: absent row, junk, an array of names this
    /// build does not know. 081 §3 asks for that explicitly — a checklist that came back empty would
    /// make the next ⌘C carry nothing, and the user would have to discover why.
    ///
    /// An unknown name is dropped rather than fatal, and a value with *no* known name left falls back
    /// to 全部 for the same reason.
    public init(storageValue: String?) {
        guard let storageValue,
              let data = storageValue.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            self = .all
            return
        }
        let known = names.compactMap(EditSnapshotSection.init(rawValue:))
        guard !known.isEmpty else {
            self = .all
            return
        }
        self.init(sections: Set(known))
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
    /// 085 — the middle window of S2's three-zone lift, between 高光 and 阴影. Absent means "the
    /// destination keeps its own middle tone", exactly like every other tone leaf.
    public var midtones: Double?
    public var shadows: Double?
    public var whites: Double?
    public var blacks: Double?
    public var temperature: Double?
    public var tint: Double?
    public var highlightRecovery: Double?
    /// 081: 黑电平 — `LightGroup.blackOffset`, the additive linear trim (派单 071). It rides in this
    /// patch because it *is* a field of `LightGroup`, but it is its own **section** (`blackLevel`),
    /// so narrowing to 黑电平 keeps this leaf and drops the seven tone ones (and vice versa). Absent in
    /// every pre-081 payload, which is exactly what "the destination keeps its own black level" means.
    public var blackOffset: Double?

    public init() {}

    public var fieldCount: Int {
        [exposure != nil, contrast != nil, highlights != nil, midtones != nil, shadows != nil,
         whites != nil, blacks != nil, temperature != nil, tint != nil, highlightRecovery != nil,
         blackOffset != nil]
            .filter { $0 }.count
    }

    public var isEmpty: Bool { fieldCount == 0 }

    public static let fullFieldCount = 11

    /// The tone leaves — everything the `light` section owns (black offset excluded).
    public var hasToneLeaves: Bool {
        exposure != nil || contrast != nil || highlights != nil || midtones != nil
            || shadows != nil || whites != nil || blacks != nil || highlightRecovery != nil
    }

    /// The balance pair — everything the `whiteBalance` section owns.
    public var hasWhiteBalance: Bool { temperature != nil || tint != nil }
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
    /// 101 — 全局: the ninth selector's triplet, sparse like a band patch. Its `index` is
    /// `ColorGroup.bandCount` (the ninth cell) and is not a leaf; a paste ignores it and writes
    /// `color.global` directly.
    public var global: HSLBandPatch?
    /// 2026-10-28 (P0-4): the 黑白 switch. Copied as a field of its own so "paste onto a colour photo"
    /// can carry the mode — a mix list without the switch is a look nobody asked for.
    public var blackAndWhite: Bool?

    public init() {}

    public var fieldCount: Int {
        [vibrance != nil, saturation != nil, blackAndWhite != nil].filter { $0 }.count
            + (bands ?? []).reduce(0) { $0 + $1.fieldCount }
            + (global?.fieldCount ?? 0)
    }

    public var isEmpty: Bool { fieldCount == 0 }

    public static let fullFieldCount = 3 + ColorGroup.bandCount * 4

    // MARK: 081 — the three cards this one patch serves

    /// Any band carries a 色相 / 饱和度 / 亮度 number — what the `hsl` card owns. Since 101 the
    /// global triplet belongs to the same card, so a global-only copy is an HSL copy too.
    public var hasHSL: Bool {
        global != nil
            || (bands ?? []).contains { $0.hue != nil || $0.saturation != nil || $0.luminance != nil }
    }

    /// Any band carries a 黑白混合 number — what the `blackAndWhite` card owns besides its switch.
    public var hasBlackAndWhiteMix: Bool { (bands ?? []).contains { $0.mix != nil } }
}

/// 校正 — the two lateral-CA ratios (`OpticsGroup.caRed` / `caBlue`, 029 / 096).
///
/// Two leaves, not the whole `OpticsGroup`: the group has exactly these two fields today, and a
/// snapshot is a leaf table. The conversion the panel uses (slider −100…+100 ↔ α ±0.005) is a
/// **view** fact (`OpticsGroup.alpha(fromSlider:)`); the clipboard stores α, like the document.
public struct OpticsPatch: Sendable, Equatable, Codable {
    public var caRed: Double?
    public var caBlue: Double?

    public init() {}

    public var fieldCount: Int { [caRed != nil, caBlue != nil].filter { $0 }.count }

    public var isEmpty: Bool { fieldCount == 0 }

    public static let fullFieldCount = 2
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
    public var grain: Double?
    /// 2026-10-28 (P0-6): S3.8's three numbers. Sparse like every other leaf — a copy of a
    /// vignette-only look carries no `texture`, so pasting it leaves the target's 纹理 alone.
    public var texture: Double?
    public var clarity: Double?
    public var dehaze: Double?

    public init() {}

    public var fieldCount: Int {
        [vignetteAmount != nil, vignetteMidpoint != nil, vignetteFeather != nil,
         grain != nil,
         texture != nil, clarity != nil, dehaze != nil].filter { $0 }.count
    }

    public var isEmpty: Bool { fieldCount == 0 }

    public static let fullFieldCount = 7
}

/// 色彩分级 — the nine wheel numbers (S3.8), one optional `GradeWheel` per region.
///
/// A wheel, not three loose doubles: the document stores the three numbers as a unit
/// (`ColorGradingGroup`), the card draws them as one row of three sliders, and the sheet's child rows
/// are per region (阴影 / 中间调 / 高光), so "shadows only" is one optional and not a bit mask. A
/// region that is identity is **absent**, which is why `fieldCount` counts **three leaves per present
/// region** rather than one: the arithmetic `fieldCount` exists for is "one slider = one field", and
/// moving 阴影色相 alone is one.
public struct ColorGradingPatch: Sendable, Equatable, Codable {
    public var shadows: GradeWheel?
    public var midtones: GradeWheel?
    public var highlights: GradeWheel?

    public init() {}

    public var fieldCount: Int {
        [shadows != nil, midtones != nil, highlights != nil].filter { $0 }.count * 3
    }

    public var isEmpty: Bool { fieldCount == 0 }

    /// Nine leaves — three regions of three numbers.
    public static let fullFieldCount = 9
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
    /// **2 → 3 (081, 2026-10-28): the card granularity.** Not a new wire shape — every v2 key keeps
    /// its name and meaning (`light` still holds the tone leaves *and* the Kelvin pin, `color` still
    /// holds the bands), which is why a v2 payload decodes into this struct unchanged and pastes
    /// byte-for-byte the same document. What the number names is the *reading*: `sections` now reports
    /// the twelve cards (黑电平 out of `light`, 黑白 / HSL out of `color`), and `colorGrading` /
    /// `light.blackOffset` are two new optional keys that an older reader simply does not know. A build
    /// that dropped them would report a paste as complete when it was not, which is the same reason
    /// the masks key bumped 1 → 2.
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var geometry: GeometryPatch?
    public var light: LightPatch?
    public var curve: CurvePatch?
    public var color: ColorPatch?
    /// 081: 色彩分级 — absent in every payload written before the card had its own patch.
    public var colorGrading: ColorGradingPatch?
    public var detail: DetailPatch?
    /// 156: 校正 — the two CA ratios. Absent in every payload written before the card was carried;
    /// absent means "the destination keeps its own CA", which is what an old copy did.
    public var optics: OpticsPatch?
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
        if differs(edit.light.midtones, 0) { light.midtones = edit.light.midtones }
        if differs(edit.light.shadows, 0) { light.shadows = edit.light.shadows }
        if differs(edit.light.whites, 0) { light.whites = edit.light.whites }
        if differs(edit.light.blacks, 0) { light.blacks = edit.light.blacks }
        // 派单 006: white balance has no neutral *number* to compare against any more — either the
        // document follows the file (`nil`, nothing to copy) or it pins a value (always copied, even
        // 6500 K, because pinning 6500 K on a 4803 K shot is a real setting).
        if let t = edit.light.temperature { light.temperature = t }
        if let i = edit.light.tint { light.tint = i }
        if differs(edit.light.highlightRecovery, 0) { light.highlightRecovery = edit.light.highlightRecovery }
        // 081: 黑电平 is a leaf of `LightGroup` but a card of its own; 0 is the neutral trim, so only
        // a real offset travels.
        if differs(edit.light.blackOffset, 0) { light.blackOffset = edit.light.blackOffset }
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
        // 101 — the ninth selector. Sparse like a band: only the non-zero axes travel, so pasting a
        // global 色相 leaves the destination's global 明度 alone (「只带非默认字段」).
        if edit.color.hasGlobal {
            var patch = HSLBandPatch(index: ColorGroup.bandCount)
            if differs(edit.color.global.hue, 0) { patch.hue = edit.color.global.hue }
            if differs(edit.color.global.saturation, 0) {
                patch.saturation = edit.color.global.saturation
            }
            if differs(edit.color.global.luminance, 0) {
                patch.luminance = edit.color.global.luminance
            }
            if !patch.isEmpty { color.global = patch }
        }
        s.color = color.isEmpty ? nil : color

        // 081: 色彩分级 — nine numbers, one wheel per luminance region. A region whose three numbers
        // are all 0 is absent (the card's own "nothing here"), so a shadows-only grade carries one
        // wheel and pasting it leaves the destination's midtones and highlights alone.
        var grading = ColorGradingPatch()
        if !edit.colorGrading.shadows.isIdentity { grading.shadows = edit.colorGrading.shadows }
        if !edit.colorGrading.midtones.isIdentity { grading.midtones = edit.colorGrading.midtones }
        if !edit.colorGrading.highlights.isIdentity { grading.highlights = edit.colorGrading.highlights }
        s.colorGrading = grading.isEmpty ? nil : grading

        var detail = DetailPatch()
        if differs(edit.detail.sharpening, 0) { detail.sharpening = edit.detail.sharpening }
        if differs(edit.detail.sharpeningRadius, 1.0) { detail.sharpeningRadius = edit.detail.sharpeningRadius }
        if differs(edit.detail.noiseLuminance, 0) { detail.noiseLuminance = edit.detail.noiseLuminance }
        if differs(edit.detail.noiseColor, 0) { detail.noiseColor = edit.detail.noiseColor }
        if edit.detail.lensCorrections { detail.lensCorrections = true }
        s.detail = detail.isEmpty ? nil : detail

        // 156: 校正 — the two lateral-CA ratios. 0 is the neutral ratio, so only a real correction
        // travels (「只带非默认字段」); the document stores α, not the panel's −100…+100 position.
        var optics = OpticsPatch()
        if differs(edit.optics.caRed, 0) { optics.caRed = edit.optics.caRed }
        if differs(edit.optics.caBlue, 0) { optics.caBlue = edit.optics.caBlue }
        s.optics = optics.isEmpty ? nil : optics

        var effects = EffectsPatch()
        if differs(edit.effects.vignetteAmount, 0) { effects.vignetteAmount = edit.effects.vignetteAmount }
        if differs(edit.effects.vignetteMidpoint, 50) { effects.vignetteMidpoint = edit.effects.vignetteMidpoint }
        if differs(edit.effects.vignetteFeather, 50) { effects.vignetteFeather = edit.effects.vignetteFeather }
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
    /// from is `fullDocumentFieldCount` (80). Masks are counted separately (`maskCount`): a mask is a
    /// nested document, and folding it into this arithmetic would make "1 slider + 1 mask" read as
    /// 2 leaves of 80 — a fraction that means nothing.
    public var fieldCount: Int {
        (geometry?.fieldCount ?? 0) + (light?.fieldCount ?? 0) + (curve?.fieldCount ?? 0)
            + (color?.fieldCount ?? 0) + (colorGrading?.fieldCount ?? 0)
            + (detail?.fieldCount ?? 0) + (optics?.fieldCount ?? 0)
            + (effects?.fieldCount ?? 0)
    }

    /// How many masks the payload carries. 0 = a paste leaves the destination's list alone.
    public var maskCount: Int { masks?.masks.count ?? 0 }

    public var isEmpty: Bool { fieldCount == 0 && maskCount == 0 }

    /// Leaves a full `EditModel` carries — the denominator `fieldCount` is compared against.
    /// geometry 9 (4 crop edges + straighten + 2 flips + aspect lock + `quarterTurns`) + light 11
    /// (7 tone + 2 balance + 高光恢复 + 黑电平) + curve 4 + color 26 (2 + 8 bands × 3) + 色彩分级 9
    /// + detail 5 + 校正 2 (色差 R/B) + effects 7 (暗角 3 + 颗粒 1 + 纹理/清晰度/去雾 3).
    public static let fullDocumentFieldCount =
        GeometryPatch.fullFieldCount + LightPatch.fullFieldCount + CurvePatch.fullFieldCount
        + ColorPatch.fullFieldCount + ColorGradingPatch.fullFieldCount
        + DetailPatch.fullFieldCount + OpticsPatch.fullFieldCount
        + EffectsPatch.fullFieldCount

    /// Groups with at least one field present, for a "copied: Light, Color" line.
    public var groups: Set<RenderGroup> {
        var out: Set<RenderGroup> = []
        if geometry != nil { out.insert(.geometry) }
        // 校正 rides in `optics`, whose document group is `.geometry` (EditModel's dirty bit).
        if optics != nil { out.insert(.geometry) }
        if light != nil { out.insert(.light) }
        if curve != nil { out.insert(.curve) }
        if color != nil { out.insert(.color) }
        if colorGrading != nil { out.insert(.colorGrading) }
        if detail != nil { out.insert(.detail) }
        if effects != nil { out.insert(.effects) }
        if maskCount > 0 { out.insert(.masks) }
        return out
    }

    // MARK: sections (081: 卡片粒度)

    /// What this payload carries, in `EditSnapshotSection` terms — thirteen cards out of seven patches.
    ///
    /// Two patches are shared by three sections each, so this is the **field-level reading** and not a
    /// key list: `light` reports `.whiteBalance` / `.blackLevel` / `.light` separately, and `color`
    /// reports `.color` / `.blackAndWhite` / `.hsl` separately. That is also what makes a pre-081
    /// payload 「等价展开」: an old `{"light":{…},"color":{…}}` blob decodes into these same patches
    /// and the same twelve-card reading, with no migration step.
    public var sections: Set<EditSnapshotSection> {
        var out: Set<EditSnapshotSection> = []
        if geometry != nil { out.insert(.geometry) }
        if let l = light {
            if l.hasWhiteBalance { out.insert(.whiteBalance) }
            if l.blackOffset != nil { out.insert(.blackLevel) }
            if l.hasToneLeaves { out.insert(.light) }
        }
        if curve != nil { out.insert(.curve) }
        if let c = color {
            if c.vibrance != nil || c.saturation != nil { out.insert(.color) }
            if c.blackAndWhite != nil || c.hasBlackAndWhiteMix { out.insert(.blackAndWhite) }
            if c.hasHSL { out.insert(.hsl) }
        }
        if colorGrading != nil { out.insert(.colorGrading) }
        if detail != nil { out.insert(.detail) }
        if optics != nil { out.insert(.correction) }
        if effects != nil { out.insert(.effects) }
        if maskCount > 0 { out.insert(.masks) }
        return out
    }

    /// Would pasting this payload have to develop again? True only when it carries a white balance:
    /// the Kelvin/tint pair is assigned inside `CIRAWFilter` (`DecodeInputs.whiteBalance`), so the
    /// buffer itself is a different picture. Every other field is a GPU-stage change — and `detail`
    /// is stored, not rendered, so a paste of it moves no pixels and no buffer.
    public var requiresDecode: Bool { sections.contains(where: \.requiresDecode) }

    /// The payload narrowed to `sections` — one row per card, and the leaves of that card only.
    ///
    /// Field-level, not group-level, for the two places it has to be: `whiteBalance` / `blackLevel` /
    /// `light` live in the *same* `LightPatch`, and `color` / `blackAndWhite` / `hsl` in the *same*
    /// `ColorPatch`. Dropping a section drops its leaves only: the destination's values for it are
    /// never read, never written, so they cannot be reset.
    public func filtered(to sections: Set<EditSnapshotSection>) -> EditSnapshot {
        filtered(to: sections, children: Set(EditSnapshotChild.allCases))
    }

    /// The payload narrowed to the checked leaves of the checked cards.
    ///
    /// `children` is the whole answer, not a delta: a leaf is kept when its child is in the set, so
    /// checking 曝光 alone carries `exposure` and drops `contrast` even though both are `.light`.
    /// (`filtered(to: Set<Section>)` above is the same function with every child on.)
    public func filtered(to sections: Set<EditSnapshotSection>,
                         children: Set<EditSnapshotChild>) -> EditSnapshot {
        var out = EditSnapshot()
        func on(_ child: EditSnapshotChild) -> Bool { children.contains(child) }

        if sections.contains(.geometry), let g = geometry {
            var p = GeometryPatch()
            if on(.crop) {
                p.cropX = g.cropX
                p.cropY = g.cropY
                p.cropWidth = g.cropWidth
                p.cropHeight = g.cropHeight
            }
            if on(.straighten) { p.rotationDegrees = g.rotationDegrees }
            if on(.flips) {
                p.flipHorizontal = g.flipHorizontal
                p.flipVertical = g.flipVertical
            }
            if on(.aspectLock) { p.aspectLock = g.aspectLock }
            if on(.quarterTurns) { p.quarterTurns = g.quarterTurns }
            out.geometry = p.isEmpty ? nil : p
        }

        if let l = light {
            var p = LightPatch()
            if sections.contains(.whiteBalance) {
                if on(.temperature) { p.temperature = l.temperature }
                if on(.tint) { p.tint = l.tint }
            }
            if sections.contains(.blackLevel), on(.blackOffset) { p.blackOffset = l.blackOffset }
            if sections.contains(.light) {
                if on(.exposure) { p.exposure = l.exposure }
                if on(.contrast) { p.contrast = l.contrast }
                if on(.highlights) { p.highlights = l.highlights }
                if on(.midtones) { p.midtones = l.midtones }
                if on(.shadows) { p.shadows = l.shadows }
                if on(.whites) { p.whites = l.whites }
                if on(.blacks) { p.blacks = l.blacks }
                if on(.highlightRecovery) { p.highlightRecovery = l.highlightRecovery }
            }
            out.light = p.isEmpty ? nil : p
        }

        if sections.contains(.curve), let c = curve {
            var p = CurvePatch()
            if on(.curveWhite) { p.rgb = c.rgb }
            if on(.curveRed) { p.red = c.red }
            if on(.curveGreen) { p.green = c.green }
            if on(.curveBlue) { p.blue = c.blue }
            out.curve = p.isEmpty ? nil : p
        }

        if let c = color {
            var p = ColorPatch()
            if sections.contains(.color) {
                if on(.vibrance) { p.vibrance = c.vibrance }
                if on(.saturation) { p.saturation = c.saturation }
            }
            if sections.contains(.blackAndWhite), on(.blackAndWhiteSwitch) {
                p.blackAndWhite = c.blackAndWhite
            }
            // Bands are narrowed leaf by leaf: one band may carry an HSL number *and* a 黑白混合, and
            // those belong to two different cards. A band left with nothing is dropped rather than
            // stored empty.
            var bands: [HSLBandPatch] = []
            for band in c.bands ?? [] {
                var patch = HSLBandPatch(index: band.index)
                if sections.contains(.hsl) {
                    if on(.hslHue) { patch.hue = band.hue }
                    if on(.hslSaturation) { patch.saturation = band.saturation }
                    if on(.hslLuminance) { patch.luminance = band.luminance }
                }
                if sections.contains(.blackAndWhite), on(.blackAndWhiteMix) { patch.mix = band.mix }
                if !patch.isEmpty { bands.append(patch) }
            }
            if !bands.isEmpty { p.bands = bands }
            // 101: the global triplet follows the hsl card and its three children, exactly like a band.
            if sections.contains(.hsl), let g = c.global {
                var patch = HSLBandPatch(index: g.index)
                if on(.hslHue) { patch.hue = g.hue }
                if on(.hslSaturation) { patch.saturation = g.saturation }
                if on(.hslLuminance) { patch.luminance = g.luminance }
                if !patch.isEmpty { p.global = patch }
            }
            out.color = p.isEmpty ? nil : p
        }

        if sections.contains(.colorGrading), let g = colorGrading {
            var p = ColorGradingPatch()
            if on(.gradeShadows) { p.shadows = g.shadows }
            if on(.gradeMidtones) { p.midtones = g.midtones }
            if on(.gradeHighlights) { p.highlights = g.highlights }
            out.colorGrading = p.isEmpty ? nil : p
        }

        if sections.contains(.detail), let d = detail {
            var p = DetailPatch()
            if on(.sharpening) { p.sharpening = d.sharpening }
            if on(.sharpeningRadius) { p.sharpeningRadius = d.sharpeningRadius }
            if on(.noiseLuminance) { p.noiseLuminance = d.noiseLuminance }
            if on(.noiseColor) { p.noiseColor = d.noiseColor }
            if on(.lensCorrections) { p.lensCorrections = d.lensCorrections }
            out.detail = p.isEmpty ? nil : p
        }

        if sections.contains(.correction), let o = optics {
            var p = OpticsPatch()
            if on(.caRed) { p.caRed = o.caRed }
            if on(.caBlue) { p.caBlue = o.caBlue }
            out.optics = p.isEmpty ? nil : p
        }

        if sections.contains(.effects), let e = effects {
            var p = EffectsPatch()
            // 暗角 is one row on the card and three numbers in the patch: the child governs all
            // three, because a vignette with a copied amount and an uncopied feather is another look.
            if on(.vignette) {
                p.vignetteAmount = e.vignetteAmount
                p.vignetteMidpoint = e.vignetteMidpoint
                p.vignetteFeather = e.vignetteFeather
            }
            if on(.grain) { p.grain = e.grain }
            if on(.texture) { p.texture = e.texture }
            if on(.clarity) { p.clarity = e.clarity }
            if on(.dehaze) { p.dehaze = e.dehaze }
            out.effects = p.isEmpty ? nil : p
        }

        if sections.contains(.masks) { out.masks = masks }
        return out
    }

    /// The payload narrowed by a checklist **and** its child rows.
    public func filtered(to selection: CopySettingsSelection) -> EditSnapshot {
        filtered(to: selection.sections, children: selection.children)
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
            if let v = p.midtones { out.light.midtones = v }
            if let v = p.shadows { out.light.shadows = v }
            if let v = p.whites { out.light.whites = v }
            if let v = p.blacks { out.light.blacks = v }
            if let v = p.temperature { out.light.temperature = v }
            if let v = p.tint { out.light.tint = v }
            if let v = p.highlightRecovery { out.light.highlightRecovery = v }
            if let v = p.blackOffset { out.light.blackOffset = v }
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
            // 101: the ninth selector's triplet, written over the destination's global.
            if let patch = p.global {
                if let v = patch.hue { out.color.global.hue = v }
                if let v = patch.saturation { out.color.global.saturation = v }
                if let v = patch.luminance { out.color.global.luminance = v }
            }
        }

        if let p = colorGrading {
            if let v = p.shadows { out.colorGrading.shadows = v }
            if let v = p.midtones { out.colorGrading.midtones = v }
            if let v = p.highlights { out.colorGrading.highlights = v }
        }

        if let p = detail {
            if let v = p.sharpening { out.detail.sharpening = v }
            if let v = p.sharpeningRadius { out.detail.sharpeningRadius = v }
            if let v = p.noiseLuminance { out.detail.noiseLuminance = v }
            if let v = p.noiseColor { out.detail.noiseColor = v }
            if let v = p.lensCorrections { out.detail.lensCorrections = v }
        }

        if let p = optics {
            if let v = p.caRed { out.optics.caRed = v }
            if let v = p.caBlue { out.optics.caBlue = v }
        }

        if let p = effects {
            if let v = p.vignetteAmount { out.effects.vignetteAmount = v }
            if let v = p.vignetteMidpoint { out.effects.vignetteMidpoint = v }
            if let v = p.vignetteFeather { out.effects.vignetteFeather = v }
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
        // 081: absent in every payload written before the 色彩分级 card had a patch — absent means
        // "the destination keeps its own grade", which is exactly what a pre-081 copy did.
        self.colorGrading = c.val("colorGrading", ColorGradingPatch?.none)
        self.detail = c.val("detail", DetailPatch?.none)
        // 156: absent in every payload written before 校正 was carried — absent means "keep the
        // destination's own CA". No schema bump: the key is additive and its default is 0.
        self.optics = c.val("optics", OpticsPatch?.none)
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
