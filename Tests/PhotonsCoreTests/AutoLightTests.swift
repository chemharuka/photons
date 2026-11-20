import XCTest
import Metal
@testable import PhotonsCore

/// 派单 422 — 明暗 · 自动调节.
///
/// The algorithm is `AutoLight.plan` (pure) and the wiring is `LoupeController.autoLight()`; this file
/// holds both halves plus the acceptance's two hard requirements:
///
///   · **the criterion is texture loss, and it is measured** (§0c/§4.2) — the test computes the loss on
///     the shipping pipeline and asserts the shipped threshold sits between the two sliders' families;
///   · **the slopes are re-measured after step 1** (§0d) — the test measures the 7× swing and shows the
///     0 EV table would mis-solve a +2 EV frame by an order of magnitude;
///   · **⑧a–⑧e go red** (§4.3) — each gate deletes one load-bearing line, and the assertion that
///     guards that line is asserted to fail *through the same code path the app runs*.
///
/// The pure half runs on synthetic grids (no GPU) so the arithmetic is testable everywhere; the
/// measured half skips when there is no RAW fixture or no Metal device, exactly like the rest of the
/// core suite.
final class AutoLightTests: XCTestCase {

    // MARK: - a synthetic picture

    /// A grid with a known shape: `dark` fraction at a low level, the rest a ramp, and a highlight band
    /// with a controllable amount of local contrast. Built so every percentile is computable by hand.
    private func grid(picture: [Float], width: Int, height: Int) -> AutoLight.Sample {
        AutoLight.Sample(width: width, height: height, luma: picture)
    }

