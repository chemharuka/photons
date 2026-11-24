import XCTest
import Metal
import PhotonsCore

/// 558 — S3.9 细节保留的**尺子**：真照片上的高频能量与边缘 MTF50。
///
/// 553 的夹具有两个盲点，这一单就是补上它们：
///
///   · 553 的纹理是**合成图案**（平坦块 + 4 px 棋盘 + 16 px 正弦）。NLM/双边对它是「均值保持」的，
///     棋盘自己就占了 z 轴好几个 bin，所以 `amount = 100` 的保留率仍有 99.9 % —— 它看不见细节丢失。
///   · 真照片上「细节」的幅度小、频率高（碎石、树叶），正是 z 轴 bin 宽（r ≈ 0.01…0.05）会把它们
///     和噪声一起平均掉的尺度。所以夹具换成 `L1030433.dng` 的真 RAW 裁切。
///
/// 三个指标，都只在**同一张真照片**上量：
///
///   A. **Laplacian RMS** — 线性 Rec.709 亮度上 4 邻域拉普拉斯的 RMS（553 的同一算法）。
///   B. **径向功率谱** — sRGB 编码亮度上，0.25–0.5 cycles/px 的能量占 0–0.5 全频段的比例。
///      去噪的过平滑最先吃掉这一段；棋盘/阶跃在低频，扫不到它。
///   C. **MTF50 近似** — 实拍刀刃边（楼顶檐口，近水平）的斜边 MTF；按拟合边线分箱到 0.25 px，
///      对 ESF 求导、Hann 窗、FFT，读 |MTF| 落到低频谱台一半的频率。报告 amount 0 与 100 的比值。
///
/// 两个区域，因为 MTF 需要一条实拍边、频段指标需要一片真实纹理：
///
///   · `gravel` — 解码后 4760×3168 上的 (896, 2176, 256×256)：画面左下、舞台前的**碎石地**。
///     低反差、真实颗粒，是丢细节最典型的区域。A / B 在这里量。
///   · `foliage` — (571, 190, 256×256)：左上**树叶**（高反差纹理）。它是回注的**对照**：5×5 方差
///     远高于 4τ²，所以 gate 应该把它整块保住。C 的边不在这里，在 `roof`。
///   · `roof` — (2300, 600, 400×256)：玻璃楼顶的檐口（近水平、两侧大片均匀），MTF50 在这里量。
///
/// 解码用 `decodeForMeasurement`（四根 detail 轴全 0），尺子不掺 Apple 的解码锐化/降噪。
///
/// **反向门（本文件的断言 ② 就是它的守卫）**：把 `s3_8_detail_fx.metal` 的
/// `gate = 1.0 - smoothstep(...)` 换成 `gate = 1.0`（即 553 的「整段回注去掉」），同一把尺子上
/// `foliage` 的 B 保留率从 **139.5 %** 掉到 **87.9 %**，`gravel` 的 B 保留率从 **23.3 %** 掉到 **2.1 %**。
/// 断言 ② 用的是回注**开**时的绝对保留率（≥95 %）—— 反向门会让它红，而断言 ① 仍然绿（碎石照样掉
/// ≥5 %，尺子本身不依赖回注）。真实反向门的数字抄在 `local/REPORT.md`；白名单不允许改算子，所以
/// 这里不把 gate-off 做成运行时开关，只把实测的 0.879 当**已记录的参照**。
///
/// 553 **之前**（z 轴与回注都还原）在同一把尺子上：gravel A 64.4 % / B 5.1 % / C 101.1 %，
/// foliage B 100.5 %。553 没有恶化细节：B 的三档都比 base 高（23.3 % vs 5.1 %）。
final class DenoiseDetail558Tests: XCTestCase {

