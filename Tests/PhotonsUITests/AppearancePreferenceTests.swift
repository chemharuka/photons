import XCTest
import AppKit
import SwiftUI
import PhotonsCore
import PhotonsLocalization
@testable import PhotonsUI

/// 473 —— 设置里的「外观：跟随系统 / 浅色 / 深色」，以及画布未选过时跟随外观的默认。
///
/// 三件事分开验，因为坏掉的方式不同：
///
///   ① 三态真的落到 `NSApp.appearance`（`nil` 就是跟随系统，不用 `.aqua` 冒充）；
///   ② 偏好持久化在 `photons.appearance`，未知值回落 `.system`；启动时 `applyStored()` 读回；
///   ③ 外观真的看得见：`HistogramCard` 在 aqua / darkAqua 窗口里分辨出明暗；
///   ④ 设置界面点「深色 / 跟随系统」立即生效（不重启）；
///   ⑤ 画布未选过 = 外观默认（深色 `#202020` / 浅色 `#E6E6E6`），显式选过则永久遵守。
///
/// 外观与画布默认都是全局状态：每条用例的 `tearDown` 都恢复成 `.system` + 原 defaults + 原 fallback。
@MainActor
final class AppearancePreferenceTests: XCTestCase {
    private var savedAppearance: Any?
    private var savedFallback: CanvasBackdrop = .dark

    override func setUp() {
        super.setUp()
        if NSApp == nil { _ = NSApplication.shared }
        savedAppearance = AppPreferences.store.object(forKey: AppearancePreference.defaultsKey)
        savedFallback = CanvasBackdrop.fallback
    }

    override func tearDown() {
        if let savedAppearance {
            AppPreferences.store.set(savedAppearance, forKey: AppearancePreference.defaultsKey)
        } else {
            AppPreferences.store.removeObject(forKey: AppearancePreference.defaultsKey)
        }
        AppearancePreference.apply(.system)
        CanvasBackdrop.fallback = savedFallback
        NotificationCenter.default.post(name: .canvasBackdropDidChange, object: nil)
        super.tearDown()
    }

    // MARK: - ① 三态

    func testTheThreeStatesLandOnNSAppAppearance() {
        AppearancePreference.apply(.light)
        XCTAssertEqual(NSApp.appearance?.name, .aqua, "浅色 = aqua")

        AppearancePreference.apply(.dark)
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua, "深色 = darkAqua")

        AppearancePreference.apply(.system)
        XCTAssertNil(NSApp.appearance, "跟随系统 = nil（不是 .aqua）")

