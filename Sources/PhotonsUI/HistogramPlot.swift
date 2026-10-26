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

    /// The right-hand string: that bin's R/G/B sample counts, exactly as counted (`R 1284 · G 1291 · B 1206`).
    /// Percentages are deliberately left out: at 9.5 pt the three counts plus the stop already fill
    /// the 244 pt card, and a number that has to be truncated is worse than one that is not shown.
    public static func hoverCounts(_ histogram: Histogram?, _ reading: HistogramHoverReading) -> String {
        guard let histogram else { return "—" }
        func count(_ channel: HistogramChannel) -> Int {
            let bins = reading.isTail ? channel.hdrBins : channel.bins
            return reading.bin >= 0 && reading.bin < bins.count ? bins[reading.bin] : 0
        }
        return "R \(count(histogram.red)) · G \(count(histogram.green)) · B \(count(histogram.blue))"
    }
}

// MARK: - 015: the channel row becomes three *fixed* R/G/B slots while hovering
//
// 013 printed one label (`亮度 82%`). The owner wants the same value three times — once per
// channel — and, the hard part, the three letters to sit at **fixed** positions: while the number
// changed, `G` and `B` used to slide sideways with the text.
//
// So the row is three equal-width slots, `rowWidth / 3` each:
//
//     |R        128|G        128|B        128|
//     ↑slot edge           slot edge ↑
//
// The letter is pinned to its slot's left edge (offset 0) and the number is right-aligned to its
// slot's right edge. Neither position is a function of the string, so `0`, `128` and `+3.0` all land
// in the same three places: the letters and the slots never move.
//
// The numbers: the row's x axis *is* brightness, so R/G/B are identical by construction (that
// redundancy is the owner's explicit call). The format follows the segment —
//
// - code segment (`0…1` of display white) → the **sRGB code, 0…255**, an integer: `128`;
// - the tail (above white) → **`+x.x`**, one decimal of a stop, the same `+1 档 = 2×` language the
//   footnote one row down uses: `+0.8`, `+3.0`.
//
// All geometry is quantised to 1/1000 pt, so `244 / 3` is the numbers `81.333 / 81.334 / 81.333`
// and a test can assert the three letters' `minX` are *exactly* equal rather than "equal to within
// a tolerance" — which is the only version of "fixed" that is worth asserting.

/// The hover row's three fixed slots: four ascending edges, three equal-width cells.
public struct HistogramHoverSlotLayout: Equatable, Sendable {

    /// The width the slots were laid out for: `max(cardWidth, 3 × minimumSlotWidth)`.
    public let rowWidth: CGFloat
    /// `[0, a, b, rowWidth]`, ascending, quantised to 1/1000 pt.
    public let edges: [CGFloat]

    public init(rowWidth: CGFloat, edges: [CGFloat]) {
        self.rowWidth = rowWidth
        self.edges = edges
    }

    public static let slotCount = 3

    /// The slot's left edge — where its channel letter starts.
    public func slotOrigin(_ slot: Int) -> CGFloat { edges[slot] }
    /// The slot's right edge — where its number ends.
    public func slotEnd(_ slot: Int) -> CGFloat { edges[slot + 1] }
    public func slotWidth(_ slot: Int) -> CGFloat { edges[slot + 1] - edges[slot] }

    public func slotRect(_ slot: Int, height: CGFloat, y: CGFloat) -> NSRect {
        NSRect(x: edges[slot], y: y, width: slotWidth(slot), height: height)
    }

    /// The letter's box: pinned to the slot's left edge, so its `minX` *is* the slot's `minX`
    /// whatever number sits next to it. `offsetX` is the row's own origin (the card's `bounds.minX`).
    public func letterRect(_ slot: Int, size: NSSize, y: CGFloat, offsetX: CGFloat = 0) -> NSRect {
        NSRect(origin: CGPoint(x: offsetX + edges[slot], y: y), size: size)
    }

