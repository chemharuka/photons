import XCTest
import AppKit
import ImageIO
import Metal
import PhotonsCore
import PhotonsUI

/// 039 — wiring the low-resolution **whole picture** (037 ①) into `LoupeController`.
///
/// Three claims, and each of them is a failure the user would see:
///
///   1. **It is made once per dirty pointer entry, and at no other time.** 「这个低清预览只在画面有调整且
///      鼠标从调整区移开时才渲染，不会影响性能」 — a stop change, a pan and a zoom transition must not
///      generate one, and an edit must only *mark* it stale. The counter test below is the acceptance
///      test; the negative control (turning "a stop change generates" into the code) makes it red.
///   2. **A shrinking frame is drawn with it, a covering frame without it.** The engine feathers 2 px
///      of the backdrop into the frame's own edge, so handing a backdrop to a frame that reaches the
///      canvas would mix low resolution into the picture. The on-screen drawable cannot be read back,
///      so `backdropPresents` records the parameters of every present and both rules are asserted on it.
///   3. **With no backdrop nothing changes.** Before the first pointer entry — and for every frame of a
///      shrink that happens before one — every present carries `nil`, i.e. 025's edge extrapolation,
///      which `LoupeZoomShrinkCoverTests` still proves pixel by pixel ("0 个未渲染黑像素").
///
/// The size rule is pinned twice: as arithmetic here (the four cases from the task, plus the 1024 guard
/// rail) and on the texture a real render produced (a 4096-capped frame must not come out at 0.5×).
@MainActor
final class BackdropWiringTests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    private var windows: [NSWindow] = []

    /// Millisecond ceilings are asserted only under `PHOTONS_BENCH=1` (project rule): `swift test` builds
    /// Debug, where these numbers are not the shipping ones.
    private var benchmarks: Bool { ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" }

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

    /// The frame's own pixel size, straight out of the container — no decode. Only used to check the
    /// size *rule* against the file it was applied to.
    private func sourceSize(of url: URL) throws -> ImageSize {
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "no image source")
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any], "no properties")
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int, "no pixel width")
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int, "no pixel height")
        return ImageSize(width: width, height: height)
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

    /// The pointer leaves the canvas and comes back: **one** entry, the way the tracking area delivers
    /// it (`pointerExited` is the `mouseExited`, `pointerMoved` the `mouseEntered`/first `mouseMoved`).
    private func enter(_ controller: LoupeController, at point: CGPoint = CGPoint(x: 64, y: 140)) {
        controller.pointerExited()
        controller.pointerMoved(to: point)
    }

    /// Wait until no backdrop render is in flight, so a count read now is the settled answer.
    @discardableResult
    private func settleBackdrop(_ controller: LoupeController,
                                timeout: TimeInterval = 60) -> Bool {
        waitFor(timeout) { controller.backdrop.isIdle }
    }

    private func settleZoom(_ controller: LoupeController, zoom: Double) -> Bool {
        waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == zoom }
    }

    // MARK: - ① the size rule (037 ②, user 2026-10-27)

    func testPreviewSizeIsHalfTheOriginalCappedAt4096() {
        // The four cases the task names, plus the two ceilings' own edges.
        let cases: [(image: Int, expected: Int)] = [
            (6000, 3000),     // 24 MP, half is under the cap → 3000
            (9000, 4096),     // 54 MP → half is 4500, capped at 4096
            (15360, 4096),    // 16K → capped
            (24000, 4096),    // 100 MP → capped
            (3000, 1500),     // small file → half, no cap in play
            (8192, 4096),     // exactly the cap
            (8194, 4096),     // one past it
        ]
        for c in cases {
            XCTAssertEqual(BackdropScale.previewLongEdge(imageLongEdge: c.image), c.expected,
                           "previewLongEdge(\\(c.image))")
        }

        // The guard rail (added here, not by the user — a file below 2048 px must not turn into a
        // colour block behind the frame).
        XCTAssertEqual(BackdropScale.previewLongEdge(imageLongEdge: 2048), 1024)
        XCTAssertEqual(BackdropScale.previewLongEdge(imageLongEdge: 1200), 1024)
        XCTAssertEqual(BackdropScale.previewLongEdge(imageLongEdge: 8), 1024)

        // The scale is an arbitrary `Double`, **not** a rung: 9000 → 4096 is 0.4551…, and snapping it
        // to 0.5 (4500 px render) or 0.25 (2048 px) is the bug the task calls out.
        let capped = BackdropScale.renderScale(imageLongEdge: 9000, contentLongEdge: 9000)
        XCTAssertEqual(capped, 4096.0 / 9000.0, accuracy: 0)
        XCTAssertGreaterThan(abs(capped - 0.5), 1e-3, "the scale must not be snapped to a half")
        XCTAssertGreaterThan(abs(capped - 0.25), 1e-3, "nor to a quarter")

        // Half of a 6000 px frame is a 3000 px preview: at scale 1 for the whole-frame picture.
        XCTAssertEqual(BackdropScale.renderScale(imageLongEdge: 6000, contentLongEdge: 3000), 1.0,
                       accuracy: 0)
        // A crop is smaller than the frame it was cut from, so the ceilings still hold.
        XCTAssertEqual(BackdropScale.renderScale(imageLongEdge: 9000, contentLongEdge: 4500),
                       4096.0 / 4500.0, accuracy: 0)
    }

    // MARK: - ② one generation per dirty pointer entry

    func testOneGenerationPerDirtyPointerEntryAndNoneForAStopChange() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "backdrop-count")

        // A frame is not an entry: nothing has been generated for a picture that was only opened.
        XCTAssertEqual(controller.backdrop.generationCount, 0,
                       "opening a photo must not render a backdrop")
        var trace = ["opened=\(controller.backdrop.generationCount)"]

        // ── dirty (nothing has been made for this document) + the pointer enters → exactly one.
        enter(controller)
        XCTAssertTrue(settleBackdrop(controller), "the backdrop render never finished")
        XCTAssertEqual(controller.backdrop.generationCount, 1, "one entry, one generation")
        trace.append("dirty+enter=\(controller.backdrop.generationCount)")
        XCTAssertNotNil(controller.backdrop.texture)
        XCTAssertGreaterThan(controller.backdrop.lastGenerationMilliseconds, 0)
        let firstKey = try XCTUnwrap(controller.backdrop.key)

        // Moving *inside* the canvas is not another entry, however many events arrive.
        for i in 0 ..< 8 {
            controller.pointerMoved(to: CGPoint(x: 40 + i * 3, y: 60 + i))
        }
        XCTAssertTrue(settleBackdrop(controller))
        XCTAssertEqual(controller.backdrop.generationCount, 1,
                       "a pointer already on the canvas must not generate again")
        trace.append("+8 moves=\(controller.backdrop.generationCount)")

        // ── two stop changes (and a pan between them) generate nothing. This is the requirement in
        // the user's own words: 换档/拖滑杆/平移/缩放过渡一律不生成.
        controller.zoomToActualSize(aroundView: CGPoint(x: 100, y: 120))
        XCTAssertTrue(settleZoom(controller, zoom: 1))
        controller.zoom(to: 2, aroundView: CGPoint(x: 200, y: 160))
        XCTAssertTrue(settleZoom(controller, zoom: 2))
        // A pan at a fixed zoom: the camera moves, the document does not.
        controller.panImage(byPoints: CGSize(width: 24, height: -16))
        XCTAssertTrue(settleZoom(controller, zoom: 2))
        pump(0.1)
        XCTAssertEqual(controller.backdrop.generationCount, 1,
                       "a stop change or a pan must not render the backdrop")
        XCTAssertTrue(controller.zoomBridgeArmedCount >= 2, "the stop changes really ran")
        trace.append("2 stops+pan=\(controller.backdrop.generationCount)")

        // ── an edit only marks it stale…
        let source = try XCTUnwrap(controller.frameSource)
        var edited = source.edit
        edited.light.exposure = 0.6
        controller.frameSource = LoupeController.FrameSource(url: source.url, identity: source.identity,
                                                             viewport: source.viewport,
                                                             state: source.state, edit: edited)
        pump(0.05)
        XCTAssertEqual(controller.backdrop.generationCount, 1,
                       "an edit must mark the backdrop stale, not render it")
        XCTAssertEqual(controller.backdrop.key, firstKey)
        trace.append("after edit=\(controller.backdrop.generationCount)")

        // …and the next entry is the second generation.
        enter(controller, at: CGPoint(x: 120, y: 90))
        XCTAssertTrue(settleBackdrop(controller))
        XCTAssertEqual(controller.backdrop.generationCount, 2,
                       "a dirty document plus a pointer entry is one more generation")
        trace.append("dirty+enter=\(controller.backdrop.generationCount)")
        print("[039] generations: " + trace.joined(separator: " → "))
        XCTAssertNotEqual(controller.backdrop.key, firstKey,
                          "the new texture must belong to the edited document")
    }

    // MARK: - ③ what the present pass was given

    func testShrinkingFramesDrawTheBackdropAndCoveringFramesDoNot() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "backdrop-present")
        enter(controller)
        XCTAssertTrue(settleBackdrop(controller))
        XCTAssertEqual(controller.backdrop.generationCount, 1)
        let lowRes = try XCTUnwrap(controller.backdrop.size)

        // Settle at 200 %, then shrink to 100 % while the pointer is **not** on the canvas: nothing may
        // generate, and the transition is the only thing drawing.
        controller.zoomToActualSize(aroundView: CGPoint(x: 100, y: 120))
        XCTAssertTrue(settleZoom(controller, zoom: 1))
        controller.zoom(to: 2, aroundView: CGPoint(x: 100, y: 120))
        XCTAssertTrue(settleZoom(controller, zoom: 2))
        controller.pointerExited()
        pump(0.05)

        let armed = controller.zoomBridgeArmedCount
        let before = controller.backdropPresents.count
        controller.zoom(to: 1, aroundView: CGPoint(x: 64, y: 140))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil }, "the bridge never ended")
        XCTAssertTrue(settleZoom(controller, zoom: 1), "the frame at 100 % never landed")
        pump(0.1)
        XCTAssertEqual(controller.backdrop.generationCount, 1,
                       "running a transition must not generate a backdrop")

        // Every present since the transition started — the bridge's own frames and the real frame that
        // landed on top of them at the end.
        let presents = controller.backdropPresents.dropFirst(before)
        // How many frames a transition presents is the display's business (a release build drops most of
        // them and a Debug build on an idle machine keeps many), so this threshold only proves that a
        // transition really ran. The rule that matters is per frame, below.
        XCTAssertGreaterThanOrEqual(presents.filter { $0.serial > armed }.count, 3,
                                    "the bridge really presented a transition")

        var shrinking = 0, covering = 0
        for p in presents {
            // The record cannot lie about the geometry it was recorded with.
            XCTAssertEqual(p.coversCanvas, p.window.coversCanvas)
            if p.coversCanvas {
                covering += 1
                XCTAssertNil(p.backdrop,
                             "a frame that covers the canvas must not be given a backdrop "
                             + "(the 2 px feather would mix low resolution into the picture)")
            } else {
                shrinking += 1
                XCTAssertEqual(p.backdrop, lowRes,
                               "a shrinking frame must draw the whole picture behind itself")
            }
        }
        XCTAssertGreaterThan(shrinking, 0, "no shrinking frame was presented — the test proved nothing")
        XCTAssertGreaterThan(covering, 0,
                             "the settled frame at 100 % covers the canvas, and must have no backdrop")

        // The counters agree with the log.
        XCTAssertGreaterThan(controller.backdropDrawCount, 0)
        XCTAssertGreaterThan(controller.backdroplessDrawCount, 0)
        print("[039] presents: \(shrinking) shrinking → backdrop \(lowRes.width)×\(lowRes.height), "
              + "\(covering) covering → nil")
    }

    // MARK: - ④ no backdrop yet → 025's edge extrapolation, never a black band

    func testShrinkBeforeAnyPointerEntryPresentsWithoutABackdrop() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "backdrop-absent")
        XCTAssertNil(controller.backdrop.texture, "nothing generated without a pointer entry")

        controller.zoomToActualSize(aroundView: CGPoint(x: 100, y: 120))
        XCTAssertTrue(settleZoom(controller, zoom: 1))
        controller.zoom(to: 2, aroundView: CGPoint(x: 100, y: 120))
        XCTAssertTrue(settleZoom(controller, zoom: 2))
        let armed = controller.zoomBridgeArmedCount
        let before = controller.backdropPresents.count
        controller.zoom(to: 1, aroundView: CGPoint(x: 64, y: 140))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil })

        let frames = controller.backdropPresents.dropFirst(before).filter { $0.serial > armed }
        // Display-rate dependent, like every bridge frame count: it proves a transition ran, nothing more.
        XCTAssertGreaterThanOrEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0.backdrop == nil },
                      "with no backdrop every present must fall back to the edges")
        XCTAssertTrue(frames.contains { !$0.coversCanvas },
                      "the transition really did leave the canvas uncovered")
        // …and it did not quietly generate one on the way.
        XCTAssertEqual(controller.backdrop.generationCount, 0)
        // The pixel-level half of this claim is 025's own test (0 unrendered black pixels), which runs
        // on exactly this state: no pointer entry, no backdrop, a full shrink.
        XCTAssertNotNil(controller.lastFrame)
    }

    // MARK: - ⑤ the texture a real render produced (size, format, arbitrary scale)

    func testGeneratedTextureFollowsTheRuleForThisFile() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "backdrop-size")
        enter(controller)
        XCTAssertTrue(settleBackdrop(controller))
        let texture = try XCTUnwrap(controller.backdrop.texture)
        let size = try XCTUnwrap(controller.backdrop.size)

        XCTAssertEqual(texture.pixelFormat, .rgba16Float, "the backdrop is 16-bit float like a frame")

        let source = try sourceSize(of: url)
        let longEdge = max(size.width, size.height)
        let expected = BackdropScale.previewLongEdge(imageLongEdge: max(source.width, source.height))
        XCTAssertLessThanOrEqual(abs(longEdge - expected), 1,
                                 "rendered \(size.width)×\(size.height), expected a \(expected) px "
                                 + "long edge (min(image/2, 4096), floored at 1024)")
        XCTAssertLessThanOrEqual(longEdge, BackdropScale.maximumLongEdge)
        XCTAssertGreaterThanOrEqual(longEdge, BackdropScale.minimumLongEdge)

        // The picture's aspect survived: the backdrop is the **whole picture**, not a letterboxed
        // canvas (a canvas-shaped one would sit wrong behind a shrink from any stop).
        XCTAssertEqual(Double(size.width) / Double(size.height),
                       Double(source.width) / Double(source.height),
                       accuracy: 0.01, "the backdrop's aspect must be the picture's")

        // Any Double is legal, and this is the number the engine must not assume a rung for.
        let scale = Double(expected) / Double(max(source.width, source.height))
        print("[039] \(source.width)×\(source.height) → \(size.width)×\(size.height) "
              + "(scale \(scale))")
        if max(source.width, source.height) > 2 * BackdropScale.maximumLongEdge {
            XCTAssertLessThan(scale, 0.5, "a capped preview is a non-rung scale")
        }
        XCTAssertTrue(scale.isFinite && scale > 0)
    }

    // MARK: - ⑦ the digest-keyed read-only accessor (what 040's histogram reuses)

    /// The whole picture is a **read**: the histogram asks for it on every frame it measures, so a getter
    /// that could queue a render would be a render loop. This pins all three halves of the interface the
    /// parent asked for — the digest in the key, the accessor, and the explicit request that is the only
    /// other way in.
    func testAccessorIsReadOnlyKeyedByTheEditDigestAndTheRequestIsExplicit() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "backdrop-accessor")

        // Nothing yet, and asking does not make one.
        XCTAssertNil(controller.lowResFullFrame)
        for _ in 0 ..< 200 { _ = controller.lowResFullFrame }
        XCTAssertEqual(controller.backdrop.generationCount, 0,
                       "reading the accessor must never generate a backdrop")
        XCTAssertTrue(controller.backdrop.isIdle, "reading the accessor must not start a render")

        enter(controller)
        XCTAssertTrue(settleBackdrop(controller))
        let source = try XCTUnwrap(controller.frameSource)
        let first = try XCTUnwrap(controller.lowResFullFrame)
        XCTAssertTrue(first.texture === controller.backdrop.texture)
        XCTAssertEqual(first.digest, Histogram.editDigest(source.edit),
                       "the cache is keyed by the edit digest the histogram caches its own numbers by")
        XCTAssertEqual(first.develop, source.edit.decodeInputs.key, "and by the develop key")
        XCTAssertEqual(first.photo, source.identity)
        // `content` is the picture inside the texture: the whole of it, for a render with no canvas.
        XCTAssertEqual(first.content.width, first.texture.width)
        XCTAssertEqual(first.content.height, first.texture.height)

        // An edit moves the digest and **nothing else happens** — the texture on hand is the previous
        // document's, which is exactly what `digest` lets a consumer detect.
        var edited = source.edit
        edited.light.exposure = 0.75
        controller.frameSource = LoupeController.FrameSource(url: source.url, identity: source.identity,
                                                             viewport: source.viewport,
                                                             state: source.state, edit: edited)
        pump(0.05)
        let staleDigest = Histogram.editDigest(edited)
        XCTAssertNotEqual(staleDigest, first.digest, "the edit really moved the digest")
        for _ in 0 ..< 200 { _ = controller.lowResFullFrame }
        XCTAssertEqual(controller.backdrop.generationCount, 1, "a dirty document does not re-render on read")
        XCTAssertEqual(controller.lowResFullFrame?.digest, first.digest,
                       "the accessor reports the document it actually has, not the one on screen")

        // The explicit request: one generation, for the document asked for, and idempotent afterwards.
        XCTAssertTrue(controller.ensureLowResFullFrame(), "a dirty document is exactly what this is for")
        XCTAssertTrue(settleBackdrop(controller))
        XCTAssertEqual(controller.backdrop.generationCount, 2)
        XCTAssertEqual(controller.lowResFullFrame?.digest, staleDigest)
        XCTAssertFalse(controller.ensureLowResFullFrame(),
                       "the document on screen is already cached — no second render")
        XCTAssertTrue(settleBackdrop(controller))
        XCTAssertEqual(controller.backdrop.generationCount, 2)
        XCTAssertTrue(controller.backdrop.isIdle)
    }

    // MARK: - ⑦b the backdrop *is* the histogram's whole picture (039 × 045)

    /// 「低清全图一次渲染、两个用途」：缩小时的底图，和放大态测直方图要的整幅图，是**同一张**。
    ///
    /// 注入点必须只交出 digest 与所问文档一致的那张：交错的会得到一个“看起来更新了、数值却是上一版”的
    /// 直方图，那比不更新更糟。交不出就返回 nil，让 045 退回自己渲染（11–24 ms），绝不猜。
    func testTheHistogramSourceIsTheBackdropAndNothingElse() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "backdrop-histogram-source")
        let source = try XCTUnwrap(controller.fullPictureSource,
                                   "the histogram's injection point must be wired, not left nil")

        let current = try XCTUnwrap(controller.frameSource).edit
        XCTAssertNil(source(current), "no backdrop yet → nil, so 045 renders it itself")
        XCTAssertEqual(controller.backdrop.generationCount, 0,
                       "asking the source must not generate anything")

        enter(controller)
        XCTAssertTrue(settleBackdrop(controller))
        let handed = try XCTUnwrap(source(current), "the backdrop for this very document is handed over")
        XCTAssertTrue(handed.texture === controller.backdrop.texture,
                      "same texture, not a copy: one render serves both purposes")
        XCTAssertEqual(handed.digest, Histogram.editDigest(current))
        XCTAssertEqual(handed.content.width, handed.texture.width,
                       "a backdrop render has no canvas, so the picture is the whole texture")

        // Another edit: the texture on hand is the *previous* document's, so it must not be offered.
        var edited = current
        edited.light.exposure = 1.25
        XCTAssertNotEqual(Histogram.editDigest(edited), handed.digest)
        XCTAssertNil(source(edited), "a stale digest is never handed to the histogram")

        // The photo going away takes its picture (and the snapshot) with it.
        controller.cancelPendingFrames()
        pump(0.05)
        XCTAssertNil(source(current), "a cancelled photo's picture is not measurable any more")
    }

    // MARK: - ⑧ a different photo is a different picture

    /// 换图释放 (039 ④): the backdrop belongs to the photo it was rendered from. Switching photos must
    /// release it — and, until the next entry makes a new one, a shrinking frame must fall back to 025's
    /// edge extrapolation rather than show the **previous** photograph behind the new one.
    func testSwitchingPhotoReleasesTheBackdropAndNeverDrawsTheOldOne() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "backdrop-photo-a")
        enter(controller)
        XCTAssertTrue(settleBackdrop(controller))
        XCTAssertEqual(controller.backdrop.generationCount, 1)
        XCTAssertNotNil(controller.backdrop.texture)

        // Another photo: same file, a different photo identity — the half of the key the picture lives in.
        controller.frameSource = LoupeController.FrameSource(url: url, identity: "backdrop-photo-b",
                                                             viewport: Self.viewport, state: .fit)
        pump(0.05)
        XCTAssertNil(controller.backdrop.texture, "a photo switch releases the backdrop")
        XCTAssertNil(controller.lowResFullFrame)
        XCTAssertEqual(controller.backdrop.generationCount, 1, "and does not render a new one")

        // A shrink on the new photo: every frame of the transition must be drawn without a backdrop,
        // because the only one on hand belongs to the picture that just left.
        controller.zoomToActualSize(aroundView: CGPoint(x: 100, y: 120))
        XCTAssertTrue(settleZoom(controller, zoom: 1))
        controller.zoom(to: 2, aroundView: CGPoint(x: 100, y: 120))
        XCTAssertTrue(settleZoom(controller, zoom: 2))
        let armed = controller.zoomBridgeArmedCount
        let before = controller.backdropPresents.count
        controller.zoom(to: 1, aroundView: CGPoint(x: 64, y: 140))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil })

        let frames = controller.backdropPresents.dropFirst(before).filter { $0.serial > armed }
        XCTAssertGreaterThanOrEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0.backdrop == nil },
                      "the previous photo's backdrop must never be drawn behind the new one")
        XCTAssertTrue(frames.contains { !$0.coversCanvas })
        XCTAssertEqual(controller.backdrop.generationCount, 1, "a transition still generates nothing")
    }

    // MARK: - ⑥ cost (PHOTONS_BENCH=1)

    func testGenerationCostStaysInsideTheBudget() throws {
        guard benchmarks else { throw XCTSkip("PHOTONS_BENCH=1 only") }
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "backdrop-bench")
        enter(controller)
        XCTAssertTrue(settleBackdrop(controller))
        let size = try XCTUnwrap(controller.backdrop.size)
        let milliseconds = controller.backdrop.lastGenerationMilliseconds
        print("[039] backdrop \(size.width)×\(size.height) rendered in "
              + String(format: "%.1f", milliseconds) + " ms")
        XCTAssertLessThanOrEqual(milliseconds, 120,
                                 "one generation must stay inside the 120 ms budget")
    }
}
