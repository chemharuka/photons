import AppKit
import SwiftUI

// MARK: - the 自动黑电平 icon's frame probe

/// The frame of the 黑电平 card's auto button, and whether any chrome drew around it.
///
/// SwiftUI's plain `Button` has no AppKit control to measure, so the probe hangs off the button with
/// `.background(…)`: a background is sized by its content, which makes this exactly the hit area the
/// 20×18 frame gives the button (the width includes the 2 pt cell overhang it aligns to). `hasBorder`
/// walks a few ancestors for a layer border or a bordered
/// `NSButton`; a `.background`/`stroke`/capsule added to the icon is the regression it is here to catch.
final class BlackLevelAutoProbe: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError("BlackLevelAutoProbe is created in code") }

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

struct BlackLevelAutoProbeHost: NSViewRepresentable {
    func makeNSView(context: Context) -> BlackLevelAutoProbe { BlackLevelAutoProbe() }
    func updateNSView(_ probe: BlackLevelAutoProbe, context: Context) {}
}
