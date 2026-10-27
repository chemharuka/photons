import XCTest
import PhotonsCore
import Metal

/// 081 — a frame whose document did not change must not walk the pipeline.
///
/// The measurement that opened this (`local/perf/perf-baseline-2026-10-28.md` §3.3): a 60.32 Mpx export
/// frame with an **untouched** document ran 8 of its 11 stages and cost 59 ms against 85 ms cold. The
/// budget is 1.5 GB and one intermediate at that canvas is 483 MB, so only three entries survive — and
/// they are the *last* three, which is why S0 was always re-run.
///
/// The fix is not a bigger budget (measured: same hot number, +1.93 GB of Metal). It is that the key
/// chain is a **hash chain**, so an unchanged document can be recognised from its last link alone: the
/// cache stores, next to each entry's per-stage key, the *composite* key of the pipeline's last
/// cacheable stage, and a frame that finds it starts at S4.
///
/// What this file pins:
///   ① an unchanged frame executes exactly `[s4]` — and its pixels are **bit-identical** to a cold one
///      (the whole point: a resume that changed a pixel would be a stale picture, not an optimisation);
///   ② one slider step cancels the resume and runs exactly that stage's suffix;
///   ③ the refutation: with `useCache: false` the same repeated document runs the whole pipeline, so
///      the `[s4]` of ① is the cache's doing and not the pipeline's;
///   ④ the composite is the entry a budget squeeze must keep last — with a one-byte budget the cache
///      holds one entry, and an unchanged frame is still `[s4]`;
///   ⑤ the resume is counted (`compositeResumes`), so ① cannot pass for the wrong reason.
final class StageCacheCompositeTests: XCTestCase {

    // MARK: - fixtures

