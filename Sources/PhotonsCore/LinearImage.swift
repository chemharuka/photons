import Foundation
import CryptoKit

// MARK: - orientation

/// How a stored buffer's rows relate to the upright picture: the eight EXIF values
/// (`tiff:Orientation`, TIFF tag 0x0112, `kCGImagePropertyOrientation`).
///
/// The case names and raw values are deliberately `CGImagePropertyOrientation`'s, so a value can
/// cross an API boundary without a lookup table (`CGImagePropertyOrientation(rawValue: o.rawValue)`)
/// and so log lines and JSON read the same everywhere.
///
/// **Why this is a `PhotonsCore` type and not an `EditModel` field.** Orientation is a property of
/// the *file*, not of the user's edit: the camera wrote it, the user never chose it, and a document
/// that carried a copy would go stale the moment the same sidecar is applied to a re-imported file.
/// It belongs to the decode, travels on `LinearImage`, and is folded into the render key so cached
/// pixels cannot be reused across a different orientation (docs/architecture-decisions.md §11.2).
public enum ImageOrientation: Int, Sendable, Hashable, Codable, CaseIterable {
    case up = 1             // 0th row top, 0th column left      — no transform
    case upMirrored = 2     // 0th row top, 0th column right     — mirror horizontal
    case down = 3           // 0th row bottom, 0th column right  — rotate 180°
    case downMirrored = 4   // 0th row bottom, 0th column left   — mirror vertical
    case leftMirrored = 5   // 0th row left, 0th column top      — transpose
    case right = 6          // 0th row right, 0th column top     — rotate 90° CW
    case rightMirrored = 7  // 0th row right, 0th column bottom  — anti-transpose
    case left = 8           // 0th row left, 0th column bottom   — rotate 270° CW

    // Semantic aliases, so call sites can say what they mean instead of quoting a number.
    // (`CaseIterable`/`Codable` still see exactly eight values: these are statics, not cases.)
    public static let identity = ImageOrientation.up
    public static let mirroredHorizontally = ImageOrientation.upMirrored
    public static let rotated180 = ImageOrientation.down
    public static let mirroredVertically = ImageOrientation.downMirrored
    public static let mirroredHorizontallyRotated90CCW = ImageOrientation.leftMirrored
    public static let rotated90CW = ImageOrientation.right
    public static let mirroredHorizontallyRotated90CW = ImageOrientation.rightMirrored
    public static let rotated90CCW = ImageOrientation.left

    /// `nil` for anything outside 1…8 — a corrupt tag must not become a random transform.
    public init?(exif value: Int) { self.init(rawValue: value) }

    /// Lenient reader for metadata: anything unreadable is `.up`, which is the correct assumption
    /// for the overwhelming majority of files and never worse than guessing a rotation.
    public init(exifOrDefault value: Int?) { self = ImageOrientation(rawValue: value ?? 1) ?? .up }

    /// HEIF `irot`: the box stores a rotation in 90° **counter-clockwise** quarter turns (0…3), with
    /// no mirror flag in the base spec (ISO/IEC 23008-12 §6.5.10). EXIF's 90° values are clockwise,
    /// hence 1 ↔ 8 and 3 ↔ 6 — the two translations that are easy to get backwards, so they are
    /// pinned by a test rather than by a comment.
    ///
    /// `nil` for an out-of-range angle, which is the box being wrong rather than the picture.
    public init?(heifRotationQuarterTurnsCCW angle: Int) {
        switch angle {
        case 0: self = .up              // 0° (and the value an all-zero box carries)
        case 1: self = .rotated90CCW    // EXIF 8: rotate 270° CW
        case 2: self = .rotated180      // EXIF 3
        case 3: self = .rotated90CW     // EXIF 6: rotate 90° CW
        default: return nil
        }
    }

    /// True for 5…8, the orientations that swap the frame's width and height.
    public var exchangesDimensions: Bool { rawValue >= 5 }

    /// The upright size for a stored `width × height` buffer.
    public func uprightSize(width: Int, height: Int) -> (width: Int, height: Int) {
        exchangesDimensions ? (height, width) : (width, height)
    }

    /// Where upright pixel `(x, y)` comes from in the stored buffer (`x` right, `y` down, both
    /// measured on the **upright** frame, so the valid range is `uprightSize`).
    ///
    /// This is the single definition of the eight transforms in the codebase; `LinearImage.oriented`
    /// is the only thing that needs to loop over it, and the test pins every value against an
    /// independent rotation/mirror composition.
    public func sourceCoordinate(x: Int, y: Int, width w: Int, height h: Int) -> (x: Int, y: Int) {
        switch self {
        case .up: return (x, y)
        case .upMirrored: return (w - 1 - x, y)
        case .down: return (w - 1 - x, h - 1 - y)
        case .downMirrored: return (x, h - 1 - y)
        case .leftMirrored: return (y, x)
        case .right: return (y, h - 1 - x)
        case .rightMirrored: return (w - 1 - y, h - 1 - x)
        case .left: return (w - 1 - y, x)
        }
    }

