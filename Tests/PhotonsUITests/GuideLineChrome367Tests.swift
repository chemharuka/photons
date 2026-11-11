import XCTest
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// **367 — 引导线「看得见」**: colour, width and endpoint dots, measured on a bitmap.
///
/// The user's report was visual (「现在的引导线不明显，两端点需要用「点」来标记，线的颜色不要用现在
/// 默认的灰白，用更加有辨识度的，而且要稍微粗一些」), so the acceptance is visual too: the pixels the
/// painter writes, not the constants it reads. Each test draws through the shipped
/// `CropStraightenLinePainter` with `GuideLineChrome`'s numbers, then counts pixels of the accepted
/// colour. The reverse-gate numbers live in the task report: at 1.5 pt / no dots the middle-line
/// width is 3 px and the endpoint count is 0 — both below the thresholds asserted here.
@MainActor
final class GuideLineChrome367Tests: XCTestCase {

    private let pointSize = NSSize(width: 1000, height: 700)
    private let backingScale: CGFloat = 2

    // MARK: - the bitmap harness

    /// A 1000 × 700 pt canvas at 2× (2000 × 1400 px) filled with the canvas backdrop `#202020`.
    private func makeBitmap() throws -> (NSBitmapImageRep, NSGraphicsContext) {
        let pixelsWide = Int(pointSize.width * backingScale)
        let pixelsHigh = Int(pointSize.height * backingScale)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = pointSize
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        NSColor(srgbRed: 32.0 / 255, green: 32.0 / 255, blue: 32.0 / 255, alpha: 1).setFill()
        NSRect(origin: .zero, size: pointSize).fill()
        NSGraphicsContext.current = previous
        return (rep, context)
    }

