import XCTest
import CoreImage
@testable import PhotonsCore

/// 「四轴可用性」的数据源：Apple 的逐实例 `isSupported`，不是版本前缀表 (owner, 2026-10-27).
///
/// Three claims, each one a number rather than a sentence:
///
///  1. **`capabilities.detailAxes` IS the filter's own flags.** For every version this file offers,
///     the value that travels with the pixels (`DecoderCapabilities.detailAxes`, provenance
///     `.filterFlags`) is compared **item by item** against the four `isSupported` booleans read
///     directly off a `CIRAWFilter` in this test — not through `DetailAxes.supported(by:)`, so the
///     assertion cannot pass by asking the same function twice. Bare `9` (not offered, reads back
///     `8`) must report **v8's** flags, which is what makes the read-back worth having.
///  2. **The veto did not change.** v9.dng still assigns 降噪 + 锐化 only (`detailApplied` has two
///     numbers and two `nil`s); v8 still assigns all four. That is the pixel-compatibility
///     requirement: the *source* of the flags changed, not the decision they produce.
///  3. **The UI and the veto read the same field.** `InspectorView.detailAxes(capabilities:…)` is the
///     capabilities value verbatim (the mirrored assertion lives in `DecoderModelCardTests`, which
///     hosts the card and reads SwiftUI's own `isEnabled`).
///
/// Why flags and not the pixel probe: one full-size axis probe costs 159–214 s per file per version
/// (≈ two hours for one photo's seven versions) and would have to run before the card can draw. The
/// pixel table in `DetailAxes`' doc comment is the evidence that the flags are not lying; these tests
/// are the evidence that the app reads them from the right place.
final class DetailAxesFlagTests: XCTestCase {

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

    private let probeScale: Float = 0.125

    /// The four flags, read here, from a fresh live filter — deliberately independent of the code
    /// under test.
    private func flagsFromApple(_ url: URL, requesting version: String)
        -> (effective: String, axes: DetailAxes, raw: String) {
        guard let filter = CIRAWFilter(imageURL: url) else {
            return ("<no filter>", .all, "no filter")
        }
        filter.decoderVersion = CIRAWDecoderVersion(rawValue: version)
        let effective = filter.decoderVersion.rawValue
        let nr = filter.isLuminanceNoiseReductionSupported
        let cnr = filter.isColorNoiseReductionSupported
        let detail = filter.isDetailSupported
        let sharp = filter.isSharpnessSupported
        return (effective,
                DetailAxes(nr: nr, cnr: cnr, detail: detail, sharpness: sharp,
                           moire: filter.isMoireReductionSupported),
                "isLuminanceNoiseReductionSupported=\(nr) isColorNoiseReductionSupported=\(cnr)"
                + " isDetailSupported=\(detail) isSharpnessSupported=\(sharp)")
    }

    // MARK: - 1. capabilities.detailAxes == Apple's flags, item for item

    func testEveryOfferedVersionCarriesTheFiltersOwnFlags() throws {
        let url = try fixtureURL()
        let offered = try RAWDecoder.availableVersions(for: url)
        let decoder = try RAWDecoder()

        print("AXES file \(url.lastPathComponent) offered \(offered.joined(separator: ","))")
        print("AXES requested  effective   provenance    capabilities.detailAxes"
              + "                        apple flags")

        var compared = 0
        for requested in offered {
            let caps = try decoder.decodeDetailed(url, options: DecodeOptions(decoderVersion: requested,
                                                                             scale: probeScale)).capabilities
            let apple = flagsFromApple(url, requesting: requested)
            print("AXES \(requested.padding(toLength: 10, withPad: " ", startingAt: 0))"
                  + " \(caps.effectiveVersion.padding(toLength: 11, withPad: " ", startingAt: 0))"
                  + " \(caps.detailAxesProvenance.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0))"
                  + " \(caps.detailAxes.flagSummary.padding(toLength: 48, withPad: " ", startingAt: 0))"
                  + " \(apple.raw)")

            XCTAssertEqual(caps.effectiveVersion, apple.effective,
                           "v\(requested): the read-back and this test's own filter must agree")
            XCTAssertEqual(caps.detailAxesProvenance, .filterFlags,
                           "a real decode must report Apple's flags, not the table")
            XCTAssertEqual(caps.detailAxes.nr, apple.axes.nr,
                           "v\(requested) nr: capabilities says \(caps.detailAxes.nr), Apple says \(apple.axes.nr)")
            XCTAssertEqual(caps.detailAxes.cnr, apple.axes.cnr,
                           "v\(requested) cnr: capabilities says \(caps.detailAxes.cnr), Apple says \(apple.axes.cnr)")
            XCTAssertEqual(caps.detailAxes.detail, apple.axes.detail,
                           "v\(requested) detail: capabilities says \(caps.detailAxes.detail), Apple says \(apple.axes.detail)")
            XCTAssertEqual(caps.detailAxes.sharpness, apple.axes.sharpness,
                           "v\(requested) sharpness: capabilities says \(caps.detailAxes.sharpness), Apple says \(apple.axes.sharpness)")
            compared += 1
        }
        XCTAssertEqual(compared, offered.count, "every offered spelling was compared")
        XCTAssertGreaterThanOrEqual(compared, 2)
    }

