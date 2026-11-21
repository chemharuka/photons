import PhotonsLocalization
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
///
/// §382 — the corners were re-divided so the stack count is the most visible of them; see
/// `layout(in:)` for the table and the numbers. The same four corners are used by all three
/// surfaces (grid card, filmstrip cell, photo-list row).
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

    // MARK: geometry (§382)

    /// The four corners, re-divided so that 「this card stands for N photos」 is the **first** thing
    /// the eye lands on:
    ///
    /// | corner | what |
    /// |---|---|
    /// | bottom-left | 「⧉ N」 stack capsule (13 pt, 9 pt semibold), stars 3 pt to its right |
    /// | top-left | one capsule holding the flag glyph and the colour dot, 3 pt apart |
    /// | top-right | nothing (the dot moved next to the flag — the user's 16:3x call) |
    ///
    /// All three surfaces are *flipped* (`AssetCardView`, `FilmstripCard`, `StackBadgeView`), so
    /// `minY` is the top edge and `maxY` is the bottom edge — "bottom-left" is `minX + inset,
    /// maxY − height − inset`.
    ///
    /// These numbers are the ticket's: inset 3, capsule 13 pt tall, 4 pt horizontal padding, 3 pt
    /// between neighbours, 7 pt dot. They are pinned here (not derived) because the acceptance
    /// quotes them, and one place is what keeps the three faces on the same geometry.
    ///
    /// 465 —— 色点 9 → **7 pt**：用户口径「色标比选中的绿色旗帜大很多，稍微调小以匹配」。旗帜是
    /// 9 pt bold 的 `⚑`，墨迹实测 4.5 × 6.0 pt（`✕` 是 6.0 × 6.5）；9 pt 的实心圆比它高一半、面积
    /// 大四倍，一眼看过去色标在抢戏。7 pt 与字形墨迹同高，胶囊高度（13）不变，`padX` 也不动。
    public enum BadgeMetrics {
        public static let inset: CGFloat = 3
        public static let pillHeight: CGFloat = 13
        public static let padX: CGFloat = 4
        public static let gap: CGFloat = 3
        public static let dot: CGFloat = 7
    }

    /// Where a paint put the capsules, in the thumbnail rect's own coordinates.
    ///
    /// Returned by `layout(in:)` and recorded by each cell during its draw, so 「the capsule is 3 pt
    /// from the bottom-left corner」 is a number a test can read off the surface that painted it
    /// rather than a claim about the helper.
    public struct Layout: Equatable {
        public var stackPill: NSRect?
        public var starsPill: NSRect?
        public var flagPill: NSRect?
        /// Where the flag glyph itself was painted, inside `flagPill` (the left half).
        public var flagGlyphRect: NSRect?
        /// Where the colour dot was painted, inside `flagPill` (the right half).
        public var colorDotRect: NSRect?
        public var stackText: String
        public var starsText: String
        public var flagText: String

        public init(stackPill: NSRect? = nil, starsPill: NSRect? = nil, flagPill: NSRect? = nil,
                    flagGlyphRect: NSRect? = nil, colorDotRect: NSRect? = nil,
                    stackText: String = "", starsText: String = "", flagText: String = "") {
            self.stackPill = stackPill
            self.starsPill = starsPill
            self.flagPill = flagPill
            self.flagGlyphRect = flagGlyphRect
            self.colorDotRect = colorDotRect
            self.stackText = stackText
            self.starsText = starsText
            self.flagText = flagText
        }
    }

    /// Which corner the stack capsule takes.
    ///
    /// Kept for source compatibility (the list's badge view still passes it): §382 pinned the
    /// layout to *the same* four corners on all three surfaces, so the value no longer moves
    /// anything. It is deliberately not read — a per-surface corner is exactly what made the
    /// filmstrip and the list disagree with the grid.
    public enum Corner: Sendable {
        case topTrailing
        case bottomTrailing
    }

    /// The capsules this badge would paint in `rect` — the same function `draw` paints from.
    ///
    /// `drawsStars: false` is for the photo list's row: stars are already a text line of their own
    /// there, so the square only carries the stack count and the flag/colour capsule. The `drawn`
    /// vocabulary is unaffected — the row paints its stars as text.
    public func layout(in rect: NSRect, drawsStars: Bool = true) -> Layout {
        var out = Layout()
        guard !isEmpty, rect.width > 24, rect.height > 16 else { return out }
        let m = BadgeMetrics.self
        let y = rect.maxY - m.pillHeight - m.inset     // flipped: the bottom row
        var x = rect.minX + m.inset

        if isStack {
            let text = "⧉ \(stackCount)" as NSString
            let width = min(rect.width - m.inset * 2,
                            ceil(text.size(withAttributes: BadgeStyle.stack).width) + m.padX * 2)
            out.stackPill = NSRect(x: x, y: y, width: width, height: m.pillHeight)
            out.stackText = text as String
            x = out.stackPill!.maxX + m.gap
        }
        // The count is the most prominent badge, and the stars sit to its right on the same baseline.
        // §382 rule for a surface too narrow to hold both: the count wins and the stars give way —
        // never the other way round. (At the shipped sizes both fit: the 90 pt filmstrip cell and the
        // ≥150 pt grid card; the 34 pt list square passes `drawsStars: false` and paints its stars as
        // a text line instead.)
        if drawsStars, rating > 0 {
            let text = String(repeating: "★", count: rating) as NSString
            let width = ceil(text.size(withAttributes: BadgeStyle.stars).width) + m.padX * 2
            if x + width <= rect.maxX - m.inset {
                out.starsPill = NSRect(x: x, y: y, width: width, height: m.pillHeight)
                out.starsText = text as String
            }
        }
        // Flag + colour label share one capsule in the top-left corner: both are small and their
        // width is bounded, and the user asked for them side by side (2026-11-11 16:3x).
        if flag != nil || colorLabel != nil {
            let glyph = (flag?.glyph ?? "") as NSString
            var inner = flag == nil ? 0 : ceil(glyph.size(withAttributes: BadgeStyle.flagGlyph).width)
            if flag != nil, colorLabel != nil { inner += m.gap }
            if colorLabel != nil { inner += m.dot }
            let width = min(rect.width - m.inset * 2, inner + m.padX * 2)
            out.flagPill = NSRect(x: rect.minX + m.inset, y: rect.minY + m.inset,
                                  width: width, height: m.pillHeight)
            out.flagText = glyph as String
        }
        return out
    }

    /// Draw into the thumbnail rect: 「⧉ N」 + stars bottom-left, flag + colour dot top-left.
    ///
    /// `corner` is accepted for source compatibility but no longer steers the layout — §382 fixed
    /// the four corners for all three surfaces (see `Corner`). Returns the rects it painted, so the
    /// surface can record them as evidence.
    @discardableResult
    public func draw(in swatchRect: NSRect, corner: Corner = .topTrailing,
                     drawsStars: Bool = true) -> Layout {
        let m = BadgeMetrics.self
        let l = layout(in: swatchRect, drawsStars: drawsStars)

        if let pillRect = l.stackPill {
            drawPill(pillRect)
            let text = l.stackText as NSString
            let size = text.size(withAttributes: BadgeStyle.stack)
            text.draw(at: NSPoint(x: pillRect.minX + m.padX,
                                  y: pillRect.minY + (m.pillHeight - size.height) / 2),
                      withAttributes: BadgeStyle.stack)
        }
        if let pillRect = l.starsPill {
            drawPill(pillRect)
            let text = l.starsText as NSString
            let size = text.size(withAttributes: BadgeStyle.stars)
            text.draw(at: NSPoint(x: pillRect.minX + m.padX,
                                  y: pillRect.minY + (m.pillHeight - size.height) / 2),
                      withAttributes: BadgeStyle.stars)
        }
        if let pillRect = l.flagPill {
            drawPill(pillRect)
            var x = pillRect.minX + m.padX
            var out = l
            if let flag, !l.flagText.isEmpty {
                let glyph = l.flagText as NSString
                let size = glyph.size(withAttributes: BadgeStyle.flagGlyph)
                let glyphRect = NSRect(x: x, y: pillRect.minY + (m.pillHeight - size.height) / 2,
                                       width: size.width, height: size.height)
                glyph.draw(at: glyphRect.origin,
                           withAttributes: BadgeStyle.flagAttributes(for: flag))
                out.flagGlyphRect = glyphRect
                x += size.width + (colorLabel == nil ? 0 : m.gap)
            }
            if let colorLabel {
                let dot = NSRect(x: x,
                                 y: pillRect.minY + (m.pillHeight - m.dot) / 2,
                                 width: m.dot, height: m.dot)
                colorLabel.color.setFill()
                NSBezierPath(ovalIn: dot).fill()
                NSColor.white.withAlphaComponent(0.85).setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                ring.stroke()
                out.colorDotRect = dot
            }
            return out
        }
        return l
    }

    private func drawPill(_ rect: NSRect) {
        Self.pill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2,
                     yRadius: rect.height / 2).fill()
    }

    private static let pill = NSColor.black.withAlphaComponent(0.55)
}

