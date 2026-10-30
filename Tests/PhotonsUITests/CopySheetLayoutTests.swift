import XCTest
import AppKit
@testable import PhotonsUI

/// 156 — the copy sheet's **window**: three columns, column-major reading order, and the sidebar
/// material instead of the system glass an `NSAlert` brings.
///
/// The layout is measured on the real `CopySettingsPanel` (not a parallel model), because the two
/// things the ticket asks for — 「弹窗贴窗」 and 「三列」 — are properties of that window.
@MainActor
final class CopySheetLayoutTests: XCTestCase {

    private func panel(showsChildren: Bool = false) -> CopySettingsPanel {
        let panel = CopySettingsPanel(selection: .all, purpose: .copy, showsChildren: showsChildren)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.accessory.layoutSubtreeIfNeeded()
        return panel
    }

    // MARK: §1 — the sheet belongs to the editor window

    func testThePanelIsASheetOnTheEditorWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        let panel = panel()
        window.beginSheet(panel)
        XCTAssertTrue(panel.sheetParent === window, "弹窗挂在编辑窗口上，不是屏幕居中")
        window.endSheet(panel)
    }

    // MARK: §4 — sidebar material, not alert glass

    func testTheContentIsTheSidebarMaterialWithARoundedCorner() throws {
        let panel = panel()
        let effect = try XCTUnwrap(panel.contentView as? NSVisualEffectView,
                                   "内容容器是 NSVisualEffectView，不再是 NSAlert 的窗口")
        XCTAssertEqual(effect.material, .sidebar, "和侧栏同一套材质")
        XCTAssertEqual(effect.blendingMode, .behindWindow)
        XCTAssertEqual(effect.layer?.cornerRadius, CopySettingsSheet.cornerRadius)
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertTrue(panel.titlebarAppearsTransparent)
        print("156 panel: \(Int(panel.frame.width))×\(Int(panel.frame.height)) material=\(effect.material.rawValue)")
    }

    // MARK: §2 — three columns, column-major

    func testTheRowsAreLaidOutInThreeColumnsColumnMajor() {
        let panel = panel()
        let view = panel.accessory
        let frames = view.rowFrames
        let expected = CopySettingsAccessoryView.rows(showsChildren: false)
        XCTAssertEqual(view.rows, expected, "行序列仍是 panelOrder")
        XCTAssertEqual(frames.count, expected.count)

        let xs = Set(frames.map { ($0.minX * 100).rounded() })
        print("156 columns: \(xs.count) x=\(xs.sorted()) rows=\(frames.count)")
        print("156 frames: \(frames.map { "(\($0.minX),\($0.minY),\($0.width),\($0.height))" })")
        XCTAssertEqual(xs.count, 3, "三列：\(xs.sorted())")

        let columnWidths = frames.map(\.width)
        XCTAssertTrue(columnWidths.allSatisfy { abs($0 - CopySettingsSheet.columnWidth) < 0.5 },
                      "列宽 \(CopySettingsSheet.columnWidth)：\(Set(columnWidths))")
        let rowHeights = frames.map(\.height)
        XCTAssertTrue(rowHeights.allSatisfy { abs($0 - CopySettingsSheet.rowHeight) < 0.5 },
                      "行高一致：\(Set(rowHeights))")

        // Column-major: i → (col: i / n, row: i % n), n = ceil(count / 3).
        let n = CopySettingsSheet.columnRows(for: frames.count)
        let columns = Array(Set(frames.map(\.minX))).sorted()
        XCTAssertEqual(columns.count, 3)
        for (i, frame) in frames.enumerated() {
            let expectedColumn = i / n
            let expectedRow = i % n
            let column = columns.firstIndex { abs($0 - frame.minX) < 0.5 } ?? -1
            XCTAssertEqual(column, expectedColumn, "第 \(i) 行应在第 \(expectedColumn) 列：\(frame)")
            let top = frames[expectedColumn * n].minY
            let expectedY = top - CGFloat(expectedRow) * CopySettingsSheet.rowHeight
            XCTAssertEqual(frame.minY, expectedY, accuracy: 0.5,
                           "第 \(i) 行（列内第 \(expectedRow) 行）")
        }

        // Within one column, reading top → bottom is decreasing minY, and the array order follows it.
        for column in columns {
            let inColumn = frames.enumerated()
                .filter { abs($0.element.minX - column) < 0.5 }
                .map(\.element)
            for (a, b) in zip(inColumn, inColumn.dropFirst()) {
                XCTAssertLessThan(b.minY, a.minY, "同一列 minY 单调递减（自上而下）")
            }
        }

        // Width is 3 × 260 + 2 × 24 = 828 of content, plus the two insets.
        XCTAssertEqual(CopySettingsSheet.gridWidth, 828, accuracy: 0.001)
        XCTAssertEqual(panel.frame.width,
                       CopySettingsSheet.gridWidth + 2 * CopySettingsSheet.contentInset,
                       accuracy: 1)
    }

    func testShowingChildrenKeepsTheSameThreeColumnRule() {
        let panel = panel(showsChildren: true)
        let view = panel.accessory
        let frames = view.rowFrames
        let expected = CopySettingsAccessoryView.rows(showsChildren: true)
        XCTAssertEqual(view.rows, expected)
        XCTAssertEqual(frames.count, expected.count)
        XCTAssertEqual(Set(frames.map { ($0.minX * 100).rounded() }).count, 3)

        let n = CopySettingsSheet.columnRows(for: frames.count)
        let columns = Array(Set(frames.map(\.minX))).sorted()
        for (i, frame) in frames.enumerated() {
            let column = columns.firstIndex { abs($0 - frame.minX) < 0.5 } ?? -1
            XCTAssertEqual(column, i / n, "子项也算一行，列优先不变（第 \(i) 行）")
            XCTAssertEqual(frame.minY, frames[(i / n) * n].minY
                           - CGFloat(i % n) * CopySettingsSheet.rowHeight,
                           accuracy: 0.5)
        }
    }
}
