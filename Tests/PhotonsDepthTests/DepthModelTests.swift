import XCTest
@testable import PhotonsDepth

/// Scaffold-level assertions only (the dispatch session wrote these so the target has a test bundle).
/// The real coverage — inference size, cache key, dehaze assist, depth mask — belongs to task 120.
final class DepthModelTests: XCTestCase {
    func testRevisionIsPinnedToTheWeights() {
        XCTAssertTrue(DepthModel.revision.hasPrefix("dav2s-f16@"),
                      "the cache key depends on this string naming the exact weight revision")
        XCTAssertTrue(DepthModel.revision.contains("cfef6f6"),
                      "the upstream weight SHA prefix belongs in the revision")
    }

    func testAnAppWithoutTheCompiledModelReportsItByName() {
        // The xctest bundle carries no `.mlmodelc`: this is the "shipped without weights" path, and it
        // must be a named error rather than a crash or a silent identity depth map.
        XCTAssertThrowsError(try DepthModel(bundle: Bundle.main)) { error in
            guard case DepthError.modelMissing = error else {
                return XCTFail("expected .modelMissing, got \(error)")
            }
        }
    }
}
