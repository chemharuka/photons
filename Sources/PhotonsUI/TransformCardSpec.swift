import PhotonsCore

// MARK: - 214: a transform card declares the geometry fields it owns

/// One document field of `GeometryGroup`, as a **name** rather than a closure.
///
/// The transform workspace's resets are derived from these values: a card declares which sections it
/// contains, a section declares which fields it contains, and `PanelResets.reset(fields:)` is the one
/// implementation that writes those fields back to `GeometryGroup.identity`. Nothing at a call site
/// names `.crop` or `.rotation`, so moving a section between cards moves its reset with it.
public enum GeometryField: String, CaseIterable, Sendable, Hashable {
    case cropRect
    case aspectLock
    case straightenDegrees
    case quarterTurns
    case flipHorizontal
    case flipVertical
    case perspectiveVertical
    case perspectiveHorizontal
}

/// A set of `GeometryField`s. Set algebra (not strings, not closures) is what makes the card scope
/// checkable: `fields == sections.map(\.fields).union`.
public struct GeometryFieldSet: Sendable, Hashable, ExpressibleByArrayLiteral {

    public typealias ArrayLiteralElement = GeometryField

    /// The ordered set: `ordered` below reads `GeometryField.allCases`, so the iteration order is a
    /// property of the enum, not of the call site.
    public let fields: Set<GeometryField>

    public static let empty = GeometryFieldSet([])
    public static let all = GeometryFieldSet(GeometryField.allCases)

    public init(_ fields: Set<GeometryField>) {
        self.fields = fields
    }

    public init(_ fields: [GeometryField]) {
        self.fields = Set(fields)
    }

    public init(arrayLiteral elements: GeometryField...) {
        self.init(elements)
    }

    public var isEmpty: Bool { fields.isEmpty }

    /// Enum-declaration order — used by the writer so two runs cannot disagree about write order.
    public var ordered: [GeometryField] { GeometryField.allCases.filter(fields.contains) }

    public func contains(_ field: GeometryField) -> Bool { fields.contains(field) }

    public func union(_ other: GeometryFieldSet) -> GeometryFieldSet {
        GeometryFieldSet(fields.union(other.fields))
    }

    public func intersection(_ other: GeometryFieldSet) -> GeometryFieldSet {
        GeometryFieldSet(fields.intersection(other.fields))
    }

    public func subtracting(_ field: GeometryField) -> GeometryFieldSet {
        GeometryFieldSet(fields.subtracting([field]))
    }

    public static func + (lhs: GeometryFieldSet, rhs: GeometryFieldSet) -> GeometryFieldSet {
        lhs.union(rhs)
    }
}

extension CropSection {

    /// The document fields this section owns. This is the **only** section → field mapping; the
    /// section header's reset and the card title's reset both read it.
    public var fields: GeometryFieldSet {
        switch self {
        case .crop: return [.cropRect, .aspectLock]
        case .angle: return [.straightenDegrees]
        case .perspective: return [.perspectiveVertical, .perspectiveHorizontal]
        case .rotation: return [.quarterTurns]
        case .mirror: return [.flipHorizontal, .flipVertical]
        }
    }
}

/// One card of the transform workspace: its title, the sections it contains, and — **derived from
/// those sections, never spelled a second time** — the geometry fields its title double-click resets.
///
/// Same shape as `InspectorView.PanelCardSpec` (one record per card, the scope is the table), applied
/// to the two transform cards. `fields` has the derived value in production; the explicit parameter
/// exists so the guard tests can build a deliberately incomplete declaration and prove they go red.
public struct TransformCardSpec: Sendable, Hashable {

    public let title: String
    public let sections: [CropSection]
    public let fields: GeometryFieldSet

    public init(title: String, sections: [CropSection], fields: GeometryFieldSet? = nil) {
        self.title = title
        self.sections = sections
        self.fields = fields ?? TransformCardSpec.union(of: sections)
    }

    /// The union of the sections' own field sets — the derivation `fields` uses by default.
    public static func union(of sections: [CropSection]) -> GeometryFieldSet {
        sections.reduce(.empty) { $0.union($1.fields) }
    }

    /// What `sections` implies `fields` must be. The card-title reset uses `fields`; the guard
    /// compares this value with it.
    public var sectionFieldUnion: GeometryFieldSet { TransformCardSpec.union(of: sections) }

    /// 「裁切」 — 宽高比 + 角度 + 透视. Turn and mirror are the other card's, so a double-click here
    /// keeps them exactly as they were.
    public static let cropCard = TransformCardSpec(
        title: InspectorView.Section.crop.title,
        sections: [.crop, .angle, .perspective])

    /// 「旋转」 — 旋转 + 镜像. The crop rect, its lock and the straighten keep what they hold.
    public static let rotationCard = TransformCardSpec(
        title: InspectorView.Section.angle.title,
        sections: [.rotation, .mirror])

    public static let all: [TransformCardSpec] = [.cropCard, .rotationCard]

    /// The card an `InspectorView.Section` draws, if it is one of the transform cards.
    public static func card(for section: InspectorView.Section) -> TransformCardSpec? {
        all.first { $0.title == section.title }
    }

    /// Structural checks the guard test runs over `all` (and over a deliberately broken declaration
    /// in its reverse gate). Empty cards, fields that no section owns, and sections whose fields were
    /// forgotten are all reported.
    public static func issues(in specs: [TransformCardSpec]) -> [String] {
        var issues: [String] = []
        for card in specs {
            if card.sections.isEmpty { issues.append("\(card.title)：没有 section") }
            if card.fields.isEmpty { issues.append("\(card.title)：没有字段") }
            if card.fields != card.sectionFieldUnion {
                let extra = card.fields.ordered.filter { !card.sectionFieldUnion.contains($0) }
                let missing = card.sectionFieldUnion.ordered.filter { !card.fields.contains($0) }
                issues.append("\(card.title)：字段与 section 不一致"
                              + "（多 \(extra.map(\.rawValue)) · 少 \(missing.map(\.rawValue))）")
            }
        }
        let owned = specs.flatMap { $0.fields.ordered }
        if Set(owned).count != owned.count {
            issues.append("同一个 geometry 字段被两张卡同时声明：\(owned.map(\.rawValue))")
        }
        return issues
    }
}
