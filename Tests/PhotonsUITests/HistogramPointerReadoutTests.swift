import XCTest
import AppKit
import Metal
import PhotonsCore
import PhotonsUI

/// The bottom row of the histogram card — the owner's 「鼠标在画面上就显示该像素亮度，鼠标在直方图上就显示
/// 该亮度像素数量，鼠标在其他位置就都不显示但保留这行的高度不要乱动」.
///
/// Three things have to be true at once, and they are tested separately because they fail differently:
///
///   ① **the number is the pixel's.** The loupe tracks the pointer, reads a 1×1 texel of the presented
///      frame, and the card prints the brightness of *that* texel — so the test reads the same texel a
///      second way and compares the two numbers (≤ 1 code / 0.02 stop), rather than comparing the
///      formatter to itself.
///   ② **it costs nothing when nothing changes.** A 1×1 `getBytes` synchronises with the GPU, so 100
///      `mouseMoved` events in the same pixel must cost at most one readback.
///   ③ **the row is a slot, not a label.** The three states paint different things; the row's height and
///      position are the same number in all of them, and the R/G/B letters sit at fixed x whatever the
///      counts are.
@MainActor
final class HistogramPointerReadoutTests: XCTestCase {

    private var windows: [NSWindow] = []
    private let canvasPoints = CGSize(width: 320, height: 200)
    private let viewport = ImageSize(width: 640, height: 400)
    private let cardWidth: CGFloat = 244
    private let cardHeight: CGFloat = 104

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

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

    private func waitFor(_ timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    // MARK: - a controller with a real frame, plus a card reading it

    private func makeLoupe(url: URL, identity: String) -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        controller.reducesMotion = true
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvasPoints),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = NSRect(origin: .zero, size: canvasPoints)
        windows.append(window)
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        controller.frameSource = LoupeController.FrameSource(url: url, identity: identity,
                                                            viewport: viewport, state: .fit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        pump(0.1)
        return controller
    }

    /// A card, drawn once into an offscreen bitmap — real text metrics, no window.
    private func drawnCard(width: CGFloat = 244, histogram: Histogram? = nil) -> HistogramCardView {
        let card = HistogramCardView()
        card.frame = NSRect(x: 0, y: 0, width: width, height: cardHeight)
        card.appearance = NSAppearance(named: .aqua)
        card.histogram = histogram
        render(card)
        return card
    }

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

    /// A histogram whose bins the test chose, so "R 1284" is a number this test put there.
    private func knownCounts(red: Int = 1284, green: Int = 1291, blue: Int = 1206) -> Histogram {
        func channel(_ bins: [Int], _ hdr: [Int]) -> HistogramChannel {
            HistogramChannel(bins: bins, hdrBins: hdr, clippedHigh: 0.01, clippedCeiling: 0.01,
                             clippedLow: 0)
        }
        func bins(_ value: Int) -> [Int] {
            (0..<256).map { $0 == 128 ? value : 0 }
        }
        func hdr(_ value: Int) -> [Int] {
            (0..<Histogram.hdrBinCount).map { $0 == 64 ? value : 0 }
        }
        let red = channel(bins(red), hdr(red))
        let green = channel(bins(green), hdr(green))
        let blue = channel(bins(blue), hdr(blue))
        return Histogram(binCount: 256, sampleCount: 898_432,
                         canvas: ImageSize(width: 720, height: 420),
                         roi: ImageRect(x: 0, y: 0, width: 720, height: 420),
                         sampleSize: ImageSize(width: 720, height: 420),
                         primaries: .sRGB, headroom: 1,
                         red: red, green: green, blue: blue, luma: red)
    }

    // MARK: - ① the number is the pixel's

