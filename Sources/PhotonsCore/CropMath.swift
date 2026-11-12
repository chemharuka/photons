import Foundation

// MARK: - corner-based crop rectangle (XMP `crs:Crop*` semantics)

/// A crop rectangle in **normalized source coordinates** (0…1, origin top-left) stored as its four
/// **edges**, exactly like XMP's `crs:CropLeft/Top/Right/Bottom`: `right` and `bottom` are
/// boundaries, *not* widths. `left == 0, top == 0, right == 1, bottom == 1` is the whole frame.
///
/// The document still stores `NormalizedRect` (origin + size) under the `crop` key so pre-existing
/// documents keep their bytes; `CropRect` is the edge-semantics view of the same rectangle and the
/// only form the crop math below speaks (docs/architecture-decisions.md D9).
public struct CropRect: Sendable, Equatable, Hashable, Codable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double

    public static let full = CropRect(left: 0, top: 0, right: 1, bottom: 1)

    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    /// Edge view of the stored `NormalizedRect`.
    public init(_ rect: NormalizedRect) {
        self.init(left: rect.x, top: rect.y,
                  right: rect.x + rect.width, bottom: rect.y + rect.height)
    }

    /// Same thing spelled with origin + size (the Lightroom/Photoshop habit).
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(left: x, top: y, right: x + width, bottom: y + height)
    }

    public var width: Double { right - left }
    public var height: Double { bottom - top }
    public var centerX: Double { (left + right) / 2 }
    public var centerY: Double { (top + bottom) / 2 }

    /// Back to the form the document stores and the kernels consume.
    public var normalizedRect: NormalizedRect {
        NormalizedRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    public var isFull: Bool { self == .full }

    /// True for a rect that covers the frame within floating-point noise.
    public var coversFrame: Bool {
        abs(left) < 1e-9 && abs(top) < 1e-9 && abs(right - 1) < 1e-9 && abs(bottom - 1) < 1e-9
    }

    public func contains(x: Double, y: Double) -> Bool {
        x >= left && x <= right && y >= top && y <= bottom
    }

    /// Pull every edge into 0…1 and keep at least `minimumSpan` of width/height.
    ///
    /// Same policy — and the same numbers — as `NormalizedRect.clamped()`, so a full-frame crop
    /// keeps rendering as the whole image and a degenerate one cannot become zero-sized.
    ///
    /// **132 (user 2026-10-29)**: `allowsOutsideSource: true` is the editing clamp — it keeps the
    /// minimum span and the finiteness but **does not pull the rect back inside the picture**. A crop
    /// is the output frame now, and the user may drag it off the photograph; the pixels outside the
    /// source are written as transparent/black by S0, never smeared. `false` (the default) is the
    /// historical clamp every document decode, XMP read, mask and export check still uses, so an
    /// in-range document keeps its exact numbers byte for byte.
    public func clamped(minimumSpan: Double = 0.001,
                        allowsOutsideSource: Bool = false) -> CropRect {
        let span = min(max(minimumSpan, 0), 1)
        if allowsOutsideSource {
            let w = width.isFinite ? max(width, span) : span
            let h = height.isFinite ? max(height, span) : span
            let l = left.isFinite ? left : 0
            let t = top.isFinite ? top : 0
            return CropRect(left: l, top: t, right: l + w, bottom: t + h)
        }
        let w = min(max(width, span), 1)
        let h = min(max(height, span), 1)
        let l = min(max(left, 0), 1 - w)
        let t = min(max(top, 0), 1 - h)
        return CropRect(left: l, top: t, right: l + w, bottom: t + h)
    }

    public var keyString: String {
        String(format: "%.5f,%.5f,%.5f,%.5f", left, top, right, bottom)
    }
}

/// A crop rectangle in whole pixels, origin top-left, half-open on the far edge (`maxX`/`maxY`).
public struct PixelRect: Sendable, Equatable, Hashable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var area: Int { width * height }

    public var keyString: String { "\(x),\(y),\(width)x\(height)" }
}

/// A non-integral size in pixels: the result of rotating an image by a non-right angle is a real
/// number of pixels, and rounding twice is how straighten crops end up half a pixel off.
public struct DSize: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var aspect: Double { width / max(height, .ulpOfOne) }
}

// MARK: - aspect lock

/// The ratio a crop is constrained to. `ratio` is in **pixels** (width / height of the cropped
/// image), which is the only place an aspect ratio means anything: a 3:2 crop of a 9520×6336 frame
/// is 3:2 in pixels, not in normalized coordinates.
public enum AspectLock: Sendable, Equatable, Hashable {
    /// No constraint: the stored crop rect *is* the frame. This is the default and the reason a
    /// document written before this field existed still renders byte-identically — "原图" means
    /// "keep the geometry you already have", not "re-fit to the sensor's 3:2".
    case original
    case square
    case threeTwo
    case fourThree
    case sixteenNine
    /// Explicit ratio, width / height. Non-positive or non-finite values fall back to `nil`.
    case custom(Double)

    /// Constrained ratio in pixels, or `nil` when the stored rect is authoritative.
    public var ratio: Double? {
        switch self {
        case .original: return nil
        case .square: return 1
        case .threeTwo: return 3.0 / 2.0
        case .fourThree: return 4.0 / 3.0
        case .sixteenNine: return 16.0 / 9.0
        case .custom(let r): return (r.isFinite && r > 0) ? r : nil
        }
    }

    /// Stable text for documents and cache keys. `custom` carries its ratio, so two custom locks
    /// with different ratios never hash the same.
    public var code: String {
        switch self {
        case .original: return "original"
        case .square: return "square"
        case .threeTwo: return "3:2"
        case .fourThree: return "4:3"
        case .sixteenNine: return "16:9"
        case .custom(let r): return String(format: "custom:%.10g", r)
        }
    }

    public var displayName: String {
        switch self {
        case .original: return "Original"
        case .square: return "1:1"
        case .threeTwo: return "3:2"
        case .fourThree: return "4:3"
        case .sixteenNine: return "16:9"
        case .custom(let r): return String(format: "%.4g:1", r)
        }
    }

    /// `nil` for anything this version does not know, so a hand-edited document degrades to the
    /// unconstrained default instead of failing to load.
    public init?(code: String) {
        switch code {
        case "original": self = .original
        case "square": self = .square
        case "3:2": self = .threeTwo
        case "4:3": self = .fourThree
        case "16:9": self = .sixteenNine
        default:
            guard code.hasPrefix("custom:"),
                  let r = Double(code.dropFirst("custom:".count)) else { return nil }
            self = .custom(r)
        }
    }
}

extension AspectLock: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let code = try container.decode(String.self)
        guard let value = AspectLock(code: code) else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "unknown aspect lock '\(code)'")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }

    /// What a UI starts from when the user clicks a ratio: the frame's own ratio is
    /// `source.width / source.height` and is spelled `.custom(...)`.
    public static func matching(source: ImageSize, tolerance: Double = 1e-6) -> AspectLock {
        let r = Double(source.width) / Double(max(source.height, 1))
        for lock in [AspectLock.square, .threeTwo, .fourThree, .sixteenNine] {
            if let known = lock.ratio, abs(known - r) <= tolerance { return lock }
        }
        return .custom(r)
    }

    /// The same question asked of a bare ratio — 072 §C1/§C2.
    ///
    /// 交换长宽 produces ratios that no preset names (9:16, 3:4, 2:3), so they have to be stored as
    /// `.custom`, but one that *does* land on a preset (a 1:1 swap, or 9:16 swapped back to 16:9) should
    /// come back as that preset — otherwise the popup would show 自由 for a 16:9 frame and the next
    /// drag would lose the constraint's name.
    public static func matching(ratio: Double, tolerance: Double = 1e-6) -> AspectLock {
        guard ratio.isFinite, ratio > 0 else { return .original }
        for lock in [AspectLock.square, .threeTwo, .fourThree, .sixteenNine] {
            if let known = lock.ratio, abs(known - ratio) <= tolerance { return lock }
        }
        return .custom(ratio)
    }
}

// MARK: - 183 · perspective / keystone

