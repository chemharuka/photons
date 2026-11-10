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
//     exactly this: two 20 pt arms per corner, `CropView.CropInsideOverlay.swift:63-106`). 132: when
//     the frame covers pixels outside the photograph (`layout.exceedsPicture`) the stroke and the
//     grips are drawn **red** as a warning; the view still draws the same geometry at the same place
//     — colour is the whole difference, and it never writes the document.
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

    /// 328 — the 画线拉直 stroke, in view points, and its opacity. Drawn **after** the frame and the
    /// grips so the line the hand is pulling is the brightest thing on the canvas; `nil` and `0` are
    /// both 「nothing to draw」.
    var straightenStroke: CropToolSegment? {
        didSet { if oldValue != straightenStroke { needsDisplay = true } }
    }

    var straightenStrokeAlpha: Double = 1 {
        didSet { if oldValue != straightenStrokeAlpha { needsDisplay = true } }
    }

    /// 337 — the 引导线 lines, in view points: every line of the accepted fit (drawn dimly so the
    /// user can see what the numbers are standing on), the stroke under the hand / its 0.3 s flash,
    /// and the one the fit refused (red).
    var guideLines: [CropToolSegment] = [] {
        didSet { if oldValue != guideLines { needsDisplay = true } }
    }

    var guideLineStroke: CropToolSegment? {
        didSet { if oldValue != guideLineStroke { needsDisplay = true } }
    }

    var guideLineStrokeAlpha: Double = 1 {
        didSet { if oldValue != guideLineStrokeAlpha { needsDisplay = true } }
    }

    var rejectedGuideLine: CropToolSegment? {
        didSet { if oldValue != rejectedGuideLine { needsDisplay = true } }
    }

    var rejectedGuideLineAlpha: Double = 1 {
        didSet { if oldValue != rejectedGuideLineAlpha { needsDisplay = true } }
    }

    /// 337 — the accepted lines' standing opacity: dim enough that the picture still shows through,
    /// bright enough to read against both a sky and a shadow.
    static let appliedGuideLineAlpha: Double = 0.55

    /// §2's two numbers, re-exported so the acceptance can name what is drawn: 1.5 pt white,
    /// 1 px black shadow.
    static let straightenLineWidth = CropStraightenLinePainter.lineWidth
    static let straightenShadowWidth = CropStraightenLinePainter.shadowWidth

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    /// Never a hit target — the canvas owns every click, and the grips are hit-tested there.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let bracketArm: CGFloat = 18
    private static let bracketWidth: CGFloat = 2.5
    /// The bar on an edge grip: 22 pt long, centred on the edge's midpoint. Internal so 312 can
    /// measure the drawn length from a test.
    static let edgeBarLength: CGFloat = 22

    override func draw(_ dirtyRect: NSRect) {
        // 328 — the drawn line is drawn even when the frame has no layout yet (a press on the very
        // first frame of a mode change); `defer` keeps it out of every early return below.
        defer {
            if let stroke = straightenStroke {
                CropStraightenLinePainter.draw(stroke, alpha: straightenStrokeAlpha)
            }
            // 337 — the accepted guide lines under the live stroke, the refused one in red: the same
            // painter (1.5 pt white over 1 px black) so the two tools' strokes look like one tool.
            for line in guideLines {
                CropStraightenLinePainter.draw(line, alpha: Self.appliedGuideLineAlpha)
            }
            if let rejected = rejectedGuideLine {
                CropStraightenLinePainter.draw(rejected, alpha: rejectedGuideLineAlpha,
                                               colour: .systemRed)
            }
            if let stroke = guideLineStroke {
                CropStraightenLinePainter.draw(stroke, alpha: guideLineStrokeAlpha)
            }
        }
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

        // 3. The frame itself. 132: red when the crop covers pixels outside the photograph.
        let frame = quad(layout.corners)
        frame.lineWidth = 1.5
        Self.frameColour(alert: layout.exceedsPicture).setStroke()
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

    /// The frame's stroke colour: white, or **red** for a frame that leaves the picture (132). The
    /// active grip keeps the accent colour so "the hand is on this one" stays readable.
    static func frameColour(alert: Bool, active: Bool = false) -> NSColor {
        if alert { return active ? .systemRed.blended(withFraction: 0.35, of: .white) ?? .systemRed
                                 : .systemRed }
        return active ? NSColor.controlAccentColor : NSColor.white
    }

    private func draw(grip: CropToolLayout.Grip, in layout: CropToolLayout) {
        let active = grip.kind == self.active
        let colour = Self.frameColour(alert: layout.exceedsPicture, active: active)
        let p = grip.point
        let w = Self.bracketWidth
        let arm = Self.bracketArm

        if grip.kind.isCorner {
            // Two arms pointing **in** along the frame's own edges, so the bracket sits on the
            // picture rather than in the dimmed margin.
            let corner = Self.cornerIndex(grip.kind)
            let along = Self.unit(from: p, to: layout.corners[(corner + 1) % 4])
            let down = Self.unit(from: p, to: layout.corners[(corner + 3) % 4])
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

        // An edge grip: a short bar lying along the edge it moves, centred on its midpoint. 312: the
        // bar's geometry is one pure function — the same value this path strokes and the test asserts.
        let bar = Self.edgeBarGeometry(for: grip.kind, in: layout)
        let path = NSBezierPath()
        path.lineWidth = w + 1
        path.lineCapStyle = .round
        path.move(to: bar.start)
        path.line(to: bar.end)
        colour.setStroke()
        path.stroke()
    }

    // MARK: - the edge bar's geometry (312)

    /// An edge grip's bar: centre, direction and length, in view points. Pure data — `draw` strokes
    /// `start…end` and the test measures the very same value, so there is no second arithmetic that
    /// could happen to agree.
    struct EdgeBar: Equatable {
        var centre: CGPoint
        /// Unit vector along the side the bar rides.
        var along: CGPoint
        var length: CGFloat
        var start: CGPoint {
            CGPoint(x: centre.x - along.x * length / 2, y: centre.y - along.y * length / 2)
        }
        var end: CGPoint {
            CGPoint(x: centre.x + along.x * length / 2, y: centre.y + along.y * length / 2)
        }
    }

    /// The bar of an edge grip, read off the frame's own corners.
    ///
    /// The direction used to be a constant — `(.top, .bottom) → (1,0)`, `(.left, .right) → (0,1)` —
    /// which is right only for an upright frame. A straighten turns the quad (088), so a bar on a
    /// constant axis stops being parallel to its own side: that is what the user saw
    /// (「裁剪框在旋转时，四边中心的拖动指示条不会跟着旋转」). The corner brackets already read their
    /// direction from `layout.corners`; the edge bars now do the same, from the same four points.
    ///
    /// The old constants survive only as the **degenerate fallback**: when a side's two corners
    /// coincide there is no direction to read, and a path must never receive a NaN.
    static func edgeBarGeometry(for kind: CropToolHandle, in layout: CropToolLayout) -> EdgeBar {
        let centre = layout.grips.first(where: { $0.kind == kind })?.point
            ?? sideMidpoint(kind, in: layout) ?? .zero
        return EdgeBar(centre: centre, along: edgeDirection(kind, in: layout), length: edgeBarLength)
    }

    /// The corner pair that is `kind`'s side, in `CropToolLayout.corners` order
    /// (top-left, top-right, bottom-right, bottom-left).
    static func sideCorners(_ kind: CropToolHandle) -> (from: Int, to: Int)? {
        switch kind {
        case .top: return (0, 1)
        case .right: return (1, 2)
        case .bottom: return (3, 2)
        case .left: return (0, 3)
        default: return nil
        }
    }

    static func sideMidpoint(_ kind: CropToolHandle, in layout: CropToolLayout) -> CGPoint? {
        guard layout.corners.count == 4, let pair = sideCorners(kind) else { return nil }
        let a = layout.corners[pair.from], b = layout.corners[pair.to]
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// The unit direction of `kind`'s side: the same corner-to-corner vector the brackets use. At 0°
    /// this is exactly the old constant (the projection puts both corners on one axis), and when the
    /// side collapses it falls back to that constant rather than dividing by zero.
    static func edgeDirection(_ kind: CropToolHandle, in layout: CropToolLayout) -> CGPoint {
        let fallback: CGPoint = (kind == .left || kind == .right)
            ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0)
        guard layout.corners.count == 4, let pair = sideCorners(kind) else { return fallback }
        return unit(from: layout.corners[pair.from], to: layout.corners[pair.to], fallback: fallback)
    }

    private static func cornerIndex(_ kind: CropToolHandle) -> Int {
        switch kind {
        case .topLeft: return 0
        case .topRight: return 1
        case .bottomRight: return 2
        default: return 3
        }
    }

    private static func unit(from a: CGPoint, to b: CGPoint,
                             fallback: CGPoint = CGPoint(x: 1, y: 0)) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-6 else { return fallback }
        return CGPoint(x: dx / length, y: dy / length)
    }
}
