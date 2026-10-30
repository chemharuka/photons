import Foundation

// MARK: - Presets (M5)
//
// A preset is a *named, partial* develop document: the groups the user chose plus a fragment that
// holds those groups' values. Two properties make it safe to apply to a photo that already has an
// edit:
//
//  1. **Only the groups in `groups` are written.** Everything else — including `masks` and
//     `showMaskID`, which are never part of a preset at all — is left exactly as the target had it.
//     A "Light" preset must not silently reset a crop.
//  2. **The fragment is stored, not the whole document.** `fragment` in the encoded form contains
//     one key per group in the subset and nothing else, so a preset file cannot carry fields it
//     does not own (docs/xmp-mapping.md §1.8: masks are not mappable, so they are not carried).
//
// `schemaVersion` is the preset envelope's own version, not the document's: a preset written by a
// newer build is refused instead of being applied with fields silently dropped.

/// The groups a preset can carry. Deliberately **not** `RenderGroup`: two of its cases are groups of
/// the document that cannot be groups of a preset — `masks` (per-photo geometry, docs/xmp-mapping.md
/// §1.8) and `heal` (2026-10-28, 078 P0-1: a spot is a repair of *this* picture's blemishes at *these*
/// coordinates; a preset that carried one into another photograph would paint a disk of somebody
/// else's pixels on it, which is why Lightroom's presets do not carry spot removal either) — so
/// reusing `RenderGroup` would invite exactly the mistake this type prevents.
public enum PresetGroup: String, CaseIterable, Sendable, Hashable, Codable {
    case geometry
    case light
    case curve
    case color
    /// 2026-10-28 (P0 色彩分级): the nine wheel numbers — a develop setting like every other group, so
    /// a preset either carries it or does not touch it. (Its own group because `EditModel` gives it one:
    /// `RenderGroup.colorGrading`, S3.8.)
    case colorGrading
    /// 179 — 校准's seven numbers. Its own group because `EditModel` gives it one: it is stored on
    /// the document, editable on its own card, and a preset that carries 白平衡 must not silently
    /// carry a primaries matrix. (`renderGroup` reports `.light` — that is the *render* grouping,
    /// whose `stages` contain `.sceneLinear`, and it is what the inspector uses to colour a row.)
    case calibration
    case detail
    case effects

    /// The document group this preset group writes. `nil` for nothing — every case maps today.
    public var renderGroup: RenderGroup {
        switch self {
        case .geometry: return .geometry
        case .light: return .light
        case .curve: return .curve
        case .color: return .color
        case .colorGrading: return .colorGrading
        case .calibration: return .light
        case .detail: return .detail
        case .effects: return .effects
        }
    }

    public var displayName: String { renderGroup.displayName }

    /// Declaration order, never `Set` iteration order: the encoded preset must be byte-stable.
    public static func ordered(_ groups: Set<PresetGroup>) -> [PresetGroup] {
        PresetGroup.allCases.filter { groups.contains($0) }
    }

    /// Accepts `light`, `Light`, `LIGHT` and a few spellings an XMP/CLI hand might use.
    public init?(token: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = PresetGroup(rawValue: t) { self = exact; return }
        switch t {
        case "tone", "exposure", "whitebalance", "wb": self = .light
        case "tonecurve", "curves": self = .curve
        case "hsl", "colour": self = .color
        case "colorgrading", "grading", "grade", "split", "splittoning", "colorbalance": self = .colorGrading
        case "crop", "transform": self = .geometry
        case "sharpening", "noise", "lens": self = .detail
        // 2026-10-28 (P0-6): the Effects group is the 效果 card, so its three new controls answer to
        // the card's own names as well as to the two older ones.
        case "vignette", "grain", "texture", "clarity", "dehaze", "detailfx": self = .effects
        default: return nil
        }
    }

