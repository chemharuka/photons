import XCTest
import CoreGraphics
import Foundation
@testable import PhotonsCatalog

/// 006c service contract: single flight, priority, concurrency ceiling, cancellation, stats.
/// Every assertion here is either §5 of docs/tasks/006-thumbnails.md or an explicit acceptance rule
/// ("取消后不再写盘", "服务层不占主线程").
final class ThumbnailServiceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - harness

    enum StubError: LocalizedError {
        case bounce
        var errorDescription: String? { "stub producer refused this tier" }
    }

    /// A producer that can be slow, blocking, failing and counted — everything the queue needs to be
    /// observed from the outside rather than inferred from timings.
    final class StubProducer: ThumbnailProducer, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [ThumbKey] = []
        private(set) var concurrent = 0
        private(set) var peakConcurrent = 0
        private(set) var mainThreadCalls = 0
        /// Blocks every call until the test signals it (priority / cancellation ordering).
        var gate: DispatchSemaphore?
        /// Signalled as each call *enters*, so a test can wait for "something is in flight".
        var startedSignal: DispatchSemaphore?
        var delayMilliseconds: UInt32 = 0
        var failingTiers: Set<ThumbTier> = []
        /// Set by container-writers so a distinct key is still a distinct payload.
        var payload: ((ThumbKey) -> Data?)?

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
        func callsContains(_ key: ThumbKey) -> Bool { lock.lock(); defer { lock.unlock() }; return calls.contains(key) }

        func produce(_ key: ThumbKey, source: URL) throws -> ThumbPayload {
            if Thread.isMainThread { lock.lock(); mainThreadCalls += 1; lock.unlock() }
            lock.lock()
            calls.append(key)
            concurrent += 1
            peakConcurrent = max(peakConcurrent, concurrent)
            lock.unlock()
            defer { lock.lock(); concurrent -= 1; lock.unlock() }

            startedSignal?.signal()
            gate?.wait()
            if delayMilliseconds > 0 { usleep(delayMilliseconds * 1000) }
            if failingTiers.contains(key.tier) { throw StubError.bounce }
            if let payload, let data = payload(key) {
                return ThumbPayload(data: data, source: "stub", sourceLongEdge: key.tier.longEdge)
            }
            return ThumbPayload(data: Self.jpeg(seed: key.digest), source: "stub",
                                sourceLongEdge: key.tier.longEdge)
        }

        static func jpeg(seed: String) -> Data {
            let n = 8
            let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let b = Double(UInt8(seed.prefix(2), radix: 16) ?? 0) / 255
            ctx.setFillColor(CGColor(red: b, green: 0.4, blue: 0.6, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
            return ThumbnailJPEG.encode(ctx.makeImage()!)!
        }
    }

    private func makeCache() throws -> ThumbnailCache { try ThumbnailCache(root: root) }

    private func contentHash(_ i: Int) -> String { String(format: "%064x", i) }

    private func spec(_ i: Int, tier: ThumbTier = .t256, pipeline: ThumbPipeline = .preview,
                      developJSON: String = "{}") -> ThumbRequestSpec {
        let key = pipeline == .preview
            ? ThumbKey.preview(contentHash: contentHash(i), tier: tier)
            : ThumbKey.graph(contentHash: contentHash(i), tier: tier, developJSON: developJSON)
        return ThumbRequestSpec(key: key, source: URL(fileURLWithPath: "/tmp/asset-\(i).CR3"))
    }

    private func waitIdle(_ service: ThumbnailService) {
        XCTAssertTrue(service.waitUntilIdle(timeout: 60), "service did not drain")
    }

    // MARK: - ① single flight

    /// §4: "单飞 per (contentHash, tier)" — five requests for one key must cost one producer call and
    /// hand every subscriber the same bytes.
    func testSameKeyCoalescesIntoOneProducerCall() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 2), producer: producer)

        let one = spec(1)
        let tickets = service.request([one, one, one, one, one], priority: .onScreen)
        waitIdle(service)

        XCTAssertEqual(tickets.count, 5)
        XCTAssertEqual(producer.callCount, 1, "single flight: the same key must be produced once")
        let stats = service.stats()
        XCTAssertEqual(stats.coalesced, 4)
        XCTAssertEqual(stats.missGenerated, 1)
        XCTAssertEqual(stats.writes, 1)
        XCTAssertEqual(stats.delivered, 5, "every subscriber gets the result")

        // Same bytes for everyone: the result the second caller saw is the file on disk.
        let fileData = try XCTUnwrap(cache.data(for: one.key))
        XCTAssertFalse(fileData.isEmpty)
        XCTAssertEqual(producer.calls.first, one.key)
        XCTAssertEqual(stats.hits, 0)
    }

    /// The coalesced subscribers receive the *same* payload object content, via completions.
    func testCoalescedSubscribersShareOnePayload() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 1), producer: producer)

        let payloads = NSMutableArray()
        let lock = NSLock()
        let done = expectation(description: "3 subscribers")
        done.expectedFulfillmentCount = 3
        let one = spec(7)
        for _ in 0..<3 {
            service.request(one, priority: .onScreen) { result in
                lock.lock(); payloads.add(result.data ?? Data()); lock.unlock()
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(producer.callCount, 1)
        XCTAssertEqual(payloads.count, 3)
        XCTAssertEqual(Set(payloads.map { $0 as! Data }).count, 1, "one producer call, one payload")
        XCTAssertEqual(service.stats().coalesced, 2)
    }

    // MARK: - ② hits bypass the producer

    func testCacheHitNeverCallsTheProducer() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let service = ThumbnailService(cache: cache, config: .init(), producer: producer)
        let one = spec(2)
        try cache.store(StubProducer.jpeg(seed: one.key.digest), for: one.key)

        let ticket = service.request(one, priority: .onScreen)
        waitIdle(service)

        XCTAssertEqual(producer.callCount, 0, "a hit is a file read, not a render")
        XCTAssertEqual(service.stats().hits, 1)
        XCTAssertEqual(service.result(for: ticket)?.origin, .hit)
        XCTAssertNil(service.result(for: ticket)?.data, "summaries never pin the bytes")
    }

    // MARK: - ③ priority

    /// §4: onScreen before prefetch before background; FIFO inside a priority.
    func testPriorityOrderRunsOnScreenFirst() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let gate = DispatchSemaphore(value: 0)
        producer.gate = gate
        producer.startedSignal = DispatchSemaphore(value: 0)
        // One slot, so "next" is a real decision rather than three jobs racing.
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 1), producer: producer)

        let blocker = spec(100)
        let low1 = spec(101), low2 = spec(102), pre = spec(103), high = spec(104)
        _ = service.request(blocker, priority: .background)
        XCTAssertEqual(producer.startedSignal!.wait(timeout: .now() + 5), .success,
                       "the blocker should occupy the single slot")

        // Enqueued out of priority order on purpose.
        _ = service.request(low1, priority: .background)
        _ = service.request(low2, priority: .background)
        _ = service.request(pre, priority: .prefetch)
        _ = service.request(high, priority: .onScreen)
        XCTAssertEqual(service.pendingCount, 4)

        for _ in 0..<5 { gate.signal() }
        waitIdle(service)

        XCTAssertEqual(producer.calls.count, 5)
        XCTAssertEqual(producer.calls[0], blocker.key)
        XCTAssertEqual(producer.calls[1], high.key, "onScreen jumps the queue")
        XCTAssertEqual(producer.calls[2], pre.key, "then prefetch")
        XCTAssertEqual(producer.calls[3], low1.key, "background stays FIFO")
        XCTAssertEqual(producer.calls[4], low2.key)
        XCTAssertEqual(service.stats().queuedPeak, 4)
    }

    // MARK: - ④ concurrency ceiling

    /// §4: "并发上限 3" — never more, and actually reached (a serial service would pass a `<=` only).
    func testConcurrencyCeilingIsNeverExceeded() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        producer.delayMilliseconds = 25
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 3), producer: producer)

        let specs = (0..<12).map { spec($0) }
        _ = service.request(specs, priority: .onScreen)
        waitIdle(service)

        XCTAssertEqual(producer.callCount, 12)
        XCTAssertLessThanOrEqual(producer.peakConcurrent, 3, "the ceiling is a promise, not a hope")
        XCTAssertEqual(producer.peakConcurrent, 3, "and it is actually used")
        XCTAssertEqual(service.stats().activePeak, 3)
    }

    /// The ceiling config is honoured for any value, including 1 (ordering tests depend on it).
    func testConfigurableConcurrencyOfOneIsSerial() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        producer.delayMilliseconds = 5
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 1), producer: producer)

        _ = service.request((0..<6).map { spec($0) }, priority: .onScreen)
        waitIdle(service)
        XCTAssertEqual(producer.peakConcurrent, 1)
        XCTAssertEqual(service.stats().activePeak, 1)
        XCTAssertEqual(producer.callCount, 6)
    }

    // MARK: - ⑤ cancellation

    /// The acceptance rule: a cancelled job never reaches the disk.
    func testCancelBeforeStartWritesNothing() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let gate = DispatchSemaphore(value: 0)
        producer.gate = gate
        producer.startedSignal = DispatchSemaphore(value: 0)
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 1), producer: producer)

        let blocker = spec(200)
        let victim = spec(201)
        _ = service.request(blocker, priority: .onScreen)
        XCTAssertEqual(producer.startedSignal!.wait(timeout: .now() + 5), .success)

        let ticket = service.request(victim, priority: .prefetch)
        XCTAssertEqual(service.pendingCount, 1)
        ticket.cancel()

        XCTAssertTrue(ticket.isCancelled)
        XCTAssertEqual(service.pendingCount, 0, "a cancelled pending job leaves the queue")
        XCTAssertEqual(service.stats().missCancelled, 1)

        gate.signal()   // let the blocker go; the victim must not be picked up
        waitIdle(service)

        XCTAssertFalse(producer.callsContains(victim.key), "the cancelled key was never produced")
        XCTAssertFalse(cache.exists(victim.key), "取消后不再写盘")
        XCTAssertTrue(cache.exists(blocker.key))
        XCTAssertNil(service.result(for: ticket), "no result is fabricated for a cancelled ticket")
    }

    /// In-flight cancellation: the decode cannot be interrupted (§5), but its bytes are dropped.
    func testCancelInFlightDropsBytesAndCountsIt() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        producer.gate = gate
        producer.startedSignal = started
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 2), producer: producer)

        let one = spec(210)
        let ticket = service.request(one, priority: .onScreen)
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success, "producer entered")
        ticket.cancel()

        gate.signal()
        waitIdle(service)

        XCTAssertEqual(producer.callCount, 1, "the uninterruptible decode still ran once")
        XCTAssertFalse(cache.exists(one.key), "取消后不再写盘 — even for an in-flight job")
        let stats = service.stats()
        XCTAssertEqual(stats.cancelledInFlight, 1)
        XCTAssertEqual(stats.missCancelled, 1)
        XCTAssertEqual(stats.missGenerated, 0)
        XCTAssertEqual(stats.writes, 0)
    }

    /// Cancelling one subscriber of a coalesced job must not kill the job for the others.
    func testCancellingOneSubscriberKeepsTheSharedJobAlive() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        producer.gate = gate
        producer.startedSignal = started
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 1), producer: producer)

        let one = spec(220)
        let a = service.request(one, priority: .onScreen)
        let b = service.request(one, priority: .onScreen)
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        a.cancel()

        gate.signal()
        waitIdle(service)

        XCTAssertTrue(a.isCancelled)
        XCTAssertFalse(b.isCancelled)
        XCTAssertTrue(cache.exists(one.key), "someone still wants it, so the file is written")
        XCTAssertEqual(service.stats().cancelledInFlight, 0)
        XCTAssertEqual(service.stats().missGenerated, 1)
    }

    /// "The view left": one call cancels a whole visible set.
    func testBatchCancelOfAVisibleSet() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let gate = DispatchSemaphore(value: 0)
        producer.gate = gate
        producer.startedSignal = DispatchSemaphore(value: 0)
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 1), producer: producer)

        let blocker = spec(230)
        _ = service.request(blocker, priority: .background)
        XCTAssertEqual(producer.startedSignal!.wait(timeout: .now() + 5), .success)

        let visible = (300..<310).map { spec($0) }
        let tickets = service.request(visible, priority: .onScreen)
        XCTAssertEqual(service.pendingCount, 10)
        cancel(tickets) // the free function: "batch cancel when the view goes away"
        XCTAssertEqual(service.pendingCount, 0)

        gate.signal()
        waitIdle(service)
        for s in visible {
            XCTAssertFalse(cache.exists(s.key))
            XCTAssertFalse(producer.callsContains(s.key))
        }
        XCTAssertEqual(service.stats().missCancelled, 10)
    }

    // MARK: - ⑥ generation

    /// §5: a new generation drops queued work from the old one.
    func testGenerationBumpDropsOlderQueuedJobs() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let gate = DispatchSemaphore(value: 0)
        producer.gate = gate
        producer.startedSignal = DispatchSemaphore(value: 0)
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 1), producer: producer)

        let blocker = spec(400)
        _ = service.request(blocker, priority: .background)
        XCTAssertEqual(producer.startedSignal!.wait(timeout: .now() + 5), .success)

        let old = (401..<406).map { spec($0) }
        _ = service.request(old, priority: .prefetch)
        XCTAssertEqual(service.pendingCount, 5)

        let gen = service.beginGeneration()
        XCTAssertEqual(gen, 1)
        XCTAssertEqual(service.pendingCount, 0, "stale generation is dropped, not run later")
        XCTAssertEqual(service.stats().missCancelled, 5)

        gate.signal()
        waitIdle(service)
        for s in old { XCTAssertFalse(producer.callsContains(s.key)) }
    }

    /// §5: an in-flight job is allowed to finish and write — the work is already paid for — but the
    /// result must not be delivered to a view that no longer exists.
    func testGenerationBumpLetsInFlightJobWriteButNotDeliver() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        producer.gate = gate
        producer.startedSignal = started
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 1), producer: producer)

        var delivered = false
        let one = spec(410)
        let ticket = service.request(one, priority: .onScreen) { _ in delivered = true }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        _ = service.beginGeneration()

        gate.signal()
        waitIdle(service)

        XCTAssertTrue(cache.exists(one.key), "in-flight work is not wasted")
        XCTAssertFalse(delivered, "but the stale view is not called back")
        XCTAssertGreaterThanOrEqual(service.stats().missGenerated, 1)
        XCTAssertNotNil(ticket)
    }

    /// §5: keys that survive the scroll (the same visible rows) are kept.
    func testGenerationBumpCanKeepVisibleKeys() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let gate = DispatchSemaphore(value: 0)
        producer.gate = gate
        producer.startedSignal = DispatchSemaphore(value: 0)
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 1), producer: producer)

        _ = service.request(spec(420), priority: .background)
        XCTAssertEqual(producer.startedSignal!.wait(timeout: .now() + 5), .success)

        let kept = spec(421), gone = spec(422)
        _ = service.request([kept, gone], priority: .prefetch)
        _ = service.beginGeneration(keeping: [kept.key])
        XCTAssertEqual(service.pendingCount, 1, "only the key that is still on screen survives")

        for _ in 0..<3 { gate.signal() }
        waitIdle(service)
        XCTAssertTrue(producer.callsContains(kept.key))
        XCTAssertFalse(producer.callsContains(gone.key))
    }

    // MARK: - ⑦ pause (§4 isInteracting)

    func testPausedServiceRejectsInsteadOfQueueing() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let service = ThumbnailService(cache: cache, config: .init(), producer: producer)
        service.isPaused = true

        let tickets = service.request((0..<4).map { spec($0) }, priority: .onScreen)
        XCTAssertEqual(service.pendingCount, 0)
        waitIdle(service)

        XCTAssertEqual(producer.callCount, 0, "no job while the user is dragging")
        let stats = service.stats()
        XCTAssertEqual(stats.rejectedWhilePaused, 4)
        XCTAssertEqual(stats.missCancelled, 0, "a refusal is not an outcome bucket")
        XCTAssertEqual(stats.requests, 0)
        XCTAssertTrue(tickets.allSatisfy { $0.isCancelled })

        service.isPaused = false
        _ = service.request(spec(0), priority: .onScreen)
        waitIdle(service)
        XCTAssertEqual(producer.callCount, 1, "resuming works")
    }

    // MARK: - ⑧ G path keys

    /// §0 / D12: the two pipelines produce two different keys for the same bytes at the same tier, so
    /// the placeholder and the faithful rendering can coexist without one overwriting the other.
    func testGraphAndPreviewKeysAreDistinctAndBothCached() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 2), producer: producer)

        let p = spec(500, tier: .t512, pipeline: .preview)
        let g = spec(500, tier: .t512, pipeline: .graph, developJSON: "{}")
        XCTAssertNotEqual(p.key, g.key)
        XCTAssertNotEqual(p.key.digest, g.key.digest, "pipeline is part of the key")
        XCTAssertEqual(p.key.contentHash, g.key.contentHash)
        XCTAssertEqual(p.key.recipeDigest, "-", "a placeholder carries no recipe")

        // A placeholder at another tier survives, so the grid keeps its fast frame.
        let placeholderElsewhere = spec(500, tier: .t256, pipeline: .preview)
        _ = service.request(placeholderElsewhere, priority: .onScreen)
        _ = service.request(p, priority: .onScreen)
        waitIdle(service)
        XCTAssertTrue(cache.exists(p.key), "the placeholder exists before the render arrives")

        _ = service.request(g, priority: .onScreen)
        waitIdle(service)

        XCTAssertTrue(cache.exists(g.key))
        XCTAssertFalse(cache.exists(p.key),
                       "the same-tier placeholder is pruned once the faithful rendering exists (§0)")
        XCTAssertTrue(cache.exists(placeholderElsewhere.key), "other tiers keep their placeholder")
        XCTAssertEqual(producer.callCount, 3, "two pipelines at one tier are two keys, never aliases")
    }

    /// §4: a committed edit changes `recipeDigest`, so the new thumbnail is a new key. The old file is
    /// **not** deleted: undo returns to it as a hit (§4 A→B→A), and LRU owns the cleanup.
    func testEditProducesANewKeyAndKeepsTheOldFile() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 2), producer: producer)

        let before = spec(510, tier: .t512, pipeline: .graph, developJSON: #"{"light":{"exposure":0}}"#)
        let after = spec(510, tier: .t512, pipeline: .graph, developJSON: #"{"light":{"exposure":1}}"#)
        XCTAssertNotEqual(before.key.digest, after.key.digest, "renderVersion/digest change → new key")

        _ = service.request(before, priority: .onScreen)
        waitIdle(service)
        let oldBytes = try XCTUnwrap(cache.data(for: before.key))

        _ = service.request(after, priority: .onScreen)
        waitIdle(service)

        XCTAssertTrue(cache.exists(before.key), "the pre-edit file stays for undo")
        XCTAssertTrue(cache.exists(after.key))
        XCTAssertEqual(cache.data(for: before.key), oldBytes, "and it is untouched")

        // Undo: the old key is a hit, and no third file appears.
        let undo = service.request(before, priority: .onScreen)
        waitIdle(service)
        XCTAssertEqual(service.result(for: undo)?.origin, .hit)
        XCTAssertEqual(producer.callCount, 2)
        XCTAssertEqual(cache.inventory().count, 2, "A, B — never a third")
    }

    // MARK: - ⑨ stats

    /// Every accepted request ends in exactly one bucket; writes track generations; cancellation is
    /// never double counted. A report that cannot satisfy this is a report nobody should trust.
    func testStatsAreSelfConsistent() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let gate = DispatchSemaphore(value: 0)
        producer.gate = gate
        producer.startedSignal = DispatchSemaphore(value: 0)
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 1), producer: producer)

        let a = spec(600), b = spec(601), c = spec(602), d = spec(603)
        _ = service.request(a, priority: .onScreen)          // in flight (blocked)
        XCTAssertEqual(producer.startedSignal!.wait(timeout: .now() + 5), .success)
        _ = service.request(b, priority: .prefetch)          // queued
        _ = service.request(b, priority: .prefetch)          // coalesced into the same job
        let cTicket = service.request(c, priority: .background)
        cTicket.cancel()                                     // cancelled while pending
        _ = service.request(d, priority: .background)        // queued

        for _ in 0..<3 { gate.signal() }
        waitIdle(service)

        let s = service.stats()
        print("service stats: requests=\(s.requests) coalesced=\(s.coalesced) hits=\(s.hits) "
              + "generated=\(s.missGenerated) cancelled=\(s.missCancelled) failed=\(s.missFailed) "
              + "writes=\(s.writes) delivered=\(s.delivered) queuedPeak=\(s.queuedPeak) "
              + "activePeak=\(s.activePeak) avgWait=\(s.averageWaitMilliseconds)")

        XCTAssertEqual(s.requests, 5)
        XCTAssertEqual(s.coalesced, 1)
        XCTAssertEqual(s.missCancelled, 1)
        XCTAssertEqual(s.missGenerated, 3)
        XCTAssertEqual(s.hits, 0)
        XCTAssertEqual(s.missFailed, 0)
        XCTAssertEqual(s.requests, s.coalesced + s.hits + s.missGenerated + s.missCancelled + s.missFailed,
                       "every request is a join or one outcome; nothing is counted twice")
        XCTAssertEqual(s.rejectedWhilePaused + s.droppedStaleGeneration + s.rejectedByDepth, 0)
        XCTAssertEqual(s.writes, s.missGenerated, "each generated thumbnail is written once")
        XCTAssertEqual(s.delivered, s.requests - s.missCancelled)
        XCTAssertGreaterThan(s.averageWaitMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(s.queuedPeak, 2)
        XCTAssertEqual(s.active, 0, "nothing left running")
        XCTAssertEqual(s.queued, 0)
        XCTAssertFalse(cache.exists(c.key), "the cancelled key was never written")
    }

    /// A failing producer is counted, not crashed, and does not poison the queue.
    func testProducerFailureIsCountedAndQueueContinues() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        producer.failingTiers = [.t4096]
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 2), producer: producer)

        let bad = spec(700, tier: .t4096)
        let good = spec(700, tier: .t256)
        let badTicket = service.request(bad, priority: .onScreen)
        _ = service.request(good, priority: .onScreen)
        waitIdle(service)

        let s = service.stats()
        XCTAssertEqual(s.missFailed, 1)
        XCTAssertEqual(s.missGenerated, 1)
        XCTAssertNotNil(service.result(for: badTicket)?.error)
        XCTAssertFalse(cache.exists(bad.key))
        XCTAssertTrue(cache.exists(good.key))
    }

    // MARK: - ⑩ main thread

    /// "服务层不占主线程": a batch runs entirely off-main, and the main thread keeps ticking. If any
    /// cache read, producer call or write landed on main, the heartbeat would show a hole.
    func testServiceNeverBlocksTheMainThread() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        producer.delayMilliseconds = 4
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 3), producer: producer)

        let done = expectation(description: "batch finished")
        let specs = (0..<150).map { spec($0) }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = service.request(specs, priority: .prefetch)
            _ = service.waitUntilIdle(timeout: 120)
            DispatchQueue.main.async { done.fulfill() }
        }

        var last = CFAbsoluteTimeGetCurrent()
        var maxGap = 0.0
        var ticks = 0
        let timer = Timer(timeInterval: 0.004, repeats: true) { _ in
            let now = CFAbsoluteTimeGetCurrent()
            maxGap = max(maxGap, now - last)
            last = now
            ticks += 1
        }
        RunLoop.main.add(timer, forMode: .common)
        wait(for: [done], timeout: 180)
        timer.invalidate()

        print("main-thread heartbeat: ticks=\(ticks) maxGap=\(maxGap * 1000) ms")
        XCTAssertGreaterThan(ticks, 5, "the heartbeat must have had time to tick")
        XCTAssertLessThan(maxGap * 1000, 50, "service work ran on the main thread (gap \(maxGap * 1000) ms)")
        XCTAssertEqual(producer.mainThreadCalls, 0)
    }

    /// 1000 keys, the first 20 of them `onScreen`: the visible cells must finish first, and the
    /// per-request cost on the caller's thread must stay negligible (§5 "队列峰值不随行数增长").
    func testThousandKeyBatchFinishesVisibleFirst() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        producer.delayMilliseconds = 1
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 3), producer: producer)

        let visibleCount = 20
        let total = 1000
        let visible = (0..<visibleCount).map { spec($0) }
        let rest = (visibleCount..<total).map { spec($0) }

        let finishLock = NSLock()
        var order: [ThumbKey] = []
        var finishedAt: [ThumbKey: Double] = [:]
        let start = CFAbsoluteTimeGetCurrent()

        // Enqueue cost measured on this (main) thread — this is what a scroll actually pays.
        var enqueueMs: [Double] = []
        for s in visible {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = service.request(s, priority: .onScreen) { result in
                finishLock.lock()
                order.append(result.key)
                finishedAt[result.key] = (CFAbsoluteTimeGetCurrent() - start) * 1000
                finishLock.unlock()
            }
            enqueueMs.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        let tBatch = CFAbsoluteTimeGetCurrent()
        let prefetchTickets = service.request(rest, priority: .prefetch) { result in
            finishLock.lock()
            order.append(result.key)
            finishedAt[result.key] = (CFAbsoluteTimeGetCurrent() - start) * 1000
            finishLock.unlock()
        }
        enqueueMs.append((CFAbsoluteTimeGetCurrent() - tBatch) * 1000)
        XCTAssertEqual(prefetchTickets.count, rest.count)

        waitIdle(service)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        finishLock.lock()
        let firstTwenty = Array(order.prefix(visibleCount))
        let visibleSet = Set(visible.map { $0.key })
        let visibleFinish = visible.compactMap { finishedAt[$0.key] }.max() ?? .infinity
        finishLock.unlock()

        let s = service.stats()
        print(String(format: "batch1000: total %.1f ms, all onScreen done at %.1f ms, "
                     + "enqueue p50 %.3f ms max %.3f ms, peakActive %d, generated %d",
                     elapsed, visibleFinish, median(enqueueMs), enqueueMs.max() ?? 0,
                     s.activePeak, s.missGenerated))

        XCTAssertEqual(firstTwenty.count, visibleCount)
        XCTAssertEqual(Set(firstTwenty), visibleSet, "the 20 visible cells finish before any prefetch")
        XCTAssertLessThan(visibleFinish, elapsed, "prefetch continued after the grid was served")
        XCTAssertEqual(s.missGenerated, total)
        XCTAssertLessThanOrEqual(s.activePeak, 3)
        XCTAssertLessThan(median(enqueueMs), 5.0, "request() must not do I/O on the caller's thread")
    }

    private func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Pure queue cost at 1000 keys: everything is already on disk, so this measures the service
    /// layer (lock, priority pick, dispatch, counters) and nothing else. Acceptance #1's second pass
    /// is exactly this workload.
    func testThousandKeyAllHitBatchIsQueueBound() throws {
        let cache = try makeCache()
        let producer = StubProducer()
        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 3), producer: producer)

        let total = 1000
        var specs: [ThumbRequestSpec] = []
        specs.reserveCapacity(total)
        let payload = StubProducer.jpeg(seed: "aa")
        for i in 0..<total {
            let s = spec(i)
            try cache.store(payload, for: s.key)
            specs.append(s)
        }
        cache.resetStats()

        let t0 = CFAbsoluteTimeGetCurrent()
        let tickets = service.request(specs, priority: .onScreen)
        XCTAssertEqual(tickets.count, total)
        let enqueueMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        waitIdle(service)
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        let s = service.stats()
        print(String(format: "batch1000 hits: enqueue %.1f ms, total %.1f ms, avg wait %.2f ms, "
                     + "hitRatio %.3f, activePeak %d", enqueueMs, elapsed,
                     s.averageWaitMilliseconds, s.hitRatio, s.activePeak))

        XCTAssertEqual(producer.callCount, 0, "no render for a fully warm batch")
        XCTAssertEqual(s.hits, total)
        XCTAssertEqual(s.hitRatio, 1.0)
        XCTAssertEqual(cache.stats().misses, 0)
        XCTAssertLessThan(enqueueMs, 100, "queueing 1000 keys must not be a visible pause")
        XCTAssertLessThanOrEqual(s.activePeak, 3)
    }
}
