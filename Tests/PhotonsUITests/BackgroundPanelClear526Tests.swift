import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 526 — 后台面板的「清空已完成」+ 底部按钮不再压住末行进度条。
///
/// The reverse gates live in the assertions: clearing by queue semantics (`clearDenoiseQueue`)
/// leaves the finished rows in place, so case ① / ② go red; moving `scrollView` back to `y: 8`
/// puts case ③'s `minY ≥ button.maxY` under 24 and goes red.
@MainActor
final class BackgroundPanelClear526Tests: XCTestCase {

    private final class FakeClock {
        var instant: Date
        init(_ t: TimeInterval) { instant = Date(timeIntervalSince1970: t) }
        func advance(_ dt: TimeInterval) { instant = instant.addingTimeInterval(dt) }
    }

    override func setUpWithError() throws {
        _ = NSApplication.shared
    }

    override func tearDownWithError() throws {
        TestWindows.sweep()
    }

    private func makeStore(_ clock: FakeClock) -> BackgroundTaskStore {
        let store = BackgroundTaskStore()
        store.now = { clock.instant }
        return store
    }

    private func makePanel(_ store: BackgroundTaskStore,
                           size: NSSize = NSSize(width: BackgroundTasksPopover.preferredWidth,
                                                 height: BackgroundTasksPopover.preferredHeight))
        -> BackgroundTasksPopover {
        let panel = BackgroundTasksPopover(store: store, thumbnailSource: nil)
        panel.loadViewIfNeeded()
        panel.view.frame = NSRect(origin: .zero, size: size)
        panel.reload()
        panel.view.needsLayout = true
        panel.view.layoutSubtreeIfNeeded()
        return panel
    }

    @discardableResult
    private func beginFinished(_ store: BackgroundTaskStore, title: String,
                               at instant: Date) -> UUID {
        let id = store.begin(BackgroundTask(kind: .export, title: title, total: 2,
                                            startedAt: instant))
        store.advance(id: id, completed: 2)
        store.finish(id: id)
        return id
    }

    // MARK: - ① 只清终态，running 逐字段不变

    func testClearFinishedRemovesOnlyTerminalRowsAndKeepsRunningProgress() throws {
        let clock = FakeClock(2_000)
        let store = makeStore(clock)

        let running = store.begin(BackgroundTask(kind: .denoise, title: "正在降噪", total: 10,
                                                 startedAt: clock.instant))
        store.advance(id: running, completed: 4, currentAssetID: "asset-run-1",
                      currentThumbKey: "thumb|v2|hash|hdJPEG|t2048|jpeg|digest|0")
        let queued = store.begin(BackgroundTask(kind: .denoise, title: "排队中", total: 3,
                                                startedAt: clock.instant.addingTimeInterval(1),
                                                state: .queued, queuedAhead: 1))

        // 3 terminal + 2 in-flight == the five-row budget exactly, so nothing is evicted before
        // the clear and the returned count can be the literal 3.
        var terminalIDs: [UUID] = []
        for index in 0..<3 {
            clock.advance(10)
            terminalIDs.append(beginFinished(store, title: "已完成\(index)", at: clock.instant))
        }
        XCTAssertEqual(store.tasks.count, 5)

        let runningBefore = try XCTUnwrap(store.tasks.first { $0.id == running })

        let removed = store.clearFinished()

        XCTAssertEqual(removed, 3, "只清 finished / failed / cancelled 三条")
        XCTAssertEqual(store.tasks.map(\.id), [running, queued], "running / queued 两行都在")
        XCTAssertFalse(store.tasks.contains { terminalIDs.contains($0.id) }, "终态行一条不剩")

        let runningAfter = try XCTUnwrap(store.tasks.first { $0.id == running })
        XCTAssertEqual(runningAfter, runningBefore, "running 行逐字段不变（progress / currentAssetID 等）")
        XCTAssertEqual(runningAfter.completed, 4)
        XCTAssertEqual(runningAfter.currentAssetID, "asset-run-1")
        XCTAssertEqual(runningAfter.state, .running)

        XCTAssertEqual(store.clearFinished(), 0, "没有终态行时返回 0")
        XCTAssertEqual(store.tasks.count, 2)
        print("526① 清掉 \(removed) 条，剩 running=\(runningAfter.completed)/10 "
              + "asset=\(runningAfter.currentAssetID ?? "nil")")
    }

    // MARK: - ② 按钮可见性跟着终态行走

