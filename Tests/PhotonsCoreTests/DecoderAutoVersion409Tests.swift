import XCTest
import CoreImage
import ImageIO
@testable import PhotonsCore

/// 409 — 高 ISO 时默认解码版本自动升到 v9（按画幅归一化的阈值）.
///
/// 555 folded this rule into `DecoderVersionPreference`: the crop-factor / threshold helpers moved
/// there, `requestedVersion` / `availableV9` / `v9Spellings` are **gone**, and the repository has one
/// automatic-version entry point (`resolve(policy:preference:iso:cropFactor:stored:resolved:in:)`).
/// The cases below therefore assert the same 409 intentions through that one entry point:
///
///   1. `cropFactor` is `FocalLenIn35mmFilm / FocalLength` and nothing else.
///   2. the threshold is `800 / crop²`; the 555 table uses `≥` (409 used strict `>`).
///   3. the version offered is the file's own spelling, and 555 prefers **bare `9`** first.
///   4. a hand pick (`.v8` / `.v9`) is never second-guessed.
///   5. the resolved spelling enters the decode key; the recipe token still names the rule's
///      generation, so a constant change invalidates old buffers.
final class DecoderAutoVersion409Tests: XCTestCase {

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

    /// This machine's SL3 DNG, in the file's own order (`photonsctl` and `DecoderModelTests` pin it).
    private let sl3Offered = ["6.dng", "7", "7.dng", "8", "8.dng", "9.dng"]

    /// The one resolver, in its pure form.
    private func selected(iso: Int?, focalLength: Double?, focalLength35mm: Double?,
                          in available: [String],
                          preference: DecoderVersionPreference.Preference = .auto)
        -> String? {
        let crop = DecoderVersionPreference.cropFactor(orFullFrame: focalLength, focalLength35mm)
        return DecoderVersionPreference.resolve(
            policy: .auto, preference: preference, iso: iso, cropFactor: crop,
            stored: nil, resolved: nil, in: available) { $0 }.selected
    }

    // MARK: - A. cropFactor (4)

    func testCropFactorFromTheTwoFocalLengths() {
        XCTAssertEqual(DecoderVersionPreference.cropFactor(focalLength: 25, focalLength35mm: 50), 2.0)
        XCTAssertEqual(DecoderVersionPreference.cropFactor(focalLength: 50, focalLength35mm: 50), 1.0)
    }

    func testCropFactorIsNilWhenEitherFocalLengthIsUnreadable() {
        XCTAssertNil(DecoderVersionPreference.cropFactor(focalLength: nil, focalLength35mm: 50))
        XCTAssertNil(DecoderVersionPreference.cropFactor(focalLength: 50, focalLength35mm: nil))
        XCTAssertNil(DecoderVersionPreference.cropFactor(focalLength: 0, focalLength35mm: 50))
        XCTAssertNil(DecoderVersionPreference.cropFactor(focalLength: 50, focalLength35mm: 0))
        XCTAssertNil(DecoderVersionPreference.cropFactor(focalLength: nil, focalLength35mm: nil))
    }

    func testCropFactorRejectsAnImplausibleRatio() {
        XCTAssertNil(DecoderVersionPreference.cropFactor(focalLength: 25, focalLength35mm: 200))
        XCTAssertEqual(DecoderVersionPreference.cropFactor(orFullFrame: 25, 200),
                       DecoderVersionPreference.assumedCropFactor)
        XCTAssertEqual(DecoderVersionPreference.cropFactor(orFullFrame: nil, nil), 1.0)
    }

    // MARK: - B. the threshold (2 + boundary)

