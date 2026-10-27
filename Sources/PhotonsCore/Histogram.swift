import Foundation
import CryptoKit

// MARK: - what a histogram is here
//
// A histogram is a measurement of **the picture**, not of the screen and not of the frame the camera
// happens to be showing. Three consequences, each a deliberate break from 005f:
//
// **1. It is measured before S4.** The samples are the scene-linear RGB S3 hands to S4: no primaries
// matrix, no transfer function, and — the point — no `min(v, headroom)` clamp. The measurement
// therefore describes the *photograph* (what an export at any headroom would carry), and an SDR panel
// can still show that a picture has 3 stops of highlight above white. `DisplayOptions.headroom` no
// longer enters the geometry of the measurement at all; it only derives `clippedCeiling` (how much
// *this* screen would throw away) and the card's 「本机能显示到哪」 tick.
//
// **2. The x axis is an sRGB code axis, derived here.** Below white the bins are uniform in the code
// value this process computes by applying the sRGB OETF to the linear sample (`srgbEncode`), so the
// axis still means "how many pixels at code k" — the same reading as before, and the same 256 bins an
// 8-bit output has. Above white the axis is exponential in **stops of linear light**, because a stop
// is a doubling of light and the headroom S4 is handed is a linear multiple of white; one stop of
// *code* is 2.4 stops of light (sRGB is ~γ2.4 above the knee), so a code-doubling axis would lie by
// that factor and the display-ceiling marker could not be placed on it.
//
// **3. There is one measurement per picture, not one per frame.** `RenderGraph.measureHistogram`
// renders the whole picture once, at a thumbnail scale (long edge ≤ `maxLongEdge`), and counts the
// pixels of *that* render. So `sampleCount` is a property of the photo's aspect and nothing else: it
// does not move when the camera zooms or pans or when the window resizes, and the card's 「采样 N px」
// is the same number at fit, at 1:1 and at 400 %.
//
// **3b. A frame that is the whole picture also measures *this* domain (070).** The card follows a
// drag out of the frame it just drew, and that frame's own texture is not usable for this: S4 has
// encoded it *and* clamped it at `DisplayOptions.headroom` (`min(v, headroom)` in `s4_display.metal`),
// so on a +2 stop screen everything brighter than +2 stops arrives as the same number and the plot
// cannot show the three stops a picture may actually have. `RenderOptions.histogramSampleLongEdge`
// therefore makes the render stride-sample its **pre-S4** texture into a ≤ 256-long-edge grid
// (`histogram_sample_linear`) and hands back the same `Histogram` this file builds from a
// `LinearSample` — one extra dispatch, 0.29 MB read back, measured inside the frame's own command
// buffer. `headroom` in that histogram still only labels the screen (the ceiling tick and
// `clippedCeiling`); it cannot move a bin, which is the whole point.
//
// `RenderGraph.measureFrameHistogram(fromFrame:)` remains as the **display-referred** measurement of
// an S4 texture — codes, clamped at the panel's headroom. It is what `HistogramLetterboxTests` and
// 070's counter-proof (`HistogramHeadroomTests`) use to show what the old source could not see; the
// card no longer calls it.
//
// The tail: `maxStops × hdrBinsPerStop` = 4 × 64 = **256 bins of 1/64 stop** above white (005 was
// 4 × 8 = 32 bins of 1/8 stop — one bin per 12 % of light, which made the tail's spikes tower over
// the SDR segment because a tail bin covered a far wider slice of the picture than a code bin did).
// The **range** stays at the owner's 4 stops (2^4 = 16× white, the largest headroom the app can hand
// S4); the *resolution* is what changed, to 256 bins — the same count as the SDR segment, so the two
// halves of the axis are comparable at a glance instead of one being 32× coarser than the other.
// Samples past the last bin are counted in the last bin (`hdrBinIndex`).
//
// Two smaller decisions worth writing down rather than discovering later:
//
//   · `binCount` is the *measurement's* resolution, not the file's. The default 256 matches an
//     8-bit output; a 16-bit export that wants per-code counts would ask for 65536 bins (4 × 256 KB
//     of counters here, so that is a caller's decision, not a default).
//   · The four series are R, G, B and **luma** with Rec.709 weights applied to the encoded values
//     (0.2126, 0.7152, 0.0722). That is the same number a compositor would call luma; scene
//     luminance is a different quantity and `LinearImage.statistics()` is where it lives.

