import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PhotonsCore
@testable import PhotonsExport

/// 107 — the exported file keeps the source's EXIF/TIFF/GPS/IPTC and an embedded `crs:` packet.
///
/// Every assertion reads the **written** file back with ImageIO: trusting the dictionary we passed
/// to `CGImageDestinationAddImage` would not notice a container that silently dropped it.
final class ExportMetadataTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-export-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - fixtures

    private let sourceWidth = 120
    private let sourceHeight = 80
    private let sourceDate = "2026:03:07 10:00:00"

    /// A source JPEG with the same blocks a camera writes. Orientation 6 on purpose: the export
    /// must write 1, because the renderer has already turned the pixels.
    private func makeSource() throws -> URL {
        let url = scratch.appendingPathComponent("source.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: sourceDate,
                kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [400],
                kCGImagePropertyExifFocalLength: 50.0,
                kCGImagePropertyExifFocalLenIn35mmFilm: 50,
                kCGImagePropertyExifLensModel: "Summilux-M 1:1.4/50 ASPH.",
                kCGImagePropertyExifLensMake: "LEICA CAMERA AG",
                kCGImagePropertyExifExposureBiasValue: 0.0,
                kCGImagePropertyExifFlash: 16,
                kCGImagePropertyExifWhiteBalance: 0,
                kCGImagePropertyExifColorSpace: 1,
                kCGImagePropertyExifPixelXDimension: sourceWidth,
                kCGImagePropertyExifPixelYDimension: sourceHeight,
                kCGImagePropertyExifUserComment: "shot for the metadata test",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "LEICA CAMERA AG",
                kCGImagePropertyTIFFModel: "LEICA SL3",
                kCGImagePropertyTIFFOrientation: 6,
                kCGImagePropertyTIFFDateTime: sourceDate,
                kCGImagePropertyTIFFArtist: "Ada Lovelace",
                kCGImagePropertyTIFFCopyright: "© 2026 Ada",
                kCGImagePropertyTIFFSoftware: "Photons test fixture",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 31.2304,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 121.4737,
                kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCKeywords: ["travel", "coast"],
                kCGImagePropertyIPTCCopyrightNotice: "© 2026 Ada",
            ],
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
        CGImageDestinationAddImage(dest, try cgImage(width: sourceWidth, height: sourceHeight),
                                   properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func cgImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                bytes[o] = UInt8((x * 255) / max(1, width - 1))
                bytes[o + 1] = UInt8((y * 255) / max(1, height - 1))
                bytes[o + 2] = UInt8(((x + y) * 7) & 0xFF)
                bytes[o + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                                     bitsPerPixel: 32, bytesPerRow: width * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue:
                                        CGImageAlphaInfo.noneSkipLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false,
                                     intent: .defaultIntent))
    }

    private func displayImage(width: Int, height: Int) -> DisplayImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let t = Float(x) / Float(max(1, width - 1))
                rgba[o] = Float16(0.05 + 0.9 * t)
                rgba[o + 1] = Float16(0.05 + 0.7 * t)
                rgba[o + 2] = Float16(0.05 + 0.5 * t)
                rgba[o + 3] = 1
            }
        }
        return DisplayImage(width: width, height: height, rgba: rgba,
                            primaries: .displayP3, bitDepth: 8)
    }

    /// An SDR base plus the linear exit (values above 1) so `Exporter.write` takes the gain-map path.
    private func hdrPair(width: Int = 64, height: Int = 48) -> DisplayImage {
        let sdr = displayImage(width: width, height: height)
        var linear = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let t = Float(x) / Float(max(1, width - 1))
                linear[o] = Float16(0.05 + 3.0 * t)
                linear[o + 1] = Float16(0.05 + 2.4 * t)
                linear[o + 2] = Float16(0.05 + 1.8 * t)
                linear[o + 3] = 1
            }
        }
        let slices = DisplayImage(width: width, height: height, rgba: linear,
                                  primaries: .displayP3, bitDepth: 16)
        return sdr.withLinear(LinearPixels(slices))
    }

    // MARK: - readback helpers

    private func properties(of url: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let raw = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        if let d = raw as? [String: Any] { return d }
        let cd = raw as! [CFString: Any]
        var out: [String: Any] = [:]
        for (key, value) in cd { out[key as String] = value }
        return out
    }

    private func dictionary(_ props: [String: Any], _ key: CFString) -> [String: Any] {
        props[key as String] as? [String: Any] ?? [:]
    }

    private func intValue(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    private func metadataContext(_ source: URL, level: ExportMetadataLevel = .all,
                                 edit: EditModel? = nil, author: String? = nil,
                                 copyright: String? = nil, embedXMP: Bool = false)
        -> ExportMetadataContext {
        ExportMetadataContext(level: level, source: SourceMetadata.read(from: source),
                              edit: edit, author: author, copyright: copyright,
                              embedXMP: embedXMP)
    }

    private func assertCameraBlocks(_ props: [String: Any], width: Int, height: Int,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let exif = dictionary(props, kCGImagePropertyExifDictionary)
        let tiff = dictionary(props, kCGImagePropertyTIFFDictionary)

        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake as String] as? String, "LEICA CAMERA AG",
                       "make", file: file, line: line)
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel as String] as? String, "LEICA SL3",
                       file: file, line: line)
        XCTAssertEqual(intValue(tiff[kCGImagePropertyTIFFOrientation as String]), 1,
                       "orientation must be baked to 1", file: file, line: line)
        XCTAssertFalse((exif[kCGImagePropertyExifLensModel as String] as? String ?? "").isEmpty,
                       "lens model", file: file, line: line)
        XCTAssertEqual((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?
                        .map(\.intValue), [400], file: file, line: line)
        XCTAssertEqual(intValue(exif[kCGImagePropertyExifPixelXDimension as String]), width,
                       file: file, line: line)
        XCTAssertEqual(intValue(exif[kCGImagePropertyExifPixelYDimension as String]), height,
                       file: file, line: line)
        let original = date(exif[kCGImagePropertyExifDateTimeOriginal as String])
        let expected = date(sourceDate)
        XCTAssertNotNil(original, file: file, line: line)
        if let original, let expected {
            XCTAssertLessThanOrEqual(abs(original.timeIntervalSince(expected)), 1,
                                     "capture time", file: file, line: line)
        }
        XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist as String] as? String, "Ada Lovelace",
                       file: file, line: line)
        XCTAssertEqual(tiff[kCGImagePropertyTIFFCopyright as String] as? String, "© 2026 Ada",
                       file: file, line: line)
        let gps = dictionary(props, kCGImagePropertyGPSDictionary)
        XCTAssertEqual((gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue ?? .nan,
                       31.2304, accuracy: 1e-6, file: file, line: line)
    }

    // MARK: - 1. JPEG

    func testJPEGCarriesExifTiffGpsAndSourceFields() throws {
        let source = try makeSource()
        let out = scratch.appendingPathComponent("out.jpg")
        let image = displayImage(width: sourceWidth, height: sourceHeight)
        try Exporter.write(image, to: out, options: ExportOptions(format: .jpeg, quality: 0.9),
                           metadata: metadataContext(source))

        let props = try properties(of: out)
        assertCameraBlocks(props, width: sourceWidth, height: sourceHeight)
        let iptc = dictionary(props, kCGImagePropertyIPTCDictionary)
        XCTAssertEqual(iptc[kCGImagePropertyIPTCKeywords as String] as? [String],
                       ["travel", "coast"])
    }

    func testPixelDimensionsAreTheOutputSizeNotTheSourceSize() throws {
        let source = try makeSource()
        let out = scratch.appendingPathComponent("scaled.jpg")
        // The renderer's output, after a 0.25 scale: 30×20, not the 120×80 source.
        let image = displayImage(width: 30, height: 20)
        try Exporter.write(image, to: out, options: ExportOptions(format: .jpeg),
                           metadata: metadataContext(source))

        let exif = dictionary(try properties(of: out), kCGImagePropertyExifDictionary)
        XCTAssertEqual(intValue(exif[kCGImagePropertyExifPixelXDimension as String]), 30)
        XCTAssertEqual(intValue(exif[kCGImagePropertyExifPixelYDimension as String]), 20)
        XCTAssertNotEqual(intValue(exif[kCGImagePropertyExifPixelXDimension as String]), sourceWidth)
    }

    // MARK: - 2. HDR HEIC

    @available(macOS 15.0, *)
    func testHDRHEICCarriesMetadataOnTheISOPath() throws {
        let source = try makeSource()
        let out = scratch.appendingPathComponent("hdr-iso.heic")
        let image = hdrPair()
        let options = ExportOptions(format: .heic, quality: 0.9, bitDepth: 8,
                                    hdr: HDRExport(enabled: true, gainMap: .iso))
        let ctx = metadataContext(source, edit: .neutral, embedXMP: true)
        try Exporter.write(image, to: out, options: options, metadata: ctx)

        let props = try properties(of: out)
        assertCameraBlocks(props, width: 64, height: 48)
        let headroom = try XCTUnwrap(GainMapHEIC.readHeadroom(at: out))
        XCTAssertGreaterThan(headroom, 1.05)
        // The embedded packet and the source metadata live in the same container.
        let metadata = try XCTUnwrap(XMPReadback.metadata(of: out))
        XCTAssertEqual(XMPReadback.string(metadata, "crs:Version"), XMPNamespace.crsVersion)
    }

    func testHDRHEICCarriesMetadataOnTheApplePath() throws {
        let source = try makeSource()
        let out = scratch.appendingPathComponent("hdr-apple.heic")
        let image = hdrPair()
        let options = ExportOptions(format: .heic, quality: 0.9, bitDepth: 8,
                                    hdr: HDRExport(enabled: true, gainMap: .apple))
        try Exporter.write(image, to: out, options: options,
                           metadata: metadataContext(source, edit: .neutral, embedXMP: true))

        let props = try properties(of: out)
        assertCameraBlocks(props, width: 64, height: 48)
        let headroom = try XCTUnwrap(GainMapHEIC.readHeadroom(at: out))
        XCTAssertGreaterThan(headroom, 1.05, "the metadata pass must not drop the gain map")
        let metadata = try XCTUnwrap(XMPReadback.metadata(of: out))
        XCTAssertEqual(XMPReadback.string(metadata, "crs:Version"), XMPNamespace.crsVersion)
    }

    // MARK: - 3. metadataLevel

    func testNoneWritesNoMetadataBlocks() throws {
        let source = try makeSource()
        let out = scratch.appendingPathComponent("none.jpg")
        try Exporter.write(displayImage(width: 64, height: 48), to: out,
                           options: ExportOptions(format: .jpeg),
                           metadata: metadataContext(source, level: .none))

        let props = try properties(of: out)
        XCTAssertTrue(dictionary(props, kCGImagePropertyExifDictionary).isEmpty)
        XCTAssertTrue(dictionary(props, kCGImagePropertyTIFFDictionary).isEmpty)
        XCTAssertTrue(dictionary(props, kCGImagePropertyGPSDictionary).isEmpty)
        let xmp = XMPReadback.metadata(of: out)
        XCTAssertNil(xmp.map { XMPReadback.string($0, "crs:Version") } ?? nil)
    }

    func testCopyrightKeepsOnlyArtistAndCopyright() throws {
        let source = try makeSource()
        let out = scratch.appendingPathComponent("copyright.jpg")
        try Exporter.write(displayImage(width: 64, height: 48), to: out,
                           options: ExportOptions(format: .jpeg),
                           metadata: metadataContext(source, level: .copyright))

        let props = try properties(of: out)
        let exif = dictionary(props, kCGImagePropertyExifDictionary)
        let tiff = dictionary(props, kCGImagePropertyTIFFDictionary)
        XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist as String] as? String, "Ada Lovelace")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFCopyright as String] as? String, "© 2026 Ada")
        XCTAssertNil(tiff[kCGImagePropertyTIFFMake as String], "make is not copyright metadata")
        XCTAssertNil(tiff[kCGImagePropertyTIFFModel as String])
        XCTAssertNil(exif[kCGImagePropertyExifLensModel as String])
        XCTAssertNil(exif[kCGImagePropertyExifISOSpeedRatings as String])
        XCTAssertTrue(dictionary(props, kCGImagePropertyGPSDictionary).isEmpty)
    }

    // MARK: - 4. TIFF / PNG

    func testTIFFCarriesTheSameBlocks() throws {
        let source = try makeSource()
        let out = scratch.appendingPathComponent("out.tif")
        try Exporter.write(displayImage(width: 60, height: 40), to: out,
                           options: ExportOptions(format: .tiff),
                           metadata: metadataContext(source))

        let props = try properties(of: out)
        assertCameraBlocks(props, width: 60, height: 40)
    }

    func testPNGCarriesMetadataAndNoneStripsIt() throws {
        let source = try makeSource()
        let with = scratch.appendingPathComponent("with.png")
        try Exporter.write(displayImage(width: 60, height: 40), to: with,
                           options: ExportOptions(format: .png),
                           metadata: metadataContext(source))
        let props = try properties(of: with)
        // PNG's metadata surface is the thinnest of the four; the blocks that ImageIO keeps must be
        // the output's, and the export must not fail on the ones it does not.
        let pngExif = dictionary(props, kCGImagePropertyExifDictionary)
        let pngTiff = dictionary(props, kCGImagePropertyTIFFDictionary)
        XCTAssertEqual(intValue(pngExif[kCGImagePropertyExifPixelXDimension as String]), 60)
        XCTAssertEqual(intValue(pngTiff[kCGImagePropertyTIFFOrientation as String]), 1)

        let without = scratch.appendingPathComponent("without.png")
        try Exporter.write(displayImage(width: 60, height: 40), to: without,
                           options: ExportOptions(format: .png),
                           metadata: metadataContext(source, level: .none))
        let bare = try properties(of: without)
        XCTAssertTrue(dictionary(bare, kCGImagePropertyExifDictionary).isEmpty)
        XCTAssertTrue(dictionary(bare, kCGImagePropertyTIFFDictionary).isEmpty)
        XCTAssertTrue(dictionary(bare, kCGImagePropertyGPSDictionary).isEmpty)
    }

    // MARK: - 5. batch engine passes the source through, sidecar rules unchanged

    func testBatchExportScalesMetadataAndEmbedsThePacket() throws {
        let source = try makeSource()
        var edit = EditModel.neutral
        edit.light.exposure = 0.75
        let item = ExportItem(id: "1", name: "a", edit: edit, sourceURL: source)
        let report = BatchExporter.run(items: [item],
                                       preset: ExportPreset(format: .jpeg, writeXMP: true,
                                                            sizingMode: .percent, percent: 25),
                                       outputDirectory: scratch,
                                       render: { _, _ in
            self.displayImage(width: self.sourceWidth, height: self.sourceHeight)
        })
        let url = try XCTUnwrap(report.written.first?.fileURL)
        let props = try properties(of: url)
        assertCameraBlocks(props, width: 30, height: 20)
        let metadata = try XCTUnwrap(XMPReadback.metadata(of: url))
        XCTAssertEqual(XMPReadback.string(metadata, "crs:Version"), XMPNamespace.crsVersion)
        XCTAssertEqual(XMPReadback.double(metadata, "crs:Exposure2012") ?? 0, 0.75, accuracy: 1e-6)
        XCTAssertEqual(report.written.first?.xmpURL, url, "the packet is embedded, not beside")
    }

    func testSixteenBitPNGKeepsTheSidecarRuleAndMetadata() throws {
        let source = try makeSource()
        var edit = EditModel.neutral
        edit.color.saturation = 12
        let item = ExportItem(id: "1", name: "a", edit: edit, sourceURL: source)
        let report = BatchExporter.run(items: [item],
                                       preset: ExportPreset(format: .png, bitDepth: 16,
                                                            writeXMP: true),
                                       outputDirectory: scratch,
                                       render: { _, _ in self.displayImage(width: 64, height: 48) })
        let url = try XCTUnwrap(report.written.first?.fileURL)
        let sidecar = url.deletingPathExtension().appendingPathExtension("xmp")
        XCTAssertEqual(report.written.first?.xmpURL, sidecar)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        let metadata = try XCTUnwrap(XMPReadback.metadata(fromXMP: sidecar))
        XCTAssertEqual(XMPReadback.double(metadata, "crs:Saturation") ?? 0, 12, accuracy: 1e-6)
        let pngSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let pngImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(pngSource, 0, nil))
        XCTAssertEqual(pngImage.bitsPerComponent, 16)
        let props = try properties(of: url)
        let tiff = dictionary(props, kCGImagePropertyTIFFDictionary)
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake as String] as? String, "LEICA CAMERA AG")
    }
}
