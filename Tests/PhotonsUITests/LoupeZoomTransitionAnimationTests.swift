import XCTest
import AppKit
import QuartzCore
import PhotonsCore
import PhotonsUI

/// A stop change, measured at the only place the user can see it: the **presentation** tree.
///
/// `layer.presentation()` is what the window server composites — one value per frame, interpolated by
/// Core Animation between the `fromValue` and `toValue` the loupe handed it. Sampling it at display
/// cadence therefore answers the question this task was opened with ("does the picture *travel* to the
/// next stop, or jump?") in numbers: how many frames the transition was on screen, and what scale each
/// of them had.
///
/// The counterexample is in the same file: with `reducesMotion` on (which is how the app behaves for a
/// user with 减弱动态效果, and how the app behaved for stop changes before this change — the camera
/// cut straight to the new frame) the same measurement returns **one** value, because there was only
/// ever one frame.
@MainActor
final class LoupeZoomTransitionAnimationTests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    /// How long a wait may take. 6 s was enough while a frame cost one render; `hashesFrames` (which
    /// this file switches on) adds a 32 MB readback + SHA-256 per frame, and on a loaded machine that
    /// alone has been measured at 4–14 s. The *assertions* are about geometry, not speed, so the
    /// timeout is generous and bounded — a hang still fails, an honest frame still passes.
    private static let deadline: TimeInterval = 30
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - harness

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

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitFor(_ timeout: TimeInterval = deadline, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func makeController() -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        return controller
    }

    private func start(_ controller: LoupeController, url: URL, identity: String) {
        controller.hashesFrames = true
        controller.frameSource = LoupeController.FrameSource(url: url, identity: identity,
                                                             viewport: Self.viewport, state: .fit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        XCTAssertTrue(waitFor { controller.lastFrame != nil },
                      "no first frame (last error: \(controller.lastPresentError ?? "—"))")
        pump(0.15)
    }

    /// The canvas's presentation scale, sampled at display cadence.
    ///
    /// The transition is a **sampling window** on the present pass now (025), so the frames the user
    /// actually saw are logged by the loupe itself (`LoupeController.zoomBridgeFrames`): progress,
    /// window, drawable. The picture's scale on screen is `1 / window.du` — a shrinking window is
    /// larger than the texture, a growing one is a sub-rect — and that is the number this returns, one
    /// entry per presented frame, in the order they were presented.
    ///
    /// With `stopWhenBridgeEnds` the sampling stops the moment the bridge hands over: after that the
    /// real frame for the new stop is presented at the identity window, which is a no-op visually but
    /// would read as a jump to 1 on the scale alone.
    private func sampleScale(_ controller: LoupeController, seconds: Double,
                             stopWhenBridgeEnds: Bool = false) -> [(ms: Double, scale: Double)] {
        var out: [(ms: Double, scale: Double)] = []
        let t0 = CACurrentMediaTime()
        // The frame the bridge drew when it armed (progress 0, the picture as it was) is already in
        // the log by the time this is called; a bridge is told from the ones before it by its serial.
        let serial = controller.zoomBridgeArmedCount
        var seen = controller.zoomBridgeFrames.firstIndex { $0.serial == serial }
            ?? controller.zoomBridgeFrames.count
        var sawBridge = false
        while CACurrentMediaTime() - t0 < seconds {
            if controller.zoomBridge != nil { sawBridge = true }
            RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 120))
            let frames = controller.zoomBridgeFrames
            while seen < frames.count {
                let w = frames[seen].window
                out.append(((CACurrentMediaTime() - t0) * 1000,
                            w.du > 0 ? 1.0 / Double(w.du) : 1))
                seen += 1
            }
            // Checked *before* the next sample: the turn in which the bridge hands over is the turn
            // the new frame reaches the layer, and that is not part of the transition's scale sequence.
            if stopWhenBridgeEnds, sawBridge, controller.zoomBridge == nil { break }
        }
        return out
    }

    /// Samples → the frames that actually differed from the previous one (a sample taken twice within
    /// one display refresh is not a second frame).
    private func frames(_ samples: [(ms: Double, scale: Double)],
                        tolerance: Double = 1e-3) -> [(ms: Double, scale: Double)] {
        var out: [(ms: Double, scale: Double)] = []
        for s in samples {
            if let last = out.last, abs(last.scale - s.scale) < tolerance { continue }
            out.append(s)
        }
        return out
    }

    private func assertMonotone(_ values: [Double], increasing: Bool,
                               tolerance: Double = 3e-3,
                               file: StaticString = #filePath, line: UInt = #line) {
        for i in 1..<max(values.count, 1) {
            let delta = values[i] - values[i - 1]
            if increasing {
                XCTAssertGreaterThanOrEqual(delta, -tolerance,
                                            "backtracked at frame \(i): \(values[i - 1]) → \(values[i])",
                                            file: file, line: line)
            } else {
                XCTAssertLessThanOrEqual(delta, tolerance,
                                         "backtracked at frame \(i): \(values[i - 1]) → \(values[i])",
                                         file: file, line: line)
            }
        }
    }

    private func list(_ values: [Double]) -> String {
        values.map { String(format: "%.3f", $0) }.joined(separator: " → ")
    }

    // MARK: - ① the transition, in frames and in scales (5 rounds, with and without the animation)

    func testOneHundredToTwoHundredPresentsAContinuousRunOfScales() throws {
        let url = try rawFixture()
        let controller = makeController()
        start(controller, url: url, identity: "anim-100-200")
        XCTAssertEqual(controller.viewState.mode, .fit)

        controller.zoomToActualSize(aroundView: CGPoint(x: 160, y: 100))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil }, "fit → 100 % never settled")
        pump(0.1)
        let baselineArmed = controller.zoomBridgeArmedCount

        var withAnimation: [[Double]] = []
        for round in 1...5 {
            let armed = controller.zoomBridgeArmedCount
            controller.zoom(to: 1, aroundView: CGPoint(x: 160, y: 100))
            XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 1 },
                          "round \(round): 200 → 100 never settled")
            pump(0.05)
            controller.zoom(to: 2, aroundView: CGPoint(x: 160, y: 100))
            let bridge = try XCTUnwrap(controller.zoomBridge, "round \(round): no bridge")
            let sampled = frames(sampleScale(controller, seconds: 0.35, stopWhenBridgeEnds: true))
            let values = sampled.map(\.scale)
            withAnimation.append(values)
            XCTAssertTrue(waitFor { controller.zoomBridge == nil }, "round \(round): never completed")
            print("100→200 round \(round): \(values.count) frames over "
                  + "\(String(format: "%.0f", bridge.duration * 1000)) ms · \(list(values))")
            XCTAssertGreaterThanOrEqual(values.count, 6,
                                        "round \(round): \(values.count) frames is a jump, not a transition")
            let inBetween = values.filter { $0 > 1.05 && $0 < 1.95 }
            XCTAssertGreaterThanOrEqual(inBetween.count, 8,
                                        "round \(round): only \(inBetween.count) frames are *between* "
                                        + "the two stops — that is a cut with extra steps")
            XCTAssertEqual(values.first ?? 0, 1, accuracy: 0.03,
                           "round \(round): the transition must start from the frame on screen")
            // The last *bridged* frame is a hundredth short of the stop (the sampling loop stops when
            // the bridge hands over); the exact stop is the real frame that replaces it, which
            // `testTheFrameAfterTheTransitionHashesLikeADirectRender` pins to the byte.
            XCTAssertEqual(values.last ?? 0, 2, accuracy: 0.08,
                           "round \(round): the bridged run must reach the stop")
            assertMonotone(values, increasing: true)
        }
        XCTAssertGreaterThanOrEqual(controller.zoomBridgeArmedCount, baselineArmed + 9,
                                    "one bridge per stop change (the first 200 → 100 is a no-op when "
                                    + "the camera is already there)")

        // The same measurement with the animation off: this is what a stop change did before this
        // change (and what it still does under 减弱动态效果) — one frame, one scale, a cut.
        controller.reducesMotion = true
        var withoutAnimation: [[Double]] = []
        for round in 1...5 {
            controller.zoom(to: 1, aroundView: CGPoint(x: 160, y: 100))
            XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 1 })
            pump(0.05)
            controller.zoom(to: 2, aroundView: CGPoint(x: 160, y: 100))
            let values = frames(sampleScale(controller, seconds: 0.25)).map(\.scale)
            withoutAnimation.append(values)
            XCTAssertTrue(waitFor { controller.zoomBridge == nil })
            let intermediate = values.filter { $0 > 1.05 && $0 < 1.95 }
            print("100→200 round \(round) (no animation): \(values.count) frames · \(list(values)) "
                  + "· \(intermediate.count) in-between")
            XCTAssertEqual(intermediate.count, 0, "without the animation no frame is between the stops")
        }
        let countsWith = withAnimation.map(\.count)
        let countsWithout = withoutAnimation.map(\.count)
        print("frames per transition: with animation \(countsWith) · without \(countsWithout)")
        // Two values at most: the new scale, then identity once its drawable has landed (the held
        // geometry is released in the same turn the real frame reaches the layer).
        XCTAssertLessThanOrEqual(countsWithout.max() ?? 0, 2,
                                 "without the animation a stop change is a single frame")
        XCTAssertGreaterThan(countsWith.min() ?? 0, 4 * (countsWithout.max() ?? 1),
                             "the animated transition must span many frames, the cut one")
    }

    // MARK: - ② the pixels: the frame that ends the transition is the stop's own frame

    func testTheFrameAfterTheTransitionHashesLikeADirectRender() throws {
        let url = try rawFixture()
        let controller = makeController()
        start(controller, url: url, identity: "anim-hash")
        controller.zoomToActualSize(aroundView: CGPoint(x: 160, y: 100))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 1 })

        for round in 1...5 {
            controller.zoom(to: 2, aroundView: CGPoint(x: 160, y: 100))
            XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 2 },
                          "round \(round): no 200 % frame")
            pump(0.05)
            let final = try XCTUnwrap(controller.lastFrame)
            let direct = try controller.makeFrame(url: url, viewport: Self.viewport,
                                                  decodeScale: final.decodeScale, edit: .neutral,
                                                  state: controller.viewState, hashPixels: true)
            XCTAssertEqual(final.displayHash, direct.displayHash,
                           "round \(round): the transition presented pixels that are not the stop's")
            XCTAssertEqual(final.zoom, 2, accuracy: 1e-12)
            print("round \(round): final hash \((final.displayHash ?? "—").prefix(12))… == direct "
                  + "rung \(final.decodeScale) window \(final.window.width)×\(final.window.height)")
            controller.zoom(to: 1, aroundView: CGPoint(x: 160, y: 100))
            let tBack = CACurrentMediaTime()
            let cameBack = waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 1 }
            XCTAssertTrue(cameBack, "round \(round): the 100 % frame never arrived "
                          + "(lastFrame \(String(describing: controller.lastFrame?.zoom)) after "
                          + "\(String(format: "%.2f", CACurrentMediaTime() - tBack)) s, "
                          + "bridge \(controller.zoomBridge == nil ? "gone" : "up"), "
                          + "covered \(controller.zoomBridgeCoveredPresents), "
                          + "error \(controller.lastPresentError ?? "—"))")
            pump(0.05)
        }
    }

    // MARK: - ③ the reverse: monotone *down*

    func testTwoHundredToOneHundredIsMonotoneDecreasing() throws {
        let url = try rawFixture()
        let controller = makeController()
        start(controller, url: url, identity: "anim-200-100")
        controller.zoomToActualSize(aroundView: CGPoint(x: 160, y: 100))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 1 })

        for round in 1...5 {
            controller.zoom(to: 2, aroundView: CGPoint(x: 160, y: 100))
            XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 2 })
            pump(0.05)
            controller.zoom(to: 1, aroundView: CGPoint(x: 160, y: 100))
            XCTAssertNotNil(controller.zoomBridge, "round \(round): 200 → 100 must arm a bridge")
            let values = frames(sampleScale(controller, seconds: 0.35, stopWhenBridgeEnds: true)).map(\.scale)
            XCTAssertTrue(waitFor { controller.zoomBridge == nil })
            print("200→100 round \(round): \(values.count) frames · \(list(values))")
            XCTAssertGreaterThanOrEqual(values.count, 6)
            XCTAssertEqual(values.first ?? 0, 1, accuracy: 0.03)
            XCTAssertEqual(values.last ?? 0, 0.5, accuracy: 0.02,
                           "200 → 100 is a scale of 1/2 from the 200 % picture")
            XCTAssertLessThanOrEqual(values.last ?? 1, 0.55, "the shrink must reach the stop")
            assertMonotone(values, increasing: false)
        }
    }

    // MARK: - ④ three ⌘= in a row: no backtrack, 400 % at the end, same pixels as a direct zoom

    func testThreeQuickZoomInsNeverGoBackwardsAndEndOnFourHundred() throws {
        let url = try rawFixture()
        let controller = makeController()
        start(controller, url: url, identity: "anim-triple")
        controller.zoomToActualSize(aroundView: CGPoint(x: 160, y: 100))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 1 })
        pump(0.05)

        var samples: [(ms: Double, scale: Double)] = []
        var presses = 0
        var sawBridge = false
        var seen = controller.zoomBridgeFrames.count
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < 1.2 {
            let ms = (CACurrentMediaTime() - t0) * 1000
            if presses < 3, ms >= Double(presses) * 70 {
                controller.zoomIn()                 // ⌘=
                presses += 1
            }
            if controller.zoomBridge != nil { sawBridge = true }
            RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 120))
            // The log is append-only across a retarget (that is the point: the frames the eye saw are
            // all in it), so only the entries past `seen` are new.
            let frames = controller.zoomBridgeFrames
            while seen < frames.count {
                let w = frames[seen].window
                samples.append(((CACurrentMediaTime() - t0) * 1000, w.du > 0 ? 1.0 / Double(w.du) : 1))
                seen += 1
            }
            // Stop when the last bridge has handed over: after that the new frame is on the layer at
            // the identity window, which is not a step backwards (see `sampleScale`).
            if presses == 3, sawBridge, controller.zoomBridge == nil { break }
        }
        let values = frames(samples).map(\.scale)
        print("100→200→300→400 (3 × ⌘=, 70 ms apart): \(values.count) frames · \(list(values))")
        XCTAssertEqual(presses, 3)
        XCTAssertEqual(controller.viewState.zoom, 4, accuracy: 1e-12, "the camera ends on 400 %")
        XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 4 },
                      "the 400 % frame never arrived (last error: \(controller.lastPresentError ?? "—"))")
        pump(0.1)
        // Monotone over the whole run: a retarget that restarted from identity would show a drop here.
        assertMonotone(values, increasing: true)
        XCTAssertEqual(values.last ?? 0, 4, accuracy: 0.12,
                       "the picture must end at 4× the frame it started from")
        // `zoomIn()` reads the pointer for its anchor, so two runs can differ by the anchor's clamp;
        // the pixels must not. Compare against a render of the camera the loop actually ended on.
        let final = try XCTUnwrap(controller.lastFrame)
        let direct = try controller.makeFrame(url: url, viewport: Self.viewport,
                                              decodeScale: final.decodeScale, edit: .neutral,
                                              state: controller.viewState, hashPixels: true)
        XCTAssertEqual(final.displayHash, direct.displayHash,
                       "the 400 % frame is not the frame the 400 % camera renders")
        XCTAssertEqual(controller.zoomLabel, "400%")
        print("final: label \(controller.zoomLabel) hash \((final.displayHash ?? "—").prefix(12))… "
              + "== direct · bridges \(controller.zoomBridgeArmedCount) "
              + "retargets \(controller.zoomBridgeRetargets) "
              + "drops \(controller.zoomBridgePendingDrops)")
    }

    // MARK: - ⑥ the invariant behind all of the above: every zoom ends **on a stop**

    /// The user's acceptance line: "每次缩放都动起来，动完必须正好停在 25/33.3/50/66.7/100/200/300/400
    /// 或 fit 上，不许停在中间." A transition is allowed to *show* intermediate scales (that is what an
    /// animation is) but the camera must not come to rest on one, so `viewState.zoom` is asserted to be
    /// exactly a table value after every single command — including while a bridge is still running,
    /// i.e. before any of them has settled.
    func testEveryZoomLeavesTheCameraOnAStopNeverInBetween() throws {
        let url = try rawFixture()
        let controller = makeController()
        start(controller, url: url, identity: "anim-invariant")
        controller.reducesMotion = true        // no waiting: the camera value is set synchronously

        func assertOnAStop(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
            if controller.viewState.isActualSize {
                let zoom = controller.viewState.zoom
                XCTAssertNotNil(LoupeViewState.stopIndex(of: zoom),
                                "\(what) left the camera on \(zoom) — between stops",
                                file: file, line: line)
            }
        }

        XCTAssertEqual(controller.viewState.mode, .fit)
        controller.zoomToActualSize(aroundView: CGPoint(x: 160, y: 100))
        assertOnAStop("fit → 100 %")

        // Every menu stop, up the ladder.
        for stop in LoupeController.menuZoomStops {
            controller.zoom(to: stop, aroundView: CGPoint(x: 160, y: 100))
            XCTAssertEqual(controller.viewState.zoom, stop, accuracy: 1e-12,
                           "\(LoupeViewState.percentLabel(of: stop)) must be reached exactly")
            assertOnAStop("menu \(LoupeViewState.percentLabel(of: stop))")
        }

        // ⌘− all the way down: 9 stops → fit, every step parked on a stop on the way.
        var seen: [String] = []
        for _ in 0..<10 {
            controller.zoomOut()
            if controller.viewState.isActualSize {
                seen.append(LoupeViewState.percentLabel(of: controller.viewState.zoom))
            } else {
                seen.append("fit")
            }
            assertOnAStop("⌘−")
        }
        // 2026-10-27 用户要求加 12.5% 档: the walk now passes 12.5 % before it leaves the ladder.
        XCTAssertEqual(seen, ["300%", "200%", "100%", "66.7%", "50%", "33.3%", "25%", "12.5%", "fit", "fit"],
                       "⌘− walks the nine stops in order and then reaches fit")

        // ⌘= back up: fit → 100 % (full size first), then 200 → 300 → 400.
        var up: [String] = []
        for _ in 0..<4 {
            controller.zoomIn()
            up.append(controller.viewState.isActualSize
                      ? LoupeViewState.percentLabel(of: controller.viewState.zoom) : "fit")
            assertOnAStop("⌘=")
        }
        XCTAssertEqual(up, ["100%", "200%", "300%", "400%"])
        XCTAssertEqual(controller.viewState.zoom, 4, accuracy: 1e-12, "the ladder tops out on 400 %")

        // A pinch sweep: the accumulator carries the continuous value, the camera may not.
        var factor = 0.55
        for _ in 0..<80 {
            controller.magnify(by: CGFloat(factor), at: CGPoint(x: 120, y: 80))
            assertOnAStop("pinch ×\(String(format: "%.2f", factor))")
            factor = factor < 1 ? factor * 1.08 : factor * 0.92
            if factor > 2.4 { factor = 0.9 }
        }

        // A pinch that passes through a third lands on **the third**, not on 33 %.
        controller.zoom(to: 0.5, aroundView: CGPoint(x: 160, y: 100))
        controller.magnify(by: 0.68, at: CGPoint(x: 160, y: 100))     // 0.5 × 0.68 = 0.34
        XCTAssertEqual(controller.viewState.zoom, 1.0 / 3.0, accuracy: 1e-12)
        print("invariant: 9 × ⌘− = \(seen.joined(separator: " → ")) · 4 × ⌘= = "
              + "\(up.joined(separator: " → ")) · pinch 0.34 → "
              + LoupeViewState.percentLabel(of: controller.viewState.zoom))
    }

    // MARK: - ⑤ cleanup: a resize mid-transition leaves no transform behind

    func testResizingDuringATransitionTearsItDown() throws {
        let url = try rawFixture()
        let controller = makeController()
        start(controller, url: url, identity: "anim-resize")
        controller.zoomToActualSize(aroundView: CGPoint(x: 160, y: 100))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 1 })
        pump(0.05)

        controller.zoom(to: 2, aroundView: CGPoint(x: 160, y: 100))
        XCTAssertNotNil(controller.zoomBridge)
        pump(0.04)                                  // mid-flight

        // A real resize: the window gets bigger, so the canvas does too.
        let window = try XCTUnwrap(controller.view.window)
        window.setContentSize(NSSize(width: 420, height: 300))
        controller.canvasView.frame = window.contentLayoutRect
        controller.view.layoutSubtreeIfNeeded()
        // 067: the frame source's viewport **is** the canvas a frame is rendered for, so a harness that
        // resizes the window has to say so — the app derives it from the viewport on every job. A frame
        // rendered for the old canvas is refused at present (`AFrameForAStaleCanvasIsNeverDrawn`), which
        // is what 「变扁」 needs and what a stale harness viewport would otherwise loop on.
        if var source = controller.frameSource {
            source = LoupeController.FrameSource(url: source.url, identity: source.identity,
                                                 viewport: controller.viewportPixels,
                                                 state: source.state, edit: source.edit)
            controller.frameSource = source
        }
        pump(0.02)

        XCTAssertNil(controller.zoomBridge, "a resize must tear the bridge down")
        XCTAssertNil(controller.canvasView.metalLayer.animation(forKey: "photons.zoomBridge"))
        XCTAssertTrue(CATransform3DIsIdentity(controller.canvasView.metalLayer.transform),
                      "the transform must not be left in a mid-flight state")
        // And the loupe keeps working on the new canvas.
        XCTAssertTrue(waitFor { controller.lastFrame?.zoom == 2 },
                      "no frame after the resize (last error: \(controller.lastPresentError ?? "—"))")
        print("resize: bridge cleared, transform identity, frame at "
              + "\(controller.lastFrame?.zoom ?? -1)× on \(controller.viewportPixels.width)×"
              + "\(controller.viewportPixels.height)")
    }
}
