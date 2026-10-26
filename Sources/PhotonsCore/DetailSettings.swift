import Foundation

// MARK: - 细节 / 降噪（派单 031）
//
// 「降噪」和「细节」不是渲染后处理：它们是 **解码**参数，必须在 `CIRAWFilter` 输出像素之前
// 交给它（`luminanceNoiseReductionAmount` / `colorNoiseReductionAmount` / `sharpnessAmount` /
// `detailAmount`）。所以这一组值住在 `DecodeInputs` 里，改一个值就是一次新的 develop
// （60 MP 全尺寸 1–5 s），而不是一次新的 render。
//
// 本机实测（macOS 27.2，L1030433.dng / 908×606 缩放解码，每题一个新 `CIRAWFilter` + 新
// `CIContext` —— 复用 context 会缓存渲染结果，是这段代码最容易骗过自己的地方）：
//
//   · **回读永远等于所设**。四个属性都接受任意 Float（−0.5、2.0 原样保留，谁都不钳制），
//     所以「设进去 → 读回来」只能证明属性存在，**不能证明它影响了像素**。范围钳制必须是我们的。
//   · **不动手时的基线不是 0**：`luminanceNoiseReductionAmount` 0.000、`detailAmount` 0.000，
//     但 `colorNoiseReductionAmount` **0.500**、`sharpnessAmount` **0.500**。这正是「0 = 保持
//     系统默认」必须翻译成「不赋值」的原因：把 0 显式赋给色彩降噪会把 Apple 的默认一半
//     降噪关掉（实测 1656830 个采样变化）。
//   · **是否有效按解码器版本分裂**（同一文件）：v8 只有 `colorNoiseReductionAmount` 改变像素；
//     v8.dng 上 `luminanceNoiseReductionAmount`/`detailAmount` 生效；v9.dng 上
//     `luminanceNoiseReductionAmount`/`sharpnessAmount` 生效。默认走 v8（D2′），因此在本机
//     的 Leica 样张上「降噪/细节/锐化」三根滑杆**会**改变缓存键与解码调用，但 v8 不改变像素 ——
//     这是 Apple 解码器的行为，不是接线错误，`DetailTests` 把这条实测钉住，不让它悄悄变。
public struct DetailSettings: Sendable, Hashable, Codable {

    /// 亮度降噪（「降噪」滑杆）。0 = 不动解码器，正数向 1.0 走，负数向 0 走。
    public var luminanceNR: Double
    /// 色度降噪。同上，但基线是 0.5（实测），所以负半边是真的「比默认更少降噪」。
    public var colorNR: Double
    /// 锐化。基线 0.5。
    public var sharpness: Double
    /// 细节。基线 0.0。
    public var detail: Double

    /// 全部 0 = 不动解码器 = 与 031 之前的解码**逐字节相同**。
    public static let identity = DetailSettings()

    /// 四根滑杆的行程。0 是「Apple 的默认」，负数是「比默认更少」，所以是双极的。
    public static let range: ClosedRange<Double> = -100...100
    /// 滑杆量化：1 个单位。缩到手再 commit，所以文档里只存整数（与白平衡的 25 K 同一条纪律）。
    public static let step: Double = 1

    public init(luminanceNR: Double = 0, colorNR: Double = 0,
                sharpness: Double = 0, detail: Double = 0) {
        self.luminanceNR = luminanceNR
        self.colorNR = colorNR
        self.sharpness = sharpness
        self.detail = detail
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var v = DetailSettings.identity
        v.luminanceNR = c.val("luminanceNR", v.luminanceNR)
        v.colorNR = c.val("colorNR", v.colorNR)
        v.sharpness = c.val("sharpness", v.sharpness)
        v.detail = c.val("detail", v.detail)
        self = v
    }

