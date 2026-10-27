import XCTest
@testable import PhotonsCore

/// 075 的前置地基 —— 基色矩阵与亮度权重。
///
/// `Sources/PhotonsCore/ColorPrimaries.swift` 里没有一行判定逻辑：三套基色的 RGB→XYZ 由
/// 基色 + 白点**现场解出**，互转矩阵由两个矩阵**相乘**得到。所以这个文件要证的不是「代码照着表
/// 写对了」，而是**那张表本身是对的**，而且它的每一个后果都被钉住：
///
///   1. 推导复现公开参考值（W3C CSS Color 4 的精确有理数矩阵，1e-12），也复现仓里**已经在运**的
///      `RenderGraph.primariesMatrix` sRGB→P3 七个常数（5e-7）。
///   2. sRGB→Rec2020 的九个数逐项钉住；行列式 > 0；**九个系数全为正**（凸组合）；而行列式与负系数
///      真正出现的地方是它的逆（min = −0.5876411）—— 那就是 `s4_display.metal` 会算出负 R 的原因。
///   3. A→B→A 是单位阵（六种顺序，±1e-12）。
///   4. 白点：行和 = 1 ± 1e-12、`(1,1,1) → (1,1,1)`、`toXYZ·(1,1,1)` 的 Y 恰为 1 且色度回到 D65。
///   5. 权重：`w·C` 与矩阵算出的 Y 是同一个数（±1e-9）；三套的规范和都是 1。
///   6. 已知色：饱和红 `(1,0,0)` → `(0.6274, 0.0691, 0.0164)`；`0.18` 灰**逐位**不变（**Float16 同码**）；
///      Y 是往返不变量。
///   7. **反证**：只换权重不换基色，饱和红的亮度偏 **+23.5%**（≥ 20%），绿 −5.2%、蓝 −17.9%，
///      中性灰 0.0% —— 075 §5.2 那个「真照片 golden 抓不到」的坑。
final class ColorPrimariesTests: XCTestCase {

    // MARK: - helpers

    /// 逐元素比较，报出**哪个元素**不对（`XCTAssertEqual` 的数组比较只给最大值，定位成本高）。
    private func assertMatrix(_ m: Matrix3, equals reference: [[Double]], accuracy: Double,
                              _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for r in 0..<3 {
            for c in 0..<3 {
                XCTAssertEqual(m[r, c], reference[r][c], accuracy: accuracy,
                               "\(label)[\(r)][\(c)]", file: file, line: line)
            }
        }
    }

    private func format(_ m: Matrix3) -> String {
        m.rows.map { "[" + $0.map { String(format: "%+.9f", $0) }.joined(separator: " ") + "]" }
            .joined(separator: " ")
    }

    private func format(_ v: SIMD3<Double>) -> String {
        String(format: "%+.9f %+.9f %+.9f", v.x, v.y, v.z)
    }

    private func maxAbs(_ v: SIMD3<Double>) -> Double {
        max(abs(v.x), max(abs(v.y), abs(v.z)))
    }

    // MARK: - 1. the derivation reproduces published numbers

