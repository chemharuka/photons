import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// 010 — the histogram card's **hover readout**: the line the owner deleted as a footnote
/// (「采样 898k px · 直方图 256+256 档」) now shows what the pointer is over.
///
/// Two claims, tested apart because they fail differently:
///
///   ① **x → bin is arithmetic.** `HistogramAxis.hoverReading(atX:)` must invert the axis exactly at
///      both ends, in the middle of the code segment, and on each of the tail's four stop lines —
///      those are the points a user can actually aim at, and the ones a half-bin error would move.
///   ② **The line is text, a font and a colour.** `HistogramCardFormat.hoverValue/hoverCounts` are
///      asserted against a fixture with *known* counts (so "R 1284" is a number this test put
///      there), the font is the clipping numbers' own `numberFont` (an identity, not two literals),
///      and the colour is measured with the card's WCAG arithmetic in both appearances.
///   ③ **The level row is three slots that do not move** (015). `R/G/B` are pinned to their slots'
///      left edges and the numbers right-aligned to their right edges, so `0`, `128` and `+3.0` all
///      produce the *same* letter `minX` and the *same* number `maxX` — asserted exactly, not within
///      a tolerance.
///
/// The card is drawn offscreen, never in a window: nothing here can leave a window on screen.
@MainActor
final class HistogramHoverTests: XCTestCase {

    /// The card's shipped minimum width (inspector 300 − 24 padding − 32 inset) and its height.
    private let minimumCardWidth: CGFloat = 244
    private let cardHeight: CGFloat = 104
    private let plot = NSRect(x: 0, y: 0, width: 300, height: 58)

    // MARK: - fixtures

    /// A histogram whose bins the test chose: `bins[128]` and three tail bins carry the counts the
    /// readout strings below assert, so a formatting bug cannot pass by matching itself.
    private var knownCounts: Histogram {
        func bins(sdr: [(Int, Int, Int, Int)], tail: [(Int, Int, Int, Int)]) -> (HistogramChannel, HistogramChannel, HistogramChannel) {
            let r = (0..<256).map { i in sdr.first { $0.0 == i }?.1 ?? 0 }
            let g = (0..<256).map { i in sdr.first { $0.0 == i }?.2 ?? 0 }
            let b = (0..<256).map { i in sdr.first { $0.0 == i }?.3 ?? 0 }
            let hr = (0..<256).map { i in tail.first { $0.0 == i }?.1 ?? 0 }
            let hg = (0..<256).map { i in tail.first { $0.0 == i }?.2 ?? 0 }
            let hb = (0..<256).map { i in tail.first { $0.0 == i }?.3 ?? 0 }
            func channel(_ bins: [Int], _ hdr: [Int]) -> HistogramChannel {
                HistogramChannel(bins: bins, hdrBins: hdr,
                                 clippedHigh: 0.01, clippedCeiling: 0.01, clippedLow: 0)
            }
            return (channel(r, hr), channel(g, hg), channel(b, hb))
        }
        let (red, green, blue) = bins(sdr: [(128, 1284, 1291, 1206), (129, 7, 7, 7)],
                                     tail: [(64, 812, 819, 734), (128, 903, 910, 825),
                                            (255, 41, 48, 33)])
        return Histogram(binCount: 256, sampleCount: 898_432,
                         canvas: ImageSize(width: 720, height: 420),
                         roi: ImageRect(x: 0, y: 0, width: 720, height: 420),
                         sampleSize: ImageSize(width: 720, height: 420),
                         primaries: .sRGB, headroom: 1,
                         red: red, green: green, blue: blue, luma: red)
    }

    private func drawnCard(width: CGFloat = 244, appearance: NSAppearance.Name = .aqua,
                           histogram: Histogram? = nil) -> HistogramCardView {
        let card = HistogramCardView()
        card.frame = NSRect(x: 0, y: 0, width: width, height: cardHeight)
        card.appearance = NSAppearance(named: appearance)
        card.histogram = histogram
        render(card)
        return card
    }

