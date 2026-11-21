import CoreGraphics
import Foundation

// MARK: - 489 · the crop frame's hit decision, in one place
//
// The frame's controls have to be forgiving: 「裁剪框的四角四边的控制区扩大，鼠标操作容错度更高，
// 现在稍微间隔几个px就变成重新划定裁剪框了」. The drawn bracket/bar is small, so the **hit** area is
// the visual one doubled, capped at a quarter of the frame's short side so a tiny frame still has an
// interior to move by.
//
// Three answers, in this order and no other:
//
//   1. a **grip** (corner before edge at equal distance) → drag that grip;
//   2. otherwise the frame's **interior** → move the picture;
//   3. otherwise **outside** → draw a new frame.
//
// `CropTool.hit` is the old spelling of the same function; it now delegates here, and
// `LoupeController.beginCropDrag` asks this first so a guide line under a grip cannot steal the
// press. The pure rect form (`box:`) is what the acceptance measures; the quad form (`in:`) is what
// the canvas calls, so a straightened frame's grips stay on its own edges.

public enum CropHitTester {

    /// The visual sizes the drawn controls read as. The hit radius is twice these (see
    /// `expandedRadius`), which is what turns "a few px off" into a grip drag instead of a new frame.
    public static let cornerVisualRadius = CropTool.cornerHitRadiusPoints
    public static let edgeVisualRadius = CropTool.edgeHitRadiusPoints

    /// `visual × 2`, never more than `min(box.width, box.height) × 0.25`.
    public static func expandedRadius(visual: Double, box: CGSize) -> Double {
        let short = max(min(Double(box.width), Double(box.height)), 0)
        return min(visual * 2, short * 0.25)
    }

    /// The axis-aligned form: a frame given by its box, in view points (`zoom` is the camera scale
    /// the box was measured at — the radii are screen points, so it only guards a zero).
    public static func hit(at point: CGPoint, box: CGRect, zoom: Double = 1) -> CropToolHandle {
        _ = zoom > 0 ? zoom : 1
        let corner = expandedRadius(visual: cornerVisualRadius, box: box.size)
        let edge = expandedRadius(visual: edgeVisualRadius, box: box.size)

        let corners: [(CropToolHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: box.minX, y: box.minY)),
            (.topRight, CGPoint(x: box.maxX, y: box.minY)),
            (.bottomRight, CGPoint(x: box.maxX, y: box.maxY)),
            (.bottomLeft, CGPoint(x: box.minX, y: box.maxY)),
        ]
        if let best = nearest(point: point, candidates: corners, radius: corner) { return best }

        let edges: [(CropToolHandle, CGPoint)] = [
            (.top, CGPoint(x: box.midX, y: box.minY)),
            (.right, CGPoint(x: box.maxX, y: box.midY)),
            (.bottom, CGPoint(x: box.midX, y: box.maxY)),
            (.left, CGPoint(x: box.minX, y: box.midY)),
        ]
        if let best = nearest(point: point, candidates: edges, radius: edge) { return best }

        return box.contains(point) ? .inside : .outside
    }

    /// The canvas form. The grips are already projected (`CropToolLayout`), so this only widens their
    /// radii and keeps the same corner-before-edge priority as `CropTool.hit` always had.
    public static func hit(at point: CGPoint, in layout: CropToolLayout,
                           zoom: Double = 1) -> CropToolHandle {
        _ = zoom > 0 ? zoom : 1
        let size = layout.sizeInPoints
        let corner = expandedRadius(visual: cornerVisualRadius, box: size)
        let edge = expandedRadius(visual: edgeVisualRadius, box: size)

        var best: (kind: CropToolHandle, distance: Double)?
        for grip in layout.grips {
            let distance = hypot(Double(point.x - grip.point.x),
                                 Double(point.y - grip.point.y))
            let radius = grip.kind.isCorner ? corner : edge
            guard distance <= radius else { continue }
            if let current = best {
                if current.kind.isCorner && !grip.kind.isCorner { continue }
                if current.kind.isCorner == grip.kind.isCorner, current.distance <= distance { continue }
            }
            best = (grip.kind, distance)
        }
        if let best { return best.kind }
        return CropTool.contains(point, in: layout) ? .inside : .outside
    }

    private static func nearest(point: CGPoint,
                                candidates: [(CropToolHandle, CGPoint)],
                                radius: Double) -> CropToolHandle? {
        var best: (kind: CropToolHandle, distance: Double)?
        for (kind, centre) in candidates {
            let distance = hypot(Double(point.x - centre.x), Double(point.y - centre.y))
            guard distance <= radius else { continue }
            if let current = best, current.distance <= distance { continue }
            best = (kind, distance)
        }
        return best?.kind
    }
}
