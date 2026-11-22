import Foundation

// MARK: - 452/498 — 自动颜色（自动饱和度）的纯函数
//
// The owner's ask (2026-11-20): add 自动颜色 beside 自动黑电平 / 自动明暗. 498 (2026-11-22) makes it
// **two degrees of freedom**: the picture's chroma p50 drives `color.vibrance`, its chroma p95 drives
// `color.saturation`, and the saturation solve has a hard clipping guard.
//
// **Why OKLab chroma and not HSL saturation.** HSL's `s` is a per-pixel statement about the largest
// channel, and it saturates at 1 on white; OKLab's `C = √(a² + b²)` is perceptual and survives the
// scene-linear → display-referred trip, which is also the space S3.6's bands use. `HSLBands.chromaGate`
// (0.02) is therefore the right "is this pixel coloured at all" line here too.
//
// **Only raise.** An automatic colour tool that desaturates a picture the owner deliberately
// saturated is a surprise, so neither parameter ever returns a negative lift and both have a ceiling.
// A frame with almost no coloured samples (a grey wall, a night sky, a black frame) gets **0 + 0**:
// auto colour has nothing to act on, and pushing chroma there would invent tint.
//
// The two targets are **calibrated**, not guessed round numbers: see `targetChromaP50` /
// `targetChromaP95` and `AutoColor498Tests.testCalibrationDistribution498` (the 441/452 pattern).

public enum AutoColor {

    // MARK: - the measurement

    /// One picture's chroma distribution, at the scale `RenderGraph.measureLinearSample` measures on.
    public struct Metrics: Sendable, Equatable {
        /// Median OKLab chroma of the picture samples (letterbox excluded).
        public var chromaP50: Double
        /// 95th-percentile OKLab chroma of the picture samples (letterbox excluded). 498: the
        /// saturation degree of freedom is solved from this, not from the median.
        public var chromaP95: Double
        /// Fraction of picture samples whose chroma is above `HSLBands.chromaGate` (0.02).
        public var coloredFraction: Double
        /// Picture samples the two numbers were computed over (letterbox sentinels excluded).
        public var sampleCount: Int

        /// The per-pixel inputs the saturation guard needs. Deliberately **internal**: the caller
        /// sees the distribution, and only `plan2D` needs the pixels to price its own clipping.
        var pixels: [Pixel]

        struct Pixel: Sendable, Equatable {
            /// OKLab chroma of this sample (scene-linear, pre-S4).
            var chroma: Float
            /// S3's own HSL saturation for this sample, after the kernel's headroom normalisation.
            var hslSaturation: Float
            /// OKLab hue in degrees, 0…360. Used only by the skin-band guard.
            var hueDegrees: Float
            /// The HSL hue (fraction of a turn), lightness and headroom scale S3 used, so the solver
            /// can replay the kernel exactly instead of approximating chroma as linear in saturation.
            /// `hueDegrees` is OKLab's hue and is only for the skin band; HSL has its own hue.
            var hslHue: Float
            var hslLightness: Float
            var headroomScale: Float
        }

        public init(chromaP50: Double, chromaP95: Double = 0,
                    coloredFraction: Double, sampleCount: Int) {
            self.chromaP50 = chromaP50
            self.chromaP95 = chromaP95
            self.coloredFraction = coloredFraction
            self.sampleCount = sampleCount
            self.pixels = []
        }

        init(chromaP50: Double, chromaP95: Double, coloredFraction: Double,
             sampleCount: Int, pixels: [Pixel]) {
            self.chromaP50 = chromaP50
            self.chromaP95 = chromaP95
            self.coloredFraction = coloredFraction
            self.sampleCount = sampleCount
            self.pixels = pixels
        }
    }

    // MARK: - the calibration

    /// **The vibrance gain, and it must equal `kVibranceGain` in `s3_color.metal`.**
    ///
    /// Auto colour inverts S3's own curve — `s' = s + v/100 · k · (1 − s)` — so the auto plan and a
    /// hand move of the slider land on the same picture. 452 lowered the kernel literal to **0.28**
    /// (the old 0.5 read as too strong); this constant is the Swift copy the inverse solve needs and
    /// `AutoColor452Tests` parses the kernel text to keep it honest. **Changing this alone is a bug.**
    public static let vibranceGain: Double = 0.28