    func testThresholdISOIsTheFullFrame800NormalisedByCropSquared() {
        XCTAssertEqual(DecoderVersionPreference.thresholdISO(crop: 1.0), 800, accuracy: 1e-9)
        XCTAssertEqual(DecoderVersionPreference.thresholdISO(crop: 2.0), 200, accuracy: 1e-9,
                       "m4/3 — the user's own number")
        XCTAssertEqual(DecoderVersionPreference.thresholdISO(crop: 0.79), 1281.84, accuracy: 0.01,
                       "medium format 44×33 at the brief's rounded crop 0.79")
        let mediumDiag: Double = (44.0 * 44.0 + 33.0 * 33.0).squareRoot()
        let fullDiag: Double = (36.0 * 36.0 + 24.0 * 24.0).squareRoot()
        let mediumFormat: Double = fullDiag / mediumDiag
        XCTAssertEqual(DecoderVersionPreference.thresholdISO(crop: mediumFormat), 1293,
                       accuracy: 1.0)
        XCTAssertEqual(mediumFormat, 0.79, accuracy: 0.01, "the brief's rounded crop")
        XCTAssertEqual(DecoderVersionPreference.thresholdISO(crop: 1.53), 341.75, accuracy: 0.01,
                       "APS-C 23.5×15.6 (the brief's table rounds to 340)")
        XCTAssertEqual(DecoderVersionPreference.thresholdISO(crop: 2.73), 107.34, accuracy: 0.01,
                       "1-inch 13.2×8.8")
        XCTAssertEqual(DecoderVersionPreference.thresholdISO(crop: 0), 800)
    }

    /// 555 changed 409's strict `>` to `≥`: an actual ISO exactly at the threshold now upgrades.
    func testTheComparisonIncludesTheBoundary() {
        XCTAssertTrue(DecoderVersionPreference.shouldUpgrade(iso: 800, crop: 1.0))
        XCTAssertTrue(DecoderVersionPreference.shouldUpgrade(iso: 801, crop: 1.0))
        XCTAssertTrue(DecoderVersionPreference.shouldUpgrade(iso: 200, crop: 2.0))
        XCTAssertTrue(DecoderVersionPreference.shouldUpgrade(iso: 201, crop: 2.0))
        XCTAssertFalse(DecoderVersionPreference.shouldUpgrade(iso: 799, crop: 1.0))
        XCTAssertFalse(DecoderVersionPreference.shouldUpgrade(iso: 199, crop: 2.0))
        XCTAssertFalse(DecoderVersionPreference.shouldUpgrade(iso: nil, crop: 1.0))
        XCTAssertEqual(DecoderVersionPreference.cropFactor(orFullFrame: nil, nil), 1.0)
        XCTAssertTrue(DecoderVersionPreference.shouldUpgrade(iso: 800,
            crop: DecoderVersionPreference.cropFactor(orFullFrame: nil, nil)))
    }

    // MARK: - C. picking the spelling (4)

    func testTheSl3ListPicksDngNineWhenBareNineIsNotOffered() {
        XCTAssertEqual(selected(iso: 6400, focalLength: 50, focalLength35mm: 50,
                                in: sl3Offered), "9.dng")
    }

    /// 555's first behaviour change: bare `9` is now the first candidate (554 measured that this
    /// machine accepts it, and its pixels differ from `9.dng`).
    func testABodyThatOffersBareNineGetsBareNine() {
        XCTAssertEqual(selected(iso: 6400, focalLength: 25, focalLength35mm: 50,
                                in: ["8", "9"]), "9")
        XCTAssertEqual(selected(iso: 6400, focalLength: 25, focalLength35mm: 50,
                                in: ["9", "9.dng", "8", "8.dng"]), "9")
    }

    func testWithoutV9TheAutomaticChoiceStaysOnTheClassicFamily() {
        XCTAssertEqual(selected(iso: 6400, focalLength: 50, focalLength35mm: 50,
                                in: ["8"]), "8",
                       "no v9 ⇒ 8, the same pixels as Apple's default")
        // …and a low-ISO file stays on 8 too.
        XCTAssertEqual(selected(iso: 100, focalLength: 50, focalLength35mm: 50,
                                in: sl3Offered), "8")
    }

    func testAHandPickIsNeverSecondGuessedByTheSetting() {
        for preference in DecoderVersionPreference.Preference.allCases {
            for iso in [100, 800, 6400] {
                XCTAssertEqual(
                    DecoderVersionPreference.resolve(
                        policy: .v8, preference: preference, iso: iso,
                        stored: "8", in: sl3Offered) { $0 }.selected,
                    "8", "手选 v8 · \(preference.rawValue) · iso \(iso)")
            }
        }
        // The API-level exact request is still assigned verbatim by the decoder (D2′ read-back);
        // that contract lives in `DecodeContractTests`.
    }

