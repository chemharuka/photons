import XCTest
import PhotonsCore
import Metal

/// 246 — **先透视 → 再旋转 → 再算画布尺寸**, and the red frame is the photo's **quad**, not an AABB.
///
/// Every expectation below is derived a second time in this file (cos/sin and an AABB, or a
/// point-in-quad), never read back from `CropMath`, so a regression in either side shows up as a
/// disagreement. The three claims:
///
///   1. the canvas is the AABB of the warped **and turned** quadrilateral, within half a pixel;
///   2. the whole photograph fits inside it — no corner is cut off;
///   3. the composed map is `M = R · P` (perspective first), and a document at 0/0 is untouched.
final class PerspectiveCanvas246Tests: XCTestCase {

    private static let source = ImageSize(width: 2000, height: 1500)

    private func requireMetal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    }

    /// The independent AABB: warp the four corners through `PerspectiveMap.forward`, turn them by
    /// `degrees` about the **crop's centre in pixels**, and take min/max. This is the prose of 246,
    /// written with no `CropMath` call.
    private func expectedAABB(vertical: Double, horizontal: Double, degrees: Double,
                              source: ImageSize = source) -> (min: (Double, Double),
                                                              max: (Double, Double)) {
        let map = PerspectiveMap(vertical: vertical, horizontal: horizontal)
        let w = Double(source.width), h = Double(source.height)
        let cornerPoints = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map { c -> (Double, Double) in
            let p = map.forward(x: c.0, y: c.1)
            return (p.x * w, p.y * h)
        }
        let radians = degrees * .pi / 180
        let cosine = cos(radians), sine = sin(radians)
        let turned = cornerPoints.map { p -> (Double, Double) in
            let dx = p.0 - w / 2, dy = p.1 - h / 2
            return (dx * cosine - dy * sine + w / 2, dx * sine + dy * cosine + h / 2)
        }
        let xs = turned.map { $0.0 }, ys = turned.map { $0.1 }
        return ((xs.min()!, ys.min()!), (xs.max()!, ys.max()!))
    }

    // MARK: - 1 · canvas = AABB(warped + turned)

    func testCanvasIsTheAABBOfThePerspectiveThenRotationQuad() {
        let values = [0.0, 30.0, -30.0, 60.0, -60.0, 100.0, -100.0]
        var worst = 0.0
        for vertical in values {
            for horizontal in values where vertical == 0 || horizontal == 0 {
                for degrees in [0.0, 5.0, 45.0, 90.0] {
                    // 0/0 is the old document (162's right-angle canvas), covered by the identity
                    // test below; 246's AABB claim is about a keystone.
                    guard vertical != 0 || horizontal != 0 else { continue }
                    let expected = expectedAABB(vertical: vertical, horizontal: horizontal,
                                                degrees: degrees)
                    let map = PerspectiveMap(vertical: vertical, horizontal: horizontal)
                    let pc = CropMath.perspectiveCanvas(crop: .full, in: Self.source,
                                                        straightenDegrees: degrees,
                                                        perspective: map)
                    let canvas = CropMath.canvasSize(crop: .full, in: Self.source,
                                                     straightenDegrees: degrees,
                                                     quarterTurns: 0,
                                                     allowsOutsideSource: true,
                                                     perspective: map)
                    let ew = expected.max.0 - expected.min.0
                    let eh = expected.max.1 - expected.min.1
                    worst = max(worst, abs(pc.extent.width - ew),
                                abs(pc.extent.height - eh))
                    XCTAssertEqual(pc.extent.width, ew, accuracy: 0.5,
                                   "v=\(vertical) h=\(horizontal) @\(degrees): width")
                    XCTAssertEqual(pc.extent.height, eh, accuracy: 0.5,
                                   "v=\(vertical) h=\(horizontal) @\(degrees): height")
                    XCTAssertEqual(canvas.width, CropGeometry.canvasPixels(ew),
                                   "v=\(vertical) h=\(horizontal) @\(degrees): ceiling")
                    XCTAssertEqual(canvas.height, CropGeometry.canvasPixels(eh),
                                   "v=\(vertical) h=\(horizontal) @\(degrees): ceiling")
                }
            }
        }
        print(String(format: "246 AABB · worst |canvas − closed form| = %.4f px", worst))
        XCTAssertLessThanOrEqual(worst, 0.5)
    }

    /// §2.2 — the photograph is never cut: every corner of the warp+turn quad is inside the canvas
    /// (the AABB is *the* fitting box), and no canvas edge has a negative distance to the quad.
    func testTheWholePhotographFitsInsideTheCanvas() {
        let values = [0.0, 30.0, -30.0, 60.0, -60.0, 100.0, -100.0]
        var worstNegative = 0.0
        for vertical in values {
            for horizontal in values where vertical == 0 || horizontal == 0 {
                for degrees in [0.0, 5.0, 45.0, 90.0] {
                    let map = PerspectiveMap(vertical: vertical, horizontal: horizontal)
                    let pc = CropMath.perspectiveCanvas(crop: .full, in: Self.source,
                                                        straightenDegrees: degrees,
                                                        perspective: map)
                    let quad = CropMath.perspectivePhotoQuad(crop: .full, canvas: pc)
                    for p in quad {
                        worstNegative = min(worstNegative, p.x, p.y, 1 - p.x, 1 - p.y)
                        XCTAssertGreaterThanOrEqual(p.x, -1e-9)
                        XCTAssertLessThanOrEqual(p.x, 1 + 1e-9)
                        XCTAssertGreaterThanOrEqual(p.y, -1e-9)
                        XCTAssertLessThanOrEqual(p.y, 1 + 1e-9)
                    }
                    // Every corner of the crop frame (the canvas) is inside the photo only when the
                    // quad is axis-aligned; the *photo* being inside the canvas is the claim here.
                    XCTAssertTrue(CropMath.quadContains(quad,
                                                        x: 0.5, y: 0.5, tolerance: 1e-6),
                                  "the picture's centre must be picture")
                }
            }
        }
        print(String(format: "246 FIT · worst negative margin %.3e", worstNegative))
        XCTAssertGreaterThanOrEqual(worstNegative, -1e-9)
    }

    /// §2.2's pathological bound: at full travel neither knob may ask for more than 4× the source.
    func testFullTravelStaysUnderFourTimesTheSource() {
        for vertical in [-100.0, 0, 100.0] {
            for horizontal in [-100.0, 0, 100.0] {
                for degrees in [0.0, 45.0, 90.0] {
                    let canvas = CropMath.canvasSize(crop: .full, in: Self.source,
                                                     straightenDegrees: degrees,
                                                     quarterTurns: 0,
                                                     allowsOutsideSource: true,
                                                     perspective: PerspectiveMap(
                                                        vertical: vertical,
                                                        horizontal: horizontal))
                    print("246 LIMIT v=\(Int(vertical)) h=\(Int(horizontal)) @\(Int(degrees))°"
                          + " · \(canvas.width)×\(canvas.height)")
                    XCTAssertLessThanOrEqual(canvas.width, Self.source.width * 4,
                                             "v=\(vertical) h=\(horizontal) @\(degrees): width")
                    XCTAssertLessThanOrEqual(canvas.height, Self.source.height * 4,
                                             "v=\(vertical) h=\(horizontal) @\(degrees): height")
                }
            }
        }
    }

    // MARK: - 2 · order: M = R · P

    /// The host's composed matrix is perspective **then** rotation: applying it to the photo's
    /// corners equals the independent `R(P(corner))` walk, and `sampling · forward = I`.
    func testComposedMapIsPerspectiveThenRotation() {
        for vertical in [-100.0, 0, 55.0, 100.0] {
            for horizontal in [-100.0, 0, 55.0, 100.0] where vertical == 0 || horizontal == 0 {
                for degrees in [-45.0, 0, 7.0, 45.0] {
                    let map = PerspectiveMap(vertical: vertical, horizontal: horizontal)
                    let pc = CropMath.perspectiveCanvas(crop: .full, in: Self.source,
                                                        straightenDegrees: degrees,
                                                        perspective: map)
                    let w = Double(Self.source.width), h = Double(Self.source.height)
                    let radians = degrees * .pi / 180
                    let cosine = cos(radians), sine = sin(radians)
                    for corner in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)] {
                        // P first, then R, in pixels — the user's order.
                        let warped = map.forward(x: corner.0, y: corner.1)
                        let px = warped.x * w - w / 2, py = warped.y * h - h / 2
                        let qx = px * cosine - py * sine + w / 2
                        let qy = px * sine + py * cosine + h / 2
                        let expected = ((qx - pc.originX) / pc.extent.width,
                                        (qy - pc.originY) / pc.extent.height)
                        let got = PerspectiveMap.apply(pc.forward, x: corner.0, y: corner.1)
                        XCTAssertEqual(got.x, expected.0, accuracy: 1e-12,
                                       "v=\(vertical) h=\(horizontal) @\(degrees): x")
                        XCTAssertEqual(got.y, expected.1, accuracy: 1e-12,
                                       "v=\(vertical) h=\(horizontal) @\(degrees): y")
                    }
                    let product = PerspectiveMap.multiply(pc.forward, pc.sampling)
                    for r in 0..<3 {
                        for c in 0..<3 {
                            XCTAssertEqual(product[r][c], r == c ? 1 : 0, accuracy: 1e-12,
                                           "sampling · forward at (\(vertical),\(horizontal),\(degrees))")
                        }
                    }
                }
            }
        }
    }

    /// Same document rendered twice: the one-pass composed map is deterministic and the second
    /// render is bit-identical (the "P then R versus M = R·P" agreement this build can express).
    func testTheComposedMapRendersDeterministically() throws {
        try requireMetal()
        let image = patternImage(width: 320, height: 240)
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "246-order"))
        var edit = EditModel.neutral
        edit.geometry.perspectiveVertical = 40
        edit.geometry.rotationDegrees = 17
        let a = try render(graph, edit)
        let b = try render(graph, edit)
        print("246 ORDER · \(a.width)×\(a.height) · \(a.sha256().prefix(16))")
        XCTAssertEqual(a.size, b.size)
        XCTAssertEqual(a.sha256(), b.sha256())
    }

    // MARK: - 3 · neutral is the old path

    func testZeroPerspectiveIsTheOldCanvasEverywhere() {
        let crops = [CropRect.full,
                     CropRect(left: 0.1, top: 0.2, right: 0.8, bottom: 0.9)]
        for crop in crops {
            for degrees in [0.0, 5.0, 45.0, 90.0] {
                for turns in [0, 1, 3] {
                    let old = CropMath.canvasSize(crop: crop, in: Self.source,
                                                  straightenDegrees: degrees,
                                                  quarterTurns: turns,
                                                  allowsOutsideSource: true)
                    let explicitZero = CropMath.canvasSize(
                        crop: crop, in: Self.source, straightenDegrees: degrees,
                        quarterTurns: turns, allowsOutsideSource: true,
                        perspective: PerspectiveMap(vertical: 0, horizontal: 0))
                    XCTAssertEqual(old, explicitZero, "a 0/0 map moved the canvas")
                }
            }
        }
    }

    // MARK: - 4 · the red frame is the photo quadrilateral

    /// §2.3 — at 0° the old "turned rectangle" rule says a full frame is inside the photograph; the
    /// keystone's AABB corners are not, so the frame must be red. That is the reverse gate: the two
    /// predicates disagree on exactly the documents this task adds.
    func testRedFrameUsesTheQuadNotTheRotatedRectangle() {
        for vertical in [50.0, -50.0, 100.0, -100.0] {
            for degrees in [0.0, 45.0] {
                let map = PerspectiveMap(vertical: vertical, horizontal: 0)
                let quad = CropMath.perspectiveCanvas(crop: .full, in: Self.source,
                                                      straightenDegrees: degrees,
                                                      perspective: map)
                let photoQuad = CropMath.perspectivePhotoQuad(crop: .full, canvas: quad)
                let red = CropMath.frameExceedsPicture(.full, in: Self.source, degrees: degrees,
                                                       perspective: map)
                let old = CropMath.frameExceedsRotatedRectangle(.full, in: Self.source,
                                                                degrees: degrees)
                // The AABB's four corners are outside a non-axis-aligned photo quad.
                let cornersInside = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
                    .allSatisfy { CropMath.quadContains(photoQuad, x: $0.0, y: $0.1,
                                                        tolerance: 1e-9) }
                print("246 RED v=\(Int(vertical)) @\(Int(degrees))° · red=\(red)"
                      + " oldRect=\(old) cornersInside=\(cornersInside)")
                XCTAssertEqual(red, !cornersInside,
                               "the predicate must agree with the quadrilateral")
                if degrees == 0 {
                    XCTAssertTrue(red, "a keystoned full frame covers black corners")
                    XCTAssertFalse(old, "the old rotated rectangle calls the same frame legal")
                }
            }
        }
    }

    /// A crop whose frame already sits inside the picture is not red; one dragged off the picture is.
    /// The first row is the unchanged 224/227 rule (no keystone).
    func testRedFrameKeepsTheOldRuleWithoutAKeystone() {
        let source = ImageSize(width: 6000, height: 4000)
        XCTAssertFalse(CropMath.frameExceedsPicture(.full, in: source, degrees: 0),
                       "an upright full frame is the photograph")
        let inside = CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)
        XCTAssertFalse(CropMath.frameExceedsPicture(inside, in: source, degrees: 45),
                       "an inscribed frame at 45° is still inside")
        XCTAssertTrue(CropMath.frameExceedsPicture(.full, in: source, degrees: 45),
                      "a full frame at 45° reaches past the turned photograph — red")
    }

    // MARK: - fixtures / render

    private func patternImage(width: Int, height: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let noise = (x &* 73856093) ^ (y &* 19349663)
                let h = Double(abs(noise % 977))
                rgba[o] = Float16(0.06 + 0.70 * Double(x) / Double(width - 1))
                rgba[o + 1] = Float16(0.06 + 0.70 * Double(y) / Double(height - 1))
                rgba[o + 2] = Float16(0.05 + 0.75 * h / 977)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-246")
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let result = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        return try XCTUnwrap(result.display)
    }
}
