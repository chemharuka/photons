import XCTest
import PhotonsCore
@testable import PhotonsExport
@testable import PhotonsUI

/// 557 — 导出 sheet 的总结行只要计数，不再显示 `x.x s`；行明细也不带每张图的耗时。
/// `BatchExportOutcome.seconds` 仍在测（`BatchReport.p50/p95` 与 bench 读它），这里只切界面这一侧。
@MainActor
final class ExportSummaryNoTiming557Tests: XCTestCase {

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
            .appendingPathComponent("photons-export-no-timing-557-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        draftStore = MemoryDraftStore()
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - fixtures

    private func model() -> ExportSheetModel {
        let model = ExportSheetModel(presetStore: ExportPresetStore(directory: scratch),
                                     draftStore: draftStore)
        model.outputDirectory = scratch
        model.imageRenderer = { _, _, _ in
            DisplayImage(width: 4, height: 4,
                         rgba: [Float16](repeating: 0.5, count: 4 * 4 * 4),
                         primaries: .displayP3, bitDepth: 8)
        }
        return model
    }

    private func items(_ ids: [String]) -> [ExportItem] {
        ids.map { ExportItem(id: $0, name: $0) }
    }

    private func report(_ items: [ExportItem],
                        failures: Set<String> = [],
                        skipped: Set<String> = [],
                        cancelled: Set<String> = []) -> BatchExportReport {
        let outcomes = items.enumerated().map { index, item -> BatchExportOutcome in
            if failures.contains(item.id) {
                return BatchExportOutcome(index: index, id: item.id, sourceName: item.name,
                                          fileURL: nil, fileBytes: 0, pixelSize: nil,
                                          seconds: 12.34, xmpURL: nil, warnings: [],
                                          error: "fake failure")
            }
            if skipped.contains(item.id) {
                return BatchExportOutcome(index: index, id: item.id, sourceName: item.name,
                                          fileURL: nil, fileBytes: 0, pixelSize: nil,
                                          seconds: 0.5, xmpURL: nil, warnings: [],
                                          error: nil, skipped: true)
            }
            if cancelled.contains(item.id) {
                return BatchExportOutcome(index: index, id: item.id, sourceName: item.name,
                                          fileURL: nil, fileBytes: 0, pixelSize: nil,
                                          seconds: 0.25, xmpURL: nil, warnings: [],
                                          error: nil, cancelled: true)
            }
            return BatchExportOutcome(index: index, id: item.id, sourceName: item.name,
                                      fileURL: scratch.appendingPathComponent("\(item.id).png"),
                                      fileBytes: 2048,
                                      pixelSize: ImageSize(width: 640, height: 480),
                                      seconds: 12.34, xmpURL: nil, warnings: [], error: nil)
        }
        return BatchExportReport(outcomes: outcomes, seconds: 12.34,
                                 requestedConcurrency: 1, peakConcurrency: 1)
    }

    private func pump(_ seconds: TimeInterval = 0.01) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    }

