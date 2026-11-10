import XCTest
import Metal
import CryptoKit
import PhotonsCore

/// 147 — **whites / contrast / the mask predicates must be exposure-independent.**
///
/// S1 applies the global exposure gain `g = 2^EV` before S1.5, S1.8 and S1 (whites), so a naive read
/// makes each of the three depend on the slider:
///
///   · `whites` read its EV window on the exposed `L`, so the same number acted on different scene
///     tones at E 0 and E +2 (audit: p95 1.266 → 2.070, `+100` reached 6.49× white);
///   · `contrast` kept its pivot at −3.5 EV while the whole picture moved, flipping the coarse gain
///     (audit: p50 0.849 → 1.510);
///   · `maskAtlas`'s luma/colour predicates read the exposed sample, so one `0.55…1.0` mask went from
///     17.09 % to 55.03 % of the frame (IoU 0.196).
///
/// The fix is 141's: `g` travels as a uniform, the estimates/pivots/predicates live on `v / g`, and the
/// applied gain lands back on `v`. `g == 1` is an exact multiply/divide by one, which is the `E = 0`
/// byte contract below.
///
/// The invariant every test here checks:
///
///     render(E = k, slider) == 2^k · render(E = 0, slider)      (scene-linear light, per pixel)
final class ExposureEquivarianceTests: XCTestCase {