    /// One real `draw` into an offscreen bitmap — no window, but real text metrics.
    private func render(_ card: HistogramCardView) {
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(card.bounds.width * scale),
                                   pixelsHigh: Int(cardHeight * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: card.bounds.width, height: cardHeight)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        card.draw(card.bounds)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - ① x → bin: both ends

    func testTheLeftEdgeOfThePlotIsCodeZero() {
        let axis = HistogramAxis(plot: plot)
        let reading = axis.hoverReading(atX: plot.minX)
        XCTAssertEqual(reading.segment, .code)
        XCTAssertEqual(reading.bin, 0)
        XCTAssertEqual(reading.code, 0)
        XCTAssertEqual(HistogramCardFormat.hoverValue(reading), "0")
    }

    func testTheRightEdgeOfThePlotIsTheLastTailBin() {
        let axis = HistogramAxis(plot: plot)
        let reading = axis.hoverReading(atX: plot.maxX)
        XCTAssertEqual(reading.segment, .tail)
        XCTAssertEqual(reading.bin, 255, "越过 4 档右端 clamp 到最后一箱（溢出箱）")
        XCTAssertEqual(reading.stops, 3.984375, accuracy: 1e-9)
        XCTAssertEqual(reading.multiple, 15.827648211103607, accuracy: 1e-9, "2^(255/64) = 15.83×")
        XCTAssertEqual(HistogramCardFormat.hoverValue(reading), "+3.98 档 (15.8×)")
    }

    /// Even a point far outside the plot (a drag that ran off the card) yields a legal bin.
    func testAPointOutsideThePlotIsClampedNotTrapped() {
        let axis = HistogramAxis(plot: plot)
        XCTAssertEqual(axis.hoverReading(atX: -400).bin, 0)
        XCTAssertEqual(axis.hoverReading(atX: 9_999).bin, 255)
        XCTAssertEqual(axis.hoverReading(atX: 9_999).segment, .tail)
    }

    // MARK: - ① x → bin: the code segment's middle, and the split

    func testTheMiddleOfTheCodeSegmentIsBin128() {
        let axis = HistogramAxis(plot: plot)
        let middle = plot.minX + axis.sdrWidth * 0.5
        XCTAssertEqual(axis.sdrWidth, 180, accuracy: 1e-9, "300 pt 卡：180 pt 码值 + 120 pt 尾段")
        let reading = axis.hoverReading(atX: middle)
        XCTAssertEqual(reading.segment, .code)
        XCTAssertEqual(reading.bin, 128)
        XCTAssertEqual(reading.code, 128)
        // A round trip both ways: the bin's own centre maps back to the same bin.
        XCTAssertEqual(axis.hoverReading(atX: axis.x(sdrBin: 128, of: 256)).bin, 128)
        XCTAssertEqual(axis.hoverReading(atX: axis.x(sdrBin: 0, of: 256)).bin, 0)
        XCTAssertEqual(axis.hoverReading(atX: axis.x(sdrBin: 255, of: 256)).bin, 255)
    }

    /// The SDR/tail boundary *is* display white, so it belongs to the code segment (code 255); the
    /// tail starts strictly to its right, and its first bin starts at exactly 0 stops.
    func testTheSplitBelongsToCode255AndTheTailStartsRightAfter() {
        let axis = HistogramAxis(plot: plot)
        let onTheSplit = axis.hoverReading(atX: axis.sdrMaxX)
        XCTAssertEqual(onTheSplit.segment, .code)
        XCTAssertEqual(onTheSplit.bin, 255)
        XCTAssertEqual(onTheSplit.code, 255)

        let inTheTail = axis.hoverReading(atX: axis.sdrMaxX + 0.01)
        XCTAssertEqual(inTheTail.segment, .tail)
        XCTAssertEqual(inTheTail.bin, 0)
        XCTAssertEqual(inTheTail.stops, 0, accuracy: 1e-12)
        XCTAssertEqual(inTheTail.multiple, 1, accuracy: 1e-12)
    }

    // MARK: - ① x → bin: every stop line of the tail

    /// `+1`, `+2`, `+3` land on bins 64 / 128 / 192 exactly (64 bins per stop), and `+4` is the
    /// overflow bin — that is the whole point of quoting a bin's *lower* edge: the number under the
    /// cursor is the number the axis prints.
    func testTheFourStopBoundariesLandOnExactBins() {
        let axis = HistogramAxis(plot: plot)
        let expected: [(stop: Int, bin: Int)] = [(1, 64), (2, 128), (3, 192), (4, 255)]
        for (stop, bin) in expected {
            let reading = axis.hoverReading(atX: axis.x(stopsAboveWhite: Double(stop)))
            XCTAssertEqual(reading.segment, .tail, "+\(stop) 档应在尾段")
            XCTAssertEqual(reading.bin, bin, "+\(stop) 档 → bin \(bin)")
            if stop < 4 {
                XCTAssertEqual(reading.stops, Double(stop), accuracy: 1e-9, "+\(stop) 档边界读 +\(stop).00")
                XCTAssertEqual(reading.multiple, pow(2, Double(stop)), accuracy: 1e-9)
                XCTAssertEqual(HistogramCardFormat.hoverValue(reading),
                               String(format: "%+.2f 档 (%.1f×)", Double(stop), pow(2, Double(stop))),
                               "+\(stop) 档的文本")
            }
        }
        // 4 档本身是右端：溢出箱的下边界，读 3.98 档而不是 4.00（见 hoverReading 的注释）。
        XCTAssertEqual(axis.hoverReading(atX: axis.x(stopsAboveWhite: 4)).stops, 3.984375, accuracy: 1e-9)
    }

    /// Each half's inverse is monotone non-decreasing as x sweeps right, and the code half ends on
    /// bin 255 with the tail starting at bin 0 — i.e. no x in either segment maps backwards.
    func testTheInverseIsMonotoneInBothSegments() {
        let axis = HistogramAxis(plot: plot)
        var codeBin = -1
        for step in 0...1000 {
            let x = plot.minX + (axis.sdrWidth - 0.001) * CGFloat(step) / 1000
            let bin = axis.hoverReading(atX: x).bin
            XCTAssertGreaterThanOrEqual(bin, codeBin, "码值段向右扫时 bin 不回头（step \(step)）")
            codeBin = bin
        }
        XCTAssertEqual(codeBin, 255)

        var tailBin = -1
        for step in 0...1000 {
            let x = axis.sdrMaxX + 0.001 + (axis.hdrWidth - 0.002) * CGFloat(step) / 1000
            let bin = axis.hoverReading(atX: x).bin
            XCTAssertGreaterThanOrEqual(bin, tailBin, "尾段向右扫时 bin 不回头（step \(step)）")
            tailBin = bin
        }
        XCTAssertEqual(tailBin, 255)
    }

    // MARK: - ② the four sample strings, against counts the test chose

    func testTheReadoutStringsForCode128AndTheThreeTailBins() {
        let histogram = knownCounts
        let axis = HistogramAxis(plot: plot)
        let samples: [(x: CGFloat, value: String, counts: String)] = [
            (axis.x(sdrBin: 128, of: 256), "128", "R 1284 · G 1291 · B 1206"),
            (axis.x(hdrBin: 64), "+1.00 档 (2.0×)", "R 812 · G 819 · B 734"),
            (axis.x(hdrBin: 128), "+2.00 档 (4.0×)", "R 903 · G 910 · B 825"),
            (axis.x(hdrBin: 255), "+3.98 档 (15.8×)", "R 41 · G 48 · B 33"),
        ]
        for sample in samples {
            let reading = axis.hoverReading(atX: sample.x)
            XCTAssertEqual(HistogramCardFormat.hoverValue(reading), sample.value)
            XCTAssertEqual(HistogramCardFormat.hoverCounts(histogram, reading), sample.counts)
        }
    }

    /// A card with no measurement still reads position ("this is code 128") and says the counts are
    /// unknown rather than inventing zeros.
    func testAnUnmeasuredCardReadsThePositionAndNoCounts() {
        let reading = HistogramAxis(plot: plot).hoverReading(atX: 90)
        XCTAssertEqual(HistogramCardFormat.hoverValue(reading), "128")
        XCTAssertEqual(HistogramCardFormat.hoverCounts(nil, reading), "—")
    }

    // MARK: - ② the font is the clipping numbers' font (an identity)

    func testTheReadoutUsesTheSameFontAsTheClippingNumbers() {
        let readout = HistogramCardView.hoverNumberFont
        XCTAssertEqual(readout, HistogramCardView.clipNumberFont, "读数与过白/削顶是同一个 NSFont")
        XCTAssertEqual(readout.pointSize, 9.5, accuracy: 1e-9, "不是脚注的 8 pt")
        XCTAssertGreaterThan(readout.pointSize, HistogramCardReadability.percentFont.pointSize,
                             "比通道百分数（8.5 pt）更大")
        let expected = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        XCTAssertEqual(readout.fontName, expected.fontName)
        // Monospaced digits: the row must not reflow as the numbers change.
        for glyph in ["0", "1", "8"] {
            XCTAssertEqual((glyph as NSString).size(withAttributes: [.font: readout]).width,
                           ("0" as NSString).size(withAttributes: [.font: readout]).width,
                           accuracy: 0.01, "等宽数字 \(glyph)")
        }
    }

    // MARK: - ② contrast, measured

    func testTheReadoutColourClearsTheWCAGFloorInBothAppearances() {
        for isDark in [false, true] {
            let name = isDark ? "darkAqua" : "aqua"
            let colour = HistogramCardReadability.readoutColor(isDark: isDark)
            XCTAssertEqual(colour.alphaComponent, 1, "\(name) 读数必须是实色（不是 alpha 淡染）")
            let band = HistogramCardReadability.backdropGreys(isDark: isDark)
            for grey in [band.low, band.high] {
                let ratio = HistogramCardReadability.contrast(of: colour, overGrey: grey)
                XCTAssertGreaterThanOrEqual(ratio, HistogramCardReadability.minimumRatio,
                                            "\(name) 读数在灰阶 \(grey) 上只有 \(ratio):1")
            }
            XCTAssertGreaterThanOrEqual(HistogramCardReadability.worstContrast(of: colour, isDark: isDark), 5,
                                        "\(name) 读数留有余量")
            print("hover readout contrast \(name): worst \(String(format: "%.2f", HistogramCardReadability.worstContrast(of: colour, isDark: isDark))):1 over grey \(String(format: "%.3f…%.3f", band.low, band.high))")
        }
        // The colour it replaces would not have cleared the floor — the reason it is not used.
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let s = NSColor.secondaryLabelColor.usingColorSpace(.sRGB)!
            r = Double(s.redComponent); g = Double(s.greenComponent)
            b = Double(s.blueComponent); a = Double(s.alphaComponent)
        }
        let composited = NSColor(srgbRed: CGFloat(r * a + 0.925 * (1 - a)),
                                 green: CGFloat(g * a + 0.925 * (1 - a)),
                                 blue: CGFloat(b * a + 0.925 * (1 - a)), alpha: 1)
        let secondaryRatio = HistogramCardReadability.contrast(of: composited, overGrey: 0.925)
        XCTAssertLessThan(secondaryRatio, HistogramCardReadability.minimumRatio,
                          ".secondaryLabelColor 在卡片底色上只有 \(secondaryRatio):1，所以读数不用它")
    }

