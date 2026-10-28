import XCTest
import PhotonsCore
import Metal

/// 079 A4 — a shape's feather in **darktable's reading**: a short-edge percentage spent *outside* the
/// rim (interior exactly 1.0, quadratic falloff beyond), not a fraction of the shape spent inside it.
///
/// Before A4 both gradients narrowed the shape: `radial: 1 − smoothstep(1−f, 1, r)` made
/// `feather = 0.5` leave a solid region of **half** the radius, `linear: smoothstep(½−f/2, ½+f/2, t')`
/// moved the ramp *into* the covered half. darktable's drawn masks keep the shape solid to its rim and
/// put the feather outside (`masks/ellipse.c:1502-1534`). These five tests are the claims of that
/// change, each measured off the atlas the kernel wrote — never off a picture:
///
///   1. `feather = 0.5` at `r = 0.25` short edges keeps 100 % coverage out to **0.25** (was 0.125);
///   2. the 11-point profile: exactly 1.0 inside, monotone and quadratic outside, to the analytic
///      value within one 8-bit code;
///   3. `feather = 0` is the pre-A4 frame **byte for byte** (digest recorded on main `c9aa22e`);
///   4. `MaskBounds.rasterRect` covers the whole falloff — the bound is grown by the outward radius,
///      and the value at its edge is the analytic one (a box that stopped at the rim would cut it);
///   5. the linear gradient follows the same rule across its own half-way line.
///
/// The counter-proof is one edit: restore `1 − smoothstep(1 − f, 1, r)` in `s1_5_mask_atlas.metal` and
/// claim (1) goes red at 0.125 while (2) and (4) follow.
final class MaskFeatherShapeTests: XCTestCase {

    // MARK: - fixtures

    private func rampImage(width: Int = 400, height: Int = 300) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let v = Float(0.10 + 0.55 * Double(x) / Double(max(width - 1, 1)))
                rgba[o] = Float16(v)
                rgba[o + 1] = Float16(v * 0.95)
                rgba[o + 2] = Float16(v * 0.9)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func makeGraph(_ image: LinearImage, identity: String = "mask-feather-a4") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func atlas(_ edit: EditModel, _ image: LinearImage) throws -> MaskAtlasDump {
        let graph = try makeGraph(image)
        return try XCTUnwrap(try graph.maskAtlas(edit, options: RenderOptions(scale: 1)),
                             "a document with an enabled mask must produce an atlas")
    }

