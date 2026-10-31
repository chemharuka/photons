import XCTest
@testable import PhotonsCore
import PhotonsUI

final class LoupeFrameRequestTests: XCTestCase {

    private func makeRequest() -> LoupeFrameRequest {
        LoupeFrameRequest(identity: "L1030433",
                          documentHash: "hash-42",
                          revision: 7,
                          source: .decoded,
                          rungScale: 0.5,
                          contentRect: ImageRect(x: 10, y: 20, width: 800, height: 600),
                          canvas: ImageSize(width: 1600, height: 1200),
                          display: DisplayOptions(headroom: 1.5))
    }

    func testRenderOptionsMapFields() {
        let options = makeRequest().renderOptions()
        XCTAssertEqual(options.canvas, ImageSize(width: 1600, height: 1200))
        XCTAssertEqual(options.outputWindow, ImageRect(x: 10, y: 20, width: 800, height: 600))
        XCTAssertEqual(options.display.headroom, 1.5)
        XCTAssertEqual(options.source, .decoded)
        XCTAssertEqual(options.scale, 1)
        XCTAssertFalse(options.wantsPixels)
        XCTAssertTrue(options.useCache)
    }

    func testReceiptKeepsTheRequest() {
        let request = makeRequest()
        let receipt = LoupeFrameReceipt(request: request,
                                        canvas: ImageSize(width: 1600, height: 1200),
                                        photoRect: ImageRect(x: 0, y: 0, width: 1600, height: 1200),
                                        stages: ["S0", "S4"],
                                        milliseconds: 12.5)
        XCTAssertEqual(receipt.request, request)
        XCTAssertEqual(receipt.stages, ["S0", "S4"])
        XCTAssertEqual(receipt.milliseconds, 12.5)
    }
}
