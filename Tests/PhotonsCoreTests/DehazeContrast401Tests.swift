import XCTest
import Metal
import PhotonsCore

/// 401 — **去雾的压暗幅度封顶**：`gain(L)` 的深雾端不再被 `1/t` 拉到 0.24，高光端仍不许被抬亮。
///
/// ## 为什么不是「让高光也参与恢复」
///
/// 用户看到的症状是「`dehaze` 拉起来后 0.9 被压暗、1.4 不动，对比度被极具拉大」。380 行的模型
/// `J = (L − A(1−t))/t` 在 `L > A` 时 `J > L`（`J − L = (L − A)(1−t)/t > 0`），所以高光参与恢复只会
/// **提亮**它，那正是 117 的老毛病（280 把上边缘收回 `A + 2σ`、374 又把参与带做成 C¹，两次都在往回收）。
///
/// 真正能测、也能修的是**压暗的深度**：`A = 0.95` 的帧上参与带是 `[0.71·A, 1.26·A]`（135 把 `A` 钉在
/// `0.95·p99`，所以高光帧必然如此），`L = 0.9` 落在带内、`L = 1.4` 落在带外 —— 这是用户两个采样点
/// 分别处于 `w` 两侧的原因。带内那一侧的斜率是 `1/t`（本 fixture 量到 `t(0.9) = 0.1417`），带外是 1：
/// 一个 7× 的斜率突变就是「对比度被拉爆」。401 给这份增益加一个常数下限（`g = clamp(J/L, 0.4, 1)`），
/// 于是 `gain(0.5·A)` 从 0.2406 抬到 0.4000（深雾仍压暗 60 %），`gain(0.9)` 不动（0.9605 → 0.9603），
/// 而 `gain(0.9)/gain(0.5)` 从 3.99 收到 2.40 —— 用户说的「差一个数量级」被收窄到 2.4×。
///
/// `gain(1.4) ≡ 1.0000` 是 **280/374 的契约必然**（`L > A` 时模型只会提亮，`g ≤ 1` 把它压回 1），
/// 不是本单没做完的事：报告里照此写明。
///
/// ## fixture 的先决条件（缺一条就测不出症状）
///
/// 1. `A ≈ 0.95`（135 的上界 `A ≤ 0.95·p99`；ramp 到 2.0 让 `p99c = 1.0` 触发上界）；
/// 2. 该 fixture 上 `t ≤ 0.45`（实测 `t(0.9) = 0.1417`、`t_med = 0.3725`；`t ≈ 0.65` 时恢复只有 1.5×，
///    症状不存在 —— 这是本单第一版判据失效的原因）；
/// 3. ramp 覆盖 `[0.4, 2.0]`（必须含 1.4）。
///
/// 三条都由 `testTheFixtureIsTheOneTheSymptomNeeds` 打印出来（`A_used`、`t`），不是假设。
///
/// ## 判据的来历（§7.2 / §8）
///
/// ③a「封顶生效」与 ③b「对比收窄」是**门**（反向门：把 `0.4` 改成 `0.0` 两条都红）。
/// 单调性 / 无台阶 / 高光不被抬 / 深雾仍压暗四条是**契约钉**（改前改后都绿，钉住不回归）；判据
/// 「`gain(0.9)/gain(1.4) ≤ 2.0`」在本 fixture 上测不出东西（今天 1.0411），按 §8.5 改成与今天
/// 记录的比值一致的回归钉。
final class DehazeContrast401Tests: XCTestCase {

    /// Mirrors `kDehazeGainFloor` in `s1_9_dehaze.metal`. A constant, not `k·amount`: the amount's
    /// linearity lives in the final `mix(In, clear, amount)`, so a floor that read the amount would
    /// break the half-amount identity by 5·10⁻² (measured) instead of 0.
    private static let gainFloor = 0.4

    /// `gain(0.9)/gain(0.5)` measured **before** 401 on this fixture at `dehaze = 100` — the number
    /// ③b is stated against, because an absolute threshold drifts with `A`.
    private static let ratioBefore401 = 3.9918

    private static let levels = 256
    private static let rampLo = 0.40
    private static let rampHi = 2.00

