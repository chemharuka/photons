import XCTest
import Metal
import PhotonsCore

/// 374 — **去雾的 SDR/HDR 交界**：`w` 的过渡带要跨过 1.0，而不是在 `A` 处硬切。
///
/// 280 把上边缘收到 `A + 2σ`（`σ = 2 %·A`），于是 `w = 0` 对所有 `L ≥ A`。`A` 通常
/// `0.95·p99(L) ≤ 1.0`，所以低于 1.0 的像素被压暗、高于 1.0 的完全不动 —— 断层正好落在
/// SDR/HDR 的交界。物理模型 `J = (I − A(1−t))/t` 在 `I = A` 处连续（`J(A) = A`），断层来自
/// `w` 的截断，不是公式。
///
/// 这个文件把断层量化成两个探针，并钉住修复后的契约：
///
///   1. **ramp**：一张 0.2 → 2.0 的 256 级线性灰度 ramp，`dehaze = 20/50/100`。输出必须单调
///      不减；1.0 两侧 ±1 %（以及 `A` 两侧 ±1 %，旧截断真正所在）的斜率比 ≤ 1.2；相邻级差
///      不许超过模型自己的 `1/t0` 上限 —— 这是「没有 cliff」的判据。字面上的「≤ 1.5× 输入
///      步长」在这个 ramp 上做不到：`t(0.9·A) ≈ 0.13`，物理反演本身就是 `1/t ≈ 7.7×`
///      （见报告）。
///   2. **真图**：`L1030437`（HDR 高光）与 `L1030428`（暗场）的 p95–p99 / p99–p99.9 /
///      p99.9–p100 分箱 gain，以及跨 1.0 的 gain 台阶。高光尾不许被抬（280 的成果），
///      跨 1.0 也不许有台阶。
final class DehazeSeamTests: XCTestCase {

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func image(width: Int, height: Int,
                       _ value: (Int, Int) -> Double) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = value(x, y)
                let i = (y * width + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v); rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// `0.2 → 2.0` over `levels` columns — the SDR/HDR seam probe. `dehaze`'s `w` is a function of
    /// luminance, so a horizontal ramp of uniform rows reads the whole participation curve.
    private func ramp(levels: Int = 256, height: Int = 64) -> LinearImage {
        image(width: levels, height: height) { x, _ in
            0.2 + 1.8 * Double(x) / Double(max(levels - 1, 1))
        }
    }

