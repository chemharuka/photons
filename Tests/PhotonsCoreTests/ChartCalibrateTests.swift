import XCTest
import CoreImage
import CoreGraphics
import Foundation
@testable import PhotonsCore

/// 合成图卡体检 — 解码器把仓库里那张 256 格图卡解得对不对。
///
/// 默认 **skip**：`make verify` 不受影响。打开开关才跑，而且只读仓库夹具，**不需要 dnglab**：
///
/// ```bash
/// PHOTONS_CHART_CALIBRATE=1 swift test --filter ChartCalibrate
/// ```
///
/// 被判的是今天这台 macOS 的 `CIRAWFilter`：
///
///  1. 容器被接受（`supportedDecoderVersions` 非空、`outputImage != nil`）；
///  2. 16×16 的 256 格都能分层（512×512，16×16 格 × 32 px，取中心 8×8，σ ≤ 2）；
///  3. 中性 32 格（行 0–1）色偏 ≤ 8/255，亮度随格号单调不减（允许 −1 抖动）；
///  4. 224 个色块里 ≥ 200 个 8-bit 三元组互不相同。
///
/// 失败信息带实测三元组：升级 macOS 后如果中性点漂了，读断言就知道漂了多少。
final class ChartCalibrateTests: XCTestCase {

    private let grid = 16
    private let inner = 8
    private let decodeTemperature: Float = 6500

    private var chartURL: URL {
        // <repo>/Tests/PhotonsCoreTests/ChartCalibrateTests.swift → <repo>/tools/wb-calibrate/chart256.dng
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tools/wb-calibrate/chart256.dng")
    }