    // MARK: - ③ the drawn card: readout on, readout cleared, one tracking area

    func testTheDrawnCardPaintsTheReadoutAtCode128AndClearsItOnLeave() {
        let card = drawnCard(histogram: knownCounts)
        XCTAssertTrue(card.hoverValueText.isEmpty, "没悬停时那一行是空的")
        XCTAssertTrue(card.hoverReadoutRect.isEmpty)
        XCTAssertEqual(card.hoverPaintCount, 0)

        // bin 128 of the 244 pt card: sdrWidth 124 pt, so the bin's centre is at x = 62.25.
        card.updateHoverReadout(at: CGPoint(x: 62.25, y: 20))
        render(card)
        XCTAssertEqual(card.hoverValueText, "128")
        XCTAssertEqual(card.hoverCountText, "R 1284 · G 1291 · B 1206")
        XCTAssertEqual(card.hoverPaintCount, 1)
        XCTAssertFalse(card.hoverReadoutRect.isEmpty)
        XCTAssertEqual(card.hoverReadoutRect.minX, 0, accuracy: 0.5, "左侧：码值左对齐")
        XCTAssertEqual(card.hoverReadoutRect.maxX, minimumCardWidth, accuracy: 0.6, "右侧：计数右对齐")
        XCTAssertLessThanOrEqual(card.hoverReadoutRect.maxY, cardHeight + 0.01, "读数不能画到卡片外面")
        XCTAssertGreaterThanOrEqual(card.hoverReadoutRect.minY, 89, "读数在通道行（8.5 pt）下方，不重叠")
        XCTAssertEqual(card.lastHoverColor, HistogramCardReadability.readoutColor(isDark: false))
        XCTAssertGreaterThanOrEqual(card.hoverContrast, HistogramCardReadability.minimumRatio)
        print("hover readout drawn: \"\(card.hoverValueText)\" | \"\(card.hoverCountText)\" · rect \(card.hoverReadoutRect) · card \(card.bounds) · font \(HistogramCardView.hoverNumberFont.fontName) \(HistogramCardView.hoverNumberFont.pointSize) · contrast \(String(format: "%.2f", card.hoverContrast)):1")

        // Moved out of the plot → the line is empty and nothing is painted any more (paint count stays).
        card.clearHoverReadout()
        render(card)
        XCTAssertNil(card.hoverReading)
        XCTAssertEqual(card.hoverValueText.count, 0)
        XCTAssertEqual(card.hoverCountText.count, 0)
        XCTAssertTrue(card.hoverReadoutRect.isEmpty)
        XCTAssertEqual(card.hoverPaintCount, 1, "清空后不再画读数")
    }

