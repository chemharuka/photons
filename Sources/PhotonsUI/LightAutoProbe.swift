import AppKit
import SwiftUI

// MARK: - 422 — the 自动调节 icon's frame probe

/// The frame of the Light card's 自动调节 button, and whether any chrome drew around it.
///
/// Exact same shape as `BlackLevelAutoProbe` (071/089), because the two buttons are the same control
/// family: a bare 14 pt `wand.and.stars` with a 20×18 hit area and no bottom, no border, no capsule.
/// A `.background(…)` is sized by its content, so this view's own frame *is* the hit area the button
/// gives (the width includes the 2 pt cell overhang it aligns to), and `hasBorder` walks a few
/// ancestors for a layer border / a fill / a bordered `NSButton` — the regression it is here to catch.
final class LightAutoProbe: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError("LightAutoProbe is created in code") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    var hasBorder: Bool {
        var view: NSView? = self
        var depth = 0
        while let current = view, depth < 4 {
            if let layer = current.layer,
               layer.borderWidth > 0 || (layer.backgroundColor.map { $0.alpha > 0.001 } ?? false) {
                return true
            }
            if let button = current as? NSButton, button.isBordered { return true }
            view = current.superview
            depth += 1
        }
        return false
    }
}

struct LightAutoProbeHost: NSViewRepresentable {
    func makeNSView(context: Context) -> LightAutoProbe { LightAutoProbe() }
    func updateNSView(_ probe: LightAutoProbe, context: Context) {}
}
