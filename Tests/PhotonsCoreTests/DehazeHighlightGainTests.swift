import XCTest
import Metal
import PhotonsCore

/// 280 — **去雾不许把高光抬亮.**
///
/// 130's participation fade is `w = 1 − smoothstep(A, k·A, L)` with `k = 2`, so a pixel in
/// `A < L < 2A` still takes the full `1/t` recovery. At `t ≈ 0.12` that is a 1.3–2.2× gain in the
/// band just above the measured airlight — the place where a bright sky, snow or water puts the
/// airlight estimate. This file measures the gain on the user's reference frame (`L1030433.dng`) by
/// luminance percentile and pins the two halfs of the contract:
///
///   1. the bright end (`L ≥ p90`) is **not lifted**: mean gain ≤ 1.02, max gain ≤ 1.05 at
///      `dehaze = 20/50/100`;
///   2. dehaze still works in the fog (`L < A`): `J/I` stays in `[0.70, 0.98]` and falls
///      monotonically with the amount.
///
/// The `dehaze < 0` branch is **measured** (not asserted against a golden) so the report can show it
/// is byte-identical to the pre-280 formula: the fix owns only the positive branch's participation.
final class DehazeHighlightGainTests: XCTestCase {

    private let rawPath = NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// S4's linear exit: the scene light itself (Rec.2020 working primaries), no OETF, no clamp.
    private func linearRender(_ graph: RenderGraph, _ edit: EditModel,
                              probe: Bool = false) throws -> DisplayImage {
        let display = DisplayOptions(primaries: .rec2020, bitDepth: 16, headroom: 1,
                                     linearOutput: true)
        let result = try graph.render(edit, options: RenderOptions(
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

    private func rgb(_ image: DisplayImage, _ x: Int, _ y: Int) -> (Double, Double, Double) {
        let i = (y * image.width + x) * 4
        return (Double(image.rgba[i]), Double(image.rgba[i + 1]), Double(image.rgba[i + 2]))
    }

    private func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(q * Double(sorted.count - 1)))]
    }

    private struct Band {
        let name: String
        let count: Int
        let meanGain: Double
        let maxGain: Double
    }

    /// Per-luminance-band gain of `after` relative to `before`, with the band edges fixed by the
    /// **neutral** render's luminance percentiles (the same pixels are compared across amounts).
    private func bands(_ before: DisplayImage, _ after: DisplayImage, _ sorted: [Double],
                       edges: [Double]) -> [Band] {
        var sums = [Double](repeating: 0, count: edges.count + 1)
        var maxes = [Double](repeating: 0, count: edges.count + 1)
        var counts = [Int](repeating: 0, count: edges.count + 1)
        for y in 0..<before.height {
            for x in 0..<before.width {
                let l = luma(before, x, y)
                let j = luma(after, x, y)
                guard l > 1e-9 else { continue }
                var b = 0
                while b < edges.count, l >= edges[b] { b += 1 }
                let gain = j / l
                sums[b] += gain
                maxes[b] = max(maxes[b], gain)
                counts[b] += 1
            }
        }
        let names = ["p0–p50", "p50–p90", "p90–p99", "p99–p99.9", "p99.9–p100"]
        return (0...edges.count).map { i in
            Band(name: names[min(i, names.count - 1)], count: counts[i],
                 meanGain: counts[i] > 0 ? sums[i] / Double(counts[i]) : 1,
                 maxGain: counts[i] > 0 ? maxes[i] : 1)
        }
    }

