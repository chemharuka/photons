import XCTest
@testable import HDRMergeCore

final class BitmapShiftTests: XCTestCase {
    func testShiftDirection() {
        var px = [UInt16](repeating: 0, count: 16 * 4)
        px[1 * 16 + 4] = 1000          // bright pixel at x=4,y=1
        let b = Bitmap(pixels: px, width: 16, height: 4, threshold: 500, exclusive: false)
        // shifted(dx,dy) moves content by (dx,dy): a pixel at x=4 goes to x=4+dx.
        for (d, expected) in [(-3, 1), (3, 7)] {
            let s = b.shifted(d, 0)
            var hits: [Int] = []
            for i in 0..<s.bits.count where s.bits[i] != 0 { hits.append(i % 16) }
            XCTAssertEqual(hits, [expected], "shifted(\(d),0)")
        }
    }
}
