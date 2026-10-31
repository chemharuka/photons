import XCTest
import Metal
import PhotonsCore

/// 192 — **the σ floor is gone**: S3.10's radius means `radius_img · S` canvas pixels at *every* zoom,
/// and a σ below the base plane's own texel is carried by a moment-matched (energy- and
/// variance-normalised) kernel instead of being clamped up to a fixed half canvas pixel.
///
/// What the floor did, measured on `main` (`local/out/probe-base.log`), radius 1.0, `amount = 150`, an
/// 8 px soft edge:
///
/// | S | 0.198 (fit) | 0.5 | 1:1 | 2× |
/// |---|---|---|---|---|
/// | before | 2.86 | 2.12 | 3.11 | 2.86 |
/// | after | 0.00 | 2.12 | 3.11 | 2.74 |
///
/// …and the radius slider at `S = 0.198` read **2.86 / 2.86 / 2.86 / 2.99** for
/// `r = 0.5 / 1 / 2 / 3` — three identical values, because `max(radius·S, 0.5)` maps every
/// `radius ≤ 0.5/S = 2.5` image pixels onto the same 0.5-canvas-pixel kernel. After: **0.00 / 0.00 /
/// 1.74 / 7.60**.
///
/// The residual, measured and written down rather than tuned away: at a 0.2 fit **radius ≤ 1.6 image
/// pixels is narrower than one canvas pixel**, so the two smallest radii still round to nothing
/// (`0.00 / 0.00`) — a halo of 0.2 canvas px cannot be drawn, and inflating σ until it can is exactly
/// the bug this fixes. Likewise the three framings cannot agree within 10 %: the base plane's own box
/// is a σ of ≈ 1 image pixel, so the response goes as `sqrt(radius² + 1)` — scale-free for
/// `radius ≫ 1`, and *inherently* 1.5× apart at `radius = 1` (`local/out/probe-v1.log` has the table
/// for 8 px, 16 px and a 4 px checkerboard).
final class SharpenRadiusFloorTests: XCTestCase {

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func image(_ w: Int, _ h: Int, _ f: (Int, Int) -> Double) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = Float16(f(x, y))
                let i = (y * w + x) * 4
                rgba[i] = v; rgba[i + 1] = v; rgba[i + 2] = v; rgba[i + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// A step edge with a linear transition of `t` **image** pixels at `x = 300`: 0.06 → 0.50.
    private func step(transition t: Int, width: Int = 600, height: Int = 400) -> LinearImage {
        image(width, height) { x, _ in
            if x < 300 { return 0.06 }
            if x >= 300 + t { return 0.50 }
            return 0.06 + 0.44 * Double(x - 300) / Double(t)
        }
    }

    /// A linear ramp: every normalised kernel — of any width, at any stride — must leave it alone.
    private func ramp(width: Int = 600, height: Int = 400) -> LinearImage {
        image(width, height) { x, _ in 0.05 + 0.0005 * Double(x) }
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel, scale: Double) throws -> DisplayImage {
        let options = RenderOptions(scale: scale, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    private func codes(_ image: DisplayImage) -> [Double] {
        var out = [Double](repeating: 0, count: image.width * image.height)
        for i in 0..<(image.width * image.height) {
            out[i] = 255 * (0.2126 * Double(image.rgba[i * 4])
                            + 0.7152 * Double(image.rgba[i * 4 + 1])
                            + 0.0722 * Double(image.rgba[i * 4 + 2]))
        }
        return out
    }

    private func sharpen(_ amount: Double, radius: Double, detail: Double = 25,
                         masking: Double = 0) -> EditModel {
        var e = EditModel.neutral
        e.sharpen = SharpenGroup(amount: amount, radius: radius, detail: detail, masking: masking)
        return e
    }

    private func overshoot(_ out: [Double], width: Int, height: Int,
                           transition t: Int, scale S: Double) -> Double {
        let y = height / 2
        var tail = [Double]()
        for x in (width - 12)..<(width - 2) { tail.append(out[y * width + x]) }
        let plateau = tail.sorted()[tail.count / 2]
        let start = Int((Double(300 + t) * S).rounded())
        let end = min(width - 2, start + Int((40 * S).rounded()))
        var worst = 0.0
        for x in start..<max(start + 1, end) { worst = max(worst, out[y * width + x] - plateau) }
        return worst
    }

    /// The render scale of a fit preview on a 4 MP portrait — the rung the user complained about.
    private let fitScale = 0.198

    // MARK: - 1. σ is linear in the render scale — no floor, at any rung

    func testTheSigmaIsLinearInTheRenderScaleWithNoFloor() throws {
        for radius in [0.5, 0.6, 1.0, 1.75, 3.0] {
            for S in [0.01, 0.1, fitScale, 0.293, 0.5, 1.0, 2.0] {
                let c = RenderGraph.sharpenScale(radius: radius, imageScale: S)
                XCTAssertEqual(c.radius, radius * S, accuracy: 1e-12,
                               "S=\(S)、radius=\(radius)：σ 必须逐值等于 radius·S")
                // …and the value the floor used to force is nowhere on the curve.
                if radius * S < 0.5 {
                    XCTAssertLessThan(c.radius, 0.5,
                                      "S=\(S)、radius=\(radius)：σ 仍被抬到了半画布像素")
                }
            }
        }
    }

    /// The base plane's own box is one texel per **two image pixels**, so the layer the halo is
    /// measured against is the same picture width at 1:1 and at 2× — and as fine as a fit preview can
    /// hold (stride 1, the canvas itself) below `S = 0.75`.
    func testTheBasePlaneStrideFollowsTheRenderScale() throws {
        XCTAssertEqual(RenderGraph.sharpenPlaneStride(imageScale: 1.0), 2)
        XCTAssertEqual(RenderGraph.sharpenPlaneStride(imageScale: 2.0), 4)
        XCTAssertEqual(RenderGraph.sharpenPlaneStride(imageScale: 1.5), 3)
        XCTAssertEqual(RenderGraph.sharpenPlaneStride(imageScale: 0.75), 2)
        XCTAssertEqual(RenderGraph.sharpenPlaneStride(imageScale: fitScale), 1)
        XCTAssertEqual(RenderGraph.sharpenPlaneStride(imageScale: 0.5), 1)
    }

    // MARK: - 2. the complaint: fit must not be sharper than 1:1

    /// The user's report, as a gate: at **every** radius, the same document at a fit scale must not
    /// overshoot more than it does at 1:1. On `main` the smallest radius broke this by 2.3×
    /// (2.86 codes at fit against 1.25 at 1:1), because the floor gave fit a σ of 2.5 *image* pixels.
    func testAFitPreviewIsNotSharperThanOneToOne() throws {
        let graph = try makeGraph(step(transition: 8), identity: "floor-not-sharper")
        var fit: [Double] = [], one: [Double] = []
        for radius in [0.5, 1.0, 2.0, 3.0] {
            for S in [fitScale, 1.0] {
                let out = try render(graph, sharpen(150, radius: radius), scale: S)
                let o = overshoot(codes(out), width: out.width, height: out.height,
                                  transition: 8, scale: S)
                if S == fitScale { fit.append(o) } else { one.append(o) }
            }
        }
        print(String(format: "192 · 8 px 软边 · 过冲 fit %.2f/%.2f/%.2f/%.2f · 1:1 %.2f/%.2f/%.2f/%.2f",
                     fit[0], fit[1], fit[2], fit[3], one[0], one[1], one[2], one[3]))
        for i in 0..<4 {
            XCTAssertLessThanOrEqual(fit[i], one[i] + 0.05,
                                     "r=\(( [0.5, 1.0, 2.0, 3.0][i] )) 在 fit 上比 1:1 更锐（\(fit[i]) > \(one[i])）")
        }
        // Not vacuous: 1:1 still has a halo to compare against.
        XCTAssertGreaterThan(one[1], 2.0, "1:1 的 8 px 边锐化不见了，这条测试会空转")
    }

    // MARK: - 3. the slider moves at a fit scale

    /// `r = 0.5 / 1 / 2 / 3` at a 0.2 fit used to read 2.86 / 2.86 / 2.86 / 2.99 — three identical
    /// values, i.e. a slider whose bottom two thirds did nothing. It must be monotone now, and the top
    /// of the range must be materially stronger than the bottom.
    func testTheRadiusSliderMovesAtAFitScale() throws {
        let graph = try makeGraph(step(transition: 8), identity: "floor-slider-fit")
        var values: [Double] = []
        for radius in [0.5, 1.0, 2.0, 3.0] {
            let out = try render(graph, sharpen(150, radius: radius), scale: fitScale)
            values.append(overshoot(codes(out), width: out.width, height: out.height,
                                    transition: 8, scale: fitScale))
        }
        print(String(format: "192 · S=%.3f · r=0.5/1/2/3 过冲 %.2f / %.2f / %.2f / %.2f",
                     fitScale, values[0], values[1], values[2], values[3]))
        for i in 1..<values.count {
            XCTAssertGreaterThanOrEqual(values[i], values[i - 1] - 0.01,
                                        "半径在 fit 上不再单调（\(values)）")
        }
        // The two smallest radii are narrower than one canvas pixel at this zoom and round to
        // nothing — the residual this class's header writes down. What must hold is that the top of
        // the range is a real response and it is far above the bottom.
        XCTAssertGreaterThan(values[3], 4.0, "r=3 在 fit 上几乎不动（\(values[3]) 码）")
        XCTAssertGreaterThan(values[3], 2.0 * max(values[0], 0.05), "半径范围在 fit 上被压平了（\(values)）")
        XCTAssertGreaterThan(values[2], 0.5, "r=2 在 fit 上仍然被地板压成 0（\(values[2]) 码）")
    }

    // MARK: - 4. the sub-texel kernel keeps the energy

    /// The whole point of replacing the clamp with a moment-matched kernel is that it stays
    /// **normalised**: a σ far below one texel narrows the kernel, it does not scale the picture. A
    /// linear ramp is the fixture that says so — any kernel whose weights sum to 1 (and whose taps are
    /// symmetric) leaves a ramp exactly where it was, and a kernel with a gain error moves it by
    /// `(1 − Σw)·I`, which on this fixture is several codes.
    func testTheSubTexelKernelPreservesALinearRamp() throws {
        let graph = try makeGraph(ramp(), identity: "floor-ramp")
        for radius in [0.5, 1.0, 3.0] {
            let base = try render(graph, .neutral, scale: fitScale)
            let w = base.width, y = base.height / 2
            let neutral = codes(base)
            let out = codes(try render(graph, sharpen(150, radius: radius), scale: fitScale))
            var worst = 0.0
            for x in (w / 4)..<(w * 3 / 4) { worst = max(worst, abs(out[(y * w) + x] - neutral[(y * w) + x])) }
            print(String(format: "192 · 线性斜坡 · r=%.1f · 中心行最大偏移 %.3f 码", radius, worst))
            XCTAssertLessThanOrEqual(worst, 0.5,
                                     "r=\(radius) 的子像素核不是能量归一的（偏移 \(worst) 码）")
        }
    }

    // MARK: - 5. cost

    /// No new pass: the stage is still five dispatches, and at 1:1 the plane's stride is unchanged
    /// (2), so the work is identical. A fit preview builds the plane at stride 1 — four times the
    /// texels of a canvas that is itself 25× smaller than 1:1 — which is printed here rather than
    /// asserted, for the reason `SharpenScaleTests.testTheCostIsOneStageThatEntersOnlyWhenNonZero`
    /// spells out (a marginal on this box can even come out negative under load).
    func testTheCostShapeIsUnchanged() throws {
        let graph = try makeGraph(image(1500, 2731) { _, _ in 0.18 }, identity: "floor-cost")
        func traced(_ edit: EditModel, _ S: Double) throws -> RenderTrace {
            let options = RenderOptions(scale: S, display: DisplayOptions(headroom: 1),
                                        useCache: false, wantsPixels: false)
            let result = try graph.render(edit, options: options)
            if let t = result.output { graph.recycle(output: t) }
            return result.trace
        }
        let off = EditModel.neutral, on = sharpen(150, radius: 1.0)
        _ = try traced(off, 1); _ = try traced(on, 1)
        _ = try traced(off, 0.293); _ = try traced(on, 0.293)
        for S in [0.293, 1.0] {
            let a = try traced(off, S), b = try traced(on, S)
            XCTAssertFalse(a.executed.contains(.sharpen), "amount = 0 时 S3.10 不许进图（S=\(S)）")
            XCTAssertEqual(b.executed.filter { $0 == .sharpen }.count, 1,
                           "S3.10 每帧只进一次（S=\(S)）")
            XCTAssertEqual(b.executed.count, a.executed.count + 1,
                           "锐化只多这一段（S=\(S)）")
        }
        for S in [1.0, 0.293] {
            var marginal: [Double] = []
            for _ in 0..<3 {
                let a = try traced(off, S), b = try traced(on, S)
                marginal.append(b.gpuMilliseconds - a.gpuMilliseconds)
            }
            print(String(format: "192 · 开销 S=%.3f · 边际 %+.3f / %+.3f / %+.3f ms",
                         S, marginal[0], marginal[1], marginal[2]))
        }
    }
}
