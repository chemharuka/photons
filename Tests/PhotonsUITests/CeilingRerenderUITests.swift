import XCTest
import CoreGraphics
import Metal
import PhotonsCore
import PhotonsUI

/// 323 — 「拖动最高亮度后，没有触发直方图和画面的重算」, on the loupe's own paths.
///
/// The probe that found it is in `PhotonsCoreTests/CeilingRerenderTests`: the ceiling was reached
/// the display link only, so S2 (which clamps at it) and the S3.7/S3.8/S3.10 tail guards came out of
/// the stage cache and the frame kept the old top. This file asks the two questions the user asked,
/// through the shipped entry points:
///
///   ① the **plot** follows the row — the frame's own measurement of a +5 EV picture stops at bin
///      147 under +2.3 EV and at 255 under +4 EV, with the frames rendered from one graph (i.e.
///      `useCache: true`, the path that was broken);
///   ② a **released drag** costs at most two presented frames, and the card ends on the last tick's
///      numbers — the change is not swallowed by a cache, and not queued behind ten stale renders.
@MainActor
final class CeilingRerenderUITests: XCTestCase {

    private static let viewport = ImageSize(width: 2560, height: 1600)
    private var windows: [NSWindow] = []
    private var savedPref: Any?

    override func setUp() {
        super.setUp()
        savedPref = UserDefaults.standard.object(forKey: HighlightCeiling.defaultsKey)
        UserDefaults.standard.removeObject(forKey: HighlightCeiling.defaultsKey)
    }

    override func tearDown() {
        if let savedPref { UserDefaults.standard.set(savedPref, forKey: HighlightCeiling.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: HighlightCeiling.defaultsKey) }
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - fixtures

    private func rawFixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func makeController(autoRender: Bool) -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = autoRender
        controller.collectsHistogram = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        return controller
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func topBin(_ h: Histogram?) -> Int {
        guard let bins = h?.luma.hdrBins else { return -1 }
        for i in stride(from: bins.count - 1, through: 0, by: -1) where bins[i] > 0 { return i }
        return -1
    }

    private func brighter(_ stops: Double) -> EditModel {
        var edit = EditModel.neutral
        edit.light.exposure = stops
        return edit
    }

    // MARK: - ① the plot follows the row, from one graph, with the stage cache on

    func testTheFramesPlotFollowsTheCeilingFromOneGraph() throws {
        let url = try rawFixture()
        let loupe = makeController(autoRender: false)
        let edit = brighter(5)

        HighlightCeiling.setEV(2.3)
        _ = try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                edit: edit, state: .fit, hashPixels: true)
        pump(0.02)
        let bin23 = topBin(loupe.lastHistogram)
        let digest23 = loupe.lastHistogram?.binsDigest() ?? "none"
        let frames23 = loupe.histogramCollectedFrames

        HighlightCeiling.setEV(4.0)
        _ = try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                edit: edit, state: .fit, hashPixels: true)
        pump(0.02)
        let bin40 = topBin(loupe.lastHistogram)
        let digest40 = loupe.lastHistogram?.binsDigest() ?? "none"
        let frames40 = loupe.histogramCollectedFrames

