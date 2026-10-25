import XCTest
@testable import PhotonsCatalog

/// Placeholder: the real catalog tests land with the import service.
final class CatalogSmokeTests: XCTestCase {
    func testSchemaVersionIsPinned() {
        XCTAssertEqual(Schema.version, 1)
        XCTAssertEqual(Schema.uniqueHashVersion, 1)
    }
}
