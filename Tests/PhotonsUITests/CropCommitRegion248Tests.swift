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

    // MARK: - 286 · the test's own 279 projection

    /// `|w·cos| + |h·sin|` by `|w·sin| + |h·cos|`, written here rather than called from the product.
    private func rotatedExtent(width: Double, height: Double,
                               degrees: Double) -> (width: Double, height: Double) {
        guard degrees.isFinite, degrees != 0 else { return (width, height) }
        let quarter = degrees / 90
        if abs(quarter - quarter.rounded()) < 1e-9 {
            return Int(quarter.rounded()) % 2 != 0 ? (height, width) : (width, height)
        }
        let radians = degrees * .pi / 180
        let c = abs(cos(radians)), s = abs(sin(radians))
        return (width * c + height * s, width * s + height * c)
    }

    /// The one `ceil` the renderer's canvas uses.
    private func canvasPixels(_ value: Double) -> Int {
        max(1, Int((value - 1e-9).rounded(.up)))
    }

    /// The canvas' origin inside the turned frame — **`(0, 0)` since 301**.
    ///
    /// 279's derivation (`(I − R)·(cropCentre − photoCentre) + (extent − frame)/2`) placed a
    /// frame-sized picture inside the turned crop's AABB. 301 made the canvas the crop frame itself
    /// (方案 A), so there is no AABB and no offset: S0 samples `p.c` from canvas pixel 0 and the
    /// overlay's forward/backward walks start there too. Kept as a named call so this file spells
    /// the kernel's walk with **one** origin, and so a future AABB cannot creep back in silently.
    private func canvasInset(crop: CropRect, in turned: ImageSize,
                             degrees: Double) -> (x: Int, y: Int) {
        _ = crop; _ = turned; _ = degrees
        return (0, 0)
    }

    /// Turned source pixel → canvas coordinate.
    ///
    /// **301b — this is a translation, not a rotation.** S0's `p.c` is the crop rect in the turned
    /// frame and the kernel maps a canvas pixel to `p_c + uv·crop` *linearly*: the canvas **is** the
    /// crop's own pixel grid (301, 方案 A). The straighten lives one step further out, on the sample
    /// coordinate (`photo = R(θ)(p_c − P) + P`), so it cancels between the committed crop and the
    /// session canvas — both index the same turned frame at 1:1. 279's spelling rotated *here* and
    /// put the difference back through the AABB inset; with the inset gone that walk is a 2θ error
    /// (measured 0.008 / 0.105 / 0.256 before this correction).
    private func canvasPoint(photo: (x: Double, y: Double), crop: CropRect,
                             in turned: ImageSize, degrees: Double,
                             inset: (x: Int, y: Int)) -> (x: Double, y: Double) {
        _ = degrees
        return (Double(inset.x) + photo.x - crop.left * Double(turned.width),
                Double(inset.y) + photo.y - crop.top * Double(turned.height))
    }

    /// Canvas pixel → turned source pixel, the inverse of `canvasPoint` (also a translation).
    private func photoPoint(canvas: (x: Double, y: Double), crop: CropRect,
                            in turned: ImageSize, degrees: Double,
                            inset: (x: Int, y: Int)) -> (x: Double, y: Double) {
        _ = degrees
        return (canvas.x - Double(inset.x) + crop.left * Double(turned.width),
                canvas.y - Double(inset.y) + crop.top * Double(turned.height))
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
                // 286 — the two integer origins and the two projections are written **in this
                // test** from 279's geometry (turn about the photograph's centre, then translate
                // by the crop's own origin, then snap the AABB origin once). Neither side calls
                // `FrameTransform.sourceToView` or reads the product's continuous inset, so a
                // wrong origin cannot agree with itself.
                let inset = self.canvasInset(crop: draw, in: turned,
                                          degrees: angle.straighten)
                let sessionInset = self.canvasInset(crop: .full, in: turned,
                                                 degrees: angle.straighten)
                let frame = CropMath.outputSize(draw, in: turned, allowsOutsideSource: true)
                let cropOrigin = (x: draw.left * Double(turned.width),
                                  y: draw.top * Double(turned.height))
                XCTAssertEqual(committed.size, document.geometry.outputPixels(in: source),
                               "\(angle) / \(crop): the export canvas is not the render's")

                // Pick points in the committed crop, take their committed canvas pixel centres,
                // then walk each centre **back** to the turned source and **forward** to the
                // session canvas. Both walks are the test's own formula above.
                var worst = 0.0
                for iy in 0..<10 {
                    for ix in 0..<10 {
                        let rx = 0.05 + 0.1 * Double(ix)
                        let ry = 0.05 + 0.1 * Double(iy)
                        let photo = (x: cropOrigin.x + rx * Double(frame.width),
                                     y: cropOrigin.y + ry * Double(frame.height))
                        let raw = self.canvasPoint(photo: photo, crop: draw, in: turned,
                                                   degrees: angle.straighten, inset: inset)
                        // The renderer's grid is integral; sample the pixel centre it wrote.
                        let c = (x: (raw.x - 0.5).rounded() + 0.5,
                                 y: (raw.y - 0.5).rounded() + 0.5)
                        let sourcePoint = self.photoPoint(canvas: c, crop: draw, in: turned,
                                                          degrees: angle.straighten, inset: inset)
                        let s = self.canvasPoint(photo: sourcePoint, crop: .full, in: turned,
                                                 degrees: angle.straighten,
                                                 inset: sessionInset)
                        let a = sampleLinear(committed, x: c.x, y: c.y)
                        let b = sampleLinear(sessionDisplay, x: s.x, y: s.y)
                        worst = max(worst, abs(a.r - b.r), abs(a.g - b.g),
                                    abs(a.r - b.g) * 0)
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
                // The true translation between the crop-centred and photo-centred turns is
                // `|(I − R)·(cropCentre − photoCentre)| = 2·sin(θ/2)·|d|`; it is a centre offset, not
                // the corner-to-corner maximum the first version printed.
                let dx = cropCentre.0 - pivot.x, dy = cropCentre.1 - pivot.y
                let shift = 2 * sin(angle * .pi / 360) * hypot(dx, dy)
                print(String(format: "248 reverse · %.0f° / %@ · |d| %.3f px · 2sin(θ/2)|d| %.3f px",
                             angle, crop.name, hypot(dx, dy), shift))
                if crop.name == "满幅" || crop.name == "居中半幅" {
                    XCTAssertEqual(shift, 0, accuracy: 1e-9,
                                   "a centred crop's two pivots coincide — the bug is invisible there")
                } else if crop.name == "偏心" {
                    XCTAssertGreaterThan(shift, 1,
                                         "the off-centre reverse gate must be more than one pixel")
                }
                _ = corners
            }
        }
    }


    // MARK: - B · the 5 × 4 × 3 edge table

    private func mappedSource(_ r: (x: Double, y: Double), crop: CropRect,
                              angle: Double, perspective: PerspectiveMap?,
                              source: ImageSize) -> (x: Double, y: Double) {
        let w = Double(source.width), h = Double(source.height)
        let photo = (x: crop.left + r.x * crop.width, y: crop.top + r.y * crop.height)
        let warped: (x: Double, y: Double)
        if let perspective, perspective.hasWarp {
            warped = perspective.forward(x: photo.x, y: photo.y)
        } else {
            warped = photo
        }
        let px = warped.x * w - w / 2, py = warped.y * h - h / 2
        // The preview (and the committed picture) is the photo turned by +θ on screen; the source
        // point under a screen point is `P + R(+θ)(screen − P)`.
        let rotation = CropGeometry.RotationMatrix(degrees: angle)
        let q = rotation.apply(x: px, y: py)
        return (x: q.x + w / 2, y: q.y + h / 2)
    }



    private func sampleLinear(_ image: DisplayImage, x: Double, y: Double) -> (r: Double, g: Double) {
        let px = x - 0.5, py = y - 0.5
        let fx = floor(px), fy = floor(py)
        let tx = px - fx, ty = py - fy
        let x0 = Int(fx), y0 = Int(fy)
        func v(_ x: Int, _ y: Int, _ c: Int) -> Double {
            let xx = min(max(x, 0), image.width - 1)
            let yy = min(max(y, 0), image.height - 1)
            return Double(image.rgba[(yy * image.width + xx) * 4 + c])
        }
        func channel(_ c: Int) -> Double {
            let v00 = v(x0, y0, c), v10 = v(x0 + 1, y0, c)
            let v01 = v(x0, y0 + 1, c), v11 = v(x0 + 1, y0 + 1, c)
            return (v00 * (1 - tx) + v10 * tx) * (1 - ty) + (v01 * (1 - tx) + v11 * tx) * ty
        }
        return (channel(0), channel(1))
    }

    /// §B — four edges × 10 samples × 5 angles × 4 crops × 3 keystones = 60 groups. The expected
    /// source point is the box formula (photo centre, P on the whole photo); the actual one is decoded
    /// from the **rendered linear pixels** (`R`/`G` encode source x/y). `linearOutput` makes the two
    /// ramps survive S4 unchanged, so no tone-curve calibration is needed.
    func testTheSixtyGroupEdgeTableStaysWithinOnePixel() throws {
        let angles: [(name: String, degrees: Double)] =
            [("0°", 0), ("0.1°", 0.1), ("1°", 1), ("5°", 5), ("45°", 45)]
        let crops: [(name: String, rect: CropRect)] = [
            ("偏心", CropRect(left: 0.15, top: 0.20, right: 0.70, bottom: 0.85)),
            ("居中半幅", CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)),
            ("贴左上", CropRect(left: 0, top: 0, right: 0.5, bottom: 0.5)),
            ("满幅", .full),
        ]
        let perspectives: [(name: String, map: PerspectiveMap?)] = [
            ("0", nil),
            ("+50", PerspectiveMap(vertical: 50, horizontal: 0)),
            ("-50", PerspectiveMap(vertical: -50, horizontal: 0)),
        ]
        let graph = try RenderGraph(input: RenderInput(image: ramp(source), identity: "248-edges"))
        var worstAll = 0.0
        for angle in angles {
            for crop in crops {
                for p in perspectives {
                    var geometry = GeometryGroup(crop: crop.rect.normalizedRect,
                                                 rotationDegrees: angle.degrees)
                    geometry.perspectiveVertical = p.map?.vertical ?? 0
                    geometry.perspectiveHorizontal = p.map?.horizontal ?? 0
                    var edit = EditModel.neutral
                    edit.geometry = geometry
                    let renderScale = 1.0
                    var options = RenderOptions(scale: renderScale, useCache: false, wantsPixels: true)
                    options.display.linearOutput = true
                    let result = try graph.render(edit, options: options)
                    let display = try XCTUnwrap(result.display)
                    let draw = geometry.renderCrop(source: source)
                    let fractions = (0..<10).map { 0.15 + 0.078 * Double($0) }
                    func edge(_ name: String, _ points: [(Double, Double)], axis: Int) -> Double {
                        var worst = 0.0
                        for r in points {
                            let photo = (x: (draw.left + r.0 * draw.width),
                                         y: (draw.top + r.1 * draw.height))
                            let cx: Double, cy: Double
                            var expected: (x: Double, y: Double)
                            if let map = p.map, map.hasWarp {
                                // The keystone walks the **photo** coordinate; the committed pixel is
                                // the composed forward map, and it shows this input photo point.
                                expected = (x: photo.x * Double(source.width),
                                            y: photo.y * Double(source.height))
                                let pc = CropMath.perspectiveCanvas(crop: draw, in: source,
                                                                    straightenDegrees: angle.degrees,
                                                                    perspective: map)
                                let canvas = PerspectiveMap.apply(pc.forward, x: photo.x, y: photo.y)
                                guard canvas.x > 0.02, canvas.x < 0.98,
                                      canvas.y > 0.02, canvas.y < 0.98 else { continue }
                                cx = canvas.x * Double(display.width)
                                cy = canvas.y * Double(display.height)
                            } else {
                                expected = mappedSource(r, crop: draw, angle: angle.degrees,
                                                        perspective: nil, source: source)
                                // Inverse of the kernel's R(−θ) walk, back into the crop frame.
                                let w = Double(source.width), h = Double(source.height)
                                let dx = expected.x - w / 2, dy = expected.y - h / 2
                                let turned = CropGeometry.RotationMatrix(degrees: angle.degrees)
                                    .apply(x: dx, y: dy)
                                let photo = (x: (turned.x + w / 2) / w,
                                             y: (turned.y + h / 2) / h)
                                let frame = CropMath.outputSize(draw, in: source,
                                                                allowsOutsideSource: true)
                                let inset = CropMath.canvasOrigin(crop: draw, in: source,
                                                                  straightenDegrees: angle.degrees,
                                                                  quarterTurns: 0)
                                cx = ((photo.x - draw.left) / max(draw.width, 1e-9)
                                    * Double(frame.width) + Double(inset.x)) * renderScale
                                cy = ((photo.y - draw.top) / max(draw.height, 1e-9)
                                    * Double(frame.height) + Double(inset.y)) * renderScale
                            }
                            guard expected.x >= 4, expected.y >= 4,
                                  expected.x < Double(source.width) - 4,
                                  expected.y < Double(source.height) - 4 else { continue }
                            // Stay one pixel inside the rendered canvas: an edge pixel's bilinear
                            // neighbourhood includes the matte, which is not a source position.
                            guard cx >= 2, cy >= 2,
                                  cx < Double(display.width) - 2,
                                  cy < Double(display.height) - 2 else { continue }
                            // Compare at the **pixel centre** the render actually sampled, so the
                            // half-pixel quantisation is not mistaken for a transform error.
                            let sx = (cx - 0.5).rounded() + 0.5
                            let sy = (cy - 0.5).rounded() + 0.5
                            if let map = p.map, map.hasWarp {
                                let pc = CropMath.perspectiveCanvas(crop: draw, in: source,
                                                                    straightenDegrees: angle.degrees,
                                                                    perspective: map)
                                let back = PerspectiveMap.apply(pc.sampling,
                                                                x: sx / Double(display.width),
                                                                y: sy / Double(display.height))
                                expected = (x: back.x * Double(source.width),
                                            y: back.y * Double(source.height))
                            } else {
                                let frame = CropMath.outputSize(draw, in: source,
                                                                allowsOutsideSource: true)
                                let inset = CropMath.canvasOrigin(crop: draw, in: source,
                                                                  straightenDegrees: angle.degrees,
                                                                  quarterTurns: 0)
                                let u = (sx / renderScale - Double(inset.x)) / Double(frame.width)
                                let v = (sy / renderScale - Double(inset.y)) / Double(frame.height)
                                let photo = (x: draw.left + u * draw.width,
                                             y: draw.top + v * draw.height)
                                let px = photo.x * Double(source.width) - Double(source.width) / 2
                                let py = photo.y * Double(source.height) - Double(source.height) / 2
                                let r = CropGeometry.RotationMatrix(degrees: -angle.degrees)
                                    .apply(x: px, y: py)
                                expected = (x: r.x + Double(source.width) / 2,
                                            y: r.y + Double(source.height) / 2)
                            }
                            let rgba = sampleLinear(display, x: sx, y: sy)
                            guard expected.x >= 0, expected.y >= 0,
                                  expected.x < Double(source.width),
                                  expected.y < Double(source.height) else { continue }
                            let actualX = (rgba.r - 0.05) / 0.9 * Double(source.width)
                            let actualY = (rgba.g - 0.05) / 0.9 * Double(source.height)
                            // A pixel that landed on the matte has no source position to compare.
                            guard actualX >= 0, actualY >= 0,
                                  actualX < Double(source.width),
                                  actualY < Double(source.height) else { continue }
                            worst = max(worst, axis == 0 ? abs(actualX - expected.x) : abs(actualY - expected.y))
                        }
                        return worst
                    }
                    let left = edge("left", fractions.map { (0.08, $0) }, axis: 0)
                    let top = edge("top", fractions.map { ($0, 0.08) }, axis: 1)
                    let right = edge("right", fractions.map { (0.92, $0) }, axis: 0)
                    let bottom = edge("bottom", fractions.map { ($0, 0.92) }, axis: 1)
                    let worst = max(left, top, right, bottom)
                    worstAll = max(worstAll, worst)
                    print(String(format: "248B %@ / %@ / p=%@ · L %.3f T %.3f R %.3f B %.3f px",
                                 angle.name, crop.name, p.name, left, top, right, bottom))
                    XCTAssertLessThanOrEqual(worst, 1.5,
                                             "\(angle.name) / \(crop.name) / p=\(p.name): "
                                             + "edge deviation \(worst) px")
                }
            }
        }
        print(String(format: "248B · worst %.3f px over 60 groups", worstAll))
    }

    /// §D — the flip is the photograph's mirror at every angle. A tiny straighten must not move the
    /// box's content by the old `2|cropCentre − photoCentre|` jump.
    func testFlipIsTheSameRuleAtZeroAndATinyAngle() throws {
        let graph = try RenderGraph(input: RenderInput(image: ramp(source), identity: "248-flip"))
        let crop = CropRect(left: 0.15, top: 0.20, right: 0.70, bottom: 0.85)
        func render(degrees: Double) throws -> DisplayImage {
            var g = GeometryGroup(crop: crop.normalizedRect, rotationDegrees: degrees,
                                  flipHorizontal: true)
            var e = EditModel.neutral
            e.geometry = g
            _ = g
            return try XCTUnwrap(try graph.render(e, options: RenderOptions(
                scale: 1, useCache: false, wantsPixels: true)).display)
        }
        let a = try render(degrees: 0)
        let b = try render(degrees: 0.001)
        // Compare the same frame fraction in the two canvases (their AABB differs by at most a pixel).
        var worst = 0.0
        for iy in 0..<10 {
            for ix in 0..<10 {
                let ax = Int((0.05 + 0.09 * Double(ix)) * Double(a.width))
                let ay = Int((0.05 + 0.09 * Double(iy)) * Double(a.height))
                let bx = Int((0.05 + 0.09 * Double(ix)) * Double(b.width))
                let by = Int((0.05 + 0.09 * Double(iy)) * Double(b.height))
                for c in 0..<3 {
                    worst = max(worst, abs(value(a, x: ax, y: ay, c: c)
                                           - value(b, x: bx, y: by, c: c)))
                }
            }
        }
        print(String(format: "248D flip · 0° vs 0.001° worst colour delta %.6f", worst))
        XCTAssertLessThanOrEqual(worst, 0.008,
                                 "a flipped off-centre crop jumped when the straighten left zero")
    }

}