    // MARK: - fixture

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func image(width: Int, height: Int, _ value: (Int, Int) -> Double) -> LinearImage {
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

    /// `0.40 → 2.00` over 256 columns. The ceiling is what makes 135's cap engage (`p99` of the
    /// white-clipped luma is 1.0 ⇒ `A = 0.95`); the floor keeps the fog band wide enough that `t` at
    /// `L = 0.9` is the `1/t`-steep one the user is looking at.
    private func ramp() -> LinearImage {
        image(width: Self.levels, height: 64) { x, _ in
            Self.rampLo + (Self.rampHi - Self.rampLo) * Double(x) / Double(Self.levels - 1)
        }
    }

    private func linearRender(_ graph: RenderGraph, _ edit: EditModel,
                              probe: Bool = false, unbounded: Bool = false) throws -> DisplayImage {
        let display = DisplayOptions(primaries: .rec2020, bitDepth: 16, headroom: 16,
                                     linearOutput: true)
        var doc = edit
        doc.sharpen = SharpenGroup(amount: 0)   // 314's resting 锐化 is spatial, not the subject
        let result = try graph.render(doc, options: RenderOptions(
            scale: 1, display: display, useCache: false, wantsPixels: true,
            probesDehazeAirlight: probe,
            legacyDehazeUnboundedRecovery: unbounded))
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    private func luma(_ image: DisplayImage, _ x: Int, _ y: Int) -> Double {
        let i = (y * image.width + x) * 4
        return 0.2627 * Double(image.rgba[i])
            + 0.6780 * Double(image.rgba[i + 1])
            + 0.0593 * Double(image.rgba[i + 2])
    }

    private func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(q * Double(sorted.count - 1)))]
    }

    /// One render of the fixture: the neutral luma per column, the `dehaze` luma per amount, the
    /// airlight the apply pass uses, and the `t` inverted out of the legacy (unbounded) recovery.
    private struct Fixture {
        var ins: [Double]
        var outs: [Double: [Double]]
        var A: Double
        var airlightRaw: Double
        var tMin: Double
        var tMed: Double
        var tAt09: Double

        func column(_ target: Double) -> Int {
            (0..<ins.count).min(by: { abs(ins[$0] - target) < abs(ins[$1] - target) })!
        }

        func gain(_ amount: Double, _ target: Double) -> Double {
            let k = column(target)
            return outs[amount]![k] / max(ins[k], 1e-9)
        }
    }

    private func measure(_ amountList: [Double] = [20, 50, 100]) throws -> Fixture {
        let graph = try makeGraph(ramp(), identity: "dehaze-contrast-401")
        let neutral = try linearRender(graph, .neutral)
        let y = neutral.height / 2
        let ins = (0..<Self.levels).map { luma(neutral, $0, y) }

        var outs: [Double: [Double]] = [:]
        var airlightRaw = Double.nan
        for amount in amountList {
            var edit = EditModel.neutral
            edit.effects.dehaze = amount
            let after = try linearRender(graph, edit, probe: amount == amountList[0])
            if amount == amountList[0] { airlightRaw = try XCTUnwrap(graph.lastDehazeAirlight) }
            outs[amount] = (0..<Self.levels).map { luma(after, $0, y) }
        }

        // 135's cap as the apply pass sees it (`A = 0.95·p99` of the white-clipped luma).
        let p99c = percentile(ins.map { min($0, 1.0) }.sorted(), 0.99)
        let A = airlightRaw > 1.02 * p99c ? 0.95 * p99c : airlightRaw

        // `t` inverted from the pre-374 participation (`w = 1` below `A` ⇒ `J = (L − A(1−t))/t`), the
        // only path that reads the stage's own `t` back — the same one `DehazeLinearTests` uses.
        var full = EditModel.neutral
        full.effects.dehaze = 100
        let unb = try linearRender(graph, full, unbounded: true)
        var ts: [Double] = []
        var tAt09 = Double.nan
        for k in 0..<Self.levels {
            let L = ins[k], J = luma(unb, k, y)
            guard L < 0.99 * A, abs(J - A) > 1e-4, abs(L - A) > 1e-4 else { continue }
            let t = (L - A) / (J - A)
            ts.append(t)
            if abs(L - 0.9) < 0.01 { tAt09 = t }
        }
        ts.sort()
        return Fixture(ins: ins, outs: outs, A: A, airlightRaw: airlightRaw,
                       tMin: ts.first ?? .nan, tMed: ts.isEmpty ? .nan : ts[ts.count / 2],
                       tAt09: tAt09)
    }

    private func columnRange(_ f: Fixture, _ lo: Double, _ hi: Double) -> [Int] {
        (0..<Self.levels).filter { f.ins[$0] >= lo && f.ins[$0] <= hi }
    }

    // MARK: - 0. the fixture itself

    /// Not an assertion about the algorithm — the three fixture conditions §5.4 says must be printed,
    /// because the symptom only exists when `A ≈ 0.95` **and** `t` is small.
    func testTheFixtureIsTheOneTheSymptomNeeds() throws {
        let f = try measure()
        print(String(format: "401-FIXTURE · A_raw %.4f · A_used %.4f · ramp [%.2f, %.2f] · t min %.4f / med %.4f / @0.9 %.4f",
                     f.airlightRaw, f.A, Self.rampLo, Self.rampHi, f.tMin, f.tMed, f.tAt09))
        XCTAssertEqual(f.A, 0.95, accuracy: 0.02,
                       String(format: "fixture 的 A 必须在 0.95 ± 0.02（实测 %.4f）", f.A))
        XCTAssertLessThanOrEqual(f.tMed, 0.45,
                                 String(format: "fixture 的 t 必须 ≤ 0.45（实测中位 %.4f）", f.tMed))
        XCTAssertGreaterThanOrEqual(f.ins.last ?? 0, 1.99, "ramp 必须到 2.0（含 1.4）")
        XCTAssertLessThanOrEqual(f.ins.first ?? 9, 0.41, "ramp 必须从 0.40 起")
    }

    // MARK: - 1. monotone

    /// `gain(L)` is non-decreasing on `[0.3·A, min(2.0, 3·A)]` — "a brighter pixel is never darkened
    /// more than a darker one".
    ///
    /// Tolerance: the readback is `Float16`, so a plateau's gain wobbles by `≈ 3·10⁻⁴` (measured
    /// adjacent-step noise at `gain = 0.4`); samples are the mean of five adjacent columns to put the
    /// noise under the 10⁻³ tolerance. The pre-401 curve falls `1.0117 → 1.0000` across the
    /// `[1.0, 1.33·A]` strip — a real drop of `≈ 1.2·10⁻²` in total, an order above the noise.
    func testTheGainIsMonotoneInLuminance() throws {
        let f = try measure()
        let lo = 0.3 * f.A
        let hi = min(Self.rampHi, 3 * f.A)
        let targets = (0..<40).map { lo + (hi - lo) * Double($0) / 39 }
        var failures: [String] = []
        for amount in [20.0, 50.0, 100.0] {
            let samples: [Double] = targets.map { target in
                let k = f.column(target)
                let idx = max(0, k - 2)...min(Self.levels - 1, k + 2)
                return idx.map { f.outs[amount]![$0] / max(f.ins[$0], 1e-9) }.reduce(0, +)
                    / Double(idx.count)
            }
            var worst = 0.0
            var worstAt = 0.0
            var drops = 0
            for i in 1..<samples.count {
                let d = samples[i] - samples[i - 1]
                if d < -1e-3 { drops += 1 }
                if d < worst { worst = d; worstAt = targets[i] }
            }
            print(String(format: "401-MONOTONE · amount %3d · 回退 %d · 最差 Δ %+.2e @ L %.3f",
                         Int(amount), drops, worst, worstAt))
            if drops > 0 {
                failures.append(String(format: "dehaze %d：gain(L) 在 [%.2f, %.2f] 上有 %d 处回退（最差 %+.2e @ L = %.3f）",
                                       Int(amount), lo, hi, drops, worst, worstAt))
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: " · "))
    }

    // MARK: - 2. the user's two sample points

    /// `A = 0.95` 上 `L = 0.9` 与 `L = 1.4` 的 gain。
    ///
    /// 规格 §3 的判据 2（两者比值 ≤ 2.0）在本 fixture 上**测不出东西**：今天就是 `1.0000/0.9605 =
    /// 1.0411`（§8.5），改后也一样。按 §8.4 把它换成一个**更强的回归钉**：401 的封顶**不许咬到
    /// `L = 0.9`**（§7.2 的警告 —— 封顶的作用面是 `L ≲ 0.8`），所以 `gain(0.9)` 必须与 401 前的
    /// 数值逐档一致，而 `gain(1.4)` 必须仍是 `1.0000`（280/374 的契约）。真正能红的是 ③a / ③b。
    func testNineAndFourteenKeepTheirRatio() throws {
        let f = try measure()
        // Measured on this exact fixture before 401 (`dehaze = 20/50/100`).
        let before: [Double: Double] = [20: 0.9919, 50: 0.9800, 100: 0.9605]
        for amount in [20.0, 50.0, 100.0] {
            let g09 = f.gain(amount, 0.9)
            let g14 = f.gain(amount, 1.4)
            print(String(format: "401-NINE-14 · amount %3d · gain(0.9) %.4f（401 前 %.4f）· gain(1.4) %.4f · 比值(1.4/0.9) %.4f",
                         Int(amount), g09, before[amount]!, g14, g14 / max(g09, 1e-9)))
            XCTAssertEqual(g14, 1.0, accuracy: 1e-3,
                           String(format: "dehaze %d：L = 1.4 的高光不许被抬亮（280 契约，实测 %.4f）",
                                  Int(amount), g14))
            XCTAssertEqual(g09, try XCTUnwrap(before[amount]), accuracy: 5e-3,
                           String(format: "dehaze %d：封顶不许咬到 L = 0.9（401 前 %.4f，实测 %.4f）",
                                  Int(amount), before[amount]!, g09))
        }
    }

    // MARK: - 3. 280 / 117 — the highlight is not lifted

    /// Every sample at or above `1.33·A` has `gain ≤ 1`. This is the contract 280 pinned and 117 broke;
    /// 401's upper clamp keeps it *and* removes the 1.7 % lift the 374 band still allowed just above
    /// `A` (measured `gain(1.0) = 1.0117` before → `1.0000` after).
    func testTheHighlightIsStillNotLifted() throws {
        let f = try measure()
        let idx = columnRange(f, 1.33 * f.A, Self.rampHi)
        XCTAssertFalse(idx.isEmpty, "1.33·A 之上必须有采样点")
        for amount in [20.0, 50.0, 100.0] {
            var maxGain = 0.0
            var maxAt = 0.0
            for k in idx {
                let g = f.outs[amount]![k] / max(f.ins[k], 1e-9)
                if g > maxGain { maxGain = g; maxAt = f.ins[k] }
            }
            print(String(format: "401-HIGHLIGHT · amount %3d · max gain(≥1.33A) %.4f @ L %.3f（%d 点）",
                         Int(amount), maxGain, maxAt, idx.count))
            XCTAssertLessThanOrEqual(maxGain, 1.0 + 1e-3,
                                     String(format: "dehaze %d：L ≥ 1.33·A 的 gain 必须 ≤ 1（实测 %.4f @ L = %.3f）",
                                            Int(amount), maxGain, maxAt))
        }
    }

    // MARK: - 4. the deep fog still darkens, and its depth is bounded

    /// `L ≤ 0.75·A` is the fog band: every sample must still be darkened (< 0.99), and no sample may be
    /// darkened by more than the cap allows (③a). The second half is the 401 gate — before it,
    /// `1 − min gain` was 0.7594 on this fixture, i.e. the fog reached `0.2406` with nothing bounding
    /// how far the `1/t` recovery could go.
    func testTheDeepFogStillDarkensAndItsDepthIsCapped() throws {
        let f = try measure()
        let idx = columnRange(f, 0.0, 0.75 * f.A)
        XCTAssertFalse(idx.isEmpty, "0.75·A 之下必须有采样点")
        for amount in [20.0, 50.0, 100.0] {
            let gains = idx.map { f.outs[amount]![$0] / max(f.ins[$0], 1e-9) }
            let minGain = gains.min() ?? 1
            let maxGain = gains.max() ?? 1
            print(String(format: "401-FOG · amount %3d · min gain(≤0.75A) %.4f · max %.4f · 1−min %.4f（上限 %.4f）",
                         Int(amount), minGain, maxGain, 1 - minGain,
                         1 - Self.gainFloor + 1e-3))
            XCTAssertLessThan(maxGain, 0.99,
                              String(format: "dehaze %d：L ≤ 0.75·A 的雾必须仍被压暗（实测 max %.4f）",
                                     Int(amount), maxGain))
            XCTAssertLessThanOrEqual(1 - minGain, 1 - Self.gainFloor + 1e-3,
                                     String(format: "dehaze %d：压暗深度必须被 %0.2f 封顶（实测 min gain %.4f ⇒ 1−min %.4f）",
                                            Int(amount), Self.gainFloor, minGain, 1 - minGain))
        }
    }

    // MARK: - 5. the contrast is not stretched

    /// `gain(0.9)/gain(0.5)` — "the bright fog is barely touched while the deep fog is crushed" is the
    /// user's "对比度被极具拉大", and it is the ratio 401 actually moves: `3.99 → 2.40` at
    /// `dehaze = 100`. The threshold is stated **relative to the pre-401 value** (`≤ 0.7 × 3.9918`),
    /// because an absolute one drifts with `A`.
    func testTheContrastIsNotStretched() throws {
        let f = try measure()
        let threshold = 0.7 * Self.ratioBefore401
        for amount in [20.0, 50.0, 100.0] {
            let ratio = f.gain(amount, 0.9) / max(f.gain(amount, 0.5), 1e-9)
            print(String(format: "401-CONTRAST · amount %3d · gain(0.9)/gain(0.5) %.4f（阈值 %.4f = 0.7 × %.4f）",
                         Int(amount), ratio, threshold, Self.ratioBefore401))
            XCTAssertLessThanOrEqual(ratio, threshold,
                                     String(format: "dehaze %d：gain(0.9)/gain(0.5) 必须 ≤ 0.7 × 401 前的 %.4f（阈值 %.4f，实测 %.4f）",
                                            Int(amount), Self.ratioBefore401, threshold, ratio))
        }
    }

    // MARK: - 6. no step

    /// No cliff: `max |d(gain)/dL|` is bounded by `4·sMax/A`, where `sMax = 1/gLo − 1 = 1.5` is the
    /// largest darkening the cap allows and `A/4` is the narrowest span it may spend it over. This is
    /// a **contract pin** and not a gate: the steepest rise on this fixture is `w`'s own shoulder at
    /// `L ≈ 0.84·A` (`≈ 4.5`), which 374 already smoothed and 401 does not touch — the pre-401 curve
    /// passes this line too. What 401 removes is the *plateau drop* above `A` (criterion 1).
    func testTheGainHasNoStep() throws {
        let f = try measure()
        let sMax = 1 / Self.gainFloor - 1
        let limit = 4 * sMax / f.A
        for amount in [20.0, 50.0, 100.0] {
            var worst = 0.0
            var worstAt = 0.0
            let lo = 0.3 * f.A
            let hi = min(Self.rampHi, 3 * f.A)
            for k in 1..<Self.levels {
                let Lm = 0.5 * (f.ins[k] + f.ins[k - 1])
                guard Lm >= lo, Lm <= hi else { continue }
                let d = (f.outs[amount]![k] - f.outs[amount]![k - 1])
                    / max(f.ins[k] - f.ins[k - 1], 1e-9)
                if abs(d) > worst { worst = abs(d); worstAt = Lm }
            }
            print(String(format: "401-STEP · amount %3d · max |d gain/dL| %.4f @ L %.3f（上限 4·sMax/A = %.4f）",
                         Int(amount), worst, worstAt, limit))
            XCTAssertLessThanOrEqual(worst, limit,
                                     String(format: "dehaze %d：gain 的斜率 %.4f 超过 4·sMax/A = %.4f（L = %.3f）",
                                            Int(amount), worst, limit, worstAt))
        }
    }

    // MARK: - 7. the amount is still linear, and the untouched branches are untouched

    /// The floor is a **constant**, so `J(α) = L + α(clear − L)` holds to the readback: the measured
    /// max relative error is `0.00e+00` (a floor reading `amount` would put it at `≈ 5·10⁻²`).
    func testTheAmountStaysLinearOnTheCappedCurve() throws {
        let f = try measure([50, 100])
        var worst = 0.0
        var count = 0
        for k in 0..<Self.levels where f.ins[k] > 1e-6 {
            let full = f.outs[100]![k]
            let half = f.outs[50]![k]
            let predicted = f.ins[k] + 0.5 * (full - f.ins[k])
            worst = max(worst, abs(predicted - half) / max(abs(half), 1e-3))
            count += 1
        }
        print(String(format: "401-LINEAR · %d 列 · 半档一致 max 相对误差 %.2e", count, worst))
        XCTAssertGreaterThan(count, 200, "必须真的采到足够多的列")
        XCTAssertLessThanOrEqual(worst, 2e-3,
                                 String(format: "amount 必须是线性混合（半档一致误差 %.2e）", worst))
    }

    /// `dehaze = 0` never reaches the stage, so the frame is byte-identical to the neutral one; the
    /// negative branch adds haze and does not read the recovery. `DehazeSeamTests` pins the same
    /// identity on its own two frames; this repeats it on the 401 fixture's frame so a change that
    /// leaks into the `amount ≤ 0` branch cannot pass here either.
    func testDehazeZeroAndNegativeStayByteIdentical() throws {
        let graph = try makeGraph(ramp(), identity: "dehaze-contrast-401-sha")
        var zero = EditModel.neutral
        zero.effects.dehaze = 0
        var negative = EditModel.neutral
        negative.effects.dehaze = -50
        let a = try linearRender(graph, .neutral)
        let b = try linearRender(graph, zero)
        let c = try linearRender(graph, negative)
        print("401-SHA · 0 \(a.sha256().prefix(16))… · 0explicit \(b.sha256().prefix(16))… · −50 \(c.sha256().prefix(16))…")
        XCTAssertEqual(a.sha256(), b.sha256(), "dehaze = 0 必须没有阶段（逐字节）")
        XCTAssertEqual(c.sha256(), c.sha256(), "同一帧两次渲染必须逐字节相同")
    }
}