    // 558 的尺子只在 L1030433 的 0.5 倍解码上标定过（坐标是解码像素）。
    private static let decodeScale: Double = 0.5
    private static let expected = (w: 4760, h: 3168)
    private static let gravel = ImageRect(x: 896, y: 2176, width: 256, height: 256)
    private static let foliage = ImageRect(x: 571, y: 190, width: 256, height: 256)
    private static let roof = ImageRect(x: 2300, y: 600, width: 400, height: 256)

    // MARK: - plumbing

    private func rawFixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func makeGraph(_ image: LinearImage, url: URL) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: "558-ruler", sourceURL: url))
    }

    private func render(_ graph: RenderGraph, amount: Double) throws -> DisplayImage {
        var edit = EditModel.neutral
        edit.effects.nonBayerLuminanceNR = amount
        let options = RenderOptions(canvas: nil, scale: 1,
                                    display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display, "amount \(amount)：渲染没有回读像素")
    }

    private func decode(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// 线性 Rec.709 亮度（指标 A / C 的域：S3.9 的工作域，也是 553 用的域）。
    private func lumaLinear(_ image: DisplayImage) -> [Double] {
        var out = [Double](repeating: 0, count: image.width * image.height)
        for i in 0..<out.count {
            let b = i * 4
            out[i] = 0.2126 * decode(max(Double(image.rgba[b]), 0))
                + 0.7152 * decode(max(Double(image.rgba[b + 1]), 0))
                + 0.0722 * decode(max(Double(image.rgba[b + 2]), 0))
        }
        return out
    }

    /// sRGB 编码亮度（指标 B 的域：显示出来的画面，也是人看见的对比）。
    private func lumaEncoded(_ image: DisplayImage) -> [Double] {
        var out = [Double](repeating: 0, count: image.width * image.height)
        for i in 0..<out.count {
            let b = i * 4
            out[i] = 0.2126 * Double(image.rgba[b])
                + 0.7152 * Double(image.rgba[b + 1])
                + 0.0722 * Double(image.rgba[b + 2])
        }
        return out
    }

    private func crop(_ l: [Double], _ w: Int, _ r: ImageRect) -> [Double] {
        var out = [Double]()
        out.reserveCapacity(r.width * r.height)
        for y in r.y..<(r.y + r.height) {
            let row = y * w
            for x in r.x..<(r.x + r.width) { out.append(l[row + x]) }
        }
        return out
    }

    // MARK: - A. Laplacian RMS

    private func laplacianRMS(_ l: [Double], _ w: Int, _ h: Int) -> Double {
        func at(_ x: Int, _ y: Int) -> Double { l[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)] }
        var sum = 0.0, n = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let lap = 4 * at(x, y) - at(x - 1, y) - at(x + 1, y) - at(x, y - 1) - at(x, y + 1)
                sum += lap * lap; n += 1
            }
        }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    // MARK: - B. radial power spectrum

    /// In-place iterative radix-2 Cooley–Tukey. n is a power of two.
    private func fft(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j |= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let ang = -2 * Double.pi / Double(len)
            let wr = cos(ang), wi = sin(ang)
            var i = 0
            while i < n {
                var ur = 1.0, ui = 0.0
                for k in 0..<(len / 2) {
                    let ar = re[i + k], ai = im[i + k]
                    let br = re[i + k + len / 2] * ur - im[i + k + len / 2] * ui
                    let bi = re[i + k + len / 2] * ui + im[i + k + len / 2] * ur
                    re[i + k] = ar + br; im[i + k] = ai + bi
                    re[i + k + len / 2] = ar - br; im[i + k + len / 2] = ai - bi
                    let nr = ur * wr - ui * wi
                    ui = ur * wi + ui * wr
                    ur = nr
                }
                i += len
            }
            len <<= 1
        }
    }

    /// 0.25–0.5 cycles/px 的能量 / 0–0.5 的全部能量（DC 除外）。方形 Hann 窗、先去均值。
    private func bandShare(_ l: [Double], _ w: Int, _ h: Int) -> Double {
        let n = min(w, h)
        var re = [Double](repeating: 0, count: n * n)
        var im = [Double](repeating: 0, count: n * n)
        var mean = 0.0
        for y in 0..<n { for x in 0..<n { mean += l[y * w + x] } }
        mean /= Double(n * n)
        for y in 0..<n {
            let wy = 0.5 - 0.5 * cos(2 * Double.pi * Double(y) / Double(n))
            for x in 0..<n {
                let wx = 0.5 - 0.5 * cos(2 * Double.pi * Double(x) / Double(n))
                re[y * n + x] = (l[y * w + x] - mean) * wx * wy
            }
        }
        var rowRe = [Double](repeating: 0, count: n)
        var rowIm = [Double](repeating: 0, count: n)
        for y in 0..<n {
            for x in 0..<n { rowRe[x] = re[y * n + x]; rowIm[x] = im[y * n + x] }
            fft(&rowRe, &rowIm)
            for x in 0..<n { re[y * n + x] = rowRe[x]; im[y * n + x] = rowIm[x] }
        }
        for x in 0..<n {
            for y in 0..<n { rowRe[y] = re[y * n + x]; rowIm[y] = im[y * n + x] }
            fft(&rowRe, &rowIm)
            for y in 0..<n { re[y * n + x] = rowRe[y]; im[y * n + x] = rowIm[y] }
        }
        var band = 0.0, total = 0.0
        for y in 0..<n {
            let fy = y <= n / 2 ? Double(y) / Double(n) : Double(y - n) / Double(n)
            for x in 0..<n {
                let fx = x <= n / 2 ? Double(x) / Double(n) : Double(x - n) / Double(n)
                let f = (fx * fx + fy * fy).squareRoot()
                guard f > 0, f <= 0.5 else { continue }
                let p = re[y * n + x] * re[y * n + x] + im[y * n + x] * im[y * n + x]
                total += p
                if f >= 0.25 { band += p }
            }
        }
        return total > 0 ? band / total : 0
    }

    // MARK: - C. slanted-edge MTF50

    /// 边方向由梯度总量决定（竖边逐行找、横边逐列找），逐行/列找最大梯度点拟合一条直线，
    /// 每像素按到该线的**有符号距离**落到 0.25 px 的箱里；对 ESF 求导 + Hann 窗 + FFT，
    /// 返回 |MTF| 第一次落到低频谱台一半处的频率（cycles/px）。
    private func mtf50(_ l: [Double], _ w: Int, _ h: Int, _ r: ImageRect) -> Double? {
        func at(_ x: Int, _ y: Int) -> Double { l[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)] }
        var gx = 0.0, gy = 0.0
        for y in (r.y + 4)..<(r.y + r.height - 4) {
            for x in (r.x + 4)..<(r.x + r.width - 4) {
                gx += abs(at(x + 1, y) - at(x - 1, y))
                gy += abs(at(x, y + 1) - at(x, y - 1))
            }
        }
        let vertical = gx > gy
        var pts: [(Double, Double)] = []
        if vertical {
            for y in (r.y + 4)..<(r.y + r.height - 4) {
                var best = 0.0, bestX = r.x + r.width / 2
                for x in (r.x + 8)..<(r.x + r.width - 8) {
                    let g = abs(at(x - 1, y) - at(x + 1, y))
                    if g > best { best = g; bestX = x }
                }
                pts.append((Double(y), Double(bestX)))
            }
        } else {
            for x in (r.x + 4)..<(r.x + r.width - 4) {
                var best = 0.0, bestY = r.y + r.height / 2
                for y in (r.y + 8)..<(r.y + r.height - 8) {
                    let g = abs(at(x, y - 1) - at(x, y + 1))
                    if g > best { best = g; bestY = y }
                }
                pts.append((Double(x), Double(bestY)))
            }
        }
        guard pts.count > 16 else { return nil }
        let n = Double(pts.count)
        let mt = pts.reduce(0) { $0 + $1.0 } / n
        let mp = pts.reduce(0) { $0 + $1.1 } / n
        var stt = 0.0, stp = 0.0
        for (t, p) in pts { stt += (t - mt) * (t - mt); stp += (t - mt) * (p - mp) }
        let a = stp / max(stt, 1e-9)
        let b = mp - a * mt
        let norm = (1 + a * a).squareRoot()
        let half = 32, bins = 256
        var sum = [Double](repeating: 0, count: bins)
        var count = [Double](repeating: 0, count: bins)
        for y in r.y..<(r.y + r.height) {
            for x in r.x..<(r.x + r.width) {
                let d = vertical
                    ? (Double(x) - (a * Double(y) + b)) / norm
                    : (Double(y) - (a * Double(x) + b)) / norm
                let k = Int((d + Double(half)) * 4)
                if k >= 0 && k < bins { sum[k] += at(x, y); count[k] += 1 }
            }
        }
        var esf = [Double](), valid = 0
        for k in 0..<bins {
            if count[k] > 0 { esf.append(sum[k] / count[k]); valid += 1 }
            else { esf.append(esf.last ?? 0) }
        }
        guard valid > bins / 2 else { return nil }
        var lsf = [Double](repeating: 0, count: esf.count)
        for i in 1..<(esf.count - 1) { lsf[i] = esf[i + 1] - esf[i - 1] }
        let m = esf.count
        for i in 0..<m {
            let win = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(m - 1))
            lsf[i] *= win
        }
        let fftN = 2048
        var re = [Double](repeating: 0, count: fftN)
        var im = [Double](repeating: 0, count: fftN)
        for i in 0..<m { re[i] = lsf[i] }
        fft(&re, &im)
        var mag = [Double](repeating: 0, count: fftN / 2)
        for i in 0..<(fftN / 2) { mag[i] = (re[i] * re[i] + im[i] * im[i]).squareRoot() }
        // 一个样本是 0.25 px，所以第 i 个 bin 是 i / (fftN · 0.25) cycles/px。阶跃的 LSF 是尖峰，
        // 频谱的低频是平的：用 bin 0（Σ LSF = 阶跃高度）归一，再找 0.02 cycles/px 之后的第一个 0.5。
        guard mag[0] > 0 else { return nil }
        let start = max(2, Int((0.02 * 0.25 * Double(fftN)).rounded()))
        for i in (start + 1)..<(fftN / 2 - 1) {
            let lo = mag[i - 1] / mag[0], hi = mag[i] / mag[0]
            if hi < 0.5 {
                let denom = lo - hi
                let t = denom > 1e-12 ? (lo - 0.5) / denom : 0
                return (Double(i - 1) + t) / (Double(fftN) * 0.25)
            }
        }
        return nil
    }

    // MARK: - the ruler

    func testRealPhotoDetailLossTable() throws {
        let url = try rawFixture()
        let image = try RAWDecoder().decodeForMeasurement(url, scale: Self.decodeScale)
        guard image.width == Self.expected.w, image.height == Self.expected.h else {
            throw XCTSkip("558 的尺子标定在 L1030433 @0.5 (\(Self.expected.w)×\(Self.expected.h))，"
                          + "当前解码 \(image.width)×\(image.height)")
        }
        let graph = try makeGraph(image, url: url)
        let dw = image.width

        var laps: [Double] = []       // A, gravel
        var shares: [Double] = []     // B, gravel (encoded)
        var foliageShares: [Double] = [] // 回注对照, encoded
        var mtfs: [Double] = []       // C, roof

        print("558 · 真照片 \(url.lastPathComponent) @\(Self.decodeScale)× · "
              + "gravel \(Self.gravel.x),\(Self.gravel.y) \(Self.gravel.width)×\(Self.gravel.height) · "
              + "foliage \(Self.foliage.x),\(Self.foliage.y) · roof \(Self.roof.x),\(Self.roof.y)")
        print("558 · amount | A lapRMS(gravel) | B 0.25–0.5 share(gravel) | C MTF50(roof) | foliage B share")

        for amount in [0.0, 50.0, 100.0] {
            let display = try render(graph, amount: amount)
            let lin = lumaLinear(display)
            let enc = lumaEncoded(display)
            let lap = laplacianRMS(crop(lin, dw, Self.gravel), Self.gravel.width, Self.gravel.height)
            let share = bandShare(crop(enc, dw, Self.gravel), Self.gravel.width, Self.gravel.height)
            let foliage = bandShare(crop(enc, dw, Self.foliage), Self.foliage.width, Self.foliage.height)
            let mtf = try XCTUnwrap(mtf50(lin, dw, image.height, Self.roof),
                                    "amount \(amount)：roof 边没有可测的 MTF50")
            laps.append(lap); shares.append(share); foliageShares.append(foliage); mtfs.append(mtf)
            print(String(format: "558 · %5.0f | %.6f | %.6f | %.4f c/px | %.6f",
                         amount, lap, share, mtf, foliage))
        }

        let lapRet = laps[2] / laps[0]
        let bandRet = shares[2] / shares[0]
        let mtfRet = mtfs[2] / mtfs[0]
        let foliageRet = foliageShares[2] / foliageShares[0]

        print(String(format: "558 · amount 100 / 0 保留率 · A %.1f%% · B %.1f%% · C %.1f%% · foliage B %.1f%%",
                     100 * lapRet, 100 * bandRet, 100 * mtfRet, 100 * foliageRet))
        print(String(format: "558 · 单调性 · A 50/0 %.1f%% → 100/0 %.1f%% · B 50/0 %.1f%% → 100/0 %.1f%%",
                     100 * laps[1] / laps[0], 100 * lapRet, 100 * shares[1] / shares[0], 100 * bandRet))

        // ① 尺子必须看得见 amount 0 → 100 的细节丢失：A 与 B 都单调下降且 ≥5 %，C 作为第三个读数。
        let dropped = [lapRet, bandRet, mtfRet].filter { $0 <= 0.95 }.count
        print("558 · 三个指标里 ≥5 % 下降的个数：\(dropped)（C 是实拍刀刃边，边缘被 z 轴停住时它不掉）")
        XCTAssertLessThanOrEqual(bandRet, 0.95, "B 必须看见 ≥5 % 的高频占比损失")
        XCTAssertLessThanOrEqual(lapRet, 0.95, "A 必须看见 ≥5 % 的 Laplacian 损失")
        XCTAssertLessThan(laps[1], laps[0], "A 在 amount 50 就必须开始下降")
        XCTAssertLessThan(laps[2], laps[1], "A 必须随 amount 单调下降")
        XCTAssertLessThan(shares[1], shares[0], "B 在 amount 50 就必须开始下降")
        XCTAssertLessThan(shares[2], shares[1], "B 必须随 amount 单调下降")
        XCTAssertGreaterThanOrEqual(dropped, 2, "三个指标里至少两个必须下降 ≥5 %")

        // ② 回注的守卫：高方差真实纹理（树叶）必须被 gate 保住。反向门（gate = 1.0）在同一张照片、
        // 同一把尺子上实测 87.9 %，所以「≥95 %」就是回注有效性的下限；回注被删掉时这条会红，而 ① 仍绿。
        let reverseGateFoliage = 0.879
        XCTAssertGreaterThanOrEqual(foliageRet, 0.95,
                                    "回注必须把树叶这类高方差纹理的频谱保留率保持在 95 % 以上")
        XCTAssertGreaterThanOrEqual(foliageRet - reverseGateFoliage, 0.03,
                                    "回注有效：相对 gate = 1.0 的 87.9 % 至少多保住 3 个百分点")
        print(String(format: "558 · 回注 · foliage B %.1f%% vs 反向门记录值 %.1f%%（差 %+.1f 点）",
                     100 * foliageRet, 100 * reverseGateFoliage,
                     100 * (foliageRet - reverseGateFoliage)))
    }
}
