import Foundation
import Metal

// MARK: - what a histogram is here
//
// A histogram is a *display-encoded* measurement: the numbers below are the values S4 wrote — the
// sRGB/P3 transfer already applied, 0…1 for an SDR output (and up to `srgb_encode(headroom)` for an
// EDR one). It is deliberately **not** scene-linear luma: the question a histogram answers is
// "how many pixels did the file/panel get at code value k", and the answer must be the codes.
//
// **The x axis is SDR + a 4-stop exponential tail** (2026-10-26). Two segments, one measurement:
//
//   · `0 … 1` (display white) on `binCount` **uniform code** bins — unchanged from 005f, so an SDR
//     screen sees exactly the histogram it always saw.
//   · above white on `maxStops × hdrBinsPerStop` bins that are uniform in **stops of linear
//     light**: bin k covers scene-linear `[2^(k/8), 2^((k+1)/8))`, i.e. 1/8 stop per bin, 4 stops
//     total (`hdrBins`).
//
// Why stops of *linear* light and not "the code value doubles": S4 clamps in linear
// (`min(v, headroom)`, §11.8), the headroom it is handed is a linear multiple of SDR white, and a
// photographer's stop is a doubling of light. One stop of *code* is 2.4 stops of light (the sRGB
// OETF is ~γ2.4 above white), so a code-doubling axis would lie by that factor and the display
// ceiling marker could not be placed without a second, contradicting scale.
//
// Why 4 stops: `DisplayHeadroom.maximumHeadroom` is 16 = 2^4, so no screen this app can drive puts
// a value past the last bin — the tail is a fixed 4 stops for every display, and `hdrBins.last`
// means "4 stops or more".
//
// **The measured region is the picture, not the canvas** (2026-10-26): `RenderGraph`'s default ROI is
// `plan.origin + plan.content`, so a `fit` frame's matte bars are not counted as black pixels. At 1:1
// the picture that exists *is* the window, so the numbers are of the window — a photo-wide reading at
// every zoom would be a second render, not a different ROI.
//
// Two consequences worth writing down rather than discovering later:
//
//   · `binCount` is the *measurement's* resolution, not the file's. The default 256 matches an
//     8-bit output; a 16-bit export that wants per-code counts would ask for 65536 bins (4 × 256 KB
//     of counters here, so that is a caller's decision, not a default).
//   · The four series are R, G, B and **luma** with Rec.709 weights applied to the encoded values
//     (0.2126, 0.7152, 0.0722). That is the same number a compositor would call luma; scene
//     luminance is a different quantity and `LinearImage.statistics()` is where it lives.

/// One channel's distribution plus the three ratios that make it actionable.
public struct HistogramChannel: Sendable, Equatable {
    /// `bins[k]` = number of sampled pixels whose code fell in `[k/binCount, (k+1)/binCount)`.
    public let bins: [Int]
    /// `hdrBins[k]` = samples 1/8 stop apart above display white — see the file header. Empty when a
    /// caller built the value by hand; the measurement always fills it.
    public let hdrBins: [Int]
    /// Fraction of sampled pixels **above** `Histogram.clipHighThreshold` (0.999), i.e. above SDR
    /// white. On an EDR screen this is *not* lost detail any more — it is what the panel's extra
    /// range is for — which is why `clippedCeiling` exists next to it.
    ///
    /// A clipped sample is still counted in `bins` — its last bin — because "the distribution ends
    /// at white" and "white was hit" are different facts and a caller needs both.
    public let clippedHigh: Double
    /// Fraction of sampled pixels **at the display ceiling** — S4's own clamp, so this is detail that
    /// was actually lost. With `headroom = 1` it coincides with `clippedHigh`.
    public let clippedCeiling: Double
    /// Fraction of sampled pixels **below** `Histogram.clipLowThreshold` (0.001).
    public let clippedLow: Double

    public init(bins: [Int], hdrBins: [Int] = [], clippedHigh: Double, clippedCeiling: Double = 0,
                clippedLow: Double) {
        self.bins = bins
        self.hdrBins = hdrBins
        self.clippedHigh = clippedHigh
        self.clippedCeiling = clippedCeiling
        self.clippedLow = clippedLow
    }

