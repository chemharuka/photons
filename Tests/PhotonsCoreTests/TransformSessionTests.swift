import XCTest
import Metal
import PhotonsCore

/// 123 — the transform session is the one place a draft becomes a document.
///
/// The angle's **sign** is decided here (UI positive = clockwise), the aspect lock is clamped here,
/// and the three finish doors (↵ / 完成 / Esc) are the same `finish(_:)`. The render half of the
/// acceptance — a +5° UI turn moves a top-left dot toward the top-right and paints the corners as
/// background — is measured on real pixels at the bottom of this file.
final class TransformSessionTests: XCTestCase {

    private let source = ImageSize(width: 4000, height: 3000)

    // MARK: - draft / commit / revert

    func testDraftCommitAndRevert() {
        let start = GeometryGroup.identity
        var session = TransformSession(geometry: start, source: source)
        XCTAssertFalse(session.hasChanges, "a fresh session is the document")
        XCTAssertEqual(session.cropGeometry.canvas, source)

        session.setAngle(uiValue: 3.5)
        session.setAspect(.square)
        session.flip(horizontal: true)
        session.rotate90(clockwise: true)
        XCTAssertTrue(session.hasChanges)
        XCTAssertEqual(session.committedGeometry, start, "editing the draft must not move the base")

        let committed = session.commit()
        XCTAssertNotNil(committed)
        XCTAssertEqual(committed, session.committedGeometry)
        XCTAssertFalse(session.hasChanges, "commit makes the draft the base")

        session.setAngle(uiValue: -2)
        session.revert()
        XCTAssertFalse(session.hasChanges, "revert drops the draft")
        XCTAssertEqual(session.draft, committed, "revert restores the committed geometry")
    }

    func testCommitWithNoChangesIsANoOp() {
        var session = TransformSession(geometry: .identity, source: source)
        XCTAssertNil(session.commit(), "nothing moved → no document write")
        XCTAssertEqual(session.finish(.confirm), .unchanged)
    }

    // MARK: - angle sign

    /// **The one sign decision.** The slider's positive value is clockwise on screen; the document
    /// keeps the sign S0 has always consumed, so `TransformSession.setAngle` writes it negated.
    func testPositiveUIAngleIsClockwiseAndWritesTheDocumentSignHere() {
        var session = TransformSession(geometry: .identity, source: source)
        session.setAngle(uiValue: 5)
        XCTAssertEqual(session.angleUIValue, 5, accuracy: 1e-12)
        XCTAssertEqual(session.draft.rotationDegrees, 5, accuracy: 1e-12,
                       "UI positive → document negative; this is the only place the sign is chosen")
        XCTAssertEqual(session.cropGeometry.rotationDegrees, 5, accuracy: 1e-12,
                       "the geometry handed to the overlay and S0 carries the same angle")

        session.setAngle(uiValue: 999)
        XCTAssertEqual(session.angleUIValue, 45, accuracy: 1e-12, "the slider is clamped to ±45")
        session.setAngle(uiValue: -999)
        XCTAssertEqual(session.angleUIValue, -45, accuracy: 1e-12)
    }

    // MARK: - aspect clamp

    func testAspectLockReshapesAndStaysInsideTheFrame() {
        var session = TransformSession(geometry: .identity, source: source)
        session.setAspect(.sixteenNine)
        let crop = session.draft.cropRect
        let pixelRatio = (crop.width * 4000) / max(crop.height * 3000, 1e-9)
        XCTAssertEqual(pixelRatio, 16.0 / 9.0, accuracy: 0.002)
        XCTAssertGreaterThanOrEqual(crop.left, 0)
        XCTAssertGreaterThanOrEqual(crop.top, 0)
        XCTAssertLessThanOrEqual(crop.right, 1)
        XCTAssertLessThanOrEqual(crop.bottom, 1)
        XCTAssertEqual(session.draft.aspectLock, .sixteenNine)

        session.setAspect(.square)
        let square = session.draft.cropRect
        let squareRatio = (square.width * 4000) / max(square.height * 3000, 1e-9)
        XCTAssertEqual(squareRatio, 1, accuracy: 0.002, "1:1 is a pixel ratio, not a normalized one")
    }

    // MARK: - the three finish doors

    func testAllThreeFinishPathsAreEquivalent() {
        func edited() -> TransformSession {
            var s = TransformSession(geometry: .identity, source: source)
            s.setAngle(uiValue: 4)
            s.setAspect(.fourThree)
            s.flip(horizontal: true)
            return s
        }

        var confirm = edited()
        var done = edited()
        var cancel = edited()

        let confirmed = confirm.finish(.confirm)
        let completed = done.finish(.done)
        let cancelled = cancel.finish(.cancel)

        XCTAssertEqual(confirmed, completed, "↵ and 完成 are the same finish")
        XCTAssertTrue(confirmed.changed)
        XCTAssertEqual(confirmed.geometry, confirm.draft)
        XCTAssertEqual(done.draft, confirm.draft, "both writes land on the same geometry")

        XCTAssertEqual(cancelled, .unchanged)
        XCTAssertEqual(cancel.draft, .identity, "Esc restores the entry geometry")
        XCTAssertFalse(cancel.hasChanges)
    }
}

