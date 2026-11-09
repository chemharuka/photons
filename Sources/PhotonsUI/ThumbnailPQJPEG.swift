import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import PhotonsCore

/// 308 — the **1920 px, 8-bit Display P3 PQ JPEG** encoder, written by hand.
///
/// The brief said the obvious route tone-maps — `CGContext(bitsPerComponent: 8, space:
/// displayP3_PQ)` + `draw(pq image)` turning a 2.033 peak into 0.765. **Measured, that is only true
/// of an untagged source.** On 6 RAWs, drawing a correctly tagged 16-bit PQ `CGImage` into that same
/// context gives the identical peak as the manual quantiser (Δ 0.0 % on all 6, and on the cached HD
/// HEIC); drawing the *untagged* `CGImage` that `CGImageSourceCreateImageAtIndex` hands back for a
/// HEIC (its `colorSpace` is `nil` — 226's finding) loses half the headroom: 1.133 → 0.563. That is
/// the mechanism behind the 0.765 observation, and it is a property of the source, not of the
/// destination.
///
/// So this file is **not** a workaround for a broken context. It exists for controllability: the
/// codes are produced by arithmetic this code owns (dither on/off, 8-bit now, 10-bit later), every
/// step is readable in a test, and nothing depends on which profile a decoded image happens to
/// carry. It is also the only way to *state* the PQ quantisation in one place instead of trusting
/// two colour-management paths to agree.
///
/// The path, in order:
///
///   1. Core Image renders the linear half-float render into a **`.RGBA16` integer** buffer whose
///      colour space is `displayP3_PQ`. Integer, not `.RGBAh` (half floats come back with garbage
///      codes — measured) and not `.RGBAf`; ColorSync performs the PQ OETF + the 203-nit
///      reference-white mapping exactly once, on the way in.
///   2. Optional 8×8 ordered dither (off by default; see `bayerOffset` for the measurements).
///   3. `code8 = (code16 + 128) / 257` — PQ is monotonic, and 65535/255 = 257 exactly, so this is
///      a plain rounding of the 16-bit code rather than a second transfer function.
///   4. `CGDataProvider` → `CGImage` (8 bpc, `noneSkipLast`, space = `displayP3_PQ`) →
///      `CGImageDestination` JPEG q0.75. ImageIO embeds the PQ ICC profile (`sips -g profile`:
///      `Display P3; SMPTE ST 2084 PQ`).
///
/// The decode is ImageIO's thumbnail door at the cell's pixel size, not a full-size decode plus a
/// resize: see `ThumbnailProvider.decodeJPEG`.
enum ThumbnailPQJPEG {

