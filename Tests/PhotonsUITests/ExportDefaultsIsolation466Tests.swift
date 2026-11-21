import XCTest
import AppKit
import PhotonsCore
@testable import PhotonsExport
@testable import PhotonsUI

/// 466 — a harness is not the user.
///
/// 取证：真实域 `com.nousresearch.photons` 里躺着
/// `photons.export.draft.v1 = {"name":"Smoke Thumb", …, "longEdge":2401, "ppi":240}` 和 8 个
/// `photons.export.section.*`（中英两套标题）—— 它们来自 `--ui-smoke`（真 app 二进制）与导出布局
/// 测试直接写 `UserDefaults.standard`，不是用户的选择。
///
/// 这条门只做一件事：**在真实域里对 `photons.export*` 做前后快照**，走一遍「present 面板 → 改
/// 模型 → 成功导出写草稿 → dismiss」，断言逐键（存在性 + 值）未变。
///
/// 反向门：如果 `exerciseSheet` 里有人重新加一行 `UserDefaults.standard.set(...)`（或默认 store
/// 退回 `UserDefaults.standard`），快照就会变，本测试必红。所以快照辅助函数里刻意没有任何
/// `UserDefaults.standard` 写操作。
@MainActor
final class ExportDefaultsIsolation466Tests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDownWithError() throws {
        for window in windows {
            window.makeFirstResponder(nil)
            if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil) }
            window.contentView = nil
        }
        windows = []
    }

    // MARK: - snapshot

    /// Every key in the real domain that belongs to the export surface. `dictionaryRepresentation()`
    /// distinguishes "absent" from "present but false", which is exactly the section-key bug (the
    /// teardown wrote `false` instead of removing the key).
    private func exportSnapshot() -> [String: Any] {
        UserDefaults.standard.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("photons.export") }
    }

    private func assertSnapshotUnchanged(_ before: [String: Any], file: StaticString = #filePath,
                                         line: UInt = #line) {
        let after = exportSnapshot()
        let same = NSDictionary(dictionary: before).isEqual(NSDictionary(dictionary: after))
        XCTAssertTrue(same, """
            466 · 真实域里的 photons.export* 被测试改动了。
            before = \(before.sorted { $0.key < $1.key })
            after  = \(after.sorted { $0.key < $1.key })
            """, file: file, line: line)
    }

    // MARK: - helpers

    private func report(written: Int, in directory: URL) -> BatchExportReport {
        let outcomes = (0..<written).map { index in
            BatchExportOutcome(index: index, id: "i\(index)", sourceName: "i\(index)",
                               fileURL: directory.appendingPathComponent("i\(index).jpg"),
                               fileBytes: 1024,
                               pixelSize: ImageSize(width: 2401, height: 1601), seconds: 0.1,
                               xmpURL: nil, warnings: [], error: nil)
        }
        return BatchExportReport(outcomes: outcomes, seconds: 0.1,
                                 requestedConcurrency: 1, peakConcurrency: 1)
    }

    /// The exercise the gate watches. Keep every store injected: any `UserDefaults.standard` write
    /// added here must make `test…RealExportDomainUntouched` red.
    private func exerciseSheet() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-466-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let draftStore = InMemoryDraftStore()
        let sectionStore = ExportSectionCollapseStore.memory([
            ExportSheetView.colourSection: true,
            ExportSheetView.hdrSection: true,
            ExportSheetView.afterSection: true
        ])

        NSApplication.shared.setActivationPolicy(.accessory)
        let parent = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                                      styleMask: [.titled, .closable, .resizable],
                                      backing: .buffered, defer: false)
        TestWindows.show(parent, key: true)
        windows.append(parent)

        let controller = ExportSheetController(
            session: CatalogSession(remembersRecentLibrary: false),
            draftStore: draftStore,
            sectionStore: sectionStore)
        controller.present(in: parent)
        let window = try XCTUnwrap(controller.sheetWindow, "present(in:) 没有开 sheet 窗口")
        windows.append(window)
        let content = try XCTUnwrap(window.contentView)
        for _ in 0..<4 {
            window.layoutIfNeeded()
            content.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        // The exact fixture values the user saw in the screenshot: 2401 / 240 PPI / HEIC HDR.
        let model = controller.model
        model.selectSizingMode(.longEdge)
        model.preset.longEdge = 2401
        model.setPPI(240)
        model.setHDR(true)
        model.outputDirectory = directory

        // A real successful run is the production write point; it must land in `draftStore`.
        model.finish(with: report(written: 1, in: directory))
        controller.dismiss()

        XCTAssertNotNil(draftStore.values[ExportDraftPersistence.storageKey],
                        "草稿没写进注入的 store —— 这条门就成了空转")
    }

    // MARK: - gates

    func testPresentingEditingAndClosingTheSheetLeavesTheRealExportDomainUntouched() throws {
        let before = exportSnapshot()
        try exerciseSheet()
        assertSnapshotUnchanged(before)
    }

    /// The defaulted entries (a sheet constructed without `draftStore:` / `sectionStore:`) are also
    /// isolated under XCTest. This is the safety net for tests that forget to inject.
    func testDefaultedStoresInATestProcessDoNotTouchTheRealDomain() {
        let before = exportSnapshot()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-466-defaults-\(UUID().uuidString)", isDirectory: true)

        let defaultStore = ExportDefaults.draftStore
        XCTAssertFalse(defaultStore is UserDefaults,
                       "测试进程的默认草稿 store 不许是真实 UserDefaults")
        ExportDraftPersistence.save(preset: ExportSheetModel.defaultPreset,
                                    outputDirectory: directory,
                                    to: defaultStore)

        let sections = ExportSectionCollapseStore.userDefaults
        XCTAssertNil(sections.read(ExportSheetView.colourSection),
                     "测试进程的默认折叠 store 应从内存空白开始，不读真实域")
        sections.write(ExportSheetView.colourSection, true)

        assertSnapshotUnchanged(before)
    }
}
