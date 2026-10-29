import XCTest
import Metal
import PhotonsCore

/// 117 — 去雾 in the **scene-linear** domain (`Kernels/s1_9_dehaze.metal`), at the end of the linear
/// chain: `… .contrast → .dehaze → .vignette → .toneMap …`.
///
/// The operator is He/Sun/Tang's dark channel prior with the airlight **measured** from the dark
/// channel instead of assumed to be display white:
///
///     D(p) = min_c min_{q×q block} I_c         (dark channel, q = 4, linear Rec2020)
///     A    = clamp(max D, 1e-4, 8)             (He's brightest-dark-channel estimate)
///     t    = max(1 − ω·D, t0)                  (ω = 0.95, t0 = 0.1)
///     J    = (I − A·(1 − t)) / t                (the veil `I = tJ + A(1 − t)`, inverted)
///
/// What is pinned here:
///
///   1. **中性 = 零像素 + 阶段不存在**: `dehaze == 0` has no `.dehaze` link and no pass.
///   2. **去雾有效**: on a 0.4 uniform veil, RMS contrast ≥ 2×, dark-channel mean −50 %, and the
///      measured `A` within 10 % of the veil (read from the 1 × 1 texture via the test probe).
///   3. **HDR 参与且不失控**: `I = 0.3 / 1.5 / 4.0` patches all move, `J ≤ I/t0`, samples below `A`
///      darken and samples above `A` brighten, and no NaN/Inf appears.
///   4. **单调**: amount 0 → 50 → 100 moves the dark channel down monotonically and never increases
///      the fraction of 255 codes.
///   5. **行颜色**: the 去雾 row is `.linear` (scene-linear red).
///   6. **开销**: the three passes fit the frame budget (60 Mpx under `PHOTONS_BENCH=1`).
final class DehazeLinearTests: XCTestCase {

    private var benchmarks: Bool { ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" }

    private func makeGraph(_ image: LinearImage, identity: String = "dehaze-linear-tests") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func image(width: Int, height: Int,
                       _ value: (Int, Int) -> Double) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = value(x, y)
                let i = (y * width + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v); rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func flat(_ value: Double = 0.18, width: Int = 64, height: Int = 48) -> LinearImage {
        image(width: width, height: height) { _, _ in value }
    }

    /// A "landscape" with the property the dark channel prior needs — a wide bright region (J = 1, so
    /// a 0.4 veil leaves a block whose dark channel is the true airlight 1), a textured mid band, and a
    /// near-black band. The measured `A` is therefore the synthetic airlight, not a bright object.
    private func landscape(bright: Double = 1.0, width: Int = 750, height: Int = 500) -> LinearImage {
        image(width: width, height: height) { x, y in
            if y < height / 3 { return bright - 0.10 * Double(y) / Double(height / 3) }
            if y < 2 * height / 3 { return 0.20 + ((x / 4 + y / 4) % 2 == 0 ? 0.05 : -0.05) }
            return 0.01 + 0.02 * Double(x) / Double(width)
        }
    }

    /// `I = (1 − veil)·J + veil` in linear light: a uniform 0.4 additive veil.
    private func foggy(_ image: LinearImage, veil: Double = 0.4) -> LinearImage {
        var rgba = image.rgba
        for i in stride(from: 0, to: rgba.count, by: 4) {
            for c in 0..<3 { rgba[i + c] = Float16(Double(rgba[i + c]) * (1 - veil) + veil) }
        }
        return LinearImage(width: image.width, height: image.height, rgba: rgba,
                           colorSpace: image.colorSpace, decoderVersion: image.decoderVersion)
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel, headroom: Double = 1,
                        bitDepth: Int = 16, probeAirlight: Bool = false) throws -> DisplayImage {
        let options = RenderOptions(scale: 1,
                                    display: DisplayOptions(primaries: .sRGB, bitDepth: bitDepth,
                                                            headroom: headroom),
                                    useCache: false, wantsPixels: true,
                                    probesDehazeAirlight: probeAirlight)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    private func renderWithTrace(_ graph: RenderGraph, _ edit: EditModel) throws -> (DisplayImage, RenderTrace) {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return (try XCTUnwrap(result.display), result.trace)
    }

    // MARK: - measurement

    private func code(_ image: DisplayImage, _ x: Int, _ y: Int, _ c: Int = 0) -> Double {
        Double(image.rgba[(y * image.width + x) * 4 + c])
    }

    /// sRGB OETF inverse — the display image is what S4 wrote.
    private func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private func linearRGB(_ image: DisplayImage, _ x: Int, _ y: Int) -> (Double, Double, Double) {
        (linear(code(image, x, y, 0)), linear(code(image, x, y, 1)), linear(code(image, x, y, 2)))
    }

    /// **RMS contrast** `σ/µ` of linear luma.
    private func rmsContrast(_ image: DisplayImage) -> Double {
        var sum = 0.0, sum2 = 0.0
        var n = 0
        for y in stride(from: 0, to: image.height, by: 2) {
            for x in stride(from: 0, to: image.width, by: 2) {
                let r = linearRGB(image, x, y)
                let v = 0.2627 * r.0 + 0.6780 * r.1 + 0.0593 * r.2
                sum += v; sum2 += v * v; n += 1
            }
        }
        let m = sum / Double(n)
        return (sum2 / Double(n) - m * m).squareRoot() / m
    }

    /// Mean dark channel: `min` over channels, then a 15 × 15 window, in display codes. This is the
    /// measurement the old display-domain stage used, kept so the two domains are compared on one
    /// number ("how much veil is left").
    private func darkChannelMean(_ image: DisplayImage) -> Double {
        let w = image.width, h = image.height, r = 7
        var mins = [Double](repeating: 1, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                mins[y * w + x] = min(code(image, x, y, 0), code(image, x, y, 1), code(image, x, y, 2))
            }
        }
        var horiz = [Double](repeating: 1, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var m = 1.0
                for i in -r...r { m = min(m, mins[y * w + min(max(x + i, 0), w - 1)]) }
                horiz[y * w + x] = m
            }
        }
        var sum = 0.0
        var n = 0
        for y in stride(from: r, to: h - r, by: 3) {
            for x in stride(from: r, to: w - r, by: 3) {
                var m = 1.0
                for i in -r...r { m = min(m, horiz[min(max(y + i, 0), h - 1) * w + x]) }
                sum += m
                n += 1
            }
        }
        return sum / Double(max(n, 1))
    }

