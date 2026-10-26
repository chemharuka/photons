import CoreGraphics
import Foundation
import PhotonsCore

// MARK: - the pointer, on the histogram's own axis
//
// Two features of the loupe are the same question — **where is the pointer, and what is under it** —
// asked by two surfaces: the zoom commands anchor on that pixel, and the histogram card reports it.
// This file is the arithmetic half of the second one. It exists so that "the number under the cursor"
// and "the bin the card draws" are the *same* number by construction, not two implementations that
// happen to agree on the fixture:
//
//   · the transfer function is `Histogram.srgbEncode` / `srgbDecode` — the pair `s4_display` writes and
//     the pair the measure loop derives its code axis with, now public for exactly this reason;
//   · luma is `Histogram.lumaWeights` applied to **scene-linear** channels, which is what
//     `Histogram.measure` does (`lv = wr·rv + wg·gv + wb·bv` on the linear samples);
//   · the bin split is the measurement's own rule: `v > 1` is the tail (1/64-stop bins above white),
//     everything else is `srgbEncode(v) × 256` on the code axis.
//
// The sample comes from the **presented** frame (`LoupeController.lastFrame.texture`), i.e. after S4:
// the channels are already sRGB-encoded and clamped at the frame's headroom, so one `srgbDecode` puts
// them back. That clamp is the one difference from the measurement, and it is a property of the screen,
// not of this arithmetic: on an SDR panel a pixel the picture holds at +2.0 stops is stored as white,
// because that is what the panel is being handed. `headroom` is therefore carried along — a frame on an
// EDR screen reads its tail honestly, an SDR frame reads 255 and says so.

/// The R/G/B sample counts of one histogram bin.
public struct HistogramBinCounts: Equatable, Sendable {
    public let red: Int
    public let green: Int
    public let blue: Int

    public init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `(0, 0, 0)` — what a bin with nothing in it holds, and what an unmeasured card has to say.
    public static let zero = HistogramBinCounts(red: 0, green: 0, blue: 0)
}

/// One pixel of the presented frame, expressed on the histogram's axis.
public struct PointerPixel: Equatable, Sendable {

    /// Where the pixel's luma sits: an sRGB code, or stops of light above white.
    public enum Level: Equatable, Sendable {
        /// `0…255` — the same axis the SDR half of the plot counts.
        case code(Int)
        /// Stops above display white (`1.0` = 2×, one decimal in the readout).
        case stops(Double)

        /// `"128"` / `"+1.0"` — the string the card paints on the left of the row.
        ///
        /// No `档`, no `×`, no `L` prefix: the owner's wording for this row is a *number* (「左侧：亮度
        /// 0-255 或者 +1.0，不要写档和 x2.0」), and the two forms are distinguishable on sight.
        public var text: String {
            switch self {
            case .code(let code): return "\(code)"
            case .stops(let stops): return String(format: "%+.1f", max(stops, 0))
            }
        }
    }

    /// The level under the pointer.
    public let level: Level
    /// Which bin the level falls in: `bins` index (code segment) or `hdrBins` index (tail).
    public let bin: Int
    /// `true` when `bin` indexes `hdrBins`.
    public let isTail: Bool
    /// The pixel's scene-linear luma, `1` = SDR white. Kept for the tests (they compare a pixel to the
    /// same pixel read a second way) and for a future log readout; the row paints `level`.
    public let luma: Double
    /// That bin's R/G/B sample counts, `nil` when there is no measurement to look them up in.
    public let counts: HistogramBinCounts?

    public init(level: Level, bin: Int, isTail: Bool, luma: Double,
                counts: HistogramBinCounts? = nil) {
        self.level = level
        self.bin = bin
        self.isTail = isTail
        self.luma = luma
        self.counts = counts
    }

    /// The pixel of a presented (S4-encoded, RGBA16F) frame, put on `histogram`'s axis.
    ///
    /// `luma` is the Rec.709 weighted sum of the **decoded** channels — the measurement's own formula,
    /// so the bin this returns is the bin the plot counted that pixel into (to the tolerance of the
    /// thumbnail's resampling, which is the measurement's, not this function's).
    public init(encodedRed: Float, green: Float, blue: Float, histogram: Histogram?) {
        let wr = Float(Histogram.lumaWeights.r)
        let wg = Float(Histogram.lumaWeights.g)
        let wb = Float(Histogram.lumaWeights.b)
        let r = Histogram.srgbDecode(encodedRed)
        let g = Histogram.srgbDecode(green)
        let b = Histogram.srgbDecode(blue)
        let linear = Double(wr * r + wg * g + wb * b)
        let sdrBins = max(histogram?.binCount ?? 256, 2)

        if linear > 1 {
            // The tail: 1/64 stop per bin, the last bin is the overflow ("4 stops or more").
            let stops = log2(linear)
            let scaled = stops * Double(Histogram.hdrBinsPerStop)
            let bin = scaled >= Double(Histogram.hdrBinCount) ? Histogram.hdrBinCount - 1
                : max(0, Int(scaled))
            self.init(level: .stops(stops), bin: bin, isTail: true, luma: linear,
                      counts: Self.counts(histogram, bin: bin, isTail: true))
        } else {
            let code01 = Double(Histogram.srgbEncode(Float(max(linear, 0))))
            // `binIndex` in the measure loop: `floor(v · bins)` clamped into `[0, bins-1]`.
            let bin = min(sdrBins - 1, max(0, Int(code01 * Double(sdrBins))))
            let code = min(255, max(0, Int((code01 * 255).rounded())))
            self.init(level: .code(code), bin: bin, isTail: false, luma: linear,
                      counts: Self.counts(histogram, bin: bin, isTail: false))
        }
    }

