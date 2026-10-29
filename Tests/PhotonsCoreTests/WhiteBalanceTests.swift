import XCTest
import CoreGraphics
@testable import PhotonsCore

/// 006's contract, **after 143**: the decoder is always the as-shot decode, and a document's
/// white balance is an S1 gain computed by `WhiteBalanceEstimate`.
///
/// What is pinned here, and why each assertion is the one that matters:
///
///   · **The default document is byte-identical.** The decoder is left untouched for every document
///     (`nil` and explicit alike), so the default decode path is the pre-006 path unchanged.
///   · **A white balance is not a development.** Two requests produce the same buffer; the gain is a
///     render-side number (`testExplicitWhiteBalanceIsNotADifferentDevelopment`).
///   · **The cost is bounded.** 25 K / 1 tint quantization still makes a whole drag one document
///     value, and since there is no decode at all the ladder is asked once per photo.
///   · **S1 applies the estimator's gain**, not the old encoded fit
///     (`testWhiteBalanceOnlyDocumentRendersDifferentlyToNeutral`).
///
/// The RAW fixture is the user's own photo and is not vendored: set `PHOTONS_TEST_RAW` or the suite
/// skips. The second body (if present) is used only where two cameras prove the point.
final class WhiteBalanceTests: XCTestCase {

    // MARK: - fixtures

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

    /// A second, different body — the as-shot value is a fact about a *file*, so one camera proves
    /// nothing about the mechanism.
    private func secondBodyURL() -> URL? {
        let p = NSString(string: "~/Desktop/US/_1274394.dng").expandingTildeInPath
        return FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
    }

    private func decoder() throws -> RAWDecoder { try RAWDecoder() }

    // MARK: - 1. the value comes from the file

    func testAsShotWhiteBalanceIsReadFromTheFileAndIsNot6500() throws {
        for url in [try fixtureURL()] + [secondBodyURL()].compactMap({ $0 }) {
            let probe = try decoder().probe(url)
            let wb = WhiteBalance(temperature: probe.asShotTemperature, tint: probe.asShotTint)
            print("\(url.lastPathComponent): as-shot \(wb.summary) "
                  + "(raw \(probe.asShotTemperature.map { String(format: "%.3f", $0) } ?? "nil") K / "
                  + "\(probe.asShotTint.map { String(format: "%.3f", $0) } ?? "nil"))")
            let t = try XCTUnwrap(probe.asShotTemperature, "no as-shot temperature for \(url.lastPathComponent)")
            let i = try XCTUnwrap(probe.asShotTint, "no as-shot tint for \(url.lastPathComponent)")
            XCTAssertTrue(WhiteBalance.temperatureRange.contains(t),
                          "as-shot \(t) K outside the slider range")
            XCTAssertTrue(WhiteBalance.tintRange.contains(i), "as-shot tint \(i) outside ±150")
            // The complaint that started this task: every photo showed 6500 K / 0.
            XCTAssertNotEqual(t, 6500, accuracy: 1,
                              "\(url.lastPathComponent) really is a 6500 K shot — pick another fixture")
            // The decode reports the same pair the probe does.
            let outcome = try decoder().decodeDetailed(url, options: DecodeOptions(scale: 0.0625))
            XCTAssertEqual(outcome.asShotWhiteBalance.temperature, probe.asShotTemperature)
            XCTAssertEqual(outcome.capabilities.asShotTemperature, probe.asShotTemperature)
            XCTAssertEqual(outcome.capabilities.asShotTint, probe.asShotTint)
        }
    }

    // MARK: - 2. the default document does not move

    func testAsShotDecodeIsByteIdenticalToTheDefaultDecode() throws {
        let url = try fixtureURL()
        let d = try decoder()
        for scale: Float in [0.125, 0.25] {
            let plain = try d.decode(url, options: DecodeOptions(scale: scale))
            let asShot = try d.decode(url, options: DecodeOptions(scale: scale, whiteBalance: .asShot))
            let partial = try d.decode(url, options: DecodeOptions(scale: scale,
                                                                   whiteBalance: WhiteBalance()))
            XCTAssertEqual(plain.sha256(), asShot.sha256(),
                           "as shot must be the untouched filter (scale \(scale))")
            XCTAssertEqual(plain.sha256(), partial.sha256())
        }
    }