    /// Fraction of channels sitting at the 8-bit ceiling.
    private func whiteFraction(_ image: DisplayImage) -> Double {
        var white = 0
        var n = 0
        for i in stride(from: 0, to: image.rgba.count, by: 4) {
            for c in 0..<3 {
                if Double(image.rgba[i + c]) >= 255.0 / 255.0 { white += 1 }
                n += 1
            }
        }
        return Double(white) / Double(max(n, 1))
    }

    // MARK: - 1. 中性

    func testNeutralHasNoDehazeStageAndIsPixelIdentical() throws {
        let graph = try makeGraph(flat())
        let untouched = EditModel.neutral
        var explicit = untouched
        explicit.effects.dehaze = 0
        let roundTripped = try JSONDecoder().decode(EditModel.self, from: JSONEncoder().encode(untouched))

        let a = try render(graph, untouched)
        let b = try render(graph, explicit)
        let c = try render(graph, roundTripped)
        XCTAssertEqual(a.sha256(), b.sha256(), "显式写回 0 也必须零像素变化")
        XCTAssertEqual(a.sha256(), c.sha256(), "过一趟 JSON 也不能变")

        let links = RenderKeyChain.links(identity: "dehaze-linear-tests",
                                         sourceSize: ImageSize(width: a.width, height: a.height),
                                         canvas: ImageSize(width: a.width, height: a.height),
                                         content: ImageSize(width: a.width, height: a.height),
                                         edit: untouched,
                                         display: DisplayOptions(headroom: 1))
        XCTAssertNil(links.dehaze, "dehaze == 0 就没有 S1.9 链接 —— 不是「链接了但乘 0」")
        XCTAssertEqual(links.pipeline, RenderStage.allCases)
        XCTAssertEqual(links.pipeline.count, 7, "M1 的七段，一段不多")

        let (_, trace) = try renderWithTrace(graph, untouched)
        XCTAssertFalse(trace.executed.contains(.dehaze), "中性帧不许编码 S1.9")
        XCTAssertFalse(trace.skipped.contains(.dehaze), "阶段必须不存在，而不是编码后跳过")
        XCTAssertFalse(untouched.hasDehaze)
        XCTAssertFalse(untouched.renderInputs.key.contains("s1.9-dehaze"),
                       "中性文档的 renderInputs 键里也不许出现这一段")

        // The mount point: directly after S1.8 and before the vignette, which is before S2.
        let order = RenderStage.order
        XCTAssertEqual(order[try XCTUnwrap(order.firstIndex(of: .dehaze)) - 1], .contrast)
        XCTAssertEqual(order[try XCTUnwrap(order.firstIndex(of: .dehaze)) + 1], .vignette)
        XCTAssertEqual(order[try XCTUnwrap(order.firstIndex(of: .vignette)) + 1], .toneMap)
        XCTAssertEqual(RenderStage.dehaze.rawValue, "s1.9-dehaze")
        print("NEUTRAL · stages \(links.pipeline.count) · sha \(a.sha256().prefix(16))…")
    }

