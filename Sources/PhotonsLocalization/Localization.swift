import Foundation

/// 界面文案的唯一入口。
///
/// **key 就是中文原文**（不是哈希、不是 `inspector.effects.title`）：代码里写 `Loc.t("效果卡")`，
/// `zh-Hans.lproj` 里 `"效果卡" = "效果卡"`，`en.lproj` 里 `"效果卡" = "Effects panel"`。
/// 这样任何一个调用点都能直接读出用户看到的字，翻译表也能逐行对照代码，不必维护「key ↔ 文案」
/// 的第三份映射（PR1 的哈希 key 正是这份映射：`extract.py` 生成的 12 位哈希，读代码时无从还原）。
///
/// 两条代入约定，与 PR1 的表一一对应（表是从 PR1 的 `zh-Hans.json`/`en.json` 按中文原文重组的）：
///
/// - `Loc.t(_:_:)` —— 表里的 `{0}` `{1}` 占位，按位置代入 `String`。用于 `\(expr)` 插值。
/// - `Loc.f(_:_:)` —— 表里带 `%.2f` 之类的 printf 说明符，走 `String(format:)`，参数是 `CVarArg`。
///
/// 语言在**进程内冻结**：界面文字只看 `appliedLanguage`，它第一次读时定下来；
/// 菜单、工具窗口、后台任务因此不会中途换语言。改语言只写偏好（`photons.language`），
/// 重启后新的进程才会用新语言 —— 与 PR1 的口径一致。
public enum Loc {
    /// 语言变更（写入偏好后）——供设置窗口刷新自己的说明文字。
    public static let languageDidChange = Notification.Name("photons.languageDidChange")

    public static let defaultLanguage = "zh-Hans"
    public static let supportedLanguages = ["zh-Hans", "en"]

    /// 当前偏好解析出的语言（`PHOTONS_LANGUAGE` 优先，其次偏好，最后默认中文）。
    ///
    /// 注意：这是**偏好**，不是界面正在使用的语言。偏好一写这里就变，但 `Loc.t` / `Loc.f`
    /// 只认 `appliedLanguage`；判断「选的和生效的是否一致」也要用 `appliedLanguage`。
    public static var language: String {
        resolve(environment: ProcessInfo.processInfo.environment["PHOTONS_LANGUAGE"])
    }

    /// 用户上次选的语言（只读 `photons.language`，不含 `PHOTONS_LANGUAGE` 覆盖）。
    /// 设置窗口的选中项用它：用户看到的应当是自己上次的选择，而不是测试/命令行的临时覆盖。
    public static var preferenceLanguage: String {
        resolve(environment: nil)
    }

    /// 本进程真正生效的界面语言：第一次读时定下来，之后不再随偏好变化。
    ///
    /// `PHOTONS_LANGUAGE`（测试/命令行）优先，其次偏好，最后默认中文；与 `language` 的解析
    /// 顺序相同，但结果**冻结**。所有取表的地方（`t` / `f`）只用它 —— 这就是「重启后生效」。
    public static var appliedLanguage: String {
        FrozenLanguage.shared.value
    }

    private static func resolve(environment: String?) -> String {
        let raw = environment
            ?? AppPreferences.store.string(forKey: keyLanguage)
            ?? defaultLanguage
        return supportedLanguages.contains(raw) ? raw : defaultLanguage
    }

    /// 进程内的生效语言。用锁而不是 `static let` 是为了让测试能在同一进程里模拟
    /// 「以 en 偏好启动」—— 生产代码没有任何写入点，第一次读之后就固定。
    private final class FrozenLanguage: @unchecked Sendable {
        static let shared = FrozenLanguage()

        private let lock = NSLock()
        private var frozen: String?
        private var frozenEnvironment: String?

        var value: String {
            lock.lock(); defer { lock.unlock() }
            let environment = ProcessInfo.processInfo.environment["PHOTONS_LANGUAGE"]
            // 生产里环境变量启动后不会变；测试会在同一进程里改 `PHOTONS_LANGUAGE`
            // （`LocalizationTableTests` 的端到端用例），那只对测试进程重新定一次。
            if frozen == nil || (AppPreferences.isRunningTests && environment != frozenEnvironment) {
                frozen = Loc.resolve(environment: environment)
                frozenEnvironment = environment
            }
            return frozen ?? Loc.defaultLanguage
        }