        print("323 loupe · top hdr bin +2.3 EV \(bin23) / +4.0 EV \(bin40)"
              + " · frames that measured \(frames23) → \(frames40)"
              + " · digests \(digest23.prefix(12)) / \(digest40.prefix(12))")
        XCTAssertEqual(bin23, 147, accuracy: 1, "the default ceiling stops the tail at 2.3 EV")
        XCTAssertEqual(bin40, 255, "and +4.0 EV lets it reach the axis' end")
        XCTAssertNotEqual(digest23, digest40, "the second frame must be measured, not served")
        XCTAssertEqual(frames40, frames23 + 1, "one new frame, one new measurement")
        XCTAssertNil(loupe.lastHistogramError)
    }

    // MARK: - ② a released drag lands in ≤ 2 presented frames

    func testAReleasedDragCarriesTheCeilingIntoTheNextFrame() throws {
        let url = try rawFixture()
        let loupe = makeController(autoRender: true)
        loupe.frameSource = LoupeController.FrameSource(url: url, identity: "ceiling-drag",
                                                        viewport: Self.viewport, state: .fit,
                                                        edit: brighter(5))
        HighlightCeiling.setEV(2.3)
        loupe.scheduleRender()
        XCTAssertTrue(waitFor(20) { loupe.lastFrame != nil }, "no first frame")
        XCTAssertTrue(waitFor(20) { self.topBin(loupe.lastHistogram) > 0 }, "no first measurement")
        pump(0.05)

        // What one frame costs **here** (a debug build on a 2560 × 1600 viewport): one change, no
        // drag, timed the same way as the drag below. The 16.7 ms of a 60 Hz display is not this
        // machine's frame, so "two frames" is measured against the loupe's own single-change latency.
        var baselineMs: [Double] = []
        for step in 0..<3 {
            let before = topBin(loupe.lastHistogram)
            HighlightCeiling.setEV(2.5 + Double(step) * 0.2)
            let changed = CFAbsoluteTimeGetCurrent()
            _ = waitFor(10) { self.topBin(loupe.lastHistogram) != before }
            baselineMs.append((CFAbsoluteTimeGetCurrent() - changed) * 1000)
        }
        let baseline = baselineMs.sorted()[baselineMs.count / 2]
        HighlightCeiling.setEV(2.3)
        loupe.scheduleRender()
        XCTAssertTrue(waitFor(20) { self.topBin(loupe.lastHistogram) > 0 })
        pump(0.05)

        let staleBefore = loupe.staleFrameDrops
        var releasedAt = CFAbsoluteTimeGetCurrent()
        var presentedAtLastTick = loupe.viewRenderCount
        let lastTick = 10

        // Ten ticks, 16 ms apart — a slider drag at 60 Hz, ending exactly on +4.0 EV.
        for tick in 1...10 {
            // Frames that land while the hand is still moving are the drag, not the answer: the count
            // below starts at the **last** change, which is what 「松手后一帧内」 is about.
            if tick == lastTick { presentedAtLastTick = loupe.viewRenderCount }
            HighlightCeiling.setEV(2.3 + Double(tick) * 0.17)
            releasedAt = CFAbsoluteTimeGetCurrent()
            pump(0.016)
        }
        XCTAssertEqual(HighlightCeiling.currentEV, 4.0, accuracy: 1e-9)

        // The card's own numbers are the receipt: the last tick is only on screen when a frame
        // measured at +4 EV has been published.
        let landed = waitFor(10) { self.topBin(loupe.lastHistogram) >= 250 }
        let elapsed = (CFAbsoluteTimeGetCurrent() - releasedAt) * 1000
        pump(0.05)
        let presented = loupe.viewRenderCount - presentedAtLastTick
        let stale = loupe.staleFrameDrops - staleBefore

        print(String(format: "323 drag · one change = %.1f ms · 10 ticks/16 ms → %d presented frames"
                     + " (%d stale drops, %d coalesced) · last change → new numbers %.1f ms"
                     + " (%.2f frames, limit 2) · top bin %d",
                     baseline, presented, stale, loupe.scheduledRenderCoalesced,
                     elapsed, elapsed / max(baseline, 0.001), topBin(loupe.lastHistogram)))
        print(String(format: "323 drag · two frames = %.1f ms (one = %.1f ms)", 2 * max(baseline, 1000.0 / 60), baseline))

        XCTAssertTrue(landed, "the last tick never reached the card")
        XCTAssertEqual(topBin(loupe.lastHistogram), 255)
        // A frame is the loupe's own measured single-change latency, floored at one 60 Hz display
        // interval (this machine's debug render is faster than a panel's refresh, and a test may not
        // claim a budget tighter than the display it stands for).
        let frameMs = max(baseline, 1000.0 / 60)
        XCTAssertLessThanOrEqual(elapsed, 2 * frameMs,
                                 "松手后两帧内（≤ \(2 * frameMs) ms）必须看到新结果")
        XCTAssertLessThanOrEqual(presented, 2, "at most two frames may be presented after the release")
    }
}
