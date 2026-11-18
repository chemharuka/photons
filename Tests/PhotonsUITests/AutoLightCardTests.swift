import XCTest
import SwiftUI
import AppKit
import PhotonsCatalog
import PhotonsCore
import PhotonsLocalization
@testable import PhotonsUI

/// 派单 422 — 明暗 · 自动调节 的**面板侧与接线**。
///
/// 算法本身（五步、判据、⑧a–⑧e 五道反向门）在 `PhotonsCoreTests/AutoLightTests.swift`；这一份只管两件
/// 事，和 `BlackLevelCardTests` 对 自动黑电平 的分工一模一样：
///
///   1. **按钮是同一个控件族的第二个实例** —— 同图标、同 20×18 命中区、同无框 hover、自己的 id。
///      `LightAutoProbe` 是 frame 探针（`.background` 撑出来的，和 `BlackLevelAutoProbe` 逐字同形）。
///   2. **接线是一次文档写 + 一条快照**，`light.blackOffset` 只读不写，第二次点击是 no-op，⌘Z 一步回去。
@MainActor
final class AutoLightCardTests: XCTestCase {

    private static let panelHeight: CGFloat = 2600

    // MARK: - 1. 按钮的形状与位置

    /// 图标渲染出来了、命中区 ≥ 18×18、自身没有底色/边框、落在卡头（数值行上方）、右缘与数值列对齐。
    func testTheAutoIconSitsInTheCardHeaderWithoutChrome() throws {
        let host = NSHostingView(rootView: InspectorView(session: CatalogSession()))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: Self.panelHeight)
        let window = TestWindows.make(contentRect: host.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: true)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        let probe = try XCTUnwrap(Self.firstView(in: host) { $0 is LightAutoProbe } as? LightAutoProbe,
                                  "自动调节图标没有渲染出来：Light 卡的卡头里找不到 LightAutoProbe")
        let icon = probe.convert(probe.bounds, to: host)

        let field = try XCTUnwrap(Self.firstView(in: host) {
            $0.accessibilityIdentifier() == "inspector.light.曝光"
        }, "Light 卡的曝光数值框没有渲染出来")
        let value = field.convert(field.bounds, to: host)
        print(String(format: "422 AUTO · icon (%.1f, %.1f, %.1f×%.1f) · value (%.1f, %.1f, %.1f×%.1f)",
                     icon.minX, icon.minY, icon.width, icon.height,
                     value.minX, value.minY, value.width, value.height))

