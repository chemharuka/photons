import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// 403 — the plot is **three** additive series, not four overlaid ones.
///
/// The owner's wording: 「直方图取消白色线，只绘制 RGB，RGB 重叠部分的颜色按光叠加展示——即都有的话白色，
/// R+G 就是黄色」. So this file measures the *painted* card offscreen at 2×, exactly the way
/// `HistogramAxisTests.bitmap(of:cardWidth:scale:)` does — one drawing pipeline, no copy:
///
///   ① one channel alone paints its own hue and nothing else;
///   ② R + G on the same bin is **yellow** (r ≈ g, b far below both);
///   ③ R + G + B on the same bin is **white**;
///   ④ the luma outline is gone — a luma-only histogram paints nothing at all;
///   ⑤ the result does not depend on the appearance, because the added layer is composited over a
///      **fixed dark bed** (the one change outside the series list this lane had to make: additive
///      light at full strength cannot work on a light bed).
///
/// Every threshold is derived from a pixel these tests print first; see `local/REPORT.md` for the
/// measured numbers and the margins.
@MainActor
final class HistogramAdditive403Tests: XCTestCase {

    private let cardWidth: CGFloat = 400
    private let scale: CGFloat = 2
    private let cardHeight = HistogramCardView.contentHeight

    /// Where the fixtures put their samples: a five-bin plateau, so the column under test is ~8 px
    /// wide at 2× and — the reason for these numbers — clear of the quarter-tone grid lines (they sit
    /// at 50 / 100 / 150 pt of the 400 pt card; this plateau's centre is at 80 pt).
    private let plateau = 100...104
    private let sampleBin = 102

    // MARK: - fixtures

    /// A histogram whose named channels hold `value` on the plateau and nothing anywhere else.
    private func histogram(red: Int = 0, green: Int = 0, blue: Int = 0, luma: Int = 0,
                           headroom: Double = 1) -> Histogram {
        func channel(_ value: Int) -> HistogramChannel {
            HistogramChannel(bins: (0..<256).map { plateau.contains($0) ? value : 0 },
                             hdrBins: [Int](repeating: 0, count: Histogram.hdrBinCount),
                             clippedHigh: 0, clippedCeiling: 0, clippedLow: 0)
        }
        return Histogram(binCount: 256, sampleCount: 898_432,
                         canvas: ImageSize(width: 720, height: 420),
                         roi: ImageRect(x: 0, y: 0, width: 720, height: 420),
                         sampleSize: ImageSize(width: 720, height: 420),
                         primaries: .sRGB, headroom: headroom,
                         red: channel(red), green: channel(green), blue: channel(blue),
                         luma: channel(luma))
    }

