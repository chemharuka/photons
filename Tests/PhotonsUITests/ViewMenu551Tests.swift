import XCTest
import AppKit
import PhotonsLocalization
@testable import PhotonsUI

/// 551 — 显示菜单的「胶片条」「侧栏」：改名、当前模式灰掉、⌃⌘B / ⌃⌘A 真的通。
///
/// 快捷键那一条的现实根因：**键窗口是编辑窗口、但第一响应者是文本字段**时，`NSTextView`
/// 把 Control+字母当成自己的 Emacs 移动键（⌃B 后退一格、⌃A 行首），chord 到不了主菜单。
/// 复核用的独立 AppKit 探针：同一个窗口、同一份 `MainMenu.build()`，
/// `rootView` 持有焦点时 ⌃⌘B 切换成功；`NSTextField` 持有焦点时模式不变。
/// 修复是编辑窗口里的 `.keyDown` 本地监视器（与 `LoupeController.handleCropReturn` 同一装置）。
@MainActor
final class ViewMenu551Tests: XCTestCase {

    private var editor: EditorWindowController!
    private var savedBrowserMode: Any?

    override func setUpWithError() throws {
        _ = NSApplication.shared
        savedBrowserMode = AppPreferences.store.object(forKey: "photons.browserMode")
        AppPreferences.store.removeObject(forKey: "photons.browserMode")
        NSApp.mainMenu = MainMenu.build()
        editor = EditorWindowController(size: NSSize(width: 1200, height: 800))
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
        pump(0.05)
    }

    override func tearDownWithError() throws {
        editor?.window?.orderOut(nil)
        editor = nil
        NSApp.mainMenu = nil
        if let value = savedBrowserMode {
            AppPreferences.store.set(value, forKey: "photons.browserMode")
        } else {
            AppPreferences.store.removeObject(forKey: "photons.browserMode")
        }
    }