        print("473 ① · light=aqua · dark=darkAqua · system=nil")
    }

    // MARK: - ② 持久化与未知值

    func testThePreferencePersistsAndAnUnknownValueFallsBackToSystem() {
        AppearancePreference.apply(.dark)
        XCTAssertEqual(AppPreferences.store.string(forKey: AppearancePreference.defaultsKey), "dark")

        // 模拟重启：把 app 的外观弄成别的，`applyStored` 必须读回 dark 并重新应用。
        NSApp.appearance = NSAppearance(named: .aqua)
        AppearancePreference.applyStored()
        XCTAssertEqual(AppearancePreference.current, .dark)
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua, "applyStored 读回了 dark")

        // 未知值（降级 / 手改）不崩、不当作 light。
        AppPreferences.store.set("purple", forKey: AppearancePreference.defaultsKey)
        XCTAssertEqual(AppearancePreference.current, .system)
        AppearancePreference.applyStored()
        XCTAssertNil(NSApp.appearance, "未知值按跟随系统处理")

        print("473 ② · photons.appearance = dark → applyStored() = darkAqua · purple → system/nil")
    }

    // MARK: - ③ 真的看得见

    func testTheHistogramCardSeesTheWindowAppearance() throws {
        let card = HistogramCardView()
        card.frame = NSRect(x: 0, y: 0, width: 244, height: 120)
        let window = NSWindow(contentRect: card.frame,
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = card
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        for (name, isDark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            window.appearance = NSAppearance(named: name)
            card.needsDisplay = true
            card.display()
            XCTAssertEqual(card.lastAppearanceIsDark, isDark,
                           "窗口外观 \(name.rawValue) 下 HistogramCard 的明暗判定")
        }

        print("473 ③ · HistogramCard in aqua → light readout · darkAqua → dark readout")
    }

    // MARK: - ④ 设置界面即时生效

    func testClickingDarkAndSystemInSettingsAppliesImmediately() throws {
        let host = NSHostingView(rootView: SettingsView())
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 380)
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        pump(host)

        // SwiftUI 的分段 Picker 把 `settings.appearance` 放在 AX 包装层上，底下的
        // `NSSegmentedControl` 没有 id；按三项文案认它，避免误点语言那一行。
        let wanted = [Loc.t("跟随系统"), Loc.t("浅色"), Loc.t("深色")]
        let picker = try XCTUnwrap(segmentedControl(in: host, labels: wanted),
                                   "找不到外观分段控件；现有分段控件：\(segmentedLabels(in: host))")
        XCTAssertEqual(picker.segmentCount, 3, "三项：跟随系统 / 浅色 / 深色")

        select(2, in: picker)
        pump(host)
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua, "点「深色」后立即生效")
        XCTAssertEqual(AppPreferences.store.string(forKey: AppearancePreference.defaultsKey), "dark",
                       "点「深色」后偏好已写")

        select(0, in: picker)
        pump(host)
        XCTAssertNil(NSApp.appearance, "点「跟随系统」后立即回到 nil")

        print("473 ④ · settings.appearance dark → darkAqua/defaults=dark · system → nil")
    }

    // MARK: - ⑤ 画布未选过时跟随外观

    func testCanvasFollowsTheAppearanceUntilExplicitlyChosen() {
        withFreshCanvasPreference {
            AppearancePreference.apply(.dark)
            XCTAssertEqual(CanvasBackdrop.current, .dark, "深色外观下未选过 = #202020")
            XCTAssertEqual(CanvasBackdrop.current.eightBitValue, 0x20)

            AppearancePreference.apply(.light)
            XCTAssertEqual(CanvasBackdrop.current, .light, "浅色外观下未选过 = #E6E6E6")
            XCTAssertEqual(CanvasBackdrop.current.eightBitValue, 0xE6)

            // 显式选过一档之后，外观再怎样都遵守用户的选择。
            CanvasBackdrop.set(.midGrey)
            AppearancePreference.apply(.dark)
            XCTAssertEqual(CanvasBackdrop.current, .midGrey, "显式选择永久优先")
            AppearancePreference.apply(.light)
            XCTAssertEqual(CanvasBackdrop.current, .midGrey, "浅色外观也不改写显式选择")

            print("473 ⑤ · unselected: dark → #202020, light → #E6E6E6; explicit midGrey survives")
        }
    }

    // MARK: - helpers

    /// 没存过画布偏好时运行，跑完恢复调用方的存储与外观。
    private func withFreshCanvasPreference(_ body: () -> Void) {
        let saved = AppPreferences.store.object(forKey: CanvasBackdrop.defaultsKey)
        AppPreferences.store.removeObject(forKey: CanvasBackdrop.defaultsKey)
        defer {
            if let saved {
                AppPreferences.store.set(saved, forKey: CanvasBackdrop.defaultsKey)
            } else {
                AppPreferences.store.removeObject(forKey: CanvasBackdrop.defaultsKey)
            }
        }
        body()
    }

    private func pump(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func select(_ index: Int, in control: NSSegmentedControl) {
        control.selectedSegment = index
        _ = control.sendAction(control.action, to: control.target)
    }

    private func segmentedControl(in root: NSView, labels: [String]) -> NSSegmentedControl? {
        allSubviews(of: root).compactMap { $0 as? NSSegmentedControl }.first { control in
            (0..<control.segmentCount).compactMap { control.label(forSegment: $0) } == labels
        }
    }

    private func segmentedLabels(in root: NSView) -> [String] {
        allSubviews(of: root).compactMap { $0 as? NSSegmentedControl }.map { control in
            "id=\(control.accessibilityIdentifier()) "
            + (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "?" }.joined(separator: "/")
        }
    }

    private func allSubviews(of root: NSView) -> [NSView] {
        var out: [NSView] = [root]
        for child in root.subviews { out += allSubviews(of: child) }
        return out
    }
}
