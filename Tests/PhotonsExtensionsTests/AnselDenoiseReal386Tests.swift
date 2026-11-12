import XCTest
import Foundation
@testable import PhotonsExtensions

/// §386 / §390 ⑧⑨ —— **真机端到端**：真工具 + 真模型 + 一张真的 60 MP DNG。
///
/// 判据，都是「不是没干活」的证据：
///
///   ⑧ 产物存在、同目录、且**几何 / CFA 相位 / 黑白电平与原图一致** —— 相位错一位整张图就是棋盘格，
///      所以这三项必须从产物的 tag 里读出来比对，不能只看「文件存在」；
///   ⑨ 降噪有效性 —— 在 raw 域取一块平坦暗区，量**相邻差方差**，降噪后必须显著小于原图。
///      ⑪⑫ 反向门靠的正是这一条：跳过 `denoise` 直接用原 mosaic 写 DNG 时，这个数字不会变；
///      把产物当原图时它会变大而不是变小。
///   **§390 ⑥⑦ —— 总耗时贴出来，且 `backend == "gpu"`。** 60 MP 上这两个数字是整张单的论点：
///      工具自己做 IO 之后总耗时应当接近它自报的 `seconds`（42 s 量级），而不是以前的 350 s；
///      而 `backend` 是 `cpu` 时那 42 s 会变成 7 分钟 —— 也就是 `--gpu` 没透传。
///
/// 需要环境变量，缺了是 `XCTSkip`（工具是可选扩展，装不上的机器也该能跑整套测试）：
///   `PHOTONS_TEST_DENOISE_RAW`  —— 一张 60 MP 的 capture DNG（例：~/Desktop/austria/L1030552.dng）
///   `PHOTONS_ANSEL_MODEL`       —— `.anselnn`；缺省时用 `AnselDenoiseLocation` 的四级解析
///   `ANSEL_DENOISE_SWIFT`       —— 可选，工具路径覆盖（同样有默认解析）
final class AnselDenoiseReal386Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-denoise386-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// One flat dark patch, measured in the raw domain.
    private struct Block {
        let x: Int, y: Int, size: Int
        let mean: Double
        /// Mean of squared horizontal neighbour differences — the high-frequency energy a denoiser
        /// has to remove. Texture raises it, so a *flat* block is the only honest probe.
        let adjacentDifferenceVariance: Double
    }

    private func block(_ samples: [UInt16], width: Int, _ x: Int, _ y: Int, size: Int) -> Block {
        var sum = 0.0
        var energy = 0.0
        var n = 0
        for row in y..<(y + size) {
            let base = row * width
            for col in x..<(x + size) {
                sum += Double(samples[base + col])
                let d = Double(samples[base + col]) - Double(samples[base + col + 1])
                energy += d * d
                n += 1
            }
        }
        return Block(x: x, y: y, size: size, mean: sum / Double(n),
                     adjacentDifferenceVariance: energy / Double(n))
    }

    // MARK: - tag reads (the host no longer computes these; the tests still have to *check* them)

    /// `33422 CFAPattern` → `"rggb"`. The host stopped computing this for the job (§390 passes the
    /// file and lets the tool read it), but 「产物的相位与原图一致」 is still a claim worth checking —
    /// and checking it from the tags is the only way that does not trust either side's arithmetic.
    private func cfaPattern(of doc: SourceDNG) -> String? {
        guard let entry = doc.raw[33422] ?? doc.ifd0[33422], entry.count == 4 else { return nil }
        let letters = entry.value.prefix(4).map { v -> Character in
            switch v {
            case 0: return "r"
            case 1: return "g"
            case 2: return "b"
            default: return "?"
            }
        }
        return letters.contains("?") ? nil : String(letters)
    }

    private func blackLevels(of doc: SourceDNG) -> [Double] {
        guard let entry = doc.raw[50714] ?? doc.ifd0[50714] else { return [] }
        switch entry.type {
        case 3:                                    // SHORT
            return stride(from: 0, to: entry.value.count - 1, by: 2).map {
                Double(UInt16(entry.value[$0]) | (UInt16(entry.value[$0 + 1]) << 8))
            }
        case 4:                                    // LONG
            return stride(from: 0, to: entry.value.count - 3, by: 4).map {
                Double(UInt32(entry.value[$0]) | (UInt32(entry.value[$0 + 1]) << 8)
                       | (UInt32(entry.value[$0 + 2]) << 16) | (UInt32(entry.value[$0 + 3]) << 24))
            }
        case 5:                                    // RATIONAL
            return stride(from: 0, to: entry.value.count - 7, by: 8).map {
                let num = Double(UInt32(entry.value[$0]) | (UInt32(entry.value[$0 + 1]) << 8)
                                 | (UInt32(entry.value[$0 + 2]) << 16) | (UInt32(entry.value[$0 + 3]) << 24))
                let den = Double(UInt32(entry.value[$0 + 4]) | (UInt32(entry.value[$0 + 5]) << 8)
                                 | (UInt32(entry.value[$0 + 6]) << 16) | (UInt32(entry.value[$0 + 7]) << 24))
                return den == 0 ? 0 : num / den
            }
        default:
            return []
        }
    }

    private func whiteLevel(of doc: SourceDNG) -> Double {
        double(doc.raw[50717] ?? doc.ifd0[50717])
    }

    private func double(_ entry: TIFFEntry?) -> Double {
        guard let entry else { return 0 }
        switch entry.type {
        case 3: return entry.value.count >= 2
            ? Double(UInt16(entry.value[0]) | (UInt16(entry.value[1]) << 8)) : 0
        case 4: return entry.value.count >= 4
            ? Double(UInt32(entry.value[0]) | (UInt32(entry.value[1]) << 8)
                     | (UInt32(entry.value[2]) << 16) | (UInt32(entry.value[3]) << 24)) : 0
        case 5: return entry.value.count >= 8
            ? { let n = Double(UInt32(entry.value[0]) | (UInt32(entry.value[1]) << 8)
                               | (UInt32(entry.value[2]) << 16) | (UInt32(entry.value[3]) << 24))
                let d = Double(UInt32(entry.value[4]) | (UInt32(entry.value[5]) << 8)
                               | (UInt32(entry.value[6]) << 16) | (UInt32(entry.value[7]) << 24))
                return d == 0 ? 0 : n / d }() : 0
        default: return 0
        }
    }

    // MARK: - ⑥ ⑦ the real run

    func testARealDenoiseKeepsTheGeometryAndActuallyRemovesNoise() throws {
        guard let rawPath = ProcessInfo.processInfo.environment["PHOTONS_TEST_DENOISE_RAW"],
              FileManager.default.fileExists(atPath: rawPath) else {
            throw XCTSkip("⑧ 没有 PHOTONS_TEST_DENOISE_RAW，跳过 60 MP 真跑")
        }
        var location = AnselDenoiseLocation()
        if let tool = ProcessInfo.processInfo.environment["ANSEL_DENOISE_SWIFT"] {
            location.executableURL = URL(fileURLWithPath: tool)
        }
        guard let model = location.resolvedModel() else {
            throw XCTSkip("⑧ 没有 .anselnn 模型（PHOTONS_ANSEL_MODEL 或 Application Support）")
        }
        let modelBytes = (try? FileManager.default.attributesOfItem(atPath: model.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        print("⑧ 工具 \(location.client()?.executableURL.path ?? "<missing>")")
        print("⑧ 模型 \(model.lastPathComponent) \(modelBytes / 1_048_576) MB")

        // Everything happens on a **copy** in a temp dir: the user's folder is not touched, and
        // "same directory" is still a real claim about the writer.
        let dir = workDir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("L1030552.dng")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: rawPath), to: source)

        let sourceData = try Data(contentsOf: source, options: .alwaysMapped)
        let sourceDoc = try SourceDNG(data: sourceData)
        let original = try sourceDoc.readMosaic(data: sourceData)
        let originalBlacks = blackLevels(of: sourceDoc)
        let originalWhite = whiteLevel(of: sourceDoc)
        let originalCFA = cfaPattern(of: sourceDoc)
        print("⑧ 原图 \(original.width)×\(original.height) cfa=\(originalCFA ?? "nil") "
              + "black=\(originalBlacks) white=\(originalWhite)")

        let job = AnselDenoiseJob(location: AnselDenoiseLocation(modelURL: model, variant: .quarter))
        let started = Date()
        let outcome = try job.run(source: source) { print("   … \($0)") }
        let elapsed = Date().timeIntervalSince(started)

        // ⑥ 总耗时 —— 这是本单的论点。分工必须能被看出：总耗时 ≈ 工具自报的 seconds，差额只是
        // 一次 rename 和一次 JSON 解析，而不是 284 s 的样本搬运。
        let overhead = elapsed - outcome.seconds
        print(String(format: "⑥ 60 MP 总耗时 %.2f s · 工具自报 %.2f s · 宿主开销 %.2f s（%.1f%%）",
                     elapsed, outcome.seconds, overhead,
                     outcome.seconds > 0 ? overhead / outcome.seconds * 100 : 0))
        print("⑥ 产物 \(outcome.output.lastPathComponent) \(outcome.width)×\(outcome.height) "
              + "cfa=\(outcome.cfa) pieces=\(outcome.pieces) seams=\(outcome.seams) "
              + "backend=\(outcome.backend) bytes=\(outcome.byteCount)")
        // ⑦ — 工具的 backend 必须原样透出来，且必须是 gpu。cpu 意味着 --gpu 没到工具手里，
        // 那 42 s 会变 7 分钟。
        XCTAssertEqual(outcome.backend, "gpu", "⑦ backend 必须是 gpu；cpu 说明 --gpu 没透传")
        XCTAssertGreaterThan(outcome.seconds, 0)
        XCTAssertLessThan(elapsed, 120,
                          "⑥ 60 MP 总耗时必须是 42 s 量级，不是 350 s；实测 \(elapsed) s")
        XCTAssertLessThan(overhead, max(5, outcome.seconds * 0.25),
                          "⑥ 宿主侧只该剩 rename + JSON；实测多花了 \(overhead) s")

        // ⑧ — the product is a legal DNG whose geometry/CFA/levels came from the source.
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.output.path))
        XCTAssertEqual(outcome.output.deletingLastPathComponent().standardizedFileURL,
                       dir.standardizedFileURL, "⑧ 同目录")
        XCTAssertEqual(outcome.output.lastPathComponent, "L1030552-denoised.dng")

        let productData = try Data(contentsOf: outcome.output, options: .alwaysMapped)
        let productDoc = try SourceDNG(data: productData)
        let product = try productDoc.readMosaic(data: productData)
        let productBlacks = blackLevels(of: productDoc)
        let productWhite = whiteLevel(of: productDoc)
        let productCFA = cfaPattern(of: productDoc)
        print("⑧ 产物 tag：\(product.width)×\(product.height) cfa=\(productCFA ?? "nil") "
              + "black=\(productBlacks) white=\(productWhite) "
              + "compression=\(productDoc.ifd0[259]?.firstUInt32 ?? 0) "
              + "photometric=\(productDoc.ifd0[262]?.firstUInt32 ?? 0)")

        XCTAssertEqual(product.width, original.width, "⑧ 宽度必须相同")
        XCTAssertEqual(product.height, original.height, "⑧ 高度必须相同")
        XCTAssertEqual(productCFA, originalCFA, "⑧ CFA 相位必须相同（差一位就是棋盘格）")
        XCTAssertEqual(productBlacks, originalBlacks, "⑧ 黑电平必须相同")
        XCTAssertEqual(productWhite, originalWhite, "⑧ 白电平必须相同")
        XCTAssertEqual(productDoc.ifd0[262]?.firstUInt32, 32803, "⑧ 仍是 CFA 图")
        XCTAssertEqual(productDoc.ifd0[259]?.firstUInt32, 7, "⑧ SOF3 压缩")
        // No temporary file survives a successful run either — the rename is the only trace.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".denoise-") }
        XCTAssertTrue(leftovers.isEmpty, "⑧ 成功后不许留下临时文件：\(leftovers)")

        // ⑨ — a flat dark block, same coordinates in both files. The search walks a diagonal grid and
        // keeps the darkest block that is still flat, so the probe is "shadow noise", not "a wall".
        let size = 256
        var darkest = block(original.samples, width: original.width, size, size, size: size)
        for k in 1...11 {
            let x = min(original.width - size - 1, size * 2 * k)
            let y = min(original.height - size - 1, size * 2 * k)
            let candidate = block(original.samples, width: original.width, x, y, size: size)
            if candidate.mean < darkest.mean { darkest = candidate }
        }
        let after = block(product.samples, width: product.width, darkest.x, darkest.y, size: size)
        print("⑨ 平坦暗块 (\(darkest.x),\(darkest.y)) \(size)²："
              + "均值 \(String(format: "%.1f", darkest.mean)) → \(String(format: "%.1f", after.mean))，"
              + "相邻差方差 \(String(format: "%.1f", darkest.adjacentDifferenceVariance)) → "
              + "\(String(format: "%.1f", after.adjacentDifferenceVariance))")
        let ratio = darkest.adjacentDifferenceVariance == 0
            ? 1 : after.adjacentDifferenceVariance / darkest.adjacentDifferenceVariance
        print("⑨ 比值 = \(String(format: "%.3f", ratio))（< 1 表示高频能量下降）")
        XCTAssertLessThan(ratio, 0.75,
                          "⑨ 暗部高频能量必须显著下降（比值 \(ratio)）；≈1 意味着根本没降噪")
        // On a block this close to black the *mean* is allowed to move: half the noise sits below the
        // floor and was clipped, so averaging it away lowers the mean by construction. What must stay
        // put is a midtone, where nothing is clipped — that is where 「亮度保持」 is measurable.
        let range = originalWhite - (originalBlacks.first ?? 0)
        let midBlock = block(original.samples, width: original.width, original.width / 2,
                             original.height / 2, size: size)
        let midAfter = block(product.samples, width: product.width, midBlock.x, midBlock.y, size: size)
        let midRatio = midBlock.adjacentDifferenceVariance == 0
            ? 1 : midAfter.adjacentDifferenceVariance / midBlock.adjacentDifferenceVariance
        print("⑨ 中间调块 (\(midBlock.x),\(midBlock.y))：均值 "
              + "\(String(format: "%.1f", midBlock.mean)) → \(String(format: "%.1f", midAfter.mean))"
              + "（噪声码 \(String(format: "%.1f", (midBlock.adjacentDifferenceVariance).squareRoot()))），"
              + "相邻差方差 \(String(format: "%.1f", midBlock.adjacentDifferenceVariance)) → "
              + "\(String(format: "%.1f", midAfter.adjacentDifferenceVariance))，"
              + "比值 \(String(format: "%.3f", midRatio))")
        XCTAssertEqual(midAfter.mean, midBlock.mean,
                       accuracy: max(4, range * 0.02),
                       "⑨ 中间调不许整体压暗/提亮（亮度保持是契约）")

        // Hand the product to `photonsctl info` / a library probe when the caller asks for it: the
        // temp dir is removed in `tearDown`, and §3 ⑧ wants the tool's own read of the file.
        if let keep = ProcessInfo.processInfo.environment["PHOTONS_TEST_DENOISE_KEEP"],
           !keep.isEmpty {
            let target = URL(fileURLWithPath: (keep as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: outcome.output, to: target)
            print("⑧ 产物已留一份：\(target.path)")
        }
    }
}
