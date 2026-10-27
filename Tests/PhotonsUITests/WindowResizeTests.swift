import XCTest
import AppKit
import QuartzCore
import Metal
import PhotonsCore
import PhotonsUI

/// 067 — **a window drag renders nothing.** Not "coalesces to one", not "debounces": zero.
///
/// The user's report: 「放大状态下反复拖窗口边界是因为拖拽的每一帧都会触发一次渲染请求，所以直接卡死」.
/// The numbers behind it are the reason the fix has to be structural — a 60 MP frame costs tens of
/// milliseconds, a drag delivers a layout pass every ~8 ms, and every one of those frames was presented
/// with `nextDrawable()` **on the main thread**. So the drag produced a backlog of renders nobody would
/// ever see, and the window stopped responding while it drained.
///
/// What the drag does instead: the picture already on the canvas is re-drawn **with the geometry it was
/// drawn with** — cropped when the window shrinks, the low-resolution backdrop in the area a grown
/// window exposes — and exactly one render is requested when the hand lets go.
///
/// Three acceptance numbers, all read from counters rather than from watching the picture:
///
///   · twelve layout passes inside a drag → `resizeRequests` **0**, `liveResizeRenderRequests` 0;
///   · the frozen presents keep the picture's pixel geometry (`pictureQuad` unchanged) while the
///     drawable follows the viewport — that is "no stretch", the 「变扁」 check;
///   · the release → exactly one request and one start, and the frame that arrives was rendered for
///     the canvas that is on screen.
///
/// `disableResizeCoalescing` reproduces the pre-067 shape (every layout pass renders), so the first
/// assertion is shown to go red for the reason it names rather than being a number that happens to hold.
@MainActor
final class WindowResizeTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
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

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitFor(_ timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    /// A controller showing `url` at the canvas the window currently is, exactly as the app does: the
    /// frame source's viewport **is** the viewport, so a resize is a new canvas for the next render.
    private func makeController(url: URL, size: CGSize) -> (LoupeController, NSWindow) {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        controller.frameSource = LoupeController.FrameSource(url: url, identity: "resize-067",
                                                             viewport: controller.viewportPixels,
                                                             state: .fit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        return (controller, window)
    }

    /// Resize the window and let AppKit run one layout pass, keeping the frame source's viewport in
    /// step with it — the model of the app, where the job's canvas is read from the viewport.
    private func resize(_ controller: LoupeController, _ window: NSWindow, to size: CGSize) {
        window.setContentSize(size)
        controller.view.layoutSubtreeIfNeeded()
        if var source = controller.frameSource {
            source = LoupeController.FrameSource(url: source.url, identity: source.identity,
                                                 viewport: controller.viewportPixels,
                                                 state: source.state, edit: source.edit)
            controller.frameSource = source
        }
        pump(0.004)
    }

    // MARK: - ① no render while the hand is moving

    func testALiveResizeAsksForNothingAndOneRenderAtTheEnd() throws {
        let url = try fixture()
        let (controller, window) = makeController(url: url, size: CGSize(width: 160, height: 100))
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        pump(0.1)
        let firstQuad = try XCTUnwrap(controller.lastPresented?.pictureQuad,
                                      "the first frame was never presented")

        let requestsBefore = controller.resizeRequests
        let startsBefore = controller.resizeRenderStarts
        let presentsBefore = controller.presentRecords.count
        let zoom = try XCTUnwrap(controller.lastFrame?.zoom)

        controller.beginLiveResize()
        XCTAssertTrue(controller.isLiveResizing)

        // Twelve layout passes — the shape of one drag, taken at the sizes a hand produces (up, down,
        // and back again, so the last size is not simply the largest).
        let sizes: [CGSize] = [CGSize(width: 170, height: 100), CGSize(width: 185, height: 108),
                               CGSize(width: 200, height: 120), CGSize(width: 220, height: 130),
                               CGSize(width: 205, height: 122), CGSize(width: 190, height: 115),
                               CGSize(width: 176, height: 106), CGSize(width: 164, height: 101),
                               CGSize(width: 180, height: 112), CGSize(width: 196, height: 124),
                               CGSize(width: 210, height: 132), CGSize(width: 230, height: 140)]
        for size in sizes { resize(controller, window, to: size) }
        pump(0.05)

        // The number the user's freeze is: **zero requests** during the drag.
        XCTAssertEqual(controller.resizeRequests - requestsBefore, 0,
                       "\(controller.resizeRequests - requestsBefore) render requests inside a live "
                       + "resize — this is the drag that freezes the window")
        XCTAssertEqual(controller.liveResizeRenderRequests, 0,
                       "a request reached the render queue during the drag")
        XCTAssertEqual(controller.resizeRenderStarts - startsBefore, 0,
                       "a render started during the drag")
        XCTAssertGreaterThanOrEqual(controller.liveResizeLayouts, 12,
                                    "the drag produced fewer layout passes than expected — the fixture "
                                    + "never exercised the freeze")

        // …and it still drew: one frozen present per pass, at the picture's own geometry.
        let frozen = controller.presentRecords.dropFirst(presentsBefore).filter(\.frozen)
        XCTAssertGreaterThanOrEqual(frozen.count, 12, "the drag presented nothing — the canvas would be stale")
        for record in frozen {
            XCTAssertEqual(record.pictureQuad, firstQuad,
                           "a frozen present moved the photograph (\(record.pictureQuad) vs "
                           + "\(firstQuad)) — a window drag must not rescale the picture")
            XCTAssertEqual(record.zoom, zoom, accuracy: 1e-9, "a frozen present changed the zoom")
        }
        // The drawable did follow the viewport, or the layer itself would be stale.
        let drawables = Set(frozen.map(\.drawable))
        XCTAssertGreaterThan(drawables.count, 2, "the frozen presents never changed canvas size")
        XCTAssertEqual(frozen.last?.drawable, controller.viewportPixels,
                       "the last frozen present's drawable is not the canvas on screen")

        // ③ the release: exactly one request, exactly one render, for the canvas that is here now.
        controller.endLiveResize()
        XCTAssertFalse(controller.isLiveResizing)
        XCTAssertEqual(controller.resizeRequests - requestsBefore, 1,
                       "the release must ask for exactly one frame, not \(controller.resizeRequests - requestsBefore)")
        XCTAssertTrue(waitFor { controller.lastPresented?.frozen == false
            && controller.lastPresented?.drawable == controller.viewportPixels },
                      "no frame for the released canvas")
        let settled = try XCTUnwrap(controller.lastPresented)
        XCTAssertEqual(settled.drawable, controller.viewportPixels)
        XCTAssertEqual(settled.frameCanvas, controller.viewportPixels,
                       "the frame that landed was rendered for another canvas — the 「变扁」 condition")
        XCTAssertEqual(controller.resizeRenderStarts - startsBefore, 1,
                       "the release rendered \(controller.resizeRenderStarts - startsBefore) times")

        print("[067] live drag: \(sizes.count) layout passes → \(controller.resizeRequests - requestsBefore) "
              + "render requests (0 during, 1 on release), \(controller.liveResizeLayouts) frozen presents, "
              + "\(drawables.count) canvas sizes, quad \(firstQuad.keyString) → \(settled.pictureQuad.keyString)")
    }

    // MARK: - the counter-proof

    /// The same twelve passes with the freeze switched off — i.e. the pre-067 shape, one render per
    /// layout pass. The assertion above (`requests == 0`) is exactly the one that goes red here, and the
    /// request count that replaces it is the storm the user felt.
    func testWithoutTheFreezeEveryLayoutPassAsksForAFrame() throws {
        let url = try fixture()
        let (controller, window) = makeController(url: url, size: CGSize(width: 160, height: 100))
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        pump(0.1)

        controller.disableResizeCoalescing = true
        controller.beginLiveResize()
        let before = controller.resizeRequests
        let sizes: [CGSize] = [CGSize(width: 170, height: 100), CGSize(width: 185, height: 108),
                               CGSize(width: 200, height: 120), CGSize(width: 220, height: 130),
                               CGSize(width: 205, height: 122), CGSize(width: 190, height: 115),
                               CGSize(width: 176, height: 106), CGSize(width: 164, height: 101),
                               CGSize(width: 180, height: 112), CGSize(width: 196, height: 124),
                               CGSize(width: 210, height: 132), CGSize(width: 230, height: 140)]
        for size in sizes { resize(controller, window, to: size) }
        pump(0.05)
        let during = controller.resizeRequests - before
        controller.endLiveResize()
        pump(0.05)

        XCTAssertGreaterThanOrEqual(during, sizes.count,
                                    "the counter-proof asked for \(during) frames for \(sizes.count) "
                                    + "layout passes; it is supposed to reproduce the per-pass storm")
        print("[067] counter-proof (freeze disabled): \(sizes.count) layout passes → \(during) render "
              + "requests — the pre-067 shape, and the reason the drag froze")
    }

    // MARK: - the stale canvas is still dropped

    /// 066's rule survives the refactor (it is not made redundant by quads: the quads are **pixel**
    /// rectangles of the canvas the frame was rendered for, so an old-canvas frame in a new drawable is
    /// the photograph at another aspect either way). A frame that arrives for a canvas that has moved is
    /// refused, and a frame for the canvas that is here is asked for — once.
    func testAFrameForAStaleCanvasIsNeverDrawn() throws {
        let url = try fixture()
        let (controller, window) = makeController(url: url, size: CGSize(width: 160, height: 100))
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        pump(0.1)
        let presentsBefore = controller.presentRecords.count

        // A programmatic resize (no live drag): the canvas moves, a frame for the old one may be in
        // flight, and the shape that produced 「变扁」 is a present of it into the new drawable.
        resize(controller, window, to: CGSize(width: 240, height: 130))
        XCTAssertTrue(waitFor { controller.lastPresented?.drawable == controller.viewportPixels
            && controller.lastPresented?.frozen == false }, "no frame for the new canvas")

        let settled = controller.presentRecords.dropFirst(presentsBefore).filter { !$0.frozen }
        XCTAssertFalse(settled.isEmpty, "nothing was presented after the resize")
        for record in settled {
            XCTAssertEqual(record.drawable, record.frameCanvas,
                           "a frame rendered for \(record.frameCanvas.keyString) was drawn into a "
                           + "\(record.drawable.keyString) drawable — the photograph would be stretched")
        }
        print("[067] programmatic resize: \(settled.count) settled presents, every drawable == its "
              + "frame's canvas; \(controller.canvasMismatchDrops) frames refused, "
              + "\(controller.staleCanvasDrops) dropped before rendering")
    }

    /// The counter-proof for the rule above: with the guard off, the same resize presents the old-canvas
    /// frame as if it filled the new drawable — `drawable != frameCanvas`, which is the 「变扁」 condition
    /// the assertion in the test above forbids.
    func testWithoutTheGuardAFrameForTheOldCanvasIsDrawnStretched() throws {
        let url = try fixture()
        let (controller, window) = makeController(url: url, size: CGSize(width: 160, height: 100))
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        pump(0.1)
        let presentsBefore = controller.presentRecords.count

        controller.forceStaleCanvasPresent = true
        resize(controller, window, to: CGSize(width: 240, height: 130))
        XCTAssertTrue(waitFor { controller.lastPresented?.drawable == controller.viewportPixels },
                      "no frame after the resize")
        pump(0.05)

        let stretched = controller.presentRecords.dropFirst(presentsBefore).filter {
            !$0.frozen && $0.drawable != $0.frameCanvas
        }
        XCTAssertFalse(stretched.isEmpty,
                       "the counter-proof never drew a stale frame full-bleed — the guard's assertion "
                       + "would go red for no reason")
        print("[067] counter-proof (guard off): \(stretched.count) presents drew a "
              + "\(stretched[0].frameCanvas.keyString) frame into a \(stretched[0].drawable.keyString) "
              + "drawable — the photograph at another aspect, the 「变扁」 this forbids")
    }
}