    /// The four samples again, this time read back from the **drawn** card (the strings `draw` really
    /// painted, in the layout it really used) — so the report's numbers are not just the formatter's.
    func testTheDrawnCardPaintsTheFourSampleStrings() {
        let card = drawnCard(histogram: knownCounts)
        let axis = HistogramAxis(plot: NSRect(x: 0, y: 0, width: minimumCardWidth, height: 58))
        let samples: [(x: CGFloat, value: String, counts: String)] = [
            (axis.x(sdrBin: 128, of: 256), "128", "R 1284 · G 1291 · B 1206"),
            (axis.x(hdrBin: 64), "+1.00 档 (2.0×)", "R 812 · G 819 · B 734"),
            (axis.x(hdrBin: 128), "+2.00 档 (4.0×)", "R 903 · G 910 · B 825"),
            (axis.x(hdrBin: 255), "+3.98 档 (15.8×)", "R 41 · G 48 · B 33"),
        ]
        for sample in samples {
            card.updateHoverReadout(at: CGPoint(x: sample.x, y: 20))
            render(card)
            XCTAssertEqual(card.hoverValueText, sample.value)
            XCTAssertEqual(card.hoverCountText, sample.counts)
            XCTAssertLessThanOrEqual(card.hoverReadoutRect.maxY, cardHeight + 0.01)
            XCTAssertLessThanOrEqual(card.hoverReadoutRect.maxX, minimumCardWidth + 0.01)
            print("drawn readout: \(card.hoverValueText) | \(card.hoverCountText) · rect \(card.hoverReadoutRect)")
        }
    }

    /// A point on the 过白 row is *not* in the plot: hovering there must clear, not invent a bin.
    func testAPointBelowThePlotClearsTheReadout() {
        let card = drawnCard(histogram: knownCounts)
        card.updateHoverReadout(at: CGPoint(x: 62.25, y: 20))
        XCTAssertEqual(card.hoverReading?.bin, 128)
        card.updateHoverReadout(at: CGPoint(x: 62.25, y: 70))   // 过白 那一行
        render(card)
        XCTAssertNil(card.hoverReading)
        XCTAssertTrue(card.hoverValueText.isEmpty)
        XCTAssertTrue(card.hoverReadoutRect.isEmpty)
    }