// MARK: - real pixels: direction and the background corners

extension TransformSessionTests {

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// A flat frame with one bright block near the top-left. A **+5° UI turn** must make the block
    /// travel toward the top-right (clockwise on screen), and the four corners — whose source
    /// positions are outside the photograph — must be `float4(0)` background with no edge smear.
    func testPositiveUITurnMovesTheMarkerClockwiseAndFillsTheCornersWithBackground() throws {
        let width = 120, height = 80
        let marker = (x: 30..<38, y: 12..<20)
        var rgba = [Float16](repeating: 0.25, count: width * height * 4)
        for y in marker.y {
            for x in marker.x {
                let o = (y * width + x) * 4
                rgba[o] = 1; rgba[o + 1] = 1; rgba[o + 2] = 1; rgba[o + 3] = 1
            }
        }
        let image = LinearImage(width: width, height: height, rgba: rgba,
                                colorSpace: "sRGB", decoderVersion: "transform-session")
        let graph = try makeGraph(image, identity: "transform-session")

        func render(_ geometry: GeometryGroup) throws -> DisplayImage {
            var edit = EditModel.neutral
            edit.geometry = geometry
            let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                      wantsPixels: true))
            return try XCTUnwrap(result.display)
        }

        func centroid(_ image: DisplayImage) -> (x: Double, y: Double, count: Double) {
            var sx = 0.0, sy = 0.0, n = 0.0
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let o = (y * image.width + x) * 4
                    if image.rgba[o] > 0.9 {
                        sx += Double(x); sy += Double(y); n += 1
                    }
                }
            }
            return (sx / max(n, 1), sy / max(n, 1), n)
        }

        var session = TransformSession(geometry: .identity, source: ImageSize(width: width, height: height))
        session.setAngle(uiValue: 5)
        let turned = try render(session.draft)
        let flat = try render(.identity)
        let before = centroid(flat)
        let after = centroid(turned)
        // 132: the straightened canvas is the rotated crop's bounding box, so the untouched frame is
        // centred in it. Compare the marker in the **same** space.
        let ox = Double(turned.width - width) / 2
        let oy = Double(turned.height - height) / 2
        print("123 · marker \(before) → \(after) (canvas offset \(ox), \(oy))")

        XCTAssertGreaterThan(after.count, 0, "the marker vanished")
        // 126: the slider's "+5°" turns the picture **clockwise** on screen, so a marker in the
        // top-left quadrant travels toward the top-right. Measured here (and confirmed by the user):
        // before the S0 inverse the same document put it left+down, i.e. the picture was rendered at
        // R(−θ) while the crop frame was drawn at R(+θ) — the 2θ mismatch of 126.
        XCTAssertGreaterThan(after.x, before.x + ox + 0.1, "+5° must move the top-left marker right")
        XCTAssertLessThan(after.y, before.y + oy - 0.1, "…and up (clockwise)")

        // Corners of the **canvas** (the AABB, not the frame) are background (0), not the flat
        // frame's 0.25 edge colour.
        let corners = [(0, 0), (turned.width - 1, 0),
                       (0, turned.height - 1), (turned.width - 1, turned.height - 1)]
        for (x, y) in corners {
            let o = (y * turned.width + x) * 4
            for c in 0..<3 {
                XCTAssertEqual(turned.rgba[o + c], 0, "corner (\(x),\(y)) is not background")
            }
        }
        // …and the arc of background is flat: variance over the corner region ≈ 0.
        var values: [Double] = []
        for y in 0..<2 {
            for x in 0..<2 {
                let o = (y * turned.width + x) * 4
                values.append(Double(turned.rgba[o]))
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        XCTAssertEqual(variance, 0, accuracy: 1e-6, "the corner region must be uniform background")

        // A pixel just inside the picture still carries the photograph, so the corners really are
        // "background vs picture", not an all-black frame.
        let edge = ((turned.height / 2) * turned.width + turned.width / 2) * 4
        XCTAssertGreaterThan(turned.rgba[edge], 0.05, "the picture itself disappeared")
    }

    /// The other half of the contract: no rotation means the old path — the corners are the picture,
    /// not background (the background rejection is compiled only into the rotating instantiation).
    func testNoRotationKeepsTheCornersAsPicture() throws {
        let width = 40, height = 30
        let rgba = [Float16](repeating: 0.4, count: width * height * 4)
        let image = LinearImage(width: width, height: height, rgba: rgba,
                                colorSpace: "sRGB", decoderVersion: "transform-session-flat")
        let graph = try makeGraph(image, identity: "transform-session-flat")
        var edit = EditModel.neutral
        edit.geometry = .identity
        let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                  wantsPixels: true))
        let out = try XCTUnwrap(result.display)
        let o = 0
        XCTAssertGreaterThan(out.rgba[o], 0.05, "rotationDegrees == 0 must not paint background")
    }

    /// 126 acceptance ③ — **the mask turns by the same inverse as the picture.**
    ///
    /// A small radial mask sits on a bright dot in the upper-left of the source. After a +9.7°
    /// straighten the dot must still be *inside* that mask: the mask's centroid (read back from the
    /// atlas, i.e. through `s1_5_mask_atlas`) and the picture's centroid (read off the rendered frame,
    /// i.e. through `s0_geometry`) are the same place to ≤ 2 px. Their only shared input is
    /// `RenderGraph`'s `(costheta, sintheta)` pair, so a second sign decision would split them again.
    func testRadialMaskTurnsWithThePictureAtPlus9_7() throws {
        let width = 400, height = 300
        let probe = NormalizedPoint(0.18, 0.18)
        let sigma = 6.0
        let background: Float = 0.05
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let o = i * 4
            rgba[o] = Float16(background); rgba[o + 1] = Float16(background)
            rgba[o + 2] = Float16(background); rgba[o + 3] = 1
        }
        let cx = probe.x * Double(width), cy = probe.y * Double(height)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let v = background + 0.95 * Float(exp(-(dx * dx + dy * dy) / (2 * sigma * sigma)))
                let o = (y * width + x) * 4
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v); rgba[o + 2] = Float16(v)
            }
        }
        let image = LinearImage(width: width, height: height, rgba: rgba,
                                colorSpace: "sRGB", decoderVersion: "transform-session-mask")
        let graph = try makeGraph(image, identity: "transform-session-mask")

        var edit = EditModel.neutral
        edit.geometry = GeometryGroup(crop: .full, rotationDegrees: 9.7)
        edit.masks = [Mask(id: "m-dot", components: [MaskComponent(
            id: "c", feather: 0,
            shape: .radialGradient(RadialGradientShape(
                center: probe, radius: NormalizedPoint(0.08, 0.08), angle: 0)))],
            adjustments: LocalAdjustments())]

        let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                  wantsPixels: true))
        let display = try XCTUnwrap(result.display)
        let dump = try XCTUnwrap(try graph.maskAtlas(edit, options: RenderOptions(scale: 1)))

        func centroid(_ weight: (Int, Int) -> Double) -> (x: Double, y: Double) {
            var sx = 0.0, sy = 0.0, sw = 0.0
            for y in 0..<display.height {
                for x in 0..<display.width {
                    let w = weight(x, y)
                    if w <= 0 { continue }
                    sx += Double(x) * w; sy += Double(y) * w; sw += w
                }
            }
            return sw > 0 ? (sx / sw, sy / sw) : (.nan, .nan)
        }

        var darkest = Double.infinity
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let luma = (Double(display.rgba[i]) + Double(display.rgba[i + 1])
                        + Double(display.rgba[i + 2])) / 3
            if luma > 1e-4 { darkest = min(darkest, luma) }
        }
        let picture = centroid { x, y in
            let o = (y * display.width + x) * 4
            let luma = (Double(display.rgba[o]) + Double(display.rgba[o + 1])
                        + Double(display.rgba[o + 2])) / 3
            return luma - darkest
        }
        let mask = centroid { x, y in Double(dump.value(slice: 0, x: x, y: y) ?? 0) }

        // The independent expectation: the same rotation `CropMath` draws for the crop UI.
        let quad = CropMath.rotatedFrameCorners(in: ImageSize(width: width, height: height),
                                                degrees: 9.7)
        let u = probe.x, v = probe.y
        // 132: the canvas is the rotated crop's bounding box; the frame is centred in it.
        let ox = Double(display.width - width) / 2, oy = Double(display.height - height) / 2
        let want = (x: ox + ((1 - u) * (1 - v) * quad[0].x + u * (1 - v) * quad[1].x
                        + u * v * quad[2].x + (1 - u) * v * quad[3].x) * Double(width) - 0.5,
                    y: oy + ((1 - u) * (1 - v) * quad[0].y + u * (1 - v) * quad[1].y
                        + u * v * quad[2].y + (1 - u) * v * quad[3].y) * Double(height) - 0.5)

        print(String(format: "126 · dot expected (%.2f, %.2f) picture (%.2f, %.2f) mask (%.2f, %.2f)",
                     want.x, want.y, picture.x, picture.y, mask.x, mask.y))
        XCTAssertEqual(picture.x, want.x, accuracy: 2, "the picture is not on the rotated quad")
        XCTAssertEqual(picture.y, want.y, accuracy: 2, "the picture is not on the rotated quad")
        XCTAssertLessThanOrEqual(hypot(mask.x - picture.x, mask.y - picture.y), 2,
                                 "the mask is \(hypot(mask.x - picture.x, mask.y - picture.y)) px off "
                                 + "the picture — S0 and S1.5 are not using the same inverse")
    }
}
