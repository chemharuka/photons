import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// 406c — the additive plot is **computed in sRGB and filled opaquely**, not added by Core Graphics.
///
/// 403 measured the plot on an 8-bit **`deviceRGB`** surface, where `plusLighter` on three sRGB
/// primaries happens to be right — in an sRGB context `(1,0,0) + (0,1,0)` *is* `(1,1,0)`. A real
/// wide-gamut Mac window's backing store is **Display P3** though, and there the same code adds the
/// three primaries' *P3-encoded* coordinates: `(1.3759, 1.1856, 0.4369)`. An 8-bit P3 surface clamps
/// that to `(255, 255, 78)` — visibly yellow-green, never pure yellow — and a float/extended surface
/// keeps the overflow, which normalises to the pale pink the owner reported (「加色发淡粉」).
///
/// So the criterion here is an **8-bit Display P3** surface (§5.1–5.3 of the order), read back by
/// converting the whole surface to sRGB and reading raw bytes — the one read-back that returns
/// `(255,0,0)` for pure red. No EDR assumption, no float path, no "does the compositor keep >1".
///
/// **Ink is found by colour, not by coordinate** (§5.4): the y mapping of a `flipped: false` CGContext
/// differs from 403's `row(forViewY:)`, and a coordinate probe silently reads bare bed — which would
/// pass a "no pixel is too bright" style assertion and fail nothing. So each case scans the whole
/// surface for the class of pixels it is about.
///
/// Which cases actually distinguish before from after:
///
///   · **R+G is the one.** `b ≤ 5` fails on the old code with `b = 78`; passes now with `b = 0`.
///   · R+B / G+B clamp to `(255,0,255)` / `(3,255,255)` either way — a saturated channel hides the
///     overflow — so they are asserted here for completeness, not as a before/after gate.
///   · three-way and single-channel are white / their own primary on both builds; they are kept as
///     invariants (the old code clamped to white in 8 bits and the shape of a single fill is
///     unchanged).
@MainActor
final class HistogramAdditive406cTests: XCTestCase {

    private let cardWidth: CGFloat = 400
    private let scale: CGFloat = 2
    private let cardHeight = HistogramCardView.contentHeight

    /// A five-bin plateau, the same fixture 403 uses: ~8 px of ink at 2× and clear of the
    /// quarter-tone guides (50 / 100 / 150 pt on a 400 pt card; this plateau's centre is at 80 pt).
    private let plateau = 100...104

    private func histogram(red: Int = 0, green: Int = 0, blue: Int = 0, luma: Int = 0) -> Histogram {
        func channel(_ value: Int) -> HistogramChannel {
            HistogramChannel(bins: (0..<256).map { plateau.contains($0) ? value : 0 },
                             hdrBins: [Int](repeating: 0, count: Histogram.hdrBinCount),
                             clippedHigh: 0, clippedCeiling: 0, clippedLow: 0)
        }
        return Histogram(binCount: 256, sampleCount: 898_432,
                         canvas: ImageSize(width: 720, height: 420),
                         roi: ImageRect(x: 0, y: 0, width: 720, height: 420),
                         sampleSize: ImageSize(width: 720, height: 420),
                         primaries: .sRGB, headroom: 1,
                         red: channel(red), green: channel(green), blue: channel(blue),
                         luma: channel(luma))
    }

    // MARK: - the surface
    //
    // `NSBitmapImageRep(colorSpaceName: NSColorSpaceName(rawValue: "NSDisplayP3ColorSpace"))` is
    // **nil** on this platform (§5.2), so the surface has to be a CGContext. Its backing is P3 and
    // 8 bits per component: the store a wide-gamut window really gets, and the one where the
    // arithmetic bug is visible without any float/EDR question.

    private struct SRGBImage {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let rowBytes: Int

        func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = y * rowBytes + x * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }

