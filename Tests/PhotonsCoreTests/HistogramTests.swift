import XCTest
import Metal
import PhotonsCore

/// The histogram (005f): four series, two clipping ratios, an optional ROI, and one readback of a
/// reduced grid.
///
/// What this file defends, in the order the failures would appear:
///
///   1. **The arithmetic is right at the ends.** Black is bin 0 and counts as clipped-low; white is the
///      last bin and counts as clipped-high; a ramp that is one pixel per bin lands exactly there. This
///      is the part that can be checked without a GPU, so it is the part that is checked hardest.
///   2. **The three channels plus luma are *separate* series**, not one series printed three times.
///   3. **A ROI counts only what is inside it**, and the mapping from canvas pixels to the sample grid
///      is exact when no reduction is needed — the GPU path and the CPU reference then agree bin for
///      bin, which is a much stronger statement than "roughly the same shape".
///   4. **Reduction costs accuracy, and no more than the documented bound.** The downsampled
///      histogram of a 1.08 Mpx frame is compared against the full-resolution one; every bin must be
///      within 1 % of the total, and the number is printed so the claim travels with a measurement.
///   5. **Off means off.** `collectHistogram == false` produces `nil`, identical pixels, identical
///      keys, and a frame time that is not slower than the measured one (`test...FrameTime`).
final class HistogramTests: XCTestCase {

    // MARK: - fixtures

    private func display(_ rgba: [Float16], _ width: Int, _ height: Int,
                         primaries: OutputPrimaries = .sRGB) -> DisplayImage {
        XCTAssertEqual(rgba.count, width * height * 4)
        return DisplayImage(width: width, height: height, rgba: rgba,
                            primaries: primaries, bitDepth: 8)
    }

    /// `value` per pixel, alpha 1.
    private func solid(_ width: Int, _ height: Int, rgb: Float) -> DisplayImage {
        var rgba = [Float16](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = Float16(rgb)
            rgba[i * 4 + 1] = Float16(rgb)
            rgba[i * 4 + 2] = Float16(rgb)
        }
        return display(rgba, width, height)
    }

    /// The bin a value must land in, computed the way the type documents it.
    private func expectedBin(_ v: Float, bins: Int = 256) -> Int {
        min(bins - 1, max(0, Int(v * Float(bins))))
    }

    private func fractions(_ channel: HistogramChannel) -> [Double] {
        let n = Double(max(channel.total, 1))
        return channel.bins.map { Double($0) / n }
    }

