import XCTest
import Metal
import PhotonsCore

/// 553 — 内置去噪（164「去噪」/ S3.9 联合双边网格）把 >1.0 的高光压到 1.0，且细节丢得厉害。
///
/// The two failures were both in the grid's **index domain**, not in the mixing strength:
///
///   · `s3_9_nr_splat` indexed z by the absolute luma and stored `clamp(L, 0, 1)`, so every pixel
///     above display white landed in the top bin as exactly 1.0. At `amount = 100` a 1.2 / 2.0 / 4.0
///     patch was replaced by 1.0. 553 normalises z and the stored luma by the picture's headroom
///     (the 320 ceiling) and indexes the 40 bins in log2, so each highlight keeps its own layer.
///   · the slice was added at full strength, and the grid is a wide low-pass (8 px cell, ±2 cells),
///     so `amount = 100` erased texture. 553 gates the correction on the grid's own residual: below
///     ~2σ it is noise and is averaged away, above it is structure and is kept.
///
/// The two acceptance tables below are both necessary. A "fix" that simply stops denoising passes
/// retention and fails σ; one that keeps the full low-pass passes σ and fails retention.
final class DenoiseS39Highlight553Tests: XCTestCase {

    private static let w = 800
    private static let h = 500

    // MARK: - plumbing

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// The test frames carry EDR light, so the panel has to be able to show it: headroom 6 is above
    /// the default 2^2.3 ceiling, i.e. S4 is not what would clip a 4.0 patch here.
    private func render(_ graph: RenderGraph, _ edit: EditModel,
                        headroom: Double = 6) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: headroom),
                                    useCache: false, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    private func image(_ rgba: [Float16], _ tag: String) -> LinearImage {
        LinearImage(width: Self.w, height: Self.h, rgba: rgba,
                    colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-553-\(tag)")
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

    // MARK: - measurement

    /// The sRGB OETF's inverse (S4's encode), including the linear segment.
    private func decode(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Linear Rec.709 luma per pixel — the quantity the grid's luma axis indexes and the one the
    /// ticket reports ("亮度大于 1.0").
    private func luma(_ image: DisplayImage) -> [Double] {
        var out = [Double](repeating: 0, count: image.width * image.height)
        for i in 0..<out.count {
            let b = i * 4
            let r = decode(max(Double(image.rgba[b]), 0))
            let g = decode(max(Double(image.rgba[b + 1]), 0))
            let bb = decode(max(Double(image.rgba[b + 2]), 0))
            out[i] = 0.2126 * r + 0.7152 * g + 0.0722 * bb
        }
        return out
    }

    private func regionMean(_ l: [Double], w: Int, x0: Int, x1: Int, y0: Int, y1: Int) -> Double {
        var sum = 0.0
        for y in y0..<y1 { for x in x0..<x1 { sum += l[y * w + x] } }
        return sum / Double((x1 - x0) * (y1 - y0))
    }

    private func highPassSigma(_ l: [Double], w: Int, h: Int,
                               x0: Int, x1: Int, y0: Int, y1: Int, radius: Int = 2) -> Double {
        func at(_ x: Int, _ y: Int) -> Double { l[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)] }
        var sum = 0.0, n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                var s = 0.0, c = 0
                for dy in -radius...radius {
                    for dx in -radius...radius { s += at(x + dx, y + dy); c += 1 }
                }
                let d = at(x, y) - s / Double(c)
                sum += d * d; n += 1
            }
        }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    private func laplacianRMS(_ l: [Double], w: Int, h: Int,
                              x0: Int, x1: Int, y0: Int, y1: Int) -> Double {
        func at(_ x: Int, _ y: Int) -> Double { l[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)] }
        var sum = 0.0, n = 0
        for y in max(y0, 1)..<min(y1, h - 1) {
            for x in max(x0, 1)..<min(x1, w - 1) {
                let lap = 4 * at(x, y) - at(x - 1, y) - at(x + 1, y) - at(x, y - 1) - at(x, y + 1)
                sum += lap * lap; n += 1
            }
        }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    private func digest(_ image: DisplayImage) -> String {
        var hasher = Hasher()
        for v in image.rgba { hasher.combine(v.bitPattern) }
        return String(hasher.finalize())
    }

    // MARK: - fixtures

    /// Five vertical bands, each 160 px wide and constant over the height:
    /// `L ∈ {0.5, 1.0, 1.2, 2.0, 4.0}`. The Δ between bands is several z bins (≈0.15 stop each), and
    /// every band is much wider than the grid's 8 px cell, so a band's centre is the band and not a
    /// boundary. A tiny ±0.01 noise keeps the frame from being a mathematical constant.
    private func highlightBands() -> LinearImage {
        let levels: [Double] = [0.5, 1.0, 1.2, 2.0, 4.0]
        let w = Self.w, h = Self.h, band = w / levels.count
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        var noise = Noise(0x553_0001)
        for y in 0..<h {
            for x in 0..<w {
                let k = min(x / band, levels.count - 1)
                let v = levels[k] + noise.symmetric(0.01)
                let i = (y * w + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v); rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        return image(rgba, "highlight-bands")
    }

    private func bandRect(_ k: Int) -> (Int, Int) {
        let band = Self.w / 5
        return (k * band + 48, (k + 1) * band - 48)
    }

    /// Left 60 %: flat 0.30 + ±0.02 noise → the σ measurement. Right 40 %: a 4 px checkerboard
    /// (±0.15) plus a 16 px sine (±0.10) + the same noise → the structure-retention measurement.
    /// The checker is deliberately **not** aligned with the 8 px grid cell, so the grid really does
    /// low-pass it and the gate has something to preserve.
    private func textureFixture() -> LinearImage {
        let w = Self.w, h = Self.h
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        var noise = Noise(0x553_0002)
        let split = 480
        for y in 0..<h {
            for x in 0..<w {
                var v = 0.30
                if x >= split {
                    let checker = ((x / 4 + y / 4) % 2 == 0 ? 0.15 : -0.15)
                    let sine = 0.10 * sin(2.0 * Double.pi * Double(x) / 16.0)
                        * sin(2.0 * Double.pi * Double(y) / 16.0)
                    v += checker + sine
                }
                v += noise.symmetric(0.02)
                let i = (y * w + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v); rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        return image(rgba, "texture")
    }

    // MARK: - 1. highlight table

    func testHighlightsAboveOneAreNotPulledDown() throws {
        let graph = try makeGraph(highlightBands(), identity: "553-highlights")
        let levels: [Double] = [0.5, 1.0, 1.2, 2.0, 4.0]
        let amounts: [Double] = [0, 25, 50, 75, 100]

        var edit = EditModel.neutral
        edit.effects.nonBayerLuminanceNR = 0
        let before = luma(try render(graph, edit))
        let w = Self.w

        print("553 · 高光表（中心线性亮度，amount → 每个区块）")
        for amount in amounts {
            edit.effects.nonBayerLuminanceNR = amount
            let after = luma(try render(graph, edit))
            var row: [String] = []
            for k in levels.indices {
                let (x0, x1) = bandRect(k)
                let b = regionMean(before, w: w, x0: x0, x1: x1, y0: 96, y1: Self.h - 96)
                let a = regionMean(after, w: w, x0: x0, x1: x1, y0: 96, y1: Self.h - 96)
                row.append(String(format: "L%.1f %.4f→%.4f (%+.2f%%)",
                                  levels[k], b, a, 100 * (a - b) / max(b, 1e-9)))
                if levels[k] > 1.0 {
                    // Both directions: a highlight may not be pulled down **and** the test may not
                    // be fooled by a compensating overshoot. 2 % is the ticket's bound.
                    XCTAssertLessThanOrEqual(abs(a - b) / b, 0.02,
                                             "amount \(amount)：L > 1.0 的区块 \(levels[k]) 不得被改动 >2%")
                    // "数量不减少" on the same pixels: nothing may cross below 1.0.
                    var nBefore = 0, nAfter = 0
                    for y in 96..<(Self.h - 96) {
                        for x in x0..<x1 {
                            if before[y * w + x] > 1.0 { nBefore += 1 }
                            if after[y * w + x] > 1.0 { nAfter += 1 }
                        }
                    }
                    XCTAssertGreaterThanOrEqual(nAfter, nBefore,
                                                "amount \(amount)：L > 1.0 的像素不得减少")
                }
            }
            print("553 · amount \(Int(amount)) · " + row.joined(separator: " · "))
        }
    }

    // MARK: - 2 + 3. texture retention and flat noise, one render

    func testDetailIsKeptWhileFlatNoiseFalls() throws {
        let graph = try makeGraph(textureFixture(), identity: "553-texture")
        var neutral = EditModel.neutral
        neutral.effects.nonBayerLuminanceNR = 0
        var edit = EditModel.neutral
        edit.effects.nonBayerLuminanceNR = 100

        let before = luma(try render(graph, neutral, headroom: 1))
        let after = luma(try render(graph, edit, headroom: 1))
        let w = Self.w, h = Self.h

        // σ on the flat left block, away from the split and the frame border.
        let sigmaBefore = highPassSigma(before, w: w, h: h, x0: 8, x1: 440, y0: 8, y1: h - 8)
        let sigmaAfter = highPassSigma(after, w: w, h: h, x0: 8, x1: 440, y0: 8, y1: h - 8)
        let reduction = 1 - sigmaAfter / sigmaBefore
        print(String(format: "553 · 平坦区 σ %.5f → %.5f (↓%.1f%%)",
                     sigmaBefore, sigmaAfter, 100 * reduction))

        // Laplacian RMS on the textured right block: checker + sine, away from the split.
        let lapBefore = laplacianRMS(before, w: w, h: h, x0: 504, x1: w - 8, y0: 8, y1: h - 8)
        let lapAfter = laplacianRMS(after, w: w, h: h, x0: 504, x1: w - 8, y0: 8, y1: h - 8)
        let retention = lapAfter / lapBefore
        print(String(format: "553 · 纹理 Laplacian RMS %.4f → %.4f (保留 %.1f%%)",
                     lapBefore, lapAfter, 100 * retention))

        XCTAssertGreaterThanOrEqual(retention, 0.90, "amount 100：纹理结构保留必须 ≥90%")
        XCTAssertGreaterThanOrEqual(reduction, 0.50, "amount 100：平坦区 σ 必须 ↓≥50%")
    }

    // MARK: - 4. the pre-553 frame is untouched

    func testAmountZeroIsTheNeutralFrame() throws {
        let graph = try makeGraph(highlightBands(), identity: "553-zero")
        var edit = EditModel.neutral
        edit.effects.nonBayerLuminanceNR = 0
        let zero = try render(graph, edit)
        let neutral = try render(graph, .neutral)
        XCTAssertEqual(digest(zero), digest(neutral), "去噪 = 0 时像素必须逐字节不变")
        // Determinism: the same document twice is the same frame.
        XCTAssertEqual(digest(try render(graph, edit)), digest(zero))
    }
}
