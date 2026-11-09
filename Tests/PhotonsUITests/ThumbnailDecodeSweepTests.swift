import XCTest
import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 308 — **is thumbnail production worth more than 3 workers on this machine?** The answer decides
/// `ThumbnailProvider.defaultConcurrency`, so it is measured instead of assumed.
///
/// Gated on `PHOTONS_SWEEP=1` (a sweep renders 24 real RAWs and decodes them 400+ times; that is a
/// benchmark, not a unit test). Every number is printed — `local/THUMB-BENCH.md` carries the table.
///
/// Method, and the three ways this could lie:
///   · **24 different files**, not one file 24 times: the OS page cache would otherwise make the
///     second decode of the same 368 KB a memory copy, which is exactly the thing under test;
///   · **warm disk**: each arm decodes the whole set twice and the second round is the measurement;
///   · **whole-image decode** through ImageIO (`CGImageSourceCreateImageAtIndex` +
///     `kCGImageSourceShouldCacheImmediately`), the same door the HD path takes before Core Image
///     turns the picture into an EDR bitmap. A thumbnail door would measure a different pipeline.
final class ThumbnailDecodeSweepTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_SWEEP"] != nil else {
            throw XCTSkip("set PHOTONS_SWEEP=1 to run the concurrency sweep")
        }
        root = fm.temporaryDirectory.appendingPathComponent("photons-sweep-\(UUID().uuidString)",
                                                            isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    // MARK: fixtures

    private func rawFiles(limit: Int) throws -> [URL] {
        let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"]
            ?? NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath
        let dir = URL(fileURLWithPath: env).deletingLastPathComponent()
        let all = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let raws = all.filter { ["dng", "cr3", "arw", "rw2", "nef", "raf", "orf"]
                                    .contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard raws.count >= limit else {
            throw XCTSkip("need \(limit) distinct RAWs in \(dir.path), found \(raws.count)")
        }
        return Array(raws.prefix(limit))
    }

    private func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func asset(_ url: URL, index: Int) -> Asset {
        Asset(id: "asset-\(index)", sourceRootId: "root", relPath: url.lastPathComponent,
              filename: url.lastPathComponent, ext: url.pathExtension, kind: .raw, size: 1,
              mtime: 0, contentHash: sha256(url.path), width: 9520, height: 6336)
    }

    /// Render the HD thumbnail for every file through the shipped producer, then hand back the 24
    /// paths. This is the cache the sweep decodes — the same 1920 px PQ HEIC the grid reads.
    private func makeHDThumbnails(_ urls: [URL], provider: ThumbnailProvider) -> [URL] {
        let done = expectation(description: "24 HD thumbnails")
        done.expectedFulfillmentCount = urls.count
        done.assertForOverFulfill = false
        for (i, url) in urls.enumerated() {
            provider.request(index: i, asset: asset(url, index: i), fileURL: url,
                             document: .neutral, tier: .t256, spec: .hd,
                             display: ImageSize(width: 326, height: 242)) { _, _, image in
                XCTAssertNotNil(image, "HD producer failed for \(url.lastPathComponent)")
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 900)

        let files = provider.cache.inventory().map(\.url)
        XCTAssertEqual(files.count, urls.count, "one HD file per fixture")
        let sizes = files.compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.size] as? Int }
        let mean = sizes.isEmpty ? 0 : sizes.reduce(0, +) / sizes.count
        print(String(format: "SWEEP cache  %d files, %.1f KB mean, %.1f MB total",
                     files.count, Double(mean) / 1024, Double(sizes.reduce(0, +)) / 1_048_576))
        return files
    }

    // MARK: measurement

    private struct Arm {
        var k: Int
        var wall: Double
        var p50: Double
        var p95: Double
        var throughput: Double
        var busyCores: Double
        var psMax: Double
        var psMean: Double
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let u = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let s = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return u + s
    }

    /// `ps -o %cpu` of this process, sampled every 100 ms while the arm runs. Its number is a decaying
    /// average, so it is reported as a shape (max/mean), not as a precise utilisation.
    private final class PSSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Double] = []
        private var stop = false
        private let pid = String(ProcessInfo.processInfo.processIdentifier)

        func start() {
            let t = Thread { [self] in
                while true {
                    lock.lock(); let done = stop; lock.unlock()
                    if done { return }
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/ps")
                    p.arguments = ["-o", "%cpu=", "-p", pid]
                    let pipe = Pipe()
                    p.standardOutput = pipe
                    try? p.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    if let v = Double(String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)) {
                        lock.lock(); samples.append(v); lock.unlock()
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            t.stackSize = 512 * 1024
            t.start()
        }

        func finish() -> (max: Double, mean: Double) {
            lock.lock(); stop = true; let s = samples; lock.unlock()
            guard !s.isEmpty else { return (0, 0) }
            return (s.max()!, s.reduce(0, +) / Double(s.count))
        }
    }

    private func run(files: [URL], k: Int) -> Arm {
        var latencies = [Double](repeating: 0, count: files.count)
        let sem = DispatchSemaphore(value: k)
        let cpu0 = cpuSeconds()
        let ps = PSSampler(); ps.start()
        let t0 = DispatchTime.now()
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            sem.wait()
            defer { sem.signal() }
            let s = DispatchTime.now()
            if let src = CGImageSourceCreateWithURL(files[i] as CFURL, nil) {
                _ = CGImageSourceCreateImageAtIndex(
                    src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }
            latencies[i] = Double(DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds) / 1e6
        }
        let wall = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        let cpu = cpuSeconds() - cpu0
        let psStat = ps.finish()
        let sorted = latencies.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return Arm(k: k, wall: wall / 1000, p50: p50, p95: p95,
                   throughput: Double(files.count) / (wall / 1000),
                   busyCores: cpu / (wall / 1000), psMax: psStat.max, psMean: psStat.mean)
    }

    func testDecodeConcurrencySweep() throws {
        let urls = try rawFiles(limit: 24)
        let provider = try ThumbnailProvider(cache: try ThumbnailCache(root: root))
        let files = makeHDThumbnails(urls, provider: provider)

        var arms: [Arm] = []
        for k in [1, 2, 3, 4, 6, 8, 10, 12] {
            _ = run(files: files, k: k)                 // warm the page cache
            let arm = run(files: files, k: k)           // the measurement
            arms.append(arm)
            print(String(format: "SWEEP k=%2d  wall %6.0f ms  p50 %6.1f ms  p95 %6.1f ms  "
                         + "%6.1f img/s  cpu %.2f cores  ps max %5.1f%% mean %5.1f%%",
                         arm.k, arm.wall * 1000, arm.p50, arm.p95, arm.throughput,
                         arm.busyCores, arm.psMax, arm.psMean))
        }

        // Saturation: the smallest k whose throughput reaches 90 % / 95 % of the best arm.
        let peak = arms.map(\.throughput).max() ?? 0
        let first90 = arms.first { $0.throughput >= peak * 0.90 }?.k ?? 0
        let first95 = arms.first { $0.throughput >= peak * 0.95 }?.k ?? 0
        print(String(format: "SWEEP peak %.1f img/s · first ≥90%%: k=%d · first ≥95%%: k=%d · "
                     + "k=1 vs best: %.2f×", peak, first90, first95,
                     peak / max(arms.first?.throughput ?? 1, 0.001)))
        print("SWEEP defaultConcurrency in the build: \(ThumbnailProvider.defaultConcurrency)")
    }
}
