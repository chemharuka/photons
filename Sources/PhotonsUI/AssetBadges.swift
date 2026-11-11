import AppKit
import PhotonsCatalog

/// The corner badges on a grid cell: stars, flag, colour label, and the stack indicator.
///
/// Kept as a value computed from `Asset` rather than as view state, for two reasons: the cell can
/// be recycled at any moment (so the badge must be re-derived, never carried over), and the smoke
/// can assert on **what was drawn** — `drawn` is recorded by `draw(in:)` and read back from the
/// cell that actually painted.
///
/// Everything is drawn *inside* the thumbnail rect, on top of the placeholder or the image: the
/// placeholder block is never removed, so the badges are an overlay on top of whatever the cell
/// already drew — a missing or failed thumbnail is "not yet", never a white hole.
public struct AssetBadges: Equatable {

    public let rating: Int
    public let flag: AssetFlag?
    public let colorLabel: ColorLabel?

    /// How many photos the stack this card represents holds, or `0`/`1` when it is not a stack.
    ///
    /// §378: the three browsers only ever show the 置顶 photo, so the count is what tells the eye
    /// that this single card stands for more than one picture. It is passed in by the controller
    /// (from `CatalogSession.stacksByTopID`), not read from `Asset` — the row itself only knows its
    /// own `stack_id`, never how many siblings share it.
    public let stackCount: Int

    public init(rating: Int, flag: String?, colorLabel: String?, stackCount: Int = 0) {
        self.rating = max(0, min(5, rating))
        self.flag = AssetFlag.normalized(flag)
        self.colorLabel = ColorLabel.normalized(colorLabel)
        self.stackCount = max(0, stackCount)
    }

    public init(asset: Asset, stackCount: Int = 0) {
        self.init(rating: asset.rating, flag: asset.flag, colorLabel: asset.colorLabel,
                  stackCount: stackCount)
    }

    /// A stack of one is not a stack (the catalog dissolves those), so the indicator needs ≥ 2.
    public var isStack: Bool { stackCount >= 2 }

    public var isEmpty: Bool {
        rating == 0 && flag == nil && colorLabel == nil && !isStack
    }

    /// What the cell painted, in a form the smoke can compare ("stars:3", "flag:pick", "color:red",
    /// "stack:5").
    public var drawn: [String] {
        var out: [String] = []
        if rating > 0 { out.append("stars:\(rating)") }
        if let flag { out.append("flag:\(flag.rawValue)") }
        if let colorLabel { out.append("color:\(colorLabel.rawValue)") }
        if isStack { out.append("stack:\(stackCount)") }
        return out
    }

    /// One line, human readable: what the badge says, for the smoke log.
    public var signature: String {
        var parts: [String] = []
        if rating > 0 { parts.append("★\(rating)") }
        if let flag { parts.append(flag.glyph) }
        if let colorLabel { parts.append(colorLabel.displayName) }
        if isStack { parts.append("⧉\(stackCount)") }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }

    // MARK: drawing

    private static let pill = NSColor.black.withAlphaComponent(0.55)

    /// Which corner the stack capsule takes. Every surface that draws these badges is **flipped**
    /// (`AssetCardView`, `FilmstripCard`, and the sidebar row's badge overlay), so "top" is `minY`
    /// — the same reading `drawStars`/`drawFlag`/`drawColorDot` already use.
    ///
    /// The grid card and the filmstrip cell use `.topTrailing`, 2 pt under the colour dot. The photo
    /// list's 46 pt row uses `.bottomTrailing`: its square is only 34 pt and the top-right corner
    /// belongs to the colour dot.
    public enum Corner: Sendable {
        case topTrailing
        case bottomTrailing
    }

    /// Draw into the thumbnail rect: stars bottom-left, flag top-left, colour dot top-right, and the
    /// stack capsule top-right under the dot (or bottom-right, per `corner`).
    public func draw(in swatchRect: NSRect, corner: Corner = .topTrailing) {
        guard !isEmpty, swatchRect.width > 24, swatchRect.height > 16 else { return }
        if rating > 0 { drawStars(in: swatchRect) }
        if let flag { drawFlag(flag, in: swatchRect) }
        if let colorLabel { drawColorDot(colorLabel, in: swatchRect) }
        // Last, so the stack indicator is never covered by a dot it sits next to.
        if isStack { drawStackPill(in: swatchRect, corner: corner) }
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

    /// 「⧉ N」 — a rounded black capsule, 11 pt tall, 3 pt padding, white 8 pt text.
    ///
    /// The capsule height and the gap under the colour dot are pinned numbers: the dot occupies
    /// `minY + 5 … minY + 14`, so `minY + 16` is exactly 2 pt below it. That gap is the spec's
    /// "below the dot, 2 pt" and it is why this is a constant rather than computed from the dot.
    private func drawStackPill(in rect: NSRect, corner: Corner) {
        let text = "⧉ \(stackCount)" as NSString
        let textSize = text.size(withAttributes: BadgeStyle.stack)
        let height: CGFloat = 11
        let padX: CGFloat = 3
        let width = min(rect.width - 6, textSize.width + padX * 2)
        let x = rect.maxX - width - 3
        let y: CGFloat = switch corner {
        case .topTrailing: rect.minY + 16
        case .bottomTrailing: rect.maxY - height - 3
        }
        let pillRect = NSRect(x: x, y: y, width: width, height: height)
        Self.pill.setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: height / 2,
                     yRadius: height / 2).fill()
        let textY = pillRect.minY + (height - textSize.height) / 2
        text.draw(at: NSPoint(x: pillRect.minX + padX, y: textY),
                  withAttributes: BadgeStyle.stack)
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
    /// The stack capsule's text: 8 pt semibold white on the black pill.
    public static let stack: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
}
