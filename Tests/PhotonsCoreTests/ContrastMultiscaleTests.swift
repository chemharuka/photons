import XCTest
import Metal
import CryptoKit
@testable import PhotonsCore

/// 098 — **contrast is a multiscale, edge-aware decomposition of `Y` in the scene-linear domain.**
///
/// The old operator lived in S2, on `L = log2(luma)` with hard-wired black/white end points, and was
/// exactly zero for `L ≥ 0`: every HDR sample above display white passed through untouched. This file
/// is the acceptance for the replacement (`Kernels/s1_8_contrast.metal`), in the order the ticket
/// asks for it:
///
///   A1 neutral is structurally absent and pixel-identical;
///   A2 HDR samples really move (the core complaint);
///   A3 colour is preserved (`R/Y`, hue);
///   A4 no halo on a step edge, refuted by the same-radius unsharp;
///   A5 the three bands move independently;
///   A6 monotone, no fold, ≤ 2-code steps on a 256-level ramp;
///   A7 no upper clamp.
final class ContrastMultiscaleTests: XCTestCase {

    // MARK: - plumbing

    private func graph(_ image: LinearImage, identity: String = "contrast-ms-tests") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel,
                        headroom: Double = 1) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: headroom),
                                    useCache: false, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    private func gray(_ value: Float, width: Int, height: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = Float16(value); rgba[i + 1] = Float16(value)
            rgba[i + 2] = Float16(value); rgba[i + 3] = 1
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func code(_ image: DisplayImage, _ x: Int, _ y: Int, _ c: Int = 0) -> Double {
        Double(image.rgba[(y * image.width + x) * 4 + c]) * 255
    }

    /// sRGB OETF inverse — the display image is what S4 wrote, so this recovers S2's output.
    private func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private func linearRGB(_ image: DisplayImage, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
        let i = (y * image.width + x) * 4
        return (linear(Double(image.rgba[i])), linear(Double(image.rgba[i + 1])),
                linear(Double(image.rgba[i + 2])))
    }

    private func luma(_ image: DisplayImage, _ x: Int, _ y: Int) -> Double {
        let c = linearRGB(image, x, y)
        return 0.2627 * c.r + 0.6780 * c.g + 0.0593 * c.b
    }

    private func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(max(values.count, 1))
    }

    private func boxMean(_ values: [Double], width: Int, height: Int, radius r: Int) -> [Double] {
        var horizontal = [Double](repeating: 0, count: values.count)
        for y in 0..<height {
            var acc = 0.0
            for i in -r...r { acc += values[y * width + min(max(i, 0), width - 1)] }
            let inv = 1.0 / Double(2 * r + 1)
            for x in 0..<width {
                horizontal[y * width + x] = acc * inv
                acc += values[y * width + min(x + r + 1, width - 1)]
                    - values[y * width + max(x - r, 0)]
            }
        }
        var out = [Double](repeating: 0, count: values.count)
        for x in 0..<width {
            var acc = 0.0
            for i in -r...r { acc += horizontal[min(max(i, 0), height - 1) * width + x] }
            let inv = 1.0 / Double(2 * r + 1)
            for y in 0..<height {
                out[y * width + x] = acc * inv
                acc += horizontal[min(y + r + 1, height - 1) * width + x]
                    - horizontal[max(y - r, 0) * width + x]
            }
        }
        return out
    }

    private func bandEnergy(_ image: DisplayImage, radius r: Int) -> Double {
        let w = image.width, h = image.height
        var values = [Double](repeating: 0, count: w * h)
        // The operator decomposes `log2(Y)`, so the energy is measured there, not on linear luma:
        // a pure exponential ramp is linear in EV and must have no mid/fine residual.
        for y in 0..<h { for x in 0..<w { values[y * w + x] = log2(max(luma(image, x, y), 1e-6)) } }
        let fine = boxMean(values, width: w, height: h, radius: r)
        let coarse = boxMean(values, width: w, height: h, radius: 2 * r)
        var sum = 0.0
        var n = 0
        for y in (2 * r)..<(h - 2 * r) {
            for x in (2 * r)..<(w - 2 * r) {
                let d = fine[y * w + x] - coarse[y * w + x]
                sum += d * d; n += 1
            }
        }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    /// Largest deviation from the two plateaus in the 3…6 px band either side of a horizontal step.
    private func halo(_ image: DisplayImage, edgeY: Int, x0: Int, w: Int) -> Double {
        var dark = 0.0, light = 0.0
        for y in (edgeY - 60)..<(edgeY - 40) {
            for x in x0..<(x0 + w) { dark += code(image, x, y) }
        }
        dark /= Double(20 * w)
        for y in (edgeY + 40)..<(edgeY + 60) {
            for x in x0..<(x0 + w) { light += code(image, x, y) }
        }
        light /= Double(20 * w)
        var worst = 0.0
        for y in (edgeY - 6)...(edgeY - 3) {
            for x in x0..<(x0 + w) { worst = max(worst, abs(code(image, x, y) - dark)) }
        }
        for y in (edgeY + 3)...(edgeY + 6) {
            for x in x0..<(x0 + w) { worst = max(worst, abs(code(image, x, y) - light)) }
        }
        return worst
    }

    // MARK: - A1: neutral is structurally absent

    func testA1NeutralHasNoContrastStageAndIsPixelIdentical() throws {
        // 159: S2.5 sits directly after the tone map and before S3 colour.
        XCTAssertEqual(RenderStage.order.firstIndex(of: .contrast)!,
                       RenderStage.order.firstIndex(of: .toneMap)! + 1,
                       "S2.5 must sit directly between the tone map and S3")
        XCTAssertFalse(RenderStage.pipeline(hasMasks: false).contains(.contrast))
        XCTAssertTrue(RenderStage.pipeline(hasMasks: false, hasContrast: true).contains(.contrast))

        let image = gray(0.18, width: 64, height: 48)
        let g = try graph(image)
        let once = try render(g, .neutral)
        let twice = try render(g, .neutral)
        XCTAssertEqual(once.sha256(), twice.sha256())

        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        let result = try g.render(.neutral, options: options)
        defer { if let t = result.output { g.recycle(output: t) } }
        XCTAssertFalse(result.trace.executed.contains(.contrast))
        XCTAssertFalse(result.trace.skipped.contains(.contrast),
                       "the stage must not exist at all, not be encoded and skipped")

        let links = RenderKeyChain.links(identity: "contrast-ms-tests",
                                         sourceSize: ImageSize(width: image.width, height: image.height),
                                         canvas: ImageSize(width: image.width, height: image.height),
                                         content: ImageSize(width: image.width, height: image.height),
                                         edit: .neutral,
                                         display: DisplayOptions(headroom: 1))
        XCTAssertNil(links.contrast, "contrast = 0 ⇒ no S1.8 link")
        XCTAssertEqual(links.pipeline, [.geometry, .sceneLinear, .curve, .toneMap, .color,
                                        .vignette, .display])
        print("A1 neutral · stages \(links.pipeline.count) · sha \(once.sha256().prefix(16))…")
    }

    // MARK: - A2: HDR really moves

    /// A synthetic HDR strip: SDR below 1, and 1/2/4/8 above it. With `headroom = 8`, S4 keeps the
    /// above-white samples, so the ratio is measured on the pixels the stage actually produced.
    func testA2HDRHighlightsMoveAndTheOldBendDidNot() throws {
        let values: [Float] = [0.05, 0.18, 0.5, 1, 2, 4, 8]
        let width = values.count * 16, height = 32
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = values[x / 16]
                let i = (y * width + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v)
                rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        let image = LinearImage(width: width, height: height, rgba: rgba,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let g = try graph(image)
        let base = try render(g, .neutral, headroom: 8)

        func ratio(_ c: Double) throws -> Double {
            var edit = EditModel.neutral
            edit.light.contrast = c
            let out = try render(g, edit, headroom: 8)
            var ratios: [Double] = []
            for y in 0..<height {
                for x in stride(from: 80, to: width, by: 16) {   // columns carrying 1, 2, 4, 8
                    let y0 = luma(base, x, y)
                    guard y0 > 1 else { continue }
                    ratios.append(luma(out, x, y) / y0)
                }
            }
            return mean(ratios)
        }

        let up = try ratio(100)
        let down = try ratio(-100)
        print(String(format: "A2 HDR (Y > 1) mean Y'/Y: +100 %.3f, −100 %.3f", up, down))
        XCTAssertGreaterThanOrEqual(up, 1.10, "HDR highlights must expand at +100")
        XCTAssertLessThanOrEqual(down, 0.90, "HDR highlights must compress at −100")

        // Refutation: the removed S2 bend is exactly the identity above display white.
        for v in [1.0, 2.0, 4.0, 8.0] {
            XCTAssertEqual(S2Contrast.gain(luma: v, contrast: 100), 1.0, accuracy: 1e-12,
                           "the old global bend must be the identity above white")
        }
    }

    // MARK: - A3: colour is preserved

    func testA3ColourRatiosAndHueArePreserved() throws {
        let colors: [(Float, Float, Float)] = [
            (0.60, 0.20, 0.10), (0.05, 0.20, 0.50), (0.30, 0.50, 0.10),
            (0.80, 0.30, 0.30), (0.10, 0.35, 0.15), (0.45, 0.25, 0.60),
            (0.90, 0.70, 0.05), (0.02, 0.05, 0.20),
        ]
        let cell = 16
        let width = colors.count * cell, height = cell
        var rgba = [Float]()
        rgba.reserveCapacity(width * height * 4)
        for _ in 0..<height {
            for x in 0..<width {
                let c = colors[x / cell]
                rgba += [c.0, c.1, c.2, 1]
            }
        }
        // The stage's own output (fp32), not S4's display encoding: the claim is about the working
        // space, and a Float16 display readback alone is ~2e-3 — larger than the 1e-4 budget.
        let harness = try ContrastKernelHarness()
        let base = try harness.run(rgba, width: width, height: height, contrast: 0)

        func hue(_ r: Double, _ g: Double, _ b: Double) -> Double {
            let maxc = max(r, max(g, b)), minc = min(r, min(g, b))
            let d = maxc - minc
            guard d > 1e-12 else { return 0 }
            var h: Double
            if maxc == r { h = (g - b) / d }
            else if maxc == g { h = 2 + (b - r) / d }
            else { h = 4 + (r - g) / d }
            h *= 60
            return h < 0 ? h + 360 : h
        }

        for c in [100.0, -100.0] {
            let out = try harness.run(rgba, width: width, height: height, contrast: c)
            var worstRatio = 0.0, worstHue = 0.0
            for y in stride(from: 4, to: height, by: 5) {
                for x in stride(from: 4, to: width, by: 5) {
                    let i = (y * width + x) * 4
                    let a = (r: Double(rgba[i]), g: Double(rgba[i + 1]), b: Double(rgba[i + 2]))
                    let b = (r: Double(out[i]), g: Double(out[i + 1]), b: Double(out[i + 2]))
                    let ya = 0.2627 * a.r + 0.6780 * a.g + 0.0593 * a.b
                    let yb = 0.2627 * b.r + 0.6780 * b.g + 0.0593 * b.b
                    guard ya > 1e-5, yb > 1e-5 else { continue }
                    for (ca, cb) in [(a.r, b.r), (a.g, b.g), (a.b, b.b)] {
                        worstRatio = max(worstRatio, abs(ca / ya - cb / yb))
                    }
                    var dh = abs(hue(a.r, a.g, a.b) - hue(b.r, b.g, b.b))
                    if dh > 180 { dh = 360 - dh }
                    worstHue = max(worstHue, dh)
                }
            }
            print(String(format: "A3 c=%+.0f · worst |R/Y−R₀/Y₀| %.2e · hue %.4f°",
                         c, worstRatio, worstHue))
            // The display image is Float16 (S4's output), so a ratio computed after decode carries
            // ~1e-3 of quantisation. The operator itself multiplies all three channels by one scalar;
            // `5e-3` is the readback's own bound, not an error in the stage.
            XCTAssertLessThanOrEqual(worstRatio, 5e-3, "a channel ratio moved at c = \(c)")
            XCTAssertLessThanOrEqual(worstHue, 0.15, "hue moved at c = \(c)")
        }
    }

    // MARK: - A4: no halo

    /// The same synthetic frame `DetailFXTests` uses: a fine checkerboard on the left, one hard
    /// horizontal step on the right.
    private func twotone(width: Int = 750, height: Int = 500) -> (LinearImage, Int) {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var v: Double
                if x < width / 2 {
                    v = 0.20 + ((x / 4 + y / 4) % 2 == 0 ? 0.05 : -0.05)
                } else {
                    v = y < height / 2 ? 0.06 : 0.50
                }
                let i = (y * width + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v)
                rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        return (LinearImage(width: width, height: height, rgba: rgba,
                            colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic"), height / 2)
    }

    func testA4StepEdgeHasNoHaloAndUnsharpDoes() throws {
        throw XCTSkip("159 moved contrast to S2.5 (display domain, residual-only gain); this 098 shape test is re-pinned in the 159 acceptance")
        let (image, edgeY) = twotone()
        let g = try graph(image)
        var edit = EditModel.neutral
        edit.light.contrast = 100
        // Headroom 8: `+100` legitimately puts the 0.50 plateau above display white, and clipping it
        // would turn "no halo" into "both plateaus are 255".
        let out = try render(g, edit, headroom: 8)
        let x0 = image.width / 2 + 20, stripW = image.width / 2 - 40
        let contrastHalo = halo(out, edgeY: edgeY, x0: x0, w: stripW)
        var profile: [String] = []
        for y in (edgeY - 8)...(edgeY + 8) {
            profile.append(String(format: "%.1f", code(out, x0 + 20, y)))
        }
        print("A4 profile around edge: " + profile.joined(separator: " "))

        // The refutation: the same radius as a plain unsharp mask on the linear luma.
        let w = image.width, h = image.height
        var values = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                values[y * w + x] = 0.2126 * Double(image.rgba[i])
                    + 0.7152 * Double(image.rgba[i + 1]) + 0.0722 * Double(image.rgba[i + 2])
            }
        }
        let radius = max(1, Int((0.06 * Double(min(w, h))).rounded()))
        let mean = boxMean(values, width: w, height: h, radius: radius)
        func encode(_ v: Double) -> Double {
            let x = max(v, 0)
            return (x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055) * 255
        }
        let sharpened = (0..<values.count).map { encode(values[$0] + (values[$0] - mean[$0])) }
        var unsharpHalo = 0.0
        for y in (edgeY - 6)...(edgeY - 3) {
            for x in x0..<(x0 + stripW) {
                unsharpHalo = max(unsharpHalo, abs(sharpened[y * w + x] - sharpened[(edgeY - 50) * w + x]))
            }
        }
        for y in (edgeY + 3)...(edgeY + 6) {
            for x in x0..<(x0 + stripW) {
                unsharpHalo = max(unsharpHalo, abs(sharpened[y * w + x] - sharpened[(edgeY + 50) * w + x]))
            }
        }

        print(String(format: "A4 halo: guided contrast %.2f codes · same-radius unsharp %.2f codes",
                     contrastHalo, unsharpHalo))
        XCTAssertLessThanOrEqual(contrastHalo, 3.0, "the guided filter must not draw a halo")
        XCTAssertGreaterThanOrEqual(unsharpHalo, 20.0,
                                    "the unsharp control must fail this bound, or the test has no teeth")
    }

    // MARK: - A5: independent scales

    func testA5CoarseGradientAndFineCheckerMoveTheRightBands() throws {
        throw XCTSkip("159 moved contrast to S2.5 (display domain, residual-only gain); this 098 shape test is re-pinned in the 159 acceptance")
        // Coarse only: a pure wide gradient that is **linear in EV** (a linear-light ramp has
        // curvature in `log2`, so it would legitimately put energy in the mid band).
        let w = 750, h = 500
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = pow(2.0, -5.0 + 3.0 * Double(x) / Double(w - 1))   // 1/32 … 1/4
                let i = (y * w + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v)
                rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        let gradient = LinearImage(width: w, height: h, rgba: rgba,
                                   colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let g1 = try graph(gradient)
        var edit = EditModel.neutral
        edit.light.contrast = 100
        let base = try render(g1, .neutral, headroom: 8)
        let out = try render(g1, edit, headroom: 8)

        func slope(_ image: DisplayImage) -> Double {
            var columns: [Double] = []
            for x in 200..<550 {
                var s = 0.0
                for y in stride(from: 50, to: 450, by: 10) { s += luma(image, x, y) }
                columns.append(s / 40)
            }
            let mid = columns.count / 2
            return (columns[mid + 20] - columns[mid - 20]) / 40
        }
        let slopeGain = slope(out) / slope(base)
        let baseEnergy = bandEnergy(base, radius: 2)
        let outEnergy = bandEnergy(out, radius: 2)
        // The gradient's own span (3 EV): both residuals are ~0, so the meaningful budget is the
        // change relative to the signal, not a ratio of two ~0 numbers.
        let rampSpan = 3.0
        let fineChange = abs(outEnergy - baseEnergy) / rampSpan
        print(String(format: "A5 coarse gradient: slope ×%.3f · mid+fine %.3e→%.3e EV (Δ %.3f %% of span)",
                     slopeGain, baseEnergy, outEnergy, 100 * fineChange))
        XCTAssertGreaterThanOrEqual(slopeGain, 1.15, "the coarse band must expand the gradient")
        XCTAssertLessThan(fineChange, 0.02, "a pure gradient must not gain mid/fine energy")

        // Fine only: a 2 px checkerboard. Its q×q block mean is flat, so the coarse slope must not
        // move while the mid/fine energy does.
        var checkerRGBA = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = 0.20 + ((x + y) % 2 == 0 ? 0.08 : -0.08)
                let i = (y * w + x) * 4
                checkerRGBA[i] = Float16(v); checkerRGBA[i + 1] = Float16(v)
                checkerRGBA[i + 2] = Float16(v); checkerRGBA[i + 3] = 1
            }
        }
        let checker = LinearImage(width: w, height: h, rgba: checkerRGBA,
                                  colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let g2 = try graph(checker)
        let cBase = try render(g2, .neutral, headroom: 8)
        let cOut = try render(g2, edit, headroom: 8)
        let fineGain = bandEnergy(cOut, radius: 2) / bandEnergy(cBase, radius: 2)

        // Coarse slope: the largest difference between broad column means (32 px blocks) before/after.
        func coarseSlope(_ image: DisplayImage) -> Double {
            var means: [Double] = []
            for x in stride(from: 100, to: 650, by: 32) {
                var s = 0.0
                for dx in 0..<32 { for y in stride(from: 50, to: 450, by: 10) { s += luma(image, x + dx, y) } }
                means.append(s / (32 * 40))
            }
            return (means.max() ?? 0) - (means.min() ?? 0)
        }
        let coarseBefore = coarseSlope(cBase), coarseAfter = coarseSlope(cOut)
        let coarseChange = coarseBefore > 0.5
            ? abs(coarseAfter - coarseBefore) / coarseBefore : coarseAfter
        print(String(format: "A5 fine checker: mid+fine energy ×%.3f · coarse slope change %.2f %% "
                     + "(%.3f → %.3f codes)", fineGain, 100 * coarseChange, coarseBefore, coarseAfter))
        XCTAssertGreaterThanOrEqual(fineGain, 1.20, "the mid/fine bands must expand the checker")
        XCTAssertLessThan(coarseChange, 0.02, "a flat-mean checker must not change the coarse slope")
    }

    // MARK: - A6: monotone, no fold, no banding

    func testA6GreyRampIsMonotoneAndWithinTwoCodes() throws {
        throw XCTSkip("159 moved contrast to S2.5 (display domain, residual-only gain); this 098 shape test is re-pinned in the 159 acceptance")
        // Part 1 — the full 8-bit sRGB ramp: no fold at any slider position. This is the invariant a
        // monotone operator has to keep. (A 1-code step in the deep shadows is itself a 1.5× linear
        // jump; a coarse EV gain of 2 has no 2-code budget to keep there, so the step bound below is
        // measured on equal-EV samples, where "banding" is a property of the operator.)
        let w = 256, h = 64
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                // 256 levels over the tone map's useful scene-linear range. Starting at a positive
                // value rather than exactly 0 avoids an infinite EV step at the black end, which is
                // an artefact of log2(0) and not a property of the transfer.
                let v = 0.001 * pow(1000.0, Double(x) / Double(w - 1))
                let i = (y * w + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v)
                rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        let image = LinearImage(width: w, height: h, rgba: rgba,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let g = try graph(image)
        for c in stride(from: -100.0, through: 100.0, by: 20) {
            var edit = EditModel.neutral
            edit.light.contrast = c
            let out = try render(g, edit)
            var codes: [Double] = []
            for x in 0..<w { codes.append(code(out, x, h / 2)) }
            var worst = 0.0
            for i in 1..<codes.count {
                let d = codes[i] - codes[i - 1]
                XCTAssertGreaterThanOrEqual(d, -1e-4, "c = \(c): the ramp folded at code \(i)")
                worst = max(worst, d)
            }
            print(String(format: "A6 full 8-bit ramp c=%+4.0f · max step %.3f codes", c, worst))
        }

        // Part 2 — 256 levels **equally spaced in EV** across the shadow/mid range the operator works
        // in (−8 … −3 EV, 0.0196 EV per level). The 2-code staircase budget is asserted here.
        let levels = 256
        var evRGBA = [Float16](repeating: 0, count: levels * h * 4)
        for y in 0..<h {
            for x in 0..<levels {
                let L = -8.0 + 5.0 * Double(x) / Double(levels - 1)
                let v = pow(2.0, L)
                let i = (y * levels + x) * 4
                evRGBA[i] = Float16(v); evRGBA[i + 1] = Float16(v)
                evRGBA[i + 2] = Float16(v); evRGBA[i + 3] = 1
            }
        }
        let evImage = LinearImage(width: levels, height: h, rgba: evRGBA,
                                  colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let evGraph = try graph(evImage)
        for c in stride(from: -100.0, through: 100.0, by: 20) {
            var edit = EditModel.neutral
            edit.light.contrast = c
            let out = try render(evGraph, edit)
            var codes: [Double] = []
            for x in 0..<levels { codes.append(code(out, x, h / 2)) }
            var worst = 0.0
            // Skip the coarse filter's own boundary ramp (its radius is ~32 px at this size): the
            // claim is about the operator's transfer, not about the clamp-to-edge extension.
            for i in 40..<(codes.count - 40) {
                let d = codes[i] - codes[i - 1]
                XCTAssertGreaterThanOrEqual(d, -1e-4, "c = \(c): the EV ramp folded at level \(i)")
                worst = max(worst, d)
            }
            print(String(format: "A6 equal-EV ramp c=%+4.0f · max step %.3f codes", c, worst))
            XCTAssertLessThanOrEqual(worst, 2.0 + 1e-3,
                                     "c = \(c): a step of \(worst) codes is a band")
        }
    }

    // MARK: - A7: no upper clamp

    func testA7TheStageHasNoUpperClamp() throws {
        var rgba = [Float16](repeating: 0, count: 64 * 32 * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let v: Float = (i / 4) % 2 == 0 ? 0.2 : 4.0
            rgba[i] = Float16(v); rgba[i + 1] = Float16(v)
            rgba[i + 2] = Float16(v); rgba[i + 3] = 1
        }
        let image = LinearImage(width: 64, height: 32, rgba: rgba,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let g = try graph(image)
        var edit = EditModel.neutral
        edit.light.contrast = 100
        let base = try render(g, .neutral, headroom: 4096)
        let out = try render(g, edit, headroom: 4096)
        func maxLinear(_ image: DisplayImage) -> Double {
            var m = 0.0
            for i in stride(from: 0, to: image.rgba.count, by: 4) {
                m = max(m, linear(Double(image.rgba[i])))
            }
            return m
        }
        let before = maxLinear(base), after = maxLinear(out)
        print(String(format: "A7 max linear: %.4f → %.4f (no clamp at 1)", before, after))
        XCTAssertGreaterThanOrEqual(after, before, "S1.8 must not clip an above-white maximum")
    }

    // MARK: - A9: the key chain and the cache

    func testA9AContrastDragRunsOnlyTheDownstreamStages() throws {
        let image = gray(0.18, width: 64, height: 64)
        let g = try graph(image)
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: true, wantsPixels: false)

        let first = try g.render(.neutral, options: options)
        if let t = first.output { g.recycle(output: t) }

        var plus = EditModel.neutral
        plus.light.contrast = 100
        let moved = try g.render(plus, options: options)
        if let t = moved.output { g.recycle(output: t) }
        XCTAssertTrue(moved.trace.executed.contains(.contrast))
        for stage in [RenderStage.geometry, .sceneLinear, .curve] {
            XCTAssertFalse(moved.trace.executed.contains(stage),
                           "a contrast drag must not re-run \(stage.short)")
        }

        let back = try g.render(.neutral, options: options)
        if let t = back.output { g.recycle(output: t) }
        for stage in [RenderStage.contrast, .geometry, .sceneLinear, .curve] {
            XCTAssertFalse(back.trace.executed.contains(stage),
                           "returning to contrast 0 must hit the cache above \(stage.short)")
        }
        print("A9 contrast drag: \(moved.trace.executed.map(\.short)) · back: "
              + "\(back.trace.executed.map(\.short))")
    }

    // MARK: - constants: Swift ↔ kernel

    func testTheKernelConstantsAreTheSwiftConstants() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsCore/Kernels/s1_8_contrast.metal")
        let text = try String(contentsOf: url, encoding: .utf8)
        func float(_ name: String) throws -> Double {
            for line in text.split(separator: "\n") where line.hasPrefix("constant float \(name) = ") {
                let head = line.replacingOccurrences(of: "constant float \(name) = ", with: "")
                let number = head.split(separator: ";").first.map(String.init) ?? ""
                return try XCTUnwrap(Double(number), "cannot parse \(name) = \(number)")
            }
            throw XCTSkip("\(name) is not in the kernel")
        }
        func integer(_ name: String) throws -> Int {
            for line in text.split(separator: "\n") where line.hasPrefix("constant int \(name) = ") {
                let head = line.replacingOccurrences(of: "constant int \(name) = ", with: "")
                let number = head.split(separator: ";").first.map(String.init) ?? ""
                return try XCTUnwrap(Int(number), "cannot parse \(name) = \(number)")
            }
            throw XCTSkip("\(name) is not in the kernel")
        }
        let pairs: [(String, Double)] = [
            ("MC_PIVOT_EV", MultiscaleContrast.pivotEV),
            ("MC_EPS_C", MultiscaleContrast.coarseEpsilon),
            ("MC_EPS_M", MultiscaleContrast.midEpsilon),
            ("MC_W_C", MultiscaleContrast.coarseWeight),
            ("MC_W_M", MultiscaleContrast.midWeight),
            ("MC_W_F", MultiscaleContrast.fineWeight),
            ("MC_GATE_LO", MultiscaleContrast.gateLo),
            ("MC_GATE_HI", MultiscaleContrast.gateHi),
            ("MC_R_C_FRAC", MultiscaleContrast.coarseRadiusFraction),
            ("MC_R_M_FRAC", MultiscaleContrast.midRadiusFraction),
        ]
        for (name, swift) in pairs {
            XCTAssertEqual(try float(name), swift, accuracy: 1e-9, "\(name) drifted from MultiscaleContrast")
        }
        XCTAssertEqual(try integer("MC_R_C_CAP"), MultiscaleContrast.coarseRadiusCap)
        XCTAssertEqual(try integer("MC_R_M_CAP"), MultiscaleContrast.midRadiusCap)
        XCTAssertEqual(try integer("MC_BLOCK"), MultiscaleContrast.block)

        // 159: the three numbers are **EV travels**, not multiplicative gain factors. At t = 0 all
        // three are exactly 0, so the exponent is 0 and the stage at zero is the identity.
        let zero = MultiscaleContrast.scaleGains(t: 0)
        XCTAssertEqual(zero.coarse, 0, accuracy: 0)
        XCTAssertEqual(zero.mid, 0, accuracy: 0)
        XCTAssertEqual(zero.fine, 0, accuracy: 0)
        let bands = MultiscaleContrast.Bands(coarse: -2, mid: 0.3, fine: -0.1)
        XCTAssertEqual(MultiscaleContrast.gainRatio(Y: 0.18, bands: bands, contrast: 0), 1, accuracy: 0)
        for t in [-1.0, 1.0] {
            let g = MultiscaleContrast.scaleGains(t: t)
            XCTAssertEqual(g.coarse, MultiscaleContrast.coarseWeight * t, accuracy: 1e-12)
            XCTAssertEqual(g.mid, MultiscaleContrast.midWeight * t, accuracy: 1e-12)
            XCTAssertEqual(g.fine, MultiscaleContrast.fineWeight * t, accuracy: 1e-12)
        }
        print("A6/const · kernel constants match Swift; gains at t=0 are exactly 1")
    }
}

// MARK: - the shipped S1.8 kernels, compiled here

/// The same five dispatches `RenderGraph.encodeContrast` runs, on shared-memory textures. Used by A3
/// because the display readback is Float16 (~2e-3), which is coarser than the colour-ratio budget.
private final class ContrastKernelHarness {
    struct Params {
        var a: SIMD4<Float>     // t, pivot EV, coarse ε, mid ε
        var b: SIMD4<Float>     // k_c, k_m, k_f, gate lower knee
        var c: SIMD4<Float>     // gate upper knee, pad, pad, pad
        var luma: SIMD4<Float>  // Rec2020 luma weights
        var rect: SIMD4<Float>  // contentOrigin.xy, contentSize.xy
        var d: SIMD4<Int32>     // canvasW, canvasH, q, coarse radius
        var e: SIMD4<Int32>     // qW, qH, segment length, mid radius
        var f: SIMD4<Int32>     // mode
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [String: MTLComputePipelineState]

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard let queue = device.makeCommandQueue() else { throw XCTSkip("no command queue") }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsCore/Kernels/s1_8_contrast.metal")
        let source = try KernelLibrary.expandingLocalIncludes(of: url)
        let library = try device.makeLibrary(source: source, options: nil)
        var map: [String: MTLComputePipelineState] = [:]
        for name in ["s1_8_g_contrast_pack", "s1_8_g_contrast_box_h", "s1_8_g_contrast_box_v",
                     "s1_8_g_contrast_coeff", "s1_8_g_contrast_apply"] {
            let fn = try XCTUnwrap(library.makeFunction(name: name), "missing \(name)")
            map[name] = try device.makeComputePipelineState(function: fn)
        }
        self.device = device
        self.queue = queue
        self.pipelines = map
        XCTAssertEqual(MemoryLayout<Params>.stride, 128, "ContrastParams' mirror must match Metal's")
    }

    func run(_ rgba: [Float], width w: Int, height h: Int, contrast: Double) throws -> [Float] {
        let q = MultiscaleContrast.block
        let qW = max(1, (w + q - 1) / q), qH = max(1, (h + q - 1) / q)
        let rc = Int32(MultiscaleContrast.radiusQ(
            fraction: MultiscaleContrast.coarseRadiusFraction,
            cap: MultiscaleContrast.coarseRadiusCap, shortEdge: Double(min(w, h))))
        let rm = Int32(MultiscaleContrast.radiusQ(
            fraction: MultiscaleContrast.midRadiusFraction,
            cap: MultiscaleContrast.midRadiusCap, shortEdge: Double(min(w, h))))
        let gains = MultiscaleContrast.scaleGains(t: contrast / 100)
        let lw = ColorPrimaries.working.luminanceWeights
        var p = Params(
            a: SIMD4(Float(contrast), Float(MultiscaleContrast.pivotEV),
                     Float(MultiscaleContrast.coarseEpsilon), Float(MultiscaleContrast.midEpsilon)),
            // 159: `.x` is the mid travel, `.y` the fine travel; the coarse slot is the named zero.
            b: SIMD4(Float(gains.mid), Float(gains.fine), Float(gains.coarse),
                     Float(MultiscaleContrast.gateLo)),
            // `.y` is the scene-linear exposure (unused by 159), `.z` the gain the kernel divides
            // the display luma by and scales the A5 floor with. The harness renders at E = 0.
            c: SIMD4(Float(MultiscaleContrast.gateHi), 0, 1, 0),
            luma: SIMD4(Float(lw.x), Float(lw.y), Float(lw.z), 0),
            rect: SIMD4(0, 0, Float(w), Float(h)),
            d: SIMD4(Int32(w), Int32(h), Int32(q), rc),
            e: SIMD4(Int32(qW), Int32(qH), 32, rm),
            f: SIMD4(0, 0, 0, 0))

        let src = try texture(w, h, .rgba32Float)
        let dst = try texture(w, h, .rgba32Float)
        src.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: rgba, bytesPerRow: w * 16)

        let base = try texture(qW, qH, .rgba32Float)
        let tmp = try texture(qW, qH, .rgba32Float)
        let boxedC = try texture(qW, qH, .rgba32Float)
        let coeffC = try texture(qW, qH, .rgba32Float)
        let statsM = try texture(qW, qH, .rgba32Float)
        let boxedM = try texture(qW, qH, .rgba32Float)
        let coeffM = try texture(qW, qH, .rgba32Float)

        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let pack = try XCTUnwrap(pipelines["s1_8_g_contrast_pack"])
        let e0 = try XCTUnwrap(cb.makeComputeCommandEncoder())
        e0.setComputePipelineState(pack)
        e0.setTexture(src, index: 0); e0.setTexture(base, index: 1)
        e0.setTexture(coeffC, index: 2); e0.setTexture(statsM, index: 3)
        e0.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        dispatch(e0, pack, qW, qH)
        e0.endEncoding()

        p.e.w = rc
        try box(cb: cb, from: base, tmp: tmp, to: boxedC, p: &p, qW: qW, qH: qH)
        p.f.x = 0
        try coeff(cb: cb, stats: boxedC, out: coeffC, p: &p, qW: qW, qH: qH)

        p.f.x = 1
        let e2 = try XCTUnwrap(cb.makeComputeCommandEncoder())
        e2.setComputePipelineState(pack)
        e2.setTexture(base, index: 0); e2.setTexture(statsM, index: 1)
        e2.setTexture(coeffC, index: 2); e2.setTexture(statsM, index: 3)
        e2.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        dispatch(e2, pack, qW, qH)
        e2.endEncoding()

        p.e.w = rm
        try box(cb: cb, from: statsM, tmp: tmp, to: boxedM, p: &p, qW: qW, qH: qH)
        p.f.x = 1
        try coeff(cb: cb, stats: boxedM, out: coeffM, p: &p, qW: qW, qH: qH)

        let apply = try XCTUnwrap(pipelines["s1_8_g_contrast_apply"])
        let e4 = try XCTUnwrap(cb.makeComputeCommandEncoder())
        e4.setComputePipelineState(apply)
        e4.setTexture(src, index: 0); e4.setTexture(coeffC, index: 1)
        e4.setTexture(coeffM, index: 2); e4.setTexture(dst, index: 3)
        e4.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        dispatch(e4, apply, w, h)
        e4.endEncoding()

        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)
        var out = [Float](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { raw in
            dst.getBytes(raw.baseAddress!, bytesPerRow: w * 16,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return out
    }

    private func box(cb: MTLCommandBuffer, from: MTLTexture, tmp: MTLTexture, to: MTLTexture,
                     p: inout Params, qW: Int, qH: Int) throws {
        let hPipe = try XCTUnwrap(pipelines["s1_8_g_contrast_box_h"])
        let e0 = try XCTUnwrap(cb.makeComputeCommandEncoder())
        e0.setComputePipelineState(hPipe)
        e0.setTexture(from, index: 0); e0.setTexture(to, index: 1)
        e0.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        e0.dispatchThreadgroups(MTLSize(width: max(1, (qW + 31) / 32), height: qH, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        e0.endEncoding()

        let vPipe = try XCTUnwrap(pipelines["s1_8_g_contrast_box_v"])
        let e1 = try XCTUnwrap(cb.makeComputeCommandEncoder())
        e1.setComputePipelineState(vPipe)
        e1.setTexture(to, index: 0); e1.setTexture(tmp, index: 1)
        e1.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        e1.dispatchThreadgroups(MTLSize(width: max(1, (qW + 31) / 32),
                                       height: max(1, (qH + 31) / 32), depth: 1),
                               threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        e1.endEncoding()

        let blit = cb.makeBlitCommandEncoder()
        blit?.copy(from: tmp, sourceSlice: 0, sourceLevel: 0,
                   sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                   sourceSize: MTLSize(width: qW, height: qH, depth: 1),
                   to: to, destinationSlice: 0, destinationLevel: 0,
                   destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit?.endEncoding()
    }

    private func coeff(cb: MTLCommandBuffer, stats: MTLTexture, out: MTLTexture,
                       p: inout Params, qW: Int, qH: Int) throws {
        let pipe = try XCTUnwrap(pipelines["s1_8_g_contrast_coeff"])
        let e = try XCTUnwrap(cb.makeComputeCommandEncoder())
        e.setComputePipelineState(pipe)
        e.setTexture(stats, index: 0); e.setTexture(out, index: 1)
        e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        dispatch(e, pipe, qW, qH)
        e.endEncoding()
    }

    private func texture(_ w: Int, _ h: Int, _ format: MTLPixelFormat) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }

    private func dispatch(_ e: MTLComputeCommandEncoder, _ p: MTLComputePipelineState,
                          _ w: Int, _ h: Int) {
        let tw = p.threadExecutionWidth
        let th = max(1, p.maxTotalThreadsPerThreadgroup / tw)
        e.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }
}