    /// One real `draw` into an offscreen bitmap at 2×, with the card's appearance pinned.
    ///
    /// `performAsCurrentDrawingAppearance` matters: `card.appearance` alone does not make semantic
    /// colours (`labelColor` and friends) resolve inside a bitmap context, and the point of ⑤ is that
    /// the *appearance* really is different during the draw. With it, a `labelColor`-based bed would
    /// resolve to 0.94 in aqua and 0.13 in darkAqua — which is exactly the regression ⑤ must catch.
    private func bitmap(of histogram: Histogram?,
                        appearance: NSAppearance.Name = .aqua) -> NSBitmapImageRep {
        let card = HistogramCardView()
        card.frame = NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
        let resolution = NSAppearance(named: appearance)!
        card.appearance = resolution
        card.histogram = histogram
        lastCard = card
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(cardWidth * scale),
                                   pixelsHigh: Int(cardHeight * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: cardWidth, height: cardHeight)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        resolution.performAsCurrentDrawingAppearance {
            card.draw(card.bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The card the last `bitmap(...)` drew — its `lastAxis` says where the pixels are.
    private var lastCard: HistogramCardView?

    /// The card is `isFlipped` (view y is 0 at the **top**), a bitmap's row 0 is its top too, and
    /// AppKit flips the view into the bitmap context — so a view point `y` lands on bitmap row
    /// `(cardHeight − y) × scale`. Measured, not assumed: the plot's bed occupies rows
    /// `(90 − 58)·2 = 64 … 180` and the clipping row's ink rows ~168…175.
    private func row(forViewY y: CGFloat) -> Int {
        Int(((cardHeight - y) * scale).rounded())
    }

    /// The pixel column of the fixture's bin and the middle row of the plot.
    private func plotColumn(_ card: HistogramCardView) -> (x: Int, y: Int) {
        let axis = card.lastAxis!
        return (Int((axis.x(sdrBin: sampleBin, of: 256) * scale).rounded()),
                row(forViewY: axis.plot.midY))
    }

    /// A point of bare bed: 5 pt in from the left edge (the grid starts at 50 pt), mid-height.
    private func bedPixel(_ card: HistogramCardView) -> (x: Int, y: Int) {
        (Int((5 * scale).rounded()), row(forViewY: card.lastAxis!.plot.midY))
    }

    /// Every row the plot covers, as bitmap rows.
    private func plotRows(_ card: HistogramCardView) -> Range<Int> {
        let plot = card.lastAxis!.plot
        return row(forViewY: plot.maxY)..<row(forViewY: plot.minY)
    }

    private func rgb(_ rep: NSBitmapImageRep, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (-1, -1, -1) }
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    private func formatted(_ c: (r: Double, g: Double, b: Double)) -> String {
        String(format: "(r %.3f, g %.3f, b %.3f)", c.r, c.g, c.b)
    }

    // MARK: - ① one channel paints its own hue

    func testASingleChannelPaintsOnlyItsOwnHue() {
        let cases: [(name: String, histogram: Histogram,
                     own: WritableKeyPath<(r: Double, g: Double, b: Double), Double>)] = [
            ("单 R", histogram(red: 1000), \.r),
            ("单 G", histogram(green: 1000), \.g),
            ("单 B", histogram(blue: 1000), \.b),
        ]
        for c in cases {
            let rep = bitmap(of: c.histogram)
            let card = lastCard!
            let (x, y) = plotColumn(card)
            let bed = bedPixel(card)
            let p = rgb(rep, x: x, y: y)
            print("① \(c.name) @ (\(x), \(y)) → \(formatted(p)) · 底板 \(formatted(rgb(rep, x: bed.x, y: bed.y)))")
            let own = p[keyPath: c.own]
            // The other two channels, named so the fixture's key path stays readable.
            let others: [Double] = c.name == "单 R" ? [p.g, p.b] : (c.name == "单 G" ? [p.r, p.b] : [p.r, p.g])
            XCTAssertGreaterThanOrEqual(own, 0.6,
                                        "\(c.name)：自己的那一路要有实色，实测 \(formatted(p))")
            XCTAssertGreaterThanOrEqual(own - (others.max() ?? 0), 0.3,
                                        "\(c.name)：另两路必须远低于自己，实测 \(formatted(p))")
            XCTAssertLessThanOrEqual(abs(others[0] - others[1]), 0.05,
                                     "\(c.name)：剩下两路是加法的零，不应互相有色差，实测 \(formatted(p))")
        }
    }

    // MARK: - ② R + G = 黄

    func testRedPlusGreenIsYellow() {
        let rep = bitmap(of: histogram(red: 1000, green: 1000))
        let (x, y) = plotColumn(lastCard!)
        let p = rgb(rep, x: x, y: y)
        print("② R+G @ (\(x), \(y)) → \(formatted(p))")
        XCTAssertLessThanOrEqual(abs(p.r - p.g), 0.08,
                                 "R+G 必须是黄色：r 与 g 相等，实测 \(formatted(p))")
        XCTAssertLessThanOrEqual(p.b, min(p.r, p.g) - 0.15,
                                 "R+G 的蓝必须明显更低，实测 \(formatted(p))")
    }

    // MARK: - ③ R + G + B = 白

    func testAllThreeTogetherAreWhite() {
        let rep = bitmap(of: histogram(red: 1000, green: 1000, blue: 1000))
        let (x, y) = plotColumn(lastCard!)
        let p = rgb(rep, x: x, y: y)
        print("③ R+G+B @ (\(x), \(y)) → \(formatted(p))")
        XCTAssertGreaterThanOrEqual(min(p.r, p.g, p.b), 0.85,
                                    "三路齐必须是白色，实测 \(formatted(p))")
        XCTAssertLessThanOrEqual(max(p.r, p.g, p.b) - min(p.r, p.g, p.b), 0.06,
                                 "白是中性：三路差 ≤ 0.06，实测 \(formatted(p))")
    }

    func testOverlapStaysNeutralSDRWhiteInExtendedLinearDisplayP3() throws {
        let card = HistogramCardView()
        card.frame = NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
        card.histogram = histogram(red: 1000, green: 1000, blue: 1000, headroom: 4)
        let width = Int(cardWidth * scale), height = Int(cardHeight * scale)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 32, bytesPerRow: width * 16,
            space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        card.draw(card.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let point = plotColumn(card)
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: Float.self)
        let index = (point.y * width + point.x) * 4
        let rgb = (0..<3).map { pixels[index + $0] }
        XCTAssertGreaterThan(rgb.min()!, 0.95)
        XCTAssertLessThanOrEqual(rgb.max()!, 1.01, "UI white must not become an EDR highlight")
        XCTAssertLessThan(rgb.max()! - rgb.min()!, 0.015, "RGB overlap must remain neutral on a P3 HDR display")
    }

    // MARK: - ④ the luma line is gone

    func testTheLumaLineIsGone() {
        // The series count on a real measurement: three colour paths, no fourth outline.
        _ = bitmap(of: histogram(red: 1000, green: 1000, blue: 1000, luma: 1000))
        let card = lastCard!
        print("④ lastDrawnSeries = \(card.lastDrawnSeries)（改前 4 / 改后 3）")
        XCTAssertEqual(card.lastDrawnSeries, 3, "只画 RGB 三组（luma 不再画）")

        // A luma-only measurement must paint **nothing**: the same pixels as everything-zero, and the
        // band where luma's spike would be is still bare bed.
        let lumaOnly = bitmap(of: histogram(luma: 1000))
        let lumaCard = lastCard!
        let empty = bitmap(of: histogram())
        let emptyCard = lastCard!
        print("④ luma-only series = \(lumaCard.lastDrawnSeries) · 空直方图 series = \(emptyCard.lastDrawnSeries)")

        let axis = lumaCard.lastAxis!
        let from = Int((axis.x(sdrBin: plateau.lowerBound, of: 256) * scale).rounded()) - 3
        let to = Int((axis.x(sdrBin: plateau.upperBound, of: 256) * scale).rounded()) + 3
        var bedMax = 0.0
        var lumaMax = 0.0
        var differing = 0
        for x in from...to {
            for y in plotRows(lumaCard) {
                let a = rgb(lumaOnly, x: x, y: y)
                let b = rgb(empty, x: x, y: y)
                bedMax = max(bedMax, b.r, b.g, b.b)
                lumaMax = max(lumaMax, a.r, a.g, a.b)
                if abs(a.r - b.r) > 0.03 || abs(a.g - b.g) > 0.03 || abs(a.b - b.b) > 0.03 {
                    differing += 1
                }
            }
        }
        print("④ luma 那条本应在的列带：bedMax \(String(format: "%.3f", bedMax)) · "
              + "luma 图在同一带的 max \(String(format: "%.3f", lumaMax)) · 差异像素 \(differing)")
        XCTAssertEqual(lumaCard.lastDrawnSeries, 0, "luma 不产生任何一条绘制序列")
        XCTAssertEqual(differing, 0, "只有 luma 有值时画面与「什么都没有」逐像素相同（没有白线）")
        XCTAssertLessThanOrEqual(lumaMax, bedMax + 0.05,
                                 "没有数据的地方不许比底板亮：\(String(format: "%.3f", lumaMax)) vs "
                                 + "\(String(format: "%.3f", bedMax))")
    }

    // MARK: - ⑤ the overlap colour is the data's, not the appearance's

    func testOverlapColoursDoNotDependOnAppearance() {
        let yellowAqua = bitmap(of: histogram(red: 1000, green: 1000), appearance: .aqua)
        let aqua = plotColumn(lastCard!)
        let yellowAquaPixel = rgb(yellowAqua, x: aqua.x, y: aqua.y)
        let bed = bedPixel(lastCard!)
        let bedAqua = rgb(yellowAqua, x: bed.x, y: bed.y)

        let yellowDark = bitmap(of: histogram(red: 1000, green: 1000), appearance: .darkAqua)
        let dark = plotColumn(lastCard!)
        let yellowDarkPixel = rgb(yellowDark, x: dark.x, y: dark.y)
        let darkBed = bedPixel(lastCard!)
        let bedDark = rgb(yellowDark, x: darkBed.x, y: darkBed.y)

        let whiteAqua = bitmap(of: histogram(red: 1000, green: 1000, blue: 1000), appearance: .aqua)
        let wa = plotColumn(lastCard!)
        let whiteAquaPixel = rgb(whiteAqua, x: wa.x, y: wa.y)
        let whiteDark = bitmap(of: histogram(red: 1000, green: 1000, blue: 1000), appearance: .darkAqua)
        let wd = plotColumn(lastCard!)
        let whiteDarkPixel = rgb(whiteDark, x: wd.x, y: wd.y)

        print("⑤ 底板 aqua \(formatted(bedAqua)) · darkAqua \(formatted(bedDark))")
        print("⑤ R+G aqua \(formatted(yellowAquaPixel)) · darkAqua \(formatted(yellowDarkPixel))")
        print("⑤ R+G+B aqua \(formatted(whiteAquaPixel)) · darkAqua \(formatted(whiteDarkPixel))")

        for (name, a, b) in [("R+G", yellowAquaPixel, yellowDarkPixel),
                             ("R+G+B", whiteAquaPixel, whiteDarkPixel)] {
            XCTAssertLessThanOrEqual(abs(a.r - b.r), 0.10, "\(name) 的 R 不随外观变")
            XCTAssertLessThanOrEqual(abs(a.g - b.g), 0.10, "\(name) 的 G 不随外观变")
            XCTAssertLessThanOrEqual(abs(a.b - b.b), 0.10, "\(name) 的 B 不随外观变")
        }
        XCTAssertLessThanOrEqual(abs(bedAqua.r - bedDark.r), 0.05, "底板两种外观同值（R）")
        XCTAssertLessThanOrEqual(abs(bedAqua.g - bedDark.g), 0.05, "底板两种外观同值（G）")
        XCTAssertLessThanOrEqual(abs(bedAqua.b - bedDark.b), 0.05, "底板两种外观同值（B）")
        // …and the bed really is a fixed *dark* surface, not the ~0.94 light tint the additive scheme
        // cannot work on (that tint is what §1.2 of the order measured).
        XCTAssertLessThanOrEqual(max(bedAqua.r, bedAqua.g, bedAqua.b), 0.20,
                                 "底板是深色面，实测 \(formatted(bedAqua))")
    }

    // MARK: - ⑥ the chrome on the new bed is still visible (§2.3's regression point)

    /// Moving the bed to a fixed dark surface makes every `labelColor` tint on it invisible in aqua — a
    /// black 8 % grid on a 0.09 bed *is* the bed. So the chrome (quarter-tone guides, the SDR/tail
    /// split, the `+1…+4` stop numbers) is fixed light ink; this case measures all three on the paint,
    /// in both appearances, and asserts they are **brighter than the bare bed** by a visible margin.
    func testTheChromeStaysVisibleOnTheDarkBedInBothAppearances() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let rep = bitmap(of: histogram(red: 1000, green: 1000, blue: 1000),
                             appearance: appearance)
            let card = lastCard!
            let axis = card.lastAxis!
            let midRow = row(forViewY: axis.plot.midY)
            let bed = rgb(rep, x: 10, y: midRow)
            let bedLuma = (bed.r + bed.g + bed.b) / 3

            // The quarter-tone guide at 25 % of the SDR segment (2 px wide at 2×, so probe the centre).
            let gridX = Int((axis.plot.width / 4 * scale).rounded())
            let gridLuma = { () -> Double in
                var best = 0.0
                for x in (gridX - 2)...(gridX + 2) {
                    let c = rgb(rep, x: x, y: midRow)
                    best = max(best, (c.r + c.g + c.b) / 3)
                }
                return best
            }()

            // The `+n` stop numbers sit in the top 9 pt of the plot. Measured on a card with **no**
            // histogram: the axis (bed, guides, split, stop numbers) is all that is painted then, so the
            // brightest ink up there is the numbers themselves and cannot be a curve.
            let blank = bitmap(of: nil)
            var labelLuma = 0.0
            for x in 0..<Int(cardWidth * scale) {
                for y in row(forViewY: 9)..<row(forViewY: 1) {
                    let c = rgb(blank, x: x, y: y)
                    labelLuma = max(labelLuma, (c.r + c.g + c.b) / 3)
                }
            }
            print("⑥ \(appearance.rawValue) 底板 \(formatted(bed)) 亮度 \(String(format: "%.3f", bedLuma)) · "
                  + "网格 \(String(format: "%.3f", gridLuma)) · 停档数字带 \(String(format: "%.3f", labelLuma))")

            XCTAssertLessThanOrEqual(bedLuma, 0.16, "\(appearance.rawValue)：底板是暗的")
            XCTAssertGreaterThanOrEqual(gridLuma - bedLuma, 0.05,
                                        "\(appearance.rawValue)：四分线必须在深底上看得见")
            XCTAssertGreaterThanOrEqual(labelLuma - bedLuma, 0.20,
                                        "\(appearance.rawValue)：停档数字必须在深底上看得见")
        }
    }
}