    @discardableResult
    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        XCTFail("\(what)：\(timeout) s 内没有成立")
        return false
    }

    private func assertNoTimeSuffix(_ text: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(text.range(of: #"\d+\.\d+ s"#, options: .regularExpression),
                     "不准再出现 `x.x s` 的时间读数：\(text)", file: file, line: line)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/PhotonsUITests/ThisFile.swift
            .deletingLastPathComponent()         // Tests/PhotonsUITests
            .deletingLastPathComponent()         // Tests
            .deletingLastPathComponent()         // repo root
    }

    // MARK: - 1 · running 只给计数，finished 只给计数

    func testRunningAndFinishedLinesCarryCountsWithoutAnyTime() {
        let sheet = model()
        let batchItems = items(["a", "b", "c"])
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }

        sheet.batchRun = { items, preset, _, _, render in
            _ = try? render(items[0], preset)
            gate.wait()
            return self.report(items)
        }

        XCTAssertTrue(sheet.run(items: batchItems))
        waitUntil("第一个渲染回调没有到") { sheet.rendered == 1 }

        XCTAssertEqual(sheet.summaryLine, "导出中… 已渲染 1/3")
        XCTAssertFalse(sheet.summaryLine.contains(" · "), "时间后缀必须整段消失：\(sheet.summaryLine)")
        assertNoTimeSuffix(sheet.summaryLine)

        gate.signal()
        waitUntil("批次没有收尾") { sheet.phase == .finished }

        XCTAssertEqual(sheet.summaryLine, "完成：3 个文件")
        XCTAssertFalse(sheet.summaryLine.contains("共 "), "finished 行不再有「共 … s」：\(sheet.summaryLine)")
        assertNoTimeSuffix(sheet.summaryLine)
    }

    // MARK: - 2 · 行明细没有每张图的耗时，但大小/尺寸还在

    func testRowDetailKeepsSizeAndBytesButDropsPerFileSeconds() {
        let sheet = model()
        sheet.finish(with: report(items(["a"])))

        XCTAssertEqual(sheet.rows.count, 1)
        let detail = sheet.rows[0].detail
        assertNoTimeSuffix(detail)
        XCTAssertTrue(detail.contains("640×480"), "尺寸还在：\(detail)")
        XCTAssertTrue(detail.contains("2 KB"), "文件大小还在：\(detail)")
        XCTAssertFalse(detail.contains("12.34"), "报告里的秒数不许漏到行里：\(detail)")
    }

    // MARK: - 3 · 代码不再跑：sheet 源文件里没有计时符号

    func testTheSheetSourceHasNoTimingSymbolsLeft() throws {
        let url = repoRoot.appendingPathComponent("Sources/PhotonsUI/ExportSheet.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(source.components(separatedBy: "elapsed").count - 1, 0,
                       "ExportSheet 里 `elapsed` 命中必须为 0")
        XCTAssertEqual(source.components(separatedBy: "seconds").count - 1, 0,
                       "ExportSheet 里 `seconds` 命中必须为 0")
        XCTAssertFalse(source.contains("%.1f s"), "running 格式串的时间占位必须删掉")
        XCTAssertFalse(source.contains("%.2f s"), "行明细/ finished 的时间占位必须删掉")
    }

    // MARK: - 4 · 计数、失败原因、跳过/取消都不受这次删除影响

    func testMixedOutcomesStillReportTheirCountsAndReasons() {
        let sheet = model()
        let batchItems = items(["a", "b", "c", "d"])
        sheet.finish(with: report(batchItems, failures: ["b"], skipped: ["c"], cancelled: ["d"]))

        XCTAssertEqual(sheet.writtenCount, 1)
        XCTAssertEqual(sheet.failedCount, 1)
        XCTAssertEqual(sheet.skippedCount, 1)
        XCTAssertEqual(sheet.cancelledCount, 1)
        XCTAssertEqual(sheet.summaryLine, "完成：1 个文件，跳过 1，取消 1，失败 1")
        assertNoTimeSuffix(sheet.summaryLine)

        let byID = Dictionary(uniqueKeysWithValues: sheet.rows.map { ($0.id, $0) })
        XCTAssertEqual(byID["b"]?.detail, "失败：fake failure")
        XCTAssertEqual(byID["c"]?.detail, "跳过：目标文件已存在")
        XCTAssertEqual(byID["d"]?.detail, "已取消")
        for row in sheet.rows { assertNoTimeSuffix(row.detail) }
    }

    // MARK: - 5 · 本地化：新串在，旧的时间串是孤儿键

    func testLocalizationTablesUseTheTimelessRunningLineAndDropTheOldKeys() throws {
        for language in ["zh-Hans", "en"] {
            let url = repoRoot
                .appendingPathComponent("Sources/PhotonsLocalization/Resources/\(language).lproj/Localizable.strings")
            let table = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(table.contains("%.1f s"), "\(language) 还有 running 的时间占位")
            XCTAssertFalse(table.contains("共 %.2f s"), "\(language) 还有 finished 的「共 … s」")
            XCTAssertTrue(table.contains("\"导出中… 已渲染 %d/%d\" = "),
                          "\(language) 缺不带时间的新 key")
        }
    }

    // MARK: - 6 · 测量没被误删：报告的 p50/p95 仍读 outcome.seconds

    func testBatchReportPercentilesStillUseOutcomeSeconds() {
        let outcomes = [1.0, 2.0, 3.0, 4.0].enumerated().map { index, seconds in
            BatchExportOutcome(index: index, id: "i\(index)", sourceName: "i\(index)",
                               fileURL: scratch.appendingPathComponent("i\(index).png"),
                               fileBytes: 100, pixelSize: ImageSize(width: 4, height: 4),
                               seconds: seconds, xmpURL: nil, warnings: [], error: nil)
        }
        let report = BatchExportReport(outcomes: outcomes, seconds: 10.0,
                                       requestedConcurrency: 1, peakConcurrency: 1)
        XCTAssertEqual(report.p50, 3.0, "p50 仍从 BatchExportOutcome.seconds 算出来")
        XCTAssertEqual(report.p95, 4.0, "p95 仍从 BatchExportOutcome.seconds 算出来")
        XCTAssertEqual(report.seconds, 10.0)
    }
}
