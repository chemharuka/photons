import XCTest
import Metal
@testable import PhotonsCore

/// 派单 071 — 黑电平校正：S1 线性域里一个**加性**的细粒度黑电平微调。
///
/// 用户的现象是「加了曝光后黑部变得更黑」。根因不在 S2 的 clamp 本身，而在它前面的乘法：解码器
/// 交给我们的 scene-linear 有负样本（`_1274394.dng` 实测 min −0.039、33 M 个负样本），曝光是
/// **乘性**增益，负值被同比例放大，S2 末尾的 `max(v, 0)` 再把它们删掉 —— 细节不是被压暗，是被删掉。
///
/// 修法是 S1 里 ① 电平归一化之后、② 曝光增益之前加一条 `v = v + blackOffset`（±0.01，1/1000 粒度）。
/// 放在增益之前是这次的核心口径：修正量跟着同一个增益一起放大（+0.01 在 +2 EV 处抬 +0.04），
/// 正好按比例抵消负值的放大；放在增益之后是恒定抬升，高曝光抬不够、低曝光抬过头。
///
/// 这个文件钉四件事，每件都在真实代码上跑，不是复述规格：
///
///   1. **映射**：滑杆整数 −10…+10 → `n/1000` 精确，0 → 0，越界钳制，非整数位置四舍五入到一个 tick。
///   2. **恒等**：`blackOffset = 0` 的文档，`.sceneLinear` 键 material 与 main@73eca0b 逐字节相同
///      （直接对 `WindowTests`/`MaskTests` 钉的那条向量），旧文档重编码不出现 `blackOffset` 键。
///   3. **内核算术**：把 **真的** `s1_scene_linear.metal` 编译起来跑合成像素，验证方向、幅度、
///      「在增益之前」以及 letterbox / alpha 两个守卫。float32 纹理，所以量的是算术本身。
///   4. **用户现象**：真 RAW（`~/Desktop/test/L1030433.dng`）在 +2 EV 下三档 offset，报「被
///      `max(v,0)` 夹掉的像素数」与暗部（0–5 % 分位）均值，并断言单调向「细节回来」的方向走。
final class BlackLevelTests: XCTestCase {

    // MARK: - ① 映射（§2.1）

    /// 滑杆整数 → 文档值：`n/1000` **精确**，0 在中间，两端是 ±0.01。
    ///
    /// 「精确」在这里是可断言的：`n/1000` 在实数里就是 n 个千分之一，`Double(n) / 1000.0` 是正确
    /// 舍入的除法，所以它必然等于 `0.01` / `0.007` 这样的字面量本身 —— 不是「差一点点」。
    func testSliderPositionMapsToExactlyOneThousandth() {
        XCTAssertEqual(LightGroup.blackOffsetSliderRange, -10 ... 10, "滑杆行程 −10…+10（0.1 步）")
        XCTAssertEqual(LightGroup.blackOffset(fromSlider: 10), 0.01, "+10 → +0.01")
        XCTAssertEqual(LightGroup.blackOffset(fromSlider: -10), -0.01, "−10 → −0.01")
        XCTAssertEqual(LightGroup.blackOffset(fromSlider: 0), 0, "0 → 0（默认居中）")

        for n in -10 ... 10 {
            let offset = LightGroup.blackOffset(fromSlider: Double(n))
            XCTAssertEqual(offset, Double(n) / 1000, "n = \(n) 必须是 n/1000")
            // 存的是 Double，但落在 1/1000 的格子上：读回滑杆位置必须一字不差。
            var light = LightGroup.identity
            light.blackOffset = offset
            XCTAssertEqual(light.blackOffsetSliderPosition, Double(n), "\(n) → \(offset) → 回来还是 \(n)")
        }

        // 越界钳到行程两端（手改文档 / 键盘敲大数）。
        XCTAssertEqual(LightGroup.blackOffset(fromSlider: 11), 0.01)
        XCTAssertEqual(LightGroup.blackOffset(fromSlider: 400), 0.01)
        XCTAssertEqual(LightGroup.blackOffset(fromSlider: -11), -0.01)
        // 非有限值不是 ±0.01，也不是崩：它没有任何意义，落到默认的 0。
        XCTAssertEqual(LightGroup.blackOffset(fromSlider: .nan), 0)
        XCTAssertEqual(LightGroup.blackOffset(fromSlider: .infinity), 0)

        // 面板没有 `step:`（046 不许刻度线），所以量化在模型层：位置吸到 **0.1** 的格子上
        // （「取值范围是 −10 到 10，但不是只能取整数」），也就是线性域的 1/10 000。
        XCTAssertEqual(LightGroup.blackOffset(fromSlider: 2.4), 0.0024)
        XCTAssertEqual(LightGroup.blackOffset(fromSlider: 2.6), 0.0026)
        XCTAssertEqual(LightGroup.blackOffset(fromSlider: -6.6), -0.0066)
        XCTAssertEqual(LightGroup.blackOffset(fromSlider: 2.44), 0.0024, "2.44 → 最近 0.1 格 = 2.4")
        XCTAssertEqual(LightGroup.blackOffset(fromSlider: 2.46), 0.0025, "2.46 → 最近 0.1 格 = 2.5")
        XCTAssertEqual(LightGroup.blackOffset(fromSlider: -0.04), 0, "-0.04 → 最近的 0.1 格是 0")
        // 0.002 这类值必须能表达 —— 这正是模型里存 Double 而不是整数格值的原因。
        var light = LightGroup.identity
        light.blackOffset = 0.002
        XCTAssertEqual(light.blackOffset, 0.002)
        XCTAssertEqual(light.blackOffsetSliderPosition, 2, "0.002 → 2.0（0.1 格上）")

        // 信封：±0.01，内核拿到的永远是钳过的值。
        XCTAssertEqual(LightGroup.blackOffsetRange, -0.01 ... 0.01)
        light.blackOffset = 0.4
        XCTAssertEqual(light.clampedBlackOffset, 0.01, "手改文档不能把线性缓冲推出去 ±0.01")
        light.blackOffset = -9
        XCTAssertEqual(light.clampedBlackOffset, -0.01)
        light.blackOffset = 0
        XCTAssertEqual(light.clampedBlackOffset, 0, "0 的钳制结果必须还是 0（键与内核都靠这个）")
    }

