import XCTest
import Foundation
import CryptoKit
import CoreImage
import Metal
import Darwin
@testable import PhotonsCore

/// 359 — **why does `rawDecode` not scale with workers?**
///
/// Gated on `PHOTONS_RAW_BENCH=1`: it decodes 24 real RAWs several times over, which is a benchmark,
/// not a unit test.
///
/// Three readings, all measured, none estimated:
///
///  1. **One decode, split** — `CIRAWFilter(imageURL:)`, the property prep, `outputImage`, the
///     texture, the CPU submit, `waitUntilCompleted`, the GPU's own `gpuStart/gpuEnd`, the readback.
///     The three candidate causes separate here: one queue shows as `gpuWait` growing while `gpu`
///     does not, a rebuilt filter as `filterCreate`, a CPU-side lock as `prepare`/`outputImage`.
///  2. **1 / 2 / 4 / 8 workers** — the same set of decodes through a pool of `workers` decoders,
///     wall clock for the whole set, throughput, per-decode latency and the speedup column.
///  3. **Correctness and memory** — `sha256` of the decoded pixels at 1 and at 8 workers (they must
///     be the same digest), and the process's peak RSS after the 8-way round.
final class RAWDecodeBenchTests: XCTestCase {

    private let fm = FileManager.default

    private func gated() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_RAW_BENCH"] != nil else {
            throw XCTSkip("set PHOTONS_RAW_BENCH=1 to measure RAW decode scaling")
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