/// **透视 / 梯形校正** — the two knobs as one 3×3 homography, in the frame's own **normalized**
/// coordinates (y down, the same box S0's `p.c` lives in), plus the closed form that says how much
/// canvas the warp needs.
///
/// ## The map
///
/// Each axis is a *keystone* in the classic sense: a projective scale whose denominator is linear in
/// the distance from a **fixed line**. 338 made that line the frame's **mid-line** — a knob has no
/// near end. `+v` grows one end while it shrinks the other by the same amount, and `−v` is `+v`
/// **reflected in the mid-line**, exactly: `P(−v) = A·P(+v)·A` element for element (asserted to
/// 1e−12, and the two renders to a code, by `KeystoneSymmetry338Tests`).
///
///     vertical   (Y = y − ½)     w = 1 − v·Y      x ↦ ½ + (x − ½)/w      y ↦ ½ + Y/w
///     horizontal (X = x − ½)     w = 1 + v·X      x ↦ ½ + X/w             y ↦ ½ + (y − ½)/w
///
/// Both are exact homographies (`[[1,0,0],[0,1,0],[0,v,1]]` conjugated by a translation), the
/// composition is `M = M_horizontal · M_vertical` (**vertical first** — pinned by
/// `PerspectiveTests`), and the fixed line is the mid-line: `y = ½` for the vertical knob
/// (pointwise), `x = ½` for the horizontal one, and `(½, ½)` for the pair.
///
/// Before 338 the same scale was anchored on the **corner** `(0, 1)` (`w = 1 + s·(1 − y)`, near edge
/// pinned). That is a one-sided family: `+100` scaled the far edge by `1/1.21` and `−100` by
/// `1/(1−0.21)`, so the two ends of the slider were **reciprocals of each other, not reflections** —
/// the user's report (「+100 和 −100 行为不一致」). §The strength says what that costs: the
/// coefficient, not the knob.
///
/// ## The strength
///
/// The knob's strength is the tangent `v = −slider/100 · 0.21`, and it is **the coefficient the
/// matrix carries** — one number, no rescaling, so `+v` and `−v` differ by sign and nothing else.
/// `|slider| = 100` puts the two edges at `1 ∓ v/2`, so the edge pair converges by
/// `atan(½·v/(1 − v²/4))`: **6.06° at ±100 and 3.03° at ±50**, which is the `2·tan 6° = 0.21` the
/// constant was chosen for (183's one-sided map actually produced 7.57° / 3.36° at the same slider
/// positions; this one is the number the doc always named).
///
/// The far/near **width ratio** is `(1 − v/2)/(1 + v/2)` = 1.2346 at `±100`, against the 1.2658 a
/// one-sided map produced at `+100`. That 2.4 % is not slack: a reflected pair requires `v` **odd** in
/// the slider, and no odd `v` can make `(1 − v/2)/(1 + v/2)` equal `1/(1 + v)` away from `v = 0`. The
/// two families agree to first order (`R ≈ 1 − v`), which is the tangent both were specified by; the
/// 3° acceptance card rectifies to 0.16° instead of 0.00° for the same reason (the card tapers
/// *linearly*, a mirrored keystone is projective — see `testFiftyRectifiesTheThreeDegreeCard`).
///
/// **347 — the travel is ±200, the unit is still 100.** The two numbers were the same constant until
/// a document needed more than 6° of correction; splitting them is what makes the widening safe:
/// `limit` (200) is the clamp and the slider's track, `strengthUnit` (100) is the divisor the warp
/// is scaled by. So 100 is today's 0.21 to the last bit, 200 is 0.42 (**12.39°** of convergence, and
/// `w ≥ 1 − 0.42/2 = 0.79` — the quad stays convex), and no existing document moves.
///
/// ## The canvas
///
/// The warped picture is a convex quadrilateral; the canvas is the **largest axis-aligned rectangle
/// inscribed in it**. With the anchor on the mid-line the quad is a symmetric trapezoid, whose width
/// is monotone in height, so the optimum is its full height at the narrow end; `canvasSize` solves it
/// in closed form (see `inscribedRect`), never by search.
public struct PerspectiveMap: Sendable, Equatable {

    /// The slider's range, and the one place a document value is clamped. **353** — ±400: the
    /// travel 347 opened to ±200 still ran out on narrow pairs (two verticals 20 % of the frame
    /// apart need v = 208 at a mere 5° of convergence; measured, see `docs/tasks/353-...`). 400 is
    /// `0.84` of strength, `w ≥ 1 − 0.84/2 = 0.58` — still convex, still no pole. It is *only* the
    /// clamp and the slider's track; the strength is scaled by `strengthUnit`, never by this
    /// number (see `verticalStrength` for the trap).
    ///
    /// **353b (用户 2026-11-12)** — ±500: 「透视可以做到500吗」→「改成500」. `s = 1.05`,
    /// `w ≥ 1 − 1.05/2 = 0.475` — still convex, still no pole, so nothing downstream changes
    /// shape. The near edge magnifies to **2.105×** (`1/(1 − 1.05/2)` … at the resolved corner)
    /// against 400's 1.724×, i.e. the extra travel buys a more aggressive stretch, not new reach
    /// that was previously clipped by a pole. Because the denominator stays `strengthUnit`, the
    /// **existing** ±100…±400 values keep their strength bit for bit; only the track got longer.
    public static let limit = 500.0
    /// **347** — the unit the strength is divided by: **100**, hard-wired, no longer `limit`.
    ///
    /// The strength used to read `-vertical / PerspectiveMap.limit * tangentPerUnit`. Widening
    /// `limit` to 200 under that formula would have **halved** the strength at slider 100 and
    /// repainted every document in the library — a re-parametrisation, not a wider travel. Fixing
    /// the denominator at 100 makes `|v| ≤ 100` bit-for-bit what it was and leaves 200 to mean
    /// exactly twice today's warp (0.42). `PerspectiveRange347Tests` pins both halves.
    public static let strengthUnit = 100.0
    /// `v` at 100 units of travel: 6° of convergence on a square frame (`2·tan 6°`). At the new end
    /// of the travel, 200 units is `0.42`, i.e. 12.39° of convergence.
    public static let tangentPerUnit = 0.21

    public var vertical: Double      // clamped −500…500 (353b; 353 was ±400)
    public var horizontal: Double

    public init(vertical: Double, horizontal: Double) {
        // 353b — **one axis gives way to the other.** `limit` is a *per-axis* clamp, but the two
        // strengths enter one homography (`M = M_horizontal · M_vertical`) and the corner that
        // matters reads
        //
        //     w_min = 1 − (|s_v| + |s_h|) / 2        s = slider / strengthUnit · tangentPerUnit
        //
        // (measured to 1e-16 against the real matrix in `PerspectiveRange347Tests`). Two axes at
        // 500 therefore cancel — `w = −0.05`, a pole, and the picture tears instead of warping.
        // That coupling is not new with 500: two axes at 400 gave `w = 0.160`, positive only by
        // luck, and 476.19 is where any pair lands exactly on zero (`100 / tangentPerUnit`).
        //
        // So the pair is clamped as a **pair**: the magnitude sum is scaled back to
        // `coupledTravelBudget` keeping both signs, which is the "one axis gives way" behaviour
        // the user asked for. At `|v| ≤ 450` and `|h| ≤ 450` the sum is ≤ 900, so every existing
        // document (±400 max, sum ≤ 800) is untouched bit for bit.
        let v = PerspectiveMap.clamp(vertical)
        let h = PerspectiveMap.clamp(horizontal)
        let sum = abs(v) + abs(h)
        let budget = PerspectiveMap.coupledTravelBudget
        if sum > budget, sum > 0 {
            let k = budget / sum
            self.vertical = v * k
            self.horizontal = h * k
            return
        }
        self.vertical = v
        self.horizontal = h
    }

    /// The largest `|v| + |h|` the pair may reach. **900** (用户 2026-11-12：「上限设置为900好了」)
    /// — a round number that leaves `w_min = 1 − 900·0.21/200 = 0.055`, i.e. the pole at
    /// `sum = 952.38` is still 52 units away.
    ///
    /// It sits **below** `2 × limit` (1000), which is exactly why the pair needs its own bound:
    /// each axis alone may use the whole track, the two together may not. At 900 the near edge is
    /// already magnified `1/(1 − 0.945/2) = 1.90×`, so a tighter budget would only trade visible
    /// reach for margin nobody can see.
    public static let coupledTravelBudget = 900.0

    /// The `w_min` the budget buys, derived — never a second constant to keep in sync.
    /// `1 − 900 · 0.21 / (2 · 100) = 0.055`.
    public static var coupledWFloor: Double {
        1 - coupledTravelBudget * tangentPerUnit / (2 * strengthUnit)
    }

    /// `w_min` for a pair, the formula `init` inverts. Exposed because the acceptance reads it.
    public static func minimumW(vertical: Double, horizontal: Double) -> Double {
        let sv = abs(vertical) / strengthUnit * tangentPerUnit
        let sh = abs(horizontal) / strengthUnit * tangentPerUnit
        return 1 - (sv + sh) / 2
    }

