import PhotonsCore
import PhotonsLocalization
import AppKit
import SwiftUI

/// 设置窗口（⌘,）。「通用」页：语言、外观、画布。页面结构按 SwiftUI 写，加页只需在
/// `SettingsPage` 里加一个 case —— 与 PR1 的 `SettingsWindowController` 同形，但不依赖
/// `StudioTheme` / `ApplicationPreferences`：main 上还没有那两样。
///
/// 语言**重启后生效**（`Loc.appliedLanguage` 在进程内冻结，见 `Localization.swift` 的说明）：
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
    /// 用户的选择（初始值 = 上次写下的偏好，不是本进程生效语言）。写进
    /// `UserDefaults`（`photons.language`），重启后被 `Loc` 读走。
    @State private var language: String = Loc.preferenceLanguage
    /// 473 — 外观：跟随系统 / 浅色 / 深色。选中即 `NSApp.appearance`，不需要重启。
    @State private var appearance: AppearancePreference = .current
    /// 473 — 画布衬底。显式选过就永久遵守；没选过时显示当前的随外观默认。
    @State private var canvasBackdrop: CanvasBackdrop = .current
    /// 555 — 解码偏好（自动 / 优先 v9 / 优先 v8）。写 `AppPreferences.store`，切换即重解当前文档。
    @State private var decoderPreference: DecoderVersionPreference.Preference =
        DecoderVersionPreference.setting

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.titleText)
                .font(.system(size: 20, weight: .semibold))
                .padding(.bottom, 2)
            Text(Self.subtitleText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 14) {
                languageRow
                appearanceRow
                canvasRow
                decoderSection
            }

            if let notice = Self.pendingNotice(for: language) {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .accessibilityIdentifier("settings.language.pendingNotice")
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(Loc.t("立即重启")) { relaunch() }
                    .disabled(!Self.isRelaunchEnabled(for: language))
                    .accessibilityIdentifier("settings.language.relaunch")
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 380, alignment: .topLeading)
        .onAppear {
            appearance = .current
            canvasBackdrop = .current
            decoderPreference = DecoderVersionPreference.setting
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
        .onChange(of: decoderPreference) { _, new in
            DecoderVersionPreference.setSetting(new)
        }
    }

    // MARK: language state

    /// 页面标题与说明：只用**生效语言**（`Loc.appliedLanguage`），所以写偏好不会当场换字。
    static var titleText: String { Loc.t("通用") }
    static var subtitleText: String { Loc.t("界面语言在下次启动时生效。") }

    /// 提示与「立即重启」的统一判据：选择 != 本进程生效语言。
    /// 切回原语言时两者相等，提示消失、按钮置灰。
    static func pendingNotice(for selected: String) -> String? {
        guard selected != Loc.appliedLanguage else { return nil }
        return Loc.t("已选 {0}，重启后生效。", Loc.localizedName(of: selected))
    }

    static func isRelaunchEnabled(for selected: String) -> Bool {
        selected != Loc.appliedLanguage
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

    /// 555 — 「解码」分区, after 画布: one three-way 解码偏好 row and the ML-cost note underneath.
    ///
    /// The note is a real `NSTextField` (not a SwiftUI `Text`) so a UI test can read the control's
    /// own font size and secondary colour, and so the smaller/secondary style is one AppKit fact
    /// instead of a source string.
    private var decoderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Loc.t("解码"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.decoder.title")
            HStack(spacing: 12) {
                Text(Loc.t("解码偏好"))
                    .frame(width: 64, alignment: .leading)
                Picker("", selection: $decoderPreference) {
                    ForEach(DecoderVersionPreference.Preference.allCases, id: \.self) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .accessibilityIdentifier("settings.decoderPreference")
            }
            SettingsSecondaryNote(text: Loc.t("解码版本 9 使用机器学习降噪算法，处理时长慢 5–10 倍"),
                                  identifier: "settings.decoderPreference.note")
                .frame(maxWidth: 380, alignment: .leading)
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

/// 555 — the settings window's one small secondary note line.
///
/// It is an `NSTextField` on purpose: 「小字/次要色」 is then a control fact (point size 11 and
/// `secondaryLabelColor`, dynamic with the appearance) that the acceptance test reads back from the
/// hosted view tree, not a claim about a SwiftUI modifier in the source.
struct SettingsSecondaryNote: NSViewRepresentable {
    let text: String
    let identifier: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 2
        field.setAccessibilityIdentifier(identifier)
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.setAccessibilityIdentifier(identifier)
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
    }
}
