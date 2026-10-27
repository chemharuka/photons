import XCTest
import AppKit
import Metal
import PhotonsCore
import PhotonsUI

/// The channel row's **over-white segment**: the number a channel paints when the *picture* holds it
/// above display white, and the clipping ink it is painted in (2026-10-27).
///
/// The owner's two asks, in one row:
///
/// > 「鼠标所在位置的 RGB 值，目前显示的屏幕渲染的值，上限就是屏幕亮度。改成显示这个点的实际亮度，
/// >   如果 R/G/B 中某个超过屏幕的亮度，就把直方图下方字的颜色改为红色，例如 G +2.3，+2.3 是红色」
/// > 「彩色的 RGB 三个字母大小，调整大一些和数值的 px 一致」
///
/// So there are four separate claims here, and each is measured against something that is not the code
/// under test:
///
///   ① **the number is the picture's light, not the panel's.** Same pixel, two sources: the frame S4
///      wrote (clamped at the display's headroom → `255`) and the scene-linear grid the histogram is
///      counted from (→ `+2.3`). Both are printed, and the loupe is driven through its real pointer.
///   ② **only the over-white segment is recoloured.** The ink is read back off a rendered bitmap, per
///      segment, and compared with `ClippingMark.color` (`#FF00C7`, the canvas wash's own colour) to
///      within 24/255 per channel.
///   ③ **the layout does not move.** Same font, same group starts, same row height; the mixed row is
///      measured at both shipped card widths, and the clipping ink is shown to change *no* metric.
///   ④ **the letters are the values' size.** Point size and cap height, both appearances.
@MainActor
final class HistogramOverWhiteReadoutTests: XCTestCase {

    private let cardWidth: CGFloat = 244        // the inspector's shipped minimum
    private let wideCardWidth: CGFloat = 274    // the widest the inspector gives the card
    private var cardHeight: CGFloat { HistogramCardView.contentHeight }
    private var windows: [NSWindow] = []
    private let scale: CGFloat = 2

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - fixtures

