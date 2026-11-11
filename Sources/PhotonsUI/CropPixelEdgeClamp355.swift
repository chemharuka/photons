import CoreGraphics
import Foundation
import PhotonsCore

// MARK: - 355/368 · 「不出像素」的**每 tick 夹取**：只夹被拖的那条边，夹在文档空间
//
// 317 的 `placedInsidePixels` 只能**平移**（310：拖动不改尺寸），所以它挡不住「把框拖大」——
// 框一旦比照片的四边形还大，任何平移都放不回去，`?? rect` 就把它原样留在外面。324 的内切
// (`inscribedInPhotoQuad`) 是**绕中心整体缩小**，那是「勾选时 / 改角度后」的一次性动作，把它挪到
// 每个 tick 就成了「夹一次、整框跳一下」。
//
// 这里补的是第三种：**只按被拖的那条边**。
//
// 前提只有一个，而且由 330 保证：透视文档的裁切框是**文档画布上的矩形**，所以在文档像素里它
// 轴对齐。照片的四边形是凸的，于是「被拖的边在哪」就是「把它从固定不动的对边朝手的方向拉开，
// 最多能拉多远还让四个角都在四边形里」：
//
//     把被拖的边按同一个比例 s 从对边拉开（s = 1 就是手的位置），
//     取最大的 s ≤ 1，使矩形的四个角都落在四边形内。
//
// **368 — 一个 tick 一次夹取。** 355 的写法是先在候选框的 y 跨度上采样四边形求右边的上限，再用
// 夹过的 x 求下边的上限：右边读到的是**候选框另一端**的当前位置，而那一端也在被拖，于是每个 tick
// 的合法上限都随手的到达位置改变，夹过的尺寸又喂回下一 tick —— 用户看到的「尺寸一直在跳变」。
// 现在每个被拖的边只读候选框和四边形，s 是手的连续函数（半平面约束的闭式解），同一个鼠标点逐位
// 可重现。反向门 `bothEnds` 保留 355 的旧采样，只给测试把这条验收弄红用。

/// The four edges of the frame, as a set — which of them a gesture moves.
public struct CropEdges: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let left = CropEdges(rawValue: 1 << 0)
    public static let right = CropEdges(rawValue: 1 << 1)
    public static let top = CropEdges(rawValue: 1 << 2)
    public static let bottom = CropEdges(rawValue: 1 << 3)
}

public extension CropGeometry {

    /// The photograph quad's `x` range on the horizontal line `y`, in document pixels.
    ///
    /// `nil` when the line misses the quad (then nothing can be pressed on that axis).
    func photoQuadSpan(atY y: Double) -> (min: Double, max: Double)? {
        let quad = photoQuad()
        guard quad.count >= 3 else { return nil }
        var xs: [Double] = []
        for index in quad.indices {
            let a = quad[index], b = quad[(index + 1) % quad.count]
            // A vertex on the line counts once; a crossing counts once.
            if abs(a.y - y) <= 1e-9 { xs.append(a.x); continue }
            if (a.y - y) * (b.y - y) < 0 {
                let t = (y - a.y) / (b.y - a.y)
                xs.append(a.x + (b.x - a.x) * t)
            }
        }
        guard let low = xs.min(), let high = xs.max(), high >= low else { return nil }
        return (low, high)
    }

    /// The photograph quad's `y` range on the vertical line `x`.
    func photoQuadSpan(atX x: Double) -> (min: Double, max: Double)? {
        let quad = photoQuad()
        guard quad.count >= 3 else { return nil }
        var ys: [Double] = []
        for index in quad.indices {
            let a = quad[index], b = quad[(index + 1) % quad.count]
            if abs(a.x - x) <= 1e-9 { ys.append(a.y); continue }
            if (a.x - x) * (b.x - x) < 0 {
                let t = (x - a.x) / (b.x - a.x)
                ys.append(a.y + (b.y - a.y) * t)
            }
        }
        guard let low = ys.min(), let high = ys.max(), high >= low else { return nil }
        return (low, high)
    }

    /// `rect` (canvas-normalized) with **each of `edges` pressed inside the photograph's quad**, the
    /// opposite edge and the other axis untouched. Only ever shrinks; idempotent.
    ///
    /// **368 — one edge, one reading.** The press is the largest scale `s ≤ 1` of the dragged edges
    /// about the **anchor** (the opposite corner/edge, which does not move) whose four corners are all
    /// inside the quad. It reads the candidate rect and the quad, never the candidate's *other* edge:
    /// 355's `scanLines(from:top,to:bottom)` re-sampled the quad every time that other edge moved, so
    /// the clamped width fed back into the next tick (the reported 「尺寸一直在跳变」).
    ///
    /// A convex quad contains an axis-aligned rectangle iff it contains its four corners, so the
    /// corner test is exact. The scale is found in closed form (one half-plane bound per corner and
    /// quad edge), which keeps it continuous in the hand's position and bit-for-bit repeatable.
    ///
    /// `minimumSpan` is the drag's own floor (in canvas-normalized units). It is already enforced
    /// before the press, and the press only ever shrinks: a legal limit always wins, so a floor is
    /// never used to push an edge back out of the quad.
    func pressedToPhotoQuad(_ rect: CropRect, edges: CropEdges,
                            minimumSpan: Double = 0.001,
                            bothEnds: Bool = false) -> CropRect {
        let e = photoQuadExtent
        return pressedToQuad(rect, edges: edges, quad: photoQuad(),
                             extent: DSize(width: e.width, height: e.height),
                             minimumSpan: minimumSpan, bothEnds: bothEnds)
    }