    /// Every sample this channel counted: the SDR bins **and** the tail.
    public var total: Int { bins.reduce(0, +) + hdrBins.reduce(0, +) }

    /// Samples that landed above white (the tail's own subtotal).
    public var hdrTotal: Int { hdrBins.reduce(0, +) }

    /// The bin with the most samples (`nil` for an empty channel — an empty ROI has no peak).
    public var peakBin: Int? {
        guard total > 0 else { return nil }
        return bins.indices.max { bins[$0] < bins[$1] }
    }
}

/// Four channels, the region they were measured over, and the grid they were measured on.
public struct Histogram: Sendable, Equatable {
    /// What counts as clipped. Display-encoded white is exactly 1.0, so 0.999 admits one 8-bit code
    /// below it; the low side is symmetric (0.001 is the second code above black at 8 bits).
    public static let clipHighThreshold: Double = 0.999
    public static let clipLowThreshold: Double = 0.001
    /// Rec.709 weights, applied to encoded values — see the note at the top of this file.
    public static let lumaWeights: (r: Double, g: Double, b: Double) = (0.2126, 0.7152, 0.0722)

    /// Bins per channel on the SDR segment.
    public let binCount: Int
    /// Bins per channel on the exponential tail: `maxStops × hdrBinsPerStop` (32 today).
    public var hdrBinCount: Int { Histogram.hdrBinCount }
    /// Pixels counted: the sample grid's pixel count (the ROI clipped to the frame, downsampled).
    public let sampleCount: Int
    /// The render's output size the ROI is expressed in.
    public let canvas: ImageSize
    /// The region measured, in canvas pixels: the picture, not the letterbox around it.
    public let roi: ImageRect
    /// The grid the samples came from (long edge ≤ `maxLongEdge`).
    public let sampleSize: ImageSize
    /// Output primaries the samples are in — the same codes the export would carry.
    public let primaries: OutputPrimaries
    /// The S4 clamp (`DisplayOptions.headroom`) this frame was measured with, in **linear** scene
    /// units where 1 is SDR white. Travels with the measurement on purpose: the card's ceiling tick
    /// then describes the frame it drew, not whatever screen the window is on by the time it
    /// redraws.
    public let headroom: Double

    public let red: HistogramChannel
    public let green: HistogramChannel
    public let blue: HistogramChannel
    public let luma: HistogramChannel

    public init(binCount: Int, sampleCount: Int, canvas: ImageSize, roi: ImageRect,
                sampleSize: ImageSize, primaries: OutputPrimaries, headroom: Double = 1,
                red: HistogramChannel, green: HistogramChannel, blue: HistogramChannel,
                luma: HistogramChannel) {
        self.binCount = binCount
        self.sampleCount = sampleCount
        self.canvas = canvas
        self.roi = roi
        self.sampleSize = sampleSize
        self.primaries = primaries
        self.headroom = headroom
        self.red = red
        self.green = green
        self.blue = blue
        self.luma = luma
    }

    /// Stops above white this measurement can hold. Fixed at 4 for every display: see the file
    /// header (16 = 2^4 is the largest headroom the app will ever hand S4).
    public static let maxStops = 4
    /// Tail resolution. 8 bins per stop is 1/8 stop ≈ 9 % of light per bin — fine enough to see a
    /// highlight roll-off, coarse enough that a 30 pt-per-stop card draws it without resampling.
    public static let hdrBinsPerStop = 8
    public static var hdrBinCount: Int { maxStops * hdrBinsPerStop }

    /// Where the display ceiling sits on the tail, in stops above white (`0` for an SDR screen).
    public var displayStops: Double { log2(max(headroom, 1)) }

    /// How many times this process compiled the histogram's downsample kernel. One, ever.
    ///
    /// It exists so the acceptance test can assert "once per process" as a **fact** instead of
    /// inferring it from a frame time: a ±2 ms budget on a ~130 ms debug-build measurement is noise
    /// (measured 151 vs 154 ms between two graphs doing identical work), while a counter cannot be
    /// talked out of the answer.
    public internal(set) nonisolated(unsafe) static var kernelCompileCount = 0

