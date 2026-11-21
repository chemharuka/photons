import AppKit
import PhotonsCore
import PhotonsLocalization

/// 473 —— 外观（跟随系统 / 浅色 / 深色）。
///
/// 三态直接映射到 `NSApp.appearance`：`nil` **就是**「跟随系统」的唯一表示，不用 `.aqua` 冒充。
/// 与语言不同，外观没有进程内冻结的约束：`NSApp.appearance` 会对已有窗口立即生效，所以设置里
/// 选中即应用，不需要重启。
///
/// 偏好一律走 `AppPreferences.store`（467）：测试进程里它是隔离域，不会写到用户的真实设置。
public enum AppearancePreference: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    /// `nil` 只在「跟随系统」时出现。
    public var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    public static let defaultsKey = "photons.appearance"

    /// 读偏好。未知值（降级、手改）回落 `.system`，既不是 `.light` 也不崩。
    public static var current: Self {
        guard let raw = AppPreferences.store.string(forKey: defaultsKey),
              let stored = Self(rawValue: raw) else { return .system }
        return stored
    }

    /// 设置并立即应用（写入偏好 + `NSApp.appearance` + 画布默认衬底）。
    public static func apply(_ preference: Self) {
        AppPreferences.store.set(preference.rawValue, forKey: defaultsKey)
        applyToApp(preference)
    }

    /// 启动时调一次：读回偏好，应用到 app 与首帧画布默认。不重写偏好（未知值保持原样）。
    public static func applyStored() {
        applyToApp(current)
    }

    private static func applyToApp(_ preference: Self) {
        let appearance = preference.appearanceName.flatMap { NSAppearance(named: $0) }
        NSApp?.appearance = appearance
        updateCanvasFallback(for: preference)
    }

    /// 用户没显式选过画布时，衬底跟着外观走：深色 `#202020`，浅色 `#E6E6E6`。
    /// 只改 `CanvasBackdrop.fallback`（`current` 只在没有存储值时用它），显式选过的值永久优先。
    private static func updateCanvasFallback(for preference: Self) {
        let next: CanvasBackdrop
        switch preference {
        case .light:
            next = .light
        case .dark:
            next = .dark
        case .system:
            // `nil` 之后系统实际是哪一档，由 `effectiveAppearance` 回答；没有 app 时保守用深色。
            if let app = NSApp,
               app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua {
                next = .light
            } else {
                next = .dark
            }
        }
        guard CanvasBackdrop.fallback != next else { return }
        CanvasBackdrop.fallback = next
        NotificationCenter.default.post(name: .canvasBackdropDidChange, object: nil)
    }
}
