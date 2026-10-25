import AppKit
import PhotonsCatalog

/// The corner badges on a grid cell: stars, flag, colour label.
///
/// Kept as a value computed from `Asset` rather than as view state, for two reasons: the cell can
/// be recycled at any moment (so the badge must be re-derived, never carried over), and the smoke
/// can assert on **what was drawn** — `drawn` is recorded by `draw(in:)` and read back from the
/// cell that actually painted.
///
/// Everything is drawn *inside* the thumbnail rect, on top of the placeholder or the image: the
/// placeholder block is never removed (docs/tasks/006-thumbnails.md §2), the badges are an overlay.
public struct AssetBadges: Equatable {

    public let rating: Int
    public let flag: AssetFlag?
    public let colorLabel: ColorLabel?

    public init(rating: Int, flag: String?, colorLabel: String?) {
        self.rating = max(0, min(5, rating))
        self.flag = AssetFlag.normalized(flag)
        self.colorLabel = ColorLabel.normalized(colorLabel)
    }

    public init(asset: Asset) {
        self.init(rating: asset.rating, flag: asset.flag, colorLabel: asset.colorLabel)
    }

    public var isEmpty: Bool { rating == 0 && flag == nil && colorLabel == nil }

    /// What the cell painted, in a form the smoke can compare ("stars:3", "flag:pick", "color:red").
    public var drawn: [String] {
        var out: [String] = []
        if rating > 0 { out.append("stars:\(rating)") }
        if let flag { out.append("flag:\(flag.rawValue)") }
        if let colorLabel { out.append("color:\(colorLabel.rawValue)") }
        return out
    }

    /// One line, human readable: what the badge says, for the smoke log.
    public var signature: String {
        var parts: [String] = []
        if rating > 0 { parts.append("★\(rating)") }
        if let flag { parts.append(flag.glyph) }
        if let colorLabel { parts.append(colorLabel.displayName) }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }

    // MARK: drawing

    private static let pill = NSColor.black.withAlphaComponent(0.55)

    /// Draw into the thumbnail rect: stars bottom-left, flag top-left, colour dot top-right.
    public func draw(in swatchRect: NSRect) {
        guard !isEmpty, swatchRect.width > 24, swatchRect.height > 16 else { return }
        if rating > 0 { drawStars(in: swatchRect) }
        if let flag { drawFlag(flag, in: swatchRect) }
        if let colorLabel { drawColorDot(colorLabel, in: swatchRect) }
    }

    private func drawStars(in rect: NSRect) {
        let text = String(repeating: "★", count: rating)
        let size = (text as NSString).size(withAttributes: BadgeStyle.stars)
        let pillRect = NSRect(x: rect.minX + 3,
                              y: rect.maxY - size.height - 5,
                              width: size.width + 8,
                              height: size.height + 2)
        Self.pill.setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2,
                     yRadius: pillRect.height / 2).fill()
        (text as NSString).draw(at: NSPoint(x: pillRect.minX + 4, y: pillRect.minY + 1),
                                withAttributes: BadgeStyle.stars)
    }

    private func drawFlag(_ flag: AssetFlag, in rect: NSRect) {
        let glyph = flag.glyph as NSString
        let size = glyph.size(withAttributes: BadgeStyle.flagGlyph)
        let pillRect = NSRect(x: rect.minX + 3, y: rect.minY + 3,
                              width: size.width + 8, height: size.height + 2)
        let path = NSBezierPath(roundedRect: pillRect, xRadius: 3, yRadius: 3)
        flag.color.withAlphaComponent(0.85).setFill()
        path.fill()
        glyph.draw(at: NSPoint(x: pillRect.minX + 4, y: pillRect.minY + 1),
                   withAttributes: BadgeStyle.flagGlyph)
    }

    private func drawColorDot(_ label: ColorLabel, in rect: NSRect) {
        let d: CGFloat = 9
        let dot = NSRect(x: rect.maxX - d - 5, y: rect.minY + 5, width: d, height: d)
        label.color.setFill()
        NSBezierPath(ovalIn: dot).fill()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }
}

/// One set of attributes for every cell (the original stars code did the same, for the same reason:
/// no per-item font building on a 10k-row grid).
public enum BadgeStyle {
    public static let stars: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
        .foregroundColor: NSColor.systemYellow,
    ]
    public static let flagGlyph: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
}