    /// Where SDR white sits on the combined axis, as a fraction of it: the split a card draws.
    public var sdrFraction: Double {
        Double(binCount) / Double(binCount + hdrBinCount)
    }

    public var channels: [HistogramChannel] { [red, green, blue, luma] }

    /// The channel with a name, for the CLI and for tests that want to iterate.
    public subscript(channel: Channel) -> HistogramChannel {
        switch channel {
        case .red: return red
        case .green: return green
        case .blue: return blue
        case .luma: return luma
        }
    }

    public enum Channel: String, CaseIterable, Sendable {
        case red, green, blue, luma
    }

    /// The sample grid as a fraction of the ROI it stands for — the honest denominator for "how
    /// much of the picture did this measurement actually see".
    public var sampleFraction: Double {
        let roiPixels = roi.area
        guard roiPixels > 0 else { return 0 }
        return Double(sampleCount) / Double(roiPixels)
    }
}

// MARK: - downsampling rule

extension Histogram {
    /// Longest edge of the grid a histogram is measured on.
    ///
    /// Why 1024 rather than the frame: at 4.10 Mpx (1500×2731) the grid is 562×1024 = 0.58 Mpx, so
    /// the single readback is 4.6 MB of half float instead of 32 MB, and the CPU walks 14 % of the
    /// pixels instead of all of them. The error this buys is quantified in `sampleSize(for:)`'s
    /// sibling note below and measured in `HistogramTests`.
    public static let maxLongEdge = 1024

    /// The grid a `roi` is reduced to: the same aspect, long edge ≤ 1024, never upsampled.
    ///
    /// **The error this introduces, in full.** A destination texel is the *mean* of the source
    /// rectangle it covers (`r_x × r_y` pixels, `r ≈ longEdge/1024`, i.e. 2.7 × 2.7 at 4.10 Mpx).
    /// Two things follow:
    ///
    ///   1. **Bin counts.** The sample is a 0.58 Mpx estimate of a 4.10 Mpx distribution. If the
    ///      pixels were independent, the per-bin fractional error would be bounded by
    ///      `0.5/√N ≈ 0.07 pp` at N = 0.58 M (a binomial two-sigma figure); in practice pictures
    ///      are spatially correlated, so the *structural* term dominates: a feature smaller than
    ///      one source rectangle (≈ 2.7 × 2.7 px) is averaged into its neighbours, which moves at
    ///      most the mass of those features. For smooth and mid-frequency content this is far below
    ///      the 1 % bound `HistogramTests.testDownsamplingKeepsBinCountsWithinOnePercent` asserts;
    ///      for 1-px-wide detail (a resolution chart, dithered noise) the histogram of a downsample
    ///      is genuinely the histogram of an *average*, and no bound smaller than the local contrast
    ///      exists.
    ///   2. **Clipping ratios.** Averaging is what clipping measurement cannot survive at the
    ///      extreme: a specular highlight or a 1-px rim that is (1,1,1) inside a footprint whose
    ///      mean is 0.99 stops counting as clipped. So the ratio is exact for regions larger than
    ///      ~3 × 3 source pixels and *under*-reports the finest clipped detail. That under-report is
    ///      the price of a single 4.6 MB readback instead of a 32 MB one, and it is the reason the
    ///      ratio is documented as "fraction of the sample", not "fraction of the picture".
    public static func sampleSize(for roi: ImageRect) -> ImageSize {
        let long = max(roi.width, roi.height)
        guard long > maxLongEdge else {
            return ImageSize(width: max(1, roi.width), height: max(1, roi.height))
        }
        let s = Double(maxLongEdge) / Double(long)
        return ImageSize(width: max(1, Int((Double(roi.width) * s).rounded())),
                         height: max(1, Int((Double(roi.height) * s).rounded())))
    }
}

// MARK: - the measurement itself

