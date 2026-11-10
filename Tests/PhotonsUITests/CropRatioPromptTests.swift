import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// ⑨ → 104 → 334 — **键入比例永远不弹框**；非法输入仍然一声响、什么都不写。
///
/// ⑨ 原本钉的是「弹层中心 = 窗口中心」，因为 `NSAlert.runModal()` 居中到**屏幕**、sheet 会落在标题栏
/// 下面。104 取消了弹框（chip 就地变字段），334 把字段变成**常显**的那一行（用户：「需要一个自定义
/// 比例的输入框」）。这一份保留 ⑨ 真正在守的语义 —— 「键入非法输入不写文档」 —— 只把入口换成卡片里
/// 那个一直看得见的字段；居中的几何已经没有测量对象，删掉的是过时的断言，不是功能。
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

    /// 非法输入：常显字段收下字符串 → 一声响、草稿与文档一个字节都不动、字段回到原文本。
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
        let fieldBefore = Self.field(in: inspector)?.stringValue
        let documentBefore = CropUITestSupport.documentHash(session)
        let visibleBefore = NSApp.windows.filter(\.isVisible).count
        let panelsBefore = NSApp.windows.filter { $0 is NSPanel }.count

        // The field is part of the card — there is no door to open and nothing to open it with.
        let field = try XCTUnwrap(Self.field(in: inspector), "334: 自定义比例字段必须常显")
        XCTAssertTrue(field.isEditable, "334: 字段必须可键入")
        XCTAssertNil(CropRatioPanels.shared.prompt, "104/334: 键入比例不许创建面板")
        XCTAssertEqual(NSApp.windows.filter(\.isVisible).count, visibleBefore,
                       "334: 字段常显，不许新建可见窗口")
        XCTAssertEqual(NSApp.windows.filter { $0 is NSPanel }.count, panelsBefore,
                       "334: 字段常显，不许新建面板")

        field.stringValue = "5:x"
        field.commitForTesting()
        CropUITestSupport.pump(0.1)
        inspector.layoutSubtreeIfNeeded()

        XCTAssertEqual(tool.draft.lock, lockBefore, "⑨/104: 被拒的输入不许改比例")
        XCTAssertEqual(CropUITestSupport.documentHash(session), documentBefore,
                       "⑨/104: 被拒的输入不许写文档")
        XCTAssertEqual(Self.field(in: inspector)?.stringValue, fieldBefore,
                       "⑨/104: 字段要回到草稿的文本")
        XCTAssertNil(CropRatioPanels.shared.prompt, "104: 全程没有面板")
        XCTAssertEqual(NSApp.windows.filter(\.isVisible).count, visibleBefore,
                       "104: 提交路径没有创建可见窗口")
        print("104 invalid · lock \(lockBefore.code) → \(tool.draft.lock.code)"
              + " · field \(fieldBefore ?? "nil") · visible \(visibleBefore) → \(NSApp.windows.filter(\.isVisible).count)")
    }

    /// `Esc` cancels: the typed text goes back to the draft's ratio and the lock is untouched.
    func testEscapePutsTheStoredRatioBack() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let window = try XCTUnwrap(editor.window)
        defer { window.orderOut(nil) }
        let loupe = editor.rootView.loupeController
        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        let inspector = editor.rootView.inspectorHost
        inspector.layoutSubtreeIfNeeded()

        let lockBefore = loupe.cropTool.draft.lock
        let field = try XCTUnwrap(Self.field(in: inspector))
        field.stringValue = "7:5"
        field.cancelForTesting()
        CropUITestSupport.pump(0.1)
        inspector.layoutSubtreeIfNeeded()

        XCTAssertEqual(loupe.cropTool.draft.lock, lockBefore, "334: Esc 不许写比例")
        XCTAssertEqual(field.stringValue, CropAspectRow.fieldText(for: loupe.cropTool),
                       "334: Esc 之后字段回到草稿的文本")
    }

    // MARK: - finding the shipped view

    private static func allViews(in root: NSView) -> [NSView] {
        var found: [NSView] = [root]
        for sub in root.subviews { found += allViews(in: sub) }
        return found
    }

    private static func field(in root: NSView) -> CustomRatioField? {
        allViews(in: root).compactMap { $0 as? CustomRatioField }
            .first { $0.accessibilityIdentifier() == CropAspectRow.customID }
    }
}
