import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// 464 — 「削顶」must follow screen brightness while the bins stand still.
///
/// The bug: 削顶 was the stored `HistogramChannel.clippedScreen`, computed once with the headroom the
/// measurement happened to carry. A brightness change moves `maximumExtendedDynamicRangeColorComponentValue`,
/// but `Histogram.cacheKey` has no headroom in it, so the same measurement is served and the stored
/// ratio never moves — while the 「屏 x.xx×」 chip and the tick *are* live. Two numbers, two screens.
///
/// The fix is the split asserted here: the **bins** are the panel-independent asset, and 削顶 is a
/// *read-time derivation* from them (`clippedFraction(atOrAbove:)`). So:
///
///   ① one fixed `Histogram`, headrooms `1.0 → 3.2 → 4.08`: the painted text changes every time and
///      matches `clippedFraction` bit for bit;
///   ② the chip's headroom (`lastCeilingHeadroom`, read off the paint) and the one the percentage was
///      derived with are the same number;
///   ③ the three curves' `points` and `lastDrawnBins` cannot move — proof the re-read did not turn into
///      a re-measure;
///   ④ the reverse gate: the stored `clippedScreen` prints one and the same text for all three
///      headrooms, so a paint that read it would fail ①.
@MainActor
final class HistogramCeilingIsLive464Tests: XCTestCase {

    private let headrooms: [Double] = [1.0, 3.2, 4.08]
    private let cardWidth: CGFloat = 400

    // MARK: - fixtures

    /// A fixed distribution with mass spread across the tail, so the three headrooms land in three
    /// different bins:
    ///
    ///   · `1.0×`  → last SDR bin + **all** tail bins;
    ///   · `3.2×`  → tail bin 107 (`log2(3.2)×64 ≈ 107.4`) and later;
    ///   · `4.08×` → tail bin 129 (`log2(4.08)×64 ≈ 129.8`) and later.
    ///
    /// `clippedScreen` is a fixed diagnostic (7.0 %) that matches none of the live values — that is
    /// the frozen number 464 stops painting.
    private func fixture() -> Histogram {
        func channel(tail: [(Int, Int)], sdrPeak: Int) -> HistogramChannel {
            var bins = [Int](repeating: 0, count: 256)
            bins[128] = sdrPeak
            bins[255] = 200
            var hdr = [Int](repeating: 0, count: Histogram.hdrBinCount)
            for (index, count) in tail { hdr[index] = count }
            return HistogramChannel(bins: bins, hdrBins: hdr,
                                    clippedHDR: 0.09, clippedScreen: 0.07, clippedBlack: 0.01)
        }
        // Σ = 9100 + 200 + (100 + 120 + 140 + 160 + 180) = 10000.
        let tail = [(0, 100), (64, 120), (107, 140), (130, 160), (200, 180)]
        let red = channel(tail: tail, sdrPeak: 9100)
        let green = channel(tail: tail, sdrPeak: 9100)
        let blue = channel(tail: tail, sdrPeak: 9100)
        return Histogram(binCount: 256, sampleCount: 10_000,
                         canvas: ImageSize(width: 720, height: 420),
                         roi: ImageRect(x: 0, y: 0, width: 720, height: 420),
                         sampleSize: ImageSize(width: 720, height: 420),
                         primaries: .sRGB, headroom: 1,
                         red: red, green: green, blue: blue, luma: red)
    }

    private func makeCard(source: HeadroomSource, histogram: Histogram) -> HistogramCardView {
        let card = HistogramCardView()
        card.frame = NSRect(x: 0, y: 0, width: cardWidth, height: HistogramCardView.contentHeight)
        card.appearance = NSAppearance(named: .aqua)
        card.headroomSource = source
        card.histogram = histogram
        return card
    }

    /// One real `draw` through AppKit's offscreen path. Every readback below is off the paint.
    private func render(_ card: HistogramCardView, scale: CGFloat = 2) {
        let w = max(1, Int(card.bounds.width * scale)), h = max(1, Int(card.bounds.height * scale))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = card.bounds.size
        card.needsDisplay = true
        card.cacheDisplay(in: card.bounds, to: rep)
    }

    /// `(injected headroom, painted 削顶 text, chip's headroom, effectiveHeadroom)` for each value,
    /// captured per frame through a real draw (not read after the loop).
    private func paintedRows(_ card: HistogramCardView,
                             source: FixedHeadroomSource)
        -> [(headroom: Double, text: String, chip: Double, effective: Double)] {
        var rows: [(headroom: Double, text: String, chip: Double, effective: Double)] = []
        for headroom in headrooms {
            source.headroom = headroom
            card.noteFramePresented()
            render(card)
            rows.append((headroom, card.clipCeilingText,
                         card.lastCeilingHeadroom, card.effectiveHeadroom))
        }
        return rows
    }

    // MARK: - ① the percentage follows the injected brightness

