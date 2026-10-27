import XCTest
import AppKit
import CryptoKit
import Metal
@testable import PhotonsCore
import PhotonsUI

/// 053 — the low-resolution picture behind a shrinking frame must shrink **with** the frame.
///
/// The bug as reported:
/// > 缩小时，我想法是在背景贴一个全画面低清晰度预览避免黑边。这个预览需要缩放到和开始的画面同程度，
/// > 然后以同样的动画缩小。现在预览是固定死，大小为 fit。
///
/// The cause was a default: `LoupeController` passed `backdrop: drawn` and let
/// `CanvasPresenter.render(..., backdropWindow: .whole)` fill in the window, so the shader's
/// `backdropUV = (0,0) + canvasUV · (1,1)` spread the *whole picture* over the canvas at every zoom
/// level — a static fit-sized picture that never moves. The fix is one argument per present:
/// `backdropWindow: window`, the **same value** the frame is read through, so both textures are one
/// mapping (`backdropUV == uv`) and the backdrop is drawn where the frame is drawn, at whatever scale
/// the frame is at.
///
/// Four kinds of evidence, in the order the failures would show up:
///
///   1. **The wiring, per present.** `BackdropPresent` now records the window the backdrop was
///      actually given, so every present of a real 300 % → 适应 transition can be checked field by
///      field: `window == backdropWindow`, all four of u0/v0/du/dv.
///   2. **The geometry is not a constant.** Three windows of one shrink (300 %, the middle of the
///      animation, 适应) are three different windows, growing monotonically — the "same animation,
///      same degree" half of the report.
///   3. **The pixels follow the window.** A synthetic backdrop and a synthetic frame are composited
///      through one window, and the canvas is read back: a pixel in the band around the picture is
///      the backdrop sampled **at the window's own texel**, and the counterexample — the same draw
///      with `backdropWindow: .whole` — reads a different texel and a different colour. That second
///      render is the mutation proof: it is what the code did before this change, asserted to be red.
///   4. **Nothing else moved.** A covering window still gets no backdrop (039's rule, unchanged), and
///      under `PHOTONS_BENCH=1` the pass with the new window is timed against the old one: the same
///      fragment function, the same cost.
@MainActor
final class BackdropTransformTests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    private var windows: [NSWindow] = []

    /// Millisecond numbers are recorded only under `PHOTONS_BENCH=1` (project rule): `swift test`
    /// builds Debug, where they are not the shipping ones.
    private var benchmarks: Bool { ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" }

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

    private func waitFor(_ timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func makeController(url: URL, identity: String) -> LoupeController {
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
        controller.frameSource = LoupeController.FrameSource(url: url, identity: identity,
                                                             viewport: Self.viewport, state: .fit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        pump(0.1)
        return controller
    }

    private func enter(_ controller: LoupeController, at point: CGPoint = CGPoint(x: 64, y: 140)) {
        controller.pointerExited()
        controller.pointerMoved(to: point)
    }

    @discardableResult
    private func settleBackdrop(_ controller: LoupeController, timeout: TimeInterval = 60) -> Bool {
        waitFor(timeout) { controller.backdrop.isIdle }
    }

    private func settleZoom(_ controller: LoupeController, zoom: Double) -> Bool {
        waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == zoom }
    }

    private static func describe(_ w: PresentWindow) -> String {
        String(format: "u0 %.4f · v0 %.4f · du %.4f · dv %.4f", w.u0, w.v0, w.du, w.dv)
    }

    // MARK: - ① every present reads both textures through one window

    /// The claim the fix is: **one window, two textures**. Everything else in `053` follows from it,
    /// so it is pinned on every present of a real 300 % → 适应 transition, not on a sample of them —
    /// and against the bridge's own record of the window each frame was drawn with, so "the backdrop
    /// got the frame's window" cannot be true by accident of two separately-computed values.
    func testEveryBackdropPresentReadsBothTexturesThroughOneWindow() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "backdrop-transform")
        enter(controller)
        XCTAssertTrue(settleBackdrop(controller), "the backdrop render never finished")
        let lowRes = try XCTUnwrap(controller.backdrop.size, "no low-res picture to draw")

        // 100 % → 200 % → 300 %, then the whole way down to 适应 in one transition: the frames where
        // the picture is larger than the canvas (no backdrop, by 039's rule) and the frames where it
        // is not (backdrop) are both in the log.
        let point = CGPoint(x: 100, y: 120)
        controller.zoomToActualSize(aroundView: point)
        XCTAssertTrue(settleZoom(controller, zoom: 1))
        controller.zoom(to: 2, aroundView: point)
        XCTAssertTrue(settleZoom(controller, zoom: 2))
        controller.zoom(to: 3, aroundView: point)
        XCTAssertTrue(settleZoom(controller, zoom: 3))
        pump(0.15)

        let armed = controller.zoomBridgeArmedCount
        let before = controller.backdropPresents.count
        controller.zoomToFit()
        XCTAssertTrue(waitFor { controller.zoomBridge == nil }, "the bridge never ended")
        XCTAssertTrue(waitFor { controller.lastBackdropPresent?.serial == 0 },
                      "the settled frame at 适应 never landed")
        pump(0.1)

        let presents = Array(controller.backdropPresents.dropFirst(before))
        let frames = controller.zoomBridgeFrames.filter { $0.serial > armed }
        XCTAssertGreaterThanOrEqual(frames.count, 3,
                                    "the transition presented \(frames.count) frames — it proved nothing "
                                    + "about a window that moves")

        // ── ①a the four fields, on every present that was recorded.
        for p in presents {
            XCTAssertEqual(p.window.u0, p.backdropWindow.u0, "serial \(p.serial): u0")
            XCTAssertEqual(p.window.v0, p.backdropWindow.v0, "serial \(p.serial): v0")
            XCTAssertEqual(p.window.du, p.backdropWindow.du, "serial \(p.serial): du")
            XCTAssertEqual(p.window.dv, p.backdropWindow.dv, "serial \(p.serial): dv")
            XCTAssertTrue(p.windowsMatch, "serial \(p.serial): \(Self.describe(p.window)) vs backdrop "
                          + Self.describe(p.backdropWindow))
            // The record still cannot lie about the geometry it was recorded with (039).
            XCTAssertEqual(p.coversCanvas, p.window.coversCanvas)
            if p.coversCanvas {
                XCTAssertNil(p.backdrop, "a covering frame must still get no backdrop (039 ④)")
            } else {
                XCTAssertEqual(p.backdrop, lowRes, "a shrinking frame draws the whole picture behind it")
            }
        }
        // The read-only accessor reports the same thing the log does.
        XCTAssertEqual(controller.lastBackdropPresent, presents.last)

        // ── ①b and the window the present records *is* the one the bridge drew that frame with.
        XCTAssertGreaterThanOrEqual(frames.count, 3)
        let bridgeWindows = frames.map(\.window)
        let bridgePresents = presents.filter { $0.serial > armed }
        XCTAssertFalse(bridgePresents.isEmpty, "no bridge frame carried a backdrop record")
        for p in bridgePresents {
            XCTAssertTrue(bridgeWindows.contains(p.window),
                          "serial \(p.serial): the present's window \(Self.describe(p.window)) is not one "
                          + "of the bridge's own windows")
        }

        // ── ①c three different windows, and the backdrop's window moves with them.
        let distinct = bridgeWindows.reduce(into: [PresentWindow]()) { acc, w in
            if !acc.contains(w) { acc.append(w) }
        }
        XCTAssertGreaterThanOrEqual(distinct.count, 3,
                                    "one shrink presented \(distinct.count) distinct windows — the "
                                    + "backdrop window cannot have followed an animation it never saw")

        // 039's covering-frame rule is still exercised (the settled frame at 适应 is `.whole`, i.e. it
        // reaches every canvas pixel and must be drawn *without* a backdrop — the 2 px feather would
        // otherwise mix low resolution into the picture's own edge).
        XCTAssertTrue(presents.contains { $0.coversCanvas && $0.backdrop == nil },
                      "no covering present in the log — 039's nil rule went untested here")
        XCTAssertTrue(bridgePresents.allSatisfy { $0.backdrop != nil || $0.coversCanvas })

        print("[053] 300 % → 适应: \(frames.count) bridge frames, \(distinct.count) distinct windows, "
              + "\(bridgePresents.filter { $0.backdrop != nil }.count) with a \(lowRes.width)×\(lowRes.height) "
              + "backdrop, every present window == backdropWindow")
        for (i, w) in distinct.prefix(3).enumerated() {
            print("       window \(i): \(Self.describe(w))\(w.coversCanvas ? " · covers canvas" : " · band")")
        }
        if let last = distinct.last, distinct.count > 3 {
            let band = (1 - 1 / Double(last.du)) * 100
            print(String(format: "       window %d (last): %@ · band %.2f%% of the canvas width",
                         distinct.count - 1, Self.describe(last), band))
        }
    }

    // MARK: - ② three windows of one shrink are three different windows

    /// 「缩放到和开始的画面同程度，然后以同样的动画缩小」 read as arithmetic: the backdrop's window is
    /// the frame's own `LoupeZoomBridge` window, so at 300 %, halfway and 适应 it takes three different
    /// values, monotonically growing towards the end of the animation — not a constant, and not the
    /// identity except at progress 0, where the frame itself is the identity ("the picture as it is").
    /// `textureSize` is the canvas, which is the size of the texture the loupe presents.
    func testThreeWindowsOfOneShrinkGrowWithTheAnimation() throws {
        let canvas = ImageSize(width: 640, height: 400)
        let framing = LoupeFraming(viewport: canvas, sourceWidth: 6000, sourceHeight: 4000)
        let from = LoupeViewState(mode: .actual, zoom: 3)
        let to = LoupeViewState.fit
        let bridge = LoupeZoomBridge(fromContent: framing.contentPixels(of: from),
                                     toContent: framing.contentPixels(of: to),
                                     fromMapping: framing.mapping(of: from),
                                     toMapping: framing.mapping(of: to),
                                     canvas: canvas, anchor: .center)

        let w0 = bridge.window(atProgress: 0, textureSize: canvas)          // 300 %
        let w5 = bridge.window(atProgress: 0.5, textureSize: canvas)        // the middle of the slide
        let w1 = bridge.window(atProgress: 1, textureSize: canvas)          // 适应

        // Three different windows — the property the `.whole` default destroyed. Frame 0 of a bridge is
        // the canvas as it is (the identity), which is also why the start of a shrink has no black
        // edge: the picture already covers the canvas, so the backdrop drawn through the same window
        // covers it too.
        XCTAssertEqual(w0, PresentWindow.whole, "progress 0 is the picture as it is on the canvas")
        XCTAssertNotEqual(w0, w5, "the start and the midpoint share a window")
        XCTAssertNotEqual(w5, w1, "the midpoint and 适应 share a window")
        XCTAssertNotEqual(w0, w1, "the start and 适应 share a window")
        XCTAssertNotEqual(w1, PresentWindow.whole, "适应 is the identity window — the old .whole value")

        // …and they move in one direction, by the frame's own scale: the backdrop grows exactly as the
        // picture does, because it is the same number.
        XCTAssertLessThan(Double(w0.du), Double(w5.du), "the window must grow towards 适应")
        XCTAssertLessThan(Double(w5.du), Double(w1.du))
        XCTAssertLessThan(Double(w0.dv), Double(w5.dv))
        XCTAssertLessThan(Double(w5.dv), Double(w1.dv))
        XCTAssertTrue(w0.coversCanvas, "300 % still reaches every canvas pixel")
        XCTAssertFalse(w5.coversCanvas, "by the midpoint the picture no longer does")
        XCTAssertFalse(w1.coversCanvas, "适应 leaves a band — that band is what the backdrop is for")

        // The identity the fix buys, stated as a formula: the fragment samples the backdrop at
        // `p.c.xy + canvasUV · p.c.zw` and the vertex stage samples the frame at
        // `p.b.xy + canvasUV · p.b.zw`; with `p.c == p.b` the two are one expression, so the backdrop
        // texel at a canvas point is the frame's texel at that point.
        for (x, y) in [(0.0, 0.0), (0.13, 0.42), (0.5, 0.5), (0.97, 0.03), (1.0, 1.0)] {
            let cx = x * Double(canvas.width), cy = y * Double(canvas.height)
            for w in [w0, w5, w1] {
                let texel = w.texel(canvasX: cx, canvasY: cy, canvas: canvas)
                let shader = (u: Double(w.u0) + x * Double(w.du), v: Double(w.v0) + y * Double(w.dv))
                XCTAssertEqual(texel.u, shader.u, accuracy: 1e-12,
                               "\(Self.describe(w)): the window's texel is not the shader's uv")
                XCTAssertEqual(texel.v, shader.v, accuracy: 1e-12)
            }
        }
        print("[053] one shrink, three windows:\n"
              + "       300 %: \(Self.describe(w0))\n"
              + "       mid:   \(Self.describe(w5))\n"
              + "       适应:  \(Self.describe(w1))")
    }

    // MARK: - ③ the pixels: the band is the backdrop, read through the frame's window

    /// The on-screen drawable cannot be read back, so the pixel half of this task is the same pass
    /// rendered into a texture (the engine's own arithmetic, `CanvasPresenter.render`).
    ///
    /// A backdrop that is **two colours split down the middle** makes the two mappings impossible to
    /// confuse: read through the frame's window, a point in the band left of the picture clamps to
    /// the backdrop's *left* edge (red); read through `.whole` — the old behaviour — the same point
    /// reads the backdrop at its own canvas position, which for this geometry is the *right* half
    /// (blue). The second render is the mutation: it is what the code did before this change, and the
    /// assertion the fix satisfies fails on it.
    ///
    /// The window is a *shrink* (`du = 1/s > 1`) because that is the only shape that can carry a
    /// backdrop at all: `backdropTexture(for:)` returns `nil` whenever `window.coversCanvas`. The
    /// window in the task text — `(0.25, 0.25, 0.5, 0.5)` — is a zoom-*in*, `coversCanvas == true`,
    /// and the 2 px feather leaves the whole canvas frame-dominated; `testTheZoomInWindowCannotCarryA
    /// Backdrop` pins that, which is why the pixel proof is done on the shape the feature exists for.
    func testTheBandIsTheBackdropReadThroughTheFramesOwnWindow() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 256, height: 256)

        let red: [Float] = [0.90, 0.10, 0.10, 1]
        let blue: [Float] = [0.10, 0.10, 0.90, 1]
        let frameColour: [Float] = [0.20, 0.80, 0.20, 1]
        let backdrop = try halves(device, 64, 64, left: red, right: blue)
        let frame = try solid(device, 128, 128, frameColour)
        let target = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                     [.shaderRead, .renderTarget])

        // The picture occupies the right-hand 40 % of the canvas: rect = (0.6, 0, 0.4, 1), i.e.
        // du = 2.5, u0 = −1.5. A shrinking window, exactly the family `ZoomBridgeFrame` produces.
        let window = PresentWindow(u0: -1.5, v0: 0, du: 2.5, dv: 1)
        XCTAssertFalse(window.coversCanvas, "this window leaves a band on the left")
        XCTAssertGreaterThan(Double(window.du), 1, "a shrink reads past the texture's edge")

        // The probe: canvas x = 133 of 256 → canvasUV.x = 0.52, left of the picture (0.6) so the pass
        // draws the backdrop there (weight 0), away from the two pixels of feather.
        let probe = (x: 133, y: 128)
        let probeUV = window.texel(canvasX: Double(probe.x), canvasY: Double(probe.y), canvas: canvas)
        XCTAssertLessThan(probeUV.u, 0, "the probe must read past the texture's left edge through this window")

        // ── the fix: the backdrop reads through the frame's window, so the band is the picture's own
        // left edge — texel u = 0, i.e. `red`.
        XCTAssertTrue(presenter.render(frame, window: window, backdrop: backdrop,
                                       backdropWindow: window, into: target, linearize: false),
                      presenter.lastFailure ?? "the present pass failed")
        let fixed = Self.pixelAt(target, probe.x, probe.y)
        XCTAssertEqual(fixed[0], red[0], accuracy: 1.0 / 255,
                       "band pixel (133, 128): the backdrop must be sampled at texel u = "
                       + "\(probeUV.u) clamped to 0 — the picture's own left edge")
        XCTAssertEqual(fixed[2], red[2], accuracy: 1.0 / 255)
        // Inside the picture the frame is still the frame (the feather is 2 px wide, the probe is far in).
        let inside = Self.pixelAt(target, 230, 128)
        Self.assertColour(inside, frameColour, "inside the picture at (230, 128) must be the frame")
        // And nothing on the canvas is unrendered.
        let all = Self.readRGBA16(target)
        let unpainted = stride(from: 0, to: all.count, by: 4)
            .filter { all[$0] == 0 && all[$0 + 1] == 0 && all[$0 + 2] == 0 }.count
        XCTAssertEqual(unpainted, 0, "\(unpainted) canvas pixels are unrendered black")

        // ── the counterexample, in the same geometry: `backdropWindow: .whole` — what every present
        // did before this change. The same band pixel is now the backdrop at canvasUV = 0.52, i.e. the
        // right half, and the assertion above is red on it.
        let whole = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                    [.shaderRead, .renderTarget])
        XCTAssertTrue(presenter.render(frame, window: window, backdrop: backdrop,
                                       backdropWindow: .whole, into: whole, linearize: false))
        let mutated = Self.pixelAt(whole, probe.x, probe.y)
        XCTAssertEqual(mutated[2], blue[2], accuracy: 1.0 / 255,
                       "with .whole the band reads the backdrop at the canvas's own position — the "
                       + "static fit picture of the report")
        XCTAssertGreaterThan(abs(mutated[0] - fixed[0]), 0.5,
                             "the two mappings must be distinguishable at this pixel, or this test "
                             + "proves nothing: fixed \(fixed[0]) vs .whole \(mutated[0])")
        XCTAssertNotEqual(Self.bytes(whole), Self.bytes(target),
                          "the whole-canvas draw must differ from the windowed one")

        // ── and the layer moves with the animation: three windows of one shrink (the picture taking
        // 45 %, 40 % and 30 % of the canvas) are three different canvases, each with its band where
        // its own window says it is.
        var canvases: [[Float]] = []
        for fraction in [Float(0.55), 0.60, 0.70] {
            let du = 1 / (1 - fraction)
            let w = PresentWindow(u0: -fraction * du, v0: 0, du: du, dv: 1)
            let out = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                      [.shaderRead, .renderTarget])
            XCTAssertTrue(presenter.render(frame, window: w, backdrop: backdrop,
                                           backdropWindow: w, into: out, linearize: false))
            // One pixel just inside the picture's left edge, one just outside it: the boundary is
            // where this window says it is, to the pixel.
            let x0 = Int(((Double(-w.u0) / Double(w.du)) * Double(canvas.width)).rounded())
            XCTAssertGreaterThan(x0, 0)
            let inEdge = Self.pixelAt(out, min(x0 + 4, canvas.width - 1), 128)
            let outEdge = Self.pixelAt(out, max(x0 - 4, 0), 128)
            Self.assertColour(inEdge, frameColour, "fraction \(fraction): just inside the picture")
            Self.assertColour(outEdge, red, "fraction \(fraction): just outside it is the backdrop's edge")
            canvases.append(Self.readRGBA16(out))
        }
        XCTAssertNotEqual(Self.hash(canvases[0]), Self.hash(canvases[1]),
                          "45 % and 40 % must not draw the same canvas")
        XCTAssertNotEqual(Self.hash(canvases[1]), Self.hash(canvases[2]),
                          "40 % and 30 % must not draw the same canvas")
        XCTAssertNotEqual(Self.hash(canvases[0]), Self.hash(canvases[2]))

        print(String(format: "[053] band pixel (133, 128): window-mapped = %.3f/%.3f/%.3f (backdrop at "
                     + "texel u %.3f → clamped 0), .whole = %.3f/%.3f/%.3f (backdrop at u 0.52)",
                     fixed[0], fixed[1], fixed[2], probeUV.u,
                     mutated[0], mutated[1], mutated[2]))
    }

    // MARK: - ④ a zoom-in window cannot carry a backdrop (why ③ uses a shrink)

    /// The window named in the task text, `(0.25, 0.25, 0.5, 0.5)`, is a **zoom-in**: the picture is
    /// twice the canvas in each axis, so `coversCanvas` is true, `backdropTexture(for:)` returns `nil`,
    /// and no present in the app can ever carry a backdrop with it. It is also the case where the two
    /// mappings are indistinguishable on the canvas: with the picture covering everything, the 2 px
    /// feather never reaches, so every pixel is the frame's own sample of `uv = (0.25, 0.25)` at the
    /// top-left corner — under either window.
    ///
    /// Pinned so the choice in ③ is a documented fact about the geometry rather than an omission.
    func testTheZoomInWindowCannotCarryABackdrop() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 256, height: 256)
        let window = PresentWindow(u0: 0.25, v0: 0.25, du: 0.5, dv: 0.5)

        XCTAssertTrue(window.coversCanvas,
                      "a zoom-in window reaches every canvas pixel — no backdrop is drawn through one")
        // The top-left corner reads uv = (0.25, 0.25) — the same texel under both windows.
        let corner = window.texel(canvasX: 0, canvasY: 0, canvas: canvas)
        XCTAssertEqual(corner.u, 0.25, accuracy: 1e-6)
        XCTAssertEqual(corner.v, 0.25, accuracy: 1e-6)

        let red: [Float] = [0.90, 0.10, 0.10, 1]
        let blue: [Float] = [0.10, 0.10, 0.90, 1]
        let backdrop = try halves(device, 64, 64, left: red, right: blue)
        let frame = try solid(device, 128, 128, [0.20, 0.80, 0.20, 1])

        var renders: [Data] = []
        for backdropWindow in [window, PresentWindow.whole] {
            let out = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                      [.shaderRead, .renderTarget])
            XCTAssertTrue(presenter.render(frame, window: window, backdrop: backdrop,
                                           backdropWindow: backdropWindow, into: out, linearize: false))
            renders.append(Self.bytes(out))
        }
        XCTAssertEqual(renders[0], renders[1],
                       "under a covering window the canvas is the frame everywhere: the backdrop window "
                       + "cannot show up in pixels here, which is why ③ needs a shrinking window")
        print("[053] window (0.25, 0.25, 0.5, 0.5): coversCanvas = true, top-left reads uv "
              + "(0.25, 0.25); both backdrop windows render byte-identical canvases")
    }

    // MARK: - ⑤ cost (PHOTONS_BENCH=1): the new window is the same fragment, the same work

    /// The fix changes five floats in the parameter buffer and nothing else: same fragment function,
    /// same two fetches, same feather. Measured p50/p95 over 60 draws on a 4.10 Mpx canvas for the old
    /// window (`p.c = (0, 0, 1, 1)`) and the new one (`p.c = p.b`), numbers recorded and not thresholded
    /// — the budget lives in 037/039's own tests.
    func testBackdropPresentCostIsUnchangedByTheWindow() throws {
        guard benchmarks else { throw XCTSkip("PHOTONS_BENCH=1 only") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 2560, height: 1600)          // 4.10 Mpx
        XCTAssertEqual(canvas.pixelCount, 4_096_000)

        let frame = try patterned(device, ImageSize(width: 1280, height: 800))
        let backdrop = try solid(device, 1280, 800, [0.4, 0.5, 0.6, 1])
        let target = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                     [.shaderRead, .renderTarget])
        // A real shrinking window: the picture at 70 % of the canvas, moving, so `p.c` is not the
        // identity on the frames that matter.
        let window = PresentWindow(u0: -0.3, v0: -0.3, du: 1.42857143, dv: 1.42857143)
        XCTAssertGreaterThan(Double(window.du), 1)

        func percentiles(_ backdropWindow: PresentWindow) -> (p50: Double, p95: Double) {
            var samples: [Double] = []
            for _ in 0 ..< 60 {
                let t0 = CFAbsoluteTimeGetCurrent()
                _ = presenter.render(frame, window: window, backdrop: backdrop,
                                     backdropWindow: backdropWindow, into: target, linearize: true)
                samples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            samples.sort()
            return (samples[samples.count / 2], samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))])
        }
        _ = percentiles(.whole)                                   // warm the clocks up
        let old = percentiles(.whole)
        let new = percentiles(window)

        print(String(format: "[053] present 4.10 Mpx, backdrop, 60 draws: p.c = .whole p50 %.3f ms / "
                     + "p95 %.3f ms · p.c = p.b p50 %.3f ms / p95 %.3f ms (%+.3f ms at p95)",
                     old.p50, old.p95, new.p50, new.p95, new.p95 - old.p95))
        XCTAssertGreaterThan(old.p95, 0)
        XCTAssertGreaterThan(new.p95, 0)
        XCTAssertEqual(CanvasPresenter.fragmentName(backdrop), "present_fragment_backdrop",
                       "both draws go through the backdrop fragment — the comparison is one shader")
    }

    // MARK: - texture helpers (rgba16Float, shared storage, CPU readable)

    private func makeTexture(_ device: MTLDevice, _ w: Int, _ h: Int, _ format: MTLPixelFormat,
                             _ usage: MTLTextureUsage) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h,
                                                          mipmapped: false)
        d.usage = usage
        d.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }

    private func solid(_ device: MTLDevice, _ w: Int, _ h: Int, _ rgba: [Float]) throws -> MTLTexture {
        let t = try makeTexture(device, w, h, .rgba16Float, [.shaderRead])
        var row = [UInt16](repeating: 0, count: w * 4)
        for x in 0 ..< w { for c in 0 ..< 4 { row[x * 4 + c] = Float16(rgba[c]).bitPattern } }
        for y in 0 ..< h {
            row.withUnsafeBytes { buf in
                t.replace(region: MTLRegionMake2D(0, y, w, 1), mipmapLevel: 0,
                          withBytes: buf.baseAddress!, bytesPerRow: w * 8)
            }
        }
        return t
    }

    /// Two colours split down the middle in **u**: the seam makes "which texel did the sampler read"
    /// a colour question, not a distance question.
    private func halves(_ device: MTLDevice, _ w: Int, _ h: Int, left: [Float],
                        right: [Float]) throws -> MTLTexture {
        let t = try makeTexture(device, w, h, .rgba16Float, [.shaderRead])
        var row = [UInt16](repeating: 0, count: w * 4)
        for x in 0 ..< w {
            let v = x < w / 2 ? left : right
            for c in 0 ..< 4 { row[x * 4 + c] = Float16(v[c]).bitPattern }
        }
        for y in 0 ..< h {
            row.withUnsafeBytes { buf in
                t.replace(region: MTLRegionMake2D(0, y, w, 1), mipmapLevel: 0,
                          withBytes: buf.baseAddress!, bytesPerRow: w * 8)
            }
        }
        return t
    }

    /// A gradient with structure, for the cost test — the fetch has to be a real one.
    private func patterned(_ device: MTLDevice, _ size: ImageSize) throws -> MTLTexture {
        let t = try makeTexture(device, size.width, size.height, .rgba16Float, [.shaderRead])
        let w = size.width, h = size.height
        var row = [UInt16](repeating: 0, count: w * 4)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let fx = Float(x) / Float(max(w - 1, 1))
                let fy = Float(y) / Float(max(h - 1, 1))
                let v: [Float] = [0.1 + 0.8 * fx, 0.2 + 0.6 * fy, Float((x / 3 + y / 3) % 2) * 0.7, 1]
                for c in 0 ..< 4 { row[x * 4 + c] = Float16(v[c]).bitPattern }
            }
            row.withUnsafeBytes { buf in
                t.replace(region: MTLRegionMake2D(0, y, w, 1), mipmapLevel: 0,
                          withBytes: buf.baseAddress!, bytesPerRow: w * 8)
            }
        }
        return t
    }

    private static func readRGBA16(_ t: MTLTexture) -> [Float] {
        var raw = [UInt16](repeating: 0, count: t.width * t.height * 4)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: t.width * 8,
                       from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        }
        return raw.map { Float(Float16(bitPattern: $0)) }
    }

    private static func pixelAt(_ t: MTLTexture, _ x: Int, _ y: Int) -> [Float] {
        var raw = [UInt16](repeating: 0, count: 4)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: 8,
                       from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return raw.map { Float(Float16(bitPattern: $0)) }
    }

    private static func bytes(_ t: MTLTexture) -> Data {
        var raw = [UInt8](repeating: 0, count: t.width * t.height * 8)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: t.width * 8,
                       from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        }
        return Data(raw)
    }

    private static func hash(_ pixels: [Float]) -> String {
        let data = pixels.withUnsafeBytes { Data($0) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func assertColour(_ got: [Float], _ want: [Float], _ message: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        for c in 0 ..< 3 {
            XCTAssertEqual(got[c], want[c], accuracy: 1.0 / 255,
                           "\(message): channel \(c) = \(got[c]), want \(want[c])", file: file, line: line)
        }
    }
}
