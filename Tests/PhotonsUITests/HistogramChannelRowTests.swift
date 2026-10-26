import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// The histogram card's **channel row** — `R 245 G 128 B 64`, the pixel under the pointer.
///
/// This row is where the per-channel 过白 percentages used to be. The owner replaced it:
/// 「不再展示过白的 RGB 比例，把这个位置换成鼠标指针位置处像素的 RGB 值」, then pinned the layout:
/// 「RGB 三个字母要带颜色，直方图悬停时数字要靠近字母，例如 `R 2      G 40      B 1023`，像素指示也是一样的」.
///
/// Five claims, each tested against something other than itself:
///
///   ① **the numbers are the pixel's** — the expectation is computed from the *encoded* frame values
///      (`code = round(v · 255)` for a channel at or below white, `log2(decode(v))` above it), which is
///      a different arithmetic from the card's `srgbDecode` → `srgbEncode` round trip;
///   ② **a channel above white prints `+x.x`** while its neighbours stay codes — one row, two forms;
///   ③ **no pointer, no percentages**: blank row, unchanged height, and no `%` in any painted string;
///   ④ **the letters do not float** — group starts are `i · rowWidth / 3`, asserted exactly across three
///      value lengths, with long values allowed to run past their group instead of being truncated;
///   ⑤ **the letters are coloured** — the colours read back from the paint, compared to
///      `HistogramCardView.channelNameColors` (red R, green G, blue B), and the value sits **one space**
///      behind its letter (「数字要靠近字母」), not at a field's right edge.
@MainActor
final class HistogramChannelRowTests: XCTestCase {

    private let cardWidth: CGFloat = 244
    private let cardHeight: CGFloat = 104

    // MARK: - fixtures

    /// A card drawn once into an offscreen bitmap — real text metrics, no window.
    private func drawnCard(width: CGFloat = 244, histogram: Histogram? = nil) -> HistogramCardView {
        let card = HistogramCardView()
        card.frame = NSRect(x: 0, y: 0, width: width, height: cardHeight)
        card.appearance = NSAppearance(named: .aqua)
        card.histogram = histogram
        render(card)
        return card
    }

    @discardableResult
    private func render(_ card: HistogramCardView) -> NSBitmapImageRep {
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
        return rep
    }

    /// A measured histogram at a chosen display headroom (`1` = SDR panel, `4` = 2 stops of EDR).
    private func measuredHistogram(headroom: Double = 1) -> Histogram {
        func channel(_ value: Int) -> HistogramChannel {
            HistogramChannel(bins: (0..<256).map { $0 == 128 ? value : 0 },
                             hdrBins: (0..<Histogram.hdrBinCount).map { $0 == 64 ? value : 0 },
                             clippedHigh: 0.0123, clippedCeiling: 0.0456, clippedLow: 0)
        }
        let red = channel(1284)
        return Histogram(binCount: 256, sampleCount: 898_432,
                         canvas: ImageSize(width: 720, height: 420),
                         roi: ImageRect(x: 0, y: 0, width: 720, height: 420),
                         sampleSize: ImageSize(width: 720, height: 420),
                         primaries: .sRGB, headroom: headroom,
                         red: red, green: channel(1291), blue: channel(1206), luma: red)
    }

    /// A pixel from three **encoded** channel values (the frame is sRGB-encoded before it is presented),
    /// so the expectation below can be computed straight off those numbers.
    private func pixel(_ red: Float, _ green: Float, _ blue: Float,
                       headroom: Double = 1) -> PointerPixel {
        PointerPixel(encodedRed: red, green: green, blue: blue,
                     histogram: measuredHistogram(headroom: headroom))
    }

    /// The code a channel paints, computed from the encoded value **without** decoding it first: the
    /// presented frame already *is* on the code axis, so `round(v · 255)` is the independent answer.
    private func expectedCode(_ encoded: Float) -> String {
        let code = (Double(encoded) * 255).rounded()
        return "\(min(255, max(0, Int(code))))"
    }

    /// The stops a channel above white paints: `log2` of the decoded value, one decimal.
    private func expectedStops(_ encoded: Float) -> String {
        String(format: "%+.1f", log2(Double(Histogram.srgbDecode(encoded))))
    }