    /// A value read from a document, made legal: finite and inside ±`limit` (353: ±400).
    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -limit), limit)
    }

    /// 0/0 — no warp, no canvas change, no uniform, no key token.
    public var isIdentity: Bool { vertical == 0 && horizontal == 0 }

    /// `true` when this map changes no pixel — the one predicate the renderer, the key and the UI ask.
    public var hasWarp: Bool { !isIdentity }

    /// The slider's strength as a **tangent**, `v = −slider/100 · 0.21`: **negative** at a positive
    /// slider, because the far end has to grow and `w = 1 − v·Y` has to *shrink* there. This is also
    /// the coefficient the matrix carries, unchanged — see the type's doc, §The strength.
    ///
    /// 347 — the denominator is `strengthUnit` (**100**), not `limit` (**200**). The two were the
    /// same number until the travel widened; tying the warp's scale to the clamp is the trap the
    /// type doc calls out (`PerspectiveRange347Tests`' ① and ③ are that pin).
    public var verticalStrength: Double { -vertical / PerspectiveMap.strengthUnit * PerspectiveMap.tangentPerUnit }
    public var horizontalStrength: Double { -horizontal / PerspectiveMap.strengthUnit * PerspectiveMap.tangentPerUnit }

    /// The far edge's magnification relative to the frame: `1/(1 − s/2)` at a positive slider, i.e.
    /// `1.117` at `+100`, with the near edge at `1/(1 + s/2)` = `0.905` — the knob moves both ends now
    /// (183 pinned one and read `1/(1 + s)` = 1.266; the far/near **ratio** of this map is
    /// `(1 − s/2)/(1 + s/2)` = 1.235, within 2.4 % — type doc, §The strength).
    public var verticalFarScale: Double { 1 / (1 + verticalStrength / 2) }
    public var horizontalFarScale: Double { 1 / (1 + horizontalStrength / 2) }

    // MARK: the homography

    /// The forward map, `frame → warped frame`, as a row-major 3×3 on `(x, y, 1)`.
    ///
    /// `M = M_horizontal · M_vertical`, both written out rather than conjugated and multiplied, so the
    /// numbers here are the ones the doc comment derives:
    ///
    ///     M_vertical   = [1, −v/2,  v/4 ; 0, 1−v/2,  v/4 ; 0, −v, 1+v/2]
    ///     M_horizontal = [1+h/2, 0, −h/4 ; h/2, 1, −h/4 ; h, 0, 1−h/2]
    ///
    /// with `v`/`h` the strengths (`verticalStrength`), not a rescaled copy. Each row's third entry is
    /// the `T(½,½)…T(−½,−½)` conjugation's offset, and the whole matrix is odd in `v` (in `h`), so
    /// `±slider` differ by nothing but sign — the reflection is exact in floating point, not merely
    /// accurate.
    public var forwardMatrix: [[Double]] {
        let v = verticalStrength
        let h = horizontalStrength
        let m1: [[Double]] = [[1, -0.5 * v, 0.25 * v],
                              [0, 1 - 0.5 * v, 0.25 * v],
                              [0, -v, 1 + 0.5 * v]]
        let m2: [[Double]] = [[1 + 0.5 * h, 0, -0.25 * h],
                              [0.5 * h, 1, -0.25 * h],
                              [h, 0, 1 - 0.5 * h]]
        return PerspectiveMap.multiply(m2, m1)
    }

    /// The sampling map, `warped frame → frame`: what S0 multiplies the sample coordinate by.
    public var inverseMatrix: [[Double]] { PerspectiveMap.invert(forwardMatrix) }

    /// `frame → warped frame` for one normalized point (y down, as everywhere in S0).
    public func forward(x: Double, y: Double) -> (x: Double, y: Double) {
        PerspectiveMap.apply(forwardMatrix, x: x, y: y)
    }

    /// `warped frame → frame` for one normalized point.
    public func inverse(x: Double, y: Double) -> (x: Double, y: Double) {
        PerspectiveMap.apply(inverseMatrix, x: x, y: y)
    }

    // MARK: the canvas (inscribed rectangle, closed form)

    /// The warped picture's four corners in **warped normalized** coordinates, in the frame's own
    /// order (top-left, top-right, bottom-right, bottom-left) — the quadrilateral whose inscribed
    /// rectangle is the canvas.
    public func warpedQuad() -> [(x: Double, y: Double)] {
        [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map { forward(x: $0.0, y: $0.1) }
    }

    /// The canvas: the largest axis-aligned rectangle inside the warped quad, in normalized units of
    /// the **warped** frame (`width ≤ 1` or `> 1` — the far end may push past the old frame).
    ///
    /// The quad is convex and contains its narrow end; measuring in `(x, 1 − y)` the rect is a box in
    /// the quad, and its widest possible value at a given height band is `min(right) − max(left)` over
    /// that band. The boundaries are piecewise linear with the quad's vertices as kinks, so the
    /// optimum is at a vertex height or at a band's own stationary point — the code below enumerates
    /// those candidates and never searches. `testClosedFormIsTheLargestInscribedRectangle` checks the
    /// answer against a 120 × 120 band sweep over the whole knob grid.
    ///
    /// 338 — the anchor moved to the mid-line, so the quad is a symmetric trapezoid and the rect is
    /// the quad's full height at its **narrow end** (the width is monotone in height, so the area only
    /// grows as the band lengthens). Before 338 the rect was pinned to the bottom-left corner instead;
    /// that pinning was the canvas half of the same one-sided parametrisation.
    ///
    /// Degenerate inputs (a knob combination that leaves less than a pixel) are clamped to `minimum`
    /// and reported through `canvas(...)`'s `degenerate` flag — never a zero-sized canvas (§5).
    public func canvasSize() -> DSize {
        let r = inscribedRect()
        return DSize(width: r.width, height: r.height)
    }

    /// `canvasSize` in the units the caller works in: the crop's pixel size in, the canvas' out.
    ///
    /// `minimum` is 1 px, and a degenerate answer is *clamped to it* rather than thrown: a canvas is
    /// an allocation, and the caller has no better answer than "the smallest picture" (the report
    /// names the case).
    public func canvasSize(_ frame: DSize, minimum: Double = 1) -> DSize {
        let r = inscribedRect()
        let w = frame.width * r.width
        let h = frame.height * r.height
        let mw = w.isFinite ? max(w, minimum) : minimum
        let mh = h.isFinite ? max(h, minimum) : minimum
        return DSize(width: mw, height: mh)
    }

    /// Is this canvas a clamped (degenerate) one? A separate predicate so the caller — and the test —
    /// can name the case without a second formula.
    public func isDegenerate(_ frame: DSize, minimum: Double = 1) -> Bool {
        let r = inscribedRect()
        return !(frame.width * r.width >= minimum) || !(frame.height * r.height >= minimum)
    }

    /// The inscribed rectangle in normalized units of the **frame** (not the warped one): `width` and
    /// `height` are what the canvas is, `x`/`y` where its top-left sits.
    ///
    /// 338 — the anchor is the mid-line, so the rect is the quad's full height at the narrow end, and
    /// the narrow end is the bottom (`y = 1 − height`, `x` centred) at a positive slider and the top
    /// (`y = 0`) at a negative one. Nothing is pinned to a corner: `−v`'s rect is `+v`'s reflected, the
    /// same way the quads are.
    public func inscribedRect() -> (x: Double, y: Double, width: Double, height: Double) {
        // Work in (u, t) = (x, 1 − y), i.e. right and *up*. The quad is convex;
        // `left(t)`/`right(t)` are its two boundaries at height `t`, each a single straight line
        // between two vertices, so both are piecewise linear with the vertices' `t` as kinks.
        let quad = warpedQuad().map { (u: $0.x, t: 1 - $0.y) }
        func bounds(at t: Double) -> (left: Double, right: Double) {
            var lo = Double.infinity, hi = -Double.infinity
            var found = false
            for i in 0..<4 {
                let a = quad[i], b = quad[(i + 1) % 4]
                let d = b.t - a.t
                guard abs(d) > 1e-12 else { continue }
                let lambda = (t - a.t) / d
                guard lambda >= -1e-9, lambda <= 1 + 1e-9 else { continue }
                let u = a.u + lambda * (b.u - a.u)
                lo = min(lo, u); hi = max(hi, u); found = true
            }
            return found ? (lo, hi) : (0, 0)
        }

        // Candidate heights: every vertex's own `t` (the quad can reach past the frame's 0…1 at a
        // positive slider, which is the whole point of the inscribed rect). Between two of them
        // `left` and `right` are single lines, so the extremes are at the knots. (A maximal
        // rectangle's ends land on a knot for every map in range: the width falls at most
        // `1 − 1/(1+0.21) = 17 %`, so the unconstrained optimum `h = 1/(2·slope)` is always past the
        // quad. The grid-search test checks that claim to 1e-3 of area over the whole knob grid.)
        var knots = quad.map(\.t)
        knots.sort()
        knots = knots.reduce(into: []) { acc, t in
            if acc.last.map({ abs($0 - t) > 1e-9 }) ?? true { acc.append(t) }
        }

        // Candidate bands. The knot-aligned ones are exact whenever the width falls or is constant
        // across the band (every single-knob map — the acceptance's four notches). When both knobs are
        // engaged the quad is skewed and the width can *grow* with height, which puts the optimum
        // strictly inside a piece: there `area(b) = (b − a)(R(b) − L_max)` is a quadratic in `b`, so
        // its stationary point is closed form too (`b* = (L_max − r0 + r1·a) / (2·r1)`).
        var bands: [(Double, Double)] = []
        for i in 0..<knots.count {
            for j in (i + 1)..<knots.count { bands.append((knots[i], knots[j])) }
        }
        for i in 0..<knots.count {
            let a = knots[i]
            for j in (i + 1)..<knots.count {
                let p = knots[j], q = knots[(j + 1) % knots.count]
                guard q > p else { continue }
                let rp = bounds(at: p).right, rq = bounds(at: q).right
                let slope = (rq - rp) / (q - p)
                guard slope < -1e-9 else { continue }
                var lMax = -Double.infinity
                for t in knots[i...j] { lMax = max(lMax, bounds(at: t).left) }
                let r0 = rp - slope * p
                let bStar = (lMax - r0 + slope * a) / (2 * slope)
                if bStar > p + 1e-12, bStar < q - 1e-12, bStar > a {
                    bands.append((a, min(bStar, q)))
                }
            }
        }

        var best = (x: 0.0, y: 0.0, w: 0.0, h: 0.0, area: 0.0)
        for (t0, t1) in bands {
            let height = t1 - t0
            guard height > 0 else { continue }
            // The widest rect over the whole band: every sample's `[left, right]` must contain it, so
            // its left is the largest `left` and its right the smallest `right` in there — evaluated
            // at the band's ends and at every vertex height inside it (each boundary is one line
            // between vertices, so those are the extremes).
            var lo = -Double.infinity, hi = Double.infinity
            var samples = [t0, t1]
            samples.append(contentsOf: knots.filter { $0 > t0 + 1e-12 && $0 < t1 - 1e-12 })
            for t in samples {
                let b = bounds(at: t)
                lo = max(lo, b.left)
                hi = min(hi, b.right)
            }
            let width = hi - lo
            guard width > 1e-12 else { continue }
            if width * height > best.area {
                best = (x: lo, y: 1 - t1, w: width, h: height, area: width * height)
            }
        }

        guard best.area > 0 else {
            return (x: 0, y: 0, width: 1, height: 1)
        }
        return (x: best.x, y: best.y, width: best.w, height: best.h)
    }

    // MARK: the 3×3 arithmetic

    public static func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0.0) { $0 + a[i][$1] * b[$1][j] } } }
    }

    public static func apply(_ m: [[Double]], x: Double, y: Double) -> (x: Double, y: Double) {
        let w = m[2][0] * x + m[2][1] * y + m[2][2]
        guard abs(w) > 1e-12 else { return (x, y) }
        return ((m[0][0] * x + m[0][1] * y + m[0][2]) / w,
                (m[1][0] * x + m[1][1] * y + m[1][2]) / w)
    }

    /// Adjugate inverse: the matrices here are well conditioned (the denominator is `1 ± 0.21`), and
    /// `PerspectiveTests` pins `M·M⁻¹ = I` to 1e-12 for the whole slider grid.
    public static func invert(_ m: [[Double]]) -> [[Double]] {
        let c00 = m[1][1] * m[2][2] - m[1][2] * m[2][1]
        let c01 = m[1][2] * m[2][0] - m[1][0] * m[2][2]
        let c02 = m[1][0] * m[2][1] - m[1][1] * m[2][0]
        let det = m[0][0] * c00 + m[0][1] * c01 + m[0][2] * c02
        guard abs(det) > 1e-12 else { return [[1, 0, 0], [0, 1, 0], [0, 0, 1]] }
        let d = 1 / det
        return [[c00 * d, (m[0][2] * m[2][1] - m[0][1] * m[2][2]) * d,
                 (m[0][1] * m[1][2] - m[0][2] * m[1][1]) * d],
                [c01 * d, (m[0][0] * m[2][2] - m[0][2] * m[2][0]) * d,
                 (m[0][2] * m[1][0] - m[0][0] * m[1][2]) * d],
                [c02 * d, (m[0][1] * m[2][0] - m[0][0] * m[2][1]) * d,
                 (m[0][0] * m[1][1] - m[0][1] * m[1][0]) * d]]
    }
}

