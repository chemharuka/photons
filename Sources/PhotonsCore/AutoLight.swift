import Foundation

// MARK: - 422 — the Light card's 自动调节
//
// **Four** steps, in the owner's order, and each one is a **measurement** rather than a table lookup:
//
//   1. 曝光     先加. The anchor is the picture's own p99 in scene-linear light: raise the gain until
//               that percentile sits **above** SDR white (`p99WhiteTarget = 1.5`) — the owner's own
//               finished pictures do exactly that (median clipping 2.44 %) — while the **tail stays
//               proportionally close to it**: `p99.9 / p99 ≤ 1.6` (`p999OverP99Ceiling`), the only
//               overshoot guard left. The guard is a **ratio** on purpose — see the constant.
//   2. 中间调/阴影  what step 1 did not lift (the picture's own body is still under `midtoneTarget`)
//               is lifted here, so the SDR picture is not left underexposed.
//   3. 高光/白色   the criterion is **texture loss**, not area (`docs/tasks/422-auto-light.md` §0c).
//               高光 is the first tool and it has a texture **budget**; 白色 then joins it
//               **simultaneously** for whatever pull is left, because — measured, not assumed — 白色
//               cannot deliver the darkening alone. See `whiteJoinsHighlights`.
//   4. 黑色      give back the lift `blackOffset` put on the black floor, then deepen until >0.1 % of
//               the pixels reach the bottom (cap −100).
//
// **步骤 5（对比）不做** — 422 裁定（2026-11-17，用户原话「对比不做，曝光按我的习惯来」）：the old
// "separation too small ⇒ add 对比" rule measured `r = −0.092` against the owner's own contrast, i.e.
// it could not tell their decisions apart, so the step is deleted and `contrast` is always 0.
//
// **Why every slope is measured at the operating point** (§0d). Measured on L1030433, p99 per −100 of
// 高光: **−0.128 at 0 EV, −0.906 at +2 EV, −2.368 at +3 EV** — 7.1× and then 18.5×. A fixed table
// therefore mis-solves a bright photo by an order of magnitude, in the direction that over-corrects.
// Step 3 asks the pipeline for its own secant *after* step 1 has fixed the exposure.
//
// Everything here is **pure**: it reads an `EditModel`, asks a closure for measurements, and returns a
// `Plan`. It never writes a document, never touches `blackOffset`, and never renders by itself — the
// caller (`LoupeController.autoLight()`) applies the plan in one edit and commits one snapshot.

public enum AutoLight {

    // MARK: - the measurement

    /// One picture's luma grid, at the scale the algorithm measures on.
    ///
    /// Luma is `ColorPrimaries.working`'s (Rec.2020) weights applied to the **scene-linear** samples —
    /// the same weighting S1/S2 use — so a percentile here is the percentile of the light the pipeline
    /// actually moved.
    public struct Sample: Sendable {
        public let width: Int
        public let height: Int
        /// Row-major, one value per texel. Matte/letterbox samples arrive as `−65504` (372's sentinel)
        /// and are excluded by every statistic below.
        public let luma: [Float]

        public init(width: Int, height: Int, luma: [Float]) {
            self.width = width
            self.height = height
            self.luma = luma
        }

        /// The scene-linear RGB grid the pipeline's own stride sample produces, weighted to luma.
        public init(_ sample: LinearSample) {
            let w = sample.width
            let h = sample.height
            let weights = ColorPrimaries.working.luminanceWeights
            var out = [Float](repeating: 0, count: max(w * h, 0))
            for p in 0 ..< (w * h) {
                let o = p * 4
                guard o + 2 < sample.rgba.count else { break }
                out[p] = Float(weights.x * Double(sample.rgba[o])
                               + weights.y * Double(sample.rgba[o + 1])
                               + weights.z * Double(sample.rgba[o + 2]))
            }
            self.init(width: w, height: h, luma: out)
        }

        /// Texels that are photograph: not the `000000` matte of a window render and not 372's
        /// sentinel. S2 clamps every picture sample to `≥ 0`, so a negative luma can only be a
        /// sentinel — one test at zero is exact.
        @inline(__always) public static func isPicture(_ v: Float) -> Bool { v > -0.001 }
    }

    /// The numbers one render contributes.
    public struct Metrics: Sendable, Equatable {
        public var p01: Double
        public var p10: Double
        public var p50: Double
        public var p90: Double
        public var p95: Double
        public var p99: Double
        public var p999: Double
        public var peak: Double
        /// Fraction of picture samples above SDR white (1.0 linear).
        public var clippedHigh: Double
        /// Fraction of picture samples at or below 0.001 linear.
        public var clippedLow: Double
        /// **§0c's texture, level-normalised** — see `texture(atOrAbove:absolute:)`.
        public var texture: Double
        /// The same first difference **without** the division: §0c's literal formula. Carried beside the
        /// shipped number so the report can print both.
        public var textureAbsolute: Double
        /// The luma floor of the region the two were measured over.
        public var cut: Float
        public var sampleCount: Int

        /// The picture's own separation, in stops of light: p90 ÷ p10.
        public var separationStops: Double {
            guard p10 > 1e-6, p90 > 1e-6 else { return 0 }
            return log2(p90 / p10)
        }
    }

    /// Nearest-rank percentile on an ascending array.
    static func percentile(_ sorted: [Float], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let clamped = min(max(q, 0), 1)
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return Double(sorted[min(max(index, 0), sorted.count - 1)])
    }

