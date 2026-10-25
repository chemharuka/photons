import XCTest
@testable import PhotonsCore

/// `DecodeQueue` (Q29): the properties the loupe depends on, asserted without Metal or a RAW file.
///
/// The queue exists so a frame is never queued behind a development. What that costs is bookkeeping —
/// dedupe, generations, cancellation — and bookkeeping is exactly what a timing test cannot check, so
/// every rule is pinned here as a *count*:
///
///   · one development per `(photo, rung)`, however many frames ask for it;
///   · every waiter is told, with the generation it asked for;
///   · a cancelled photo is never delivered — not the queued work, not the running work;
///   · work and frames **overlap in time**, which is the whole point (asserted as an interval
///     overlap, not a wall clock: a slow machine must not fail this test);
final class DecodeQueueTests: XCTestCase {

    private func rung(_ scale: Float) -> DecodeRung {
        let image = LinearImage(width: 2, height: 2, rgba: [Float16](repeating: 1, count: 16),
                                colorSpace: "extendedLinearSRGB", decoderVersion: "8")
        return DecodeRung(scale: scale, image: image,
                          capabilities: DecoderCapabilities(requestedVersion: nil,
                                                            effectiveVersion: "8",
                                                            defaultVersion: "8"),
                          milliseconds: 0)
    }

    /// One development, one buffer, two notifications: the second frame joins the first rather than
    /// opening the file again. This is what keeps 20 pans from costing 20 developments.
    func testOneDevelopmentPerKeyAndEveryWaiterIsCalled() {
        let queue = DecodeQueue(label: "test.dedupe")
        let workCalls = Counter()
        let delivered = Counter()
        let deliveredGenerations = Locked<[Int]>([])

        for generation in 0..<20 {
            queue.request(identity: "photo", scale: 1, generation: generation, work: {
                workCalls.increment()
                Thread.sleep(forTimeInterval: 0.05)
                return self.rung(1)
            }, completion: { _, generation in
                delivered.increment()
                deliveredGenerations.mutate { $0.append(generation) }
            })
        }
        XCTAssertTrue(queue.waitUntilIdle())
        XCTAssertEqual(workCalls.value, 1, "20 requests must cost one development")
        XCTAssertEqual(queue.decodes, 1)
        XCTAssertEqual(queue.coalesced, 19)
        XCTAssertEqual(delivered.value, 20, "every waiter is told, even though only one developed")
        XCTAssertEqual(deliveredGenerations.value.sorted(), Array(0..<20),
                       "each delivery reports the generation its request asked for")
    }

    /// A cancelled photo is never delivered — and the *queued* work is skipped, so leaving a photo
    /// stops paying ImageIO for it.
    func testCancelledPhotoIsNeverDelivered() {
        let queue = DecodeQueue(label: "test.cancel")
        let started = DispatchSemaphore(value: 0)
        var delivered = 0
        var workRan = 0
        queue.request(identity: "photo", scale: 0.5, generation: 1, work: {
            workRan += 1
            started.signal()
            Thread.sleep(forTimeInterval: 0.1)
            return self.rung(0.5)
        }, completion: { _, _ in delivered += 1 })
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success, "the first development never ran")

        // The second rung is still queued behind it when the photo goes away.
        queue.request(identity: "photo", scale: 1, generation: 1, work: {
            workRan += 1
            return self.rung(1)
        }, completion: { _, _ in delivered += 1 })

