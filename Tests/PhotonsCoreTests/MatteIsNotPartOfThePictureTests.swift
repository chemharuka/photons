import XCTest
import Metal
import PhotonsCore

/// The matte is **not** a shadow.
///
/// S0 marks everything that is not photograph (a canvas-space window that reaches past the picture, and
/// the letterbox of a viewport wider than the crop) with alpha 0. The pixel stages used to guard on the
/// *content rect*, which always covers the whole canvas when the window is the canvas — so the matte fell
/// through the guard and every shadow lift treated it as a black pixel of the picture. `blacks +50` on a
/// photo that leaves the frame therefore turned the background grey (measured 0.29 display value, `+100`
/// → 0.40) and the owner reported it twice.
///
/// These tests pin the contract from the outside: a window that is entirely background keeps reading 0
/// whatever the edit does to the shadows, and a window that straddles the picture's edge keeps its
/// outside columns black while the inside is free to change.
final class MatteIsNotPartOfThePictureTests: XCTestCase {

    private func makeGraph(_ image: LinearImage) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: "matte-test"))
    }

    /// Flat mid-grey: any lift of "black" shows up immediately, and nothing depends on texture.
    private func flatImage(width: Int = 160, height: Int = 120) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = Float16(0.25)
            rgba[i + 1] = Float16(0.25)
            rgba[i + 2] = Float16(0.25)
            rgba[i + 3] = 1
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "test")
    }

    private func brightest(_ image: DisplayImage, inColumn column: Int? = nil) -> Float {
        var m: Float = 0
        let x0 = column ?? 0, x1 = column ?? (image.width - 1)
        for y in 0..<image.height {
            for x in x0...max(x0, x1) where x < image.width {
                let o = (y * image.width + x) * 4
                m = max(m, max(Float(image.rgba[o]),
                               max(Float(image.rgba[o + 1]), Float(image.rgba[o + 2]))))
            }
        }
        return m
    }

    /// Every shadow-side control, on a window that is pure background.
    func testNoShadowControlLiftsABackgroundOnlyWindow() throws {
        let graph = try makeGraph(flatImage())
        let window = ImageRect(x: 400, y: 400, width: 20, height: 16)   // wholly outside the picture

        var edits: [(String, EditModel)] = []
        for blacks in [-100.0, -50, 0, 50, 100] {
            var e = EditModel.neutral
            e.light.blacks = blacks
            edits.append(("blacks \(Int(blacks))", e))
        }
        for whites in [50.0, 100] {
            var e = EditModel.neutral
            e.light.whites = whites
            edits.append(("whites \(Int(whites))", e))
        }
        for contrast in [50.0, 100] {
            var e = EditModel.neutral
            e.light.contrast = contrast
            edits.append(("contrast \(Int(contrast))", e))
        }
        for shadows in [50.0, 100] {
            var e = EditModel.neutral
            e.light.shadows = shadows
            edits.append(("shadows \(Int(shadows))", e))
        }
        var liftedCurve = EditModel.neutral
        // 030: the curve's y axis is the log-light coordinate `u`, so "lifted at the toe" is said in
        // u: (0, 0.5) maps u = 0 to u = 0.5, which is +9 stops of lift at the bottom of the axis —
        // by far the most aggressive shadow lift in this list, and therefore the one most likely to
        // light a background-only window up if the matte guard ever went missing.
        liftedCurve.curve.white = [CurvePoint(u: 0, v: 0.5), CurvePoint(u: 0.5, v: 0.7), CurvePoint(u: 1, v: 1)]
        edits.append(("curve lifted at the toe", liftedCurve))
        var saturated = EditModel.neutral
        saturated.color.saturation = 100
        saturated.color.vibrance = 100
        edits.append(("saturation +100", saturated))
        var exposure = EditModel.neutral
        exposure.light.exposure = 2
        edits.append(("exposure +2", exposure))

        for (name, edit) in edits {
            let result = try graph.render(edit, options: RenderOptions(scale: 1,
                                                                      outputWindow: window,
                                                                      display: DisplayOptions(headroom: 4),
                                                                      useCache: false, wantsPixels: true))
            if let t = result.output { graph.recycle(output: t) }
            let pixels = try XCTUnwrap(result.display)
            XCTAssertEqual(brightest(pixels), 0, accuracy: 1e-4,
                           "\(name) lit the background: the matte is not part of the picture")
        }
    }

    /// A window that straddles the picture's right edge: the columns outside stay black.
    func testStraddlingWindowKeepsItsOutsideColumnsBlack() throws {
        let graph = try makeGraph(flatImage())
        let window = ImageRect(x: 140, y: 40, width: 40, height: 20)   // 20 columns inside, 20 outside
        var edit = EditModel.neutral
        edit.light.blacks = 100
        edit.light.shadows = 100

        let result = try graph.render(edit, options: RenderOptions(scale: 1, outputWindow: window,
                                                                  display: DisplayOptions(headroom: 4),
                                                                  useCache: false, wantsPixels: true))
        if let t = result.output { graph.recycle(output: t) }
        let pixels = try XCTUnwrap(result.display)
        XCTAssertEqual(brightest(pixels, inColumn: 39), 0, accuracy: 1e-4,
                       "the column past the picture's right edge")
        XCTAssertGreaterThan(brightest(pixels, inColumn: 0), 0.01,
                             "the columns inside the picture must still be edited")
    }
}
