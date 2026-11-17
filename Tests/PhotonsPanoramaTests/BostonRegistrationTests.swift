import XCTest
import CoreImage
import ImageIO
@testable import PhotonsPanorama

/// Optional real-camera regression fixtures; never require private photos in CI.
final class BostonRegistrationTests: XCTestCase {
    func testBostonStripsAndConfirmedGroups() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTONS_BOSTON_DIR"] else {
            throw XCTSkip("Set PHOTONS_BOSTON_DIR to the external Boston RAW fixtures")
        }
        let root = URL(fileURLWithPath: path)
        let selected = ProcessInfo.processInfo.environment["PHOTONS_BOSTON_GROUP"]
        let groups = selected == "650" ? [650...658] : [628...633, 641...643, 644...646, 653...658, 659...662]
        for range in groups {
            if let selected, selected != String(range.lowerBound) { continue }
            try autoreleasepool {
                let urls = range.map { root.appendingPathComponent(String(format: "B%07d.3FR", $0)) }
                do {
                    let plan = try PanoramaEngine().analyze(urls: urls) { FileHandle.standardError.write(Data("BOSTON \(range.lowerBound) \($0)\n".utf8)) }
                    print("BOSTON RESULT", range.lowerBound, plan.origins, plan.registrationScores, plan.size)
                    XCTAssertEqual(plan.sources.count, range.count)
                    XCTAssertTrue(plan.registrationScores.allSatisfy { $0 > 0.7 })
                    let preview = try XCTUnwrap(plan.preview)
                    let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("photons-boston-\(range.lowerBound).png")
                    let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(dest, preview, nil)
                    XCTAssertTrue(CGImageDestinationFinalize(dest))
                } catch { XCTFail("Boston \(range): \(error)") }
            }
        }
    }
}