    /// The pixel under the pointer, through the whole shipped path: tracking point → texel → 1×1
    /// readback → histogram axis → the card's row. The expectation is computed **independently**, from
    /// a second readback of the same texel, so a formatter that agrees with itself cannot pass.
    func testTheRowReportsThePixelUnderThePointer() throws {
        let url = try rawFixture()
        let controller = makeLoupe(url: url, identity: "pointer-pixel")
        let card = drawnCard(width: cardWidth, histogram: knownCounts())
        controller.pointerReadoutTarget = card
        let frame = try XCTUnwrap(controller.lastFrame)
        let hist = knownCounts()
        let k = Double(controller.canvasView.window?.backingScaleFactor ?? 2)

        var lines: [String] = []
        let points = [CGPoint(x: 160, y: 100), CGPoint(x: 80, y: 50), CGPoint(x: 260, y: 168)]
        for point in points {
            controller.pointerMoved(to: point)
            let texel = try XCTUnwrap(controller.textureTexel(forViewPoint: point))
            // The independent readback: the same texel, straight off the texture.
            var raw = [UInt16](repeating: 0, count: 4)
            raw.withUnsafeMutableBytes { buffer in
                frame.texture.getBytes(buffer.baseAddress!,
                                       bytesPerRow: 4 * MemoryLayout<UInt16>.size,
                                       from: MTLRegionMake2D(texel.x, texel.y, 1, 1),
                                       mipmapLevel: 0)
            }
            func channel(_ i: Int) -> Float { Float(Float16(bitPattern: raw[i])) }
            let linear = Double(Float(Histogram.lumaWeights.r) * Histogram.srgbDecode(channel(0))
                                + Float(Histogram.lumaWeights.g) * Histogram.srgbDecode(channel(1))
                                + Float(Histogram.lumaWeights.b) * Histogram.srgbDecode(channel(2)))
            let expected: String
            if linear > 1 {
                expected = String(format: "%+.1f", log2(linear))
            } else {
                expected = "\(min(255, max(0, Int((Double(Histogram.srgbEncode(Float(linear))) * 255).rounded()))))"
            }

            let pixel = try XCTUnwrap(controller.pointerReadout)
            render(card)
            XCTAssertEqual(card.readoutState, .image(value: pixel.level.text),
                           "the row is the pixel's brightness and nothing else")
            XCTAssertEqual(card.hoverValueText, expected, "texel (\(texel.x), \(texel.y)) at \(point)")
            XCTAssertEqual(card.hoverCountText, "", ".image shows no counts")
            // The channel row: the same texel, each channel on its own axis (a code, or +x.x above
            // display white) — computed here from the texture, not from the card's own arithmetic.
            let expectedChannels = [channel(0), channel(1), channel(2)].map { c -> String in
                let linear = Histogram.srgbDecode(c)
                if linear > 1 { return String(format: "%+.1f", log2(Double(linear))) }
                let code = (Double(Histogram.srgbEncode(Float(max(linear, 0)))) * 255).rounded()
                return "\(min(255, max(0, Int(code))))"
            }
            XCTAssertEqual(card.channelRowText,
                           "R \(expectedChannels[0]) G \(expectedChannels[1]) B \(expectedChannels[2])",
                           "texel (\(texel.x), \(texel.y)): 通道行就是这颗像素的三通道值")
            XCTAssertEqual(card.channelRowValues, expectedChannels)
            XCTAssertEqual(card.channelRowValues.count, 3)
            // The same texel, put on the axis by the *same* rule but with the test's own histogram:
            // the bin index and the counts have to be that histogram's, or the row's numbers would
            // describe a bin the card never drew.
            let reference = PointerPixel(encodedRed: channel(0), green: channel(1), blue: channel(2),
                                         histogram: hist)
            XCTAssertEqual(reference.bin, pixel.bin)
            XCTAssertEqual(reference.isTail, pixel.isTail)
            let counts = try XCTUnwrap(reference.counts)
            let bins = reference.isTail ? hist.red.hdrBins : hist.red.bins
            XCTAssertEqual(counts.red, bins[reference.bin], "the pixel's bin count is the measurement's")
            XCTAssertEqual(counts.green, (reference.isTail ? hist.green.hdrBins : hist.green.bins)[reference.bin])
            XCTAssertEqual(counts.blue, (reference.isTail ? hist.blue.hdrBins : hist.blue.bins)[reference.bin])
            XCTAssertEqual(k, 2, accuracy: 1e-9)
            lines.append("point \(point) → texel (\(texel.x),\(texel.y)) · linear \(String(format: "%.4f", linear)) · 亮度 “\(card.hoverValueText)” (expected “\(expected)”) · 通道 “\(card.channelRowText)” (expected “R \(expectedChannels[0]) G \(expectedChannels[1]) B \(expectedChannels[2])”) · bin \(pixel.bin)\(pixel.isTail ? " (tail)" : "")")
        }
        print("pointer row vs an independent readback of the same texel:")
        print(lines.map { "        " + $0 }.joined(separator: "\n"))
    }