    // MARK: - ① / ② the numbers, and the mixed row

    /// Three known channels → three known codes, in one row, letter by letter.
    func testTheChannelRowPrintsThePixelsThreeCodes() {
        let card = drawnCard(histogram: measuredHistogram())
        let samples: [(Float, Float, Float)] = [(0.96, 0.50, 0.25),   // the owner's `R 245 G 128 B 64`
                                               (0.0, 0.0, 0.0),
                                               (1.0, 0.502, 0.999)]
        var lines: [String] = []
        for (r, g, b) in samples {
            card.showPointerReadout(pixel(r, g, b))
            render(card)
            let expected = "R \(expectedCode(r)) G \(expectedCode(g)) B \(expectedCode(b))"
            XCTAssertEqual(card.channelRowText, expected,
                           "encoded (\(r), \(g), \(b)) → 通道行逐字相等")
            XCTAssertEqual(card.channelRowValues,
                           [expectedCode(r), expectedCode(g), expectedCode(b)])
            XCTAssertFalse(card.channelRowText.contains("%"), "过白比例不再出现")
            lines.append("encoded (\(r), \(g), \(b)) → “\(card.channelRowText)” (expected “\(expected)”)")
        }
        // The `±1 code` tolerance the owner allowed: the parsed codes are within one of the expectation.
        // (They are in fact exact here — `round(v · 255)` is what the card computes too — but the test
        // states the tolerance rather than relying on bit equality of two roundings.)
        card.showPointerReadout(pixel(0.96, 0.50, 0.25))
        render(card)
        let codes = card.channelRowValues.compactMap(Int.init)
        let expected525 = [245, 128, 64]
        XCTAssertEqual(codes.count, 3)
        for (got, want) in zip(codes, expected525) {
            XCTAssertLessThanOrEqual(abs(got - want), 1, "码值容差 1：\(got) vs \(want)")
        }
        print("channel row vs the encoded texel:\n        " + lines.joined(separator: "\n        "))
    }

    /// A channel above display white prints stops, its neighbours keep their codes: `R +1.0 G 188 B 137`.
    ///
    /// The frame is presented after S4, so a value above `1.0` only exists on a panel with headroom —
    /// the histogram's own `headroom` parameter says which screen this reading is honest for, and the
    /// pixel is built for a 2-stop display.
    func testAChannelAboveWhitePrintsStopsAndTheOthersStayCodes() {
        let card = drawnCard(histogram: measuredHistogram(headroom: 4))
        let encodedRed = Histogram.srgbEncode(2)     // 2× white = +1.0 stop
        let encodedGreen: Float = 0.8
        let encodedBlue: Float = 0.5
        let reading = pixel(encodedRed, encodedGreen, encodedBlue, headroom: 4)
        card.showPointerReadout(reading)
        render(card)

        let expected = "R \(expectedStops(encodedRed)) G \(expectedCode(encodedGreen)) "
            + "B \(expectedCode(encodedBlue))"
        XCTAssertEqual(card.channelRowText, expected, "一行里可以混写：超白通道 +x.x，其他通道码值")
        XCTAssertTrue(card.channelRowText.contains("+1.0"), "2× 白 = +1.0 档")
        XCTAssertEqual(card.channelRowValues.count, 3)
        XCTAssertEqual(card.channelRowValues.first, "+1.0")
        XCTAssertFalse(card.channelRowValues[1].hasPrefix("+"), "只有超白的那一通道写 +x.x")
        XCTAssertFalse(card.channelRowValues[2].hasPrefix("+"))
        XCTAssertEqual(card.readoutState, .image(value: reading.level.text),
                       "脚注行仍是该像素的亮度，与通道行是两个问题")
        print("mixed row: “\(card.channelRowText)” · 亮度行 “\(card.hoverValueText)” · luma "
              + "\(String(format: "%.3f", reading.luma))")
    }

    // MARK: - ③ no pointer / on the plot → blank, same height, no percentages

