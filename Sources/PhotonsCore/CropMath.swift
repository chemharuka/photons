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
    public func clamped(minimumSpan: Double = 0.001) -> CropRect {
        let span = min(max(minimumSpan, 0), 1)
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

// MARK: - crop math (pure, no GPU, no Metal)

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
    public static func pixelRect(_ crop: CropRect, in source: ImageSize) -> PixelRect {
        let c = crop.clamped()
        let w = max(1, Int((Double(source.width) * c.width).rounded()))
        let h = max(1, Int((Double(source.height) * c.height).rounded()))
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
    public static func outputSize(_ crop: CropRect, in source: ImageSize) -> ImageSize {
        let p = pixelRect(crop, in: source)
        return ImageSize(width: p.width, height: p.height)
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
        let c = rect.clamped()
        return CropRect(left: 1 - c.bottom, top: c.left, right: 1 - c.top, bottom: c.right)
    }

    /// The inverse of `turnedClockwise`: the rect as measured in the frame turned 90° the other way.
    public static func turnedCounterClockwise(_ rect: CropRect) -> CropRect {
        let c = rect.clamped()
        return CropRect(left: c.top, top: 1 - c.right, right: c.bottom, bottom: 1 - c.left)
    }

    /// `rect` after `quarterTurns` (0…3, clockwise) turns of the frame.
    public static func turned(_ rect: CropRect, quarterTurns: Int) -> CropRect {
        var out = rect.clamped()
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
        var out = rect.clamped()
        for _ in 0..<(((quarterTurns % 4) + 4) % 4) { out = turnedCounterClockwise(out) }
        return out
    }

    // MARK: rotation

    /// Smallest axis-aligned rectangle that contains `size` after rotating it by `degrees`.
    /// Grows to the diagonal at 45°; never smaller than the source.
    public static func containingExtent(of size: ImageSize, degrees: Double) -> DSize {
        let (c, s) = cosSin(degrees)
        let w = Double(size.width), h = Double(size.height)
        return DSize(width: w * c + h * s, height: w * s + h * c)
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
    public static func fittedCrop(aspect: Double, in crop: CropRect, source: ImageSize) -> CropRect {
        let c = crop.clamped()
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
    public static func lockedCrop(_ lock: AspectLock, in crop: CropRect, source: ImageSize) -> CropRect {
        guard let ratio = lock.ratio else { return crop.clamped() }
        return fittedCrop(aspect: ratio, in: crop, source: source)
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
    /// the sensor turned by `degrees`: the auto-shrink a straighten needs.
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
                                             degrees: Double) -> CropRect {
        let c = crop.clamped()
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
