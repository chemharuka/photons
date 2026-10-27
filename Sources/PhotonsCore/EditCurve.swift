import Foundation

/// 4096-entry lookup tables built from curve control points.
///
/// The curve is a UI construct (a few control points) but the kernel wants random access at pixel
/// rate, so the table is built once per parameter change on the CPU (deterministic double math) and
/// uploaded as a float buffer. Interpolation is monotone cubic (Fritsch–Carlson) so dragging a point
/// can never make the curve fold back on itself — a fold would invert tones and is the classic
/// spline artifact in tone curves.
///
/// ## 派单 030: the same tables, a different axis, four times the resolution
///
/// The y axis is no longer a display value but the **log-light coordinate** of `HDRCurveAxis`
/// (`u = log1p(x/x0)/K`). Nothing about the table changed shape: `buildOne` still samples a monotone
/// cubic in 0…1 and the identity table is still `i/(N−1)`, so `tablesAreIdentity` means exactly what
/// it meant before.
///
/// 4096 entries are the measured answer, not a round number: a 2 %-wide cliff (the narrowest gesture
/// the editor allows — 0.36 stop) has a worst-case error of 2.97 8-bit codes at N=1024, 0.74 at
/// N=2048 and **0.19 at N=4096**; 600 random legal curves peak at 0.24 codes at N=4096. The frame is
/// `rgba16Float`, whose relative step is 9.77e-4 (≈0.25 code at white), so at 4096 the table error is
/// below the storage it is written into — going higher buys nothing (docs/tasks/030 §6).
///
/// Four tables × 4096 × 4 B = 64 KB, one upload. `RenderGraph` keeps a **single** buffer and rewrites
/// only the slices whose points changed (§6.4), because a slider drag would otherwise allocate a
/// 64 KB buffer per frame.
public enum CurveLUT {
    public static let size = 4096

    /// Four tables back to back: W (luminance), then R, G, B.
    ///
    /// W is a luma **gain**, not a fourth per-channel table: the kernel applies it as one exposure
    /// offset to the pixel's luma, which preserves hue and saturation. The two operators differ by up
    /// to 137 8-bit codes on a saturated HDR pixel (§5.2), so the distinction is load-bearing.
    public static let tableCount = 4

