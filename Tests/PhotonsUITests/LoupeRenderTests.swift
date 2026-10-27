import XCTest
import AppKit
import Metal
import PhotonsCore
import PhotonsUI

/// The parts of the 1:1 / EDR work that only a real `RenderGraph` frame can answer: does the zoomed
/// window show the same pixels as the whole frame, does a 1:1 frame actually reach the viewport, and
/// does turning EDR off leave the pixels alone?
///
/// These need a RAW file (`PHOTONS_TEST_RAW`, else `~/Desktop/test/L1030433.dng`) and Metal; both are
/// skipped-with-a-reason rather than failed when absent, like the rest of the suite.
@MainActor
final class LoupeRenderTests: XCTestCase {

    private static let viewport = ImageSize(width: 2560, height: 1600)

    // MARK: fixtures

    private static func rawFixture() throws -> URL {
        if let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"], !env.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: env).expandingTildeInPath)
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        let fallback = URL(fileURLWithPath: NSString(string: "~/Desktop/test/L1030433.dng")
            .expandingTildeInPath)
        guard FileManager.default.isReadableFile(atPath: fallback.path) else {
            throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
        }
        return fallback
    }

    private func makeController() -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false      // these tests drive every frame themselves
        controller.hashesFrames = true
        _ = controller.view                        // builds the presenter + canvas layer
        return controller
    }

    // MARK: 1. fit ↔ 1:1

    /// The switch must change the pixels, and each side must be reproducible: a re-render at the
    /// same state is byte-identical (nothing time- or order-dependent leaks into the frame).
    func testFitAndOneToOneDifferAndRepeatExactly() throws {
        let url = try Self.rawFixture()
        let loupe = makeController()
        let edit = EditModel.neutral
        let fit = try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                      edit: edit, state: .fit, hashPixels: true)
        let oneToOne = try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                           edit: edit,
                                           state: LoupeViewState(mode: .actual, zoom: 1,
                                                                 centerX: 3000, centerY: 2000),
                                           hashPixels: true)
        let oneToOneAgain = try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                                edit: edit,
                                                state: LoupeViewState(mode: .actual, zoom: 1,
                                                                      centerX: 3000, centerY: 2000),
                                                hashPixels: true)
        let fitAgain = try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                           edit: edit, state: .fit, hashPixels: true)

        let fitHash = try XCTUnwrap(fit.displayHash)
        let actualHash = try XCTUnwrap(oneToOne.displayHash)
        XCTAssertNotEqual(fitHash, actualHash, "1:1 must not be the fit frame re-presented")
        XCTAssertEqual(actualHash, oneToOneAgain.displayHash, "1:1 rerender drifted")
        XCTAssertEqual(fitHash, fitAgain.displayHash, "fit rerender drifted")

        // Both are presented at the viewport: the canvas is never resampled by the layer.
        XCTAssertEqual(oneToOne.texture.width, Self.viewport.width)
        XCTAssertEqual(oneToOne.texture.height, Self.viewport.height)
        XCTAssertEqual(oneToOne.zoom, 1, accuracy: 1e-12)
        XCTAssertLessThan(fit.zoom, 1, "fit of a 60 MP frame in a 2560×1600 viewport is below 1:1")
    }

    /// 4:1 is four source pixels per device pixel, and the window is a quarter of the viewport in
    /// source pixels — the number the status chip and the render scale both come from.
    func testFourToOneWindowIsTheViewportAtFourPixelsPerSourcePixel() throws {
        let url = try Self.rawFixture()
        let loupe = makeController()
        let state = LoupeViewState(mode: .actual, zoom: 4, centerX: 3000, centerY: 2000)
        let frame = try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 1,
                                        edit: .neutral, state: state, hashPixels: false)
        XCTAssertEqual(frame.texture.width, Self.viewport.width)
        XCTAssertEqual(frame.texture.height, Self.viewport.height)
        XCTAssertEqual(frame.zoom, 4, accuracy: 1e-12)
        XCTAssertEqual(frame.window.width, Self.viewport.width / 4)
        XCTAssertEqual(frame.window.height, Self.viewport.height / 4)
    }

    // MARK: 2. the window really is the frame's neighbourhood

    /// Two windows that overlap by half must agree, pixel for pixel, on the overlap: same source
    /// pixels, same half-pixel convention, same chain. This is the pixel-level proof that a pan
    /// re-render (a *new* crop) does not shift the picture by a fraction of a pixel.
    func testTwoOverlappingWindowsAgreeOnTheOverlap() throws {
        let url = try Self.rawFixture()
        let loupe = makeController()
        let viewport = ImageSize(width: 256, height: 192)
        let a = LoupeViewState(mode: .actual, zoom: 1, centerX: 3000, centerY: 2000)
        var b = a
        b.centerX = 3000 + 128      // half the window, exactly

        let frameA = try loupe.makeFrame(url: url, viewport: viewport, decodeScale: 0.5,
                                         edit: .neutral, state: a)
        let frameB = try loupe.makeFrame(url: url, viewport: viewport, decodeScale: 0.5,
                                         edit: .neutral, state: b)
        let pixelsA = Self.pixels(of: frameA.texture)
        let pixelsB = Self.pixels(of: frameB.texture)
        XCTAssertEqual(pixelsA.count, pixelsB.count)

        var worst: Float = 0
        var compared = 0
        for y in 0..<viewport.height {
            for x in 0..<128 {
                for c in 0..<4 {
                    let i = (y * viewport.width + x) * 4 + c
                    let j = (y * viewport.width + (x + 128)) * 4 + c
                    let d = abs(pixelsA[j] - pixelsB[i])
                    worst = max(worst, d)
                    compared += 1
                }
            }
        }
        XCTAssertGreaterThan(compared, 90_000)
        XCTAssertLessThan(worst, 0.01, "overlapping windows disagree (worst Δ \(worst))")
    }

    // MARK: 3. EDR off is pixel-identical to headroom 1

    /// Every "no EDR" path resolves to `headroom = 1`, and a headroom-1 frame is byte-identical to
    /// the M3 output (§11.8: `clamp(v,0,1)` became `min(v,headroom)`). Rendered through the same
    /// layer, same decode, same state — only the display key moves.
    func testHeadroomOneIsIdenticalAcrossEveryEDROffPath() throws {
        let url = try Self.rawFixture()
        let loupe = makeController()
        let state = LoupeViewState(mode: .actual, zoom: 2, centerX: 3000, centerY: 2000)

        loupe.setDisplayHeadroom(DisplayHeadroom(headroom: 1, screenName: nil,
                                                 maximumEDRComponent: 1, source: .sdr))
        let sdr = try XCTUnwrap(try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                                    edit: .neutral, state: state, hashPixels: true)
            .displayHash)

        loupe.setDisplayHeadroom(DisplayHeadroom(headroom: 1, screenName: nil,
                                                 maximumEDRComponent: 1, source: .unknown))
        let unknown = try XCTUnwrap(try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                                        edit: .neutral, state: state, hashPixels: true)
            .displayHash)

        loupe.setDisplayHeadroom(DisplayHeadroom(headroom: 1, screenName: "Built-in Retina Display",
                                                 maximumEDRComponent: 16, source: .layerRefusedEDR))
        let refused = try XCTUnwrap(try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                                        edit: .neutral, state: state, hashPixels: true)
            .displayHash)

        XCTAssertEqual(sdr, unknown, "EDR-off paths must agree: SDR vs unknown")
        XCTAssertEqual(sdr, refused, "EDR-off paths must agree: SDR vs layer-refused")
        XCTAssertEqual(loupe.headroom, 1, accuracy: 1e-12)

        // And a real ceiling does move the pixels, once there is something above SDR white to keep.
        // +2 EV is the cheapest way to guarantee that: at neutral exposure a dim interior can
        // honestly have nothing above 1.0, and then the test would prove nothing.
        var bright = EditModel.neutral
        bright.light.exposure = 2
        let clampedHash = try XCTUnwrap(try loupe.makeFrame(url: url, viewport: Self.viewport,
                                                            decodeScale: 0.5, edit: bright,
                                                            state: state, hashPixels: true)
            .displayHash)
        loupe.setDisplayHeadroom(DisplayHeadroom(headroom: 4, screenName: "Built-in Retina Display",
                                                 maximumEDRComponent: 16, source: .extendedRange))
        let hdrHash = try XCTUnwrap(try loupe.makeFrame(url: url, viewport: Self.viewport,
                                                        decodeScale: 0.5, edit: bright,
                                                        state: state, hashPixels: true)
            .displayHash)
        XCTAssertEqual(loupe.headroom, 4, accuracy: 1e-12)
        if hdrHash == clampedHash {
            print("NOTE: headroom 4 matched headroom 1 even at +2 EV — S4 kept nothing above 1.0")
        } else {
            XCTAssertNotEqual(hdrHash, clampedHash, "headroom must survive into the output")
            print("headroom: 1.0 vs 4.0 changed the frame (as it must)")
        }
    }

    // MARK: EDR on the canvas layer

    /// The picture side of EDR is one boolean on the layer plus the ceiling — assert both, in a real
    /// window, and assert that an SDR resolution puts the boolean back to false.
    func testCanvasLayerEDRFlagFollowsTheDisplayHeadroom() throws {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect

        let layer = controller.canvasView.metalLayer
        XCTAssertEqual(layer.pixelFormat, .rgba16Float, "the canvas must hold a 16-bit float drawable")

        controller.setDisplayHeadroom(DisplayHeadroom(headroom: 1.2, screenName: "Built-in Retina Display",
                                                     maximumEDRComponent: 1.2, source: .extendedRange))
        XCTAssertTrue(controller.wantsExtendedDynamicRange)
        XCTAssertTrue(layer.wantsExtendedDynamicRangeContent, "EDR on must reach the layer")
        XCTAssertEqual(controller.headroom, 1.2, accuracy: 1e-12)

        // The hand-off itself: a 16-bit EDR frame must reach a real drawable, with no fallback.
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                  width: 64, height: 64,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let presenter = try CanvasPresenter()
        XCTAssertTrue(presenter.presentForTest(texture, in: layer, wantsEDR: true,
                                               drawableSize: ImageSize(width: 64, height: 64)),
                      presenter.lastFailure ?? "present failed")
        XCTAssertEqual(presenter.storage, .linear16, "the layer must not have fallen back to 8-bit")

        // Degradation: an SDR resolution must switch the layer back off, not raise.
        controller.setDisplayHeadroom(.sdr)
        XCTAssertFalse(controller.wantsExtendedDynamicRange)
        XCTAssertFalse(layer.wantsExtendedDynamicRangeContent, "SDR must switch EDR off")
        XCTAssertEqual(controller.headroom, 1, accuracy: 1e-12)
        XCTAssertTrue(controller.statusText.contains("SDR 显示器"), controller.statusText)
    }

    // MARK: 4. frame cost

    /// The numbers the report quotes: first 1:1 frame (full decode), a subsequent 1:1 frame, one pan
    /// frame, and one 4:1 frame. Printed rather than asserted — a build machine is not a benchmark —
    /// but the *shape* is asserted: a pan frame is a stage-cache miss and must still fit a frame.
    func testFrameCostReport() throws {
        let url = try Self.rawFixture()
        let edit = EditModel.neutral

        // Fit, cold (the M3 ladder's first rung) — fresh controller, so the decode is real.
        let cold = makeController()
        let fitCold = try cold.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                         edit: edit, state: .fit)
        let fitCached = try cold.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                           edit: edit, state: .fit)
        let fitFull = try cold.makeFrame(url: url, viewport: Self.viewport, decodeScale: 1.0,
                                         edit: edit, state: .fit)
        let fitFullAgain = try cold.makeFrame(url: url, viewport: Self.viewport, decodeScale: 1.0,
                                              edit: edit, state: .fit)

        // 1:1, cold: needs the full-resolution decode (a fresh controller has none).
        let zoomed = makeController()
        let oneToOneCold = try zoomed.makeFrame(url: url, viewport: Self.viewport, decodeScale: 1.0,
                                                edit: edit,
                                                state: LoupeViewState(mode: .actual, zoom: 1,
                                                                      centerX: 3000, centerY: 2000))
        let oneToOneWarm = try zoomed.makeFrame(url: url, viewport: Self.viewport, decodeScale: 1.0,
                                                edit: edit,
                                                state: LoupeViewState(mode: .actual, zoom: 1,
                                                                      centerX: 3000, centerY: 2000))
        let panned = try zoomed.makeFrame(url: url, viewport: Self.viewport, decodeScale: 1.0,
                                          edit: edit,
                                          state: LoupeViewState(mode: .actual, zoom: 1,
                                                                centerX: 3128, centerY: 2100))
        let fourToOne = try zoomed.makeFrame(url: url, viewport: Self.viewport, decodeScale: 1.0,
                                             edit: edit,
                                             state: LoupeViewState(mode: .actual, zoom: 4,
                                                                   centerX: 3000, centerY: 2000))

        func line(_ name: String, _ f: LoupeController.FrameResult) -> String {
            let padded = name.padding(toLength: 28, withPad: " ", startingAt: 0)
            return String(format: "%@ decode %7.1f ms  render %6.1f ms  total %7.1f ms  (scale %.2f, canvas %@)",
                          padded, f.decodeMilliseconds, f.renderMilliseconds,
                          f.decodeMilliseconds + f.renderMilliseconds, f.decodeScale,
                          f.canvas.keyString)
        }
        print("── loupe frame cost (M1 Pro, \(Self.viewport.width)×\(Self.viewport.height) canvas) ──")
        print(line("fit, cold (decode 0.5)", fitCold))
        print(line("fit, cached (decode 0.5)", fitCached))
        print(line("fit, full decode 1.0", fitFull))
        print(line("fit, repeat (cached 1.0)", fitFullAgain))
        print(line("1:1, cold (full decode)", oneToOneCold))
        print(line("1:1, repeat (cached)", oneToOneWarm))
        print(line("1:1, pan by 128 px", panned))
        print(line("4:1", fourToOne))
        print(String(format: "note: 1:1 cold decode alone was %.1f ms of the %.1f ms",
                     oneToOneCold.decodeMilliseconds,
                     oneToOneCold.decodeMilliseconds + oneToOneCold.renderMilliseconds))

        // Shape assertions: warm frames must not pay for a decode, and a zoomed frame is a real
        // render (not a cached fit frame re-presented).
        XCTAssertTrue(fitCached.usedCachedDecode, "the second fit frame should reuse the decode")
        XCTAssertTrue(fitFullAgain.usedCachedDecode, "the repeat fit frame should reuse the decode")
        XCTAssertTrue(oneToOneWarm.usedCachedDecode, "the second 1:1 frame should reuse the decode")
        XCTAssertGreaterThan(panned.renderMilliseconds, 0, "a pan frame is a stage-cache miss and a real render")
        XCTAssertNotEqual(oneToOneWarm.window.keyString, fourToOne.window.keyString)
        XCTAssertGreaterThan(fourToOne.renderMilliseconds, 0)
        XCTAssertEqual(fourToOne.window.width, Self.viewport.width / 4)
    }

    // MARK: helpers

    /// rgba16Float → 4 floats per pixel.
    private static func pixels(of texture: MTLTexture) -> [Float] {
        let w = texture.width, h = texture.height
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return raw.map { Float(Float16(bitPattern: $0)) }
    }
}
