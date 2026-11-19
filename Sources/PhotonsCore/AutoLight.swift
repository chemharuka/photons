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
        public var clippedHDR: Double
        /// Fraction of picture samples at or below 0.001 linear.
        public var clippedBlack: Double
        /// **426d — 撞到屏幕 HDR 上限的像素占比**（`v >= HighlightCeiling.defaultLinear × peakMargin`）。
        ///
        /// 与 `peak` 的关系：S2 会把超限像素钳到恰好 ceiling，所以 `peak` 饱和后恒为 4.92、斜率 0，
        /// 无法判断「压下去了没有」；这个计数是单调的，用来求解与验收。
        ///
        /// 与 `clippedHDR` 的关系：`clippedHDR` 是「> SDR 白」，大面积天空/雪本来就该是白的
        /// （owner 的 L1030940 成品 17.9 %），而这个是「撞到 HDR 上限、正在丢信息」。
        public var clippedScreen: Double
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
        /// **426d** — step 1 之后的大面积高光分位；曝光的锚点就是它（`broadHighlightTarget`）。
        public var p95AfterExposure: Double
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

    /// Step 1's anchor: **the exposure that puts the picture's body where it belongs, not a fixed p99.**
    ///
    /// **426d 裁定 (2026-11-19) — 用户的算法，第一性原理.** The owner's words:
    ///
    /// > 「EV 的目标是把主体曝光放在合适的位置，如果高光太亮就 EV 少一些，通过中间调和阴影拉高主体。
    /// >  高光部分可能是天空可能是窗户可能是灯光，这些部分如果是大面积的，那么就尽量控制在 +1 内。
    /// >  然后要通过白色和高光将最高亮的像素压到 clippedScreen 以下」
    ///
    /// 所以 EV 有**两个约束，取小者**：
    ///   ① 主体：p50 落到 `bodyTarget`（题材相关，不是固定值 —— 见 `bodyTarget` 的注释）
    ///   ② 大面积高光：p95 落到 `broadHighlightTarget`（SDR 白附近 = 「控制在 +1 内」）
    ///
    /// **为什么锚 p95 而不是 p99（旧口径）**：在 owner 自己的五帧 boston 上实测反推，把 EV 除以
    /// 2^EV 得到的「target」是 p95 最稳定 ——
    ///
    /// | 分位 | 反推 target 范围 | 跨度 |
    /// |---|---|---|
    /// | p50 | 0.083–0.644 | **7.8×** |
    /// | **p95** | **0.800–1.416** | **1.77×** |
    /// | p99 | 1.004–1.774 | 1.77× |
    ///
    /// p50 差 7.8 倍说明主体位置随题材变（夜景 vs 室内），p95 稳定说明**大面积高光**才是
    /// 曝光上限的那个量。这也正是 owner 的原话「大面积的尽量控制在 +1 内」。
    ///
    /// ⚠ **旧口径 `p99 → 1.5` 的错误**：p99 = 1.5 意味着「99 分位放到 1.5」，而 SDR 白是 1.0 ⇒
    /// **制造约 1% 的必然过白**。owner 的五帧成品里 p99 从 0.833 到 1.259 都有，从不是 1.5。
    ///
    /// **1.1 是标定出来的**：在 owner 的五帧 boston 成品上反推 `log2(target / baseP95)` 与手调 EV
    /// 的差，逐 target 的中位 \|差\| 是 0.9→0.29 / 1.0→0.32 / **1.1→0.21** / 1.2→0.24 / 1.4→0.35 /
    /// 1.6→0.54。1.1 也落在 owner 成品 p95（0.663–1.174）的中段。
    public static let broadHighlightTarget: Double = 1.1

    /// **426d — 大面积高光的许可上限**：`clippedHDR`（>SDR 白的像素占比）超过它就该降 EV。
    ///
    /// 用户原话：「高光部分可能是天空可能是窗户可能是灯光，这些部分如果是大面积的，那么就尽量
    /// 控制在 +1 内」。5 % 来自 owner 五帧的实测分布：四帧 ≤ 2.7 %，只有 L1030940（整片天空）
    /// 是 17.9 % —— 所以 5 % 是「普通画面该守住的线」，超过它说明 EV 给多了。
    public static let clippedHighCeiling: Double = 0.05

    /// **426d — 对比的行程下限**（只在极端情况下用到）。
    ///
    /// owner 口径：「最后极端情况下如果白色+高光+中间调+阴影都实现不了，还能减对比度来拉下」。
    /// −30 是保守的：再深会把画面压平到没有层次，那时宁可让一点点撞上限留着。
    public static let contrastFloor: Double = -30

    /// Step 3's goal (426d): **the brightest pixel ends below `clippedScreen`**.
    ///
    /// > 「通过白色和高光将最高亮的像素压到 clippedScreen 以下」
    ///
    /// Measured on the owner's five finished frames: every one lands `peak ≤ ceiling` (5/5), and two of
    /// them (L1030940, L1030942) sit **exactly on** 4.92 — i.e. the owner pushes 高光 until the peak
    /// touches the ceiling and stops, while tolerating 17.9 % / 2.4 % of ordinary white clipping from
    /// the *large* bright area. Those are two different quantities and this constant is the second one.
    ///
    /// ⚠ **Not `p99TopTarget`** (1.2): that was a p99 anchor, which is exactly the mistake — p99 says
    /// nothing about the single brightest pixel.
    public static let peakMargin: Double = 0.995

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
    /// **426d: 40 → 100.** owner 口径：「主体也能通过中间调 +100 …拉到合适水平」。
    /// 旧的 40 是 422 从 owner 使用分布（中位 +16.3）推的上限，但那是**手调成品**的分布，
    /// 不是自动算法的许可；自动算法需要它来补 EV 让路之后的亮度。
    public static let midtoneCap: Double = 100
    public static let shadowTarget: Double = 0.005
    /// **426d: 30 → 50.** owner 口径：「阴影加到 40–50 拉到合适水平」。
    public static let shadowCap: Double = 50

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

    /// **426d: 高光的上限由 `highlightLossThreshold`（纹理预算）决定，不设数字上限。**
    ///
    /// owner 口径：「高光减多少上限其实取决于高光纹理，无纹理的比如天空 −100 都没关系，
    /// 但有纹理就不能 −100 否则丢失高光对比度」。
    ///
    /// 所以「能推多深」是**测量出来的**：`loss(atDepth:)` 给出某深度的纹理损失，算法取
    /// 仍在 `highlightLossThreshold`（8 %）以内的最深处。一片天空几乎没有一阶差分，loss 极低
    /// ⇒ 允许到 −100；一片有云的天空纹理丰富，loss 很快超预算 ⇒ 停在 −40 附近。
    ///
    /// ⚠ 不要把这个换成固定数字（−80 / −100）。那会把「无纹理可以推到底」和
    /// 「有纹理必须收手」这两种情况压成同一个答案。

    /// The most 白色 this algorithm will ask for, and the residual below which it does not engage at
    /// all. Both from the owner's own usage (白色 is 0 on all five boston frames; −31.6 median, −100
    /// min across the 19 % of the library that touches it) and from §1's 「要么不动、要么 ≥ −60」.
    /// **426d: 60 → 100.** owner 口径：「大面积高光也能通过白色 −100、高光减少 50–60 左右拉回很多」。
    /// 60 会让「白色已经用到底但仍撞上限」的帧停在差一点点的地方，而 owner 明确允许 −100。
    public static let whiteTravelEnd: Double = 100
    public static let whiteEngageDeadband: Double = 0.04

    /// Step 4: >0.1 % of the pixels clipping at the bottom.
    public static let clipFloorFraction: Double = 0.001
    /// The black floor the crush aims at: 0.0016 is one hair below `clippedBlack`'s own 0.001, so a solve
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
        // **426d — 曝光的唯一驱动量：大面积高光。**
        //
        // owner 的原话是「如果高光太亮就 EV 少一些，通过中间调和阴影拉高主体」——所以 EV 由**高光**
        // 决定，主体不足由步骤 2 补，EV 不为主体让路。
        //
        // 标定：在 owner 自己的五帧 boston 成品上反推 `log2(target / baseP95)`，逐 target 比对手调 EV：
        //   target 0.9 → 中位差 0.29 | 1.0 → 0.32 | **1.1 → 0.21** | 1.2 → 0.24 | 1.4 → 0.35 | 1.6 → 0.54
        // 1.1 是最贴合的（逐帧 −0.36/+0.46/+0.11/−0.00/−0.21），也落在 owner 成品 p95 的中段。
        var exposure = snapExposure(log2(broadHighlightTarget / max(neutral.p95, 1e-5)))
        // ⚠ 旧的 `p99 → 1.5` 口径只在反向门 ⑧d 打开时复现，好让门能证明新规则确实换了驱动量。
        if gates.noExposureCeiling {
            exposure = snapExposure(log2(p99WhiteTarget / max(anchor, 1e-5)))
        }
        document.light.exposure = exposure
        var afterExposure = try sample(document).metrics()
        // **422's tail guard is retired by 426d.** It walked exposure *back* whenever `p99.9/p99`
        // exceeded 1.6, and 422's own note records the outcome: on L1030940 the ratio is 1.831 at both
        // −0.5 EV and +3 EV — it is a property of the picture, not of the gain — so the walk-back could
        // never fix it and only cost the frame its exposure. Measured cost: 426b's variant spent it and
        // landed 0.46–1.89 stops dark on five frames.
        //
        // 426d's exposure rule already bounds the top from the *large* highlight (p95 → 1.0), which is
        // what the guard was trying to approximate from the other end. A thick tail beyond that is the
        // picture's own business — the owner's L1030940 finished with 17.9 % of pixels above white and
        // was accepted, because what they constrain is `peak ≤ clippedScreen` (step 3), not p99.9.
        //
        // `exposureBackstops` stays in the report as a constant 0 so 422's A③ still has something to read.
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
        // **426d: 这条 walk-back 已删除。** 见上方注释。⑧d 仍需要它来证明旧行为，所以只在 gate
        // 打开时执行，生产路径恒 0 次。
        while gates.noExposureCeiling == false, gates.keepsTailGuard,
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

        // ── 步骤 3 — 高光 / 白色 / 中间调 / 阴影 / 对比（426d：面多了加水 水多了加面）─────────
        //
        // **用户的算法（原话）**：
        //   「大面积高光也能通过白色 −100，高光减少 50–60 左右拉回很多，而主体也能通过中间调 +100，
        //    阴影加到 40–50 拉到合适水平。很多时候 EV 稍微不对也没关系，面多了加水 水多了加面，
        //    所以不要太纠结 EV 的值。我的目标是优先用白色+高光，如果白色高光要减得比较多，
        //    就少一些 EV，加中间调和阴影。最后极端情况下如果白色+高光+中间调+阴影都实现不了，
        //    还能减对比度来拉下」
        //
        // 求解目标只有一个：**`clippedScreen` 归零**（撞到屏幕 HDR 上限的像素占比）。
        // 为什么不是 `peak`：S2 的 `min(v, ceiling)` 把超限像素钳到恰好 ceiling，`peak` 饱和后
        // 恒为 4.92、斜率 0（实测 L1030940 在高光 0/−10/−20/−40 时 peak 全是 4.92），数值不可用；
        // 计数是单调的（11.67 % → 7.81 → 3.99 → 0.43 %）。
        //
        // 求解顺序就是用户给的优先级：
        //   ① 高光（深度由**纹理预算**决定，不是固定上限 —— 天空可到 −100，有纹理的高光会早停）
        //   ② 白色（补高光之后的残余，到 −100）
        //   ③ 仍不够 ⇒ 减少 EV，然后用中间调/阴影把主体拉回来（这一步不降 EV 就不做）
        //   ④ 极端情况 ⇒ 降低对比
        //
        // ⚠ 注意 ③ 的代价：EV 一降，`clippedHDR`（>SDR 白）会跟着降，画面整体变暗 ——
        // 这正是用户说的「面多了加水」。所以它**只在 ①② 用尽后**触发，不做迭代优化。
        let textureBase = afterStep2.texture
        let textureAbsoluteBase = afterStep2.textureAbsolute

        /// 高光在 depth（正数单位）处的归一化纹理损失。
        func loss(atDepth depth: Double) throws -> Double {
            if let lossAtDepth { return try lossAtDepth(depth) }
            var probe = document
            probe.light.highlights = -depth.rounded()
            let m = try sample(probe).metrics()
            return max(0, (textureBase - m.texture) / textureBase)
        }

        /// 在纹理预算内，高光能压到的最深单位数（0…100）。
        ///
        /// **这才是高光的真实上限** —— 一片天空几乎没有一阶差分，loss 极低，可到 −100；
        /// 有纹理的高光几档就超预算，会早停在 −40 附近。用户原话：「高光减多少上限其实取决于
        /// 高光纹理，无纹理的比如天空 −100 都没关系，但有纹理就不能 −100 否则丢失高光对比度」。
        func deepestHighlightWithinBudget() throws -> Double {
            if gates.criterionAlwaysZeroLoss { return 100 }
            if gates.criterionAlwaysFullLoss { return 0 }
            // 先试满行程：够用就不必二分（大多数帧走这里）。
            if try loss(atDepth: 100) <= highlightLossThreshold { return 100 }
            // 否则在 0…100 上二分三次，落点误差 ≤ 12 单位，小于滑杆的 1 单位格。
            var allowed = 0.0
            var refused = 100.0
            for _ in 0 ..< 3 {
                let mid = (allowed + refused) / 2
                if try loss(atDepth: mid) <= highlightLossThreshold {
                    allowed = mid
                } else {
                    refused = mid
                }
            }
            return allowed
        }

        /// **③ 的配套：EV 降下来之后，用中间调/阴影把主体拉回去。**
        ///
        /// 用户原话：「如果白色高光要减得比较多，就少一些 EV，加中间调和阴影」。
        /// 所以每降一次 EV 就重算这两个滑块 —— 这是「水多了加面」的那一把面。
        ///
        /// 目标仍然是 `midtoneTarget` / `shadowTarget` 这两个**地板**（不是目标值），
        /// 而且会把已有的中间调/阴影算进去（累计，不是覆盖），因为之前的步骤 2 可能已经加过。
        func refillBody() throws {
            var probe = document
            probe.light.midtones = 0
            probe.light.shadows = 0
            let bare = try sample(probe).metrics()
            var addMid = 0.0
            var addShadow = 0.0
            if bare.p50 > 1e-6, bare.p50 < midtoneTarget {
                let needEV = log2(midtoneTarget / bare.p50)
                let weight = max(S2Regions.weights(L: log2(bare.p50)).mid, 0.2)
                let travel = max(S2Regions.midTravel * weight, 0.05)
                addMid = (needEV / travel * 100).rounded()
            }
            if bare.p10 > 0, bare.p10 < shadowTarget {
                let needEV = log2(shadowTarget / bare.p10)
                let weight = max(S2Regions.weights(L: log2(max(bare.p10, 1e-6))).shadow, 0.2)
                let travel = max(S2Regions.shadowTravel * weight, 0.05)
                addShadow = (needEV / travel * 100).rounded()
            }
            midtones = min(midtoneCap, max(0, addMid))
            shadows = min(shadowCap, max(0, addShadow))
            document.light.midtones = midtones
            document.light.shadows = shadows
        }

        var highlights = 0.0
        var whites = 0.0
        var contrast = 0.0
        var highlightBudget = 0.0
        var highlightsOnlyLoss = 0.0
        var evRelaxSteps = 0
        var contrastRelaxed = false

        document.light.highlights = 0
        document.light.whites = 0
        var stage = try sample(document).metrics()

        // **①② 一套工具：压高光、补白色。**
        func applyHighlightAndWhite() throws {
            // ① 高光 — 深度受纹理预算约束
            let depth = try deepestHighlightWithinBudget()
            highlights = -depth.rounded()
            highlightBudget = -highlights
            highlightsOnlyLoss = try loss(atDepth: -highlights)
            document.light.highlights = highlights

            var m = try sample(document).metrics()
            // ② 白色 — **二分求解**（对目标量单调：推得越深，超限/撞上限的越少）。
            //
            // **426d: 介入条件是「`clippedScreen > 0` 或 `clippedHDR` 超标」**，不只是前者。
            // 用户的口径是「优先用白色+高光，如果白色高光要减得比较多，就少一些 EV」——
            // 所以大面积过白（clippedHDR）也要先由高光+白色处理，降 EV 是它们不够时才做的。
            //
            // 为什么不用斜率：`clippedScreen` 是计数，归零后斜率为 0，而斜率是割线（一段近似），
            // 在「刚好跨过 0」附近会过冲。二分 4 次把 −100 的区间收到 6 单位内，比任何切线都稳。
            // 目标：`clippedScreen` 归零；若它已经 0，则把 `clippedHDR` 压到 `clippedHighCeiling` 以内。
            func settled(_ mm: AutoLight.Metrics) -> Bool {
                mm.clippedScreen <= 0 && mm.clippedHDR <= clippedHighCeiling
            }
            if !settled(m) {
                var shallow = 0.0          // 已知不够（仍在超限）
                var deep = -whiteTravelEnd // 已知最深的候选
                var deepMetrics = m
                var probe = document
                probe.light.whites = deep
                deepMetrics = try sample(probe).metrics()
                if settled(deepMetrics) {
                    // 二分找「刚好归零」的最浅深度
                    for _ in 0 ..< 4 {
                        let mid = ((shallow + deep) / 2).rounded()
                        var q = document
                        q.light.whites = mid
                        let qm = try sample(q).metrics()
                        if settled(qm) { deep = mid; deepMetrics = qm } else { shallow = mid }
                    }
                    whites = deep
                } else {
                    whites = -whiteTravelEnd    // 到底仍不够：留给 ③ 降 EV
                    deepMetrics = m
                }
                document.light.whites = whites
                m = whites < 0 ? (try sample(document).metrics()) : m
            }
            stage = m
        }

        // 斜率：**仍按 p99 测**（连续量，可作「推多少单位」的 proxy）。
        //
        // ⚠ 不能用 `clippedScreen` 测斜率：它是**计数**，一旦归零斜率为 0，而求解恰恰是在
        // 「已归零」的帧上也要能工作；且计数在 0 附近不连续（一个像素跨过去就跳 1/N）。
        // 真正的求解用二分（见 `applyHighlightAndWhite`），斜率只是给报告和 ⑧e 门用的。
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

        // **① ② 总是先跑**：`clippedHDR` 超标（大面积高光过亮）与 `clippedScreen` 是两件事，
        // 前者 ALSO 需要高光/白色介入 —— 之前把整块藏在 `clippedScreen > 0` 里，导致
        // L1030941（clippedScreen=0 但 clippedHDR=7.57 %）完全没被处理。
        try applyHighlightAndWhite()
        if stage.clippedScreen > 0 || stage.clippedHDR > clippedHighCeiling {
            // **②b 大面积高光太亮 ⇒ 少一些 EV。**
            //
            // 用户原话：「如果高光太亮就 EV 少一些」。这里「太亮」用 `clippedHDR`（>SDR 白的像素占比）
            // 度量 —— 不是 p95：在 owner 的五帧成品上 `p95×2^EV` 是 0.80…1.42，而 `clippedHDR` 是
            // 0.05 %…17.93 %，**同样的 p95 target 差 360 倍**，说明 p95 不决定「有多白」。
            //
            // 目标 `clippedHighCeiling` = 5 %：owner 五帧里四帧 ≤ 2.7 %，L1030940 的 17.9 % 是大面积
            // 天空的特例；5 % 把「普通画面」和「整片天空」分开，同时不至于把普通帧压得太暗。
            var highRelaxSteps = 0
            while stage.clippedHDR > clippedHighCeiling, highRelaxSteps < 3, exposure > -4 {
                exposure = snapExposure(exposure - 0.15)
                document.light.exposure = exposure
                highRelaxSteps += 1
                try refillBody()
                document.light.highlights = 0
                document.light.whites = 0
                highlights = 0
                whites = 0
                try applyHighlightAndWhite()
            }
            if highRelaxSteps > 0 { evRelaxSteps += highRelaxSteps }

            // ③ 高光压在纹理预算内、白色也用到底，仍然撞上限 ⇒ **减少 EV**，再用中间调/阴影补主体。
            // 每次降 0.15 档，最多 4 次（0.6 档）—— 用户说「不要太纠结 EV 的值」，所以这不是求最优，
            // 而是「够用就停」。每步都把中间调/阴影重算一遍，让主体回到位（水多了加面）。
            while stage.clippedScreen > 0, evRelaxSteps < 4, exposure > -4 {
                exposure = snapExposure(exposure - 0.15)
                document.light.exposure = exposure
                evRelaxSteps += 1
                try refillBody()
                document.light.highlights = 0
                document.light.whites = 0
                highlights = 0
                whites = 0
                try applyHighlightAndWhite()
                if stage.clippedScreen <= 0 { break }
                // 这一档没换来改善就停手，别把 EV 一路降下去（面多了加水要看得见效果）
                if evRelaxSteps >= 2, stage.clippedScreen > 0.002 { break }
            }

            // ④ 极端情况：①②③ 都压不住 ⇒ 降对比（对比把高光往下拉，代价是画面变平）
            if stage.clippedScreen > 0 {
                // 每步 −4，最多到 `contrastFloor`。一有改善就收（不追最优）。
                var c = 0.0
                while stage.clippedScreen > 0, c > contrastFloor {
                    c = max(contrastFloor, c - 4)
                    var probe = document
                    probe.light.contrast = c
                    let m = try sample(probe).metrics()
                    contrast = c
                    document.light.contrast = c
                    stage = m
                }
                contrastRelaxed = contrast < 0
            }
        }

        // 中间调/阴影要把主体的最终位置记进报告；`stage` 就是成品的那一帧。
        let verified = stage
        let textureLoss = textureBase > 0
            ? max(0, (textureBase - verified.texture) / textureBase) : 0
        let textureLossAbsolute = textureAbsoluteBase > 0
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
        if afterBlacks.clippedBlack < clipFloorFraction, blacks > -100 {
            // **Bisection on `clippedBlack`, not a solve on p01.** Measured (L1030940 at +2 EV, from the
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
            if deepMetrics.clippedBlack < clipFloorFraction, deep > -100 {
                shallow = deep
                deep = max(-100, deep - 24)
                var probe = document
                probe.light.blacks = deep
                deepMetrics = try sample(probe).metrics()
            }
            // Four halvings land a 24-unit bracket inside 1.5 units — finer than any look.
            for _ in 0 ..< 4 where deep - shallow < -0.5 && deepMetrics.clippedBlack >= clipFloorFraction {
                let mid = ((shallow + deep) / 2).rounded()
                var probe = document
                probe.light.blacks = mid
                let m = try sample(probe).metrics()
                if m.clippedBlack >= clipFloorFraction {
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
        let clippedLowAfterBlacks = afterBlacks.clippedBlack

        // ── 步骤 5 — 对比 — **422 裁定：不做** ─────────────────────────────────────────────────────
        //
        // The verdict (「对比不做，曝光按我的习惯来」) deleted the step. `contrast` stays a field — `Plan`
        // keeps writing `light.contrast = 0`, which is what the "seven fields" assertion reads — and the
        // report still carries the *measured* `separationStops` beside the always-zero `contrast`, so a
        // future rule can be argued against a number instead of a memory.
        let separation = afterBlacks.separationStops
        // **426d**: `contrast` 现在是 ④ 求解出来的值（极端情况下才非 0），不再是硬写 0。

        return Plan(exposure: exposure, contrast: contrast, highlights: highlights,
                    midtones: midtones, shadows: shadows, whites: whites, blacks: blacks,
                    report: Report(baseP99: neutral.p99, exposureEV: exposure,
                                   p99AfterExposure: afterExposure.p99,
                                   p95AfterExposure: afterExposure.p95,
                                   p999OverP99AfterExposure: afterExposure.p999
                                       / max(afterExposure.p99, 1e-9),
                                   exposureBackstops: backstops,
                                   clippedHighAfterExposure: afterExposure.clippedHDR,
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
        /// ⑧d — **426d 重定义**：步骤 1 退回旧口径（`p99 → 1.5` + tail guard walk-back）。
        /// 生产路径走新的「p95 大面积高光 + 主体兜底」规则，所以这个 gate 打开时才复现旧行为，
        /// 门才能证明新规则确实改变了曝光。
        public var noExposureCeiling = false
        /// ⑧e — the slopes come from the **0 EV** table instead of being re-measured (§0d's 7.1×).
        public var fixedSlopeTable = false

        /// ⑧d 的配套：只在 `noExposureCeiling` 打开时才有意义的旧 tail guard。
        /// 生产恒 `false` —— 426d 删掉了这条 walk-back（理由见步骤 1 的注释）。
        public var keepsTailGuard = false

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
                                     peak: 0, clippedHDR: 0, clippedBlack: 0, clippedScreen: 0, texture: 0,
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
        var high = 0, low = 0, screen = 0
        // **426d — `clippedScreen`: 撞到当前屏幕 HDR 上限的像素占比。**
        //
        // 为什么必须单独计数：S2 的 `min(v, ceiling)` 会把超限像素**压到恰好等于 ceiling**，所以
        // `peak` 一旦饱和就恒等于 4.92 —— 实测 L1030940 在高光 0/−10/−20/−40 时 `peak` 都是 4.92，
        // 斜率恒 0，无法用 `peak` 的数值判断「压到上限以下了没有」。而计数是单调的（11.67 % →
        // 7.81 → 3.99 → 0.43 %），正是用户要的那个量。
        //
        // 阈值取 `ceiling × peakMargin`：留 0.5 % 余量，避免把「刚好等于 ceiling 的合法像素」
        // 算成削顶（S2 的钳制就落在那儿）。
        let screenFloor = Float(HighlightCeiling.defaultLinear * AutoLight.peakMargin)
        for v in picture {
            if v > 1 { high += 1 }
            if v <= 0.001 { low += 1 }
            if v >= screenFloor { screen += 1 }
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
                                 clippedHDR: Double(high) / Double(n),
                                 clippedBlack: Double(low) / Double(n),
                                 clippedScreen: Double(screen) / Double(n),
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
