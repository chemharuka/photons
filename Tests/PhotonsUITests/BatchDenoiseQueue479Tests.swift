import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsUI

/// §479 — 批量降噪：排队中的照片显示「等待降噪 / 宽×高 / 0:00」，轮到时变「降噪中」并计时。
///
/// 用户口径：只有正在跑的那一张有卡片；后面排队的几张在翻到它们时也要有卡片，但时间是 `0:00`，
/// 直到批次推进到它，标题才变「降噪中」、计时才从 0 开始。
///
/// 所有用例都用 `nlmfDenoiseBody` 替身（474 的既有接缝）把批次按住，**不跑 Core ML**：
/// 「排队」与「轮到」因此是测试自己控制的两个状态，而不是靠 sleep 去撞。
@MainActor
final class BatchDenoiseQueue479Tests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []
    private var activeGate: Gate?

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-batch479-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for _ in 0..<8 { activeGate?.permits.signal() }
        activeGate = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixture

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
        let assets: [Asset]
    }

    /// `sizes[i]` is the stored `width`/`height` of the i-th asset — the card's second line reads these
    /// rows, not the pixels of the (1024²) fixture.
    @discardableResult
    private func makeSession(sizes: [(Int, Int)]) throws -> Fixture {
        let libraryURL = workDir.appendingPathComponent("S479.\(LibraryLayout.packageExtension)",
                                                        isDirectory: true)
        let catalog = try Catalog.create(at: libraryURL)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)

        var assets: [Asset] = []
        for (i, size) in sizes.enumerated() {
            let name = String(format: "IMG_%04d.dng", i)
            // A unique trailing byte per source: the stand-in copies through, and `ImportService`
            // dedupes by content hash — identical outputs would make items look like duplicates.
            var data = try Data(contentsOf: Self.fixtureURL)
            data.append(contentsOf: Array("batch479-\(i)".utf8))
            try data.write(to: src.appendingPathComponent(name))
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name,
                              ext: "dng", kind: .raw, size: 1, mtime: 0,
                              contentHash: UUID().uuidString, width: size.0, height: size.1,
                              captureTime: String(format: "2026-05-01T10:%02d:00Z", i),
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
        return Fixture(session: session, assets: assets)
    }

    private func installNLMFModel(on session: CatalogSession) throws {
        let model = workDir.appendingPathComponent("v_matmul_256.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        session.nlmfModelURL = model
    }

    private final class Gate: @unchecked Sendable {
        let permits = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var starts: [String] = []

        func begin(_ name: String) {
            lock.lock(); starts.append(name); lock.unlock()
        }

        var startedCount: Int {
            lock.lock(); defer { lock.unlock() }
            return starts.count
        }
    }

    private func installBlockingBody(on session: CatalogSession, gate: Gate) {
        activeGate = gate
        session.nlmfDenoiseBody = { source, output, _ in
            gate.begin(source.lastPathComponent)
            _ = gate.permits.wait(timeout: .now() + 30)
            try FileManager.default.copyItem(at: source, to: output)
            return NLMFDenoiseExecutor.Report(width: 1024, height: 1024, cfa: "rggb",
                                              tiles: 1, seconds: 0.01, byteCount: 1)
        }
    }

    private func makeLoupe(session: CatalogSession, anchor: String)
        throws -> LoupeController {
        _ = NSApplication.shared
        // Move the anchor without collapsing the batch's selection (the batch is built from the
        // selection captured when `denoiseBatchSelection` runs).
        if session.selection.isEmpty {
            session.selectOnly(anchor)
        } else {
            session.setSelection(session.selection, anchor: anchor)
        }
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
        return loupe
    }

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

    private func releaseEverything(_ gate: Gate, session: CatalogSession) {
        for _ in 0..<8 { gate.permits.signal() }
        waitUntil("批次没有结束") { (try? self.task(in: session))?.state.isTerminal == true }
    }

    /// The batch fixture: 4 selected DNGs, item 3 is 6000×4000 (the acceptance's dimensions), plus an
    /// optional 5th photo that is **not** in the batch (for 「不在队列里」).
    private func startBatch(extraOutside: Bool = false)
        throws -> (session: CatalogSession, assets: [Asset], gate: Gate, loupe: LoupeController,
                   taskID: UUID, participants: [String]) {
        var sizes = Array(repeating: (1024, 1024), count: 4)
        sizes[2] = (6000, 4000)                       // item 3 — the queued card's second line
        if extraOutside { sizes.append((1024, 1024)) }
        let fixture = try makeSession(sizes: sizes)
        let session = fixture.session
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)

        let inBatch = Array(fixture.assets.prefix(4))
        session.setSelection(Set(inBatch.map(\.id)), anchor: inBatch[0].id)
        let anchor = extraOutside ? fixture.assets[4].id : inBatch[2].id
        let loupe = try makeLoupe(session: session, anchor: anchor)

        let participants = session.denoiseBatchSelection(engine: .nonlocal)
        XCTAssertEqual(participants.count, 4)
        let taskID = try XCTUnwrap(session.backgroundTasks.tasks.first?.id)
        waitUntil("第 1 张没有开始") { gate.startedCount == 1 }
        return (session, fixture.assets, gate, loupe, taskID, participants)
    }

    // MARK: - ① queued 文案：等待降噪 / 6000×4000 / 0:00

    func testAQueuedPhotoShowsWaitingToDenoiseAndTheDimensions() throws {
        let run = try startBatch()
        waitUntil("第 3 张没有显示 .queued") { run.loupe.denoiseHUDStateForTesting == .queued }
        let laydown = try XCTUnwrap(run.loupe.denoiseLaydownForTesting)

        print("① 排队中：state=\(run.loupe.denoiseHUDStateForTesting) lines=\(laydown.lines) "
              + "bounds=\(NSStringFromRect(laydown.bounds))")

        XCTAssertEqual(run.loupe.denoiseHUDStateForTesting, .queued)
        XCTAssertEqual(laydown.lines, ["等待降噪", "6000×4000", "0:00"])
        XCTAssertEqual(laydown.lines.count, 3)
        XCTAssertEqual(run.session.denoiseAssetID, run.assets[0].id, "① 正在跑的仍是第 1 张")
        XCTAssertTrue(run.session.denoiseQueuedAssetIDs.contains(run.assets[2].id),
                      "① 第 3 张必须被 session 的只读接缝列为排队")

        releaseEverything(run.gate, session: run.session)
    }

    // MARK: - ② queued 不计时：1.2 s 后仍是 0:00，且没有 ticker

    func testAQueuedPhotoNeverTicks() throws {
        let run = try startBatch()
        waitUntil("第 3 张没有显示 .queued") { run.loupe.denoiseHUDStateForTesting == .queued }
        XCTAssertFalse(run.loupe.isDenoiseTimerRunningForTesting, "② 排队时 ticker 必须是死的")
        XCTAssertEqual(run.loupe.liveDenoiseTickerCountForTesting, 0,
                       "② 创建过的 timer 里活着的必须为 0（不是只把字段置 nil）")

        pump(1.2)
        let laydown = try XCTUnwrap(run.loupe.denoiseLaydownForTesting)
        print("② 排队停 1.2 s：lines=\(laydown.lines) 计时器=\(run.loupe.isDenoiseTimerRunningForTesting) "
              + "活 timer=\(run.loupe.liveDenoiseTickerCountForTesting)")

        XCTAssertEqual(run.loupe.denoiseHUDStateForTesting, .queued)
        XCTAssertEqual(laydown.lines[2], "0:00", "② 排队期间时间必须一直是 0:00")
        XCTAssertFalse(run.loupe.isDenoiseTimerRunningForTesting)
        XCTAssertEqual(run.loupe.liveDenoiseTickerCountForTesting, 0)

        releaseEverything(run.gate, session: run.session)
    }

    // MARK: - ③ 轮到它：标题变「降噪中」，1.2 s 后 0:01

    func testWhenItsTurnComesTheCardBecomesRunningAndCounts() throws {
        let run = try startBatch()
        waitUntil("第 3 张没有先显示 .queued") { run.loupe.denoiseHUDStateForTesting == .queued }
        XCTAssertEqual(try XCTUnwrap(run.loupe.denoiseLaydownForTesting).lines.first, "等待降噪")

        // Let item 1 finish, then item 2 finish; item 3 then becomes the running photo (blocked in the
        // stand-in, so its clock is observable for as long as the test needs).
        run.gate.permits.signal()
        waitUntil("第 2 张没有开始") { run.gate.startedCount == 2 }
        run.gate.permits.signal()
        waitUntil("第 3 张没有轮到") {
            run.session.denoiseAssetID == run.assets[2].id
                && run.loupe.denoiseHUDStateForTesting == .running
        }
        let atStart = try XCTUnwrap(run.loupe.denoiseLaydownForTesting)
        print("③ 轮到第 3 张：lines=\(atStart.lines) 计时器=\(run.loupe.isDenoiseTimerRunningForTesting)")
        XCTAssertEqual(atStart.lines[0], "降噪中")
        XCTAssertEqual(atStart.lines[1], "6000×4000")
        XCTAssertTrue(run.loupe.isDenoiseTimerRunningForTesting, "③ 轮到后计时器必须在跑")

        pump(1.2)
        let after = try XCTUnwrap(run.loupe.denoiseLaydownForTesting)
        print("③ 轮到后 1.2 s：lines=\(after.lines)")
        XCTAssertEqual(run.loupe.denoiseHUDStateForTesting, .running)
        XCTAssertEqual(after.lines[0], "降噪中")
        XCTAssertEqual(after.lines[2], "0:01", "③ 1.2 s 后必须读到 0:01")

        releaseEverything(run.gate, session: run.session)
    }

    // MARK: - ④ 不在队列里的照片：.hidden

    func testAPhotoOutsideTheBatchShowsNothing() throws {
        let run = try startBatch(extraOutside: true)
        waitUntil("第 1 张没有开始") { run.session.denoiseAssetID == run.assets[0].id }
        pump(0.15)

        print("④ 翻到队列外的第 5 张：anchorID=\(run.session.anchorID ?? "nil") "
              + "队列=\(run.session.denoiseQueuedAssetIDs.count) state="
              + "\(run.loupe.denoiseHUDStateForTesting) laydown="
              + "\(String(describing: run.loupe.denoiseLaydownForTesting))")

        XCTAssertEqual(run.loupe.denoiseHUDStateForTesting, .hidden)
        XCTAssertNil(run.loupe.denoiseLaydownForTesting)
        XCTAssertTrue(run.session.isDenoiseRunning, "④ 批次还在跑，只是这张不在其中")
        XCTAssertFalse(run.session.denoiseQueuedAssetIDs.contains(run.session.anchorID ?? ""))

        releaseEverything(run.gate, session: run.session)
    }

    // MARK: - ⑤ 排队时取消：立刻 .hidden，ticker 为 nil

    func testCancellingWhileQueuedTakesTheCardDownAtOnce() throws {
        let run = try startBatch()
        waitUntil("第 3 张没有显示 .queued") { run.loupe.denoiseHUDStateForTesting == .queued }

        run.session.backgroundTasks.cancel(id: run.taskID)
        waitUntil("取消后没有变 .hidden") { run.loupe.denoiseHUDStateForTesting == .hidden }
        pump(0.1)

        print("⑤ 排队中取消：state=\(run.loupe.denoiseHUDStateForTesting) laydown="
              + "\(String(describing: run.loupe.denoiseLaydownForTesting)) "
              + "计时器=\(run.loupe.isDenoiseTimerRunningForTesting) "
              + "批量活跃=\(run.session.denoiseBatchIsActive) 队列=\(run.session.denoiseQueuedAssetIDs.count)")

        XCTAssertEqual(run.loupe.denoiseHUDStateForTesting, .hidden)
        XCTAssertNil(run.loupe.denoiseLaydownForTesting, "⑤ 不许留一张 0:00 的残卡")
        XCTAssertFalse(run.loupe.isDenoiseTimerRunningForTesting)
        XCTAssertEqual(run.loupe.liveDenoiseTickerCountForTesting, 0)
        XCTAssertFalse(run.session.denoiseBatchIsActive)
        XCTAssertTrue(run.session.denoiseQueuedAssetIDs.isEmpty, "⑤ 取消后队列里不该还有「等待降噪」")

        releaseEverything(run.gate, session: run.session)
        let done = try task(in: run.session)
        XCTAssertEqual(done.state, .cancelled)
    }

    // MARK: - ⑥ 固定框：.running 与 .queued 都是 boxSize

    func testTheBoxKeepsItsFixedSizeInEveryVisibleState() throws {
        let run = try startBatch()

        // .running — the photo being denoised.
        run.session.selectOnly(run.assets[0].id)
        waitUntil("第 1 张没有显示 .running") { run.loupe.denoiseHUDStateForTesting == .running }
        let running = try XCTUnwrap(run.loupe.denoiseLaydownForTesting)
        XCTAssertEqual(running.bounds.size, DenoiseProgressOverlay.boxSize)

        // .queued — the same 180 × 74 with a longer title and 6000×4000.
        run.session.selectOnly(run.assets[2].id)
        waitUntil("第 3 张没有显示 .queued") { run.loupe.denoiseHUDStateForTesting == .queued }
        let queued = try XCTUnwrap(run.loupe.denoiseLaydownForTesting)
        print("⑥ 固定框：running=\(running.lines) \(running.bounds.size) · "
              + "queued=\(queued.lines) \(queued.bounds.size) · boxSize="
              + "\(DenoiseProgressOverlay.boxSize)")
        XCTAssertEqual(queued.bounds.size, DenoiseProgressOverlay.boxSize)
        XCTAssertEqual(running.bounds.size, queued.bounds.size)

        // .hidden — no frame at all (387's resting state).
        run.session.backgroundTasks.cancel(id: run.taskID)
        waitUntil("取消后没有变 .hidden") { run.loupe.denoiseHUDStateForTesting == .hidden }
        XCTAssertNil(run.loupe.denoiseLaydownForTesting)

        releaseEverything(run.gate, session: run.session)
    }
}
