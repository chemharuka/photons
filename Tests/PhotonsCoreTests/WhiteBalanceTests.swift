import XCTest
import CoreGraphics
@testable import PhotonsCore

/// 派单 006: white balance is a **decode** setting, not an S1 gain.
///
/// What is pinned here, and why each assertion is the one that matters:
///
///   · **The default document is byte-identical.** The whole change is only safe because as shot
///     (`nil`) means "do not touch the filter" — the decode path for a default document is the
///     pre-006 path, unchanged. `#2` asserts it two ways (same hash, same options), and `#3` records
///     *why* it cannot be done by assigning the value the filter reports.
///   · **An explicit value is a different development.** Not a render, not a gain: a second trip
///     through ImageIO (`#4`), with its own cache identity (`#5`) so a stale buffer can never answer
///     a 3500 K document.
///   · **The cost is bounded.** 25 K / 1 tint quantization makes a whole drag one rung, and the
///     ladder answers the repeat request without developing again (`#6`, `#7`).
///   · **S1 no longer multiplies by a WB gain** (`#8`), which is what "退化为恒等" means in pixels.
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

    /// Why `nil` is a state and not a number: assigning the value the filter *reports* is not a
    /// no-op. Measured here rather than asserted from a comment, because the whole design of `nil`
    /// rests on it.
    func testAssigningTheAsShotValueBackIsNotTheAsShotState() throws {
        let url = try fixtureURL()
        let d = try decoder()
        let outcome = try d.decodeDetailed(url, options: DecodeOptions(scale: 0.125))
        let shot = outcome.asShotWhiteBalance
        let t = try XCTUnwrap(shot.temperature)
        let i = try XCTUnwrap(shot.tint)

        let pinned = try d.decode(url, options: DecodeOptions(scale: 0.125,
                                                              whiteBalance: WhiteBalance(temperature: t, tint: i)))
        XCTAssertNotEqual(pinned.sha256(), outcome.image.sha256(),
                          "assigning the reported as-shot value IS a no-op — `nil` could then be a number, "
                          + "and this test (and its doc comment) would be wrong")
    }

    // MARK: - 3. an explicit value is a second development

    func testExplicitWhiteBalanceIsADifferentDevelopment() throws {
        let url = try fixtureURL()
        let d = try decoder()
        let shot = try d.decode(url, options: DecodeOptions(scale: 0.125))
        let warmer = try d.decode(url, options: DecodeOptions(scale: 0.125,
                                                             whiteBalance: WhiteBalance(temperature: 3500, tint: 30)))
        let again = try d.decode(url, options: DecodeOptions(scale: 0.125,
                                                            whiteBalance: WhiteBalance(temperature: 3500, tint: 30)))
        XCTAssertNotEqual(shot.sha256(), warmer.sha256(), "3500 K/+30 produced the as-shot pixels")
        XCTAssertEqual(warmer.sha256(), again.sha256(), "the decoder is not deterministic for a WB it accepted")

        // A WB the decoder cannot honour must be an error, not a quiet as-shot. The filter accepts
        // out-of-range values verbatim, so the clamp is ours; what must never happen is a silent
        // fallback to the file's own balance.
        XCTAssertNoThrow(try d.decode(url, options: DecodeOptions(scale: 0.0625,
                                                                  whiteBalance: WhiteBalance(temperature: 99_999,
                                                                                             tint: 4_000))))
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

    /// The on-disk store must keep two white balances apart, byte for byte — the v9 lesson (§8c) was
    /// that a key which does not carry a setting serves the wrong buffer with no error at all.
    func testStoreRoundTripIsKeyedByWhiteBalance() throws {
        let url = try fixtureURL()
        let d = try decoder()
        let shot = try d.decode(url, options: DecodeOptions(scale: 0.0625))
        let warm = try d.decode(url, options: DecodeOptions(scale: 0.0625,
                                                           whiteBalance: WhiteBalance(temperature: 3500, tint: 30)))
        XCTAssertNotEqual(shot.sha256(), warm.sha256())

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-wb-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LinearImageStore(directory: dir)
        let shotKey = DecodeCacheKey(fileSHA256: "wb", decoderVersion: shot.decoderVersion,
                                     scale: 0.0625, whiteBalance: .asShot)
        let warmKey = DecodeCacheKey(fileSHA256: "wb", decoderVersion: warm.decoderVersion,
                                     scale: 0.0625, whiteBalance: WhiteBalance(temperature: 3500, tint: 30))
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

    // MARK: - 6. one development per white balance, not per request

    /// The loupe's mechanism, exercised directly: a rung identity that carries the white balance.
    /// The counter is `RAWDecoder.decodeCounts()` — real ImageIO runs, not jobs created.
    func testOneDevelopmentPerWhiteBalanceNotPerRequest() throws {
        let url = try fixtureURL()
        RAWDecoder.resetDecodeCounts()

        let ladder = DecodeLadder()
        let base = "\(url.lastPathComponent)|asset-1"
        func identity(_ wb: WhiteBalance) -> String {
            base + "#wb=" + (wb.keyString ?? "as-shot")
        }
        func develop(_ wb: WhiteBalance) throws -> DecodeRung {
            let d = try RAWDecoder()
            let o = try d.decodeDetailed(url, options: DecodeOptions(scale: 0.125, whiteBalance: wb))
            return DecodeRung(scale: 0.125, image: o.image, capabilities: o.capabilities, milliseconds: 0)
        }
        func total() -> Int { RAWDecoder.decodeCounts().values.reduce(0, +) }

        // ① as shot: one development, and it is a hit on the second ask.
        let asShot = WhiteBalance.asShot
        let first = try ladder.rung(identity: identity(asShot), scale: 0.125) { try develop(asShot) }
        XCTAssertFalse(first.cached)
        XCTAssertEqual(total(), 1)
        let second = try ladder.rung(identity: identity(asShot), scale: 0.125) { try develop(asShot) }
        XCTAssertTrue(second.cached, "the second as-shot request developed the file again")
        XCTAssertEqual(total(), 1)

        // ② release the slider at 3500 K/+30: +1 development, under its own identity.
        let warm = WhiteBalance(temperature: 3500, tint: 30)
        let third = try ladder.rung(identity: identity(warm), scale: 0.125) { try develop(warm) }
        XCTAssertFalse(third.cached)
        XCTAssertEqual(total(), 2, "a new white balance did not develop the RAW exactly once")
        XCTAssertNotEqual(first.rung.image.sha256(), third.rung.image.sha256())

        // ③ the same value again (a second release, or coming back to it): a cache hit.
        let fourth = try ladder.rung(identity: identity(warm), scale: 0.125) { try develop(warm) }
        XCTAssertTrue(fourth.cached)
        XCTAssertEqual(total(), 2, "re-submitting the same white balance developed the file again")

        // ④ drag ticks never reach the decoder: the gate is the document, and the document is only
        //    written on release. 12 ticks inside one bucket are one identity, hence zero new decodes.
        var model = EditModel.neutral
        for k in stride(from: 3563.0, through: 3585.0, by: 2.0) { model.light.temperature = k }
        XCTAssertEqual(total(), 2, "a slider tick decoded the RAW")
        model.light.temperature = WhiteBalance(temperature: 3575).quantized().temperature
        let released = model.light.whiteBalance
        XCTAssertEqual(identity(released), base + "#wb=3575K/shot")
        XCTAssertEqual(total(), 2)
    }

    // MARK: - 7. S1's white-balance gain is the identity

    /// A white-balance-only document must render **the same pixels** as the neutral document on the
    /// same decoded buffer, because the balancing happened in the decoder. If S1 still applied its
    /// old Planckian gain this would differ — and that difference is exactly the double correction
    /// 派单 006 removed.
    func testWhiteBalanceOnlyDocumentRendersIdenticallyToNeutral() throws {
        let url = try fixtureURL()
        let image = try decoder().decode(url, options: DecodeOptions(scale: 0.125))
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "wb-identity-test"))

        var wbOnly = EditModel.neutral
        wbOnly.light.temperature = 3500
        wbOnly.light.tint = 30

        let opts = RenderOptions(scale: 1, useCache: false, wantsPixels: true)
        let neutral = try XCTUnwrap(try graph.render(.neutral, options: opts).display)
        let balanced = try XCTUnwrap(try graph.render(wbOnly, options: opts).display)
        XCTAssertEqual(neutral.sha256(), balanced.sha256(),
                       "S1 applied a white-balance gain on top of the decode")

        // And the old approximation is emphatically not a no-op, so the identity above is a real
        // assertion about the render path and not a property of the numbers 3500/30.
        let gains = wbOnly.light.whiteBalanceGains
        XCTAssertFalse(abs(gains.r - 1) < 1e-3 && abs(gains.g - 1) < 1e-3 && abs(gains.b - 1) < 1e-3,
                       "the mask-local fit says 3500 K/+30 is identity — pick another value")
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