    /// **498 — 自动颜色 vibrance 的目标彩度。真库标定，不是拍的整数。**
    ///
    /// 与 441/452 同一个口径：取 `~/Documents/photons-demo.photonslibrary` 里**已有编辑**的照片
    /// （最新快照 `seq > 1`，按各自当前文档渲染），逐个算 `Metrics.chromaP50`，取该分布的 **p70**。
    /// 标定（2026-11-22，**477 帧**，0 跳过，规则与 452 一致）：
    ///
    ///     chromaP50   p10 0.0104 · p50 0.0219 · p70 0.0306 · p85 0.0430 · p90 0.0520 · p95 0.0745
    ///     chromaP95   p10 0.0376 · p50 0.0724 · p70 0.0948 · p85 0.1300 · p90 0.1412 · p95 0.1643
    ///
    /// 452 的 `defaultTarget` 取的是 p50（0.0219），结果一半以上的照片解出 v ≤ 0，用户看到的就是
    /// 「点了没反应」。取 p70（0.0306）意味着约 70% 的照片（p50 落在库 p70 以下）都有正向 lift，
    /// 而最高的一小撮仍然不动。标定命令见
    /// `AutoColor498Tests.testCalibrationDistribution498`。
    public static let targetChromaP50: Double = 0.0306

    /// **498 — 自动颜色 saturation 的目标彩度。真库标定。**
    ///
    /// 同一个已编辑库（477 帧），逐个算 `Metrics.chromaP95`，取该分布的 **p85**：
    ///
    ///     chromaP95   p10 0.0376 · p50 0.0724 · p70 0.0948 · p85 0.1300 · p90 0.1412 · p95 0.1643
    ///
    /// p95 描述「这张图里已经最艳的那一小撮」；把它映射到库的 p85（0.1300），意味着约 85% 的照片
    /// 还有一点点饱和度空间，而本来就比库更艳的 15% 得到 `s = 0`（只升不降）。
    public static let targetChromaP95: Double = 0.1300

    /// 452's old name; kept so older call sites keep compiling. 498 moved the target from the
    /// library median to the 70th percentile — seeing 0.0219 here again is the "0+0" regression.
    public static let defaultTarget: Double = targetChromaP50

    /// Below this coloured fraction the frame is (almost) grey and auto colour returns 0 + 0.
    /// Same line as `HSLBands.chromaGate`, so "coloured" means the same thing in both places.
    public static let minimumColoredFraction: Double = 0.02

    /// Auto colour only raises. These are the **total** slider values (`color.vibrance` /
    /// `color.saturation`), not the lift, so a second press on a settled picture cannot creep up.
    public static let maxVibrance: Double = 60
    public static let maxSaturation: Double = 25

    /// **The saturation clipping budget the ticket allows**: 0.1 % of the frame. This is the hard
    /// ceiling the final check enforces and the acceptance table measures against.
    public static let maxNewClippedFraction: Double = 0.001

    /// The guard's own, stricter target: a quarter of the ticket budget (0.025 %, ≈ 10 samples on
    /// the 256-grid). It leaves room for the measure→plan→re-measure loop and for vibrance pushing a
    /// near-ceiling pixel across 0.99, so the cumulative count still lands under 0.1 %. Picking the
    /// rank instead of the single highest saturation is what stops one specular pixel from zeroing
    /// the global term — the first cut's failure mode.
    static let clippingGuardFraction: Double = 0.00025

    /// The HSL saturation at which a pixel counts as sitting on the clamp.
    ///
    /// The measurement grid is **Float16**, and S3's own saturation slider clamps at 1. 1 % of the
    /// 0–1 range is 2.55 display codes at 8 bit — below any visible difference — so a pixel at 0.99
    /// is already "at the ceiling" in both the before and after pictures. Without this margin a
    /// single specular pixel at 0.999 would force the global saturation term to 0 on an otherwise
    /// ordinary photograph. New clipping is only counted below 0.99 → ≥0.99.
    static let saturationCeilingEpsilon: Double = 0.01

    /// A picture within this relative distance of a target is treated as **settled**. Acceptance wants
    /// p50 within ±5 % of target, and the owner wants a second press to be a no-op; 4 % sits inside
    /// the acceptance band and absorbs the Float16/render difference between the exact replay and
    /// the GPU frame, which is ~2–3 % on the real library.
    public static let settledTolerance: Double = 0.04

