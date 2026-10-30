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
    /// (docs/architecture-decisions.md §11.5). 8–10 bits per channel in practice.
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

    /// The identifier used to ask ImageIO's writer list about this container.
    ///
    /// AVIF is the one case where `utType` has a fallback: on systems without the AVIF UTI a file
    /// would be silently written as HEIC, so the *availability* question must use the real identifier
    /// (nil = not writable) rather than the fallback.
    public var writableTypeIdentifier: String? {
        switch self {
        case .avif: return UTType("public.avif")?.identifier
        default: return utType.identifier
        }
    }

    /// 109 §2 — only the formats this machine has an encoder for.
    ///
    /// The set comes from `CGImageDestinationCopyTypeIdentifiers()`; taking it as a parameter keeps
    /// the rule testable without depending on what the running OS happens to ship.
    public static func available(writableUTIs: Set<String>) -> [ExportFormat] {
        allCases.filter { format in
            guard let identifier = format.writableTypeIdentifier else { return false }
            return writableUTIs.contains(identifier)
        }
    }

    /// The writable UTI set on this machine.
    public static var writableUTIs: Set<String> {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }

    /// What the 文件设置 format row may offer here.
    public static var availableHere: [ExportFormat] {
        available(writableUTIs: writableUTIs)
    }

    /// 109 §1 / 108 / 163 — the bit depths the container can honestly store, narrowest first.
    ///
    /// AVIF was 8-only while the project had no fixture that read 10 back. The 163 probe writes a
    /// 16-bit-storage `CGImage` and reads `kCGImagePropertyDepth = 10` + `bitsPerComponent = 10`, so
    /// AVIF now offers 10 like HEIC.
    public var bitDepths: [Int] {
        switch self {
        case .jpeg: return [8]
        case .heic, .avif: return [8, 10]
        case .tiff, .png: return [8, 16]
        }
    }

    /// The closest depth this container really accepts. Switching HEIC 10 → JPEG gives 8 instead of
    /// leaving a hidden illegal value in the preset.
    public func clampedBitDepth(_ depth: Int) -> Int {
        let legal = bitDepths
        if legal.contains(depth) { return depth }
        if depth >= 16, legal.contains(16) { return 16 }
        if depth > 8, legal.contains(10) { return 10 }
        if depth > 8, legal.contains(16) { return 16 }
        return legal.first ?? 8
    }

    public var supportsQuality: Bool {
        self == .jpeg || self == .heic || self == .avif
    }

    /// Formats that can really carry 16 bits per channel. Measured on this machine: HEIC/AVIF accept
    /// 16 bpc but read back as 10 (HEIF has no 16-bit primary item), so only TIFF and PNG offer it.
    public var supports16Bit: Bool {
        self == .tiff || self == .png
    }

    /// HEIF-based containers top out at 10 bits per channel (see `supports16Bit`). AVIF's ImageIO
    /// encoder really produces 10 when handed 16-bit storage (163 probe).
    public var supports10Bit: Bool {
        self == .heic || self == .avif
    }

    /// 111 — the HDR kinds this container can honestly carry.
    ///
    /// This table is the single source of truth for `ExportPreset.validated()`, the UI picker and the
    /// tests. `gainMap` is available for HEIC/JPEG/AVIF (163 measured that ImageIO's JPEG writer takes
    /// the ISO auxiliary image and Core Image's JPEG representation takes Apple's); TIFF/PNG have no
    /// auxiliary-image container. `hlg`/`pq` are offered for every non-JPEG container (8-bit JPEG has
    /// neither transfer curve).
    public var hdrKinds: [HDRKind] {
        switch self {
        case .jpeg:
            return [.none, .gainMap]
        case .heic, .avif:
            return [.none, .gainMap, .hlg, .pq]
        case .tiff, .png:
            return [.none, .hlg, .pq]
        }
    }

    public func supports(_ kind: HDRKind) -> Bool {
        hdrKinds.contains(kind)
    }

    /// 163 — the only bit depth a `pq`/`hlg` primary item may carry: HEIF tops out at 10, the lossless
    /// containers are honest at 16. `nil` when the container cannot write that curve at all (JPEG).
    public func hdrTransferBitDepth(for kind: HDRKind) -> Int? {
        guard kind == .hlg || kind == .pq else { return nil }
        switch self {
        case .heic, .avif: return 10
        case .png, .tiff: return 16
        case .jpeg: return nil
        }
    }

    /// 163 — the depths the sheet may offer for `kind`. PQ/HLG are locked to the one legal value
    /// instead of silently clamping a stale 8-bit preset at write time.
    public func bitDepths(for kind: HDRKind) -> [Int] {
        if let locked = hdrTransferBitDepth(for: kind) { return [locked] }
        return bitDepths
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
    public var bitDepth: Int          // 8, 10 or 16
    /// 100/111 — the HDR path. `nil` = the pre-HDR encoder path, byte for byte.
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

        guard bitDepth == 8 || bitDepth == 10 || bitDepth == 16 else {
            throw ExportError.badBitDepth("image", bitDepth)
        }
        // 10-bit is stored in 16-bit words: CGImage's 10-bpc spelling is not accepted with the
        // sRGB space on this OS, and ImageIO's HEIC/AVIF writer reads back 10 bits either way.
        let storageDepth = bitDepth == 10 ? 16 : bitDepth
        let maxValue: Float = storageDepth == 16 ? 65535 : 255
        var words = [UInt16](repeating: 0, count: count)
        for i in 0..<count {
            words[i] = UInt16(min(max(Float(image.rgba[i]), 0), 1) * maxValue + 0.5)
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let provider = CGDataProvider(data: Data(words.withUnsafeBufferPointer { Data(buffer: $0) }) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: storageDepth,
                               bitsPerPixel: storageDepth * 4,
                               bytesPerRow: w * 8, space: space, bitmapInfo: info,
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else {
            throw ExportError.bitmapContextFailed
        }
        return cg
    }

    /// Write `image`. When `options.hdr` asks for a gain map **and** the image carries a linear
    /// companion (rendered through `s4_display_linear`), this routes to `GainMapHEIC`, which writes
    /// the same SDR base plus a gain-map auxiliary image. `hlg`/`pq` route to `HDREncoding`, which
    /// converts the linear companion to Rec.2020 with the requested transfer curve. Otherwise it is
    /// the untouched pre-100 encoder.
    ///
    /// - Returns: non-fatal HDR notes (an SDR fallback, a clipped headroom). Empty on the normal path.
    @discardableResult
    public static func write(_ image: DisplayImage, to url: URL, options: ExportOptions,
                             metadata: ExportMetadataContext = ExportMetadataContext()) throws -> [String] {
        if let hdr = options.hdr, hdr.enabled {
            switch hdr.kind {
            case .gainMap:
                if let linear = image.linear {
                    if options.format == .heic || options.format == .jpeg {
                        let result = try GainMapHEIC.write(
                            sdr: image, linear: linear, to: url,
                            options: HDRGainMapOptions(gainMap: hdr.gainMap,
                                                       halfSize: hdr.halfSize,
                                                       headroom: hdr.headroom,
                                                       quality: options.quality,
                                                       bitDepth: options.bitDepth),
                            metadata: metadata,
                            format: options.format)
                        return result.warnings
                    }
                    // 163 probe: AVIF takes the ISO gain map (contentHeadroom reads back 4.00) but
                    // not Apple's spelling (aux written, headroom 1.00). Write ISO for an Apple
                    // request and say why — never mislabel an SDR file as HDR.
                    if options.format == .avif {
                        let apple = hdr.gainMap == .apple
                        let result = try GainMapHEIC.write(
                            sdr: image, linear: linear, to: url,
                            options: HDRGainMapOptions(gainMap: apple ? .iso : hdr.gainMap,
                                                       halfSize: hdr.halfSize,
                                                       headroom: hdr.headroom,
                                                       quality: options.quality,
                                                       bitDepth: options.bitDepth),
                            metadata: metadata,
                            format: .avif)
                        if apple {
                            return ["AVIF cannot carry Apple's gain map (ImageIO reads it as SDR); "
                                    + "wrote the ISO RGB gain map instead"] + result.warnings
                        }
                        return result.warnings
                    }
                }
            case .hlg, .pq:
                return try HDREncoding.write(image, to: url, options: options, metadata: metadata)
            case .none:
                break
            }
        }
        guard options.bitDepth == 8
                || (options.bitDepth == 10 && options.format.supports10Bit)
                || (options.bitDepth == 16 && options.format.supports16Bit) else {
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
    static func stripMetadata(at url: URL) throws {
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
        let cg: CGImage
        if let kind = options.hdr?.kind, kind == .hlg || kind == .pq {
            cg = try HDREncoding.cgImage(for: image, kind: kind)
        } else {
            cg = try cgImage(image, bitDepth: options.bitDepth)
        }
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
