import XCTest
import Metal
@testable import PhotonsCore

/// 派单 498 — 自动颜色从 1 个自由度升成 2 个：p50 → vibrance，p95 → saturation，
/// 裁剪护栏与肤色带护栏，以及「0+0 不生效」的标定回归。
final class AutoColor498Tests: XCTestCase {

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

    /// 70 % muted at half the p50 target, 30 % at 70 % of the p95 target: the median is below the
    /// p50 target and the tail is below the p95 target, so both degrees of freedom have work to do.
    private func typicalGrid() -> LinearSample {
        let low = AutoColor.targetChromaP50 * 0.50
        let high = AutoColor.targetChromaP95 * 0.40
        return sample(60, 40) { x, y in
            let tail = (x + y) % 10 >= 7
            // 2.4 rad ≈ 137°: deliberately outside the 50°–70° skin band.
            return oklch(0.62, tail ? high : low, 2.4)
        }
    }

    // MARK: - constants / reverse gate 3

    /// Both targets are calibrated constants, not the old 452 median. Reverting `targetChromaP50` to
    /// 0.0219 must make the "typical picture moves" assertion red — this is that assertion.
    func testTargetsAreTheCalibratedConstants() {
        XCTAssertGreaterThan(AutoColor.targetChromaP50, 0.0219,
                             "498 的 vibrance 目标是库的 p70，必须高于 452 的 p50 0.0219")
        XCTAssertGreaterThan(AutoColor.targetChromaP95, 0,
                             "498 的 saturation 目标是库的 p85 of chromaP95")
        XCTAssertEqual(AutoColor.defaultTarget, AutoColor.targetChromaP50,
                       "旧名字必须指向新标定，不能仍是 0.0219")
        XCTAssertEqual(AutoColor.maxVibrance, 60)
        XCTAssertEqual(AutoColor.maxSaturation, 25)
        XCTAssertEqual(AutoColor.maxNewClippedFraction, 0.001,
                       "票面允许 ≤0.1% 新增裁剪；护栏仍优先于观感")

        // A picture at the old 0.0219 median is below the new p70 target: the old target returned
        // 0, the new one must return a positive lift.
        let grid = sample(40, 30) { _, _ in oklch(0.62, 0.022, 0.9) }
        let m = AutoColor.metrics(from: grid)
        XCTAssertGreaterThan(AutoColor.plan2D(m).vibrance, 0,
                             "把 targetChromaP50 改回 0.0219 ⇒ 这条必红")
    }

    // MARK: - two degrees of freedom

    func testTypicalPictureMovesBothSlidersAndLandsNearTheTargets() {
        let grid = typicalGrid()
        let m = AutoColor.metrics(from: grid)
        let plan = AutoColor.plan2D(m)
        print(String(format: "498 TYPICAL · p50 %.4f p95 %.4f → v %.2f s %.2f "
                     + "(unguarded %.2f) · predicted p50 %.4f p95 %.4f",
                     m.chromaP50, m.chromaP95, plan.vibrance, plan.saturation,
                     plan.unguardedSaturation, plan.predictedChromaP50, plan.predictedChromaP95))
        XCTAssertGreaterThan(plan.vibrance, 0, "p50 低于目标 ⇒ vibrance 必须动")
        XCTAssertGreaterThan(plan.saturation, 0, "p95 低于目标 ⇒ saturation 必须动")
        XCTAssertLessThanOrEqual(plan.vibrance, AutoColor.maxVibrance)
        XCTAssertLessThanOrEqual(plan.saturation, AutoColor.maxSaturation)
        XCTAssertGreaterThan(plan.predictedChromaP50, AutoColor.targetChromaP50 * 0.95)
        XCTAssertLessThan(plan.predictedChromaP50, AutoColor.targetChromaP50 * 1.05)
        XCTAssertLessThanOrEqual(plan.predictedChromaP95, AutoColor.targetChromaP95 * 1.05)

        // The kernel simulation agrees with the plan's prediction, not just with itself.
        let after = render(grid, vibrance: plan.vibrance, saturation: plan.saturation)
        let m2 = AutoColor.metrics(from: after)
        print(String(format: "498 TYPICAL AFTER · p50 %.4f p95 %.4f (targets %.4f / %.4f)",
                     m2.chromaP50, m2.chromaP95,
                     AutoColor.targetChromaP50, AutoColor.targetChromaP95))
        XCTAssertGreaterThan(m2.chromaP50, AutoColor.targetChromaP50 * 0.95)
        XCTAssertLessThan(m2.chromaP50, AutoColor.targetChromaP50 * 1.05)
        XCTAssertLessThanOrEqual(m2.chromaP95, AutoColor.targetChromaP95 * 1.05)
    }

