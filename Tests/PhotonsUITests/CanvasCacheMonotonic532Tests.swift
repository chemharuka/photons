import XCTest
import AppKit
import Metal
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 532 — 切图时缓存帧之后不许再被「低分辨率预览级」顶掉。
///
/// 用户看到的三跳：缓存帧（全分辨）→ 0.5 预览级放大（像素不够、变模糊）→ 全分辨。中间那一跳是
/// **像素数不足的一帧**，不是锐化没跟上。本套件用真库、真解码、真 present 记录每一次上屏的
/// `(kind, decodeScale, fromCanvasCache)`（`LoupeController.framePresentLog`），断言：
///
///   1. 缓存帧之后、target 帧之前，没有任何 `decodeScale` 更小的帧；
///   2. 关掉单调门 ⇒ 序列里必须出现「0.5 夹在中间」（反向门，证明 ① 会为该原因变红）；
///   3. 冷启动/无缓存时 0.5 → 1.0 仍然照常（门只在屏上已有更清晰帧时生效）；
///   4. target 永不返回时，兜底时长后仍要上屏某一帧；
///   5. 缓存命中的屏上帧不被低清帧替换。
@MainActor
final class CanvasCacheMonotonic532Tests: XCTestCase {

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
        super.tearDown()
    }

    // MARK: - fixtures / harness

    /// `count` distinct, readable DNGs from the same directory as the configured fixture.
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

    /// Start one switch; returns the index the new present records begin at.
    @discardableResult
    private func beginSwitch(_ controller: LoupeController, _ url: URL, _ identity: String,
                             state: LoupeViewState = .fit) -> Int {
        let start = controller.framePresentLog.count
        controller.frameSource = source(url, identity, state: state)
        controller.scheduleRender()
        return start
    }

    /// Wait until a real (non-cache) target-rung frame for `identity` has reached the layer, then
    /// return the records this switch produced.
    @discardableResult
    private func finishSwitch(_ controller: LoupeController, _ identity: String,
                              from start: Int) -> [LoupeController.FramePresentRecord] {
        let reached = waitFor {
            controller.framePresentLog.dropFirst(start).contains {
                $0.photo == identity && !$0.fromCanvasCache
                    && $0.decodeScale >= DecodeLadder.fullScale - 1e-4
            }
        }
        XCTAssertTrue(reached, "\(identity): the target rung never reached the layer "
                      + "(last error: \(controller.lastPresentError ?? "—"))")
        // The settled frame's store lands inside the same present; let follow-ups drain so the next
        // step starts from a quiet table.
        pump(0.1)
        return Array(controller.framePresentLog.dropFirst(start))
    }

    /// One full switch: begin, wait for target, return the sequence.
    @discardableResult
    private func switchPhoto(_ controller: LoupeController, _ url: URL, _ identity: String)
        -> [LoupeController.FramePresentRecord] {
        let start = beginSwitch(controller, url, identity)
        return finishSwitch(controller, identity, from: start)
    }

    /// Warm one photo all the way into the 434 cache, so a later return is a hit.
    private func warm(_ controller: LoupeController, _ url: URL, _ identity: String) {
        _ = switchPhoto(controller, url, identity)
        XCTAssertNotNil(controller.lastCanvasFrameCacheKey)
        if let key = controller.lastCanvasFrameCacheKey {
            XCTAssertTrue(controller.canvasFrameCache.contains(key),
                          "\(identity) never reached the canvas cache")
        }
    }

    private func describe(_ records: [LoupeController.FramePresentRecord]) -> String {
        records.map {
            "\($0.kind)\($0.fromCanvasCache ? "/cache" : "")@\($0.decodeScale)"
        }.joined(separator: " → ")
    }

    /// ① — a cache frame is never followed by a softer frame before the target rung.
    ///
    /// Ten switches across five real photos, so the first visit to each is a miss and every return is
    /// a window-cache hit (≥ 2 hits, as the ticket requires).
    func testTenSwitchesNeverPresentASofterFrameAfterTheCacheFrame() throws {
        let photos = try rawFixtures(count: 5)
        let identities = (0..<photos.count).map { "mono532-\($0)" }
        let controller = makeController()

        // Warm each photo (five misses).
        for index in 0..<photos.count {
            warm(controller, photos[index], identities[index])
        }

        let hitsBefore = controller.canvasFrameCacheDiagnostics.hits
        var hitSwitches = 0
        var cachePresents = 0
        let suppressedBefore = controller.monotonicSuppressedPresents
        var lines: [String] = []

        // Ten switches over the warmed five: every one of these must be a hit.
        for step in 0..<10 {
            let index = step % photos.count
            let identity = identities[index]
            let records = switchPhoto(controller, photos[index], identity)
            lines.append("step \(step) \(identity): \(describe(records))")

            guard let cacheIndex = records.firstIndex(where: {
                $0.photo == identity && $0.fromCanvasCache
            }) else {
                XCTFail("step \(step) \(identity) was not a cache hit: \(describe(records))")
                continue
            }
            hitSwitches += 1
            cachePresents += records.filter { $0.fromCanvasCache }.count
            let cacheScale = records[cacheIndex].decodeScale
            XCTAssertEqual(cacheScale, DecodeLadder.fullScale, accuracy: 1e-4,
                           "step \(step): the cache frame must be the full canvas")

            // Everything after the cache frame, until the target frame, must be at least as sharp.
            var targetSeen = false
            for record in records[(cacheIndex + 1)...] {
                if record.decodeScale < cacheScale - 1e-4 {
                    XCTFail("step \(step) \(identity): a softer frame came after the cache frame "
                            + "(\(record.kind)@\(record.decodeScale) < \(cacheScale)): "
                            + describe(records))
                }
                if !record.fromCanvasCache, record.decodeScale >= cacheScale - 1e-4 {
                    targetSeen = true
                    break
                }
            }
            XCTAssertTrue(targetSeen, "step \(step): no target frame after the cache frame")
        }

        // 571-A: there is no 0.5 frame for the gate to hold any more, so it is a pure safety net.
        XCTAssertEqual(controller.monotonicSuppressedPresents, suppressedBefore,
                       "571-A: the canvas no longer produces a softer frame to suppress")
        XCTAssertGreaterThanOrEqual(hitSwitches, 2, "at least two switches must hit the cache")
        XCTAssertEqual(hitSwitches, 10, "every return to a warmed photo must hit")
        XCTAssertEqual(cachePresents, 10, "one cached present (and only one) per hit")
        XCTAssertEqual(controller.canvasFrameCacheDiagnostics.hits, hitsBefore + 10)
        print("[532] ①  ten switches:\n" + lines.joined(separator: "\n"))
    }

    /// ② — 571-A: with the monotonic gate **off** there is still no softer frame between the cache
    /// frame and the target, because the ladder no longer produces one. The gate's reverse switch keeps
    /// working (proved by ④), but it no longer has a mid-switch hop to remove.
    func testWithoutTheGateNoSofterFrameExistsToPresent() throws {
        let photos = try rawFixtures(count: 2)
        let controller = makeController()
        warm(controller, photos[0], "mono532-rev-a")
        warm(controller, photos[1], "mono532-rev-b")

        controller.enforcesMonotonicPresentScale = false
        let records = switchPhoto(controller, photos[0], "mono532-rev-a")
        let line = describe(records)
        print("[532] ② 571-A gate off: \(line)")

        guard let cacheIndex = records.firstIndex(where: { $0.fromCanvasCache }),
              let targetIndex = records[(cacheIndex + 1)...].firstIndex(where: {
                  !$0.fromCanvasCache && $0.decodeScale >= DecodeLadder.fullScale - 1e-4
              }) else {
            return XCTFail("the reverse-gate switch did not produce cache → target: \(line)")
        }
        let softer = records[(cacheIndex + 1)..<targetIndex].contains {
            $0.decodeScale < DecodeLadder.fullScale - 1e-4
        }
        XCTAssertFalse(softer, "571-A: no 0.5 frame exists, so none can sit between cache and target: "
                       + line)
    }

    /// ③ — 571-A: a cold start presents the full rung and nothing before it.
    func testColdStartPresentsTheFullRungOnly() throws {
        let photos = try rawFixtures(count: 1)
        let controller = makeController()
        let records = switchPhoto(controller, photos[0], "mono532-cold")
        let line = describe(records)
        print("[532] ③  cold start: \(line)")

        XCTAssertFalse(records.contains { $0.fromCanvasCache },
                       "a cold start has nothing in the cache")
        XCTAssertFalse(records.contains { $0.decodeScale < DecodeLadder.fullScale - 1e-4 },
                       "571-A: the cold start must not present a half-resolution frame: \(line)")
        XCTAssertTrue(records.contains { $0.decodeScale >= DecodeLadder.fullScale - 1e-4 },
                      "the full rung must reach the canvas: \(line)")
        XCTAssertEqual(controller.monotonicSuppressedPresents, 0,
                       "the gate must not touch a cold start")
    }

    /// ④ — the target rung never returns: after the deadline a frame must still reach the layer.
    ///
    /// The window is armed the way a cache hit arms it — `armMonotonicPresentGateForTesting` stands in
    /// for the hit so the test controls the second half exactly — and the only frame offered is the
    /// 0.5 preview. Nothing sharper ever arrives, which is what a failed or cancelled full decode
    /// looks like to the present path.
    func testFallbackPresentsAHeldFrameWhenTheTargetNeverArrives() throws {
        let controller = makeController()
        controller.monotonicPresentTimeout = 0.2
        let photo = "mono532-fallback"
        controller.armMonotonicPresentGateForTesting(photo: photo, scale: DecodeLadder.fullScale)

        let frame = try dummyFrame(decodeScale: DecodeLadder.previewScale, photo: photo)
        controller.presentForTesting(frame, state: .fit)
        XCTAssertEqual(controller.monotonicSuppressedPresents, 1,
                       "the 0.5 frame must be held, not drawn")
        let recordsAfterHold = controller.framePresentLog.count

        XCTAssertTrue(waitFor(3) { controller.monotonicFallbackPresents == 1 },
                      "the deadline never released the held frame")
        XCTAssertEqual(controller.framePresentLog.count, recordsAfterHold + 1,
                       "the fallback must present exactly the held frame")
        XCTAssertEqual(controller.lastPresentedScale, DecodeLadder.previewScale)
        XCTAssertGreaterThan(controller.lastPresentedScale ?? 0, 0)
        XCTAssertNotEqual(controller.presentationContentForTesting, "empty",
                          "the fallback frame must be on the canvas")
        print("[532] ④  fallback: \(describe(controller.framePresentLog))")
    }

    /// ⑤ — the cache frame on the layer is not replaced by a low-resolution present.
    func testTheCacheFrameIsNotReplacedBeforeTheTargetArrives() throws {
        let photos = try rawFixtures(count: 2)
        let controller = makeController()
        warm(controller, photos[0], "mono532-hold-a")
        warm(controller, photos[1], "mono532-hold-b")

        let cachePresentsBefore = controller.canvasCachePresents
        let records = switchPhoto(controller, photos[0], "mono532-hold-a")
        let line = describe(records)
        print("[532] ⑤  hit switch: \(line)")

        XCTAssertEqual(controller.canvasCachePresents, cachePresentsBefore + 1,
                       "a hit switch presents the cached canvas exactly once")
        guard let cacheIndex = records.firstIndex(where: { $0.fromCanvasCache }) else {
            return XCTFail("the return to A did not hit the cache: \(line)")
        }
        guard let targetOffset = records[(cacheIndex + 1)...].firstIndex(where: {
            !$0.fromCanvasCache && $0.decodeScale >= DecodeLadder.fullScale - 1e-4
        }) else {
            return XCTFail("no target frame after the cache frame: \(line)")
        }
        let between = records[(cacheIndex + 1)..<targetOffset]
        XCTAssertTrue(between.isEmpty,
                      "a frame reached the layer between the cache frame and the target: "
                      + between.map { "\($0.kind)@\($0.decodeScale)" }.joined(separator: ", "))
    }

    // MARK: - a Metal frame for the fallback window

    private func dummyFrame(decodeScale: Float, photo: String) throws -> LoupeController.FrameResult {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let size = ImageSize(width: 64, height: 64)
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
            primaries: .displayP3, editRevision: 0, edit: .neutral, displayHash: nil,
            zoom: 1, headroom: 1, window: size, clipped: nil, sceneLinearSample: nil,
            mode: .edited, trace: RenderTrace(), whiteBalanceGain: SIMD3<Double>(1, 1, 1),
            frameInCanvas: size, frameOrigin: SIMD2<Float>(0, 0), expandedCanvas: nil,
            neverUpscalesContent: false)
        frame.stamp(photo: photo)
        return frame
    }
}
