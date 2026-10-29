import Foundation
import PhotonsCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - formats

public enum ExportFormat: String, Sendable, CaseIterable {
    case jpeg
    case heic
    case tiff
    /// Lossless, 8/16-bit, and the one container ImageIO cannot copy-image-source — XMP embedding
    /// re-encodes (docs/xmp-mapping.md §4.2).
    case png
    /// AVIF is free on macOS 14+: ImageIO ships the encoder, so it costs no dependency
    /// (docs/architecture-decisions.md §11.5). 8-bit only in practice.
    case avif

    public var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        case .png: return .png
        case .avif: return UTType("public.avif") ?? UTType(filenameExtension: "avif") ?? .heic
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .tiff: return "tif"
        case .png: return "png"
        case .avif: return "avif"
        }
    }

    public var supportsQuality: Bool {
        self == .jpeg || self == .heic || self == .avif
    }

    /// Formats that can carry 16 bits per channel. AVIF is nominally 10/12-bit; asking ImageIO for
    /// 16 bpc on this path produces a file that reads back as 8, so it is not offered.
    public var supports16Bit: Bool {
        switch self {
        case .jpeg, .avif: return false
        case .heic, .tiff, .png: return true
        }
    }

    /// Containers ImageIO can rewrite in place with XMP (`XMPWriter.canEmbed`). AVIF is absent:
    /// ImageIO's AVIF path drops the packet, so the writer falls back to a sidecar.
    public var supportsXMPEmbedding: Bool {
        self != .avif
    }
}

public struct ExportOptions: Sendable {
    public var format: ExportFormat
    public var quality: Double        // 0…1, lossy formats only
    public var bitDepth: Int          // 8 or 16
    /// 100 — HEIC + gain map. `nil` = the pre-HDR encoder path, byte for byte.
    public var hdr: HDRExport?

    public init(format: ExportFormat = .jpeg, quality: Double = 0.95, bitDepth: Int = 8,
                hdr: HDRExport? = nil) {
        self.format = format
        self.quality = quality
        self.bitDepth = bitDepth
        self.hdr = hdr
    }

    public static func detect(from url: URL) -> ExportOptions {
        switch url.pathExtension.lowercased() {
        case "heic", "heif": return ExportOptions(format: .heic)
        case "tif", "tiff": return ExportOptions(format: .tiff, bitDepth: 16)
        case "png": return ExportOptions(format: .png)
        case "avif": return ExportOptions(format: .avif)
        default: return ExportOptions(format: .jpeg)
        }
    }
}

public enum ExportError: LocalizedError {
    case badBitDepth(String, Int)
    case bitmapContextFailed
    case destinationFailed(URL)
    case finalizeFailed(URL)
    case encodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .badBitDepth(let f, let b): return "\(f) cannot be written at \(b) bits per channel"
        case .bitmapContextFailed: return "could not build the output bitmap"
        case .destinationFailed(let u): return "could not create an image destination at \(u.path)"
        case .finalizeFailed(let u): return "could not finalize \(u.lastPathComponent)"
        case .encodeFailed(let m): return "encoding failed: \(m)"
        }
    }
}

// MARK: - encoder

/// Turns display-encoded pixels into a file. Everything here is ImageIO: no libheif, no x265, no
/// third-party encoder (docs/architecture-decisions.md D1 / licensing.md).
///
/// The pixels arrive already OETF-encoded and tagged with their primaries (S4 did that), so this
/// layer only packs them into a `CGImage` and lets ImageIO write the container.
public enum Exporter {

