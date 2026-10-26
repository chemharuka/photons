import Foundation
import PhotonsCore

// MARK: - photonsctl histogram
//
// The acceptance harness for `RenderOptions.collectHistogram`: render one document, print the four
// series and the clipping ratios. Deliberately `wantsPixels: false` — the histogram does not need the
// frame readback, and running it that way is the proof: the measurement comes off the GPU's own
// reduced grid, not off the pixels the caller would otherwise be handed (32 MB at 4.10 Mpx).
//
// Two machine forms, because two consumers exist:
//   · `--json`  — one line, bins base64 (little-endian UInt32 each), the form a script or a UI reads.
//   · `--csv`   — four lines of comma-separated counts, the form a person pipes into a plot.
// The default text output is the same base64 as JSON plus the human-readable summary.

// `--roi` is gone with the ROI itself (2026-10-26): a histogram is of the picture now, at the
// picture's own thumbnail scale, and a sub-rectangle of one would be a second measurement with no
// consumer. The flag is refused in `cmdHistogram` rather than silently ignored.

/// Four bytes per bin, little-endian, base64 — 1.4 KB for 256 bins instead of a 1.1 KB decimal list
/// that has to be re-parsed with a split.
func base64HistogramBins(_ bins: [Int]) -> String {
    var data = Data(capacity: bins.count * 4)
    for b in bins {
        var word = UInt32(max(0, b)).littleEndian
        withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
    }
    return data.base64EncodedString()
}

func csvHistogramBins(_ bins: [Int]) -> String {
    bins.map(String.init).joined(separator: ",")
}

func percent(_ v: Double) -> String { String(format: "%.3f%%", v * 100) }

