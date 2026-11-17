import AppKit
import PhotonsLocalization
import SwiftUI

/// Neutral, opaque surfaces keep the photograph's surround stable across desktop wallpapers.
enum StudioTheme {
    static let panel = adaptive("studio.panel", dark: 0.17, light: 0.94)
    static let raised = adaptive("studio.raised", dark: 0.20, light: 0.98)
    static let well = adaptive("studio.well", dark: 0.12, light: 0.88)
    static let separator = adaptive("studio.separator", dark: 0.09, light: 0.78)
    static let labelWidth: CGFloat = L10n.language == "en" ? 82:62
    static let valueWidth: CGFloat = 64
    static let rowHeight: CGFloat = 26

    private static func adaptive(_ name: String, dark: CGFloat, light: CGFloat) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value, green: value, blue: value, alpha: 1)
        }
    }
}

final class StudioPanelView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("no nib") }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        StudioTheme.panel.setFill()
        bounds.intersection(dirtyRect).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
