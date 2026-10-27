import XCTest
import Metal
import PhotonsCore

/// 070: the histogram must be able to measure **light brighter than the screen**.
///
/// The user's report (2026-10-27): 「直方图的亮度统计最高只能取到屏幕亮度，比如 +2」. The measurement the card
/// shows was taken off the frame S4 had just written, and S4 ends with `min(v, headroom)`
/// (`s4_display.metal:33`) — on this machine 3.948×, i.e. +1.98 stop. Everything brighter arrived as
/// the same number, so the plot's right end could never carry it. This file pins the fix from both
/// sides:
///
///   · **the scene-linear measurement** (`RenderOptions.collectHistogram` +
///     `histogramSampleLongEdge`, the source the card uses) separates a +2 EV block from a +5 EV one;
///   · **the counter-proof** — the same frame measured on its S4 texture (`measureFrameHistogram`,
///     the pre-070 source) puts those two blocks in **one** bin, at the ceiling. If a future change
///     puts the card back on that source, the first test goes red, which is the point of writing the
///     bug down as an assertion instead of a comment.
///
/// The synthetic picture is four vertical blocks — sRGB **code 128**, **SDR white**, **+2 EV (4×)** and
/// **+5 EV (32×)** — so "which bin did it land in" is a number, not an impression. Nothing here asserts
/// a timing (the cost is printed by `HistogramSampleTests`).
final class HistogramHeadroomTests: XCTestCase {

