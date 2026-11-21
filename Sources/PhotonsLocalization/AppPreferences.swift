import Foundation

/// 466 / 467 —— **所有用户偏好的唯一入口**（`photons.*` 那些键）。
///
/// 为什么要有这一层：偏好是「用户的」，而测试与烟测跑的也是**同一台机器、同一个 `UserDefaults`**：
///
///   · `ui-smoke` 跑的是**打包好的 app 本体**，它的 `UserDefaults.standard` 就是用户的
///     `com.nousresearch.photons`，一次烟测就会把筛选条、排序、画布背景、色标门限写一遍；
///   · `swift test` 用的是 `com.apple.dt.xctest.tool` 这个**全机共享**的域，测试之间互相覆盖，
///     而且留下来的值下次跑还会被读回去（「照片筛选被测试改写」就是这么来的）。
///
/// 所以默认值一律解析到这里，而不是各文件里写 `UserDefaults.standard`：
///
///   · 装过 `install(_:)` 的进程（`--ui-smoke`）= 那一份专用 suite，跑完整个域删掉；
///   · 进程里加载了 XCTest（`swift test`）= **每次进程一个**隔离 suite，
///     `com.nousresearch.photons.tests.<UUID>`，退出时删掉；
///   · 真正的 app = `UserDefaults.standard`。
///
/// 一条纪律：新写的偏好代码必须用 `AppPreferences.store`（或注入的 store），不许再出现
/// `UserDefaults.standard` —— 否则又回到「测试覆盖用户设置」。
public enum AppPreferences {

    /// `--ui-smoke` 的专用域。和 `ExportDefaults.smokeSuiteName` 同名：一个进程只该有一份夹具域。
    public static let smokeSuiteName = "com.nousresearch.photons.uismoke"

    /// 测试进程的隔离域前缀；完整名字带上进程 UUID，跑完就删，跨次运行不共享。
    public static let testsSuitePrefix = "com.nousresearch.photons.tests."

    /// 装过的那份域（烟测/宿主用）。`nil` 表示没装。
    public private(set) static var override: UserDefaults?

    /// 本进程实际用到的测试域名字（`nil` = 不是测试进程），探针与日志用。
    public private(set) static var isolatedSuiteName: String?

    /// 装/卸一份域。烟测在开库之前调用，跑完 `install(nil)`。
    public static func install(_ defaults: UserDefaults?) {
        override = defaults
    }

    /// 这个进程里加载了 XCTest。只用来把默认 store 挡在真实域之外；生产二进制不链接 XCTest。
    public static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// 偏好的默认 store。**唯一**该被 preference 代码引用的 `UserDefaults`。
    public static var store: UserDefaults {
        if let override { return override }
        if isRunningTests { return testStore }
        return .standard
    }

    /// 测试进程的那一份：一个进程一个 UUID 域，创建时先清空，退出时整个删掉。
    ///
    /// 用 UUID 而不是 `standard`：同一次 `swift test` 里的多个用例共享它（同一个库的筛选要能
    /// 「重启后读回」），但下一次运行一定是干净的；进程退出删掉，`defaults domains` 里不留垃圾。
    private static let testStore: UserDefaults = {
        let name = testsSuitePrefix + UUID().uuidString
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        isolatedSuiteName = name
        IsolatedTestSuite.name = name
        atexit(removeIsolatedTestSuiteAtExit)
        return defaults
    }()

    /// 烟测用的那一份：开跑前清空，跑完删掉。
    public static func makeSmokeStore() -> UserDefaults? {
        let suite = UserDefaults(suiteName: smokeSuiteName)
        suite?.removePersistentDomain(forName: smokeSuiteName)
        return suite
    }
}

/// `atexit` 只收「不捕获上下文的 C 函数」，所以待清理的域名放在文件级盒子里，清理函数也是文件级的。
private enum IsolatedTestSuite {
    static var name: String?
}

private func removeIsolatedTestSuiteAtExit() {
    guard let name = IsolatedTestSuite.name else { return }
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    // `removePersistentDomain` 之后 cfprefsd 仍会留一个 42 字节的空 plist；测试进程不该在
    // `~/Library/Preferences/` 里留下自己的名字，所以把文件也删掉（`defaults delete` 做的就是这件事）。
    let plist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(name).plist")
    try? FileManager.default.removeItem(at: plist)
}
