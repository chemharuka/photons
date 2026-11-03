import XCTest
import PhotonsCore
@testable import PhotonsUI

/// 279 — 「旋转角度 45° + 裁切，输出和裁切框完全无关」.
///
/// The kernel turns the picture about the **photograph's** centre (248), but `plan` used to place the
/// picture at the frame-centred `(baseline − frame)/2`. For an off-centre crop that puts the kept
/// picture `(I − R)·(cropCentre − photoCentre)` away from the canvas' AABB, and the rotating branch
/// only clipped at the *photograph*, so the canvas' margins sampled the neighbouring picture. The
/// rendered content was therefore a different region entirely, not merely shifted.
///
/// These tests measure the **rendered pixels**, not a second derivation of the same formula:
///
///   1. the source region the output actually shows is the crop rect (four sides, ≤ 1 source px);
///   2. the content's support in S3 is the transformed frame quad's AABB (≤ 1 px);
///   3. every content pixel's `(R, G)` decodes back to the source point the ramp encodes (≤ 2 codes),
///      at 0°, 10°, 45° and a 90° quarter turn, and for a full, centred and an off-centre crop;
///   4. the old frame-centred inset is tens of pixels away on the 45° fixture, so none of the above
///      is vacuous.
@MainActor
final class RotateCropFortyFiveTests: XCTestCase {

    private let source = ImageSize(width: 480, height: 320)