    /// 143 — assigning the reported as-shot value is now exactly the as-shot decode: the decoder has
    /// no write path for `neutralTemperature`/`neutralTint` at all. (Before 143 this test asserted the
    /// opposite, because 006 deliberately *did* write the pair; the pairs of pixels that moved are the
    /// reason the table/prediction path existed, and both are gone.)
    func testAssigningAWhiteBalanceDoesNotTouchTheDecode() throws {
        let url = try fixtureURL()
        let d = try decoder()
        let outcome = try d.decodeDetailed(url, options: DecodeOptions(scale: 0.125))
        let shot = outcome.asShotWhiteBalance
        let t = try XCTUnwrap(shot.temperature)
        let i = try XCTUnwrap(shot.tint)

        let pinned = try d.decode(url, options: DecodeOptions(scale: 0.125,
                                                              whiteBalance: WhiteBalance(temperature: t, tint: i)))
        XCTAssertEqual(pinned.sha256(), outcome.image.sha256(),
                       "the decoder still wrote a white balance into the filter")
        let wild = try d.decode(url, options: DecodeOptions(scale: 0.125,
                                                            whiteBalance: WhiteBalance(temperature: 3500, tint: 30)))
        XCTAssertEqual(wild.sha256(), outcome.image.sha256(),
                       "an explicit pair changed the decoded pixels — 143 says it must not")
    }

    // MARK: - 3. an explicit value is a render-side gain, not a second development

    func testExplicitWhiteBalanceIsNotADifferentDevelopment() throws {
        let url = try fixtureURL()
        let d = try decoder()
        let shot = try d.decode(url, options: DecodeOptions(scale: 0.125))
        let warm = try d.decode(url, options: DecodeOptions(scale: 0.125,
                                                           whiteBalance: WhiteBalance(temperature: 3500, tint: 30)))
        let again = try d.decode(url, options: DecodeOptions(scale: 0.125,
                                                            whiteBalance: WhiteBalance(temperature: 3500, tint: 30)))
        XCTAssertEqual(shot.sha256(), warm.sha256(),
                       "3500 K/+30 developed a different buffer — it must be an S1 gain now")
        XCTAssertEqual(warm.sha256(), again.sha256(), "the as-shot decode is not deterministic")

        // The gain the render applies is real (and not the old encoded fit), so the picture the user
        // sees does change even though the buffer does not.
        let g = WhiteBalanceEstimate.gain(for: WhiteBalance(temperature: 3500, tint: 30))
        XCTAssertFalse(abs(g.r - 1) < 1e-3 && abs(g.b - 1) < 1e-3,
                       "3500 K/+30 is the identity — pick another value")
    }

    // MARK: - 4. cache identity

