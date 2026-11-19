import XCTest
import PhotonsCore

/// 436 A① — the pure rule behind `assets.width/height` being display pixels.
final class PixelUpright436Tests: XCTestCase {

    func testQuarterTurnsSwapTheAxes() {
        for orientation in [5, 6, 7, 8] {
            let out = PixelUpright.upright(width: 9520, height: 6336, orientation: orientation)
            XCTAssertEqual(out.width, 6336, "orientation \(orientation) width")
            XCTAssertEqual(out.height, 9520, "orientation \(orientation) height")
        }
    }

    func testNonTurningOrientationsKeepThePair() {
        for orientation in [1, 2, 3, 4, 9, 0, -1, 99] {
            let out = PixelUpright.upright(width: 9520, height: 6336, orientation: orientation)
            XCTAssertEqual(out.width, 9520, "orientation \(orientation) width")
            XCTAssertEqual(out.height, 6336, "orientation \(orientation) height")
        }
    }

    func testNilOrientationKeepsThePair() {
        let out = PixelUpright.upright(width: 9520, height: 6336, orientation: nil)
        XCTAssertEqual(out.width, 9520)
        XCTAssertEqual(out.height, 6336)
    }

    func testHalfKnownSizesDoNotCrash() {
        let noWidth = PixelUpright.upright(width: nil, height: 4000, orientation: 6)
        XCTAssertNil(noWidth.width)
        XCTAssertEqual(noWidth.height, 4000)

        let noHeight = PixelUpright.upright(width: 4000, height: nil, orientation: 8)
        XCTAssertEqual(noHeight.width, 4000)
        XCTAssertNil(noHeight.height)

        let neither = PixelUpright.upright(width: nil, height: nil, orientation: 6)
        XCTAssertNil(neither.width)
        XCTAssertNil(neither.height)
    }

    func testAlreadyUprightStoredPairIsUntouchedForOrientationOne() {
        let out = PixelUpright.upright(width: 6336, height: 9520, orientation: 1)
        XCTAssertEqual(out.width, 6336)
        XCTAssertEqual(out.height, 9520)
    }
}
