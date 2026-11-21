import XCTest
import AppKit
import PhotonsLocalization
@testable import PhotonsUI

/// 454 P1 — 顶栏「排序 | 后台」入口、空面板，以及 `BackgroundTaskStore` 的纯逻辑。
///
/// P1 的验收只有一件事：**任务这个概念存在且能画，但现有行为一点没变**。所以这里不碰导出的
/// dismiss 路径、不碰两个 HUD，也不制造任何真实生产者 —— store 的测试直接写值类型。
@MainActor
final class BackgroundTaskEntry454Tests: XCTestCase {

    override func setUpWithError() throws {
        _ = NSApplication.shared
    }

    override func tearDownWithError() throws {
        TestWindows.sweep()
    }

    // MARK: - fixtures

    private func makeBar(width: CGFloat = 1600) -> TopBarView {
        let bar = TopBarView()
        bar.frame = NSRect(x: 0, y: 0, width: width, height: WorkspaceLayout.topBarHeight)
        bar.statusColumnWidth = 330
        bar.update(mode: .grid, assetCount: 45, selectionCount: 4,
                   libraryName: "tasks-demo", filmstrip: false)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    /// The real production click path needs a window for `NSPopover.show`.
    private func makeLiveBar() -> TopBarView {
        let bar = TopBarView()
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 700, height: 120))
        window.contentView = bar
        bar.frame = NSRect(x: 0, y: 0, width: 700, height: WorkspaceLayout.topBarHeight)
        TestWindows.show(window)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private func pump() {
        for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    // MARK: - 1 · 顶栏入口

    func testTopBarEntryIsRightmostAndHasItsOwnSeparator() {
        let bar = makeBar()
        let sort = bar.sortButtonView
        let background = bar.backgroundButtonView

        XCTAssertEqual(background.title, "后台")
        XCTAssertEqual(bar.controlsTrailingEdge, background.frame.maxX, accuracy: 0.001,
                       "预算线必须是「后台」按钮的右边缘")
        XCTAssertGreaterThanOrEqual(background.frame.minX - sort.frame.maxX, TopBarView.itemGap - 0.001,
                                    "排序与后台之间至少留一个 itemGap")

        XCTAssertEqual(bar.separatorsForTesting.count, 2, "顶栏现在有两条分隔线")
        let second = bar.separatorsForTesting[1]
        XCTAssertGreaterThan(second.frame.minX, sort.frame.maxX, "第二条分隔线在排序右侧")
        XCTAssertLessThan(second.frame.maxX, background.frame.minX, "第二条分隔线在后台按钮左侧")

        // 状态簇仍然让开最右控件。
        XCTAssertGreaterThanOrEqual(bar.statusCluster.frame.minX,
                                    bar.controlsTrailingEdge
                                        + TopBarStatusCluster.Metrics.minimumGapFromControls - 0.001)
    }

    // MARK: - 3 · 空面板（点开 → 文本 → 再点关闭）

    func testClickingTheEntryShowsAnEmptyPopoverAndClickingAgainClosesIt() {
        let bar = makeLiveBar()
        XCTAssertTrue(bar.backgroundTaskStore.tasks.isEmpty, "P1 没有生产者，列表必须为空")

        bar.backgroundButtonView.performClick(nil)
        pump()
        XCTAssertTrue(bar.isBackgroundTasksPopoverOpen)
        XCTAssertTrue(bar.backgroundTasksPopoverForTesting.isShown, "点一下必须真的弹出 popover")

        let panel = bar.backgroundTasksPopoverControllerForTesting
        XCTAssertEqual(panel.emptyStateText, Loc.t("没有后台任务"))
        XCTAssertEqual(panel.emptyStateText, "没有后台任务")
        XCTAssertTrue(panel.isShowingEmptyState)
        XCTAssertEqual(panel.rowHeightForTesting, WorkspaceLayout.browserRowHeight,
                       "行高与侧栏一致")

        bar.backgroundButtonView.performClick(nil)
        pump()
        XCTAssertFalse(bar.isBackgroundTasksPopoverOpen)
        XCTAssertFalse(bar.backgroundTasksPopoverForTesting.isShown, "再点一次必须关闭")
    }

    // MARK: - 4 · store 纯逻辑

    func testBeginAdvanceFinishCountText() {
        let store = BackgroundTaskStore()
        let id = store.begin(BackgroundTask(kind: .export, title: "导出", total: 40))
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(store.countText(for: store.tasks[0]), "0/40")
        XCTAssertEqual(store.progressFraction(for: store.tasks[0]), 0, accuracy: 0.0001)

        store.advance(id: id, completed: 8, currentAssetID: "asset-8", currentThumbKey: "thumb-8")
        XCTAssertEqual(store.tasks.count, 1, "advance 必须就地更新，不能追加")
        XCTAssertEqual(store.tasks[0].currentAssetID, "asset-8")
        XCTAssertEqual(store.tasks[0].currentThumbKey, "thumb-8")
        XCTAssertEqual(store.countText(for: store.tasks[0]), "8/40")
        XCTAssertEqual(store.progressFraction(for: store.tasks[0]), 0.2, accuracy: 0.0001)

        store.finish(id: id)
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(store.tasks[0].state, .finished)
        XCTAssertEqual(store.countText(for: store.tasks[0]), "40/40")
        XCTAssertEqual(store.progressFraction(for: store.tasks[0]), 1, accuracy: 0.0001)
    }

    func testRetentionKeepsFiveRowsIncludingRunningOnesAndClearFinishedLeavesRunningOnes() {
        // 488 — owner rule: five retained rows **including** in-flight tasks. These numbers are the
        // dispatch's §2.2 item 7; changing the limit back to 20 must turn this red.
        let store = BackgroundTaskStore()
        for index in 0..<25 {
            let id = store.begin(BackgroundTask(kind: .export,
                                                title: "批次\(index)",
                                                total: 1,
                                                startedAt: Date(timeIntervalSince1970: Double(index))))
            store.finish(id: id)
        }
        XCTAssertEqual(BackgroundTaskStore.retainedFinishedLimit, 5)
        XCTAssertEqual(store.retainedFinishedLimit, 5)
        XCTAssertEqual(store.tasks.count, 5, "已完成最多留 5 条")
        XCTAssertEqual(Set(store.tasks.map(\.title)), Set((20..<25).map { "批次\($0)" }),
                       "超出时按 startedAt 淘汰最旧的已完成")

        // 5 finished + 1 running: the running one is never evicted, so the total is 6 and the
        // finished budget becomes max(0, 5 − 1) = 4 ⇒ the oldest finished row goes immediately.
        let running = store.begin(BackgroundTask(kind: .denoise, title: "降噪中", total: 3))
        store.advance(id: running, completed: 1)
        XCTAssertEqual(store.tasks.count, 5, "进行中的任务占一个保留位，完成记录同步减一")
        XCTAssertEqual(Set(store.tasks.map(\.title)),
                       Set(["降噪中"] + (21..<25).map { "批次\($0)" }))

        store.clearFinished()
        XCTAssertEqual(store.tasks.count, 1, "clearFinished 只清已结束（finished/cancelled/failed）")
        XCTAssertEqual(store.tasks[0].id, running)
        XCTAssertEqual(store.tasks[0].state, .running)
    }
}
