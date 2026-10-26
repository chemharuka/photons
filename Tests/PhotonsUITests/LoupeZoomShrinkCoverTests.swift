import XCTest
import AppKit
import Metal
import PhotonsCore
import PhotonsUI

/// 025 ③ — a shrink must not show an unrendered band.
///
/// The bug as reported: 缩小时，由于画面外没有渲染，会出现黑色遮罩然后再生成图像. A layer transform
/// shrinks the *layer*, so the canvas area the shrunken layer no longer covers is whatever is behind
/// it — the window's background, i.e. black — until the new frame lands.
///
/// The trade-off this implementation takes is the task's option (a), and it takes it structurally:
///
///   · the present quad **always covers the whole canvas** (it is a full-screen quad), so nothing on
///     the canvas is ever left unpainted;
///   · a shrinking frame's sampling window is *larger* than the texture (`du = 1/s > 1`, origin
///     negative), so every canvas pixel reads the nearest texel and `clamp_to_edge` extends the
///     picture's own edge outwards.
///
/// Two kinds of evidence, because either alone is weak: the per-frame window geometry (structural)
/// and the pixels the pass actually produces (a real render into a readback texture, at a real
/// window from a real 200 → 100 % transition).
@MainActor
final class LoupeZoomShrinkCoverTests: XCTestCase {

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

    /// Bounded, but generous: a frame is a render plus (when the harness hashes) a 32 MB readback, and
    /// on a machine running other test bundles that has been measured in the tens of seconds. The
    /// assertions here are about geometry, not speed, so a slow frame must not read as a broken one.
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

    private func frames(_ controller: LoupeController, _ command: () -> Void) -> [LoupeController.ZoomBridgeFrame] {
        let armed = controller.zoomBridgeArmedCount
        command()
        XCTAssertTrue(waitFor { controller.zoomBridge == nil }, "the bridge never ended")
        return controller.zoomBridgeFrames.filter { $0.serial > armed }
    }

    // MARK: - ① every shrinking frame covers the canvas

