import Foundation

/// **520 — the largest-area axis-aligned rectangle inside a convex polygon, exactly.**
///
/// 489's `AutoCropSolver` enumerates four supporting *edges* of the polygon and solves a 4×4 system
/// for the rectangle's four sides. That is complete for a rectangle whose every side is tangent to an
/// edge, but it has no assignment for an **axis-parallel** side: its `left` row is `[a, 0, b, 0, c]`,
/// which cannot name `left` when the supporting edge is horizontal (`a = 0`). Every keystone at 0° of
/// straighten produces such a side, so the solver answered `nil` there and the crop kept its black
/// corners. 505 patched the caller with `bandRectangle`, but a band is pinned to the hull's vertex
/// `y`s and to the narrowest chord across the whole band, so it is an *upper-ish* guess, not the
/// optimum.
///
/// This file is the exact solution, independent of the 505 band.
///
/// ## The lemma
///
/// Let `Q` be a convex polygon, `top(x)` its upper boundary (**concave**) and `bot(x)` its lower
/// boundary (**convex**). For an axis-aligned rectangle `R = [a, b] × [y1, y2]`,
///
///     R ⊆ Q  ⟺  y2 ≤ min(top(a), top(b))  and  y1 ≥ max(bot(a), bot(b)).
///
/// `R` is the convex hull of its four corners, so if the four corners are in `Q` then `R` is too;
/// `top` is concave, so its minimum over `[a, b]` is at an endpoint; `bot` is convex, so its maximum
/// is at an endpoint. (The corner test is still performed on every candidate as the last safety net.)
///
/// Therefore the height of the best rectangle with those vertical sides is
///
///     H(a, b) = min(top(a), top(b)) − max(bot(a), bot(b))
///
/// and the objective is `F(a, b) = (b − a) · H(a, b)`. **Area in either crop space is proportional to
/// `width · height`**: both canvas width and source width are constants, so maximizing normalized
/// `w·h` is maximizing pixels — do not "fix" this by comparing in another space.
///
/// ## Why enumerating the four min/max sources is exact
///
/// `top`/`bot` are piecewise linear, with kinks only at the hull's vertex x's. Split the x axis at
/// those kinks. On one pair of intervals `(a in I, b in J)` each of `top(a)`, `top(b)`, `bot(a)`,
/// `bot(b)` is one fixed line, so `H` is one of four affine functions
/// `top_source(x_source) − bot_source(x_source)`. On the region where that choice really is the
/// min/max, `F` equals one quadratic; away from it `F` is *smaller* than that quadratic (each factor
/// is an upper bound), so clipping the cell by the two validity half-planes
/// (`chosen top ≤ other top`, `chosen bottom ≥ other bottom`) gives a convex region on which the
/// quadratic **is** the objective. Its maximum is on the boundary — the quadratic is a saddle
/// (`det = −(q + r)² ≤ 0`) — so the four corners, the one-dimensional stationary point of every
/// region edge, and (belt and braces, per the ticket) the interior stationary point are all the
/// candidates there are. Taking the best over the four choices and all interval pairs is the global
/// optimum, not a heuristic.
public enum MaxInscribedRect {

    /// The largest-area axis-aligned rectangle inside `polygon`, intersected with `bounds`
    /// (default the whole legal `[0,1]²` frame). `nil` for a degenerate picture.
    ///
    /// The polygon is clipped to `bounds` first: a crop may not cover pixels outside the output frame
    /// either, and a convex polygon clipped by a box stays convex, so the lemma still holds.
    public static func maximumRectangle(in polygon: [NormalizedPoint],
                                        bounds: CropRect = .full) -> NormalizedRect? {
        let clipped = clip(polygon, to: bounds)
        guard clipped.count >= 3, abs(signedArea(clipped)) > 1e-12 else { return nil }

        let xs = breakpoints(clipped)
        guard xs.count >= 2 else { return nil }
        var slices: [Slice] = []
        slices.reserveCapacity(xs.count - 1)
        for i in 0..<(xs.count - 1) {
            guard xs[i + 1] - xs[i] > 1e-12 else { continue }
            if let slice = makeSlice(clipped, from: xs[i], to: xs[i + 1]) {
                slices.append(slice)
            }
        }
        guard !slices.isEmpty else { return nil }

        var bestArea = 0.0
        var best: NormalizedRect?
        for i in slices.indices {
            let a = slices[i]
            for j in slices.indices {
                let b = slices[j]
                // No b > a possible when J ends at or before I starts.
                guard b.x1 > a.x0 + 1e-12 else { continue }
                for topFromA in [true, false] {
                    for bottomFromA in [true, false] {
                        solve(a, b, topFromA: topFromA, bottomFromA: bottomFromA,
                              polygon: clipped, bestArea: &bestArea, best: &best)
                    }
                }
            }
        }
        return best
    }

    // MARK: - the pieces

    /// `y = slope·x + intercept` between two x-breakpoints.
    private struct Linear {
        var slope: Double
        var intercept: Double
    }