        /// 只给测试：钉住生效语言；传 `nil` 表示下次读时重新按启动语义解析。
        func override(_ code: String?) {
            lock.lock(); defer { lock.unlock() }
            frozen = code
            frozenEnvironment = ProcessInfo.processInfo.environment["PHOTONS_LANGUAGE"]
        }
    }

    /// 只给测试：模拟一次「以某个生效语言启动」；生产代码不调用。
    static func setAppliedLanguageForTesting(_ code: String?) {
        FrozenLanguage.shared.override(code)
    }

    public static let keyLanguage = "photons.language"

    public static func setLanguage(_ code: String) {
        guard supportedLanguages.contains(code) else { return }
        AppPreferences.store.set(code, forKey: keyLanguage)
        NotificationCenter.default.post(name: languageDidChange, object: nil)
    }

    public static func localizedName(of code: String) -> String {
        switch code {
        case "zh-Hans": return "中文"
        case "en": return "English"
        default: return code
        }
    }

    /// 每种语言的 `.lproj` 包，按语言缓存（`Bundle(path:)` 不必重复打开）。
    /// 缺表时回落到 `Bundle.module` 本身 —— 于是返回 key 即中文原文，不会返回空串。
    ///
    /// 用字典而**不是**一个 `static let`：界面语言在进程内冻结（`appliedLanguage`），
    /// 但测试要在同一进程里模拟不同启动语言，按语言缓存才能让两种表都被读到。
    private static let bundles = BundleCache()
    private final class BundleCache: @unchecked Sendable {
        private var cache: [String: Bundle] = [:]
        private let lock = NSLock()
        func bundle(for code: String) -> Bundle {
            lock.lock(); defer { lock.unlock() }
            if let hit = cache[code] { return hit }
            let resolved: Bundle
            if let path = Bundle.module.path(forResource: code, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                resolved = bundle
            } else {
                resolved = .module
            }
            cache[code] = resolved
            return resolved
        }
    }

    /// 资源包本身 —— 给**表级验收**用（`LocalizationTableTests`）。
    /// 测试 target 的 `Bundle.module` 指向测试自己的 bundle，读不到这里的 `.lproj`，
    /// 所以必须由这个 target 把入口交出来，测试不许自己拼路径。
    public static var resourceBundle: Bundle { .module }

    /// 某语言的表地址；表不存在时返回 nil（不是崩）。
    public static func stringsURL(for language: String) -> URL? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.url(forResource: "Localizable", withExtension: "strings")
    }

    private static func raw(_ key: String) -> String {
        bundles.bundle(for: appliedLanguage).localizedString(forKey: key, value: key, table: nil)
    }

    // MARK: - 文案

    /// 无代入的文案。表里没有这个 key 时返回原文（中文），永远不返回空串、不崩。
    public static func t(_ key: String) -> String {
        raw(key)
    }

    /// `{0}` `{1}` 位置代入（PR1 表的约定）。从后往前替换，用户文本里形似占位符的内容不会被二次代入。
    public static func t(_ key: String, _ arguments: String...) -> String {
        guard !arguments.isEmpty else { return raw(key) }
        var text = raw(key)
        let matches = placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let numberRange = Range(match.range(at: 1), in: text),
                  let index = Int(text[numberRange]), arguments.indices.contains(index),
                  let whole = Range(match.range, in: text) else { continue }
            text.replaceSubrange(whole, with: arguments[index])
        }
        return text
    }

    /// printf 说明符路径（表里本来就写着 `%.1f`、`%@` 的那些行）。
    public static func f(_ format: String, _ arguments: CVarArg...) -> String {
        String(format: raw(format), arguments: arguments)
    }

    private static let placeholder = try! NSRegularExpression(pattern: "\\{([0-9]+)\\}")
}
