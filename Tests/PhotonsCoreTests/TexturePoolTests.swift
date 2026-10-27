import XCTest
import PhotonsCore
import Metal

/// 2026-10-28 (P1b) — the texture pool has a **byte budget** and a way to give its bytes back.
///
/// The report this comes from (`local/perf/perf-baseline-2026-10-28.md` §5) measured a 60 Mpx export
/// frame holding eleven 483 MB intermediates and a pool that never gave one of them back:
/// 「纹理池只增不减」. `recycle` only appended, so a graph's footprint was the high-water mark of every
/// canvas it had ever rendered, and nothing short of dropping the whole graph returned it.
///
/// What this file pins, each about a number a caller can ask for:
///
///   ① the idle list is bounded in **bytes** — a canvas' worth per allowance, not "however many
///      frames have run";
///   ② a one-shot graph (`.none`) keeps nothing past the frame, and `releaseAllTextures()` gives the
///      rest back: cache, S1/S1.6 slots, atlas;
///   ③ the accounting is real — the device's own `currentAllocatedSize` comes back down
///      (「导出后回落到基线」), and the frame itself never holds eleven intermediates;
///   ④ retention changes **no pixel**: `.oneFrame` + cache and `.none` + no cache are byte-identical;
///   ⑤ the refutation: with an unbounded pool (`.bytes(.max)`) the fall-back in ③ does **not** happen,
///      so ③ is measuring the reclaim and not the weather.
final class TexturePoolTests: XCTestCase {

    // MARK: - fixtures

    /// 2048×1365 = 22.4 MB an intermediate at rgba16f — big enough that eleven of them is a visible
    /// device allocation, small enough that the pipeline runs in milliseconds.
    private let canvas = ImageSize(width: 2048, height: 1365)

    private var canvasBytes: Int { canvas.width * canvas.height * 8 }
    /// What "back at the baseline" is allowed to be off by: another test class may be holding a graph,
    /// and Metal does not promise `currentAllocatedSize` settles to the byte.
    private var slack: Int { 3 * canvasBytes }

