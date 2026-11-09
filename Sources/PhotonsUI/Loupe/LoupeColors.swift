import AppKit
import PhotonsCore

extension NSColor {
    /// 054 — the colour of the canvas around the picture: `#202020` at the default stop (315), from
    /// `CanvasBackdrop.current` and nowhere else.
    ///
    /// The bands around a fitted photograph are painted by the present pass (they live *in* the canvas
    /// texture — S2/S4 write 0 there), so this colour is only what shows while there is no drawable
    /// yet, or behind a layer that has not been drawn into. It is the same value as the pass's clear
    /// colour so the canvas cannot flash black on its way to grey.
    ///
    /// **315 — computed, not stored.** The stop is a preference; a stored `NSColor` would be the one
    /// copy that never heard about a change.
    static var canvasMatte: NSColor {
        let v = CGFloat(CanvasBackdrop.current.displayEncoded)
        return NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
    }
}
