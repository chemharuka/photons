import XCTest
import Metal
import PhotonsCore

/// 171 — the 去噪 / 去彩噪 acceptance, measured through the shipped graph on synthetic frames.
///
/// The two controls used to be "a blur" and "a black-and-white filter": the luma side was a guided
/// base mean (edge width ≈ a Gaussian's) and the chroma side scaled OKLab `C` by `1 − 0.9·amt`,
/// which took a saturated patch to 10 % chroma. 171 replaces both with **one joint bilateral grid**
/// (Halide's `apps/bilateral_grid`, MIT): splat → 5-tap blur (z→x→y) → trilinear slice. This file is
/// the proof that the replacement is a *denoiser* and not a low-pass, one measurement per requirement:
///
///   A  noise        — flat-region σ falls ≥ 50 % at amount = 100.
///   B  edge         — the same step's 10→90 % width stays ≤ 1.25× the source **and** ≤ 0.7× the width
///                     of a Gaussian calibrated to the *same* noise reduction (which must be ≥ 2×).
///   C  texture      — Laplacian RMS on the texture band keeps ≥ 60 % (the same Gaussian keeps < 50 %).
///   D  chroma noise — σa, σb on a flat patch fall ≥ 50 %.
///   E  real colour  — six saturated patches keep ≥ 95 % of their OKLab `C` (was 10 %).
///   F  luma is held — chroma-only changes every pixel's luma by ≤ 1 code.
///
/// Every number printed here comes from a real render of the shipped Metal kernels (the research
/// report's figures were a Python simulation and are not reused).
final class DetailDenoiseTests: XCTestCase {

    private static let w = 750
    private static let h = 500

