import Foundation

// MARK: - RGB 基色（075 的前置地基）
//
// 三套 D65 RGB 基色 —— **sRGB / Rec.709**、**Display P3**、**Rec.2020** —— 各带三样东西：
//
//   ① 基色 → XYZ 与 XYZ → 基色 的 3×3 矩阵（`Double`，行主序）；
//   ② 亮度权重（矩阵 Y 行的三个系数，`L = w·(R,G,B)`）；
//   ③ 任两套之间的转换矩阵 —— 由 ① 的两个矩阵**相乘**得到，**结果不手写**。
//
// 白点固定 **D65**（`whitePoint`），并且每条转换矩阵都带一条数值判据
// `preservesWhitePoint()`：行和 = 1 ± 1e-12，即中性 `(1,1,1)` 在三个基色下都是同一块白。
//
// ## 本文件不改任何像素
//
// 这一版**没有任何调用方**：`Sources/` 里没有一处引用 `ColorPrimaries`，所以文件存在与否，
// 渲染结果逐字节相同。它是 075 的批次 A/B 的唯一常数来源：
//
//   · 仓里有 **14 处**硬编码的 Rec709 权重（清单见 `luminanceWeights` 的注释），
//     迁移时全部换成 `ColorPrimaries.rec2020.luminanceWeights`，而不是散着改 14 次；
//   · `RenderGraph.primariesMatrix(from:to:)` 今天只认 `.sRGB → .displayP3`，其余一律 identity
//     （静默错误，见 075 §3.2）—— 那张表要由 `conversion(from:to:)` 填满。
//
// ## 矩阵是推出来的，不是抄来的
//
// `toXYZ` 由「三基色色度坐标 + 白点色度坐标」现场解出来（`linearRGBToXYZ`），
// 不是从表里抄九个数字。测试把它钉在 **W3C CSS Color 4** 的精确有理数矩阵（`lin_sRGB_to_XYZ` 等，
// https://www.w3.org/TR/css-color-4/#color-conversion-code ）上，容差 1e-12 —— 两路独立推导
// 在双精度下相差 ≤ 2.3e-16。sRGB→P3 还额外对上仓里**已经在运**的那七个常数
// （`RenderGraph.primariesMatrix`，即 Apple 的 P3 转换数字），容差 5e-7。
//
// 基色色度坐标的来源：
//   · sRGB / Rec.709 — ITU-R BT.709-6 Table 1（与 IEC 61966-2-1 的 sRGB 同基色、同白点）
//     https://www.itu.int/rec/R-REC-BT.709
//   · Display P3      — SMPTE ST 432-1（DCI-P3 基色）+ D65；Apple 的「Display P3」就是这一套
//     https://developer.apple.com/documentation/coregraphics/cgcolorspace/displayp3
//   · Rec.2020        — ITU-R BT.2020-2 Table 3（= BT.2100 的 UHDTV 基色）
//     https://www.itu.int/rec/R-REC-BT.2020
//   · 白点 D65        — CIE S 014-2 / ISO 11664-2：x = 0.3127, y = 0.3290
// 推导方法的独立参考：Bruce Lindbloom, "RGB/XYZ Matrices"
//   http://www.brucelindbloom.com/index.html?Eqn_RGB_XYZ_Matrix.html
//
// ## 两条会被这次迁移踩到的物理事实（测试里各有一条断言）
//
// 1. **Y 是不变量。** 同一物理色在两套基色下是两组不同的数字，但亮度相同：所以「只换基色」对
//    中性内容恒等（`0.18` 灰进 `Float16` 后**同码**），对饱和色则大幅改写。
// 2. **只换权重、不换基色不是重构，是调色。** 用 Rec2020 的权重去读 sRGB 基色的数字，饱和红
//    的亮度会从 0.212639 变成 0.262700（**+23.5%**），而普通照片的平均 |Δluma| 只有
//    0.00103 —— 这就是 075 §5.2 那个「golden 抓不到」的坑。
//
// ## 一个别踩的钳位顺序
//
// `Rec2020 → sRGB` 的最小系数是 **−0.5876411**，所以一个饱和的 Rec2020 绿 `(0,1,0)` 经它出来
// R = −0.5876。`s4_display.metal` 今天把 `max(v,0)` 放在矩阵**之前**，对 sRGB→P3（系数全非负）
// 无害；搬到 Rec2020 后这个负数会原样穿过 `srgb_encode` 写进纹理（075 §3.1）。
// 本文件只负责让那个数可见，修法在 kernel 里。