    func testEveryShrinkingFrameCoversTheWholeCanvas() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "shrink-cover")
        let point = CGPoint(x: 64, y: 140)
        controller.zoomToActualSize(aroundView: point)
        XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 1 })
        controller.zoom(to: 2, aroundView: point)
        XCTAssertTrue(waitFor { controller.zoomBridge == nil && controller.lastFrame?.zoom == 2 })
        pump(0.1)

        var lines: [String] = []
        let out = frames(controller) { controller.zoom(to: 1, aroundView: point) }
        XCTAssertGreaterThanOrEqual(out.count, 12)
        for f in out {
            let w = f.window
            // Progress 0 is the picture as it is (the identity window); from the first moving frame on,
            // the window is larger than the texture, so no canvas pixel reads an empty area and the
            // sampler's clamp turns the outside into the picture's own edge.
            XCTAssertGreaterThanOrEqual(w.du, 1 - 1e-6, "progress \(f.progress): du = \(w.du)")
            XCTAssertGreaterThanOrEqual(w.dv, 1 - 1e-6, "progress \(f.progress): dv = \(w.dv)")
            if f.progress > 0.05 {
                XCTAssertGreaterThan(w.du, 1, "progress \(f.progress): the canvas must read past the edge")
                XCTAssertGreaterThan(w.dv, 1)
            }
            XCTAssertLessThanOrEqual(w.u0, 1e-6, "progress \(f.progress): the window starts right of the texture")
            XCTAssertLessThanOrEqual(w.v0, 1e-6)
            XCTAssertGreaterThanOrEqual(w.u0 + w.du, 1 - 1e-6, "progress \(f.progress): the window stops short")
            XCTAssertGreaterThanOrEqual(w.v0 + w.dv, 1 - 1e-6)
            XCTAssertTrue(w.coversWholeTexture,
                          "progress \(f.progress): the canvas is not fully covered by the picture")
            if lines.count < 4 {
                lines.append(String(format: "        progress %.3f · window u[%.3f…%.3f] v[%.3f…%.3f] "
                                   + "· covers whole canvas", f.progress, w.u0, w.u0 + w.du, w.v0, w.v0 + w.dv))
            }
        }
        print("200→100 %: \(out.count) frames, every window larger than the texture\n"
              + lines.joined(separator: "\n"))

        // The crossing out of 1:1 has the same shape — and it is the one the user hit on ⌘0.
        pump(0.15)
        let fit = frames(controller) { controller.zoomToFit() }
        XCTAssertGreaterThanOrEqual(fit.count, 6)
        for f in fit {
            XCTAssertTrue(f.window.coversWholeTexture,
                          "100 %→fit progress \(f.progress): the canvas is not fully covered")
        }
        print("100 %→fit: \(fit.count) frames, last window u[\(String(format: "%.3f", fit.last!.window.u0))…"
              + "\(String(format: "%.3f", fit.last!.window.u0 + fit.last!.window.du))] — covers")
    }

    // MARK: - ② the pixels: the canvas is picture, not fill

    func testTheShrinkingCanvasIsFilledWithThePicturesOwnEdge() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let size = ImageSize(width: 64, height: 48)

        // A source that cannot be mistaken for the clear colour, with a distinct one-pixel border so
        // "clamped edge" and "stretched interior" are different answers.
        let interior: [Float] = [0.2, 0.4, 0.6, 1]
        let border: [Float] = [0.8, 0.2, 0.2, 1]
        let source = try XCTUnwrap(Self.makeTexture(device: device, size: size, format: .rgba16Float,
                                                    usage: [.shaderRead]))
        Self.fill(source, interior: interior, border: border)

        let target = try XCTUnwrap(Self.makeTexture(device: device, size: size, format: .rgba16Float,
                                                    usage: [.shaderRead, .renderTarget]))

        // A real shrinking frame's window, taken from the geometry the loupe uses (scale 1/2 about a
        // point a fifth of the way in — the middle of a 200 → 100 % transition).
        let canvas = size
        let window = PresentWindow(scale: 0.5, originX: Double(canvas.width) * 0.1,
                                   originY: Double(canvas.height) * 0.1,
                                   canvas: canvas, texture: size)
        XCTAssertTrue(window.coversWholeTexture, "a shrinking window must be bigger than the texture")
        XCTAssertGreaterThan(Double(window.du), 1)

        XCTAssertTrue(presenter.render(source, window: window, into: target, linearize: false),
                      presenter.lastFailure ?? "the present pass failed")
        let pixels = Self.read(target)

        // Every pixel of the canvas is real content: none is the pass's clear colour.
        let black = pixels.filter { $0[0] == 0 && $0[1] == 0 && $0[2] == 0 }
        XCTAssertEqual(black.count, 0, "\(black.count) of \(pixels.count) canvas pixels are unrendered black")
        // The corners read the *border* texel (clamp_to_edge), the middle the interior.
        func pixel(_ x: Int, _ y: Int) -> [Float] { pixels[y * size.width + x] }
        for (x, y) in [(0, 0), (size.width - 1, 0), (0, size.height - 1), (size.width - 1, size.height - 1)] {
            XCTAssertEqual(pixel(x, y)[0], border[0], accuracy: 1e-3,
                           "corner (\(x), \(y)) is not the picture's own edge")
            XCTAssertEqual(pixel(x, y)[1], border[1], accuracy: 1e-3)
        }
        XCTAssertEqual(pixel(size.width / 2, size.height / 2)[0], interior[0], accuracy: 1e-3,
                       "the middle of the canvas must show the picture, not the edge")

        // The counterexample: the same target, cleared and *not* covered, is exactly the black band the
        // report was about. It is the same amount of canvas the layer transform used to leave bare.
        let bare = try XCTUnwrap(Self.makeTexture(device: device, size: size, format: .rgba16Float,
                                                  usage: [.shaderRead, .renderTarget]))
        Self.clearToBlack(bare, device: device)
        let barePixels = Self.read(bare)
        XCTAssertEqual(barePixels.filter { $0[0] == 0 && $0[1] == 0 && $0[2] == 0 }.count, barePixels.count,
                       "the cleared target is the counterexample: black everywhere")
        print(String(format: "shrink frame (picture scale 0.5 about (%.1f, %.1f) px): %d canvas pixels, "
                     + "0 unrendered; corners = edge (%.2f, %.2f, %.2f), middle = picture (%.2f, %.2f, %.2f); "
                     + "a cleared target is black in all %d",
                     Double(canvas.width) * 0.1, Double(canvas.height) * 0.1,
                     pixels.count, border[0], border[1], border[2],
                     interior[0], interior[1], interior[2], barePixels.count))
    }

    // MARK: - texture helpers (rgba16Float, shared storage, CPU readable)

    private static func makeTexture(device: MTLDevice, size: ImageSize, format: MTLPixelFormat,
                                    usage: MTLTextureUsage) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                                  width: size.width, height: size.height,
                                                                  mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    private static func fill(_ texture: MTLTexture, interior: [Float], border: [Float]) {
        var row = [UInt16](repeating: 0, count: texture.width * 4)
        for x in 0..<texture.width {
            let isBorder = x == 0 || x == texture.width - 1
            let value = isBorder ? border : interior
            for c in 0..<4 { row[x * 4 + c] = Float16(value[c]).bitPattern }
        }
        for y in 0..<texture.height {
            let isBorderRow = y == 0 || y == texture.height - 1
            var current = row
            if isBorderRow {
                for x in 0..<texture.width {
                    for c in 0..<4 { current[x * 4 + c] = Float16(border[c]).bitPattern }
                }
            }
            current.withUnsafeBytes { buffer in
                texture.replace(region: MTLRegionMake2D(0, y, texture.width, 1), mipmapLevel: 0,
                                withBytes: buffer.baseAddress!, bytesPerRow: texture.width * 4 * 2)
            }
        }
    }

    private static func clearToBlack(_ texture: MTLTexture, device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }

    private static func read(_ texture: MTLTexture) -> [[Float]] {
        var raw = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        raw.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!,
                             bytesPerRow: texture.width * 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        var out: [[Float]] = []
        out.reserveCapacity(texture.width * texture.height)
        for i in 0..<(texture.width * texture.height) {
            out.append((0..<4).map { Float(Float16(bitPattern: raw[i * 4 + $0])) })
        }
        return out
    }
}