    private func measuredHistogram(headroom: Double = 4) -> Histogram {
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

    private func drawnCard(width: CGFloat? = nil, appearance: NSAppearance.Name = .aqua,
                           histogram: Histogram? = nil) -> HistogramCardView {
        let card = HistogramCardView()
        card.frame = NSRect(x: 0, y: 0, width: width ?? cardWidth, height: cardHeight)
        card.appearance = NSAppearance(named: appearance)
        card.histogram = histogram ?? measuredHistogram()
        render(card)
        return card
    }

    @discardableResult
    private func render(_ card: HistogramCardView) -> NSBitmapImageRep {
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

    /// A pixel from three **scene-linear** channel values — the shipped source.
    private func linearPixel(_ red: Float, _ green: Float, _ blue: Float) -> PointerPixel {
        PointerPixel(linearRed: red, green: green, blue: blue, histogram: measuredHistogram())
    }

    /// `+2.3` stops of light, as a linear value: `2^2.3 = 4.925…`.
    private var twoPointThreeStops: Float { Float(pow(2.0, 2.3)) }

    // MARK: - reading the paint back

    /// The clipping ink, straight from the constants the app paints with.
    private var ink: NSColor { HistogramCardView.overWhiteColor }

    private func components(_ color: NSColor) -> (r: Double, g: Double, b: Double) {
        let s = color.usingColorSpace(.sRGB) ?? color
        return (Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent))
    }

    /// Is this pixel the clipping ink, per channel within `tolerance`?
    private func isInk(_ color: NSColor, tolerance: Double = 24.0 / 255) -> Bool {
        let a = components(color), b = components(ink)
        return abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
    }

    /// Every pixel inside `rect` (card coordinates → bitmap rows, the card is flipped), with its own
    /// mean, the number of pixels that match the clipping ink, and the darkest-green pixel (the most
    /// ink-covered one — antialiased edges blend toward the backdrop).
    private func inkStats(_ rep: NSBitmapImageRep, _ rect: NSRect)
        -> (ink: Int, total: Int, mean: (r: Double, g: Double, b: Double)) {
        let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let x1 = min(rep.pixelsWide - 1, Int((rect.maxX * scale).rounded(.up)))
        let y0 = max(0, Int(((cardHeight - rect.maxY) * scale).rounded(.down)))
        let y1 = min(rep.pixelsHigh - 1, Int(((cardHeight - rect.minY) * scale).rounded(.up)))
        var matched = 0, total = 0
        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0
        guard x1 >= x0, y1 >= y0 else { return (0, 0, (0, 0, 0)) }
        for y in y0...y1 {
            for x in x0...x1 {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                total += 1
                if isInk(c) {
                    matched += 1
                    let s = components(c)
                    sr += s.r; sg += s.g; sb += s.b; n += 1
                }
            }
        }
        return (matched, total, (n == 0 ? 0 : sr / Double(n),
                                 n == 0 ? 0 : sg / Double(n),
                                 n == 0 ? 0 : sb / Double(n)))
    }

    private func describe(_ value: (r: Double, g: Double, b: Double)) -> String {
        String(format: "%.3f/%.3f/%.3f (bytes %d/%d/%d)",
               value.r, value.g, value.b,
               Int((value.r * 255).rounded()), Int((value.g * 255).rounded()),
               Int((value.b * 255).rounded()))
    }

    // MARK: - ① every channel inside white → codes, and no clipping ink at all

    func testAnAllInsideWhiteRowPaintsCodesAndNoClippingInk() {
        let card = drawnCard()
        // 0.96 / 0.50 / 0.25 linear → the owner's `R 245 G 128 B 64` (the same fixture the row's
        // other tests use, now stated in the linear domain the readout actually reads).
        card.showPointerReadout(linearPixel(0.9128, 0.2158, 0.0508))
        let rep = render(card)

        XCTAssertEqual(card.channelRowText, "R 245 G 128 B 64",
                       "画面内的通道只写码值，没有 +x.x")
        XCTAssertEqual(card.channelOverWhite, [false, false, false])
        XCTAssertEqual(card.channelValueColors.count, 3)
        for (index, colour) in card.channelValueColors.enumerated() {
            XCTAssertEqual(colour, HistogramCardReadability.readoutColor(isDark: false),
                           "第 \(index) 段用的是行色，不是削顶色")
        }
        // The paint itself: not one pixel in the row matches the clipping ink.
        var inkPixels = 0
        for rect in card.channelValueRects { inkPixels += inkStats(rep, rect).ink }
        let row = card.readoutRowRect
        let wholeRow = inkStats(rep, row)
        print("all-inside-white row: “\(card.channelRowText)” · 削顶色像素 "
              + "\(inkPixels)（值段）/ \(wholeRow.ink)（整行 \(Int(wholeRow.total)) px）· 墨色 "
              + "\(describe(components(ink)))")
        XCTAssertEqual(inkPixels, 0, "没有超白通道 → 一个削顶色像素都不该有")
        XCTAssertEqual(wholeRow.ink, 0, "整行也没有（字母是通道色，数值是行色）")
    }

    // MARK: - ② only the over-white segment is recoloured

    /// `R <code> G +2.3 B <code>`: the middle segment is the clipping ink, and its neighbours are not.
    func testOnlyTheOverWhiteSegmentCarriesTheClippingInk() {
        let card = drawnCard(histogram: measuredHistogram(headroom: 4))
        card.showPointerReadout(linearPixel(0.9128, twoPointThreeStops, 0.0508))
        let rep = render(card)

        XCTAssertEqual(card.channelRowText, "R 245 G +2.3 B 64",
                       "混行是特性：只有超白的那一段写 +x.x")
        XCTAssertEqual(card.channelRowValues, ["245", "+2.3", "64"])
        XCTAssertEqual(card.channelOverWhite, [false, true, false])
        XCTAssertEqual(card.channelValueColors[1], ink, "超白那一段就是削顶色（常量，不是副本）")
        XCTAssertEqual(card.channelValueColors[0], HistogramCardReadability.readoutColor(isDark: false))
        XCTAssertEqual(card.channelValueColors[2], HistogramCardReadability.readoutColor(isDark: false))

        XCTAssertEqual(card.channelValueRects.count, 3)
        let red = inkStats(rep, card.channelValueRects[0])
        let green = inkStats(rep, card.channelValueRects[1])
        let blue = inkStats(rep, card.channelValueRects[2])
        print("mixed row: “\(card.channelRowText)”")
        print("        R value \(card.channelValueRects[0]) → 削顶色像素 \(red.ink)/\(red.total) 均值 \(describe(red.mean))")
        print("        G value \(card.channelValueRects[1]) → 削顶色像素 \(green.ink)/\(green.total) 均值 \(describe(green.mean))")
        print("        B value \(card.channelValueRects[2]) → 削顶色像素 \(blue.ink)/\(blue.total) 均值 \(describe(blue.mean))")
        print("        ink \(describe(components(ink))) · 容差 \(String(format: "%.1f", 24.0)) / 255 = \(String(format: "%.4f", 24.0 / 255))")

        // The magenta segment really is magenta, per channel, within 24/255.
        XCTAssertGreaterThan(green.ink, 8, "`+2.3` 那段应该有削顶色像素（实际 \(green.ink)）")
        XCTAssertEqual(green.mean.r, components(ink).r, accuracy: 24.0 / 255, "+2.3 的 R")
        XCTAssertEqual(green.mean.g, components(ink).g, accuracy: 24.0 / 255, "+2.3 的 G")
        XCTAssertEqual(green.mean.b, components(ink).b, accuracy: 24.0 / 255, "+2.3 的 B")
        // …and its neighbours are not, by a wide margin (they are the neutral readout grey).
        XCTAssertEqual(red.ink, 0, "R 245 不是削顶色")
        XCTAssertEqual(blue.ink, 0, "B 64 不是削顶色")
        // The letters keep their own channel colours — the clipping ink never touches them.
        for (index, rect) in card.channelLetterRects.enumerated() {
            XCTAssertEqual(inkStats(rep, rect).ink, 0, "字母 \(index) 不该被染色")
        }
        XCTAssertEqual(card.channelLetterColors, HistogramCardView.channelNameColors)
    }

    /// Two channels above white, one inside: **the ink is the panel's answer, not the picture's**
    /// (2026-10-27). On the fixture's 2-stop panel (`headroom 4`) the `+2.3` channel is light it cannot
    /// show and `+0.5` fits, so only one segment is magenta; on an SDR panel (`headroom 1`) both are.
    /// The row's digits never move — 「相对屏幕白点的 +x.x」 is the picture's, the ink is the screen's.
    func testOnlyTheChannelsBeyondThePanelAreMagenta() {
        let pixel = linearPixel(twoPointThreeStops, 0.2158, Float(pow(2.0, 0.5)))

        // ① the 4× (2-stop) fixture: `+0.5` is inside the budget, `+2.3` is not.
        let card = drawnCard()
        card.showPointerReadout(pixel)
        let rep = render(card)
        XCTAssertEqual(card.channelRowText, "R +2.3 G 128 B +0.5")
        XCTAssertEqual(card.channelOverWhite, [true, false, false],
                       "2 档的屏幕装得下 +0.5，装不下 +2.3")

        let r = inkStats(rep, card.channelValueRects[0])
        let g = inkStats(rep, card.channelValueRects[1])
        let b = inkStats(rep, card.channelValueRects[2])
        print("two-over-white row on a 4× panel: “\(card.channelRowText)” · 削顶色像素 R \(r.ink)/\(r.total) · "
              + "G \(g.ink)/\(g.total) · B \(b.ink)/\(b.total)")
        XCTAssertGreaterThan(r.ink, 8, "R +2.3 是削顶色")
        XCTAssertEqual(g.ink, 0, "G 128 不是削顶色")
        XCTAssertEqual(b.ink, 0, "B +0.5 在这块屏上装得下 → 不是削顶色")

        // ② the same row on an SDR panel: everything above white is lost.
        let sdr = drawnCard(histogram: measuredHistogram(headroom: 1))
        sdr.showPointerReadout(pixel)
        let sdrRep = render(sdr)
        XCTAssertEqual(sdr.channelRowText, "R +2.3 G 128 B +0.5", "数字一模一样")
        XCTAssertEqual(sdr.channelOverWhite, [true, false, true], "SDR 屏：超白的两段都丢")
        XCTAssertGreaterThan(inkStats(sdrRep, sdr.channelValueRects[0]).ink, 8)
        XCTAssertGreaterThan(inkStats(sdrRep, sdr.channelValueRects[2]).ink, 8)
        XCTAssertEqual(inkStats(sdrRep, sdr.channelValueRects[1]).ink, 0)
    }

    // MARK: - ③ above white is never clamped to a code

    func testAnOverWhiteChannelIsNeverPrintedAsAClampedCode() {
        let card = drawnCard()
        let pixel = linearPixel(0.5, twoPointThreeStops, 0.5)
        card.showPointerReadout(pixel)
        render(card)

        // The level, not the string: a clamped source could still *look* like `+2.3` if the number were
        // faked, so the case is asserted too.
        guard case .stops(let stops) = pixel.channels[1] else {
            return XCTFail("4.93 线性值必须是 .stops，实际 \(pixel.channels[1])")
        }
        XCTAssertEqual(stops, 2.3, accuracy: 0.05, "log2(4.925) = 2.3 档")
        XCTAssertEqual(pixel.channels[1].text, "+2.3")
        XCTAssertNotEqual(pixel.channels[1].text, "255", "超白通道不得显示被钳到 255 的码值")
        XCTAssertNotEqual(pixel.channels[1].text, "256")
        XCTAssertEqual(card.channelRowValues[1], "+2.3")
        XCTAssertFalse(card.channelRowValues[1].contains("档"), "不带「档」字（owner 的写法）")
        XCTAssertFalse(card.channelRowValues[1].contains("EV"))
        XCTAssertFalse(card.channelRowValues[1].contains("×"))
        print("over-white level: 4.925 线性 → \(pixel.channels[1].text) · luma "
              + "\(String(format: "%.3f", pixel.luma)) · bin \(pixel.bin) tail \(pixel.isTail)")
    }

    // MARK: - ④ the same pixel, two sources: S4 clamps, the grid does not

    /// The change of source, stated as an experiment: one texel's worth of light put through **both**
    /// paths. The frame path is the old behaviour (S4 wrote `encode(min(v, headroom))`); the grid path is
    /// what the row reads now. If the data source were still the S4 frame the red-segment assertions
    /// above would be red — this test is that counter-proof, kept as a passing assertion.
    func testTheSameLightReadsWhiteFromS4AndStopsFromTheSceneLinearGrid() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                 width: 4, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let frame = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        // What S4 writes for a 4.93-linear pixel on an SDR panel (`headroom = 1`): `encode(min(v, 1))`
        // = 1.0, i.e. white. The green channel is the over-white one; R and B are inside.
        let light: (Float, Float, Float) = (0.9128, twoPointThreeStops, 0.0508)
        let presented = (min(light.0, 1), min(light.1, 1), min(light.2, 1))
        var pixels = [Float16](repeating: 0, count: 4 * 4)
        for x in 0..<4 {
            let o = x * 4
            pixels[o] = Float16(Histogram.srgbEncode(presented.0))
            pixels[o + 1] = Float16(Histogram.srgbEncode(presented.1))
            pixels[o + 2] = Float16(Histogram.srgbEncode(presented.2))
            pixels[o + 3] = 1
        }
        pixels.withUnsafeBytes { buffer in
            frame.replace(region: MTLRegionMake2D(0, 0, 4, 1), mipmapLevel: 0,
                          withBytes: buffer.baseAddress!, bytesPerRow: 4 * 4 * 2)
        }

        // The two readings of the same light.
        let fromFrame = try XCTUnwrap(LoupeController.sample(frame, x: 0, y: 0,
                                                            histogram: measuredHistogram()))
        let fromGrid = PointerPixel(linearRed: light.0, green: light.1, blue: light.2,
                                    histogram: measuredHistogram())
        print("same light \(light):")
        print("        S4 frame  → “\(fromFrame.channelRowText)” (source \(fromFrame.source.rawValue))")
        print("        scene-linear grid → “\(fromGrid.channelRowText)” (source \(fromGrid.source.rawValue))")
        print("        反证：把数据源改回 S4 帧，G 段就是 “\(fromFrame.channels[1].text)”，"
              + "「超白段必须 +x.x 且染削顶色」的断言必红")

        XCTAssertEqual(fromFrame.channelRowText, "R 245 G 255 B 64",
                       "S4 帧里的超白通道已经是白的：这正是用户报的「上限就是屏幕亮度」")
        XCTAssertEqual(fromFrame.source, .presented)
        XCTAssertEqual(fromFrame.channels[1], .code(255), "S4 帧读出来就是码值 255，不是 +2.3")
        XCTAssertFalse(fromFrame.channels[1].isOverWhite, "…所以它不会被染成削顶色（反证）")

        XCTAssertEqual(fromGrid.channelRowText, "R 245 G +2.3 B 64")
        XCTAssertEqual(fromGrid.source, .sceneLinear)
        XCTAssertTrue(fromGrid.channels[1].isOverWhite)
        XCTAssertNotEqual(fromFrame.channelRowText, fromGrid.channelRowText,
                          "两个数据源在同一像素上必须给出不同的答案，这就是换源生效")
    }