// MARK: - chromaticity

/// CIE 1931 的 `xy` 色度坐标（没有亮度）。
public struct Chromaticity: Sendable, Hashable {

    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// 该色度的 XYZ，`Y` 取给定亮度（默认 1 = 归一化）。
    ///
    /// `X = x/y·Y`、`Z = (1 − x − y)/y·Y` —— 这一步是唯一把色度坐标变成三刺激值的地方，
    /// 后面所有矩阵都从它出发。
    public func xyz(Y: Double = 1) -> SIMD3<Double> {
        SIMD3(x / y * Y, Y, (1 - x - y) / y * Y)
    }
}

/// 一套 RGB 基色的四个色度坐标：三基色 + 白点。
public struct RGBChromaticities: Sendable, Hashable {

    public var red: Chromaticity
    public var green: Chromaticity
    public var blue: Chromaticity
    public var white: Chromaticity

    public init(red: Chromaticity, green: Chromaticity, blue: Chromaticity, white: Chromaticity) {
        self.red = red
        self.green = green
        self.blue = blue
        self.white = white
    }
}

// MARK: - 3×3 matrix

/// 一个 `Double` 的 3×3 矩阵，**行主序**（`values[row * 3 + column]`）。
///
/// 行主序是为了和文档、RGB→XYZ 表的书写顺序一致：`matrix[0]` 是 X 那一行，
/// `matrix[1]` 是 Y 那一行 —— 也就是亮度权重那一行。转换到 GPU 时注意 Metal 的 `float3x3`
/// 初始化器是**列**主序，那时要做一次转置（`s4_display.metal` 的 `p.m` 就是这么喂的）。
public struct Matrix3: Sendable, Hashable {

    public let values: [Double]

    public init(rowMajor values: [Double]) {
        precondition(values.count == 9, "Matrix3 是 3×3，行主序展开应为 9 个数")
        self.values = values
    }

    public init(rows: [[Double]]) {
        precondition(rows.count == 3 && rows.allSatisfy { $0.count == 3 }, "Matrix3 是 3×3")
        self.values = rows.flatMap { $0 }
    }

    public static let identity = Matrix3(rows: [[1, 0, 0], [0, 1, 0], [0, 0, 1]])

    public subscript(row: Int, column: Int) -> Double {
        values[row * 3 + column]
    }

    public func row(_ index: Int) -> SIMD3<Double> {
        SIMD3(values[index * 3], values[index * 3 + 1], values[index * 3 + 2])
    }

    public func column(_ index: Int) -> SIMD3<Double> {
        SIMD3(values[index], values[3 + index], values[6 + index])
    }

    public var rows: [[Double]] {
        (0..<3).map { Array(values[($0 * 3)..<($0 * 3 + 3)]) }
    }

    /// 九个元素里的最小值。判断「是不是凸组合」（全部 ≥ 0）与「有没有负系数」都靠它。
    public var minimum: Double { values.min() ?? 0 }
    public var maximum: Double { values.max() ?? 0 }

    /// 三行的行和。白点不变的数值判据就是这三个数都是 1。
    public var rowSums: SIMD3<Double> {
        SIMD3(row(0).x + row(0).y + row(0).z,
              row(1).x + row(1).y + row(1).z,
              row(2).x + row(2).y + row(2).z)
    }

    public var determinant: Double {
        let a = self[0, 0], b = self[0, 1], c = self[0, 2]
        let d = self[1, 0], e = self[1, 1], f = self[1, 2]
        let g = self[2, 0], h = self[2, 1], i = self[2, 2]
        return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    }

    /// 逆矩阵（伴随矩阵 ÷ 行列式）。基色矩阵的行列式是两套基色在 XYZ 里的体积比，
    /// 永不为零 —— 这里仍然 `precondition`，因为「悄悄返回单位阵」正是 075 §3.2 要消灭的失败模式。
    public func inverted() -> Matrix3 {
        let a = self[0, 0], b = self[0, 1], c = self[0, 2]
        let d = self[1, 0], e = self[1, 1], f = self[1, 2]
        let g = self[2, 0], h = self[2, 1], i = self[2, 2]
        let det = determinant
        precondition(det != 0, "奇异矩阵没有逆：两套基色不可能重合到这种程度")
        return Matrix3(rows: [
            [e * i - f * h, c * h - b * i, b * f - c * e],
            [f * g - d * i, a * i - c * g, c * d - a * f],
            [d * h - e * g, b * g - a * h, a * e - b * d],
        ]).scaled(by: 1 / det)
    }

