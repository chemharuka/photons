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

    private func edit(exposure: Double = 0, whites: Double = 0, contrast: Double = 0,
                      masks: [Mask] = []) -> EditModel {
        var e = EditModel.neutral
        e.light.exposure = exposure
        e.light.whites = whites
        e.light.contrast = contrast
        e.masks = masks
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

    func testContrastCommutesWithExposureOnReferenceFrames() throws {
        // 2026-10-30 (mainline): 147 的 contrast 归一化**已回滚**，这一条暂时不成立，原因是一个真正二选一的设计冲突：
        //   · 把 contrast 的枢轴搬去「未曝光刻度」可以让 contrast 与 exposure 可交换（审计 §2 #3，p50 0.849→1.510 方向翻转）；
        //   · 但 `s1_8_contrast` 只能按**文档级**曝光增益归一，而蒙版里的局部曝光是逐像素增益，于是
        //     `LocalColorStageTests.testLocalExposureLandsInTheSameDomainAsGlobalExposure` 会退回差 4 码
        //     （079 的「同一滑杆在蒙版内外同义」是用户可见承诺，比可交换性更硬）。
        //   → 保留 079、放弃这条可交换性，并把决定记录在 `docs/tasks/QUEUE.md`（147 条目）+ 审计报告 §2 #3。
        throw XCTSkip("147 reverted the contrast normalisation: it trades 079's masked-vs-global equality for commutativity; decision pending")
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
                    // The stage's input at this exposure (no contrast pass): its luma is the estimate
                    // the guided filter reads, so this is where the half-subnormal caveat belongs.
                    let input = luma(try linearRender(graph, edit(exposure: k)))
                    assertCommutes(base, exposed, gain: Float(pow(2.0, k)),
                                   "\(name) contrast=\(Int(c)) E=\(Int(k))", inputLuma: input)
                }
            }
        }
        if available == 0 { throw XCTSkip("需要三张参考原片") }
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

    func testContrastMetricsAreExposureInvariant() throws {
        // 2026-10-30 (mainline): 147 的 contrast 归一化**已回滚**，这一条暂时不成立，原因是一个真正二选一的设计冲突：
        //   · 把 contrast 的枢轴搬去「未曝光刻度」可以让 contrast 与 exposure 可交换（审计 §2 #3，p50 0.849→1.510 方向翻转）；
        //   · 但 `s1_8_contrast` 只能按**文档级**曝光增益归一，而蒙版里的局部曝光是逐像素增益，于是
        //     `LocalColorStageTests.testLocalExposureLandsInTheSameDomainAsGlobalExposure` 会退回差 4 码
        //     （079 的「同一滑杆在蒙版内外同义」是用户可见承诺，比可交换性更硬）。
        //   → 保留 079、放弃这条可交换性，并把决定记录在 `docs/tasks/QUEUE.md`（147 条目）+ 审计报告 §2 #3。
        throw XCTSkip("147 reverted the contrast normalisation: it trades 079's masked-vs-global equality for commutativity; decision pending")
        let path = Self.frames[0].1
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("需要 L1030437")
        }
        let graph = try makeGraph(try decode(path), identity: "eq-contrast-metrics")
        var gains: [Double: Double] = [:]
        for ev in [0.0, 2.0] {
            let g = pow(2.0, ev)
            let none = luma(try linearRender(graph, edit(exposure: ev)))
            for c in [-100.0, 50.0, 100.0] {
                let frame = luma(try linearRender(graph, edit(exposure: ev, contrast: c)))
                // The gain ratio is scale-free, but both frames are taken to the unexposed scale
                // anyway so the p50 is the same scene percentile at both exposures.
                let gain = medianGain(frame.map { $0 / g }, none.map { $0 / g })
                gains[ev * 10 + c] = gain
                print(String(format: "CONTRAST · E%+.0f c=%+.0f · p50 增益 %.5f", ev, c, gain))
            }
        }
        for c in [-100.0, 50.0, 100.0] {
            guard let e0 = gains[c], let e2 = gains[20 + c] else { continue }
            XCTAssertEqual(e0.sign, e2.sign, "contrast=\(Int(c))：两曝光的 p50 增益必须同号")
            if e0 != 0 {
                XCTAssertEqual(e2, e0, accuracy: 0.02 * abs(e0),
                               "contrast=\(Int(c))：两曝光的 p50 增益比差必须 ≤ 2 %")
            }
        }
    }

    func testContrastGainMatchesTheClosedForm() throws {
        // 2026-10-30 (mainline): 147 的 contrast 归一化**已回滚**，这一条暂时不成立，原因是一个真正二选一的设计冲突：
        //   · 把 contrast 的枢轴搬去「未曝光刻度」可以让 contrast 与 exposure 可交换（审计 §2 #3，p50 0.849→1.510 方向翻转）；
        //   · 但 `s1_8_contrast` 只能按**文档级**曝光增益归一，而蒙版里的局部曝光是逐像素增益，于是
        //     `LocalColorStageTests.testLocalExposureLandsInTheSameDomainAsGlobalExposure` 会退回差 4 码
        //     （079 的「同一滑杆在蒙版内外同义」是用户可见承诺，比可交换性更硬）。
        //   → 保留 079、放弃这条可交换性，并把决定记录在 `docs/tasks/QUEUE.md`（147 条目）+ 审计报告 §2 #3。
        throw XCTSkip("147 reverted the contrast normalisation: it trades 079's masked-vs-global equality for commutativity; decision pending")
        // A flat grey with `s = 2` EV above the pivot: the guided filter's base is the constant
        // itself, so the coarse term is exact and the closed form is `2^((k_c − 1) s)`.
        let pivot = MultiscaleContrast.pivotEV
        let s = 2.0
        let grey0 = pow(2.0, pivot + s)
        let t = 0.5
        let kCoarse = pow(2.0, MultiscaleContrast.coarseWeight * t)
        let closed = pow(2.0, (kCoarse - 1) * s)
        let graph = try makeGraph(grey(grey0), identity: "eq-contrast-closed-form")
        var measured: [Double] = []
        for ev in [0.0, 2.0] {
            let g = pow(2.0, ev)
            let base = luma(try linearRender(graph, edit(exposure: ev)))
            let plus = luma(try linearRender(graph, edit(exposure: ev, contrast: t * 100)))
            // The centre pixel of a flat frame is the same everywhere; p50 keeps it robust to edges.
            let gain = medianGain(plus.map { $0 / g }, base.map { $0 / g })
            measured.append(gain)
            print(String(format: "CLOSED · E%+.0f · measured %.5f · closed %.5f · diff %+.3f%%",
                         ev, gain, closed, (gain / closed - 1) * 100))
            XCTAssertEqual(gain, closed, accuracy: 0.005 * closed,
                           "E \(Int(ev))：实测 contrast 增益必须等于闭式 2^((k_c−1)s)（≤0.5%）")
        }
        XCTAssertEqual(measured[1], measured[0], accuracy: 0.02 * measured[0],
                       "闭式增益在两曝光间必须相同")
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
        "contrast·-100": "2612acb3f49e493e15694a491c96736972b8b52a870610a0114a086ee601ca14",
        "contrast·-50": "70dbae57785430f3dee6042a1f17a96751ab861b86d9afeb0df02145f805d378",
        "contrast·50": "db75c0a43f3ce746f54479eb10ced5898b74a3e606905b9a1b11bdf9e1742d1d",
        "contrast·100": "914849e5602179a5722dd5a5cc0527b7a5203589784afd93a21550fd9525a947",
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
                           "147 不许动 E = 0 的 contrast（g = 1 必须是逐字节恒等）")
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
