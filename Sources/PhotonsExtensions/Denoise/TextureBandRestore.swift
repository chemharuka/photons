//
//  TextureBandRestore.swift
//  562 — 降噪后按窄带「织纹恢复」把画布纹理加回来
//
//  两条引擎（宿主内 nonlocal、子进程 ansel）都把原图的**窄带周期性纹理**当成噪声抹掉了：
//  denoise 的混合 `out = in + s·(d − in)` 没有频率分辨力，画布的 3–4 plane-px 织纹和颗粒
//  落在同一个亮度/方差桶里。区域门控 strength 会在区域边界留下接缝（用户已在 L1040080 上判死），
//  所以这里换一个轴：**在频域把被抹掉的窄带还回去**，权重连续、窗与窗之间靠 Hann² 重叠相加
//  自然过渡，不做任何硬切换。
//
//  域是 mosaic 而不是 plane 图：CFA 的 2×2 采样会把各平面的高频折叠到别处，直接在一张
//  mosaic 上做带通等于把四个平面的谱混在一起。因此四个 CFA 平面各自进出（`PackedLayout`
//  的四个 offset），逐平面检测/恢复后再交错写回。
//
//  输入 `source` 是原图（含织纹），`product` 是降噪产物；`band = source − product` 就是
//  被抹掉的那一层。检测只在 `source` 上做：产物的谱线正是我们想找回来的，不能在它上面找。
//

import Foundation
import Accelerate
import Dispatch
import NonlocalMatchFilter

// MARK: - 选项 / 报告

public struct TextureBandRestoreOptions: Sendable {
    /// 窗边长，**plane 像素**。必须是 2 的幂（FFT 的要求）；不是时会向下取到最近的 2 的幂。
    ///
    /// 512/384 是实测选的：L1040080 上三个配置的宽带颗粒都是 0.94–0.95σ，但织纹线恢复差异很大
    /// （原图 0.070σ）—— 512/256 只到 0.043σ（71 % 的带被窗间相位抵消掉），512/384 到 0.068σ
    /// （97 %），256/192 到 0.065σ（93 %）但要 1700 窗、且 25 % 重叠下窗界权重台阶 0.059 超过
    /// 测试 (c) 的 0.02。⇒ 512/384：97 % 恢复、14.2 s、权重台阶通过。
    public var window: Int = 512
    /// 窗步长，plane 像素；默认 25 % 重叠（512 → 384）。
    public var hop: Int = 384
    /// 带通高斯的半径，单位 cyc/plane-px。
    public var bandSigma: Double = 0.04
    /// 候选谱线的最低 / 最高空间频率，单位 cyc/plane-px。
    public var minFrequency: Double = 0.10
    public var maxFrequency: Double = 0.45
    /// `smoothstep(excessLow, excessHigh, …)` 的两个拐点。
    public var excessLow: Double = 3.0
    public var excessHigh: Double = 10.0
    public var enabled: Bool = true
    /// `false` 时只算不写（验收 CLI 的 `denoise-band` 不带 `--out` 用它）。
    public var writeProduct: Bool = true

    public init() {}
}

public struct TextureBandRestoreReport: Sendable {
    public let windows: Int
    public let meanWeight: Double
    public let medianPeriodPlanePx: Double
    public let addedRMS: Double
    public let seconds: Double
    public let planes: Int
    /// 读不出 / 几何或 CFA 不匹配时为 `true`；降噪本身不应因此失败。
    public let skipped: Bool
    public let note: String?

    static func skipped(_ note: String, seconds: Double) -> TextureBandRestoreReport {
        TextureBandRestoreReport(windows: 0, meanWeight: 0, medianPeriodPlanePx: 0,
                                 addedRMS: 0, seconds: seconds, planes: 0,
                                 skipped: true, note: note)
    }
}

// MARK: - 入口

public enum TextureBandRestore {

