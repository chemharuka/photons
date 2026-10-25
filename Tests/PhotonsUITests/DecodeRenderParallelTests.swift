import XCTest
import CoreGraphics
import PhotonsCore
import PhotonsUI

/// Q29 — **the two queues**, measured against the one-queue shape it replaces.
///
/// The bug this file pins down: the loupe developed *and* rendered on one serial queue, so a 60 MP
/// development (~800 ms) stood in front of every pan. The picture froze for the length of the
/// development, and then a flurry of stale frames drained — nothing errored, which is why no
/// assertion caught it.
///
/// What is measured, and why it is measured this way:
///
///   · **A** is the pre-Q29 shape, reproduced honestly: one serial queue, the development queued on
///     it, the pans `sync`ed onto the same queue. It is not a straw man — that is literally what
///     `pumpLadder` did (`queue.async { makeFrame(…full…) }` behind the frames).
///   · **B** is the shape the loupe ships now: the development on its own serial queue, the frames
///     on the render queue, and nothing shared but the decoded buffer.
///   · Both do the *same* work on the *same* file, and they alternate round by round, so neither
///     one inherits the other's thermal state or a warm ImageIO cache it did not earn.
///
/// The frames here are `makeFrame` at the rung the camera is already showing (0.5, a ladder hit):
/// exactly what a pan during the full development renders in the shipped path.
@MainActor
final class DecodeRenderParallelTests: XCTestCase {

    private static let viewport = ImageSize(width: 2560, height: 1600)
    private static let panFrames = 20