    func testSyntheticChartDecodesToSpec() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_CHART_CALIBRATE"] == "1" else {
            throw XCTSkip("PHOTONS_CHART_CALIBRATE=1 才跑；需要 dnglab/图卡检查")
        }
        let url = chartURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return XCTFail("图卡夹具不存在：\(url.path)")
        }

        // ① 容器被这个 macOS 的 RAW 解码器接受 -------------------------------------------------
        guard let raw = CIRAWFilter(imageURL: url) else {
            return XCTFail("CIRAWFilter(imageURL:) == nil：这台机器拒绝解码 \(url.lastPathComponent)")
        }
        XCTAssertFalse(raw.supportedDecoderVersions.isEmpty,
                       "supportedDecoderVersions 为空：今天这个 macOS 的 RAW 解码器不接受图卡容器")
        guard raw.outputImage != nil else {
            return XCTFail("outputImage == nil（nativeSize \(raw.nativeSize)）：容器被接受但没有像素")
        }

        raw.neutralTemperature = decodeTemperature
        raw.neutralTint = 0
        guard let image = raw.outputImage else {
            return XCTFail("设置 \(Int(decodeTemperature)) K / tint 0 后 outputImage == nil")
        }
        let frame = try render(image)
        guard frame.width == grid * 32, frame.height == grid * 32 else {
            return XCTFail("解码尺寸 \(frame.width)×\(frame.height)，期望 \(grid * 32)×\(grid * 32)")
        }

        // ② 16×16 网格，每格中心 8×8 ----------------------------------------------------------
        let cell = frame.width / grid
        let offset = (cell - inner) / 2
        var mean = Array(repeating: Array(repeating: (r: 0.0, g: 0.0, b: 0.0), count: grid), count: grid)
        var maxSigma = 0.0
        var worstSigmaCell = (0, 0)
        for row in 0..<grid {
            for col in 0..<grid {
                var sum = (0.0, 0.0, 0.0)
                var sumSq = (0.0, 0.0, 0.0)
                let count = Double(inner * inner)
                for dy in 0..<inner {
                    for dx in 0..<inner {
                        let x = col * cell + offset + dx
                        let y = row * cell + offset + dy
                        let p = frame.pixel(x, y)
                        let r = Double(p.0), g = Double(p.1), b = Double(p.2)
                        sum.0 += r; sum.1 += g; sum.2 += b
                        sumSq.0 += r * r; sumSq.1 += g * g; sumSq.2 += b * b
                    }
                }
                let m = (sum.0 / count, sum.1 / count, sum.2 / count)
                mean[row][col] = m
                let variance = max(sumSq.0 / count - m.0 * m.0,
                                   max(sumSq.1 / count - m.1 * m.1, sumSq.2 / count - m.2 * m.2))
                let sigma = variance.squareRoot()
                if sigma > maxSigma { maxSigma = sigma; worstSigmaCell = (row, col) }
            }
        }
        XCTAssertLessThanOrEqual(maxSigma, 2.0, String(
            format: "格 (row %d, col %d) 内 σ = %.2f（上限 2）：格内不稳定，坐标/取向或解码纹理有变；实测中心 8×8 均值 %@",
            worstSigmaCell.0, worstSigmaCell.1, maxSigma,
            triple(mean[worstSigmaCell.0][worstSigmaCell.1])))

        // ③ 中性 32 格（行 0–1）：色偏 ≤ 8，亮度单调不减（−1 抖动） ----------------------------
        var neutral: [(r: Double, g: Double, b: Double)] = []
        for row in 0..<2 { for col in 0..<grid { neutral.append(mean[row][col]) } }
        var worstChroma = 0.0
        var worstChromaIndex = 0
        for (i, p) in neutral.enumerated() {
            let chroma = max(p.r, max(p.g, p.b)) - min(p.r, min(p.g, p.b))
            if chroma > worstChroma { worstChroma = chroma; worstChromaIndex = i }
        }
        XCTAssertLessThanOrEqual(worstChroma, 8.0, String(
            format: "今天这个 macOS 版本的 RAW 解码把中性点解偏了：中性第 %d 格实测 %@，色偏 %.0f/255（上限 8）",
            worstChromaIndex, triple(neutral[worstChromaIndex]), worstChroma))

        for i in 1..<neutral.count {
            let prev = neutral[i - 1], cur = neutral[i]
            let step = (cur.r + cur.g + cur.b) / 3 - (prev.r + prev.g + prev.b) / 3
            XCTAssertGreaterThanOrEqual(step, -1.0, String(
                format: "中性灰阶在格 %d → %d 掉头：%@ → %@（亮度步长 %+.1f，允许 −1）",
                i - 1, i, triple(prev), triple(cur), step))
        }

        // ④ 224 个色块：≥200 个 8-bit 三元组互不相同 ------------------------------------------
        var distinct = Set<[Int]>()
        for row in 2..<grid {
            for col in 0..<grid {
                let p = mean[row][col]
                distinct.insert([Int(p.r.rounded()), Int(p.g.rounded()), Int(p.b.rounded())])
            }
        }
        XCTAssertGreaterThanOrEqual(distinct.count, 200,
                                    "224 个色块只有 \(distinct.count) 个互不相同的 8-bit 三元组（下限 200）")
    }

    // MARK: - helpers

    private func triple(_ p: (r: Double, g: Double, b: Double)) -> String {
        String(format: "%.0f/%.0f/%.0f", p.r, p.g, p.b)
    }

    private struct Frame {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        /// PNG 行序（第 0 行 = 文件顶行）。CGContext 的位图内存在这里按顶行在前落盘，
        /// 与 `probe2.swift` 写出的 PNG 一致（`verify_chart.py` 已按同一行序验过）。
        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2])
        }
    }

    private struct RenderError: Error, CustomStringConvertible { let description: String }

    private func render(_ image: CIImage) throws -> Frame {
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        let extent = image.extent
        let w = Int(extent.width), h = Int(extent.height)
        guard let cg = ctx.createCGImage(image, from: extent) else {
            throw RenderError(description: "CIContext.createCGImage 返回 nil（extent \(extent)）")
        }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        try bytes.withUnsafeMutableBytes { p in
            guard let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw RenderError(description: "CGContext 创建失败（\(w)×\(h)）")
            }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Frame(width: w, height: h, bytes: bytes)
    }
}