    /// Build `tableCount * size` floats, each in 0…1.
    public static func build(_ group: CurveGroup) -> [Float] {
        var out = [Float](repeating: 0, count: tableCount * size)
        let tables = group.tables
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

    /// True when every table is the identity, so the kernel can take its copy branch.
    public static func tablesAreIdentity(_ tables: [Float]) -> Bool {
        guard tables.count == tableCount * size else { return false }
        // Slices, not copies: this runs once per curve change on a 64 KB buffer, but a drag asks the
        // question 60 times a second and four 16 KB copies per frame is a needless 4 MB/s.
        return (0..<tableCount).allSatisfy { isIdentityTable(tables[$0 * size..<($0 + 1) * size]) }
    }

    /// One table's identity test. Same 1e-5 tolerance `tablesAreIdentity` has always used: the
    /// comparison is against the *stored* `Float` of `i/(N−1)`, so the tolerance only has to absorb
    /// double→single rounding, not an approximation.
    public static func isIdentityTable(_ table: ArraySlice<Float>) -> Bool {
        guard table.count == size else { return false }
        var i = table.startIndex
        for k in 0..<size {
            if abs(table[i] - Float(k) / Float(size - 1)) > 1e-5 { return false }
            i += 1
        }
        return true
    }

    public static func isIdentityTable(_ table: [Float]) -> Bool { isIdentityTable(table[...]) }

    /// Rule 4's slopes: the last segment of each table, extrapolated to a per-unit-u slope.
    ///
    /// `(lut[N−1] − lut[N−2]) · (N−1)` — exactly 1 for the identity table, < 1 for a roll-off, 0 for
    /// a ceiling the user drew at the right end. The kernel clamps it into [0,1]; the value here is
    /// what goes into the uniform.
    public static func slopes(_ tables: [Float]) -> [Float] {
        guard tables.count == tableCount * size else {
            return [Float](repeating: 1, count: tableCount)
        }
        return (0..<tableCount).map { t in
            let end = (t + 1) * size - 1
            return (tables[end] - tables[end - 1]) * Float(size - 1)
        }
    }

    /// The same number for one table, so a partial rebuild does not have to concatenate to ask.
    public static func slope(of table: [Float]) -> Float {
        guard table.count >= 2 else { return 1 }
        return (table[table.count - 1] - table[table.count - 2]) * Float(table.count - 1)
    }

    /// The **black point** of each table — its first control point's x after `buildOne`'s own
    /// normalisation — in buffer order (W, R, G, B). 0 means "this curve starts at zero light".
    ///
    /// This is the one number the kernel cannot read out of the table (`061`). Rule 3 of
    /// `s1_7_hdr_curve.metal` passes `x ≤ 0` through with its sign (018's sub-black detail) — but that
    /// is only right while the curve still *starts* at `u = 0`. Once the first point sits at 0.2, the
    /// table's `0…0.2` segment is a constant: the black point has been raised, and a raised black point
    /// that spared the negatives would be a clip with a hole in it. So the kernel gets `first.x` per
    /// table and takes the pass-through branch only when it is 0. See `HDRCurve.channel`.
    ///
    /// `min` over the clamped xs, not `sorted().first` on the raw doubles: it is the same point
    /// `buildOne` starts from (it clamps then sorts), and an empty list answers 0 = no clip, which is
    /// the identity.
    public static func blackPoints(_ group: CurveGroup) -> [Float] {
        group.tables.map { points in
            let xs = points.map(\.u)
            return Float(xs.min() ?? 0)
        }
    }

    /// One table from control points: normalise, then Fritsch–Carlson, then **enforce** monotonicity.
    ///
    /// **The two ends are constants, not extrapolations (061).** A point list need not start at `x = 0`
    /// or end at `x = 1`: `x` left of the first point answers `first.y`, and `x` right of the last
    /// answers `last.y`. That is what makes a movable endpoint mean what the user expects — the first
    /// point's x **is** the black point (everything below it crushed to one output), the last point's
    /// x **is** the white point. Both references agree, from opposite ends of their pipelines:
    /// `RapidRAW src-tauri/src/shaders/shader.wgsl:438-441` (`if (x <= first.x) { return first.y / 255; }`
    /// / `if (x >= last.x) { return last.y / 255; }`) and `LightCraft crates/color/src/spline.rs:58-65`
    /// (`x <= xs[0] → ys[0]`, `x >= xs[n-1] → ys[n-1]`). A linear extrapolation would instead keep
    /// rising below the black point — i.e. invent detail the clip is there to remove.
    ///
    /// The identity is *inside* this rule, not a special case: `[(0,0), (1,1)]` has its first point at
    /// 0 and its last at 1, so there is no constant segment at all and the table is `i/(N−1)` to the
    /// last bit (`HDRCurveTests` and `CurvePanelTests` compare the arrays, not a tolerance).
    ///
    /// Layer 2 of §5.4: Fritsch–Carlson guarantees the *interpolant* is monotone between monotone
    /// data, but a user can still hand us y values that go down (the editor forbids it, documents do
    /// not). The tabulated `min(diff) > 0` check is the object-level promise the kernel relies on —
    /// a curve that folds is not "a bit wrong", it inverts tones — so a fold falls back to the
    /// identity, the same failure path `pts.count < 2` already takes.
    /// - Parameter n: table length. `CurveLUT.size` (4096) everywhere in the product; a test may ask
    ///   for 1024 or 65536 to measure what the resolution is worth (`HDRCurveTests`, 030 §6).
    public static func buildOne(_ rawPoints: [CurvePoint], size requested: Int? = nil) -> [Float] {
        let tableSize = max(2, requested ?? size)
        let identity = (0..<tableSize).map { Float($0) / Float(tableSize - 1) }
        // Sort by x and drop duplicate x. 069: the coordinates are grid cells, so "the same x" is
        // an integer equality rather than a tolerance, and the last point written at a cell wins
        // (the newest hand edit) exactly as the old 1e-6 window did.
        var pts = rawPoints.sorted { $0.x < $1.x }
        var deduped: [CurvePoint] = []
        for p in pts {
            if let last = deduped.last, last.x == p.x {
                deduped[deduped.count - 1] = p
            } else {
                deduped.append(p)
            }
        }
        pts = deduped

        guard pts.count >= 2 else { return identity }

        let n = pts.count
        let h = (0..<(n - 1)).map { pts[$0 + 1].u - pts[$0].u }
        guard h.allSatisfy({ $0 > 1e-9 }) else { return identity }
        let delta = (0..<(n - 1)).map { (pts[$0 + 1].v - pts[$0].v) / h[$0] }

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

        var out = [Float](repeating: 0, count: tableSize)
        var seg = 0
        for i in 0..<tableSize {
            let x = Double(i) / Double(tableSize - 1)
            if x <= pts[0].u {
                out[i] = Float(pts[0].v)
                continue
            }
            if x >= pts[n - 1].u {
                out[i] = Float(pts[n - 1].v)
                continue
            }
            while seg < n - 2 && x > pts[seg + 1].u { seg += 1 }
            let t = (x - pts[seg].u) / h[seg]
            let t2 = t * t
            let t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            // Split into two sums: one expression of six products is past what the type checker
            // will do in reasonable time.
            let a = h00 * pts[seg].v + h10 * h[seg] * m[seg]
            let b = h01 * pts[seg + 1].v + h11 * h[seg] * m[seg + 1]
            let y = a + b
            out[i] = Float(min(max(y, 0), 1))
        }

        // §5.4 layer 2: the table must not fold. Tolerance 0 — equal neighbours are monotone,
        // a single descending step is not.
        guard zip(out, out.dropFirst()).allSatisfy({ $1 >= $0 }) else { return identity }
        return out
    }
}
