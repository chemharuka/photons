import AppKit
import XCTest

/// 331 — 测试窗口的卫生：不进用户视线，并且一定被关掉。
///
/// 用户看到的「好多 photons-cold 的窗口」是 UI 测试自己造的**真窗口**：这个 target 里有 101 处
/// `NSWindow(contentRect:)`（宿主一个 loupe、一张卡片）加上编辑器的真窗，跑一大组用例时它们一个接一个
/// 出现在屏幕上，进程被掐掉时还留在那儿。这一份文件给它们两条规矩，别的地方只走这两个入口：
///
///   1. **不在用户眼前。** 由 `make` 造的窗一出生就在 `offscreen`（`-20000, -20000`，所有显示器之外），
///      并且带 `.transient` + `.ignoresCycle`，所以 Mission Control / ⌘Tab / 程序坞窗口列表里都没有它。
///      窗口仍然 **ordered in**（几套用例要活窗口：display-linked 绘制、first responder、合成按键），
///      所以 AppKit 的行为一点没变，只是画在没人看得到的地方。
///   2. **一定被关掉。** 走过这里的窗户都记在 `alive` 里，`TestWindowJanitor` 在**每个**用例结束时
///      （通过、断言失败、抛错都算）扫一遍 `NSApplication.shared.windows`，`orderOut` + `close`。
///
/// 两个细节是量出来的，不是猜的：
///
///   · **`constrainFrameRect` 必须关掉。** AppKit 不许一个 `.titled` 窗口离开屏幕：把一个 1200×800 的
///     标题窗挪到 `-20000, -20000`，实测停在 `x ∈ [-1102, 98]`、`y ∈ [-768, 32]` —— 左下角还留着一条
///     98×32 pt 的边。窗体子类把它关掉之后偏移才是真的（实测 `frame = {{-20000, -20000}, …}`）。
///   · **应用自己造的窗没法移出去（也不能改它）。** `EditorWindowController` 的窗口是 `PhotonsUI` 里的
///     生产对象，测试既不能让它继承子类，也不许在 app 里加「测试模式」分支（§1.4）。那种窗改用
///     `alphaValue = 0`：照样 ordered in、照样布局、照样是 key window，只是什么都画不出来 —— 对用户
///     而言和屏幕外没有区别。它们是 sheet 的 parent 时，sheet 也跟着不可见。
///
/// 断言行为不变：这里的窗口只是**位置**和**透明度**不同，`bounds` / `contentLayoutRect` / backing
/// scale / 命中坐标全是原来的值（`window.screen` 在屏幕外为 `nil`，`ScreenHeadroomSource` 与它自己
/// 的断言都用 `window.screen ?? NSScreen.main`，所以读数一致）。
@MainActor
enum TestWindows {

    /// 所有显示器之外。取值只要保证不和任何 `NSScreen.frame` 相交即可。
    static let offscreen = NSPoint(x: -20000, y: -20000)

    /// 331 自己量「改造前」用的开关（§2.1）：打开后窗口按老样子造、老样子 order，也不收尾 ——
    /// 两次运行共用同一套计数代码，峰值才有可比性。只在测试进程里读，不进任何生产路径。
    static var legacy: Bool {
        ProcessInfo.processInfo.environment["PHOTONS_TEST_WINDOW_LEGACY"] == "1"
    }

    /// 还没被收掉的窗。每个用例结束时清空。
    private(set) static var alive: [NSWindow] = []

    // MARK: - 造窗

