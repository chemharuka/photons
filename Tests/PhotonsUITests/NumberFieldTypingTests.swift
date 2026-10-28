import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 派单 057 — **接线**测试：真的建一个 `NSWindow`，真的把 `NSTextField` 变成第一响应者，真的让 field
/// editor 去调 delegate，然后断言**字段自己的字符串**。
///
/// 052 的教训是这里的每一条断言的理由：那一版把规则放在 SwiftUI `TextField` 的 `Binding` setter 里，
/// 纯状态机的单元测试全绿，真机上「什么都没发生」——因为测的是规则，不是接线。所以这里的每一条都从
/// AppKit 的回调进（`controlTextDidBeginEditing` / 字段 editor 的 `shouldChangeTextIn` /
/// `doCommandBy` / `controlTextDidEndEditing`），不经过任何手写的状态机。
///
/// `swift test` 里能开窗口（这一版量过）：`NSApplication.shared` + 一个 `NSWindow` + `selectText(nil)`
/// 就能拿到真的 field editor，`NSTextView.insertText` 会照 AppKit 的规矩先问 delegate。
@MainActor
final class NumberFieldTypingTests: XCTestCase {

    // MARK: - 1. 首次按键 = 整个缓冲区

    /// 聚焦（`controlTextDidBeginEditing`）后敲 `5` → 字段里是 `5`，不是 `1.48`；再敲 `1` → `51`；
    /// 连打三个字符就是三个字符。
    func testTheFirstKeystrokeReplacesTheWholeBufferInTheField() throws {
        try withRow(exposureRow(1.48)) { h in
            let editor = try focus(h)
            XCTAssertEqual(editor.string, "1.48", "聚焦后显示的是干净数字，不是 `1.48 EV`")
            XCTAssertTrue(h.controller.state.pendingClear, "聚焦让规则就位")

            editor.setSelectedRange(NSRange(location: 0, length: 0))    // 鼠标点击留下的插入点
            editor.insertText("5", replacementRange: editor.selectedRange())

            XCTAssertEqual(editor.string, "5", "首次按键要把 1.48 整段换掉，不是插进去变成 51.48")
            XCTAssertEqual(h.field.stringValue, "5", "字段自己的字符串就是这个（不是只有某个状态机）")
            XCTAssertNotEqual(editor.string, "1.48", "旧行为：什么都没发生")
            XCTAssertFalse(h.controller.state.pendingClear, "规则只用一次")

            editor.insertText("1", replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.string, "51", "第二次按键不再清空")

            editor.insertText("0", replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.string, "510", "连打三个字符得到三个字符")
            print("057 · first key: 1.48 + 「5」 → 5 · 再「1」→ 51 · 再「0」→ 510")
        }
    }

    /// 粘贴 `-2.5`（一次插入多个字符）→ 缓冲区就是 `-2.5`。
    ///
    /// 用 `insertText` 而不是 `paste(nil)`：真实的粘贴走的是同一个 delegate 回调
    /// （`paste:` → `shouldChangeTextInRanges:replacementStrings:`，手工验过），但 `paste` 还会去动
    /// **共享** field editor 的 undo 栈，而一个测试进程里所有 harness 共用那一份，会带进上一个窗口
    /// 的残留范围。这里要钉的是「一次插入多字符」这一条路径。
    func testAPastedNumberBecomesTheWholeBuffer() throws {
        try withRow(exposureRow(1.48)) { h in
            let editor = try focus(h)
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.insertText("-2.5", replacementRange: editor.selectedRange())

            XCTAssertEqual(editor.string, "-2.5", "粘贴是「一次插入」，同样整段替换")
            XCTAssertEqual(h.field.stringValue, "-2.5")
            print("057 · paste: 「-2.5」 → -2.5")
        }
    }

    // MARK: - 2. 选区和删除都是局部编辑

    /// 聚焦后先选好一段再敲 → 走用户选区（局部替换），**不清空**；Backspace 同样不清空。
    func testAChosenRangeAndADeletionAreLocalEdits() throws {
        try withRow(exposureRow(1.48)) { h in
            let editor = try focus(h)
            // `1.48` 里选中 `4`，敲 `9`
            editor.setSelectedRange(NSRange(location: 2, length: 1))
            editor.insertText("9", replacementRange: editor.selectedRange())

            XCTAssertEqual(editor.string, "1.98", "选过文本 → 只替换选区（「只想改一位」）")
            XCTAssertFalse(h.controller.state.pendingClear, "规则同样只用一次")
        }

        try withRow(exposureRow(1.48)) { h in
            let editor = try focus(h)
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.deleteBackward(nil)

            XCTAssertEqual(editor.string, "1.4", "Backspace 是删除，不是「第一次按键」")
            XCTAssertFalse(h.controller.state.pendingClear)
        }
    }

    // MARK: - 3. 三个出口

