import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import PhotonsCore

// MARK: - 100 · HDR gain map HEIC
//
// A gain map is not a second picture: it is a per-pixel **ratio** between the linear HDR light and
// the SDR base's linear light, stored as an auxiliary image in the same HEIF container. A reader
// (Photos, Preview, iOS) decodes the base normally and, when it wants HDR, multiplies it by
// `2^(gain · GainMapMax)` (ISO) or `1 + gain · (headroom − 1)` (Apple's Rec.709-shaped map).
//
// The two spellings below are the two that actually decode on macOS/iOS:
//
//   · **ISO 21496-1** (`kCGImageAuxiliaryDataTypeISOGainMap`): an `hvc1` auxiliary item whose XMP uses
//     `http://ns.apple.com/HDRToneMap/1.0/` (the string `hdrgm` readers look for is the *namespace
//     of ISO's own XMP*, this build writes Apple's HDRToneMap keys because that is what ImageIO
//     emits and reads back — verified with `heif-item-dump.py` and `CIImage.contentHeadroom`).
//     Pixel formats: `32ARGB` for the RGB map, `OneComponent8` for the mono map.
//   · **Apple HDR gain map** (`kCGImageAuxiliaryDataTypeHDRGainMap`): a monochrome map written by
//     Core Image's `hdrGainMapImage` representation option, plus a `tmap` MakerNote item carrying the
//     headroom in stops ("33"/"48", the same private keys toGainMapHDR writes).
//
// Everything here is CoreGraphics/CoreImage/ImageIO. No libheif, no third-party encoder.
public enum GainMapHEICError: LocalizedError {
    case writeFailed(URL, String)
    case gainMapFailed(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let url, let why):
            return "could not write the HDR HEIC at \(url.path): \(why)"
        case .gainMapFailed(let why):
            return "could not build the gain map: \(why)"
        }
    }
}

public struct HDRGainMapOptions: Sendable {
    public var gainMap: HDRExport.GainMap
    public var halfSize: Bool
    public var headroom: HDRExport.Headroom
    public var quality: Double
    public var bitDepth: Int

    public init(gainMap: HDRExport.GainMap = .iso, halfSize: Bool = true,
                headroom: HDRExport.Headroom = .auto, quality: Double = 0.95, bitDepth: Int = 8) {
        self.gainMap = gainMap
        self.halfSize = halfSize
        self.headroom = headroom
        self.quality = quality
        self.bitDepth = bitDepth
    }
}

public struct HDRWriteResult: Sendable {
    /// The headroom the file claims (`contentHeadroom`), i.e. the peak ratio the map can reconstruct.
    public var headroom: Double
    /// False when the source measured SDR and the file is a plain SDR HEIC.
    public var isHDR: Bool
    public var warnings: [String]
}

public enum GainMapHEIC {

    /// The line toGainMapHDR draws: below this the source is SDR and a gain map would amplify noise.
    public static let sdrThreshold = 1.05
    /// The gain-map maths' guard against `0/0` in the shadows (ISO 21496-1's `k`).
    static let k: Float = 0.000_010

    // MARK: - measurement

    /// Peak linear channel value, `max(r, g, b)` over every pixel — the same statistic as
    /// `CIAreaMaximum` on the HDR image (a hotspot is a peak even when it is one texel).
    public static func peak(of image: LinearPixels) -> Double {
        var peak: Float = 0
        let n = image.width * image.height
        for i in 0..<n {
            let o = i * 4
            peak = max(peak, max(Float(image.rgba[o]), max(Float(image.rgba[o + 1]), Float(image.rgba[o + 2]))))
        }
        return Double(peak)
    }