    /// Slider differences below this are Float16/measurement noise, not a reason for a second write.
    /// 0.05 is one twentieth of a slider unit — invisible on the panel, but enough to make 连点两次
    /// a true no-op.
    public static let settledSliderEpsilon: Double = 0.05

    /// **The skin-band guard.** Mean OKLab chroma in the skin hue band (50°–70°) may not rise by more
    /// than 10 %; global saturation is multiplicative and the most dangerous place to overdo it is a
    /// face. When it would, `s` is reduced (never `v`: the owner asked for the mild vibrance lift).
    public static let maxSkinChromaChange: Double = 0.10

    /// The guard aims 5 % inside the published cap, so the **rendered** picture (whose HSL→RGB→OKLab
    /// trip is not exactly the chroma-ratio approximation the solver uses) still clears 10 %.
    static let skinGuardLimit: Double = maxSkinChromaChange * 0.95

    // MARK: - measurement

    /// One pass over the sample grid: the chroma percentiles, the coloured fraction, and the
    /// per-pixel HSL saturation the clipping guard prices.
    ///
    /// Letterbox / matte is excluded with the **same** rule `AutoLight.Sample.isPicture` uses — a
    /// sentinel texel has negative luma, and S2 clamps every real picture sample to `≥ 0`. The grid
    /// is the pipeline's 256-long-edge scene-linear sample, so this is the picture and not the canvas.
    public static func metrics(from sample: LinearSample) -> Metrics {
        let weights = ColorPrimaries.working.luminanceWeights
        let count = sample.width * sample.height
        var chroma: [Float] = []
        chroma.reserveCapacity(count)
        var pixels: [Metrics.Pixel] = []
        pixels.reserveCapacity(count)
        var colored = 0
        for p in 0 ..< count {
            let o = p * 4
            guard o + 2 < sample.rgba.count else { break }
            let r = Double(sample.rgba[o])
            let g = Double(sample.rgba[o + 1])
            let b = Double(sample.rgba[o + 2])
            let luma = weights.x * r + weights.y * g + weights.z * b
            guard AutoLight.Sample.isPicture(Float(luma)) else { continue }
            let lab = CalibrationGroup.oklab(fromRec2020: SIMD3(r, g, b))
            let c = (lab.y * lab.y + lab.z * lab.z).squareRoot()
            chroma.append(Float(c))
            if c > HSLBands.chromaGate { colored += 1 }
            var hue = atan2(lab.z, lab.y) * 180 / .pi
            if hue < 0 { hue += 360 }
            let hsl = hslSaturationAndLightness(r: r, g: g, b: b)
            pixels.append(Metrics.Pixel(chroma: Float(c),
                                       hslSaturation: Float(hsl.s),
                                       hueDegrees: Float(hue),
                                       hslHue: Float(hsl.h),
                                       hslLightness: Float(hsl.l),
                                       headroomScale: Float(hsl.scale)))
        }
        guard !chroma.isEmpty else {
            return Metrics(chromaP50: 0, chromaP95: 0, coloredFraction: 0, sampleCount: 0)
        }
        let q = AutoLight.percentiles(chroma, [0.5, 0.95])
        return Metrics(chromaP50: q[0], chromaP95: q[1],
                       coloredFraction: Double(colored) / Double(chroma.count),
                       sampleCount: chroma.count, pixels: pixels)
    }

    /// S3's HSL saturation/lightness, including the kernel's headroom normalisation
    /// (`peak > 1 → / (peak/0.9)`). Saturation is the quantity the saturation formula clamps, so the
    /// clipping guard must price this one and not an OKLab proxy.
    static func hslSaturationAndLightness(r: Double, g: Double, b: Double)
        -> (s: Double, l: Double, scale: Double, h: Double) {
        let peak = max(r, max(g, b))
        let scale = peak > 1 ? peak / 0.9 : 1
        let rr = max(r, 0) / scale
        let gg = max(g, 0) / scale
        let bb = max(b, 0) / scale
        let mx = max(rr, max(gg, bb))
        let mn = min(rr, min(gg, bb))
        let d = mx - mn
        let l = (mx + mn) * 0.5
        guard d >= 1e-9 else { return (0, l, scale, 0) }
        let s = l > 0.5 ? d / max(2 - mx - mn, 1e-6) : d / max(mx + mn, 1e-6)
        var h: Double
        if mx == rr { h = (gg - bb) / d + (gg < bb ? 6 : 0) }
        else if mx == gg { h = (bb - rr) / d + 2 }
        else { h = (rr - gg) / d + 4 }
        return (min(max(s, 0), 1), l, scale, h / 6)
    }