extension Histogram {
    /// Measure display-encoded pixels. Pure CPU: no Metal, no I/O, so the arithmetic is testable
    /// against a hand-built `DisplayImage` and the GPU side (`HistogramGather`) only has to be
    /// trusted as far as "it averaged a rectangle".
    ///
    /// `rect` is in image pixels and defaults to the whole image; the returned histogram's `canvas`
    /// is the image's own size, i.e. the frame the rect was expressed in. A caller measuring a
    /// *reduced* sample (the render path) re-labels the result with `relabelled(canvas:roi:)` so the
    /// numbers are the sample's and the region they stand for is the caller's.
    public static func compute(_ image: DisplayImage, bins: Int = 256,
                               rect: ImageRect? = nil, headroom: Double = 1) -> Histogram {
        let binCount = min(max(bins, 2), 1 << 16)
        let hdrCount = hdrBinCount
        let stride = binCount + hdrCount
        let frame = ImageSize(width: image.width, height: image.height)
        if let rect, rect.isEmpty {
            return Histogram.empty(bins: binCount, canvas: frame, roi: rect,
                                   primaries: image.primaries, headroom: headroom)
        }
        let rect = (rect ?? ImageRect(x: 0, y: 0, width: frame.width, height: frame.height))
            .clamped(in: frame)

        let high = Float(clipHighThreshold)
        let low = Float(clipLowThreshold)
        let (wr, wg, wb) = (Float(lumaWeights.r), Float(lumaWeights.g), Float(lumaWeights.b))
        // The ceiling is S4's own clamp, read back in code: a pixel S4 clamped carries exactly
        // `srgbEncode(headroom)`. The comparison is slack by half a float16 step (2^-11 relative) —
        // that is the quantisation of the texture the samples came from, and without the slack a
        // pixel clamped *at* the ceiling could land one ULP below it and never be counted.
        let ceilingFloor = srgbEncode(Float(max(headroom, 1))) * (1 - 1.0 / 2048)

        // One flat counter block indexed through a raw pointer: per channel
        // `SDR bins | HDR bins`, then 12 scalars `hiR hiG hiB hiL · ceilR ceilG ceilB ceilL ·
        // loR loG loB loL`. The pointer matters because an `Array` subscript per increment pays an
        // exclusivity check on every one of a million pixels — 306 ms for 0.79 Mpx in a debug build,
        // against 83 ms for 0.58 Mpx with this block. In a **release** build the same loop is 4.7 ms
        // for 0.58 Mpx, and the split is worth knowing: 3.2 ms is the four scatter increments and
        // 1.5 ms the eight clipping predicates (measured by removing each in turn). The exponential
        // tail adds work **only for pixels above white** (one `pow` + one `log2` each), so an SDR
        // frame pays the four extra ceiling comparisons and nothing else. That is what counting on
        // the CPU costs; `Histogram.maxLongEdge` is what keeps the number of pixels this block ever
        // sees at ~0.5 M rather than 60 M.
        let statsBase = 4 * stride
        var counts = [Int](repeating: 0, count: 4 * stride + 12)
        let scale = Float(binCount)

        image.rgba.withUnsafeBufferPointer { px in
            counts.withUnsafeMutableBufferPointer { c in
                let base = c.baseAddress!
                let g0 = stride, b0 = 2 * stride, l0 = 3 * stride
                // The twelve counters are locals of this closure rather than captures, so they can
                // stay in registers while the bins are being incremented.
                var hiR = 0, hiG = 0, hiB = 0, hiL = 0
                var ceR = 0, ceG = 0, ceB = 0, ceL = 0
                var loR = 0, loG = 0, loB = 0, loL = 0
                for y in rect.y..<(rect.y + rect.height) {
                    let row = y * frame.width
                    for x in rect.x..<(rect.x + rect.width) {
                        let o = (row + x) * 4
                        let rv = unbounded(px[o])
                        let gv = unbounded(px[o + 1])
                        let bv = unbounded(px[o + 2])
                        let lv = wr * rv + wg * gv + wb * bv

                        base[combinedIndex(rv, sdrBins: binCount, scale: scale)] += 1
                        base[g0 + combinedIndex(gv, sdrBins: binCount, scale: scale)] += 1
                        base[b0 + combinedIndex(bv, sdrBins: binCount, scale: scale)] += 1
                        base[l0 + combinedIndex(lv, sdrBins: binCount, scale: scale)] += 1

                        // Clipping is counted in the same pass, from the same values, so the ratios
                        // and the bins can never describe two different samples.
                        if rv > high { hiR += 1 }
                        if gv > high { hiG += 1 }
                        if bv > high { hiB += 1 }
                        if lv > high { hiL += 1 }
                        if rv >= ceilingFloor { ceR += 1 }
                        if gv >= ceilingFloor { ceG += 1 }
                        if bv >= ceilingFloor { ceB += 1 }
                        if lv >= ceilingFloor { ceL += 1 }
                        if rv < low { loR += 1 }
                        if gv < low { loG += 1 }
                        if bv < low { loB += 1 }
                        if lv < low { loL += 1 }
                    }
                }
                base[statsBase] = hiR
                base[statsBase + 1] = hiG
                base[statsBase + 2] = hiB
                base[statsBase + 3] = hiL
                base[statsBase + 4] = ceR
                base[statsBase + 5] = ceG
                base[statsBase + 6] = ceB
                base[statsBase + 7] = ceL
                base[statsBase + 8] = loR
                base[statsBase + 9] = loG
                base[statsBase + 10] = loB
                base[statsBase + 11] = loL
            }
        }

        // The sample's pixel count is the red series' own total: one invariant instead of a second
        // counter that could (silently) disagree with the bins.
        let counted = counts[0..<stride].reduce(0, +)
        let n = Double(max(counted, 1))
        func channel(_ offset: Int, _ hiIndex: Int, _ ceilIndex: Int,
                     _ loIndex: Int) -> HistogramChannel {
            HistogramChannel(bins: Array(counts[offset..<(offset + binCount)]),
                             hdrBins: Array(counts[(offset + binCount)..<(offset + stride)]),
                             clippedHigh: Double(counts[hiIndex]) / n,
                             clippedCeiling: Double(counts[ceilIndex]) / n,
                             clippedLow: Double(counts[loIndex]) / n)
        }
        return Histogram(binCount: binCount, sampleCount: counted, canvas: frame,
                         roi: rect, sampleSize: frame, primaries: image.primaries,
                         headroom: headroom,
                         red: channel(0, statsBase, statsBase + 4, statsBase + 8),
                         green: channel(stride, statsBase + 1, statsBase + 5, statsBase + 9),
                         blue: channel(2 * stride, statsBase + 2, statsBase + 6, statsBase + 10),
                         luma: channel(3 * stride, statsBase + 3, statsBase + 7, statsBase + 11))
    }

