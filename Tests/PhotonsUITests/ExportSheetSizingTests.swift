import XCTest
import PhotonsCore
@testable import PhotonsExport
@testable import PhotonsUI

/// 161 §1–§4 — the panel's default is 原尺寸, the popup reads `displayOrder`, switching to 原尺寸
/// clears the stale long edge (the "选原尺寸却出 2048" bug), and a finished report returns to the
/// parameter line as soon as anything changes.
@MainActor
final class ExportSheetSizingTests: XCTestCase {

    final class MemoryDraftStore: ExportDraftPersistence.Store {
        var values: [String: Data] = [:]
        func exportDraftData(forKey key: String) -> Data? { values[key] }
        func setExportDraftData(_ data: Data?, forKey key: String) {
            if let data { values[key] = data } else { values.removeValue(forKey: key) }
        }
    }

    private var scratch: URL!
    private var draftStore: MemoryDraftStore!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-sizing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        draftStore = MemoryDraftStore()
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func model() -> ExportSheetModel {
        ExportSheetModel(presetStore: ExportPresetStore(directory: scratch),
                         draftStore: draftStore)
    }

    // MARK: §1 / §9

    func testTheFirstSheetIsOriginalSizeAtQuality085() {
        let sheet = model()
        XCTAssertEqual(sheet.preset.sizingMode, .none)
        XCTAssertNil(sheet.preset.longEdge)
        XCTAssertEqual(sheet.preset.quality, 0.85)
        XCTAssertEqual(sheet.preset.format, .heic)
        XCTAssertEqual(sheet.preset.name, "默认")
    }

    // MARK: §2

    func testThePopupOrderIsOriginalLongEdgePercentAndStorageOrderIsUntouched() {
        XCTAssertEqual(ExportSizingMode.displayOrder.map(\.displayName),
                       ["原尺寸", "长边", "百分比"])
        XCTAssertEqual(ExportSizingMode.allCases, [.longEdge, .percent, .none],
                       "declaration order is the stored order and must not be reordered for the UI")
    }

    // MARK: §3 — the bug

    /// The old 网络 2048 draft carries `longEdge = 2048`; clicking 原尺寸 must clear it, otherwise
    /// `ExportPreset.renderScale` (which still honours `longEdge` in `.none`) renders at 2048 and the
    /// panel shows 原尺寸 while the file comes out 2048.
    func testSelectingOriginalClearsTheLongEdgeAndPredictsTheNativeSize() {
        let sheet = model()
        sheet.preset = ExportSheetModel.network2048Preset
        XCTAssertEqual(sheet.preset.sizingMode, .longEdge)
        XCTAssertEqual(sheet.preset.longEdge, 2048)

        sheet.selectSizingMode(.none)

        XCTAssertEqual(sheet.preset.sizingMode, .none)
        XCTAssertNil(sheet.preset.longEdge, "原尺寸必须清掉旧的长边，否则渲染仍是 2048")
        XCTAssertEqual(sheet.effectivePreset.sizingMode, .none)
        XCTAssertEqual(sheet.effectivePreset.longEdge, nil)

        let native = ImageSize(width: 6000, height: 4000)
        XCTAssertEqual(sheet.predictedSizeText(native: native), "6000×4000")
        XCTAssertEqual(sheet.preset.summary.contains("原尺寸"), true, sheet.preset.summary)
    }

    /// Defence in depth: even if a legacy preset reaches the run with `.none` **and** a long edge,
    /// the snapshot handed to `BatchExporter` drops the edge.
    func testTheRunSnapshotNormalisesANonePresetWithAStaleLongEdge() {
        let sheet = model()
        sheet.preset.sizingMode = .none
        sheet.preset.longEdge = 2048

        XCTAssertNil(sheet.effectivePreset.longEdge,
                     "导出路径用的那份 preset 不能带着 2048")
        XCTAssertEqual(sheet.predictedSizeText(native: ImageSize(width: 4000, height: 3000)),
                       "4000×3000")
    }

    // MARK: §4 — the summary goes back to the parameters

    private func report(written: Int) -> BatchExportReport {
        let outcomes = (0..<written).map { index in
            BatchExportOutcome(index: index, id: "i\(index)", sourceName: "i\(index)",
                               fileURL: scratch.appendingPathComponent("i\(index).png"),
                               fileBytes: 1024,
                               pixelSize: ImageSize(width: 10, height: 10), seconds: 0.1,
                               xmpURL: nil, warnings: [], error: nil)
        }
        return BatchExportReport(outcomes: outcomes, seconds: 0.1,
                                 requestedConcurrency: 1, peakConcurrency: 1)
    }

    func testAFinishedReportReturnsToTheParameterLineWhenAnythingChanges() {
        let sheet = model()
        sheet.selectionCount = 3
        sheet.finish(with: report(written: 3))

        XCTAssertEqual(sheet.phase, .finished)
        XCTAssertTrue(sheet.summaryLine.hasPrefix("完成："), sheet.summaryLine)
        XCTAssertEqual(sheet.writtenCount, 3)

        sheet.preset.quality = 0.5

        XCTAssertEqual(sheet.phase, .idle, "改配置后必须回到参数行")
        XCTAssertTrue(sheet.summaryLine.hasPrefix("将导出 3 张"), sheet.summaryLine)
        XCTAssertEqual(sheet.writtenCount, 0)
        XCTAssertEqual(sheet.skippedCount, 0)
        XCTAssertEqual(sheet.cancelledCount, 0)
        XCTAssertEqual(sheet.failedCount, 0)
        XCTAssertEqual(sheet.startedAt, 0)
        XCTAssertEqual(sheet.finishedAt, 0)
    }

    /// The negative case: during `.running` nothing resets, because the report is live.
    func testAConfigurationChangeWhileRunningDoesNotResetTheReport() {
        let sheet = model()
        sheet.selectionCount = 3
        sheet.phase = .running

        sheet.preset.quality = 0.5

        XCTAssertEqual(sheet.phase, .running, "导出中不许被复位")
    }

    /// 选择集 is also configuration: changing it after a finished run returns to the parameter line.
    func testChangingTheSelectionAfterAFinishedRunResetsIt() {
        let sheet = model()
        sheet.selectionCount = 3
        sheet.finish(with: report(written: 3))
        XCTAssertEqual(sheet.phase, .finished)

        sheet.selectionCount = 5
        XCTAssertEqual(sheet.phase, .idle)
        XCTAssertTrue(sheet.summaryLine.hasPrefix("将导出 5 张"))
    }
}
