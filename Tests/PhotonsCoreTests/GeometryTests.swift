import XCTest
import Metal
import PhotonsCore

/// 123 — `CropGeometry` is the single rotation/rect/canvas value the overlay and S0 share.
final class GeometryTests: XCTestCase {

    private let source = ImageSize(width: 4000, height: 3000)

    /// y-down pixels: +90° takes the right vector to *down* — clockwise on screen.
    func testPositiveRotationIsClockwiseOnScreen() {
        let rotation = CropGeometry.RotationMatrix(degrees: 90)
        let right = rotation.apply(x: 1, y: 0)
        XCTAssertEqual(right.x, 0, accuracy: 1e-12)
        XCTAssertEqual(right.y, 1, accuracy: 1e-12)

        let back = rotation.invert(x: right.x, y: right.y)
        XCTAssertEqual(back.x, 1, accuracy: 1e-12)
        XCTAssertEqual(back.y, 0, accuracy: 1e-12)
    }

    func testGeometryCarriesCropCanvasAndSource() {
        var geometry = GeometryGroup.identity
        geometry.cropRect = CropRect(left: 0.1, top: 0.2, right: 0.6, bottom: 0.7)
        geometry.rotationDegrees = -12.5
        let carried = CropGeometry(geometry: geometry, source: source)

        XCTAssertEqual(carried.rotationDegrees, -12.5, accuracy: 1e-12)
        XCTAssertEqual(carried.crop, geometry.renderCrop(source: source))
        XCTAssertEqual(carried.canvas, CropMath.outputSize(carried.crop, in: source))
        XCTAssertEqual(carried.source, source)
        XCTAssertEqual(carried.cosine, cos(-12.5 * .pi / 180), accuracy: 1e-12)
        XCTAssertEqual(carried.sine, sin(-12.5 * .pi / 180), accuracy: 1e-12)
    }

    /// A quarter turn swaps the canvas, and the crop stays a rectangle of the *turned* frame.
    func testQuarterTurnCarriesTheOrientedCanvas() {
        let geometry = GeometryGroup(crop: .full, rotationDegrees: 0,
                                     quarterTurns: 1)
        let carried = CropGeometry(geometry: geometry, source: source)
        XCTAssertEqual(carried.source, ImageSize(width: 3000, height: 4000))
        XCTAssertEqual(carried.canvas, ImageSize(width: 3000, height: 4000))
        XCTAssertEqual(carried.quarterTurns, 1)
    }

    func testNoRotationIsTheIdentityMatrix() {
        let carried = CropGeometry(geometry: .identity, source: source)
        XCTAssertTrue(carried.isIdentityRotation)
        XCTAssertEqual(carried.cosine, 1)
        XCTAssertEqual(carried.sine, 0)
        XCTAssertEqual(carried.canvas, source)
    }

    // MARK: - 126: 框 = 像素

    /// **The 2θ bug, measured on pixels.** `CropMath.rotatedFrameCorners` turns the source corners by
    /// `R(+θ)` — that is the quad the crop UI draws and the limits are derived from. S0 walks the
    /// other way (canvas → source) and must therefore consume `R(−θ)`. Handing it `+sin` made the
    /// picture appear at `R(−θ)`: box and pixels differed by 2θ, which is what the user saw at +9.7°.
    ///
    /// The frame carries eight asymmetric probes — four corner blocks and four edge midpoints, each a
    /// different grey. Each probe is planted at a known **source** point; its expected **canvas**
    /// position is the same rotation applied to that point, read off the four corners
    /// `rotatedFrameCorners` returns (an affine map commutes with this bilinear interpolation, so the
    /// two spellings are the same matrix, not two models). The assertion is the distance between that
    /// position and the probe's rendered centroid: ≤ 1 px at +9.7° and at −9.7°.
    ///
    /// The probes sit a little inside the frame because a *frame corner* of a rotated picture lands
    /// outside the axis-aligned canvas — that is why the visible quad is the picture's edge, and why
    /// an inset corner is the corner a pixel test can measure.
    func testRenderedPictureMatchesTheRotatedFrameQuad() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let width = 480, height = 320
        let frame = ImageSize(width: width, height: height)
        // Four inset corners + the four edge midpoints between them, each with its own grey.
        // The inset is at least ~⅛ of each side so that both +9.7° and −9.7° keep every probe
        // inside the canvas: clockwise sends the top-left corner up, counter-clockwise the top-right.
        let probes: [(u: Double, v: Double)] = [
            (0.12, 0.15), (0.88, 0.15), (0.88, 0.85), (0.12, 0.85),
            (0.50, 0.15), (0.88, 0.50), (0.50, 0.85), (0.12, 0.50),
        ]
        let radius = 4