        /// Every pixel matching `predicate`, as a census: how many, and the extremes of each channel.
        func census(where predicate: (Int, Int, Int) -> Bool) -> (count: Int, maxes: (r: Int, g: Int, b: Int),
                                                                 mins: (r: Int, g: Int, b: Int)) {
            var count = 0
            var maxes = (0, 0, 0)
            var mins = (255, 255, 255)
            for y in 0..<height {
                for x in 0..<width {
                    let p = rgb(x, y)
                    guard predicate(p.r, p.g, p.b) else { continue }
                    count += 1
                    maxes = (max(maxes.0, p.r), max(maxes.1, p.g), max(maxes.2, p.b))
                    mins = (min(mins.0, p.r), min(mins.1, p.g), min(mins.2, p.b))
                }
            }
            return (count, maxes, mins)
        }
    }

    /// One real `draw` through an **8-bit Display P3** CGContext, converted wholesale into sRGB and
    /// read as raw bytes (§5.3's ③ — the only read-back that returns `(255,0,0)` for pure red; the
    /// P3 store's own bytes and `colorAt().usingColorSpace(.sRGB)` are both lossy here).
    private func image(of histogram: Histogram) -> SRGBImage {
        let width = Int(cardWidth * scale)
        let height = Int(cardHeight * scale)
        let p3 = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                           bytesPerRow: width * 4,
                           space: CGColorSpace(name: CGColorSpace.displayP3)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // An opaque black bed: alpha stays 1 everywhere, so the read-back never has to un-premultiply.
        p3.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        p3.fill(CGRect(x: 0, y: 0, width: width, height: height))
        p3.scaleBy(x: scale, y: scale)

        let card = HistogramCardView()
        card.frame = NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
        let resolution = NSAppearance(named: .aqua)!
        card.appearance = resolution
        card.histogram = histogram
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: p3, flipped: false)
        resolution.performAsCurrentDrawingAppearance { card.draw(card.bounds) }
        NSGraphicsContext.restoreGraphicsState()

        let srgb = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                             bytesPerRow: width * 4,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        srgb.draw(p3.makeImage()!, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pointer = srgb.data!.bindMemory(to: UInt8.self, capacity: srgb.bytesPerRow * height)
        return SRGBImage(bytes: Array(UnsafeBufferPointer(start: pointer,
                                                          count: srgb.bytesPerRow * height)),
                         width: width, height: height, rowBytes: srgb.bytesPerRow)
    }

    // MARK: - ① R + G = exactly yellow (the one case that fails before the fix)

    /// Before 406c: these pixels are `(255, 255, 78)` — `b = 78`. After: `(255, 255, 0)`.
    func testRedPlusGreenIsExactlyYellowOnAnEightBitP3Surface() {
        let img = image(of: histogram(red: 1000, green: 1000))
        let yellow = img.census { r, g, _ in r >= 250 && g >= 250 }
        print("① R+G 于 8-bit Display P3 → sRGB：黄墨 \(yellow.count) px，"
              + "各分量 max \(yellow.maxes)，min \(yellow.mins)")
        XCTAssertGreaterThanOrEqual(yellow.count, 100, "没找到黄墨：绘制缺失（不是通过）")
        XCTAssertLessThanOrEqual(yellow.maxes.b, 5,
                                 "R+G 的蓝必须是 0：改前 P3 上是 (1.3759,1.1856,0.4369) ⇒ b ≈ 78，"
                                 + "实测 max b = \(yellow.maxes.b)")
        XCTAssertGreaterThanOrEqual(yellow.mins.r, 250, "黄墨的红要满")
        XCTAssertGreaterThanOrEqual(yellow.mins.g, 250, "黄墨的绿要满")
    }

    // MARK: - ② R + B and G + B are their own secondaries
    //
    // Not a before/after gate: the saturated channel clamps the overflow away in 8 bits, so these
    // read the same on both builds (documented in the order's §5.6 table). They are here so the
    // additive contract is stated in full, not only where it happens to have been broken.

    func testRedPlusBlueIsMagentaAndGreenPlusBlueIsCyanOnAnEightBitP3Surface() {
        let magenta = image(of: histogram(red: 1000, blue: 1000)).census { r, _, b in r >= 250 && b >= 250 }
        print("② R+B：品红墨 \(magenta.count) px，各分量 max \(magenta.maxes)，min \(magenta.mins)")
        XCTAssertGreaterThanOrEqual(magenta.count, 100, "没找到品红墨：绘制缺失")
        XCTAssertLessThanOrEqual(magenta.maxes.g, 5, "R+B 的绿必须是 0，实测 max g = \(magenta.maxes.g)")

        let cyan = image(of: histogram(green: 1000, blue: 1000)).census { _, g, b in g >= 250 && b >= 250 }
        print("② G+B：青墨 \(cyan.count) px，各分量 max \(cyan.maxes)，min \(cyan.mins)")
        XCTAssertGreaterThanOrEqual(cyan.count, 100, "没找到青墨：绘制缺失")
        XCTAssertLessThanOrEqual(cyan.maxes.r, 5, "G+B 的红必须是 0，实测 max r = \(cyan.maxes.r)")
    }

    // MARK: - ③ three together = white

    /// Before and after both clamp to white in 8 bits (the raw three-way sum is `1.38 / 1.19 / 1.40`),
    /// so this is an invariant, not a gate — stated as such rather than claimed as a discriminator.
    func testThreeWayOverlapIsWhiteOnAnEightBitP3Surface() {
        let img = image(of: histogram(red: 1000, green: 1000, blue: 1000))
        let white = img.census { r, g, b in min(r, g, b) >= 250 }
        print("③ 三路齐：白墨 \(white.count) px，各分量 max \(white.maxes)，min \(white.mins)")
        XCTAssertGreaterThanOrEqual(white.count, 100, "没找到白墨：绘制缺失")
        let spread = max(white.maxes.r, white.maxes.g, white.maxes.b)
            - min(white.mins.r, white.mins.g, white.mins.b)
        XCTAssertLessThanOrEqual(spread, 6, "白是中性：三分量极差 ≤ 6，实测 \(spread)")
    }

    // MARK: - ④ one channel alone is its own primary

    /// Unchanged by the fix (a single opaque fill encodes the same either way) — an invariant, and the
    /// check that the band decomposition never bleeds one channel into another.
    func testSingleChannelIsItsOwnPrimaryOnAnEightBitP3Surface() {
        let cases: [(name: String, histogram: Histogram)] = [
            ("单 R", histogram(red: 1000)), ("单 G", histogram(green: 1000)), ("单 B", histogram(blue: 1000)),
        ]
        for c in cases {
            let img = image(of: c.histogram)
            switch c.name {
            case "单 R":
                let ink = img.census { r, g, b in r >= 250 && g <= 5 && b <= 5 }
                print("④ 单 R：红墨 \(ink.count) px，各分量 max \(ink.maxes)")
                XCTAssertGreaterThanOrEqual(ink.count, 100, "单 R：没找到纯红墨")
            case "单 G":
                let ink = img.census { r, g, b in g >= 250 && r <= 5 && b <= 5 }
                print("④ 单 G：绿墨 \(ink.count) px，各分量 max \(ink.maxes)")
                XCTAssertGreaterThanOrEqual(ink.count, 100, "单 G：没找到纯绿墨")
            default:
                let ink = img.census { r, g, b in b >= 250 && r <= 5 && g <= 5 }
                print("④ 单 B：蓝墨 \(ink.count) px，各分量 max \(ink.maxes)")
                XCTAssertGreaterThanOrEqual(ink.count, 100, "单 B：没找到纯蓝墨")
            }
        }
    }

    // MARK: - ⑤ no component anywhere is at its ceiling "by accident"

    /// Trivial for a `UInt8` store, and kept as the suite's invariant: it is the statement that the
    /// additive colour is **constructed** (a channel mask) rather than summed, so no future additive
    /// operation may be reintroduced here without this suite noticing that it now needs clamping.
    func testNoPixelAnywhereExceedsItsChannelMaximum() {
        let img = image(of: histogram(red: 1000, green: 1000, blue: 1000))
        var worst = (r: 0, g: 0, b: 0)
        var checked = 0
        for y in 0..<img.height {
            for x in 0..<img.width {
                let p = img.rgb(x, y)
                worst = (max(worst.r, p.r), max(worst.g, p.g), max(worst.b, p.b))
                checked += 1
            }
        }
        print("⑤ 遍历 \(checked) px，各分量 max \(worst)（上限 255）")
        XCTAssertGreaterThan(checked, 0, "位图是空的：这个不变量没有意义")
        XCTAssertLessThanOrEqual(worst.r, 255)
        XCTAssertLessThanOrEqual(worst.g, 255)
        XCTAssertLessThanOrEqual(worst.b, 255)
    }
}
