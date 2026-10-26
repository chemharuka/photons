import XCTest
import Metal
import PhotonsCore

/// The histogram (005f, rewritten for 005 2026-10-26): four series, three ratios, and a measurement of
/// **the picture** taken before S4.
///
/// What this file defends, in the order the failures would appear:
///
///   1. **The arithmetic is right at the ends.** Black is bin 0 and counts as clipped-low; white is the
///      last bin and counts as clipped-high; a ramp that is one pixel per bin lands exactly there. This
///      is the part that can be checked without a GPU, so it is the part that is checked hardest.
///   2. **The three channels plus luma are *separate* series**, not one series printed three times.
///   3. **The tail is 6 stops of 1/16 stop** and its seam at white is exact: white is the last code
///      bin, a hair above it is tail bin 0, and anything past 6 stops piles onto the last bin.
///   4. **The measurement is of the picture, not of the frame.** `measureHistogram` renders the whole
///      picture at thumbnail scale; the same photo and edit give the same bins and the same
///      `sampleCount` no matter what window, canvas or scale the camera happened to be showing, and a
///      second call cannot drift.
///   5. **The screen cannot move a bin.** The measurement is pre-S4, so an SDR (`headroom = 1`) and an
///      EDR (`headroom = 1.2`) measurement of the same picture agree on all 256 SDR bins *and* the
///      tail — only `clippedCeiling` differs. An SDR measurement still sees light above white.
///   6. **Reduction costs accuracy, and no more than the documented bound.** The thumbnail is compared
///      against a full-resolution recount of the same picture; every bin must be within 1 % of the
///      total and the numbers are printed so the claim travels with a measurement.
///   7. **Off means off, and a frame never measures.** `collectHistogram == false` produces `nil` and
///      identical pixels, and a plain `render` produces `nil` even when a measurement exists — the
///      card's numbers come from their own render.
final class HistogramTests: XCTestCase {

    // MARK: - fixtures

    private func display(_ rgba: [Float16], _ width: Int, _ height: Int,
                         primaries: OutputPrimaries = .sRGB) -> DisplayImage {
        XCTAssertEqual(rgba.count, width * height * 4)
        return DisplayImage(width: width, height: height, rgba: rgba,
                            primaries: primaries, bitDepth: 8)
    }

    /// `value` per pixel, alpha 1 — **display-encoded**, the form the hand-built fixtures are in.
    private func solid(_ width: Int, _ height: Int, rgb: Float) -> DisplayImage {
        var rgba = [Float16](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = Float16(rgb)
            rgba[i * 4 + 1] = Float16(rgb)
            rgba[i * 4 + 2] = Float16(rgb)
        }
        return display(rgba, width, height)
    }

    /// **Linear** light at `value` per pixel — what the graph actually measures.
    private func solidLinear(_ width: Int, _ height: Int, rgb: Float) -> LinearSample {
        var rgba = [Float16](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = Float16(rgb)
            rgba[i * 4 + 1] = Float16(rgb)
            rgba[i * 4 + 2] = Float16(rgb)
        }
        return LinearSample(width: width, height: height, rgba: rgba)
    }

    /// The bin a value must land in, computed the way the type documents it.
    private func expectedBin(_ v: Float, bins: Int = 256) -> Int {
        min(bins - 1, max(0, Int(v * Float(bins))))
    }

    private func fractions(_ channel: HistogramChannel) -> [Double] {
        let n = Double(max(channel.total, 1))
        return channel.bins.map { Double($0) / n }
    }

