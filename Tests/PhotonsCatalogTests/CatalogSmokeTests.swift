import XCTest
@testable import PhotonsCatalog

/// Placeholder: the real catalog tests land with the import service.
final class CatalogSmokeTests: XCTestCase {
    func testSchemaVersionIsPinned() {
        // Pinned on purpose: bump both numbers *and* `Schema.steps` in the same change, so
        // `PRAGMA user_version` can never drift from the migrations that ran.
        XCTAssertEqual(Schema.version, 5)
        XCTAssertEqual(Schema.version, Schema.steps.count)
        XCTAssertEqual(Schema.uniqueHashVersion, 1)
    }
}
