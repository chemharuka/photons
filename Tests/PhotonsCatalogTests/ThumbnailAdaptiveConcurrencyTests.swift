import XCTest
@testable import PhotonsCatalog

final class ThumbnailAdaptiveConcurrencyTests: XCTestCase {
    private final class Producer: ThumbnailProducer {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        func produce(_ key: ThumbKey, source: URL) throws -> ThumbPayload {
            started.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.userCancelled) }
            return ThumbPayload(data: Data([0xff, 0xd8] + Array(repeating: UInt8(0), count: 28) + [0xff, 0xd9]), source: "test")
        }
    }

    func testChangingAdmissionDoesNotCancelOrLoseJobs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let producer = Producer()
        let service = ThumbnailService(cache: try ThumbnailCache(root: root),
            config: .init(maxConcurrency: 1), producer: producer)
        let done = expectation(description: "all jobs delivered")
        done.expectedFulfillmentCount = 3
        for i in 0..<3 {
            service.request(ThumbRequestSpec(key: .preview(contentHash: "adaptive-\(i)", tier: .t256),
                source: URL(fileURLWithPath: "/unused")), priority: .onScreen) { result in
                    XCTAssertEqual(result.origin, .generated)
                    done.fulfill()
                }
        }
        XCTAssertEqual(producer.started.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(producer.started.wait(timeout: .now() + 0.05), .timedOut)
        service.setConcurrencyLimit(2)
        XCTAssertEqual(producer.started.wait(timeout: .now() + 2), .success)
        service.setConcurrencyLimit(1)
        producer.release.signal()
        XCTAssertEqual(producer.started.wait(timeout: .now() + 0.1), .timedOut,
            "lowering the limit must let in-flight work drain before admitting another job")
        producer.release.signal()
        XCTAssertEqual(producer.started.wait(timeout: .now() + 2), .success)
        producer.release.signal()
        wait(for: [done], timeout: 3)
        XCTAssertTrue(service.waitUntilIdle(timeout: 2))
        XCTAssertEqual(service.stats().maxConcurrency, 1)
        XCTAssertEqual(service.stats().missGenerated, 3)
    }
}
