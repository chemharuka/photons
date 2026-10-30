import XCTest
import Metal
import PhotonsCore

/// Sub-black signal survives the tone map.
///
/// The decoder delivers scene-linear values below the black point (measured on `_1274394.dng`:
/// min −0.039, 33 M negative samples, 43 % of the frame under luma 1e−6). Inside that band the
/// 32×32 block means vary with σ 5.7e−4 while pure noise would give 2.5e−5 — the detail Lightroom
/// lifts. `s2_tone_map` used to clamp it away at four places (`max(c.rgb, 0)`, the remap, the
/// `pow`, and the write), so no slider could ever bring it back.
///
/// These tests pin the two halves of the contract: nothing changes for an ordinary edit (the display
/// clamp in S4 still ends at the same pixels), and a strong lift can now resolve a staircase that
/// lives entirely below zero.
///
/// **073B changed which control is the lift.** For the first half of its travel `blacks` is a pure
/// multiplier (±3 EV at the dark end), and multiplying a negative keeps it negative: the *fine*
/// additive control that can pull sub-black data across zero is 071's `blackOffset` (「可选到 −10 和
/// +10，对应于让 0 值变为 ±0.01」), which the tests below still pin the staircase against.
///
/// **073C moved the black point in the second half.** `|blacks| > 50` blends in a level term
/// (`+B_LEV`, applied after a 1.5 EV darkening), so `blacks = +100` — like Lightroom's black level —
/// does recover the *shallow* sub-black bands while the deeper ones stay clamped at 0. That is the
/// owner's 「后面逐步变为修改电平」, and it is pinned below band by band; the first half of the travel
/// still has to keep every negative sample negative, which is 073B's claim and is still asserted.
final class SubBlackSignalTests: XCTestCase {

