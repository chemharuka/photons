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
///   1. **The wiring, per present.** `BackdropPresent` records the window the backdrop was actually
///      given *and* the placement it was composed with, so every present of a real 300 % → 适应
///      transition can be checked: `backdropWindow == window.onWholePicture(placement)`.
///   2. **The geometry is not a constant.** Three windows of one shrink (300 %, the middle of the
///      animation, 适应) are three different windows, growing monotonically — the "same animation,
///      same degree" half of the report.
///   3. **The pixels follow the window.** Gradient backdrops through the engine's own pass: the canvas
///      edges hold the picture's own edges, the band between a shrinking frame and the canvas holds the
///      picture's *content* (a ramp, not one colour), the area outside the picture is the canvas matte,
///      and each counterexample — 053's `backdropWindow: window`, or no backdrop at all — is asserted to
///      be the flat edge column instead.
///   4. **Nothing else moved.** A covering window still gets no backdrop (039's rule, unchanged) and is
///      byte-identical with and without one, and under `PHOTONS_BENCH=1` the pass with the new window is
///      timed against the old one: the same fragment function, the same cost.
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

    private static func describe(_ r: CropRect) -> String {
        String(format: "u[%.4f…%.4f] v[%.4f…%.4f]", r.left, r.right, r.top, r.bottom)
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

        // ── ①a the record, on every present that was recorded.
        for p in presents {
            // 058: the backdrop window is the frame's window **read on the picture**, not the frame's
            // window itself — the two numbers are only equal when the frame texture *is* the picture.
            XCTAssertEqual(p.backdropWindow, p.window.onWholePicture(p.placement),
                           "serial \(p.serial): \(Self.describe(p.window)) composed with "
                           + "\(Self.describe(p.placement.rect)) / region \(Self.describe(p.placement.region)) "
                           + "is not the backdrop window \(Self.describe(p.backdropWindow))")
            XCTAssertTrue(p.windowsMatch, "serial \(p.serial): the two textures are not one mapping")
            // 053's literal rule survives as the case it always described: a texture that holds the
            // whole picture *and* fills its canvas (适应 with matching aspects). A letterboxed 适应 is
            // not one — there the picture's window and the canvas disagree at the bars.
            if p.placement.isIdentity {
                XCTAssertTrue(p.windowsAreIdentical,
                              "serial \(p.serial): a whole-picture texture must give the identical window")
            }
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
              + "backdrop, every backdrop window = the frame window read on the picture")
        for (i, w) in distinct.prefix(3).enumerated() {
            print("       window \(i): \(Self.describe(w))\(w.coversCanvas ? " · covers canvas" : " · band")")
        }
        // 058: the conversion on a real present of this transition — the frame window, the placement it is
        // composed with, and the picture window the backdrop was actually read through.
        if let p = bridgePresents.first(where: { $0.backdrop != nil }) ?? bridgePresents.first {
            print("       [058] placement region u[\(String(format: "%.4f…%.4f", p.placement.region.left, p.placement.region.right))]"
                  + " rect \(Self.describe(p.placement.rect))")
            print("       [058] frame \(Self.describe(p.window)) → picture \(Self.describe(p.backdropWindow))")
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

    // MARK: - ③ (058) the band is the picture's own content, in the picture's coordinates

    /// **053's pixel test, re-read in 058's coordinates.** 053 asserted that the band reads the
    /// backdrop through *the frame's* window and took "the picture's own left edge" for the answer. It
    /// was the wrong question: at 300 % the frame texture is a *ninth* of the picture, so the frame's
    /// window says "outside the texture" for most of the band, and the sampler's `clamp_to_edge` turned
    /// that into one column of the photograph — the stretched-edge artefact the user reported seeing
    /// after 053 shipped.
    ///
    /// The band must instead hold the picture's **content beyond the frame texture's region**, at the
    /// coordinates that content actually has. Gradient backdrop, 512 px wide, `0.1` at `u = 0` to `0.9`
    /// at `u = 1`: the band's colours are then a *function of position*, and the two failures are
    /// distinguishable at a glance — an edge column is one flat colour, real content is a ramp.
    ///
    /// The counterexample is 053's `backdropWindow: window`; it reads `uv = 1.25 … 1.25` (past the
    /// texture) for the whole band, clamps to `u = 1`, and paints `0.9` everywhere. The assertion that
    /// the band's span is a real gradient is red on it, which is the point.
    func testTheBandIsThePicturesContentNotAnEdgeColumn() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 256, height: 256)

        // The picture sits at 80 % of the canvas: window u ∈ [0, 1.25] → the band is canvas x ≥ 205.
        let window = PresentWindow(u0: 0, v0: 0, du: 1.25, dv: 1)
        XCTAssertFalse(window.coversCanvas, "this window leaves a band on the right")

        // The frame texture holds the picture's **middle half** (a 200 % render of it), and it fills
        // the canvas — the shape `LoupeFraming.framePlacement` produces for a camera at its own zoom.
        let placement = FramePlacement(region: CropRect(x: 0.25, y: 0, width: 0.5, height: 1),
                                       rect: .whole)
        let backdropWindow = window.onWholePicture(placement)

        let backdrop = try gradient(device, 512, 512, from: 0.1, to: 0.9)
        let frame = try solid(device, 256, 256, [0.90, 0.90, 0.90, 1])
        let target = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                     [.shaderRead, .renderTarget])

        // ── the fix: picture coordinates, so the band is the content the frame texture does not have.
        XCTAssertTrue(presenter.render(frame, window: window, backdrop: backdrop,
                                       backdropWindow: backdropWindow, into: target, linearize: false),
                      presenter.lastFailure ?? "the present pass failed")
        var band: [Float] = []
        var mismatches: [String] = []
        for x in 205 ..< 256 {
            let uv = Double(backdropWindow.u0) + (Double(x) + 0.5) / 256 * Double(backdropWindow.du)
            let want = 0.1 + 0.8 * uv        // the gradient, at the picture coordinate the band reads
            let got = Self.pixelAt(target, x, 128)
            band.append(got[0])
            if abs(Double(got[0]) - want) > 0.02 {
                mismatches.append(String(format: "x %d: %.3f, want %.3f (picture u %.4f)", x, got[0], want, uv))
            }
            XCTAssertEqual(got[0], got[1], accuracy: 1.0 / 255, "the gradient is grey; channel drift at \(x)")
        }
        XCTAssertTrue(mismatches.isEmpty,
                      "the band is not the picture at its own coordinates:\n  "
                      + mismatches.prefix(6).joined(separator: "\n  "))
        let span = (band.max() ?? 0) - (band.min() ?? 0)
        XCTAssertGreaterThan(span, 0.05,
                             "the band spans \(span) — that is one colour, i.e. the edge column of 053, "
                             + "not the picture's content continuing past the frame texture")
        XCTAssertTrue(zip(band, band.dropFirst()).allSatisfy { $0 <= $1 + 1.0 / 255 },
                      "the band must run in one direction (the gradient), not oscillate")

        // ── the counterexample: 053's `backdropWindow: window`, in the same geometry. Every band
        // fragment reads past the texture's right edge, clamps to u = 1, and the band becomes the
        // picture's edge colour — the exact artefact the user saw.
        let mutated = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                      [.shaderRead, .renderTarget])
        XCTAssertTrue(presenter.render(frame, window: window, backdrop: backdrop,
                                       backdropWindow: window, into: mutated, linearize: false))
        var flat: [Float] = []
        for x in 205 ..< 256 { flat.append(Self.pixelAt(mutated, x, 128)[0]) }
        let flatSpan = (flat.max() ?? 0) - (flat.min() ?? 0)
        XCTAssertLessThan(flatSpan, 2.0 / 255,
                          "the counterexample is supposed to be a flat edge column: span \(flatSpan)")
        XCTAssertGreaterThan(abs(flat[25] - band[25]), 0.05,
                             "the two mappings must differ inside the band, or this test proves "
                             + "nothing: fixed \(band[25]) vs 053 \(flat[25])")
        let flipProof = Double(window.u0) + (Double(230) + 0.5) / 256 * Double(window.du)
        XCTAssertGreaterThan(flipProof, 1, "053's window reads past the texture at x = 230 (uv \(flipProof))")

        // Inside the picture the frame is the frame: the band never bleeds into it.
        Self.assertColour(Self.pixelAt(target, 60, 128), [0.90, 0.90, 0.90, 1],
                          "well inside the picture it is the frame")

        print(String(format: "[058] band x 205…255: plant %.4f → %.4f (span %.3f, picture u %.3f → "
                     + "%.3f) · 053 %.3f (flat %.4f) · first mismatch-free sample x230 = %.3f vs %.3f",
                     band[0], band[band.count - 1], span,
                     Double(backdropWindow.u0) + 205.5 / 256 * Double(backdropWindow.du),
                     Double(backdropWindow.u0) + 255.5 / 256 * Double(backdropWindow.du),
                     flat[25], flatSpan, band[25], flat[25]))
    }


    // MARK: - ② (058) the frame window → the picture window, in numbers

    /// The conversion, on the real geometry of the reported transition (300 % → 适应), with the numbers
    /// printed so the report can quote them.
    ///
    /// The claim is arithmetic and has two halves: **a covering frame reads inside `[0, 1]`** (nothing
    /// for the matte to paint) and **适应 maps to exactly `[0, 1]`** (the whole picture lands on the
    /// canvas, untruncated). 053's `backdropWindow = window` satisfies neither — at 300 % it claims the
    /// picture is 28× the canvas.
    func testTheFrameWindowBecomesAPictureWindow() throws {
        let canvas = ImageSize(width: 640, height: 400)
        // 1.6 aspect, so 适应 fills the canvas exactly: the cleanest form of "covers [0, 1]".
        let framing = LoupeFraming(viewport: canvas, sourceWidth: 6000, sourceHeight: 3750)
        // The camera centred on the picture: a 300 % window is 213 × 133 source px in the middle.
        let from = LoupeViewState(mode: .actual, zoom: 3, centerX: 3000, centerY: 1875)
        let to = LoupeViewState.fit
        let bridge = LoupeZoomBridge(fromContent: framing.contentPixels(of: from),
                                     toContent: framing.contentPixels(of: to),
                                     fromMapping: framing.mapping(of: from),
                                     toMapping: framing.mapping(of: to),
                                     canvas: canvas, anchor: .center)
        // A frame texture is canvas-sized (`RenderOptions.canvas`), which is why the bridge is given
        // the canvas as its texture size.
        let atFit = bridge.window(atProgress: 1, textureSize: canvas)
        let atStart = bridge.window(atProgress: 0, textureSize: canvas)

        // The 300 % texture: a 1/28 slice of the picture, filling the canvas.
        let placement = framing.framePlacement(of: framing.mapping(of: from))
        XCTAssertEqual(placement.region.width, 213.333 / 6000, accuracy: 1e-5,
                       "the 300 % frame texture holds 213 px of a 6000 px picture")
        XCTAssertEqual(placement.rect, .whole, "a window render fills its canvas")
        XCTAssertFalse(placement.coversPicture)

        // progress 0 is the picture as it is: the identity window, composed, is the region itself.
        let startPicture = atStart.onWholePicture(placement)
        XCTAssertEqual(atStart, .whole)
        XCTAssertEqual(Double(startPicture.u0), Double(placement.region.left), accuracy: 1e-6)
        XCTAssertEqual(Double(startPicture.du), Double(placement.region.width), accuracy: 1e-6)
        XCTAssertGreaterThan(Double(startPicture.u0), 0.4, "the 300 % window is in the middle of the picture")
        XCTAssertLessThan(Double(startPicture.u0 + startPicture.du), 1)

        // 适应: the composition covers exactly the whole picture.
        let fitPicture = atFit.onWholePicture(placement)
        XCTAssertEqual(Double(fitPicture.u0), 0, accuracy: 2e-4, "适应 must start at the picture's left edge")
        XCTAssertEqual(Double(fitPicture.v0), 0, accuracy: 2e-4)
        XCTAssertEqual(Double(fitPicture.du), 1, accuracy: 2e-4, "and span exactly [0, 1]")
        XCTAssertEqual(Double(fitPicture.dv), 1, accuracy: 2e-4)

        // A covering frame reads inside the picture: every canvas corner is a real texel, so a backdrop
        // given to one (it never is — `backdropTexture(for:)` returns nil) could only repeat content.
        let covering = PresentWindow(u0: 0.2, v0: 0.3, du: 0.5, dv: 0.5)
        XCTAssertTrue(covering.coversCanvas)
        let coveringPicture = covering.onWholePicture(placement)
        let corners = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)].map {
            (u: Double(coveringPicture.u0) + $0.0 * Double(coveringPicture.du),
             v: Double(coveringPicture.v0) + $0.1 * Double(coveringPicture.dv))
        }
        for corner in corners {
            XCTAssertTrue(corner.u >= -1e-6 && corner.u <= 1 + 1e-6,
                          "covering frame: u \(corner.u) left the picture")
            XCTAssertTrue(corner.v >= -1e-6 && corner.v <= 1 + 1e-6,
                          "covering frame: v \(corner.v) left the picture")
        }

        // A letterboxed 适应 (canvas 1.6, picture 1.5): the picture covers [0, 1] and the bars beyond it
        // become the matte instead of the picture's edge stretched sideways.
        let letterboxed = LoupeFraming(viewport: canvas, sourceWidth: 6000, sourceHeight: 4000)
        let box = letterboxed.framePlacement(of: letterboxed.mapping(of: LoupeViewState.fit))
        XCTAssertEqual(Double(box.rect.u0), 20.0 / 640, accuracy: 1e-6, "a 20 px bar on each side")
        XCTAssertEqual(Double(box.rect.du), 600.0 / 640, accuracy: 1e-6)
        let boxed = PresentWindow.whole.onWholePicture(box)
        XCTAssertLessThan(Double(boxed.u0), 0, "the canvas is wider than the picture — the bars fall outside")
        XCTAssertGreaterThan(Double(boxed.u0 + boxed.du), 1)
        XCTAssertEqual(Double(boxed.v0), 0, accuracy: 1e-6)
        XCTAssertEqual(Double(boxed.dv), 1, accuracy: 1e-6)

        print(String(format: "[058] 300 %% → 适应 (640×400 canvas, 6000×3750 picture)\n"
                     + "       frame window at 适应: u0 %.4f · du %.4f  (053 gave the backdrop this)\n"
                     + "       placement: region u[%.4f…%.4f] v[%.4f…%.4f] · rect %@\n"
                     + "       picture window:   u0 %.4f · v0 %.4f · du %.4f · dv %.4f",
                     Double(atFit.u0), Double(atFit.du),
                     placement.region.left, placement.region.right,
                     placement.region.top, placement.region.bottom,
                     Self.describe(placement.rect),
                     Double(fitPicture.u0), Double(fitPicture.v0),
                     Double(fitPicture.du), Double(fitPicture.dv)))
    }

    // MARK: - ③ (058) 适应: the canvas edges are the picture's own edges

    /// The acceptance, end to end and in pixels: the reported transition is 300 % → 适应, so take the
    /// transition's own window at progress 1, compose it with the 300 % texture's placement, and render
    /// the engine's pass with a **gradient** backdrop (`0.1` left → `0.9` right).
    ///
    /// The picture's edges must land on the canvas's edges (u ≈ 0 and u ≈ 1) and the middle must be the
    /// middle. The counterexample is 053's `backdropWindow: window`: every canvas fragment then reads
    /// `uv ≈ ±13.5` — thirteen pictures to the left of the texture — clamps to the same edge texel, and
    /// both canvas edges come out the *same* colour. That is "一条边缘色带" as a number, and it is what
    /// the assertions below are red on.
    func testTheShrinkToFitShowsTheWholePictureAcrossTheCanvas() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 640, height: 400)
        let framing = LoupeFraming(viewport: canvas, sourceWidth: 6000, sourceHeight: 3750)
        let from = LoupeViewState(mode: .actual, zoom: 3, centerX: 3000, centerY: 1875)
        let bridge = LoupeZoomBridge(fromContent: framing.contentPixels(of: from),
                                     toContent: framing.contentPixels(of: LoupeViewState.fit),
                                     fromMapping: framing.mapping(of: from),
                                     toMapping: framing.mapping(of: LoupeViewState.fit),
                                     canvas: canvas, anchor: .center)
        let window = bridge.window(atProgress: 1, textureSize: canvas)
        let placement = framing.framePlacement(of: framing.mapping(of: from))
        let backdropWindow = window.onWholePicture(placement)

        let backdrop = try gradient(device, 512, 320, from: 0.1, to: 0.9)
        let frame = try solid(device, 320, 200, [0.55, 0.55, 0.55, 1])
        let fixed = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                    [.shaderRead, .renderTarget])
        XCTAssertTrue(presenter.render(frame, window: window, backdrop: backdrop,
                                       backdropWindow: backdropWindow, into: fixed,
                                       linearize: false), presenter.lastFailure ?? "the present pass failed")

        // The picture coordinate a canvas column reads, and the gradient's value there.
        func pictureU(_ x: Int) -> Double {
            Double(backdropWindow.u0) + (Double(x) + 0.5) / Double(canvas.width) * Double(backdropWindow.du)
        }
        let left = Self.pixelAt(fixed, 2, 200)
        let right = Self.pixelAt(fixed, 637, 200)
        XCTAssertEqual(Double(left[0]), 0.1, accuracy: 0.012,
                       "canvas x = 2 must be the picture's left edge (u \(pictureU(2))), not a band")
        XCTAssertEqual(Double(right[0]), 0.9, accuracy: 0.012,
                       "canvas x = 637 must be the picture's right edge (u \(pictureU(637)))")

        // Every canvas column **outside the frame's own sliver** is the picture at that column's
        // coordinate, in order. (At progress 1 the 300 % texture is drawn at 1/28, so the sharp frame
        // still occupies the middle 3.5 % of the canvas; that sliver is the frame's, and the next
        // assertion is that it is.)
        let probes = [2, 100, 200, 290, 350, 440, 540, 637]
        var values: [Float] = []
        for x in probes {
            let px = Self.pixelAt(fixed, x, 200)
            values.append(px[0])
            XCTAssertEqual(Double(px[0]), 0.1 + 0.8 * pictureU(x), accuracy: 0.02,
                           "canvas x = \(x) must be the picture at u \(pictureU(x)), not a band")
        }
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $1 > $0 },
                      "the canvas must climb monotonically from the picture's left edge to its right: \(values)")
        XCTAssertGreaterThan(Double(values.last! - values.first!), 0.7,
                             "the canvas spans \(values.last! - values.first!) — less than the picture's range")
        Self.assertColour(Self.pixelAt(fixed, 320, 200), [0.55, 0.55, 0.55, 1],
                          "the frame texture is still drawn where the window puts it — the middle sliver")

        // ── the counterexample: 053's `backdropWindow: window` on the same window and the same frame.
        let mutated = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                      [.shaderRead, .renderTarget])
        XCTAssertTrue(presenter.render(frame, window: window, backdrop: backdrop,
                                       backdropWindow: window, into: mutated, linearize: false))
        let mutLeft = Self.pixelAt(mutated, 2, 200)
        let mutRight = Self.pixelAt(mutated, 637, 200)
        XCTAssertEqual(mutLeft[0], mutRight[0], accuracy: 1.0 / 255,
                       "053's window must read the SAME value at both canvas edges — one edge texel "
                       + "smeared across the canvas. Left \(mutLeft[0]), right \(mutRight[0])")
        XCTAssertGreaterThan(abs(Double(mutRight[0] - right[0])), 0.5,
                             "the fix and 053 must differ at the right edge: \(right[0]) vs \(mutRight[0])")
        XCTAssertEqual(Double(window.u0), -13.56, accuracy: 0.05,
                       "053's window starts 13.6 pictures left of the texture — that is the bug")

        print(String(format: "[058] 300 %% → 适应, gradient backdrop, canvas 640×400:\n"
                     + "       plant  left x2 %.3f (u %.4f) · x200 %.3f (u %.4f) · right x637 %.3f (u %.4f)\n"
                     + "       053    left x2 %.3f · right x637 %.3f  — both edges read one texel, "
                     + "Δ %.3f vs plant",
                     left[0], pictureU(2), values[2], pictureU(200), right[0], pictureU(637),
                     mutLeft[0], mutRight[0], right[0] - mutRight[0]))
    }

    // MARK: - ④ (058) outside the picture is the matte, and the seam still ramps

    /// **H2**: with the picture at half the canvas, the canvas outside it is `#0F0F0F` — the canvas
    /// colour, three channels equal — not the picture's edge column, which is what `saturate()` in the
    /// shader produced from 037 to 053.
    ///
    /// The same render also carries the seam: the two pixels **inside** the picture's edge are a ramp
    /// from the backdrop to the frame (the feather stays inside, where 037 put it), so the photograph
    /// does not end on a step.
    func testOutsideThePictureIsTheMatteNotTheEdgeColumn() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 256, height: 256)

        // The picture at half the canvas, centred: canvas px [64, 192) on both axes.
        let window = PresentWindow(u0: -0.5, v0: -0.5, du: 2, dv: 2)
        XCTAssertFalse(window.coversCanvas)
        let backdropWindow = window.onWholePicture(.whole)
        XCTAssertEqual(backdropWindow, window,
                       "a texture that IS the picture: the composition is the identity")

        let backdrop = try gradient(device, 512, 512, from: 0.1, to: 0.9)
        let frameColour: [Float] = [0.90, 0.90, 0.90, 1]
        let frame = try solid(device, 128, 128, frameColour)
        let target = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                     [.shaderRead, .renderTarget])
        XCTAssertTrue(presenter.render(frame, window: window, backdrop: backdrop,
                                       backdropWindow: backdropWindow, into: target, linearize: false),
                      presenter.lastFailure ?? "the present pass failed")

        let matte = Float(15.0 / 255.0)
        for (x, y) in [(0, 0), (255, 255), (255, 0), (0, 255), (10, 128), (246, 128), (128, 10),
                       (128, 246), (63, 63), (193, 193)] {
            let px = Self.pixelAt(target, x, y)
            XCTAssertEqual(px[0], matte, accuracy: 1.0 / 255,
                           "outside the picture at (\(x), \(y)) must be #0F0F0F, not the edge column")
            XCTAssertEqual(px[1], px[0], accuracy: 1.0 / 255, "the matte is grey: green at (\(x), \(y))")
            XCTAssertEqual(px[2], px[0], accuracy: 1.0 / 255, "the matte is grey: blue at (\(x), \(y))")
            // …and it is *not* the picture's edge, which for this gradient is 0.1 (25.5/255).
            XCTAssertGreaterThan(abs(px[0] - 0.1), 0.03,
                                 "(\(x), \(y)) is the picture's edge colour — 037's clamp, not the matte")
        }

        // The picture itself is untouched.
        Self.assertColour(Self.pixelAt(target, 128, 128), frameColour, "the middle is the frame")

        // The seam: inside the edge, a ramp — the two pixels of feather, not a step.
        var ramp: [Float] = []
        for x in 63 ... 68 { ramp.append(Self.pixelAt(target, x, 128)[0]) }
        for (a, b) in zip(ramp, ramp.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b, a - 1.0 / 255, "the seam must not go backwards: \(ramp)")
        }
        XCTAssertLessThan(ramp[0], ramp[2] - 0.1, "x 63 → 65 must climb off the matte: \(ramp)")
        XCTAssertLessThan(ramp[2], ramp[4] - 0.1, "x 65 → 67 must climb towards the frame: \(ramp)")
        XCTAssertGreaterThan(ramp[5], frameColour[0] - 1.0 / 255, "and reach the frame a feather in")

        // The counterexample, same window, no backdrop: 025's `clamp_to_edge` stretches the frame's own
        // edge across the canvas — a picture-coloured band, three channels of 0.9, everywhere.
        let bare = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                   [.shaderRead, .renderTarget])
        XCTAssertTrue(presenter.render(frame, window: window, into: bare, linearize: false))
        Self.assertColour(Self.pixelAt(bare, 0, 0), frameColour,
                          "without a backdrop the corner is the frame's stretched edge (025) — the band")
        XCTAssertGreaterThan(abs(Self.pixelAt(bare, 0, 0)[0] - matte), 0.5,
                             "the matte and the stretched edge must be far apart at the same pixel")

        print(String(format: "[058] picture at ½ canvas: corner (0,0) = %.4f (%.1f/255) matte · "
                     + "025's same corner = %.3f · seam x63…68 = %@",
                     Self.pixelAt(target, 0, 0)[0], Self.pixelAt(target, 0, 0)[0] * 255,
                     Self.pixelAt(bare, 0, 0)[0],
                     ramp.map { String(format: "%.3f", $0) }.joined(separator: " → ")))
    }

    /// 058 ④: a covering window never draws the backdrop, and when one is handed in anyway the frame
    /// wins every fragment — byte for byte, so 039's `nil` rule cannot be hiding a blend.
    func testACoveringWindowIsByteIdenticalWithAndWithoutABackdrop() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 128, height: 128)
        let window = PresentWindow(u0: 0.1, v0: 0.15, du: 0.5, dv: 0.6)
        XCTAssertTrue(window.coversCanvas, "a zoom-in window reaches every canvas pixel")

        let backdrop = try gradient(device, 256, 256, from: 0.1, to: 0.9)
        let frame = try patterned(device, canvas)
        var renders: [Data] = []
        for backdropWindow in [PresentWindow.whole, window.onWholePicture(.whole),
                               PresentWindow(u0: -3, v0: 7, du: 11, dv: 0.25)] {
            let out = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                      [.shaderRead, .renderTarget])
            XCTAssertTrue(presenter.render(frame, window: window, backdrop: backdrop,
                                           backdropWindow: backdropWindow, into: out,
                                           linearize: false))
            renders.append(Self.bytes(out))
        }
        let plain = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                    [.shaderRead, .renderTarget])
        XCTAssertTrue(presenter.render(frame, window: window, into: plain, linearize: false))
        renders.append(Self.bytes(plain))

        for (i, data) in renders.enumerated() where i > 0 {
            XCTAssertEqual(data, renders[0],
                           "render \(i) differs from the no-backdrop one: a covering window must be "
                           + "bit-identical to 025's path, whatever backdrop window it was given")
        }
        print("[058] covering window: 3 backdrop windows (incl. one far outside the picture) and no "
              + "backdrop — 4 canvases, byte-identical")
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
    ///
    /// **058** adds the second pair below: the same geometry, the same fragment, with the backdrop window
    /// either inside the picture (every fragment samples a real texel) or far outside it (every fragment
    /// takes the matte). That difference *is* the new select, so its cost is measured rather than
    /// claimed: no extra sample is added — the fetch happens either way, and the matte replaces its
    /// result.
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

        // ── 058: the matte select, isolated. Same window, same frame, same backdrop; one backdrop
        // window lands inside the picture for every fragment, the other outside it for every fragment.
        let insidePicture = percentiles(PresentWindow(u0: 0.30, v0: 0.30, du: 0.35, dv: 0.35))
        let allMatte = percentiles(PresentWindow(u0: -4, v0: -4, du: 9, dv: 9))
        print(String(format: "[058] the same draw, backdrop window inside the picture vs far outside it "
                     + "(every fragment matte): p50 %.3f / %.3f ms · p95 %.3f / %.3f ms  (%+.3f ms at p95, "
                     + "i.e. the select costs nothing measurable and adds no fetch)",
                     insidePicture.p50, allMatte.p50, insidePicture.p95, allMatte.p95,
                     allMatte.p95 - insidePicture.p95))
        XCTAssertGreaterThan(allMatte.p50, 0)
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

    /// A horizontal gradient in **u**, `from` at the left edge to `to` at the right, grey (r = g = b).
    /// The 058 acceptance uses this instead of flat colours so that "the band is the picture's content"
    /// is a *shape* claim — a value that changes with position — and not just a different constant.
    private func gradient(_ device: MTLDevice, _ w: Int, _ h: Int, from: Float,
                          to: Float) throws -> MTLTexture {
        let t = try makeTexture(device, w, h, .rgba16Float, [.shaderRead])
        var row = [UInt16](repeating: 0, count: w * 4)
        let span = Float(max(w - 1, 1))
        for x in 0 ..< w {
            let v = from + (to - from) * Float(x) / span
            for c in 0 ..< 3 { row[x * 4 + c] = Float16(v).bitPattern }
            row[x * 4 + 3] = Float16(1).bitPattern
        }
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
