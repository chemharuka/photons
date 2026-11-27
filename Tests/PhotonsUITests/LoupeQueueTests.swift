import XCTest
import CoreGraphics
import PhotonsCore
import PhotonsUI

/// Q29 on the **shipped path**: the loupe's own two queues, driven through `scheduleRender` /
/// `requestViewportRender` — not a hand-rolled imitation of them.
///
/// 571-A changed what the canvas asks for: the ladder has one rung (the whole picture), and while it
/// is being developed there is **no half-resolution frame** to pan over — the canvas keeps the 1920 px
/// stand-in. The claims below were re-based on that two-valued canvas:
///
///   ① twenty pans while a 60 MP development runs: they draw nothing and cost no extra decode; the one
///      arrival paints exactly one replacement frame.
///   ② the 1:1 first frame is the full rung (the user waits for the development, never sees a soft
///      frame in between).
///   ③ cold-open ready time is compared against the same inline work (develop then render).
///   ④ `fit ↔ 1:1` develops one rung and no more, counted in `DecodeLadder`/`RAWDecoder`.
///
/// The ordering rules are asserted on counts, never on a clock: `rungArrivals` (rungs that entered the
/// ladder), `staleRungDrops` (deliveries that were **not** painted), and the queue's own
/// `decodes`/`deliveries`/`drops`. A stale result may be cached; it must never reach the canvas, and a
/// cancelled photo must not call back at all.
///
/// Absolute, user-facing numbers are asserted only under `PHOTONS_BENCH=1`: on a machine that is
/// building two other things at once they drift by ±20 %, and a red test must mean a regression
/// rather than a busy CPU. The *semantics* — counts, ordering, interval overlap — are asserted on
/// every run, and the numbers are printed on every run.
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
        controller.collectsHistogram = false
        controller.frameSource = source
        if windowed {
            let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
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

    /// Pump until nothing is moving: the decode queue idle, no frame mid-render, **and** the frame
    /// count unchanged for four consecutive checks.
    private func settle(_ controller: LoupeController, timeout: TimeInterval = 180) {
        let deadline = Date().addingTimeInterval(timeout)
        var quiescent = 0
        var lastFrames = -1
        while Date() < deadline && quiescent < 4 {
            let budget = max(0.05, min(2, deadline.timeIntervalSinceNow))
            let idle = controller.awaitPendingDevelopments(timeout: budget)
            pump(0.05)
            let frames = controller.viewRenderCount + controller.editRenderCount
            let rendering = controller.isRenderingViewportFrame
            if idle, !rendering, frames == lastFrames { quiescent += 1 } else { quiescent = 0 }
            lastFrames = frames
        }
        XCTAssertEqual(quiescent, 4, "the loupe never went quiet")
    }

    private func percentile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }

    // MARK: - ① pans during a development

    /// ① Twenty pans while the 60 MP development runs. 571-A: there is no half-resolution rung to draw,
    /// so every one of them is a request that draws nothing and joins the one development already on
    /// its way; the single arrival then paints exactly one replacement frame.
    func testPansDuringTheFullDevelopmentDrawNothingAndCostOneDecode() throws {
        let url = try rawFixture()
        let loupe = makeController(source: source(url, identity: "A"))
        loupe.autoRenderEnabled = true
        loupe.scheduleRender()

        // The development has started; the canvas has no frame yet (the 1920 px stand-in is the
        // first-frame placeholder, not a presented `FrameResult`).
        XCTAssertTrue(waitFor { loupe.developmentStats.decodes >= 1 }, "the development never started")
        XCTAssertNil(loupe.lastPresentedScale)
        XCTAssertEqual(loupe.rungArrivals, 0)

        for step in 0..<20 {
            loupe.frameSource = source(url, identity: "A", state: pannedState(step))
            let before = loupe.viewRenderCount
            loupe.requestViewportRender()
            XCTAssertEqual(loupe.viewRenderCount, before,
                           "pan \(step) drew a frame while the full rung was still developing")
            XCTAssertEqual(loupe.developmentStats.decodes, 1,
                           "pan \(step) asked the decoder again while the full rung was developing")
        }
        print("Q29 ① 20 pans during the full development: no frames, one decode")

        settle(loupe)
        XCTAssertEqual(loupe.lastPresentedScale, DecodeLadder.fullScale,
                       "the replacement frame must put the full rung on screen")
        XCTAssertEqual(loupe.rungArrivals, 1, "one rung, one arrival")
        // The pan storm folds into one in-flight view render plus its single queued follow-up. The
        // full rung arrives while that follow-up is the in-flight pan frame, so the follow-up paints
        // it and the arrival's replacement paints once more: this machine makes exactly two frames.
        // No pan paints synchronously, and all twenty cost one development (asserted above).
        XCTAssertEqual(loupe.viewRenderCount, 2,
                       "the pan follow-up and the arrival replacement, and nothing per pan")
        XCTAssertEqual(loupe.developmentStats.decodes, 1,
                       "twenty pans asked for the full rung twenty times and cost one development")
        XCTAssertGreaterThanOrEqual(loupe.viewRenderCoalesced, 18,
                                    "the pan storm must fold into the in-flight frame")
        XCTAssertGreaterThanOrEqual(loupe.developmentStats.coalesced, 1,
                                    "the renders that did reach the queue join the one development")
    }

    // MARK: - ② the 1:1 first frame

    /// ② Entering 1:1 while the full rung is being developed waits for that development; when it lands
    /// the first frame is a window render off the full rung. No preview leg, no second development.
    func testOneToOneFirstFrameIsTheFullRung() throws {
        let url = try rawFixture()
        let loupe = makeController(source: source(url, identity: "A", state: pannedState(0)))
        loupe.autoRenderEnabled = true
        let t0 = CFAbsoluteTimeGetCurrent()
        loupe.scheduleRender()
        XCTAssertTrue(waitFor { loupe.viewRenderCount >= 1 },
                      "the first 1:1 frame never reached the canvas")
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let first = try XCTUnwrap(loupe.lastFrame)
        print(String(format: "Q29 ② 1:1 first frame: render %.1f ms (%.0f ms from the request, which "
                        + "includes the full development)",
                     first.renderMilliseconds, elapsed))

        XCTAssertEqual(loupe.lastPresentedScale, DecodeLadder.fullScale,
                       "1:1 opens on the full rung; there is no preview to open on")
        XCTAssertEqual(loupe.rungArrivals, 1, "one rung, one arrival")
        XCTAssertEqual(loupe.developmentStats.decodes, 1,
                       "entering 1:1 must not develop a second rung")
        if benchmarks {
            XCTAssertLessThanOrEqual(first.renderMilliseconds, 60,
                                     "the 1:1 frame's own render must fit the 60 ms budget")
        }

        // Warm: once the full rung is resident, the same 1:1 frame is a render-only frame.
        settle(loupe)
        let before = loupe.viewRenderCount
        let warmStart = CFAbsoluteTimeGetCurrent()
        loupe.requestViewportRender()
        XCTAssertTrue(waitFor { loupe.viewRenderCount > before })
        settle(loupe)
        let warm = (CFAbsoluteTimeGetCurrent() - warmStart) * 1000
        print(String(format: "Q29 ② 1:1 warm frame (full rung resident): %.1f ms total · render "
                        + "%.1f ms", warm, loupe.lastFrame?.renderMilliseconds ?? 0))
        XCTAssertEqual(loupe.lastPresentedScale, DecodeLadder.fullScale)
        if benchmarks {
            XCTAssertLessThanOrEqual(warm, 40, "a warm 1:1 frame must stay a frame, not a stage rebuild")
        }
        XCTAssertEqual(loupe.developmentStats.decodes, 1,
                       "the warm frame must not develop anything")
    }

    // MARK: - ③ full-resolution ready time

    /// ③ Cold open → a full-resolution frame on the canvas, against the *same work inline* (develop
    /// then render, synchronously, no queue split). Two rounds, alternating, so neither number gets
    /// the other's warm ImageIO cache for free. 571-A: both sides do exactly one development.
    func testFullRungReadyTimeDoesNotRegress() throws {
        let url = try rawFixture()
        var inline: [Double] = []
        var split: [Double] = []

        for round in 0..<2 {
            // A — inline: develop the full rung and render, synchronously.
            let a = makeController(source: source(url, identity: "inline-\(round)"))
            let tA = CFAbsoluteTimeGetCurrent()
            _ = try a.makeFrame(url: url, viewport: Self.viewport, decodeScale: 1,
                                edit: .neutral, state: .fit)
            inline.append((CFAbsoluteTimeGetCurrent() - tA) * 1000)

            // B — the shipped split: two queues, the ladder, one replacement for the rung.
            let b = makeController(source: source(url, identity: "split-\(round)"))
            b.autoRenderEnabled = true
            let tB = CFAbsoluteTimeGetCurrent()
            b.scheduleRender()
            XCTAssertTrue(waitFor { b.lastPresentedScale == DecodeLadder.fullScale },
                          "the full rung never reached the canvas")
            split.append((CFAbsoluteTimeGetCurrent() - tB) * 1000)
            XCTAssertEqual(b.rungArrivals, 1, "one rung, one arrival")
            XCTAssertEqual(b.developmentStats.decodes, 1,
                           "the queue split must not develop a rung twice")
            print(String(format: "Q29 ③ round %d: inline %.0f ms → two queues %.0f ms (%.1f%%), "
                         + "decodes %d, arrivals %d",
                         round, inline[round], split[round],
                         (split[round] / inline[round] - 1) * 100,
                         b.developmentStats.decodes, b.rungArrivals))
        }

        let inlineP50 = percentile(inline, 0.5), splitP50 = percentile(split, 0.5)
        print(String(format: "Q29 ③ full-resolution ready: inline %.0f ms → split %.0f ms",
                     inlineP50, splitP50))
        if benchmarks {
            XCTAssertLessThanOrEqual(splitP50, inlineP50 * 1.05 + 5,
                                     "the queue split must not cost 5% of the ready time")
        }
    }

    // MARK: - ④ the decode count

    /// ④ `fit ↔ 1:1` develops the full rung exactly once. The count is `loupe.developedRungs` —
    /// **this** ladder's ledger — because `RAWDecoder.decodeCounts()` is process-global.
    func testFitAndOneToOneDevelopTheFullRungOnce() throws {
        let url = try rawFixture()
        RAWDecoder.resetDecodeCounts()
        let loupe = makeController(source: source(url, identity: "count"))
        loupe.autoRenderEnabled = true
        loupe.scheduleRender()
        settle(loupe)
        XCTAssertEqual(loupe.lastPresentedScale, DecodeLadder.fullScale)
        XCTAssertEqual(loupe.developedRungs, [1: 1])
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
        print("Q29 ④ fit↔1:1 ×5 rounds: developed rungs "
              + "\(loupe.developedRungs.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" })"
              + ", development queue \(loupe.developmentStats)"
              + ", process-wide \(RAWDecoder.decodeCounts().sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" })")
        XCTAssertEqual(loupe.developedRungs, [1: 1],
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
    func testAStaleArrivalIsCachedAndRepaintedAtTheCurrentCamera() throws {
        let url = try rawFixture()
        let loupe = makeController(source: source(url, identity: "stale"))
        loupe.autoRenderEnabled = true
        loupe.scheduleRender()
        XCTAssertTrue(waitFor { loupe.developmentStats.decodes >= 1 },
                      "the development never started")
        let framesBefore = loupe.viewRenderCount

        // A resize (or any new intent) while the full development is still running: same photo, new
        // generation. The full rung's arrival now belongs to a frame that no longer exists.
        loupe.scheduleRender()
        XCTAssertTrue(waitFor { loupe.lastPresentedScale == DecodeLadder.fullScale },
                      "the stale arrival never repainted at the current camera")
        settle(loupe)
        print("Q29 stale: frames \(framesBefore) → \(loupe.viewRenderCount), "
              + "stale drops \(loupe.staleRungDrops), arrivals \(loupe.rungArrivals), "
              + "queue \(loupe.developmentStats)")

        XCTAssertGreaterThanOrEqual(loupe.staleRungDrops, 1,
                                    "a delivery for a superseded frame still counts as stale")
        XCTAssertEqual(loupe.rungArrivals, 1, "…and the buffer is kept: the full rung is resident")
        // There was no preview frame to paint; the stale arrival's one repaint is the only frame.
        XCTAssertEqual(loupe.viewRenderCount, framesBefore + 1,
                       "a stale arrival repaints once, at the camera on screen now")
        XCTAssertEqual(loupe.lastPresentedScale, DecodeLadder.fullScale)

        // The buffer is not thrown away: the explicit next frame uses it, with no new development.
        let decodes = loupe.developmentStats.decodes
        loupe.requestViewportRender()
        XCTAssertTrue(waitFor { loupe.lastPresentedScale == DecodeLadder.fullScale })
        XCTAssertEqual(loupe.developmentStats.decodes, decodes,
                       "the stale arrival was cached: the next frame owes ImageIO nothing")
    }
}
