import XCTest
@testable import PhotonsCore

/// 097 — the DNG `OpcodeList3 / WarpRectilinear` parser (pure data, no Metal).
final class LensProfileTests: XCTestCase {

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    /// The SL3 file: three planes with different `kr0`, big-endian payload under an `II` header, in a
    /// SubIFD. Every number below was read from `L1030433.dng` (exiftool agrees the opcode is
    /// WarpRectilinear).
    func testSL3FileHasThreeDistinctPlanesAndExactCoefficients() throws {
        let url = try fixtureURL()
        let profile = try XCTUnwrap(LensProfile.read(from: url))
        XCTAssertEqual(profile.planes.count, 3)
        XCTAssertTrue(profile.hasPerPlaneDifference)
        XCTAssertEqual(profile.centerX, 0.5, accuracy: 1e-12)
        XCTAssertEqual(profile.centerY, 0.5, accuracy: 1e-12)

        let expected = [1.00022744, 0.99991073, 0.99966989]
        for (plane, kr0) in zip(profile.planes, expected) {
            XCTAssertEqual(plane.kr0, kr0, accuracy: 1e-8)
            XCTAssertEqual(plane.kt0, 0, accuracy: 1e-12)
            XCTAssertEqual(plane.kt1, 0, accuracy: 1e-12)
        }
        // The first plane's own non-zero terms (095's numbers); the other planes differ.
        XCTAssertEqual(profile.planes[0].kr1, -0.007641494406453521, accuracy: 1e-8)
        XCTAssertEqual(profile.planes[0].kr2, -0.010054672900487066, accuracy: 1e-8)
        XCTAssertEqual(profile.planes[0].kr3, -0.0028838454462290714, accuracy: 1e-8)
        print("L1030433 planes: "
              + profile.planes.map {
                  String(format: "kr0=%.8f kr1=%.8f kr2=%.8f kr3=%.8f",
                         $0.kr0, $0.kr1, $0.kr2, $0.kr3)
              }.joined(separator: " | "))
        print("lens key: \(profile.recipeComponent)")
    }

    /// A TIFF with no OpcodeList3 (indeed no IFD entries at all) is `nil`, not a crash and not a
    /// guess. Written to a temp file so `read(from:)` exercises the real entry point.
    func testFileWithoutOpcodeList3IsNil() throws {
        var tiff = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]) // II, magic 42, IFD0 @8
        tiff.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])   // 0 entries, next IFD 0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lens-empty-\(UUID().uuidString).tiff")
        try tiff.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(LensProfile.read(from: url))
    }

    func testIdenticalPlanesHaveNoPerPlaneDifference() {
        let p = LensWarpPlane(kr0: 1.0002, kr1: -0.0076, kr2: -0.0100, kr3: -0.0028)
        let profile = LensProfile(planes: [p, p, p])
        XCTAssertFalse(profile.hasPerPlaneDifference)
        XCTAssertEqual(profile.recipeComponent, "lens=apple")

        var q = p
        let different = LensProfile(planes: [p, p, LensWarpPlane(kr0: q.kr0 + 1e-6,
                                                                 kr1: q.kr1, kr2: q.kr2, kr3: q.kr3)])
        XCTAssertTrue(different.hasPerPlaneDifference)
        XCTAssertTrue(different.recipeComponent.hasPrefix("lens=ours:"))

        q = p
        let withinTolerance = LensProfile(planes: [p, p, LensWarpPlane(kr0: q.kr0 + 1e-12,
                                                                       kr1: q.kr1, kr2: q.kr2, kr3: q.kr3)])
        XCTAssertFalse(withinTolerance.hasPerPlaneDifference)
    }
}
