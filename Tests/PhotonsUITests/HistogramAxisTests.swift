import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// The histogram card's **axis** (068): SDR codes on the left **half**, the 4-stop exponential tail on
/// the right half, with the display ceiling marked at `log2(headroom)` stops.
///
/// These are geometry claims, so they are tested as arithmetic on `HistogramAxis` rather than by
/// reading pixels: the smoke asserts the same numbers on a laid-out card (`lastAxis`), and this file
/// asserts them without a window at all.
///
/// 068 changed the *proportion only*: the tail used to be a fixed 120 pt (30 pt/stop × 4), which on a
/// 400 pt card is 70/30. The owner asked for 50/50 (「左侧 50% 是 sdr，右侧 50% 是 hdr」), so the split
/// is the input and `stopWidth` follows from it. The bins did not move: SDR is 256 and the tail was
/// already 4 × 64 = 256.
final class HistogramAxisTests: XCTestCase {

    private let plot = NSRect(x: 0, y: 0, width: 300, height: 58)

    /// The widths the card is actually laid out at in the app: the inspector's minimum (244), a narrow
    /// panel, the default card, and a wide one.
    private let shippedWidths: [CGFloat] = [240, 320, 400, 560]

    // MARK: - the split

    /// **The claim of 068**: both halves are half the plot, exactly, at every width — not "about half",
    /// and not "whatever is left after a fixed 120 pt tail".
    func testTheSplitIsHalfAndHalfAtEveryWidth() {
        for width in shippedWidths {
            let axis = HistogramAxis(plot: NSRect(x: 0, y: 0, width: width, height: 58))
            XCTAssertEqual(axis.sdrWidth, width / 2, accuracy: 1e-12, "\(width) pt: SDR 半区")
            XCTAssertEqual(axis.hdrWidth, width / 2, accuracy: 1e-12, "\(width) pt: HDR 半区")
            XCTAssertEqual(axis.sdrWidth, axis.hdrWidth, accuracy: 1e-12, "\(width) pt: 两半相等")
            XCTAssertEqual(axis.sdrWidth + axis.hdrWidth, width, accuracy: 1e-12, "\(width) pt: 两半加满")
            // Derived, not the old fixed 30 pt/stop.
            XCTAssertEqual(axis.stopWidth, width / 8, accuracy: 1e-12, "\(width) pt: 每档 = 半区/4")
        }
    }

    /// Display white is the **middle** of the plot — the line the two scales meet at, and the line the
    /// curve panel calls `whiteU`.
    func testTheWhitePointIsTheMiddleOfThePlot() {
        for width in shippedWidths {
            let plot = NSRect(x: 12, y: 3, width: width, height: 58)
            let axis = HistogramAxis(plot: plot)
            XCTAssertEqual(axis.sdrMaxX, plot.minX + width / 2, accuracy: 1e-12, "\(width) pt: 白点在正中")
            XCTAssertEqual(axis.sdrMaxX, plot.midX, accuracy: 1e-12, "\(width) pt: 白点 == plot.midX")
        }
    }

    /// The two plots are one yardstick: the card's split and the curve's `whiteU` are the same
    /// **proportion**. Their point widths differ by design (the curve's plot is its own rect, the
    /// card's follows the card), so proportion is the claim — 50/50 both places, which is what makes
    /// the `+1…+4` ticks line up when the panel and the card are the same width.
    func testTheCardSplitAndTheCurveWhiteUAreTheSameProportion() {
        let axis = HistogramAxis(plot: NSRect(x: 0, y: 0, width: 400, height: 58))
        let curve = HDRCurveAxis.standard
        XCTAssertEqual(curve.whiteU, 0.5, "曲线的白点必须在正中（SDR 占 50%）")
        XCTAssertEqual(Double(axis.sdrWidth / axis.plot.width), curve.whiteU, accuracy: 1e-12,
                       "直方图 SDR 半区的比例 == 曲线的 whiteU")
        XCTAssertEqual(Double(axis.hdrWidth / axis.plot.width), 1 - curve.whiteU, accuracy: 1e-12,
                       "直方图 HDR 半区的比例 == 曲线右半")
        // …and the four tail stops are evenly spread over that half, the same 12.5 % per stop the
        // curve's `u(stops:)` gives.
        for stop in 1...4 {
            let x = axis.x(stopsAboveWhite: Double(stop))
            XCTAssertEqual(Double((x - axis.sdrMaxX) / axis.plot.width), 0.125 * Double(stop),
                           accuracy: 1e-12, "+\(stop) 档在 12.5 % × \(stop) 处")
        }
        XCTAssertEqual(axis.x(stopsAboveWhite: 4), axis.plot.maxX, accuracy: 1e-12)
    }