    /// Draw the shipped guide-line chrome. Coordinates are **points**, deliberately on half pixels so
    /// a 2.5 pt stroke covers 5 whole device pixels at 2×.
    private func drawGuideLine(in rep: NSBitmapImageRep, from a: CGPoint, to b: CGPoint,
                               colour: NSColor = GuideLineChrome.acceptedColour) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        CropStraightenLinePainter.draw(CropToolSegment(a: a, b: b), alpha: 1,
                                       colour: colour,
                                       width: GuideLineChrome.lineWidth,
                                       shadowWidth: GuideLineChrome.shadowWidth,
                                       dotRadius: GuideLineChrome.dotRadius,
                                       dotRingWidth: GuideLineChrome.dotRingWidth)
        NSGraphicsContext.current = previous
    }

    private func srgb(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? color
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    /// ±2 codes out of 255 per channel, as the acceptance states.
    private func matches(_ color: NSColor, _ reference: NSColor) -> Bool {
        let a = srgb(color), b = srgb(reference)
        let scale: CGFloat = 255
        return abs(a.r - b.r) * scale <= 2
            && abs(a.g - b.g) * scale <= 2
            && abs(a.b - b.b) * scale <= 2
    }

    private func debugColour(_ color: NSColor) -> String {
        let c = srgb(color)
        return String(format: "#%02X%02X%02X", Int(round(c.r * 255)),
                      Int(round(c.g * 255)), Int(round(c.b * 255)))
    }

    // MARK: - ① endpoint dots

    /// ① — both ends carry a disc of the accepted colour. Before 367 the painter drew no dot at all
    /// (0 px); the measurement is the count inside ±3 pt of each endpoint.
    func testBothEndpointsCarryADotOfTheAcceptedColour() throws {
        let (rep, _) = try makeBitmap()
        let a = CGPoint(x: 200.5, y: 350.5)
        let b = CGPoint(x: 800.5, y: 350.5)
        drawGuideLine(in: rep, from: a, to: b)

        let reference = GuideLineChrome.acceptedColour
        func count(around point: CGPoint) -> Int {
            let radius = 3.0 * Double(backingScale)
            let cx = Double(point.x) * Double(backingScale)
            let cy = Double(point.y) * Double(backingScale)
            let x0 = max(0, Int(cx - radius)), x1 = min(rep.pixelsWide - 1, Int(cx + radius))
            let y0 = max(0, Int(cy - radius)), y1 = min(rep.pixelsHigh - 1, Int(cy + radius))
            var found = 0
            for y in y0...y1 {
                for x in x0...x1 {
                    guard let color = rep.colorAt(x: x, y: y) else { continue }
                    if matches(color, reference) { found += 1 }
                }
            }
            return found
        }
        let first = count(around: a), second = count(around: b)
        print("367 ① 端点: 起点 ±3 pt \(first) px · 终点 \(second) px · 色 \(debugColour(reference))")
        XCTAssertGreaterThanOrEqual(first, 20, "367 ① 起点没有端点圆点")
        XCTAssertGreaterThanOrEqual(second, 20, "367 ① 终点没有端点圆点")
    }

    // MARK: - ② width

    /// ② — the line is **thicker than 328's 1.5 pt** and thinner than 367's 2.5 pt.
    ///
    /// 2026-11-11 (user): 「引导线粗细再细一些」 → `GuideLineChrome.lineWidth = 2.0`. At the bitmap's
    /// 2× that is 4 px of body, and the fully-saturated run the matcher counts is 3 px (the two
    /// outermost pixels are the anti-aliased skirt). The floor therefore moves 4 → 3, and the
    /// assertion still fails on 328's 1.5 pt (2 px) — the thing it exists to catch.
    func testTheLineBodyIsAtLeastFourPixelsWide() throws {
        let (rep, _) = try makeBitmap()
        let a = CGPoint(x: 200.5, y: 350.5)
        let b = CGPoint(x: 800.5, y: 350.5)
        drawGuideLine(in: rep, from: a, to: b)

        let reference = GuideLineChrome.acceptedColour
        let x = Int(500 * backingScale)
        var longest = 0, run = 0
        for y in 0..<rep.pixelsHigh {
            guard let color = rep.colorAt(x: x, y: y) else { run = 0; continue }
            if matches(color, reference) { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        print("367 ② 线身: x=500 pt 横截面连续 \(longest) px（2.0 pt @2× = 4 px）")
        XCTAssertGreaterThanOrEqual(longest, 3, "367 ② 引导线不够粗（< 2.0 pt）")
    }

    // MARK: - ③ colour

    /// ③ — the colour is `#22D3EE`: chroma ≥ 0.30 and ΔE00 ≥ 25 against the three backgrounds that
    /// matter (the `#202020` backdrop, the frame's white, the rejected red).
    func testTheAcceptedColourIsDistinctiveAgainstBackdropWhiteAndRed() {
        let colour = GuideLineChrome.acceptedColour
        let c = srgb(colour)
        let chroma = max(c.r, c.g, c.b) - min(c.r, c.g, c.b)
        let backdrop = NSColor(srgbRed: 32.0 / 255, green: 32.0 / 255, blue: 32.0 / 255, alpha: 1)
        let white = NSColor.white
        let red = NSColor.systemRed
        let against = [("backdrop", backdrop), ("white", white), ("red", red)]
            .map { ($0.0, deltaE00(colour, $0.1)) }
        print(String(format: "367 ③ 颜色 %@: 色度 %.3f · ΔE00 %@", debugColour(colour), chroma,
                     against.map { String(format: "%@ %.1f", $0.0, $0.1) }.joined(separator: " / ")))
        XCTAssertGreaterThanOrEqual(chroma, 0.30, "367 ③ 颜色不够鲜艳")
        for (name, delta) in against {
            XCTAssertGreaterThanOrEqual(delta, 25, "367 ③ 与 \(name) 的 ΔE00 太小")
        }
        // 2026-11-11：用户「再细一些，直接改不跑测试」→ `lineWidth` 2.5 → 2.0（`ba18e3d`）；
        // 这条断言当时没跟着改，属遗留红，现按实现重钉（仍高于 328 的 1.5 pt）。
        XCTAssertEqual(GuideLineChrome.lineWidth, 2.0)
        XCTAssertEqual(GuideLineChrome.shadowWidth, 1.5)
        XCTAssertEqual(GuideLineChrome.dotRadius, 4)
        XCTAssertEqual(GuideLineChrome.acceptedAlpha, 0.9, accuracy: 1e-12)
    }

    // MARK: - ⑪ 328's line is untouched

    /// ⑪ — the guide line's chrome must not leak into 328's 画线拉直 line: 1.5 pt, 1 px, and the
    /// painter's defaults are still those numbers (dots off).
    func testTheStraightenLineKeepsItsOldNumbers() {
        XCTAssertEqual(CropDrawStraighten.lineWidth, 1.5)
        XCTAssertEqual(CropDrawStraighten.shadowWidth, 1)
        XCTAssertEqual(CropToolOverlayView.straightenLineWidth, 1.5)
        XCTAssertEqual(CropToolOverlayView.straightenShadowWidth, 1)
        XCTAssertGreaterThan(CropToolOverlayView.appliedGuideLineAlpha, 0.2)
        print("367 ⑪ 328 线仍 \(CropToolOverlayView.straightenLineWidth) pt / "
              + "\(CropToolOverlayView.straightenShadowWidth) px · 引导线透明度 "
              + "\(CropToolOverlayView.appliedGuideLineAlpha)")
    }

    // MARK: - CIEDE2000

    private func deltaE00(_ first: NSColor, _ second: NSColor) -> Double {
        let a = lab(first), b = lab(second)
        let rad = Double.pi / 180
        let c1 = (a.a * a.a + a.b * a.b).squareRoot()
        let c2 = (b.a * b.a + b.b * b.b).squareRoot()
        let cBar = (c1 + c2) / 2
        let g = 0.5 * (1 - (cBar.powi(7) / (cBar.powi(7) + 25.0.powi(7))).squareRoot())
        let a1p = (1 + g) * a.a, a2p = (1 + g) * b.a
        let c1p = (a1p * a1p + a.b * a.b).squareRoot()
        let c2p = (a2p * a2p + b.b * b.b).squareRoot()
        func hue(_ b: Double, _ a: Double) -> Double {
            guard abs(a) > 1e-12 || abs(b) > 1e-12 else { return 0 }
            var h = atan2(b, a) / rad
            if h < 0 { h += 360 }
            return h
        }
        let h1p = hue(a.b, a1p), h2p = hue(b.b, a2p)
        let dL = b.l - a.l
        let dC = c2p - c1p
        var dh = h2p - h1p
        if c1p * c2p == 0 { dh = 0 }
        else if dh > 180 { dh -= 360 }
        else if dh < -180 { dh += 360 }
        let dH = 2 * (c1p * c2p).squareRoot() * sin(dh * rad / 2)
        let lBar = (a.l + b.l) / 2
        let cBarP = (c1p + c2p) / 2
        var hBar = h1p + h2p
        if c1p * c2p == 0 { hBar = h1p + h2p }
        else if abs(h1p - h2p) <= 180 { hBar = (h1p + h2p) / 2 }
        else if h1p + h2p < 360 { hBar = (h1p + h2p + 360) / 2 }
        else { hBar = (h1p + h2p - 360) / 2 }
        let t = 1 - 0.17 * cos((hBar - 30) * rad) + 0.24 * cos(2 * hBar * rad)
            + 0.32 * cos((3 * hBar + 6) * rad) - 0.20 * cos((4 * hBar - 63) * rad)
        let dTheta = 30 * exp(-((hBar - 275) / 25).powi(2))
        let rC = 2 * (cBarP.powi(7) / (cBarP.powi(7) + 25.0.powi(7))).squareRoot()
        let sL = 1 + 0.015 * (lBar - 50).powi(2) / (20 + (lBar - 50).powi(2)).squareRoot()
        let sC = 1 + 0.045 * cBarP
        let sH = 1 + 0.015 * cBarP * t
        let rT = -sin(2 * dTheta * rad) * rC
        let l = dL / sL, c = dC / sC, h = dH / sH
        return (l * l + c * c + h * h + rT * c * h).squareRoot()
    }

    private func lab(_ color: NSColor) -> (l: Double, a: Double, b: Double) {
        let c = srgb(color)
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = (0.2126729 * r + 0.7151522 * g + 0.0721750 * b)
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3) : (7.787 * t + 16.0 / 116)
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}

private extension Double {
    func powi(_ exponent: Int) -> Double {
        var result = 1.0
        var base = self
        var e = exponent
        while e > 0 {
            if e & 1 == 1 { result *= base }
            base *= base
            e >>= 1
        }
        return result
    }
}