    /// The eight percentiles `Metrics` reports, from **one partial selection** rather than a full sort.
    ///
    /// Measured on the 341×512 grid the algorithm measures at: a full `sorted()` is **122 ms** of the
    /// 173 ms `metrics()` costs, and the algorithm calls it a dozen times per run. Quickselect on the
    /// eight ranks is O(n) per rank and, because they are pulled in ascending order, each pass only
    /// touches the prefix the previous rank left behind — measured **9 ms** for all eight.
    ///
    /// `ranks` must be ascending in [0, 1]; ties are handled by the same nearest-rank rule
    /// `percentile(_:_:)` uses, so the two agree to the sample.
    static func percentiles(_ values: [Float], _ ranks: [Double]) -> [Double] {
        guard !values.isEmpty else { return ranks.map { _ in 0 } }
        var work = values
        let n = work.count
        var out: [Double] = []
        out.reserveCapacity(ranks.count)
        var lower = 0
        for q in ranks {
            let clamped = min(max(q, 0), 1)
            let index = min(max(Int((Double(n - 1) * clamped).rounded()), 0), n - 1)
            if index >= lower {
                // Selection is in place and `work[lower...]` is already the right multiset, so the
                // search only spans the part the previous rank did not settle.
                select(&work, k: index, from: lower)
                lower = index
            }
            out.append(Double(work[index]))
        }
        return out
    }