    /// The ceiling tick is `log2(headroom)` stops into the tail — the *same* unit the stops are in,
    /// which is the reason the tail is in linear stops rather than code doublings.
    func testTheCeilingTickIsAtLogTwoOfHeadroom() {
        let axis = HistogramAxis(plot: plot)
        let stop = axis.stopWidth
        XCTAssertEqual(stop, 37.5, accuracy: 1e-12, "300 pt 卡：尾段 150 pt / 4 档")
        XCTAssertEqual(axis.x(ceiling: 1), axis.sdrMaxX, accuracy: 1e-9, "SDR: the tick *is* the boundary")
        XCTAssertEqual(axis.x(ceiling: 1.695),
                       axis.sdrMaxX + CGFloat(log2(1.695)) * stop, accuracy: 1e-9)
        XCTAssertEqual(axis.x(ceiling: 16), plot.maxX, accuracy: 1e-9,
                       "headroom 16 is 4 stops — exactly the tail's end")
        // A ceiling past what the tail can hold is clamped to its right edge, never drawn outside.
        XCTAssertEqual(axis.x(ceiling: 64), plot.maxX, accuracy: 1e-9)
        XCTAssertEqual(axis.x(ceiling: 256), plot.maxX, accuracy: 1e-9)
    }

    // MARK: - the pointer's inverse, HDR half

    /// **The part that is easiest to forget when the split moves**: every x in the tail must still read
    /// back the stop it is drawn at. Five points — the middle of each of the four stops, and a point
    /// just inside the right end (the overflow bin) — must invert to within one bin, i.e. 1/64 stop.
    ///
    /// The positions are **absolute** fractions of the plot (`minX + width · 0.5625` …), not
    /// `sdrMaxX + hdrWidth · …`: that is what makes this a test of the *50/50 split* as well as of the
    /// inverse. Derived from the axis it would pass under any split, which is exactly the bug this
    /// card had.
    func testTheHoverInverseFindsTheStopsInTheHDRHalf() {
        let axis = HistogramAxis(plot: plot)
        func at(_ u: CGFloat) -> CGFloat { plot.minX + plot.width * u }
        let samples: [(x: CGFloat, stops: Double, why: String)] = [
            (at(0.5625), 0.5, "第 1 档中点（绘图区 56.25 %）"),
            (at(0.6875), 1.5, "第 2 档中点（68.75 %）"),
            (at(0.8125), 2.5, "第 3 档中点（81.25 %）"),
            (at(0.9375), 3.5, "第 4 档中点（93.75 %）"),
            (plot.maxX - 0.001, 255.0 / 64.0, "右端内 0.001 pt（溢出箱）"),
        ]
        for sample in samples {
            let reading = axis.hoverReading(atX: sample.x)
            XCTAssertEqual(reading.segment, .tail, "\(sample.why) 在尾段")
            XCTAssertEqual(reading.stops, sample.stops, accuracy: 1.0 / 64.0,
                           "\(sample.why) 反查档位误差 ≤ 1/64 档（读 \(reading.stops)）")
            // And the reading's own bin maps back to where the pointer is: no drift.
            XCTAssertEqual(axis.x(hdrBin: reading.bin), sample.x, accuracy: axis.hdrWidth / 256,
                           "\(sample.why)：bin \(reading.bin) 的中心与指针同一箱")
            print(String(format: "hover→stop %@ x=%.3f → bin %d · %.4f 档（期望 %.4f，误差 %.4f 档）",
                         sample.why, sample.x, reading.bin, reading.stops, sample.stops,
                         abs(reading.stops - sample.stops)))
        }
        // The stop lines themselves are the exact bins 64/128/192 (64 bins per stop), at the absolute
        // positions the 50 % half puts them.
        for (stop, bin) in [(1, 64), (2, 128), (3, 192)] {
            XCTAssertEqual(axis.x(stopsAboveWhite: Double(stop)), at(0.5 + 0.125 * Double(stop)),
                           accuracy: 1e-9, "+\(stop) 档在绘图区 \(50 + 12.5 * Double(stop)) % 处")
            XCTAssertEqual(axis.hoverReading(atX: at(0.5 + 0.125 * Double(stop))).bin, bin,
                           "+\(stop) 档 → bin \(bin)")
        }
    }

