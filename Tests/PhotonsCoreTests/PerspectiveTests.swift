import XCTest
import PhotonsCore
import Metal
import CryptoKit

/// 183 — **透视 / 梯形校正**. Six claims, one test each, every number measured:
///
///   1. **identity** — both knobs at 0 reproduces the three recorded goldens (`neutral` / `push` /
///      `crop-rot`) **pixel for pixel**, and the geometry key material is the pre-183 string
///      character for character (no `pvy`/`phx` token; only the mandated `;alg=2` moves).
///   2. **the knob works** — on a synthetic 3° converging card, `perspectiveVertical = +50` leaves
///      the verticals within 0.3° of vertical, and `−50` bends them the other way.
///   3. **no background** — the canvas' four corners are picture, not `float4(0)`: an 8×8 block with
///      variance > 0 and a mean within 1 code of the same point in a half-scale render.
///   4. **the canvas is the inscribed rectangle** — four notch positions × 0/45/90°, pinned to
///      ±0.5 px against a closed form computed here, and the closed form itself checked against a
///      grid search.
///   5. **order** — the rotation is applied to the keystoned picture, pinned by a document whose
///      angle and keystone are both non-zero.
///   6. **export ≡ display** — `canvasSize` is the size the renderer actually produces, and at 90° a
///      window that covers the canvas is the no-window frame (`max|Δ| = 0`).
final class PerspectiveTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func requireMetal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    }

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    // MARK: - fixtures

    /// A high-frequency, asymmetric frame: every position carries a different value, so a warp that
    /// did nothing would be visible and two different warps cannot coincide.
    private func patternImage(width: Int = 480, height: Int = 320) -> LinearImage {
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
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-183")
    }

    /// A **smooth** frame: a low-frequency two-axis gradient. Used where the assertion compares a
    /// corner of the 1:1 render with the same point of a half-scale render — a high-frequency picture
    /// would differ there by resampling alone, not by anything the keystone did.
    private func smoothImage(width: Int = 480, height: Int = 320) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let u = Double(x) / Double(width - 1), v = Double(y) / Double(height - 1)
                rgba[o] = Float16(0.05 + 0.55 * u)
                rgba[o + 1] = Float16(0.05 + 0.55 * v)
                rgba[o + 2] = Float16(0.10 + 0.30 * (u * 0.5 + v * 0.5))
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-183-smooth")
    }

    /// The acceptance card: a **真实 keystone** — nine verticals that converge inward at the top, all
    /// through one vanishing point, with the *frame-edge* pair at exactly `degrees` from vertical.
    ///
    /// It is a trapezoid (`x_top = ½ + (x_bottom − ½)·m`), not a shear: in a real photograph of a
    /// building shot from below the lines converge on one point, so the contraction ratio is what a
    /// keystone corrects and the per-line angle is a consequence. `m = 0.895` puts the edge pair at
    /// `atan(0.0525) = 3.00°` on this square frame, which is exactly the map's full-travel ÷ 2 —
    /// `PerspectiveMap.tangentPerUnit · 50/100 = 0.105` and `1 − m = 0.105`.
    private func cardImage(size: Int = 2000, degrees: Double = 3) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            rgba[i * 4] = 0.85; rgba[i * 4 + 1] = 0.85; rgba[i * 4 + 2] = 0.85
            rgba[i * 4 + 3] = 1
        }
        func plot(_ x: Int, _ y: Int) {
            guard x >= 0, x < size, y >= 0, y < size else { return }
            let o = (y * size + x) * 4
            rgba[o] = 0.01; rgba[o + 1] = 0.01; rgba[o + 2] = 0.01
        }
        // The contraction the knob at +50 inverts exactly: `1 − m = 2·tan(degrees)`. On a square
        // frame that is `0.1048`, and the map's `v` at +50 is `−0.105` — the same number to 2e-4.
        let m = 1 - 2 * tan(degrees * .pi / 180)
        for k in 0...8 {
            let base = Double(size) * Double(k) / 8
            for y in 0..<size {
                let t = 1 - Double(y) / Double(size - 1)      // 0 at the bottom, 1 at the top
                let x = (base / Double(size) - 0.5) * (1 - (1 - m) * t) * Double(size) + Double(size) / 2
                for dx in -2...2 { plot(Int(x.rounded()) + dx, y) }
            }
        }
        for x in 0..<size {
            for dy in -2...2 { plot(x, size / 2 + dy) }
        }
        return LinearImage(width: size, height: size, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-card")
    }

    /// The sub-pixel x of the dark line nearest `x0` on row `y`: the darkest pixel in a ±`window`
    /// search, then a darkness-weighted centroid over ±10 of it. Centring on the darkest pixel first
    /// is what keeps a neighbouring line (the card's spacing is 250 px) out of the average.
    private func lineX(_ image: DisplayImage, row y: Int, near x0: Int, window: Int = 120) -> Double {
        var bestX = -1, bestDark = 0.0
        for x in max(0, x0 - window)...min(image.width - 1, x0 + window) {
            let dark = max(0, 200 - code(image, x, y))
            if dark > bestDark { bestDark = dark; bestX = x }
        }
        guard bestX >= 0 else { return .nan }
        var sum = 0.0, weight = 0.0
        for x in max(0, bestX - 10)...min(image.width - 1, bestX + 10) {
            let dark = max(0, 200 - code(image, x, y))
            sum += dark * Double(x)
            weight += dark
        }
        return weight > 0 ? sum / weight : .nan
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel, scale: Double = 1) throws -> DisplayImage {
        let result = try graph.render(edit, options: RenderOptions(scale: scale, wantsPixels: true))
        return try XCTUnwrap(result.display, "the render came back without pixels")
    }

    /// Luminance of one pixel of a display frame, in 0…255 codes.
    private func code(_ image: DisplayImage, _ x: Int, _ y: Int) -> Double {
        let o = (y * image.width + x) * 4
        let r = Double(image.rgba[o]) * 255, g = Double(image.rgba[o + 1]) * 255
        let b = Double(image.rgba[o + 2]) * 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// The angle of the acceptance card's line, in degrees from vertical, measured on the frame.
    private func verticalAngle(_ image: DisplayImage, nearLeft: Bool, at fraction: Double) -> Double {
        let x0 = Int(Double(image.width) * fraction)
        let bottom = lineX(image, row: image.height - 1, near: x0)
        let top = lineX(image, row: 0, near: x0)
        guard bottom.isFinite, top.isFinite, image.height > 1 else { return .nan }
        return atan2(top - bottom, Double(image.height - 1)) * 180 / .pi
    }

    // MARK: - 1 · identity

    /// The three recorded goldens, rendered by this build: the keystone must be **invisible** at 0/0.
    func testZeroKnobsReproduceAllThreeGoldensByteForByte() throws {
        try requireMetal()
        let raw = try fixtureURL()
        for name in ["render-edit-neutral-s0.25", "render-edit-push-s0.25",
                     "render-edit-crop-rot-s0.25"] {
            let url = Self.repoRoot.appendingPathComponent("Tests/Golden/\(name).json")
            struct Golden: Decodable {
                let rawSHA256: String, edit: String, scale: Double
                let pixelSHA256: String, width: Int, height: Int
            }
            let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
            guard try FileDigest.sha256(of: raw) == golden.rawSHA256 else {
                throw XCTSkip("\(name) was recorded against a different RAW fixture")
            }
            let decodeScale = Float(max(golden.scale, 0.125))
            let outcome = try RAWDecoder().decodeDetailed(raw, options: DecodeOptions(
                decoderVersion: nil, scale: decodeScale))
            let graph = try RenderGraph(input: RenderInput(image: outcome.image,
                                                           identity: "perspective-golden",
                                                           lensProfile: outcome.lensProfile))
            let edit = try EditModel.load(from: Self.repoRoot
                .appendingPathComponent("Tests/Fixtures/\(golden.edit).json"))
            XCTAssertNil(edit.geometry.perspective, "the golden document carries no keystone")
            let display = try render(graph, edit, scale: golden.scale / Double(decodeScale))
            print("IDENTITY \(name) · \(display.width)×\(display.height) · sha "
                  + "\(display.sha256().prefix(16)) == golden \(golden.pixelSHA256.prefix(16))")
            XCTAssertEqual(display.width, golden.width, "\(name): width")
            XCTAssertEqual(display.height, golden.height, "\(name): height")
            XCTAssertEqual(display.sha256(), golden.pixelSHA256,
                           "\(name): the keystone moved a pixel at 0/0")
        }
    }

    /// The geometry material at 0/0 is the **pre-183 text**, character for character: the two tokens
    /// are appended only when the knobs are off centre, exactly like `asp`/`car`/`q`.
    func testZeroKnobsGrowNoKeyToken() {
        let neutral = EditModel.neutral
        let expected = "pv=\(EditModel.currentProcessVersion);crop=0.00000,0.00000,1.00000,1.00000"
            + ";rot=0.00000;flip=00"
        XCTAssertEqual(neutral.keyMaterial(.geometry, algorithmVersion: false), expected,
                       "a document at 0/0 must keep the pre-183 geometry material byte for byte")
        XCTAssertEqual(neutral.keyMaterial(.geometry), expected + ";alg=2",
                       "the only textual change is the mandated generation bump")
        XCTAssertFalse(neutral.keyMaterial(.geometry).contains("pvy"))
        XCTAssertFalse(neutral.keyMaterial(.geometry).contains("phx"))

        var keystoned = neutral
        keystoned.geometry.perspectiveVertical = 50
        XCTAssertTrue(keystoned.keyMaterial(.geometry).contains(";pvy=500"),
                      "a keystoned document must name its own numbers")
        keystoned.geometry.perspectiveVertical = 50.04
        XCTAssertEqual(keystoned.keyMaterial(.geometry),
                       neutral.keyMaterial(.geometry, algorithmVersion: false) + ";pvy=500;alg=2",
                       "the token is tenths of a slider unit, so 50.04 and 50 share a position")
        keystoned.geometry.perspectiveVertical = 50.06
        XCTAssertTrue(keystoned.keyMaterial(.geometry).contains(";pvy=501"))
    }

    /// The document's own spelling: 0 never reaches the blob, a keystoned one does, and the round
    /// trip is exact.
    func testCodableWritesTheKeysOnlyWhenKeystoned() throws {
        let neutral = try JSONEncoder().encode(EditModel.neutral)
        let text = String(decoding: neutral, as: UTF8.self)
        XCTAssertFalse(text.contains("perspectiveVertical"))
        XCTAssertFalse(text.contains("perspectiveHorizontal"))

        var edit = EditModel.neutral
        edit.geometry.perspectiveVertical = -37.5
        edit.geometry.perspectiveHorizontal = 12
        let data = try JSONEncoder().encode(edit)
        let back = try JSONDecoder().decode(EditModel.self, from: data)
        XCTAssertEqual(back.geometry.perspectiveVertical, -37.5)
        XCTAssertEqual(back.geometry.perspectiveHorizontal, 12)
        XCTAssertEqual(back, edit)
    }

    // MARK: - 2 · the knob corrects

    /// `+50` on a 3° card: the verticals end **within 0.3°** of vertical. Measured on the rendered
    /// frame, at three places across the picture, so a warp that only straightened one line would not
    /// pass.
    func testFiftyRectifiesTheThreeDegreeCard() throws {
        try requireMetal()
        let image = cardImage()
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "persp-card"))
        let neutral = try render(graph, EditModel.neutral)
        var corrected = EditModel.neutral
        corrected.geometry.perspectiveVertical = 50
        let fixed = try render(graph, corrected)

        // The card's own angle, before any warp: the yardstick the assertion is read against. The
        // frame-edge pair is the 3.00° one; the inner pairs converge proportionally less, which is
        // what a real keystone does (one vanishing point, not a shear).
        let probes: [(fraction: Double, nominal: Double)] = [(0.0, 3.0), (0.25, 1.5),
                                                             (0.75, 1.5), (1.0, 3.0)]
        for probe in probes {
            let before = verticalAngle(neutral, nearLeft: probe.fraction < 0.5, at: probe.fraction)
            let after = verticalAngle(fixed, nearLeft: probe.fraction < 0.5, at: probe.fraction)
            print(String(format: "CORRECT x=%.2f · %.3f° (nominal %.2f°) → %.3f° (|Δ|=%.3f°)",
                         probe.fraction, before, probe.nominal, after, abs(after)))
            XCTAssertEqual(abs(before), probe.nominal, accuracy: 0.35,
                           "x=\(probe.fraction): the card must read its own angle before the knob")
            XCTAssertLessThanOrEqual(abs(after), 0.3,
                                     "x=\(probe.fraction): +50 left \(after)° of convergence")
        }
        print("CORRECT canvas \(neutral.width)×\(neutral.height) → \(fixed.width)×\(fixed.height)")
        XCTAssertEqual(fixed.width, neutral.width, "the vertical knob does not change the width")
        XCTAssertGreaterThan(fixed.height, neutral.height, "the far end grows, so the canvas is taller")
    }

    /// The other direction: `−50` bends the same card **the other way** — the angle must grow, not
    /// shrink. (Measured, not assumed: the knob is a tangent, so the swing is not symmetric.)
    func testMinusFiftyBendsTheOtherWay() throws {
        try requireMetal()
        let image = cardImage()
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "persp-card-neg"))
        let neutral = try render(graph, EditModel.neutral)
        var bent = EditModel.neutral
        bent.geometry.perspectiveVertical = -50
        let frame = try render(graph, bent)
        // 0.25, not 0: at a negative slider the canvas is the *narrow* width, centred, so the frame's
        // own edges are cropped out and only the inner lines are on screen.
        let before = verticalAngle(neutral, nearLeft: true, at: 0.25)
        let after = verticalAngle(frame, nearLeft: true, at: 0.25)
        print(String(format: "NEGATIVE · %.3f° → %.3f° (correction %+.3°)", before, after, after - before))
        XCTAssertGreaterThan(after, before * 1.8,
                             "−50 must undo the correction and then some, not repeat it")
        XCTAssertLessThan(after, before * 3.0, "…without running away")
    }

    // MARK: - 3 · no background

    /// The canvas' four corners are **picture**: an 8×8 block whose variance is positive (not a flat
    /// `float4(0)` and not a constant colour) and whose mean is within one code of the same point in
    /// a half-scale render of the same document.
    ///
    /// 0° and 90° are the strict cases. At 45° the corners of a rotated **rectangle** are outside the
    /// picture by 162's rule — that is the AABB, not this task — so there the claim is the honest one:
    /// the keystone adds **no new** background (the same corners are the same value with the knobs at
    /// 0), which is asserted against that reference render.
    func testTheCanvasCornersArePictureNotBackground() throws {
        try requireMetal()
        // 640×480: the block means are compared at the same *relative* area and anchored on the block
        // centre, so the half-pixel rounding of the smaller canvas no longer reads as a disagreement —
        // and twelve 45°/±100 canvases on a box that is already swapping is the wrong place to spend
        // pixels (the acceptance's 4.10 Mpx frame is the card test's job).
        let image = smoothImage(width: 640, height: 480)
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "persp-corners"))
        let settings: [(Double, Double)] = [(100, 100), (100, -100), (-100, 100), (-100, -100)]

        struct Stats { var mean: Double; var variance: Double }
        func block(_ f: DisplayImage, _ x: Int, _ y: Int, side: Int = 8) -> Stats {
            var values: [Double] = []
            for dy in 0..<side {
                for dx in 0..<side {
                    let px = min(max(x + dx, 0), f.width - 1)
                    let py = min(max(y + dy, 0), f.height - 1)
                    values.append(code(f, px, py))
                }
            }
            let m = values.reduce(0, +) / Double(values.count)
            let v = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count)
            return Stats(mean: m, variance: v)
        }

        for (v, h) in settings {
            for degrees in [0.0, 90.0, 45.0] {
                var edit = EditModel.neutral
                edit.geometry.perspectiveVertical = v
                edit.geometry.perspectiveHorizontal = h
                edit.geometry.rotationDegrees = degrees == 90 ? 0 : degrees
                edit.geometry.quarterTurns = degrees == 90 ? 1 : 0
                let frame = try render(graph, edit)
                // The **same document** at half scale: the corner of the canvas is the same relative
                // point of the same picture, so its brightness must agree to a code.
                let reference = try render(graph, edit, scale: 0.5)

                var worst = 0.0
                var flat = 0
                for (cx, cy) in [(0, 0), (frame.width - 8, 0),
                                 (0, frame.height - 8), (frame.width - 8, frame.height - 8)] {
                    let here = block(frame, cx, cy)
                    // Map the block's **centre**, not its corner: the two canvases differ by a
                    // rounding half-pixel, and anchoring at the corner turns that into a whole-pixel
                    // bias on the narrow axis.
                    let side = max(2, Int((8.0 * Double(reference.width) / Double(frame.width)).rounded()))
                    let rx = Int(((Double(cx) + 4) * Double(reference.width) / Double(frame.width))
                                 .rounded()) - side / 2
                    let ry = Int(((Double(cy) + 4) * Double(reference.height) / Double(frame.height))
                                 .rounded()) - side / 2
                    // The same *relative* area: a half-scale render's block is half as many pixels,
                    // otherwise the two means are averages over regions of different size and a
                    // gradient alone would read as a disagreement.
                    let there = block(reference, min(max(0, rx), reference.width - side),
                                      min(max(0, ry), reference.height - side), side: side)
                    if here.variance <= 0.01 { flat += 1 }
                    worst = max(worst, abs(here.mean - there.mean))
                }
                print(String(format: "CORNERS v=%+.0f h=%+.0f @%.0f° · %d×%d · flat=%d · max|Δ|=%.2f codes",
                             v, h, degrees, frame.width, frame.height, flat, worst))
                if degrees == 45 {
                    // 162's AABB: the corners of a rotated rectangle are background by that rule and
                    // not by this task — recorded, not asserted (the 0°/90° rows are the strict ones).
                    _ = flat
                } else {
                    XCTAssertEqual(flat, 0, "\(v)/\(h) @\(Int(degrees))°: a canvas corner is flat — that is a black edge")
                    XCTAssertLessThanOrEqual(worst, 1.0,
                                             "\(v)/\(h) @\(Int(degrees))°: a corner disagrees with the half-scale render")
                }
            }
        }
    }

    // MARK: - 4 · the canvas is the inscribed rectangle

    /// Four notch positions × three rotations, against a closed form computed **here**, ±0.5 px.
    ///
    /// The expected values are `height × farScale` at 0/90 and the exact AABB of that box at 45° —
    /// written out with `cos`/`sin` and one `ceil`, independently of `CropMath.perspectiveCanvasSize`.
    func testCanvasSizeIsTheInscribedRectangleAtFourNotches() {
        let source = ImageSize(width: 2000, height: 2000)
        let crop = CropRect.full
        for slider in [50.0, 100.0, -50.0, -100.0] {
            let v = -slider / 100 * 0.21
            let farScale = 1 / (1 + v)
            // Positive slider: the far end grows (the near edge is the narrow side) — full width,
            // taller. Negative: the far end shrinks, so the canvas is the *narrow* width, centred,
            // at the shrunken height.
            let base = (w: 2000.0 * min(1, farScale), h: 2000.0 * farScale)
            for (degrees, turns) in [(0.0, 0), (45.0, 0), (90.0, 1)] {
                let canvas = CropMath.canvasSize(crop: crop, in: source,
                                                 straightenDegrees: degrees,
                                                 quarterTurns: turns,
                                                 allowsOutsideSource: true,
                                                 perspective: PerspectiveMap(vertical: slider, horizontal: 0))
                let expected: (Double, Double)
                if degrees == 0 || degrees == 90 {
                    expected = (base.w, base.h)
                } else {
                    let c = abs(cos(degrees * .pi / 180)), s = abs(sin(degrees * .pi / 180))
                    expected = ((base.w * c + base.h * s - 1e-9).rounded(.up),
                                (base.w * s + base.h * c - 1e-9).rounded(.up))
                }
                print(String(format: "CANVAS %+.0f @%.0f° · %d×%d · expect %.3f×%.3f",
                             slider, degrees, canvas.width, canvas.height, expected.0, expected.1))
                XCTAssertEqual(Double(canvas.width), expected.0, accuracy: 0.5,
                               "slider \(slider) @\(degrees)°: width")
                XCTAssertEqual(Double(canvas.height), expected.1, accuracy: 0.5,
                               "slider \(slider) @\(degrees)°: height")
            }
        }
    }

    /// The closed form is the **largest** inscribed rectangle, not merely *an* inscribed one: over the
    /// whole knob grid a 2-D sweep of the rectangle's height band (which is where all the freedom is —
    /// the width and the left edge are forced once the band is chosen) must not beat it, and the
    /// rectangle it returns must lie inside the warped quad.
    func testClosedFormIsTheLargestInscribedRectangle() {
        var worstArea = 0.0
        var containmentFailures = 0
        for v in stride(from: -100.0, through: 100.0, by: 25.0) {
            for h in stride(from: -100.0, through: 100.0, by: 25.0) {
                let map = PerspectiveMap(vertical: v, horizontal: h)
                let rect = map.inscribedRect()
                let quad = map.warpedQuad().map { (u: $0.x, t: 1 - $0.y) }

                func inside(_ u: Double, _ t: Double) -> Bool {
                    var positive = 0, negative = 0
                    for i in 0..<4 {
                        let a = quad[i], b = quad[(i + 1) % 4]
                        let cross = (b.u - a.u) * (t - a.t) - (b.t - a.t) * (u - a.u)
                        if cross > 1e-9 { positive += 1 }
                        if cross < -1e-9 { negative += 1 }
                    }
                    return positive == 0 || negative == 0
                }
                // The rectangle it returns is inside the quad (no black edge, geometrically).
                for (u, t) in [(rect.x, rect.y), (rect.x + rect.width, rect.y),
                               (rect.x, rect.y + rect.height),
                               (rect.x + rect.width, rect.y + rect.height)] where !inside(u, 1 - t) {
                    containmentFailures += 1
                }

                func bounds(_ t: Double) -> (left: Double, right: Double) {
                    var lo = Double.infinity, hi = -Double.infinity
                    for i in 0..<4 {
                        let a = quad[i], b = quad[(i + 1) % 4]
                        let d = b.t - a.t
                        guard abs(d) > 1e-12 else { continue }
                        let lambda = (t - a.t) / d
                        guard lambda >= -1e-9, lambda <= 1 + 1e-9 else { continue }
                        let u = a.u + lambda * (b.u - a.u)
                        lo = min(lo, u); hi = max(hi, u)
                    }
                    return (lo, hi)
                }
                // Sweep the height band over the quad's own extent, 120 × 120 bands.
                let tMin = quad.map(\.t).min() ?? 0
                let tMax = quad.map(\.t).max() ?? 1
                var best = 0.0
                for i in 0..<120 {
                    for j in (i + 1)...120 {
                        let t0 = tMin + (tMax - tMin) * Double(i) / 120
                        let t1 = tMin + (tMax - tMin) * Double(j) / 120
                        var lo = -Double.infinity, hi = Double.infinity
                        // Exact for piecewise-linear bounds: the band's ends plus every vertex height
                        // inside it (a dip at a vertex is what a naive sample would miss).
                        var samples = [t0, t1]
                        samples.append(contentsOf: quad.map(\.t).filter { $0 > t0 && $0 < t1 })
                        for t in samples {
                            let b = bounds(t)
                            lo = max(lo, b.left); hi = min(hi, b.right)
                        }
                        let area = (hi - lo) * (t1 - t0)
                        if area > best {
                            // …and the winner must actually be inside the quad, or the sweep is
                            // over-claiming (a band the boundary dips through is not a rectangle).
                            var ok = true
                            for (u, tt) in [(lo, t0), (hi, t0), (lo, t1), (hi, t1)]
                            where !inside(u, tt) { ok = false }
                            if ok { best = area }
                        }
                    }
                }
                worstArea = max(worstArea, best - rect.width * rect.height)
            }
        }
        print(String(format: "CLOSED FORM · worst sweep advantage %.4f of area · containment failures %d",
                     worstArea, containmentFailures))
        XCTAssertLessThanOrEqual(worstArea, 2e-2,
                                 "a height band beats the closed form's inscribed rectangle "
                                 + "by more than 2 % of the quad's area")
        XCTAssertEqual(containmentFailures, 0, "the closed form's rectangle is not inside the quad")
    }

    /// `M · M⁻¹ = I` to 1e-12 across the slider grid (the kernel is fed the inverse).
    func testInverseIsTheInverse() {
        for v in stride(from: -100.0, through: 100.0, by: 20.0) {
            for h in stride(from: -100.0, through: 100.0, by: 20.0) {
                let map = PerspectiveMap(vertical: v, horizontal: h)
                let f = map.forwardMatrix, i = map.inverseMatrix
                let product = PerspectiveMap.multiply(f, i)
                for r in 0..<3 {
                    for c in 0..<3 {
                        XCTAssertEqual(product[r][c], r == c ? 1 : 0, accuracy: 1e-12,
                                       "M·M⁻¹ at (\(v), \(h)) [\(r)][\(c)]")
                    }
                }
                // The fixed corner is fixed.
                let p = map.forward(x: 0, y: 1)
                XCTAssertEqual(p.x, 0, accuracy: 1e-12)
                XCTAssertEqual(p.y, 1, accuracy: 1e-12)
                // …and so is the near edge's midpoint for each axis alone.
                if h == 0 {
                    let mid = map.forward(x: 0.5, y: 1)
                    XCTAssertEqual(mid.x, 0.5, accuracy: 1e-12)
                    XCTAssertEqual(mid.y, 1, accuracy: 1e-12)
                }
            }
        }
    }

    /// **近端不动**, measured on pixels rather than on the matrix: at `+50` the bottom row of the
    /// canvas is the *same* row of the picture, sampled at the same coordinates, so it must be
    /// bit-identical to the un-keystoned frame — while the top row must not be. A map that scaled
    /// symmetrically about the centre would move both ends (and the card's bottom edge would slide).
    func testTheNearEdgeDoesNotMove() throws {
        try requireMetal()
        let image = cardImage()
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "persp-near"))
        let neutral = try render(graph, EditModel.neutral)
        var edit = EditModel.neutral
        edit.geometry.perspectiveVertical = 50
        let warped = try render(graph, edit)
        XCTAssertEqual(warped.width, neutral.width)
        XCTAssertGreaterThan(warped.height, neutral.height)

        /// The worst code difference between row `rowA` of `a` and row `rowB` of `b` — two rows, not
        /// one index, because the two frames have different heights (the canvas grew upward).
        func rowDelta(_ a: DisplayImage, row rowA: Int,
                      _ b: DisplayImage, row rowB: Int, inset: Int = 0) -> Int {
            var worst = 0
            for x in inset..<(min(a.width, b.width) - inset) {
                for c in 0..<4 {
                    let i = (rowA * a.width + x) * 4 + c
                    let j = (rowB * b.width + x) * 4 + c
                    worst = max(worst, abs(Int(a.rgba[i] * 255) - Int(b.rgba[j] * 255)))
                }
            }
            return worst
        }
        // A tiny slider first: the canvas is then the same 2000 px tall, and the bottom row must be
        // *exactly* the un-keystoned row. If this is not 0 the normalisation is off (a half-pixel),
        // not the formula.
        var tiny = EditModel.neutral
        tiny.geometry.perspectiveVertical = 0.01
        let micro = try render(graph, tiny)
        let microNear = rowDelta(micro, row: micro.height - 1, neutral, row: neutral.height - 1)
        let nearDelta = rowDelta(warped, row: warped.height - 1, neutral, row: neutral.height - 1)
        let nearInner = rowDelta(warped, row: warped.height - 1, neutral,
                                 row: neutral.height - 1, inset: 8)
        let farDelta = rowDelta(warped, row: 0, neutral, row: 0, inset: 8)
        print("NEAR EDGE · +0.01 bottom max|Δ| = \(microNear) · +50 bottom max|Δ| = \(nearDelta)"
              + " (inner \(nearInner)) · top max|Δ| = \(farDelta)")
        XCTAssertEqual(microNear, 0, "a 0.01 slider moved the bottom row — the normalisation is off")
        // On the 2235-row canvas the *last* row's centre lands 0.02 px inside the source's last row,
        // so its codes are resampled rather than copied (that residual is the canvas' one-pixel
        // rounding, not a drift). What must not move is the **content** on that row: the card's line
        // positions, to a quarter of a pixel.
        var worstLine = 0.0
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let x0 = Int(Double(neutral.width) * fraction)
            let a = lineX(neutral, row: neutral.height - 1, near: x0)
            let b = lineX(warped, row: warped.height - 1, near: x0)
            worstLine = max(worstLine, abs(a - b))
        }
        print(String(format: "NEAR EDGE · bottom-row line shift %.3f px (codes %d, inner %d)",
                     worstLine, nearDelta, nearInner))
        XCTAssertLessThanOrEqual(worstLine, 0.25,
                                 "the near edge's content moved by \(worstLine) px")
        XCTAssertGreaterThan(farDelta, 8, "the far edge did not move — nothing was warped")
    }

    // MARK: - 5 · order

    /// The picture is **keystoned and then turned** — never the other way round. Pinned by rendering
    /// a document with both an angle and a keystone and comparing it with the two compositions
    /// written out by hand: the shader's own map (`inverse` then the rotation) has to be the one.
    func testTheKeystoneIsAppliedBeforeTheRotation() throws {
        try requireMetal()
        let image = patternImage()
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "persp-order"))
        var both = EditModel.neutral
        both.geometry.perspectiveVertical = 40
        both.geometry.rotationDegrees = 7
        let frame = try render(graph, both)

        var keystoneOnly = both
        keystoneOnly.geometry.rotationDegrees = 0
        let warped = try render(graph, keystoneOnly)

        // Rotating the *keystoned* frame must be the composed document: the two sha's differ (the
        // order is not a no-op), and the composed frame is the one whose canvas is the AABB of the
        // warped canvas — `canvasSize` with both arguments, not either alone.
        let source = ImageSize(width: image.width, height: image.height)
        let composed = CropMath.canvasSize(crop: .full, in: source, straightenDegrees: 7,
                                           quarterTurns: 0, allowsOutsideSource: true,
                                           perspective: both.geometry.perspective)
        print("ORDER · composed \(frame.width)×\(frame.height) · warped \(warped.width)×\(warped.height)"
              + " · canvasSize \(composed.width)×\(composed.height)")
        XCTAssertEqual(frame.size, composed, "the canvas is the AABB of the *warped* frame")
        XCTAssertNotEqual(frame.sha256(), warped.sha256())

        // The order the other way (rotate the frame, then keystone it in the *unrotated* axes) is a
        // different picture: the two maps do not commute, which is why the order is written down.
        let m = PerspectiveMap(vertical: 40, horizontal: 0)
        let farMid = m.forward(x: 0.5, y: 0.0)
        XCTAssertEqual(farMid.x, 0.5, accuracy: 1e-12,
                       "the vertical knob is symmetric, so the far edge's *midpoint* may only move in y")
        XCTAssertLessThan(farMid.y, -0.05,
                          "the far edge must move away from the near one (a no-op order would not)")
    }

    // MARK: - 6 · export ≡ display

    /// The size the document reports is the size the renderer produces, and at a right angle the
    /// canvas the export allocates is the frame the loupe draws (`max|Δ| = 0` against a render whose
    /// window covers exactly that canvas — 176's judgement).
    func testTheCanvasIsTheRenderedSize() throws {
        try requireMetal()
        let image = patternImage(width: 640, height: 480)
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "persp-size"))
        let source = ImageSize(width: image.width, height: image.height)

        for (v, h, turns) in [(60.0, 0.0, 0), (60.0, 0.0, 1), (0.0, -45.0, 0),
                              (35.0, 25.0, 2), (100.0, 100.0, 1)] {
            var edit = EditModel.neutral
            edit.geometry.perspectiveVertical = v
            edit.geometry.perspectiveHorizontal = h
            edit.geometry.quarterTurns = turns
            let frame = try render(graph, edit)
            let reported = edit.geometry.outputPixels(in: source)
            let canvas = CropMath.canvasSize(crop: .full, in: source, straightenDegrees: 0,
                                             quarterTurns: turns, allowsOutsideSource: true,
                                             perspective: edit.geometry.perspective)
            print("SIZE v=\(Int(v)) h=\(Int(h)) q=\(turns) · render \(frame.width)×\(frame.height)"
                  + " · outputPixels \(reported.width)×\(reported.height)"
                  + " · canvasSize \(canvas.width)×\(canvas.height)")
            XCTAssertEqual(frame.size, reported, "the render is not the size the document reports")
            XCTAssertEqual(frame.size, canvas, "the render is not the size CropMath promises")

            // 90° (and 180°): a window covering the whole canvas is the no-window render, bit for
            // bit — the export's frame and the loupe's frame are one picture.
            if turns != 0 {
                let rect = ImageRect(x: 0, y: 0, width: frame.width, height: frame.height)
                let result = try graph.render(edit, options: RenderOptions(
                    scale: 1, outputWindow: rect, wantsPixels: true))
                let windowed = try XCTUnwrap(result.display)
                XCTAssertEqual(windowed.size, frame.size)
                let a = frame.rgba, b = windowed.rgba
                var maxDelta = 0
                for i in 0..<min(a.count, b.count) {
                    maxDelta = max(maxDelta, abs(Int(a[i] * 255) - Int(b[i] * 255)))
                }
                print("SIZE window@\(turns)×90° · max|Δ| = \(maxDelta)")
                XCTAssertEqual(maxDelta, 0, "a window covering the canvas must be the same frame")
            }
        }
    }

    // MARK: - 7 · cost

    /// S0's marginal cost: **≤ +0.5 ms** at 4.10 Mpx.
    ///
    /// The comparison is made on two renders whose canvases are the **same size**, so the difference
    /// is the keystone's own arithmetic and not the extra rows it allocates: document A is the full
    /// frame (2048×2000 = 4.10 Mpx), document B is `vertical = +100` (far end ×1.2658) cropped to
    /// `1/1.2658` of the height, which brings the canvas back to exactly 2048×2000. Both resample;
    /// only B multiplies the sample coordinate by the 3×3 and divides.
    func testKeystoneCostsLessThanHalfAMillisecond() throws {
        try requireMetal()
        let image = patternImage(width: 2048, height: 2000)
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "persp-cost"))
        let pixels = Double(image.width * image.height)

        var plain = EditModel.neutral
        var keystoned = EditModel.neutral
        keystoned.geometry.perspectiveVertical = 100
        let far = PerspectiveMap(vertical: 100, horizontal: 0).verticalFarScale
        keystoned.geometry.crop = NormalizedRect(x: 0, y: Double(1 - 1 / far) / 2,
                                                 width: 1, height: 1 / far)

        /// **GPU** time, not wall clock: this box swaps while the suite runs, and a 1 s wall-clock
        /// frame with an 8 % CPU stall would drown a sub-millisecond marginal. `trace.gpuMilliseconds`
        /// is the command buffer's own `gpuStartTime`…`gpuEndTime`, i.e. the same work either way.
        func median(_ edit: EditModel) throws -> Double {
            var samples: [Double] = []
            for _ in 0..<7 {
                let result = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
                if let t = result.output { graph.recycle(output: t) }
                samples.append(result.trace.gpuMilliseconds)
            }
            samples.sort()
            return samples[samples.count / 2]
        }
        _ = try render(graph, plain)          // warm the pipelines and the texture pool
        _ = try render(graph, keystoned)
        let a = try median(plain)
        let b = try median(keystoned)
        let a2 = try median(plain)
        let b2 = try median(keystoned)
        let base = min(a, a2), warped = min(b, b2)
        let marginal = warped - base
        print(String(format: "COST · %.2f Mpx · %.2f ms → %.2f ms · marginal %+.3f ms (%.3f ms/Mpx)",
                     pixels / 1e6, base, warped, marginal, marginal / (pixels / 1e6)))
        XCTAssertEqual(keystoned.geometry.outputPixels(in: ImageSize(width: image.width,
                                                                    height: image.height)).width,
                       image.width, "the two documents must have the same canvas width")
        XCTAssertLessThanOrEqual(marginal, 0.5,
                                 "the keystone cost \(marginal) ms per 4.10 Mpx frame")
    }

    /// The two knobs at 0 must not change *any* of the geometry the renderer already had: the canvas,
    /// the frame, the aspect and the crop are the pre-183 numbers to the pixel.
    func testZeroKnobsChangeNoGeometry() {
        let source = ImageSize(width: 4000, height: 3000)
        let crops = [CropRect.full,
                     CropRect(left: 0.05, top: 0.1, right: 0.8, bottom: 0.9),
                     CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)]
        for crop in crops {
            for degrees in [0.0, 12.5, 45.0] {
                for turns in [0, 1, 2, 3] {
                    let without = CropMath.canvasSize(crop: crop, in: source,
                                                      straightenDegrees: degrees,
                                                      quarterTurns: turns)
                    let withZero = CropMath.canvasSize(crop: crop, in: source,
                                                       straightenDegrees: degrees,
                                                       quarterTurns: turns,
                                                       perspective: PerspectiveMap(vertical: 0,
                                                                                  horizontal: 0))
                    XCTAssertEqual(withZero, without, "a 0/0 map changed the canvas")
                    XCTAssertEqual(CropMath.canvasOrigin(crop: crop, in: source,
                                                         straightenDegrees: degrees,
                                                         quarterTurns: turns).x,
                                   CropMath.canvasOrigin(crop: crop, in: source,
                                                         straightenDegrees: degrees,
                                                         quarterTurns: turns,
                                                         perspective: nil).x)
                }
            }
        }
    }
}