    // MARK: - 2. 去雾有效 (and the airlight is the veil)

    func testDehazeLiftsContrastDropsTheDarkChannelAndFindsTheAirlight() throws {
        let clean = landscape()
        let graph = try makeGraph(foggy(clean))
        var edit = EditModel.neutral
        edit.effects.dehaze = 100
        var negative = EditModel.neutral
        negative.effects.dehaze = -100

        let fogged = try render(graph, .neutral, headroom: 4)
        let cleared = try render(graph, edit, headroom: 4, probeAirlight: true)
        let measuredA = try XCTUnwrap(graph.lastDehazeAirlight)
        let hazier = try render(graph, negative, headroom: 4)

        let c0 = rmsContrast(fogged), c1 = rmsContrast(cleared)
        let d0 = darkChannelMean(fogged), d1 = darkChannelMean(cleared)
        let cleanGraph = try makeGraph(clean)
        let cClean = rmsContrast(try render(cleanGraph, .neutral, headroom: 4))

        print(String(format: "DEHAZE · 对比度(σ/µ) %.4f→%.4f (%.2fx) · 干净原图 %.4f · 暗通道 %.4f→%.4f (%+.1f%%) · A %.4f (合成 0.4) · 反向 −100 → %.4f",
                     c0, c1, c1 / c0, cClean, d0, d1, (d1 / d0 - 1) * 100, measuredA, rmsContrast(hazier)))

        XCTAssertGreaterThanOrEqual(c1 / c0, 2.0, String(format: "去雾 +100 的对比度必须 ≥ 2×（实测 %.2fx）", c1 / c0))
        XCTAssertLessThanOrEqual(d1 / d0, 0.5,
                                 String(format: "暗通道均值必须下降 ≥ 50 %%（实测 %+.1f %%）", (d1 / d0 - 1) * 100))
        XCTAssertEqual(measuredA, 1.0, accuracy: 0.1,
                       String(format: "估出的 A 必须与合成雾亮度 1.0 差 ≤ 10 %%（实测 %.4f）", measuredA))
        XCTAssertLessThan(abs(c1 / cClean - 1), 0.35,
                          String(format: "去雾后的对比度必须落回干净原图附近（实测 %.2fx 原图）", c1 / cClean))
        XCTAssertLessThan(rmsContrast(hazier), c0, "负值必须把雾加回来")
    }

    // MARK: - 3. HDR 参与且不失控

    func testHDRParticipatesWithoutBreakingThePhysicalBound() throws {
        // Three uniform patches with one 0.6 pinhole column per 4 px, so the measured airlight is 0.6
        // rather than the brightest patch (which would make `A > I` for every patch).
        let w = 64, h = 48
        let patches: [Double] = [0.3, 1.5, 4.0]
        let frame = image(width: w, height: h) { x, y in
            let band = min(y / (h / 3), 2)
            if x % 4 == 0 { return patches[band] < 0.6 ? 0.3 : 0.6 }
            return patches[band]
        }

        let graph = try makeGraph(frame)
        var edit = EditModel.neutral
        edit.effects.dehaze = 100
        let neutral = try render(graph, .neutral, headroom: 16)
        let out = try render(graph, edit, headroom: 16, probeAirlight: true)
        let A = try XCTUnwrap(graph.lastDehazeAirlight)
        XCTAssertEqual(A, 0.6, accuracy: 0.06, "测试帧的 A 应是 0.6（块最小值里的最大值）")

        // Sample a pixel that is *not* one of the 0.6 pinholes, away from band boundaries.
        let samples = [(1, 6), (1, 22), (1, 38)]
        var rows: [String] = []
        for (i, p) in samples.enumerated() {
            let (x, y) = p
            let before = linearRGB(neutral, x, y).0
            let after = linearRGB(out, x, y).0
            rows.append(String(format: "I=%.2f → %.3f (Δ%+.3f)", patches[i], after, after - before))
            XCTAssertGreaterThan(abs(after - before), 1e-3,
                                 "patch \(patches[i]) 必须被去雾改动（|Δ| > 1e-3）")
            XCTAssertLessThanOrEqual(after, before / 0.1 + 1e-6,
                                     "J ≤ I/t0（t0 = 0.1）是物理上界")
            if A < before {
                XCTAssertGreaterThan(after, before + 1e-6, "A < I 的样本必须变亮（从雾幕里恢复）")
            } else if A > before {
                XCTAssertLessThan(after, before - 1e-6, "A > I 的样本必须变暗（它是雾）")
            }
        }
        print("HDR · " + rows.joined(separator: " · ") + String(format: " · A %.3f", A))

        for y in 0..<h {
            for x in 0..<w {
                let c = linearRGB(out, x, y)
                XCTAssertTrue(c.0.isFinite && c.1.isFinite && c.2.isFinite,
                              "去雾不许产生 NaN/Inf（\(x),\(y)）")
            }
        }
    }

