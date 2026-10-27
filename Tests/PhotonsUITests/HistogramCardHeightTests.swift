import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// How tall the histogram card is, and **where its ink actually stops** (2026-10-27).
///
/// The owner's report is a bottom gap, not a short plot: 「直方图卡片底部空太多了，现在直方图底部只会出现
/// 一行内容，所以可以窄一些」. 023 had merged the pixel-brightness row into the values row, and that row's
/// height was handed back as **bottom inset**, so the card kept 104 pt while its last row's ink stopped
/// at 87.5 — 16.5 pt of nothing under the readout.
///
/// The claims here are measured on a real draw (`cacheDisplay`, so the flipped CTM and the text metrics
/// are AppKit's own), never on arithmetic that mirrors the layout code:
///
///   ① **the card is its content.** `contentHeight` = top inset + plot + 5 pt gap + clipping row + the
///      one readout row = 90 pt (it was 104), and the SwiftUI frame is *this* number, not a literal;
///   ② **nothing above the readout moved.** The plot is still 58 pt at y 0, the clipping row still starts
///      5 pt under it — the height came off the bottom only;
///   ③ **the empty line is gone.** The readout row's bottom edge is the card's bottom edge in **every**
///      state (idle paints nothing, but its slot is still there), and where the row *does* paint, the ink
///      gap under the lowest pixel is ≤ 3 pt — it was 16.5 before the change;
///   ④ **the row keeps its height in every state** (023's contract) — idle paints nothing at the same
///      rect and the same height;
///   ⑤ **the card is still tall enough to draw.** `draw` bails below 60 pt; 90 > 60, and a card at
///      exactly `contentHeight` still paints its readout row;
///   ⑥ **the shipped minimum width does not truncate.** At the inspector's 244 pt every painted rect of
///      the row stays inside the card, for both contents.
///
/// The reverse check is in the task log, not in an assertion: setting `contentHeight` back to 104 makes
/// ③ red with the measured 16.5 pt gap.
@MainActor
final class HistogramCardHeightTests: XCTestCase {

    /// The inspector's shipped minimum card width: `300 − 2·12 (panel) − 2·16 (card inset)`.
    private let minimumCardWidth: CGFloat = 244

    private var cardHeight: CGFloat { HistogramCardView.contentHeight }

    // MARK: - fixtures

    /// Counts the assertions can name: `bins[128]` is where the hover lands, and the tail carries a
    /// non-zero bin so both segments draw.
    private func measuredHistogram() -> Histogram {
        func channel(_ sdr: [(Int, Int)], _ tail: [(Int, Int)]) -> HistogramChannel {
            var bins = [Int](repeating: 0, count: 256)
            for (i, v) in sdr { bins[i] = v }
            var hdr = [Int](repeating: 0, count: 64)
            for (i, v) in tail { hdr[i] = v }
            return HistogramChannel(bins: bins, hdrBins: hdr,
                                    clippedHigh: 0.012, clippedCeiling: 0.004, clippedLow: 0.001)
        }
        let red = channel([(128, 1284), (129, 7)], [(8, 812)])
        let green = channel([(128, 1291)], [(8, 819)])
        let blue = channel([(128, 1206)], [(8, 734)])
        return Histogram(binCount: 256, sampleCount: 898_432,
                         canvas: ImageSize(width: 720, height: 420),
                         roi: ImageRect(x: 0, y: 0, width: 720, height: 420),
                         sampleSize: ImageSize(width: 720, height: 420),
                         primaries: .sRGB, headroom: 1,
                         red: red, green: green, blue: blue, luma: red)
    }

    private func card(width: CGFloat = 244) -> HistogramCardView {
        let card = HistogramCardView()
        card.frame = NSRect(x: 0, y: 0, width: width, height: cardHeight)
        card.appearance = NSAppearance(named: .aqua)
        card.histogram = measuredHistogram()
        return card
    }

    /// The card's three row states, each a fresh card so no readback can leak between them.
    private func states(width: CGFloat = 244) -> [(name: String, card: HistogramCardView)] {
        let idle = card(width: width)
        let counts = card(width: width)
        counts.updateHoverReadout(at: CGPoint(x: width * 0.25, y: 30))
        let pixel = card(width: width)
        pixel.showPointerReadout(PointerPixel(encodedRed: 0.9, green: 0.2, blue: 0.1,
                                              histogram: measuredHistogram()))
        return [("idle", idle), ("counts", counts), ("pixel", pixel)]
    }

