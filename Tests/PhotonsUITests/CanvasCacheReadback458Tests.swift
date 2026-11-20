import XCTest
import AppKit
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 458 — 窗口画布缓存的**读取**这一半。
///
/// 434 建好了容量（浏览 10 / 编辑 3）、副本所有权（`.shared`，437）和写入点；用户仍说
/// 「缓存应该是建好了但没读取上」。根因是 key 把显示值（headroom / primaries）和 rung 拼成了
/// 身份：写的时候用帧记下的值，读的时候用屏幕此刻的实时值，`%.17g` 下只要差 1 ulp 就是两个 key。
///
/// 458 的规则：
///   · **软 key + 硬校验** — 身份不含 headroom / primaries / rung；命中要求条目的这三个值与调用方
///     此刻给出的值逐位相等。
///   · **显示变化即失效** — headroom / primaries 一移动就清表，不拿旧显示下的像素凑命中。
///   · **miss 归因** — 每次 miss 记下是照片、显示、文档、相机、画布还是 rung 变了。
///
/// 所有用例都走真实路径：`LoupeController` + `frameSource` + 真实 RAW + 真实 Metal presenter。
@MainActor
final class CanvasCacheReadback458Tests: XCTestCase {

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

    /// Two real RAW files: the switch A→B→A is the user's own gesture, not two identities of one file.
    private func rawFixtures() throws -> (URL, URL) {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"], !env.isEmpty {
            candidates.append(NSString(string: env).expandingTildeInPath)
        }
        candidates.append(NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath)
        guard let first = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) })
        else { throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW") }

        let firstURL = URL(fileURLWithPath: first)
        let directory = firstURL.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil))
            ?? []
        let second = siblings
            .filter { $0.standardizedFileURL != firstURL.standardizedFileURL }
            .filter { ["dng", "DNG", "raw", "RAW"].contains($0.pathExtension) }
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
        guard let second else { throw XCTSkip("two RAW fixtures are required for the A→B→A path") }
        return (firstURL, second)
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

    private func source(_ url: URL, _ identity: String) -> LoupeController.FrameSource {
        LoupeController.FrameSource(url: url, identity: identity, viewport: Self.viewport,
                                    state: .fit, edit: .neutral)
    }

    /// Name a photo and ask for its first frame; returns the key this scheduled render looked up.
    @discardableResult
    private func switchTo(_ controller: LoupeController, _ url: URL,
                          _ identity: String) throws -> CanvasFrameCache.Key {
        controller.frameSource = source(url, identity)
        controller.scheduleRender()
        return try XCTUnwrap(controller.lastCanvasFrameCacheKey,
                             "scheduleRender did not name a canvas-cache key")
    }

    /// Switch to a photo and wait until its settled frame has been **stored** (not merely presented).
    @discardableResult
    private func settle(_ controller: LoupeController, _ url: URL,
                        _ identity: String) throws -> CanvasFrameCache.Key {
        let key = try switchTo(controller, url, identity)
        XCTAssertTrue(waitFor { controller.canvasFrameCache.contains(key) },
                      "the settled frame of \(identity) never reached the canvas cache")
        return key
    }

    private func graphOwner(_ frame: LoupeController.FrameResult?) -> RenderGraph? {
        guard let frame, case .graph(let graph) = frame.owner else { return nil }
        return graph
    }

    // MARK: - ①②③ ④ A→B→A hits, the pixels are readable, and the copy never enters the pool

    func testACachedReturnHitsReadsBackAndNeverEntersThePool() throws {
        let (a, b) = try rawFixtures()
        let controller = makeController()
        let cache = controller.canvasFrameCache

        _ = try settle(controller, a, "readback458-a")
        _ = try settle(controller, b, "readback458-b")

        let hitsBefore = cache.hits
        let presentsBefore = controller.canvasCachePresents
        let settledBefore = controller.settledFramePresents
        let arrivalsBefore = controller.rungArrivals

        let keyA = try switchTo(controller, a, "readback458-a")

        // ① A→B→A must hit: exactly one hit, the cached canvas replaces the stand-in, and it is on
        // screen before a development could have finished.
        XCTAssertEqual(cache.hits, hitsBefore + 1, "A→B→A: exactly one hit for the return")
        XCTAssertEqual(controller.canvasCachePresents, presentsBefore + 1)
        XCTAssertEqual(controller.firstFrameContent, .canvasCache,
                       "the return presented something other than the cached canvas")
        XCTAssertLessThan(controller.lastPhotoSwitchFirstFrameMilliseconds, 100,
                          "the cached canvas did not reach the layer before the decode")

        // ③ No wrong-pixel hit: the headroom/primaries the cache presented are the entry's own.
        let cached = try XCTUnwrap(cache.cachedCanvas(matching: keyA),
                                   "the hit's entry is not in the table")
        XCTAssertEqual(controller.lastPresentedHeadroomForTesting?.bitPattern,
                       cached.headroom.bitPattern,
                       "the cache presented a headroom the entry was not rendered under")
        XCTAssertEqual(controller.lastPresentedPrimariesForTesting, cached.primaries,
                       "the cache presented primaries the entry was not rendered under")

        // ④ 437's crash: the pointer reads the presented frame. A cached frame is `.shared`, the
        // copy is readable, and it is not a RenderGraph texture that could be recycled underneath it.
        XCTAssertEqual(cached.texture.storageMode, .shared,
                       "437: a private cache copy segfaults the pointer's getBytes")
        let centreX = cached.texture.width / 2
        let centreY = cached.texture.height / 2
        let pixel = LoupeController.sample(cached.frameResult(), x: centreX, y: centreY,
                                           histogram: nil)
        XCTAssertNotNil(pixel, "437: the cached canvas must be readable the way the pointer reads it")
        XCTAssertEqual(pixel?.source, .presented)

        // ①b the hit still develops and the real frame replaces the cached copy.
        XCTAssertTrue(waitFor { controller.settledFramePresents > settledBefore },
                      "the real settled frame never reached the cache")
        XCTAssertGreaterThan(controller.rungArrivals, arrivalsBefore,
                             "a hit must not skip the development")
        XCTAssertEqual(controller.developedRungs[1], 1,
                       "the return must develop exactly one full rung")
        XCTAssertTrue(waitFor { controller.lastFrame?.decodeScale == 1 },
                      "the real full-size frame never presented")
        let real = try XCTUnwrap(controller.lastFrame)
        XCTAssertNotEqual(ObjectIdentifier(real.texture), ObjectIdentifier(cached.texture),
                          "the cache kept a reference instead of its own blit copy")
        XCTAssertEqual(controller.currentCanvasTextureIDForTesting,
                       ObjectIdentifier(real.texture),
                       "the canvas is showing the real frame, not the cached copy")
        let graph = try XCTUnwrap(graphOwner(real), "the real frame is not graph-owned")
        XCTAssertEqual(graph.foreignTextureRecycles, 0,
                       "a cache copy was handed to the render pool (438's black canvas)")

        print("[458] A→B→A: hits=\(cache.hits) misses=\(cache.misses) stores=\(cache.stores) "
              + "count=\(cache.count)/\(cache.capacity) "
              + String(format: "switch→cached %.1f ms, entry %.1f MB",
                       controller.lastPhotoSwitchFirstFrameMilliseconds,
                       Double(cached.byteCount) / 1_048_576))
    }

    // MARK: - ② display change: clear, never serve the other display's pixels

    func testADisplayMoveClearsTheTableInsteadOfServingAnotherDisplay() throws {
        let (a, b) = try rawFixtures()
        let controller = makeController()
        let cache = controller.canvasFrameCache

        _ = try settle(controller, a, "display458-a")
        _ = try settle(controller, b, "display458-b")
        XCTAssertGreaterThan(cache.count, 0)

        let hitsBefore = cache.hits
        let presentsBefore = controller.canvasCachePresents
        let displayMissesBefore = controller.canvasCacheMissReasons[.displayChanged]

        // Inject one ulp of headroom between the two settles. This is the real screen's behaviour
        // (EDR/brightness re-reads move the number) reproduced deterministically.
        controller.autoRenderEnabled = false
        let bumped = controller.headroom.nextUp
        XCTAssertNotEqual(bumped, controller.headroom)
        controller.setDisplayHeadroom(
            DisplayHeadroom(headroom: bumped, screenName: "injected-458",
                            maximumEDRComponent: bumped, source: .extendedRange))
        controller.autoRenderEnabled = true

        // ② 新代码：显示一变就清空，不拿旧 headroom 的像素凑一个「命中」。
        XCTAssertEqual(cache.count, 0, "a display move must leave no entry to serve")

        _ = try switchTo(controller, a, "display458-a")

        XCTAssertEqual(cache.hits, hitsBefore, "the return after a display move must not hit")
        XCTAssertEqual(controller.canvasCachePresents, presentsBefore,
                       "the return after a display move must not present a cached canvas")
        XCTAssertNotEqual(controller.firstFrameContent, .canvasCache)
        XCTAssertGreaterThanOrEqual(
            controller.canvasCacheMissReasons[.displayChanged], displayMissesBefore + 1,
            "the miss must be attributed to the display, not silently counted as a first visit")
    }

    // MARK: - ⑤ the capacities are still 10 / 3

    func testCapacityIsStillTenThenThree() throws {
        let cache = try makeEmptyCache()
        for index in 0..<12 {
            cache.store(try dummyFrame(), key: dummyKey(photo: "cap458-\(index)"))
        }
        XCTAssertEqual(cache.capacity, 10)
        XCTAssertEqual(cache.count, 10, "browsing keeps ten canvas frames")
        XCTAssertEqual(cache.evictions, 2, "twelve visits, ten slots: two LRU evictions")

        cache.noteEditLanded(photo: "cap458-11", digest: "digest")
        XCTAssertEqual(cache.regime, .editing)
        XCTAssertEqual(cache.capacity, 3)
        XCTAssertEqual(cache.count, 3, "the first edit trims the table to three")
    }

    /// The soft key is not permission to serve any display: the entry's own values are the check.
    /// This is the unit-level form of ②, independent of the controller's invalidation.
    func testLookupHardChecksDisplayAndRungInsteadOfTrustingTheSoftKey() throws {
        let cache = try makeEmptyCache()
        let key = dummyKey(photo: "display458-unit")
        XCTAssertTrue(cache.store(try dummyFrame(), key: key))

        XCTAssertNotNil(cache.lookup(key, headroom: 1, primaries: .displayP3, decodeScale: 1),
                        "same display and rung must hit")

        XCTAssertNil(cache.lookup(key, headroom: 1.0000000000000002,
                                  primaries: .displayP3, decodeScale: 1),
                     "one ulp of headroom must miss, not alias")
        XCTAssertEqual(cache.missReasons[.displayChanged], 1)

        XCTAssertNil(cache.lookup(key, headroom: 1, primaries: .sRGB, decodeScale: 1),
                     "another primaries must miss")
        XCTAssertEqual(cache.missReasons[.displayChanged], 2)

        XCTAssertNil(cache.lookup(key, headroom: 1, primaries: .displayP3, decodeScale: 0.5),
                     "a predicted rung the entry was not rendered from must miss")
        XCTAssertEqual(cache.missReasons[.decodeScaleChanged], 1)
    }

    // MARK: - unit fixtures

    private func makeEmptyCache() throws -> CanvasFrameCache {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return CanvasFrameCache()
    }

    private func dummyKey(photo: String, digest: String = "digest") -> CanvasFrameCache.Key {
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
}