    // MARK: - ② 恒等：键 material 与旧文档（§2.3 / 验收 1、5、6）

    /// 没用过这个控件的文档，`.sceneLinear` 的键 material **逐字节**是 019/030 的那一条。
    ///
    /// 直接复制 `WindowTests` / `MaskTests` 钉住的那串文字（exposure 0.75 / 5200 K / tint 12 /
    /// hlr 0.4 / whites 10 / blacks −5）：那两个套件是旧文档的证人，这里是 071 自己在同一串文字上
    /// 的对照 —— 只要多一个字节，三处断言一起红。
    func testTheSceneLinearKeyIsUnchangedForADocumentThatNeverUsedTheTrim() {
        var edit = EditModel.neutral
        edit.light.exposure = 0.75
        edit.light.temperature = 5200
        edit.light.tint = 12
        edit.light.highlightRecovery = 0.4
        edit.light.whites = 10
        edit.light.blacks = -5
        // P1f: `;alg=2` is S1's algorithm-version token (`StageAlgorithmVersion` — 073C's hybrid
        // blacks travel), appended to every stage's material. The *parameters* are still byte-identical
        // to main@73eca0b, which is what `algorithmVersion: false` asserts.
        let preBlackOffset = "ev=0.75000;temp=5200.00000;tint=12.00000;hlr=0.40000;wh=10.00000;bl=-5.00000"
        XCTAssertEqual(edit.keyMaterial(.sceneLinear, algorithmVersion: false), preBlackOffset,
                       "blackOffset = 0 时参数部分必须与 main@73eca0b 逐字节相同")
        XCTAssertEqual(edit.keyMaterial(.sceneLinear), preBlackOffset + ";alg=2",
                       "唯一的差别是算法版本号")

        // 非零才追加，而且追加的是**内核真正加的那个数**（clamped）。
        edit.light.blackOffset = 0.007
        XCTAssertEqual(edit.keyMaterial(.sceneLinear), preBlackOffset + ";boff=0.00700;alg=2")
        edit.light.blackOffset = -0.01
        XCTAssertEqual(edit.keyMaterial(.sceneLinear), preBlackOffset + ";boff=-0.01000;alg=2")
        edit.light.blackOffset = 0.4                      // 越界：键与内核都说 +0.01
        XCTAssertEqual(edit.keyMaterial(.sceneLinear), preBlackOffset + ";boff=0.01000;alg=2")
        edit.light.blackOffset = 0
        XCTAssertEqual(edit.keyMaterial(.sceneLinear), preBlackOffset + ";alg=2",
                       "清零之后键必须回到原样")

        // 只差这一个参数的两份文档，键必须不同 —— 否则缓存会串。
        var one = EditModel.neutral
        var two = EditModel.neutral
        one.light.blackOffset = 0.001
        two.light.blackOffset = 0.002
        XCTAssertNotEqual(one.keyMaterial(.sceneLinear), two.keyMaterial(.sceneLinear))
    }

