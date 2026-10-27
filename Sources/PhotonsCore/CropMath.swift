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

    // MARK: helpers

    /// |cos|, |sin| of an angle in degrees. Abs because a rectangle's extent is the same either
    /// way round, and both signs appear in the formulas.
    static func cosSin(_ degrees: Double) -> (Double, Double) {
        let r = degrees * Double.pi / 180
        return (abs(cos(r)), abs(sin(r)))
    }
}