    // MARK: - the plan

    /// The **vibrance-only** inverse (452), kept as the pure decision older callers use.
    ///
    /// Inverts the kernel's curve in *chroma* space: `C' = C + v/100 · k · (1 − C)`, so
    /// `v = 100 · (target − C) / (k · (1 − C))`. 498 keeps it for older callers and for the synthetic
    /// `Metrics` that carry no pixels; the product path `plan2D` replays the kernel on the measured
    /// samples so the result really lands on `targetChromaP50`.
    ///
    /// - Already at/above `target` → **0** (this tool only raises).
    /// - Fewer than `minimumColoredFraction` coloured samples → **0** (grey/black frames).
    /// - Otherwise clamped to `0 ... maxVibrance`.
    public static func plan(_ m: Metrics, target: Double = targetChromaP50) -> Double {
        guard m.sampleCount > 0 else { return 0 }
        guard m.coloredFraction >= minimumColoredFraction else { return 0 }
        let c = m.chromaP50
        let denominator = vibranceGain * (1 - c)
        guard denominator > 1e-9 else { return 0 }
        let v = 100 * (target - c) / denominator
        return min(maxVibrance, max(0, v))
    }

    /// The two sliders one 自动颜色 press writes, plus what the guard did.
    public struct Plan: Sendable, Equatable {
        /// Total `color.vibrance` to write (clamped to `0 ... maxVibrance`).
        public var vibrance: Double
        /// Total `color.saturation` to write (clamped to `0 ... maxSaturation`).
        public var saturation: Double
        /// The saturation the p95 solve asked for **before** the clipping/skin guard.
        public var unguardedSaturation: Double
        /// Newly clipped picture samples at the plan's own threshold; never above
        /// `maxNewClippedFraction` of the frame.
        public var newClippedPixels: Int
        /// Relative mean chroma change in the skin band caused by **saturation alone** (same
        /// vibrance, document's own saturation as the reference).
        public var skinChromaChange: Double
        /// What the plan predicts for the picture's p50/p95 after it is written.
        public var predictedChromaP50: Double
        public var predictedChromaP95: Double

        public var isEmpty: Bool { vibrance == 0 && saturation == 0 }

        static let zero = Plan(vibrance: 0, saturation: 0, unguardedSaturation: 0,
                               newClippedPixels: 0, skinChromaChange: 0,
                               predictedChromaP50: 0, predictedChromaP95: 0)
    }

