import XCTest
import AppKit
import ImageIO
import Metal
import PhotonsCore
import PhotonsUI

/// 065 — 放大状态切换照片时，底图（以及桥接帧）还是上一张的。
///
/// The user's report is one sentence: 「如果在放大视图切换照片，此时的背景用的低清渲染图还是上一张的。
/// 所以切换照片时必须重新走流程」. 039 already released the **texture** on a photo switch
/// (`frameSource.didSet` → `backdrop.invalidate()`), and that is what its own test covers — but only
/// while the loupe is *standing still at fit*. Zoomed in, two more things are holding the old picture:
///
///   · **H1 — the bridge.** A running stop change owns the frame texture on the canvas, presents it
///     every display frame, and is holding the next frame to hand over. Nothing ended it on a switch,
///     so A kept being composited at whatever scale the eye was at, and `finishZoomBridge` presented
///     the frame it had been holding — A, drawn after the switch.
///   · **H2 — the generation gate.** The backdrop renders through the **frame** graph, and that graph
///     only becomes B's when B's first frame is rendered. A request that outlived its photo therefore
///     rendered A's decoded pixels through B's edit and adopted the result under **B's key** — a
///     backdrop that says B and is A's picture. That is the sentence above, literally, and no key or
///     field can see it: the key is right.
///
/// So every assertion here is on **identity** (`ObjectIdentifier` / `===`), never on a key, a size or a
/// field: `BackdropPresent` records the backdrop's texture identity and `ZoomBridgeFrame` records the
/// texture the bridge sampled.
///
///  1. from the first present after the switch, the backdrop is `nil` or **B's** texture; A's identity
///     never appears again;
///  2. the bridge is over at the instant of the switch (`zoomBridge == nil`) and presents no further
///     frame from A's texture;
///  3. the pointer entry after the switch generates **B's** bottom image — one generation, `key.photo`
///     is B, and the texture is a different object from A's;
///  4. the histogram's whole-picture snapshot is empty the instant the photo changes, until B's own
///     backdrop exists (its digest covers only the `EditModel`, so an untouched document keeps the
///     same digest across a photo switch — the digest alone can never catch this);
///  5. the same for the frame-present path, not just the still frame.
@MainActor
final class BackdropSwitchAtZoomTests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    private static let photoA = "switch-at-zoom-a"
    private static let photoB = "switch-at-zoom-b"
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

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

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func makeController(url: URL, identity: String,
                                edit: EditModel = .neutral) -> LoupeController {
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
                                                             viewport: Self.viewport,
                                                             state: .fit, edit: edit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        pump(0.1)
        return controller
    }

    /// The pointer leaves the canvas and comes back: **one** entry, the way the tracking area delivers
    /// it (`pointerExited` is the `mouseExited`, `pointerMoved` the `mouseEntered`/first `mouseMoved`).
    private func enter(_ controller: LoupeController, at point: CGPoint = CGPoint(x: 64, y: 140)) {
        controller.pointerExited()
        controller.pointerMoved(to: point)
    }

    @discardableResult
    private func settleBackdrop(_ controller: LoupeController,
                               timeout: TimeInterval = 60) -> Bool {
        waitFor(timeout) { controller.backdrop.isIdle }
    }

    private func settleZoom(_ controller: LoupeController, zoom: Double) -> Bool {
        waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == zoom }
    }

    /// B is the same file under another photo identity — the half of the key the picture lives in. The
    /// camera and the document are carried over so the only thing that changed is the photo.
    private func switchToB(_ controller: LoupeController, url: URL) throws -> LoupeController.FrameSource {
        let previous = try XCTUnwrap(controller.frameSource)
        let next = LoupeController.FrameSource(url: url, identity: Self.photoB,
                                               viewport: previous.viewport,
                                               state: previous.state, edit: previous.edit)
        controller.frameSource = next
        return next
    }

    private func identity(_ texture: MTLTexture?) -> ObjectIdentifier? {
        texture.map { ObjectIdentifier($0) }
    }

    // MARK: - ①② the switch while a zoom bridge is running

    /// The user's own sequence: zoomed in, zooming back out (the bridge is running and the low-res
    /// picture is being drawn behind the shrinking frame), then the next photo.
    func testSwitchingPhotoWithTheBridgeRunningEndsItAndNeverPresentsTheOldOne() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: Self.photoA)

        // ── A's bottom image, then the camera at 100 %.
        enter(controller)
        XCTAssertTrue(settleBackdrop(controller), "A's backdrop never landed")
        let aBackdrop = try XCTUnwrap(controller.backdrop.texture)
        let aBackdropID = ObjectIdentifier(aBackdrop)
        XCTAssertEqual(controller.backdrop.key?.photo, Self.photoA)

        controller.zoomToActualSize(aroundView: CGPoint(x: 100, y: 120))
        XCTAssertTrue(settleZoom(controller, zoom: 1))
        let aFrameID = ObjectIdentifier(try XCTUnwrap(controller.lastFrame?.texture))

        // ── 100 % → fit: the bridge is armed, it carries A's frame texture, and as the picture shrinks
        // into the canvas the pass is handed A's backdrop. **This** is the moment the user switches.
        let presentsBeforeFit = controller.backdropPresents.count
        controller.zoomToFit()
        pump(0.06)
        let bridgeFramesAtSwitch = controller.zoomBridgeFrames.count
        let presentsAtSwitch = controller.backdropPresents.count
        let armedAtSwitch = controller.zoomBridgeArmedCount
        XCTAssertTrue(controller.zoomBridgeFrames.contains { $0.source == aFrameID },
                      "the bridge must be sampling A's frame texture")
        XCTAssertTrue(controller.backdropPresents.dropFirst(presentsBeforeFit)
                        .contains { $0.backdropIdentity == aBackdropID },
                      "the shrink really drew A's backdrop — otherwise this test proves nothing")
        XCTAssertNotNil(controller.zoomBridge, "the switch must happen while the bridge is running")

        // ── the switch, mid-bridge (H1).
        _ = try switchToB(controller, url: url)
        XCTAssertNil(controller.zoomBridge, "a photo switch ends the zoom bridge")
        XCTAssertEqual(controller.zoomBridgeArmedCount, armedAtSwitch, "and must not arm a new one")

        controller.scheduleRender()
        XCTAssertTrue(waitFor(60) { identity(controller.lastFrame?.texture) != aFrameID },
                      "the new photo's first frame never landed")
        pump(0.15)

        // ② no bridge frame after the switch came from A's texture (and none was presented at all).
        let lateBridgeFrames = controller.zoomBridgeFrames.dropFirst(bridgeFramesAtSwitch)
        XCTAssertEqual(lateBridgeFrames.filter { $0.source == aFrameID }.count, 0,
                       "a bridge frame after the switch still sampled A's texture")

        // ① every present after the switch: the backdrop is nil or B's, and no present carried a
        // bridge serial — the composite is not A's any more, from the first frame that landed.
        let after = Array(controller.backdropPresents.dropFirst(presentsAtSwitch))
        XCTAssertGreaterThanOrEqual(after.count, 1, "no present after the switch: nothing was proved")
        XCTAssertEqual(after.filter { $0.backdropIdentity == aBackdropID }.count, 0,
                       "A's backdrop was drawn after the switch to B")
        XCTAssertTrue(after.allSatisfy { $0.backdropIdentity == nil || $0.backdropIdentity != aBackdropID },
                      "every backdrop after the switch is nil or B's")
        XCTAssertTrue(after.allSatisfy { $0.serial == 0 },
                      "a present after the switch still belonged to the bridge that was running")
        XCTAssertNotEqual(identity(controller.lastFrame?.texture), aFrameID,
                          "the canvas is still showing A's frame texture")

        print("[065] switch mid-bridge: bridge frames after the switch = \(lateBridgeFrames.count), "
              + "presents after = \(after.count) "
              + "(with A's backdrop: \(after.filter { $0.backdropIdentity == aBackdropID }.count)), "
              + "backdrops nil/B = \(after.map { $0.backdropIdentity == nil ? "nil" : "B" })")
    }

    // MARK: - ③④ the regeneration, and the gate that must not render A's pixels as B's

    /// The pointer comes back to the canvas **before** the new photo's first frame, which is the window
    /// in which the render graph is still A's decoded image. The gate must refuse, and the request must
    /// be re-armed once B's own graph exists — the flow re-runs, once, for the new photo.
    func testThePointerEntryAfterTheSwitchGeneratesTheNewPhotosBottomImage() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: Self.photoA)

        enter(controller)
        XCTAssertTrue(settleBackdrop(controller))
        let aBackdrop = try XCTUnwrap(controller.backdrop.texture)
        XCTAssertEqual(controller.backdrop.generationCount, 1)
        XCTAssertEqual(controller.backdrop.key?.photo, Self.photoA)

        controller.zoomToActualSize(aroundView: CGPoint(x: 100, y: 120))
        XCTAssertTrue(settleZoom(controller, zoom: 1))
        let aFrameID = ObjectIdentifier(try XCTUnwrap(controller.lastFrame?.texture))

        // The histogram's whole picture for a zoomed frame *is* the backdrop (045 × 039).
        let source = try XCTUnwrap(controller.fullPictureSource,
                                   "the histogram's injection point must be wired")
        let edit = try XCTUnwrap(controller.frameSource).edit
        XCTAssertNotNil(source(edit), "A's picture is measurable while A is on screen")

        // ── the switch: the snapshot goes with the photo, before anything has re-rendered.
        _ = try switchToB(controller, url: url)
        XCTAssertNil(controller.lowResFullFrame, "A's bottom image is released with A")
        XCTAssertNil(controller.backdrop.texture)
        XCTAssertNil(source(edit), "A's picture must not be measurable as B's — the digest is the same")

        // ── the entry lands before B's first frame: the graph is still A's.
        enter(controller)
        controller.scheduleRender()
        XCTAssertTrue(waitFor(60) { identity(controller.lastFrame?.texture) != aFrameID },
                      "the new photo's first frame never landed")
        XCTAssertTrue(settleBackdrop(controller), "the regenerated backdrop never finished")

        // ③ B's own bottom image, rendered from B's own decode — one generation, not A's texture.
        XCTAssertEqual(controller.backdrop.generationCount, 2,
                       "the switch must re-run the flow exactly once")
        XCTAssertEqual(controller.backdrop.key?.photo, Self.photoB)
        let bBackdrop = try XCTUnwrap(controller.backdrop.texture)
        XCTAssertFalse(bBackdrop === aBackdrop,
                       "the backdrop was reused instead of re-rendered")
        XCTAssertEqual(controller.lastBackdropRenderedPhoto, Self.photoB,
                       "the adopted generation did not render B's pixels")
        XCTAssertEqual(controller.backdropStaleGraphRefusals, 1,
                       "the entry made before B's first frame must be refused, not rendered from A's graph")

        // ④ and only now is B's picture the histogram's whole picture.
        XCTAssertTrue(controller.fullPictureSource?(edit)?.texture === bBackdrop,
                      "B's backdrop is what the histogram may measure")

        print("[065] after the switch: generationCount = \(controller.backdrop.generationCount), "
              + "key.photo = \(controller.backdrop.key?.photo ?? "nil"), "
              + "renderedPhoto = \(controller.lastBackdropRenderedPhoto ?? "nil"), "
              + "staleGraphRefusals = \(controller.backdropStaleGraphRefusals), "
              + "same texture as A = \(bBackdrop === aBackdrop)")
    }

    // MARK: - ⑤⑥ the open itself: the bottom image is made without a pointer, and it is the new photo's

    /// 「低清照片渲染在切换/打开照片的一瞬间就要完成并且换进来，否则切换照片后低清渲染还是旧的」.
    ///
    /// The old gate was *document dirty **and** pointer enters the canvas* (039), which is why an opened
    /// photo could go without a bottom image until the mouse happened to move — and why switching photos
    /// left the previous one's. The rule now: an open or a switch asks for it at once, the request is
    /// served by the photo's **first frame** (so nothing is queued in front of the picture), and a second
    /// switch makes the first generation nobody's (`isCurrent`), adopting nothing and rendering nothing.
    ///
    /// The judgement here is by **pixel**, on purpose: two photos whose documents differ by 6 EV are a
    /// blue-black and a grey, so "which picture is behind the frame" cannot be answered by a key, a size
    /// or a field. And the pointer never moves in this test — not once.
    func testTheBottomImageOfTheNewPhotoArrivesWithoutAPointerMoveAndIsItsOwnPixels() throws {
        let url = try rawFixture()
        // A is six stops down: its low-resolution picture is nearly black, B's is not.
        var dark = EditModel.neutral
        dark.light.exposure = -6
        let controller = makeController(url: url, identity: Self.photoA, edit: dark)

        // ── no pointer, no canvas entry: the photo was *opened*, so its bottom image is on its way.
        XCTAssertNil(controller.pointerCanvasPoint, "no pointer in this test")
        XCTAssertTrue(waitFor(60) { controller.backdrop.texture != nil },
                      "opening a photo must make its bottom image without waiting for the pointer")
        XCTAssertEqual(controller.backdrop.generationCount, 1, "exactly once per open")
        XCTAssertEqual(controller.backdrop.key?.photo, Self.photoA)
        let aBackdrop = try XCTUnwrap(controller.backdrop.texture)
        let aID = ObjectIdentifier(aBackdrop)
        let aMean = try XCTUnwrap(meanLuma(aBackdrop))
        XCTAssertEqual(controller.lastBackdropRenderedPhoto, Self.photoA)

        // ── the switch, again with no pointer anywhere near the canvas.
        let previous = try XCTUnwrap(controller.frameSource)
        let t0 = CFAbsoluteTimeGetCurrent()
        controller.frameSource = LoupeController.FrameSource(url: url, identity: Self.photoB,
                                                             viewport: previous.viewport,
                                                             state: previous.state,
                                                             edit: .neutral)
        let switchCallMilliseconds = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        XCTAssertNil(controller.backdrop.texture, "A's picture is released at the switch")
        // What the app's model observer does on a photo change; the switch itself only cancels.
        controller.scheduleRender()

        XCTAssertTrue(waitFor(60) { identity(controller.lastFrame?.texture) != nil
                        && controller.backdrop.texture != nil && controller.backdrop.key?.photo == Self.photoB },
                      "the new photo's first frame and bottom image never landed")
        XCTAssertTrue(settleBackdrop(controller))

        // ⑤ the two numbers, and no synchronous generation: the switch call returned at once, the frame
        // came first, and the bottom image came after it.
        let toFirstFrame = controller.lastPhotoSwitchFirstFrameMilliseconds
        let toBackdrop = controller.lastPhotoSwitchBackdropMilliseconds
        XCTAssertLessThan(switchCallMilliseconds, 50,
                          "switching must not render synchronously (\(switchCallMilliseconds) ms)")
        XCTAssertGreaterThan(toFirstFrame, 0, "the first frame after the switch was not timed")
        XCTAssertGreaterThan(toBackdrop, 0, "the bottom image after the switch was not timed")
        XCTAssertGreaterThan(toBackdrop, toFirstFrame,
                             "the bottom image must be made *after* the frame, never instead of it")

        // ③ the key is still (photo, develop, digest), and the texture is a new render of B.
        let bBackdrop = try XCTUnwrap(controller.backdrop.texture)
        let bID = ObjectIdentifier(bBackdrop)
        XCTAssertNotEqual(bID, aID, "the backdrop was not re-rendered")
        XCTAssertEqual(controller.backdrop.key?.photo, Self.photoB)
        XCTAssertEqual(controller.backdrop.key?.digest, Histogram.editDigest(.neutral))
        XCTAssertEqual(controller.lastBackdropRenderedPhoto, Self.photoB)

        // ④ pixel level: B's bottom image is B's picture, not A's — six stops apart.
        let bMean = try XCTUnwrap(meanLuma(bBackdrop))
        XCTAssertGreaterThan(bMean - aMean, 0.02,
                             "the new photo's bottom image is indistinguishable from the old one "
                             + String(format: "(A mean %.4f, B mean %.4f)", aMean, bMean))

        // ── 缩小, still without touching the pointer: what the canvas is handed outside the frame must
        // be **B's** texture, and it is non-covering (so it is really drawn in the letterbox).
        controller.zoomToActualSize(aroundView: CGPoint(x: 100, y: 120))
        XCTAssertTrue(settleZoom(controller, zoom: 1))
        let beforeFit = controller.backdropPresents.count
        controller.zoomToFit()
        XCTAssertTrue(waitFor { controller.zoomBridge == nil })
        let shrink = Array(controller.backdropPresents.dropFirst(beforeFit))
        let withBackdrop = shrink.filter { !$0.coversCanvas }
        XCTAssertGreaterThanOrEqual(withBackdrop.count, 1,
                                    "the shrink never drew a backdrop: nothing was proved")
        XCTAssertEqual(withBackdrop.filter { $0.backdropIdentity == aID }.count, 0,
                       "A's picture was drawn outside the frame of B")
        XCTAssertTrue(withBackdrop.allSatisfy { $0.backdropIdentity == bID },
                      "the letterbox after the switch is not the new photo's bottom image")
        XCTAssertNil(controller.pointerCanvasPoint, "the pointer never moved in this test")

        print("[065b] switch → first frame " + String(format: "%.1f ms", toFirstFrame)
              + ", switch → bottom image " + String(format: "%.1f ms", toBackdrop)
              + ", the bottom render itself " + String(format: "%.1f ms", controller.backdrop.lastGenerationMilliseconds)
              + ", switch call " + String(format: "%.2f ms", switchCallMilliseconds)
              + String(format: ", luma A %.4f / B %.4f", aMean, bMean)
              + ", backdrop \(bBackdrop.width)×\(bBackdrop.height)"
              + String(format: " (%.1f MB)", Double(bBackdrop.width * bBackdrop.height * 8) / 1_048_576)
              + ", shrink presents with B's backdrop \(withBackdrop.filter { $0.backdropIdentity == bID }.count)"
              + " of \(shrink.count)")
    }

    // MARK: - a second switch makes the first generation nobody's

    /// 「再一次换图就把上一次的生成作废（不许两个照片的生成互相排队）」.
    ///
    /// Two switches in a row, faster than one decode: the middle photo's first frame never lands, so its
    /// bottom image is never even asked for — one request per photo that actually reached the canvas
    /// (`backdrop.requests`), and nothing of the middle photo is adopted (`generationCount`).
    func testASecondSwitchMakesTheFirstGenerationNobodys() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: Self.photoA)
        XCTAssertTrue(waitFor { controller.backdrop.texture != nil }, "the open's bottom image")
        XCTAssertEqual(controller.backdrop.requests, 1)

        let source = try XCTUnwrap(controller.frameSource)
        controller.frameSource = LoupeController.FrameSource(url: url, identity: Self.photoB,
                                                             viewport: source.viewport, state: .fit,
                                                             edit: source.edit)
        controller.scheduleRender()          // B's frame starts decoding; it will not land in time
        controller.frameSource = LoupeController.FrameSource(url: url, identity: "switch-at-zoom-c",
                                                             viewport: source.viewport, state: .fit,
                                                             edit: source.edit)
        controller.scheduleRender()

        XCTAssertTrue(waitFor(120) { controller.backdrop.texture != nil
                        && controller.backdrop.key?.photo == "switch-at-zoom-c" },
                      "the last photo never got its bottom image")
        XCTAssertTrue(settleBackdrop(controller))
        XCTAssertEqual(controller.backdrop.requests, 2,
                       "the photo that was switched away from must never have asked for a render")
        XCTAssertEqual(controller.backdrop.generationCount, 2,
                       "only the photos that reached the canvas generated one")
        XCTAssertEqual(controller.lastBackdropRenderedPhoto, "switch-at-zoom-c")
    }

    /// Mean linear luma of the centre of a backdrop texture, read straight out of the GPU resource: the
    /// canvas samples this exact object, so its pixels are the evidence that the *right* picture is behind
    /// the frame.
    private func meanLuma(_ texture: MTLTexture) -> Double? {
        guard texture.pixelFormat == .rgba16Float else { return nil }
        let w = min(256, texture.width), h = min(256, texture.height)
        guard w > 0, h > 0 else { return nil }
        let x = max(0, (texture.width - w) / 2), y = max(0, (texture.height - h) / 2)
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: w * 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0)
        }
        var sum = 0.0
        for i in stride(from: 0, to: raw.count, by: 4) {
            let r = Double(Float16(bitPattern: raw[i]))
            let g = Double(Float16(bitPattern: raw[i + 1]))
            let b = Double(Float16(bitPattern: raw[i + 2]))
            guard r.isFinite, g.isFinite, b.isFinite else { continue }
            sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return sum / Double(w * h)
    }
}