    private func tailFractions(_ channel: HistogramChannel) -> [Double] {
        let n = Double(max(channel.total, 1))
        return channel.hdrBins.map { Double($0) / n }
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

    /// A picture with real highlight headroom: a smooth base plus a "specular" band that runs 1.5 to
    /// 8 stops above white. This is the fixture the SDR-screen claim needs — 68 % of the frame is
    /// ordinary tones and the rest is light no SDR panel can show.
    private func hotImage(width: Int, height: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let fx = Double(x), fy = Double(y)
                let base = 0.05 + 0.35 * (0.5 + 0.5 * sin(fx * 0.011 + fy * 0.005))
                // The top-right quadrant is the hot band; its height varies 0…3 stops above white.
                let inBand = Double(x) > 0.5 * Double(width) && Double(y) < 0.35 * Double(height)
                let lift = inBand ? pow(2.0, 0.6 + 2.4 * (fx / Double(width))) : 1.0
                let o = (y * width + x) * 4
                rgba[o] = Float16(base * lift)
                rgba[o + 1] = Float16(base * lift * 0.96)
                rgba[o + 2] = Float16(base * lift * 0.9)
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
        let bins = hist.luma.bins
        XCTAssertEqual(bins.firstIndex(of: 1), 0)
        XCTAssertEqual(bins.lastIndex(of: 1), 255)
    }

    /// The same ramp, handed in as **linear** light (the shipped form): the code axis is derived here,
    /// so the bins must be the ramp's own.
    func testALinearRampLandsOnTheSameCodeBins() {
        let n = 256, w = 16, hgt = 16
        var rgba = [Float16](repeating: 1, count: w * hgt * 4)
        for i in 0..<(w * hgt) {
            let code = Float((Double(i) + 0.5) / Double(n))
            let linear = code <= 0.04045 ? code / 12.92 : pow((code + 0.055) / 1.055, 2.4)
            rgba[i * 4] = Float16(linear)
            rgba[i * 4 + 1] = Float16(linear)
            rgba[i * 4 + 2] = Float16(linear)
        }
        let hist = Histogram.compute(LinearSample(width: w, height: hgt, rgba: rgba))
        XCTAssertEqual(hist.sampleCount, n)
        XCTAssertEqual(hist.red.bins.filter { $0 == 1 }.count, n,
                       "a linear ramp must reach every code bin exactly once")
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

        XCTAssertGreaterThan(hist.red.bins.filter { $0 > 0 }.count, 16)
        XCTAssertEqual(hist.green.bins[expectedBin(0.25)], w * h)
        XCTAssertEqual(hist.green.bins.filter { $0 > 0 }.count, 1)
        XCTAssertEqual(hist.blue.bins[expectedBin(0.75)], w * h)
        XCTAssertEqual(hist.blue.bins.filter { $0 > 0 }.count, 1)
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
        XCTAssertEqual(hist.red.bins[0], 16)
        XCTAssertEqual(hist.red.bins[expectedBin(0.5)], 16)
        XCTAssertEqual(hist.red.bins[255], 32)
    }

    // MARK: - 5. the CPU API's region

    func testARectOnlyCountsPixelsInsideIt() {
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

        // A rect that leaves the frame is clamped: an oversized rect becomes the whole frame — a count
        // of pixels that exist, never of pixels asked for.
        let oversized = Histogram.compute(image, rect: ImageRect(x: 2, y: 1, width: 99, height: 99))
        XCTAssertEqual(oversized.roi, ImageRect(x: 0, y: 0, width: 4, height: 2))
        XCTAssertEqual(oversized.sampleCount, 8)

        // And the whole-frame measurement is the sum of its parts.
        let whole = Histogram.compute(image)
        XCTAssertEqual(whole.red.bins[0], left.red.bins[0] + right.red.bins[0])
        XCTAssertEqual(whole.red.bins[255], left.red.bins[255] + right.red.bins[255])
    }

    // MARK: - 6. degenerate sizes

    func testSinglePixelAndEmptyRectAreWellDefined() {
        let one = solid(1, 1, rgb: 1)
        let h = Histogram.compute(one)
        XCTAssertEqual(h.sampleCount, 1)
        XCTAssertEqual(h.binCount, 256)
        XCTAssertEqual(h.red.bins[255], 1)
        XCTAssertEqual(h.red.clippedHigh, 1.0, accuracy: 1e-12)
        XCTAssertEqual(h.sampleFraction, 1.0, accuracy: 1e-12)

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

        // A one-pixel rect of a bigger picture still has its own bin.
        let single = Histogram.compute(solid(9, 9, rgb: 0.5),
                                       rect: ImageRect(x: 4, y: 4, width: 1, height: 1))
        XCTAssertEqual(single.sampleCount, 1)
        XCTAssertEqual(single.red.bins[expectedBin(0.5)], 1)
    }

    /// The sampling rule, without a GPU: aspect preserved, long edge ≤ 1024, never upsampled — and the
    /// scale that produces it is the same arithmetic in the other direction.
    func testSampleSizeRule() {
        XCTAssertEqual(Histogram.sampleSize(for: ImageRect(x: 0, y: 0, width: 600, height: 400)).keyString,
                       "600x400")
        XCTAssertEqual(Histogram.sampleSize(for: ImageRect(x: 0, y: 0, width: 1500, height: 2731)).keyString,
                       "562x1024")
        XCTAssertEqual(Histogram.sampleSize(for: ImageRect(x: 0, y: 0, width: 2731, height: 1500)).keyString,
                       "1024x562")
        XCTAssertEqual(Histogram.sampleSize(for: ImageRect(x: 0, y: 0, width: 1, height: 4000)).keyString,
                       "1x1024")
        XCTAssertEqual(Histogram.sampleScale(for: ImageSize(width: 600, height: 400)), 1)
        XCTAssertEqual(Histogram.sampleScale(for: ImageSize(width: 1500, height: 2731)),
                       1024.0 / 2731, accuracy: 1e-12)
    }

    // MARK: - 7. the measurement is of the picture, not of the frame

    /// **The acceptance claim.** One `measureHistogram` per document, and the camera cannot be an input
    /// to it: `measureHistogram` has no viewport, window or scale parameter at all. What this test can
    /// still check is that rendering frames at wildly different cameras in between changes nothing —
    /// the numbers are the same object-cached bins, and a *fresh* graph measuring the same edit agrees.
    func testTheMeasurementIgnoresTheCamera() throws {
        let w = 1500, h = 2731                           // 4.10 Mpx: the repo's reference frame
        let source = texturedImage(width: w, height: h)
        let graph = try makeGraph(source)

        let first = try graph.measureHistogram(.neutral)
        XCTAssertEqual(first.canvas, ImageSize(width: w, height: h))
        XCTAssertEqual(first.roi, ImageRect(x: 0, y: 0, width: w, height: h))
        XCTAssertEqual(first.sampleSize, Histogram.sampleSize(for: first.roi))
        XCTAssertEqual(first.sampleCount, first.sampleSize.pixelCount)
        XCTAssertEqual(first.sampleCount, 562 * 1024)

        // The cameras a user actually works through: fit, 1:1, 400 %, and a pan. Each is a full frame
        // render at a different window/scale — the frames the old code measured.
        let cameras: [RenderOptions] = [
            RenderOptions(canvas: ImageSize(width: 2560, height: 1600), scale: 0.58,
                          useCache: false, wantsPixels: false),
            RenderOptions(canvas: ImageSize(width: 2560, height: 1600), scale: 1,
                          outputWindow: ImageRect(x: 400, y: 900, width: 2560, height: 1600),
                          useCache: false, wantsPixels: false),
            RenderOptions(canvas: ImageSize(width: 2560, height: 1600), scale: 4,
                          outputWindow: ImageRect(x: 900, y: 1500, width: 640, height: 400),
                          useCache: false, wantsPixels: false),
            RenderOptions(canvas: ImageSize(width: 2560, height: 1600), scale: 1,
                          outputWindow: ImageRect(x: 1700, y: 200, width: 900, height: 700),
                          useCache: false, wantsPixels: false),
        ]
        var digests: [String] = [first.binsDigest()]
        for options in cameras {
            let frame = try graph.render(.neutral, options: options)
            if let texture = frame.output { graph.recycle(output: texture) }
            XCTAssertNil(frame.histogram, "a frame render must not measure anything")
            let again = try graph.measureHistogram(.neutral)
            digests.append(again.binsDigest())
            XCTAssertEqual(again.sampleCount, first.sampleCount)
        }
        XCTAssertEqual(Set(digests).count, 1, "the same edit produced \(Set(digests).count) histograms")
        print("histogram camera invariance: 4 cameras (fit / 1:1 / 4:1 / panned), "
              + "1 digest \(first.binsDigest().prefix(16))…, sampleCount \(first.sampleCount) at every one")

        // A second graph of the same source agrees too — the measurement is a function of the picture,
        // not of a graph's state.
        let other = try makeGraph(source, identity: "histogram-test-b")
        let fresh = try other.measureHistogram(.neutral)
        XCTAssertEqual(fresh.binsDigest(), first.binsDigest())
        XCTAssertEqual(fresh.sampleCount, first.sampleCount)
    }

    // MARK: - 8. the GPU path: the reduction's error, measured against a full-resolution recount

    func testThumbnailAgreesWithAFullResolutionRecount() throws {
        let w = 1200, h = 900                       // 1.08 Mpx; the thumbnail is 1024×768
        let graph = try makeGraph(smoothImage(width: w, height: h))

        let thumbnail = try graph.measureHistogram(.neutral)
        XCTAssertEqual(thumbnail.sampleCount, 1024 * 768)

        // The reference: the same picture, every pixel, measured pre-S4 by a full-scale render.
        var full = RenderOptions(scale: 1, useCache: false, wantsPixels: false, collectHistogram: true)
        full.histogramBins = 256
        let reference = try XCTUnwrap(try graph.render(.neutral, options: full).histogram)
        XCTAssertEqual(reference.sampleCount, w * h, "the reference must be every pixel")
        if let texture = try graph.render(.neutral, options: full).output { graph.recycle(output: texture) }

        var worstBin = 0.0
        var worstChannel = ""
        for name in Histogram.Channel.allCases {
            let a = fractions(thumbnail[name])
            let b = fractions(reference[name])
            for (i, (x, y)) in zip(a, b).enumerated() {
                if abs(x - y) > worstBin { worstBin = abs(x - y); worstChannel = "\(name)[\(i)]" }
            }
            let diff = zip(a, b).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThan(diff, 0.01,
                              "\(name): one bin moved \(String(format: "%.3f", diff * 100)) % of the "
                              + "pixels; the documented bound is 1 %")
            XCTAssertEqual(thumbnail[name].clippedHigh, reference[name].clippedHigh, accuracy: 0.01)
            XCTAssertEqual(thumbnail[name].clippedLow, reference[name].clippedLow, accuracy: 0.01)
            let tailDiff = zip(tailFractions(thumbnail[name]), tailFractions(reference[name]))
                .map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThan(tailDiff, 0.005)
        }
        print(String(format: "histogram reduction: %d px → %d px (%@), worst bin %@ %.4f %% of total "
                     + "(per-bin ±%.4f pp), clippedHigh Δ %.4f",
                     w * h, thumbnail.sampleCount, thumbnail.sampleSize.keyString,
                     worstChannel, worstBin * 100, worstBin * 100,
                     abs(thumbnail.luma.clippedHigh - reference.luma.clippedHigh)))
    }

    // MARK: - 9. off means off, and a frame never measures

    func testPixelsAndKeysAreIdenticalWithAndWithout() throws {
        let graph = try makeGraph(texturedImage(width: 640, height: 480))

        let off = try graph.render(.neutral, options: RenderOptions(scale: 1, useCache: false,
                                                                   wantsPixels: true))
        var on = RenderOptions(scale: 1, useCache: false, wantsPixels: true)
        on.collectHistogram = true
        let onResult = try graph.render(.neutral, options: on)

        XCTAssertNil(off.histogram, "the default must not measure anything")
        XCTAssertNotNil(onResult.histogram, "the flag is what makes a render measure")

        let a = try XCTUnwrap(off.display), b = try XCTUnwrap(onResult.display)
        XCTAssertEqual(a.sha256(), b.sha256(), "measuring must not touch a pixel")
        XCTAssertEqual(off.canvas, onResult.canvas)
        XCTAssertEqual(off.keys, onResult.keys, "the histogram is a measurement, not document state")
        XCTAssertEqual(off.trace.executed, onResult.trace.executed,
                       "no stage may appear because a histogram was asked for")
    }

    /// The card's numbers never come from a frame: `measureHistogram` is the only shipped path, and it
    /// is a render of its own. This is the property the whole of A rests on.
    func testTheShippedPathIsItsOwnRender() throws {
        let graph = try makeGraph(texturedImage(width: 900, height: 700))
        let measured = try graph.measureHistogram(.neutral)
        XCTAssertEqual(measured.sampleCount, Histogram.sampleSize(for: measured.roi).pixelCount)

        // A frame of the same picture — the window the camera would show — is not the measurement.
        let frame = try graph.render(.neutral, options: RenderOptions(
            canvas: ImageSize(width: 900, height: 700), scale: 1,
            outputWindow: ImageRect(x: 100, y: 50, width: 600, height: 500),
            useCache: false, wantsPixels: false))
        XCTAssertNil(frame.histogram)
        if let texture = frame.output { graph.recycle(output: texture) }
        XCTAssertEqual(try graph.measureHistogram(.neutral).binsDigest(), measured.binsDigest())
    }

    /// The cost of the measurement, printed. One thumbnail render plus one readback plus the CPU
    /// binning of ~0.58 Mpx — and it is a *separate* render, so a pan pays nothing.
    func testTheMeasurementCostsOneThumbnailRender() throws {
        let graph = try makeGraph(texturedImage(width: 1500, height: 2731))
        _ = try graph.measureHistogram(.neutral)          // warm: pipeline, pool, source upload
        var times: [Double] = []
        for _ in 0..<6 {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = try graph.measureHistogram(.neutral)
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        let sorted = times.sorted()
        let p50 = sorted[sorted.count / 2]
        print(String(format: "histogram measurement (4.10 Mpx picture → %d px thumbnail): "
                     + "p50 %.2f ms / min %.2f / max %.2f", 562 * 1024, p50, sorted.first ?? 0,
                     sorted.last ?? 0))
        XCTAssertLessThan(p50, 500, "a thumbnail render plus 0.58 Mpx of counting is not a second export")
    }

    // MARK: - 10. the exponential tail (6 stops × 1/16 stop)

    /// The sRGB OETF, written out here rather than called from `Histogram`: a test that builds its
    /// input with the very helper it is checking proves only that the helper is self-consistent.
    private func encode(_ linear: Float) -> Float {
        linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1.0 / 2.4) - 0.055
    }

    /// The centre of tail bin `k` as a display code: 1/16 stop apart, and a stop is a **doubling of
    /// light**, not of code.
    private func codeAtBinCentre(_ k: Int) -> Float {
        encode(Float(pow(2.0, (Double(k) + 0.5) / 16.0)))
    }

    /// One pixel per tail bin, each at its bin's centre: the bins are 1/16 stop apart, there are 96 of
    /// them, and the ones chosen are spread over all 6 stops so a wrong scale cannot pass by luck.
    func testTailBinsAreSixteenthOfAStopApart() {
        let bins = [0, 1, 7, 8, 15, 16, 31, 32, 63, 64, 95]
        let w = bins.count, h = 1
        var rgba = [Float16](repeating: 1, count: w * h * 4)
        for (i, k) in bins.enumerated() {
            let v = Float16(codeAtBinCentre(k))
            rgba[i * 4] = v
            rgba[i * 4 + 1] = v
            rgba[i * 4 + 2] = v
        }
        let hist = Histogram.compute(display(rgba, w, h))
        XCTAssertEqual(Histogram.maxStops, 6)
        XCTAssertEqual(Histogram.hdrBinsPerStop, 16)
        XCTAssertEqual(hist.hdrBinCount, 96)
        XCTAssertEqual(hist.red.hdrBins.count, hist.hdrBinCount)
        for k in bins {
            XCTAssertEqual(hist.red.hdrBins[k], 1,
                           "bin \(k) must hold exactly the pixel placed at \(codeAtBinCentre(k))")
        }
        XCTAssertEqual(hist.red.hdrBins.reduce(0, +), bins.count)
        XCTAssertEqual(hist.red.bins.reduce(0, +), 0, "nothing above white belongs on the code axis")
        XCTAssertEqual(hist.red.total, hist.sampleCount, "total counts both segments")
        XCTAssertEqual(hist.red.hdrTotal, bins.count)
    }

    /// 6.5 stops is past `maxStops`, so it piles onto the last bin (`"6 stops or more"`) instead of
    /// running off the plot.
    func testTailClampsAtSixStops() {
        let h = Histogram.compute(solid(2, 2, rgb: encode(Float(pow(2.0, 6.5)))))
        XCTAssertEqual(h.red.hdrBins[95], 4)
        XCTAssertEqual(h.red.hdrBins.reduce(0, +), 4)
        XCTAssertEqual(h.red.clippedHigh, 1.0, accuracy: 1e-12)
    }

    /// White itself stays on the code axis (last SDR bin); a hair above it is tail bin 0. This is the
    /// seam the card draws as the SDR/tail boundary, so it has to be exact.
    func testWhiteIsTheLastSDRBinAndAHairAboveItIsTailBinZero() {
        let white = Histogram.compute(solid(1, 1, rgb: 1))
        XCTAssertEqual(white.red.bins[255], 1)
        XCTAssertEqual(white.red.hdrTotal, 0)

        let barely = Histogram.compute(solid(1, 1, rgb: encode(Float(pow(2.0, 1.0 / 64.0)))))
        XCTAssertEqual(barely.red.hdrBins[0], 1)
        XCTAssertEqual(barely.red.bins.reduce(0, +), 0)
    }

    /// 削顶 is "the ceiling of the screen this measurement was taken for", which is a *derived* number
    /// now: the bins are of the picture, and this is how much of it that screen would throw away.
    func testClippedCeilingIsTheScreensLossNotThePictures() {
        let inside = Histogram.compute(solid(2, 2, rgb: encode(1.9)), headroom: 2)
        XCTAssertEqual(inside.red.clippedHigh, 1.0, accuracy: 1e-12, "above white")
        XCTAssertEqual(inside.red.clippedCeiling, 0.0, accuracy: 1e-12, "but inside the ceiling")

        let atCeiling = Histogram.compute(solid(2, 2, rgb: encode(2.0)), headroom: 2)
        XCTAssertEqual(atCeiling.red.clippedCeiling, 1.0, accuracy: 1e-12)
        XCTAssertEqual(atCeiling.red.clippedHigh, 1.0, accuracy: 1e-12)
    }

    /// **The acceptance claim of B**, on the CPU: the bins do not know what screen this is. An SDR and a
    /// 1.2× measurement of the same picture agree on every SDR bin *and* every tail bin; only the
    /// ceiling ratio moves. And the SDR one still sees light above white.
    func testHeadroomMovesOnlyTheCeilingRatio() {
        let image = solidLinear(8, 4, rgb: 4.0)          // 2 stops above white, everywhere
        let sdr = Histogram.compute(image, headroom: 1)
        let edr = Histogram.compute(image, headroom: 1.2)
        XCTAssertEqual(sdr.red.bins, edr.red.bins)
        XCTAssertEqual(sdr.red.hdrBins, edr.red.hdrBins)
        XCTAssertGreaterThan(sdr.red.hdrTotal, 0, "an SDR screen must still see light above white")
        XCTAssertEqual(sdr.red.hdrTotal, 32)
        // 2 stops = bin 32 of 1/16 stop.
        XCTAssertEqual(sdr.red.hdrBins[32], 32)
        XCTAssertEqual(sdr.red.clippedHigh, 1.0, accuracy: 1e-12)
        XCTAssertEqual(sdr.red.clippedCeiling, 1.0, accuracy: 1e-12, "headroom 1: white is the ceiling")
        XCTAssertEqual(edr.red.clippedCeiling, 1.0, accuracy: 1e-12, "4.0 > 1.2 too")
    }

    /// The same claim through the graph, on a real picture with a hot band: `headroom` changes nothing
    /// but `clippedCeiling`, and the SDR measurement has a non-zero tail.
    func testAnSDRMeasurementSeesTheHighlightThatAnSDRScreenWouldLose() throws {
        let graph = try makeGraph(hotImage(width: 1200, height: 900))
        let sdr = try graph.measureHistogram(.neutral, headroom: 1)
        let edr = try graph.measureHistogram(.neutral, headroom: 1.2)

        XCTAssertGreaterThan(sdr.luma.hdrTotal, 0, "headroom = 1 must still count the tail")
        XCTAssertEqual(sdr.red.bins, edr.red.bins, "the 256 SDR bins are screen-independent")
        XCTAssertEqual(sdr.red.hdrBins, edr.red.hdrBins, "and so is the 96-bin tail")
        XCTAssertEqual(sdr.binsDigest(), edr.binsDigest())
        XCTAssertEqual(sdr.headroom, 1, accuracy: 1e-12)
        XCTAssertEqual(edr.headroom, 1.2, accuracy: 1e-12)

        // The tail's first 8 bins, printed: the acceptance number for C.
        let head = (0..<8).map { "\(sdr.luma.hdrBins[$0])" }.joined(separator: " / ")
        print("histogram tail, luma, bins 0…7 of 96: \(head) · hdrTotal \(sdr.luma.hdrTotal) of "
              + "\(sdr.luma.total) samples · clippedHigh(R) \(String(format: "%.4f", sdr.red.clippedHigh))")
        print("histogram ceiling, same picture: SDR clippedCeiling(R) "
              + "\(String(format: "%.4f", sdr.red.clippedCeiling)) vs 1.2× "
              + "\(String(format: "%.4f", edr.red.clippedCeiling)); bins identical")
        XCTAssertGreaterThan(sdr.red.hdrTotal, 0)
        XCTAssertNotEqual(sdr.red.clippedCeiling, edr.red.clippedCeiling, accuracy: 0.0,
                          "1.2× keeps some of the light an SDR panel loses")
    }

    /// The ceiling travels with the measurement, so the card's tick can never describe a different
    /// screen than the numbers next to it.
    func testTheCeilingTravelsWithTheMeasurement() {
        let h = Histogram.compute(solid(2, 2, rgb: 0.5), headroom: 1.695)
        XCTAssertEqual(h.headroom, 1.695, accuracy: 1e-12)
        XCTAssertEqual(h.displayStops, log2(1.695), accuracy: 1e-12)
        XCTAssertEqual(h.displayStops, 0.7614, accuracy: 1e-3)
    }

    /// The cache key is the claim, written down: nothing about a camera, a viewport or a display.
    func testTheCacheKeyNamesThePictureAndTheDocument() {
        let a = Histogram.cacheKey(rungIdentity: "photo-s1.0", editDigest: "deadbeefcafe0001", bins: 256)
        XCTAssertEqual(a, "hist|v1|photo-s1.0|deadbeefcafe0001|256")
        let b = Histogram.cacheKey(rungIdentity: "photo-s1.0", editDigest: "deadbeefcafe0002", bins: 256)
        XCTAssertNotEqual(a, b, "an edit must mint a new key")
        XCTAssertFalse(a.contains("2560"), "no viewport in the key")
        XCTAssertFalse(a.contains("headroom"), "no panel in the key")

        // The digest is stable across processes (SHA-256 of sorted-key JSON), not a seeded hash.
        let edit = EditModel.neutral
        XCTAssertEqual(Histogram.editDigest(edit), Histogram.editDigest(edit))
        XCTAssertEqual(Histogram.editDigest(edit).count, 16)
        var brighter = edit.light
        brighter.exposure = edit.light.exposure + 0.25
        var edited = edit
        edited.light = brighter
        XCTAssertNotEqual(Histogram.editDigest(edit), Histogram.editDigest(edited))
    }
}
