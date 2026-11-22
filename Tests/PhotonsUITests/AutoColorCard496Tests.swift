import XCTest
import SwiftUI
import AppKit
import PhotonsCatalog
import PhotonsCore
import PhotonsLocalization
@testable import PhotonsUI

/// 派单 496 — 「色彩」卡的 自动颜色 图标按钮。
///
/// 算法与两个入口（右键「自动颜色」、顶栏「全部自动」）在 490 已经存在；这一份只管**第三个入口**
/// 和它与前两个的同源性：
///
///   1. 按钮是 422 那个 wand 家族的第三个实例：同图标、同 20×18 命中区、同无框 hover、自己的 id。
///      同一个 `LightAutoProbe` 探针因此渲染两次（Light 卡与 Color 卡各一次），测试按「探针在
///      自己那张卡的第一行上方」分辨它们。
///   2. 点击走 `loupe.autoColor()`：只写 `color.vibrance`、一条「自动颜色」历史；收敛后再点是 no-op。
///   3. 等待全档解码时按钮禁用且 help 是「等待解码…」；没有 loupe 时禁用而不是隐藏。
///   4. 与右键入口同源：两条路径在同一张图上给出同一个 vibrance。
@MainActor
final class AutoColorCard496Tests: XCTestCase {

    private static let panelHeight: CGFloat = 2600
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        AutoColorButtonLog.shared.reset()
    }

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - fixtures

    private func rawFixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    @discardableResult
    private func host(_ view: InspectorView) -> NSHostingView<InspectorView> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 330, height: Self.panelHeight)
        let window = TestWindows.make(contentRect: host.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: true)
        window.contentView = host
        windows.append(window)
        TestWindows.show(window, key: true)
        host.layoutSubtreeIfNeeded()
        pump(0.05)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func makeController(url: URL, identity: String,
                                session: CatalogSession) throws -> LoupeController {
        session.mode = .loupe
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        _ = loupe.view
        _ = try loupe.makeFrame(url: url, viewport: ImageSize(width: 800, height: 600),
                                decodeScale: 0.125, edit: session.edit)
        return loupe
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - ① 结构与几何：与 Light 卡的 自动调节 同尺寸、右缘贴值列

    func testTheColorIconSitsInTheCardHeaderWithTheLightIconGeometry() throws {
        let host = host(InspectorView(session: CatalogSession()))

        let probes = Self.allViews(in: host).compactMap { $0 as? LightAutoProbe }
        XCTAssertEqual(probes.count, 2, "wand 家族应有两只探针：明暗卡与色彩卡")

        let colorProbe = try XCTUnwrap(Self.colorProbe(in: host, probes: probes),
                                       "色彩卡头里找不到 wand 探针")
        let lightProbe = try XCTUnwrap(Self.lightProbe(in: host, probes: probes),
                                       "明暗卡头里找不到 wand 探针")
        XCTAssertFalse(colorProbe === lightProbe, "两只探针必须是两个实例")

        let colorField = try XCTUnwrap(Self.view(in: host, id: "inspector.color.自然饱和"),
                                       "色彩卡的第一行没有渲染出来")
        let colorIcon = colorProbe.convert(colorProbe.bounds, to: host)
        let lightIcon = lightProbe.convert(lightProbe.bounds, to: host)
        let value = colorField.convert(colorField.bounds, to: host)
        print(String(format: "496 AUTO · color (%.1f, %.1f, %.1f×%.1f) · light (%.1f, %.1f, %.1f×%.1f) · value maxX %.1f",
                     colorIcon.minX, colorIcon.minY, colorIcon.width, colorIcon.height,
                     lightIcon.minX, lightIcon.minY, lightIcon.width, lightIcon.height, value.maxX))

        XCTAssertEqual(colorIcon.width, lightIcon.width, accuracy: 0.01, "宽度与 自动调节 同尺寸")
        XCTAssertEqual(colorIcon.height, lightIcon.height, accuracy: 0.01, "高度与 自动调节 同尺寸")
        XCTAssertGreaterThanOrEqual(colorIcon.width, 18, "命中区 ≥ 18 pt 宽")
        XCTAssertGreaterThanOrEqual(colorIcon.height, 18, "命中区 ≥ 18 pt 高")
        XCTAssertFalse(colorProbe.hasBorder, "裸图标：没有底、没有边、没有胶囊（同一族）")
        XCTAssertLessThan(colorIcon.midY, value.midY, "图标在卡头，也就是数值行的上方")
        XCTAssertLessThanOrEqual(abs(colorIcon.maxX - value.maxX), 0.5,
                                 "右缘与值列右边对齐（−2 尾距抵掉单元格溢出）")
        XCTAssertGreaterThanOrEqual(colorIcon.maxX, value.minX, "不得挤进标题区域")

        let ids = Self.allViews(in: host).compactMap { $0.accessibilityIdentifier() }
        XCTAssertTrue(ids.contains("inspector.color.自然饱和"), "色彩卡的两行仍然在")
        XCTAssertEqual(InspectorView.colorRows.count, 2, "自动颜色 是卡头按钮，不是色彩卡的第三行")
        XCTAssertFalse(InspectorView.colorRows.map(\.title).contains("自动颜色"))

        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"inspector.color.auto\")"),
                      "控件树的 id 必须是 inspector.color.auto")
        XCTAssertTrue(source.contains("private var autoColorButton: some View"))
        XCTAssertTrue(source.contains("spec.section == .color"),
                      "挂在色彩卡的 accessory 上，不是新加一行")
    }

    /// 分离面板 / 没有 loupe：按钮仍在，但是灰的（不是消失）。
    func testTheColorButtonIsDisabledWithoutALoupe() throws {
        let host = host(InspectorView(session: CatalogSession()))
        XCTAssertNotNil(Self.colorProbe(in: host, probes: Self.allViews(in: host).compactMap { $0 as? LightAutoProbe }),
                        "没有 loupe 时按钮必须仍然画出来（只是禁用）")
        let state = AutoColorButtonLog.shared.state
        print("496 ① nil loupe · enabled=\(state.enabled) help=\(state.help)")
        XCTAssertFalse(state.enabled, "没有 loupe 时按钮必须禁用而不是隐藏")
        XCTAssertEqual(state.help, Loc.t("自动颜色：按画面的色度分布安排自然饱和（只加不减）"))
    }

    // MARK: - ② 接线：一次文档写、一条历史、幂等

    func testClickingWritesOnlyVibranceOneHistoryAndIsIdempotent() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = try makeController(url: url, identity: "496-click", session: session)

        session.applyEdit { $0.color.vibrance = -20 }
        XCTAssertTrue(session.commitEdit(label: "原照"))
        let before = session.edit
        let historyBefore = session.history.count

        let host = host(InspectorView(session: session, loupe: loupe))
        let probe = try XCTUnwrap(Self.colorProbe(in: host,
                                                 probes: Self.allViews(in: host).compactMap { $0 as? LightAutoProbe }))
        XCTAssertTrue(AutoColorButtonLog.shared.state.enabled, "有 loupe、不在等解码时按钮可点")

        // The plan is measured before the click so the assertion is about the wiring, not a re-derivation.
        let expected = try XCTUnwrap(loupe.colorVibranceCandidate(), "the fixture must move vibrance")
        Self.click(probe, in: host)
        pump(0.05)

        XCTAssertEqual(session.edit.color.vibrance, expected, "vibrance = 同一个 plan")
        XCTAssertEqual(session.edit.color.saturation, before.color.saturation, "saturation 不变")
        XCTAssertEqual(session.edit.light, before.light, "明暗不受影响")
        XCTAssertEqual(session.history.count, historyBefore + 1, "一次点击 = 一条历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "自动颜色")

        let settled = session.edit
        Self.click(probe, in: host)
        pump(0.05)
        XCTAssertEqual(session.edit, settled, "收敛后再点是 no-op（文档不变）")
        XCTAssertEqual(session.history.count, historyBefore + 1, "no-op 不加历史")
    }

    /// 右键入口 / 全部自动 与本按钮走同一条 `autoColor()`：同一张图、中间撤销，值逐位相同。
    func testTheIconAndTheRightClickVerbAgree() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = try makeController(url: url, identity: "496-same-source", session: session)

        session.applyEdit { $0.color.vibrance = -20 }
        XCTAssertTrue(session.commitEdit(label: "原照"))
        let before = session.edit

        // The right-click row's own target method, with the loupe's own verb — what the menu installs.
        var routed = false
        let target = AutoAdjustMenuTarget(session: session, performColor: {
            routed = true
            _ = loupe.autoColor()
        })
        target.autoColorPressed(nil)
        XCTAssertTrue(routed, "右键「自动颜色」没有走到 loupe.autoColor()")
        let menuValue = session.edit.color.vibrance
        XCTAssertEqual(menuValue, try XCTUnwrap(loupe.lastAutoColorMetricsForTesting.map { AutoColor.plan($0) }),
                       "右键入口给出的值就是 AutoColor.plan")
        XCTAssertEqual(session.history.currentSnapshot?.label, "自动颜色")
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit, before, "撤销回到起点")

        let host = host(InspectorView(session: session, loupe: loupe))
        let probe = try XCTUnwrap(Self.colorProbe(in: host,
                                                 probes: Self.allViews(in: host).compactMap { $0 as? LightAutoProbe }))
        Self.click(probe, in: host)
        pump(0.05)

        XCTAssertEqual(session.edit.color.vibrance, menuValue,
                       "两个入口必须是同一套 plan（不许有第二套）")
        XCTAssertEqual(session.edit.color.saturation, before.color.saturation)
    }

    // MARK: - ③ 等待解码：禁用 + help

    func testWaitingForDecodeDisablesTheButtonAndSaysSo() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = try makeController(url: url, identity: "496-wait", session: session)
        let host = host(InspectorView(session: session, loupe: loupe))
        pump(0.05)

        let available = AutoColorButtonLog.shared.state
        XCTAssertTrue(available.enabled)
        XCTAssertEqual(available.help, Loc.t("自动颜色：按画面的色度分布安排自然饱和（只加不减）"))

        loupe.autoAdjustWait.isWaitingForDecode = true
        pump(0.05)
        host.layoutSubtreeIfNeeded()

        let waiting = AutoColorButtonLog.shared.state
        print("496 ③ waiting · enabled=\(waiting.enabled) help=\(waiting.help)")
        XCTAssertFalse(waiting.enabled, "等待全档解码时必须禁用")
        XCTAssertEqual(waiting.help, "等待解码…", "等待时的 help 必须说明原因")

        loupe.autoAdjustWait.isWaitingForDecode = false
        pump(0.05)
        host.layoutSubtreeIfNeeded()
        let resumed = AutoColorButtonLog.shared.state
        XCTAssertTrue(resumed.enabled)
        XCTAssertEqual(resumed.help, Loc.t("自动颜色：按画面的色度分布安排自然饱和（只加不减）"))
    }

    // MARK: - helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    private static var inspectorSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    private static func allViews(in root: NSView) -> [NSView] {
        var out = [root]
        for child in root.subviews { out += allViews(in: child) }
        return out
    }

    private static func view(in root: NSView, id: String) -> NSView? {
        allViews(in: root).first { $0.accessibilityIdentifier() == id }
    }

    /// The color card's wand probe: the one directly above 自然饱和.
    private static func colorProbe(in host: NSView, probes: [LightAutoProbe]) -> LightAutoProbe? {
        guard let field = view(in: host, id: "inspector.color.自然饱和") else { return nil }
        return probe(above: field, in: host, probes: probes)
    }

    /// The Light card's wand probe: the one directly above 曝光.
    private static func lightProbe(in host: NSView, probes: [LightAutoProbe]) -> LightAutoProbe? {
        guard let field = view(in: host, id: "inspector.light.曝光") else { return nil }
        return probe(above: field, in: host, probes: probes)
    }

    /// The wand probe in the header directly above `field` — smallest absolute vertical gap.
    private static func probe(above field: NSView, in host: NSView,
                              probes: [LightAutoProbe]) -> LightAutoProbe? {
        let value = field.convert(field.bounds, to: host)
        return probes.min { lhs, rhs in
            let a = lhs.convert(lhs.bounds, to: host)
            let b = rhs.convert(rhs.bounds, to: host)
            return abs(value.minY - a.maxY) < abs(value.minY - b.maxY)
        }
    }

    /// A real click on whatever the SwiftUI button landed as: the wand host view is not an `NSButton`,
    /// so drive the window's own hit test at the probe's centre (`CropAspectOrientationTests`' path).
    private static func click(_ probe: NSView, in host: NSView) {
        guard let window = host.window else { return }
        let point = probe.convert(CGPoint(x: probe.bounds.midX, y: probe.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            window.sendEvent(event)
        }
    }
}