    /// The same counts, described by the frame they were taken from.
    ///
    /// The render path measures a *reduced* sample (≤ 1024 long edge), so `compute` reports the
    /// sample's own size as both canvas and ROI — true, and useless: what a caller asked about is the
    /// ROI in canvas pixels. Re-labelling keeps the arithmetic untouched and makes `roi.area` the
    /// denominator `sampleFraction` divides by, so "we counted 14 % of the pixels you asked about" is
    /// a number the caller can check.
    public func relabelled(canvas: ImageSize, roi: ImageRect) -> Histogram {
        Histogram(binCount: binCount, sampleCount: sampleCount, canvas: canvas, roi: roi,
                  sampleSize: sampleSize, primaries: primaries, headroom: headroom,
                  red: red, green: green, blue: blue, luma: luma)
    }

    /// Nothing measured: an empty ROI, or a render that could not produce a sample. Ratios are 0,
    /// not NaN, so a UI can print it without a special case.
    public static func empty(bins: Int = 256, canvas: ImageSize, roi: ImageRect,
                             primaries: OutputPrimaries = .sRGB,
                             headroom: Double = 1) -> Histogram {
        let binCount = min(max(bins, 2), 1 << 16)
        let zero = HistogramChannel(bins: [Int](repeating: 0, count: binCount),
                                    hdrBins: [Int](repeating: 0, count: hdrBinCount),
                                    clippedHigh: 0, clippedCeiling: 0, clippedLow: 0)
        return Histogram(binCount: binCount, sampleCount: 0, canvas: canvas, roi: roi,
                         sampleSize: ImageSize(width: 1, height: 1), primaries: primaries,
                         headroom: headroom,
                         red: zero, green: zero, blue: zero, luma: zero)
    }

    /// A half-float sample as a number. `Float(Float16)` is one instruction on arm64; the only case
    /// that needs care is a value `binIndex` cannot convert, and that is handled there (NaN and ±∞
    /// clamp into the end bins instead of trapping in `Int(_:)`).
    @inline(__always)
    private static func unbounded(_ h: Float16) -> Float {
        Float(h)
    }