    /// 脏标记：它改的是 S1 的线性缓冲本身，所以只脏 `.sceneLinear`，不许顺手把 S2 也拖下水。
    func testTheTrimDirtiesOnlyTheSceneLinearStage() {
        var a = EditModel.neutral
        var b = a
        b.light.blackOffset = 0.003
        XCTAssertEqual(b.changedStages(from: a), [.sceneLinear])
        a.light.blackOffset = 0.003
        XCTAssertEqual(b.changedStages(from: a), [], "同一份文档没有阶段要重画")
        b.light.blackOffset = 0
        XCTAssertEqual(b.changedStages(from: a), [.sceneLinear], "清零也是一次线性域改动")
    }

    /// 旧文档：一段**不含** `blackOffset` 的 JSON 读成 0，重编码逐字节等于原文；`schemaVersion`
    /// 读到文件自己写的 4（不是 5 —— 版本号是文档的，不是代码的），新文档才是 5。
    ///
    /// 「旧 blob」按它真实的形状造：`EditModel.write(to:)` 就是 `prettyPrinted + sortedKeys`，所以
    /// 一份 pre-071 的文档**正好**是同一个编码器对同一份模型的输出，只是没有那个键、版本号是 4。
    /// 手工敲一段只有两个键的 JSON 不行 —— 编码器会补齐每一个组，那样的「原文」从来不存在。
    func testAPreBlackOffsetDocumentReadsAsZeroAndReEncodesByteForByte() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var legacyModel = EditModel.neutral
        legacyModel.schemaVersion = 4
        legacyModel.light.exposure = 0.5
        legacyModel.light.blacks = -12
        legacyModel.light.whiteLevel = 2
        let legacy = String(decoding: try encoder.encode(legacyModel), as: UTF8.self)
        XCTAssertFalse(legacy.contains("blackOffset"), "旧 blob 里本来就没有这个键")

        let model = try JSONDecoder().decode(EditModel.self, from: Data(legacy.utf8))
        XCTAssertEqual(model.light.blackOffset, 0, "缺键 = 0，不是别的默认值")
        XCTAssertEqual(model.schemaVersion, 4, "旧文档读入不报错，版本号是它自己写的那个")
        XCTAssertEqual(model.light.exposure, 0.5)
        XCTAssertEqual(model.light.blacks, -12)
        XCTAssertEqual(model, legacyModel, "读进来的就是写出去的那份文档")

        let reencoded = try encoder.encode(model)
        XCTAssertEqual(String(decoding: reencoded, as: UTF8.self), legacy,
                       "重编码必须逐字节等于原文（0 不写键）")

        // 仓库里的老 fixture（M1 的手写最小文档）也不许长出这个键。
        let fixture = Self.repoRoot.appendingPathComponent("Tests/Fixtures/edit-neutral.json")
        let old = try EditModel.load(from: fixture)
        XCTAssertEqual(old.light.blackOffset, 0)
        XCTAssertFalse(String(decoding: try encoder.encode(old), as: UTF8.self).contains("blackOffset"))

