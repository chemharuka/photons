import XCTest
import PhotonsCore
import PhotonsUI

/// 099 — the sheet's section order, the one-line summary, and the preset files behind the popup.
@MainActor
final class ExportSheetModelTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-sheet-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func model() -> ExportSheetModel {
        ExportSheetModel(presetStore: ExportPresetStore(directory: scratch))
    }

    // MARK: sections

    func testSectionOrderMatchesLightroom() {
        XCTAssertEqual(ExportSheetModel.sectionTitles,
                       ["位置", "文件命名", "文件设置", "图像尺寸", "输出锐化", "元数据", "导出"])
    }

    // MARK: summary

    func testBottomSummaryIsExact() {
        let sheet = model()
        sheet.selectionCount = 3

        sheet.preset = ExportSheetModel.defaultPreset
        sheet.preset.format = .jpeg
        sheet.preset.longEdge = 2400
        sheet.preset.bitDepth = 8
        sheet.preset.colorSpace = .sRGB
        sheet.preset.sizingMode = .longEdge
        sheet.preset.conflict = .rename
        XCTAssertEqual(sheet.summaryLine,
                       "将导出 3 张 → JPEG · 8 位 · sRGB · 长边 2400 · 重命名")

        sheet.preset.format = .tiff
        sheet.preset.bitDepth = 16
        sheet.preset.colorSpace = .displayP3
        sheet.preset.sizingMode = .percent
        sheet.preset.percent = 60
        sheet.preset.conflict = .skip
        XCTAssertEqual(sheet.summaryLine,
                       "将导出 3 张 → TIFF · 16 位 · Display P3 · 长边 60% · 跳过")

        sheet.preset.format = .png
        sheet.preset.bitDepth = 8
        sheet.preset.colorSpace = .sRGB
        sheet.preset.longEdge = 1234
        sheet.preset.sizingMode = .none
        sheet.preset.conflict = .overwrite
        XCTAssertEqual(sheet.summaryLine,
                       "将导出 3 张 → PNG · 8 位 · sRGB · 原尺寸 · 覆盖")
    }

    // MARK: preset files

    func testSaveLoadAndDeleteAPreset() throws {
        let sheet = model()
        sheet.preset = ExportSheetModel.defaultPreset
        sheet.preset.longEdge = 2400
        sheet.preset.conflict = .skip

        XCTAssertTrue(sheet.savePreset(named: "网络 2048"))
        XCTAssertEqual(sheet.presetNames, ["网络 2048"])
        let file = scratch.appendingPathComponent("网络-2048.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        sheet.preset = ExportSheetModel.defaultPreset
        XCTAssertEqual(sheet.preset.longEdge, 2048)
        sheet.loadPreset(named: "网络 2048")
        XCTAssertEqual(sheet.preset.longEdge, 2400)
        XCTAssertEqual(sheet.preset.conflict, .skip)
        XCTAssertEqual(sheet.preset.name, "网络 2048")

        sheet.deletePreset(named: "网络 2048")
        XCTAssertTrue(sheet.presetNames.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSafePresetFilenameStripsPathCharacters() {
        XCTAssertEqual(ExportPresetStore.safeFilename("a/b:c d"), "a-b-c-d")
        XCTAssertEqual(ExportPresetStore.safeFilename("   "), "preset")
    }
}