    /// 把 `source` 里被 `product` 抹掉的窄带纹理加回 `product`（**原地**改写 `product`，
    /// 但先写临时名再改名，失败不会留下半个文件）。几何/CFA 不匹配时返回 `skipped` 报告，
    /// 不抛错——恢复层是增益，不是降噪的前置条件。
    @discardableResult
    public static func apply(source: URL,
                             product: URL,
                             options: TextureBandRestoreOptions = .init(),
                             progress: ((String) -> Void)? = nil) throws -> TextureBandRestoreReport {
        let start = Date()
        guard options.enabled else {
            progress?("织纹恢复：关闭")
            return .skipped("关闭", seconds: Date().timeIntervalSince(start))
        }

        let sourceData: Data
        let productData: Data
        do {
            sourceData = try Data(contentsOf: source, options: .alwaysMapped)
            productData = try Data(contentsOf: product, options: .alwaysMapped)
        } catch {
            let note = "读不出文件（\(error.localizedDescription)）"
            progress?("织纹恢复：跳过（\(note)）")
            return .skipped(note, seconds: Date().timeIntervalSince(start))
        }

        let sourceDoc: SourceDNG
        let productDoc: SourceDNG
        let sourceMosaic: (samples: [UInt16], width: Int, height: Int)
        let productMosaic: (samples: [UInt16], width: Int, height: Int)
        do {
            sourceDoc = try SourceDNG(data: sourceData)
            productDoc = try SourceDNG(data: productData)
            sourceMosaic = try sourceDoc.readMosaic(data: sourceData)
            productMosaic = try productDoc.readMosaic(data: productData)
        } catch {
            let note = "读不出 mosaic（\(error)）"
            progress?("织纹恢复：跳过（\(note)）")
            return .skipped(note, seconds: Date().timeIntervalSince(start))
        }

        guard sourceMosaic.width == productMosaic.width,
              sourceMosaic.height == productMosaic.height else {
            let note = "尺寸不同（\(sourceMosaic.width)×\(sourceMosaic.height) vs "
                     + "\(productMosaic.width)×\(productMosaic.height)）"
            progress?("织纹恢复：跳过（\(note)）")
            return .skipped(note, seconds: Date().timeIntervalSince(start))
        }

        let sourceNorm: Normalization
        let productNorm: Normalization
        let sourceCFA: String
        let productCFA: String
        do {
            sourceNorm = try Normalization(doc: sourceDoc)
            productNorm = try Normalization(doc: productDoc)
            sourceCFA = try cfa(of: sourceDoc)
            productCFA = try cfa(of: productDoc)
        } catch {
            let note = "缺黑/白电平或 CFA（\(error)）"
            progress?("织纹恢复：跳过（\(note)）")
            return .skipped(note, seconds: Date().timeIntervalSince(start))
        }

        guard sourceCFA == productCFA else {
            let note = "CFA 不同（\(sourceCFA) vs \(productCFA)）"
            progress?("织纹恢复：跳过（\(note)）")
            return .skipped(note, seconds: Date().timeIntervalSince(start))
        }
        guard sourceCFA.count == 4,
              sourceCFA.filter({ $0 == "g" }).count == 2,
              sourceCFA.contains("r"), sourceCFA.contains("b") else {
            let note = "不支持的 CFA（\(sourceCFA)）"
            progress?("织纹恢复：跳过（\(note)）")
            return .skipped(note, seconds: Date().timeIntervalSince(start))
        }

        // 逐值相同：没有任何被抹掉的层。直接返回，产物一个字节都不动（§3 d）。
        if sourceMosaic.samples == productMosaic.samples {
            let seconds = Date().timeIntervalSince(start)
            progress?(summaryLine(windows: 0, meanWeight: 0, medianPeriod: 0, seconds: seconds))
            return TextureBandRestoreReport(windows: 0, meanWeight: 0, medianPeriodPlanePx: 0,
                                            addedRMS: 0, seconds: seconds, planes: 4,
                                            skipped: false, note: "源与产物逐值相同")
        }

        let width = sourceMosaic.width
        let height = sourceMosaic.height
        let layout = PackedLayout(cfa: sourceCFA)

        var newSamples = productMosaic.samples
        var totalWindows = 0
        var weightSum = 0.0
        var periods: [Double] = []
        var addedEnergy = 0.0
        var addedCount = 0

        struct PlaneInput {
            let dy: Int
            let dx: Int
            let width: Int
            let height: Int
            let source: [Double]
            let product: [Double]
        }

        var inputs: [PlaneInput] = []
        inputs.reserveCapacity(layout.offsets.count)
        for (dy, dx) in layout.offsets {
            let planeW = (width - dx + 1) / 2
            let planeH = (height - dy + 1) / 2
            guard planeW > 0, planeH > 0 else { continue }

            var srcPlane = [Double](repeating: 0, count: planeW * planeH)
            var prodPlane = [Double](repeating: 0, count: planeW * planeH)
            for r in 0..<planeH {
                let row = (dy + 2 * r) * width + dx
                let planeRow = r * planeW
                for c in 0..<planeW {
                    let idx = row + 2 * c
                    srcPlane[planeRow + c] = sourceNorm.normalize(sourceMosaic.samples[idx],
                                                                  row: dy + 2 * r, col: dx + 2 * c)
                    prodPlane[planeRow + c] = productNorm.normalize(productMosaic.samples[idx],
                                                                    row: dy + 2 * r, col: dx + 2 * c)
                }
            }
            inputs.append(PlaneInput(dy: dy, dx: dx, width: planeW, height: planeH,
                                     source: srcPlane, product: prodPlane))
        }

        // 四个 CFA 平面彼此独立；60 MP 上单平面 ~12 s，四核并行才进得了 10 s 预算。
        let results = UnsafeMutablePointer<PlaneResult?>.allocate(capacity: inputs.count)
        results.initialize(repeating: nil, count: inputs.count)
        defer {
            results.deinitialize(count: inputs.count)
            results.deallocate()
        }
        DispatchQueue.concurrentPerform(iterations: inputs.count) { index in
            let input = inputs[index]
            results[index] = restorePlane(source: input.source, product: input.product,
                                          width: input.width, height: input.height,
                                          options: options)
        }

        for index in inputs.indices {
            guard let result = results[index] else { continue }
            let input = inputs[index]
            let dy = input.dy, dx = input.dx
            let planeW = input.width, planeH = input.height
            totalWindows += result.windows
            weightSum += result.weightSum
            periods.append(contentsOf: result.periods)

            for r in 0..<planeH {
                let row = (dy + 2 * r) * width + dx
                let planeRow = r * planeW
                for c in 0..<planeW {
                    let normalized = result.output[planeRow + c]
                    newSamples[row + 2 * c] = productNorm.denormalize(normalized,
                                                                      row: dy + 2 * r, col: dx + 2 * c)
                    let d = result.deltas[planeRow + c]
                    addedEnergy += d * d
                    addedCount += 1
                }
            }
        }

        let addedRMS = addedCount > 0 ? (addedEnergy / Double(addedCount)).squareRoot() : 0
        let meanWeight = totalWindows > 0 ? weightSum / Double(totalWindows) : 0

        if options.writeProduct {
            let fm = FileManager.default
            let tmp = product.deletingLastPathComponent()
                .appendingPathComponent(".band-\(UUID().uuidString).dng")
            defer { try? fm.removeItem(at: tmp) }
            _ = try DNGRawWriter.write(samples: newSamples, width: width, height: height,
                                       from: product, to: tmp)
            try? fm.removeItem(at: product)
            try fm.moveItem(at: tmp, to: product)
        }

        let seconds = Date().timeIntervalSince(start)
        let medianPeriod = median(periods)
        progress?(summaryLine(windows: totalWindows, meanWeight: meanWeight,
                              medianPeriod: medianPeriod, seconds: seconds))
        return TextureBandRestoreReport(windows: totalWindows, meanWeight: meanWeight,
                                        medianPeriodPlanePx: medianPeriod,
                                        addedRMS: addedRMS, seconds: seconds,
                                        planes: layout.offsets.count, skipped: false, note: nil)
    }

