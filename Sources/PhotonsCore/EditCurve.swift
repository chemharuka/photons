import Foundation

/// 4096-entry lookup tables built from curve control points.
///
/// The curve is a UI construct (a few control points) but the kernel wants random access at pixel
/// rate, so the table is built once per parameter change on the CPU (deterministic double math) and
/// uploaded as a float buffer. Interpolation is monotone cubic (Fritsch–Carlson) so dragging a point
/// can never make the curve fold back on itself — a fold would invert tones and is the classic
/// spline artifact in tone curves.
///
/// **派单 137 — a curve may descend as a whole.** Fritsch–Carlson's "no fold" property is about the
/// *shape* (the table never turns back on itself), not about the sign of the slope. A film negative
/// inverted through a tone curve is a legitimate non-increasing shape: right point below left point,
/// every adjacent sample descending. `buildOne` therefore sorts the points, inspects the sign of all
/// adjacent `Δv`, and dispatches:
///
///   · all `Δv ≥ 0` → the historical non-decreasing path, **byte for byte**;
///   · all `Δv ≤ 0` with at least one `Δv < 0` → reflect `v → 1 − v`, run that same path, reflect the
///     table back (`v → 1 − v`). The no-fold guarantee is inherited, not re-derived;
///   · mixed signs (up then down, or down then up) → `CurveShapeError.mixedDirection`. The table falls
///     back to the identity for a hand-written document; the editor refuses the write and shows the
///     reason, so the picture keeps the last legal shape.
///
/// The **axis is untouched** (派单 030/062): `u = log1p`/sRGB/`log2` still samples `0…1` in increasing
/// order. Only the sampled `v` descends — a falling table on an increasing axis, never a reversed
/// axis.
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
            let table = buildTable(points, index: t)
            for i in 0..<size { out[t * size + i] = table[i] }
        }
        return out
    }

    /// One of the four tables, by its buffer slot (0 = W, 1 = R, 2 = G, 3 = B).
    ///
    /// **W is a luminance gain, so it may never be negative** (派单 137). A non-increasing W point list
    /// is a valid shape in the document — the editor must not throw it away — but multiplying the
    /// pixel by a descending gain would subtract light and can produce negative values, which has no
    /// physical meaning. The cell's rule is therefore: an inverted W is stored (and drawn as the user
    /// drew it) but its **table is the identity**, and the inversion is carried by R/G/B. The same
    /// function is what the renderer's partial rebuild calls, so a drag and a full build cannot
    /// disagree about which table W is.
    public static func buildTable(_ points: [CurvePoint], index: Int) -> [Float] {
        if index == 0, direction(of: points) == .decreasing { return identityTable() }
        return buildOne(points)
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
    /// a ceiling the user drew at the right end, and **up to 2** for a steepened HDR tail (派单 080:
    /// the clamp used to stop at 1, which silently threw away every slope the user drew above it).
    /// A non-increasing table's tail is **negative** (派单 137): the kernel clamps the raw estimate
    /// into `[−HDRCurve.tailSlopeLimit, +HDRCurve.tailSlopeLimit]`, so an inverted curve keeps its
    /// descending continuation instead of being flattened to a ceiling. Both sides clamp with the
    /// same two numbers (`HDRCurve.clampTailSlope`), so a test can compare them. Only the tail is
    /// extrapolated: for `u ≤ 1` this number is never read, which is why the other segments need no
    /// ceiling of their own.
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

    /// The coordinate's own **resolution**: `1e-9` of the axis width — the smallest difference two
    /// `x` values can have and still mean different things to this file.
    ///
    /// 069 made `CurvePoint.x` a continuous `Double` on `0…CurvePoint.maximum`, so this has to be
    /// measured against the axis rather than written down: `2e-9` on today's `0…2` card, `4e-9` on the
    /// `0…4` (+8 EV) card `maximum`'s comment anticipates, with no code change between them. It is
    /// ~7 orders of magnitude above what a `Double` can tell apart at this magnitude (`2.0.ulp` is
    /// `4.4e-16`) and ~6 below the finest step the product can produce (one 8-bit display code is
    /// `1/255 = 3.9e-3` of the axis; one pixel of the card's plot is `~5e-4` of it).
    static func coordinateEpsilon(axis: Double = CurvePoint.maximum) -> Double { axis * 1e-9 }

    /// The **de-duplication window**: `1e-6` of the axis width — two control points closer than this
    /// are one point, and the newer one wins. `2e-6` on today's card, `4e-6` on a `0…4` card.
    ///
    /// Why `1e-6` of the axis: that is exactly the tolerance the pre-069 code used, as an absolute
    /// number on the `0…1` engine axis. The engine's `u` is still the card divided by its width, so
    /// expressing it as a fraction of the axis *restores* that window in the new `0…2` coordinate
    /// (`2e-6` here = `1e-6` there) and keeps it the same window on any wider card. It is 1000×
    /// `coordinateEpsilon` — the resolution is where storage stops distinguishing, the window is where
    /// the *product* stops distinguishing, and the two must not be confused: a segment narrower than
    /// one table sample (`1/(N−1) = 2.4e-4` in `u`) is what turns into a spike.
    static func dedupeWindow(axis: Double = CurvePoint.maximum) -> Double { axis * 1e-6 }

    /// Drop points whose `x` sits within `dedupeWindow(axis:)` of the previous kept one; the
    /// **last** point written wins (the newest hand edit), exactly as the old `1e-6` window did.
    ///
    /// Why a window at all: keeping a pair `ε` apart gives the spline a segment far shorter than the
    /// table's own sample spacing — `h → 0`, `delta = Δv/h → ∞`, and Fritsch–Carlson has to clamp a
    /// tangent it cannot represent. The finished table then holds the whole rise in one sample: a
    /// one-pixel spike in the curve, which is the artifact this function exists to prevent. Bit-exact
    /// de-duplication (not a mere smoothing) is what `CurveStorageTests`' near-coincidence case pins.
    ///
    /// `axis` is a **parameter** so the rule can be exercised on the wider card of a future document
    /// (the test does exactly that: extent `4.0`, a point at `x = 3`). Nothing in here knows the
    /// extent is 2.
    static func dedupe(_ sorted: [CurvePoint], axis: Double) -> [CurvePoint] {
        let window = dedupeWindow(axis: axis)
        var out: [CurvePoint] = []
        for p in sorted {
            if let last = out.last, abs(p.x - last.x) <= window {
                out[out.count - 1] = p
            } else {
                out.append(p)
            }
        }
        return out
    }

    /// The direction of the points as `buildOne` will see them — sorted by x, then de-duplicated.
    public static func direction(of rawPoints: [CurvePoint]) -> CurveDirection {
        direction(ofPrepared: prepared(rawPoints))
    }

    private static func direction(ofPrepared pts: [CurvePoint]) -> CurveDirection {
        guard pts.count >= 2 else { return .increasing }
        var up = false
        var down = false
        for i in 0..<(pts.count - 1) {
            let dy = pts[i + 1].v - pts[i].v
            if dy > 0 { up = true } else if dy < 0 { down = true }
        }
        if up && down { return .mixed }
        return down ? .decreasing : .increasing
    }

    /// The named reason a point list cannot be built, or `nil` when it can.
    public static func shapeError(of points: [CurvePoint]) -> CurveShapeError? {
        direction(of: points) == .mixed ? .mixedDirection : nil
    }

    private static func prepared(_ rawPoints: [CurvePoint]) -> [CurvePoint] {
        dedupe(rawPoints.sorted { $0.x < $1.x }, axis: CurvePoint.maximum)
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
    /// data, but a document or a caller can still hand us y values that go both up and down. The
    /// tabulated fold check is the object-level promise the kernel relies on — a curve that folds is
    /// not "a bit wrong", it inverts tones — so a fold falls back to the identity, the same failure
    /// path `pts.count < 2` already takes.
    ///
    /// 派单 137: "monotone" now means **one direction**, not "non-decreasing". A list whose adjacent
    /// `Δv` are all ≤ 0 (and not all 0) takes the same Fritsch–Carlson path with `v` reflected
    /// (`v → 1 − v`) and the finished table reflected back. The no-fold check is therefore inherited:
    /// the reflected table is non-decreasing exactly where the historical one is, and the final table
    /// is non-increasing. Mixed signs return the identity here (a hand-written document still renders
    /// deterministically); the editor rejects such a write with `CurveShapeError.mixedDirection`, so
    /// in the product the last legal shape stays on screen.
    /// - Parameter n: table length. `CurveLUT.size` (4096) everywhere in the product; a test may ask
    ///   for 1024 or 65536 to measure what the resolution is worth (`HDRCurveTests`, 030 §6).
    public static func buildOne(_ rawPoints: [CurvePoint], size requested: Int? = nil) -> [Float] {
        let tableSize = max(2, requested ?? size)
        let identity = (0..<tableSize).map { Float($0) / Float(tableSize - 1) }
        // Sort by x, then drop points the axis cannot tell apart. 069: the coordinate is continuous,
        // so this is the axis-derived window `dedupeWindow`, not `==` (two points a few nanometres
        // apart are one point, and a segment that short makes the spline spike — see `dedupe`). The
        // last point written wins (the newest hand edit), as the old 1e-6 window did.
        let pts = prepared(rawPoints)

        guard pts.count >= 2 else { return identity }

        switch direction(ofPrepared: pts) {
        case .mixed:
            // A hand-written document can hold an up-then-down list. There is no "last legal shape"
            // to recover inside a pure build, so the deterministic answer is the identity (the same
            // fallback the fold check has always taken). The panel never writes this shape.
            return identity
        case .increasing:
            return monotoneTable(u: pts.map(\.u), v: pts.map(\.v),
                                 tableSize: tableSize, identity: identity)
        case .decreasing:
            // `1 − v` turns a descending list into an ascending one without changing any spacing, so
            // this is the *same* interpolant — not a second algorithm. Reflect the finished table
            // back; Float rounding preserves the reversed order because subtraction is monotone.
            let reflected = monotoneTable(u: pts.map(\.u), v: pts.map { 1 - $0.v },
                                          tableSize: tableSize, identity: identity)
            return reflected.map { Float(min(max(1 - Double($0), 0), 1)) }
        }
    }

    /// The historical non-decreasing table, on plain `u`/`v` arrays so the descending path can hand
    /// it a reflected `v` without constructing points (and without a card-coordinate round trip).
    private static func monotoneTable(u: [Double], v: [Double], tableSize: Int,
                                      identity: [Float]) -> [Float] {
        let n = u.count
        guard n >= 2 else { return identity }

        let h = (0..<(n - 1)).map { u[$0 + 1] - u[$0] }
        // The same window in the engine's coordinate (`u = x / maximum`) — `1e-6`, independent of how
        // wide the card is. After `dedupe` no surviving gap can be this small, so this is the identity
        // fallback for input `dedupe` cannot order (a non-finite coordinate), not a live filter.
        let uWindow = dedupeWindow() / CurvePoint.maximum
        guard h.allSatisfy({ $0 > uWindow }) else { return identity }
        let delta = (0..<(n - 1)).map { (v[$0 + 1] - v[$0]) / h[$0] }

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
            if x <= u[0] {
                out[i] = Float(v[0])
                continue
            }
            if x >= u[n - 1] {
                out[i] = Float(v[n - 1])
                continue
            }
            while seg < n - 2 && x > u[seg + 1] { seg += 1 }
            let t = (x - u[seg]) / h[seg]
            let t2 = t * t
            let t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            // Split into two sums: one expression of six products is past what the type checker
            // will do in reasonable time.
            let a = h00 * v[seg] + h10 * h[seg] * m[seg]
            let b = h01 * v[seg + 1] + h11 * h[seg] * m[seg + 1]
            let y = a + b
            out[i] = Float(min(max(y, 0), 1))
        }

        // §5.4 layer 2: the *reflected* table must not fold either. Tolerance 0 — equal neighbours are
        // monotone, a single step in the wrong direction is not. (The final reflection in `buildOne`
        // preserves this exactly, so the descending table inherits the check.)
        guard zip(out, out.dropFirst()).allSatisfy({ $1 >= $0 }) else { return identity }
        return out
    }
}

/// A point list's **overall direction** after the same sort/de-dupe `CurveLUT.buildOne` performs.
///
/// Flat lists answer `.increasing`: that is the historical path and its table is both non-decreasing
/// and non-increasing, so it needs no second representation. `.mixed` is exactly the shape the old
/// code silently flattened: one adjacent step up and another down.
public enum CurveDirection: Sendable, Equatable {
    case increasing
    case decreasing
    case mixed
}

/// Why a point list is not a curve this engine can build (派单 137).
///
/// Named, not a bare `false`, because the panel has to tell the user *why* a drag did not land:
/// "先升后降" is a different message from "点太少" or an out-of-range coordinate.
public enum CurveShapeError: Error, Equatable, CustomStringConvertible {
    case mixedDirection

    public var description: String {
        switch self {
        case .mixedDirection:
            return "曲线只能整体递增或整体递减，不能先升后降（或先降后升）"
        }
    }

    /// The one-line hint the panel shows in its read-out row. Kept next to the error so the word
    /// the model rejects with and the word the user reads cannot drift.
    public var hint: String { description }
}
