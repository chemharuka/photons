import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 504 — 后台任务完成后 **5 分钟**自动回收（顶栏进度条 + 面板行一起消失）。
///
/// Every number here comes off a **fake clock**: `store.now` is replaced with a closure over
/// `FakeClock.instant`, so the whole file runs in milliseconds and no test waits 300 real seconds.
/// Time only moves when a test says so, which is also what makes 「一次到期只裁一次」 assertable.
@MainActor
final class BackgroundTaskExpiry504Tests: XCTestCase {

    // MARK: - fake clock

    private final class FakeClock {
        var instant: Date
        init(_ t: TimeInterval) { instant = Date(timeIntervalSince1970: t) }
        func advance(_ dt: TimeInterval) { instant = instant.addingTimeInterval(dt) }
    }

    override func setUpWithError() throws {
        _ = NSApplication.shared
    }

    private func makeStore(_ clock: FakeClock) -> BackgroundTaskStore {
        let store = BackgroundTaskStore()
        store.now = { clock.instant }
        return store
    }

    /// A row that finished "now" on the fake clock: begin → advance → finish, the producer's real
    /// path, so `finishedAt` is written by the store and not by the test.
    @discardableResult
    private func completed(_ store: BackgroundTaskStore, title: String,
                           at clock: FakeClock, total: Int = 40) -> UUID {
        let id = store.begin(BackgroundTask(kind: .export, title: title, total: total,
                                            startedAt: clock.instant))
        store.advance(id: id, completed: total)
        store.finish(id: id)
        return id
    }

    private func makeBar(_ store: BackgroundTaskStore) -> TopBarView {
        let bar = TopBarView(store: store)
        bar.frame = NSRect(x: 0, y: 0, width: 1600, height: WorkspaceLayout.topBarHeight)
        bar.statusColumnWidth = 330
        bar.update(mode: .grid, assetCount: 45, selectionCount: 4,
                   libraryName: "expiry-demo", filmstrip: false)
        bar.syncBackgroundTaskBars()
        bar.layoutSubtreeIfNeeded()
        bar.backgroundTaskBars.layoutSubtreeIfNeeded()
        return bar
    }

    private func makePanel(_ store: BackgroundTaskStore) -> BackgroundTasksPopover {
        let panel = BackgroundTasksPopover(store: store, thumbnailSource: nil)
        panel.loadViewIfNeeded()
        panel.reload()
        return panel
    }

    // MARK: - ① fake clock: 299 / 301 / 401

    func testFinishedRowsLiveUntil300ThenExpireOneByOne() {
        let clock = FakeClock(1_000)
        let store = makeStore(clock)
        let a = completed(store, title: "A", at: clock)          // t = 0
        clock.advance(100)
        let b = completed(store, title: "B", at: clock)          // t = 100
        XCTAssertEqual(store.displayTasks.map(\.title), ["B", "A"])

        clock.advance(199)                                       // t = 299
        XCTAssertEqual(store.displayTasks.map(\.title), ["B", "A"], "t=299 两条都还在")
        XCTAssertTrue(store.tasks.contains { $0.id == a })

        // 「到点自动消失」= an observer hears about it with **no user action in between**. Without
        // the one-shot timer this stays 0 and the row only disappears from the next render.
        var notifications = 0
        store.onExpiry = { notifications += 1 }

        store.fireExpiryTimerForTesting()                        // an early tick must not remove
        XCTAssertEqual(store.displayTasks.map(\.title), ["B", "A"], "早到一拍不裁")
        XCTAssertEqual(notifications, 0, "没到期就不许通知")

        clock.advance(2)                                         // t = 301
        store.fireExpiryTimerForTesting()
        XCTAssertEqual(store.displayTasks.map(\.title), ["B"], "t=301 只有 A 到期")
        XCTAssertEqual(notifications, 1, "到点自动通知一次（不靠下一次用户操作）")
        XCTAssertFalse(store.tasks.contains { $0.id == a }, "A 已从存储里裁掉，不是只隐藏")
        XCTAssertTrue(store.tasks.contains { $0.id == b })

        clock.advance(100)                                       // t = 401
        store.fireExpiryTimerForTesting()
        XCTAssertEqual(store.displayTasks, [], "t=401 两条都到期")
        XCTAssertEqual(notifications, 2, "第二次到期再通知一次")
        XCTAssertTrue(store.tasks.isEmpty)
        print("504① t=299 → 2；t=301 → 1（A 走）；t=401 → 0；通知 \(notifications) 次")
    }

    // MARK: - ② three surfaces agree

