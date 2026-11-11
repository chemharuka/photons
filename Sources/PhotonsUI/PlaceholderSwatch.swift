import Foundation
import CoreGraphics
import AppKit

/// The M3 stand-in for a thumbnail: a colour block derived from the asset's content hash.
///
/// Deliberately **not** a thumbnail: M3 ships the grid before any thumbnail exists, so what a cell
/// draws is a stand-in by definition.
/// The point is that a 10k-row grid measures the grid — layout, reuse, selection — and not ImageIO.
/// Deriving the colour from `contentHash` keeps it stable across launches and unique per photo, so
/// mistakes in reuse show up as a caption that does not match its block.
public enum PlaceholderSwatch {

    /// Stable, hash-derived HSL-ish triple in 0…1. Pure: no AppKit, no randomness, no state.
    public static func components(for hash: String) -> (hue: Double, saturation: Double, brightness: Double) {
        let bytes = Array(hash.utf8)
        let a = Double(bytes.first.map { Int($0) } ?? 0)
        let b = Double(bytes.count > 7 ? Int(bytes[7]) : 0)
        let c = Double(bytes.count > 15 ? Int(bytes[15]) : 0)
        let hue = (a * 1.7 + b * 0.3).truncatingRemainder(dividingBy: 256) / 256
        let saturation = 0.24 + (b.truncatingRemainder(dividingBy: 7)) * 0.045
        let brightness = 0.34 + (c.truncatingRemainder(dividingBy: 9)) * 0.038
        return (hue, saturation, brightness)
    }

    public static func color(for hash: String, alpha: CGFloat = 1) -> NSColor {
        let c = components(for: hash)
        return NSColor(hue: CGFloat(c.hue), saturation: CGFloat(c.saturation),
                       brightness: CGFloat(c.brightness), alpha: alpha)
    }

    /// Second colour for the very slight vertical gradient that makes a card read as a photo
    /// placeholder rather than a flat swatch.
    public static func secondaryColor(for hash: String) -> NSColor {
        let c = components(for: hash)
        return NSColor(hue: CGFloat(c.hue), saturation: CGFloat(min(1, c.saturation * 0.8)),
                       brightness: CGFloat(min(1, c.brightness * 1.45)), alpha: 1)
    }

    /// One star string, no font work: the cells draw this instead of building attributed runs.
    public static func stars(_ rating: Int) -> String {
        let n = max(0, min(5, rating))
        return String(repeating: "★", count: n) + String(repeating: "☆", count: 5 - n)
    }
}

/// Shared text attributes for the placeholder cells (one allocation, not one per item).
public enum PlaceholderStyle {
    /// The filename caption's font — the grid card and the filmstrip cell draw at this size, and
    /// `fitted(_:width:font:)` is measured with it so the two agree by construction.
    public static let captionFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    /// 377 — a tail-truncating paragraph style for every caption.
    ///
    /// Without it `NSString.draw(in:withAttributes:)` falls back to **word wrapping**, which breaks
    /// the name at a space or a `-` and then clips the second line away: no ellipsis, half the name
    /// missing. `byTruncatingTail` makes the *draw* agree with the *measurement* below (a one-glyph
    /// disagreement would otherwise be the only way the two could drift).
    public static let captionParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .left
        return style
    }()

    public static let captionAttributes: [NSAttributedString.Key: Any] = [
        .font: captionFont,
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: captionParagraphStyle,
    ]

    /// 377 — **the** filename fit, shared by the grid card, the filmstrip cell and the browser row.
    ///
    /// The user's rule: keep the longest head that still fits, end it with `…`, and never let a
    /// space or a `-` decide where the name stops. `MarqueeLayout.tailTruncated` already does
    /// exactly that (character-by-character, ellipsis width included, trailing spaces dropped), so
    /// this is a thin, named entry point rather than a second implementation — three call sites,
    /// one algorithm. A name that fits comes back untouched, with no ellipsis.
    ///
    /// One refinement on top of the seed, because "longest" is judged by the width the string has
    /// **as a whole** (`NSString.size`, which is what the line draws at) and that is up to a kerning
    /// pair narrower than the sum of its characters: after the seed is found, characters from the
    /// original name are appended while `head + next + …` still measures inside `width`. On the
    /// acceptance name at 10 pt, 100 pt wide, that is exactly the one `-` the seed would drop
    /// (99.88 pt with it, 100.06 pt by character sums) — the difference between "longest" in
    /// principle and "longest" as a number.
    public static func fitted(_ filename: String, width: CGFloat, font: NSFont) -> String {
        let seed = MarqueeLayout.tailTruncated(filename, font: font, width: width,
                                               color: .secondaryLabelColor)
        guard seed != filename, seed.hasSuffix(MarqueeLayout.ellipsis) else { return seed }
        guard width > 0, !filename.isEmpty else { return seed }

        let characters = Array(filename)
        // The seed's head is the character-sum answer; its count is therefore a safe lower bound
        // for the whole-string answer (kerning can only make a string narrower, never wider).
        let seedHeadCount = seed.dropLast().count
        guard seedHeadCount < characters.count else { return seed }
        var best = seedHeadCount
        func rendered(_ n: Int) -> String {
            var head = String(characters.prefix(n))
            while head.last == " " { head.removeLast() }
            return head + MarqueeLayout.ellipsis
        }
        // Scan every remaining prefix rather than stopping at the first overflow: the whole-string
        // measure is not *provably* monotone (a kerning pair can shave a fraction of a point), and
        // "longest" has to mean longest. ~60 characters, so the extra measurements are free.
        for n in (seedHeadCount + 1)...characters.count {
            if MarqueeLayout.width(of: rendered(n), font: font,
                                   color: .secondaryLabelColor) <= width { best = n }
        }
        return rendered(best)
    }

    public static let starsAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8, weight: .regular),
        .foregroundColor: NSColor.systemYellow,
    ]
    public static let selectedStarsAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8, weight: .regular),
        .foregroundColor: NSColor.systemYellow,
    ]
}
