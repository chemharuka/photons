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

    public var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .tiff: return "tif"
        }
    }

    public var supportsQuality: Bool {
        self == .jpeg || self == .heic
    }

    /// Formats that can carry 16 bits per channel.
    public var supports16Bit: Bool {
        self != .jpeg
    }
}

public struct ExportOptions: Sendable {
    public var format: ExportFormat
    public var quality: Double        // 0…1, lossy formats only
    public var bitDepth: Int          // 8 or 16

    public init(format: ExportFormat = .jpeg, quality: Double = 0.95, bitDepth: Int = 8) {
        self.format = format
        self.quality = quality
        self.bitDepth = bitDepth
    }

    public static func detect(from url: URL) -> ExportOptions {
        switch url.pathExtension.lowercased() {
        case "heic", "heif": return ExportOptions(format: .heic)
        case "tif", "tiff": return ExportOptions(format: .tiff, bitDepth: 16)
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

    public static func write(_ image: DisplayImage, to url: URL, options: ExportOptions) throws {
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
        var properties: [CFString: Any] = [:]
        if options.format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.finalizeFailed(url)
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
