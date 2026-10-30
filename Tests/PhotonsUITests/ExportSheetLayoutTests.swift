import XCTest
import AppKit
import SwiftUI
import PhotonsCore
@testable import PhotonsExport
@testable import PhotonsUI

/// 161 §6 — the scroll region eats the leftover height; with no result rows there is no blank strip
/// between it and the footer, and with rows the form gives back exactly the list's height.
@MainActor
final class ExportSheetLayoutTests: XCTestCase {

    final class MemoryDraftStore: ExportDraftPersistence.Store {
        var values: [String: Data] = [:]
        func exportDraftData(forKey key: String) -> Data? { values[key] }
        func setExportDraftData(_ data: Data?, forKey key: String) {
            if let data { values[key] = data } else { values.removeValue(forKey: key) }
        }
    }

    private var scratch: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.contentView = nil }
        windows = []
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func model() -> ExportSheetModel {
        ExportSheetModel(presetStore: ExportPresetStore(directory: scratch),
                         draftStore: MemoryDraftStore())
    }

    private struct Hosted {
        let host: NSHostingView<ExportSheetView>
        let window: NSWindow
    }

    private func host(height: CGFloat, model sheet: ExportSheetModel) throws -> Hosted {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ExportSheetView(model: sheet))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        windows.append(window)
        return Hosted(host: host, window: window)
    }

    private func pump(_ host: NSHostingView<ExportSheetView>) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(of root: NSView) -> [NSView] {
        var found: [NSView] = []
        for sub in root.subviews {
            found.append(sub)
            found += descendants(of: sub)
        }
        return found
    }

    private func frame(of kind: ExportLayoutProbe.Kind, in host: NSView) throws -> NSRect {
        let match = descendants(of: host)
            .compactMap { $0 as? ExportLayoutProbe }
            .first { $0.kind == kind }
        let probe = try XCTUnwrap(match, "no \(kind.rawValue) probe in the hosted sheet")
        return probe.convert(probe.bounds, to: host)
    }

    private func hasProbe(_ kind: ExportLayoutProbe.Kind, in host: NSView) -> Bool {
        descendants(of: host).contains { ($0 as? ExportLayoutProbe)?.kind == kind }
    }

    /// 168 §1 — the 色调映射 row's own marker (the probe enum lives outside this task's files).
    private func hasToneMappingRow(in host: NSView) -> Bool {
        descendants(of: host).contains { $0 is ExportToneMappingRowProbe }
    }

    /// 168 §1 — the hosted view must not paint 色调映射 under HDR + PQ/HLG, and must paint it under
    /// SDR. This is the actual view, not just `showsToneMappingRow`: the bug was the view ignoring
    /// that predicate.
    func testToneMappingRowFollowsHDRKindInTheView() throws {
        let sheet = model()
        let hosted = try host(height: 900, model: sheet)

        // Default draft: HDR gain map — the gain-map row, no tone mapping.
        XCTAssertTrue(hasProbe(.hdrRow, in: hosted.host))
        XCTAssertFalse(hasToneMappingRow(in: hosted.host))

        sheet.setHDR(true)
        sheet.setHDRKind(.pq)
        pump(hosted.host)
        XCTAssertFalse(sheet.showsToneMappingRow)
        XCTAssertFalse(hasToneMappingRow(in: hosted.host), "HDR + PQ 不许有色调映射行")

        sheet.setHDRKind(.hlg)
        pump(hosted.host)
        XCTAssertFalse(sheet.showsToneMappingRow)
        XCTAssertFalse(hasToneMappingRow(in: hosted.host), "HDR + HLG 不许有色调映射行")

        sheet.setHDR(false)
        pump(hosted.host)
        XCTAssertTrue(sheet.showsToneMappingRow)
        XCTAssertTrue(hasToneMappingRow(in: hosted.host), "HDR 关必须有色调映射行")
    }

    @discardableResult
    private func finish(withRows rows: Int, on sheet: ExportSheetModel) -> BatchExportReport {
        let outcomes = (0..<rows).map { index in
            BatchExportOutcome(index: index, id: "i\(index)", sourceName: "L10304\(index)",
                               fileURL: scratch.appendingPathComponent("i\(index).png"),
                               fileBytes: 1024,
                               pixelSize: ImageSize(width: 10, height: 10), seconds: 0.1,
                               xmpURL: nil, warnings: [], error: nil)
        }
        let report = BatchExportReport(outcomes: outcomes, seconds: 0.1,
                                       requestedConcurrency: 1, peakConcurrency: 1)
        sheet.finish(with: report)
        return report
    }

    func testNoRowsTheFormConsumesTheSpaceAndFooterStaysAtTheBottom() throws {
        let sheet = model()
        let hosted = try host(height: 900, model: sheet)
        let form = try frame(of: .form, in: hosted.host)
        let footer = try frame(of: .footer, in: hosted.host)

        // Content starts at the 18 pt padding; `form.minY - 18` is the header block (title + line +
        // its 8 pt spacing), measured instead of guessed.
        let headerBlock = form.minY - 18
        let available = hosted.host.bounds.height - headerBlock - footer.height - 36
        print(String(format: "layout-empty · form %.1f · header %.1f · footer %.1f · available %.1f",
                     form.height, headerBlock, footer.height, available))

        XCTAssertGreaterThanOrEqual(form.height, 0.8 * available,
                                    "没有结果行时滚动区必须吃掉剩余高度（form \(form.height) / available \(available)）")
        XCTAssertFalse(hasProbe(.results, in: hosted.host),
                       "空态不该有 results 区域（那正是底部空白）")
        XCTAssertLessThanOrEqual(hosted.host.bounds.maxY - footer.maxY, 20,
                                 "footer 必须贴底")
        XCTAssertLessThanOrEqual(footer.minY - form.maxY, 12,
                                 "form 与 footer 之间不许夹着空白")
        // The form is still a scroll view: its seven sections are taller than the sheet.
        let scrolls = descendants(of: hosted.host).compactMap { $0 as? NSScrollView }
            .filter { scroll in
                scroll.convert(scroll.bounds, to: hosted.host)
                    .intersects(form.insetBy(dx: 1, dy: 1))
            }
        XCTAssertFalse(scrolls.isEmpty, "表单必须还能滚")
    }

    func testThreeRowsTheFormShrinksAndTheGapStaysTight() throws {
        let sheet = model()
        let hosted = try host(height: 900, model: sheet)
        let emptyForm = try frame(of: .form, in: hosted.host).height

        finish(withRows: 3, on: sheet)
        pump(hosted.host)

        let form = try frame(of: .form, in: hosted.host)
        let results = try frame(of: .results, in: hosted.host)
        let footer = try frame(of: .footer, in: hosted.host)
        print(String(format: "layout-rows · form %.1f → %.1f · results %.1f · footer maxY %.1f",
                     emptyForm, form.height, results.height, footer.maxY))

        XCTAssertLessThan(form.height, emptyForm - 20,
                          "3 行结果必须让 form 相应变矮")
        XCTAssertGreaterThanOrEqual(results.height, 28)
        XCTAssertLessThanOrEqual(results.minY - form.maxY, 8.5,
                                 "form 底边与结果区顶边间距 <= 8 pt")
        XCTAssertLessThanOrEqual(hosted.host.bounds.maxY - footer.maxY, 20,
                                 "footer 仍然贴底")
        XCTAssertGreaterThan(footer.minY, results.maxY - 1, "顺序仍是 form → results → footer")
    }
}
