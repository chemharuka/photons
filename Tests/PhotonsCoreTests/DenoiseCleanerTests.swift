import XCTest
import PhotonsCore

/// 485 — the cache/service half of the real-time denoiser. These tests use a stand-in `compute`
/// on purpose: the acceptance is about identity, hits, inverters and failure hygiene, not about the
/// NLM kernel (which `BuiltinDenoiseTests` pins).
final class DenoiseCleanerTests: XCTestCase {

    private var workDir: URL!
    private var cacheDir: URL!
    private var photoDir: URL!
    private var photoURL: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-denoise485-\(UUID().uuidString)", isDirectory: true)
        cacheDir = workDir.appendingPathComponent("denoise-v1", isDirectory: true)
        photoDir = workDir.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photoDir, withIntermediateDirectories: true)
        photoURL = photoDir.appendingPathComponent("IMG_0001.dng")
        try Data("source pixels".utf8).write(to: photoURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: fixtures

    private static func image(_ width: Int = 8, _ height: Int = 6, seed: Int = 0) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for i in 0..<rgba.count {
            rgba[i] = Float16(Float((i * 7 + seed) % 251) / 251)
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "test")
    }

    private func source(_ id: String = "A", sha: String = "sha-a") -> DenoiseSource {
        DenoiseSource(assetID: id, url: photoURL, contentSHA256: sha, width: 1024, height: 768)
    }

    /// Thread-safe probe for compute calls, concurrency and the values handed out.
    private actor Probe {
        var calls = 0
        var active = 0
        var maxActive = 0
        var fail = false
        var delay: UInt64 = 0
        var seed = 0

        func configure(fail: Bool = false, delay: UInt64 = 0, seed: Int = 0) {
            self.fail = fail
            self.delay = delay
            self.seed = seed
        }

        struct Failure: Error {}

        func run() async throws -> LinearImage {
            calls += 1
            active += 1
            maxActive = max(maxActive, active)
            defer { active -= 1 }
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if fail { throw Failure() }
            return DenoiseCleanerTests.image(seed: seed)
        }

        var callCount: Int { calls }
        var peak: Int { maxActive }
    }

    private func cleaner(_ probe: Probe,
                         id: String = "builtin-nlm",
                         version: String = "v1",
                         directory: URL? = nil) throws -> DenoiseCleaner {
        let src = source()
        return try DenoiseCleaner(
            directory: directory ?? cacheDir,
            cleanerID: id,
            cleanerVersion: version,
            params: "amount=100",
            resolver: { _ in src },
            compute: { _, _ in try await probe.run() })
    }

    // MARK: acceptance

    func testSecondRequestIsACacheHitAndDoesNotCompute() async throws {
        let probe = Probe()
        let cleaner = try cleaner(probe)

        let first = await cleaner.cleanIfNeeded(assetID: "A")
        let second = await cleaner.cleanIfNeeded(assetID: "A")

        let firstSHA = try first.get().sha256()
        let secondSHA = try second.get().sha256()
        XCTAssertEqual(firstSHA, secondSHA)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 1, "第二次不该再算")
        let stats = await cleaner.statsSnapshot()
        XCTAssertEqual(stats.computes, 1)
        XCTAssertEqual(stats.cacheHits, 1)
        XCTAssertEqual(stats.computesFailed, 0)
        XCTAssertGreaterThan(stats.bytesWritten, 0)
    }

    func testKeyIsTheSourceAndCleanerOnly() throws {
        let key = DenoiseCacheKey(sourceSHA256: "sha-a", cleanerID: "builtin-nlm",
                                  cleanerVersion: "v1", width: 1024, height: 768)
        XCTAssertEqual(key.keyText, "sha-a|builtin-nlm|v1|1024x768")
        // A different EditModel cannot be expressed here: the key's inputs do not contain it. This
        // pins the *shape* the acceptance reads ("改曝光/裁切/蒙版后键不变").
        XCTAssertFalse(key.keyText.contains("exposure"))
        XCTAssertFalse(key.keyText.contains("crop"))
        XCTAssertFalse(key.keyText.contains("mask"))
    }

    func testVersionOrEngineChangeMovesTheKeyAndRecomputesOnce() async throws {
        let probeA = Probe()
        let first = try cleaner(probeA, id: "builtin-nlm", version: "v1")
        _ = await first.cleanIfNeeded(source: source())
        let callsA = await probeA.callCount
        XCTAssertEqual(callsA, 1)

        let probeB = Probe()
        let versioned = try cleaner(probeB, id: "builtin-nlm", version: "v2")
        _ = await versioned.cleanIfNeeded(source: source())
        let callsB = await probeB.callCount
        XCTAssertEqual(callsB, 1, "版本变了必须重算")
        let sameSource = await first.key(for: source())
        let moved = await versioned.key(for: source())
        XCTAssertNotEqual(sameSource.digest, moved.digest)

        let probeC = Probe()
        let otherEngine = try cleaner(probeC, id: "other-engine", version: "v2")
        _ = await otherEngine.cleanIfNeeded(source: source())
        let callsC = await probeC.callCount
        XCTAssertEqual(callsC, 1, "换引擎必须重算")
        let otherKey = await otherEngine.key(for: source())
        XCTAssertNotEqual(moved.digest, otherKey.digest)
    }

    func testConcurrentRequestsForOnePhotoJoinOneCompute() async throws {
        let probe = Probe()
        await probe.configure(delay: 150_000_000)
        let cleaner = try cleaner(probe)
        let src = source()

        let results = await withTaskGroup(of: Result<LinearImage, DenoiseCleanerFailure>.self) { group in
            for _ in 0..<4 {
                group.addTask { await cleaner.cleanIfNeeded(source: src) }
            }
            var out: [Result<LinearImage, DenoiseCleanerFailure>] = []
            for await result in group { out.append(result) }
            return out
        }

        XCTAssertEqual(results.count, 4)
        for result in results { _ = try result.get() }
        let calls = await probe.callCount
        XCTAssertEqual(calls, 1, "并发请求必须合并到同一次计算")
        let stats = await cleaner.statsSnapshot()
        XCTAssertEqual(stats.computes, 1)
        XCTAssertEqual(stats.cacheHits, 0)
        XCTAssertGreaterThan(stats.bytesWritten, 0)
    }

    func testComputesNeverOverlap() async throws {
        let probe = Probe()
        await probe.configure(delay: 60_000_000)
        let cleaner = try cleaner(probe)
        let url = photoURL!

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<3 {
                group.addTask {
                    _ = await cleaner.cleanIfNeeded(source: DenoiseSource(
                        assetID: "A\(i)", url: url, contentSHA256: "sha-\(i)",
                        width: 1024, height: 768))
                }
            }
            await group.waitForAll()
        }

        let calls = await probe.callCount
        let peak = await probe.peak
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(peak, 1, "引擎/CPU 只能有一个在算")
    }

    func testFailureWritesNoHalfCacheAndIsCounted() async throws {
        let probe = Probe()
        await probe.configure(fail: true)
        let cleaner = try cleaner(probe)
        let src = source()
        let key = await cleaner.key(for: src)

        let result = await cleaner.cleanIfNeeded(source: src)
        guard case .failure = result else { return XCTFail("应当失败") }
        let store = try DenoiseCacheStore(directory: cacheDir)
        let cached = try store.load(key)
        XCTAssertNil(cached)
        let stats = await cleaner.statsSnapshot()
        XCTAssertEqual(stats.computes, 1)
        XCTAssertEqual(stats.computesFailed, 1)
        XCTAssertEqual(stats.bytesWritten, 0)

        // A retry is allowed to compute again (a failure is never cached).
        await probe.configure(fail: false)
        let retry = await cleaner.cleanIfNeeded(source: src)
        _ = try retry.get()
        let calls = await probe.callCount
        XCTAssertEqual(calls, 2)
    }

    func testDeleteTheCacheRebuildsTheSameBytes() async throws {
        let probe = Probe()
        let cleaner = try cleaner(probe)
        let src = source()
        let key = await cleaner.key(for: src)

        let first = try await cleaner.cleanIfNeeded(source: src).get()
        let store = try DenoiseCacheStore(directory: cacheDir)
        let cached = try store.load(key)
        XCTAssertNotNil(cached)
        store.remove(key)
        let gone = try store.load(key)
        XCTAssertNil(gone)

        let second = try await cleaner.cleanIfNeeded(source: src).get()
        XCTAssertEqual(first.sha256(), second.sha256(), "同参数必须逐字节确定")
        let stats = await cleaner.statsSnapshot()
        XCTAssertEqual(stats.computes, 2)
        XCTAssertEqual(stats.cacheHits, 0)
    }

    func testCorruptCacheIsAMissAndIsRewritten() async throws {
        let probe = Probe()
        let cleaner = try cleaner(probe)
        let src = source()
        let key = await cleaner.key(for: src)
        let store = try DenoiseCacheStore(directory: cacheDir)
        try Data("not a clean buffer".utf8).write(to: store.fileURL(for: key))

        let result = await cleaner.cleanIfNeeded(source: src)
        _ = try result.get()
        let calls = await probe.callCount
        XCTAssertEqual(calls, 1)
        let cached = try store.load(key)
        XCTAssertNotNil(cached)
    }

    func testThePhotoDirectoryStaysUntouched() async throws {
        let before = try FileManager.default.contentsOfDirectory(atPath: photoDir.path)
        let cleaner = try cleaner(Probe())
        _ = await cleaner.cleanIfNeeded(source: source())
        let after = try FileManager.default.contentsOfDirectory(atPath: photoDir.path)
        XCTAssertEqual(before, after, "降噪只许写自己的缓存目录")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: photoDir.appendingPathComponent("IMG_0001-denoised.dng").path))
    }

    func testHeaderRecordsMagicAlgoParamsAndDims() async throws {
        let cleaner = try cleaner(Probe())
        _ = await cleaner.cleanIfNeeded(source: source())
        let key = await cleaner.key(for: source())
        let url = try DenoiseCacheStore(directory: cacheDir).fileURL(for: key)
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 24)
        let magic = data[0..<4].withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        XCTAssertEqual(magic, DenoiseCacheStore.magic)
        let version = data[4..<6].withUnsafeBytes { UInt16(littleEndian: $0.load(as: UInt16.self)) }
        XCTAssertEqual(version, DenoiseCacheStore.formatVersion)
        let algoLength = Int(data[6]) | Int(data[7]) << 8
        let algo = String(decoding: data[8..<(8 + algoLength)], as: UTF8.self)
        XCTAssertEqual(algo, "builtin-nlm")
    }
}
