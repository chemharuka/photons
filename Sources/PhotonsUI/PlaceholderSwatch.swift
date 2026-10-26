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
    public static let captionAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
    public static let starsAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8, weight: .regular),
        .foregroundColor: NSColor.systemYellow,
    ]
    public static let selectedStarsAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8, weight: .regular),
        .foregroundColor: NSColor.systemYellow,
    ]
}