    /// One synthetic frame at `0 EV`: half the frame at 0.05, half ramping 0.1 → 0.9.
    private func flatGrid(width: Int = 40, height: Int = 40) -> AutoLight.Sample {
        var luma = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                luma[y * width + x] = y < height / 2 ? 0.05 : Float(x) / Float(width) * 0.8 + 0.1
            }
        }
        return grid(picture: luma, width: width, height: height)
    }

    /// A **document model** the tests drive `plan` with: the plan's seven fields in, a real grid out.
    ///
    /// It is a stand-in for the pipeline and deliberately *first order*: 高光/白色 move p99, 中间调/阴影
    /// move p50/p10, 黑色 pulls a fraction of samples to zero, 对比 widens the p10…p90 span. The grid is
    /// laid out so `metrics()` computes every number from **pixels** — no statistic is handed in — which
    /// is what makes the pure tests exercise the same `Sample` arithmetic the shipping path does.
    ///
    /// Fidelity it does **not** have: it cannot fake the texture of a real photograph, so the tests that
    /// turn on the criterion inject `lossAtDepth:` instead of pretending this model has one.
    private struct Model {
        var baseP99: Double = 0.30
        /// **426d** — 大面积高光分位。exposure 的锚点现在是它（`p95 → broadHighlightTarget`）。
        var baseP95: Double = 0.24
        var baseP50: Double = 0.06
        var baseP10: Double = 0.03
        /// p99 per slider unit, at a given exposure (positive number).
        var highlightSlope: (Double) -> Double = { ev in 0.00128 * pow(2.0, ev * 1.45) }
        var whiteSlope: (Double) -> Double = { ev in 0.000999 * pow(2.0, ev * 1.0) }
        var separation: Double = 4.1
        /// Units of 黑色 the bottom needs before 0.1 % of the samples reach the floor.
        var blackNeed: Double = 40

        func sample(for edit: EditModel) -> AutoLight.Sample {
            let ev = edit.light.exposure
            let high = max(0, -edit.light.highlights) * highlightSlope(ev)
            let white = max(0, -edit.light.whites) * whiteSlope(ev)
            let p99 = max(0.02, baseP99 * pow(2.0, ev) - high - white)
            let p50 = min(0.9, baseP50 * pow(2.0, ev) * (1 + edit.light.midtones / 100 * 0.9))
            let p10 = min(p50, baseP10 * pow(2.0, ev) * (1 + edit.light.shadows / 100 * 0.9))
            // 黑色: the deepest fraction of the picture is pulled to the floor, exponentially.
            let depth = max(0, -edit.light.blacks) / max(blackNeed, 1)
            let floorFraction = min(0.5, depth * 0.001 * 4 + (depth > 1 ? (depth - 1) * 0.01 : 0))
            let pFloor = max(0, baseP10 * pow(2.0, ev) * pow(2.0, -depth * 3))

            // A **2-D** grid: `texture` takes a horizontal *and* a vertical first difference, so a
            // one-row grid would report 0 no matter what the document says.
            let w = 100, h = 10
            let n = w * h
            let zeros = min(n / 2, Int((floorFraction * Double(n)).rounded()))
            var luma = [Float](repeating: 0, count: n)
            let live = n - zeros
            // A monotone ramp over the live samples: pFloor → p10 → p50 → p95 → p99, so every
            // percentile `metrics()` reports is a value this model actually placed.
            //
            // **426d**: the p50→p99 leg is split at p95 because 曝光 now anchors on p95; without a
            // knot there, `baseP95` would only be an interpolation accident of `baseP99`.
            let p95 = max(p50, baseP95 * pow(2.0, ev) - high - white)
            for i in 0 ..< live {
                let t = Double(i) / Double(max(live - 1, 1))
                let v: Double
                switch t {
                case ..<0.11: v = pFloor + (p10 - pFloor) * (t / 0.11)
                case ..<0.56: v = p10 + (p50 - p10) * ((t - 0.11) / 0.45)
                case ..<0.95: v = p50 + (p95 - p50) * ((t - 0.56) / 0.39)
                default: v = p95 + (p99 - p95) * ((t - 0.95) / 0.05)
                }
                luma[i] = Float(max(0, v))
            }
            // The zeros sit at the **end**, so the ramp's own order is not disturbed by them.
            for i in live ..< n { luma[i] = 0 }
            return AutoLight.Sample(width: w, height: h, luma: luma)
        }
    }

    /// The same model with the criterion injected, for the tests that are about the *decision* rather
    /// than about measuring a photograph.
    private func run(_ edit: EditModel,
                     gates: AutoLight.Gates = AutoLight.Gates(),
                     model: Model = Model(),
                     lossAtDepth: ((Double) throws -> Double)? = nil) throws -> AutoLight.Plan {
        try AutoLight.plan(for: edit, gates: gates, lossAtDepth: lossAtDepth) { model.sample(for: $0) }
    }

    // MARK: - ① the texture criterion is measured, and 8 % sits between the two families

    /// §0c/§4.2 — on the **shipping pipeline**, 高光 costs several times what 白色 costs per unit of
    /// p99 movement, and the shipped 8 % threshold is crossed by 高光 at a real depth.
    ///
    /// This is the test that would have caught the first version: it asserts a *ratio*, not an area.
    func testTheCriterionSeparatesHighlightsFromWhitesPerUnitOfDarkening() throws {
        guard let url = rawFixture() else { throw XCTSkip("no RAW fixture") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try self.graph(url)
        var base = EditModel.neutral
        base.sharpen = SharpenGroup(amount: 0)
        base.light.exposure = 2
        let m = try graph.measureAutoLightSample(base).metrics()
        XCTAssertGreaterThan(m.p99, 1.0, "the fixture must actually be hot at +2 EV, else this proves nothing")
        XCTAssertGreaterThan(m.texture, 0, "the highlight region must have contrast to lose")

        var h = base
        h.light.highlights = -50
        let hm = try graph.measureAutoLightSample(h).metrics()
        var w = base
        w.light.whites = -50
        let wm = try graph.measureAutoLightSample(w).metrics()

        let hLoss = (m.texture - hm.texture) / m.texture
        let wLoss = (m.texture - wm.texture) / m.texture
        let hDelivered = m.p99 - hm.p99
        let wDelivered = m.p99 - wm.p99
        print(String(format: "422 CRITERION · 高光−50 loss %.2f%% delivers %.4f · 白色−50 loss %.2f%% delivers %.4f · ratio %.2f",
                     hLoss * 100, hDelivered, wLoss * 100, wDelivered, hLoss / max(wLoss, 1e-9)))

        XCTAssertGreaterThan(hLoss, AutoLight.highlightLossThreshold,
                             "高光 −50 必须越过 8% 判据，否则「切到白色」这条分支永不成立")
        XCTAssertGreaterThan(hLoss, wLoss * 1.5,
                             "高光每单位压暗必须比白色贵得多（§0c 的 3.32×），实际 \(hLoss / max(wLoss, 1e-9))×")
        // …and the criterion is crossed somewhere inside the travel, not at neither end.
        var shallow = base
        shallow.light.highlights = -10
        let sm = try graph.measureAutoLightSample(shallow).metrics()
        XCTAssertLessThan((m.texture - sm.texture) / m.texture, AutoLight.highlightLossThreshold,
                          "高光 −10 不该已经越过判据，否则算法一上手就切白色")
    }

    /// The literal formula (§0c's own words) is carried beside the shipped one, and the shipped one is
    /// the level-normalised number — with the measured reason.
    func testTheShippedTextureIsLevelNormalisedAndTheLiteralOneIsReportedBesideIt() throws {
        guard let url = rawFixture() else { throw XCTSkip("no RAW fixture") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try self.graph(url)
        var base = EditModel.neutral
        base.sharpen = SharpenGroup(amount: 0)
        let neutral = try graph.measureAutoLightSample(base).metrics()

        // Same slider, two exposures: the literal formula moves; the normalised one moves less.
        var atZero = base
        atZero.light.highlights = -50
        let lit0 = try graph.measureAutoLightSample(atZero).metrics()
        var hot = base
        hot.light.exposure = 2
        let hotBase = try graph.measureAutoLightSample(hot).metrics()
        hot.light.highlights = -50
        let lit2 = try graph.measureAutoLightSample(hot).metrics()

        let literal0 = (neutral.textureAbsolute - lit0.textureAbsolute) / neutral.textureAbsolute
        let literal2 = (hotBase.textureAbsolute - lit2.textureAbsolute) / hotBase.textureAbsolute
        let norm0 = (neutral.texture - lit0.texture) / neutral.texture
        let norm2 = (hotBase.texture - lit2.texture) / hotBase.texture
        print(String(format: "422 TEXTURE · 高光−50 literal %.1f%%@0EV → %.1f%%@+2EV (×%.1f) · normalised %.1f%% → %.1f%% (×%.1f)",
                     literal0 * 100, literal2 * 100, literal2 / max(literal0, 1e-9),
                     norm0 * 100, norm2 * 100, norm2 / max(norm0, 1e-9)))
        XCTAssertGreaterThan(norm0, 0, "the normalised texture must respond to the slider")
        XCTAssertGreaterThan(norm2, 0)
        XCTAssertNotEqual(literal0, 0)
        XCTAssertNotEqual(literal2, 0)
    }

    // MARK: - ② §0d: the slope swings 7×, and the table would be wrong

    /// §0d/§4.1 — 高光's p99 response is re-measured **at the exposure step 1 chose**, and the 0 EV table
    /// value is an order of magnitude off on a hot frame.
    func testTheHighlightSlopeSwingsWithExposureAndTheTableWouldBeWrong() throws {
        guard let url = rawFixture() else { throw XCTSkip("no RAW fixture") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try graph(url)
        var slopes: [Double] = []
        for ev in [0.0, 2.0, 3.0] {
            var base = EditModel.neutral
            base.sharpen = SharpenGroup(amount: 0)
            base.light.exposure = ev
            let m = try graph.measureAutoLightSample(base).metrics()
            var deep = base
            deep.light.highlights = -100
            let dm = try graph.measureAutoLightSample(deep).metrics()
            let slope = (m.p99 - dm.p99) / 100
            slopes.append(slope)
            print(String(format: "422 SLOPE · EV %+.0f · p99 %.4f → 高光−100 %.4f · %.5f per unit",
                         ev, m.p99, dm.p99, slope))
        }
        XCTAssertGreaterThan(slopes[0], 0)
        XCTAssertGreaterThan(slopes[1], slopes[0] * 3,
                             "§0d: 高光's slope must be several times steeper at +2 EV than at 0 EV, measured \(slopes)")
        XCTAssertGreaterThan(slopes[2], slopes[1] * 1.2, "+3 EV goes further again")
        // The shipped table is the 0 EV number, and the plan must not use it at a +2 EV operating point.
        XCTAssertEqual(AutoLight.zeroEVHighlightSlope, slopes[0], accuracy: 0.05,
                       "the ⑧e table must be the *measured* 0 EV slope, or the gate proves nothing")
        XCTAssertGreaterThan(abs(slopes[1] - AutoLight.zeroEVHighlightSlope) / slopes[1], 0.5,
                             "at +2 EV the table is off by more than half")
    }

    /// The plan's own report carries both numbers, and on a hot picture they disagree by a large factor.
    func testThePlanReportsTheMeasuredSlopeAndTheTableBesideIt() throws {
        var edit = EditModel.neutral
        edit.light.blackOffset = 0.005
        let plan = try run(edit)
        let r = plan.report
        // The model's slope at the plan's own exposure vs the 0 EV table.
        print(String(format: "422 SLOPE REPORT · measured %.5f · table %.5f · exposure %+.2f",
                     r.highlightSlope, r.tableHighlightSlope, r.exposureEV))
        XCTAssertGreaterThan(r.exposureEV, 0.5, "the fixture frame is dark; step 1 must lift it")
        XCTAssertGreaterThan(r.highlightSlope, r.tableHighlightSlope,
                             "at a positive exposure the measured slope must be steeper than the 0 EV table")
    }

    // MARK: - ③ 曝光's guard is the tail, and the anchor is the owner's habit

    /// 422 裁定 §5.1 (rework 3) — **old assertion, changed on purpose**:
    /// `p99 ≤ 1.0` (`AutoLight.p99Ceiling`) → `p99 == 1.5` (`p99WhiteTarget`) while the **tail stays
    /// proportionally close** (`p99.9/p99 ≤ 1.6`, `p999OverP99Ceiling`). Why it had to change twice: the
    /// verdict's calibration is "p99 lands at 1.5", a `p99 ≤ 1.0` guard contradicts it outright, and an
    /// *absolute* `p99.9 ≤ 2.0` guard still contradicts it (`2.0/1.5 = 1.333` is below the ratio four of
    /// the five owner frames actually have). The load-bearing constraint is the tail's **ratio**.
    func testExposureLandsOnTheOwnersHabitAndKeepsTheTailInsideTheGuard() throws {
        var edit = EditModel.neutral
        let plan = try run(edit)
        // **426d**: 锚点从 p99 换成 p95（大面积高光）；tail guard 已删除，改成断言它恒 0。
        XCTAssertEqual(plan.report.p95AfterExposure, AutoLight.broadHighlightTarget, accuracy: 0.08,
                       "p95 落在 \(AutoLight.broadHighlightTarget)（大面积高光目标），实测 \(plan.report.p95AfterExposure)")
        XCTAssertEqual(plan.report.exposureBackstops, 0, "426d 已删除 tail guard 回退，恒 0")
        print(String(format: "422 EXPOSURE · p99 %.4f → %+.2f EV → p99 %.4f (p99.9/p99 %.3f, 回退 %d, clip %.3f%%)",
                     plan.report.baseP99, plan.report.exposureEV, plan.report.p99AfterExposure,
                     plan.report.p999OverP99AfterExposure, plan.report.exposureBackstops,
                     plan.report.clippedHighAfterExposure * 100))
    }

    /// The exposure is a function of the picture's own p99: a darker frame gets more light, and the two
    /// are exactly `log2(target / p99)` apart.
    /// **426d — 旧断言，按新口径改写**: `p99 → 1.5` 已被废除（它等于「制造 1% 必然过白」）。
    ///
    /// 现在的曝光锚在**大面积高光** `p95 → broadHighlightTarget(1.1)`，理由见该常量的注释：
    /// 在 owner 五帧成品上反推 `log2(target / baseP95)`，1.1 与手调 EV 的中位差最小（0.21 档）。
    func testExposureIsTheLogOfThePicturesOwnP95() throws {
        for base in [0.15, 0.30, 0.45] {
            var model = Model()
            model.baseP95 = base
            let plan = try AutoLight.plan(for: EditModel.neutral) { model.sample(for: $0) }
            let expected = min(8, max(-4, log2(AutoLight.broadHighlightTarget / base)))
            // 容差 0.15 而不是 0.06：合成 grid 只有 100×10，p95 落在 ramp 的 0.95 结点附近，
            // 分位取整带来的偏差比真实照片大。reality check 在 owner 五帧上做（见 A④）。
            XCTAssertEqual(plan.report.exposureEV, (expected * 100).rounded(.down) / 100, accuracy: 0.15,
                           "p95 \(base) → 曝光 \(plan.report.exposureEV)，应在 \(expected) 附近")
        }
    }

    // MARK: - ④ the four steps produce a coherent plan

    func testThePlanIsTheStepsInOrder() throws {
        var edit = EditModel.neutral
        edit.light.blackOffset = 0.005
        let plan = try run(edit)
        let r = plan.report

        // 1 — 曝光 up.
        XCTAssertGreaterThan(plan.exposure, 0, "步骤 1：默认照片很暗，曝光先加")
        // 2 — 中间调/阴影 only补, never negative.
        XCTAssertGreaterThanOrEqual(plan.midtones, 0, "步骤 2 只补，不压")
        XCTAssertGreaterThanOrEqual(plan.shadows, 0)
        XCTAssertLessThanOrEqual(plan.midtones, AutoLight.midtoneCap)
        XCTAssertLessThanOrEqual(plan.shadows, AutoLight.shadowCap)
        // 3 — 高光 negative (it is a recovery), 白色 a co-tool at most.
        XCTAssertLessThanOrEqual(plan.highlights, 0, "步骤 3 的第一手段是压高光")
        XCTAssertGreaterThanOrEqual(plan.highlights, -100)
        XCTAssertLessThanOrEqual(plan.whites, 0)
        XCTAssertGreaterThanOrEqual(plan.whites, -AutoLight.whiteTravelEnd, "白色 有上限，不是 −100")
        XCTAssertLessThanOrEqual(r.textureLossHighlightsOnly, AutoLight.highlightLossThreshold,
                                "高光自己的纹理损失必须落在判据内，实测 \(r.textureLossHighlightsOnly)")
        // 4 — 黑色 negative, inside the travel.
        XCTAssertLessThanOrEqual(plan.blacks, 0)
        XCTAssertGreaterThanOrEqual(plan.blacks, -100)
        // 步骤 5（对比）— **422 裁定：不做**，所以它恒为 0，而不是「在 cap 以内」。
        XCTAssertEqual(plan.contrast, 0, "对比不做：plan.contrast 恒为 0，实际 \(plan.contrast)")
        print(String(format: "422 PLAN · EV %+.2f · 高光 %.0f 白色 %.0f · 中间调 %.0f 阴影 %.0f · 黑色 %.0f · 对比 %.0f (sep %.2f)",
                     plan.exposure, plan.highlights, plan.whites, plan.midtones, plan.shadows,
                     plan.blacks, plan.contrast, r.separationStops))
    }

    /// **The plan is one document write, and it does not touch `blackOffset`.**
    func testThePlanWritesSevenFieldsAndLeavesBlackOffsetAlone() throws {
        var edit = EditModel.neutral
        edit.light.blackOffset = 0.007
        edit.geometry.crop = .full
        let before = edit
        let plan = try run(edit)
        let after = plan.apply(to: edit)

        XCTAssertEqual(after.light.blackOffset, before.light.blackOffset,
                       "硬约束 1：自动调节只读 blackOffset，绝不写它")
        XCTAssertEqual(after.geometry, before.geometry, "几何不动")
        XCTAssertEqual(after.color, before.color, "颜色不动")
        XCTAssertEqual(after.effects, before.effects, "效果不动")
        // And the seven fields it does own are the plan's numbers, exactly.
        XCTAssertEqual(after.light.exposure, plan.exposure)
        XCTAssertEqual(after.light.contrast, plan.contrast)
        XCTAssertEqual(after.light.highlights, plan.highlights)
        XCTAssertEqual(after.light.midtones, plan.midtones)
        XCTAssertEqual(after.light.shadows, plan.shadows)
        XCTAssertEqual(after.light.whites, plan.whites)
        XCTAssertEqual(after.light.blacks, plan.blacks)
    }

    /// Step 1 zeroes 明暗 but keeps everything else — the plan is solved from the *decoded* picture, not
    /// from whatever the user had already dialled in.
    func testTheBaselineZeroesOnlyTheToneFields() throws {
        var edit = EditModel.neutral
        edit.light.exposure = 3
        edit.light.highlights = -80
        edit.light.blackOffset = 0.004
        edit.color.saturation = 25
        var seen: [EditModel] = []
        let model = Model()
        _ = try AutoLight.plan(for: edit) { document in
            seen.append(document)
            return model.sample(for: document)
        }
        let first = try XCTUnwrap(seen.first)
        XCTAssertEqual(first.light.exposure, 0, "the first measurement is the zeroed document")
        XCTAssertEqual(first.light.highlights, 0)
        XCTAssertEqual(first.light.blacks, 0)
        XCTAssertEqual(first.light.blackOffset, 0.004, "blackOffset 不属于 明暗，基线保留它")
        XCTAssertEqual(first.color.saturation, 25, "其他卡一个字段都不动")
    }

    /// Step 4 cancels `blackOffset`: the same picture with a bigger trim needs a deeper 黑色.
    func testStepFourCancelsTheBlackOffsetLift() throws {
        var bare = EditModel.neutral
        bare.light.blackOffset = 0
        var trimmed = EditModel.neutral
        trimmed.light.blackOffset = 0.008
        let a = try run(bare)
        let b = try run(trimmed)
        XCTAssertLessThan(b.blacks, a.blacks,
                          "blackOffset 0.008 把黑场抬起来了，黑色必须比没有偏移时更深（\(b.blacks) vs \(a.blacks)）")
        XCTAssertLessThan(b.report.blackCancelTerm, 0, "抵消项为负")
        print(String(format: "422 BLACKS · boff 0 → %.0f · boff 0.008 → %.0f (cancel %.0f)",
                     a.blacks, b.blacks, b.report.blackCancelTerm))
    }

    // MARK: - ⑤ ⑧a–⑧e: the five reverse gates
    //
    // Each gate makes one load-bearing line of `AutoLight.plan` inert. The test asserts the behaviour
    // that line buys — so if the line is deleted, or the gate stops being wired to it, the assertion
    // goes red. The criterion is injected (`lossAtDepth:`) because a GPU-free model cannot carry a real
    // photograph's texture; §4.2's *measurement* is asserted separately, on the pipeline, in
    // `testTheCriterionSeparatesHighlightsFromWhitesPerUnitOfDarkening`.

    /// A frame that needs a highlight pull: p99 = 0.30, so `log2(0.98/0.30)` = +1.7 EV, and after step 1
    /// the top still has to come down.
    private func hotEdit() -> EditModel {
        var edit = EditModel.neutral
        edit.light.blackOffset = 0.005
        return edit
    }

    /// The criterion "高光 costs 2 % of the region per unit", so the 8 % budget is spent by depth 4 —
    /// **高光 can take a token depth and no more**, and 白色 must be reached for the rest.
    private func expensiveHighlights() -> (Double) throws -> Double {
        { depth in min(0.99, depth * 0.02) }
    }

    /// The criterion "高光 costs almost nothing", so 高光 alone can finish and 白色 must stay 0.
    private func cheapHighlights() -> (Double) throws -> Double {
        { depth in depth * 0.00001 }
    }

    /// Sanity: the two fixtures really do disagree, so each gate's assertion is about the algorithm and
    /// not about a model that happens to sit on one side.
    func testTheTwoCriterionFixturesReachOppositeDecisions() throws {
        let expensive = try run(hotEdit(), lossAtDepth: expensiveHighlights())
        let cheap = try run(hotEdit(), lossAtDepth: cheapHighlights())
        print(String(format: "422 FIXTURE · expensive → 高光 %.0f 白色 %.0f · cheap → 高光 %.0f 白色 %.0f",
                     expensive.highlights, expensive.whites, cheap.highlights, cheap.whites))
        XCTAssertEqual(cheap.whites, 0, "判据说高光便宜 ⇒ 不用白色")
        XCTAssertLessThan(expensive.whites, 0, "判据说高光贵 ⇒ 必须用白色")
        XCTAssertGreaterThan(abs(cheap.highlights), abs(expensive.highlights),
                             "便宜时高光走得更深")
    }

    /// ⑧a — the criterion always says **0 % loss** ⇒ 白色 is **never** reached.
    ///
    /// The gate is not a stub here: the injected criterion is the *expensive* one, and only the gate flag
    /// makes it read 0. So this asserts the line the flag deletes, on a frame where the alternative
    /// (`testTheTwoCriterionFixturesReachOppositeDecisions`) demonstrably reaches 白色.
    func testGateAAlwaysZeroLossNeverReachesWhite() throws {
        // **Both halves in one test**, so that hard-coding the gate's mistake into the shipped path
        // breaks this test rather than only the gated line: the shipped plan must reach 白色 on this
        // frame, and the gated plan must not.
        // **441** — 这条门只钉「判据 → 白色」那一行；主体地板会先加中间调，改变 `settled` 的
        // 起点，把 441 的效应混进 ⑧a。两半都在关掉主体地板（⑧c）的状态下跑，门仍然证明
        // 「判据恒 0 ⇒ 白色 不启用」这一行是承重的。
        var noSubject = AutoLight.Gates()
        noSubject.collapsesSubjectTarget = true
        let shipped = try run(hotEdit(), gates: noSubject, lossAtDepth: expensiveHighlights())
        XCTAssertLessThan(shipped.whites, 0, "出货路径在本帧**必须**启用白色，否则本门无从谈起")

        var gates = AutoLight.Gates()
        gates.criterionAlwaysZeroLoss = true
        gates.collapsesSubjectTarget = true
        let gated = try run(hotEdit(), gates: gates, lossAtDepth: expensiveHighlights())
        XCTAssertEqual(gated.whites, 0, "⑧a：判据恒返 0 ⇒ 永不该启用白色，实际 \(gated.whites)")
        XCTAssertLessThan(gated.highlights, 0, "高光 仍然工作：\(gated.highlights)")
        XCTAssertEqual(gated.report.highlightBudget, abs(gated.highlights),
                             "判据恒 0 ⇒ 高光 的预算就是它走的全部，没有上限")
        print("422 GATE ⑧a · shipped whites \(shipped.whites) · gated whites \(gated.whites) 高光 \(gated.highlights)")
    }

    /// ⑧b — the criterion always says **99 %** ⇒ 白色 is **always** reached and 高光 never moves.
    func testGateBAlwaysFullLossAlwaysReachesWhite() throws {
        // Both halves: the shipped cheap frame needs **no** 白色, and the gated one cannot avoid it.
        let shipped = try run(hotEdit(), lossAtDepth: cheapHighlights())
        XCTAssertEqual(shipped.whites, 0, "判据说高光便宜 ⇒ 出货路径一步白色都不该走")
        XCTAssertLessThan(shipped.highlights, 0, "高光 承担全部")

        var gates = AutoLight.Gates()
        gates.criterionAlwaysFullLoss = true
        let gated = try run(hotEdit(), gates: gates, lossAtDepth: cheapHighlights())
        XCTAssertLessThan(gated.whites, 0, "⑧b：判据恒返 99% ⇒ 必须启用白色，实际 \(gated.whites)")
        XCTAssertEqual(gated.highlights, 0, "判据恒满 ⇒ 高光一步都不许走，实际 \(gated.highlights)")
        print("422 GATE ⑧b · shipped whites \(shipped.whites) 高光 \(shipped.highlights) · gated whites \(gated.whites) 高光 \(gated.highlights)")
    }

    /// ⑧c — step 4 ignores `blackOffset` ⇒ a trimmed picture gets the **un-trimmed** floor.
    func testGateCIgnoringBlackOffsetLosesTheCancellation() throws {
        var edit = EditModel.neutral
        edit.light.blackOffset = 0.008
        let shipped = try run(edit, lossAtDepth: cheapHighlights())
        var gates = AutoLight.Gates()
        gates.ignoresBlackOffset = true
        let gated = try run(edit, gates: gates, lossAtDepth: cheapHighlights())
        XCTAssertEqual(gated.report.blackCancelTerm, 0, "⑧c：抵消项必须归零")
        XCTAssertGreaterThan(gated.blacks, shipped.blacks,
                             "⑧c：不抵消就必须比正常情况浅（\(gated.blacks) vs \(shipped.blacks)）")
        // …and with no trim at all the two agree: the gate removes the *cancellation*, nothing else.
        var untrimmed = edit
        untrimmed.light.blackOffset = 0
        let plain = try run(untrimmed, lossAtDepth: cheapHighlights())
        let plainGated = try run(untrimmed, gates: gates, lossAtDepth: cheapHighlights())
        XCTAssertEqual(plain.blacks, plainGated.blacks, accuracy: 1e-9,
                       "没有 blackOffset 时，⑧c 不该改变任何东西")
        print("422 GATE ⑧c · shipped \(shipped.blacks) · gated \(gated.blacks) · no-trim \(plain.blacks)")
    }

    /// ⑧d — the tail guard is gone (anchor on p95, no walk-back) ⇒ a thick tail is left un-answered.
    ///
    /// **What this gate can and cannot assert, measured.** The guard is a *ratio* (`p99.9/p99 ≤ 1.6`), and
    /// `p99.9/p99` is a property of the picture rather than of the gain: on this fixture it is **1.830** at
    /// 0 EV and 1.830 at +2.3 EV, and the five real frames measure the same invariance (−0.5 … +3 EV). So a
    /// frame whose tail is genuinely thicker than the ceiling can never be walked back *into* it, and the
    /// gate cannot assert "the tail ends up inside". What it asserts is the **response**: the guard notices
    /// the exceedance and takes a step back, which costs exposure. Remove the guard and the extra exposure
    /// is spent anyway — which is exactly the over-exposure the gate is about.
    func testGateDroppingTheCeilingOvershootsWhite() throws {
        // L1030940's own tail ratio (1.83) on a **linear** gain, so the ratio is constant and the guard's
        // behaviour is isolated from any pipeline nonlinearity.
        var luma = [Float](repeating: 0, count: 1000)
        for i in 0 ..< 1000 { luma[i] = Float(0.10 + Double(i) / 989.0 * 0.20) }
        luma[995] = 0.42
        luma[996] = 0.45
        luma[997] = 0.47
        luma[998] = 0.549     // p999
        luma[999] = 0.60      // peak
        let base = AutoLight.Sample(width: 100, height: 10, luma: luma)
        func measure(_ document: EditModel) -> AutoLight.Sample {
            let gain = pow(2.0, document.light.exposure)
            return AutoLight.Sample(width: base.width, height: base.height,
                                    luma: base.luma.map { Float(Double($0) * gain) })
        }
        let shipped = try AutoLight.plan(for: hotEdit()) { measure($0) }
        var gates = AutoLight.Gates()
        gates.noExposureCeiling = true
        gates.keepsTailGuard = true      // 426d: 旧口径的配套护栏，只在门里打开
        // **The gate deletes *two* lines** — the p95 anchor and the walk-back loop — so its mutation has
        // to touch both; this assertion is what catches a mutation that only touches one.
        let gated = try AutoLight.plan(for: hotEdit(), gates: gates) { measure($0) }

        print(String(format: "422 GATE ⑧d · shipped EV %+.2f p99 %.3f 比值 %.3f 回退 %d · "
                     + "gated EV %+.2f p99 %.3f 比值 %.3f 回退 %d",
                     shipped.report.exposureEV, shipped.report.p99AfterExposure,
                     shipped.report.p999OverP99AfterExposure, shipped.report.exposureBackstops,
                     gated.report.exposureEV, gated.report.p99AfterExposure,
                     gated.report.p999OverP99AfterExposure, gated.report.exposureBackstops))
        // **426d 重定义**: `gated` 现在走**旧口径**（`p99 → 1.5` + tail guard walk-back），
        // `shipped` 走新口径（`p95 → broadHighlightTarget`，无 walk-back）。
        //
        // 门要证明的是「旧口径确实会把曝光推得更高、并让尾巴超界」—— 这正是它被废除的理由：
        // 422 自己的记录写着 L1030940 的 p99.9/p99 在 −0.5 EV 和 +3 EV 都是 1.831，
        // 那是照片的属性、不是增益的产物，walk-back 永远无法把它压回 1.6。
        XCTAssertEqual(shipped.report.exposureBackstops, 0,
                       "新口径没有 tail guard，回退恒 0，实际 \(shipped.report.exposureBackstops)")
        // 最终 EV 可能被步骤 3 的 `refillBody` 拉回同一档（两条口径都会降 EV 补主体），所以这里
        // 只要求旧口径**不比新口径少**；真正区分两条口径的是下面那条「旧口径把 p99 推到更高」。
        XCTAssertGreaterThanOrEqual(gated.report.exposureEV, shipped.report.exposureEV - 1e-9,
                                    "⑧d：旧口径 p99→1.5 给的光不该少于新口径 p95→1.1"
                                    + "（\(gated.report.exposureEV) vs \(shipped.report.exposureEV)）")
        XCTAssertGreaterThan(gated.report.p99AfterExposure, shipped.report.p99AfterExposure,
                             "⑧d：旧口径把 p99 推到 1.5 附近，新口径不会")
    }

    /// ⑧e — the slope comes from the **0 EV table** ⇒ a hot frame is asked for a depth it does not need.
    func testGateFixedSlopeTableUndershootsOnAHotPicture() throws {
        var model = Model()
        // A frame whose real slope is ~9× the 0 EV table at the operating point.
        model.highlightSlope = { ev in 0.00128 * pow(2.0, ev * 1.8) }
        let edit = hotEdit()
        let shipped = try AutoLight.plan(for: edit, lossAtDepth: cheapHighlights()) { model.sample(for: $0) }
        var gates = AutoLight.Gates()
        gates.fixedSlopeTable = true
        let gated = try AutoLight.plan(for: edit, gates: gates, lossAtDepth: cheapHighlights()) { model.sample(for: $0) }

        XCTAssertEqual(gated.report.highlightSlope, AutoLight.zeroEVHighlightSlope,
                       "⑧e：门打开时斜率必须来自表")
        XCTAssertNotEqual(shipped.report.highlightSlope, AutoLight.zeroEVHighlightSlope)
        XCTAssertLessThan(gated.report.highlightSlope, shipped.report.highlightSlope,
                          "0 EV 表在这个曝光点上是**更小**的数（这就是 §0d 的 7×）")
        // **426d**: 高光深度现在由**纹理预算**决定（`deepestHighlightWithinBudget`），而本夹具的
        // `cheapHighlights()` 让任何深度都合格 ⇒ 两条路径都走满 −100，`abs()` 不再有区分度。
        // 门要证明的仍然是「表低估斜率」，所以断言改为**斜率**本身（上面两条已覆盖），
        // 高光深度只打印不设门 —— 否则这条门是在测一个已不再由斜率决定的量。
        XCTAssertLessThanOrEqual(abs(gated.highlights), 100,
                                 "⑧e：高光不超过滑杆行程（\(gated.highlights)）")
        print(String(format: "422 GATE ⑧e · shipped slope %.5f 高光 %.0f · gated slope %.5f 高光 %.0f",
                     shipped.report.highlightSlope, shipped.highlights,
                     gated.report.highlightSlope, gated.highlights))
    }

    /// The gates are inert in production, and each one is its own line.
    func testEveryGateIsOffInProductionAndIndependent() {
        let gates = AutoLight.Gates()
        XCTAssertFalse(gates.criterionAlwaysZeroLoss)
        XCTAssertFalse(gates.criterionAlwaysFullLoss)
        XCTAssertFalse(gates.ignoresBlackOffset)
        XCTAssertFalse(gates.noExposureCeiling)
        XCTAssertFalse(gates.fixedSlopeTable)
        XCTAssertEqual(gates, AutoLight.Gates())
    }

    // MARK: - ⑥ the engine's own arithmetic

    /// Percentiles and the two clip ratios on a known grid.
    func testMetricsAreTheGridsOwnNumbers() {
        let sample = flatGrid(width: 10, height: 10)
        let m = sample.metrics()
        XCTAssertEqual(m.sampleCount, 100)
        // Rows 0–4 are 0.05 (50 texels), rows 5–9 ramp 0.1 → 0.82 (50 texels, so 0.1…0.18).
        XCTAssertEqual(m.p10, 0.05, accuracy: 1e-6, "a tenth of the frame is the dark half")
        XCTAssertEqual(m.p50, 0.1, accuracy: 1e-6, "the 50th of 100 samples is the ramp's first step")
        XCTAssertGreaterThan(m.p90, 0.5, "the top tenth is the ramp's bright end")
        XCTAssertGreaterThan(m.p99, 0.7)
        XCTAssertEqual(m.clippedHDR, 0, "nothing is above white in this grid")
        XCTAssertEqual(m.clippedBlack, 0, "and nothing is at or below 0.001")
        XCTAssertGreaterThan(m.texture, 0, "the top tenth is a ramp, so it has a first difference")
        XCTAssertGreaterThan(m.textureAbsolute, 0)
    }

    /// A grid that is entirely above white reports every sample as clipped, and a matte-only grid
    /// reports nothing at all (the `−65504` sentinel is not a photograph).
    func testMatteAndClippedGridsAreHandledExactly() {
        let hot = AutoLight.Sample(width: 4, height: 4,
                                   luma: Array(repeating: 2.0, count: 16))
        XCTAssertEqual(hot.metrics().clippedHDR, 1.0)
        XCTAssertEqual(hot.metrics().texture, 0, "a flat grid has no first difference")

        let matte = AutoLight.Sample(width: 4, height: 4,
                                     luma: Array(repeating: -65504, count: 16))
        let m = matte.metrics()
        XCTAssertEqual(m.sampleCount, 0, "372's sentinel is not a photograph")
        XCTAssertEqual(m.p99, 0)
    }

    /// The texture is measured over **each render's own** top 10 %, so it follows the region as it
    /// darkens — a fixed floor empties out (the probe measured that, which is why `plan` passes `nil`).
    func testTheTextureRegionFollowsTheRenderThatIsMeasured() {
        // A grid whose brightest **column** is x = 8 (so the region has both neighbours to difference
        // against), with x = 9 deliberately dark. `texture` never centres on the last column or row, so
        // a region made of those would measure nothing at all — which is why the band is not at the edge.
        func grid(brightValue: Float) -> AutoLight.Sample {
            var luma = [Float](repeating: 0, count: 100)
            for y in 0 ..< 10 {
                for x in 0 ..< 10 {
                    luma[y * 10 + x] = x == 8 ? brightValue : (x == 9 ? 0.05 : Float(x) * 0.1 + 0.1)
                }
            }
            return AutoLight.Sample(width: 10, height: 10, luma: luma)
        }
        // A 10-wide grid: the top-10 % rank is **index 9 of 10**, i.e. the 9th smallest — which is
        // 0.8, not the band at 0.9. That is the nearest-rank rule, and it is why the assertion names the
        // 9th smallest rather than "the brightest".
        let bright = grid(brightValue: 0.90)
        let darker = grid(brightValue: 0.20)
        XCTAssertEqual(bright.metrics().cut, 0.80, accuracy: 1e-6, "区域是第 9/10 小的值")
        XCTAssertLessThan(darker.metrics().cut, bright.metrics().cut, "压暗之后区域跟着下移")
        XCTAssertGreaterThan(bright.metrics().texture, 0, "亮列的第一差分是真的")
        // A **fixed** floor instead of the render's own would measure a different region on each.
        // A floor well inside the band's own reach: on the bright grid it measures the band, on the
        // darkened one the band is **below the floor** and the region collapses to the ramp's top —
        // a different population, i.e. a rate that is not comparable. That is why `plan` passes `nil`.
        let fixed = bright.metrics(cut: 0.85)
        let fixedDarker = darker.metrics(cut: 0.85)
        XCTAssertGreaterThan(fixed.texture, 0, "固定门槛在亮画面上仍然能测到那条带")
        XCTAssertEqual(fixedDarker.sampleCount > 0 ? fixedDarker.texture : 0, 0,
                       "固定的门槛在压暗后的画面上空掉了 —— 这正是 plan 传 nil 的理由")
    }

    /// `snapExposure` is the row's grid and the ceiling at once.
    func testExposureSnapsDownOntoTheRowGrid() {
        XCTAssertEqual(AutoLight.snapExposure(1.7777), 1.77, "曝光 落在 0.01 格，向下取整")
        XCTAssertEqual(AutoLight.snapExposure(-2.0001), -2.01)
        XCTAssertEqual(AutoLight.snapExposure(99), 8, "钳到滑杆上限")
        XCTAssertEqual(AutoLight.snapExposure(-99), -4, "钳到滑杆下限")
        XCTAssertEqual(AutoLight.snapExposure(.nan), 0)
        XCTAssertEqual(AutoLight.snapExposure(0.98), 0.98)
    }

    /// **B① — 422 裁定：对比不做.** On every measured frame the plan's 对比 is exactly 0, while the
    /// report still carries the *measured* separation beside it — so the number a future rule would use
    /// is on the record even though no rule acts on it. Restoring the old 分离度 rule turns this red.
    func testContrastIsAlwaysZeroOnEveryFrame() throws {
        // Two synthetic frames that the **old** rule treated differently: `tight` was under the 4.1-stop
        // target (it used to get 对比 > 0), `wide` was over it (it used to get 0). Now both are 0.
        var tight = Model()
        tight.baseP10 = 0.02
        tight.baseP50 = 0.06
        var wide = Model()
        wide.baseP10 = 0.25
        wide.baseP50 = 0.32
        let tightPlan = try AutoLight.plan(for: EditModel.neutral) { tight.sample(for: $0) }
        let widePlan = try AutoLight.plan(for: EditModel.neutral) { wide.sample(for: $0) }
        print(String(format: "422 CONTRAST OFF · sep %.2f → 对比 %.0f · sep %.2f → 对比 %.0f",
                     tightPlan.report.separationStops, tightPlan.contrast,
                     widePlan.report.separationStops, widePlan.contrast))
        XCTAssertEqual(tightPlan.contrast, 0, "分离度不足也不加对比（裁定：对比不做）")
        XCTAssertEqual(widePlan.contrast, 0)
        XCTAssertGreaterThan(tightPlan.report.separationStops, 0, "分离度仍然被测量并报告")
        // …and the plan's write keeps the field: `apply` still writes `light.contrast`, to 0.
        let applied = tightPlan.apply(to: EditModel.neutral)
        XCTAssertEqual(applied.light.contrast, 0, "Plan.contrast 保留字段，apply 写 0")
    }

    /// **B② — 步骤 4 仍然读 `blackOffset`.** The verdict deleted step 5 only; the black cancellation is
    /// untouched. ⑧c still removes it, so this assertion is what stands between the cancellation and a
    /// silent deletion along with the contrast rule.
    func testStepFourStillReadsBlackOffsetAfterTheVerdict() throws {
        var trimmed = EditModel.neutral
        trimmed.light.blackOffset = 0.008
        let shipped = try run(trimmed, lossAtDepth: cheapHighlights())
        XCTAssertNotEqual(shipped.report.blackCancelTerm, 0, "offset > 0 ⇒ 抵消项非 0")
        XCTAssertLessThan(shipped.report.blackCancelTerm, 0)

        var gates = AutoLight.Gates()
        gates.ignoresBlackOffset = true
        let gated = try run(trimmed, gates: gates, lossAtDepth: cheapHighlights())
        XCTAssertEqual(gated.report.blackCancelTerm, 0, "⑧c 仍然必须把抵消项清零")
        XCTAssertGreaterThan(gated.blacks, shipped.blacks)
    }

    // MARK: - ⑦ 422 裁定 §5.4: the owner's own five frames

    /// The one row of `handValues`, for the acceptance test below.
    private struct HandRow {
        let name: String
        let exposure, highlights, whites, blacks, blackOffset: Double
        func edit(base: EditModel) -> EditModel {
            var e = base
            e.light.exposure = exposure
            e.light.highlights = highlights
            e.light.whites = whites
            e.light.blacks = blacks
            return e
        }
    }

    /// The owner's finished edit, read from the demo catalog's **last** snapshot (`seq > 1`, i.e. actually
    /// edited — a bare import is not a decision).
    private func handValues(root: String, limit: Int) throws -> [HandRow] {
        let library = NSString(string: "~/Documents/photons-demo.photonslibrary/library.db").expandingTildeInPath
        guard FileManager.default.isReadableFile(atPath: library) else { throw XCTSkip("no catalog") }
        let sql = """
        SELECT a.filename, h.develop_json FROM assets a
          JOIN source_roots s ON s.id = a.source_root_id
          JOIN asset_history h ON h.asset_id = a.id
         WHERE s.display_name = '\(root)'
           AND h.seq = (SELECT MAX(seq) FROM asset_history x WHERE x.asset_id = a.id)
           AND h.seq > 1
         ORDER BY a.filename LIMIT \(limit);
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [library, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var rows: [HandRow] = []
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let json = String(parts[1]).data(using: .utf8),
                  let model = try? JSONDecoder().decode(EditModel.self, from: json) else { continue }
            rows.append(HandRow(name: String(parts[0]), exposure: model.light.exposure,
                                highlights: model.light.highlights, whites: model.light.whites,
                                blacks: model.light.blacks, blackOffset: model.light.blackOffset))
        }
        return rows
    }

    /// **422 裁定 §5.4 (rework 3), A①/A②/A③/A④/A⑤ and B① on the real five frames.** ⑧a turns A① red and
    /// ⑧b turns **A④** red — A④ is the point of this rework.
    ///
    /// The rework changed two things and both are asserted here rather than printed and trusted:
    /// `p99TopTarget` 0.82 → **1.2** (it has to follow the anchor, and 1.2 is the bisected value that lands
    /// both A④ and A⑤; see the constant's table) and the guard `p99.9 ≤ 2.0` → **`p99.9/p99 ≤ 1.6`**.
    ///
    ///   · A① **every frame goes up** by more than +0.2 stops over the 0.98 baseline's exposure
    ///     (`log2(0.98 / p99@0EV)`, snapped down). +0.2 rather than +0.3: the guard still costs the one
    ///     frame with a thick tail (L1030940, ratio 1.83) a little, and +0.2 is above the visible threshold.
    ///   · A② the **median** rise is 0.4–0.9 stops. **The 0.4 lower bound is lower than v2's 0.5 on
    ///     purpose**: A④ (the finished picture's p50) is the goal of this ticket and A② is only an
    ///     intermediate; a plan that lands the picture correctly with 0.45 stops of exposure is a success.
    ///   · A③ the **relative** guard responds correctly: the four frames inside 1.6 take **zero** walk-backs,
    ///     and the one frame outside it (L1030940, 1.83) takes **at most one**. The ratio itself is a
    ///     property of the picture — measured 1.831 at −0.5 EV *and* +3 EV — so no walk-back can move it
    ///     into the ceiling; v2's absolute guard spent 10 futile steps per run there (20 in total).
    ///   · A④ **the finished picture's whole-frame p50 is within 0.25 stops of the owner's own**
    ///     (median of |Δ|) —— 这是 422 的原判据，441 返工 §5.4 明确不许换。主体 `subjectP50` 的差
    ///     作为**附加读数**并列打印（本单治理的量，但不是 A④ 的门）。
    ///   · A⑤ the finished render's clipping median lands in 1 %–5 % (L1030941's ~5 % is allowed).
    ///   · B① `plan.contrast == 0` on every frame (步骤 5 删除).
    func testTheOwnersFiveFramesAdvanceTheCalibrationAndLeaveContrastAtZero() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let rows = try handValues(root: "boston", limit: 5)
        guard rows.count == 5 else { throw XCTSkip("the owner's five frames are not all in the catalog") }
        let dir = NSString(string: "~/Desktop/boston").expandingTildeInPath

        var gains: [Double] = []          // plan exposure − the 0.98 baseline's exposure
        var p50Diffs: [Double] = []
        var subjectDiffs: [Double] = []
        var clips: [Double] = []
        var backstopFrames = 0
        var backstopTotal = 0
        for row in rows {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(row.name)
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw XCTSkip("no \(row.name)") }
            let image = try RAWDecoder().decode(url, options: DecodeOptions(scale: 0.5))
            let graph = try RenderGraph(input: RenderInput(image: image, identity: "auto-light-422-verdict",
                                                          sourceURL: url))
            var start = EditModel.neutral
            start.sharpen = SharpenGroup(amount: 0)
            start.light.blackOffset = row.blackOffset
            let neutral = try graph.measureAutoLightSample(start).metrics()
            let old = (min(8, max(-4, log2(0.98 / max(neutral.p99, 1e-5)))) * 100).rounded(.down) / 100
            let plan = try AutoLight.plan(for: start) { try graph.measureAutoLightSample($0) }
            let auto = plan.apply(to: start)
            let hand = row.edit(base: start)
            let am = try graph.measureAutoLightSample(auto).metrics()
            let hm = try graph.measureAutoLightSample(hand).metrics()

            let diff = log2(max(am.p50, 1e-6) / max(hm.p50, 1e-6))
            let subjectDiff = log2(max(am.subjectP50, 1e-6) / max(hm.subjectP50, 1e-6))
            gains.append(plan.exposure - old)
            p50Diffs.append(diff)
            subjectDiffs.append(subjectDiff)
            clips.append(am.clippedHDR)
            if plan.report.exposureBackstops > 0 { backstopFrames += 1 }
            backstopTotal += plan.report.exposureBackstops
            print(String(format: "422 FIVE %@ · EV %+.2f (0.98 基线 %+.2f, +%.2f) · 回退 %d · p99.9/p99 %.3f · "
                         + "p99@exp %.3f 高光 %.0f 白色 %.0f · 中间调 %.0f · 主体 %.4f→%.4f · 整帧 %.4f→%.4f · "
                         + "成品 p50 %.4f / 用户 %.4f (%+.2f 档) · 成品主体 %.4f / 用户 %.4f (%+.2f 档) · 削顶 %.2f%% · 对比 %.0f",
                         row.name, plan.exposure, old, plan.exposure - old,
                         plan.report.exposureBackstops, plan.report.p999OverP99AfterExposure,
                         plan.report.p99AfterExposure, plan.highlights, plan.whites, plan.midtones,
                         plan.report.subjectP50Before, plan.report.subjectP50After,
                         plan.report.wholeP50Before, plan.report.wholeP50After,
                         am.p50, hm.p50, diff, am.subjectP50, hm.subjectP50, subjectDiff,
                         am.clippedHDR * 100, plan.contrast))

            // A① — 曝光 上升（每一帧），逐帧 > +0.2 档。
            XCTAssertGreaterThan(plan.exposure - old, 0.2,
                                 "A① \(row.name)：0.98 基线 \(old)，新曝光 \(plan.exposure)")
            // A③ — 相对护栏的**响应**是正确的：界内的帧一次回退都没有；超界的帧（尾巴 1.83 的
            // L1030940）回退次数**有界**，不会像绝对护栏那样耗掉 10 步。比值本身是照片的属性、
            // 不随增益变化，所以护栏挡不住它 —— 这条断言拦的是「回退退化成把曝光吃掉」。
            // **426d: tail guard 已删除** —— 422 自己的记录证明 p99.9/p99 是照片属性、不随增益变，
            // walk-back 永远压不回去，只会白吃掉曝光（426b 实测五帧 0.46–1.89 档）。
            // 所以这里改成断言「恒不回退」，而且是**每帧**都断言，不再是「界内才断言」。
            XCTAssertEqual(plan.report.exposureBackstops, 0,
                           "A③ \(row.name)：426d 没有 tail guard，回退必须恒 0，实际 \(plan.report.exposureBackstops)")
            // A④ — 成品 p50 贴近用户（逐帧 |Δ| ≤ 0.6，中位在循环外断言 ≤ 0.25）。
            XCTAssertLessThanOrEqual(abs(diff), 0.6,
                                     "A④ \(row.name)：成品 p50 与用户差 \(diff) 档")
            // B① — 对比不做。
            XCTAssertEqual(plan.contrast, 0, "B① \(row.name)：对比恒为 0")
        }

        let medianGain = gains.sorted()[gains.count / 2]
        let medianP50 = p50Diffs.map { abs($0) }.sorted()[p50Diffs.count / 2]
        let medianSubject = subjectDiffs.map { abs($0) }.sorted()[subjectDiffs.count / 2]
        let medianClip = clips.sorted()[clips.count / 2]
        print(String(format: "422 FIVE · 中位升 %.2f 档 · 中位 |主体 差| %.2f 档 · 中位 |p50 差| %.2f 档 · 中位削顶 %.2f%% · "
                     + "回退：%d 帧 / 合计 %d · 主体差逐帧 %@ · p50 差逐帧 %@",
                     medianGain, medianSubject, medianP50, medianClip * 100, backstopFrames, backstopTotal,
                     subjectDiffs.map { String(format: "%+.2f", $0) }.joined(separator: " "),
                     p50Diffs.map { String(format: "%+.2f", $0) }.joined(separator: " ")))
        // A② — 中位增量 0.4…0.9 档。下限 0.4 低于 v2 的 0.5，因为 A④ 才是目标、A② 只是中间量。
        XCTAssertGreaterThanOrEqual(medianGain, 0.4, "A②：中位增量 \(medianGain) 档，应 ≥ 0.4")
        XCTAssertLessThanOrEqual(medianGain, 0.9, "A②：中位增量 \(medianGain) 档，应 ≤ 0.9")
        // A③ — 相对护栏下只有尾巴最厚的那一帧（L1030940, 1.83）会响应，其余四帧必须 0，且超界帧
        // 最多退 1 步（比值不随增益变，再退只是白吃曝光 —— v2 的绝对护栏就在这里吃了 10 步）。
        XCTAssertLessThanOrEqual(backstopFrames, 1,
                                 "A③：\(backstopFrames)/5 帧触发回退（相对护栏 1.6 只该挡尾巴最厚的一帧），合计 \(backstopTotal) 次")
        XCTAssertLessThanOrEqual(backstopTotal, 1,
                                 "A③：回退合计 \(backstopTotal) 次；超界帧最多退 1 步，不该再出现 v2 的 20 次")
        // A④ — **422 的原判据，441 返工 §5.4 恢复：成品整帧 p50 与用户的中位差 ≤ 0.25 档。**
        //
        // 首轮把它换成了 `subjectP50`（因为整帧差 0.28 越线），这是偷换被测量，返工禁止。
        // 主体差 `medianSubject` 仍逐帧打印，作为附加读数；若整帧差越线，就如实报红并在报告里
        // 说明「用户口径是要更亮，所以整帧会偏亮 X 档」，由主线决定是否调门限。
        // **实测（441 返工）：0.2537 档，只越线 0.0037 档**；越线来自 L1030943 —— 主体地板把它
        // 的中间调推到 100，成品整帧 p50 0.0576（无地板）→ 0.0776，而用户成品是 0.0651。
        // 这是本单「主体要更亮」的直接结果，不换被测量、不放宽门限；红着交主线裁决。
        XCTAssertLessThanOrEqual(medianP50, 0.25,
                                 "A④：成品整帧 p50 差中位 \(medianP50) 档，应 ≤ 0.25（逐帧 \(p50Diffs)）")
        // A⑤ — 削顶与用户中位同量级（1 %…5 %）。
        XCTAssertGreaterThanOrEqual(medianClip, 0.01, "A⑤：中位削顶 \(medianClip * 100)%")
        XCTAssertLessThanOrEqual(medianClip, 0.05, "A⑤：中位削顶 \(medianClip * 100)%")
    }

    // MARK: - helpers

    private func rawFixture() -> URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func graph(_ url: URL) throws -> RenderGraph {
        let image = try RAWDecoder().decode(url, options: DecodeOptions(scale: 0.5))
        return try RenderGraph(input: RenderInput(image: image, identity: "auto-light-422",
                                                  sourceURL: url))
    }

    private static func firstView(in root: NSView, where match: (NSView) -> Bool) -> NSView? {
        if match(root) { return root }
        for child in root.subviews {
            if let found = firstView(in: child, where: match) { return found }
        }
        return nil
    }

    private static func allAccessibilityIdentifiers(in root: NSView, depth: Int = 0) -> [String] {
        guard depth < 24 else { return [] }
        var out: [String] = []
        for child in root.accessibilityChildren() ?? [] {
            if let view = child as? NSView {
                let id = view.accessibilityIdentifier()
                if !id.isEmpty { out.append(id) }
                out += allAccessibilityIdentifiers(in: view, depth: depth + 1)
            } else if let element = child as? NSAccessibilityElement,
                      let id = element.accessibilityIdentifier(), !id.isEmpty {
                out.append(id)
            }
        }
        let selfID = root.accessibilityIdentifier()
        if !selfID.isEmpty { out.append(selfID) }
        return out
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var inspectorSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    private static var loupeSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/LoupeController.swift")
    }

    private static func body(of signature: String, upTo endMarker: String, in url: URL) throws -> String {
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: signature),
              let end = source.range(of: endMarker),
              start.lowerBound < end.lowerBound else {
            throw XCTSkip("no `\(signature)` … `\(endMarker)` section in \(url.lastPathComponent)")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: search) {
            count += 1
            search = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
