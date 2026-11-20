import XCTest
import Metal
@testable import PhotonsCore

/// 派单 441 — 自动 Light 的中间调按「主体」（去掉最亮 5 %）判，不按整帧 p50。
///
/// 这个文件只放 441 自己的验收：A①（合成网格：天空亮 / 主体暗 ⇒ 新实现提，旧实现不提）、
/// A③（整帧护栏）、A④（真库标定分布）、A⑤（真图 before/after 表）、⑧a–⑧c（三道反向门）。
/// 422/426d 的老断言仍在 `AutoLightTests.swift`，没有删弱。
final class AutoLightSubject441Tests: XCTestCase {

    /// XCTest 在重定向 stdout 时会吞掉 `print`；标定表同时写一份到 `/tmp/auto441.log`。
    private func emit(_ line: String) {
        print(line)
        let url = URL(fileURLWithPath: "/tmp/auto441.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write((line + "\n").data(using: .utf8)!)
            try? h.close()
        }
    }

    // MARK: - 合成网格

    /// 上半 `bright`、下半 `dark` 的网格。测试用它复现「大片天空 + 暗主体」。
    private func splitGrid(bright: Float, dark: Float, width: Int = 40, height: Int = 40) -> AutoLight.Sample {
        var luma = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                luma[y * width + x] = y < height / 2 ? bright : dark
            }
        }
        return AutoLight.Sample(width: width, height: height, luma: luma)
    }

    /// 把文档当增益 + 中间调/阴影的替身：中间调把主体（下半）按 0.9 × 单位/100 提亮，
    /// 阴影只动最暗的一小部分；曝光是纯增益。足够验证「判据/护栏」这一层。
    /// **A① 的 plan 级网格：一片亮天空 + 一块主体 + 一条比主体更暗的前景。**
    ///
    /// 分段：最暗的 48.5 %（主体，0.01）、41.5 %（桌面/墙，0.2）、10 %（天空，1.0）。
    /// 曝光把 p95（天空）放到 1.1 之后，整帧 **p50 = 0.214**（主体之上的 41.5 %），而
    /// **subjectP50 = 0.011**（第 47.5 百分位仍落在最暗的一档）。于是同一张图同时满足：
    /// - 旧地板 `p50 ≥ 0.04` ⇒ 不提；
    /// - 新地板 `subjectP50 < subjectTarget` ⇒ 要提；
    /// - 整帧 p50 在 `wholeCeiling` 以下 ⇒ 护栏放行；
    /// - ⑧a 把 subjectP50 换回 p50（0.214 ≥ target）⇒ 不提，A① 红。
    ///
    /// 规格原文的 0.9 / 0.02 是 50/50：曝光后整帧 p50 = p95 = 1.1 > `wholeCeiling`，必然被 A③
    /// 的护栏拦下，所以「量的那一半」用 0.9 / 0.02 原样（`testSubjectMetricCutsTheBrightHalf…`），
    /// plan 这一半用上面的分段网格。两条验收因此不互相矛盾。
    private struct Model {
        var sky: Float = 1.0
        var body: Float = 0.28
        var dark: Float = 0.01
        var darkFraction: Double = 0.485
        var bodyFraction: Double = 0.415
        var midGainPer100: Double = 21.0
        var shadowGainPer100: Double = 0.0

        func sample(for edit: EditModel) -> AutoLight.Sample {
            let gain = pow(2.0, edit.light.exposure)
            let mid = 1 + edit.light.midtones / 100 * midGainPer100
            let shadow = 1 + edit.light.shadows / 100 * shadowGainPer100
            let skyLevel = Double(sky) * gain
            let bodyLevel = Double(body) * gain
            let darkLevel = Double(dark) * gain * mid * shadow
            let w = 40, h = 200
            let darkRows = Int((Double(h) * darkFraction).rounded())
            let bodyRows = darkRows + Int((Double(h) * bodyFraction).rounded())
            var luma = [Float](repeating: 0, count: w * h)
            // h = 200 是刻意的：47.5 %（subjectP50 的秩）与 50 %（p50）之间只有 2.5 个百分点的
            // 窗口，40 行只有 2.5 % 的粒度，会让两个分位落到同一档。
            for y in 0 ..< h {
                let level: Float = y < darkRows ? Float(darkLevel)
                    : (y < bodyRows ? Float(bodyLevel) : Float(skyLevel))
                for x in 0 ..< w { luma[y * w + x] = level }
            }
            return AutoLight.Sample(width: w, height: h, luma: luma)
        }
    }

    // MARK: - A① 主体地板生效

    /// 主体统计本身：上半 0.9、下半 0.02 的网格，整帧 p50=0.9，而主体中位数=0.02。
    ///
    /// 这条是 A① 的「量」那一半（规格里的 0.9/0.02 原样）。注意它不跑 plan：0.9 已经高于标定出来的
    /// `wholeCeiling`，会先撞 A③ 的护栏；A① 的「提」那一半用 `wholeCeiling` 以下的亮部。
    func testSubjectMetricCutsTheBrightHalfEvenAtPointNine() {
        let sample = splitGrid(bright: 0.9, dark: 0.02)
        let m = sample.metrics()
        print(String(format: "441 SUBJECT METRIC · whole p50 %.4f · subject p50 %.4f over %d/%d samples",
                     m.p50, m.subjectP50, m.subjectCount, m.sampleCount))
        XCTAssertGreaterThanOrEqual(m.p50, AutoLight.midtoneTarget, "旧地板看整帧，这张图它不提")
        XCTAssertEqual(m.subjectP50, 0.02, accuracy: 1e-6,
                       "砍掉最亮 5 % 后，主体应该是暗的那一半")
        XCTAssertLessThan(m.subjectCount, m.sampleCount, "主体样本必须真的少掉尾部")

        // ⑧a 的量那一半：换回整帧后 subjectP50 就是 p50。
        let folded = sample.metrics(subjectCut: false)
        XCTAssertEqual(folded.subjectP50, folded.p50, accuracy: 1e-9)
        XCTAssertEqual(folded.subjectCount, folded.sampleCount)
    }

    /// §6.4 — `darkFrac` / `brightFrac` / `highlightBlocks` / `darkTexture` / `brightTexture`
    /// 必须来自同一张网格、单位写死在注释里，并且分类器能直接用它们判出 B。
    ///
    /// 64×64 网格：左上 32×32 是 0.9（4 个 32×32 块里的 1 个），其余 0.001。
    /// ⇒ `highlightBlocks = 1/4`、`darkFrac = 75 %`、`brightFrac = 25 %`，
    /// 亮暗边界上两种 texture 都 > 0。
    func testStructuralMetrics441() {
        let w = 64, h = 64
        var luma = [Float](repeating: 0.001, count: w * h)
        for y in 0 ..< 32 { for x in 0 ..< 32 { luma[y * w + x] = 0.9 } }
        // 右下 32×32 做 0.001/0.02 的棋盘，保证暗部也有可量的局部梯度（仍然 < darkCut）。
        for y in 32 ..< 64 { for x in 32 ..< 64 { luma[y * w + x] = (x + y) % 2 == 0 ? 0.001 : 0.02 } }
        let m = AutoLight.Sample(width: w, height: h, luma: luma).metrics()
        XCTAssertEqual(m.highlightBlocks, 0.25, accuracy: 1e-9, "§6.4：32×32 块均值 > 0.85 的占比")
        XCTAssertEqual(m.darkFrac, 0.75, accuracy: 1e-9, "§6.1：luma < darkCut 的面积")
        XCTAssertEqual(m.brightFrac, 0.25, accuracy: 1e-9, "§6.1：luma > brightCut 的面积")
        XCTAssertGreaterThan(m.darkTexture, 0, "§6.4：暗部局部梯度必须可量")
        XCTAssertGreaterThan(m.brightTexture, 0, "§6.4：亮部局部梯度必须可量")
        XCTAssertGreaterThan(m.subjectBrightFrac, 0.05, "§6.1：主体里确实有亮部")
        XCTAssertEqual(AutoLight.classify(base: m, afterExposure: m), .darkBright,
                       "§6.1：这组量必须让分类器判成 B")
        emit(String(format: "441 STRUCT · blocks %.2f dark %.2f bright %.2f · darkT %.2f brightT %.2f · subjectBright %.2f · class %@",
                     m.highlightBlocks, m.darkFrac, m.brightFrac, m.darkTexture, m.brightTexture,
                     m.subjectBrightFrac, AutoLight.classify(base: m, afterExposure: m).rawValue))
    }

    /// A①：整帧 p50 已经在 0.04 以上（旧实现完全不提），但主体在 `subjectTarget` 以下，
    /// 新实现必须提中间调，并且提完主体回到 `subjectTarget`（±5 %）。
    func testA1SubjectFloorLiftsEvenWhenWholeFrameIsAlreadyBright() throws {
        let model = Model()
        let base = model.sample(for: EditModel.neutral)
        let before = base.metrics()
        XCTAssertGreaterThanOrEqual(before.p50, AutoLight.midtoneTarget,
                                    "A①：这张网格的整帧 p50 必须在旧地板以上，旧实现才「不提」")
        XCTAssertLessThan(before.subjectP50, AutoLight.subjectTarget,
                          "A①：主体必须在主体地板以下，新实现才有活干")

        let plan = try AutoLight.plan(for: EditModel.neutral) { model.sample(for: $0) }
        let after = model.sample(for: plan.apply(to: EditModel.neutral)).metrics()
        let target = plan.report.subjectTarget
        print(String(format: "441 A① · class %@ · whole p50 %.4f → %.4f · subject %.4f → %.4f (target %.4f) · 中间调 %.0f 阴影 %.0f",
                     plan.report.frameClass.rawValue, before.p50, after.p50,
                     before.subjectP50, after.subjectP50, target, plan.midtones, plan.shadows))

        XCTAssertEqual(plan.report.frameClass, .highKey, "A①：这张网格是 A 类（10 % 天空在曝光后过白）")
        XCTAssertGreaterThan(plan.midtones, 0, "A①：主体不足 ⇒ 中间调必须 > 0")
        XCTAssertEqual(after.subjectP50, target, accuracy: target * 0.05,
                       "A①：提完主体应落在本类 subjectTarget ±5 %")
    }

    /// ⑧a：把主体样本换回整帧 ⇒ A① 的那条断言必须红。
    func testGate8aFoldingSubjectBackIntoWholeFrameKillsA1() throws {
        var gates = AutoLight.Gates()
        gates.ignoresSubjectCut = true
        let model = Model()
        let plan = try AutoLight.plan(for: EditModel.neutral, gates: gates) { model.sample(for: $0) }
        print("441 GATE ⑧a · 整帧判据 ⇒ 中间调 \(plan.midtones)（A① 要求 > 0）")
        XCTAssertEqual(plan.midtones, 0,
                       "⑧a：subjectP50 := p50 之后，整帧 0.9 ≥ 地板 ⇒ 不该提中间调")
    }

    // MARK: - A③ 整帧护栏

    /// **A③ 第一档（§5.2 规格原文）：提亮前 `wholeP50` 就已经 ≥ `wholeCeiling` ⇒ 中间调增量 0。**
    ///
    /// 网格：50 % 亮天空 0.9 + 50 % 暗主体 0.02。曝光把亮部推到 SDR 白附近（p95 → 1.1），
    /// 整帧 p50 就落在亮部上：`wholeP50 ≈ 1.1 ≥ wholeCeiling`，而主体中位仍是 0.02。
    /// 这正是「大片天空」——441 要区分的是「主体暗」，但整帧已经够亮，所以护栏必须拒绝这次提亮。
    func testA3aAlreadyBrightFrameGetsNoMidtoneLift() throws {
        let w = 40, h = 40, n = w * h
        let half = n / 2
        var luma = [Float](repeating: 0, count: n)
        for i in 0 ..< n { luma[i] = i < half ? 0.02 : 0.9 }
        let base = AutoLight.Sample(width: w, height: h, luma: luma)

        func measure(_ edit: EditModel) -> AutoLight.Sample {
            let gain = pow(2.0, edit.light.exposure)
            let mid = 1 + edit.light.midtones / 100 * 5.3
            let body = Float(0.02 * gain * mid)
            let bright = Float(0.9 * gain)
            var out = [Float](repeating: 0, count: n)
            for i in 0 ..< n { out[i] = i < half ? body : bright }
            return AutoLight.Sample(width: w, height: h, luma: out)
        }

        var standard = AutoLight.Gates()
        standard.forcesStandardClass = true
        let plan = try AutoLight.plan(for: EditModel.neutral, gates: standard, lossAtDepth: { _ in 0 }) { measure($0) }
        let ceiling = plan.report.wholeCeiling
        let target = plan.report.subjectTarget
        var exposed = EditModel.neutral
        exposed.light.exposure = plan.exposure
        let afterExposure = measure(exposed).metrics()
        let after = measure(plan.apply(to: EditModel.neutral)).metrics()
        emit(String(format: "441 A③a · class %@ · whole before %.4f (ceiling %.4f) → after %.4f · subject before %.4f → after %.4f · 中间调 %.0f",
                    plan.report.frameClass.rawValue, afterExposure.p50, ceiling, after.p50,
                    afterExposure.subjectP50, after.subjectP50, plan.midtones))
        XCTAssertGreaterThanOrEqual(afterExposure.p50, ceiling, "A③a：提亮前整帧就已经 ≥ 本类 wholeCeiling")
        XCTAssertLessThan(afterExposure.subjectP50, target, "A③a：主体必须不足，护栏才有东西可拦")
        XCTAssertEqual(plan.midtones, 0, "A③a：整帧已经够亮 ⇒ 中间调增量必须为 0")
        XCTAssertLessThanOrEqual(after.p50, afterExposure.p50 + 1e-6,
                                 "A③a：这次提亮不得把整帧再往上推")

        // ⑧b：去掉护栏 ⇒ 同一张图必须被提亮（A③a 的 midtones = 0 变红）。
        var gates = AutoLight.Gates()
        gates.ignoresWholeCeiling = true
        gates.forcesStandardClass = true
        let gated = try AutoLight.plan(for: EditModel.neutral, gates: gates, lossAtDepth: { _ in 0 }) { measure($0) }
        emit("441 GATE ⑧b · 去掉护栏 ⇒ 中间调 \(gated.midtones)（A③a 要求 0）")
        XCTAssertGreaterThan(gated.midtones, 0, "⑧b：没有护栏时 A③a 的中间调会被提起来")
    }

    /// **A③ 第二档：提亮前在 `wholeCeiling` 以下、提亮本身把整帧推过线 ⇒ 减半仍越线则回退。**
    ///
    /// 网格：55 % 主体 0.03 + 45 % 亮部 0.4。曝光后整帧 p50 ≈ 0.08 < ceiling，主体不足；
    /// 中间调的替身故意过冲（+100 把主体提到 100×），提到主体地板就会把整帧推到 ceiling 以上。
    func testA3bLiftThatPushesWholeFrameOverCeilingRollsBack() throws {
        let w = 40, h = 40, n = w * h
        let brightCount = Int((Double(n) * 0.45).rounded())
        var luma = [Float](repeating: 0, count: n)
        for i in 0 ..< n { luma[i] = i < (n - brightCount) ? 0.03 : 0.4 }
        let base = AutoLight.Sample(width: w, height: h, luma: luma)

        func measure(_ edit: EditModel) -> AutoLight.Sample {
            let gain = pow(2.0, edit.light.exposure)
            let mid = 1 + edit.light.midtones / 100 * 100   // 故意过冲
            let body = Float(0.03 * gain * mid)
            let bright = Float(0.4 * gain)
            var out = [Float](repeating: 0, count: n)
            for i in 0 ..< n { out[i] = i < (n - brightCount) ? body : bright }
            return AutoLight.Sample(width: w, height: h, luma: out)
        }

        var standard = AutoLight.Gates()
        standard.forcesStandardClass = true
        let plan = try AutoLight.plan(for: EditModel.neutral, gates: standard, lossAtDepth: { _ in 0 }) { measure($0) }
        let ceiling = plan.report.wholeCeiling
        let target = plan.report.subjectTarget
        var exposed = EditModel.neutral
        exposed.light.exposure = plan.exposure
        let afterExposure = measure(exposed).metrics()
        let after = measure(plan.apply(to: EditModel.neutral)).metrics()
        emit(String(format: "441 A③b · class %@ · whole before %.4f (ceiling %.4f) → after %.4f · subject before %.4f · 中间调 %.0f",
                    plan.report.frameClass.rawValue, afterExposure.p50, ceiling, after.p50,
                    afterExposure.subjectP50, plan.midtones))
        XCTAssertLessThan(afterExposure.p50, ceiling, "A③b：曝光之后整帧还没越线，提亮才会越过")
        XCTAssertLessThan(afterExposure.subjectP50, target, "A③b：主体必须不足")
        XCTAssertEqual(plan.midtones, 0, "A③b：减半仍越线 ⇒ 中间调回退到 0")
        XCTAssertLessThanOrEqual(after.p50, ceiling, "A③b：整帧不得越过 wholeCeiling")

        // ⑧b：去掉护栏 ⇒ 整帧被推过线，A③b 红。
        var gates = AutoLight.Gates()
        gates.ignoresWholeCeiling = true
        gates.forcesStandardClass = true
        // ⑧b 只拆整帧护栏；441 的每帧代价上限是另一条保护，`clippingBudgetOverride: 1.0` 把它关掉，
        // 否则它会替护栏回退到「不提」，这条反向门就看不到护栏本身的作用了。
        let gated = try AutoLight.plan(for: EditModel.neutral, gates: gates,
                                       clippingBudgetOverride: 1.0, lossAtDepth: { _ in 0 }) { measure($0) }
        let gatedAfter = measure(gated.apply(to: EditModel.neutral)).metrics()
        emit("441 GATE ⑧b · 去掉护栏 ⇒ 中间调 \(gated.midtones) · whole p50 \(gatedAfter.p50)（A③b 要求 ≤ \(ceiling)）")
        XCTAssertGreaterThan(gated.midtones, 0, "⑧b：没有护栏时这张图会被继续提亮")
        XCTAssertGreaterThan(gatedAfter.p50, ceiling, "⑧b：没有护栏时整帧确实越过 ceiling")
    }

    /// ⑧c：把 subjectTarget 压到 0.001 ⇒ 主体地板等于不存在，A⑤ 的中位提升必须红。
    func testGate8cCollapsingSubjectTargetSuppressesTheLift() throws {
        let model = Model()
        let shipped = try AutoLight.plan(for: EditModel.neutral) { model.sample(for: $0) }
        XCTAssertGreaterThan(shipped.midtones, 0, "出货路径在 A① 网格上必须提中间调")
        var gates = AutoLight.Gates()
        gates.collapsesSubjectTarget = true
        let gated = try AutoLight.plan(for: EditModel.neutral, gates: gates) { model.sample(for: $0) }
        print("441 GATE ⑧c · 出货中间调 \(shipped.midtones) · 地板 0.001 ⇒ \(gated.midtones)")
        XCTAssertEqual(gated.midtones, 0, "⑧c：地板 0.001 ⇒ 主体 0.02 已在地板之上 ⇒ 不提")
    }

    // MARK: - A② / A⑤ 真图回归

    /// **A⑤ 的帧集：先声明，后测量。**
    ///
    /// 24 张，覆盖派单 §5.3 要求的全部人群：
    /// - `boston` 那组（`L1030940`…`L1030944`，含 A④ 的五帧；0940/0943 兼作雪 / 大面积高光）；
    /// - 强天空：`austria/L1030857`；
    /// - 夜景：`austria/L1030547-denoised`；
    /// - US 两张：一张航拍大亮部（DJI）、一张暗主体（_1274394）；
    /// - 其余 15 张 = **步骤 1 之后主体仍然最低的 15 张奥地利照片**（这正是本单的用户口径：
    ///   「主体（去掉天空/灯光后）的曝光还缺一点」。选帧依据是 `subjectP50Before`（曝光后、中间调前），
    ///   不是本次中间调提了多少；表里 12 张 `subjectP50 < 0.06`，满足 §5.3 的 ≥8 张要求）。
    ///
    /// 这张表**不因结果调整**；要调的是 `subjectTarget` / 代价预算（见 REPORT）。
    static let a5Frames: [(root: String, name: String)] = [
        // boston 白墙（含雪 / 大面积高光 L1030940 / L1030943）
        ("boston", "L1030940.dng"),
        ("boston", "L1030941.dng"),
        ("boston", "L1030942.dng"),
        ("boston", "L1030943.dng"),
        ("boston", "L1030944.dng"),
        // 研究报告的 11 张 B 类（§6.5，逐张都在这里；L1030715 同时是 A/B 双标签）
        ("austria", "L1030530.dng"),
        ("austria", "L1030753.dng"),
        ("austria", "L1030531.dng"),
        ("austria", "L1030529.dng"),
        ("austria", "L1030532.dng"),
        ("austria", "L1030716.dng"),
        ("austria", "L1030750.dng"),
        ("austria", "L1030715.dng"),
        ("austria", "L1030478.dng"),
        ("austria", "L1030558.dng"),
        ("austria", "L1030595.dng"),
        // 强天空 / 夜景 / 航拍 / 极暗主体
        ("austria", "L1030857.dng"),
        ("austria", "L1030547-denoised.dng"),
        ("US", "DJI_air3_2250_D.dng"),
        ("US", "_1274394.dng"),
        // 四张主体明显偏暗的（subjectP50 < 0.06 的补足）
        ("austria", "L1030867.dng"),
        ("austria", "L1030722.dng"),
        ("austria", "L1030868.dng"),
        ("austria", "L1030717.dng"),
    ]

    /// A② 提亮了但不炸高光；A⑤ 逐张 before/after 表 + 主体中位提升 ≥ 0.3 档。
    ///
    /// 帧集是文件顶部**预先声明**的 `a5Frames`（24 张，不挑结果）。**A② 的增量是与「不做主体
    /// 地板」的同一次运行比的**（⑧c：subjectTarget=0.001），这样 426d 的曝光/高光/白色增量
    /// 不会混进来。没有库 / 没有 RAW / 没有 GPU 时跳过。
    ///
    /// 判据（§5.3，两条同时成立）：
    /// - 主体提升中位 ≥ 0.3 档（整组 24 帧的中位，不是子集）；
    /// - `clippedHDR` 增量中位 ≤ 0.1 pp 且最大 ≤ 0.5 pp；
    /// - 纹理损失（426d 的高光份额，门限不动）**全部** ≤ 0.08。
    func testA2A5RealFramesLiftSubjectWithoutBlowingHighlights() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let byKey = Dictionary(uniqueKeysWithValues: try editedRows().map {
            ("\($0.rootName)/\($0.filename)", $0)
        })
        var lifts: [Double] = []
        var hdrDeltas: [Double] = []
        var screenDeltas: [Double] = []
        var darkCount = 0
        var liftByClass: [AutoLight.FrameClass: [Double]] = [:]
        var hdrByClass: [AutoLight.FrameClass: [Double]] = [:]
        var bFrames = 0, cFrames = 0, aFrames = 0
        for (root, name) in Self.a5Frames {
            guard let row = byKey["\(root)/\(name)"] else { continue }
            let url = URL(fileURLWithPath: row.root).appendingPathComponent(row.filename)
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
            let g = try graph(url)
            var start = EditModel.neutral
            start.sharpen = SharpenGroup(amount: 0)
            start.light.blackOffset = row.edit.light.blackOffset

            let plan = try AutoLight.plan(for: start) { try g.measureAutoLightSample($0) }
            let auto = plan.apply(to: start)
            let am = try g.measureAutoLightSample(auto).metrics()

            // 同一张图、同一曝光/高光/白色，只是不做主体地板。
            var gates = AutoLight.Gates()
            gates.collapsesSubjectTarget = true
            let barePlan = try AutoLight.plan(for: start, gates: gates) { try g.measureAutoLightSample($0) }
            let bare = try g.measureAutoLightSample(barePlan.apply(to: start)).metrics()
            let hand = try g.measureAutoLightSample(row.edit).metrics()

            let lift = log2(max(plan.report.subjectP50After, 1e-9)
                            / max(plan.report.subjectP50Before, 1e-9))
            lifts.append(lift)
            liftByClass[plan.report.frameClass, default: []].append(lift)
            switch plan.report.frameClass {
            case .highKey: aFrames += 1
            case .darkBright:
                bFrames += 1
                XCTAssertEqual(plan.shadows, 0, "A② \(root)/\(name)：B 类不许提阴影")
                // 护栏只约束**这次提亮**：本来就在上限以上的帧，中间调必须是 0 且不得再推高；
                // 提亮前在上限以内的帧，提完不得越线。
                if plan.midtones > 0 {
                    XCTAssertLessThanOrEqual(plan.report.wholeP50After,
                                             plan.report.wholeCeiling * 1.001,
                                             "A② \(root)/\(name)：B 类提亮把整帧推过上限")
                    XCTAssertGreaterThan(plan.report.subjectP50After,
                                         plan.report.subjectP50Before,
                                         "A② \(root)/\(name)：B 类提亮必须真的抬高主体")
                } else {
                    XCTAssertEqual(plan.report.wholeP50After, plan.report.wholeP50Before, accuracy: 1e-9,
                                   "A② \(root)/\(name)：没有提亮就不许动整帧")
                }
            case .standard:
                cFrames += 1
                if plan.midtones > 0 {
                    XCTAssertLessThanOrEqual(plan.report.wholeP50After,
                                             plan.report.wholeCeiling * 1.001,
                                             "A④ \(root)/\(name)：C 类提亮把整帧推过上限")
                    // C 类的地板是 0.1238 线性（显示 0.387）；走到地板的帧应落在 ±10 % 内。
                    XCTAssertEqual(plan.report.subjectP50After, plan.report.subjectTarget,
                                   accuracy: plan.report.subjectTarget * 0.10,
                                   "A④ \(root)/\(name)：C 类主体应落在 target ±10 %")
                } else {
                    XCTAssertEqual(plan.report.wholeP50After, plan.report.wholeP50Before, accuracy: 1e-9,
                                   "A④ \(root)/\(name)：没有提亮就不许动整帧")
                }
            }
            if plan.report.subjectP50Before < 0.06 { darkCount += 1 }
            let hdrDelta = am.clippedHDR - bare.clippedHDR
            let screenDelta = am.clippedScreen - bare.clippedScreen
            hdrDeltas.append(hdrDelta)
            hdrByClass[plan.report.frameClass, default: []].append(hdrDelta)
            screenDeltas.append(screenDelta)
            XCTAssertLessThanOrEqual(plan.report.textureLossHighlightsOnly,
                                     AutoLight.highlightLossThreshold,
                                     "A② \(root)/\(name)：高光纹理损失 \(plan.report.textureLossHighlightsOnly)")
            emit(String(format: "441 A⑤ %@/%@ · %@ · 主体 %.4f→%.4f (%+.2f 档, 显示 %.2f) · 亮主体 %.2f · 整帧 %.4f→%.4f (显示 %.2f) · "
                         + "EV %+.2f · 中间调 %.0f · 阴影 %.0f · 黑 %.0f · clippedHDR %.2f%%→%.2f%% (%+.2fpp, 用户 %.2f%%) · "
                         + "clippedScreen %.2f%%→%.2f%% (%+.2fpp) · 纹理 %.1f%% / 仅高光 %.1f%% · darkT %.2f · blocks %.2f",
                         root, name, plan.report.frameClass.rawValue,
                         plan.report.subjectP50Before, plan.report.subjectP50After, lift,
                         AutoLight.displayFromLinear(plan.report.subjectP50After),
                         AutoLight.displayFromLinear(am.brightP50),
                         plan.report.wholeP50Before, plan.report.wholeP50After,
                         AutoLight.displayFromLinear(plan.report.wholeP50After),
                         plan.exposure, plan.midtones, plan.shadows, plan.blacks,
                         bare.clippedHDR * 100, am.clippedHDR * 100, hdrDelta * 100, hand.clippedHDR * 100,
                         bare.clippedScreen * 100, am.clippedScreen * 100, screenDelta * 100,
                         plan.report.textureLoss * 100, plan.report.textureLossHighlightsOnly * 100,
                         plan.report.darkTexture, plan.report.highlightBlocks))
        }
        guard lifts.count >= 24 else { throw XCTSkip("only \(lifts.count)/24 declared frames available") }
        let medianLift = lifts.sorted()[lifts.count / 2]
        let maxHDR = hdrDeltas.max() ?? 0
        let medianHDR = hdrDeltas.sorted()[hdrDeltas.count / 2]
        let maxScreen = screenDeltas.max() ?? 0
        emit(String(format: "441 A⑤ · %d frames (A %d / B %d / C %d) · 主体中位提升 %+.2f 档 · ΔclippedHDR 中位 %+.2fpp / 最大 %+.2fpp · max ΔclippedScreen %+.2fpp · 暗帧 %d",
                     lifts.count, aFrames, bFrames, cFrames, medianLift,
                     medianHDR * 100, maxHDR * 100, maxScreen * 100, darkCount))
        for cls in AutoLight.FrameClass.allCases {
            let l = liftByClass[cls] ?? []
            let h = hdrByClass[cls] ?? []
            guard !l.isEmpty else { continue }
            emit(String(format: "441 A⑥ class %@ · %d frames · 主体中位提升 %+.2f 档 · ΔclippedHDR 中位 %+.2fpp / 最大 %+.2fpp",
                         cls.rawValue, l.count, l.sorted()[l.count / 2],
                         h.sorted()[h.count / 2] * 100, (h.max() ?? 0) * 100))
        }
        XCTAssertGreaterThanOrEqual(darkCount, 8, "A⑤：subjectP50 < 0.06 的暗帧只有 \(darkCount) 张")
        XCTAssertGreaterThanOrEqual(medianLift, 0.3, "A⑤：主体中位提升 \(medianLift) 档，应 ≥ 0.3")
        XCTAssertLessThanOrEqual(medianHDR, 0.001, "A②：clippedHDR 增量中位 \(medianHDR * 100)pp，应 ≤ 0.1pp")
        XCTAssertLessThanOrEqual(maxHDR, 0.005,
                                 "A②：clippedHDR 增量最大 \(maxHDR * 100)pp，应 ≤ 0.5pp")
        XCTAssertLessThanOrEqual(maxScreen, 0.001, "A②：clippedScreen 增量 \(maxScreen * 100)pp，应 ≤ 0.1pp")
    }

    // MARK: - §6 分类标定与按类反向门

    /// 研究报告 60 帧里 `clip_high ≥ 10 %` 的 A 类（显示域，`/tmp/research441/renders.csv`）。
    static let researchAHighClip: [String] = [
        "L1030465.dng", "L1030466.dng", "L1030467.dng", "L1030470.dng", "L1030472.dng",
        "L1030474.dng", "L1030476.dng", "L1030489.dng", "L1030490.dng", "L1030491.dng",
        "L1030492.dng", "L1030493.dng", "L1030479-denoised.dng", "L1030479.dng",
        "L1030596.dng", "L1030598.dng", "L1030463.dng", "L1030715.dng",
    ]
    /// 研究报告的 11 张 B 类。`L1030715` 同时满足 A 的 `clip_high ≥ 10 %`（双标签，
    /// §6.1 的优先级把它判成 A）；其余 10 张必须判成 B。
    static let researchB: [String] = [
        "L1030530.dng", "L1030753.dng", "L1030531.dng", "L1030529.dng", "L1030532.dng",
        "L1030716.dng", "L1030750.dng", "L1030715.dng", "L1030478.dng", "L1030558.dng",
        "L1030595.dng",
    ]

    /// **A① 分类标定**：60 帧研究集，逐帧用出货分类器判类，与研究标签对表。
    ///
    /// 判据（§6.2）：B 类（除双标签 0715）全部判 B；A 类（除同一张照片的两个 0479 变体）
    /// 全部判 A；错分 ≤ 2 张且点名。实测只有 `L1030479.dng` / `L1030479-denoised.dng` 两张
    /// 被标成 A（作者用 +3.86 EV、中间调 +100、白色 −100 把一张欠曝片推成了大面积过白），
    /// 算法在 as-shot / 曝光后的读数里看不到这个**编辑**选择，所以判成 B —— 见 REPORT §2。
    func testA1ClassCalibrationOnResearchSixty() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let byName = Dictionary(uniqueKeysWithValues: try editedRows().map { ($0.filename, $0) })
        var confusion: [String: Int] = [:]
        var mismatches: [String] = []
        var seen = 0
        for name in Self.research60 {
            guard let row = byName[name] else { continue }
            let url = URL(fileURLWithPath: row.root).appendingPathComponent(row.filename)
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
            guard let g = try? graph(url) else { continue }
            var base = row.edit
            AutoLight.zero(&base)
            base.sharpen = SharpenGroup(amount: 0)
            guard let bs = try? g.measureAutoLightSample(base) else { continue }
            let bm = bs.metrics()
            var exposed = base
            exposed.light.exposure = AutoLight.snapExposure(
                log2(AutoLight.broadHighlightTarget / max(bm.p95, 1e-5)))
            guard let es = try? g.measureAutoLightSample(exposed) else { continue }
            let cls = AutoLight.classify(base: bm, afterExposure: es.metrics())
            let expected: AutoLight.FrameClass = Self.researchAHighClip.contains(name)
                ? .highKey : (Self.researchB.contains(name) ? .darkBright : .standard)
            confusion["\(expected.rawValue)->\(cls.rawValue)", default: 0] += 1
            if expected != cls { mismatches.append(name) }
            seen += 1
        }
        guard seen >= 54 else { throw XCTSkip("only \(seen)/60 research frames available") }
        emit("441 A① CONFUSION \(confusion.sorted { $0.key < $1.key })")
        emit("441 A① MISMATCH \(mismatches.sorted())")
        XCTAssertLessThanOrEqual(mismatches.count, 2,
                                 "A①：错分 \(mismatches.count) 张（\(mismatches)），应 ≤ 2")
        XCTAssertEqual(Set(mismatches), Set(["L1030479.dng", "L1030479-denoised.dng"]),
                       "A①：点名的那两张之外不许有别的错分")
        // 10 张单标签 B 必须真的落在 B；0715 是双标签，A 优先。
        let bOnly = Self.researchB.filter { $0 != "L1030715.dng" }
        let expectedB = confusion["B->B"] ?? 0
        XCTAssertGreaterThanOrEqual(expectedB, bOnly.count,
                                    "A①：单标签 B 只认出 \(expectedB)/\(bOnly.count) 张")
    }

    /// **⑧d**：分类恒为 C ⇒ A① 红。取一张 A、一张 B、一张 C，比较出货分类与强制 C。
    func testGate8dForcingStandardClassKillsClassification() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let byName = Dictionary(uniqueKeysWithValues: try editedRows().map { ($0.filename, $0) })
        var gates = AutoLight.Gates()
        gates.forcesStandardClass = true
        var changed = 0
        for name in ["L1030940.dng", "L1030530.dng", "L1030941.dng"] {
            guard let row = byName[name] else { continue }
            let url = URL(fileURLWithPath: row.root).appendingPathComponent(row.filename)
            guard FileManager.default.isReadableFile(atPath: url.path), let g = try? graph(url) else { continue }
            // 与 A⑤ 同一种起点（neutral + 这张图的 blackOffset），否则分类量会被 blackOffset 改掉。
            var start = EditModel.neutral
            start.sharpen = SharpenGroup(amount: 0)
            start.light.blackOffset = row.edit.light.blackOffset
            let shipped = try AutoLight.plan(for: start) { try g.measureAutoLightSample($0) }
            let forced = try AutoLight.plan(for: start, gates: gates) { try g.measureAutoLightSample($0) }
            emit("441 GATE ⑧d · \(name) · 出货 \(shipped.report.frameClass.rawValue) ⇒ 强制 \(forced.report.frameClass.rawValue)")
            XCTAssertEqual(forced.report.frameClass, .standard, "⑧d：强制门必须让分类恒为 C")
            if shipped.report.frameClass != .standard { changed += 1 }
        }
        XCTAssertGreaterThanOrEqual(changed, 2, "⑧d：A/B 至少两帧被强制成 C，A① 才会红")
    }

    /// **⑧a**：把 B 类的「阴影 ≤ 0」去掉 ⇒ A② 红。
    ///
    /// 60 帧研究集里的 B 图在步骤 1 曝光之后 p10 都已被抬到 `shadowTarget` 以上，所以只用真图
    /// 打开门，阴影仍然是 0 —— 门等于没被检验。这里用一个**明确分类成 B** 的合成网格：
    /// 20 % 亮主体 0.6、80 % 暗背景（0.001 和 0.02），`darkFrac ≥ 15 %`、`brightFrac ≥ 5 %`、
    /// `subjectBrightFrac ≥ 5 %`、`p50 < 0.40`，且没有 ≥10 % 过白（不是 A）。
    /// 它的 p10 = 0.001 < `shadowTarget`，所以出货（B 不许提阴影）阴影 = 0，打开门后 p10 地板
    /// 必须把阴影抬起来 —— A② 的「shadows ≤ 0」因此是承重的。
    func testGate8aBClassShadowsLiftWhenTheRuleIsRemoved() throws {
        let w = 100, h = 100, n = w * h
        var luma = [Float](repeating: 0.02, count: n)
        for i in 0 ..< n {
            if i < Int(Double(n) * 0.30) { luma[i] = 0.001 }        // 暗背景
            else if i >= Int(Double(n) * 0.80) { luma[i] = 0.60 }   // 亮主体 20 %
        }
        let sample = AutoLight.Sample(width: w, height: h, luma: luma)
        let metrics = sample.metrics()
        emit(String(format: "441 GATE ⑧a · 合成 B 网格 · p10 %.4f subject %.4f whole %.4f · dark %.2f bright %.2f · class %@",
                     metrics.p10, metrics.subjectP50, metrics.p50,
                     metrics.darkFrac, metrics.brightFrac,
                     AutoLight.classify(base: metrics, afterExposure: metrics).rawValue))
        XCTAssertEqual(AutoLight.classify(base: metrics, afterExposure: metrics), .darkBright,
                       "⑧a：合成网格必须先被判成 B 类")
        let shipped = try AutoLight.plan(for: EditModel.neutral) { _ in sample }
        var gates = AutoLight.Gates()
        gates.liftsShadowsForB = true
        let gated = try AutoLight.plan(for: EditModel.neutral, gates: gates) { _ in sample }
        emit("441 GATE ⑧a · B 类出货阴影 \(shipped.shadows) ⇒ 去掉规则 \(gated.shadows)")
        XCTAssertEqual(shipped.shadows, 0, "A②：B 类出货阴影必须 ≤ 0")
        XCTAssertGreaterThan(gated.shadows, 0, "⑧a：去掉规则后阴影必须 > 0，A② 才会红")
    }

    /// **⑧b**：三类上限改回单值（全按 C）⇒ A② / A④ 红。
    /// - A 图：C 的整帧上限 0.425 显示会把 A 的主体提亮压回去；
    /// - B 图：C 的上限比 B 宽松，整帧会被推过 0.25 显示。
    func testGate8bSingleCeilingBreaksPerClassBehavior() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let byName = Dictionary(uniqueKeysWithValues: try editedRows().map { ($0.filename, $0) })
        var gates = AutoLight.Gates()
        gates.collapsesClassCeilings = true
        var red = 0
        for name in ["L1030467.dng", "L1030530.dng", "L1030716.dng"] {
            guard let row = byName[name] else { continue }
            let url = URL(fileURLWithPath: row.root).appendingPathComponent(row.filename)
            guard FileManager.default.isReadableFile(atPath: url.path), let g = try? graph(url) else { continue }
            var start = EditModel.neutral
            start.sharpen = SharpenGroup(amount: 0)
            let shipped = try AutoLight.plan(for: start) { try g.measureAutoLightSample($0) }
            let gated = try AutoLight.plan(for: start, gates: gates) { try g.measureAutoLightSample($0) }
            emit(String(format: "441 GATE ⑧b · %@ · %@ 出货 主体 %.4f 整帧 %.4f (ceil %.4f) ⇒ 单值 主体 %.4f 整帧 %.4f (ceil %.4f)",
                        name, shipped.report.frameClass.rawValue,
                        shipped.report.subjectP50After, shipped.report.wholeP50After, shipped.report.wholeCeiling,
                        gated.report.subjectP50After, gated.report.wholeP50After, gated.report.wholeCeiling))
            if shipped.report.frameClass == .darkBright {
                if shipped.midtones > 0 {
                    XCTAssertLessThanOrEqual(shipped.report.wholeP50After,
                                             shipped.report.wholeCeiling * 1.001,
                                             "A②：B 类提亮不得越过整帧上限")
                }
                if gated.report.wholeP50After > shipped.report.wholeCeiling,
                   gated.report.wholeP50After > shipped.report.wholeP50After { red += 1 }
            } else if shipped.report.frameClass == .highKey {
                if gated.report.subjectP50After < shipped.report.subjectP50After - 1e-6 { red += 1 }
            }
        }
        XCTAssertGreaterThan(red, 0, "⑧b：单值上限必须让至少一类的 A②/A④ 判据变红")
    }

    /// **A③**：A 类的削顶门 0.30 不参与主体回退 —— `midtones` / `subjectP50` 增量与「不设削顶门」
    /// 逐位相同；⑧c 把它收回 0.05 后，同一帧的提亮被压回去。
    func testA3HighKeyClipCeilingDoesNotUndoTheSubjectLift() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let byName = Dictionary(uniqueKeysWithValues: try editedRows().map { ($0.filename, $0) })
        var noCeiling = AutoLight.Gates()
        noCeiling.ignoresClippedHighCeiling = true
        for name in ["L1030940.dng", "L1030466.dng", "L1030467.dng", "L1030493.dng", "L1030490.dng"] {
            guard let row = byName[name] else { continue }
            let url = URL(fileURLWithPath: row.root).appendingPathComponent(row.filename)
            guard FileManager.default.isReadableFile(atPath: url.path), let g = try? graph(url) else { continue }
            var start = EditModel.neutral
            start.sharpen = SharpenGroup(amount: 0)
            let shipped = try AutoLight.plan(for: start) { try g.measureAutoLightSample($0) }
            guard shipped.report.frameClass == .highKey else { continue }
            let open = try AutoLight.plan(for: start, gates: noCeiling) { try g.measureAutoLightSample($0) }
            XCTAssertEqual(shipped.midtones, open.midtones,
                           "A③ \(name)：A 类削顶门不得改变中间调")
            XCTAssertEqual(shipped.report.subjectP50After, open.report.subjectP50After, accuracy: 1e-9,
                           "A③ \(name)：A 类削顶门不得回退主体提亮")
            let finalShipped = try g.measureAutoLightSample(shipped.apply(to: start)).metrics()
            emit(String(format: "441 A③ · %@ · 削顶门 0.30：step2 主体 %.4f / 成品 %.4f / EV %+.2f · clippedHDR 曝光后 %.2f%%",
                        name, shipped.report.subjectP50After, finalShipped.subjectP50, shipped.exposure,
                        shipped.report.clippedHighAfterExposure * 100))
        }
    }

    /// **⑧c**：把 A 类的削顶门从 0.30 收回 0.05 ⇒ A③ 红。
    ///
    /// 合成的「20 % 白墙 + 80 % 暗主体」网格：曝光后 `clippedHDR = 20 %`，落在 0.05 与 0.30 之间。
    /// 出货（A 类 0.30）接受它、不降 EV；收回 0.05 后步骤 3 会降 EV（最多 3×0.15 档）再用中间调补主体，
    /// 成品主体被压低。替身的 measure 故意忽略高光/白色，保证这条门测的是**削顶门**而不是纹理。
    func testGate8cHighKeyClipCeilingCollapsedLosesTheLift() throws {
        let w = 40, h = 40, n = w * h
        let skyCount = Int(Double(n) * 0.20)
        var luma = [Float](repeating: 0, count: n)
        for i in 0 ..< n { luma[i] = i < (n - skyCount) ? 0.01 : 3.0 }
        func measure(_ edit: EditModel) -> AutoLight.Sample {
            let gain = pow(2.0, edit.light.exposure)
            let mid = 1 + edit.light.midtones / 100 * 21.0
            let body = Float(0.01 * gain * mid)
            let sky = Float(3.0 * gain)
            var out = [Float](repeating: 0, count: n)
            for i in 0 ..< n { out[i] = i < (n - skyCount) ? body : sky }
            return AutoLight.Sample(width: w, height: h, luma: out)
        }
        let shipped = try AutoLight.plan(for: EditModel.neutral, lossAtDepth: { _ in 0 }) { measure($0) }
        var gates = AutoLight.Gates()
        gates.collapsesHighKeyClipCeiling = true
        let closed = try AutoLight.plan(for: EditModel.neutral, gates: gates, lossAtDepth: { _ in 0 }) { measure($0) }
        let finalShipped = measure(shipped.apply(to: EditModel.neutral)).metrics()
        let finalClosed = measure(closed.apply(to: EditModel.neutral)).metrics()
        emit(String(format: "441 GATE ⑧c · A 削顶门 0.30：EV %+.2f 主体 %.4f · 收回 0.05：EV %+.2f 主体 %.4f",
                    shipped.exposure, finalShipped.subjectP50, closed.exposure, finalClosed.subjectP50))
        XCTAssertEqual(shipped.report.frameClass, .highKey)
        XCTAssertGreaterThan(shipped.exposure, closed.exposure, "⑧c：收回削顶门后 EV 必须被降下来")
        XCTAssertGreaterThan(finalShipped.subjectP50, finalClosed.subjectP50 + 1e-6,
                             "⑧c：收回削顶门后成品主体必须更低，A③ 才会红")
    }

    /// 标定辅助：用 `PHOTONS_SUBJECT_TARGET_441` 覆盖主体地板，跑同一批 24 帧并打印汇总。
    ///
    /// 默认跳过；只在「选 `subjectTarget`」时打开。它不改生产常量，也不改任何文档。
    func testSweepSubjectTarget441() throws {
        guard let raw = ProcessInfo.processInfo.environment["PHOTONS_SUBJECT_TARGET_441"] else {
            throw XCTSkip("set PHOTONS_SUBJECT_TARGET_441")
        }
        let targets = raw.split(separator: ",").compactMap { Double($0) }
        guard !targets.isEmpty else { throw XCTSkip("bad PHOTONS_SUBJECT_TARGET_441") }
        let budget = ProcessInfo.processInfo.environment["PHOTONS_CLIP_BUDGET_441"].flatMap { Double($0) }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let byKey = Dictionary(uniqueKeysWithValues: try editedRows().map {
            ("\($0.rootName)/\($0.filename)", $0)
        })
        var lifts = [[Double]](repeating: [], count: targets.count)
        var finalLifts = [[Double]](repeating: [], count: targets.count)
        var hdr = [[Double]](repeating: [], count: targets.count)
        var textureMax = [Double](repeating: 0, count: targets.count)
        var count = 0
        for (root, name) in Self.a5Frames {
            guard let row = byKey["\(root)/\(name)"] else { continue }
            let url = URL(fileURLWithPath: row.root).appendingPathComponent(row.filename)
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
            let g = try graph(url)
            var start = EditModel.neutral
            start.sharpen = SharpenGroup(amount: 0)
            start.light.blackOffset = row.edit.light.blackOffset
            var gates = AutoLight.Gates()
            gates.collapsesSubjectTarget = true
            let barePlan = try AutoLight.plan(for: start, gates: gates) { try g.measureAutoLightSample($0) }
            let bare = try g.measureAutoLightSample(barePlan.apply(to: start)).metrics()
            count += 1
            for (i, target) in targets.enumerated() {
                let plan = try AutoLight.plan(for: start, subjectTargetOverride: target,
                                              clippingBudgetOverride: budget) {
                    try g.measureAutoLightSample($0)
                }
                let am = try g.measureAutoLightSample(plan.apply(to: start)).metrics()
                let lift = log2(max(plan.report.subjectP50After, 1e-9)
                                / max(plan.report.subjectP50Before, 1e-9))
                lifts[i].append(lift)
                finalLifts[i].append(log2(max(am.subjectP50, 1e-9) / max(plan.report.subjectP50Before, 1e-9)))
                hdr[i].append(am.clippedHDR - bare.clippedHDR)
                textureMax[i] = max(textureMax[i], plan.report.textureLossHighlightsOnly)
                if i == 0 {
                    emit(String(format: "441 DIAG %@ · step2 主体 %.4f 整帧 %.4f · mid %.0f sh %.0f · final 主体 %.4f 整帧 %.4f · blacks %.0f",
                                 name, plan.report.subjectP50After, plan.report.p50AfterStep2,
                                 plan.report.midtones, plan.report.shadows, am.subjectP50, am.p50, plan.blacks))
                    emit(String(format: "441 SWEEP %@/%@ · 主体 %.4f→%.4f（成品 %.4f） · 整帧 %.4f→%.4f（成品 %.4f） · EV %+.2f · 中间调 %.0f · "
                                 + "clippedHDR %.2f%%→%.2f%% (%+.2fpp) · 仅高光 %.1f%% · 纹理损失 %.1f%% · 提升 %@",
                                 root, name, plan.report.subjectP50Before, plan.report.subjectP50After,
                                 am.subjectP50, plan.report.wholeP50Before, plan.report.p50AfterStep2,
                                 am.p50, plan.exposure, plan.midtones,
                                 bare.clippedHDR * 100, am.clippedHDR * 100,
                                 (am.clippedHDR - bare.clippedHDR) * 100,
                                 plan.report.textureLossHighlightsOnly * 100,
                                 plan.report.textureLoss * 100,
                                 String(format: "%.3f", lift)))
                }
            }
        }
        for (i, target) in targets.enumerated() {
            let sortedLifts = lifts[i].sorted()
            let medianLift = sortedLifts[sortedLifts.count / 2]
            let sortedHDR = hdr[i].sorted()
            let medianHDR = sortedHDR[sortedHDR.count / 2]
            let sortedFinal = finalLifts[i].sorted()
            emit(String(format: "441 SWEEP t=%.4f b=%@ · %d frames · step2 中位 %+.2f 档（最小 %+.2f） · 成品中位 %+.2f · ΔHDR 中位 %+.2fpp / 最大 %+.2fpp · 纹理最大 %.1f%% · 提升 %@",
                         target, budget.map { String(format: "%.3f", $0) } ?? "prod", count,
                         medianLift, sortedLifts.first ?? 0, sortedFinal[sortedFinal.count / 2],
                         medianHDR * 100, (sortedHDR.last ?? 0) * 100, textureMax[i] * 100,
                         sortedLifts.map { String(format: "%+.2f", $0) }.joined(separator: " ")))
        }
    }

    // MARK: - §6 分类标定（60 帧研究集）

    /// 研究报告 `docs/tasks/441-research-owner-habits.md` 的 60 帧集（每 ISO 档 12 张）。
    static let research60: [String] = [
        "L1030465.dng", "L1030466.dng", "L1030467.dng", "L1030470.dng", "L1030472.dng",
        "L1030474.dng", "L1030476.dng", "L1030489.dng", "L1030490.dng", "L1030491.dng",
        "L1030492.dng", "L1030493.dng",
        "L1030479-denoised.dng", "L1030479.dng", "L1030540.dng", "L1030596.dng", "L1030598.dng",
        "L1030699.dng", "L1030700.dng", "L1030702.dng", "L1030703.dng", "L1030716.dng",
        "L1030724.dng", "L1030725.dng",
        "L1030463.dng", "L1030464.dng", "L1030485-denoised.dng", "L1030485.dng",
        "L1030486.dng", "L1030497.dng", "L1030499.dng", "L1030500.dng", "L1030501.dng",
        "L1030715.dng", "L1030750.dng", "L1030753.dng",
        "L1030475.dng", "L1030478.dng", "L1030487.dng", "L1030505.dng", "L1030506.dng",
        "L1030529.dng", "L1030530.dng", "L1030531.dng", "L1030532.dng", "L1030537.dng",
        "L1030558.dng", "L1030595.dng",
        "L1030477.dng", "L1030481-denoised.dng", "L1030481.dng", "L1030482-denoised.dng",
        "L1030482.dng", "L1030484-denoised.dng", "L1030484.dng", "L1030502.dng", "L1030503.dng",
        "L1030504.dng", "L1030507.dng", "L1030508.dng",
    ]

    /// §6.1 标定：分类必须在**步骤 1 曝光之后**的那一帧上做（as-shot 的 base 在 60 帧上
    /// `clippedHDR` 全为 0，A 类判据 `≥ 10 %` 永远不成立 —— 见 REPORT）。这里打印曝光后样本的
    /// 线性分布，用来选 `darkCut` / `brightCut`。
    func testCalibrateClassesAfterExposure441() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_CALIBRATE_60"] == "1" else {
            throw XCTSkip("set PHOTONS_CALIBRATE_60=1")
        }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let byName = Dictionary(uniqueKeysWithValues: try editedRows().map { ($0.filename, $0) })
        let cuts: [Float] = [0.001, 0.002, 0.003, 0.005, 0.008, 0.01, 0.015, 0.02, 0.03,
                             0.04, 0.05, 0.065, 0.08, 0.1, 0.13, 0.16, 0.2, 0.25, 0.3, 0.4, 0.5, 0.7, 0.9,
                             1.1, 1.4, 1.8, 2.2]
        for name in Self.research60 {
            guard let row = byName[name] else { continue }
            let url = URL(fileURLWithPath: row.root).appendingPathComponent(row.filename)
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
            guard let g = try? graph(url) else { continue }
            var base = row.edit
            AutoLight.zero(&base)
            base.sharpen = SharpenGroup(amount: 0)
            guard let bs = try? g.measureAutoLightSample(base) else { continue }
            let bm = bs.metrics()
            guard let fs = try? g.measureAutoLightSample({ var e = row.edit; e.sharpen = SharpenGroup(amount: 0); return e }()) else { continue }
            let fm = fs.metrics()
            var exposed = base
            exposed.light.exposure = AutoLight.snapExposure(log2(AutoLight.broadHighlightTarget / max(bm.p95, 1e-5)))
            guard let es = try? g.measureAutoLightSample(exposed) else { continue }
            let em = es.metrics()
            func fmt(_ sample: AutoLight.Sample, _ m: AutoLight.Metrics) -> String {
                String(format: "p10 %.4f p50 %.4f p90 %.4f p95 %.4f p99 %.4f subject %.4f clip %.4f blocks %.4f darkCut %.4f brightCut %.4f",
                       m.p10, m.p50, m.p90, m.p95, m.p99, m.subjectP50, m.clippedHDR,
                       blockFraction(sample, size: 32, above: 0.85),
                       fraction(sample, below: 0.01), fraction(sample, above: 0.214))
            }
            emit("60BASE2 \(name) \(fmt(es, em))")
            emit("60CLS \(name) \(AutoLight.classify(base: bm, afterExposure: em).rawValue)")
            for c in cuts {
                emit(String(format: "60CUT2 %@ %.3f dark %.4f bright %.4f",
                            name, c, fraction(es, below: c), fraction(es, above: c)))
            }
        }
    }

    /// 32×32 块均值 > `above` 的占比（§6.4 的 `highlightBlocks`）。
    private func blockFraction(_ sample: AutoLight.Sample, size: Int, above: Float) -> Double {
        var blocks = 0, hit = 0
        var y = 0
        while y + size <= sample.height {
            var x = 0
            while x + size <= sample.width {
                var sum = 0.0, n = 0
                for yy in y ..< y + size {
                    for xx in x ..< x + size {
                        let v = sample.luma[yy * sample.width + xx]
                        guard AutoLight.Sample.isPicture(v) else { continue }
                        sum += Double(v); n += 1
                    }
                }
                if n > 0 {
                    blocks += 1
                    if sum / Double(n) > Double(above) { hit += 1 }
                }
                x += size
            }
            y += size
        }
        return blocks > 0 ? Double(hit) / Double(blocks) : 0
    }

    private func fraction(_ sample: AutoLight.Sample, below: Float) -> Double {
        var n = 0, hit = 0
        for v in sample.luma where AutoLight.Sample.isPicture(v) {
            n += 1
            if v < below { hit += 1 }
        }
        return n > 0 ? Double(hit) / Double(n) : 0
    }
    private func fraction(_ sample: AutoLight.Sample, above: Float) -> Double {
        var n = 0, hit = 0
        for v in sample.luma where AutoLight.Sample.isPicture(v) {
            n += 1
            if v > above { hit += 1 }
        }
        return n > 0 ? Double(hit) / Double(n) : 0
    }

    /// §6.2 标定：60 帧研究集的 **base（as-shot、未编辑）** 线性分布 + 成品线性分布。
    ///
    /// 默认跳过；`PHOTONS_CALIBRATE_60=1` 打开。输出喂给 `darkCut`/`brightCut` 的选值。
    func testCalibrateClasses441() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_CALIBRATE_60"] == "1" else {
            throw XCTSkip("set PHOTONS_CALIBRATE_60=1")
        }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let byName = Dictionary(uniqueKeysWithValues: try editedRows().map { ($0.filename, $0) })
        let cuts: [Float] = [0.001, 0.002, 0.003, 0.005, 0.008, 0.01, 0.015, 0.02, 0.03,
                             0.04, 0.05, 0.065, 0.08, 0.1, 0.13, 0.16, 0.2, 0.25, 0.3, 0.4, 0.5, 0.7, 0.9]
        for name in Self.research60 {
            guard let row = byName[name] else { continue }
            let url = URL(fileURLWithPath: row.root).appendingPathComponent(row.filename)
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
            guard let g = try? graph(url) else { continue }
            var base = row.edit
            AutoLight.zero(&base)
            base.sharpen = SharpenGroup(amount: 0)
            guard let bs = try? g.measureAutoLightSample(base) else { continue }
            let bm = bs.metrics()
            guard let fs = try? g.measureAutoLightSample({ var e = row.edit; e.sharpen = SharpenGroup(amount: 0); return e }()) else { continue }
            let fm = fs.metrics()
            func fmt(_ sample: AutoLight.Sample, _ m: AutoLight.Metrics) -> String {
                String(format: "p10 %.4f p50 %.4f p90 %.4f p95 %.4f p99 %.4f subject %.4f clip %.4f blocks %.4f",
                       m.p10, m.p50, m.p90, m.p95, m.p99, m.subjectP50, m.clippedHDR,
                       blockFraction(sample, size: 32, above: 0.85))
            }
            emit("60CAL \(name) BASE \(fmt(bs, bm))")
            emit("60CAL \(name) FIN  \(fmt(fs, fm))")
            for c in cuts {
                emit(String(format: "60CUT %@ %.3f dark %.4f bright %.4f",
                            name, c, fraction(bs, below: c), fraction(bs, above: c)))
            }
        }
    }

    // MARK: - 标定（真库）

    private struct EditedRow {
        let filename: String
        let rootName: String
        let root: String
        let edit: EditModel
    }

    private func editedRows(limit: Int? = nil) throws -> [EditedRow] {
        let library = NSString(string: "~/Documents/photons-demo.photonslibrary/library.db").expandingTildeInPath
        guard FileManager.default.isReadableFile(atPath: library) else { throw XCTSkip("no catalog") }
        let limitClause = limit.map { "LIMIT \($0)" } ?? ""
        let sql = """
        SELECT a.filename, s.display_name, s.path_hint, h.develop_json FROM assets a
          JOIN source_roots s ON s.id = a.source_root_id
          JOIN asset_history h ON h.asset_id = a.id
         WHERE h.seq = (SELECT MAX(seq) FROM asset_history x WHERE x.asset_id = a.id)
           AND h.seq > 1
         ORDER BY s.display_name, a.filename \(limitClause);
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [library, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var rows: [EditedRow] = []
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 3)
            guard parts.count == 4, let json = String(parts[3]).data(using: .utf8),
                  let model = try? JSONDecoder().decode(EditModel.self, from: json) else { continue }
            rows.append(EditedRow(filename: String(parts[0]), rootName: String(parts[1]),
                                  root: String(parts[2]), edit: model))
        }
        return rows
    }

    private func graph(_ url: URL) throws -> RenderGraph {
        let image = try RAWDecoder().decode(url, options: DecodeOptions(scale: 0.5))
        return try RenderGraph(input: RenderInput(image: image, identity: "auto-light-441-\(url.lastPathComponent)",
                                                  sourceURL: url))
    }

    /// A④：真库成品的 `subjectP50` / `wholeP50` 分布（p10 / p50 / p90）。
    ///
    /// 默认跳过；标定时设 `PHOTONS_CALIBRATE_441=1` 运行。它不改文档、不写库，只读当前快照。
    func testCalibrationDistribution441() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_CALIBRATE_441"] == "1" else {
            throw XCTSkip("set PHOTONS_CALIBRATE_441=1 to re-measure the library")
        }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let rows = try editedRows()
        var subjects: [Double] = []
        var wholes: [Double] = []
        var pairs: [(String, Double)] = []
        var byClass: [AutoLight.FrameClass: (subjects: [Double], wholes: [Double])] = [:]
        var skipped = 0
        for row in rows {
            let url = URL(fileURLWithPath: row.root).appendingPathComponent(row.filename)
            guard FileManager.default.isReadableFile(atPath: url.path) else { skipped += 1; continue }
            guard let g = try? graph(url) else { skipped += 1; continue }
            guard let m = try? g.measureAutoLightSample(row.edit).metrics() else { skipped += 1; continue }
            subjects.append(m.subjectP50)
            wholes.append(m.p50)
            pairs.append(("\(row.rootName)/\(row.filename)", m.subjectP50))
            // §6 — 用同一套分类（as-shot + 步骤 1 之后的读数）给成品分桶。
            var base = row.edit
            AutoLight.zero(&base)
            base.sharpen = SharpenGroup(amount: 0)
            guard let bs = try? g.measureAutoLightSample(base) else { continue }
            let bm = bs.metrics()
            var exposed = base
            exposed.light.exposure = AutoLight.snapExposure(log2(AutoLight.broadHighlightTarget / max(bm.p95, 1e-5)))
            guard let es = try? g.measureAutoLightSample(exposed) else { continue }
            let cls = AutoLight.classify(base: bm, afterExposure: es.metrics())
            var bucket = byClass[cls] ?? ([], [])
            bucket.subjects.append(m.subjectP50)
            bucket.wholes.append(m.p50)
            byClass[cls] = bucket
        }
        func q(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        emit(String(format: "441 CALIBRATION · %d frames (%d skipped) · subjectP50 p10 %.4f p50 %.4f p90 %.4f · wholeP50 p10 %.4f p50 %.4f p90 %.4f",
                     subjects.count, skipped,
                     q(subjects, 0.10), q(subjects, 0.50), q(subjects, 0.90),
                     q(wholes, 0.10), q(wholes, 0.50), q(wholes, 0.90)))
        for cls in AutoLight.FrameClass.allCases {
            guard let b = byClass[cls], !b.subjects.isEmpty else { continue }
            emit(String(format: "441 CALIB CLASS %@ · %d frames · subject p10 %.4f p50 %.4f p90 %.4f (display p50 %.3f) · whole p10 %.4f p50 %.4f p90 %.4f (display p50 %.3f)",
                         cls.rawValue, b.subjects.count,
                         q(b.subjects, 0.10), q(b.subjects, 0.50), q(b.subjects, 0.90),
                         AutoLight.displayFromLinear(q(b.subjects, 0.50)),
                         q(b.wholes, 0.10), q(b.wholes, 0.50), q(b.wholes, 0.90),
                         AutoLight.displayFromLinear(q(b.wholes, 0.50))))
        }
        XCTAssertGreaterThan(subjects.count, 0, "标定样本不能为空")
        for (name, v) in pairs.sorted(by: { $0.1 < $1.1 }).prefix(90) {
            emit(String(format: "441 CALIB LOW %@ %.4f", name, v))
        }
        for (name, v) in pairs.sorted(by: { $0.1 > $1.1 }).prefix(10) {
            emit(String(format: "441 CALIB HIGH %@ %.4f", name, v))
        }
    }
}
