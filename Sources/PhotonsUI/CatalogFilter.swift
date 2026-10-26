import AppKit
import Foundation
import PhotonsCatalog

/// The six colour labels every editor ships, in the order the ⌥1–⌥6 shortcut and the filter
/// popup use. Stored as the lowercase raw value in `assets.color_label`; `normalized` accepts the
/// capitalised spellings that come out of `xmp:Label` ("Red") so a label written by someone else
/// still draws and still filters.
public enum ColorLabel: String, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple

    public var displayName: String {
        switch self {
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .blue: return "蓝"
        case .purple: return "紫"
        }
    }

    public var color: NSColor {
        switch self {
        case .red: return NSColor(srgbRed: 0.90, green: 0.26, blue: 0.24, alpha: 1)
        case .orange: return NSColor(srgbRed: 0.96, green: 0.58, blue: 0.16, alpha: 1)
        case .yellow: return NSColor(srgbRed: 0.95, green: 0.82, blue: 0.20, alpha: 1)
        case .green: return NSColor(srgbRed: 0.36, green: 0.72, blue: 0.34, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.24, green: 0.52, blue: 0.94, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.62, green: 0.36, blue: 0.86, alpha: 1)
        }
    }

    public static func normalized(_ raw: String?) -> ColorLabel? {
        guard let raw, !raw.isEmpty else { return nil }
        let key = raw.lowercased()
        return ColorLabel(rawValue: key)
    }
}

/// Flag values as they live in `assets.flag`. `nil` is "unflagged" — which is what P/X/U write.
public enum AssetFlag: String, CaseIterable, Sendable {
    case pick
    case reject

    public var displayName: String {
        switch self {
        case .pick: return "已选"
        case .reject: return "已拒"
        }
    }

    public var glyph: String {
        switch self {
        case .pick: return "⚑"
        case .reject: return "✕"
        }
    }

    public var color: NSColor {
        switch self {
        case .pick: return NSColor(srgbRed: 0.28, green: 0.78, blue: 0.44, alpha: 1)
        case .reject: return NSColor(srgbRed: 0.94, green: 0.32, blue: 0.30, alpha: 1)
        }
    }

    public static func normalized(_ raw: String?) -> AssetFlag? {
        guard let raw else { return nil }
        return AssetFlag(rawValue: raw.lowercased())
    }
}

/// One slot of the grid's filter bar (026 v2): a dimension and the values ticked inside it.
///
/// The slot is a *view* of the query, not a query: `values` are the canonical strings the catalog
/// speaks (a camera key, `1/800`, `5934607`), and the bar is what makes them readable.
/// **Values inside one slot are OR; slots are AND** — that is the whole contract.
public struct FilterSlot: Equatable, Sendable {
    public var dimension: FilterDimension
    public var values: [String]

    public init(dimension: FilterDimension, values: [String] = []) {
        self.dimension = dimension
        self.values = values
    }

    public var isEmpty: Bool { values.isEmpty }
}

/// The filter bar's value: what the grid is currently narrowed to.
///
/// Deliberately **not** part of `CatalogSession`'s document state and not in history: it is a door
/// on the same query the source list uses (`AssetFilter`), so the grid, the count in the top bar
/// and the row order can never disagree about what "the library" is. Changing a photo — or the
/// selection — never touches it; only the bar and `clearFilter()` do.
///
/// Two shapes live here at once, on purpose:
///
/// - `slots` — 026's five filter slots, the bar's own state (up to 5 dimensions, multi-value each).
/// - `ratingAtLeast` / `flag` / `colorLabel` / `cameraKey` — the pre-026 single-facet controls, still
///   what the CLI-shaped `CatalogFilter(ratingAtLeast: 3)` and the ui-smoke build. They are ANDed with
///   the slots exactly as `AssetFilter.criteria` is ANDed with `AssetFilter`'s own fields, so nothing
///   that already worked had to be rewritten to gain slots.
public struct CatalogFilter: Equatable, Sendable {

    /// The legacy single-facet identity, kept so chips and the smoke keep talking about the same four
    /// things. A slot on one of these dimensions maps onto it (`chipFacet(_:)`), which is what lets a
    /// pre-026 test go on asserting `.rating`.
    public enum Facet: String, CaseIterable, Sendable {
        case rating, flag, color, camera

        public var dimension: FilterDimension {
            switch self {
            case .rating: return .rating
            case .flag: return .flag
            case .color: return .color
            case .camera: return .camera
            }
        }
    }

    /// 026 v2: at most five dimensions can be slots at once.
    public static let slotCapacity = 5

    /// 星级 / 旗标 / 相机 / 镜头 / 文件后缀 — the owner's own example, shipped as the starting bar.
    public static let defaultDimensions: [FilterDimension] = [.rating, .flag, .camera, .lens, .ext]

    public static var defaultSlots: [FilterSlot] { defaultDimensions.map { FilterSlot(dimension: $0) } }

    public var ratingAtLeast: Int?
    public var flag: String?
    public var colorLabel: String?
    public var cameraKey: String?

    /// The bar's slots, **in click order** (v2: 第 1 个点的在最左). At most `slotCapacity`.
    public var slots: [FilterSlot]

    public init(ratingAtLeast: Int? = nil, flag: String? = nil,
                colorLabel: String? = nil, cameraKey: String? = nil,
                slots: [FilterSlot] = CatalogFilter.defaultSlots) {
        self.ratingAtLeast = ratingAtLeast
        self.flag = flag
        self.colorLabel = colorLabel
        self.cameraKey = cameraKey
        self.slots = Array(slots.prefix(Self.slotCapacity))
    }

