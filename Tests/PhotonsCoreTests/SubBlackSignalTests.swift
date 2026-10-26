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
    /// The lift has to be **additive**, because that is what a negative value needs: `exposure` and
    /// `shadows` multiply, and multiplying a negative keeps it negative (so those sliders still cannot
    /// reach below black — a property of the maths, not of the clamp). `blacks +` moves the input black
    /// point *down*, which adds light, so it is the operator that can pull sub-black data up.
    func testAnAdditiveLiftResolvesASubBlackStaircase() throws {
        let graph = try makeGraph(staircase())
        var edit = EditModel.neutral
        edit.light.blacks = 100          // blk = −0.15: −0.004 → 0.146 … +0.001 → 0.151

        let means = bandMeans(try render(graph, edit))
        print("sub-black staircase means (blacks +100):", means.map { String(format: "%.4f", $0) })
        for i in 1..<means.count {
            XCTAssertGreaterThanOrEqual(means[i], means[i - 1] - 1e-4,
                                        "band \(i) dropped below band \(i-1): \(means)")
        }
        XCTAssertGreaterThan(means.last! - means.first!, 0.001,
                             "the staircase collapsed — the sub-black signal is still being clamped")
    }

    /// The same lift on an image whose sub-black samples are already gone (all ≥ 0) must give the
    /// same answer as before the change — proving the difference really is the preserved sign.
    func testTheResolvedStaircaseNeedsTheSubBlackSamples() throws {
        let graph = try makeGraph(staircase())
        var additive = EditModel.neutral
        additive.light.blacks = 100
        let means = bandMeans(try render(graph, additive))
        // The two darkest bands differ by ~1e-3 linear; on screen that is a visible step, not a flat 0.
        XCTAssertGreaterThan(means[1] - means[0], 1e-5,
                             "bands −0.004 and −0.003 read the same: \(means)")
    }

    /// An ordinary edit (no lift) ends at the same pixels as before: the display clamp in S4 is the
    /// only place that decides, so keeping the sign must not brighten anything by accident.
    func testAnOrdinaryEditStillEndsAtZeroForSubBlackPixels() throws {
        let graph = try makeGraph(staircase())
        var edit = EditModel.neutral
        edit.light.contrast = 10          // a real tone-map pass, but no lift
        edit.light.blacks = -5

        let means = bandMeans(try render(graph, edit))
        print("sub-black staircase with a normal edit:", means.map { String(format: "%.5f", $0) })
        for (i, m) in means.enumerated() {
            XCTAssertEqual(m, 0, accuracy: 1e-4,
                           "band \(i) lit up without a lift (\(m)) — the display clamp is the only judge")
        }
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
