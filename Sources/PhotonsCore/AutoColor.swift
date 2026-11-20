import Foundation

// MARK: - 452 — 自动颜色（自动饱和度）的纯函数
//
// The owner's ask (2026-11-20): add 自动颜色 beside 自动黑电平 / 自动明暗, and make 自然饱和度
// less strong. This type is the **decision**, not the button: it measures a picture's OKLab chroma
// through the pipeline's own scene-linear sample and returns a suggested `color.vibrance` value.
// The UI/menu/shortcut entry is 453.
//
// **Why OKLab chroma and not HSL saturation.** HSL's `s` is a per-pixel statement about the largest
// channel, and it saturates at 1 on white; OKLab's `C = √(a² + b²)` is perceptual and survives the
// scene-linear → display-referred trip, which is also the space S3.6's bands use. `HSLBands.chromaGate`
// (0.02) is therefore the right "is this pixel coloured at all" line here too.
//
// **Only raise.** An automatic colour tool that desaturates a picture the owner deliberately
// saturated is a surprise, so `plan` never returns a negative number and caps at +60. A frame with
// almost no coloured samples (a grey wall, a night sky, a black frame) gets **0**: auto colour has
// nothing to act on, and pushing chroma there would invent tint.
//
// The target is **calibrated**, not a guessed round number: see `defaultTarget` and
// `AutoColor452Tests.testCalibrationDistribution452` (the 441 pattern).

public enum AutoColor {

    // MARK: - the measurement

    /// One picture's chroma distribution, at the scale `RenderGraph.measureLinearSample` measures on.
    public struct Metrics: Sendable, Equatable {
        /// Median OKLab chroma of the picture samples (letterbox excluded).
        public var chromaP50: Double
        /// Fraction of picture samples whose chroma is above `HSLBands.chromaGate` (0.02).
        public var coloredFraction: Double
        /// Picture samples the two numbers were computed over (letterbox sentinels excluded).
        public var sampleCount: Int

        public init(chromaP50: Double, coloredFraction: Double, sampleCount: Int) {
            self.chromaP50 = chromaP50
            self.coloredFraction = coloredFraction
            self.sampleCount = sampleCount
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

    /// **452 — 自动颜色的目标彩度。真库标定，不是拍的整数。**
    ///
    /// 与 441 同一个口径：取 `~/Documents/photons-demo.photonslibrary` 里**已有编辑**的照片
    /// （最新快照 `seq > 1`，按各自当前文档渲染），逐个算 `Metrics.chromaP50`，取其中位数。
    /// 标定（2026-11-20，**465 帧**，0 跳过）：
    ///
    ///     chromaP50        p10 0.0097 · p50 0.0219 · p90 0.0512
    ///     coloredFraction  p10 0.2001 · p50 0.5391 · p90 0.9554
    ///
    /// 所以字面量是 **0.0219**。它只比 `HSLBands.chromaGate`（0.02）高一点，这是照片本身的中位
    /// 彩度：已编辑库里 465 帧的中位就是这么多，自动颜色因此是一个**温和**的提亮（对中位附近的片子
    /// 约 +3…5 档 vibrance），不是把每张图都推到艳丽。标定命令见
    /// `AutoColor452Tests.testCalibrationDistribution452`。
    public static let defaultTarget: Double = 0.0219

    /// Below this coloured fraction the frame is (almost) grey and auto colour returns 0.
    /// Same line as `HSLBands.chromaGate`, so "coloured" means the same thing in both places.
    public static let minimumColoredFraction: Double = 0.02

    /// Auto colour only raises, and never past +60 — the owner's ceiling for an automatic move.
    public static let maxVibrance: Double = 60

    // MARK: - measurement

    /// One pass over the sample grid: OKLab chroma p50 and the coloured fraction.
    ///
    /// Letterbox / matte is excluded with the **same** rule `AutoLight.Sample.isPicture` uses — a
    /// sentinel texel has negative luma, and S2 clamps every real picture sample to `≥ 0`. The grid
    /// is the pipeline's ≤512-long-edge scene-linear sample, so this is the picture and not the canvas.
    public static func metrics(from sample: LinearSample) -> Metrics {
        let weights = ColorPrimaries.working.luminanceWeights
        let count = sample.width * sample.height
        var chroma: [Float] = []
        chroma.reserveCapacity(count)
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
        }
        guard !chroma.isEmpty else {
            return Metrics(chromaP50: 0, coloredFraction: 0, sampleCount: 0)
        }
        chroma.sort()
        return Metrics(chromaP50: AutoLight.percentile(chroma, 0.5),
                       coloredFraction: Double(colored) / Double(chroma.count),
                       sampleCount: chroma.count)
    }

    // MARK: - the plan

    /// The suggested `color.vibrance` for one picture.
    ///
    /// Inverts the kernel's curve in *chroma* space: `C' = C + v/100 · k · (1 − C)`, so
    /// `v = 100 · (target − C) / (k · (1 − C))`. It is an approximation — the kernel moves HSL
    /// saturation per pixel, not the picture's OKLab median — but it uses the same `k` and the same
    /// shape, which is what makes the result land where a hand move would.
    ///
    /// - Already at/above `target` → **0** (this tool only raises).
    /// - Fewer than `minimumColoredFraction` coloured samples → **0** (grey/black frames).
    /// - Otherwise clamped to `0 ... maxVibrance`.
    public static func plan(_ m: Metrics, target: Double = defaultTarget) -> Double {
        guard m.sampleCount > 0 else { return 0 }
        guard m.coloredFraction >= minimumColoredFraction else { return 0 }
        let c = m.chromaP50
        let denominator = vibranceGain * (1 - c)
        guard denominator > 1e-9 else { return 0 }
        let v = 100 * (target - c) / denominator
        return min(maxVibrance, max(0, v))
    }
}