    public static let none = CatalogFilter()

    // MARK: what it means

    /// The criteria the catalog will run: one per ticked value. Same-dimension criteria OR together
    /// (the slot's multi-select), different dimensions AND.
    public var criteria: [FilterCriterion] {
        slots.flatMap { slot in
            slot.values.map { FilterCriterion(dimension: slot.dimension, value: $0) }
        }
    }

    /// The one place the bar's state becomes a query. `folders` comes from the source tree, which is
    /// why it is a parameter and not a field: the tree owns it, this only folds it in.
    public func assetFilter(limit: Int = 200_000, folders: [FolderSelection] = []) -> AssetFilter {
        AssetFilter(ratingAtLeast: ratingAtLeast,
                    cameraKey: cameraKey,
                    includeDeleted: false,
                    limit: limit,
                    flagEquals: flag,
                    colorLabelEquals: colorLabel,
                    folders: folders,
                    criteria: criteria)
    }

    public var isActive: Bool {
        ratingAtLeast != nil || flag != nil || colorLabel != nil || cameraKey != nil
            || slots.contains { !$0.isEmpty }
    }

    public var activeFacetCount: Int { chips().count }

    // MARK: edits (each returns a new value; the bar owns no state)

    /// The menu's click on a dimension: tick it (append a slot, if there is room) or untick it
    /// (remove the slot, later slots closing the gap and keeping their relative order).
    public func togglingDimension(_ dimension: FilterDimension) -> CatalogFilter {
        var next = self
        if let index = next.slots.firstIndex(where: { $0.dimension == dimension }) {
            next.slots.remove(at: index)
        } else if next.slots.count < Self.slotCapacity {
            next.slots.append(FilterSlot(dimension: dimension))
        }
        return next
    }

    /// 「全部不选」 — every slot goes away, so the next five clicks number 1…5 again.
    public func clearingSlots() -> CatalogFilter {
        var next = self
        next.slots = []
        return next
    }

    /// Tick/untick one value inside one slot. Unticking the last one leaves the slot in place with
    /// 「全部」 — the slot is the dimension the user is looking at, not a condition.
    public func togglingValue(_ value: String, atSlot index: Int) -> CatalogFilter {
        guard slots.indices.contains(index) else { return self }
        var next = self
        if let at = next.slots[index].values.firstIndex(of: value) {
            next.slots[index].values.remove(at: at)
        } else {
            next.slots[index].values.append(value)
        }
        return next
    }

    public func settingValues(_ values: [String], atSlot index: Int) -> CatalogFilter {
        guard slots.indices.contains(index) else { return self }
        var next = self
        next.slots[index].values = values
        return next
    }

    /// A chip's × : drop that one value, never the slot.
    public func removingValue(_ value: String, atSlot index: Int) -> CatalogFilter {
        guard slots.indices.contains(index) else { return self }
        var next = self
        next.slots[index].values.removeAll { $0 == value }
        return next
    }

    // MARK: legacy facets (pre-026 callers)

    /// The chip text for a legacy facet, or nil when that facet is off.
    public func chipText(for facet: Facet) -> String? {
        switch facet {
        case .rating:
            guard let n = ratingAtLeast else { return nil }
            return n == 0 ? "未评级" : "≥\(n) 星"
        case .flag:
            guard let flag else { return nil }
            let f = AssetFlag.normalized(flag)
            return "旗标 \(f?.displayName ?? flag)"
        case .color:
            guard let colorLabel else { return nil }
            return "色标 \(ColorLabel.normalized(colorLabel)?.displayName ?? colorLabel)"
        case .camera:
            guard let cameraKey else { return nil }
            return cameraKey.replacingOccurrences(of: "|", with: " ")
        }
    }

    public func without(_ facet: Facet) -> CatalogFilter {
        var next = self
        switch facet {
        case .rating: next.ratingAtLeast = nil
        case .flag: next.flag = nil
        case .color: next.colorLabel = nil
        case .camera: next.cameraKey = nil
        }
        return next
    }

    // MARK: chips

    /// One removable condition. `origin` is what a click needs to know: a legacy facet clears a field,
    /// a slot drops one ticked value.
    public struct Chip: Equatable, Sendable {
        public enum Origin: Equatable, Sendable {
            case facet(Facet)
            case slot(Int)
        }

        public var origin: Origin
        public var dimension: FilterDimension
        public var text: String
        /// The slot value this chip stands for (nil for a legacy facet chip).
        public var value: String?
    }

    /// Chips in a fixed order — the legacy facets first (they predate slots), then the slots left to
    /// right, and inside a slot the values in tick order. This is the order the bar draws and hit-
    /// tests, and the order the log reads.
    public func chips(cameraLabels: [String: String] = [:]) -> [Chip] {
        var out: [Chip] = []
        for facet in Facet.allCases {
            guard let text = chipText(for: facet) else { continue }
            out.append(Chip(origin: .facet(facet), dimension: facet.dimension, text: text, value: nil))
        }
        for (index, slot) in slots.enumerated() {
            for value in slot.values {
                let label = FilterDisplay.value(slot.dimension, value, cameraLabels: cameraLabels)
                out.append(Chip(origin: .slot(index), dimension: slot.dimension,
                                text: "\(FilterDisplay.title(slot.dimension)) \(label)", value: value))
            }
        }
        return out
    }

    public var summary: String {
        let parts = chips().map(\.text)
        return parts.isEmpty ? "全部照片" : parts.joined(separator: " · ")
    }
}
