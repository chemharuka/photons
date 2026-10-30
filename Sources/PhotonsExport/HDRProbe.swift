import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

// MARK: - 163 · ImageIO HDR probes
//
// These are the measurements behind the JPEG/AVIF decisions, kept in the library (not only in a
// throwaway script) so `photonsctl probe-hdr` can reproduce them on any machine and the tests can
// pin the current facts. Everything is ImageIO/CoreGraphics/CoreImage — no third-party encoder.
//
// Measured on macOS 27 (2026-10-30):
//   · JPEG accepts `kCGImageAuxiliaryDataTypeISOGainMap`; `CIImage.contentHeadroom` reads back 4.0.
//   · JPEG accepts `kCGImageAuxiliaryDataTypeHDRGainMap` only with an explicit `{MakerApple}` block
//     and Core Image's `hdrGainMapImage` representation option; the raw auxiliary API alone reads 1.0.
//   · `kCGImagePropertyImages` / `kCGImagePropertyAuxiliaryData` are absent from the property dict;
//     the auxiliary data is still reachable through `CGImageSourceCopyAuxiliaryDataInfoAtIndex`.
//   · A two-image JPEG/AVIF destination cannot be created (`CGImageDestinationCreateWithURL` → nil),
//     so there is no MPF/multi-page route to an Ultra HDR secondary image.
//   · AVIF writes 10-bit primaries (`kCGImagePropertyDepth` = 10) and accepts the ISO gain map
//     (contentHeadroom 4.0); Apple's spelling is stored but reads back as SDR.
public struct HDRProbeResult: Sendable {
    public var lines: [String] = []
    public var outputDirectory: URL?

    public var jpegISOAccepted = false
    public var jpegISOHeadroom: Double?
    public var jpegAppleAccepted = false
    public var jpegAppleHeadroom: Double?
    public var jpegMultiImage = false
    /// True when `kCGImagePropertyImages` or `kCGImagePropertyAuxiliaryData` appears in the JPEG
    /// properties dictionary. Measured false; aux is only reachable via the auxiliary-data API.
    public var jpegPropertiesExposeAux = false

    public var avif10Depth: Int?
    public var avifISOAccepted = false
    public var avifISOHeadroom: Double?
    public var avifAppleAccepted = false
    public var avifAppleHeadroom: Double?
    public var avifMultiImage = false
}

@available(macOS 15.0, *)
public enum HDRProbe {

    public static func run(keepFiles: Bool = false) -> HDRProbeResult {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-hdr-probe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { if !keepFiles { try? FileManager.default.removeItem(at: dir) } }

        var result = HDRProbeResult()
        result.outputDirectory = keepFiles ? dir : nil
        let width = 64, height = 48
        let base = baseImage(width: width, height: height)

        // MARK: JPEG — ISO auxiliary
        let jpegISO = dir.appendingPathComponent("jpeg-iso.jpg")
        let isoOK = writeSingle(jpegISO, type: .jpeg, image: base,
                                auxType: kCGImageAuxiliaryDataTypeISOGainMap,
                                aux: isoAux(width: width, height: height, headroom: 4))
        result.jpegISOAccepted = isoOK
        result.jpegISOHeadroom = headroom(of: jpegISO)
        let jpegProps = properties(of: jpegISO)
        result.jpegPropertiesExposeAux =
            jpegProps?[kCGImagePropertyImages] != nil || jpegProps?[kCGImagePropertyAuxiliaryData] != nil
        result.lines.append("jpeg + ISOGainMap: finalize=\(isoOK) "
            + "aux=\(auxPresent(jpegISO, kCGImageAuxiliaryDataTypeISOGainMap)) "
            + "headroom=\(fmt(result.jpegISOHeadroom)) "
            + "ImagesKey=\(jpegProps?[kCGImagePropertyImages] != nil) "
            + "AuxDataKey=\(jpegProps?[kCGImagePropertyAuxiliaryData] != nil)")

        // MARK: JPEG — Apple spelling through Core Image (why the raw aux API is not enough)
        let jpegApple = dir.appendingPathComponent("jpeg-apple.jpg")
        let appleOK: Bool
        if #available(macOS 14.1, *) {
            appleOK = writeAppleJPEG(jpegApple, image: base, width: width, height: height,
                                     headroom: 4)
        } else {
            appleOK = false
        }
        result.jpegAppleAccepted = appleOK
        result.jpegAppleHeadroom = headroom(of: jpegApple)
        result.lines.append("jpeg + HDRGainMap (CI hdrGainMapImage + MakerApple 33/48): "
            + "written=\(appleOK) aux=\(auxPresent(jpegApple, kCGImageAuxiliaryDataTypeHDRGainMap)) "
            + "headroom=\(fmt(result.jpegAppleHeadroom))")

