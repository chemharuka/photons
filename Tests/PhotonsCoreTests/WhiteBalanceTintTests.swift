import XCTest
import Metal
@testable import PhotonsCore

/// 240 — **the drag's tint axis against the decoder's own**.
///
/// The defect: the preview's `(temperature, tint)` went through a Bradford adaptation built on
/// `WhiteBalanceEstimate.tintPerUnit = 0.00005`, a display-scale guess with no measurement behind it.
/// `CIRAWFilter.neutralTint` moves the white point along the same locus normal but **6.86×** further,
/// so a tint drag was a small fraction of the move the settled frame makes — the "tint deviation"
/// this task is about.
///
/// This suite is the acceptance gate on the repo's synthetic ground truth
/// (`tools/wb-calibrate/chart256.dng`, whose rows 0–1 are 32 neutral patches that decode to `R=G=B`
/// at the file's as-shot pair). For each of the 9 pairs named by §1.4 it measures the shipped drag
/// path against the settled decode:
///
///   · **chromaticity difference** — each patch is scaled to the settled frame's own mean, so a
///     white-balance *level* difference cannot masquerade as a tint difference; the maximum channel
///     difference in 8-bit codes, median over the 32 patches, must be **≤ 6**;
///   · **neutrality excess** — `spread(drag) − spread(settled)` per patch (`spread = max(R,G,B) −
///     min(R,G,B)`), median ≤ **4**: the drag may not make a neutral patch less neutral than the
///     decoder itself does at the same pair.
///
/// The second test is the reverse gate: the same grid with the old `0.00005` scale, applied through
/// the test-only `previewMatrixOverride`, must fail at least one pair. Without it the calibrated
/// coefficient would not be shown to be load-bearing.
final class WhiteBalanceTintTests: XCTestCase {

    private static let pairs: [(name: String, whiteBalance: WhiteBalance)] = [
        ("4000 K / −50", WhiteBalance(temperature: 4000, tint: -50)),
        ("4000 K / 0", WhiteBalance(temperature: 4000, tint: 0)),
        ("4000 K / +50", WhiteBalance(temperature: 4000, tint: 50)),
        ("5500 K / −50", WhiteBalance(temperature: 5500, tint: -50)),
        ("5500 K / 0", WhiteBalance(temperature: 5500, tint: 0)),
        ("5500 K / +50", WhiteBalance(temperature: 5500, tint: 50)),
        ("6500 K / −50", WhiteBalance(temperature: 6500, tint: -50)),
        ("6500 K / 0", WhiteBalance(temperature: 6500, tint: 0)),
        ("6500 K / +50", WhiteBalance(temperature: 6500, tint: 50)),
    ]

    private static let grid = 16
    private static let inner = 8
    private static let neutralPatches = 32

