import XCTest
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// Temporary probe (supervisor): does `LoupeFraming.zooming` keep the pixel under a view point at
/// rest, for both zoom in and zoom out, at all four corners and the middle?
final class AnchorProbeTests: XCTestCase {

    private func framing() -> LoupeFraming {
        LoupeFraming(viewport: ImageSize(width: 2404, height: 1600),
                     sourceWidth: 9520, sourceHeight: 6336,
                     crop: .full,
                     straightenDegrees: 0,
                     flipH: false, flipV: false)
    }

    func testWhereTheAnchorActuallyLands() {
        let f = framing()
        var start = LoupeViewState(mode: .actual, zoom: 1)
        start.centerX = 9520 / 2
        start.centerY = 6336 / 2
        let points: [CGPoint] = [
            CGPoint(x: 200, y: 200),     // top-left (flipped view: y down from top)
            CGPoint(x: 2200, y: 200),    // top-right
            CGPoint(x: 200, y: 1400),    // bottom-left
            CGPoint(x: 2200, y: 1400),   // bottom-right
            CGPoint(x: 1202, y: 800),    // middle
        ]
        for target in [2.0, 0.5, 1.0 / 3.0, 4.0] {
            for p in points {
                let next = f.zooming(start, to: target, aroundView: p, backingScale: 2)
                let before = f.sourcePoint(of: start, viewX: Double(p.x), viewY: Double(p.y), backingScale: 2)
                let after = f.sourcePoint(of: next, viewX: Double(p.x), viewY: Double(p.y), backingScale: 2)
                let landed = f.viewPoint(of: next, sourceX: before.x, sourceY: before.y, backingScale: 2)
                print("z1→\(target) p(\(Int(p.x)),\(Int(p.y))) srcBefore(\(Int(before.x)),\(Int(before.y))) srcAfter(\(Int(after.x)),\(Int(after.y))) Δsrc(\(Int(after.x - before.x)),\(Int(after.y - before.y))) landedView(\(Int(landed.x)),\(Int(landed.y)))")
            }
        }
    }
}
