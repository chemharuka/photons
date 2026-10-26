import AppKit
import PhotonsCore

// MARK: - the card's x axis: SDR + a 4-stop exponential tail
//
// The measurement (`Histogram`) already knows *what* it counted: 256 uniform code bins up to display
// white, then 256 bins that are 1/64 stop apart in linear light (the same count as the code half). This file is the other half of that
// contract — where each of them goes on screen — plus the peak normalisation the two segments must
// share, because a histogram whose two halves are scaled differently is two histograms glued
// together.
//
// Three numbers are policy, and they are here rather than in the card so `--ui-smoke` can assert
// them without reading pixels:
//
//   · **30 pt per stop.** The tail is a *reading* scale: "+1 stop" must mean the same 30 points
//     whether the inspector is 300 or 364 wide, otherwise the same picture's highlights would move
//     when the window moves. Only when the card is too narrow to keep 60 pt of SDR does the stop
//     scale shrink (the alternative — letting SDR collapse to nothing — is worse: the SDR segment is
//     where 95 % of a photograph lives).
//   · **4 stops**, i.e. a fixed 120 pt tail, from `Histogram.maxStops` — the owner's range rule
//     (2^4 = 16× white). The precision bump lives inside those 4 stops (64 bins/stop instead of 8),
//     not in a longer tail: at the inspector's 244 pt minimum, 120 pt of tail still leaves 124 pt of
//     SDR, far above the 60 pt floor, so the default scale holds at every width the app ships.
//   · **one peak for both segments.** End spikes are excluded together (the drawn path's first and
//     last bin), which is what keeps a clipped highlight from flattening the whole plot.

/// Where the SDR segment ends, where each stop of the tail lands, and where the display ceiling sits.
public struct HistogramAxis: Equatable {

    /// Points per stop of the exponential tail (owner's number, 2026-10-26).
    public static let pointsPerStop: CGFloat = 30
    /// The SDR segment never gets narrower than this; below it the stop scale shrinks instead.
    public static let minimumSDRWidth: CGFloat = 60

    public let plot: NSRect
    /// Actual points per stop (30 unless the card is too narrow).
    public let stopWidth: CGFloat

    public init(plot: NSRect) {
        self.plot = plot
        let stops = CGFloat(max(Histogram.maxStops, 1))
        let room = max(plot.width - Self.minimumSDRWidth, 0)
        self.stopWidth = plot.width > 1 ? min(Self.pointsPerStop, room / stops) : Self.pointsPerStop
    }

    public var stops: Int { Histogram.maxStops }
    public var hdrBinCount: Int { Histogram.hdrBinCount }
    /// Width of the exponential tail (4 × `stopWidth`, 120 pt at the default scale).
    public var hdrWidth: CGFloat { stopWidth * CGFloat(stops) }
    /// Width of the code segment (everything left of the tail).
    public var sdrWidth: CGFloat { max(plot.width - hdrWidth, 0) }
    /// The SDR / tail boundary: display white.
    public var sdrMaxX: CGFloat { plot.minX + sdrWidth }

    /// Centre of an SDR bin (uniform in code, so uniform in x).
    public func x(sdrBin index: Int, of binCount: Int) -> CGFloat {
        let n = max(binCount, 1)
        let i = min(max(index, 0), n - 1)
        return plot.minX + (CGFloat(i) + 0.5) / CGFloat(n) * sdrWidth
    }

    /// Centre of a tail bin (each 1/64 stop, so uniform in x **inside the tail**).
    public func x(hdrBin index: Int) -> CGFloat {
        let n = max(hdrBinCount, 1)
        let i = min(max(index, 0), n - 1)
        return sdrMaxX + (CGFloat(i) + 0.5) / CGFloat(n) * hdrWidth
    }

    /// A position in stops above display white — positive inside the tail, clamped to `0…stops`.
    public func x(stopsAboveWhite stop: Double) -> CGFloat {
        let s = min(max(stop.isFinite ? stop : 0, 0), Double(stops))
        return sdrMaxX + CGFloat(s) * stopWidth
    }

    /// Where a display with this S4 ceiling can show up to: `log2(headroom)` stops above white
    /// (headroom is linear, so `1.695` is 0.76 stop and `1.0` — SDR — is exactly the boundary).
    public func x(ceiling headroom: Double) -> CGFloat {
        x(stopsAboveWhite: log2(max(headroom, 1)))
    }
}

