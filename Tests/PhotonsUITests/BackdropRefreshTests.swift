import XCTest
import AppKit
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 144 — the low-resolution whole picture must follow the frame that actually settled.
///
/// Since 143b a white-balance drag is a **real render**: the canvas shows the target pair while the
/// document still holds the released one. The bug this suite pins is the state *after* that: the
/// settled frame lands, but the digest-keyed backdrop still describes the preview (or an older
/// document), so shrinking shows a bottom image with the wrong balance.
///
/// The three claims:
///
///   1. **The preview and the settled frame are different sources.** The key carries the preview
///      target *and* a source marker, so a texture made during the drag can never be mistaken for the
///      settled document even when the pair is numerically the same.
///   2. **A settled frame retires the preview's bottom image.** Merely landing does not render a new
///      one (the 039 gate is unchanged); it drops the old one, so the accessor cannot return a digest
///      the canvas no longer has.
///   3. **The next need rebuilds from the new frame, and the result is the same bytes a rebuild
///      makes.** Repeated preview → settle cycles hit the new digest every time.
@MainActor
final class BackdropRefreshTests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
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

    private func waitFor(_ timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func makeController(url: URL, identity: String)
        -> (loupe: LoupeController, session: CatalogSession, URL: URL) {
        let session = CatalogSession()
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = loupe.view
        loupe.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        window.orderFront(nil)
        loupe.view.layoutSubtreeIfNeeded()
        pump(0.05)
        loupe.frameSource = LoupeController.FrameSource(url: url, identity: identity,
                                                        viewport: Self.viewport, state: .fit,
                                                        edit: session.edit)
        loupe.autoRenderEnabled = true
        loupe.scheduleRender()
        XCTAssertTrue(waitFor { loupe.lastFrame != nil }, "no first frame")
        XCTAssertTrue(waitFor { loupe.backdrop.texture != nil }, "the open made no bottom image")
        pump(0.05)
        return (loupe, session, url)
    }

    /// The pointer leaves and comes back: **one** entry, the way a tracking area delivers it.
    private func enter(_ loupe: LoupeController, at point: CGPoint = CGPoint(x: 64, y: 140)) {
        loupe.pointerExited()
        loupe.pointerMoved(to: point)
    }

    @discardableResult
    private func settleBackdrop(_ loupe: LoupeController,
                                timeout: TimeInterval = 60) -> Bool {
        waitFor(timeout) { loupe.backdrop.isIdle }
    }

    /// The edit a preview frame is rendered from: the document with the target pair in S1.
    private func previewEdit(_ document: EditModel, _ target: (Double, Double)) -> EditModel {
        var edit = document
        edit.light.temperature = target.0
        edit.light.tint = target.1
        return edit
    }

    private func previewDigest(_ document: EditModel, _ target: (Double, Double)) -> String {
        Histogram.editDigest(previewEdit(document, target)) + LoupeController.backdropPreviewMarker
    }

    /// One drag tick: the preview frame reaches the canvas and the target is stable.
    @discardableResult
    private func drag(_ loupe: LoupeController, to target: (Double, Double),
                      from count: Int) -> Bool {
        if !loupe.isWhiteBalancePreviewActive { loupe.beginWhiteBalancePreview() }
        loupe.updateWhiteBalancePreview(temperature: target.0, tint: target.1)
        return waitFor { loupe.whiteBalancePreviewRenderCount > count
            && !loupe.isRenderingWhiteBalancePreview }
    }

    /// The slider's release: one document write, one settled frame from that document.
    private func settle(_ loupe: LoupeController, session: CatalogSession, url: URL,
                        to target: (Double, Double)) {
        let source = loupe.frameSource!
        var edited = source.edit
        edited.light.temperature = target.0
        edited.light.tint = target.1
        session.applyEdit { $0 = edited }
        let revision = session.editRevision
        loupe.frameSource = LoupeController.FrameSource(url: url, identity: source.identity,
                                                        viewport: source.viewport,
                                                        state: source.state, edit: edited)
        loupe.releaseWhiteBalancePreview(awaiting: revision)
        loupe.scheduleRender()
        XCTAssertTrue(waitFor {
            !loupe.isWhiteBalancePreviewActive && (loupe.lastFrame?.editRevision ?? 0) >= revision
        }, "the settled frame never replaced the preview")
        XCTAssertTrue(settleBackdrop(loupe))
        pump(0.05)
    }

    // MARK: - ① the backdrop follows the settled frame

    func testTheBackdropFollowsTheSettledFrame() throws {
        let url = try rawFixture()
        let (loupe, session, _) = makeController(url: url, identity: "backdrop-refresh-follow")
        let openedGeneration = loupe.backdrop.generationCount

        let target = (4200.0, 12.0)
        let documentBefore = try XCTUnwrap(loupe.frameSource).edit
        XCTAssertTrue(drag(loupe, to: target, from: 0), "no preview frame reached the canvas")
        let previewDigest = previewDigest(documentBefore, target)
        XCTAssertEqual(loupe.backdropDigestForTesting, previewDigest,
                       "the key must name the preview source, not the document being dragged")

        // The shrink's bottom image is the preview's. It is made by the same dirty-pointer-entry gate
        // as every other backdrop (039); nothing here renders once per tick.
        XCTAssertTrue(loupe.backdrop.needsGeneration(for: try XCTUnwrap(loupe.backdropKeyForTesting)))
        enter(loupe)
        XCTAssertTrue(settleBackdrop(loupe), "the preview backdrop never finished")
        XCTAssertEqual(loupe.backdrop.generationCount, openedGeneration + 1,
                       "one dirty entry, one generation")
        let previewTexture = try XCTUnwrap(loupe.backdrop.texture)
        let previewFrame = try XCTUnwrap(loupe.lowResFullFrame)
        XCTAssertEqual(previewFrame.digest, previewDigest)
        XCTAssertTrue(previewFrame.digest.hasSuffix(LoupeController.backdropPreviewMarker))

        // A shrinking window is given exactly that texture (the present pass's own gate, 039).
        let shrinking = PresentWindow(u0: -1.5, v0: -1.5, du: 4, dv: 4)
        XCTAssertFalse(shrinking.coversCanvas)
        XCTAssertTrue(loupe.backdropTextureForTesting(for: shrinking) === previewTexture,
                      "a shrinking canvas must draw the preview's bottom image")

        // ── release. The settled frame replaces the preview on the canvas.
        settle(loupe, session: session, url: url, to: target)
        let settledDocument = try XCTUnwrap(loupe.frameSource).edit
        let settledDigest = Histogram.editDigest(settledDocument)

        // The old preview texture may not be offered under its old digest any more, and the settle
        // itself arms one rebuild from the settled frame (one per gesture, not one per frame).
        XCTAssertNotEqual(loupe.lowResFullFrame?.digest, previewDigest,
                          "the settled frame must retire the preview's bottom image, not leave its digest")
        let settledFrame = try XCTUnwrap(loupe.lowResFullFrame,
                                         "the settle must rebuild the bottom image from the new frame")
        XCTAssertEqual(settledFrame.digest, settledDigest)
        XCTAssertEqual(loupe.backdropDigestForTesting, settledDigest)
        XCTAssertFalse(settledFrame.digest.hasSuffix(LoupeController.backdropPreviewMarker))
        XCTAssertFalse(settledFrame.texture === previewTexture)
        let rebuilt = LoupeController.hash(settledFrame.texture)

        // Byte-for-byte what a second rebuild from the same settled frame produces.
        loupe.backdrop.invalidate()
        XCTAssertTrue(loupe.ensureLowResFullFrame(), "a released backdrop is exactly what this is for")
        XCTAssertTrue(settleBackdrop(loupe))
        let again = try XCTUnwrap(loupe.lowResFullFrame)
        XCTAssertEqual(again.digest, settledDigest)
        XCTAssertEqual(LoupeController.hash(again.texture), rebuilt,
                       "the settled backdrop must be deterministic, not a leftover of the preview")
        print("[144] preview \(previewDigest.prefix(16))… → settled \(settledDigest.prefix(16))… "
              + "· generations \(loupe.backdrop.generationCount)")
    }

    // MARK: - ② nothing changed → one generation, however often it is read

    func testNoRebuildWhenNothingChanged() throws {
        let url = try rawFixture()
        let (loupe, _, _) = makeController(url: url, identity: "backdrop-refresh-clean")
        XCTAssertTrue(waitFor { loupe.backdrop.isIdle })
        XCTAssertEqual(loupe.backdrop.generationCount, 1, "the open made exactly one")

        for _ in 0 ..< 10 {
            XCTAssertNotNil(loupe.lowResFullFrame)
            pump(0.01)
        }
        XCTAssertTrue(settleBackdrop(loupe))
        XCTAssertEqual(loupe.backdrop.generationCount, 1,
                       "reading a clean backdrop must not rebuild it")
        XCTAssertFalse(loupe.ensureLowResFullFrame(),
                       "the document on screen is already cached")
    }

    // MARK: - ③ every preview → settled replacement moves the digest

    func testEveryFrameArrivalInvalidates() throws {
        let url = try rawFixture()
        let (loupe, session, _) = makeController(url: url, identity: "backdrop-refresh-cycles")
        var seen = Set<String>()

        for i in 0 ..< 5 {
            let target = (3000.0 + Double(i) * 550.0, Double(i) * 3.0)
            let documentBefore = try XCTUnwrap(loupe.frameSource).edit
            let expectedPreview = previewDigest(documentBefore, target)
            let rendersBefore = loupe.whiteBalancePreviewRenderCount
            XCTAssertTrue(drag(loupe, to: target, from: rendersBefore),
                          "cycle \(i): no preview frame")

            enter(loupe)
            XCTAssertTrue(settleBackdrop(loupe), "cycle \(i): preview backdrop never finished")
            XCTAssertEqual(loupe.lowResFullFrame?.digest, expectedPreview,
                           "cycle \(i): the preview backdrop must name the preview source")

            settle(loupe, session: session, url: url, to: target)
            let settledDigest = Histogram.editDigest(try XCTUnwrap(loupe.frameSource).edit)
            XCTAssertNotEqual(loupe.lowResFullFrame?.digest, expectedPreview,
                              "cycle \(i): the settled frame must retire the preview backdrop first")
            XCTAssertEqual(loupe.lowResFullFrame?.digest, settledDigest,
                           "cycle \(i): the rebuilt backdrop must name the settled document")
            XCTAssertTrue(seen.insert(settledDigest).inserted,
                          "cycle \(i): every settled document is a different digest")
            print("[144] cycle \(i): preview → \(expectedPreview.prefix(12))…, "
                  + "settled → \(settledDigest.prefix(12))…")
        }

        XCTAssertEqual(seen.count, 5)
    }
}
