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
///   ③ **The three groups do not move** (018/019). The row is split into thirds and group `i`'s letter
///      starts at `i · rowWidth / 3`, so any count length — `0`, `1284`, `1987675` — produces the *same*
///      three letter `minX`, asserted exactly; the number sits **one space** behind its letter
///      (「数字要靠近字母」) rather than at a field's right edge, and a long number runs past its group
///      instead of being truncated.
///
/// The card is drawn offscreen, never in a window: nothing here can leave a window on screen.
@MainActor
final class HistogramHoverTests: XCTestCase {

    /// The card's shipped minimum width (inspector 300 − 24 padding − 32 inset) and its height.
    private let minimumCardWidth: CGFloat = 244
    private let cardHeight: CGFloat = 104
    private let plot = NSRect(x: 0, y: 0, width: 300, height: 58)

    /// Where code bin 128 lands on the shipped-minimum card. The card's plot spans its full width
    /// (`HistogramCardView` lays it out at `bounds.width`), so since 068 the code half is 122 pt and
    /// this bin's centre is 61.25 — derived here rather than typed, so a geometry change cannot leave
    /// these hover tests aiming at the wrong bin.
    private var code128X: CGFloat {
        HistogramAxis(plot: NSRect(x: 0, y: 0, width: minimumCardWidth, height: 58))
            .x(sdrBin: 128, of: 256)
    }

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
        XCTAssertEqual(axis.sdrWidth, 150, accuracy: 1e-12, "300 pt 卡：左半 150 pt 码值 + 右半 150 pt 尾段（068）")
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
            (axis.x(sdrBin: 128, of: 256), "128", "R 1284 G 1291 B 1206"),
            (axis.x(hdrBin: 64), "+1.00 档 (2.0×)", "R 812 G 819 B 734"),
            (axis.x(hdrBin: 128), "+2.00 档 (4.0×)", "R 903 G 910 B 825"),
            (axis.x(hdrBin: 255), "+3.98 档 (15.8×)", "R 41 G 48 B 33"),
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
        let axis = HistogramAxis(plot: plot)
        let reading = axis.hoverReading(atX: axis.x(sdrBin: 128, of: 256))
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
        XCTAssertEqual(card.readoutState, .idle, "没悬停时那一行什么都没有")
        XCTAssertTrue(card.hoverReadoutRect.isEmpty)
        XCTAssertEqual(card.hoverPaintCount, 0)

        // bin 128 of the 244 pt card: the code half is 122 pt (068), so the bin's centre is at x = 61.25.
        card.updateHoverReadout(at: CGPoint(x: code128X, y: 20))
        render(card)
        XCTAssertEqual(card.readoutValueTexts.count, 3,
                       "直方图上只有三组计数，没有第二个「裸数字」亮度值（023 已删除亮度行）")
        XCTAssertEqual(card.hoverCountText, "R 1284 G 1291 B 1206")
        XCTAssertEqual(card.hoverPaintCount, 1)
        XCTAssertFalse(card.hoverReadoutRect.isEmpty)
        XCTAssertEqual(card.hoverReadoutRect.minX, 0, accuracy: 0.5, "三组从卡片内容左端开始")
        XCTAssertLessThanOrEqual(card.hoverReadoutRect.maxX, minimumCardWidth + 0.01, "不出卡片右边界")
        XCTAssertLessThanOrEqual(card.hoverReadoutRect.maxY, cardHeight + 0.01, "读数不能画到卡片外面")
        // 023 collapsed the two bottom rows into one: the counts are painted in the **same slot** the
        // pixel's channels use, which is what replaced 「读数在通道行下方（minY ≥ 89）」 — there is no row
        // above this one any more, and the slot must be below the plot and inside the card.
        XCTAssertEqual(card.readoutRowRect, card.channelRowRect,
                       "计数与像素值是同一行、同一个槽")
        XCTAssertGreaterThanOrEqual(card.readoutRowRect.minY, card.lastAxis?.plot.maxY ?? .infinity,
                                    "这一行在绘图区下方")
        XCTAssertEqual(card.lastHoverColor, HistogramCardReadability.readoutColor(isDark: false))
        XCTAssertGreaterThanOrEqual(card.hoverContrast, HistogramCardReadability.minimumRatio)
        print("hover readout drawn: \"\(card.hoverCountText)\" · rect \(card.hoverReadoutRect) · card \(card.bounds) · font \(HistogramCardView.hoverNumberFont.fontName) \(HistogramCardView.hoverNumberFont.pointSize) · contrast \(String(format: "%.2f", card.hoverContrast)):1")