    private var chartURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tools/wb-calibrate/chart256.dng")
    }

    // MARK: - the gate

    func testCalibratedTintAxisMatchesTheDecoderAcrossNinePairs() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let fixture = try Fixture(chartURL: chartURL)
        var worstChroma = 0
        var worstExcess = 0
        for (name, pair) in Self.pairs {
            let truth = try fixture.settled(pair)
            let drag = try fixture.drag(to: pair)
            let m = Self.metrics(truth: truth, drag: drag)
            print(String(format: "240 gate %-14@ chroma med %3d max %3d · spread excess med %+3d max %+3d",
                         name as NSString, m.chromaMedian, m.chromaMax,
                         m.excessMedian, m.excessMax))
            XCTAssertLessThanOrEqual(m.chromaMedian, 6,
                                     "\(name): the drag's neutral patches are \(m.chromaMedian) codes "
                                     + "off the decoder's (median, limit 6)")
            XCTAssertLessThanOrEqual(m.excessMedian, 4,
                                     "\(name): the drag is \(m.excessMedian) codes less neutral than "
                                     + "the decoder itself (median excess, limit 4)")
            worstChroma = max(worstChroma, m.chromaMedian)
            worstExcess = max(worstExcess, m.excessMedian)
        }
        print("240 gate worst: chroma \(worstChroma) · excess \(worstExcess) (limits 6 / 4)")
    }

    /// **Reverse gate.** The old scale is put back only for the drag matrix (the decoder side
    /// unchanged), and at least one of the nine pairs must leave the budget. If this passes, the
    /// calibrated `tintPerUnit` is not doing any work and the gate above is decoration.
    func testLegacyTintScaleWouldFailTheSameGrid() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let fixture = try Fixture(chartURL: chartURL)
        var failures: [String] = []
        for (name, pair) in Self.pairs {
            let truth = try fixture.settled(pair)
            let legacy = try fixture.drag(to: pair, override: fixture.legacyMatrix(to: pair))
            let m = Self.metrics(truth: truth, drag: legacy)
            let failed = m.chromaMedian > 6 || m.excessMedian > 4
            if failed { failures.append(name) }
            print(String(format: "240 legacy %-14@ chroma med %3d · spread excess med %+3d → %@",
                         name as NSString, m.chromaMedian, m.excessMedian,
                         failed ? "red" : "green"))
        }
        XCTAssertFalse(failures.isEmpty,
                       "the legacy 0.00005 tint scale passed every pair — the reverse gate does not "
                       + "discriminate, so the calibrated coefficient is not proven load-bearing")
    }

    // MARK: - fixture

    /// One as-shot decode reused by every drag, plus the chart's as-shot pair and a renderer.
    private struct Fixture {
        let url: URL
        let asShot: LinearImage
        let asShotPair: WhiteBalance
        let decoder: RAWDecoder

        init(chartURL: URL) throws {
            guard FileManager.default.fileExists(atPath: chartURL.path) else {
                throw XCTSkip("chart fixture missing: \(chartURL.path)")
            }
            url = chartURL
            let outcome = try RAWDecoder().decodeDetailed(
                chartURL, options: DecodeOptions(scale: 1, whiteBalance: .asShot))
            asShot = outcome.image
            asShotPair = outcome.capabilities.asShotWhiteBalance
            decoder = try RAWDecoder()
        }

        /// The settled frame: the decoder develops the chart **at** the pair, S1 identity.
        func settled(_ pair: WhiteBalance) throws -> DisplayImage {
            let image = try decoder.decode(url, options: DecodeOptions(scale: 1, whiteBalance: pair))
            return try render(image, buffer: pair, document: pair, override: nil)
        }

        /// The drag: the as-shot buffer on screen, the pair as S1's matrix.
        func drag(to pair: WhiteBalance, override: Matrix3? = nil) throws -> DisplayImage {
            try render(asShot, buffer: .asShot, document: pair, override: override)
        }

        private func render(_ image: LinearImage, buffer: WhiteBalance, document: WhiteBalance,
                            override: Matrix3?) throws -> DisplayImage {
            let graph = try RenderGraph(input: RenderInput(image: image, identity: "240",
                                                           whiteBalance: buffer,
                                                           asShotPair: asShotPair))
            graph.previewMatrixOverride = override
            var edit = EditModel.neutral
            edit.light.temperature = document.temperature
            edit.light.tint = document.tint
            let options = RenderOptions(scale: 1,
                                        display: DisplayOptions(primaries: .sRGB, bitDepth: 8),
                                        useCache: false, wantsPixels: true)
            return try XCTUnwrap(graph.render(edit, options: options).display)
        }

        /// The pre-240 model for one pair, in working RGB: `M(doc) · M(asShot)⁻¹`, with the old
        /// `0.00005` uv/tint-unit scale. The anchor telescopes out, so this is the same quantity the
        /// shipped `previewMatrix(from:to:asShotPair:)` computes — only the tint scale differs.
        func legacyMatrix(to document: WhiteBalance) -> Matrix3 {
            let target = legacyMatrix(temperature: document.temperature ?? 6500,
                                      tint: document.tint ?? 0)
            let base = legacyMatrix(temperature: asShotPair.temperature ?? 6500,
                                    tint: asShotPair.tint ?? 0)
            return target * base.inverted()
        }

        /// The historical scale, kept only here as the counter-proof's input.
        private static let legacyTintPerUnit = 0.00005

        private func legacyMatrix(temperature: Double, tint: Double) -> Matrix3 {
            let t = min(max(temperature, WhiteBalanceSolver.searchRange.lowerBound),
                        WhiteBalanceSolver.searchRange.upperBound)
            let (u, v) = WhiteBalanceEstimate.planckianUV(t)
            let (u0, v0) = WhiteBalanceEstimate.planckianUV(t - 1)
            let (u1, v1) = WhiteBalanceEstimate.planckianUV(t + 1)
            var nu = -(v1 - v0), nv = u1 - u0
            let n = (nu * nu + nv * nv).squareRoot()
            if n > 1e-12 { nu /= n; nv /= n } else { nu = 0; nv = 1 }
            if nv < 0 { nu = -nu; nv = -nv }
            let du = nu * tint * Self.legacyTintPerUnit
            let dv = nv * tint * Self.legacyTintPerUnit
            let xy = WhiteBalanceEstimate.xy(fromUV: u + du, max(v + dv, 1e-4))
                ?? ColorPrimaries.whitePoint
            let adaptation = WhiteBalanceEstimate.bradfordAdaptation(
                from: xy.xyz(), to: WhiteBalanceEstimate.whitePointXYZ)
            return ColorPrimaries.working.fromXYZ * adaptation * ColorPrimaries.working.toXYZ
        }
    }

    // MARK: - measurement

    struct Metrics {
        let chromaMedian: Int
        let chromaMax: Int
        let excessMedian: Int
        let excessMax: Int
    }

    /// 32 neutral-patch means (rows 0–1), in 8-bit display codes.
    private static func neutralPatches(_ image: DisplayImage) -> [(Double, Double, Double)] {
        let cell = image.width / grid
        let offset = (cell - inner) / 2
        var out: [(Double, Double, Double)] = []
        out.reserveCapacity(neutralPatches)
        for row in 0..<2 {
            for col in 0..<grid {
                var sum = (0.0, 0.0, 0.0)
                for dy in 0..<inner {
                    for dx in 0..<inner {
                        let i = ((row * cell + offset + dy) * image.width
                                 + col * cell + offset + dx) * 4
                        sum.0 += Double(image.rgba[i]) * 255
                        sum.1 += Double(image.rgba[i + 1]) * 255
                        sum.2 += Double(image.rgba[i + 2]) * 255
                    }
                }
                let n = Double(inner * inner)
                out.append((sum.0 / n, sum.1 / n, sum.2 / n))
            }
        }
        return out
    }

    static func metrics(truth: DisplayImage, drag: DisplayImage) -> Metrics {
        precondition(truth.width == drag.width && truth.height == drag.height)
        let a = neutralPatches(truth)
        let b = neutralPatches(drag)
        var chroma: [Int] = []
        var excess: [Int] = []
        chroma.reserveCapacity(a.count)
        excess.reserveCapacity(a.count)
        for k in 0..<a.count {
            let t = a[k], d = b[k]
            // Scale the drag to the settled patch's own mean: only the colour cast is compared.
            let meanT = (t.0 + t.1 + t.2) / 3
            let meanD = (d.0 + d.1 + d.2) / 3
            let s = meanD > 1 ? meanT / meanD : 1
            let scaled = (d.0 * s, d.1 * s, d.2 * s)
            chroma.append(max(abs(Int(t.0.rounded()) - Int(scaled.0.rounded())),
                              max(abs(Int(t.1.rounded()) - Int(scaled.1.rounded())),
                                  abs(Int(t.2.rounded()) - Int(scaled.2.rounded())))))
            let spreadT = max(t.0, max(t.1, t.2)) - min(t.0, min(t.1, t.2))
            let spreadD = max(d.0, max(d.1, d.2)) - min(d.0, min(d.1, d.2))
            excess.append(Int((spreadD - spreadT).rounded()))
        }
        func median(_ v: [Int]) -> Int { v.sorted()[v.count / 2] }
        return Metrics(chromaMedian: median(chroma), chromaMax: chroma.max() ?? 0,
                       excessMedian: median(excess), excessMax: excess.max() ?? 0)
    }
}