    // MARK: - helpers

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    private var stripSelector: Selector { #selector(EditorWindowController.toggleFilmstripAction(_:)) }
    private var listSelector: Selector { #selector(EditorWindowController.showBrowserListAction(_:)) }

    private func item(_ action: Selector) throws -> NSMenuItem {
        func find(in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            for item in menu.items {
                if item.action == action { return item }
                if let sub = item.submenu, let hit = find(in: sub) { return hit }
            }
            return nil
        }
        return try XCTUnwrap(find(in: NSApp.mainMenu), "主菜单里没有 action \(action)")
    }

    private func keyEvent(_ characters: String,
                          _ modifiers: NSEvent.ModifierFlags = [.control, .command]) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                       modifierFlags: modifiers,
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: editor.window?.windowNumber ?? 0,
                                       context: nil,
                                       characters: characters,
                                       charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: 0))
    }

    /// `performKeyEquivalent` resolves a nil-target item through the **key window**. An `xctest`
    /// process launched from a shell cannot hold key focus (`NSApp.isActive == false`), so the test
    /// hands AppKit the target the responder chain would have chosen. The shipped item stays
    /// nil-target — asserted before the hand-off.
    private func deliverToEditor(_ items: NSMenuItem...) {
        for item in items { item.target = editor }
    }

    private func restoreShippedTargets(_ items: NSMenuItem...) {
        for item in items { item.target = nil }
    }

    /// `NSMenu.update()` is per-menu: a main menu's update does not recurse into `显示`.
    private func updateViewMenu() {
        NSApp.mainMenu?.items.first { $0.submenu?.title == Loc.t("显示") }?.submenu?.update()
    }

    // MARK: - ① 改名

    func testTitlesAreFilmstripAndSidebar() throws {
        let strip = try item(stripSelector)
        let list = try item(listSelector)
        XCTAssertEqual(strip.title, Loc.t("胶片条"), "显示 ▸ 胶片条")
        XCTAssertEqual(list.title, Loc.t("侧栏"), "显示 ▸ 侧栏")
        XCTAssertNotEqual(strip.title, Loc.t("胶片条（第二浏览器）"), "旧标题必须消失")
        XCTAssertNotEqual(list.title, Loc.t("浏览列表"), "旧标题必须消失")
    }

    // MARK: - ② 当前模式灰掉

    func testCurrentBrowserModeIsGreyedOutAndTheOtherIsEnabled() throws {
        let strip = try item(stripSelector)
        let list = try item(listSelector)
        deliverToEditor(strip, list)
        defer { restoreShippedTargets(strip, list) }

        editor.rootView.setBrowserMode(.filmstrip)
        XCTAssertFalse(editor.validateMenuItem(strip), "已在胶片条 ⇒ 胶片条灰")
        XCTAssertTrue(editor.validateMenuItem(list), "已在胶片条 ⇒ 侧栏可点")
        XCTAssertEqual(strip.state, .on, "当前模式仍是 tick")
        XCTAssertEqual(list.state, .off)
        // AppKit's own answer, not only our return value: `update()` asks the target and writes
        // `isEnabled`. This would stay `true` if `validateMenuItem` were not exposed to ObjC.
        updateViewMenu()
        XCTAssertFalse(strip.isEnabled, "AppKit 应把胶片条行灰掉")
        XCTAssertTrue(list.isEnabled, "AppKit 应保留侧栏行")

        editor.rootView.setBrowserMode(.list)
        XCTAssertTrue(editor.validateMenuItem(strip), "已在侧栏 ⇒ 胶片条可点")
        XCTAssertFalse(editor.validateMenuItem(list), "已在侧栏 ⇒ 侧栏灰")
        XCTAssertEqual(strip.state, .off)
        XCTAssertEqual(list.state, .on)
        updateViewMenu()
        XCTAssertTrue(strip.isEnabled, "AppKit 应保留胶片条行")
        XCTAssertFalse(list.isEnabled, "AppKit 应把侧栏行灰掉")
    }

    // MARK: - ③ 快捷键真的通（菜单这条路）

    func testControlCommandBAndAReachTheEditorThroughTheMenu() throws {
        let strip = try item(stripSelector)
        let list = try item(listSelector)
        // The shipped wiring: no target, the responder chain supplies the window controller.
        XCTAssertNil(strip.target, "菜单项按出货版保持 nil target")
        XCTAssertNil(list.target, "菜单项按出货版保持 nil target")
        XCTAssertTrue(editor.responds(to: stripSelector), "窗口控制器实现胶片条 action")
        XCTAssertTrue(editor.responds(to: listSelector), "窗口控制器实现侧栏 action")
        XCTAssertTrue(editor.window?.windowController === editor,
                      "窗口控制器在窗口的响应链上")

        deliverToEditor(strip, list)
        defer { restoreShippedTargets(strip, list) }

        editor.rootView.setBrowserMode(.list)
        let bEvent = try keyEvent("b")
        XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: bEvent) ?? false,
                      "⌃⌘B 必须被主菜单认下")
        XCTAssertEqual(editor.rootView.browserMode, .filmstrip, "⌃⌘B ⇒ 胶片条")

        let aEvent = try keyEvent("a")
        XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: aEvent) ?? false,
                      "⌃⌘A 必须被主菜单认下")
        XCTAssertEqual(editor.rootView.browserMode, .list, "⌃⌘A ⇒ 侧栏")
    }

    // MARK: - ③' 快捷键真的通（文本字段持有焦点 —— 用户报的「不可用」）

    func testShortcutsSurviveATextFieldHoldingFocus() throws {
        let field = NSTextField(frame: NSRect(x: 12, y: 12, width: 240, height: 24))
        editor.rootView.addSubview(field)
        XCTAssertTrue(editor.window?.makeFirstResponder(field) ?? false,
                      "precondition：文本字段拿到键盘")

        editor.rootView.setBrowserMode(.list)
        NSApp.sendEvent(try keyEvent("b"))
        XCTAssertEqual(editor.rootView.browserMode, .filmstrip,
                       "字段编辑器不得再吞掉 ⌃⌘B")

        NSApp.sendEvent(try keyEvent("a"))
        XCTAssertEqual(editor.rootView.browserMode, .list,
                       "字段编辑器不得再吞掉 ⌃⌘A")
    }

    // MARK: - ④ 不禁用也能点：当前模式那一行不可点，另一行仍可切

    func testTheOtherModeActionStillSwitches() throws {
        editor.rootView.setBrowserMode(.list)
        let strip = try item(stripSelector)
        XCTAssertTrue(editor.validateMenuItem(strip), "侧栏模式下胶片条行可点")
        deliverToEditor(strip)
        defer { restoreShippedTargets(strip) }
        NSApp.sendAction(strip.action!, to: editor, from: strip)
        XCTAssertEqual(editor.rootView.browserMode, .filmstrip,
                       "点胶片条 action ⇒ 切到胶片条")

        let list = try item(listSelector)
        deliverToEditor(list)
        defer { restoreShippedTargets(list) }
        NSApp.sendAction(list.action!, to: editor, from: list)
        XCTAssertEqual(editor.rootView.browserMode, .list,
                       "点侧栏 action ⇒ 切回侧栏")
    }

    // MARK: - ⑤ 反向门：当前模式自己的快捷键不切换

    func testCurrentModesOwnShortcutDoesNothing() throws {
        let strip = try item(stripSelector)
        let list = try item(listSelector)
        deliverToEditor(strip, list)
        defer { restoreShippedTargets(strip, list) }

        editor.rootView.setBrowserMode(.filmstrip)
        updateViewMenu()
        XCTAssertFalse(strip.isEnabled, "已在胶片条，行必须灰")
        _ = NSApp.mainMenu?.performKeyEquivalent(with: try keyEvent("b"))
        XCTAssertEqual(editor.rootView.browserMode, .filmstrip,
                       "反向门：若 validateMenuItem 改回 return true，这里会切到侧栏")

        // The monitor must be a no-op in the same mode too, not a text-field ⌃B.
        NSApp.sendEvent(try keyEvent("b"))
        XCTAssertEqual(editor.rootView.browserMode, .filmstrip,
                       "当前模式的 chord 是 no-op")
    }
}