    // MARK: - fixture

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func makeController() -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false     // these tests drive every frame themselves
        // The histogram card is a *separate* ~104 ms of GPU work on a windowed 1:1 frame (measured:
        // `testWindowFrameCostFromEachRung`), and it is off in every pan bench in this repo (§11.10
        // quotes 4.0–4.6 ms with it off). It is not the subject here: a pan frame's own cost is.
        controller.collectsHistogram = false
        _ = controller.view
        return controller
    }

    /// One real development, without touching any render state — what a decode queue owns.
    private func develop(_ url: URL, scale: Float) throws {
        let decoder = try RAWDecoder()
        _ = try decoder.decodeDetailed(url, options: DecodeOptions(decoderVersion: nil,
                                                                   exposureEV: 0, scale: scale))
    }

    /// The 1:1 window the camera would show after `step` pans of 16 source pixels.
    private func pannedState(_ step: Int) -> LoupeViewState {
        LoupeViewState(mode: .actual, zoom: 1,
                       centerX: 3000 + Double(step * 16), centerY: 2000 + Double(step * 9))
    }

    private func percentile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }

    // MARK: - the two shapes

    /// A — one queue for developments and frames. The pans wait.
    private func measureSingleQueue(url: URL, round: Int) throws -> [Double] {
        let loupe = makeController()
        let queue = DispatchQueue(label: "q29.single.\(round)")
        // What fit developed before the user pressed Z: the rung on screen.
        _ = try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                edit: .neutral, state: .fit)
        // The development, on the *frames'* queue — `pumpLadder` in one line.
        queue.async { [loupe] in
            _ = try? loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 1,
                                     edit: .neutral, state: .fit)
        }
        Thread.sleep(forTimeInterval: 0.02)      // the development takes the queue (as it did)

        var times: [Double] = []
        for step in 0..<Self.panFrames {
            let state = pannedState(step)
            let t0 = CFAbsoluteTimeGetCurrent()
            queue.sync {
                _ = try? loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                         edit: .neutral, state: state)
            }
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        return times
    }

    /// B — the development has its own queue; the frames keep the render queue.
    private func measureSplitQueues(url: URL, round: Int) throws -> [Double] {
        let loupe = makeController()
        let decodeQueue = DispatchQueue(label: "q29.decode.\(round)")
        let renderQueue = DispatchQueue(label: "q29.render.\(round)")
        _ = try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                edit: .neutral, state: .fit)
        decodeQueue.async { [weak self] in
            guard let self else { return }
            _ = try? self.develop(url, scale: 1)
        }
        Thread.sleep(forTimeInterval: 0.02)

        var times: [Double] = []
        for step in 0..<Self.panFrames {
            let state = pannedState(step)
            let t0 = CFAbsoluteTimeGetCurrent()
            renderQueue.sync {
                _ = try? loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                         edit: .neutral, state: state)
            }
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        return times
    }

    /// Diagnostic: what one 1:1 window frame costs from each rung. The pan budget (8 ms) is a
    /// claim about *this* number, so it has to be measured on the rung the frame actually rides —
    /// and a magnified preview is not the same render as a full-resolution one.
    func testWindowFrameCostFromEachRung() throws {
        let url = try fixtureURL()
        let loupe = makeController()
        loupe.collectsHistogram = false
        let decoder = try RAWDecoder()
        for scale: Float in [0.5, 1] {
            let image = try decoder.decodeDetailed(url, options: DecodeOptions(scale: scale)).image
            let graph = try RenderGraph(input: RenderInput(image: image,
                                                          identity: "diag-\(scale)",
                                                          sourceURL: url))
            let framing = LoupeFraming(viewport: Self.viewport,
                                       decoded: ImageSize(width: image.width, height: image.height),
                                       decodeScale: Double(scale), edit: .neutral)
            var times: [Double] = []
            for step in 0..<6 {
                let state = pannedState(step)
                let window = framing.outputWindow(of: state)
                let rs = framing.renderScale(of: state, decodeScale: Double(scale))
                let t0 = CFAbsoluteTimeGetCurrent()
                let result = try graph.render(.neutral, options: RenderOptions(
                    canvas: Self.viewport, scale: rs, outputWindow: window,
                    useCache: true, wantsPixels: false))
                if let tex = result.output { graph.recycle(output: tex) }
                times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            print(String(format: "Q29 diag rung %.1f (%dx%d) scale %.2f: p50 %6.1f ms  window %@",
                         scale, image.width, image.height,
                         framing.renderScale(of: pannedState(0), decodeScale: Double(scale)),
                         percentile(Array(times.dropFirst()), 0.5),
                         framing.outputWindow(of: pannedState(0))?.keyString ?? "nil"))
        }

        // …and the same frames through the controller, whose frame also collects the histogram.
        _ = try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                edit: .neutral, state: .fit)
        for histogram in [false, true] {
            loupe.collectsHistogram = histogram
            var times: [Double] = []
            for step in 0..<6 {
                let t0 = CFAbsoluteTimeGetCurrent()
                _ = try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                        edit: .neutral, state: pannedState(step))
                times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            print(String(format: "Q29 diag controller 0.5 pan, histogram %@: p50 %6.1f  max %6.1f ms",
                         histogram ? "on " : "off", percentile(Array(times.dropFirst()), 0.5),
                         times.max() ?? 0))
        }
    }

    // MARK: - the measurement

    /// ① — twenty pans while a 60 MP development runs, in both shapes, two rounds alternating.
    func testPanDuringDevelopmentIsNeverSerialisedBehindIt() throws {
        let url = try fixtureURL()
        var aRounds: [[Double]] = []
        var bRounds: [[Double]] = []
        for round in 0..<2 {
            let a = try measureSingleQueue(url: url, round: round)
            let b = try measureSplitQueues(url: url, round: round + 10)
            aRounds.append(a)
            bRounds.append(b)
            print(String(format: "Q29 round %d  A one queue: p50 %6.1f  max %6.1f ms   "
                            + "B two queues: p50 %5.2f  max %5.2f ms",
                         round,
                         percentile(a, 0.5), a.max() ?? 0,
                         percentile(b, 0.5), b.max() ?? 0))
        }

        let aAll = aRounds.flatMap { $0 }
        let bAll = bRounds.flatMap { $0 }
        print(String(format: "Q29 ① 20 pans during the full development: one queue max %.1f ms "
                        + "(the freeze) → two queues p50 %.2f / max %.2f ms (budget 8 per frame)",
                     aAll.max() ?? 0, percentile(bAll, 0.5), bAll.max() ?? 0))

        // The shape that shipped is the one that never blocks. The millisecond budgets are gated on
        // `PHOTONS_BENCH=1` (they drift ±20 % on a machine running other builds); what is asserted on
        // every run is that no frame came anywhere near the development's cost — a *serialised* frame
        // is 800–6000 ms, a free one is 4–12 ms even under load, so 50 ms separates them by 100×.
        XCTAssertLessThan(bAll.max() ?? .infinity, 50.0, "a pan was serialised behind the development")
        if ProcessInfo.processInfo.environment["PHOTONS_BENCH"] != nil {
            XCTAssertLessThanOrEqual(percentile(bAll, 0.5), 8.0, "a pan must fit a frame")
            XCTAssertLessThanOrEqual(percentile(bAll, 0.9), 8.0, "and 36 of 40 frames must too")
            XCTAssertLessThanOrEqual(bAll.max() ?? 0, 16.7,
                                     "no frame may take longer than a 60 Hz interval")
        }
        // …and the shape it replaced really did block, so this file cannot pass vacuously.
        XCTAssertGreaterThan(aAll.max() ?? 0, 100.0, "the one-queue reproduction must reproduce the freeze")
    }
}