        // 新文档：schemaVersion 9（2026-10-28 加了 纹理/清晰度/去雾），而且**仍然**不写
        // blackOffset 这个键。
        XCTAssertEqual(EditModel.currentSchemaVersion, 9)
        XCTAssertEqual(EditModel.neutral.schemaVersion, 9)
        let fresh = String(decoding: try encoder.encode(EditModel.neutral), as: UTF8.self)
        XCTAssertTrue(fresh.contains("\"schemaVersion\" : 9"), "新文档是版本 9")
        XCTAssertFalse(fresh.contains("blackOffset"), "0 不写键 —— 旧 blob 的逐字节稳定靠这条")
        // 2026-10-28: 黑白 的两个新键同样在默认值上缺席，所以 schema-7 的 blob 也能逐字节重编码。
        XCTAssertFalse(fresh.contains("blackAndWhite"))
        XCTAssertFalse(fresh.contains("\"mix\""))
        // 2026-10-28 (P0-6): and the three S3.8 numbers are absent at 0 too, so a schema-8 blob also
        // re-encodes byte for byte.
        XCTAssertFalse(fresh.contains("\"texture\""))
        XCTAssertFalse(fresh.contains("\"clarity\""))
        XCTAssertFalse(fresh.contains("\"dehaze\""))

        // 用过控件的文档才写键，而且读回来还是同一个数。
        var used = EditModel.neutral
        used.light.blackOffset = -0.007
        let usedJSON = try encoder.encode(used)
        XCTAssertTrue(String(decoding: usedJSON, as: UTF8.self).contains("\"blackOffset\" : -0.007"))
        XCTAssertEqual(try JSONDecoder().decode(EditModel.self, from: usedJSON).light.blackOffset, -0.007)
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    // MARK: - ③ 内核算术：方向、幅度、在增益之前（§2.2 / 验收 3）

    /// 合成像素 `−0.02 / 0 / 0.5`，`blackOffset = +0.01`、曝光 0：
    ///
    ///     −0.02 → −0.01     0 → +0.01      0.5 → 0.51
    ///
    /// 曝光 +1 EV（gain = 2）时前两项**再 ×2**：`−0.02 → −0.04+0.02 = −0.02`、`0 → +0.02` —— 这就是
    /// 「在增益之前」的取证。如果 offset 落在增益之后，`−0.02` 会是 `−0.02 − 0.02 + 0.01 = −0.03`，
    /// 不是 0 EV 的两倍。
    func testTheOffsetIsAddedBeforeTheGain() throws {
        let harness = try KernelHarness()
        let values: [Float] = [-0.02, 0, 0.5]

        let base = try harness.run(rgb: values.map { [$0, $0, $0] }, gain: 1, offset: 0.01)
        XCTAssertEqual(Double(base[0]), -0.01, accuracy: 1e-6, "−0.02 + 0.01 = −0.01")
        XCTAssertEqual(Double(base[1]), 0.01, accuracy: 1e-6, "0 + 0.01 = +0.01")
        XCTAssertEqual(Double(base[2]), 0.51, accuracy: 1e-6, "0.5 + 0.01 = 0.51")

        let pushed = try harness.run(rgb: values.map { [$0, $0, $0] }, gain: 2, offset: 0.01)
        XCTAssertEqual(Double(pushed[0]), -0.02, accuracy: 1e-6, "(−0.02 + 0.01)·2")
        XCTAssertEqual(Double(pushed[1]), 0.02, accuracy: 1e-6, "(0 + 0.01)·2")
        XCTAssertEqual(Double(pushed[2]), 1.02, accuracy: 1e-6, "(0.5 + 0.01)·2")
        // 「再 ×2」逐项成立，而不只是碰巧落在同一侧。
        for i in 0 ..< values.count {
            XCTAssertEqual(Double(pushed[i]), Double(base[i]) * 2, accuracy: 1e-6,
                           "第 \(i) 项在 +1 EV 下必须是 0 EV 的两倍")
        }

        // 负的方向：−0.01 压黑，0 → −0.01，−0.02 → −0.03。
        let down = try harness.run(rgb: values.map { [$0, $0, $0] }, gain: 1, offset: -0.01)
        XCTAssertEqual(Double(down[0]), -0.03, accuracy: 1e-6)
        XCTAssertEqual(Double(down[1]), -0.01, accuracy: 1e-6)
        XCTAssertEqual(Double(down[2]), 0.49, accuracy: 1e-6)
    }

