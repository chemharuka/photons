import XCTest
import AppKit
@testable import PhotonsUI

@MainActor
final class PanoramaMenuTests: XCTestCase {
    func testToolsMenuAndSelectionGate() {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        let tools = menu.items.compactMap(\.submenu).first { $0.title == "工具" }
        XCTAssertNotNil(tools)
        XCTAssertEqual(tools?.items.map(\.title),["全景拼接…","LCC矫正…","社交媒体切片输出"])
        let lcc = tools?.items.first { $0.action == #selector(EditorWindowController.lccAction(_:)) }
        XCTAssertEqual(lcc?.keyEquivalent, "l")
        XCTAssertEqual(lcc?.keyEquivalentModifierMask, [.control])
        XCTAssertEqual(EditorWindowController.panoramaSelectionMessage(count:0),"请先选中需要拼接的图片")
        XCTAssertNotNil(EditorWindowController.panoramaSelectionMessage(count:1))
        XCTAssertNil(EditorWindowController.panoramaSelectionMessage(count:2))
    }
}