    public static func colorSpace(for primaries: OutputPrimaries) -> CGColorSpace? {
        switch primaries {
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)
        // Rec.2020 primaries, sRGB transfer — the tag a 16-bit TIFF/PNG (or 10-bit HEIC) should carry.
        case .rec2020: return CGColorSpace(name: CGColorSpace.itur_2020)
        }
    }

    public static func cgImage(_ image: DisplayImage, bitDepth: Int) throws -> CGImage {
        guard let space = colorSpace(for: image.primaries) else {
            throw ExportError.encodeFailed("color space unavailable: \(image.primaries.displayName)")
        }
        let w = image.width, h = image.height
        let count = w * h * 4

        if bitDepth == 8 {
            var bytes = [UInt8](repeating: 0, count: count)
            for i in 0..<count {
                bytes[i] = UInt8(min(max(Float(image.rgba[i]), 0), 1) * 255 + 0.5)
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: w * 4, space: space,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false,
                                   intent: .defaultIntent) else {
                throw ExportError.bitmapContextFailed
            }
            return cg
        }

        guard bitDepth == 16 else {
            throw ExportError.badBitDepth("image", bitDepth)
        }
        var words = [UInt16](repeating: 0, count: count)
        for i in 0..<count {
            words[i] = UInt16(min(max(Float(image.rgba[i]), 0), 1) * 65535 + 0.5)
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let provider = CGDataProvider(data: Data(words.withUnsafeBufferPointer { Data(buffer: $0) }) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64,
                               bytesPerRow: w * 8, space: space, bitmapInfo: info,
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else {
            throw ExportError.bitmapContextFailed
        }
        return cg
    }

    /// Write `image`. When `options.hdr` is enabled **and** the image carries a linear companion
    /// (rendered through `s4_display_linear`), this routes to `GainMapHEIC`, which writes the same SDR
    /// base plus a gain-map auxiliary image. Otherwise it is the untouched pre-100 encoder.
    ///
    /// - Returns: non-fatal HDR notes (an SDR fallback, a clipped headroom). Empty on the normal path.
    @discardableResult
    public static func write(_ image: DisplayImage, to url: URL, options: ExportOptions,
                             metadata: ExportMetadataContext = ExportMetadataContext()) throws -> [String] {
        if let hdr = options.hdr, hdr.enabled, options.format == .heic, let linear = image.linear {
            let result = try GainMapHEIC.write(sdr: image, linear: linear, to: url,
                                               options: HDRGainMapOptions(gainMap: hdr.gainMap,
                                                                          halfSize: hdr.halfSize,
                                                                          headroom: hdr.headroom,
                                                                          quality: options.quality,
                                                                          bitDepth: options.bitDepth),
                                               metadata: metadata)
            return result.warnings
        }
        guard options.bitDepth == 8 || (options.bitDepth == 16 && options.format.supports16Bit) else {
            throw ExportError.badBitDepth(options.format.rawValue, options.bitDepth)
        }
        let cg = try cgImage(image, bitDepth: options.bitDepth)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         options.format.utType.identifier as CFString,
                                                         1, nil) else {
            throw ExportError.destinationFailed(url)
        }
        var properties = metadata.properties(outputWidth: image.width, outputHeight: image.height,
                                             format: options.format)
        if options.format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
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
        // PNG's writer always adds its own EXIF block (colour space + dimensions) even when asked
        // for nothing, and unlike JPEG it rejects the `NSNull` marker. A copy-image-source pass with
        // an empty metadata object removes it without re-encoding the pixels.
        if metadata.level == .none && options.format == .png {
            try stripMetadata(at: url)
        }
        return []
    }

    /// Rewrites `url` through `CGImageDestinationCopyImageSource` with an empty metadata object.
    /// Used only for `.none` PNG, whose writer cannot be told to omit EXIF in the first place.
    private static func stripMetadata(at url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).strip-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL,
                                                         ExportFormat.png.utType.identifier as CFString,
                                                         1, nil) else {
            throw ExportError.encodeFailed("cannot reopen \(url.lastPathComponent) to strip metadata")
        }
        let empty = CGImageMetadataCreateMutable()
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, source,
                                                [kCGImageDestinationMetadata: empty] as CFDictionary,
                                                &error) else {
            let why = error.map { ($0.takeRetainedValue() as Error).localizedDescription }
                ?? "copy failed"
            try? FileManager.default.removeItem(at: tmp)
            throw ExportError.encodeFailed("could not strip metadata: \(why)")
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw ExportError.encodeFailed("could not replace \(url.lastPathComponent): "
                                           + error.localizedDescription)
        }
    }

    /// Encode in memory (determinism tests compare digests without touching the filesystem).
    public static func data(_ image: DisplayImage, options: ExportOptions) throws -> Data {
        let cg = try cgImage(image, bitDepth: options.bitDepth)
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buffer as CFMutableData,
                                                          options.format.utType.identifier as CFString,
                                                          1, nil) else {
            throw ExportError.destinationFailed(URL(fileURLWithPath: "<memory>"))
        }
        var properties: [CFString: Any] = [:]
        if options.format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.finalizeFailed(URL(fileURLWithPath: "<memory>"))
        }
        return buffer as Data
    }
}
