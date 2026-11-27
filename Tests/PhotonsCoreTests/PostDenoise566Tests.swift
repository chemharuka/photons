import XCTest
import Metal
@testable import PhotonsCore

/// 566-A — the scene-linear GMW denoiser that replaced S3.9's joint-bilateral NR branch.
///
/// These tests go through the shipped graph and Metal kernels. They pin the contract the ticket
/// states, not a CPU re-implementation:
///
///   1. the resting document is **50 / 50** (k = 2 / k_c = 1.5), and an absent key reads as 50 while
///      an explicit 0 stays 0 and is written back;
///   2. `0 / 0` is the pre-566 frame: no S1.5 pass, no `gmw=` key token, no S3.9 NR pass;
///   3. flat-region high-pass noise falls while a step edge does not widen;
///   4. a neutral frame keeps its luma code (the chroma stage must not divide by a zero variance);
///   5. an extremely dark (σ = 0) frame is a verbatim no-op — finite, not black;
///   6. the two strengths ride the linear curve link, not S3.9's material;
///   7. the corrected §9.2 split holds: low-frequency chroma (colour) survives, high-frequency
///      chroma (noise) falls, and a window's first frame is already the whole-frame crop.
final class PostDenoise566Tests: XCTestCase {

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

    private struct Noise {
        var seed: UInt32
        init(_ s: UInt32) { seed = s }
        mutating func next() -> Double {
            seed = seed &* 1664525 &+ 1013904223
            return Double(seed >> 8) / Double(1 << 24)
        }
        mutating func symmetric(_ amplitude: Double) -> Double { (next() - 0.5) * 2 * amplitude }
    }

    /// Left half: a noisy flat field. Right half: one horizontal step (top vs bottom), so the
    /// row-mean profile has a 10–90 % crossing to measure.
    private func noisyStep(w: Int = 320, h: Int = 240) -> LinearImage {
        var rng = Noise(0x566)
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let base: Double = x < w / 2 ? 0.14 : (y < h / 2 ? 0.06 : 0.42)
                let v = base + rng.symmetric(0.03)
                let i = (y * w + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v); rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-566")
    }

