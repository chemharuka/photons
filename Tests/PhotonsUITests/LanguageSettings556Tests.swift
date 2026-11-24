import XCTest
import AppKit
import SwiftUI
@testable import PhotonsLocalization
@testable import PhotonsUI

/// 556 —— 设置里的语言：**切走再切回原语言不该还提示重启**，而且写偏好不许当场换界面文字。
///
/// 根因是「生效时机」：`Loc.t` 原来每次按偏好取表，`SettingsWindowController` 又拿
/// `language != Loc.language` 当提示判据 —— 同一拍里偏好刚写、判据那端也跟着变，
/// 于是切回中文仍可能显示「已选 中文，重启后生效」，文字还当场变成了英文。
///
/// 这里的门：
///   ① 中 → 英 → 中：提示出现 → 消失、重启按钮可用 → 置灰，标题/说明始终中文；
///   ② 英 → 中 → 英：镜像；
///   ③ 真的换语言只在重启后（`appliedLanguage` 定住，写偏好只影响提示）；
///   ④ 写偏好后 `Loc.t` 仍返回生效语言的文字（不换表）；
///   ⑤ 判据是 `appliedLanguage`，不是「当前偏好」。
///
/// 偏好走 `AppPreferences.store`（测试进程里是隔离域），不碰用户的 `photons.language`。
/// 生效语言用 `Loc.setAppliedLanguageForTesting` 模拟一次「以某种偏好启动」，tearDown 还原。
@MainActor
final class LanguageSettings556Tests: XCTestCase {

    private var windows: [NSWindow] = []
    private var savedPreference: String?
    private var savedAppliedLanguage: String!

    override func setUp() {
        super.setUp()
        if NSApp == nil { _ = NSApplication.shared }
        savedPreference = AppPreferences.store.string(forKey: Loc.keyLanguage)
        savedAppliedLanguage = Loc.appliedLanguage
    }

    override func tearDown() {
        if let savedPreference {
            AppPreferences.store.set(savedPreference, forKey: Loc.keyLanguage)
        } else {
            AppPreferences.store.removeObject(forKey: Loc.keyLanguage)
        }
        Loc.setAppliedLanguageForTesting(savedAppliedLanguage)
        for window in windows {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
        }
        windows = []
        super.tearDown()
    }

    // MARK: - ① 中 → 英 → 中

    func testSwitchingAwayAndBackDoesNotKeepTheRestartPrompt() throws {
        start(applied: "zh-Hans", preference: "zh-Hans")
        let host = hostSettings()

        XCTAssertEqual(SettingsView.titleText, "通用", "启动时界面是中文")
        XCTAssertEqual(SettingsView.subtitleText, "界面语言在下次启动时生效。")
        XCTAssertNil(SettingsView.pendingNotice(for: "zh-Hans"), "还没改，不该提示")
        XCTAssertFalse(SettingsView.isRelaunchEnabled(for: "zh-Hans"))

        select(1, in: try languagePicker(in: host))   // English
        pump()

        XCTAssertEqual(AppPreferences.store.string(forKey: Loc.keyLanguage), "en",
                       "选择必须写进偏好")
        XCTAssertEqual(SettingsView.pendingNotice(for: "en"), "已选 English，重启后生效。",
                       "提示必须用**生效语言**（中文）说话")
        XCTAssertTrue(SettingsView.isRelaunchEnabled(for: "en"), "此时才该能立即重启")
        XCTAssertEqual(SettingsView.titleText, "通用", "写偏好不许当场换标题")
        XCTAssertEqual(SettingsView.subtitleText, "界面语言在下次启动时生效。",
                       "写偏好不许当场换说明")

        select(0, in: try languagePicker(in: host))   // 中文
        pump()

        XCTAssertEqual(AppPreferences.store.string(forKey: Loc.keyLanguage), "zh-Hans")
        XCTAssertNil(SettingsView.pendingNotice(for: "zh-Hans"),
                     "切回原语言后不许再提示重启")
        XCTAssertFalse(SettingsView.isRelaunchEnabled(for: "zh-Hans"),
                       "切回原语言后重启按钮必须置灰")
        XCTAssertEqual(SettingsView.titleText, "通用", "界面始终是中文")
        XCTAssertEqual(SettingsView.subtitleText, "界面语言在下次启动时生效。")
    }

    // MARK: - ② 英 → 中 → 英

    func testTheEnglishSideMirrorsTheBehaviour() throws {
        start(applied: "en", preference: "en")
        let host = hostSettings()

        XCTAssertEqual(SettingsView.titleText, "General")
        XCTAssertEqual(SettingsView.subtitleText, "The interface language takes effect at the next launch.")
        XCTAssertNil(SettingsView.pendingNotice(for: "en"))
        XCTAssertFalse(SettingsView.isRelaunchEnabled(for: "en"))

        select(0, in: try languagePicker(in: host))   // 中文
        pump()

        XCTAssertEqual(AppPreferences.store.string(forKey: Loc.keyLanguage), "zh-Hans")
        XCTAssertEqual(SettingsView.pendingNotice(for: "zh-Hans"),
                       "Selected 中文; applies after a restart.",
                       "提示用生效语言（英文）说话")
        XCTAssertTrue(SettingsView.isRelaunchEnabled(for: "zh-Hans"))
        XCTAssertEqual(SettingsView.titleText, "General", "写偏好不许当场换标题")
        XCTAssertEqual(SettingsView.subtitleText, "The interface language takes effect at the next launch.",
                       "写偏好不许当场换说明")

        select(1, in: try languagePicker(in: host))   // English
        pump()

        XCTAssertEqual(AppPreferences.store.string(forKey: Loc.keyLanguage), "en")
        XCTAssertNil(SettingsView.pendingNotice(for: "en"), "切回原语言后不许再提示重启")
        XCTAssertFalse(SettingsView.isRelaunchEnabled(for: "en"), "切回原语言后重启按钮必须置灰")
        XCTAssertEqual(SettingsView.titleText, "General")
    }