    /// One x-interval on which `top` and `bot` are single lines.
    private struct Slice {
        var x0: Double
        var x1: Double
        var top: Linear
        var bottom: Linear
    }

    /// A 2D point in `(a, b)` space (the rectangle's left and right edges).
    private struct Pair {
        var x: Double
        var y: Double
    }

    /// A half-plane `nx·a + ny·b + c ≥ 0`.
    private struct HalfPlane {
        var nx: Double
        var ny: Double
        var c: Double
        func value(_ p: Pair) -> Double { nx * p.x + ny * p.y + c }
    }

    // MARK: - interval structure

    private static func breakpoints(_ polygon: [NormalizedPoint]) -> [Double] {
        let sorted = polygon.map(\.x).sorted()
        var out: [Double] = []
        for x in sorted where out.last.map({ x - $0 > 1e-12 }) ?? true {
            out.append(x)
        }
        return out
    }

    /// The two boundary lines between `x0` and `x1`. The vertical line at the interval's midpoint
    /// crosses the convex polygon exactly twice; each crossing lies on one edge, whose slope is the
    /// line's slope. Midpoints never sit on a vertex x, so vertical edges cannot be chosen.
    private static func makeSlice(_ polygon: [NormalizedPoint], from x0: Double,
                                  to x1: Double) -> Slice? {
        let mid = (x0 + x1) / 2
        var crossings: [(y: Double, slope: Double)] = []
        for i in polygon.indices {
            let p = polygon[i], q = polygon[(i + 1) % polygon.count]
            let dx = q.x - p.x
            guard abs(dx) > 1e-15 else { continue }
            let low = min(p.x, q.x), high = max(p.x, q.x)
            guard mid >= low - 1e-12, mid <= high + 1e-12 else { continue }
            let t = (mid - p.x) / dx
            let y = p.y + (q.y - p.y) * t
            crossings.append((y, (q.y - p.y) / dx))
        }
        guard crossings.count >= 2 else { return nil }
        crossings.sort { $0.y < $1.y }
        let lower = crossings[0], upper = crossings[crossings.count - 1]
        guard upper.y - lower.y > 1e-12 else { return nil }
        return Slice(x0: x0, x1: x1,
                     top: Linear(slope: upper.slope,
                                 intercept: upper.y - upper.slope * mid),
                     bottom: Linear(slope: lower.slope,
                                    intercept: lower.y - lower.slope * mid))
    }

    // MARK: - one (interval pair × source choice)

    /// Clip the cell by the choice's validity half-planes, then collect every boundary/interior
    /// candidate of the quadratic and keep the best feasible one in the shared answer.
    private static func solve(_ a: Slice, _ b: Slice, topFromA: Bool, bottomFromA: Bool,
                              polygon: [NormalizedPoint], bestArea: inout Double,
                              best: inout NormalizedRect?) {
        // The chosen and rejected lines, as coefficients in (a, b): y = c0 + ca·a + cb·b.
        let (tc0, tca, tcb) = coefficients(topFromA ? a.top : b.top, onA: topFromA)
        let (oc0, oca, ocb) = coefficients(topFromA ? b.top : a.top, onA: !topFromA)
        let (bc0, bca, bcb) = coefficients(bottomFromA ? a.bottom : b.bottom, onA: bottomFromA)
        let (ob0, oba, obb) = coefficients(bottomFromA ? b.bottom : a.bottom, onA: !bottomFromA)

        // chosen top − other top ≤ 0, chosen bottom − other bottom ≥ 0, and b − a ≥ 0.
        let planes = [
            HalfPlane(nx: -(tca - oca), ny: -(tcb - ocb), c: -(tc0 - oc0)),
            HalfPlane(nx: bca - oba, ny: bcb - obb, c: bc0 - ob0),
            HalfPlane(nx: -1, ny: 1, c: 0),
        ]

        var region = [Pair(x: a.x0, y: b.x0), Pair(x: a.x1, y: b.x0),
                      Pair(x: a.x1, y: b.x1), Pair(x: a.x0, y: b.x1)]
        for plane in planes {
            region = clip(region, by: plane)
            if region.count < 2 { return }
        }

        // H = p + q·a + r·b; F = (b − a)(p + q·a + r·b).
        let p = tc0 - bc0
        let q = tca - bca
        let r = tcb - bcb

        var candidates = region
        for i in region.indices {
            let p0 = region[i], p1 = region[(i + 1) % region.count]
            let da = p1.x - p0.x, db = p1.y - p0.y
            // F(t) on the edge = (w0 + w1 t)(h0 + h1 t), t ∈ [0, 1].
            let w0 = p0.y - p0.x, w1 = db - da
            let h0 = p + q * p0.x + r * p0.y, h1 = q * da + r * db
            let quadratic = w1 * h1
            let linear = w0 * h1 + w1 * h0
            if abs(quadratic) > 1e-15 {
                let t = -linear / (2 * quadratic)
                if t > 0, t < 1 {
                    candidates.append(Pair(x: p0.x + da * t, y: p0.y + db * t))
                }
            }
        }

        // Interior stationary point of F: ∂F/∂a = −2q·a + (q−r)·b − p,
        // ∂F/∂b = (q−r)·a + 2r·b + p. `det = −(q + r)²`.
        let det = -(q + r) * (q + r)
        if abs(det) > 1e-14 {
            let m00 = -2 * q, m01 = q - r, m10 = q - r, m11 = 2 * r
            let sa = (p * m11 - m01 * -p) / det
            let sb = (m00 * -p - p * m10) / det
            let point = Pair(x: sa, y: sb)
            if planes.allSatisfy({ $0.value(point) >= -1e-9 }) { candidates.append(point) }
        }

        for point in candidates {
            let lo = min(point.x, point.y), hi = max(point.x, point.y)
            guard hi - lo > 1e-12,
                  planes.allSatisfy({ $0.value(point) >= -1e-9 }) else { continue }
            guard let measured = measure(left: lo, right: hi, polygon: polygon) else { continue }
            if measured.area > bestArea {
                bestArea = measured.area
                best = measured.rect
            }
        }
    }