    /// `"light,curve"` → `[.light, .curve]`. Unknown tokens are returned in `unknown`.
    public static func parse(_ list: String) -> (groups: Set<PresetGroup>, unknown: [String]) {
        var groups: Set<PresetGroup> = []
        var unknown: [String] = []
        for token in list.split(separator: ",") {
            let t = String(token)
            if let g = PresetGroup(token: t) { groups.insert(g) } else if !t.trimmingCharacters(in: .whitespaces).isEmpty {
                unknown.append(t)
            }
        }
        return (groups, unknown)
    }
}

public enum PresetError: LocalizedError, Equatable {
    /// A preset envelope from a build that knows fields this one does not. Refused rather than
    /// half-applied: silently dropping an unknown group is how a look quietly stops matching.
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case emptyName
    case noGroups

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            return "preset schemaVersion \(found) is not supported by this build (v\(supported)); "
                + "it was not loaded"
        case .emptyName: return "a preset needs a non-empty name"
        case .noGroups: return "a preset needs at least one group"
        }
    }
}

/// A named subset of develop settings.
public struct Preset: Sendable, Equatable, Codable {
    /// Bumped when the *envelope* changes shape. Compare with `EditModel.currentSchemaVersion`:
    /// they are different numbers with different meanings.
    ///
    /// **Stays 1 at 081.** The `sections` key below is additive and optional, so a v1 envelope still
    /// decodes (as "whole groups") and a v1 *build* reading a new envelope ignores the key and applies
    /// the groups — the same presets it always did, only coarser. Bumping here would refuse every old
    /// preset for a widening no reader has to care about.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var name: String
    /// Which groups `apply(to:)` writes. A group may legitimately hold identity values (a preset
    /// that *resets* the Light panel), so membership — not non-identity — decides what is written.
    public var groups: Set<PresetGroup>
    /// The fragment. Only the groups in `groups` are read or written; `masks` is always empty and
    /// `showMaskID` always nil, at construction and after every decode.
    public var edit: EditModel

    /// **081: the cards the preset was saved from, when it was saved from the copy sheet.**
    ///
    /// `groups` is the storage unit and stays the authority for the *fragment* — but a group is
    /// coarser than a card (`.light` covers 白平衡, 黑电平 and Light), and 「把当前选中的项目数值为预设」
    /// means a preset that carries exactly those cards. So a section-scoped preset also narrows
    /// **application**: `apply(to:)` merges its fields through `EditSnapshot` instead of replacing the
    /// group, and a 白平衡-only preset no longer resets the destination's 曝光.
    ///
    /// `nil` is every preset written before 081, and means "the whole groups" — that is what keeps old
    /// rows byte-identical and behaviourally unchanged. A build that does not know the key still
    /// applies the groups, which is the coarse answer, never a wrong one.
    public var sections: Set<EditSnapshotSection>?

    public init(name: String,
                groups: Set<PresetGroup> = Set(PresetGroup.allCases),
                edit: EditModel = .neutral,
                sections: Set<EditSnapshotSection>? = nil,
                schemaVersion: Int = Preset.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.groups = groups
        self.sections = sections
        // Only the subset survives: reading `preset.edit.color` on a Light preset must show what
        // would actually be applied (neutral), never a value that is silently dropped on encode.
        self.edit = Preset.project(edit, onto: groups)
    }

    /// Capture a preset from a document: same groups, values as they stand (masks dropped).
    public init(name: String, from edit: EditModel, groups: Set<PresetGroup> = Set(PresetGroup.allCases)) {
        self.init(name: name, groups: groups, edit: edit)
    }

