import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Metal

public struct DecodeOptions: Sendable {
    /// Decoder version requested from the system RAW pipeline, e.g. `"8"`, `"9"`, `"9.dng"`.
    /// `nil` means "whatever Apple defaults to for this file" (measured to be v8 today).
    public var decoderVersion: String?
    public var exposureEV: Float
    public var scale: Float
    public var draft: Bool
    public var colorSpace: LinearColorSpace

    public init(decoderVersion: String? = nil,
                exposureEV: Float = 0,
                scale: Float = 1,
                draft: Bool = false,
                colorSpace: LinearColorSpace = .extendedLinearSRGB) {
        self.decoderVersion = decoderVersion
        self.exposureEV = exposureEV
        self.scale = scale
        self.draft = draft
        self.colorSpace = colorSpace
    }
}

/// The only working spaces the pipeline is allowed to use: unbounded linear light.
///
/// `CGColorSpace(name:)` takes the *CFString constant* value, not a friendly name —
/// passing "extendedLinearSRGB" silently returns nil. Hence this enum.
public enum LinearColorSpace: String, Sendable, CaseIterable {
    case extendedLinearSRGB
    case extendedLinearDisplayP3

    public var cgColorSpace: CGColorSpace? {
        switch self {
        case .extendedLinearSRGB: return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        case .extendedLinearDisplayP3: return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        }
    }
}

public enum DecodeError: LocalizedError {
    case unsupportedFile(URL)
    case noMetalDevice
    case unavailableColorSpace(String)
    case unsupportedVersion(requested: String, available: [String])
    case renderFailed
    case badDimensions(CGSize)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let u): return "not a decodable RAW/JPEG: \(u.lastPathComponent)"
        case .noMetalDevice: return "no Metal device"
        case .unavailableColorSpace(let n): return "color space not available: \(n)"
        case .unsupportedVersion(let r, let a): return "decoder version '\(r)' not offered by this file; available: \(a.joined(separator: ", "))"
        case .renderFailed: return "CIRAWFilter produced no image (or the version was rejected)"
        case .badDimensions(let s): return "unusable dimensions \(s)"
        }
    }
}

/// What the system RAW pipeline reports about one file.
public struct RAWProbe: Sendable {
    public let supportedVersions: [String]
    public let defaultVersion: String
    public let nativeWidth: Int
    public let nativeHeight: Int
    public let make: String?
    public let model: String?
    public let iso: Int?
}

public final class RAWDecoder {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let ciContext: CIContext
    private let colorSpace: CGColorSpace
    private let colorSpaceID: LinearColorSpace

    public init(colorSpace: LinearColorSpace = .extendedLinearSRGB) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw DecodeError.noMetalDevice }
        guard let queue = device.makeCommandQueue() else { throw DecodeError.noMetalDevice }
        guard let cs = colorSpace.cgColorSpace else { throw DecodeError.unavailableColorSpace(colorSpace.rawValue) }
        self.device = device
        self.queue = queue
        self.colorSpace = cs
        self.colorSpaceID = colorSpace
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: cs,
            .outputColorSpace: cs,
            .cacheIntermediates: false,
        ])
    }

    public var deviceName: String { device.name }

    // MARK: - version helpers

    public static func versionString(_ v: CIRAWDecoderVersion) -> String { v.rawValue }

    public static func availableVersions(for url: URL) throws -> [String] {
        guard let filter = CIRAWFilter(imageURL: url) else { throw DecodeError.unsupportedFile(url) }
        return filter.supportedDecoderVersions.map { versionString($0) }
    }

    public func probe(_ url: URL) throws -> RAWProbe {
        guard let filter = CIRAWFilter(imageURL: url) else { throw DecodeError.unsupportedFile(url) }
        let versions = filter.supportedDecoderVersions.map { Self.versionString($0) }
        let props = filter.properties
        let tiff = (props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
            ?? (props["{TIFF}"] as? [String: Any])
        let exif = (props[kCGImagePropertyExifDictionary as String] as? [String: Any])
            ?? (props["{Exif}"] as? [String: Any])
        var iso: Int?
        if let arr = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int] { iso = arr.first }
        else if let arr = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Any] { iso = (arr.first as? NSNumber)?.intValue }

        return RAWProbe(supportedVersions: versions,
                        defaultVersion: Self.versionString(filter.decoderVersion),
                        nativeWidth: Int(filter.nativeSize.width),
                        nativeHeight: Int(filter.nativeSize.height),
                        make: tiff?[kCGImagePropertyTIFFMake as String] as? String,
                        model: tiff?[kCGImagePropertyTIFFModel as String] as? String,
                        iso: iso)
    }

    // MARK: - decode

    public func decode(_ url: URL, options: DecodeOptions = DecodeOptions()) throws -> LinearImage {
        guard let filter = CIRAWFilter(imageURL: url) else { throw DecodeError.unsupportedFile(url) }

        let offered = filter.supportedDecoderVersions.map { Self.versionString($0) }
        var usedVersion = Self.versionString(filter.decoderVersion)
        if let wanted = options.decoderVersion {
            guard let match = filter.supportedDecoderVersions.first(where: { Self.versionString($0) == wanted }) else {
                throw DecodeError.unsupportedVersion(requested: wanted, available: offered)
            }
            filter.decoderVersion = match
            usedVersion = wanted
        }
        filter.isDraftModeEnabled = options.draft
        filter.scaleFactor = options.scale
        filter.exposure = options.exposureEV

        guard let output = filter.outputImage else { throw DecodeError.renderFailed }
        let extent = output.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0 else { throw DecodeError.badDimensions(extent.size) }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                           width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        // .shared so we can read back without a blit; revisited in M1 with a private
        // texture + MTLBuffer copy once the cache format is settled.
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { throw DecodeError.renderFailed }

        guard let cb = queue.makeCommandBuffer() else { throw DecodeError.renderFailed }
        ciContext.render(output, to: texture, commandBuffer: cb,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h),
                         colorSpace: colorSpace)
        cb.commit()
        cb.waitUntilCompleted()

        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!,
                             bytesPerRow: w * 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(0, 0, w, h),
                             mipmapLevel: 0)
        }
        let rgba = raw.map { Float16(bitPattern: $0) }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: colorSpaceID.rawValue, decoderVersion: usedVersion)
    }
}