    /// 公开参考值：W3C CSS Color 4 非规范性样例代码里的**精确有理数**矩阵
    /// （https://www.w3.org/TR/css-color-4/#color-conversion-code ，`lin_sRGB_to_XYZ` /
    /// `lin_P3_to_XYZ` / `lin_2020_to_XYZ`），在这里写成 15 位小数。
    ///
    /// 为什么不是 Lindbloom 的表：他用的是 D65 的精确 XYZ（0.95047 / 1.08883），而 CSS Color 4
    /// 用的是 4 位色度坐标 `(0.3127, 0.3290)` —— 与本文件一致。两路的差是 2.3e-4（就在
    /// `[0][0] = 0.4124564` vs `0.4123908`），不是精度问题，是白点的小数位不同。
    /// 本文件取 4 位色度坐标这一路，因为它与 CSS Color 4、Chrome/Safari 的 sRGB→P3→Rec2020
    /// 转换是同一套数字，而且它复现了仓里已经在跑的 sRGB→P3 常数（见下一条测试）。
    func testTheMatricesReproduceThePublishedReference() {
        assertMatrix(ColorPrimaries.sRGB.toXYZ, equals: [
            [0.412390799265960, 0.357584339383878, 0.180480788401834],
            [0.212639005871510, 0.715168678767756, 0.072192315360734],
            [0.019330818715592, 0.119194779794626, 0.950532152249661],
        ], accuracy: 1e-12, "sRGB → XYZ")

        assertMatrix(ColorPrimaries.displayP3.toXYZ, equals: [
            [0.486570948648216, 0.265667693169093, 0.198217285234362],
            [0.228974564069749, 0.691738521836506, 0.079286914093745],
            [0.000000000000000, 0.045113381858903, 1.043944368900976],
        ], accuracy: 1e-12, "P3 → XYZ")

        assertMatrix(ColorPrimaries.rec2020.toXYZ, equals: [
            [0.636958048301291, 0.144616903586208, 0.168880975164172],
            [0.262700212011267, 0.677998071518871, 0.059301716469862],
            [0.000000000000000, 0.028072693049088, 1.060985057710791],
        ], accuracy: 1e-12, "Rec2020 → XYZ")

        // `fromXYZ` 是数值逆，不是抄的逆表。两个方向的往返误差就是它的精度证明。
        for space in ColorPrimaries.allCases {
            let roundTrip = space.fromXYZ * space.toXYZ
            XCTAssertLessThanOrEqual(roundTrip.maxAbsoluteDifference(from: .identity), 1e-12,
                                     "\(space.rawValue)：逆矩阵不是数值逆")
        }

        print("toXYZ · sRGB  " + format(ColorPrimaries.sRGB.toXYZ))
        print("toXYZ · P3    " + format(ColorPrimaries.displayP3.toXYZ))
        print("toXYZ · 2020  " + format(ColorPrimaries.rec2020.toXYZ))
        print("det · " + ColorPrimaries.allCases
            .map { "\($0.rawValue) \(String(format: "%.9f", $0.toXYZ.determinant))" }
            .joined(separator: " · "))
    }

    /// 仓里**已经在运**的那七个常数（`RenderGraph.primariesMatrix`，Apple 的 sRGB→P3 数字）
    /// 必须与本文件的推导一致 —— 这证明「换基色」不是换了一套数学，而是把同一套数学用在更宽的
    /// 基色上。差 1.1e-7 全部来自那七个常数的第七位小数。
    func testTheDerivationMatchesTheMatrixAlreadyShipping() {
        let shipped = RenderGraph.primariesMatrix(from: .sRGB, to: .displayP3)
        // `simd_float4x4` 是列主序（`columns.0` 是第一**列**），本文件是行主序。
        let reference = [[Double(shipped.columns.0.x), Double(shipped.columns.1.x), Double(shipped.columns.2.x)],
                         [Double(shipped.columns.0.y), Double(shipped.columns.1.y), Double(shipped.columns.2.y)],
                         [Double(shipped.columns.0.z), Double(shipped.columns.1.z), Double(shipped.columns.2.z)]]

        let ours = ColorPrimaries.conversion(from: .sRGB, to: .displayP3)
        assertMatrix(ours, equals: reference, accuracy: 5e-7, "sRGB → P3（对照已在运的常数）")

        print("sRGB→P3 vs 已在运的常数 · max|Δ| = "
              + String(format: "%.2e", (0..<3).flatMap { r in (0..<3).map { c in abs(ours[r, c] - reference[r][c]) } }.max() ?? 0))
    }

    // MARK: - 2. sRGB → Rec2020, the matrix this migration hangs on

