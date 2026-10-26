import AppKit
import SwiftUI
import PhotonsCore

// MARK: - the histogram card
//
// Four series (R, G, B, luma) drawn from the bins `RenderGraph.measureHistogram` measured, the
// clipping ratios under them, and one click target: 过白 toggles the highlight warning on the canvas.
//
// **The plot has two segments** (2026-10-26): 0…1 on a linear code axis, then a fixed **30 pt per
// stop** exponential tail of 4 stops (`HistogramAxis`, `Histogram.maxStops`) — 120 pt at the default
// scale, which a 364 pt card and even the inspector's 244 pt minimum can hold (244 − 60 pt of SDR =
// 184 pt of tail, so 30 pt/stop still fits; below that the stop scale shrinks, never the code axis).
// Everything right of the dashed orange tick is light this panel cannot show: the tick is the display
// ceiling (`log2(headroom)` stops above white) and it comes from the *measurement's* own headroom, not
// from whatever screen the window is on by the time the card redraws — so the plot and its ceiling
// always describe the same screen. On an SDR screen the tick sits exactly on the SDR/tail boundary,
// which is the honest picture: no headroom at all.
//
// Decisions worth writing down:
//
//   · **The numbers come from `Histogram`, never from a second measurement.** The card formats
//     `HistogramChannel.clippedHigh` / `clippedCeiling` / `clippedLow` — the same values the CLI
//     prints and the tests assert — so "what the card says" and "what Core measured" cannot drift,
//     and `--ui-smoke` checks the identity by reformatting the measurement.
//   · **The histogram is of the picture, not of the frame** (005, 2026-10-26). `LoupeController`
//     measures the whole photo once per edit (`RenderGraph.measureHistogram`: a whole-picture render
//     at thumbnail scale, counted before S4) and hands the payload to the session; a frame render no
//     longer measures anything, so panning and zooming cannot move a bin. That is why 「采样 N px」 is
//     the same number at fit, at 1:1 and at 400 %, and why the plot can show light above 1.0 on an
//     SDR panel.
//   · **A stale plot is the design.** The measurement is debounced ~120 ms behind an edit and no
//     gesture triggers one, so `histogram` is always "the last measurement of the document that is on
//     screen", and it never goes nil mid-gesture (which is why `LoupeController.recordMeasurements`
//     publishes only non-nil).
//   · **The region is the picture, always.** There is no ROI any more: the measurement renders the
//     whole picture at its own thumbnail scale, so a `fit` frame's matte bars cannot reach bin 0 and a
//     1:1 window cannot measure only the window.
//   · **The deleted footnote is now the pointer's reading** (010, 2026-10-26). The owner removed the
//     painted 「采样 N px · 直方图 256+256 档」 line; the space it left carries a hover readout instead
//     — the code (0–255) or the tail's stop (`+1.00 档 (2.0×)`, per "＋1 档 = 2×") on the left, and
//     that bin's R/G/B counts on the right, in the *same* 9.5 pt semibold digits as 过白/削顶. It is
//     driven by a tracking area over the plot only, and mouse-out clears it (nothing is painted).
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
            // A new measurement moves the counts under the pointer, so the readout's text follows it.
            if let hoverReading {
                hoverValueText = HistogramCardFormat.hoverValue(hoverReading)
                hoverCountText = HistogramCardFormat.hoverCounts(histogram, hoverReading)
                hoverRowText = HistogramCardFormat.hoverRowText(histogram, hoverReading)
            }
            needsDisplay = true
            updateAccessibilityHelp()
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
    /// Bins the last path was built from, **both segments** (256 + 256 = 512 today).
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

    // MARK: the card's one number font (2026-10-26)
    //
    // 过白 / 削顶 / 削底 and the hover readout are the *same* size and weight by the owner's request
    // ("lastNoteColor 的字体要更大，和过白/等保持一致"). One constant, used by both call sites, so
    // "the same" is an identity the tests can assert (`hoverNumberFont == clipNumberFont`) rather
    // than two literals that happen to agree today.
    public static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    public static var hoverNumberFont: NSFont { numberFont }
    public static var clipNumberFont: NSFont { numberFont }

    // MARK: what the smoke reads back about the hover readout (010)

    /// The bin the pointer is over, `nil` when the pointer is outside the plot (or has left the card).
    public private(set) var hoverReading: HistogramHoverReading?
    /// Exactly the strings the readout painted: the code / stop on the left, the R/G/B counts on the
    /// right. Both empty when nothing is being hovered — that emptiness *is* "the readout cleared".
    public private(set) var hoverValueText = ""
    public private(set) var hoverCountText = ""
    public private(set) var hoverValueRect: NSRect = .zero
    public private(set) var hoverCountRect: NSRect = .zero
    /// The union of the two rects: what the readout occupies. `.zero` when cleared.
    public private(set) var hoverReadoutRect: NSRect = .zero
    /// How many `draw`s painted a readout — the countable half of "moved out → nothing is painted".
    public private(set) var hoverPaintCount = 0
    /// The colour the last readout was painted with (contrast is recomputed from this, not stored).
    public private(set) var lastHoverColor: NSColor = .labelColor

    // MARK: the hover row (017: one line — `L 245 · R 1284 · G 1291 · B 1206`)

    /// The row while a bin is under the pointer, `nil` while idle (then the row is the three
    /// above-white percentages). One line, because the row's x axis *is* brightness: printing the
    /// same level once per channel was the 015 mistake.
    public private(set) var hoverRowText: String?
    /// Where that line was painted — `.zero` while the row is the percentages.
    public private(set) var hoverRowRect: NSRect = .zero
    /// The strings the channel row painted last `draw`: the three above-white shares while idle, the
    /// single hover line while a bin is under the pointer.
    public private(set) var channelRowTexts: [String] = ["—", "—", "—"]
    /// The row as one string (idle: `R 1.0% G 1.0% B 1.0%`; hovering: `L 128 · R 1284 · G 1291 · B 1206`).
    public private(set) var channelRowText = ""

    /// Worst-case WCAG ratio of the readout colour on the card's own backdrop band.
    public var hoverContrast: Double {
        HistogramCardReadability.worstContrast(of: lastHoverColor, isDark: lastAppearanceIsDark)
    }

    // MARK: what the smoke reads back about the two *legibility* labels (2026-10-26)

    /// Right edge of the last channel percentage (R/G/B), i.e. how wide the channel row really is.
    public private(set) var channelRowWidth: CGFloat = 0
    /// The percentage colour of the last `draw`. The smoke recomputes its contrast from this rather
    /// than trusting a stored ratio.
    public private(set) var lastPercentColor: NSColor = .labelColor
    /// Which appearance those colours were resolved for (`effectiveAppearance` in `draw`).
    public private(set) var lastAppearanceIsDark = false

    /// Worst-case WCAG ratio of the percentage colour on the card's own backdrop.
    public var percentContrast: Double {
        HistogramCardReadability.worstContrast(of: lastPercentColor, isDark: lastAppearanceIsDark)
    }

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
        updateAccessibilityHelp()
    }

    /// VoiceOver still hears how the x axis is binned. The painted footnote that used to carry this
    /// sentence was removed at the owner's request (2026-10-26) — it was "采样 N px · 直方图 256+N 档",
    /// and the owner does not want that line on screen — so the binning is now spoken, not painted.
    private func updateAccessibilityHelp() {
        let bins = histogram?.binCount ?? 256
        let tail = histogram?.hdrBinCount ?? Histogram.hdrBinCount
        setAccessibilityHelp("直方图：R/G/B/亮度四组曲线；横轴 \(bins) 档 SDR 码值 + \(tail) 档高光尾。鼠标悬停读出该档的码值（尾段为 +N 档 = 2^N 倍）与该箱 R/G/B 样本数，同时把通道行换成 R/G/B 三份该处亮度（SDR 区为 0–255 码值，尾段为 +x.x 档）。")
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

    // MARK: the pointer's reading (010)
    //
    // The readout is driven by a **tracking area over the plot only** (not the whole card, not the
    // clip rows), so "inside the plot" is the definition of "there is something to read" and leaving
    // it is what clears the line. `.inVisibleRect` is deliberately *not* used: it would make the
    // tracked rect the whole view and hovering the 过白 row would invent a reading for a bin nobody
    // pointed at. `updateTrackingAreas` instead rebuilds the rect from `bounds` on every call —
    // remove first, add second, always exactly one area — because SwiftUI re-lays the card out
    // whenever the inspector resizes, and stacking areas would deliver the same move N times.

    private var hoverTrackingArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        let plot = NSRect(x: 0, y: plotInsetTop, width: bounds.width, height: plotHeight)
        guard plot.width > 1, plot.height > 1 else { return }
        let area = NSTrackingArea(rect: plot,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    /// A tracking area with `.mouseMoved` is only delivered while the window accepts move events;
    /// nothing in this app depends on the flag being false, and the readout depends on it being true.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    /// The plot rect the axis is laid out in *right now* (the same arithmetic `draw` uses), or `nil`
    /// when the card is too small to have one.
    private var liveAxis: HistogramAxis? {
        guard bounds.width > 80, bounds.height > 60 else { return nil }
        return HistogramAxis(plot: NSRect(x: 0, y: plotInsetTop, width: bounds.width, height: plotHeight))
    }

    public override func mouseMoved(with event: NSEvent) {
        updateHoverReadout(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseEntered(with event: NSEvent) {
        updateHoverReadout(at: convert(event.locationInWindow, from: nil))
    }

    /// Off the plot (or off the card, which `.activeInKeyWindow` reports the same way) → nothing.
    public override func mouseExited(with event: NSEvent) {
        clearHoverReadout()
    }

    /// Read the bin under `point` (view coordinates) and repaint. Public so the smoke can drive the
    /// readout without a live cursor — it is the same call `mouseMoved` makes.
    public func updateHoverReadout(at point: CGPoint) {
        guard let axis = liveAxis, axis.plot.contains(point) else {
            clearHoverReadout()
            return
        }
        let reading = axis.hoverReading(atX: point.x, sdrBins: histogram?.binCount ?? 256)
        guard reading != hoverReading else { return }
        hoverReading = reading
        hoverValueText = HistogramCardFormat.hoverValue(reading)
        hoverCountText = HistogramCardFormat.hoverCounts(histogram, reading)
        hoverRowText = HistogramCardFormat.hoverRowText(histogram, reading)
        needsDisplay = true
    }

    /// Drop the reading: the line goes blank, the percentages row comes back, and the readback rects
    /// go to `.zero` (what the smoke counts as "cleared").
    public func clearHoverReadout() {
        guard hoverReading != nil || !hoverValueText.isEmpty || !hoverReadoutRect.isEmpty
                || hoverRowText != nil else { return }
        hoverReading = nil
        hoverValueText = ""
        hoverCountText = ""
        hoverRowText = nil
        hoverRowRect = .zero
        hoverValueRect = .zero
        hoverCountRect = .zero
        hoverReadoutRect = .zero
        needsDisplay = true
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
        drawHoverReadoutRow(below: plot, histogram: histogram, in: bounds)
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
        guard axis.stopWidth >= 16 else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                         .foregroundColor: NSColor.secondaryLabelColor]
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
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                         .foregroundColor: NSColor.systemOrange]
        let size = (text as NSString).size(withAttributes: attributes)
        var labelX = x + 3
        if labelX + size.width > axis.plot.maxX - 1 { labelX = axis.plot.maxX - size.width - 1 }
        if labelX < axis.plot.minX + 1 { labelX = axis.plot.minX + 1 }
        let labelY = axis.plot.maxY - size.height - 1
        // A chip behind the number: the tick is drawn over the distribution, and an orange 8 pt label
        // on top of a filled curve is unreadable exactly where it matters (a spiky highlight).
        NSColor.labelColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: NSRect(x: labelX - 1.5, y: labelY - 0.5,
                                        width: size.width + 3, height: size.height + 1),
                     xRadius: 2, yRadius: 2).fill()
        (text as NSString).draw(at: CGPoint(x: labelX, y: labelY), withAttributes: attributes)
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
    /// at or above the ceiling the measurement was taken for, i.e. the detail *this* screen would
    /// throw away (with `headroom = 1` that is light above white, so an SDR screen sees the familiar
    /// pair of numbers). The bins themselves do not depend on the panel — that is the whole point of
    /// measuring before S4 — so 削顶 is the one number that moves when the display does.
    private func drawClipRows(below plot: NSRect, histogram: Histogram?, in bounds: NSRect) {
        let y = plot.maxY + 5
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        let numberFont = Self.numberFont

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
        //
        // While a bin is under the pointer this row becomes three **fixed slots** (015):
        // `R 128 G 128 B 128` on the code segment, `R +0.8 G +0.8 B +0.8` on the tail. The letters
        // are pinned to their slots' left edges and the numbers right-aligned to their slots' right
        // edges, so neither position is a function of the text — that fixed layout is the whole
        // point (the owner: "不要出现 G B 的位置随着内容变化乱动").
        //
        // The face is the card's own `numberFont` (9.5 pt semibold), the same size as 过白/削顶 above
        // it (the owner: "字号要更大，和其他 UI 匹配"). On leave the row goes back to the three
        // above-white percentages in their 8.5 pt face, which is why the row's own width is measured
        // per state (`channelRowWidth`) and the footnote row below steps down a little further while
        // the taller face is in use (`channelRowStride`).
        //
        // The percentages used to be `.tertiaryLabelColor`: resolved over this card's own backdrop
        // that is 1.86 : 1 in aqua and 2.26 : 1 in darkAqua — invisible next to the bold channel
        // letter it belongs to. `HistogramCardReadability` picks an *opaque* colour per appearance
        // that clears 4.5 : 1 at the worst end of the material's own grey band (see that type).
        let channelY = y + clipRowHeight
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        lastAppearanceIsDark = dark
        lastPercentColor = HistogramCardReadability.percentColor(isDark: dark)
        // Re-derived from the live reading every draw: a new measurement or a new bin can never leave
        // the previous one's numbers on screen.
        hoverRowText = HistogramCardFormat.hoverRowText(histogram, hoverReading)
        hoverRowRect = .zero
        if let rowText = hoverRowText {
            paintHoverRow(rowText, atY: channelY)
        } else {
            var x = bounds.minX
            for (index, value) in clipHighTextByChannel.prefix(3).enumerated() {
                let nameRect = drawText(Self.channelLetters[index],
                                        at: CGPoint(x: x, y: channelY),
                                        font: .systemFont(ofSize: 8, weight: .bold),
                                        color: Self.channelNameColors[index])
                let valueRect = drawText(value, at: CGPoint(x: nameRect.maxX + 2, y: channelY),
                                         font: HistogramCardReadability.percentFont,
                                         color: lastPercentColor)
                x = valueRect.maxX + 9
            }
            channelRowWidth = x - 9 - bounds.minX
            channelRowTexts = Array(clipHighTextByChannel.prefix(3))
            channelRowText = zip(Self.channelLetters, channelRowTexts)
                .map { "\($0) \($1)" }.joined(separator: " ")
        }
    }

    /// The channel letters' colours: the same three the idle percentage row paints (a red R next to
    /// a red curve, and so on), so the row reads the same in both states.
    /// The three channel letters, in row order — the idle percentages row and the hover row share them.
    static let channelLetters = ["R", "G", "B"]

    private static let channelNameColors: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.25, blue: 0.28, alpha: 1),
        NSColor(srgbRed: 0.22, green: 0.72, blue: 0.34, alpha: 1),
        NSColor(srgbRed: 0.30, green: 0.48, blue: 0.98, alpha: 1),
    ]

    /// 017: paint the hover row as one left-aligned line in the card's number face.
    ///
    /// The line is `L <level> · R n · G n · B n`, so its width changes with the counts — that is
    /// expected now: there is no second column to keep still.
    private func paintHoverRow(_ text: String, atY y: CGFloat) {
        let rect = drawText(text, at: CGPoint(x: bounds.minX, y: y),
                            font: Self.numberFont, color: lastPercentColor)
        hoverRowRect = rect
        channelRowTexts = [text]
        channelRowText = text
        channelRowWidth = rect.width
    }

    /// Vertical distance from the percentages row's top to the footnote row's top.
    ///
    /// The percentage row's own slot is `clipRowHeight` (15 pt, an 8.5 pt face). While it carries the
    /// 9.5 pt brightness readout the next row steps down 2 pt, so the two labels keep a real gap
    /// instead of sharing a line box (at 244 × 104 the card has the room: the footnote still ends
    /// above `bounds.maxY`).
    private var channelRowStride: CGFloat {
        hoverRowText == nil ? clipRowHeight : clipRowHeight + 2
    }

    // MARK: the hover readout line (010)

    /// The line the owner deleted as a footnote, now carrying the pointer's own reading: **left** the
    /// code (or the tail's stop), **right** that bin's R/G/B counts.
    ///
    /// Left/right rather than one sentence because the two halves answer different questions
    /// ("what brightness is here?" / "how much of the picture is here?"), and because splitting them
    /// keeps either half from being truncated at the inspector's 244 pt card: the stop
    /// `+1.00 档 (2.0×)` is ~74 pt and `R 12841 · G 12903 · B 12688` ~120 pt, so both fit on one row
    /// with room for the gap. The row only exists while `hoverReading` is set — otherwise nothing is
    /// painted there at all (that is the "cleared" state, and the rects go to `.zero`).
    ///
    /// The font is `Self.numberFont` — the *same* 9.5 pt semibold monospaced digits as 过白/削顶/削底,
    /// by the owner's request; the colour is an opaque `HistogramCardReadability.readoutColor`, which
    /// is what makes ≥ 4.5 : 1 a measured fact rather than a hope.
    private func drawHoverReadoutRow(below plot: NSRect, histogram: Histogram?, in bounds: NSRect) {
        guard let reading = hoverReading else {
            hoverValueText = ""
            hoverCountText = ""
            hoverValueRect = .zero
            hoverCountRect = .zero
            hoverReadoutRect = .zero
            return
        }
        let font = Self.numberFont
        let color = HistogramCardReadability.readoutColor(isDark: lastAppearanceIsDark)
        lastHoverColor = color
        // Re-derive from the current measurement: a redraw after a new measurement must not show the
        // previous picture's counts next to this picture's plot.
        hoverValueText = HistogramCardFormat.hoverValue(reading)
        hoverCountText = HistogramCardFormat.hoverCounts(histogram, reading)

        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let valueSize = (hoverValueText as NSString).size(withAttributes: attributes)
        let countSize = (hoverCountText as NSString).size(withAttributes: attributes)
        let rowTop = plot.maxY + 5 + clipRowHeight + channelRowStride
        // Half a point of slack: the row's line box ends exactly at the card's bottom edge otherwise.
        let y = min(rowTop, bounds.maxY - max(valueSize.height, countSize.height) - 0.5)

        var countX = bounds.maxX - countSize.width
        let valueX = bounds.minX
        if countX < valueX + valueSize.width + 6 { countX = valueX + valueSize.width + 6 }

        (hoverValueText as NSString).draw(at: CGPoint(x: valueX, y: y), withAttributes: attributes)
        (hoverCountText as NSString).draw(at: CGPoint(x: countX, y: y), withAttributes: attributes)
        hoverValueRect = NSRect(origin: CGPoint(x: valueX, y: y), size: valueSize)
        hoverCountRect = NSRect(origin: CGPoint(x: countX, y: y), size: countSize)
        hoverReadoutRect = hoverValueRect.union(hoverCountRect)
        hoverPaintCount += 1
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

// MARK: - the two labels that had to become readable
//
// The complaint (2026-10-26): the per-channel percentages were "grey, not obvious" and the
// sample/bin footnote "even blacker, invisible". Both were *semantic* label colours, and those are
// alpha tints of black/white — 26 % and 10 % — so they read as texture, not as text:
//
// | | aqua (over #ECECEC) | darkAqua (over #1E1E1E) |
// |---|---|---|
// | `.tertiaryLabelColor` (percentages) | **1.86 : 1** | **2.26 : 1** |
// | `.quaternaryLabelColor` (footnote)  | **1.24 : 1** | **1.34 : 1** |
//
// WCAG 2.1 SC 1.4.3 wants 4.5 : 1 for text this size, so neither was near it. The fix is a pair of
// **opaque** colours resolved per appearance, and the arithmetic that proves them is here rather
// than in a comment: the unit test and `--ui-smoke` both recompute the ratio from the colours the
// card actually drew with.
//
// The card paints nothing of its own behind these labels. It is an `NSView` inside the inspector's
// `card(_:)`, whose fill is `.regularMaterial` over `NSColor.windowBackgroundColor` (set on the
// window by `EditorWindowController`). A material can only lift a backdrop toward white, so the
// backdrop's grey level is *bounded* by the window background on one side and white on the other.
// The colours below therefore have to clear 4.5 : 1 at the **worst** end of that band — the darker
// one in aqua, the lighter one in darkAqua — not at the middle of it, which is why the numbers here
// (9.9 and 6.1 in aqua) look stronger than the 4.5 they promise.
public enum HistogramCardReadability {

    /// WCAG 2.1 SC 1.4.3, normal-size text. The card's labels are 8–8.5 pt, so this is the floor.
    public static let minimumRatio: Double = 4.5

    /// The sRGB grey levels the card's backdrop can resolve to, per appearance.
    ///
    /// aqua: `windowBackgroundColor` `#ECECEC` (0.925) up to the material's white.
    /// darkAqua: `#1E1E1E` (0.117) up to the material's own grey, `#333333` (0.200).
    public static func backdropGreys(isDark: Bool) -> (low: Double, high: Double) {
        isDark ? (0.117, 0.200) : (0.925, 1.000)
    }

    // MARK: the colours

    /// The R/G/B percentages: a strong neutral, one step below the card's primary numbers.
    public static func percentColor(isDark: Bool) -> NSColor {
        isDark ? NSColor(srgbRed: 0.82, green: 0.82, blue: 0.83, alpha: 1)
               : NSColor(srgbRed: 0.22, green: 0.22, blue: 0.23, alpha: 1)
    }

    /// The hover readout (010): a neutral that is *quieter* than the percentages but still opaque and
    /// still ≥ 4.5 : 1 at the worst end of the band (measured: 6.1 : 1 in aqua, 6.3 : 1 in darkAqua).
    /// `.secondaryLabelColor` would have been the obvious choice and is not: it is a 50 % tint, so
    /// over this backdrop it lands near 4 : 1 — under the floor the card promises. Being opaque is
    /// also what keeps a filled plot from showing through the glyphs.
    public static func readoutColor(isDark: Bool) -> NSColor {
        isDark ? NSColor(srgbRed: 0.72, green: 0.72, blue: 0.73, alpha: 1)
               : NSColor(srgbRed: 0.34, green: 0.34, blue: 0.35, alpha: 1)
    }

    // MARK: the fonts (unchanged sizes — nothing here may shrink)

    /// 8.5 pt, monospaced digits: the size the percentages already had. They are a column of numbers
    /// under each other's channel letters, so the digits must not jitter as the value changes.
    public static var percentFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
    }

    // MARK: the arithmetic (WCAG 2.1, sRGB-linearised)

    /// One sRGB channel, linearised.
    public static func linear(_ component: CGFloat) -> Double {
        let v = Double(component)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance of an sRGB colour (alpha is the caller's problem: these colours are
    /// opaque by construction, and the *old* ones are composited by the test before measuring).
    public static func relativeLuminance(of color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) else { return .nan }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }

    /// Contrast ratio of `color` against a neutral backdrop of the given sRGB grey level.
    public static func contrast(of color: NSColor, overGrey grey: Double) -> Double {
        let a = relativeLuminance(of: color) + 0.05
        let b = linear(CGFloat(grey)) + 0.05
        return max(a, b) / min(a, b)
    }

    /// The ratio that has to hold: the worst end of the backdrop band for this appearance.
    public static func worstContrast(of color: NSColor, isDark: Bool) -> Double {
        let band = backdropGreys(isDark: isDark)
        return [band.low, band.high].map { contrast(of: color, overGrey: $0) }.min() ?? 0
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
