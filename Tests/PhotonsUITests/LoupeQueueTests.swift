import XCTest
import CoreGraphics
import PhotonsCore
import PhotonsUI

/// Q29 on the **shipped path**: the loupe's own two queues, driven through `scheduleRender` /
/// `requestViewportRender` — not a hand-rolled imitation of them.
///
/// The four acceptance numbers, and how each is made checkable:
///
///   ① twenty pans while a 60 MP development runs: every frame inside a frame budget. Measured as
///      `requestViewportRender()` → the frame reaching the canvas, which is the latency a hand feels.
///   ② the 1:1 first frame does not regress: entering 1:1 while only the preview rung exists opens on
///      that rung in one render, never on a development.
///   ③ full-resolution ready time does not regress: cold open → a frame at scale 1 on the canvas,
///      against the *same work done inline* (the pre-Q29 shape) on the same machine, in the same
///      process, alternating rounds.
///   ④ `fit ↔ 1:1` still develops two rungs and no more, counted in `DecodeLadder`/`RAWDecoder`.
///
/// The ordering rules are asserted on counts, never on a clock: `rungArrivals` (rungs that entered the
/// ladder), `staleRungDrops` (deliveries that were **not** painted), and the queue's own
/// `decodes`/`deliveries`/`drops`. A stale result may be cached; it must never reach the canvas, and a
/// cancelled photo must not call back at all.
///
/// Absolute, user-facing numbers (52 ms first frame, 8 ms per pan, 4.9 ms warm) are asserted only
/// under `PHOTONS_BENCH=1`: on a machine that is building two other things at once they drift by
/// ±20 %, and a red test must mean a regression rather than a busy CPU. The *semantics* — counts,
/// ordering, interval overlap — are asserted on every run, and the numbers are printed on every run
/// so the gate is a formality, not a blind spot.
///
/// The controller gets a real window (as `LoupeRenderTests`' EDR test does): `present` needs a
/// drawable, and a failed hand-off would make the layer fall back to 8-bit and re-render once — noise
/// this file does not want in its frame counts.
@MainActor
final class LoupeQueueTests: XCTestCase {

    private static let viewport = ImageSize(width: 2560, height: 1600)
    private var windows: [NSWindow] = []

    /// `PHOTONS_BENCH=1` turns the absolute millisecond budgets on (see the note above).
    private var benchmarks: Bool { ProcessInfo.processInfo.environment["PHOTONS_BENCH"] != nil }

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - fixtures

    private func fixture(_ name: String) throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/\(name)").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func rawFixture() throws -> URL { try fixture("L1030433.dng") }

    /// A second, different photograph — the "the user moved to the next photo" case.
    private func otherFixture() throws -> URL {
        for name in ["L1030402.dng", "L1030403.dng", "L1030404.dng", "L1030405.dng"] {
            if let url = try? fixture(name) { return url }
        }
        throw XCTSkip("no second RAW fixture for the photo-switch test")
    }