    /// 公开参考值同样是 CSS Color 4 的那套精确有理数（`sRGB → XYZ → Rec2020` 复合）。
    /// 九个数逐项对，容差 1e-12 —— 比派单要求的 1e-6 严五个数量级，因为两路推导在双精度下
    /// 只差 1e-16。
    func testSRGBToRec2020MatchesThePublishedMatrix() {
        let t = ColorPrimaries.conversion(from: .sRGB, to: .rec2020)
        assertMatrix(t, equals: [
            [0.627403895934699, 0.329283038377884, 0.043313065687417],
            [0.069097289358232, 0.919540395075459, 0.011362315566309],
            [0.016391438875150, 0.088013307877226, 0.895595253247624],
        ], accuracy: 1e-12, "sRGB → Rec2020")

        // 行列式是两套基色的体积比：`conversion = toXYZ(目标)⁻¹·toXYZ(源)`，所以
        // det = V(源)/V(目标) = 0.207094 / 0.418070 = **0.4954** —— 窄 → 宽方向必然 < 1。
        // 直觉：今天塞满 sRGB 立方体的那批物理色，在 Rec2020 立方体里只占一半体积
        // （这就是饱和红从 1.0 掉到 0.6274 的同一件事）。符号仍然必须为正（不翻转色相）。
        XCTAssertGreaterThan(t.determinant, 0, "基色矩阵的行列式必须为正（右手系，不翻转色相）")
        XCTAssertLessThan(t.determinant, 1, "窄 → 宽：det = V(sRGB)/V(Rec2020) < 1")
        XCTAssertEqual(t.determinant, 0.495357082319, accuracy: 1e-11)
        XCTAssertEqual(ColorPrimaries.rec2020.toXYZ.determinant / ColorPrimaries.sRGB.toXYZ.determinant,
                       1 / t.determinant, accuracy: 1e-12, "体积比与 det 互为倒数")
        print("sRGB→2020 · det = " + String(format: "%.12f", t.determinant) + "  " + format(t))

        // **凸组合**：窄 → 宽方向的系数全为正、行和为 1，所以输出必然落在三个输入的 min–max 之间。
        // 这是 075 §1.4 那句「负样本变 0 是正确行为」的全部理由。
        XCTAssertGreaterThanOrEqual(t.minimum, 0,
                                    "sRGB→Rec2020 应当全为正（凸组合）；出现负数说明基色或白点抄错了")
        XCTAssertEqual(t.minimum, 0.011362315566, accuracy: 1e-12, "最小的那个系数")
        XCTAssertTrue(t.preservesWhitePoint())
    }

    /// **负系数在逆矩阵里，不在正向矩阵里。**
    ///
    /// 派单里写的是「断言 sRGB→Rec2020 的最小元素 < 0」—— 但那九个数是全正的（上一条测试钉住）。
    /// 真正为负、也真正会让 `s4_display.metal` 吐出负 R 的，是 **Rec2020 → sRGB**：
    /// 它的最小系数是 −0.5876411，于是 Rec2020 的饱和绿 `(0,1,0)` 出来 R = −0.5876。
    /// 两条断言都写在这里，免得下一个人按派单的字面去「修正」一个没有错的东西。
    func testTheNegativeCoefficientsLiveInTheInverse() {
        let forward = ColorPrimaries.conversion(from: .sRGB, to: .rec2020)
        let back = ColorPrimaries.conversion(from: .rec2020, to: .sRGB)

        XCTAssertGreaterThan(forward.minimum, 0, "sRGB→Rec2020 全为正（凸组合）")
        XCTAssertLessThan(back.minimum, 0, "Rec2020→sRGB 必须有负系数 —— 这就是 s4_display 的负 R")

        assertMatrix(back, equals: [
            [1.660491002108, -0.587641138789, -0.072849863320],
            [-0.124550474522, 1.132899897126, -0.008349422604],
            [-0.018150763355, -0.100578898008, 1.118729661363],
        ], accuracy: 1e-11, "Rec2020 → sRGB")
        XCTAssertEqual(back.minimum, -0.587641138789, accuracy: 1e-11, "最小的那个系数（=−0.5876）")
        XCTAssertGreaterThan(back.determinant, 0, "逆矩阵的行列式也必须为正")

        // Rec2020 的饱和绿在 sRGB 基色下的样子：R 是负的，量级就是那个 −0.5876。
        let saturatedGreen = back * SIMD3<Double>(0, 1, 0)
        XCTAssertLessThan(saturatedGreen.x, -0.5, "Rec2020 绿 → sRGB：R 必须落在 −0.5876 附近")
        print("2020 绿 (0,1,0) 读作 sRGB · " + format(saturatedGreen))

        // Rec2020 → P3（P3 屏的出口）同样有负系数，只是小一个量级。
        let toP3 = ColorPrimaries.conversion(from: .rec2020, to: .displayP3)
        assertMatrix(toP3, equals: [
            [1.343578252584, -0.282179670526, -0.061398582058],
            [-0.065297452789, 1.075787915849, -0.010490463059],
            [0.002821787262, -0.019598494524, 1.016776707263],
        ], accuracy: 1e-11, "Rec2020 → P3")
        XCTAssertLessThan(toP3.minimum, 0)
        print("2020→P3 · " + format(toP3))
    }