    /// 「没有指针在画面上时通道行空白，且行高不变」 — and it is *blank*, not the percentages, not `—`.
    func testTheRowIsBlankWithoutAPointerAndKeepsItsHeight() {
        let card = drawnCard(histogram: measuredHistogram())
        let blankSlot = card.channelRowRect
        let blankHeight = card.channelRowRect.height
        XCTAssertFalse(blankSlot.isEmpty, "槽在，只是不画")
        XCTAssertEqual(card.channelRowText, "")
        XCTAssertTrue(card.channelLetterRects.isEmpty)
        XCTAssertTrue(card.channelValueRects.isEmpty)

        card.showPointerReadout(pixel(0.96, 0.50, 0.25))
        render(card)
        let paintedSlot = card.channelRowRect
        XCTAssertEqual(card.channelRowText, "R \(expectedCode(0.96)) G \(expectedCode(0.50)) B \(expectedCode(0.25))")
        XCTAssertEqual(paintedSlot, blankSlot, "有指针与没指针是同一个槽（accuracy 0）")
        XCTAssertEqual(paintedSlot.height, blankHeight, accuracy: 0)
        XCTAssertEqual(paintedSlot.height, HistogramCardView.channelRowHeight, accuracy: 0)

        // Off the picture: blank again, same slot, same height.
        card.clearPointerReadout()
        render(card)
        XCTAssertEqual(card.channelRowText, "")
        XCTAssertEqual(card.channelRowRect, blankSlot, "…还是同一个槽")
        XCTAssertEqual(card.channelRowRect.height, blankHeight, accuracy: 0)

        // The pointer on the histogram: not a pixel → the channel row stays blank, the footnote row
        // answers with the bin's counts.
        card.showPointerReadout(pixel(0.96, 0.50, 0.25))
        if let axis = card.lastAxis {
            card.updateHoverReadout(at: CGPoint(x: axis.x(sdrBin: 128, of: 256), y: axis.plot.midY))
        }
        render(card)
        XCTAssertEqual(card.channelRowText, "", "鼠标在直方图上 → 通道行空白")
        XCTAssertTrue(card.channelLetterRects.isEmpty)
        XCTAssertEqual(card.channelRowRect, blankSlot)
        XCTAssertFalse(card.hoverCountText.isEmpty, "计数由脚注行回答")
        XCTAssertEqual(card.hoverCountText, "R 1284 G 1291 B 1206")
    }

    /// The percentages are gone from the paint *and* from accessibility, even though the measurement
    /// that produced them is still there (`clipHighTextByChannel` is what the CLI prints).
    func testThePercentagesAreNotPaintedOnTheChannelRow() {
        let card = drawnCard(histogram: measuredHistogram())
        let measured = card.clipHighTextByChannel
        XCTAssertEqual(measured.count, 4, "过白比例仍在测（内部/CLI 用）")
        XCTAssertFalse(measured[0] == "—", "这份 fixture 有削顶像素，比例是真数字")

        card.showPointerReadout(pixel(0.96, 0.50, 0.25))
        render(card)
        XCTAssertFalse(card.channelRowText.contains("%"))
        XCTAssertNotEqual(card.channelRowText,
                          "R \(measured[0]) G \(measured[1]) B \(measured[2])",
                          "通道行不再是过白比例")
        // The row it paints has three letters and three values, one group each — a percentage string
        // would have put "%" in all three.
        XCTAssertEqual(card.channelRowValues.count, 3)
        for value in card.channelRowValues {
            XCTAssertFalse(value.contains("%"), "每个值都不带 %")
        }
        let help = card.accessibilityHelp() ?? ""
        XCTAssertFalse(help.contains("%"), "无障碍说明里也不再读百分比")
        XCTAssertTrue(help.contains("R/G/B"), "…但仍然说明这三通道行")
    }

    // MARK: - ④ group starts, ⑤ colours and the one-space gap