    private struct Crop: CustomStringConvertible {
        let name: String
        let rect: CropRect
        var description: String { name }
        static let all: [Crop] = [
            Crop(name: "满幅", rect: .full),
            Crop(name: "居中半幅", rect: CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)),
            Crop(name: "偏心", rect: CropRect(left: 0.20, top: 0.20, right: 0.70, bottom: 0.70)),
            Crop(name: "贴左上", rect: CropRect(left: 0.05, top: 0.45, right: 0.45, bottom: 0.95)),
        ]
    }

    private struct Angle: CustomStringConvertible {
        let name: String
        let straighten: Double
        let quarterTurns: Int
        var description: String { name }
        static let all: [Angle] = [
            Angle(name: "0°", straighten: 0, quarterTurns: 0),
            Angle(name: "10°", straighten: 10, quarterTurns: 0),
            Angle(name: "45°", straighten: 45, quarterTurns: 0),
            Angle(name: "90° 四分之一转", straighten: 0, quarterTurns: 1),
        ]
    }

    /// `R = x/W`, `G = y/H` — a linear ramp, so a rendered pixel says which source pixel it sampled.
    private func ramp(_ source: ImageSize) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: source.width * source.height * 4)
        for y in 0..<source.height {
            for x in 0..<source.width {
                let o = (y * source.width + x) * 4
                rgba[o] = Float16(Double(x) / Double(source.width) * 0.9 + 0.05)
                rgba[o + 1] = Float16(Double(y) / Double(source.height) * 0.9 + 0.05)
                rgba[o + 2] = 0.3
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: source.width, height: source.height, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "279-rotate-crop")
    }

    private func edit(_ angle: Angle, crop: Crop) -> EditModel {
        var geometry = GeometryGroup(crop: crop.rect.normalizedRect,
                                     rotationDegrees: angle.straighten,
                                     quarterTurns: angle.quarterTurns)
        geometry.aspectLock = .original
        var e = EditModel.neutral
        e.geometry = geometry
        return e
    }

    private func value(_ image: DisplayImage, x: Int, y: Int, c: Int) -> Double {
        let xx = min(max(x, 0), image.width - 1)
        let yy = min(max(y, 0), image.height - 1)
        return Double(image.rgba[(yy * image.width + xx) * 4 + c])
    }

    private struct Measurement {
        let display: DisplayImage
        let turned: ImageSize
        let cropRect: CropRect
        let quarterTurns: Int
        let transform: FrameTransform
        /// Content bbox in canvas pixels, and the source region it decodes to (turned S1 pixels).
        let canvasMinX: Int, canvasMaxX: Int, canvasMinY: Int, canvasMaxY: Int
        let sourceMinX: Double, sourceMaxX: Double
        let sourceMinY: Double, sourceMaxY: Double
        let worstRampDelta: Double
    }

    private func measure(_ angle: Angle, _ crop: Crop) throws -> Measurement {
        let document = edit(angle, crop: crop)
        let graph = try RenderGraph(input: RenderInput(image: ramp(source), identity: "279"))
        var options = RenderOptions(scale: 1, useCache: false, wantsPixels: true)
        options.display.linearOutput = true
        let result = try graph.render(document, options: options)
        let display = try XCTUnwrap(result.display)

        let turned = document.geometry.orientedSource(source)
        let draw = document.geometry.renderCrop(source: source)
        let transform = FrameTransform(source: turned, crop: draw,
                                       straightenDegrees: angle.straighten,
                                       quarterTurns: 0, viewport: nil, zoom: 1)

        var minX = display.width, maxX = -1, minY = display.height, maxY = -1
        var sxMin = Double.infinity, sxMax = -Double.infinity
        var syMin = Double.infinity, syMax = -Double.infinity
        var worst = 0.0
        for y in 0..<display.height {
            for x in 0..<display.width {
                let r = value(display, x: x, y: y, c: 0)
                let g = value(display, x: x, y: y, c: 1)
                let b = value(display, x: x, y: y, c: 2)
                guard r + g + b > 0.02 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                // A partially covered edge pixel is `coverage × ramp` (the matte is 0), so dividing
                // by the coverage recovers the ramp value at the sample point and lets the edge be
                // measured to the pixel grid rather than a full pixel inside it.
                let coverage = b / 0.3
                guard coverage > 0.2 else { continue }
                let fileX = (r / coverage - 0.05) / 0.9 * Double(source.width)
                let fileY = (g / coverage - 0.05) / 0.9 * Double(source.height)
                let turnedPoint = CropMath.turned(
                    NormalizedPoint(fileX / Double(source.width), fileY / Double(source.height)),
                    quarterTurns: angle.quarterTurns)
                let tx = turnedPoint.x * Double(turned.width)
                let ty = turnedPoint.y * Double(turned.height)
                sxMin = min(sxMin, tx); sxMax = max(sxMax, tx)
                syMin = min(syMin, ty); syMax = max(syMax, ty)
                // The ramp is linear, so the decoded source coordinate must reproduce both channels.
                worst = max(worst, abs(r - (fileX / Double(source.width) * 0.9 + 0.05)),
                            abs(g - (fileY / Double(source.height) * 0.9 + 0.05)))
            }
        }
        return Measurement(display: display, turned: turned, cropRect: draw,
                           quarterTurns: angle.quarterTurns, transform: transform,
                           canvasMinX: minX, canvasMaxX: maxX,
                           canvasMinY: minY, canvasMaxY: maxY,
                           sourceMinX: sxMin, sourceMaxX: sxMax,
                           sourceMinY: syMin, sourceMaxY: syMax,
                           worstRampDelta: worst)
    }

    // MARK: - ① the 45° fixture: content = the crop, not the photograph

    func testTheFortyFiveDegreeCropShowsTheFrameAndNotThePhotograph() throws {
        let m = try measure(Angle(name: "45°", straighten: 45, quarterTurns: 0), Crop.all[2])
        let crop = m.cropRect
        let left = crop.left * Double(m.turned.width)
        let right = crop.right * Double(m.turned.width)
        let top = crop.top * Double(m.turned.height)
        let bottom = crop.bottom * Double(m.turned.height)

        print(String(format: "279 ① · 45° · canvas %dx%d · content bbox x %d…%d y %d…%d",
                     m.display.width, m.display.height,
                     m.canvasMinX, m.canvasMaxX, m.canvasMinY, m.canvasMaxY))
        print(String(format: "279 ① · source x %.3f…%.3f (crop %.3f…%.3f) · y %.3f…%.3f (crop %.3f…%.3f)",
                     m.sourceMinX, m.sourceMaxX, left, right,
                     m.sourceMinY, m.sourceMaxY, top, bottom))

        XCTAssertLessThanOrEqual(abs(m.sourceMinX - left), 1.0, "left edge of the kept picture")
        XCTAssertLessThanOrEqual(abs(m.sourceMaxX - right), 1.0, "right edge of the kept picture")
        XCTAssertLessThanOrEqual(abs(m.sourceMinY - top), 1.0, "top edge of the kept picture")
        XCTAssertLessThanOrEqual(abs(m.sourceMaxY - bottom), 1.0, "bottom edge of the kept picture")
        // The content's support is the transformed frame quad's AABB, which is the canvas itself.
        XCTAssertLessThanOrEqual(abs(Double(m.canvasMinX) - m.transform.frameInS3.minX), 1.0)
        XCTAssertLessThanOrEqual(abs(Double(m.canvasMinY) - m.transform.frameInS3.minY), 1.0)
        XCTAssertLessThanOrEqual(abs(Double(m.canvasMaxX) - m.transform.frameInS3.maxX), 2.0)
        XCTAssertLessThanOrEqual(abs(Double(m.canvasMaxY) - m.transform.frameInS3.maxY), 2.0)
    }

    // MARK: - ② θ invariance: the same crop, four angles

    func testEveryAngleShowsTheSameCropRegionWithinOnePixel() throws {
        for angle in Angle.all {
            for crop in Crop.all {
                let m = try measure(angle, crop)
                let c = m.cropRect
                let left = c.left * Double(m.turned.width)
                let right = c.right * Double(m.turned.width)
                let top = c.top * Double(m.turned.height)
                let bottom = c.bottom * Double(m.turned.height)
                print(String(format: "279 ② · %@ / %@ · source x %.2f…%.2f (%.2f…%.2f) y %.2f…%.2f (%.2f…%.2f) · ramp worst %.6f",
                             angle.name, crop.name, m.sourceMinX, m.sourceMaxX, left, right,
                             m.sourceMinY, m.sourceMaxY, top, bottom, m.worstRampDelta))
                XCTAssertLessThanOrEqual(abs(m.sourceMinX - left), 1.0, "\(angle) / \(crop): left")
                XCTAssertLessThanOrEqual(abs(m.sourceMaxX - right), 1.0, "\(angle) / \(crop): right")
                XCTAssertLessThanOrEqual(abs(m.sourceMinY - top), 1.0, "\(angle) / \(crop): top")
                XCTAssertLessThanOrEqual(abs(m.sourceMaxY - bottom), 1.0, "\(angle) / \(crop): bottom")
                // Two display codes: the ramp round-trips through the kernel at every angle.
                XCTAssertLessThanOrEqual(m.worstRampDelta, 2.0 / 255.0,
                                         "\(angle) / \(crop): a content pixel does not decode to its source point")
            }
        }
    }

    // MARK: - ③ the frame quad back on the crop rect

    func testTheFrameQuadIsTheCropRectAfterTheTurn() {
        let angle = Angle(name: "45°", straighten: 45, quarterTurns: 0)
        let document = edit(angle, crop: Crop.all[2])
        let turned = document.geometry.orientedSource(source)
        let draw = document.geometry.renderCrop(source: source)
        let transform = FrameTransform(source: turned, crop: draw, straightenDegrees: 45,
                                       quarterTurns: 0, viewport: nil, zoom: 1)
        let corners = [(draw.left, draw.top), (draw.right, draw.top),
                       (draw.right, draw.bottom), (draw.left, draw.bottom)]
        for (i, corner) in corners.enumerated() {
            let want = SIMD2(corner.0 * Double(turned.width), corner.1 * Double(turned.height))
            let back = transform.viewPointToSource(transform.sourceToView(want))
            XCTAssertEqual(back.x, want.x, accuracy: 0.5, "corner \(i) x")
            XCTAssertEqual(back.y, want.y, accuracy: 0.5, "corner \(i) y")
        }
        // …and the quad's AABB fills the canvas: no frame-centred margin is left over.
        let bbox = transform.frameInS3
        print(String(format: "279 ③ · frame quad AABB %.3f,%.3f %.3fx%.3f · canvas %dx%d",
                     bbox.minX, bbox.minY, bbox.width, bbox.height,
                     transform.canvasS3.width, transform.canvasS3.height))
        XCTAssertEqual(bbox.minX, 0, accuracy: 1.0)
        XCTAssertEqual(bbox.minY, 0, accuracy: 1.0)
        XCTAssertEqual(bbox.width, Double(transform.canvasS3.width), accuracy: 1.0)
        XCTAssertEqual(bbox.height, Double(transform.canvasS3.height), accuracy: 1.0)
    }

    // MARK: - ④ the reverse gate, in numbers

    /// The old `(canvas − frame)/2` and the photo-centred origin must be far apart on the 45°
    /// fixture — otherwise the assertions above would pass for the wrong reason.
    func testTheOldFrameCentredInsetIsTensOfPixelsAway() {
        let angle = Angle(name: "45°", straighten: 45, quarterTurns: 0)
        let document = edit(angle, crop: Crop.all[2])
        let draw = document.geometry.renderCrop(source: source)
        let canvas = CropMath.canvasSize(crop: draw, in: source, straightenDegrees: 45,
                                         quarterTurns: 0)
        let frame = CropMath.outputSize(draw, in: source, allowsOutsideSource: true)
        let old = (x: (canvas.width - frame.width) / 2, y: (canvas.height - frame.height) / 2)
        let new = CropMath.canvasOrigin(crop: draw, in: source, straightenDegrees: 45,
                                        quarterTurns: 0)
        let distance = hypot(Double(new.x - old.x), Double(new.y - old.y))
        print(String(format: "279 ④ · old inset (%d,%d) · new (%d,%d) · %.2f px apart",
                     old.x, old.y, new.x, new.y, distance))
        XCTAssertGreaterThan(distance, 20,
                             "the 45° fixture must separate the two spellings by tens of pixels")
    }
}