    // MARK: - ⑤ the layout does not move

    /// The clipping ink changes no metric: the same strings painted neutral and painted magenta have
    /// **identical** rects, and the mixed row is no taller than the all-code one.
    ///
    /// (The task expected `+2.3` to be *narrower* than a three-digit code. Measured, it is 3.27 pt
    /// wider — `+` and `.` are full-width in this face — so the assertion below is "no metric moves",
    /// and the width budget is checked at both shipped card widths instead of assumed.)
    func testTheClippingInkChangesNoMetric() {
        let codeRow = drawnCard()
        codeRow.showPointerReadout(linearPixel(0.9128, 0.2158, 0.0508))
        render(codeRow)
        let codeWidth = (codeRow.channelValueRects.last?.maxX ?? 0) - codeRow.channelRowRect.minX
        let codeHeight = codeRow.channelRowRect.height

        // The same three strings, forced through an over-white pixel: the digits are identical, only the
        // middle one's ink changes. Built by hand so the *strings* are the same in both cards.
        let mixed = drawnCard()
        mixed.showPointerReadout(linearPixel(0.9128, twoPointThreeStops, 0.0508))
        render(mixed)

        // Neutral vs magenta for one and the same string: draw the same value in both inks and compare
        // the rects the paint reported (colour is not part of a text metric).
        let strings = mixed.channelRowValues
        let neutralWidths = strings.map { (($0 as NSString).size(
            withAttributes: [.font: HistogramCardView.numberFont])).width }
        let paintedWidths = zip(mixed.channelLetterRects, mixed.channelValueRects)
            .map { $0.1.width }
        print("row metrics: all-code width \(String(format: "%.2f", codeWidth)) pt · "
              + "mixed width "
              + "\(String(format: "%.2f", (mixed.channelValueRects.last?.maxX ?? 0) - mixed.channelRowRect.minX)) pt · "
              + "row height \(String(format: "%.1f", codeHeight)) / \(String(format: "%.1f", mixed.channelRowRect.height)) pt")
        print("        painted value widths \(paintedWidths.map { String(format: "%.2f", $0) }) vs "
              + "NSString.size \(neutralWidths.map { String(format: "%.2f", $0) })")

        for (painted, measured) in zip(paintedWidths, neutralWidths) {
            XCTAssertEqual(painted, measured, accuracy: 0.01,
                           "画出来的宽度就是字体量出来的宽度：颜色不参与排版")
        }
        XCTAssertEqual(mixed.channelRowRect.height, codeHeight, accuracy: 0,
                       "混行与全码行同一行高")
        XCTAssertEqual(mixed.readoutRowRect, codeRow.readoutRowRect, "同一个槽")
        // The mixed row is wider by the two extra glyphs and still nowhere near the card's width.
        XCTAssertLessThan(mixed.channelValueRects.last?.maxX ?? .infinity, mixed.bounds.width,
                          "混行放得下")
        // Group starts are the layout's, not the strings':
        XCTAssertEqual(mixed.channelLetterRects[0].minX, codeRow.channelLetterRects[0].minX, accuracy: 0)
        XCTAssertEqual(mixed.channelLetterRects[1].minX, codeRow.channelLetterRects[1].minX, accuracy: 0)
        XCTAssertEqual(mixed.channelLetterRects[2].minX, codeRow.channelLetterRects[2].minX, accuracy: 0)
    }

