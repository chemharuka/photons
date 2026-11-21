import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsUI

/// §480 × 485 — the built-in engine's entry points. The algorithm is tested in
/// `BuiltinDenoiseTests`; this suite is about the product contract: the row exists in all three
/// browsers with no model or tool installed, a click fills the edit-time cache instead of writing
/// `<原名>-denoised.dng`, and the batch row fills the same cache serially.
@MainActor
final class BuiltinDenoiseEntry480Tests: XCTestCase {

    private var workDir: URL!
    private var src: URL!
    private var catalog: Catalog!
    private var session: CatalogSession!
    private var root: SourceRoot!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-builtin480-\(UUID().uuidString)", isDirectory: true)
        src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        try? FileManager.default.removeItem(at: workDir)
    }

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters[key] = nil }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    @discardableResult
    private func makeSession(dngCount: Int,
                             compute: DenoiseCleaner.Compute? = nil) throws -> [Asset] {
        let library = workDir.appendingPathComponent("S480.\(LibraryLayout.packageExtension)",
                                                     isDirectory: true)
        catalog = try Catalog.create(at: library)
        root = try catalog.ensureRoot(for: src, mode: .reference)
        var assets: [Asset] = []
        for i in 0..<dngCount {
            let name = String(format: "IMG_%04d.dng", i)
            var data = try Data(contentsOf: Self.fixtureURL)
            data.append(contentsOf: Array("builtin480-\(i)".utf8))
            try data.write(to: src.appendingPathComponent(name))
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name,
                              ext: "dng", kind: .raw, size: data.count, mtime: 0,
                              contentHash: UUID().uuidString,
                              width: 1024, height: 1024,
                              captureTime: String(format: "2026-05-01T10:%02d:00Z", i),
                              captureLocalDate: "2026-05-01",
                              cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            assets.append(asset)
        }
        let store = MemoryStore()
        let s = CatalogSession(filterStore: store, sortPreferenceStore: store,
                               remembersRecentLibrary: false)
        s.denoiseCacheDirectory = workDir.appendingPathComponent("denoise-v1", isDirectory: true)
        if let compute { s.denoiseComputeOverride = compute }
        try s.open(library)
        s.setSortOrder(.oldestFirst)
        session = s
        return assets
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func waitForDenoise(timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && session.denoiseCompletionCount == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThan(session.denoiseCompletionCount, 0, "降噪没有结束")
    }

    private struct Surfaces {
        let grid: AssetGridController
        let strip: FilmstripController
        let pane: BrowserPaneController
    }

    private func makeSurfaces() -> Surfaces {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1200))
        window.contentView = content
        windows.append(window)

        let grid = AssetGridController(session: session)
        _ = grid.view
        grid.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        content.addSubview(grid.view)

        let strip = FilmstripController(session: session)
        _ = strip.view
        strip.view.frame = NSRect(x: 0, y: 800, width: 1600, height: WorkspaceLayout.filmstripHeight)
        content.addSubview(strip.view)

        let pane = BrowserPaneController(session: session)
        _ = pane.view
        _ = pane.applyLayout(in: CGSize(width: WorkspaceLayout.browserWidthDefault, height: 744))
        content.addSubview(pane.view)
        content.layoutSubtreeIfNeeded()
        pump(0.2)
        return Surfaces(grid: grid, strip: strip, pane: pane)
    }

    private func menus(_ surfaces: Surfaces) throws -> [String: NSMenu] {
        surfaces.pane.prepareContextMenu()
        return ["grid": try XCTUnwrap(surfaces.grid.menuForRightClick(nil)),
                "filmstrip": try XCTUnwrap(surfaces.strip.menuForRightClick(nil)),
                "browser": try XCTUnwrap(surfaces.pane.contextMenu.menu)]
    }

    func testTheBuiltinRowIsLiveInAllThreeBrowsersWithoutAnyModelOrTool() throws {
        let assets = try makeSession(dngCount: 2)
        // No fake ansel tool, no NLMF model: the other two rows must be grey, this one must not.
        session.selectOnly(assets[0].id)
        let surfaces = makeSurfaces()
        let title = DenoiseMenuBuilder.title(for: .builtin)
        XCTAssertEqual(title, "模型降噪（内置）…")
        for (name, menu) in try menus(surfaces) {
            let row = try XCTUnwrap(menu.items.first { $0.title == title }, "\(name) 缺内置行")
            print("480 单张 [\(name)] \(row.title) enabled=\(row.isEnabled) tooltip=\(row.toolTip ?? "nil")")
            XCTAssertTrue(row.isEnabled, "\(name)：内置引擎没有依赖，不该灰")
            XCTAssertEqual(row.action, #selector(DenoiseMenuTarget.builtinPressed(_:)))
            // 485 §3 ⑥ — the built-in row must not promise a new file any more.
            XCTAssertEqual(row.toolTip, "预计算降噪并写入缓存（不再生成新文件）")
            XCTAssertFalse(row.toolTip?.contains("-denoised.dng") ?? false)
        }
    }

    func testTheBuiltinSingleFillsTheCacheAndWritesNoDNG() throws {
        let assets = try makeSession(dngCount: 1, compute: { _, _ in
            DenoiseCache485Tests.fakeImage()
        })
        let asset = try XCTUnwrap(assets.first)
        session.selectOnly(asset.id)
        let before = (try FileManager.default.contentsOfDirectory(atPath: src.path)).sorted()

        XCTAssertEqual(session.denoiseSelection(engine: .builtin), [asset.id])
        waitForDenoise()

        print("485 单张 error=\(session.lastDenoiseError ?? "none") "
              + "progress=\(session.lastDenoiseProgress ?? "nil") "
              + "engine=\(String(describing: session.lastDenoiseEngine))")
        XCTAssertNil(session.lastDenoiseError)
        XCTAssertEqual(session.lastDenoiseEngine, .builtin)
        // 485: the interactive entry is a cache fill, not a second RAW.
        XCTAssertNil(session.lastDenoiseReport)
        XCTAssertEqual(session.selection, [asset.id], "缓存填充不改选中")
        XCTAssertEqual(session.denoiseStats.computes, 1)
        let after = (try FileManager.default.contentsOfDirectory(atPath: src.path)).sorted()
        XCTAssertEqual(before, after, "照片目录零新文件")
        XCTAssertFalse(after.contains { $0.contains("denoised") })
        XCTAssertTrue(session.lastDenoiseProgress?.contains("降噪缓存") == true,
                      "进度行要看得出是缓存：\(session.lastDenoiseProgress ?? "nil")")
    }

    func testTheBuiltinBatchRowRunsTwoPhotosUnderOneTask() throws {
        let assets = try makeSession(dngCount: 2, compute: { _, _ in
            DenoiseCache485Tests.fakeImage()
        })
        session.setSelection(Set(assets.map(\.id)), anchor: assets[0].id)
        let before = (try FileManager.default.contentsOfDirectory(atPath: src.path)).sorted()

        let menu = NSMenu()
        let target = DenoiseMenuTarget(session: session)
        target.presentBatchSkipNotice = { _ in }
        DenoiseMenuBuilder.attach(to: menu, session: session, target: target,
                                  selectedIDs: assets.map(\.id))
        let row = try XCTUnwrap(menu.items.first {
            $0.title == DenoiseMenuBuilder.builtinBatchTitle(count: 2)
        }, "多选缺内置批量行：\(menu.items.map(\.title))")
        print("480 批量 rows=\(menu.items.map(\.title))")
        XCTAssertTrue(row.isEnabled)
        // 480 × 478 合并后：三行共用同一个动作，引擎由 `tag` 携带 —— builtin 不再是独立 selector。
        XCTAssertEqual(row.action, DenoiseMenuBuilder.batchAction)
        XCTAssertEqual(row.tag, DenoiseMenuBuilder.tag(for: .builtin))

        target.builtinBatchPressed(nil)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let task = session.backgroundTasks.tasks.first, task.state.isTerminal { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let task = try XCTUnwrap(session.backgroundTasks.tasks.first)
        print("480 批量 task=\(task.title) \(task.completed)/\(task.total) "
              + "engine=\(String(describing: session.lastDenoiseEngine))")
        XCTAssertEqual(task.kind, .denoise)
        XCTAssertEqual(task.total, 2)
        XCTAssertEqual(task.completed, 2)
        XCTAssertEqual(task.state, .finished)
        XCTAssertEqual(session.lastDenoiseEngine, .builtin)
        // 485 — each photo went through the cache, not the DNG writer.
        XCTAssertEqual(session.denoiseStats.computes, 2)
        XCTAssertEqual(session.denoiseStats.computesFailed, 0)
        XCTAssertNil(session.lastDenoiseReport)
        let after = (try FileManager.default.contentsOfDirectory(atPath: src.path)).sorted()
        XCTAssertEqual(before, after, "批量降噪也不许往照片目录写文件")
        XCTAssertFalse(after.contains { $0.contains("denoised") })
        XCTAssertTrue(session.lastDenoiseProgress?.contains("降噪缓存") == true,
                      "批量进度要看得出是缓存：\(session.lastDenoiseProgress ?? "nil")")
    }
}
