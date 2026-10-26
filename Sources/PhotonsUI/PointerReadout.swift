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

        /// `"128"` / `"+1.0"` — the string the card paints behind the channel letter.
        ///
        /// No `档`, no `×`, no `L` prefix: the owner's wording for this row is a *number* (「左侧：亮度
        /// 0-255 或者 +1.0，不要写档和 x2.0」), and the two forms are distinguishable on sight.
        public var text: String {
            switch self {
            case .code(let code): return "\(code)"
            case .stops(let stops): return String(format: "%+.1f", max(stops, 0))
            }
        }

        /// One channel of a presented frame → the level that channel paints.
        ///
        /// Same two cases as the luma, per channel: a channel at or below display white is its sRGB
        /// **code** (0–255); a channel above it is that channel's own `log2` — one stop is 2×, the
        /// owner's 「+1 档 = 2×」 — printed as `+x.x`. Mixed rows are the point (`R 255 G +0.8 B 120`):
        /// a picture can hold a channel over white while the others are still inside the plot.
        public static func channel(encoded: Float) -> Level {
            let linear = Histogram.srgbDecode(encoded)
            if linear > 1 {
                return .stops(log2(Double(linear)))
            }
            let code = Double(Histogram.srgbEncode(Float(max(linear, 0)))) * 255
            return .code(min(255, max(0, Int(code.rounded()))))
        }
    }

    /// The level under the pointer (the luma).
    ///
    /// 023 deleted the row that printed it (「不需要亮度信息了」), so nothing paints `level.text` any more;
    /// it stays because it *is* the pixel's position on the axis (the bin/counts lookup above is its), and
    /// because the tests compare it against a second readback of the same texel.
    public let level: Level
    /// The three channels' **own** levels, R/G/B — what the row paints.
    ///
    /// Separate from `level` because they answer different questions: `level` is one brightness that
    /// places the pixel on the axis, the channels are the pixel's colour, and either of them can be above
    /// white while the other is not.
    public let channels: [Level]
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
                counts: HistogramBinCounts? = nil, channels: [Level]? = nil) {
        self.level = level
        self.channels = (channels?.count == 3) ? channels! : [level, level, level]
        self.bin = bin
        self.isTail = isTail
        self.luma = luma
        self.counts = counts
    }

    /// The three channel strings, in R/G/B order — `["245", "128", "64"]`.
    public var channelTexts: [String] { channels.map(\.text) }

    /// The channel row as one string, exactly as the card paints it: `R 245 G 128 B 64`.
    public var channelRowText: String { HistogramCardFormat.grouped(channelTexts) }

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
        // The three channels' own levels travel with the pixel: the channel row is their printout.
        let channels = [Level.channel(encoded: encodedRed), .channel(encoded: green),
                        .channel(encoded: blue)]

        if linear > 1 {
            // The tail: 1/64 stop per bin, the last bin is the overflow ("4 stops or more").
            let stops = log2(linear)
            let scaled = stops * Double(Histogram.hdrBinsPerStop)
            let bin = scaled >= Double(Histogram.hdrBinCount) ? Histogram.hdrBinCount - 1
                : max(0, Int(scaled))
            self.init(level: .stops(stops), bin: bin, isTail: true, luma: linear,
                      counts: Self.counts(histogram, bin: bin, isTail: true), channels: channels)
        } else {
            let code01 = Double(Histogram.srgbEncode(Float(max(linear, 0))))
            // `binIndex` in the measure loop: `floor(v · bins)` clamped into `[0, bins-1]`.
            let bin = min(sdrBins - 1, max(0, Int(code01 * Double(sdrBins))))
            let code = min(255, max(0, Int((code01 * 255).rounded())))
            self.init(level: .code(code), bin: bin, isTail: false, luma: linear,
                      counts: Self.counts(histogram, bin: bin, isTail: false), channels: channels)
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

// MARK: - the row's states

/// What the histogram card's one row is showing, when the pointer is over the **plot**.
///
/// The owner's rule (2026-10-26): 「鼠标在直方图上就显示该亮度像素数量，鼠标在其他位置就都不显示但保留这行的
/// 高度不要乱动」, revised by 023 (2026-10-26): 「不需要亮度信息了，只要 RGB 值」 — the `.image` case (the
/// pixel's brightness, one bare number) is gone, so the picture's half of the row is the pixel's three
/// **channels**, painted by the card from `PointerPixel.channelTexts` rather than by this enum. What is
/// left here is the plot's statement (a bin's R/G/B counts) and the absence of one.
public enum HistogramReadoutRow: Equatable, Sendable {
    /// Nothing under the pointer: the row paints nothing and keeps its height.
    case idle
    /// The pointer is over the plot: the R/G/B sample counts of the bin it points at.
    case histogram(counts: HistogramBinCounts)

    /// What the row paints, or `nil` for `.idle` (which paints nothing and still occupies the row).
    public var text: String? {
        switch self {
        case .idle: return nil
        case .histogram(let counts): return HistogramCardFormat.readoutCounts(counts)
        }
    }

    /// The counts string, or `""`.
    public var countsText: String {
        if case .histogram(let counts) = self { return HistogramCardFormat.readoutCounts(counts) }
        return ""
    }
}

extension HistogramCardFormat {

    /// Three `letter value` groups, exactly as the card paints them: `R 245 G 128 B 64`.
    ///
    /// The owner's layout (2026-10-26, second pass): 「RGB 三个字母要带颜色，数字要靠近字母，例如
    /// `R 2      G 40      B 1023`」. So the string is *one space* between a letter and its value and
    /// one space between groups; the wide gaps in the sketch are the **fixed group starts** the paint
    /// uses (`groupWidth = rowWidth / 3`, letter `i` at `i · groupWidth`), not characters. Numbers are
    /// left-aligned right after their letter and may run past their group's edge — the group *starts*
    /// are what must not float, and the readback that proves it is `letterRects`, not this string.
    ///
    /// Nothing is padded and nothing is right-aligned any more: the previous five-character
    /// right-aligned field is gone, so a long number cannot push its own value away from its letter.
    public static func grouped(_ values: [String]) -> String {
        zip(channelLetters, values).map { "\($0) \($1)" }.joined(separator: " ")
    }

    /// The counts block, exactly as the card paints it: `R 1284 G 1291 B 1206`.
    public static func readoutCounts(_ counts: HistogramBinCounts) -> String {
        grouped(["\(max(counts.red, 0))", "\(max(counts.green, 0))", "\(max(counts.blue, 0))"])
    }

    /// The three letters, in row order. One constant, shared by the plot legend, the channel row and
    /// the counts row, so "R is red" is the same fact everywhere.
    public static let channelLetters = ["R", "G", "B"]
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
