import XCTest
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// 205 — the one-line notice for a document from a newer build.
///
/// Two contracts: the sentence is exactly one sentence (no banner, no alert), and a document this
/// build wrote (`forwardCompatVersion == nil`) shows **nothing** and moves **no** layout frame.
@MainActor
final class ForwardCompatNoticeTests: XCTestCase {

    private func workspace() -> WorkspaceRootView {
        let root = WorkspaceRootView(session: CatalogSession())
        root.frame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        root.layoutSubtreeIfNeeded()
        return root
    }

    func testNoVersionMeansNoText() {
        XCTAssertNil(ForwardCompatNotice.text(for: nil))
        XCTAssertTrue(ForwardCompatNotice.lineHeight == 14)
        XCTAssertEqual(ForwardCompatNotice.font.pointSize, 10)
    }

    func testTheWordingIsExact() {
        XCTAssertEqual(ForwardCompatNotice.text(for: 14),
                       "该文件来自更新的版本 v14，未知设置已原样保留")
    }

    func testNilVersionLeavesTheWorkspaceUntouched() {
        let root = workspace()
        XCTAssertTrue(root.forwardCompatNotice.isHidden)
        XCTAssertEqual(root.forwardCompatNotice.stringValue, "")
        XCTAssertEqual(root.forwardCompatNotice.frame.height, ForwardCompatNotice.lineHeight)
    }

    func testShowingTheNoticeMovesNoLayoutFrame() {
        let root = workspace()
        let before = root.geometry
        root.showForwardCompatNotice(14)
        root.layoutSubtreeIfNeeded()

        XCTAssertFalse(root.forwardCompatNotice.isHidden)
        XCTAssertEqual(root.forwardCompatNotice.stringValue,
                       "该文件来自更新的版本 v14，未知设置已原样保留")
        XCTAssertEqual(root.forwardCompatNotice.font?.pointSize, 10)
        XCTAssertEqual(root.forwardCompatNotice.frame.height, ForwardCompatNotice.lineHeight)
        // Every `WorkspaceLayout` frame is the same object before and after: the notice is an
        // overlay, not a row in any of them.
        XCTAssertEqual(root.geometry, before)
    }

    func testHidingTheNoticeAgainReturnsToNothing() {
        let root = workspace()
        root.showForwardCompatNotice(14)
        root.showForwardCompatNotice(nil)
        XCTAssertTrue(root.forwardCompatNotice.isHidden)
        XCTAssertEqual(root.forwardCompatNotice.stringValue, "")
    }
}
