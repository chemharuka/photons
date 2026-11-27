import XCTest
import AppKit
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 571-A — 画布只出两种画面：1920 px 预览图（533 占位），或整幅渲染。
///
/// The user's rule (2026-11-26): 「取消任何半分辨率相关的内容，即要么用 1920px 预览图，要么全分辨率
/// 渲染，不允许先出半分辨率」. This suite pins the five facts of the canvas side of that change:
///
///   1. `DecodeLadder.plan` is single-rung: a cold target plans no preview.
///   2. A live frame never presents a `decodeScale < 1.0`; the canvas is the stand-in until the full
///      development lands.
///   3. A held 细节 slider requests **no** development; the settle after the hand stops does exactly
///      one full development, and the canvas keeps the previous full frame in between.
///   4. A canvas-cache entry at 0.5 does not answer a 1.0 request (floor 1.0).
///   5. A whole-picture frame still hits the ladder's own cache on the second request.
@MainActor
final class NoHalfResCanvas571Tests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        RAWDecoder.resetDecodeCounts()
        super.tearDown()
    }

    // MARK: - fixtures

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

    private func source(_ url: URL, identity: String = "nohalf571",
                        edit: EditModel = .neutral) -> LoupeController.FrameSource {
        LoupeController.FrameSource(url: url, identity: identity, viewport: Self.viewport,
                                    state: .fit, edit: edit)
    }

    private func makeController(_ source: LoupeController.FrameSource) -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        controller.frameSource = source
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        return controller
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 180, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    // MARK: - 1. the ladder is single-rung

    func testNoHalfRes571ColdTargetPlansNoPreviewRung() {
        let ladder = DecodeLadder()
        let plan = ladder.plan(identity: "photo", target: DecodeLadder.fullScale)
        XCTAssertNil(plan.preview, "571-A: a cold request must not plan the 0.5 preview")
        XCTAssertEqual(plan.rungs, [DecodeLadder.fullScale])
    }

    // MARK: - 2. the canvas never presents a half frame

    func testNoHalfRes571CanvasNeverPresentsBelowFullScale() throws {
        let url = try rawFixture()
        let controller = makeController(source(url))
        controller.autoRenderEnabled = true
        controller.scheduleRender()

        XCTAssertTrue(waitFor { controller.lastPresentedScale == DecodeLadder.fullScale },
                      "the full frame never reached the canvas")
        let scales = controller.framePresentLog.map(\.decodeScale)
        XCTAssertFalse(scales.isEmpty, "nothing was presented")
        XCTAssertFalse(scales.contains { $0 < DecodeLadder.fullScale - 1e-4 },
                       "571-A: the canvas presented a sub-full frame: \(scales)")
        XCTAssertEqual(controller.lastPresentedScale, DecodeLadder.fullScale)
    }

    // MARK: - 3. a held detail slider requests nothing; the settle does one full development

    func testNoHalfRes571HeldDetailSliderDevelopsNothing() throws {
        let url = try rawFixture()
        let controller = makeController(source(url))
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        XCTAssertTrue(waitFor { controller.lastPresentedScale == DecodeLadder.fullScale },
                      "the initial full frame never landed")
        pump(0.1)
        RAWDecoder.resetDecodeCounts()
        let presentsBefore = controller.framePresentLog.count
        let requestsBefore = controller.viewRenderRequests
        let stateBefore = controller.viewState

        controller.beginDetailAdjustment()
        for step in 1...5 {
            var edit = EditModel.neutral
            edit.detailSettings.luminanceNR = Double(step * 10)
            controller.frameSource = source(url, edit: edit)   // a tick, as the harness spells it
            controller.requestViewportRender()
        }

        // ① not one development while the slider is held.
        XCTAssertEqual(RAWDecoder.decodeCounts()[DecodeLadder.fullScale] ?? 0, 0,
                       "571-A: a held detail slider must not develop the full frame")
        XCTAssertEqual(controller.framePresentLog.count, presentsBefore,
                       "571-A: a held detail slider must not draw a new frame")
        XCTAssertEqual(controller.viewRenderRequests, requestsBefore,
                       "571-A: a held detail slider must not request a canvas frame")
        XCTAssertEqual(controller.lastPresentedScale, DecodeLadder.fullScale,
                       "the canvas stays on the previous full frame during the drag")

        // ② the hand stops: exactly one full development, one new frame.
        controller.endDetailAdjustment()
        XCTAssertTrue(waitFor {
            controller.framePresentLog.dropFirst(presentsBefore).contains {
                $0.photo == "nohalf571" && $0.decodeScale >= DecodeLadder.fullScale - 1e-4
            }
        }, "the settle never put a full frame on the canvas")
        XCTAssertEqual(RAWDecoder.decodeCounts()[DecodeLadder.fullScale] ?? 0, 1,
                       "the settle must develop the full rung exactly once")
        XCTAssertEqual(controller.viewState, stateBefore, "the settle moved the camera")
    }

    // MARK: - 4. a coarser cache entry is not served

    func testNoHalfRes571CoarseCacheEntryMisses() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let cache = CanvasFrameCache(device: device)
        XCTAssertEqual(CanvasFrameCache.coarserRungFloor, 1.0,
                       "571-A ships the floor at 1.0 (the shipped default is the gate)")

        let key = CanvasFrameCache.Key(
            photo: "nohalf571-cache", decodeInputs: "neutral", editDigest: "digest",
            geometry: "geometry", cameraState: "fit", viewport: Self.viewport,
            mode: "edited", fitScale: 1, canvasRole: "document", cropIsActive: false,
            highlightWarning: false, headroom: 1,
            decodeScale: Double(DecodeLadder.previewScale), primaries: OutputPrimaries.displayP3.rawValue)
        let frame = try dummyFrame(device: device, decodeScale: DecodeLadder.previewScale,
                                   photo: key.photo, primaries: .displayP3)
        XCTAssertTrue(cache.store(frame, key: key), "the 0.5 entry could not be seeded")

        let hitsBefore = cache.hits
        let missesBefore = cache.misses
        let scaleChangedBefore = cache.missReasons[.decodeScaleChanged]

        let served = cache.lookup(key, headroom: 1, primaries: .displayP3,
                                  decodeScale: Double(DecodeLadder.fullScale))
        XCTAssertNil(served, "571-A: a 0.5 entry must not answer a 1.0 request")
        XCTAssertEqual(cache.hits, hitsBefore, "the coarser entry is not a hit")
        XCTAssertEqual(cache.misses, missesBefore + 1, "the request is a miss")
        XCTAssertEqual(cache.missReasons[.decodeScaleChanged], scaleChangedBefore + 1,
                       "the miss must name the rung component")
        let stillCached = try XCTUnwrap(cache.cachedCanvas(matching: key))
        XCTAssertEqual(Float(stillCached.decodeScale), DecodeLadder.previewScale, accuracy: 1e-4,
                       "the 0.5 entry must stay in the table; it just must not be served")
    }

    // MARK: - 5. the full rung still hits

    func testNoHalfRes571SecondFullFrameUsesLadderCache() throws {
        let url = try rawFixture()
        let controller = LoupeController(session: CatalogSession())
        controller.collectsHistogram = false

        let first = try controller.makeFrame(url: url, viewport: Self.viewport,
                                             decodeScale: DecodeLadder.fullScale,
                                             edit: .neutral, state: .fit)
        XCTAssertFalse(first.usedCachedDecode, "the first full frame is the development")
        XCTAssertEqual(first.decodeScale, DecodeLadder.fullScale)

        let second = try controller.makeFrame(url: url, viewport: Self.viewport,
                                              decodeScale: DecodeLadder.fullScale,
                                              edit: .neutral, state: .fit)
        XCTAssertTrue(second.usedCachedDecode,
                      "571-A: the second full frame must reuse the resident rung")
        XCTAssertEqual(second.decodeScale, DecodeLadder.fullScale)
    }

    // MARK: - fixtures

    private func dummyFrame(device: MTLDevice, decodeScale: Float, photo: String,
                            primaries: OutputPrimaries) throws -> LoupeController.FrameResult {
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
            primaries: primaries, editRevision: 0, edit: .neutral, displayHash: nil,
            zoom: 1, headroom: 1, window: size, clipped: nil, sceneLinearSample: nil,
            mode: .edited, trace: RenderTrace(), whiteBalanceGain: SIMD3<Double>(1, 1, 1),
            frameInCanvas: size, frameOrigin: SIMD2<Float>(0, 0), expandedCanvas: nil,
            neverUpscalesContent: false)
        frame.stamp(photo: photo)
        return frame
    }
}