    /// The number's box: right-aligned to the slot's right edge, `maxX == offsetX + edges[slot + 1]`.
    ///
    /// The origin is nudged by at most one ulp so that `origin.x + width` lands on the edge
    /// *exactly*. Without the nudge a right-aligned rect misses its edge by ~1e-14, and three
    /// different numbers then have three (very slightly) different right ends — which is precisely
    /// the "it moves when the text changes" the slots exist to prevent.
    public func valueRect(_ slot: Int, size: NSSize, y: CGFloat, offsetX: CGFloat = 0) -> NSRect {
        let right = offsetX + edges[slot + 1]
        var x = right - size.width
        if x + size.width != right {
            if x.nextUp + size.width == right { x = x.nextUp }
            else if x.nextDown + size.width == right { x = x.nextDown }
        }
        return NSRect(origin: CGPoint(x: x, y: y), size: size)
    }
}


extension HistogramCardFormat {

    /// The number the row prints, in the owner's two forms:
    ///
    /// - code segment: the **sRGB code, 0…255**, an integer — `0`, `128`, `255`. The axis is drawn
    ///   on the code, so the row quotes the code the pointer is on (a percentage of white is a
    ///   derived number; the code is the one a levels/curve tool is dialled in);
    /// - tail: **`+x.x`**, one decimal of a stop — `+0.8`, `+3.0` — the same `+1 档 = 2×` language
    ///   the closed readout one row down uses (`+0.80 档 (1.7×)`).
    ///
    /// One number for all three slots: the row's x axis *is* brightness, so R/G/B are at the same
    /// level at the same x by construction.
    public static func hoverSlotValue(_ reading: HistogramHoverReading?) -> String? {
        guard let reading else { return nil }
        switch reading.segment {
        case .code:
            return "\(min(255, max(0, reading.code)))"
        case .tail:
            return String(format: "%+.1f", max(reading.stops, 0))
        }
    }

    /// The three channel letters, in slot order — the same `R/G/B` the idle row uses.
    public static let hoverLevelSlotNames = ["R", "G", "B"]

    /// The row's text while hovering: three identical slots, `R 128 G 128 B 128` (or `+0.8` on the
    /// tail). `nil` only when there is no reading at all (nothing hovered) — the caller then keeps
    /// painting the above-white shares.
    public static func hoverLevelText(_ reading: HistogramHoverReading?) -> String? {
        guard let value = hoverSlotValue(reading) else { return nil }
        return hoverLevelSlotNames.map { "\($0) \(value)" }.joined(separator: " ")
    }
}

// MARK: - the row's three fixed slots (015)

extension HistogramCardFormat {

    /// The narrowest slot that still holds `+3.0` (≈ 21 pt at 9.5 pt) beside its letter with a real
    /// gap. `244 / 3 ≈ 81.3` clears it; the floor only matters on a card narrower than 216 pt, where
    /// the slots stay this wide and the row is allowed to run past the card rather than shrink the
    /// letters into the numbers.
    public static let hoverSlotMinimumWidth: CGFloat = 72

    /// The row's three slots for a card `rowWidth` points wide.
    ///
    /// `slotWidth = rowWidth / 3`, floor 72 pt. The four edges are quantised to 1/1000 pt, which is
    /// what makes the "fixed position" claim a fact rather than a hope: every number drawn into a
    /// slot is right-aligned to `edges[slot + 1]`, and that value is the same bit pattern for `0`,
    /// `128` and `+3.0`.
    public static func hoverSlotLayout(forRowWidth rowWidth: CGFloat) -> HistogramHoverSlotLayout {
        let total = max(rowWidth.isFinite ? rowWidth : 0, hoverSlotMinimumWidth * 3)
        func grid(_ value: CGFloat) -> CGFloat { (value * 1000).rounded() / 1000 }
        var edges = [CGFloat(0), grid(total / 3), grid(total * 2 / 3), grid(total)]
        // Degenerate widths (a 1 pt card, a NaN) must not produce equal or inverted edges.
        if edges[1] <= edges[0] { edges[1] = edges[0] + 1 }
        if edges[2] <= edges[1] { edges[2] = edges[1] + 1 }
        if edges[3] <= edges[2] { edges[3] = edges[2] + 1 }
        return HistogramHoverSlotLayout(rowWidth: total, edges: edges)
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