    /// `blackOffset = 0` 时内核**逐位**是今天的样子：不是「加了 0.0」，是同一串运算。
    ///
    /// 这里比的是 bit pattern：`v = (v − 0)/max(1 − 0, 1e−3)` 与 `v *= 1` 都是精确运算，所以任何一个
    /// 被误改成「无条件 `+ offset`」的写法都会立刻在 `−0.02`、`0` 这些值上露出来。
    func testAZeroOffsetLeavesEveryPixelBitIdentical() throws {
        let harness = try KernelHarness()
        let values: [Float] = [-0.02, -0.0001, 0, 0.001, 0.5, 1.7]
        let rgb = values.map { [$0, $0, $0] }

        let zero = try harness.run(rgb: rgb, gain: 1, offset: 0)
        for (i, v) in values.enumerated() {
            XCTAssertEqual(zero[i].bitPattern, v.bitPattern, "第 \(i) 个像素被改了：\(zero[i]) vs \(v)")
        }
        // 增益路径也一样：0 offset 下 gain 就是纯乘法（4 是 2 的幂，所以 float32 里仍然精确）。
        let twoStops = try harness.run(rgb: rgb, gain: 4, offset: 0)
        for (i, v) in values.enumerated() {
            XCTAssertEqual(twoStops[i].bitPattern, (v * 4).bitPattern, "gain 4 下第 \(i) 个像素不是 4v")
        }
    }

    /// letterbox 两个守卫：`blackOffset ≠ 0` 时也不许把画布外的 0 抬成灰。
    ///
    /// content rect 之外、以及 alpha = 0 的像素，必须是**精确写通**（原样交回），而不是「抬起来再
    /// 夹一下」。这条在 019 已经为电平钉过，071 的加性偏移同样会抬 0，所以要再钉。
    func testTheLetterboxAndTheAlphaGuardStayExactWithANonZeroOffset() throws {
        let harness = try KernelHarness()
        // 5×1：x = 0 / 4 在 content rect 外（都是 0），x = 2 的 alpha 是 0，x = 1 / 3 是照片。
        let source: [[Float]] = [
            [0, 0, 0, 1],
            [0.2, 0.2, 0.2, 1],
            [0.3, 0.3, 0.3, 0],
            [0.25, 0.25, 0.25, 1],
            [0, 0, 0, 1],
        ]
        let out = try harness.run(source: source, gain: 1, offset: 0.01, content: (x: 1, width: 3))

        XCTAssertEqual(out[0], [0, 0, 0, 1], "content rect 外的 0 必须原样写回，不能变成 0.01")
        XCTAssertEqual(out[4], [0, 0, 0, 1], "右边那条也一样")
        XCTAssertEqual(out[2], [0.3, 0.3, 0.3, 0], "alpha = 0 是「这里没有照片」，一个字段都不许动")
        XCTAssertEqual(Double(out[1][0]), 0.21, accuracy: 1e-6, "照片像素才吃到偏移")
        XCTAssertEqual(Double(out[3][0]), 0.26, accuracy: 1e-6)
    }

    // MARK: - ④ 用户现象：真 RAW 在 +2 EV 下（验收 4）

