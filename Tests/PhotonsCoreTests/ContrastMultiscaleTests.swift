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

    /// 159 — contrast is S2.5 and **residual-only**. 098's A2 ("HDR highlights must move") was a
    /// consequence of the coarse *level* term (`k_c·(B_c − P)`), which 142 measured to be exactly why
    /// `exposure × contrast` did not commute. That term is deleted **by design**: the operator order is
    /// decided by commutativity — what commutes with exposure stays in the scene-linear stages, what
    /// does not goes after the tone map (user, 2026-10-30; `docs/tasks/174-contrast-contract.md` §0).
    /// The display-domain form of "the highlights are not ignored" is therefore the pair below:
    ///
    ///   (a) a **flat** field has no residual ⇒ it does not move at any contrast. This is the
    ///       assertion that keeps the level term deleted — re-adding one fails here immediately;
    ///   (b) detail at display white **does** expand, and the white shoulder never lets a positive
    ///       gain put a pixel onto the ceiling (`Y_output ≤ 0.98`, `s2_5_contrast_gain`).
    func testA2FlatFieldsAreUntouchedAndDetailAtWhiteDoesNotClip() throws {
        // (a) the flat strip: SDR below 1, and 1/2/4/8 above it. `headroom = 8` so S4 keeps the
        // above-white samples and the stage's own output is what is measured.
        let values: [Float] = [0.05, 0.18, 0.5, 1, 2, 4, 8]
        // 64 px patches: the coarse window is 3 q = 12 px, so a patch centre cannot see its
        // neighbour — otherwise the test would measure the *edge* residual, not the flat field.
        let patch = 64
        let width = values.count * patch, height = 64
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = values[x / patch]
                let i = (y * width + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v)
                rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        let image = LinearImage(width: width, height: height, rgba: rgba,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let g = try graph(image)
        let base = try render(g, .neutral, headroom: 8)

        for c in [100.0, -100.0] {
            var edit = EditModel.neutral
            edit.light.contrast = c
            let out = try render(g, edit, headroom: 8)
            var worst = 0.0
            for i in values.indices {
                for y in stride(from: 8, to: height - 8, by: 9) {
                    let x = patch * i + patch / 2     // the patch centre, away from the joins
                    worst = max(worst, abs(code(out, x, y) - code(base, x, y)))
                }
            }
            print(String(format: "A2 flat strip c=%+.0f · worst |Δcode| %.3f (residual-only: "
                         + "a flat field has no band to gain)", c, worst))
            // One display code is Float16's own grid on an 8-bit readback; anything above it is the
            // stage moving a field that has no residual, i.e. a level term back from the dead.
            XCTAssertLessThanOrEqual(worst, 1.0,
                                     "c = \(c): a flat field must not move (the level term is deleted)")
        }

        // (b) 2 px detail whose plateau sits just under display white.
        let dw = 240, dh = 160
        let detail = frame(dw, dh) { x, _ in 0.55 + ((x / 2) % 2 == 0 ? 0.10 : -0.10) }
        let dg = try graph(detail, identity: "contrast-ms-a2-detail")
        let dBase = try render(dg, .neutral)
        var dEdit = EditModel.neutral
        dEdit.light.contrast = 100
        let dOut = try render(dg, dEdit)
        var ampBase = 0.0, ampOut = 0.0, peak = 0.0
        for y in 20..<(dh - 20) {
            for x in 20..<(dw - 20) {
                ampBase = max(ampBase, luma(dBase, x, y))
                ampOut = max(ampOut, luma(dOut, x, y))
                peak = max(peak, luma(dOut, x, y))
            }
        }
        print(String(format: "A2 detail at white · peak Y %.4f → %.4f · shoulder cap 0.98",
                     ampBase, ampOut))
        XCTAssertGreaterThanOrEqual(ampOut, ampBase * 1.02,
                                   "local detail under white must still expand at +100")
        XCTAssertLessThanOrEqual(peak, 0.985,
                                 "a positive gain must never put a below-white pixel on the ceiling")

        // Refutation: the removed S2 bend is exactly the identity above display white.
        for v in [1.0, 2.0, 4.0, 8.0] {
            XCTAssertEqual(S2Contrast.gain(luma: v, contrast: 100), 1.0, accuracy: 1e-12,
                           "the old global bend must be the identity above white")
        }
    }

    /// A grey frame whose value is a function of the pixel — the shape tests below all need one.
    private func frame(_ w: Int, _ h: Int, _ value: (Int, Int) -> Double) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = Float16(value(x, y))
                let i = (y * w + x) * 4
                rgba[i] = v; rgba[i + 1] = v; rgba[i + 2] = v; rgba[i + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
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

    /// 159 re-pin — **what "no halo" can still mean once the operator is display-referred.**
    ///
    /// 098's bound (3 codes at 3…6 px) was measured with 098's weights: 0.5 / 0.25 EV of travel, so a
    /// step residual of ~0.5 EV moved the picture by ~0.2 EV. 159 rides 7.50 / 3.75 on the same
    /// residual, so the identical step gets 15× the lift and rows inside the guided filter's window
    /// move by ~1 EV. That is the operator's step response, not a rendering error — what it must still
    /// do, and what this test pins instead of the old 3-code bound, is:
    ///
    ///   1. the response is **confined**: at 4× the coarse radius the output is the neutral render to
    ///      within a code (no level term, no long-range bleed);
    ///   2. the response **decays monotonically** away from the edge on both sides — a dark band next to
    ///      the step and a bright band on the other side *is* a halo in 098's sense, and it is here: what
    ///      098 could assert beyond a bound was that the profile does not ring (overshoot followed by
    ///      undershoot), and that still holds;
    ///   3. a positive lift never crosses the shoulder cap (0.98) and a negative one never crosses the
    ///      black floor, so neither end is pushed onto a ceiling;
    ///   4. the pinned lift is the number these constants produce (±8 codes), so a change in the band
    ///      weights cannot pass silently.
    ///
    /// Numbers taken at contrast = +100 on this frame: dark plateau 69.0 → 35.2 codes at the edge,
    /// light plateau 188.6 → 252.6 (the shoulder). The same-radius unsharp is the control: it must
    /// still be far outside anything the guided filter does.
    func testA4StepEdgeResponseIsConfinedAndDoesNotRing() throws {
        let (image, edgeY) = twotone()
        let g = try graph(image)
        var edit = EditModel.neutral
        edit.light.contrast = 100
        // Headroom 8: `+100` legitimately puts the 0.50 plateau above display white, and clipping it
        // would turn "no halo" into "both plateaus are 255".
        let out = try render(g, edit, headroom: 8)
        // The measured strip starts 96 px into the right half: the coarse window is 32 px, so the
        // checkerboard next door must not reach it (it did by 61 codes at 20 px, which measures the
        // checker's residual, not the step's halo).
        let x0 = image.width / 2 + 96, stripW = image.width / 2 - 96 - 40
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

        // 1 · confined: 80…100 px either side of the edge is the neutral render to within a code.
        let neutral = try render(g, .neutral, headroom: 8)
        var far = 0.0
        for y in Array((edgeY - 100)..<(edgeY - 80)) + Array((edgeY + 80)..<(edgeY + 100)) {
            for x in x0..<(x0 + stripW) {
                far = max(far, abs(code(out, x, y) - code(neutral, x, y)))
            }
        }
        print(String(format: "A4 far field (80…100 px): max |Δneutral| %.3f codes", far))
        XCTAssertLessThanOrEqual(far, 1.0, "the response must not reach outside the filter window")

        // 2 · monotone away from the edge on both sides (no ringing).
        func column(_ image: DisplayImage, _ x: Int, _ ys: [Int]) -> [Double] {
            ys.map { code(image, x, $0) }
        }
        var monotone = true
        let darkSide = Array((edgeY - 32)..<(edgeY - 2)).reversed().map { $0 }   // edge → far
        let lightSide = Array((edgeY + 3)...(edgeY + 32))                        // edge → far
        for x in stride(from: x0, to: x0 + stripW, by: 16) {
            // Walking away from the edge the dark side rises back to its plateau and the light side
            // falls back to its own; any reversal is the overshoot/undershoot a halo is made of.
            let d = column(out, x, darkSide)
            for i in 1..<d.count where d[i] < d[i - 1] - 0.5 { monotone = false }
            let l = column(out, x, lightSide)
            for i in 1..<l.count where l[i] > l[i - 1] + 0.5 { monotone = false }
        }
        XCTAssertTrue(monotone, "the step response must decay away from the edge, not ring")

        // 3 · neither end onto a ceiling: the light side is capped by the shoulder, the dark side by
        // the floor.
        var peak = 0.0, trough = 1.0
        for y in (edgeY + 3)...(edgeY + 32) {
            for x in x0..<(x0 + stripW) { peak = max(peak, luma(out, x, y)) }
        }
        for y in (edgeY - 32)..<(edgeY - 2) {
            for x in x0..<(x0 + stripW) { trough = min(trough, luma(out, x, y)) }
        }
        print(String(format: "A4 step response: dark %.4f linear · light %.4f linear (cap 0.98 · floor %.5f)",
                     trough, peak, MultiscaleContrast.floorY))
        XCTAssertLessThanOrEqual(peak, 0.985, "the shoulder must keep the light side under white")
        XCTAssertGreaterThanOrEqual(trough, MultiscaleContrast.floorY,
                                    "the floor must keep the dark side above the display black")

        // 4 · the pinned lift of these constants.
        func plateau(_ ys: [Int]) -> Double {
            var acc = 0.0
            for y in ys { for x in x0..<(x0 + stripW) { acc += code(out, x, y) } }
            return acc / Double(ys.count * stripW)
        }
        let darkPlateau = plateau(Array((edgeY - 60)..<(edgeY - 40)))
        let lightPlateau = plateau(Array((edgeY + 40)..<(edgeY + 60)))
        print(String(format: "A4 pinned lift: dark %.1f → %.1f codes (%.1f) · light %.1f → %.1f (%.1f)",
                     darkPlateau, code(out, x0 + 20, edgeY - 4), code(out, x0 + 20, edgeY - 4) - darkPlateau,
                     lightPlateau, code(out, x0 + 20, edgeY + 4), code(out, x0 + 20, edgeY + 4) - lightPlateau))
        XCTAssertEqual(code(out, x0 + 20, edgeY - 4) - darkPlateau, -33.8, accuracy: 8.0,
                       "the dark-side lift is pinned (7.50/3.75 at +100)")
        XCTAssertEqual(code(out, x0 + 20, edgeY + 4) - lightPlateau, 64.0, accuracy: 8.0,
                       "the light-side lift is pinned (shoulder-capped)")
        // 098's 3-code bound cannot be carried over: the same step residual rides 15× the weight here
        // (see the doc comment). The number is pinned instead, so it can only move on purpose.
        XCTAssertEqual(contrastHalo, 64.0, accuracy: 8.0,
                       "the display-domain step response is pinned (±8 codes)")
        XCTAssertGreaterThanOrEqual(unsharpHalo, 20.0,
                                    "the unsharp control must fail this bound, or the test has no teeth")
    }

    // MARK: - A5: the three bands respond separately

    /// 159 re-pin. 098 asked "does each band move its own pattern"; the display operator has three
    /// **weights**, not three level anchors — `coarseWeight = 0` by design (a gain anchored to an
    /// absolute level is exactly what made exposure and contrast non-commutative), `midWeight = 7.50`,
    /// `fineWeight = 3.75`. The shape claim therefore becomes:
    ///
    ///   1. a coarse-only signal (a pure EV-linear gradient ⇒ zero mid/fine residual) is **untouched**.
    ///      This is the assertion that keeps the coarse level term deleted;
    ///   2. detail at the mid band's period is amplified harder than detail at the fine band's, because
    ///      the same residual rides a 2× weight — that is what makes them three bands, not one slider.
    func testA5CoarseGradientIsUntouchedAndBothBandsExpand() throws {
        let w = 750, h = 500
        var edit = EditModel.neutral
        edit.light.contrast = 100

        /// Peak-to-trough display luma over the frame's interior: how much local contrast a periodic
        /// pattern carries after the stage (linear light, so a ratio-scale amplitude).
        func spread(_ image: DisplayImage) -> Double {
            var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
            for y in stride(from: 40, to: h - 40, by: 2) {
                for x in stride(from: 40, to: w - 40, by: 2) {
                    let v = luma(image, x, y)
                    lo = min(lo, v); hi = max(hi, v)
                }
            }
            return hi - lo
        }

        func amplified(_ image: LinearImage, identity: String) throws -> Double {
            let g = try graph(image, identity: identity)
            let base = try render(g, .neutral, headroom: 8)
            let out = try render(g, edit, headroom: 8)
            return spread(out) / spread(base)
        }

        // 1 · coarse only. The ramp is linear in **EV** (a linear-light ramp is not): its display log
        // is linear in x too, because the tone map is a power law over this range, so both residuals
        // are ~0. A flat column profile has no `spread`, hence the slope.
        let ramp = frame(w, h) { x, _ in pow(2.0, -5.0 + 3.0 * Double(x) / Double(w - 1)) } // 1/32 … 1/4
        let g1 = try graph(ramp, identity: "contrast-ms-a5-ramp")
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
        print(String(format: "A5 coarse gradient · slope ×%.4f · mid+fine residual %.3e → %.3e EV",
                     slopeGain, baseEnergy, outEnergy))
        XCTAssertEqual(slopeGain, 1.0, accuracy: 0.01,
                       "a coarse-only gradient must not move: `coarseWeight` is the named zero")
        XCTAssertLessThan(abs(outEnergy - baseEnergy) / 3.0, 0.01,
                          "a pure gradient must not gain mid/fine energy")

        // 2 · mid vs fine, same ≈0.2 EV of residual at two periods. The mid base averages 2 q = 8 px;
        // whatever survives inside those 8 px is the fine band.
        // Same ±0.70 EV peak-to-peak in **log** light, so the two patterns carry the same residual
        // amplitude and the comparison is about the weights, not about which one is more contrasty.
        let mid = frame(w, h) { x, _ in 0.30 * pow(2.0, 0.70 * sin(2 * Double.pi * Double(x) / 24.0)) }
        let fine = frame(w, h) { x, _ in 0.30 * pow(2.0, (x / 2) % 2 == 0 ? 0.70 : -0.70) }
        let midGain = try amplified(mid, identity: "contrast-ms-a5-mid")
        let fineGain = try amplified(fine, identity: "contrast-ms-a5-fine")
        print(String(format: "A5 mid (24 px) ×%.3f · fine (2 px) ×%.3f · weights 7.50 / 3.75",
                     midGain, fineGain))
        // Both non-zero bands must respond, and by the numbers these constants give (a residual of
        // ±0.35 EV riding 7.50 / 3.75 is ~1.3 EV of lift, i.e. ~2.5× of amplitude). The mid and fine
        // responses come out within 1 % of each other at equal log amplitude — the pattern→band split
        // is not a clean 1:1 mapping of the weights — so the 2:1 weight ratio is asserted on the
        // constants below, not on two different pictures.
        XCTAssertGreaterThanOrEqual(midGain, 2.0, "mid-scale detail must expand at +100")
        XCTAssertGreaterThanOrEqual(fineGain, 2.0, "fine-scale detail must expand at +100")
        XCTAssertLessThanOrEqual(max(midGain, fineGain) / min(midGain, fineGain), 1.5,
                                 "the two non-zero bands must move together")
    }

    // MARK: - A6: monotone, no fold, no banding

    /// 159 re-pin. Monotone and fold-free are properties of the **operator**, so they carry over to the
    /// display domain unchanged; what has to be re-taken is the staircase budget. A display-domain ramp
    /// is already compressed by the tone map, so the budget is stated against what the ramp itself
    /// brings (`base`, printed) and capped at the 2 codes the ticket asks for.
    func testA6GreyRampIsMonotoneAndWithinTwoCodes() throws {
        // Part 1 — the full 8-bit sRGB ramp: no fold at any slider position, and no step the base
        // ramp did not already have. This is the invariant a monotone operator has to keep. (A 1-code
        // step in the deep shadows is itself a 1.5× linear jump, so the absolute 2-code bound is
        // asserted on the equal-EV ramp below, where "banding" is a property of the operator.)
        let w = 256, h = 64

        func codes(_ image: DisplayImage, _ width: Int) -> [Double] {
            (0..<width).map { code(image, $0, h / 2) }
        }

        func steps(_ image: DisplayImage, _ width: Int) -> [Double] {
            let c = codes(image, width)
            return (1..<c.count).map { c[$0] - c[$0 - 1] }
        }

        let ramp = frame(w, h) { x, _ in 0.001 * pow(1000.0, Double(x) / Double(w - 1)) }
        let g = try graph(ramp, identity: "contrast-ms-a6-ramp")
        let baseSteps = steps(try render(g, .neutral), w)
        print(String(format: "A6 full 8-bit ramp · base max step %.3f codes",
                     baseSteps.max() ?? 0))
        for c in stride(from: -100.0, through: 100.0, by: 20) {
            var edit = EditModel.neutral
            edit.light.contrast = c
            let out = try render(g, edit)
            let c0 = codes(out, w)
            let d = steps(out, w)
            // The first/last 40 px are the coarse filter's clamp-to-edge extension, exactly as in
            // part 2: the claim is about the operator's transfer, not about the ramp's ends.
            for i in 40..<(d.count - 40) {
                let step = d[i]
                // A 10-stop ramp squeezed by the OETF has steps of a few hundredths of a code at the
                // black end, so there the bound is the display encoder's own one code; from code 16 up
                // (where one code is a real step on this ramp) the operator must be monotone to the bit.
                let bound = c0[i] < 16 ? -1.0 : -1e-4
                XCTAssertGreaterThanOrEqual(step, bound,
                                            "c = \(c): the ramp folded at code \(i + 1)")
            }
            print(String(format: "A6 full 8-bit ramp c=%+4.0f · max step %.3f codes", c, d.max() ?? 0))
            XCTAssertLessThanOrEqual((d.max() ?? 0), (baseSteps.max() ?? 0) + 0.5,
                                     "c = \(c): the operator added a step the ramp did not have")
        }

        // Part 2 — 256 levels **equally spaced in EV** over the display range the operator works in
        // (scene −6 … 0 EV is display white's neighbourhood after S2). The 2-code staircase budget is
        // asserted here, absolutely: this is where a jumpy gain shows up as banding.
        let levels = 256
        let evImage = frame(levels, h) { x, _ in
            pow(2.0, -6.0 + 6.0 * Double(x) / Double(levels - 1))
        }
        let evGraph = try graph(evImage, identity: "contrast-ms-a6-ev")
        let evBase = steps(try render(evGraph, .neutral), levels)
        print(String(format: "A6 equal-EV ramp · base max step %.3f codes", evBase.max() ?? 0))
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