    // MARK: - 3. round trip

    /// 六种「换个基色再换回来」都是单位阵。这条同时钉住 `fromXYZ` 是 `toXYZ` 的真逆：
    /// 若 `conversion` 是手写表，任何一处抄错都会在这里放大成 1e-3 量级。
    func testEveryRoundTripIsTheIdentity() {
        for a in ColorPrimaries.allCases {
            for b in ColorPrimaries.allCases {
                let there = ColorPrimaries.conversion(from: a, to: b)
                let back = ColorPrimaries.conversion(from: b, to: a)
                let roundTrip = back * there
                XCTAssertLessThanOrEqual(roundTrip.maxAbsoluteDifference(from: .identity), 1e-12,
                                         "\(a.rawValue) → \(b.rawValue) → \(a.rawValue)")
                XCTAssertTrue(there.preservesWhitePoint(), "\(a.rawValue) → \(b.rawValue) 丢了白点")
                XCTAssertGreaterThan(there.determinant, 0, "\(a.rawValue) → \(b.rawValue) 翻转过色相")
            }
        }
        print("round trip · 6 种顺序全部 ≤ 1e-12")
    }

    // MARK: - 4. the white point

    /// 三套基色 + 六条转换矩阵，`(1,1,1)` 都必须是 `(1,1,1)`。
    ///
    /// 这是「换基色对中性内容 = 恒等」的形式化（也是 `headroom` 数值不用重算的理由，075 §5.6）：
    /// 白点一致 ⇒ 中性白在两边的码都是 1。
    func testTheWhitePointIsPreservedInEverySpace() {
        for space in ColorPrimaries.allCases {
            let mapped = space.toXYZ * SIMD3<Double>(1, 1, 1)
            XCTAssertEqual(mapped.y, 1, accuracy: 1e-12, "\(space.rawValue)：白点的 Y 必须是 1")

            // 白点的色度坐标必须回到 D65（不是 0.3127/0.3290 之外的任何东西）。
            let x = mapped.x / (mapped.x + mapped.y + mapped.z)
            let y = mapped.y / (mapped.x + mapped.y + mapped.z)
            XCTAssertEqual(x, ColorPrimaries.whitePoint.x, accuracy: 1e-9, "\(space.rawValue)：白点 x")
            XCTAssertEqual(y, ColorPrimaries.whitePoint.y, accuracy: 1e-9, "\(space.rawValue)：白点 y")

            for other in ColorPrimaries.allCases {
                let t = ColorPrimaries.conversion(from: space, to: other)
                XCTAssertTrue(t.preservesWhitePoint(), "\(space.rawValue) → \(other.rawValue) 行和不为 1")

                let white = t * SIMD3<Double>(1, 1, 1)
                XCTAssertLessThanOrEqual(maxAbs(white - SIMD3<Double>(1, 1, 1)), ColorPrimaries.whitePointTolerance,
                                         "\(space.rawValue) → \(other.rawValue)：(1,1,1) 必须映射到 (1,1,1)")
            }
        }
        // 判据本身也要被证一次：拿一个真的会破坏白点的矩阵去问，它必须说不。
        let broken = Matrix3(rows: [[1, 0, 0], [0, 1, 0], [0, 0, 1.001]])
        XCTAssertFalse(broken.preservesWhitePoint(), "判据必须能认出 1.001 这种错")
        XCTAssertTrue(broken.preservesWhitePoint(within: 1e-2), "容差是它的旋钮")

        print("white point · " + ColorPrimaries.allCases
            .map { "\($0.rawValue) " + format($0.toXYZ.rowSums) }
            .joined(separator: " · "))
    }

