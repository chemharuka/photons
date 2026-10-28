import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// ⑨ → 104 — **键入比例不再弹框**；非法输入仍然一声响、什么都不写。
///
/// ⑨ 原本钉的是「弹层中心 = 窗口中心」，因为 `NSAlert.runModal()` 居中到**屏幕**、sheet 会落在标题栏
/// 下面。104 的用户口径（2026-10-29）直接取消了弹框：比例 chip 右侧的铅笔把 chip **就地**换成
/// 等宽的 `W:H` 字段。所以这一份保留 ⑨ 真正在守的语义 —— 「键入非法输入不写文档」 —— 只把入口从
/// 居中面板换成内联字段；居中的几何已经没有测量对象，删掉的是过时的断言，不是功能。
@MainActor
final class CropRatioPromptTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-inline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// 非法输入：内联字段收下字符串 → 一声响、草稿与文档一个字节都不动、chip 回到原文本。
    func testAnInvalidTypedRatioWritesNothingAndCreatesNoWindow() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let window = try XCTUnwrap(editor.window)
        defer { window.orderOut(nil) }
        let session = editor.session
        let loupe = editor.rootView.loupeController
        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        let inspector = editor.rootView.inspectorHost
        inspector.layoutSubtreeIfNeeded()

        XCTAssertTrue(loupe.isCropToolActive, "104: 进变换就已经在裁切模式")
        let tool = loupe.cropTool
        let lockBefore = tool.draft.lock
        let chipBefore = Self.chip(in: inspector)?.title
        let documentBefore = CropUITestSupport.documentHash(session)
        let windowsBefore = NSApp.windows.count

        // The pencil is the inline door — no menu, no panel.
        let pencil = try XCTUnwrap(Self.iconButton(CropAspectRow.editID, in: inspector),
                                   "104: 比例行没有铅笔按钮")
        pencil.performClick(nil)
        CropUITestSupport.pump(0.1)
        inspector.layoutSubtreeIfNeeded()

        let field = try XCTUnwrap(Self.inlineField(in: inspector), "104: chip 没有就地变成输入框")
        XCTAssertTrue(field.isEditable, "104: 内联字段必须可键入")
        XCTAssertNil(CropRatioPanels.shared.prompt, "104: 键入比例不许创建面板")
        XCTAssertEqual(NSApp.windows.count, windowsBefore, "104: 打开内联字段不许新建窗口")

        field.stringValue = "5:x"
        field.commitForTesting()
        CropUITestSupport.pump(0.1)
        inspector.layoutSubtreeIfNeeded()

        XCTAssertEqual(tool.draft.lock, lockBefore, "⑨/104: 被拒的输入不许改比例")
        XCTAssertEqual(CropUITestSupport.documentHash(session), documentBefore,
                       "⑨/104: 被拒的输入不许写文档")
        XCTAssertEqual(Self.chip(in: inspector)?.title, chipBefore,
                       "⑨/104: chip 要回到原来的文本")
        XCTAssertNil(Self.inlineField(in: inspector), "104: 提交后内联字段收回去")
        XCTAssertNil(CropRatioPanels.shared.prompt, "104: 全程没有面板")
        XCTAssertEqual(NSApp.windows.count, windowsBefore, "104: 提交路径没有创建任何窗口")
        print("104 invalid · lock \(lockBefore.code) → \(tool.draft.lock.code)"
              + " · chip \(chipBefore ?? "nil") · windows \(windowsBefore) → \(NSApp.windows.count)")
    }

    /// `Esc` cancels: the field goes away and the ratio is untouched (the old panel's cancel rule).
    func testEscapeCancelsTheInlineField() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let window = try XCTUnwrap(editor.window)
        defer { window.orderOut(nil) }
        let loupe = editor.rootView.loupeController
        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        let inspector = editor.rootView.inspectorHost
        inspector.layoutSubtreeIfNeeded()

        let lockBefore = loupe.cropTool.draft.lock
        let pencil = try XCTUnwrap(Self.iconButton(CropAspectRow.editID, in: inspector))
        pencil.performClick(nil)
        CropUITestSupport.pump(0.1)
        let field = try XCTUnwrap(Self.inlineField(in: inspector))
        field.stringValue = "7:5"
        field.cancelForTesting()
        CropUITestSupport.pump(0.1)
        inspector.layoutSubtreeIfNeeded()

        XCTAssertEqual(loupe.cropTool.draft.lock, lockBefore, "104: Esc 不许写比例")
        XCTAssertNil(Self.inlineField(in: inspector), "104: Esc 后字段收回")
    }

    // MARK: - finding the shipped views

    private static func allViews(in root: NSView) -> [NSView] {
        var found: [NSView] = [root]
        for sub in root.subviews { found += allViews(in: sub) }
        return found
    }

    private static func chip(in root: NSView) -> RatioChipButton? {
        allViews(in: root).compactMap { $0 as? RatioChipButton }
            .first { $0.accessibilityIdentifier() == CropAspectRow.chipID }
    }

    private static func iconButton(_ id: String, in root: NSView) -> RatioIconButton? {
        allViews(in: root).compactMap { $0 as? RatioIconButton }
            .first { $0.accessibilityIdentifier() == id }
    }

    private static func inlineField(in root: NSView) -> RatioInlineField? {
        allViews(in: root).compactMap { $0 as? RatioInlineField }
            .first { $0.accessibilityIdentifier() == CropAspectRow.fieldID }
    }
}