    public func scaled(by factor: Double) -> Matrix3 {
        Matrix3(rowMajor: values.map { $0 * factor })
    }

    /// `self · vector`
    public func applying(to v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(self[0, 0] * v.x + self[0, 1] * v.y + self[0, 2] * v.z,
              self[1, 0] * v.x + self[1, 1] * v.y + self[1, 2] * v.z,
              self[2, 0] * v.x + self[2, 1] * v.y + self[2, 2] * v.z)
    }

    /// `lhs · rhs`（矩阵积，不是逐元素积）。
    public static func * (lhs: Matrix3, rhs: Matrix3) -> Matrix3 {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                var sum = 0.0
                for k in 0..<3 { sum += lhs[r, k] * rhs[k, c] }
                out[r * 3 + c] = sum
            }
        }
        return Matrix3(rowMajor: out)
    }

    public static func * (lhs: Matrix3, rhs: SIMD3<Double>) -> SIMD3<Double> {
        lhs.applying(to: rhs)
    }

    public func maxAbsoluteDifference(from other: Matrix3) -> Double {
        zip(values, other.values).reduce(0) { Swift.max($0, abs($1.0 - $1.1)) }
    }

    /// **白点不变量**：中性 `(1,1,1)` 映射后仍是 `(1,1,1)`。
    ///
    /// 判据取行和（三行都为 1 ± tolerance），因为 `M·(1,1,1)` 的第 i 个分量就是第 i 行之和。
    /// 三套基色都把白归一化到 `Y = 1`，所以这条对**任意** (源, 目标) 组合都必须成立 ——
    /// 它不成立就说明基色或白点抄错了，与「哪个基色」无关。
    public func preservesWhitePoint(within tolerance: Double = ColorPrimaries.whitePointTolerance) -> Bool {
        let s = rowSums
        return abs(s.x - 1) <= tolerance && abs(s.y - 1) <= tolerance && abs(s.z - 1) <= tolerance
    }
}

// MARK: - the three spaces

/// 管线可选的三套 RGB 基色，全部 **D65**、全部把白归一化到 `Y = 1`。
///
/// 顺序（`allCases`）是 `sRGB → displayP3 → rec2020`：从窄到宽。P3 与 Rec2020 都严格包含
/// sRGB，所以「窄 → 宽」的矩阵系数全为正（凸组合，见 `testTheSRGBToRec2020MatrixIsAConvexCombination`），
/// 「宽 → 窄」的矩阵必然有负系数。
public enum ColorPrimaries: String, Sendable, Hashable, CaseIterable, Codable {

    /// sRGB / Rec.709 —— 仓里今天的工作空间。两者的**基色与白点完全相同**（只有传输函数不同），
    /// 而这一层只关心基色，所以它们本来就是同一套数字。
    case sRGB

    /// Display P3（SMPTE ST 432-1 基色 + D65）。
    case displayP3

    /// Rec.2020（BT.2020-2 / BT.2100 的 UHDTV 基色 + D65）—— 075 的目标工作空间。
    case rec2020

    // MARK: chromaticities

    public var chromaticities: RGBChromaticities {
        switch self {
        case .sRGB: return Self.sRGBChromaticities
        case .displayP3: return Self.p3Chromaticities
        case .rec2020: return Self.rec2020Chromaticities
        }
    }

    /// BT.709-6 Table 1（IEC 61966-2-1 的 sRGB 同值）。
    public static let sRGBChromaticities = RGBChromaticities(
        red: Chromaticity(x: 0.640, y: 0.330),
        green: Chromaticity(x: 0.300, y: 0.600),
        blue: Chromaticity(x: 0.150, y: 0.060),
        white: whitePoint)

    /// SMPTE ST 432-1 的 DCI-P3 基色 + D65。
    public static let p3Chromaticities = RGBChromaticities(
        red: Chromaticity(x: 0.680, y: 0.320),
        green: Chromaticity(x: 0.265, y: 0.690),
        blue: Chromaticity(x: 0.150, y: 0.060),
        white: whitePoint)

    /// BT.2020-2 Table 3。注意蓝基色是 `(0.131, 0.046)`，不是 P3/sRGB 的 `(0.150, 0.060)`。
    public static let rec2020Chromaticities = RGBChromaticities(
        red: Chromaticity(x: 0.708, y: 0.292),
        green: Chromaticity(x: 0.170, y: 0.797),
        blue: Chromaticity(x: 0.131, y: 0.046),
        white: whitePoint)