    /// One mask, one component, **no mask-level feather** (that operator is 005d's spatial blur, a
    /// different thing with a different radius function), so the atlas is the shape's own coverage.
    private func doc(_ shape: MaskShape, feather: Double,
                     adjustments: LocalAdjustments = LocalAdjustments(exposure: 0.8)) -> EditModel {
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-\(shape.kind)", opacity: 1, feather: 0, refine: 0,
                           components: [MaskComponent(id: "c", feather: feather, shape: shape)],
                           adjustments: adjustments)]
        return edit
    }

    private func sample(_ dump: MaskAtlasDump, _ x: Int, _ y: Int) -> Double {
        Double(dump.value(slice: 0, x: x, y: y) ?? -1)
    }

    // MARK: - the analytic reference (independent of the kernel, mirrors its algebra)

    /// `alpha = 1` for `r ≤ 1`; `clamp((r_out² − r²)/(r_out² − 1))²` beyond, `r_out = 1 + g` — the
    /// darktable ellipse rule with `g` = short-edge feather radius / min(rx, ry).
    private func radialAlpha(x: Double, y: Double, _ s: RadialGradientShape, feather f: Double,
                             size: (w: Int, h: Int)) -> Double {
        let w = Double(size.w), h = Double(size.h)
        let side = min(w, h)
        let cx = s.center.x * w, cy = s.center.y * h
        let radx = max(abs(s.radius.x) * side, 1e-4)
        let rady = max(abs(s.radius.y) * side, 1e-4)
        let t = s.angle * Double.pi / 180
        let cs = cos(t), sn = sin(t)
        let dvx = x - cx, dvy = y - cy
        let qx = (dvx * cs + dvy * sn) / radx
        let qy = (-dvx * sn + dvy * cs) / rady
        let r = (qx * qx + qy * qy).squareRoot()
        let radius = min(max(f, 0), 1)
        let featherPx = radius * 0.1 * side
        if featherPx <= 0 {
            // The pre-A4 expression, kept for `feather == 0` — and a division by zero at `r == 1`,
            // which is why the caller compares at pixel centres that never land on the rim exactly.
            let e0 = 1 - radius
            let tt = min(max((r - e0) / max(1 - e0, 1e-12), 0), 1)
            return 1 - tt * tt * (3 - 2 * tt)
        }
        let g = featherPx / min(radx, rady)
        let rOut = 1 + g
        let ratio = min(max((rOut * rOut - r * r) / (rOut * rOut - 1), 0), 1)
        return ratio * ratio
    }

    /// 102: a **symmetric** smoothstep ramp of width `f` centred on the half-way line. (079 A4's
    /// one-sided "outside the rim" ramp applied to the open shapes was the bug this file now records the
    /// fix for; the radial helper above keeps that rule.)
    private func linearAlpha(x: Double, y: Double, _ s: LinearGradientShape, feather f: Double,
                             size: (w: Int, h: Int)) -> Double {
        let w = Double(size.w), h = Double(size.h)
        let ax = s.start.x * w, ay = s.start.y * h
        let bx = s.end.x * w, by = s.end.y * h
        let dx = bx - ax, dy = by - ay
        let denom = max(dx * dx + dy * dy, 1e-12)
        var t = ((x - ax) * dx + (y - ay) * dy) / denom
        t = min(max(t, 0), 1)
        let m = min(max(s.midpoint, 0.02), 0.98)
        var tp = t
        if abs(m - 0.5) > 1e-6 && t > 0 { tp = pow(t, log(0.5) / log(m)) }
        let radius = min(max(f, 0), 1)
        let lo = 0.5 - 0.5 * radius
        let hi = max(0.5 + 0.5 * radius, lo + 1e-5)
        let tt = min(max((tp - lo) / (hi - lo), 0), 1)
        return tt * tt * (3 - 2 * tt)
    }

    private func h16(_ v: Float) -> Double { Double(Float16(v)) }

    // MARK: - 1. the solid region is the shape, not half of it

    /// `radial r = 0.25·短边`, `feather = 0.5`: 100 % coverage reaches the rim, i.e. **0.25** short
    /// edges, where the pre-A4 rule stopped at `r·(1 − f) = 0.125`. Area ×4, exactly as 079 A4 says.
    func testFeatherHalfKeepsTheFullyCoveredRadius() throws {
        let image = rampImage()                       // 400 × 300 → short edge 300 px
        let shape = RadialGradientShape(center: NormalizedPoint(0.5, 0.5),
                                        radius: NormalizedPoint(0.25, 0.25), angle: 0)
        let dump = try atlas(doc(.radialGradient(shape), feather: 0.5), image)

        let side = Double(min(image.width, image.height))
        let cx = Double(image.width) / 2               // pixel-centre coordinate of the centre pixel
        let cy = Double(image.height) / 2
        let featherPx = MaskRadius.featherPixels(0.5, content: ImageSize(width: image.width,
                                                                        height: image.height))

        // The last pixel on the horizontal radius whose coverage is *exactly* 1.0.
        var solid = 0.0
        var x = Int(cx)
        while x < image.width, sample(dump, x, Int(cy)) == 1.0 {
            solid = Double(x) + 0.5 - cx
            x += 1
        }
        let r100 = solid / side

        // The same measurement on the pre-A4 rule, for the record: `r(f=0.5) = 0.125`.
        let before = 0.25 * (1 - 0.5)

        print(String(format: "A4 radial r=0.25·side f=0.5: 100%% radius %.4f·side (%.1f px); "
                     + "pre-A4 %.4f·side (%.1f px); feather radius %.1f px",
                     r100, solid, before, before * side, featherPx))

        XCTAssertEqual(r100, 0.25, accuracy: 1.5 / side,
                       "the solid region must reach the rim: \(r100)·side, not \(before)·side")
        XCTAssertGreaterThan(r100, 0.2, "0.125·side is the pre-A4 answer — the feather must not eat in")
        XCTAssertEqual(sample(dump, Int(cx), Int(cy)), 1.0, "the centre must be exactly 1.0")

        // Nothing beyond the outer rim (r_out = 1 + featherR/R = 1.2) may be non-zero.
        let outer = 0.25 * side + featherPx
        for step in stride(from: outer + 1, to: outer + 12, by: 1) {
            let px = Int((cx + step).rounded(.down))
            guard px < image.width else { break }
            XCTAssertEqual(sample(dump, px, Int(cy)), 0, "coverage past r_out must be 0")
        }
    }

    // MARK: - 2. the profile: solid inside, quadratic outside

    /// 11 samples from the centre through the rim to the outer edge. Inside (`r ≤ 1`, the first eight
    /// samples) the coverage is **exactly** 1.0; beyond it, monotone decreasing and equal to
    /// `clamp((r_out² − r²)/(r_out² − 1))²` within one 8-bit code (the atlas is R16F; one code here is
    /// 1/255, the resolution every consumer reads it at).
    func testFeatherProfileIsSolidInsideAndQuadraticOutside() throws {
        let image = rampImage()                       // short edge 300 px
        let shape = RadialGradientShape(center: NormalizedPoint(0.5, 0.5),
                                        radius: NormalizedPoint(0.25, 0.25), angle: 0)
        let dump = try atlas(doc(.radialGradient(shape), feather: 0.5), image)

        let side = Double(min(image.width, image.height))
        let cx = Double(image.width) / 2, cy = Double(image.height) / 2
        let featherPx = 0.05 * side                   // feather 0.5 → 5 % of the short edge
        let rOut = 1 + featherPx / (0.25 * side)      // 1.2 in shape-radius units

        // 11 points, 0 … r_out in 0.12 steps of the shape radius (9 px at this size), on the +x ray.
        var rows: [String] = []
        var values: [Double] = []
        var previous = 2.0
        for i in 0...10 {
            let rShape = rOut * Double(i) / 10
            let offset = rShape * 0.25 * side
            let x = Int((cx + offset).rounded(.down))
            let y = Int(cy)
            let got = sample(dump, x, y)
            let expected = radialAlpha(x: Double(x) + 0.5, y: Double(y) + 0.5, shape,
                                       feather: 0.5, size: (image.width, image.height))
            values.append(got)
            rows.append(String(format: "r=%5.3f·R  r=%5.3f·side  x=%3d  coverage %.6f  analytic %.6f",
                               rShape, rShape * 0.25, x, got, expected))
            XCTAssertEqual(got, expected, accuracy: 1.0 / 255.0,
                           "sample \(i) (r = \(rShape)·R) disagrees with the quadratic falloff")
            XCTAssertLessThanOrEqual(got, previous + 1e-6, "the profile grew outwards at sample \(i)")
            previous = got
        }
        print("A4 radial feather profile (f = 0.5, r = 0.25·side, r_out = \(rOut)·R):\n"
              + rows.joined(separator: "\n"))

        // Inside the rim (samples 0…8 cover r ≤ 0.96·R) the coverage is exactly 1.0 …
        for i in 0...8 {
            XCTAssertEqual(values[i], 1.0, accuracy: 0,
                           "sample \(i) is inside the rim and must be exactly 1.0")
        }
        // … and outside it strictly positive, strictly decreasing, reaching 0 at the outer edge.
        XCTAssertGreaterThan(values[9], 0, "the falloff must be visible one step past the rim")
        XCTAssertLessThan(values[9], 1, "… and it must be a falloff, not a plateau")
        XCTAssertLessThanOrEqual(values[10], 1.0 / 255.0, "the outer edge must have reached 0")
        XCTAssertEqual(values[8] - values[9], 1.0 - values[9], accuracy: 1e-9,
                       "1.0 · R is still solid: only the falloff may move the value")

        // The falloff itself, sampled densely: `ratio = (r_out² − r²)/(r_out² − 1)`, out = ratio². Six
        // points from the rim to the outer edge, each within one 8-bit code, strictly decreasing, and
        // the shape of the curve pinned by the ratio between two of them (a linear ramp would give
        // 0.55 where the square gives 0.30).
        print("A4 radial falloff (r_out = \(rOut)·R):")
        var last = 2.0
        var falloff: [Double] = []
        for step in 0...10 {
            let rShape = 1 + 0.2 * Double(step) / 10          // 1.00 … 1.20 in shape-radius units
            let offset = rShape * 0.25 * side
            let x = Int((cx + offset).rounded(.down))
            let got = sample(dump, x, Int(cy))
            let expected = radialAlpha(x: Double(x) + 0.5, y: Double(cy) + 0.5, shape,
                                       feather: 0.5, size: (image.width, image.height))
            falloff.append(got)
            print(String(format: "r=%.3f·R  x=%3d  coverage %.6f  analytic %.6f", rShape, x, got, expected))
            XCTAssertEqual(got, expected, accuracy: 1.0 / 255.0,
                           "the falloff at \(rShape)·R disagrees with the squared ratio")
            XCTAssertLessThanOrEqual(got, last + 1e-6, "the falloff must be monotone at \(rShape)·R")
            last = got
        }
        XCTAssertEqual(sample(dump, Int(cx) + 74, Int(cy)), 1.0, accuracy: 0,
                       "the last pixel whose centre is inside the rim must be exactly 1.0")
        XCTAssertLessThan(falloff.first ?? 1, 1.0,
                          "the first pixel past the rim must already be falling")
        XCTAssertLessThanOrEqual(falloff.last ?? 1, 1.0 / 255.0, "the outer edge is zero")
        XCTAssertGreaterThan(falloff[2], falloff[7], "the decay must be real, not numeric dust")
    }

    // MARK: - 3. linear gradient: symmetric ramp, unlike the radial rule

    /// 102 — the linear feather is a **symmetric** ramp of width `f` of the span, centred on the
    /// half-way line, so coverage is 0 below `½ − f/2`, 0.5 at `½` and 1 above `½ + f/2`. 079 A4 had
    /// pinned the opposite (solid past `½`, a squared `0.1·shortEdge` band below it) by applying the
    /// radial rule to the open shapes. That was the regression: one-sided and a tenth as wide.
    func testLinearFeatherIsSymmetricAboutTheHalfWayLine() throws {
        let image = rampImage(width: 320, height: 300)
        let shape = LinearGradientShape(start: NormalizedPoint(0.5, 0), end: NormalizedPoint(0.5, 1))
        var worst = 0.0
        for f in [0.0, 0.2, 1.0] {
            let dump = try atlas(doc(.linearGradient(shape), feather: f), image)
            for y in 0..<image.height {
                for x in stride(from: 0, to: image.width, by: 7) {
                    let expected = linearAlpha(x: Double(x) + 0.5, y: Double(y) + 0.5, shape,
                                               feather: f, size: (image.width, image.height))
                    worst = max(worst, abs(expected - sample(dump, x, y)))
                }
            }
            // Past the ramp it is solid; below it, empty. At f = 0 that is the hard edge at ½.
            let solidFrom = Int(((0.5 + 0.5 * f) * Double(image.height)).rounded(.up))
            let emptyBelow = Int(((0.5 - 0.5 * f) * Double(image.height)).rounded(.down))
            for y in solidFrom..<image.height {
                XCTAssertEqual(sample(dump, image.width / 2, y), 1.0,
                               "f = \(f): the half past the ramp must be exactly 1.0 (row \(y))")
            }
            for y in 0..<emptyBelow {
                XCTAssertEqual(sample(dump, image.width / 2, y), 0.0,
                               "f = \(f): the half below the ramp must be exactly 0.0 (row \(y))")
            }
        }
        XCTAssertLessThan(worst, 1.5 / 255.0, "the linear gradient deviates from its own reference")
    }

    // MARK: - 4. feather 0 is the pre-A4 frame, byte for byte

    /// The two digests were recorded on **main `c9aa22e`**, i.e. with the pre-A4 kernel: `feather == 0`
    /// must keep the old expression verbatim (both kernels still carry it), so every document in the
    /// wild that has no shape feather renders the same bytes it did before the change.
    func testFeatherZeroFrameIsByteIdenticalToThePreA4Graph() throws {
        let image = rampImage(width: 160, height: 120)
        let radial = doc(.radialGradient(RadialGradientShape(center: NormalizedPoint(0.5, 0.5),
                                                             radius: NormalizedPoint(0.3, 0.25),
                                                             angle: 20)),
                         feather: 0)
        let linear = doc(.linearGradient(LinearGradientShape(start: NormalizedPoint(0.2, 0.1),
                                                             end: NormalizedPoint(0.7, 0.95),
                                                             midpoint: 0.4)),
                         feather: 0)

        let radialSHA = try XCTUnwrap(try makeGraph(image).render(
            radial, options: RenderOptions(scale: 1, wantsPixels: true)).display).sha256()
        let linearSHA = try XCTUnwrap(try makeGraph(image).render(
            linear, options: RenderOptions(scale: 1, wantsPixels: true)).display).sha256()

        print("A4 feather 0 frame sha256 (radial) = \(radialSHA)")
        print("A4 feather 0 frame sha256 (linear) = \(linearSHA)")

        XCTAssertEqual(radialSHA, Self.radialFeatherZeroSHA,
                       "a radial mask with feather 0 must be the pre-A4 frame, byte for byte")
        XCTAssertEqual(linearSHA, Self.linearFeatherZeroSHA,
                       "a linear mask with feather 0 must be the pre-A4 frame, byte for byte")
    }

    /// Recorded on main `c9aa22e` (pre-A4 kernel). `swift test --filter testFeatherZeroFrameIsByte`
    /// prints the current values if a deliberate change ever has to move them.
    private static let radialFeatherZeroSHA = "7adba4e58d4550689e566bec4992d467617abf4fb2ed3483d8a8cfce1df4b8ea"
    private static let linearFeatherZeroSHA = "8d63b9200f0d63d808f47617ee923920e4243ba4fbf905e81fc36031603aeb83"

    // MARK: - 5. the raster box covers the falloff

    /// `MaskBounds.rasterRect` is the box the kernel evaluates in: coverage outside it is not
    /// computed, it is written as +0.0. A bound that stopped at the rim would therefore **cut** the
    /// feather — the silent failure A4 has to rule out, because the outward radius is new geometry
    /// rather than a wider blur kernel.
    func testRasterBoxIsGrownByTheOutwardFeather() throws {
        let image = rampImage(width: 320, height: 240)     // short edge 240 px
        let shape = RadialGradientShape(center: NormalizedPoint(0.5, 0.5),
                                        radius: NormalizedPoint(0.25, 0.25), angle: 0)
        var hard = doc(.radialGradient(shape), feather: 0)
        var soft = doc(.radialGradient(shape), feather: 0.5)
        hard.masks[0].adjustments = LocalAdjustments(exposure: 0.6)
        soft.masks[0].adjustments = LocalAdjustments(exposure: 0.6)

        let frame = ImageSize(width: image.width, height: image.height)
        let hardBox = MaskBounds.rasterRect(for: hard.masks[0],
                                            mapping: MaskCanvasMapping(geometry: hard.geometry,
                                                                       source: frame, content: frame,
                                                                       canvas: frame, origin: (0, 0)))
        let softBox = MaskBounds.rasterRect(for: soft.masks[0],
                                            mapping: MaskCanvasMapping(geometry: soft.geometry,
                                                                       source: frame, content: frame,
                                                                       canvas: frame, origin: (0, 0)))

        let side = Double(min(image.width, image.height))
        let rim = 0.25 * side
        let featherPx = MaskRadius.featherPixels(0.5, content: frame)     // 0.05 · 240 = 12 px
        let outer = rim + featherPx

        // The box must contain the whole falloff: the rim plus the feather radius, on both axes.
        let cx = Double(image.width) / 2, cy = Double(image.height) / 2
        XCTAssertGreaterThanOrEqual(Double(cx - Double(softBox.x0)), outer - 1.5)
        XCTAssertGreaterThanOrEqual(Double(Double(softBox.x1) - cx), outer - 1.5)
        XCTAssertGreaterThanOrEqual(Double(cy - Double(softBox.y0)), outer - 1.5)
        XCTAssertGreaterThanOrEqual(Double(Double(softBox.y1) - cy), outer - 1.5)
        // … and it must be *tight*, i.e. grown by that radius and not by the canvas.
        XCTAssertEqual(Double(softBox.width - hardBox.width), 2 * featherPx, accuracy: 4,
                       "feather 0.5 must widen the box by 2 × its radius (\(featherPx) px)")
        XCTAssertEqual(Double(Double(hardBox.x0) - Double(softBox.x0)), featherPx, accuracy: 2,
                       "the box must grow outwards by the feather radius on the left")

        // The receipt, measured: the atlas the kernel wrote reaches the outer rim, so nothing was cut.
        let dump = try atlas(soft, image)
        var reach = 0.0
        for x in 0..<image.width {
            if sample(dump, x, Int(cy)) > 0 { reach = max(reach, Double(x) + 0.5 - cx) }
        }
        XCTAssertEqual(reach, outer, accuracy: 1.5,
                       "the written coverage must reach r_out (\(outer) px), not the rim (\(rim) px)")

        // Every edge texel of the box holds the analytic value (≤ 1 code apart) …
        for x in softBox.x0..<softBox.x1 {
            let expected = radialAlpha(x: Double(x) + 0.5, y: Double(softBox.y0) + 0.5, shape,
                                       feather: 0.5, size: (image.width, image.height))
            XCTAssertEqual(sample(dump, x, softBox.y0), expected, accuracy: 1.0 / 255.0,
                           "top edge texel x = \(x) was cut by the box")
        }
        // … and the texels just outside it are in the tail: the bound itself is not the limit.
        for (x, y) in [(softBox.x0 - 1, Int(cy)), (softBox.x1, Int(cy)),
                       (Int(cx), softBox.y0 - 1), (Int(cx), softBox.y1)] {
            let expected = radialAlpha(x: Double(x) + 0.5, y: Double(y) + 0.5, shape,
                                       feather: 0.5, size: (image.width, image.height))
            XCTAssertLessThanOrEqual(expected, 1.0 / 255.0,
                                     "texel (\(x), \(y)) outside the box still had coverage "
                                     + "\(expected): the bound is too small")
            XCTAssertEqual(sample(dump, x, y), 0, "the kernel must not evaluate outside the box")
        }
    }

    // MARK: - 6. the S1.5 frame budget

    /// 4.10 Mpx, one full-frame radial mask, `PHOTONS_BENCH=1`: the frame A/B and the atlas's own
    /// **rasterisation** delta, so a regression in either would show.
    ///
    /// · `frame` — one cold S0→S4 frame with the mask (cache off, no readback): the number the
    ///   milestone note quotes. The graph times **whole frames** (`MTLCommandBuffer.gpuEndTime −
    ///   gpuStartTime`), and no per-stage timer exists, so S1.5's share cannot be read off directly;
    ///   what is measurable is that the frame does not move, and by how much it moves.
    /// · `raster` — the paired difference between a disc (box = the frame) and a speck (box = 1 px) of
    ///   the same document: everything else in the frame is identical work, so this isolates the
    ///   per-pixel shape evaluation S1.5 spends on the mask.
    ///
    /// Run it on `main c9aa22e` and here, and the two sets of numbers are the A4 performance claim.
    func testS15FeatherCostAtFourMegapixels() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" else {
            throw XCTSkip("set PHOTONS_BENCH=1 to measure S1.5 at 4.10 Mpx")
        }
        let image = rampImage(width: 2731, height: 1500)
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }

        func document(radius: Double, feather: Double, shift: Double = 0) -> EditModel {
            var edit = EditModel.neutral
            edit.masks = [Mask(id: "m-bench", feather: 0, refine: 0,
                               components: [MaskComponent(id: "c", feather: feather,
                                                          shape: .radialGradient(
                                                            RadialGradientShape(
                                                                center: NormalizedPoint(0.5 + shift, 0.5),
                                                                radius: NormalizedPoint(radius, radius))))],
                               adjustments: LocalAdjustments(exposure: 0.7))]
            return edit
        }

        let graph = try RenderGraph(input: RenderInput(image: image, identity: "bench-a4"))
        var options = RenderOptions(scale: 1, useCache: false, wantsPixels: false)
        options.maskTiling = .off

        func frame(_ doc: EditModel) throws -> Double {
            let r = try graph.render(doc, options: options)
            if let t = r.output { graph.recycle(output: t) }
            return r.trace.gpuMilliseconds
        }

        for _ in 0..<3 { _ = try frame(document(radius: 1.0, feather: 0)) }    // warm-up

        for feather in [0.0, 0.5] {
            var frames: [Double] = []
            var raster: [Double] = []
            for i in 0..<31 {
                let shift = Double(i) * 0.001
                frames.append(try frame(document(radius: 1.0, feather: feather, shift: shift)))
                let disc = frames.last!
                let speck = try frame(document(radius: 0.0001, feather: feather, shift: shift))
                raster.append(disc - speck)
            }
            frames.sort()
            raster.sort()
            print(String(format: "BENCH S1.5 f=%.1f: frame p50 %.2f ms (p10 %.2f p90 %.2f), "
                         + "raster disc−speck p50 %+.3f ms (p10 %+.3f p90 %+.3f), 4.10 Mpx",
                         feather, frames[frames.count / 2], frames[frames.count / 10],
                         frames[9 * frames.count / 10], raster[raster.count / 2],
                         raster[raster.count / 10], raster[9 * raster.count / 10]))
            XCTAssertLessThan(frames[frames.count / 2], 100, "a structural regression, not jitter")
        }
    }
}
