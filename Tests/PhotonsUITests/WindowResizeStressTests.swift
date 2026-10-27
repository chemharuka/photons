import XCTest
import AppKit
import QuartzCore
import Metal
import PhotonsCore
import PhotonsUI

/// 068 — **the canvas may not move while the hand is moving.**
///
/// The report, twice, from two entry points: 「调整窗口大小时，画布还是会动，如果按住边框不断调整，画面就像
/// 果冻一样弹来弹去」 and 「调整边栏（检查器）宽度也是一样的行为」.
///
/// 067 froze the picture for a *window* live resize and left three holes, and this file is written
/// against them:
///
///   1. **A divider drag was not a gesture at all.** `WorkspaceDivider.mouseDown` runs its own
///      `nextEvent` loop; AppKit never starts a live resize for it, so nothing froze and every
///      mouse-moved tick asked for a render at a canvas size the next tick would replace. Entry point
///      two was never covered.
///   2. **Every layout pass drew.** `CanvasPresenter.present` takes a drawable with
///      `displaySyncEnabled`, i.e. `nextDrawable()` on the main thread waits for a vsync. A drag is laid
///      out more often than it is displayed, so one draw per pass made the second draw of a display
///      frame wait for a vsync it had already missed: the window server showed the layer at the last
///      size it had, then the late draw moved it. Twice per frame, back and forth — the jelly.
///   3. **A frame that landed mid-gesture was still drawn.** Drawing it at its own pixel geometry is
///      right *outside* a gesture and wrong inside one: it hands the hand a picture at the scale the
///      release render is about to change, so every landed frame is one re-fit.
///
/// The fix is one channel for all of it (`LoupeController.CanvasGeometryGesture`): a gesture freezes the
/// geometry, **one draw per runloop tick** follows the canvas, nothing renders while the hand moves, and
/// the release is one render at the exact final size. `CanvasPresenter` gains the invariant that makes
/// (b) structural — it refuses a request whose quads belong to another canvas, before the GPU work and
/// before `nextDrawable()` — and the counters read below.
///
/// The acceptance numbers, read from counters and from the presenter's record of what reached the
/// drawable — never from watching the picture:
///
///   a. forty monotone steps of window width: the photograph's quad has **no reversal** (no delta
///      against the hand's direction, no change of direction), and inside the drag it does not move;
///   b. every drawn frame's canvas **equals the canvas that was on screen when it was drawn**;
///   c. draws and renders ≤ half the steps, and the last step's sizes are exactly equal;
///   d. `decodeRequests` moves by **0** — a resize is not a decode input.
///
/// Both entry points run the same four assertions, and `disableResizeCoalescing` reproduces the pre-068
/// shape so (c) is shown to go red for the reason it names.
@MainActor
final class WindowResizeStressTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var savedInspectorWidth: Any?

    override func setUp() {
        super.setUp()
        // The workspace persists a divider drag in the user's defaults; a test must not leave the app
        // opening at the width it dragged to.
        savedInspectorWidth = UserDefaults.standard.object(forKey: "photons.inspectorWidth")
    }

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let savedInspectorWidth {
            UserDefaults.standard.set(savedInspectorWidth, forKey: "photons.inspectorWidth")
        } else {
            UserDefaults.standard.removeObject(forKey: "photons.inspectorWidth")
        }
        super.tearDown()
    }

    // MARK: - harness

    private func fixture() throws -> URL {
        var candidates = [ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"]].compactMap { $0 }
        let dir = NSString(string: "~/Desktop/test").expandingTildeInPath
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.lowercased().hasSuffix(".dng") }.sorted() ?? []
        candidates += names.map { "\(dir)/\($0)" }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    /// One runloop tick. This is the unit the coalescer counts in: whatever a burst of layout passes did
    /// to the canvas, the tick draws **one** frame, for the size the canvas has when it runs.
    private func tick(_ seconds: TimeInterval = 0.006) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitFor(_ timeout: TimeInterval = 60, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            tick()
        }
        return condition()
    }

    private func makeWindow(_ size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        windows.append(window)
        window.orderFront(nil)
        return window
    }

    private func show(_ controller: LoupeController, url: URL, identity: String) {
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        controller.frameSource = LoupeController.FrameSource(url: url, identity: identity,
                                                             viewport: controller.viewportPixels,
                                                             state: .fit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
    }

    /// The app's own model: the canvas the next job is for **is** the viewport, so a resize really is a
    /// new canvas rather than a number the harness forgot to move.
    private func syncCanvas(_ controller: LoupeController) {
        guard var source = controller.frameSource else { return }
        source = LoupeController.FrameSource(url: source.url, identity: source.identity,
                                             viewport: controller.viewportPixels,
                                             state: source.state, edit: source.edit)
        controller.frameSource = source
    }

    /// First frame, then let the open's own full-rung development land.
    ///
    /// The wait is what makes (d) measurable: until the rung the resize job asks for is resident in the
    /// ladder, a resize job legitimately *joins the open's* development request and the counter moves for
    /// a reason that has nothing to do with the canvas.
    private func arriveAtFirstFrame(_ controller: LoupeController) {
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        XCTAssertTrue(waitFor(180) { controller.residentRungScales.contains(DecodeLadder.fullScale) },
                      "the open never finished its full-rung decode; (d) cannot be measured")
        tick(0.05)
    }

    /// A delta that goes the other way from the hand's, or a change of direction, is the picture
    /// bouncing. Zero deltas are the freeze holding still — not a reversal.
    private func reversals(_ widths: [Int]) -> (negative: Int, alternations: Int) {
        let deltas = zip(widths, widths.dropFirst()).map { $1 - $0 }
        let nonZero = deltas.filter { $0 != 0 }
        let negative = nonZero.filter { $0 < 0 }.count
        var alternations = 0
        for (a, b) in zip(nonZero, nonZero.dropFirst()) where (a > 0) != (b > 0) {
            alternations += 1
        }
        return (negative, alternations)
    }

    private func describe(_ widths: [Int]) -> String {
        let deltas = zip(widths, widths.dropFirst()).map { $1 - $0 }
        let unique = Array(Set(deltas)).sorted()
        return "quad widths \(widths.count): \(widths.prefix(6))…\(widths.suffix(3)) "
            + "deltas {\(unique.map(String.init).joined(separator: ","))}"
    }

    // MARK: - ① the window edge, 1200 → 1600 in forty steps

    func testAWindowDragDrawsOnePerTickAndRendersOnceAtTheExactFinalSize() throws {
        let url = try fixture()
        let controller = LoupeController(session: CatalogSession())
        let window = makeWindow(CGSize(width: 1200, height: 800))
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        controller.view.layoutSubtreeIfNeeded()
        tick(0.05)
        show(controller, url: url, identity: "resize-068-window")
        arriveAtFirstFrame(controller)

        let presenter = try XCTUnwrap(controller.canvasPresenter, "no presenter — the canvas never loaded")
        let startDraws = presenter.presentCount
        let startRenders = controller.resizeRenderStarts
        let startRequests = controller.resizeRequests
        let startDecodes = controller.decodeRequests
        let firstQuad = try XCTUnwrap(presenter.presentedGeometry?.pictureQuad,
                                      "the first frame was never presented")

        controller.beginLiveResize()
        XCTAssertTrue(controller.isCanvasGeometryFrozen, "the gesture did not freeze the canvas")

        let steps = 40
        var draws = 0
        var widths: [Int] = [firstQuad.width]
        var heights: [Int] = [firstQuad.height]
        var canvasMismatches: [String] = []
        var passes = 0
        var lastDrawCount = presenter.presentCount

        for step in 1...steps {
            resizeCanvas(controller, window, to: CGSize(width: 1200 + CGFloat(step) * 10, height: 800))
            passes += 1
            // Two layout passes per display frame — the shape of a fast drag, and the reason one draw per
            // pass used to mean one vsync wait per frame too many.
            guard step % 2 == 0 else { continue }
            tick()
            guard presenter.presentCount != lastDrawCount else { continue }
            draws += presenter.presentCount - lastDrawCount
            lastDrawCount = presenter.presentCount
            let geometry = try XCTUnwrap(presenter.presentedGeometry)
            let canvasNow = controller.viewportPixels
            widths.append(geometry.pictureQuad.width)
            heights.append(geometry.pictureQuad.height)
            // ⓑ: this draw's quads were computed for the canvas that is on screen when it ran. Nothing
            // has moved since the tick, so the canvas now is the canvas then.
            if geometry.canvas != canvasNow || geometry.drawableSize != geometry.canvas {
                canvasMismatches.append("\(geometry.canvas.keyString)/\(geometry.drawableSize.keyString) "
                                        + "≠ \(canvasNow.keyString)")
            }
        }

        let frozenPasses = controller.liveResizeLayouts
        let coalesced = controller.coalescedDrawCount

        // ① nothing was rendered while the hand was moving.
        XCTAssertEqual(controller.liveResizeRenderRequests, 0,
                       "a render request reached the render queue inside the drag")
        XCTAssertEqual(controller.resizeRequests - startRequests, 0,
                       "\(controller.resizeRequests - startRequests) render requests inside the drag")
        XCTAssertEqual(controller.resizeRenderStarts - startRenders, 0,
                       "\(controller.resizeRenderStarts - startRenders) renders started inside the drag")
        XCTAssertGreaterThanOrEqual(frozenPasses, passes,
                                    "the drag produced fewer frozen passes than layout passes")

        // ⓐ the picture did not bounce: no delta against the hand's direction, no change of direction,
        // and no rescale — the axis the drag does not touch stays pixel-identical.
        XCTAssertGreaterThan(draws, 0, "the drag drew nothing at all — the canvas would sit stale")
        let bounce = reversals(widths)
        XCTAssertEqual(bounce.negative, 0,
                       "the photograph got narrower while the window got wider — \(describe(widths))")
        XCTAssertEqual(bounce.alternations, 0, "the photograph changed direction — \(describe(widths))")
        // The axis the drag does not touch: if the picture were re-fitted or rescaled, this would move.
        XCTAssertEqual(Set(heights).count, 1,
                       "the photograph's pixel height changed under the hand: \(Array(Set(heights)).sorted())")

        // ⓑ every draw's canvas is the canvas on screen, and the layer refused none.
        XCTAssertTrue(canvasMismatches.isEmpty,
                      "\(canvasMismatches.count) frames were drawn for another canvas: "
                      + "\(canvasMismatches.prefix(4))")
        XCTAssertEqual(presenter.droppedStaleFrameCount, 0,
                       "the present pass refused \(presenter.droppedStaleFrameCount) stale-canvas requests")

        // ⓒ merged: at most one draw per tick — half the passes — while the hand is moving.
        XCTAssertLessThanOrEqual(draws, steps / 2,
                                 "\(draws) draws for \(steps) layout passes — nothing was coalesced")
        XCTAssertGreaterThanOrEqual(coalesced, 1,
                                    "no draw was ever folded into a tick's draw — nothing was coalesced")

        // ③ the release: one render request, at the size the hand stopped on.
        controller.endLiveResize()
        XCTAssertFalse(controller.isCanvasGeometryFrozen)
        XCTAssertEqual(controller.resizeRequests - startRequests, 1,
                       "the release asked for \(controller.resizeRequests - startRequests) frames, not one")
        XCTAssertTrue(waitFor { controller.lastFrame?.canvas == controller.viewportPixels },
                      "no frame for the canvas the hand stopped on")
        tick(0.05)
        XCTAssertEqual(controller.resizeRenderStarts - startRenders, 1,
                       "the release rendered \(controller.resizeRenderStarts - startRenders) times")

        let settled = try XCTUnwrap(controller.lastFrame)
        XCTAssertEqual(settled.canvas, controller.viewportPixels,
                       "the frame on the canvas was rendered for another canvas — the 「变扁」 condition")
        let finalDraw = try XCTUnwrap(presenter.presentedGeometry)
        XCTAssertEqual(finalDraw.canvas, controller.viewportPixels,
                       "the last thing drawn is not for the canvas on screen")
        XCTAssertEqual(finalDraw.drawableSize, finalDraw.canvas)

        // ⓓ a resize is not a decode input.
        XCTAssertEqual(controller.decodeRequests - startDecodes, 0,
                       "\(controller.decodeRequests - startDecodes) decodes were asked for by a resize")

        // the final sizes are exactly equal — the last step, not a neighbour.
        let all = widths + [finalDraw.pictureQuad.width]
        XCTAssertGreaterThanOrEqual(finalDraw.pictureQuad.width, widths[0],
                                    "the released frame is narrower than the drag started with")
        let total = reversals(all)
        XCTAssertEqual(total.negative + total.alternations, 0,
                       "the whole drag reversed — \(describe(all))")

        print("""
        [068 · window] \(steps) steps 1200→1600 pt, \(passes) layout passes, \(frozenPasses) frozen passes
          draws            \(draws) (≤ \(steps / 2) required), folded into a tick \(coalesced)
          renders          during 0, on release \(controller.resizeRenderStarts - startRenders) (≤ \(steps / 2) required)
          canvas==bounds   \(draws) draws checked, \(canvasMismatches.count) mismatches, \
        \(presenter.droppedStaleFrameCount) refused by the presenter
          quad             \(firstQuad.keyString) → \(finalDraw.pictureQuad.keyString), \
        height \(heights.first ?? 0) px constant, narrower-only \(total.negative) / alternations \(total.alternations)
          decode           +\(controller.decodeRequests - startDecodes)
          frames held      \(controller.framesHeldDuringGesture) mid-gesture, \(controller.staleCanvasDrops) before rendering
        """)
    }

    /// The window's own resize, in the app's order.
    ///
    /// AppKit lays the content out **eagerly** inside `setContentSize`, so that first pass still sees the
    /// harness's `frameSource` — which carries the canvas as a value — on the old size. Set it, then let
    /// the canvas lay out once more so its own pass sees the pair in step. (The app has no frame source:
    /// `viewDidLayout` reads `viewportPixels`, which is already the new canvas, so its single pass does.)
    private func resizeCanvas(_ controller: LoupeController, _ window: NSWindow, to size: CGSize) {
        window.setContentSize(size)
        syncCanvas(controller)
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
    }

    // MARK: - the counter-proof: without the freeze, one render per layout pass

    func testWithoutTheFreezeEveryLayoutPassAsksForAFrame() throws {
        let url = try fixture()
        let controller = LoupeController(session: CatalogSession())
        let window = makeWindow(CGSize(width: 1200, height: 800))
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        controller.view.layoutSubtreeIfNeeded()
        tick(0.05)
        show(controller, url: url, identity: "resize-068-window-off")
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        tick(0.05)

        let startRequests = controller.resizeRequests
        let startViewRenders = controller.viewRenderCount
        controller.disableResizeCoalescing = true
        controller.beginLiveResize()
        XCTAssertFalse(controller.isCanvasGeometryFrozen,
                       "the counter-proof switch did not disable the freeze")

        let steps = 40
        for step in 1...steps {
            resizeCanvas(controller, window, to: CGSize(width: 1200 + CGFloat(step) * 10, height: 800))
            if step % 2 == 0 { tick() }
        }
        tick(0.1)
        let requests = controller.resizeRequests - startRequests

        XCTAssertGreaterThan(requests, steps / 2,
                             "the counter-proof asked for \(requests) frames for \(steps) passes; it is "
                             + "supposed to reproduce the per-pass storm that made the picture bounce")
        print("[068 · counter-proof] freeze off: \(steps) layout passes → \(requests) render requests, "
              + "\(controller.viewRenderCount - startViewRenders) scheduled renders — the pre-068 shape")
        controller.disableResizeCoalescing = false
        controller.endLiveResize()
        tick(0.05)
    }

    // MARK: - ② the inspector divider, 274 → 360 in twenty steps

    func testInspectorDividerDragShowsTheSameFourNumbers() throws {
        let url = try fixture()
        _ = NSApplication.shared
        let session = CatalogSession()
        session.mode = .loupe
        let workspace = WorkspaceRootView(session: session)
        let window = makeWindow(CGSize(width: 1600, height: 1000))
        window.contentView = workspace
        workspace.layoutSubtreeIfNeeded()
        tick(0.08)
        let controller = workspace.loupeController
        show(controller, url: url, identity: "resize-068-divider")
        arriveAtFirstFrame(controller)
        let presenter = try XCTUnwrap(controller.canvasPresenter, "no presenter")

        // The wiring that was missing: a divider drag must announce itself to the canvas.
        XCTAssertTrue(workspace.panelDividersAreWired,
                      "a divider is not wired to the canvas freeze — its drag renders per mouse tick")

        // Start from the narrowest inspector the layout allows, so the twenty steps really move the
        // canvas (the drag below starts at 274, which `clampInspectorWidth` pins to 300), and let the
        // frame for that canvas land — the release below has to be a *new* frame, not this one.
        workspace.setInspectorWidth(WorkspaceLayout.inspectorWidthMin)
        workspace.layoutSubtreeIfNeeded()
        syncCanvas(controller)
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(waitFor { controller.lastFrame?.canvas == controller.viewportPixels },
                      "the pre-drag frame never landed on the canvas it was made for")

        let startInspector = workspace.currentInspectorWidth
        let startCanvas = controller.viewportPixels
        let startRenders = controller.resizeRenderStarts
        let startRequests = controller.resizeRequests
        let startDecodes = controller.decodeRequests
        let firstQuad = try XCTUnwrap(presenter.presentedGeometry?.pictureQuad)
        var lastDrawCount = presenter.presentCount

        workspace.beginPanelDividerDrag()
        XCTAssertTrue(controller.isCanvasGeometryFrozen,
                      "a divider drag does not freeze the canvas — this is entrance two")

        let steps = 20
        var draws = 0
        var widths: [Int] = [firstQuad.width]
        var heights: [Int] = [firstQuad.height]
        var canvasMismatches: [String] = []
        var passes = 0

        for step in 1...steps {
            resizeInspector(workspace, to: 274 + CGFloat(step) * 4.3)
            passes += 1
            guard step % 2 == 0 else { continue }
            tick()
            guard presenter.presentCount != lastDrawCount else { continue }
            draws += presenter.presentCount - lastDrawCount
            lastDrawCount = presenter.presentCount
            let geometry = try XCTUnwrap(presenter.presentedGeometry)
            let canvasNow = controller.viewportPixels
            widths.append(geometry.pictureQuad.width)
            heights.append(geometry.pictureQuad.height)
            if geometry.canvas != canvasNow || geometry.drawableSize != geometry.canvas {
                canvasMismatches.append("\(geometry.canvas.keyString)/\(geometry.drawableSize.keyString) "
                                        + "≠ \(canvasNow.keyString)")
            }
        }

        let frozenPasses = controller.liveResizeLayouts

        XCTAssertEqual(controller.liveResizeRenderRequests, 0,
                       "a render request reached the queue inside the divider drag")
        XCTAssertEqual(controller.resizeRequests - startRequests, 0,
                       "\(controller.resizeRequests - startRequests) render requests inside the divider drag")
        XCTAssertEqual(controller.resizeRenderStarts - startRenders, 0,
                       "\(controller.resizeRenderStarts - startRenders) renders started inside the divider drag")

        XCTAssertGreaterThan(draws, 0, "the divider drag drew nothing — the canvas would sit stale")
        // ⓐ the canvas only narrows here, so the frozen picture is **cropped**: its visible width shrinks
        // with the surface, monotonically and never back — while its **height**, the axis the drag does
        // not touch, is exactly constant. A re-fit or a rescale under the hand moves both (that is what
        // the pre-068 picture did, one re-fit per landed frame).
        let bounce = reversals(widths)
        XCTAssertEqual(bounce.alternations, 0,
                       "the photograph changed direction while the canvas moved one way — \(describe(widths))")
        XCTAssertTrue(widths.allSatisfy { $0 <= widths[0] },
                      "the photograph got wider while the canvas only narrowed — \(describe(widths))")
        XCTAssertEqual(Set(heights).count, 1,
                       "the photograph's pixel height changed under the hand: \(Array(Set(heights)).sorted())")

        XCTAssertTrue(canvasMismatches.isEmpty,
                      "\(canvasMismatches.count) frames were drawn for another canvas: "
                      + "\(canvasMismatches.prefix(4))")
        XCTAssertEqual(presenter.droppedStaleFrameCount, 0)
        XCTAssertLessThanOrEqual(draws, steps / 2,
                                 "\(draws) draws for \(steps) divider passes — nothing was coalesced")

        // ③ the release: one request, and a frame for the width the hand stopped on.
        workspace.endPanelDividerDrag()
        XCTAssertFalse(controller.isCanvasGeometryFrozen)
        XCTAssertEqual(controller.resizeRequests - startRequests, 1,
                       "the release asked for \(controller.resizeRequests - startRequests) frames, not one")
        XCTAssertTrue(waitFor { controller.lastFrame?.canvas == controller.viewportPixels },
                      "no frame for the divider's final width")
        tick(0.05)
        XCTAssertEqual(controller.resizeRenderStarts - startRenders, 1,
                       "the divider's release rendered \(controller.resizeRenderStarts - startRenders) times")

        let settled = try XCTUnwrap(controller.lastFrame)
        XCTAssertEqual(settled.canvas, controller.viewportPixels,
                       "the frame on the canvas was rendered for another canvas")
        XCTAssertNotEqual(controller.viewportPixels, startCanvas,
                          "the twenty steps never moved the canvas — the drag proved nothing")
        let finalDraw = try XCTUnwrap(presenter.presentedGeometry)
        XCTAssertEqual(finalDraw.canvas, controller.viewportPixels)
        XCTAssertEqual(finalDraw.drawableSize, finalDraw.canvas)

        XCTAssertEqual(controller.decodeRequests - startDecodes, 0,
                       "\(controller.decodeRequests - startDecodes) decodes were asked for by a divider drag")

        // No reversal anywhere in the drag, release included: the picture only ever got narrower as the
        // canvas did, never wider again (the direction flip is the bounce).
        let whole = widths + [finalDraw.pictureQuad.width]
        let total = reversals(whole)
        XCTAssertEqual(total.alternations, 0, "the whole drag reversed — \(describe(whole))")
        XCTAssertTrue(whole.allSatisfy { $0 <= whole[0] },
                      "a draw after the drag was wider than it started while the canvas only narrowed")

        print("""
        [068 · divider] inspector \(Int(startInspector))→\(Int(workspace.currentInspectorWidth)) pt, \
        \(steps) steps, \(passes) layout passes, \(frozenPasses) frozen passes
          draws            \(draws) (≤ \(steps / 2) required), folded into a tick \(controller.coalescedDrawCount)
          renders          during 0, on release \(controller.resizeRenderStarts - startRenders)
          canvas==bounds   \(draws) draws checked, \(canvasMismatches.count) mismatches
          quad             \(firstQuad.keyString) → \(finalDraw.pictureQuad.keyString), \
        height \(heights.first ?? 0) px constant, narrower-only \(total.negative) / alternations \(total.alternations)
          canvas           \(startCanvas.keyString) → \(controller.viewportPixels.keyString)
          decode           +\(controller.decodeRequests - startDecodes)
          frames held      \(controller.framesHeldDuringGesture)
        """)
    }

    /// The inspector drag, in the app's order: the layout pass moves the canvas, the job's canvas is
    /// re-read from the new viewport, and the canvas lays out once more so its own pass sees the pair in
    /// step (the app has no `frameSource`, so its single pass already does).
    private func resizeInspector(_ workspace: WorkspaceRootView, to width: CGFloat) {
        workspace.setInspectorWidth(width)
        workspace.layoutSubtreeIfNeeded()
        let controller = workspace.loupeController
        syncCanvas(controller)
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
    }

    // MARK: - both entrances are one channel

    /// The two entry points must not be two implementations: a window drag and a divider drag have to be
    /// the same freeze, the same counters and the same release. This asserts the identity rather than the
    /// behaviour, so a future divergence cannot hide behind two green resize tests.
    func testTheTwoEntrancesShareOneFreeze() throws {
        let url = try fixture()
        let controller = LoupeController(session: CatalogSession())
        let window = makeWindow(CGSize(width: 800, height: 600))
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        controller.view.layoutSubtreeIfNeeded()
        tick(0.05)
        show(controller, url: url, identity: "resize-068-one-channel")
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")

        controller.beginLiveResize()
        XCTAssertTrue(controller.isCanvasGeometryFrozen)
        XCTAssertEqual(controller.activeGeometryGestureCount, 1)
        // The same source twice: idempotent, so a notification doubled by the view override and the
        // window observer cannot unbalance the release.
        controller.beginLiveResize()
        XCTAssertEqual(controller.activeGeometryGestureCount, 1)

        controller.beginCanvasGeometryGesture(.panelDivider)
        XCTAssertEqual(controller.activeGeometryGestureCount, 2)
        controller.endCanvasGeometryGesture(.panelDivider)
        XCTAssertTrue(controller.isCanvasGeometryFrozen,
                      "the freeze ended while the window edge was still held")
        controller.endLiveResize()
        XCTAssertFalse(controller.isCanvasGeometryFrozen)
        XCTAssertEqual(controller.activeGeometryGestureCount, 0)

        // Nothing left over: the next layout pass is an ordinary resize, and it renders.
        let before = controller.resizeRenderStarts
        resizeCanvas(controller, window, to: CGSize(width: 900, height: 640))
        XCTAssertTrue(waitFor { controller.resizeRenderStarts > before },
                      "an ordinary resize after the gestures rendered nothing")
    }
}
