import XCTest
import CoreGraphics
import ImageIO
import PhotonsCore
@testable import PhotonsExport

/// 206 — PPI is a pixel fact, not a metadata policy: JPEG/TIFF/HEIC carry it in the TIFF block,
/// PNG in its `pHYs`/DPI pair, and `.none` / `.copyrightOnly` still write it. `ppi = nil` keeps the
/// pre-206 output, which is what makes an old preset byte-identical.
final class ExportResolutionTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-resolution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - fixtures

    private func image(width: Int = 64, height: Int = 48) -> DisplayImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                rgba[o] = Float16(Double(x) / Double(width))
                rgba[o + 1] = Float16(Double(y) / Double(height))
                rgba[o + 2] = 0.5
                rgba[o + 3] = 1
            }
        }
        return DisplayImage(width: width, height: height, rgba: rgba,
                            primaries: .displayP3, bitDepth: 8)
    }

    @discardableResult
    private func export(_ format: ExportFormat, ppi: Int?, level: ExportMetadataLevel = .none,
                        name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        let metadata = ExportMetadataContext(level: level, author: "Ada", copyright: "© 2026 Ada",
                                             ppi: ppi)
        try Exporter.write(image(), to: url, options: ExportOptions(format: format, bitDepth: 8),
                           metadata: metadata)
        return url
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let raw = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        if let d = raw as? [CFString: Any] { return d }
        let d = raw as! [String: Any]
        var out: [CFString: Any] = [:]
        for (key, value) in d { out[key as CFString] = value }
        return out
    }

    private func tiff(_ url: URL) throws -> [CFString: Any] {
        let value = try properties(of: url)[kCGImagePropertyTIFFDictionary]
        if let d = value as? [CFString: Any] { return d }
        if let d = value as? [String: Any] {
            var out: [CFString: Any] = [:]
            for (key, value) in d { out[key as CFString] = value }
            return out
        }
        return [:]
    }

    // MARK: - 240 readback

    func testJPEGAndTIFFCarryXResolution240AndInchUnit() throws {
        for format in [ExportFormat.jpeg, .tiff] {
            let url = try export(format, ppi: 240, name: "r240.\(format.fileExtension)")
            let tags = try tiff(url)
            print("206 \(format.rawValue) XResolution \(tags[kCGImagePropertyTIFFXResolution] ?? "nil")"
                  + " unit \(tags[kCGImagePropertyTIFFResolutionUnit] ?? "nil")")
            XCTAssertEqual(tags[kCGImagePropertyTIFFXResolution] as? Double, 240)
            XCTAssertEqual(tags[kCGImagePropertyTIFFYResolution] as? Double, 240)
            XCTAssertEqual(tags[kCGImagePropertyTIFFResolutionUnit] as? Int, 2,
                           "\(format.rawValue) must say inch (2), not cm (3)")
        }
    }

    func testHEICCarriesTheTIFFBlockAndPNGCarriesDPI() throws {
        let heic = try export(.heic, ppi: 240, name: "r240.heic")
        let heicTags = try tiff(heic)
        XCTAssertEqual(heicTags[kCGImagePropertyTIFFXResolution] as? Double, 240)
        XCTAssertEqual(heicTags[kCGImagePropertyTIFFResolutionUnit] as? Int, 2)

        let png = try export(.png, ppi: 240, name: "r240.png")
        let pngProperties = try properties(of: png)
        print("206 png DPI \(pngProperties[kCGImagePropertyDPIWidth] ?? "nil")"
              + "×\(pngProperties[kCGImagePropertyDPIHeight] ?? "nil")")
        XCTAssertEqual(pngProperties[kCGImagePropertyDPIWidth] as? Double, 240)
        XCTAssertEqual(pngProperties[kCGImagePropertyDPIHeight] as? Double, 240)
    }

    // MARK: - nil means no tag at all (pre-206 output)

    func testNilPPIWritesNoResolutionKeys() throws {
        for format in [ExportFormat.jpeg, .tiff, .png, .heic] {
            let url = try export(format, ppi: nil, name: "none.\(format.fileExtension)")
            let properties = try properties(of: url)
            let tags = try tiff(url)
            XCTAssertNil(tags[kCGImagePropertyTIFFXResolution],
                         "\(format.rawValue) wrote a resolution for ppi = nil")
            XCTAssertNil(tags[kCGImagePropertyTIFFYResolution])
            // ImageIO's TIFF writer emits `ResolutionUnit = 2` as a structural tag even for an empty
            // property dictionary (measured on macOS 27), so only the containers that carry it from
            // our dictionary can be asserted absent.
            if format != .tiff {
                XCTAssertNil(tags[kCGImagePropertyTIFFResolutionUnit],
                             "\(format.rawValue) wrote a unit for ppi = nil")
            }
            XCTAssertNil(properties[kCGImagePropertyDPIWidth],
                         "\(format.rawValue) wrote DPI for ppi = nil")
            XCTAssertNil(properties[kCGImagePropertyDPIHeight])
        }
    }

    // MARK: - the policy does not own resolution

    func testResolutionIsWrittenUnderNoneAndCopyrightOnly() throws {
        let noneJPEG = try export(.jpeg, ppi: 240, level: .none, name: "none-policy.jpg")
        XCTAssertEqual(try tiff(noneJPEG)[kCGImagePropertyTIFFXResolution] as? Double, 240,
                       "`.none` still writes the pixel fact")

        let nonePNG = try export(.png, ppi: 240, level: .none, name: "none-policy.png")
        XCTAssertEqual(try properties(of: nonePNG)[kCGImagePropertyDPIWidth] as? Double, 240,
                       "the `.none` PNG strip pass must keep DPI")

        let copyright = try export(.jpeg, ppi: 240, level: .copyright, name: "copyright.jpg")
        XCTAssertEqual(try tiff(copyright)[kCGImagePropertyTIFFXResolution] as? Double, 240)

        let all = try export(.jpeg, ppi: 240, level: .all, name: "all.jpg")
        XCTAssertEqual(try tiff(all)[kCGImagePropertyTIFFXResolution] as? Double, 240)
    }

    // MARK: - clamping

    func testOutOfRangePPIIsClampedNotRejected() throws {
        XCTAssertEqual(ExportPreset(ppi: 10).effectivePPI, 72)
        XCTAssertEqual(ExportPreset(ppi: 700).effectivePPI, 600)
        XCTAssertNil(ExportPreset(ppi: nil).effectivePPI)

        let low = try export(.jpeg, ppi: 10, name: "low.jpg")
        XCTAssertEqual(try tiff(low)[kCGImagePropertyTIFFXResolution] as? Double, 72)
        let high = try export(.tiff, ppi: 700, name: "high.tif")
        XCTAssertEqual(try tiff(high)[kCGImagePropertyTIFFXResolution] as? Double, 600)
    }
}
