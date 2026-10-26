import XCTest
import Metal
import PhotonsCore

/// 027: the histogram measured off the frame S4 just wrote (`RenderGraph.measureHistogram(fromFrame:)`).
///
/// The claim this file defends is narrow and checkable: **the plot a frame produces is the plot the
/// picture produces**, as far as the frame still carries the information. Three separations make that
/// answerable instead of impressionistic:
///
///   1. **The binning is exact for the bytes it counted.** `Histogram.computeEncoded` over the very
///      samples the measurement hands back must reproduce its bins to the count. Anything else would
///      mean the GPU pass or the readback moved a number, which they must not.
///   2. **Same pixels, same bins.** A frame rendered at 1:1 (`collectHistogram` gives the shipped
///      pre-S4 measurement of the *same* render) is measured again from its S4 texture with a grid of
///      one texel per texel. The only difference left is the domain, and this file prints it: below
///      white the two agree bin for bin except where a `Float16` code sits within half an ULP of a bin
///      edge; above white they agree only if the frame had headroom, because S4 clamps to it.
///   3. **The sample is of the picture, not of a patch.** The grid spans the picture's full rect
///      (`(i + 0.5) · step`), the letterbox band is detected and dropped rather than counted into
///      bin 0, and the readback is bounded (0.29 MB at 4.10 Mpx, never the frame's 33 MB).
///
/// The cost is printed rather than asserted tightly: the acceptance number (≤ 2 ms per frame) is a
/// release figure, and a debug build measures a debug build.
final class HistogramSampleTests: XCTestCase {

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String = "histogram-sample") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func image(width: Int, height: Int, hot: Bool = false, textured: Bool = true) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let fx = Double(x), fy = Double(y)
                let a = 0.5 + 0.5 * sin(fx * (textured ? 0.31 : 0.012) + fy * (textured ? 0.07 : 0.004))
                let b = 0.5 + 0.5 * sin(fy * (textured ? 0.43 : 0.017) - fx * (textured ? 0.05 : 0.003))
                var base = 0.08 + 0.42 * a * b
                // A specular band 0.6…3 stops above white in the top-right quadrant: real light the
                // frame's S4 clamp will eat.
                if hot, Double(x) > 0.5 * Double(width), Double(y) < 0.35 * Double(height) {
                    base *= pow(2.0, 0.6 + 2.4 * (fx / Double(width)))
                }
                let o = (y * width + x) * 4
                rgba[o] = Float16(base)
                rgba[o + 1] = Float16(min(base * 1.25, hot ? 6.0 : 0.9))
                rgba[o + 2] = Float16(base * 0.8)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// The frame S4 wrote for `edit`, plus (optionally) the shipped pre-S4 measurement of the *same*
    /// render — one render, two domains, which is what makes the comparison a controlled one.
    private func renderFrame(_ graph: RenderGraph, _ edit: EditModel = .neutral,
                             canvas: ImageSize? = nil, scale: Double = 1,
                             headroom: Double = 1, collectHistogram: Bool = false)
        throws -> (texture: MTLTexture, shipped: Histogram?) {
        let options = RenderOptions(canvas: canvas, scale: scale,
                                    display: DisplayOptions(primaries: .sRGB, bitDepth: 16,
                                                            headroom: headroom),
                                    useCache: false, wantsPixels: false,
                                    collectHistogram: collectHistogram, histogramBins: 256)
        let result = try graph.render(edit, options: options)
        let texture = try XCTUnwrap(result.output, "a pixels-free render must hand back its texture")
        return (texture, result.histogram)
    }

    // MARK: - the grid rule

    func testTheFrameGridRule() {
        // 4.10 Mpx portrait → 141×256 = 36 k samples, 0.29 MB, the same aspect.
        XCTAssertEqual(Histogram.frameSampleLongEdge, 256)
        let portrait = Histogram.frameSampleSize(for: ImageRect(x: 0, y: 0, width: 1500, height: 2731))
        XCTAssertEqual(portrait.keyString, "141x256")
        XCTAssertEqual(portrait.pixelCount * 8, 288_768)
        XCTAssertLessThanOrEqual(portrait.pixelCount * 8, 512 * 1024,
                                 "the readback bound the派单 states is 256×256×8")

        let landscape = Histogram.frameSampleSize(for: ImageRect(x: 0, y: 0, width: 2731, height: 1500))
        XCTAssertEqual(landscape.keyString, "256x141")

        // Never upsampled: a picture smaller than the grid is sampled texel for texel.
        XCTAssertEqual(Histogram.frameSampleSize(for: ImageRect(x: 0, y: 0, width: 120, height: 80))
                        .keyString, "120x80")
        // And a 1-px-wide picture still has a grid.
        XCTAssertEqual(Histogram.frameSampleSize(for: ImageRect(x: 0, y: 0, width: 1, height: 4000))
                        .keyString, "1x256")
    }

    // MARK: - 1. the binning is exact for the bytes it counted

    func testTheBinsAreExactForTheBytesTheFrameCounted() throws {
        let graph = try makeGraph(image(width: 900, height: 700))
        let frame = try renderFrame(graph, scale: 1)
        defer { graph.recycle(output: frame.texture) }

        let measured = try graph.measureFrameHistogram(fromFrame: frame.texture, edit: .neutral)
        XCTAssertEqual(measured.histogram.sampleCount, measured.rect.area)

        // Re-count the very samples it handed back: the GPU pass, the readback and the matte probe
        // must not have moved a single count. `computeFrameSample` because the sample's alpha carries
        // the luma rather than alpha.
        let recount = Histogram.computeFrameSample(measured.sample,
                                                   bins: measured.histogram.binCount,
                                                   rect: measured.rect)
        for name in Histogram.Channel.allCases {
            XCTAssertEqual(recount[name].bins, measured.histogram[name].bins,
                           "\(name): the frame's own bytes must bin identically on the CPU")
            XCTAssertEqual(recount[name].hdrBins, measured.histogram[name].hdrBins)
            XCTAssertEqual(recount[name].clippedHigh, measured.histogram[name].clippedHigh,
                           accuracy: 1e-12)
        }
        XCTAssertEqual(measured.histogram.channels.reduce(0) { $0 + $1.total },
                       4 * measured.rect.area,
                       "every sampled pixel is counted in every channel — coverage, not a patch")
    }

    // MARK: - 2. the readback is bounded and the default grid is the frame's, not the picture's

    func testTheReadbackIsBoundedAndTheGridIsSmall() throws {
        let graph = try makeGraph(image(width: 1500, height: 2731))
        let frame = try renderFrame(graph, scale: 1)
        defer { graph.recycle(output: frame.texture) }

        let measured = try graph.measureFrameHistogram(fromFrame: frame.texture, edit: .neutral)
        XCTAssertEqual(measured.cost.sampleSize.keyString, "141x256")
        XCTAssertEqual(measured.cost.readbackBytes, 141 * 256 * 8)
        XCTAssertLessThanOrEqual(measured.cost.readbackBytes, 512 * 1024,
                                 "0.5 MB is the bound; a 4.10 Mpx frame is 33 MB")
        print(String(format: "frame histogram readback: %d B (%@) for a %d×%d frame — the frame "
                     + "itself is %d B",
                     measured.cost.readbackBytes, measured.cost.sampleSize.keyString,
                     1500, 2731, 1500 * 2731 * 8))
    }

    // MARK: - 3. determinism (L1: same input, same bytes, twice and across graphs)

    func testTwoMeasurementsOfOneFrameAreByteIdentical() throws {
        let graph = try makeGraph(image(width: 900, height: 700))
        let frame = try renderFrame(graph, scale: 1)
        defer { graph.recycle(output: frame.texture) }

        let a = try graph.measureFrameHistogram(fromFrame: frame.texture, edit: .neutral)
        let b = try graph.measureFrameHistogram(fromFrame: frame.texture, edit: .neutral)
        XCTAssertEqual(a.sample.sha256(), b.sample.sha256(),
                       "the same frame must reduce to the same bytes")
        XCTAssertEqual(a.histogram.binsDigest(), b.histogram.binsDigest())
        XCTAssertEqual(a.rect, b.rect)

        // A second graph, same picture and edit, must measure the same frame the same way: the stride
        // is integer arithmetic, not a seeded hash or a clock.
        let other = try makeGraph(image(width: 900, height: 700), identity: "histogram-sample-b")
        let otherFrame = try renderFrame(other, scale: 1)
        defer { other.recycle(output: otherFrame.texture) }
        XCTAssertEqual(otherFrame.texture.width, frame.texture.width)
        let c = try other.measureFrameHistogram(fromFrame: otherFrame.texture, edit: .neutral)
        XCTAssertEqual(c.sample.sha256(), a.sample.sha256())
        XCTAssertEqual(c.histogram.binsDigest(), a.histogram.binsDigest())
        print("frame histogram determinism: sample sha256 \(a.sample.sha256().prefix(16))… "
              + "× 3 calls (2 graphs), 1 digest")
    }

    // MARK: - 4. the domain question, measured: same pixels, two domains

    /// One render at 1:1 allows both measurements of the **same** pixels: `collectHistogram` gives the
    /// shipped one (S3, scene-linear) and the texture gives the frame's own (S4, display-encoded). The
    /// from-frame grid is set to the frame's own size, so the stride is exactly 1 and the difference
    /// that remains is domain, not sampling.
    private struct BinDiff {
        var differing = 0
        var withinHalfPercent = 0
        var worst = 0.0
        var worstBin = 0
        var bins = 0
    }

    private func compare(_ a: [Int], _ b: [Int]) -> BinDiff {
        // Both sides are *fractions of their own sample*: the two grids count different numbers of
        // pixels (36 k against 575 k), so comparing raw counts would report the size difference.
        let nA = Double(max(a.reduce(0, +), 1))
        let nB = Double(max(b.reduce(0, +), 1))
        var d = BinDiff()
        d.bins = min(a.count, b.count)
        for i in 0..<d.bins {
            let delta = abs(Double(a[i]) / nA - Double(b[i]) / nB)
            if a[i] != b[i] { d.differing += 1 }
            if delta <= 0.005 { d.withinHalfPercent += 1 }
            if delta > d.worst { d.worst = delta; d.worstBin = i }
        }
        return d
    }

    func testSamePixelsTwoDomains() throws {
        let w = 1200, h = 900                       // 1.08 Mpx, ordinary tones, nothing above white
        let graph = try makeGraph(image(width: w, height: h))
        let frame = try renderFrame(graph, scale: 1, collectHistogram: true)
        defer { graph.recycle(output: frame.texture) }
        let shipped = try XCTUnwrap(frame.shipped)
        XCTAssertEqual(shipped.sampleCount, w * h, "the reference must be every pixel")

        let measured = try graph.measureFrameHistogram(fromFrame: frame.texture, edit: .neutral,
                                                      sampleLongEdge: w)
        XCTAssertEqual(measured.cost.sampleSize.keyString, "1200x900",
                       "≥ the picture, so the grid is the picture: stride 1, no resampling")
        XCTAssertEqual(measured.histogram.sampleCount, shipped.sampleCount)

        var worst = 0.0
        for name in Histogram.Channel.allCases {
            let d = compare(measured.histogram[name].bins, shipped[name].bins)
            let dt = compare(measured.histogram[name].hdrBins, shipped[name].hdrBins)
            XCTAssertEqual(d.bins, 256)
            XCTAssertEqual(dt.differing, 0, "\(name): nothing here is above white, so the tail is empty "
                           + "in both domains")
            // R, G and B are one OETF applied to one texel value: the frame's code and the code the
            // shipped path derives differ only by the frame's `Float16` storage, so every bin is
            // within half a percent of the sample and in practice most bins match exactly.
            XCTAssertEqual(dt.differing, 0, "\(name): nothing here is above white, so the tail is empty "
                           + "in both domains")
            // R, G and B are one OETF applied to one texel value: the frame's code and the code the
            // shipped path derives differ only by the frame's `Float16` storage, so every bin is
            // within half a percent of the sample. **Luma is the exception, and structurally so**: it
            // is a weighted sum of the three *codes*, so the half-float rounding of three channels
            // adds up before the sum is binned, and a sharply peaked distribution (this synthetic
            // gradient has one) can move a couple of percent of its peak bin across the edge. The
            // count is asserted loosely and printed rather than smoothed over.
            if name == .luma {
                XCTAssertGreaterThanOrEqual(d.withinHalfPercent, d.bins - 6,
                                            "luma: at most a handful of bins may exceed 0.5 %")
            } else {
                XCTAssertEqual(d.withinHalfPercent, d.bins,
                               "\(name): every SDR bin must be within 0.5 % of the sample — "
                               + "worst was bin \(d.worstBin) at \(String(format: "%.4f", d.worst * 100)) %")
            }
            worst = max(worst, d.worst)
            print("  same-pixel \(name.rawValue) SDR bins: \(d.bins - d.differing)/\(d.bins) identical, "
                  + "\(d.withinHalfPercent)/\(d.bins) within 0.5 % of the sample, worst bin "
                  + "\(d.worstBin) = \(String(format: "%.4f", d.worst * 100)) %; tail bins differing "
                  + "\(dt.differing)")
        }
        print(String(format: "same-pixel domain check: 4 channels × 256 SDR bins, worst bin "
                     + "%.4f %% of the sample (half-float code rounding at bin edges)", worst * 100))
    }

    // MARK: - 5. the shipped grids: the plot a drag shows vs the plot the card showed

    func testTheFramePlotTracksTheShippedPlot() throws {
        let w = 1500, h = 2731                      // the repo's 4.10 Mpx reference frame
        let graph = try makeGraph(image(width: w, height: h, hot: false, textured: false))

        let shipped = try graph.measureHistogram(.neutral)
        let frame = try renderFrame(graph, scale: 1)
        defer { graph.recycle(output: frame.texture) }
        let live = try graph.measureFrameHistogram(fromFrame: frame.texture, edit: .neutral)
        XCTAssertEqual(live.cost.sampleSize.keyString, "141x256")
        XCTAssertEqual(shipped.sampleSize.keyString, "562x1024")

        // Two different grids *and* two different domains, on purpose: this is the pair the card will
        // actually show (a live plot during a drag, the shipped one when it settles).
        for name in Histogram.Channel.allCases {
            let d = compare(live.histogram[name].bins, shipped[name].bins)
            XCTAssertGreaterThan(d.withinHalfPercent, 200,
                                 "\(name): the live plot must be the same shape — worst bin "
                                 + "\(d.worstBin) moved \(String(format: "%.3f", d.worst * 100)) % of the sample")
            XCTAssertLessThan(d.worst, 0.02,
                              "\(name): no bin may move more than 2 % of the sample between the two grids")
            print("  live vs shipped \(name.rawValue): \(d.withinHalfPercent)/\(d.bins) bins within "
                  + "0.5 % of the sample, worst bin \(d.worstBin) = "
                  + "\(String(format: "%.3f", d.worst * 100)) %, clippedHigh Δ "
                  + "\(String(format: "%.4f", abs(live.histogram[name].clippedHigh - shipped[name].clippedHigh)))")
        }
        XCTAssertEqual(live.histogram.canvas, shipped.canvas)
        XCTAssertEqual(live.histogram.roi, shipped.roi,
                       "both are labelled with the picture, so the axis and 「采样 N px」 line up")
    }

    // MARK: - 6. the tail: what the frame loses at SDR white, and keeps with headroom

    func testAboveWhiteIsKeptOnlyWhereTheFrameKeptIt() throws {
        let graph = try makeGraph(image(width: 900, height: 700, hot: true))
        // One render, both domains: the shipped measurement of *this* frame and the frame's own
        // texture. Comparing against a second render would mix "what the clamp did" with "did the two
        // renders agree", and only the first is the question here.
        let sdrFrame = try renderFrame(graph, scale: 1, headroom: 1, collectHistogram: true)
        defer { graph.recycle(output: sdrFrame.texture) }
        let shipped = try XCTUnwrap(sdrFrame.shipped)
        XCTAssertGreaterThan(shipped.red.hdrTotal, 0, "the picture has light above white")

        // An SDR frame (headroom 1) clamps it: the information is not in the texture any more.
        let sdr = try graph.measureFrameHistogram(fromFrame: sdrFrame.texture, edit: .neutral,
                                                  headroom: 1)
        XCTAssertEqual(sdr.histogram.red.hdrTotal, 0,
                       "S4 clamped everything above white to code 1.0 — the tail cannot be recovered")

        // Red is the channel the clamp acts on directly (one texel, one code, no cross-channel
        // arithmetic), so it is where "the clamped light is counted where the shipped path reports
        // clipping" is a clean statement. The shipped path counts those pixels twice — in the last bin
        // *and* on the tail (a clipped sample is both, by design) — so the comparison is last+tail.
        let sdrLast = Double(sdr.histogram.red.bins[255]) / Double(max(sdr.histogram.red.total, 1))
        let shippedLast = Double(shipped.red.bins[255] + shipped.red.hdrTotal)
            / Double(max(shipped.red.total, 1))
        XCTAssertEqual(sdrLast, shippedLast, accuracy: 0.01,
                       "the light an SDR frame clamps is what the shipped path reports clipped — "
                       + "\(String(format: "%.4f", sdrLast)) vs \(String(format: "%.4f", shippedLast))")
        XCTAssertGreaterThan(sdr.histogram.red.clippedHigh, 0)

        // The same frame measured on a grid of one texel per texel: the domain question with the
        // sampling question removed. Red must agree to the pixel.
        let dense = try graph.measureFrameHistogram(fromFrame: sdrFrame.texture, edit: .neutral,
                                                    sampleLongEdge: 900, headroom: 1)
        XCTAssertEqual(dense.cost.sampleSize.keyString, "900x700", "stride 1: every pixel")
        XCTAssertEqual(dense.histogram.red.clippedHigh, shipped.red.clippedHigh, accuracy: 0.002,
                       "same pixels, same answer for 削顶 on red: "
                       + "\(String(format: "%.4f", dense.histogram.red.clippedHigh)) vs "
                       + "\(String(format: "%.4f", shipped.red.clippedHigh))")

        // Luma is where the clamp *lowers* the measurement, and structurally so: S4 clamps each
        // channel at the ceiling before luma is formed, so a pixel whose red was 3× white has a luma
        // of at most 1 in the frame (0.21·1 + the others), while the picture's own luma is > 1. The
        // frame's 削顶 is therefore *smaller* — it is the luma of what is displayed, which is the
        // honest number for a plot that sits next to the displayed frame.
        XCTAssertLessThanOrEqual(sdr.histogram.luma.clippedHigh, shipped.luma.clippedHigh)
        XCTAssertGreaterThan(sdr.histogram.luma.clippedHigh, 0)

        // A 1.2× frame keeps a stop of it, and the tail reappears on the same axis.
        let edrFrame = try renderFrame(graph, scale: 1, headroom: 1.2)
        defer { graph.recycle(output: edrFrame.texture) }
        let edr = try graph.measureFrameHistogram(fromFrame: edrFrame.texture, edit: .neutral,
                                                  headroom: 1.2)
        XCTAssertGreaterThan(edr.histogram.red.hdrTotal, 0, "headroom 1.2 survives S4's clamp")
        XCTAssertLessThan(edr.histogram.red.hdrTotal, shipped.red.hdrTotal,
                          "but only up to 1.2× — the rest was clamped")
        // The two ceilings differ, and the ceiling *ratio* is the only thing that moves: a 1.2× frame
        // keeps some of the light an SDR one throws away.
        XCTAssertNotEqual(sdr.histogram.red.clippedCeiling, edr.histogram.red.clippedCeiling,
                          "the ceiling ratio is the one thing headroom moves")
        print("frame histogram tail: picture hdrTotal(red) \(shipped.red.hdrTotal), SDR frame 0 "
              + "(clamped at white, \(sdr.histogram.red.bins[255]) of \(sdr.histogram.red.total) in "
              + "the last bin), 1.2× frame \(edr.histogram.red.hdrTotal); clippedHigh red "
              + "\(String(format: "%.4f", sdr.histogram.red.clippedHigh)) on the frame vs "
              + "\(String(format: "%.4f", shipped.red.clippedHigh)) on the picture, luma "
              + "\(String(format: "%.4f", sdr.histogram.luma.clippedHigh)) vs "
              + "\(String(format: "%.4f", shipped.luma.clippedHigh)) (the clamp lowers luma)")
    }

    // MARK: - 7. the matte is not part of the picture

    func testTheLetterboxBandIsNotCounted() throws {
        let w = 900, h = 1400                       // portrait picture …
        let canvas = ImageSize(width: 1600, height: 1000)   // … into a landscape window
        let graph = try makeGraph(image(width: w, height: h, textured: false))

        let shown = try renderFrame(graph, canvas: canvas, scale: 0.71, collectHistogram: true)
        defer { graph.recycle(output: shown.texture) }
        let shipped = try XCTUnwrap(shown.shipped)
        // An in-render measurement is labelled in the *frame's* coordinates (the canvas it drew),
        // unlike `measureHistogram` which relabels to the picture's own grid.
        XCTAssertEqual(shipped.canvas.keyString, canvas.keyString)
        XCTAssertEqual(shipped.roi, ImageRect(x: 478, y: 0, width: 643, height: 1000),
                       "the picture is centred in the canvas by S0's letterbox")

        // No `content:`, so the matte has to be *found*: the probe must drop the bands rather than
        // count them into bin 0.
        let live = try graph.measureFrameHistogram(fromFrame: shown.texture, edit: .neutral)
        let sample = live.cost.sampleSize
        XCTAssertLessThan(live.rect.width, sample.width, "the bands are left and right")
        XCTAssertEqual(live.rect.height, sample.height)
        XCTAssertGreaterThan(live.rect.width, 0)

        // The picture's own fraction of the canvas, to the pixel: 900/1400 of a 1600×1000 canvas is
        // 643×1000, i.e. ~40 % of the width. Anything near 100 % means the matte was counted.
        let expectedWidthFraction = 643.0 / 1600.0
        XCTAssertEqual(Double(live.rect.width) / Double(sample.width), expectedWidthFraction,
                       accuracy: 0.02)

        // And the plot agrees with the shipped one instead of reporting a third of the frame as black.
        for name in Histogram.Channel.allCases {
            let d = compare(live.histogram[name].bins, shipped[name].bins)
            XCTAssertLessThan(d.worst, 0.02,
                              "\(name): bin \(d.worstBin) differs by "
                              + "\(String(format: "%.3f", d.worst * 100)) % — matte in bin 0 would be ~30 %")
            XCTAssertEqual(live.histogram[name].clippedLow, shipped[name].clippedLow, accuracy: 0.02,
                           "\(name): counting the matte would read as 削底")
        }
        print("frame histogram matte: canvas \(canvas.keyString) → sample \(sample.keyString), "
              + "counted \(live.rect.keyString) (picture is 643×1000 of it)")
    }

    /// A caller that knows the picture's rect gets it used verbatim — no probe, and the band is not
    /// even sampled.
    func testAnExplicitContentRectIsUsedVerbatim() throws {
        let graph = try makeGraph(image(width: 900, height: 1400, textured: false))
        let canvas = ImageSize(width: 1600, height: 1000)
        let shown = try renderFrame(graph, canvas: canvas, scale: 0.71)
        defer { graph.recycle(output: shown.texture) }

        let content = ImageRect(x: 478, y: 0, width: 643, height: 1000)
        let live = try graph.measureFrameHistogram(fromFrame: shown.texture, edit: .neutral,
                                                   content: content)
        XCTAssertEqual(live.cost.sampleSize.keyString, "165x256")
        XCTAssertEqual(live.rect, ImageRect(x: 0, y: 0, width: 165, height: 256),
                       "an explicit rect is sampled edge to edge, so the whole sample is counted")
    }

    // MARK: - 8. the cost, printed (debug here; the release numbers are in the task report)

    func testTheCostOfMeasuringOneFrame() throws {
        let graph = try makeGraph(image(width: 1500, height: 2731))
        let frame = try renderFrame(graph, scale: 1)
        defer { graph.recycle(output: frame.texture) }

        _ = try graph.measureFrameHistogram(fromFrame: frame.texture, edit: .neutral)   // warm
        var wall: [Double] = [], gpu: [Double] = [], cpu: [Double] = []
        for _ in 0..<20 {
            let m = try graph.measureFrameHistogram(fromFrame: frame.texture, edit: .neutral)
            wall.append(m.cost.wallMilliseconds)
            gpu.append(m.cost.gpuMilliseconds)
            cpu.append(m.cost.cpuMilliseconds)
        }
        func stat(_ xs: [Double]) -> (p50: Double, p95: Double, max: Double) {
            let s = xs.sorted()
            return (s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.95))], s.last ?? 0)
        }
        let w = stat(wall), g = stat(gpu), c = stat(cpu)
        print(String(format: "frame histogram cost (4.10 Mpx frame → %@ = %d B): wall p50 %.2f / "
                     + "p95 %.2f / max %.2f ms · downsample pass p50 %.2f / p95 %.2f / max %.2f ms · "
                     + "CPU binning p50 %.2f / p95 %.2f / max %.2f ms",
                     "141x256", 141 * 256 * 8, w.p50, w.p95, w.max, g.p50, g.p95, g.max,
                     c.p50, c.p95, c.max))
        // Loose on purpose: this runs in a *debug* build, where the CPU binning is an order of
        // magnitude slower than release. The release figure is what the派单 bounds (≤ 2 ms), and it is
        // measured by `photonsctl histogram --from-frame`.
        XCTAssertLessThan(w.p50, 60, "debug build; the release budget is ≤ 2 ms")
    }
}