    /// 「加曝光后暗部更黑」的定量版本。
    ///
    /// 同一张 `L1030433.dng`（1/8 解码），+2 EV（gain = 4），`blackOffset` 三档 0 / +0.005 / +0.01：
    /// 数**被 `max(v, 0)` 夹掉的像素**（三通道全 ≤ 0 的像素，也就是 S2 的 clamp 会把它们变成纯黑）
    /// 与**暗部 0–5 % 分位的均值**（S1 输出的线性亮度）。细节回来的方向 = 夹断像素变少、暗部均值
    /// 上升，两条都必须单调。
    func testOnARealRawTheTrimPullsShadowDetailBackOutOfTheClamp() throws {
        guard let url = Self.rawFixture else { throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW") }
        let harness = try KernelHarness()
        let decoded = try RAWDecoder().decode(url, options: DecodeOptions(decoderVersion: nil, scale: 0.125))
        let pixels = Self.float32Pixels(decoded)

        var rows: [(offset: Double, clipped: Int, negative: Int, shadow: Double, lowest: Double)] = []
        for offset in [0.0, 0.005, 0.01] {
            let out = try harness.run(frame: pixels, width: decoded.width, height: decoded.height,
                                      gain: 4, offset: Float(offset))          // +2 EV
            var clipped = 0, negative = 0
            var luma: [Double] = []
            luma.reserveCapacity(decoded.width * decoded.height)
            var lowest = Double.infinity
            for i in stride(from: 0, to: out.count, by: 4) {
                let r = Double(out[i]), g = Double(out[i + 1]), b = Double(out[i + 2])
                if r <= 0 && g <= 0 && b <= 0 { clipped += 1 }
                if r < 0 { negative += 1 }
                if g < 0 { negative += 1 }
                if b < 0 { negative += 1 }
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                luma.append(l)
                lowest = min(lowest, l)
            }
            luma.sort()
            let fivePercent = max(1, luma.count * 5 / 100)
            let shadow = luma.prefix(fivePercent).reduce(0, +) / Double(fivePercent)
            rows.append((offset, clipped, negative, shadow, lowest))
            print(String(format: "071 raw %d×%d @ +2 EV · offset %+.3f · 夹断像素 %d/%d (%.2f %%) "
                         + "· 负样本 %d · 暗部 0–5%% 均值 %.6f · min %.6f",
                         decoded.width, decoded.height, offset, clipped, luma.count,
                         Double(clipped) / Double(luma.count) * 100, negative, shadow, lowest))
        }

        XCTAssertGreaterThan(rows[0].clipped, 0,
                             "这条测试只有在 +2 EV 真的把像素夹掉时才有意义，否则它是空的")
        XCTAssertLessThan(rows[1].clipped, rows[0].clipped,
                          "+0.005 必须比 0 少夹一些像素：\(rows.map(\.clipped))")
        XCTAssertLessThan(rows[2].clipped, rows[1].clipped,
                          "+0.01 必须比 +0.005 再少一些：\(rows.map(\.clipped))")
        XCTAssertLessThan(rows[1].negative, rows[0].negative, "负样本也要变少：\(rows.map(\.negative))")
        XCTAssertLessThan(rows[2].negative, rows[1].negative, "负样本也要变少：\(rows.map(\.negative))")
        XCTAssertGreaterThan(rows[1].shadow, rows[0].shadow, "暗部均值必须往上走：\(rows.map(\.shadow))")
        XCTAssertGreaterThan(rows[2].shadow, rows[1].shadow, "暗部均值必须往上走：\(rows.map(\.shadow))")
    }

    // MARK: - fixtures

    private static var rawFixture: URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private static func float32Pixels(_ image: LinearImage) -> [Float] {
        var out = [Float](repeating: 0, count: image.width * image.height * 4)
        for i in 0 ..< out.count { out[i] = Float(image.rgba[i]) }
        return out
    }

    // MARK: - the harness: the shipped kernel, compiled here

    /// 把**真的** `s1_scene_linear.metal`（仓库里那一份，不是复制品）在测试进程里编译，喂像素，读回
    /// scene-linear 输出。
    ///
    /// 为什么不是「渲染一整帧再看 display」：display 是 0…1 且负值已经被 S4 夹成 0，`−0.02 → −0.01`
    /// 这种断言在那里根本不存在。这一层是 S1 自己的算术，唯一能看见它的地方就是它的输出。
    ///
    /// 纹理用 **float32**（产品管线是 float16）：这里量的是算术，不是半浮点的量化。参数结构体是本
    /// 文件的镜像 —— Metal 与 Swift 的结构体没有共享声明，镜像逐字段对齐（80 B），一段不齐就会在
    /// 数值上立刻露出来。
    private struct KernelHarness {
        static let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root

        /// Mirror of `S1Params` in `s1_scene_linear.metal`, field for field.
        struct Params {
            var a: SIMD4<Float>   // gain, wbR, wbG, wbB
            var b: SIMD4<Float>   // recovery, identity, blacks, whites
            var c: SIMD4<Float>   // contentOrigin.xy, contentSize.xy
            var d: SIMD4<Float>   // blackLevel, whiteLevel, hasBlack, hasWhite
            var e: SIMD4<Float>   // 071: blackOffset, pad, pad, pad
        }

        let device: MTLDevice
        let defaultPipeline: MTLComputePipelineState
        let trimPipeline: MTLComputePipelineState
        let queue: MTLCommandQueue

        init() throws {
            guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
            self.device = device
            let url = Self.repoRoot
                .appendingPathComponent("Sources/PhotonsCore/Kernels/s1_scene_linear.metal")
            // 079 §2.1.2: the end points live in `tone_shape.metal` now; inline it like the app does.
            let source = try KernelLibrary.expandingLocalIncludes(of: url)
            let library = try device.makeLibrary(source: source, options: nil)
            // 071 有**两个**入口：默认的 `s1_scene_linear`（019 的算术）和 `s1_scene_linear_trim`。
            // 生产路径按 `blackOffset != 0` 选，这个 harness 照抄同一条规则 —— 否则「offset 生效了
            // 吗」会被问成空问题（拿默认入口跑 offset，输出当然不变）。
            self.defaultPipeline = try Self.pipeline(library, device: device, "s1_scene_linear")
            self.trimPipeline = try Self.pipeline(library, device: device, "s1_scene_linear_trim")
            guard let queue = device.makeCommandQueue() else { throw XCTSkip("no command queue") }
            self.queue = queue
            XCTAssertEqual(MemoryLayout<Params>.stride, 80, "S1Params 的镜像必须与 Metal 侧同宽")
        }

        private static func pipeline(_ library: MTLLibrary, device: MTLDevice,
                                     _ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw XCTSkip("\(name) is not in the shipped source")
            }
            return try device.makeComputePipelineState(function: function)
        }

        /// 一条直线的合成图（每项 `[r, g, b]`，alpha 1）。返回每个像素的**红通道**（三通道同值）。
        func run(rgb: [[Float]], gain: Float, offset: Float) throws -> [Float] {
            var source = [Float]()
            for p in rgb { source += [p[0], p[1], p[2], 1] }
            let pixels = try execute(source: source, width: rgb.count, height: 1,
                                     gain: gain, offset: offset, content: nil)
            return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
        }

        /// 一条直线的完整 RGBA（letterbox / alpha 守卫要看四个字段）。
        func run(source: [[Float]], gain: Float, offset: Float,
                 content: (x: Int, width: Int)?) throws -> [[Float]] {
            var flat = [Float]()
            for p in source { flat += p }
            let pixels = try execute(source: flat, width: source.count, height: 1,
                                     gain: gain, offset: offset, content: content)
            var out: [[Float]] = []
            for i in 0 ..< source.count {
                out.append(Array(pixels[(i * 4) ..< (i * 4 + 4)]))
            }
            return out
        }

        func run(frame: [Float], width: Int, height: Int, gain: Float, offset: Float) throws -> [Float] {
            try execute(source: frame, width: width, height: height,
                        gain: gain, offset: offset, content: nil)
        }

        private func execute(source: [Float], width: Int, height: Int,
                             gain: Float, offset: Float,
                             content: (x: Int, width: Int)?) throws -> [Float] {
            let src = try texture(width: width, height: height)
            source.withUnsafeBytes { buf in
                src.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: buf.baseAddress!, bytesPerRow: width * 16)
            }
            let dst = try texture(width: width, height: height)

            // ① 电平不动（blk = 0, wht = 1），①b offset，② 增益。identity 标志是 0，否则内核会
            // 直接拷贝 —— 那会把「offset 生效了吗」这个问题问成空的。
            var params = Params(
                a: SIMD4(gain, 1, 1, 1),
                b: SIMD4(0, 0, 0, 0),
                c: SIMD4(Float(content?.x ?? 0), 0,
                         Float(content?.width ?? width), Float(height)),
                d: SIMD4(0, 0, 0, 0),
                e: SIMD4(offset, 0, 0, 0))

            guard let cb = queue.makeCommandBuffer(),
                  let enc = cb.makeComputeCommandEncoder() else { throw XCTSkip("no command buffer") }
            // Same rule as production: a non-zero offset means the `_trim` entry point.
            let pipeline = offset == 0 ? defaultPipeline : trimPipeline
            enc.setComputePipelineState(pipeline)
            enc.setTexture(src, index: 0)
            enc.setTexture(dst, index: 1)
            enc.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            let threads = MTLSize(width: width, height: height, depth: 1)
            let group = MTLSize(width: min(pipeline.maxTotalThreadsPerThreadgroup, 32), height: 1, depth: 1)
            enc.dispatchThreads(threads, threadsPerThreadgroup: group)
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            XCTAssertEqual(cb.status, .completed, "the S1 dispatch did not complete")

            var out = [Float](repeating: 0, count: width * height * 4)
            out.withUnsafeMutableBytes { buf in
                dst.getBytes(buf.baseAddress!, bytesPerRow: width * 16,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            return out
        }

        private func texture(width: Int, height: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                                                             width: width, height: height,
                                                             mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d) else { throw XCTSkip("no texture") }
            return t
        }
    }
}
