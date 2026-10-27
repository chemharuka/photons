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
// **The sample is the measurement's own source, not the presented frame** (2026-10-27). It used to be
// `LoupeController.lastFrame.texture` — the frame S4 wrote — and S4 is `encode(min(v, headroom))`, so on
// this panel every channel above +1.98 stop arrived here as *white*: the row could print `255` and never
// `+2.3`. The owner's complaint is exactly that (「上限就是屏幕亮度」). The reading now comes from the
// **scene-linear grid** the histogram itself is counted from (`RenderGraph`'s `histogram_sample_linear`
// pass, 070), so the number under the cursor is the picture's light and the plot's bins are the same
// pixels. `SampleSource` records which of the two a reading came from, because the difference is
// observable (255 vs +2.3 on one pixel) and a fallback must not be able to pass for the real thing.

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

/// Where a `PointerPixel` was read from.
///
/// The two sources differ by exactly one clamp, and that clamp is the whole of the owner's complaint
/// (「上限就是屏幕亮度」): S4 writes `encode(min(v, headroom))`, so on a panel with 2 stops of headroom
/// every channel above +1.98 stop arrives as white. The scene-linear grid is the measurement's own input
/// and keeps those stops. Kept as a value on the pixel rather than a comment, so a test can say *which*
/// path produced a number and a fallback can never be mistaken for the real source.
public enum PointerSampleSource: String, Equatable, Sendable {
    /// The histogram's own grid, scene-linear, before S4 (`RenderGraph`'s `histogram_sample_linear`).
    case sceneLinear
    /// The frame S4 wrote, decoded again (`LoupeController.sample`). A fallback: over-white channels are
    /// already white in it.
    case presented
}