    private func rampImage() -> LinearImage {
        let width = canvas.width, height = canvas.height
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let v = Float(0.02 + 0.96 * Double(x) / Double(max(width - 1, 1)))
                rgba[o] = Float16(v)
                rgba[o + 1] = Float16(min(1, v * 1.02))
                rgba[o + 2] = Float16(v * 0.9)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// Every conditional stage present, so a frame really has eleven intermediates to hold.
    private func document() -> EditModel {
        var edit = EditModel.neutral
        edit.light.exposure = 0.4
        edit.light.contrast = 18
        edit.curve.white = [CurvePoint(0, 0), CurvePoint(0.3, 0.26), CurvePoint(1, 1)]
        edit.color.vibrance = 12
        edit.color.bands = [HSLBand(hue: 4, saturation: 8, luminance: 0),
                            HSLBand(), HSLBand(hue: -6, saturation: 4, luminance: 2), HSLBand(),
                            HSLBand(), HSLBand(), HSLBand()]
        edit.effects.vignetteAmount = -18
        edit.masks = [Mask(id: "m-pool", feather: 0.1,
                           components: [MaskComponent(id: "p1", feather: 0.4, shape: .radialGradient(
                               RadialGradientShape(center: NormalizedPoint(0.5, 0.5),
                                                   radius: NormalizedPoint(0.2, 0.2))))],
                           adjustments: LocalAdjustments(exposure: 0.3, hue: 10, saturation: 6))]
        return edit
    }

    private func makeGraph(_ retention: TextureRetention,
                           cacheBytes: Int = 1_500_000_000) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: rampImage(), identity: "pool-tests"),
                               cacheBudgetBytes: cacheBytes,
                               textureRetention: retention)
    }

    private func options(cache: Bool, pixels: Bool = false) -> RenderOptions {
        RenderOptions(canvas: canvas, scale: 1,
                      display: DisplayOptions(primaries: .displayP3, bitDepth: 8, headroom: 1),
                      useCache: cache, wantsPixels: pixels)
    }

    private var deviceMetalBytes: Int {
        Int(MTLCreateSystemDefaultDevice()?.currentAllocatedSize ?? 0)
    }

    // MARK: - ① the budget is in bytes

    func testIdleListNeverExceedsItsByteBudget() throws {
        let graph = try makeGraph(.oneFrame)
        // Six frames of one canvas: the pre-P1b pool would now hold eleven intermediates forever.
        for _ in 0..<6 {
            let r = try graph.render(document(), options: options(cache: true))
            if let t = r.output { graph.recycle(output: t) }
        }
        XCTAssertGreaterThan(graph.idleTextureBytes, 0, "the hot path must keep a texture to reuse")
        XCTAssertEqual(graph.idleTextureBudgetBytes, 2 * canvasBytes)
        XCTAssertLessThanOrEqual(graph.idleTextureBytes, graph.idleTextureBudgetBytes)
        XCTAssertLessThanOrEqual(graph.idleTextureCount, 2)
    }

    /// The budget is *reused*, not just capped: a second identical frame must not pay `makeTexture`
    /// for every stage — that is the whole reason the idle list exists (measured at 60 Mpx: 24
    /// allocations for 12 frames with it, 109 for 12 without).
    func testHotFrameReusesTheIdleList() throws {
        let graph = try makeGraph(.oneFrame)
        let r1 = try graph.render(document(), options: options(cache: true))
        if let t = r1.output { graph.recycle(output: t) }
        let afterFirst = graph.textureAllocations
        for _ in 0..<3 {
            let r = try graph.render(document(), options: options(cache: true))
            if let t = r.output { graph.recycle(output: t) }
        }
        XCTAssertEqual(graph.textureAllocations, afterFirst,
                       "a hot frame on an unchanged document must allocate nothing")
        XCTAssertGreaterThan(graph.textureReuses, 0)
    }

    // MARK: - ② / ③ a one-shot graph gives its bytes back

    func testOneShotExportKeepsNothingAndFallsBack() throws {
        let baseline = deviceMetalBytes
        let graph = try makeGraph(.none)
        let r = try graph.render(document(), options: options(cache: false, pixels: true))
        XCTAssertNotNil(r.display, "the export path reads pixels back")
        // The only thing a paint-only frame holds is S1.5's side output — the mask atlas, r16f, one
        // slice: 2048×1365×2 B = 5.6 MB at this canvas (120 MB at 60 Mpx, and the export releases it).
        XCTAssertEqual(graph.heldTextureBytes, 2048 * 1365 * 2,
                       "no stage cache and no S1/S1.6 slot: only the atlas")
        XCTAssertEqual(graph.idleTextureBytes, 0, "a .none pool releases its list when the frame ends")

        // The frame itself: eleven intermediates would be 11 canvases; the one-shot churn is two
        // (the texture being read, the one being written) plus the source.
        let duringExport = deviceMetalBytes
        XCTAssertLessThan(duringExport, baseline + 6 * canvasBytes,
                          "the export frame must not hold one intermediate per stage")

        // 「导出后回落到基线附近」.
        _ = graph.releaseAllTextures()
        XCTAssertEqual(graph.idleTextureBytes, 0)
        XCTAssertEqual(graph.heldTextureBytes, 0)
        XCTAssertLessThanOrEqual(deviceMetalBytes, baseline + slack)
    }

    func testReleaseAllTexturesEmptiesEverySlot() throws {
        let graph = try makeGraph(.oneFrame)
        // A cached frame leaves the stage cache, S1's slot, S1.6's slot and the atlas occupied.
        let r = try graph.render(document(), options: options(cache: true))
        if let t = r.output { graph.recycle(output: t) }
        XCTAssertGreaterThan(graph.heldTextureBytes, 0)
        XCTAssertGreaterThan(graph.idleTextureBytes, 0)

        let freed = graph.releaseAllTextures()
        XCTAssertGreaterThan(freed, 0)
        XCTAssertEqual(graph.heldTextureBytes, 0)
        XCTAssertEqual(graph.idleTextureBytes, 0)
        XCTAssertEqual(graph.idleTextureCount, 0)

        // The graph still works — a released graph is not a broken one.
        let again = try graph.render(document(), options: options(cache: true))
        XCTAssertNotNil(again.output)
        if let t = again.output { graph.recycle(output: t) }
    }

    // MARK: - ④ no pixel moves

    /// The eager recycle's one real hazard, pinned: an export-sized frame (`useCache: false`, canvas
    /// over `eagerRecycleFloorBytes`) hands each stage's input back to the pool mid-frame, and the
    /// **histogram is read after the commit** from the texture S4 read. The mask overlay below is the
    /// same canvas, so an `obtain` there would hand that very texture back to be overwritten — the
    /// measurement would then count the overlay instead of the picture. Both spellings of the same
    /// frame must report the same histogram.
    func testHistogramSurvivesTheEagerRecycleWithAMaskOverlay() throws {
        let big = ImageSize(width: 5200, height: 3300)      // 137 MB a texture: over the floor
        var doc = document()
        doc.showMaskID = "m-pool"

        func render(cache: Bool, retention: TextureRetention) throws -> Histogram {
            let graph = try RenderGraph(input: RenderInput(image: rampImage(), identity: "pool-hist"),
                                        textureRetention: retention)
            let opts = RenderOptions(canvas: big, scale: 1,
                                     display: DisplayOptions(primaries: .displayP3,
                                                             bitDepth: 8, headroom: 1),
                                     useCache: cache, wantsPixels: false,
                                     collectHistogram: true, histogramSampleLongEdge: 0)
            let r = try graph.render(doc, options: opts)
            guard let h = r.histogram else { throw XCTSkip("no histogram") }
            if let t = r.output { graph.recycle(output: t) }
            return h
        }

        let cached = try render(cache: true, retention: .oneFrame)
        let eager = try render(cache: false, retention: .none)
        XCTAssertEqual(cached, eager,
                       "the histogram must measure the picture S4 read, not the overlay that reused it")
        XCTAssertGreaterThan(cached.channels.first?.total ?? 0, 0, "and it must have measured something")
    }

    func testRetentionChangesNoPixel() throws {
        let doc = document()
        let cached = try makeGraph(.oneFrame, cacheBytes: 1_500_000_000)
        let oneShot = try makeGraph(.none)
        let a = try cached.render(doc, options: options(cache: true, pixels: true))
        let b = try oneShot.render(doc, options: options(cache: false, pixels: true))
        guard let pa = a.display, let pb = b.display else { return XCTFail("no pixels") }
        XCTAssertEqual(pa.width, pb.width)
        XCTAssertEqual(pa.height, pb.height)
        XCTAssertEqual(pa.rgba.map(\.bitPattern), pb.rgba.map(\.bitPattern),
                       "the pool policy decides which texture holds a result, never what is in it")
    }

    // MARK: - ⑤ the refutation

    /// The counterexample, in code: an **unbounded** pool retains the export's intermediates and the
    /// assertion "after the export, the device is back near the baseline" **fails**. So
    /// `testOneShotExportKeepsNothingAndFallsBack` is measuring the reclaim, not the machine.
    func testUnboundedPoolKeepsTheBytesAndTheFallBackFails() throws {
        let baseline = deviceMetalBytes
        let graph = try makeGraph(.bytes(Int.max))
        for _ in 0..<3 {
            let r = try graph.render(document(), options: options(cache: false, pixels: true))
            XCTAssertNotNil(r.display)
        }
        // Everything three frames ever wrote is still held: that is the defect, and it is still
        // reachable through the explicit `.bytes` knob.
        XCTAssertGreaterThan(graph.idleTextureBytes, 8 * canvasBytes)
        XCTAssertFalse(deviceMetalBytes <= baseline + slack,
                       "with an unbounded pool the fall-back must NOT hold — otherwise the "
                       + "fall-back assertion proves nothing")
        // …and an explicit release is what turns it around.
        let idleBefore = graph.idleTextureBytes
        let freed = graph.releaseIdleTextures()
        XCTAssertEqual(freed, idleBefore, "the release reports exactly what it freed")
        XCTAssertEqual(graph.idleTextureBytes, 0)
        XCTAssertLessThanOrEqual(deviceMetalBytes, baseline + slack)
    }
}
