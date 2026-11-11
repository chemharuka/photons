import XCTest
import CoreImage
@testable import PhotonsExtensions

/// End-to-end on the real 60 MP capture: decode the mosaic, shift it, write it back, and confirm
/// Core Image still renders the same picture at full size.
///
/// This is the test that would have caught the all-black DNG: it asserts a *mean*, not just that a
/// render returned non-nil. It is guarded by the fixture file (the 60 MB reference RAW is not in the
/// repository) and skips with a loud message when absent, rather than silently passing.
final class DNGRawWriterFullSizeTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func fixture() throws -> URL {
        let url = Self.repoRoot.appendingPathComponent("Tests/Fixtures/sl3-iso3200.dng")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("缺少 \(url.lastPathComponent)（60 MB 实拍 RAW，见 Tests/Fixtures/README.md）")
        }
        return url
    }

    func testFullSizeRoundTripKeepsGeometryMetadataAndBrightness() throws {
        let source = try fixture()
        let data = try Data(contentsOf: source, options: .alwaysMapped)
        let doc = try SourceDNG(data: data)
        var mosaic = try doc.readMosaic(data: data)
        XCTAssertGreaterThan(mosaic.width * mosaic.height, 50_000_000, "这份 fixture 应该是 60 MP")

        for i in mosaic.samples.indices where mosaic.samples[i] > 512 {
            mosaic.samples[i] -= 1
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-60mp-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: output) }

        let started = Date()
        let result = try DNGRawWriter.write(samples: mosaic.samples,
                                            width: mosaic.width, height: mosaic.height,
                                            from: source, to: output)
        let seconds = Date().timeIntervalSince(started)
        print("60 MP 写入: \(result.byteCount / 1_000_000) MB, \(result.tileCount) tiles, "
              + "压缩比 \(Int((1 - result.compressedFraction) * 100))%, \(String(format: "%.2f", seconds)) s")

        XCTAssertLessThan(result.compressedFraction, 0.7, "压缩效果不足")

        // Metadata: the optical model must be byte-identical.
        let written = try SourceDNG(url: output)
        for tag: UInt16 in [51022, 51041, 50714, 50717, 50829] {
            let original = doc.raw[tag] ?? doc.ifd0[tag]
            XCTAssertEqual(written.ifd0[tag]?.value, original?.value, "tag \(tag) 未逐字节保留")
        }
        XCTAssertEqual(written.exif?.count, doc.exif?.count)
        XCTAssertEqual(written.gps?.count, doc.gps?.count)

        // Pixels: decode through our own SOF3 reader and compare.
        let decoded = try written.readMosaic(data: try Data(contentsOf: output))
        XCTAssertEqual(decoded.width, mosaic.width)
        XCTAssertEqual(decoded.height, mosaic.height)
        XCTAssertEqual(decoded.samples, mosaic.samples)

        // And the thing that actually matters to a user: Core Image renders it, at full size, and
        // it is not black. `nativeSize` is 9520×6336 for this body (ActiveArea trims the margins).
        guard let filter = CIRAWFilter(imageURL: output) else { return XCTFail("CIRAWFilter 失败") }
        XCTAssertEqual(filter.nativeSize.width, 9520)
        XCTAssertEqual(filter.nativeSize.height, 6336)
        guard let image = filter.outputImage else { return XCTFail("outputImage 为 nil（全黑 DNG 就是这样）") }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        // Render a centre crop rather than all 60 MP: the statistic is what matters here.
        let crop = CGRect(x: 2000, y: 2000, width: 512, height: 512)
        guard let cg = context.createCGImage(image, from: crop) else { return XCTFail("createCGImage 失败") }
        var buffer = [UInt8](repeating: 0, count: 512 * 512 * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buffer, width: 512, height: 512, bitsPerComponent: 8,
                                  bytesPerRow: 512 * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return XCTFail("CGContext 失败")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 512, height: 512))
        var sum = 0.0
        for i in stride(from: 0, to: buffer.count, by: 4) {
            sum += Double(Int(buffer[i]) + Int(buffer[i + 1]) + Int(buffer[i + 2])) / 3.0
        }
        let mean = sum / Double(512 * 512)
        XCTAssertGreaterThan(mean, 5.0, "裁剪区渲染成全黑（mean=\(mean)）")
    }
}