    /// Stable text for the render key. `1` is the default and callers omit it, so an upright file
    /// keeps the pre-orientation key verbatim (§3.2 discipline: a new field must not move keys for
    /// the documents that do not use it).
    public var keyString: String { "\(rawValue)" }

    public var displayName: String {
        switch self {
        case .up: return "upright"
        case .upMirrored: return "mirrored horizontally"
        case .down: return "rotated 180°"
        case .downMirrored: return "mirrored vertically"
        case .leftMirrored: return "transposed"
        case .right: return "rotated 90° CW"
        case .rightMirrored: return "anti-transposed"
        case .left: return "rotated 270° CW"
        }
    }
}

// MARK: - the linear buffer

/// A decoded image in linear light: RGBA, half precision, **row-major, row 0 = top of the picture**,
/// not premultiplied.
///
/// This is the single pixel truth of the pipeline (see docs/architecture-decisions.md §3 D4).
/// Everything downstream (editing graph, thumbnails, export) reads from this representation,
/// never from the RAW file directly.
///
/// The top-down row order is part of the contract, not an accident: `CIContext.render(to:)` +
/// `MTLTexture.getBytes` hands back the picture **bottom-up** (measured:
/// `local/probes/orient/readbackconvention.swift` puts a top-left marker in the last row), so
/// `RAWDecoder` flips once at the decode boundary and every consumer below this type may assume
/// row 0 is the top.
public struct LinearImage: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [Float16]
    /// Name of the linear color space the samples are in (e.g. `extendedLinearSRGB`).
    public let colorSpace: String
    /// Decoder version the samples were produced with (e.g. `"8"`, `"9.dng"`).
    public let decoderVersion: String
    /// Orientation the *stored* rows still carry, as the file declared it (EXIF 1…8 / HEIF `irot`).
    ///
    /// `.up` means the buffer is already upright. `rgba` is never rotated by the decoder: the
    /// transform is applied once, before S0, by `oriented()` — so a rotation costs one buffer copy
    /// per render ingestion and never a second RAW decode.
    public let orientation: ImageOrientation

    public init(width: Int, height: Int, rgba: [Float16], colorSpace: String, decoderVersion: String,
                orientation: ImageOrientation = .up) {
        precondition(rgba.count == width * height * 4, "rgba must be width*height*4")
        self.width = width
        self.height = height
        self.rgba = rgba
        self.colorSpace = colorSpace
        self.decoderVersion = decoderVersion
        self.orientation = orientation
    }

    public var byteCount: Int { rgba.count * MemoryLayout<Float16>.size }

    /// Size of the upright picture: differs from `(width, height)` for the four rotating
    /// orientations, and is what the graph, crop math and masks must see.
    public var uprightSize: (width: Int, height: Int) {
        orientation.uprightSize(width: width, height: height)
    }

    public var isUpright: Bool { orientation == .up }

    /// The upright buffer, with `orientation` reset to `.up`.
    ///
    /// `.up` returns `self` — identity by value, no copy, so the common case costs nothing and the
    /// pixel digest of an upright file is untouched by this type existing.
    public func oriented() -> LinearImage {
        guard !isUpright else { return self }
        let (w, h) = uprightSize
        var out = [Float16](repeating: 0, count: w * h * 4)
        let srcW = width, srcH = height
        for y in 0..<h {
            for x in 0..<w {
                let s = orientation.sourceCoordinate(x: x, y: y, width: srcW, height: srcH)
                let so = (s.y * srcW + s.x) * 4
                let do_ = (y * w + x) * 4
                out[do_] = rgba[so]
                out[do_ + 1] = rgba[so + 1]
                out[do_ + 2] = rgba[so + 2]
                out[do_ + 3] = rgba[so + 3]
            }
        }
        return LinearImage(width: w, height: h, rgba: out, colorSpace: colorSpace,
                           decoderVersion: decoderVersion, orientation: .up)
    }

    /// Byte-exact digest of the samples. Used by the L1 determinism check and by
    /// golden-image regression; must not depend on timestamps or paths.
    public func sha256() -> String {
        var hasher = SHA256()
        rgba.withUnsafeBytes { raw in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: raw.baseAddress, count: raw.count))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public struct Statistics: Sendable {
        public let maxChannel: Float
        public let meanLuma: Float
        /// Fraction of samples above 1.0 — proof that HDR/EDR headroom survived the decode.
        public let overUnityRatio: Double
    }

    public func statistics(sampleStride: Int = 7) -> Statistics {
        var maxV: Float = 0
        var sum: Double = 0
        var over = 0
        var n = 0
        var i = 0
        let count = width * height
        while i < count {
            let o = i * 4
            let r = Float(rgba[o]), g = Float(rgba[o + 1]), b = Float(rgba[o + 2])
            let m = Swift.max(r, Swift.max(g, b))
            if m > maxV { maxV = m }
            if m > 1.0 { over += 1 }
            let w = ColorPrimaries.working.luminanceWeights
            sum += Double(w.x) * Double(r) + Double(w.y) * Double(g) + Double(w.z) * Double(b)
            n += 1
            i += sampleStride
        }
        return Statistics(maxChannel: maxV,
                          meanLuma: Float(sum / Double(Swift.max(n, 1))),
                          overUnityRatio: Double(over) / Double(Swift.max(n, 1)))
    }

    /// One upright pixel's colour, box-averaged over a `radius`-pixel square (派单 009 C).
    ///
    /// Upright, not stored: the eyedropper works in the coordinates the user sees, and the
    /// orientation is undone here through the one table that defines it (`sourceCoordinate`), so a
    /// rotated file cannot sample a transposed point. The box average is what every raw converter's
    /// dropper does — a single pixel of a 60 MP frame is noise, and a 3×3 mean is still "that spot".
    public func averageRGB(x: Int, y: Int, radius: Int = 1) -> RGBSample {
        let (w, h) = uprightSize
        let cx = Swift.min(Swift.max(x, 0), w - 1)
        let cy = Swift.min(Swift.max(y, 0), h - 1)
        let r = Swift.max(0, radius)
        var acc = (0.0, 0.0, 0.0)
        var n = 0.0
        for dy in -r...r {
            let yy = Swift.min(Swift.max(cy + dy, 0), h - 1)
            for dx in -r...r {
                let xx = Swift.min(Swift.max(cx + dx, 0), w - 1)
                let s = orientation.sourceCoordinate(x: xx, y: yy, width: width, height: height)
                let o = (s.y * width + s.x) * 4
                acc.0 += Double(rgba[o])
                acc.1 += Double(rgba[o + 1])
                acc.2 += Double(rgba[o + 2])
                n += 1
            }
        }
        guard n > 0 else { return .black }
        return RGBSample(r: acc.0 / n, g: acc.1 / n, b: acc.2 / n)
    }

    /// Mean colour of the whole picture, sampled on a stride — the grey-world input for Auto WB.
    ///
    /// A stride rather than every pixel: the mean of 60 M samples and of every 8th one agree to
    /// well under a percent, and this runs on the main thread when the user picks 自动.
    public func meanRGB(stride: Int = 8) -> RGBSample {
        let step = Swift.max(1, stride)
        let (w, h) = uprightSize
        var acc = (0.0, 0.0, 0.0)
        var n = 0.0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let s = orientation.sourceCoordinate(x: x, y: y, width: width, height: height)
                let o = (s.y * width + s.x) * 4
                acc.0 += Double(rgba[o])
                acc.1 += Double(rgba[o + 1])
                acc.2 += Double(rgba[o + 2])
                n += 1
                x += step
            }
            y += step
        }
        guard n > 0 else { return .black }
        return RGBSample(r: acc.0 / n, g: acc.1 / n, b: acc.2 / n)
    }

    /// Mean luma of the top and bottom halves, in **row** terms (row 0 = top).
    ///
    /// This is the objective "which way up is this?" measurement used by the orientation tests: a
    /// scene with a sky and a ground has a different vertical gradient in one direction than the
    /// other, and a flipped decode inverts it.
    public func halfMeans(sampleStride: Int = 5) -> (top: Double, bottom: Double) {
        var top = 0.0, bottom = 0.0
        var nt = 0, nb = 0
        let half = height / 2
        var y = 0
        while y < height {
            let row = y * width
            var x = 0
            while x < width {
                let o = (row + x) * 4
                let w = ColorPrimaries.working.luminanceWeights
                let l = w.x * Double(rgba[o]) + w.y * Double(rgba[o + 1]) + w.z * Double(rgba[o + 2])
                if y < half { top += l; nt += 1 } else { bottom += l; nb += 1 }
                x += sampleStride
            }
            y += 1
        }
        return (top / Double(Swift.max(nt, 1)), bottom / Double(Swift.max(nb, 1)))
    }

    /// Downscale to a smaller linear image by box averaging (M0-quality; replaced by a
    /// mip chain in M3). Keeps the pipeline honest in tests without a second code path.
    public func downscaled(factor: Int) -> LinearImage {
        guard factor > 1 else { return self }
        let nw = Swift.max(1, width / factor)
        let nh = Swift.max(1, height / factor)
        var out = [Float16](repeating: 0, count: nw * nh * 4)
        let inv = 1.0 / Float(factor * factor)
        for y in 0..<nh {
            for x in 0..<nw {
                var acc: [Float] = [0, 0, 0, 0]
                for dy in 0..<factor {
                    let sy = Swift.min(y * factor + dy, height - 1)
                    for dx in 0..<factor {
                        let sx = Swift.min(x * factor + dx, width - 1)
                        let o = (sy * width + sx) * 4
                        for c in 0..<4 { acc[c] += Float(rgba[o + c]) }
                    }
                }
                let o = (y * nw + x) * 4
                for c in 0..<4 { out[o + c] = Float16(acc[c] * inv) }
            }
        }
        return LinearImage(width: nw, height: nh, rgba: out, colorSpace: colorSpace,
                           decoderVersion: decoderVersion, orientation: orientation)
    }
}