    /// The counts of one bin, or `nil` when the measurement is missing or too short for this index.
    public static func counts(_ histogram: Histogram?, bin: Int, isTail: Bool) -> HistogramBinCounts? {
        guard let histogram else { return nil }
        func value(_ channel: HistogramChannel) -> Int? {
            let bins = isTail ? channel.hdrBins : channel.bins
            guard bin >= 0, bin < bins.count else { return nil }
            return bins[bin]
        }
        guard let r = value(histogram.red), let g = value(histogram.green),
              let b = value(histogram.blue) else { return nil }
        return HistogramBinCounts(red: r, green: g, blue: b)
    }
}

// MARK: - the row's three states

/// What the histogram card's bottom row is showing. One row, one height, three contents.
///
/// The owner's rule (2026-10-26): 「鼠标在画面上就显示该像素亮度，鼠标在直方图上就显示该亮度像素数量，
/// 鼠标在其他位置就都不显示但保留这行的高度不要乱动」. An enum rather than two optional strings,
/// because the point of the type is that exactly one of the three is true and that none of them changes
/// the row's height.
public enum HistogramReadoutRow: Equatable, Sendable {
    /// Nothing under the pointer: the row paints nothing and keeps its height.
    case idle
    /// The pointer is over the picture: the brightness of the pixel under it, and nothing else.
    case image(value: String)
    /// The pointer is over the plot: the R/G/B sample counts of the brightness it points at.
    case histogram(counts: HistogramBinCounts)

    /// What the row paints, or `nil` for `.idle` (which paints nothing and still occupies the row).
    public var text: String? {
        switch self {
        case .idle: return nil
        case .image(let value): return value
        case .histogram(let counts): return HistogramCardFormat.readoutCounts(counts)
        }
    }

    /// The value string, or `""` — the readback the tests and the smoke compare.
    public var valueText: String {
        if case .image(let value) = self { return value }
        return ""
    }

    /// The counts string, or `""`.
    public var countsText: String {
        if case .histogram(let counts) = self { return HistogramCardFormat.readoutCounts(counts) }
        return ""
    }
}

extension HistogramCardFormat {

    /// The counts block, exactly as the card paints it: `R  1284 G  1291 B  1206`.
    ///
    /// Every count is **right-aligned in a five-character field** (`%5d`), so `R`/`G`/`B` sit at fixed x
    /// positions whatever the numbers are — the owner: 「需要固定 R xxx G xxx B xxx 的宽度，暂时给 xxx 留
    /// 五位的空白避免 RGB 三个字母位置会浮动」. A count that needs more than five digits grows its own
    /// field (nothing is truncated) and pushes the later letters right, which is the one case where the
    /// letters move and the only one the owner allowed ("超过 5 位时该列自然加宽").
    public static func readoutCounts(_ counts: HistogramBinCounts) -> String {
        "R " + field(counts.red) + " G " + field(counts.green) + " B " + field(counts.blue)
    }

    /// One fixed-width, right-aligned count field.
    public static func field(_ count: Int) -> String {
        let digits = max(count, 0)
        let text = "\(digits)"
        let width = max(readoutCountFieldWidth, text.count)
        return String(repeating: " ", count: width - text.count) + text
    }

    /// The number of characters a count field reserves — five, by the owner's request.
    public static let readoutCountFieldWidth = 5
}

// MARK: - who receives the pointer's reading

/// A surface that shows the pointer's reading (the histogram card today).
///
/// A protocol rather than a closure pair: the loupe owns *one* pointer, so it may have one consumer, and
/// `weak` means a card that goes away (a rebuilt inspector) cannot be written to. `PointerReadoutTarget`
/// is also what keeps the canvas from having to know that a histogram card exists at all.
@MainActor
public protocol PointerReadoutTarget: AnyObject {
    /// The pointer is over the picture at a pixel with this reading (`counts` included when known).
    func showPointerReadout(_ pixel: PointerPixel)
    /// The pointer left the picture; the row goes back to idle (and keeps its height).
    func clearPointerReadout()
}