        // MARK: JPEG — multi-image destination (the MPF route)
        let jpegMulti = dir.appendingPathComponent("jpeg-multi.jpg")
        result.jpegMultiImage = writeMulti(jpegMulti, type: .jpeg, image: base, second: base)
        let jpegMultiProps = properties(of: jpegMulti)
        result.lines.append("jpeg two-image destination: created=\(result.jpegMultiImage) "
            + "count=\(imageCount(jpegMulti)) ImagesKey=\(jpegMultiProps?[kCGImagePropertyImages] != nil)")

        // MARK: AVIF — 10-bit primary
        let avif = UTType("public.avif") ?? .heic
        let avif10 = dir.appendingPathComponent("avif-10.avif")
        let avif10OK = writeSingle(avif10, type: avif, image: baseImage(width: width, height: height,
                                                                       bits: 16), auxType: nil, aux: nil)
        result.avif10Depth = (properties(of: avif10)?[kCGImagePropertyDepth] as? NSNumber)?.intValue
        result.lines.append("avif 16-bit-storage write: finalize=\(avif10OK) "
            + "depth=\(result.avif10Depth.map(String.init) ?? "nil") "
            + "bitsPerComponent=\(imageBits(avif10).map(String.init) ?? "nil") "
            + "profile=\(profile(of: avif10) ?? "nil")")

        // MARK: AVIF — ISO auxiliary
        let avifISO = dir.appendingPathComponent("avif-iso.avif")
        let avifISOOK = writeSingle(avifISO, type: avif, image: baseImage(width: width, height: height,
                                                                         bits: 16),
                                    auxType: kCGImageAuxiliaryDataTypeISOGainMap,
                                    aux: isoAux(width: width, height: height, headroom: 4))
        result.avifISOAccepted = avifISOOK
        result.avifISOHeadroom = headroom(of: avifISO)
        result.lines.append("avif + ISOGainMap: finalize=\(avifISOOK) "
            + "aux=\(auxPresent(avifISO, kCGImageAuxiliaryDataTypeISOGainMap)) "
            + "headroom=\(fmt(result.avifISOHeadroom))")

        // MARK: AVIF — Apple spelling (raw aux + MakerApple)
        let avifApple = dir.appendingPathComponent("avif-apple.avif")
        var makerProps: [String: Any] = [:]
        makerProps[kCGImagePropertyMakerAppleDictionary as String] = ["33": 1.0, "48": 1.0]
        let avifAppleOK = writeSingle(avifApple, type: avif, image: baseImage(width: width, height: height,
                                                                            bits: 16),
                                      auxType: kCGImageAuxiliaryDataTypeHDRGainMap,
                                      aux: appleAux(width: width, height: height),
                                      properties: makerProps)
        result.avifAppleAccepted = avifAppleOK
        result.avifAppleHeadroom = headroom(of: avifApple)
        result.lines.append("avif + HDRGainMap + MakerApple: finalize=\(avifAppleOK) "
            + "aux=\(auxPresent(avifApple, kCGImageAuxiliaryDataTypeHDRGainMap)) "
            + "headroom=\(fmt(result.avifAppleHeadroom))")

        // MARK: AVIF — multi-image destination
        let avifMulti = dir.appendingPathComponent("avif-multi.avif")
        result.avifMultiImage = writeMulti(avifMulti, type: avif,
                                           image: baseImage(width: width, height: height, bits: 16),
                                           second: baseImage(width: width, height: height, bits: 16))
        result.lines.append("avif two-image destination: created=\(result.avifMultiImage) "
            + "count=\(imageCount(avifMulti))")

