import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 157 · ⌥0（色标：无）**真的能被按下去**。
///
/// `ColorLabelClearMenuTests` 只钉了"菜单项存在、它的 action 是对的"。用户报 ⌥0 没反应，
/// 而 ⌥1…⌥6 正常 —— 因为**网格 / 胶片条 / 放大画布都走 `RatingShortcuts` 这张键盘表**
/// （`AssetGridController.keyDown` → `RatingShortcuts.handle`），而 ⌥0 当初只加进了
/// `照片 ▸ 色标 ▸ 无` 的 `NSMenuItem`。菜单项那条 `performKeyEquivalent` 在测试里
/// 返回 true 但 action 的 target 解析不到，真机上就是"按了没反应"。
///
/// 这条测试钉的是**应用真正走的键盘表**，红/绿与真按一致。
@MainActor
final class ColorLabelShortcutTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-clear-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixture（照 ColorLabelClearMenuTests 的做法，走真 Catalog + 真 SQL）

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

    private func makeEditor(_ library: Library) throws -> EditorWindowController {
        let editor = EditorWindowController()
        _ = editor.window
        try editor.openLibrary(at: library.package)
        editor.session.setSelection([library.id])
        editor.session.mode = .grid
        return editor
    }

    private func label(_ catalog: Catalog, _ id: String) throws -> String? {
        try catalog.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT color_label FROM assets WHERE id = ?", arguments: [id])
        }
    }

    /// 按键事件按键盘真实产出构造：`characters` 是 option 之后的字符，`charactersIgnoringModifiers` 是数字。
    private func optionKey(_ digit: String, characters: String, keyCode: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: digit,
            isARepeat: false, keyCode: keyCode))
    }

    // MARK: - ① ⌥0 必须被键盘表认领并清掉色标

    func testOptionZeroClearsTheLabelThroughTheShortcutTable() throws {
        let library = try makeLibrary()
        let editor = try makeEditor(library)
        XCTAssertTrue(editor.session.setColorLabelForSelection("blue"), "precondition")
        XCTAssertEqual(try label(library.catalog, library.id), "blue")

        let event = try optionKey("0", characters: "º", keyCode: 29)
        let command = try XCTUnwrap(RatingShortcuts.command(for: event),
                                    "⌥0 没被键盘表认领 —— 真机上这个键不会有任何反应")
        XCTAssertEqual(command, .colorLabel(nil))
        XCTAssertTrue(RatingShortcuts.handle(event, session: editor.session))
        XCTAssertNil(try label(library.catalog, library.id), "⌥0 应把色标清成 NULL")
    }

    // MARK: - ② 六个正标（⌥1…⌥6）不能被连带弄坏

    func testOptionOneStillSetsTheLabelThroughTheShortcutTable() throws {
        let library = try makeLibrary()
        let editor = try makeEditor(library)
        let event = try optionKey("1", characters: "¡", keyCode: 18)
        XCTAssertEqual(RatingShortcuts.command(for: event),
                       .colorLabel(ColorLabel.allCases[0].rawValue))
        XCTAssertTrue(RatingShortcuts.handle(event, session: editor.session))
        XCTAssertEqual(try label(library.catalog, library.id), ColorLabel.allCases[0].rawValue)
    }

    // MARK: - ③ 普通 "0"（无修饰键）仍是 0 星，别被 ⌥0 抢走

    func testBareZeroIsStillAZeroStarRating() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil,
            characters: "0", charactersIgnoringModifiers: "0",
            isARepeat: false, keyCode: 29))
        XCTAssertEqual(RatingShortcuts.command(for: event), .rating(0))
    }
}
