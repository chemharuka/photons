import XCTest
import AppKit
import Metal
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 542 / 571-A — 回切照片命中不到缓存，但 **571-A 不再用更粗的一级将就**。
///
/// 用户口径（2026-11-24）：「现在屏幕渲染完成切下一张，等渲染好再马上切回来，并没有缓存」。
/// 542 的做法是让 1.0 的请求接受 0.5 的条目；571-A 把用户口径收得更紧：画布只出整幅，切图不许先上一张
/// 半分辨率。`coarserRungFloor` 因此是 **1.0** —— 只有不粗于请求尺度的条目可用，0.5 的条目对 1.0 的
/// 请求是 miss（533 占位/新整幅帧接手）。本套件用真库、真解码、真 present 驱动 controller：
///
///   1. 回切时 0.5 的条目 **不命中**：`misses +1`、`decodeScaleChanged +1`、`canvasCachePresents` 不增；
///   2. 精确路径不变：条目 rung 与请求相等时 `hits +1` 且 `coarserRung` 不增长；
///   3. 下限：0.25 的条目对 1.0 的请求同样 miss（与 0.5 一样在 floor 以下）；
///   4. 升级：回切后的足分辨帧到达，同 `softIdentity` 条目变成 1.0；再回切走精确命中；
///   5. 反向门：关掉「接受更粗一级」，结论不变（拒绝发生在更早的尺度检查）。
@MainActor
final class CanvasCacheCoarserRung542Tests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        CanvasFrameCache.browsingCapacity = 10
        CanvasFrameCache.editingCapacity = 3
        CanvasFrameCache.invalidatesOnEdit = true
        CanvasFrameCache.protectsCurrentPhoto = true
        CanvasFrameCache.quantizesCanvasCamera = true
        CanvasFrameCache.canonicalizesCanvasEditDigest = true
        CanvasFrameCache.acceptsCoarserRung = true
        CanvasFrameCache.coarserRungFloor = 1.0
        super.tearDown()
    }

    // MARK: - fixtures / harness

    private func rawFixtures(count: Int) throws -> [URL] {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"], !env.isEmpty {
            candidates.append(NSString(string: env).expandingTildeInPath)
        }
        candidates.append(NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath)
        guard let first = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) })
        else { throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW") }
        let firstURL = URL(fileURLWithPath: first)
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: firstURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        let others = siblings
            .filter { $0.standardizedFileURL != firstURL.standardizedFileURL }
            .filter { ["dng", "DNG", "raw", "RAW"].contains($0.pathExtension) }
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let urls = [firstURL] + others
        guard urls.count >= count else {
            throw XCTSkip("\(count) RAW fixtures are required, found \(urls.count)")
        }
        return Array(urls.prefix(count))
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 180, _ condition: () -> Bool) -> Bool {
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

    private func source(_ url: URL, _ identity: String,
                        state: LoupeViewState = .fit) -> LoupeController.FrameSource {
        LoupeController.FrameSource(url: url, identity: identity, viewport: Self.viewport,
                                    state: state, edit: .neutral)
    }

    @discardableResult
    private func beginSwitch(_ controller: LoupeController, _ url: URL, _ identity: String,
                             state: LoupeViewState = .fit) -> Int {
        let start = controller.framePresentLog.count
        controller.frameSource = source(url, identity, state: state)
        controller.scheduleRender()
        return start
    }

    @discardableResult
    private func waitForFullFrame(_ controller: LoupeController, _ identity: String,
                                  from start: Int) -> Bool {
        waitFor {
            controller.framePresentLog.dropFirst(start).contains {
                $0.photo == identity && !$0.fromCanvasCache
                    && $0.decodeScale >= DecodeLadder.fullScale - 1e-4
            }
        }
    }

    /// One full switch (cold or cached) **and** wait until the full-rung key is really in the table.
    @discardableResult
    private func settleFull(_ controller: LoupeController, _ url: URL,
                            _ identity: String) throws -> CanvasFrameCache.Key {
        let start = beginSwitch(controller, url, identity)
        XCTAssertTrue(waitForFullFrame(controller, identity, from: start),
                      "\(identity): the full rung never reached the layer "
                        + "(last error: \(controller.lastPresentError ?? "—"))")
        let key = try XCTUnwrap(controller.lastCanvasFrameCacheKey)
        XCTAssertTrue(waitFor { controller.canvasFrameCache.contains(key) },
                      "\(identity): the settled frame never reached the canvas cache")
        pump(0.1)
        return key
    }

    /// The deterministic form of 「A 停在 0.5 那一帧就被切走」: replace A's full entry with the same
    /// canvas at `decodeScale`, as 535 would have written it when the screen frame was the preview.
    /// The soft identity is unchanged, which is exactly what makes it the same canvas.
    private func seedCachedEntry(_ controller: LoupeController, key: CanvasFrameCache.Key,
                                 decodeScale: Float) throws {
        let coarseKey = CanvasFrameCache.Key(
            photo: key.photo, decodeInputs: key.decodeInputs, editDigest: key.editDigest,
            geometry: key.geometry, cameraState: key.cameraState, viewport: key.viewport,
            mode: key.mode, fitScale: key.fitScale, canvasRole: key.canvasRole,
            cropIsActive: key.cropIsActive, highlightWarning: key.highlightWarning,
            headroom: key.headroom, decodeScale: Double(decodeScale),
            primaries: key.primaries, highlightCeiling: key.highlightCeiling)
        XCTAssertEqual(coarseKey.softIdentity, key.softIdentity,
                       "the seeded entry is not the same canvas")
        let frame = try dummyFrame(decodeScale: decodeScale, photo: key.photo,
                                   primaries: OutputPrimaries(rawValue: key.primaries) ?? .displayP3)
        XCTAssertTrue(controller.canvasFrameCache.store(frame, key: coarseKey),
                      "the test could not seed the coarser entry")
    }

    private func dummyFrame(decodeScale: Float, photo: String,
                            primaries: OutputPrimaries) throws -> LoupeController.FrameResult {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let size = Self.viewport
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: size.width, height: size.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let rect = ImageRect(x: 0, y: 0, width: size.width, height: size.height)
        var frame = LoupeController.FrameResult(
            texture: texture, canvas: size, content: size, photoRect: rect, presentRect: rect,
            outputWindow: nil, decodeScale: decodeScale, decodeMilliseconds: 0,
            renderMilliseconds: 0, usedCachedDecode: true, capabilities: nil,
            primaries: primaries, editRevision: 0, edit: .neutral, displayHash: nil,
            zoom: 1, headroom: 1, window: size, clipped: nil, sceneLinearSample: nil,
            mode: .edited, trace: RenderTrace(), whiteBalanceGain: SIMD3<Double>(1, 1, 1),
            frameInCanvas: size, frameOrigin: SIMD2<Float>(0, 0), expandedCanvas: nil,
            neverUpscalesContent: false)
        frame.stamp(photo: photo)
        return frame
    }

    private func reasonCounts(_ controller: LoupeController) -> String {
        let r = controller.canvasCacheMissReasons
        return "noEntry=\(r[.noEntryForPhoto]) display=\(r[.displayChanged])"
            + " document=\(r[.documentChanged]) camera=\(r[.cameraChanged])"
            + " canvas=\(r[.canvasChanged]) decodeScale=\(r[.decodeScaleChanged])"
            + " coarser=\(r[.coarserRung])"
    }

    private func firstCacheRecord(_ controller: LoupeController, from start: Int,
                                  photo: String) -> LoupeController.FramePresentRecord? {
        controller.framePresentLog.dropFirst(start).first {
            $0.photo == photo && $0.fromCanvasCache
        }
    }

    // MARK: - ① 571-A: A at 0.5 → B → back to A does **not** use the 0.5 entry

    /// The user's sequence is unchanged; the answer is. With `coarserRungFloor = 1.0` the cached 0.5
    /// entry is coarser than the predicted 1.0, so the return is a miss (the 533 stand-in / the fresh
    /// full frame takes the canvas) — no 「切图先糊一下」 hop.
    func testReturningWithOnlyAPreviewRungEntryMissesInsteadOfShowingIt() throws {
        let photos = try rawFixtures(count: 2)
        let controller = makeController()
        let cache = controller.canvasFrameCache
        let a = "coarse542-a"
        let b = "coarse542-b"

        // A is on screen and cached; replace its entry with the 0.5 frame 535 could have kept.
        let keyA = try settleFull(controller, photos[0], a)
        try seedCachedEntry(controller, key: keyA, decodeScale: DecodeLadder.previewScale)
        // Visiting B pushes A's rung out of the one-photo ladder: the return predicts 1.0.
        try settleFull(controller, photos[1], b)

        let hitsBefore = cache.hits
        let coarserBefore = controller.canvasCacheMissReasons[.coarserRung]
        let missesBefore = cache.misses
        let scaleChangedBefore = controller.canvasCacheMissReasons[.decodeScaleChanged]
        let presentsBefore = controller.canvasCachePresents

        let start = beginSwitch(controller, photos[0], a)
        XCTAssertTrue(waitForFullFrame(controller, a, from: start),
                      "the return to A never produced the full frame")

        XCTAssertEqual(cache.hits, hitsBefore, "a coarser entry must not answer the 1.0 request")
        XCTAssertEqual(cache.misses, missesBefore + 1, "the return is a miss")
        XCTAssertEqual(controller.canvasCacheMissReasons[.decodeScaleChanged],
                       scaleChangedBefore + 1,
                       "the miss must name the rung component")
        XCTAssertEqual(controller.canvasCacheMissReasons[.coarserRung], coarserBefore,
                       "the entry was rejected before the coarser-hit counter (floor 1.0)")
        XCTAssertEqual(controller.canvasCachePresents, presentsBefore,
                       "the 0.5 entry must not reach the layer")
        XCTAssertNil(firstCacheRecord(controller, from: start, photo: a),
                     "a sub-full entry was presented: \(reasonCounts(controller))")
        print("[542] ①  return miss · \(reasonCounts(controller))")
    }

    // MARK: - ② the exact path is unchanged

    func testAnEntryAtTheRequestedRungHitsExactlyWithoutTheCoarserCounter() throws {
        let photos = try rawFixtures(count: 2)
        let controller = makeController()
        let cache = controller.canvasFrameCache
        let a = "coarse542-exact-a"
        let b = "coarse542-exact-b"

        try settleFull(controller, photos[0], a)
        try settleFull(controller, photos[1], b)

        let hitsBefore = cache.hits
        let coarserBefore = controller.canvasCacheMissReasons[.coarserRung]
        let presentsBefore = controller.canvasCachePresents

        let start = beginSwitch(controller, photos[0], a)
        XCTAssertTrue(waitFor(10) { controller.canvasCachePresents > presentsBefore },
                      "the exact-rung return did not hit the cache")

        XCTAssertEqual(cache.hits, hitsBefore + 1)
        XCTAssertEqual(controller.canvasCacheMissReasons[.coarserRung], coarserBefore,
                       "an exact hit must not use the coarser counter")
        let record = try XCTUnwrap(firstCacheRecord(controller, from: start, photo: a))
        XCTAssertEqual(record.decodeScale, DecodeLadder.fullScale, accuracy: 1e-4)
    }

    // MARK: - ③ the floor: 0.25 for a 1.0 request is a miss

    func testAnEntryBelowTheFloorIsNotServedAsIfItWereTheCanvas() throws {
        let photos = try rawFixtures(count: 2)
        let controller = makeController()
        let cache = controller.canvasFrameCache
        let a = "coarse542-floor-a"
        let b = "coarse542-floor-b"

        let keyA = try settleFull(controller, photos[0], a)
        // 0.25 / 1.0 = 0.25 < 0.5: visibly blurry, must not pretend to be the full canvas.
        try seedCachedEntry(controller, key: keyA, decodeScale: 0.25)
        try settleFull(controller, photos[1], b)

        let hitsBefore = cache.hits
        let coarserBefore = controller.canvasCacheMissReasons[.coarserRung]
        let scaleChangedBefore = controller.canvasCacheMissReasons[.decodeScaleChanged]
        let presentsBefore = controller.canvasCachePresents

        let start = beginSwitch(controller, photos[0], a)
        XCTAssertTrue(waitForFullFrame(controller, a, from: start),
                      "the fallback render never produced A's full frame")

        XCTAssertEqual(controller.canvasCachePresents, presentsBefore,
                       "the 0.25 entry must not be presented for a 1.0 request")
        XCTAssertNil(firstCacheRecord(controller, from: start, photo: a),
                     "a below-floor entry reached the layer")
        XCTAssertEqual(cache.hits, hitsBefore, "a below-floor entry is not a hit")
        XCTAssertEqual(controller.canvasCacheMissReasons[.coarserRung], coarserBefore,
                       "a below-floor entry must not be counted as a coarser hit")
        XCTAssertEqual(controller.canvasCacheMissReasons[.decodeScaleChanged],
                       scaleChangedBefore + 1,
                       "the miss must still name the rung component")
        XCTAssertNotEqual(controller.firstFrameContent, .canvasCache,
                          "the first frame of the return must not claim a cached canvas")
        print("[542] ③  floor miss · \(reasonCounts(controller))"
              + " · firstFrame=\(controller.firstFrameContent)")
    }

    // MARK: - ④ the full frame upgrades the entry; the next return is exact

    func testTheFullFrameUpgradesTheCoarseEntryAndTheNextReturnIsExact() throws {
        let photos = try rawFixtures(count: 2)
        let controller = makeController()
        let cache = controller.canvasFrameCache
        let a = "coarse542-upgrade-a"
        let b = "coarse542-upgrade-b"

        let keyA = try settleFull(controller, photos[0], a)
        try seedCachedEntry(controller, key: keyA, decodeScale: DecodeLadder.previewScale)
        try settleFull(controller, photos[1], b)
        let storesBefore = cache.stores
        let presentsBefore = controller.canvasCachePresents

        // First return: the 0.5 entry misses; the real full frame lands and replaces the same entry.
        let firstReturn = beginSwitch(controller, photos[0], a)
        XCTAssertTrue(waitForFullFrame(controller, a, from: firstReturn),
                      "the full frame that upgrades the entry never arrived")
        XCTAssertEqual(controller.canvasCachePresents, presentsBefore,
                       "571-A: the 0.5 entry must not be presented on the way")
        pump(0.1)

        let upgraded = try XCTUnwrap(cache.cachedCanvas(matching: keyA),
                                     "the entry disappeared while it should have been upgraded")
        XCTAssertEqual(upgraded.decodeScale, DecodeLadder.fullScale, accuracy: 1e-4,
                       "the full frame must overwrite the same soft identity at 1.0")
        XCTAssertEqual(cache.stores, storesBefore,
                       "replacing the entry is not a new store")

        // Leave and come back: now the request matches exactly.
        try settleFull(controller, photos[1], b)
        let hitsBefore = cache.hits
        let coarserBefore = controller.canvasCacheMissReasons[.coarserRung]
        let presentsBeforeSecond = controller.canvasCachePresents

        let secondReturn = beginSwitch(controller, photos[0], a)
        XCTAssertTrue(waitFor(10) { controller.canvasCachePresents > presentsBeforeSecond },
                      "the second return did not hit the cache")
        XCTAssertEqual(cache.hits, hitsBefore + 1)
        XCTAssertEqual(controller.canvasCacheMissReasons[.coarserRung], coarserBefore,
                       "after the upgrade the return must be an exact hit")
        let record = try XCTUnwrap(firstCacheRecord(controller, from: secondReturn, photo: a))
        XCTAssertEqual(record.decodeScale, DecodeLadder.fullScale, accuracy: 1e-4,
                       "the upgraded entry must be served at 1.0")
        print("[542] ④  upgrade · stores \(storesBefore) → \(cache.stores)"
              + " · entry=\(upgraded.decodeScale) · \(reasonCounts(controller))")
    }

    // MARK: - ⑤ reverse gate: turning coarser acceptance off keeps the same miss

    func testReverseGateExactRungOnlyMakesTheReturnMiss() throws {
        let photos = try rawFixtures(count: 2)
        let controller = makeController()
        let cache = controller.canvasFrameCache
        let a = "coarse542-gate-a"
        let b = "coarse542-gate-b"

        let keyA = try settleFull(controller, photos[0], a)
        try seedCachedEntry(controller, key: keyA, decodeScale: DecodeLadder.previewScale)
        try settleFull(controller, photos[1], b)

        CanvasFrameCache.acceptsCoarserRung = false
        let hitsBefore = cache.hits
        let coarserBefore = controller.canvasCacheMissReasons[.coarserRung]
        let scaleChangedBefore = controller.canvasCacheMissReasons[.decodeScaleChanged]
        let presentsBefore = controller.canvasCachePresents

        let start = beginSwitch(controller, photos[0], a)
        XCTAssertTrue(waitForFullFrame(controller, a, from: start),
                      "the reverse-gate return never produced a real frame")

        XCTAssertEqual(cache.hits, hitsBefore, "with the gate off the 0.5 entry must not hit")
        XCTAssertEqual(controller.canvasCachePresents, presentsBefore,
                       "with the gate off the cached frame must not reach the layer")
        XCTAssertEqual(controller.canvasCacheMissReasons[.coarserRung], coarserBefore)
        XCTAssertEqual(controller.canvasCacheMissReasons[.decodeScaleChanged],
                       scaleChangedBefore + 1,
                       "the miss must be named decodeScaleChanged")
        XCTAssertNil(firstCacheRecord(controller, from: start, photo: a))
        print("[542] ⑤  reverse gate · missReasons \(reasonCounts(controller))")
    }
}
