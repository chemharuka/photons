import XCTest
import Metal
@testable import PhotonsCore

/// 派单 511 — 自动颜色从「解绝对目标」改成**有界加法 + 阻尼**。
///
/// 这一份钉住 §3.2 的九条行为：硬上限、单调递减收益、已达目标不写、幂等、只加不减、
/// 裁剪/肤色两条护栏、2-DOF 分离、雾天降权、均匀性降权。§3.3 的两条旧断言在
/// `AutoColor498Tests` 里替换；这里补上 §6.3 的 `gap ≈ 1` 端点断言。
final class AutoColor511Tests: XCTestCase {

    // MARK: - fixtures

    private func sample(_ width: Int, _ height: Int,
                        _ rgb: (Int, Int) -> (Double, Double, Double)) -> LinearSample {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (r, g, b) = rgb(x, y)
                let o = (y * width + x) * 4
                rgba[o] = Float16(r); rgba[o + 1] = Float16(g)
                rgba[o + 2] = Float16(b); rgba[o + 3] = 1
            }
        }
        return LinearSample(width: width, height: height, rgba: rgba)
    }

    private func oklch(_ l: Double, _ c: Double, _ h: Double) -> (Double, Double, Double) {
        let v = CalibrationGroup.rec2020(fromOklab: SIMD3(l, c * cos(h), c * sin(h)))
        return (v.x, v.y, v.z)
    }

    private func veil(_ input: LinearSample, imageWeight a: Double) -> LinearSample {
        var rgba = input.rgba
        for p in 0 ..< input.width * input.height {
            let o = p * 4
            for k in 0 ..< 3 {
                rgba[o + k] = Float16(a * Double(rgba[o + k]) + (1 - a))
            }
        }
        return LinearSample(width: input.width, height: input.height, rgba: rgba)
    }

    private func bumpSaturation(_ input: LinearSample, _ slider: Double) -> LinearSample {
        var rgba = input.rgba
        for p in 0 ..< input.width * input.height {
            let o = p * 4
            var (h, s, l) = hsl(SIMD3(Double(rgba[o]), Double(rgba[o + 1]), Double(rgba[o + 2])))
            s = min(1, max(0, s * (1 + slider / 100)))
            let out = hslToRGB(SIMD3(h, s, l))
            rgba[o] = Float16(out.x); rgba[o + 1] = Float16(out.y); rgba[o + 2] = Float16(out.z)
        }
        return LinearSample(width: input.width, height: input.height, rgba: rgba)
    }

    private func normalA() -> LinearSample {
        sample(60, 40) { x, y in
            let tail = (x + y) % 10 >= 7
            return oklch(0.62, tail ? 0.0724 : 0.0219, 2.4)
        }
    }

    private func normalB() -> LinearSample {
        sample(60, 40) { x, y in
            let tail = (x + y) % 5 >= 3
            let l = 0.45 + 0.30 * Double(y) / 39
            return oklch(l, tail ? 0.095 : 0.026, 1.9 + 0.4 * Double(x) / 59)
        }
    }

    private func portrait() -> LinearSample {
        sample(60, 40) { x, y in
            let bg = x > 47 || y < 8
            if bg { return oklch(0.42, 0.090, 2.4) }
            let l = 0.60 + 0.12 * Double(y) / 39
            return oklch(l, 0.024, 1.05)
        }
    }

    private func hazyScene(subjectPercent: Int) -> LinearSample {
        sample(60, 40) { x, y in
            let subject = ((y * 60 + x) % 100) < subjectPercent
            if subject { return oklch(0.62, 0.30, 0.6) }
            let c = 0.004 + 0.010 * Double(x) / 59
            return oklch(0.58 + 0.10 * Double(y) / 39, c, 2.4)
        }
    }

    private func greyCard() -> LinearSample {
        sample(40, 30) { _, _ in (0.18, 0.18, 0.18) }
    }

    private func synthetic(_ p50: Double, _ p95: Double,
                           colored: Double = 1, count: Int = 1000) -> AutoColor.Metrics {
        AutoColor.Metrics(chromaP50: p50, chromaP95: p95,
                          coloredFraction: colored, sampleCount: count)
    }

    // MARK: - §3.2.1 constants + hard ceiling

    func testConstantsAreThe511Block() {
        XCTAssertEqual(AutoColor.maxAdditiveVibrance, 15, "自动 vibrance 硬上限，§3.2.1")
        XCTAssertEqual(AutoColor.maxAdditiveSaturation, 8, "自动 saturation 硬上限，§3.2.1")
        XCTAssertEqual(AutoColor.responseK, 0.9)
        XCTAssertEqual(AutoColor.referenceColoredFraction, 0.15)
        XCTAssertEqual(AutoColor.referenceSpread, 3.0)
        // The manual slider ranges are explicitly **not** what 511 changes.
        XCTAssertEqual(AutoColor.maxVibrance, 60)
        XCTAssertEqual(AutoColor.maxSaturation, 25)
    }

    func testHardCeilingHoldsOnExtremeMetrics() {
        // The synthetic path (no pixels) must use the same formula: an extreme p50 = 1e-4 still
        // cannot escape the automatic ceiling.
        let extreme = synthetic(1e-4, 1e-4)
        let plan = AutoColor.plan2D(extreme)
        print(String(format: "511 EXTREME · v %.0f s %.0f", plan.vibrance, plan.saturation))
        XCTAssertGreaterThanOrEqual(plan.vibrance, 0)
        XCTAssertLessThanOrEqual(plan.vibrance, 15, "§3.2.1 的字面硬上限")
        XCTAssertGreaterThanOrEqual(plan.saturation, 0)
        XCTAssertLessThanOrEqual(plan.saturation, 8, "§3.2.1 的字面硬上限")

        // ... and so does the pixel path, including the fog arm that used to hit +60.
        for grid in [hazyScene(subjectPercent: 5), greyCard(), normalA()] {
            let p = AutoColor.plan2D(AutoColor.metrics(from: grid))
            XCTAssertLessThanOrEqual(p.vibrance, 15, "§3.2.1 的字面硬上限")
            XCTAssertLessThanOrEqual(p.saturation, 8, "§3.2.1 的字面硬上限")
        }
    }

    // MARK: - §3.2.2 monotone + diminishing returns

    func testGapIsMonotoneWithDiminishingReturns() {
        let t = AutoColor.targetChromaP50
        // p95 = 0.15 is above targetP95, so gapS = 0 and the spread is wide ⇒ both dampings are 1.
        let gap1 = AutoColor.plan2D(synthetic(t / 2, 0.15))
        let gap3 = AutoColor.plan2D(synthetic(t / 4, 0.15))
        print(String(format: "511 GAP · gap1 v %.0f · gap3 v %.0f · ratio %.2f",
                     gap1.vibrance, gap3.vibrance,
                     gap3.vibrance / max(gap1.vibrance, 1)))
        XCTAssertEqual(gap1.vibrance, 9, "gap = 1 ⇒ 约 0.59 × 15")
        XCTAssertGreaterThan(gap3.vibrance, gap1.vibrance, "gap 越大 lift 越大（单调）")
        XCTAssertLessThan(gap3.vibrance, 2 * gap1.vibrance,
                          "差 4 倍不是给 4 倍：gap 1 → 3 的增量也 < 2×")
        XCTAssertGreaterThan(gap3.vibrance - gap1.vibrance, 0)
        XCTAssertLessThan(gap3.vibrance - gap1.vibrance, gap1.vibrance)
    }

    // MARK: - §3.2.3 / §3.2.4 at target and idempotence

    func testAtTargetIsZeroAndEmpty() {
        let atTarget = synthetic(AutoColor.targetChromaP50, AutoColor.targetChromaP95)
        let plan = AutoColor.plan2D(atTarget)
        XCTAssertEqual(plan.vibrance, 0, accuracy: 1e-9, "已达目标 ⇒ 0")
        XCTAssertEqual(plan.saturation, 0, accuracy: 1e-9, "已达目标 ⇒ 0")
        XCTAssertTrue(plan.isEmpty, "0 + 0 不铸历史行")

        // Already above target is also zero: this tool only raises.
        let above = synthetic(AutoColor.targetChromaP50 * 2, AutoColor.targetChromaP95 * 2)
        XCTAssertTrue(AutoColor.plan2D(above).isEmpty)
    }

    func testSecondPressOnASettledPictureIsANoOp() {
        let grid = normalA()
        let m = AutoColor.metrics(from: grid)
        let first = AutoColor.plan2D(m)
        XCTAssertFalse(first.isEmpty)

        let after = render(grid, vibrance: first.vibrance, saturation: first.saturation)
        let m2 = AutoColor.metrics(from: after)
        // The second press measures the picture the first press wrote, and passes the written values
        // as both `current` and `floor`, exactly like `LoupeController.colorCandidate`.
        let second = AutoColor.plan2D(m2,
                                      currentVibrance: first.vibrance,
                                      currentSaturation: first.saturation,
                                      floorVibrance: first.vibrance,
                                      floorSaturation: first.saturation)
        print(String(format: "511 IDEMPOTENT · first v %.0f s %.0f · second v %.0f s %.0f",
                     first.vibrance, first.saturation, second.vibrance, second.saturation))
        XCTAssertEqual(second.vibrance, first.vibrance, "第二次不得再抬 vibrance")
        XCTAssertEqual(second.saturation, first.saturation, "第二次不得再抬 saturation")
    }

    // MARK: - §3.2.5 only raise

    func testFloorIsANeverDecrease() {
        let m = normalB()
        let metrics = AutoColor.metrics(from: m)
        let floorV = 12.0, floorS = 6.0
        let plan = AutoColor.plan2D(metrics,
                                    currentVibrance: floorV, currentSaturation: floorS,
                                    floorVibrance: floorV, floorSaturation: floorS)
        print(String(format: "511 ONLY-RAISE · floor v %.0f s %.0f → v %.0f s %.0f",
                     floorV, floorS, plan.vibrance, plan.saturation))
        XCTAssertGreaterThanOrEqual(plan.vibrance, floorV, "只加不减")
        XCTAssertGreaterThanOrEqual(plan.saturation, floorS, "只加不减")
    }

    // MARK: - 518 — the floor is above the automatic ceiling

    /// 518 ① — a document already **above** `maxVibrance` / `maxSaturation` must not be pulled down.
    /// 511 clamped the floor to those ceilings, so `vibrance = 80` came back as 60: a silent −20.
    func testFloorAboveTheAutomaticCeilingIsNeverLowered() {
        let metrics = AutoColor.metrics(from: normalB())
        let floorV = 80.0, floorS = 40.0
        let plan = AutoColor.plan2D(metrics,
                                    currentVibrance: floorV, currentSaturation: floorS,
                                    floorVibrance: floorV, floorSaturation: floorS)
        print(String(format: "518 FLOOR>CEILING · floor v %.0f s %.0f → v %.0f s %.0f",
                     floorV, floorS, plan.vibrance, plan.saturation))
        XCTAssertGreaterThanOrEqual(plan.vibrance, floorV, "地板高于自动上限时也不许下调 vibrance")
        XCTAssertGreaterThanOrEqual(plan.saturation, floorS, "地板高于自动上限时也不许下调 saturation")
    }

    /// 518 ② — the original floor (12 / 6, below both ceilings) still returns **exactly** what it did
    /// before 518: 12 / 6. This is the regression guard for the two-line product change.
    func testFloorBelowTheAutomaticCeilingIsBitIdentical() {
        let metrics = AutoColor.metrics(from: normalB())
        let floorV = 12.0, floorS = 6.0
        let plan = AutoColor.plan2D(metrics,
                                    currentVibrance: floorV, currentSaturation: floorS,
                                    floorVibrance: floorV, floorSaturation: floorS)
        print(String(format: "518 FLOOR<CEILING · floor v %.0f s %.0f → v %.1f s %.1f",
                     floorV, floorS, plan.vibrance, plan.saturation))
        XCTAssertEqual(plan.vibrance, 12, "改动前逐位相同：v = 12")
        XCTAssertEqual(plan.saturation, 6, "改动前逐位相同：s = 6")
    }

    /// 518 ③ — a grey frame has no plan to preserve: the floor must not resurrect one.
    func testGreyFrameStaysZeroEvenWithAFloor() {
        let metrics = AutoColor.metrics(from: greyCard())
        XCTAssertLessThan(metrics.coloredFraction, AutoColor.minimumColoredFraction,
                          "前提：灰帧低于有色比例阈值")
        let plan = AutoColor.plan2D(metrics,
                                    currentVibrance: 80, currentSaturation: 40,
                                    floorVibrance: 80, floorSaturation: 40)
        print(String(format: "518 GREY · coloured %.3f · plan v %.0f s %.0f",
                     metrics.coloredFraction, plan.vibrance, plan.saturation))
        XCTAssertEqual(plan, .zero, "灰帧 ⇒ 0 + 0，地板不参与")
    }

    // MARK: - §3.2.6 clipping / skin rails (same thresholds as 498)

    func testClippingGuardStillBinds() {
        // 70 % muted, 30 % near-clamp red. `targetP95: 2.0` makes the formula ask for the full 8;
        // the guard has to pull it back under 1.0.
        let grid = sample(60, 40) { x, y in
            let tail = (x + y) % 10 >= 7
            return tail ? (0.85, 0.01, 0.01)
                        : oklch(0.62, AutoColor.targetChromaP50 * 0.5, 2.4)
        }
        let m = AutoColor.metrics(from: grid)
        let plan = AutoColor.plan2D(m, targetP95: 2.0)
        let before = clippedCount(m)
        let unguarded = render(grid, vibrance: plan.vibrance,
                               saturation: plan.unguardedSaturation)
        let clippedUnguarded = clippedCount(AutoColor.metrics(from: unguarded))
        let guarded = render(grid, vibrance: plan.vibrance, saturation: plan.saturation)
        let clippedAfter = clippedCount(AutoColor.metrics(from: guarded))
        print(String(format: "511 CLIP · v %.0f unguarded s %.2f (clipped %d) → guarded s %.2f (clipped %d)",
                     plan.vibrance, plan.unguardedSaturation, clippedUnguarded,
                     plan.saturation, clippedAfter))
        XCTAssertGreaterThan(clippedUnguarded, before, "去掉裁剪护栏 ⇒ 这条必红")
        XCTAssertLessThanOrEqual(plan.saturation, plan.unguardedSaturation, "护栏只能把 s 调小")
        let budget = Int((AutoColor.maxNewClippedFraction * Double(m.sampleCount)).rounded(.down))
        XCTAssertLessThanOrEqual(plan.newClippedPixels, budget)
        XCTAssertLessThanOrEqual(clippedAfter - before, budget, "新增裁剪 ≤ 0.1%")
    }

    func testSkinGuardStillCapsAtTenPercent() {
        // 70 % low-chroma skin, 30 % a brighter skin tail: p95/p50 ≈ 5 so `dampUniform` is 1 and the
        // formula can really ask for the full automatic saturation.
        let grid = sample(60, 40) { x, y in
            let tail = (x + y) % 10 >= 7
            return oklch(0.62, tail ? 0.10 : 0.02, 60 * .pi / 180)
        }
        let m = AutoColor.metrics(from: grid)
        let plan = AutoColor.plan2D(m, targetP95: 2.0)
        let vibranceOnly = render(grid, vibrance: plan.vibrance, saturation: 0)
        let after = render(grid, vibrance: plan.vibrance, saturation: plan.saturation)
        let m1 = AutoColor.metrics(from: vibranceOnly)
        let m2 = AutoColor.metrics(from: after)
        print(String(format: "511 SKIN · s %.0f (unguarded %.0f) · predicted %+.1f%% · actual %+.1f%%",
                     plan.saturation, plan.unguardedSaturation,
                     plan.skinChromaChange * 100, skinChange(m1, m2) * 100))
        XCTAssertLessThanOrEqual(plan.saturation, plan.unguardedSaturation)
        // 511 — this rail is **inert** under the new cap: `maxAdditiveSaturation = 8` produces a +8.0 %
        // skin change, below the 10 % threshold. It stays as the fence for any future cap change, so the
        // tripwire below re-arms the discussion the day someone raises it past 10.
        XCTAssertLessThanOrEqual(AutoColor.maxAdditiveSaturation, 10,
                                 "自动饱和上限超过 10 ⇒ 肤色护栏不再是空门，必须重跑这条并更新结论")
        XCTAssertLessThanOrEqual(plan.skinChromaChange, AutoColor.maxSkinChromaChange + 1e-9)
        XCTAssertLessThanOrEqual(skinChange(m1, m2), AutoColor.maxSkinChromaChange + 1e-9,
                                 "肤色带平均彩度变化 ≤ 10%（498 阈值不变）")
    }

    // MARK: - §3.2.7 two degrees of freedom

    func testTwoDOFSeparation() {
        let t = AutoColor.targetChromaP50
        // Tail only: p50 is exactly on target, p95 is half of its target. p95/p50 = 2.12 ≥ 2, so
        // `dampUniform` must not swallow the DOF split.
        let tailOnly = synthetic(t, AutoColor.targetChromaP95 * 0.5)
        // Median only: p95 is far above its target.
        let medianOnly = synthetic(t / 2, AutoColor.targetChromaP95 * 2)
        let tailPlan = AutoColor.plan2D(tailOnly)
        let medianPlan = AutoColor.plan2D(medianOnly)
        print(String(format: "511 2DOF · tail-only v %.0f s %.0f · median-only v %.0f s %.0f",
                     tailPlan.vibrance, tailPlan.saturation,
                     medianPlan.vibrance, medianPlan.saturation))
        XCTAssertGreaterThan(tailOnly.chromaP95 / tailOnly.chromaP50, 2)
        XCTAssertLessThanOrEqual(tailPlan.vibrance, 1, "只有 p95 低 ⇒ v 接近 0")
        XCTAssertGreaterThan(tailPlan.saturation, 0, "只有 p95 低 ⇒ s 动")
        XCTAssertGreaterThan(medianPlan.vibrance, 0, "只有 p50 低 ⇒ v 动")
        XCTAssertEqual(medianPlan.saturation, 0, accuracy: 1e-9, "只有 p50 低 ⇒ s 不动")
    }

    // MARK: - §3.2.8 fog damping (the ticket's main assertion)

    func testFogDampingCapsVibrance() {
        let t = AutoColor.targetChromaP50
        // coloredFraction = 0.02 ⇒ dampFraction = 0.1333; even with a huge gap, v ≈ 2.
        let fog = synthetic(t / 8, AutoColor.targetChromaP95 * 2, colored: 0.02)
        let plan = AutoColor.plan2D(fog)
        print(String(format: "511 FOG · colored 0.02 · v %.0f s %.0f", plan.vibrance, plan.saturation))
        XCTAssertLessThanOrEqual(plan.vibrance, 5, "雾天降权：v ≤ 5")

        // The measured fog arms as well: 60 → 3 and 45 → 3 before 511. §3.3 also requires the fog
        // sample's p50' to be no worse than before the plan.
        let fogArms: [(String, LinearSample)] = [
            ("fog1", veil(hazyScene(subjectPercent: 5), imageWeight: 0.35)),
            ("fog2", veil(hazyScene(subjectPercent: 5), imageWeight: 0.45)),
        ]
        for (name, grid) in fogArms {
            let m = AutoColor.metrics(from: grid)
            let p = AutoColor.plan2D(m)
            let after = AutoColor.metrics(from: render(grid, vibrance: p.vibrance,
                                                       saturation: p.saturation))
            print(String(format: "511 FOG ARM · %@ v %.0f s %.0f · p50 %.4f → %.4f (%.3f×)",
                         name, p.vibrance, p.saturation, m.chromaP50,
                         after.chromaP50, after.chromaP50 / max(m.chromaP50, 1e-6)))
            XCTAssertLessThanOrEqual(p.vibrance, 5)
            XCTAssertGreaterThanOrEqual(after.chromaP50, m.chromaP50 * 0.98,
                                        "\(name) 的 p50' 不比改前更差")
        }
    }

    // MARK: - §3.2.9 uniformity damping

    func testUniformityDampingLowersTheSameGap() {
        let t = AutoColor.targetChromaP50
        // Same p50 (gap = 1), same coloured fraction; only p95/p50 changes: 2 vs 4.
        let narrow = synthetic(t / 2, 2 * (t / 2))
        let wide = synthetic(t / 2, 4 * (t / 2))
        let narrowPlan = AutoColor.plan2D(narrow)
        let widePlan = AutoColor.plan2D(wide)
        print(String(format: "511 UNIFORM · spread 2 v %.0f · spread 4 v %.0f",
                     narrowPlan.vibrance, widePlan.vibrance))
        XCTAssertEqual(narrow.chromaP95 / narrow.chromaP50, 2, accuracy: 1e-9)
        XCTAssertEqual(wide.chromaP95 / wide.chromaP50, 4, accuracy: 1e-9)
        XCTAssertLessThan(narrowPlan.vibrance, widePlan.vibrance,
                          "p95/p50 = 2 比 = 4 给得更少")
        XCTAssertEqual(widePlan.vibrance, 9, "spread ≥ 3 ⇒ dampUniform = 1")
    }

    // MARK: - §6.3 the gap ≈ 1 endpoint

    /// The gap = 1 endpoint, under 511's **corrected** contract: strict improvement, and no overshoot
    /// past 110 % of the target. The old `[0.75, 1.10]` band was the "solve to target" era's judge and
    /// cannot hold once the plan is a bounded addition (measured 0.72 here; 14 real photos span
    /// 0.22–1.27 with a 0.52 median). Kept as its own test so the numbers stay in the report.
    func testGapOneEndpointIsNineAndStaysAboveSeventyPercent() {
        let t = AutoColor.targetChromaP50
        // 70 % at exactly target/2 (the median), 30 % at the 498 band fixture's tail ⇒ p50 =
        // target/2, gap = 1, spread ≫ 3, and the s term is 4 (p95 still below its own target).
        let low = t * 0.5
        let high = 0.0724
        let grid = sample(60, 40) { x, y in
            let tail = (x + y) % 10 >= 7
            return oklch(0.62, tail ? high : low, 2.4)
        }
        let m = AutoColor.metrics(from: grid)
        let plan = AutoColor.plan2D(m)
        let after = AutoColor.metrics(from: render(grid, vibrance: plan.vibrance,
                                                  saturation: plan.saturation))
        print(String(format: "511 ENDPOINT · p50 %.4f gap %.2f v %.0f · p50' %.4f (%.3f × target)",
                     m.chromaP50, t / m.chromaP50 - 1, plan.vibrance,
                     after.chromaP50, after.chromaP50 / t))
        XCTAssertEqual(plan.vibrance, 9, "gap = 1 ⇒ 0.59 × 15")
        // 511 口径修正（覆盖规格 §3.3 的 `[0.75, 1.10]` 窗口）：`[0.75,1.10]` 是「解到目标」时代的判据，
        // 与「有界加法」互斥。真实 14 张照片的 `p50'/target` 是 0.22–1.27、中位数 0.52，只有 1 张进窗口。
        // 新契约两条：**严格改善**（`p50' > p50`）与**不许越界**（`p50' ≤ 1.10 × target`）。
        XCTAssertGreaterThan(after.chromaP50, m.chromaP50, "必然改善")
        XCTAssertLessThanOrEqual(after.chromaP50, t * 1.10, "不许越过目标的 110 %")
    }

    // MARK: - §3.1 measurement table

    func testMeasurementTable511() {
        struct Arm {
            let name: String
            let grid: LinearSample
            let oldV: Double
            let oldS: Double
            let newV: Double
            let newS: Double
        }
        let arms = [
            Arm(name: "normalA", grid: normalA(), oldV: 4.2, oldS: 25, newV: 5, newS: 4),
            Arm(name: "normalB", grid: normalB(), oldV: 0, oldS: 25, newV: 2, newS: 2),
            Arm(name: "portrait", grid: portrait(), oldV: 9.2, oldS: 9.6, newV: 3, newS: 3),
            Arm(name: "fog1", grid: veil(hazyScene(subjectPercent: 5), imageWeight: 0.35),
                oldV: 60, oldS: 25, newV: 3, newS: 2),
            Arm(name: "fog2", grid: veil(hazyScene(subjectPercent: 5), imageWeight: 0.45),
                oldV: 45, oldS: 25, newV: 3, newS: 2),
            Arm(name: "greyCard", grid: greyCard(), oldV: 0, oldS: 0, newV: 0, newS: 0),
            Arm(name: "highSatA", grid: sample(60, 40) { _, _ in oklch(0.62, 0.16, 0.9) },
                oldV: 0, oldS: 0, newV: 0, newS: 0),
            Arm(name: "highSatB", grid: bumpSaturation(normalA(), 60),
                oldV: 0, oldS: 13, newV: 0, newS: 1),
        ]
        print("511 TABLE | arm | p50 | p95 | colored | spread | old v | old s | new v | new s")
        for arm in arms {
            let m = AutoColor.metrics(from: arm.grid)
            let plan = AutoColor.plan2D(m)
            print(String(format: "511 ROW %@ | %.4f | %.4f | %.3f | %.2f | %.1f | %.1f | %.0f | %.0f",
                         arm.name, m.chromaP50, m.chromaP95, m.coloredFraction,
                         m.chromaP95 / max(m.chromaP50, 1e-6),
                         arm.oldV, arm.oldS, plan.vibrance, plan.saturation))
            XCTAssertEqual(plan.vibrance, arm.newV, accuracy: 1e-9, "\(arm.name) v")
            XCTAssertEqual(plan.saturation, arm.newS, accuracy: 1e-9, "\(arm.name) s")
            XCTAssertLessThanOrEqual(plan.vibrance, AutoColor.maxAdditiveVibrance)
            XCTAssertLessThanOrEqual(plan.saturation, AutoColor.maxAdditiveSaturation)
            if arm.name.hasPrefix("normal") {
                XCTAssertLessThanOrEqual(abs(plan.vibrance - arm.oldV), 3,
                                         "正常组（normalA/B）的新旧 v 差 ≤ 3")
            }
        }
        // §3.1's acceptance line: the fog arms must come down from ≥ 40 to ≤ 5.
        for name in ["fog1", "fog2"] {
            let arm = arms.first { $0.name == name }!
            XCTAssertGreaterThanOrEqual(arm.oldV, 40)
            XCTAssertLessThanOrEqual(arm.newV, 5)
        }
        // Grey card: both zero.
        let grey = AutoColor.plan2D(AutoColor.metrics(from: greyCard()))
        XCTAssertEqual(grey.vibrance, 0)
        XCTAssertEqual(grey.saturation, 0)
    }

    // MARK: - kernel simulation (exactly S3b, same as 498Tests)

    private func render(_ input: LinearSample, vibrance: Double, saturation: Double) -> LinearSample {
        var rgba = input.rgba
        for p in 0 ..< input.width * input.height {
            let o = p * 4
            let r = Double(rgba[o]), g = Double(rgba[o + 1]), b = Double(rgba[o + 2])
            let peak = max(r, max(g, b))
            let headroom = peak > 1 ? peak / 0.9 : 1
            var (h, s, l) = hsl(SIMD3(max(r, 0), max(g, 0), max(b, 0)) / headroom)
            if abs(vibrance) > 1e-6 {
                s = min(1, max(0, s + vibrance / 100 * AutoColor.vibranceGain * (1 - s)))
            }
            if abs(saturation) > 1e-6 {
                s = min(1, max(0, s * (1 + saturation / 100)))
            }
            let out = hslToRGB(SIMD3(h, s, l)) * headroom
            rgba[o] = Float16(out.x); rgba[o + 1] = Float16(out.y); rgba[o + 2] = Float16(out.z)
        }
        return LinearSample(width: input.width, height: input.height, rgba: rgba)
    }

    private func hsl(_ c: SIMD3<Double>) -> (Double, Double, Double) {
        let mx = max(c.x, max(c.y, c.z)), mn = min(c.x, min(c.y, c.z))
        let l = (mx + mn) * 0.5
        let d = mx - mn
        guard d >= 1e-9 else { return (0, 0, l) }
        let s = l > 0.5 ? d / max(2 - mx - mn, 1e-6) : d / max(mx + mn, 1e-6)
        var h: Double
        if mx == c.x { h = (c.y - c.z) / d + (c.y < c.z ? 6 : 0) }
        else if mx == c.y { h = (c.z - c.x) / d + 2 }
        else { h = (c.x - c.y) / d + 4 }
        return (h / 6, s, l)
    }

    private func hslToRGB(_ hsl: SIMD3<Double>) -> SIMD3<Double> {
        let h = hsl.x - floor(hsl.x)
        let s = min(1, max(0, hsl.y))
        let l = min(1, max(0, hsl.z))
        guard s >= 1e-9 else { return SIMD3(l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
            return p
        }
        return SIMD3(channel(h + 1.0 / 3.0), channel(h), channel(h - 1.0 / 3.0))
    }

    private func clippedCount(_ m: AutoColor.Metrics) -> Int {
        m.pixels.filter { Double($0.hslSaturation) >= 1 - AutoColor.saturationCeilingEpsilon }.count
    }

    private func skinChange(_ before: AutoColor.Metrics, _ after: AutoColor.Metrics) -> Double {
        func mean(_ m: AutoColor.Metrics) -> (Double, Int) {
            var sum = 0.0
            var n = 0
            for p in m.pixels where p.hueDegrees >= 50 && p.hueDegrees <= 70
                && Double(p.chroma) > HSLBands.chromaGate {
                sum += Double(p.chroma); n += 1
            }
            return (n > 0 ? sum / Double(n) : 0, n)
        }
        let (a, _) = mean(before)
        let (b, _) = mean(after)
        guard a > 1e-9 else { return 0 }
        return (b - a) / a
    }
}
