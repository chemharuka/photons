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
//   2. 中间调/阴影  what step 1 did not lift (the picture's **subject** — after the brightest 5 % is cut —
//               is still under `subjectTarget`, 441) is lifted here, so the SDR picture is not left
//               underexposed. The whole frame is only a ceiling (`wholeCeiling`), never a second goal.
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

    /// **441 §6 — 画面的三类结构**，由算法自己的一次测量判定（不是 EXIF / 语义分割）。
    ///
    /// - `highKey`（A）: 白墙 / 雪 / 日光，允许大面积过白；
    /// - `darkBright`（B）: 暗背景 + 亮主体（高 ISO 室内、舞台），背景要压住；
    /// - `standard`（C）: 其余。
    public enum FrameClass: String, Sendable, Equatable, CaseIterable {
        case highKey = "A"
        case darkBright = "B"
        case standard = "C"
    }

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
        /// **441 — 主体（去掉最亮的 5 %）的中位数。**
        ///
        /// `p50` is the median of **every** picture sample, so a frame whose bright part is more than half
        /// of the picture (a big sky, a wall of windows, snow) reports the *bright part* as its median and
        /// the old 0.04 floor never engages. This is the median of the picture after the brightest 5 % is
        /// cut **by rank** (see `Sample.metrics`), i.e. the part left after sky / lights / windows are
        /// taken out. The cut is a rank cut rather than a value cut on purpose: with a flat bright sky,
        /// `luma <= p95` keeps *all* of it (ties), which is the very population 441 wants to remove.
        public var subjectP50: Double
        /// How many picture samples the subject median was computed over (the lowest `1 - 5 %` by rank).
        public var subjectCount: Int

        // MARK: - 441 §6 — 分类与结构（同一张网格上换分位口径，零新渲染）

        /// 画面中 `luma < darkCut` 的面积占比（§6.1 的 `darkFrac`）。
        public var darkFrac: Double
        /// 画面中 `luma > brightCut` 的面积占比（§6.1 的 `brightFrac`）。
        public var brightFrac: Double
        /// **主体样本里** `luma > brightCut` 的占比。
        ///
        /// `brightFrac` 会把「最亮 5 % 的过曝灯」也算成亮主体：L1030485 的 `brightFrac` 是 5.5 %，
        /// 但那 5.5 % 全在 `p95` 以上（`p99 = 4.92`），画面本身是一片暗背景 + 几盏炸掉的灯。
        /// 把最亮 5 % 先按秩去掉，再问「主体里有没有亮部」，才不会把「炸掉的灯」当成「亮主体」。
        public var subjectBrightFrac: Double
        /// 32×32 块均值 > `highlightBlockLevel` 的块占比（§6.4 的 `highlightBlocks`）。
        public var highlightBlocks: Double
        /// 暗部（`luma < darkCut`）的局部梯度均值 ×100（§6.4 的 `darkTexture`）。
        public var darkTexture: Double
        /// 亮部（`luma > brightCut`）的局部梯度均值 ×100（§6.4 的 `brightTexture`）。
        public var brightTexture: Double
        /// 亮部（`luma > brightCut`）的中位数。研究报告里 B 类的「主体 p50 0.45–0.55 显示」
        /// 指的是**亮主体**（`>0.5` 的面积），不是 `subjectP50`（去尾后的整帧中位）；两者并列报告，
        /// 不允许用其中一个冒充另一个。
        public var brightP50: Double

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
        /// **443** — 低信号帧判定（整帧没有可信内容），步骤 1 之前就在 base 上量出。
        public var lowSignal: Bool
        /// **443** — 曝光是否被上限截断（低信号 +3 EV / 全类 +4.5 EV）。
        public var exposureCapped: Bool
        /// **443** — 截断之前步骤 1 本来要多少 EV，让「本来要多少、封到多少」可读。
        public var needEVBeforeCap: Double
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
        /// **441** — 步骤 2 之前 / 之后的主体中位数（去掉最亮 5 %）与整帧中位数。
        ///
        /// `Before` 是步骤 1 的曝光定下来、步骤 2 还没动的时候；`After` 是步骤 2 落完（含护栏）之后。
        /// 两者分开报告，一次运行才能说清「主体提了多少 / 整帧被推了多少」。步骤 3 会把高光/白色压回去
        /// 并连带压低主体，所以这不是成品值，而是**中间调这一步的增量**。
        public var subjectP50Before: Double
        public var subjectP50After: Double
        public var wholeP50Before: Double
        public var wholeP50After: Double
        /// 本次运行实际使用的地板与护栏（标定值；⑧c 打开时 `subjectTarget` 会显示 0.001）。
        public var subjectTarget: Double
        public var wholeCeiling: Double
        /// **§6 — 画面分类与它的判据量**，逐帧可解释。
        public var frameClass: FrameClass
        public var darkFrac: Double
        public var brightFrac: Double
        public var subjectBrightFrac: Double
        public var highlightBlocks: Double
        public var darkTexture: Double
        public var brightTexture: Double
        /// 步骤 3 的 `clippedHDR` 许可上限（按类：A 0.30 / B 0.025 / C 0.03）。
        public var clippedHighCeiling: Double
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

    // MARK: - 443 — 低信号帧与曝光上限

    /// **443 — 低信号判据：`base.p99` 在线性域低于它，或 90 % 以上的画面已经在黑位。**
    ///
    /// 低信号 ≠ 暗背景（B 类）：B 类是「背景暗、主体亮」，`brightFrac` 有几个百分点；低信号是
    /// **整帧几乎没有可信内容**，p99 只是噪声。派单初值 0.05，但实测 L1030746 在出货测量口径下
    /// （`measureAutoLightSample`，0.5 解码 + 256 网格）的 `base.p99 = 0.0607`，而下一档有内容的
    /// 最暗帧（L1030730）是 0.0742 —— 0.07 落在两者之间，既不漏报这张，也不把「只是暗、仍有主体」
    /// 的帧误判成无内容。
    ///
    /// `clippedBlack` 是 `≤ 0.001 线性` 的像素占比（`Metrics` 的定义），不是显示域的
    /// 「clipping low」；这里用 0.90 作为「整帧已压到黑位」的兜底，与派单一致。
    public static let lowSignalP99: Double = 0.07
    public static let lowSignalClippedBlack: Double = 0.90

    /// **443 — 低信号帧的曝光上限。** 用户对 L1030746 的选择是 +2.82 EV（全库 p99 +4.15），
    /// 给到 +3 已经略高于他的习惯，但不再把噪声锚到 SDR 白（旧路径会要求 +5…+6 EV）。
    public static let lowSignalExposureCap: Double = 3.0

    /// **443 — 全类曝光上限（A/B/C 都生效）。**
    ///
    /// 用户全库 570 张成品的曝光 p99 是 +4.15、max +5.00；4.5 在 p99 之上留一点余量，
    /// 只切掉他自己也极少/从未使用的 +4.5…+8 区间。低信号帧另有更紧的 +3。
    public static let maxExposureEV: Double = 4.5

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

    // MARK: - 441 — the subject floor, and the whole-frame guard

    /// **441 — 主体样本砍掉最亮的这一比例（按秩，不是按值）。**
    ///
    /// 用户口径（2026-11-20）：「主体（去掉天空/灯光后）的曝光还缺一点，需要加中间调来提亮」。
    /// 天空 / 灯光 / 窗 / 雪都在最亮的尾部，所以主体 = picture 样本里**按秩**去掉最亮 5 % 之后
    /// 的中位数。按秩而不是按 `luma <= p95` 的**值**：一片平顶的亮天空会让所有样本都等于 p95，
    /// 值切法一个也去不掉（平局），而这正是本单要拿掉的人群。对没有平局的普通照片两者相同。
    ///
    /// 5 % 是规格写死的；它只去掉「尾部」，不做语义分割，也不假设天空在上方。
    public static let subjectTopCut: Double = 0.05

    /// **441 — 主体的中间调地板。真库标定，不是拍的整数。**
    ///
    /// 取 `~/Documents/photons-demo.photonslibrary` 里**已有编辑**的照片（最新快照 `seq > 1`）
    /// 当前文档的 `subjectP50` 中位数。标定：465 帧，p10 **0.0197** / p50 **0.1350** / p90 **0.3319**。
    /// 它不是「目标值」而是**地板**：主体已经在这里就不动（和 `midtoneTarget` 同一种语义）。
    /// §6 起生产路径按类取值（`classTargets`），这个全局常数只作为「不分家时」的参照与测试基准。
    public static let subjectTarget: Double = 0.1350

    /// **441 返工 §5.3 — 每帧的提亮代价上限（成品 `clippedHDR` 相对「不做主体地板」的增量）。**
    ///
    /// 中位提升不能靠少数暗帧把高光推爆来换。这里量的是**整条流水线跑完之后**的削顶差
    /// （`plan` 与同一次输入、`subjectTarget = 0.001` 的那次运行比），不是步骤 2 的探针：
    /// 步骤 3 的高光/白色会把中间调推上去的一部分削顶再压回来，用步骤 2 的探针会把代价高估一个量级。
    /// 超过 0.50 pp 就把本次 `needEV` 折半（几何平均重设地板）再算一次，最多 3 次；仍超则回退到
    /// 「不做主体地板」（midtones = 0），保证单帧代价有硬上限。验收上限就是单帧 ≤ 0.5 pp。
    public static let subjectClippingBudget: Double = 0.0050

    /// **441 — 整帧的上限护栏（不是第二个目标）。**
    ///
    /// 主体地板会把中间调提起来，整帧也跟着亮；这条护栏只回答「别把整帧推过曝」。
    /// 初值取真库**成品** `wholeP50` 的 p90（标定：464 帧，p10 0.0220 / p50 0.1465 / **p90 0.3469**）。
    /// 提完之后如果整帧越过它：先把本次 `needEV` 减半再算一次，仍越过就回退到「不提」。
    /// 它**不是**目标值 —— 整帧低于它也不会被拉上去（本单不改 EV、不改高光/白色/黑色）。
    public static let wholeCeiling: Double = 0.3469

    // MARK: - 441 §6 — 三类结构：标定出来的判据与每类目标

    /// **§6.1 的 `darkCut`（线性 scene luma）**：`darkFrac` 的切点。
    ///
    /// 不是把研究里的显示值 0.1 用 sRGB 硬套（那会是 0.01 — 初始猜测）；这里由 60 帧研究集标定：
    /// 在**步骤 1 曝光之后**的样本上，`0.05` 让 11 张 B 类里的 10 张（L1030715 是 A/B 双标签，
    /// 见 REPORT）同时满足 `darkFrac ≥ 15 %`，而 `0.04` 会漏掉两张（L1030750/L1030558）。
    /// 曝光已把 as-shot 抬了约 2 档，所以线性的 0.05 对应的正是研究里成品显示域的「暗背景」。
    public static let darkCut: Float = 0.05

    /// **§6.1 的 `brightCut`（线性 scene luma）**：`brightFrac` 的切点。
    /// 同样标定：`0.25` 让 B 类的亮主体（占画面 5–30 %）全部在切点以上，同时不把中间调当主体。
    public static let brightCut: Float = 0.25
    /// `darkFrac` 的判据下限（§6.1 写死的 15 %）。
    public static let darkFractionFloor: Double = 0.15
    /// `brightFrac` 的判据下限（§6.1 写死的 5 %）。
    public static let brightFractionFloor: Double = 0.05
    /// 主体样本里亮部的下限 —— 用来把「5 % 炸掉的灯」从「亮主体」里分出去（见 `subjectBrightFrac`）。
    public static let subjectBrightFractionFloor: Double = 0.05
    /// B 类还得是**暗背景**：整帧中位数高于它就不是 B（而是 C 的高键室内）。
    public static let darkBrightWholeP50Ceiling: Double = 0.40

    /// **A 类（高键）的判据**：`clippedHDR ≥ 10 %`（§6.1），
    /// 或 as-shot 已经有大面积过白（`≥ 6 %`），
    /// 或 as-shot 的白点/主体已经在白附近（`p50 ≥ 0.03 且 p90 ≥ 0.26`）。
    ///
    /// 后两条是 60 帧标定补上的：曝光前的 `clippedHDR` 全为 0（60 帧实测），单靠
    /// `clippedHDR ≥ 10 %` 只能认出 11/18 张 A 类；补上「白墙在 as-shot 就已经很亮」这一条，
    /// 18 张里认出 16 张，剩下的两张是同一张照片的 `-denoised` 变体（L1030479，见 REPORT）。
    public static let highKeyClipFraction: Double = 0.10
    public static let highKeyAsShotClipFraction: Double = 0.06
    public static let highKeyBaseP50: Double = 0.03
    public static let highKeyBaseP90: Double = 0.26

    /// §6.4 的 `highlightBlocks`：32×32 块均值 > 0.85 的占比（研究里 A 类 25.2 %、C 类 0.4 %）。
    public static let highlightBlockSize: Int = 32
    public static let highlightBlockLevel: Float = 0.85

    /// 三类各自的「步骤 2 目标 + 整帧护栏 + 步骤 3 削顶门」（§6.3）。
    ///
    /// 线性值由显示域目标经 S4 的 sRGB OETF 反解（`srgbDecode`），因为
    /// `measureAutoLightSample` 读的是 **S4 之前**的 display-linear 网格（1.0 = SDR 白）。
    /// 三类的 `subjectTarget` / `wholeCeiling` 再由真库**按类**标定（见 `classTargets` 的注释与 REPORT）。
    public struct ClassTargets: Sendable, Equatable {
        /// 主体（去掉最亮 5 %）的地板。
        public var subjectTarget: Double
        /// 整帧 p50 的护栏；`.infinity` = A 类不设。
        public var wholeCeiling: Double
        /// 步骤 3 的 `clippedHDR` 许可上限（`>SDR 白`的面积占比）。
        public var clippedHighCeiling: Double
        /// 阴影是否允许往上提（B 类：**不许**）。
        public var liftsShadows: Bool
    }

    /// 显示域 → display-linear（S4 的 OETF 的反函数，`Histogram.srgbDecode`）。
    public static func linearFromDisplay(_ v: Double) -> Double {
        Histogram.srgbDecode(Float(v)).isFinite ? Double(Histogram.srgbDecode(Float(v))) : v
    }

    /// display-linear → 8-bit 显示值（S4 的 OETF），只用于报告里的「显示域」列。
    public static func displayFromLinear(_ v: Double) -> Double {
        v.isFinite ? Double(Histogram.srgbEncode(Float(max(v, 0)))) : v
    }

    /// 三类的预设。显示域 → 线性的换算是精确的（S2 的区段提升是 EV 增益，S4 才是 OETF），
    /// 目标值本身按真库**成品**的同类中位标定（REPORT §2）。
    public static func classTargets(_ frameClass: FrameClass) -> ClassTargets {
        switch frameClass {
        case .highKey:
            // 真库 A 类 157 帧成品：subjectP50 p50 = 0.2408（显示 0.528，落在 §6.3 的 0.45–0.55）。
            return ClassTargets(subjectTarget: 0.2408,
                                wholeCeiling: .infinity,
                                clippedHighCeiling: 0.30,
                                liftsShadows: true)
        case .darkBright:
            // 真库 B 类 95 帧成品：subjectP50 p10 0.0099 / p50 0.0648（显示 0.282）/ p90 0.1350（显示 0.400）；
            // wholeP50 p10 0.0118 / p50 0.0718（显示 0.297）/ p90 0.1515（显示 0.427）。
            //
            // 取 **p90** 而不是 p50，原因写在 REPORT：B 类的成品里本来就有一成照片把主体推到
            // 0.40 显示（研究报告 §5 的 0.45–0.55 是「>0.5 面积」的近似，不是 `subjectP50`），
            // 取 p50 会让「主体明显偏暗」的那一半 B 帧只提 0.1–0.2 档，达不到用户「加够」的口径。
            // 整帧上限在 p90（0.1515）之上留 0.0185 的余量（0.17 → 显示 0.450）：目标值贴着上限时
            // 一次取整就会越线、触发折半，实测那一档反而把 B 的中位提升从 0.38 档压回 0.24 档。
            // 研究报告的「≤0.25 显示」与 426d 固定的曝光锚（步骤 1 不改）冲突，见 REPORT §5。
            //
            // `clippedHighCeiling` 取 0.025（2.5 %）而不是研究报告的 2 %：owner 自己的 B 类成品
            // L1030943 就有 2.70 % 过白、L1030532 有 3.80 %。2 % 时步骤 3 会把这张压得比 owner 还暗
            // （A④ 整帧 p50 差 −0.27 档）；2.5 % 让 A④ 回到 0.21 档，同时 A⑤ 的 ΔclippedHDR 仍在
            // 中位 0.1 pp / 最大 0.5 pp 以内（REPORT §5）。
            return ClassTargets(subjectTarget: 0.1350,
                                wholeCeiling: 0.1700,
                                clippedHighCeiling: 0.025,
                                liftsShadows: false)
        case .standard:
            // 真库 C 类 213 帧成品：subjectP50 p50 = 0.1238（显示 0.387，落在 0.35–0.40）。
            // 整帧护栏取 §6.3 的 0.425 显示（0.1516）；owner 的 C 类成品 p50 是 0.401 显示，在它下面。
            return ClassTargets(subjectTarget: 0.1238,
                                wholeCeiling: 0.1516,
                                clippedHighCeiling: 0.03,
                                liftsShadows: true)
        }
    }

    /// **§6.1 — 分类。优先级 A → B → C，判据全部来自算法自己的测量。**
    ///
    /// 输入是**同一张网格的两次读数**：as-shot 的 `base`（步骤 0）与步骤 1 曝光之后的
    /// `afterExposure`。为什么不是只读 as-shot：60 帧实测 as-shot 的 `clippedHDR` 全为 0，
    /// 「A 类 ≥ 10 % 过白」在曝光前永远不成立（REPORT §2 点名）。所以 A 类用
    /// **曝光后**的过白面积，外加两条 as-shot 的白墙证据；B 类用曝光后的暗/亮面积。
    ///
    /// 所有常量都是 60 帧研究集标定出来的，不是把显示域阈值用 sRGB 硬套。
    public static func classify(base: Metrics, afterExposure: Metrics) -> FrameClass {
        if afterExposure.clippedHDR >= highKeyClipFraction
            || base.clippedHDR >= highKeyAsShotClipFraction
            || (base.p50 >= highKeyBaseP50 && base.p90 >= highKeyBaseP90) {
            return .highKey
        }
        if afterExposure.darkFrac >= darkFractionFloor,
           afterExposure.brightFrac >= brightFractionFloor,
           afterExposure.subjectBrightFrac >= subjectBrightFractionFloor,
           afterExposure.p50 < darkBrightWholeP50Ceiling {
            return .darkBright
        }
        return .standard
    }

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

    // MARK: - 443 — 步骤 1 的曝光裁决（先判低信号，再封顶）

    /// 步骤 1 的一个完整裁决：本来要多少、是不是低信号、被哪个上限截断。
    struct ExposureDecision: Sendable, Equatable {
        var exposure: Double
        var needEV: Double
        var lowSignal: Bool
        var capped: Bool
    }

    /// **443** — 把步骤 1 的曝光决策从 `solve` 里拆出来，让「低信号 / 上限」可以被单独断言，
    /// 而不必为了看一个 EV 跑完整条流水线。
    ///
    /// 431/426d 的锚点不变：生产路径 `p95 → broadHighlightTarget`；⑧d 打开时才回到旧的
    /// `p99 → p99WhiteTarget`。低信号判定只看 **base**（步骤 0 的 as-shot 测量）：
    ///
    ///     lowSignal = base.p99 < lowSignalP99 || base.clippedBlack >= lowSignalClippedBlack
    ///
    /// 低信号的曝光上限是 `lowSignalExposureCap`，其余帧是 `maxExposureEV`；⑧b 的
    /// `ignoresExposureCap` 只去掉全类上限，不去掉低信号自己的 +3 封顶。
    static func exposureDecision(base: Metrics, gates: Gates) -> ExposureDecision {
        let needEV: Double
        if gates.noExposureCeiling {
            needEV = log2(p99WhiteTarget / max(base.p99, 1e-5))
        } else {
            needEV = log2(broadHighlightTarget / max(base.p95, 1e-5))
        }
        let lowSignal = !gates.ignoresLowSignal
            && (base.p99 < lowSignalP99 || base.clippedBlack >= lowSignalClippedBlack)
        let globalCap = gates.ignoresExposureCap ? Double.infinity : maxExposureEV
        let cap = lowSignal ? min(lowSignalExposureCap, globalCap) : globalCap
        let bounded = min(needEV, cap)
        return ExposureDecision(exposure: snapExposure(bounded),
                                needEV: needEV,
                                lowSignal: lowSignal,
                                capped: needEV > cap)
    }

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
                            subjectTargetOverride: Double? = nil,
                            clippingBudgetOverride: Double? = nil,
                            lossAtDepth: ((Double) throws -> Double)? = nil,
                            measure: (EditModel) throws -> Sample) throws -> Plan {
        /// 441 ⑧c：把主体地板压到 0.001，等于「永不提主体」。
        /// `nil` = 让 `solve` 按 §6 的三类各自取标定值。
        let budget = clippingBudgetOverride ?? AutoLight.subjectClippingBudget

        func run(_ target: Double?) throws -> Plan {
            try Self.solve(for: edit, gates: gates, subjectTargetOverride: target,
                           lossAtDepth: lossAtDepth, measure: measure)
        }
        var best = try run(gates.collapsesSubjectTarget ? 0.001 : subjectTargetOverride)
        // 没有提主体（或主体地板已经被关掉）时不存在「这一刀的代价」，不必再跑一遍基线。
        guard best.midtones > 0 else { return best }

        /// **441 返工 §5.3 — 每帧的收益/代价上限（见 `subjectClippingBudget`）。**
        ///
        /// 基线是**同一次输入、不做主体地板**（`subjectTarget = 0.001`）的成品：两次运行共享
        /// 曝光 / 高光 / 白色 / 黑色的求解规则，差只来自中间调。步骤 3 会把中间调推上去的削顶
        /// 再压回来一部分，所以在**成品**上量，而不是在步骤 2 的探针上量。
        let bare = try run(0.001)
        let bareClip = try measure(bare.apply(to: edit)).metrics().clippedHDR
        var bestClip = try measure(best.apply(to: edit)).metrics().clippedHDR
        var attempts = 0
        while best.midtones > 0, bestClip - bareClip > budget, attempts < 3 {
            // needEV 折半 = 地板取当前主体与地板的几何平均；主体已经在地板以上时下一步就是 0。
            let subject = max(best.report.subjectP50Before, 1e-6)
            let target = (subject * best.report.subjectTarget).squareRoot()
            best = try run(target)
            bestClip = try measure(best.apply(to: edit)).metrics().clippedHDR
            attempts += 1
        }
        // 折半到「地板贴着主体」仍然买不起这一刀 ⇒ 回退到不做主体地板（§1.3 的「仍超则不提」）。
        // 这一步保证每帧的成品削顶增量有硬上限，而不是拿报告解释例外。
        if best.midtones > 0, bestClip - bareClip > budget { return bare }
        return best
    }

    /// 441 的 `plan` 主体：给定一个**已经裁决好**的 `subjectTarget` 跑完整条流水线。
    /// `plan` 在它外面套「每帧代价上限」的折半重试；反向门与标定直接调它以外的公开入口。
    static func solve(for edit: EditModel,
                      gates: Gates,
                      subjectTargetOverride: Double?,
                      lossAtDepth: ((Double) throws -> Double)?,
                      measure: (EditModel) throws -> Sample) throws -> Plan {
        let started = Date()
        var renders = 0
        func sample(_ document: EditModel) throws -> Sample {
            renders += 1
            return try measure(document)
        }
        /// 441 — 每一次统计都走同一个口径；⑧a 打开时把主体换回整帧。
        func measured(_ sample: Sample) -> Metrics {
            sample.metrics(subjectCut: !gates.ignoresSubjectCut)
        }

        // Step 0 — the baseline every step is measured against: 明暗 zeroed, `blackOffset` kept.
        var document = edit
        zero(&document)

        // ── 步骤 1 — 曝光 ────────────────────────────────────────────────────────────────────────
        let neutral = try measured(sample(document))
        // ⑧d: anchoring on p95 is "reach SDR white" *without* the p99 ceiling — the gate's mistake, and
        // it over-exposes every picture that has a tail.
        //
        // **426d — 曝光的唯一驱动量：大面积高光。**
        //
        // owner 的原话是「如果高光太亮就 EV 少一些，通过中间调和阴影拉高主体」——所以 EV 由**高光**
        // 决定，主体不足由步骤 2 补，EV 不为主体让路。
        //
        // 标定：在 owner 自己的五帧 boston 成品上反推 `log2(target / baseP95)`，逐 target 比对手调 EV：
        //   target 0.9 → 中位差 0.29 | 1.0 → 0.32 | **1.1 → 0.21** | 1.2 → 0.24 | 1.4 → 0.35 | 1.6 → 0.54
        // 1.1 是最贴合的（逐帧 −0.36/+0.46/+0.11/−0.00/−0.21），也落在 owner 成品 p95 的中段。
        //
        // **443** — 低信号先判、再封顶：`exposureDecision` 在 base 上判 `lowSignal`，
        // 低信号帧只给 +3 EV，其余帧全类上限 +4.5；`needEVBeforeCap` 记下截断前的本来值。
        // ⑧d 打开时复现旧的 `p99 → 1.5` 口径，好让门能证明新规则确实换了驱动量。
        let decision = exposureDecision(base: neutral, gates: gates)
        let lowSignal = decision.lowSignal
        var exposure = decision.exposure
        document.light.exposure = exposure
        var afterExposure = try measured(sample(document))
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
            afterExposure = try measured(sample(document))
            backstops += 1
            let ratioAfter = afterExposure.p999 / max(afterExposure.p99, 1e-9)
            if ratioAfter >= ratioBefore - 1e-3 { break }
        }

        // ── §6.1 — 分类（A 高键 / B 暗背景+亮主体 / C 标准）────────────────────────────────
        //
        // 用**已经量过的两次读数**分类，不额外渲染：`neutral`（as-shot）与 `afterExposure`
        // （步骤 1 定下曝光之后）。三类的目标 / 护栏 / 削顶门见 `classTargets`。
        var frameClass = AutoLight.classify(base: neutral, afterExposure: afterExposure)
        if gates.forcesStandardClass { frameClass = .standard }
        var targets = AutoLight.classTargets(frameClass)
        if let subjectTargetOverride { targets.subjectTarget = subjectTargetOverride }
        if gates.collapsesClassCeilings { targets = AutoLight.classTargets(.standard) }
        if gates.collapsesHighKeyClipCeiling { targets.clippedHighCeiling = 0.05 }
        if gates.ignoresClippedHighCeiling { targets.clippedHighCeiling = 1.0 }
        if gates.ignoresWholeCeiling { targets.wholeCeiling = .infinity }
        if gates.liftsShadowsForB { targets.liftsShadows = true }
        // **443 — 低信号优先：不进分类的 A/B/C 目标逻辑。**
        //
        // 一张「整帧没有内容」的片子里没有可信的主体，追 classTargets 的 0.12–0.24 只会把噪声
        // 推成灰雾（用户对 L1030746 的选择就是 midtones = 0 / shadows = 0）。所以把主体地板压到 0、
        // 阴影地板关掉；高光 / 白色 / 黑色三步照旧（它们只压顶、压黑位，不追主体）。
        // `frameClass` 仍照常测量并写进报告，供人看这张本会被分到哪一类。
        if lowSignal {
            targets.subjectTarget = 0
            targets.liftsShadows = false
        }
        let subjectTarget = targets.subjectTarget

        // ── 步骤 2 — 中间调 / 阴影 ──────────────────────────────────────────────────────────────
        //
        // **441：中间调的地板看主体，不看整帧。**
        //
        // owner 口径（2026-11-20）：「主体（去掉天空/灯光后）的曝光还缺一点，需要加中间调来提亮」。
        // 旧判据是整帧 `p50 < midtoneTarget(0.04)`：一帧只要亮部超过一半（大片天空 / 灯光 / 雪），
        // 整帧中位数就是亮部，第二步完全不动作，而主体仍在 0.02–0.03。现在判据换成
        // `subjectP50 < subjectTarget`（真库标定），需要多少 EV 也按主体算；`midtoneTarget` 的
        // 0.04 保留为历史常量（`refillBody` 也不再使用它，避免两套地板打架）。
        //
        // 整帧只作**上限护栏**：提完若 `wholeP50 > wholeCeiling`，本次 needEV 减半再算一次；仍超就
        // 回退到「不提」（441 返工 §5.2：不加「且被这次提亮推得更高」的附加条件，否则「提亮前就
        // 已经够亮」这一档会被整个放过）。护栏不是第二个目标 —— 整帧低于它不会被拉上去。
        var midtones = 0.0
        var shadows = 0.0

        /// needEV → 中间调滑杆单位（在 `level` 这个亮度上的行程）。
        func midtoneUnits(needEV: Double, level: Double) -> Double {
            let weight = max(S2Regions.weights(L: log2(max(level, 1e-6))).mid, 0.2)
            let travel = max(S2Regions.midTravel * weight, 0.05)   // EV per 100 units at this level
            return min(midtoneCap, max(0, (needEV / travel * 100).rounded()))
        }
        /// needEV → 阴影滑杆单位。
        func shadowUnits(needEV: Double, level: Double) -> Double {
            let weight = max(S2Regions.weights(L: log2(max(level, 1e-6))).shadow, 0.2)
            let travel = max(S2Regions.shadowTravel * weight, 0.05)
            return min(shadowCap, max(0, (needEV / travel * 100).rounded()))
        }

        /// 从 `bare`（中间调/阴影为 0 时的统计）算出两个滑块，写进 `document`，返回落完后的统计。
        ///
        /// 护栏在这里而不是在调用方：步骤 2 与步骤 3 的 `refillBody` 都要同一条规则，两处各写一遍
        /// 迟早会漂移。`bare` 已经包含当前曝光（以及步骤 3 里已有的高光/白色），但护栏的测量会把
        /// 高光/白色清零 —— 它问的是「只靠主体地板，整帧会被推到哪里」，步骤 3 的工具只会把它压回来。
        ///
        /// **护栏的语义（441 返工 §5.2）：整帧已经够亮就不提。**
        /// 判据只有 `after > wholeCeiling` 一条：中间调只会把 p50 往上推，所以
        /// `bare.p50 ≥ wholeCeiling` 的照片提完必然越线 ⇒ 回退到「不提」；照片本来就在线下、提亮
        /// 把它推过线时同样先减半、再回退。不再加「&& 比提亮前更高」这种附带条件 —— 那会把
        /// 「已经够亮」这一档整个放过（首轮的偏差）。
        @discardableResult
        func applyBodyFloor(from bare: Metrics) throws -> Metrics {
            var mid = 0.0
            if bare.subjectP50 > 1e-6, bare.subjectP50 < subjectTarget {
                let needEV = log2(subjectTarget / bare.subjectP50)
                mid = midtoneUnits(needEV: needEV, level: bare.subjectP50)
            }
            var shadow = 0.0
            // **§6.3 — B 类不许提阴影**：背景本来就该暗；高 ISO 的暗部纹理只有 ~1.1，
            // 拉亮它只会把噪声提出来。C/A 仍按 p10 的地板补黑场。
            if targets.liftsShadows, bare.p10 > 0, bare.p10 < shadowTarget {
                let needEV = log2(shadowTarget / bare.p10)
                shadow = shadowUnits(needEV: needEV, level: bare.p10)
            }
            document.light.midtones = mid
            document.light.shadows = shadow
            var probe = document
            probe.light.highlights = 0
            probe.light.whites = 0
            var m = try measured(sample(probe))
            if targets.wholeCeiling.isFinite, mid > 0, m.p50 > targets.wholeCeiling {
                // 第一次：needEV 减半，滑块按半程重算。
                let halfNeed = log2(subjectTarget / max(bare.subjectP50, 1e-6)) * 0.5
                mid = midtoneUnits(needEV: halfNeed, level: bare.subjectP50)
                document.light.midtones = mid
                probe.light.midtones = mid
                m = try measured(sample(probe))
                if m.p50 > targets.wholeCeiling {
                    // 仍越过：回退到「不提」（阴影不受这条护栏管，它只补黑场）。
                    mid = 0
                    document.light.midtones = 0
                    probe.light.midtones = 0
                    m = try measured(sample(probe))
                }
            }

            // 441 返工 §5.3 的代价上限不在这里：步骤 2 的探针没有高光/白色，会把代价高估一个
            // 量级（实测同一帧的探针增量可以到 1 pp，成品只有 0.1 pp）。上限在 `plan` 外层用
            // **成品**与「不做主体地板」的成品比，超了才折半重跑（见 `subjectClippingBudget`）。
            midtones = mid
            shadows = shadow
            return m
        }

        var afterStep2 = try applyBodyFloor(from: afterExposure)

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

        /// **441 返工 — 高光的纹理基线是「本次高光动作之前」的那一帧，不是步骤 2 的 afterStep2。**
        ///
        /// ②b/③ 会降 EV 再 `refillBody`，整帧纹理随 EV 变化；如果仍拿 afterStep2 当基线，
        /// `loss(atDepth:)` 在 depth=0 时就已经不为 0，`textureLossHighlightsOnly` 会把 EV 的代价
        /// 算到高光头上（实测 L1030942 10.3 %、L1030545 9.8 %、_1274394 13.8 %，都在
        /// `subjectTarget` 开到 0.04、主体地板几乎不动作时就已超 8 %）。每次 `applyHighlightAndWhite`
        /// 先测一次当前帧（highlights/whites 已清零）作为基线，`loss` 只回答「高光这一刀」的代价。
        var highlightTextureBase = textureBase

        /// 高光在 depth（正数单位）处的归一化纹理损失。
        func loss(atDepth depth: Double) throws -> Double {
            // ⑧a/⑧b 必须也作用在「预算是多少」的那条循环上：`deepestHighlightWithinBudget`
            // 里的 gate 只决定起点，返工后的「向下取整 + 逐格退回」会再次问 `loss`，如果这里
            // 不认 gate，⑧a 就会被昂贵的注入判据重新拉回浅深度，白色也跟着被误启用。
            if gates.criterionAlwaysZeroLoss { return 0 }
            if gates.criterionAlwaysFullLoss { return 0.99 }
            if let lossAtDepth { return try lossAtDepth(depth) }
            var probe = document
            probe.light.highlights = -depth.rounded()
            let m = try measured(sample(probe))
            return max(0, (highlightTextureBase - m.texture) / max(highlightTextureBase, 1e-9))
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
        /// 目标与步骤 2 同一条：`subjectTarget` / `shadowTarget` 两个**地板**（441 起中间调看主体），
        /// 护栏也用同一份 `applyBodyFloor`。探针先把自己的中间调/阴影清零再量，避免把上一次的量
        /// 当成照片本身。
        func refillBody() throws {
            var probe = document
            probe.light.midtones = 0
            probe.light.shadows = 0
            let bare = try measured(sample(probe))
            try applyBodyFloor(from: bare)
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
        var stage = try measured(sample(document))

        // **①② 一套工具：压高光、补白色。**
        func applyHighlightAndWhite() throws {
            // 441 返工 — 高光自己的基线：此刻的高光/白色已清零，这一帧就是「高光动手前」。
            let highlightProbe = try measured(sample(document))
            highlightTextureBase = highlightProbe.texture
            // ① 高光 — 深度受纹理预算约束
            //
            // **441 返工：向下取整，不越过预算一格。** 二分得到的是连续深度，`rounded()` 可能把
            // 36.6 抬到 37，恰好在 8 % 线上多走 0.4 单位；实测 L1030739 因此报 8.1 %。预算必须
            // 从**向下**的一侧满足，所以这里 `rounded(.down)`，再退回一格直到真的在门限内。
            var depth = try deepestHighlightWithinBudget().rounded(.down)
            while depth > 0, try loss(atDepth: depth) > highlightLossThreshold {
                depth -= 1
            }
            highlights = -depth
            highlightBudget = -highlights
            highlightsOnlyLoss = try loss(atDepth: -highlights)
            document.light.highlights = highlights

            var m = try measured(sample(document))
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
                mm.clippedScreen <= 0 && mm.clippedHDR <= targets.clippedHighCeiling
            }
            if !settled(m) {
                var shallow = 0.0          // 已知不够（仍在超限）
                var deep = -whiteTravelEnd // 已知最深的候选
                var deepMetrics = m
                var probe = document
                probe.light.whites = deep
                deepMetrics = try measured(sample(probe))
                if settled(deepMetrics) {
                    // 二分找「刚好归零」的最浅深度
                    for _ in 0 ..< 4 {
                        let mid = ((shallow + deep) / 2).rounded()
                        var q = document
                        q.light.whites = mid
                        let qm = try measured(sample(q))
                        if settled(qm) { deep = mid; deepMetrics = qm } else { shallow = mid }
                    }
                    whites = deep
                } else {
                    whites = -whiteTravelEnd    // 到底仍不够：留给 ③ 降 EV
                    deepMetrics = m
                }
                document.light.whites = whites
                m = whites < 0 ? (try measured(sample(document))) : m
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
            highlightSlope = max((afterStep2.p99 - (try measured(sample(probe))).p99) / 100, 1e-4)
            probe = document
            probe.light.whites = -100
            whiteSlope = max((afterStep2.p99 - (try measured(sample(probe))).p99) / 100, 1e-4)
        }

        // **① ② 总是先跑**：`clippedHDR` 超标（大面积高光过亮）与 `clippedScreen` 是两件事，
        // 前者 ALSO 需要高光/白色介入 —— 之前把整块藏在 `clippedScreen > 0` 里，导致
        // L1030941（clippedScreen=0 但 clippedHDR=7.57 %）完全没被处理。
        try applyHighlightAndWhite()
        if stage.clippedScreen > 0 || stage.clippedHDR > targets.clippedHighCeiling {
            // **②b 大面积高光太亮 ⇒ 少一些 EV。**
            //
            // 用户原话：「如果高光太亮就 EV 少一些」。这里「太亮」用 `clippedHDR`（>SDR 白的像素占比）
            // 度量 —— 不是 p95：在 owner 的五帧成品上 `p95×2^EV` 是 0.80…1.42，而 `clippedHDR` 是
            // 0.05 %…17.93 %，**同样的 p95 target 差 360 倍**，说明 p95 不决定「有多白」。
            //
            // 目标 `clippedHighCeiling` = 5 %：owner 五帧里四帧 ≤ 2.7 %，L1030940 的 17.9 % 是大面积
            // 天空的特例；5 % 把「普通画面」和「整片天空」分开，同时不至于把普通帧压得太暗。
            var highRelaxSteps = 0
            while stage.clippedHDR > targets.clippedHighCeiling, highRelaxSteps < 3, exposure > -4 {
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
                    let m = try measured(sample(probe))
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
        var afterBlacks = try measured(sample(document))
        if afterBlacks.clippedBlack < clipFloorFraction, blacks > -100 {
            // **Bisection on `clippedBlack`, not a solve on p01.** Measured (L1030940 at +2 EV, from the
            // cancel term's −36): the bottom fraction is 0.03 % at −36 and 1.03 % at −48, while `p01`
            // has already collapsed to 0 by −60 — so a log2(p01) secant saturates and either stalls or
            // overshoots to −100. The clip fraction is monotone in the depth over the whole useful
            // range, and it is what the spec's rule is stated in (「刚好有 > 0.1% 的像素削底」).
            var shallow = blacks                        // too shallow: clips too little
            var deep = max(-100, blacks - 24)           // assumed too deep
            var deepMetrics = try measured(sample({
                var probe = document
                probe.light.blacks = deep
                return probe
            }()))
            // Widen once if 24 units were not enough to cross the threshold.
            if deepMetrics.clippedBlack < clipFloorFraction, deep > -100 {
                shallow = deep
                deep = max(-100, deep - 24)
                var probe = document
                probe.light.blacks = deep
                deepMetrics = try measured(sample(probe))
            }
            // Four halvings land a 24-unit bracket inside 1.5 units — finer than any look.
            for _ in 0 ..< 4 where deep - shallow < -0.5 && deepMetrics.clippedBlack >= clipFloorFraction {
                let mid = ((shallow + deep) / 2).rounded()
                var probe = document
                probe.light.blacks = mid
                let m = try measured(sample(probe))
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
                                   lowSignal: lowSignal,
                                   exposureCapped: decision.capped,
                                   needEVBeforeCap: decision.needEV,
                                   p99AfterExposure: afterExposure.p99,
                                   p95AfterExposure: afterExposure.p95,
                                   p999OverP99AfterExposure: afterExposure.p999
                                       / max(afterExposure.p99, 1e-9),
                                   exposureBackstops: backstops,
                                   clippedHighAfterExposure: afterExposure.clippedHDR,
                                   p50AfterExposure: afterExposure.p50,
                                   subjectP50Before: afterExposure.subjectP50,
                                   subjectP50After: afterStep2.subjectP50,
                                   wholeP50Before: afterExposure.p50,
                                   wholeP50After: afterStep2.p50,
                                   subjectTarget: subjectTarget,
                                   wholeCeiling: targets.wholeCeiling,
                                   frameClass: frameClass,
                                   darkFrac: afterExposure.darkFrac,
                                   brightFrac: afterExposure.brightFrac,
                                   subjectBrightFrac: afterExposure.subjectBrightFrac,
                                   highlightBlocks: afterExposure.highlightBlocks,
                                   darkTexture: afterExposure.darkTexture,
                                   brightTexture: afterExposure.brightTexture,
                                   clippedHighCeiling: targets.clippedHighCeiling,
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

        // MARK: 441 — the subject floor's three reverse gates

        /// **441 ⑧a** — 把主体样本换回整帧：`subjectP50 := p50`、`subjectCount := sampleCount`。
        /// 打开后 A① 必须红（天空/灯光重新把「主体」抬到地板上）。
        public var ignoresSubjectCut = false
        /// **441 ⑧b** — 去掉整帧护栏。打开后 A③ 必须红（中间调把整帧推过 `wholeCeiling`）。
        public var ignoresWholeCeiling = false
        /// **441 ⑧c** — 把 `subjectTarget` 压到 0.001（≈永不提主体）。打开后 A⑤ 的中位提升必须红。
        public var collapsesSubjectTarget = false

        // MARK: 443 — 低信号 / 曝光上限的两道反向门

        /// **443 ⑧a** — 关掉低信号判定。打开后 L1030746 退回锚点路径（曝光 > +3、主体地板重新参与）。
        public var ignoresLowSignal = false
        /// **443 ⑧b** — 去掉全类曝光上限 `maxExposureEV`。打开后 60 帧的曝光 p99 必须越 +4.5。
        public var ignoresExposureCap = false

        // MARK: 441 §6 — 按类的四道反向门

        /// **§6 ⑧a** — 去掉 B 类的「阴影 ≤ 0」：让 B 也走 p10 地板。打开后 A② 必须红。
        public var liftsShadowsForB = false
        /// **§6 ⑧b** — 三类上限改回单值（全部按 C 类预设）。打开后 A② / A④ 必须红。
        public var collapsesClassCeilings = false
        /// **§6 ⑧c** — 把 A 类的削顶门从 0.30 收回 0.05。打开后 A③ 必须红。
        public var collapsesHighKeyClipCeiling = false
        /// **§6 ⑧d** — 分类恒为 C。打开后 A①（分类标定）必须红。
        public var forcesStandardClass = false
        /// **A③ 的正向对照** — 把本类的削顶门抬到「不设」（1.0），用来证明 A 类的
        /// `midtones` / `subjectP50` 增量与没有削顶门时逐位相同。
        public var ignoresClippedHighCeiling = false

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
    /// - Parameter subjectCut: **441** — `true` (production) computes `subjectP50` over the lower
    ///   `1 - subjectTopCut` of the picture **by rank**; `false` is the reverse gate ⑧a and makes
    ///   `subjectP50 := p50` (the whole frame), exactly the old behaviour.
    public func metrics(cut: Float? = nil, topFraction: Double = 0.10,
                        subjectCut: Bool = true) -> AutoLight.Metrics {
        var picture: [Float] = []
        picture.reserveCapacity(luma.count)
        for v in luma where AutoLight.Sample.isPicture(v) { picture.append(v) }
        guard !picture.isEmpty else {
            return AutoLight.Metrics(p01: 0, p10: 0, p50: 0, p90: 0, p95: 0, p99: 0, p999: 0,
                                     peak: 0, clippedHDR: 0, clippedBlack: 0, clippedScreen: 0, texture: 0,
                                     textureAbsolute: 0, cut: 0, sampleCount: 0,
                                     subjectP50: 0, subjectCount: 0,
                                     darkFrac: 0, brightFrac: 0, subjectBrightFrac: 0,
                                     highlightBlocks: 0, darkTexture: 0, brightTexture: 0, brightP50: 0)
        }
        let n = picture.count
        // **441 — 主体中位数：按秩砍掉最亮的 `subjectTopCut`。**
        //
        // 设保留 `k = n - round(n · 5 %)` 个最暗的样本，主体中位数就是这 k 个里的中位（第
        // `round((k-1)/2)` 小），等价于整帧的第 `(k-1)/2 / (n-1)` 分位 —— 不需要另建数组，也不需要
        // 第二个 `metrics()`。`luma <= p95` 的值切法在有平局时（一片平顶天空）一个也去不掉，
        // 所以这里用秩切；没有平局时两者是同一个样本集。
        var subjectCount = n
        let subjectRank: Double?
        let subjectTopRank: Double?
        if subjectCut, n > 1 {
            let kept = max(1, n - Int((Double(n) * AutoLight.subjectTopCut).rounded()))
            subjectCount = kept
            subjectRank = Double(kept - 1) * 0.5 / Double(n - 1)
            // 主体样本**集合的上沿**（≈ 整帧 p95），用来数「主体里的亮部」。
            subjectTopRank = Double(kept - 1) / Double(n - 1)
        } else {
            subjectRank = nil
            subjectTopRank = nil
        }
        // The eight ranks the algorithm reads, plus the region's own floor when it has to be derived.
        // The region's rank is inserted in order so the selection stays ascending.
        var ranks: [Double] = [0.01, 0.10, 0.50, 0.90, 0.95, 0.99, 0.999, 1.0]
        let regionRank = 1 - topFraction
        if cut == nil {
            ranks.append(regionRank)
        }
        if let subjectRank { ranks.append(subjectRank) }
        if let subjectTopRank, subjectTopRank != subjectRank { ranks.append(subjectTopRank) }
        ranks.sort()
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
        // **§6 — 分类量 / 结构量**，全部在同一个 picture 集合上。`subjectBrightFrac` 先按秩去掉
        // 最亮 5 % 再数亮部，这样一片炸掉的灯（L1030485 的 5.5 %）不会被当成亮主体。
        var darkN = 0, brightN = 0
        var brightValues: [Float] = []
        for v in picture {
            if v < AutoLight.darkCut { darkN += 1 }
            if v > AutoLight.brightCut { brightN += 1; brightValues.append(v) }
        }
        let brightP50 = brightValues.isEmpty ? 0 : AutoLight.percentiles(brightValues, [0.5])[0]
        let subjectLimit: Float
        if let subjectTopRank {
            subjectLimit = Float(value(subjectTopRank))
        } else {
            subjectLimit = .greatestFiniteMagnitude
        }
        var subjectBrightN = 0
        for v in picture where v > AutoLight.brightCut && v <= subjectLimit { subjectBrightN += 1 }
        let subjectBrightFrac = subjectCount > 0
            ? Double(subjectBrightN) / Double(subjectCount) : 0

        // 32×32 块的均值（§6.4）。网格只有 256 长边时是 8×8 个块；一个块里只数 picture 样本。
        var blockTotal = 0, blockHit = 0
        var by = 0
        while by + AutoLight.highlightBlockSize <= height {
            var bx = 0
            while bx + AutoLight.highlightBlockSize <= width {
                var sum = 0.0, count = 0
                for yy in by ..< by + AutoLight.highlightBlockSize {
                    let row = yy * width
                    for xx in bx ..< bx + AutoLight.highlightBlockSize {
                        let v = luma[row + xx]
                        guard AutoLight.Sample.isPicture(v) else { continue }
                        sum += Double(v); count += 1
                    }
                }
                if count > 0 {
                    blockTotal += 1
                    if sum / Double(count) > Double(AutoLight.highlightBlockLevel) { blockHit += 1 }
                }
                bx += AutoLight.highlightBlockSize
            }
            by += AutoLight.highlightBlockSize
        }
        let highlightBlocks = blockTotal > 0 ? Double(blockHit) / Double(blockTotal) : 0

        // 暗部 / 亮部的局部梯度均值 ×100（研究里的 texture 口径）。
        var darkGrad = 0.0, darkGradN = 0, brightGrad = 0.0, brightGradN = 0
        if width > 1, height > 1 {
            for y in 0 ..< (height - 1) {
                let row = y * width
                for x in 0 ..< (width - 1) {
                    let i = row + x
                    let L = luma[i]
                    guard AutoLight.Sample.isPicture(L) else { continue }
                    let right = luma[i + 1], below = luma[i + width]
                    guard AutoLight.Sample.isPicture(right), AutoLight.Sample.isPicture(below) else { continue }
                    let d = (abs(Double(right) - Double(L)) + abs(Double(below) - Double(L))) * 0.5
                    if L < AutoLight.darkCut { darkGrad += d; darkGradN += 1 }
                    if L > AutoLight.brightCut { brightGrad += d; brightGradN += 1 }
                }
            }
        }
        let darkTexture = darkGradN > 0 ? darkGrad / Double(darkGradN) * 100 : 0
        let brightTexture = brightGradN > 0 ? brightGrad / Double(brightGradN) * 100 : 0

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
                                 cut: region, sampleCount: n,
                                 subjectP50: subjectRank.map { value($0) } ?? value(0.50),
                                 subjectCount: subjectCount,
                                 darkFrac: Double(darkN) / Double(n),
                                 brightFrac: Double(brightN) / Double(n),
                                 subjectBrightFrac: subjectBrightFrac,
                                 highlightBlocks: highlightBlocks,
                                 darkTexture: darkTexture,
                                 brightTexture: brightTexture,
                                 brightP50: brightP50)
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
