import XCTest
import AppKit
import PhotonsCore
@testable import PhotonsExport
@testable import PhotonsUI

/// 454 P3 — 点「导出」后 sheet 收起，任务进后台面板；进度按回调自增，取消只能走面板那一行。
///
/// 不导真文件：`ExportSheetModel.batchRun` / `imageRenderer` 是本单新增的接缝，fake exporter 直接
/// 按调用顺序驱动 `markRendered`，所以 40 张的批次在这里只是 3 个字符串。
@MainActor
final class ExportToBackground454Tests: XCTestCase {

    private var scratch: URL!
    private var draftStore: MemoryDraftStore!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-export-bg454-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        draftStore = MemoryDraftStore()
    }

    override func tearDownWithError() throws {
        TestWindows.sweep()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - fixtures

    final class MemoryDraftStore: ExportDraftPersistence.Store {
        var values: [String: Data] = [:]
        func exportDraftData(forKey key: String) -> Data? { values[key] }
        func setExportDraftData(_ data: Data?, forKey key: String) {
            if let data { values[key] = data } else { values.removeValue(forKey: key) }
        }
    }

    private func model(store: BackgroundTaskStore? = nil) -> ExportSheetModel {
        let model = ExportSheetModel(presetStore: ExportPresetStore(directory: scratch),
                                     draftStore: draftStore,
                                     backgroundTasks: store)
        model.outputDirectory = scratch
        model.imageRenderer = { _, _, _ in Self.image() }
        return model
    }

    private static func image() -> DisplayImage {
        DisplayImage(width: 4, height: 4,
                     rgba: [Float16](repeating: 0.5, count: 4 * 4 * 4),
                     primaries: .displayP3, bitDepth: 8)
    }

    private func items(_ ids: [String]) -> [ExportItem] {
        ids.map { ExportItem(id: $0, name: $0) }
    }

    private func report(_ items: [ExportItem],
                        failures: Set<String> = [],
                        cancelled: Set<String> = []) -> BatchExportReport {
        let outcomes = items.enumerated().map { index, item -> BatchExportOutcome in
            if failures.contains(item.id) {
                return BatchExportOutcome(index: index, id: item.id, sourceName: item.name,
                                          fileURL: nil, fileBytes: 0, pixelSize: nil,
                                          seconds: 0, xmpURL: nil, warnings: [],
                                          error: "fake failure")
            }
            if cancelled.contains(item.id) {
                return BatchExportOutcome(index: index, id: item.id, sourceName: item.name,
                                          fileURL: nil, fileBytes: 0, pixelSize: nil,
                                          seconds: 0, xmpURL: nil, warnings: [],
                                          error: nil, cancelled: true)
            }
            return BatchExportOutcome(index: index, id: item.id, sourceName: item.name,
                                      fileURL: scratch.appendingPathComponent("\(item.id).png"),
                                      fileBytes: 16,
                                      pixelSize: ImageSize(width: 4, height: 4),
                                      seconds: 0.01, xmpURL: nil, warnings: [], error: nil)
        }
        return BatchExportReport(outcomes: outcomes, seconds: 0.01,
                                 requestedConcurrency: 1, peakConcurrency: 1)
    }

    private func pump(_ seconds: TimeInterval = 0.01) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    }

    @discardableResult
    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        XCTFail("\(what)：\(timeout) s 内没有成立")
        return false
    }

    private func onlyTask(in store: BackgroundTaskStore) throws -> BackgroundTask {
        let task = try XCTUnwrap(store.tasks.first, "后台面板里没有任务")
        XCTAssertEqual(store.tasks.count, 1, "一次导出只能产生一条任务")
        return task
    }

    // MARK: - 1 · 点导出即收起，而批次仍在跑

    func testExportDismissesTheSheetImmediatelyAndKeepsRunning() throws {
        let parent = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                                      styleMask: [.titled, .closable, .resizable],
                                      backing: .buffered, defer: false)
        TestWindows.show(parent, key: true)

        let session = CatalogSession(remembersRecentLibrary: false)
        let controller = ExportSheetController(session: session)
        controller.present(in: parent)
        XCTAssertTrue(controller.isPresented)

        let batchItems = items(["a", "b", "c"])
        controller.setItemsForTesting(batchItems,
                                      thumbKeys: ["a": "thumb-a", "b": "thumb-b", "c": "thumb-c"])

        let entered = expectation(description: "fake batch started")
        let gate = DispatchSemaphore(value: 0)
        controller.model.batchRun = { items, _, _, _, _ in
            entered.fulfill()
            gate.wait()
            // All failures: the dismissal test must not write a draft into the developer's defaults.
            return self.report(items, failures: Set(items.map(\.id)))
        }

        XCTAssertTrue(controller.runExport())
        wait(for: [entered], timeout: 2)
        XCTAssertEqual(controller.dismissCount, 1, "点导出必须收起，且只收一次")
        XCTAssertFalse(controller.isPresented, "sheet 不该继续展示")

        // The batch is still inside `gate.wait()` here: 收起 ≠ 取消.
        XCTAssertEqual(session.backgroundTasks.tasks.first?.state, .running)
        let panel = BackgroundTasksPopover(store: session.backgroundTasks)
        panel.loadViewIfNeeded()
        panel.reload()
        XCTAssertTrue(panel.rowTextForTesting(at: 0)?.contains("0/3") ?? false)
        XCTAssertEqual(panel.rowHasCancelButtonForTesting(at: 0), true, "运行中的行必须有取消")

        gate.signal()
        waitUntil("后台任务没有收尾") {
            session.backgroundTasks.tasks.first?.state.isTerminal == true
        }
        XCTAssertEqual(controller.dismissCount, 1, "收尾不许再 dismiss 一次")
    }

    // MARK: - 2 · 进度按回调自增，不按 index 推

    func testProgressCountsCallbacksInArrivalOrderNotRequestOrder() throws {
        let store = BackgroundTaskStore()
        let sheet = model(store: store)
        let batchItems = items(["a", "b", "c"])
        let finished = expectation(description: "fake batch finished")
        var observed: [Int] = []

        sheet.batchRun = { items, preset, _, _, render in
            for index in [2, 0, 1] {
                _ = try? render(items[index], preset)
                // Drain the markRendered hop, then read the row's count on the same main actor.
                DispatchQueue.main.sync {}
                DispatchQueue.main.sync { observed.append(store.tasks.first?.completed ?? -1) }
            }
            finished.fulfill()
            return self.report(items)
        }

        XCTAssertTrue(sheet.run(items: batchItems,
                                thumbKeys: ["a": "thumb-a", "b": "thumb-b", "c": "thumb-c"]))
        wait(for: [finished], timeout: 2)
        waitUntil("任务没有 finished") { store.tasks.first?.state == .finished }

        XCTAssertEqual(observed, [1, 2, 3], "并发 2、回调乱序，计数只能是自增")
        let task = try onlyTask(in: store)
        XCTAssertEqual(BackgroundTaskStore.countText(for: task), "3/3")
        // 549 — a batch keeps 「正在处理的那张」 when it ends, so the panel's square stays on the
        // photo whose render callback arrived last (`b`, not the request-order last `c`). The counts
        // stay on the terminal row.
        XCTAssertEqual(task.currentAssetID, "b")
        XCTAssertEqual(task.currentThumbKey, "thumb-b")
        XCTAssertEqual(BackgroundTaskStore.progressFraction(for: task), 1, accuracy: 0.0001)
    }

    // MARK: - 3 · 取消走面板那一行，后续回调不再推进

    func testCancelFromThePanelCancelsTheTokenAndFreezesTheCount() throws {
        let store = BackgroundTaskStore()
        let sheet = model(store: store)
        let batchItems = items(["a", "b", "c"])
        let firstRender = expectation(description: "first item rendered")
        let runnerReturned = expectation(description: "fake batch returned")
        var tokenWasCancelled = false

        sheet.batchRun = { items, preset, _, token, render in
            _ = try? render(items[0], preset)
            DispatchQueue.main.sync {}
            firstRender.fulfill()
            // Wait for the panel's cancel. The loop is on the worker, not the main actor.
            let deadline = Date().addingTimeInterval(5)
            while !token.isCancelled, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.002)
            }
            if token.isCancelled { DispatchQueue.main.sync { tokenWasCancelled = true } }
            // A late callback after the cancel must not move the row's 12/40.
            _ = try? render(items[1], preset)
            DispatchQueue.main.sync {}
            runnerReturned.fulfill()
            return self.report(items, cancelled: ["b", "c"])
        }

        XCTAssertTrue(sheet.run(items: batchItems))
        wait(for: [firstRender], timeout: 2)
        let taskBefore = try onlyTask(in: store)
        XCTAssertEqual(taskBefore.completed, 1)

        store.cancel(id: taskBefore.id)
        store.cancel(id: taskBefore.id)   // second click: no-op (see the store test below)
        wait(for: [runnerReturned], timeout: 2)
        waitUntil("取消后的任务没有收尾") { store.tasks.first?.state.isTerminal == true }

        let task = try onlyTask(in: store)
        XCTAssertTrue(tokenWasCancelled, "面板的取消必须传到导出的 token")
        XCTAssertEqual(task.state, .cancelled)
        XCTAssertEqual(task.completed, 1, "取消后的回调不许再推进计数")
        XCTAssertEqual(sheet.phase, .finished)
    }

    // MARK: - 4 · 失败只留计数，明细不进面板

    func testFailureClosesAsFailedAndThePanelShowsOnlyTheCounts() throws {
        let store = BackgroundTaskStore()
        let sheet = model(store: store)
        let batchItems = items(["a", "b", "c"])
        let finished = expectation(description: "fake batch finished")

        sheet.batchRun = { items, preset, _, _, render in
            for item in items {
                _ = try? render(item, preset)
                DispatchQueue.main.sync {}
            }
            finished.fulfill()
            return self.report(items, failures: ["c"])
        }

        XCTAssertTrue(sheet.run(items: batchItems))
        wait(for: [finished], timeout: 2)
        waitUntil("失败任务没有收尾") { store.tasks.first?.state == .failed }

        let task = try onlyTask(in: store)
        XCTAssertEqual(task.failureCount, 1)
        XCTAssertEqual(task.completed, 3)

        let panel = BackgroundTasksPopover(store: store)
        panel.loadViewIfNeeded()
        panel.reload()
        let text = try XCTUnwrap(panel.rowTextForTesting(at: 0))
        XCTAssertTrue(text.contains("成功 2 / 失败 1"), text)
        XCTAssertFalse(text.contains("fake failure"), "失败明细不进面板")
        XCTAssertEqual(panel.rowHasCancelButtonForTesting(at: 0), false, "完成态不再显示取消")
    }

    // MARK: - 5 · store 的取消句柄只跑一次

    func testCancelHandleRunsOnceAndForgetDropsIt() {
        let store = BackgroundTaskStore()
        let running = store.begin(BackgroundTask(kind: .export, title: "导出 3 张照片", total: 3))
        var calls = 0
        store.registerCancel(id: running) { calls += 1 }

        store.cancel(id: running)
        store.cancel(id: running)
        XCTAssertEqual(calls, 1, "同一条任务不许取消两次")

        let forgotten = store.begin(BackgroundTask(kind: .export, title: "导出 2 张照片", total: 2))
        store.registerCancel(id: forgotten) { calls += 1 }
        store.forgetCancel(id: forgotten)
        store.cancel(id: forgotten)
        XCTAssertEqual(calls, 1, "forgetCancel 之后不许再跑动作")
    }
}
