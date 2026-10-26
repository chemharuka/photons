import AppKit
import SwiftUI
import PhotonsCore

// MARK: - the histogram card
//
// Four series (R, G, B, luma) drawn from the bins `RenderGraph` measured, the clipping ratios under
// them, and one click target: 过白 toggles the highlight warning on the canvas.
//
// **The plot has two segments** (2026-10-26): 0…1 on a linear code axis, then a fixed **30 pt per
// stop** exponential tail of 4 stops (`HistogramAxis`, `Histogram.maxStops`). Everything right of
// the dashed orange tick is light this panel cannot show: the tick is the display ceiling
// (`log2(headroom)` stops above white) and it comes from the *frame's* measurement, not from the
// screen the window happens to be on when the card redraws — so the plot and its ceiling always
// describe the same pixels. On an SDR screen the tick sits exactly on the SDR/tail boundary, which
// is the honest picture: no headroom at all.
//
// Decisions worth writing down:
//
//   · **The numbers come from `Histogram`, never from a second measurement.** The card formats
//     `HistogramChannel.clippedHigh` / `clippedCeiling` / `clippedLow` — the same values the CLI
//     prints and the tests assert — so "what the card says" and "what Core measured" cannot drift,
//     and `--ui-smoke` checks the identity by reformatting the frame's own histogram.
//   · **The histogram arrives with the frame, not from a render of its own.** `LoupeController`
//     asks for `RenderOptions.collectHistogram` on the same render that produces the picture
//     (one dispatch inside the frame's own command buffer) and hands the payload to the session
//     when the frame is presented. A card that rendered separately would double the cost of every
//     slider tick and could describe a different document than the photo next to it.
//   · **The numbers are of a *settled* camera (Q30).** While the loupe is panning or zooming the
//     controller skips the measurement and keeps the last one on screen — a plot that changes 10
//     times a second is unreadable anyway — then measures once, ~60 ms after the hand stops, on a
//     frame it does not present. So a stale plot here is the design, not a bug: `histogram` is
//     always "the last measurement of the picture that was on screen", and it never goes nil
//     mid-gesture (which is why `LoupeController.recordMeasurements` publishes only non-nil).
//   · **The region is the picture, not the canvas.** `RenderGraph`'s default ROI is the content
//     rect, so a `fit` frame's matte bars are not counted as black pixels (they used to be, and
//     削底 read tens of percent on a photo with no blacks at all).
//
// The card is AppKit rather than SwiftUI because it has to be *measurable*: the smoke reads the
// histogram it drew, the bin count of the path it built, the axis split and ceiling tick it laid
// out, and the exact text of the clipping percentages, then clicks 过白 through `mouseDown` — none
// of which a SwiftUI `Canvas` exposes.

public final class HistogramCardView: NSView {

    /// What the card is showing. Set from the frame the loupe presented (`nil` before the first).
    public var histogram: Histogram? {
        didSet {
            guard histogram != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The canvas overlay state, so the 过白 number can read as on/off (it is the same toggle).
    public var showsHighlightWarning: Bool = false {
        didSet { if showsHighlightWarning != oldValue { needsDisplay = true } }
    }

    /// What a click on 过白 does. The card itself changes nothing — the session owns the flag.
    public var onToggleHighlightWarning: (() -> Void)?

    // MARK: what the smoke reads back

    /// Channels whose path was actually built in the last `draw` (4 when there is a histogram).
    public private(set) var lastDrawnSeries = 0
    /// Bins the last path was built from, **both segments** (256 + 32 = 288 today).
    public private(set) var lastDrawnBins = 0
    /// How many of those were tail bins (0 without a histogram).
    public private(set) var lastDrawnHDRBins = 0
    /// The axis the last `draw` laid out: the 30 pt-per-stop rule and the SDR/tail split are asserted
    /// from this, not from pixels.
    public private(set) var lastAxis: HistogramAxis?
    /// Where the display-ceiling tick was painted, and what it means in stops above white.
    public private(set) var lastCeilingMarkerX: CGFloat = .nan
    public private(set) var lastCeilingStops: Double = 0
    /// The clipping percentages exactly as painted, in the luma channel (what the numbers mean).
    public private(set) var clipHighText = "—"
    public private(set) var clipLowText = "—"
    public private(set) var clipCeilingText = "—"
    public private(set) var clipHighTextByChannel: [String] = ["—", "—", "—", "—"]
    /// Where 过白 was painted, in view coordinates — so a synthetic click can aim at it.
    public private(set) var clipHighHitRect: NSRect = .zero
    public private(set) var clipLowHitRect: NSRect = .zero

    /// The card's own title is the inspector's (`card("直方图")`), so nothing is drawn twice: the
    /// plot starts at the top edge of this view.
    private let plotInsetTop: CGFloat = 0
    private let plotHeight: CGFloat = 58
    private let clipRowHeight: CGFloat = 15

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 104) }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityIdentifier("histogram-card")
        setAccessibilityLabel("直方图")
        setAccessibilityRole(.group)
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    // MARK: the toggle (one code path for a click and for the smoke)