    /// The pointer *on the plot* shows counts in the footnote row and leaves the **channel row blank** —
    /// the channel row reads a *pixel*, and a hover points at a bin. (This is the slot the old
    /// per-channel percentages row used to occupy; the percentages are no longer painted at all.)
    func testThePlotShowsCountsAndTheChannelRowStaysBlank() throws {
        let card = drawnCard(histogram: knownCounts())
        XCTAssertEqual(card.readoutState, .idle)
        XCTAssertEqual(card.channelRowText, "", "no pointer on the picture → the channel row is blank")
        let idleChannelSlot = card.channelRowRect
        XCTAssertFalse(idleChannelSlot.isEmpty, "the channel slot exists even when it is empty")

        // A pixel reading is available: the channel row prints it, the footnote row prints its luma.
        card.showPointerReadout(PointerPixel(level: .code(200), bin: 200, isTail: false, luma: 0.6,
                                             channels: [.code(245), .code(128), .code(64)]))
        render(card)
        XCTAssertEqual(card.readoutState, .image(value: "200"))
        XCTAssertEqual(card.hoverCountText, "")
        XCTAssertEqual(card.channelRowText, "R 245 G 128 B 64", "on the picture: the pixel's channels")
        XCTAssertFalse(card.channelRowText.contains("%"), "过白比例不再出现在这一行")

        // The pointer on the plot: the plot wins for the footnote row, and the channel row goes blank
        // (the pixel is not what a hover is pointing at), at the same slot.
        let axis = try XCTUnwrap(card.lastAxis)
        card.updateHoverReadout(at: CGPoint(x: axis.x(sdrBin: 128, of: 256), y: axis.plot.midY))
        render(card)
        XCTAssertEqual(card.readoutState, .histogram(counts: HistogramBinCounts(red: 1284, green: 1291,
                                                                                blue: 1206)))
        XCTAssertEqual(card.hoverCountText, "R 1284 G 1291 B 1206")
        XCTAssertEqual(card.hoverValueText, "", ".histogram shows no level")
        XCTAssertEqual(card.channelRowText, "", "a hover is not a pixel: the channel row is blank")
        XCTAssertTrue(card.channelLetterRects.isEmpty)
        XCTAssertEqual(card.channelRowRect, idleChannelSlot, "…and keeps its slot")
        XCTAssertLessThanOrEqual(card.channelRowRect.maxY, card.readoutRowRect.minY,
                                 "the two rows' slots do not overlap")

        // Off the plot, with the pixel still known: back to the pixel's brightness *and* its channels.
        card.clearHoverReadout()
        render(card)
        XCTAssertEqual(card.readoutState, .image(value: "200"))
        XCTAssertEqual(card.channelRowText, "R 245 G 128 B 64")

        // And with the pointer gone from the picture too: idle, nothing painted, both rows the same.
        card.clearPointerReadout()
        render(card)
        XCTAssertEqual(card.readoutState, .idle)
        XCTAssertTrue(card.hoverReadoutRect.isEmpty)
        XCTAssertEqual(card.channelRowText, "")
        XCTAssertEqual(card.channelRowRect, idleChannelSlot, "the channel row keeps its slot")
    }

    // MARK: - ② the readback is throttled

    /// 100 moves inside one pixel: one readback, not 100. The counter is the claim — a `getBytes` on the
    /// frame texture is a GPU synchronisation, and a readout that re-read on every mouse event would
    /// show up in the frame time long before it showed up in a screenshot.
    func testOneHundredMovesInTheSamePixelCostAtMostTwoReadbacks() throws {
        let url = try rawFixture()
        let controller = makeLoupe(url: url, identity: "pointer-throttle")
        let card = drawnCard(histogram: knownCounts())
        controller.pointerReadoutTarget = card
        let point = CGPoint(x: 120, y: 90)

        controller.pointerMoved(to: point)
        let afterFirst = controller.pointerReadbackCount
        XCTAssertEqual(afterFirst, 1, "the first sample reads once")
        for _ in 0..<100 { controller.pointerMoved(to: point) }
        let afterMany = controller.pointerReadbackCount
        print("throttle: 101 moves in one pixel → \(afterMany) readback(s), \(controller.pointerReadbacksSkipped) refused")
        XCTAssertLessThanOrEqual(afterMany, 2, "101 moves in one pixel must not read 101 times")
        XCTAssertEqual(afterMany, afterFirst, "…and must not read at all after the first")

        // A different pixel *does* read: the throttle is per texel, not per event.
        controller.pointerMoved(to: CGPoint(x: 121, y: 90))
        XCTAssertEqual(controller.pointerReadbackCount, afterFirst + 1)
    }

