import Foundation

/// Two display modes measured from one small, scene-linear whole-picture sample.
/// Only counts are persisted, never RAW pixels or another full-size bitmap.
public struct HistogramSnapshot: Codable, Sendable, Equatable {
    public let hdr: Histogram
    public let sdr: Histogram
    public static let excludedSample = Float16(-65504)

    public init(sample: LinearSample, canvas: ImageSize) {
        var rgba: [Float16] = []
        rgba.reserveCapacity(sample.rgba.count)
        for i in stride(from: 0, to: sample.rgba.count - sample.rgba.count % 4, by: 4) {
            guard sample.rgba[i] != Self.excludedSample else { continue }
            for c in 0..<3 { rgba.append(sample.rgba[i+c].isFinite ? sample.rgba[i+c] : 0) }
            rgba.append(1)
        }
        let valid = LinearSample(width: rgba.count / 4, height: 1, rgba: rgba)
        func labelled(_ h: Histogram) -> Histogram {
            Histogram(binCount: h.binCount, sampleCount: h.sampleCount, canvas: canvas,
                      roi: ImageRect(x: 0, y: 0, width: canvas.width, height: canvas.height),
                      sampleSize: sample.size, primaries: h.primaries, headroom: h.headroom,
                      red: h.red, green: h.green, blue: h.blue, luma: h.luma)
        }
        hdr = labelled(Histogram.compute(valid))
        sdr = labelled(SDRProjection.histogram(valid, bins: 256, rect: nil, primaries: .displayP3))
    }

    public func histogram(hdr enabled: Bool, headroom: Double) -> Histogram {
        enabled ? hdr.withDisplayHeadroom(headroom) : sdr
    }

    public var isValid: Bool {
        [hdr, sdr].allSatisfy { h in
            h.binCount == 256 && h.sampleCount >= 0 && h.sampleCount <= 256 * 256
                && h.sampleSize.width > 0 && h.sampleSize.height > 0
                && h.channels.allSatisfy { c in
                    c.bins.count == 256 && c.hdrBins.count == Histogram.hdrBinCount
                        && c.bins.allSatisfy { $0 >= 0 && $0 <= h.sampleCount }
                        && c.hdrBins.allSatisfy { $0 >= 0 && $0 <= h.sampleCount }
                        && c.total == h.sampleCount
                        && [c.clippedHigh, c.clippedLow, c.clippedCeiling].allSatisfy { $0.isFinite && (0...1).contains($0) }
                }
        }
    }
}

extension Histogram {
    /// The display ceiling changes a readout, not the distribution. Derive it from the cached
    /// 1/64-stop bins instead of waking the decoder/GPU when the display's EDR budget changes.
    /// Interpolation within a bin has the same 1/64-stop resolution as the plotted distribution.
    public func withDisplayHeadroom(_ requested: Double) -> Histogram {
        let ceiling = min(16, max(1, requested.isFinite ? requested : 1))
        guard abs(ceiling - headroom) > 0.0001 else { return self }
        func channel(_ c: HistogramChannel) -> HistogramChannel {
            let position = max(0, log2(ceiling * (1 - 1.0 / 2048)) * Double(Self.hdrBinsPerStop))
            let index = min(c.hdrBins.count - 1, Int(position))
            let above = index >= 0 ? Double(c.hdrBins.dropFirst(index + 1).reduce(0, +))
                + Double(c.hdrBins[index]) * (index == c.hdrBins.count - 1 ? 1 : 1 - min(1, position - Double(index))) : 0
            let ratio = ceiling == 1 ? c.clippedHigh : above / Double(max(1, sampleCount))
            return HistogramChannel(bins: c.bins, hdrBins: c.hdrBins, clippedHigh: c.clippedHigh,
                                    clippedCeiling: ratio, clippedLow: c.clippedLow)
        }
        return Histogram(binCount: binCount, sampleCount: sampleCount, canvas: canvas, roi: roi,
                         sampleSize: sampleSize, primaries: primaries, headroom: ceiling,
                         red: channel(red), green: channel(green), blue: channel(blue), luma: channel(luma))
    }
}
