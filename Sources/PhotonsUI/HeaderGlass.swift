import AppKit

/// Opaque studio header; the historical public name is retained for callers.
/// Native AppKit window buttons remain above it. Hit testing passes through to the title bar.
public final class HeaderGlassView: NSView {
    public init() {
        super.init(frame: .zero)
        autoresizingMask = [.width]
        clipsToBounds = true
    }
    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }
    public override var isOpaque: Bool { true }
    public override func draw(_ dirtyRect: NSRect) {
        StudioTheme.raised.setFill()
        bounds.intersection(dirtyRect).fill()
        StudioTheme.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
