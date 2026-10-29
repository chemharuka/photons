import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import PhotonsCore

// MARK: - 111 · PQ / HLG output
//
// The S4 exit gives us extended-range **linear** pixels in the preset's primaries. Writing PQ or HLG
// is then a colour-space conversion, not a hand-written ST 2084 / BT.2100 curve: Core Image maps the
// linear source to `itur_2100_PQ` / `itur_2100_HLG` and we let ImageIO pack the result. The curve
// constants therefore live in exactly one place (CoreGraphics' colour management), and a future
// change to the target space is a one-line edit here.
//
// Outputs:
//   · HEIC / AVIF — RGBA16 handed to ImageIO, which stores the 10-bit HEVC/AV1 primary item
//     (measured: asking for 16 reads back 10; the container has no 16-bit mode).
//   · TIFF / PNG  — RGBA16, read back as 16.
public enum HDREncoding {

    /// The linear source space matching the renderer's primaries. `CIImage` must be told what the
    /// half-float samples mean, otherwise Core Image assumes linear sRGB and a P3/Rec.2020 export is
    /// converted through the wrong matrix.
    public static func linearColorSpace(for primaries: OutputPrimaries) -> CGColorSpace? {
        switch primaries {
        case .sRGB: return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        case .displayP3: return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        case .rec2020: return CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        }
    }

    /// Rec.2020 with the requested transfer function. `nil` for every non-PQ/HLG kind.
    public static func targetColorSpace(for kind: HDRKind) -> CGColorSpace? {
        switch kind {
        case .pq: return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case .hlg: return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        case .none, .gainMap: return nil
        }
    }

    /// Convert `image`'s linear companion to a PQ/HLG-tagged `CGImage`.
    ///
    /// The linear samples are handed over as half floats (no clamp), so highlights above display
    /// white survive into the PQ code space instead of being flattened at 1.0.
    public static func cgImage(for image: DisplayImage, kind: HDRKind) throws -> CGImage {
        guard kind == .hlg || kind == .pq else {
            throw ExportError.encodeFailed("\(kind.rawValue) is not a PQ/HLG kind")
        }
        guard let linear = image.linear else {
            throw ExportError.encodeFailed(
                "\(kind.displayName) export needs the linear render (s4_display_linear)")
        }
        guard linear.width == image.width, linear.height == image.height else {
            throw ExportError.encodeFailed(
                "linear render is \(linear.width)×\(linear.height) but the SDR base is "
                + "\(image.width)×\(image.height)")
        }
        guard let source = linearColorSpace(for: image.primaries) else {
            throw ExportError.encodeFailed(
                "linear color space unavailable: \(image.primaries.displayName)")
        }
        guard let target = targetColorSpace(for: kind) else {
            throw ExportError.encodeFailed("\(kind.displayName) color space unavailable")
        }

        // `CIImage(bitmapData:)` reads row 0 as the bottom row; DisplayImage stores the top row
        // first, so flip the rows once here (the alternative is a transform whose extent starts at
        // a negative y, which then has to be cropped again).
        let w = image.width, h = image.height
        var rows = [Float16](repeating: 0, count: w * h * 4)
        linear.rgba.withUnsafeBufferPointer { src in
            rows.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let from = y * w * 4
                    let to = (h - 1 - y) * w * 4
                    for i in 0..<(w * 4) { dst[to + i] = src[from + i] }
                }
            }
        }
        let data = rows.withUnsafeBufferPointer { Data(buffer: $0) }
        let ci = CIImage(bitmapData: data, bytesPerRow: w * 8,
                         size: CGSize(width: w, height: h), format: .RGBAh, colorSpace: source)
        // Pin both working and output space: letting Core Image pick a working space would route a
        // P3 picture through linear sRGB before the Rec.2020 conversion.
        let context = CIContext(options: [.workingColorSpace: source, .outputColorSpace: target])
        guard let out = context.createCGImage(ci, from: ci.extent, format: .RGBA16,
                                              colorSpace: target) else {
            throw ExportError.encodeFailed("Core Image could not convert to \(kind.displayName)")
        }
        return out
    }

    /// Write a PQ/HLG file. Returns non-fatal notes (empty on the normal path).
    @discardableResult
    public static func write(_ image: DisplayImage, to url: URL, options: ExportOptions,
                             metadata: ExportMetadataContext = ExportMetadataContext())
        throws -> [String] {
        guard let kind = options.hdr?.kind, kind == .hlg || kind == .pq else {
            throw ExportError.encodeFailed("not a PQ/HLG export")
        }
        let cg = try cgImage(for: image, kind: kind)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, options.format.utType.identifier as CFString, 1, nil) else {
            throw ExportError.destinationFailed(url)
        }
        var properties = metadata.properties(outputWidth: image.width, outputHeight: image.height,
                                             format: options.format)
        if options.format.supportsQuality {
            // AVIF's HDR path rejects quality 1.0 (`CGImageDestinationFinalize` returns false);
            // 0.99 is still visually lossless and keeps the file writable.
            let quality = options.format == .avif ? min(options.quality, 0.99) : options.quality
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if let xmp = metadata.xmpMetadata(outputWidth: image.width,
                                          outputHeight: image.height) {
            CGImageDestinationAddImageAndMetadata(dest, cg, xmp, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.finalizeFailed(url)
        }
        // The PNG writer always emits its own EXIF block; `.none` means none (107).
        if metadata.level == .none && options.format == .png {
            try Exporter.stripMetadata(at: url)
        }
        return []
    }
}