    /// `floor(v · bins)` clamped into `[0, bins-1]`, with **no** `Int(Float)` conversion for values a
    /// conversion cannot represent: NaN lands on black, +∞ on white, −∞ on black. The comparison form
    /// is deliberate — `Int(nan)` traps, and a curve that produces a NaN must degrade to a wrong bin,
    /// not to a crash.
    @inline(__always)
    private static func binIndex(_ v: Float, _ scale: Float, _ binCount: Int) -> Int {
        let scaled = v * scale
        if scaled >= scale { return binCount - 1 }
        if !(scaled > 0) { return 0 }
        return Int(scaled)
    }

    /// The index in the combined `SDR bins | HDR bins` block: white and below on the code axis, above
    /// it on the exponential tail.
    @inline(__always)
    private static func combinedIndex(_ v: Float, sdrBins: Int, scale: Float) -> Int {
        if v > 1 { return sdrBins + hdrBinIndex(v) }
        return binIndex(v, scale, sdrBins)
    }

    /// Which 1/8-stop bin a code above white belongs to.
    ///
    /// The decode is only ever reached for `v > 1`, so it is the linear branch of the sRGB inverse —
    /// `pow` once per above-white sample, which for a normal photograph is a fraction of a percent of
    /// the samples and for a clipped frame is a few hundred thousand of them (0.58 Mpx worst case,
    /// still well inside the 16.7 ms budget).
    ///
    /// Degradation rules, same discipline as `binIndex`: `+∞` and anything past 4 stops land on the
    /// last bin (`"4 stops or more"`), and NaN — which cannot be above white and therefore cannot get
    /// here — would too, rather than trapping in `Int(_:)`.
    @inline(__always)
    private static func hdrBinIndex(_ v: Float) -> Int {
        let limit = Float(hdrBinCount)
        let linear = srgbDecode(v)
        let scaled = log2(linear) * Float(hdrBinsPerStop)
        if !(scaled < limit) { return hdrBinCount - 1 }
        if !(scaled > 0) { return 0 }
        return Int(scaled)
    }

    /// `1.055·v^(1/2.4) − 0.055` above the knee — the same function `s4_display` writes, so the
    /// ceiling comparison is in the same code space as the samples.
    @inline(__always)
    static func srgbEncode(_ v: Float) -> Float {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    /// Its inverse. Total (no trap) for every finite input; negatives mirror, which the counters
    /// ignore anyway.
    @inline(__always)
    static func srgbDecode(_ v: Float) -> Float {
        let a = abs(v)
        let d = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return v < 0 ? -d : d
    }
}

// MARK: - the GPU side: one downsample dispatch

/// The only GPU code a histogram needs: reduce the display-encoded frame (or the ROI inside it) to a
/// grid of at most 1024 × 1024 box averages.
///
/// Why a shader and not a mip chain: `generateMipmaps` halves the size, so a 1500×2731 frame would
/// land on 682 (level 2) — a third less data than asked for and a different grid for every size,
/// which is exactly the kind of "it depends on the frame" number a histogram must not have. A box
/// average to a fixed long edge keeps the sample grid a function of the ROI alone.
///
/// Why not a full-resolution readback and a CPU reduce: 60 MP is 480 MB of half float and a per-pixel
/// loop in Swift; the point of this file is that the CPU sees 0.3–1 Mpx.
///
/// The source is compiled at runtime from the string below, the same way `KernelLibrary` compiles the
/// shipped `.metal` files (no Metal toolchain, no build step, one `makeLibrary` per process).
enum HistogramGather {
    /// Mirror of `struct HistogramDownsampleParams` in `HISTOGRAM_METAL` — three `uint2`s, stride 24.
    struct Params {
        var origin: SIMD2<UInt32>
        var size: SIMD2<UInt32>
        var target: SIMD2<UInt32>
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct HistogramDownsampleParams {
        uint2 origin;   // ROI origin in source pixels
        uint2 size;     // ROI size in source pixels
        uint2 target;   // destination grid
    };

