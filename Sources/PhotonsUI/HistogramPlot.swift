import AppKit
import PhotonsCore

// MARK: - the card's x axis: SDR + a 4-stop exponential tail
//
// The measurement (`Histogram`) already knows *what* it counted: 256 uniform code bins up to display
// white, then 32 bins that are 1/8 stop apart in linear light. This file is the other half of that
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
//   · **4 stops**, i.e. a fixed 120 pt tail, from `Histogram.maxStops` (16× = the largest headroom
//     the app will ever hand S4, so the tail always covers the screen).
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

    /// Centre of a tail bin (each 1/8 stop, so uniform in x **inside the tail**).
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
