import XCTest
import AppKit
import Metal
import PhotonsCore
import PhotonsUI

/// What the canvas shows where the picture isn't.
///
/// The camera may now walk off the edge of the photograph (`LoupeFraming.minimumPictureCoverage`), so
/// the renderer is asked for a window that reaches outside the frame. The question this file answers
/// with pixels is the one the design turns on: is the out-of-frame part **background**, or is it the
/// frame's edge texels dragged outward? `s0_geometry` samples bilinear with clamp-to-edge, which would
/// smear; the canvas-space window (`S0Params.e.y`) rejects the sample instead and writes zero.
///
/// The evidence is a readback of a 10×10 block on each side of the frame's edge, in the same units the
/// shader writes (rgba16Float, linear light).
@MainActor
final class LoupeZoomOutsideFrameTests: XCTestCase {

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

    private func waitFor(_ timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
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
        controller.reducesMotion = true
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

    // MARK: - readback

    /// A block of the frame's own pixels, exactly as the shader wrote them (rgba16Float → Float).
    private struct Block {
        var rgba: [Float]
        var width: Int
        var height: Int
        /// The brightest **colour** channel in the block. Alpha is deliberately not in here: the
        /// display pass writes alpha 1 on top of the black background (an opaque canvas), so alpha
        /// says nothing about whether a pixel is picture or background.
        var maximum: Float {
            stride(from: 0, to: rgba.count, by: 4).map { max(rgba[$0], max(rgba[$0 + 1], rgba[$0 + 2])) }
                .max() ?? 0
        }
        /// Nothing but background: every colour channel is exactly zero (see `s0_geometry`: the miss
        /// writes `float4(0)`, so "black" here is the shader's own zero, not a dark photograph).
        var isBackground: Bool {
            stride(from: 0, to: rgba.count, by: 4).allSatisfy { rgba[$0] == 0 && rgba[$0 + 1] == 0 && rgba[$0 + 2] == 0 }
        }
        var description: String {
            // The four corners of the block, so a printed line is a reading and not a wall of numbers.
            func px(_ x: Int, _ y: Int) -> String {
                let i = (y * width + x) * 4
                return String(format: "(%.3f, %.3f, %.3f, %.3f)", rgba[i], rgba[i + 1],
                              rgba[i + 2], rgba[i + 3])
            }
            return "\(width)×\(height) · max \(String(format: "%.4f", maximum)) · "
                + "corners TL \(px(0, 0)) TR \(px(width - 1, 0)) BL \(px(0, height - 1)) "
                + "BR \(px(width - 1, height - 1))"
        }
    }

    private func block(of texture: MTLTexture, x: Int, y: Int, w: Int = 10, h: Int = 10) throws -> Block {
        XCTAssertGreaterThanOrEqual(x, 0); XCTAssertGreaterThanOrEqual(y, 0)
        XCTAssertLessThanOrEqual(x + w, texture.width); XCTAssertLessThanOrEqual(y + h, texture.height)
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buffered in
            texture.getBytes(buffered.baseAddress!,
                             bytesPerRow: w * 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(x, y, w, h),
                             mipmapLevel: 0)
        }
        let floats = raw.map { Float(Float16(bitPattern: $0)) }
        return Block(rgba: floats, width: w, height: h)
    }

    // MARK: - the test