    /// Same as clicking 过白: what the smoke calls to flip the warning without synthesising a click.
    public func toggleHighlightWarning() {
        showsHighlightWarning.toggle()
        onToggleHighlightWarning?()
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if clipHighHitRect.contains(point), event.clickCount == 1 {
            toggleHighlightWarning()
            return
        }
        super.mouseDown(with: event)
    }

    /// The pointer says "this is a control" over the number, and nothing anywhere else.
    public override func resetCursorRects() {
        if !clipHighHitRect.isEmpty { addCursorRect(clipHighHitRect, cursor: .pointingHand) }
    }

    // MARK: drawing

    public override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        guard bounds.width > 80, bounds.height > 60 else { return }

        let plot = NSRect(x: 0, y: plotInsetTop, width: bounds.width, height: plotHeight)
        let axis = HistogramAxis(plot: plot)
        lastAxis = axis
        lastCeilingMarkerX = .nan
        lastCeilingStops = 0
        drawAxis(axis)

        // The 4-series plot. RGB are filled, luma is the outline over them: the additive stack is
        // how a histogram reads as "where are my colours", and the luma line is the one number a
        // levels adjustment is actually aiming at. Both segments are drawn as **one** path per
        // series, so the curve crosses the SDR/tail boundary without a seam.
        lastDrawnSeries = 0
        lastDrawnBins = 0
        lastDrawnHDRBins = 0
        if let histogram {
            let bins = histogram.binCount
            let series: [(channel: Histogram.Channel, color: NSColor)] = [
                (.red, NSColor(srgbRed: 0.95, green: 0.20, blue: 0.24, alpha: 0.55)),
                (.green, NSColor(srgbRed: 0.24, green: 0.80, blue: 0.36, alpha: 0.55)),
                (.blue, NSColor(srgbRed: 0.28, green: 0.45, blue: 1.00, alpha: 0.55)),
            ]
            for (channel, color) in series {
                let c = histogram[channel]
                let points = HistogramCardFormat.points(c, binCount: bins, axis: axis,
                                                        peak: HistogramCardFormat.scalePeak(c))
                guard points.count > 2 else { continue }
                let path = NSBezierPath()
                path.move(to: points[0])
                for p in points.dropFirst() { path.line(to: p) }
                path.close()
                color.setFill()
                path.fill()
                lastDrawnSeries += 1
                lastDrawnBins = max(lastDrawnBins, points.count - 2)
                lastDrawnHDRBins = max(lastDrawnHDRBins, c.hdrBins.count)
            }
            let luma = histogram.luma
            let lumaPoints = HistogramCardFormat.points(luma, binCount: bins, axis: axis,
                                                       peak: HistogramCardFormat.scalePeak(luma))
            if lumaPoints.count > 2 {
                let outline = NSBezierPath()
                outline.move(to: lumaPoints[0])
                for p in lumaPoints.dropFirst() { outline.line(to: p) }
                outline.lineWidth = 1.2
                NSColor.labelColor.withAlphaComponent(0.85).setStroke()
                outline.stroke()
                lastDrawnSeries += 1
                lastDrawnBins = max(lastDrawnBins, lumaPoints.count - 2)
                lastDrawnHDRBins = max(lastDrawnHDRBins, luma.hdrBins.count)
            }
            // The 0.999 / 0.001 thresholds as tick marks: they are what the numbers below mean.
            drawThresholdTicks(in: axis)
            // The stop grid's numbers and the ceiling tick go on top of the curves — they are the
            // axis, and an axis must stay readable over a filled plot.
            drawStopLabels(axis)
            drawCeilingTick(axis, histogram: histogram)
        } else {
            drawStopLabels(axis)
            drawText("还没有可测的帧", at: CGPoint(x: plot.minX + 6, y: plot.midY - 6),
                     font: .systemFont(ofSize: 9), color: .tertiaryLabelColor)
        }