    // MARK: - frame builders

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func image(width: Int = 320, height: Int = 200) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width - 1)
                let v = Double(y) / Double(height - 1)
                let ramp = 0.015 + 0.95 * u
                let texture = 0.06 * Double((x * 7 + y * 13) % 11) / 10.0
                let r = ramp * (1.0 + 0.10 * (v - 0.5)) + texture
                let g = ramp * (1.0 - 0.05 * (u - 0.5)) + texture * 0.8
                let b = ramp * (0.85 + 0.25 * v) + texture * 0.6
                let i = (y * width + x) * 4
                rgba[i] = Float16(r); rgba[i + 1] = Float16(g)
                rgba[i + 2] = Float16(b); rgba[i + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func grey(_ value: Double, size: Int = 96) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            let o = i * 4
            rgba[o] = Float16(value); rgba[o + 1] = Float16(value)
            rgba[o + 2] = Float16(value); rgba[o + 3] = 1
        }
        return LinearImage(width: size, height: size, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// Two solid colours: a colour-range mask has one known edge and a non-trivial coverage on both
    /// sides, at every exposure.
    private func twoTone(_ left: (Float, Float, Float), _ right: (Float, Float, Float),
                         width: Int = 128, height: Int = 96) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = x < width / 2 ? left : right
                let o = (y * width + x) * 4
                rgba[o] = Float16(c.0); rgba[o + 1] = Float16(c.1)
                rgba[o + 2] = Float16(c.2); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func decode(_ path: String) throws -> LinearImage {
        try RAWDecoder().decode(URL(fileURLWithPath: path),
                                options: DecodeOptions(scale: 0.25))
    }

    /// S4's linear exit in the **working primaries** (Rec.2020), so the frame is the scene light
    /// itself: S2/S3 are the identity for these documents and only the stage under test runs.
    private func linearRender(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let display = DisplayOptions(primaries: .rec2020, bitDepth: 16, headroom: 1,
                                     linearOutput: true)
        let result = try graph.render(edit, options: RenderOptions(
            scale: 1, display: display, useCache: false, wantsPixels: true))
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    /// 318 / 314 — the document these laws are measured on: the shipped pipeline with the sharpening
    /// stage **off**. Sharpen is a local, halo-clamped operator applied after exposure, so a document
    /// carrying it cannot satisfy `render(E=k) == 2^k·render(0)` by construction — that is the
    /// operator's boundary, not a bug in the stage under test. Same move as 2e6ab4a's
    /// `CropUITestSupport.geometryOnly` for the geometry identities.
    private static var algebraOnly: EditModel {
        var e = EditModel.neutral
        e.sharpen = SharpenGroup(amount: 0, radius: 2.0, detail: 25, masking: 0)
        return e
    }

    private func edit(exposure: Double = 0, whites: Double = 0, contrast: Double = 0,
                      masks: [Mask] = []) -> EditModel {
        var e = Self.algebraOnly
        e.light.exposure = exposure
        e.light.whites = whites
        e.light.contrast = contrast
        e.masks = masks
        return e
    }

    /// The **shipped** document — 314's default sharpen 50 / 2.0 left in. Used only to *measure* the
    /// boundary this file's laws stop at (printed, never asserted).
    private static func shippedEdit(exposure: Double = 0, contrast: Double = 0) -> EditModel {
        var e = EditModel.neutral
        e.light.exposure = exposure
        e.light.contrast = contrast
        return e
    }

    private func masks(luma: Bool, adjustment: Double = 0.5) -> [Mask] {
        let shape: MaskShape = luma
            ? .luminanceRange(LuminanceRangeShape(low: 0.55, high: 1.0,
                                                  lowFeather: 0.10, highFeather: 0.10))
            : .colorRange(ColorRangeShape(samples: [Self.leftColourSRGB], tolerance: 0.18,
                                          smoothness: 0.5))
        return [Mask(id: luma ? "luma-147" : "colour-147", opacity: 1, invert: false,
                     components: [MaskComponent(id: "c", feather: 0.15, shape: shape)],
                     adjustments: LocalAdjustments(exposure: adjustment))]
    }

    // MARK: - the 1-ULP law

    private static let frames: [(String, String)] = [
        ("L1030437", NSString(string: "~/Desktop/test/L1030437.dng").expandingTildeInPath),
        ("L1030433", NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath),
        ("DJI_air3_2250_D", NSString(string: "~/Desktop/US/DJI_air3_2250_D.dng").expandingTildeInPath),
    ]

    @discardableResult
    private func assertCommutes(_ base: DisplayImage, _ exposed: DisplayImage, gain: Float,
                                _ label: String, inputLuma: [Double]? = nil,
                                file: StaticString = #filePath, line: UInt = #line) -> Int {
        let normalFloor = Float(Float16.leastNormalMagnitude)
        // In the subnormal-window regime the input is already quantized on Float16's constant grid
        // (141's measured caveat), and for a near-black pixel that is many EV of log error; the
        // observed residual on L1030433 at E −2 is 1.2e-4 linear, i.e. **0.4 of one display code**.
        // The absolute floor is therefore "under one code", not "half the smallest normal".
        let subnormalTolerance = 4 * normalFloor
        // Contrast's guided filter reads a frame-wide estimation window (coarse radius up to 96/q),
        // so one pixel below Float16's normal range is enough to move the coefficients of a whole
        // neighbourhood. In that regime the 1-ULP law is not applicable to *any* pixel; the same
        // carve-out 141 recorded for the dark-channel window applies here.
        let estimationClean = inputLuma.map { values in
            values.allSatisfy { $0 >= Double(normalFloor) }
        } ?? true
        var over = 0, subnormalOver = 0
        var worst = 0.0, subnormalWorst = 0.0
        var sample = ""
        for i in stride(from: 0, to: base.rgba.count, by: 4) {
            // A pixel whose luma at this exposure fell below Float16's normal range lost low bits in
            // S1's half texture before this stage saw it.
            let estimationNormal = estimationClean
                && (inputLuma.map { $0[i / 4] >= Double(normalFloor) } ?? true)
            for c in 0..<3 {
                let b = Float(base.rgba[i + c])
                let expected = b * gain
                let tol = Float(Float16(expected).ulp)
                let actual = Float(exposed.rgba[i + c])
                let delta = abs(actual - expected)
                let strict = estimationNormal && b >= normalFloor && expected >= normalFloor
                    && expected <= Float(Float16.greatestFiniteMagnitude)
                if strict {
                    if delta > tol {
                        if over == 0 {
                            sample = String(format: "期望 %.7g · 实际 %.7g · 像素 %d 通道 %d · tol %.3g",
                                            expected, actual, i / 4, c, tol)
                        }
                        over += 1
                    }
                    if tol > 0 { worst = max(worst, Double(delta / tol)) }
                } else if delta > subnormalTolerance {
                    subnormalOver += 1
                    subnormalWorst = max(subnormalWorst, Double(delta))
                }
            }
        }
        print(String(format: "COMMUTE · %@ · max %.1f ULP · 超限 %d · 次正规 %d (max %.3g) · %@",
                     label, worst, over, subnormalOver, subnormalWorst, sample))
        XCTAssertEqual(over, 0, "\(label)：必须与曝光可交换（1 ULP）", file: file, line: line)
        XCTAssertEqual(subnormalOver, 0, "\(label)：次正规窗的绝对差必须 ≤ 4×leastNormal（<1 显示码）",
                       file: file, line: line)
        return over
    }

    // MARK: - 1. 交换性，三张参考帧 × 三档曝光

    func testWhitesCommutesWithExposureOnReferenceFrames() throws {
        var available = 0
        for (name, path) in Self.frames {
            guard FileManager.default.fileExists(atPath: path) else {
                print("COMMUTE · \(name) · skipped (missing)")
                continue
            }
            available += 1
            let graph = try makeGraph(try decode(path), identity: "eq-whites-\(name)")
            for w in [-100.0, 100.0] {
                let base = try linearRender(graph, edit(whites: w))
                for k in [-2.0, 1.0, 2.0] {
                    let exposed = try linearRender(graph, edit(exposure: k, whites: w))
                    assertCommutes(base, exposed, gain: Float(pow(2.0, k)),
                                   "\(name) whites=\(Int(w)) E=\(Int(k))")
                }
            }
        }
        if available == 0 { throw XCTSkip("需要三张参考原片") }
    }

    /// 2026-10-30 — **算子顺序由可交换性决定**：与曝光可交换的（blacks/whites/局部曝光…）留在线性域
    /// （S1 系），不可交换的（contrast）放到 tone map 之后的显示域（S2.5）。用户口径与验收记录见
    /// `docs/tasks/174-contrast-contract.md` §0。
    ///
    /// 这条钉的是那个**顺序**的后果。S2.5 是残差增益，且 kernel 先把显示亮度除以 S1 的曝光增益（`p.c.z`）
    /// 再取 log，于是 `2^k` 的整幅缩放把 `G` 与 `B_c` 一起搬走、增益不动 —— 098 在 scene-linear 里锚在
    /// −3.5 EV 绝对电平上的那种翻转（142 audit：p50 0.849 → 1.510）在显示域不再存在。
    ///
    /// 精度用**显示码**，不是 1 ULP：系数是从 q 域双线性上采样回来的，量化下限就是输出的一码；把 1 ULP
    /// 这条（属于逐像素的 whites/蒙版阶段）硬套到它头上只会测出采样误差。
    /// **读数面（2026-10-30 探针实测确认）**：这条读的是 `linearOutput`（无 OETF、无 `min(v, headroom)`），
    /// 量的是**算子增益**。用户可见的那一面**不**满足"同一曝光下强度相同"：同一帧、同编辑，出图后在中调带量
    /// `gain = c50/c0` 的 p50 是 E+0 **1.0041** / E+2 **0.8360**（−16.74 %；把亮度还原到线性域再取 p50 得
    /// 1.0159 / 0.8407；**关掉 tone map 仍是 −17.40 %**，所以不是 tone map 造成的）—— 原因是
    /// `s4_display.metal` 的 `min(v, headroom)` 在 E+2 把中调送上白点后**单侧削掉正向增益**
    /// （被照亮像素码域增益 1.2053 → 1.0000，其中 95.9 % 已贴白点；被压暗的反而 0.8957 → 0.9564）。
    /// 因此：**本测试不许被读成"用户可见强度与曝光无关"**。要改可见那一面必须去改显示管线
    /// （headroom / tone map），**不许**回滚 contrast 的域 —— 那会把「可交换的放前、不可交换的放后」这条顺序破坏掉。
    ///
    /// 实测（三张参考帧 × 两档 contrast × 三档曝光）：**p50 = 0.000 码**（中位像素逐码相同，说明增益本身
    /// 对 `2^k` 缩放不变），尾部 p95 ≤ 3.5 码、>8 码的像素 ≤ 1.7 %——尾部来自 guided filter 的 ε 与
    /// 黑位/白肩阈值在不同曝光下落在不同的 pow2 格子上，是**阈值翻转**，不是增益漂移。
    /// 判据：p50 ≤ 0.05、p95 ≤ 4、>8 码 ≤ 2 %。
    ///
    /// **314 / 318 — 这份文档必须关掉锐化。** 314 把锐化的默认值改成 50 / 2.0，而锐化是
    /// 非线性、带 halo 截止的局部算子：它对 `2^k` 的整幅缩放不交换（暗部的 halo 阈值与亮部
    /// 落在不同的 pow2 格子上），所以「默认文档」上的 `render(E=k, c) ?= 2^k·render(E=0, c)`
    /// 本来就不该成立 —— 那是**算子代数**的边界，不是 contrast 域错了。同 2e6ab4a 给
    /// `CropFullResCanvasTests` 换 `CropUITestSupport.geometryOnly` 一样，这里用 `algebraOnly`
    /// （同一台管线，锐化 amount = 0）。默认 50 下的实测差值在同一个循环里
    /// **打印不判**（见下），它是这条边界本身的证据：
    /// 例如 `L1030433 contrast=+50 E+2` 的 p95 是 **4.980 码**（判据 4）、>8 码 **2.519 %**（判据 2 %），
    /// max 816.80 码；关掉锐化后同一条目四个数全是 0.00。
    func testContrastCommutesWithExposureOnReferenceFrames() throws {
        var available = 0
        for (name, path) in Self.frames {
            guard FileManager.default.fileExists(atPath: path) else {
                print("COMMUTE · \(name) · skipped (missing)")
                continue
            }
            available += 1
            let graph = try makeGraph(try decode(path), identity: "eq-contrast-\(name)")
            for c in [-50.0, 50.0] {
                let base = try linearRender(graph, edit(contrast: c))
                for k in [-2.0, 1.0, 2.0] {
                    let exposed = try linearRender(graph, edit(exposure: k, contrast: c))
                    let gain = Float(pow(2.0, k))
                    let s = residualStats(base, exposed, gain: gain)
                    print(String(format: "COMMUTE · %@ contrast=%+.0f E%+.0f · |Y(E)−2^k·Y₀| "
                                 + "p50 %.3f / p95 %.3f / p99 %.3f / max %.2f codes · >8 codes %.3f%% · n %d",
                                 name, c, k, s.p50, s.p95, s.p99, s.max, s.share8 * 100, s.n))
                    XCTAssertLessThanOrEqual(s.p50, 0.05,
                                             "\(name) contrast=\(Int(c)) E=\(Int(k))："
                                             + "两档曝光的中位像素必须逐码相同")
                    XCTAssertLessThanOrEqual(s.p95, 4.0,
                                             "\(name) contrast=\(Int(c)) E=\(Int(k))："
                                             + "95 % 的像素必须在四码以内（顺序已经确定：contrast 在 S2.5）")
                    XCTAssertLessThanOrEqual(s.share8, 0.02,
                                             "\(name) contrast=\(Int(c)) E=\(Int(k))："
                                             + "超过 8 码的像素超过 2 % —— 尾部应当只有 ε / 黑位 / 白肩的"
                                             + "阈值翻转，不该是一个整体漂移")

                    // 314 — the shipped document (default sharpen 50 / 2.0), measured and **not**
                    // asserted: this is the size of the operator boundary the assertion above avoids.
                    let shippedBase = try linearRender(graph, Self.shippedEdit(contrast: c))
                    let shippedExposed = try linearRender(graph,
                                                          Self.shippedEdit(exposure: k, contrast: c))
                    let d = residualStats(shippedBase, shippedExposed, gain: gain)
                    print(String(format: "COMMUTE · %@ contrast=%+.0f E%+.0f · 默认锐化 50/2.0（不判）· "
                                 + "p50 %.3f / p95 %.3f / p99 %.3f / max %.2f codes · >8 codes %.3f%% · n %d",
                                 name, c, k, d.p50, d.p95, d.p99, d.max, d.share8 * 100, d.n))
                }
            }
        }
        if available == 0 { throw XCTSkip("需要三张参考原片") }
    }

    /// 318 — one contrast/exposure residual, in display codes, over the pixels the law applies to.
    private struct ResidualStats {
        let p50: Double, p95: Double, p99: Double, max: Double, share8: Double, n: Int
    }

    private func residualStats(_ base: DisplayImage, _ exposed: DisplayImage,
                               gain: Float) -> ResidualStats {
        var residuals: [Double] = []
        var worst = 0.0
        for i in stride(from: 0, to: base.rgba.count, by: 4) {
            let b = Float(base.rgba[i])
            let expected = b * gain
            guard b > 1e-3, expected > 1e-3 else { continue }
            let d = Double(abs(Float(exposed.rgba[i]) - expected)) * 255
            residuals.append(d)
            worst = max(worst, d)
        }
        return ResidualStats(p50: percentile(residuals, 0.5), p95: percentile(residuals, 0.95),
                             p99: percentile(residuals, 0.99), max: worst,
                             share8: Double(residuals.filter { $0 > 8 }.count)
                                 / Double(max(residuals.count, 1)),
                             n: residuals.count)
    }

    func testMaskPredicateCommutesWithExposureOnReferenceFrames() throws {
        // The atlas is the mask stage's output — a predicate, not light — so its form of
        // `render(E=k) == 2^k · render(E=0)` is "the same coverage at every exposure". (The local
        // adjustment that consumes it is checked on a toe-free synthetic frame below: the local
        // pass's own `s1_toe` is identity above 1e-3 linear, and a real frame's deep shadows would
        // test that toe, not 147.)
        var available = 0
        for (name, path) in Self.frames {
            guard FileManager.default.fileExists(atPath: path) else {
                print("COMMUTE · \(name) · skipped (missing)")
                continue
            }
            available += 1
            let graph = try makeGraph(try decode(path), identity: "eq-mask-\(name)")
            let base = try XCTUnwrap(try graph.maskAtlas(
                edit(masks: masks(luma: true)), options: RenderOptions(scale: 1)))
            let zero = base.slices[0].map(Double.init)
            for k in [-2.0, 1.0, 2.0] {
                let dump = try XCTUnwrap(try graph.maskAtlas(
                    edit(exposure: k, masks: masks(luma: true)), options: RenderOptions(scale: 1)))
                let values = dump.slices[0].map(Double.init)
                var worst = 0.0
                for i in 0..<min(zero.count, values.count) {
                    worst = max(worst, abs(zero[i] - values[i]))
                }
                print(String(format: "COMMUTE · %@ luma-mask E=%+.0f · max|Δcov| %.6f",
                             name, k, worst))
                XCTAssertLessThanOrEqual(worst, 1e-3,
                                         "\(name)：蒙版谓词必须与曝光无关（E=\(Int(k))）")
            }
        }
        if available == 0 { throw XCTSkip("需要三张参考原片") }
    }

    func testMaskAdjustmentCommutesWithExposure() throws {
        // A bright synthetic frame keeps every sample above `LEV_KNEE`, so the local pass is the pure
        // gain the mask adds; the selection underneath it is the same at every exposure.
        var rgba = [Float16](repeating: 0, count: 200 * 140 * 4)
        for y in 0..<140 {
            for x in 0..<200 {
                let v = 0.05 + 0.9 * Double(x) / 199.0 + 0.01 * Double((x + y) % 3)
                let o = (y * 200 + x) * 4
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v * 0.85)
                rgba[o + 2] = Float16(v * 0.7); rgba[o + 3] = 1
            }
        }
        let img = LinearImage(width: 200, height: 140, rgba: rgba,
                              colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let graph = try makeGraph(img, identity: "eq-mask-render")
        let base = try linearRender(graph, edit(masks: masks(luma: true)))
        for k in [-2.0, 1.0, 2.0] {
            let exposed = try linearRender(graph, edit(exposure: k, masks: masks(luma: true)))
            assertCommutes(base, exposed, gain: Float(pow(2.0, k)), "synthetic luma-mask E=\(Int(k))")
        }
    }

    // MARK: - 2. whites: p95 gain ratio, top-white share, p99 (cross-exposure)

    private func luma(_ image: DisplayImage) -> [Double] {
        var out = [Double](repeating: 0, count: image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                out[y * image.width + x] = 0.2627 * Double(image.rgba[i])
                    + 0.6780 * Double(image.rgba[i + 1]) + 0.0593 * Double(image.rgba[i + 2])
            }
        }
        return out
    }

    private func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let i = min(max(Int((Double(sorted.count - 1) * q).rounded()), 0), sorted.count - 1)
        return sorted[i]
    }

    func testWhitesMetricsAreExposureInvariant() throws {
        let path = Self.frames[0].1
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("需要 L1030437")
        }
        let graph = try makeGraph(try decode(path), identity: "eq-whites-metrics")
        var normalized: [Double: (p95: Double, p99: Double, top: Double)] = [:]
        for ev in [0.0, 2.0] {
            let g = pow(2.0, ev)
            let none = luma(try linearRender(graph, edit(exposure: ev)))
            for w in [-100.0, 100.0] {
                let frame = luma(try linearRender(graph, edit(exposure: ev, whites: w)))
                // The comparison is made on the **unexposed** scale: an E +2 frame is the E 0 frame
                // times g by construction, so dividing g out is what makes the two comparable.
                let values = frame.map { $0 / g }
                let baseline = none.map { $0 / g }
                let p95 = percentile(values, 0.95)
                let p95None = percentile(baseline, 0.95)
                let ratio = p95 / p95None
                let top = Double(values.filter { $0 >= 1.0 }.count) / Double(values.count)
                normalized[ev * 10 + w] = (p95: ratio, p99: percentile(values, 0.99), top: top)
                print(String(format: "WHITES · E%+.0f w=%+.0f · p95 %.5f / 无whites %.5f = %.4f · p99 归一 %.4f · 顶白 归一 %.3f%% · 绝对 p99 %.4f",
                             ev, w, p95, p95None, ratio, percentile(values, 0.99),
                             top * 100, percentile(frame, 0.99)))
            }
        }
        for w in [-100.0, 100.0] {
            guard let e0 = normalized[w], let e2 = normalized[20 + w] else { continue }
            XCTAssertEqual(e2.p95, e0.p95, accuracy: 0.05 * e0.p95,
                           "whites=\(Int(w))：E +2 的 p95 增益比与 E 0 的差必须 ≤ 5 %")
            XCTAssertEqual(e2.top, e0.top, accuracy: 0.02,
                           "whites=\(Int(w))：E +2 的顶白占比与 E 0 的差必须 ≤ 2 pp")
            XCTAssertLessThanOrEqual(e2.p99, e0.p99 * 1.02,
                                     "whites=\(Int(w))：E +2 的 p99 不得超过 E 0 的 1.02×")
        }
    }

    // MARK: - 3. contrast: p50 sign/ratio and the closed form

    private func medianGain(_ values: [Double], _ baseline: [Double]) -> Double {
        let a = percentile(values, 0.5), b = percentile(baseline, 0.5)
        return b > 0 ? a / b : 0
    }

    /// **228 re-pin.** This test used to pin 159's multiscale p50 gains (1.0786 at +100, 0.98069 at
    /// −100, 1.06189 at +50). 228 replaced that operator with a global power curve, so those absolute
    /// numbers belong to a different function. What survives — and what this test is for — is the
    /// **exposure law**: the same slider at E 0 and E +2 must produce the same gain, because the curve
    /// is built on `Y / exposureGain` and multiplied back onto the exposed pixel. The absolute gains
    /// are printed, not asserted; `GlobalContrastTests` pins the curve itself.
    func testContrastGainIsPinnedAtZeroAndPlusTwoStops() throws {
        let path = Self.frames[0].1
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("需要 L1030437")
        }
        let graph = try makeGraph(try decode(path), identity: "contrast-pinned")
        var gains: [Double: Double] = [:]
        for ev in [0.0, 2.0] {
            let g = pow(2.0, ev)
            let none = luma(try linearRender(graph, edit(exposure: ev)))
            for c in [-100.0, 50.0, 100.0] {
                let frame = luma(try linearRender(graph, edit(exposure: ev, contrast: c)))
                let gain = medianGain(frame.map { $0 / g }, none.map { $0 / g })
                gains[ev * 10 + c] = gain
                print(String(format: "CONTRAST · E%+.0f c=%+.0f · p50 增益 %.6f", ev, c, gain))
            }
        }
        guard let e0 = gains[100], let e2 = gains[120] else {
            return XCTFail("+100 没有测到")
        }
        XCTAssertEqual(e2, e0, accuracy: 0.02 * e0,
                       "E +2 与 E 0 的 p50 增益必须相同 —— 228 的曲线建在 Y/exposure 上")
        for c in [-100.0, 50.0] {
            guard let a = gains[c], let b = gains[20 + c] else {
                return XCTFail("c=\(c) 没有测到")
            }
            XCTAssertEqual(b, a, accuracy: 0.02 * a,
                           "c=\(c)：两个曝光下必须是同一个算子")
        }
    }

    /// 228: the flat **0.18** frame is the curve's pivot, so its gain is exactly 1 at every exposure —
    /// still the cleanest closed form the operator has. The old residual operator had *no* level term,
    /// so every flat field was the identity; the global curve has one, and it is anchored here.
    func testFlatFrameGainIsExactlyOneAtEveryExposure() throws {
        let graph = try makeGraph(grey(0.18), identity: "contrast-flat-closed-form")
        for ev in [0.0, 2.0, -2.0] {
            let g = pow(2.0, ev)
            let base = luma(try linearRender(graph, edit(exposure: ev)))
            for c in [-100.0, -50.0, 50.0, 100.0] {
                let plus = luma(try linearRender(graph, edit(exposure: ev, contrast: c)))
                let gain = medianGain(plus.map { $0 / g }, base.map { $0 / g })
                print(String(format: "FLAT · E%+.0f c=%+.0f · 实测增益 %.7f · 闭式 1", ev, c, gain))
                XCTAssertEqual(gain, 1.0, accuracy: 1e-6,
                               "E \(Int(ev)) c=\(Int(c))：平场没有残差，增益必须是 1")
            }
        }
        // 同一个算子在 Swift 侧的看法：0.18 是枢轴，所以 `gain(0.18, c) == 1`，与滑杆位置无关。
        XCTAssertEqual(GlobalContrast.gain(luma: 0.18, contrast: 100), 1, accuracy: 1e-15)
        XCTAssertEqual(GlobalContrast.gain(luma: 0.18, contrast: -100), 1, accuracy: 1e-15)
        XCTAssertEqual(GlobalContrast.pivot, 0.18, accuracy: 0)
    }

    // MARK: - 4. mask predicates: IoU / mean |Δcov| / cov ≥ 0.8 share

    private func coverage(_ dump: MaskAtlasDump, slice: Int) -> [Double] {
        dump.slices[slice].map(Double.init)
    }

    private func assertSameSelection(_ a: [Double], _ b: [Double], _ label: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count)
        var inter = 0.0, union = 0.0, delta = 0.0
        var aHigh = 0, bHigh = 0
        for i in 0..<min(a.count, b.count) {
            inter += min(a[i], b[i])
            union += max(a[i], b[i])
            delta += abs(a[i] - b[i])
            if a[i] >= 0.8 { aHigh += 1 }
            if b[i] >= 0.8 { bHigh += 1 }
        }
        let iou = union > 0 ? inter / union : 1
        let meanDelta = delta / Double(max(a.count, 1))
        let highA = Double(aHigh) / Double(max(a.count, 1))
        let highB = Double(bHigh) / Double(max(a.count, 1))
        print(String(format: "MASK · %@ · IoU %.4f · mean|Δcov| %.4f · cov≥0.8 %.2f%% vs %.2f%% · 面积 %.2f%% vs %.2f%%",
                     label, iou, meanDelta, highA * 100, highB * 100,
                     a.reduce(0, +) / Double(max(a.count, 1)) * 100,
                     b.reduce(0, +) / Double(max(a.count, 1)) * 100))
        XCTAssertGreaterThanOrEqual(iou, 0.98, "\(label)：IoU 必须 ≥ 0.98", file: file, line: line)
        XCTAssertLessThanOrEqual(meanDelta, 0.02, "\(label)：mean|Δcov| 必须 ≤ 0.02",
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(abs(highA - highB), 0.005,
                                 "\(label)：cov ≥ 0.8 的像素占比三档必须相同", file: file, line: line)
    }

    func testLuminanceMaskSelectionIsExposureInvariant() throws {
        let path = Self.frames[0].1
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("需要 L1030437")
        }
        let graph = try makeGraph(try decode(path), identity: "eq-mask-luma")
        var coverages: [Double: [Double]] = [:]
        for ev in [-2.0, 0.0, 2.0] {
            let dump = try XCTUnwrap(try graph.maskAtlas(edit(exposure: ev, masks: masks(luma: true)),
                                                        options: RenderOptions(scale: 1)))
            coverages[ev] = coverage(dump, slice: 0)
        }
        guard let zero = coverages[0], let minus = coverages[-2], let plus = coverages[2] else {
            return XCTFail("missing coverage")
        }
        print(String(format: "MASK luma · E0 面积 %.2f%%", zero.reduce(0, +) / Double(zero.count) * 100))
        assertSameSelection(zero, minus, "luma 0.55…1.0 · E−2 vs E0")
        assertSameSelection(zero, plus, "luma 0.55…1.0 · E+2 vs E0")
    }

    func testColourMaskSelectionIsExposureInvariant() throws {
        let left: (Float, Float, Float) = (0.20, 0.40, 0.15)
        let right: (Float, Float, Float) = (0.15, 0.20, 0.85)
        let graph = try makeGraph(twoTone(left, right), identity: "eq-mask-colour")
        var coverages: [Double: [Double]] = [:]
        for ev in [-2.0, 0.0, 2.0] {
            let dump = try XCTUnwrap(try graph.maskAtlas(edit(exposure: ev, masks: masks(luma: false)),
                                                        options: RenderOptions(scale: 1)))
            coverages[ev] = coverage(dump, slice: 0)
        }
        guard let zero = coverages[0], let minus = coverages[-2], let plus = coverages[2] else {
            return XCTFail("missing coverage")
        }
        print(String(format: "MASK colour · E0 面积 %.2f%%",
                     zero.reduce(0, +) / Double(zero.count) * 100))
        assertSameSelection(zero, minus, "colour · E−2 vs E0")
        assertSameSelection(zero, plus, "colour · E+2 vs E0")
    }

    // MARK: - 5. E = 0 逐字节不变（digests recorded with the pre-147 build）

    private static let e0SHASHA: [String: String] = [
        "whites·-100": "f0aab69d7053530ade24137072c6020932ae4699a1e5afc9ec7a038531b008e0",
        "whites·-50": "00d775c5e4e1460958891d4cf061c7bd1fbbb893630dd9690fcb901f15796579",
        "whites·0": "ca29dd99716d62f978a01f429fac8bc8f6b2637752dc688d70a82684efed8f80",
        "whites·50": "df77d410c7c3fcdc4b78054d46c13ba7dda559ccc0f30ca96639ba13582669eb",
        "whites·100": "171d3efc32fed68f151157287de9d053e1c6c8221b5625c0671f1631e092f755",
        "contrast·-100": "942e973a97e9bf115a37cb440807faeade533fb3d0d5cee0d47dbab30c466269",
        "contrast·-50": "987bdb88fe0a2fe0c3a59df005d750987a7aafcf40be6ea3f5b4100054bbbf89",
        "contrast·50": "c671cb270d37f00a1eac6ecc65bade0dc59d5e3725bf7e8e53262313e011d53d",
        "contrast·100": "39979df257481b60497c04d39727545510be1b28e4892fe6d3e32eaa2ceaef87",
        // **265（2026-11-03）重钉这四个 contrast 档。** 228 把 159 的多尺度局部算子换成显示域的全局
        // 幂曲线，`contrast` 段必然整段变；265 又修了这条曲线的锚点：它读的是 **16F** 缓冲，文档里的
        // 0.18 平场实际存成 `half(0.18)` = 0.1800537，而 Double 锚点留下 4.3e-4 的偏移，曲线在枢轴上
        // 的位移只有 0.22 个码；隐式 float→half 存盘**向零截断**，于是负对比度白丢一码
        // （1474/1475 = 0.9993220，−1/−50/−100 全一样），正对比度却留在原码。修法：锚点取同一张
        // 半精度网格上的中灰 `half(0.18)`（`s1_8_contrast.metal#s2_5_global_gain`），平场处 G == P，
        // `gain == 1` 精确成立，两侧逐字节相等。
        // 旧（187 记录的 159 局部算子值）→ 新：-100 4a1c72dc…93a382 → 942e973a…c466269，
        // -50 cbcd950b…d9a0843 → 987bdb88…bbbf89，+50 271a3f57…516c94c6 → c671cb27…11d53d，
        // +100 eeae3582…e0a6537d → 39979df2…ceaef87。`whites·*` 五档与 `atlas` **未动**：它们的
        // 文档 contrast = 0，S2.5 根本不编码，仍是 147/167 的逐字节值。
        // 167: the atlas digest below moved **only** because the luma predicate's axis no longer
        // folds HDR light to `L = 1`; at E = 0 the global gain is still exactly 1, so this remains a
        // check of 147's "unexposed tick" invariant for the same document. Old → new:
        // 37b8deb9…b0eae → 2b0a593e…9eee (introduced by b6166e4, 147).
        "atlas": "2b0a593e14b510ca2580e50d4b0ad144d12b77b1d000c9ddbbf04b34134d9eee",
    ]

    private static let leftColourSRGB: [Double] = {
        func encode(_ v: Double) -> Double {
            v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return [encode(0.20), encode(0.40), encode(0.15)]
    }()

    private func atlasSHA(_ dump: MaskAtlasDump) -> String {
        var hasher = SHA256()
        for slice in dump.slices {
            let bits = slice.map { Float16($0).bitPattern }
            bits.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: raw.baseAddress,
                                                                    count: raw.count))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func testZeroExposureIsByteIdenticalToThePre147Build() throws {
        let img = image()
        let graph = try makeGraph(img, identity: "e0-record")
        for w in [-100.0, -50.0, 0.0, 50.0, 100.0] {
            let sha = try linearRender(graph, edit(whites: w)).sha256()
            let key = "whites·\(Int(w))"
            print("E0 · \(key) · \(sha)")
            XCTAssertEqual(sha, Self.e0SHASHA[key],
                           "147 不许动 E = 0 的 whites（g = 1 必须是逐字节恒等）")
        }
        for c in [-100.0, -50.0, 50.0, 100.0] {
            let sha = try linearRender(graph, edit(contrast: c)).sha256()
            let key = "contrast·\(Int(c))"
            print("E0 · \(key) · \(sha)")
            XCTAssertEqual(sha, Self.e0SHASHA[key],
                           "159 换域后 E = 0 的 contrast 重钉；whites/atlas 仍是 147 的逐字节值")
        }
        var maskEdit = EditModel.neutral
        maskEdit.masks = [
            Mask(id: "luma-147", opacity: 1, invert: false,
                 components: [MaskComponent(id: "c", feather: 0.2,
                                            shape: .luminanceRange(LuminanceRangeShape(
                                                low: 0.55, high: 1.0,
                                                lowFeather: 0.10, highFeather: 0.10)))],
                 adjustments: LocalAdjustments(exposure: 0.5)),
            Mask(id: "colour-147", opacity: 1, invert: false,
                 components: [MaskComponent(id: "c", feather: 0.15,
                                            shape: .colorRange(ColorRangeShape(
                                                samples: [[0.55, 0.35, 0.20]],
                                                tolerance: 0.18, smoothness: 0.5)))],
                 adjustments: LocalAdjustments(exposure: -0.25)),
        ]
        let dump = try XCTUnwrap(try graph.maskAtlas(maskEdit, options: RenderOptions(scale: 1)))
        let sha = atlasSHA(dump)
        print("E0 · atlas · \(sha)")
        XCTAssertEqual(sha, Self.e0SHASHA["atlas"],
                       "147 不许动 E = 0 的蒙版谓词（g = 1 必须是逐字节恒等）")
    }
}