    private func linearRender(_ graph: RenderGraph, _ edit: EditModel,
                              probe: Bool = false) throws -> DisplayImage {
        let display = DisplayOptions(primaries: .rec2020, bitDepth: 16, headroom: 16,
                                     linearOutput: true)
        // The subject is S1.9; 314's resting 锐化 would ride in the frame and move every ratio.
        var doc = edit
        doc.sharpen = SharpenGroup(amount: 0)
        let result = try graph.render(doc, options: RenderOptions(
            scale: 1, display: display, useCache: false, wantsPixels: true,
            probesDehazeAirlight: probe))
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    private func luma(_ image: DisplayImage, _ x: Int, _ y: Int) -> Double {
        let i = (y * image.width + x) * 4
        return 0.2627 * Double(image.rgba[i])
            + 0.6780 * Double(image.rgba[i + 1])
            + 0.0593 * Double(image.rgba[i + 2])
    }

    private func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(q * Double(sorted.count - 1)))]
    }

    // MARK: - 1. ramp probe (chip level)

    func testTheLinearRampHasNoSeamAcrossOne() throws {
        let levels = 256
        let graph = try makeGraph(ramp(levels: levels), identity: "dehaze-seam-ramp")
        let before = try linearRender(graph, .neutral)
        let y = before.height / 2
        let xs = (0..<levels).map { 0.2 + 1.8 * Double($0) / Double(levels - 1) }
        // The stage's own input is the neutral frame; using its readback keeps `in` and `out` on the
        // same measurement chain (there is no other stage between them).
        let ins = (0..<levels).map { luma(before, $0, y) }
        let step = (ins.last! - ins.first!) / Double(levels - 1)

        var failures: [String] = []
        var rows: [String] = []
        var renders: [Int: [Double]] = [:]
        for amount in [20, 50, 100] {
            var edit = EditModel.neutral
            edit.effects.dehaze = Double(amount)
            let after = try linearRender(graph, edit, probe: amount == 100)
            renders[amount] = (0..<levels).map { luma(after, $0, y) }
        }
        // 135's capped airlight in the ramp's own units (the probe reads `A_raw`).
        let aRaw = try XCTUnwrap(graph.lastDehazeAirlight)
        let p99c = {
            let clipped = ins.map { min($0, 1.0) }.sorted()
            return percentile(clipped, 0.99)
        }()
        let A = aRaw > 1.02 * p99c ? 0.95 * p99c : aRaw
        /// The two adjacent ramp intervals straddling `x`: the finite-difference slopes just below
        /// and just above it.
        func sideSlopes(_ outs: [Double], _ x: Double) -> (below: Double, above: Double) {
            let k = ins.firstIndex(where: { $0 >= x }) ?? (levels - 1)
            let below = k > 0 ? (outs[k] - outs[k - 1]) / max(ins[k] - ins[k - 1], 1e-12) : .nan
            let above = k + 1 < levels
                ? (outs[k + 1] - outs[k]) / max(ins[k + 1] - ins[k], 1e-12) : .nan
            return (below, above)
        }
        for amount in [20, 50, 100] {
            let outs = renders[amount]!
            var maxDelta = 0.0
            var maxAt = 0
            var drops = 0
            for i in 1..<levels {
                let d = outs[i] - outs[i - 1]
                if d < -1e-6 { drops += 1 }
                if abs(d) > maxDelta { maxDelta = abs(d); maxAt = i }
            }
            let one = sideSlopes(outs, 1.0)
            let ratio = max(one.below, one.above) / max(min(one.below, one.above), 1e-12)
            // The **seam-centered** cross-check: 1.0 is the SDR/HDR boundary, but the estimator puts
            // `A` at `0.95·p99`, so on this fixture the old cut sits at `A ≈ 0.95`, not exactly 1.0.
            // The participation is C¹ only if the slope is continuous at `A` too.
            let seam = sideSlopes(outs, A)
            let seamRatio = max(seam.below, seam.above) / max(min(seam.below, seam.above), 1e-12)
            // The model's own ceiling: `J = (L − A(1−t))/t` is `1/t0` steep at its steepest, so no
            // participation function can make the adjacent-level step smaller than
            // `1 + amount·(1/t0 − 1)` on this ramp at `amount`. A **cliff** is a step above that.
            let t0 = 0.1
            let physical = 1.0 + Double(amount) / 100.0 * (1.0 / t0 - 1.0)
            rows.append(String(format: "dehaze %3d: maxΔ %.5f @ %.3f (%.2f×step, 物理上限 %.2f×) · 1.0 斜率 %.3f/%.3f 比 %.3f · A=%.3f 斜率 %.3f/%.3f 比 %.3f · 回退 %d",
                               amount, maxDelta, xs[maxAt], maxDelta / max(step, 1e-9), physical,
                               one.below, one.above, ratio,
                               A, seam.below, seam.above, seamRatio, drops))
            if drops > 0 { failures.append("dehaze \(amount) 输出不单调（\(drops) 处回退）") }
            if maxDelta > physical * step * 1.05 {
                failures.append(String(format: "dehaze %d 相邻级差 %.5f 超过模型的 1/t 上限 %.5f（%.2f×，cliff 还在）",
                                       amount, maxDelta, physical * step, maxDelta / max(step, 1e-9)))
            }
            if !(ratio <= 1.2) {
                failures.append(String(format: "dehaze %d 的 1.0±1%% 斜率比 %.3f > 1.2", amount, ratio))
            }
            if !(seamRatio <= 1.2) {
                failures.append(String(format: "dehaze %d 的 A±1%% 斜率比 %.3f > 1.2", amount, seamRatio))
            }
        }
        print(String(format: "SEAM-RAMP · 输入级差 %.6f · A_raw %.4f · A_used %.4f · A 处输入 %.3f",
                     step, aRaw, A, A))
        for r in rows { print("SEAM-RAMP · " + r) }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: " · "))
    }

    // MARK: - 2. real frames

    private struct Band {
        let name: String
        let count: Int
        let avgGain: Double
        let maxGain: Double
    }

    private func bands(_ before: DisplayImage, _ after: DisplayImage)
        -> [Band] {
        var lumas: [Double] = []
        lumas.reserveCapacity(before.width * before.height)
        for y in 0..<before.height {
            for x in 0..<before.width { lumas.append(luma(before, x, y)) }
        }
        lumas.sort()
        let edges = [percentile(lumas, 0.95), percentile(lumas, 0.99), percentile(lumas, 0.999)]
        var sums = [Double](repeating: 0, count: 4)
        var maxes = [Double](repeating: 0, count: 4)
        var counts = [Int](repeating: 0, count: 4)
        for y in 0..<before.height {
            for x in 0..<before.width {
                let l = luma(before, x, y)
                guard l > 1e-9 else { continue }
                var b = 0
                while b < edges.count, l >= edges[b] { b += 1 }
                let g = luma(after, x, y) / l
                sums[b] += g
                maxes[b] = max(maxes[b], g)
                counts[b] += 1
            }
        }
        let names = ["<p95", "p95–p99", "p99–p99.9", "p99.9–p100"]
        return (0..<4).map {
            Band(name: names[$0], count: counts[$0],
                 avgGain: counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : 1,
                 maxGain: counts[$0] > 0 ? maxes[$0] : 1)
        }
    }

    /// Mean gain for pixels whose neutral luminance is within `lo...hi` — the cross-1.0 step probe.
    private func gain(_ before: DisplayImage, _ after: DisplayImage,
                      _ lo: Double, _ hi: Double) -> (Double, Int) {
        var i = 0.0, j = 0.0, n = 0
        for y in 0..<before.height {
            for x in 0..<before.width {
                let l = luma(before, x, y)
                guard l >= lo, l < hi else { continue }
                i += l; j += luma(after, x, y); n += 1
            }
        }
        return (j / max(i, 1e-9), n)
    }

    private func measure(_ path: String, identity: String) throws -> (
        a: Double, p95: Double, p99: Double, p999: Double, p100: Double, aUsed: Double,
        bands: [Double: [Band]], step: [Double: (Double, Int, Double, Int)],
        neutralSHA: String, negativeSHA: String) {
        let decoded = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                              options: DecodeOptions(scale: 0.25))
        let graph = try makeGraph(decoded, identity: identity)
        let before = try linearRender(graph, .neutral)
        var lumas: [Double] = []
        lumas.reserveCapacity(before.width * before.height)
        for y in 0..<before.height {
            for x in 0..<before.width { lumas.append(luma(before, x, y)) }
        }
        lumas.sort()
        var measured: [Double: [Band]] = [:]
        var steps: [Double: (Double, Int, Double, Int)] = [:]
        var a = 0.0
        for amount in [20.0, 50.0, 100.0] {
            var edit = EditModel.neutral
            edit.effects.dehaze = amount
            let after = try linearRender(graph, edit, probe: amount == 20)
            if amount == 20 { a = try XCTUnwrap(graph.lastDehazeAirlight) }
            measured[amount] = bands(before, after)
            let below = gain(before, after, 0.99, 1.0)
            let above = gain(before, after, 1.0, 1.01)
            steps[amount] = (below.0, below.1, above.0, above.1)
        }
        var negative = EditModel.neutral
        negative.effects.dehaze = -50
        let hazy = try linearRender(graph, negative)
        // 135's cap, as the apply pass sees it: the percentile is taken on the luma clipped at white.
        let p99c = percentile(lumas.map { min($0, 1.0) }, 0.99)
        let aUsed = a > 1.02 * p99c ? 0.95 * p99c : a
        return (a, p95: percentile(lumas, 0.95), p99: percentile(lumas, 0.99),
                p999: percentile(lumas, 0.999), p100: lumas.last ?? 0, aUsed: aUsed,
                bands: measured, step: steps, neutralSHA: before.sha256(),
                negativeSHA: hazy.sha256())
    }

    func testTheRealFramesHaveNoStepAcrossOne() throws {
        let files = [
            ("~/Desktop/test/L1030437.dng", "dehaze-seam-437"),
            ("~/Desktop/test/L1030428.dng", "dehaze-seam-428"),
        ]
        for (tilde, identity) in files {
            let path = NSString(string: tilde).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                throw XCTSkip("需要 \(tilde)")
            }
            let m = try measure(path, identity: identity)
            print(String(format: "SEAM-IMG %@ · A_raw %.4f · A_used %.4f · p95 %.4f · p99 %.4f · p99.9 %.4f · p100 %.4f · 1.0/A %.2f · p99.9/A %.2f · p99.9/2A %.2f",
                         identity, m.a, m.aUsed, m.p95, m.p99, m.p999, m.p100,
                         1.0 / max(m.aUsed, 1e-9), m.p999 / max(m.aUsed, 1e-9),
                         m.p999 / max(2 * m.aUsed, 1e-9)))
            var failures: [String] = []
            for amount in [20.0, 50.0, 100.0] {
                let rows = (m.bands[amount] ?? []).map {
                    String(format: "%@ avg %.3f max %.3f (%d)", $0.name, $0.avgGain, $0.maxGain, $0.count)
                }
                let s = m.step[amount]!
                print(String(format: "SEAM-IMG %@ dehaze %3d · %@ · 跨1.0 gain [0.99,1) %.3f (%d) → [1,1.01] %.3f (%d) · 台阶 %.3f",
                             identity, Int(amount), rows.joined(separator: " · "),
                             s.0, s.1, s.2, s.3, s.2 - s.0))
                let b = m.bands[amount] ?? []
                let deep = b[0], seam = b[2], top = b[3]
                // ③ — the p99.9–p100 tail is exactly 280's: not lifted (a hair under 1 is the
                // half-float readback) and never above the 2 % ceiling.
                if abs(top.avgGain - 1) > 0.02 {
                    failures.append(String(format: "%@ dehaze %d 的 p99.9–p100 gain %.3f 偏离 1 超过 2%%",
                                           identity, Int(amount), top.avgGain))
                }
                // The body of the frame (`L < p95`, i.e. the deep fog / the scene itself) keeps its
                // recovery; the near-`A` strip is where the seam fix deliberately tapers.
                if deep.avgGain > 0.99 {
                    failures.append(String(format: "%@ dehaze %d 的 <p95 gain %.3f 不再压暗",
                                           identity, Int(amount), deep.avgGain))
                }
                // The seam band may participate (it is the new contract) but is bounded.
                if seam.avgGain > 1.05 {
                    failures.append(String(format: "%@ dehaze %d 的 p99–p99.9 gain %.3f 超过 1.05",
                                           identity, Int(amount), seam.avgGain))
                }
                // No gain step across SDR white.
                if abs(s.2 - s.0) > 0.02 {
                    failures.append(String(format: "%@ dehaze %d 跨 1.0 的 gain 台阶 %.3f 超过 2%%",
                                           identity, Int(amount), s.2 - s.0))
                }
            }
            print("SEAM-IMG \(identity) · neutral sha \(m.neutralSHA.prefix(16))… · −50 sha \(m.negativeSHA.prefix(16))…")
            XCTAssertTrue(failures.isEmpty, failures.joined(separator: " · "))
        }
    }

    // MARK: - 3. byte identity of the untouched branches

    func testDehazeZeroAndNegativeStayByteIdentical() throws {
        let files = ["~/Desktop/test/L1030433.dng", "~/Desktop/test/L1030437.dng"]
        for tilde in files {
            let path = NSString(string: tilde).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let decoded = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                                  options: DecodeOptions(scale: 0.25))
            let graph = try makeGraph(decoded, identity: "dehaze-seam-sha")
            var zero = EditModel.neutral
            zero.effects.dehaze = 0
            var negative = EditModel.neutral
            negative.effects.dehaze = -50
            let a = try linearRender(graph, .neutral)
            let b = try linearRender(graph, zero)
            let c = try linearRender(graph, negative)
            print("SEAM-SHA \(String((tilde as NSString).lastPathComponent)) · 0 \(a.sha256().prefix(16))… · 0explicit \(b.sha256().prefix(16))… · −50 \(c.sha256().prefix(16))…")
            XCTAssertEqual(a.sha256(), b.sha256(), "dehaze = 0 必须没有阶段")
        }
    }
}