    private func makeGraph(_ image: LinearImage, identity: String = "histogram-test") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// Two beating gratings, mid-tones, no clipping: a distribution with structure in every channel, so
    /// a reduction that flattens it shows up immediately.
    private func texturedImage(width: Int, height: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let fx = Double(x), fy = Double(y)
                let a = 0.5 + 0.5 * sin(fx * 0.31 + fy * 0.07)
                let b = 0.5 + 0.5 * sin(fy * 0.43 - fx * 0.05)
                let base = 0.08 + 0.42 * a * b
                let o = (y * width + x) * 4
                rgba[o] = Float16(base)
                rgba[o + 1] = Float16(min(base * 1.25, 0.9))
                rgba[o + 2] = Float16(base * 0.8)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// Photographic frequencies (period ≈ 300–800 px): what a picture's histogram is stable against.
    private func smoothImage(width: Int, height: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let fx = Double(x), fy = Double(y)
                let a = 0.5 + 0.5 * sin(fx * 0.012 + fy * 0.004)
                let b = 0.5 + 0.5 * sin(fy * 0.017 - fx * 0.003)
                let base = 0.08 + 0.42 * a * b
                let o = (y * width + x) * 4
                rgba[o] = Float16(base)
                rgba[o + 1] = Float16(min(base * 1.25, 0.9))
                rgba[o + 2] = Float16(base * 0.8)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    // MARK: - 1. the ends

    func testPureBlackFillsBinZeroAndClipsLow() {
        let h = Histogram.compute(solid(8, 4, rgb: 0))
        XCTAssertEqual(h.sampleCount, 32)
        XCTAssertEqual(h.binCount, 256)
        for channel in h.channels {
            XCTAssertEqual(channel.bins[0], 32)
            XCTAssertEqual(channel.total, 32)
            XCTAssertEqual(channel.clippedLow, 1.0, accuracy: 1e-12)
            XCTAssertEqual(channel.clippedHigh, 0.0, accuracy: 1e-12)
            XCTAssertEqual(channel.peakBin, 0)
        }
        XCTAssertEqual(h.red.bins.count, 256)
        XCTAssertEqual(h.channels.reduce(0) { $0 + $1.bins.count }, 4 * 256)
    }

    func testPureWhiteFillsLastBinAndClipsHigh() {
        let h = Histogram.compute(solid(5, 3, rgb: 1))
        for channel in h.channels {
            XCTAssertEqual(channel.bins[255], 15, "white must be the last bin, not one past it")
            XCTAssertEqual(channel.clippedHigh, 1.0, accuracy: 1e-12)
            XCTAssertEqual(channel.clippedLow, 0.0, accuracy: 1e-12)
        }
    }

    /// 0.998 is *not* clipped (the threshold is 0.999) but is still the last bin — the distinction the
    /// warning is supposed to make.
    func testNearWhiteIsLastBinWithoutBeingClipped() {
        let h = Histogram.compute(solid(4, 4, rgb: 0.998))
        XCTAssertEqual(h.red.bins[255], 16)
        XCTAssertEqual(h.red.clippedHigh, 0.0, accuracy: 1e-12)
    }

    // MARK: - 2. a ramp, one pixel per bin

    func testGrayRampPutsOnePixelInEveryBin() {
        let n = 256, w = 16, hgt = 16
        var rgba = [Float16](repeating: 1, count: w * hgt * 4)
        for i in 0..<(w * hgt) {
            let v = Float16((Double(i) + 0.5) / Double(n))   // bin i, unambiguously
            rgba[i * 4] = v
            rgba[i * 4 + 1] = v
            rgba[i * 4 + 2] = v
        }
        let hist = Histogram.compute(display(rgba, w, hgt))
        XCTAssertEqual(hist.sampleCount, n)
        for name in Histogram.Channel.allCases {
            let channel = hist[name]
            XCTAssertEqual(channel.total, n)
            XCTAssertEqual(channel.bins.filter { $0 == 1 }.count, n,
                           "\(name): every bin must hold exactly one pixel")
            XCTAssertEqual(channel.clippedHigh, 0, accuracy: 1e-12)
            XCTAssertEqual(channel.clippedLow, 0, accuracy: 1e-12)
        }
        // Monotone: the ramp's bins are in value order, which is the only ordering claim here.
        let bins = hist.luma.bins
        XCTAssertEqual(bins.firstIndex(of: 1), 0)
        XCTAssertEqual(bins.lastIndex(of: 1), 255)
    }

    // MARK: - 3. channels are separate series

    func testChannelsAreSeparateSeries() throws {
        let w = 64, h = 8
        var rgba = [Float16](repeating: 1, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i * 4] = Float16((Double(i % w) + 0.5) / Double(w))   // R ramps across the row
            rgba[i * 4 + 1] = Float16(0.25)                           // G constant
            rgba[i * 4 + 2] = Float16(0.75)                           // B constant
        }
        let hist = Histogram.compute(display(rgba, w, h))

        // R spread over ~64 bins near the bottom of the range.
        XCTAssertGreaterThan(hist.red.bins.filter { $0 > 0 }.count, 16)
        // G and B are single spikes, in the bins their values imply.
        XCTAssertEqual(hist.green.bins[expectedBin(0.25)], w * h)
        XCTAssertEqual(hist.green.bins.filter { $0 > 0 }.count, 1)
        XCTAssertEqual(hist.blue.bins[expectedBin(0.75)], w * h)
        XCTAssertEqual(hist.blue.bins.filter { $0 > 0 }.count, 1)
        // Luma is its own series: 0.2126·r + 0.7152·0.25 + 0.0722·0.75, so its support is the red
        // series shifted up by the constant green and blue contribute — not a copy of red.
        XCTAssertEqual(hist.luma.total, w * h)
        XCTAssertNotEqual(hist.luma.bins, hist.red.bins)
        let lumaLo = 0.2126 * 0.0 + 0.7152 * 0.25 + 0.0722 * 0.75
        let lumaHi = 0.2126 * 1.0 + 0.7152 * 0.25 + 0.0722 * 0.75
        let occupied = hist.luma.bins.enumerated().filter { $0.element > 0 }.map(\.offset)
        let first = try XCTUnwrap(occupied.first)
        let last = try XCTUnwrap(occupied.last)
        XCTAssertGreaterThanOrEqual(first, expectedBin(Float(lumaLo), bins: 256) - 1)
        XCTAssertLessThanOrEqual(last, expectedBin(Float(lumaHi), bins: 256) + 1)
        XCTAssertGreaterThan(first, hist.red.bins.firstIndex { $0 > 0 } ?? 0)
    }

    // MARK: - 4. clipping ratios

    func testClippingRatiosAreExactFractions() {
        let w = 8, h = 8                       // 64 px: 32 white, 16 near-black, 16 mid
        var rgba = [Float16](repeating: 1, count: w * h * 4)
        for i in 0..<(w * h) {
            let v: Float16 = i < 32 ? 1.0 : (i < 48 ? 0.0005 : 0.5)
            rgba[i * 4] = v; rgba[i * 4 + 1] = v; rgba[i * 4 + 2] = v
        }
        let hist = Histogram.compute(display(rgba, w, h))
        for channel in hist.channels {
            XCTAssertEqual(channel.clippedHigh, 0.5, accuracy: 1e-12)
            XCTAssertEqual(channel.clippedLow, 0.25, accuracy: 1e-12)
            XCTAssertEqual(channel.total, 64)
        }
        // 0.0005 is clipped low and still in bin 0; 0.999 itself is the threshold's edge case.
        XCTAssertEqual(hist.red.bins[0], 16)
        XCTAssertEqual(hist.red.bins[expectedBin(0.5)], 16)
        XCTAssertEqual(hist.red.bins[255], 32)
    }

    // MARK: - 5. ROI

    func testROIOnlyCountsPixelsInsideTheRect() {
        let w = 4, h = 2                        // left half white, right half black
        var rgba = [Float16](repeating: 1, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v: Float16 = x < 2 ? 1.0 : 0.0
                let o = (y * w + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v
            }
        }
        let image = display(rgba, w, h)

        let left = Histogram.compute(image, rect: ImageRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(left.sampleCount, 4)
        XCTAssertEqual(left.roi, ImageRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(left.red.bins[255], 4)
        XCTAssertEqual(left.red.clippedHigh, 1.0, accuracy: 1e-12)

        let right = Histogram.compute(image, rect: ImageRect(x: 2, y: 0, width: 2, height: 2))
        XCTAssertEqual(right.red.bins[0], 4)
        XCTAssertEqual(right.red.clippedLow, 1.0, accuracy: 1e-12)

        // A rect that leaves the frame is clamped by `PixelRect.clamped`: shrunk to fit, then moved
        // inside. An oversized rect therefore becomes the whole frame — a count of pixels that exist,
        // never of pixels asked for.
        let oversized = Histogram.compute(image, rect: ImageRect(x: 2, y: 1, width: 99, height: 99))
        XCTAssertEqual(oversized.roi, ImageRect(x: 0, y: 0, width: 4, height: 2))
        XCTAssertEqual(oversized.sampleCount, 8)

        // And the whole-frame measurement is the sum of its parts.
        let whole = Histogram.compute(image)
        XCTAssertEqual(whole.red.bins[0], left.red.bins[0] + right.red.bins[0])
        XCTAssertEqual(whole.red.bins[255], left.red.bins[255] + right.red.bins[255])
    }

    // MARK: - 6. degenerate sizes

    func testSinglePixelAndEmptyROIAreWellDefined() {
        let one = solid(1, 1, rgb: 1)
        let h = Histogram.compute(one)
        XCTAssertEqual(h.sampleCount, 1)
        XCTAssertEqual(h.binCount, 256)
        XCTAssertEqual(h.red.bins[255], 1)
        XCTAssertEqual(h.red.clippedHigh, 1.0, accuracy: 1e-12)
        XCTAssertEqual(h.sampleFraction, 1.0, accuracy: 1e-12)
        XCTAssertEqual(Histogram.sampleSize(for: ImageRect(x: 0, y: 0, width: 1, height: 1)).keyString,
                       "1x1")

        // An empty rect is a measurement of nothing, not of pixel (0,0).
        let empty = Histogram.compute(solid(4, 4, rgb: 0.5),
                                      rect: ImageRect(x: 1, y: 1, width: 0, height: 0))
        XCTAssertEqual(empty.sampleCount, 0)
        for channel in empty.channels {
            XCTAssertEqual(channel.total, 0)
            XCTAssertEqual(channel.clippedHigh, 0)
            XCTAssertEqual(channel.clippedLow, 0)
            XCTAssertNil(channel.peakBin)
        }
        XCTAssertEqual(empty.sampleFraction, 0)

        // A one-pixel ROI of a bigger picture still has its own bin.
        let single = Histogram.compute(solid(9, 9, rgb: 0.5),
                                       rect: ImageRect(x: 4, y: 4, width: 1, height: 1))
        XCTAssertEqual(single.sampleCount, 1)
        XCTAssertEqual(single.red.bins[expectedBin(0.5)], 1)
    }

    /// The reduction's sizing rule, without a GPU: aspect preserved, long edge ≤ 1024, never upsampled.
    func testSampleSizeRule() {
        XCTAssertEqual(Histogram.sampleSize(for: ImageRect(x: 0, y: 0, width: 600, height: 400)).keyString,
                       "600x400")
        XCTAssertEqual(Histogram.sampleSize(for: ImageRect(x: 0, y: 0, width: 1500, height: 2731)).keyString,
                       "562x1024")
        XCTAssertEqual(Histogram.sampleSize(for: ImageRect(x: 0, y: 0, width: 2731, height: 1500)).keyString,
                       "1024x562")
        XCTAssertEqual(Histogram.sampleSize(for: ImageRect(x: 0, y: 0, width: 1, height: 4000)).keyString,
                       "1x1024")
    }

    // MARK: - 7. the GPU path, whole frame: the reduction's error, measured

    func testDownsamplingKeepsBinCountsWithinOnePercent() throws {
        let w = 1200, h = 900                       // 1.08 Mpx; sample grid is 1024×768
        let graph = try makeGraph(smoothImage(width: w, height: h))
        let opts = RenderOptions(scale: 1, useCache: false, wantsPixels: true,
                                 collectHistogram: true)
        let result = try graph.render(.neutral, options: opts)
        let full = try XCTUnwrap(result.display)
        let measured = try XCTUnwrap(result.histogram)

        XCTAssertEqual(measured.canvas, ImageSize(width: w, height: h))
        XCTAssertEqual(measured.roi, ImageRect(x: 0, y: 0, width: w, height: h))
        XCTAssertEqual(measured.sampleSize, Histogram.sampleSize(for: measured.roi))
        XCTAssertEqual(measured.sampleCount, measured.sampleSize.pixelCount)
        XCTAssertLessThan(measured.sampleCount, full.width * full.height)

        // The reference: the same frame, every pixel, on the CPU.
        let reference = Histogram.compute(full)
        XCTAssertEqual(reference.sampleCount, full.width * full.height)

        var worst = 0.0
        for name in Histogram.Channel.allCases {
            let a = fractions(measured[name])
            let b = fractions(reference[name])
            XCTAssertEqual(measured[name].total, measured.sampleCount)
            let diff = zip(a, b).map { abs($0 - $1) }.max() ?? 0
            worst = max(worst, diff)
            XCTAssertLessThan(diff, 0.01,
                              "\(name): one bin moved \(String(format: "%.3f", diff * 100)) % of the "
                              + "pixels; the documented bound is 1 %")
            XCTAssertEqual(measured[name].clippedHigh, reference[name].clippedHigh, accuracy: 0.01)
            XCTAssertEqual(measured[name].clippedLow, reference[name].clippedLow, accuracy: 0.01)
        }
        print(String(format: "histogram reduction: %d px → %d px (%@), worst bin error %.3f %% of total",
                     full.width * full.height, measured.sampleCount,
                     measured.sampleSize.keyString, worst * 100))

        // For the record, the same measurement on 20-px gratings: this is the case the file's error
        // note says is *not* bounded by 1 % — a reduction turns near-Nyquist detail into an average,
        // and no histogram can undo that. Printed, not asserted, so the number travels with the claim.
        let detail = try makeGraph(texturedImage(width: w, height: h))
        let detailResult = try detail.render(.neutral, options: opts)
        let detailFull = try XCTUnwrap(detailResult.display)
        let detailHist = try XCTUnwrap(detailResult.histogram)
        let detailRef = Histogram.compute(detailFull)
        var detailWorst = 0.0
        for name in Histogram.Channel.allCases {
            let diff = zip(fractions(detailHist[name]), fractions(detailRef[name]))
                .map { abs($0 - $1) }.max() ?? 0
            detailWorst = max(detailWorst, diff)
        }
        print(String(format: "histogram reduction on 20-px detail: worst bin error %.3f %% of total "
                     + "(no 1 %% claim for near-Nyquist content)", detailWorst * 100))
    }

    // MARK: - 8. the GPU path, ROI: pixel-exact when there is nothing to reduce

    func testGraphROIMatchesTheCPUHistogramOfThosePixels() throws {
        let w = 1200, h = 900
        let graph = try makeGraph(texturedImage(width: w, height: h))
        let roi = ImageRect(x: 100, y: 50, width: 400, height: 300)   // < 1024 → 1:1 sample
        var opts = RenderOptions(scale: 1, useCache: false, wantsPixels: true,
                                 collectHistogram: true)
        opts.histogramROI = roi
        let result = try graph.render(.neutral, options: opts)
        let full = try XCTUnwrap(result.display)
        let measured = try XCTUnwrap(result.histogram)

        XCTAssertEqual(measured.roi, roi)
        XCTAssertEqual(measured.canvas, ImageSize(width: w, height: h))
        XCTAssertEqual(measured.sampleSize, ImageSize(width: 400, height: 300))
        XCTAssertEqual(measured.sampleCount, 400 * 300)

        let reference = Histogram.compute(full, rect: roi)
        for name in Histogram.Channel.allCases {
            XCTAssertEqual(measured[name].bins, reference[name].bins,
                           "\(name): a 1:1 sample must be the pixels themselves, bin for bin")
            XCTAssertEqual(measured[name].clippedHigh, reference[name].clippedHigh, accuracy: 1e-12)
            XCTAssertEqual(measured[name].clippedLow, reference[name].clippedLow, accuracy: 1e-12)
        }

        // The ROI really did exclude the rest of the frame.
        let whole = Histogram.compute(full)
        XCTAssertNotEqual(measured.red.bins, whole.red.bins)

        if let t = result.output { graph.recycle(output: t) }
    }

    /// A ROI with no area is an empty measurement even on the render path (no dispatch, no sample).
    func testGraphEmptyROIProducesAnEmptyHistogram() throws {
        let graph = try makeGraph(texturedImage(width: 300, height: 200))
        var opts = RenderOptions(scale: 1, useCache: false, wantsPixels: false,
                                 collectHistogram: true)
        opts.histogramROI = ImageRect(x: 10, y: 10, width: 0, height: 0)
        let result = try graph.render(.neutral, options: opts)
        let h = try XCTUnwrap(result.histogram)
        XCTAssertEqual(h.sampleCount, 0)
        XCTAssertEqual(h.roi, ImageRect(x: 10, y: 10, width: 0, height: 0))
        XCTAssertEqual(h.red.total, 0)
        if let t = result.output { graph.recycle(output: t) }
    }

    // MARK: - 9. off means off, and on means one extra dispatch

    func testPixelsAndKeysAreIdenticalWithAndWithout() throws {
        let graph = try makeGraph(texturedImage(width: 640, height: 480))

        let off = try graph.render(.neutral, options: RenderOptions(scale: 1, useCache: false,
                                                                   wantsPixels: true))
        var on = RenderOptions(scale: 1, useCache: false, wantsPixels: true)
        on.collectHistogram = true
        let onResult = try graph.render(.neutral, options: on)

        XCTAssertNil(off.histogram, "the default must not measure anything")
        XCTAssertNotNil(onResult.histogram)

        let a = try XCTUnwrap(off.display), b = try XCTUnwrap(onResult.display)
        XCTAssertEqual(a.sha256(), b.sha256(), "measuring must not touch a pixel")
        XCTAssertEqual(off.canvas, onResult.canvas)
        XCTAssertEqual(off.keys, onResult.keys, "the histogram is a measurement, not document state")
        XCTAssertEqual(off.trace.executed, onResult.trace.executed,
                       "no stage may appear because a histogram was asked for")
    }

    /// Frame cost of the measurement, interleaved so drift cannot favour either side. The assertion is
    /// deliberately loose (a p50 ratio under contention is not a microbenchmark); the numbers are
    /// printed and quoted in the task report.
    func testFrameTimeWithAndWithoutHistogram() throws {
        // The frame the repo quotes everywhere: 1500 × 2731 = 4.10 Mpx canvas.
        let graph = try makeGraph(texturedImage(width: 1500, height: 2731))
        let base = RenderOptions(scale: 1, useCache: false, wantsPixels: false)
        var with = base
        with.collectHistogram = true

        // Warm up both paths: pipeline compile, texture allocation, the pool.
        for _ in 0..<2 {
            if let t = try graph.render(.neutral, options: base).output { graph.recycle(output: t) }
            if let t = try graph.render(.neutral, options: with).output { graph.recycle(output: t) }
        }

        var offTimes: [Double] = [], onTimes: [Double] = []
        for _ in 0..<8 {
            var t0 = CFAbsoluteTimeGetCurrent()
            if let t = try graph.render(.neutral, options: base).output { graph.recycle(output: t) }
            offTimes.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)

            t0 = CFAbsoluteTimeGetCurrent()
            if let t = try graph.render(.neutral, options: with).output { graph.recycle(output: t) }
            onTimes.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }

        func median(_ xs: [Double]) -> Double {
            let s = xs.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        func p95(_ xs: [Double]) -> Double {
            let s = xs.sorted()
            return s[min(s.count - 1, Int((Double(s.count - 1) * 0.95).rounded()))]
        }
        let (offP50, onP50) = (median(offTimes), median(onTimes))
        print(String(format: "histogram frame cost (1500×2731 = 4.10 Mpx): off p50 %.2f ms / p95 %.2f ms · "
                     + "on p50 %.2f ms / p95 %.2f ms · Δp50 %+.2f ms",
                     offP50, p95(offTimes), onP50, p95(onTimes), onP50 - offP50))

        XCTAssertLessThanOrEqual(offP50, max(onP50 * 1.4, onP50 + 1.0),
                                 "collecting a histogram off must not cost more than on")
    }
}