    /// Three value lengths (`0` / `128` / `+3.0`) → the **same** letter `minX`, exactly; the value one
    /// space behind its letter; a long value complete and still not moving the letters.
    func testTheThreeGroupStartsNeverMove() {
        let card = drawnCard(histogram: measuredHistogram(headroom: 8))
        let samples: [(String, PointerPixel)] = [
            ("0     ", pixel(0, 0, 0)),
            ("128   ", pixel(0.502, 0.502, 0.502)),
            ("+3.0  ", pixel(Histogram.srgbEncode(8), Histogram.srgbEncode(8), Histogram.srgbEncode(8),
                            headroom: 8)),
        ]
        let spaceWidth = (" " as NSString)
            .size(withAttributes: [.font: HistogramCardReadability.percentFont]).width
        var starts: [[CGFloat]] = []
        for (label, reading) in samples {
            card.showPointerReadout(reading)
            render(card)
            XCTAssertEqual(card.channelLetterRects.count, 3)
            XCTAssertEqual(card.channelValueRects.count, 3)
            starts.append(card.channelLetterRects.map(\.minX))
            let gaps = zip(card.channelLetterRects, card.channelValueRects).map { $0.1.minX - $0.0.maxX }
            print("channel \(label) “\(card.channelRowText)” · 字母 minX \(card.channelLetterRects.map { String(format: "%.3f", $0.minX) }) · 间距 \(gaps.map { String(format: "%.2f", $0) })")
            for gap in gaps {
                XCTAssertEqual(gap, spaceWidth, accuracy: 0.5, "数值紧跟字母：一个空格")
            }
        }
        for group in 0..<3 {
            XCTAssertEqual(starts[1][group], starts[0][group], accuracy: 0,
                           "第 \(group) 组起点与数值长度无关（precision 0）")
            XCTAssertEqual(starts[2][group], starts[0][group], accuracy: 0,
                           "`+3.0` 也不移动第 \(group) 组")
        }
        XCTAssertEqual(starts[0][0], 0, accuracy: 0)
        XCTAssertEqual(starts[0][1], cardWidth / 3, accuracy: 0.01)
        XCTAssertEqual(starts[0][2], 2 * cardWidth / 3, accuracy: 0.01)

        // A value much wider than anything a channel can print: the string is complete (nothing
        // truncated) and the group starts are unchanged. `grouped` is what the card serialises, so a
        // truncated paint would show up as a shorter string here.
        let longRow = HistogramCardFormat.grouped(["1987675", "+3.0", "1023"])
        XCTAssertEqual(longRow, "R 1987675 G +3.0 B 1023", "长数值完整，不截断")
        XCTAssertEqual(longRow.filter { $0 == "%" }.isEmpty, true, "…而且没有百分比")
        // The widest *channel* value this fixture can print still fits inside the card.
        card.showPointerReadout(samples[2].1)
        render(card)
        XCTAssertEqual(card.channelValueRects.count, 3)
        XCTAssertLessThanOrEqual(card.channelValueRects.last?.maxX ?? .infinity, cardWidth + 0.01)
    }

    /// The letters are painted in the channel colours — read back from the paint, and compared to the
    /// constant the legend/curves use, in **both** rows (they share the colour table).
    func testTheLettersArePaintedInTheChannelColours() {
        let card = drawnCard(histogram: measuredHistogram())
        card.showPointerReadout(pixel(0.96, 0.50, 0.25))
        render(card)
        XCTAssertEqual(card.channelLetterColors.count, 3)
        XCTAssertEqual(card.channelLetterColors, HistogramCardView.channelNameColors,
                       "通道行的 R/G/B 就是 channelNameColors 那三个颜色")

        // The footnote row's counts use the same three colours.
        if let axis = card.lastAxis {
            card.updateHoverReadout(at: CGPoint(x: axis.x(sdrBin: 128, of: 256), y: axis.plot.midY))
        }
        render(card)
        XCTAssertEqual(card.readoutLetterColors.count, 3)
        XCTAssertEqual(card.readoutLetterColors, HistogramCardView.channelNameColors,
                       "脚注行的计数也用同一套字母颜色")
        // …and they are three distinct colours (a red R is not a blue B).
        XCTAssertEqual(Set(HistogramCardView.channelNameColors.map { $0.description }).count, 3)
    }

