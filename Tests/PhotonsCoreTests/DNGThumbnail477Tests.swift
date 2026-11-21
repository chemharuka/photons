import XCTest
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import CryptoKit
@testable import PhotonsCore

/// 477 — the embedded preview replacement. The promises are the same as `DNGXMP`'s: the raw picture
/// does not move, the preview really becomes the requested size, and a read-only file fails with one
/// sentence and zero changed bytes.
final class DNGThumbnail477Tests: XCTestCase {

    private var source: URL {
        let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"]
        return URL(fileURLWithPath: env ?? NSString(string: "~/Desktop/test/L1030433.dng")
            .expandingTildeInPath)
    }

    private func copyOfSource() throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("no test RAW at \(source.path)")
        }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("dngthumb-\(UUID().uuidString).dng")
        try FileManager.default.copyItem(at: source, to: dst)
        addTeardownBlock { try? FileManager.default.removeItem(at: dst) }
        return dst
    }

    private func journal() -> DNGXMPJournal {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dngthumb-journal-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return DNGXMPJournal(directory: dir)
    }

    private func solidImage(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func decodedSHA(_ url: URL) throws -> String {
        let image = try RAWDecoder().decode(url, options: DecodeOptions(scale: 0.125))
        var hasher = SHA256()
        image.rgba.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func mainImageSize(_ url: URL) -> ImageSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return ImageSize(width: w, height: h)
    }

    /// The external reader the brief names. `nil` when `sips` is unavailable; the ImageIO assertion
    /// above still runs.
    private func sipsSize(_ url: URL) -> ImageSize? {
        let sips = URL(fileURLWithPath: "/usr/bin/sips")
        guard FileManager.default.isExecutableFile(atPath: sips.path) else { return nil }
        let process = Process()
        process.executableURL = sips
        process.arguments = ["-g", "pixelWidth", "-g", "pixelHeight", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let numbers = text.split(separator: "\n").compactMap { line -> Int? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        guard numbers.count >= 2 else { return nil }
        return ImageSize(width: numbers[0], height: numbers[1])
    }

    // MARK: - the size rule

    func testTheFourSizeExamplesFromTheBrief() {
        let a = DNGThumbnail.targetSize(forCrop: ImageSize(width: 6000, height: 4000))
        XCTAssertEqual(a, ImageSize(width: 1920, height: 1280))       // 1500 → 1920

        let b = DNGThumbnail.targetSize(forCrop: ImageSize(width: 3000, height: 2000))
        XCTAssertEqual(b, ImageSize(width: 1920, height: 1280))       // 750 → 1920

        let c = DNGThumbnail.targetSize(forCrop: ImageSize(width: 9000, height: 6000))
        XCTAssertEqual(c, ImageSize(width: 2250, height: 1500))       // 2250 stays

        let d = DNGThumbnail.targetSize(forCrop: ImageSize(width: 1600, height: 1200))
        XCTAssertEqual(d, ImageSize(width: 1600, height: 1200))       // no upscale
        print("缩略图：6000×4000→\(a.width)×\(a.height) · 3000×2000→\(b.width)×\(b.height) · 9000×6000→\(c.width)×\(c.height) · 1600×1200→\(d.width)×\(d.height)")
    }

    func testTargetSizeNeverExceedsTheCropOrFallsBelowOnePixel() {
        XCTAssertEqual(DNGThumbnail.targetSize(forCrop: ImageSize(width: 1, height: 1)).width, 1)
        let tall = DNGThumbnail.targetSize(forCrop: ImageSize(width: 1200, height: 4000))
        XCTAssertEqual(tall, ImageSize(width: 576, height: 1920),
                       "长边 4000/4=1000 抬到 1920，短边按比例")
    }

    // MARK: - write

    func testWriteReplacesThePreviewAndKeepsTheRawPixels() throws {
        let url = try copyOfSource()
        let beforeSHA = try decodedSHA(url)
        let beforeSize = try XCTUnwrap(mainImageSize(url))
        let target = DNGThumbnail.targetSize(forCrop: ImageSize(width: 6000, height: 4000))
        XCTAssertEqual(target, ImageSize(width: 1920, height: 1280))

        // A synthetic 6000×4000 crop at the brief's size (`6000/4 → 1920`).
        let jpeg = try XCTUnwrap(DNGThumbnail.jpegData(from: solidImage(width: 6000, height: 4000),
                                                       targetSize: target))
        let outcome = try DNGThumbnail.write(jpeg, size: target, to: url, journal: journal())
        XCTAssertEqual(outcome.width, 1920)
        XCTAssertEqual(outcome.height, 1280)
        XCTAssertTrue(outcome.replacedInPlace || outcome.appendedBytes > 0)

        let embedded = try XCTUnwrap(DNGThumbnail.embeddedPreviewSize(at: url))
        XCTAssertEqual(embedded.width, 1920)
        XCTAssertEqual(embedded.height, 1280)
        let preview = try XCTUnwrap(CIRAWFilter(imageURL: url)?.previewImage)
        XCTAssertEqual(Int(preview.extent.width), 1920)
        XCTAssertEqual(Int(preview.extent.height), 1280)
        XCTAssertEqual(mainImageSize(url), beforeSize, "主图尺寸必须不变")
        if let sips = sipsSize(url) {
            XCTAssertEqual(sips, beforeSize, "sips 读主图仍须是原尺寸")
        }

        let afterSHA = try decodedSHA(url)
        XCTAssertEqual(beforeSHA, afterSHA, "替换内嵌预览后解码像素必须完全一样")
        print("缩略图写前 SHA \(beforeSHA.prefix(16))… · 写后 \(afterSHA.prefix(16))… · 内嵌 \(embedded.width)×\(embedded.height) · 主图 \(beforeSize.width)×\(beforeSize.height)")
    }

    func testTheSameJPEGIsIdempotentAndInPlace() throws {
        let url = try copyOfSource()
        let target = ImageSize(width: 1920, height: 1280)
        let jpeg = try XCTUnwrap(DNGThumbnail.jpegData(from: solidImage(width: 3000, height: 2000),
                                                       targetSize: target))
        let first = try DNGThumbnail.write(jpeg, size: target, to: url, journal: journal())
        let sizeAfterFirst = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        let second = try DNGThumbnail.write(jpeg, size: target, to: url, journal: journal())
        let sizeAfterSecond = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0

        XCTAssertTrue(second.replacedInPlace, "第二次必须原位覆盖，实际 \(second)")
        XCTAssertEqual(second.appendedBytes, 0)
        XCTAssertEqual(sizeAfterFirst, sizeAfterSecond, "同一份 JPEG 不该再改文件大小")
        XCTAssertEqual(first.width, 1920)
        XCTAssertEqual(try DNGThumbnail.embeddedPreviewSize(at: url)?.width, 1920)
    }

    func testReadOnlyFileFailsWithOneSentenceAndZeroBytesChanged() throws {
        let url = try copyOfSource()
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        let jpeg = try XCTUnwrap(DNGThumbnail.jpegData(from: solidImage(width: 300, height: 200),
                                                       targetSize: ImageSize(width: 300, height: 200)))
        XCTAssertThrowsError(try DNGThumbnail.write(jpeg, size: ImageSize(width: 300, height: 200),
                                                    to: url, journal: journal())) { error in
            let sentence = String(describing: error)
            XCTAssertFalse(sentence.isEmpty)
            XCTAssertTrue(sentence.contains("只读") || sentence.contains("read-only"), sentence)
        }
        XCTAssertEqual(try Data(contentsOf: url), before, "只读文件必须一个字节都没变")
    }

    func testANonTIFFFileFailsCleanly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dngthumb-not-tiff-\(UUID().uuidString).dng")
        try Data("not a tiff".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let jpeg = try XCTUnwrap(DNGThumbnail.jpegData(from: solidImage(width: 10, height: 10),
                                                       targetSize: ImageSize(width: 10, height: 10)))
        XCTAssertThrowsError(try DNGThumbnail.write(jpeg, size: ImageSize(width: 10, height: 10),
                                                    to: url, journal: journal()))
    }

    // MARK: - negative control for the pixel hash

    /// The "pixels are identical" assertion is only meaningful if the digest can notice a changed
    /// picture. Flip one byte inside the first full-resolution tile and require a different hash.
    func testThePixelDigestNoticesAChangedRawTile() throws {
        let url = try copyOfSource()
        let before = try decodedSHA(url)

        var file = try TIFFFile(Data(contentsOf: url))
        let rawIFD = try XCTUnwrap(file.subIFDOffsets(in: file.ifd0).first)
        let tileOffsets = try XCTUnwrap(file.entries(of: 324, in: rawIFD))
        let bytes = try file.payload(tileOffsets)
        let firstOffset = Int(bytes[bytes.startIndex])
            | Int(bytes[bytes.startIndex + 1]) << 8
            | Int(bytes[bytes.startIndex + 2]) << 16
            | Int(bytes[bytes.startIndex + 3]) << 24
        let at = firstOffset + 1024
        try file.overwriteBytes(at: at, with: Data([0xA5]), zeroFillTo: 1)
        try file.persist(to: url)

        let after = try decodedSHA(url)
        XCTAssertNotEqual(before, after, "该 hash 必须能发现像素变了（否则「不变」断言是假的）")
        print("反向门：改一个 raw tile 字节 ⇒ \(before.prefix(16))… → \(after.prefix(16))…")
    }
}