/// Scene-linear RGB, as S3 hands it to S4 — **no** transfer function, **no** headroom clamp.
///
/// The measurement's input. Deliberately not `DisplayImage` (which is display-encoded by contract): a
/// type that says "linear" is what keeps a future caller from feeding the counters coded values and
/// getting a plausible, wrong plot.
public struct LinearSample: Sendable {
    public let width: Int
    public let height: Int
    /// Row-major rgba, 4 components per pixel. Values above 1 are legal and expected.
    public let rgba: [Float16]

    public init(width: Int, height: Int, rgba: [Float16]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public var size: ImageSize { ImageSize(width: width, height: height) }

    /// One texel's scene-linear RGB, or `nil` when the index is outside the grid.
    ///
    /// The pointer's readout reads here (`PointerPixel(linearRed:…)`): the grid is the measurement's own
    /// input, so the number under the cursor and the bin the plot drew come from one place. Values above
    /// 1 are legal and are the reason the row has a `+x.x` form at all.
    public func texel(x: Int, y: Int) -> (red: Float, green: Float, blue: Float)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        guard i >= 0, i + 3 < rgba.count else { return nil }
        return (Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2]))
    }
}

/// One channel's distribution plus the three ratios that make it actionable.
public struct HistogramChannel: Sendable, Equatable {
    /// `bins[k]` = number of sampled pixels whose **code** (`srgbEncode(linear)`) fell in
    /// `[k/binCount, (k+1)/binCount)`. Linear values above white are not here: they are the tail.
    public let bins: [Int]
    /// `hdrBins[k]` = samples 1/64 stop apart above white — see the file header. Empty when a caller
    /// built the value by hand; the measurement always fills it.
    public let hdrBins: [Int]
    /// Fraction of sampled pixels **above** `Histogram.clipHighThreshold` (0.999 of code), i.e. above
    /// SDR white. On an SDR screen this is *not* lost detail any more — it is light the picture has
    /// and the panel does not — which is why `clippedCeiling` sits next to it.
    ///
    /// A clipped sample is still counted in `bins` — its last bin — because "the distribution ends at
    /// white" and "white was hit" are different facts and a caller needs both.
    public let clippedHigh: Double
    /// Fraction of sampled pixels **at or above the ceiling this measurement was taken for**
    /// (`Histogram.headroom`, in linear units where 1 is SDR white).
    ///
    /// This is the derived quantity screen-independence bought: the bins cannot depend on a panel, so
    /// "how much would it lose *here*" is reported separately, as the fraction a screen with that
    /// headroom would clamp. With `headroom = 1` it is the fraction above white that an SDR panel
    /// cannot show — the number the old `clippedCeiling` reported, now for a stated screen instead of
    /// for whichever panel happened to render the frame.
    public let clippedCeiling: Double
    /// Fraction of sampled pixels **below** `Histogram.clipLowThreshold` (0.001). Linear values are
    /// negative sometimes (a curve can undershoot); those count as below black.
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

    /// The bin with the most samples (`nil` for an empty channel — an empty sample has no peak).
    public var peakBin: Int? {
        guard total > 0 else { return nil }
        return bins.indices.max { bins[$0] < bins[$1] }
    }