    // MARK: - 4. 单调

    func testAmountIsMonotonicAndDoesNotClipMore() throws {
        let graph = try makeGraph(foggy(landscape(bright: 1.0)))
        var half = EditModel.neutral
        half.effects.dehaze = 50
        var full = EditModel.neutral
        full.effects.dehaze = 100

        let zero = try render(graph, .neutral, bitDepth: 8)
        let fifty = try render(graph, half, bitDepth: 8)
        let hundred = try render(graph, full, bitDepth: 8)

        let d0 = darkChannelMean(zero), d50 = darkChannelMean(fifty), d100 = darkChannelMean(hundred)
        let w0 = whiteFraction(zero), w50 = whiteFraction(fifty), w100 = whiteFraction(hundred)
        print(String(format: "MONOTONIC · 暗通道 %.3f → %.3f → %.3f · 255 占比 %.4f → %.4f → %.4f",
                     d0, d50, d100, w0, w50, w100))
        XCTAssertLessThan(d50, d0, "amount 50 must lower the dark channel")
        XCTAssertLessThan(d100, d50, "amount 100 must lower it further")
        XCTAssertLessThanOrEqual(w50, w0 + 1e-9, "去雾不许把更多像素推到 255")
        XCTAssertLessThanOrEqual(w100, w0 + 1e-9, "…and 100 no more than 50")
    }

    // MARK: - 5. keys

    func testDehazeOwnsItsOwnLinkAndStage() {
        var e = EditModel.neutral
        e.effects.dehaze = 70
        XCTAssertTrue(e.hasDehaze)
        XCTAssertFalse(e.hasDetailFX, "117: 去雾不再是 S3.9 的一部分")
        XCTAssertEqual(e.changedStages(from: .neutral), [.dehaze])
        XCTAssertTrue(e.renderInputs.key.contains("s1.9-dehaze"))
        XCTAssertEqual(e.decodeInputs.key, EditModel.neutral.decodeInputs.key,
                       "去雾是渲染输入，不许触发重新解码")

        let size = ImageSize(width: 100, height: 100)
        func links(_ edit: EditModel) -> RenderKeyChain.Links {
            RenderKeyChain.links(identity: "dehaze", sourceSize: size, canvas: size, content: size,
                                 edit: edit, display: DisplayOptions(headroom: 1))
        }
        XCTAssertNil(links(.neutral).dehaze)
        XCTAssertNotNil(links(e).dehaze)
        XCTAssertEqual(links(e).pipeline.count, 8)
        XCTAssertTrue(links(e).pipeline.contains(.dehaze))
    }

    // MARK: - 6. 开销

    func testThreePassesStayInsideTheFrameBudget() throws {
        let width = benchmarks ? 6000 : 1500
        let height = benchmarks ? 10000 : 2731
        let graph = try makeGraph(flat(0.35, width: width, height: height))
        var edit = EditModel.neutral
        edit.effects.dehaze = 100
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: false)

        func best(_ model: EditModel) throws -> Double {
            func once() throws -> Double {
                let start = Date()
                let result = try graph.render(model, options: options)
                let ms = Date().timeIntervalSince(start) * 1000
                if let t = result.output { graph.recycle(output: t) }
                return ms
            }
            for _ in 0..<2 { _ = try once() }
            return try (0..<5).map { _ in try once() }.min() ?? 0
        }

        let neutral = try best(.neutral)
        let dehazed = try best(edit)
        let delta = dehazed - neutral
        print(String(format: "COST · %d×%d (%.2f Mpx) · neutral %.2f · 去雾 %.2f (+%.2f) ms%@",
                     width, height, Double(width * height) / 1e6, neutral, dehazed, delta,
                     benchmarks ? " [PHOTONS_BENCH]" : ""))
        // The three passes are one full-resolution apply and two 1/16-th-sized passes; the ceiling is
        // the same order S3.9's single chain has, with room for a shared machine.
        XCTAssertLessThan(delta, 40.0, "60 Mpx 去雾三 pass 必须 ≤ 40 ms（实测 \(delta) ms）")
    }
}
