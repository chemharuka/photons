import XCTest
import AppKit
@testable import PhotonsUI

/// 442 — 右键菜单里的「导出…」：单选/多选都能导出，且与「文件 ▸ 导出…」是**同一个 selector**。
///
/// 判据只认这一条：行的 action 必须等于 `EditorWindowController.exportAction(_:)`、target 为 nil
/// （响应链 → `validateMenuItem` 负责可用性与「导出 N 张…」的标题）。另加两条结构断言：
/// 插在最上面、重复打开只有一行。
@MainActor
final class ExportMenuRightClick442Tests: XCTestCase {

    private func menu() -> NSMenu {
        let m = NSMenu(title: "右键")
        m.addItem(NSMenuItem(title: "移出照片库", action: nil, keyEquivalent: ""))
        return m
    }

    func testAttachPutsTheExportRowFirstWithTheMenuSelector() throws {
        let m = menu()
        ExportMenuBuilder.attach(to: m, session: CatalogSession(remembersRecentLibrary: false),
                                 selectedIDs: ["a"])
        let first = try XCTUnwrap(m.items.first)
        XCTAssertEqual(first.title, ExportMenuBuilder.title)
        XCTAssertEqual(first.action, #selector(EditorWindowController.exportAction(_:)),
                       "右键这一行必须与文件菜单同一个 selector")
        XCTAssertNil(first.target, "target 必须是 nil：可用性与标题交给 validateMenuItem")
        // 477 —— 「保存」与「更新缩略图」按用户口径插在「导出…」**下面**，分隔线随之退到它们之后。
        XCTAssertEqual(m.items.count >= 3 ? m.items[1].title : "", ExportMenuBuilder.saveTitle)
        XCTAssertEqual(m.items.count >= 3 ? m.items[1].action : nil,
                       #selector(EditorWindowController.saveAction(_:)))
        XCTAssertEqual(m.items.count >= 3 ? m.items[2].title : "", ExportMenuBuilder.thumbnailTitle)
        XCTAssertEqual(m.items.count >= 3 ? m.items[2].action : nil,
                       #selector(EditorWindowController.updateThumbnailAction(_:)))
        XCTAssertTrue(m.items.count >= 4 && m.items[3].isSeparatorItem,
                      "「更新缩略图」下面才是那条分隔线（477 起保存插在导出行下面）")
    }

    func testAttachingTwiceLeavesExactlyOneRow() throws {
        let m = menu()
        let session = CatalogSession(remembersRecentLibrary: false)
        ExportMenuBuilder.attach(to: m, session: session, selectedIDs: ["a"])
        ExportMenuBuilder.attach(to: m, session: session, selectedIDs: ["a", "b", "c"])
        let rows = m.items.filter { $0.action == #selector(EditorWindowController.exportAction(_:)) }
        XCTAssertEqual(rows.count, 1, "同一个 verb 只能有一行（标题会随张数变，按 action 认）")
    }

    func testNoSelectionAddsNothingAndDropsAPreviousRow() throws {
        let m = menu()
        let session = CatalogSession(remembersRecentLibrary: false)
        ExportMenuBuilder.attach(to: m, session: session, selectedIDs: [])
        XCTAssertFalse(m.items.contains { $0.action == #selector(EditorWindowController.exportAction(_:)) })

        ExportMenuBuilder.attach(to: m, session: session, selectedIDs: ["a"])
        XCTAssertTrue(m.items.contains { $0.action == #selector(EditorWindowController.exportAction(_:)) })
        ExportMenuBuilder.attach(to: m, session: session, selectedIDs: [])
        XCTAssertFalse(m.items.contains { $0.action == #selector(EditorWindowController.exportAction(_:)) },
                       "没有选中就不该留着上一轮的导出行")
    }
}