    /// The downgrade case: bare `9` is not offered by this file, the filter keeps v8, and the
    /// capabilities must then report **v8's** all-true flags — not v9's two dead axes.
    func testARefusedVersionReportsTheFlagsOfTheVersionThatRan() throws {
        let url = try fixtureURL()
        let offered = try RAWDecoder.availableVersions(for: url)
        guard let refused = DecoderCapabilities.knownVersions.first(where: { !offered.contains($0) }) else {
            throw XCTSkip("this file offers every known version")
        }
        let caps = try RAWDecoder().decodeDetailed(url, options: DecodeOptions(decoderVersion: refused,
                                                                              scale: probeScale)).capabilities
        let apple = flagsFromApple(url, requesting: refused)
        print("AXES refused v\(refused) → v\(caps.effectiveVersion) · caps \(caps.detailAxes.flagSummary)"
              + " · apple(effective v\(apple.effective)) \(apple.axes.flagSummary)")
        XCTAssertEqual(caps.effectiveVersion, apple.effective)
        XCTAssertEqual(caps.detailAxes, apple.axes,
                       "the flags must be the ones of the version that actually ran")
    }

    // MARK: - 2. the veto is unchanged (pixel-compatibility)

    /// v9.dng: 降噪 + 锐化 assigned, 色彩降噪 + 细节 withheld. v8: all four assigned. Read from
    /// `detailApplied`, i.e. from what the develop actually wrote, not from the table.
    func testTheVetoStillKeepsExactlyTwoAxesUnderV9AndFourUnderV8() throws {
        let url = try fixtureURL()
        let offered = try RAWDecoder.availableVersions(for: url)
        let decoder = try RAWDecoder()
        let loud = DetailSettings(luminanceNR: 100, colorNR: 100, sharpness: 100, detail: 100)

        if offered.contains("9.dng") {
            let v9 = try decoder.decodeDetailed(url, options: DecodeOptions(decoderVersion: "9.dng",
                                                                           scale: probeScale, detail: loud))
            print("AXES v9 axes \(v9.capabilities.detailAxes.flagSummary)"
                  + " applied \(v9.detailApplied.summary)")
            XCTAssertFalse(v9.capabilities.detailAxes.cnr)
            XCTAssertFalse(v9.capabilities.detailAxes.detail)
            XCTAssertNil(v9.detailApplied.colorNR, "v9 must not assign 色彩降噪")
            XCTAssertNil(v9.detailApplied.detail, "v9 must not assign 细节")
            XCTAssertNotNil(v9.detailApplied.luminanceNR, "v9 still assigns 降噪")
            XCTAssertNotNil(v9.detailApplied.sharpness, "v9 still assigns 锐化")
        }

        for version in ["8", "8.dng"] where offered.contains(version) {
            let out = try decoder.decodeDetailed(url, options: DecodeOptions(decoderVersion: version,
                                                                             scale: probeScale, detail: loud))
            print("AXES v\(version) axes \(out.capabilities.detailAxes.flagSummary)"
                  + " applied \(out.detailApplied.summary)")
            XCTAssertNotNil(out.detailApplied.luminanceNR, "v\(version) assigns 降噪")
            XCTAssertNotNil(out.detailApplied.colorNR, "v\(version) assigns 色彩降噪")
            XCTAssertNotNil(out.detailApplied.detail, "v\(version) assigns 细节")
            XCTAssertNotNil(out.detailApplied.sharpness, "v\(version) assigns 锐化")
        }
    }

    // MARK: - 3. the fallback still exists, and is labelled as such

    func testACapabilitiesWithoutAFilterFallsBackToTheVersionTable() {
        let v9 = DecoderCapabilities(requestedVersion: "9.dng", effectiveVersion: "9.dng", defaultVersion: "8")
        XCTAssertEqual(v9.detailAxesProvenance, .versionTable)
        XCTAssertEqual(v9.detailAxes, .v9)

        let v8 = DecoderCapabilities(requestedVersion: nil, effectiveVersion: "8", defaultVersion: "8")
        XCTAssertEqual(v8.detailAxesProvenance, .versionTable)
        XCTAssertEqual(v8.detailAxes, .all)

        // With flags, the table is not consulted at all — even when it would disagree.
        let lied: DetailAxes = .all
        let v9WithFlags = DecoderCapabilities(requestedVersion: "9.dng", effectiveVersion: "9.dng",
                                              defaultVersion: "8", detailAxes: lied)
        XCTAssertEqual(v9WithFlags.detailAxesProvenance, .filterFlags)
        XCTAssertEqual(v9WithFlags.detailAxes, .all,
                       "the flags win over the prefix, even when they are the surprising answer")
        XCTAssertTrue(v9WithFlags.supportsDetail, "the derived legacy flags follow detailAxes")
    }
}