    private func flat(_ value: Float = 0.18, w: Int = 96, h: Int = 64) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        let v = Float16(value)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = v; rgba[i + 1] = v; rgba[i + 2] = v; rgba[i + 3] = 1
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-566-flat")
    }

    private func lumaCodes(_ image: DisplayImage) -> [Double] {
        var out = [Double](repeating: 0, count: image.width * image.height)
        for i in 0..<out.count {
            let b = i * 4
            out[i] = 255 * (0.2126 * Double(image.rgba[b]) + 0.7152 * Double(image.rgba[b + 1])
                            + 0.0722 * Double(image.rgba[b + 2]))
        }
        return out
    }

    private func highPassSigma(_ luma: [Double], w: Int, h: Int,
                               x0: Int, x1: Int, y0: Int, y1: Int, radius: Int = 2) -> Double {
        func at(_ x: Int, _ y: Int) -> Double { luma[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)] }
        var sum = 0.0
        var n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                var mean = 0.0
                var c = 0
                for dy in -radius...radius {
                    for dx in -radius...radius { mean += at(x + dx, y + dy); c += 1 }
                }
                let d = at(x, y) - mean / Double(c)
                sum += d * d
                n += 1
            }
        }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    /// Row-mean step width 10 %→90 %, in pixels, over the right half where the step lives.
    private func edgeWidth(_ image: DisplayImage) -> Double {
        let luma = lumaCodes(image)
        let w = image.width
        var profile = [Double](repeating: 0, count: image.height)
        for y in 0..<image.height {
            var s = 0.0
            for x in (w / 2 + 12)..<(w - 12) { s += luma[y * w + x] }
            profile[y] = s / Double(w - 24 - w / 2)
        }
        let lo = profile.prefix(image.height / 4).reduce(.greatestFiniteMagnitude, min)
        let hi = profile.suffix(image.height / 4).reduce(-.greatestFiniteMagnitude, max)
        func crossing(_ t: Double) -> Double {
            for y in 1..<image.height where profile[y] >= t {
                let a = profile[y - 1], b = profile[y]
                return Double(y - 1) + (b == a ? 0 : (t - a) / (b - a))
            }
            return Double(image.height)
        }
        return crossing(lo + 0.9 * (hi - lo)) - crossing(lo + 0.1 * (hi - lo))
    }

    /// A plain document with both denoises at an explicit value (the resting 50 is not the baseline
    /// these measurements start from).
    private func document(_ nr: Double, _ cnr: Double) -> EditModel {
        var e = EditModel.neutral
        e.sharpen = SharpenGroup(amount: 0)
        e.effects.nonBayerLuminanceNR = nr
        e.effects.nonBayerColorNR = cnr
        return e
    }

    // MARK: - defaults and the key

    func testTheRestingDocumentIsFiftyFifty() throws {
        XCTAssertEqual(EditModel.neutral.effects.nonBayerLuminanceNR, 50)
        XCTAssertEqual(EditModel.neutral.effects.nonBayerColorNR, 50)
        XCTAssertFalse(EditModel.neutral.hasDetailFX, "S3.9 must not exist for a 50/50 document")

        // The resting value is not written: an absent key is what makes an old document read 50.
        let json = String(decoding: try JSONEncoder().encode(EditModel.neutral), as: UTF8.self)
        XCTAssertFalse(json.contains("nonBayerLuminanceNR"), "resting value must not be written")
        XCTAssertFalse(json.contains("nonBayerColorNR"), "resting value must not be written")

        // An explicit 0 is the user's own off and must survive a round trip.
        let off = document(0, 0)
        let offData = try JSONEncoder().encode(off)
        let offJSON = String(decoding: offData, as: UTF8.self)
        XCTAssertTrue(offJSON.contains("\"nonBayerLuminanceNR\":0"))
        XCTAssertTrue(offJSON.contains("\"nonBayerColorNR\":0"))
        let decoded = try JSONDecoder().decode(EditModel.self, from: offData)
        XCTAssertEqual(decoded.effects.nonBayerLuminanceNR, 0)
        XCTAssertEqual(decoded.effects.nonBayerColorNR, 0)

        // A pre-566 document has no key at all: it must read the new resting value.
        let old = try JSONDecoder().decode(EditModel.self, from: Data("{}".utf8))
        XCTAssertEqual(old.effects.nonBayerLuminanceNR, 50)
        XCTAssertEqual(old.effects.nonBayerColorNR, 50)
    }

    func testTheStrengthRidesTheCurveLinkNotS39() throws {
        let a = document(50, 50)
        let b = document(80, 20)
        XCTAssertNotEqual(a.keyMaterial(.curve), b.keyMaterial(.curve),
                          "S1.5 material must move the curve link")
        XCTAssertEqual(a.keyMaterial(.detailFX), b.keyMaterial(.detailFX),
                       "S3.9 reads neither denoise any more")
        XCTAssertTrue(a.keyMaterial(.curve).contains("gmw="))
        XCTAssertFalse(document(0, 0).keyMaterial(.curve).contains("gmw="),
                       "the explicit 0/0 pair must keep the pre-566 chain")
    }

    // MARK: - identity

    func testZeroZeroIsThePre566FrameAndEncodesNoS15Pass() throws {
        let image = noisyStep()
        let graph = try makeGraph(image, identity: "566-zero")
        let zero = document(0, 0)
        let once = try render(graph, zero)
        let twice = try render(graph, zero)
        XCTAssertEqual(once.sha256(), twice.sha256(), "deterministic")
        XCTAssertFalse(zero.keyMaterial(.curve).contains("gmw="))
        XCTAssertTrue(once.rgba.allSatisfy { $0.isFinite })
    }

    // MARK: - the measurement the design promises

    func testFlatNoiseFallsAndTheEdgeDoesNotWiden() throws {
        let image = noisyStep()
        let graph = try makeGraph(image, identity: "566-ab")
        let before = try render(graph, document(0, 0))
        let after = try render(graph, document(50, 0))

        let w = before.width, h = before.height
        let lb = lumaCodes(before), la = lumaCodes(after)
        let (x0, x1, y0, y1) = (8, w / 2 - 8, 8, h - 8)
        let sb = highPassSigma(lb, w: w, h: h, x0: x0, x1: x1, y0: y0, y1: y1)
        let sa = highPassSigma(la, w: w, h: h, x0: x0, x1: x1, y0: y0, y1: y1)
        print(String(format: "566 · flat high-pass σ %.3f → %.3f codes (↓%.1f%%)",
                     sb, sa, 100 * (1 - sa / max(sb, 1e-9))))
        XCTAssertLessThanOrEqual(sa, 0.80 * sb, "flat luma noise must fall ≥20% at k=2")

        // The same fixture's horizontal step: the flatness gate must not turn it into a blur.
        let wb = edgeWidth(before)
        let wa = edgeWidth(after)
        print(String(format: "566 · step 10–90 %% width %.2f → %.2f px (%.2f×)", wb, wa, wa / wb))
        XCTAssertLessThanOrEqual(wa, 1.25 * wb, "the flatness gate must keep the edge")
    }

    func testANeutralFrameKeepsItsMean() throws {
        let graph = try makeGraph(flat(0.42), identity: "566-neutral")
        let off = try render(graph, document(0, 0))
        let on = try render(graph, document(50, 50))
        let a = lumaCodes(off), b = lumaCodes(on)
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        print(String(format: "566 · neutral flat mean %.2f → %.2f codes", ma, mb))
        XCTAssertEqual(ma, mb, accuracy: 0.5,
                       "a grey card must stay the same grey; the chroma stage may not shift luma")
    }

    // MARK: - strength from off to the resting/default positions

    /// Flat mid-grey with independent per-channel perturbation: nearly all of it is chroma.
    private func chromaSpeckle() -> LinearImage {
        let w = 400, h = 300
        var rng = Noise(0xBEEF01)
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let base = 0.35
            rgba[i] = Float16(base + rng.symmetric(0.055))
            rgba[i + 1] = Float16(base + rng.symmetric(0.055))
            rgba[i + 2] = Float16(base + rng.symmetric(0.055))
            rgba[i + 3] = 1
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-566-chroma")
    }

    /// OKLab (a, b), the chroma axes the color control is defined on.
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

    private func chromaSigma(_ ab: [(Double, Double)], w: Int, h: Int,
                             _ pick: ((Double, Double)) -> Double) -> Double {
        var s = 0.0, ss = 0.0
        var n = 0
        for y in 8..<(h - 8) {
            for x in 8..<(w - 8) {
                let v = pick(ab[y * w + x])
                s += v; ss += v * v; n += 1
            }
        }
        let m = s / Double(n)
        return (ss / Double(n) - m * m).squareRoot()
    }

    /// Box low-pass over one scalar plane (interior only; edges clamp like the shader's sampler).
    /// Separable, so the 8-px radius costs O(N·r) rather than O(N·r²) in a test body.
    private func lowPass(_ v: [Double], w: Int, h: Int, radius: Int) -> [Double] {
        var horizontal = [Double](repeating: 0, count: v.count)
        let n = Double(2 * radius + 1)
        for y in 0..<h {
            let base = y * w
            for x in 0..<w {
                var sum = 0.0
                for dx in -radius...radius {
                    sum += v[base + min(max(x + dx, 0), w - 1)]
                }
                horizontal[base + x] = sum / n
            }
        }
        var out = [Double](repeating: 0, count: v.count)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0.0
                for dy in -radius...radius {
                    sum += horizontal[min(max(y + dy, 0), h - 1) * w + x]
                }
                out[y * w + x] = sum / n
            }
        }
        return out
    }

    /// RMS of the residual `v − box(v)`, the "high-frequency chroma" of §9.2. The 8-px box is the
    /// discrete stand-in for the metric's `σ = 8` blur.
    private func highPassSigma(_ v: [Double], w: Int, h: Int, radius: Int = 8) -> Double {
        let low = lowPass(v, w: w, h: h, radius: radius)
        var s = 0.0, n = 0
        for y in radius..<(h - radius) {
            for x in radius..<(w - radius) {
                let d = v[y * w + x] - low[y * w + x]
                s += d * d; n += 1
            }
        }
        return (s / Double(max(n, 1))).squareRoot()
    }

    private func meanAbs(_ v: [Double], w: Int, h: Int, margin: Int) -> Double {
        var s = 0.0, n = 0
        for y in margin..<(h - margin) {
            for x in margin..<(w - margin) { s += abs(v[y * w + x]); n += 1 }
        }
        return s / Double(max(n, 1))
    }

    /// The four quadrant interiors of the colour fixture, with a `seam` margin off each block edge
    /// so the sharp block boundaries are not counted as "high-frequency noise".
    private func quadrants(w: Int, h: Int, seam: Int) -> [(x0: Int, x1: Int, y0: Int, y1: Int)] {
        [(seam, w / 2 - seam, seam, h / 2 - seam),
         (w / 2 + seam, w - seam, seam, h / 2 - seam),
         (seam, w / 2 - seam, h / 2 + seam, h - seam),
         (w / 2 + seam, w - seam, h / 2 + seam, h - seam)]
    }

    private func meanAbs(_ v: [Double], w: Int, h: Int,
                         rects: [(x0: Int, x1: Int, y0: Int, y1: Int)]) -> Double {
        var s = 0.0, n = 0
        for r in rects {
            for y in r.y0..<r.y1 {
                for x in r.x0..<r.x1 { s += abs(v[y * w + x]); n += 1 }
            }
        }
        return s / Double(max(n, 1))
    }

    private func highPassSigma(_ v: [Double], w: Int, h: Int,
                               rects: [(x0: Int, x1: Int, y0: Int, y1: Int)],
                               radius: Int = 8) -> Double {
        let low = lowPass(v, w: w, h: h, radius: radius)
        var s = 0.0, n = 0
        for r in rects {
            for y in r.y0..<r.y1 {
                for x in r.x0..<r.x1 {
                    let d = v[y * w + x] - low[y * w + x]
                    s += d * d; n += 1
                }
            }
        }
        return (s / Double(max(n, 1))).squareRoot()
    }

    func testChromaNoiseFallsFromOffToTheRestingStrength() throws {
        let graph = try makeGraph(chromaSpeckle(), identity: "566-chroma-strength")
        let off = try render(graph, document(0, 0))
        let resting = try render(graph, document(0, 50))
        let full = try render(graph, document(0, 100))

        let w = off.width, h = off.height
        let abOff = oklabAB(off), abRest = oklabAB(resting), abFull = oklabAB(full)
        let a0 = abOff.map { $0.0 }, b0 = abOff.map { $0.1 }
        for (name, ab) in [("50", abRest), ("100", abFull)] {
            let a = ab.map { $0.0 }, b = ab.map { $0.1 }
            let ha0 = highPassSigma(a0, w: w, h: h), hb0 = highPassSigma(b0, w: w, h: h)
            let ha = highPassSigma(a, w: w, h: h), hb = highPassSigma(b, w: w, h: h)
            print(String(format: "566 · chroma %@: HF σa %.4f → %.4f (↓%.1f%%) · HF σb %.4f → %.4f (↓%.1f%%)",
                         name, ha0, ha, 100 * (1 - ha / ha0), hb0, hb, 100 * (1 - hb / hb0)))
        }
        let ha0 = highPassSigma(a0, w: w, h: h), hb0 = highPassSigma(b0, w: w, h: h)
        let ha1 = highPassSigma(abFull.map { $0.0 }, w: w, h: h)
        let hb1 = highPassSigma(abFull.map { $0.1 }, w: w, h: h)
        XCTAssertGreaterThanOrEqual(1 - ha1 / ha0, 0.50, "chroma HF σa must fall ≥50% at amount 100")
        XCTAssertGreaterThanOrEqual(1 - hb1 / hb0, 0.50, "chroma HF σb must fall ≥50% at amount 100")
    }

    /// 566-A §9.2 — the corrected split: low-frequency chroma is **colour** and must survive, while
    /// high-frequency chroma is **noise** and must fall. Four flat colour quadrants make both halves
    /// of the measurement honest (the speckle fixture above has no low-frequency colour at all).
    private func colouredBlocks(w: Int = 400, h: Int = 300) -> LinearImage {
        let bases: [(Double, Double, Double)] = [
            (0.42, 0.15, 0.10), (0.10, 0.33, 0.14),
            (0.08, 0.16, 0.40), (0.45, 0.36, 0.07),
        ]
        var rng = Noise(0xC01_0BEEF)
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let q = (y < h / 2 ? 0 : 2) + (x < w / 2 ? 0 : 1)
                let c = bases[q]
                let i = (y * w + x) * 4
                rgba[i] = Float16(c.0 + rng.symmetric(0.02))
                rgba[i + 1] = Float16(c.1 + rng.symmetric(0.02))
                rgba[i + 2] = Float16(c.2 + rng.symmetric(0.02))
                rgba[i + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-566-colour")
    }

    func testColourSurvivesWhenTheChromaNoiseFalls() throws {
        let graph = try makeGraph(colouredBlocks(), identity: "566-colour")
        let off = try render(graph, document(0, 0))
        let on = try render(graph, document(0, 50))
        let w = off.width, h = off.height
        let abOff = oklabAB(off), abOn = oklabAB(on)
        let rects = quadrants(w: w, h: h, seam: 24)
        for (axis, pick) in [("a", { (p: (Double, Double)) in p.0 }),
                             ("b", { (p: (Double, Double)) in p.1 })] {
            let o = abOff.map(pick), n = abOn.map(pick)
            let low = lowPass(o, w: w, h: h, radius: 8)
            // `n` is the filtered frame; compare its low-pass, not its own pixel values.
            let lowOn = lowPass(n, w: w, h: h, radius: 8)
            let kept = meanAbs(lowOn, w: w, h: h, rects: rects)
                / max(meanAbs(low, w: w, h: h, rects: rects), 1e-9)
            let hf0 = highPassSigma(o, w: w, h: h, rects: rects)
            let hf1 = highPassSigma(n, w: w, h: h, rects: rects)
            print(String(format: "566 · colour-%@: low-freq %.1f %% kept · HF chroma %.1f %% of off",
                         axis, 100 * kept, 100 * hf1 / hf0))
            XCTAssertGreaterThanOrEqual(kept, 0.95, "色度低频（颜色）必须保留 ≥95 % — axis \(axis)")
            XCTAssertLessThanOrEqual(hf1 / hf0, 0.60, "色度高频率（色噪）必须 ≤60 % — axis \(axis)")
        }
    }

    /// 4-px checkerboard at ±0.05 on 0.20 plus the same noise: a texture the Wiener must not eat.
    private func noisyChecker(w: Int = 750, h: Int = 500) -> LinearImage {
        var rng = Noise(0x1234567)
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = 0.20 + ((x / 4 + y / 4) % 2 == 0 ? 0.05 : -0.05)
                    + rng.symmetric(0.04)
                let i = (y * w + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v); rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-566-checker")
    }

    private func laplacianRMS(_ luma: [Double], w: Int, h: Int,
                              x0: Int, x1: Int, y0: Int, y1: Int) -> Double {
        func at(_ x: Int, _ y: Int) -> Double { luma[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)] }
        var sum = 0.0
        var n = 0
        for y in max(y0, 1)..<min(y1, h - 1) {
            for x in max(x0, 1)..<min(x1, w - 1) {
                let lap = 4 * at(x, y) - at(x - 1, y) - at(x + 1, y) - at(x, y - 1) - at(x, y + 1)
                sum += lap * lap; n += 1
            }
        }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    func testTextureSurvivesTheRestingStrength() throws {
        let graph = try makeGraph(noisyChecker(), identity: "566-texture-strength")
        let off = try render(graph, document(0, 0))
        let resting = try render(graph, document(50, 0))
        let w = off.width, h = off.height
        let (x0, x1, y0, y1) = (16, w - 16, 16, h - 16)
        let lapOff = laplacianRMS(lumaCodes(off), w: w, h: h, x0: x0, x1: x1, y0: y0, y1: y1)
        let lapOn = laplacianRMS(lumaCodes(resting), w: w, h: h, x0: x0, x1: x1, y0: y0, y1: y1)
        print(String(format: "566 · texture Laplacian RMS %.2f → %.2f codes (retained %.1f%%)",
                     lapOff, lapOn, 100 * lapOn / lapOff))
        XCTAssertGreaterThanOrEqual(lapOn / lapOff, 0.60,
                                    "the resting strength must keep ≥60% of the texture")
    }

    // MARK: - §8.2: a window never stays un-denoised

    func testAWindowFirstDrawsTheWholeFrameCropAndNotTheRawChain() throws {
        let image = noisyStep(w: 768, h: 576)
        let graph = try makeGraph(image, identity: "566-window")
        let on = document(50, 50)
        let win = ImageRect(x: 224, y: 176, width: 160, height: 112)
        func render(_ edit: EditModel, canvas: ImageSize?, window: ImageRect?) throws -> DisplayImage {
            var options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                        useCache: true, wantsPixels: true)
            options.canvas = canvas
            options.outputWindow = window
            let result = try graph.render(edit, options: options)
            if let t = result.output { graph.recycle(output: t) }
            return try XCTUnwrap(result.display)
        }

        // Window **first** on a fresh graph: no memo exists yet, so this is the §8.2 miss path. It
        // must still draw the denoised crop, never the raw linear chain.
        let window = try render(on, canvas: ImageSize(width: win.width, height: win.height),
                                window: win)
        // The whole frame at the same scale fills the cache, and its crop is the contract.
        let whole = try render(on, canvas: ImageSize(width: image.width, height: image.height),
                               window: nil)
        var worst = 0.0
        for y in 0..<win.height {
            for x in 0..<win.width {
                let a = ((y + win.y) * whole.width + (x + win.x)) * 4
                let b = (y * window.width + x) * 4
                for c in 0..<4 {
                    worst = max(worst, abs(Double(window.rgba[b + c]) - Double(whole.rgba[a + c])))
                }
            }
        }
        print(String(format: "566 · window vs whole crop worst Δ %.2e", worst))
        XCTAssertLessThanOrEqual(worst, 2.0 / 65535.0,
                                 "a window must be the whole-frame result cut out (≤1 LSB)")

        // And it really is denoised: a 0/0 window (no S1.5 at all) has the fixture's full grain.
        let raw = try render(document(0, 0),
                             canvas: ImageSize(width: win.width, height: win.height), window: win)
        let w = window.width, h = window.height
        let (x0, x1, y0, y1) = (8, w - 8, 8, h - 8)
        let sigmaWindow = highPassSigma(lumaCodes(window), w: w, h: h, x0: x0, x1: x1, y0: y0, y1: y1)
        let sigmaRaw = highPassSigma(lumaCodes(raw), w: w, h: h, x0: x0, x1: x1, y0: y0, y1: y1)
        print(String(format: "566 · window flat grain %.3f → %.3f codes (↓%.1f%%)",
                     sigmaRaw, sigmaWindow, 100 * (1 - sigmaWindow / max(sigmaRaw, 1e-9))))
        XCTAssertLessThanOrEqual(sigmaWindow, 0.90 * sigmaRaw,
                                 "the first window frame must already carry S1.5's denoise")
    }

    // MARK: - the dark-frame robustness rule

    func testADarkFrameIsANoOpAndNeverNaN() throws {
        let image = flat(0.0)
        let graph = try makeGraph(image, identity: "566-dark")
        let off = try render(graph, document(0, 0))
        let on = try render(graph, document(50, 50))
        XCTAssertTrue(on.rgba.allSatisfy { $0.isFinite })
        XCTAssertEqual(on.sha256(), off.sha256(),
                       "σ = 0 must copy the frame verbatim, not invent a black level")
    }
}