        queue.cancel(identity: "photo")
        XCTAssertTrue(queue.waitUntilIdle())
        XCTAssertEqual(delivered, 0, "a cancelled photo must not call back")
        XCTAssertEqual(workRan, 1, "the queued rung is skipped; only the running one has to finish")
        XCTAssertGreaterThanOrEqual(queue.drops, 2)
    }

    /// Cancellation while the development is already inside ImageIO cannot abort it — but it must not
    /// publish it either. The pixels are paid for, the canvas is not touched.
    func testCancellingWhileRunningDropsTheDelivery() {
        let queue = DecodeQueue(label: "test.cancel-running")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var delivered = 0
        queue.request(identity: "photo", scale: 1, generation: 7, work: {
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            return self.rung(1)
        }, completion: { _, _ in delivered += 1 })
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        queue.cancel(identity: "photo")
        release.signal()
        XCTAssertTrue(queue.waitUntilIdle())
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(queue.drops, 1)
    }

    /// A different photo is a different key: cancelling one never touches the other, and the shared
    /// counter still says two developments, not one.
    func testIdentityIsPartOfTheKey() {
        let queue = DecodeQueue(label: "test.identity")
        var delivered: [String] = []
        for (identity, scale) in [("a", Float(0.5)), ("b", Float(0.5))] {
            queue.request(identity: identity, scale: scale, generation: 0, work: {
                self.rung(scale)
            }, completion: { _, _ in delivered.append(identity) })
        }
        XCTAssertTrue(queue.waitUntilIdle())
        XCTAssertEqual(delivered.sorted(), ["a", "b"])
        XCTAssertEqual(queue.decodes, 2)
    }

    /// The property the whole change is for: a development and the frames run **at the same time**.
    ///
    /// Asserted as an interval overlap rather than "the frame took less than N ms" — a machine under
    /// load may take 30 ms for a 5 ms frame, but it can never make two overlapping intervals disjoint.
    func testDevelopmentAndRenderOverlapInTime() {
        let queue = DecodeQueue(label: "test.overlap")
        let decodeWindow = Locked<(start: CFAbsoluteTime, end: CFAbsoluteTime)>((0, 0))
        let ready = DispatchSemaphore(value: 0)

        queue.request(identity: "photo", scale: 1, generation: 0, work: {
            let start = CFAbsoluteTimeGetCurrent()
            ready.signal()
            Thread.sleep(forTimeInterval: 0.25)
            decodeWindow.set((start, CFAbsoluteTimeGetCurrent()))
            return self.rung(1)
        }, completion: { _, _ in })

        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success,
                       "the development has started; the frames must not wait for it")

        let renderQueue = DispatchQueue(label: "test.overlap.render")
        let renderWindow = Locked<(start: CFAbsoluteTime, end: CFAbsoluteTime)>((.greatestFiniteMagnitude, 0))
        for _ in 0..<5 {
            renderQueue.sync {
                let start = CFAbsoluteTimeGetCurrent()
                Thread.sleep(forTimeInterval: 0.02)
                let end = CFAbsoluteTimeGetCurrent()
                renderWindow.mutate { $0 = (min($0.start, start), max($0.end, end)) }
            }
        }
        XCTAssertTrue(queue.waitUntilIdle())

        let d = decodeWindow.value, r = renderWindow.value
        XCTAssertGreaterThan(d.end, d.start)
        XCTAssertGreaterThan(r.end, r.start)
        XCTAssertTrue(r.start < d.end && d.start < r.end,
                      "development \(d) and frames \(r) did not overlap: the frames were serialised "
                      + "behind the development, which is the defect Q29 removed")
    }

    /// A second request for a key that has *finished* is a new development: the caller is telling the
    /// queue it does not have the buffer (which is what a ladder miss means).
    func testARequestAfterDeliveryDevelopsAgain() {
        let queue = DecodeQueue(label: "test.again")
        for _ in 0..<2 {
            queue.request(identity: "photo", scale: 1, generation: 0, work: { self.rung(1) },
                          completion: { _, _ in })
            XCTAssertTrue(queue.waitUntilIdle())
        }
        XCTAssertEqual(queue.decodes, 2)
    }
}

// MARK: - tiny thread-safe helpers (no third-party dependency)

final class Counter {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func increment() { lock.lock(); stored += 1; lock.unlock() }
}

final class Locked<T> {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: T) { lock.lock(); stored = value; lock.unlock() }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