// MARK: - 246 · the perspective canvas (photo → P → R → AABB)

/// The one description of a keystoned document's canvas, in **crop pixels** at 1:1.
///
/// The chain is the user's order and nothing else:
///
///     photo pixels --P (keystone)--> --R (straighten, about the crop's centre)--> --AABB--> canvas
///
/// `extent` is the continuous AABB (what the ≤0.5 px assertions compare against), `size` is its
/// one `ceil` (what a texture allocates), and `sampling` is the composed 3×3 from **canvas
/// normalized** coordinates to **turned-photo normalized** coordinates. The kernel applies exactly
/// that matrix once per pixel; `CropMath` is the only place the composition is written down.
///
/// The AABB is taken with the corners **already warped**, not from the rotated AABB of the warped
/// bounding box: `R(AABB(Q))` is bigger than `AABB(R(Q))` at θ ≠ 0, and the difference is precisely
/// the black band the user reported as "the photo's corners were cut off".
public struct PerspectiveCanvas: Sendable, Equatable {
    /// The canvas in whole pixels (the `ceil` of `extent`).
    public let size: ImageSize
    /// The canvas in continuous pixels — the number the acceptance's ±0.5 px compares with.
    public let extent: DSize
    /// The AABB's top-left in rotated-crop pixel coordinates (the phase the shader walks back).
    public let originX: Double
    public let originY: Double
    /// The crop's own pixel size before the warp — the frame the keystone is measured in.
    public let frame: DSize
    /// `canvas-normalized → turned-photo-normalized`, row-major 3×3, for S0.
    public let sampling: [[Double]]
    /// `turned-photo-normalized → canvas-normalized`, row-major 3×3 — the same map forward. The
    /// photo-quad and red-frame arithmetic read it.
    public let forward: [[Double]]
}

/// The arithmetic behind crop / straighten / aspect lock, kept out of the renderer so it can be
/// checked against closed-form values instead of against pixels (docs/architecture-decisions.md
/// D12: one implementation, several callers — UI preview, export, golden tests).
///
/// **Rotation convention** matches `s0_geometry.metal`: a positive angle turns the picture
/// clockwise about the centre of the crop, and the crop stays the output frame. So "does the
/// rotated crop still sample inside the sensor" is the question the inscribed-rect functions
/// answer.
public enum CropMath {

    // MARK: normalized ↔ pixels

    /// Pixel rect of a normalized crop. Rounding is `round(source * normalized)`, the exact formula
    /// `RenderGraph.plan` has always used, so the rendered size cannot drift by a pixel.
    ///
    /// `allowsOutsideSource: true` (132) keeps the origin where the crop puts it instead of pulling
    /// it back inside the source, and lets the width/height exceed the source (`round(source × span)`
    /// with a span > 1) — the crop editing path's output frame may be larger than the photograph.
    /// `false` is the historical clamp, byte for byte.
    public static func pixelRect(_ crop: CropRect, in source: ImageSize,
                                 allowsOutsideSource: Bool = false) -> PixelRect {
        let c = crop.clamped(allowsOutsideSource: allowsOutsideSource)
        let w = max(1, Int((Double(source.width) * c.width).rounded()))
        let h = max(1, Int((Double(source.height) * c.height).rounded()))
        if allowsOutsideSource {
            return PixelRect(x: Int((Double(source.width) * c.left).rounded()),
                             y: Int((Double(source.height) * c.top).rounded()),
                             width: w, height: h)
        }
        let x = min(max(Int((Double(source.width) * c.left).rounded()), 0), source.width - w)
        let y = min(max(Int((Double(source.height) * c.top).rounded()), 0), source.height - h)
        return PixelRect(x: x, y: y, width: w, height: h)
    }

    /// Inverse of `pixelRect`: normalized edges for a whole-pixel crop.
    public static func cropRect(_ pixels: PixelRect, in source: ImageSize) -> CropRect {
        let w = Double(max(source.width, 1))
        let h = Double(max(source.height, 1))
        return CropRect(left: Double(pixels.x) / w,
                        top: Double(pixels.y) / h,
                        right: Double(pixels.x + pixels.width) / w,
                        bottom: Double(pixels.y + pixels.height) / h)
    }

    /// Size of the cropped picture at 1:1 — "裁剪后尺寸".
    public static func outputSize(_ crop: CropRect, in source: ImageSize,
                                  allowsOutsideSource: Bool = false) -> ImageSize {
        let p = pixelRect(crop, in: source, allowsOutsideSource: allowsOutsideSource)
        return ImageSize(width: p.width, height: p.height)
    }

    // MARK: 246 · perspective canvas

