import XCTest
import Metal
@testable import PhotonsCore

/// 派单 452 — 自然饱和度强度 0.5 → 0.28，以及自动颜色（自动饱和度）的纯函数与标定。
///
/// This file is only 452's own acceptance: the kernel/Swift constant reconciliation, the pure
/// `AutoColor.metrics/plan` behaviour (grey, low chroma, already-at-target, letterbox), and the
/// opt-in real-library calibration that produced `AutoColor.defaultTarget`.
final class AutoColor452Tests: XCTestCase {

    // MARK: - fixtures

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// `width × height`, each pixel from `rgb`, alpha 1.
    private func sample(_ width: Int, _ height: Int,
                        _ rgb: (Int, Int) -> (Double, Double, Double)) -> LinearSample {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (r, g, b) = rgb(x, y)
                let o = (y * width + x) * 4
                rgba[o] = Float16(r); rgba[o + 1] = Float16(g)
                rgba[o + 2] = Float16(b); rgba[o + 3] = 1
            }
        }
        return LinearSample(width: width, height: height, rgba: rgba)
    }

    /// A scene-linear colour at a chosen OKLab lightness / chroma / hue.
    private func oklch(_ l: Double, _ c: Double, _ h: Double) -> (Double, Double, Double) {
        let v = CalibrationGroup.rec2020(fromOklab: SIMD3(l, c * cos(h), c * sin(h)))
        return (v.x, v.y, v.z)
    }

    // MARK: - c1 — the gain is one number in two places

    /// **The reconciliation the ticket asks for.** The kernel's `kVibranceGain` and Swift's
    /// `AutoColor.vibranceGain` are the two halves of one curve (S3 applies it, auto colour inverts
    /// it); if they drift the auto plan stops landing where a hand move would. The kernel text is
    /// the source of truth when it is readable, and the literal is asserted either way.
    ///
    /// Reverse gate: change `AutoColor.vibranceGain` to 0.5 and this test fails on the parsed kernel
    /// value (0.28); change the kernel literal and it fails too.
    func testVibranceGainMatchesTheKernelLiteral() throws {
        XCTAssertEqual(AutoColor.vibranceGain, 0.28, accuracy: 1e-12,
                       "452 的产品强度是 0.28；kernel 里必须是同一个数")

        let url = Self.repoRoot.appendingPathComponent("Sources/PhotonsCore/Kernels/s3_color.metal")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // The source tree is not beside the test bundle (installed/CI layout): the literal
            // assertion above is the contract — kernel and Swift both say 0.28.
            return
        }
        let pattern = #"constant\s+float\s+kVibranceGain\s*=\s*([0-9.]+)"#
        let match = try XCTUnwrap(text.range(of: pattern, options: .regularExpression),
                                  "s3_color.metal must declare `constant float kVibranceGain = …`")
        let literal = String(text[match]).split(separator: "=").last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        XCTAssertEqual(Double(literal), AutoColor.vibranceGain,
                       "Swift 常量必须与 s3_color.metal 的 kVibranceGain 相等")
        XCTAssertFalse(text.contains(" p.a.x / 100.0 * 0.5 *"),
                       "旧的 0.5 字面量必须从 vibrance 行消失")
    }

    // MARK: - c2 — the pure functions

    /// A perfectly grey grid has no coloured samples and nothing for auto colour to do.
    func testGreyGridIsUntouched() {
        let grid = sample(40, 30) { _, _ in (0.18, 0.18, 0.18) }
        let m = AutoColor.metrics(from: grid)
        print(String(format: "452 GREY · chromaP50 %.6f · coloured %.4f · n %d",
                     m.chromaP50, m.coloredFraction, m.sampleCount))
        XCTAssertEqual(m.coloredFraction, 0, accuracy: 1e-12, "R=G=B ⇒ 没有一个有彩样本")
        XCTAssertEqual(m.sampleCount, 40 * 30)
        XCTAssertEqual(AutoColor.plan(m), 0, accuracy: 1e-12, "灰网格不动")
    }

    /// A muted grid (C ≈ 0.03) is raised toward a target **above** it, and never past +60.
    ///
    /// 498 moved the calibrated default from the library p50 (0.0219, where half the library solved
    /// to 0) to p70. This test is about the mapping; `testAtTargetGridIsLeftAlone` is about the
    /// calibrated default. The explicit-target assertion pins the formula down; the default one only
    /// says the calibrated target is above a muted grid.
    func testLowChromaGridIsRaisedWithinTheCeiling() {
        let c = 0.03
        let grid = sample(40, 30) { _, _ in oklch(0.62, c, 0.4) }
        let m = AutoColor.metrics(from: grid)
        let raised = AutoColor.plan(m, target: 0.10)
        print(String(format: "452/498 LOW · chromaP50 %.4f · coloured %.4f · plan(target .10) %.2f · plan(default) %.2f",
                     m.chromaP50, m.coloredFraction, raised, AutoColor.plan(m)))
        XCTAssertEqual(m.chromaP50, c, accuracy: 5e-4, "fixture 的 OKLab 彩度必须真的 ≈ 0.03")
        XCTAssertGreaterThan(m.coloredFraction, AutoColor.minimumColoredFraction)
        XCTAssertGreaterThan(raised, 0, "低于目标 ⇒ 必须提")
        XCTAssertLessThanOrEqual(raised, AutoColor.maxVibrance, "上限 +60")
        if AutoColor.targetChromaP50 > c {
            XCTAssertGreaterThan(AutoColor.plan(m), 0,
                                 "498 的 p70 目标高于 0.03 ⇒ 这张典型片必须有正向 lift")
        }
    }

    /// A frame already at the target gets no move (the tool only raises).
    func testAtTargetGridIsLeftAlone() {
        let grid = sample(40, 30) { _, _ in oklch(0.62, AutoColor.targetChromaP50, 0.4) }
        let m = AutoColor.metrics(from: grid)
        print(String(format: "452/498 AT TARGET · chromaP50 %.4f · target %.4f · plan %.4f",
                     m.chromaP50, AutoColor.targetChromaP50, AutoColor.plan(m)))
        XCTAssertEqual(AutoColor.plan(m), 0, accuracy: 0.5,
                       "已达标 ⇒ plan 为 0（±0.5：Float16 往返误差）")
        XCTAssertLessThanOrEqual(AutoColor.plan(m), AutoColor.maxVibrance)
    }

    /// Letterbox sentinels are not photographs: half a frame of `−65504` must not move p50 at all.
    func testLetterboxSentinelsDoNotEnterTheStatistics() {
        let c = 0.06
        let pictureOnly = sample(40, 30) { _, _ in oklch(0.62, c, 0.4) }
        var rgba = [Float16](repeating: 0, count: 40 * 30 * 4)
        let clean = pictureOnly.rgba
        for p in 0 ..< 40 * 30 {
            let o = p * 4
            if p % 2 == 0 {
                rgba[o] = Float16(-65504); rgba[o + 1] = Float16(-65504)
                rgba[o + 2] = Float16(-65504); rgba[o + 3] = Float16(-65504)
            } else {
                rgba[o] = clean[o]; rgba[o + 1] = clean[o + 1]
                rgba[o + 2] = clean[o + 2]; rgba[o + 3] = clean[o + 3]
            }
        }
        let holed = LinearSample(width: 40, height: 30, rgba: rgba)
        let a = AutoColor.metrics(from: pictureOnly)
        let b = AutoColor.metrics(from: holed)
        print(String(format: "452 LETTERBOX · clean p50 %.6f n %d · holed p50 %.6f n %d",
                     a.chromaP50, a.sampleCount, b.chromaP50, b.sampleCount))
        XCTAssertEqual(b.chromaP50, a.chromaP50, accuracy: 1e-9,
                       "哨兵样本不参与统计 ⇒ p50 与不带哨兵时相同")
        XCTAssertEqual(b.sampleCount, a.sampleCount / 2)
        XCTAssertEqual(b.coloredFraction, a.coloredFraction, accuracy: 1e-12)
        XCTAssertEqual(AutoColor.plan(b), AutoColor.plan(a), accuracy: 1e-9)
    }

    // MARK: - c2 — calibration (real library, opt-in)

    private struct EditedRow {
        let filename: String
        let rootName: String
        let root: String
        let edit: EditModel
    }

    /// The demo catalog's **edited** frames (latest snapshot `seq > 1`) — the 441 harness's query.
    private func editedRows() throws -> [EditedRow] {
        let library = NSString(string: "~/Documents/photons-demo.photonslibrary/library.db").expandingTildeInPath
        guard FileManager.default.isReadableFile(atPath: library) else { throw XCTSkip("no catalog") }
        let sql = """
        SELECT a.filename, s.display_name, s.path_hint, h.develop_json FROM assets a
          JOIN source_roots s ON s.id = a.source_root_id
          JOIN asset_history h ON h.asset_id = a.id
         WHERE h.seq = (SELECT MAX(seq) FROM asset_history x WHERE x.asset_id = a.id)
           AND h.seq > 1
         ORDER BY s.display_name, a.filename;
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
        return try RenderGraph(input: RenderInput(image: image,
                                                  identity: "auto-color-452-\(url.lastPathComponent)",
                                                  sourceURL: url))
    }

    /// **c2 的标定：真库成品的 `chromaP50` / `coloredFraction` 分布。**
    ///
    /// 默认跳过；`PHOTONS_CALIBRATE_452=1 swift test --filter testCalibrationDistribution452`
    /// 才跑。只读当前快照，不改文档、不写库。落盘的 `AutoColor.defaultTarget` 就是这里的 p50。
    func testCalibrationDistribution452() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_CALIBRATE_452"] == "1" else {
            throw XCTSkip("set PHOTONS_CALIBRATE_452=1 to re-measure the library")
        }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let rows = try editedRows()
        var chromas: [Double] = []
        var coloreds: [Double] = []
        var skipped = 0
        for row in rows {
            let url = URL(fileURLWithPath: row.root).appendingPathComponent(row.filename)
            guard FileManager.default.isReadableFile(atPath: url.path) else { skipped += 1; continue }
            guard let g = try? graph(url) else { skipped += 1; continue }
            guard let s = try? g.measureLinearSample(row.edit) else { skipped += 1; continue }
            let m = AutoColor.metrics(from: s)
            chromas.append(m.chromaP50)
            coloreds.append(m.coloredFraction)
        }
        func q(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        print(String(format: "452 CALIBRATION · %d frames (%d skipped) · chromaP50 p10 %.4f p50 %.4f p90 %.4f · "
                     + "coloredFraction p10 %.4f p50 %.4f p90 %.4f",
                     chromas.count, skipped,
                     q(chromas, 0.10), q(chromas, 0.50), q(chromas, 0.90),
                     q(coloreds, 0.10), q(coloreds, 0.50), q(coloreds, 0.90)))
        XCTAssertGreaterThan(chromas.count, 0, "标定样本不能为空")
    }
}
