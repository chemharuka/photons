import XCTest
@testable import HDRMergeCore

final class PlaceholderTests: XCTestCase {
    func testTIFFRejectsGarbage() {
        XCTAssertThrowsError(try TIFFFile(data: Data([1, 2, 3, 4, 5, 6, 7, 8])))
    }
}