    /// **498 — the product decision.** `p50 → vibrance`, `p95 → saturation`, both raise-only, with a
    /// hard no-new-clipping gate and a skin-band cap.
    ///
    /// `currentVibrance` / `currentSaturation` describe the picture that was measured (the sample
    /// already includes them, so they are inverted back to base first). `floorVibrance` /
    /// `floorSaturation` are the document that may be written over — the result is never below them,
    /// which is what makes a second press on a settled picture a no-op. In the normal call they are
    /// the same; 自动颜色's internal re-measure loop passes the original document as the floor.
    public static func plan2D(_ m: Metrics,
                              currentVibrance: Double = 0,
                              currentSaturation: Double = 0,
                              floorVibrance: Double? = nil,
                              floorSaturation: Double? = nil,
                              targetP50: Double = targetChromaP50,
                              targetP95: Double = targetChromaP95) -> Plan {
        guard m.sampleCount > 0, m.coloredFraction >= minimumColoredFraction else { return .zero }

        // The measured sliders are already in the sample. Recover each pixel's **base** saturation
        // once, then every solve below is an absolute slider solve — no additive double-counting, so
        // a settled document re-solves to exactly the values it already carries.
        //
        // `current*` describes the picture that was measured; `floor*` is the document the caller is
        // allowed to write over. They differ inside 自动颜色's own measure→plan→re-measure loop: a
        // staged overshoot may be lowered again, but never below the document the run started from.
        let measuredV = min(maxVibrance, max(0, currentVibrance))
        let measuredS = min(maxSaturation, max(0, currentSaturation))
        let floorV = min(maxVibrance, max(0, floorVibrance ?? currentVibrance))
        let floorS = min(maxSaturation, max(0, floorSaturation ?? currentSaturation))
        let pixels = m.pixels.isEmpty ? m.pixels
            : basePixels(m.pixels, vibrance: measuredV, saturation: measuredS)
        var vibrance = floorV
        var saturation = floorS
        var unguarded = floorS
        var newClipped = 0

        if pixels.isEmpty {
            // Synthetic Metrics (no pixels): keep the 452 formula, and treat its output as absolute.
            vibrance = min(maxVibrance, max(floorV, plan(m, target: targetP50)))
            let p95AfterV = predictedChroma(m.chromaP95, afterVibrance: vibrance)
            let settledP95 = targetP95 * (1 - settledTolerance)
            if p95AfterV > 1e-9, p95AfterV < settledP95 {
                saturation = min(maxSaturation,
                                 max(floorS, floorS + 100 * (targetP95 / p95AfterV - 1)))
            }
            unguarded = saturation
        } else {
            for _ in 0 ..< 4 {
                let nextV = solveVibrance(pixels, target: targetP50,
                                          range: floorV ... maxVibrance, saturation: saturation)
                let solvedS = saturationForP95(pixels, vibrance: nextV,
                                               target: targetP95, range: floorS ... maxSaturation)
                unguarded = solvedS
                var nextS = solvedS

                // Hard guard: no newly clipped picture sample.
                let cap = clippingLimitedSaturation(pixels, vibrance: nextV)
                if nextS > cap { nextS = max(floorS, cap) }

                // Skin guard: the **saturation stage's own** contribution to skin chroma must stay
                // within 10 %, measured against the same vibrance. Vibrance is not reduced here.
                if skinChromaChange(pixels, vibrance: nextV, saturation: nextS,
                                    reference: floorS) > skinGuardLimit {
                    nextS = skinLimitedSaturation(pixels, vibrance: nextV,
                                                  lower: floorS, limit: nextS)
                }

                let stable = abs(nextV - vibrance) < 1e-4 && abs(nextS - saturation) < 1e-4
                vibrance = nextV
                saturation = nextS
                if stable { break }
            }
            newClipped = countNewClipped(pixels, vibrance: vibrance, saturation: saturation)
            if Double(newClipped) / Double(m.sampleCount) > maxNewClippedFraction {
                // 护栏优先：never add a clipped sample just to reach the p95 target.
                saturation = floorS
                newClipped = 0
            }
        }

        // Snap sub-epsilon differences back to the document: a second press must not write a new row.
        if abs(vibrance - floorV) < settledSliderEpsilon { vibrance = floorV }
        if abs(saturation - floorS) < settledSliderEpsilon { saturation = floorS }

        let predicted50 = pixels.isEmpty
            ? predictedChroma(m.chromaP50, afterVibrance: vibrance)
            : percentileAfterPlan(pixels, vibrance: vibrance, saturation: saturation, q: 0.50)
        let predicted95 = pixels.isEmpty
            ? predictedChroma(m.chromaP95, afterVibrance: vibrance) * (1 + saturation / 100)
            : percentileAfterPlan(pixels, vibrance: vibrance, saturation: saturation, q: 0.95)
        return Plan(vibrance: vibrance, saturation: saturation,
                    unguardedSaturation: unguarded,
                    newClippedPixels: newClipped,
                    skinChromaChange: pixels.isEmpty ? 0
                        : skinChromaChange(pixels, vibrance: vibrance, saturation: saturation,
                                           reference: floorS),
                    predictedChromaP50: predicted50,
                    predictedChromaP95: predicted95)
    }

