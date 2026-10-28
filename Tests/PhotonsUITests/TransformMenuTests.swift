import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 变换 ▸ 裁切的快捷方式，以及「翻转是一份文档字段」这件事。
///
/// 072 §F 立了这张菜单（裁切三项 + 两个翻转），并让翻转成为**文档级几何动作**。
///
/// 2026-10-27 重新切了一刀：用户要「将裁切下拉菜单中的相关功能，移动到右侧第二栏「变换」」，
/// 所以 应用裁切 / 取消裁切 / 水平翻转 / 垂直翻转 四行**从菜单里删掉了** —— 它们是检查器 裁切卡里的
/// 行（以及画布上的 ↵ / Esc），菜单不再镜像面板。留下的是**快捷方式本身**：⌘R 必须仍能进/出裁切。
///
/// 这里仍然钉四件事，而且都钉在真实对象上：
///
///   1. 变换子菜单三行（⌘R 裁切 + P0-10 的两个 90° 旋转 ⌘[ / ⌘]），显影没有裁切行，
///      梯形/四边形校正仍然一行都没有；
///   2. 有照片 / 没照片的 enabled 表，以及裁切模式下那一行的勾；
///   3. 一次翻转 = 一条历史 + 一次 ⌘Z（hash 前后相同）；
///   4. 一份字段、三个入口：菜单（现在只有 ⌘R）、裁切浮动栏的两个开关、裁切卡的翻转片 ——
///      `GeometryGroup.flipHorizontal/Vertical` 是唯一的一份，没有草稿副本。
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

    func testTheTransformMenuSitsBeforeDevelopAndKeepsOnlyTheCropShortcut() throws {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        let titles = topLevel(menu)
        print("F · top level: \(titles)")

        let transformIndex = try XCTUnwrap(titles.firstIndex(of: "变换"))
        let developIndex = try XCTUnwrap(titles.firstIndex(of: "显影"))
        XCTAssertLessThan(transformIndex, developIndex, "§F: 变换 before 显影")

        let transform = try XCTUnwrap(menu.items[transformIndex].submenu)
        XCTAssertEqual(transform.items.map(\.title),
                       ["裁切", "逆时针旋转 90°", "顺时针旋转 90°"],
                       "菜单里搬走的功能都删掉了：只剩 ⌘R 那一行 + P0-10 的两个旋转")
        XCTAssertFalse(transform.items.contains { $0.isSeparatorItem }, "三行菜单不该带分隔符")
        print("F · 变换: \(transform.items.map { $0.isSeparatorItem ? "─" : $0.title })")

        let develop = try XCTUnwrap(menu.items[developIndex].submenu)
        XCTAssertEqual(develop.items.map(\.title), ["预设"], "§F: 显影 keeps the presets and nothing else")

        // 搬走的四行：一个大标题都不许留。
        for gone in ["裁切与旋转", "应用裁切", "取消裁切", "水平翻转", "垂直翻转"] {
            XCTAssertNil(find(gone, in: menu), "\(gone) 已经搬进检查器的裁切卡了，菜单里不许再有一行")
        }

        // ⌘R —— 用户点名要留的那一个快捷方式。
        let crop = try XCTUnwrap(find("裁切", in: transform))
        XCTAssertEqual(crop.keyEquivalent, "r", "⌘R 必须仍能进/出裁切")
        XCTAssertEqual(crop.keyEquivalentModifierMask, .command)
        XCTAssertEqual(crop.action, #selector(EditorWindowController.toggleCropAction(_:)))

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
        let crop = try XCTUnwrap(find("裁切", in: menu))
        XCTAssertFalse(empty.validateMenuItem(crop), "没照片时 ⌘R 是灰的（没有东西可裁）")
        print("F · no photo: 裁切=\(empty.validateMenuItem(crop))")

        let editor = try CropUITestSupport.makeEditor(in: workDir)
        editor.window?.orderFront(nil)
        defer { editor.window?.orderOut(nil) }
        let item = try XCTUnwrap(find("裁切", in: MainMenu.build()))
        XCTAssertTrue(editor.validateMenuItem(item), "有照片时 ⌘R 是活的")
        XCTAssertEqual(item.state, .off, "没进裁切时不该有勾")

        XCTAssertTrue(editor.rootView.loupeController.beginCropTool())
        CropUITestSupport.pump(0.05)
        XCTAssertTrue(editor.validateMenuItem(item), "裁切模式下仍可点")
        XCTAssertEqual(item.state, .on, "裁切模式下那一行要打勾")
        print("F · with photo: 裁切=\(editor.validateMenuItem(item)) · tick=\(item.state == .on)")
        editor.rootView.loupeController.cancelCropTool()
    }

    // MARK: - one flip = one ⌘Z

    /// 翻转是**文档动作**，动词是 `LoupeController.flipHorizontal/Vertical` —— 裁切卡的两片开关和
    /// 裁切浮动栏的两个开关调的就是它。一次翻转一条历史，一次 ⌘Z 回得去。
    func testAFlipIsOneHistoryEntryAndUndoRestoresTheDocument() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let session = editor.session
        let loupe = editor.rootView.loupeController

        let before = CropUITestSupport.documentBytes(session)
        let historyBefore = session.history.snapshots.count
        let revisionBefore = session.editRevision

        loupe.flipHorizontal()
        let afterFlip = CropUITestSupport.documentBytes(session)
        print("F · flip: history \(historyBefore) → \(session.history.snapshots.count), "
              + "revision \(revisionBefore) → \(session.editRevision), "
              + "flipH = \(session.edit.geometry.flipHorizontal)")
        XCTAssertTrue(session.edit.geometry.flipHorizontal)
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 1, "§F: 一条历史")
        XCTAssertNotEqual(afterFlip, before)

        // A second flip is a *second* entry (it is a real change), and ⌘Z takes it back one at a time.
        loupe.flipVertical()
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 2)
        XCTAssertTrue(session.edit.geometry.flipVertical)

        XCTAssertTrue(editor.undoEdit())
        XCTAssertFalse(session.edit.geometry.flipVertical, "one ⌘Z takes one flip")
        XCTAssertTrue(session.edit.geometry.flipHorizontal)
        XCTAssertTrue(editor.undoEdit())
        XCTAssertEqual(CropUITestSupport.documentBytes(session), before, "§F: ⌘Z 回原 hash")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 2,
                       "undo moves the cursor, not the log")
        XCTAssertFalse(loupe.isFlippedHorizontally)
    }

    // MARK: - one field, three doors

    /// The crop bar's switches, the 裁切 card's two chips and the tool's own verbs read/write the
    /// **same** `GeometryGroup` bits — no draft copy exists to disagree with them.
    func testTheCropBarTheCardAndTheToolDriveOneField() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view          // loadView is what wires `cropBar.controller`
        XCTAssertTrue(loupe.beginCropTool())

        let bar = loupe.cropBar
        bar.sync()
        XCTAssertFalse(bar.toggleStyle("h").on)

        // Tool path (what the card's chip calls through the loupe) → the bar's switch follows.
        loupe.flipHorizontal()
        bar.sync()
        XCTAssertTrue(session.edit.geometry.flipHorizontal, "the tool wrote the document")
        XCTAssertTrue(bar.toggleStyle("h").on, "§F: the bar reads the document's bit, so it moved too")

        // Bar path → the document follows, and so does the card's read (`isFlippedHorizontally`).
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
        print("F · bar/card one field: document flipH=\(session.edit.geometry.flipHorizontal) "
              + "flipV=\(session.edit.geometry.flipVertical), draft has no flip fields")
        loupe.cancelCropTool()
    }
}