    private func sha256(_ image: LinearImage) -> String {
        var digest = SHA256()
        image.rgba.withUnsafeBytes { digest.update(bufferPointer: $0) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Peak resident set of this process, MB. `ru_maxrss` on Darwin is bytes.
    private func peakRSSMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / (1024 * 1024)
    }

    private func wall(_ body: () -> Void) -> Double {
        let t = DispatchTime.now()
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6
    }

    /// Peak **current** resident size of this process, MB — sampled by a watcher thread while a round
    /// runs. `ru_maxrss` cannot answer "how much did 8 workers cost": it is a high-water mark that
    /// never comes down, so the 8-way number would include the 1-way rounds before it.
    private final class RSSWatcher {
        private let lock = NSLock()
        private var peak = 0.0
        private var stop = false
        private var thread: Thread?

        func start() {
            let t = Thread { [weak self] in
                while true {
                    guard let self else { return }
                    self.lock.lock(); let done = self.stop; self.lock.unlock()
                    if done { return }
                    let now = RSSWatcher.residentMB()
                    self.lock.lock(); self.peak = max(self.peak, now); self.lock.unlock()
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            t.qualityOfService = .userInteractive
            thread = t
            t.start()
        }

        func finish() -> Double {
            lock.lock(); stop = true; let p = peak; lock.unlock()
            return p
        }

        static func residentMB() -> Double {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
                                               / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            guard kr == KERN_SUCCESS else { return 0 }
            return Double(info.resident_size) / (1024 * 1024)
        }
    }

    /// One set of `count` decodes spread over `workers` decoders. Each image is hashed and released
    /// immediately — the real pipeline holds a decoded buffer only for the length of one cell's
    /// render, and keeping 24 of them alive would measure the benchmark's array, not the decoder.
    ///
    /// `qos` matters: `DispatchQueue.concurrentPerform` inherits the *caller's* quality of service,
    /// which inside XCTest is `.default`, while `ThumbnailService` runs its producers on
    /// `.userInitiated` workers. A benchmark that ignores that differences itself from the pipeline it
    /// claims to measure, so the real-thread variant is measured beside it.
    private func round(pool: [RAWDecoder], urls: [URL], options: DecodeOptions,
                       count: Int, qos: QualityOfService? = nil) -> (wall: Double, cpu: Double,
                                                                     digests: [String],
                                                                     phases: [RAWDecoder.DecodePhases],
                                                                     peakRSS: Double) {
        var digests = [String?](repeating: nil, count: count)
        let lock = NSLock()
        var phases: [RAWDecoder.DecodePhases] = []
        let workers = pool.count
        let watcher = RSSWatcher()
        watcher.start()
        let cpu0 = RAWDecoder.processCPUMilliseconds()
        let body: (Int) -> Void = { slot in
            var mine: [RAWDecoder.DecodePhases] = []
            var i = slot
            while i < count {
                let decoder = pool[slot]
                if let image = try? decoder.decode(urls[i % urls.count], options: options) {
                    digests[i] = self.sha256(image)
                }
                mine.append(decoder.lastDecodePhases)
                i += workers
            }
            lock.lock(); phases.append(contentsOf: mine); lock.unlock()
        }
        let w = wall {
            if let qos {
                let group = DispatchGroup()
                for slot in 0..<workers {
                    group.enter()
                    let t = Thread { body(slot); group.leave() }
                    t.qualityOfService = qos
                    t.start()
                }
                group.wait()
            } else {
                DispatchQueue.concurrentPerform(iterations: workers, execute: body)
            }
        }
        let cpu = RAWDecoder.processCPUMilliseconds() - cpu0
        let peak = watcher.finish()
        return (w, cpu, digests.compactMap { $0 }, phases, peak)
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s[s.count / 2]
    }

    // MARK: - 1. one decode, split

    func testRawDecodePhaseSplit() throws {
        try gated()
        let urls = try rawFiles(limit: 12)
        let decoder = try RAWDecoder()
        let options = DecodeOptions(scale: 0.25)
        _ = try decoder.decode(urls[0], options: options)     // warm: kernels, file cache

        print("RAWSPLIT core \(ProcessInfo.processInfo.activeProcessorCount)"
              + " · device \(decoder.deviceName) · queue \(decoder.queueIdentity)")
        for (i, url) in urls.enumerated() {
            let ms = wall { _ = try? decoder.decode(url, options: options) }
            let ph = decoder.lastDecodePhases
            print(String(format: "RAWSPLIT %2d %@  %@  (wall %.1f)",
                         i, url.lastPathComponent, ph.summary, ms))
        }

        // The same file twice on **fresh** decoders: what a per-worker decoder costs to stand up,
        // and its first decode (un-warmed kernels) versus the second.
        for n in 0..<2 {
            let t0 = DispatchTime.now()
            let fresh = try RAWDecoder()
            let initMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            let firstMs = wall { _ = try? fresh.decode(urls[0], options: options) }
            let secondMs = wall { _ = try? fresh.decode(urls[0], options: options) }
            print(String(format: "RAWSPLIT fresh decoder #%d init %.1f ms · decode#1 %.0f ms"
                         + " · decode#2 %.0f ms · queue %d",
                         n, initMs, firstMs, secondMs, fresh.queueIdentity))
        }
    }

    // MARK: - 2b. where inside the render does the time go?

    /// Which `CIContext` shape actually runs the RAW pipeline on the GPU?
    ///
    /// Every variant decodes a **fresh** filter (so the demosaic really runs — a second render on the
    /// same output image is 30 ms of CPU because Apple caches the developed frame), and reports the
    /// CPU it burned beside the GPU time the command buffer reports. A GPU render shows `gpu` ≈
    /// `wall` and a small CPU number; the CPU renderer shows the opposite, and
    /// `.useSoftwareRenderer` is the control that proves the two are distinguishable.
    func testRawContextVariants() throws {
        try gated()
        let url = try rawFiles(limit: 1)[0]
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        print("RAWCTX device \(device.name)")

        struct Variant {
            let name: String
            let make: () -> CIContext
        }
        var variants: [Variant] = [
            .init(name: "device + workingCS (current)") {
                CIContext(mtlDevice: device, options: [.workingColorSpace: cs,
                                                       .outputColorSpace: cs,
                                                       .cacheIntermediates: false])
            },
            .init(name: "queue + workingCS") {
                CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: cs,
                                                            .outputColorSpace: cs,
                                                            .cacheIntermediates: false])
            },
            .init(name: "device, default options") { CIContext(mtlDevice: device) },
            .init(name: "device + RGBAh + cache") {
                CIContext(mtlDevice: device, options: [.workingFormat: CIFormat.RGBAh,
                                                       .workingColorSpace: cs,
                                                       .outputColorSpace: cs])
            },
            .init(name: "software renderer") {
                CIContext(options: [.useSoftwareRenderer: true,
                                    .workingColorSpace: cs, .outputColorSpace: cs])
            },
        ]

        for v in variants {
            let ctx = v.make()
            let f0 = CACurrentMediaTime()
            guard let filter = CIRAWFilter(imageURL: url) else { return XCTFail("filter") }
            filter.boostAmount = 0
            filter.isGamutMappingEnabled = false
            filter.scaleFactor = 0.25
            guard let out = filter.outputImage else { return XCTFail("output") }
            let e = out.extent.integral
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                             width: Int(e.width), height: Int(e.height),
                                                             mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]
            d.storageMode = .shared
            let texture = device.makeTexture(descriptor: d)!
            let cb = queue.makeCommandBuffer()!
            let c0 = RAWDecoder.processCPUMilliseconds()
            let w0 = CACurrentMediaTime()
            ctx.render(out, to: texture, commandBuffer: cb, bounds: e, colorSpace: cs)
            cb.commit()
            cb.waitUntilCompleted()
            let wallMs = (CACurrentMediaTime() - w0) * 1000
            let cpuMs = RAWDecoder.processCPUMilliseconds() - c0
            print(String(format: "RAWCTX %-28@ filter %5.0f ms · render wall %6.0f ms"
                         + " · cpu %6.0f ms · %.2f threads · gpu %5.0f ms",
                         v.name, (w0 - f0) * 1000, wallMs, cpuMs, cpuMs / max(wallMs, 0.001),
                         (cb.gpuEndTime - cb.gpuStartTime) * 1000))
        }
    }


