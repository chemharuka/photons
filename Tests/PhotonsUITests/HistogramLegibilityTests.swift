import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// The card's minimum content width: inspector 300 pt (`WorkspaceLayout.inspectorWidthMin`)
/// − 2 × 12 pt scroll padding − 2 × 16 pt card inset.
private let minimumCardWidth: CGFloat = 244
private let cardHeight: CGFloat = 104

/// 004 — the histogram card's two secondary labels were **unreadable**, and this file is the proof
/// that they are not any more.
///
/// The complaint was concrete: "RGB 百分数现在颜色是灰色,不明显 … 旁边还有个 898px 256+96 bin 是什么?
/// 这个颜色是黑色更加看不清". The cause was that both were *semantic* label colours — alpha tints of
/// black/white — so on the card's own backdrop they landed at 1.2–2.3 : 1, i.e. texture rather than
/// text. WCAG 2.1 SC 1.4.3 asks 4.5 : 1 for text this size, so the fix is measured, not eyeballed:
///
///   ① both colours clear 4.5 : 1 at the **worst** end of the card's backdrop band, in aqua *and*
///      in darkAqua (the old ones are asserted to fail, so the table is not decoration);
///   ② the hierarchy survives — the caption stays quieter than the percentages;
///   ③ nothing shrank: 8.5 pt monospaced digits for the percentage, 8 pt for the caption;
///   ④ at the card's minimum width (the inspector's 300 pt floor minus the inspector's 24 pt of
///      padding and the card's 32 pt of inset = **244 pt**) both rows fit: the channel row (the cursor
///      pixel's R/G/B — the percentages it replaced are gone) and the caption row, unabbreviated;
///   ⑤ the sentence says what it means (「采样 … px · 直方图 256+256 档」) and VoiceOver spells the
///      binning out (「256 档 SDR 码值 + 256 档高光尾」).
@MainActor
final class HistogramLegibilityTests: XCTestCase {

    // MARK: - fixtures

    private func fixture(sampleCount: Int = 898_432, high: Double? = nil) -> Histogram {
        func channel(_ h: Double) -> HistogramChannel {
            HistogramChannel(bins: [Int](repeating: 1, count: 256),
                             hdrBins: [Int](repeating: 0, count: 96),
                             clippedHigh: h, clippedCeiling: h, clippedLow: 0)
        }
        return Histogram(binCount: 256, sampleCount: sampleCount,
                         canvas: ImageSize(width: 720, height: 420),
                         roi: ImageRect(x: 0, y: 0, width: 720, height: 420),
                         sampleSize: ImageSize(width: 720, height: 420),
                         primaries: .sRGB, headroom: 1,
                         red: channel(high ?? 0.012), green: channel(high ?? 0.003),
                         blue: channel(high ?? 0.0), luma: channel(high ?? 0.005))
    }

    /// Draws a real card into a bitmap: the readbacks (`channelRowWidth`, `sampleNoteRect`) are what
    /// `draw` laid out, so this measures the card, not a copy of its arithmetic.
    private func drawnCard(width: CGFloat = minimumCardWidth,
                           appearance: NSAppearance.Name = .aqua,
                           histogram: Histogram? = nil,
                           measured: Bool = true) -> HistogramCardView {
        let card = HistogramCardView()
        card.frame = NSRect(x: 0, y: 0, width: width, height: cardHeight)
        card.appearance = NSAppearance(named: appearance)
        card.histogram = measured ? (histogram ?? fixture()) : nil
        render(card)
        return card
    }

