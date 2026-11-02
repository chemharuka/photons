import XCTest
import PhotonsCore
@testable import PhotonsUI

/// 232 — 「旋转后第一帧计算错位：画面整体往左上移（改缩放/重渲即恢复）」.
///
/// The bug was one line in `RenderGraph.plan`: with an angle and no output window (适应), the
/// picture's `frameOrigin` added the **letterbox** origin `(canvas − content)/2` on top of the
/// content-space window origin. `s0_geometry` already subtracts that origin (`local = gid − origin`),
/// so the picture sampled `origin` pixels too far into the frame and every letterboxed 适应 frame of
/// a straightened document was drawn up-left by exactly `origin`. A zoom change makes
/// `canvas == requested`, hence `origin == 0`, which is why the report says 「改缩放即恢复」.
///
/// The assertion is the user's own measurement, in pixels: the photograph's bounding box in the
/// rendered viewport must be centred on the viewport (and fill the content rect), at 0.1° just as at
/// 45°. Reinstating the `origin + …` spelling turns every fit case red by `origin / 2` px (measured
/// 25.5 × 12.5 px at a 2000 × 1500 photo in a 700 × 500 viewport).
@MainActor
final class CropRotateOffset232Tests: XCTestCase {

    private static let source = ImageSize(width: 2000, height: 1500)
    private static let viewport = ImageSize(width: 700, height: 500)

