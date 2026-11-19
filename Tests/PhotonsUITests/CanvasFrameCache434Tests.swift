import XCTest
import AppKit
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 434 — 窗口画布缓存：未编辑前保留 10 张，开始编辑后保留最新 3 张。
///
/// The user's wording:
///
/// > 当前修改区域（即窗口画布）的缓存在未有继续编辑前，保留最多 10 张不同照片的窗口缓存。
/// > 开始对照片编辑后，保留最新的三张窗口缓存（含当前正在编辑的），这样多张照片对比时不用一直等重新解 raw 渲染
///
/// And the correction of 18:1x:
///
/// > 命中就后台继续渲染只不过把原本 1920px 低清图换成缓存命中
///
/// So a hit means 「这次上屏早于解码」: the cached canvas takes the 1920 px stand-in's place at the
/// instant of the switch, **and the scheduled render still develops and renders**. The real frame
/// then replaces it through the same `present(...)`.
///
/// Everything here drives the shipped path: a `LoupeController` with a `frameSource`, `scheduleRender`,
/// the decode queue and the real Metal presenter. No test-only render path exists.
@MainActor
final class CanvasFrameCache434Tests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        CanvasFrameCache.browsingCapacity = 10
        CanvasFrameCache.editingCapacity = 3
        CanvasFrameCache.invalidatesOnEdit = true
        CanvasFrameCache.protectsCurrentPhoto = true
        super.tearDown()
    }

    // MARK: - fixtures / harness

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
    private func waitFor(_ timeout: TimeInterval = 90, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    /// A controller with a live layer and no photo yet. The first photo is named by `switchTo`, so a
    /// fixture photo is never a cache entry of its own.
    private func makeController() -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        TestWindows.show(window)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        controller.autoRenderEnabled = true
        return controller
    }

    private func source(_ url: URL, _ identity: String, edit: EditModel = .neutral)
        -> LoupeController.FrameSource {
        LoupeController.FrameSource(url: url, identity: identity, viewport: Self.viewport,
                                    state: .fit, edit: edit)
    }

    /// Name a photo and ask for its first frame. Returns the key this scheduled render looked up.
    @discardableResult
    private func switchTo(_ controller: LoupeController, _ url: URL, _ identity: String,
                          edit: EditModel = .neutral) throws -> CanvasFrameCache.Key {
        controller.frameSource = source(url, identity, edit: edit)
        controller.scheduleRender()
        return try XCTUnwrap(controller.lastCanvasFrameCacheKey,
                             "scheduleRender did not name a canvas-cache key")
    }

    private func visit(_ controller: LoupeController, _ url: URL, _ identity: String,
                       edit: EditModel = .neutral) throws -> CanvasFrameCache.Key {
        let key = try switchTo(controller, url, identity, edit: edit)
        XCTAssertTrue(waitFor { controller.canvasFrameCache.contains(key) },
                      "the settled frame of \(identity) never reached the canvas cache")
        return key
    }

    private func presentCount(_ controller: LoupeController) -> Int {
        controller.canvasPresenter?.presentCount ?? 0
    }

    // MARK: - Key: every pixel input is in it

    func testTheKeyChangesForEveryInputThatReachesThePixels() {
        let base = CanvasFrameCache.Key(
            photo: "p", decodeInputs: "d", editDigest: "e", geometry: "g",
            cameraState: "fit", viewport: ImageSize(width: 640, height: 400),
            mode: "edited", fitScale: 0.9, canvasRole: "export",
            cropIsActive: false, highlightWarning: false, headroom: 1,
            decodeScale: 1, primaries: "displayP3", highlightCeiling: 4.9)

        let variants: [(String, CanvasFrameCache.Key)] = [
            ("photo", CanvasFrameCache.Key(photo: "q", decodeInputs: "d", editDigest: "e",
                                           geometry: "g", cameraState: "fit",
                                           viewport: base.viewport, mode: "edited", fitScale: 0.9,
                                           canvasRole: "export", cropIsActive: false,
                                           highlightWarning: false, headroom: 1, decodeScale: 1,
                                           primaries: "displayP3", highlightCeiling: 4.9)),
            ("decodeInputs", CanvasFrameCache.Key(photo: "p", decodeInputs: "d2", editDigest: "e",
                                                  geometry: "g", cameraState: "fit",
                                                  viewport: base.viewport, mode: "edited", fitScale: 0.9,
                                                  canvasRole: "export", cropIsActive: false,
                                                  highlightWarning: false, headroom: 1, decodeScale: 1,
                                                  primaries: "displayP3", highlightCeiling: 4.9)),
            ("editDigest", CanvasFrameCache.Key(photo: "p", decodeInputs: "d", editDigest: "e2",
                                                geometry: "g", cameraState: "fit",
                                                viewport: base.viewport, mode: "edited", fitScale: 0.9,
                                                canvasRole: "export", cropIsActive: false,
                                                highlightWarning: false, headroom: 1, decodeScale: 1,
                                                primaries: "displayP3", highlightCeiling: 4.9)),
            ("geometry", CanvasFrameCache.Key(photo: "p", decodeInputs: "d", editDigest: "e",
                                              geometry: "g2", cameraState: "fit",
                                              viewport: base.viewport, mode: "edited", fitScale: 0.9,
                                              canvasRole: "export", cropIsActive: false,
                                              highlightWarning: false, headroom: 1, decodeScale: 1,
                                              primaries: "displayP3", highlightCeiling: 4.9)),
            ("cameraState", CanvasFrameCache.Key(photo: "p", decodeInputs: "d", editDigest: "e",
                                                 geometry: "g", cameraState: "actual|z=1",
                                                 viewport: base.viewport, mode: "edited", fitScale: 0.9,
                                                 canvasRole: "export", cropIsActive: false,
                                                 highlightWarning: false, headroom: 1, decodeScale: 1,
                                                 primaries: "displayP3", highlightCeiling: 4.9)),
            ("viewport", CanvasFrameCache.Key(photo: "p", decodeInputs: "d", editDigest: "e",
                                              geometry: "g", cameraState: "fit",
                                              viewport: ImageSize(width: 641, height: 400),
                                              mode: "edited", fitScale: 0.9, canvasRole: "export",
                                              cropIsActive: false, highlightWarning: false, headroom: 1,
                                              decodeScale: 1, primaries: "displayP3",
                                              highlightCeiling: 4.9)),
            ("mode", CanvasFrameCache.Key(photo: "p", decodeInputs: "d", editDigest: "e",
                                          geometry: "g", cameraState: "fit", viewport: base.viewport,
                                          mode: "original", fitScale: 0.9, canvasRole: "export",
                                          cropIsActive: false, highlightWarning: false, headroom: 1,
                                          decodeScale: 1, primaries: "displayP3",
                                          highlightCeiling: 4.9)),
            ("fitScale", CanvasFrameCache.Key(photo: "p", decodeInputs: "d", editDigest: "e",
                                              geometry: "g", cameraState: "fit", viewport: base.viewport,
                                              mode: "edited", fitScale: 0.9000001, canvasRole: "export",
                                              cropIsActive: false, highlightWarning: false, headroom: 1,
                                              decodeScale: 1, primaries: "displayP3",
                                              highlightCeiling: 4.9)),
            ("canvasRole", CanvasFrameCache.Key(photo: "p", decodeInputs: "d", editDigest: "e",
                                                geometry: "g", cameraState: "fit", viewport: base.viewport,
                                                mode: "edited", fitScale: 0.9, canvasRole: "document",
                                                cropIsActive: false, highlightWarning: false, headroom: 1,
                                                decodeScale: 1, primaries: "displayP3",
                                                highlightCeiling: 4.9)),
            ("cropIsActive", CanvasFrameCache.Key(photo: "p", decodeInputs: "d", editDigest: "e",
                                                  geometry: "g", cameraState: "fit", viewport: base.viewport,
                                                  mode: "edited", fitScale: 0.9, canvasRole: "export",
                                                  cropIsActive: true, highlightWarning: false, headroom: 1,
                                                  decodeScale: 1, primaries: "displayP3",
                                                  highlightCeiling: 4.9)),
            ("highlightWarning", CanvasFrameCache.Key(photo: "p", decodeInputs: "d", editDigest: "e",
                                                      geometry: "g", cameraState: "fit",
                                                      viewport: base.viewport, mode: "edited",
                                                      fitScale: 0.9, canvasRole: "export",
                                                      cropIsActive: false, highlightWarning: true,
                                                      headroom: 1, decodeScale: 1,
                                                      primaries: "displayP3", highlightCeiling: 4.9)),
            ("headroom", CanvasFrameCache.Key(photo: "p", decodeInputs: "d", editDigest: "e",
                                              geometry: "g", cameraState: "fit", viewport: base.viewport,
                                              mode: "edited", fitScale: 0.9, canvasRole: "export",
                                              cropIsActive: false, highlightWarning: false, headroom: 2.5,
                                              decodeScale: 1, primaries: "displayP3",
                                              highlightCeiling: 4.9)),
            ("decodeScale", CanvasFrameCache.Key(photo: "p", decodeInputs: "d", editDigest: "e",
                                                 geometry: "g", cameraState: "fit",
                                                 viewport: base.viewport, mode: "edited", fitScale: 0.9,
                                                 canvasRole: "export", cropIsActive: false,
                                                 highlightWarning: false, headroom: 1, decodeScale: 0.5,
                                                 primaries: "displayP3", highlightCeiling: 4.9)),
            ("primaries", CanvasFrameCache.Key(photo: "p", decodeInputs: "d", editDigest: "e",
                                               geometry: "g", cameraState: "fit", viewport: base.viewport,
                                               mode: "edited", fitScale: 0.9, canvasRole: "export",
                                               cropIsActive: false, highlightWarning: false, headroom: 1,
                                               decodeScale: 1, primaries: "sRGB", highlightCeiling: 4.9)),
            ("highlightCeiling", CanvasFrameCache.Key(photo: "p", decodeInputs: "d", editDigest: "e",
                                                      geometry: "g", cameraState: "fit",
                                                      viewport: base.viewport, mode: "edited",
                                                      fitScale: 0.9, canvasRole: "export",
                                                      cropIsActive: false, highlightWarning: false,
                                                      headroom: 1, decodeScale: 1,
                                                      primaries: "displayP3", highlightCeiling: 8)),
        ]

        for (name, variant) in variants {
            XCTAssertNotEqual(variant.identity, base.identity, "\(name) is missing from the key")
            XCTAssertNotEqual(variant, base, "\(name) is missing from Key equality")
        }
        XCTAssertEqual(base, CanvasFrameCache.Key(
            photo: "p", decodeInputs: "d", editDigest: "e", geometry: "g",
            cameraState: "fit", viewport: ImageSize(width: 640, height: 400),
            mode: "edited", fitScale: 0.9, canvasRole: "export",
            cropIsActive: false, highlightWarning: false, headroom: 1,
            decodeScale: 1, primaries: "displayP3", highlightCeiling: 4.9),
                       "the same inputs must spell the same key")
    }

    // MARK: - ①②③⑥⑦ the browsing regime, one switch at a time

    func testBrowsingKeepsTenAndACachedPhotoComesBackBeforeItsDecode() throws {
        let url = try rawFixture()
        let controller = makeController()
        let cache = controller.canvasFrameCache

        // A① — twelve different photos at the same camera and canvas.
        var keys: [String: CanvasFrameCache.Key] = [:]
        for index in 1...12 {
            let identity = "cache434-photo-\(index)"
            keys[identity] = try visit(controller, url, identity)
        }
        var diagnostics = controller.canvasFrameCacheDiagnostics
        XCTAssertEqual(diagnostics.capacity, 10)
        XCTAssertEqual(diagnostics.count, 10, "browsing keeps ten canvas frames")
        XCTAssertEqual(diagnostics.evictions, 2, "twelve visits, ten slots: two LRU evictions")

        let cacheDiagnostics = cache.diagnostics
        XCTAssertTrue(cache.contains(try XCTUnwrap(keys["cache434-photo-11"])))
        XCTAssertTrue(cache.contains(try XCTUnwrap(keys["cache434-photo-12"])))
        XCTAssertFalse(cache.contains(try XCTUnwrap(keys["cache434-photo-1"])),
                       "the first photo must be the first eviction")
        XCTAssertFalse(cache.contains(try XCTUnwrap(keys["cache434-photo-2"])),
                       "the second photo must be the second eviction")

        // A② —回到第 3 张: the cached canvas goes up at the switch, before any development.
        let hitsBefore = diagnostics.hits
        let presentsBefore = presentCount(controller)
        let cachePresentsBefore = controller.canvasCachePresents
        let settledBefore = controller.settledFramePresents
        let arrivalsBefore = controller.rungArrivals
        let photo3 = try switchTo(controller, url, "cache434-photo-3")

        diagnostics = controller.canvasFrameCacheDiagnostics
        XCTAssertEqual(diagnostics.hits, hitsBefore + 1, "A②: exactly one hit for the return")
        XCTAssertEqual(controller.canvasCachePresents, cachePresentsBefore + 1)
        XCTAssertEqual(controller.firstFrameContent, .canvasCache,
                       "A②c: the cached canvas replaced the 1920 px stand-in")
        XCTAssertGreaterThan(controller.lastPhotoSwitchFirstFrameMilliseconds, 0,
                             "the switch's first frame must still be timed")
        XCTAssertLessThan(controller.lastPhotoSwitchFirstFrameMilliseconds, 100,
                          "A②: the cached canvas reached the layer before the decode")
        let cachedPresentMilliseconds = controller.lastPhotoSwitchFirstFrameMilliseconds
        XCTAssertTrue(cache.contains(photo3))

        // A②b — the scheduled render still develops and renders, and the real frame replaces it.
        let cachedAtHit = try XCTUnwrap(cache.cachedCanvas(for: photo3))
        let cachedID = ObjectIdentifier(cachedAtHit.texture)
        XCTAssertTrue(waitFor { controller.settledFramePresents > settledBefore },
                      "A②b: the real settled frame never reached the cache")
        XCTAssertGreaterThan(controller.rungArrivals, arrivalsBefore,
                             "A②b: the return must still develop the photo")
        XCTAssertEqual(controller.developedRungs[1], 1,
                       "A②b: exactly one full-size development after the switch")
        XCTAssertTrue(waitFor { controller.lastFrame?.decodeScale == 1 },
                      "the real full-size frame never presented")
        let realTexture = try XCTUnwrap(controller.lastFrame?.texture)
        XCTAssertNotEqual(ObjectIdentifier(realTexture), cachedID,
                          "A②b: the cache texture is not the real frame's texture")
        XCTAssertNotEqual(controller.currentCanvasTextureIDForTesting, cachedID,
                          "A②b: the canvas is showing the real frame, not the cached copy")

        // A⑦ — the cached frame and the real frame both went through `present(...)`.
        let presentsAfter = presentCount(controller)
        XCTAssertGreaterThanOrEqual(presentsAfter - presentsBefore, 2,
                                    "A⑦: one cached present and at least one real present")
        XCTAssertEqual(controller.canvasCachePresents, cachePresentsBefore + 1,
                       "A⑦: exactly one cached present")

        // A⑥ — the entry owns a copy; the graph's texture is a different object and the copy is
        // readable on its own.
        let entry = try XCTUnwrap(cache.cachedCanvas(for: photo3))
        XCTAssertNotEqual(ObjectIdentifier(entry.texture), ObjectIdentifier(realTexture),
                          "A⑥: the cache kept a reference instead of a blit copy")
        XCTAssertEqual(entry.pixelSize, Self.viewport)
        XCTAssertEqual(entry.byteCount, Self.viewport.width * Self.viewport.height * 8)
        XCTAssertNotNil(readCentrePixel(entry.texture), "A⑥: the cached copy is not readable")

        // A③ — a thirteenth photo evicts an old one, never the current photo.
        let photo13 = try visit(controller, url, "cache434-photo-13")
        diagnostics = controller.canvasFrameCacheDiagnostics
        XCTAssertEqual(diagnostics.count, 10)
        XCTAssertTrue(cache.contains(photo13), "A③: the current photo's entry was evicted")
        XCTAssertFalse(cache.contains(try XCTUnwrap(keys["cache434-photo-4"])),
                       "A③: the oldest entry should be the victim instead")

        print("[434] browsing: count=\(diagnostics.count) bytes=\(diagnostics.bytes) "
              + "hits=\(diagnostics.hits) misses=\(diagnostics.misses) "
              + "stores=\(diagnostics.stores) evictions=\(diagnostics.evictions); "
              + String(format: "one entry %.1f MB, ten %.1f MB, blit %.3f ms, "
                       + "switch→cached present %.1f ms",
                       Double(cacheDiagnostics.bytes / 10) / 1_048_576,
                       Double(cacheDiagnostics.bytes) / 1_048_576,
                       cache.lastBlitMilliseconds,
                       cachedPresentMilliseconds))
    }

    // MARK: - ④⑤ the editing regime

    func testTheFirstEditMovesToThreeAndItsOldFrameIsNeverServed() throws {
        let url = try rawFixture()
        let controller = makeController()
        let cache = controller.canvasFrameCache
        controller.hashesFrames = true

        var photoKeys: [String: CanvasFrameCache.Key] = [:]
        for identity in ["edit434-p1", "edit434-p2", "edit434-p3", "edit434-p4", "edit434-p5"] {
            photoKeys[identity] = try visit(controller, url, identity)
        }
        XCTAssertEqual(cache.count, 5)

        // ── A④ — a document write lands for p5 (same photo, new digest).
        var edited = EditModel.neutral
        edited.light.exposure = 0.5
        let oldP5 = try XCTUnwrap(photoKeys["edit434-p5"])
        let editedKey = try switchTo(controller, url, "edit434-p5", edit: edited)

        XCTAssertEqual(cache.capacity, 3, "A④: the first edit moves the capacity to three")
        XCTAssertEqual(controller.canvasCacheRegime, "editing")
        XCTAssertLessThanOrEqual(cache.count, 3, "A④: the table is trimmed at once")
        XCTAssertFalse(cache.contains(oldP5), "A⑤: the old digest's entry must be gone")
        XCTAssertTrue(waitFor { cache.contains(editedKey) }, "the edited frame was never cached")

        // Four more photos: the table stays at three.
        for identity in ["edit434-e1", "edit434-e2", "edit434-e3", "edit434-e4"] {
            _ = try visit(controller, url, identity)
        }
        XCTAssertEqual(cache.count, 3, "A④: three, not four")
        XCTAssertEqual(cache.capacity, 3)

        // ── A⑤ — edit p5, leave, come back. The return is a miss and a fresh render.
        let hitsBefore = cache.hits
        let edited2 = try switchTo(controller, url, "edit434-p5", edit: edited)
        XCTAssertEqual(cache.hits, hitsBefore, "A⑤: an edited photo must not be served from cache")
        XCTAssertNotEqual(controller.firstFrameContent, .canvasCache)

        XCTAssertTrue(waitFor { controller.lastFrame?.decodeScale == 1 && controller.canvasFrameCache.contains(edited2) },
                      "the edited photo's fresh frame never landed")

        let frame = try XCTUnwrap(controller.lastFrame)
        XCTAssertEqual(Histogram.editDigest(frame.edit), Histogram.editDigest(edited),
                       "A⑤: the frame is the new document")
        let reference = try controller.makeFrame(url: url, viewport: Self.viewport, decodeScale: 1,
                                                 edit: edited, state: .fit, hashPixels: true)
        XCTAssertNotNil(frame.displayHash)
        XCTAssertEqual(frame.displayHash, reference.displayHash,
                       "A⑤: the returned frame must be byte-identical to a fresh render")

        print("[434] editing: capacity=\(cache.capacity) count=\(cache.count) "
              + "regime=\(controller.canvasCacheRegime) hits=\(cache.hits) "
              + "evictions=\(cache.evictions)")
    }

    // MARK: - ⑧ the reverse gates

    /// ⑧c (new direction) — with 「命中即跳过整单渲染」 forced on, the hit still presents but the
    /// development and the real frame disappear: A②b goes red.
    func testReverseGateSkippingTheRenderOnAHitStopsTheDevelopment() throws {
        let url = try rawFixture()
        let controller = makeController()

        _ = try visit(controller, url, "gate434-a")
        _ = try visit(controller, url, "gate434-b")
        let arrivalsBefore = controller.rungArrivals
        let settledBefore = controller.settledFramePresents
        let presentsBefore = presentCount(controller)
        let hitsBefore = controller.canvasFrameCache.hits

        controller.rendersAfterCanvasCacheHit = false
        _ = try switchTo(controller, url, "gate434-a")

        XCTAssertEqual(controller.canvasFrameCache.hits, hitsBefore + 1,
                       "the cached frame is still presented")
        XCTAssertEqual(controller.firstFrameContent, .canvasCache)
        XCTAssertEqual(presentCount(controller), presentsBefore + 1,
                       "⑧c: only the cached present, no real frame")
        pump(0.3)
        XCTAssertEqual(controller.rungArrivals, arrivalsBefore,
                       "⑧c: the hit skipped the development (A②b is red)")
        XCTAssertEqual(controller.settledFramePresents, settledBefore,
                       "⑧c: the hit skipped the real frame (A②b is red)")
    }

    /// ⑧a — the capacity is the constant 10. Nine makes A①'s 「count == 10、evictions == 2」 red.
    func testReverseGateBrowsingCapacityNine() throws {
        let cache = try makeEmptyCache()
        CanvasFrameCache.browsingCapacity = 9
        for index in 0..<12 {
            cache.store(try dummyFrame(), key: dummyKey(photo: "cap434-\(index)"))
        }
        XCTAssertEqual(cache.count, 9, "⑧a: capacity 9 keeps nine")
        XCTAssertEqual(cache.evictions, 3)
    }

    /// ⑧b — an edit landing deletes the photo's old entries.
    func testReverseGateEditInvalidation() throws {
        let cache = try makeEmptyCache()
        let key = dummyKey(photo: "inv434", digest: "old")
        cache.store(try dummyFrame(), key: key)
        XCTAssertTrue(cache.contains(key))

        CanvasFrameCache.invalidatesOnEdit = false
        cache.noteEditLanded(photo: "inv434", digest: "new")
        XCTAssertTrue(cache.contains(key), "⑧b: with invalidation off the old frame stays (A⑤ red)")

        CanvasFrameCache.invalidatesOnEdit = true
        cache.noteEditLanded(photo: "inv434", digest: "newer")
        XCTAssertFalse(cache.contains(key), "with invalidation on the old frame is gone")
    }

    /// ⑧d — the current photo is protected from LRU eviction.
    func testReverseGateCurrentPhotoProtection() throws {
        let cache = try makeEmptyCache()
        CanvasFrameCache.browsingCapacity = 3

        let first = dummyKey(photo: "prot434-1")
        cache.store(try dummyFrame(), key: first)
        cache.store(try dummyFrame(), key: dummyKey(photo: "prot434-2"))
        _ = cache.lookup(first)                    // the photo on screen
        XCTAssertTrue(cache.contains(first))

        for index in 3...5 {
            cache.store(try dummyFrame(), key: dummyKey(photo: "prot434-\(index)"))
        }
        XCTAssertTrue(cache.contains(first), "⑧d: the current photo survived three evictions")

        CanvasFrameCache.protectsCurrentPhoto = false
        cache.cleanup()
        cache.store(try dummyFrame(), key: first)
        cache.store(try dummyFrame(), key: dummyKey(photo: "prot434-2"))
        _ = cache.lookup(first)
        for index in 3...5 {
            cache.store(try dummyFrame(), key: dummyKey(photo: "prot434-\(index)"))
        }
        XCTAssertFalse(cache.contains(first), "⑧d: without protection the current photo is evicted")
    }

    // MARK: - the real canvas' entry cost (reported, not gated)

    /// The test canvas is 640 × 400 (2.0 MB per entry). The user's window is 2560 × 1600 device
    /// pixels, which is 32.8 MB per entry — this measures one blit at that size so the report carries
    /// a real number rather than an arithmetic claim.
    func testFullSizeCanvasEntryCost() throws {
        let cache = try makeEmptyCache()
        let size = ImageSize(width: 2560, height: 1600)
        let frame = try dummyFrame(size: size)
        let key = dummyKey(photo: "size434")
        XCTAssertTrue(cache.store(frame, key: key))
        XCTAssertEqual(cache.diagnostics.bytes, 2560 * 1600 * 8)
        XCTAssertEqual(cache.cachedCanvas(for: key)?.pixelSize, size)
        print(String(format: "[434] full-size entry: %d×%d = %.1f MB; blit %.3f ms; ten = %.1f MB",
                     size.width, size.height, Double(cache.diagnostics.bytes) / 1_048_576,
                     cache.lastBlitMilliseconds,
                     10 * Double(cache.diagnostics.bytes) / 1_048_576))
    }

    // MARK: - unit fixtures

    private func makeEmptyCache() throws -> CanvasFrameCache {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return CanvasFrameCache()
    }

    private func dummyKey(photo: String, digest: String = "digest")
        -> CanvasFrameCache.Key {
        CanvasFrameCache.Key(photo: photo, decodeInputs: "d", editDigest: digest,
                             geometry: "", cameraState: "fit", viewport: Self.viewport,
                             mode: "edited", fitScale: 0.9, canvasRole: "export",
                             cropIsActive: false, highlightWarning: false, headroom: 1)
    }

    private func dummyFrame(size: ImageSize = ImageSize(width: 16, height: 16))
        throws -> LoupeController.FrameResult {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: size.width, height: size.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let rect = ImageRect(x: 0, y: 0, width: size.width, height: size.height)
        return LoupeController.FrameResult(
            texture: texture, canvas: size, content: size, photoRect: rect, presentRect: rect,
            outputWindow: nil, decodeScale: 1, decodeMilliseconds: 0, renderMilliseconds: 0,
            usedCachedDecode: true, capabilities: nil, primaries: .displayP3,
            editRevision: 0, edit: .neutral, displayHash: nil, zoom: 1, headroom: 1,
            window: size, clipped: nil, sceneLinearSample: nil, mode: .edited,
            trace: RenderTrace(), whiteBalanceGain: SIMD3<Double>(1, 1, 1),
            frameInCanvas: size, frameOrigin: SIMD2<Float>(0, 0), expandedCanvas: nil,
            neverUpscalesContent: false)
    }

    /// A⑥ — read one texel without `getBytes` on a private texture (the driver's CPU path for a
    /// private `rgba16Float` texture crashed in this suite): one blit into a shared buffer, then the
    /// centre pixel. The readback would fail if the cache had kept a recycled graph texture.
    private func readCentrePixel(_ texture: MTLTexture) -> [UInt16]? {
        let device = texture.device
        guard let queue = device.makeCommandQueue() else { return nil }
        let bytesPerRow = texture.width * 8
        let byteCount = bytesPerRow * texture.height
        guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: byteCount)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        let pixels = buffer.contents().bindMemory(to: UInt16.self, capacity: byteCount / 2)
        let offset = ((texture.height / 2) * texture.width + texture.width / 2) * 4
        return [pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]]
    }
}
