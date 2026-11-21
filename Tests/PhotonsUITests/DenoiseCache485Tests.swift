import XCTest
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsUI

/// 485 — the edit-time clean cache seen through `CatalogSession`: hits across a re-open, a stable
/// key across edits, rebuilding after deletion, failure hygiene, and "no new file in the photo
/// directory". The algorithm itself is tested in `BuiltinDenoiseClean485Tests`.
@MainActor
final class DenoiseCache485Tests: XCTestCase {

    private var workDir: URL!
    private var src: URL!
    private var library: URL!
    private var session: CatalogSession!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-cache485-\(UUID().uuidString)", isDirectory: true)
        src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        library = workDir.appendingPathComponent("S485.\(LibraryLayout.packageExtension)",
                                                 isDirectory: true)
    }

    override func tearDownWithError() throws {
        session = nil
        try? FileManager.default.removeItem(at: workDir)
    }

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters[key] = nil }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    private actor ComputeProbe {
        var calls = 0
        var fail = false
        func configure(fail: Bool) { self.fail = fail }
        struct Failure: Error {}
        func image() throws -> LinearImage {
            calls += 1
            if fail { throw Failure() }
            return DenoiseCache485Tests.fakeImage()
        }
        var count: Int { calls }
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    nonisolated static func fakeImage() -> LinearImage {
        var rgba = [Float16](repeating: 0, count: 8 * 8 * 4)
        for i in 0..<rgba.count { rgba[i] = Float16(Float(i % 17) / 17) }
        return LinearImage(width: 8, height: 8, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "fake")
    }

    @discardableResult
    private func makeSession(compute: DenoiseCleaner.Compute? = nil,
                             probe: ComputeProbe? = nil) throws -> Asset {
        let catalog = try Catalog.create(at: library)
        let root = try catalog.ensureRoot(for: src, mode: .reference)
        let name = "IMG_0000.dng"
        var data = try Data(contentsOf: Self.fixtureURL)
        data.append(contentsOf: Array("cache485".utf8))
        try data.write(to: src.appendingPathComponent(name))
        let asset = Asset(sourceRootId: root.id, relPath: name, filename: name,
                          ext: "dng", kind: .raw, size: data.count, mtime: 0,
                          contentHash: "cache485-content",
                          width: 1024, height: 1024,
                          captureTime: "2026-05-01T10:00:00Z",
                          captureLocalDate: "2026-05-01",
                          cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
        try catalog.dbQueue.write { db in try asset.insert(db) }

        let store = MemoryStore()
        let s = CatalogSession(filterStore: store, sortPreferenceStore: store,
                               remembersRecentLibrary: false)
        s.denoiseCacheDirectory = workDir.appendingPathComponent("denoise-v1", isDirectory: true)
        s.denoiseComputeOverride = compute ?? { _, _ in
            if let probe { return try await probe.image() }
            return Self.fakeImage()
        }
        try s.open(library)
        session = s
        return asset
    }

    private var cacheFiles: [URL] {
        let dir = session.denoiseCacheDirectory!
        return (try? FileManager.default.contentsOfDirectory(at: dir,
                                                             includingPropertiesForKeys: nil)) ?? []
    }

    private var sourceFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: src.path)) ?? []).sorted()
    }

    // MARK: acceptance

    func testReopenHitsTheCacheAndReadsInUnder30ms() async throws {
        let probe = ComputeProbe()
        let asset = try makeSession(probe: probe)

        let first = await session.cleanDenoiseIfNeeded(assetID: asset.id)
        _ = try first.get()
        let firstCalls = await probe.count
        XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(session.denoiseStats.computes, 1)
        XCTAssertEqual(cacheFiles.count, 1)

        // "Second open": the same library is opened again, which rebuilds the cleaner but keeps
        // the global on-disk cache. A new probe proves the recompute does not happen.
        let secondProbe = ComputeProbe()
        session.denoiseComputeOverride = { _, _ in try await secondProbe.image() }
        try session.open(library)
        session.selectOnly(asset.id)
        let started = CFAbsoluteTimeGetCurrent()
        let second = await session.cleanDenoiseIfNeeded(assetID: asset.id)
        let milliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000
        _ = try second.get()
        let secondCalls = await secondProbe.count
        let stats = session.denoiseStats
        print("485 reopen hit: \(String(format: "%.2f", milliseconds)) ms, "
              + "hits=\(stats.cacheHits) computes=\(stats.computes)")
        XCTAssertEqual(secondCalls, 0, "重新打开后不许再算")
        XCTAssertEqual(stats.cacheHits, 1)
        XCTAssertEqual(stats.computes, 0)
        XCTAssertLessThan(milliseconds, 30, "读缓存应在 30 ms 内")
    }

    func testEditingDoesNotMoveTheKey() async throws {
        let probe = ComputeProbe()
        let asset = try makeSession(probe: probe)
        session.selectOnly(asset.id)

        _ = try await session.cleanDenoiseIfNeeded(assetID: asset.id).get()
        session.applyEdit { $0.light.exposure += 1.5 }
        session.applyEdit { $0.geometry.crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5) }
        // 485 §3 ② — a mask is an edit too: it changes rendering, never the source pixels.
        session.applyEdit { $0.masks.append(Mask(id: "m-cache485", name: "Mask 1")) }
        let afterEdit = await session.cleanDenoiseIfNeeded(assetID: asset.id)
        _ = try afterEdit.get()

        let calls = await probe.count
        let stats = session.denoiseStats
        print("485 edit key: calls=\(calls) hits=\(stats.cacheHits) computes=\(stats.computes)")
        XCTAssertEqual(calls, 1, "编辑不影响源像素，键不该变")
        XCTAssertEqual(stats.computes, 1)
        XCTAssertEqual(stats.cacheHits, 1)
        XCTAssertEqual(cacheFiles.count, 1, "同一张照片只该有一份缓存")
    }

    func testDeleteTheCacheRecomputesTheSameBytes() async throws {
        let probe = ComputeProbe()
        let asset = try makeSession(probe: probe)

        let first = try await session.cleanDenoiseIfNeeded(assetID: asset.id).get()
        XCTAssertEqual(cacheFiles.count, 1)
        try FileManager.default.removeItem(at: cacheFiles[0])
        XCTAssertEqual(cacheFiles.count, 0)

        let second = try await session.cleanDenoiseIfNeeded(assetID: asset.id).get()
        let calls = await probe.count
        print("485 rebuild: sha \(first.sha256().prefix(12))… → \(second.sha256().prefix(12))…")
        XCTAssertEqual(first.sha256(), second.sha256())
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(session.denoiseStats.computes, 2)
        XCTAssertEqual(cacheFiles.count, 1)
    }

    func testFailureLeavesNoCacheAndNoPhotoDirectoryFiles() async throws {
        let probe = ComputeProbe()
        await probe.configure(fail: true)
        let asset = try makeSession(probe: probe)
        let before = sourceFiles

        // 480's menu row is gone: P1 drives the cleaner through the service door directly.
        let result = await session.cleanDenoiseIfNeeded(assetID: asset.id)
        guard case .failure = result else {
            return XCTFail("计算失败时服务必须返回 failure")
        }

        XCTAssertEqual(session.denoiseStats.computesFailed, 1)
        XCTAssertEqual(cacheFiles.count, 0, "失败不许留半成品缓存")
        XCTAssertEqual(sourceFiles, before, "照片目录零新文件")
    }

    func testTheServiceWritesNoDNGAndLeavesSelectionAlone() async throws {
        let probe = ComputeProbe()
        let asset = try makeSession(probe: probe)
        session.selectOnly(asset.id)
        let before = sourceFiles

        let result = await session.cleanDenoiseIfNeeded(assetID: asset.id)
        _ = try result.get()

        let calls = await probe.count
        print("485 service: calls=\(calls) computes=\(session.denoiseStats.computes) "
              + "files=\(sourceFiles)")
        XCTAssertEqual(session.selection, [asset.id], "缓存填充不改选中")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(session.denoiseStats.computes, 1)
        XCTAssertEqual(sourceFiles, before)
        XCTAssertEqual(cacheFiles.count, 1)
    }

    /// 485 × 480 — the batch row is gone, but serial cache filling is still a service contract.
    func testPrecomputeFillsTwoPhotosSeriallyAndWritesNoDNG() async throws {
        let probe = ComputeProbe()
        let first = try makeSession(probe: probe)
        // A second asset in the same library, reusing the fixture with a different hash.
        var data = try Data(contentsOf: Self.fixtureURL)
        data.append(contentsOf: Array("cache485-b".utf8))
        let name = "IMG_0001.dng"
        try data.write(to: src.appendingPathComponent(name))
        let catalog = try Catalog.open(at: library)
        let root = try XCTUnwrap(try catalog.roots().first)
        let second = Asset(sourceRootId: root.id, relPath: name, filename: name,
                           ext: "dng", kind: .raw, size: data.count, mtime: 0,
                           contentHash: "cache485-content-b",
                           width: 1024, height: 1024,
                           captureTime: "2026-05-01T10:01:00Z",
                           captureLocalDate: "2026-05-01",
                           cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
        try await catalog.dbQueue.write { db in try second.insert(db) }
        try session.open(library)
        let before = sourceFiles

        let failures = await session.precomputeDenoiseCache(assetIDs: [first.id, second.id])

        let calls = await probe.count
        print("485 precompute: calls=\(calls) computes=\(session.denoiseStats.computes) "
              + "failed=\(failures.count) files=\(sourceFiles)")
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(session.denoiseStats.computes, 2)
        XCTAssertEqual(session.denoiseStats.computesFailed, 0)
        XCTAssertEqual(cacheFiles.count, 2)
        XCTAssertEqual(sourceFiles, before, "批量填充也不许往照片目录写文件")
        XCTAssertFalse(sourceFiles.contains { $0.contains("denoised") })
    }
}
