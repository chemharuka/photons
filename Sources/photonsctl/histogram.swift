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

    // ---- `--from-frame` (027, experimental) ---------------------------------------------------
    //
    // The real-time path: measure the frame S4 **already wrote** instead of rendering the picture a
    // second time. The numbers above stay the reference — the same picture, the shot the card shows
    // when an edit settles — so this mode's job is to report the difference between the two and the
    // cost of the one a slider drag can afford.
    if a.has("--from-frame") {
        let repeats = max(1, a.value("--repeat").flatMap(Int.init) ?? 20)
        // Diagnostics go to stderr when stdout is a machine form, so `--json --from-frame` still
        // parses.
        let emit: (String) -> Void = (a.has("--json") || a.has("--csv")) ? err : note
        func stats(_ xs: [Double]) -> String {
            let s = xs.sorted()
            let mean = s.reduce(0, +) / Double(s.count)
            let p50 = s[s.count / 2]
            let p95 = s[min(s.count - 1, Int(Double(s.count) * 0.95))]
            return String(format: "mean %.2f / p50 %.2f / p95 %.2f / max %.2f ms",
                          mean, p50, p95, s.last ?? 0)
        }
        let picture = histogram.canvas
        let frameOptions = RenderOptions(canvas: picture, scale: 1, display: display,
                                         useCache: false, wantsPixels: false,
                                         collectHistogram: false)
        let tRender = CFAbsoluteTimeGetCurrent()
        let frame = try graph.render(edit, options: frameOptions)
        let renderMs = (CFAbsoluteTimeGetCurrent() - tRender) * 1000
        guard let texture = frame.output else { die("the frame render produced no texture") }
        defer { graph.recycle(output: texture) }

        // The reference the same way: `repeats` full shipped measurements (each one its own thumbnail
        // render — `measureHistogram` uses no cache), so the two numbers are warm on both sides and
        // can be subtracted. The single cold number printed at the top of this output includes the
        // runtime compilation of the Metal kernels.
        var oldWall: [Double] = []
        for _ in 0..<repeats {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = try graph.measureHistogram(edit, bins: bins, headroom: display.headroom)
            oldWall.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        emit("shipped    \(stats(oldWall))  (\(repeats) warm measurements, each a thumbnail render)")

        // The canvas *is* the picture here (it was sized from `histogram.canvas`), so nothing is
        // letterboxed and the whole texture is the measurement's domain.
        let whole = ImageRect(x: 0, y: 0, width: texture.width, height: texture.height)
        // One warm-up call, excluded from the distribution: the first use of a kernel file in this
        // process compiles it (`makeLibrary(source:)`), which costs ~135 ms and is paid once at app
        // launch, not per frame.
        let coldStart = CFAbsoluteTimeGetCurrent()
        let cold = try graph.measureFrameHistogram(fromFrame: texture, edit: edit, bins: bins,
                                                   content: whole, primaries: display.primaries,
                                                   headroom: display.headroom)
        let coldMs = (CFAbsoluteTimeGetCurrent() - coldStart) * 1000
        let coldGpu = cold.cost.gpuMilliseconds
        var wall: [Double] = [], gpu: [Double] = [], cpu: [Double] = []
        var digests = Set<String>()
        var live: Histogram?
        var grid = ImageSize(width: 0, height: 0)
        var readBytes = 0
        for _ in 0..<repeats {
            let m = try graph.measureFrameHistogram(fromFrame: texture, edit: edit, bins: bins,
                                                    content: whole,
                                                    primaries: display.primaries,
                                                    headroom: display.headroom)
            wall.append(m.cost.wallMilliseconds)
            gpu.append(m.cost.gpuMilliseconds)
            cpu.append(m.cost.cpuMilliseconds)
            digests.insert(m.histogram.binsDigest())
            live = m.histogram
            grid = m.cost.sampleSize
            readBytes = m.cost.readbackBytes
        }
        emit("frame      canvas \(texture.width)×\(texture.height) at scale 1, rendered in "
             + String(format: "%.2f ms (paid by the frame, excluded below)", renderMs))
        emit("sample     \(grid.keyString) = \(grid.pixelCount) px, \(readBytes) B read back "
             + "(the frame itself is \(texture.width * texture.height * 8) B)")
        emit("measure    \(stats(wall))")
        emit("           downsample pass \(stats(gpu))")
        emit("           CPU binning \(stats(cpu))")
        emit(String(format: "           first call (compiles histogram_sample.metal in-process): "
                    + "%.1f ms, of which the pass was %.2f ms", coldMs, coldGpu))
        emit("repeat     \(repeats) calls, \(digests.count) digest "
             + (digests.count == 1 ? "(byte-identical every call)" : "(NOT deterministic)"))

        if let live {
            func binDiff(_ a: [Int], _ b: [Int]) -> (within: Int, bins: Int, worst: Double, worstBin: Int) {
                // Fractions of each side's own sample: the two grids count different pixel counts.
                let nA = Double(max(a.reduce(0, +), 1))
                let nB = Double(max(b.reduce(0, +), 1))
                var within = 0, worst = 0.0, worstBin = 0
                let bins = min(a.count, b.count)
                for i in 0..<bins {
                    let d = abs(Double(a[i]) / nA - Double(b[i]) / nB)
                    if d <= 0.005 { within += 1 }
                    if d > worst { worst = d; worstBin = i }
                }
                return (within, bins, worst, worstBin)
            }
            emit("vs old     the shipped measurement of the same picture, per channel")
            for channel in Histogram.Channel.allCases {
                let d = binDiff(live[channel].bins, histogram[channel].bins)
                let t = binDiff(live[channel].hdrBins, histogram[channel].hdrBins)
                let name = channel.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)
                emit(String(format: "           %@  %d/%d SDR bins within 0.5 %% of the sample, "
                            + "worst bin %d = %.4f %%, %d/%d tail bins differ",
                            name, d.within, d.bins, d.worstBin, d.worst * 100,
                            t.bins - t.within, t.bins))
            }
            emit(String(format: "           clippedHigh Δ %.4f (luma), sampleFraction %.2f %% of the "
                        + "picture", abs(live.luma.clippedHigh - histogram.luma.clippedHigh),
                        live.sampleFraction * 100))
        }
        return
    }
}