    // MARK: - 5. luminance weights

    /// `w·C` 与「直接用 `toXYZ` 算出的 Y」是同一个数。
    ///
    /// 用的是**推导出来的**权重（`derivedLuminanceWeights` = `toXYZ` 的 Y 行）：这一组与矩阵在
    /// 双精度下完全一致，所以能断言 1e-9。规范常数（`luminanceWeights`）与它的差就是规范自己的
    /// 小数舍入，容差单列在下一条测试里 —— 两者混着断言会逼着人放宽到 1e-4，白丢三个数量级的分辨力。
    func testWeightsAgreeWithTheMatrixRow() {
        let colours: [SIMD3<Double>] = [
            SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1),
            SIMD3(0.18, 0.18, 0.18),
            SIMD3(0.3, 0.5, 0.7),
            SIMD3(0.6921, 0.3185, 0.1706),   // 075 §5.2 的肤色橙
        ]
        for space in ColorPrimaries.allCases {
            let m = space.toXYZ
            let w = space.derivedLuminanceWeights
            XCTAssertEqual(w.x + w.y + w.z, 1, accuracy: 1e-12,
                           "\(space.rawValue)：权重和必须是 1（否则白点的亮度不是 1）")

            for c in colours {
                let fromWeights = w.x * c.x + w.y * c.y + w.z * c.z
                let fromMatrix = (m * c).y
                XCTAssertEqual(fromWeights, fromMatrix, accuracy: 1e-9,
                               "\(space.rawValue)：w·\(format(c)) 与矩阵的 Y 不一致")
            }
        }
        print("weights(derived) · " + ColorPrimaries.allCases
            .map { "\($0.rawValue) " + format($0.derivedLuminanceWeights) }
            .joined(separator: " · "))
    }

    /// 规范常数 vs 推导值：容差就是规范自己的舍入预算。
    ///
    /// sRGB/709 的 0.2126 是 BT.709-6 Table 3 把 0.21263901 **舍到四位**的结果（差 3.9e-5）；
    /// Rec2020 的 0.6780 同理（差 1.9e-6）；P3 的那三个不是规范常数而是反推值，差 ≤ 3.6e-8。
    ///
    /// 这条测试同时是批次 B 的验收前提：**sRGB 那一组必须原样等于今天 14 处硬编码的数字**
    /// （`0.2126 / 0.7152 / 0.0722`），否则批次 B 会顺手改掉今天的中性像素。
    func testTheNormativeWeightsMatchTheDerivationWithinTheirRounding() {
        XCTAssertEqual(ColorPrimaries.sRGB.luminanceWeights, SIMD3<Double>(0.2126, 0.7152, 0.0722),
                       "第 1 位是今天 14 处硬编码的那个常数，批次 B 换的是它，不是它的精度")
        XCTAssertEqual(ColorPrimaries.displayP3.luminanceWeights,
                       SIMD3<Double>(0.2289746, 0.6917385, 0.0792869))
        XCTAssertEqual(ColorPrimaries.rec2020.luminanceWeights, SIMD3<Double>(0.2627, 0.6780, 0.0593))

        // (基色, 容差, 依据)
        let budgets: [(ColorPrimaries, Double, String)] = [
            (.sRGB, 1e-4, "BT.709-6 Table 3 的四位小数舍入，实测差 3.9e-5"),
            (.displayP3, 1e-6, "反推值，实测差 3.6e-8"),
            (.rec2020, 1e-5, "BT.2020-2 的四位小数舍入，实测差 1.9e-6"),
        ]
        for (space, budget, note) in budgets {
            let declared = space.luminanceWeights
            let derived = space.derivedLuminanceWeights
            let delta = maxAbs(declared - derived)
            XCTAssertLessThanOrEqual(delta, budget, "\(space.rawValue)：\(note)")
            XCTAssertEqual(declared.x + declared.y + declared.z, 1, accuracy: 1e-12,
                           "\(space.rawValue)：规范和也必须为 1")
            print("weights · \(space.rawValue) 声明 " + format(declared)
                  + " 推导 " + format(derived)
                  + " max|Δ| = " + String(format: "%.2e", delta) + "（\(note)）")
        }
    }

    // MARK: - 6. known colours

    /// 饱和红与中性灰 —— 迁移前后同一物理色的两种写法。
    ///
    /// * 红：`(1,0,0)` 在 Rec2020 基色下是 `(0.6274, 0.0691, 0.0164)`。**这不是变暗**：三个数
    ///   描述的仍是同一个物理色，它的 Y 在两边都是 0.212639（下一条断言）。反过来说，今天那
    ///   5.42% 的负通道与这个 0.627 是同一件事 —— 饱和色在宽基色里「占的码更少」（075 §1.4）。
    /// * 灰：`(0.18,0.18,0.18)` 原地不动，而且**进 `Float16` 后逐位相同** —— 这是批次 A 最重要
    ///   的那条断言（075 §4 验收 3）：换基色对中性内容不是「近似恒等」，是同一个码。
    func testSaturatedRedAndNeutralGrey() {
        let toRec2020 = ColorPrimaries.conversion(from: .sRGB, to: .rec2020)
        let red = SIMD3<Double>(1, 0, 0)
        let converted = toRec2020 * red

        XCTAssertEqual(converted.x, 0.627403895934699, accuracy: 1e-12)
        XCTAssertEqual(converted.y, 0.069097289358232, accuracy: 1e-12)
        XCTAssertEqual(converted.z, 0.016391438875150, accuracy: 1e-12)

        // Y 是不变量：同一个物理色的亮度，在两个基色下用各自的权重读出来必须相同。
        // 用**规范常数**读时残差是 3.9e-5 —— 就是 sRGB 那三个常数被舍到四位小数的量；
        // 用推导权重读则是 1e-16（下一条测试里的原色循环断言 1e-12）。
        let ySource = ColorPrimaries.sRGB.luminance(of: red)
        let yTarget = ColorPrimaries.rec2020.luminance(of: converted)
        XCTAssertEqual(ySource, 0.2126, accuracy: 1e-12, "红的亮度按 sRGB 读")
        XCTAssertEqual(yTarget, ySource, accuracy: 5e-5,
                       "Y 必须往返不变（残差只来自两套规范常数各自的小数舍入）")
        XCTAssertEqual(ColorPrimaries.rec2020.derivedLuminanceWeights.dot(converted),
                       ColorPrimaries.sRGB.derivedLuminanceWeights.dot(red), accuracy: 1e-12,
                       "Y 是往返不变量（推导权重下是同一个数）")

        // 中性灰：数学上不动。
        let grey = SIMD3<Double>(0.18, 0.18, 0.18)
        let movedGrey = toRec2020 * grey
        XCTAssertLessThanOrEqual(maxAbs(movedGrey - grey), 1e-12, "中性灰必须原地不动")

        // 而且进 Float16 后**逐位**相同 —— 这才是批次 A 能「不重录 golden」的依据。
        XCTAssertEqual(Float16(movedGrey.x).bitPattern, Float16(0.18).bitPattern, "灰 R 的 Float16 位型")
        XCTAssertEqual(Float16(movedGrey.y).bitPattern, Float16(0.18).bitPattern, "灰 G 的 Float16 位型")
        XCTAssertEqual(Float16(movedGrey.z).bitPattern, Float16(0.18).bitPattern, "灰 B 的 Float16 位型")

        // GPU 侧会先把矩阵降成 Float32（`s4_display.metal` 的 `float3x3`）。行和在那里的残差是
        // 1e-7 量级（075 §4 实测蓝通道 0.9999994），仍然比 half-float 在 0.18 处的量化步长
        // 2.44e-4 小三个数量级 —— 所以同码不是运气。
        let halfStepAt018 = Double(Float16(0.18).nextUp) - Double(Float16(0.18))
        for r in 0..<3 {
            let floats = (0..<3).map { Float(toRec2020[r, $0]) }
            let sum = floats.reduce(0, +)
            XCTAssertLessThanOrEqual(abs(Double(sum) - 1), 1e-6, "Float32 行和 [\(r)]")
            XCTAssertLessThan(abs(Double(sum) - 1) * 0.18, halfStepAt018,
                              "Float32 行和误差必须远小于 half-float 在 0.18 处的步长")
        }
        print("red (1,0,0) → 2020 · " + format(converted)
              + "  Y " + String(format: "%.9f", ySource) + " / " + String(format: "%.9f", yTarget))
        print("grey 0.18 → 2020 · " + format(movedGrey)
              + "  Float16 bits " + String(Float16(movedGrey.x).bitPattern, radix: 16)
              + " == " + String(Float16(0.18).bitPattern, radix: 16)
              + "  half step @0.18 = " + String(format: "%.2e", halfStepAt018))
    }

    /// 三个饱和原色在 sRGB→Rec2020 下的全部九个码 —— 075 §2.2 的 HSL 色带表格用的就是这三个向量。
    /// 一起钉住，省得批次 C 再推一遍（绿在 Rec2020 基色下 hue 掉 17.4°，就是这一行造成的）。
    func testTheThreePrimariesAsSeenInRec2020() {
        let t = ColorPrimaries.conversion(from: .sRGB, to: .rec2020)
        let expected: [(SIMD3<Double>, SIMD3<Double>, String)] = [
            (SIMD3(1, 0, 0), SIMD3(0.627403896, 0.069097289, 0.016391439), "红"),
            (SIMD3(0, 1, 0), SIMD3(0.329283038, 0.919540395, 0.088013308), "绿"),
            (SIMD3(0, 0, 1), SIMD3(0.043313066, 0.011362316, 0.895595253), "蓝"),
        ]
        for (source, reference, name) in expected {
            let moved = t * source
            XCTAssertLessThanOrEqual(maxAbs(moved - reference), 1e-9, "\(name)在 Rec2020 下的码")
            // 亮度不变（用推导权重，容差 1e-12 以内）。
            XCTAssertEqual(ColorPrimaries.sRGB.derivedLuminanceWeights.dot(source),
                           ColorPrimaries.rec2020.derivedLuminanceWeights.dot(moved),
                           accuracy: 1e-12, "\(name)：Y 是往返不变量")
        }
        print("primaries as read in Rec2020 · "
              + expected.map { "\($0.2) " + format(t * $0.0) }.joined(separator: " · "))
    }

    // MARK: - 7. the counter-proof: weights without primaries

    /// **只换权重、不换基色 —— 这就是 075 §5.2 说「golden 抓不到」的那个错误。**
    ///
    /// 用 Rec2020 的权重去读 sRGB 基色的数字（即：解码仍产出 sRGB-lin，却把 14 处 `0.2126`
    /// 换成 `0.2627`），饱和红的亮度就从 0.212639 变成 0.262700：**+23.57%**。
    /// 这个量级远超任何「调色」可以接受的偏差，但它在真照片上平摊下来只有 0.00103 的平均
    /// |Δluma| —— 因为普通照片饱和度低（075 §5.2 实测），所以**任何 golden 都会绿着放它过去**。
    ///
    /// 这条断言就是那个缺口的补丁：它不需要渲染，只需要两个数字，而且偏差 ≥ 20% 是硬门槛。
    func testSwappingWeightsWithoutSwappingPrimariesIsAColourShift() {
        let sRGBWeights = ColorPrimaries.sRGB.luminanceWeights
        let rec2020Weights = ColorPrimaries.rec2020.luminanceWeights

        func relativeError(_ colour: SIMD3<Double>) -> Double {
            let truth = sRGBWeights.x * colour.x + sRGBWeights.y * colour.y + sRGBWeights.z * colour.z
            let wrong = rec2020Weights.x * colour.x + rec2020Weights.y * colour.y + rec2020Weights.z * colour.z
            return wrong / truth - 1
        }

        let redError = relativeError(SIMD3(1, 0, 0))
        let greenError = relativeError(SIMD3(0, 1, 0))
        let blueError = relativeError(SIMD3(0, 0, 1))
        let greyError = relativeError(SIMD3(0.18, 0.18, 0.18))

        XCTAssertGreaterThanOrEqual(redError, 0.20,
                                    "饱和红的亮度偏差必须 ≥ 20%（实测 +23.57%）——低于这个数说明权重没真的换")
        XCTAssertEqual(redError, 0.235654, accuracy: 1e-5, "0.2627 / 0.2126 − 1，实测 +23.5654%")
        XCTAssertEqual(greenError, -0.052013, accuracy: 1e-5, "0.6780 / 0.7152 − 1，实测 −5.2013%")
        XCTAssertEqual(blueError, -0.178670, accuracy: 1e-5, "0.0593 / 0.0722 − 1，实测 −17.8670%")
        XCTAssertEqual(greyError, 0, accuracy: 1e-12, "中性灰不受影响 —— 所以 golden 看不出来")

        // 换个说法（同一件事）：一个纯红像素被读高了 23.6%，纯蓝被读低了 17.9% —— 冷暖同时反向偏移，
        // 这不是「整体亮度变了」，是**色相/饱和度被改了**（S2 的 shadows/highlights 权重随之偏）。
        print("weights-only error · 红 \(String(format: "%+.4f", redError * 100))%"
              + " · 绿 \(String(format: "%+.4f", greenError * 100))%"
              + " · 蓝 \(String(format: "%+.4f", blueError * 100))%"
              + " · 灰 \(String(format: "%+.4f", greyError * 100))%")

        // 反向的 sanity：真的连基色一起换（sRGB→2020 后再用 Rec2020 权重读），偏差回到 0 ——
        // 推导权重下是 1e-16，规范常数下残余 1.8e-4（就是那三个常数舍到四位的传播）。
        let convertedRed = ColorPrimaries.conversion(from: .sRGB, to: .rec2020) * SIMD3<Double>(1, 0, 0)
        XCTAssertEqual(ColorPrimaries.rec2020.derivedLuminanceWeights.dot(convertedRed),
                       ColorPrimaries.sRGB.derivedLuminanceWeights.dot(SIMD3<Double>(1, 0, 0)),
                       accuracy: 1e-12, "两者都换 ⇒ Y 不变（推导权重）")
        let afterFullMove = rec2020Weights.dot(convertedRed)
        XCTAssertEqual(afterFullMove, sRGBWeights.x, accuracy: 1e-3,
                       "两者都换 ⇒ 偏差回到 0（规范常数下残余 1.8e-4，来自常数舍入）")
        print("full move · 红 " + String(format: "%+.6f", (afterFullMove / sRGBWeights.x - 1) * 100) + "%")
    }
}

// MARK: - small helpers for the tests

private extension SIMD3 where Scalar == Double {
    func dot(_ other: SIMD3<Double>) -> Double {
        x * other.x + y * other.y + z * other.z
    }
}
