import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 131 · 色标 ▸ 无 (⌥0).
///
/// The six values already existed (⌥1…⌥6). This suite pins the seventh row — 色标：无 — to the
/// **same** metadata path (`setColorLabelForSelection(nil)`), so clearing a label is one catalog
/// write over the whole selection and never a history entry: a colour label is a library fact, not
/// an edit.
@MainActor
final class ColorLabelClearMenuTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-color-label-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixture

    private struct Library {
        let package: URL
        let catalog: Catalog
        let ids: [String]
    }

    /// A real library with `count` rows, so the metadata write goes through the real `Catalog`.
    private func makeLibrary(count: Int) throws -> Library {
        _ = NSApplication.shared
        let folder = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appendingPathComponent("Spec.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let src = folder.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)

        var ids: [String] = []
        for index in 0..<count {
            let name = String(format: "IMG_%04d.dng", index)
            try Data([0x00]).write(to: src.appendingPathComponent(name))
            let id = UUID().uuidString
            try catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                        content_hash, width, height, camera_make, camera_model, lens,
                                        imported_at, missing)
                    VALUES ('\(id)', '\(root.id)', '\(name)', '\(name)', 'dng', 'raw', 1, 0,
                            '\(UUID().uuidString)',
                            6000, 4000, 'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                            '2026-10-29T00:00:00Z', 0)
                    """)
            }
            ids.append(id)
        }
        return Library(package: package, catalog: catalog, ids: ids)
    }

    private func makeEditor(_ library: Library) throws -> EditorWindowController {
        let editor = EditorWindowController()
        _ = editor.window
        try editor.openLibrary(at: library.package)
        editor.session.setSelection(Set(library.ids))
        editor.session.mode = .grid
        return editor
    }

    private func find(_ action: Selector, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.action == action { return item }
            if let sub = item.submenu, let hit = find(action, in: sub) { return hit }
        }
        return nil
    }

    private func photoMenu(_ menu: NSMenu) -> NSMenu? {
        menu.items.first { $0.submenu?.title == "照片" }?.submenu
    }

    private func nullLabelCount(_ catalog: Catalog) throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets WHERE color_label IS NULL") ?? -1
        }
    }

    // MARK: - ① the menu row

    func testTheMenuHasClearColorLabelOnOptionZeroAndKeepsTheSixValues() throws {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        let photo = try XCTUnwrap(photoMenu(menu))

        let clear = try XCTUnwrap(photo.items.first { $0.title.contains("无") || $0.title.contains("移除") },
                                 "照片菜单里应有 色标：无：\(photo.items.map(\.title))")
        XCTAssertEqual(clear.keyEquivalent, "0")
        XCTAssertEqual(clear.keyEquivalentModifierMask, [.option])
        XCTAssertEqual(clear.action, #selector(EditorWindowController.clearColorLabelAction(_:)))

        for (index, label) in ColorLabel.allCases.enumerated() {
            let item = try XCTUnwrap(photo.items.first { $0.title == "色标：\(label.displayName)" })
            XCTAssertEqual(item.keyEquivalent, "\(index + 1)")
            XCTAssertEqual(item.keyEquivalentModifierMask, [.option])
            XCTAssertEqual(item.tag, index)
            XCTAssertEqual(item.action, #selector(EditorWindowController.colorLabelAction(_:)))
        }
    }

    // MARK: - ② ⌥0 is one metadata write, not an edit

    func testClearingThreeBlueLabelsWritesNullAndLeavesHistoryAndRevisionAlone() throws {
        let library = try makeLibrary(count: 3)
        let editor = try makeEditor(library)
        let session = editor.session

        let blue = try XCTUnwrap(photoMenu(MainMenu.build())?.items.first { $0.title == "色标：蓝" })
        editor.colorLabelAction(blue)
        XCTAssertEqual(session.assets.map(\.colorLabel), Array(repeating: "blue", count: 3))

        let historyBefore = session.history.snapshots.count
        let revisionBefore = session.editRevision
        let documentBefore = CropUITestSupport.documentBytes(session)

        editor.clearColorLabelAction(nil)

        XCTAssertTrue(session.assets.allSatisfy { $0.colorLabel == nil })
        XCTAssertEqual(try nullLabelCount(library.catalog), 3, "库里三行都应是 NULL")
        XCTAssertEqual(session.history.snapshots.count, historyBefore, "一张色标不是一次编辑")
        XCTAssertEqual(session.editRevision, revisionBefore)
        XCTAssertEqual(CropUITestSupport.documentBytes(session), documentBefore)
    }

    // MARK: - ③ mixed selection still clears, and reports a change

    func testClearingAMixedSelectionTakesTheLabelledPhotoWithItAndReturnsTrue() throws {
        let library = try makeLibrary(count: 2)
        let editor = try makeEditor(library)
        let session = editor.session

        session.selectOnly(library.ids[0])
        XCTAssertTrue(editor.applyColorLabel(tag: 4), "蓝")
        session.setSelection(Set(library.ids), anchor: library.ids[0])
        XCTAssertEqual(session.selectedAssets.map(\.colorLabel), ["blue", nil])

        XCTAssertTrue(editor.clearColorLabel(), "有变化")
        XCTAssertTrue(session.selectedAssets.allSatisfy { $0.colorLabel == nil },
                      "有色标和没色标的一起变无色标")
        XCTAssertEqual(try nullLabelCount(library.catalog), 2)
    }

    // MARK: - ④ validation

    func testTheItemIsGreyWithoutASelectionOrWithoutAnyLabelToClear() throws {
        _ = NSApplication.shared
        let item = try XCTUnwrap(find(#selector(EditorWindowController.clearColorLabelAction(_:)),
                                     in: MainMenu.build()))

        let empty = EditorWindowController()
        XCTAssertFalse(empty.validateMenuItem(item), "空选区：置灰")

        let library = try makeLibrary(count: 2)
        let editor = try makeEditor(library)
        XCTAssertFalse(editor.validateMenuItem(item), "选区里一张色标都没有：置灰")

        XCTAssertTrue(editor.applyColorLabel(tag: 4))
        XCTAssertTrue(editor.validateMenuItem(item), "有蓝标可清：可用")

        editor.session.setSelection([])
        XCTAssertFalse(editor.validateMenuItem(item), "清空选区后再次置灰")
    }

    // MARK: - ⑤ badge and filter follow the label

    func testTheBadgeLosesItsColourAndTheBlueFilterDropsThePhotos() throws {
        let library = try makeLibrary(count: 3)
        let session = CatalogSession()
        try session.open(library.package)
        session.setSelection(Set(library.ids))
        XCTAssertTrue(session.setColorLabelForSelection("blue"))

        let first = try XCTUnwrap(try library.catalog.asset(id: library.ids[0]))
        XCTAssertEqual(AssetBadges(asset: first).colorLabel, .blue, "缩略图徽章有色点")
        XCTAssertTrue(AssetBadges(asset: first).drawn.contains("color:blue"))

        session.applyFilter(CatalogFilter(colorLabel: "blue"))
        XCTAssertEqual(session.assets.count, 3, "三张蓝标都在结果集里")

        XCTAssertTrue(session.setColorLabelForSelection(nil))
        XCTAssertEqual(session.assets.count, 0, "⌥0 后它们离开「色标 蓝」的结果集")

        let after = try XCTUnwrap(try library.catalog.asset(id: library.ids[0]))
        XCTAssertNil(AssetBadges(asset: after).colorLabel, "徽章无色点")
        XCTAssertTrue(AssetBadges(asset: after).isEmpty)
    }
}
