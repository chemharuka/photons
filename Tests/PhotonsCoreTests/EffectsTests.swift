import XCTest
import Metal
import CryptoKit
import PhotonsCore

/// 2026-10-28 — the 效果 card at the pixel level: 暗角 (S3c, which had a kernel and no UI) and 颗粒
/// (S3.7, which had neither).
///
/// Everything is measured on the **shipped** kernels through the shipped graph, on a synthetic
/// 1500×2731 = 4.10 Mpx frame — the size of the reference fixture's canvas and the number the frame
/// budget is written against (16.7 ms). Synthetic rather than the user's DNG on purpose: the
/// assertions here are ratios and variances of a *flat* field, and a flat field is the only input
/// where "the corner lost 50 %" and "the grain's σ is this" are unambiguous. The suite therefore
/// never skips.
///
/// What is pinned:
///
///   1. **中性 = 零像素变化.** A document with no effects renders the pre-S3.7 stage list (seven
///      passes, no S3.7 link in the key chain), and its frame is byte-identical to the same document
///      whose effects group was explicitly reset to `.identity` — the card stores no second state.
///   2. **暗角 50 / 100:** four corners ≥ 25 % darker, centre < 2 %.
///   3. **中点** moves the 50 % ring to the pixel the kernel's own arithmetic predicts.
///   4. **颉粒 size × roughness** 3 × 3: Laplacian variance and visual amplitude, both monotone.
///   5. **确定性:** same seed twice → same sha; another seed → another sha.
///   6. **开销:** ms for one 4.10 Mpx frame carrying both stages.
///   7. **文档/键:** one parameter = one history entry, `documentHash` moves, decode inputs do not,
///      and the seed is in the render key.
final class EffectsTests: XCTestCase {

    /// 4.10 Mpx — the reference canvas (`1500 × 2731`).
    private static let frameWidth = 1500
    private static let frameHeight = 2731

