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
        // 023 deleted the brightness row (「不需要亮度信息了，只要 RGB 值」), so the row has **one** content
        // here: the pixel's three channels. The readout state is idle and nothing bare-numbered is painted
        // — that is the assertion that replaces the old `.image(value: reading.level.text)`.
        XCTAssertEqual(card.readoutState, .idle, "亮度行已删除：指针在画面上时读数态是 idle")
        XCTAssertTrue(card.readoutValueTexts.isEmpty, "没有任何「只有数字没有字母」的裸数字")
        XCTAssertTrue(card.readoutValueRects.isEmpty)
        XCTAssertTrue(card.readoutLetterRects.isEmpty)
        XCTAssertTrue(card.readoutContentRect.isEmpty, "读数那一半在指针位于画面上时一个字都不画")
        XCTAssertEqual(card.channelRowValues.count, 3, "画面上只画了这一组 R/G/B")
        print("mixed row: “\(card.channelRowText)” · 读数态 \(card.readoutState) · luma "
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

        // The pointer on the histogram: not a pixel → the pixel half stays blank, and the *same row*
        // answers with the bin's counts (023: one row, two contents).
        card.showPointerReadout(pixel(0.96, 0.50, 0.25))
        if let axis = card.lastAxis {
            card.updateHoverReadout(at: CGPoint(x: axis.x(sdrBin: 128, of: 256), y: axis.plot.midY))
        }
        render(card)
        XCTAssertEqual(card.channelRowText, "", "鼠标在直方图上 → 像素那半空白")
        XCTAssertTrue(card.channelLetterRects.isEmpty)
        XCTAssertEqual(card.channelRowRect, blankSlot)
        XCTAssertFalse(card.hoverCountText.isEmpty, "计数由同一行的另一半回答")
        XCTAssertEqual(card.hoverCountText, "R 1284 G 1291 B 1206")
        XCTAssertEqual(card.readoutRowRect, blankSlot, "两半共用一个槽：槽从不因为内容而变")
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
        // One space **in the face the values are painted in**. 023 moved that face from
        // `percentFont` (8.5 pt regular) to `numberFont` (9.5 pt semibold) to match the counts
        // indicator, so the expected gap is measured in `numberFont` — the assertion itself is unchanged.
        let spaceWidth = (" " as NSString)
            .size(withAttributes: [.font: HistogramCardView.numberFont]).width
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

    /// 023's whole point: 「样式和鼠标悬停在直方图上的 RGB 像素个数指示保持一致」.
    ///
    /// The fixture makes the two states print the **same three strings** (a pixel of 245 / 128 / 64 and a
    /// bin whose counts are 245 / 128 / 64), so "the same style" is not a claim about text but about the
    /// paint: the face, the colour, the rects and the pixels are compared between the two states, and to
    /// `numberFont` / `readoutColor(isDark:)` — never to a copy of the literals.
    func testThePixelRowPaintsInTheCountsIndicatorsFaceColourAndGeometry() {
        func measured(counts: (Int, Int, Int)) -> Histogram {
            func channel(_ value: Int) -> HistogramChannel {
                HistogramChannel(bins: (0..<256).map { $0 == 128 ? value : 0 },
                                 hdrBins: (0..<Histogram.hdrBinCount).map { _ in 0 },
                                 clippedHigh: 0, clippedCeiling: 0, clippedLow: 0)
            }
            return Histogram(binCount: 256, sampleCount: 861,
                             canvas: ImageSize(width: 720, height: 420),
                             roi: ImageRect(x: 0, y: 0, width: 720, height: 420),
                             sampleSize: ImageSize(width: 720, height: 420),
                             primaries: .sRGB, headroom: 1,
                             red: channel(counts.0), green: channel(counts.1), blue: channel(counts.2),
                             luma: channel(counts.0))
        }
        let card = drawnCard(histogram: measured(counts: (245, 128, 64)))
        card.appearance = NSAppearance(named: .aqua)

        /// Mean colour of the opaque (non-backdrop) pixels inside `rect`, off a rendered bitmap.
        func glyphColour(_ rep: NSBitmapImageRep, _ rect: NSRect) -> (r: Double, g: Double, b: Double, n: Int) {
            let scale: CGFloat = 2
            let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
            let x1 = min(rep.pixelsWide - 1, Int((rect.maxX * scale).rounded(.up)))
            let y0 = max(0, Int(((cardHeight - rect.maxY) * scale).rounded(.down)))
            let y1 = min(rep.pixelsHigh - 1, Int(((cardHeight - rect.minY) * scale).rounded(.up)))
            var sr = 0.0, sg = 0.0, sb = 0.0, n = 0
            guard x1 > x0, y1 > y0 else { return (0, 0, 0, 0) }
            for y in y0...y1 {
                for x in x0...x1 {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    // The card's backdrop is a light neutral; the digits are the dark readout grey.
                    guard Double(c.redComponent) < 0.6 else { continue }
                    sr += Double(c.redComponent); sg += Double(c.greenComponent)
                    sb += Double(c.blueComponent); n += 1
                }
            }
            return (sr / Double(max(n, 1)), sg / Double(max(n, 1)), sb / Double(max(n, 1)), n)
        }

        // ① pointer on the picture → the pixel's channels.
        card.showPointerReadout(pixel(0.96, 0.502, 0.25))
        let pictureRep = render(card)
        XCTAssertEqual(card.channelRowText, "R 245 G 128 B 64", "像素行是这颗像素的三通道值")
        XCTAssertEqual(card.channelRowValues, ["245", "128", "64"])
        let pictureRects = card.channelValueRects
        let pictureFont = card.channelValueFont
        let pictureColour = card.channelValueColor
        guard pictureRects.count == 3 else { return XCTFail("像素行应画三组值，实际 \(pictureRects.count)") }
        let pictureGlyph = glyphColour(pictureRep, pictureRects[0])

        // ② pointer on the plot, same three strings as counts.
        guard let axis = card.lastAxis else { return XCTFail("卡片没画出坐标轴") }
        card.updateHoverReadout(at: CGPoint(x: axis.x(sdrBin: 128, of: 256), y: axis.plot.midY))
        let countsRep = render(card)
        XCTAssertEqual(card.hoverCountText, "R 245 G 128 B 64", "同一串数字，来自这一箱的计数")
        XCTAssertEqual(card.readoutValueTexts, ["245", "128", "64"])
        let countsRects = card.readoutValueRects
        let countsFont = card.readoutValueFont
        let countsColour = card.readoutValueColor
        guard countsRects.count == 3 else { return XCTFail("计数行应画三组值，实际 \(countsRects.count)") }
        let countsGlyph = glyphColour(countsRep, countsRects[0])

        // ③ the equality — font, colour, and the painted rects (which also pins the face: a wider face
        // would move the value's maxX, and a different face would change the glyph widths).
        XCTAssertEqual(pictureFont, countsFont, "两态的数值字体相同（同一个 NSFont）")
        XCTAssertEqual(pictureFont, HistogramCardView.numberFont,
                       "就是 readoutColor 那一套：numberFont 9.5 semibold")
        XCTAssertEqual(pictureColour, countsColour, "两态的数值颜色相同")
        XCTAssertEqual(pictureColour, HistogramCardReadability.readoutColor(isDark: false))
        XCTAssertEqual(pictureRects, countsRects, "同样的字符串、同一个槽 → 逐点相同的矩形")
        XCTAssertEqual(card.channelRowRect, card.readoutRowRect, "…因为它们就是同一行")
        XCTAssertEqual(pictureGlyph.n, countsGlyph.n, "同一串数字 → 同样多的字形像素")
        XCTAssertEqual(pictureGlyph.r, countsGlyph.r, accuracy: 0.02, "字形像素颜色相同（R）")
        XCTAssertEqual(pictureGlyph.g, countsGlyph.g, accuracy: 0.02, "字形像素颜色相同（G）")
        XCTAssertEqual(pictureGlyph.b, countsGlyph.b, accuracy: 0.02, "字形像素颜色相同（B）")
        XCTAssertGreaterThan(pictureGlyph.n, 0, "位图里真的画了字")
        print("023 style identity: 字体 \(pictureFont.fontName) \(String(format: "%.1f", pictureFont.pointSize))pt · "
              + "颜色 \(pictureColour) == \(countsColour) · rects 相同 \(pictureRects == countsRects) · "
              + "字形像素 \(pictureGlyph.n)/\(countsGlyph.n) 均值 "
              + "\(String(format: "%.3f/%.3f/%.3f", pictureGlyph.r, pictureGlyph.g, pictureGlyph.b))")
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

    /// **One row, one slot** (023). The pixel's channels and the bin's counts are the same row, so they
    /// share one rect — `accuracy: 0`, in both states and when idle — and the card never has a second.
    /// (That is what replaced 「通道行与脚注行相接不重叠」: there is nothing left to overlap.)
    func testTheRowIsOneSlotForBothContents() {
        let card = drawnCard(histogram: measuredHistogram())
        let blankChannel = card.channelRowRect
        let blankReadout = card.readoutRowRect
        XCTAssertEqual(blankChannel, blankReadout, "一个槽：像素行与计数行是同一行")
        XCTAssertEqual(blankChannel.height, HistogramCardView.readoutRowHeight, accuracy: 0)

        // Pointer on the picture: the pixel half paints, the counts half is empty, the slot is unchanged.
        card.showPointerReadout(pixel(0.96, 0.50, 0.25))
        render(card)
        XCTAssertEqual(card.channelRowRect, blankChannel)
        XCTAssertEqual(card.readoutRowRect, blankReadout)
        XCTAssertEqual(card.channelValueRects.count, 3, "像素那半画了三组值")
        XCTAssertTrue(card.readoutValueTexts.isEmpty, "计数那半没画")
        XCTAssertGreaterThan(card.channelLetterRects.first?.minY ?? -CGFloat.infinity,
                             card.lastAxis?.plot.maxY ?? CGFloat.infinity,
                             "这一行在绘图区下方")

        // Pointer on the plot: the counts half paints, the pixel half is empty, the same slot.
        if let axis = card.lastAxis {
            card.updateHoverReadout(at: CGPoint(x: axis.x(sdrBin: 128, of: 256), y: axis.plot.midY))
        }
        render(card)
        XCTAssertEqual(card.channelRowRect, blankChannel, "换内容不移动这一行")
        XCTAssertEqual(card.readoutRowRect, blankReadout)
        XCTAssertEqual(card.readoutValueTexts.count, 3, "计数那半画了三组值")
        XCTAssertTrue(card.channelRowValues.isEmpty, "像素那半没画")
        XCTAssertLessThanOrEqual(card.readoutRowRect.maxY, cardHeight + 0.01, "都在卡片内")
        print("row: 槽 \(card.channelRowRect)（== \(card.readoutRowRect)）· 行高 \(String(format: "%.1f", HistogramCardView.readoutRowHeight)) · 卡片 \(cardHeight)")
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
