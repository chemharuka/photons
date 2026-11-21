import PhotonsCore
import PhotonsLocalization
import AppKit
import SwiftUI

/// 设置窗口（⌘,）。「通用」页：语言、外观、画布。页面结构按 SwiftUI 写，加页只需在
/// `SettingsPage` 里加一个 case —— 与 PR1 的 `SettingsWindowController` 同形，但不依赖
/// `StudioTheme` / `ApplicationPreferences`：main 上还没有那两样。
///
/// 语言**重启后生效**（`Loc.language` 在进程内冻结，见 `Localization.swift` 的说明）：
/// 菜单、工具窗口、后台任务因此不会在一次运行中途换语言。外观没有这个约束
/// （`NSApp.appearance` 会对已有窗口立即生效），选中即应用。
@MainActor
public final class SettingsWindowController: NSWindowController {
    public static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = Loc.t("设置")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        super.init(window: window)
        window.center()
        window.setFrameAutosaveName("PhotonsSettings")
    }

    public required init?(coder: NSCoder) { fatalError("no nib") }

    @objc public func openSettings(_ sender: Any?) {
        centreOnAppScreen()
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 设置窗要出现在**当前 app 所在的那块屏**上，而不是主屏。
    ///
    /// 三件事都由这一处收口：
    /// 1. 首次打开时 `NSWindow.center()` 用的是 `NSScreen.main`（主屏），多屏用户会看到设置窗
    ///    跳到另一块屏上 —— 所以改成按 app 自己那块屏的 `visibleFrame` 居中。
    /// 2. 「app 那块屏」= 键盘窗口所在屏；没有键盘窗口时退到主窗口，再退到 `NSScreen.main`。
    /// 3. `setFrameAutosaveName` 会跨启动记住位置，而记住的位置可能属于另一块屏 —— 所以每次
    ///    打开时若窗当前所在的屏不是 app 的屏，就重新居中一次；已经在同一块屏上则**不动**
    ///    （用户自己拖的位置要留住，只在换屏时纠正）。
    private func centreOnAppScreen() {
        guard let window else { return }
        let appScreen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        guard let screen = appScreen else { window.center(); return }
        if window.screen === screen { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                      y: visible.midY - size.height / 2))
    }
}

public struct SettingsView: View {
    /// 当前选择。写进 `UserDefaults`（`photons.language`），重启后被 `Loc` 读走。
    @State private var language: String = Loc.language
    /// 473 — 外观：跟随系统 / 浅色 / 深色。选中即 `NSApp.appearance`，不需要重启。
    @State private var appearance: AppearancePreference = .current
    /// 473 — 画布衬底。显式选过就永久遵守；没选过时显示当前的随外观默认。
    @State private var canvasBackdrop: CanvasBackdrop = .current

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Loc.t("通用"))
                .font(.system(size: 20, weight: .semibold))
                .padding(.bottom, 2)
            Text(Loc.t("界面语言在下次启动时生效。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 14) {
                languageRow
                appearanceRow
                canvasRow
            }

            if language != Loc.language {
                Text(Loc.t("已选 {0}，重启后生效。", Loc.localizedName(of: language)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .accessibilityIdentifier("settings.language.pendingNotice")
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(Loc.t("立即重启")) { relaunch() }
                    .disabled(language == Loc.language)
                    .accessibilityIdentifier("settings.language.relaunch")
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 380, alignment: .topLeading)
        .onAppear {
            appearance = .current
            canvasBackdrop = .current
        }
        .onChange(of: language) { _, new in
            Loc.setLanguage(new)
        }
        .onChange(of: appearance) { _, new in
            AppearancePreference.apply(new)
            // 没显式选过画布时，高亮跟着外观默认走；显式选过则保持用户那一档。
            if AppPreferences.store.string(forKey: CanvasBackdrop.defaultsKey) == nil {
                canvasBackdrop = CanvasBackdrop.current
            }
        }
    }

    // MARK: rows

    private var languageRow: some View {
        HStack(spacing: 12) {
            Text(Loc.t("语言"))
                .frame(width: 64, alignment: .leading)
            Picker("", selection: $language) {
                ForEach(Loc.supportedLanguages, id: \.self) { code in
                    Text(Loc.localizedName(of: code)).tag(code)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .accessibilityIdentifier("settings.language")
        }
    }

    private var appearanceRow: some View {
        HStack(spacing: 12) {
            Text(Loc.t("外观"))
                .frame(width: 64, alignment: .leading)
            Picker("", selection: $appearance) {
                ForEach(AppearancePreference.allCases, id: \.self) { preference in
                    Text(Loc.t(appearanceLabel(preference))).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .accessibilityIdentifier("settings.appearance")
        }
    }

    private var canvasRow: some View {
        HStack(spacing: 12) {
            Text(Loc.t("画布"))
                .frame(width: 64, alignment: .leading)
            HStack(spacing: 8) {
                ForEach(CanvasBackdrop.allCases, id: \.self) { stop in
                    Button {
                        canvasBackdrop = stop
                        CanvasBackdrop.set(stop)
                    } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(swatch(stop))
                                .frame(width: 20, height: 20)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(.separator, lineWidth: 1))
                            Text(hexLabel(stop))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(canvasBackdrop == stop ? Color.accentColor.opacity(0.18)
                                                         : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(canvasBackdrop == stop ? Color.accentColor : .clear,
                                          lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .help(hexLabel(stop))
                    .accessibilityIdentifier("settings.canvasBackdrop.\(stop.rawValue)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.canvasBackdrop")
        }
    }

    private func appearanceLabel(_ preference: AppearancePreference) -> String {
        switch preference {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    private func swatch(_ stop: CanvasBackdrop) -> Color {
        let v = stop.displayEncoded
        return Color(.sRGB, red: v, green: v, blue: v, opacity: 1)
    }

    private func hexLabel(_ stop: CanvasBackdrop) -> String {
        String(format: "#%02X%02X%02X",
               stop.eightBitValue, stop.eightBitValue, stop.eightBitValue)
    }

    /// 重启自己：`open` 起新实例，旧的退出。语言在进程启动时定下，所以必须重启。
    private func relaunch() {
        let path = Bundle.main.bundlePath
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path),
                                           configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
