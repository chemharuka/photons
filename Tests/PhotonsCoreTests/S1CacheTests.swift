import XCTest
import PhotonsCore
import Metal

/// 073 — the linear pass (S1) is cached on **its own inputs**, so a blue slider step does not
/// re-derive the linear domain.
///
/// The three colour words of 073 mean: yellow = the decode (never re-run by a slider), red = the
/// linear domain (S1: black/white levels, 071's trim, exposure, highlight recovery), blue = the
/// render (S1.6/S1.7/S2/S3/S4).
///
/// What this file pins, each with the number that can be asked (`RenderGraph.s1Passes`,
/// `s1_6Passes`, `s1CacheBytes`, `s1CacheKey`):
///
///   ① a blue burst runs S1 **once** (the cold frame) and S1.6 once per step;
///   ② a red burst runs S1 once per step — the key is load-bearing, not decorative;
///   ③ cached and uncached renders are **byte-identical**, through a red change and back;
///   ④ exactly **one** S1 texture is held, replaced on a key change and freed by `invalidateCache`;
///   ⑤ the refutation: a key without the red group serves a red change the previous buffer, and ③
///      must then fail — otherwise ③ proves nothing.
final class S1CacheTests: XCTestCase {

    // MARK: - fixtures

    private func rampImage(width: Int = 384, height: Int = 256) -> LinearImage {
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

    private func makeGraph(_ image: LinearImage, identity: String = "s1-cache",
                           s1KeyIncludesRedGroup: Bool = true) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity),
                               s1KeyIncludesRedGroup: s1KeyIncludesRedGroup)
    }

    /// One enabled mask, so the pipeline really has an S1.6 (`localApply`) to count — and so the blue
    /// drag below has a stage of its own to re-run.
    private func maskedDocument() -> EditModel {
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-a", feather: 0.15,
                           components: [MaskComponent(id: "a1", feather: 0.4, shape: .radialGradient(
                               RadialGradientShape(center: NormalizedPoint(0.3, 0.35),
                                                   radius: NormalizedPoint(0.18, 0.18))))],
                           adjustments: LocalAdjustments(exposure: 0.5))]
        return edit
    }

    /// A blue step: the mask's own exposure is S1.6's, and nothing in S1's key moves.
    private func blueStep(_ doc: EditModel, _ i: Int) -> EditModel {
        var d = doc
        d.masks[0].adjustments.exposure = 0.5 + Double(i + 1) * 0.05
        d.light.contrast = Double(i + 1) * 2
        d.color.saturation = Double(i + 1) * 1.5
        d.curve = CurveGroup(white: [CurvePoint(u: 0, v: 0),
                                     CurvePoint(u: 0.3, v: 0.25 + Double(i + 1) * 0.01),
                                     CurvePoint(u: 1, v: 1)])
        return d
    }

    /// A red step: 071's trim and the absolute black level — the linear domain.
    private func redStep(_ doc: EditModel, _ i: Int) -> EditModel {
        var d = doc
        d.light.blackOffset = Double(i + 1) * 0.001
        d.light.blackLevel = 0.004 + Double(i) * 0.001
        return d
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel,
                        useCache: Bool = true) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, useCache: useCache, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        return try XCTUnwrap(result.display)
    }

    // MARK: - ①② the counters (blue / red)

    func testBlueDragRunsS1OnceAndS1_6EveryStep() throws {
        let image = rampImage()
        let base = maskedDocument()
        let graph = try makeGraph(image)

        // The cold frame: S1 runs once, and this is the only run the burst may cost.
        _ = try render(graph, base)
        XCTAssertEqual(graph.s1Passes, 1, "the cold frame must run S1")
        XCTAssertEqual(graph.s1CacheTextures, 1)

        // Ten blue steps: mask exposure (S1.6), contrast (S2), saturation (S3), curve (S1.7).
        var doc = base
        let s16Before = graph.s1_6Passes
        let s17Before = graph.s1_7Passes
        for i in 0..<10 {
            doc = blueStep(base, i)
            _ = try render(graph, doc)
        }
        print("073 COUNTS blue: s1Passes=\(graph.s1Passes) s1Hits=\(graph.s1Hits) "
              + "s1.6+=\(graph.s1_6Passes - s16Before) s1.7+=\(graph.s1_7Passes - s17Before) "
              + "s1Textures=\(graph.s1CacheTextures) bytes=\(graph.s1CacheBytes)")
        XCTAssertEqual(graph.s1Passes, 1, "a blue burst re-ran the linear pass")
        XCTAssertEqual(graph.s1Hits, 10, "every blue frame must have read S1 out of the cache")
        XCTAssertEqual(graph.s1_6Passes - s16Before, 10, "S1.6 is the stage a blue step re-runs")
        XCTAssertEqual(graph.s1_7Passes - s17Before, 10, "the curve is downstream of S1 and must re-run")
    }

    func testRedDragRunsS1EveryStep() throws {
        let image = rampImage()
        let base = maskedDocument()
        // No warm frame: ten red steps are ten linear passes, one per step.
        let graph = try makeGraph(image)
        var doc = base
        for i in 0..<10 {
            doc = redStep(base, i)
            _ = try render(graph, doc)
        }
        print("073 COUNTS red:  s1Passes=\(graph.s1Passes) s1Hits=\(graph.s1Hits) "
              + "s1Textures=\(graph.s1CacheTextures) bytes=\(graph.s1CacheBytes)")
        XCTAssertEqual(graph.s1Passes, 10, "a red burst must re-run S1 on every step")
        XCTAssertEqual(graph.s1Hits, 0)
        XCTAssertEqual(graph.s1CacheTextures, 1, "a red step replaces the one cached texture")
    }

    /// The decode half of the acceptance. A blue or red edit must not move `DecodeInputs.key` — that is
    /// the identity the loupe's decode queue and the ladder are keyed on, and `decodeRequests` only
    /// counts requests for a rung the ladder does not already hold, so an identity that does not move
    /// is a decode request that cannot happen.
    func testBlueAndRedDoNotMoveTheDecodeIdentity() {
        let base = maskedDocument()
        let identity = base.decodeInputs.key
        for i in 0..<10 {
            XCTAssertEqual(blueStep(base, i).decodeInputs.key, identity, "blue step \\(i) moved the decode")
            XCTAssertEqual(redStep(base, i).decodeInputs.key, identity, "red step \\(i) moved the decode")
        }
    }

    // MARK: - ③ byte identity, cached vs cold

    func testCachedAndColdRendersAreByteIdentical() throws {
        let image = rampImage()
        let base = maskedDocument()
        // The sequence a hand produces: blue, then red, then blue again.
        var sequence: [EditModel] = (0..<5).map { blueStep(base, $0) }
        sequence += (0..<3).map { redStep(base, $0) }
        sequence += (5..<8).map { blueStep(base, $0) }

        // Cached: one graph, one cold frame, then every step reuses whatever still holds.
        let warm = try makeGraph(image)
        var cached: [String] = []
        _ = try render(warm, base)
        for edit in sequence { cached.append(try render(warm, edit).sha256()) }

        // Cold: a fresh graph per document, so nothing can be reused.
        var reference: [String] = []
        for edit in sequence {
            reference.append(try render(try makeGraph(image), edit, useCache: false).sha256())
        }

        print("073 BYTES cached[0]=\(cached[0].prefix(16)) cold[0]=\(reference[0].prefix(16)) "
              + "cached[last]=\(cached[cached.count - 1].prefix(16)) "
              + "frames=\(cached.count) s1Passes=\(warm.s1Passes)")
        for (i, (a, b)) in zip(cached, reference).enumerated() {
            XCTAssertEqual(a, b, "frame \\(i) of the sequence differs between the cached and the cold path")
        }
        // And the sequence really did exercise both kinds of step.
        XCTAssertGreaterThanOrEqual(warm.s1Passes, 4, "the red steps must have re-run S1")
    }

    /// The same identity, asserted on the pixels rather than on their digest, and on the frame the
    /// cache is *most* likely to get wrong: the first blue frame after a red one (S1 was just rebuilt).
    func testBlueAfterRedIsBitExact() throws {
        let image = rampImage()
        let base = maskedDocument()
        let graph = try makeGraph(image)
        _ = try render(graph, base)
        _ = try render(graph, redStep(base, 3))                 // S1 rebuilt for a new red group
        let afterRed = try render(graph, blueStep(base, 6))     // …and reused for a blue one
        let cold = try render(try makeGraph(image), blueStep(base, 6), useCache: false)
        XCTAssertEqual(afterRed.rgba.count, cold.rgba.count)
        XCTAssertEqual(afterRed.sha256(), cold.sha256(), "a blue frame after a red one is not bit-exact")
    }

    // MARK: - ④ memory

    func testExactlyOneS1TextureIsHeld() throws {
        let image = rampImage(width: 320, height: 200)
        let base = maskedDocument()
        let graph = try makeGraph(image)
        let expected = 320 * 200 * 8

        _ = try render(graph, base)
        XCTAssertEqual(graph.s1CacheTextures, 1)
        XCTAssertEqual(graph.s1CacheBytes, expected)
        let key = try XCTUnwrap(graph.s1CacheKey)

        // A blue burst neither adds a texture nor moves the key.
        for i in 0..<5 { _ = try render(graph, blueStep(base, i)) }
        XCTAssertEqual(graph.s1CacheTextures, 1)
        XCTAssertEqual(graph.s1CacheBytes, expected)
        XCTAssertEqual(graph.s1CacheKey, key, "a blue step moved S1's key")

        // A red step replaces the single texture (the old one goes back to the pool).
        _ = try render(graph, redStep(base, 1))
        XCTAssertEqual(graph.s1CacheTextures, 1)
        XCTAssertEqual(graph.s1CacheBytes, expected)
        XCTAssertNotEqual(graph.s1CacheKey, key, "a red step must move S1's key")

        // Geometry is part of the key and of the texture's size: a crop replaces both.
        var cropped = base
        cropped.geometry = GeometryGroup(crop: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        _ = try render(graph, cropped)
        XCTAssertEqual(graph.s1CacheTextures, 1)
        XCTAssertEqual(graph.s1CacheBytes, 160 * 100 * 8)

        // A cache-off frame is a transient: it must not install an entry…
        graph.invalidateCache()
        XCTAssertEqual(graph.s1CacheTextures, 0)
        XCTAssertEqual(graph.s1CacheBytes, 0)
        _ = try render(graph, cropped, useCache: false)
        XCTAssertEqual(graph.s1CacheTextures, 0, "a cache-off frame must not populate the S1 slot")
    }

    // MARK: - ⑤ the refutation

    /// **The test that makes ③ worth something.** With the red group deleted from S1's key, a red
    /// change is served the *previous* linear buffer — so the cached frame and the cold frame must
    /// disagree exactly where the red group moved. If this ever passes, the cache is not keyed on the
    /// red group and every "byte-identical" claim above is a coincidence.
    func testRedGroupIsLoadBearing() throws {
        let image = rampImage()
        let base = maskedDocument()
        // blue, blue, then a red step, then blue again.
        let sequence = [blueStep(base, 1), blueStep(base, 2), redStep(base, 0), blueStep(base, 3)]

        let refuted = try makeGraph(image, s1KeyIncludesRedGroup: false)
        _ = try render(refuted, base)
        var cached: [String] = []
        for edit in sequence { cached.append(try render(refuted, edit).sha256()) }
        var cold: [String] = []
        for edit in sequence { cold.append(try render(try makeGraph(image), edit, useCache: false).sha256()) }

        // The blue frames still match — the refutation only removes the red group.
        XCTAssertEqual(cached[0], cold[0])
        XCTAssertEqual(cached[1], cold[1])
        // The red frame is where it must break: index 2, the first red step after the warm frame.
        print("073 REFUTE cached[2]=\(cached[2].prefix(16)) cold[2]=\(cold[2].prefix(16)) "
              + "refuted s1Passes=\(refuted.s1Passes) of \(sequence.count + 1) frames")
        XCTAssertNotEqual(cached[2], cold[2],
                          "a key without the red group served a red change the previous S1 buffer — "
                          + "if this is equal, the byte-identical test above proves nothing")
        XCTAssertLessThan(refuted.s1Passes, sequence.count + 1,
                          "the refuted key must hit S1's cache on the red step")
    }

    // MARK: - bench (PHOTONS_BENCH=1)

    private var benchmarks: Bool { ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" }

    // MARK: - bench: the decomposition (PHOTONS_BENCH=1)

    /// One frame's costs, isolated by **suffix**: each drag moves a later stage's key only, so the
    /// difference between two drags is what the stages in between cost. No masks, so the chain is
    /// `S0 → S1 → S1.7 → S2 → S3 → S3c → S4` and nothing else is in the way.
    ///
    /// Timing a 4 ms frame with `gpuEndTime - gpuStartTime` is noisy on a laptop (clocks ramp, other
    /// work lands in the same command buffer), so the variants are **interleaved round-robin** — six
    /// rounds of 24 frames each — and what is printed is the median of the six per-round medians. The
    /// differences are then read as "what this stage costs", which is the only thing a decomposition can
    /// honestly claim at this resolution.
    func testBenchFrameDecomposition() throws {
        guard benchmarks else { throw XCTSkip("set PHOTONS_BENCH=1 to print the decomposition") }
        // The canvas: 4.10 Mpx by default (the fixture frame everyone quotes), or `PHOTONS_BENCH_WIDTH`
        // for a second size. At 4.10 Mpx a single pointwise pass is ~0.3 ms, which is *below* the GPU
        // timer's own jitter (~0.4 ms), so the configuration that can resolve S1 is the larger one —
        // and having both sizes is what turns the numbers into a slope instead of a floor.
        let width = Int(ProcessInfo.processInfo.environment["PHOTONS_BENCH_WIDTH"] ?? "2731") ?? 2731
        let height = Int((Double(width) / (2731.0 / 1500.0)).rounded())
        let megapixels = Double(width * height) / 1_000_000
        let image = rampImage(width: width, height: height)
        // **One** base document, non-identity in every stage, so each variant runs the same arithmetic
        // path in the stages it does not drag: otherwise "curve drag" measures S1.7's table path and
        // "blackOffset drag" its identity copy, and the difference between them is not S1.
        var base = EditModel.neutral
        base.light.exposure = 0.2
        base.light.contrast = 8
        base.light.highlights = -10
        base.light.shadows = 8
        base.light.whites = 4
        base.light.blacks = -3
        base.curve = CurveGroup(white: [CurvePoint(u: 0, v: 0),
                                       CurvePoint(u: 0.25, v: 0.22),
                                       CurvePoint(u: 0.7, v: 0.78),
                                       CurvePoint(u: 1, v: 1)])
        base.color = ColorGroup(vibrance: 10, saturation: 6)
        base.effects = EffectsGroup(vignetteAmount: -20)
        let plain = base
        var maskedBase = base
        maskedBase.masks = maskedDocument().masks
        let masked = maskedBase

        struct Variant {
            let name: String
            let doc: EditModel
            /// Built with the **refuted** S1 key (red group deleted), so S1 is served out of the cache
            /// even though the red group moved. The pair "red drag, normal" vs "red drag, refuted" is
            /// the same document, the same canvas and the same downstream work, and the only difference
            /// is whether S1's pass runs — which is what makes it the one honest way to time S1 here.
            var refute: Bool = false
            let drag: (inout EditModel, inout RenderOptions, Int) -> Void
        }
        // Every drag stays inside its slider's envelope: 071's trim clamps at ±0.01, so a burst that
        // ran past it would saturate and stop moving the key (and measure a cache hit, not a pass).
        let redDrag: (inout EditModel, inout RenderOptions, Int) -> Void = { d, _, i in
            d.light.blackOffset = Double(i + 1) * 0.0004
        }
        let exposureDrag: (inout EditModel, inout RenderOptions, Int) -> Void = { d, _, i in
            d.light.exposure = 0.2 + Double(i + 1) * 0.05
        }
        // A 0.9 crop, so "S0 + everything" and "everything" run on the *same* canvas: the crop drag
        // moves the rect's origin and leaves its size alone.
        var cropped = base
        cropped.geometry = GeometryGroup(crop: NormalizedRect(x: 0, y: 0, width: 0.9, height: 0.9))

        let variants: [Variant] = [
            Variant(name: "s4 (headroom)", doc: plain) { _, o, i in
                o.display.headroom = 1 + Double(i + 1) * 0.01
            },
            Variant(name: "s3+s3c+s4 (saturation)", doc: plain) { d, _, i in
                d.color.saturation = 6 + Double(i + 1) * 1.5
            },
            Variant(name: "s2+s3+s3c+s4 (contrast)", doc: plain) { d, _, i in
                d.light.contrast = 8 + Double(i + 1) * 1.5
            },
            Variant(name: "s1.7+…+s4 (curve)", doc: plain) { d, _, i in
                d.curve = CurveGroup(white: [CurvePoint(u: 0, v: 0),
                                            CurvePoint(u: 0.25, v: 0.22 + Double(i + 1) * 0.006),
                                            CurvePoint(u: 0.7, v: 0.78),
                                            CurvePoint(u: 1, v: 1)])
            },
            Variant(name: "s1+…+s4 (blackOffset 红)", doc: plain, drag: redDrag),
            Variant(name: "s1 skipped (red, refuted)", doc: plain, refute: true, drag: redDrag),
            Variant(name: "s1+…+s4 (exposure)", doc: plain, drag: exposureDrag),
            Variant(name: "s1.6+…+s4 (mask local)", doc: masked) { d, _, i in
                d.masks[0].adjustments.exposure = 0.5 + Double(i + 1) * 0.05
            },
            Variant(name: "s2+…+s4 (masked, contrast)", doc: masked) { d, _, i in
                d.light.contrast = 8 + Double(i + 1) * 1.5
            },
            Variant(name: "blue step + histogram", doc: plain) { d, o, i in
                d.light.contrast = 8 + Double(i + 1) * 1.5
                o.collectHistogram = true
                o.histogramSampleLongEdge = Histogram.frameSampleLongEdge
            },
            // The two steps exactly as `S1BenchBeforeTests` (the pristine tree) measures them, so the
            // before/after columns are the same workload and not two different drags.
            Variant(name: "blue step (full, S1.6→S4)", doc: masked) { d, _, i in
                d.masks[0].adjustments.exposure = 0.5 + Double(i + 1) * 0.05
                d.light.contrast = 8 + Double(i + 1) * 1.5
                d.color.saturation = 6 + Double(i + 1) * 1.5
                d.curve = CurveGroup(white: [CurvePoint(u: 0, v: 0),
                                             CurvePoint(u: 0.25, v: 0.22 + Double(i + 1) * 0.006),
                                             CurvePoint(u: 0.7, v: 0.78),
                                             CurvePoint(u: 1, v: 1)])
            },
            Variant(name: "red step (full, S1→S4)", doc: plain, drag: redDrag),
            Variant(name: "s1+…+s4 (exposure, 0.9 crop)", doc: cropped, drag: exposureDrag),
            Variant(name: "s0+…+s4 (crop origin, 0.9)", doc: cropped) { d, _, i in
                d.geometry = GeometryGroup(crop: NormalizedRect(x: 0.01 * Double(i), y: 0,
                                                                width: 0.9, height: 0.9))
            },
        ]

        let rounds = 6, frames = 24, drop = 4
        var perRound = [[Double]](repeating: [], count: variants.count)
        var ran = [String](repeating: "", count: variants.count)
        for round in 0..<rounds {
            for (vi, v) in variants.enumerated() {
                let graph = try makeGraph(image, s1KeyIncludesRedGroup: !v.refute)
                var options = RenderOptions(scale: 1, useCache: true, wantsPixels: false)
                if let t = try graph.render(v.doc, options: options).output { graph.recycle(output: t) }
                var times: [Double] = []
                for i in 0..<frames {
                    var doc = v.doc
                    v.drag(&doc, &options, i)
                    let r = try graph.render(doc, options: options)
                    if i >= drop { times.append(r.trace.gpuMilliseconds) }
                    if round == 0, i == frames - 1 { ran[vi] = r.trace.executed.map(\.short).joined(separator: " ") }
                    if let t = r.output { graph.recycle(output: t) }
                }
                times.sort()
                perRound[vi].append(times[times.count / 2])
            }
        }
        var medians = [String: Double]()
        for vi in variants.indices {
            perRound[vi].sort()
            let v = perRound[vi][perRound[vi].count / 2]
            medians[variants[vi].name] = v
            print(String(format: "BENCH 073 %-30@ p50 %6.2f ms | ran: %@",
                         variants[vi].name as NSString, v, ran[vi] as NSString))
        }
        func m(_ name: String) -> Double { medians[name] ?? 0 }

        // 4.10 Mpx is the size a report quotes; a pointwise pass scales with the pixel count, so the
        // scaled column is what a 4.10 Mpx frame would pay (its constant term is the ~0.4 ms floor).
        let scale = 4.0965 / megapixels
        // The chain, stage by stage, as a telescoping sum: each line removes one stage from a frame
        // that ran one more. "red, refuted" is the same document as "red" with S1 served out of the
        // cache, so it isolates S1 exactly; "masked, contrast" vs "mask local" does the same for S1.6.
        let s1 = m("s1+…+s4 (blackOffset 红)") - m("s1 skipped (red, refuted)")
        let s17 = m("s1 skipped (red, refuted)") - m("s2+s3+s3c+s4 (contrast)")
        let s2cost = m("s2+s3+s3c+s4 (contrast)") - m("s3+s3c+s4 (saturation)")
        let s3 = m("s3+s3c+s4 (saturation)") - m("s4 (headroom)")
        let s4cost = m("s4 (headroom)")
        let s0cost = m("s0+…+s4 (crop origin, 0.9)") - m("s1+…+s4 (exposure, 0.9 crop)")
        let s16cost = m("s1.6+…+s4 (mask local)") - m("s2+…+s4 (masked, contrast)")
        let histcost = m("blue step + histogram") - m("s2+s3+s3c+s4 (contrast)")
        let costs: [(String, Double)] = [
            ("S0 (geometry)", s0cost),
            ("S1 (scene-linear)", s1),
            ("S1.6 (local)", s16cost),
            ("S1.7 (curve)", s17),
            ("S2 (tone map)", s2cost),
            ("S3+S3c (colour, vignette)", s3),
            ("S4 (display)", s4cost),
            ("histogram (grid + CPU count)", histcost),
        ]
        print(String(format: "BENCH 073 ⇒ %.2f Mpx, cache on, median of %d rounds:", megapixels, rounds))
        for (name, v) in costs {
            print(String(format: "BENCH 073   %-26@ %6.2f ms   @4.10 Mpx ≈ %6.2f ms",
                         name as NSString, v, v * scale))
        }
        // The telescoping check: S1 + S1.7 + S2 + S3 + S4 must reproduce a red step exactly, because
        // that is the frame the five lines were taken from. If they do not add up, the decomposition is
        // noise and not a decomposition.
        let sum = s1 + s17 + s2cost + s3 + s4cost
        print(String(format: "BENCH 073   %-26@ %6.2f ms  (S1+S1.7+S2+S3+S4, red step %.2f)",
                     "sum check" as NSString, sum, m("s1+…+s4 (blackOffset 红)")))
        // A curve *drag* also rebuilds the four 4096-entry tables on the CPU, inside the frame's own
        // command-buffer span (the GPU idles while it waits) — a property of the curve, not the cache.
        print(String(format: "BENCH 073   %-26@ %6.2f ms  (pass + table rebuild, cf. S1.7 %.2f)",
                     "S1.7 whole curve drag" as NSString,
                     m("s1.7+…+s4 (curve)") - m("s2+s3+s3c+s4 (contrast)"), s17))
        print(String(format: "BENCH 073   %-26@ %6.2f ms  (S2→S4, contrast only)",
                     "blue step (no curve)" as NSString, m("s2+s3+s3c+s4 (contrast)")))
        print(String(format: "BENCH 073   %-26@ %6.2f ms  (blackOffset drag)",
                     "red step" as NSString, m("s1+…+s4 (blackOffset 红)")))
        // The exact workload `S1BenchBeforeTests` runs on the pristine tree — the before/after pair.
        print(String(format: "BENCH 073   %-26@ %6.2f ms  (S1.6→S4, same as BEFORE)",
                     "blue step, full drag" as NSString, m("blue step (full, S1.6→S4)")))
        print(String(format: "BENCH 073   %-26@ %6.2f ms  (S1→S4, same as BEFORE)",
                     "red step, full drag" as NSString, m("red step (full, S1→S4)")))

        // The present, at the loupe's 2560×1600 canvas: the same pass the drawable gets.
        if let device = MTLCreateSystemDefaultDevice() {
            let graph = try makeGraph(image)
            let r = try graph.render(plain, options: RenderOptions(scale: 1, wantsPixels: false))
            if let frameTexture = r.output {
                var doc = plain
                doc.light.contrast = 12
                let frame2 = try graph.render(doc, options: RenderOptions(scale: 1, wantsPixels: false))
                let picture = frame2.output ?? frameTexture
                let canvas = ImageSize(width: 2560, height: 1600)
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                   width: canvas.width,
                                                                   height: canvas.height,
                                                                   mipmapped: false)
                desc.usage = [.renderTarget, .shaderRead]
                if let target = device.makeTexture(descriptor: desc),
                   let presenter = try? CanvasPresenter(device: device, storage: .linear16) {
                    let request = PresentRequest(picture: picture,
                                                 photoRect: ImageRect(x: 0, y: 0,
                                                                      width: picture.width,
                                                                      height: picture.height),
                                                 window: .whole, canvas: canvas)
                    _ = presenter.render(request, into: target)      // warm the pipeline
                    var times: [Double] = []
                    for _ in 0..<12 {
                        let t0 = CFAbsoluteTimeGetCurrent()
                        _ = presenter.render(request, into: target)
                        times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    }
                    times.sort()
                    print(String(format: "BENCH 073 present (2560×1600) p50 %.2f ms", times[times.count / 2]))
                }
                graph.recycle(output: picture)
                if frame2.output == nil { graph.recycle(output: frameTexture) }
            }
        }

        // The decode, for scale: a slider never pays this (its identity does not move), but a frame's
        // budget has to be read against it.
        let candidates = [ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
                          NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath]
            .compactMap { $0 }
        if let path = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) }),
           let decoder = try? RAWDecoder() {
            let t0 = CFAbsoluteTimeGetCurrent()
            let out = try? decoder.decode(URL(fileURLWithPath: path),
                                          options: DecodeOptions(scale: 0.5))
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print(String(format: "BENCH 073 decode %@ @ scale 0.5: %.0f ms (%d×%d)",
                         (path as NSString).lastPathComponent as NSString, ms,
                         out?.width ?? 0, out?.height ?? 0))
        }
    }

    /// The two totals the report quotes, plus the slot's size: a blue burst and a red burst on the
    /// same 4.10 Mpx frame, with the counters each one leaves behind.
    func testBenchBlueAndRedStep() throws {
        guard benchmarks else { throw XCTSkip("set PHOTONS_BENCH=1 to measure the blue/red step") }
        let image = rampImage(width: 2731, height: 1500)     // 4.0965 Mpx ≈ 4.10 Mpx
        let base = maskedDocument()

        func p50(_ label: String, blue: Bool, steps: Int = 12) throws -> Double {
            let graph = try makeGraph(image)
            let options = RenderOptions(scale: 1, useCache: true, wantsPixels: false)
            if let t = try graph.render(base, options: options).output { graph.recycle(output: t) }
            var times: [Double] = []
            for i in 0..<steps {
                let doc = blue ? blueStep(base, i) : redStep(base, i)
                let r = try graph.render(doc, options: options)
                if i >= 2 { times.append(r.trace.gpuMilliseconds) }
                if let t = r.output { graph.recycle(output: t) }
            }
            times.sort()
            let v = times[times.count / 2]
            print(String(format: "BENCH 073 %-22@ p50 %6.2f ms | s1Passes %d s1Hits %d s1.6 %d s1.7 %d "
                         + "| %d texture %.1f MB",
                         label as NSString, v, graph.s1Passes, graph.s1Hits,
                         graph.s1_6Passes, graph.s1_7Passes,
                         graph.s1CacheTextures, Double(graph.s1CacheBytes) / 1_000_000))
            return v
        }

        _ = try p50("blue burst (S1.6→S4)", blue: true)
        _ = try p50("red burst (S1→S4)", blue: false)
    }
}