    func testClippingFollowsTheInjectedHeadroom() {
        let histogram = fixture()
        let source = FixedHeadroomSource(headroom: 1)
        let card = makeCard(source: source, histogram: histogram)
        let rows = paintedRows(card, source: source)

        for row in rows {
            let (headroom, text) = (row.headroom, row.text)
            let fraction = histogram.luma.clippedFraction(atOrAbove: headroom)
            let expected = HistogramCardFormat.percent(fraction)
            XCTAssertEqual(text, expected,
                           "\(headroom)×：削顶必须逐位等于 clippedFraction(atOrAbove:)，得到 \(text) vs \(expected)")
            XCTAssertEqual(text, HistogramCardFormat.clipCeiling(histogram, .luma, headroom: headroom),
                           "\(headroom)×：卡片新接缝（带 headroom 的 clipCeiling）必须给出同一个文本")
        }

        // 1.0× = 900/10000 = 9.0 %; 3.2× = 480/10000 = 4.8 %; 4.08× = 340/10000 = 3.4 %.
        XCTAssertEqual(rows.map(\.text), ["9.0%", "4.8%", "3.4%"],
                       "三个 headroom 必须给出三个不同的读数（实际 \(rows.map(\.text))）")
        print("464 ① 削顶随亮度：\(rows.map { String(format: "%.2f×→%@", $0.headroom, $0.text) }.joined(separator: " · "))")
    }

    // MARK: - ② the chip and the percentage are the same number

    func testChipAndClippingUseTheSameHeadroom() {
        let histogram = fixture()
        let source = FixedHeadroomSource(headroom: 1)
        let card = makeCard(source: source, histogram: histogram)
        let rows = paintedRows(card, source: source)

        for row in rows {
            XCTAssertEqual(row.chip, row.effective, accuracy: 1e-12,
                           "chip 用的 headroom 与 effectiveHeadroom 必须是同一个数")
            XCTAssertEqual(row.effective, row.headroom, accuracy: 1e-12,
                           "注入的 \(row.headroom)× 必须成为卡片的 effectiveHeadroom")
            let expected = HistogramCardFormat.percent(
                histogram.luma.clippedFraction(atOrAbove: row.chip))
            XCTAssertEqual(row.text, expected,
                           "\(row.headroom)×：削顶用的 headroom 必须就是 chip 的 \(row.chip)×")
        }
        print("464 ② chip \(card.lastCeilingText) · 削顶 \(rows.last?.text ?? "—") · "
              + "同一个 headroom \(String(format: "%.2f", card.lastCeilingHeadroom))×")
    }

    // MARK: - ③ only the readout moves; the bins do not

    func testOnlyTheReadoutMovesAndTheBinsDoNot() throws {
        let histogram = fixture()
        let source = FixedHeadroomSource(headroom: 1)
        let card = makeCard(source: source, histogram: histogram)
        let digestBefore = histogram.binsDigest()
        var previousPoints: [[CGPoint]]?
        var previousBins = 0

        for headroom in headrooms {
            source.headroom = headroom
            card.noteFramePresented()
            render(card)

            let axis = try XCTUnwrap(card.lastAxis)
            let peak = HistogramCardFormat.scalePeak([histogram[.red], histogram[.green], histogram[.blue]])
            let points = [Histogram.Channel.red, .green, .blue].map {
                HistogramCardFormat.points(histogram[$0], binCount: histogram.binCount,
                                           axis: axis, peak: peak)
            }

            if let previousPoints {
                XCTAssertEqual(points, previousPoints,
                               "\(headroom)×：三条曲线的 points 必须与上一帧完全相同")
                XCTAssertEqual(card.lastDrawnBins, previousBins,
                               "\(headroom)×：lastDrawnBins 必须不动")
            } else {
                XCTAssertEqual(card.lastDrawnBins, histogram.binCount + histogram.hdrBinCount)
            }
            XCTAssertEqual(histogram.binsDigest(), digestBefore,
                           "\(headroom)×：bins 摘要必须不变 — 没有重新测量")
            previousPoints = points
            previousBins = card.lastDrawnBins
        }
        print("464 ③ 三帧 \(previousPoints?.count ?? 0) 条曲线 · points 逐位相同 · "
              + "lastDrawnBins \(previousBins) · digest \(digestBefore.prefix(12))…")
    }

    // MARK: - ④ the reverse gate

    func testAPaintThatReadsTheStoredRatioWouldFailTheLiveCheck() {
        let histogram = fixture()
        let source = FixedHeadroomSource(headroom: 1)
        let card = makeCard(source: source, histogram: histogram)
        let rows = paintedRows(card, source: source)

        // The frozen diagnostic — the old paint source — is one text for every screen.
        let frozen = HistogramCardFormat.percent(histogram.luma.clippedScreen)
        XCTAssertEqual(frozen, "7.0%")
        XCTAssertEqual(Set(rows.map(\.text)), Set(["9.0%", "4.8%", "3.4%"]))
        XCTAssertFalse(rows.map(\.text).contains(frozen),
                       "如果绘制退回 clippedScreen，三个 headroom 都会印 \(frozen)；那样 ① 的断言必红")
        print("464 ④ 反向门：clippedScreen 恒为 \(frozen)，派生的三帧是 \(rows.map(\.text))")
    }
}
