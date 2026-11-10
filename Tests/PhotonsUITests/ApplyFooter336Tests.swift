import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 336 — **变换的「应用 / 取消」做大，固定在右栏右下角，不随卡片滚动而变。**
///
/// 用户的口径（2026-11-10）：
///
///   > 变换的"应用" "取消" 做大一些，放在右侧栏的右下方，不随卡片滚动而变。
///
/// 336 之前：`CropApplyRow` 是**裁切卡的最后一行**（334 排到卡内 minY 479），两个 `.mini`
/// bordered 按钮实测 34×13，跟着卡片一起滚。
///
/// 336 之后：`CropApplyFooter` 是**面板的固定页脚** —— `InspectorView.body` 里与 `ScrollView` 并列，
/// 只在变换工作区出现。这份文件量的是真实宿主窗口里排过版的那一条：
///
///   ① 每个按钮 ≥ 60×22；两钮同一水平线（midY 差 ≤0.5）、间距 ≥8；
///      （339：用户说 `.large` 太大不协调，退到 `.regular` 60×22 —— 仍是原来 `.mini` 34×13 的近两倍。）
///   ② `应用`.maxX == 检查器内容右沿 − 16（±0.5），页脚底 == 检查器底边 − 12（±0.5）；
///   ③ 滚到顶 / 滚到底 / 再滚 200 pt：两个按钮的 frame 三次**完全相同**（Δ≤0.5），
///      而同一次滚动里卡内「拉直」行的 y 确实变了（证明滚动真的发生）；
///   ④ 裁切卡的行集合**不含** `apply`；页脚与两颗按钮的 `enclosingScrollView == nil`，
///      卡片里的行都有（判据：SwiftUI 的 `ScrollView` 在 macOS 上就是 `NSScrollView`）；
///   ⑤ 非变换工作区（「光」）页脚不存在：`apply` / `footer` 探针命中 0。
///
/// id 与探针标题沿用 086/334（`inspector.crop.apply` / `inspector.crop.cancel`、
/// `裁切.应用` / `裁切.取消`），语义不变。
@MainActor
final class ApplyFooter336Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-336-footer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - ①② 尺寸与位置

    func testTheTwoButtonsAreAtLeast60By22InTheBottomRightCorner() throws {
        let (panel, _) = try transformPanel(width: 330, height: 900)
        defer { panel.window.contentView = nil }

        let apply = try XCTUnwrap(panel.row(CropApplyRow.applyButtonProbe), "「应用」没有画出来")
        let cancel = try XCTUnwrap(panel.row(CropApplyRow.cancelButtonProbe), "「取消」没有画出来")
        let row = try XCTUnwrap(panel.row(CropApplyRow.probeID), "页脚里的按钮行没有画出来")
        let footer = try XCTUnwrap(panel.row(CropApplyFooter.probeID), "页脚容器没有画出来")
        print(String(format: "336 ① · 应用 %.2f×%.2f · 取消 %.2f×%.2f（改前 .mini = 34×13）",
                     apply.width, apply.height, cancel.width, cancel.height))

        // ① 尺寸：每个按钮 ≥ 60×22（339 从 72×26 收小）. 
        for (name, rect) in [("应用", apply), ("取消", cancel)] {
            XCTAssertGreaterThanOrEqual(rect.width, CropApplyRow.minSize.width - 0.5,
                                        "336: 「\(name)」只有 \(rect.width) pt 宽（< 60）")
            XCTAssertGreaterThanOrEqual(rect.height, CropApplyRow.minSize.height - 0.5,
                                        "336: 「\(name)」只有 \(rect.height) pt 高（< 22）")
        }
        // 间距 ≥ 8，同一水平线.
        let gap = apply.minX - cancel.maxX
        XCTAssertGreaterThanOrEqual(gap, 8 - 0.5, "336: 两钮间距只有 \(gap) pt（< 8）")
        XCTAssertLessThanOrEqual(abs(apply.midY - cancel.midY), 0.5,
                                 "336: 两钮不在一条水平线上（midY \(apply.midY) / \(cancel.midY)）")
        // 应用在右、取消在其左（§2.1 的默认排法）.
        XCTAssertGreaterThan(apply.minX, cancel.minX, "336: 「应用」应在「取消」右侧")

        // ② 位置：右沿 − 16（相对检查器**内容**右沿 = 面板宽 − 12 的列内缩），底边 − 12.
        let panelWidth = panel.host.bounds.width
        let contentRight = panelWidth - CropApplyFooter.columnInset
        XCTAssertEqual(apply.maxX, contentRight - CropApplyFooter.trailingInset, accuracy: 0.5,
                       "336: 「应用」右沿 \(apply.maxX) ≠ 内容右沿 \(contentRight) − 16")
        XCTAssertEqual(panel.host.bounds.maxY - row.maxY, CropApplyFooter.bottomInset, accuracy: 0.5,
                       "336: 页脚底 \(row.maxY) ≠ 检查器底边 \(panel.host.bounds.maxY) − 12")
        // 页脚容器（算上它自己的 padding）就是面板底边，右边顶到面板边.
        XCTAssertEqual(footer.maxY, panel.host.bounds.maxY, accuracy: 0.5,
                       "336: 页脚容器底边 \(footer.maxY) ≠ 面板底边 \(panel.host.bounds.maxY)")
        XCTAssertEqual(footer.maxX, panelWidth, accuracy: 0.5)
        // 上方的 10 pt 是面板列自己的节奏：页脚顶 = 滚动区底 + 10.
        let scroll = try XCTUnwrap(panel.scrollView, "检查器的 ScrollView 不是 NSScrollView")
        let viewport = scroll.convert(scroll.bounds, to: panel.host)
        let above = footer.minY - viewport.maxY
        XCTAssertGreaterThanOrEqual(above, 10 - 0.5, "336: 页脚上方的间距只有 \(above) pt（< 10）")
        XCTAssertLessThanOrEqual(above, 12 + 0.5, "336: 页脚上方的间距 \(above) pt（> 12）")
        print(String(format: "336 ② · 应用 maxX %.1f（内容右沿 %.1f − 16）· 页脚底 %.1f（底边 %.1f − 12）"
                     + " · 上方间距 %.1f · 两钮间距 %.1f · midY %.1f / %.1f",
                     apply.maxX, contentRight, row.maxY, panel.host.bounds.maxY,
                     above, gap, apply.midY, cancel.midY))
    }

    // MARK: - ③ 不随滚动

    /// 520 pt 高的面板：三张卡一共 578 pt，视口只有 ~180 pt，所以「滚到底」是真的移动。
    func testTheFooterStaysPutWhileTheCardsScrollToTopBottomAndPlus200() throws {
        let (panel, _) = try transformPanel(width: 330, height: 520)
        defer { panel.window.contentView = nil }

        let scroll = try XCTUnwrap(panel.scrollView, "检查器的 ScrollView 不是 NSScrollView")
        let document = scroll.documentView?.bounds.height ?? 0
        let viewport = scroll.contentView.bounds.height
        XCTAssertGreaterThan(document, viewport + 200,
                             "336: 这道门需要一个真能滚 200 pt 的文档（\(document) vs \(viewport)）")

        let applyID = CropApplyRow.applyButtonProbe
        let cancelID = CropApplyRow.cancelButtonProbe
        let straightenID = CorrectionCardRow.straighten.probeID

        func snapshot(_ label: String) throws -> (apply: CGRect, cancel: CGRect, straighten: CGFloat) {
            let apply = try XCTUnwrap(panel.row(applyID))
            let cancel = try XCTUnwrap(panel.row(cancelID))
            let straighten = try XCTUnwrap(panel.row(straightenID), "卡内「拉直」行没有画出来")
            print(String(format: "336 ③ · %@ offset %.1f → 应用 %@ · 取消 %@ · 拉直 y %.2f",
                         label, scroll.contentView.bounds.origin.y,
                         NSStringFromRect(apply), NSStringFromRect(cancel), straighten.minY))
            return (apply, cancel, straighten.minY)
        }

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        panel.settle()
        let top = try snapshot("顶")

        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document - viewport)))
        scroll.reflectScrolledClipView(scroll.contentView)
        panel.settle()
        let bottom = try snapshot("底")

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        scroll.reflectScrolledClipView(scroll.contentView)
        panel.settle()
        let plus200 = try snapshot("再滚 200")

        // 两个按钮三次 frame 完全相同（Δ ≤0.5）.
        for (name, a, b) in [("顶/底", top, bottom), ("底/再滚 200", bottom, plus200)] {
            XCTAssertEqual(a.apply.minX, b.apply.minX, accuracy: 0.5, "336: 应用 x 在 \(name) 之间变了")
            XCTAssertEqual(a.apply.minY, b.apply.minY, accuracy: 0.5, "336: 应用 y 在 \(name) 之间变了")
            XCTAssertEqual(a.apply.width, b.apply.width, accuracy: 0.5, "336: 应用宽在 \(name) 之间变了")
            XCTAssertEqual(a.apply.height, b.apply.height, accuracy: 0.5, "336: 应用高在 \(name) 之间变了")
            XCTAssertEqual(a.cancel.minX, b.cancel.minX, accuracy: 0.5, "336: 取消 x 在 \(name) 之间变了")
            XCTAssertEqual(a.cancel.minY, b.cancel.minY, accuracy: 0.5, "336: 取消 y 在 \(name) 之间变了")
        }
        XCTAssertEqual(top.apply, plus200.apply, "336: 页脚跟着滚了（\(top.apply) vs \(plus200.apply)）")

        // 反向断言：卡内「拉直」的 y 确实变了（证明滚动真的发生，不是没滚）.
        XCTAssertGreaterThan(abs(bottom.straighten - top.straighten), 100,
                             "336: 卡内「拉直」只动了 \(abs(bottom.straighten - top.straighten)) pt —— 滚动没发生")
        print(String(format: "336 ③ · 拉直 y %.1f → %.1f（Δ %.1f）· 页脚 Δ 0.0",
                     top.straighten, bottom.straighten, bottom.straighten - top.straighten))
    }

    // MARK: - ④ 不在卡里

    func testTheCropCardNoLongerHoldsTheApplyRowAndTheFooterIsOutsideTheScrollView() throws {
        let (panel, _) = try transformPanel(width: 330, height: 900)
        defer { panel.window.contentView = nil }

        let card = try XCTUnwrap(panel.row(CropCardID.card))
        let rows = panel.rowIDs(inside: card)
        print("336 ④ · 裁切卡行集合 \(rows.sorted())")
        XCTAssertFalse(rows.contains(CropCardID.apply),
                       "336: 裁切卡里还留着 apply 行（\(rows.sorted())）")
        XCTAssertFalse(rows.contains(CropApplyRow.applyButtonProbe))
        XCTAssertFalse(rows.contains(CropApplyFooter.probeID))
        // 卡里仍有的那几行，一个都不少.
        for id in [CropCardID.aspect, CropCardID.staysInsidePixels, CropCardID.grid] {
            XCTAssertTrue(rows.contains(id), "336: 裁切卡少了 \(id)（\(rows.sorted())）")
        }

        // 判据：SwiftUI 的 `ScrollView` 在 macOS 上就是 `NSScrollView`，行探针是它的后代.
        let probes = panel.probes
        let applyProbe = try XCTUnwrap(probes.first { $0.rowID == CropApplyRow.applyButtonProbe })
        let footerProbe = try XCTUnwrap(probes.first { $0.rowID == CropApplyFooter.probeID })
        let rowProbe = try XCTUnwrap(probes.first { $0.rowID == CropApplyRow.probeID })
        for probe in [applyProbe, footerProbe, rowProbe] {
            XCTAssertNil(probe.enclosingScrollView,
                         "336: 页脚里的 \(probe.rowID) 在 ScrollView 内容里")
        }
        let gridProbe = try XCTUnwrap(probes.first { $0.rowID == CropCardID.grid })
        let straightenProbe = try XCTUnwrap(probes.first { $0.rowID == CorrectionCardRow.straighten.probeID })
        for probe in [gridProbe, straightenProbe] {
            XCTAssertNotNil(probe.enclosingScrollView,
                            "336: 卡里那一行 \(probe.rowID) 居然不在 ScrollView 里")
        }
        print("336 ④ · enclosingScrollView：页脚 nil · 应用 nil · 九宫格 YES · 拉直 YES")
    }

    // MARK: - ⑤ 非变换工作区没有页脚

    func testTheFooterIsAbsentOutsideTheTransformWorkspace() throws {
        let (panel, _) = try transformPanel(width: 330, height: 900)
        defer { panel.window.contentView = nil }

        // 「光」是 调整 工作区里的一张卡，不是工作区；非变换工作区用「色彩」（.colour）.
        panel.state.select(.colour)
        try panel.waitFor { !$0.cards.cardIDs.contains("crop") }
        let ids = Set(panel.probes.map(\.rowID))
        XCTAssertFalse(ids.contains(CropApplyFooter.probeID), "336: 色彩工作区还有页脚")
        XCTAssertFalse(ids.contains(CropApplyRow.probeID), "336: 色彩工作区还有按钮行")
        XCTAssertFalse(ids.contains(CropApplyRow.applyButtonProbe), "336: 色彩工作区还有应用按钮")
        XCTAssertFalse(ids.contains(CropApplyRow.cancelButtonProbe))
        // 连 id 都不在树里（AX 那半边也一样）.
        let ax = Self.allIdentifiers(in: panel.host)
        XCTAssertFalse(ax.contains(CropApplyRow.applyID), "336: 色彩工作区还有 \(CropApplyRow.applyID)")
        XCTAssertFalse(ax.contains(CropApplyRow.cancelID))
        print("336 ⑤ · 色彩工作区 · 探针 \(ids.sorted()) · ax 里 apply \(ax.contains(CropApplyRow.applyID))")

        // 切回变换：页脚回来，并且还在右下角.
        panel.state.select(.transform)
        try panel.waitFor { _ in panel.row(CropApplyFooter.probeID) != nil }
        let footer = try XCTUnwrap(panel.row(CropApplyFooter.probeID))
        XCTAssertEqual(footer.maxY, panel.host.bounds.maxY, accuracy: 0.5)
    }

    private static func allIdentifiers(in root: NSView) -> Set<String> {
        var out: Set<String> = []
        func walk(_ view: NSView) {
            let id = view.accessibilityIdentifier()
            if !id.isEmpty { out.insert(id) }
            for child in view.accessibilityChildren() ?? [] {
                if let v = child as? NSView { walk(v) }
                else if let e = child as? NSAccessibilityElement, let i = e.accessibilityIdentifier(),
                        !i.isEmpty { out.insert(i) }
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return out
    }

    // MARK: - harness

    @MainActor
    private struct Panel {
        let host: NSHostingView<InspectorView>
        let window: NSWindow
        let state: InspectorWorkspaceState

        var cards: InspectorCardsProbe {
            views(ofType: InspectorCardsProbe.self).first ?? InspectorCardsProbe(frame: .zero)
        }

        var probes: [CropRowProbe] { views(ofType: CropRowProbe.self) }

        var scrollView: NSScrollView? { views(ofType: NSScrollView.self).first }

        func row(_ id: String) -> CGRect? {
            probes.first { $0.rowID == id }.map { $0.convert($0.bounds, to: host) }
        }

        /// The row probes whose midpoint lies inside `rect` (334's own rule).
        func rowIDs(inside rect: CGRect) -> Set<String> {
            Set(probes.filter {
                $0.rowID != CropCardID.card
            }.filter {
                let f = $0.convert($0.bounds, to: host)
                return rect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: f.midX, y: f.midY))
            }.map(\.rowID))
        }

        func rowIDs() -> Set<String> { Set(probes.map(\.rowID)) }

        func views<T: NSView>(ofType: T.Type) -> [T] {
            var found: [T] = []
            func walk(_ root: NSView) {
                if let match = root as? T { found.append(match) }
                for sub in root.subviews { walk(sub) }
            }
            walk(host)
            return found
        }

        /// Lay out again and let SwiftUI flush (one runloop turn and a short wait).
        func settle(_ seconds: TimeInterval = 0.25) {
            host.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            CropUITestSupport.pump(seconds)
        }

        func waitFor(timeout: TimeInterval = 3, _ condition: (Panel) -> Bool) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition(self) { return }
                CropUITestSupport.pump(0.05)
            }
            XCTAssertTrue(condition(self), "336: 等了 \(timeout) s 条件仍不成立")
        }
    }

    private func transformPanel(width: CGFloat,
                                height: CGFloat) throws -> (Panel, LoupeController) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view

        _ = NSApplication.shared
        let state = InspectorWorkspaceState()
        let host = NSHostingView(rootView: InspectorView(session: session, loupe: loupe,
                                                          workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = TestWindows.make(contentRect: host.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.4)
        state.select(.transform)
        CropUITestSupport.pump(0.6)
        host.layoutSubtreeIfNeeded()
        let panel = Panel(host: host, window: window, state: state)
        XCTAssertTrue(loupe.isCropToolActive || loupe.beginCropTool(), "336: 进变换就该在裁切模式")
        try panel.waitFor { $0.cards.cardIDs == ["crop", "transformCorrection", "angle"] }
        try panel.waitFor { _ in panel.row(CropApplyFooter.probeID) != nil }
        return (panel, loupe)
    }
}