    /// One real `draw` through AppKit's offscreen path (`cacheDisplay` sets the view's own flipped CTM,
    /// so "lowest ink" means lowest on screen, not the bitmap's mirrored row). Returns the bottom edge of
    /// the lowest painted pixel, in view coordinates.
    private func lowestInkRow(_ card: HistogramCardView, scale: CGFloat = 2) -> CGFloat {
        let w = Int(card.bounds.width * scale), h = Int(cardHeight * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: card.bounds.width, height: cardHeight)
        card.cacheDisplay(in: card.bounds, to: rep)
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in 0..<w {
                if let p = rep.colorAt(x: x, y: y), p.alphaComponent > 0.02 {
                    return CGFloat(y + 1) / scale
                }
            }
        }
        return 0
    }

    // MARK: - ① the card is its content

    func testTheCardIsExactlyItsContentHeight() {
        let plot: CGFloat = 58, gap: CGFloat = 5, clipRow: CGFloat = 15
        let readoutRow = HistogramCardView.readoutRowHeight

        // The parts are the layout's own, and the sum is the number the owner's gap came off of:
        // 104 → 90, i.e. the one line the merged row freed and 023 gave back as bottom inset.
        XCTAssertEqual(HistogramCardView.contentHeight, plot + gap + clipRow + readoutRow, accuracy: 0.001,
                       "contentHeight must be the sum of the parts, not a second geometry")
        XCTAssertEqual(HistogramCardView.contentHeight, 90, accuracy: 0.001,
                       "the card is 90 pt; 104 was the two-row height 023 left behind")
        XCTAssertLessThan(HistogramCardView.contentHeight, 104,
                          "the bottom gap is not removed if the card is still the old height")

        // One height, from one source: the intrinsic size and the SwiftUI frame read the same constant.
        let intrinsic = HistogramCardView().intrinsicContentSize.height
        XCTAssertEqual(intrinsic, HistogramCardView.contentHeight, accuracy: 0.001,
                       "intrinsicContentSize disagrees with contentHeight")
        let source = try? String(contentsOf: Self.histogramCardSource, encoding: .utf8)
        XCTAssertEqual(source?.contains(".frame(height: HistogramCardView.contentHeight)"), true,
                       "the SwiftUI host must frame the card at contentHeight, not at a literal")
        XCTAssertEqual(source?.contains("height: 104"), false,
                       "a 104 pt literal survives in HistogramCard.swift")

        print(String(format: "CARD HEIGHT: 104 → %.1f pt (plot %.1f + gap %.1f + clip row %.1f + readout row %.1f)",
                     HistogramCardView.contentHeight, plot, gap, clipRow, readoutRow))
    }

    private static var histogramCardSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsUI/HistogramCard.swift")
    }

    // MARK: - ② nothing above the readout moved

    func testThePlotAndTheClippingRowDidNotMove() throws {
        let card = card()
        _ = lowestInkRow(card)   // a real draw, through a real context (lastAxis is a readback of it)
        let plot = try XCTUnwrap(card.lastAxis?.plot)
        XCTAssertEqual(plot.minY, 0, accuracy: 0.001, "the plot still starts at the card's top edge")
        XCTAssertEqual(plot.height, 58, accuracy: 0.001,
                       "the plot is untouched — the complaint was the bottom gap, not a short plot")
        XCTAssertEqual(plot.width, card.bounds.width, accuracy: 0.001,
                       "the plot still spans the card's width")
        // The clipping row: 5 pt under the plot's bottom edge, as `drawClipRows` draws its text.
        XCTAssertEqual(card.clipHighHitRect.minY, plot.maxY + 3, accuracy: 0.001,
                       "过白 keeps its 5 pt gap under the plot (hit rect is the glyph box −2 pt)")
        XCTAssertEqual(card.readoutRowRect.minY, plot.maxY + 5 + 15, accuracy: 0.001,
                       "the one row still starts where the clipping row ends")
        print(String(format: "PLOT: y %.1f h %.1f · clip row y %.1f · readout row y %.1f h %.1f",
                     plot.minY, plot.height, card.clipHighHitRect.minY,
                     card.readoutRowRect.minY, card.readoutRowRect.height))
    }

    // MARK: - ③ the empty line is gone, in every state

    func testTheEmptySpaceUnderTheReadoutIsGone() {
        for (name, card) in states() {
            let inkBottom = lowestInkRow(card)
            let gap = cardHeight - inkBottom
            let slotGap = cardHeight - card.readoutRowRect.maxY
            // Printed for the record: this was 16.5 pt before the change (ink stopped at 87.5 in 104).
            print(String(format: "GAP [%@]: card %.1f · ink bottom %.1f · empty under ink %.1f pt · empty under the row slot %.1f pt",
                         name, cardHeight, inkBottom, gap, slotGap))
            // The height claim holds in every state: the slot's bottom edge *is* the card's bottom edge,
            // so nothing inside the card sits below the row (idle included — an idle card has no ink
            // under the clipping row, which is why the ink gap is only asserted where the row paints).
            XCTAssertEqual(slotGap, 0, accuracy: 0.001,
                           "[\(name)] the readout slot's bottom edge must be the card's bottom edge")
            guard name != "idle" else { continue }
            XCTAssertLessThanOrEqual(gap, 3,
                                     "[\(name)] \(gap) pt of nothing under the readout — the gap is back")
            XCTAssertGreaterThanOrEqual(gap, 0,
                                        "[\(name)] the readout paints past the card's bottom edge")
        }
    }

    // MARK: - ④ one row, one height, in every state

    func testTheRowKeepsItsHeightWhenIdle() {
        let all = states()
        // The rect is a readback of a draw, so each card is drawn once before it is read.
        for (_, card) in all { _ = lowestInkRow(card) }
        let rows = all.map { $0.card.readoutRowRect }
        for (i, row) in rows.enumerated() {
            XCTAssertEqual(row.minY, rows[0].minY, accuracy: 0.001,
                           "\(all[i].name) moved the row: \(row) vs \(rows[0])")
            XCTAssertEqual(row.height, rows[0].height, accuracy: 0.001,
                           "\(all[i].name) changed the row's height")
        }
        // And the height is the font constant, so no text can change it.
        XCTAssertEqual(rows[0].height, HistogramCardView.readoutRowHeight, accuracy: 0.001)
    }

    // MARK: - ⑤ still tall enough to draw

    func testTheCardStillPassesTheDrawGuard() {
        XCTAssertGreaterThan(HistogramCardView.contentHeight, 60,
                             "`draw` returns below 60 pt — the card must stay above that")
        // Drawn at exactly contentHeight, the counts row paints inside the card.
        let card = card()
        card.updateHoverReadout(at: CGPoint(x: 61, y: 30))
        _ = lowestInkRow(card)
        XCTAssertFalse(card.readoutValueTexts.isEmpty, "the row painted nothing at the new height")
        XCTAssertLessThanOrEqual(card.readoutContentRect.maxY, cardHeight + 0.01,
                                 "the reading is cut by the card's bottom edge")
        XCTAssertGreaterThan(card.readoutContentRect.maxY, card.readoutRowRect.minY,
                             "the reading is not in the row")
    }

    // MARK: - ⑥ the shipped minimum width does not truncate

    func testNothingIsTruncatedAtTheMinimumWidth() {
        for (name, card) in states(width: minimumCardWidth) {
            for rect in card.readoutLetterRects + card.readoutValueRects
                + card.channelLetterRects + card.channelValueRects {
                XCTAssertLessThanOrEqual(rect.maxX, minimumCardWidth + 0.01,
                                         "[\(name)] a painted rect runs past the 244 pt card: \(rect)")
            }
        }
        // The widest counts the card can print in a fused SDR half (16 777 216 samples is a 60 MP
        // frame): all three groups still fit at 244 pt, which is the case that would clip first.
        let card = card(width: minimumCardWidth)
        card.updateHoverReadout(at: CGPoint(x: 61, y: 30))
        let widest = [String](repeating: "16777216", count: 3)
        let groupWidth = minimumCardWidth / 3
        let spaceWidth = (" " as NSString).size(
            withAttributes: [.font: HistogramCardView.numberFont]).width
        let letterWidth = ("R" as NSString).size(
            withAttributes: [.font: HistogramCardView.channelLetterFont]).width
        let valueWidth = (widest[0] as NSString).size(
            withAttributes: [.font: HistogramCardView.numberFont]).width
        print(String(format: "WIDTH: group %.1f pt · widest value %.1f pt (+letter %.1f +space %.1f)",
                     groupWidth, valueWidth, letterWidth, spaceWidth))
        XCTAssertLessThanOrEqual(letterWidth + spaceWidth + valueWidth, groupWidth + 0.01,
                                 "the widest count outgrows its third at 244 pt — the row would overlap")
    }
}