    private static func summaryLine(windows: Int, meanWeight: Double,
                                    medianPeriod: Double, seconds: Double) -> String {
        String(format: "织纹恢复：%d 窗、平均权重 %.2f、周期 %.1f px、+%.1f s",
               windows, meanWeight, medianPeriod, seconds)
    }

    // MARK: - 一个平面的频带恢复

    struct PlaneResult {
        var output: [Double]
        var deltas: [Double]
        /// 每个像素的有效权重 `Σ w·Hann⁴ / Σ Hann⁴`，给接缝测试用。
        var weights: [Double]
        var windows: Int
        var weightSum: Double
        var periods: [Double]
    }

    /// `source` / `product` 是同一个 CFA 平面的归一化值（`[0,1]` 附近）。
    ///
    /// - 检测在 `source` 上做：`product` 正是缺了这条谱线的那个。
    /// - `band = source − product`，在频域只留 `±f*` 附近半径 `bandSigma` 的高斯。
    /// - 重叠相加用 Hann² 归一化：分子 `Σ w·H·band`、分母 `Σ w·H²`，所以窗界处不会出现
    ///   权重台阶，也不会因为补零而变暗。
    static func restorePlane(source: [Double],
                             product: [Double],
                             width: Int,
                             height: Int,
                             options: TextureBandRestoreOptions) -> PlaneResult {
        let side = min(width, height)
        var n = min(options.window, side)
        if n < 4 { n = 0 }
        if n > 0 {
            var p = 1
            while p * 2 <= n { p *= 2 }
            n = p
        }
        guard n >= 8 else {
            return PlaneResult(output: product, deltas: [Double](repeating: 0, count: product.count),
                               weights: [Double](repeating: 0, count: product.count),
                               windows: 0, weightSum: 0, periods: [])
        }

        let hop = max(1, min(options.hop, n))
        let log2n = vDSP_Length(round(log2(Double(n))))
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
            return PlaneResult(output: product, deltas: [Double](repeating: 0, count: product.count),
                               weights: [Double](repeating: 0, count: product.count),
                               windows: 0, weightSum: 0, periods: [])
        }
        defer { vDSP_destroy_fftsetupD(setup) }