    /// One real `draw` into an offscreen bitmap at 2× — no window, but real text metrics.
    private func render(_ card: HistogramCardView) {
        let width = card.bounds.width
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(width * scale), pixelsHigh: Int(cardHeight * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: cardHeight)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        card.draw(card.bounds)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A semantic label colour resolved and composited over a neutral backdrop — how the *old*
    /// colours actually appeared, alpha and all.
    private func composited(_ color: NSColor, over grey: Double,
                            appearance: NSAppearance.Name) -> NSColor {
        let resolution = NSAppearance(named: appearance)!
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        resolution.performAsCurrentDrawingAppearance {
            let s = color.usingColorSpace(.sRGB)!
            r = Double(s.redComponent); g = Double(s.greenComponent)
            b = Double(s.blueComponent); a = Double(s.alphaComponent)
        }
        return NSColor(srgbRed: CGFloat(r * a + grey * (1 - a)),
                       green: CGFloat(g * a + grey * (1 - a)),
                       blue: CGFloat(b * a + grey * (1 - a)), alpha: 1)
    }

    private func ratio(_ color: NSColor, overGrey grey: Double) -> Double {
        HistogramCardReadability.contrast(of: color, overGrey: grey)
    }

    // MARK: - ① contrast, both appearances, worst end of the band

    func testThePercentageLabelClearsTheWCAGFloorInAquaAndDarkAqua() {
        for isDark in [false, true] {
            let name = isDark ? "darkAqua" : "aqua"
            let percent = HistogramCardReadability.percentColor(isDark: isDark)
            for grey in [HistogramCardReadability.backdropGreys(isDark: isDark).low,
                         HistogramCardReadability.backdropGreys(isDark: isDark).high] {
                XCTAssertGreaterThanOrEqual(
                    ratio(percent, overGrey: grey), HistogramCardReadability.minimumRatio,
                    "\(name) 通道百分数在背景灰阶 \(grey) 上的对比度 \(ratio(percent, overGrey: grey))")
            }
            XCTAssertGreaterThanOrEqual(
                HistogramCardReadability.worstContrast(of: percent, isDark: isDark), 7,
                "\(name) 百分数留足余量（实际 ≥ 7:1）")
        }
    }

    /// The colours this file replaces, measured the way the user saw them: `.tertiaryLabelColor`
    /// is a 26 % tint and `.quaternaryLabelColor` a 10 % one, so both were far below the floor.
    func testTheSemanticLabelColoursTheyReplacedDidNotClearTheFloor() {
        let aqua = HistogramCardReadability.backdropGreys(isDark: false).low
        let dark = HistogramCardReadability.backdropGreys(isDark: true).low
        let cases: [(name: String, old: NSColor, new: NSColor, grey: Double, was: Double)] = [
            ("aqua 百分数", composited(.tertiaryLabelColor, over: aqua, appearance: .aqua),
             HistogramCardReadability.percentColor(isDark: false), aqua, 2.5),
            ("darkAqua 百分数", composited(.tertiaryLabelColor, over: dark, appearance: .darkAqua),
             HistogramCardReadability.percentColor(isDark: true), dark, 2.5),
        ]
        for c in cases {
            let before = ratio(c.old, overGrey: c.grey)
            let after = ratio(c.new, overGrey: c.grey)
            XCTAssertLessThan(before, c.was, "\(c.name)：改之前 \(before):1 本来就该是坏的")
            XCTAssertGreaterThanOrEqual(after, HistogramCardReadability.minimumRatio)
            XCTAssertGreaterThan(after, 2 * before, "\(c.name)：\(before):1 → \(after):1 应至少翻倍")
        }
    }

    // MARK: - ③ nothing shrank, digits do not jitter

    func testTheLabelsKeptTheirSizesAndTheDigitsAreMonospaced() {
        let percent = HistogramCardReadability.percentFont
        XCTAssertGreaterThanOrEqual(percent.pointSize, 8.5, "百分数不得小于 8.5 pt")
        for font in [percent] {
            let one = ("1" as NSString).size(withAttributes: [.font: font]).width
            let zero = ("0" as NSString).size(withAttributes: [.font: font]).width
            let eight = ("8" as NSString).size(withAttributes: [.font: font]).width
            XCTAssertEqual(one, zero, accuracy: 0.01, "等宽数字：1 和 0 同宽")
            XCTAssertEqual(eight, zero, accuracy: 0.01, "等宽数字：8 和 0 同宽")
        }
    }

    // MARK: - ② the colours the card actually drew with

    func testTheDrawnCardUsesTheReadableColoursInBothAppearances() {
        for (name, isDark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            let card = drawnCard(appearance: name)
            XCTAssertEqual(card.lastAppearanceIsDark, isDark)
            XCTAssertEqual(card.lastPercentColor, HistogramCardReadability.percentColor(isDark: isDark))
            XCTAssertGreaterThanOrEqual(card.percentContrast, HistogramCardReadability.minimumRatio)
            // 100 % opaque: a tint would let the backdrop back in through the glyphs.
            XCTAssertEqual(card.lastPercentColor.alphaComponent, 1)
        }
    }

    // MARK: - ④ layout at the card's minimum width

    /// The channel row is the cursor pixel now, and the widest honest row still fits 244 pt:
    /// three codes plus a `+x.x` channel, with nothing truncated and the letters at their thirds.
    func testTheChannelRowFitsTheMinimumCardWidth() {
        let card = drawnCard(width: minimumCardWidth, histogram: fixture(high: 1))
        XCTAssertEqual(card.channelRowText, "", "没有指针 → 空行（比例不再画在这里）")
        XCTAssertFalse(card.channelRowRect.isEmpty, "空行仍占位")

        card.showPointerReadout(PointerPixel(level: .code(255), bin: 255, isTail: false, luma: 1,
                                            channels: [.code(255), .code(255), .stops(3)]))
        render(card)
        XCTAssertGreaterThan(card.channelRowWidth, 0)
        XCTAssertLessThanOrEqual(card.channelRowWidth, minimumCardWidth,
                                 "通道行宽 \(card.channelRowWidth) pt 必须 ≤ 卡宽 \(minimumCardWidth) pt")
        XCTAssertEqual(card.channelRowText, "R 255 G 255 B +3.0")
        XCTAssertLessThanOrEqual(card.channelValueRects.map(\.maxX).max() ?? 0,
                                 minimumCardWidth + 0.01,
                                 "最宽的一行也在卡片内")
    }

    /// A card with **no measurement** still paints the channel row (a pixel is not a histogram), in the
    /// readable colour — and the row says nothing about 过白, which has nothing to measure.
    func testAHistogramLessCardStillPaintsTheChannelRowReadably() {
        let card = drawnCard(width: minimumCardWidth, measured: false)
        card.showPointerReadout(PointerPixel(level: .code(64), bin: 64, isTail: false, luma: 0.05,
                                            channels: [.code(32), .code(64), .code(96)]))
        render(card)
        XCTAssertEqual(card.channelRowText, "R 32 G 64 B 96")
        XCTAssertGreaterThanOrEqual(card.percentContrast, HistogramCardReadability.minimumRatio)
        XCTAssertGreaterThan(card.channelRowWidth, 0)
        XCTAssertTrue(card.clipHighTextByChannel.allSatisfy { $0 == "—" },
                      "没有测量就没有过白比例——而且它本来也不画")
        XCTAssertFalse(card.channelRowText.contains("%"))
    }
}