/// One pixel of the picture, expressed on the histogram's axis.
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

        /// Is this level light the *picture* has and the row reports as stops — i.e. above white?
        ///
        /// The card paints exactly these values in the clipping colour (「如果 R/G/B 中某个超过屏幕的
        /// 亮度，就把…字的颜色改为红色」). A code is never over white, whatever its digits say: `255` is
        /// white, `+0.0` is not a thing (the initialiser rounds to a code at 1.0), so the case *is* the
        /// predicate and nothing has to compare strings.
        public var isOverWhite: Bool {
            if case .stops = self { return true }
            return false
        }

        /// Is this level light the **panel** cannot show, given the ceiling it has right now?
        ///
        /// `isOverWhite` answers the picture's question (is it above 1.0 — above display white). This
        /// answers the screen's, and the two differ exactly when the screen has headroom: `+0.6` on a
        /// panel whose budget is 1.695 (0.76 stop) is lost, and on one at 4.08 (2.03 stops) it is
        /// shown. That is why the card takes its ink from **this** and its number from
        /// `DisplayHeadroom.ceilingStops` — one reading of the screen, used for both halves of the
        /// indicator (2026-10-27, 「调节屏幕亮度后要更新直方图中屏幕亮度指示」).
        public func exceeds(headroom: Double) -> Bool {
            let ceiling = log2(max(headroom, 1))
            switch self {
            case .code: return false
            case .stops(let stops): return stops > ceiling + 1e-9
            }
        }

        /// One **scene-linear** channel → the level that channel paints.
        ///
        /// The shipped measurement's own rule, per channel: at or below white the channel is its sRGB
        /// **code** (0–255, `srgbEncode(linear) × 255`); above white it is that channel's own `log2` —
        /// one stop is 2×, the owner's 「+1 档 = 2×」 — printed as `+x.x`. Mixed rows are the point
        /// (`R 255 G +2.3 B 120`): a picture can hold a channel over white while the others are still
        /// inside the plot, and the row must say so channel by channel rather than report one luma.
        ///
        /// Negative light (a curve can undershoot) reads as code 0, the same clamp `srgbEncode` gets in
        /// the measurement.
        public static func channel(linear: Float) -> Level {
            let value = Double(linear)
            if value > 1 {
                return .stops(log2(value))
            }
            let code = Double(Histogram.srgbEncode(Float(max(value, 0)))) * 255
            return .code(min(255, max(0, Int(code.rounded()))))
        }

        /// One channel of a **presented** (S4-encoded) frame → the level that channel paints.
        ///
        /// The fallback's spelling: the frame is already on the code axis, so one `srgbDecode` puts it
        /// back and `channel(linear:)` does the rest. It cannot recover light above the panel's headroom
        /// — that is S4's clamp, and the reason this is not the shipped path.
        public static func channel(encoded: Float) -> Level {
            channel(linear: Histogram.srgbDecode(encoded))
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
    /// Which source produced this reading (`sceneLinear` in the app, `presented` only as a fallback).
    public let source: PointerSampleSource

    public init(level: Level, bin: Int, isTail: Bool, luma: Double,
                counts: HistogramBinCounts? = nil, channels: [Level]? = nil,
                source: PointerSampleSource = .sceneLinear) {
        self.level = level
        self.channels = (channels?.count == 3) ? channels! : [level, level, level]
        self.bin = bin
        self.isTail = isTail
        self.luma = luma
        self.counts = counts
        self.source = source
    }

    /// The three channel strings, in R/G/B order — `["245", "128", "64"]`.
    public var channelTexts: [String] { channels.map(\.text) }

    /// Which of the three channels the row must paint in the clipping colour: the ones above white.
    ///
    /// Per channel and not per pixel — `R 255 G +2.3 B 8` is a legal row, and only the middle segment is
    /// light the panel cannot show.
    public var overWhiteChannels: [Bool] { channels.map(\.isOverWhite) }

    /// Which channels are light **this panel, at this ceiling, cannot show** — the picture's
    /// above-white flag narrowed by the screen's budget. `overWhiteChannels` is headroom-free; this is
    /// what the card inks, so growing the budget (a brighter screen) un-magenta's a channel that now
    /// fits.
    public func channelsBeyond(headroom: Double) -> [Bool] {
        channels.map { $0.exceeds(headroom: headroom) }
    }

    /// The channel row as one string, exactly as the card paints it: `R 245 G 128 B 64`.
    public var channelRowText: String { HistogramCardFormat.grouped(channelTexts) }

    /// The pixel of a **scene-linear** sample (S3 → S4's input), put on `histogram`'s axis.
    ///
    /// The shipped path (`LoupeController`): the channels are the picture's own light, so a channel the
    /// picture holds at 4.93 (log2 = +2.3) prints `+2.3` on *any* panel — including an SDR one that
    /// renders it as white. `luma` is the Rec.709 weighted sum of the linear channels, the measurement's
    /// own formula, so `bin` is the bin the plot counted this pixel into.
    public init(linearRed: Float, green: Float, blue: Float, histogram: Histogram?,
                source: PointerSampleSource = .sceneLinear) {
        let wr = Float(Histogram.lumaWeights.r)
        let wg = Float(Histogram.lumaWeights.g)
        let wb = Float(Histogram.lumaWeights.b)
        let linear = Double(wr * linearRed + wg * green + wb * blue)
        let sdrBins = max(histogram?.binCount ?? 256, 2)
        // The three channels' own levels travel with the pixel: the channel row is their printout.
        let channels = [Level.channel(linear: linearRed), .channel(linear: green),
                        .channel(linear: blue)]

        if linear > 1 {
            // The tail: 1/64 stop per bin, the last bin is the overflow ("4 stops or more").
            let stops = log2(linear)
            let scaled = stops * Double(Histogram.hdrBinsPerStop)
            let bin = scaled >= Double(Histogram.hdrBinCount) ? Histogram.hdrBinCount - 1
                : max(0, Int(scaled))
            self.init(level: .stops(stops), bin: bin, isTail: true, luma: linear,
                      counts: Self.counts(histogram, bin: bin, isTail: true), channels: channels,
                      source: source)
        } else {
            let code01 = Double(Histogram.srgbEncode(Float(max(linear, 0))))
            // `binIndex` in the measure loop: `floor(v · bins)` clamped into `[0, bins-1]`.
            let bin = min(sdrBins - 1, max(0, Int(code01 * Double(sdrBins))))
            let code = min(255, max(0, Int((code01 * 255).rounded())))
            self.init(level: .code(code), bin: bin, isTail: false, luma: linear,
                      counts: Self.counts(histogram, bin: bin, isTail: false), channels: channels,
                      source: source)
        }
    }

    /// The pixel of a presented (S4-encoded, RGBA16F) frame — **the fallback**, not the shipped source.
    ///
    /// S4 wrote `encode(min(v, headroom))`, so a channel the picture holds above the panel's headroom is
    /// already white here; one `srgbDecode` puts the codes back, and nothing can put the lost stops back.
    /// Kept because a frame whose measurement has not landed yet still has pixels, and a row that says
    /// `255` is better than a row that flickers — as long as it says where it read (`source`).
    public init(encodedRed: Float, green: Float, blue: Float, histogram: Histogram?) {
        self.init(linearRed: Histogram.srgbDecode(encodedRed), green: Histogram.srgbDecode(green),
                  blue: Histogram.srgbDecode(blue), histogram: histogram, source: .presented)
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

// MARK: - where a screen point lands on the measurement's grid

/// The mapping the pointer's readout needs: a texel of the frame **→** the texel of the measurement's
/// grid that covers it.
///
/// The grid is not the frame. `RenderGraph` reduces the picture to ≤ 256 texels on its long edge
/// (`Histogram.frameSampleLongEdge`) and `histogram_sample_linear` point-samples it on a fixed stride,
/// `(i + 0.5) · step`, so cell `j` is the picture pixel at `picture.origin + floor((j + 0.5) · step)`.
/// Asking "what is under the cursor" therefore means: which cell contains this frame texel.
///
/// Two properties this type exists to make checkable rather than implicit:
///
///   · **it is a pure function** of the picture rect and the grid size, so the arithmetic is testable
///     without a device, a render or a fixture;
///   · **the error is bounded by half a cell**, and a cell is `picture.size / grid.size` frame texels —
///     2.5 texels for a 640 × 400 canvas at the default grid, i.e. 1.25 pt on a 2× screen. That is the
///     honest resolution of a readout taken off a histogram's own sample, and it is the price of reading
///     the same pixels the plot counted instead of rendering the picture a second time.
public struct PointerSampleLattice: Equatable, Sendable {

    /// The picture's rect **inside the frame texture**, in texels (row 0 = the texture's first row).
    public let picture: ImageRect
    /// The measurement's grid over that rect.
    public let grid: ImageSize

    public init(picture: ImageRect, grid: ImageSize) {
        self.picture = picture
        self.grid = ImageSize(width: max(1, grid.width), height: max(1, grid.height))
    }

    /// The lattice the graph will have built for `picture` at `longEdge` — the same function the render
    /// uses (`Histogram.frameSampleSize`), so a caller can predict the grid from the frame alone.
    public init(picture: ImageRect, longEdge: Int = Histogram.frameSampleLongEdge) {
        self.init(picture: picture, grid: Histogram.frameSampleSize(for: picture, longEdge: longEdge))
    }

    /// Frame texels per grid cell, in x and y.
    public var step: (x: Double, y: Double) {
        (Double(max(picture.width, 1)) / Double(grid.width),
         Double(max(picture.height, 1)) / Double(grid.height))
    }

    /// The cell that covers frame texel `(x, y)`, clamped into the grid.
    ///
    /// `floor` because the kernel's sample sits *inside* the cell it stands for: cell `j` is drawn from
    /// the pixel at `picture.origin + floor((j + 0.5) · step)`, so a frame texel (whose centre is at
    /// `t + 0.5` locally) belongs to `j = floor((t − origin + 0.5) / step)`.
    public func gridTexel(forTextureX x: Int, y: Int) -> (x: Int, y: Int) {
        let s = step
        let jx = Int(((Double(x - picture.x) + 0.5) / s.x).rounded(.down))
        let jy = Int(((Double(y - picture.y) + 0.5) / s.y).rounded(.down))
        return (x: min(grid.width - 1, max(0, jx)), y: min(grid.height - 1, max(0, jy)))
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