    /// Four decodes that separate "per-pixel work" from "per-render setup", and "CPU" from "GPU":
    ///
    ///  · **filter only** — `CIRAWFilter(imageURL:)` with no render;
    ///  · **render #1 / #2 on the same filter** — if #2 is much cheaper, the first render pays a
    ///    one-time pipeline setup; if they match, the cost is per-pixel;
    ///  · **scale 1.0** — if the cost tracks the *output* pixels it is resampling, if it barely moves
    ///    it is the full-sensor demosaic that dominates;
    ///  · **`createCGImage`** — Core Image's own path, no command buffer of ours, for comparison with
    ///    the explicit-queue render.
    func testRawPipelineProbe() throws {
        try gated()
        let url = try rawFiles(limit: 1)[0]
        let decoder = try RAWDecoder()
        print("RAWPIPE device \(decoder.deviceName)")

        func wall() -> Double { CACurrentMediaTime() * 1000 }

        func timed(_ name: String, _ body: () -> Void) {
            let c0 = RAWDecoder.processCPUMilliseconds()
            let w0 = wall()
            body()
            let w = wall() - w0
            let c = RAWDecoder.processCPUMilliseconds() - c0
            print(String(format: "RAWPIPE %-22@ wall %7.1f ms · cpu %7.1f ms · %.2f×threads",
                         name, w, c, c / max(w, 0.001)))
        }

        var filter: CIRAWFilter?
        timed("filter create") { filter = CIRAWFilter(imageURL: url) }
        guard let filter else { return XCTFail("filter") }
        filter.boostAmount = 0
        filter.isGamutMappingEnabled = false
        filter.scaleFactor = 0.25
        guard let output = filter.outputImage else { return XCTFail("outputImage") }

        // Same context, same output image, twice. `render` needs a texture; one is made outside the
        // timed block so only the render is measured.
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let ctx = CIContext(options: [.workingColorSpace: cs, .outputColorSpace: cs,
                                      .cacheIntermediates: false])
        let e = output.extent.integral
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                            width: Int(e.width), height: Int(e.height),
                                                            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .shared
        let texture = device.makeTexture(descriptor: desc)!

        for pass in 1...2 {
            timed("render #\(pass) (explicit q)") {
                let cb = queue.makeCommandBuffer()!
                ctx.render(output, to: texture, commandBuffer: cb, bounds: e, colorSpace: cs)
                cb.commit()
                cb.waitUntilCompleted()
            }
        }
        timed("createCGImage") {
            _ = ctx.createCGImage(output, from: e, format: .RGBAh, colorSpace: cs)
        }

        // scale 1.0 on a fresh filter: the output is 60 MP, so a resample-bound pipeline must be
        // ~16× the cost of 0.25 and a demosaic-bound one will barely move.
        var full: CIRAWFilter?
        timed("filter create (full)") { full = CIRAWFilter(imageURL: url) }
        if let full {
            full.boostAmount = 0
            full.isGamutMappingEnabled = false
            full.scaleFactor = 1
            if let out = full.outputImage {
                timed("render scale 1.0") {
                    let cb = queue.makeCommandBuffer()!
                    let d = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .rgba16Float, width: Int(out.extent.width),
                        height: Int(out.extent.height), mipmapped: false)
                    d.usage = [.shaderRead, .shaderWrite, .renderTarget]
                    d.storageMode = .shared
                    if let t = device.makeTexture(descriptor: d) {
                        ctx.render(out, to: t, commandBuffer: cb, bounds: out.extent, colorSpace: cs)
                    }
                    cb.commit()
                    cb.waitUntilCompleted()
                }
            }
        }
    }

    // MARK: - 3. worker-count table, digest, memory

    func testRawDecodeScaling() throws {
        try gated()
        let urls = try rawFiles(limit: 24)
        let options = DecodeOptions(scale: 0.25)
        let perRound = 24
        // One warm-up decode so the first row is not paying kernel compilation.
        do {
            let warm = try RAWDecoder()
            _ = try warm.decode(urls[0], options: options)
        } catch { XCTFail("warm-up decode failed: \(error)") }

        print("RAWSCALE 24 files · \(perRound) decodes per round · scale \(options.scale)"
              + " · peak RSS before \(String(format: "%.0f", peakRSSMB())) MB")

        var baseline = 0.0
        var peakAt: [Int: Double] = [:]
        var digests: [Int: [String]] = [:]
        var speedups: [Int: Double] = [:]
        for workers in [1, 2, 4, 8, 16] {
            let pool = try (0..<workers).map { _ in try RAWDecoder() }
            let result = round(pool: pool, urls: urls, options: options, count: perRound)
            let w = result.wall
            peakAt[workers] = result.peakRSS
            if workers == 1 { baseline = w }
            speedups[workers] = baseline / w
            digests[workers] = result.digests
            XCTAssertEqual(result.digests.count, perRound,
                           "\(workers)-way round produced \(result.digests.count)/\(perRound)")
            let totals = result.phases.map { $0.total }
            print(String(format: "RAWSCALE workers %d · wall %7.0f ms · %.2f decodes/s"
                         + " · per-decode p50 %6.0f ms · speedup %.2f×"
                         + " · max case %.0f ms · live RSS peak %.0f MB",
                         workers, w, Double(perRound) / (w / 1000),
                         median(totals), baseline / w, totals.max() ?? 0, result.peakRSS))
            print(String(format: "   cpu %.1f s for the round · %.2f cores busy"
                         + " · per decode %.0f ms CPU",
                         result.cpu / 1000, result.cpu / w,
                         result.cpu / Double(perRound)))
            print(String(format: "   phases p50 @%dw: filter %.0f · prepare %.0f · outputImage %.0f"
                         + " · texture %.0f · submit %.0f (cpu %.0f) · gpuWait %.0f · gpu %.0f"
                         + " · bytes %.0f · flip %.0f · queues %d",
                         workers,
                         median(result.phases.map { $0.filterCreate }),
                         median(result.phases.map { $0.prepare }),
                         median(result.phases.map { $0.outputImage }),
                         median(result.phases.map { $0.textureMake }),
                         median(result.phases.map { $0.submit }),
                         median(result.phases.map { $0.cpuSubmit }),
                         median(result.phases.map { $0.gpuWait }),
                         median(result.phases.map { $0.gpu }),
                         median(result.phases.map { $0.readbackBytes }),
                         median(result.phases.map { $0.rowFlip }),
                         Set(result.phases.map { $0.queueID }).count))
        }

        print(String(format: "RAWSCALE speedups 1×%.2f 2×%.2f 4×%.2f 8×%.2f 16×%.2f",
                     speedups[1] ?? 0, speedups[2] ?? 0, speedups[4] ?? 0,
                     speedups[8] ?? 0, speedups[16] ?? 0))

        // Is the ceiling a per-file lock? The same 24 decodes again, 8 workers, **one file**.
        do {
            let pool = try (0..<8).map { _ in try RAWDecoder() }
            let one = [urls[0]]
            let result = round(pool: pool, urls: one, options: options, count: perRound)
            print(String(format: "RAWSCALE same file ×8 workers · wall %7.0f ms · %.2f decodes/s"
                         + " · %.2f cores · per-decode p50 %.0f ms",
                         result.wall, Double(perRound) / (result.wall / 1000), result.cpu / result.wall,
                         median(result.phases.map { $0.total })))
        }

        // 4. the digest must not depend on how many workers ran.
        XCTAssertEqual(digests[1] ?? [], digests[8] ?? [],
                       "1-way and 8-way decoding of the same files must agree byte for byte")
        print("RAWSHA 1-way \(digests[1]?.first ?? "none")")
        print("RAWSHA 8-way \(digests[8]?.first ?? "none")")
        if let first = digests[1]?.first {
            print("RAWSHA identical \(digests[1]?.first == digests[8]?.first) all24 "
                  + "\(digests[1] == digests[8])")
            _ = first
        }

        // 5. memory: the 8-way working set against the 1-way working set.
        let one = peakAt[1] ?? 0, eight = peakAt[8] ?? 0
        print(String(format: "RAWRSS 1-way live peak %.0f MB · 8-way live peak %.0f MB · ratio %.2f×",
                     one, eight, eight / max(one, 1)))
        XCTAssertLessThanOrEqual(eight, one * 1.6,
                                 "8-way peak RSS \(eight) MB is above 1.6× the 1-way \(one) MB")
    }

    // MARK: - 4. the acceptance gate: 4 workers must buy ≥ 3.0×

    /// The one assertion 359 is judged on. `PHOTONS_RAW_SINGLE_QUEUE=1` re-creates the shape this
    /// ticket exists to rule out — every decoder on one process-wide queue and one `CIContext` — and
    /// this test must then fail. That is what makes the number a measurement of the queue and not of
    /// the weather.
    ///
    /// The ticket's acceptance number, kept as an assertion on purpose: **it is red on this machine,
    /// and that is the finding.** 4-way lands at 2.2–2.8×, because a single decode already spends
    /// ~830 ms of CPU on ~3.3 threads inside Apple's RAW demosaic (see
    /// `docs/tasks/359-raw-decode-concurrency.md` §3): four of them need ~13 threads on a 10-core
    /// machine, so each slows down instead of adding throughput. `PHOTONS_RAW_SINGLE_QUEUE=1` — the
    /// shape the ticket blamed — measures 1.88×, i.e. the queue is *not* what caps this.
    ///
    /// Both rows use `.userInitiated` threads, which is what `ThumbnailService`'s worker queue is;
    /// the plain-`concurrentPerform` row is printed beside them because XCTest's calling thread is
    /// `.default` and that alone moves the number.
    func testFourWaySpeedup() throws {
        try gated()
        let urls = try rawFiles(limit: 24)
        let options = DecodeOptions(scale: 0.25)
        let perRound = 24

        let warm = try RAWDecoder()
        _ = try warm.decode(urls[0], options: options)

        let solo = round(pool: [warm], urls: urls, options: options, count: perRound,
                         qos: .userInitiated)
        let four = try round(pool: try (0..<4).map { _ in try RAWDecoder() },
                             urls: urls, options: options, count: perRound,
                             qos: .userInitiated)
        let eight = try round(pool: try (0..<8).map { _ in try RAWDecoder() },
                              urls: urls, options: options, count: perRound,
                              qos: .userInitiated)
        let fourDefault = try round(pool: try (0..<4).map { _ in try RAWDecoder() },
                                    urls: urls, options: options, count: perRound)
        let s4 = solo.wall / four.wall
        let s8 = solo.wall / eight.wall
        // 351's own reading, repeated: **four decodes of one file**, one after another, then all four
        // at once. This is a burst, not a sustained table — no queue, no second wave — and it is the
        // number the ticket quotes (1.42× through one decoder).
        let burstURL = [urls[0]]
        let single = try RAWDecoder()
        _ = try single.decode(urls[0], options: options)
        let seq = wall {
            for _ in 0..<4 { _ = try? single.decode(urls[0], options: options) }
        }
        let burstPool = try (0..<4).map { _ in try RAWDecoder() }
        let par = wall {
            let group = DispatchGroup()
            for slot in 0..<4 {
                group.enter()
                let t = Thread { _ = try? burstPool[slot].decode(burstURL[0], options: options)
                                 group.leave() }
                t.qualityOfService = .userInitiated
                t.start()
            }
            group.wait()
        }
        let burst = seq / par
        print(String(format: "RAWMODE singleQueueGate=%@ · 1-way %.0f ms (%.0f ms/decode)"
                     + " · 4-way %.0f ms (%.2f×) · 8-way %.0f ms (%.2f×)"
                     + " · 4-way default-QoS %.0f ms (%.2f×)"
                     + " · live RSS 1-way %.0f MB / 8-way %.0f MB (%.2f×)"
                     + " · digests equal %@",
                     RAWDecoder.singleQueueGate ? "on" : "off",
                     solo.wall, solo.wall / Double(perRound), four.wall, s4, eight.wall, s8,
                     fourDefault.wall, solo.wall / fourDefault.wall,
                     solo.peakRSS, eight.peakRSS, eight.peakRSS / max(solo.peakRSS, 1),
                     solo.digests == eight.digests ? "yes" : "NO"))
        print(String(format: "RAWBURST 4 decodes one file · sequential %.0f ms · 4 concurrent %.0f ms"
                     + " · %.2f× (gate=%@ · single decoder %@)",
                     seq, par, burst, RAWDecoder.singleQueueGate ? "on" : "off",
                     burst >= 3.0 ? "passes" : "below 3.0×"))

        XCTAssertEqual(solo.digests, eight.digests,
                       "1-way and 8-way decodes of the same files must be byte identical")
        XCTAssertLessThanOrEqual(eight.peakRSS, solo.peakRSS * 1.6,
                                 "8-way working set must stay within 1.6× the 1-way set")
        XCTAssertGreaterThanOrEqual(s4, 3.0, String(format:
            "4-way RAW decode speedup %.2f× is below 3.0× (gate=%@, 1-way %.0f ms, 4-way %.0f ms)",
            s4, RAWDecoder.singleQueueGate ? "on" : "off", solo.wall, four.wall))
    }
}
