import XCTest
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
        let sharpen: OutputSharpening?
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
                                  sharpen: preset.sharpen,
                                  nameTemplate: preset.nameTemplate)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(legacy)
    }

    func testLegacyJSONReEncodesByteForByteWhenTheNewFieldsAreDefault() throws {
        let preset = ExportPreset(name: "Web", format: .heic, longEdge: 2400, quality: 0.8,
                                  bitDepth: 8, colorSpace: .displayP3, writeXMP: true,
                                  sharpen: OutputSharpening(amount: 0.4, radius: 0.7),
                                  nameTemplate: "{date}/{name}")
        let legacy = try legacyData(for: preset)
        let decoded = try JSONDecoder().decode(ExportPreset.self, from: legacy).validated()
        XCTAssertEqual(try decoded.data(), legacy, "a pre-099 preset must re-encode identically")
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("sizingMode"))
    }

    func testLegacyJSONTakesEveryNewDefault() throws {
        let legacy = Data(#"{"format":"jpg"}"#.utf8)
        let decoded = try JSONDecoder().decode(ExportPreset.self, from: legacy).validated()
        XCTAssertEqual(decoded.sizingMode, .longEdge)
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

    func testValidatedRejectsPercentOutsideTenToHundred() {
        XCTAssertThrowsError(try ExportPreset(sizingMode: .percent, percent: 5).validated())
        XCTAssertThrowsError(try ExportPreset(sizingMode: .percent, percent: 101).validated())
    }

    func testValidatedRejectsNonPositiveLongEdge() {
        XCTAssertThrowsError(try ExportPreset(longEdge: 0).validated())
        XCTAssertThrowsError(try ExportPreset(longEdge: -1).validated())
    }

    func testValidatedRejectsEmptyNameTemplate() {
        XCTAssertThrowsError(try ExportPreset(nameTemplate: "   ").validated())
    }

    func testValidatedRejectsSharpeningRadiusOutsideTheSlider() {
        XCTAssertThrowsError(try ExportPreset(sharpen: OutputSharpening(amount: 0.5, radius: 0.2)).validated())
        XCTAssertThrowsError(try ExportPreset(sharpen: OutputSharpening(amount: 0.5, radius: 3.1)).validated())
        XCTAssertNoThrow(try ExportPreset(sharpen: OutputSharpening(amount: 0.5, radius: 0.3)).validated())
        XCTAssertNoThrow(try ExportPreset(sharpen: OutputSharpening(amount: 0.5, radius: 3.0)).validated())
    }

    // MARK: sizing

    func testSizingModesChooseTheRenderScale() {
        let content = ImageSize(width: 6000, height: 4000)
        XCTAssertEqual(ExportPreset(longEdge: 2400).renderScale(content: content), 0.4, accuracy: 1e-12)
        XCTAssertEqual(ExportPreset(sizingMode: .percent, percent: 50).renderScale(content: content),
                       0.5, accuracy: 1e-12)
        XCTAssertEqual(ExportPreset(longEdge: 100, sizingMode: .none).renderScale(content: content),
                       1, accuracy: 1e-12)
        // A percent above 100 is clamped by the shared rule as well (validation rejects it earlier).
        XCTAssertEqual(ExportPreset(sizingMode: .percent, percent: 150).renderScale(content: content),
                       1, accuracy: 1e-12)
    }

    func testSummaryNamesFormatDepthSpaceSizeAndConflict() {
        XCTAssertEqual(ExportPreset(format: .jpeg, longEdge: 2400, bitDepth: 8,
                                    colorSpace: .sRGB, conflict: .rename).summary,
                       "JPEG · 8 位 · sRGB · 长边 2400 · 重命名")
        XCTAssertEqual(ExportPreset(format: .tiff, bitDepth: 16, colorSpace: .displayP3,
                                    sizingMode: .percent, percent: 60, conflict: .skip).summary,
                       "TIFF · 16 位 · Display P3 · 长边 60% · 跳过")
        XCTAssertEqual(ExportPreset(format: .png, longEdge: 1234,
                                    sizingMode: .none, conflict: .overwrite).summary,
                       // 默认色彩空间 2026-10-29 改为 Display P3（用户口径），这一条就是那个默认值。
                       "PNG · 8 位 · Display P3 · 原尺寸 · 覆盖")
    }
}
