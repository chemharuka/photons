import XCTest
@testable import PhotonsCore

/// M3 decode-contract tests: the two preconditions of the editing graph
/// (docs/architecture-decisions.md §11.4 / §11.8).
///
/// ① v8 capability set + read-back assert. ② explicit linear (boost = 0, gamut mapping off).
/// Both are pixel-level claims, so the tests that can use the real RAW do; the resolution rules are
/// also tested as pure functions so they cannot silently rot on a machine without a fixture.
final class DecodeContractTests: XCTestCase {

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

    // MARK: - ① read-back assertion

    /// A body that does not offer the requested version must end up on the D2′ default (v8) — and
    /// the reported `effectiveVersion` must be the version that actually ran, not the request.
    func testRequestedVersionThatIsNotOfferedLandsOnV8() throws {
        let url = try fixtureURL()
        let decoder = try RAWDecoder()
        let probe = try decoder.probe(url)

        // Pick a known version this body does not offer. On the Leica SL3 fixture bare "9" is not
        // offered (only "9.dng"), which is exactly the silent-downgrade case.
        let candidate = ["9", "6", "7"].first { !probe.supportedVersions.contains($0) }
        let requested = try XCTUnwrap(candidate, "fixture offers every known version; nothing to downgrade")
        XCTAssertNotEqual(probe.defaultVersion, requested)

        let outcome = try decoder.decodeDetailed(url, options: DecodeOptions(decoderVersion: requested, scale: 0.125))
        XCTAssertEqual(outcome.capabilities.requestedVersion, requested)
        XCTAssertEqual(outcome.capabilities.effectiveVersion, "8",
                       "an unoffered request must be pinned to the D2′ default (v8)")
        XCTAssertNotEqual(outcome.capabilities.effectiveVersion, requested)
        XCTAssertTrue(outcome.capabilities.downgraded)
        XCTAssertEqual(outcome.image.decoderVersion, outcome.capabilities.effectiveVersion,
                       "the buffer must report the version that produced it")
        print("readback: requested v\(requested) → effective v\(outcome.capabilities.effectiveVersion) "
              + "offered \(probe.supportedVersions.joined(separator: ","))")
    }

    /// Requesting a version the body *does* offer must be honoured exactly (no accidental downgrade).
    func testRequestedVersionThatIsOfferedIsHonoured() throws {
        let url = try fixtureURL()
        let decoder = try RAWDecoder()
        let probe = try decoder.probe(url)
        let wanted = probe.supportedVersions.contains("8.dng") ? "8.dng" : probe.defaultVersion
        let outcome = try decoder.decodeDetailed(url, options: DecodeOptions(decoderVersion: wanted, scale: 0.125))
        XCTAssertEqual(outcome.capabilities.effectiveVersion, wanted)
        XCTAssertFalse(outcome.capabilities.downgraded)
    }

    /// The pure form of the same rule, independent of any body: v9 is not in the offered set → v8.
    func testResolutionRuleForANonWhitelistedBody() {
        let offered = ["6.dng", "7", "7.dng", "8", "8.dng"]
        let r = DecoderCapabilities.resolve(requested: "9", offered: offered, filterDefault: "8")
        XCTAssertEqual(r.effective, "8")
        XCTAssertTrue(r.downgraded)

        let honoured = DecoderCapabilities.resolve(requested: "8", offered: offered, filterDefault: "8")
        XCTAssertEqual(honoured.effective, "8")
        XCTAssertFalse(honoured.downgraded)

        let none = DecoderCapabilities.resolve(requested: nil, offered: offered, filterDefault: "8")
        XCTAssertEqual(none.effective, "8")
        XCTAssertFalse(none.downgraded)
    }

    /// v9 silently turns three sliders into no-ops (§11.1) — the capability set has to say so.
    func testV9DropsThreeSliders() {
        let v8 = DecoderCapabilities(requestedVersion: nil, effectiveVersion: "8", defaultVersion: "8")
        XCTAssertTrue(v8.supportsChromaNoiseReduction)
        XCTAssertTrue(v8.supportsDetail)
        XCTAssertTrue(v8.supportsMoireReduction)

        let v9 = DecoderCapabilities(requestedVersion: "9", effectiveVersion: "9", defaultVersion: "8")
        XCTAssertFalse(v9.supportsChromaNoiseReduction)
        XCTAssertFalse(v9.supportsDetail)
        XCTAssertFalse(v9.supportsMoireReduction)
        XCTAssertFalse(v9.downgraded)

        let both = DecoderCapabilities(requestedVersion: "9", effectiveVersion: "9.dng", defaultVersion: "8")
        XCTAssertFalse(both.supportsChromaNoiseReduction, "version strings come with .dng suffixes")
    }

    // MARK: - ② explicit linear: exposure is exactly ×2

    /// The whole editing graph assumes "decode → arithmetic". With the system defaults the same
    /// +1 EV measured 2.03–2.66 because a tone curve was already in play; with `boostAmount = 0` and
    /// gamut mapping off it is 2.00. Percentiles, not the mean: a mean can hide a bent curve.
    func testExposureOneStopIsExactlyDoubled() throws {
        let url = try fixtureURL()
        let decoder = try RAWDecoder()
        let base = try decoder.decode(url, options: DecodeOptions(decoderVersion: nil, exposureEV: 0, scale: 0.125))
        let plus = try decoder.decode(url, options: DecodeOptions(decoderVersion: nil, exposureEV: 1, scale: 0.125))
        XCTAssertEqual(base.width, plus.width)
        XCTAssertEqual(base.height, plus.height)

        var ratios: [Double] = []
        ratios.reserveCapacity(base.width * base.height * 3)
        for i in stride(from: 0, to: base.rgba.count, by: 4) {
            for c in 0..<3 {
                let a = Double(base.rgba[i + c])
                guard a > 1e-4 else { continue }          // quantisation noise in the blacks
                ratios.append(Double(plus.rgba[i + c]) / a)
            }
        }
        XCTAssertGreaterThan(ratios.count, 1000)
        ratios.sort()
        func percentile(_ p: Double) -> Double { ratios[Int((Double(ratios.count - 1) * p).rounded())] }

        let p10 = percentile(0.1), p50 = percentile(0.5), p90 = percentile(0.9)
        print(String(format: "exposure ×2: p10 %.4f p50 %.4f p90 %.4f over %d samples", p10, p50, p90, ratios.count))
        for (name, v) in [("p10", p10), ("p50", p50), ("p90", p90)] {
            XCTAssertGreaterThanOrEqual(v, 1.99, "\(name) = \(v): the decode still bends exposure")
            XCTAssertLessThanOrEqual(v, 2.01, "\(name) = \(v): the decode still bends exposure")
        }
    }

    // MARK: - cache identity

    /// Old linear buffers on disk were produced with the *default* decoder settings. Without the
    /// recipe in the key, the first M3 launch would reuse them and every render would be off.
    func testCacheKeyDistinguishesDecodeRecipes() {
        let a = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8")
        let b = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8", decodeRecipe: "v0-defaults")
        XCTAssertNotEqual(a.digest, b.digest)
        XCTAssertEqual(a.decodeRecipe, DecodeRecipe.current)
        XCTAssertEqual(a.digest, DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8").digest,
                       "the key must stay stable inside one recipe")
    }
}