    /// Peak of the 3×3 box-averaged picture — toGainMapHDR's `picHeadroom2`. A single hot texel
    /// should not define the map's whole range, and a downscaled reader would never see it.
    public static func coarsePeak(of image: LinearPixels, block: Int = 3) -> Double {
        let w = image.width, h = image.height
        let b = max(1, block)
        var peak: Float = 0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                var r: Float = 0, g: Float = 0, bl: Float = 0
                var n: Float = 0
                for yy in y..<min(y + b, h) {
                    for xx in x..<min(x + b, w) {
                        let o = (yy * w + xx) * 4
                        r += Float(image.rgba[o]); g += Float(image.rgba[o + 1])
                        bl += Float(image.rgba[o + 2]); n += 1
                    }
                }
                if n > 0 { peak = max(peak, max(r / n, max(g / n, bl / n))) }
                x += b
            }
            y += b
        }
        return Double(peak)
    }

    /// The headroom the map is normalized by: measured, then `min(full, coarse)` (spec §2.B.2), or the
    /// preset's manual value. Never below 1, so `log2` stays finite.
    public static func resolvedHeadroom(linear: LinearPixels,
                                        manual: HDRExport.Headroom) -> (peak: Double, used: Double) {
        let full = peak(of: linear)
        let coarse = coarsePeak(of: linear)
        let measured = max(1.0, min(full, coarse == 0 ? full : coarse))
        switch manual {
        case .auto: return (full, measured)
        case .manual(let value): return (full, max(1.0, value))
        }
    }

    // MARK: - writing

    /// Write `sdr` as `format` and attach a gain map built from `linear`.
    ///
    /// `linear` must be the same picture through `s4_display_linear` in the **same** primaries; its
    /// values are extended-range linear light, while `sdr` is display-encoded (OETF applied).
    ///
    /// 163 — the writer is no longer HEIF-only: JPEG takes the same SDR base + ISO auxiliary image,
    /// and the Apple spelling through Core Image's JPEG representation. `format` defaults to HEIC so
    /// every pre-163 call site keeps its exact behaviour.
    @discardableResult
    public static func write(sdr: DisplayImage, linear: LinearPixels, to url: URL,
                             options: HDRGainMapOptions = HDRGainMapOptions(),
                             metadata: ExportMetadataContext = ExportMetadataContext(),
                             format: ExportFormat = .heic)
        throws -> HDRWriteResult {
        guard format.supports(.gainMap) else {
            throw GainMapHEICError.writeFailed(
                url, "\(format.rawValue.uppercased()) cannot carry a gain map")
        }
        guard sdr.width == linear.width, sdr.height == linear.height else {
            throw GainMapHEICError.gainMapFailed(
                "SDR base is \(sdr.width)×\(sdr.height) but the linear render is "
                + "\(linear.width)×\(linear.height)")
        }
        let (fullPeak, used) = resolvedHeadroom(linear: linear, manual: options.headroom)

        // SDR source: write the file the pre-HDR path would have written and say so. The caller keeps
        // the same filename; only the auxiliary image is missing.
        if fullPeak < sdrThreshold {
            try Exporter.write(sdr, to: url,
                               options: ExportOptions(format: format, quality: options.quality,
                                                      bitDepth: options.bitDepth),
                               metadata: metadata)
            return HDRWriteResult(
                headroom: 1,
                isHDR: false,
                warnings: ["HDR gain map skipped: source headroom "
                           + String(format: "%.3f", fullPeak)
                           + " is below \(sdrThreshold) (SDR) — wrote an SDR "
                           + format.rawValue.uppercased()])
        }

        let map = try GainMapPixels(sdr: sdr, linear: linear, headroom: used,
                                    mode: options.gainMap, halfSize: options.halfSize)

        switch options.gainMap {
        case .apple:
            if #available(macOS 14.1, *) {
                switch format {
                case .heic:
                    try writeAppleHEIF(sdr: sdr, map: map, headroom: used, to: url,
                                       options: options, metadata: metadata)
                case .jpeg:
                    try writeAppleJPEG(sdr: sdr, map: map, headroom: used, to: url,
                                       options: options, metadata: metadata)
                case .avif:
                    // Apple's spelling is stored by ImageIO's AVIF writer but reads back as SDR
                    // (163 probe: contentHeadroom 1.00). Refuse to mislabel it; the caller sees the
                    // same warning path it would for an unwritable spelling.
                    throw GainMapHEICError.gainMapFailed(
                        "Apple gain maps are not readable in AVIF — pick ISO RGB")
                case .tiff, .png:
                    throw GainMapHEICError.gainMapFailed(
                        "\(format.rawValue.uppercased()) cannot carry an auxiliary gain map")
                }
            } else {
                throw GainMapHEICError.writeFailed(url, "Apple gain maps need macOS 14.1")
            }
        case .iso, .mono:
            if #available(macOS 15.0, *) {
                try writeISO(sdr: sdr, map: map, headroom: used, to: url, options: options,
                             metadata: metadata, format: format)
            } else {
                throw GainMapHEICError.writeFailed(url, "ISO gain maps need macOS 15")
            }
        }

        var warnings: [String] = []
        if used < fullPeak * 0.999 {
            warnings.append("headroom clipped: measured peak "
                            + String(format: "%.3f", fullPeak)
                            + " > map headroom " + String(format: "%.3f", used))
        }
        return HDRWriteResult(headroom: used, isHDR: true, warnings: warnings)
    }

    /// `CIImage.contentHeadroom` of a written file — the number a reader will use, not the number we
    /// intended. Available on macOS 15+; `nil` on older systems (the tests read it on this machine).
    public static func readHeadroom(at url: URL) -> Double? {
        if #available(macOS 15.0, *) {
            let options: [CIImageOption: Any] = [.expandToHDR: true]
            return CIImage(contentsOf: url, options: options).map { Double($0.contentHeadroom) }
        }
        return nil
    }

    // MARK: - ISO path (ImageIO auxiliary data)

    @available(macOS 15.0, *)
    private static func writeISO(sdr: DisplayImage, map: GainMapPixels, headroom: Double,
                                 to url: URL, options: HDRGainMapOptions,
                                 metadata: ExportMetadataContext,
                                 format: ExportFormat) throws {
        let baseCG = try Exporter.cgImage(sdr, bitDepth: options.bitDepth)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         format.utType.identifier as CFString,
                                                         1, nil) else {
            throw GainMapHEICError.writeFailed(url, "no \(format.rawValue.uppercased()) destination")
        }
        var properties = metadata.properties(outputWidth: sdr.width, outputHeight: sdr.height,
                                             format: format)
        if format.supportsQuality {
            // AVIF's HDR path rejects quality 1.0 (same reason as `HDREncoding`); 0.99 is still
            // visually lossless and keeps the auxiliary-image container writable.
            let quality = format == .avif ? min(options.quality, 0.99) : options.quality
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if let xmp = metadata.xmpMetadata(outputWidth: sdr.width, outputHeight: sdr.height) {
            CGImageDestinationAddImageAndMetadata(dest, baseCG, xmp, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(dest, baseCG, properties as CFDictionary)
        }

        let isMono = options.gainMap == .mono
        let pixelFormat = isMono ? kCVPixelFormatType_OneComponent8 : kCVPixelFormatType_32ARGB
        let colorSpace = isMono ? CGColorSpace(name: CGColorSpace.linearGray)
                                : CGColorSpace(name: CGColorSpace.linearITUR_2020)
        let description: [String: Any] = [
            "PixelFormat": pixelFormat,
            "Width": String(map.width),
            "Height": String(map.height),
            "BytesPerRow": String(map.rowBytes),
        ]
        var aux: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: map.data,
            kCGImageAuxiliaryDataInfoDataDescription: description,
        ]
        if let colorSpace { aux[kCGImageAuxiliaryDataInfoColorSpace] = colorSpace }
        let xmp = isoXMP(gainMapMax: log2(headroom), channels: isMono ? 1 : 3)
        if let metadata = CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData) {
            aux[kCGImageAuxiliaryDataInfoMetadata] = metadata
        }
        CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeISOGainMap,
                                               aux as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw GainMapHEICError.writeFailed(url, "ImageIO did not finalize")
        }
    }

    /// ISO 21496-1 XMP. `GainMapMax`/`GainMapMin` are in **stops** (`log2` of the ratio), `Gamma` 1
    /// because the pixels are already linear codes, and `AlternateHeadroom` is the field ImageIO
    /// reads back as `contentHeadroom` (verified: a file written with 2.300450 reads back 4.926).
    static func isoXMP(gainMapMax: Double, channels: Int) -> String {
        func block() -> String {
            """
            <rdf:li rdf:parseType="Resource">
               <HDRToneMap:GainMapMin>0.000000</HDRToneMap:GainMapMin>
               <HDRToneMap:GainMapMax>\(String(format: "%.6f", gainMapMax))</HDRToneMap:GainMapMax>
               <HDRToneMap:Gamma>1.000000</HDRToneMap:Gamma>
               <HDRToneMap:BaseOffset>0.000010</HDRToneMap:BaseOffset>
               <HDRToneMap:AlternateOffset>0.000010</HDRToneMap:AlternateOffset>
            </rdf:li>
            """
        }
        let blocks = Array(repeating: block(), count: max(1, channels)).joined(separator: "\n")
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
           <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                    xmlns:HDRToneMap="http://ns.apple.com/HDRToneMap/1.0/">
                 <HDRToneMap:Version>1</HDRToneMap:Version>
                 <HDRToneMap:BaseHeadroom>0.000000</HDRToneMap:BaseHeadroom>
                 <HDRToneMap:AlternateHeadroom>\(String(format: "%.6f", gainMapMax))</HDRToneMap:AlternateHeadroom>
                 <HDRToneMap:ChannelMetadata>
                    <rdf:Seq>
        \(blocks)
                    </rdf:Seq>
                 </HDRToneMap:ChannelMetadata>
                 <HDRToneMap:BaseColorIsWorkingColor>True</HDRToneMap:BaseColorIsWorkingColor>
              </rdf:Description>
           </rdf:RDF>
        </x:xmpmeta>
        """
    }

    // MARK: - Apple path (Core Image representation option + tmap MakerNote)

    @available(macOS 14.1, *)
    private static func writeAppleHEIF(sdr: DisplayImage, map: GainMapPixels, headroom: Double,
                                       to url: URL, options: HDRGainMapOptions,
                                       metadata: ExportMetadataContext) throws {
        let baseCG = try Exporter.cgImage(sdr, bitDepth: options.bitDepth)
        guard let gainCG = map.appleCGImage() else {
            throw GainMapHEICError.gainMapFailed("could not build the Apple gain map bitmap")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // The `tmap` item is what Apple's decoder reads the headroom from. These are the reverse of
        // the formulas in "Applying Apple HDR effect to your photos" (maker 33/48), exactly as
        // toGainMapHDR encodes them.
        let maker = appleMaker(headroom: headroom)
        var properties: [String: Any] = [:]
        for (key, value) in metadata.properties(outputWidth: sdr.width,
                                                outputHeight: sdr.height,
                                                format: .heic) {
            properties[key as String] = value
        }
        properties[kCGImagePropertyMakerAppleDictionary as String] = maker
        let baseCI = CIImage(cgImage: baseCG, options: [.properties: properties])
        let gainCI = CIImage(cgImage: gainCG)

        guard let space = Exporter.colorSpace(for: sdr.primaries) else {
            throw GainMapHEICError.gainMapFailed(
                "color space unavailable: \(sdr.primaries.displayName)")
        }
        let format: CIFormat = baseCG.bitsPerComponent == 16 ? .RGBA16 : .RGBA8
        var ciOptions: [CIImageRepresentationOption: Any] = [.hdrGainMapImage: gainCI]
        ciOptions[CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String)] = options.quality
        let context = CIContext()
        do {
            try context.writeHEIFRepresentation(of: baseCI, to: url, format: format,
                                                colorSpace: space, options: ciOptions)
        } catch {
            throw GainMapHEICError.writeFailed(url, error.localizedDescription)
        }
        // `writeHEIFRepresentation` honours `CIImage.properties` but not
        // `kCGImageDestinationMetadata`, so the XMP packet is merged into the finished container.
        // Copy-image-source keeps the primary image and its gain-map auxiliary image untouched.
        if let xmp = metadata.xmpMetadata(outputWidth: sdr.width, outputHeight: sdr.height) {
            try mergeXMP(xmp, into: url, format: .heic)
        }
    }

    /// The reverse of Apple's MakerNote 33/48 formulas (the same numbers toGainMapHDR writes).
    /// `33` selects the curve and `48` is the headroom on that curve, in stops.
    private static func appleMaker(headroom: Double) -> [String: Any] {
        let stops = log2(max(1.0001, headroom))
        switch stops {
        case 2.3...:
            return ["33": 1.0, "48": (3.0 - stops) / 70.0]
        case 1.8..<2.3:
            return ["33": 1.0, "48": (2.30303 - stops) / 0.303]
        case 1.6..<1.8:
            return ["33": 0.0, "48": (1.80 - stops) / 20.0]
        default:
            return ["33": 0.0, "48": (1.60101 - stops) / 0.101]
        }
    }

    /// 163 — Apple's gain map in a JPEG.
    ///
    /// Measured: `CGImageDestinationAddAuxiliaryDataInfo(…HDRGainMap…)` writes the auxiliary image but
    /// readers stay at headroom 1. Core Image's JPEG representation with `.hdrGainMapImage` **and** the
    /// `{MakerApple}` block on `CIImage.properties` is the one route that reads back as HDR. The
    /// quality option has the same spelling as ImageIO's destination property.
    @available(macOS 14.1, *)
    private static func writeAppleJPEG(sdr: DisplayImage, map: GainMapPixels, headroom: Double,
                                       to url: URL, options: HDRGainMapOptions,
                                       metadata: ExportMetadataContext) throws {
        let baseCG = try Exporter.cgImage(sdr, bitDepth: options.bitDepth)
        guard let gainCG = map.appleCGImage() else {
            throw GainMapHEICError.gainMapFailed("could not build the Apple gain map bitmap")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var properties: [String: Any] = [:]
        for (key, value) in metadata.properties(outputWidth: sdr.width,
                                                outputHeight: sdr.height,
                                                format: .jpeg) {
            properties[key as String] = value
        }
        properties[kCGImagePropertyMakerAppleDictionary as String] = appleMaker(headroom: headroom)

        let baseCI = CIImage(cgImage: baseCG, options: [.properties: properties])
        let gainCI = CIImage(cgImage: gainCG)
        guard let space = Exporter.colorSpace(for: sdr.primaries) else {
            throw GainMapHEICError.gainMapFailed(
                "color space unavailable: \(sdr.primaries.displayName)")
        }
        var ciOptions: [CIImageRepresentationOption: Any] = [.hdrGainMapImage: gainCI]
        ciOptions[CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String)] = options.quality
        do {
            try CIContext().writeJPEGRepresentation(of: baseCI, to: url, colorSpace: space,
                                                    options: ciOptions)
        } catch {
            throw GainMapHEICError.writeFailed(url, error.localizedDescription)
        }
        if let xmp = metadata.xmpMetadata(outputWidth: sdr.width, outputHeight: sdr.height) {
            try mergeXMP(xmp, into: url, format: .jpeg)
        }
    }

    /// Merge `metadata` into an existing container without re-encoding the pixels (or dropping the
    /// auxiliary gain map). Used only on the Apple path, whose writer has no XMP option.
    private static func mergeXMP(_ metadata: CGImageMetadata, into url: URL,
                                 format: ExportFormat) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw GainMapHEICError.writeFailed(
                url, "cannot reopen the written \(format.rawValue.uppercased())")
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).xmp-\(UUID().uuidString)"
                                    + ".\(format.fileExtension)")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL,
                                                         format.utType.identifier as CFString,
                                                         1, nil) else {
            throw GainMapHEICError.writeFailed(
                url, "no \(format.rawValue.uppercased()) destination for the XMP merge")
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata,
                                        kCGImageDestinationMergeMetadata: true]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) else {
            let why = error.map { ($0.takeRetainedValue() as Error).localizedDescription }
                ?? "copy failed"
            try? FileManager.default.removeItem(at: tmp)
            throw GainMapHEICError.writeFailed(url, why)
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw GainMapHEICError.writeFailed(url, error.localizedDescription)
        }
    }

}

// MARK: - gain map pixels

/// One encoded gain map, ready to hand to ImageIO: RGB interleaved ARGB8, or 8-bit mono.
struct GainMapPixels {
    let width: Int
    let height: Int
    let channels: Int          // 4 (ARGB8) or 1 (L8)
    let data: Data

    var rowBytes: Int { width * channels }

    func appleCGImage() -> CGImage? {
        guard channels == 1, let space = CGColorSpace(name: CGColorSpace.linearGray),
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    init(sdr: DisplayImage, linear: LinearPixels, headroom: Double,
         mode: HDRExport.GainMap, halfSize: Bool) throws {
        let hdrMax = Float(max(1.0001, headroom))
        let logMax = log2(hdrMax)
        guard logMax > 0 else { throw GainMapHEICError.gainMapFailed("headroom must exceed 1") }

        let w = sdr.width, h = sdr.height
        // Gain at full resolution first, then (for `halfSize`) a 2×2 box average of the **gain**,
        // not of the pixels: averaging two linear pictures and then taking their ratio is a different
        // quantity near an edge.
        var full = [Float](repeating: 0, count: w * h * (mode == .iso ? 3 : 1))
        let channels = mode == .iso ? 3 : 1
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                let s = (0..<3).map { GainMapHEIC.srgbToLinear(Float(sdr.rgba[o + $0])) }
                let l = (0..<3).map { Float(linear.rgba[o + $0]) }
                switch mode {
                case .iso:
                    for c in 0..<3 {
                        full[(y * w + x) * 3 + c] = GainMapPixels.isoGain(hdr: l[c], sdr: s[c], logMax: logMax)
                    }
                case .mono:
                    let g = GainMapPixels.isoGain(hdr: GainMapPixels.luma(l), sdr: GainMapPixels.luma(s), logMax: logMax)
                    full[y * w + x] = g
                case .apple:
                    let hdrL = GainMapPixels.luma(l), sdrL = GainMapPixels.luma(s)
                    let ratio = sdrL <= 0 ? 1 : hdrL / sdrL
                    full[y * w + x] = GainMapPixels.appleGain(ratio: ratio, hdrMax: hdrMax)
                }
            }
        }

        // 163 — the spec's size is `ceil(base / 2)` per axis, not a floor, so an odd edge still keeps
        // the last row/column's ratio instead of dropping it.
        let tw = halfSize ? max(1, (w + 1) / 2) : w
        let th = halfSize ? max(1, (h + 1) / 2) : h
        let reduced = halfSize ? GainMapPixels.reduce(full, w: w, h: h, channels: channels)
                                : full
        self.width = tw
        self.height = th
        self.channels = channels == 3 ? 4 : 1
        var bytes = [UInt8](repeating: 0, count: tw * th * self.channels)
        for i in 0..<(tw * th) {
            if channels == 3 {
                bytes[i * 4] = 255
                for c in 0..<3 { bytes[i * 4 + 1 + c] = GainMapPixels.encode(reduced[i * 3 + c]) }
            } else {
                bytes[i] = GainMapPixels.encode(reduced[i])
            }
        }
        self.data = Data(bytes)
    }

    /// 2×2 box average, per channel, with `ceil` output dimensions (163): the last output row/column
    /// averages the one input row/column that still exists instead of dropping it.
    private static func reduce(_ src: [Float], w: Int, h: Int, channels: Int) -> [Float] {
        let tw = max(1, (w + 1) / 2), th = max(1, (h + 1) / 2)
        var out = [Float](repeating: 0, count: tw * th * channels)
        for y in 0..<th {
            for x in 0..<tw {
                for c in 0..<channels {
                    var sum: Float = 0, n: Float = 0
                    for dy in 0..<2 {
                        let yy = min(h - 1, y * 2 + dy)
                        for dx in 0..<2 {
                            let xx = min(w - 1, x * 2 + dx)
                            sum += src[(yy * w + xx) * channels + c]
                            n += 1
                        }
                    }
                    out[(y * tw + x) * channels + c] = sum / n
                }
            }
        }
        return out
    }

    private static func luma(_ rgb: [Float]) -> Float {
        0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
    }

    /// ISO: `log2((hdr+k)/(sdr+k)) / log2(hdrmax)`, clamped to the map's [0, 1] cube.
    private static func isoGain(hdr: Float, sdr: Float, logMax: Float) -> Float {
        let ratio = log2((hdr + GainMapHEIC.k) / (max(0, sdr) + GainMapHEIC.k))
        return min(max(ratio / logMax, 0), 1)
    }

    /// Apple: `(hdrLum/sdrLum − 1) / (hdrmax − 1)`, then Rec.709's OETF (the shape Apple's decoder
    /// inverts). Ratio below 1 (a darker alternate) clamps to no gain.
    private static func appleGain(ratio: Float, hdrMax: Float) -> Float {
        var r = (ratio - 1) / (hdrMax - 1)
        r = min(max(r, 0), 1)
        return r < 0.018 ? 4.5 * r : 1.099 * pow(r, 0.45) - 0.099
    }

    private static func encode(_ v: Float) -> UInt8 {
        UInt8(min(max(v, 0), 1) * 255 + 0.5)
    }
}

extension GainMapHEIC {
    /// The sRGB piecewise EOTF. Display P3 uses the same curve (S4's own comment), so one function
    /// decodes either base.
    static func srgbToLinear(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
}
