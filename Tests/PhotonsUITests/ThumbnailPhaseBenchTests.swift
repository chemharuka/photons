import XCTest
import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 351 — **where does a first screen's time go?** Five legs per cell: `render` (RenderGraph at
/// 1920), `encode` (PQ JPEG), `write` (cache store), `decode` (ImageIO → cell pixels) and the queue
/// (`waited − produced − write`, i.e. admission + `isPaused`/held + waiting for a worker slot).
///
/// Gated on `PHOTONS_THUMB_PHASES=1`: this decodes 24 real RAWs and renders 24 HD thumbnails, which
/// is a benchmark, not a unit test. Every number printed is measured.
///
/// Method:
///   · **24 different files** — one file 24 times would measure the page cache, not the pipeline;
///   · **cold round on an empty cache** — the round the user calls "生成缩略图";
///   · **second round on the same provider** — the hit-rate reading (`hits / renders`);
///   · cell pixels are the grid's real swatch: 460×340 at 1× (the number 308 used).
final class ThumbnailPhaseBenchTests: XCTestCase {

    private let fm = FileManager.default
    private let cell = ImageSize(width: 460, height: 340)

    private func gated() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_THUMB_PHASES"] != nil else {
            throw XCTSkip("set PHOTONS_THUMB_PHASES=1 to measure the thumbnail pipeline")
        }
    }

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

    // MARK: - statistics

    private func stat(_ samples: [Double]) -> (p50: Double, p95: Double, max: Double, mean: Double) {
        guard !samples.isEmpty else { return (0, 0, 0, 0) }
        let s = samples.sorted()
        let p50 = s[s.count / 2]
        let p95 = s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.down)))]
        return (p50, p95, s.last ?? 0, s.reduce(0, +) / Double(s.count))
    }

    private func line(_ name: String, _ v: [Double]) -> String {
        let s = stat(v)
        return String(format: "  %-7s n=%3d  p50 %7.2f  p95 %7.2f  max %7.2f  mean %7.2f",
                      (name as NSString).utf8String!, v.count, s.p50, s.p95, s.max, s.mean)
    }

    private func oneScreen(_ provider: ThumbnailProvider, urls: [URL]) -> Double {
        let done = expectation(description: "24 cells")
        done.expectedFulfillmentCount = urls.count
        done.assertForOverFulfill = false
        let t0 = DispatchTime.now()
        for (i, url) in urls.enumerated() {
            provider.request(index: i, asset: asset(url, index: i), fileURL: url,
                             document: .neutral, tier: .t2048, spec: .hdJPEG,
                             display: cell, priority: .onScreen) { _, _, image in
                XCTAssertNotNil(image, "cell \(i) produced nothing")
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 900)
        return Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
    }

    // MARK: - the measurement

    func testFiveWayBreakdown() throws {
        try gated()
        let urls = try rawFiles(limit: 24)
        let root = fm.temporaryDirectory.appendingPathComponent("photons-phases-\(UUID().uuidString)",
                                                                isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let provider = ThumbnailProvider(cache: try ThumbnailCache(root: root))
        print("PHASE cores \(ProcessInfo.processInfo.activeProcessorCount)"
              + " · defaultConcurrency \(ThumbnailProvider.defaultConcurrency)"
              + " · service maxConcurrency \(provider.service.config.maxConcurrency)")

        // MARK: cold round — an empty cache, i.e. what "生成缩略图" means to the user.
        var latencies = [Double](repeating: 0, count: urls.count)
        let done = expectation(description: "24 cold cells")
        done.expectedFulfillmentCount = urls.count
        done.assertForOverFulfill = false
        let t0 = DispatchTime.now()
        for (i, url) in urls.enumerated() {
            provider.request(index: i, asset: asset(url, index: i), fileURL: url,
                             document: .neutral, tier: .t2048, spec: .hdJPEG,
                             display: cell, priority: .onScreen) { _, _, image in
                XCTAssertNotNil(image, "cold cell \(i) produced nothing")
                latencies[i] = Double(DispatchTime.now().uptimeNanoseconds
                                      - t0.uptimeNanoseconds) / 1e6
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 900)
        let firstScreen = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6

        let stats = provider.serviceStats
        let phases = provider.phaseTimes
        // The queue leg is derived, not timed twice: enqueue→delivery minus the producer's own
        // render+encode and the service's write.
        let produced = phases.render.enumerated().map { $0.element + (phases.encode[safe: $0.offset] ?? 0) }
        let writes = stats.writeTimes
        let queue = latencies.enumerated().map { i, waite in
            max(0, waite - (produced[safe: i] ?? 0) - (writes[safe: i] ?? 0))
        }

        print(String(format: "PHASE cold  first screen %.0f ms · hits %d gen %d writes %d"
                     + " · activePeak %d/%d · queuedPeak %d · sourceProbes %d",
                     firstScreen, stats.hits, stats.missGenerated, stats.writes,
                     stats.activePeak, stats.maxConcurrency, stats.queuedPeak,
                     provider.sourceProbes))
        print(line("cells", latencies))
        print(line("render", phases.render))
        print(line("  rawDec", phases.rawDecode))
        print(line("  grInit", phases.graphInit))
        print(line("  grFrm", phases.graphRender))
        print(line("encode", phases.encode))
        print(line("write", writes))
        print(line("decode", phases.decode))
        print(line("queue", queue))
        let total = ["render": phases.render, "encode": phases.encode, "write": writes,
                     "decode": phases.decode, "queue": queue]
            .mapValues { $0.reduce(0, +) }
        let sum = total.values.reduce(0, +)
        if sum > 0 {
            print("PHASE share " + total.sorted { $0.key < $1.key }
                .map { String(format: "%@ %.0f%%", $0.key, $0.value / sum * 100) }
                .joined(separator: "  "))
        }
        XCTAssertEqual(stats.missGenerated, urls.count,
                       "one render per photo on a cold cache, found \(stats.missGenerated)")
        // 351 — **the producer legs must actually overlap.** The wall clock of the first screen
        // against the sum of the work it contains: one worker gives ≈ 1.0×, the shipped 9 give ≈ 8×.
        // This is the reading a pinned `defaultConcurrency` cannot fake — the config and `activePeak`
        // both looked correct while the decode leg was serialising on one command queue.
        let work = produced.enumerated().reduce(0.0) { running, pair in
            running + pair.element + (writes[safe: pair.offset] ?? 0)
        }
        let overlap = work / max(firstScreen, 0.001)
        print(String(format: "PHASE overlap %.1f× (%.0f ms of producer work in a %.0f ms screen)",
                     overlap, work, firstScreen))
        XCTAssertGreaterThan(overlap, 1.5,
                             "24 cold cells must overlap their decodes: \(work) ms of work in"
                             + " \(firstScreen) ms is \(overlap)×")

        // MARK: warm round — a **fresh** provider over the same directory: memory empty, disk warm.
        // This is the number 308 published (34/27/28 ms), and the one the ≤ 60 ms budget is about.
        var screens: [Double] = []
        var warmHits = 0, warmRenders = 0
        for _ in 0..<3 {
            let fresh = ThumbnailProvider(cache: try ThumbnailCache(root: root))
            screens.append(oneScreen(fresh, urls: urls))
            warmHits = fresh.serviceStats.hits
            warmRenders = fresh.serviceStats.missGenerated
        }
        print(String(format: "PHASE warm  24 cells k=%d: %@ ms (best %.0f) · hits %d renders %d",
                     provider.service.config.maxConcurrency,
                     screens.map { String(format: "%.0f", $0) }.joined(separator: "/"),
                     screens.min() ?? 0, warmHits, warmRenders))
        XCTAssertEqual(warmRenders, 0, "a warm directory must not render anything")
        XCTAssertEqual(warmHits, urls.count, "every warm cell must be a disk hit")
        XCTAssertLessThanOrEqual(screens.min() ?? .infinity, 60,
                                 "24-cell first screen must stay under 60 ms (best of 3)")

        // MARK: one key, three cell sizes, **empty cache** — one render, three decodes.
        let multi = ThumbnailProvider(cache: try ThumbnailCache(root: root.appendingPathComponent(
            "shared-\(UUID().uuidString)", isDirectory: true)))
        let url = urls[0]
        let a = asset(url, index: 0)
        let sizes = [ImageSize(width: 460, height: 340), ImageSize(width: 326, height: 242),
                     ImageSize(width: 68, height: 68)]
        let three = expectation(description: "three cell sizes")
        three.expectedFulfillmentCount = sizes.count
        three.assertForOverFulfill = false
        for size in sizes {
            multi.request(index: 0, asset: a, fileURL: url, document: .neutral, tier: .t2048,
                          spec: .hdJPEG, display: size) { _, _, _ in three.fulfill() }
        }
        wait(for: [three], timeout: 300)
        let multiRenders = multi.generationsPerContent.values.reduce(0, +)
        print("PHASE shared 3 cell sizes · renders \(multiRenders)"
              + " · decodes \(multi.stats.decodes) · distinct keys \(multi.generationCounts.count)")
        XCTAssertEqual(multiRenders, 1, "one contentHash + one editFingerprint ⇒ one render")
        XCTAssertEqual(multi.stats.decodes, 3, "three cell sizes decode the one file three times")

        // MARK: single-cell decode — 1920 PQ JPEG → the cell's pixels.
        let key = ThumbKey.hdJPEG(contentHash: a.contentHash, document: .neutral)
        guard let data = provider.cache.data(for: key) else { return XCTFail("no 1920 file") }
        var decodes: [Double] = []
        for _ in 0..<60 {
            let s = DispatchTime.now()
            _ = ThumbnailProvider.decodeJPEG(data, display: cell)
            decodes.append(Double(DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds) / 1e6)
        }
        print(line("decode1", decodes))
        let full = CGImageSourceCreateWithData(data as CFData, nil)
        let fullImage = full.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        print(String(format: "PHASE file  %d bytes, %d×%d on disk", data.count,
                     fullImage?.width ?? 0, fullImage?.height ?? 0))
        XCTAssertLessThanOrEqual(stat(decodes).p50, 10.0,
                                 "1920 → cell decode must stay under 10 ms")
    }

    // MARK: - does the decode path actually run in parallel?

    /// Four decodes of the same RAW, first one after another, then all at once on four threads.
    /// `ThumbnailProvider.defaultConcurrency` is 9 and the service's `activePeak` reaches it, so a
    /// first screen that still takes 11 s means the *work* is serialised, not the queue — this is the
    /// reading that tells the two apart (351: 4 concurrent decodes bought 1.0×).
    func testDecodeConcurrency() throws {
        try gated()
        let url = try rawFiles(limit: 1)[0]
        let decoder = try RAWDecoder()
        let options = DecodeOptions(scale: 0.25)
        _ = try decoder.decode(url, options: options)   // warm the file + the pipeline

        func wall(_ body: () -> Void) -> Double {
            let s = DispatchTime.now()
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds) / 1e6
        }
        let n = 4
        let seq = wall {
            for _ in 0..<n { _ = try? decoder.decode(url, options: options) }
        }
        let par = wall {
            DispatchQueue.concurrentPerform(iterations: n) { _ in
                _ = try? decoder.decode(url, options: options)
            }
        }
        print(String(format: "DECODE %d sequential %.0f ms · %d parallel %.0f ms · speedup %.2f×",
                     n, seq, n, par, seq / max(par, 0.001)))

        // The same four decodes, but through four `RAWDecoder`s — i.e. four `MTLCommandQueue`s and
        // four `CIContext`s instead of one shared pair. If this is the number that scales, the
        // serialisation is the shared queue and a pool fixes it; if it does not, it is Apple's RAW
        // pipeline and no amount of queueing will help.
        let pool = try (0..<n).map { _ in try RAWDecoder() }
        let pooled = wall {
            DispatchQueue.concurrentPerform(iterations: n) { i in
                _ = try? pool[i].decode(url, options: options)
            }
        }
        print(String(format: "DECODE %d parallel, one decoder each: %.0f ms · %.2f× vs sequential",
                     n, pooled, seq / max(pooled, 0.001)))
    }

    // MARK: - where inside `render` does the time go?

    /// Splits the 3.5 s `render` into its four steps: metadata, RAW decode, `RenderGraph` init and the
    /// graph's own `render`. The last one is repeated on a **second** graph over the same decoded
    /// buffer, which is the only way to tell "the arithmetic is slow" from "each graph compiles its
    /// Metal kernels again".
    func testRenderPhaseSplit() throws {
        try gated()
        let url = try rawFiles(limit: 1)[0]
        let decoder = try RAWDecoder()
        func ms(_ body: () throws -> Void) rethrows -> Double {
            let s = DispatchTime.now()
            try body()
            return Double(DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds) / 1e6
        }
        var edge = 0
        let edgeMs = try ms { edge = ThumbnailProvider.sourceLongEdge(url: url) ?? 0 }
        let decoded = try decoder.decode(url, options: DecodeOptions(scale: 0.25))
        var decodeMs = 0.0
        var decodedImage = decoded
        decodeMs = try ms { decodedImage = try decoder.decode(url, options: DecodeOptions(scale: 0.25)) }

        let longEdge = ThumbSpec.hdJPEG.longEdge
        let w = decodedImage.width, h = decodedImage.height
        let scale = min(1, Double(longEdge) / Double(max(w, h, 1)))
        let options = RenderOptions(canvas: nil, scale: scale,
                                    display: DisplayOptions(primaries: .displayP3, bitDepth: 16,
                                                            headroom: 1, linearOutput: true),
                                    useCache: false, wantsPixels: true)

        var first = 0.0, second = 0.0, third = 0.0
        do {
            var graph: RenderGraph!
            let initMs = try ms {
                graph = try RenderGraph(input: RenderInput(image: decodedImage,
                                                          identity: "probe-1", sourceURL: url),
                                        textureRetention: .none)
            }
            first = try ms { _ = try graph.render(.neutral, options: options) }
            second = try ms { _ = try graph.render(.neutral, options: options) }
            graph.releaseAllTextures()
            print(String(format: "SPLIT edge %.1f ms · decode %.0f ms · graph init %.1f ms"
                         + " · render#1 %.0f ms · render#2 %.0f ms · %d×%d → %.2f",
                         edgeMs, decodeMs, initMs, first, second, w, h, scale))
        }
        do {
            var graph: RenderGraph!
            let initMs = try ms {
                graph = try RenderGraph(input: RenderInput(image: decodedImage,
                                                          identity: "probe-2", sourceURL: url),
                                        textureRetention: .none)
            }
            third = try ms { _ = try graph.render(.neutral, options: options) }
            graph.releaseAllTextures()
            print(String(format: "SPLIT second graph (same pixels): init %.1f ms · render %.0f ms"
                         + " — a fresh graph re-paying the first render's %.0f ms means the cost is"
                         + " per-graph, not per-frame", initMs, third, first))
        }
        print(String(format: "SPLIT source edge %d px", edge))
        _ = decoded.width
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
