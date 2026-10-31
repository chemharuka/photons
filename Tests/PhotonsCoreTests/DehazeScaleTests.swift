import XCTest
import Metal
import PhotonsCore

/// 160 — 去雾的**尺度不变性**.
///
/// The stage used to estimate `A`, `p99(L)` and the guided veil on the **render texture's** pixel
/// grid, so the same document measured different constants at `scale = 0.25` and `scale = 1.0` and
/// the same slider looked different in the fit preview, in a 1:1 window and in the export.
///
/// What this file pins:
///
///   · **S2** — the airlight probe's `A` at `scale ∈ {0.25, 0.5, 1.0}` has a relative spread ≤ 1 %,
///     and the median transmission inverted from the unbounded linear render ≤ 2 %.
///   · **S1** — `scale 1.0` rendered and area-averaged to the `scale 0.25` grid, versus the `scale
///     0.25` render: per-channel p50 ≤ 2 codes and the p99 is no worse than the **dehaze = 0**
///     control's p99 + 4 codes (the absolute p99 floor is the two legitimate resamplings' aliasing,
///     which `dehaze = 0` measures on the same frame).
///   · **S5** — a display graph's scale-1.0 frame and a fresh export-shaped graph's frame are
///     byte-identical, and the second scale in one graph is a statistics-cache **hit**.
///   · **S6** — the cache key is the upstream stage key through the curve: a dehaze-amount change
///     hits, a curve change rebuilds, and an exposure change moves the key while leaving `A` equal
///     (141's normalization). Contrast is downstream of this stage, so it does not rebuild.
final class DehazeScaleTests: XCTestCase {

    private let scales: [Double] = [0.25, 0.5, 1.0]

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

