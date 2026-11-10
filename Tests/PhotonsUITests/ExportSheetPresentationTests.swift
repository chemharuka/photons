import XCTest
import AppKit
import SwiftUI
@testable import PhotonsExport
@testable import PhotonsUI

/// 321 — 真呈现路径的门。
///
/// 302 的布局测试是把 `ExportSheetView` 直接塞进测试窗口，所以「首屏 7 个常驻行」在那边是绿的；
/// 用户看到的是**空面板**，差别只可能出在应用真正走的那条路：`ExportSheetController.present(in:)`
/// → `NSWindow(560×640)` + `beginSheet` + `NSHostingController`。
///
/// 这条测试就是那条路：不再自己搭窗口，而是让 controller 开它自己的 sheet，然后在**真实宿主的
/// 坐标系里**读 `form`（ScrollView）与第一行 `export.format` 的 frame。两条读数：
///
///   1. `form` 的高度 ≥ 7 行的 pitch（7 × 32 = 224）—— 七行常驻决定得真有可能看见；
///   2. 第一行 `export.format` 整条落在窗口内容区里（不是 frame 有值但跑到窗口外/被裁掉）。
@MainActor
final class ExportSheetPresentationTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDownWithError() throws {
        for window in windows {
            window.makeFirstResponder(nil)
            if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil) }
            window.contentView = nil
        }
        windows = []
    }

    // MARK: - probe readback

    private func descendants(of root: NSView) -> [NSView] {
        var found: [NSView] = []
        for sub in root.subviews {
            found.append(sub)
            found += descendants(of: sub)
        }
        return found
    }

    private func layoutProbes(_ kind: ExportLayoutProbe.Kind, in root: NSView) -> [ExportLayoutProbe] {
        descendants(of: root).compactMap { $0 as? ExportLayoutProbe }.filter { $0.kind == kind }
    }

    private func gridProbes(_ kind: ExportRowGridProbe.Kind, in root: NSView) -> [ExportRowGridProbe] {
        descendants(of: root).compactMap { $0 as? ExportRowGridProbe }.filter { $0.kind == kind }
    }

    private func frame(of view: NSView, in root: NSView) -> NSRect {
        view.convert(view.bounds, to: root)
    }

    // MARK: - the real path

    /// Opens the sheet exactly like 文件 ▸ 导出… does and returns the hosting view + sheet window.
    private func presentSheetLikeTheApp() throws -> (controller: ExportSheetController,
                                                     window: NSWindow,
                                                     content: NSView) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        parent.makeKeyAndOrderFront(nil)
        windows.append(parent)

        let session = CatalogSession(remembersRecentLibrary: false)
        let controller = ExportSheetController(session: session)
        controller.present(in: parent)

        let window = try XCTUnwrap(controller.sheetWindow, "present(in:) 没有开 sheet 窗口")
        windows.append(window)
        let content = try XCTUnwrap(window.contentView, "sheet 窗口没有 contentView")

        // 布局不是一次就稳：sheet 呈现有动画，hosting 的 fitting 尺寸在头几帧里还会变。
        for _ in 0..<10 {
            window.layoutIfNeeded()
            content.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        window.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()
        return (controller, window, content)
    }

    private func dump(_ controller: ExportSheetController, _ window: NSWindow, _ content: NSView) {
        let contentRect = content.frame
        let form = layoutProbes(.form, in: content).first
        let rows = gridProbes(.row, in: content)
        let formatRow = rows.first { $0.rowID == "export.format" }
        let hosting = window.contentView as? NSHostingView<ExportSheetView>

        print("321 dump · window.frame \(window.frame)")
        print("321 dump · window.contentLayoutRect \(window.contentLayoutRect)")
        print("321 dump · content.frame \(contentRect) · bounds \(content.bounds)")
        print("321 dump · hosting.view.frame \(contentRect) · fittingSize \(content.fittingSize) "
              + "· intrinsic \(content.intrinsicContentSize)")
        print("321 dump · hosting.preferredContentSize \(hosting.map { String(describing: $0.intrinsicContentSize) } ?? "—")")
        print("321 dump · form frame \(form.map { "\(frame(of: $0, in: content))" } ?? "—") "
              + "· form frame(in window) \(form.map { "\($0.convert($0.bounds, to: nil))" } ?? "—")")
        print("321 dump · first row(export.format) \(formatRow.map { "\(frame(of: $0, in: content))" } ?? "—")")
        print("321 dump · row probes \(rows.count) · \(rows.map(\.rowID).joined(separator: ","))")
        print("321 dump · model.rows.count \(controller.model.rows.count) · preset \(controller.model.preset.format.rawValue)/\(controller.model.preset.quality)")
    }

    func testTheRealSheetHasRoomForSevenRowsAndShowsTheFirstOne() throws {
        let (controller, window, content) = try presentSheetLikeTheApp()
        dump(controller, window, content)

        let form = try XCTUnwrap(layoutProbes(.form, in: content).first, "form（ScrollView）探针不存在")
        let formRect = frame(of: form, in: content)
        let rows = gridProbes(.row, in: content)
        let formatRow = try XCTUnwrap(rows.first { $0.rowID == "export.format" }, "格式行探针不存在")
        let rowRect = frame(of: formatRow, in: content)

        // 1 —— 七行常驻决定的高度（pitch 32 × 7 = 224）。
        let sevenRows = ExportRowGrid.rowPitch * 7
        XCTAssertGreaterThanOrEqual(formRect.height, sevenRows,
                                    "321 · form 只有 \(formRect.height) pt，装不下 7 行（需 \(sevenRows)）")

        // 2 —— 第一行整条在窗口内容区里，而且真的在 `form` 的可见区里（ScrollView 高度为 0 时
        // frame 照样有值，但那一行谁也看不见 —— 这正是用户看到的空面板）。
        XCTAssertGreaterThanOrEqual(rowRect.minY, content.bounds.minY,
                                    "321 · 格式行 minY \(rowRect.minY) 在内容区外")
        XCTAssertLessThanOrEqual(rowRect.maxY, content.bounds.maxY,
                                 "321 · 格式行 maxY \(rowRect.maxY) 超出内容区 \(content.bounds.maxY)")
        XCTAssertGreaterThan(rowRect.height, 0, "321 · 格式行高度为 0")
        XCTAssertTrue(formRect.contains(rowRect),
                      "321 · 格式行 \(rowRect) 不在 form 的可见区 \(formRect) 里（被 ScrollView 裁掉）")
    }
}