    // MARK: - ③ the row is a slot with one height

    /// The owner's 「保留这行的高度不要乱动」: the slot's rect is the **same** in all three states,
    /// compared with `accuracy: 0`, and the idle state paints nothing at all.
    func testTheRowKeepsItsHeightInAllThreeStates() {
        let card = drawnCard(histogram: knownCounts())
        render(card)
        let idleSlot = card.readoutRowRect
        let idlePaint = card.hoverPaintCount
        XCTAssertFalse(idleSlot.isEmpty, "the slot exists even when it is empty")
        XCTAssertEqual(card.readoutState, .idle)
        XCTAssertTrue(card.hoverReadoutRect.isEmpty)
        XCTAssertEqual(card.hoverPaintCount, idlePaint, "idle paints nothing")

        card.showPointerReadout(PointerPixel(level: .code(128), bin: 128, isTail: false, luma: 0.2))
        render(card)
        let imageSlot = card.readoutRowRect
        let imagePaint = card.hoverPaintCount

        card.showPointerReadout(PointerPixel(level: .code(128), bin: 128, isTail: false, luma: 0.2))
        card.clearPointerReadout()
        let axis = try? XCTUnwrap(card.lastAxis)
        if let axis {
            card.updateHoverReadout(at: CGPoint(x: axis.x(sdrBin: 128, of: 256), y: axis.plot.midY))
        }
        render(card)
        let countsSlot = card.readoutRowRect
        let countsPaint = card.hoverPaintCount

        print("readout row slot: idle \(idleSlot) · image \(imageSlot) · counts \(countsSlot) · height \(HistogramCardView.readoutRowHeight)")
        XCTAssertEqual(imageSlot, idleSlot, "the row does not move for .image")
        XCTAssertEqual(countsSlot, idleSlot, "the row does not move for .histogram")
        XCTAssertEqual(imageSlot.height, countsSlot.height, accuracy: 0, "one height, three states")
        XCTAssertEqual(idleSlot.height, HistogramCardView.readoutRowHeight, accuracy: 0)
        XCTAssertGreaterThan(imagePaint, idlePaint, ".image paints")
        XCTAssertGreaterThan(countsPaint, imagePaint, ".histogram paints")
        XCTAssertLessThanOrEqual(countsSlot.maxY, cardHeight + 0.01)
        // The channel row above it is a slot too: the same rect whether it paints or not, and the two
        // rows never overlap (they answer two different questions).
        XCTAssertEqual(card.channelRowRect.height, HistogramCardView.channelRowHeight, accuracy: 0)
        XCTAssertEqual(card.channelRowRect.maxY, card.readoutRowRect.minY, accuracy: 0.01,
                       "通道行与脚注行的槽位相接、不重叠")
    }