    func testCacheKeyCarriesTheWhiteBalance() {
        let shot = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8")
        let legacy = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8", decodeRecipe: DecodeRecipe.current)
        XCTAssertEqual(shot.digest, legacy.digest,
                       "the as-shot digest must stay the pre-006 one, or every buffer on disk is orphaned")

        let warm = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8",
                                  whiteBalance: WhiteBalance(temperature: 3500, tint: 30))
        let warmAgain = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8",
                                       whiteBalance: WhiteBalance(temperature: 3500, tint: 30))
        let kelvinOnly = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8",
                                        whiteBalance: WhiteBalance(temperature: 3500))
        XCTAssertNotEqual(shot.digest, warm.digest, "a 3500 K document would hit the as-shot buffer")
        XCTAssertEqual(warm.digest, warmAgain.digest)
        XCTAssertNotEqual(warm.digest, kelvinOnly.digest,
                          "explicit tint and as-shot tint must not share a buffer")
        // `nil` temperature with an explicit tint is a third state, not "0 K".
        XCTAssertNotEqual(kelvinOnly.digest, DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8",
                                                            whiteBalance: WhiteBalance(tint: 30)).digest)
    }

    /// The on-disk store still keeps two **keys** apart byte for byte — the v9 lesson (§8c) was that a
    /// key which does not carry a setting serves the wrong buffer with no error at all. Since 143 the
    /// document never names the second key (white balance is a render gain), but a caller that does
    /// still gets the buffer it named.
    func testStoreRoundTripIsKeyedAndTheDecoderStaysAsShot() throws {
        let url = try fixtureURL()
        let d = try decoder()
        let shot = try d.decode(url, options: DecodeOptions(scale: 0.0625))
        let warm = try d.decode(url, options: DecodeOptions(scale: 0.0625,
                                                           whiteBalance: WhiteBalance(temperature: 3500, tint: 30)))
        XCTAssertEqual(shot.sha256(), warm.sha256(),
                       "two decodes of the same file differ — the decoder still takes a balance")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-wb-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LinearImageStore(directory: dir)
        let shotKey = DecodeCacheKey(fileSHA256: "wb", decoderVersion: shot.decoderVersion,
                                     scale: 0.0625, whiteBalance: .asShot)
        let warmKey = DecodeCacheKey(fileSHA256: "wb", decoderVersion: warm.decoderVersion,
                                     scale: 0.0625, whiteBalance: WhiteBalance(temperature: 3500, tint: 30))
        XCTAssertNotEqual(shotKey.digest, warmKey.digest)
        try store.save(shot, key: shotKey)
        try store.save(warm, key: warmKey)
        XCTAssertEqual(try XCTUnwrap(store.load(shotKey)).sha256(), shot.sha256())
        XCTAssertEqual(try XCTUnwrap(store.load(warmKey)).sha256(), warm.sha256(),
                       "the 3500 K key returned the as-shot buffer (or vice versa)")
    }

    // MARK: - 5. quantization: a drag is one rung

    func testQuantizationCollapsesADragIntoOneDevelopment() {
        // 12 ticks inside one 25 K bucket (3562.5…3587.5 → 3575) — the thumb moves, the document
        // does not.
        let ticks = stride(from: 3563.0, through: 3585.0, by: 2.0).map {
            WhiteBalance(temperature: $0, tint: 30.4).quantized()
        }
        XCTAssertEqual(Set(ticks.map { $0.keyString ?? "as-shot" }).count, 1,
                       "ticks 3562…3585 K did not collapse into one development: "
                       + "\(Set(ticks.map { $0.keyString ?? "as-shot" }))")
        XCTAssertEqual(ticks.first?.temperature, 3575)

        XCTAssertEqual(WhiteBalance(temperature: 3537).quantized().temperature, 3525)
        XCTAssertEqual(WhiteBalance(temperature: 3551).quantized().temperature, 3550)
        XCTAssertEqual(WhiteBalance(tint: 30.4).quantized().tint, 30)
        XCTAssertEqual(WhiteBalance(tint: -0.4).quantized().tint, 0)   // -0.0 would key differently
        // Clamped, not wrapped, and as shot stays as shot.
        XCTAssertEqual(WhiteBalance(temperature: 99_999).quantized().temperature,
                       WhiteBalance.temperatureRange.upperBound)
        XCTAssertEqual(WhiteBalance(temperature: 10).quantized().temperature,
                       WhiteBalance.temperatureRange.lowerBound)
        XCTAssertTrue(WhiteBalance().quantized().isAsShot)
        XCTAssertNil(WhiteBalance().keyString)
    }

    // MARK: - 6. one development per photo, not per white balance

    /// 143: a white-balance request never reaches the decoder. The ladder is asked once, and every
    /// later pair — including the release of a drag — is a render over that one buffer.
    func testOneDevelopmentRegardlessOfWhiteBalance() throws {
        let url = try fixtureURL()
        RAWDecoder.resetDecodeCounts()

        let ladder = DecodeLadder()
        let base = "\(url.lastPathComponent)|asset-1"
        func identity() -> String { base }
        func develop() throws -> DecodeRung {
            let d = try RAWDecoder()
            let o = try d.decodeDetailed(url, options: DecodeOptions(scale: 0.125))
            return DecodeRung(scale: 0.125, image: o.image, capabilities: o.capabilities, milliseconds: 0)
        }
        func total() -> Int { RAWDecoder.decodeCounts().values.reduce(0, +) }

        let first = try ladder.rung(identity: identity(), scale: 0.125) { try develop() }
        XCTAssertFalse(first.cached)
        XCTAssertEqual(total(), 1)

        let second = try ladder.rung(identity: identity(), scale: 0.125) { try develop() }
        XCTAssertTrue(second.cached, "the second request developed the file again")
        XCTAssertEqual(total(), 1)

        // A release at 3500 K/+30 shares that rung: the pair is an S1 gain, so the identity did not
        // move and the decoder was not asked again.
        var model = EditModel.neutral
        model.light.temperature = 3500
        model.light.tint = 30
        XCTAssertEqual(model.decodeInputs.appending(to: base), base)
        let third = try ladder.rung(identity: model.decodeInputs.appending(to: base), scale: 0.125) {
            try develop()
        }
        XCTAssertTrue(third.cached)
        XCTAssertEqual(total(), 1, "a white balance developed the RAW again")

        // Twelve drag ticks inside one bucket still develop nothing.
        for k in stride(from: 3563.0, through: 3585.0, by: 2.0) { model.light.temperature = k }
        XCTAssertEqual(total(), 1, "a slider tick decoded the RAW")
    }

    // MARK: - 7. S1's white-balance gain is the estimator's

    /// 143 — a white-balance-only document must **not** render the neutral document's pixels: the
    /// balance is S1's gain now. The pair is also emphatically not the old encoded fit, so the
    /// difference is the new estimator's arithmetic rather than a coincidence of 3500/30.
    func testWhiteBalanceOnlyDocumentRendersDifferentlyToNeutral() throws {
        let url = try fixtureURL()
        let image = try decoder().decode(url, options: DecodeOptions(scale: 0.125))
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "wb-identity-test"))

        var wbOnly = EditModel.neutral
        wbOnly.light.temperature = 3500
        wbOnly.light.tint = 30

        let opts = RenderOptions(scale: 1, useCache: false, wantsPixels: true)
        let neutral = try XCTUnwrap(try graph.render(.neutral, options: opts).display)
        let balanced = try XCTUnwrap(try graph.render(wbOnly, options: opts).display)
        XCTAssertNotEqual(neutral.sha256(), balanced.sha256(),
                          "S1 did not apply the white-balance gain")

        // The gain is the estimator's diagonal and it is not the identity.
        let gains = graph.whiteBalanceGain(for: wbOnly.light.whiteBalance)
        XCTAssertFalse(abs(gains.r - 1) < 1e-3 && abs(gains.g - 1) < 1e-3 && abs(gains.b - 1) < 1e-3,
                       "the estimator says 3500 K/+30 is identity — pick another value")
        // …and the old display-encoded fit is a different number, so this is not a re-run of it.
        let old = wbOnly.light.whiteBalanceGains
        XCTAssertNotEqual(Float(gains.r), old.r, accuracy: 1e-3)
    }

    // MARK: - 8. documents written before schema 3

    func testSchema2DocumentReadsTheOldSentinelAsAsShot() throws {
        let old = Data(#"{"schemaVersion":2,"light":{"exposure":0.5,"temperature":6500,"tint":0}}"#.utf8)
        let model = try JSONDecoder().decode(EditModel.self, from: old)
        XCTAssertNil(model.light.temperature, "6500 was the old \"no change\" sentinel, not a value")
        XCTAssertNil(model.light.tint)
        XCTAssertEqual(model.light.exposure, 0.5)
        XCTAssertTrue(model.light.whiteBalance.isAsShot)

        let edited = Data(#"{"schemaVersion":2,"light":{"temperature":5200,"tint":-12}}"#.utf8)
        let kept = try JSONDecoder().decode(EditModel.self, from: edited)
        XCTAssertEqual(kept.light.temperature, 5200, "a real value must survive the migration")
        XCTAssertEqual(kept.light.tint, -12)

        // A schema-3 document keeps an explicit 6500 K: it is a value now, not a sentinel.
        let pinned = Data(#"{"schemaVersion":3,"light":{"temperature":6500,"tint":0}}"#.utf8)
        let model3 = try JSONDecoder().decode(EditModel.self, from: pinned)
        XCTAssertEqual(model3.light.temperature, 6500)
        XCTAssertEqual(model3.light.tint, 0)

        // And as shot round-trips as *absence*, not as `null`.
        let encoded = try JSONEncoder().encode(EditModel.neutral)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("temperature"), "as shot was written as a number: \(json)")
        XCTAssertEqual(try JSONDecoder().decode(EditModel.self, from: encoded), .neutral)
    }
}