    /// A solid photograph: every rendered non-black pixel is the picture, so its bounding box is the
    /// picture's place on the canvas, measured without knowing any production rect.
    private func image(_ source: ImageSize) -> LinearImage {
        var rgba = [Float16](repeating: 0.9, count: source.width * source.height * 4)
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 1 }
        return LinearImage(width: source.width, height: source.height, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "rotate-offset-232")
    }

    private func pictureBounds(_ image: DisplayImage) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        var x0 = image.width, y0 = image.height, x1 = -1, y1 = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let o = (y * image.width + x) * 4
                if Double(image.rgba[o]) > 0.01 {
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                }
            }
        }
        return (x0, y0, x1, y1)
    }

    private func state(_ mode: LoupeViewState.Mode, zoom: Double = 1) -> LoupeViewState {
        var s = LoupeViewState()
        s.mode = mode
        if mode == .actual {
            s.zoom = zoom
            s.centerX = Double(Self.source.width) / 2
            s.centerY = Double(Self.source.height) / 2
        }
        return s
    }

    private func render(_ graph: RenderGraph, edit: EditModel, framing: LoupeFraming,
                        state: LoupeViewState) throws -> RenderResult {
        try graph.render(edit, options: RenderOptions(
            canvas: Self.viewport,
            scale: framing.renderScale(of: state, decodeScale: 1),
            outputWindow: framing.outputWindow(of: state, decodeScale: 1),
            useCache: true, wantsPixels: true, neverUpscalesContent: true))
    }

    private func framing(degrees: Double,
                         source: ImageSize = ImageSize(width: 2000, height: 1500)) -> LoupeFraming {
        LoupeFraming(viewport: Self.viewport,
                     sourceWidth: Double(source.width), sourceHeight: Double(source.height),
                     crop: .full, straightenDegrees: degrees)
    }

    /// The reported case: 裁切界面 适应 (letterboxed, `origin != 0`) + any rotation.
    func testFitKeepsTheRotatedPictureCentredOnTheViewport() throws {
        let graph = try RenderGraph(input: RenderInput(image: image(Self.source),
                                                       identity: "rotate-offset-232"))
        let fit = state(.fit)
        for degrees in [0.1, 1.0, 45.0] {
            var edit = EditModel.neutral
            edit.geometry.rotationDegrees = degrees
            let f = framing(degrees: degrees)
            let result = try render(graph, edit: edit, framing: f, state: fit)
            let display = try XCTUnwrap(result.display, "\(degrees)°: no pixels")
            let b = pictureBounds(display)
            XCTAssertGreaterThanOrEqual(b.x1, b.x0, "\(degrees)°: nothing was drawn")

            let centreX = Double(b.x0 + b.x1) / 2, centreY = Double(b.y0 + b.y1) / 2
            let viewportX = Double(Self.viewport.width) / 2
            let viewportY = Double(Self.viewport.height) / 2
            print(String(format: "232 fit %.1f° · bbox (%d,%d)-(%d,%d) centre (%.1f,%.1f)"
                         + " · viewport centre (%.1f,%.1f) · content %@ · origin (%d,%d)",
                         degrees, b.x0, b.y0, b.x1, b.y1, centreX, centreY,
                         viewportX, viewportY, result.content.keyString,
                         result.drawnRect.x, result.drawnRect.y))
            XCTAssertEqual(centreX, viewportX, accuracy: 1.0,
                           "\(degrees)° 适应: the picture is \(centreX - viewportX) px off the viewport centre horizontally")
            XCTAssertEqual(centreY, viewportY, accuracy: 1.0,
                           "\(degrees)° 适应: the picture is \(centreY - viewportY) px off the viewport centre vertically")
            // …and it fills the content rect, not a smaller copy pushed into its top-left corner.
            XCTAssertEqual(Double(b.x1 - b.x0 + 1), Double(result.content.width), accuracy: 1,
                           "\(degrees)° 适应: the picture does not fill the content width")
            XCTAssertEqual(Double(b.y1 - b.y0 + 1), Double(result.content.height), accuracy: 1,
                           "\(degrees)° 适应: the picture does not fill the content height")
        }
    }

    /// The acceptance's other form: the frame after the rotation and a forced re-render of the same
    /// document/camera must be the same bytes.
    func testTheFirstFrameAfterRotationEqualsAForcedRerender() throws {
        let graph = try RenderGraph(input: RenderInput(image: image(Self.source),
                                                       identity: "rotate-offset-232-rerender"))
        let fit = state(.fit)
        var flat = EditModel.neutral
        _ = try render(graph, edit: flat, framing: framing(degrees: 0), state: fit)  // prime at 0°

        flat.geometry.rotationDegrees = 0.1
        let first = try render(graph, edit: flat, framing: framing(degrees: 0.1), state: fit)
        let again = try render(graph, edit: flat, framing: framing(degrees: 0.1), state: fit)
        let a = try XCTUnwrap(first.display), b = try XCTUnwrap(again.display)
        XCTAssertEqual(a.sha256(), b.sha256(), "the first rotated frame differs from a re-render")
        XCTAssertEqual(first.drawnRect, again.drawnRect)
        XCTAssertEqual(first.canvasRect, again.canvasRect)
    }

    /// 100 % / 200 % (and a zoomed-out 12.5 %) take the windowed path (`origin == 0`), which the bug
    /// never reached — pinned so the fix cannot trade one framing for another.
    func testActualSizeFramingsKeepThePictureCentred() throws {
        let graph = try RenderGraph(input: RenderInput(image: image(Self.source),
                                                       identity: "rotate-offset-232-actual"))
        for (name, zoom) in [("12.5%", 0.125), ("100%", 1.0), ("200%", 2.0)] {
            let st = state(.actual, zoom: zoom)
            for degrees in [0.1, 1.0, 45.0] {
                var edit = EditModel.neutral
                edit.geometry.rotationDegrees = degrees
                let result = try render(graph, edit: edit,
                                        framing: framing(degrees: degrees), state: st)
                let b = pictureBounds(try XCTUnwrap(result.display))
                let centreX = Double(b.x0 + b.x1) / 2, centreY = Double(b.y0 + b.y1) / 2
                print(String(format: "232 %@ %.1f° · bbox (%d,%d)-(%d,%d) centre (%.1f,%.1f)",
                             name, degrees, b.x0, b.y0, b.x1, b.y1, centreX, centreY))
                XCTAssertEqual(centreX, Double(Self.viewport.width) / 2, accuracy: 1.0,
                               "\(name) \(degrees)°: horizontally off centre")
                XCTAssertEqual(centreY, Double(Self.viewport.height) / 2, accuracy: 1.0,
                               "\(name) \(degrees)°: vertically off centre")
            }
        }
    }

    /// 90° is a quarter turn (the other rotation path); 适应 must be centred there too.
    func testQuarterTurnFitIsCentred() throws {
        let graph = try RenderGraph(input: RenderInput(image: image(Self.source),
                                                       identity: "rotate-offset-232-quarter"))
        var edit = EditModel.neutral
        edit.geometry.quarterTurns = 1
        let turned = ImageSize(width: Self.source.height, height: Self.source.width)
        let f = framing(degrees: 0, source: turned)
        let result = try render(graph, edit: edit, framing: f, state: state(.fit))
        let b = pictureBounds(try XCTUnwrap(result.display))
        let centreX = Double(b.x0 + b.x1) / 2, centreY = Double(b.y0 + b.y1) / 2
        print(String(format: "232 quarter fit · bbox (%d,%d)-(%d,%d) centre (%.1f,%.1f)",
                     b.x0, b.y0, b.x1, b.y1, centreX, centreY))
        XCTAssertEqual(centreX, Double(Self.viewport.width) / 2, accuracy: 1.0)
        XCTAssertEqual(centreY, Double(Self.viewport.height) / 2, accuracy: 1.0)
    }
}
