import XCTest
import PhotonsCore
import PhotonsUI

/// 派单 031 on the **shipped path**: a 细节 slider dragged through the loupe, measured the way a hand
/// feels it, with the decode counts as the gate (a clock that happens to be fast proves nothing).
///
/// The contract:
///
///   ① **a tick is a preview, never a full development.** While the slider is held the ladder is asked
///      for the 0.5 rung only, so `RAWDecoder.decodeCounts()[1]` stays 0 for the whole drag — that is
///      a count, not a budget, so a busy machine cannot make it pass by luck.
///   ② **the canvas follows the thumb** at the preview rung (`lastPresentedScale == 0.5`).
///   ③ **the hand stops → full size.** 150–250 ms after the last movement (or the release) one 1.0
///      development runs and replaces the frame, and the camera (zoom/centre) does not move.
///   ④ the settle window itself is the constant, so a change to it is a visible decision rather than a
///      number buried in a closure.
///
/// The numbers are printed on every run; only the counts and the ordering are asserted.
@MainActor
final class DetailTimelineTests: XCTestCase {

    private static let viewport = ImageSize(width: 1600, height: 1000)
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        RAWDecoder.resetDecodeCounts()
        super.tearDown()
    }

    // MARK: - fixtures

    private func fixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func makeController(_ source: LoupeController.FrameSource) -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        controller.frameSource = source
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        return controller
    }

    private func source(_ url: URL, edit: EditModel, state: LoupeViewState = .fit) -> LoupeController.FrameSource {
        LoupeController.FrameSource(url: url, identity: "detail-photo", viewport: Self.viewport,
                                    state: state, edit: edit)
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func settle(_ controller: LoupeController, timeout: TimeInterval = 120) {
        let deadline = Date().addingTimeInterval(timeout)
        var quiescent = 0
        var lastFrames = -1
        while Date() < deadline && quiescent < 4 {
            let budget = max(0.05, min(2, deadline.timeIntervalSinceNow))
            let idle = controller.awaitPendingDevelopments(timeout: budget)
            pump(0.05)
            let frames = controller.viewRenderCount + controller.editRenderCount
            if idle, !controller.isRenderingViewportFrame, frames == lastFrames {
                quiescent += 1
            } else {
                quiescent = 0
            }
            lastFrames = frames
        }
        XCTAssertEqual(quiescent, 4, "the loupe never went quiet")
    }

    // MARK: - the drag

    func testDragStaysOnThePreviewRungAndTheHandStoppingDevelopsFullSize() throws {
        // ④ the window the task asks for.
        XCTAssertGreaterThanOrEqual(LoupeController.detailSettleInterval, 0.15)
        XCTAssertLessThanOrEqual(LoupeController.detailSettleInterval, 0.25)

        let url = try fixture()
        let controller = makeController(source(url, edit: .neutral))

        // A cold open at fit: preview rung first, then the full one (the normal ladder).
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        XCTAssertTrue(waitFor(180) { controller.lastPresentedScale == DecodeLadder.fullScale },
                      "the full rung never reached the canvas")

        // The camera the whole test is about: fit is not a pan, so a jump here would be a bug.
        let stateBefore = controller.viewState
        RAWDecoder.resetDecodeCounts()

        // ── ① the drag: eight ticks, fired the way a hand fires them (no waiting in between) ────
        controller.beginDetailAdjustment()
        for step in 1...8 {
            var doc = EditModel.neutral
            doc.detailSettings.luminanceNR = Double(step * 10)
            controller.frameSource = source(url, edit: doc, state: stateBefore)
            controller.requestViewportRender()
        }

        // A tick is a *preview* develop, and this is a count, not a budget: after the whole burst —
        // before the settle window has even elapsed — the full frame has not been asked for once.
        XCTAssertEqual(RAWDecoder.decodeCounts()[DecodeLadder.fullScale] ?? 0, 0,
                       "a detail tick developed the full 60 MP frame")

        let lastTick = CFAbsoluteTimeGetCurrent()
        XCTAssertTrue(waitFor(180) { controller.lastPresentedScale == DecodeLadder.previewScale },
                      "the drag never drew the preview rung")
        let previewMilliseconds = (CFAbsoluteTimeGetCurrent() - lastTick) * 1000

        // ── ② the hand stops ────────────────────────────────────────────────────────────────────
        let release = CFAbsoluteTimeGetCurrent()
        controller.endDetailAdjustment()
        XCTAssertTrue(waitFor(180) { controller.lastPresentedScale == DecodeLadder.fullScale },
                      "the full-size frame never arrived after the settle window")

        let settleMilliseconds = (CFAbsoluteTimeGetCurrent() - release) * 1000
        XCTAssertEqual(RAWDecoder.decodeCounts()[DecodeLadder.fullScale] ?? 0, 1,
                       "the release must develop the full rung exactly once")

        // The camera did not jump: a detail change is a new development, not a new framing.
        XCTAssertEqual(controller.viewState, stateBefore, "the settle moved the camera")

        print("DETAIL drag: 8 ticks · thumb → preview frame "
              + "\(String(format: "%.1f", previewMilliseconds)) ms · full decodes during the drag 0")
        print("DETAIL settle: release → full frame \(String(format: "%.1f", settleMilliseconds)) ms "
              + "(window \(LoupeController.detailSettleInterval * 1000) ms + one full development)")
    }

    /// A drag that pauses without releasing also gets the full-size development — "停手" means the
    /// hand stopped, not that the button came up.
    func testPausingMidDragAlsoDevelopsFullSize() throws {
        let url = try fixture()
        let controller = makeController(source(url, edit: .neutral))
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        XCTAssertTrue(waitFor(180) { controller.lastPresentedScale == DecodeLadder.fullScale })
        RAWDecoder.resetDecodeCounts()

        controller.beginDetailAdjustment()
        var doc = EditModel.neutral
        doc.detailSettings.colorNR = 40
        let tick = CFAbsoluteTimeGetCurrent()
        controller.frameSource = source(url, edit: doc)      // the tick: arms the settle timer
        controller.requestViewportRender()
        XCTAssertEqual(RAWDecoder.decodeCounts()[DecodeLadder.fullScale] ?? 0, 0,
                       "the tick itself asked for the full rung")

        // The tick's own frame is the preview rung (the queue is serial: the 0.5 development was
        // requested first, so it lands before the settle's 1.0 one).
        XCTAssertTrue(waitFor(180) { controller.lastPresentedScale == DecodeLadder.previewScale },
                      "the paused tick never drew the preview rung")
        let preview = (CFAbsoluteTimeGetCurrent() - tick) * 1000

        // No further tick: the settle timer alone must upgrade the frame.
        XCTAssertTrue(waitFor(180) { controller.lastPresentedScale == DecodeLadder.fullScale },
                      "a paused drag never developed full size")
        let full = (CFAbsoluteTimeGetCurrent() - tick) * 1000
        print("DETAIL pause: last tick → preview \(String(format: "%.1f", preview)) ms"
              + " → full \(String(format: "%.1f", full)) ms")
        XCTAssertEqual(RAWDecoder.decodeCounts()[DecodeLadder.fullScale] ?? 0, 1)

        controller.endDetailAdjustment()
        settle(controller)
    }
}