/// §382 — the words a stack adds to the three surfaces, in **one** place.
///
/// Two strings, both display-only: the 置顶 photo's caption/name is 「堆叠 XXX.dng」, and
/// `countLabel` is the 「堆叠5张」 wording — **no longer drawn in the photo list** (465: 用户要求侧栏
/// 不显示张数文字), kept because the smoke's string probe and the 382 acceptance assert it. Neither
/// `asset.filename` nor anything on disk moves —
/// the prefix is composed here and fitted afterwards (`PlaceholderStyle.fitted` on the *joined*
/// string), so the truncation is solved for the string the eye actually sees.
public enum StackText {
    public static let prefix = Loc.t("堆叠 ")
    public static let empty = ""

    /// 「堆叠 XXX.dng」 for a stack's 置顶, the filename untouched otherwise.
    public static func displayName(_ filename: String, isStack: Bool) -> String {
        isStack ? prefix + filename : filename
    }

    /// 「堆叠5张」 — Arabic digits, as the user asked (16:2x). 465：列表不再画它（用户要求侧栏不显示
    /// 「堆叠N张」），只剩这一处字符串口径与它的断言。
    public static func countLabel(_ count: Int) -> String {
        Loc.t("堆叠{0}张", String(describing: (count)))
    }
}

/// 465 —— 侧栏照片行第三行的字：**星级 + 选取 + 色标**，一个 attributed 串。
///
/// 用户口径（2026-11-21）：这三样不再画在缩略图上，而是和星级一起放到第三行；顺序是
/// 「星级 + 选取 + 色标」，空格分隔、**有就占位、没有就下一个靠左**。堆叠指示在同一行右端（见
/// `stackIndicator(_:)`），所以这里只管左半。
///
/// 为什么要 attributed 而不是纯文本：三样各有自己的颜色（星级黄、旗帜绿/红、色标红/黄/绿/蓝/紫），
/// 而 `NSTextField(stringValue:)` 只有一个 `textColor`。串本身仍是「有就画」，不补占位符。
public enum RowBadgeLine {
    /// 色标的字形：一个实心圆点，颜色就是色标色（与缩略图上的圆点是同一个语义）。
    public static let colorGlyph = "●"
    /// 堆叠指示的字形：与网格 / 胶片条的胶囊同一个 `⧉`。
    public static let stackGlyph = "⧉"

