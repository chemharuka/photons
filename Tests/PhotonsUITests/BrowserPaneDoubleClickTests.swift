import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 166 · 双击左侧照片列表要进单图（loupe）。
///
/// 用户报「双击左侧的照片列表不能进入单图编辑界面」。原因是左侧是 `NSTableView`，
/// 而网格/胶片条用的是 `NSClickGestureRecognizer` —— 表格必须显式给 `doubleAction` + `target`。
/// 这条测试同时钉「接上了」和「接的对象对」。
@MainActor
final class BrowserPaneDoubleClickTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-browser-dbl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private struct Library { let package: URL; let catalog: Catalog; let id: String }

    private func makeLibrary() throws -> Library {
        _ = NSApplication.shared
        let folder = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appendingPathComponent("Spec.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let src = folder.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)
        try Data([0x00]).write(to: src.appendingPathComponent("IMG_0001.dng"))
        let id = UUID().uuidString
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                    content_hash, width, height, camera_make, camera_model, lens,
                                    imported_at, missing)
                VALUES ('\(id)', '\(root.id)', 'IMG_0001.dng', 'IMG_0001.dng', 'dng', 'raw', 1, 0,
                        '\(UUID().uuidString)',
                        6000, 4000, 'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                        '2026-10-29T00:00:00Z', 0)
                """)
        }
        return Library(package: package, catalog: catalog, id: id)
    }

    // MARK: - ① 表格的双击真的接上了

    func testThePhotoListHasADoubleActionAndATarget() throws {
        let session = CatalogSession()
        let pane = BrowserPaneController(session: session)
        _ = pane.view

        let table = pane.photoListForTesting
        XCTAssertNotNil(table.doubleAction, "左侧照片列表没有 doubleAction —— 双击不会发生任何事")
        XCTAssertTrue(table.target === pane, "doubleAction 的 target 必须是自己")
    }

    // MARK: - ② 双击的行为 = 选中这一张 + 进单图

    func testDoubleClickingARowOpensThatPhotoInTheLoupe() throws {
        let library = try makeLibrary()
        let session = CatalogSession()
        let editor = EditorWindowController()
        _ = editor.window
        try editor.openLibrary(at: library.package)

        let pane = BrowserPaneController(session: editor.session)
        _ = pane.view
        editor.session.mode = .grid
        XCTAssertNotEqual(editor.session.mode, .loupe, "precondition")

        XCTAssertTrue(pane.openRowInLoupe(0), "第 0 行应当能打开")
        XCTAssertEqual(editor.session.mode, .loupe, "双击之后必须进单图")
        XCTAssertEqual(editor.session.selection, [library.id], "开的是被双击的那一张")
    }

    // MARK: - ③ 越界行不做事，也不改模式

    func testDoubleClickingPastTheEndDoesNothing() throws {
        let library = try makeLibrary()
        let editor = EditorWindowController()
        _ = editor.window
        try editor.openLibrary(at: library.package)
        let pane = BrowserPaneController(session: editor.session)
        _ = pane.view
        editor.session.mode = .grid

        XCTAssertFalse(pane.openRowInLoupe(99))
        XCTAssertEqual(editor.session.mode, .grid, "越界双击不许改模式")
    }
}