        // Moved out of the plot → the line is empty and nothing is painted any more (paint count stays).
        card.clearHoverReadout()
        render(card)
        XCTAssertNil(card.hoverReading)
        XCTAssertTrue(card.readoutValueTexts.isEmpty)
        XCTAssertEqual(card.hoverCountText.count, 0)
        XCTAssertTrue(card.hoverReadoutRect.isEmpty)
        XCTAssertEqual(card.hoverPaintCount, 1, "清空后不再画读数")
    }

    /// The four samples again, this time read back from the **drawn** card (the strings `draw` really
    /// painted, in the layout it really used) — so the report's numbers are not just the formatter's.
    ///
    /// 018: a plot hover paints **counts only** (`R 1284 G 1291 B 1206`), and the five-character
    /// right-aligned fields are what keeps the letters still; the level is the *canvas* pointer's half
    /// of the row, and it is asserted in `HistogramPointerReadoutTests`.
    func testTheDrawnCardPaintsTheFourSampleStrings() {
        let card = drawnCard(histogram: knownCounts)
        let axis = HistogramAxis(plot: NSRect(x: 0, y: 0, width: minimumCardWidth, height: 58))
        let samples: [(x: CGFloat, counts: String)] = [
            (axis.x(sdrBin: 128, of: 256), "R 1284 G 1291 B 1206"),
            (axis.x(hdrBin: 64), "R 812 G 819 B 734"),
            (axis.x(hdrBin: 128), "R 903 G 910 B 825"),
            (axis.x(hdrBin: 255), "R 41 G 48 B 33"),
        ]
        for sample in samples {
            card.updateHoverReadout(at: CGPoint(x: sample.x, y: 20))
            render(card)
            XCTAssertEqual(card.hoverCountText, sample.counts)
            XCTAssertEqual(card.readoutValueTexts.count, 3,
                           "直方图上只有三组计数：没有裸数字（023 删掉了亮度那一行）")
            XCTAssertLessThanOrEqual(card.hoverReadoutRect.maxY, cardHeight + 0.01)
            XCTAssertLessThanOrEqual(card.hoverReadoutRect.maxX, minimumCardWidth + 0.01)
            print("drawn readout: \(card.hoverCountText) · rect \(card.hoverReadoutRect)")
        }
    }

    /// A point on the 过白 row is *not* in the plot: hovering there must clear, not invent a bin.
    func testAPointBelowThePlotClearsTheReadout() {
        let card = drawnCard(histogram: knownCounts)
        card.updateHoverReadout(at: CGPoint(x: code128X, y: 20))
        XCTAssertEqual(card.hoverReading?.bin, 128)
        card.updateHoverReadout(at: CGPoint(x: code128X, y: 70))   // 过白 那一行
        render(card)
        XCTAssertNil(card.hoverReading)
        XCTAssertTrue(card.readoutValueTexts.isEmpty)
        XCTAssertTrue(card.hoverReadoutRect.isEmpty)
    }

    /// The mouse-out path: AppKit will not let a test *construct* a `.mouseExited` event (it raises
    /// "Invalid parameter … _NSEventMask64FromType"), so the exit is covered by the two facts that
    /// can be asserted — the tracking area carries `.mouseEnteredAndExited` (so AppKit delivers the
    /// exit), and the clear it calls empties the line — plus the event path in `--ui-smoke`, where a
    /// real window exists. Nothing here fakes an event that cannot exist.
    func testTheExitIsDeliveredByTheTrackingAreaAndClears() {
        let card = drawnCard(histogram: knownCounts)
        card.updateHoverReadout(at: CGPoint(x: code128X, y: 20))
        render(card)
        XCTAssertEqual(card.hoverCountText, "R 1284 G 1291 B 1206")
        card.updateTrackingAreas()
        XCTAssertTrue(card.trackingAreas.allSatisfy { $0.options.contains(.mouseEnteredAndExited) },
                      "mouseExited 由 tracking area 送到卡片")
        card.clearHoverReadout()   // exactly what mouseExited(with:) calls
        render(card)
        XCTAssertNil(card.hoverReading)
        XCTAssertTrue(card.readoutValueTexts.isEmpty)
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
        XCTAssertEqual(card.readoutValueTexts.count, 3,
                       "数量态画的是三组「字母 + 数字」，不是一颗裸数字（023 删掉了亮度那一行）")
        XCTAssertEqual(card.readoutLetterRects.count, 3)
    }

    // MARK: - 015: the row's values are three *fixed* R/G/B groups
    //
    // The owner's requirement is layout, not content: `R`, `G` and `B` must sit at the same three x
    // positions whatever number follows them (「不要出现 G B 的位置随着内容变化乱动」). The rows below assert
    // that as *exact* equality across different lengths, because "within a tolerance" is what a layout
    // that twitches also passes.
    //
    // 023 deleted the two tests that used to live here (`hoverRowValue` on the code segment, and on the
    // tail): they formatted the **pixel's brightness** — `128` / `+1.0` — as one bare number at the row's
    // left edge, and 「不需要亮度信息了，只要 RGB 值」 removed both the state and its formatter. The
    // equivalent claim for what is left (the counts, and the pixel's three channels) lives in
    // `testTheRowTextIsTheCountsInThreeGroups` and in `HistogramChannelRowTests`' rect assertions.

    func testNoReadingIsNoRow() {
        XCTAssertNil(HistogramCardFormat.hoverRowText(knownCounts, nil))
        XCTAssertNil(HistogramReadoutRow.idle.text, "idle 时这一行什么都不画")
    }

    /// The row's counts, in the owner's grouped form: `R 1284 G 1291 B 1206` — letter, one space,
    /// number, and the groups a space apart (「数字要靠近字母」). The five-character right-aligned field
    /// is gone; the fixed thing is now the **group start**, asserted from the painted rects.
    func testTheRowTextIsTheCountsInThreeGroups() {
        let axis = HistogramAxis(plot: NSRect(x: 0, y: 0, width: 244, height: 58))
        let code = axis.hoverReading(atX: axis.x(sdrBin: 128, of: 256))
        XCTAssertEqual(HistogramCardFormat.hoverRowText(knownCounts, code),
                       "R 1284 G 1291 B 1206")
        let tail = axis.hoverReading(atX: axis.x(hdrBin: 128))
        XCTAssertEqual(HistogramCardFormat.hoverRowText(knownCounts, tail),
                       "R 903 G 910 B 825")
        // An unmeasured card has no counts to print — and no level either: the level belongs to the
        // pixel under the pointer, not to the axis.
        XCTAssertNil(HistogramCardFormat.hoverRowText(nil, code))
    }

    /// One row, two contents, one height — and the **pixel half is blank** while the pointer is on the
    /// plot, because a hover points at a bin, not at a pixel.
    ///
    /// This is the semantics the percentages row used to carry (it never changed, whatever the pointer
    /// did); the owner replaced that row with the cursor pixel, so the assertions below are the ones that
    /// replaced "通道行永远是过白比例". 023 then deleted the second row, so the two contents share the
    /// slot instead of sitting one above the other.
    func testTheDrawnCardPaintsTheCountsAndLeavesThePixelHalfBlank() {
        let card = drawnCard(histogram: knownCounts)
        let idleSlot = card.readoutRowRect
        let channelSlot = card.channelRowRect
        XCTAssertNil(card.hoverRowText, "没悬停 → 这一行是空的")
        XCTAssertTrue(card.hoverRowRect.isEmpty)
        XCTAssertEqual(card.channelRowText, "", "没有指针在画面上 → 像素那半也是空的")
        XCTAssertFalse(channelSlot.isEmpty, "…但它在")

        let axis = HistogramAxis(plot: NSRect(x: 0, y: 0, width: minimumCardWidth, height: 58))
        card.updateHoverReadout(at: CGPoint(x: axis.x(sdrBin: 128, of: 256), y: 20))
        render(card)

        XCTAssertEqual(card.hoverRowText, "R 1284 G 1291 B 1206")
        XCTAssertEqual(card.channelRowText, "", "指针在直方图上 → 像素那半空白（不显示像素，也不显示比例）")
        XCTAssertTrue(card.channelLetterRects.isEmpty)
        XCTAssertFalse(card.hoverRowRect.isEmpty)
        XCTAssertEqual(card.hoverRowRect.minX, 0, accuracy: 0.01, "左对齐到卡片内容左端")
        XCTAssertEqual(card.hoverRowRect.minY, idleSlot.minY, accuracy: 0, "行位置不随状态变")
        XCTAssertEqual(card.readoutRowRect, idleSlot, "这一行的高度和位置不随状态变")
        XCTAssertEqual(card.hoverRowRect.height, HistogramCardView.readoutRowHeight, accuracy: 0.01,
                       "行高是 numberFont 的固定值，不是 string 的 sizeToFit")
        XCTAssertEqual(card.channelRowRect, channelSlot, "像素那半的槽也没动")
        // 023: the two contents are the *same* row — so 「两行不重叠」 became 「同一个槽」.
        XCTAssertEqual(card.channelRowRect, card.readoutRowRect,
                       "像素值与计数共用一个槽（023 之后卡片只有一行）")
        XCTAssertEqual(card.readoutLetterColors, HistogramCardView.channelNameColors,
                       "计数的三个字母也带通道颜色")
        print("drawn row: \"\(card.hoverRowText ?? "nil")\" · 槽 \(card.channelRowRect)（== \(card.readoutRowRect)）")

        card.clearHoverReadout()
        render(card)
        XCTAssertNil(card.hoverRowText)
        XCTAssertTrue(card.hoverRowRect.isEmpty)
        XCTAssertEqual(card.channelRowText, "")
        XCTAssertEqual(card.readoutRowRect, idleSlot, "idle 时这一行仍是同一个槽")
        XCTAssertEqual(card.channelRowRect, channelSlot)
    }

    /// The row starts at the same x for every level, and `R` starts at the same x for every count
    /// length — "the letters do not float" is a fact about the paint, not about the string.
    func testTheDrawnRowKeepsItsLeftEdgeForEveryValue() {
        let card = drawnCard(histogram: knownCounts)
        let axis = HistogramAxis(plot: NSRect(x: 0, y: 0, width: minimumCardWidth, height: 58))
        var minXs: [CGFloat] = []
        var minYs: [CGFloat] = []
        var letterXs: [CGFloat] = []
        // Three bins whose counts have three different lengths (see `knownCounts`): 41, 812, 1284.
        let samples: [(x: CGFloat, label: String)] = [
            (axis.x(hdrBin: 255), "41"),
            (axis.x(hdrBin: 64), "812"),
            (axis.x(sdrBin: 128, of: 256), "1284"),
        ]
        for sample in samples {
            card.updateHoverReadout(at: CGPoint(x: sample.x, y: 20))
            render(card)
            XCTAssertTrue(card.hoverRowText?.hasPrefix("R ") ?? false,
                          "\(card.hoverRowText ?? "nil") 以 R 开头")
            minXs.append(card.hoverRowRect.minX)
            minYs.append(card.hoverRowRect.minY)
            letterXs.append(card.readoutLetterRects[0].minX)
        }
        XCTAssertEqual(Set(minXs).count, 1, "不同计数下行起点相同：\(minXs)")
        XCTAssertEqual(Set(minYs).count, 1, "不同计数下行位置相同：\(minYs)")
        XCTAssertEqual(Set(letterXs).count, 1, "计数 41 / 812 / 1284 下 R 的 minX 相同：\(letterXs)")
        _ = samples.map(\.label)
    }

    /// A card with no measurement has no counts to print — the level in that row belongs to the pixel
    /// under the pointer, and there is no pointer on the plot's half of the row.
    func testAnUnmeasuredCardHasNothingToSayAboutABin() {
        let card = drawnCard(histogram: nil)
        card.updateHoverReadout(at: CGPoint(x: code128X, y: 20))
        render(card)
        XCTAssertEqual(card.hoverRowText, "R 0 G 0 B 0",
                       "没有测量就没有计数：三个组仍是三个 0")
        XCTAssertTrue(card.clipHighTextByChannel.allSatisfy { $0 == "—" },
                      "过白比例仍是 —（只是不再画到通道行上）")
        XCTAssertEqual(card.channelRowText, "", "通道行没有像素可读 → 空白，不显示 — 也不显示比例")
        XCTAssertTrue(card.channelLetterRects.isEmpty)
    }
}
