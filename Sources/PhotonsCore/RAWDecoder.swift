import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Metal

public struct DecodeOptions: Sendable {
    /// Decoder version requested from the system RAW pipeline, e.g. `"8"`, `"9"`, `"9.dng"`.
    /// `nil` means "whatever Apple defaults to for this file" (measured to be v8 today).
    ///
    /// A request the body does not whitelist is **not** an error: the filter silently keeps its old
    /// value, so `RAWDecoder` reads the version back and reports the effective one
    /// (`DecoderCapabilities`, docs/architecture-decisions.md §11.1 / D2′).
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
    /// §11.3: lens correction is a **per-file** fact, never a per-camera one — the EOS R5 + Sigma
    /// 50/1.4 CR3 body reports the switch as unavailable while RW2/RAF from the same era honour it.
    /// So this is `isLensCorrectionSupported` *and* a successful toggle-and-read-back on this very
    /// file; a body that claims support but keeps the old value must read `false` here, because a
    /// UI toggle that cannot change pixels is a lie.
    public let lensCorrectionSupported: Bool
    /// The value `isLensCorrectionEnabled` came back with, after the probe restored it.
    public let lensCorrectionEnabled: Bool
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
                        iso: iso,
                        lensCorrectionSupported: Self.probeLensCorrection(filter),
                        lensCorrectionEnabled: filter.isLensCorrectionEnabled)
    }

    /// Toggle-and-read-back, on this file only (§11.3).
    ///
    /// `isLensCorrectionSupported` alone is not enough: the flag is a claim, and a claim that does
    /// not survive assignment would put a dead switch in the inspector. We flip the value, read it
    /// back, and restore — the restore matters because the same `CIRAWFilter` is about to be used
    /// for the capabilities of the file, and a left-on correction silently changes pixels.
    static func probeLensCorrection(_ filter: CIRAWFilter) -> Bool {
        guard filter.isLensCorrectionSupported else { return false }
        let original = filter.isLensCorrectionEnabled
        filter.isLensCorrectionEnabled = !original
        let toggled = filter.isLensCorrectionEnabled
        filter.isLensCorrectionEnabled = original
        return toggled == !original && filter.isLensCorrectionEnabled == original
    }

    // MARK: - decode

    /// A decoded buffer plus the decoder facts that shaped it.
    ///
    /// The pixel hash alone cannot tell you that a v9 request silently became v8; `capabilities`
    /// can, and the UI has to say so (§11.1: 69 bodies offer v9, 941 do not).
    public struct DecodeOutcome: Sendable {
        public let image: LinearImage
        public let capabilities: DecoderCapabilities
    }

    /// Test hook: `resolve` is what a read-back proves. Kept here so the decode path and the test
    /// cannot drift apart.
    public static func resolveVersion(_ requested: String?, offered: [String],
                                      filterDefault: String) -> (effective: String, downgraded: Bool) {
        DecoderCapabilities.resolve(requested: requested, offered: offered, filterDefault: filterDefault)
    }

    public func decode(_ url: URL, options: DecodeOptions = DecodeOptions()) throws -> LinearImage {
        try decodeDetailed(url, options: options).image
    }

    public func decodeDetailed(_ url: URL, options: DecodeOptions = DecodeOptions()) throws -> DecodeOutcome {
        guard let filter = CIRAWFilter(imageURL: url) else { throw DecodeError.unsupportedFile(url) }

        let offered = filter.supportedDecoderVersions.map { Self.versionString($0) }
        let filterDefault = Self.versionString(filter.decoderVersion)

        // ── 前置 ① D2′: v8 default + read-back assert ────────────────────────────────────────
        // Assign, then read back. A body that does not whitelist the request keeps the old value
        // (measurably: v9 on an SL3 stays v8), so the read-back — not the assignment — is the
        // truth. On a mismatch we pin the D2′ default and report `effectiveVersion`.
        var effective = filterDefault
        if let wanted = options.decoderVersion {
            guard DecoderCapabilities.knownVersions.contains(wanted) else {
                throw DecodeError.unsupportedVersion(requested: wanted, available: offered)
            }
            filter.decoderVersion = CIRAWDecoderVersion(rawValue: wanted)
            effective = Self.versionString(filter.decoderVersion)
            if effective != wanted {
                // Downgrade explicitly, then re-read: reporting the *requested* version here is
                // exactly the bug the read-back exists to catch.
                filter.decoderVersion = CIRAWDecoderVersion(
                    rawValue: DecoderCapabilities.preferredDefault(offered: offered, filterDefault: filterDefault))
                effective = Self.versionString(filter.decoderVersion)
            }
        }

        // ── 前置 ② explicit linear ──────────────────────────────────────────────────────────
        // §11.4: with the default boost/gamut-mapping, +1 EV is *not* a factor of two (measured
        // 2.03–2.66); with both off it is 2.0063. §11.8: the same two switches decide whether the
        // EDR headroom survives at all (1.018 → 1.695 on the same file), so this is also the
        // data-side precondition for EDR.
        filter.boostAmount = 0
        filter.isGamutMappingEnabled = false

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
        let image = LinearImage(width: w, height: h, rgba: rgba,
                                colorSpace: colorSpaceID.rawValue, decoderVersion: effective)
        let capabilities = DecoderCapabilities(requestedVersion: options.decoderVersion,
                                               effectiveVersion: effective,
                                               defaultVersion: filterDefault)
        return DecodeOutcome(image: image, capabilities: capabilities)
    }
}