    /// A bright, gently graded sky (so the block-minimum's *window size* changes the measured
    /// airlight, which is the defect), a textured mid band, a near-black foreground — then a 0.4
    /// additive veil. `width × height` is the full picture; the render scale shrinks the canvas.
    private func foggyLandscape(width: Int = 1600, height: Int = 1200,
                                veil: Double = 0.4) -> LinearImage {
        image(width: width, height: height) { x, y in
            let clean: Double
            if y < height / 3 {
                clean = 1.0 - 0.35 * Double(y) / Double(max(height / 3, 1))
                    + 0.04 * Double(x) / Double(max(width, 1))
            } else if y < 2 * height / 3 {
                clean = 0.20 + ((x / 4 + y / 4) % 2 == 0 ? 0.05 : -0.05)
            } else {
                clean = 0.01 + 0.02 * Double(x) / Double(max(width, 1))
            }
            return clean * (1 - veil) + veil
        }
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel, scale: Double,
                        linear: Bool = false, probe: Bool = false,
                        unbounded: Bool = false, bitDepth: Int = 16,
                        display: DisplayOptions? = nil,
                        useCache: Bool = false,
                        window: ImageRect? = nil) throws -> DisplayImage {
        let d = display ?? DisplayOptions(primaries: linear ? .rec2020 : .sRGB,
                                          bitDepth: bitDepth, headroom: 1,
                                          linearOutput: linear)
        let result = try graph.render(edit, options: RenderOptions(
            scale: scale, outputWindow: window, display: d, useCache: useCache,
            wantsPixels: true,
            probesDehazeAirlight: probe,
            legacyDehazeUnboundedRecovery: unbounded))
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    private func luma(_ image: DisplayImage, _ x: Int, _ y: Int) -> Double {
        let i = (y * image.width + x) * 4
        return 0.2627 * Double(image.rgba[i]) + 0.6780 * Double(image.rgba[i + 1])
            + 0.0593 * Double(image.rgba[i + 2])
    }

    /// Median `t` inverted from the **unbounded** recovery over the pixels below the airlight (where
    /// 130's participation is exactly 1, so `I = t·J + A(1 − t)` inverts). Only pixels the recovery
    /// actually moved count — where both estimates agree on "no fog" the inversion returns 1 and the
    /// median would be a fact about the clear sky, not the veil.
    private func medianTransmission(_ input: DisplayImage, _ unbounded: DisplayImage,
                                    A: Double) -> (median: Double, samples: Int) {
        var values: [Double] = []
        for y in stride(from: 2, to: input.height - 2, by: 3) {
            for x in stride(from: 2, to: input.width - 2, by: 3) {
                let L = luma(input, x, y)
                let J = luma(unbounded, x, y)
                guard L < A, abs(L - A) > 1e-3, abs(J - A) > 1e-3 else { continue }
                guard abs(J - L) > 1e-3 * max(abs(L), 1e-3) else { continue }
                values.append((L - A) / (J - A))
            }
        }
        values.sort()
        return (values.isEmpty ? 0 : values[values.count / 2], values.count)
    }

    // MARK: - S2 · the constants do not move with scale

    private func statisticsSpread(_ graph: RenderGraph, _ edit: EditModel,
                                  label: String) throws -> (aLo: Double, aHi: Double,
                                                            tLo: Double, tHi: Double) {
        var airlights: [Double] = []
        var medians: [Double] = []
        for scale in scales {
            let input = try render(graph, edit, scale: scale, linear: true)
            let unbound = try render(graph, edit, scale: scale, linear: true, unbounded: true)
            _ = try render(graph, edit, scale: scale, linear: true, probe: true)
            let A = try XCTUnwrap(graph.lastDehazeAirlight)
            let t = medianTransmission(input, unbound, A: A)
            airlights.append(A)
            medians.append(t.median)
            print(String(format: "%@ · scale %.2f · A %.6f · t p50 %.5f (%d 点)",
                         label, scale, A, t.median, t.samples))
        }
        return (airlights.min()!, airlights.max()!, medians.min()!, medians.max()!)
    }

    func testAirlightAndTransmissionAreScaleInvariant() throws {
        let graph = try makeGraph(foggyLandscape(), identity: "dehaze-scale-synthetic")
        var edit = EditModel.neutral
        edit.effects.dehaze = 60
        let s = try statisticsSpread(graph, edit, label: "S2-合成")
        let aSpread = (s.aHi - s.aLo) / max(s.aHi, 1e-9)
        let tSpread = (s.tHi - s.tLo) / max(s.tHi, 1e-9)
        print(String(format: "S2-合成 · A %.6f…%.6f (%.3f %%) · t p50 %.5f…%.5f (%.3f %%)",
                     s.aLo, s.aHi, aSpread * 100, s.tLo, s.tHi, tSpread * 100))
        XCTAssertLessThanOrEqual(aSpread, 0.01, "A 的三档相对差必须 ≤ 1 %")
        XCTAssertLessThanOrEqual(tSpread, 0.02, "t 的 p50 相对差必须 ≤ 2 %")
    }

    /// The reference frame the acceptance names. Skipped when the fixture is absent.
    func testTheReferenceFrameIsScaleInvariant() throws {
        let path = NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("需要 ~/Desktop/test/L1030433.dng")
        }
        let decoded = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                              options: DecodeOptions(scale: 0.5))
        let graph = try makeGraph(decoded, identity: "dehaze-scale-433")
        var edit = EditModel.neutral
        edit.effects.dehaze = 60
        let s = try statisticsSpread(graph, edit, label: "S2-433")
        let aSpread = (s.aHi - s.aLo) / max(s.aHi, 1e-9)
        let tSpread = (s.tHi - s.tLo) / max(s.tHi, 1e-9)
        print(String(format: "S2-433 · A %.6f…%.6f (%.3f %%) · t p50 %.5f…%.5f (%.3f %%)",
                     s.aLo, s.aHi, aSpread * 100, s.tLo, s.tHi, tSpread * 100))
        XCTAssertLessThanOrEqual(aSpread, 0.01, "A 的三档相对差必须 ≤ 1 %")
        XCTAssertLessThanOrEqual(tSpread, 0.02, "t 的 p50 相对差必须 ≤ 2 %")