    /// Invert S3's two slider stages for every sample: observed saturation → base saturation.
    ///
    /// `s1 = s + V/100·k·(1−s)`, then `s2 = s1·(1+S/100)`. A sample already at the clamp is treated
    /// as base `s = 1` (it was clipped before this plan too, so the guard must not count it as new).
    private static func basePixels(_ pixels: [Metrics.Pixel], vibrance: Double,
                                   saturation: Double) -> [Metrics.Pixel] {
        guard abs(vibrance) > 1e-9 || abs(saturation) > 1e-9 else { return pixels }
        let satFactor = max(1e-6, 1 + saturation / 100)
        let lift = vibrance / 100 * vibranceGain
        let denominator = 1 - lift
        var out = pixels
        for i in out.indices {
            let observed = Double(out[i].hslSaturation)
            if observed >= 1 - saturationCeilingEpsilon {
                out[i].hslSaturation = 1
                continue
            }
            let s1 = observed / satFactor
            let base = abs(denominator) > 1e-6 ? (s1 - lift) / denominator : s1
            out[i].hslSaturation = Float(min(1, max(0, base)))
        }
        return out
    }

    // MARK: - solves

    /// The chroma S3 would produce for one sample after the two slider stages. This **replays the
    /// kernel** (HSL → `s1` → `s2` → HSL → OKLab) instead of assuming chroma grows linearly with
    /// saturation, which is what lets the solver land on the measured p50/p95 rather than near them.
    private static func chromaAfterPlan(_ p: Metrics.Pixel, vibrance: Double,
                                        saturation: Double) -> Float {
        let base = Double(p.hslSaturation)
        let s1 = liftedSaturation(base, vibrance: vibrance)
        let s2 = min(1, max(0, s1 * (1 + saturation / 100)))
        let rgb = hslToRGB(h: Double(p.hslHue),
                           s: s2, l: Double(p.hslLightness)) * Double(p.headroomScale)
        let lab = CalibrationGroup.oklab(fromRec2020: rgb)
        return Float((lab.y * lab.y + lab.z * lab.z).squareRoot())
    }

    private static func liftedSaturation(_ base: Double, vibrance v: Double) -> Double {
        guard base > 1e-6 else { return 0 }
        return min(1, max(0, base + v / 100 * vibranceGain * (1 - base)))
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> SIMD3<Double> {
        let hue = h - floor(h)
        let sat = min(1, max(0, s))
        let light = min(1, max(0, l))
        guard sat >= 1e-9 else { return SIMD3(light, light, light) }
        let q = light < 0.5 ? light * (1 + sat) : light + sat - light * sat
        let p = 2 * light - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
            return p
        }
        return SIMD3(channel(hue + 1.0 / 3.0), channel(hue), channel(hue - 1.0 / 3.0))
    }

    private static func predictedChroma(_ c: Double, afterVibrance v: Double) -> Double {
        c + v / 100 * vibranceGain * (1 - c)
    }

    private static func percentileAfterPlan(_ pixels: [Metrics.Pixel], vibrance: Double,
                                            saturation: Double, q: Double) -> Double {
        guard !pixels.isEmpty else { return 0 }
        var values = [Float](repeating: 0, count: pixels.count)
        for i in pixels.indices {
            values[i] = chromaAfterPlan(pixels[i], vibrance: vibrance, saturation: saturation)
        }
        return AutoLight.percentiles(values, [q])[0]
    }

    /// Binary-search the absolute vibrance that puts p50 on `target`, with the other slider held at
    /// `saturation`. `range.lowerBound` is the document's current value, so this only raises.
    private static func solveVibrance(_ pixels: [Metrics.Pixel], target: Double,
                                      range: ClosedRange<Double>,
                                      saturation: Double) -> Double {
        func p50(_ v: Double) -> Double {
            percentileAfterPlan(pixels, vibrance: v, saturation: saturation, q: 0.50)
        }
        let lower = range.lowerBound
        let upper = range.upperBound
        let goal = target * (1 - settledTolerance)
        if p50(lower) >= goal { return lower }
        if p50(upper) <= goal { return upper }
        var lo = lower
        var hi = upper
        for _ in 0 ..< 20 {
            let mid = (lo + hi) * 0.5
            if p50(mid) < target {
                lo = mid
            } else {
                hi = mid
            }
            if hi - lo < 1e-4 { break }
        }
        return hi
    }

