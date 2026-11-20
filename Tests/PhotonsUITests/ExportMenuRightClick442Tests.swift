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
        XCTAssertTrue(m.items.count >= 2 && m.items[1].isSeparatorItem, "导出行下面要有一条分隔线")
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