    /// **362 — the same press for a `.source` rect**, where the photograph is the **turned
    /// rectangle** (`CropMath.rotatedFrameCorners`, the quad `frameExceedsPicture` already judges by).
    /// 355 only pressed `.canvas` rects, so 「不出像素」 on a straightened-but-unwarped document did
    /// nothing at all: the 9°/v=0 group of the report's four geometries had 1210 of 1320 edge samples
    /// outside the photograph.
    func pressedToTurnedPhotoQuad(_ rect: CropRect, edges: CropEdges,
                                  minimumSpan: Double = 0.001,
                                  bothEnds: Bool = false) -> CropRect {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        let quad = CropMath.rotatedFrameCorners(in: source, degrees: rotationDegrees)
            .map { DocumentPoint($0.x * w, $0.y * h) }
        return pressedToQuad(rect, edges: edges, quad: quad,
                             extent: DSize(width: w, height: h),
                             minimumSpan: minimumSpan, bothEnds: bothEnds)
    }

    /// The one press: `quad` is the photograph's quad **in this rect's own pixel grid**, `extent` the
    /// size of `[0,1]²` on that grid. `bothEnds` is 368's reverse gate only: it re-runs 355's
    /// double-endpoint scan, which reads the moving other edge and therefore jumps.
    func pressedToQuad(_ rect: CropRect, edges: CropEdges, quad: [DocumentPoint],
                       extent: DSize, minimumSpan: Double = 0.001,
                       bothEnds: Bool = false) -> CropRect {
        if bothEnds {
            return pressedToQuadScanningBothEnds(rect, edges: edges, quad: quad,
                                                 extent: extent, minimumSpan: minimumSpan)
        }
        return pressedToQuadScalingFromAnchor(rect, edges: edges, quad: quad, extent: extent)
    }

    /// **368 — the one press.** Largest `s ∈ [0,1]` such that scaling the dragged edges about the
    /// fixed opposite edge keeps all four corners inside the convex `quad`. Dragged edge at `s = 1`
    /// is exactly the hand's candidate; a clamped edge stops on the quad, the opposite edge never
    /// moves, and no other edge is consulted.
    private func pressedToQuadScalingFromAnchor(_ rect: CropRect, edges: CropEdges,
                                                quad: [DocumentPoint],
                                                extent: DSize) -> CropRect {
        let c = rect.clamped(allowsOutsideSource: true)
        guard !edges.isEmpty, c.width > 0, c.height > 0, quad.count >= 3 else { return c }
        let w = max(extent.width, 1e-9), h = max(extent.height, 1e-9)

        // The fixed side of each axis, and how far the dragged side travels at s = 1.
        let rightMoves = edges.contains(.right), leftMoves = edges.contains(.left)
        let bottomMoves = edges.contains(.bottom), topMoves = edges.contains(.top)
        guard rightMoves || leftMoves || bottomMoves || topMoves else { return c }

        var left0 = c.left, dLeft = 0.0
        var right0 = c.right, dRight = 0.0
        if rightMoves, !leftMoves { right0 = c.left; dRight = c.width }
        if leftMoves, !rightMoves { left0 = c.right; dLeft = -c.width }
        var top0 = c.top, dTop = 0.0
        var bottom0 = c.bottom, dBottom = 0.0
        if bottomMoves, !topMoves { bottom0 = c.top; dBottom = c.height }
        if topMoves, !bottomMoves { top0 = c.bottom; dTop = -c.height }

        let corners: [(x0: Double, dx: Double, y0: Double, dy: Double)] = [
            (left0, dLeft, top0, dTop),
            (right0, dRight, top0, dTop),
            (right0, dRight, bottom0, dBottom),
            (left0, dLeft, bottom0, dBottom),
        ]
        let centre = quad.reduce(into: (x: 0.0, y: 0.0)) { $0.x += $1.x; $0.y += $1.y }
        let cx = centre.x / Double(quad.count), cy = centre.y / Double(quad.count)

        // `n·(p − a) >= -tol` for every edge, with `n` pointing into the convex quad.
        var cap = 1.0
        for index in quad.indices {
            let a = quad[index], b = quad[(index + 1) % quad.count]
            var nx = b.y - a.y, ny = -(b.x - a.x)
            let length = (nx * nx + ny * ny).squareRoot()
            guard length > 1e-12 else { continue }
            nx /= length; ny /= length
            if nx * (cx - a.x) + ny * (cy - a.y) < 0 { nx = -nx; ny = -ny }
            for corner in corners {
                let px = corner.x0 * w, py = corner.y0 * h
                let dx = corner.dx * w, dy = corner.dy * h
                let base = nx * (px - a.x) + ny * (py - a.y)
                let slope = nx * dx + ny * dy
                // Moving outward: the largest s still inside this half-plane.
                if slope < 0 {
                    cap = min(cap, (base + 1e-9) / -slope)
                }
            }
        }
        guard cap.isFinite else { return c }
        let s = min(max(cap, 0), 1)
        guard s < 1 else { return c }
        guard s > 0 else { return c }        // the anchor itself is outside: nothing to scale from
        return CropRect(left: min(left0 + dLeft * s, right0 + dRight * s),
                        top: min(top0 + dTop * s, bottom0 + dBottom * s),
                        right: max(left0 + dLeft * s, right0 + dRight * s),
                        bottom: max(top0 + dTop * s, bottom0 + dBottom * s))
            .clamped(allowsOutsideSource: true)
    }