    /// Capture **the cards the user checked** from a document (081 §4: the sheet's 保存为预设).
    ///
    /// The fragment is the checked cards' *current* values over a neutral document
    /// (`EditSnapshot.capture` → `filtered` → `applied(to: .neutral)`), so nothing the user did not
    /// check is in the blob — a 白平衡-only preset does not secretly carry an exposure. 蒙版 is never
    /// in a preset (a mask is this picture's blemish), so the section is dropped here rather than
    /// stored and ignored later.
    public init(name: String, fromSections sections: Set<EditSnapshotSection>, of edit: EditModel) {
        let kept = sections.subtracting([.masks])
        let narrow = EditSnapshot.capture(edit).filtered(to: kept)
        let groups = Set(kept.flatMap { section -> [PresetGroup] in
            switch section {
            case .geometry: return [.geometry]
            case .whiteBalance, .blackLevel, .light: return [.light]
            case .curve: return [.curve]
            case .color, .blackAndWhite, .hsl: return [.color]
            case .colorGrading: return [.colorGrading]
            case .calibration: return [.calibration]
            case .detail: return [.detail]
            // 156: 校正's two leaves live in `OpticsGroup`, which the preset envelope has never had a
            // group for (whole-document presets do not carry CA either). The card is copy/paste only;
            // naming a group here would promise a fragment the encoder cannot write.
            case .correction: return []
            // 164: 纹理 / 清晰度 / 非 Bayer 降噪 are `EffectsGroup` fields, so the preset envelope's
            // effects group is the one that can carry them (the storage group, not the panel card).
            case .detailFX: return [.effects]
            case .effects: return [.effects]
            case .masks: return []
            }
        })
        self.init(name: name, groups: groups, edit: narrow.applied(to: .neutral), sections: kept)
    }

    /// `edit` with everything outside `groups` reset to the document default, and masks /
    /// `showMaskID` dropped. The result is exactly what the encoded fragment carries.
    static func project(_ edit: EditModel, onto groups: Set<PresetGroup>) -> EditModel {
        var out = EditModel.neutral
        out.schemaVersion = edit.schemaVersion
        out.processVersion = edit.processVersion
        for group in PresetGroup.ordered(groups) {
            switch group {
            case .geometry: out.geometry = edit.geometry
            case .light: out.light = edit.light
            case .curve: out.curve = edit.curve
            case .color: out.color = edit.color
            case .colorGrading: out.colorGrading = edit.colorGrading
            case .calibration: out.calibration = edit.calibration
            case .detail: out.detail = edit.detail
            case .effects: out.effects = edit.effects
            }
        }
        out.masks = []
        out.showMaskID = nil
        return out
    }

    // MARK: applying

    /// `target` with the preset's groups replaced. `masks`, `showMaskID`, `schemaVersion` and
    /// `processVersion` are always the target's own.
    ///
    /// When `sections` is set (081) the merge is **field-level** instead: the fragment is re-read as a
    /// sparse snapshot narrowed to those cards, so a 白平衡-only preset writes the Kelvin pair and
    /// leaves the destination's 曝光, 黑电平 and 曲线 alone. `groups` still says which keys the blob
    /// carries; it is the fragment that decides which leaves land.
    public func apply(to target: EditModel) -> EditModel {
        if let sections, !sections.isEmpty {
            return EditSnapshot.capture(edit).filtered(to: sections).applied(to: target)
        }
        var out = target
        for group in PresetGroup.ordered(groups) {
            switch group {
            case .geometry: out.geometry = edit.geometry
            case .light: out.light = edit.light
            case .curve: out.curve = edit.curve
            case .color: out.color = edit.color
            case .colorGrading: out.colorGrading = edit.colorGrading
            case .calibration: out.calibration = edit.calibration
            case .detail: out.detail = edit.detail
            case .effects: out.effects = edit.effects
            }
        }
        return out
    }

    /// Groups this preset would actually change on `target` (semantic comparison, D10's tolerance).
    public func changedGroups(appliedTo target: EditModel) -> Set<RenderGroup> {
        EditHistory.dirtyGroups(from: target, to: apply(to: target))
    }

    // MARK: Codable