    /// **D65**（CIE S 014-2）：x = 0.3127, y = 0.3290 → XYZ ≈ (0.95046, 1, 1.08906)。
    ///
    /// 三个候选基色用的是同一个白点，这是「搬迁不动中性内容」的全部理由：
    /// 白点一致 ⇒ 中性 `(1,1,1)` 在两边都是同一块白 ⇒ 每行和为 1。
    public static let whitePoint = Chromaticity(x: 0.3127, y: 0.3290)

    /// `preservesWhitePoint` 的容差：1e-12。双精度下实际残差 ~2e-16，这个容差留了 4 个数量级，
    /// 但比任何真实错误（抄错基色 ⇒ 1e-3 量级）小得多。
    public static let whitePointTolerance = 1e-12

    // MARK: - 管线的两端（075 批次 A）

    /// **解码器**写出的基色 —— 仍然是线性 sRGB。
    ///
    /// 075 的决定是「解码不动」：`CIContext` 的工作空间、`LinearImageStore` 的缓存键
    /// （`colorSpace` 在键文本里）以及解码 golden 全部保持原样，磁盘上已有的 60 MP 缓冲继续命中。
    /// 所以这个常数是**标签的真话**，不是待改项。
    public static let decoded: ColorPrimaries = .sRGB

    /// 管线的**工作基色**：S0 出口之后、S4 入口之前，所有 stage 里的数字都在这个空间里。
    ///
    /// 两处使用，都在 `RenderGraph` 里，且都必须引用**这一个**常数：
    ///   · S0 的出口矩阵 `conversion(from: .decoded, to: .working)`；
    ///   · S4 的入口矩阵 `conversion(from: .working, to: 输出基色)`。
    /// 批次 D（把解码本身搬过去）的全部改动就是把 `decoded` 改成 `.rec2020`，S0 的矩阵随之变成
    /// 恒等 —— 那时 `conversion` 的 1e-16 残差就要靠 `RenderGraph.primariesMatrix` 的
    /// `source == target` 分支吃掉，所以它必须存在。
    public static let working: ColorPrimaries = .rec2020

    // MARK: matrices

    /// 基色 → XYZ。`Double`，行主序，`Y` 列（第 2 行）就是亮度权重。
    ///
    /// 由 `linearRGBToXYZ` 从基色 + 白点推得，不是抄表。
    public var toXYZ: Matrix3 {
        switch self {
        case .sRGB: return Self.sRGBToXYZ
        case .displayP3: return Self.p3ToXYZ
        case .rec2020: return Self.rec2020ToXYZ
        }
    }

    /// XYZ → 基色（`toXYZ` 的逆）。宽 → 窄方向的负系数都在这里。
    public var fromXYZ: Matrix3 {
        switch self {
        case .sRGB: return Self.xyzToSRGB
        case .displayP3: return Self.xyzToP3
        case .rec2020: return Self.xyzToRec2020
        }
    }

    private static let sRGBToXYZ = linearRGBToXYZ(sRGBChromaticities)
    private static let p3ToXYZ = linearRGBToXYZ(p3Chromaticities)
    private static let rec2020ToXYZ = linearRGBToXYZ(rec2020Chromaticities)

    private static let xyzToSRGB = sRGBToXYZ.inverted()
    private static let xyzToP3 = p3ToXYZ.inverted()
    private static let xyzToRec2020 = rec2020ToXYZ.inverted()

    /// **源基色 → 目标基色**：`toXYZ(目标)⁻¹ · toXYZ(源)`。
    ///
    /// 两个矩阵相乘，**不手写结果** —— 手写的那张表（075 §2.0 的三张）是核对用的，
    /// 不是实现。`source == target` 时在双精度下得到单位阵（残差 ≤ 1e-16，不是位相等）。
    public static func conversion(from source: ColorPrimaries, to target: ColorPrimaries) -> Matrix3 {
        target.fromXYZ * source.toXYZ
    }

    // MARK: luminance

