import XCTest
@testable import PhotonsDepth

/// Scaffold-level assertions only (the dispatch session wrote these so the target has a test bundle).
/// The real coverage — inference size, cache key, dehaze assist, depth mask — belongs to task 120.
final class DepthModelTests: XCTestCase {
    func testRevisionIsPinnedToTheWeights() {
        // The cache key depends on this string naming the exact weight revision **and geometry**:
        // 2026-10-30 the shipped package became our own 1036×784 re-export, so a map computed by
        // the old 518 model must never be hit by the new one.
        XCTAssertTrue(DepthModel.revision.hasPrefix("dav2s-f16-1036x784@"),
                      "the cache key depends on this string naming the exact weight revision")
        XCTAssertTrue(DepthModel.revision.contains("00b3af8c"),
                      "the re-export's weight SHA prefix belongs in the revision")
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