    /// 一个不服从「标题栏必须留在屏幕上」的窗（见文件头第一条实测）。
    final class Window: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }

    /// 101 处 `NSWindow(contentRect:)` 的统一入口：同样的参数、同样的尺寸，只是出生在屏幕外。
    static func make(contentRect: NSRect,
                     styleMask: NSWindow.StyleMask = [.titled],
                     backing: NSWindow.BackingStoreType = .buffered,
                     defer flag: Bool = false) -> NSWindow {
        arm()
        let rect = legacy ? contentRect : NSRect(origin: offscreen, size: contentRect.size)
        let window = Window(contentRect: rect, styleMask: styleMask, backing: backing, defer: flag)
        TestWindowMetrics.noteCreated()
        adopt(window)
        return window
    }

    /// 别处造出来的窗（编辑器的、sheet 的 parent）纳入同样的两条规矩。
    static func adopt(_ window: NSWindow) {
        arm()
        if !alive.contains(where: { $0 === window }) { alive.append(window) }
        guard !legacy else {
            // 「改造前」的那次运行：窗口就是原来那个窗口 —— 不改 collectionBehavior、不改 alpha、
            // 不挪位置、收尾也不关（只有计数是新的）。
            TestWindowMetrics.sample("adopt")
            return
        }
        window.isReleasedWhenClosed = false
        // `PhotonsUI` gives the editor window `setFrameAutosaveName("PhotonsEditorWindow")`. A test
        // window that is *closed* saves whatever frame it had — and it had just been parked at
        // -20000 — into the process' defaults, so the next run would restore an off-screen frame (and
        // a size from whenever something last resized it). Measured: after one 331 run the defaults
        // held `-1102 -748 1200 780`, which changed the canvas height by 20 pt in a later run.
        // Dropping the autosave name keeps the parked frame, and the test's declared size, out of it.
        window.setFrameAutosaveName("")
        var behavior = window.collectionBehavior
        behavior.insert(.transient)
        behavior.insert(.ignoresCycle)
        window.collectionBehavior = behavior
        // 应用自己造的标题窗移不出屏幕（AppKit 会钳住），所以用透明度让它不可见；自己造的 `Window`
        // 已经真的在屏幕外了，不必也不该动它的 alpha。
        if !(window is Window) { window.alphaValue = 0 }
        park(window)
        TestWindowMetrics.sample("adopt")
    }

    /// 挪到屏幕外。`orderFront` 之后还要再挪一次：AppKit 可能在 ordering 时把窗口拽回屏幕边上。
    static func park(_ window: NSWindow) {
        guard !legacy else { return }
        window.setFrameOrigin(offscreen)
    }

    // MARK: - 上前台

    /// 61 处 `orderFront` / `makeKeyAndOrderFront` 的统一入口：先纳入规矩，再 order，再挪回屏幕外。
    /// `key: true` 是给需要 first responder 的合成按键用例的 —— 屏幕外的窗照样能当 key window。
    static func show(_ window: NSWindow?, key: Bool = false) {
        guard let window else { return }
        adopt(window)
        if key {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        park(window)
        TestWindowMetrics.noteShown()
        TestWindowMetrics.sample(key ? "show(key)" : "show")
    }

    // MARK: - 收尾

    /// 用例结束时扫一遍：登记的窗全部关掉，另外 AppKit 里任何还可见的窗（sheet、popover 的窗、
    /// 没走入口的窗）也关掉 —— 用例结束之后屏幕上不许留东西。
    static func sweep() {
        let tracked = alive
        alive.removeAll()
        for window in tracked {
            window.isReleasedWhenClosed = false
            if window.isVisible { window.orderOut(nil) }
            window.close()
        }
        for window in NSApplication.shared.windows where window.isVisible {
            window.isReleasedWhenClosed = false
            window.orderOut(nil)
            window.close()
        }
        TestWindowMetrics.sample("sweep")
    }

    /// `TestWindowJanitor` 的入口（它在主线程上被通知）。
    static func flush(testName: String) {
        if !legacy { sweep() }
        TestWindowMetrics.endOfTest(testName)
    }

    private static var armed = false
    private static func arm() {
        guard !armed else { return }
        armed = true
        TestWindowJanitor.install()
    }
}

/// 331 — 「一定被关掉」那一半。
///
/// 用 `XCTestObservation` 而不是基类或 `addTeardownBlock`：这个 target 的 212 个用例类里 89 个自己
/// override `setUpWithError`、93 个 override `tearDownWithError`，其中绝大多数**不调 `super`**（这是
/// 本仓库既有写法），基类的钩子会被它们整个跳过；而 `addTeardownBlock` 要在两千多个测试方法里逐个登记。
/// `XCTestObservationCenter` 在**每个**用例自己的 teardown 之后调一次 `testCaseDidFinish` —— 通过、
/// 断言失败、抛错都会调到，正好是 §1.2 要的那个时刻。
final class TestWindowJanitor: NSObject, XCTestObservation {

    static let shared = TestWindowJanitor()
    private static var installed = false

    @MainActor
    static func install() {
        guard !installed else { return }
        installed = true
        XCTestObservationCenter.shared.addTestObserver(shared)
        TestWindowMetrics.start()
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        let name = testCase.name
        if Thread.isMainThread {
            MainActor.assumeIsolated { TestWindows.flush(testName: name) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { TestWindows.flush(testName: name) } }
        }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { TestWindowMetrics.summary() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { TestWindowMetrics.summary() } }
        }
    }
}

/// 331 的度量：`NSApplication.shared.windows.filter(\.isVisible).count` 的**运行期间峰值**与
/// 每个用例结束后的计数。§2.1 / §2.2 的两个数字就是它打出来的。
///
/// 采样有两条路，因为窗口可能在一个用例里从「没有」到「可见」再到「关掉」而 RunLoop 一次都没转过：
/// 20 ms 的定时器（挂在 `.common` mode 上，`pump`/runloop 都能跑到），加上每一次造窗 / order / 收尾
/// 的即时采样。
@MainActor
enum TestWindowMetrics {

    private(set) static var peak = 0
    private(set) static var peakNote = "—"
    private(set) static var samples = 0
    private(set) static var afterTest = 0
    private(set) static var tests = 0
    /// 一共造了多少窗、order 了多少次 —— 「一跑就是好多窗口」的那个多数是这两个数，不是同时可见数。
    private(set) static var created = 0
    private(set) static var shown = 0

    private static var timer: Timer?

    static func visibleCount() -> Int {
        NSApplication.shared.windows.filter(\.isVisible).count
    }

    static func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated { TestWindowMetrics.sample("tick") }
        }
        RunLoop.main.add(timer, forMode: .common)
        TestWindowMetrics.timer = timer
    }

    static func noteCreated() { created += 1 }
    static func noteShown() { shown += 1 }

    static func sample(_ note: String) {
        samples += 1
        let count = visibleCount()
        if count > peak {
            peak = count
            peakNote = note
            print("[331] visible-window peak → \(count)   (\(note))")
        }
    }

    static func endOfTest(_ name: String) {
        tests += 1
        afterTest = visibleCount()
        print("[331] \(name) · visible windows after teardown = \(afterTest)")
    }

    static func summary() {
        timer?.invalidate()
        timer = nil
        print("[331] SUMMARY tests=\(tests) samples=\(samples) peak-visible=\(peak)"
              + " peak-at=\(peakNote) last-after-teardown=\(afterTest)"
              + " created=\(created) shown=\(shown)")
    }
}