        var rgba = [Float16](repeating: 0, count: width * height * 4)
        var centres: [(x: Int, y: Int)] = []
        for (i, probe) in probes.enumerated() {
            let cx = Int((probe.u * Double(width)).rounded())
            let cy = Int((probe.v * Double(height)).rounded())
            centres.append((cx, cy))
            let value = Float(0.35 + 0.08 * Double(i))
            for y in (cy - radius)...(cy + radius) {
                for x in (cx - radius)...(cx + radius) {
                    let o = (y * width + x) * 4
                    rgba[o] = Float16(value)
                    rgba[o + 1] = Float16(value)
                    rgba[o + 2] = Float16(value)
                    rgba[o + 3] = 1
                }
            }
        }
        let image = LinearImage(width: width, height: height, rgba: rgba,
                                colorSpace: "sRGB", decoderVersion: "quad-match")
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "quad-match"))

        func render(degrees: Double) throws -> DisplayImage {
            var edit = EditModel.neutral
            edit.geometry.rotationDegrees = degrees
            let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                      wantsPixels: true))
            return try XCTUnwrap(result.display)
        }

        /// Where the rotation matrix says a source pixel centre lands, built **only** from
        /// `rotatedFrameCorners` (the quad the crop UI uses).
        func expected(_ centre: (x: Int, y: Int), degrees: Double) -> (x: Double, y: Double) {
            let quad = CropMath.rotatedFrameCorners(in: frame, degrees: degrees)
            let u = (Double(centre.x) + 0.5) / Double(width)
            let v = (Double(centre.y) + 0.5) / Double(height)
            // Bilinear weights of the unit square's corners, applied to the rotated quad: the affine
            // rotation maps the convex combination, so this is the matrix itself.
            let x = (1 - u) * (1 - v) * quad[0].x + u * (1 - v) * quad[1].x
                + u * v * quad[2].x + (1 - u) * v * quad[3].x
            let y = (1 - u) * (1 - v) * quad[0].y + u * (1 - v) * quad[1].y
                + u * v * quad[2].y + (1 - u) * v * quad[3].y
            // Normalised position (0…1) → pixel **index**: a texel's centre is at index + 0.5.
            return (x * Double(width) - 0.5, y * Double(height) - 0.5)
        }

        /// Centroids of the eight bright blobs, as pixel indices.
        func centroids(_ image: DisplayImage) -> [(x: Double, y: Double)] {
            var lit = [Bool](repeating: false, count: image.width * image.height)
            for i in 0..<lit.count {
                let o = i * 4
                let luma = (Double(image.rgba[o]) + Double(image.rgba[o + 1])
                            + Double(image.rgba[o + 2])) / 3
                lit[i] = luma > 0.15
            }
            var seen = [Bool](repeating: false, count: lit.count)
            var out: [(x: Double, y: Double)] = []
            var stack: [Int] = []
            for start in 0..<lit.count where lit[start] && !seen[start] {
                stack.append(start)
                seen[start] = true
                var sx = 0.0, sy = 0.0, n = 0.0
                while let i = stack.popLast() {
                    let x = i % image.width, y = i / image.width
                    sx += Double(x); sy += Double(y); n += 1
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < image.width, ny < image.height else { continue }
                        let j = ny * image.width + nx
                        if lit[j] && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
                if n >= 4 { out.append((sx / n, sy / n)) }
            }
            return out
        }

        for degrees in [9.7, -9.7] {
            let rendered = try render(degrees: degrees)
            let found = centroids(rendered)
            XCTAssertEqual(found.count, probes.count,
                           "\(degrees)°: expected \(probes.count) separated probes, found \(found.count)")

            var matched = [Bool](repeating: false, count: found.count)
            for (i, centre) in centres.enumerated() {
                let want = expected(centre, degrees: degrees)
                // Nearest blob that no other probe has claimed.
                var best = -1
                var bestDistance = Double.infinity
                for (j, got) in found.enumerated() where !matched[j] {
                    let d = hypot(got.x - want.x, got.y - want.y)
                    if d < bestDistance { bestDistance = d; best = j }
                }
                XCTAssertGreaterThanOrEqual(best, 0, "\(degrees)°: probe \(i) has no rendered blob")
                if best >= 0 { matched[best] = true }
                XCTAssertLessThanOrEqual(bestDistance, 1.0,
                    "\(degrees)°: probe \(i) rendered \(String(format: "%.2f", bestDistance)) px from "
                    + "the corner `CropMath.rotatedFrameCorners` predicts — the box and the pixels "
                    + "disagree by 2θ")
                print(String(format: "QUAD-MATCH %+.1f° probe %d: %.3f px", degrees, i, bestDistance))
            }
        }

        // The floor: at 0° the probes are exactly where they were planted, so the fix cannot have
        // moved the neutral frame (that path never reads the sine at all).
        let upright = try render(degrees: 0)
        let flat = centroids(upright)
        XCTAssertEqual(flat.count, probes.count)
        for (i, centre) in centres.enumerated() {
            let nearest = flat.min { hypot($0.x - Double(centre.x), $0.y - Double(centre.y))
                < hypot($1.x - Double(centre.x), $1.y - Double(centre.y)) }
            XCTAssertNotNil(nearest)
            if let nearest {
                XCTAssertLessThanOrEqual(hypot(nearest.x - Double(centre.x),
                                               nearest.y - Double(centre.y)), 1.0,
                                         "0°: probe \(i) moved — the neutral frame changed")
            }
        }
    }
}
