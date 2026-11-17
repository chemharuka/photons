import XCTest
import PhotonsCore
@testable import PhotonsCatalog

final class PreviewCacheStorageTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("preview-management-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testClearPreservesOriginalsOtherCachesAndMarkersAndRejectsOldWrites() throws {
        let cache = try ThumbnailCache(root: directory.appendingPathComponent("thumbs"))
        let key = ThumbKey.hdJPEG(contentHash: "photo", document: .neutral)
        let data = ThumbnailServiceTests.StubProducer.jpeg(seed: key.digest)
        try cache.store(data, for: key)
        let histogram = HistogramCache(root: directory.appendingPathComponent("histograms-v1"))
        let snapshot = HistogramSnapshot(sample: LinearSample(width: 1, height: 1, rgba: [0.2, 0.4, 2, 1]),
                                         canvas: ImageSize(width: 100, height: 100))
        let histogramKey = HistogramCacheKey(thumbnail: key)
        histogram.store(snapshot, for: histogramKey)
        let protected = ["original.jpg", "library.db", "linear.bin", "thumbs/.layout-marker"]
        for name in protected { try Data("keep".utf8).write(to: directory.appendingPathComponent(name)) }
        let before = try PreviewCacheStorage.usage(in: directory)
        XCTAssertEqual(before.fileCount, 2)
        XCTAssertGreaterThan(before.bytes, 0)
        let oldGeneration = cache.generation
        try PreviewCacheStorage.clear(in: directory)
        XCTAssertFalse(cache.exists(key))
        XCTAssertNil(histogram.cached(histogramKey), "Clearing disk also invalidates memory")
        try cache.store(data, for: key, generation: oldGeneration)
        histogram.store(snapshot, for: histogramKey, generation: oldGeneration)
        XCTAssertEqual(try PreviewCacheStorage.usage(in: directory).fileCount, 0)
        for name in protected { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), Data("keep".utf8)) }
        try cache.store(data, for: key, generation: cache.generation)
        let reopened = try ThumbnailCache(root: cache.root)
        XCTAssertEqual(reopened.data(for: key), data, "Reopening must retain newly generated previews")
    }

    func testLeavingViewFinishesStartedWorkAndReopenUsesDiskWithoutProducer() throws {
        let cache = try ThumbnailCache(root: directory.appendingPathComponent("thumbs"))
        let producer = ThumbnailServiceTests.StubProducer()
        producer.gate = DispatchSemaphore(value: 0)
        producer.startedSignal = DispatchSemaphore(value: 0)
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 1), producer: producer)
        let key = ThumbKey.preview(contentHash: "photo", tier: .t256)
        let request = ThumbRequestSpec(key: key, source: directory.appendingPathComponent("offline.dng"))
        let callback = expectation(description: "detached subscriber is never called"); callback.isInverted = true
        let ticket = service.request(request) { _ in callback.fulfill() }
        XCTAssertEqual(producer.startedSignal?.wait(timeout: .now() + 5), .success)
        ticket.cancel(preservingStartedWork: true)
        producer.gate?.signal()
        XCTAssertTrue(service.waitUntilIdle(timeout: 5))
        XCTAssertTrue(cache.exists(key))
        wait(for: [callback], timeout: 0.05)
        let reopened = try ThumbnailCache(root: cache.root)
        let nextProducer = ThumbnailServiceTests.StubProducer()
        let nextService = ThumbnailService(cache: reopened, producer: nextProducer)
        let hit = expectation(description: "reopened disk hit")
        _ = nextService.request(request) { result in XCTAssertEqual(result.origin, .hit); hit.fulfill() }
        wait(for: [hit], timeout: 5)
        XCTAssertEqual(nextProducer.callCount, 0)
    }

    func testClearDuringDecodeDoesNotResurrectDeletedPreview() throws {
        let cache = try ThumbnailCache(root: directory.appendingPathComponent("thumbs"))
        let producer = ThumbnailServiceTests.StubProducer()
        producer.gate = DispatchSemaphore(value: 0); producer.startedSignal = DispatchSemaphore(value: 0)
        let service = ThumbnailService(cache: cache, producer: producer)
        let key = ThumbKey.preview(contentHash: "photo", tier: .t256)
        let finished = expectation(description: "old request terminates")
        _ = service.request(ThumbRequestSpec(key: key, source: directory.appendingPathComponent("photo.dng"))) { result in
            XCTAssertEqual(result.origin, .cancelled); finished.fulfill()
        }
        XCTAssertEqual(producer.startedSignal?.wait(timeout: .now() + 5), .success)
        try PreviewCacheStorage.clear(in: directory)
        producer.gate?.signal()
        wait(for: [finished], timeout: 5)
        XCTAssertFalse(cache.exists(key))
        XCTAssertEqual(try PreviewCacheStorage.usage(in: directory).fileCount, 0)
    }

    func testClearDoesNotFollowSymlinks() throws {
        let outside = directory.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let photo = outside.appendingPathComponent("photo.jpg")
        try Data("original".utf8).write(to: photo)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("thumbs"), withDestinationURL: outside)
        try PreviewCacheStorage.clear(in: directory)
        XCTAssertEqual(try Data(contentsOf: photo), Data("original".utf8))
    }
}