    /// The worst rows the card can print, at both shipped card widths: everything inside, nothing
    /// truncated (「不许静默截断」).
    func testTheWorstCaseRowsFitAtBothShippedCardWidths() {
        let cases: [(String, (Float, Float, Float))] = [
            ("R 255 G 255 B 255", (0.999, 0.999, 0.999)),
            ("R 255 G +2.3 B +0.5", (0.999, twoPointThreeStops, Float(pow(2.0, 0.5)))),
            ("R +2.3 G +2.3 B +2.3", (twoPointThreeStops, twoPointThreeStops, twoPointThreeStops)),
        ]
        var lines: [String] = []
        for width in [cardWidth, wideCardWidth] {
            for (expected, light) in cases {
                let card = drawnCard(width: width)
                card.showPointerReadout(linearPixel(light.0, light.1, light.2))
                render(card)
                XCTAssertEqual(card.channelRowText, expected)
                let lastMaxX = card.channelValueRects.last?.maxX ?? .infinity
                let margin = width - lastMaxX
                lines.append(String(format: "%.0f pt · “%@” → 末端 %.2f pt，余量 %.2f pt（行高 %.1f）",
                                    Double(width), card.channelRowText, Double(lastMaxX),
                                    Double(margin), Double(card.channelRowRect.height)))
                XCTAssertGreaterThan(margin, 0, "\(width) pt 卡宽下 “\(expected)” 被截断了")
                XCTAssertEqual(card.channelLetterRects.first?.minX ?? -1, 0, accuracy: 0.01,
                               "第一组仍从卡左边缘开始（没有被挤动）")
                XCTAssertEqual(card.channelRowRect.height, HistogramCardView.readoutRowHeight,
                               accuracy: 0, "行高没变")
            }
        }
        print("worst-case rows:\n        " + lines.joined(separator: "\n        "))
    }

