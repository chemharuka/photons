import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsUI

/// 510 — 降噪**可排队**：跑起来之后，别的照片还能加进队列；菜单按「选中的照片」判断而不是
/// 「全局有没有活在跑」；执行仍然是并发度 1 的那一条路径。
///
/// 所有用例都用 `nlmfDenoiseBody` 替身（生产代码里既有的接缝），绝不跑 Core ML。并发度用闸门
/// 量：替身进入时 +1、返回时 -1，测试按住一张再放一张；若实现把「串行」改成「并发」，第二张
/// 会在第一张还按住时就进替身，`peakConcurrency` 立刻变成 2。
@MainActor
final class DenoiseQueue510Tests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []
    private var activeGate: Gate?

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-queue510-\(UUID().uuidString)", isDirectory: true)
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
    private func makeSession(dngCount: Int) throws -> Fixture {
        let libraryURL = workDir.appendingPathComponent("S510.\(LibraryLayout.packageExtension)",
                                                       isDirectory: true)
        let catalog = try Catalog.create(at: libraryURL)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)

        var assets: [Asset] = []
        for i in 0..<dngCount {
            let name = String(format: "IMG_%04d.dng", i)
            // A trailing unique byte keeps the copied outputs distinct by hash: `ImportService`
            // dedupes by content hash, and identical outputs would look like duplicates.
            var data = try Data(contentsOf: Self.fixtureURL)
            data.append(contentsOf: Array("queue510-\(i)".utf8))
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

    /// Blocks in the stand-in until a permit arrives, then copies through.
    private func installBlockingBody(on session: CatalogSession, gate: Gate) {
        activeGate = gate
        session.nlmfDenoiseBody = { source, output, _ in
            gate.begin(source.lastPathComponent)
            defer { gate.end() }
            _ = gate.permits.wait(timeout: .now() + 60)
            try FileManager.default.copyItem(at: source, to: output)
            return NLMFDenoiseExecutor.Report(width: 1024, height: 1024, cfa: "rggb",
                                              tiles: 1, seconds: 0.01, byteCount: 1)
        }
    }

    // MARK: - pumping / reading

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    @discardableResult
    private func waitUntil(_ what: String, timeout: TimeInterval = 40,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump(0.01)
        }
        XCTFail("\(what)：\(timeout) s 内没有成立")
        return false
    }

    private func denoiseRows(in session: CatalogSession) -> [BackgroundTask] {
        session.backgroundTasks.tasks.filter { $0.kind == .denoise }
    }

    private func menuRow(_ session: CatalogSession, selectedIDs: [String],
                         engine: DenoiseEngine) -> NSMenuItem {
        let menu = NSMenu()
        DenoiseMenuBuilder.attach(to: menu, session: session,
                                  target: DenoiseMenuTarget(session: session),
                                  selectedIDs: selectedIDs)
        return menu.items.first { $0.title == DenoiseMenuBuilder.title(for: engine) }
            ?? NSMenuItem(title: "<missing>", action: nil, keyEquivalent: "")
    }

    // MARK: - ① 单张开跑；运行中右键 B 可点并排队；A 完成后 B 自动开始；并发峰值 1

    func testSingleRunThenQueuedPhotoStartsWithConcurrencyOne() throws {
        let fixture = try makeSession(dngCount: 2)
        let session = fixture.session
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        let a = fixture.assets[0]
        let b = fixture.assets[1]

        session.selectOnly(a.id)
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [a.id], "A 应当立刻开跑")
        waitUntil("A 没有进执行器") { gate.startedCount == 1 }
        XCTAssertTrue(session.isDenoiseRunning)
        XCTAssertEqual(session.denoiseAssetID, a.id)
        XCTAssertEqual(session.denoiseQueueDepth, 0)

        // 运行中右键 B：**可点**（这是本单的核心口径），原因不是「已有一次降噪在进行」。
        session.selectOnly(b.id)
        let rowForB = menuRow(session, selectedIDs: [b.id], engine: .nonlocal)
        print("① 运行中右键 B：enabled=\(rowForB.isEnabled) toolTip=\(rowForB.toolTip ?? "nil")")
        XCTAssertTrue(rowForB.isEnabled, "别的照片在跑时，B 的降噪菜单必须可点")
        XCTAssertNil(DenoiseMenuBuilder.unavailableReason(session: session, selectedIDs: [b.id],
                                                          engine: .nonlocal))

        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [b.id], "B 应当入队")
        XCTAssertEqual(session.denoiseQueueDepth, 1)
        let notice = session.lastDenoiseQueueNotice ?? ""
        print("① 入队 notice=\(notice) 队列深度=\(session.denoiseQueueDepth)")
        XCTAssertTrue(notice.contains("队列"), "notice 必须写明进了队列：\(notice)")
        XCTAssertNil(session.lastDenoiseError, "排队不是错误")
        XCTAssertTrue(session.denoiseAssetIsQueued(b.id))
        XCTAssertEqual(session.denoiseAssetID, a.id, "B 入队不能抢走 A 的执行位")

        // 放 A：A 完成 → B 自动开始。
        gate.permits.signal()
        waitUntil("B 没有自动开始") { gate.startedCount == 2 }
        let runningWhenBStarted = session.denoiseAssetID
        print("① 序列：startedNames=\(gate.startedNames) B 开始时的 denoiseAssetID="
              + "\(runningWhenBStarted ?? "nil") 峰值并发=\(gate.peakConcurrency)")
        XCTAssertEqual(gate.startedNames, [a.filename, b.filename], "A 先、B 后，顺序不能反")
        XCTAssertEqual(runningWhenBStarted, b.id, "B 开始的那一刻 denoiseAssetID 必须是 B")

        gate.permits.signal()
        waitUntil("B 没有结束") { !session.isDenoiseRunning && session.denoiseQueueDepth == 0 }
        print("① 结束：isDenoiseRunning=\(session.isDenoiseRunning) 深度=\(session.denoiseQueueDepth) "
              + "峰值并发=\(gate.peakConcurrency) 完成数=\(session.denoiseCompletionCount)")
        XCTAssertEqual(gate.peakConcurrency, 1, "并发度必须恒为 1")
        XCTAssertEqual(gate.startedCount, 2)
        XCTAssertEqual(session.denoiseCompletionCount, 2)
        XCTAssertFalse(session.isDenoiseRunning, "⑥ 队列空后 isDenoiseRunning 必须回落")
        XCTAssertNil(session.denoiseAssetID)
    }

    // MARK: - ② 运行中右键 A 灰「正在降噪」；B 已排队时右键 B 灰「已在队列中」；C 仍可点

    func testMenuReasonsArePerPhoto() throws {
        let fixture = try makeSession(dngCount: 3)
        let session = fixture.session
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        let a = fixture.assets[0]
        let b = fixture.assets[1]
        let c = fixture.assets[2]

        session.selectOnly(a.id)
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [a.id])
        waitUntil("A 没有进执行器") { gate.startedCount == 1 }

        session.selectOnly(a.id)
        let rowA = menuRow(session, selectedIDs: [a.id], engine: .nonlocal)
        print("② A：enabled=\(rowA.isEnabled) toolTip=\(rowA.toolTip ?? "nil")")
        XCTAssertFalse(rowA.isEnabled)
        XCTAssertEqual(rowA.toolTip, DenoiseNotices.runningThisPhoto)

        session.selectOnly(b.id)
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [b.id])
        let rowB = menuRow(session, selectedIDs: [b.id], engine: .nonlocal)
        print("② B（已排队）：enabled=\(rowB.isEnabled) toolTip=\(rowB.toolTip ?? "nil")")
        XCTAssertFalse(rowB.isEnabled)
        XCTAssertEqual(rowB.toolTip, DenoiseNotices.alreadyQueued)

        // 第三张既不在跑也不在队列 ⇒ 照旧可点：这是「按选中的照片判断」的另一半。
        session.selectOnly(c.id)
        let rowC = menuRow(session, selectedIDs: [c.id], engine: .nonlocal)
        print("② C：enabled=\(rowC.isEnabled) toolTip=\(rowC.toolTip ?? "nil")")
        XCTAssertTrue(rowC.isEnabled)
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [c.id])
        XCTAssertEqual(session.denoiseQueueDepth, 2, "B、C 都在队列里")

        gate.permits.signal()
        gate.permits.signal()
        gate.permits.signal()
        waitUntil("队列没有清空") { !session.isDenoiseRunning && session.denoiseQueueDepth == 0 }
        XCTAssertEqual(gate.peakConcurrency, 1)
    }

    // MARK: - ③ 批量 3 张在跑时右键第 4 张 ⇒ 可点、入队；批量结束后它才开始

    func testBatchRunningThenQueuedSingleStartsAfterwards() throws {
        let fixture = try makeSession(dngCount: 4)
        let session = fixture.session
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        let batchIDs = fixture.assets.prefix(3).map(\.id)
        let c = fixture.assets[3]

        session.setSelection(Set(batchIDs), anchor: batchIDs[0])
        XCTAssertEqual(session.denoiseBatchSelection(engine: .nonlocal), Array(batchIDs))
        waitUntil("批量第 1 张没有开始") { gate.startedCount == 1 }

        session.selectOnly(c.id)
        let row = menuRow(session, selectedIDs: [c.id], engine: .nonlocal)
        print("③ 批量运行中右键 C：enabled=\(row.isEnabled) toolTip=\(row.toolTip ?? "nil")")
        XCTAssertTrue(row.isEnabled, "批量在跑时，另一张照片的菜单必须可点")
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [c.id])
        XCTAssertEqual(session.denoiseQueueDepth, 1)

        for i in 1...3 {
            waitUntil("批量第 \(i) 张没有开始") { gate.startedCount == i }
            gate.permits.signal()
        }
        waitUntil("C 没有在批量结束后开始") { gate.startedCount == 4 }
        print("③ 序列：startedNames=\(gate.startedNames) C 开始时的 denoiseAssetID="
              + "\(session.denoiseAssetID ?? "nil") 深度=\(session.denoiseQueueDepth)")
        XCTAssertEqual(gate.startedNames, fixture.assets.map(\.filename),
                       "三张批量按顺序跑完，然后才是 C")
        XCTAssertEqual(session.denoiseAssetID, c.id)
        XCTAssertEqual(session.denoiseQueueDepth, 0)

        gate.permits.signal()
        waitUntil("C 没有结束") { !session.isDenoiseRunning }
        print("③ C 完成：堆叠张数=\(session.lastDenoiseReport?.stackCount ?? -1) "
              + "产物 assetID=\(session.lastDenoiseReport?.assetID ?? "nil")")
        XCTAssertEqual(session.lastDenoiseReport?.stackCount, 2, "487：原图 + 产物组成两张的堆叠")
        XCTAssertEqual(gate.peakConcurrency, 1)
    }

    // MARK: - ④ 面板行文本「排队中」；顶栏条只画执行中/已完成的

    /// 「口径修正（覆盖 510 §④）」— owner's 2026-11-23 wording: a waiting row says only 「排队中」.
    /// The 510 parenthetical 「（前面还剩 N 个）」 was clipped by the row's text width, so the
    /// structural assertion is now «the row ends with 排队中 and carries no queue-position text».
    func testPanelShowsQueuedStateAndTopBarSkipsQueued() throws {
        let fixture = try makeSession(dngCount: 3)
        let session = fixture.session
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        let a = fixture.assets[0]
        let b = fixture.assets[1]
        let c = fixture.assets[2]

        session.selectOnly(a.id)
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [a.id])
        waitUntil("A 没有进执行器") { gate.startedCount == 1 }
        session.selectOnly(b.id)
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [b.id])
        session.selectOnly(c.id)
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [c.id])

        let panel = BackgroundTasksPopover(store: session.backgroundTasks)
        let allRows = (0..<session.backgroundTasks.displayTasks.count)
            .compactMap { panel.rowTextForTesting(at: $0) }
        print("④ 面板行：\(allRows)")
        let queuedRows = allRows.filter { $0.contains("排队中") }
        XCTAssertEqual(queuedRows.count, 2, "两条排队项各占一行")
        for row in queuedRows {
            XCTAssertTrue(row.hasSuffix("排队中"),
                          "排队那行的状态就是「排队中」两个字（口径修正 2026-11-23）：\(row)")
            XCTAssertFalse(row.contains("前面还剩"),
                           "队列位置不再写进行文本（会被截断）：\(row)")
        }

        // 顶栏：排队项不画条，只有正在执行的那一条。
        let bars = BackgroundTaskBars()
        bars.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        bars.update(tasks: session.backgroundTasks.displayTasks)
        print("④ 顶栏：visibleTasks=\(bars.visibleTasks.count) 全部任务="
              + "\(session.backgroundTasks.tasks.count) 队列深度=\(session.denoiseQueueDepth)")
        XCTAssertEqual(session.backgroundTasks.tasks.count, 3, "一条执行 + 两条排队")
        XCTAssertEqual(bars.visibleTasks.count, 1, "顶栏只画执行中的那一条")
        XCTAssertEqual(bars.visibleTasks.first?.state, .running)

        gate.permits.signal(); gate.permits.signal(); gate.permits.signal()
        waitUntil("队列没有清空") { !session.isDenoiseRunning && session.denoiseQueueDepth == 0 }
        XCTAssertEqual(gate.peakConcurrency, 1)
    }

    // MARK: - ⑤ 取消当前只停当前、队列继续；clearDenoiseQueue 只清 pending

    func testCancelStopsCurrentOnlyAndClearDropsPending() throws {
        let fixture = try makeSession(dngCount: 4)
        let session = fixture.session
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        let batchIDs = fixture.assets.prefix(2).map(\.id)
        let c = fixture.assets[2]
        let d = fixture.assets[3]

        session.setSelection(Set(batchIDs), anchor: batchIDs[0])
        XCTAssertEqual(session.denoiseBatchSelection(engine: .nonlocal), Array(batchIDs))
        waitUntil("批量第 1 张没有开始") { gate.startedCount == 1 }
        let batchRowID = try XCTUnwrap(denoiseRows(in: session).first?.id)

        session.selectOnly(c.id)
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [c.id])
        session.selectOnly(d.id)
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [d.id])
        XCTAssertEqual(session.denoiseQueueDepth, 2)

        // 取消**当前**（批量那一行）：只看当前项跑完就停，队列不动。
        session.backgroundTasks.cancel(id: batchRowID)
        gate.permits.signal()
        waitUntil("C 没有在被取消的批量之后开始") { gate.startedCount == 2 }
        print("⑤ 取消当前后：sequence=\(gate.startedNames) denoiseAssetID="
              + "\(session.denoiseAssetID ?? "nil") 深度=\(session.denoiseQueueDepth)")
        XCTAssertEqual(gate.startedNames, [fixture.assets[0].filename, c.filename],
                       "被取消的批量只跑完当前项，接着是队列里的 C")
        XCTAssertEqual(session.denoiseAssetID, c.id, "队列继续：C 已经开始")
        XCTAssertEqual(session.denoiseQueueDepth, 1, "D 还在队列里")

        // clearDenoiseQueue 只清 pending，不动正在跑的 C。
        let depthBefore = session.denoiseQueueDepth
        let cleared = session.clearDenoiseQueue()
        print("⑤ 清空队列：清空深度 \(depthBefore) → \(session.denoiseQueueDepth)，"
              + "clearDenoiseQueue()=\(cleared)，C 还在跑=\(session.isDenoiseRunning)")
        XCTAssertEqual(cleared, 1)
        XCTAssertEqual(session.denoiseQueueDepth, 0)
        XCTAssertEqual(session.denoiseAssetID, c.id, "清空队列不能停掉正在跑的那一个")
        XCTAssertTrue(session.isDenoiseRunning)

        gate.permits.signal()
        waitUntil("C 没有结束") { !session.isDenoiseRunning }
        print("⑤ 结束：startedNames=\(gate.startedNames) 峰值并发=\(gate.peakConcurrency) "
              + "isDenoiseRunning=\(session.isDenoiseRunning)")
        XCTAssertEqual(gate.startedNames.count, 2, "D 被清空，不能再跑")
        XCTAssertEqual(gate.peakConcurrency, 1)
        XCTAssertFalse(session.isDenoiseRunning, "⑥ 队列空后 isDenoiseRunning 必须回落 false")
        XCTAssertNil(session.denoiseAssetID)
    }

    // MARK: - 去重：同一张照片永远不会有第二个排队请求

    func testSamePhotoNeverQueuedTwice() throws {
        let fixture = try makeSession(dngCount: 2)
        let session = fixture.session
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        let a = fixture.assets[0]
        let b = fixture.assets[1]

        session.selectOnly(a.id)
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [a.id])
        waitUntil("A 没有进执行器") { gate.startedCount == 1 }
        session.selectOnly(b.id)
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [b.id])

        // 同一张再点一次：拒绝，不新增队列项。
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [], "B 已排队，不能再入队")
        XCTAssertEqual(session.lastDenoiseError, DenoiseNotices.alreadyQueued)
        XCTAssertEqual(session.denoiseQueueDepth, 1)

        session.selectOnly(a.id)
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [], "A 正在跑，不能再入队")
        XCTAssertEqual(session.lastDenoiseError, DenoiseNotices.runningThisPhoto)

        gate.permits.signal(); gate.permits.signal()
        waitUntil("队列没有清空") { !session.isDenoiseRunning }
        XCTAssertEqual(gate.startedCount, 2, "去重之后只跑两张，不会多跑一次")
    }
}
