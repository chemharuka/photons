import XCTest
import CoreImage
import ImageIO
@testable import PhotonsCore

/// 409 — 高 ISO 时默认解码版本自动升到 v9（按画幅归一化的阈值）.
///
/// The rule is three pure functions in `DecoderAutoVersion` plus one read-back in the decode path, so
/// everything except the last section is testable with **synthetic inputs**: this machine has no
/// m4/3, no APS-C and no file above ISO 100, and the acceptance must not depend on a photo the user
/// has not shot yet.
///
/// What is pinned here:
///
///   1. `cropFactor` is `FocalLenIn35mmFilm / FocalLength` and **nothing else** — unreadable EXIF is
///      full frame (`nil`), not a guessed body.
///   2. the threshold is `800 / crop²`, reproducing both anchors the user gave (full frame 800,
///      m4/3 200), and 「大于 800」 is strictly greater.
///   3. the version offered is the file's own spelling, `9.dng` first — bare `9` on the SL3 silently
///      reads back v8 (`DecoderCapabilities.swift:7-11`).
///   4. an explicit document choice is never second-guessed.
///   5. the automatic rule does **not** enter the decode key: a document that asks for nothing is
///      always spelled `ver=auto`, and the rule's generation — the only thing that has to invalidate
///      old buffers when a constant moves — is carried by `DecodeRecipe.current`. An explicit choice
///      therefore keeps the pre-409 key byte for byte.
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

    // MARK: - A. cropFactor (4)

    func testCropFactorFromTheTwoFocalLengths() {
        // m4/3: a 25 mm lens is a 50 mm equivalent.
        XCTAssertEqual(DecoderAutoVersion.cropFactor(focalLength: 25, focalLength35mm: 50), 2.0)
        // This machine's SL3 file: 50 mm physical, 50 mm equivalent ⇒ full frame.
        XCTAssertEqual(DecoderAutoVersion.cropFactor(focalLength: 50, focalLength35mm: 50), 1.0)
    }

    func testCropFactorIsNilWhenEitherFocalLengthIsUnreadable() {
        XCTAssertNil(DecoderAutoVersion.cropFactor(focalLength: nil, focalLength35mm: 50))
        XCTAssertNil(DecoderAutoVersion.cropFactor(focalLength: 50, focalLength35mm: nil))
        XCTAssertNil(DecoderAutoVersion.cropFactor(focalLength: 0, focalLength35mm: 50))
        XCTAssertNil(DecoderAutoVersion.cropFactor(focalLength: 50, focalLength35mm: 0))
        XCTAssertNil(DecoderAutoVersion.cropFactor(focalLength: nil, focalLength35mm: nil))
    }

    func testCropFactorRejectsAnImplausibleRatio() {
        // 25 mm physical / "200 mm equivalent" = 8.0 — no still format we know, so the EXIF pair is
        // untrustworthy. The brief forbids widening the range to catch more high-ISO files.
        XCTAssertNil(DecoderAutoVersion.cropFactor(focalLength: 25, focalLength35mm: 200))
        // …and the same file is then decoded as full frame, which is the user's stated fallback.
        XCTAssertEqual(DecoderAutoVersion.cropFactor(orFullFrame: 25, 200),
                       DecoderAutoVersion.assumedCropFactor)
        XCTAssertEqual(DecoderAutoVersion.cropFactor(orFullFrame: nil, nil), 1.0)
    }

    // MARK: - B. the threshold (2 + boundary)

    func testThresholdISOIsTheFullFrame800NormalisedByCropSquared() {
        // The table the brief proves the formula with. ISO_equiv = ISO_actual · crop², so the upgrade
        // point is 800 / crop².
        XCTAssertEqual(DecoderAutoVersion.thresholdISO(crop: 1.0), 800, accuracy: 1e-9)
        XCTAssertEqual(DecoderAutoVersion.thresholdISO(crop: 2.0), 200, accuracy: 1e-9,
                       "m4/3 — the user's own number")
        XCTAssertEqual(DecoderAutoVersion.thresholdISO(crop: 0.79), 1281.84, accuracy: 0.01,
                       "medium format 44×33 at the brief's rounded crop 0.79")
        // The exact 44×33 / 36×24 diagonal ratio the brief's 1293 came from: crop = full-frame
        // diagonal / sensor diagonal (√(36²+24²) / √(44²+33²) = 0.7867 ⇒ 800 / 0.7867² = 1293).
        let mediumDiag: Double = (44.0 * 44.0 + 33.0 * 33.0).squareRoot()
        let fullDiag: Double = (36.0 * 36.0 + 24.0 * 24.0).squareRoot()
        let mediumFormat: Double = fullDiag / mediumDiag
        XCTAssertEqual(DecoderAutoVersion.thresholdISO(crop: mediumFormat), 1293, accuracy: 1.0)
        XCTAssertEqual(mediumFormat, 0.79, accuracy: 0.01, "the brief's rounded crop")
        XCTAssertEqual(DecoderAutoVersion.thresholdISO(crop: 1.53), 341.75, accuracy: 0.01,
                       "APS-C 23.5×15.6 (the brief's table rounds to 340)")
        XCTAssertEqual(DecoderAutoVersion.thresholdISO(crop: 2.73), 107.34, accuracy: 0.01,
                       "1-inch 13.2×8.8")
        // A broken crop is a broken input, not a format: answer the full-frame number, never ∞.
        XCTAssertEqual(DecoderAutoVersion.thresholdISO(crop: 0), 800)
    }

    func testTheComparisonIsStrictlyGreater() {
        // 「ISO 大于 800」 — at exactly the threshold nothing upgrades.
        XCTAssertFalse(DecoderAutoVersion.shouldUpgrade(iso: 800, crop: 1.0))
        XCTAssertTrue(DecoderAutoVersion.shouldUpgrade(iso: 801, crop: 1.0))
        XCTAssertFalse(DecoderAutoVersion.shouldUpgrade(iso: 200, crop: 2.0))
        XCTAssertTrue(DecoderAutoVersion.shouldUpgrade(iso: 201, crop: 2.0))
        // No ISO reading is a "no": we cannot prove the file is noisy, so nothing upgrades.
        XCTAssertFalse(DecoderAutoVersion.shouldUpgrade(iso: nil, crop: 1.0))
        // Unreadable crop defaults to full frame, which is the 800 threshold.
        XCTAssertEqual(DecoderAutoVersion.cropFactor(orFullFrame: nil, nil), 1.0)
        XCTAssertFalse(DecoderAutoVersion.shouldUpgrade(iso: 800,
                                                        crop: DecoderAutoVersion.cropFactor(orFullFrame: nil, nil)))
        XCTAssertTrue(DecoderAutoVersion.shouldUpgrade(iso: 801,
                                                       crop: DecoderAutoVersion.cropFactor(orFullFrame: nil, nil)))
    }

    // MARK: - C. picking the spelling (4)

    func testTheSl3ListPicksDngNineNotBareNine() {
        // bare `9` is **not** in this list: assigning it reads back v8 with no error.
        XCTAssertEqual(DecoderAutoVersion.availableV9(in: sl3Offered), "9.dng")
        XCTAssertEqual(DecoderAutoVersion.requestedVersion(explicit: nil, iso: 6400,
                                                           focalLength: 50, focalLength35mm: 50,
                                                           offered: sl3Offered),
                       "9.dng")
    }

    func testABodyThatOffersOnlyBareNineGetsBareNine() {
        XCTAssertEqual(DecoderAutoVersion.availableV9(in: ["8", "9"]), "9")
        XCTAssertEqual(DecoderAutoVersion.requestedVersion(explicit: nil, iso: 6400,
                                                           focalLength: 25, focalLength35mm: 50,
                                                           offered: ["8", "9"]),
                       "9")
    }

    func testWithoutV9TheDocumentStaysOnTheDefault() {
        XCTAssertNil(DecoderAutoVersion.availableV9(in: ["8"]))
        XCTAssertNil(DecoderAutoVersion.requestedVersion(explicit: nil, iso: 6400,
                                                         focalLength: 50, focalLength35mm: 50,
                                                         offered: ["8"]),
                     "no v9 ⇒ nil ⇒ Apple's default (v8) exactly as before 409")
        // …and a low-ISO file on a v9-capable body also stays on the default.
        XCTAssertNil(DecoderAutoVersion.requestedVersion(explicit: nil, iso: 100,
                                                         focalLength: 50, focalLength35mm: 50,
                                                         offered: sl3Offered))
    }

    func testAnExplicitDocumentChoiceIsNeverSecondGuessed() {
        XCTAssertEqual(DecoderAutoVersion.requestedVersion(explicit: "8", iso: 6400,
                                                           focalLength: 25, focalLength35mm: 50,
                                                           offered: sl3Offered),
                       "8", "the user's own choice wins over the rule")
        // Even a spelling this file does not offer is passed through verbatim: the decoder's read-back
        // is what reports the fallback (`已退回 v8`), not this rule.
        XCTAssertEqual(DecoderAutoVersion.requestedVersion(explicit: "9", iso: 6400,
                                                           focalLength: 25, focalLength35mm: 50,
                                                           offered: sl3Offered),
                       "9")
    }

    // MARK: - D. the decode key (1) and the rule/recipe pin (1)

    func testAnExplicitVersionKeepsThePreChangeKey() {
        // The pre-409 spelling, verbatim: an explicit document choice is unchanged and its buffers
        // must keep hitting.
        let v8 = DecodeInputs(decoderVersion: "8")
        XCTAssertEqual(v8.versionComponent, "ver=8")
        XCTAssertEqual(v8.key, "recipe=\(DecodeRecipe.current);ver=8;scale=1.0000")
        XCTAssertEqual(v8.appending(to: "photo"), "photo|ver=8")

        let v9 = EditModel.neutral
        var d = v9
        d.decoderVersion = "9.dng"
        XCTAssertEqual(d.decodeInputs.key,
                       "recipe=\(DecodeRecipe.current);ver=9.dng;scale=1.0000",
                       "a document that asks explicitly is unchanged by 409")
        XCTAssertNil(EditModel.neutral.decodeInputs.versionComponent,
                     "the default document still asks for nothing")
    }

    // MARK: - D2. the real invariant: nothing to ask for appends nothing

    /// The one property 405's neutral fingerprint rests on, asserted here because this lane predates
    /// 405: a document that asks for no version must append **no** version segment, and no `auto:`-style
    /// spelling may exist anywhere (the 409 mechanism that produced one is gone).
    func testADocumentThatAsksForNothingAppendsNoVersion() {
        let nothing = DecodeInputs()
        XCTAssertNil(nothing.versionComponent,
                     "decoderVersion == nil must append no version segment — 405's neutral fingerprint "
                     + "is byte-identical only because of this")
        XCTAssertEqual(nothing.key, "recipe=\(DecodeRecipe.current);ver=auto;scale=1.0000",
                       "`ver=auto` is the literal, with no colon suffix")
        XCTAssertEqual(nothing.appending(to: "photo"), "photo")

        let explicit = DecodeInputs(decoderVersion: "9.dng")
        XCTAssertEqual(explicit.versionComponent, "ver=9.dng")
        XCTAssertEqual(explicit.key, "recipe=\(DecodeRecipe.current);ver=9.dng;scale=1.0000")
        XCTAssertEqual(explicit.appending(to: "photo"), "photo|ver=9.dng")

        // No `ver=auto:…` may be produced by anything: that spelling belonged to the deleted mechanism.
        for inputs in [nothing, explicit, DecodeInputs(decoderVersion: "8"), EditModel.neutral.decodeInputs] {
            XCTAssertFalse(inputs.key.contains("ver=auto:"), "no `ver=auto:…` in \(inputs.key)")
            XCTAssertFalse(inputs.appending(to: "photo").contains("auto:"),
                           "no `auto:` segment in \(inputs.appending(to: "photo"))")
        }
    }

    func testTheRuleConstantsAndTheRecipeTokenArePinnedTogether() {
        // The automatic rule never appears in the decode key (`ver=auto` only), so the recipe token is
        // the **only** thing that tells an old-rule buffer from a new-rule one. Changing any constant
        // below without bumping it would reuse a buffer the new rule would no longer produce.
        XCTAssertEqual(DecoderAutoVersion.fullFrameBaseISO, 800,
                       "改规则常量必须 bump DecodeRecipe.current")
        XCTAssertEqual(DecoderAutoVersion.cropRange, 0.5...4.0,
                       "改规则常量必须 bump DecodeRecipe.current")
        XCTAssertEqual(DecoderAutoVersion.v9Spellings, ["9.dng", "9"],
                       "改规则常量必须 bump DecodeRecipe.current")
        XCTAssertEqual(DecoderAutoVersion.thresholdISO(crop: 1), 800,
                       "改规则常量必须 bump DecodeRecipe.current")
        XCTAssertEqual(DecodeRecipe.current, "v4-auto409",
                       "改规则常量必须 bump DecodeRecipe.current")
    }

    // MARK: - E. the EXIF reader the decode path uses (synthetic, no RAW)

    func testTheDecodePathReadsTheThreeExifFacts() {
        // The shapes ImageIO really hands over: `FocalLength` / `FocalLenIn35mmFilm` as numbers and
        // `ISOSpeedRatings` as a one-element array (measured on `L1030433.dng`, 50 / 50 / [100]).
        let dng: [String: Any] = [
            kCGImagePropertyExifFocalLength as String: NSNumber(value: 50),
            kCGImagePropertyExifFocalLenIn35mmFilm as String: NSNumber(value: 50),
            kCGImagePropertyExifISOSpeedRatings as String: [NSNumber(value: 100)],
        ]
        let facts = RAWDecoder.exifFacts(fromExif: dng)
        XCTAssertEqual(facts.focalLength, 50)
        XCTAssertEqual(facts.focalLength35mm, 50)
        XCTAssertEqual(facts.iso, 100)
        XCTAssertEqual(DecoderAutoVersion.cropFactor(focalLength: facts.focalLength,
                                                     focalLength35mm: facts.focalLength35mm), 1.0)

        // Some JPEG/RAW writers store the ISO as a bare number; both are accepted.
        let bare: [String: Any] = [
            kCGImagePropertyExifFocalLength as String: NSNumber(value: 25),
            kCGImagePropertyExifFocalLenIn35mmFilm as String: NSNumber(value: 50),
            kCGImagePropertyExifISOSpeedRatings as String: NSNumber(value: 3200),
        ]
        let bareFacts = RAWDecoder.exifFacts(fromExif: bare)
        XCTAssertEqual(bareFacts.iso, 3200)
        XCTAssertEqual(DecoderAutoVersion.cropFactor(focalLength: bareFacts.focalLength,
                                                     focalLength35mm: bareFacts.focalLength35mm), 2.0)
        // An m4/3 frame at ISO 3200 is equivalent ISO 12800 ⇒ it upgrades, and on the SL3 list that
        // means `9.dng`.
        XCTAssertEqual(DecoderAutoVersion.requestedVersion(explicit: nil, iso: bareFacts.iso,
                                                           focalLength: bareFacts.focalLength,
                                                           focalLength35mm: bareFacts.focalLength35mm,
                                                           offered: sl3Offered),
                       "9.dng")

        // Nothing in the dictionary: full frame, no upgrade.
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
        let crop = DecoderAutoVersion.cropFactor(orFullFrame: 50, 50)
        print("409 fixture: offered \(probe.supportedVersions) · iso \(exif) · crop \(crop)"
            + " · threshold \(DecoderAutoVersion.thresholdISO(crop: crop))")

        // The brief's measurement: this machine's SL3 file is 50 mm / 50 mm ⇒ crop 1.0 ⇒ 800, and it
        // is ISO 100, so the rule asks for nothing and the decode is today's v8 byte for byte.
        XCTAssertFalse(DecoderAutoVersion.shouldUpgrade(iso: exif, crop: crop),
                       "ISO \(exif) must not cross the full-frame threshold")
        XCTAssertNil(DecoderAutoVersion.requestedVersion(explicit: nil, iso: exif,
                                                         focalLength: 50, focalLength35mm: 50,
                                                         offered: probe.supportedVersions))

        let outcome = try decoder.decodeDetailed(url, options: DecodeOptions(scale: 0.2))
        XCTAssertNil(outcome.capabilities.requestedVersion,
                     "no request is made, so nothing can be reported as downgraded")
        XCTAssertEqual(outcome.capabilities.effectiveVersion, outcome.capabilities.defaultVersion,
                       "the default document still runs Apple's default")
        XCTAssertEqual(outcome.image.decoderVersion, outcome.capabilities.defaultVersion)

        // …and the measurement decode (black level / goldens) is never auto-upgraded either: its
        // recipe must stay fixed so a threshold change cannot move the measured black point.
        let measured = try decoder.decodeForMeasurement(url, scale: 0.2)
        XCTAssertEqual(measured.decoderVersion, outcome.capabilities.defaultVersion)
    }
}
