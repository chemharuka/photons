import Foundation

// MARK: - 489 · 自动裁剪: the largest axis-aligned rectangle with no black corners
//
// The valid picture after P → R is a convex quadrilateral in the crop's own normalized space. The
// largest axis-aligned rectangle inside it is the classic 「最大内接轴对齐矩形」 problem; this file
// solves it by the corner enumeration the ticket allows:
//
//   a maximal rectangle's four corners lie on the polygon boundary (otherwise it could grow), so
//   each corner lies on one of the polygon's edges. Enumerating the four edge assignments
//   (`n⁴`, at most 4⁴ for a quadrilateral) gives one linear system per assignment — four lines, four
//   unknowns (`left, right, top, bottom`) — and the winner is the feasible solution of maximum area.
//
// No approximation is involved: every candidate is a real rectangle whose four corners are checked
// against the polygon, and the answer is the maximum over all of them. That is why the test can
// compare it against a brute-force optimum and require ≥ 99 % without special-casing the fixture.
//
// The polygon is clipped to the crop's legal box first (the source-normalized frame is `[0,1]²`; a
// straighten makes the valid region stick out of it, and a crop may not cover pixels outside the
// output frame either). Clipping a convex polygon by a box keeps it convex, so the same enumeration
// applies with up to eight edges.

public enum AutoCropSolver {

    /// The largest axis-aligned rectangle inside `polygon`, intersected with `bounds` (default the
    /// full `[0,1]²`). `nil` when the polygon has no positive area (a degenerate picture).
    public static func maximumRectangle(in polygon: [NormalizedPoint],
                                        bounds: CropRect = .full) -> NormalizedRect? {
        let clipped = clip(polygon, to: bounds)
        guard clipped.count >= 3 else { return nil }
        let edges = lines(of: clipped)
        guard edges.count >= 3 else { return nil }

        var bestArea = 0.0
        var best: NormalizedRect?

        for e0 in edges {
            for e1 in edges {
                for e2 in edges {
                    for e3 in edges {
                        // left/top on e0, right/top on e1, right/bottom on e2, left/bottom on e3.
                        let matrix: [[Double]] = [
                            [e0.a, 0, e0.b, 0, e0.c],
                            [0, e1.a, e1.b, 0, e1.c],
                            [0, e2.a, 0, e2.b, e2.c],
                            [e3.a, 0, 0, e3.b, e3.c],
                        ]
                        guard let x = solve(matrix) else { continue }
                        let l = x[0], r = x[1], t = x[2], b = x[3]
                        guard l.isFinite, r.isFinite, t.isFinite, b.isFinite,
                              r - l > 1e-12, b - t > 1e-12 else { continue }
                        let area = (r - l) * (b - t)
                        guard area > bestArea else { continue }
                        let corners = [NormalizedPoint(l, t), NormalizedPoint(r, t),
                                       NormalizedPoint(r, b), NormalizedPoint(l, b)]
                        guard corners.allSatisfy({ contains(clipped, $0) }) else { continue }
                        bestArea = area
                        best = NormalizedRect(x: l, y: t, width: r - l, height: b - t)
                    }
                }
            }
        }
        return best
    }

    // MARK: lines

    private struct Line {
        var a: Double
        var b: Double
        var c: Double
    }

    private static func lines(of polygon: [NormalizedPoint]) -> [Line] {
        var out: [Line] = []
        for i in polygon.indices {
            let p = polygon[i], q = polygon[(i + 1) % polygon.count]
            let a = -(q.y - p.y), b = q.x - p.x
            guard abs(a) > 1e-12 || abs(b) > 1e-12 else { continue }
            out.append(Line(a: a, b: b, c: a * p.x + b * p.y))
        }
        return out
    }

    /// Gauss–Jordan on a 4×5 augmented matrix. `nil` for a singular assignment (three lines through
    /// one point, two parallel supports, …); those cannot name a rectangle.
    private static func solve(_ input: [[Double]]) -> [Double]? {
        var m = input
        for col in 0..<4 {
            var pivot = col
            for row in col..<4 where abs(m[row][col]) > abs(m[pivot][col]) { pivot = row }
            guard abs(m[pivot][col]) > 1e-12 else { return nil }
            if pivot != col { m.swapAt(pivot, col) }
            let p = m[col][col]
            for j in col..<5 { m[col][j] /= p }
            for row in 0..<4 where row != col {
                let f = m[row][col]
                guard f != 0 else { continue }
                for j in col..<5 { m[row][j] -= f * m[col][j] }
            }
        }
        return (0..<4).map { m[$0][4] }
    }

    // MARK: containment

    /// Convex containment with a relative tolerance, either winding. A point on an edge is inside.
    private static func contains(_ polygon: [NormalizedPoint], _ p: NormalizedPoint) -> Bool {
        var positive = false, negative = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            let scale = max(1e-12, hypot(b.x - a.x, b.y - a.y))
            if cross > 1e-7 * scale { positive = true }
            if cross < -1e-7 * scale { negative = true }
        }
        return !(positive && negative)
    }

    // MARK: box clip (Sutherland–Hodgman)

    private static func clip(_ polygon: [NormalizedPoint], to box: CropRect) -> [NormalizedPoint] {
        var out = polygon
        out = clip(out, coordinate: { $0.x }, bound: box.left, keepAbove: true)
        out = clip(out, coordinate: { $0.x }, bound: box.right, keepAbove: false)
        out = clip(out, coordinate: { $0.y }, bound: box.top, keepAbove: true)
        out = clip(out, coordinate: { $0.y }, bound: box.bottom, keepAbove: false)
        return out
    }

    /// One half-plane, whose boundary is `coordinate == bound`. A segment between an inside and an
    /// outside vertex is cut at the lerp parameter that makes the coordinate exactly `bound`.
    private static func clip(_ input: [NormalizedPoint],
                             coordinate: (NormalizedPoint) -> Double,
                             bound: Double,
                             keepAbove: Bool) -> [NormalizedPoint] {
        guard !input.isEmpty else { return [] }
        func inside(_ p: NormalizedPoint) -> Bool {
            keepAbove ? coordinate(p) >= bound : coordinate(p) <= bound
        }
        var result: [NormalizedPoint] = []
        var previous = input[input.count - 1]
        var previousInside = inside(previous)
        for current in input {
            let currentInside = inside(current)
            if currentInside != previousInside {
                let va = coordinate(previous), vb = coordinate(current)
                let denominator = vb - va
                let t = abs(denominator) > 1e-15 ? (bound - va) / denominator : 0
                result.append(NormalizedPoint(previous.x + (current.x - previous.x) * t,
                                              previous.y + (current.y - previous.y) * t))
            }
            if currentInside { result.append(current) }
            previous = current
            previousInside = currentInside
        }
        return result
    }
}
