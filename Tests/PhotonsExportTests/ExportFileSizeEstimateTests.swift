import XCTest
import PhotonsCore
@testable import PhotonsExport

final class ExportFileSizeEstimateTests: XCTestCase {
    private let photo = ImageSize(width: 6000, height: 4000)

    func testSizingAndBatchTotalsUseOutputPixels() throws {
        var preset = ExportPreset(format: .jpeg, sizingMode: .percent, percent: 50)
        let half = try XCTUnwrap(ExportFileSizeEstimator.estimate(contents: [photo], preset: preset))
        XCTAssertEqual(half, ExportFileSizeEstimator.file(output: .init(width: 3000, height: 2000), preset: preset))
        preset.sizingMode = .longEdge; preset.longEdge = 3000
        XCTAssertEqual(half, ExportFileSizeEstimator.estimate(contents: [photo], preset: preset))
        let batch = try XCTUnwrap(ExportFileSizeEstimator.estimate(contents: [photo, photo], preset: preset))
        XCTAssertEqual(batch.fileCount, 2)
        XCTAssertEqual(batch.lowerBytes, half.lowerBytes * 2)
        XCTAssertEqual(batch.upperBytes, half.upperBytes * 2)
        preset.longEdge = 12000; preset.noUpscale = true
        XCTAssertEqual(ExportFileSizeEstimator.estimate(contents: [photo], preset: preset),
                       ExportFileSizeEstimator.file(output: photo, preset: preset))
    }

    func testQualityAndHDRGainMapResolutionAffectEstimate() throws {
        var preset = ExportPreset(format: .jpeg, quality: 0.6)
        let low = try XCTUnwrap(ExportFileSizeEstimator.file(output: photo, preset: preset))
        preset.quality = 1
        let high = try XCTUnwrap(ExportFileSizeEstimator.file(output: photo, preset: preset))
        preset.hdr = HDRExport(gainMap: .iso, halfSize: true)
        let halfMap = try XCTUnwrap(ExportFileSizeEstimator.file(output: photo, preset: preset))
        preset.hdr?.halfSize = false
        let fullMap = try XCTUnwrap(ExportFileSizeEstimator.file(output: photo, preset: preset))
        XCTAssertLessThan(low.upperBytes, high.upperBytes)
        XCTAssertLessThan(high.upperBytes, halfMap.upperBytes)
        XCTAssertLessThan(halfMap.upperBytes, fullMap.upperBytes)
    }

    func testTIFFDepthAndCompressedFormats() throws {
        var preset = ExportPreset(format: .tiff, bitDepth: 8)
        let eight = try XCTUnwrap(ExportFileSizeEstimator.file(output: photo, preset: preset))
        preset.bitDepth = 16
        let sixteen = try XCTUnwrap(ExportFileSizeEstimator.file(output: photo, preset: preset))
        XCTAssertGreaterThan(sixteen.lowerBytes, eight.upperBytes)
        for format in [ExportFormat.jpeg, .heic, .avif, .png] {
            preset = ExportPreset(format: format)
            let compressed = try XCTUnwrap(ExportFileSizeEstimator.file(output: photo, preset: preset))
            XCTAssertGreaterThan(compressed.lowerBytes, 0)
            XCTAssertLessThan(compressed.lowerBytes, compressed.upperBytes)
            XCTAssertLessThan(compressed.upperBytes, sixteen.lowerBytes)
        }
    }

    func testDNGIgnoresInactiveCodecAndGainMapSettingsAndKeepsOddPixels() throws {
        var preset = ExportPreset(format: .jpeg, quality: 0.6, hdr: HDRExport(gainMap: .iso, halfSize: true))
        let odd = ImageSize(width: 257, height: 257)
        let dng = try XCTUnwrap(ExportFileSizeEstimator.estimate(contents: [odd], preset: preset, linearDNG: true))
        preset.format = .tiff; preset.bitDepth = 16; preset.quality = 1; preset.hdr = nil
        XCTAssertEqual(dng, ExportFileSizeEstimator.estimate(contents: [odd], preset: preset, linearDNG: true))
        let even = try XCTUnwrap(ExportFileSizeEstimator.estimate(contents: [.init(width: 256, height: 256)], preset: preset, linearDNG: true))
        XCTAssertGreaterThan(dng.upperBytes, even.upperBytes, "257 pixels require four DNG tiles; gain-map trimming must not drop them")
    }

    func testUnknownInvalidAndHugeDimensionsAreSafe() throws {
        let preset = ExportPreset(format: .jpeg)
        XCTAssertNil(ExportFileSizeEstimator.estimate(contents: [], preset: preset))
        var invalid = photo
        invalid.width = 0
        XCTAssertNil(ExportFileSizeEstimator.estimate(contents: [photo, invalid], preset: preset))
        let huge = try XCTUnwrap(ExportFileSizeEstimator.file(output: .init(width: Int.max, height: Int.max), preset: preset))
        XCTAssertEqual(huge.upperBytes, Int64.max)
        XCTAssertEqual(ExportFileSizeEstimate.total([huge, huge])?.upperBytes, Int64.max)
    }
}