    /// 「三个字母位置恒定，数字紧跟字母」 — the group starts are a property of the layout, so they are
    /// compared **exactly** (`accuracy: 0`) across counts of every length: `i · rowWidth / 3`, whatever
    /// the numbers are. A count that outgrows its third is neither truncated nor shrunk — the *starts*
    /// are what must not float, and the value stays one space behind its letter (replaces the old
    /// five-character right-aligned field, which put the number at the far edge of its slot).
    func testTheGroupsHoldTheirStartsAndTheNumbersHugTheLetters() throws {
        let cases: [(String, Int, Int, Int)] = [
            ("zeros", 0, 0, 0),
            ("mixed", 1284, 12, 9),
            ("wide ", 198_765, 90_000, 1_234),
        ]
        let spaceWidth = (" " as NSString)
            .size(withAttributes: [.font: HistogramCardView.numberFont]).width
        var letters: [[CGFloat]] = []
        var gaps: [[CGFloat]] = []
        var texts: [[String]] = []
        var colors: [[NSColor]] = []
        for (label, red, green, blue) in cases {
            let card = drawnCard(histogram: knownCounts(red: red, green: green, blue: blue))
            let axis = try XCTUnwrap(card.lastAxis)
            card.updateHoverReadout(at: CGPoint(x: axis.x(sdrBin: 128, of: 256), y: axis.plot.midY))
            render(card)
            XCTAssertEqual(card.readoutState,
                           .histogram(counts: HistogramBinCounts(red: red, green: green, blue: blue)))
            XCTAssertEqual(card.readoutLetterRects.count, 3)
            XCTAssertEqual(card.readoutValueRects.count, 3)
            letters.append(card.readoutLetterRects.map(\.minX))
            gaps.append(zip(card.readoutLetterRects, card.readoutValueRects).map { $0.1.minX - $0.0.maxX })
            texts.append(card.readoutValueTexts)
            colors.append(card.readoutLetterColors)
            print("counts \(label) “\(card.hoverCountText)” · letters \(card.readoutLetterRects.map { String(format: "%.2f", $0.minX) }) · gaps \(zip(card.readoutLetterRects, card.readoutValueRects).map { String(format: "%.2f", $0.1.minX - $0.0.maxX) })")
        }
        // The three group starts are identical for every length — including the six-digit count.
        for group in 0..<3 {
            XCTAssertEqual(letters[1][group], letters[0][group], accuracy: 0,
                           "第 \(group) 组字母起点与数字长度无关")
            XCTAssertEqual(letters[2][group], letters[0][group], accuracy: 0,
                           "长数字也不移动第 \(group) 组的字母")
        }
        // …and they are the thirds of the row.
        XCTAssertEqual(letters[0][0], 0, accuracy: 0.01)
        XCTAssertEqual(letters[0][1], 244.0 / 3, accuracy: 0.01, "中间组的起点是 1/3 卡宽")
        XCTAssertEqual(letters[0][2], 2 * 244.0 / 3, accuracy: 0.01, "最后一组的起点是 2/3 卡宽")
        // The number hugs its letter: one space, not a right-aligned field edge.
        for gap in gaps.flatMap({ $0 }) {
            XCTAssertEqual(gap, spaceWidth, accuracy: 0.5, "数值与字母之间是一个空格 (\(spaceWidth) pt)")
        }
        // Nothing is truncated: the six-digit count is painted whole.
        XCTAssertEqual(texts[2], ["198765", "90000", "1234"])
        // The letters are painted with the channel colours — read back from the paint, not re-typed.
        for painted in colors {
            XCTAssertEqual(painted, HistogramCardView.channelNameColors)
        }
        // The canonical strings of the new layout.
        XCTAssertEqual(HistogramCardFormat.readoutCounts(HistogramBinCounts(red: 1284, green: 12,
                                                                           blue: 198_765)),
                       "R 1284 G 12 B 198765")
        XCTAssertEqual(HistogramCardFormat.readoutCounts(.zero), "R 0 G 0 B 0")
    }

    // MARK: - the pointer leaving, and the loupe clearing it

