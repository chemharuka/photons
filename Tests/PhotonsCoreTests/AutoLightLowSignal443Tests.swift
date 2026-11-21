import XCTest
import Metal
@testable import PhotonsCore

/// 派单 443 — 自动 Light 对「准黑」照片给 +6 EV：低信号帧必须封顶。
///
/// 这里只放 443 自己的验收：
/// - A①：L1030746 被判成 `lowSignal`，曝光 ≤ +3、中间调/阴影 = 0、成品 p99/p50 在用户成品的量级；
/// - A②：同一批（ISO 3200 夜景）再取 ≥5 张低信号帧，全部 ≤ +3 且不追主体；
/// - A④：60 帧研究集的步骤 1 曝光包络 p99 / max ≤ +4.5，逐帧列出被 cap 的帧；
/// - ⑧a / ⑧b：去掉低信号判定 / 去掉全类上限，各自的断言必须红。
///
/// A③（正常帧不回归）沿用 `AutoLightSubject441Tests` 的 24 帧 A⑤，本文件不重复。
final class AutoLightLowSignal443Tests: XCTestCase {

    private func emit(_ line: String) {
        print(line)
        let url = URL(fileURLWithPath: "/tmp/auto443.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write((line + "\n").data(using: .utf8)!)
            try? h.close()
        }
    }

    private func graph(_ url: URL) throws -> RenderGraph {
        let image = try RAWDecoder().decode(url, options: DecodeOptions(scale: 0.5))
        return try RenderGraph(input: RenderInput(image: image,
                                                  identity: "auto-light-443-\(url.lastPathComponent)",
                                                  sourceURL: url))
    }

    private func file(_ root: String, _ name: String) -> URL {
        URL(fileURLWithPath: NSString(string: "~/Desktop/\(root)/\(name).dng").expandingTildeInPath)
    }

    private func start(_ url: URL) throws -> (RenderGraph, EditModel) {
        let g = try graph(url)
        var edit = EditModel.neutral
        edit.sharpen = SharpenGroup(amount: 0)
        return (g, edit)
    }

    private func quantile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// A② 的低信号帧集：**先声明，后测量**。
    ///
    /// 派单给的例子（L1030868 / L1030719 / L1030713 / L1030739 / L1030867）在出货测量口径下
    /// `base.p99` 是 0.156–1.325、`clippedBlack` 只有 5–25 %，是「暗背景 + 亮主体 / 灯光」而不是
    /// 「整帧没有内容」；把它们当低信号会把正常的夜景压暗。这里改用同一批里真正的准黑帧：
    /// L1030740–0746 是同一段夜景连拍，L1030758 与 L1030725 是 60 帧研究集里最暗的两张。
    static let lowSignalFrames: [String] = [
        "L1030740", "L1030741", "L1030742", "L1030743", "L1030744",
        "L1030745", "L1030758", "L1030725",
    ]

    // MARK: - 低信号判据本身

