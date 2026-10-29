import XCTest
import Metal
import PhotonsCore

/// 132 — the canvas is the **rotated crop's bounding box**, and a crop may leave the photograph.
final class RotatedCanvasTests: XCTestCase {

    private let square = ImageSize(width: 400, height: 400)

    // MARK: - 1. the size

    func testZeroAngleCanvasIsTheOutputSizeForEveryCrop() {
        let source = ImageSize(width: 4000, height: 3000)
        let rects = [CropRect.full,
                     CropRect(left: 0.1, top: 0.2, right: 0.7, bottom: 0.6),
                     CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)]
        for rect in rects {
            for turns in [0, 1, 2, 3] {
                XCTAssertEqual(CropMath.canvasSize(crop: rect, in: source,
                                                   straightenDegrees: 0, quarterTurns: turns),
                               CropMath.outputSize(rect, in: turns % 2 == 1
                                   ? ImageSize(width: source.height, height: source.width)
                                   : source),
                               "θ = 0 must be the old output size, bit for bit")
            }
        }
        // …and `CropGeometry.canvas` takes the same path.
        var geometry = GeometryGroup.identity
        geometry.rotationDegrees = 0
        geometry.crop = CropRect(left: 0.1, top: 0.2, right: 0.7, bottom: 0.6).normalizedRect
        let carried = CropGeometry(geometry: geometry, source: source)
        XCTAssertEqual(carried.canvas, CropMath.outputSize(carried.crop, in: source))
    }

    func testSquareAt45IsTheDiagonal() {
        let canvas = CropMath.canvasSize(crop: .full, in: square, straightenDegrees: 45,
                                         quarterTurns: 0)
        XCTAssertLessThanOrEqual(abs(canvas.width - 566), 1, "400·√2 = 565.7")
        XCTAssertLessThanOrEqual(abs(canvas.height - 566), 1)
    }

    func testNinePointSevenDegreesFollowsTheFormula() {
        let source = ImageSize(width: 4000, height: 3000)
        let out = CropMath.outputSize(.full, in: source)
        let canvas = CropMath.canvasSize(crop: .full, in: source, straightenDegrees: 9.7,
                                         quarterTurns: 0)
        let c = abs(cos(9.7 * Double.pi / 180)), s = abs(sin(9.7 * Double.pi / 180))
        let w = Double(out.width), h = Double(out.height)
        XCTAssertEqual(canvas.width, Int((w * c + h * s).rounded()))
        XCTAssertEqual(canvas.height, Int((w * s + h * c).rounded()))
    }

    func testQuarterTurnIsAppliedBeforeTheAngle() {
        let source = ImageSize(width: 4000, height: 3000)
        let turned = CropMath.canvasSize(crop: .full, in: source, straightenDegrees: 0,
                                         quarterTurns: 1)
        XCTAssertEqual(turned, ImageSize(width: 3000, height: 4000))
        let turned45 = CropMath.canvasSize(crop: .full, in: source, straightenDegrees: 45,
                                           quarterTurns: 1)
        XCTAssertLessThanOrEqual(abs(turned45.width - 4950), 1)   // 3000·√2
        XCTAssertLessThanOrEqual(abs(turned45.height - 4950), 1)
    }

    // MARK: - 2. pixels: corners, black margins

    private func borderImage(_ w: Int, _ h: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0.2, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let edge = x < 6 || y < 6 || x >= w - 6 || y >= h - 6
                let v: Float16 = edge ? 0.95 : 0.2
                let o = (y * w + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "rotated-canvas")
    }

    private func pixels(_ image: DisplayImage, _ x: Int, _ y: Int) -> [Float] {
        let o = (y * image.width + x) * 4
        return [Float(image.rgba[o]), Float(image.rgba[o + 1]), Float(image.rgba[o + 2])]
    }

    func testFullFrameAt45KeepsThePictureCornersAndBlacksTheBoundingBoxCorners() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let image = borderImage(400, 400)
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "rotated-canvas"))
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = 45
        let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                  wantsPixels: true))
        let display = try XCTUnwrap(result.display)
        XCTAssertLessThanOrEqual(abs(result.canvas.width - 566), 1)

        // The rotated square's corners land on the canvas edges' midpoints. Two pixels inside each
        // of the four picture corners is still the photograph's own bright border…
        let mid = result.canvas.width / 2
        let maxX = result.canvas.width - 3, maxY = result.canvas.height - 3
        for (x, y) in [(mid, 2), (maxX, mid), (mid, maxY), (2, mid)] {
            let p = pixels(display, x, y)
            print(String(format: "132 §3 2 · canvas %d×%d · picture corner (%d,%d) = %.3f/%.3f/%.3f",
                         result.canvas.width, result.canvas.height, x, y, p[0], p[1], p[2]))
            XCTAssertTrue(p.contains { $0 > 0.3 },
                          "the picture's corner at (\(x),\(y)) is background — the canvas is too small")
        }
        // …while the bounding box's four corners (outside the rotated picture) are pure black.
        for (x, y) in [(2, 2), (result.canvas.width - 3, 2),
                       (2, result.canvas.height - 3), (result.canvas.width - 3,
                                                       result.canvas.height - 3)] {
            let p = pixels(display, x, y)
            XCTAssertEqual(p, [0, 0, 0], "AABB corner (\(x),\(y)) is not background")
        }
    }

    func testOutOfRangeCropRendersABiggerCanvasWithABlackBorder() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let image = borderImage(400, 300)
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "outside-crop"))
        var edit = EditModel.neutral
        edit.geometry.crop = CropRect(left: -0.1, top: -0.1, right: 1.1, bottom: 1.1)
            .normalizedRect
        let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                  wantsPixels: true))
        let display = try XCTUnwrap(result.display)
        XCTAssertEqual(result.canvas, ImageSize(width: 480, height: 360),
                       "1.2 × the source on each axis")
        // The outside ring is background, and nothing became NaN.
        for (x, y) in [(2, 2), (477, 2), (2, 357), (477, 357), (240, 2), (2, 180)] {
            XCTAssertEqual(pixels(display, x, y), [0, 0, 0], "(\(x),\(y)) outside the picture")
        }
        print("132 §D · crop -0.1..1.1 · canvas \(result.canvas.width)×\(result.canvas.height) "
              + "· corner \(pixels(display, 2, 2)) · centre \(pixels(display, 240, 180))")
        let centre = pixels(display, 240, 180)
        XCTAssertFalse(centre.contains { $0.isNaN })
        XCTAssertTrue(centre.contains { $0 > 0.1 }, "the picture itself vanished")
        // The former border lands at 0.1/1.2 of the canvas: the ring inside it is the photograph.
        XCTAssertTrue(pixels(display, 50, 180).contains { $0 > 0.1 },
                      "the crop's own edge is not the picture")
    }

    // MARK: - 3. the cache key follows the canvas

    func testTheCanvasChangeMovesTheGeometryKeyAndThenHits() {
        let source = ImageSize(width: 4000, height: 3000)
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = 45
        let crop = edit.geometry.renderCrop(source: source)
        let flat = CropMath.outputSize(crop, in: source)
        let rotated = CropMath.canvasSize(crop: crop, in: source, straightenDegrees: 45,
                                          quarterTurns: 0)
        func keys(canvas: ImageSize) -> RenderKeyChain.Links {
            RenderKeyChain.links(identity: "132-key", sourceSize: source, canvas: canvas,
                                 content: canvas, edit: edit, display: DisplayOptions())
        }
        let before = keys(canvas: flat)
        let after = keys(canvas: rotated)
        XCTAssertNotEqual(before.geometry, after.geometry,
                          "the canvas is in the geometry link — a grown canvas must miss")
        XCTAssertNotEqual(before.sceneLinear, after.sceneLinear, "…and every downstream link")
        XCTAssertEqual(after.geometry, keys(canvas: rotated).geometry,
                       "the same document + canvas is the same key (the rebuild is one-off)")
        print("132 §6 · geoKey \(String(before.geometry.prefix(8)))… → "
              + "\(String(after.geometry.prefix(8)))… for \(flat.keyString) → \(rotated.keyString)")
    }

    // MARK: - 4. the UI predicate

    func testFrameExceedsPictureIsTheColorSemanticsOfTheSpec() {
        let source = ImageSize(width: 4000, height: 4000)
        XCTAssertTrue(CropMath.frameExceedsPicture(.full, in: source, degrees: 45),
                      "full frame at 45° covers the empty corners → red")
        let centre = CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        XCTAssertFalse(CropMath.frameExceedsPicture(centre, in: source, degrees: 45),
                       "0.6× centred is inside the rotated picture → not red")
        XCTAssertFalse(CropMath.frameExceedsPicture(.full, in: source, degrees: 0),
                       "0° full frame has no empty pixels → not red")
    }
}
