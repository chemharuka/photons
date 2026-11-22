import XCTest
import Metal
@testable import PhotonsCore

/// 498 — diagnostics only. This file deliberately measures the **old** `AutoColor` (before the
/// 2-degree-of-freedom change) so the report's "0+0" table is evidence, not a claim.
///
/// Opt in: `PHOTONS_DIAGNOSE_498=1 swift test --filter testDiagnoseZeroPlan498`.
final class AutoColor498DiagnosticsTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private struct Row {
        let name: String
        let url: URL
        let edit: EditModel
    }

    private func graph(_ url: URL) throws -> RenderGraph {
        let image = try RAWDecoder().decode(url, options: DecodeOptions(scale: 0.5))
        return try RenderGraph(input: RenderInput(image: image,
                                                  identity: "auto-color-498-\(url.lastPathComponent)",
                                                  sourceURL: url))
    }

    /// Same query as 452's calibration: the demo catalog's edited frames (latest snapshot seq > 1).
    private func editedRows() throws -> [Row] {
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
        var rows: [Row] = []
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 3)
            guard parts.count == 4, let json = String(parts[3]).data(using: .utf8),
                  let model = try? JSONDecoder().decode(EditModel.self, from: json) else { continue }
            let url = URL(fileURLWithPath: String(parts[2])).appendingPathComponent(String(parts[0]))
            rows.append(Row(name: "\(parts[1])/\(parts[0])", url: url, edit: model))
        }
        return rows
    }

    private struct Measured {
        let p50: Double
        let p70: Double
        let p85: Double
        let p95: Double
        let colored: Double
        let n: Int
    }

    /// Recomputes what 498 needs from the same scene-linear sample: the full chroma percentile set.
    private func measure(_ sample: LinearSample) -> Measured {
        let weights = ColorPrimaries.working.luminanceWeights
        var chroma: [Float] = []
        chroma.reserveCapacity(sample.width * sample.height)
        var colored = 0
        for p in 0 ..< sample.width * sample.height {
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
        guard !chroma.isEmpty else { return Measured(p50: 0, p70: 0, p85: 0, p95: 0, colored: 0, n: 0) }
        chroma.sort()
        return Measured(p50: AutoLight.percentile(chroma, 0.50),
                        p70: AutoLight.percentile(chroma, 0.70),
                        p85: AutoLight.percentile(chroma, 0.85),
                        p95: AutoLight.percentile(chroma, 0.95),
                        colored: Double(colored) / Double(chroma.count),
                        n: chroma.count)
    }

    /// Six named fixtures: people (L1040003, L1030433), blue sky (L1030684), the high-chroma
    /// over-shoot family (P5190009), a low-chroma neutral (L1030541), and the festival frame.
    private static let fixtureNames = [
        "L1040003", "L1030433", "L1030684", "P5190009", "L1030541", "L1030402",
    ]

    private func fixtureRows() -> [Row] {
        let dirs = ["~/Desktop/test", "~/Desktop/austria", "~/Desktop/boston"].map {
            NSString(string: $0).expandingTildeInPath
        }
        var rows: [Row] = []
        for dir in dirs {
            let all = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for stem in Self.fixtureNames {
                guard let file = all.first(where: { ($0 as NSString).deletingPathExtension == stem })
                else { continue }
                let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
                rows.append(Row(name: "\(URL(fileURLWithPath: dir).lastPathComponent)/\(file)",
                                url: url, edit: EditModel()))
            }
        }
        return rows
    }

    /// **The report's table.** Old plan: `v = 100·(target − p50)/(k·(1 − p50))`, target 0.0219.
    func testDiagnoseZeroPlan498() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_DIAGNOSE_498"] == "1" else {
            throw XCTSkip("set PHOTONS_DIAGNOSE_498=1 to print the 18-frame diagnostic table")
        }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }

        var rows: [Row] = fixtureRows()
        let fixtureStems = Set(Self.fixtureNames)
        let library = try editedRows().filter {
            FileManager.default.isReadableFile(atPath: $0.url.path)
                && !fixtureStems.contains(($0.url.lastPathComponent as NSString).deletingPathExtension)
        }
        XCTAssertFalse(library.isEmpty, "no readable edited frames in the demo library")
        // 12 spread evenly over the catalog, so the sample is not one folder's morning.
        for i in 0 ..< 12 where !library.isEmpty {
            let index = library.count == 1 ? 0 : Int(Double(i) * Double(library.count - 1) / 11.0)
            rows.append(library[index])
        }

        let oldTarget = 0.0219
        let k = AutoColor.vibranceGain
        var zero = 0
        print("498 DIAGNOSTIC · old target \(oldTarget) · k \(k)")
        print("name\tp50\tp70\tp85\tp95\tcolored\tvOld")
        for row in rows {
            guard let g = try? graph(row.url) else { continue }
            guard let s = try? g.measureLinearSample(row.edit) else { continue }
            let m = measure(s)
            let denominator = k * (1 - m.p50)
            let v = denominator > 1e-9 ? 100 * (oldTarget - m.p50) / denominator : 0
            if v <= 0 { zero += 1 }
            print(String(format: "%@\t%.4f\t%.4f\t%.4f\t%.4f\t%.3f\t%+.2f",
                         row.name, m.p50, m.p70, m.p85, m.p95, m.colored, v))
        }
        print("498 DIAGNOSTIC · frames \(rows.count) · v==0 \(zero) (\(String(format: "%.0f%%", 100 * Double(zero) / Double(max(rows.count, 1)))))")
    }

    /// The **new** calibration: the edited library's chromaP50 / p70 / p85 / p95 distribution.
    /// Opt in: `PHOTONS_CALIBRATE_498=1 swift test --filter testCalibrationDistribution498`.
    func testCalibrationDistribution498() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_CALIBRATE_498"] == "1" else {
            throw XCTSkip("set PHOTONS_CALIBRATE_498=1 to re-measure the library")
        }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let rows = try editedRows()
        var p50s: [Double] = []
        var p70s: [Double] = []
        var p85s: [Double] = []
        var p95s: [Double] = []
        var coloreds: [Double] = []
        var skipped = 0
        for row in rows {
            guard FileManager.default.isReadableFile(atPath: row.url.path),
                  let g = try? graph(row.url),
                  let s = try? g.measureLinearSample(row.edit) else { skipped += 1; continue }
            let m = measure(s)
            p50s.append(m.p50); p70s.append(m.p70); p85s.append(m.p85); p95s.append(m.p95)
            coloreds.append(m.colored)
        }
        func q(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        func line(_ name: String, _ values: [Double]) -> String {
            String(format: "%@\tp10 %.4f\tp50 %.4f\tp70 %.4f\tp85 %.4f\tp90 %.4f\tp95 %.4f",
                   name, q(values, 0.10), q(values, 0.50), q(values, 0.70),
                   q(values, 0.85), q(values, 0.90), q(values, 0.95))
        }
        print("498 CALIBRATION · \(p50s.count) frames (\(skipped) skipped)")
        print(line("chromaP50", p50s))
        print(line("chromaP70", p70s))
        print(line("chromaP85", p85s))
        print(line("chromaP95", p95s))
        print(line("coloredFraction", coloreds))
        XCTAssertGreaterThan(p50s.count, 0, "calibration sample must not be empty")
    }

    // MARK: - acceptance: the same 18 frames, after the plan

    private func clipped(_ m: AutoColor.Metrics) -> Int {
        m.pixels.filter { Double($0.hslSaturation) >= 1 - AutoColor.saturationCeilingEpsilon }.count
    }

    /// The same measure → plan → re-measure loop `LoupeController.colorCandidate` runs, without UI.
    private func converge(_ g: RenderGraph, _ start: EditModel)
        throws -> (vibrance: Double, saturation: Double,
                   before: AutoColor.Metrics, after: AutoColor.Metrics, plan: AutoColor.Plan) {
        var edit = start
        let sourceV = start.color.vibrance
        let sourceS = start.color.saturation
        let before = AutoColor.metrics(from: try g.measureLinearSample(edit))
        var after = before
        var plan = AutoColor.plan2D(before, currentVibrance: sourceV, currentSaturation: sourceS,
                                    floorVibrance: sourceV, floorSaturation: sourceS)
        for _ in 0 ..< 3 {
            let v = max(sourceV, plan.vibrance)
            let s = max(sourceS, plan.saturation)
            guard abs(v - edit.color.vibrance) > 1e-9
                    || abs(s - edit.color.saturation) > 1e-9 else { break }
            edit.color.vibrance = v
            edit.color.saturation = s
            after = AutoColor.metrics(from: try g.measureLinearSample(edit))
            plan = AutoColor.plan2D(after, currentVibrance: v, currentSaturation: s,
                                    floorVibrance: sourceV, floorSaturation: sourceS)
        }
        return (edit.color.vibrance, edit.color.saturation, before, after, plan)
    }

    private func skinChange(_ a: AutoColor.Metrics, _ b: AutoColor.Metrics) -> (Double, Int) {
        func mean(_ m: AutoColor.Metrics) -> (Double, Int) {
            var sum = 0.0
            var n = 0
            for p in m.pixels where p.hueDegrees >= 50 && p.hueDegrees <= 70
                && Double(p.chroma) > HSLBands.chromaGate {
                sum += Double(p.chroma); n += 1
            }
            return (n > 0 ? sum / Double(n) : 0, n)
        }
        let (before, n) = mean(a)
        let (after, _) = mean(b)
        guard before > 1e-9 else { return (0, n) }
        return ((after - before) / before, n)
    }

    /// **改后表**：same frames, 2-D plan applied, re-measured through the pipeline.
    /// Opt in: `PHOTONS_ACCEPT_498=1 swift test --filter testAcceptance498`.
    func testAcceptance498() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_ACCEPT_498"] == "1" else {
            throw XCTSkip("set PHOTONS_ACCEPT_498=1 to run the 18-frame after table")
        }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        var rows: [Row] = fixtureRows()
        let fixtureStems = Set(Self.fixtureNames)
        let library = try editedRows().filter {
            FileManager.default.isReadableFile(atPath: $0.url.path)
                && !fixtureStems.contains(($0.url.lastPathComponent as NSString).deletingPathExtension)
        }
        for i in 0 ..< 12 where !library.isEmpty {
            let index = library.count == 1 ? 0 : Int(Double(i) * Double(library.count - 1) / 11.0)
            rows.append(library[index])
        }

        var vNonZero = 0
        var sNonZero = 0
        var p50Eligible = 0
        var p50Misses = 0
        var p95Eligible = 0
        var p95Misses = 0
        var clipMisses = 0
        var processed = 0
        print("498 ACCEPTANCE · target p50 \(AutoColor.targetChromaP50) · p95 \(AutoColor.targetChromaP95)")
        print("name\tp50\tp95\tv\ts\tp50'\tp95'\tnewClip\tskin")
        for row in rows {
            guard let g = try? graph(row.url),
                  let result = try? converge(g, row.edit) else { continue }
            processed += 1
            let m0 = result.before
            let m1 = result.after
            let newClipped = max(0, clipped(m1) - clipped(m0))
            let skin = skinChange(m0, m1).0
            if result.vibrance > row.edit.color.vibrance + 1e-9 { vNonZero += 1 }
            if result.saturation > row.edit.color.saturation + 1e-9 { sNonZero += 1 }
            // Only-raise: a frame already above a target is *correctly* left there. The p50 band is
            // only promised for frames the plan was allowed to move (not already above, not capped at
            // maxVibrance); the p95 bound only for frames that were not already above it.
            let p50EligibleRow = m0.chromaP50 < AutoColor.targetChromaP50
                && result.vibrance < AutoColor.maxVibrance - 0.01
            let p50OK = abs(m1.chromaP50 - AutoColor.targetChromaP50)
                <= AutoColor.targetChromaP50 * 0.05
            let p95EligibleRow = m0.chromaP95 <= AutoColor.targetChromaP95 * 1.05
            let p95OK = m1.chromaP95 <= AutoColor.targetChromaP95 * 1.05
            if p50EligibleRow { p50Eligible += 1; if !p50OK { p50Misses += 1 } }
            if p95EligibleRow { p95Eligible += 1; if !p95OK { p95Misses += 1 } }
            let clipBudget = Int((AutoColor.maxNewClippedFraction
                                  * Double(m0.sampleCount)).rounded(.down))
            if newClipped > clipBudget { clipMisses += 1 }
            print(String(format: "%@\t%.4f\t%.4f\t%+.2f\t%+.2f\t%.4f\t%.4f\t%d\t%+.1f%%",
                         row.name, m0.chromaP50, m0.chromaP95, result.vibrance, result.saturation,
                         m1.chromaP50, m1.chromaP95, newClipped, skin * 100))
        }
        let count = processed
        print("498 ACCEPTANCE · frames \(count) · v≠0 \(vNonZero) · s≠0 \(sNonZero) · "
              + "p50 eligible \(p50Eligible) miss \(p50Misses) · "
              + "p95 eligible \(p95Eligible) miss \(p95Misses) · clip miss \(clipMisses)")
        XCTAssertGreaterThan(vNonZero, count / 2, "多数样本的 vibrance 必须非零")
        XCTAssertGreaterThan(sNonZero, count / 2, "多数样本的 saturation 必须非零")
        XCTAssertEqual(p50Misses, 0, "可移动样本的 p50' 落在 target ±5%")
        XCTAssertEqual(p95Misses, 0, "未超标的样本 p95' ≤ target × 1.05")
        XCTAssertEqual(clipMisses, 0, "新增裁剪不超过 0.1% 预算")
    }

    /// Face and blue-sky guard acceptance. These two files live in the demo library, so the test is
    /// skipped on a machine without that library.
    func testSkinSkyGuard498() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_ACCEPT_498"] == "1" else {
            throw XCTSkip("set PHOTONS_ACCEPT_498=1 to run the face/sky guard")
        }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let candidates: [(String, String)] = [
            ("face", "\(NSString(string: "~/Desktop/boston").expandingTildeInPath)/L1040003.dng"),
            ("sky", "\(NSString(string: "~/Desktop/austria").expandingTildeInPath)/L1030684.dng"),
        ]
        for (kind, path) in candidates {
            guard FileManager.default.isReadableFile(atPath: path) else {
                print("498 GUARD · skip \(kind) (no \(path))")
                continue
            }
            let url = URL(fileURLWithPath: path)
            let g = try graph(url)
            let result = try converge(g, EditModel())
            let m0 = result.before
            let m1 = result.after
            var vibOnly = EditModel()
            vibOnly.color.vibrance = result.vibrance
            let m1v = AutoColor.metrics(from: try g.measureLinearSample(vibOnly))
            // The guard's contract is saturation's own contribution: vibrance-only → full plan.
            let (change, n) = skinChange(m1v, m1)
            print(String(format: "498 GUARD · %@ · s %.2f (unguarded %.2f) · skin n %d %+.1f%% · clip %d",
                         kind, result.saturation, result.plan.unguardedSaturation, n, change * 100,
                         max(0, clipped(m1) - clipped(m0))))
            XCTAssertLessThanOrEqual(result.saturation, result.plan.unguardedSaturation)
            if kind == "face" {
                XCTAssertLessThanOrEqual(change, AutoColor.maxSkinChromaChange + 1e-6,
                                         "肤色带平均彩度变化 ≤ 10%")
            }
        }
    }
}