    private func makeGraph(_ image: LinearImage) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: "sub-black"))
    }

    /// Six vertical bands, every one of them below black: −0.004 … +0.001 in 0.001 steps.
    private func staircase(width: Int = 120, height: Int = 40) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        let values: [Float] = [-0.004, -0.003, -0.002, -0.001, 0.0, 0.001]
        for y in 0..<height {
            for x in 0..<width {
                let band = min(values.count - 1, x * values.count / width)
                let v = Float16(values[band])
                let o = (y * width + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "test")
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        var options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        options.collectHistogram = false
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    /// Column means of the display image (one value per staircase band centre).
    private func bandMeans(_ image: DisplayImage, bands: Int = 6) -> [Double] {
        var out: [Double] = []
        for band in 0..<bands {
            let x = (image.width * (band * 2 + 1)) / (bands * 2)
            var sum = 0.0
            for y in 0..<image.height {
                let o = (y * image.width + x) * 4
                sum += Double(image.rgba[o])
            }
            out.append(sum / Double(image.height))
        }
        return out
    }

    /// A strong lift must resolve the staircase: neighbouring bands are visibly different.
    ///
    /// The lift has to be **additive**, because that is what a negative value needs: `exposure`,
    /// `blacks` and `shadows` multiply, and multiplying a negative keeps it negative (a property of the
    /// maths, not of the clamp). That is 071's `blackOffset` — `+0.01` shifts every sample by 0.01 in
    /// scene-linear light *before* the gain, so −0.004…+0.001 becomes +0.006…+0.011 and the whole
    /// staircase comes out above black, separated.
    func testTheBlackOffsetResolvesASubBlackStaircase() throws {
        let graph = try makeGraph(staircase())
        var edit = EditModel.neutral
        edit.light.blackOffset = 0.01    // −0.004 → +0.006 … +0.001 → +0.011

        let means = bandMeans(try render(graph, edit))
        print("sub-black staircase means (blackOffset +0.01):", means.map { String(format: "%.4f", $0) })
        for i in 1..<means.count {
            XCTAssertGreaterThan(means[i], means[i - 1] + 1e-5,
                                 "band \(i) did not separate from band \(i-1): \(means)")
        }
        XCTAssertGreaterThan(means.first!, 0.001, "the darkest band was not pulled above black")
        XCTAssertGreaterThan(means.last! - means.first!, 0.001,
                             "the staircase collapsed — the sub-black signal is still being clamped")
    }

    /// **Where the multiplier stops and the level starts.** For `|blacks| ≤ 20` the four negative bands
    /// stay negative and S2/S4 clamp them to 0 — `0 → 0`, which is 073B's claim and is still true.
    /// (129: the level's entry is 20, not 50 — `smoothstep(0.2, 1, |blacks|/100)` is exactly 0 there,
    /// so ±20 is the last value whose kernel instance is the pure multiplier.)
    ///
    /// At `blacks = +100` the black point itself moves. Since a4494626 (2026-10-29) the level is
    /// `+B_LEV = +0.006` outside a **full 3 EV** gain, `v′ = v·2³ + 0.006`, so the black point sits
    /// at `v = −0.00075`: a `0.0` sample comes back (0.0701 display) while the negative bands
    /// (−0.001 and deeper) stay under it. (Before that commit the gain was the halved 1.5 EV and the
    /// level 0.005, i.e. a −0.0018 point — which is why this test used to expect the −0.001 band.)
    func testTheLevelHalfMovesTheBlackPointAndTheEVHalfDoesNot() throws {
        let graph = try makeGraph(staircase())

        // The first half: still a pure multiplier, every negative band stays clamped.
        for blacks in [20.0, -20] {
            var edit = EditModel.neutral
            edit.light.blacks = blacks
            let means = bandMeans(try render(graph, edit))
            for i in 0..<5 {
                XCTAssertEqual(means[i], 0, accuracy: 1e-4,
                               "blacks \(blacks): band \(i) (a negative sample) was lifted — the "
                               + "first half of the travel is a multiplier (\(means))")
            }
        }

        // 129 (2026-10-30): past 20 the level is on, so this test **stops here** — the sub-black bands
        // are no longer all clamped for `|blacks| > 20` and which of them clear the black point is the
        // gain/level ratio's business, pinned by `BlacksBoundaryTests` (which does it band by band and
        // asserts the `50 → 50.01` seam is gone). This one pins the entry point: at exactly ±20 the
        // kernel instance is still the pure multiplier and every negative band is still clamped.

        // The second half: the black point moves, band by band.
        var edit = EditModel.neutral
        edit.light.blacks = 100
        let means = bandMeans(try render(graph, edit))
        print("sub-black staircase means (blacks +100):", means.map { String(format: "%.4f", $0) })
        XCTAssertGreaterThan(means[4], 0.01,
                             "band 4 (0.0) must come back: at +100 the black point moved to −0.00075")
        for i in 0..<4 {
            XCTAssertEqual(means[i], 0, accuracy: 1e-4,
                           "band \(i) is below −0.00075 and must stay under the black point: \(means)")
        }
        // Order is preserved: a deeper band never comes out brighter.
        for i in 1..<means.count {
            XCTAssertGreaterThan(means[i], means[i - 1] - 1e-4, "the staircase inverted: \(means)")
        }
        XCTAssertGreaterThan(means[5], 0.01, "the positive band must still be inside the toe")
    }

    /// An ordinary edit (no lift) ends at the same pixels as before: the display clamp in S4 is the
    /// only place that decides, so keeping the sign must not brighten anything by accident.
    func testAnOrdinaryEditStillEndsAtZeroForSubBlackPixels() throws {
        let graph = try makeGraph(staircase())
        var edit = EditModel.neutral
        edit.light.contrast = 10          // a real tone-map pass, but no lift
        edit.light.blacks = -5            // 073B: a multiplier, so it darkens rather than shifting

        let means = bandMeans(try render(graph, edit))
        print("sub-black staircase with a normal edit:", means.map { String(format: "%.5f", $0) })
        // The five bands at or below zero must end at exactly 0 — the display clamp is the only judge.
        // The sixth sample is +0.001 of *light* (a real, if tiny, positive value): 0.0053 of full
        // scale, i.e. code 3.1 on its own.
        for (i, m) in means.enumerated() where i < 5 {
            XCTAssertEqual(m, 0, accuracy: 1e-4,
                           "band \(i) lit up without a lift (\(m)) — the display clamp is the only judge")
        }
        // 0107: the bound is **"no brighter than neutral"**, not "≤ 2 codes". The two-code figure was
        // the *old* curve's: a linear-light power crushes everything below its 0.18 pivot
        // (0.001 → 0.00049, code 1.6), so the assertion was pinning the arithmetic and not the
        // invariant. The log2-domain bend's toe is a bounded gain — `2^(−0.85·contrast/100)` = 0.94 at
        // `+10` — so this sample now renders at 2.8 codes, i.e. *darker* than its own neutral. Pinned as
        // "an ordinary edit may not brighten the toe", with a loose ceiling that still catches "grey".
        var neutral = EditModel.neutral
        neutral.light.blacks = -5
        let neutralMeans = bandMeans(try render(graph, neutral))
        print("sub-black staircase: neutral band 6 = \(neutralMeans[5] * 255) codes, "
              + "with contrast +10 & blacks −5 = \(means[5] * 255)")
        // 159 (contrast → S2.5) note: the residual gain now reads this sample on the tone map's
        // display output instead of on scene light, which moves the *float* mean by +0.0039 codes
        // (2.99995 vs 2.99606). That is below the 1/255 step of anything displayed or hashed — both
        // render as code 3 — so the invariant is stated at the granularity the invariant has: no
        // 8-bit code may rise. A real brightening (the failure this test was written for) moves a
        // whole code and still fails.
        XCTAssertLessThanOrEqual((means[5] * 255).rounded(), (neutralMeans[5] * 255).rounded(),
                                 "an ordinary edit brightened a +0.001 sample")
        XCTAssertLessThanOrEqual(means[5] * 255, 4,
                                 "a +0.001 sample must not render as grey")
    }

    /// Blacks stays monotone across its whole range on a sub-black staircase.
    func testBlacksStaysMonotoneOnSubBlackPixels() throws {
        let graph = try makeGraph(staircase())
        var previous = -Double.infinity
        for blacks in stride(from: -100.0, through: 100.0, by: 25.0) {
            var edit = EditModel.neutral
            edit.light.blacks = blacks
            edit.light.exposure = 3
            let means = bandMeans(try render(graph, edit))
            let brightest = means.max() ?? 0
            XCTAssertGreaterThanOrEqual(brightest, previous - 1e-4,
                                        "blacks \(blacks) went darker than the step below it")
            previous = brightest
        }
    }
}