    // MARK: - the pointer's inverse, SDR half

    /// The code half's two end bins have their **centres** inside their own half: bin 0's right of the
    /// plot's left edge, bin 255's left of the **middle of the card**. Nothing in the code segment is
    /// drawn across the white line, which is what "SDR 是左半" means in pixels.
    ///
    /// Both anchors are used on purpose: the middle (`plot.midX`) is the 50/50 claim, and the boundary
    /// (`sdrMaxX`) is what the bins must agree with for any split.
    func testTheCodeHalfsEndBinsStayInsideTheirHalf() {
        for width in shippedWidths {
            let axis = HistogramAxis(plot: NSRect(x: 0, y: 0, width: width, height: 58))
            let first = axis.x(sdrBin: 0, of: 256)
            let last = axis.x(sdrBin: 255, of: 256)
            XCTAssertGreaterThan(first, axis.plot.minX, "\(width) pt: bin 0 在中线左侧、绘图区之内")
            XCTAssertLessThan(first, axis.plot.midX, "\(width) pt: bin 0 的中心在卡片正中左边")
            XCTAssertLessThan(first, axis.sdrMaxX, "\(width) pt: bin 0 不跨中线")
            XCTAssertLessThan(last, axis.plot.midX, "\(width) pt: bin 255 的中心也还在正中左边")
            XCTAssertLessThan(last, axis.sdrMaxX, "\(width) pt: bin 255 在中线左侧")
            XCTAssertGreaterThan(last, first)
            // One bin is 1/256 of the half, so bin 255's *edge* still lands on white.
            XCTAssertEqual(last + axis.sdrWidth / 512, axis.sdrMaxX, accuracy: 1e-12,
                           "\(width) pt: bin 255 的右边缘就是白点")
            // …and the first tail bin's centre is right of the middle: the halves really are split.
            XCTAssertGreaterThan(axis.x(hdrBin: 0), axis.plot.midX,
                                 "\(width) pt: 尾段第一箱的中点在中线右边")
        }
        // The boundary itself is code 255, and the tail starts strictly to its right (unchanged).
        let axis = HistogramAxis(plot: plot)
        XCTAssertEqual(axis.hoverReading(atX: axis.sdrMaxX).segment, .code)
        XCTAssertEqual(axis.hoverReading(atX: axis.sdrMaxX).bin, 255)
        XCTAssertEqual(axis.hoverReading(atX: axis.sdrMaxX + 0.01).bin, 0)
    }

    // MARK: - the drawn path

    /// One path covers both segments: 256 code bins, then 256 tail bins, then the baseline corner.
    func testOnePathCoversBothSegments() {
        let channel = HistogramChannel(bins: [Int](repeating: 1, count: 256),
                                       hdrBins: [Int](repeating: 1, count: 256),
                                       clippedHigh: 0, clippedCeiling: 0, clippedLow: 0)
        let axis = HistogramAxis(plot: plot)
        let points = HistogramCardFormat.points(channel, binCount: 256, axis: axis,
                                                peak: HistogramCardFormat.scalePeak(channel))
        XCTAssertEqual(points.count, 256 + 256 + 2)
        // points[0] is the baseline corner, so bin 255 is index 256 and tail bin 0 is index 257.
        XCTAssertLessThan(points[256].x, axis.sdrMaxX, "the last code bin stays left of white")
        XCTAssertGreaterThan(points[257].x, axis.sdrMaxX, "the first tail bin is right of white")
        // The seam is the middle of the plot, so the code half is the left half of the card.
        XCTAssertEqual(axis.sdrMaxX, plot.midX, accuracy: 1e-12)
        // Monotone in x across the seam: the path never doubles back.
        for i in 1..<points.count {
            XCTAssertGreaterThanOrEqual(points[i].x, points[i - 1].x - 1e-9,
                                        "point \(i) doubles back")
        }
    }