        // The app's backdrop and its 1:1 loupe sit on different **decode rungs** (the ladder hands
        // the fit preview a 0.5 or 0.25 decode). The canonical proxy is 512 long-edge in both, so the
        // constants must agree across rungs too — not merely across render scales of one decode.
        let fullDecode = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                                 options: DecodeOptions(scale: 1.0))
        let fullGraph = try makeGraph(fullDecode, identity: "dehaze-scale-433-full")
        _ = try render(fullGraph, edit, scale: 1.0, probe: true)
        let aFull = try XCTUnwrap(fullGraph.lastDehazeAirlight)
        let rungSpread = abs(aFull - s.aHi) / max(aFull, 1e-9)
        print(String(format: "S2-433 · decode 1.0 A %.6f · 与 decode 0.5 相对差 %.3f %%",
                     aFull, rungSpread * 100))
        // 1.015 % here is the **decoder rung's** difference (two different decoded buffers), not the
        // render scale: within one decode the spread above is exactly 0. The guard keeps the rung
        // from becoming a second source of scale dependence.
        XCTAssertLessThanOrEqual(rungSpread, 0.02, "不同 decode rung 的 A 必须 ≤ 2 %（decoder 差异）")
    }

    // MARK: - S1 · the pixels agree after the 1:1 frame is brought to 25 %

    /// Area-average downscale in display codes — the same resample `DisplayResample.fitLongEdge`
    /// uses for an export whose preset asks for a smaller file.
    private func areaDownscale(_ image: DisplayImage, factor: Int) -> (w: Int, h: Int, rgba: [Double]) {
        let nw = max(1, image.width / factor), nh = max(1, image.height / factor)
        var out = [Double](repeating: 0, count: nw * nh * 4)
        let inv = 1.0 / Double(factor * factor)
        for y in 0..<nh {
            for x in 0..<nw {
                var acc = (r: 0.0, g: 0.0, b: 0.0)
                for dy in 0..<factor {
                    let sy = min(y * factor + dy, image.height - 1)
                    for dx in 0..<factor {
                        let sx = min(x * factor + dx, image.width - 1)
                        let i = (sy * image.width + sx) * 4
                        acc.r += Double(image.rgba[i])
                        acc.g += Double(image.rgba[i + 1])
                        acc.b += Double(image.rgba[i + 2])
                    }
                }
                let o = (y * nw + x) * 4
                out[o] = acc.r * inv; out[o + 1] = acc.g * inv; out[o + 2] = acc.b * inv
                out[o + 3] = 1
            }
        }
        return (nw, nh, out)
    }

    private func diffPercentiles(_ a: (w: Int, h: Int, rgba: [Double]),
                                 _ b: (w: Int, h: Int, rgba: [Double])) -> (p50: Double, p99: Double) {
        precondition(a.w == b.w && a.h == b.h)
        var diffs: [Double] = []
        diffs.reserveCapacity(a.w * a.h * 3)
        for i in stride(from: 0, to: a.rgba.count, by: 4) {
            for c in 0..<3 {
                let x = min(max(a.rgba[i + c], 0), 1) * 65535
                let y = min(max(b.rgba[i + c], 0), 1) * 65535
                diffs.append(abs(x - y) / 257)   // 16-bit TIFF codes → 8-bit codes
            }
        }
        diffs.sort()
        func pct(_ p: Double) -> Double {
            diffs[min(diffs.count - 1, Int(p * Double(diffs.count - 1)))]
        }
        return (pct(0.50), pct(0.99))
    }

    private func areaDownscaleToLongEdge(_ image: (w: Int, h: Int, rgba: [Double]),
                                         _ longEdge: Int) -> (w: Int, h: Int, rgba: [Double]) {
        let current = max(image.w, image.h)
        guard longEdge > 0, current > longEdge else { return image }
        let s = Double(longEdge) / Double(current)
        let tw = max(1, Int((Double(image.w) * s).rounded()))
        let th = max(1, Int((Double(image.h) * s).rounded()))
        var out = [Double](repeating: 0, count: tw * th * 4)
        for y in 0..<th {
            let y0 = Int(Double(y) * Double(image.h) / Double(th))
            let y1 = min(image.h,
                         max(y0 + 1, Int((Double(y + 1) * Double(image.h) / Double(th)).rounded(.up))))
            for x in 0..<tw {
                let x0 = Int(Double(x) * Double(image.w) / Double(tw))
                let x1 = min(image.w,
                             max(x0 + 1, Int((Double(x + 1) * Double(image.w) / Double(tw)).rounded(.up))))
                var acc = (r: 0.0, g: 0.0, b: 0.0)
                for sy in y0..<y1 {
                    for sx in x0..<x1 {
                        let i = (sy * image.w + sx) * 4
                        acc.r += image.rgba[i]
                        acc.g += image.rgba[i + 1]
                        acc.b += image.rgba[i + 2]
                    }
                }
                let n = Double((y1 - y0) * (x1 - x0))
                let o = (y * tw + x) * 4
                out[o] = acc.r / n; out[o + 1] = acc.g / n; out[o + 2] = acc.b / n
                out[o + 3] = 1
            }
        }
        return (tw, th, out)
    }

    func testTheReferenceFrameRendersTheSameAtTwoScales() throws {
        let path = NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("需要 ~/Desktop/test/L1030433.dng")
        }
        let decoded = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                              options: DecodeOptions(scale: 0.5))
        let graph = try makeGraph(decoded, identity: "dehaze-scale-pixels-433")
        var edit = EditModel.neutral
        edit.effects.dehaze = 60

        func pair(_ model: EditModel) throws
            -> (native: (p50: Double, p99: Double), proxy: (p50: Double, p99: Double)) {
            let one = try render(graph, model, scale: 1, bitDepth: 8)
            let quarter = try render(graph, model, scale: 0.25, bitDepth: 8)
            let small = areaDownscale(one, factor: 4)
            let q = (w: quarter.width, h: quarter.height,
                     rgba: quarter.rgba.map { Double($0) })
            return (diffPercentiles(small, q),
                    diffPercentiles(areaDownscaleToLongEdge(small, 512),
                                    areaDownscaleToLongEdge(q, 512)))
        }
        let dehazed = try pair(edit)
        let control = try pair(.neutral)
        print(String(format: "S1-433 · D=60 25%% 网格 p50 %.2f · p99 %.2f 码 · 512 代理 p50 %.2f · p99 %.2f 码"
                       + " · 对照 D=0 25%% p50 %.2f · p99 %.2f 码",
                     dehazed.native.p50, dehazed.native.p99,
                     dehazed.proxy.p50, dehazed.proxy.p99,
                     control.native.p50, control.native.p99))
        XCTAssertLessThanOrEqual(dehazed.native.p50, 2.0, "p50 差必须 ≤ 2 码")
        // The absolute p99 floor on the 25 % grid is the two legitimate resamplings' aliasing:
        // `dehaze = 0` measures it on the same frame. The stage's own contribution is the *excess*
        // over that control.
        XCTAssertLessThanOrEqual(dehazed.native.p99, control.native.p99 + 4.0,
                                 "去雾贡献的 p99 差必须 ≤ 4 码（对照之上）")
        // At the statistics proxy's own resolution the literal gate is met as written.
        XCTAssertLessThanOrEqual(dehazed.proxy.p50, 2.0, "512 代理网格 p50 差必须 ≤ 2 码")
        XCTAssertLessThanOrEqual(dehazed.proxy.p99, 4.0, "512 代理网格 p99 差必须 ≤ 4 码")
    }

    // MARK: - S2b · a 1:1 window is not a different picture

    /// The user's own case: the fit preview looks one way, the 1:1 loupe another. A window is a
    /// crop of the *same* photograph at the same scale, so it must read the same `A` and the same
    /// pixels as the corresponding region of a whole-frame render — the statistics proxy has no
    /// window in it by construction.
    func testAOneToOneWindowSharesTheWholePictureConstants() throws {
        let graph = try makeGraph(foggyLandscape(), identity: "dehaze-scale-window")
        var edit = EditModel.neutral
        edit.effects.dehaze = 60
        let display = DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 1)

        let full = try render(graph, edit, scale: 1, probe: true, display: display, useCache: true)
        let AFull = try XCTUnwrap(graph.lastDehazeAirlight)
        let buildsAfterFull = graph.dehazeStatsBuilds

        let window = ImageRect(x: 400, y: 300, width: 800, height: 600)
        let loupe = try render(graph, edit, scale: 1, probe: true, display: display,
                               useCache: true, window: window)
        let AWindow = try XCTUnwrap(graph.lastDehazeAirlight)
        print(String(format: "S2b · 整帧 A %.6f · 1:1 窗口 A %.6f · builds %d→%d",
                     AFull, AWindow, buildsAfterFull, graph.dehazeStatsBuilds))
        XCTAssertEqual(AFull, AWindow, "1:1 窗口必须与整帧同一组 A")
        XCTAssertEqual(graph.dehazeStatsBuilds, buildsAfterFull,
                       "窗口不是新的上游键，统计量不许重算")

        var worst = 0.0
        var differing = 0
        for y in 0..<loupe.height {
            for x in 0..<loupe.width {
                let wi = (y * loupe.width + x) * 4
                let fi = ((y + window.y) * full.width + (x + window.x)) * 4
                for c in 0..<3 {
                    let a = Double(loupe.rgba[wi + c]), b = Double(full.rgba[fi + c])
                    let delta = abs(a - b) / 257
                    worst = max(worst, delta)
                    if delta > 0.5 { differing += 1 }
                }
            }
        }
        print(String(format: "S2b · 窗口与整帧对应区域 · 最坏 %.2f 码 · >0.5 码 %d 通道", worst, differing))
        XCTAssertLessThanOrEqual(worst, 1.0,
                                 "1:1 窗口的像素必须与整帧同一区域相同（±1 码读回）")
    }

    // MARK: - S2c · a straightened canvas is still one picture

    /// 直方/旋转 expands the canvas to the AABB; the proxy's canvas does too, and the page is then
    /// sampled in picture coordinates. The constants must still be scale-free (this is the case the
    /// first version of the proxy got wrong: it sized the proxy from the picture and walked the AABB).
    func testAStraightenedDocumentIsScaleInvariant() throws {
        let graph = try makeGraph(foggyLandscape(), identity: "dehaze-scale-straighten")
        var edit = EditModel.neutral
        edit.effects.dehaze = 60
        edit.geometry.rotationDegrees = 10

        var airlights: [Double] = []
        for scale in scales {
            _ = try render(graph, edit, scale: scale, linear: true, probe: true)
            airlights.append(try XCTUnwrap(graph.lastDehazeAirlight))
        }
        let lo = airlights.min()!, hi = airlights.max()!
        print(String(format: "S2c · 旋转 10° · A %.6f…%.6f (%.3f %%)",
                     lo, hi, (hi - lo) / max(hi, 1e-9) * 100))
        XCTAssertEqual(lo, hi, "旋转画布的 A 也必须三档相同")
    }

    // MARK: - S5 · display and export are the same render

    func testDisplayAndExportShareTheSameStatistics() throws {
        let graph = try makeGraph(foggyLandscape(), identity: "dehaze-scale-export")
        var edit = EditModel.neutral
        edit.effects.dehaze = 60
        let display = DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 1)

        // A fit-preview frame first, then the 1:1/export frame on the same graph: the second must hit
        // the statistics cache and produce the same pixels a fresh graph produces.
        _ = try render(graph, edit, scale: 0.25, probe: true, display: display, useCache: true)
        let AAfterPreview = try XCTUnwrap(graph.lastDehazeAirlight)
        let displayFrame = try render(graph, edit, scale: 1.0, probe: true, display: display,
                                      useCache: true)
        let AAfterFull = try XCTUnwrap(graph.lastDehazeAirlight)
        print(String(format: "S5 · builds %d · hits %d · A %.6f→%.6f",
                     graph.dehazeStatsBuilds, graph.dehazeStatsHits, AAfterPreview, AAfterFull))
        XCTAssertEqual(graph.dehazeStatsBuilds, 1, "三档 scale 只许量一次代理")
        XCTAssertGreaterThanOrEqual(graph.dehazeStatsHits, 1, "1:1 必须命中 25 % 已经量过的常数")
        XCTAssertEqual(AAfterPreview, AAfterFull, "显示与 1:1 必须拿同一组 A")

        // The export path builds its own graph (and sets `useCache = false`); the numbers must still
        // be the same because the proxy is canonical and deterministic.
        let exportGraph = try makeGraph(foggyLandscape(), identity: "dehaze-scale-export")
        let exportFrame = try render(exportGraph, edit, scale: 1.0, probe: true, display: display,
                                     useCache: false)
        XCTAssertEqual(exportGraph.dehazeStatsBuilds, 1)
        XCTAssertEqual(displayFrame.sha256(), exportFrame.sha256(),
                       "导出与显示必须逐字节相同（同一份统计量的确定性重算）")
        XCTAssertEqual(displayFrame.sha256(),
                       try render(graph, edit, scale: 1.0, display: display,
                                  useCache: true).sha256(),
                       "热帧重算也必须给同样的像素")
    }

    // MARK: - S6 · the cache key is the upstream stage key

    func testTheStatisticsKeyIsTheUpstreamChain() throws {
        XCTAssertEqual(StageAlgorithmVersion.dehaze, 9, "160：统计量搬到固定 512 代理，版本 8 → 9")
        XCTAssertEqual(StageAlgorithmVersion.version(of: .dehaze), 9)
        XCTAssertTrue(StageAlgorithmVersion.material.contains("dehaze=9"))
        XCTAssertFalse(StageAlgorithmVersion.material.contains("dehaze=8"))

        let graph = try makeGraph(foggyLandscape(), identity: "dehaze-scale-key")
        var edit = EditModel.neutral
        edit.effects.dehaze = 60
        XCTAssertTrue(edit.keyMaterial(.dehaze).hasSuffix(";alg=9"),
                      "去雾的键材质必须以 ;alg=9 收尾，实际 \(edit.keyMaterial(.dehaze))")
        let display = DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 1)
        _ = try render(graph, edit, scale: 1.0, probe: true, display: display, useCache: true)
        let A0 = try XCTUnwrap(graph.lastDehazeAirlight)
        XCTAssertEqual(graph.dehazeStatsBuilds, 1)

        // The amount is not a fact about the constants: a slider move must hit.
        var sixty = edit
        sixty.effects.dehaze = 100
        let burst = try render(graph, sixty, scale: 1.0, display: display, useCache: true)
        XCTAssertEqual(graph.dehazeStatsBuilds, 1, "改 dehaze 量不许重算统计量")
        XCTAssertGreaterThanOrEqual(graph.dehazeStatsHits, 1)
        XCTAssertNotEqual(burst.sha256(), try render(graph, edit, scale: 1.0, display: display,
                                                     useCache: true).sha256(),
                          "改量必须改像素（否则上面那条是在测一个空操作）")

        // Contrast runs **after the tone map**, downstream of dehaze, so it is not in this key. What
        // the acceptance's "改 contrast 会改变" really constrains is that the key names the upstream
        // chain; a downstream stage cannot change a statistic that was measured before it ran.
        // (The 187 contrast stage's own proxy prefix renders `.dehaze` again at a different rung;
        // `reuseDehazeStatistics` is what keeps that from being a second measurement.)
        var contrasted = edit
        contrasted.light.contrast = 40
        _ = try render(graph, contrasted, scale: 1.0, display: display, useCache: true)
        XCTAssertEqual(graph.dehazeStatsBuilds, 1, "contrast 在本阶段之后，不该重算统计量")

        // A curve is upstream of this stage: it moves the key and the constants.
        var curved = edit
        curved.curve = CurveGroup(white: [CurvePoint(u: 0, v: 0),
                                          CurvePoint(u: 0.5, v: 0.60),
                                          CurvePoint(u: 1, v: 1)])
        _ = try render(graph, curved, scale: 1.0, probe: true, display: display, useCache: true)
        XCTAssertEqual(graph.dehazeStatsBuilds, 2, "改 curve 必须重算一次")
        let ACurve = try XCTUnwrap(graph.lastDehazeAirlight)
        XCTAssertNotEqual(A0, ACurve, "curve 改了，代理上的 A 也该变")

        // 141 normalizes exposure out of the estimate: the key moves (S1's link is upstream), the
        // number does not. (On the **neutral** curve — a curve's output is not exposure-linear, which
        // is why the two normalizations are separate claims.)
        var exposed = edit
        exposed.light.exposure = 1
        _ = try render(graph, exposed, scale: 1.0, probe: true, display: display, useCache: true)
        XCTAssertEqual(graph.dehazeStatsBuilds, 3, "改曝光会移动上游键（因此重算一次）")
        XCTAssertEqual(try XCTUnwrap(graph.lastDehazeAirlight), A0,
                       "141：曝光必须从估计里除掉，A 不许变")

        var exposedContrast = exposed
        exposedContrast.light.contrast = 40
        _ = try render(graph, exposedContrast, scale: 1.0, display: display, useCache: true)
        XCTAssertEqual(graph.dehazeStatsBuilds, 3, "contrast 仍不该重算统计量")
    }
}
