import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsUI

/// 524 (= 529) — 降噪「完成一张就落堆叠可见」，且完成后不抢走用户当前的照片。
///
/// 两条验收读的是同一段收尾路径：
///   · 批量：每一项成功就 `reloadKeepingSelection()`，新堆叠立刻在投影里；
///     `selection` / `anchorID` / `selectionBase` 逐字段不变（旧实现在整批结束时
///     `selectOnly(last)`，所以用例 2 是反向门）。
///   · 单张：原图变成堆叠成员、格子画的是顶点，选择跟随**该条目的顶点**；模式不变、没有窗口激活。
///
/// 全部用 `nlmfDenoiseBody` 替身（474 的既有接缝），不跑 Core ML。
@MainActor
final class DenoiseStreaming524Tests: XCTestCase {

    private var workDir: URL!
    private var activeGate: Gate?

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-stream524-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for _ in 0..<8 { activeGate?.permits.signal() }
        activeGate = nil
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
        let assets: [Asset]
    }

    @discardableResult
    private func makeSession(dngCount: Int) throws -> Fixture {
        let libraryURL = workDir.appendingPathComponent("S524.\(LibraryLayout.packageExtension)",
                                                        isDirectory: true)
        let catalog = try Catalog.create(at: libraryURL)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)

        var assets: [Asset] = []
        for i in 0..<dngCount {
            let name = String(format: "IMG_%04d.dng", i)
            // Unique trailing bytes per source: the stand-in copies through and `ImportService`
            // dedupes by content hash, so identical outputs would look like duplicates.
            var data = try Data(contentsOf: Self.fixtureURL)
            data.append(contentsOf: Array("stream524-\(i)".utf8))
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
        return Fixture(session: session, assets: assets)
    }

    private func installNLMFModel(on session: CatalogSession) throws {
        let model = workDir.appendingPathComponent("v_matmul_256.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        session.nlmfModelURL = model
    }

    /// Thread-safe stand-in bookkeeping: a gate that holds one item at a time and records starts.
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

    private func releaseEverything(_ gate: Gate, session: CatalogSession) {
        for _ in 0..<8 { gate.permits.signal() }
        waitForTerminal(session)
    }

    /// The stack whose members include `assetID`, as the projection draws it.
    private func stackTop(of assetID: String, in session: CatalogSession) -> String? {
        session.stacksByTopID.values.first { $0.memberIDs.contains(assetID) }?.topID
    }

    // MARK: - ① 第一项完成：堆叠已经可见；选择三字段不动

    func testTheFirstFinishedItemBecomesVisibleWithoutMovingTheSelection() throws {
        let fixture = try makeSession(dngCount: 3)
        let session = fixture.session
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        let ids = fixture.assets.map(\.id)
        session.setSelection(Set(ids), anchor: ids[0])

        let beforeSelection = session.selection
        let beforeAnchor = session.anchorID
        let beforeBase = session.selectionBase
        let beforeMissing = session.stackTopIDsWithMissingMembers

        let participants = session.denoiseBatchSelection(engine: .nonlocal)
        XCTAssertEqual(participants.count, 3)

        waitUntil("第 1 张没有开始") { gate.startedCount == 1 }
        gate.permits.signal()
        // Item 2 starts only from item 1's main-actor completion, so this is 「第 1 项已完成」.
        waitUntil("第 2 张没有开始") { gate.startedCount == 2 }

        let top = stackTop(of: ids[0], in: session)
        print("① 第 1 项完成：top=\(top ?? "nil") selection=\(session.selection.sorted()) "
              + "anchor=\(session.anchorID ?? "nil") base=\(session.selectionBase ?? "nil") "
              + "assets=\(session.assets.count) reload=\(session.lastDenoiseItemReloadSeconds * 1000) ms")

        let unwrappedTop = try XCTUnwrap(top, "第 1 项完成后 stacksByTopID 必须已含该产物")
        XCTAssertTrue(session.assets.contains { $0.id == unwrappedTop },
                      "产物必须已经出现在可见投影里")
        XCTAssertEqual(session.stacksByTopID[unwrappedTop]?.memberIDs.count, 2)
        XCTAssertEqual(session.stackTopIDsWithMissingMembers, beforeMissing,
                       "文件都在，缺成员标记不许被这次刷新改变")
        XCTAssertTrue(session.stackTopIDsWithMissingMembers.isEmpty)

        XCTAssertEqual(session.selection, beforeSelection, "① 选择逐字段不变（含还没跑完的原图）")
        XCTAssertEqual(session.anchorID, beforeAnchor, "① 锚点不变")
        XCTAssertEqual(session.selectionBase, beforeBase, "① 范围基点不变")

        releaseEverything(gate, session: session)
    }

    // MARK: - ② 整批完成：选择仍是开工前那一组（旧实现这里等于最后一个产物 ⇒ 反向门）

    func testTheWholeBatchKeepsTheSelectionAndReportsTheReloadCost() throws {
        let fixture = try makeSession(dngCount: 3)
        let session = fixture.session
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        let ids = fixture.assets.map(\.id)
        session.setSelection(Set(ids), anchor: ids[0])

        let beforeSelection = session.selection
        let beforeAnchor = session.anchorID
        let beforeBase = session.selectionBase

        session.denoiseBatchSelection(engine: .nonlocal)

        var timings: [Double] = []
        for i in 1...3 {
            waitUntil("第 \(i) 张没有开始") { gate.startedCount == i }
            gate.permits.signal()
            if i < 3 {
                waitUntil("第 \(i + 1) 张没有开始") { gate.startedCount == i + 1 }
            }
            timings.append(session.lastDenoiseItemReloadSeconds)
        }
        waitForTerminal(session)

        let lastTop = ids.last.flatMap { stackTop(of: $0, in: session) }
        print("② 整批完成：reload ms=\(timings.map { $0 * 1000 }) "
              + "selection=\(session.selection.sorted()) anchor=\(session.anchorID ?? "nil") "
              + "lastTop=\(lastTop ?? "nil")")

        XCTAssertEqual(session.selection, beforeSelection, "② 选择必须还是开工前那一组")
        XCTAssertEqual(session.anchorID, beforeAnchor, "② 锚点必须不变")
        XCTAssertEqual(session.selectionBase, beforeBase, "② 范围基点必须不变")
        if let lastTop {
            XCTAssertNotEqual(session.selection, [lastTop],
                              "② 旧实现在这里 selectOnly(最后一个产物)：结果不许等于它")
            XCTAssertFalse(session.selection.contains(lastTop), "② 产物不许被塞进选择")
        }
        XCTAssertEqual(timings.count, 3)
        XCTAssertTrue(timings.allSatisfy { $0 > 0 }, "② 三次刷新都必须真的跑过并留下耗时")
    }

    // MARK: - ③ 单张：选择跟随该条目的顶点；模式不变、没有窗口激活

    func testTheSinglePathFollowsItsStackTopWithoutActivatingOrSwitching() throws {
        _ = NSApplication.shared
        let fixture = try makeSession(dngCount: 1)
        let session = fixture.session
        let original = try XCTUnwrap(fixture.assets.first)
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        session.selectOnly(original.id)
        session.mode = .grid

        let modeBefore = session.mode
        let keyWindowBefore = NSApp.keyWindow

        session.denoiseSelection(engine: .nonlocal)
        waitUntil("单张没有开始") { gate.startedCount == 1 }
        gate.permits.signal()
        waitForTerminal(session)

        let top = try XCTUnwrap(session.lastDenoiseReport?.stackTopID,
                                "单张也必须组成两张的堆叠")
        print("③ 单张完成：top=\(top) selection=\(session.selection.sorted()) "
              + "anchor=\(session.anchorID ?? "nil") mode=\(session.mode) "
              + "active=\(NSApp.isActive)")

        XCTAssertEqual(session.selection, [top], "③ 选择必须指向该条目堆叠的顶点")
        XCTAssertEqual(session.anchorID, top)
        XCTAssertNotEqual(session.selection, [original.id], "③ 原图已变成堆叠成员，不在投影里")
        XCTAssertEqual(session.mode, modeBefore, "③ 不许切换浏览器模式")
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore, "③ 不许激活窗口")
        XCTAssertFalse(NSApp.isActive)
    }

    // MARK: - ④ 空选择边界：开工前选择为空 ⇒ 允许 reload 的兜底选中产物

    func testAnEmptySelectionMayLandOnTheProduct() throws {
        let fixture = try makeSession(dngCount: 1)
        let session = fixture.session
        let original = try XCTUnwrap(fixture.assets.first)
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        session.selectOnly(original.id)

        session.denoiseSelection(engine: .nonlocal)
        waitUntil("单张没有开始") { gate.startedCount == 1 }
        // The user clears the selection while the engine is running: nothing may be "kept", so
        // `reload()`'s own fallback is allowed — and the only visible row is the product.
        session.setSelection([], anchor: nil)
        XCTAssertTrue(session.selection.isEmpty)
        gate.permits.signal()
        waitForTerminal(session)

        let top = try XCTUnwrap(session.lastDenoiseReport?.stackTopID)
        print("④ 空选择完成：top=\(top) selection=\(session.selection.sorted()) "
              + "anchor=\(session.anchorID ?? "nil") assets=\(session.assets.map(\.id))")

        XCTAssertEqual(session.selection, [top], "④ 空选择允许落到产物上")
        XCTAssertTrue(session.selection.isSubset(of: Set(session.assets.map(\.id))),
                      "④ 落下的必须是一张看得见的照片，不许留死角 id")
    }
}