    func testDisplayTasksTopBarAndPanelRowsAlwaysAgree() {
        let clock = FakeClock(5_000)
        let store = makeStore(clock)
        completed(store, title: "A", at: clock)
        clock.advance(100)
        completed(store, title: "B", at: clock)

        let bar = makeBar(store)
        let panel = makePanel(store)

        func readings(_ label: String) -> (Int, Int, Int) {
            // The panel re-reads on the observation bridge in the app; here the same `reload()` the
            // bridge calls is invoked directly so the table's own row count is current.
            bar.syncBackgroundTaskBars()
            panel.reload()
            let display = store.displayTasks.count
            let bars = bar.backgroundTaskBars.visibleTaskIDsForTesting.count
            let rows = panel.tableRowCountForTesting
            print("504② \(label) displayTasks=\(display) topBarBars=\(bars) panelRows=\(rows)")
            return (display, bars, rows)
        }

        clock.advance(199)                                       // t = 299 (A finished at t=0)
        let stillThere = readings("t=299")
        XCTAssertEqual(stillThere.0, 2)
        XCTAssertEqual(stillThere.0, stillThere.1, "顶栏条数 == displayTasks")
        XCTAssertEqual(stillThere.0, stillThere.2, "面板行数 == displayTasks")

        clock.advance(2)                                         // t = 301
        store.fireExpiryTimerForTesting()
        let oneGone = readings("t=301")
        XCTAssertEqual(oneGone.0, 1)
        XCTAssertEqual(oneGone.0, oneGone.1)
        XCTAssertEqual(oneGone.0, oneGone.2)

        clock.advance(100)                                       // t = 401
        store.fireExpiryTimerForTesting()
        let empty = readings("t=401")
        XCTAssertEqual(empty.0, 0)
        XCTAssertEqual(empty.1, 0, "顶栏一条都不画")
        XCTAssertEqual(empty.2, 0, "面板零行")
        XCTAssertTrue(panel.isShowingEmptyState, "面板回到空状态文案")
    }

    // MARK: - ③ an in-flight task never expires by time

    func testARunningTaskSurvivesTenTimesTheRetention() {
        let clock = FakeClock(9_000)
        let store = makeStore(clock)
        let running = store.begin(BackgroundTask(kind: .denoise, title: "在飞",
                                                total: 10, startedAt: clock.instant))
        XCTAssertNil(store.displayTasks.first?.finishedAt, "在飞任务没有 finishedAt")

        var notifications = 0
        store.onExpiry = { notifications += 1 }

        clock.advance(600)                                       // ≫ 300 s
        XCTAssertEqual(store.displayTasks.map(\.id), [running], "在飞任务跨 600 s 仍在")
        XCTAssertTrue(store.tasks.contains { $0.id == running })
        XCTAssertNil(store.nextExpiryDate, "没有终态行 ⇒ 没有可排的到期时刻")
        XCTAssertFalse(store.fireExpiryTimerForTesting(), "没有定时器可触发")
        XCTAssertEqual(notifications, 0)

        // The task still finishes normally afterwards, and only then starts its own clock.
        store.advance(id: running, completed: 10)
        store.finish(id: running)
        XCTAssertEqual(store.expiryTickCount, 0)
        XCTAssertNotNil(store.nextExpiryDate, "终态之后才开始计 300 s")
        print("504③ 在飞任务 +600 s 仍在：displayTasks=1 tasks=1 通知=0；终态后 nextExpiry = +\(Int(store.nextExpiryDate!.timeIntervalSince(clock.instant))) s")
    }

    // MARK: - ④ one expiry wave prunes once

    func testOneExpiryWavePrunesExactlyOnce() {
        let clock = FakeClock(20_000)
        let store = makeStore(clock)
        for title in ["A", "B", "C"] { completed(store, title: title, at: clock) }
        XCTAssertEqual(store.displayTasks.count, 3)

        var notifications = 0
        store.onExpiry = { notifications += 1 }

        clock.advance(301)
        XCTAssertTrue(store.fireExpiryTimerForTesting(), "到期时刻必须真有定时器在跑")
        XCTAssertEqual(store.expiryTickCount, 1, "一次到期 = 一拍")
        XCTAssertEqual(notifications, 1, "一次到期 = 一次通知（不是每行一次）")
        XCTAssertTrue(store.tasks.isEmpty, "同一拍里三行全裁")
        XCTAssertEqual(store.displayTasks.count, 0)
        XCTAssertFalse(store.fireExpiryTimerForTesting(), "裁完不再排拍")

        // Moving the clock further must not produce another wave: nothing is armed, nothing due.
        clock.advance(10_000)
        XCTAssertFalse(store.fireExpiryTimerForTesting())
        XCTAssertEqual(store.expiryTickCount, 1, "多余的重排一次都不许有")
        XCTAssertEqual(notifications, 1)
        print("504④ ticks=\(store.expiryTickCount) notifications=\(notifications) tasks=\(store.tasks.count)")
    }

    // MARK: - ⑤ count rule and time rule coexist

    func testSevenFinishedKeepFiveThenTimeEmptiesThem() {
        let clock = FakeClock(30_000)
        let store = makeStore(clock)
        for index in 0..<7 { completed(store, title: "批次\(index)", at: clock) }

        XCTAssertEqual(store.displayTasks.count, 5, "条数规则先砍到 5")
        XCTAssertEqual(store.tasks.count, 5)
        XCTAssertEqual(store.displayTasks.map(\.title), ["批次6", "批次5", "批次4", "批次3", "批次2"],
                       "砍的是最老的")
        XCTAssertEqual(BackgroundTaskStore.finishedRetention, 300, "值不许被顺手改掉")

        clock.advance(301)
        store.fireExpiryTimerForTesting()
        XCTAssertEqual(store.displayTasks.count, 0, "时间规则随后清空")
        print("504⑤ 7 个完成 → 5（条数）；+301 s → 0（时间）")
    }
}
