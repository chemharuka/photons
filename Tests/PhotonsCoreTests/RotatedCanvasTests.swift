import XCTest
import Metal
import PhotonsCore

/// 132 / 301 — the canvas is the **rotated crop frame itself** (301 方案 A). 132's AABB is gone from
/// the output; the same formula remains as the crop's legal region (`CropGeometry.rotatedExtent`).
/// A crop may still leave the photograph at 0° (the black ring then is the crop, not a margin).
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

    func testSquareAt45KeepsTheCropFrameAndTheAABBIsTheLegalRegion() {
        let canvas = CropMath.canvasSize(crop: .full, in: square, straightenDegrees: 45,
                                         quarterTurns: 0)
        // 301 — the output is the crop frame, so a 400×400 crop stays 400×400 at 45°.
        XCTAssertEqual(canvas, square)
        let legal = CropGeometry.rotatedExtent(width: 400, height: 400, degrees: 45)
        XCTAssertEqual(legal.width, 400 * 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(legal.height, 400 * 2.0.squareRoot(), accuracy: 1e-9)
    }

    func testNinePointSevenDegreesKeepsTheCropFrame() {
        let source = ImageSize(width: 4000, height: 3000)
        let out = CropMath.outputSize(.full, in: source)
        let canvas = CropMath.canvasSize(crop: .full, in: source, straightenDegrees: 9.7,
                                         quarterTurns: 0)
        XCTAssertEqual(canvas, out, "301: the canvas is the crop frame at every angle")
        // The old AABB formula is still the legal region; it is intentionally *not* the canvas.
        let c = abs(cos(9.7 * Double.pi / 180)), s = abs(sin(9.7 * Double.pi / 180))
        let w = Double(out.width), h = Double(out.height)
        let legal = CropGeometry.rotatedExtent(width: w, height: h, degrees: 9.7)
        XCTAssertEqual(legal.width, w * c + h * s, accuracy: 1e-9)
        XCTAssertEqual(legal.height, w * s + h * c, accuracy: 1e-9)
    }

    func testQuarterTurnIsAppliedBeforeTheAngle() {
        let source = ImageSize(width: 4000, height: 3000)
        let turned = CropMath.canvasSize(crop: .full, in: source, straightenDegrees: 0,
                                         quarterTurns: 1)
        XCTAssertEqual(turned, ImageSize(width: 3000, height: 4000))
        let turned45 = CropMath.canvasSize(crop: .full, in: source, straightenDegrees: 45,
                                           quarterTurns: 1)
        // The crop is measured in the turned frame (3000×4000); 301 keeps that as the canvas.
        XCTAssertEqual(turned45, ImageSize(width: 3000, height: 4000))
        let legal = CropGeometry.rotatedExtent(width: 3000, height: 4000, degrees: 45)
        XCTAssertEqual(legal.width, 4950, accuracy: 1)   // (3000 + 4000)·sin 45°
        XCTAssertEqual(legal.height, 4950, accuracy: 1)
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

    func testFullFrameAt45HasNoBlackCorners() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let image = borderImage(400, 400)
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "rotated-canvas"))
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = 45
        // 301's contract: a full-frame request is inscribed in the turned picture before it reaches
        // the renderer (the crop tool does this through `clampsToRotatedFrame`); model that here so
        // the whole output is photograph and no AABB margin exists.
        edit.geometry.crop = CropMath.clampedToRotatedFrame(.full, in: ImageSize(width: 400, height: 400),
                                                            degrees: 45,
                                                            keepsInsideRotatedFrame: true).normalizedRect
        let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                  wantsPixels: true))
        let display = try XCTUnwrap(result.display)
        XCTAssertEqual(result.canvas,
                       CropMath.frameSize(edit.geometry.renderCrop(source: ImageSize(width: 400, height: 400)),
                                          in: ImageSize(width: 400, height: 400),
                                          allowsOutsideSource: true),
                       "the canvas is the crop frame itself")

        // Every corner is photograph — including the four AABB corners that used to be black.
        let maxX = result.canvas.width - 3, maxY = result.canvas.height - 3
        for (x, y) in [(2, 2), (maxX, 2), (2, maxY), (maxX, maxY),
                       (result.canvas.width / 2, 2), (maxX, result.canvas.height / 2)] {
            let p = pixels(display, x, y)
            print(String(format: "301 §3 · canvas %d×%d · corner (%d,%d) = %.3f/%.3f/%.3f",
                         result.canvas.width, result.canvas.height, x, y, p[0], p[1], p[2]))
            XCTAssertTrue(p.contains { $0 > 0.3 },
                          "the picture's corner at (\(x),\(y)) is background — the frame is not the canvas")
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

    func testTheCanvasIsTheCropFrameAtEveryAngleAndTheKeyFollowsTheCrop() {
        let source = ImageSize(width: 4000, height: 3000)
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = 45
        let crop = edit.geometry.renderCrop(source: source)
        let flat = CropMath.outputSize(crop, in: source)
        let rotated = CropMath.canvasSize(crop: crop, in: source, straightenDegrees: 45,
                                          quarterTurns: 0)
        // 301 — the straighten no longer grows the canvas; the crop alone decides it.
        XCTAssertEqual(rotated, flat, "the canvas is the crop frame at 45°")
        func keys(canvas: ImageSize) -> RenderKeyChain.Links {
            RenderKeyChain.links(identity: "301-key", sourceSize: source, canvas: canvas,
                                 content: canvas, edit: edit, display: DisplayOptions())
        }
        XCTAssertEqual(keys(canvas: flat).geometry, keys(canvas: rotated).geometry,
                       "the same crop is the same canvas, so the same key")
        // A real crop *does* change the canvas — the key still has to follow it.
        var cropped = edit
        cropped.geometry.crop = CropRect(left: 0.1, top: 0.1, right: 0.6, bottom: 0.7).normalizedRect
        let smaller = CropMath.canvasSize(crop: cropped.geometry.renderCrop(source: source),
                                          in: source, straightenDegrees: 45, quarterTurns: 0)
        XCTAssertNotEqual(smaller, flat)
        XCTAssertNotEqual(keys(canvas: flat).geometry, keys(canvas: smaller).geometry,
                          "a different crop must miss the geometry key")
        print("301 §6 · crop canvas \(flat.keyString) · smaller \(smaller.keyString)")
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
