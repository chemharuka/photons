import XCTest
import CoreImage
@testable import PhotonsExtensions

/// `DNGRawWriter` — proves the two things that can go wrong when you rewrite a RAW's samples:
/// either the picture changes, or the metadata does.
///
/// ① **Every metadata tag survives.** The fixture is a real (small) DNG with the full tag set a
///    camera file carries: CFA/black level/white level, `ActiveArea`, `DefaultCrop*`, both colour
///    matrices, both forward matrices, `AsShotNeutral`, `BaselineExposure`, `CameraProfile`,
///    `DNGPrivateData`, XMP, **`OpcodeList2` and `OpcodeList3``**, EXIF (ISO/shutter/aperture/lens),
///    GPS and a preview page. After a pass-through write, every tag that is not a layout tag must be
///    byte-identical. A tag nobody anticipated survives by construction — `preserved` starts as "all
///    source tags" — and this test is what keeps that true.
/// ② **The pixels come back exactly.** Samples are shifted by one LSB (so a pass-through bug cannot
///    masquerade as success, and negative differences get exercised) and must decode back identical.
/// ③ **Core Image accepts the result.** `CIRAWFilter` must report the same native size as the source
///    and render a non-black picture: `Compression = 8` (Deflate) is rejected by Core Image outright
///    (`nativeSize = 0×0`, `outputImage` nil), which is why the writer emits SOF3. And an all-black
///    image also "renders successfully", so the mean is asserted, not just nil-ness.
final class DNGRawWriterTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var fixtureURL: URL {
        repoRoot.appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-dngwriter-\(UUID().uuidString).dng")
    }

    private func loadFixture() throws -> (SourceDNG, Data) {
        let data = try Data(contentsOf: Self.fixtureURL, options: .alwaysMapped)
        return (try SourceDNG(data: data), data)
    }

    // MARK: ① metadata

    func testEveryNonLayoutTagSurvivesByteForByte() throws {
        let (doc, sourceData) = try loadFixture()
        let mosaic = try doc.readMosaic(data: sourceData)

        let output = temporaryURL()
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try DNGRawWriter.write(samples: mosaic.samples, width: mosaic.width, height: mosaic.height,
                                   from: Self.fixtureURL, to: output)

        let written = try SourceDNG(url: output)

        var checked = 0
        for (tag, entry) in doc.ifd0 where !DNGRawWriter.layoutTags.contains(tag) {
            guard let other = written.ifd0[tag] else {
                XCTFail("IFD0 tag \(tag) 丢失")
                continue
            }
            XCTAssertEqual(other.type, entry.type, "tag \(tag) 的类型变了")
            XCTAssertEqual(other.value, entry.value, "tag \(tag) 的字节变了")
            checked += 1
        }
        for (tag, entry) in doc.raw where !DNGRawWriter.layoutTags.contains(tag) {
            guard let other = written.ifd0[tag] else {
                XCTFail("RAW tag \(tag) 丢失（应当提升到 IFD0）")
                continue
            }
            XCTAssertEqual(other.value, entry.value, "tag \(tag) 的字节变了")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 25, "只校验了 \(checked) 个 tag")

        // The tags that decide whether the picture renders the same way.
        for tag: UInt16 in [50714, 50717, 50829, 50719, 50720, 50710, 50713,
                            50721, 50722, 50964, 50965, 50728, 51022, 51041, 700, 50740] {
            let original = doc.raw[tag] ?? doc.ifd0[tag]
            XCTAssertNotNil(original, "fixture 应有 tag \(tag)")
            XCTAssertEqual(written.ifd0[tag]?.value, original?.value, "tag \(tag) 未逐字节保留")
        }

        XCTAssertEqual(written.exif?.count, doc.exif?.count, "EXIF 项数变了")
        XCTAssertEqual(written.gps?.count, doc.gps?.count, "GPS 项数变了")
        XCTAssertNotNil(written.preview, "预览页丢失")
        XCTAssertEqual(written.ifd0[259]?.firstUInt32, 7, "压缩方式必须是 7（lossless JPEG）")
    }

    func testEXIFAndGPSValuesAreStillReadable() throws {
        let (doc, sourceData) = try loadFixture()
        let mosaic = try doc.readMosaic(data: sourceData)
        let output = temporaryURL()
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try DNGRawWriter.write(samples: mosaic.samples, width: mosaic.width, height: mosaic.height,
                                   from: Self.fixtureURL, to: output)
        let written = try SourceDNG(url: output)

        // ISO 34855 / ExposureTime 33434 / FNumber 33437 / FocalLength 37386 / LensModel 42036
        for tag: UInt16 in [34855, 33434, 33437, 37386, 42036, 42033] {
            XCTAssertEqual(written.exif?[tag]?.value, doc.exif?[tag]?.value,
                           "EXIF tag \(tag) 的值变了")
        }
        // GPS latitude 2 — the payload must arrive byte-identical, not merely "present".
        XCTAssertEqual(written.gps?[2]?.value, doc.gps?[2]?.value, "GPS tag 2 变了")
    }

    // MARK: ② pixels

    func testSamplesRoundTripThroughTheEncodedTiles() throws {
        let (doc, sourceData) = try loadFixture()
        var mosaic = try doc.readMosaic(data: sourceData)
        let blackLevel = doc.raw[50714]?.firstUInt32 ?? 0

        // Shift every sample that has room: a pass-through bug can no longer pretend to work, and
        // most differences become non-zero (which is what exercises the entropy coder).
        var shifted = 0
        for i in mosaic.samples.indices where mosaic.samples[i] > UInt16(blackLevel) {
            mosaic.samples[i] -= 1
            shifted += 1
        }
        XCTAssertGreaterThan(shifted, mosaic.samples.count / 2, "shift 太少，测不出问题")

        let output = temporaryURL()
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try DNGRawWriter.write(samples: mosaic.samples,
                                            width: mosaic.width, height: mosaic.height,
                                            from: Self.fixtureURL, to: output)
        XCTAssertGreaterThan(result.tileCount, 0)
        XCTAssertLessThan(result.compressedFraction, 1.0, "压缩没有生效")

        let written = try SourceDNG(url: output)
        let decoded = try written.readMosaic(data: try Data(contentsOf: output))
        XCTAssertEqual(decoded.width, mosaic.width)
        XCTAssertEqual(decoded.height, mosaic.height)
        XCTAssertEqual(decoded.samples, mosaic.samples, "解码出来的像素与写入的不一致")
    }

    // MARK: ④ dates (514)

    /// 514 — the four tags that decide what day the photo claims to be from. `0x0132` lives in IFD0,
    /// the other three in the EXIF sub-IFD, and all four are payloads (20-byte ASCII, or an inline
    /// 4-byte sub-second), so "preserved" has to mean **the bytes come back**, not merely that a tag
    /// with the same number is present. The fixture carries `2026:10:02 13:25:32` + `203`.
    func testCaptureDateTagsSurviveByteForByte() throws {
        let (doc, sourceData) = try loadFixture()
        let mosaic = try doc.readMosaic(data: sourceData)
        let output = temporaryURL()
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try DNGRawWriter.write(samples: mosaic.samples, width: mosaic.width, height: mosaic.height,
                                   from: Self.fixtureURL, to: output)
        let written = try SourceDNG(url: output)

        let dateTags: [(String, UInt16)] = [("0x0132 DateTime", 0x0132),
                                            ("0x9003 DateTimeOriginal", 0x9003),
                                            ("0x9004 DateTimeDigitized", 0x9004),
                                            ("0x9291 SubSecTimeOriginal", 0x9291)]
        for (name, tag) in dateTags {
            let original = try XCTUnwrap(doc.exif?[tag] ?? doc.ifd0[tag], "fixture 应有 \(name)")
            let other = try XCTUnwrap(written.exif?[tag] ?? written.ifd0[tag], "\(name) 在产物里丢了")
            XCTAssertEqual(other.type, original.type, "\(name) 的类型变了")
            XCTAssertEqual(other.count, original.count, "\(name) 的 count 变了")
            XCTAssertEqual(other.value, original.value, "\(name) 的字节变了")
        }
        // The sub-IFD that carries them survives whole, pointer included.
        XCTAssertEqual(written.exif?.count, doc.exif?.count, "EXIF 项数变了")
        XCTAssertEqual(written.ifd0[34665] != nil, doc.ifd0[34665] != nil, "ExifIFD 指针丢了")
    }

    /// 514 — the product is a **new inode**, born at the moment of the write; the source's birth time
    /// is *not* inherited. Recorded as a fact, not asserted as a defect: 514 measured it
    /// (`2026-10-03T15:28:04+08` → the write moment) and left it alone — that is 486's rule for an
    /// in-place save, not for a new product file.
    func testProductGetsAFreshBirthTime() throws {
        let fm = FileManager.default
        let aged = fm.temporaryDirectory
            .appendingPathComponent("photons-aged-\(UUID().uuidString).dng")
        try fm.copyItem(at: Self.fixtureURL, to: aged)
        defer { try? fm.removeItem(at: aged) }

        var parts = DateComponents()
        parts.year = 2026; parts.month = 5; parts.day = 1
        parts.hour = 10; parts.minute = 0; parts.second = 0
        let sourceBirth = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: parts))
        var values = URLResourceValues()
        values.creationDate = sourceBirth
        var mutableAged = aged
        try mutableAged.setResourceValues(values)

        let data = try Data(contentsOf: aged, options: .alwaysMapped)
        let doc = try SourceDNG(data: data)
        let mosaic = try doc.readMosaic(data: data)
        let output = temporaryURL()
        defer { try? fm.removeItem(at: output) }
        _ = try DNGRawWriter.write(samples: mosaic.samples, width: mosaic.width, height: mosaic.height,
                                   from: aged, to: output)

        let writtenBirth = try XCTUnwrap((try? output.resourceValues(forKeys: [.creationDateKey]))?.creationDate)
        XCTAssertGreaterThan(writtenBirth.timeIntervalSince1970, sourceBirth.timeIntervalSince1970,
                             "产物的 birth time 应落在写文件时，而不是继承源")
        XCTAssertEqual(writtenBirth.timeIntervalSince1970, Date().timeIntervalSince1970, accuracy: 120,
                       "产物的 birth time 应是刚刚（写文件的时刻）")
    }

    /// 514 §3.3 — a source with no date tags must produce a product with no date tags. The writer may
    /// not invent "today": the synthetic source is IFD0-only (CFA tags) and carries no ExifIFD at all.
    func testSourceWithoutDatesGainsNone() throws {
        let fm = FileManager.default
        let source = fm.temporaryDirectory
            .appendingPathComponent("photons-nodate-\(UUID().uuidString).dng")
        try MinimalDNG.data(width: 2, height: 2).write(to: source)
        defer { try? fm.removeItem(at: source) }

        let output = temporaryURL()
        defer { try? fm.removeItem(at: output) }
        _ = try DNGRawWriter.write(samples: [0, 1, 2, 3], width: 2, height: 2,
                                   from: source, to: output)

        let written = try SourceDNG(url: output)
        XCTAssertNil(written.exif, "源没有 EXIF，产物里却出现了一个 EXIF 子 IFD")
        XCTAssertNil(written.ifd0[34665], "源没有 ExifIFD 指针，产物却编了一个")
        for tag: UInt16 in [0x0132, 0x9003, 0x9004, 0x9291] {
            XCTAssertNil(written.ifd0[tag], "产物凭空出现了日期 tag \(tag)")
            XCTAssertNil(written.exif?[tag], "产物凭空出现了日期 tag \(tag)")
        }
    }

    func testWriterRefusesARejectedPixelCount() throws {
        XCTAssertThrowsError(try DNGRawWriter.write(samples: [0, 1, 2], width: 4, height: 4,
                                                    from: Self.fixtureURL, to: temporaryURL())) { error in
            guard case DNGRawWriter.WriteError.pixelCountMismatch = error else {
                return XCTFail("应当报 pixelCountMismatch，实际 \(error)")
            }
        }
    }

    // MARK: ③ Core Image

    func testCoreImageAcceptsTheOutputAndItIsNotBlack() throws {
        let (doc, sourceData) = try loadFixture()
        let mosaic = try doc.readMosaic(data: sourceData)
        let output = temporaryURL()
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try DNGRawWriter.write(samples: mosaic.samples, width: mosaic.width, height: mosaic.height,
                                   from: Self.fixtureURL, to: output)

        let stats = try renderStats(url: output)
        XCTAssertGreaterThan(stats.width, 0, "CIRAWFilter 报的宽度必须非 0")
        XCTAssertGreaterThan(stats.mean, 1.0, "渲染出来是全黑（mean=\(stats.mean)）")
        XCTAssertGreaterThan(stats.max, 64, "渲染出来的最亮值只有 \(stats.max)")

        let sourceStats = try renderStats(url: Self.fixtureURL)
        XCTAssertEqual(stats.width, sourceStats.width, "渲染尺寸与源文件不一致")
        XCTAssertEqual(stats.height, sourceStats.height)
        XCTAssertEqual(stats.mean, sourceStats.mean, accuracy: 3.0,
                       "去掉噪声后平均亮度变了 \(sourceStats.mean) → \(stats.mean)")
    }

    private struct RenderStats { var width: Int; var height: Int; var mean: Double; var max: Int }

    private func renderStats(url: URL) throws -> RenderStats {
        guard let raw = CIRAWFilter(imageURL: url) else {
            throw NSError(domain: "test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "CIRAWFilter 初始化失败"])
        }
        guard let image = raw.outputImage else {
            throw NSError(domain: "test", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "outputImage 为 nil"])
        }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cg = context.createCGImage(image, from: image.extent) else {
            throw NSError(domain: "test", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "createCGImage 失败"])
        }
        let w = cg.width, h = cg.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "test", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "CGContext 创建失败"])
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        var maxValue = 0
        for i in stride(from: 0, to: buffer.count, by: 4) {
            let v = max(Int(buffer[i]), max(Int(buffer[i + 1]), Int(buffer[i + 2])))
            maxValue = max(maxValue, v)
            sum += Double(Int(buffer[i]) + Int(buffer[i + 1]) + Int(buffer[i + 2])) / 3.0
        }
        return RenderStats(width: w, height: h, mean: sum / Double(w * h), max: maxValue)
    }
}

