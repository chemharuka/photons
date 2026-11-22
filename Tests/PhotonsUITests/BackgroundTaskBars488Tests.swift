import XCTest
import AppKit
import CoreGraphics
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 488 — 顶栏 1–4 条进度线、五条保留策略、面板行内真缩略图。
///
/// The numbers in this file are the dispatch's acceptance items 1–12: slot width == the 后台
/// button's intrinsic width even with zero tasks, three lines 3 pt apart with equal midX, at most
/// four visible lines (newest four), and `finishedKeep = max(0, 5 − inFlight)`.
@MainActor
final class BackgroundTaskBars488Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-bars488-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestWindows.sweep()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixtures

    private func makeBar(store: BackgroundTaskStore = BackgroundTaskStore(),
                         width: CGFloat = 1600) -> TopBarView {
        let bar = TopBarView(store: store)
        bar.frame = NSRect(x: 0, y: 0, width: width, height: WorkspaceLayout.topBarHeight)
        bar.statusColumnWidth = 330
        bar.update(mode: .grid, assetCount: 45, selectionCount: 4,
                   libraryName: "tasks-demo", filmstrip: false)
        bar.syncBackgroundTaskBars()
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private func refresh(_ bar: TopBarView) {
        bar.syncBackgroundTaskBars()
        bar.layoutSubtreeIfNeeded()
        bar.backgroundTaskBars.layoutSubtreeIfNeeded()
    }

    private func pump(_ seconds: TimeInterval = 0.25) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func finishedTask(_ store: BackgroundTaskStore, title: String, total: Int = 40,
                              completed: Int = 40, started: TimeInterval) -> UUID {
        let id = store.begin(BackgroundTask(kind: .export, title: title, total: total,
                                            startedAt: Date(timeIntervalSince1970: started)))
        store.advance(id: id, completed: completed)
        store.finish(id: id)
        return id
    }

    // MARK: - ① 0 tasks: the slot is reserved

    func testZeroTasksStillReservesTheButtonWideSlot() {
        let store = BackgroundTaskStore()
        let bar = makeBar(store: store)
        let bars = bar.backgroundTaskBars
        let buttonWidth = bar.backgroundButtonView.intrinsicContentSize.width

        // 481 —— 槽位从「后台」右边缘再让 6 pt，宽度跟着少 6 pt（右边缘不动）。
        let gap = BackgroundTaskBars.Metrics.gapFromButton
        XCTAssertGreaterThan(bars.frame.width, 0, "没有后台任务也要留出空间")
        XCTAssertEqual(bars.frame.width, buttonWidth - gap, accuracy: 0.001, "槽宽 = 后台按钮宽 − 间隙")
        XCTAssertEqual(bars.frame.minX, bar.backgroundButtonView.frame.maxX + gap, accuracy: 0.001,
                       "槽位从「后台」右边缘再让 \(gap) pt")
        XCTAssertEqual(bars.visibleTasks.count, 0, "0 个任务 ⇒ 0 条")
        XCTAssertEqual(bars.barFramesForTesting.count, 0)
        XCTAssertGreaterThanOrEqual(bar.statusCluster.frame.minX, bars.frame.maxX + 16 - 0.001,
                                    "状态簇从条区右边缘再让 16 pt")
        print("488① slot x=\(bars.frame.minX) w=\(bars.frame.width) buttonW=\(buttonWidth) bars=0")
    }

    // MARK: - ② one finished task: one full-width, fully blue line

    func testOneFinishedTaskIsOneFullWidthFullyBlueLine() {
        let store = BackgroundTaskStore()
        _ = finishedTask(store, title: "导出 40 张照片", started: 1)
        let bar = makeBar(store: store)
        refresh(bar)
        let bars = bar.backgroundTaskBars
        let buttonWidth = bar.backgroundButtonView.intrinsicContentSize.width

        XCTAssertEqual(bars.visibleTasks.count, 1)
        XCTAssertEqual(bars.barFramesForTesting.count, 1)
        XCTAssertEqual(bars.barFramesForTesting[0].width, buttonWidth - BackgroundTaskBars.Metrics.gapFromButton,
                       accuracy: 0.001, "1 条任务时线宽 = 按钮宽 − 间隙（481）")
        XCTAssertEqual(bars.blueFractionsForTesting[0], 1, accuracy: 0.0001,
                       "40/40 必须全蓝")
        XCTAssertEqual(bars.barFramesForTesting[0].midX, bars.bounds.midX, accuracy: 0.5)
        print("488② bars=1 w=\(bars.barFramesForTesting[0].width) blue=\(bars.blueFractionsForTesting[0])")
    }

    // MARK: - ③ three tasks: vertical 3 pt, centred, a 0 % line is all grey

    /// 510 — the third line used to be a `.queued` task (488 drew it as a grey line). 510 puts queued
    /// requests in the **panel** only (`「排队中（前面还剩 N 个）」`) and keeps the header for
    /// 「正在执行的那条 + 已完成未过期的」, so the grey line here is now a running task at 0/5 —
    /// the geometry and the all-grey claim are unchanged, the membership rule is asserted at the end.
    func testThreeTasksStackThreePointsApartCentredWithQueuedAllGrey() {
        let store = BackgroundTaskStore()
        let first = store.begin(BackgroundTask(kind: .denoise, title: "降噪 40 张", total: 40,
                                               startedAt: Date(timeIntervalSince1970: 1)))
        store.advance(id: first, completed: 10)
        let second = finishedTask(store, title: "导出 40 张照片", started: 2)
        let third = store.begin(BackgroundTask(kind: .export, title: "刚开始的导出", total: 5,
                                               startedAt: Date(timeIntervalSince1970: 3)))

        let bar = makeBar(store: store)
        refresh(bar)
        let bars = bar.backgroundTaskBars

        XCTAssertEqual(bars.visibleTasks.count, 3)
        let frames = bars.barFramesForTesting
        XCTAssertEqual(frames[1].minY - frames[0].maxY, BackgroundTaskBars.Metrics.spacing,
                       accuracy: 0.001, "竖排间距 3 pt")
        XCTAssertEqual(frames[2].minY - frames[1].maxY, BackgroundTaskBars.Metrics.spacing,
                       accuracy: 0.001, "竖排间距 3 pt")
        for frame in frames {
            XCTAssertEqual(frame.midX, bars.bounds.midX, accuracy: 0.5, "三条水平居中")
        }

        // display order is newest first: 0/5, finished, 10/40.
        let fractions = Dictionary(uniqueKeysWithValues: zip(bars.visibleTaskIDsForTesting,
                                                              bars.blueFractionsForTesting))
        XCTAssertEqual(fractions[third] ?? -1, 0, accuracy: 0.0001, "0/5 全灰")
        XCTAssertEqual(fractions[second] ?? -1, 1, accuracy: 0.0001, "40/40 全蓝")
        XCTAssertEqual(fractions[first] ?? -1, 0.25, accuracy: 0.0001, "10/40 = 25% 蓝")
        XCTAssertEqual(bars.visibleTaskIDsForTesting, [third, second, first], "新任务在最上")
        print("488③ bars=3 ys=\(frames.map(\.minY)) midX=\(frames.map(\.midX)) "
              + "blue=\(bars.blueFractionsForTesting.map { String(format: "%.2f", $0) })")

        // 510 — a **queued** request draws no header line at all: it lives in the panel, where its
        // text can say 「排队中（前面还剩 N 个）」. This also keeps the four slots for real progress.
        let queued = store.begin(BackgroundTask(kind: .denoise, title: "排队中", total: 5,
                                                startedAt: Date(timeIntervalSince1970: 4),
                                                state: .queued,
                                                queuedAhead: 1))
        refresh(bar)
        let afterQueue = bar.backgroundTaskBars
        print("510 排队项：store=\(store.tasks.count) 顶栏=\(afterQueue.visibleTasks.count) "
              + "ids=\(afterQueue.visibleTaskIDsForTesting)")
        XCTAssertEqual(afterQueue.visibleTasks.count, 3, "排队项不占顶栏槽位")
        XCTAssertFalse(afterQueue.visibleTaskIDsForTesting.contains(queued))
    }

    // MARK: - ④ six tasks: only the newest four are drawn

    func testSixTasksDrawOnlyTheNewestFour() {
        let store = BackgroundTaskStore()
        var ids: [UUID] = []
        for index in 0..<6 {
            ids.append(finishedTask(store, title: "批次\(index)", started: TimeInterval(index + 1)))
        }
        let bar = makeBar(store: store)
        refresh(bar)
        let bars = bar.backgroundTaskBars

        XCTAssertEqual(bars.visibleTasks.count, 4, "顶栏最多 4 条")
        XCTAssertEqual(bars.visibleTaskIDsForTesting, Array(ids.reversed().prefix(4)),
                       "最上面 4 条 = 最新 4 个任务")
        XCTAssertFalse(bars.visibleTaskIDsForTesting.contains(ids[0]), "第 6 条不显示")
        XCTAssertFalse(bars.visibleTaskIDsForTesting.contains(ids[1]), "第 5 条不显示")

        // Reverse gate: this constant is what makes the assertion above red if changed to 6.
        XCTAssertEqual(BackgroundTaskBars.Metrics.maximumVisibleBars, 4)
        print("488④ bars=\(bars.visibleTaskIDsForTesting.count) ids=\(bars.visibleTaskIDsForTesting.map { $0.uuidString.prefix(4) })")
    }

    // MARK: - ⑥⑦⑧ retention: five rows including in-flight

    func testFiveFinishedTasksAreRetained() {
        let store = BackgroundTaskStore()
        for index in 0..<5 {
            _ = finishedTask(store, title: "批次\(index)", started: TimeInterval(index + 1))
        }
        XCTAssertEqual(store.tasks.count, 5)
        XCTAssertEqual(store.finishedKeep, 5)
        XCTAssertEqual(store.displayTasks.map(\.title), ["批次4", "批次3", "批次2", "批次1", "批次0"])
    }

    func testTheSixthFinishedTaskDropsTheOldestImmediately() {
        let store = BackgroundTaskStore()
        var ids: [UUID] = []
        for index in 0..<5 {
            ids.append(finishedTask(store, title: "批次\(index)", started: TimeInterval(index + 1)))
        }
        let sixth = finishedTask(store, title: "批次5", started: 6)

        XCTAssertEqual(store.tasks.count, 5, "第 6 条完成 ⇒ 立刻删最旧，仍是 5")
        XCTAssertFalse(store.tasks.contains { $0.id == ids[0] }, "最旧的已完成记录不在")
        XCTAssertTrue(store.tasks.contains { $0.id == sixth })
        print("488⑦ count=\(store.tasks.count) oldestPresent=\(store.tasks.contains { $0.id == ids[0] })")
    }

    func testSixRunningTasksLeaveNoRoomForAFinishedRow() {
        let store = BackgroundTaskStore()
        var running: [UUID] = []
        for index in 0..<6 {
            running.append(store.begin(BackgroundTask(kind: .denoise, title: "运行\(index)", total: 2,
                                                      startedAt: Date(timeIntervalSince1970: Double(index + 1)))))
        }
        XCTAssertEqual(store.tasks.count, 6, "进行中的任务可以超过 5 个")
        XCTAssertEqual(store.finishedKeep, 0)

        let done = finishedTask(store, title: "刚完成", started: 7)
        XCTAssertEqual(store.tasks.count, 6, "6 在跑时任意一条完成即被删")
        XCTAssertFalse(store.tasks.contains { $0.id == done }, "完成的那条立刻删除")
        XCTAssertTrue(store.tasks.allSatisfy { !$0.state.isTerminal }, "剩下 6 条全是 in-flight")
        XCTAssertEqual(Set(store.tasks.map(\.id)), Set(running))
        print("488⑧ count=\(store.tasks.count) finishedKeep=\(store.finishedKeep)")
    }

    // MARK: - ⑩⑪⑫ panel thumbnail

    private func makeCache() throws -> ThumbnailCache {
        try ThumbnailCache(root: workDir.appendingPathComponent("thumbs-\(UUID().uuidString)",
                                                               isDirectory: true))
    }

    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }

    private func key(_ hash: String) -> ThumbKey {
        .preview(contentHash: hash, tier: .t256)
    }

    private func makePanel(store: BackgroundTaskStore,
                           source: BackgroundTaskThumbnailSource?) -> BackgroundTasksPopover {
        let panel = BackgroundTasksPopover(store: store, thumbnailSource: source)
        panel.loadViewIfNeeded()
        panel.reload()
        return panel
    }

    func testASingleRunningTaskShowsANonPlaceholderSquareWithin200ms() throws {
        let cache = try makeCache()
        let image = solidImage(red: 0.9, green: 0.1, blue: 0.1)
        let thumbKey = key("asset-A-\(UUID().uuidString)")
        try cache.store(image: image, for: thumbKey)
        let provider = ThumbnailProvider(cache: cache)
        let source = BackgroundTaskThumbnailSource(provider: { provider })

        let store = BackgroundTaskStore()
        _ = store.begin(BackgroundTask(kind: .denoise, title: "降噪 1 张", total: 1,
                                       currentThumbKey: thumbKey.keyString))
        let panel = makePanel(store: store, source: source)
        // Realise the row first (the popover's own layout does this when it is shown); then the
        // 200 ms clock starts and the async fill must land in that window.
        _ = panel.rowThumbnailImageForTesting(at: 0)
        pump(0.2)

        XCTAssertNotNil(panel.rowThumbnailImageForTesting(at: 0), "200 ms 内方块必须有真图像")
        XCTAssertEqual(panel.rowIsShowingThumbnailPlaceholderForTesting(at: 0), false,
                       "占位色必须消失")
        XCTAssertEqual(panel.rowThumbnailKeyForTesting(at: 0), thumbKey.keyString)
        XCTAssertEqual(panel.thumbnailMissCount, 0)
        print("488⑩ image=\(panel.rowThumbnailImageForTesting(at: 0).map { "\($0.size)" } ?? "nil") "
              + "placeholder=\(panel.rowIsShowingThumbnailPlaceholderForTesting(at: 0) ?? true)")
    }

    func testABatchMovesTheSquareFromTheFirstPhotoToTheSecond() throws {
        let cache = try makeCache()
        let provider = ThumbnailProvider(cache: cache)
        let source = BackgroundTaskThumbnailSource(provider: { provider })
        let keyA = key("asset-A-\(UUID().uuidString)")
        let keyB = key("asset-B-\(UUID().uuidString)")
        try cache.store(image: solidImage(red: 0.8, green: 0.2, blue: 0.2), for: keyA)
        try cache.store(image: solidImage(red: 0.2, green: 0.2, blue: 0.8), for: keyB)

        let store = BackgroundTaskStore()
        let id = store.begin(BackgroundTask(kind: .denoise, title: "降噪 3 张", total: 3,
                                            currentThumbKey: keyA.keyString))
        let panel = makePanel(store: store, source: source)
        _ = panel.rowThumbnailImageForTesting(at: 0)
        pump(0.2)
        XCTAssertEqual(panel.rowThumbnailKeyForTesting(at: 0), keyA.keyString, "第 1 张 = asset A")
        let firstImage = try XCTUnwrap(panel.rowThumbnailImageForTesting(at: 0))

        store.advance(id: id, completed: 1, currentThumbKey: keyB.keyString)
        panel.reload()
        pump(0.05)
        _ = panel.rowThumbnailImageForTesting(at: 0)
        pump(0.2)
        XCTAssertEqual(panel.rowThumbnailKeyForTesting(at: 0), keyB.keyString, "第 2 张 = asset B")
        let secondImage = try XCTUnwrap(panel.rowThumbnailImageForTesting(at: 0))
        XCTAssertFalse(firstImage === secondImage, "两张图不是同一个 NSImage 实例")

        store.clearCurrent(id: id)
        panel.reload()
        pump(0.05)
        XCTAssertNil(panel.rowThumbnailKeyForTesting(at: 0))
        XCTAssertEqual(panel.rowIsShowingThumbnailPlaceholderForTesting(at: 0), true,
                       "clearCurrent ⇒ 回到占位")
        print("488⑪ A=\(keyA.digest.prefix(8)) B=\(keyB.digest.prefix(8)) keyBShown=true")
    }

    func testWithoutAProviderTheSquareStaysAPlaceholderAndCountsTheMiss() {
        let store = BackgroundTaskStore()
        store.begin(BackgroundTask(kind: .export, title: "导出 1 张", total: 1,
                                   currentThumbKey: key("no-provider-\(UUID().uuidString)").keyString))
        let panel = makePanel(store: store, source: nil)
        pump(0.05)

        XCTAssertNil(panel.rowThumbnailImageForTesting(at: 0), "反向门：去掉 provider 必须没有图")
        XCTAssertEqual(panel.rowIsShowingThumbnailPlaceholderForTesting(at: 0), true)
        XCTAssertGreaterThan(panel.thumbnailMissCount, 0, "取不到要记一条，不能静默")
        print("488⑫ placeholder=true miss=\(panel.thumbnailMissCount)")
    }
}