    /// 355's original press, kept **only** as 368's reverse gate (`bothEnds: true`).
    private func pressedToQuadScanningBothEnds(_ rect: CropRect, edges: CropEdges,
                                               quad: [DocumentPoint],
                                               extent: DSize,
                                               minimumSpan: Double = 0.001) -> CropRect {
        let c = rect.clamped(allowsOutsideSource: true)
        guard !edges.isEmpty, c.width > 0, c.height > 0, quad.count >= 3 else { return c }
        let w = max(extent.width, 1e-9), h = max(extent.height, 1e-9)
        var left = c.left * w, right = c.right * w
        var top = c.top * h, bottom = c.bottom * h
        let spanX = min(max(minimumSpan, 0), 1) * w
        let spanY = min(max(minimumSpan, 0), 1) * h
        let quadXs = quad.map(\.x), quadYs = quad.map(\.y)

        // 1 — x. The band the frame covers in y decides which horizontal lines are asked.
        if edges.contains(.right) || edges.contains(.left) {
            var caps: [Double] = []
            var floors: [Double] = []
            for y in Self.scanLines(from: top, to: bottom, in: quadYs) {
                guard let span = Self.span(of: quad, atY: y) else { continue }
                caps.append(span.max)
                floors.append(span.min)
            }
            if edges.contains(.right), let cap = caps.min() { right = min(right, cap) }
            if edges.contains(.left), let floor = floors.max() { left = max(left, floor) }
            if right - left < spanX {
                right = max(right, min(left + spanX, caps.min() ?? right))
            }
        }

        // 2 — y, on the x the step above settled (固定顺序：先 x 后 y).
        if edges.contains(.bottom) || edges.contains(.top) {
            var caps: [Double] = []
            var floors: [Double] = []
            for x in Self.scanLines(from: left, to: right, in: quadXs) {
                guard let span = Self.span(of: quad, atX: x) else { continue }
                caps.append(span.max)
                floors.append(span.min)
            }
            if edges.contains(.bottom), let cap = caps.min() { bottom = min(bottom, cap) }
            if edges.contains(.top), let floor = floors.max() { top = max(top, floor) }
            if bottom - top < spanY {
                bottom = max(bottom, min(top + spanY, caps.min() ?? bottom))
            }
        }

        return CropRect(left: left / w, top: top / h, right: right / w, bottom: bottom / h)
            .clamped(allowsOutsideSource: true)
    }

    /// The quad's `x` range on the horizontal line `y`, for **any** quad (`photoQuadSpan(atY:)` is
    /// this for the photograph's own). `nil` when the line misses the quad.
    static func span(of quad: [DocumentPoint], atY y: Double) -> (min: Double, max: Double)? {
        guard quad.count >= 3 else { return nil }
        var xs: [Double] = []
        for index in quad.indices {
            let a = quad[index], b = quad[(index + 1) % quad.count]
            if abs(a.y - y) <= 1e-9 { xs.append(a.x); continue }
            if (a.y - y) * (b.y - y) < 0 {
                let t = (y - a.y) / (b.y - a.y)
                xs.append(a.x + (b.x - a.x) * t)
            }
        }
        guard let low = xs.min(), let high = xs.max(), high >= low else { return nil }
        return (low, high)
    }

    /// The quad's `y` range on the vertical line `x`.
    static func span(of quad: [DocumentPoint], atX x: Double) -> (min: Double, max: Double)? {
        guard quad.count >= 3 else { return nil }
        var ys: [Double] = []
        for index in quad.indices {
            let a = quad[index], b = quad[(index + 1) % quad.count]
            if abs(a.x - x) <= 1e-9 { ys.append(a.y); continue }
            if (a.x - x) * (b.x - x) < 0 {
                let t = (x - a.x) / (b.x - a.x)
                ys.append(a.y + (b.y - a.y) * t)
            }
        }
        guard let low = ys.min(), let high = ys.max(), high >= low else { return nil }
        return (low, high)
    }

    /// The scan lines of the rule: the two ends of the span, plus every quad vertex strictly inside
    /// it (the completeness note in the header).
    private static func scanLines(from low: Double, to high: Double, in vertices: [Double]) -> [Double] {
        var lines = [low, high]
        for v in vertices where v > low + 1e-9 && v < high - 1e-9 {
            lines.append(v)
        }
        return lines
    }
}