    /// In-place quickselect: puts the k-th smallest of `work[from...]` at `work[k]`.
    ///
    /// Hoare partition around a median-of-three pivot, with the recursion replaced by a loop on the
    /// side that still contains `k`. Deterministic: no seed, no random pivot, so the same input gives
    /// the same answer in every process (which `AutoLightTests` asserts).
    private static func select(_ work: inout [Float], k: Int, from: Int) {
        var lo = from
        var hi = work.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            // Median of three, so an already-sorted or reversed input cannot degrade the pivot.
            if work[mid] < work[lo] { work.swapAt(mid, lo) }
            if work[hi] < work[lo] { work.swapAt(hi, lo) }
            if work[hi] < work[mid] { work.swapAt(hi, mid) }
            let pivot = work[mid]
            var i = lo
            var j = hi
            while i <= j {
                while work[i] < pivot { i += 1 }
                while work[j] > pivot { j -= 1 }
                if i <= j {
                    work.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if k <= j {
                hi = j
            } else if k >= i {
                lo = i
            } else {
                return
            }
        }
    }

    // MARK: - the plan

    /// 明暗's seven fields, as the algorithm sets them. `blackOffset` is deliberately **not** here: it
    /// belongs to the 黑电平 card and 自动调节 only reads it.
    public struct Plan: Sendable, Equatable {
        public var exposure: Double
        public var contrast: Double
        public var highlights: Double
        public var midtones: Double
        public var shadows: Double
        public var whites: Double
        public var blacks: Double
        public var report: Report

        /// The one write this plan is: the seven tone fields, on top of the document it was planned
        /// for. Nothing else in the document moves.
        public func apply(to edit: EditModel) -> EditModel {
            var next = edit
            next.light.exposure = exposure
            next.light.contrast = contrast
            next.light.highlights = highlights
            next.light.midtones = midtones
            next.light.shadows = shadows
            next.light.whites = whites
            next.light.blacks = blacks
            return next
        }
    }

    /// What the run measured, for the tests and the log line. Every number a decision used is here, so
    /// a report can argue about the decision instead of re-deriving it.
    public struct Report: Sendable, Equatable {
        /// Step 1.
        public var baseP99: Double
        public var exposureEV: Double
        public var p99AfterExposure: Double
        /// The overshoot guard's own number, measured at step 1's exposure: **`p99.9 / p99`**, i.e. the
        /// quantity `p999OverP99Ceiling` (1.6) governs. Reported as a ratio rather than an absolute p99.9
        /// because that is what the guard reads.
        public var p999OverP99AfterExposure: Double
        /// How many 0.05 EV steps the guard actually took back. 422's calibration target is **0** on the
        /// owner's five frames. A real exceedance gets a real response (one step back); the loop then stops
        /// as soon as a further step fails to lower `p99.9/p99`, because that ratio is a property of the
        /// picture rather than of the gain. Such a frame therefore reads **1** here, with its ratio still
        /// above the ceiling — the honest pair of numbers, rather than v2's 10 futile steps.
        public var exposureBackstops: Int
        public var clippedHighAfterExposure: Double
        /// Step 2.
        public var p50AfterExposure: Double
        public var midtones: Double
        public var shadows: Double
        public var p50AfterStep2: Double
        public var p10AfterStep2: Double
        /// Step 3.
        public var p99AfterStep2: Double
        public var p99Target: Double
        /// **Measured at step 1's exposure**, with the 0 EV table value beside it (⑧e's mistake).
        public var highlightSlope: Double
        public var whiteSlope: Double
        public var tableHighlightSlope: Double
        public var tableWhiteSlope: Double
        public var textureBase: Double
        public var textureAbsoluteBase: Double
        /// Measured on the **finished** render, over its own top 10 %.
        /// The **total** loss of the finished render, over its own top 10 % (高光 and 白色 together).
        public var textureLoss: Double
        /// 高光's **own** share — the number the criterion actually governs (`highlightLossThreshold`).
        /// Smaller than `textureLoss` because 白色 also darkens the region; both are reported so the
        /// decision can be read separately from the look it produced.
        public var textureLossHighlightsOnly: Double
        public var textureLossAbsolute: Double
        /// The deepest 高光 the criterion would allow on its own (0 when it was never the limit).
        public var highlightBudget: Double
        public var usedWhites: Bool
        /// Step 4.
        public var blackOffset: Double
        public var blackCancelTerm: Double
        public var clippedLowAfterBlacks: Double
        /// **Not a step any more** — 422's verdict deleted 对比. `separationStops` is still the measured
        /// p90 ÷ p10 (the report keeps the number) and `contrast` is always 0.
        public var separationStops: Double
        public var contrast: Double
        /// What the whole run cost.
        public var renderCount: Int
        public var milliseconds: Double
        public var textureLossThreshold: Double
        public var p99Final: Double
    }

    // MARK: - constants (each measured on the shipping pipeline; numbers in the lane report)

    /// Step 1's anchor: p99 lands **here**, above SDR white — the owner's own habit, not a convention.
    ///
    /// **422 裁定 (2026-11-17): 0.98 → 1.5.** The five boston frames, measured auto vs. hand, showed the
    /// automatic plan 0.72 EV dark (median ΔEV, 5/5) and their finished p50 0.62 stops darker — so the
    /// picture was genuinely dark, not merely reached by another route. `exposure = log2(target/anchor)`,
    /// so `log2(1.5 / 0.98) = +0.61` stops of the 0.72 come back and 0.11 stops are left (< 0.15, the
    /// visible threshold).
    ///
    /// Why 1.5 and not 1.59 (which would close the gap exactly): their finished **clipping median is
    /// 2.44 %**, and `p99 = 1.5` manufactures clipping of that order (≥ 1 %) while 1.59 slightly
    /// overshoots every frame on average. `target > 1.0` deliberately puts ~1 % of the pixels above the
    /// white point; going higher only buys headroom for extreme frames to overshoot into.
    /// (1.2 would come back +0.29 stops and leave 0.29 undelivered — also rejected.)
    ///
    /// The old note read "0.98 rather than 1.0 so the p99−p99.9 tail is still below white": that tail is
    /// now the `p999OverP99Ceiling` guard's job, which is why this constant could move at all.
    public static let p99WhiteTarget: Double = 1.5

    /// Step 1's overshoot guard, as a **multiple of p99** rather than an absolute p99.9.
    ///
    /// **Why not an absolute ceiling.** The old guard read `p99.9 ≤ 2.0`. With the anchor at `p99 = 1.5`
    /// that demands `p99.9/p99 ≤ 2.0/1.5 = 1.333`, and the five boston frames measure **1.831 / 1.117 /
    /// 1.404 / 1.452 / 1.587** — a ratio that is a property of the picture's own tail (`p99.9` is almost
    /// exactly `ratio · p99`, invariant in exposure: measured at −0.5 … +3 EV) and not of the exposure.
    /// **4/5 frames are therefore mathematically unsatisfiable** and the walk-back fired 20 times, which
    /// un-did most of the calibration it was guarding.
    ///
    /// A photograph with a thick tail should be allowed a thicker tail; only an *unusually* thick one is a
    /// defect. 1.6 sits between the measured 1.587 and 1.831: **only L1030940 (1.831) trips it**, the other
    /// four frames pass with zero walk-back.
    public static let p999OverP99Ceiling: Double = 1.6

    /// Step 2's targets. Both are **floors**, not goals: a picture already there is left alone.
    ///
    /// 0.04 linear is sRGB code 0.23 — "not underexposed", not "middle grey". The owner's own finished p50
    /// across boston measures **0.27 / 0.24 / 0.073 / 0.045 / 0.13**, and they used 中间调 on **none** of
    /// those five, so a conventional "middle grey" target (linear 0.18–0.21) would have driven the slider
    /// to its cap on three frames and invented a look they never made. The caps keep both sliders inside
    /// the envelope the owner actually uses (中间调 median +16.3, on the 33 % of the library that touches
    /// it at all).
    public static let midtoneTarget: Double = 0.04
    public static let midtoneCap: Double = 40
    public static let shadowTarget: Double = 0.005
    public static let shadowCap: Double = 30

    /// Step 3's goal: where the highlight pull ends.
    ///
    /// **422 rework (3rd): 0.82 → 1.2 — the target had to follow the anchor.** The original pair was
    /// anchor 0.98 / target 0.82, i.e. the target sat **0.16 stops below** the anchor: the anchor puts p99
    /// above white, step 3 pulls the top back down toward the texture budget's landing point. Raising the
    /// anchor to 1.5 and leaving the target at 0.82 turned that 0.16-stop gap into **0.68** (4.25×), so
    /// step 3 believed every picture was still 0.68 stops too hot and spent its whole 高光 budget (plus
    /// 白色 to −60) pushing the step-1 lift back out of the midtones. Measured consequence of the mismatch:
    /// exposure rose 0.46 stops while the finished p50 stayed 0.53 stops dark.
    ///
    /// **The value is calibrated, not derived.** The dispatch's arithmetic said `1.5 − 0.16 = 1.34`; the
    /// bisection over 1.2 / 1.34 / 1.42 says **1.2** is the one that satisfies both gates on the five
    /// frames (A④ = the finished p50 distance from the owner's, A⑤ = the finished clipping band):
    ///
    /// | 目标 | A④ 中位 \|p50 差\| | A⑤ 中位削顶 | 判定 |
    /// |---|---|---|---|
    /// | **1.2**  | **0.195** | **4.19 %** | ✔ 两条都过 |
    /// | 1.34 | 0.170 | 6.70 % | A⑤ 出界 |
    /// | 1.42 | 0.197 | 8.81 % | A⑤ 出界 |
    ///
    /// 1.34 pulls the top *less* than 1.2 does, which leaves the pictures brighter — and A⑤ is exactly the
    /// band that says how much white the owner's own finished pictures carry (their median 2.44 %). 1.2 keeps
    /// 高光's work inside the budget while holding the clipping there. The gap is 0.30 stops rather than
    /// 0.16: the original ratio was calibrated against an anchor whose p99 sat *below* white, and at 1.5 the
    /// pictures need to be pulled a little further to land their clipping in the owner's band.
    public static let p99TopTarget: Double = 1.2

    /// Below this much remaining deficit, step 3 does nothing (a picture already inside white).
    public static let topDeadband: Double = 0.02

    /// §0c's criterion, as a **budget on 高光's normalised texture loss**: 8 %.
    ///
    /// Re-measured on the shipping pipeline at the exposure step 1 picks (+2 EV), §0c's own comparison
    /// reproduces: 高光 −50 costs **16.3 / 17.8 / 9.2 / 13.3 %** of the region's normalised contrast
    /// (median 14.7 %) against 白色 −50's **5.3 / 5.0 / 1.3 / 3.3 %** (median 4.3 %) — a **3.4× ratio**
    /// against the spec's 3.32×. 8 % therefore sits between the two families and is crossed by 高光 at
    /// roughly −25. See `texture(atOrAbove:absolute:)` for why the normalised form is the one shipped.
    public static let highlightLossThreshold: Double = 0.08

    /// The most 白色 this algorithm will ask for, and the residual below which it does not engage at
    /// all. Both from the owner's own usage (白色 is 0 on all five boston frames; −31.6 median, −100
    /// min across the 19 % of the library that touches it) and from §1's 「要么不动、要么 ≥ −60」.
    public static let whiteTravelEnd: Double = 60
    public static let whiteEngageDeadband: Double = 0.04

    /// Step 4: >0.1 % of the pixels clipping at the bottom.
    public static let clipFloorFraction: Double = 0.001
    /// The black floor the crush aims at: 0.0016 is one hair below `clippedLow`'s own 0.001, so a solve
    /// that lands on it clips.
    public static let blackFloorTarget: Double = 0.0016
    /// How many slider units of 黑色 one **milli-unit of `blackOffset`** is worth when cancelling it.
    ///
    /// `blackOffset` 0.005 (the owner's median) lifts the black floor by that much *before* the exposure
    /// gain, so by `0.005 · 2^EV` after it; 黑色's first half is `v · 2^(3t·w)`. Calibrated so the
    /// cancel term reproduces the owner's own 黑色 median (−34.6 for a 0.005 trim → 30 units of cancel
    /// plus a few units of crush). The measured crush solve finishes the job; this is the analytic half
    /// that says the floor was lifted at all, and it is exactly what ⑧c deletes.
    public static let blackCancelPerMilli: Double = 6.0
    /// The 黑色 bracket step the crush bisects over, in slider units. 24 measured (L1030940: 0.03 % at
    /// −36 → 1.03 % at −48), so one step crosses the 0.1 % rule on a normal frame and the bracket only
    /// has to widen on a picture with almost nothing near black.
    public static let blackBracketUnits: Double = 24

    // MARK: - 步骤 5（对比）— 422 裁定：不做
    //
    // The three constants below are **kept and unused**. 422's verdict deleted step 5 (「对比不做」) and
    // with it the 分离度 criterion, because the criterion could not tell the owner's decisions apart
    // (`r = −0.092` on the boston+austria 308-frame sample; five frames alone were worse). They stay in
    // the source — not in `Plan`, which writes 0 — so a future attempt starts from the record instead of
    // from `git log`.

    /// Step 5 — **分离度**: the stops between p10 and p90, i.e. how far the picture's own body is spread.
    /// 422 裁定：未使用（对比不做）
    public static let separationTargetStops: Double = 4.1
    /// 422 裁定：未使用（对比不做）
    public static let separationStopsPerContrast: Double = 0.0314
    /// Deliberately equal to the owner's own **median** (+8.0) plus half again.
    /// 422 裁定：未使用（对比不做）
    public static let contrastCeiling: Double = 12

    /// Step 3's slope table for ⑧e — the **0 EV** numbers, and exactly the mistake the gate makes.
    ///
    /// The unit is **p99 per slider unit**, i.e. `Δp99(−100) / 100`. Measured on L1030433 at 0 EV:
    /// 高光 −100 moves p99 by −0.1280 → **0.001280 per unit**; 白色 −100 by −0.0999 → **0.000999**.
    /// At +2 EV the same two strokes are −0.9057 / −0.3995 (0.009057 / 0.003995 per unit), i.e. **7.1×**
    /// and **4.0×** — which is exactly what makes a table wrong by an order of magnitude on a hot frame.
    public static let zeroEVHighlightSlope: Double = 0.001280
    public static let zeroEVWhiteSlope: Double = 0.000999

    /// The grid every render in this algorithm is reduced to, and the price it sets.
    ///
    /// **256, and the number is measured.** At 512 the grid is 341×512 = 175 k texels and one `metrics()`
    /// costs **75 ms** (of which 124 ms of a full sort would be, before `percentiles(_:_:)` replaced it;
    /// the remaining cost is the filter pass and the two first differences). A 13-render run then costs
    /// **1.4 s** — too long for a button press that re-renders the loupe afterwards.
    ///
    /// At 256 it is 44 k texels and the same arithmetic is **~19 ms**, so a run is ~0.4 s. What that
    /// costs is the **resolution** of the texture estimate, not its meaning: the first difference is
    /// taken at a 8-picture-pixel stride instead of 4 on a 2000-px frame, which makes the loss *rate*
    /// noisier but not biased. §0c's own measurement used a 0.5-scale decode (≈1000 px long edge) and
    /// its 3.3× ratio reproduces at this grid too — `testTheCriterionSeparatesHighlightsFromWhitesPerUnitOfDarkening`
    /// asserts that on the shipping pipeline rather than trusting this note.
    public static let sampleLongEdge: Int = 256

    // MARK: - the algorithm

    /// Solve 明暗 for `edit`, asking `measure` for one render per evaluation.
    ///
    /// `measure` receives a **document** and returns that document's rendered grid; the caller wires it
    /// to `RenderGraph.measureAutoLightSample`. About a dozen renders at a 512-long-edge thumbnail
    /// (`report.renderCount` / `report.milliseconds` say what it cost).
    /// - Parameter lossAtDepth: **tests only.** Replace the measured 高光 texture loss (a function of the
    ///   slider depth in units) instead of rendering for it. `nil` — every production call — measures the
    ///   real thing through `measure`. It exists because the criterion's *decision* has to be testable on
    ///   a machine with no GPU and no RAW, exactly like `RenderOptions.forceCurveArithmetic`.
    public static func plan(for edit: EditModel,
                            gates: Gates = Gates(),
                            lossAtDepth: ((Double) throws -> Double)? = nil,
                            measure: (EditModel) throws -> Sample) throws -> Plan {
        let started = Date()
        var renders = 0
        func sample(_ document: EditModel) throws -> Sample {
            renders += 1
            return try measure(document)
        }

        // Step 0 — the baseline every step is measured against: 明暗 zeroed, `blackOffset` kept.
        var document = edit
        zero(&document)

        // ── 步骤 1 — 曝光 ────────────────────────────────────────────────────────────────────────
        let neutral = try sample(document).metrics()
        // ⑧d: anchoring on p95 is "reach SDR white" *without* the p99 ceiling — the gate's mistake, and
        // it over-exposes every picture that has a tail.
        let anchor = gates.noExposureCeiling ? neutral.p95 : neutral.p99
        var exposure = snapExposure(log2(p99WhiteTarget / max(anchor, 1e-5)))
        document.light.exposure = exposure
        var afterExposure = try sample(document).metrics()
        // **The tail guard is hard.** 422's verdict replaced `p99 ≤ 1.0` with a tail guard; the rework made
        // it **relative** (`p99.9 / p99 ≤ 1.6`) because an absolute 2.0 contradicts `p99 = 1.5` on 4/5 of
        // the owner's frames. The anchor (1.5) is deliberately above white, so what is guarded is how far
        // the top 0.1 % runs past it *in proportion*, and a candidate that exceeds the ratio is walked back
        // until it does not.
        var backstops = 0
        // ⑧d removes the constraint **and its enforcement**: gating only the anchor would still let the
        // walk-back hold the tail inside the ceiling, and the gate would prove nothing.
        //
        // **The loop stops when a step no longer lowers the ratio.** On a real photograph `p99.9/p99` is a
        // property of the picture, not of the gain — measured on L1030940 it is 1.831 at −0.5 EV *and* at
        // +3 EV — so a frame whose tail is genuinely thicker than the ceiling can never be walked back into
        // it. The old loop still spent 10 steps (0.5 stop of the calibration, ΔEV +0.61 → +0.11) and then
        // exited on the step count, not on the guard: it bought nothing and cost the frame its exposure.
        // The loop now takes the first step back (a real exceedance gets a real response) and then stops as
        // soon as the ratio fails to fall — the measurement saying "this tail is not a gain artefact".
        // `exposureBackstops` therefore reads 1 on such a frame rather than 10.
        while !gates.noExposureCeiling,
              afterExposure.p999 > afterExposure.p99 * p999OverP99Ceiling, backstops < 10, exposure > -4 {
            let ratioBefore = afterExposure.p999 / max(afterExposure.p99, 1e-9)
            exposure = snapExposure(exposure - 0.05)
            document.light.exposure = exposure
            afterExposure = try sample(document).metrics()
            backstops += 1
            let ratioAfter = afterExposure.p999 / max(afterExposure.p99, 1e-9)
            if ratioAfter >= ratioBefore - 1e-3 { break }
        }

        // ── 步骤 2 — 中间调 / 阴影 ──────────────────────────────────────────────────────────────
        var midtones = 0.0
        var shadows = 0.0
        if afterExposure.p50 > 1e-6, afterExposure.p50 < midtoneTarget {
            let needEV = log2(midtoneTarget / afterExposure.p50)
            let weight = max(S2Regions.weights(L: log2(afterExposure.p50)).mid, 0.2)
            let travel = max(S2Regions.midTravel * weight, 0.05)   // EV per 100 units at this level
            midtones = min(midtoneCap, max(0, (needEV / travel * 100).rounded()))
        }
        if afterExposure.p10 > 0, afterExposure.p10 < shadowTarget {
            let needEV = log2(shadowTarget / afterExposure.p10)
            let weight = max(S2Regions.weights(L: log2(max(afterExposure.p10, 1e-6))).shadow, 0.2)
            let travel = max(S2Regions.shadowTravel * weight, 0.05)
            shadows = min(shadowCap, max(0, (needEV / travel * 100).rounded()))
        }
        document.light.midtones = midtones
        document.light.shadows = shadows
        var afterStep2 = try sample(document).metrics()

        // ── 步骤 3 — 高光 / 白色（纹理损失判据）─────────────────────────────────────────────────
        //
        // The slopes are re-measured **here**, at the exposure step 1 chose (§0d): one render per tool,
        // both at −100, reduced to p99 per unit of travel.
        let highlightSlope: Double
        let whiteSlope: Double
        if gates.fixedSlopeTable {
            highlightSlope = zeroEVHighlightSlope
            whiteSlope = zeroEVWhiteSlope
        } else {
            var probe = document
            probe.light.highlights = -100
            highlightSlope = max((afterStep2.p99 - (try sample(probe).metrics()).p99) / 100, 1e-4)
            probe = document
            probe.light.whites = -100
            whiteSlope = max((afterStep2.p99 - (try sample(probe).metrics()).p99) / 100, 1e-4)
        }

        let textureBase = afterStep2.texture
        let textureAbsoluteBase = afterStep2.textureAbsolute

        var highlights = 0.0
        var whites = 0.0
        var highlightBudget = 0.0
        var highlightsOnlyLoss = 0.0
        let need = afterStep2.p99 - p99TopTarget
        if need > topDeadband, lossAtDepth != nil || textureBase > 0 {
            /// The normalised texture loss a 高光 depth (positive units) would cost.
            func loss(atDepth depth: Double) throws -> Double {
                if let lossAtDepth { return try lossAtDepth(depth) }
                var probe = document
                probe.light.highlights = -depth.rounded()
                let m = try sample(probe).metrics()
                return max(0, (textureBase - m.texture) / textureBase)
            }
            let full = min(100, need / highlightSlope)          // units 高光 would need alone
            let fullLoss: Double
            if gates.criterionAlwaysZeroLoss { fullLoss = 0 }
            else if gates.criterionAlwaysFullLoss { fullLoss = 0.99 }
            else { fullLoss = try loss(atDepth: full) }

            if fullLoss <= highlightLossThreshold {
                // 高光 alone is enough and stays inside the budget: 白色 is not used at all.
                highlights = -full.rounded()
                highlightBudget = -highlights
                highlightsOnlyLoss = fullLoss
            } else {
                // The deepest 高光 that stays inside the budget. Bisection on the depth, three probes:
                // the loss is monotone in the depth, and three halvings of a 0…100 bracket land within
                // 12 units — below the 1-unit grid the slider prints on.
                var allowed = 0.0        // deepest depth known to be inside
                var refused = full       // shallowest depth known to be outside
                if gates.criterionAlwaysFullLoss {
                    allowed = 0
                } else {
                    for _ in 0 ..< 3 {
                        let mid = (allowed + refused) / 2
                        if try loss(atDepth: mid) <= highlightLossThreshold {
                            allowed = mid
                        } else {
                            refused = mid
                        }
                    }
                }
                highlights = -allowed.rounded()
                highlightBudget = -highlights
                highlightsOnlyLoss = try loss(atDepth: -highlights)
                // 白色 then **joins** 高光 for the residual. Measured reason, not a preference: per unit
                // of p99 movement 白色 is *not* cheaper (L1030433 at +2 EV — 高光 −100 delivers −0.906,
                // 白色 −100 delivers −0.399 against −0.128/−0.100 at 0 EV), so "switch to 白色" would
                // deliver less than half the darkening; and at −100 it still cannot reach the target on
                // its own. What 白色 does well is reach past where 高光 stops, so the two run together.
                let delivered = -highlights * highlightSlope
                let remainder = need - delivered
                // 白色 is capped at `whiteTravelEnd` and engages only for a **real** gap. Measured
                // reason for the cap: 白色 delivers less than half the p99 movement 高光 does per unit
                // of travel, so a residual solved to −100 would be the algorithm shouting a target the
                // owner never asked for (their 白色 is 0 on all five boston frames, and −31.6 median
                // across the 19 % of the library that uses it).
                if remainder > whiteEngageDeadband {
                    whites = max(-whiteTravelEnd, -min(whiteTravelEnd, (remainder / whiteSlope).rounded()))
                }
            }
        }
        // The plan is checked, not trusted: **when 白色 was chosen**, one render of the finished pair and
        // 白色 is deepened while the target is still missed (both slopes are secants, so the first solve
        // is close, not exact). The loop is guarded on `whites < 0` on purpose: an unconditional
        // correction would deepen 白色 on a picture the criterion said needs none — which is ⑧a's exact
        // failure, and it was found by ⑧a's test rather than by reading the code.
        document.light.highlights = highlights
        document.light.whites = whites
        var verified = try sample(document).metrics()
        var passes = 0
        while whites < 0, verified.p99 > p99TopTarget + 0.02, whites > -whiteTravelEnd, passes < 2 {
            let over = verified.p99 - p99TopTarget
            whites = max(-whiteTravelEnd, (whites - over / whiteSlope).rounded())
            document.light.whites = whites
            verified = try sample(document).metrics()
            passes += 1
        }
        var textureLoss = textureBase > 0
            ? max(0, (textureBase - verified.texture) / textureBase) : 0
        var textureLossAbsolute = textureAbsoluteBase > 0
            ? max(0, (textureAbsoluteBase - verified.textureAbsolute) / textureAbsoluteBase) : 0

        // ── 步骤 4 — 黑色（抵消 blackOffset + 0.1 % 削底）───────────────────────────────────────
        //
        // Two terms, and they are different facts:
        //   · `cancel` — `blackOffset` lifted the floor before the exposure gain, so 黑色 gives that
        //     lift back. Read from the document, never written. ⑧c deletes this term.
        //   · the crush — deepen until 0.1 % of the pixels reach the bottom, solved from the
        //     **measured** response (one probe 25 units deeper) rather than from a table.
        let offset = document.light.blackOffset
        let cancel = gates.ignoresBlackOffset ? 0 : -(offset * 1000 * blackCancelPerMilli).rounded()
        var blacks = max(-100, min(0, cancel))
        document.light.blacks = blacks
        var afterBlacks = try sample(document).metrics()
        if afterBlacks.clippedLow < clipFloorFraction, blacks > -100 {
            // **Bisection on `clippedLow`, not a solve on p01.** Measured (L1030940 at +2 EV, from the
            // cancel term's −36): the bottom fraction is 0.03 % at −36 and 1.03 % at −48, while `p01`
            // has already collapsed to 0 by −60 — so a log2(p01) secant saturates and either stalls or
            // overshoots to −100. The clip fraction is monotone in the depth over the whole useful
            // range, and it is what the spec's rule is stated in (「刚好有 > 0.1% 的像素削底」).
            var shallow = blacks                        // too shallow: clips too little
            var deep = max(-100, blacks - 24)           // assumed too deep
            var deepMetrics = try sample({
                var probe = document
                probe.light.blacks = deep
                return probe
            }()).metrics()
            // Widen once if 24 units were not enough to cross the threshold.
            if deepMetrics.clippedLow < clipFloorFraction, deep > -100 {
                shallow = deep
                deep = max(-100, deep - 24)
                var probe = document
                probe.light.blacks = deep
                deepMetrics = try sample(probe).metrics()
            }
            // Four halvings land a 24-unit bracket inside 1.5 units — finer than any look.
            for _ in 0 ..< 4 where deep - shallow < -0.5 && deepMetrics.clippedLow >= clipFloorFraction {
                let mid = ((shallow + deep) / 2).rounded()
                var probe = document
                probe.light.blacks = mid
                let m = try sample(probe).metrics()
                if m.clippedLow >= clipFloorFraction {
                    deep = mid
                    deepMetrics = m
                } else {
                    shallow = mid
                }
            }
            blacks = max(-100, min(0, deep))
            document.light.blacks = blacks
            // The bracket's own deepest measurement is the answer's metric when it is the answer.
            afterBlacks = deepMetrics
        }
        let clippedLowAfterBlacks = afterBlacks.clippedLow

        // ── 步骤 5 — 对比 — **422 裁定：不做** ─────────────────────────────────────────────────────
        //
        // The verdict (「对比不做，曝光按我的习惯来」) deleted the step. `contrast` stays a field — `Plan`
        // keeps writing `light.contrast = 0`, which is what the "seven fields" assertion reads — and the
        // report still carries the *measured* `separationStops` beside the always-zero `contrast`, so a
        // future rule can be argued against a number instead of a memory.
        let separation = afterBlacks.separationStops
        let contrast = 0.0

        return Plan(exposure: exposure, contrast: contrast, highlights: highlights,
                    midtones: midtones, shadows: shadows, whites: whites, blacks: blacks,
                    report: Report(baseP99: neutral.p99, exposureEV: exposure,
                                   p99AfterExposure: afterExposure.p99,
                                   p999OverP99AfterExposure: afterExposure.p999
                                       / max(afterExposure.p99, 1e-9),
                                   exposureBackstops: backstops,
                                   clippedHighAfterExposure: afterExposure.clippedHigh,
                                   p50AfterExposure: afterExposure.p50,
                                   midtones: midtones, shadows: shadows,
                                   p50AfterStep2: afterStep2.p50,
                                   p10AfterStep2: afterStep2.p10,
                                   p99AfterStep2: afterStep2.p99, p99Target: p99TopTarget,
                                   highlightSlope: highlightSlope, whiteSlope: whiteSlope,
                                   tableHighlightSlope: zeroEVHighlightSlope,
                                   tableWhiteSlope: zeroEVWhiteSlope,
                                   textureBase: textureBase,
                                   textureAbsoluteBase: textureAbsoluteBase,
                                   textureLoss: textureLoss,
                                   textureLossHighlightsOnly: highlightsOnlyLoss,
                                   textureLossAbsolute: textureLossAbsolute,
                                   highlightBudget: highlightBudget,
                                   usedWhites: whites < 0,
                                   blackOffset: offset, blackCancelTerm: cancel,
                                   clippedLowAfterBlacks: clippedLowAfterBlacks,
                                   separationStops: separation, contrast: contrast,
                                   renderCount: renders,
                                   milliseconds: (Date().timeIntervalSince(started) * 1000).rounded(),
                                   textureLossThreshold: highlightLossThreshold,
                                   p99Final: afterBlacks.p99))
    }

    /// 明暗 zeroed, everything else (including `light.blackOffset`) untouched.
    static func zero(_ edit: inout EditModel) {
        edit.light.exposure = 0
        edit.light.contrast = 0
        edit.light.highlights = 0
        edit.light.midtones = 0
        edit.light.shadows = 0
        edit.light.whites = 0
        edit.light.blacks = 0
    }

    /// Clamp into `LightGroup`'s travel and snap to the row's own grid (曝光 lives on 0.01 EV — the
    /// tabulated quantum in `InspectorView.lightRows`). Always rounds **down**, so the ceiling holds.
    static func snapExposure(_ ev: Double) -> Double {
        guard ev.isFinite else { return 0 }
        let bounded = min(max(ev, -4), 8)
        return (bounded * 100).rounded(.down) / 100
    }

    // MARK: - ⑧a–⑧e: the five reverse gates (tests only)

    /// **Tests only.** Each flag makes one load-bearing line of the algorithm inert, so the test that
    /// argues for that line can be shown to go red. All five are `false` in production — the app never
    /// sets one, and they are not part of any document, key or golden.
    public struct Gates: Sendable, Equatable {
        /// ⑧a — the criterion always reports **0 %** loss, i.e. 白色 is never reached.
        public var criterionAlwaysZeroLoss = false
        /// ⑧b — the criterion always reports **99 %**, i.e. 白色 is always reached.
        public var criterionAlwaysFullLoss = false
        /// ⑧c — step 4 starts from 0 instead of from `blackOffset`'s lift.
        public var ignoresBlackOffset = false
        /// ⑧d — step 1 anchors on p95 instead of p99, i.e. the `p99.9 / p99 ≤ 1.6` tail guard is gone.
        public var noExposureCeiling = false
        /// ⑧e — the slopes come from the **0 EV** table instead of being re-measured (§0d's 7.1×).
        public var fixedSlopeTable = false

        public init() {}
    }
}

// MARK: - the sample's statistics

extension AutoLight.Sample {

