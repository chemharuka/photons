import XCTest
import Metal
@testable import PhotonsCore

/// Task 028 — a mask must select the same *picture* whatever EXIF orientation the file was stored in.
///
/// The pipeline applies orientation once, at ingestion (`RenderGraph.init` calls `LinearImage.oriented()`),
/// so `sourceSize` — and therefore the frame every normalised mask parameter is measured in — is the
/// **upright** size. These tests pin that frame from three directions, all in pixels:
///
///   1. eight stored orientations of *one* picture, one set of mask parameters ⇒ the same selected pixel
///      set (IoU ≥ 0.99 against orientation 1) and the same numbers, not just a similar picture;
///   2. a content-dependent predicate (luminance range) must find the bright quarter of the *upright*
///      picture in all eight — a source that were rotated after ingestion would move it;
///   3. a brush stamp and a radial ellipse must land where they were drawn, in portrait **and**
///      landscape, and the feather radius must not change shape when the frame's long and short edges
///      swap places.
final class MaskOrientationTests: XCTestCase {

    // MARK: - fixtures

    /// The upright picture is landscape; the portrait cases store it rotated, as a camera shooting
    /// upright does (EXIF 6/8 swap the stored width and height).
    private let landscape = ImageSize(width: 96, height: 64)
    private var portrait: ImageSize { ImageSize(width: landscape.height, height: landscape.width) }

    private func graph(_ image: LinearImage, _ identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func atlas(_ edit: EditModel, _ image: LinearImage,
                       identity: String = "mask-028") throws -> MaskAtlasDump {
        let g = try graph(image, identity)
        let dump = try g.maskAtlas(edit, options: RenderOptions(scale: 1))
        return try XCTUnwrap(dump, "an enabled mask must produce an atlas")
    }

    /// A picture that only makes sense one way up: a bright **top-left** quarter on a dark field, plus
    /// a small ramp so bicubic-ish interpolation cannot hide a transposition. Asymmetric in both axes,
    /// so a wrong rotation, mirror or transpose all land somewhere visibly different.
    private func uprightPicture(_ size: ImageSize) -> LinearImage {
        let w = size.width, h = size.height
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let inBrightQuarter = x < w / 2 && y < h / 2
                let v = inBrightQuarter ? 0.90 : 0.08 + 0.02 * Double(x) / Double(max(w - 1, 1))
                let o = (y * w + x) * 4
                rgba[o] = Float16(v)
                rgba[o + 1] = Float16(v)
                rgba[o + 2] = Float16(v)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-028")
    }

    /// The same picture as the camera stored it, for one EXIF value. Built as the **inverse** of
    /// `ImageOrientation.sourceCoordinate`, which is the table `LinearImage.oriented()` walks forward —
    /// so `storedPicture(p, o).oriented()` must be `p` again, a fact the first test asserts rather than
    /// assumes.
    private func storedPicture(_ upright: LinearImage, orientation: ImageOrientation) -> LinearImage {
        let w = upright.width, h = upright.height
        // `uprightSize` is an involution here: given the *upright* dimensions it names the stored ones.
        let stored = orientation.uprightSize(width: w, height: h)
        var rgba = [Float16](repeating: 0, count: stored.width * stored.height * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = orientation.sourceCoordinate(x: x, y: y,
                                                     width: stored.width, height: stored.height)
                let from = (y * w + x) * 4
                let to = (s.y * stored.width + s.x) * 4
                rgba[to] = upright.rgba[from]
                rgba[to + 1] = upright.rgba[from + 1]
                rgba[to + 2] = upright.rgba[from + 2]
                rgba[to + 3] = upright.rgba[from + 3]
            }
        }
        return LinearImage(width: stored.width, height: stored.height, rgba: rgba,
                           colorSpace: upright.colorSpace, decoderVersion: upright.decoderVersion,
                           orientation: orientation)
    }

