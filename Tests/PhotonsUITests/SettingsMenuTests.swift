import XCTest
import AppKit
import PhotonsLocalization
import PhotonsUI

/// 511 —— 设置窗口的**入口**验收。
///
/// 这条只验菜单（`MainMenu.build()` 不需要窗口、不需要 RAW），因为「⌘, 打开设置」最容易坏的地方
/// 不是窗口本身，而是菜单项：`AppKit` 对 ⌘, 只认「App 菜单里 keyEquivalent 等于逗号且 target 非空的那一项」，
/// 少一个条件就静默失效 —— 窗口代码再好也点不开。
@MainActor
final class SettingsMenuTests: XCTestCase {

    /// `MainMenu.build()` 结尾会写 `NSApp.windowsMenu`，所以必须有 `NSApplication` 实例；
    /// 单跑这个类时 XCTest 不一定已经建过它（实测过一次 nil 崩溃）—— 这里自己兜底。
    override func setUp() {
        super.setUp()
        if NSApp == nil { _ = NSApplication.shared }
    }

    private func appMenu(_ menu: NSMenu) -> NSMenu? {
        menu.items.first?.submenu
    }

    func testTheAppMenuCarriesASettingsItemOnCommandComma() throws {
        let menu = MainMenu.build()
        let app = try XCTUnwrap(appMenu(menu), "主菜单第一项必须是 App 菜单")

        let settings = app.items.first { $0.keyEquivalent == "," }
        let item = try XCTUnwrap(settings, "App 菜单里没有 ⌘, 那一项")

        XCTAssertEqual(item.title, Loc.t("设置…"))
        XCTAssertEqual(item.action, #selector(SettingsWindowController.openSettings(_:)),
                       "⌘, 必须走设置窗口的 action")
        XCTAssertNotNil(item.target,
                        "target 为 nil 时 AppKit 走响应链，没有文档窗口时这一项就是死的")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertTrue(item.isEnabled, "没有文档窗口时也必须能打开设置")
    }

    func testTheSettingsItemSitsWhereThePlatformPutsIt() throws {
        let app = try XCTUnwrap(appMenu(MainMenu.build()))
        let titles = app.items.map(\.title)
        let index = try XCTUnwrap(titles.firstIndex(of: Loc.t("设置…")), "找不到设置项")

        // 系统惯例：关于 / 分隔 / 设置 / 分隔 / 隐藏…
        XCTAssertTrue(titles[..<index].contains { $0.hasPrefix(Loc.t("关于")) },
                      "设置必须在「关于」之后")
        XCTAssertTrue(index < titles.count - 1 && app.items[index + 1].isSeparatorItem,
                      "设置之后应当有一条分隔线")
        XCTAssertTrue(titles[(index + 1)...].contains { $0.hasPrefix(Loc.t("隐藏")) },
                      "隐藏类菜单必须排在设置之后")
    }

    /// 设置窗口只有一个实例：⌘, 连按两次不该堆出两个窗口（`shared` 是单例）。
    func testTheSettingsWindowIsASingleInstance() {
        XCTAssertTrue(SettingsWindowController.shared === SettingsWindowController.shared)
    }
}