// MARK: - the pointer's reading (x → bin), and its text
//
// 派单 010: the footnote the owner deleted is replaced by a **hover readout** — what the x under the
// cursor means, and how many pixels are in that bin. The two halves are separate on purpose:
//
//   · **`hoverReading(atX:)` is geometry and nothing else.** It turns a point into
//     `(segment, bin, code | stops)` with the inverse of `x(sdrBin:)` / `x(hdrBin:)`, so the unit
//     tests can pin both ends, the code segment's middle and the four stop boundaries without a
//     window (and the card's `draw` never does this arithmetic inline).
//   · **`hoverValue` / `hoverCounts` are formatting.** They take a `Histogram` and a reading and
//     return the exact string the card paints, so "--ui-smoke" and the unit tests compare text, not
//     pixels.
//
// The bin edge is what gets quoted, not the bin's centre: a bin's meaning is its *lower* boundary
// ("this bin is every pixel at ≥ 1.000 stop"), so a pointer sitting on a stop line reads exactly
// 1.00 / 2.00 / 3.00 档 instead of drifting by half a bin (1.0078 …). The last tail bin is the
// overflow bin — the measurement puts everything at or past 4 stops in it — so it reads 3.98 档
// (15.8×) and is *taken to mean* "≥ 3.98 stops, up to the 16× ceiling".

/// What the pointer is over: a code bin, or a bin of the exponential tail.
public struct HistogramHoverReading: Equatable, Sendable {
    public enum Segment: String, Sendable { case code, tail }

    /// Which half of the axis the pointer is in.
    public let segment: Segment
    /// Index into `HistogramChannel.bins` (`segment == .code`) or `.hdrBins` (`segment == .tail`).
    public let bin: Int
    /// The sRGB code the bin stands for, 0…255 — `-1` on the tail, where code has no meaning.
    public let code: Int
    /// Stops above display white (the bin's lower boundary). `0` on the code segment.
    public let stops: Double
    /// Linear multiple of white, `2^stops` — the owner's "＋1 档 = 2×" wording. `1` on the code segment.
    public let multiple: Double

    public init(segment: Segment, bin: Int, code: Int = -1, stops: Double = 0, multiple: Double = 1) {
        self.segment = segment
        self.bin = bin
        self.code = code
        self.stops = stops
        self.multiple = multiple
    }

    public var isTail: Bool { segment == .tail }
}

extension HistogramAxis {

    /// The inverse of `x(sdrBin:)` / `x(hdrBin:)`: which bin the pointer at `x` is over.
    ///
    /// Clamped at both ends, so a point outside the plot (a caller that forgot to test containment,
    /// or a drag that ran off the card) still yields a legal bin instead of a crash. The SDR/tail
    /// boundary itself belongs to the **code** segment: it *is* display white, i.e. code 255 — the
    /// tail only begins strictly to its right.
    public func hoverReading(atX x: CGFloat, sdrBins: Int = 256) -> HistogramHoverReading {
        let n = max(sdrBins, 1)
        let clampedX = min(max(x, plot.minX), max(plot.maxX, plot.minX))

        if clampedX <= sdrMaxX || hdrWidth <= 0 {
            let u = sdrWidth > 0 ? min(max((clampedX - plot.minX) / sdrWidth, 0), 1) : 0
            let bin = min(max(Int(u * CGFloat(n)), 0), n - 1)
            // The code at the middle of the bin, floored: for the 256-bin default this is the bin
            // index itself (bin 128 → code 128), and it stays inside 0…255 for any bin count.
            let code = min(255, max(0, Int((Double(bin) + 0.5) / Double(n) * 256)))
            return HistogramHoverReading(segment: .code, bin: bin, code: code)
        }

        let t = min(max((clampedX - sdrMaxX) / hdrWidth, 0), 1)
        let bin = min(Int(t * CGFloat(hdrBinCount)), max(hdrBinCount - 1, 0))
        let stops = Double(bin) / Double(max(Histogram.hdrBinsPerStop, 1))
        return HistogramHoverReading(segment: .tail, bin: bin, stops: stops, multiple: pow(2, stops))
    }
}

extension HistogramCardFormat {

    /// The left-hand string: the code (`128`) or the tail's stop (`+1.00 档 (2.0×)`).
    public static func hoverValue(_ reading: HistogramHoverReading) -> String {
        switch reading.segment {
        case .code:
            return "\(reading.code)"
        case .tail:
            return String(format: "%+.2f 档 (%.1f×)", reading.stops, reading.multiple)
        }
    }

    /// That bin's R/G/B sample counts, as the card paints them: `R  1284 G  1291 B  1206`.
    ///
    /// Five-character fields, right-aligned, because the owner wants the three letters to stay put
    /// (「需要固定 R xxx G xxx B xxx 的宽度」) and a number that grows must not move them. `—` when there
    /// is no measurement at all: "nothing to say" is not the same as "a bin with no samples", and the
    /// row is only ever the counts when the card *has* a measurement.
    public static func hoverCounts(_ histogram: Histogram?, _ reading: HistogramHoverReading) -> String {
        guard let histogram else { return "—" }
        func count(_ channel: HistogramChannel) -> Int {
            let bins = reading.isTail ? channel.hdrBins : channel.bins
            return reading.bin >= 0 && reading.bin < bins.count ? bins[reading.bin] : 0
        }
        return readoutCounts(HistogramBinCounts(red: count(histogram.red),
                                                green: count(histogram.green),
                                                blue: count(histogram.blue)))
    }

}

