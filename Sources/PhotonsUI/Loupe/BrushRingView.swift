import AppKit
import QuartzCore

/// 247 — the brush-size circle the canvas draws for 修复.
///
/// It is a **pure overlay**: two `CAShapeLayer`s over the canvas, no draw calls, no render request
/// and no hit testing. Every pointer move only rewrites a path; the picture, the decode ladder and
/// the history never hear about it.
public final class BrushRingView: NSView {

    private let outer = CAShapeLayer()
    private let inner = CAShapeLayer()
    private var storedCenter: CGPoint = .zero
    private var storedDiameter: CGFloat = 0

    /// Set by `LoupeCanvasView`; lets the getters answer with the controller's live radius even
    /// when the value was written through another door (the card's slider writes the document
    /// directly). The drawn path still follows `show(...)` / `refreshHealRing()`.
    weak var controller: LoupeController?

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        layer?.masksToBounds = false

        outer.fillColor = BrushRing.color.withAlphaComponent(0.06).cgColor
        outer.strokeColor = BrushRing.color.cgColor
        outer.lineWidth = BrushRing.lineWidth
        outer.contentsScale = window?.backingScaleFactor ?? 2
        outer.isHidden = true

        inner.fillColor = nil
        inner.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        inner.lineWidth = BrushRing.innerLineWidth
        inner.contentsScale = window?.backingScaleFactor ?? 2
        inner.isHidden = true

        layer?.addSublayer(outer)
        layer?.addSublayer(inner)
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    /// The ring never owns a click: the loupe's hit test stays the only one.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Centre in **view points** (y down, the canvas' own space).
    public var ringCenter: CGPoint { storedCenter }

    /// Diameter in **view points**. Live when the controller can answer (so a value written by the
    /// card's slider is visible without waiting for a draw), otherwise the last `show(...)` value.
    public var ringDiameter: CGFloat {
        if let live = controller?.liveHealRingDiameterInPoints, live.isFinite, live > 0 {
            return CGFloat(live)
        }
        return storedDiameter
    }

    public var isRingVisible: Bool { !isHidden && ringDiameter > 0 }

    public func show(center: CGPoint, diameter: CGFloat) {
        guard center.x.isFinite, center.y.isFinite,
              diameter.isFinite, diameter > 0 else {
            hide()
            return
        }
        storedCenter = center
        storedDiameter = diameter
        isHidden = false
        updatePaths()
    }

    public func hide() {
        storedDiameter = 0
        isHidden = true
        outer.isHidden = true
        inner.isHidden = true
        outer.path = nil
        inner.path = nil
    }

    public override func layout() {
        super.layout()
        // The canvas is flipped, so the layers' geometry is too; the path below is written in the
        // same y-down coordinates `ringCenter` uses.
        layer?.isGeometryFlipped = isFlipped
        let scale = window?.backingScaleFactor ?? 2
        outer.contentsScale = scale
        inner.contentsScale = scale
        outer.frame = bounds
        inner.frame = bounds
        updatePaths()
    }

    private func updatePaths() {
        guard !isHidden, storedDiameter.isFinite, storedDiameter > 0 else { return }
        let radius = storedDiameter / 2
        let rect = CGRect(x: storedCenter.x - radius, y: storedCenter.y - radius,
                          width: storedDiameter, height: storedDiameter)
        outer.path = CGPath(ellipseIn: rect, transform: nil)
        outer.isHidden = false

        let innerRadius = max(0, radius - BrushRing.lineWidth)
        if innerRadius > BrushRing.innerLineWidth / 2 {
            let innerRect = CGRect(x: storedCenter.x - innerRadius,
                                   y: storedCenter.y - innerRadius,
                                   width: innerRadius * 2, height: innerRadius * 2)
            inner.path = CGPath(ellipseIn: innerRect, transform: nil)
            inner.isHidden = false
        } else {
            inner.path = nil
            inner.isHidden = true
        }
    }
}
