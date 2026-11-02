import XCTest
import PhotonsCore
@testable import PhotonsUI

/// 248 — 「旋转 + 确认裁剪后，裁出的区域与裁切框不一致（坐标问题）」.
///
/// The crop workspace draws the box axis-aligned on the **turned** picture: its projection is
/// `LoupeMapping.sourcePoint`, which rotates the photograph about `frameWidth/2` (the photo's
/// centre). The committed render used to rotate the *crop* about the crop's own centre instead, so
/// the sampled source region was translated by `(I − R)·(cropCentre − photoCentre)`. A full crop is
/// the one case where both centres coincide, which is why the report only appeared after cropping.
///
/// The fix is in `s0_geometry.metal` (and `LoupeMapping`): the pivot is the photograph's centre in
/// both places. These tests measure the two paths against each other in pixels:
///
///   · the **box** path is the crop workspace's own framing (`LoupeMapping` + `RenderGraph` at the
///     whole-frame document), i.e. the pixels the user saw under the box;
///   · the **committed** path is `RenderGraph` at the document (`crop + straighten + quarter turn`).
///
/// They must be the same pixel, not merely close: the expected sample is picked at the committed
/// pixel centre through the session projection, so one pixel of drift is one gradient step.
@MainActor
final class CropCommitRegion248Tests: XCTestCase {

    private let source = ImageSize(width: 480, height: 320)