    /// Everything the algorithm reads, in one pass over the grid.
    ///
    /// - Parameter cut: the highlight region's luma floor. `nil` = this render's own top 10 %, which is
    ///   §0c's definition; passing an earlier render's value measures a *fixed* region instead (the
    ///   probe compares the two spellings — a fixed floor empties out as the region darkens).
    public func metrics(cut: Float? = nil, topFraction: Double = 0.10) -> AutoLight.Metrics {
        var picture: [Float] = []
        picture.reserveCapacity(luma.count)
        for v in luma where AutoLight.Sample.isPicture(v) { picture.append(v) }
        guard !picture.isEmpty else {
            return AutoLight.Metrics(p01: 0, p10: 0, p50: 0, p90: 0, p95: 0, p99: 0, p999: 0,
                                     peak: 0, clippedHigh: 0, clippedLow: 0, texture: 0,
                                     textureAbsolute: 0, cut: 0, sampleCount: 0)
        }
        let n = picture.count
        // The eight ranks the algorithm reads, plus the region's own floor when it has to be derived.
        // The region's rank is inserted in order so the selection stays ascending.
        var ranks: [Double] = [0.01, 0.10, 0.50, 0.90, 0.95, 0.99, 0.999, 1.0]
        let regionRank = 1 - topFraction
        if cut == nil {
            ranks.append(regionRank)
            ranks.sort()
        }
        let values = AutoLight.percentiles(picture, ranks)
        func value(_ rank: Double) -> Double {
            values[ranks.firstIndex(of: rank) ?? 0]
        }
        let region = cut ?? Float(value(regionRank))
        var high = 0, low = 0
        for v in picture {
            if v > 1 { high += 1 }
            if v <= 0.001 { low += 1 }
        }
        let textures = self.textures(atOrAbove: region)
        return AutoLight.Metrics(p01: value(0.01),
                                 p10: value(0.10),
                                 p50: value(0.50),
                                 p90: value(0.90),
                                 p95: value(0.95),
                                 p99: value(0.99),
                                 p999: value(0.999),
                                 peak: value(1.0),
                                 clippedHigh: Double(high) / Double(n),
                                 clippedLow: Double(low) / Double(n),
                                 texture: textures.0,
                                 textureAbsolute: textures.1,
                                 cut: region, sampleCount: n)
    }