    /// 文档里的每个字段都必须有显式默认值（D9）：缺键 = 0，不是解码失败、也不是 NaN。
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(luminanceNR, forKey: AnyCodingKey("luminanceNR"))
        try c.encode(colorNR, forKey: AnyCodingKey("colorNR"))
        try c.encode(sharpness, forKey: AnyCodingKey("sharpness"))
        try c.encode(detail, forKey: AnyCodingKey("detail"))
    }

    public var isIdentity: Bool { self == DetailSettings.identity }

    /// 钳制到滑杆行程。**不解码**，只保证映射的输入不越界。
    public func clamped() -> DetailSettings {
        func c(_ v: Double) -> Double {
            guard v.isFinite else { return 0 }
            return min(max(v, Self.range.lowerBound), Self.range.upperBound)
        }
        return DetailSettings(luminanceNR: c(luminanceNR), colorNR: c(colorNR),
                              sharpness: c(sharpness), detail: c(detail))
    }

    /// 量化到 `step`（1 个单位）再钳制 —— 唯一会被 commit 的形式。
    public func quantized() -> DetailSettings {
        func q(_ v: Double) -> Double {
            guard v.isFinite else { return 0 }
            return (v / Self.step).rounded() * Self.step
        }
        return DetailSettings(luminanceNR: q(luminanceNR), colorNR: q(colorNR),
                              sharpness: q(sharpness), detail: q(detail)).clamped()
    }

    /// 这一个值给解码缓存键 / rung identity 的部分：`dt=nr+30.00,c+0.00,s-20.00,d+10.00`。
    ///
    /// `nil`（全 0）而不是空串：默认文档必须**什么都不追加**，否则每一个已经写在磁盘上的
    /// 线性缓冲、每一个 rung identity 都会变，而像素一个都没变（与白平衡 as shot 同一条纪律）。
    public var decodeComponent: String? {
        guard !isIdentity else { return nil }
        return String(format: "dt=nr%+.2f,c%+.2f,s%+.2f,d%+.2f",
                      luminanceNR, colorNR, sharpness, detail)
    }

    /// 一行给检查器/报告：`降噪 +30 · 色彩 −20 · 细节 0 · 锐化 +10`。
    public var summary: String {
        String(format: "NR %+.0f / %+.0f · detail %+.0f · sharp %+.0f",
               luminanceNR, colorNR, detail, sharpness)
    }

    // MARK: - slider → CIRAWFilter value

    /// 一根滑杆的值翻译成**该属性**要赋的值；`nil` = 不要碰这个属性。
    ///
    /// `baseline` 是解码器在什么都没赋值时报的值（每根轴不同：实测亮度 0.0、色度 0.5、
    /// 锐化 0.5、细节 0.0）。因此滑杆是**相对**的：
    ///
    ///   · `0`     → `nil`，解码器保持 Apple 自己的默认（这也是「默认文档像素不变」的实现）；
    ///   · `+100`  → 1.0（该属性的最大值）；
    ///   · `−100`  → 0.0（关掉）；
    ///   · 中间值在 `baseline` 与两端之间线性插值。
    ///
    /// 结果一定落在 0…1（`CIRAWFilter` 自己不钳制：实测赋 2.0 会读回 2.0），插值也保证了
    /// 「加一点」不会因为基线是 0.5 而突然跳到 1。
    public static func decodeAmount(slider: Double, baseline: Double) -> Double? {
        guard slider.isFinite else { return nil }
        let s = min(max(slider, range.lowerBound), range.upperBound) / range.upperBound   // −1…1
        guard s != 0 else { return nil }
        let b = min(max(baseline.isFinite ? baseline : 0, 0), 1)
        let raw = s > 0 ? b + (1 - b) * s : b * (1 + s)
        return min(max(raw, 0), 1)
    }

    /// The four values one develop must assign, given what the filter reports before we touch it.
    public func decodeValues(baseline: DetailBaseline) -> DetailDecodeValues {
        DetailDecodeValues(
            luminanceNR: Self.decodeAmount(slider: luminanceNR, baseline: baseline.luminanceNR),
            colorNR: Self.decodeAmount(slider: colorNR, baseline: baseline.colorNR),
            sharpness: Self.decodeAmount(slider: sharpness, baseline: baseline.sharpness),
            detail: Self.decodeAmount(slider: detail, baseline: baseline.detail))
    }
}

/// What `CIRAWFilter` reports for the four axes **before** a document assigns anything.
///
/// Not a constant: it is per file and per decoder version, and it is what makes the sliders
/// relative ("a bit less NR than Apple chose for this body") instead of absolute guesses.
public struct DetailBaseline: Sendable, Equatable {

    public var luminanceNR: Double
    public var colorNR: Double
    public var sharpness: Double
    public var detail: Double

    /// The four values measured on this machine with nothing assigned. Used by the tests and by
    /// any caller that has no filter to ask; a develop always reads the live filter instead.
    public static let measured = DetailBaseline(luminanceNR: 0, colorNR: 0.5,
                                               sharpness: 0.5, detail: 0)

    public init(luminanceNR: Double, colorNR: Double, sharpness: Double, detail: Double) {
        self.luminanceNR = luminanceNR
        self.colorNR = colorNR
        self.sharpness = sharpness
        self.detail = detail
    }
}

/// One develop's four assignments; `nil` means "leave that property alone".
public struct DetailDecodeValues: Sendable, Equatable {

    public var luminanceNR: Double?
    public var colorNR: Double?
    public var sharpness: Double?
    public var detail: Double?

    public init(luminanceNR: Double? = nil, colorNR: Double? = nil,
                sharpness: Double? = nil, detail: Double? = nil) {
        self.luminanceNR = luminanceNR
        self.colorNR = colorNR
        self.sharpness = sharpness
        self.detail = detail
    }

    /// Nothing to assign: the filter keeps Apple's own four values (the default document).
    public var isEmpty: Bool {
        luminanceNR == nil && colorNR == nil && sharpness == nil && detail == nil
    }

    /// `nr=0.30 c=– sh=– d=–` for a log line or a test failure message.
    public var summary: String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }
        return "nr=\(f(luminanceNR)) c=\(f(colorNR)) sh=\(f(sharpness)) d=\(f(detail))"
    }
}