    /// The canvas of a keystoned document: **P → R → AABB**, in that order.
    ///
    /// `source` is the turned source (the frame the crop rect is measured in). The crop is the
    /// picture the document keeps; the keystone acts in that picture's normalized box, the
    /// straighten turns the warped pixels about the crop's centre, and the canvas is the bounding
    /// box of the four warped-and-turned corners.
    ///
    /// Everything is in the crop's own pixel grid at 1:1. The composed `sampling` matrix is
    /// `canvas-normalized → turned-photo-normalized`:
    ///
    ///     canvas norm → canvas px → +AABB origin → R⁻¹ about the crop centre
    ///                 → warped norm → P⁻¹ → crop norm → photo norm
    ///
    /// which is one 3×3 the kernel can evaluate with one `fma` chain and one divide. No second pass
    /// (217's single-coordinate-system rule).
    public static func perspectiveCanvas(crop: CropRect,
                                         in source: ImageSize,
                                         straightenDegrees: Double,
                                         perspective: PerspectiveMap) -> PerspectiveCanvas {
        let c = crop.clamped(allowsOutsideSource: true)
        let pixels = outputSize(c, in: source, allowsOutsideSource: true)
        let frame = DSize(width: Double(pixels.width), height: Double(pixels.height))
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))

        // (1) P: the **whole photograph's** normalized domain, anchored on the crop's four corners in
        // photo coordinates. Before 248 this warped the crop's own unit square and then scaled by the
        // crop's pixel size, i.e. it anchored the homography on the crop frame — a picture that was
        // keystoned differently depending on how much was cropped.
        let cropCorners = [(c.left, c.top), (c.right, c.top),
                           (c.right, c.bottom), (c.left, c.bottom)]
        let warped = cropCorners.map { corner -> (x: Double, y: Double) in
            let p = perspective.forward(x: corner.0, y: corner.1)
            return (x: p.x * w, y: p.y * h)
        }
        // (2) R: turn the warped pixels about the **photograph's** centre — the same pivot as S0's
        // non-perspective path and `LoupeMapping.sourcePoint`. The photo centre in the warped domain
        // is the centre of the photo's own normalized square, so its pixel position is `(w/2, h/2)`;
        // for `crop == .full` this is bit-for-bit 246's old `frame/2` (there frame == source).
        let half = (x: w / 2, y: h / 2)
        let rotation = CropGeometry.RotationMatrix(degrees: straightenDegrees)
        let turned = warped.map { p -> (x: Double, y: Double) in
            let r = rotation.apply(x: p.x - half.x, y: p.y - half.y)
            return (x: r.x + half.x, y: r.y + half.y)
        }
        let minX = turned.map(\.x).min() ?? 0
        let maxX = turned.map(\.x).max() ?? 1
        let minY = turned.map(\.y).min() ?? 0
        let maxY = turned.map(\.y).max() ?? 1
        let extent = DSize(width: max(1, maxX - minX), height: max(1, maxY - minY))
        let size = ImageSize(width: CropGeometry.canvasPixels(extent.width),
                             height: CropGeometry.canvasPixels(extent.height))

        // The forward map, one factor per line of the prose above.
        //   photo norm → warped norm            P
        //   warped norm → warped px             diag(photo)
        //   warped px → turned px               T(+½) · R · T(−½)
        //   turned px → canvas px               T(−AABB origin)
        //   canvas px → canvas norm             diag(1/extent)
        let toPixels = diag(w, h)
        let turn = translation(half.x, half.y)
            * rotationMatrix(rotation)
            * translation(-half.x, -half.y)
        let toCanvas = diag(1 / extent.width, 1 / extent.height)
            * translation(-minX, -minY)
        let forward = toCanvas * turn * toPixels * perspective.forwardMatrix
        let sampling = PerspectiveMap.invert(forward)
        return PerspectiveCanvas(size: size, extent: extent,
                                 originX: minX, originY: minY, frame: frame,
                                 sampling: sampling, forward: forward)
    }

    /// The whole photograph's four corners in **canvas normalized** coordinates, after P then R,
    /// relative to the canvas AABB of `crop`.
    ///
    /// This is the one "photo quadrilateral" the red-frame predicate reads (246 §2.3): a whole
    /// photograph corner may be far outside the crop, so its crop-normalized position is allowed to
    /// leave `0…1²`; the composed map handles that analytically.
    public static func perspectivePhotoQuad(crop: CropRect,
                                            canvas: PerspectiveCanvas) -> [NormalizedPoint] {
        [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map { corner in
            let p = PerspectiveMap.apply(canvas.forward, x: corner.0, y: corner.1)
            return NormalizedPoint(p.x, p.y)
        }
    }

    /// Is `rect` (canvas normalized) inside the convex quadrilateral `quad`?
    ///
    /// A convex quad is the intersection of four half-planes, so a convex rect is inside it exactly
    /// when its four corners are. This is the **quadrilateral** test 246 asks for — the old red
    /// predicate used the rotated rectangle (or its AABB), which counts the black triangle outside a
    /// keystoned picture as "inside the photo".
    public static func quadContains(_ quad: [NormalizedPoint],
                                    rect: CropRect,
                                    tolerance: Double = 1e-9) -> Bool {
        guard quad.count == 4 else { return false }
        let corners = [(rect.left, rect.top), (rect.right, rect.top),
                       (rect.right, rect.bottom), (rect.left, rect.bottom)]
        return corners.allSatisfy { point in
            quadContains(quad, x: point.0, y: point.1, tolerance: tolerance)
        }
    }

    /// Point-in-convex-quad (either winding). A point within `tolerance` normalized units of an
    /// edge counts as inside, so a crop flush with the picture is not painted red by a rounding.
    public static func quadContains(_ quad: [NormalizedPoint],
                                    x: Double, y: Double,
                                    tolerance: Double = 1e-9) -> Bool {
        guard quad.count == 4 else { return false }
        var positive = false, negative = false
        for i in 0..<4 {
            let a = quad[i], b = quad[(i + 1) % 4]
            let cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)
            let scale = max(1e-12, hypot(b.x - a.x, b.y - a.y))
            if cross > tolerance * scale { positive = true }
            if cross < -tolerance * scale { negative = true }
        }
        return !(positive && negative)
    }

    // MARK: the 3×3 helpers (row-major, the same shape `PerspectiveMap` uses)

    static func diag(_ x: Double, _ y: Double) -> [[Double]] {
        [[x, 0, 0], [0, y, 0], [0, 0, 1]]
    }

    static func translation(_ x: Double, _ y: Double) -> [[Double]] {
        [[1, 0, x], [0, 1, y], [0, 0, 1]]
    }

    static func rotationMatrix(_ r: CropGeometry.RotationMatrix) -> [[Double]] {
        [[r.cosine, -r.sine, 0], [r.sine, r.cosine, 0], [0, 0, 1]]
    }

    /// The output canvas: **the rotated crop frame itself**, i.e. the crop's own pixel size.
    ///
    /// 301 (方案 A, 帧优先) reversed 162's AABB rule. The crop rect is a window on the turned
    /// picture; the output is that window, so the canvas is the window's `W × H` — not the bounding
    /// box of the window once it is turned. Rotation is a rigid transform: turning the frame does not
    /// change its extent, and the AABB only added the black margin the user reported (a full-frame
    /// crop at 9° was 25.4 % background). `RenderGraph.plan` hands S0 the same crop and no baseline
    /// inset, so `p.c` is the canvas' whole domain and the picture support edge is the canvas edge.
    ///
    /// `quarterTurns` is applied to `source` first — `source` is the file's own frame, exactly like
    /// `GeometryGroup.orientedSource` — because `crop` is measured in the turned frame. A right angle
    /// (0 / 90 / 180 / 270) still returns the crop's own pixel size bit for bit: that is now simply
    /// the same branch every other angle takes.
    ///
    /// The keystone is the one exception: a warped crop is a quadrilateral, so its canvas stays the
    /// `P → R → AABB` box `perspectiveCanvas` defines (the pre-301 behaviour, untouched).
    public static func canvasSize(crop: CropRect, in source: ImageSize,
                                  straightenDegrees: Double,
                                  quarterTurns: Int,
                                  allowsOutsideSource: Bool = false,
                                  perspective: PerspectiveMap? = nil) -> ImageSize {
        let turned = GeometryGroup.normalizedQuarterTurns(quarterTurns) % 2 == 1
            ? ImageSize(width: source.height, height: source.width)
            : source
        // 246 — the keystone keeps its own canvas: the warped picture is a quadrilateral, and its
        // bounding box is still the honest output for a document that never had a rectangular crop
        // frame. `perspectiveCanvas` is the one owner of that arithmetic; at 0/0 this branch is not
        // taken and the crop-frame rule below applies.
        if let perspective, perspective.hasWarp {
            return perspectiveCanvas(crop: crop, in: turned,
                                     straightenDegrees: straightenDegrees,
                                     perspective: perspective).size
        }
        return frameSize(crop, in: turned, allowsOutsideSource: allowsOutsideSource,
                         perspective: nil)
    }

    /// Where the crop's own frame starts inside the canvas, in canvas pixels.
    ///
    /// 301 — the canvas **is** the crop frame, so the answer is always `(0, 0)`. Before 301 the
    /// canvas was the rotated crop's AABB and the frame sat at
    /// `(I − R)·(cropCentre − photoCentre) + (extent − frame) / 2` inside it
    /// (`CropGeometry.canvasInsetOrigin`); there is no such margin now. Kept as a named call so the
    /// loupe and the tests have one place to ask, not a second spelling of "zero".
    public static func canvasOrigin(crop: CropRect, in source: ImageSize,
                                    straightenDegrees: Double, quarterTurns: Int,
                                    allowsOutsideSource: Bool = false,
                                    perspective: PerspectiveMap? = nil) -> (x: Int, y: Int) {
        (0, 0)
    }

    /// The picture's own pixel grid at 1:1 — the crop's pixel rect **after the keystone** (183).
    ///
    /// This is `outputSize` plus nothing but the warped canvas: at 0/0 (`perspective == nil`) it is
    /// `outputSize` itself, which is why every caller can route through it unconditionally.
    public static func frameSize(_ crop: CropRect, in source: ImageSize,
                                 allowsOutsideSource: Bool = false,
                                 perspective: PerspectiveMap? = nil) -> ImageSize {
        let out = outputSize(crop, in: source, allowsOutsideSource: allowsOutsideSource)
        guard let perspective, perspective.hasWarp else { return out }
        let warped = perspective.canvasSize(DSize(width: Double(out.width),
                                                  height: Double(out.height)))
        return ImageSize(width: max(1, Int(warped.width.rounded())),
                         height: max(1, Int(warped.height.rounded())))
    }

    /// Size the renderer allocates at `scale` relative to the crop (1 = 1:1 pixels).
    public static func renderSize(_ crop: CropRect, in source: ImageSize,
                                  scale: Double = 1) -> ImageSize {
        let out = outputSize(crop, in: source)
        let s = max(0.01, scale)
        return ImageSize(width: max(1, Int((Double(out.width) * s).rounded())),
                         height: max(1, Int((Double(out.height) * s).rounded())))
    }

    // MARK: quarter turns (90°)

    /// The same rectangle, measured in the frame that has been **turned 90° clockwise**.
    ///
    /// The rect is a *rectangle of the picture*, so when the picture turns the rect turns with it —
    /// this is the whole reason 90° rotation is not just a flag: a crop that kept its numbers while
    /// the frame turned would select a different part of the photograph (the classic bug).
    ///
    /// In **edges**, a clockwise quarter turn is
    ///
    ///     (left, top, right, bottom) → (1 − bottom, left, 1 − top, right)
    ///
    /// which is one subtraction per coordinate and nothing else. That is not an implementation
    /// detail: `1 − x` is exact for `x ∈ [0, 1]` in binary floating point, and the map is a
    /// permutation of the four numbers, so **four turns restore the original four doubles bit for
    /// bit** — which is what makes 「转 4 次回到原帧」 a claim about the document and not just about
    /// the picture. The `NormalizedRect` spelling (`width = right − left`) is derived once from the
    /// same two doubles on every step, so it round-trips for the same reason.
    ///
    /// Why the *normalised* rect turns without the aspect: the frame's pixel dimensions swap with
    /// the turn, so `w·H` and `h·W` trade places. The normalised numbers move one way, the pixel
    /// grid the other, and the pixel block is the same one. `CropMath.turnedClockwise` therefore
    /// only ever needs the rect — see `testQuarterTurnRectIsExactAfterFourTurns` and the pixel-set
    /// assertion in `QuarterTurnTests`.
    public static func turnedClockwise(_ rect: CropRect) -> CropRect {
        let c = rect.clamped(allowsOutsideSource: true)
        return CropRect(left: 1 - c.bottom, top: c.left, right: 1 - c.top, bottom: c.right)
    }

    /// The inverse of `turnedClockwise`: the rect as measured in the frame turned 90° the other way.
    public static func turnedCounterClockwise(_ rect: CropRect) -> CropRect {
        let c = rect.clamped(allowsOutsideSource: true)
        return CropRect(left: c.top, top: 1 - c.right, right: c.bottom, bottom: 1 - c.left)
    }

    /// `rect` after `quarterTurns` (0…3, clockwise) turns of the frame.
    public static func turned(_ rect: CropRect, quarterTurns: Int) -> CropRect {
        var out = rect.clamped(allowsOutsideSource: true)
        for _ in 0..<(((quarterTurns % 4) + 4) % 4) { out = turnedClockwise(out) }
        return out
    }

    /// A **point** of the file's frame, in the frame turned `quarterTurns` (0…3) times clockwise —
    /// the forward direction, and therefore the inverse of `frame_unturn_uv` in
    /// `Kernels/frame_turn.metal`.
    ///
    /// The host needs it for the one map that runs source → canvas (`MaskCanvasMapping.canvasPoint`,
    /// which is the inverse of S0's). Mask shapes stay in the file's frame — a turn does not move
    /// them relative to the photograph — so their *canvas* position is the turned one.
    ///
    /// Clockwise: `(x, y) → (1 − y, x)`, so the file's top-left lands at the turned frame's
    /// top-right, and `turned(rect, …)` is the bounding box of the four turned corners (pinned by
    /// `testPointTurnAgreesWithTheRectTurn`).
    public static func turned(_ p: NormalizedPoint, quarterTurns: Int) -> NormalizedPoint {
        var out = p
        for _ in 0..<(((quarterTurns % 4) + 4) % 4) {
            out = NormalizedPoint(1 - out.y, out.x)
        }
        return out
    }

    /// `rect` as measured in the **file's own** (pre-turn) frame — the space XMP's `crs:Crop*` live
    /// in, and the inverse of `turned(_:quarterTurns:)`.
    ///
    /// One function, because two spellings of "undo the turn" is how a crop ends up written into a
    /// sidecar that Lightroom reads as a different picture.
    public static func sourceRect(_ rect: CropRect, quarterTurns: Int) -> CropRect {
        var out = rect.clamped(allowsOutsideSource: true)
        for _ in 0..<(((quarterTurns % 4) + 4) % 4) { out = turnedCounterClockwise(out) }
        return out
    }

    // MARK: rotation

    /// Smallest axis-aligned rectangle that contains `size` after rotating it by `degrees`.
    /// Grows to the diagonal at 45°; never smaller than the source.
    ///
    /// The formula itself lives in `CropGeometry.rotatedExtent` (2026-11-01) — one implementation for
    /// the renderer's canvas, the loupe's fit and the crop clamp.
    public static func containingExtent(of size: ImageSize, degrees: Double) -> DSize {
        CropGeometry.rotatedExtent(of: size, degrees: degrees)
    }

    /// Largest rectangle with the **source's own aspect** that still fits inside `size` rotated by
    /// `degrees` — the "zoom to fill after straighten" rect, i.e. the crop that samples no pixel
    /// outside the sensor.
    public static func inscribedExtent(of size: ImageSize, degrees: Double) -> DSize {
        let (c, s) = cosSin(degrees)
        let w = Double(size.width), h = Double(size.height)
        let k = h / w                       // the aspect we are preserving, as height per width
        let byWidth = w / (c + k * s)       // w·c + h·s ≤ W with h = k·w
        let byHeight = h / (s + k * c)      // w·s + h·c ≤ H with h = k·w
        let width = min(byWidth, byHeight)
        return DSize(width: width, height: width * k)
    }

    /// `inscribedExtent` as a normalized, centred crop rect — the auto-crop for a straighten.
    public static func inscribedCrop(of size: ImageSize, degrees: Double) -> CropRect {
        let e = inscribedExtent(of: size, degrees: degrees)
        let width = min(e.width / Double(size.width), 1)
        let height = min(e.height / Double(size.height), 1)
        let left = (1 - width) / 2
        let top = (1 - height) / 2
        return CropRect(left: left, top: top, right: left + width, bottom: top + height)
    }

    /// Largest crop with pixel ratio `aspect`, centred on `crop` and contained by it.
    public static func fittedCrop(aspect: Double, in crop: CropRect, source: ImageSize,
                                  allowsOutsideSource: Bool = false) -> CropRect {
        let c = crop.clamped(allowsOutsideSource: allowsOutsideSource)
        guard aspect.isFinite, aspect > 0 else { return c }
        // The ratio in normalized units is not the ratio in pixels: a 3:2 frame is 3:2 only after
        // multiplying width by W and height by H.
        let normalizedAspect = aspect * Double(source.height) / Double(max(source.width, 1))
        guard normalizedAspect.isFinite, normalizedAspect > 0 else { return c }
        var w = c.width
        var h = c.height
        if w / h > normalizedAspect { w = h * normalizedAspect } else { h = w / normalizedAspect }
        return CropRect(left: c.centerX - w / 2, top: c.centerY - h / 2,
                        right: c.centerX + w / 2, bottom: c.centerY + h / 2)
    }

    /// The crop an aspect lock produces on a straightened image: the largest rect with that ratio
    /// that stays inside the rotated frame (no clamped edge sampling), centred.
    public static func lockedCrop(aspect: Double, source: ImageSize, degrees: Double) -> CropRect {
        fittedCrop(aspect: aspect, in: inscribedCrop(of: source, degrees: degrees), source: source)
    }

    /// The rect a lock produces inside an arbitrary selection: free rect when the lock carries no
    /// ratio (`.original`).
    public static func lockedCrop(_ lock: AspectLock, in crop: CropRect, source: ImageSize,
                                  allowsOutsideSource: Bool = false) -> CropRect {
        guard let ratio = lock.ratio else {
            return crop.clamped(allowsOutsideSource: allowsOutsideSource)
        }
        return fittedCrop(aspect: ratio, in: crop, source: source,
                          allowsOutsideSource: allowsOutsideSource)
    }

    /// **397 — the same law with the units spelled out.** A lock's ratio is a **pixel** ratio, so
    /// converting it into the rect's normalized space needs the pixel grid the rect is *measured in* —
    /// and that is not always the photograph.
    ///
    /// A `.canvas`-spaced rect (`GeometryGroup.cropSpace`) is a rectangle of the **document canvas**
    /// (`CropGeometry.photoQuadExtent`: the photograph after `P → R`, 9846×6536 for the user's file
    /// against the source's 9520×6336). Interpreting its ratio on the source grid therefore describes
    /// a *different* rectangle: 1.5067 in normalized units instead of 1.5025, i.e. 0.28 % off, which
    /// the fit then magnifies into the 35 px black band the user sees at the bottom of the canvas.
    ///
    /// The crop tool has converted in the rect's own units since 362 (`CropToolProjection.units`);
    /// this overload is the same arithmetic for the **render** path, which used to read
    /// `orientedSource` unconditionally. `fittedCrop` itself is untouched: in `.source` units it was
    /// already right, and the two spaces are the same picture whenever there is no keystone.
    public static func lockedCrop(_ lock: AspectLock, in crop: CropRect,
                                  units: (width: Double, height: Double),
                                  allowsOutsideSource: Bool = false) -> CropRect {
        guard let ratio = lock.ratio else {
            return crop.clamped(allowsOutsideSource: allowsOutsideSource)
        }
        return fittedCrop(aspect: ratio, in: crop, units: units,
                          allowsOutsideSource: allowsOutsideSource)
    }

    /// `fittedCrop` with the pixel grid handed in explicitly (`397`). Same algebra, one call to it:
    /// `normalizedAspect = aspect · units.height / units.width`.
    public static func fittedCrop(aspect: Double, in crop: CropRect,
                                  units: (width: Double, height: Double),
                                  allowsOutsideSource: Bool = false) -> CropRect {
        let c = crop.clamped(allowsOutsideSource: allowsOutsideSource)
        guard aspect.isFinite, aspect > 0 else { return c }
        let normalizedAspect = aspect * units.height / max(units.width, 1)
        guard normalizedAspect.isFinite, normalizedAspect > 0 else { return c }
        var w = c.width
        var h = c.height
        if w / h > normalizedAspect { w = h * normalizedAspect } else { h = w / normalizedAspect }
        return CropRect(left: c.centerX - w / 2, top: c.centerY - h / 2,
                        right: c.centerX + w / 2, bottom: c.centerY + h / 2)
    }

    /// True when every sample of `crop` (rotated by `degrees` about its own centre) lands inside the
    /// source, i.e. the straighten needs no edge clamping. Same inequality the kernel relies on.
    public static func fitsInsideSource(_ crop: CropRect, in source: ImageSize,
                                        degrees: Double) -> Bool {
        let c = crop.clamped()
        let (cosine, sine) = cosSin(degrees)
        let w = c.width * Double(source.width)
        let h = c.height * Double(source.height)
        let halfX = (w * cosine + h * sine) / 2
        let halfY = (w * sine + h * cosine) / 2
        let cx = c.centerX * Double(source.width)
        let cy = c.centerY * Double(source.height)
        return cx - halfX >= -0.5 && cx + halfX <= Double(source.width) + 0.5
            && cy - halfY >= -0.5 && cy + halfY <= Double(source.height) + 0.5
    }

    // MARK: the rotated picture's own bound (框 不许 出 照片)

    /// The sensor's four corners **after** a straighten of `degrees`, in normalized frame
    /// coordinates (0…1, y down), in source order: top-left, top-right, bottom-right, bottom-left.
    ///
    /// A straighten turns the picture *inside the frame*: the crop rect stays axis-aligned and the
    /// sensor's quad turns under it, so at θ ≠ 0 the legal region for a crop is this quad and not
    /// `0…1²`. Positive `degrees` turns the picture clockwise, the same sign S0 applies
    /// (`s0_geometry.metal`), which on a y-down frame is the ordinary rotation matrix.
    public static func rotatedFrameCorners(in source: ImageSize,
                                           degrees: Double) -> [NormalizedPoint] {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        // 123: the matrix comes from `CropGeometry.RotationMatrix` — the one place the rotation's
        // sign lives — so this walk and the renderer's cannot drift apart (they did once: the frame
        // turned one way and the selection the other).
        let m = CropGeometry.RotationMatrix(degrees: degrees)
        return [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map { corner in
            let dx = corner.0 * w - w / 2, dy = corner.1 * h - h / 2
            let turned = m.apply(x: dx, y: dy)
            return NormalizedPoint((turned.x + w / 2) / w, (turned.y + h / 2) / h)
        }
    }

    /// The fraction σ ∈ 0…1 by which every side of `crop` must be multiplied — about the rect's own
    /// centre, so the pixel aspect is untouched — for the rect to sit inside the sensor turned by
    /// `degrees`. `1` means "it already fits"; `0` means "its centre is outside the picture and no
    /// positive size fits there".
    ///
    /// Closed form, not a search. Writing the rect's half-extents as (a, b) in pixels and its centre
    /// as (dx, dy) from the frame centre, rotating the *rect* by −θ into the sensor's own axes turns
    /// containment into two linear inequalities on σ:
    ///
    ///     |x₀| + σ(a·|cos θ| + b·|sin θ|) ≤ W/2
    ///     |y₀| + σ(a·|sin θ| + b·|cos θ|) ≤ H/2
    ///
    /// where (x₀, y₀) is the centre rotated by −θ. `|x₀| + σ·…` is the support function of a
    /// rectangle along an axis, so the two lines are *exact* — no corner enumeration, and no
    /// axis-aligned bounding box (which for a straightened frame is bigger than the picture, the
    /// mistake that lets a frame sample the clamped edge).
    public static func rotatedFrameScale(_ crop: CropRect,
                                         in source: ImageSize,
                                         degrees: Double) -> Double {
        let c = crop.clamped()
        guard c.width > 0, c.height > 0 else { return 1 }
        let (a, b) = halves(c, in: source)
        let (cosine, sine) = cosSin(degrees)
        let centre = rotatedCentre(c, in: source, degrees: degrees)
        return scale(dx: centre.x, dy: centre.y, a: a, b: b,
                     cosine: cosine, sine: sine, in: source)
    }

    /// `crop` shrunk — **keeping its centre and its pixel aspect** — until it is fully inscribed in
    /// the sensor turned by `degrees`: the auto-shrink a straighten used to need.
    ///
    /// **132 (user 2026-10-29) changed the default.** The 803aff6 rule ("框不许出旋转后的照片", added
    /// to stop a crop that reached the sensor's edge from smearing the border outward) is now
    /// **opt-in** through `keepsInsideRotatedFrame: true`. The user's new rule is the opposite
    /// trade: the box may leave the picture, and the pixels outside are written black/transparent by
    /// S0 (the same deterministic value, never a smear), so nothing has to be pulled back. Keeping the
    /// function and its arithmetic is deliberate — `frameExceedsPicture` below uses the same
    /// closed form to colour the frame red instead of moving it.
    ///
    /// Properties the callers rely on, each asserted in `CropFrameInscribeTests`:
    ///
    ///   · **identity at 0°** — with no straighten the sensor *is* the frame, so a legal rect comes
    ///     back bit for bit (and so does any rect `CropRect.clamped()` already bounded);
    ///   · **idempotent** — the answer fits, so clamping it again returns it unchanged (bit for bit:
    ///     a rect that fits by less than 1e-12 relative is returned as-is rather than shaved by a
    ///     ULP on every pass);
    ///   · **monotone** — the longer the straighten, the smaller the answer's sides, never bigger;
    ///   · **back to the unclamped rect at 0°** — the stored rect is the user's intent; the shrink is
    ///     derived, so reducing the angle gives the room back instead of ratcheting the frame smaller.
    ///
    /// The centre is kept because it is what the user aimed at. The single exception is a crop whose
    /// centre is itself outside the turned picture (a 32 px frame in the very corner at a large
    /// angle): no positive size can stay there, so the rect is re-centred on the frame centre — the
    /// same rectangle `inscribedCrop` describes, which is the largest one that fits.
    public static func clampedToRotatedFrame(_ crop: CropRect,
                                             in source: ImageSize,
                                             degrees: Double,
                                             keepsInsideRotatedFrame: Bool = false) -> CropRect {
        let c = crop.clamped(allowsOutsideSource: true)
        guard keepsInsideRotatedFrame, degrees.isFinite, degrees != 0 else { return c }
        guard c.width > 0, c.height > 0 else { return c }
        let (a, b) = halves(c, in: source)
        let (cosine, sine) = cosSin(degrees)
        let centre = rotatedCentre(c, in: source, degrees: degrees)
        let sigma = scale(dx: centre.x, dy: centre.y, a: a, b: b,
                          cosine: cosine, sine: sine, in: source)
        if sigma >= 1 - 1e-12 { return c }
        guard sigma > 0 else {
            // Cornered: keep the rect's shape and put its centre back in the middle of the frame.
            let middle = inscribedScale(width: c.width, height: c.height, in: source,
                                        degrees: degrees)
            let width = c.width * middle, height = c.height * middle
            return CropRect(left: 0.5 - width / 2, top: 0.5 - height / 2,
                            right: 0.5 + width / 2, bottom: 0.5 + height / 2)
        }
        let width = c.width * sigma, height = c.height * sigma
        let cx = c.centerX, cy = c.centerY
        return CropRect(left: cx - width / 2, top: cy - height / 2,
                        right: cx + width / 2, bottom: cy + height / 2)
    }

    // MARK: 317 — 「不出像素」: where a frame of a given size may be translated to

    /// 317 — how far a frame's **centre** may travel and still put all four corners inside the
    /// photograph turned by `degrees`. Measured in pixels along the photograph's own axes, as a
    /// **half-extent about the picture's centre** (`x`, `y`), so the legal centres are
    /// `|X₀| ≤ x` and `|Y₀| ≤ y`.
    ///
    /// The frame is an axis-aligned rect and the photograph is a convex quad (a turned rectangle),
    /// so 「四角都在内」 is four half-plane constraints. Turning the *frame* by −θ into the
    /// photograph's axes makes them two slabs — one per axis — whose support function is exact
    /// (`a·|cos θ| + b·|sin θ|`, the same arithmetic `rotatedFrameScale` uses):
    ///
    ///     |X₀| + A ≤ W/2        |Y₀| + B ≤ H/2
    ///
    /// So the feasible set of translations is a box in the photograph's axes and a parallelogram in
    /// the frame's — **convex**, which is what lets a move be a projection rather than a search.
    /// `isFeasible == false` means no position at all fits this size: the frame has to be inscribed
    /// once (a translation cannot help), which is the one place 317 allows a size change.
    public struct PixelTranslationLimit: Equatable, Sendable {
        public var x: Double
        public var y: Double

        /// **Pixels** of slack, and it is not cosmetic. 307's inscription solves for the frame that
        /// touches the picture's edge, so the frame it returns has a support number that equals the
        /// half-extent exactly — up to an ULP, on either side of zero. Read strictly, `x < 0` would
        /// call that frame 「放不下」 and the clamp would refuse to hold the very rect the inscriber
        /// just produced (measured: 15° inscribed, `limit.y = -1.1e-12`, and a drag then ran straight
        /// out of the picture untouched).
        public static let tolerance: Double = 1e-9

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }

        public var isFeasible: Bool {
            x >= -Self.tolerance && y >= -Self.tolerance
        }
    }

    public static func pixelTranslationLimit(of crop: CropRect,
                                             in source: ImageSize,
                                             degrees: Double) -> PixelTranslationLimit {
        let c = crop.clamped(allowsOutsideSource: true)
        guard c.width > 0, c.height > 0 else { return PixelTranslationLimit(x: 0, y: 0) }
        let (a, b) = halves(c, in: source)
        let (cosine, sine) = cosSin(degrees)
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        return PixelTranslationLimit(x: w / 2 - (a * cosine + b * sine),
                                     y: h / 2 - (a * sine + b * cosine))
    }

    /// 317 — `crop` **translated** (never resized) so its four corners sit inside the photograph
    /// turned by `degrees`: the projection of its centre onto the limit above, which is a per-axis
    /// clamp in the photograph's own axes — no LP, no search, and no axis-aligned box around the
    /// turned picture (that box is the document canvas, and it is exactly where the `000000` corners
    /// live).
    ///
    /// `nil` when no translation fits (`pixelTranslationLimit` is empty): the caller's answer there
    /// is the one-shot inscription, not a move.
    ///
    /// A frame that is already inside comes back **bit for bit** (`==` on the whole struct). That is
    /// load-bearing, not an optimisation: 317 §3.4 promises 「开勾选不缩、不动」 field by field, and
    /// re-deriving a centre through two rotations would shave an ULP off a rect nobody moved.
    public static func translatedInsidePixels(_ crop: CropRect,
                                              in source: ImageSize,
                                              degrees: Double) -> CropRect? {
        let c = crop.clamped(allowsOutsideSource: true)
        guard c.width > 0, c.height > 0 else { return c }
        let limit = pixelTranslationLimit(of: c, in: source, degrees: degrees)
        guard limit.isFeasible else { return nil }
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        let m = CropGeometry.RotationMatrix(degrees: degrees)
        let sensor = m.invert(x: c.centerX * w - w / 2, y: c.centerY * h - h / 2)
        let x = min(max(sensor.x, -max(limit.x, 0)), max(limit.x, 0))
        let y = min(max(sensor.y, -max(limit.y, 0)), max(limit.y, 0))
        guard x != sensor.x || y != sensor.y else { return c }
        let back = m.apply(x: x, y: y)
        let left = (w / 2 + back.x) / w - c.width / 2
        let top = (h / 2 + back.y) / h - c.height / 2
        return CropRect(left: left, top: top, right: left + c.width, bottom: top + c.height)
    }

    /// Does `crop`, straightened by `degrees`, sample only inside the sensor — with `tolerance`
    /// **pixels** of slack on each side? The predicate form of `clampedToRotatedFrame`, for callers
    /// that only need yes/no (a status line, a test that must not depend on the clamp's rounding).
    public static func fitsInsideRotatedFrame(_ crop: CropRect,
                                              in source: ImageSize,
                                              degrees: Double,
                                              tolerance: Double = 1e-6) -> Bool {
        let c = crop.clamped()
        let (a, b) = halves(c, in: source)
        let (cosine, sine) = cosSin(degrees)
        let centre = rotatedCentre(c, in: source, degrees: degrees)
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        let halfX = a * cosine + b * sine
        let halfY = a * sine + b * cosine
        return abs(centre.x) + halfX <= w / 2 + tolerance
            && abs(centre.y) + halfY <= h / 2 + tolerance
    }

    /// Does `crop`, straightened by `degrees`, cover any pixel **outside the photograph**? The
    /// UI-facing predicate of the 803aff6 arithmetic: instead of clamping the frame back inside the
    /// picture (132's old default), the frame is left where the user put it and painted red.
    ///
    /// This is exactly `!fitsInsideRotatedFrame`: at 0° a full-frame crop fits (no red); a full frame
    /// at 45° does not (its corners reach past the rotated sensor); a 0.6× centred crop at 45° does.
    /// Nothing is recomputed on the UI side — it reads this one Bool.
    public static func frameExceedsPicture(_ crop: CropRect,
                                           in source: ImageSize,
                                           degrees: Double,
                                           perspective: PerspectiveMap? = nil,
                                           tolerance: Double = 1e-6) -> Bool {
        // 246 §2.3 — with a keystone the picture is a **quadrilateral**, not the turned rectangle.
        // The crop frame is the canvas rectangle (the AABB of the warped crop), so "is the frame
        // inside the photograph" is "is that rectangle inside the warped photo quad". AABB
        // containment is explicitly *not* used: at 45° + perspective its corners include the black
        // triangle and would call a red frame legal.
        guard let perspective, perspective.hasWarp else {
            return !fitsInsideRotatedFrame(crop, in: source, degrees: degrees, tolerance: tolerance)
        }
        let canvas = perspectiveCanvas(crop: crop, in: source,
                                       straightenDegrees: degrees,
                                       perspective: perspective)
        let quad = perspectivePhotoQuad(crop: crop, canvas: canvas)
        return !quadContains(quad, rect: .full, tolerance: tolerance)
    }

    /// 246's **reverse gate**, kept as a named predicate so a test can show what the old rule would
    /// have answered on the same document. `frameExceedsPicture(... perspective:)` must disagree with
    /// it wherever the picture's corners fall outside the AABB.
    public static func frameExceedsRotatedRectangle(_ crop: CropRect,
                                                    in source: ImageSize,
                                                    degrees: Double,
                                                    tolerance: Double = 1e-6) -> Bool {
        !fitsInsideRotatedFrame(crop, in: source, degrees: degrees, tolerance: tolerance)
    }

    // MARK: the constraint's private arithmetic

    /// Half-extents of a normalized rect, in pixels.
    private static func halves(_ c: CropRect, in source: ImageSize) -> (a: Double, b: Double) {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        return (c.width * w / 2, c.height * h / 2)
    }

    /// The rect's centre, rotated by −θ about the frame centre and measured from it in pixels — the
    /// coordinates the sensor's own axes use.
    private static func rotatedCentre(_ c: CropRect, in source: ImageSize,
                                      degrees: Double) -> (x: Double, y: Double) {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        let dx = c.centerX * w - w / 2, dy = c.centerY * h - h / 2
        // The rect lives in sensor axes, so this is the **inverse** turn — same matrix, inverted.
        let turned = CropGeometry.RotationMatrix(degrees: degrees).invert(x: dx, y: dy)
        return (turned.x, turned.y)
    }

    private static func scale(dx: Double, dy: Double, a: Double, b: Double,
                              cosine: Double, sine: Double, in source: ImageSize) -> Double {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        let denX = a * cosine + b * sine
        let denY = a * sine + b * cosine
        guard denX > 0, denY > 0 else { return 1 }
        let s = min((w / 2 - abs(dx)) / denX, (h / 2 - abs(dy)) / denY)
        guard s.isFinite else { return 0 }
        return min(1, max(0, s))
    }

    /// σ for a rect centred on the frame — the `inscribedExtent` formula, spelled once here so the
    /// cornered fallback and the closed form cannot disagree.
    private static func inscribedScale(width: Double, height: Double, in source: ImageSize,
                                       degrees: Double) -> Double {
        let (cosine, sine) = cosSin(degrees)
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        return scale(dx: 0, dy: 0, a: width * w / 2, b: height * h / 2,
                     cosine: cosine, sine: sine, in: source)
    }

    // MARK: helpers

    /// |cos|, |sin| of an angle in degrees. Abs because a rectangle's extent is the same either
    /// way round, and both signs appear in the formulas.
    static func cosSin(_ degrees: Double) -> (Double, Double) {
        let m = CropGeometry.RotationMatrix(degrees: degrees)
        return (abs(m.cosine), abs(m.sine))
    }
}

// MARK: - 246 · row-major 3×3 composition

infix operator *: MultiplicationPrecedence

private func * (lhs: [[Double]], rhs: [[Double]]) -> [[Double]] {
    PerspectiveMap.multiply(lhs, rhs)
}