    func testTheBrightEndIsNotLiftedAndTheFogStillIs() throws {
        guard FileManager.default.fileExists(atPath: rawPath) else {
            throw XCTSkip("需要 ~/Desktop/test/L1030433.dng")
        }
        let decoded = try RAWDecoder().decode(URL(fileURLWithPath: rawPath),
                                              options: DecodeOptions(scale: 0.25))
        let graph = try makeGraph(decoded, identity: "dehaze-highlight-gain-433")
        let neutral = EditModel.neutral
        let before = try linearRender(graph, neutral)

        let amounts: [Double] = [20, 50, 100]
        var renders: [Double: DisplayImage] = [:]
        for a in amounts {
            var edit = neutral
            edit.effects.dehaze = a
            renders[a] = try linearRender(graph, edit, probe: a == 100)
        }
        let probeA = try XCTUnwrap(graph.lastDehazeAirlight)

        var lumas: [Double] = []
        lumas.reserveCapacity(before.width * before.height)
        for y in 0..<before.height {
            for x in 0..<before.width { lumas.append(luma(before, x, y)) }
        }
        lumas.sort()
        let p50 = percentile(lumas, 0.50), p90 = percentile(lumas, 0.90)
        let p99 = percentile(lumas, 0.99), p999 = percentile(lumas, 0.999)
        let p100 = lumas.last ?? 0
        let edges = [p50, p90, p99, p999]

        // 135's cap in the same units: `A = 0.95·p99` when the raw block maximum is materially above
        // the picture's bright end (2 % deadband). The probe reads `airlight` (A_raw), not `limited`,
        // so this is the A the apply pass actually uses.
        let A = (probeA > 1.02 * p99) ? 0.95 * p99 : probeA
        print(String(format: "280 · A_raw %.4f · A_used %.4f · A_raw/p99 %.3f · A_used/p99 %.3f",
                     probeA, A, probeA / max(p99, 1e-9), A / max(p99, 1e-9)))
        print(String(format: "280 · p50 %.4f · p90 %.4f · p99 %.4f · p99.9 %.4f · p100 %.4f · 2A %.4f",
                     p50, p90, p99, p999, p100, 2 * A))

        var failures: [String] = []
        for a in amounts {
            let bands = bands(before, try XCTUnwrap(renders[a]), lumas, edges: edges)
            let rows = bands.map {
                String(format: "%@ avg %.3f max %.3f", $0.name, $0.meanGain, $0.maxGain)
            }
            print("280 · dehaze \(Int(a)) · " + rows.joined(separator: " · "))

            // 1. The bright end: **every** band at or above p90 is checked, not just their combined
            // mean (the darkening below p90 must not be able to hide a lifted p99).
            let high = bands[2...]
            let highMax = high.map(\.maxGain).max() ?? 1
            print(String(format: "280 · dehaze %d · p90–p100 分箱 avg %@ · 全图最大 gain %.4f",
                         Int(a), high.map { String(format: "%.3f", $0.meanGain) }.joined(separator: "/"),
                         highMax))
            for b in high where b.meanGain > 1.02 {
                failures.append("dehaze \(Int(a)) \(b.name) 平均 \(b.meanGain) > 1.02")
            }
            if highMax > 1.05 { failures.append("dehaze \(Int(a)) 最大 gain \(highMax) > 1.05") }
        }

        // C1's probe: gain in bands of `L/A` (the airlight the apply pass uses). A lift that lives in
        // `A … 2A` and is gone at `2A` is the 130 edge and the `1/t` recovery, not an estimator drift.
        let aLabels = ["<0.5A", "0.5–0.8A", "0.8–1.0A", "1.0–1.2A", "1.2–1.5A", "1.5–2.0A", "≥2.0A"]
        let aEdges = [0.5, 0.8, 1.0, 1.2, 1.5, 2.0].map { $0 * A }
        for a in amounts {
            let after = try XCTUnwrap(renders[a])
            var sums = [Double](repeating: 0, count: aLabels.count)
            var maxes = [Double](repeating: 0, count: aLabels.count)
            var counts = [Int](repeating: 0, count: aLabels.count)
            for y in 0..<before.height {
                for x in 0..<before.width {
                    let l = luma(before, x, y)
                    guard l > 1e-9 else { continue }
                    var b = 0
                    while b < aEdges.count, l >= aEdges[b] { b += 1 }
                    let gain = luma(after, x, y) / l
                    sums[b] += gain
                    maxes[b] = max(maxes[b], gain)
                    counts[b] += 1
                }
            }
            let rows = (0..<aLabels.count).map { i in
                String(format: "%@ avg %.3f max %.3f (%d)", aLabels[i],
                       counts[i] > 0 ? sums[i] / Double(counts[i]) : 1,
                       counts[i] > 0 ? maxes[i] : 1, counts[i])
            }
            print("280 · dehaze \(Int(a)) · gain by L/A · " + rows.joined(separator: " · "))
        }

        // 2. The fog still darkens and falls monotonically. Print the ratio in A-relative bands so
        // the sample is chosen from the measurement, not before it; the near-`A` strip is the one
        // 130's symmetric fade deliberately leaves alone.
        func fogRatio(_ image: DisplayImage, A: Double, lo: Double, hi: Double) -> (ratio: Double, count: Int) {
            var i = 0.0, j = 0.0, n = 0
            for y in 0..<before.height {
                for x in 0..<before.width {
                    let l = luma(before, x, y)
                    guard l > 1e-6, l >= A * lo, l < A * hi else { continue }
                    i += l
                    j += luma(image, x, y)
                    n += 1
                }
            }
            return (j / max(i, 1e-9), n)
        }
        let fogEdges: [(Double, Double)] = [(0, 0.3), (0.3, 0.5), (0.5, 0.7), (0.7, 0.9),
                                            (0.9, 1.0), (0, 1.0), (0.5, 0.9)]
        var fog: [Double: [(Double, Int)]] = [:]
        for a in amounts {
            let render = try XCTUnwrap(renders[a])
            fog[a] = fogEdges.map { fogRatio(render, A: A, lo: $0.0, hi: $0.1) }
        }
        for a in amounts {
            let rows = zip(fogEdges, try XCTUnwrap(fog[a])).map {
                String(format: "%.1f–%.1fA %.4f (%d)", $0.0.0, $0.0.1, $0.1.0, $0.1.1)
            }
            print("280 · dehaze \(Int(a)) · 雾区 J/I · " + rows.joined(separator: " · "))
        }
        // Same table in units of the **raw** airlight the probe reads (before 135's cap). This is the
        // sample the acceptance uses: the mid-fog band `L ∈ [0.5, 0.9)·A_raw`, i.e. haze that is
        // neither the estimator's own near-`A` deadband nor the dark objects under it.
        var fogRaw: [Double: [(Double, Int)]] = [:]
        for a in amounts {
            let render = try XCTUnwrap(renders[a])
            fogRaw[a] = fogEdges.map { fogRatio(render, A: probeA, lo: $0.0, hi: $0.1) }
        }
        for a in amounts {
            let rows = zip(fogEdges, try XCTUnwrap(fogRaw[a])).map {
                String(format: "%.1f–%.1fAraw %.4f (%d)", $0.0.0, $0.0.1, $0.1.0, $0.1.1)
            }
            print("280 · dehaze \(Int(a)) · 雾区(rawA) J/I · " + rows.joined(separator: " · "))
        }
        // The sample: `L ∈ [0.5, 0.9)·A_raw` (last edge in `fogEdges`).
        let fogSample = fogEdges.count - 1
        let r20 = try XCTUnwrap(fogRaw[20])[fogSample].0
        let r50 = try XCTUnwrap(fogRaw[50])[fogSample].0
        let r100 = try XCTUnwrap(fogRaw[100])[fogSample].0
        if !(r100 >= 0.70 && r100 <= 0.98) { failures.append("雾区 J/I \(r100) 不在 [0.70, 0.98]") }
        if !(r20 > r50 && r50 > r100) {
            failures.append("雾区 J/I 不随 dehaze 单调下降: \(r20) / \(r50) / \(r100)")
        }

        // C3's probe: a saturated specular highlight (`max_c > 2·L`) is exactly where a luminance
        // participation test could mistake a bright object for fog. Its share and gain are printed so
        // the report can rule it out (or make it the owner).
        for a in amounts {
            let after = try XCTUnwrap(renders[a])
            var satSum = 0.0, satN = 0, satMax = 0.0
            var satAllN = 0, satAllMax = 1.0
            var neutralSum = 0.0, neutralN = 0
            for y in 0..<before.height {
                for x in 0..<before.width {
                    let l = luma(before, x, y)
                    guard l > 1e-9 else { continue }
                    let c = rgb(before, x, y)
                    let gain = luma(after, x, y) / l
                    let saturated = max(c.0, max(c.1, c.2)) >= 2 * l
                    if saturated {
                        satAllN += 1
                        satAllMax = max(satAllMax, gain)
                    }
                    guard l >= p90 else { continue }
                    if saturated {
                        satSum += gain; satN += 1; satMax = max(satMax, gain)
                    } else {
                        neutralSum += gain; neutralN += 1
                    }
                }
            }
            print(String(format: "280 · dehaze %d · C3: 饱和(max/L≥2) 全图 %d 点 max %.3f · p90+ %d 点 avg %.3f max %.3f · 其余 p90+ %d 点 avg %.3f",
                         Int(a), satAllN, satAllMax, satN, satN > 0 ? satSum / Double(satN) : 1, satMax,
                         neutralN, neutralN > 0 ? neutralSum / Double(neutralN) : 1))
        }

        // 3. `dehaze < 0` (add fog) never enters the recovery: it must be byte-identical to the
        // pre-280 formula, which is `hazy = 0.6·I + 0.4·A` mixed by the amount.
        var negative = neutral
        negative.effects.dehaze = -50
        let hazy = try linearRender(graph, negative)
        print("280 · dehaze −50 sha \(hazy.sha256().prefix(16))…")

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: " · "))
    }
}
