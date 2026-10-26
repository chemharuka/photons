import AppKit
import PhotonsCore

// MARK: - the crop frame, drawn
//
// The canvas half of 035. The *positions* are not computed here — `CropTool.layout` does that from
// the draft rect and the one projection (`LoupeMapping`), so what is drawn and what is grabbable
// cannot drift apart, and a portrait file needs no special case here.
//
// Three things are on screen, and each has a job:
//
//   · the **dimmed outside** — the part of the picture the current frame would throw away. Drawn as
//     the whole canvas minus the quad in one even-odd path, so a straightened (rotated) frame dims
//     correctly; Brightroom does the same with a mask view cut to the guide
//     (`CropView._InteractiveCropGuideView.swift:973-1009`).
//   · the **frame + eight grips** — corner brackets, the shape every crop tool draws, because a
//     bracket reads as "this corner" while a dot reads as "a point" (Brightroom's corner overlay is
//     exactly this: two 20 pt arms per corner, `CropView.CropInsideOverlay.swift:63-106`).
//   · the **rule-of-thirds grid**, which turns with the frame because the frame turns with the
//     picture.
//
// The view is `hitTest → nil`: the canvas owns every click and hit-tests the grips itself, exactly
// like `MaskHandlesOverlayView` and like Brightroom's guide container
// (`CropView._InteractiveCropGuideView.swift:322-335`).

final class CropToolOverlayView: NSView {

    /// The frame in view points, from `CropTool.layout`.
    var layout: CropToolLayout? {
        didSet { if oldValue != layout { needsDisplay = true } }
    }

    /// The grip under the hand, drawn in the accent colour.
    var active: CropToolHandle? {
        didSet { if oldValue != active { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    /// Never a hit target — the canvas owns every click, and the grips are hit-tested there.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let bracketArm: CGFloat = 18
    private static let bracketWidth: CGFloat = 2.5
    private static let edgeBarLength: CGFloat = 22

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, layout.corners.count == 4, bounds.width > 1, bounds.height > 1 else {
            return
        }
        _ = dirtyRect

        // 1. Everything outside the frame, dimmed.
        let outside = NSBezierPath(rect: bounds)
        outside.append(quad(layout.corners))
        outside.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.52).setFill()
        outside.fill()

        // 2. The grid, under the frame.
        let grid = NSBezierPath()
        grid.lineWidth = 1
        NSColor.white.withAlphaComponent(0.35).setStroke()
        for line in layout.grid {
            grid.move(to: line.a)
            grid.line(to: line.b)
        }
        grid.stroke()

        // 3. The frame itself.
        let frame = quad(layout.corners)
        frame.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.9).setStroke()
        frame.stroke()

        // 4. The grips.
        for grip in layout.grips {
            draw(grip: grip, in: layout)
        }
    }

    private func quad(_ corners: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: corners[0])
        for p in corners.dropFirst() { path.line(to: p) }
        path.close()
        return path
    }

    private func draw(grip: CropToolLayout.Grip, in layout: CropToolLayout) {
        let active = grip.kind == self.active
        let colour = active ? NSColor.controlAccentColor : NSColor.white
        let p = grip.point
        let w = Self.bracketWidth
        let arm = Self.bracketArm

        if grip.kind.isCorner {
            // Two arms pointing **in** along the frame's own edges, so the bracket sits on the
            // picture rather than in the dimmed margin.
            let corner = cornerIndex(grip.kind)
            let along = unit(from: p, to: layout.corners[(corner + 1) % 4])
            let down = unit(from: p, to: layout.corners[(corner + 3) % 4])
            let path = NSBezierPath()
            path.lineWidth = w
            path.lineCapStyle = .square
            path.move(to: p)
            path.line(to: CGPoint(x: p.x + along.x * arm, y: p.y + along.y * arm))
            path.move(to: p)
            path.line(to: CGPoint(x: p.x + down.x * arm, y: p.y + down.y * arm))
            colour.setStroke()
            path.stroke()
            return
        }

        // An edge grip: a short bar lying along the edge it moves, centred on its midpoint.
        let half = Self.edgeBarLength / 2
        let along: CGPoint
        switch grip.kind {
        case .top, .bottom: along = CGPoint(x: 1, y: 0)
        case .left, .right: along = CGPoint(x: 0, y: 1)
        default: along = CGPoint(x: 1, y: 0)
        }
        let path = NSBezierPath()
        path.lineWidth = w + 1
        path.lineCapStyle = .round
        path.move(to: CGPoint(x: p.x - along.x * half, y: p.y - along.y * half))
        path.line(to: CGPoint(x: p.x + along.x * half, y: p.y + along.y * half))
        colour.setStroke()
        path.stroke()
    }

    private func cornerIndex(_ kind: CropToolHandle) -> Int {
        switch kind {
        case .topLeft: return 0
        case .topRight: return 1
        case .bottomRight: return 2
        default: return 3
        }
    }

    private func unit(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-6 else { return CGPoint(x: 1, y: 0) }
        return CGPoint(x: dx / length, y: dy / length)
    }
}