    func testClearFinishedButtonAppearsOnlyWithTerminalRowsAndHidesImmediately() {
        let clock = FakeClock(3_000)
        let store = makeStore(clock)
        let running = store.begin(BackgroundTask(kind: .denoise, title: "正在导出", total: 8,
                                                 startedAt: clock.instant))
        store.advance(id: running, completed: 3)

        let panel = makePanel(store)
        XCTAssertFalse(panel.isClearFinishedButtonVisibleForTesting, "没有终态行 ⇒ 按钮隐藏")
        XCTAssertEqual(panel.clearFinishedButtonTitleForTesting, "清空已完成")

        beginFinished(store, title: "导出完成", at: clock.instant)
        panel.reload()
        XCTAssertTrue(panel.isClearFinishedButtonVisibleForTesting, "有一条终态 ⇒ 按钮显示")
        XCTAssertEqual(panel.clearFinishedButtonAccessibilityIdentifierForTesting,
                       "backgroundTasks.clearFinished")
        XCTAssertEqual(panel.tableRowCountForTesting, 2)

        panel.clearFinishedForTesting()

        XCTAssertFalse(panel.isClearFinishedButtonVisibleForTesting, "清空后立刻隐藏")
        XCTAssertEqual(store.tasks.map(\.id), [running], "在跑的那条不动")
        XCTAssertEqual(panel.tableRowCountForTesting, 1)
        print("526② 终态 0 → 隐藏；1 → 显示；清空后 → 隐藏")
    }

    // MARK: - ③ 底部按钮不再压住列表

    func testScrollViewNeverOverlapsTheClearButton() {
        let clock = FakeClock(4_000)
        let store = makeStore(clock)
        beginFinished(store, title: "已完成", at: clock.instant)

        let panel = makePanel(store)
        XCTAssertTrue(panel.isClearFinishedButtonVisibleForTesting, "footer 必须真的占位")

        // 默认 380×240, plus the smallest size this file exercises (320×160).
        let sizes = [NSSize(width: 380, height: 240), NSSize(width: 320, height: 160)]
        var readings: [(CGFloat, CGFloat, CGFloat)] = []
        for size in sizes {
            panel.view.frame = NSRect(origin: .zero, size: size)
            panel.view.needsLayout = true
            panel.view.layoutSubtreeIfNeeded()

            let scroll = panel.scrollViewFrameForTesting
            let button = panel.clearFinishedButtonFrameForTesting
            readings.append((scroll.minY, button.maxY, scroll.maxY))

            XCTAssertGreaterThanOrEqual(scroll.minY, button.maxY,
                                        "\(size)：列表下沿必须不低于按钮上沿")
            XCTAssertLessThanOrEqual(scroll.maxY, size.height - 8,
                                     "\(size)：列表上沿留 8 pt")
            XCTAssertEqual(button.maxY, 24, "\(size)：按钮仍占 y ∈ [6, 24]")
            XCTAssertEqual(scroll.minY, 38, "\(size)：页脚真实占 30 pt（8 + 30）")
        }

        // The default size, spelled out: maxY == 240 − 8 == 232, height == 232 − 38 == 194.
        panel.view.frame = NSRect(x: 0, y: 0, width: 380, height: 240)
        panel.view.needsLayout = true
        panel.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.scrollViewFrameForTesting.minY, 38)
        XCTAssertEqual(panel.scrollViewFrameForTesting.maxY, 232)
        XCTAssertEqual(panel.scrollViewFrameForTesting.height, 194)
        print("526③ minY/buttonMaxY/maxY：\(readings)")
    }

    // MARK: - ④ 清空后顶栏 1–4 条读数同步刷新（488）

    func testTopBarBarsDropFinishedRowsAfterClearFinished() {
        let clock = FakeClock(5_000)
        let store = makeStore(clock)
        let running = store.begin(BackgroundTask(kind: .export, title: "在跑", total: 10,
                                                 startedAt: clock.instant))
        store.advance(id: running, completed: 2)
        let finished = beginFinished(store, title: "完成", at: clock.instant.addingTimeInterval(1))

        let bar = TopBarView(store: store)
        bar.frame = NSRect(x: 0, y: 0, width: 1600, height: WorkspaceLayout.topBarHeight)
        bar.statusColumnWidth = 330
        bar.syncBackgroundTaskBars()
        XCTAssertEqual(Set(bar.backgroundTaskBars.visibleTaskIDsForTesting), [running, finished])

        store.clearFinished()
        bar.syncBackgroundTaskBars()

        XCTAssertEqual(bar.backgroundTaskBars.visibleTaskIDsForTesting, [running],
                       "清空后顶栏只留在跑的那一条")
    }
}