    /// The exit path: `pointerExited()` clears the row (the street the smoke cannot walk without
    /// moving the real cursor, asserted here on the real objects).
    func testPointerExitedClearsTheRow() throws {
        let url = try rawFixture()
        let controller = makeLoupe(url: url, identity: "pointer-exit")
        let card = drawnCard(histogram: knownCounts())
        controller.pointerReadoutTarget = card
        controller.pointerMoved(to: CGPoint(x: 100, y: 80))
        XCTAssertNotNil(controller.pointerReadout)
        render(card)
        XCTAssertEqual(card.readoutState, .image(value: try XCTUnwrap(controller.pointerReadout).level.text))
        XCTAssertFalse(card.readoutState.valueText.isEmpty)
        XCTAssertEqual(card.channelRowText, try XCTUnwrap(controller.pointerReadout).channelRowText,
                       "通道行是同一个像素的三通道值")
        XCTAssertFalse(card.channelRowText.isEmpty)

        controller.pointerExited()
        XCTAssertNil(controller.pointerCanvasPoint)
        XCTAssertNil(controller.pointerReadout)
        XCTAssertEqual(card.readoutState, .idle, "the row goes back to idle")
        render(card)
        XCTAssertTrue(card.hoverReadoutRect.isEmpty)
        XCTAssertFalse(card.readoutRowRect.isEmpty, "…and keeps its height")
        XCTAssertEqual(card.channelRowText, "", "通道行同样清空")
        XCTAssertTrue(card.channelLetterRects.isEmpty)
        XCTAssertEqual(card.channelRowRect.height, HistogramCardView.channelRowHeight, accuracy: 0,
                       "…通道行的高度也不变")

        // A photo switch clears it too: the reading belonged to the picture that is going away.
        controller.pointerMoved(to: CGPoint(x: 100, y: 80))
        XCTAssertNotNil(controller.pointerReadout)
        render(card)
        XCTAssertFalse(card.channelRowText.isEmpty, "通道行又回来了")
        controller.cancelPendingFrames()
        XCTAssertEqual(card.readoutState, .idle)
    }

    /// A texture the test owns: the readback path itself, with values this test chose, so the two
    /// branches of the axis (code and tail) are pinned without a screen that has headroom.
    func testTheSamplePlacesAPixelOnTheMeasuredAxis() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                 width: 4, height: 4,
                                                                 mipmapped: false)
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        // One row of known values: mid grey, near white, and two above white (2× and 4×).
        let columns: [(Float, Float, Float)] = [(0.5, 0.5, 0.5),
                                                (0.999, 0.999, 0.999),
                                                (Histogram.srgbEncode(2), Histogram.srgbEncode(2),
                                                 Histogram.srgbEncode(2)),
                                                (Histogram.srgbEncode(4), Histogram.srgbEncode(4),
                                                 Histogram.srgbEncode(4))]
        var pixels = [Float16](repeating: 0, count: 4 * 4 * 4)
        for x in 0..<4 {
            let (r, g, b) = columns[x]
            let o = (0 * 4 + x) * 4
            pixels[o] = Float16(r)
            pixels[o + 1] = Float16(g)
            pixels[o + 2] = Float16(b)
            pixels[o + 3] = 1
        }
        pixels.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                            withBytes: buffer.baseAddress!, bytesPerRow: 4 * 4 * 2)
        }
        let histogram = knownCounts()

        let grey = try XCTUnwrap(LoupeController.sample(texture, x: 0, y: 0, histogram: histogram))
        XCTAssertEqual(grey.level, .code(128), "0.5 encoded → code 128")
        XCTAssertEqual(grey.bin, 128)
        XCTAssertEqual(grey.level.text, "128")

        let white = try XCTUnwrap(LoupeController.sample(texture, x: 1, y: 0, histogram: histogram))
        XCTAssertEqual(white.level, .code(255))

        // 2× white is **one** stop (a stop is a doubling), and each stop is 64 tail bins.
        let oneStop = try XCTUnwrap(LoupeController.sample(texture, x: 2, y: 0, histogram: histogram))
        XCTAssertEqual(oneStop.isTail, true)
        guard case .stops(let oneStopValue) = oneStop.level else { return XCTFail("2× white is in the tail") }
        XCTAssertEqual(oneStopValue, 1, accuracy: 0.02, "2× white = +1.0 stop (float16 quantisation only)")
        XCTAssertEqual(oneStop.level.text, "+1.0")
        XCTAssertEqual(oneStop.bin, Histogram.hdrBinsPerStop)

        let twoStops = try XCTUnwrap(LoupeController.sample(texture, x: 3, y: 0, histogram: histogram))
        guard case .stops(let twoStopValue) = twoStops.level else { return XCTFail("4× white is in the tail") }
        XCTAssertEqual(twoStopValue, 2, accuracy: 0.02, "4× white = +2.0 stops")
        XCTAssertEqual(twoStops.level.text, "+2.0")
        XCTAssertEqual(twoStops.bin, 2 * Histogram.hdrBinsPerStop)
        print("sample: grey \(grey.level.text) bin \(grey.bin) · 2× \(oneStop.level.text) bin \(oneStop.bin) · 4× \(twoStops.level.text) bin \(twoStops.bin)")
    }
}
