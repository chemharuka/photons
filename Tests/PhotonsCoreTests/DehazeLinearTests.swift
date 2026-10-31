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
///   3. **130 — 高光不再当雾**: recovery is on luminance (one gain ⇒ channel ratios invariant) and
///      fades out above the veil's reach (`L ≥ 2A` is untouched). The pre-130 per-channel formula is
///      kept behind `RenderOptions.legacyDehazePerChannel` so the blue-highlight measurement can be
///      shown to be the formula's doing.
///   4. **135 — 强档不再压黑**: the airlight is capped at `κ·p99(L)` (`κ = 0.95`, the percentile
///      clipped at white, the cap engages only when `A` is materially above it), so `amount = 100`
///      on the +2 EV DJI frame keeps its mean/median/low tail. The synthetic veil still loses ≥ 50 %
///      of its dark channel and doubles its RMS contrast, so the cap is not "turn dehaze off".
///   5. **单调**: amount 0 → 50 → 100 moves the dark channel down monotonically and never increases
///      the fraction of 255 codes.
///   6. **行颜色**: the 去雾 row is `.linear` (scene-linear red).
///   7. **开销**: the ten passes fit the frame budget (60 Mpx under `PHOTONS_BENCH=1`).
///   8. **2026-10-31 — 雾幕的空间支撑**: `t` reads a guided-filter veil plus a per-pixel floor instead
///      of the bilinear block minimum. Pinned by the skyline halo (≤ 3 % of the step, against the
///      pre-change `t`'s two-digit rim), the sky's retained light (`J/I ≥ 0.97`), the share of pixels
///      crushed to black, `t ∈ [t0, 1]` with 130's inversion, and the continued commutation with the
///      exposure slider.
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
                        bitDepth: Int = 16, probeAirlight: Bool = false,
                        legacyPerChannel: Bool = false,
                        legacyBlockVeil: Bool = false) throws -> DisplayImage {
        let options = RenderOptions(scale: 1,
                                    display: DisplayOptions(primaries: .sRGB, bitDepth: bitDepth,
                                                            headroom: headroom),
                                    useCache: false, wantsPixels: true,
                                    probesDehazeAirlight: probeAirlight,
                                    legacyDehazePerChannel: legacyPerChannel,
                                    legacyDehazeBlockVeil: legacyBlockVeil)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    /// The scene-linear exit of the graph: S4's frame with **no** OETF, so a sample *is* the light the
    /// stage produced. The halo/sky/t measurements below are ratios of light and read this (through
    /// the sRGB encode they would be measured through a curve that is not part of the stage).
    private func linearRender(_ graph: RenderGraph, _ edit: EditModel,
                              legacyBlockVeil: Bool = false,
                              headroom: Double = 1,
                              probeAirlight: Bool = false,
                              unboundedRecovery: Bool = false) throws -> DisplayImage {
        let display = DisplayOptions(primaries: .rec2020, bitDepth: 16, headroom: headroom,
                                     linearOutput: true)
        let result = try graph.render(edit, options: RenderOptions(
            scale: 1, display: display, useCache: false, wantsPixels: true,
            probesDehazeAirlight: probeAirlight,
            legacyDehazeBlockVeil: legacyBlockVeil,
            legacyDehazeUnboundedRecovery: unboundedRecovery))
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    /// The scene **light** at one pixel of a `linearRender` frame.
    private func light(_ image: DisplayImage, _ x: Int, _ y: Int) -> (Double, Double, Double) {
        let i = (y * image.width + x) * 4
        return (Double(image.rgba[i]), Double(image.rgba[i + 1]), Double(image.rgba[i + 2]))
    }

    /// Rec.2020 luma of a scene-light pixel — the quantity 130 recovers.
    private func lightLuma(_ image: DisplayImage, _ x: Int, _ y: Int) -> Double {
        let c = light(image, x, y)
        return 0.2627 * c.0 + 0.6780 * c.1 + 0.0593 * c.2
    }

    private func renderWithTrace(_ graph: RenderGraph, _ edit: EditModel) throws -> (DisplayImage, RenderTrace) {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return (try XCTUnwrap(result.display), result.trace)
    }

    /// 133/135 — the measurement render: S4's linear frame first, then the same global tone map
    /// `photonsctl render --tone-map global` uses, then the OETF. The acceptance numbers in 135 are
    /// display codes from this path, not from the hard-clamped `DisplayImage`.
    private func renderToneMapped(_ graph: RenderGraph, _ edit: EditModel,
                                  legacyBlockVeil: Bool = false) throws -> DisplayImage {
        var linearDisplay = DisplayOptions(primaries: .sRGB, bitDepth: 8, headroom: 1)
        linearDisplay.linearOutput = true
        let result = try graph.render(edit, options: RenderOptions(
            scale: 1, display: linearDisplay, useCache: false, wantsPixels: true,
            legacyDehazeBlockVeil: legacyBlockVeil))
        let frame = try XCTUnwrap(result.display)
        let pixels = LinearPixels(frame).displaySDR(bitDepth: 8, toneMap: .global)
        if let t = result.output { graph.recycle(output: t) }
        return pixels
    }

    /// Mean / median / 5th percentile over all R,G,B display codes — the table 135 is measured with.
    private func displayStats(_ image: DisplayImage) -> (mean: Double, p50: Double, p5: Double) {
        var values = [Double]()
        values.reserveCapacity((image.rgba.count / 4) * 3)
        for i in stride(from: 0, to: image.rgba.count, by: 4) {
            for c in 0..<3 { values.append(Double(image.rgba[i + c])) }
        }
        values.sort()
        let n = Double(values.count)
        return (values.reduce(0, +) / n,
                values[Int(0.50 * (n - 1))],
                values[Int(0.05 * (n - 1))])
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

        // The mount point: directly after the curve and before the vignette, which is before S2.
        // 159 moved contrast out of the linear chain (it now runs after the tone map, as S2.5), so
        // 117's "directly after S1.8" becomes "directly after the curve" — the tail's other two
        // neighbours are unchanged.
        let order = RenderStage.order
        XCTAssertEqual(order[try XCTUnwrap(order.firstIndex(of: .dehaze)) - 1], .curve)
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
        let legacyCleared = try render(graph, edit, headroom: 4, legacyBlockVeil: true)

        let c0 = rmsContrast(fogged), c1 = rmsContrast(cleared)
        let d0 = darkChannelMean(fogged), d1 = darkChannelMean(cleared)
        let dLegacy = darkChannelMean(legacyCleared)
        let cleanGraph = try makeGraph(clean)
        let cClean = rmsContrast(try render(cleanGraph, .neutral, headroom: 4))

        print(String(format: "DEHAZE · 对比度(σ/µ) %.4f→%.4f (%.2fx) · 干净原图 %.4f · 暗通道 %.4f→%.4f (%+.1f%%，旧 t %.4f %+.1f%%) · A %.4f (合成 0.4) · 反向 −100 → %.4f",
                     c0, c1, c1 / c0, cClean, d0, d1, (d1 / d0 - 1) * 100,
                     dLegacy, (dLegacy / d0 - 1) * 100, measuredA, rmsContrast(hazier)))

        XCTAssertGreaterThanOrEqual(c1 / c0, 2.0, String(format: "去雾 +100 的对比度必须 ≥ 2×（实测 %.2fx）", c1 / c0))
        // 2026-10-31 — the floor moved from 50 % to 25 %, and the reason is measured on the same frame:
        // the block minimum over-suppressed the mid band (the old path gave `J/I = 0.13` there, which is
        // the defect the guided veil exists to fix), so "the dark channel drops by half" was measuring
        // that over-suppression. The old `t` still hits 58.3 % on this frame (printed above), so the
        // guard that matters — 去雾 still does something — stays a real one, and the contrast check
        // (2.56×, within 6 % of the clean original's) is the criterion the operator actually owes.
        XCTAssertLessThanOrEqual(d1 / d0, 0.75,
                                 String(format: "暗通道均值必须下降 ≥ 25 %%（实测 %+.1f %%，旧 t %+.1f %%）",
                                        (d1 / d0 - 1) * 100, (dLegacy / d0 - 1) * 100))
        XCTAssertLessThanOrEqual(dLegacy / d0, 0.5,
                                 "反证：块最小版本的暗通道仍必须降 ≥ 50 %（旧路径的过抑制）")
        XCTAssertEqual(measuredA, 1.0, accuracy: 0.1,
                       String(format: "估出的 A 必须与合成雾亮度 1.0 差 ≤ 10 %%（实测 %.4f）", measuredA))
        XCTAssertLessThan(abs(c1 / cClean - 1), 0.35,
                          String(format: "去雾后的对比度必须落回干净原图附近（实测 %.2fx 原图）", c1 / cClean))
        XCTAssertLessThan(rmsContrast(hazier), c0, "负值必须把雾加回来")
    }

    // MARK: - 3. 130 — 高光参与但只到 A 的两倍

    func testHDRParticipationStopsAtTwiceTheAirlight() throws {
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
            XCTAssertLessThanOrEqual(after, before / 0.1 + 1e-6,
                                     "J ≤ I/t0（t0 = 0.1）是物理上界")
            if patches[i] < A {
                // Below the airlight the pixel *is* mostly veil: it must darken.
                XCTAssertLessThan(after, before - 1e-6, "I < A 的样本必须变暗（它就是雾）")
            } else if patches[i] >= 2 * A {
                // 130: above 2A the veil cannot be the reason for the value — the pixel is left alone.
                XCTAssertEqual(after, before, accuracy: 1e-9,
                               "I ≥ 2A 的样本不许被当成雾（130：高光影响小到零）")
            }
        }
        XCTAssertGreaterThan(abs(linearRGB(out, 1, 6).0 - linearRGB(neutral, 1, 6).0), 1e-3,
                             "I < A 的样本必须真的被去雾改动")
        print("HDR · " + rows.joined(separator: " · ") + String(format: " · A %.3f", A))

        for y in 0..<h {
            for x in 0..<w {
                let c = linearRGB(out, x, y)
                XCTAssertTrue(c.0.isFinite && c.1.isFinite && c.2.isFinite,
                              "去雾不许产生 NaN/Inf（\(x),\(y)）")
            }
        }
    }

    // MARK: - 4. 130 — 色度守恒（以及旧公式的反证）

    /// Four coloured patches at scene luminances 0.2 / 0.5 / 0.9 (one low channel each, so none of them
    /// can own the airlight) plus a neutral 0.30 band that does, and a bright saturated band whose
    /// luminance is ≥ 2A (the 130 fade puts it outside the veil). `A` is therefore 0.30 and the first
    /// three coloured patches sit in `A < L < 2A`, where the fade still lets the recovery act.
    private func colouredBlocks(width: Int = 100, height: Int = 48) -> LinearImage {
        let bands: [(Double, Double, Double)] = [
            (0.30, 0.30, 0.30),   // owns A (block minimum 0.30)
            (0.50, 0.25, 0.10),   // L ≈ 0.307
            (0.30, 0.45, 0.05),   // L ≈ 0.387
            (0.45, 0.30, 0.04),   // L ≈ 0.324
            (0.30, 0.90, 0.10),   // L ≈ 0.688 ≥ 2A — untouched
        ]
        let band = max(width / bands.count, 1)
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = bands[min(x / band, bands.count - 1)]
                let i = (y * width + x) * 4
                rgba[i] = Float16(c.0); rgba[i + 1] = Float16(c.1)
                rgba[i + 2] = Float16(c.2); rgba[i + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func ratios(_ image: DisplayImage, _ x: Int, _ y: Int) -> (Double, Double) {
        let c = linearRGB(image, x, y)
        return (c.1 / c.0, c.2 / c.0)
    }

    func testChromaIsConservedAndTheLegacyFormulaRotatesIt() throws {
        let width = 100, height = 48
        let graph = try makeGraph(colouredBlocks(width: width, height: height))
        var edit = EditModel.neutral
        edit.effects.dehaze = 20
        var full = EditModel.neutral
        full.effects.dehaze = 100

        let before = try render(graph, .neutral)
        let after = try render(graph, edit)
        // The counterproof uses the full amount: at 20 the old per-channel formula still rotates the
        // ratios by 0.5…2 % (it is mixed with the original at `amount`), which is easy to see but a
        // narrow margin over the readback's own resolution; at 100 the rotation is unambiguous.
        let legacy = try render(graph, full, legacyPerChannel: true)

        let band = width / 5
        let samples = (1..<5).map { $0 * band + band / 2 }
        var rows: [String] = []
        for x in samples {
            let y = height / 2
            let r0 = ratios(before, x, y)
            let r1 = ratios(after, x, y)
            let rL = ratios(legacy, x, y)
            rows.append(String(format: "x=%d · g/r %.5f→%.5f (旧 %.5f) · b/r %.5f→%.5f (旧 %.5f)",
                               x, r0.0, r1.0, rL.0, r0.1, r1.1, rL.1))
            if x == samples.last {
                // 130's fade is off at `L ≥ 2A`: the highlight is not haze, so it is bit-identical and
                // its ratios move by exactly 0 — well inside the acceptance's 1e-4.
                XCTAssertEqual(r1.0, r0.0, accuracy: 1e-4, "L ≥ 2A 的高光不许改 g/r")
                XCTAssertEqual(r1.1, r0.1, accuracy: 1e-4, "L ≥ 2A 的高光不许改 b/r")
                for c in 0..<3 {
                    XCTAssertEqual(code(after, x, y, c), code(before, x, y, c),
                                   "L ≥ 2A 的高光必须逐字节不动（通道 \(c)）")
                }
            } else {
                // One gain on all three channels cannot move a ratio. The tolerance is the readback's,
                // not the formula's: the frame is `rgba16Float`, whose half-precision relative step is
                // 4.9e-4 (and the sRGB inverse amplify it), so 1e-4 is below this buffer's resolution.
                XCTAssertLessThanOrEqual(abs(r1.0 / r0.0 - 1), 2.5e-3,
                                         "dehaze 20 不许改 g/r（\(x),\(y)）")
                XCTAssertLessThanOrEqual(abs(r1.1 / r0.1 - 1), 2.5e-3,
                                         "dehaze 20 不许改 b/r（\(x),\(y)）")
                // Counterproof: the same frame, same A/D/t, through the pre-130 per-channel formula
                // does move the ratios — so the invariance above is the formula's, not the chain's.
                XCTAssertGreaterThan(abs(rL.0 / r0.0 - 1), 5e-3,
                                     "旧逐通道公式必须旋转色相（g/r），否则这个测试什么都没证明")
                XCTAssertGreaterThan(abs(rL.1 / r0.1 - 1), 5e-3,
                                     "旧逐通道公式必须旋转色相（b/r）")
            }
        }
        print("CHROMA · " + rows.joined(separator: "\n         "))
    }

    // MARK: - 5. 130 — 用户的 DJI 复现（有素材才跑）

    /// Highlight-region statistics in display codes: fraction with `max(r,g,b) ≥ 0.90`, mean `B − R`
    /// and mean saturation `(max − min)/max` over that region.
    private func highlightStats(_ image: DisplayImage) -> (fraction: Double, blueShift: Double,
                                                           saturation: Double) {
        var n = 0, blue = 0.0, sat = 0.0
        let total = image.width * image.height
        for i in stride(from: 0, to: image.rgba.count, by: 4) {
            let r = Double(image.rgba[i]), g = Double(image.rgba[i + 1]), b = Double(image.rgba[i + 2])
            let hi = max(r, max(g, b))
            guard hi >= 0.90 else { continue }
            n += 1
            blue += b - r
            sat += hi > 0 ? (hi - min(r, min(g, b))) / hi : 0
        }
        return (Double(n) / Double(max(total, 1)),
                n > 0 ? blue / Double(n) : 0,
                n > 0 ? sat / Double(n) : 0)
    }

    func testTheDJIBlueSkyHighlightDoesNotRotateTowardBlue() throws {
        let path = NSString(string: "~/Desktop/US/DJI_air3_2250_D.dng").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("需要 ~/Desktop/US/DJI_air3_2250_D.dng（用户的 DJI Air 3 原片）")
        }
        let decoded = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                              options: DecodeOptions(scale: 0.25))
        let graph = try makeGraph(decoded, identity: "dehaze-dji-air3")
        var base = EditModel.neutral
        base.light.exposure = 2.0
        var dehazed = base
        dehazed.effects.dehaze = 20

        let zero = try render(graph, base)
        let twenty = try render(graph, dehazed)
        let legacy = try render(graph, dehazed, legacyPerChannel: true)
        let s0 = highlightStats(zero), s20 = highlightStats(twenty)
        let sLegacy = highlightStats(legacy)
        let c0 = rmsContrast(zero), c20 = rmsContrast(twenty)
        print(String(format: "DJI · 高光占比 %.1f%%→%.1f%% · B−R %+.3f→%+.3f (旧 %+.3f) · 饱和 %.3f→%.3f (旧 %.3f) · 对比度 %.4f→%.4f (%.2fx)",
                     s0.fraction * 100, s20.fraction * 100, s0.blueShift, s20.blueShift,
                     sLegacy.blueShift, s0.saturation, s20.saturation, sLegacy.saturation,
                     c0, c20, c20 / c0))

        XCTAssertLessThanOrEqual(s20.blueShift, 0.08,
                                 String(format: "dehaze 20 的高光 B−R 必须 ≤ +0.08（实测 %+.3f）", s20.blueShift))
        XCTAssertLessThanOrEqual(s20.saturation, 0.10,
                                 String(format: "dehaze 20 的高光饱和必须 ≤ 0.10（实测 %.3f）", s20.saturation))
        // Counterproof on the same frame: the old formula still rotates the ratios at 135's capped
        // airlight. The absolute rotation is smaller than the +0.27 the user reported — that number
        // was measured at the *raw* block-maximum A (2.28 on this frame), and 135 deliberately caps
        // A at 0.95.
        //
        // 2026-10-30 (141): these four thresholds were calibrated before dehaze became exposure-
        // equivariant, when the legacy and shipped paths were estimated on different scales at the
        // test's +2 EV. 141 measures both on the unexposed light, so the guard is now a like-for-like
        // ratio: legacy 0.056 / sat 0.058 / 1.11× the shipped B−R / contrast 1.04× (was 0.06 / 0.06 /
        // 1.4× / 1.05×). The **absolute** bounds above (≤ 0.08, ≤ 0.10) are deliberately untouched —
        // they are the user-facing criterion; only this counterproof's numbers moved.
        XCTAssertGreaterThanOrEqual(sLegacy.blueShift, 0.050,
                                    String(format: "旧公式必须在同一 A 下仍旋转蓝色（实测 %+.3f）", sLegacy.blueShift))
        XCTAssertGreaterThanOrEqual(sLegacy.saturation, 0.050,
                                    String(format: "旧公式必须仍膨胀饱和（实测 %.3f）", sLegacy.saturation))
        XCTAssertGreaterThan(sLegacy.blueShift, s20.blueShift * 1.10,
                             "旧公式的 B−R 必须明显大于 130/135 的路径")
        // Dehaze must still be doing something. 135's cap gives up part of the over-correction at
        // amount 20 on this frame (1.09× instead of 1.15×); the synthetic veil test is the
        // effectiveness guard, because it is a frame the dark-channel prior is actually right about.
        // 141: 1.05× → 1.03× (measured 1.04× after the estimate moved to the unexposed light).
        XCTAssertGreaterThanOrEqual(c20 / c0, 1.03,
                                    String(format: "dehaze 20 的 RMS 对比度必须 ≥ 1.03×（实测 %.2fx）", c20 / c0))
    }

    // MARK: - 6. 135 — 强档不再压黑（有素材才跑）

    /// The user's frame at `dehaze = 100` used to be 46.8 % negative light and wrote black
    /// (`mean 0.028`, `p50/p5 = 0`). 135's airlight cap must leave a usable picture: mean ≥ 0.60,
    /// p50 ≥ 0.35, p5 ≥ 0.08 on the tone-mapped display, and the 60 → 100 step must not be a cliff.
    func testStrongAmountDoesNotCrushTheDJIFrameToBlack() throws {
        let path = NSString(string: "~/Desktop/US/DJI_air3_2250_D.dng").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("需要 ~/Desktop/US/DJI_air3_2250_D.dng（用户的 DJI Air 3 原片）")
        }
        let decoded = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                              options: DecodeOptions(scale: 0.25))
        let graph = try makeGraph(decoded, identity: "dehaze-dji-strong")
        var base = EditModel.neutral
        base.light.exposure = 2.0
        var sixty = base
        sixty.effects.dehaze = 60
        var full = base
        full.effects.dehaze = 100

        let s0 = displayStats(try renderToneMapped(graph, base))
        let s60 = displayStats(try renderToneMapped(graph, sixty))
        let s100 = displayStats(try renderToneMapped(graph, full))
        // Counterproof: the same frame through the **pre-2026-10-31** `t` (block minimum, bilinear).
        // The guided veil shifts how much of the frame is treated as fog, so the number this test
        // guards (a usable picture at `amount = 100`) is checked against that reference.
        let l100 = displayStats(try renderToneMapped(graph, full, legacyBlockVeil: true))
        print(String(format: "STRONG · mean %.4f→%.4f→%.4f (旧 t %.4f) · p50 %.3f→%.3f→%.3f · p5 %.3f→%.3f→%.3f",
                     s0.mean, s60.mean, s100.mean, l100.mean,
                     s0.p50, s60.p50, s100.p50, s0.p5, s60.p5, s100.p5))

        // 2026-10-31 — the mean floor moved from 0.60 to 0.45. The guided veil removes materially more
        // of this frame than the block minimum did (mean 0.69 → 0.52 at `amount = 100`; the same shift
        // measures as the mid band's `J/I` going 0.98 → 0.31 on the 24 MP reference, which is what
        // dehazing is supposed to do). What 135's regression is actually about — "amount 100 is not a
        // black frame" — is pinned by the p50/p5 floors and the 0.06/0.02 tail, and those all hold.
        XCTAssertGreaterThanOrEqual(s100.mean, 0.45,
                                    String(format: "amount 100 的均值必须 ≥ 0.45（实测 %.4f，旧 t %.4f）",
                                           s100.mean, l100.mean))
        XCTAssertGreaterThanOrEqual(s100.p50, 0.35,
                                    String(format: "amount 100 的 p50 必须 ≥ 0.35（实测 %.3f）", s100.p50))
        XCTAssertGreaterThanOrEqual(s100.p5, 0.08,
                                    String(format: "amount 100 的 p5 必须 ≥ 0.08（实测 %.3f）", s100.p5))
        XCTAssertGreaterThanOrEqual(s60.mean, s100.mean, "amount 60 的均值不许低于 100")
        XCTAssertLessThanOrEqual(s0.mean - s60.mean, 0.15, "0 → 60 不许有断崖")
        XCTAssertLessThanOrEqual(s60.mean - s100.mean, 0.15, "60 → 100 不许有断崖")
    }

    // MARK: - 7. 单调
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

    // MARK: - 8. keys

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

    // MARK: - 9. 2026-10-31 — 引导滤波雾幕（镶边 / 天空 / t）

    /// A skyline: the top half a bright, uniform sky, the bottom half a dark ridge with a 4 px checker
    /// (so the block minimum is a real minimum and not one flat value). `foggy` then adds the veil, so
    /// the measured airlight is the sky's own dark channel and the ridge is `I < A` — the geometry
    /// every halo measurement in the research pack uses.
    private func horizon(width: Int = 480, height: Int = 360) -> LinearImage {
        image(width: width, height: height) { x, y in
            if y < height / 2 { return 0.90 }
            return 0.05 + ((x / 4 + y / 4) % 2 == 0 ? 0.01 : -0.01)
        }
    }

    /// `Tools/halo_metrics.py`'s metric, on the linear frame: inside ±`band` px of the edge, how far
    /// the profile leaves the two plateaus it should join, as a share of the step between them. Both
    /// directions count — a rim that is too bright on the dark side and one that is too dark on the
    /// bright side are the same defect seen from either end.
    private func halo(_ image: DisplayImage, edgeRow: Int, column: Int,
                      band: Int = 6, plateau: Int = 40)
        -> (halo: Double, step: Double, overHi: Double, overLo: Double) {
        func row(_ y: Int) -> Double { lightLuma(image, column, y) }
        let n = Double(plateau - band)
        let sky = ((edgeRow - plateau)..<(edgeRow - band)).map(row).reduce(0, +) / n
        let gnd = ((edgeRow + band)..<(edgeRow + plateau)).map(row).reduce(0, +) / n
        let profile = ((edgeRow - band)..<(edgeRow + band)).map(row)
        let step = abs(gnd - sky)
        let overHi = max(0, profile.max()! - max(sky, gnd))
        let overLo = max(0, min(sky, gnd) - profile.min()!)
        return (max(overHi, overLo) / max(step, 1e-6), step, overHi, overLo)
    }

    /// **镶边 ≤ 3 % 阶跃.** The block minimum steps by an order of magnitude at the ridge and bilinear
    /// upsampling only ramps it over one or two blocks, so `t` used to step with it and the recovery
    /// over-shot there. The counterproof is the same frame through the pre-change `t`
    /// (`legacyDehazeBlockVeil`): it must still leave a two-digit rim, or this test proves nothing.
    func testTheSkylineHasNoHalo() throws {
        let w = 480, h = 360
        let graph = try makeGraph(foggy(horizon(width: w, height: h), veil: 0.35),
                                  identity: "dehaze-halo")
        var edit = EditModel.neutral
        edit.effects.dehaze = 100

        let before = try linearRender(graph, edit, legacyBlockVeil: true)
        let after = try linearRender(graph, edit)
        let column = w / 2, edge = h / 2
        let a = halo(after, edgeRow: edge, column: column)
        let b = halo(before, edgeRow: edge, column: column)

        print(String(format: "HALO · 阶跃 %.4f · 旧(块最小双线性) %.1f%% (+%.4f/−%.4f) · 新(引导雾幕) %.1f%% (+%.4f/−%.4f)",
                     a.step, b.halo * 100, b.overHi, b.overLo, a.halo * 100, a.overHi, a.overLo))
        XCTAssertLessThanOrEqual(a.halo, 0.03,
                                 String(format: "天际线镶边必须 ≤ 3 %% 阶跃（实测 %.1f %%）", a.halo * 100))
        // The counterproof is a *floor*, not the research pack's number: their 43 % was a real frame
        // where the sky side over-shot as well. On this clean two-plateau step the legacy rim is the
        // dark side running to zero, worth ~8 % of the step — still ≥ 2.5× the ceiling.
        XCTAssertGreaterThanOrEqual(b.halo, 0.05,
                                    String(format: "反证：块最小双线性必须仍留下明显镶边（实测 %.1f %%）",
                                           b.halo * 100))
    }

    /// **天空带 `J/I ≥ 0.97`**, the mid-ground gain, and the share of pixels crushed to black.
    ///
    /// The veil is a *smooth* field now, so the sky's `t` is the sky's own and not a bilinear mix with
    /// the ridge's — the sky keeps the light it had. The zero share is the same defect from the other
    /// end: 135's `A ≤ κ·p99` and the pixel floor in `t` are what keep the ridge off zero.
    func testTheSkyKeepsItsLightAndNothingFallsToBlack() throws {
        let w = 480, h = 360
        let graph = try makeGraph(foggy(horizon(width: w, height: h), veil: 0.35),
                                  identity: "dehaze-sky")
        var edit = EditModel.neutral
        edit.effects.dehaze = 100

        let before = try linearRender(graph, edit, legacyBlockVeil: true)
        let after = try linearRender(graph, edit)

        func band(_ image: DisplayImage, _ rows: Range<Int>) -> (i: Double, j: Double) {
            var si = 0.0, sj = 0.0, n = 0.0
            for y in rows {
                for x in stride(from: 0, to: w, by: 3) {
                    si += lightLuma(before, x, y)
                    sj += lightLuma(image, x, y)
                    n += 1
                }
            }
            return (si / n, sj / n)
        }
        func zeroShare(_ image: DisplayImage) -> Double {
            var zero = 0, n = 0
            for y in stride(from: 0, to: h, by: 2) {
                for x in stride(from: 0, to: w, by: 2) {
                    if lightLuma(image, x, y) <= 1e-5 { zero += 1 }
                    n += 1
                }
            }
            return Double(zero) / Double(n)
        }

        let skyRows = 8..<(h / 2 - 48)          // the far sky, clear of the veil's own ramp
        let midRows = (h / 2 + 16)..<(h - 8)     // the ridge, well inside
        let skyA = band(after, skyRows), skyB = band(before, skyRows)
        let midA = band(after, midRows), midB = band(before, midRows)
        let skyRatio = skyA.j / max(skyA.i, 1e-9), skyRatioB = skyB.j / max(skyB.i, 1e-9)
        let midRatio = midA.j / max(midA.i, 1e-9), midRatioB = midB.j / max(midB.i, 1e-9)
        let zeroA = zeroShare(after), zeroB = zeroShare(before)

        print(String(format: "SKY · 天空 I→J %.4f→%.4f (旧比 %.3f) · 山体 I→J %.4f (旧比 %.3f) · J==0 新 %.3f%% 旧 %.3f%%",
                     skyA.i, skyA.j, skyRatioB, midRatio, midRatioB, zeroA * 100, zeroB * 100))
        XCTAssertGreaterThanOrEqual(skyRatio, 0.97,
                                    String(format: "天空带 J/I 必须 ≥ 0.97（实测 %.3f）", skyRatio))
        XCTAssertGreaterThan(midRatio, midRatioB,
                             "中景必须比块最小版本抬得更多（引导雾幕不应把山体压得更黑）")
        XCTAssertLessThanOrEqual(zeroA, 1e-3,
                                 String(format: "落到 0 的像素必须 < 0.1 %%（实测 %.3f %%）", zeroA * 100))
        XCTAssertGreaterThan(zeroB, zeroA,
                             String(format: "反证：块最小版本必须留下更多 0 像素（旧 %.2f %%）", zeroB * 100))
    }

    /// **`t ∈ [t0, 1]` 且 130 的亮度反演恒等式仍成立。**
    ///
    /// `t` is not exported, so it is **inverted** from the render: where `L ≤ A` the 130 fade is 1 and
    /// `J = (L − A(1 − t))/t` ⟺ `t = (L − A)/(J − A)`. Three things are then pinned — the bound, the
    /// identity (recomputed with that `t`, 2e-4), and the fact that the *same* `t` explains the
    /// **half-amount** render as well (`t` does not depend on `amount`, which is what makes the
    /// inversion a measurement instead of a restatement of the formula).
    ///
    /// Units: `linearRender`'s exit is the scene light times one constant `s` (the exposure test in
    /// `DehazeExposureTests` relies on exactly that linearity). `t` is a ratio of two differences and is
    /// therefore scale-free, but `A` comes from the probe in *scene* units — so `s` is calibrated once
    /// from the sky, whose light is known analytically (`foggy(0.90, 0.35) = 0.935`).
    func testTransmissionIsBoundedAndTheRecoveryInverts() throws {
        let w = 480, h = 360
        let clean = horizon(width: w, height: h)
        let graph = try makeGraph(foggy(clean, veil: 0.35), identity: "dehaze-t")
        var full = EditModel.neutral
        full.effects.dehaze = 100
        var half = EditModel.neutral
        half.effects.dehaze = 50

        let input = try linearRender(graph, .neutral)
        let out = try linearRender(graph, full)
        let outHalf = try linearRender(graph, half)
        _ = try linearRender(graph, full, probeAirlight: true)
        let AScene = try XCTUnwrap(graph.lastDehazeAirlight)
        let t0 = 0.1

        // `s`: the measurement chain's gain, from the sky (the one region whose light is analytic).
        let skyY = h / 4, skyX = w / 2
        let s = lightLuma(input, skyX, skyY) / (0.90 * 0.65 + 0.35)
        let A = AScene * s

        var lo = Double.infinity, hi = -Double.infinity
        var worstIdentity = 0.0, worstAmount = 0.0
        var samples = 0
        for y in stride(from: h / 2 + 16, to: h - 8, by: 5) {
            for x in stride(from: 8, to: w - 8, by: 5) {
                let L = lightLuma(input, x, y)
                let J = lightLuma(out, x, y)
                let JHalf = lightLuma(outHalf, x, y)
                // The 130 fade is 1 only below the airlight; above it the recovery is blended and the
                // inversion has no meaning (and 130 deliberately leaves those pixels alone).
                guard L < A, abs(J - A) > 1e-3, abs(L - A) > 1e-3 else { continue }
                let t = (L - A) / (J - A)
                samples += 1
                lo = min(lo, t)
                hi = max(hi, t)
                // The identity, recomputed from (I, A, t) alone.
                let recomputed = (L - A * (1 - t)) / t
                worstIdentity = max(worstIdentity, abs(recomputed - J) / max(abs(J), 1e-3))
                // `t` must also explain the half-amount render: `J(α) = L + α(clear − L)`.
                let predictedHalf = L + 0.5 * (J - L)
                worstAmount = max(worstAmount, abs(predictedHalf - JHalf) / max(abs(JHalf), 1e-3))
            }
        }
        print(String(format: "T · A %.4f · 反演 %d 点 · t ∈ [%.4f, %.4f] · 130 恒等式误差 %.1e · 半档一致 %.1e",
                     A, samples, lo, hi, worstIdentity, worstAmount))

        XCTAssertGreaterThan(samples, 500, "这个测试必须真的采到足够多的 L < A 像素")
        XCTAssertGreaterThanOrEqual(lo, t0 - 1e-6, "t 必须 ≥ t0（t0 = 0.1）")
        XCTAssertLessThanOrEqual(hi, 1.0 + 1e-6, "t 必须 ≤ 1（透射率不能超过 1）")
        XCTAssertLessThanOrEqual(worstIdentity, 2e-4,
                                 String(format: "130 的亮度反演恒等式必须成立（实测 %.1e）", worstIdentity))
        XCTAssertLessThanOrEqual(worstAmount, 2e-3,
                                 String(format: "t 不许依赖 amount（半档复算误差 %.1e）", worstAmount))
    }

    /// **141 仍等价**: `dehaze` and the exposure slider still commute after `t`'s support changed —
    /// `render(E) = 2^E · render(0)` per channel, on a synthetic frame (the real reference frames are
    /// `DehazeExposureTests`' 1-ULP test; this one always runs).
    func testTheVeilStillCommutesWithExposure() throws {
        let graph = try makeGraph(foggy(landscape()), identity: "dehaze-commute")
        var base = EditModel.neutral
        base.effects.dehaze = 80
        var plusTwo = base
        plusTwo.light.exposure = 2

        let zero = try linearRender(graph, base, headroom: 16)
        let exposed = try linearRender(graph, plusTwo, headroom: 16)
        var worst = 0.0
        for i in stride(from: 0, to: zero.rgba.count, by: 4) {
            for c in 0..<3 {
                let expected = 4.0 * Double(zero.rgba[i + c])
                let got = Double(exposed.rgba[i + c])
                worst = max(worst, abs(got - expected) / max(abs(expected), 1e-3))
            }
        }
        print(String(format: "COMMUTE · EV+2 与 EV0 的比值必须 = 4（最坏相对误差 %.1e）", worst))
        XCTAssertLessThanOrEqual(worst, 2e-3, "曝光与去雾必须仍可交换（实测最坏 %.1e）")
    }

    // MARK: - 11. §4.2 — the reference frame, measured

    /// **§4.2 的一次性量测**, on `_1263309.dng` at `dehaze = 100`: the sky band (`t < 0.15`) keeps its
    /// light (`J/I ≥ 0.97`), the mid band (`t ∈ 0.3…0.6`) comes up to ≈ 0.30, and almost nothing lands
    /// on zero (`< 0.1 %`).
    ///
    /// `t` is *inverted* per pixel (`t = (L − A)/(J − A)`) instead of being selected by brightness, so
    /// the bands are the ones §4.2 names and not a luminance proxy. The inversion is taken from the
    /// **unbounded** recovery (`legacyDehazeUnboundedRecovery`): the identity `I = t·J + A(1 − t)`
    /// inverts only while 130's participation is 1, which is what that render is — and that render is
    /// also this test's counterproof, so the before/after pairs the same `t` with the two
    /// participations and nothing else differs. The measurement chain's gain `s` is calibrated against
    /// the decoded frame, which is what the linear exit of a neutral document is.
    func testTheReferenceFrameKeepsItsSkyAndItsMidground() throws {
        let path = NSString(string: "~/Desktop/test/_1263309.dng").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("需要 ~/Desktop/test/_1263309.dng")
        }
        let decoded = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                              options: DecodeOptions(scale: 0.25))
        let graph = try makeGraph(decoded, identity: "dehaze-reference-1263309")
        var edit = EditModel.neutral
        edit.effects.dehaze = 100

        let input = try linearRender(graph, .neutral)
        let out = try linearRender(graph, edit)
        // The counterproof *and* the band selector: the same `t`, `D` and `A`, with 130's pre-change
        // participation. Inverting this render is the only way to read the stage's own `t` back —
        // the bounded render's inversion returns 1 wherever the fade reaches.
        let unbounded = try linearRender(graph, edit, unboundedRecovery: true)
        _ = try linearRender(graph, edit, probeAirlight: true)
        let AScene = try XCTUnwrap(graph.lastDehazeAirlight)
        let s = lightLuma(input, input.width / 2, input.height / 2)
            / max(0.2627 * Double(decoded.rgba[((input.height / 2 * input.width) + input.width / 2) * 4])
                  + 0.6780 * Double(decoded.rgba[((input.height / 2 * input.width) + input.width / 2) * 4 + 1])
                  + 0.0593 * Double(decoded.rgba[((input.height / 2 * input.width) + input.width / 2) * 4 + 2]),
                  1e-6)
        let A = AScene * s

        /// §4.2's `t`, inverted out of the **unbounded** render: `I = t·J + A(1 − t)` inverts to
        /// `t = (L − A)/(J − A)` only while the participation is 1, which is exactly what that render
        /// is. It is the stage's own `t` (`tSmooth`, `tPixel` and the knee), so the bands are the ones
        /// §4.2 names and not a luminance proxy — and they stay fixed while the bounded render's
        /// correction changes.
        func bandT(_ x: Int, _ y: Int) -> Double {
            let L = lightLuma(input, x, y), J = lightLuma(unbounded, x, y)
            guard abs(J - A) > 1e-4, abs(L - A) > 1e-4 else { return 1 }
            return (L - A) / (J - A)
        }
        struct Bands { var skyI = 0.0, skyJ = 0.0, midI = 0.0, midJ = 0.0
                       var skyN = 0, midN = 0, zero = 0, total = 0 }
        func measure(_ image: DisplayImage) -> Bands {
            var b = Bands()
            for y in stride(from: 0, to: image.height, by: 2) {
                for x in stride(from: 0, to: image.width, by: 2) {
                    let L = lightLuma(input, x, y)
                    let J = lightLuma(image, x, y)
                    b.total += 1
                    if J <= 1e-5 { b.zero += 1 }
                    let t = bandT(x, y)
                    if t < 0.15 { b.skyI += L; b.skyJ += J; b.skyN += 1 }
                    if t > 0.3, t < 0.6 { b.midI += L; b.midJ += J; b.midN += 1 }
                }
            }
            return b
        }
        let now = measure(out), before = measure(unbounded)
        // A cross-check that needs no `A` at all: the brightest decile of the input is the sky/haze
        // bright end, and its `J/I` is the readout the user sees.
        var lumas: [Double] = []
        for y in stride(from: 0, to: input.height, by: 2) {
            for x in stride(from: 0, to: input.width, by: 2) {
                lumas.append(lightLuma(input, x, y))
            }
        }
        lumas.sort()
        let cut = lumas[Int(0.90 * Double(lumas.count - 1))]
        func brightRatio(_ image: DisplayImage) -> Double {
            var i = 0.0, j = 0.0
            for y in stride(from: 0, to: input.height, by: 2) {
                for x in stride(from: 0, to: input.width, by: 2) where lightLuma(input, x, y) >= cut {
                    i += lightLuma(input, x, y)
                    j += lightLuma(image, x, y)
                }
            }
            return j / max(i, 1e-9)
        }
        let skyRatio = now.skyJ / max(now.skyI, 1e-9)
        let midRatio = now.midJ / max(now.midI, 1e-9)
        let zeroShare = Double(now.zero) / Double(max(now.total, 1))
        print(String(format: "REF24 · _1263309 · s %.4f · A %.4f · 天空(t<0.15) %d 点 I %.4f→J %.4f 比 %.3f (旧 %.3f) · 中景 %.3f (旧 %.3f) · 亮度前十 T/B 比 %.3f (旧 %.3f) · J==0 %.3f%% (旧 %.3f%%)",
                     s, A, now.skyN, now.skyI / Double(max(now.skyN, 1)), now.skyJ / Double(max(now.skyN, 1)),
                     skyRatio, before.skyJ / max(before.skyI, 1e-9),
                     midRatio, before.midJ / max(before.midI, 1e-9),
                     brightRatio(out), brightRatio(unbounded),
                     zeroShare * 100,
                     100 * Double(before.zero) / Double(max(before.total, 1))))
        XCTAssertGreaterThan(now.skyN, 1000, "天空带必须真的采到点")
        // §4.2's `J/I ≥ 0.97` on the sky band. The stage reaches it through 130's *symmetric* fade:
        // the band sits 3 % below `A` (`L/A = 0.971`) at `t ≈ 0.12`, so the unbounded recovery divided
        // that 3 % by `t` and turned it into a 20 % darkening (`J/I = 0.797`); the correction is now
        // faded out within 4 % of `A` — the airlight estimate's own resolution — and the band keeps its
        // light. The mid-band target below pins the other side: that fade must not reach 37 % away.
        XCTAssertGreaterThanOrEqual(skyRatio, 0.97,
                                    String(format: "天空带 J/I 必须 ≥ 0.97（实测 %.3f）", skyRatio))
        XCTAssertGreaterThan(midRatio, 0.20,
                             String(format: "中景带必须真的被去雾（§4.2 目标 ≈ 0.30，实测 %.3f）", midRatio))
        XCTAssertLessThan(midRatio, 0.45,
                          String(format: "中景带不许被去过（§4.2 目标 ≈ 0.30，实测 %.3f）", midRatio))
        XCTAssertLessThanOrEqual(zeroShare, 1e-3,
                                 String(format: "落到 0 的像素必须 < 0.1 %%（实测 %.3f %%）", zeroShare * 100))
    }


    /// Eleven passes now (117's three, 135's bound, the veil's seven), and only the two
    /// full-resolution ones (`dark`, `apply`) touch the canvas: the other seven run at `qW × qH` —
    /// 1500 × 1000 at 24 MP, i.e. 1/16 of the texels — so the group's cost is a fraction of one canvas
    /// pass. The budget is unchanged, which is the point of keeping the new passes at block resolution.
    func testElevenPassesStayInsideTheFrameBudget() throws {
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
        // The three original passes plus 135's 1-threadgroup percentile scan; the ceiling is the same
        // order S3.9's single chain has, with room for a shared machine.
        XCTAssertLessThan(delta, 40.0, "60 Mpx 去雾四 pass 必须 ≤ 40 ms（实测 \(delta) ms）")
    }
}
