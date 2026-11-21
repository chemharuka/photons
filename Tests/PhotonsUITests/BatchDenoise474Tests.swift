import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsUI

/// 474 (= 454 P4) — 批量降噪：多选依次跑，一条后台任务、`8/40` 计数、当前照片的方形缩略图键。
///
/// 所有用例都用 `nlmfDenoiseBody` 替身（生产代码里的既有接缝），**绝不**跑 Core ML：
/// 替身把输入原样复制到输出，命名 / 落盘 / 入库 / 继承 / 堆叠仍是生产路径。
///
/// 并发度用闸门量：替身在返回前等一个 `DispatchSemaphore`，测试按住一张再放一张。若实现把
/// 「串行」改成「并发」，第二张会在第一张还按住时就进入替身，`peakConcurrency` 立刻变成 2。
@MainActor
final class BatchDenoise474Tests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []
    /// Signals any blocked stand-in in `tearDown`, so a failed assertion cannot orphan a thread.
    private var activeGate: Gate?

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-batch474-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for _ in 0..<8 { activeGate?.permits.signal() }
        activeGate = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixtures

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters[key] = nil }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    private struct Fixture {
        let session: CatalogSession
        let libraryURL: URL
        let assets: [Asset]
    }

    @discardableResult
    private func makeSession(dngCount: Int, jpgCount: Int = 0) throws -> Fixture {
        let libraryURL = workDir.appendingPathComponent("S474.\(LibraryLayout.packageExtension)",
                                                        isDirectory: true)
        let catalog = try Catalog.create(at: libraryURL)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)

        var assets: [Asset] = []
        for i in 0..<dngCount {
            let name = String(format: "IMG_%04d.dng", i)
            // Each source gets a trailing unique byte so the stand-in's copied outputs have unique
            // content hashes: `ImportService` dedupes by hash, and identical outputs would make every
            // item after the first look like a duplicate (a test artefact, not the batch's bug).
            var data = try Data(contentsOf: Self.fixtureURL)
            data.append(contentsOf: Array("fixture-\(i)".utf8))
            try data.write(to: src.appendingPathComponent(name))
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name,
                              ext: "dng", kind: .raw, size: 1, mtime: 0,
                              contentHash: UUID().uuidString, width: 1024, height: 1024,
                              captureTime: String(format: "2026-05-01T10:%02d:00Z", i),
                              captureLocalDate: "2026-05-01",
                              cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            assets.append(asset)
        }
        for i in 0..<jpgCount {
            let name = String(format: "IMG_%04d.jpg", dngCount + i)
            try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: src.appendingPathComponent(name))
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name,
                              ext: "jpg", kind: .jpeg, size: 4, mtime: 0,
                              contentHash: UUID().uuidString, width: 1024, height: 1024,
                              captureTime: String(format: "2026-05-01T11:%02d:00Z", i),
                              captureLocalDate: "2026-05-01",
                              cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            assets.append(asset)
        }

        let store = MemoryStore()
        let session = CatalogSession(filterStore: store, sortPreferenceStore: store,
                                     remembersRecentLibrary: false)
        try session.open(libraryURL)
        session.setSortOrder(.oldestFirst)
        return Fixture(session: session, libraryURL: libraryURL, assets: assets)
    }

    private func installNLMFModel(on session: CatalogSession) throws {
        let model = workDir.appendingPathComponent("v_matmul_256.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        session.nlmfModelURL = model
    }

    // MARK: - the executor stand-in

    /// Thread-safe bookkeeping for the stand-in executor. A class because the closure is
    /// `@Sendable`; the lock is the only state sharing it needs.
    private final class Gate: @unchecked Sendable {
        let permits = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var starts: [String] = []
        private var active = 0
        private var peak = 0

        func begin(_ name: String) {
            lock.lock()
            starts.append(name)
            active += 1
            peak = max(peak, active)
            lock.unlock()
        }

        func end() {
            lock.lock(); active -= 1; lock.unlock()
        }

        var startedCount: Int {
            lock.lock(); defer { lock.unlock() }
            return starts.count
        }

        var startedNames: [String] {
            lock.lock(); defer { lock.unlock() }
            return starts
        }

        var peakConcurrency: Int {
            lock.lock(); defer { lock.unlock() }
            return peak
        }
    }

    /// A stand-in that records concurrency and then waits for one permit.
    private func installBlockingBody(on session: CatalogSession, gate: Gate) {
        activeGate = gate
        session.nlmfDenoiseBody = { source, output, _ in
            gate.begin(source.lastPathComponent)
            defer { gate.end() }
            _ = gate.permits.wait(timeout: .now() + 30)
            try FileManager.default.copyItem(at: source, to: output)
            return NLMFDenoiseExecutor.Report(width: 1024, height: 1024, cfa: "rggb",
                                              tiles: 1, seconds: 0.01, byteCount: 1)
        }
    }

    /// A stand-in that copies through unless the source's filename is in `failing`.
    private func installBody(on session: CatalogSession, gate: Gate? = nil,
                             failing: Set<String> = []) {
        if let gate { activeGate = gate }
        session.nlmfDenoiseBody = { source, output, _ in
            gate?.begin(source.lastPathComponent)
            defer { gate?.end() }
            if failing.contains(source.lastPathComponent) { throw FakeFailure() }
            try FileManager.default.copyItem(at: source, to: output)
            return NLMFDenoiseExecutor.Report(width: 1024, height: 1024, cfa: "rggb",
                                              tiles: 1, seconds: 0.01, byteCount: 1)
        }
    }

    private struct FakeFailure: Error {}

    // MARK: - pumping / reading

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    @discardableResult
    private func waitUntil(_ what: String, timeout: TimeInterval = 30,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump(0.01)
        }
        XCTFail("\(what)：\(timeout) s 内没有成立")
        return false
    }

    private func task(in session: CatalogSession) throws -> BackgroundTask {
        let tasks = session.backgroundTasks.tasks.filter { $0.kind == .denoise }
        return try XCTUnwrap(tasks.last)
    }

    private func waitForTerminal(_ session: CatalogSession) {
        waitUntil("批次没有结束") { (try? self.task(in: session))?.state.isTerminal == true }
    }

    // MARK: - ① 5 张串行：completed 1…5，并发度 1

    func testFivePhotosAdvanceSeriallyWithConcurrencyOne() throws {
        let fixture = try makeSession(dngCount: 5)
        let session = fixture.session
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        session.setSelection(Set(fixture.assets.map(\.id)), anchor: fixture.assets[0].id)

        let participants = session.denoiseBatchSelection(engine: .nonlocal)
        XCTAssertEqual(participants.count, 5)
        let initial = try task(in: session)
        XCTAssertEqual(initial.kind, .denoise)
        XCTAssertEqual(initial.title, "降噪 5 张")
        XCTAssertEqual(initial.total, 5)
        XCTAssertEqual(initial.completed, 0)

        var completedAtEachStart: [Int] = []
        for i in 1...5 {
            waitUntil("第 \(i) 张没有开始") { gate.startedCount == i }
            let during = try task(in: session)
            completedAtEachStart.append(during.completed)
            XCTAssertEqual(during.currentAssetID, participants[i - 1],
                           "第 \(i) 张开始时 currentAssetID 必须是它")
            gate.permits.signal()
        }
        waitForTerminal(session)

        let done = try task(in: session)
        print("① 5 张串行：completed=\(done.completed)/\(done.total) state=\(done.state.rawValue) "
              + "failure=\(done.failureCount) starts=\(completedAtEachStart) "
              + "peak=\(gate.peakConcurrency)")
        XCTAssertEqual(completedAtEachStart, [0, 1, 2, 3, 4],
                       "每张开始前，前一张必须已经 advance")
        XCTAssertEqual(done.completed, 5)
        XCTAssertEqual(done.state, .finished)
        XCTAssertEqual(done.failureCount, 0)
        XCTAssertEqual(gate.peakConcurrency, 1, "同一时刻只能有一个 executor 在跑")
        XCTAssertEqual(gate.startedCount, 5)
        XCTAssertFalse(session.isDenoiseRunning)
    }

    // MARK: - ② 当前照片 / 缩略图；整批结束后清空

    func testCurrentPhotoAndThumbnailFollowTheRunningItem() throws {
        let fixture = try makeSession(dngCount: 3)
        let session = fixture.session
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        session.setSelection(Set(fixture.assets.map(\.id)), anchor: fixture.assets[0].id)

        let participants = session.denoiseBatchSelection(engine: .nonlocal)
        let byID = Dictionary(uniqueKeysWithValues: fixture.assets.map { ($0.id, $0) })

        for i in 1...3 {
            waitUntil("第 \(i) 张没有开始") { gate.startedCount == i }
            let during = try task(in: session)
            let expected = try XCTUnwrap(byID[participants[i - 1]])
            XCTAssertEqual(during.currentAssetID, expected.id)
            XCTAssertEqual(during.currentThumbKey,
                           ThumbnailProvider.hdJPEGKey(for: expected).keyString,
                           "面板的方形缩略图键必须是侧栏同款 hdJPEG")
            gate.permits.signal()
        }
        waitForTerminal(session)

        let done = try task(in: session)
        print("② 当前照片：state=\(done.state.rawValue) currentAssetID=\(done.currentAssetID ?? "nil") "
              + "currentThumbKey=\(done.currentThumbKey ?? "nil")")
        XCTAssertEqual(done.state, .finished)
        // 本单写死这一种：整批结束后没有「当前照片」（面板不再画一个已经不在跑的照片）。
        XCTAssertNil(done.currentAssetID)
        XCTAssertNil(done.currentThumbKey)
    }

    // MARK: - ③ 取消：当前这张跑完，下一张不开始

    func testCancelLetsTheRunningItemFinishAndStartsNothingAfterIt() throws {
        let fixture = try makeSession(dngCount: 3)
        let session = fixture.session
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        session.setSelection(Set(fixture.assets.map(\.id)), anchor: fixture.assets[0].id)

        let participants = session.denoiseBatchSelection(engine: .nonlocal)
        let taskID = try XCTUnwrap(session.backgroundTasks.tasks.first?.id)

        waitUntil("第 1 张没有开始") { gate.startedCount == 1 }
        gate.permits.signal()
        waitUntil("第 2 张没有开始") { gate.startedCount == 2 }
        XCTAssertEqual(try task(in: session).completed, 1)

        // 取消只立一个 flag：当前这张仍被按在替身里，任务还在 running。
        session.backgroundTasks.cancel(id: taskID)
        pump(0.1)
        let during = try task(in: session)
        XCTAssertEqual(gate.startedCount, 2, "取消不许立刻开始第 3 张")
        XCTAssertEqual(during.state, .running, "当前这张没跑完，任务不许提前终止")
        XCTAssertEqual(during.completed, 1)

        gate.permits.signal()
        waitForTerminal(session)

        let done = try task(in: session)
        print("③ 取消：state=\(done.state.rawValue) completed=\(done.completed)/\(done.total) "
              + "starts=\(done.currentAssetID ?? "nil") gateStarts=\(gate.startedCount)")
        XCTAssertEqual(gate.startedCount, 2, "第 3 张不许开始")
        XCTAssertEqual(done.state, .cancelled)
        XCTAssertEqual(done.completed, 2, "当前那张的完成回调仍被消费")
        XCTAssertEqual(session.denoiseCompletionCount, 2)
    }

    // MARK: - ④ 失败继续；全失败 ⇒ .failed

    func testAFailedItemIsCountedAndTheNextStillRuns() throws {
        let fixture = try makeSession(dngCount: 3)
        let session = fixture.session
        try installNLMFModel(on: session)
        session.setSelection(Set(fixture.assets.map(\.id)), anchor: fixture.assets[0].id)

        let ordered = session.selectedAssets
        let failingName = ordered[1].filename
        installBody(on: session, failing: [failingName])

        let participants = session.denoiseBatchSelection(engine: .nonlocal)
        XCTAssertEqual(participants.count, 3)
        waitForTerminal(session)

        let done = try task(in: session)
        print("④ 失败继续：state=\(done.state.rawValue) failure=\(done.failureCount) "
              + "completed=\(done.completed)/\(done.total)")
        XCTAssertEqual(done.failureCount, 1)
        XCTAssertEqual(done.state, .finished)
        XCTAssertEqual(done.completed, 3)
    }

    func testAllItemsFailingClosesTheTaskAsFailed() throws {
        let fixture = try makeSession(dngCount: 2)
        let session = fixture.session
        try installNLMFModel(on: session)
        session.setSelection(Set(fixture.assets.map(\.id)), anchor: fixture.assets[0].id)
        installBody(on: session, failing: Set(fixture.assets.map(\.filename)))

        session.denoiseBatchSelection(engine: .nonlocal)
        waitForTerminal(session)

        let done = try task(in: session)
        print("④b 全失败：state=\(done.state.rawValue) failure=\(done.failureCount) "
              + "completed=\(done.completed)/\(done.total)")
        XCTAssertEqual(done.state, .failed)
        XCTAssertEqual(done.failureCount, 2)
        XCTAssertEqual(done.completed, 2)
    }

    // MARK: - ⑤ 单选不回归：仍是单张路径，HUD 仍出现

    func testSingleSelectionStillUsesTheSinglePhotoPathAndShowsTheHUD() throws {
        _ = NSApplication.shared
        let fixture = try makeSession(dngCount: 1)
        let session = fixture.session
        let asset = try XCTUnwrap(fixture.assets.first)
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        session.selectOnly(asset.id)
        session.mode = .loupe

        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let window = TestWindows.make(contentRect: NSRect(origin: TestWindows.offscreen,
                                                          size: NSSize(width: 900, height: 600)),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = loupe.view
        TestWindows.show(window)
        windows.append(window)
        loupe.view.layoutSubtreeIfNeeded()
        pump(0.05)

        session.denoiseSelection(engine: .nonlocal)
        waitUntil("单张的 HUD 没有出现") { loupe.denoiseHUDStateForTesting == .running }
        let taskID = try XCTUnwrap(session.backgroundTasks.tasks.first?.id)
        gate.permits.signal()
        waitUntil("单张降噪没有结束") {
            (try? self.task(in: session))?.state.isTerminal == true
        }
        _ = taskID

        let done = try task(in: session)
        print("⑤ 单张：title=\(done.title) state=\(done.state.rawValue) "
              + "count=\(BackgroundTaskStore.countText(for: done)) hudWasRunning=true")
        XCTAssertEqual(done.kind, .denoise)
        XCTAssertEqual(done.total, 1)
        XCTAssertEqual(BackgroundTaskStore.countText(for: done), "1/1")
        XCTAssertEqual(done.title, asset.filename)
        XCTAssertEqual(done.state, .finished)
    }

    // MARK: - ⑥ 混合选择：3 张可用 + 1 张不支持 ⇒ total 3 + 「已跳过 1 张」

    func testMixedSelectionFiltersUnsupportedPhotosAndReportsTheSkip() throws {
        let fixture = try makeSession(dngCount: 3, jpgCount: 1)
        let session = fixture.session
        try installNLMFModel(on: session)
        installBody(on: session)
        session.setSelection(Set(fixture.assets.map(\.id)), anchor: fixture.assets[0].id)

        // The real menu row, built by the same builder the grid / filmstrip / list use.
        let menu = NSMenu()
        let target = DenoiseMenuTarget(session: session)
        var notice: String?
        target.presentBatchSkipNotice = { notice = $0 }
        DenoiseMenuBuilder.attach(to: menu, session: session, target: target,
                                  selectedIDs: fixture.assets.map(\.id))
        let row = try XCTUnwrap(menu.items.first {
            $0.title == DenoiseMenuBuilder.batchTitle(count: 4)
        }, "多选缺「降噪 4 张…」: \(menu.items.map(\.title))")
        XCTAssertTrue(row.isEnabled)
        XCTAssertEqual(row.action, #selector(DenoiseMenuTarget.batchDenoisePressed(_:)))

        target.batchDenoisePressed(nil)
        waitForTerminal(session)

        let done = try task(in: session)
        print("⑥ 混合选择：total=\(done.total) state=\(done.state.rawValue) "
              + "skipped=\(session.lastDenoiseBatchSkippedCount) notice=\(notice ?? "nil")")
        XCTAssertEqual(done.total, 3)
        XCTAssertEqual(done.state, .finished)
        XCTAssertEqual(session.lastDenoiseBatchSkippedCount, 1)
        XCTAssertTrue(notice?.contains("已跳过 1 张") == true,
                      "alert 必须明确说跳过了几张：\(notice ?? "nil")")
        XCTAssertEqual(session.lastDenoiseBatchSkipNotice, notice)
    }

    // MARK: - 编辑菜单：≥ 2 张才出现，单张隐藏

    func testEditMenuBatchRowAppearsOnlyForMultiSelection() throws {
        _ = NSApplication.shared
        let fixture = try makeSession(dngCount: 3)
        let controller = EditorWindowController()
        if let window = controller.window {
            TestWindows.adopt(window)
            windows.append(window)
        }
        try controller.openLibrary(at: fixture.libraryURL)
        let session = controller.session
        session.setSortOrder(.oldestFirst)

        let appMenu = MainMenu.build()
        let edit = try XCTUnwrap(appMenu.items.first { $0.submenu?.title == "编辑" }?.submenu)
        let row = try XCTUnwrap(controller.installBatchDenoiseMenuItem(in: edit))

        let probe = NSMenuItem(title: "", action: #selector(EditorWindowController.batchDenoiseAction(_:)),
                               keyEquivalent: "")
        session.selectOnly(try XCTUnwrap(session.assets.first).id)
        XCTAssertFalse(controller.validateMenuItem(probe), "单张不出现")
        XCTAssertTrue(probe.isHidden)

        let ids = session.assets.prefix(2).map(\.id)
        session.setSelection(Set(ids), anchor: ids.first)
        XCTAssertTrue(controller.validateMenuItem(probe), "多选可点")
        XCTAssertFalse(probe.isHidden)
        XCTAssertEqual(probe.title, "降噪 2 张…")
        XCTAssertEqual(row.action, #selector(EditorWindowController.batchDenoiseAction(_:)))
    }
}