        // 检测用 Hann²（谱估计的窗），重叠相加用 Hann：分析/合成都是 Hann，分母
        // `Σ Hann²` 就是规格里的「以 Hann² 归一化」。若把 Hann² 再平方成 Hann⁴，
        // 权重场在 50 % 重叠下最陡处的逐像素斜率达到 0.025，超过 §3(c) 的 0.02。
        var olaWindow = [Double](repeating: 0, count: n * n)
        var detectionWindow = [Double](repeating: 0, count: n * n)
        let denom = Double(max(n - 1, 1))
        var hann = [Double](repeating: 0, count: n)
        for i in 0..<n {
            hann[i] = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / denom)
        }
        for y in 0..<n {
            for x in 0..<n {
                let h = hann[y] * hann[x]
                olaWindow[y * n + x] = h
                // 检测窗用 Hann（相干增益比 Hann² 高 ~1.7×）：Hann² 虽然谱更集中，
                // 但一条 3–4 px 的织纹线在 512² 窗里本来就只有 ~20× 基线，再压一次
                // 会把真实画布窗推到 0.1–0.2 权重。
                detectionWindow[y * n + x] = h
            }
        }

        var num = [Double](repeating: 0, count: width * height)
        /// 所有窗的 `Σ Hann⁴`（**包括权重为 0 的窗**）。它是重叠相加的分母，也是权重图
        /// 的分母；把 0 权重窗留在里面，窗与窗交界处的权重才会连续地趋近 0，而不是在
        /// 一只窗的 Hann² 端点突然掉一档。
        var coverage = [Double](repeating: 0, count: width * height)
        var wnum = [Double](repeating: 0, count: width * height)

        var bandRe = [Double](repeating: 0, count: n * n)
        var bandIm = [Double](repeating: 0, count: n * n)
        var detRe = [Double](repeating: 0, count: n * n)
        var detIm = [Double](repeating: 0, count: n * n)

        let detectionTables = DetectionTables(n: n, options: options)
        let detectionWorkspace = DetectionWorkspace(n: n)
        let gaussTable = gaussianMaskTable(n: n, sigma: options.bandSigma)

        var windows = 0
        var weightSum = 0.0
        var periods: [Double] = []

        let xs = starts(length: width, window: n, hop: hop)
        let ys = starts(length: height, window: n, hop: hop)

        for y0 in ys {
            for x0 in xs {
                windows += 1

                // 高频检测只在 source 上做。
                fillHighPassedWindow(source: source, width: width, x0: x0, y0: y0,
                                     n: n, window: detectionWindow, re: &detRe, im: &detIm)
                fft2(setup: setup, log2n: log2n, re: &detRe, im: &detIm,
                     n: n, inverse: false)
                let detection = detectLine(re: detRe, im: detIm,
                                           tables: detectionTables,
                                           workspace: detectionWorkspace,
                                           options: options)
                let w = detection.weight
                weightSum += w
                if w > 0.5, detection.frequency > 0 {
                    periods.append(1 / detection.frequency)
                }

                // 分母对所有窗都要累加，包括 w = 0 的窗。
                for y in 0..<n {
                    let outRow = (y0 + y) * width + x0
                    let winRow = y * n
                    for x in 0..<n {
                        let h = olaWindow[winRow + x]
                        coverage[outRow + x] += h * h
                    }
                }
                if w <= 1e-4 {
                    continue
                }

                // band = source − product，频域只留 ±f* 附近的高斯。
                for y in 0..<n {
                    let srcRow = (y0 + y) * width + x0
                    let dstRow = y * n
                    for x in 0..<n {
                        let i = srcRow + x
                        let j = dstRow + x
                        bandRe[j] = (source[i] - product[i]) * olaWindow[j]
                        bandIm[j] = 0
                    }
                }
                fft2(setup: setup, log2n: log2n, re: &bandRe, im: &bandIm,
                     n: n, inverse: false)
                applyBandMask(re: &bandRe, im: &bandIm, n: n,
                              binX: detection.binX, binY: detection.binY,
                              signed: detectionTables.signedOffsets,
                              gauss: gaussTable)
                fft2(setup: setup, log2n: log2n, re: &bandRe, im: &bandIm,
                     n: n, inverse: true)

                // 重叠相加：分子 `Σ w·H·band`，分母 `Σ H²`（所有窗）。vDSP 的 2D 逆变换
                // 不做 1/N²，这里补上。
                let invN2 = 1 / Double(n * n)
                for y in 0..<n {
                    let outRow = (y0 + y) * width + x0
                    let winRow = y * n
                    for x in 0..<n {
                        let h = olaWindow[winRow + x]
                        let oi = outRow + x
                        let bi = winRow + x
                        num[oi] += w * h * bandRe[bi] * invN2
                        wnum[oi] += w * h * h
                    }
                }
            }
        }

        var output = product
        var deltas = [Double](repeating: 0, count: product.count)
        var weights = [Double](repeating: 0, count: product.count)
        for i in output.indices {
            let cov = coverage[i]
            // Hann² 的最外几圈 Hann⁴ 会小到 ~1e-15；那里逆变换的舍入误差已经和真实
            // 信号同量级，`num/cov` 会炸。给**叠加分母**一个 1e-6 的下限：只碰到图像最外
            // ~15 px（本来就在 ActiveArea 之外），内部窗界的覆盖由相邻窗叠到 ~1，完全不受
            // 影响。权重图不含 FFT，直接除以真实覆盖即可，所以它在窗界处是连续的。
            let delta = num[i] / max(cov, 1e-6)
            deltas[i] = delta
            let value = product[i] + delta
            output[i] = min(max(value, 0), 1)
            weights[i] = cov > 0 ? wnum[i] / cov : 0
        }

        return PlaneResult(output: output, deltas: deltas, weights: weights,
                           windows: windows, weightSum: weightSum, periods: periods)
    }

    /// 窗起点：从 0 开始每 `hop` 一个，最后一扇贴住右/下边（不留未覆盖的尾巴）。
    private static func starts(length: Int, window: Int, hop: Int) -> [Int] {
        guard length > window else { return [0] }
        var out: [Int] = []
        var s = 0
        while s + window <= length {
            out.append(s)
            s += hop
        }
        if let last = out.last, last + window < length {
            out.append(length - window)
        }
        return out
    }

    private static func fillHighPassedWindow(source: [Double], width: Int,
                                             x0: Int, y0: Int, n: Int,
                                             window: [Double],
                                             re: inout [Double], im: inout [Double]) {
        // Immerkaer [[1,-2,1],[-2,4,-2],[1,-2,1]] 加一点各向同性 Laplacian：
        // Immerkaer 是**可分离**高通，沿任一轴的常值响应严格为 0，也就是说 90° 的
        // 竖织纹（本单实拍那一条恰好就是 90°）会被它整个抹掉。加 `α·Laplacian`
        // 只改 null space，主响应仍是 Immerkaer；白化用的是一起算出来的 |H_eff|²。
        let k: [Double] = [1, -2, 1, -2, 4, -2, 1, -2, 1]
        let lap: [Double] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        let alpha = TextureBandRestore.immerkaerRegularizer
        let height = source.count / width
        for y in 0..<n {
            let sy = y0 + y
            for x in 0..<n {
                let sx = x0 + x
                var immerkaer = 0.0
                var laplacian = 0.0
                var t = 0
                for ky in -1...1 {
                    let yy = min(max(sy + ky, 0), height - 1)
                    let row = yy * width
                    for kx in -1...1 {
                        let xx = min(max(sx + kx, 0), width - 1)
                        let v = source[row + xx]
                        immerkaer += k[t] * v
                        laplacian += lap[t] * v
                        t += 1
                    }
                }
                let j = y * n + x
                re[j] = (immerkaer + alpha * laplacian) * window[j]
                im[j] = 0
            }
        }
    }

    /// `H_eff = H_immerkaer + α·H_laplacian`，α = 2。
    ///
    /// 这个值的空间核化简成 `[[1,0,1],[0,-4,0],[1,0,1]]`：只有 DC 和 Nyquist 角两个零点，
    /// 0.05–0.45 c/px 的整个带内都没有零点，轴上的竖/横织纹和 45° 斜纹一样能被检测。
    /// α = 1 会在 (0.25, 0.25) 造出一个新零点，α = 0.5 则把轴上的传送压得太低，
    /// 白化后纯噪声的窗函数泄漏会把 excess 抬到 10 以上。
    private static let immerkaerRegularizer = 2.0

    private struct Detection {
        var weight: Double = 0
        var fx: Double = 0
        var fy: Double = 0
        var binX: Int = 0
        var binY: Int = 0
        var rawExcess: Double = 0
        var frequency: Double { (fx * fx + fy * fy).squareRoot() }
    }

    /// 与窗内容无关、只由 `n` / 选项决定的东西：频率轴、白化传送、径向 bin、候选格点。
    /// 60 MP 上要跑 800+ 窗，如果每窗都重算几万次 `cos/sqrt`，光检测就超过整个预算。
    private struct DetectionTables {
        let n: Int
        let fx: [Double]
        let fy: [Double]
        let transfer: [Double]
        let binOf: [UInt8]
        let valid: [Int]
        let candidate: [Int]
        let signedOffsets: [Int]

        init(n: Int, options: TextureBandRestoreOptions) {
            let count = n * n
            let binCount = 60
            var fx = [Double](repeating: 0, count: n)
            var fy = [Double](repeating: 0, count: n)
            for k in 0..<n {
                let f = k <= n / 2 ? Double(k) / Double(n) : Double(k - n) / Double(n)
                fx[k] = f
                fy[k] = f
            }
            var transfer = [Double](repeating: 0, count: count)
            var binOf = [UInt8](repeating: 60, count: count)
            var valid: [Int] = []
            var candidate: [Int] = []
            valid.reserveCapacity(count / 2)
            candidate.reserveCapacity(count / 8)

            let maxTransfer = 64.0 // |H_eff(0.5,0)|² = 8²
            let transferFloor = maxTransfer * 1e-6
            let maxRadius = Double(n)
            for ky in 0..<n {
                let fyq = fy[ky]
                let ay = 2 * cos(2 * Double.pi * fyq) - 2
                for kx in 0..<n {
                    let fxq = fx[kx]
                    let fr = (fxq * fxq + fyq * fyq).squareRoot()
                    // 半边即可（实输入谱共轭对称）。轴上不排除：正则化后的核在轴上
                    // 不再有零点，90°/0° 的织纹线必须能被看到。
                    guard fr > 4 / maxRadius else { continue }
                    guard fyq > 0 || (fyq == 0 && fxq > 0) else { continue }
                    let ax = 2 * cos(2 * Double.pi * fxq) - 2
                    let h = ax * ay + immerkaerRegularizer * (ax + ay)
                    let hp = h * h
                    guard hp > transferFloor else { continue }
                    let j = ky * n + kx
                    transfer[j] = hp
                    let bin = min(Int(fr * Double(binCount) * 2), binCount - 1)
                    binOf[j] = UInt8(bin)
                    valid.append(j)
                    if fr >= options.minFrequency, fr <= options.maxFrequency {
                        candidate.append(j)
                    }
                }
            }
            self.n = n
            self.fx = fx
            self.fy = fy
            self.transfer = transfer
            self.binOf = binOf
            self.valid = valid
            self.candidate = candidate
            var signedOffsets = [Int](repeating: 0, count: n)
            for k in 0..<n { signedOffsets[k] = k <= n / 2 ? k : k - n }
            self.signedOffsets = signedOffsets
        }
    }

    /// 每只窗复用同一份 buffer：`power` 和 60 个半径 bin 的临时数组。
    private final class DetectionWorkspace {
        var power: [Double]
        var bins: [[Double]]

        init(n: Int) {
            power = [Double](repeating: .nan, count: n * n)
            bins = (0..<60).map { _ in [] }
        }

        func resetBins() {
            for i in bins.indices { bins[i].removeAll(keepingCapacity: true) }
        }
    }

    /// 白化后的谱峰：`P/|H|²` 再除以同半径 bin 的中值。
    ///
    /// 权重拐点作用在**幅度比** `√excess` 上：单个白噪声 bin 的功率比在 ~10⁴ 个格点里本来
    /// 就能冲到 10–20（χ²₂ 的极值），把 3/10 直接当功率阈值会让纯噪声也满权重；开方后
    /// 3–10 是「几倍标准差」的意思，纯噪声窗的权重才会落在 0.1 以下。
    private static func detectLine(re: [Double], im: [Double],
                                   tables: DetectionTables,
                                   workspace: DetectionWorkspace,
                                   options: TextureBandRestoreOptions) -> Detection {
        let binCount = 60
        workspace.resetBins()

        let valid = tables.valid
        let binOf = tables.binOf
        let transfer = tables.transfer
        for j in valid {
            let p = (re[j] * re[j] + im[j] * im[j]) / transfer[j]
            workspace.power[j] = p
            workspace.bins[Int(binOf[j])].append(p)
        }

        var baselines = [Double](repeating: .nan, count: binCount)
        for i in 0..<binCount where !workspace.bins[i].isEmpty {
            baselines[i] = quickMedian(&workspace.bins[i])
        }

        var best = 0.0
        var bestIndex = -1
        for j in tables.candidate {
            let base = baselines[Int(binOf[j])]
            guard base.isFinite, base > 0 else { continue }
            let excess = workspace.power[j] / base
            if excess > best {
                best = excess
                bestIndex = j
            }
        }

        guard best > 0, bestIndex >= 0 else { return Detection() }
        let kx = bestIndex % tables.n
        let ky = bestIndex / tables.n
        let significance = best.squareRoot()
        return Detection(weight: smoothstep(options.excessLow, options.excessHigh, significance),
                         fx: tables.fx[kx], fy: tables.fy[ky],
                         binX: kx, binY: ky, rawExcess: best)
    }

    /// 高斯带通查找表：频点都落在 DFT 格点上，所以 `exp` 只需要在
    /// `dx, dy ∈ [−n/2, n/2]` 上算一次，之后每窗查表。
    private static func gaussianMaskTable(n: Int, sigma: Double) -> [Double] {
        let half = n / 2
        let side = n + 1
        let s = max(sigma, 1 / Double(n))
        let factor = 1 / (2 * s * s * Double(n * n))
        var table = [Double](repeating: 0, count: side * side)
        for dy in -half...half {
            for dx in -half...half {
                table[(dy + half) * side + (dx + half)] =
                    exp(-Double(dx * dx + dy * dy) * factor)
            }
        }
        return table
    }

    private static func applyBandMask(re: inout [Double], im: inout [Double],
                                      n: Int, binX: Int, binY: Int,
                                      signed: [Int], gauss: [Double]) {
        let half = n / 2
        let side = n + 1
        for ky in 0..<n {
            let dy1 = signed[(ky - binY + n) % n]
            let dy2 = signed[(ky + binY) % n]
            let row1 = (dy1 + half) * side + half
            let row2 = (dy2 + half) * side + half
            for kx in 0..<n {
                let dx1 = signed[(kx - binX + n) % n]
                let dx2 = signed[(kx + binX) % n]
                let g = max(gauss[row1 + dx1], gauss[row2 + dx2])
                let j = ky * n + kx
                re[j] *= g
                im[j] *= g
            }
        }
    }

    /// 就地求中值，O(n) 平均；排序 13 万个 Double 每窗要几毫秒，60 MP 上是秒级差别。
    private static func quickMedian(_ values: inout [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let k = values.count / 2
        var lo = 0, hi = values.count - 1
        while lo < hi {
            let pivot = values[(lo + hi) / 2]
            var i = lo, j = hi
            while i <= j {
                while values[i] < pivot { i += 1 }
                while values[j] > pivot { j -= 1 }
                if i <= j {
                    values.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if k <= j {
                hi = j
            } else if k >= i {
                lo = i
            } else {
                break
            }
        }
        return values[k]
    }

    private static func fft2(setup: FFTSetupD, log2n: vDSP_Length,
                             re: inout [Double], im: inout [Double],
                             n: Int, inverse: Bool) {
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                guard let rb = rp.baseAddress, let ib = ip.baseAddress else { return }
                var split = DSPDoubleSplitComplex(realp: rb, imagp: ib)
                vDSP_fft2d_zipD(setup, &split, 1, 0, log2n, log2n,
                                inverse ? FFTDirection(FFT_INVERSE) : FFTDirection(FFT_FORWARD))
            }
        }
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard b > a else { return x >= b ? 1 : 0 }
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        var sorted = values
        sorted.sort()
        if sorted.count % 2 == 1 { return sorted[sorted.count / 2] }
        return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
}

// MARK: - 归一化 / CFA（mosaic 域）

/// 黑/白电平，按 CFA 相位。与库里的 `MosaicNormalization` 同义；宿主侧不依赖它的 internal
/// 读端，所以这里只保留恢复层实际要用的四件事。
struct Normalization {
    let blackByPhase: [Double]
    let repeatRows: Int
    let repeatCols: Int
    let white: Double

    init(doc: SourceDNG) throws {
        let blackEntry = doc.raw[50714] ?? doc.ifd0[50714]
        let whiteEntry = doc.raw[50717] ?? doc.ifd0[50717]
        let repeatEntry = doc.raw[50713] ?? doc.ifd0[50713]
        let blacks = blackEntry?.numericValues ?? []
        guard !blacks.isEmpty else { throw NormalizationError.missing(50714) }
        guard let white = (whiteEntry?.numericValues ?? []).first,
              white > (blacks.max() ?? 0) else {
            throw NormalizationError.missing(50717)
        }
        let dims = repeatEntry?.numericValues ?? []
        let rows = dims.count >= 2 ? Int(dims[0]) : (blacks.count == 4 ? 2 : 1)
        let cols = dims.count >= 2 ? Int(dims[1]) : (blacks.count == 4 ? 2 : 1)
        blackByPhase = blacks
        repeatRows = max(1, rows)
        repeatCols = max(1, cols)
        self.white = white
    }

    func black(row: Int, col: Int) -> Double {
        let r = row % repeatRows, c = col % repeatCols
        return blackByPhase[min(r * repeatCols + c, blackByPhase.count - 1)]
    }

    func normalize(_ value: UInt16, row: Int, col: Int) -> Double {
        let b = black(row: row, col: col)
        return (Double(value) - b) / (white - b)
    }

    func denormalize(_ value: Double, row: Int, col: Int) -> UInt16 {
        guard value.isFinite else { return UInt16(black(row: row, col: col).rounded()) }
        let b = black(row: row, col: col)
        let raw = value * (white - b) + b
        if raw <= 0 { return 0 }
        if raw >= Double(UInt16.max) { return UInt16.max }
        return UInt16(raw.rounded())
    }
}

enum NormalizationError: Error, CustomStringConvertible {
    case missing(UInt16)
    var description: String { "缺少 tag \(tag)" }
    private var tag: UInt16 {
        switch self { case .missing(let t): return t }
    }
}

private func cfa(of doc: SourceDNG) throws -> String {
    let entry = doc.raw[33422] ?? doc.ifd0[33422]
    let values = (entry?.numericValues ?? []).map { Int($0.rounded()) }
    guard values.count == 4 else { throw CFAError.bad("\(values)") }
    let letters: [Character] = values.map {
        switch $0 {
        case 0: return "r"
        case 1: return "g"
        case 2: return "b"
        default: return "?"
        }
    }
    guard !letters.contains("?") else { throw CFAError.bad("\(values)") }
    return String(letters)
}

enum CFAError: Error, CustomStringConvertible {
    case bad(String)
    var description: String {
        switch self { case .bad(let raw): return "无法解析 CFA（\(raw)）" }
    }
}

extension TIFFEntry {
    /// TIFF 数值 payload → `Double`；只解 DNG 电平/CFA 实际用的类型。
    var numericValues: [Double] {
        func u16(_ i: Int) -> Double {
            Double(UInt16(value[i]) | (UInt16(value[i + 1]) << 8))
        }
        func u32(_ i: Int) -> Double {
            Double(UInt32(value[i]) | (UInt32(value[i + 1]) << 8)
                   | (UInt32(value[i + 2]) << 16) | (UInt32(value[i + 3]) << 24))
        }
        var out: [Double] = []
        switch type {
        case 1:
            out = value.prefix(count).map(Double.init)
        case 3:
            var i = 0
            while i + 2 <= value.count { out.append(u16(i)); i += 2 }
        case 4:
            var i = 0
            while i + 4 <= value.count { out.append(u32(i)); i += 4 }
        case 5, 10:
            var i = 0
            while i + 8 <= value.count {
                let num = u32(i), den = u32(i + 4)
                out.append(den == 0 ? 0 : num / den)
                i += 8
            }
        default:
            break
        }
        return out
    }
}