    /// Both spellings of §0c's contrast in **one** walk: the right-hand side shows both numbers on
    /// every report, and two passes over a 175 k-texel grid cost 40 ms for nothing.
    ///
    /// Returns `(normalised, absolute)`.
    public func textures(atOrAbove cut: Float) -> (Double, Double) {
        guard width > 1, height > 1 else { return (0, 0) }
        var normSum = 0.0, absSum = 0.0
        var normCount = 0, absCount = 0
        for y in 0 ..< (height - 1) {
            let row = y * width
            for x in 0 ..< (width - 1) {
                let i = row + x
                let L = luma[i]
                guard L >= cut, AutoLight.Sample.isPicture(L) else { continue }
                let right = luma[i + 1]
                let below = luma[i + width]
                guard AutoLight.Sample.isPicture(right),
                      AutoLight.Sample.isPicture(below) else { continue }
                let d = (abs(Double(right) - Double(L)) + abs(Double(below) - Double(L))) * 0.5
                absSum += d
                absCount += 1
                // A level at or below 1e-5 is the black floor rather than a highlight; dividing there
                // would divide by ~0 and report a texture no picture has.
                if Double(L) > 1e-5 {
                    normSum += d / Double(L)
                    normCount += 1
                }
            }
        }
        return (normCount > 0 ? normSum / Double(normCount) : 0,
                absCount > 0 ? absSum / Double(absCount) : 0)
    }

    /// §0c's local contrast over the texels at or above `cut`:
    ///
    ///     textureAbsolute = mean( |∂L/∂x| + |∂L/∂y| ) / 2          — the literal formula
    ///     texture         = mean( (|∂L/∂x| + |∂L/∂y|) / 2 / L )    — the one shipped
    ///
    /// **Why the shipped one divides by `L`.** The literal formula is a difference of *light*, so it
    /// falls whenever the region merely becomes darker: it cannot tell "the contrast collapsed" from
    /// "there is less light there". Measured on L1030433 at 高光 −50: **21.7 % at 0 EV and 41.0 % at
    /// +2 EV** — for the same slider, i.e. the number is a function of the exposure it was measured at.
    /// Divided by the local level (Weber contrast) the same two are **7.5 % and 16.3 %**, and the ratio
    /// between the two sliders becomes §0c's: **3.4× against the spec's 3.32×**, where the literal
    /// formula reads 2.0× because both of its numbers are inflated by the same darkening.
    ///
    /// Both are carried in `Metrics`, so a report can print the literal one beside it.
    public func texture(atOrAbove cut: Float, absolute: Bool) -> Double {
        let both = textures(atOrAbove: cut)
        return absolute ? both.1 : both.0
    }
}
