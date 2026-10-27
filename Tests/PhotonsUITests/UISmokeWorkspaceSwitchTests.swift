import XCTest
import AppKit
import SwiftUI
@testable import PhotonsUI

/// 派单 073 的**冒烟路径**，用单测方式钉住 —— 不靠 `make ui-smoke` 开窗口。
///
/// 背景：工作区切换器合入后，默认的「调整」工作区**不再构建蒙版卡**，而 `UISmokeRunner` 里有两处检查
/// 是「遍历窗口树找 `MaskPanelProbe`」。那两条红是假红：产品没坏，是冒烟没跟上。修法只有一种诚实的：
/// 检查前先切到「蒙版」工作区，查完切回。这个文件钉的正是**修好后的那条路径本身**：
///
///   1. `UISmokeRunner.maskProbe(in:)` —— 冒烟用的那个遍历函数 —— 在默认工作区里返回 `nil`、切到
///      「蒙版」后返回非 `nil`、切回「调整」后又是 `nil`（既证明假红的成因，也证明切回去真的切回去了，
///      不留一个过期的探针在树上）；
///   2. `UISmokeRunner.showInspectorWorkspace` 切换后等的那个条件（`InspectorCardsProbe` 报出的工作区
///      + 卡片 id 序列 == `InspectorView.sections(in:)`）五个工作区都成立 —— 冒烟里的等待循环因此不会
///      空转到超时，然后在后面报一条与被测东西无关的失败。
///
/// 这里不重复 `InspectorWorkspaceTests` 已经钉过的东西（配色、等宽、卡片表本身）；只钉冒烟代码的接缝。
@MainActor
final class UISmokeWorkspaceSwitchTests: XCTestCase {

    // MARK: - 1. 冒烟的 maskProbe 只在「蒙版」工作区里看得见蒙版卡

    func testTheSmokeRunnersMaskProbeSeesThePanelOnlyInTheMasksWorkspace() {
        let (host, state) = hostPanel()

        // 默认工作区（调整）：蒙版卡不在树上 —— 这正是那两条冒烟检查假红的原因，
        // 不是「面板坏了」。
        XCTAssertNil(UISmokeRunner.maskProbe(in: host),
                     "「调整」工作区里不该有蒙版卡：默认工作区不构建 MaskListPanel")
        XCTAssertEqual(state.selection, .adjust, "面板打开时必须是「调整」")

        // 切到「蒙版」：冒烟的遍历函数必须找得到，而且要真的等到它出现。
        state.select(.masks)
        guard let probe = poll(timeout: 3, { UISmokeRunner.maskProbe(in: host) }) else {
            return XCTFail("切到「蒙版」后 3 s 内视图树里没有 MaskPanelProbe")
        }
        // 没有蒙版的库里列表是空的（`listOrder` 就是 `masks.map(\.name)`），所以这里只钉「面板本身在」；
        // 参数行与列表内容是 `checkMaskParameters` 的事，它有自己的基础文档。
        _ = probe

        // 切回「调整」：探针必须消失。旧视图留在树上就等于「切了没生效」，而这会让冒烟在错误的
        // 工作区里做断言 —— 所以这一条比第一条更重要。
        state.select(.adjust)
        let gone = poll(timeout: 3) { UISmokeRunner.maskProbe(in: host) == nil ? true : nil } ?? false
        XCTAssertTrue(gone, "切回「调整」后 MaskPanelProbe 仍然在视图树里（旧的工作区没被拆掉）")
        XCTAssertEqual(state.selection, .adjust)
    }

    // MARK: - 2. 冒烟切换后等的那个条件，五个工作区都成立

    func testTheConditionTheSmokeWaitsOnHoldsForEveryWorkspace() {
        let (host, state) = hostPanel()

        for workspace in InspectorWorkspace.allCases {
            state.select(workspace)
            guard let cards = poll(timeout: 3, {
                firstCardProbe(in: host).flatMap { $0.workspace == workspace.rawValue ? $0 : nil }
            }) else {
                XCTFail("\(workspace.title)：3 s 内滚动区的 InspectorCardsProbe 没有报出这个工作区")
                continue
            }
            // `UISmokeRunner.showInspectorWorkspace` 等的就是这个等式；它不成立，冒烟就会空转到超时，
            // 然后在后面报一条与被测东西无关的失败。
            XCTAssertEqual(cards.cardIDs, InspectorView.sections(in: workspace).map(\.rawValue),
                           "\(workspace.title)：面板报的卡片 id 序列必须等于 InspectorView.sections(in:)")
            XCTAssertEqual(cards.cardTitles, workspace.cards.map(\.title),
                           "\(workspace.title)：面板报的卡片标题必须等于工作区映射表（空工作区就是 []）")
        }
    }

    // MARK: - 宿主

    /// 一个面板、一个状态，都是**真实的** `InspectorView` —— 没有替身：冒烟的探针函数遍历的是
    /// SwiftUI 真正建出来的 AppKit 叶子。
    private func hostPanel(height: CGFloat = 900) -> (NSView, InspectorWorkspaceState) {
        _ = NSApplication.shared
        let session = CatalogSession()
        let state = InspectorWorkspaceState()
        let host = NSHostingView(rootView: InspectorView(session: session, workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        return (host, state)
    }

    private func firstCardProbe(in root: NSView) -> InspectorCardsProbe? {
        if let probe = root as? InspectorCardsProbe { return probe }
        for sub in root.subviews {
            if let found = firstCardProbe(in: sub) { return found }
        }
        return nil
    }

    // MARK: - 轮询（不睡固定时长：CI 上的布局可能比一帧慢）

    private func poll<T>(timeout: TimeInterval, _ read: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = read() { return value }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return read()
    }
}