    private static func coefficients(_ line: Linear, onA: Bool) -> (Double, Double, Double) {
        onA ? (line.intercept, line.slope, 0) : (line.intercept, 0, line.slope)
    }

    /// The true rectangle at `(left, right)`, measured with the polygon's own vertical chord and
    /// then checked corner by corner — the formula is an optimisation device, not the acceptance.
    private static func measure(left: Double, right: Double, polygon: [NormalizedPoint])
        -> (area: Double, rect: NormalizedRect)? {
        guard let ca = chord(polygon, at: left), let cb = chord(polygon, at: right) else { return nil }
        let bottom = max(ca.lo, cb.lo)
        let top = min(ca.hi, cb.hi)
        let height = top - bottom
        guard height > 1e-12 else { return nil }
        let corners = [NormalizedPoint(left, top), NormalizedPoint(right, top),
                       NormalizedPoint(right, bottom), NormalizedPoint(left, bottom)]
        guard corners.allSatisfy({ contains(polygon, $0) }) else { return nil }
        return ((right - left) * height,
                NormalizedRect(x: left, y: bottom, width: right - left, height: height))
    }

    // MARK: - geometry

    private static func chord(_ polygon: [NormalizedPoint], at x: Double)
        -> (lo: Double, hi: Double)? {
        var ys: [Double] = []
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if abs(b.x - a.x) < 1e-15 {
                if abs(x - a.x) <= 1e-12 { ys.append(a.y); ys.append(b.y) }
                continue
            }
            let t = (x - a.x) / (b.x - a.x)
            if t >= -1e-9, t <= 1 + 1e-9 { ys.append(a.y + (b.y - a.y) * t) }
        }
        guard let lo = ys.min(), let hi = ys.max() else { return nil }
        return (lo, hi)
    }

    private static func contains(_ polygon: [NormalizedPoint], _ point: NormalizedPoint) -> Bool {
        var positive = false, negative = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            let scale = max(1e-12, hypot(b.x - a.x, b.y - a.y))
            if cross > 1e-7 * scale { positive = true }
            if cross < -1e-7 * scale { negative = true }
        }
        return !(positive && negative)
    }

    private static func signedArea(_ polygon: [NormalizedPoint]) -> Double {
        var sum = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    // MARK: - clipping (Sutherland–Hodgman, both for the legal box and for the validity planes)

    private static func clip(_ polygon: [NormalizedPoint], to box: CropRect) -> [NormalizedPoint] {
        var out = polygon
        out = clip(out, coordinate: { $0.x }, bound: box.left, keepAbove: true)
        out = clip(out, coordinate: { $0.x }, bound: box.right, keepAbove: false)
        out = clip(out, coordinate: { $0.y }, bound: box.top, keepAbove: true)
        out = clip(out, coordinate: { $0.y }, bound: box.bottom, keepAbove: false)
        return out
    }

    private static func clip(_ input: [NormalizedPoint],
                             coordinate: (NormalizedPoint) -> Double,
                             bound: Double, keepAbove: Bool) -> [NormalizedPoint] {
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

    private static func clip(_ polygon: [Pair], by plane: HalfPlane) -> [Pair] {
        guard !polygon.isEmpty else { return [] }
        var result: [Pair] = []
        var previous = polygon[polygon.count - 1]
        var previousValue = plane.value(previous)
        for current in polygon {
            let currentValue = plane.value(current)
            let previousInside = previousValue >= -1e-12
            let currentInside = currentValue >= -1e-12
            if currentInside != previousInside {
                let denominator = previousValue - currentValue
                let t = abs(denominator) > 1e-15 ? previousValue / denominator : 0
                result.append(Pair(x: previous.x + (current.x - previous.x) * t,
                                   y: previous.y + (current.y - previous.y) * t))
            }
            if currentInside { result.append(current) }
            previous = current
            previousValue = currentValue
        }
        return result
    }
}
