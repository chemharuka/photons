import XCTest
import AppKit
import PhotonsUI

/// 窗口左上角三颗红绿灯的回归：它们是 **AppKit 自己的按钮**，背后必须是**系统材质**
/// （`NSVisualEffectView(.headerView, .behindWindow, .followsWindowActiveState)`），
/// 而不是一块不透明底板上的三个扁平圆点。
///
/// 这组断言全部来自真实窗口的实测值（`standardWindowButton` 的 frame、theme frame 的
/// 子视图次序、`hitTest` 的返回值、`cacheDisplay` 的像素 alpha），不是手算的期望值：
/// 「玻璃被底板架空」这件事只有像素能证明，按钮是不是系统的只有 hitTest 能证明。
@MainActor
final class NativeTrafficLightsTests: XCTestCase {

    /// 验收要求的两个窗口尺寸：常规 1600×940，以及 `WorkspaceLayout.minimumWindowSize`。
    private static let sizes: [NSSize] = [NSSize(width: 1600, height: 940),
                                          WorkspaceLayout.minimumWindowSize]

    // MARK: - harness

    private func pump(_ seconds: TimeInterval = 0.03) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// 真 `EditorWindowController` 的窗口，布局跑完两遍（第一遍量红绿灯位置，第二遍钉顶栏）。
    private func makeLive(_ size: NSSize) -> EditorWindowController {
        _ = NSApplication.shared
        let controller = EditorWindowController(size: size)
        guard let window = controller.window else {
            XCTFail("窗口没建出来")
            return controller
        }
        window.setContentSize(size)
        window.contentView?.layoutSubtreeIfNeeded()
        controller.rootView.layoutSubtreeIfNeeded()
        pump()
        controller.rootView.layoutSubtreeIfNeeded()
        controller.rootView.topBar.layoutSubtreeIfNeeded()
        return controller
    }

    /// 同 styleMask 的裸 `NSWindow`，只做对照：系统自己会把三颗按钮放在哪。
    private func makeBare(_ size: NSSize) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "Bare"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = WorkspaceLayout.minimumWindowSize
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private let buttonKinds: [(String, NSWindow.ButtonType)] = [("close", .closeButton),
                                                               ("mini", .miniaturizeButton),
                                                               ("zoom", .zoomButton)]

    /// 三颗按钮在**窗口坐标**里的框（右上角的 y 从窗口底边算起，所以 y 是个大数）。
    private func lightFrames(_ window: NSWindow) -> [(String, NSRect)] {
        buttonKinds.map { name, kind in
            guard let button = window.standardWindowButton(kind) else { return (name, .null) }
            return (name, button.convert(button.bounds, to: nil))
        }
    }

    private func fmt(_ r: NSRect) -> String {
        String(format: "x %7.2f  y %7.2f  w %5.2f  h %5.2f", r.minX, r.minY, r.width, r.height)
    }

