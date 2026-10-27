import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 072 §F — 顶层「变换」菜单，翻转 = 文档级几何动作.
///
/// The menu was re-cut, not re-skinned: 裁切三项 moved **out of 显影** (where they claimed to be a look)
/// into a new 变换 that sits before it, 水平/垂直翻转 became document actions with one history entry
/// each, and 梯形/四边形校正 have **no row at all** until they have a field and a stage.
///
/// Measured here: the printed structure, the enabled table with and without a photo, one flip = one
/// ⌘Z (hash before/after), and that the bar's two switches and the menu's two ticks are the same bit.
@MainActor
final class TransformMenuTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-transform-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func topLevel(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.submenu?.title ?? $0.title }
    }

    private func find(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        var found: NSMenuItem?
        func walk(_ m: NSMenu) {
            for item in m.items {
                if item.title == title { found = item }
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(menu)
        return found
    }

    // MARK: - structure

    func testTheTransformMenuSitsBeforeDevelopAndOwnsTheCropItems() {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        let titles = topLevel(menu)
        print("F · top level: \(titles)")

        let transformIndex = try! XCTUnwrap(titles.firstIndex(of: "变换"))
        let developIndex = try! XCTUnwrap(titles.firstIndex(of: "显影"))
        XCTAssertLessThan(transformIndex, developIndex, "§F: 变换 before 显影")

        let transform = try! XCTUnwrap(menu.items[transformIndex].submenu)
        XCTAssertEqual(transform.items.map(\.title),
                       ["裁切与旋转", "应用裁切", "取消裁切", "", "水平翻转", "垂直翻转", ""],
                       "§F: the three crop verbs, then the two flips (empty titles are separators)")
        print("F · 变换: \(transform.items.map { $0.isSeparatorItem ? "─" : $0.title })")

        let develop = try! XCTUnwrap(menu.items[developIndex].submenu)
        XCTAssertEqual(develop.items.map(\.title), ["预设"], "§F: 显影 keeps the presets and nothing else")
        for gone in ["裁切与旋转", "应用裁切", "取消裁切"] {
            XCTAssertNil(find(gone, in: develop), "\(gone) must be gone from 显影")
        }

        // The shortcuts: ⌘R / ⌘⏎ / ⌘. / ⌥⌘H / ⌥⌘V.
        let keys = [("裁切与旋转", "r", NSEvent.ModifierFlags.command),
                    ("应用裁切", "\r", .command),
                    ("取消裁切", ".", .command),
                    ("水平翻转", "h", [.command, .option]),
                    ("垂直翻转", "v", [.command, .option])]
        for (title, key, mask) in keys {
            let item = try! XCTUnwrap(find(title, in: transform))
            XCTAssertEqual(item.keyEquivalent, key, "\(title) key")
            XCTAssertEqual(item.keyEquivalentModifierMask, mask, "\(title) modifiers")
        }

        // No dead rows for 梯形/四边形校正.
        for reserved in ["梯形校正", "四边形校正", "透视", "梯形", "四边形"] {
            XCTAssertNil(find(reserved, in: menu), "§F: no dead grey item for \(reserved)")
        }
    }

    // MARK: - enabled table

    func testTheEnabledTableWithAndWithoutAPhoto() throws {
        _ = NSApplication.shared
        let empty = EditorWindowController()
        let menu = MainMenu.build()
        let cropTitles = ["裁切与旋转", "应用裁切", "取消裁切", "水平翻转", "垂直翻转"]

        var table: [(String, Bool, Bool)] = []
        for title in cropTitles {
            let item = try XCTUnwrap(find(title, in: menu))
            table.append((title, empty.validateMenuItem(item), false))
        }
        print("F · no photo: " + table.map { "\($0.0)=\($0.1)" }.joined(separator: ", "))
        for (title, enabled, _) in table {
            XCTAssertFalse(enabled, "\(title) must be grey without a photo")
        }

        // Now a real photo, in 单图.
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        editor.window?.orderFront(nil)
        defer { editor.window?.orderOut(nil) }
        var withPhoto: [(String, Bool)] = []
        for title in cropTitles {
            let item = try XCTUnwrap(find(title, in: MainMenu.build()))
            withPhoto.append((title, editor.validateMenuItem(item)))
        }
        print("F · with photo: " + withPhoto.map { "\($0.0)=\($0.1)" }.joined(separator: ", "))
        XCTAssertTrue(withPhoto[0].1, "裁切与旋转 is live with a photo")
        XCTAssertFalse(withPhoto[1].1, "§D4: 应用裁切 stays grey until the tool is on")
        XCTAssertFalse(withPhoto[2].1, "§D4: 取消裁切 stays grey until the tool is on")
        XCTAssertTrue(withPhoto[3].1, "水平翻转 is live with a photo")
        XCTAssertTrue(withPhoto[4].1, "垂直翻转 is live with a photo")
    }

    // MARK: - one flip = one ⌘Z

    func testAFlipIsOneHistoryEntryAndUndoRestoresTheDocument() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let session = editor.session
        let loupe = editor.rootView.loupeController

        let before = CropUITestSupport.documentBytes(session)
        let historyBefore = session.history.snapshots.count
        let revisionBefore = session.editRevision

        editor.flipHorizontalAction(nil)
        let afterFlip = CropUITestSupport.documentBytes(session)
        print("F · flip: history \(historyBefore) → \(session.history.snapshots.count), "
              + "revision \(revisionBefore) → \(session.editRevision), "
              + "flipH = \(session.edit.geometry.flipHorizontal)")
        XCTAssertTrue(session.edit.geometry.flipHorizontal)
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 1, "§F: 一条历史")
        XCTAssertNotEqual(afterFlip, before)

        // A second flip is a *second* entry (it is a real change), and ⌘Z takes it back one at a time.
        editor.flipVerticalAction(nil)
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 2)
        XCTAssertTrue(session.edit.geometry.flipVertical)

        XCTAssertTrue(editor.undoEdit())
        XCTAssertFalse(session.edit.geometry.flipVertical, "one ⌘Z takes one flip")
        XCTAssertTrue(session.edit.geometry.flipHorizontal)
        XCTAssertTrue(editor.undoEdit())
        XCTAssertEqual(CropUITestSupport.documentBytes(session), before, "§F: ⌘Z 回原 hash")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 2, "undo moves the cursor, not the log")

        // The menu ticks the document's bit.
        let item = try XCTUnwrap(find("水平翻转", in: MainMenu.build()))
        XCTAssertTrue(editor.validateMenuItem(item), "live: there is a photo")
        XCTAssertEqual(item.state, .off, "and unticked, because ⌘Z took the flip back")
        editor.flipHorizontalAction(nil)
        XCTAssertTrue(editor.validateMenuItem(item), "the tick follows the document")
        XCTAssertTrue(loupe.isFlippedHorizontally)
    }

    // MARK: - one field, two controls

    /// The bar's switches and the menu read/write the **same** `GeometryGroup` bits — no draft copy.
    func testTheCropBarAndTheMenuDriveOneField() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view          // loadView is what wires `cropBar.controller`
        XCTAssertTrue(loupe.beginCropTool())

        let bar = loupe.cropBar
        bar.sync()
        XCTAssertFalse(bar.toggleStyle("h").on)

        // Menu path → the bar's switch follows.
        loupe.flipHorizontal()
        bar.sync()
        XCTAssertTrue(session.edit.geometry.flipHorizontal, "the menu wrote the document")
        XCTAssertTrue(bar.toggleStyle("h").on, "§F: the bar reads the document's bit, so it moved too")

        // Bar path → the document follows, and so does the menu's tick (`isFlippedHorizontally`).
        loupe.cropTool.toggleFlipHorizontal()
        bar.sync()
        XCTAssertFalse(session.edit.geometry.flipHorizontal)
        XCTAssertFalse(bar.toggleStyle("h").on)
        XCTAssertFalse(loupe.isFlippedHorizontally)

        // 源码级证据: both doors write the same two bits through the same call, and nothing in the
        // repository keeps a second copy (`draft.flipHorizontal` does not exist any more).
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // PhotonsUITests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // the checkout
            .appendingPathComponent("Sources/PhotonsUI")
        let toolSource = try String(contentsOf: sources.appendingPathComponent("CropToolController.swift"),
                                    encoding: .utf8)
        let loupeSource = try String(contentsOf: sources.appendingPathComponent("LoupeController.swift"),
                                     encoding: .utf8)
        XCTAssertTrue(toolSource.contains("model.geometry.flipHorizontal.toggle()"))
        XCTAssertTrue(loupeSource.contains("model.geometry.flipHorizontal.toggle()"))
        XCTAssertFalse(toolSource.contains("draft.flipHorizontal"), "§F: no draft copy of the flip")
        print("F · one field: CropToolController + LoupeController both toggle geometry.flipHorizontal")

        // A draft begin/apply cycle cannot resurrect a stale flip: the draft has no flip field at all.
        loupe.cropTool.toggleFlipVertical()
        let geometry = loupe.cropTool.draft.geometry(flipsOf: session.edit.geometry)
        XCTAssertTrue(geometry.flipVertical, "§F: 应用 carries the document's flip, it does not overwrite it")
        print("F · bar/menu one field: document flipH=\(session.edit.geometry.flipHorizontal) "
              + "flipV=\(session.edit.geometry.flipVertical), draft has no flip fields")
        loupe.cancelCropTool()
    }
}