    /// 亮度权重，`L = w.x·R + w.y·G + w.z·B`，分量顺序 **(R, G, B)**。
    ///
    /// 这些是**规范里的常数**（管线要用的就是它们），不是 `toXYZ` 的第 2 行 —— 两者的一致性由
    /// `derivedLuminanceWeights` 与测试里的容差预算来保证（见下表）。
    ///
    /// | 基色 | 常数（本属性） | 从基色推得 | 差 | 来源 |
    /// |---|---|---|---|---|
    /// | sRGB/709 | 0.2126 / 0.7152 / 0.0722 | 0.21263901 / 0.71516868 / 0.07219232 | ≤ 3.9e-5 | BT.709-6 Table 3 的四位小数舍入 |
    /// | Display P3 | 0.2289746 / 0.6917385 / 0.0792869 | 0.22897456 / 0.69173852 / 0.07928691 | ≤ 3.6e-8 | 基色 + D65 反推 |
    /// | Rec.2020 | 0.2627 / 0.6780 / 0.0593 | 0.26270021 / 0.67799807 / 0.05930172 | ≤ 1.9e-6 | BT.2020-2 的四位小数舍入 |
    ///
    /// **sRGB 这一行要原样保留**：今天仓里有 14 处硬编码的正是这三个数，换基色时它们是
    /// **同一批**要换的（075 §2.1 清单）：
    ///
    /// ```
    /// Kernels/s2_tone_map.metal:82
    /// Kernels/tone_shape.metal（`kEndPointLumaWeights`，073B/073C 的端点取样；079 §2.1.2 起 S1 与 S1.6 共用）
    /// Kernels/histogram_sample.metal:90-92
    /// Kernels/s1_7_hdr_curve.metal:99            （注释；kernel 从 p.d.xyz 读）
    /// HDRCurve.swift:163                         （lumaWeights）
    /// Histogram.swift:153                        （lumaWeights）
    /// Histogram.swift:60, 399                    （注释）
    /// LinearImage.swift:212, 292
    /// RenderGraph.swift:2441                     （guided filter 的 b.y/z/w）
    /// HistogramCard.swift:947-949
    /// UISmokeRunner.swift:1732, 1743-1745
    /// ```
    public var luminanceWeights: SIMD3<Double> {
        switch self {
        case .sRGB: return SIMD3(0.2126, 0.7152, 0.0722)
        case .displayP3: return SIMD3(0.2289746, 0.6917385, 0.0792869)
        case .rec2020: return SIMD3(0.2627, 0.6780, 0.0593)
        }
    }

    /// `toXYZ` 的 Y 行 —— 从基色 + 白点**推出来**的权重。
    ///
    /// 它与 `luminanceWeights` 的差就是上表那一列（规范常数的小数舍入）。
    /// 用这一组时「权重算出的亮度」与「矩阵算出的 Y」在双精度下是同一个数（≤ 1e-16），
    /// 所以测试用它来做 1e-9 的相等断言。
    public var derivedLuminanceWeights: SIMD3<Double> { toXYZ.row(1) }

    /// `L = w·(R,G,B)`，权重取上面那一组规范常数。
    public func luminance(of linear: SIMD3<Double>) -> Double {
        let w = luminanceWeights
        return w.x * linear.x + w.y * linear.y + w.z * linear.z
    }

    // MARK: derivation

    /// 从三基色 + 白点解出 RGB → XYZ。
    ///
    /// 先把每个基色放到「`Y = 1`」的位置（列向量），得到一个只差缩放的矩阵 `C`；
    /// 再解 `C · s = XYZ(白)`，用它按列缩放。条件是**白映射到白且 `Y = 1`** ——
    /// 这正是「三套基色的中性都是同一块白」的形式化，也是每行和为 1 的来源。
    ///
    /// 结果与 W3C CSS Color 4 的精确有理数矩阵（`lin_sRGB_to_XYZ` 等）相差 ≤ 2.3e-16，
    /// 与 Lindbloom 的 sRGB 表相差 ~2.3e-4（他用的是 D65 的精确 XYZ 而不是 4 位色度坐标，
    /// 见 `testTheMatricesReproduceThePublishedReference` 的第一条注释）。
    private static func linearRGBToXYZ(_ c: RGBChromaticities) -> Matrix3 {
        let r = c.red.xyz()
        let g = c.green.xyz()
        let b = c.blue.xyz()
        let columns = Matrix3(rows: [
            [r.x, g.x, b.x],
            [r.y, g.y, b.y],
            [r.z, g.z, b.z],
        ])
        let s = columns.inverted() * c.white.xyz()
        return columns * Matrix3(rows: [[s.x, 0, 0], [0, s.y, 0], [0, 0, s.z]])
    }
}