    // MARK: - D. the decode key (1) and the rule/recipe pin (1)

    func testAnExplicitVersionKeepsThePreChangeKey() {
        let v8 = DecodeInputs(decoderVersion: "8")
        XCTAssertEqual(v8.versionComponent, "ver=8")
        XCTAssertEqual(v8.key, "recipe=\(DecodeRecipe.current);ver=8;scale=1.0000")
        XCTAssertEqual(v8.appending(to: "photo"), "photo|ver=8")

        var d = EditModel.neutral
        d.decoderVersion = "9.dng"
        XCTAssertEqual(d.decodeInputs.key,
                       "recipe=\(DecodeRecipe.current);ver=9.dng;scale=1.0000",
                       "a document that asks explicitly is unchanged by 409/555")
        XCTAssertNil(EditModel.neutral.decodeInputs.versionComponent,
                     "an unresolved automatic document still asks for nothing")
    }

    func testTheRuleConstantsAndTheRecipeTokenArePinnedTogether() {
        XCTAssertEqual(DecoderVersionPreference.highISOThreshold, 800,
                       "改规则常量必须 bump DecodeRecipe.current")
        XCTAssertEqual(DecoderVersionPreference.cropRange, 0.5...4.0,
                       "改规则常量必须 bump DecodeRecipe.current")
        XCTAssertEqual(DecoderVersionPreference.thresholdISO(crop: 1), 800,
                       "改规则常量必须 bump DecodeRecipe.current")
        XCTAssertEqual(DecodeRecipe.current, "v5-policy555",
                       "改规则常量必须 bump DecodeRecipe.current")
    }

    // MARK: - E. the EXIF reader the decode path uses (synthetic, no RAW)

    func testTheDecodePathReadsTheThreeExifFacts() {
        let dng: [String: Any] = [
            kCGImagePropertyExifFocalLength as String: NSNumber(value: 50),
            kCGImagePropertyExifFocalLenIn35mmFilm as String: NSNumber(value: 50),
            kCGImagePropertyExifISOSpeedRatings as String: [NSNumber(value: 100)],
        ]
        let facts = RAWDecoder.exifFacts(fromExif: dng)
        XCTAssertEqual(facts.focalLength, 50)
        XCTAssertEqual(facts.focalLength35mm, 50)
        XCTAssertEqual(facts.iso, 100)
        XCTAssertEqual(DecoderVersionPreference.cropFactor(focalLength: facts.focalLength,
                                                           focalLength35mm: facts.focalLength35mm),
                       1.0)

        let bare: [String: Any] = [
            kCGImagePropertyExifFocalLength as String: NSNumber(value: 25),
            kCGImagePropertyExifFocalLenIn35mmFilm as String: NSNumber(value: 50),
            kCGImagePropertyExifISOSpeedRatings as String: NSNumber(value: 3200),
        ]
        let bareFacts = RAWDecoder.exifFacts(fromExif: bare)
        XCTAssertEqual(bareFacts.iso, 3200)
        XCTAssertEqual(DecoderVersionPreference.cropFactor(focalLength: bareFacts.focalLength,
                                                           focalLength35mm: bareFacts.focalLength35mm),
                       2.0)
        XCTAssertEqual(selected(iso: bareFacts.iso, focalLength: bareFacts.focalLength,
                                focalLength35mm: bareFacts.focalLength35mm,
                                in: sl3Offered), "9.dng")

        let empty = RAWDecoder.exifFacts(fromExif: [:])
        XCTAssertNil(empty.iso)
        XCTAssertNil(empty.focalLength)
        XCTAssertNil(empty.focalLength35mm)
    }

    // MARK: - F. the real file: the rule does not fire on an ISO 100 full-frame photo