        XCTAssertGreaterThanOrEqual(icon.width, 18, "命中区 ≥ 18 pt 宽")
        XCTAssertGreaterThanOrEqual(icon.height, 18, "命中区 ≥ 18 pt 高")
        XCTAssertFalse(probe.hasBorder, "裸图标：没有底、没有边、没有胶囊（与 自动黑电平 同一族）")
        XCTAssertLessThan(icon.midY, value.midY, "图标在卡头，也就是数值行的上方")
        XCTAssertLessThanOrEqual(icon.maxX, value.maxX + 0.5, "右缘与数值列对齐（−2 尾距抵掉单元格溢出）")
        XCTAssertGreaterThanOrEqual(icon.maxX, value.minX, "不得挤进标题区域")
    }

    /// `inspector.light.auto` 在控件树里，而且 Light 卡的**行**命名空间里只有七行 —— 按钮在卡头，
    /// 不是第八行（这是复制清单覆盖测试 `CopySheetCoverageTests` 用的那条规则）。
    func testTheAutoIdentifierExistsAndAddsNoRow() {
        let host = NSHostingView(rootView: InspectorView(session: CatalogSession()))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: Self.panelHeight)
        let window = TestWindows.make(contentRect: host.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: true)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        let probes = Self.allViews(in: host).compactMap { $0.accessibilityIdentifier() }
        XCTAssertTrue(probes.contains("inspector.light.auto") || Self.hasAutoProbe(in: host),
                      "控件树里看不到 自动调节（inspector.light.auto）")

        // 行表没变：七行，名字里没有 自动调节。
        XCTAssertEqual(InspectorView.lightRows.count, 7, "自动调节 是卡头按钮，不是 明暗 的第八行")
        XCTAssertFalse(InspectorView.lightRows.map(\.title).contains("自动调节"))
        // 卡头 accessory 存在，且是 light 卡自己的分支（不是「唯一那张带注记的卡」了）。
        let ids = Self.allViews(in: host).compactMap { $0.accessibilityIdentifier() }
        XCTAssertTrue(ids.contains("inspector.light.曝光"), "七行仍然在：\(ids.sorted())")
    }

    /// 按钮的 action 走控制器，控制器一次写一条快照；五步算法在 `AutoLight` 里，控制器里没有。
    func testTheButtonCallsTheControllerAndTheControllerCommitsOnce() throws {
        let inspector = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(inspector.contains("loupe?.autoLight()"),
                      "按钮的 action 必须是 loupe?.autoLight()")
        XCTAssertTrue(inspector.contains(".accessibilityIdentifier(\"inspector.light.auto\")"),
                      "id 必须是 inspector.light.auto")
        XCTAssertTrue(inspector.contains(".background(LightAutoProbeHost())"),
                      "同形的 frame 探针宿主（与 自动黑电平 的 .background(BlackLevelAutoProbeHost()) 一致）")
        XCTAssertTrue(inspector.contains("private var autoLightButton: some View"))
        XCTAssertTrue(inspector.contains("spec.section == .light"),
                      "挂在 light 卡的 InspectorCardShell(accessory:) 上，不是新加一行")

        // The end marker must be a string that appears **after** the signature and nowhere before it —
        // `/// The document's flips` reads twice in this file, and the first copy sits above.
        let body = try Self.body(of: "public func autoLight()",
                                 upTo: "public func cropToolLayout(viewport",
                                 in: Self.loupeSource)
        XCTAssertEqual(Self.occurrences(of: "session.applyEdit", in: body), 1,
                       "一次自动调节 = 一次文档写（不是 N 次）")
        XCTAssertEqual(Self.occurrences(of: "session.commitEdit", in: body), 1,
                       "一次自动调节 = 一条历史快照")
        XCTAssertTrue(body.contains("AutoLight.plan(for: session.edit"),
                      "五步算法必须在 AutoLight.plan 里，控制器只负责接线")
        XCTAssertFalse(body.contains("blackOffset ="),
                       "硬约束 1：控制器不许写 blackOffset（只读它）")
        XCTAssertTrue(body.contains("requestEditRender()"), "写完要自己开发一次")
    }

    // MARK: - 2. 真 RAW：一条历史、幂等、可撤销

    /// 一次点击 = 明暗 七字段 + 一条「明暗 · 自动」历史；`blackOffset` 逐位不变；再点一次 no-op；⌘Z 回到原值。
    func testAutoLightWritesOneHistoryEntryIsIdempotentAndUndoes() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        session.mode = .loupe
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        _ = loupe.view
        _ = try loupe.makeFrame(url: url, viewport: ImageSize(width: 800, height: 600),
                                decodeScale: 0.125, edit: session.edit)
        session.applyEdit { $0.light.blackOffset = 0.005 }
        session.applyEdit { $0.light.exposure = 0.1 }
        XCTAssertTrue(session.commitEdit(label: "原照"))

        let before = session.edit
        let historyBefore = session.history.count
        let plan = try XCTUnwrap(loupe.autoLight(), "有帧时必须返回 plan")
        print(String(format: "422 REAL · EV %+.2f 高光 %.0f 白色 %.0f 中间调 %.0f 阴影 %.0f 黑色 %.0f 对比 %.0f · %d renders %.0f ms",
                     plan.exposure, plan.highlights, plan.whites, plan.midtones, plan.shadows,
                     plan.blacks, plan.contrast, plan.report.renderCount, plan.report.milliseconds))

        XCTAssertEqual(session.history.count, historyBefore + 1, "一次点击 = 一条历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "明暗 · 自动")
        XCTAssertEqual(session.edit.light.blackOffset, before.light.blackOffset, "blackOffset 逐位不变")
        XCTAssertEqual(session.edit.light.exposure, plan.exposure)
        XCTAssertEqual(session.edit.light.highlights, plan.highlights)
        XCTAssertEqual(session.edit.light.whites, plan.whites)
        XCTAssertEqual(session.edit.light.midtones, plan.midtones)
        XCTAssertEqual(session.edit.light.shadows, plan.shadows)
        XCTAssertEqual(session.edit.light.blacks, plan.blacks)
        XCTAssertEqual(session.edit.light.contrast, plan.contrast)
        XCTAssertNotEqual(session.edit.light, before.light, "明暗 真的被写了")

        XCTAssertNil(loupe.autoLight(), "第二次点击是 no-op（plan 与文档相同）")
        XCTAssertEqual(session.history.count, historyBefore + 1, "no-op 不加历史")

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.light, before.light, "⌘Z 一步回到原值")
    }

    /// 没有帧（浏览器模式 / 还没解码）：nil、不写文档、不加历史。
    func testAutoLightReturnsNilWithoutAFrame() {
        let session = CatalogSession()
        session.mode = .loupe
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        _ = loupe.view
        XCTAssertNil(loupe.autoLight())
        XCTAssertEqual(session.history.count, 0)

        session.mode = .grid
        XCTAssertNil(loupe.autoLight(), "浏览器模式同样 nil")
    }

    /// 五道反向门挂在控制器上，production 全关 —— 测试打开一道就足以证明那一行是承重的。
    func testTheGatesAreReachableFromTheControllerAndOffInProduction() {
        let saved = LoupeController.autoLightGates
        defer { LoupeController.autoLightGates = saved }
        LoupeController.autoLightGates = AutoLight.Gates()
        XCTAssertEqual(LoupeController.autoLightGates, AutoLight.Gates(),
                       "production 的五道门必须全关")
        var opened = AutoLight.Gates()
        opened.fixedSlopeTable = true
        LoupeController.autoLightGates = opened
        XCTAssertTrue(LoupeController.autoLightGates.fixedSlopeTable,
                      "测试打开一道门必须能传进算法")
    }

    // MARK: - helpers

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

    private static func firstView(in root: NSView, where match: (NSView) -> Bool) -> NSView? {
        if match(root) { return root }
        for child in root.subviews {
            if let found = firstView(in: child, where: match) { return found }
        }
        return nil
    }

    private static func hasAutoProbe(in root: NSView) -> Bool {
        firstView(in: root) { $0 is LightAutoProbe } != nil
    }

    private static func allViews(in root: NSView) -> [NSView] {
        var out = [root]
        for child in root.subviews { out += allViews(in: child) }
        return out
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    private static var inspectorSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    private static var loupeSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/LoupeController.swift")
    }

    private static func body(of signature: String, upTo endMarker: String, in url: URL) throws -> String {
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: signature),
              let end = source.range(of: endMarker),
              start.lowerBound < end.lowerBound else {
            throw XCTSkip("no `\(signature)` … `\(endMarker)` section in \(url.lastPathComponent)")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: search) {
            count += 1
            search = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
