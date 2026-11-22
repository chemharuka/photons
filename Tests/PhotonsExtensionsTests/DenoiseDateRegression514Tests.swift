import XCTest
import Foundation
import ImageIO
@testable import PhotonsExtensions

/// 514 — regression on the **real** capture: one real denoise, then the four date tags must come out
/// of the product byte for byte identical to the source's (`0x0132` in IFD0, `0x9003` / `0x9004` /
/// `0x9291` in the EXIF sub-IFD).
///
/// This is the assertion the 514 investigation ended on: the writer already preserves those tags
/// (measured `2026:10:02 13:21:33` + `667` in, the same bytes out), so the test exists to keep it
/// that way — anyone who touches `layoutTags` or the EXIF sub-IFD move turns this red immediately.
/// 512's "the product is five months off" came from comparing a synthetic fixture's seeded
/// `capture_time` against this file's EXIF; `13:21:33+08:00` is `05:21:33Z`, not a different day.
///
/// A full 60 MP denoise takes ~15 minutes, so it is gated twice: `PHOTONS_TEST_RAW` picks the file
/// and `PHOTONS_TEST_SLOW=1` opts into the runtime (same convention as the Ansel 60 MP test).
/// The fast byte-level version is `DNGRawWriterTests.testCaptureDateTagsSurviveByteForByte`.
final class DenoiseDateRegression514Tests: XCTestCase {

    private static let dateTags: [UInt16] = [0x0132, 0x9003, 0x9004, 0x9291]

    private func dateTag(_ doc: SourceDNG, _ tag: UInt16) -> TIFFEntry? {
        doc.exif?[tag] ?? doc.ifd0[tag]
    }

    func testRealRawDenoiseKeepsEveryDateTag() throws {
        let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"] ?? ""
        let source = URL(fileURLWithPath: env)
        try XCTSkipIf(env.isEmpty || !FileManager.default.fileExists(atPath: source.path),
                      "PHOTONS_TEST_RAW 未设置")
        try XCTSkipIf(ProcessInfo.processInfo.environment["PHOTONS_TEST_SLOW"] != "1",
                      "60 MP 真降噪约 15 分钟；设 PHOTONS_TEST_SLOW=1 才跑")

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-514-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: output) }

        let job = BuiltinDenoiseJob(options: BuiltinDenoiseJob.Options(amount: 100))
        _ = try job.denoise(input: source, output: output)

        let original = try SourceDNG(url: source)
        let product = try SourceDNG(url: output)

        for tag in Self.dateTags {
            let before = try XCTUnwrap(dateTag(original, tag), "源文件应有 tag \(tag)")
            let after = try XCTUnwrap(dateTag(product, tag), "产物里 tag \(tag) 丢了")
            XCTAssertEqual(after.type, before.type, "tag \(tag) 的类型变了")
            XCTAssertEqual(after.count, before.count, "tag \(tag) 的 count 变了")
            XCTAssertEqual(after.value, before.value, "tag \(tag) 的 payload 变了")
        }

        // The sub-IFD that carries DateTimeOriginal arrives whole, and its pointer is rewritten (it
        // has to be — the offset moved), not dropped.
        XCTAssertEqual(product.exif?.count, original.exif?.count, "EXIF 项数变了")
        XCTAssertNotNil(product.ifd0[34665], "产物的 ExifIFD 指针丢了")

        // And the reader the catalog uses agrees with the bytes.
        let read = try MetadataReaderProbe.captureDate(at: output)
        XCTAssertEqual(read, MetadataReaderProbe.captureDate(at: source),
                       "导入侧读到的拍摄时间与源不一致")
    }
}

/// The catalog's reader is in another module, so the test reaches the same value through ImageIO.
private enum MetadataReaderProbe {
    static func captureDate(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }
        let exif = (props[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
        return exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
    }
}