    /// Encoded shape — the fragment is the only place values live, and it holds one key per group:
    ///
    /// ```json
    /// {"schemaVersion":1,"name":"Punch","groups":["light","curve"],
    ///  "fragment":{"light":{…},"curve":{…}}}
    /// ```
    private enum Key {
        static let schemaVersion = AnyCodingKey("schemaVersion")
        static let name = AnyCodingKey("name")
        static let groups = AnyCodingKey("groups")
        static let sections = AnyCodingKey("sections")
        static let fragment = AnyCodingKey("fragment")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(schemaVersion, forKey: Key.schemaVersion)
        try c.encode(name, forKey: Key.name)
        try c.encode(PresetGroup.ordered(groups).map(\.rawValue), forKey: Key.groups)
        // 081: only when the preset was saved from the copy sheet's cards. **Absent** for every other
        // preset, which is what keeps their bytes — and their old behaviour — identical.
        if let sections {
            try c.encode(EditSnapshotSection.panelOrder
                            .filter { sections.contains($0) }
                            .map(\.rawValue),
                         forKey: Key.sections)
        }
        var fragment = c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: Key.fragment)
        for group in PresetGroup.ordered(groups) {
            switch group {
            case .geometry: try fragment.encode(edit.geometry, forKey: AnyCodingKey(group.rawValue))
            case .light: try fragment.encode(edit.light, forKey: AnyCodingKey(group.rawValue))
            case .curve: try fragment.encode(edit.curve, forKey: AnyCodingKey(group.rawValue))
            case .color: try fragment.encode(edit.color, forKey: AnyCodingKey(group.rawValue))
            case .colorGrading:
                try fragment.encode(edit.colorGrading, forKey: AnyCodingKey(group.rawValue))
            case .calibration:
                try fragment.encode(edit.calibration, forKey: AnyCodingKey(group.rawValue))
            case .detail: try fragment.encode(edit.detail, forKey: AnyCodingKey(group.rawValue))
            case .effects: try fragment.encode(edit.effects, forKey: AnyCodingKey(group.rawValue))
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let version = c.val("schemaVersion", Preset.currentSchemaVersion)
        guard version == Preset.currentSchemaVersion else {
            throw PresetError.unsupportedSchemaVersion(found: version,
                                                       supported: Preset.currentSchemaVersion)
        }
        self.schemaVersion = version
        self.name = c.val("name", "")

        let rawGroups: [String] = c.val("groups", PresetGroup.allCases.map(\.rawValue))
        var groups: Set<PresetGroup> = []
        for raw in rawGroups {
            if let group = PresetGroup(rawValue: raw) { groups.insert(group) }
        }
        self.groups = groups

        // The groups list is authoritative: a fragment key outside it is ignored, and a listed
        // group with no fragment value reads as neutral (a preset that resets that panel).
        var edit = EditModel.neutral
        if let fragment = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: Key.fragment) {
            if groups.contains(.geometry) { edit.geometry = fragment.val("geometry", edit.geometry) }
            if groups.contains(.light) { edit.light = fragment.val("light", edit.light) }
            if groups.contains(.curve) { edit.curve = fragment.val("curve", edit.curve) }
            if groups.contains(.color) { edit.color = fragment.val("color", edit.color) }
            if groups.contains(.colorGrading) {
                edit.colorGrading = fragment.val("colorGrading", edit.colorGrading)
            }
            if groups.contains(.calibration) {
                edit.calibration = fragment.val("calibration", edit.calibration)
            }
            if groups.contains(.detail) { edit.detail = fragment.val("detail", edit.detail) }
            if groups.contains(.effects) { edit.effects = fragment.val("effects", edit.effects) }
        }
        // Masks are never read back into a preset, even if a hand-written file carries them.
        self.edit = Preset.project(edit, onto: groups)

        // 081: optional. An unknown name is dropped rather than fatal (the same rule the stored
        // checklist uses), and an empty result stays `nil` — "the whole groups", never "nothing".
        if let raw: [String] = c.val("sections", [String]?.none) {
            let known = Set(raw.compactMap(EditSnapshotSection.init(rawValue:)))
            self.sections = known.isEmpty ? nil : known
        } else {
            self.sections = nil
        }
    }

    // MARK: convenience

    public static func load(from url: URL) throws -> Preset {
        try JSONDecoder().decode(Preset.self, from: Data(contentsOf: url))
    }
}