    /// `view` 上某点（`view` 自己的坐标，flipped/非 flipped 都行）的像素 alpha。
    /// 用来证明「顶栏那条自己画的底板没了」——底板是 0.96 alpha 的纯色，玻璃是 0。
    private func alpha(of view: NSView, at point: NSPoint) -> CGFloat? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = view.bounds.width > 0 ? CGFloat(rep.pixelsWide) / view.bounds.width : 1
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
        return rep.colorAt(x: x, y: y)?.alphaComponent
    }

    /// 顶栏里那块材质：最底层、铺满顶层那条带的 `NSVisualEffectView`。
    private func headerGlass(in root: WorkspaceRootView) -> NSVisualEffectView? {
        root.subviews.compactMap { $0 as? NSVisualEffectView }.first { view in
            view.material == .headerView
        }
    }

    private func isOurs(_ view: NSView?, root: NSView) -> Bool {
        guard let view else { return false }
        var node: NSView? = view
        while let current = node {
            if current === root { return true }
            node = current.superview
        }
        return false
    }

    // MARK: - 1 · 红绿灯 frame 与裸窗口逐项相同

    func testTrafficLightFramesMatchABareWindow() {
        for size in Self.sizes {
            let controller = makeLive(size)
            guard let window = controller.window else { return XCTFail("no window") }
            defer { window.orderOut(nil) }
            let bare = makeBare(size)
            defer { bare.orderOut(nil) }

            print("\n=== \(Int(size.width))×\(Int(size.height)) ===")
            print("live window frame   \(NSStringFromRect(window.frame))  content \(Int(window.contentLayoutRect.width))×\(Int(window.contentLayoutRect.height))")
            print("bare window frame   \(NSStringFromRect(bare.frame))")

            let ours = lightFrames(window)
            let reference = lightFrames(bare)
            for (lhs, rhs) in zip(ours, reference) {
                print("\(lhs.0.padding(toLength: 6, withPad: " ", startingAt: 0)) ours \(fmt(lhs.1))  bare \(fmt(rhs.1))")
                XCTAssertEqual(lhs.1.minX, rhs.1.minX, accuracy: 0.001, "\(lhs.0) x @\(size)")
                XCTAssertEqual(lhs.1.minY, rhs.1.minY, accuracy: 0.001, "\(lhs.0) y @\(size)")
                XCTAssertEqual(lhs.1.width, rhs.1.width, accuracy: 0.001, "\(lhs.0) w @\(size)")
                XCTAssertEqual(lhs.1.height, rhs.1.height, accuracy: 0.001, "\(lhs.0) h @\(size)")
            }

            // 三颗按钮的纵向中心就在标题栏那条上（窗口上边缘往下 ~16 pt）；顶栏的 36 pt 条
            // 跟着它走（`WorkspaceLayout.resolve(trafficLightCentreY:)`），容差用 `--ui-smoke`
            // 的同一条 ±4 pt 契约，不是新数字。
            if let close = ours.first(where: { $0.0 == "close" })?.1 {
                let centre = window.frame.height - close.midY
                let bar = controller.rootView.geometry.topBar
                print("light centre from top \(centre)  topBar.midY \(bar.midY)")
                XCTAssertEqual(bar.midY, centre, accuracy: 4.0, "顶栏没跟着红绿灯走 @\(size)")
            }
        }
    }

    // MARK: - 2 · 层级：玻璃在最底层，红绿灯之上没有我们加的不透明视图

    func testHeaderIsSystemGlassUnderTheButtons() {
        for size in Self.sizes {
            let controller = makeLive(size)
            guard let window = controller.window, let root = controller.rootView else {
                return XCTFail("no window")
            }
            defer { window.orderOut(nil) }
            let band = NSRect(x: 0, y: 0, width: root.bounds.width,
                              height: root.geometry.topBar.maxY)

            print("\n=== \(Int(size.width))×\(Int(size.height)) ===")
            print("top bar band (root, flipped) \(NSStringFromRect(band))")

            // ① 材质：.headerView / .behindWindow / followsWindowActiveState，且在最底层。
            guard let glass = headerGlass(in: root) else {
                let inventory = root.subviews.map { "\(type(of: $0)) \(NSStringFromRect($0.frame))" }
                return XCTFail("顶栏没有 .headerView 材质：\(inventory)")
            }
            print("glass \(type(of: glass)) material \(glass.material.rawValue)"
                  + " blending \(glass.blendingMode.rawValue) state \(glass.state.rawValue)"
                  + " frame \(NSStringFromRect(glass.frame))")
            XCTAssertEqual(glass.material, .headerView)
            XCTAssertEqual(glass.blendingMode, .behindWindow)
            XCTAssertEqual(glass.state, .followsWindowActiveState)
            XCTAssertTrue(root.subviews.first === glass, "玻璃不是最底层子视图")
            XCTAssertEqual(glass.frame.minX, band.minX, accuracy: 0.001)
            XCTAssertEqual(glass.frame.minY, band.minY, accuracy: 0.001)
            XCTAssertEqual(glass.frame.width, band.width, accuracy: 0.001)
            XCTAssertEqual(glass.frame.height, band.height, accuracy: 0.001)

            // ② 自下而上的子视图清单：玻璃之上，谁在这条带里不透明？
            print("root.subviews bottom → top:")
            for (index, view) in root.subviews.enumerated() {
                let intersects = view.frame.intersects(band)
                let colour = view.layer?.backgroundColor
                    .map { NSColor(cgColor: $0)?.alphaComponent ?? -1 } ?? -1
                print(String(format: "  [%d] %-22@ %@  isOpaque %@  layerAlpha %.2f  inBand %@",
                             index, "\(type(of: view))" as NSString, NSStringFromRect(view.frame),
                             "\(view.isOpaque)" as NSString, colour, "\(intersects)" as NSString))
                guard intersects, index > 0 else { continue }
                let opaquePlate = view.isOpaque && colour >= 0.999
                XCTAssertFalse(opaquePlate,
                               "\(type(of: view)) 是不透明底板，压住了顶栏的玻璃")
            }

            // ③ 顶栏自己的画：只允许 1 pt 分隔线，不许整块填色。像素 alpha 是硬证据。
            let bar = root.topBar
            if let a = alpha(of: bar, at: NSPoint(x: 700, y: 18)) {
                print(String(format: "topBar pixel alpha @(700,18) %.3f  (opaque plate would be 0.96)", a))
                XCTAssertLessThan(a, 0.02, "顶栏还在画不透明底板（alpha \(a)）")
            } else {
                XCTFail("顶栏渲染不出像素")
            }

            // ④ 红绿灯在我们之上：AppKit 把 contentView 放在 titlebar 之下，我们只活在 contentView 里。
            if let themeFrame = root.superview {
                print("theme frame subviews: \(themeFrame.subviews.map { "\(type(of: $0))" })")
                let contentIndex = themeFrame.subviews.firstIndex { $0 === root } ?? -1
                // 红绿灯挂在哪个 theme-frame 子视图里：沿 close 按钮的祖先链往上走，最后一级。
                var branch: NSView? = window.standardWindowButton(.closeButton)
                while let node = branch, node.superview !== themeFrame { branch = node.superview }
                let closeHost = branch
                let closeHostIndex = closeHost.flatMap { host in
                    themeFrame.subviews.firstIndex { $0 === host }
                } ?? -1
                print("contentView index \(contentIndex)"
                      + "  traffic-light branch \(closeHost.map { "\(type(of: $0))" } ?? "nil")"
                      + " index \(closeHostIndex)")
                XCTAssertGreaterThan(closeHostIndex, contentIndex,
                                     "红绿灯所在的 titlebar 不在 contentView 之上")
                XCTAssertFalse(themeFrame.subviews.contains { $0 === glass })
            }
        }
    }

    // MARK: - 3 · 命中：红绿灯中心点是系统按钮，不是我们的视图

    func testHitTestAtTheLightCentreLandsOnTheSystemButton() {
        for size in Self.sizes {
            let controller = makeLive(size)
            guard let window = controller.window, let root = controller.rootView else {
                return XCTFail("no window")
            }
            defer { window.orderOut(nil) }
            guard let themeFrame = root.superview else { return XCTFail("no theme frame") }

            for (name, kind) in buttonKinds {
                guard let button = window.standardWindowButton(kind) else {
                    XCTFail("\(name) 按钮不存在")
                    continue
                }
                let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY),
                                           to: themeFrame)
                let hit = themeFrame.hitTest(point)
                print("\(name) centre \(NSStringFromPoint(point)) → \(hit.map { "\(type(of: $0))" } ?? "nil")")
                XCTAssertTrue(hit === button, "\(name) 中心点没命中按钮本身")
                XCTAssertFalse(isOurs(hit, root: root), "\(name) 中心点被我们自己的视图盖住了")

                // 三颗按钮的框必须落在玻璃那条带里：玻璃是它们的背景，而不是旁边的装饰。
                let inRoot = button.convert(button.bounds, to: root)
                print("\(name) frame in root \(NSStringFromRect(inRoot))"
                      + " ∩ glass \(NSStringFromRect(inRoot.intersection(root.headerGlass.frame)))")
                XCTAssertEqual(inRoot.intersection(root.headerGlass.frame), inRoot,
                               "\(name) 不在玻璃上：玻璃没盖住红绿灯")
            }

            // 玻璃自己不接事件，否则它会从标题栏那里抢走点击/拖动。
            XCTAssertNil(root.headerGlass.hitTest(NSPoint(x: 4, y: 4)), "玻璃抢了点击")
            XCTAssertNil(root.headerGlass.hitTest(NSPoint(x: 700, y: 18)), "玻璃抢了点击")

            // 反向：顶栏的控件照样拿得到自己的点击（空白让给窗口 ≠ 控件也让出去）。
            for control in root.topBar.subviews where control.isHidden == false && !control.frame.isEmpty {
                let centre = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY),
                                             to: themeFrame)
                let hit = themeFrame.hitTest(centre)
                print("control \(type(of: control)) centre → \(hit.map { "\(type(of: $0))" } ?? "nil")")
                XCTAssertTrue(isOurs(hit, root: control), "顶栏控件 \(type(of: control)) 的点击没到自己手里")
            }

            // 顶栏空白处：命中必须落在 AppKit 的窗体（titlebar / theme frame）上，不是我们的视图，
            // 否则窗口既拖不动、点下去也没人接。拖动契约仍是「只有顶栏那条能拖」。
            XCTAssertFalse(window.isMovableByWindowBackground)
            for local in [NSPoint(x: 700, y: 8), NSPoint(x: root.bounds.width - 40, y: 8),
                          NSPoint(x: root.bounds.width / 2, y: 6)] {
                let point = root.convert(local, to: themeFrame)
                let hit = themeFrame.hitTest(point)
                print("blank @\(NSStringFromPoint(local)) → \(hit.map { "\(type(of: $0))" } ?? "nil")"
                      + "  mouseDownCanMoveWindow \(hit?.mouseDownCanMoveWindow.description ?? "n/a")")
                XCTAssertFalse(isOurs(hit, root: root), "顶栏空白处被我们自己的视图接走了")
                XCTAssertNotNil(hit, "顶栏空白处没人接：窗口拖不动")
            }
        }
    }

    // MARK: - 4 · 明暗外观：玻璃参数不写死

    func testGlassDoesNotDependOnAppearance() {
        var seen: [(String, Int, Int, Int, NSRect)] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            _ = NSApplication.shared
            let controller = makeLive(NSSize(width: 1600, height: 940))
            guard let window = controller.window, let root = controller.rootView else {
                return XCTFail("no window")
            }
            defer { window.orderOut(nil) }
            window.appearance = NSAppearance(named: name)
            root.layoutSubtreeIfNeeded()
            root.topBar.needsDisplay = true
            pump()

            guard let glass = headerGlass(in: root) else {
                return XCTFail("\(name.rawValue): 顶栏没有 .headerView 材质")
            }
            print("\(name.rawValue): glass material \(glass.material.rawValue)"
                  + " blending \(glass.blendingMode.rawValue) state \(glass.state.rawValue)"
                  + " effectiveAppearance \(glass.effectiveAppearance.name.rawValue)"
                  + " frame \(NSStringFromRect(glass.frame))")
            XCTAssertEqual(glass.material, .headerView, name.rawValue)
            XCTAssertEqual(glass.blendingMode, .behindWindow, name.rawValue)
            XCTAssertEqual(glass.state, .followsWindowActiveState, name.rawValue)
            // 材质视图拿到的是外观的 **vibrant** 变体（NSAppearanceNameVibrantLight/Dark）——这正是
            // 「材质自己跟外观走」的证据，所以比的是 family（bestMatch），不是字面名字。
            XCTAssertEqual(glass.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name,
                           "玻璃没跟着外观走：\(glass.effectiveAppearance.name.rawValue)")

            if let a = alpha(of: root.topBar, at: NSPoint(x: 700, y: 18)) {
                print(String(format: "%@: topBar pixel alpha %.3f", name.rawValue, a))
                XCTAssertLessThan(a, 0.02, "\(name.rawValue): 顶栏还在画不透明底板")
            }
            seen.append((name.rawValue, glass.material.rawValue, glass.blendingMode.rawValue,
                         glass.state.rawValue, glass.frame))
            window.appearance = nil
        }
        XCTAssertEqual(seen.count, 2)
        if seen.count == 2 {
            XCTAssertEqual(seen[0].1, seen[1].1, "材质数值随外观变了")
            XCTAssertEqual(seen[0].2, seen[1].2, "blending 随外观变了")
            XCTAssertEqual(seen[0].3, seen[1].3, "state 随外观变了")
            XCTAssertEqual(seen[0].4, seen[1].4, "玻璃 frame 随外观变了")
        }
    }

    // MARK: - 5 · 顶栏其它内容一个点都不动

    func testTopBarContentsKeepTheirFrames() {
        for size in Self.sizes {
            let controller = makeLive(size)
            guard let window = controller.window, let root = controller.rootView else {
                return XCTFail("no window")
            }
            defer { window.orderOut(nil) }
            let bar = root.topBar

            print("\n=== \(Int(size.width))×\(Int(size.height)) ===")
            print("contentLeading \(bar.contentLeading)  controlsTrailingEdge \(bar.controlsTrailingEdge)")
            // 88 = trafficLightsWidth 78 + 10：顶栏内容从红绿灯右边 10 pt 开始。
            XCTAssertEqual(bar.contentLeading, WorkspaceLayout.trafficLightsWidth + 10, accuracy: 0.001)
            for view in bar.subviews {
                print("  \(type(of: view)) \(NSStringFromRect(view.frame)) hidden \(view.isHidden)")
            }
            // 固定基线（改前实测）：第一个控件 x = 88，状态簇右边缘 = 窗口右边 − 16。
            if let firstButton = bar.subviews.first(where: { $0 is NSButton }) {
                XCTAssertEqual(firstButton.frame.minX, 88, accuracy: 0.001)
            } else {
                XCTFail("顶栏里没有按钮")
            }
            XCTAssertEqual(bar.statusCluster.frame.maxX,
                           bar.bounds.width - TopBarStatusCluster.Metrics.trailingInset,
                           accuracy: 0.001)
        }
    }
}

// MARK: - small helper

extension NSView {
    /// 第一个 `T` 类型的后代（含自身），只给层级断言用。
    func findDescendant<T: NSView>(_ type: T.Type) -> T? {
        if let self = self as? T { return self }
        for child in subviews {
            if let found = child.findDescendant(type) { return found }
        }
        return nil
    }
}