    /// 清空后直接 `↵` = 取消：值不变、`history.count` 不变、不 beep。
    func testReturnOnAnEmptyBufferCancelsAndWritesNoHistory() throws {
        let session = session(holding: 1.48)
        let before = session.history.count
        var commits: [Double] = []
        var beeps = 0

        try withRow(exposureRow(1.48), onCommit: { typed in
            commits.append(typed)
            session.applyEdit { $0.light.exposure = typed }
            session.commitEdit(label: "曝光")
        }) { h in
            h.controller.beep = { beeps += 1 }
            let editor = try focus(h)

            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            editor.deleteBackward(nil)
            XCTAssertEqual(editor.string, "", "缓冲区被清空")

            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))

            XCTAssertTrue(commits.isEmpty, "空缓冲 ↵ 不写")
            XCTAssertEqual(beeps, 0, "空缓冲不是非法输入：不 beep")
            XCTAssertEqual(session.edit.light.exposure, 1.48, "旧值原封不动")
            XCTAssertEqual(session.history.count, before, "空缓冲 ↵ 不写历史")
            XCTAssertEqual(h.field.stringValue, "1.48 EV", "字段回到读数")
            XCTAssertFalse(h.controller.state.editing, "↵ 之后离开编辑")
        }
    }

    /// `Esc` 取消（不写、不 beep）；非法输入（`abc`）→ beep 一次 + 恢复 + 不写历史。
    func testEscapeCancelsAndJunkBeepsWithoutWriting() throws {
        let session = session(holding: 1.48)
        let before = session.history.count

        // Esc
        try withRow(exposureRow(1.48), onCommit: { typed in
            session.applyEdit { $0.light.exposure = typed }
            session.commitEdit(label: "曝光")
        }) { h in
            let editor = try focus(h)
            editor.insertText("2", replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.string, "2")

            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

            XCTAssertEqual(session.edit.light.exposure, 1.48, "Esc 不写")
            XCTAssertEqual(session.history.count, before, "Esc 不写历史")
            XCTAssertEqual(h.field.stringValue, "1.48 EV", "Esc 恢复读数")
        }

        // 非法输入（独立的一份 session：断言的是「这条路一行历史都没写」）
        let junkSession = self.session(holding: 1.48)
        let junkBefore = junkSession.history.count
        var beeps = 0
        try withRow(exposureRow(1.48), onCommit: { typed in
            junkSession.applyEdit { $0.light.exposure = typed }
            junkSession.commitEdit(label: "曝光")
        }) { h in
            h.controller.beep = { beeps += 1 }
            let editor = try focus(h)
            editor.insertText("abc", replacementRange: editor.selectedRange())

            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))

            XCTAssertEqual(beeps, 1, "非法输入 beep 一次")
            XCTAssertEqual(junkSession.edit.light.exposure, 1.48, "旧值还在")
            XCTAssertEqual(junkSession.history.count, junkBefore, "非法输入不写历史")
            XCTAssertEqual(h.field.stringValue, "1.48 EV", "恢复原值")
        }
        print("057 · exits: 空缓冲 ↵ / Esc → 不写 · abc → beep 一次 + 恢复")
    }

    /// **失焦 = 取消**（2026-10-28，用户）：「点击输入滑块值时，点击其他地方就取消点击输入，并退回之前的值」。
    ///
    /// 这条曾经是"失焦即提交"，用户为了不再出现"手滑点了画布，半截数字被写进文档"把它反过来了。
    /// 键盘确认（↵ / Tab）仍然提交 —— 见下一个用例。
    func testLosingFocusCancelsAndRestoresTheOldValue() throws {
        let session = session(holding: 1.48)
        let before = session.history.count
        var commits: [Double] = []

        try withRow(exposureRow(1.48), onCommit: { typed in
            commits.append(typed)
            session.applyEdit { $0.light.exposure = typed }
            session.commitEdit(label: "曝光")
        }) { h in
            let editor = try focus(h)
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.insertText("2", replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.string, "2")

            h.window.makeFirstResponder(nil)          // 点到别处
            pump()

            XCTAssertEqual(commits, [], "失焦不许写入")
            XCTAssertEqual(session.edit.light.exposure, 1.48, "文档退回之前的值")
            XCTAssertEqual(session.history.count, before, "一条历史都不许多")
            XCTAssertEqual(h.field.stringValue, "1.48 EV", "读数退回之前的值")
            XCTAssertFalse(h.controller.state.editing)
        }
        print("057 · blur cancels: 2 → 文档仍是 1.48 · history +0")
    }

    /// 键盘确认（`↵`）照旧提交：一次输入 = 一条历史。
    func testReturnCommitsExactlyOneHistoryEntry() throws {
        let session = session(holding: 1.48)
        let before = session.history.count
        var commits: [Double] = []

        try withRow(exposureRow(1.48), onCommit: { typed in
            commits.append(typed)
            session.applyEdit { $0.light.exposure = typed }
            session.commitEdit(label: "曝光")
        }) { h in
            let editor = try focus(h)
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.insertText("2", replacementRange: editor.selectedRange())
            editor.insertNewline(nil)                                // what ↵ does in a field editor
            pump()

            XCTAssertEqual(commits, [2], "↵ 提交一次，值就是缓冲里的")
            XCTAssertEqual(session.edit.light.exposure, 2)
            XCTAssertEqual(session.history.count, before + 1, "一次输入 = 一条历史")
            XCTAssertEqual(h.field.stringValue, "2.00 EV")
        }
        print("057 · return commits: 2 → 文档 2.0 · history +1")
    }

    /// 直接点滑块：退出输入、**不写缓冲区**，然后滑块的新值生效（用户的原话：这条是防 bug 的）。
    func testClickingTheSliderEndsTextEntryWithoutWritingTheBuffer() throws {
        let session = session(holding: 1.48)
        let before = session.history.count
        var commits: [Double] = []

        try withRow(exposureRow(1.48), onCommit: { typed in
            commits.append(typed)
            session.applyEdit { $0.light.exposure = typed }
            session.commitEdit(label: "曝光")
        }) { h in
            let editor = try focus(h)
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.insertText("9", replacementRange: editor.selectedRange())

            // What clicking the slider does first: the field editor loses first responder.
            h.window.makeFirstResponder(nil)
            pump()
            // …then the drag writes through the normal path.
            session.applyEdit { $0.light.exposure = 0.25 }
            session.commitEdit(label: "曝光")

            XCTAssertEqual(commits, [], "缓冲区里的 9 不许被写进去")
            XCTAssertEqual(session.edit.light.exposure, 0.25, "滑块的值才是最新的")
            XCTAssertEqual(session.history.count, before + 1, "只留滑块那一条历史")
            // The readout itself is refreshed by SwiftUI re-rendering the row (`update(row:)`), which
            // this harness does not pump — the two facts that matter are above.
        }
        print("057 · click slider: 缓冲区丢弃 · 滑块值 0.25 生效 · history +1")
    }

    func testWithoutTheRangeRewriteTheSameKeystrokeStaysInsideTheReadout() throws {
        let window = makeWindow()
        let plain = NSTextField(frame: NSRect(x: 10, y: 10, width: 120, height: 18))
        plain.stringValue = "1.48"
        window.contentView?.addSubview(plain)
        defer { window.makeFirstResponder(nil); window.orderOut(nil) }

        XCTAssertTrue(window.makeFirstResponder(plain))
        let editor = try XCTUnwrap(plain.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.string, "1.48")

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("5", replacementRange: editor.selectedRange())

        XCTAssertEqual(editor.string, "51.48", "没有范围改写：字符落进读数里 —— 052 在真机上「什么都没发生」")
        XCTAssertNotEqual(editor.string, "5", "第 1 条在这里必须红")
        print("057 · negative control: 没有范围改写的同一个按键 → 51.48")
    }

    // MARK: - the harness

    struct Harness {
        let window: NSWindow
        let field: NumberTextField
        let controller: NumberFieldController
    }

    /// Harness windows live until the test process exits; nothing AppKit-owned is deallocated inside a
    /// test. XCTest's memory checker dereferences the objects a test let go of
    /// (`_assertInvalidObjectsDeallocatedAfterScope` → `objc_release` on a stale pointer) and a window
    /// *plus* the shared field editor is exactly the shape that crashes it. Seven offscreen windows for
    /// one test run is the cheap side of that trade.
    private static var windows: [NSWindow] = []

    private func exposureRow(_ value: Double) -> NumberFieldRow {
        NumberFieldRow(value: value, range: -5 ... 5, format: "%.2f EV", decimals: 2, rounding: .asIs)
    }

    private func session(holding exposure: Double) -> CatalogSession {
        let session = CatalogSession()
        session.applyEdit { $0.light.exposure = exposure }
        session.commitEdit(label: "拖动")
        return session
    }

    private func makeWindow() -> NSWindow {
        // A window needs an app; a test bundle has none until one is asked for.
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        Self.windows.append(window)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Build a field exactly the way the panel does (`NumberFieldView` calls the same `attach`).
    private func withRow(_ row: NumberFieldRow,
                         onCommit: @escaping (Double) -> Void = { _ in },
                         _ body: (Harness) throws -> Void) rethrows {
        let window = makeWindow()
        let controller = NumberFieldController(row: row, fontSize: 10, onCommit: onCommit)
        let field = NumberTextField(frame: NSRect(x: 10, y: 10, width: 120, height: 18))
        field.attach(controller)
        window.contentView?.addSubview(field)
        defer {
            window.makeFirstResponder(nil)      // hand the shared field editor back
            window.orderOut(nil)
        }

        try body(Harness(window: window, field: field, controller: controller))
    }

    /// Focus the field the way a click does (`mouseDown` → first responder), then hand back the real
    /// field editor. Deliberately **not** `selectText(nil)`: that ends and restarts the edit on an
    /// already-focused field, which fires a spurious end-of-editing and puts the readout back.
    private func focus(_ h: Harness) throws -> NSTextView {
        XCTAssertTrue(h.window.makeFirstResponder(h.field), "字段必须能成为第一响应者")
        let editor = try XCTUnwrap(h.field.currentEditor() as? NSTextView, "字段没有 field editor")
        XCTAssertTrue(h.controller.state.editing,
                      "聚焦必须让规则就位 —— `becomeFirstResponder` 没有把 `pendingClear` 打开")
        return editor
    }

    /// Let AppKit deliver the notifications it posts around focus.
    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }
}