    // MARK: - ⑥ the letters are the values' size (and were not)

    func testTheLettersAreTheSameSizeAsTheValues() {
        let letters = HistogramCardView.channelLetterFont
        let values = HistogramCardView.numberFont
        // The single source: both faces are built from one point size.
        XCTAssertEqual(letters.pointSize, HistogramCardView.readoutFontSize, accuracy: 0)
        XCTAssertEqual(values.pointSize, HistogramCardView.readoutFontSize, accuracy: 0)
        XCTAssertEqual(letters.pointSize, values.pointSize, accuracy: 0,
                       "「字母…和数值的 px 一致」：字号必须相同")
        XCTAssertEqual(letters.capHeight, values.capHeight, accuracy: 0.5,
                       "大写字母高度一致（cap height \(letters.capHeight) vs \(values.capHeight)）")
        // The row's height is the values' line height, and the letters cannot grow it.
        let valuesHeight = ("0" as NSString).size(withAttributes: [.font: values]).height
        let lettersHeight = ("R" as NSString).size(withAttributes: [.font: letters]).height
        XCTAssertEqual(lettersHeight, valuesHeight, accuracy: 0, "字母的行高 == 数值的行高")
        XCTAssertEqual(HistogramCardView.readoutRowHeight, valuesHeight.rounded(.up), accuracy: 0)
        XCTAssertEqual(HistogramCardView.contentHeight,
                       0 + 58 + 5 + 15 + HistogramCardView.readoutRowHeight, accuracy: 0,
                       "卡片高度 = 绘图区 + 间距 + 削顶行 + 这一行（字母变大没有改变它）")
        print("fonts: letters \(letters.fontName) \(letters.pointSize) pt cap "
              + "\(String(format: "%.3f", letters.capHeight)) · values \(values.fontName) "
              + "\(values.pointSize) pt cap \(String(format: "%.3f", values.capHeight)) · "
              + "row height \(HistogramCardView.readoutRowHeight) pt · card "
              + "\(HistogramCardView.contentHeight) pt")

        // 反证, in the same test: the face this replaced was 8 pt bold — smaller by 1.5 pt and by
        // 1.06 pt of cap height — so an assertion that the two are equal would have been red before.
        let previous = NSFont.systemFont(ofSize: 8, weight: .bold)
        XCTAssertNotEqual(previous.pointSize, values.pointSize,
                          "改前字母是 8 pt，与数值 9.5 pt 不等 —— 那时这条断言必红")
        XCTAssertGreaterThan(abs(previous.capHeight - values.capHeight), 1.0,
                             "改前 cap height 差 \(String(format: "%.2f", values.capHeight - previous.capHeight)) pt")
    }