        drawClipRows(below: plot, histogram: histogram, in: bounds)
        _ = dirtyRect
    }

    /// The two-segment surface: a flat SDR bed, a tinted tail, the quarter-tone guides inside the
    /// SDR part only, and the display-white boundary between them.
    private func drawAxis(_ axis: HistogramAxis) {
        let plot = axis.plot
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: plot, xRadius: 4, yRadius: 4).fill()

        // The tail is a different kind of axis (exponential, and mostly outside the panel), so it is
        // drawn as a different surface — clipped to the card's own rounded rect so it does not draw
        // square corners over the bed.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: plot, xRadius: 4, yRadius: 4).addClip()
        NSColor.systemOrange.withAlphaComponent(0.055).setFill()
        NSRect(x: axis.sdrMaxX, y: plot.minY, width: axis.hdrWidth, height: plot.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Quarter-tone guides, as in every raw editor — inside the code segment, where they mean
        // "a quarter of the way from black to white".
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        for i in 1..<4 {
            let x = plot.minX + axis.sdrWidth * CGFloat(i) / 4
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.line(to: CGPoint(x: x, y: plot.maxY))
            line.lineWidth = 1
            line.stroke()
        }

        // Display white: the boundary the two scales meet at.
        NSColor.labelColor.withAlphaComponent(0.30).setStroke()
        let split = NSBezierPath()
        split.move(to: CGPoint(x: axis.sdrMaxX, y: plot.minY))
        split.line(to: CGPoint(x: axis.sdrMaxX, y: plot.maxY))
        split.lineWidth = 1
        split.stroke()

        // One line per stop of the tail.
        NSColor.labelColor.withAlphaComponent(0.07).setStroke()
        for stop in 1..<axis.stops {
            let x = axis.x(stopsAboveWhite: Double(stop))
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.line(to: CGPoint(x: x, y: plot.maxY))
            line.lineWidth = 1
            line.stroke()
        }
    }

    /// `+1 … +4` along the top of the tail: what the 30 pt steps mean. Skipped when the card is too
    /// narrow for the numbers to be legible (they would collide with each other).
    private func drawStopLabels(_ axis: HistogramAxis) {
        guard axis.stopWidth >= 18 else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                         .foregroundColor: NSColor.tertiaryLabelColor]
        for stop in 1...axis.stops {
            let text = "+\(stop)"
            let size = (text as NSString).size(withAttributes: attributes)
            let centre = axis.x(stopsAboveWhite: Double(stop))
            let x = min(max(centre - size.width / 2, axis.plot.minX), axis.plot.maxX - size.width - 1)
            (text as NSString).draw(at: CGPoint(x: x, y: axis.plot.minY + 1), withAttributes: attributes)
        }
    }

    /// The display ceiling: `log2(headroom)` stops above white, dashed, with the headroom spelled out.
    ///
    /// This is what the extra range is *for* — a picture that ends left of the tick is fully visible,
    /// one that runs past it is losing detail to the panel. On an SDR screen the tick lands on the
    /// SDR/tail boundary, which is the whole truth about that screen.
    private func drawCeilingTick(_ axis: HistogramAxis, histogram: Histogram) {
        let headroom = max(histogram.headroom, 1)
        let stops = log2(headroom)
        let x = axis.x(ceiling: headroom)
        lastCeilingMarkerX = x
        lastCeilingStops = stops

        let path = NSBezierPath()
        path.move(to: CGPoint(x: x, y: axis.plot.minY))
        path.line(to: CGPoint(x: x, y: axis.plot.maxY))
        path.lineWidth = 1
        path.setLineDash([3, 2], count: 2, phase: 0)
        NSColor.systemOrange.withAlphaComponent(0.9).setStroke()
        path.stroke()

        let text = String(format: "屏 %.2f×", headroom)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                         .foregroundColor: NSColor.systemOrange]
        let size = (text as NSString).size(withAttributes: attributes)
        var labelX = x + 3
        if labelX + size.width > axis.plot.maxX - 1 { labelX = axis.plot.maxX - size.width - 1 }
        if labelX < axis.plot.minX + 1 { labelX = axis.plot.minX + 1 }
        (text as NSString).draw(at: CGPoint(x: labelX, y: axis.plot.maxY - size.height - 1),
                                withAttributes: attributes)
    }

    /// Marks the two clipping thresholds on the x axis: `0.999` is one 8-bit code below white, so
    /// the tick sits at the very edge — drawn anyway, because "why is 1 % clipped" has to be visible.
    private func drawThresholdTicks(in axis: HistogramAxis) {
        let plot = axis.plot
        let highX = plot.minX + CGFloat(Histogram.clipHighThreshold) * axis.sdrWidth
        let lowX = plot.minX + CGFloat(Histogram.clipLowThreshold) * axis.sdrWidth
        NSColor.systemOrange.withAlphaComponent(0.7).setStroke()
        for x in [lowX, highX] {
            let line = NSBezierPath()
            line.move(to: CGPoint(x: min(max(x, plot.minX), plot.maxX), y: plot.minY))
            line.line(to: CGPoint(x: min(max(x, plot.minX), plot.maxX), y: plot.minY + 6))
            line.lineWidth = 1
            line.stroke()
        }
    }

    /// 过白 / 削顶 / 削底 plus the per-channel breakdown.
    ///
    /// 过白 (>SDR white) doubles as the highlight-warning switch, and it says so (an orange dot when
    /// the overlay is on). 削顶 is the *other* number now that the plot has a tail: it counts pixels
    /// at the display's own ceiling, i.e. the detail that was really lost (with `headroom = 1` the
    /// two coincide, which is why an SDR screen sees the familiar pair of numbers).
    private func drawClipRows(below plot: NSRect, histogram: Histogram?, in bounds: NSRect) {
        let y = plot.maxY + 5
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)

        clipHighText = HistogramCardFormat.clipHigh(histogram, .luma)
        clipCeilingText = HistogramCardFormat.clipCeiling(histogram, .luma)
        clipLowText = HistogramCardFormat.clipLow(histogram, .luma)
        clipHighTextByChannel = [Histogram.Channel.red, .green, .blue, .luma].map {
            HistogramCardFormat.clipHigh(histogram, $0)
        }

        let highLabel = drawText("过白", at: CGPoint(x: 0, y: y), font: labelFont,
                                 color: .secondaryLabelColor)
        let dotWidth: CGFloat = showsHighlightWarning ? 11 : 0
        if showsHighlightWarning {
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: highLabel.maxX + 2, y: y + 2, width: 5, height: 5)).fill()
        }
        let highNumber = drawText(clipHighText, at: CGPoint(x: highLabel.maxX + 3 + dotWidth, y: y),
                                  font: numberFont,
                                  color: showsHighlightWarning ? .systemOrange : .labelColor)
        // The hit area is padded: a 9.5 pt number is a mean target, and a 14 pt box is not.
        clipHighHitRect = NSRect(x: highLabel.minX, y: y - 2,
                                 width: highNumber.maxX - highLabel.minX, height: 14)

        let ceilLabel = drawText("削顶", at: CGPoint(x: highNumber.maxX + 12, y: y),
                                 font: labelFont, color: .secondaryLabelColor)
        let ceilNumber = drawText(clipCeilingText, at: CGPoint(x: ceilLabel.maxX + 3, y: y),
                                  font: numberFont,
                                  color: clipCeilingText == "0.0%" ? .labelColor : .systemRed)

        let lowLabel = drawText("削底", at: CGPoint(x: ceilNumber.maxX + 12, y: y),
                                font: labelFont, color: .secondaryLabelColor)
        let lowNumber = drawText(clipLowText, at: CGPoint(x: lowLabel.maxX + 3, y: y),
                                 font: numberFont, color: .labelColor)
        clipLowHitRect = NSRect(x: lowLabel.minX, y: y - 2,
                                width: lowNumber.maxX - lowLabel.minX, height: 14)

        // Per-channel line: R/G/B above-white shares, the numbers a white-balance tweak moves.
        let channelY = y + clipRowHeight
        var x = bounds.minX
        let channels: [(String, String, NSColor)] = [
            ("R", clipHighTextByChannel[0], NSColor(srgbRed: 0.95, green: 0.25, blue: 0.28, alpha: 1)),
            ("G", clipHighTextByChannel[1], NSColor(srgbRed: 0.22, green: 0.72, blue: 0.34, alpha: 1)),
            ("B", clipHighTextByChannel[2], NSColor(srgbRed: 0.30, green: 0.48, blue: 0.98, alpha: 1)),
        ]
        for (name, value, color) in channels {
            let nameRect = drawText(name, at: CGPoint(x: x, y: channelY),
                                    font: .systemFont(ofSize: 8, weight: .bold), color: color)
            let valueRect = drawText(value, at: CGPoint(x: nameRect.maxX + 2, y: channelY),
                                     font: .monospacedDigitSystemFont(ofSize: 8.5, weight: .regular),
                                     color: .tertiaryLabelColor)
            x = valueRect.maxX + 9
        }
        var total = ""
        if let histogram {
            total = "\(histogram.sampleCount / 1000)k px · "
                + "\(histogram.binCount)+\(histogram.hdrBinCount) bin"
        }
        if !total.isEmpty {
            drawText(total, at: CGPoint(x: x, y: channelY),
                     font: .monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                     color: .quaternaryLabelColor)
        }
    }

    @discardableResult
    private func drawText(_ text: String, at point: CGPoint, font: NSFont,
                          color: NSColor) -> NSRect {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: point, withAttributes: attributes)
        return NSRect(origin: point, size: size)
    }
}