    /// 纯文本（无障碍标签、探针与日志用），与 `attributed` 逐字符一致。
    public static func text(_ badges: AssetBadges) -> String {
        attributed(badges, font: .systemFont(ofSize: 9)).string
    }

    /// 第三行左半：星级、旗帜、色点，按这个顺序，空格分隔，只放**有的**项。
    public static func attributed(_ badges: AssetBadges, font: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let space: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        func add(_ glyph: String, _ color: NSColor) {
            if out.length > 0 { out.append(NSAttributedString(string: " ", attributes: space)) }
            out.append(NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: color]))
        }
        if badges.rating > 0 {
            add(String(repeating: "★", count: badges.rating), .systemYellow)
        }
        if let flag = badges.flag {
            add(flag.glyph, flag.color)
        }
        if let label = badges.colorLabel {
            add(colorGlyph, label.color)
        }
        return out
    }

    /// 右端的堆叠指示：「⧉ 3」。不是堆叠（< 2 张）时调用方给空串并隐藏这个 label。
    public static func stackIndicator(_ count: Int) -> String {
        count >= 2 ? "\(stackGlyph) \(count)" : ""
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
    /// §382 — the flag glyph in **its own colour**, inside the shared flag+colour capsule. The glyph
    /// used to sit on a capsule filled with that colour; now the capsule is shared with the colour
    /// dot, so the colour moves onto the glyph (and P/X still read apart at a glance).
    public static func flagAttributes(for flag: AssetFlag) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: flag.color]
    }
    /// The stack capsule's text: 9 pt semibold white on the black pill (13 pt tall, §382).
    public static let stack: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
}