    /// The mouse-out path: AppKit will not let a test *construct* a `.mouseExited` event (it raises
    /// "Invalid parameter … _NSEventMask64FromType"), so the exit is covered by the two facts that
    /// can be asserted — the tracking area carries `.mouseEnteredAndExited` (so AppKit delivers the
    /// exit), and the clear it calls empties the line — plus the event path in `--ui-smoke`, where a
    /// real window exists. Nothing here fakes an event that cannot exist.
    func testTheExitIsDeliveredByTheTrackingAreaAndClears() {
        let card = drawnCard(histogram: knownCounts)
        card.updateHoverReadout(at: CGPoint(x: 62.25, y: 20))
        XCTAssertEqual(card.hoverValueText, "128")
        card.updateTrackingAreas()
        XCTAssertTrue(card.trackingAreas.allSatisfy { $0.options.contains(.mouseEnteredAndExited) },
                      "mouseExited 由 tracking area 送到卡片")
        card.clearHoverReadout()   // exactly what mouseExited(with:) calls
        render(card)
        XCTAssertNil(card.hoverReading)
        XCTAssertEqual(card.hoverValueText.count, 0)
        XCTAssertTrue(card.hoverReadoutRect.isEmpty)
    }

    /// `updateTrackingAreas` runs on every SwiftUI re-layout; it must leave **one** area, tracking the
    /// plot (not the whole card), with the three options the readout needs.
    func testUpdateTrackingAreasIsIdempotentAndTracksThePlotOnly() {
        let card = drawnCard(histogram: knownCounts)
        for _ in 0..<5 { card.updateTrackingAreas() }
        XCTAssertEqual(card.trackingAreas.count, 1, "重复调用不叠加：\(card.trackingAreas.count) 个 tracking area")
        let area = card.trackingAreas[0]
        XCTAssertEqual(area.rect.height, 58, accuracy: 1e-9, "只跟踪绘图区，不跟踪整张卡")
        XCTAssertEqual(area.rect.width, minimumCardWidth, accuracy: 1e-9)
        let options = area.options
        XCTAssertTrue(options.contains(.mouseMoved))
        XCTAssertTrue(options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(options.contains(.activeInKeyWindow))

        // A resize rebuilds it, still exactly one, following the new width.
        card.frame = NSRect(x: 0, y: 0, width: 320, height: cardHeight)
        card.updateTrackingAreas()
        XCTAssertEqual(card.trackingAreas.count, 1)
        XCTAssertEqual(card.trackingAreas[0].rect.width, 320, accuracy: 1e-9)
    }

    /// A very narrow card (below the shipped minimum) must not lay the readout over the channel row
    /// or outside the card: the row is clamped into the bounds.
    func testTheReadoutRowStaysInsideANarrowCard() {
        let card = drawnCard(width: 200, histogram: knownCounts)
        card.updateHoverReadout(at: CGPoint(x: 30, y: 20))
        render(card)
        XCTAssertFalse(card.hoverReadoutRect.isEmpty)
        XCTAssertLessThanOrEqual(card.hoverReadoutRect.maxY, cardHeight + 0.01)
        XCTAssertLessThanOrEqual(card.hoverCountRect.maxX, 200 + 0.01)
        XCTAssertGreaterThanOrEqual(card.hoverCountRect.minX, card.hoverValueRect.maxX,
                                   "两个半行不重叠")
    }

    // MARK: - 015: the percentages row becomes three *fixed* R/G/B slots
    //
    // The row reads the level under the pointer three times — once per channel — and the owner's
    // requirement is layout, not content: `R`, `G` and `B` must sit at the same three x positions
    // whatever number is in the slot ("不要出现 G B 的位置随着内容变化乱动"). So the row is three
    // equal-width slots: the letter pinned to the slot's left edge, the number right-aligned to the
    // slot's right edge. The tests below assert that as *exact* equality (`accuracy: 0`) at three
    // different string lengths — `0`, `128`, `+3.0` — because "within a tolerance" is what a layout
    // that twitches also passes.

    /// SDR: the number is the sRGB **code**, an integer 0…255 — bin 0 / 128 / 255 → `0` / `128` / `255`.
    func testTheSlotNumberIsTheCodeOnTheCodeSegment() {
        let axis = HistogramAxis(plot: plot)
        let cases: [(bin: Int, text: String)] = [(0, "0"), (64, "64"), (128, "128"), (255, "255")]
        for c in cases {
            let reading = axis.hoverReading(atX: axis.x(sdrBin: c.bin, of: 256))
            XCTAssertEqual(reading.segment, .code)
            XCTAssertEqual(reading.bin, c.bin)
            XCTAssertEqual(HistogramCardFormat.hoverSlotValue(reading), c.text, "码值，不是百分比")
            XCTAssertEqual(HistogramCardFormat.hoverLevelText(reading),
                           "R \(c.text) G \(c.text) B \(c.text)", "R/G/B 三份同值")
        }
        print("015 SDR row: bin 0 → \"R 0 G 0 B 0\" · bin 128 → \"R 128 G 128 B 128\" · bin 255 → \"R 255 G 255 B 255\"")
    }

    /// The tail has no code: it reads the stop, one decimal — `+0.8`, `+2.0`, `+3.0` — and the
    /// 3.984-stop overflow bin rounds to `+4.0`.
    func testTheSlotNumberIsTheStopOnTheTail() {
        let axis = HistogramAxis(plot: plot)
        let cases: [(stops: Double, text: String)] = [
            (0.8, "+0.8"), (1.0, "+1.0"), (2.0, "+2.0"), (3.0, "+3.0"),
        ]
        for c in cases {
            let reading = axis.hoverReading(atX: axis.x(stopsAboveWhite: c.stops))
            XCTAssertEqual(reading.segment, .tail)
            XCTAssertEqual(HistogramCardFormat.hoverSlotValue(reading), c.text, "一位小数的 +x.x 档")
            XCTAssertEqual(HistogramCardFormat.hoverLevelText(reading),
                           "R \(c.text) G \(c.text) B \(c.text)")
        }
        let overflow = axis.hoverReading(atX: plot.maxX)
        XCTAssertEqual(overflow.stops, 3.984375, accuracy: 1e-9)
        XCTAssertEqual(HistogramCardFormat.hoverSlotValue(overflow), "+4.0")
        print("015 tail row: 0.8 → \"+0.8\" · 1.0 → \"+1.0\" · 3.0 → \"+3.0\" · overflow 3.984 → \"+4.0\"")
    }

    func testNoReadingIsNoSlotText() {
        XCTAssertNil(HistogramCardFormat.hoverSlotValue(nil), "没悬停就没有这行数字")
        XCTAssertNil(HistogramCardFormat.hoverLevelText(nil))
    }

    /// The layout arithmetic, with no drawing: three equal slots on a 1/1000 pt grid, and the 72 pt
    /// floor that a card narrower than 216 pt falls back to.
    func testTheSlotGeometryIsThreeEqualSlots() {
        let layout = HistogramCardFormat.hoverSlotLayout(forRowWidth: minimumCardWidth)
        XCTAssertEqual(layout.edges, [0, 81.333, 162.667, 244])
        XCTAssertEqual(layout.slotOrigin(0), 0)
        XCTAssertEqual(layout.slotEnd(2), minimumCardWidth)
        XCTAssertEqual(layout.slotWidth(0), 81.333, accuracy: 1e-9)
        XCTAssertEqual(layout.slotWidth(1), 81.334, accuracy: 1e-9)
        XCTAssertEqual(HistogramCardFormat.hoverSlotLayout(forRowWidth: 180).edges, [0, 72, 144, 216],
                       "窄卡不再缩槽：72 pt × 3")
        XCTAssertEqual(HistogramCardFormat.hoverSlotLayout(forRowWidth: 216).edges, [0, 72, 144, 216])
        print("015 slots: 244 → \(layout.edges) · 180 → \(HistogramCardFormat.hoverSlotLayout(forRowWidth: 180).edges)")
    }

    /// 位置固定（纯函数）：`0` / `128` / `+3.0` 三种长度下，R/G/B 字母的 `minX` 精确相等，数值的
    /// `maxX` 也精确相等——相等的是位模式，不是"在容差内"。
    func testTheThreeSlotsDoNotMoveWhenTheNumberChanges() {
        let font = HistogramCardView.numberFont
        let layout = HistogramCardFormat.hoverSlotLayout(forRowWidth: minimumCardWidth)
        let names = HistogramCardFormat.hoverLevelSlotNames
        var letterMinX: [[CGFloat]] = []
        var valueMaxX: [[CGFloat]] = []
        var numberWidths: [[CGFloat]] = []
        for value in ["0", "128", "+3.0"] {
            var mins: [CGFloat] = []
            var maxs: [CGFloat] = []
            var widths: [CGFloat] = []
            for slot in 0..<3 {
                let letterSize = (names[slot] as NSString).size(withAttributes: [.font: font])
                let valueSize = (value as NSString).size(withAttributes: [.font: font])
                mins.append(layout.letterRect(slot, size: letterSize, y: 0).minX)
                maxs.append(layout.valueRect(slot, size: valueSize, y: 0).maxX)
                widths.append(valueSize.width)
            }
            letterMinX.append(mins)
            valueMaxX.append(maxs)
            numberWidths.append(widths)
        }
        for slot in 0..<3 {
            for caseIndex in 0..<3 {
                XCTAssertEqual(letterMinX[caseIndex][slot], layout.edges[slot], accuracy: 0,
                               "槽 \(slot) 的字母钉在槽左端（\(["0", "128", "+3.0"][caseIndex])）")
                XCTAssertEqual(valueMaxX[caseIndex][slot], layout.edges[slot + 1], accuracy: 0,
                               "槽 \(slot) 的数值右对齐到槽右端（\(["0", "128", "+3.0"][caseIndex])）")
            }
            XCTAssertEqual(letterMinX[1][slot], letterMinX[0][slot], accuracy: 0, "换数字，字母不动")
            XCTAssertEqual(letterMinX[2][slot], letterMinX[0][slot], accuracy: 0, "换数字，字母不动")
            XCTAssertEqual(valueMaxX[1][slot], valueMaxX[0][slot], accuracy: 0, "换数字，右端不动")
            XCTAssertEqual(valueMaxX[2][slot], valueMaxX[0][slot], accuracy: 0, "换数字，右端不动")
        }
        print("015 fixed slots: 字母 minX \(letterMinX[0].map { String(format: "%.3f", $0) }) · 数值 maxX \(valueMaxX[0].map { String(format: "%.3f", $0) }) · 数字宽度 0:\(String(format: "%.2f", numberWidths[0][0])) 128:\(String(format: "%.2f", numberWidths[1][0])) +3.0:\(String(format: "%.2f", numberWidths[2][0])) pt")
        print("015 三种长度同一组槽: \"0\" \(letterMinX[0]) | \"128\" \(letterMinX[1]) | \"+3.0\" \(letterMinX[2])")
    }

    // MARK: - 015: the drawn card — three slots painted, and back to the percentages on leave

    func testTheDrawnCardPaintsThreeFixedSlotsAndRestoresThePercentages() {
        let card = drawnCard(histogram: knownCounts)
        let clips = card.clipHighTextByChannel
        XCTAssertNil(card.hoverLevelText, "没悬停 → 这一行是过白比例")
        XCTAssertNil(card.hoverLevelValueText)
        XCTAssertTrue(card.hoverLevelSlotRects.isEmpty)
        XCTAssertEqual(card.channelRowTexts, Array(clips.prefix(3)))
        let idleWidth = card.channelRowWidth

        // bin 128 of the 244 pt card: sdrWidth 124 pt (the 120 pt tail takes the rest), so the bin's
        // centre is at x = 62.23.
        card.updateHoverReadout(at: CGPoint(x: 62.25, y: 20))
        render(card)
        XCTAssertEqual(card.hoverLevelValueText, "128")
        XCTAssertEqual(card.hoverLevelText, "R 128 G 128 B 128")
        XCTAssertEqual(card.channelRowTexts, ["R 128", "G 128", "B 128"], "三个槽各画一次")
        XCTAssertEqual(card.channelRowText, "R 128 G 128 B 128")
        XCTAssertEqual(card.hoverLevelSlotRects.map(\.minX), [0, 81.333, 162.667], "三槽起点")
        XCTAssertEqual(card.hoverLevelLetterRects.map(\.minX), [0, 81.333, 162.667], "字母在槽左端")
        XCTAssertEqual(card.hoverLevelValueRects.map(\.maxX), [81.333, 162.667, 244], "数值在槽右端")
        XCTAssertEqual(card.channelRowWidth, 244, accuracy: 1e-9, "三槽铺满整行")
        XCTAssertEqual(card.hoverLevelSlotRects.count, 3)

        // The face is still `numberFont` (9.5 pt semibold), the same one 过白/削顶 use.
        let face = ("128" as NSString).size(withAttributes: [.font: HistogramCardView.numberFont])
        XCTAssertEqual(card.hoverLevelValueRects[0].height, face.height, accuracy: 0.01)
        XCTAssertGreaterThan(HistogramCardView.numberFont.pointSize,
                             HistogramCardReadability.percentFont.pointSize)
        XCTAssertEqual(card.hoverLevelRect.minY, 78, accuracy: 0.5, "行位置没变（plot 58 + 5 + 15）")

        // The footnote (010) is still painted on the same draw, and the two rows do not overlap.
        XCTAssertEqual(card.hoverValueText, "128")
        XCTAssertEqual(card.hoverCountText, "R 1284 · G 1291 · B 1206")
        XCTAssertTrue(card.hoverLevelRect.intersection(card.hoverReadoutRect).isEmpty,
                      "两行不重叠：三槽 \(card.hoverLevelRect) vs 脚注 \(card.hoverReadoutRect)")
        XCTAssertLessThan(card.hoverLevelRect.maxY, card.hoverReadoutRect.minY)
        XCTAssertLessThanOrEqual(card.hoverLevelRect.maxY, cardHeight + 0.01)
        print("015 drawn slots: \"\(card.channelRowText)\" · 槽 \(card.hoverLevelSlotRects.map { String(format: "%.3f…%.3f", $0.minX, $0.maxX) }) · 行宽 \(String(format: "%.1f", card.channelRowWidth)) pt / 卡宽 \(minimumCardWidth) pt")
        print("015 drawn rows: 三槽 y \(String(format: "%.1f", card.hoverLevelRect.minY))…\(String(format: "%.1f", card.hoverLevelRect.maxY)) · 脚注 y \(String(format: "%.1f", card.hoverReadoutRect.minY))…\(String(format: "%.1f", card.hoverReadoutRect.maxY))")

        // Mouse out: the three above-white percentages come back in the row's own 8.5 pt face.
        card.clearHoverReadout()
        render(card)
        XCTAssertNil(card.hoverLevelText)
        XCTAssertNil(card.hoverLevelValueText)
        XCTAssertTrue(card.hoverLevelRect.isEmpty)
        XCTAssertTrue(card.hoverLevelSlotRects.isEmpty)
        XCTAssertTrue(card.hoverLevelLetterRects.isEmpty)
        XCTAssertEqual(card.channelRowTexts, Array(clips.prefix(3)))
        XCTAssertEqual(card.channelRowText, "R \(clips[0]) G \(clips[1]) B \(clips[2])")
        XCTAssertEqual(card.channelRowWidth, idleWidth, accuracy: 0.01, "回到过白比例，行宽回原值")
        XCTAssertEqual(card.clipHighTextByChannel, clips, "过白比例本身没被改掉")
        print("015 restored row: \"\(card.channelRowText)\" · 行宽 \(String(format: "%.2f", card.channelRowWidth)) pt（悬停时 244.0 pt）· 字号 \(HistogramCardReadability.percentFont.pointSize) pt（悬停时 \(HistogramCardView.numberFont.pointSize) pt）")
    }

    /// The claim that matters most, on the drawn card: `0`, `128` and `+3.0` all land in the same
    /// three slots, letter `minX` and number `maxX` exactly equal.
    func testTheDrawnSlotsLineUpForZero128AndAStop() {
        let card = drawnCard(histogram: knownCounts)
        let axis = HistogramAxis(plot: NSRect(x: 0, y: 0, width: minimumCardWidth, height: 58))
        let samples: [(x: CGFloat, value: String)] = [
            (axis.x(sdrBin: 0, of: 256), "0"),
            (axis.x(sdrBin: 128, of: 256), "128"),
            (axis.x(stopsAboveWhite: 3.0), "+3.0"),
        ]
        var letters: [[CGFloat]] = []
        var values: [[CGFloat]] = []
        for sample in samples {
            card.updateHoverReadout(at: CGPoint(x: sample.x, y: 20))
            render(card)
            XCTAssertEqual(card.hoverLevelValueText, sample.value)
            letters.append(card.hoverLevelLetterRects.map(\.minX))
            values.append(card.hoverLevelValueRects.map(\.maxX))
            print("015 drawn “\(sample.value)” → 字母 minX \(letters[letters.count - 1].map { String(format: "%.3f", $0) }) · 数值 maxX \(values[values.count - 1].map { String(format: "%.3f", $0) })")
        }
        XCTAssertEqual(letters[0], letters[1], "0 与 128 的字母位置完全相同")
        XCTAssertEqual(letters[1], letters[2], "128 与 +3.0 的字母位置完全相同")
        XCTAssertEqual(values[0], values[1], "0 与 128 的数值右端完全相同")
        XCTAssertEqual(values[1], values[2], "128 与 +3.0 的数值右端完全相同")
    }

    /// The tail on the drawn card: `R +0.8 G +0.8 B +0.8`, footnote still reading the stop and counts.
    func testTheDrawnCardShowsTheSameStopThreeTimesOnTheTail() {
        let card = drawnCard(histogram: knownCounts)
        let axis = HistogramAxis(plot: NSRect(x: 0, y: 0, width: minimumCardWidth, height: 58))
        card.updateHoverReadout(at: CGPoint(x: axis.x(stopsAboveWhite: 0.8), y: 20))
        render(card)
        XCTAssertEqual(card.hoverLevelText, "R +0.8 G +0.8 B +0.8")
        XCTAssertEqual(card.hoverValueText, "+0.80 档 (1.7×)")
        XCTAssertEqual(card.hoverCountText, "R 0 · G 0 · B 0", "该档没有样品，脚注如实说 0")
        XCTAssertTrue(card.hoverLevelRect.intersection(card.hoverReadoutRect).isEmpty)
        XCTAssertEqual(card.hoverLevelSlotRects.map(\.minX), [0, 81.333, 162.667], "尾段也是同一组槽")

        // +2 档 is tail bin 128 — the fixture has 903/910/825 samples there.
        card.updateHoverReadout(at: CGPoint(x: axis.x(hdrBin: 128), y: 20))
        render(card)
        XCTAssertEqual(card.hoverLevelText, "R +2.0 G +2.0 B +2.0")
        XCTAssertEqual(card.hoverCountText, "R 903 · G 910 · B 825")
        XCTAssertEqual(card.hoverLevelSlotRects.map(\.minX), [0, 81.333, 162.667])
        print("015 tail drawn: \"\(card.hoverLevelText ?? "-")\" · 脚注 \"\(card.hoverValueText)\" | \"\(card.hoverCountText)\"")
    }

    /// A card with no measurement keeps the `—` percentages: the level is a property of the *axis*,
    /// not of the histogram, so the three slots still read the code under the pointer.
    func testAnUnmeasuredCardKeepsThePercentageRowWhileHovering() {
        let card = drawnCard(histogram: nil)
        card.updateHoverReadout(at: CGPoint(x: 62.25, y: 20))
        render(card)
        XCTAssertEqual(card.hoverLevelText, "R 128 G 128 B 128", "位置读数不需要测量")
        XCTAssertTrue(card.clipHighTextByChannel.allSatisfy { $0 == "—" })
        XCTAssertEqual(card.channelRowTexts, ["R 128", "G 128", "B 128"])
    }
}