// MARK: - SwiftUI host
//
// The inspector is SwiftUI; the card is AppKit. `NSViewRepresentable` is the seam, and it carries
// nothing but three values: the histogram, the overlay flag, and the toggle — no state lives in the
// adapter, so a SwiftUI re-render cannot lose the numbers.

public struct HistogramCard: View {
    @Bindable var session: CatalogSession

    public init(session: CatalogSession) {
        self.session = session
    }

    public var body: some View {
        HistogramCardHost(histogram: session.lastHistogram,
                          showsHighlightWarning: session.highlightWarning,
                          onToggle: { session.toggleHighlightWarning() })
            .frame(height: 104)
    }
}

private struct HistogramCardHost: NSViewRepresentable {
    var histogram: Histogram?
    var showsHighlightWarning: Bool
    var onToggle: () -> Void

    func makeNSView(context: Context) -> HistogramCardView {
        let view = HistogramCardView()
        view.histogram = histogram
        view.showsHighlightWarning = showsHighlightWarning
        view.onToggleHighlightWarning = onToggle
        return view
    }

    func updateNSView(_ view: HistogramCardView, context: Context) {
        view.histogram = histogram
        view.showsHighlightWarning = showsHighlightWarning
        view.onToggleHighlightWarning = onToggle
        view.needsDisplay = true
    }
}