    /// The absolute saturation that maps post-vibrance p95 onto `target`, searched between the
    /// document's current value and the ceiling. p95 is monotonic in saturation, so binary search is
    /// exact even though HSL→OKLab is not linear.
    private static func saturationForP95(_ pixels: [Metrics.Pixel], vibrance: Double,
                                         target: Double, range: ClosedRange<Double>) -> Double {
        guard target > 1e-9 else { return range.lowerBound }
        func p95(_ s: Double) -> Double {
            percentileAfterPlan(pixels, vibrance: vibrance, saturation: s, q: 0.95)
        }
        let lower = range.lowerBound
        let upper = range.upperBound
        let goal = target * (1 - settledTolerance)
        if p95(lower) >= goal { return lower }
        if p95(upper) <= goal { return upper }
        var lo = lower
        var hi = upper
        for _ in 0 ..< 20 {
            let mid = (lo + hi) * 0.5
            if p95(mid) < target {
                lo = mid
            } else {
                hi = mid
            }
            if hi - lo < 1e-4 { break }
        }
        return hi
    }

    /// The saturation at the `clippingGuardFraction` rank of per-pixel caps. Each cap is the largest
    /// `u` that keeps `s1 · (1 + u/100)` below the ceiling; taking a rank instead of the maximum is
    /// what lets one specular pixel stay a specular pixel without zeroing the global term, while the
    /// rank itself bounds the number of newly clipped samples.
    private static func clippingLimitedSaturation(_ pixels: [Metrics.Pixel],
                                                  vibrance: Double) -> Double {
        let ceiling = 1 - 2 * saturationCeilingEpsilon
        var caps: [Double] = []
        caps.reserveCapacity(pixels.count)
        for p in pixels where p.hslSaturation > 1e-6 {
            let s1 = liftedSaturation(Double(p.hslSaturation), vibrance: vibrance)
            guard s1 < 1 - saturationCeilingEpsilon, s1 > 1e-9 else { continue }
            caps.append(max(0, 100 * (ceiling / s1 - 1)))
        }
        guard !caps.isEmpty else { return 0 }
        caps.sort()
        let allowed = Int((clippingGuardFraction * Double(pixels.count)).rounded(.down))
        let index = min(max(allowed, 0), caps.count - 1)
        return caps[index]
    }

    private static func countNewClipped(_ pixels: [Metrics.Pixel], vibrance: Double,
                                        saturation: Double) -> Int {
        var count = 0
        for p in pixels where p.hslSaturation > 1e-6 {
            let s1 = liftedSaturation(Double(p.hslSaturation), vibrance: vibrance)
            guard s1 < 1 - saturationCeilingEpsilon else { continue }
            let s2 = min(1, s1 * (1 + saturation / 100))
            if s2 >= 1 - saturationCeilingEpsilon { count += 1 }
        }
        return count
    }

    /// Relative mean chroma change in the skin band caused by **saturation alone**: the reference is
    /// the same pixel at the same vibrance with the document's existing saturation. Vibrance is not
    /// part of this number, so a legitimate vibrance lift does not zero the saturation term.
    private static func skinChromaChange(_ pixels: [Metrics.Pixel], vibrance: Double,
                                         saturation: Double, reference: Double) -> Double {
        var before = 0.0
        var after = 0.0
        var count = 0
        for p in pixels {
            let hue = Double(p.hueDegrees)
            let c = Double(p.chroma)
            guard hue >= 50, hue <= 70, c > HSLBands.chromaGate else { continue }
            guard p.hslSaturation > 1e-6 else { continue }
            before += Double(chromaAfterPlan(p, vibrance: vibrance, saturation: reference))
            after += Double(chromaAfterPlan(p, vibrance: vibrance, saturation: saturation))
            count += 1
        }
        guard count > 0, before > 1e-9 else { return 0 }
        return (after - before) / before
    }

    private static func skinLimitedSaturation(_ pixels: [Metrics.Pixel], vibrance: Double,
                                              lower: Double, limit: Double) -> Double {
        if skinChromaChange(pixels, vibrance: vibrance, saturation: lower,
                            reference: lower) > skinGuardLimit {
            return lower
        }
        var lo = lower
        var hi = limit
        for _ in 0 ..< 20 {
            let mid = (lo + hi) * 0.5
            if skinChromaChange(pixels, vibrance: vibrance, saturation: mid,
                                reference: lower) > skinGuardLimit {
                hi = mid
            } else {
                lo = mid
            }
            if hi - lo < 1e-4 { break }
        }
        return lo
    }
}