        return result
    }

    // MARK: - fixtures

    static func baseImage(width: Int, height: Int, bits: Int = 8,
                          space: CGColorSpace? = nil) -> CGImage {
        let space = space ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if bits == 8 {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for i in 0..<(width * height) {
                bytes[i * 4] = UInt8(i % 200)
                bytes[i * 4 + 1] = UInt8((i * 3) % 200)
                bytes[i * 4 + 2] = UInt8((i * 7) % 200)
                bytes[i * 4 + 3] = 255
            }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent)!
        }
        var words = [UInt16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            words[i * 4] = UInt16((i * 257) % 65535)
            words[i * 4 + 1] = UInt16((i * 3 * 257) % 65535)
            words[i * 4 + 2] = UInt16((i * 7 * 257) % 65535)
            words[i * 4 + 3] = 65535
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                | CGBitmapInfo.byteOrder16Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                       bytesPerRow: width * 8, space: space, bitmapInfo: info,
                       provider: CGDataProvider(data: words.withUnsafeBufferPointer { Data(buffer: $0) } as CFData)!,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func isoAux(width: Int, height: Int, headroom: Double = 4) -> [CFString: Any] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let g = UInt8(min(255, (i * 255) / max(1, width * height - 1)))
            bytes[i * 4] = 255
            bytes[i * 4 + 1] = g
            bytes[i * 4 + 2] = g
            bytes[i * 4 + 3] = g
        }
        let description: [String: Any] = [
            "PixelFormat": kCVPixelFormatType_32ARGB,
            "Width": String(width), "Height": String(height),
            "BytesPerRow": String(width * 4),
        ]
        var aux: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: Data(bytes) as CFData,
            kCGImageAuxiliaryDataInfoDataDescription: description,
        ]
        if let metadata = CGImageMetadataCreateFromXMPData(
            Data(GainMapHEIC.isoXMP(gainMapMax: log2(headroom), channels: 3).utf8) as CFData) {
            aux[kCGImageAuxiliaryDataInfoMetadata] = metadata
        }
        if let colorSpace = CGColorSpace(name: CGColorSpace.linearITUR_2020) {
            aux[kCGImageAuxiliaryDataInfoColorSpace] = colorSpace
        }
        return aux
    }

    static func appleAux(width: Int, height: Int) -> [CFString: Any] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            bytes[i] = UInt8(min(255, (i * 255) / max(1, width * height - 1)))
        }
        let description: [String: Any] = [
            "PixelFormat": kCVPixelFormatType_OneComponent8,
            "Width": String(width), "Height": String(height),
            "BytesPerRow": String(width),
        ]
        return [
            kCGImageAuxiliaryDataInfoData: Data(bytes) as CFData,
            kCGImageAuxiliaryDataInfoDataDescription: description,
        ]
    }

    // MARK: - writing / reading

    @discardableResult
    static func writeSingle(_ url: URL, type: UTType, image: CGImage,
                            auxType: CFString?, aux: [CFString: Any]?,
                            properties: [String: Any]? = nil) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         type.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary?)
        if let auxType, let aux {
            CGImageDestinationAddAuxiliaryDataInfo(dest, auxType, aux as CFDictionary)
        }
        return CGImageDestinationFinalize(dest)
    }

    static func writeMulti(_ url: URL, type: UTType, image: CGImage, second: CGImage) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         type.identifier as CFString, 2, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationAddImage(dest, second, nil)
        return CGImageDestinationFinalize(dest)
    }

    static func writeAppleJPEG(_ url: URL, image: CGImage, width: Int, height: Int,
                               headroom: Double) -> Bool {
        let gain = appleGainImage(width: width, height: height)
        guard let gain,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        let stops = log2(max(1.0001, headroom))
        let maker: [String: Any] = [
            "33": 1.0,
            "48": (2.30303 - stops) / 0.303,
        ]
        var properties: [String: Any] = [:]
        properties[kCGImagePropertyMakerAppleDictionary as String] = maker
        let base = CIImage(cgImage: image, options: [.properties: properties])
        let gainCI = CIImage(cgImage: gain)
        var options: [CIImageRepresentationOption: Any] = [.hdrGainMapImage: gainCI]
        options[CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String)] = 1.0
        do {
            try CIContext().writeJPEGRepresentation(of: base, to: url, colorSpace: space,
                                                    options: options)
            return true
        } catch {
            return false
        }
    }

    static func appleGainImage(width: Int, height: Int) -> CGImage? {
        guard let aux = appleAux(width: width, height: height)[kCGImageAuxiliaryDataInfoData] as? Data,
              let space = CGColorSpace(name: CGColorSpace.linearGray),
              let provider = CGDataProvider(data: aux as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    static func properties(of url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    static func headroom(of url: URL) -> Double? {
        guard #available(macOS 15.0, *) else { return nil }
        return CIImage(contentsOf: url, options: [.expandToHDR: true]).map {
            Double($0.contentHeadroom)
        }
    }

    static func auxPresent(_ url: URL, _ type: CFString) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil
    }

    static func imageCount(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return -1 }
        return CGImageSourceGetCount(source)
    }

    static func imageBits(_ url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image.bitsPerComponent
    }

    static func profile(of url: URL) -> String? {
        properties(of: url)?[kCGImagePropertyProfileName] as? String
    }

    private static func fmt(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "nil"
    }
}