    /// The vertical scale ignores the drawn path's two ends: a clipped spike in the last tail bin
    /// must not flatten the picture into a line.
    func testAPeakInTheCeilingBinDoesNotFlattenThePlot() {
        var sdr = [Int](repeating: 0, count: 256)
        sdr[100] = 40
        var hdr = [Int](repeating: 0, count: 96)
        hdr[0] = 5
        hdr[95] = 10_000
        let channel = HistogramChannel(bins: sdr, hdrBins: hdr, clippedHigh: 1,
                                       clippedCeiling: 1, clippedLow: 0)
        XCTAssertEqual(HistogramCardFormat.scalePeak(channel), 40)
    }

    // MARK: - pixel evidence: a picture that is black on the left and hot on the right

    /// A synthetic picture — **left half pure black (code 0), right half 4.0× white (+2 EV)** — measured
    /// by the real `Histogram.compute`, then drawn onto the real axis. The two claims are the owner's:
    /// the black bar is **only** in the left half, and the HDR bar is at the **third stop** of the right
    /// half. This is the same arithmetic the card draws with (`HistogramCardFormat.points`), so the
    /// fixture's bars are placed by the shipped geometry, not by a number this test typed.
    func testABlackLeftHotRightPictureDrawsItsBarsOnTheCorrectHalves() {
        let width = 64, height = 8
        let blackPixels = (width / 2) * height
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                // +2 EV above white is 4× white in linear light; +2 EV == exactly 2 stops == bin 128,
                // which is the first bin of the *third* stop (each stop is 64 bins).
                let v: Float = x < width / 2 ? 0 : 4.0
                let o = (y * width + x) * 4
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v)
                rgba[o + 2] = Float16(v); rgba[o + 3] = 1
            }
        }
        let histogram = Histogram.compute(LinearSample(width: width, height: height, rgba: rgba))

        // The measurement itself: one bar at code 0, one at tail bin 128, nothing else anywhere.
        XCTAssertEqual(histogram.red.bins[0], blackPixels, "黑柱：左半全部落在 code 0")
        XCTAssertEqual(histogram.red.bins.dropFirst().reduce(0, +), 0, "code 段只有一箱有像素")
        XCTAssertEqual(histogram.red.hdrBins[128], width * height - blackPixels,
                       "+2 EV 全部落在尾段 bin 128（第 3 档的第一箱）")
        XCTAssertEqual(Array(histogram.red.hdrBins.enumerated()).filter { $0.offset != 128 }
                        .reduce(0) { $0 + $1.element }, 0, "尾段也只有那一箱")

        // …and where the card draws them. Four widths, because the split must hold at all of them.
        for cardWidth in shippedWidths {
            let axis = HistogramAxis(plot: NSRect(x: 0, y: 0, width: cardWidth, height: 58))
            let peak = HistogramCardFormat.scalePeak(histogram.red)
            let points = HistogramCardFormat.points(histogram.red, binCount: 256,
                                                    axis: axis, peak: peak)
            let baseline = axis.plot.maxY
            // Every drawn column with ink (a point above the baseline), sorted left to right.
            let inked = points.filter { $0.y < baseline - 1e-9 }
            XCTAssertEqual(inked.count, 2, "\(cardWidth) pt: 只有两根柱子被画出来（黑柱 + HDR 柱）")

            let black = inked[0]
            XCTAssertEqual(black.x, axis.x(sdrBin: 0, of: 256), accuracy: 1e-9)
            XCTAssertLessThan(black.x, axis.sdrMaxX, "\(cardWidth) pt: 黑柱只在左半")
            XCTAssertLessThan(black.x, axis.plot.midX, "\(cardWidth) pt: 黑柱在中线左侧")

            let hot = inked[1]
            XCTAssertEqual(hot.x, axis.x(hdrBin: 128), accuracy: 1e-9)
            XCTAssertGreaterThan(hot.x, axis.sdrMaxX, "\(cardWidth) pt: HDR 柱只在右半")
            // The third of the four stops: 2.0…3.0 stop above white.
            XCTAssertGreaterThanOrEqual(hot.x, axis.sdrMaxX + axis.hdrWidth * 2 / 4,
                                        "\(cardWidth) pt: HDR 柱不在第 3 档之前")
            XCTAssertLessThan(hot.x, axis.sdrMaxX + axis.hdrWidth * 3 / 4,
                              "\(cardWidth) pt: HDR 柱不在第 3 档之后")
            // …and the pointer over that bar reads exactly +2.00 档 (4.0×): the drawing and the readout
            // agree about which stop that column is.
            XCTAssertEqual(axis.hoverReading(atX: hot.x).stops, 2.0, accuracy: 1.0 / 64.0,
                           "\(cardWidth) pt: HDR 柱上方的读数就是 +2 档")
        }
    }

    // MARK: - a narrow card has no special case any more

    /// 068 deleted the 60 pt SDR floor: with a proportional split both halves shrink together, so no
    /// width can starve the code segment. A 100 pt card is 50/50 like every other width — and the stop
    /// labels' 16 pt legibility guard (`HistogramCardView`) is what handles a tail that gets too small
    /// to label, not the axis.
    func testANarrowCardStillSplitsInHalf() {
        let narrow = HistogramAxis(plot: NSRect(x: 0, y: 0, width: 100, height: 58))
        XCTAssertEqual(narrow.sdrWidth, 50, accuracy: 1e-12)
        XCTAssertEqual(narrow.hdrWidth, 50, accuracy: 1e-12)
        XCTAssertEqual(narrow.stopWidth, 12.5, accuracy: 1e-12)
        XCTAssertLessThan(narrow.stopWidth, 16, "此时 +1…+4 标签会被跳过（卡片自己的可读性规则）")
    }

    // MARK: - the pixel evidence: the card's own bitmap

    /// The same synthetic picture, this time measured on the **card's pixels** rather than by reading
    /// the path back.
    ///
    /// The card is drawn twice offscreen at 2×: once with the picture's bins, once with the *same*
    /// histogram and every bin zeroed (identical text, identical axis, no curve). Everything the two
    /// draws share cancels; what is left is exactly the curve, so a column with ink is a column the
    /// card really painted. The claim is the owner's: the black bar is in the **left** half only, and
    /// the +2 EV bar sits in the **third stop** of the right half.
    @MainActor
    func testTheCardPaintsTheBlackBarLeftAndTheHDRBarInTheThirdStop() {
        let width = 64, height = 8
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v: Float = x < width / 2 ? 0 : 4.0      // +2 EV above white, in linear light
                let o = (y * width + x) * 4
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v)
                rgba[o + 2] = Float16(v); rgba[o + 3] = 1
            }
        }
        let picture = Histogram.compute(LinearSample(width: width, height: height, rgba: rgba))
        // The reference: same histogram, same clipped ratios (so the text rows match), zero bins.
        func zeroed(_ c: HistogramChannel) -> HistogramChannel {
            HistogramChannel(bins: [Int](repeating: 0, count: c.bins.count),
                             hdrBins: [Int](repeating: 0, count: c.hdrBins.count),
                             clippedHigh: c.clippedHigh, clippedCeiling: c.clippedCeiling,
                             clippedLow: c.clippedLow)
        }
        let blank = Histogram(binCount: picture.binCount, sampleCount: picture.sampleCount,
                              canvas: picture.canvas, roi: picture.roi,
                              sampleSize: picture.sampleSize, primaries: picture.primaries,
                              headroom: picture.headroom,
                              red: zeroed(picture.red), green: zeroed(picture.green),
                              blue: zeroed(picture.blue), luma: zeroed(picture.luma))

        let cardWidth: CGFloat = 400
        let scale: CGFloat = 2
        let drawn = bitmap(of: picture, cardWidth: cardWidth, scale: scale)
        let empty = bitmap(of: blank, cardWidth: cardWidth, scale: scale)
        let axis = HistogramAxis(plot: NSRect(x: 0, y: 0, width: cardWidth, height: 58))

        // Columns where the curve changed at least 10 pixels. The card strokes the luma outline, so the
        // whole baseline gets ~4 px of antialiasing in every column; a bar is 100+ px tall at 2×.
        var ink: [Int] = []
        for x in 0..<drawn.pixelsWide {
            var changed = 0
            for y in 0..<drawn.pixelsHigh where differs(drawn, empty, x: x, y: y) { changed += 1 }
            if changed >= 10 { ink.append(x) }
        }
        // Group consecutive columns into bars (a gap of 4 px at 2× is under one SDR bin).
        var bars: [(from: Int, to: Int)] = []
        for x in ink {
            if var last = bars.last, x - last.to <= 4 {
                last.to = x
                bars[bars.count - 1] = last
            } else {
                bars.append((x, x))
            }
        }
        print("drawn ink columns: \(bars.map { "\($0.from)…\($0.to)" }) of \(drawn.pixelsWide) px "
              + "· 中线 \(Int(cardWidth * scale / 2)) px · 有墨的列 \(ink.count)（首 \(ink.first ?? -1) 末 \(ink.last ?? -1)）")
        XCTAssertEqual(bars.count, 2, "只画出两根柱子：黑柱与 +2 EV 柱")
        guard bars.count == 2 else { return }

        let black = bars[0], hot = bars[1]
        XCTAssertLessThan(Double(black.to), Double(cardWidth * scale / 2),
                          "黑柱整根都在左半（卡片 \(cardWidth) pt，2× 位图）")
        // The bar is one bin wide plus the luma stroke (1.2 pt ≈ 2.4 px at 2×), so its *middle* is the
        // bin's centre, not its left edge.
        let blackMiddle = Double(black.from + black.to) / 2 + 0.5
        XCTAssertEqual(blackMiddle, Double(axis.x(sdrBin: 0, of: 256) * scale),
                       accuracy: 3, "黑柱在 code 0 这一箱上（左端被卡片边缘裁掉，所以看中点）")
        XCTAssertGreaterThan(Double(hot.from), Double(cardWidth * scale / 2), "HDR 柱整根都在右半")
        let hotMiddle = Double(hot.from + hot.to) / 2 + 0.5
        XCTAssertEqual(hotMiddle, Double(axis.x(hdrBin: 128) * scale), accuracy: 3,
                       "HDR 柱在尾段 bin 128 这一箱上（第 3 档的第一箱）")
        // Absolute, and independent of the axis: +2.00 档 is the middle of the tail's four stops, so with
        // a 50 % tail it lands at **75 % of the card's width** (bin 128 of 256). Under the old fixed
        // 120 pt tail the same pixel was at 85 % — this is the assertion the proportion turns on.
        XCTAssertEqual(hotMiddle / Double(drawn.pixelsWide), 0.75, accuracy: 0.02,
                       "2.00 档在卡片宽度的 75 % 处（左半 SDR + 右半尾段的正中）")

        let thirdStopFrom = axis.sdrMaxX + axis.hdrWidth * 2 / 4
        let thirdStopTo = axis.sdrMaxX + axis.hdrWidth * 3 / 4
        XCTAssertGreaterThanOrEqual(Double(hot.from), Double(thirdStopFrom * scale) - 2,
                                    "HDR 柱不早于第 3 档")
        XCTAssertLessThanOrEqual(Double(hot.to), Double(thirdStopTo * scale) + 2, "HDR 柱不晚于第 3 档")
        // The whole plot is where the ink is: nothing the curve draws escapes the plot's band.
        XCTAssertLessThanOrEqual(ink.count, Int(cardWidth * scale), "画的列数不会超过绘图区宽度")
    }

    /// One real `draw` into an offscreen bitmap at `scale`, no window (the same trick `HistogramHoverTests`
    /// uses, so text metrics are real).
    @MainActor
    private func bitmap(of histogram: Histogram, cardWidth: CGFloat, scale: CGFloat) -> NSBitmapImageRep {
        let card = HistogramCardView()
        // The card's own height (90 pt since 2026-10-27 — 104 was the two-row card; the plot this file
        // measures did not move, see `HistogramCardHeightTests`). Only the canvas under the plot shrinks.
        let cardHeight = HistogramCardView.contentHeight
        card.frame = NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
        card.appearance = NSAppearance(named: .aqua)
        card.histogram = histogram
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(cardWidth * scale),
                                   pixelsHigh: Int(cardHeight * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: cardWidth, height: cardHeight)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        card.draw(card.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Same column of two bitmaps, different by more than an antialiasing step on any of R/G/B.
    private func differs(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        guard let pa = a.bitmapData, let pb = b.bitmapData else { return false }
        let oa = y * a.bytesPerRow + x * a.samplesPerPixel
        let ob = y * b.bytesPerRow + x * b.samplesPerPixel
        for k in 0..<3 where abs(Int(pa[oa + k]) - Int(pb[ob + k])) > 8 { return true }
        return false
    }
}