    // MARK: - ③ 真的换语言只在重启后

    func testTheLanguageActuallyChangesOnlyAtTheNextLaunch() throws {
        start(applied: "en", preference: "en")
        XCTAssertEqual(Loc.appliedLanguage, "en", "以 en 偏好启动")
        XCTAssertEqual(Loc.t("通用"), "General", "界面文字是英文")

        let host = hostSettings()
        select(0, in: try languagePicker(in: host))   // 切回中文
        pump()

        XCTAssertEqual(AppPreferences.store.string(forKey: Loc.keyLanguage), "zh-Hans")
        XCTAssertEqual(SettingsView.pendingNotice(for: "zh-Hans"),
                       "Selected 中文; applies after a restart.")
        XCTAssertEqual(Loc.appliedLanguage, "en", "本次进程仍生效英文")
        XCTAssertEqual(Loc.t("通用"), "General", "本次进程不换表")
        XCTAssertEqual(SettingsView.titleText, "General", "界面文字不变")
    }

    // MARK: - ④ 不许当场换表

    func testLocDoesNotSwapTablesBeforeARestart() throws {
        start(applied: "zh-Hans", preference: "zh-Hans")
        XCTAssertEqual(Loc.t("通用"), "通用")

        Loc.setLanguage("en")

        XCTAssertEqual(Loc.language, "en", "偏好确实写成了 en")
        XCTAssertEqual(Loc.appliedLanguage, "zh-Hans", "生效语言没变")
        XCTAssertEqual(Loc.t("通用"), "通用",
                       "setLanguage 后 Loc.t 必须仍然返回 appliedLanguage 的文字")
    }

    // MARK: - ⑤ 判据是生效语言，不是当前偏好

    func testPendingNoticeComparesAgainstAppliedLanguageNotTheCurrentPreference() throws {
        XCTAssertFalse(AppPreferences.store === UserDefaults.standard,
                       "这条门必须跑在隔离域里，不许写用户真实的 photons.language")
        start(applied: "zh-Hans", preference: "zh-Hans")

        Loc.setLanguage("en")   // 偏好已是 en，但本进程生效仍是 zh
        XCTAssertEqual(Loc.language, "en")
        XCTAssertEqual(Loc.appliedLanguage, "zh-Hans")

        XCTAssertNil(SettingsView.pendingNotice(for: "zh-Hans"),
                     "选中项 == 生效语言 → 无提示，即使偏好已经被改成 en")
        XCTAssertFalse(SettingsView.isRelaunchEnabled(for: "zh-Hans"))
        XCTAssertEqual(SettingsView.pendingNotice(for: "en"), "已选 English，重启后生效。")
        XCTAssertTrue(SettingsView.isRelaunchEnabled(for: "en"))
    }

    // MARK: - helpers

    /// 模拟一次「以 preference 启动、生效语言是 applied」的进程。
    private func start(applied: String, preference: String) {
        XCTAssertTrue(Loc.supportedLanguages.contains(applied))
        XCTAssertTrue(Loc.supportedLanguages.contains(preference))
        AppPreferences.store.set(preference, forKey: Loc.keyLanguage)
        Loc.setAppliedLanguageForTesting(applied)
    }

    private func hostSettings() -> NSHostingView<SettingsView> {
        let host = NSHostingView(rootView: SettingsView())
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 380)
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        pump()
        return host
    }

    /// 分隔控件按文案认（`settings.language` 的 AX id 挂在包装层，不在 `NSSegmentedControl` 上）。
    private func languagePicker(in root: NSView) throws -> NSSegmentedControl {
        let labels = Loc.supportedLanguages.map { Loc.localizedName(of: $0) }
        let match = allSubviews(of: root).compactMap { $0 as? NSSegmentedControl }.first { control in
            (0..<control.segmentCount).compactMap { control.label(forSegment: $0) } == labels
        }
        return try XCTUnwrap(match, "找不到语言分段控件；现有：\(segmentedLabels(in: root))")
    }

    private func segmentedLabels(in root: NSView) -> [String] {
        allSubviews(of: root).compactMap { $0 as? NSSegmentedControl }.map { control in
            (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "?" }
                .joined(separator: "/")
        }
    }

    private func select(_ index: Int, in control: NSSegmentedControl) {
        control.selectedSegment = index
        _ = control.sendAction(control.action, to: control.target)
    }

    private func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func allSubviews(of root: NSView) -> [NSView] {
        var out: [NSView] = [root]
        for child in root.subviews { out += allSubviews(of: child) }
        return out
    }
}