    /// Reverse gate 1: drop the `s` term and the p95 assertion must fail. This is the picture the
    /// `plan` (vibrance only) leaves behind versus the 2-D plan.
    func testDroppingSaturationMissesTheP95Target() {
        let grid = typicalGrid()
        let m = AutoColor.metrics(from: grid)
        let plan = AutoColor.plan2D(m)
        let withoutS = render(grid, vibrance: plan.vibrance, saturation: 0)
        let withS = render(grid, vibrance: plan.vibrance, saturation: plan.saturation)
        let p95Without = AutoColor.metrics(from: withoutS).chromaP95
        let p95With = AutoColor.metrics(from: withS).chromaP95
        print(String(format: "498 REVERSE s · p95 without s %.4f · with s %.4f · target %.4f",
                     p95Without, p95With, AutoColor.targetChromaP95))
        XCTAssertLessThan(p95Without, AutoColor.targetChromaP95 * 0.95,
                          "去掉 s 项 ⇒ p95 断言必红")
        XCTAssertLessThanOrEqual(p95With, AutoColor.targetChromaP95 * 1.05)
    }

    func testAlreadySaturatedPictureGetsZeroAndZero() {
        let c = AutoColor.targetChromaP95 * 1.5
        let grid = sample(40, 30) { _, _ in oklch(0.62, c, 0.9) }
        let m = AutoColor.metrics(from: grid)
        let plan = AutoColor.plan2D(m)
        print(String(format: "498 ALREADY · p50 %.4f p95 %.4f → v %.2f s %.2f",
                     m.chromaP50, m.chromaP95, plan.vibrance, plan.saturation))
        XCTAssertEqual(plan.vibrance, 0, accuracy: 1e-9, "只升不降")
        XCTAssertEqual(plan.saturation, 0, accuracy: 1e-9, "只升不降")
    }

    func testGreyPictureGetsZeroAndZero() {
        let grid = sample(40, 30) { _, _ in (0.18, 0.18, 0.18) }
        let m = AutoColor.metrics(from: grid)
        let plan = AutoColor.plan2D(m)
        XCTAssertEqual(plan.vibrance, 0, accuracy: 1e-12)
        XCTAssertEqual(plan.saturation, 0, accuracy: 1e-12)
        XCTAssertEqual(plan.newClippedPixels, 0)
    }

    // MARK: - clipping guard / reverse gate 2

    func testClippingGuardRefusesNewClippedPixels() {
        // Half muted, half a near-clamp red. Without the guard the tail does not need much `s` to
        // cross 1.0, so the unguarded plan would clip; the guarded plan must not.
        let grid = sample(60, 40) { x, y in
            (x + y) % 2 == 0 ? oklch(0.62, AutoColor.targetChromaP50 * 0.5, 2.4)
                             : (0.85, 0.075, 0.075)
        }
        let m = AutoColor.metrics(from: grid)
        let plan = AutoColor.plan2D(m, targetP95: 0.50)
        let clippedBefore = clippedCount(m)
        let unguarded = render(grid, vibrance: plan.vibrance,
                               saturation: plan.unguardedSaturation)
        let clippedUnguarded = clippedCount(AutoColor.metrics(from: unguarded))
        let guarded = render(grid, vibrance: plan.vibrance, saturation: plan.saturation)
        let clippedAfter = clippedCount(AutoColor.metrics(from: guarded))
        print(String(format: "498 CLIP · v %.2f unguarded s %.2f → clipped %d · guarded s %.2f → clipped %d · skin %+.1f%%",
                     plan.vibrance, plan.unguardedSaturation, clippedUnguarded,
                     plan.saturation, clippedAfter, plan.skinChromaChange * 100))
        XCTAssertGreaterThan(clippedUnguarded, clippedBefore,
                             "去掉裁剪护栏 ⇒ 过冲夹具必红")
        XCTAssertLessThanOrEqual(plan.saturation, plan.unguardedSaturation,
                                 "护栏只能把 s 调小")
        let budget = Int((AutoColor.maxNewClippedFraction * Double(m.sampleCount)).rounded(.down))
        XCTAssertLessThanOrEqual(plan.newClippedPixels, budget)
        XCTAssertLessThanOrEqual(clippedAfter - clippedBefore, budget,
                                 "新增裁剪必须落在 0.1% 预算内")
    }

    // MARK: - skin guard

    func testSkinBandChangeIsCappedAtTenPercent() {
        let grid = sample(60, 40) { _, _ in
            oklch(0.62, 0.06, 60 * .pi / 180)
        }
        let m = AutoColor.metrics(from: grid)
        let plan = AutoColor.plan2D(m, targetP95: 0.50)
        let vibranceOnly = render(grid, vibrance: plan.vibrance, saturation: 0)
        let after = render(grid, vibrance: plan.vibrance, saturation: plan.saturation)
        let m1 = AutoColor.metrics(from: vibranceOnly)
        let m2 = AutoColor.metrics(from: after)
        print(String(format: "498 SKIN · s %.2f (unguarded %.2f) · predicted change %+.1f%% · actual %+.1f%%",
                     plan.saturation, plan.unguardedSaturation,
                     plan.skinChromaChange * 100, skinChange(m1, m2) * 100))
        XCTAssertLessThanOrEqual(plan.saturation, plan.unguardedSaturation)
        XCTAssertLessThanOrEqual(plan.skinChromaChange, AutoColor.maxSkinChromaChange + 1e-9)
        XCTAssertLessThanOrEqual(skinChange(m1, m2), AutoColor.maxSkinChromaChange + 1e-9)
    }

    // MARK: - kernel simulation (exactly S3b)

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
