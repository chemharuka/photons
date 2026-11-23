import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 527 (= 531) — 批量降噪结束后后台面板保留末张缩略图；单张的行文案写「降噪」。
///
/// Reverse gates (kept as comments, verified by hand):
///   · putting `backgroundTasks.clearCurrent(id:)` back into `finishDenoiseBatch` makes ① / ② red
///     (the key becomes nil and the square falls back to the placeholder);
///   · reverting the single title to `first?.filename` makes ③ red (no 「降噪 · 」 prefix).
@MainActor
final class DenoisePanelRow527Tests: XCTestCase {

    private var workDir: URL!
    private var activeGate: Gate?

    override func setUpWithError() throws {
        _ = NSApplication.shared
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-row527-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for _ in 0..<8 { activeGate?.permits.signal() }
        activeGate = nil
        TestWindows.sweep()
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

    private func makeSession(dngCount: Int) throws -> Fixture {
        let libraryURL = workDir.appendingPathComponent("S527.\(LibraryLayout.packageExtension)",
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
            data.append(contentsOf: Array("row527-\(i)".utf8))
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

    private func keys(for assets: [Asset]) -> [String] {
        assets.map { ThumbnailProvider.hdJPEGKey(for: $0).keyString }
    }

    private func providerWithSquares(for assets: [Asset]) throws -> ThumbnailProvider {
        let cache = try ThumbnailCache(root: workDir.appendingPathComponent("thumbs",
                                                                           isDirectory: true))
        for (index, asset) in assets.enumerated() {
            try cache.store(image: solidImage(red: 0.2, green: 0.3,
                                              blue: CGFloat(index + 1) / 4),
                            for: ThumbnailProvider.hdJPEGKey(for: asset))
        }
        return ThumbnailProvider(cache: cache)
    }

    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }

    private func makePanel(_ session: CatalogSession,
                           provider: ThumbnailProvider) -> BackgroundTasksPopover {
        let panel = BackgroundTasksPopover(
            store: session.backgroundTasks,
            thumbnailSource: BackgroundTaskThumbnailSource(provider: { provider }))
        panel.loadViewIfNeeded()
        panel.reload()
        return panel
    }

    // MARK: - ① 三张跑完：行停在第三张，方块是真图

    func testThreeItemBatchEndsOnTheLastPhotoAndKeepsItsSquare() throws {
        let fixture = try makeSession(dngCount: 3)
        let session = fixture.session
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        let ids = fixture.assets.map(\.id)
        let thumbKeys = keys(for: fixture.assets)
        let provider = try providerWithSquares(for: fixture.assets)
        session.setSelection(Set(ids), anchor: ids[0])

        session.denoiseBatchSelection(engine: .nonlocal)
        for i in 1...3 {
            waitUntil("第 \(i) 张没有开始") { gate.startedCount == i }
            gate.permits.signal()
        }
        waitForTerminal(session)

        let row = try task(in: session)
        print("527① key=\(row.currentThumbKey?.suffix(20) ?? "nil") "
              + "asset=\(row.currentAssetID ?? "nil") state=\(row.state)")

        XCTAssertEqual(row.currentAssetID, ids[2], "① 结束时行必须停在第三张")
        XCTAssertEqual(row.currentThumbKey, thumbKeys[2], "① 结束时方块键必须还是第三张")

        let panel = makePanel(session, provider: provider)
        _ = panel.rowThumbnailImageForTesting(at: 0)
        pump(0.2)
        XCTAssertEqual(panel.rowThumbnailKeyForTesting(at: 0), thumbKeys[2],
                       "① 面板画的必须还是第三张的键")
        XCTAssertEqual(panel.rowIsShowingThumbnailPlaceholderForTesting(at: 0), false,
                       "① 结束时方块不许退回占位色")
        XCTAssertNotNil(panel.rowThumbnailImageForTesting(at: 0), "① 方块必须是一张真图")
    }

    // MARK: - ② 第二张跑完时取消：停在第二张

    func testCancellingAfterTheSecondItemKeepsTheSecondPhotosSquare() throws {
        let fixture = try makeSession(dngCount: 2)
        let session = fixture.session
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        let ids = fixture.assets.map(\.id)
        let thumbKeys = keys(for: fixture.assets)
        session.setSelection(Set(ids), anchor: ids[0])

        session.denoiseBatchSelection(engine: .nonlocal)
        waitUntil("第 1 张没有开始") { gate.startedCount == 1 }
        gate.permits.signal()
        waitUntil("第 2 张没有开始") { gate.startedCount == 2 }

        // 取消落在第 2 张运行时：这一张跑完后批次收尾，停在它，不再往前。
        let taskID = try task(in: session).id
        session.backgroundTasks.cancel(id: taskID)
        gate.permits.signal()
        waitForTerminal(session)

        let row = try task(in: session)
        print("527② state=\(row.state) key=\(row.currentThumbKey?.suffix(20) ?? "nil") "
              + "asset=\(row.currentAssetID ?? "nil")")

        XCTAssertEqual(row.state, .cancelled)
        XCTAssertEqual(row.currentAssetID, ids[1], "② 取消时必须停在取消当刻的第 2 张")
        XCTAssertEqual(row.currentThumbKey, thumbKeys[1], "② 第 2 张的方块键必须保留")
    }

    // MARK: - ③ 单张行文案带「降噪」

    func testASingleRunRowStartsWithTheDenoiseLabelAndKeepsTheFilename() throws {
        let fixture = try makeSession(dngCount: 1)
        let session = fixture.session
        let original = try XCTUnwrap(fixture.assets.first)
        let provider = try providerWithSquares(for: fixture.assets)
        try installNLMFModel(on: session)
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        session.selectOnly(original.id)

        session.denoiseSelection(engine: .nonlocal)
        waitUntil("单张没有开始") { gate.startedCount == 1 }
        gate.permits.signal()
        waitForTerminal(session)

        let panel = makePanel(session, provider: provider)
        let text = try XCTUnwrap(panel.rowTextForTesting(at: 0))
        print("527③ row=\(text)")

        XCTAssertTrue(text.hasPrefix("降噪 · "), "③ 单张行必须以「降噪 · 」开头，实际：\(text)")
        XCTAssertTrue(text.contains(original.filename), "③ 文件名仍必须在行里，实际：\(text)")
    }
}
