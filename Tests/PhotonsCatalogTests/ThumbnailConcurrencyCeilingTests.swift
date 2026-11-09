import XCTest
import Foundation
@testable import PhotonsCatalog

/// 308 — the thumbnail ceiling must be the **machine's**, and the service must actually use it.
///
/// The real-thumbnail first-screen timings cannot carry a gate: 24 warm 1920 JPEGs decode in 25–70 ms,
/// so what is measured is 24 submissions' fixed cost, and two consecutive runs disagree by more than
/// the parallel part. This test therefore pins the two facts that *are* stable:
///
///   · `ThumbnailService.Config()` — the default a caller gets without thinking — is
///     `max(2, activeProcessorCount - 1)`, not a literal 3/4/8;
///   · with 24 jobs of a known 50 ms each, the service runs exactly `maxConcurrency` of them at once
///     and finishes 24 jobs in ≈ ⌈24/k⌉ × 50 ms. A hardcoded ceiling of 3 would take 8 rounds.
final class ThumbnailConcurrencyCeilingTests: XCTestCase {

    /// A producer whose cost is known, so the wall clock says how many ran at once.
    private final class SlowProducer: ThumbnailProducer {
        let delay: TimeInterval
        init(delay: TimeInterval) { self.delay = delay }
        func produce(_ key: ThumbKey, source: URL) throws -> ThumbPayload {
            Thread.sleep(forTimeInterval: delay)
            // `looksComplete` only asks for SOI…EOI; the service writes the bytes, never decodes them.
            var bytes = [UInt8](repeating: 0, count: 32)
            bytes[0] = 0xFF; bytes[1] = 0xD8
            bytes[30] = 0xFF; bytes[31] = 0xD9
            return ThumbPayload(data: Data(bytes), source: "slow")
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-ceiling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testServiceDefaultCeilingFollowsTheMachine() {
        let expected = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        XCTAssertEqual(ThumbnailService.Config().maxConcurrency, expected)
        // The app's provider default must not drift from it either.
        XCTAssertEqual(max(2, ProcessInfo.processInfo.activeProcessorCount - 1), expected)
    }

    private func run(jobs: Int, concurrency: Int, delay: TimeInterval) throws -> (wall: Double, peak: Int) {
        let cache = try ThumbnailCache(root: root.appendingPathComponent("k\(concurrency)"))
        let service = ThumbnailService(cache: cache,
                                       config: .init(maxConcurrency: concurrency),
                                       producer: SlowProducer(delay: delay))
        let done = expectation(description: "\(jobs) jobs")
        done.expectedFulfillmentCount = jobs
        done.assertForOverFulfill = false
        let t0 = DispatchTime.now()
        for i in 0..<jobs {
            let key = ThumbKey.preview(contentHash: "content-\(concurrency)-\(i)", tier: .t256)
            service.request(ThumbRequestSpec(key: key,
                                             source: URL(fileURLWithPath: "/tmp/unused-\(i).dng")),
                            priority: .onScreen) { _ in done.fulfill() }
        }
        wait(for: [done], timeout: 60)
        let wall = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        return (wall, service.stats().activePeak)
    }

    func testServiceRunsTheCeilingItWasGiven() throws {
        let jobs = 24, delay = 0.05
        let k = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        let armK = try run(jobs: jobs, concurrency: k, delay: delay)
        let arm3 = try run(jobs: jobs, concurrency: 3, delay: delay)
        let roundsK = Int(ceil(Double(jobs) / Double(k)))
        let expectedK = Double(roundsK) * delay * 1000
        let expected3 = Double(Int(ceil(Double(jobs) / 3.0))) * delay * 1000
        print(String(format: "CEIL k=%d: %.0f ms (expect ~%.0f, peak %d) · k=3: %.0f ms (expect ~%.0f, peak %d)",
                     k, armK.wall, expectedK, armK.peak, arm3.wall, expected3, arm3.peak))

        XCTAssertEqual(armK.peak, k, "the service must run `maxConcurrency` jobs at once")
        XCTAssertEqual(arm3.peak, 3)
        XCTAssertEqual(armK.wall, expectedK, accuracy: expectedK * 0.35)
        XCTAssertEqual(arm3.wall, expected3, accuracy: expected3 * 0.35)
        // The whole point: the machine-sized ceiling beats the old literal by the ratio of the rounds.
        XCTAssertLessThan(armK.wall, arm3.wall * 0.75,
                          "k=\(k) must be at least 1.33× faster than k=3 on the same 24 jobs")
    }
}