    private func document(_ shape: MaskShape, componentFeather: Double = 0.5,
                          maskFeather: Double = 0, id: String = "m-028") -> EditModel {
        var edit = EditModel.neutral
        edit.masks = [Mask(id: id, feather: maskFeather,
                           components: [MaskComponent(id: "c-028", feather: componentFeather,
                                                      shape: shape)])]
        return edit
    }

    // MARK: - pixel-set measurements

    private func covered(_ slice: [Float], above threshold: Float = 0.5) -> [Bool] {
        slice.map { $0 >= threshold }
    }

    private func count(_ set: [Bool]) -> Int { set.reduce(0) { $0 + ($1 ? 1 : 0) } }

    private func intersection(_ a: [Bool], _ b: [Bool]) -> Int {
        var n = 0
        for i in a.indices where i < b.count && a[i] && b[i] { n += 1 }
        return n
    }

    private func iou(_ a: [Bool], _ b: [Bool]) -> Double {
        let i = intersection(a, b)
        let u = count(a) + count(b) - i
        return u == 0 ? 1 : Double(i) / Double(u)
    }

    private func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
        var worst: Float = 0
        for i in a.indices where i < b.count { worst = max(worst, abs(a[i] - b[i])) }
        return worst
    }

    private func centroid(_ slice: [Float], width: Int, height: Int) -> (x: Double, y: Double, mass: Double) {
        var sx = 0.0, sy = 0.0, mass = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let a = Double(slice[y * width + x])
                guard a > 1e-4 else { continue }
                sx += a * (Double(x) + 0.5)
                sy += a * (Double(y) + 0.5)
                mass += a
            }
        }
        guard mass > 0 else { return (0, 0, 0) }
        return (sx / mass, sy / mass, mass)
    }

    /// Where a monotone profile crosses `level`, linearly interpolated between the two straddling
    /// pixel centres — the sub-pixel answer, so a 1.5 px budget means something.
    private func crossing(_ samples: [(x: Double, v: Double)], level: Double,
                          rising: Bool) -> Double? {
        for i in 1..<samples.count {
            let a = samples[i - 1], b = samples[i]
            let lo = min(a.v, b.v), hi = max(a.v, b.v)
            guard lo <= level, level <= hi, hi > lo else { continue }
            if rising == (b.v > a.v) {
                let t = (level - a.v) / (b.v - a.v)
                return a.x + t * (b.x - a.x)
            }
        }
        return nil
    }

    private func rowProfile(_ slice: [Float], width: Int, y: Int) -> [(x: Double, v: Double)] {
        (0..<width).map { (x: Double($0) + 0.5, v: Double(slice[y * width + $0])) }
    }

    private func columnProfile(_ slice: [Float], width: Int, height: Int,
                               x: Int) -> [(x: Double, v: Double)] {
        (0..<height).map { (x: Double($0) + 0.5, v: Double(slice[$0 * width + x])) }
    }

    // MARK: - 1. eight orientations, one selection

    /// The acceptance criterion of task 028: the same mask parameters on eight stored orientations of
    /// the same picture must select the same pixels — measured as an IoU against orientation 1 (≥ 0.99)
    /// and as the numbers themselves (so "roughly the same picture" cannot pass as "the same mask").
    func testEightOrientationsSelectTheSamePixels() throws {
        let upright = uprightPicture(landscape)
        // A diagonal ramp over the top-left half: covers a quarter of the frame, and a 90° rotation,
        // a mirror and a transpose each move it somewhere different.
        let edit = document(.linearGradient(LinearGradientShape(start: NormalizedPoint(0, 0),
                                                                end: NormalizedPoint(0.5, 0.5),
                                                                midpoint: 0.5)))

        var reference: MaskAtlasDump?
        var referenceSet: [Bool] = []
        var rows: [(orientation: String, stored: String, upright: String, affected: Int,
                    iou: Double, worst: Double)] = []

        for orientation in ImageOrientation.allCases {
            let stored = storedPicture(upright, orientation: orientation)
            // The fixture builder must be the exact inverse of `oriented()`, or the rest is noise.
            let rebuilt = stored.oriented()
            XCTAssertEqual(rebuilt.width, upright.width)
            XCTAssertEqual(rebuilt.height, upright.height)
            XCTAssertEqual(rebuilt.rgba, upright.rgba, "fixture for \(orientation.displayName) is not upright-inverse")

            let dump = try atlas(edit, stored)
            XCTAssertEqual(dump.width, upright.width, "\(orientation.displayName): atlas follows the stored width")
            XCTAssertEqual(dump.height, upright.height, "\(orientation.displayName): atlas follows the stored height")
            let set = covered(dump.slices[0])

            if let reference {
                let score = iou(referenceSet, set)
                let worst = Double(maxDifference(reference.slices[0], dump.slices[0]))
                rows.append((orientation.keyString,
                             "\(stored.width)×\(stored.height)",
                             "\(dump.width)×\(dump.height)",
                             count(set), score, worst))
                XCTAssertGreaterThanOrEqual(score, 0.99,
                    "EXIF \(orientation.displayName) selects a different region (IoU \(score))")
                XCTAssertLessThan(worst, 2.0 / 255.0,
                    "EXIF \(orientation.displayName) coverage differs by \(worst) — the atlas is not the same mask")
            } else {
                reference = dump
                referenceSet = set
                rows.append((orientation.keyString,
                             "\(stored.width)×\(stored.height)",
                             "\(dump.width)×\(dump.height)",
                             count(set), 1, 0))
                XCTAssertGreaterThan(count(set), 0, "the reference mask must cover something")
            }
        }

        var table = "028 orientation table (mask = diagonal ramp over the top-left half)\n"
        table += "exif  stored    atlas(upright)  affected  IoU(vs 1)  maxΔ\n"
        for r in rows {
            table += String(format: "%-5@ %-9@ %-15@ %-9d %-10.4f %.4f\n",
                            r.orientation as NSString, r.stored as NSString, r.upright as NSString,
                            r.affected, r.iou, r.worst)
        }
        print(table)
    }

    /// The mask predicate sees the picture the *editor* sees. A luminance range that covers the bright
    /// top-left quarter must cover the bright top-left quarter in all eight orientations — this is the
    /// half of the bug that a pure geometry test cannot see, because it lives in the pixel the mask
    /// reads rather than in the coordinate the mask is placed at.
    func testContentDependentMaskFollowsTheUprightPicture() throws {
        let upright = uprightPicture(landscape)
        let edit = document(.luminanceRange(LuminanceRangeShape(low: 0.70, high: 1.0,
                                                                lowFeather: 0.02, highFeather: 0.0)))

        for orientation in ImageOrientation.allCases {
            let dump = try atlas(edit, storedPicture(upright, orientation: orientation))
            let w = dump.width, h = dump.height
            // Every covered pixel must be in the top-left quarter; the quarter's interior must be
            // covered. A 2 px slack absorbs the smoothstep and the S1 gain.
            var outside = 0
            for y in 0..<h {
                for x in 0..<w where dump.value(slice: 0, x: x, y: y) ?? 0 > 0.5 {
                    if x >= w / 2 + 2 || y >= h / 2 + 2 { outside += 1 }
                }
            }
            XCTAssertEqual(outside, 0, "EXIF \(orientation.displayName): the mask left the bright quarter")
            let inside = dump.value(slice: 0, x: w / 4, y: h / 4) ?? 0
            XCTAssertGreaterThan(inside, 0.9,
                "EXIF \(orientation.displayName): the bright quarter is not selected")
            let dark = dump.value(slice: 0, x: 3 * w / 4, y: 3 * h / 4) ?? 0
            XCTAssertLessThan(dark, 0.1,
                "EXIF \(orientation.displayName): the dark corner is selected")
        }
    }

    // MARK: - 2. a brush lands where it was drawn

    /// §4.1: a stroke's points are normalised source coordinates. The coverage they paint must sit on
    /// the same point of the *upright* picture in a landscape file and in a portrait one — the report's
    /// "落点与覆盖区域对不上", measured instead of eyeballed.
    func testBrushStampLandsOnThePointItWasDrawnAt() throws {
        // Off-centre in both axes, and away from the borders so the disc is not clipped.
        let point = NormalizedPoint(0.42, 0.66)
        let radius = 0.05                       // short-edge units: 0.05 · minSide px

        let cases: [(name: String, upright: ImageSize, orientation: ImageOrientation)] = [
            ("landscape / EXIF 1", landscape, .up),
            ("portrait / EXIF 6", portrait, .right),
            ("portrait / EXIF 8", portrait, .left),
        ]

        for c in cases {
            let upright = uprightPicture(c.upright)
            let stored = storedPicture(upright, orientation: c.orientation)
            let edit = document(.brush(BrushShape(size: radius * 2, strokes: [
                Stroke(points: [Float(point.x), Float(point.y)], radius: radius,
                       feather: 0, flow: 1, erase: false, closed: false)
            ])), componentFeather: 0)

            let dump = try atlas(edit, stored)
            let measured = centroid(dump.slices[0], width: dump.width, height: dump.height)
            let expected = (x: point.x * Double(dump.width), y: point.y * Double(dump.height))
            let dx = abs(measured.x - expected.x), dy = abs(measured.y - expected.y)
            let expectedMass = Double.pi * pow(radius * Double(min(dump.width, dump.height)), 2)
            print(String(format: "028 brush %@: centre (%.2f, %.2f) expected (%.2f, %.2f) Δ(%.2f, %.2f) px, mass %.0f / %.0f",
                         c.name, measured.x, measured.y, expected.x, expected.y, dx, dy,
                         measured.mass, expectedMass))
            XCTAssertLessThanOrEqual(dx, 1.5, "\(c.name): brush lands \(dx) px off in x")
            XCTAssertLessThanOrEqual(dy, 1.5, "\(c.name): brush lands \(dy) px off in y")
            XCTAssertEqual(measured.mass, expectedMass, accuracy: expectedMass * 0.15,
                           "\(c.name): the stamp is not a disc of the drawn radius")
        }
    }

    // MARK: - 3. feather keeps its shape when the frame is transposed

    /// §4.6: the feather is a fraction of the **short edge**, in pixels. Two consequences, both
    /// asserted here: the radius is the same number for a 96×64 and a 64×96 frame (the short edge is
    /// the same), and the rendered blur is isotropic — an x-scan and a y-scan of the same edge cross
    /// the ramp over the same distance, in both aspects. A radius normalised by `width` instead of
    /// `min(width, height)` would pass the first and fail the second.
    func testFeatherRadiusIsAspectSymmetric() throws {
        let feather = 1.0
        let sizes = [landscape, portrait]
        var widths: [(name: String, x: Double, y: Double)] = []

        for size in sizes {
            let expectedRadius = MaskRadius.featherPixels(feather, content: size)
            XCTAssertEqual(expectedRadius, 0.1 * Double(min(size.width, size.height)), accuracy: 1e-9)

            // A hard vertical edge, then a hard horizontal edge: same blur, two directions.
            let verticalEdge = document(.linearGradient(LinearGradientShape(start: NormalizedPoint(0, 0.5),
                                                                            end: NormalizedPoint(1, 0.5),
                                                                            midpoint: 0.5)),
                                        componentFeather: 0, maskFeather: feather, id: "m-x")
            let horizontalEdge = document(.linearGradient(LinearGradientShape(start: NormalizedPoint(0.5, 0),
                                                                              end: NormalizedPoint(0.5, 1),
                                                                              midpoint: 0.5)),
                                          componentFeather: 0, maskFeather: feather, id: "m-y")

            let image = uprightPicture(size)
            let alongX = try atlas(verticalEdge, image, identity: "mask-028-x")
            let alongY = try atlas(horizontalEdge, image, identity: "mask-028-y")

            let row = rowProfile(alongX.slices[0], width: alongX.width, y: alongX.height / 2)
            let crossingX10 = try XCTUnwrap(crossing(row, level: 0.1, rising: true), "no 10 % crossing in x")
            let crossingX90 = try XCTUnwrap(crossing(row, level: 0.9, rising: true), "no 90 % crossing in x")
            let column = columnProfile(alongY.slices[0], width: alongY.width, height: alongY.height,
                                       x: alongY.width / 2)
            let crossingY10 = try XCTUnwrap(crossing(column, level: 0.1, rising: true), "no 10 % crossing in y")
            let crossingY90 = try XCTUnwrap(crossing(column, level: 0.9, rising: true), "no 90 % crossing in y")

            let widthX = crossingX90 - crossingX10
            let widthY = crossingY90 - crossingY10
            print(String(format: "028 feather %dx%d: radius %.2f px, 10–90 %% ramp x %.2f px / y %.2f px",
                         size.width, size.height, expectedRadius, widthX, widthY))
            XCTAssertGreaterThan(widthX, expectedRadius, "the feather did nothing")
            XCTAssertEqual(widthX, widthY, accuracy: 1.5,
                           "\(size.width)×\(size.height): feather is \(widthX) px across and \(widthY) px down")
            widths.append(("\(size.width)×\(size.height)", widthX, widthY))
        }

        // The same short edge, transposed: the same ramp width in pixels.
        XCTAssertEqual(widths[0].x, widths[1].x, accuracy: 1.5,
                       "a transposed frame changed the feather width")
    }

    // MARK: - 4. one frame, and it is the ingested one

    /// The number the mask UI measures with. `ingested` is what the renderer saw (upright); the catalog
    /// row is the fallback and is *stored*, so the two differ for EXIF 5…8 — which is exactly the
    /// transposition this task was about.
    func testMaskSourceFramePrefersTheIngestedSize() {
        let ingested = ImageSize(width: 6336, height: 9520)
        XCTAssertEqual(MaskSourceFrame.size(ingested: ingested, storedWidth: 9536, storedHeight: 6344),
                       ingested, "a decoded frame must win over the catalog row")

        // Before the first frame: the stored numbers, floored at 1 so a nil row cannot divide by zero.
        XCTAssertEqual(MaskSourceFrame.size(ingested: nil, storedWidth: 9536, storedHeight: 6344),
                       ImageSize(width: 9536, height: 6344))
        XCTAssertEqual(MaskSourceFrame.size(ingested: nil, storedWidth: nil, storedHeight: nil),
                       ImageSize(width: 1, height: 1))
        // A row with no dimensions is not a divide-by-zero: `ImageSize` floors both edges at 1, and a
        // one-pixel frame is honest ("nothing known"), which is what the drag maths then sees.
        XCTAssertEqual(ImageSize(width: 0, height: 0), ImageSize(width: 1, height: 1))

        // The stored → upright rule belongs to `ImageOrientation` (one table, `OrientationTests` pins
        // it); what this test adds is the transposition the mask UI must not ignore.
        let stored = (w: 9536, h: 6344)
        let portrait = ImageOrientation.right.uprightSize(width: stored.w, height: stored.h)
        XCTAssertEqual(portrait.width, 6344)
        XCTAssertEqual(portrait.height, 9536)
        let up = ImageOrientation.up.uprightSize(width: stored.w, height: stored.h)
        XCTAssertEqual(up.width, 9536)
        XCTAssertEqual(up.height, 6344)
        // The ratio that made the ellipse wrong: `W / minSide` is 1.503 in the stored frame and 1.0 in
        // the upright one, so a rim dragged 60 px sideways rendered 90 px wide (test:
        // `MaskPortraitProjectionTests`).
        XCTAssertEqual(Double(stored.w) / Double(min(stored.w, stored.h)), 1.503, accuracy: 0.001)
        XCTAssertEqual(Double(portrait.width) / Double(min(portrait.width, portrait.height)), 1.0,
                       accuracy: 1e-9, "the upright frame is the one where W is the short edge")
        for orientation in ImageOrientation.allCases {
            let upright = orientation.uprightSize(width: 40, height: 30)
            XCTAssertEqual(orientation.exchangesDimensions,
                           upright.width != 40 || upright.height != 30,
                           "EXIF \(orientation.displayName): dimension exchange does not match the table")
        }
    }
}