    /// A stable digest of the counts, so "the same edit gives the same plot" can be asserted as an
    /// equality of numbers rather than of shapes. Both segments are in it, in a fixed order.
    public func sha256() -> String {
        var hasher = SHA256()
        let sdr = bins.map { UInt32(max(0, $0)) }
        let tail = hdrBins.map { UInt32(max(0, $0)) }
        sdr.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        tail.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Four channels, the picture they were measured over, and the grid they were measured on.
public struct Histogram: Sendable, Equatable {
    /// What counts as clipped. Display-encoded white is exactly 1.0, so 0.999 admits one 8-bit code
    /// below it; the low side is symmetric (0.001 is the second code above black at 8 bits). Both are
    /// compared in *code* space, which is why `compute` encodes before it tests them — the same
    /// threshold every 8-bit tool uses, on a measurement that no longer arrives encoded.
    public static let clipHighThreshold: Double = 0.999
    public static let clipLowThreshold: Double = 0.001
    /// Rec.709 weights, applied to encoded values — see the note at the top of this file.
    public static let lumaWeights: (r: Double, g: Double, b: Double) = (0.2126, 0.7152, 0.0722)

    /// Bins per channel on the SDR segment.
    public let binCount: Int
    /// Bins per channel on the exponential tail: `maxStops × hdrBinsPerStop` (256 today — the same
    /// count as the SDR segment, so one bin means a comparable slice of the picture on both halves).
    public var hdrBinCount: Int { Histogram.hdrBinCount }
    /// Pixels counted: the sample grid's pixel count, i.e. the whole-picture thumbnail's own pixels.
    /// Constant for a given photo — this is the number the card prints as 「采样 N px」.
    public let sampleCount: Int
    /// The picture's own pixel grid at scale 1 (the crop's output size), which the sample stands for.
    public let canvas: ImageSize
    /// The region of `canvas` the measurement covers — the whole picture.
    public let roi: ImageRect
    /// The grid the samples came from (long edge ≤ `maxLongEdge`).
    public let sampleSize: ImageSize
    /// Output primaries the samples are in. Always `.sRGB`: the measurement is taken before S4's
    /// primaries matrix, so the codes on the axis are sRGB codes regardless of the panel.
    public let primaries: OutputPrimaries
    /// The display ceiling this measurement's `clippedCeiling` was derived for, in **linear** units
    /// where 1 is SDR white. It cannot move a bin any more; it travels with the measurement so the
    /// card's ceiling tick and the 削顶 number describe the same screen.
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

    /// Stops above white this measurement can hold — **4**, the same range 005 had.
    ///
    /// The owner's rule is "at most 4 stops" (2^4 = 16× white, which is also
    /// `DisplayHeadroom.maximumHeadroom`). What 派单 005 asked to improve was the *resolution*, not the
    /// range: a 6-stop tail was my own over-reach and has been reverted. Anything past the last bin
    /// lands there.
    public static let maxStops = 4
    /// Tail resolution: **64 bins per stop** = 1/64 stop ≈ 1.1 % of light per bin (005 was 1/8 stop,
    /// i.e. 12 %). 4 stops × 64 = 256 bins, matching `binCount` — that equality is the point: with 32
    /// tail bins against 256 code bins, one tail bin stood for 8× more picture than a code bin and the
    /// tail drew as spikes several times taller than anything in the SDR segment. The card gives the
    /// tail 120 pt (4 × 30), so a tail bin is under half a point wide; the plot draws the outline, not
    /// bars, so that is a shape, not a rasterisation problem.
    public static let hdrBinsPerStop = 64
    public static var hdrBinCount: Int { maxStops * hdrBinsPerStop }

    /// Where the display ceiling sits on the tail, in stops above white (`0` for an SDR screen).
    public var displayStops: Double { log2(max(headroom, 1)) }

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

    /// The sample grid as a fraction of the picture it stands for — the honest denominator for "how
    /// much of the picture did this measurement actually see".
    public var sampleFraction: Double {
        let roiPixels = roi.area
        guard roiPixels > 0 else { return 0 }
        return Double(sampleCount) / Double(roiPixels)
    }

    /// A digest of every bin of every channel (both segments), so "the same edit gives the same plot"
    /// is one string.
    public func binsDigest() -> String {
        var hasher = SHA256()
        for channel in channels { hasher.update(data: Data(channel.sha256().utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The key one measurement is cached under:
    /// `hist|v1|<rungIdentity>|<editDigest>|<bins>`.
    ///
    /// `rungIdentity` names the decoded buffer (photo content hash + decode recipe + the rung the
    /// histogram is always measured from); `editDigest` the document. Nothing about the camera, the
    /// viewport or the display is in here — that is claim A expressed as key material instead of as a
    /// comment.
    public static func cacheKey(rungIdentity: String, editDigest: String, bins: Int) -> String {
        "hist|v1|\(rungIdentity)|\(editDigest)|\(bins)"
    }

    /// A stable digest of a document's develop settings (JSON with sorted keys, SHA-256, 8 bytes of
    /// hex).
    ///
    /// Stable across processes on purpose: a key built from Swift's `Hasher` is seeded per launch, so
    /// the same photo would measure twice in two sessions and the claim "one measurement per picture"
    /// would be a per-process claim.
    public static func editDigest(_ edit: EditModel) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(edit) else { return "undigestable" }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - the sampling rule

extension Histogram {
    /// Longest edge of the grid a histogram is measured on.
    ///
    /// 1024, and now it is the **render's own** resolution rather than a reduction applied to a frame:
    /// `measureHistogram` renders the whole picture at the scale that puts its long edge here and
    /// counts every pixel of that render. At 4.10 Mpx (1500×2731) the grid is 562×1024 = 0.58 Mpx, so
    /// the one readback is 4.6 MB of half float and the CPU walks 14 % of the pixels instead of all of
    /// them. The error this buys is quantified in `sampleSize(for:)`'s note and measured against a
    /// full-resolution recount in `HistogramTests`.
    public static let maxLongEdge = 1024

    /// The grid a `roi` is reduced to: the same aspect, long edge ≤ 1024, never upsampled.
    ///
    /// **The error this introduces, in full.** The render samples the source at this scale, so a
    /// destination texel is the *mean* of the source rectangle it covers (`r_x × r_y` pixels,
    /// `r ≈ longEdge/1024`, i.e. 2.7 × 2.7 at 4.10 Mpx). Two things follow:
    ///
    ///   1. **Bin counts.** The sample is a 0.58 Mpx estimate of a 4.10 Mpx distribution. If the
    ///      pixels were independent, the per-bin fractional error would be bounded by
    ///      `0.5/√N ≈ 0.07 pp` at N = 0.58 M (a binomial two-sigma figure); in practice pictures are
    ///      spatially correlated, so the *structural* term dominates: a feature smaller than one
    ///      source rectangle (≈ 2.7 × 2.7 px) is averaged into its neighbours, which moves at most the
    ///      mass of those features. For smooth and mid-frequency content this is far below the 1 %
    ///      bound `HistogramTests` asserts against a full-resolution recount; for 1-px-wide detail (a
    ///      resolution chart, dithered noise) the histogram of a downsample is genuinely the histogram
    ///      of an *average*, and no bound smaller than the local contrast exists.
    ///   2. **Clipping ratios.** Averaging is what clipping measurement cannot survive at the extreme:
    ///      a specular highlight or a 1-px rim that is 8 stops up inside a footprint whose mean is 5
    ///      stops up stops counting as beyond the last bin. So the ratio is exact for regions larger
    ///      than ~3 × 3 source pixels and *under*-reports the finest clipped detail. That under-report
    ///      is the price of a 0.58 Mpx sample instead of a 60 Mpx one, and it is the reason the ratio
    ///      is documented as "fraction of the sample", not "fraction of the picture".
    public static func sampleSize(for roi: ImageRect) -> ImageSize {
        let long = max(roi.width, roi.height)
        guard long > maxLongEdge else {
            return ImageSize(width: max(1, roi.width), height: max(1, roi.height))
        }
        let s = Double(maxLongEdge) / Double(long)
        return ImageSize(width: max(1, Int((Double(roi.width) * s).rounded())),
                         height: max(1, Int((Double(roi.height) * s).rounded())))
    }

    /// The render scale that puts a `size`-pixel picture on that grid (`1` when it already fits).
    ///
    /// The same arithmetic as `sampleSize(for:)` in the other direction, on purpose: the render's
    /// `frame` is `round(crop × scale)`, so the two agree to the pixel and a caller can predict the
    /// sample's size without rendering it.
    public static func sampleScale(for size: ImageSize) -> Double {
        let long = Double(max(size.width, size.height))
        guard long > Double(maxLongEdge) else { return 1 }
        return Double(maxLongEdge) / long
    }

    /// Longest edge of the grid a **frame** is reduced to for a per-frame measurement.
    ///
    /// 256, not 1024 — and for the opposite reason to `maxLongEdge`. That grid is the measurement
    /// itself, paid once per edit; this one is paid *per rendered frame* (`RenderGraph
    /// .measureHistogram(fromFrame:)`, 027), inside a slider drag, where the whole budget for
    /// measuring is 2 ms. 256 on the long edge of a 4.10 Mpx frame is 141×256 = 36 k samples: 0.29 MB
    /// read back instead of 4.6 MB, and a CPU binning pass that is a tenth of the 0.58 Mpx one.
    ///
    /// The size of the grid is a noise/price knob, not a coverage one: both grids spread their
    /// samples over the whole picture, so neither is brighter or darker than the other on average.
    /// What shrinks with the grid is the *resolution of the estimate* — a bin's count carries a
    /// relative error of order `1/√(bin count)`, which `HistogramSampleTests` prints.
    public static let frameSampleLongEdge = 256

    /// The grid a frame's picture `rect` is reduced to: same aspect, long edge ≤ `longEdge`, never
    /// upsampled (a picture smaller than the grid is sampled one texel per texel, so that case is
    /// exact and not merely close).
    public static func frameSampleSize(for rect: ImageRect, longEdge: Int = frameSampleLongEdge)
        -> ImageSize {
        let long = max(max(rect.width, rect.height), 1)
        let cap = max(2, longEdge)
        guard long > cap else {
            return ImageSize(width: max(1, rect.width), height: max(1, rect.height))
        }
        let s = Double(cap) / Double(long)
        return ImageSize(width: max(1, Int((Double(rect.width) * s).rounded())),
                         height: max(1, Int((Double(rect.height) * s).rounded())))
    }
}

// MARK: - the measurement itself

extension Histogram {
    /// Measure scene-linear pixels. Pure CPU: no Metal, no I/O, so the arithmetic is testable against a
    /// hand-built `LinearSample` and the render path only has to be trusted as far as "it produced the
    /// picture at thumbnail scale".
    ///
    /// `rect` is in sample pixels and defaults to the whole sample; the returned histogram's `canvas`
    /// is the sample's own size, i.e. the frame the rect was expressed in. The render path re-labels it
    /// with `relabelled(canvas:roi:)` so the numbers stay the sample's and the region they stand for is
    /// the caller's.
    public static func compute(_ sample: LinearSample, bins: Int = 256,
                               rect: ImageRect? = nil, headroom: Double = 1) -> Histogram {
        measure(width: sample.width, height: sample.height, rgba: sample.rgba,
                bins: bins, rect: rect, headroom: headroom, encoded: false)
    }

    /// Measure an **already display-encoded** image: its codes are the axis, so nothing is encoded.
    ///
    /// Not the same as `compute(LinearSample)` with a decode in front of it: a decode→encode round trip
    /// through `Float16` moves a value that sits exactly on a bin edge into the bin below (0.5 of code
    /// came back as 0.4995 and landed in bin 127 on the first attempt at this), and a fixture that says
    /// "one pixel per bin" deserves the bins it asked for. The render path never uses this — the graph
    /// has the linear values before S4 and measures those.
    public static func computeEncoded(_ image: DisplayImage, bins: Int = 256,
                                      rect: ImageRect? = nil, headroom: Double = 1) -> Histogram {
        measure(image, bins: bins, rect: rect, headroom: headroom, lumaInAlpha: false)
    }

    /// Measure a **frame sample**: `histogram_sample`'s downsampled, display-encoded grid, whose
    /// fourth channel carries the luma (`RenderGraph.measureHistogram(fromFrame:)`, 027).
    ///
    /// Three codes and a luma is one channel more than an `rgba16Float` texture has, and S4 leaves
    /// alpha at 1.0, so the sample kernel spends that channel on the one number the CPU cannot derive
    /// without four `pow`s per pixel: `srgbEncode(0.2126·R + 0.7152·G + 0.0722·B)` of the **linear**
    /// light, which is the definition the shipped pre-S4 measurement uses. Deriving it on the CPU from
    /// the three codes instead is a different quantity (the OETF is concave: `Σw·code` sits below
    /// `encode(Σw·linear)`, by up to ~0.02 of code near white), and it showed up as the only series
    /// whose bins disagreed between the two paths.
    ///
    /// `image.alpha` is therefore *not* alpha. A caller recounting a sample must use this entry point,
    /// not `computeEncoded` — the luma series would then be the code-space mean instead.
    public static func computeFrameSample(_ image: DisplayImage, bins: Int = 256,
                                          rect: ImageRect? = nil,
                                          headroom: Double = 1) -> Histogram {
        measure(image, bins: bins, rect: rect, headroom: headroom, lumaInAlpha: true)
    }

    private static func measure(_ image: DisplayImage, bins: Int, rect: ImageRect?,
                                headroom: Double, lumaInAlpha: Bool) -> Histogram {
        let measured = measure(width: image.width, height: image.height, rgba: image.rgba,
                               bins: bins, rect: rect, headroom: headroom, encoded: true,
                               lumaInAlpha: lumaInAlpha)
        return Histogram(binCount: measured.binCount, sampleCount: measured.sampleCount,
                         canvas: measured.canvas, roi: measured.roi,
                         sampleSize: measured.sampleSize, primaries: image.primaries,
                         headroom: measured.headroom,
                         red: measured.red, green: measured.green,
                         blue: measured.blue, luma: measured.luma)
    }

    /// The one counting loop. `encoded` says whether the samples are codes (the axis itself) or scene
    /// linear light (encoded here) — the only difference between the two entry points.
    private static func measure(width: Int, height: Int, rgba: [Float16],
                                bins: Int, rect: ImageRect?, headroom: Double,
                                encoded: Bool, lumaInAlpha: Bool = false) -> Histogram {
        let binCount = min(max(bins, 2), 1 << 16)
        let hdrCount = hdrBinCount
        let stride = binCount + hdrCount
        let frame = ImageSize(width: width, height: height)
        if let rect, rect.isEmpty {
            return Histogram.empty(bins: binCount, canvas: frame, roi: rect, headroom: headroom)
        }
        let rect = (rect ?? ImageRect(x: 0, y: 0, width: frame.width, height: frame.height))
            .clamped(in: frame)

        // The two thresholds live in code space (`0.999`, `0.001`); a linear sample has them
        // translated once, so the per-pixel test stays one comparison (0.999 of code is
        // `srgbDecode(0.999)` of light). The same numbers an 8-bit tool would use.
        let high = encoded ? Float(clipHighThreshold) : srgbDecode(Float(clipHighThreshold))
        let low = encoded ? Float(clipLowThreshold) : srgbDecode(Float(clipLowThreshold))
        let (wr, wg, wb) = (Float(lumaWeights.r), Float(lumaWeights.g), Float(lumaWeights.b))
        // The ceiling is a *value* now, not a clamp whose output we read back: a sample at or above it
        // is light this screen would throw away. Slack by half a float16 step (2^-11 relative) — that
        // is the quantisation of the texture the samples came from, and without it a value that is
        // exactly the ceiling could land one ULP below and never be counted.
        let ceilingFloor = (encoded ? srgbEncode(Float(max(headroom, 1))) : Float(max(headroom, 1)))
            * (1 - 1.0 / 2048)

        // One flat counter block indexed through a raw pointer: per channel
        // `SDR bins | HDR bins`, then 12 scalars `hiR hiG hiB hiL · ceilR ceilG ceilB ceilL ·
        // loR loG loB loL`. The pointer matters because an `Array` subscript per increment pays an
        // exclusivity check on every one of a million pixels — 306 ms for 0.79 Mpx in a debug build,
        // against 83 ms for 0.58 Mpx with this block. In a **release** build the loop was 4.7 ms for
        // 0.58 Mpx when the samples arrived already encoded; deriving the code axis costs one `pow`
        // per channel per pixel and `HistogramTests` prints the measured total so the number travels
        // with the claim. The tail adds work only for samples above white (one `log2` each, and no
        // `pow` at all now that the input is linear). `Histogram.maxLongEdge` is what keeps the number
        // of pixels this block ever sees at ~0.5 M rather than 60 M.
        let statsBase = 4 * stride
        var counts = [Int](repeating: 0, count: 4 * stride + 12)
        let scale = Float(binCount)
        // Where the luma series comes from, as arithmetic rather than a branch: a *frame* sample
        // carries its luma in the (otherwise unused) alpha channel — `srgbEncode(Σw·linear)`, the
        // definition the pre-S4 measurement uses — while a linear or hand-built sample derives it from
        // the three channels weighted here. Mixing instead of testing keeps this loop branch-free:
        // the ternary this replaced cost 4.6× in a debug build (690 ms against 148 ms for the shipped
        // 0.58 Mpx measurement), which is a real regression in the test suite's own budget.
        let lumaMix: Float = lumaInAlpha ? 1 : 0

        rgba.withUnsafeBufferPointer { px in
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
                        // A frame sample carries the shipped luma in alpha (it is the only channel
                        // left, and deriving it from three codes would be a different quantity —
                        // see `computeFrameSample`).
                        let lv = lumaMix * unbounded(px[o + 3])
                            + (1 - lumaMix) * (wr * rv + wg * gv + wb * bv)

                        base[combinedIndex(rv, sdrBins: binCount, scale: scale,
                                           encoded: encoded)] += 1
                        base[g0 + combinedIndex(gv, sdrBins: binCount, scale: scale,
                                                encoded: encoded)] += 1
                        base[b0 + combinedIndex(bv, sdrBins: binCount, scale: scale,
                                                encoded: encoded)] += 1
                        base[l0 + combinedIndex(lv, sdrBins: binCount, scale: scale,
                                                encoded: encoded)] += 1

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
                         roi: rect, sampleSize: frame, primaries: .sRGB,
                         headroom: headroom,
                         red: channel(0, statsBase, statsBase + 4, statsBase + 8),
                         green: channel(stride, statsBase + 1, statsBase + 5, statsBase + 9),
                         blue: channel(2 * stride, statsBase + 2, statsBase + 6, statsBase + 10),
                         luma: channel(3 * stride, statsBase + 3, statsBase + 7, statsBase + 11))
    }

    /// The historical name for `computeEncoded`: a hand-built, display-encoded fixture measured on the
    /// code axis. Kept because that is what every arithmetic test in `HistogramTests` is written in —
    /// a ramp of codes, a solid patch of 0.5 — and renaming the fixtures would only have moved the
    /// risk, not reduced it.
    public static func compute(_ image: DisplayImage, bins: Int = 256,
                               rect: ImageRect? = nil, headroom: Double = 1) -> Histogram {
        computeEncoded(image, bins: bins, rect: rect, headroom: headroom)
    }

    /// The same counts, described by the picture they were taken from.
    ///
    /// The render path measures a *reduced* sample (≤ 1024 long edge), so `compute` reports the
    /// sample's own size as both canvas and ROI — true, and useless: what a caller asked about is the
    /// picture in its own pixels. Re-labelling keeps the arithmetic untouched and makes `roi.area` the
    /// denominator `sampleFraction` divides by, so "we counted 14 % of the pixels you asked about" is a
    /// number the caller can check.
    public func relabelled(canvas: ImageSize, roi: ImageRect) -> Histogram {
        Histogram(binCount: binCount, sampleCount: sampleCount, canvas: canvas, roi: roi,
                  sampleSize: sampleSize, primaries: primaries, headroom: headroom,
                  red: red, green: green, blue: blue, luma: luma)
    }

    /// Nothing measured: an empty region, or a render that could not produce a sample. Ratios are 0,
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

    /// The index in the combined `SDR bins | HDR bins` block: white and below on the **code** axis
    /// (`srgbEncode` of the linear sample), above it on the exponential tail.
    ///
    /// The encode is the one cost the pre-S4 measurement adds to the SDR segment: it used to be a
    /// multiply, because the samples already carried the transfer function. It is what makes the axis
    /// stay comparable with every 8-bit number a user has ever seen.
    @inline(__always)
    private static func combinedIndex(_ v: Float, sdrBins: Int, scale: Float,
                                      encoded: Bool) -> Int {
        if v > 1 {
            // The tail is in stops of *light*, so a coded sample has to be decoded first; a linear one
            // is already there.
            return sdrBins + hdrBinIndex(encoded ? srgbDecode(v) : v)
        }
        return binIndex(encoded ? v : srgbEncode(v), scale, sdrBins)
    }

    /// Which 1/64-stop bin a **linear** value above white belongs to.
    ///
    /// The sample is linear, so this is one `log2` and a multiply — no decode. (005 had to invert the
    /// transfer function per above-white sample, because what it was handed was code.)
    ///
    /// Degradation rules, same discipline as `binIndex`: `+∞` and anything at or past 4 stops land on
    /// the last bin (`"4 stops or more"`), and NaN — which cannot be above white and therefore cannot
    /// get here — would too, rather than trapping in `Int(_:)`. The scale is 1/64 stop, so `log2(v) * 64`.
    @inline(__always)
    private static func hdrBinIndex(_ v: Float) -> Int {
        let limit = Float(hdrBinCount)
        let scaled = log2(v) * Float(hdrBinsPerStop)
        if !(scaled < limit) { return hdrBinCount - 1 }
        if !(scaled > 0) { return 0 }
        return Int(scaled)
    }

    /// `1.055·v^(1/2.4) − 0.055` above the knee — the same function `s4_display` writes, so the code
    /// axis this file derives is the code axis the panel and the export carry.
    ///
    /// Public because the code axis is a *shared* definition, not a private detail: the histogram card's
    /// pointer readout has to turn a presented (S4-encoded) pixel back into the same linear light and the
    /// same code this axis counts, and two copies of the OETF would be two axes waiting to disagree.
    @inline(__always)
    public static func srgbEncode(_ v: Float) -> Float {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    /// Its inverse. Total (no trap) for every finite input; negatives mirror, which the counters
    /// handle (they land below black).
    @inline(__always)
    public static func srgbDecode(_ v: Float) -> Float {
        let a = abs(v)
        let d = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return v < 0 ? -d : d
    }
}

// MARK: - what is deliberately *not* here any more
//
// 005f's `HistogramGather` — a runtime-compiled downsample kernel that reduced the displayed frame (or
// a ROI inside it) to a ≤ 1024-long-edge grid — is gone (2026-10-26). It existed to sample the frame
// the camera had drawn; the whole point of measuring the picture instead is that there is exactly one
// sample per picture, and the cheapest way to get it is to *render* the picture at the sample's own
// size: S0 already samples with a filtered footprint, so the graph's own output at thumbnail scale is
// the downsample, produced by the same kernels as the picture on screen. That removes a runtime
// `makeLibrary` (5–8 ms on the first measurement of a process), one dispatch per measured frame, and
// the whole "the grid depends on the frame" failure mode.