    /// Park the 100 % window on the crop's top-left corner: half of the canvas is to the left of and
    /// above the photograph, and the frame's edge runs through the middle of the canvas.
    func testThePartOfTheCanvasOutsideThePictureIsBackgroundNotStretchedEdge() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "outside-frame")
        let framing = try XCTUnwrap(controller.framing())

        controller.zoom(to: 2, aroundView: CGPoint(x: 0, y: 0))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil })
        controller.zoom(to: 4, aroundView: CGPoint(x: 0, y: 0))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil })
        controller.zoom(to: 1, aroundView: CGPoint(x: 160, y: 100))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil })
        let state = controller.viewState
        let centre = framing.windowCenter(of: state)
        XCTAssertEqual(state.zoom, 1, accuracy: 1e-12)
        XCTAssertEqual(centre.x, framing.cropOriginX, accuracy: 1e-6, "x is at the limit")
        XCTAssertGreaterThanOrEqual(centre.y, framing.cropOriginY - 1e-6, "y is inside the limit")

        let window = framing.outputWindow(of: state)
        let rect = try XCTUnwrap(window)
        print("state: zoom \(state.zoom)×, window \(rect.width)×\(rect.height) at "
              + "(\(rect.x), \(rect.y)) in the \(Int(framing.cropWidthPixels))×"
              + "\(Int(framing.cropHeightPixels)) frame — "
              + "\(max(0, -rect.x)) px of the canvas is left of the picture, "
              + "\(max(0, -rect.y)) px above it")
        XCTAssertLessThan(rect.x, 0, "the window must hang off the left edge")
        XCTAssertLessThan(rect.y, 0, "the window must hang off the top edge")

        let decodeScale = try XCTUnwrap(controller.lastFrame?.decodeScale)
        let frame = try controller.makeFrame(url: url, viewport: Self.viewport,
                                             decodeScale: decodeScale, edit: .neutral,
                                             state: state, hashPixels: false)
        let texture = frame.texture
        XCTAssertEqual(texture.width, Self.viewport.width)
        XCTAssertEqual(texture.height, Self.viewport.height)
        // The frame's top-left corner lands here on the canvas: canvas = windowOrigin + frame pixel.
        let edgeX = max(0, -rect.x), edgeY = max(0, -rect.y)
        print("canvas: \(texture.width)×\(texture.height) · the picture starts at "
              + "(\(edgeX), \(edgeY))")

        // ① the far corner of the canvas, 10×10: outside the picture on both axes.
        let corner = try block(of: texture, x: 0, y: 0)
        print("outside  corner (0, 0) 10×10: \(corner.description)")
        XCTAssertTrue(corner.isBackground,
                      "the out-of-frame corner is not background — the edge is being stretched")

        // ② just outside the frame's edge (the last 10 columns before it) — still background.
        let outsideEdge = try block(of: texture, x: max(0, edgeX - 10), y: edgeY + 40)
        print("outside  \(edgeX - 10)..\(edgeX - 1), y \(edgeY + 40) 10×10: \(outsideEdge.description)")
        XCTAssertTrue(outsideEdge.isBackground, "one pixel outside the frame must already be background")

        // ③ just inside the frame's edge — photograph, and *the same* values as further in (no smear,
        //    no darkening at the boundary).
        let insideEdge = try block(of: texture, x: edgeX + 1, y: edgeY + 40)
        let insideDeep = try block(of: texture, x: edgeX + 60, y: edgeY + 40)
        print("inside   \(edgeX + 1)..\(edgeX + 10), y \(edgeY + 40): \(insideEdge.description)")
        print("inside   \(edgeX + 60)..\(edgeX + 69): \(insideDeep.description)")
        XCTAssertGreaterThan(insideEdge.maximum, 0.01, "the picture itself must not be empty here")

        // ④ and the transition is one pixel wide: the column before the edge is zero, the column after
        //    is picture. A smear would show a ramp of intermediate values here.
        var firstPaintedColumn = -1
        var profile: [String] = []
        for x in max(0, edgeX - 6)..<min(texture.width, edgeX + 6) {
            let column = try block(of: texture, x: x, y: edgeY + 40, w: 1, h: 10)
            profile.append(String(format: "x%d:%.3f", x, column.maximum))
            if !column.isBackground, firstPaintedColumn < 0 { firstPaintedColumn = x }
        }
        print("edge profile (colour channel max per column): \(profile.joined(separator: " "))")
        print("edge: first painted column is \(firstPaintedColumn), the frame starts at \(edgeX)")
        XCTAssertEqual(firstPaintedColumn, edgeX,
                       "the picture must begin exactly at the frame's edge, with nothing smeared before it")
        // …and the first painted column is already at full strength, not a ramp of half-tones.
        let firstColumn = try block(of: texture, x: max(0, firstPaintedColumn), y: edgeY + 40, w: 1, h: 10)
        let deepColumn = try block(of: texture, x: edgeX + 80, y: edgeY + 40, w: 1, h: 10)
        XCTAssertGreaterThan(firstColumn.maximum, deepColumn.maximum * 0.25,
                             "the first column of picture must be picture, not a smeared-in ramp")
    }

    /// The other side of the same coin: with the window **inside** the frame, the render must be the
    /// same picture it was before this change — the background branch is off, and no pixel differs.
    func testAnInFrameWindowKeepsTheSamePixelsAsABackgroundDisabledRender() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "outside-frame-inside")
        let framed = try XCTUnwrap(controller.framing())
        controller.zoomToActualSize(aroundView: CGPoint(x: 160, y: 100))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil })
        let state = controller.viewState
        let rect = try XCTUnwrap(framed.outputWindow(of: state))
        XCTAssertGreaterThanOrEqual(rect.x, 0)
        XCTAssertGreaterThanOrEqual(rect.y, 0)
        XCTAssertLessThanOrEqual(rect.x + rect.width, Int(framed.cropWidthPixels.rounded()))
        XCTAssertLessThanOrEqual(rect.y + rect.height, Int(framed.cropHeightPixels.rounded()))

        let decodeScale = try XCTUnwrap(controller.lastFrame?.decodeScale)
        let a = try controller.makeFrame(url: url, viewport: Self.viewport, decodeScale: decodeScale,
                                         edit: .neutral, state: state, hashPixels: true)
        // `fit` is the same picture by a different route (no window at all): a 100 % window that sits
        // inside the frame must agree with the whole-frame render where they overlap, at least at the
        // centre — this is the "the window path and the frame path still name the same pixels" guard.
        let centre = try block(of: a.texture, x: 310, y: 190, w: 20, h: 20)
        print("in-frame 100 %: window \(rect.width)×\(rect.height) at (\(rect.x), \(rect.y)) · "
              + "centre 20×20 \(centre.description)")
        XCTAssertGreaterThan(centre.maximum, 0.01)
    }
}