    /// 443 的判据是**两个测量**，不是「看着黑」：`p99 < 0.07` 或 `clippedBlack ≥ 0.90`。
    ///
    /// 同时钉住「暗背景 + 亮主体」（B 类）不被误判：它的 `p99` 由主体/灯光抬起，黑位占比也
    /// 到不了 0.90。
    func testLowSignalIsP99OrNinetyPercentBlackAndNotMerelyDark() {
        func metrics(_ luma: [Float]) -> AutoLight.Metrics {
            AutoLight.Sample(width: 100, height: 100, luma: luma).metrics()
        }
        let n = 100 * 100

        // ① 99 分位是噪声，黑位 50 % —— p99 分支。
        var dim = [Float](repeating: 0.0005, count: n)
        for i in n / 2 ..< n { dim[i] = 0.03 }
        let dimM = metrics(dim)
        XCTAssertLessThan(dimM.p99, AutoLight.lowSignalP99)
        XCTAssertLessThan(dimM.clippedBlack, AutoLight.lowSignalClippedBlack)
        XCTAssertTrue(AutoLight.exposureDecision(base: dimM, gates: AutoLight.Gates()).lowSignal,
                      "443：p99 < 0.07 必须是低信号")

        // ② p99 被少量亮像素抬高，但 95 % 已经在黑位 —— `clippedBlack` 分支。
        var black = [Float](repeating: 0.0005, count: n)
        for i in (n - n / 20) ..< n { black[i] = 0.2 }
        let blackM = metrics(black)
        XCTAssertGreaterThanOrEqual(blackM.p99, AutoLight.lowSignalP99)
        XCTAssertGreaterThanOrEqual(blackM.clippedBlack, AutoLight.lowSignalClippedBlack)
        XCTAssertTrue(AutoLight.exposureDecision(base: blackM, gates: AutoLight.Gates()).lowSignal,
                      "443：clippedBlack ≥ 0.90 必须是低信号")

        // ③ B 类：80 % 暗背景 + 20 % 亮主体 —— 不是低信号。
        var darkBright = [Float](repeating: 0.001, count: n)
        for i in (n - n / 5) ..< n { darkBright[i] = 0.6 }
        let bM = metrics(darkBright)
        XCTAssertGreaterThanOrEqual(bM.p99, AutoLight.lowSignalP99)
        XCTAssertLessThan(bM.clippedBlack, AutoLight.lowSignalClippedBlack)
        XCTAssertFalse(AutoLight.exposureDecision(base: bM, gates: AutoLight.Gates()).lowSignal,
                       "443：暗背景 + 亮主体不是低信号")

        // ④ 普通帧不受影响，且全类上限是 +4.5。
        let normal = metrics([Float](repeating: 0.3, count: n))
        let decision = AutoLight.exposureDecision(base: normal, gates: AutoLight.Gates())
        XCTAssertFalse(decision.lowSignal)
        XCTAssertLessThanOrEqual(decision.exposure, AutoLight.maxExposureEV)
    }

    // MARK: - A① L1030746