    // MARK: - plumbing

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    private func image(_ rgba: [Float16], w: Int, h: Int, _ tag: String) -> LinearImage {
        LinearImage(width: w, height: h, rgba: rgba,
                    colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-171-\(tag)")
    }

    /// A deterministic LCG — the same one `DetailFXTests` uses, so the two files' fixtures agree.
    private struct Noise {
        var seed: UInt32
        init(_ s: UInt32) { seed = s }
        mutating func next() -> Double {
            seed = seed &* 1664525 &+ 1013904223
            return Double(seed >> 8) / Double(1 << 24)
        }
        /// Symmetric uniform in ±`amplitude`.
        mutating func symmetric(_ amplitude: Double) -> Double { (next() - 0.5) * 2 * amplitude }
    }

    // MARK: - measurement

    private func lumaCodes(_ image: DisplayImage) -> [Double] {
        var out = [Double](repeating: 0, count: image.width * image.height)
        for i in 0..<(image.width * image.height) {
            let b = i * 4
            out[i] = 255 * (0.2126 * Double(image.rgba[b]) + 0.7152 * Double(image.rgba[b + 1])
                            + 0.0722 * Double(image.rgba[b + 2]))
        }
        return out
    }

    /// High-pass residual against a `radius`-box mean: σ of the noise on a flat patch.
    private func highPassSigma(_ luma: [Double], w: Int, h: Int,
                               x0: Int, x1: Int, y0: Int, y1: Int, radius: Int = 2) -> Double {
        func at(_ x: Int, _ y: Int) -> Double { luma[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)] }
        var sum = 0.0; var n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                var s = 0.0; var c = 0
                for dy in -radius...radius {
                    for dx in -radius...radius { s += at(x + dx, y + dy); c += 1 }
                }
                let d = at(x, y) - s / Double(c)
                sum += d * d; n += 1
            }
        }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    /// Laplacian RMS (4-neighbour), the texture-energy measure of requirement C.
    private func laplacianRMS(_ luma: [Double], w: Int, h: Int,
                              x0: Int, x1: Int, y0: Int, y1: Int) -> Double {
        func at(_ x: Int, _ y: Int) -> Double { luma[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)] }
        var sum = 0.0; var n = 0
        for y in max(y0, 1)..<min(y1, h - 1) {
            for x in max(x0, 1)..<min(x1, w - 1) {
                let lap = 4 * at(x, y) - at(x - 1, y) - at(x + 1, y) - at(x, y - 1) - at(x, y + 1)
                sum += lap * lap; n += 1
            }
        }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    /// A horizontal step's 10 %→90 % transition width in pixels: the row-mean luma profile, then the
    /// two crossings, linearly interpolated.
    private func edgeWidth(_ image: DisplayImage, x0: Int, x1: Int) -> Double {
        let luma = lumaCodes(image)
        let w = image.width
        var profile = [Double](repeating: 0, count: image.height)
        for y in 0..<image.height {
            var s = 0.0
            for x in x0..<x1 { s += luma[y * w + x] }
            profile[y] = s / Double(x1 - x0)
        }
        let lo = profile.prefix(image.height / 4).reduce(.greatestFiniteMagnitude, min)
        let hi = profile.suffix(image.height / 4).reduce(-.greatestFiniteMagnitude, max)
        let t10 = lo + 0.1 * (hi - lo), t90 = lo + 0.9 * (hi - lo)
        func crossing(_ t: Double) -> Double {
            for y in 1..<image.height where profile[y] >= t {
                let a = profile[y - 1], b = profile[y]
                return Double(y - 1) + (b == a ? 0 : (t - a) / (b - a))
            }
            return Double(image.height)
        }
        return crossing(t90) - crossing(t10)
    }

    /// OKLab (a, b) per pixel, the chroma axes the two controls are defined on.
    private func oklabAB(_ image: DisplayImage) -> [(Double, Double)] {
        var out = [(Double, Double)](repeating: (0, 0), count: image.width * image.height)
        for i in 0..<(image.width * image.height) {
            let b = i * 4
            let r = max(Double(image.rgba[b]), 0), g = max(Double(image.rgba[b + 1]), 0)
            let bb = max(Double(image.rgba[b + 2]), 0)
            let l = cbrt(0.6167557877 * r + 0.3601984026 * g + 0.0230458097 * bb)
            let m = cbrt(0.2651330603 * r + 0.6358393719 * g + 0.0990275679 * bb)
            let s = cbrt(0.1001026312 * r + 0.2039065206 * g + 0.6959908482 * bb)
            out[i] = (1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
        }
        return out
    }

    private func meanChroma(_ image: DisplayImage, x0: Int, x1: Int, y0: Int, y1: Int) -> Double {
        let ab = oklabAB(image)
        var sum = 0.0; var n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let (a, b) = ab[y * image.width + x]
                sum += (a * a + b * b).squareRoot(); n += 1
            }
        }
        return sum / Double(max(n, 1))
    }

    // MARK: - fixtures

    /// Noise **everywhere** (as a real frame has) with a flat left half and one step on the right:
    /// the flat half measures A, the step measures B on the same render.
    private func noisyStep() -> LinearImage {
        let w = Self.w, h = Self.h
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        var noise = Noise(0x9E3779B9)
        for y in 0..<h {
            for x in 0..<w {
                let base: Double = x < w / 2 ? 0.20 : (y < h / 2 ? 0.06 : 0.50)
                let v = base + noise.symmetric(0.04)
                let i = (y * w + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v); rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        return image(rgba, w: w, h: h, "noisy-step")
    }

    /// A 4-px checkerboard at ±0.05 on 0.20, plus the same noise: requirement C, and the pattern
    /// amplitude is measured against the known basis as well (noise has no correlation with it).
    private func noisyChecker() -> LinearImage {
        let w = Self.w, h = Self.h
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        var noise = Noise(0x1234567)
        for y in 0..<h {
            for x in 0..<w {
                let v = 0.20 + ((x / 4 + y / 4) % 2 == 0 ? 0.05 : -0.05) + noise.symmetric(0.04)
                let i = (y * w + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v); rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        return image(rgba, w: w, h: h, "noisy-checker")
    }

    /// Flat mid-grey with independent per-channel perturbation — the "coloured speckle" of a real
    /// high-ISO frame: nearly all of it is chroma, a little is luma.
    private func chromaSpeckle() -> LinearImage {
        let w = 400, h = 300
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        var noise = Noise(0xBEEF01)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let base = 0.35
            rgba[i] = Float16(base + noise.symmetric(0.055))
            rgba[i + 1] = Float16(base + noise.symmetric(0.055))
            rgba[i + 2] = Float16(base + noise.symmetric(0.055))
            rgba[i + 3] = 1
        }
        return image(rgba, w: w, h: h, "chroma-speckle")
    }

    private static let patchColours: [(Float, Float, Float)] = [
        (0.46, 0.17, 0.14),   // red
        (0.43, 0.41, 0.12),   // yellow
        (0.15, 0.43, 0.18),   // green
        (0.13, 0.41, 0.43),   // cyan
        (0.14, 0.22, 0.46),   // blue
        (0.41, 0.16, 0.41),   // magenta
    ]

    /// Six saturated patches on a neutral field — requirement E: a real colour must survive.
    private func saturatedPatches() -> LinearImage {
        let w = 600, h = 200
        let patch = 80, inset = 12
        var rgba = [Float16](repeating: 0.35, count: w * h * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba[i + 3] = 1 }
        for (k, c) in Self.patchColours.enumerated() {
            let x0 = inset + k * (patch + 12), y0 = (h - patch) / 2
            for y in y0..<(y0 + patch) {
                for x in x0..<(x0 + patch) {
                    let i = (y * w + x) * 4
                    rgba[i] = Float16(c.0); rgba[i + 1] = Float16(c.1); rgba[i + 2] = Float16(c.2)
                }
            }
        }
        return image(rgba, w: w, h: h, "saturated-patches")
    }

    private func patchRect(_ k: Int) -> (Int, Int, Int, Int) {
        let patch = 80, inset = 12, margin = 16
        let x0 = inset + k * (patch + 12)
        let y0 = (200 - patch) / 2
        return (x0 + margin, x0 + patch - margin, y0 + margin, y0 + patch - margin)
    }

    // MARK: - a Gaussian at the *same* noise reduction (the paired reference for B and C)

    /// Separable Gaussian on the linear fixture, edge-replicated.
    private func gaussian(_ image: LinearImage, sigma: Double) -> LinearImage {
        let r = max(1, Int((3 * sigma).rounded()))
        var kernel = [Double](repeating: 0, count: 2 * r + 1)
        var total = 0.0
        for i in 0...2 * r {
            let d = Double(i - r)
            kernel[i] = exp(-d * d / (2 * sigma * sigma)); total += kernel[i]
        }
        kernel = kernel.map { $0 / total }
        let w = image.width, h = image.height
        var tmp = [Double](repeating: 0, count: w * h * 4)
        var out = [Double](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<4 {
                    var s = 0.0
                    for k in -r...r {
                        let xx = min(max(x + k, 0), w - 1)
                        s += kernel[k + r] * Double(image.rgba[(y * w + xx) * 4 + c])
                    }
                    tmp[(y * w + x) * 4 + c] = s
                }
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<4 {
                    var s = 0.0
                    for k in -r...r {
                        let yy = min(max(y + k, 0), h - 1)
                        s += kernel[k + r] * tmp[(yy * w + x) * 4 + c]
                    }
                    out[(y * w + x) * 4 + c] = s
                }
            }
        }
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for i in 0..<rgba.count { rgba[i] = Float16(out[i]) }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: image.colorSpace, decoderVersion: "synthetic-171-gauss")
    }

    /// ‖g‖₂ of the 1-D kernel: a Gaussian of σ reduces white noise by exactly this factor.
    private func gaussianNoiseFactor(_ sigma: Double) -> Double {
        let r = max(1, Int((3 * sigma).rounded()))
        var kernel = [Double](repeating: 0, count: 2 * r + 1)
        var total = 0.0
        for i in 0...2 * r {
            let d = Double(i - r)
            kernel[i] = exp(-d * d / (2 * sigma * sigma)); total += kernel[i]
        }
        kernel = kernel.map { $0 / total }
        let norm = kernel.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm * norm      // two separable axes
    }

    /// The σ_g whose noise reduction matches `factor` (= σ_after / σ_before), by bisection.
    private func matchedGaussianSigma(forFactor factor: Double) -> Double {
        var lo = 0.05, hi = 12.0
        for _ in 0..<60 {
            let mid = 0.5 * (lo + hi)
            if gaussianNoiseFactor(mid) > factor { lo = mid } else { hi = mid }
        }
        return 0.5 * (lo + hi)
    }

    // MARK: - A + B: one render of the noisy step

    func testNoiseFallsAndTheEdgeDoesNotWiden() throws {
        let source = noisyStep()
        let graph = try makeGraph(source, identity: "171-ab")

        var edit = EditModel.neutral
        edit.effects.nonBayerLuminanceNR = 100

        let before = try render(graph, .neutral)
        let after = try render(graph, edit)

        let w = before.width, h = before.height
        let lumaBefore = lumaCodes(before), lumaAfter = lumaCodes(after)
        // The flat half, away from the frame border and from the step.
        let (fx0, fx1, fy0, fy1) = (8, w / 2 - 8, 8, h - 8)
        let sigmaBefore = highPassSigma(lumaBefore, w: w, h: h, x0: fx0, x1: fx1, y0: fy0, y1: fy1)
        let sigmaAfter = highPassSigma(lumaAfter, w: w, h: h, x0: fx0, x1: fx1, y0: fy0, y1: fy1)
        let reduction = 1 - sigmaAfter / sigmaBefore
        print(String(format: "171 A · flat σ %.2f → %.2f codes (↓%.1f%%)",
                     sigmaBefore, sigmaAfter, 100 * reduction))
        var meanBefore = 0.0, meanAfter = 0.0
        for y in fy0..<fy1 { for x in fx0..<fx1 {
            meanBefore += lumaBefore[y * w + x]; meanAfter += lumaAfter[y * w + x]
        } }
        let n = Double((fx1 - fx0) * (fy1 - fy0))
        print(String(format: "171 A · flat mean %.3f → %.3f codes (Δ%+.3f)",
                     meanBefore / n, meanAfter / n, (meanAfter - meanBefore) / n))
        XCTAssertGreaterThanOrEqual(reduction, 0.50, "A: 平坦区噪声 σ 必须 ↓≥50%")

        // B — this render's step, and a Gaussian calibrated to exactly this noise reduction.
        let edgeX = (w / 2 + 12, w - 12)
        let widthBefore = edgeWidth(before, x0: edgeX.0, x1: edgeX.1)
        let widthAfter = edgeWidth(after, x0: edgeX.0, x1: edgeX.1)
        let sigmaG = matchedGaussianSigma(forFactor: sigmaAfter / sigmaBefore)
        let blurred = gaussian(source, sigma: sigmaG)
        let gaussGraph = try makeGraph(blurred, identity: "171-ab-gauss")
        let gaussImage = try render(gaussGraph, .neutral)
        let widthGauss = edgeWidth(gaussImage, x0: edgeX.0, x1: edgeX.1)
        print(String(format: "171 B · edge 10–90 %: 原图 %.2f px · 去噪 %.2f px (%.2f×) · "
                     + "同降噪高斯 σ_g %.2f → %.2f px (%.2f×) · 比值 %.2f",
                     widthBefore, widthAfter, widthAfter / widthBefore,
                     sigmaG, widthGauss, widthGauss / widthBefore, widthAfter / widthGauss))
        XCTAssertLessThanOrEqual(widthAfter, 1.25 * widthBefore, "B: 去噪后的边宽必须 ≤1.25× 原图")
        XCTAssertGreaterThanOrEqual(widthGauss, 2.0 * widthBefore,
                                    "B: 同降噪量的高斯必须把边加宽 ≥2×（否则这条比较没有意义）")
        XCTAssertLessThanOrEqual(widthAfter / widthGauss, 0.7, "B: 去噪/高斯 边宽比必须 ≤0.7")
    }

    // MARK: - C: texture

    func testTextureSurvivesBetterThanAGaussian() throws {
        let source = noisyChecker()
        let graph = try makeGraph(source, identity: "171-c")
        var edit = EditModel.neutral
        edit.effects.nonBayerLuminanceNR = 100

        let before = try render(graph, .neutral)
        let after = try render(graph, edit)
        let w = before.width, h = before.height
        let (x0, x1, y0, y1) = (16, w - 16, 16, h - 16)
        let lapBefore = laplacianRMS(lumaCodes(before), w: w, h: h, x0: x0, x1: x1, y0: y0, y1: y1)
        let lapAfter = laplacianRMS(lumaCodes(after), w: w, h: h, x0: x0, x1: x1, y0: y0, y1: y1)
        let retention = lapAfter / lapBefore
        print(String(format: "171 C · Laplacian RMS %.2f → %.2f codes (保留 %.1f%%)",
                     lapBefore, lapAfter, 100 * retention))
        XCTAssertGreaterThanOrEqual(retention, 0.60, "C: 纹理 Laplacian RMS 保留率必须 ≥60%")

        // The paired Gaussian at the same noise reduction, for the "a blur is not this" half.
        let sigmaBefore = highPassSigma(lumaCodes(before), w: w, h: h, x0: 8, x1: w - 8, y0: 8, y1: h - 8)
        let sigmaAfter = highPassSigma(lumaCodes(after), w: w, h: h, x0: 8, x1: w - 8, y0: 8, y1: h - 8)
        let sigmaG = matchedGaussianSigma(forFactor: sigmaAfter / sigmaBefore)
        let gaussImage = try render(try makeGraph(gaussian(source, sigma: sigmaG), identity: "171-c-g"),
                                    .neutral)
        let lapGauss = laplacianRMS(lumaCodes(gaussImage), w: w, h: h, x0: x0, x1: x1, y0: y0, y1: y1)
        print(String(format: "171 C · same-reduction Gaussian σ_g %.2f → Laplacian RMS %.2f (保留 %.1f%%)",
                     sigmaG, lapGauss, 100 * lapGauss / lapBefore))
        XCTAssertLessThan(lapGauss / lapBefore, retention, "C: 高斯必须比去噪掉更多纹理")
    }

    // MARK: - D: chroma noise

    func testChromaSpeckleFalls() throws {
        let graph = try makeGraph(chromaSpeckle(), identity: "171-d")
        var edit = EditModel.neutral
        edit.effects.nonBayerColorNR = 100
        let before = try render(graph, .neutral)
        let after = try render(graph, edit)

        let abBefore = oklabAB(before), abAfter = oklabAB(after)
        let w = before.width, h = before.height
        func sigma(_ ab: [(Double, Double)], _ pick: ((Double, Double)) -> Double) -> Double {
            var s = 0.0, ss = 0.0; var n = 0
            for y in 8..<(h - 8) {
                for x in 8..<(w - 8) {
                    let v = pick(ab[y * w + x]); s += v; ss += v * v; n += 1
                }
            }
            let m = s / Double(n)
            return (ss / Double(n) - m * m).squareRoot()
        }
        let saBefore = sigma(abBefore) { $0.0 }, saAfter = sigma(abAfter) { $0.0 }
        let sbBefore = sigma(abBefore) { $0.1 }, sbAfter = sigma(abAfter) { $0.1 }
        print(String(format: "171 D · σa %.4f → %.4f (↓%.1f%%) · σb %.4f → %.4f (↓%.1f%%)",
                     saBefore, saAfter, 100 * (1 - saAfter / saBefore),
                     sbBefore, sbAfter, 100 * (1 - sbAfter / sbBefore)))
        XCTAssertGreaterThanOrEqual(1 - saAfter / saBefore, 0.50, "D: σa 必须 ↓≥50%")
        XCTAssertGreaterThanOrEqual(1 - sbAfter / sbBefore, 0.50, "D: σb 必须 ↓≥50%")
    }

    // MARK: - E: a real colour is not washed out

    func testSaturatedColoursSurvive() throws {
        let graph = try makeGraph(saturatedPatches(), identity: "171-e")
        var edit = EditModel.neutral
        edit.effects.nonBayerColorNR = 100
        let before = try render(graph, .neutral)
        let after = try render(graph, edit)

        var ratios: [Double] = []
        for k in 0..<Self.patchColours.count {
            let (x0, x1, y0, y1) = patchRect(k)
            let c0 = meanChroma(before, x0: x0, x1: x1, y0: y0, y1: y1)
            let c1 = meanChroma(after, x0: x0, x1: x1, y0: y0, y1: y1)
            ratios.append(c1 / c0)
            print(String(format: "171 E · patch %d C %.4f → %.4f (%.1f%%)", k, c0, c1, 100 * c1 / c0))
        }
        let mean = ratios.reduce(0, +) / Double(ratios.count)
        print(String(format: "171 E · mean chroma retention %.1f%% (was 10%% before 171)", 100 * mean))
        XCTAssertGreaterThanOrEqual(mean, 0.95, "E: 6 个高饱和色块的 C 平均保留必须 ≥95%")
        XCTAssertGreaterThanOrEqual(ratios.min() ?? 0, 0.90, "E: 单个色块也不许掉到 90% 以下")
    }

    // MARK: - F: chroma-only leaves luma alone

    func testChromaOnlyHoldsEveryPixelLuma() throws {
        let graph = try makeGraph(chromaSpeckle(), identity: "171-f")
        var edit = EditModel.neutral
        edit.effects.nonBayerColorNR = 100
        let before = try render(graph, .neutral)
        let after = try render(graph, edit)
        let a = lumaCodes(before), b = lumaCodes(after)
        var maxDelta = 0.0, sum = 0.0
        for i in 0..<a.count { let d = abs(a[i] - b[i]); maxDelta = max(maxDelta, d); sum += d }
        print(String(format: "171 F · per-pixel |Δluma| max %.3f codes · mean %.3f codes",
                     maxDelta, sum / Double(a.count)))
        XCTAssertLessThanOrEqual(maxDelta, 1.0, "F: 去彩噪只改色度，亮度逐像素变化必须 ≤1 码")
    }

    // MARK: - 不变量

    /// Both sliders at 0 must leave the frame byte for byte — including the new grid path, which must
    /// not even be encoded.
    func testZeroAmountsKeepTheFrame() throws {
        let graph = try makeGraph(noisyStep(), identity: "171-zero")
        var edit = EditModel.neutral
        edit.effects.texture = 40
        edit.effects.clarity = 20
        let a = try render(graph, edit)
        edit.effects.nonBayerLuminanceNR = 0
        edit.effects.nonBayerColorNR = 0
        let b = try render(graph, edit)
        XCTAssertEqual(digest(a), digest(b), "两个滑杆 = 0 时像素必须逐字节不变")
        let c = try render(graph, .neutral)
        let d = try render(graph, .neutral)
        XCTAssertEqual(digest(c), digest(d), "决定性：同一文档两次渲染逐字节相同")
    }

    private func digest(_ image: DisplayImage) -> String {
        var hasher = Hasher()
        for v in image.rgba { hasher.combine(v.bitPattern) }
        return String(hasher.finalize())
    }
}