    /// This machine's measured display headroom: 3.948× = **+1.98 stop** (`--ui-smoke` 的「显示上限刻度」).
    /// A literal on purpose — the claim being tested is about a *specific* ceiling, and a value read
    /// from the screen would make the counter-proof's bin depend on the machine it ran on.
    private let ceiling = 3.948

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage,
                           identity: String = "histogram-headroom") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// The four blocks, equal width: code 128 / white / +2 EV / +5 EV. Light, not code — the buffer is
    /// scene-linear, which is exactly what the measurement reads.
    private func fourBlocks(width: Int = 400, height: Int = 100) -> LinearImage {
        let values: [Float] = [Histogram.srgbDecode(128.0 / 255.0), 1.0, 4.0, 32.0]
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let block = min(values.count - 1, x * values.count / width)
                let v = Float16(values[block])
                let o = (y * width + x) * 4
                rgba[o] = v
                rgba[o + 1] = v
                rgba[o + 2] = v
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// One render, one measurement — the card's own path (a ≤ 256-long-edge grid of the **pre-S4**
    /// texture, inside the frame's command buffer).
    private func measure(_ graph: RenderGraph, canvas: ImageSize? = nil,
                         longEdge: Int = Histogram.frameSampleLongEdge)
        throws -> (histogram: Histogram, texture: MTLTexture, picture: ImageRect) {
        let result = try graph.render(.neutral, options: RenderOptions(
            canvas: canvas, scale: 1,
            display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: ceiling),
            useCache: false, wantsPixels: false,
            collectHistogram: true, histogramSampleLongEdge: longEdge))
        let texture = try XCTUnwrap(result.output, "a pixels-free render must hand back its texture")
        let histogram = try XCTUnwrap(result.histogram, "collectHistogram produced no measurement")
        return (histogram, texture, result.drawnRect)
    }

    /// +2 EV sits exactly on tail bin 128.000 — a bin **edge** — so the block is allowed to straddle
    /// 127 and 128 and nowhere else. (4.0 and 32.0 are exact in `Float16`; the edit's own arithmetic
    /// around them is what could move a value an ULP either way.) The +5 EV block's bin (255, the last
    /// one) is excluded by the caller's own assertions, not by this helper's silence.
    private func assertTwoEV(_ bins: [Int], block: Int, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(bins[127] + bins[128], block, message, file: file, line: line)
    }

    // MARK: - 1. the four blocks land in four distinguishable bins

    func testTheFourBlocksLandInFourDistinguishableBins() throws {
        let graph = try makeGraph(fourBlocks())
        let (h, texture, _) = try measure(graph)
        defer { graph.recycle(output: texture) }

        let grid = h.sampleSize.pixelCount
        XCTAssertEqual(h.sampleCount, grid, "every sample of the grid was counted once")
        let block = grid / 4
        XCTAssertEqual(block * 4, grid, "the four blocks are equal quarters of the sample")

        // Code half: code 128, then white (bin 255 is `[255/256, 1]`), and nothing else.
        XCTAssertEqual(h.red.bins[128], block, "code 128 块落在 code bin 128")
        XCTAssertEqual(h.red.bins[255], block, "白块落在 code bin 255（SDR 白）")
        XCTAssertEqual(h.red.bins.reduce(0, +) - h.red.bins[128] - h.red.bins[255], 0,
                       "code 段只有这两箱有像素")

        // Tail: +2 EV in the third stop's first bin, +5 EV past the table's end.
        assertTwoEV(h.red.hdrBins, block: block, "+2 EV 块落在 2.0 档")
        XCTAssertEqual(h.red.hdrBins[255], block,
                       "+5 EV 块落在尾段末箱（≥3.98 档）——**不是** +2 EV 那一格")
        XCTAssertGreaterThan(h.red.hdrBins[127] + h.red.hdrBins[128], 0,
                             "+2 EV 与 +5 EV 各在自己的档，可区分")
        XCTAssertEqual(h.red.hdrBins.reduce(0, +), 2 * block,
                       "尾段只有这两块：没有像素落在别的档")

        // The luma series is derived from the same linear light with Rec.709 weights, and these blocks
        // are neutral, so it is the same distribution.
        XCTAssertEqual(h.luma.bins[128], block)
        XCTAssertEqual(h.luma.bins[255], block)
        assertTwoEV(h.luma.hdrBins, block: block, "luma 与 red 同口径")
        XCTAssertEqual(h.luma.hdrBins[255], block)

        // …and every sample is in exactly one bin of exactly one segment: the counting invariant.
        for channel in Histogram.Channel.allCases {
            let c = h[channel]
            XCTAssertEqual(c.bins.reduce(0, +) + c.hdrBins.reduce(0, +), grid,
                           "\(channel.rawValue): Σbins + ΣhdrBins 必须等于照片矩形内的像素数")
        }
        // `clippedHigh` is a **code** threshold (0.999 of code), so the white block counts too: three of
        // the four blocks are 「过白」 = 75 %. That number is a fact about the photograph and would be the
        // same on a 1.0× screen; what *does* move with the screen is `clippedCeiling`, and only the
        // two blocks above 3.948× are in it (50 %).
        XCTAssertEqual(h.red.clippedHigh, 0.75, accuracy: 1e-12, "白块 + 两块高光过白 = 75 %")
        XCTAssertEqual(h.red.clippedCeiling, 0.5, accuracy: 1e-12,
                       "headroom 3.948: +2 EV 与 +5 EV 两块在本机上被削掉")
        print("070 blocks: code128 → bins[128], white → bins[255], +2 EV → hdr[127]= "
              + "\(h.red.hdrBins[127]) / hdr[128]= \(h.red.hdrBins[128]), +5 EV → hdr[255] · "
              + "\(h.sampleCount) samples · clippedHigh(R) "
              + "\(String(format: "%.3f", h.red.clippedHigh)) · clippedCeiling(R) "
              + "\(String(format: "%.3f", h.red.clippedCeiling))")
    }

    // MARK: - 2. the counter-proof: the S4 frame cannot separate them

    func testTheS4FrameCannotSeparateTwoStopsAboveItsHeadroom() throws {
        let graph = try makeGraph(fourBlocks(), identity: "histogram-headroom-counterproof")
        let (scene, texture, _) = try measure(graph)
        defer { graph.recycle(output: texture) }

        // The pre-070 source: the frame S4 wrote, measured on its codes.
        let whole = ImageRect(x: 0, y: 0, width: texture.width, height: texture.height)
        let frame = try graph.measureFrameHistogram(fromFrame: texture, edit: .neutral,
                                                    content: whole, headroom: ceiling).histogram
        let block = scene.sampleSize.pixelCount / 4
        let ceilingBin = Int(floor(log2(ceiling) * Double(Histogram.hdrBinsPerStop)))

        // The bug, written as an assertion: **both** hot blocks land in the ceiling's bin, because S4
        // clamped them to the same number on the way out.
        XCTAssertEqual(frame.red.hdrBins[ceilingBin], 2 * block,
                       "S4 帧上 +2 EV 与 +5 EV 必须落在同一格（这就是 bug）")
        XCTAssertEqual(frame.red.hdrBins[255], 0,
                       "S4 帧上永远没有东西到达尾段末箱——它到不了 +1.98 档以上")
        XCTAssertEqual(frame.red.hdrBins[128], 0, "行内也没有 +2 EV 那一格")

        // The scene-linear measurement of the **same render** separates them. Reverting the wiring
        // (measure `result.output` instead of `result.histogram`) turns this red, together with
        // `testTheFourBlocksLandInFourDistinguishableBins`.
        XCTAssertEqual(scene.red.hdrBins[255], block, "scene-linear: +5 EV 有自己的档")
        assertTwoEV(scene.red.hdrBins, block: block, "scene-linear: +2 EV 有自己的档")

        print("070 counter-proof: S4 frame puts both hot blocks in hdr[\(ceilingBin)] "
              + "(\(2 * block) samples) · the scene-linear measurement puts them in "
              + "hdr[127…128] and hdr[255]")
    }

    // MARK: - 3. the letterbox is not measured, and the count is exact

    func testTheLetterboxBandsAreNotSampledAndTheCountIsExact() throws {
        // A 2:1 canvas over a 4:1 picture: S0 letterboxes it with 100-px bands top and bottom.
        let canvas = ImageSize(width: 800, height: 400)
        let graph = try makeGraph(fourBlocks(), identity: "histogram-headroom-letterbox")
        let (h, texture, picture) = try measure(graph, canvas: canvas)
        defer { graph.recycle(output: texture) }

        XCTAssertEqual(ImageSize(width: picture.width, height: picture.height),
                       ImageSize(width: 800, height: 200),
                       "the picture is fitted into the canvas, not stretched over it")
        let grid = h.sampleSize
        XCTAssertEqual(grid, Histogram.frameSampleSize(for: picture),
                       "the grid is the picture's rect at 256 on the long edge")
        XCTAssertEqual(h.sampleCount, grid.pixelCount, "the grid, and nothing else, was counted")

        // Bin 0 holds one block (the darkest), not the matte: a letterboxed frame's bars are outside
        // the sampled rect, so they cannot pad the blacks.
        XCTAssertEqual(h.red.bins[0], 0, "没有一个像素来自 letterbox 黑边")
        XCTAssertEqual(h.red.bins[128], grid.pixelCount / 4)
        for channel in Histogram.Channel.allCases {
            let c = h[channel]
            XCTAssertEqual(c.bins.reduce(0, +) + c.hdrBins.reduce(0, +), grid.pixelCount,
                           "\(channel.rawValue): Σbins + ΣhdrBins == 照片矩形内像素数（容差 0）")
        }
        // …and the two segments agree with each other's totals, channel by channel.
        XCTAssertEqual(h.red.total, h.luma.total)
        print("070 letterbox: canvas \(canvas.width)×\(canvas.height) · picture "
              + "\(picture.width)×\(picture.height) · grid \(grid.width)×\(grid.height) = "
              + "\(grid.pixelCount) samples · bin 0 empty")
    }

    // MARK: - 4. what it costs, measured against the source it replaced

    /// **The frame's own cost, old source vs new** — the comparison the派单 asks for (「换测量源后
    /// present 帧时间不劣化 >0.2 ms」). Both sides count the same 36 k samples with the same CPU binning
    /// and read back the same 0.29 MB; the difference is one command buffer (old: a separate pass over
    /// S4's texture, after the frame's own buffer has completed) versus one dispatch inside the frame's
    /// own buffer (new), and four `pow`s per texel on the GPU that the linear path does not need.
    ///
    /// A **debug** build dominates both sides with the CPU binning, so the numbers below are not the
    /// shipping ones — the delta is, which is why the assertion is on the delta.
    func testTheSceneLinearSourceIsNotSlowerThanTheS4FrameItReplaced() throws {
        let picture = fourBlocks(width: 1200, height: 800)      // 0.96 Mpx, viewport-shaped
        let graph = try makeGraph(picture, identity: "histogram-cost")
        let whole = ImageRect(x: 0, y: 0, width: picture.width, height: picture.height)
        let n = 20

        func p50(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

        /// The pre-070 path: render, then measure the S4 texture in a second command buffer.
        func old(iterations: Int) throws -> [Double] {
            var samples: [Double] = []
            for _ in 0..<iterations {
                let t0 = CFAbsoluteTimeGetCurrent()
                let frame = try graph.render(.neutral, options: RenderOptions(
                    scale: 1,
                    display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: ceiling),
                    useCache: false, wantsPixels: false))
                if let texture = frame.output {
                    _ = try graph.measureFrameHistogram(fromFrame: texture, edit: .neutral,
                                                        content: whole, headroom: ceiling)
                    graph.recycle(output: texture)
                }
                samples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            return samples
        }

        /// 070: the same render, measuring its own scene-linear texture.
        func new(iterations: Int) throws -> [Double] {
            var samples: [Double] = []
            for _ in 0..<iterations {
                let t0 = CFAbsoluteTimeGetCurrent()
                let frame = try graph.render(.neutral, options: RenderOptions(
                    scale: 1,
                    display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: ceiling),
                    useCache: false, wantsPixels: false,
                    collectHistogram: true,
                    histogramSampleLongEdge: Histogram.frameSampleLongEdge))
                if let texture = frame.output { graph.recycle(output: texture) }
                samples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            return samples
        }

        _ = try old(iterations: 3)          // warm-up: both pipelines compiled, pool filled
        _ = try new(iterations: 3)
        let before = try old(iterations: n)
        let after = try new(iterations: n)
        let delta = p50(after) - p50(before)

        print("070 cost: frame 1200×800 · S4-frame source p50 "
              + String(format: "%.2f", p50(before)) + " ms · scene-linear source p50 "
              + String(format: "%.2f", p50(after)) + " ms · delta "
              + String(format: "%+.2f", delta) + " ms (debug build; the CPU binning dominates both)")
        XCTAssertLessThan(delta, 0.2,
                          "moving the measurement to the scene-linear texture may not cost the "
                          + "present frame more than 0.2 ms")
    }
}