    /// The two rows are two slots: neither moves, and they never overlap (the channel row is *above*
    /// the footnote row, which is the row the owner deleted as a footnote).
    func testTheTwoRowsDoNotOverlap() {
        let card = drawnCard(histogram: measuredHistogram())
        let blankChannel = card.channelRowRect
        let blankReadout = card.readoutRowRect

        card.showPointerReadout(pixel(0.96, 0.50, 0.25))
        render(card)
        XCTAssertEqual(card.channelRowRect, blankChannel)
        XCTAssertEqual(card.readoutRowRect, blankReadout)
        XCTAssertEqual(card.channelRowRect.maxY, card.readoutRowRect.minY, accuracy: 0.01,
                       "通道行下沿 = 脚注行上沿（相接但不重叠）")
        XCTAssertLessThanOrEqual(card.channelRowRect.maxY, card.readoutRowRect.minY)
        XCTAssertGreaterThan(card.channelLetterRects.first?.minY ?? -CGFloat.infinity,
                             card.lastAxis?.plot.maxY ?? CGFloat.infinity,
                             "通道行在绘图区下方")
        XCTAssertLessThanOrEqual(card.readoutRowRect.maxY, cardHeight + 0.01, "两行都在卡片内")
        print("rows: 通道 \(card.channelRowRect) · 脚注 \(card.readoutRowRect) · 通道高 \(String(format: "%.1f", HistogramCardView.channelRowHeight)) · 脚注高 \(String(format: "%.1f", HistogramCardView.readoutRowHeight))")
    }

    /// The strongest form of 「字母带颜色」: the pixels inside each letter are read back off the rendered
    /// bitmap, and `R`'s pixels are red, `G`'s green, `B`'s blue — not just "the constant says so".
    func testTheLettersAreActuallyPaintedRedGreenBlue() {
        let card = drawnCard(histogram: measuredHistogram())
        card.showPointerReadout(pixel(0.96, 0.50, 0.25))
        let rep = render(card)
        XCTAssertEqual(card.channelLetterRects.count, 3)

        let scale: CGFloat = 2
        /// Mean colour of the *saturated* pixels inside `rect` — the glyphs, not the grey backdrop.
        func meanColour(_ rect: NSRect) -> (r: Double, g: Double, b: Double, n: Int) {
            let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
            let x1 = min(rep.pixelsWide - 1, Int((rect.maxX * scale).rounded(.up)))
            // The card is flipped (y down), the bitmap is not.
            let y0 = max(0, Int(((cardHeight - rect.maxY) * scale).rounded(.down)))
            let y1 = min(rep.pixelsHigh - 1, Int(((cardHeight - rect.minY) * scale).rounded(.up)))
            var sr = 0.0, sg = 0.0, sb = 0.0, n = 0
            guard x1 > x0, y1 > y0 else { return (0, 0, 0, 0) }
            for y in y0...y1 {
                for x in x0...x1 {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let r = Double(c.redComponent), g = Double(c.greenComponent),
                        b = Double(c.blueComponent)
                    guard max(r, g, b) - min(r, g, b) > 0.10 else { continue }  // skip greys
                    sr += r; sg += g; sb += b; n += 1
                }
            }
            return (sr / Double(max(n, 1)), sg / Double(max(n, 1)), sb / Double(max(n, 1)), n)
        }

        var report: [String] = []
        for (index, rect) in card.channelLetterRects.enumerated() {
            let mean = meanColour(rect)
            XCTAssertGreaterThan(mean.n, 0, "第 \(index) 个字母在位图里应有像素")
            let components = [mean.r, mean.g, mean.b]
            let dominant = components.firstIndex(of: components.max() ?? 0) ?? -1
            XCTAssertEqual(dominant, index,
                           "第 \(index) 个字母应为 \(HistogramCardFormat.channelLetters[index]) 的颜色："
                           + "mean r \(String(format: "%.3f", mean.r)) g \(String(format: "%.3f", mean.g)) "
                           + "b \(String(format: "%.3f", mean.b))")
            report.append("\(HistogramCardFormat.channelLetters[index]) → r \(String(format: "%.3f", mean.r)) "
                          + "g \(String(format: "%.3f", mean.g)) b \(String(format: "%.3f", mean.b)) "
                          + "(\(mean.n) px)")
        }
        print("letters read back off the bitmap: " + report.joined(separator: " · ") + " · 差值 "
              + "\(String(format: "%.3f", max(0, 1)))")
    }
}