    private func makeController(source: LoupeController.FrameSource,
                                windowed: Bool = true) -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false     // each test arms rendering itself
        // The histogram card used to cost every windowed 1:1 frame +8 ms (release; +104 ms in a debug
        // build). Q30 made it a *settled-camera* measurement — a pan frame skips it — so keeping it off
        // here is about matching the pre-005f baseline these numbers quote (§11.10: 4.0–4.6 ms), not
        // about hiding a cost: `HistogramCadenceTests` measures a pan with the card on.
        controller.collectsHistogram = false
        controller.frameSource = source
        if windowed {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = controller.view
            controller.canvasView.frame = window.contentLayoutRect
            windows.append(window)
            // Let the window's first layout happen *before* the test arms rendering: a layout pass
            // calls `scheduleRender`, which bumps the generation — an expected behaviour in the app
            // (a resize is a new intent) and a trap for a test that has frames in flight.
            controller.view.layoutSubtreeIfNeeded()
            pump(0.05)
        } else {
            _ = controller.view
        }
        return controller
    }

    private func source(_ url: URL, identity: String,
                        state: LoupeViewState = .fit) -> LoupeController.FrameSource {
        LoupeController.FrameSource(url: url, identity: identity, viewport: Self.viewport, state: state)
    }

    private func pannedState(_ step: Int) -> LoupeViewState {
        LoupeViewState(mode: .actual, zoom: 1,
                       centerX: 3000 + Double(step * 16), centerY: 2000 + Double(step * 9))
    }

    // MARK: - main-thread pumping

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 120,
                         _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    /// Pump until nothing is moving: the decode queue idle **and** the frame count unchanged for four
    /// consecutive checks.
    ///
    /// Both halves are needed. A frame's render is not on the decode queue, so "the decode queue is
    /// empty" alone returns while a 60 MP render is still in flight; and a rung's arrival starts the
    /// *next* development, so one idle check can be the gap between two of them.
    private func settle(_ controller: LoupeController, timeout: TimeInterval = 180) {
        let deadline = Date().addingTimeInterval(timeout)
        var stable = 0
        var lastFrames = -1
        while Date() < deadline && stable < 4 {
            pump(0.05)
            let frames = controller.viewRenderCount + controller.editRenderCount
            let idle = controller.awaitPendingDevelopments(timeout: 30)
            if idle, frames == lastFrames { stable += 1 } else { stable = 0 }
            lastFrames = frames
        }
        XCTAssertEqual(stable, 4, "the loupe never went quiet")
    }

    private func percentile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }

    // MARK: - ① pans during a development

    /// ① Twenty pans while the 60 MP development runs. Every one of them renders from the resident
    /// preview rung; none of them waits for ImageIO.
    ///
    /// Also the "one replacement" assertion: those twenty pan frames each asked for the full rung, the
    /// decode queue folded all twenty into the one development already on its way, and the single
    /// arrival repaints **once** — 20 pan frames + 1 preview + 1 replacement = 22 frames, not 42.
    func testTwentyPansWhileTheFullDevelopmentRuns() throws {
        let url = try rawFixture()
        let loupe = makeController(source: source(url, identity: "A"))
        loupe.autoRenderEnabled = true
        loupe.scheduleRender()

        // The preview rung is what the user is looking at when they start dragging.
        XCTAssertTrue(waitFor { loupe.lastPresentedScale == DecodeLadder.previewScale },
                      "the preview rung never reached the canvas")
        XCTAssertEqual(loupe.rungArrivals, 1, "only the preview has landed; the full one is coming")

        var render: [Double] = []
        var latency: [Double] = []
        for step in 0..<20 {
            loupe.frameSource = source(url, identity: "A", state: pannedState(step))
            let before = loupe.viewRenderCount
            let t0 = CFAbsoluteTimeGetCurrent()
            loupe.requestViewportRender()
            XCTAssertTrue(waitFor(10) { loupe.viewRenderCount > before },
                          "pan \(step) never reached the canvas")
            latency.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            render.append(loupe.lastFrame?.renderMilliseconds ?? 0)
        }
        print("Q29 ① per-frame render: "
              + render.map { String(format: "%.1f", $0) }.joined(separator: " ") + " ms")
        print(String(format: "Q29 ① 20 pans during the full development: render p50 %.2f / max %.2f ms "
                        + "(budget 8, baseline 4.9 warm) · request→canvas p50 %.2f / max %.2f ms "
                        + "(60 Hz frame 16.7) · pre-Q29 the first pan waited 5906 ms",
                     percentile(render, 0.5), render.max() ?? 0,
                     percentile(latency, 0.5), latency.max() ?? 0))

        // The median is a frame; the tail is GPU contention with the 60 MP development (and with
        // anything else on the machine) — a *serialised* frame would be 800–6000 ms in the first
        // slot, which no tail allowance could hide. So: the budget on p50 **and** p90, and "no frame
        // beyond one 60 Hz interval" on the worst case.
        if benchmarks {
            XCTAssertLessThanOrEqual(percentile(render, 0.5), 8.0,
                                     "a pan's own render must fit the budget while ImageIO is busy")
            XCTAssertLessThanOrEqual(percentile(render, 0.9), 8.0,
                                     "and 19 of 20 frames must too, not just the median")
            XCTAssertLessThanOrEqual(latency.max() ?? 0, 16.7,
                                     "…and the whole request→canvas hop must fit a 60 Hz frame")
        }
        // Unconditional, and load-proof by an order of magnitude: a pan that was queued behind the
        // development costs 800–6000 ms (measured), a free one costs 4–12 ms even on a busy machine.
        XCTAssertLessThan(latency.max() ?? .infinity, 50,
                          "a pan was serialised behind the development")
        XCTAssertEqual(loupe.lastPresentedScale, DecodeLadder.previewScale,
                       "the pans ride the preview rung: the full one is still being developed")
        XCTAssertEqual(loupe.rungArrivals, 1, "only the preview rung has landed so far")

        settle(loupe)
        XCTAssertEqual(loupe.lastPresentedScale, DecodeLadder.fullScale,
                       "the replacement frame must put the full rung on screen")
        XCTAssertEqual(loupe.rungArrivals, 2, "two rungs, two arrivals")
        XCTAssertEqual(loupe.viewRenderCount, 22,
                       "20 pans + the preview frame + exactly one replacement — a duplicate arrival "
                       + "must never repaint")
        XCTAssertEqual(loupe.developmentStats.decodes, 2,
                       "twenty pans asked for the full rung twenty times and cost one development")
        XCTAssertGreaterThanOrEqual(loupe.developmentStats.coalesced, 19)
    }

    // MARK: - ② the 1:1 first frame

    /// ② Entering 1:1 while the full rung is still being developed opens on the preview rung in one
    /// render. Pre-Q29 that was 52 ms cold (a graph built for the rung, one window render); it must not
    /// get slower, and it must never become a development.
    func testOneToOneFirstFrameOpensOnThePreviewRung() throws {
        let url = try rawFixture()
        // The user pressed Z during the fit development: the first frame this loupe produces is a 1:1
        // window, from a graph that does not exist yet — the pessimistic case.
        let loupe = makeController(source: source(url, identity: "A", state: pannedState(0)))
        loupe.autoRenderEnabled = true
        let t0 = CFAbsoluteTimeGetCurrent()
        loupe.scheduleRender()
        XCTAssertTrue(waitFor { loupe.viewRenderCount >= 1 },
                      "the first 1:1 frame never reached the canvas")
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let first = try XCTUnwrap(loupe.lastFrame)
        print(String(format: "Q29 ② 1:1 first frame: render %.1f ms (%.0f ms from the request, which "
                        + "includes the preview development) · baseline 52 ms cold / 4.9 ms warm",
                     first.renderMilliseconds, elapsed))

        XCTAssertEqual(loupe.lastPresentedScale, DecodeLadder.previewScale,
                       "1:1 must open on the resident preview rung, not wait for the full one")
        XCTAssertEqual(loupe.rungArrivals, 1,
                       "the first 1:1 frame must land while the full rung is still being developed")
        if benchmarks {
            XCTAssertLessThanOrEqual(first.renderMilliseconds, 60,
                                     "the preview frame's own render must fit the 60 ms budget")
        }

        // Warm: once the full rung is resident, the same 1:1 frame is a render-only frame.
        settle(loupe)
        let before = loupe.viewRenderCount
        let warmStart = CFAbsoluteTimeGetCurrent()
        loupe.requestViewportRender()
        XCTAssertTrue(waitFor { loupe.viewRenderCount > before })
        let warm = (CFAbsoluteTimeGetCurrent() - warmStart) * 1000
        print(String(format: "Q29 ② 1:1 warm frame (full rung resident): %.1f ms total · render "
                        + "%.1f ms · baseline 4.9 ms", warm,
                     loupe.lastFrame?.renderMilliseconds ?? 0))
        XCTAssertEqual(loupe.lastPresentedScale, DecodeLadder.fullScale)
        if benchmarks {
            XCTAssertLessThanOrEqual(warm, 40, "a warm 1:1 frame must stay a frame, not a stage rebuild")
        }
        XCTAssertEqual(loupe.developmentStats.decodes, 2,
                       "entering 1:1 asks for the full rung; it must not develop the preview twice")
    }

    // MARK: - ③ full-resolution ready time

    /// ③ Cold open → a full-resolution frame on the canvas, against the *same work inline* (the
    /// pre-Q29 shape: develop then render, synchronously, no queue split). Two rounds, alternating, so
    /// neither number gets the other's warm ImageIO cache for free.
    func testFullRungReadyTimeDoesNotRegress() throws {
        let url = try rawFixture()
        var inline: [Double] = []
        var split: [Double] = []

        for round in 0..<2 {
            // A — inline: exactly what `pumpLadder` did for its two rungs.
            let a = makeController(source: source(url, identity: "inline-\(round)"))
            let tA = CFAbsoluteTimeGetCurrent()
            _ = try a.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                edit: .neutral, state: .fit)
            _ = try a.makeFrame(url: url, viewport: Self.viewport, decodeScale: 1,
                                edit: .neutral, state: .fit)
            inline.append((CFAbsoluteTimeGetCurrent() - tA) * 1000)

            // B — the shipped split: two queues, the ladder, one replacement per rung.
            let b = makeController(source: source(url, identity: "split-\(round)"))
            b.autoRenderEnabled = true
            let tB = CFAbsoluteTimeGetCurrent()
            b.scheduleRender()
            XCTAssertTrue(waitFor { b.lastPresentedScale == DecodeLadder.fullScale },
                          "the full rung never reached the canvas")
            split.append((CFAbsoluteTimeGetCurrent() - tB) * 1000)
            print(String(format: "Q29 ③ round %d: inline %.0f ms → two queues %.0f ms (%.1f%%)",
                         round, inline[round], split[round],
                         (split[round] / inline[round] - 1) * 100))
        }

        let inlineP50 = percentile(inline, 0.5), splitP50 = percentile(split, 0.5)
        print(String(format: "Q29 ③ full-resolution ready: inline %.0f ms → split %.0f ms "
                        + "(budget: within 5%% of baseline 860 ms)", inlineP50, splitP50))
        XCTAssertLessThanOrEqual(splitP50, inlineP50 * 1.05 + 5,
                                 "the queue split must not cost 5% of the ready time")
    }

    // MARK: - ④ the decode count

    /// ④ `fit ↔ 1:1` still develops each rung exactly once. The count comes from the decoder, not from
    /// a timing: a second development of the same rung is cheap to hide inside a slow frame.
    func testFitAndOneToOneStillDevelopEachRungOnce() throws {
        let url = try rawFixture()
        RAWDecoder.resetDecodeCounts()
        let loupe = makeController(source: source(url, identity: "count"))
        loupe.autoRenderEnabled = true
        loupe.scheduleRender()
        settle(loupe)
        XCTAssertEqual(loupe.lastPresentedScale, DecodeLadder.fullScale)
        XCTAssertEqual(RAWDecoder.decodeCounts(), [0.5: 1, 1: 1])
        let decodesAfterOpen = loupe.developmentStats.decodes

        for round in 0..<5 {
            loupe.frameSource = source(url, identity: "count", state: round.isMultiple(of: 2)
                                       ? .fit : pannedState(0))
            let before = loupe.viewRenderCount
            loupe.requestViewportRender()
            XCTAssertTrue(waitFor(20) { loupe.viewRenderCount > before },
                          "round \(round) never reached the canvas")
            XCTAssertEqual(loupe.lastPresentedScale, DecodeLadder.fullScale)
        }
        settle(loupe)
        print("Q29 ④ fit↔1:1 ×5 rounds: decoder counts "
              + "\(RAWDecoder.decodeCounts().sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" })"
              + ", development queue \(loupe.developmentStats)")
        XCTAssertEqual(RAWDecoder.decodeCounts(), [0.5: 1, 1: 1],
                       "switching fit ↔ 1:1 must never develop the file again")
        XCTAssertEqual(loupe.developmentStats.decodes, decodesAfterOpen,
                       "and must not ask the decode queue again either")
    }

    // MARK: - ordering: generations, photos, cancellation

    /// A photo switch cancels the old photo's queued developments and refuses the delivery of the one
    /// running: the canvas ends up showing the **new** photo's pixels, and the old rungs never evict
    /// them. Asserted on pixels (the displayed hash), not on an intention.
    func testSwitchingPhotoNeverPaintsOrEvictsTheOldRungs() throws {
        let a = try rawFixture()
        let b = try otherFixture()
        let loupe = makeController(source: source(a, identity: "photo-a"))
        loupe.hashesFrames = true
        loupe.autoRenderEnabled = true
        loupe.scheduleRender()
        // Let bit A get into a development before the photo changes.
        XCTAssertTrue(waitFor { loupe.developmentStats.decodes >= 1 }, "A never started developing")

        loupe.frameSource = source(b, identity: "photo-b")
        loupe.scheduleRender()
        XCTAssertTrue(waitFor { loupe.lastPresentedScale == DecodeLadder.fullScale },
                      "photo B never reached the canvas")
        settle(loupe)

        let shown = try XCTUnwrap(loupe.lastFrame?.displayHash, "nothing reached the canvas")
        let bHash = try XCTUnwrap(try loupe.makeFrame(url: b, viewport: Self.viewport, decodeScale: 1,
                                                      edit: .neutral, state: .fit,
                                                      hashPixels: true).displayHash)

        XCTAssertEqual(shown, bHash, "the canvas must show the photo that is on screen now")
        print("Q29 photo switch: stale deliveries dropped \(loupe.staleRungDrops), "
              + "queue \(loupe.developmentStats), arrivals \(loupe.rungArrivals)")
        XCTAssertGreaterThanOrEqual(loupe.developmentStats.drops, 1,
                                    "A's queued/running development must not be delivered")
        XCTAssertEqual(loupe.lastPresentedScale, DecodeLadder.fullScale)
    }

    /// Cancelling (leaving the loupe) delivers nothing at all: no arrival, no frame, no error.
    func testCancellingFramesDeliversNothing() throws {
        let url = try rawFixture()
        let loupe = makeController(source: source(url, identity: "cancelled"))
        loupe.autoRenderEnabled = true
        loupe.scheduleRender()
        XCTAssertTrue(waitFor { loupe.developmentStats.decodes >= 1 }, "the development never started")
        loupe.cancelPendingFrames()
        settle(loupe)

        print("Q29 cancel: arrivals \(loupe.rungArrivals), frames \(loupe.viewRenderCount), "
              + "queue \(loupe.developmentStats)")
        XCTAssertEqual(loupe.rungArrivals, 0, "a cancelled photo must not reach the ladder")
        XCTAssertEqual(loupe.viewRenderCount, 0, "…and must not reach the canvas")
        XCTAssertNil(loupe.lastPresentedScale)
        XCTAssertNil(loupe.lastFrame)
        XCTAssertGreaterThanOrEqual(loupe.developmentStats.drops, 1, "…and its delivery is refused")
    }

    /// The generation rule, isolated: a development that lands after the camera moved on is **cached
    /// and the current camera is asked for one frame** — the stale *pixels* are never painted, but the
    /// buffer must not sit invisible either.
    ///
    /// That second half is the 2026-10-26 correction of the original rule ("cache but never paint").
    /// The original version left a photo opened while the display was settling permanently black (the
    /// headroom re-read bumps the generation twice on the way into the loupe), and it also left a 0.5
    /// preview on screen after the full rung had landed; the user's only cure was to touch the camera.
    /// Repainting here is a frame at the camera that is on screen **now** — not the superseded one — so
    /// it cannot show stale pixels, and the single-flight path coalesces it during a real gesture.
    func testAStaleArrivalIsCachedAndRepaintedAtTheCurrentCamera() throws {
        let url = try rawFixture()
        let loupe = makeController(source: source(url, identity: "stale"))
        loupe.autoRenderEnabled = true
        loupe.scheduleRender()
        XCTAssertTrue(waitFor { loupe.lastPresentedScale == DecodeLadder.previewScale },
                      "the preview frame never arrived")
        let framesBefore = loupe.viewRenderCount

        // A resize (or any new intent) while the full development is still running: same photo, new
        // generation. The full rung's arrival now belongs to a frame that no longer exists.
        loupe.scheduleRender()
        settle(loupe)
        print("Q29 stale: frames \(framesBefore) → \(loupe.viewRenderCount), "
              + "stale drops \(loupe.staleRungDrops), arrivals \(loupe.rungArrivals), "
              + "queue \(loupe.developmentStats)")

        XCTAssertGreaterThanOrEqual(loupe.staleRungDrops, 1,
                                    "a delivery for a superseded frame still counts as stale")
        XCTAssertEqual(loupe.rungArrivals, 2, "…and the buffer is kept: both rungs are resident")
        // The second `scheduleRender` paints one frame of its own from the preview rung; the full
        // rung's arrival adds exactly **one** more, at the current camera, so the full rung reaches
        // the screen without the user touching anything.
        XCTAssertEqual(loupe.viewRenderCount, framesBefore + 2,
                       "a stale arrival repaints once, at the camera on screen now")
        XCTAssertEqual(loupe.lastPresentedScale, DecodeLadder.fullScale,
                       "the full rung replaces the preview on its own")

        // The buffer is not thrown away: the explicit next frame uses it, with no new development.
        let decodes = loupe.developmentStats.decodes
        loupe.requestViewportRender()
        XCTAssertTrue(waitFor { loupe.lastPresentedScale == DecodeLadder.fullScale })
        XCTAssertEqual(loupe.developmentStats.decodes, decodes,
                       "the stale arrival was cached: the next frame owes ImageIO nothing")
    }

    // MARK: - the two queues really are two

    /// Decode and render **overlap in time** — asserted as interval overlap, so a loaded machine can
    /// be slow without failing the test, and a single-queue implementation cannot pass it.
    func testDevelopmentAndFramesOverlapInTime() throws {
        let url = try rawFixture()
        let loupe = makeController(source: source(url, identity: "overlap"))
        loupe.autoRenderEnabled = true
        let t0 = CFAbsoluteTimeGetCurrent()
        loupe.scheduleRender()
        XCTAssertTrue(waitFor { loupe.developmentStats.decodes >= 1 }, "no development started")

        var frameTimes: [Double] = []
        for step in 0..<6 {
            loupe.frameSource = source(url, identity: "overlap", state: pannedState(step))
            let before = loupe.viewRenderCount
            loupe.requestViewportRender()
            if waitFor(10, { loupe.viewRenderCount > before }) {
                frameTimes.append(CFAbsoluteTimeGetCurrent())
            }
        }
        XCTAssertEqual(frameTimes.count, 6, "not every pan produced a frame")
        // The moment the second rung reaches the ladder — i.e. the development is done.
        XCTAssertTrue(waitFor(120) { loupe.rungArrivals >= 2 }, "the full rung never arrived")
        let developmentDone = CFAbsoluteTimeGetCurrent()
        settle(loupe)

        let frames = (start: try XCTUnwrap(frameTimes.first), end: try XCTUnwrap(frameTimes.last))
        print(String(format: "Q29 overlap: development finished at %.0f ms; frames at %.0f … %.0f ms",
                     (developmentDone - t0) * 1000,
                     (frames.start - t0) * 1000, (frames.end - t0) * 1000))
        XCTAssertGreaterThan(frames.start, t0)
        XCTAssertLessThan(frames.end, developmentDone,
                          "every frame must land **while** the development is still running: a single "
                          + "queue would put them all after it")
        XCTAssertGreaterThan(developmentDone - frames.end, 0.05,
                             "and the development must still be running when the last frame lands")
    }
}
