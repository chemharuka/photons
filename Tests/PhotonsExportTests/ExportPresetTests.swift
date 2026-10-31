import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PhotonsCore
@testable import PhotonsExport

/// 099 — the preset grew five fields without moving the file format.
final class ExportPresetTests: XCTestCase {

    /// The pre-099 shape, encoded with the same options `ExportPreset.data()` uses. If the new
    /// defaults were written, these bytes would no longer match.
    private struct LegacyPreset: Encodable {
        let name: String?
        let format: String
        let longEdge: Int?
        let quality: Double
        let bitDepth: Int
        let colorSpace: String
        let writeXMP: Bool
        let nameTemplate: String
    }

    private func legacyData(for preset: ExportPreset) throws -> Data {
        let legacy = LegacyPreset(name: preset.name,
                                  format: preset.format.rawValue,
                                  longEdge: preset.longEdge,
                                  quality: preset.quality,
                                  bitDepth: preset.bitDepth,
                                  colorSpace: preset.colorSpace.rawValue,
                                  writeXMP: preset.writeXMP,
                                  nameTemplate: preset.nameTemplate)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(legacy)
    }

    func testLegacyJSONReEncodesByteForByteWhenTheNewFieldsAreDefault() throws {
        let preset = ExportPreset(name: "Web", format: .heic, longEdge: 2400, quality: 0.8,
                                  bitDepth: 8, colorSpace: .displayP3, writeXMP: true,
                                  nameTemplate: "{date}/{name}")
        let legacy = try legacyData(for: preset)
        let decoded = try JSONDecoder().decode(ExportPreset.self, from: legacy).validated()
        XCTAssertEqual(try decoded.data(), legacy, "a pre-099 preset must re-encode identically")
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("sizingMode"))
    }

    /// A preset written while output sharpening was still a field must still load after the field
    /// was removed: the unknown `sharpen` key is ignored, and re-encoding drops it.
    func testAPresetFromBeforeTheSharpeningRemovalStillLoads() throws {
        let legacy = Data("""
        {
          "format" : "jpeg",
          "quality" : 0.92,
          "sharpen" : {
            "amount" : 0.6,
            "radius" : 0.8
          }
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(ExportPreset.self, from: legacy).validated()
        XCTAssertEqual(decoded.format, .jpeg)
        XCTAssertEqual(decoded.quality, 0.92, accuracy: 1e-9)
        XCTAssertFalse(String(decoding: try decoded.data(), as: UTF8.self).contains("sharpen"),
                       "the dropped key must not be written back")
    }

    /// Removing the field must not move any other byte: a preset that never carried `sharpen` round
    /// trips exactly, so export pixels and preset files for existing users are unchanged.
    func testRemovingSharpeningDidNotMoveAnyOtherByte() throws {
        let preset = ExportPreset(name: "Web", format: .heic, longEdge: 2400, quality: 0.8,
                                  bitDepth: 8, colorSpace: .displayP3, writeXMP: true,
                                  nameTemplate: "{date}/{name}")
        let legacy = try legacyData(for: preset)
        let decoded = try JSONDecoder().decode(ExportPreset.self, from: legacy).validated()
        XCTAssertEqual(try decoded.data(), legacy)
    }

    func testLegacyJSONTakesEveryNewDefault() throws {
        let legacy = Data(#"{"format":"jpg"}"#.utf8)
        let decoded = try JSONDecoder().decode(ExportPreset.self, from: legacy).validated()
        XCTAssertEqual(decoded.sizingMode, .original)
        XCTAssertTrue(decoded.noUpscale)
        XCTAssertNil(decoded.percent)
        XCTAssertEqual(decoded.subfolder, "")
        XCTAssertEqual(decoded.conflict, .rename)
        XCTAssertEqual(decoded.metadataLevel, .all)
    }

    func testNewFieldsSurviveJSON() throws {
        let preset = ExportPreset(format: .tiff, sizingMode: .percent, percent: 60,
                                  subfolder: "{date}/{camera}", conflict: .skip,
                                  metadataLevel: .copyright)
        let back = try JSONDecoder().decode(ExportPreset.self, from: try preset.data())
        XCTAssertEqual(back, preset)
    }

    // MARK: validation

    func testValidatedRejectsPercentBelowTen() {
        XCTAssertThrowsError(try ExportPreset(sizingMode: .percent, percent: 5).validated())
        // 111 — above 100 % is legal when upscaling is allowed; `noUpscale` caps it instead.
        XCTAssertNoThrow(try ExportPreset(sizingMode: .percent, noUpscale: false, percent: 101).validated())
    }

    func testValidatedRejectsNonPositiveLongEdge() {
        XCTAssertThrowsError(try ExportPreset(longEdge: 0).validated())
        XCTAssertThrowsError(try ExportPreset(longEdge: -1).validated())
    }

    func testValidatedRejectsEmptyNameTemplate() {
        XCTAssertThrowsError(try ExportPreset(nameTemplate: "   ").validated())
    }

    // MARK: sizing

    func testSizingModesChooseTheRenderScale() {
        let content = ImageSize(width: 6000, height: 4000)
        XCTAssertEqual(ExportPreset(longEdge: 2400).renderScale(content: content), 0.4, accuracy: 1e-12)
        XCTAssertEqual(ExportPreset(sizingMode: .percent, percent: 50).renderScale(content: content),
                       0.5, accuracy: 1e-12)
        XCTAssertEqual(ExportPreset(sizingMode: .original).renderScale(content: content),
                       1, accuracy: 1e-12)
        // `noUpscale` caps a percent above 100; turning it off is an explicit enlargement.
        XCTAssertEqual(ExportPreset(sizingMode: .percent, percent: 150).renderScale(content: content),
                       1, accuracy: 1e-12)
        XCTAssertEqual(ExportPreset(sizingMode: .percent, noUpscale: false, percent: 150).renderScale(content: content),
                       1.5, accuracy: 1e-12)
    }

    func testDefaultSizingIsOriginalAndDoesNotUpscale() {
        let preset = ExportPreset()
        XCTAssertEqual(preset.sizingMode, .original)
        XCTAssertTrue(preset.noUpscale)
    }

    func testSummaryNamesFormatDepthSpaceSizeAndConflict() {
        XCTAssertEqual(ExportPreset(format: .jpeg, longEdge: 2400, bitDepth: 8,
                                    colorSpace: .sRGB, conflict: .rename).summary,
                       "JPEG · 8 位 · sRGB · 长边 2400 · 重命名 · 未放大")
        XCTAssertEqual(ExportPreset(format: .tiff, bitDepth: 16, colorSpace: .displayP3,
                                    sizingMode: .percent, percent: 60, conflict: .skip).summary,
                       "TIFF · 16 位 · Display P3 · 长边 60% · 跳过 · 未放大")
        XCTAssertEqual(ExportPreset(format: .png,
                                    sizingMode: .original, conflict: .overwrite).summary,
                       // 默认色彩空间 2026-10-29 改为 Display P3（用户口径），这一条就是那个默认值。
                       "PNG · 8 位 · Display P3 · 原尺寸 · 覆盖")
    }

    // MARK: 109 — format availability, SDR tone mapping, legal depths

    func testOnlyWritableFormatsAreOffered() {
        func available(_ types: [UTType]) -> [ExportFormat] {
            ExportFormat.available(writableUTIs: Set(types.map(\.identifier)))
        }
        XCTAssertEqual(available([.jpeg, .heic, .tiff]), [.jpeg, .heic, .tiff])
        XCTAssertEqual(available([.jpeg, .heic, .tiff, .png]),
                       [.jpeg, .heic, .tiff, .png])
        XCTAssertEqual(available([]), [])
        XCTAssertEqual(available([.jpeg]), [.jpeg])
    }

    func testBitDepthsAreTheOnesEachContainerActuallyStores() {
        XCTAssertEqual(ExportFormat.heic.bitDepths, [8, 10])
        XCTAssertEqual(ExportFormat.jpeg.bitDepths, [8])
        XCTAssertEqual(ExportFormat.png.bitDepths, [8, 16])
        XCTAssertEqual(ExportFormat.tiff.bitDepths, [8, 16])
        XCTAssertEqual(ExportFormat.avif.bitDepths, [8, 10])
        XCTAssertEqual(ExportFormat.jpeg.clampedBitDepth(16), 8)
        XCTAssertEqual(ExportFormat.heic.clampedBitDepth(16), 10)
        XCTAssertEqual(ExportFormat.avif.clampedBitDepth(10), 10)
        XCTAssertEqual(ExportFormat.avif.clampedBitDepth(16), 10)
        XCTAssertEqual(ExportFormat.png.clampedBitDepth(10), 16)
    }

    func testRec2020IsTaggedAsITUR2020AndNamedInTheSummary() throws {
        let space = try XCTUnwrap(Exporter.colorSpace(for: .rec2020))
        XCTAssertEqual(space.name as String?, "kCGColorSpaceITUR_2020")
        XCTAssertTrue(ExportPreset(format: .heic, colorSpace: .rec2020).summary
            .contains("Rec2020"))
    }

    func testSDRToneMappingDefaultsToGlobalAndIsOnlyWrittenWhenNot() throws {
        let plain = ExportPreset()
        XCTAssertEqual(plain.sdrToneMapping, .global)
        XCTAssertEqual(plain, try JSONDecoder().decode(ExportPreset.self, from: try plain.data()))
        XCTAssertFalse(String(decoding: try plain.data(), as: UTF8.self).contains("sdrToneMapping"),
                       "the 099/100 defaults must still re-encode byte-for-byte")

        let hard = ExportPreset(sdrToneMapping: .none)
        XCTAssertEqual(hard.sdrToneMapping, .none)
        XCTAssertEqual(try JSONDecoder().decode(ExportPreset.self, from: try hard.data()), hard)

        let legacy = Data(#"{"format":"jpg"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ExportPreset.self, from: legacy).sdrToneMapping,
                       .global)
    }

    /// 109 §4.6 — both spellings really write a file. The `.none` side is the existing hard clamp;
    /// `.global` goes through the system tone map first, so far fewer bytes land on 255.
    func testGlobalToneMapWritesFewerClippedPixelsThanTheHardClamp() throws {
        if #unavailable(macOS 15.0) {
            throw XCTSkip("CIToneMapHeadroom — the system global tone map — is macOS 15+")
        }
        let w = 256, h = 16
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                // 0 … 4 linear: three quarters of the frame are above display white (the +2 EV
                // highlight range), and the 4.0 peak is what gives the tone map its headroom.
                let v = Float16(4 * Float(x) / Float(w - 1))
                let o = (y * w + x) * 4
                rgba[o] = v
                rgba[o + 1] = v
                rgba[o + 2] = v
                rgba[o + 3] = 1
            }
        }
        let linear = LinearPixels(width: w, height: h, rgba: rgba, primaries: .sRGB)
        let clamped = linear.displaySDR(bitDepth: 8)
        let toneMapped = linear.displaySDR(bitDepth: 8, toneMap: .global)

        // `.none` is the renderer's old path: OETF over `min(v, 1)`, nothing else.
        let reference = LinearPixels(width: w, height: h, rgba: rgba, primaries: .sRGB)
            .displaySDR(bitDepth: 8)
        XCTAssertEqual(clamped.rgba.map { $0.bitPattern }, reference.rgba.map { $0.bitPattern })

        let noneURL = try writePNG(clamped, name: "clamp.png")
        let globalURL = try writePNG(toneMapped, name: "global.png")
        let noneRatio = try clippingRatio(at: noneURL)
        let globalRatio = try clippingRatio(at: globalURL)
        XCTAssertGreaterThan(noneRatio, 0.5, "the +2 EV ramp must exercise the hard clip")
        XCTAssertLessThanOrEqual(globalRatio, noneRatio / 2,
                                 "global tone map should not leave the highlight block at 255 "
                                 + "(none \(noneRatio), global \(globalRatio))")
    }

    private func writePNG(_ image: DisplayImage, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-109-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Exporter.write(image, to: url,
                           options: ExportOptions(format: .png, quality: 1, bitDepth: 8),
                           metadata: ExportMetadataContext(level: .none))
        return url
    }

    /// Fraction of RGB bytes at 255, read back from the encoded file.
    private func clippingRatio(at url: URL) throws -> Double {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw XCTSkip("cannot read \(url.lastPathComponent)")
        }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XCTSkip("cannot build the readback context")
        }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var clipped = 0, total = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            for c in 0..<3 {
                total += 1
                if bytes[i + c] == 255 { clipped += 1 }
            }
        }
        return total == 0 ? 0 : Double(clipped) / Double(total)
    }
}
