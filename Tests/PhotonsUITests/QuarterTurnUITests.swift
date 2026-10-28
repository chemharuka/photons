import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 派单 078 / P0-10 — 变换卡上的 **90° 旋转**：两个按钮、一个徽标、一个动词、一条历史。
///
/// 全部走真对象：真的库（`CropUITestSupport.makeLibrary`）、真的 `EditorWindowController`、真的
/// `LoupeController`，卡是宿主在真窗口里的那个 `InspectorView`。两个按钮是 `NSButton`（和直角尺同一个
/// 理由：SwiftUI `Button` 在这个进程里没有 AppKit 叶子，点不到），徽标是 `NSTextField`（要能**读**到字）。
///
/// 钉六件事：
///
///   1. 卡片里那一行真的在（`CropCardID.turn` 有 frame），两个按钮 + 徽标都在树上、都可点；
///   2. 点「顺时针」= 文档转 90°（`quarterTurns == 1`），徽标读 `90°`；
///   3. 一次旋转 = **一条历史**，标签是「顺时针旋转 90°」，字段是「旋转 90°」，⌘Z 一次回到原样；
///   4. 命令是**离散**的（`coalesce: false`）：连按两次 = 两条历史（合并的话只会有一条）；
///   5. 4 次之后文档、裁切矩形与历史都回到出发点（一次 ⌘Z 一次，4 次撤销全回）；
///   6. 菜单的 ⌘[ / ⌘] 是同一个动词：走窗口 action，文档与按钮走出来的逐字段相等。
@MainActor
final class QuarterTurnUITests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-quarter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - the card

    /// A hosted panel with a real loupe on a real photo, showing the 变换 workspace.
    private func hostedCard() throws -> (editor: EditorWindowController, inspector: NSView, window: NSWindow) {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let window = try XCTUnwrap(editor.window)
        window.orderFront(nil)
        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        editor.rootView.layoutSubtreeIfNeeded()
        return (editor, editor.rootView.inspectorHost, window)
    }

    /// The card's own readback seam: `CropRowProbe` carries the row id it was built for, which is
    /// how every other 072 test measures a row's frame.
    private func findProbe(_ rowID: String, in root: NSView) -> CropRowProbe? {
        var found: CropRowProbe?
        func walk(_ view: NSView) {
            if let probe = view as? CropRowProbe, probe.rowID == rowID { found = probe }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return found
    }

    private func find<T: NSView>(_ type: T.Type, identifier: String, in root: NSView) -> T? {
        var found: T?
        func walk(_ view: NSView) {
            if let candidate = view as? T,
               candidate.accessibilityIdentifier() == identifier {
                found = candidate
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return found
    }

    func testTheCardHasTwoButtonsAndADirectionBadge() throws {
        let (editor, inspector, window) = try hostedCard()
        defer { window.orderOut(nil) }
        let loupe = editor.rootView.loupeController

        let row = try XCTUnwrap(findProbe(CropCardID.turn, in: inspector),
                                "旋转那一行没有上树（CropCardID.turn 的 probe 找不到）")
        let ccw = try XCTUnwrap(find(TurnButton.self, identifier: CropTurnRow.counterClockwiseID,
                                    in: inspector), "逆时针按钮不在树上")
        let cw = try XCTUnwrap(find(TurnButton.self, identifier: CropTurnRow.clockwiseID,
                                   in: inspector), "顺时针按钮不在树上")
        let badge = try XCTUnwrap(find(TurnBadgeLabel.self, identifier: CropTurnRow.badgeID,
                                      in: inspector), "方向徽标不在树上")
        print("CARD · row frame \(NSStringFromRect(row.frame))"
              + " · ccw \(NSStringFromRect(ccw.frame)) · cw \(NSStringFromRect(cw.frame))"
              + " · badge \(NSStringFromRect(row.convert(badge.frame, from: badge.superview)))")
        XCTAssertTrue(ccw.isEnabled && cw.isEnabled, "有照片时两个旋转按钮必须是活的")
        XCTAssertNotNil(ccw.image, "rotate.left 在本机解析不出来")
        XCTAssertNotNil(cw.image, "rotate.right 在本机解析不出来")
        XCTAssertEqual(badge.stringValue, "0°", "干净文档的徽标应该是 0°")
        XCTAssertLessThan(ccw.frame.maxX, window.frame.width, "按钮跑到卡片外面去了")
        XCTAssertGreaterThan(row.frame.height, 0, "那一行没有高度")
        XCTAssertEqual(CropCardID.turn, "turn")
    }

    // MARK: - one press = one turn = one history row

    func testTheClockwiseButtonTurnsTheDocumentAndWritesOneHistoryRow() throws {
        let (editor, inspector, window) = try hostedCard()
        defer { window.orderOut(nil) }
        let session = editor.session
        let loupe = editor.rootView.loupeController
        let cw = try XCTUnwrap(find(TurnButton.self, identifier: CropTurnRow.clockwiseID, in: inspector))
        let badge = try XCTUnwrap(find(TurnBadgeLabel.self, identifier: CropTurnRow.badgeID, in: inspector))

        let before = session.edit
        let historyBefore = session.history.snapshots.count
        XCTAssertEqual(before.geometry.quarterTurns, 0)

        cw.performClick(nil)
        CropUITestSupport.pump(0.2)
        inspector.layoutSubtreeIfNeeded()

        XCTAssertEqual(session.edit.geometry.quarterTurns, 1, "点顺时针没有把文档转 90°")
        XCTAssertEqual(loupe.quarterTurns, 1)
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 1, "一次旋转必须只有一条历史")
        XCTAssertEqual(session.history.snapshots.last?.label, "顺时针旋转 90°")
        XCTAssertEqual(badge.stringValue, "90°", "徽标没有跟着文档走（读到 \(badge.stringValue)）")
        XCTAssertTrue(session.undoLabel == "顺时针旋转 90°",
                      "撤销的标题应该是这一步（读到 \(String(describing: session.undoLabel))）")

        // The history panel's row names the *field*, not the cycle label.
        let leaves = EditHistory.changedFields(between: before, and: session.edit)
            .map(\.field.displayName)
        print("HISTORY · label \(session.history.snapshots.last?.label ?? "-") · leaves \(leaves)")
        XCTAssertTrue(leaves.contains("旋转 90°"),
                      "历史的字段名里没有「旋转 90°」：\(leaves)")

        // One ⌘Z puts the document back, bit for bit.
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.geometry.quarterTurns, 0, "⌘Z 没有把旋转撤掉")
        XCTAssertEqual(session.edit.geometry, before.geometry,
                       "撤销后几何与旋转前不同")
    }

    /// The command is **discrete**: two presses are two rows. A coalescing commit would merge them
    /// (same label, same second) and the user would have to press ⌘Z twice for one row — or, worse,
    /// once for two turns.
    func testTwoPressesAreTwoHistoryRows() throws {
        let (editor, inspector, window) = try hostedCard()
        defer { window.orderOut(nil) }
        let session = editor.session
        let cw = try XCTUnwrap(find(TurnButton.self, identifier: CropTurnRow.clockwiseID, in: inspector))
        let historyBefore = session.history.snapshots.count

        cw.performClick(nil)
        CropUITestSupport.pump(0.05)
        cw.performClick(nil)
        CropUITestSupport.pump(0.1)

        XCTAssertEqual(session.edit.geometry.quarterTurns, 2)
        print("DISCRETE · \(session.history.snapshots.count - historyBefore) rows for two presses"
              + " · tail \(session.history.snapshots.suffix(2).map { $0.label ?? "-" })")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 2,
                       "两次旋转合并成一条历史了——coalesce 必须是 false")
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.geometry.quarterTurns, 1, "一次 ⌘Z 只该退一步")
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.geometry.quarterTurns, 0, "第二次 ⌘Z 回到 0")
    }

    // MARK: - four presses are the identity, and the menu is the same verb

    func testFourPressesReturnToTheDocumentWeStartedWith() throws {
        let (editor, inspector, window) = try hostedCard()
        defer { window.orderOut(nil) }
        let session = editor.session
        let loupe = editor.rootView.loupeController
        let ccw = try XCTUnwrap(find(TurnButton.self, identifier: CropTurnRow.counterClockwiseID,
                                     in: inspector))
        // A crop first, so the rect has something to lose.
        var start = session.edit
        start.geometry.crop = NormalizedRect(x: 0.125, y: 0.25, width: 0.5, height: 0.5)
        start.geometry.quarterTurns = 0
        session.applyEdit { $0.geometry = start.geometry }
        session.commitEdit(label: "裁切", coalesce: false)
        let startBytes = CropUITestSupport.documentBytes(session)

        var badges: [String] = []
        for _ in 0..<4 {
            ccw.performClick(nil)
            CropUITestSupport.pump(0.05)
            badges.append(loupe.quarterTurnBadge)
        }
        print("CYCLE · badges \(badges) · turns \(session.edit.geometry.quarterTurns)")
        XCTAssertEqual(badges, ["270°", "180°", "90°", "0°"], "逆时针四次的徽标序列不对")
        XCTAssertEqual(session.edit.geometry.cropRect.keyString,
                       start.geometry.cropRect.keyString, "转了 4 次裁切框没有回到原处")
        XCTAssertEqual(CropUITestSupport.documentBytes(session), startBytes,
                       "转了 4 次文档的字节与出发时不同")

        // And four ⌘Z take the four turns back, one at a time — in the order the presses went
        // (0 → 3 → 2 → 1 → 0), so undo walks 1 → 2 → 3 → the pre-turn state.
        for expected in [1, 2, 3, 0] {
            XCTAssertTrue(session.undo())
            XCTAssertEqual(session.edit.geometry.quarterTurns, expected)
        }
    }

    /// 菜单的 ⌘[ / ⌘] 与卡上的两个按钮是同一个动词：走窗口 action 之后，文档与点按钮走出来的**逐字段
    /// 相等**。
    func testTheMenuShortcutIsTheSameVerbAsTheCardButtons() throws {
        let (editor, inspector, window) = try hostedCard()
        defer { window.orderOut(nil) }
        let session = editor.session
        let cw = try XCTUnwrap(find(TurnButton.self, identifier: CropTurnRow.clockwiseID, in: inspector))

        let menu = MainMenu.build()
        let transform = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == "变换" })
        let rows = transform.items
        XCTAssertEqual(rows.map(\.title), ["裁切", "逆时针旋转 90°", "顺时针旋转 90°"])
        XCTAssertEqual(rows[1].keyEquivalent, "[")
        XCTAssertEqual(rows[2].keyEquivalent, "]")
        XCTAssertEqual(rows[1].keyEquivalentModifierMask, .command)
        XCTAssertEqual(rows[2].keyEquivalentModifierMask, .command)

        cw.performClick(nil)
        CropUITestSupport.pump(0.1)
        let fromButton = session.edit.geometry

        // Same verb, other door: undo, then the window action.
        XCTAssertTrue(session.undo())
        editor.rotateClockwiseAction(nil)
        CropUITestSupport.pump(0.1)
        print("MENU · button \(fromButton.quarterTurns) · action \(session.edit.geometry.quarterTurns)")
        XCTAssertEqual(session.edit.geometry, fromButton, "菜单 action 与按钮不是同一条路")

        // The counter-clockwise door goes the other way from the same document.
        editor.rotateCounterClockwiseAction(nil)
        CropUITestSupport.pump(0.1)
        XCTAssertEqual(session.edit.geometry.quarterTurns, 0, "逆时针没有把 90° 退回去")
    }
}