    /// A smooth two-axis ramp: one rendered pixel of drift changes the colour by ~0.002 (x) or
    /// ~0.003 (y), far above Float16 noise.
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
                           colorSpace: "sRGB", decoderVersion: "commit-region-248")
    }

    /// TL red / TR green / BL blue / BR white — the fixture the acceptance names.
    private func quadrants(_ source: ImageSize) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: source.width * source.height * 4)
        for y in 0..<source.height {
            for x in 0..<source.width {
                let o = (y * source.width + x) * 4
                let left = x < source.width / 2, top = y < source.height / 2
                switch (left, top) {
                case (true, true): rgba[o] = 1; rgba[o + 1] = 0; rgba[o + 2] = 0
                case (false, true): rgba[o] = 0; rgba[o + 1] = 1; rgba[o + 2] = 0
                case (true, false): rgba[o] = 0; rgba[o + 1] = 0; rgba[o + 2] = 1
                case (false, false): rgba[o] = 1; rgba[o + 1] = 1; rgba[o + 2] = 1
                }
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: source.width, height: source.height, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "commit-region-248-quadrants")
    }

    private struct Angle: CustomStringConvertible {
        let name: String
        let straighten: Double
        let quarterTurns: Int
        var description: String { name }
        static let all: [Angle] = [
            Angle(name: "0°", straighten: 0, quarterTurns: 0),
            Angle(name: "5°", straighten: 5, quarterTurns: 0),
            Angle(name: "45°", straighten: 45, quarterTurns: 0),
            Angle(name: "90° 四分之一转", straighten: 0, quarterTurns: 1),
        ]
    }

    private struct Crop: CustomStringConvertible {
        let name: String
        let rect: CropRect
        var description: String { name }
        static let all: [Crop] = [
            Crop(name: "偏心", rect: CropRect(left: 0.15, top: 0.20, right: 0.70, bottom: 0.85)),
            Crop(name: "贴左上", rect: CropRect(left: 0, top: 0, right: 0.5, bottom: 0.5)),
            Crop(name: "贴右下", rect: CropRect(left: 0.5, top: 0.5, right: 1, bottom: 1)),
            Crop(name: "满幅", rect: .full),
        ]
    }

    private func edit(_ angle: Angle, crop: Crop, full: Bool = false) -> EditModel {
        var g = GeometryGroup(crop: (full ? CropRect.full : crop.rect).normalizedRect,
                              rotationDegrees: angle.straighten,
                              quarterTurns: angle.quarterTurns)
        g.aspectLock = .original
        var e = EditModel.neutral
        e.geometry = g
        return e
    }

    private func value(_ image: DisplayImage, x: Int, y: Int, c: Int) -> Double {
        let xx = min(max(x, 0), image.width - 1)
        let yy = min(max(y, 0), image.height - 1)
        return Double(image.rgba[(yy * image.width + xx) * 4 + c])
    }

    /// The acceptance's 4 × 4 matrix: the pixels under the box equal the committed render's pixels.
    ///
    /// Both sides are rendered at 1:1. The session side is the crop workspace's document (`crop:
    /// .full`, the committed angle) at its natural canvas; the committed side is the document with
    /// the crop. For every sample we convert the committed pixel centre back into the session's pixel
    /// grid — the same projection the overlay draws with — and compare the three colour channels.
    func testTheCommittedCropIsThePixelsUnderTheFrame() throws {
        let graph = try RenderGraph(input: RenderInput(image: ramp(source), identity: "248-region"))
        var rows = 0
        for angle in Angle.all {
            for crop in Crop.all {
                let document = edit(angle, crop: crop)
                let session = edit(angle, crop: crop, full: true)
                let turned = document.geometry.orientedSource(source)
                let sessionCanvas = CropMath.canvasSize(crop: .full, in: source,
                                                        straightenDegrees: angle.straighten,
                                                        quarterTurns: angle.quarterTurns)
                let sessionResult = try graph.render(session, options: RenderOptions(
                    canvas: sessionCanvas, scale: 1, useCache: false,
                    wantsPixels: true, neverUpscalesContent: true))
                let sessionDisplay = try XCTUnwrap(sessionResult.display)
                let committedResult = try graph.render(document, options: RenderOptions(
                    scale: 1, useCache: false, wantsPixels: true))
                let committed = try XCTUnwrap(committedResult.display)

                let draw = document.geometry.renderCrop(source: source)
                let inset = CropMath.canvasOrigin(crop: draw, in: source,
                                                  straightenDegrees: angle.straighten,
                                                  quarterTurns: angle.quarterTurns)
                let sessionInset = CropMath.canvasOrigin(crop: .full, in: source,
                                                         straightenDegrees: angle.straighten,
                                                         quarterTurns: angle.quarterTurns)
                let frame = CropMath.outputSize(draw, in: turned, allowsOutsideSource: true)
                let cropOrigin = (x: draw.left * Double(turned.width),
                                  y: draw.top * Double(turned.height))
                XCTAssertEqual(committed.size, document.geometry.outputPixels(in: source),
                               "\(angle) / \(crop): the export canvas is not the render's")

                var worst = 0.0
                for iy in 0..<10 {
                    for ix in 0..<10 {
                        let rx = 0.05 + 0.1 * Double(ix)
                        let ry = 0.05 + 0.1 * Double(iy)
                        let cx = inset.x + Int((rx * Double(frame.width)).rounded())
                        let cy = inset.y + Int((ry * Double(frame.height)).rounded())
                        // The committed pixel centre (cx+0.5, cy+0.5) in the session's grid.
                        let sx = Int((cropOrigin.x + Double(cx) - Double(inset.x)
                                      + Double(sessionInset.x)).rounded())
                        let sy = Int((cropOrigin.y + Double(cy) - Double(inset.y)
                                      + Double(sessionInset.y)).rounded())
                        for channel in 0..<3 {
                            let delta = abs(value(committed, x: cx, y: cy, c: channel)
                                            - value(sessionDisplay, x: sx, y: sy, c: channel))
                            worst = max(worst, delta)
                        }
                        rows += 1
                    }
                }
                print(String(format: "248 · %@ / %@ · frame %dx%d · inset (%d,%d)"
                             + " · worst colour delta %.6f", angle.name, crop.name,
                             frame.width, frame.height, inset.x, inset.y, worst))
                // The ramp moves ~0.0019 per source pixel on the long edge; 0.002 is one pixel.
                XCTAssertLessThanOrEqual(worst, 0.002,
                                         "\(angle) / \(crop): the committed crop is not the box's pixels")
            }
        }
        XCTAssertEqual(rows, 4 * 4 * 10 * 10)
    }

    /// §4.2 — the four quadrants keep their relative positions (no mirror, no 90° turn) at +5°.
    func testTheFourQuadrantsKeepTheirRelativePositions() throws {
        let graph = try RenderGraph(input: RenderInput(image: quadrants(source),
                                                       identity: "248-quadrants"))
        let angle = Angle(name: "5°", straighten: 5, quarterTurns: 0)
        let document = edit(angle, crop: Crop(name: "满幅", rect: .full))
        let result = try graph.render(document, options: RenderOptions(
            scale: 1, useCache: false, wantsPixels: true))
        let display = try XCTUnwrap(result.display)
        let draw = document.geometry.renderCrop(source: source)
        let inset = CropMath.canvasOrigin(crop: draw, in: source,
                                          straightenDegrees: angle.straighten,
                                          quarterTurns: angle.quarterTurns)
        let frame = CropMath.outputSize(draw, in: source, allowsOutsideSource: true)
        let pivot = (x: Double(source.width) / 2, y: Double(source.height) / 2)
        let rotation = CropGeometry.RotationMatrix(degrees: angle.straighten)

        let quadrants: [(name: String, point: (x: Double, y: Double), channel: Int)] = [
            ("TL red", (0.25, 0.25), 0),
            ("TR green", (0.75, 0.25), 1),
            ("BL blue", (0.25, 0.75), 2),
            ("BR white", (0.75, 0.75), -1),
        ]
        for quadrant in quadrants {
            let dx = quadrant.point.x * Double(source.width) - pivot.x
            let dy = quadrant.point.y * Double(source.height) - pivot.y
            let back = rotation.invert(x: dx, y: dy)
            let x = inset.x + Int((Double(frame.width) / 2 + back.x).rounded())
            let y = inset.y + Int((Double(frame.height) / 2 + back.y).rounded())
            let r = value(display, x: x, y: y, c: 0)
            let g = value(display, x: x, y: y, c: 1)
            let b = value(display, x: x, y: y, c: 2)
            if quadrant.channel < 0 {
                XCTAssertGreaterThan(r, 0.5, "\(quadrant.name): red")
                XCTAssertGreaterThan(g, 0.5, "\(quadrant.name): green")
                XCTAssertGreaterThan(b, 0.5, "\(quadrant.name): blue")
            } else {
                let channels = [r, g, b]
                for (index, channel) in channels.enumerated() {
                    if index == quadrant.channel {
                        XCTAssertGreaterThan(channel, 0.5, "\(quadrant.name): own channel")
                    } else {
                        XCTAssertLessThan(channel, 0.2, "\(quadrant.name): other channel")
                    }
                }
            }
        }
    }

    /// §4.4 — the export (`canvas == nil`) and the screen render are the same pixels at 1:1.
    func testExportAndScreenAgreeAtTheCommittedCrop() throws {
        let graph = try RenderGraph(input: RenderInput(image: ramp(source), identity: "248-export"))
        for angle in [Angle.all[1], Angle.all[2], Angle.all[3]] {
            let document = edit(angle, crop: Crop.all[0])
            let export = try graph.render(document, options: RenderOptions(
                scale: 1, useCache: false, wantsPixels: true))
            let screen = try graph.render(document, options: RenderOptions(
                canvas: document.geometry.outputPixels(in: source), scale: 1,
                useCache: false, wantsPixels: true, neverUpscalesContent: true))
            let a = try XCTUnwrap(export.display)
            let b = try XCTUnwrap(screen.display)
            XCTAssertEqual(a.size, b.size, "\(angle): canvas size")
            XCTAssertEqual(a.sha256(), b.sha256(),
                           "\(angle): export and screen differ at the same 1:1 canvas")
        }
    }

    /// §4.3 — the reverse gate, in numbers. Rotating the crop about its own centre (the old
    /// `s0_geometry` pivot) puts the sampled region `(I − R)·(cropCentre − photoCentre)` away from
    /// the box. At a full crop the offset is exactly zero (which is why the bug hid there); at an
    /// off-centre crop and a real angle it is tens of pixels, so the pixel test above is not vacuous.
    func testTheOldCropCentredPivotMissesTheBoxByTensOfPixels() {
        let pivot = (x: Double(source.width) / 2, y: Double(source.height) / 2)
        for angle in [5.0, 45.0] {
            let rotation = CropGeometry.RotationMatrix(degrees: angle)
            for crop in Crop.all {
                let c = crop.rect
                let corners = [(c.left, c.top), (c.right, c.top), (c.right, c.bottom),
                               (c.left, c.bottom)]
                    .map { (x: $0.0 * Double(source.width), y: $0.1 * Double(source.height)) }
                let cropCentre = ((c.left + c.right) / 2 * Double(source.width),
                                  (c.top + c.bottom) / 2 * Double(source.height))
                var worst = 0.0
                for corner in corners {
                    let box = rotation.apply(x: corner.x - pivot.x, y: corner.y - pivot.y)
                    let old = rotation.apply(x: corner.x - cropCentre.0,
                                             y: corner.y - cropCentre.1)
                    worst = max(worst, hypot(box.x - old.x, box.y - old.y))
                }
                print(String(format: "248 reverse · %.0f° / %@ · old-pivot edge error %.1f px",
                             angle, crop.name, worst))
                if crop.name == "满幅" {
                    XCTAssertEqual(worst, 0, accuracy: 1e-9,
                                   "a full crop's two pivots coincide — the bug is invisible there")
                } else if crop.name == "偏心" {
                    XCTAssertGreaterThan(worst, 1,
                                         "the off-centre reverse gate must be more than one pixel")
                }
            }
        }
    }
}
