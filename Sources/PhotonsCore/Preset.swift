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

/// The groups a preset can carry. Deliberately **not** `RenderGroup`: `masks` is a group of the
/// document but cannot be a group of a preset (masks are per-photo geometry, docs/xmp-mapping.md
/// §1.8), so reusing `RenderGroup` would invite exactly the mistake this type prevents.
public enum PresetGroup: String, CaseIterable, Sendable, Hashable, Codable {
    case geometry
    case light
    case curve
    case color
    /// 2026-10-28 (P0 色彩分级): the nine wheel numbers — a develop setting like every other group, so
    /// a preset either carries it or does not touch it. (Its own group because `EditModel` gives it one:
    /// `RenderGroup.colorGrading`, S3.8.)
    case colorGrading
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
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var name: String
    /// Which groups `apply(to:)` writes. A group may legitimately hold identity values (a preset
    /// that *resets* the Light panel), so membership — not non-identity — decides what is written.
    public var groups: Set<PresetGroup>
    /// The fragment. Only the groups in `groups` are read or written; `masks` is always empty and
    /// `showMaskID` always nil, at construction and after every decode.
    public var edit: EditModel

    public init(name: String,
                groups: Set<PresetGroup> = Set(PresetGroup.allCases),
                edit: EditModel = .neutral,
                schemaVersion: Int = Preset.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.groups = groups
        // Only the subset survives: reading `preset.edit.color` on a Light preset must show what
        // would actually be applied (neutral), never a value that is silently dropped on encode.
        self.edit = Preset.project(edit, onto: groups)
    }

    /// Capture a preset from a document: same groups, values as they stand (masks dropped).
    public init(name: String, from edit: EditModel, groups: Set<PresetGroup> = Set(PresetGroup.allCases)) {
        self.init(name: name, groups: groups, edit: edit)
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
    public func apply(to target: EditModel) -> EditModel {
        var out = target
        for group in PresetGroup.ordered(groups) {
            switch group {
            case .geometry: out.geometry = edit.geometry
            case .light: out.light = edit.light
            case .curve: out.curve = edit.curve
            case .color: out.color = edit.color
            case .colorGrading: out.colorGrading = edit.colorGrading
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
        static let fragment = AnyCodingKey("fragment")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(schemaVersion, forKey: Key.schemaVersion)
        try c.encode(name, forKey: Key.name)
        try c.encode(PresetGroup.ordered(groups).map(\.rawValue), forKey: Key.groups)
        var fragment = c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: Key.fragment)
        for group in PresetGroup.ordered(groups) {
            switch group {
            case .geometry: try fragment.encode(edit.geometry, forKey: AnyCodingKey(group.rawValue))
            case .light: try fragment.encode(edit.light, forKey: AnyCodingKey(group.rawValue))
            case .curve: try fragment.encode(edit.curve, forKey: AnyCodingKey(group.rawValue))
            case .color: try fragment.encode(edit.color, forKey: AnyCodingKey(group.rawValue))
            case .colorGrading:
                try fragment.encode(edit.colorGrading, forKey: AnyCodingKey(group.rawValue))
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
            if groups.contains(.detail) { edit.detail = fragment.val("detail", edit.detail) }
            if groups.contains(.effects) { edit.effects = fragment.val("effects", edit.effects) }
        }
        // Masks are never read back into a preset, even if a hand-written file carries them.
        self.edit = Preset.project(edit, onto: groups)
    }

    // MARK: convenience

    public static func load(from url: URL) throws -> Preset {
        try JSONDecoder().decode(Preset.self, from: Data(contentsOf: url))
    }
}
