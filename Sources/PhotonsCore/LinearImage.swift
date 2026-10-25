import Foundation
import CryptoKit

/// A decoded image in linear light: RGBA, half precision, row-major, not premultiplied.
///
/// This is the single pixel truth of the pipeline (see docs/architecture-decisions.md §3 D4).
/// Everything downstream (editing graph, thumbnails, export) reads from this representation,
/// never from the RAW file directly.
public struct LinearImage: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [Float16]
    /// Name of the linear color space the samples are in (e.g. `extendedLinearSRGB`).
    public let colorSpace: String
    /// Decoder version the samples were produced with (e.g. `"8"`, `"9.dng"`).
    public let decoderVersion: String

    public init(width: Int, height: Int, rgba: [Float16], colorSpace: String, decoderVersion: String) {
        precondition(rgba.count == width * height * 4, "rgba must be width*height*4")
        self.width = width
        self.height = height
        self.rgba = rgba
        self.colorSpace = colorSpace
        self.decoderVersion = decoderVersion
    }

    public var byteCount: Int { rgba.count * MemoryLayout<Float16>.size }

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
            sum += Double(0.2126 * r + 0.7152 * g + 0.0722 * b)
            n += 1
            i += sampleStride
        }
        return Statistics(maxChannel: maxV,
                          meanLuma: Float(sum / Double(Swift.max(n, 1))),
                          overUnityRatio: Double(over) / Double(Swift.max(n, 1)))
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
        return LinearImage(width: nw, height: nh, rgba: out, colorSpace: colorSpace, decoderVersion: decoderVersion)
    }
}