    private func rampImage(width: Int = 256, height: Int = 192) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let v = Float(0.02 + 0.96 * Double(x) / Double(max(width - 1, 1)))
                rgba[o] = Float16(v)
                rgba[o + 1] = Float16(v * 0.95)
                rgba[o + 2] = Float16(v * 0.9)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func makeGraph(_ image: LinearImage, identity: String = "081-composite",
                           budget: Int = 1_500_000_000) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity),
                               cacheBudgetBytes: budget)
    }

    /// Every conditional stage present (masks, local colour, HSL, vignette), so the pipeline the
    /// composite has to cover is the full one — the same shape as the 60 Mpx document in the report.
    private func fullDocument() -> EditModel {
        var e = EditModel.neutral
        e.light.exposure = 0.4
        e.light.contrast = 18
        e.light.highlights = -30
        e.light.shadows = 25
        e.curve.white = [CurvePoint(0, 0), CurvePoint(0.25, 0.2),
                         CurvePoint(0.6, 0.62), CurvePoint(1, 1)]
        e.color.vibrance = 15
        e.color.saturation = 5
        e.color.bands = [HSLBand(hue: 4, saturation: 8, luminance: 0),
                         HSLBand(), HSLBand(), HSLBand(),
                         HSLBand(hue: -5, saturation: 9, luminance: -4),
                         HSLBand(), HSLBand(), HSLBand()]
        e.effects.vignetteAmount = -20
        var adj = LocalAdjustments()
        adj.exposure = 0.3; adj.hue = 10; adj.saturation = 6
        e.masks = [Mask(id: "m-081", name: "081", feather: 0.05, refine: 0,
                        components: [MaskComponent(
                            id: "c1", op: .add, invert: false, feather: 0.4,
                            shape: .radialGradient(RadialGradientShape(
                                center: NormalizedPoint(0.5, 0.5),
                                radius: NormalizedPoint(0.22, 0.22))))],
                        adjustments: adj)]
        return e
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel,
                        useCache: Bool = true) throws -> RenderResult {
        let options = RenderOptions(scale: 1, useCache: useCache, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        if let out = result.output { graph.recycle(output: out) }
        return result
    }

    private func display(_ result: RenderResult) throws -> DisplayImage {
        try XCTUnwrap(result.display)
    }

    // MARK: - ① the unchanged frame

    func testUnchangedFrameExecutesDisplayOnly() throws {
        let image = rampImage()
        let doc = fullDocument()
        let graph = try makeGraph(image)

        let first = try render(graph, doc)
        let pipeline = first.trace.executed
        XCTAssertGreaterThan(pipeline.count, 5, "the cold frame must actually walk the pipeline")
        XCTAssertEqual(graph.compositeResumes, 0, "the cold frame has nothing to resume from")

        for i in 0..<5 {
            let r = try render(graph, doc)
            XCTAssertEqual(r.trace.executed, [.display],
                           "unchanged frame \(i) walked \(r.trace.executed.map(\.short))")
        }
        print("081 COMPOSITE resumes=\(graph.compositeResumes) entries=\(graph.cacheEntryCount) "
              + "bytes=\(graph.cacheBytes) coldStages=\(pipeline.count)")
        XCTAssertEqual(graph.compositeResumes, 5, "every unchanged frame must have used the resume")
    }

    /// The resume must serve the **same pixels** — a hot frame that is fast because it is wrong is the
    /// failure mode this whole file exists to exclude.
    func testResumedFrameIsBitIdenticalToAColdOne() throws {
        let image = rampImage()
        let doc = fullDocument()
        let graph = try makeGraph(image)
        _ = try render(graph, doc)
        let resumed = try render(graph, doc)
        XCTAssertEqual(resumed.trace.executed, [.display])

        let cold = try render(try makeGraph(image), doc, useCache: false)
        XCTAssertEqual(try display(resumed).sha256(), try display(cold).sha256(),
                       "the resumed frame is not bit-exact against a cold render of the same document")
    }

    // MARK: - ② one slider step is not a resume

    func testLightStepCancelsTheResume() throws {
        let image = rampImage()
        let doc = fullDocument()
        let graph = try makeGraph(image)
        _ = try render(graph, doc)
        let resumesBefore = graph.compositeResumes

        var bumped = doc
        bumped.light.exposure += 0.05
        let r = try render(graph, bumped)
        print("081 COMPOSITE after a Light step: \(r.trace.executed.map(\.short))")
        XCTAssertEqual(graph.compositeResumes, resumesBefore, "a Light step must not resume")
        XCTAssertNotEqual(r.trace.executed, [.display])
        // Exposure is S1's material: the linear pass and everything after it re-runs, S0 does not.
        XCTAssertTrue(r.trace.executed.contains(.sceneLinear), "S1 must re-run for an exposure change")
        XCTAssertFalse(r.trace.executed.contains(.geometry), "S0 must not re-run for an exposure change")

        // …and the document itself resumes again, bit-exact, once it is the one being asked for.
        for _ in 0..<2 { _ = try render(graph, bumped) }
        let back = try render(graph, bumped)
        XCTAssertEqual(back.trace.executed, [.display])
        let cold = try render(try makeGraph(image), bumped, useCache: false)
        XCTAssertEqual(try display(back).sha256(), try display(cold).sha256())
    }

    // MARK: - ③ the refutation

    func testCacheOffRunsTheWholePipelineEveryTime() throws {
        let image = rampImage()
        let doc = fullDocument()
        let graph = try makeGraph(image)
        let cold = try render(graph, doc, useCache: false)
        for _ in 0..<3 {
            let r = try render(graph, doc, useCache: false)
            XCTAssertEqual(r.trace.executed, cold.trace.executed,
                           "with the cache off a repeated document must re-run everything")
            XCTAssertGreaterThan(r.trace.executed.count, 5)
        }
        XCTAssertEqual(graph.compositeResumes, 0, "a cache-off frame must never resume")
    }

    // MARK: - ④ the composite is the entry to keep

    /// A budget that fits nothing at all still leaves **one** entry — the last inserted, i.e. the
    /// composite. That is the priority the cache is supposed to have: if only one stage can be kept, keep
    /// the one that makes the next unchanged frame a single pass.
    func testOneByteBudgetStillResumes() throws {
        let image = rampImage()
        let doc = fullDocument()
        let graph = try makeGraph(image, budget: 1)
        _ = try render(graph, doc)
        XCTAssertEqual(graph.cacheEntryCount, 1, "the budget must have squeezed the cache to one entry")
        let r = try render(graph, doc)
        XCTAssertEqual(r.trace.executed, [.display],
                       "even a one-entry cache must serve the unchanged frame from the composite")
        XCTAssertGreaterThanOrEqual(graph.compositeResumes, 1)
    }

    // MARK: - ⑤ the count cannot lie

    func testCompositeResumesCountsOnlyWhatItSays() throws {
        let image = rampImage()
        let doc = fullDocument()
        let graph = try makeGraph(image)
        XCTAssertEqual(graph.compositeResumes, 0)
        _ = try render(graph, doc)
        XCTAssertEqual(graph.compositeResumes, 0, "the first frame resumes from nothing")
        _ = try render(graph, doc)
        XCTAssertEqual(graph.compositeResumes, 1)
        _ = try render(graph, doc)
        XCTAssertEqual(graph.compositeResumes, 2)
    }
}
