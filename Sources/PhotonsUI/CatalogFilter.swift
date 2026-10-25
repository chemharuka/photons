import AppKit
import Foundation

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

/// The filter bar's value: what the grid is currently narrowed to.
///
/// Deliberately **not** part of `CatalogSession`'s document state and not in history: it is a door
/// on the same query the source list uses (`AssetFilter`), so the grid, the count in the top bar
/// and the row order can never disagree about what "the library" is. Changing a photo — or the
/// selection — never touches it; only the bar and `clearFilter()` do.
public struct CatalogFilter: Equatable, Sendable {

    public enum Facet: String, CaseIterable, Sendable {
        case rating, flag, color, camera
    }

    public var ratingAtLeast: Int?
    public var flag: String?
    public var colorLabel: String?
    public var cameraKey: String?

    public init(ratingAtLeast: Int? = nil, flag: String? = nil,
                colorLabel: String? = nil, cameraKey: String? = nil) {
        self.ratingAtLeast = ratingAtLeast
        self.flag = flag
        self.colorLabel = colorLabel
        self.cameraKey = cameraKey
    }

    public static let none = CatalogFilter()

    public var isActive: Bool {
        ratingAtLeast != nil || flag != nil || colorLabel != nil || cameraKey != nil
    }

    public var activeFacetCount: Int {
        [ratingAtLeast != nil, flag != nil, colorLabel != nil, cameraKey != nil]
            .filter { $0 }.count
    }

    /// The chip text for a facet, or nil when that facet is off.
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
            return cameraKey
        }
    }

    /// Chips in a fixed facet order — the bar's hit-testing and the log both read this.
    public var chips: [(facet: Facet, text: String)] {
        Facet.allCases.compactMap { facet in
            chipText(for: facet).map { (facet, $0) }
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

    public var summary: String {
        let parts = chips.map { $0.text }
        return parts.isEmpty ? "全部照片" : parts.joined(separator: " · ")
    }
}
