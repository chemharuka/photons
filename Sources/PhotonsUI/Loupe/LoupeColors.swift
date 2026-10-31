import AppKit
import PhotonsCore

extension NSColor {
    /// 054 — the colour of the canvas around the picture: `#0F0F0F`, from
    /// `CanvasPresenter.CanvasMatte` and nowhere else.
    ///
    /// The bands around a fitted photograph are painted by the present pass (they live *in* the canvas
    /// texture — S2/S4 write 0 there), so this colour is only what shows while there is no drawable
    /// yet, or behind a layer that has not been drawn into. It is the same value as the fragment's
    /// matte and the pass's clear colour so the canvas cannot flash black on its way to grey.
    static let canvasMatte = NSColor(srgbRed: CGFloat(CanvasPresenter.CanvasMatte.displayEncoded),
                                     green: CGFloat(CanvasPresenter.CanvasMatte.displayEncoded),
                                     blue: CGFloat(CanvasPresenter.CanvasMatte.displayEncoded),
                                     alpha: 1)
}