func cmdHistogram(_ a: Args) throws {
    let url = requireRaw(a)
    let scale = a.value("--scale").flatMap(Double.init) ?? 1
    let display = displayOptions(a)
    let bins = a.value("--bins").flatMap(Int.init) ?? 256
    let (edits, names) = try loadEdits(a)
    let edit = edits[0]

    let probe = try makeDecoder().probe(url)
    let version = a.value("--version") ?? probe.defaultVersion
    let fileHash = try FileDigest.sha256(of: url)
    let decodeScale = a.value("--decode-scale").flatMap(Float.init) ?? decodeScaleLadder(scale)
    let (decoded, identity) = try decodeForRender(a, url: url, decodeScale: decodeScale,
                                                 fileHash: fileHash, version: version)

    let graph = try RenderGraph(input: RenderInput(image: decoded, identity: identity, sourceURL: url))
    // The measurement is of the **picture**, at its own thumbnail scale: `--scale` and `--roi` no
    // longer mean anything here (they described the frame the camera drew, which the histogram no
    // longer is). A `--roi` is refused rather than ignored.
    if a.has("--roi") { die("--roi 不再支持：直方图现在固定测整幅图（全图缩略渲染）") }
    let t0 = CFAbsoluteTimeGetCurrent()
    let histogram = try graph.measureHistogram(edit, bins: bins, headroom: display.headroom)
    let measureMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    let whole = ImageRect(x: 0, y: 0, width: histogram.canvas.width, height: histogram.canvas.height)
    let roiLabel = histogram.roi == whole ? "whole picture" : histogram.roi.keyString

    if a.has("--json") {
        var clipping: [String: Any] = [:]
        var bins64: [String: Any] = [:]
        var hdr64: [String: Any] = [:]
        for channel in Histogram.Channel.allCases {
            let c = histogram[channel]
            clipping[channel.rawValue] = ["high": c.clippedHigh, "ceiling": c.clippedCeiling,
                                          "low": c.clippedLow]
            bins64[channel.rawValue] = base64HistogramBins(c.bins)
            hdr64[channel.rawValue] = base64HistogramBins(c.hdrBins)
        }
        note(jsonLine([
            "raw": url.lastPathComponent,
            "edit": names[0],
            "scale": scale,
            "primaries": display.primaries.rawValue,
            "bitDepth": display.bitDepth,
            // The frame's own S4 ceiling: the tail is measured against it, and the card's display
            // tick sits at log2(headroom) stops above white.
            "headroom": histogram.headroom,
            "canvas": ["width": histogram.canvas.width, "height": histogram.canvas.height],
            "roi": ["x": histogram.roi.x, "y": histogram.roi.y,
                    "width": histogram.roi.width, "height": histogram.roi.height],
            "sampleSize": ["width": histogram.sampleSize.width,
                           "height": histogram.sampleSize.height],
            "sampleCount": histogram.sampleCount,
            "sampleFraction": histogram.sampleFraction,
            "binCount": histogram.binCount,
            "axis": ["sdrBins": histogram.binCount,
                     "maxStops": Histogram.maxStops,
                     "hdrBinsPerStop": Histogram.hdrBinsPerStop,
                     "hdrBinCount": histogram.hdrBinCount],
            "clipping": clipping,
            "base64": bins64,
            "hdrBase64": hdr64,
            "measureMilliseconds": measureMs,
        ]))
        return
    }

    if a.has("--csv") {
        for channel in Histogram.Channel.allCases {
            note("\(channel.rawValue),\(csvHistogramBins(histogram[channel].bins))")
            note("\(channel.rawValue)-hdr,\(csvHistogramBins(histogram[channel].hdrBins))")
        }
        err(String(format: "canvas %d×%d  roi %@  samples %d (%.1f%%)  bins %d+%d  headroom %.3f  measure %.2f ms",
                   histogram.canvas.width, histogram.canvas.height, roiLabel,
                   histogram.sampleCount, histogram.sampleFraction * 100,
                   histogram.binCount, histogram.hdrBinCount, histogram.headroom,
                   measureMs))
        for channel in Histogram.Channel.allCases {
            let c = histogram[channel]
            err("       \(channel.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0))"
                + "high \(percent(c.clippedHigh))  ceil \(percent(c.clippedCeiling))"
                + "  low \(percent(c.clippedLow))")
        }
        return
    }

    note("source     \(url.lastPathComponent)  v\(decoded.decoderVersion)  edit \(names[0])")
    note("canvas     \(histogram.canvas.width)×\(histogram.canvas.height)"
         + "  \(display.primaries.displayName) \(display.bitDepth)-bit")
    note("roi        \(roiLabel)")
    note(String(format: "sample     %d of %d pixels (%.1f%%) on a %d×%d grid, %d+%d bins",
                histogram.sampleCount, histogram.roi.area, histogram.sampleFraction * 100,
                histogram.sampleSize.width, histogram.sampleSize.height,
                histogram.binCount, histogram.hdrBinCount))
    note(String(format: "axis       SDR 0…1 on %d code bins, then %.0f stops above white "
                + "on %d bins of 1/%.0f stop (display ceiling %.3f× = %+.2f EV)",
                histogram.binCount, Double(Histogram.maxStops), histogram.hdrBinCount,
                Double(Histogram.hdrBinsPerStop), histogram.headroom, histogram.displayStops))
    for channel in Histogram.Channel.allCases {
        let c = histogram[channel]
        note("clip \(channel.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0))"
             + "high \(percent(c.clippedHigh))  ceil \(percent(c.clippedCeiling))"
             + "  low \(percent(c.clippedLow))")
    }
    for channel in Histogram.Channel.allCases {
        note("\(channel.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
             + base64HistogramBins(histogram[channel].bins))
    }
    for channel in Histogram.Channel.allCases {
        let label = (channel.rawValue + "-hdr").padding(toLength: 10, withPad: " ", startingAt: 0)
        note(label + base64HistogramBins(histogram[channel].hdrBins))
    }
    note(String(format: "measure    %.2f ms (thumbnail render + readback + %d bins × 4 channels)",
         measureMs, histogram.binCount + histogram.hdrBinCount))
}