    /// **The neutral frame's sha, recorded on the build *before* the Effects card existed** (main
    /// `2c0629d`, this machine's GPU, the same `flat()` frame):
    ///
    ///     % ./.build/debug/photonsctl render L1030402.dng --edit Tests/Fixtures/edit-neutral.json \
    ///           --out … --scale 0.25          →  pixels 1fa052b05a298028…   (both builds, byte for byte)
    ///     FLATPROBE 23f2b0da1b1aa0f6…         ← this constant, from a probe test in a worktree at 2c0629d
    ///
    /// It is the reference that makes 「中性零变化」 a *test* rather than a promise between two renders
    /// of the same build: both sides of that comparison would carry the same bug. Pinned as a constant
    /// because the fixture is synthetic and the GPU is this machine's — the same reason
    /// `BwLevelsTests` pins its recorded identity.
    private static let preEffectsNeutralSHA =
        "23f2b0da1b1aa0f65bb1cf9298748769c2ac769b2698b3d46131792cac1f4d06"

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String = "effects-tests") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// A flat scene-linear field. `0.18` is a mid grey (sRGB ≈ 0.46), which is where a multiplicative
    /// gain and an additive grain are both easiest to read: the vignette is a pure ratio, and a grain
    /// σ is the standard deviation of the difference against the flat frame.
    private func flat(_ value: Float = 0.18,
                      width: Int = EffectsTests.frameWidth,
                      height: Int = EffectsTests.frameHeight) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        let v = Float16(value)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = v; rgba[i + 1] = v; rgba[i + 2] = v; rgba[i + 3] = 1
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
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

    // MARK: - measurement helpers

    /// sRGB code → linear light. The display image is OETF-encoded, so a *luminance* ratio has to undo
    /// it; the code ratio is reported beside it because that is what a histogram shows.
    private func linear(_ code: Double) -> Double {
        code <= 0.04045 ? code / 12.92 : pow((code + 0.055) / 1.055, 2.4)
    }

    private func code(_ image: DisplayImage, _ x: Int, _ y: Int) -> Double {
        Double(image.rgba[(y * image.width + x) * 4])
    }

    /// Mean of a rectangle, both as an sRGB code mean and as the mean of the linearised samples.
    private func patch(_ image: DisplayImage, x0: Int, y0: Int, w: Int, h: Int) -> (code: Double, linear: Double) {
        var sumCode = 0.0
        var sumLinear = 0.0
        var n = 0
        for y in y0..<min(y0 + h, image.height) {
            for x in x0..<min(x0 + w, image.width) {
                let c = code(image, x, y)
                sumCode += c
                sumLinear += linear(c)
                n += 1
            }
        }
        return (sumCode / Double(max(n, 1)), sumLinear / Double(max(n, 1)))
    }

    /// The four corner patches (outer 6 % of each side) and the centre patch (10 %).
    private struct Patches {
        var corners: [(name: String, rect: (Int, Int, Int, Int))]
        var centre: (Int, Int, Int, Int)
    }

    private func patches(_ image: DisplayImage) -> Patches {
        let w = image.width, h = image.height
        let cw = max(8, Int(Double(w) * 0.06))
        let ch = max(8, Int(Double(h) * 0.06))
        return Patches(corners: [
            ("左上", (0, 0, cw, ch)),
            ("右上", (w - cw, 0, cw, ch)),
            ("左下", (0, h - ch, cw, ch)),
            ("右下", (w - cw, h - ch, cw, ch)),
        ], centre: (w / 2 - w / 20, h / 2 - h / 20, w / 10, h / 10))
    }

    /// Laplacian variance of the luma of a central patch, in sRGB code units. One number for 「高频能
    /// 量」: a 4-neighbour Laplacian kills everything a smooth field has, so on a flat frame it is the
    /// grain's energy and nothing else.
    private func laplacianVariance(_ image: DisplayImage, size: Int = 512) -> Double {
        let x0 = max(1, image.width / 2 - size / 2)
        let y0 = max(1, image.height / 2 - size / 2)
        func luma(_ x: Int, _ y: Int) -> Double {
            let o = (y * image.width + x) * 4
            return 0.2126 * Double(image.rgba[o])
                + 0.7152 * Double(image.rgba[o + 1])
                + 0.0722 * Double(image.rgba[o + 2])
        }
        var values: [Double] = []
        values.reserveCapacity(size * size)
        for y in y0..<(y0 + size) {
            for x in x0..<(x0 + size) {
                values.append(4 * luma(x, y) - luma(x - 1, y) - luma(x + 1, y)
                              - luma(x, y - 1) - luma(x, y + 1))
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance
    }

    /// σ of `grained − neutral` over a central patch, in 8-bit codes — the visual amplitude.
    private func amplitudeCodes(_ grained: DisplayImage, _ neutral: DisplayImage, size: Int = 512) -> Double {
        let x0 = max(0, grained.width / 2 - size / 2)
        let y0 = max(0, grained.height / 2 - size / 2)
        var sum = 0.0, sumSq = 0.0
        var n = 0
        for y in y0..<min(y0 + size, grained.height) {
            for x in x0..<min(x0 + size, grained.width) {
                let d = (code(grained, x, y) - code(neutral, x, y)) * 255
                sum += d
                sumSq += d * d
                n += 1
            }
        }
        let mean = sum / Double(max(n, 1))
        return (sumSq / Double(max(n, 1)) - mean * mean).squareRoot()
    }

    /// The document hash the smoke runner uses: the canonical JSON's sha. A document edit must move it.
    private func documentHash(_ model: EditModel) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(model)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 1. 中性：零像素变化

    /// The card must be **additive**: a document that never used it renders exactly the frame the
    /// pre-S3.7 build rendered, and the stage list must not even contain S3.7 — the pass does not run
    /// and then multiply by zero, it is *not encoded* (`RenderStage.pipeline(hasGrain:)`).
    ///
    /// The three spellings of 「no effects」 below are the three ways a second copy of state could
    /// creep in: an untouched document, one whose group was explicitly assigned `.identity`, and one
    /// that went through the encoded/decoded round trip (a model that grows a phantom field on the way
    /// through JSON would show up here as a moved hash).
    func testNeutralDocumentIsByteIdenticalAndNeverRunsS3_7() throws {
        let graph = try makeGraph(flat())
        var untouched = EditModel.neutral

        var reset = untouched
        reset.effects = .identity

        var roundTripped = try JSONDecoder().decode(EditModel.self, from: JSONEncoder().encode(reset))

        let a = try render(graph, untouched)
        let b = try render(graph, reset)
        let c = try render(graph, roundTripped)

        XCTAssertEqual(a.sha256(), b.sha256(), "显式写回 .identity 也必须零像素变化")
        XCTAssertEqual(a.sha256(), c.sha256(), "过一趟 JSON 也不能变")
        // …and against the **pre-card build's** recorded frame: the one comparison that catches a pass
        // that runs at amount 0 and moves pixels anyway (both sides above would agree on that bug).
        XCTAssertEqual(a.sha256(), Self.preEffectsNeutralSHA,
                       "中性帧必须与加卡之前的构建逐字节相同（sha 是那个构建记录的）")

        // The stage list is the pre-S3.7 list, exactly: seven passes, no S3.7.
        let links = RenderKeyChain.links(identity: "effects-tests",
                                         sourceSize: ImageSize(width: a.width, height: a.height),
                                         canvas: ImageSize(width: a.width, height: a.height),
                                         content: ImageSize(width: a.width, height: a.height),
                                         edit: untouched,
                                         display: DisplayOptions(headroom: 1))
        XCTAssertNil(links.grain, "没有颗粒就没有 S3.7 链接 —— 不是「链接了但乘 0」")
        XCTAssertEqual(links.pipeline, [.geometry, .sceneLinear, .curve, .toneMap, .color,
                                        .vignette, .display])
        XCTAssertEqual(links.pipeline.count, 7, "M1 的七段，一段不多")

        let (_, trace) = try renderWithTrace(graph, untouched)
        XCTAssertFalse(trace.executed.contains(.grain), "中性帧不许编码 S3.7")
        print("NEUTRAL · sha \(a.sha256().prefix(16))… · stages \(links.pipeline.count) · "
              + "grain stage \(trace.executed.contains(.grain))")

        // …and it *is* additive: the same document with the card's numbers set to their neutral still
        // renders those bytes (the only reason to write them is that they are the defaults).
        untouched = reset
        XCTAssertEqual(untouched.effects, EffectsGroup.identity)
    }

    // MARK: - 2. 暗角：四角 ≥ 25 %，中心 < 2 %

    /// 强度 50 and 100, negative (darkening). Measured on a flat field, so the ratio of a patch's
    /// **linear** luminance to the neutral frame's same patch *is* the kernel's mean gain there.
    ///
    /// The centre is asserted at `< 2 %` on both measures, which is the acceptance's stronger reading:
    /// `dist = 0` at the middle means `t = 0`, so the gain is exactly 1 and the only thing left is the
    /// 16-bit storage round trip.
    func testVignetteCornersLoseAtLeastAQuarterAndTheCentreBarelyMoves() throws {
        let graph = try makeGraph(flat())
        let neutral = try render(graph, .neutral)
        let p = patches(neutral)

        struct Row { let amount: Double; let corners: [Double]; let centreLinear: Double; let centreCode: Double }

        var rows: [Row] = []
        for amount in [-50.0, -100.0] {
            var edit = EditModel.neutral
            edit.effects.vignetteAmount = amount
            let frame = try render(graph, edit)

            let corners = p.corners.map { c -> Double in
                let before = patch(neutral, x0: c.rect.0, y0: c.rect.1, w: c.rect.2, h: c.rect.3)
                let after = patch(frame, x0: c.rect.0, y0: c.rect.1, w: c.rect.2, h: c.rect.3)
                return 1 - after.linear / before.linear
            }
            let b = p.centre
            let before = patch(neutral, x0: b.0, y0: b.1, w: b.2, h: b.3)
            let after = patch(frame, x0: b.0, y0: b.1, w: b.2, h: b.3)
            rows.append(Row(amount: amount, corners: corners,
                            centreLinear: 1 - after.linear / before.linear,
                            centreCode: 1 - after.code / before.code))

            for (i, c) in p.corners.enumerated() {
                XCTAssertGreaterThanOrEqual(corners[i], 0.25,
                    "强度 \(Int(amount)) 的\(c.name)只降了 \(String(format: "%.1f", corners[i] * 100))%")
            }
            XCTAssertLessThan(abs(rows.last!.centreLinear), 0.02,
                              "中性中心必须 < 2 %（实测 \(String(format: "%.3f", rows.last!.centreLinear * 100))%）")
            XCTAssertLessThan(abs(rows.last!.centreCode), 0.02,
                              "中心按 sRGB 码值也必须 < 2 %（实测 \(String(format: "%.3f", rows.last!.centreCode * 100))%）")
        }

        for r in rows {
            print(String(format: "VIGNETTE %3.0f · 四角 %@ · 中心 linear %.2f%% / code %.2f%%",
                         r.amount,
                         r.corners.map { String(format: "%.1f%%", $0 * 100) }.joined(separator: " "),
                         r.centreLinear * 100, r.centreCode * 100))
        }
    }

    /// 中点 moves the dark ring, and the ring lands where `s3_vignette.metal` says it must.
    ///
    /// On the centre row `dist == |2u − 1|` (y is at the middle, so `d.y = 0`, and `roundness` 0
    /// interpolates two equal numbers), so a midpoint `m` puts the kernel's own 50 %-of-amount ring at
    /// `x = (1 − inner)·W/2` with `inner = mix(0.25, 1.05, m/100)`. The test *scans* for that ring
    /// instead of trusting the formula: it walks the centre row inwards and reports the first pixel
    /// where the gain crossed half of `amount`.
    func testVignetteMidpointMovesTheDarkRingToItsPredictedPixel() throws {
        let graph = try makeGraph(flat())
        let neutral = try render(graph, .neutral)
        let w = neutral.width, h = neutral.height
        let y = h / 2

        struct Ring { let midpoint: Double; let measured: Int; let predicted: Double }
        var rings: [Ring] = []

        for midpoint in [25.0, 50.0, 75.0] {
            var edit = EditModel.neutral
            edit.effects.vignetteAmount = -100          // gain 0 at the corner, 1 in the middle
            edit.effects.vignetteMidpoint = midpoint
            edit.effects.vignetteFeather = 50
            let frame = try render(graph, edit)

            // Half of the travel: the pixel where linear gain dropped to 0.5.
            var measured = 0
            for x in 0..<(w / 2) {
                let g = linear(code(frame, x, y)) / max(linear(code(neutral, x, y)), 1e-9)
                if g >= 0.5 { measured = x; break }
            }
            let inner = 0.25 + (1.05 - 0.25) * (midpoint / 100.0)
            // `dist` blends a per-axis square with a **pixel-space** radius, so on the centre row it
            // is `|2u−1|` scaled by `k = 1 + r0·(aspect − 1)` (r0 = 0.5 at roundness 0; on a square
            // frame k = 1 and this is the old formula verbatim).
            let roundness = 0.5 + 0.0 / 100.0 * 0.5
            // The radial metric is `pixels / (short edge / 2)`, so along **x** the scale is
            // `W/min(W,H)` — 1 on a portrait frame, the aspect on a landscape one.
            let xScale = Double(w) / Double(min(w, h))
            let k = 1 + roundness * (xScale - 1)
            let predicted = (1 - inner / k) * Double(w) / 2
            rings.append(Ring(midpoint: midpoint, measured: measured, predicted: predicted))

            XCTAssertEqual(Double(measured), predicted, accuracy: 6,
                           "中点 \(Int(midpoint))：暗环应在 x ≈ \(Int(predicted))，实测 \(measured)")
        }
        // A higher midpoint starts the falloff further out, so the 50 % ring moves **towards the
        // edge** — its distance from the centre shrinks. (Measured left-to-right from x = 0: the ring
        // walks *left*, towards the border, as the midpoint rises.)
        XCTAssertGreaterThan(rings[0].measured, rings[1].measured)
        XCTAssertGreaterThan(rings[1].measured, rings[2].measured)

        for r in rings {
            print(String(format: "VIGNETTE RING · 中点 %2.0f → 50%% 环 x = %d px（预测 %.0f，中心行 y = %d，宽 %d）",
                         r.midpoint, r.measured, r.predicted, y, w))
        }
    }

    /// 用户 2026-10-29：**暗角拉到底是一个椭圆，显然错误 —— 暗角要按圆形来。**
    ///
    /// 根因：`dist` 的径向支用的是 `uv`（每轴各自归一化），在 3:2 的帧上等于把圆按宽高比拉伸。
    /// 现在径向支改成「像素 / 短边一半」，并且要求：在**同样像素半径**上，水平方向和垂直方向的
    /// 增益必须相同（±2%），且等值线真的在 r 处而不是 r·aspect 处。
    func testTheVignetteContourIsACircleNotAnEllipse() throws {
        let graph = try makeGraph(flat())          // 非正方形：宽高比就是这条测试的意义
        let neutral = try render(graph, .neutral)
        let w = neutral.width, h = neutral.height
        XCTAssertGreaterThan(abs(w - h), 100, "这条测试需要一个明确的非正方形帧")

        var edit = EditModel.neutral
        edit.effects.vignetteAmount = -100
        edit.effects.vignetteRoundness = 100       // 圆的极端
        edit.effects.vignetteMidpoint = 50
        let frame = try render(graph, edit)

        func gain(_ x: Int, _ y: Int) -> Double {
            linear(code(frame, x, y)) / max(linear(code(neutral, x, y)), 1e-9)
        }
        // Same pixel radius along +x and +y from the centre; a circle gives equal gains, an ellipse
        // does not (the horizontal point sits at r/aspect of the vertical one's relative distance).
        let cx = w / 2, cy = h / 2
        let r = Int(Double(min(w, h)) * 0.35)
        let alongX = gain(cx + r, cy)
        let alongY = gain(cx, cy + r)
        print(String(format: "VIGNETTE CIRCLE · r=%d px · 水平增益 %.4f · 垂直增益 %.4f", r, alongX, alongY))
        XCTAssertEqual(alongX, alongY, accuracy: 0.02,
                       "同样 \(r) px 处水平 \(alongX) 与垂直 \(alongY) 不一致 —— 等值线是椭圆")

        // …and it is not a circle by accident at the centre: the corner must be darker than the edge.
        XCTAssertLessThan(gain(w - 2, h - 2), alongX, "角点应比边上更暗")
    }

    // MARK: - 3. 颉粒：size × roughness

    /// 3 × 3 at amount 100. Two numbers per cell: **Laplacian variance** of the luma (「高频能量」,
    /// code² × 16) and **σ of the difference against the neutral frame** (the visual amplitude, in
    /// 8-bit codes). Size must lower the frequency (variance down as the cell grows), roughness must
    /// raise it (more of the finer octave) — and neither may move the amplitude much, because they are
    /// shape controls, not amount controls.
    func testGrainSizeAndRoughnessShapeTheNoiseWhileAmountSetsItsAmplitude() throws {
        let graph = try makeGraph(flat())
        let neutral = try render(graph, .neutral)
        let baseVariance = laplacianVariance(neutral)

        struct Cell { let size: Double; let roughness: Double; let variance: Double; let amplitude: Double }
        var cells: [Cell] = []

        for size in [0.0, 50.0, 100.0] {
            for roughness in [0.0, 50.0, 100.0] {
                var edit = EditModel.neutral
                edit.effects.grain = 100
                edit.effects.grainSize = size
                edit.effects.grainRoughness = roughness
                let frame = try render(graph, edit)
                let variance = laplacianVariance(frame)
                cells.append(Cell(size: size, roughness: roughness, variance: variance,
                                  amplitude: amplitudeCodes(frame, neutral)))
            }
        }

        for c in cells {
            print(String(format: "GRAIN size %3.0f · rough %3.0f · laplacianVar %10.4f · σ %5.2f codes",
                         c.size, c.roughness, c.variance, c.amplitude))
        }
        print(String(format: "GRAIN flat frame baseline laplacianVar %.6f", baseVariance))

        // Size: bigger grain = less high-frequency energy, at every roughness.
        for roughness in [0.0, 50.0, 100.0] {
            let column = cells.filter { $0.roughness == roughness }.sorted { $0.size < $1.size }
            XCTAssertGreaterThan(column[0].variance, column[1].variance,
                                 "size 0 必须比 size 50 高频能量高（rough \(Int(roughness))）")
            XCTAssertGreaterThan(column[1].variance, column[2].variance,
                                 "size 50 必须比 size 100 高频能量高（rough \(Int(roughness))）")
        }
        // Roughness: more of the finer octave = more high-frequency energy, at every size.
        for size in [0.0, 50.0, 100.0] {
            let row = cells.filter { $0.size == size }.sorted { $0.roughness < $1.roughness }
            XCTAssertLessThan(row[0].variance, row[1].variance,
                              "roughness 0→50 必须让高频能量上升（size \(Int(size))）")
            XCTAssertLessThan(row[1].variance, row[2].variance,
                              "roughness 50→100 必须让高频能量上升（size \(Int(size))）")
        }
        // Amplitude is the amount's job: one amount, so every cell's σ stays in one band.
        let amplitudes = cells.map(\.amplitude)
        let minA = try XCTUnwrap(amplitudes.min()), maxA = try XCTUnwrap(amplitudes.max())
        XCTAssertGreaterThan(minA, 5, "amount 100 的 σ 必须可见（\(String(format: "%.2f", minA)) codes）")
        XCTAssertLessThan(maxA / minA, 2.0,
                          "size/roughness 是形状控制，不该让幅度翻倍（\(String(format: "%.2f…%.2f", minA, maxA))）")
    }

    /// 数量 0 = no grain at all; 50 = half of 100's σ. The **linear** control, so the amplitude numbers
    /// above are attributable to `amount` rather than to a shape accident.
    func testGrainAmountIsTheAmplitudeControl() throws {
        let graph = try makeGraph(flat(width: 600, height: 600))
        let neutral = try render(graph, .neutral)

        var sigmas: [Double: Double] = [:]
        for amount in [0.0, 25.0, 50.0, 100.0] {
            var edit = EditModel.neutral
            edit.effects.grain = amount
            let frame = try render(graph, edit)
            if amount == 0 {
                XCTAssertEqual(frame.sha256(), neutral.sha256(), "数量 0 必须逐字节等于无颗粒")
            }
            sigmas[amount] = amplitudeCodes(frame, neutral, size: 400)
        }
        for (amount, sigma) in sigmas.sorted(by: { $0.key < $1.key }) {
            print(String(format: "GRAIN AMOUNT %3.0f · σ %.2f codes", amount, sigma))
        }
        XCTAssertEqual(sigmas[0] ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual((sigmas[50] ?? 0) / max(sigmas[100] ?? 1, 1e-9), 0.5, accuracy: 0.08,
                       "数量是线性的：50 的 σ 应是 100 的一半")
    }

    // MARK: - 4. 确定性

    /// The seed is the only free variable, and it is **in the key**: same seed twice → identical bytes
    /// (two independent renders, no cache), another seed → different bytes.
    func testSameSeedIsByteIdenticalAndAnotherSeedIsNot() throws {
        let graph = try makeGraph(flat(width: 900, height: 700))

        func frame(seed: Double) throws -> DisplayImage {
            var edit = EditModel.neutral
            edit.effects.grain = 40
            edit.effects.grainSeed = seed
            return try render(graph, edit)
        }

        let a = try frame(seed: 7)
        let b = try frame(seed: 7)
        let c = try frame(seed: 8)

        XCTAssertEqual(a.sha256(), b.sha256(), "同一个种子两次渲染必须逐位一致")
        XCTAssertNotEqual(a.sha256(), c.sha256(), "换种子必须换像素")

        // …and the seed reaches the render key, not just the uniform.
        var s7 = EditModel.neutral
        s7.effects.grain = 40
        s7.effects.grainSeed = 7
        var s8 = s7
        s8.effects.grainSeed = 8
        let size = ImageSize(width: 900, height: 700)
        let l7 = RenderKeyChain.links(identity: "seed", sourceSize: size, canvas: size, content: size,
                                      edit: s7, display: DisplayOptions(headroom: 1))
        let l8 = RenderKeyChain.links(identity: "seed", sourceSize: size, canvas: size, content: size,
                                      edit: s8, display: DisplayOptions(headroom: 1))
        XCTAssertNotNil(l7.grain)
        XCTAssertNotEqual(l7.grain, l8.grain, "种子必须在 S3.7 的键里")
        XCTAssertNotEqual(l7.display, l8.display, "…并且必须传到最后一段（display 由它种下）")
        XCTAssertEqual(l7.vignette, l8.vignette, "种子不该移动 S3c —— 它不读这个数")

        print("SEED · 7×2 → \(a.sha256().prefix(16))… == \(b.sha256().prefix(16))… · "
              + "8 → \(c.sha256().prefix(16))… · key \(String(l7.grain!.suffix(24)))…")
    }

    // MARK: - 5. 开销

    /// One 4.10 Mpx frame, cache off (a complete S0→S4 chain every iteration), **no CPU readback**:
    /// `wantsPixels: false` is the on-screen path, and it is the only honest way to time the passes —
    /// with the readback on, the same frame measures **1033 ms** and the 32 MB conversion to
    /// `DisplayImage` is 99 % of it (`trace`'s own gpu 20.0 ms vs 1033 ms wall). What is compared is
    /// therefore neutral → 暗角 → 颗粒 → both, so a delta is attributable to a pass and not to the
    /// machine: p50 of 15 frames after 3 warm-ups.
    func testOneFrameWithVignetteAndGrainCostsWhatTheBudgetAllows() throws {
        let graph = try makeGraph(flat())

        var vignetteOnly = EditModel.neutral
        vignetteOnly.effects.vignetteAmount = -50
        var grainOnly = EditModel.neutral
        grainOnly.effects.grain = 40
        grainOnly.effects.grainSize = 25
        grainOnly.effects.grainRoughness = 50
        var both = grainOnly
        both.effects.vignetteAmount = -50

        func median(_ edit: EditModel) throws -> Double {
            let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                        useCache: false, wantsPixels: false)
            func once() throws -> Double {
                let start = Date()
                let result = try graph.render(edit, options: options)
                let ms = Date().timeIntervalSince(start) * 1000
                if let t = result.output { graph.recycle(output: t) }
                return ms
            }
            for _ in 0..<3 { _ = try once() }
            var samples: [Double] = []
            for _ in 0..<15 { samples.append(try once()) }
            samples.sort()
            return samples[samples.count / 2]
        }

        let neutral = try median(.neutral)
        let vig = try median(vignetteOnly)
        let grain = try median(grainOnly)
        let bothMs = try median(both)

        // The budget is the mask suite's (p95 ≤ 16.7 ms at 4.1 Mpx for a three-mask frame); these are
        // single full-screen passes, so the ceiling is generous on purpose — it catches a pass that
        // became a neighbourhood operator or fell off the fast path, not silicon speed.
        XCTAssertLessThan(bothMs, 66.0, "4.10 Mpx 暗角+颗粒 p50 \(bothMs) ms —— 超出预算的 4 倍")
        print(String(format: "COST · %d×%d (%.2f Mpx), cache off, no readback · p50 neutral %.2f · 暗角 %.2f · 颗粒 %.2f · 两者 %.2f ms",
                     EffectsTests.frameWidth, EffectsTests.frameHeight,
                     Double(EffectsTests.frameWidth * EffectsTests.frameHeight) / 1e6,
                     neutral, vig, grain, bothMs))
        print(String(format: "COST DELTA · 暗角 %+.2f ms · 颗粒 %+.2f ms · 两者 %+.2f ms（相对中性帧）",
                     vig - neutral, grain - neutral, bothMs - neutral))
    }

    // MARK: - 6. 文档 / 历史 / 解码次数

    /// One parameter write = one document change, and **no decode**: `decodeInputs` is the machine form
    /// of 「要不要重新 develop」, so an unchanged key is 「解码次数 +0」 with no counter to trust.
    func testEveryEffectsNumberMovesTheDocumentHashAndNoneMovesTheDecodeKey() throws {
        let edits: [(String, (inout EditModel) -> Void)] = [
            ("暗角", { $0.effects.vignetteAmount = -30 }),
            ("暗角中点", { $0.effects.vignetteMidpoint = 40 }),
            ("暗角羽化", { $0.effects.vignetteFeather = 60 }),
            ("暗角圆度", { $0.effects.vignetteRoundness = 30 }),
            ("颗粒数量", { $0.effects.grain = 20 }),
            ("颗粒大小", { $0.effects.grainSize = 60 }),
            ("颗粒粗糙度", { $0.effects.grainRoughness = 70 }),
            ("种子", { $0.effects.grainSeed = 12 }),
        ]

        let base = EditModel.neutral
        let baseHash = documentHash(base)
        var previous = baseHash
        for (label, apply) in edits {
            var edit = base
            apply(&edit)
            let hash = documentHash(edit)
            XCTAssertNotEqual(hash, previous, "「\(label)」必须移动 documentHash")
            previous = hash
            XCTAssertEqual(edit.decodeKey, base.decodeKey, "「\(label)」不是解码输入：不许重新 develop")
            // …and the dirty set is the stage that reads it, not the whole graph.
            let stages = edit.changedStages(from: base)
            XCTAssertFalse(stages.isEmpty, "「\(label)」必须标脏")
            XCTAssertTrue(stages.contains(label.hasPrefix("暗角") ? .vignette : .grain),
                          "「\(label)」标脏的必须是它自己那一段（\(stages.map(\.short))）")
        }
        print("DOC · documentHash \(baseHash.prefix(12))… → \(previous.prefix(12))… · 8 次修改，"
              + "decodeKey 未动（\(base.decodeKey)）")
    }

    /// The grain stage's key material names the seed as the **integer the kernel hashes**, so a
    /// document holding 3.7 and one holding 4 are the same grain and must share a cache entry.
    func testTheSeedIsKeyedAsTheIntegerTheKernelHashes() {
        var a = EditModel.neutral
        a.effects.grain = 20
        a.effects.grainSeed = 4
        var b = a
        b.effects.grainSeed = 3.7

        XCTAssertEqual(a.effects.grainSeedValue, 4)
        XCTAssertEqual(b.effects.grainSeedValue, 4, "3.7 与 4 是同一份噪声")
        XCTAssertEqual(a.keyMaterial(.grain), b.keyMaterial(.grain),
                       "键里写的必须是核实际哈希的那个整数")
    }

    /// The 效果 card and the pipeline agree about what exists: 颗粒 0 has no S3.7 stage, 1 has one, and
    /// a vignette-only document keeps the seven-pass list (S3c is unconditional, S3.7 is not).
    func testStageListFollowsTheValues() {
        XCTAssertEqual(EditModel.neutral.effects.hasGrain, false)
        XCTAssertFalse(RenderStage.pipeline(hasMasks: false).contains(.grain))
        XCTAssertTrue(RenderStage.pipeline(hasMasks: false, hasGrain: true).contains(.grain))
        XCTAssertEqual(RenderStage.pipeline(hasMasks: false, hasGrain: true).count, 8)

        var vignetteOnly = EditModel.neutral
        vignetteOnly.effects.vignetteAmount = -20
        XCTAssertEqual(vignetteOnly.changedStages(from: .neutral), [.vignette])
        XCTAssertFalse(vignetteOnly.hasGrain)

        var grainOnly = EditModel.neutral
        grainOnly.effects.grain = 1
        XCTAssertEqual(grainOnly.changedStages(from: .neutral), [.grain])
        XCTAssertTrue(grainOnly.hasGrain)

        // The render-inputs key is the document's "did anything render-relevant move" string: a
        // document with no grain must not gain a segment for a stage it does not have (§3.2).
        XCTAssertFalse(EditModel.neutral.renderInputs.key.contains("s3.7-grain"))
        var grained = EditModel.neutral
        grained.effects.grain = 1
        XCTAssertTrue(grained.renderInputs.key.contains("s3.7-grain"))
        XCTAssertNotEqual(grained.renderInputs.key, EditModel.neutral.renderInputs.key)

        // S3.7 runs after S3c and before S4 — the order is the array, so it is checkable.
        let order = RenderStage.order
        XCTAssertLessThan(order.firstIndex(of: .vignette)!,
                          order.firstIndex(of: .grain)!)
        XCTAssertLessThan(order.firstIndex(of: .grain)!,
                          order.firstIndex(of: .display)!)
    }
}
