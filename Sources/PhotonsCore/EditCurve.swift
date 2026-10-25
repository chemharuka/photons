import Foundation

/// 1024-entry lookup tables built from tone-curve control points.
///
/// The curve is a UI construct (a few control points) but the kernel wants random access at pixel
/// rate, so the table is built once per parameter change on the CPU (deterministic double math) and
/// uploaded as a float buffer. Interpolation is monotone cubic (Fritsch–Carlson) so dragging a point
/// can never make the curve fold back on itself — a fold would invert tones and is the classic
/// spline artifact in tone curves.
public enum CurveLUT {
    public static let size = 1024

    /// Four tables back to back: composite RGB, then R, G, B.
    public static let tableCount = 4

    /// Build `tableCount * size` floats, each in 0…1.
    public static func build(_ group: CurveGroup) -> [Float] {
        var out = [Float](repeating: 0, count: tableCount * size)
        let tables = [group.rgb, group.red, group.green, group.blue]
        for (t, points) in tables.enumerated() {
            let table = buildOne(points)
            for i in 0..<size { out[t * size + i] = table[i] }
        }
        return out
    }

    /// Identity table: `v == x` at every sample.
    public static func identityTable() -> [Float] {
        (0..<size).map { Float($0) / Float(size - 1) }
    }

    public static func isIdentity(_ group: CurveGroup) -> Bool {
        group.isIdentity
    }

    /// True when all four tables are the identity, so the kernel can skip the pass entirely.
    public static func tablesAreIdentity(_ tables: [Float]) -> Bool {
        guard tables.count == tableCount * size else { return false }
        for t in 0..<tableCount {
            for i in 0..<size {
                let expected = Float(i) / Float(size - 1)
                if abs(tables[t * size + i] - expected) > 1e-5 { return false }
            }
        }
        return true
    }

    public static func buildOne(_ rawPoints: [CurvePoint]) -> [Float] {
        // Normalize: clamp into the unit square, sort by x, drop duplicate x.
        var pts = rawPoints
            .map { CurvePoint(min(max($0.x, 0), 1), min(max($0.y, 0), 1)) }
            .sorted { $0.x < $1.x }
        var deduped: [CurvePoint] = []
        for p in pts {
            if let last = deduped.last, abs(last.x - p.x) < 1e-6 {
                deduped[deduped.count - 1] = p
            } else {
                deduped.append(p)
            }
        }
        pts = deduped

        let identity = (0..<size).map { Float($0) / Float(size - 1) }
        guard pts.count >= 2 else { return identity }

        let n = pts.count
        let h = (0..<(n - 1)).map { pts[$0 + 1].x - pts[$0].x }
        guard h.allSatisfy({ $0 > 1e-9 }) else { return identity }
        let delta = (0..<(n - 1)).map { (pts[$0 + 1].y - pts[$0].y) / h[$0] }

        // Fritsch–Carlson tangents.
        var m = [Double](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        for i in 1..<(n - 1) {
            m[i] = delta[i - 1] * delta[i] <= 0 ? 0 : (delta[i - 1] + delta[i]) / 2
        }
        for i in 0..<(n - 1) where abs(delta[i]) < 1e-12 {
            m[i] = 0
            m[i + 1] = 0
        }
        for i in 0..<(n - 1) {
            let d = delta[i]
            guard abs(d) > 1e-12 else { continue }
            let a = m[i] / d
            let b = m[i + 1] / d
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * d
                m[i + 1] = t * b * d
            }
        }

        var out = [Float](repeating: 0, count: size)
        var seg = 0
        for i in 0..<size {
            let x = Double(i) / Double(size - 1)
            if x <= pts[0].x {
                out[i] = Float(pts[0].y)
                continue
            }
            if x >= pts[n - 1].x {
                out[i] = Float(pts[n - 1].y)
                continue
            }
            while seg < n - 2 && x > pts[seg + 1].x { seg += 1 }
            let t = (x - pts[seg].x) / h[seg]
            let t2 = t * t
            let t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            let y = h00 * pts[seg].y + h10 * h[seg] * m[seg]
                + h01 * pts[seg + 1].y + h11 * h[seg] * m[seg + 1]
            out[i] = Float(min(max(y, 0), 1))
        }
        return out
    }
}
