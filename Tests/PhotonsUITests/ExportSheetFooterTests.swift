import XCTest
import PhotonsCore
@testable import PhotonsExport
@testable import PhotonsUI

/// 161 §7 — 取消 exists only while running, 关闭 exists in every other phase (and cannot be used to
/// hide a running batch), and a finished report keeps 在 Finder 中显示 / 再导出一次 / 关闭.
///
/// The assertions read `ExportSheetModel.footerItems`, the same list the view renders. SwiftUI's
/// buttons have no `NSButton` leaf under `swift test`, so the old "find the button by title" probe
/// would assert nothing.
@MainActor
final class ExportSheetFooterTests: XCTestCase {

    final class MemoryDraftStore: ExportDraftPersistence.Store {
        var values: [String: Data] = [:]
        func exportDraftData(forKey key: String) -> Data? { values[key] }
        func setExportDraftData(_ data: Data?, forKey key: String) {
            if let data { values[key] = data } else { values.removeValue(forKey: key) }
        }
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-footer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func model() -> ExportSheetModel {
        ExportSheetModel(presetStore: ExportPresetStore(directory: scratch),
                         draftStore: MemoryDraftStore())
    }

    private func titles(_ sheet: ExportSheetModel) -> [String] {
        sheet.footerItems.map(\.title)
    }

    func testIdleHasCloseAndNoCancel() {
        let sheet = model()
        XCTAssertEqual(titles(sheet), ["关闭", "导出"])
        XCTAssertNil(sheet.footerItems.first { $0.kind == .cancel })
        XCTAssertEqual(sheet.footerItems.first { $0.kind == .close }?.isEnabled, true)
    }

    func testRunningHasAClickableCancelAndNoClose() {
        let sheet = model()
        sheet.selectionCount = 1
        sheet.phase = .running

        XCTAssertFalse(titles(sheet).contains("关闭"), "进行中不许用关闭绕过")
        let cancel = sheet.footerItems.first { $0.kind == .cancel }
        XCTAssertEqual(cancel?.title, "取消")
        XCTAssertEqual(cancel?.isEnabled, true, "进行中必须有可点的取消")
        XCTAssertEqual(sheet.footerItems.first { $0.kind == .export }?.isEnabled, false)
    }

    func testFinishedHasCloseAgainAndNoCancel() {
        let sheet = model()
        sheet.selectionCount = 1
        let outcome = BatchExportOutcome(index: 0, id: "i0", sourceName: "L1030433",
                                         fileURL: scratch.appendingPathComponent("i0.png"),
                                         fileBytes: 1024,
                                         pixelSize: ImageSize(width: 10, height: 10),
                                         seconds: 0.1, xmpURL: nil, warnings: [], error: nil)
        sheet.finish(with: BatchExportReport(outcomes: [outcome], seconds: 0.1,
                                             requestedConcurrency: 1, peakConcurrency: 1))
        XCTAssertEqual(sheet.phase, .finished)

        XCTAssertNil(sheet.footerItems.first { $0.kind == .cancel }, "完成态不该有取消")
        XCTAssertEqual(sheet.footerItems.first { $0.kind == .close }?.isEnabled, true)
        XCTAssertEqual(titles(sheet), ["在 Finder 中显示", "再导出一次", "关闭"],
                       "完成态三件，顺序不变")
    }
}