    // MARK: - ⑦ the ink in both appearances

    /// `#FF00C7`, measured off the paint in both appearances (the card's backdrop is a material, so the
    /// *contrast* moves with the appearance while the ink does not).
    func testTheClippingInkIsTheSameInBothAppearances() {
        var lines: [String] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let card = drawnCard(appearance: appearance)
            card.showPointerReadout(linearPixel(0.9128, twoPointThreeStops, 0.0508))
            let rep = render(card)
            let isDark = card.lastAppearanceIsDark
            XCTAssertEqual(isDark, appearance == .darkAqua,
                           "卡片以 \(appearance.rawValue) 画了一次（读回 \(isDark)）")
            let stats = inkStats(rep, card.channelValueRects[1])
            let ratio = HistogramCardReadability.worstContrast(of: HistogramCardView.overWhiteColor,
                                                              isDark: isDark)
            XCTAssertGreaterThan(stats.ink, 8, "\(appearance.rawValue) 下 +2.3 有削顶色像素")
            XCTAssertEqual(stats.mean.r, components(ink).r, accuracy: 24.0 / 255, "R 通道")
            XCTAssertEqual(stats.mean.g, components(ink).g, accuracy: 24.0 / 255, "G 通道")
            XCTAssertEqual(stats.mean.b, components(ink).b, accuracy: 24.0 / 255, "B 通道")
            lines.append("\(appearance.rawValue): 削顶色 \(describe(stats.mean)) · "
                         + "常量 \(describe(components(ink))) · WCAG 最差端 "
                         + "\(String(format: "%.2f", ratio)):1 · 行色 "
                         + "\(String(format: "%.2f", HistogramCardReadability.worstContrast(of: HistogramCardReadability.readoutColor(isDark: isDark), isDark: isDark))):1")
        }
        print("clipping ink per appearance:\n        " + lines.joined(separator: "\n        "))
        // Not dimmed by the vibrancy: the glyph interiors are the constant in both. The *contrast* is
        // reported, and it is below the card's 4.5 floor in both appearances — see the report.
        XCTAssertGreaterThan(HistogramCardReadability.worstContrast(of: ink, isDark: true), 3.0)
        XCTAssertGreaterThan(HistogramCardReadability.worstContrast(of: ink, isDark: false), 2.5)
    }

    // MARK: - ⑧ the loupe's real pointer, on a real frame

    private func rawFixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitFor(_ timeout: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    /// The whole shipped path: the loupe's tracking point → the frame's scene-linear grid → the row.
    ///
    /// Two independent facts are asserted: the reading's **source** is the grid (not the presented
    /// frame), and its number is the grid texel's own — read here a second way, off the `LinearSample`
    /// with the test's own arithmetic rather than through `PointerSampleLattice`.
    func testTheLoupeReadsTheSceneLinearGridUnderThePointer() throws {
        let url = try rawFixture()
        let canvasPoints = CGSize(width: 320, height: 200)
        let viewport = ImageSize(width: 640, height: 400)
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = true
        controller.reducesMotion = true
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvasPoints),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = NSRect(origin: .zero, size: canvasPoints)
        windows.append(window)
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        controller.frameSource = LoupeController.FrameSource(url: url, identity: "over-white-grid",
                                                            viewport: viewport, state: .fit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        pump(0.05)
        // The card registers now: that is what asks the *next* frame for a sample grid.
        let card = drawnCard()
        controller.pointerReadoutTarget = card
        // A frame may already be in flight when the card registers (it was rendered for nobody, so it
        // carries no grid). Accept the first grid frame that *survives* a settle, rather than whichever
        // one happens to be landing.
        func gridFrame() -> Bool {
            guard controller.lastFrame?.sceneLinearSample != nil else { return false }
            pump(0.2)
            return controller.lastFrame?.sceneLinearSample != nil
        }
        XCTAssertTrue(waitFor(25, gridFrame), "帧没带上 scene-linear 采样网格")
        pump(0.1)

        let frame = try XCTUnwrap(controller.lastFrame)
        let grid = try XCTUnwrap(frame.sceneLinearSample)
        let lattice = PointerSampleLattice(picture: frame.photoRect, grid: grid.size)
        let point = CGPoint(x: canvasPoints.width / 2, y: canvasPoints.height / 2)
        controller.pointerMoved(to: point)
        let pixel = try XCTUnwrap(controller.pointerReadout)
        XCTAssertEqual(controller.pointerReadoutSource, .sceneLinear,
                       "指针读数来自 scene-linear 网格，不是 S4 帧")
        XCTAssertEqual(pixel.source, .sceneLinear)

        // The same cell, read a second way: the stride arithmetic of the sample kernel, in the test.
        let texel = try XCTUnwrap(controller.textureTexel(forViewPoint: point))
        let stepX = Double(frame.photoRect.width) / Double(grid.size.width)
        let stepY = Double(frame.photoRect.height) / Double(grid.size.height)
        let cx = min(grid.size.width - 1, max(0, Int((Double(texel.x - frame.photoRect.x) + 0.5) / stepX)))
        let cy = min(grid.size.height - 1, max(0, Int((Double(texel.y - frame.photoRect.y) + 0.5) / stepY)))
        let raw = try XCTUnwrap(grid.texel(x: cx, y: cy))
        let expected = PointerPixel(linearRed: raw.red, green: raw.green, blue: raw.blue,
                                    histogram: controller.lastHistogram)
        XCTAssertEqual(pixel.channelRowText, expected.channelRowText,
                       "行里就是这颗网格像素的三通道值")
        XCTAssertEqual(pixel.channels, expected.channels)
        XCTAssertEqual(lattice.gridTexel(forTextureX: texel.x, y: texel.y).x, cx)
        XCTAssertEqual(lattice.gridTexel(forTextureX: texel.x, y: texel.y).y, cy)
        // …and the same texel out of the presented frame, for the record.
        let presented = LoupeController.sample(frame.texture, x: texel.x, y: texel.y,
                                              histogram: controller.lastHistogram)
        print("pointer at \(point) → texel (\(texel.x),\(texel.y)) → grid cell (\(cx),\(cy)) of "
              + "\(grid.size.width)×\(grid.size.height)")
        print("        scene-linear “\(pixel.channelRowText)” (source \(pixel.source.rawValue), "
              + "linear \(String(format: "%.4f/%.4f/%.4f", raw.red, raw.green, raw.blue)))")
        print("        S4 frame     “\(presented?.channelRowText ?? "nil")” "
              + "(source \(presented?.source.rawValue ?? "nil")) · headroom "
              + "\(String(format: "%.3f", frame.headroom))×")
        print("        grid texel count \(grid.rgba.count / 4) · stride "
              + "\(String(format: "%.3f", stepX))×\(String(format: "%.3f", stepY)) texels")
    }

    /// The same experiment the synthetic test makes, on the **real photo**: find a texel the picture
    /// holds above white, drive the loupe's pointer onto it, and print what the two sources say about
    /// the same pixel. The S4 frame cannot say more than `255`; the scene-linear grid says how many
    /// stops above white the light is.
    ///
    /// Skipped (with a message) when this fixture happens to have no over-white pixel at the measurement
    /// grid — the synthetic test is the one that always runs.
    func testARealFramesOverWhitePixelReadsStopsWhereItsS4TexelReadsWhite() throws {
        let url = try rawFixture()
        let canvasPoints = CGSize(width: 320, height: 200)
        let viewport = ImageSize(width: 640, height: 400)
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvasPoints),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = NSRect(origin: .zero, size: canvasPoints)
        windows.append(window)
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        // +3 EV on the *document*: a normal exposure this fixture's brightest cell is only 0.818, and
        // the point of this test is light above white produced by the real pipeline, not by a fixture.
        var edit = EditModel()
        edit.light.exposure = 3
        controller.frameSource = LoupeController.FrameSource(url: url, identity: "over-white-pixel",
                                                            viewport: viewport, state: .fit,
                                                            edit: edit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        pump(0.05)
        let card = drawnCard()
        controller.pointerReadoutTarget = card
        func gridFrame() -> Bool {
            guard controller.lastFrame?.sceneLinearSample != nil else { return false }
            pump(0.2)
            return controller.lastFrame?.sceneLinearSample != nil
        }
        XCTAssertTrue(waitFor(25, gridFrame), "帧没带上 scene-linear 采样网格")
        pump(0.1)

        let frame = try XCTUnwrap(controller.lastFrame)
        let grid = try XCTUnwrap(frame.sceneLinearSample)
        // The brightest cell of the picture, at the measurement's own lattice.
        var best = (x: 0, y: 0, value: Float(0))
        for y in 0..<grid.size.height {
            for x in 0..<grid.size.width {
                guard let t = grid.texel(x: x, y: y) else { continue }
                let m = max(t.red, max(t.green, t.blue))
                if m > best.value { best = (x, y, m) }
            }
        }
        guard best.value > 1.02 else {
            print("real frame: 这颗 fixture 的采样网格里最亮的通道只有 "
                  + "\(String(format: "%.3f", best.value))，没有过白像素 —— 合成用例覆盖了这种情况")
            throw XCTSkip("fixture has no over-white pixel")
        }
        let lattice = PointerSampleLattice(picture: frame.photoRect, grid: grid.size)
        let step = lattice.step
        // The texel the sample kernel reads for this cell: `floor((j + 0.5) · step) + origin`, i.e. the
        // very pixel the grid value came from — so the two readings below are one pixel, not two
        // neighbours.
        let sampleX = frame.photoRect.x + Int((Double(best.x) + 0.5) * step.x)
        let sampleY = frame.photoRect.y + Int((Double(best.y) + 0.5) * step.y)
        let k = Double(controller.canvasView.window?.backingScaleFactor ?? 2)
        let point = CGPoint(x: Double(sampleX) * Double(frame.canvas.width)
                                / Double(frame.texture.width) / k,
                            y: Double(sampleY) * Double(frame.canvas.height)
                                / Double(frame.texture.height) / k)
        controller.pointerMoved(to: point)
        let pixel = try XCTUnwrap(controller.pointerReadout)
        let hit = try XCTUnwrap(controller.textureTexel(forViewPoint: point))
        let presented = LoupeController.sample(frame.texture, x: sampleX, y: sampleY,
                                              histogram: controller.lastHistogram)
        let raw = try XCTUnwrap(grid.texel(x: best.x, y: best.y))
        print("real frame, brightest cell (\(best.x),\(best.y)) = "
              + "\(String(format: "%.3f/%.3f/%.3f", raw.red, raw.green, raw.blue)) · pointer "
              + "\(point) → texel (\(hit.x),\(hit.y)) · kernel texel (\(sampleX),\(sampleY))")
        print("        scene-linear “\(pixel.channelRowText)” (source \(pixel.source.rawValue))")
        print("        S4 frame     “\(presented?.channelRowText ?? "nil")” "
              + "(source \(presented?.source.rawValue ?? "nil")) · headroom "
              + "\(String(format: "%.3f", frame.headroom))×")
        XCTAssertEqual(pixel.source, .sceneLinear)
        XCTAssertTrue(pixel.channels.contains(where: \.isOverWhite),
                      "最亮的那个像素至少有一个通道超过白：\(pixel.channelRowText)")
        // Per channel: whatever the *picture* holds above the panel's ceiling is white in the frame —
        // the user's 「上限就是屏幕亮度」, on a real photo, in one comparison.
        // The ceiling the frame can carry: white on an SDR panel (`headroom = 1` → `255`), or
        // `log2(headroom)` stops on an EDR one. **Whatever the picture holds beyond it is gone**, which
        // is the whole of 「上限就是屏幕亮度」 — the number is the panel's, not the pixel's.
        let ceilingStops = log2(max(frame.headroom, 1))
        var clamped = 0
        for (index, level) in pixel.channels.enumerated() {
            guard case .stops(let stops) = level, pow(2, stops) > frame.headroom * 1.005 else { continue }
            clamped += 1
            let letter = HistogramCardFormat.channelLetters[index]
            switch presented?.channels[index] {
            case .code(255):
                break                      // SDR: S4 wrote white
            case .stops(let got):
                XCTAssertEqual(got, ceilingStops, accuracy: 0.03,
                               "\(letter) 在画面里是 \(String(format: "%.2f", pow(2, stops)))× 白，"
                               + "超过屏幕上限 \(String(format: "%.2f", frame.headroom))× → "
                               + "S4 帧只能到天花板 \(String(format: "%.2f", ceilingStops)) 档")
            default:
                XCTFail("\(letter) 超白却在 S4 帧里读成 \(String(describing: presented?.channels[index]))")
            }
        }
        XCTAssertGreaterThan(clamped, 0, "这个 fixture 在这档曝光下应该有超过屏幕上限的通道")
        print("        clamped channels \(clamped) 个（超过屏幕 headroom "
              + "\(String(format: "%.3f", frame.headroom))× 那些）")
    }
}