/// The smallest legal source `DNGRawWriter` will accept: IFD0 with the CFA/layout tags it overwrites
/// anyway, **no** ExifIFD, no SubIFDs, no preview. Used to prove the writer never invents a date.
private enum MinimalDNG {
    static func data(width: Int, height: Int) -> Data {
        struct Entry { let tag: UInt16; let type: UInt16; let count: UInt32; let value: UInt32 }
        let entries: [Entry] = [
            Entry(tag: 254, type: 4, count: 1, value: 0),              // NewSubfileType
            Entry(tag: 256, type: 4, count: 1, value: UInt32(width)),
            Entry(tag: 257, type: 4, count: 1, value: UInt32(height)),
            Entry(tag: 258, type: 3, count: 1, value: 16),             // BitsPerSample
            Entry(tag: 259, type: 3, count: 1, value: 1),              // Compression: none
            Entry(tag: 262, type: 3, count: 1, value: 32803),          // Photometric: CFA
            Entry(tag: 273, type: 4, count: 1, value: 0),              // StripOffsets (unused here)
            Entry(tag: 277, type: 3, count: 1, value: 1),              // SamplesPerPixel
            Entry(tag: 278, type: 4, count: 1, value: UInt32(height)),
            Entry(tag: 279, type: 4, count: 1, value: 0),              // StripByteCounts (unused here)
            Entry(tag: 284, type: 3, count: 1, value: 1),              // PlanarConfiguration
            Entry(tag: 339, type: 3, count: 1, value: 1),              // SampleFormat
        ]
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
        }
        var out = Data([0x49, 0x49, 0x2A, 0x00]) + Data(le32(8))   // "II", 42, IFD0 at 8
        out.append(contentsOf: [UInt8(entries.count & 0xFF), UInt8(entries.count >> 8)])
        for e in entries {
            out.append(contentsOf: [UInt8(e.tag & 0xFF), UInt8(e.tag >> 8)])
            out.append(contentsOf: [UInt8(e.type & 0xFF), UInt8(e.type >> 8)])
            out.append(contentsOf: le32(e.count))
            out.append(contentsOf: le32(e.value))
        }
        out.append(contentsOf: le32(0))                                // no next IFD
        return out
    }
}