    func testTheLowIsoFullFrameFixtureKeepsTodaysDecode() throws {
        let url = try fixtureURL()
        let decoder = try RAWDecoder()
        let probe = try decoder.probe(url)
        let exif = try XCTUnwrap(probe.iso)
        let crop = DecoderVersionPreference.cropFactor(orFullFrame: 50, 50)
        print("409 fixture: offered \(probe.supportedVersions) · iso \(exif) · crop \(crop)"
            + " · threshold \(DecoderVersionPreference.thresholdISO(crop: crop))")

        XCTAssertFalse(DecoderVersionPreference.shouldUpgrade(iso: exif, crop: crop),
                       "ISO \(exif) must not cross the full-frame threshold")
        XCTAssertEqual(probe.autoVersion, "8",
                       "555: 自动 asks for the classic spelling explicitly, not nil")

        let outcome = try decoder.decodeDetailed(url, options: DecodeOptions(scale: 0.2))
        XCTAssertEqual(outcome.capabilities.requestedVersion, "8",
                       "the resolver names 8 for a low-ISO classic file")
        XCTAssertFalse(outcome.capabilities.downgraded)
        XCTAssertEqual(outcome.capabilities.effectiveVersion, outcome.capabilities.defaultVersion,
                       "the default document still runs Apple's default")
        XCTAssertEqual(outcome.image.decoderVersion, outcome.capabilities.defaultVersion)

        // …and the measurement decode (black level / goldens) is never auto-upgraded either.
        let measured = try decoder.decodeForMeasurement(url, scale: 0.2)
        XCTAssertEqual(measured.decoderVersion, outcome.capabilities.defaultVersion)
    }

    // MARK: - G. 425: the automatic answer travels in `DecoderCapabilities.autoVersion`

    private func highISOFixtureURL() throws -> URL {
        let path = NSString(string: "~/Desktop/test/L1030437.dng").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no L1030437.dng (the ISO 3200 frame); 425's A② needs it")
        }
        return URL(fileURLWithPath: path)
    }

    func testCapabilitiesAutoVersionEqualsTheProbeAndFollowsTheRule() throws {
        let decoder = try RAWDecoder()
        let cases: [(url: URL, iso: Int?, auto: String?)] = [
            // 555's first behaviour change: this body lists bare `9`, and the resolver now prefers
            // it over `9.dng` (554 measured both are accepted and produce different pixels).
            (try highISOFixtureURL(), 3200, "9"),
            (try fixtureURL(), 100, "8"),
        ]
        for c in cases {
            let probe = try decoder.probe(c.url)
            let caps = try decoder.decodeDetailed(c.url, options: DecodeOptions(scale: 0.2)).capabilities
            print("425 \(c.url.lastPathComponent) iso \(String(describing: probe.iso))"
                  + " · probe.autoVersion \(String(describing: probe.autoVersion))"
                  + " · capabilities.autoVersion \(String(describing: caps.autoVersion))"
                  + " · effective v\(caps.effectiveVersion)")

            if let expectedISO = c.iso {
                XCTAssertEqual(probe.iso, expectedISO, "the fixture's ISO is the one the rule keys on")
            }
            XCTAssertEqual(caps.autoVersion, probe.autoVersion,
                           "the same file must not answer twice")
            XCTAssertEqual(caps.autoVersion, c.auto)
        }
    }

    func testAutoVersionIgnoresTheDocumentsOwnRequest() throws {
        let url = try highISOFixtureURL()
        let auto = try RAWDecoder().decodeDetailed(url, options: DecodeOptions(scale: 0.2)).capabilities
        let explicit = try RAWDecoder().decodeDetailed(url, options: DecodeOptions(decoderVersion: "8",
                                                                                   scale: 0.2)).capabilities
        print("425 explicit v8 on the high-ISO file · requested \(String(describing: explicit.requestedVersion))"
              + " · auto \(String(describing: explicit.autoVersion)) · effective v\(explicit.effectiveVersion)")

        XCTAssertEqual(explicit.requestedVersion, "8", "the document's pick is what this decode requested")
        XCTAssertEqual(explicit.effectiveVersion, "8", "…and it ran")
        XCTAssertEqual(explicit.autoVersion, auto.autoVersion,
                       "`autoVersion` keeps answering for a document that asks for nothing")
        XCTAssertEqual(explicit.autoVersion, "9",
                       "bare 9 is offered by this body, and 555 prefers it")
    }
}