    // One thread per destination texel; the source rectangle it owns is the half-open interval
    // [gid * size / target, (gid+1) * size / target), so the whole ROI is covered exactly once and
    // the partition does not depend on the thread count.
    kernel void photons_histogram_downsample(texture2d<float, access::read> src [[texture(0)]],
                                             texture2d<float, access::write> dst [[texture(1)]],
                                             constant HistogramDownsampleParams &p [[buffer(0)]],
                                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.target.x || gid.y >= p.target.y) return;

        uint x0 = p.origin.x + uint((uint64_t(gid.x)     * uint64_t(p.size.x)) / uint64_t(p.target.x));
        uint x1 = p.origin.x + uint((uint64_t(gid.x + 1) * uint64_t(p.size.x)) / uint64_t(p.target.x));
        uint y0 = p.origin.y + uint((uint64_t(gid.y)     * uint64_t(p.size.y)) / uint64_t(p.target.y));
        uint y1 = p.origin.y + uint((uint64_t(gid.y + 1) * uint64_t(p.size.y)) / uint64_t(p.target.y));
        if (x1 <= x0) x1 = x0 + 1;   // an upsample of one axis would otherwise read nothing
        if (y1 <= y0) y1 = y0 + 1;

        float4 acc = float4(0.0);
        uint n = 0;
        for (uint y = y0; y < y1; ++y) {
            for (uint x = x0; x < x1; ++x) {
                acc += src.read(uint2(x, y));
                n += 1;
            }
        }
        dst.write(acc / float(n), gid);
    }
    """

    /// The one pipeline this process owns.
    ///
    /// `makeLibrary(source:)` is a **runtime compile**: measured on an M1 Pro at ~5 ms of extra frame
    /// time on the first measurement (34.5 ms for that frame, of which 20.6 ms is the graph's own pool
    /// warm-up and 9.1 ms the steady-state measurement; `HistogramTests.testTheRuntimeCompileIsOnce-
    /// PerProcess`). The graph used to hold the pipeline, so every graph paid that compile again — and
    /// a graph is rebuilt for each decode rung and each photo, so it could land on a frame in the
    /// middle of a pan. One process-wide slot makes it what this file always claimed: a *session*
    /// cost, never a per-frame one.
    private static let pipelineLock = NSLock()
    nonisolated(unsafe) private static var sharedPipeline: MTLComputePipelineState?


    /// The shared downsample pipeline, compiled on first use.
    static func pipeline(_ device: MTLDevice) throws -> MTLComputePipelineState {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        if let sharedPipeline { return sharedPipeline }
        let made = try makePipeline(device)
        sharedPipeline = made
        return made
    }

    static func makePipeline(_ device: MTLDevice) throws -> MTLComputePipelineState {
        Histogram.kernelCompileCount += 1
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw RenderError.kernelCompileFailed("histogram-downsample", error.localizedDescription)
        }
        guard let fn = library.makeFunction(name: "photons_histogram_downsample") else {
            throw RenderError.missingKernelFunction("histogram-downsample", "photons_histogram_downsample")
        }
        do {
            return try device.makeComputePipelineState(function: fn)
        } catch {
            throw RenderError.pipelineFailed("histogram-downsample", error.localizedDescription)
        }
    }

    /// Encode the reduction into a command buffer the frame already owns — the sample therefore costs
    /// one dispatch inside the frame's own submission, not a second command buffer and a second wait.
    /// `target` must be `Histogram.sampleSize(for: roi)` in size and a writable rgba16Float texture.
    static func encode(_ cb: MTLCommandBuffer, source: MTLTexture, roi: ImageRect,
                       target: MTLTexture, pipeline: MTLComputePipelineState) throws {
        guard let enc = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(source, index: 0)
        enc.setTexture(target, index: 1)
        var params = Params(origin: SIMD2(UInt32(max(roi.x, 0)), UInt32(max(roi.y, 0))),
                            size: SIMD2(UInt32(max(roi.width, 0)), UInt32(max(roi.height, 0))),
                            target: SIMD2(UInt32(target.width), UInt32(target.height)))
        enc.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        let tw = pipeline.threadExecutionWidth
        let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreadgroups(
            MTLSize(width: (target.width + tw - 1) / tw, height: (target.height + th - 1) / th, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
    }
}
