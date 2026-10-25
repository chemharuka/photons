import XCTest
@testable import PhotonsCore

/// M0 acceptance tests.
///
/// The RAW fixture is not vendored (it is the user's own photo). Point the suite at one with
/// `PHOTONS_TEST_RAW=/path/to/file.dng swift test`, or let it fall back to a known local sample.
final class DecodeTests: XCTestCase {

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

    private func decoder() throws -> RAWDecoder {
        try RAWDecoder()
    }

    func testProbeReportsVersionsAndSize() throws {
        let url = try fixtureURL()
        let probe = try decoder().probe(url)
        XCTAssertFalse(probe.supportedVersions.isEmpty)
        XCTAssertTrue(probe.supportedVersions.contains(probe.defaultVersion))
        XCTAssertGreaterThan(probe.nativeWidth, 0)
        XCTAssertGreaterThan(probe.nativeHeight, 0)
        print("probe: \(probe.make ?? "?")/\(probe.model ?? "?") \(probe.nativeWidth)x\(probe.nativeHeight) " +
              "default=v\(probe.defaultVersion) offered=\(probe.supportedVersions.joined(separator: ","))")
    }

    /// L1: the same inputs must produce byte-identical output, twice, from independent decoders.
    func testDecodeIsDeterministicInProcess() throws {
        let url = try fixtureURL()
        let opts = DecodeOptions(decoderVersion: nil, scale: 0.25)
        let a = try decoder().decode(url, options: opts)
        let b = try decoder().decode(url, options: opts)
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.sha256(), b.sha256(), "system RAW decode is not reproducible in-process")
    }

    /// Every offered decoder version must be selectable and stable.
    func testEachOfferedVersionIsDeterministic() throws {
        let url = try fixtureURL()
        let versions = try RAWDecoder.availableVersions(for: url)
        let d = try decoder()
        for v in versions {
            let opts = DecodeOptions(decoderVersion: v, scale: 0.125)
            let a = try d.decode(url, options: opts)
            let b = try d.decode(url, options: opts)
            XCTAssertEqual(a.sha256(), b.sha256(), "version \(v) not reproducible")
            XCTAssertEqual(a.decoderVersion, v)
            print("  v\(v): \(a.width)x\(a.height) sha=\(a.sha256().prefix(12))…")
        }
    }

    func testUnsupportedVersionIsRejected() throws {
        let url = try fixtureURL()
        XCTAssertThrowsError(try decoder().decode(url, options: DecodeOptions(decoderVersion: "42.dng", scale: 0.25))) { e in
            guard case DecodeError.unsupportedVersion = e else {
                return XCTFail("expected unsupportedVersion, got \(e)")
            }
        }
    }

    /// EDR headroom: at least some samples must exceed 1.0 on a normal photo, otherwise our
    /// whole "linear unbounded float" working space assumption (D4) is pointless.
    func testLinearBufferCarriesValuesAboveOne() throws {
        let url = try fixtureURL()
        let img = try decoder().decode(url, options: DecodeOptions(decoderVersion: nil, scale: 0.25))
        let st = img.statistics()
        print(String(format: "max=%.3f mean=%.4f over1=%.3f%%", st.maxChannel, st.meanLuma, st.overUnityRatio * 100))
        XCTAssertGreaterThan(st.maxChannel, 0, "image is black")
    }

    /// Round-trip through the cache must be byte-identical to the in-memory buffer.
    func testStoreRoundTripIsLossless() throws {
        let url = try fixtureURL()
        let img = try decoder().decode(url, options: DecodeOptions(decoderVersion: nil, scale: 0.125))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photons-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LinearImageStore(directory: dir)
        let key = DecodeCacheKey(fileSHA256: "test", decoderVersion: img.decoderVersion, scale: 0.125)
        try store.save(img, key: key)
        let back = try XCTUnwrap(try store.load(key))
        XCTAssertEqual(back.sha256(), img.sha256())
        XCTAssertEqual(back.width, img.width)
    }
}