    func testA1L1030746IsLowSignalAndCappedAtThreeEV() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let url = file("austria", "L1030746")
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("no L1030746")
        }
        let (g, begin) = try start(url)
        let base = try g.measureAutoLightSample(begin).metrics()
        let plan = try AutoLight.plan(for: begin) { try g.measureAutoLightSample($0) }
        let final = try g.measureAutoLightSample(plan.apply(to: begin)).metrics()
        emit(String(format: "443 A① L1030746 · base p50 %.4f p95 %.4f p99 %.4f black %.4f · "
                     + "need %+.2f → EV %+.2f (capped %@) · mid %.0f sh %.0f · "
                     + "成品 p50 %.4f (显示 %.3f) p99 %.4f (显示 %.3f)",
                     base.p50, base.p95, base.p99, base.clippedBlack,
                     plan.report.needEVBeforeCap, plan.exposure,
                     plan.report.exposureCapped ? "yes" : "no",
                     plan.midtones, plan.shadows,
                     final.p50, AutoLight.displayFromLinear(final.p50),
                     final.p99, AutoLight.displayFromLinear(final.p99)))

        XCTAssertTrue(plan.report.lowSignal, "A①：L1030746 必须被判成低信号帧")
        XCTAssertLessThanOrEqual(plan.exposure, AutoLight.lowSignalExposureCap + 1e-9,
                                 "A①：低信号帧曝光必须 ≤ +3，实测 \(plan.exposure)")
        XCTAssertEqual(plan.midtones, 0, "A①：低信号帧不追主体 ⇒ 中间调 = 0")
        XCTAssertEqual(plan.shadows, 0, "A①：低信号帧不追主体 ⇒ 阴影 = 0")
        XCTAssertGreaterThan(plan.report.needEVBeforeCap, plan.exposure + 1,
                             "A①：报告必须能读出「本来要多少」")
        XCTAssertTrue(plan.report.exposureCapped, "A①：这次曝光确实被低信号上限截断")
        XCTAssertLessThanOrEqual(AutoLight.displayFromLinear(final.p99), 0.50,
                                 "A①：成品 p99 必须 ≤ 0.50 显示（用户成品 0.439）")
        XCTAssertLessThanOrEqual(AutoLight.displayFromLinear(final.p50), 0.05,
                                 "A①：成品 p50 必须 ≤ 0.05 显示（用户成品 0.020）")
    }

    // MARK: - A② 同批低信号帧

    func testA2OtherLowSignalFramesAreAlsoCappedAndDoNotChaseASubject() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        var seen = 0
        for name in Self.lowSignalFrames {
            let url = file("austria", name)
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
            let (g, begin) = try start(url)
            let base = try g.measureAutoLightSample(begin).metrics()
            let plan = try AutoLight.plan(for: begin) { try g.measureAutoLightSample($0) }
            seen += 1
            emit(String(format: "443 A② %@ · base p50 %.4f p95 %.4f p99 %.4f black %.4f · "
                         + "need %+.2f → EV %+.2f · mid %.0f sh %.0f · low %@",
                         name, base.p50, base.p95, base.p99, base.clippedBlack,
                         plan.report.needEVBeforeCap, plan.exposure,
                         plan.midtones, plan.shadows,
                         plan.report.lowSignal ? "yes" : "no"))
            XCTAssertTrue(plan.report.lowSignal, "A② \(name)：必须判成低信号")
            XCTAssertLessThanOrEqual(plan.exposure, AutoLight.lowSignalExposureCap + 1e-9,
                                     "A② \(name)：曝光必须 ≤ +3")
            XCTAssertEqual(plan.midtones, 0, "A② \(name)：低信号帧中间调 = 0")
            XCTAssertEqual(plan.shadows, 0, "A② \(name)：低信号帧阴影 = 0")
        }
        XCTAssertGreaterThanOrEqual(seen, 5, "A②：低信号帧只有 \(seen) 张可用，应 ≥ 5")
    }

    // MARK: - A④ 60 帧研究集的曝光包络

    /// 研究报告 `docs/tasks/441-research-owner-habits.md` 的 60 帧集（每 ISO 档 12 张）。
    static let research60: [String] = [
        "L1030465", "L1030466", "L1030467", "L1030470", "L1030472", "L1030474", "L1030476",
        "L1030489", "L1030490", "L1030491", "L1030492", "L1030493", "L1030479-denoised",
        "L1030479", "L1030540", "L1030596", "L1030598", "L1030699", "L1030700", "L1030702",
        "L1030703", "L1030716", "L1030724", "L1030725", "L1030463", "L1030464",
        "L1030485-denoised", "L1030485", "L1030486", "L1030497", "L1030499", "L1030500",
        "L1030501", "L1030715", "L1030750", "L1030753", "L1030475", "L1030478", "L1030487",
        "L1030505", "L1030506", "L1030529", "L1030530", "L1030531", "L1030532", "L1030537",
        "L1030558", "L1030595", "L1030477", "L1030481-denoised", "L1030481",
        "L1030482-denoised", "L1030482", "L1030484-denoised", "L1030484", "L1030502",
        "L1030503", "L1030504", "L1030507", "L1030508",
    ]

    func testA4SixtyFrameExposureEnvelopeStaysInsideFourPointFive() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        var exposures: [Double] = []
        var capped: [(String, Double, Double)] = []     // name, need, delivered
        var bases: [(String, AutoLight.Metrics)] = []
        for name in Self.research60 {
            let url = file("austria", name)
            guard FileManager.default.isReadableFile(atPath: url.path),
                  let (g, begin) = try? start(url),
                  let m = try? g.measureAutoLightSample(begin).metrics() else { continue }
            bases.append((name, m))
            let d = AutoLight.exposureDecision(base: m, gates: AutoLight.Gates())
            exposures.append(d.exposure)
            if d.capped {
                capped.append((name, d.needEV, d.exposure))
                emit(String(format: "443 A④ CAPPED %@ · base p99 %.4f black %.4f · low %@ · need %+.2f → %+.2f",
                             name, m.p99, m.clippedBlack, d.lowSignal ? "yes" : "no",
                             d.needEV, d.exposure))
                // 被 cap 的帧真的跑一遍完整 plan：步骤 3 只会继续降 EV，不会把上限抬回去。
                let plan = try AutoLight.plan(for: begin) { try g.measureAutoLightSample($0) }
                XCTAssertLessThanOrEqual(plan.exposure, AutoLight.maxExposureEV + 1e-9,
                                         "A④ \(name)：完整 plan 的曝光也必须 ≤ +4.5")
                XCTAssertTrue(plan.report.exposureCapped, "A④ \(name)：报告必须标 exposureCapped")
                XCTAssertEqual(plan.report.needEVBeforeCap, d.needEV, accuracy: 1e-9,
                               "A④ \(name)：报告里的 needEVBeforeCap 就是步骤 1 的本来值")
            }
        }
        guard exposures.count >= 54 else {
            throw XCTSkip("only \(exposures.count)/60 research frames available")
        }
        let p99 = quantile(exposures, 0.99)
        let maxEV = exposures.max() ?? 0
        emit(String(format: "443 A④ · %d frames · p10 %+.2f p50 %+.2f p90 %+.2f p99 %+.2f max %+.2f · capped %d",
                     exposures.count, quantile(exposures, 0.10), quantile(exposures, 0.50),
                     quantile(exposures, 0.90), p99, maxEV, capped.count))
        XCTAssertLessThanOrEqual(p99, AutoLight.maxExposureEV + 1e-9,
                                 "A④：60 帧曝光 p99 \(p99) 必须 ≤ +4.5")
        XCTAssertLessThanOrEqual(maxEV, AutoLight.maxExposureEV + 1e-9,
                                 "A④：60 帧曝光 max \(maxEV) 必须 ≤ +4.5")
        XCTAssertGreaterThanOrEqual(capped.count, 2, "A④：60 帧里应有 ≥2 张被 cap，门才有对象")

        // ⑧b — 去掉全类上限 ⇒ 同一批的曝光包络必须越 +4.5。
        var gates = AutoLight.Gates()
        gates.ignoresExposureCap = true
        var uncapped: [Double] = []
        for (_, m) in bases {
            uncapped.append(AutoLight.exposureDecision(base: m, gates: gates).exposure)
        }
        let gatedP99 = quantile(uncapped, 0.99)
        let gatedMax = uncapped.max() ?? 0
        emit(String(format: "443 GATE ⑧b · 去掉 maxExposureEV · %d frames · p99 %+.2f max %+.2f（A④ 要求 ≤ +4.5）",
                     uncapped.count, gatedP99, gatedMax))
        XCTAssertGreaterThan(gatedP99, AutoLight.maxExposureEV,
                             "⑧b：去掉上限后曝光 p99 必须越 +4.5，A④ 才会红")
    }

    // MARK: - ⑧a 去掉低信号判定

    func testGate8aDroppingLowSignalRestoresTheUnboundedExposure() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let url = file("austria", "L1030746")
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("no L1030746")
        }
        let (g, begin) = try start(url)
        let shipped = try AutoLight.plan(for: begin) { try g.measureAutoLightSample($0) }

        var gates = AutoLight.Gates()
        gates.ignoresLowSignal = true
        // 不打开 `ignoresExposureCap`：全类 +4.5 仍然生效。门要证明的是「低信号判定拿掉后，
        // 算法回到普通帧路径」——+4.5 已经越过低信号的 +3，而且这个曝光点下主体地板重新动作。
        let gated = try AutoLight.plan(for: begin, gates: gates) { try g.measureAutoLightSample($0) }
        emit(String(format: "443 GATE ⑧a · 出货 low %@ EV %+.2f mid %.0f · 去掉 lowSignal low %@ EV %+.2f mid %.0f (need %+.2f)",
                     shipped.report.lowSignal ? "yes" : "no", shipped.exposure, shipped.midtones,
                     gated.report.lowSignal ? "yes" : "no", gated.exposure, gated.midtones,
                     gated.report.needEVBeforeCap))

        XCTAssertFalse(gated.report.lowSignal, "⑧a：门打开后不得再判低信号")
        XCTAssertGreaterThan(gated.exposure, AutoLight.lowSignalExposureCap,
                             "⑧a：去掉低信号判定后曝光必须越过 +3，A① 才会红")
        XCTAssertGreaterThan(gated.midtones, 0,
                             "⑧a：去掉低信号判定后主体地板重新参与，中间调必须 > 0")
        XCTAssertGreaterThan(gated.exposure, shipped.exposure,
                             "⑧a：门的曝光必须比出货更高")
    }
}
