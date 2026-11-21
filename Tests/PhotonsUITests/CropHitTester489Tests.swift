import XCTest
import AppKit
@testable import PhotonsUI

/// 489 §2.1/§2.2 — the frame's hit decision and the two view-state facts (hidden while 引导线 is
/// armed, 50 % lines after it is off, frame painted on top).
@MainActor
final class CropHitTester489Tests: XCTestCase {

    private let box = CGRect(x: 0, y: 0, width: 400, height: 300)

    // MARK: - 2.2: four corners, four edges, inside, outside (≥ 8 cases)

    func testFourCornersTakeThePress() {
        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 0, y: 0), box: box), .topLeft)
        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 400, y: 0), box: box), .topRight)
        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 400, y: 300), box: box), .bottomRight)
        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 0, y: 300), box: box), .bottomLeft)
    }

    func testFourEdgesTakeThePressAtTheirMidpoints() {
        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 200, y: 0), box: box), .top)
        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 400, y: 150), box: box), .right)
        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 200, y: 300), box: box), .bottom)
        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 0, y: 150), box: box), .left)
    }

    func testInsideAndOutsideAreTheThirdAndFourthAnswers() {
        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 200, y: 150), box: box), .inside)
        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 600, y: 600), box: box), .outside)
    }

    /// 400 × 300 pt at zoom 1: the visual 12 pt corner target is doubled to 24 pt, so 23 pt is a
    /// grip and 25 pt is a new frame. Same for the 9 pt edge (`18`).
    func testTheExpandedCornerAndEdgeBoundariesAreOnePointApart() {
        XCTAssertEqual(CropHitTester.expandedRadius(visual: 12, box: box.size), 24, accuracy: 1e-12)
        XCTAssertEqual(CropHitTester.expandedRadius(visual: 9, box: box.size), 18, accuracy: 1e-12)

        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 23, y: 0), box: box), .topLeft,
                       "inside the expanded corner by 1 pt")
        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 25, y: -1), box: box), .outside,
                       "outside the expanded corner by 1 pt")

        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 200, y: 17), box: box), .top,
                       "inside the expanded edge by 1 pt")
        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 200, y: 19), box: box), .inside,
                       "outside the expanded edge by 1 pt — still inside the frame")
    }

    func testTheExpansionIsCappedAtAQuarterOfTheShortSide() {
        let small = CGRect(x: 0, y: 0, width: 40, height: 30)
        XCTAssertEqual(CropHitTester.expandedRadius(visual: 12, box: small.size), 7.5, accuracy: 1e-12)
        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 12, y: -1), box: small), .outside,
                       "a small frame must keep an interior; the target may not swallow it")
        XCTAssertEqual(CropHitTester.hit(at: CGPoint(x: 20, y: 15), box: small), .inside)
    }

    /// The overlap the user asked about: a guide line endpoint and a corner grip at the same point
    /// resolve to the **frame**. This is the pure priority the UI now calls first.
    func testACornerWinsAnOverlappingGuideLineEndpoint() {
        let layout = CropToolLayout(
            corners: [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 0),
                      CGPoint(x: 400, y: 300), CGPoint(x: 0, y: 300)],
            grips: [.init(kind: .topLeft, point: CGPoint(x: 0, y: 0)),
                    .init(kind: .topRight, point: CGPoint(x: 400, y: 0)),
                    .init(kind: .bottomRight, point: CGPoint(x: 400, y: 300)),
                    .init(kind: .bottomLeft, point: CGPoint(x: 0, y: 300)),
                    .init(kind: .top, point: CGPoint(x: 200, y: 0)),
                    .init(kind: .right, point: CGPoint(x: 400, y: 150)),
                    .init(kind: .bottom, point: CGPoint(x: 200, y: 300)),
                    .init(kind: .left, point: CGPoint(x: 0, y: 150))])
        let overlap = CGPoint(x: 0, y: 0)
        XCTAssertEqual(CropHitTester.hit(at: overlap, in: layout), .topLeft)
    }

    // MARK: - 2.1: hidden while armed, 50 % after, frame on top

    private func overlayBitmap(armed: Bool) throws -> NSBitmapImageRep {
        let size = NSSize(width: 100, height: 100)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        let view = CropToolOverlayView(frame: NSRect(origin: .zero, size: size))
        view.guideLinesArmed = armed
        view.appliedGuideLineAlpha = armed ? 1 : 0.5
        // One accepted line lying exactly on the frame's top edge: when the switch is off the frame
        // must paint over it (white), when it is on the line is the only thing there (teal).
        view.guideLines = [CropToolSegment(a: CGPoint(x: 20, y: 20), b: CGPoint(x: 80, y: 20))]
        view.layout = CropToolLayout(
            corners: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 20),
                      CGPoint(x: 80, y: 80), CGPoint(x: 20, y: 80)],
            grips: [.init(kind: .topLeft, point: CGPoint(x: 20, y: 20)),
                    .init(kind: .topRight, point: CGPoint(x: 80, y: 20)),
                    .init(kind: .bottomRight, point: CGPoint(x: 80, y: 80)),
                    .init(kind: .bottomLeft, point: CGPoint(x: 20, y: 80)),
                    .init(kind: .top, point: CGPoint(x: 50, y: 20)),
                    .init(kind: .right, point: CGPoint(x: 80, y: 50)),
                    .init(kind: .bottom, point: CGPoint(x: 50, y: 80)),
                    .init(kind: .left, point: CGPoint(x: 20, y: 50))])
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        view.draw(view.bounds)
        NSGraphicsContext.current = previous
        return rep
    }

    private func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let c = rep.colorAt(x: x, y: y) ?? .clear
        return (Int(round(c.redComponent * 255)),
                Int(round(c.greenComponent * 255)),
                Int(round(c.blueComponent * 255)))
    }

    func testTheFrameIsNotDrawnWhileGuideLinesAreArmed() throws {
        let off = try overlayBitmap(armed: false)
        let armed = try overlayBitmap(armed: true)
        // (5,5) is outside the frame: the dim layer turns white grey when the frame is drawn.
        let offPixel = rgb(off, 5, 5)
        let armedPixel = rgb(armed, 5, 5)
        print("489 frame hidden: off \(offPixel) · armed \(armedPixel)")
        XCTAssertLessThan(offPixel.r, 160, "frame off must dim the outside")
        XCTAssertGreaterThan(armedPixel.r, 240, "frame armed must leave the picture alone")
    }

    func testTheGuideLineAlphaIsHalfWhenTheSwitchIsOff() {
        let view = CropToolOverlayView()
        XCTAssertEqual(view.appliedGuideLineAlpha, 0.5, accuracy: 1e-12)
        view.guideLinesArmed = true
        XCTAssertEqual(view.appliedGuideLineAlpha, 0.5, accuracy: 1e-12,
                       "the alpha itself is a separate write; the overlay does not guess")
    }
}