// MARK: - 018: the row under the plot — three states, one height
//
// 017 made the row one line (`L 245 · R 1284 · G 1291 · B 1206`) and painted it *instead of* the
// channel percentages. The owner's next word split it: 「鼠标在画面上就显示该像素亮度，鼠标在直方图上就显示
// 该亮度像素数量，鼠标在其他位置就都不显示但保留这行的高度不要乱动」. So:
//
//     .image(value:)          pointer on the picture → the brightness alone (`128`, `+2.0`)
//     .histogram(counts:)     pointer on the plot    → that bin's counts alone (`R  1284 G  1291 B  1206`)
//     .idle                   anywhere else          → nothing, at the same height
//
// The two halves are formatted here (`HistogramReadoutRow`, `PointerPixel.Level`) and laid out by the
// card (`HistogramCardView.paintCountBlock`), so "what the numbers are" and "where they sit" are two
// separate, separately testable claims.

extension HistogramCardFormat {

    /// The brightness as the row prints it: an sRGB code `0…255`, or `+x.x` stops above white.
    ///
    /// One decimal on the tail, none on the code, and no `档` / `×` / `L` — the owner's wording for this
    /// row is a bare number (「左侧：亮度 0-255 或者 +1.0，不要写档和 x2.0」).
    public static func hoverRowValue(_ reading: HistogramHoverReading?) -> String? {
        guard let reading else { return nil }
        switch reading.segment {
        case .code:
            return "\(min(255, max(0, reading.code)))"
        case .tail:
            return String(format: "%+.1f", max(reading.stops, 0))
        }
    }

    /// The row's text for a plot hover; `nil` when nothing is hovered or nothing was measured.
    ///
    /// Counts and nothing else: the level belongs to the *pixel* under the pointer, and the plot does
    /// not know which pixel that is — it knows which bin. Painting a level here was 017's conflation.
    public static func hoverRowText(_ histogram: Histogram?, _ reading: HistogramHoverReading?) -> String? {
        guard let reading, let histogram else { return nil }
        return hoverCounts(histogram, reading)
    }
}

// MARK: - the card's arithmetic (no AppKit drawing, so the smoke can check the numbers directly)

extension HistogramCardFormat {

    /// The ceiling ratio for a channel (`HistogramChannel.clippedCeiling`), formatted like the rest.
    public static func clipCeiling(_ histogram: Histogram?, _ channel: Histogram.Channel) -> String {
        guard let histogram else { return "—" }
        return percent(histogram[channel].clippedCeiling)
    }

    /// The vertical scale for both segments: the largest count *between* the drawn path's first and
    /// last bin.
    ///
    /// Same rule as 005f's, generalised to the two-segment axis: a photo with a clipped highlight has
    /// thousands of pixels in the last bin and a normal distribution everywhere else, and scaling by
    /// that spike would draw a flat line along the bottom. When the ends are not the peak they are
    /// included as normal.
    public static func scalePeak(_ channel: HistogramChannel) -> Int {
        let all = channel.bins + channel.hdrBins
        guard all.count > 2 else { return all.max() ?? 0 }
        var interior = 0
        for i in 1..<(all.count - 1) { interior = max(interior, all[i]) }
        return interior > 0 ? interior : (all.max() ?? 0)
    }

    /// Points for one channel across **both** segments, in `axis.plot`'s coordinates (y down).
    ///
    /// One path: SDR bins left to right over the code segment, then the tail bins over the
    /// exponential segment, so the curve crosses the boundary without a seam. `peak` is passed in by
    /// the card so a caller chooses the normalisation explicitly.
    public static func points(_ channel: HistogramChannel, binCount: Int,
                              axis: HistogramAxis, peak: Int) -> [CGPoint] {
        guard peak > 0, axis.plot.width > 1, axis.plot.height > 1 else { return [] }
        let scale = Double(peak)
        let bottom = axis.plot.maxY
        func y(_ count: Int) -> CGFloat {
            bottom - CGFloat(min(1.0, Double(count) / scale)) * axis.plot.height
        }

        var points: [CGPoint] = []
        points.reserveCapacity(channel.bins.count + channel.hdrBins.count + 2)
        points.append(CGPoint(x: axis.plot.minX, y: bottom))
        for (i, count) in channel.bins.prefix(max(binCount, 1)).enumerated() {
            points.append(CGPoint(x: axis.x(sdrBin: i, of: binCount), y: y(count)))
        }
        for (i, count) in channel.hdrBins.enumerated() {
            points.append(CGPoint(x: axis.x(hdrBin: i), y: y(count)))
        }
        points.append(CGPoint(x: axis.plot.maxX, y: bottom))
        return points
    }
}