    static var pqSpace: CGColorSpace? { CGColorSpace(name: CGColorSpace.displayP3_PQ) }
    static var linearSpace: CGColorSpace? { CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) }

    /// Encode `linear` (display P3, extended-range half floats) as a PQ JPEG whose long edge is at
    /// most `longEdge`. Returns `nil` only when Core Graphics refuses a bitmap — never a silently
    /// tone-mapped file.
    static func encode(linear: LinearPixels, longEdge: Int, quality: Double,
                       dither: Bool = false) -> Data? {
        guard let image = eightBitPQImage(linear: linear, longEdge: longEdge,
                                          ditherAmplitude: dither ? 64 : 0) else {
            return nil
        }
        return jpeg(from: image, quality: quality)
    }

    /// Steps 1–4a: the linear render as an **8-bit** `CGImage` tagged `displayP3_PQ`. Exposed
    /// (internal) so a test can read the codes back before JPEG's lossy step.
    /// `ditherAmplitude` is in **16-bit code units**: 0 = plain rounding, 64 = ±0.25 of an 8-bit
    /// step (the shipped option), 257 = ±1 full 8-bit code (an experiment: does it kill the ringing
    /// a hard highlight edge produces at q0.75?).
    static func eightBitPQImage(linear: LinearPixels, longEdge: Int,
                                ditherAmplitude: Int = 0) -> CGImage? {
        let w = linear.width, h = linear.height
        guard w > 0, h > 0, linear.rgba.count >= w * h * 4,
              let pq = pqSpace, let lin = linearSpace else { return nil }
        let scale = min(1, Double(longEdge) / Double(max(w, h)))
        let tw = max(1, Int((Double(w) * scale).rounded()))
        let th = max(1, Int((Double(h) * scale).rounded()))

        let pixels = linear.rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        let source = CIImage(bitmapData: pixels, bytesPerRow: w * 8,
                             size: CGSize(width: w, height: h), format: .RGBAh, colorSpace: lin)
        // 238 — `CIImage(bitmapData:)` maps row 0 to row 0 of the picture, and
        // `CIContext.render(toBitmap:)` writes that same row order (verified with a two-row probe:
        // both rows land where the source put them), so a thumbnail is not upside down.
        let scaled = (tw == w && th == h) ? source
            : source.transformed(by: CGAffineTransform(scaleX: CGFloat(tw) / CGFloat(w),
                                                       y: CGFloat(th) / CGFloat(h)))

        // Both working and output space pinned: an unpinned working space would route a P3 picture
        // through linear sRGB before the PQ encode, which is the same class of bug as the tone map.
        let context = CIContext(options: [.workingColorSpace: lin, .outputColorSpace: pq,
                                          .cacheIntermediates: false])
        var codes = [UInt16](repeating: 0, count: tw * th * 4)
        codes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(scaled, toBitmap: base, rowBytes: tw * 8,
                           bounds: CGRect(x: 0, y: 0, width: tw, height: th),
                           format: .RGBA16, colorSpace: pq)
        }

        // (code16 + 128) / 257, with an optional ordered dither of ±0.5 LSB(8) in 16-bit units.
        var out = [UInt8](repeating: 255, count: tw * th * 4)
        for y in 0..<th {
            let rowOffset = (y & 7) * 8
            for x in 0..<tw {
                let i = (y * tw + x) * 4
                let offset = ditherAmplitude == 0 ? 0
                    : Self.bayerOffset(rowOffset + (x & 7), amplitude: ditherAmplitude)
                for c in 0..<3 {
                    let rounded = (Int(codes[i + c]) + 128 + offset) / 257
                    out[i + c] = UInt8(min(255, max(0, rounded)))
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let image = CGImage(width: tw, height: th, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: tw * 4, space: pq,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        return image
    }

    /// 8×8 Bayer matrix, scaled to 16-bit units in [-64, +64): ±0.25 of an 8-bit step.
    ///
    /// **Off by default**, and measured rather than assumed. On the 0.01→4.0 ramp: plain rounding
    /// leaves a 0.107 EV max residual at full size and 0.049 EV once the decode downsamples to a
    /// 460 px cell; ±0.25 LSB gives 0.054 at full size and 0.051 at cell size; ±0.5 LSB gives 0.059
    /// and 0.058. So dithering only rebalances error between the two readings — it does nothing at
    /// the size this file is actually shown at (the cell), and every level tested is stuck near the
    /// 0.0545 EV half-code floor that 8-bit PQ has at 0.01 linear. Skipping it also saves a pass over
    /// 2.4 M pixels. Kept as an option so the claim can be re-measured instead of trusted.
    static func bayerOffset(_ index: Int, amplitude: Int = 64) -> Int {
        Self.bayer[index % 64] * 2 * amplitude / 63 - amplitude
    }

    private static let bayer: [Int] = [
         0, 32,  8, 40,  2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44,  4, 36, 14, 46,  6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
         3, 35, 11, 43,  1, 33,  9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47,  7, 39, 13, 45,  5, 37,
        63, 31, 55, 23, 61, 29, 53, 21,
    ]

    /// Step 4b — the JPEG container. The profile travels in the file (ImageIO writes the
    /// `displayP3_PQ` ICC as APP2), which is what makes the decoder's explicit PQ tagging agree with
    /// what `sips -g profile` reports.
    static func jpeg(from image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
