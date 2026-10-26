import XCTest
import CoreImage
@testable import PhotonsCore

/// 派单 031 — 降噪 / 色彩降噪 / 细节 / 锐化 是**解码**参数（`CIRAWFilter`），不是后处理。
///
/// The tests here are the contract of that sentence, in four groups:
///
///  1. **The mapping.** A slider of −100…100 is a *relative* instruction ("less / more than Apple
///     chose for this body"), it always lands inside the filter's 0…1, and 0 assigns nothing at all.
///  2. **The decode key.** All four are decode inputs, so every one of them moves `DecodeInputs`,
///     the rung identity and `DecodeCacheKey`; putting the value back must hit the old key again.
///     A document that never touched the panel must produce the **byte-identical** keys of 030.
///  3. **The pixels.** The four properties are assigned before `CIRAWFilter` produces an image, and
///     the untouched document is byte-for-byte the pre-031 decode.
///  4. **The measurement.** What this machine's decoder actually honours, printed and pinned — see
///     `DetailSettings`' header for the numbers and for why v8/v9 disagree.
final class DetailTests: XCTestCase {

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

    private func decoder() throws -> RAWDecoder { try RAWDecoder() }

    /// A rung-sized decode: 0.2 of a 60 MP frame keeps the pixel assertions honest and the suite fast.
    private let probeScale: Float = 0.2

    // MARK: - 1. the mapping (no GPU, no file)

    /// 0 = "leave the decoder alone"; ±100 = the ends of the property's range; the middle is
    /// interpolated from the *baseline* the filter reports, not from a nominal 0.5.
    func testSliderIsRelativeToTheBaselineAndAlwaysLandsInRange() {
        // 0 is not "0.0": it is "do not touch this property".
        XCTAssertNil(DetailSettings.decodeAmount(slider: 0, baseline: 0.5))
        XCTAssertNil(DetailSettings.decodeAmount(slider: 0, baseline: 0))

        // The ends.
        XCTAssertEqual(DetailSettings.decodeAmount(slider: 100, baseline: 0.5), 1)
        XCTAssertEqual(DetailSettings.decodeAmount(slider: -100, baseline: 0.5), 0)
        XCTAssertEqual(DetailSettings.decodeAmount(slider: 100, baseline: 0), 1)
        XCTAssertEqual(DetailSettings.decodeAmount(slider: -100, baseline: 0), 0)

        // Halfway from the measured colour-NR baseline (0.5): +50 → 0.75, −50 → 0.25.
        XCTAssertEqual(DetailSettings.decodeAmount(slider: 50, baseline: 0.5)!, 0.75, accuracy: 1e-9)
        XCTAssertEqual(DetailSettings.decodeAmount(slider: -50, baseline: 0.5)!, 0.25, accuracy: 1e-9)

        // Clamped, not overflowed: the filter itself accepts 2.0 and −0.5 verbatim
        // (`testTheFilterDoesNotClampSoTheMappingMust`), so an out-of-travel slider must not leak.
        XCTAssertEqual(DetailSettings.decodeAmount(slider: 1000, baseline: 0.5), 1)
        XCTAssertEqual(DetailSettings.decodeAmount(slider: -1000, baseline: 0.5), 0)

        // Exhaustive: every slider position, four plausible baselines, always inside 0…1.
        for baseline in [0.0, 0.004, 0.377, 0.5, 1.0] {
            for slider in stride(from: -300.0, through: 300.0, by: 5) {
                guard let v = DetailSettings.decodeAmount(slider: slider, baseline: baseline) else {
                    XCTAssertEqual(slider, 0, "only 0 may mean 'leave the filter alone'")
                    continue
                }
                XCTAssertGreaterThanOrEqual(v, 0, "slider \(slider) baseline \(baseline)")
                XCTAssertLessThanOrEqual(v, 1, "slider \(slider) baseline \(baseline)")
            }
        }
    }

    /// Every axis is independent, and `.identity` asks for no assignment at all.
    func testIdentityAssignsNothingAndEachAxisResolvesOnItsOwn() {
        XCTAssertTrue(DetailSettings.identity.decodeValues(baseline: .measured).isEmpty)

        let one = DetailSettings(luminanceNR: 100)
        let values = one.decodeValues(baseline: .measured)
        XCTAssertEqual(values.luminanceNR, 1)
        XCTAssertNil(values.colorNR)
        XCTAssertNil(values.sharpness)
        XCTAssertNil(values.detail)

        // The measured baseline is per body and per axis: colour NR and sharpness are **not** 0.
        XCTAssertEqual(DetailBaseline.measured.colorNR, 0.5)
        XCTAssertEqual(DetailBaseline.measured.sharpness, 0.5)
        XCTAssertEqual(DetailBaseline.measured.luminanceNR, 0)
        XCTAssertEqual(DetailBaseline.measured.detail, 0)

        // A Canon body reports sharpness 1.0: +100 on the sharpness slider is then already there,
        // and −100 is the only direction with room. Still inside the range either way.
        let canon = DetailBaseline(luminanceNR: 0, colorNR: 0.5, sharpness: 1, detail: 0)
        XCTAssertEqual(DetailSettings(sharpness: 100).decodeValues(baseline: canon).sharpness, 1)
        XCTAssertEqual(DetailSettings(sharpness: -100).decodeValues(baseline: canon).sharpness, 0)
    }

    /// Quantize → clamp, and non-finite values never reach a filter (NaN would poison the decoder).
    func testQuantizedAndClamped() {
        let q = DetailSettings(luminanceNR: 30.4, colorNR: -12.6, sharpness: 200, detail: -.infinity).quantized()
        XCTAssertEqual(q.luminanceNR, 30)
        XCTAssertEqual(q.colorNR, -13)
        XCTAssertEqual(q.sharpness, 100, "clamped to the slider travel, not to the filter range")
        XCTAssertEqual(q.detail, 0, "±infinity is not a slider position")
        XCTAssertEqual(DetailSettings(luminanceNR: .nan).clamped().luminanceNR, 0)
    }

    // MARK: - 2. the decode key (no GPU, no file)

    /// The pre-031 key text, verbatim. If this test ever needs editing, every linear buffer on disk
    /// has been orphaned by a change that claims to be pixel-neutral.
    func testDefaultDocumentProducesThePreChangeDecodeKey() {
        let doc = EditModel.neutral
        XCTAssertEqual(doc.decodeInputs, DecodeInputs.asShot)
        XCTAssertEqual(doc.decodeKey, "recipe=\(DecodeRecipe.current);ver=auto;scale=1.0000")
        XCTAssertNil(doc.decodeInputs.detailComponent)
        XCTAssertNil(doc.decodeInputs.whiteBalanceComponent)

        let photo = "abc|asset-1"
        XCTAssertEqual(doc.decodeInputs.appending(to: photo), photo,
                       "a document that never touched the panel must not move a rung identity")

        let key = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8")
        XCTAssertEqual(key.keyText, "abc|8|0.0000|1.0000|full|extendedLinearSRGB|\(DecodeRecipe.current)")
        XCTAssertEqual(key.digest,
                       KeyBuilder.digest(of: "abc|8|0.0000|1.0000|full|extendedLinearSRGB|v2-topdown-rows"),
                       "the digest of the pre-031 key text")
    }

    /// Each of the four axes is a decode input: it moves the document's decode key, the rung
    /// identity **and** the on-disk cache key, and putting the value back restores all three.
    func testEachAxisMovesEveryDecodeKeyAndReturnsHome() {
        let base = EditModel.neutral
        let homeInputs = base.decodeInputs
        let homeDocumentKey = base.decodeKey
        let homeRung = base.decodeInputs.appending(to: "photo")
        let homeCache = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8").digest

        let axes: [(String, WritableKeyPath<DetailSettings, Double>)] = [
            ("luminanceNR", \.luminanceNR), ("colorNR", \.colorNR),
            ("sharpness", \.sharpness), ("detail", \.detail),
        ]
        for (name, path) in axes {
            for value in [30.0, -30.0, 100.0] {
                var doc = base
                doc.detailSettings[keyPath: path] = value
                XCTAssertNotEqual(doc.decodeInputs, homeInputs, "\(name) did not move decodeInputs")
                XCTAssertNotEqual(doc.decodeKey, homeDocumentKey, "\(name) did not move decodeKey")
                XCTAssertNotEqual(doc.decodeInputs.appending(to: "photo"), homeRung,
                                  "\(name) did not move the rung identity")
                let cache = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8",
                                           detail: doc.detailSettings)
                XCTAssertNotEqual(cache.digest, homeCache, "\(name) did not move DecodeCacheKey.digest")

                // …and back home hits the old key again — the whole point of a value-based key.
                doc.detailSettings[keyPath: path] = 0
                XCTAssertEqual(doc.decodeKey, homeDocumentKey)
                XCTAssertEqual(doc.decodeInputs.appending(to: "photo"), homeRung)
                XCTAssertEqual(DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8",
                                              detail: doc.detailSettings).digest, homeCache)
            }
        }
    }

    /// The key text itself, so a human can read what a buffer was developed with.
    func testDetailKeyTextIsStableAndReadable() {
        let doc = EditModel(detailSettings: DetailSettings(luminanceNR: 30, colorNR: -40,
                                                          sharpness: -20, detail: 10))
        XCTAssertEqual(doc.decodeInputs.detailComponent,
                       "dt=nr+30.00,c-40.00,s-20.00,d+10.00")
        XCTAssertEqual(doc.decodeKey,
                       "recipe=\(DecodeRecipe.current);ver=auto;scale=1.0000;dt=nr+30.00,c-40.00,s-20.00,d+10.00")
        XCTAssertEqual(doc.decodeInputs.appending(to: "photo"),
                       "photo|dt=nr+30.00,c-40.00,s-20.00,d+10.00")

        // Both decode inputs, in the one spelling: the white balance first (派单 011), then detail.
        var both = doc
        both.light.temperature = 5500
        both.light.tint = 0
        XCTAssertEqual(both.decodeInputs.appending(to: "photo"),
                       "photo|wb=5500K/+0|dt=nr+30.00,c-40.00,s-20.00,d+10.00")
    }

    /// A detail change is a **new development**, and it must be classified as one by the one decision
    /// function — not as a render, and not as nothing.
    func testDetailSplitIsDecodeNotRender() {
        let old = EditModel.neutral
        for detail in [DetailSettings(luminanceNR: 30), DetailSettings(colorNR: -20),
                       DetailSettings(sharpness: 40), DetailSettings(detail: 60)] {
            var new = old
            new.detailSettings = detail
            XCTAssertEqual(new.splitFrom(old), .decode)
            XCTAssertTrue(new.decodesDifferently(from: old))
            // The render half says nothing: the buffer already carries the detail (same rule as WB).
            XCTAssertEqual(new.renderInputs, old.renderInputs)
            XCTAssertEqual(new.changedStages(from: old), Set(RenderStage.allCases),
                           "a new development invalidates every stage's source pixels")
        }

        // The neighbours are untouched: exposure is still a render, a no-op is still `.none`.
        var exposure = old
        exposure.light.exposure = 0.5
        XCTAssertEqual(exposure.splitFrom(old), .render)
        XCTAssertTrue(old.changedStages(from: old).isEmpty)
    }

    /// History: a moved slider is a changed document (one undo step), a re-commit of the same value
    /// is not.
    func testDetailIsADirtyGroupForHistory() {
        var after = EditModel.neutral
        after.detailSettings.detail = 25
        XCTAssertTrue(EditHistory.dirtyGroups(from: .neutral, to: after).contains(.detail))
        XCTAssertFalse(EditHistory.isSemanticallyIdentical(.neutral, after))
        XCTAssertTrue(EditHistory.isSemanticallyIdentical(after, after))
    }

    /// Documents: a missing key is the default, a present one round-trips, and an old document (no
    /// `detailSettings` at all) decodes to "untouched panel".
    func testDocumentCodingDefaultsAndRoundTrip() throws {
        let legacy = Data(#"{"schemaVersion":3,"processVersion":1}"#.utf8)
        let old = try JSONDecoder().decode(EditModel.self, from: legacy)
        XCTAssertEqual(old.detailSettings, .identity)
        XCTAssertEqual(old.decodeKey, EditModel.neutral.decodeKey)

        let doc = EditModel(detailSettings: DetailSettings(luminanceNR: 30, colorNR: -40,
                                                          sharpness: 20, detail: 10))
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(EditModel.self, from: data)
        XCTAssertEqual(back.detailSettings, doc.detailSettings)
        XCTAssertEqual(back.decodeKey, doc.decodeKey)

        // A partial object: missing axes are 0, not a decode failure.
        let partial = try JSONDecoder().decode(DetailSettings.self,
                                              from: Data(#"{"colorNR":-40}"#.utf8))
        XCTAssertEqual(partial, DetailSettings(colorNR: -40))
    }

    // MARK: - 3. the filter itself: range, read-back, and who clamps

    /// Requirement 1: **assign → read back** for 0 / 0.3 / 1.0 on each of the four properties.
    ///
    /// This is the property-level fact the whole task rests on: the assignment lands and reads back
    /// exactly what was written. It says nothing about whether the *pixels* move (that is
    /// `testTheHonouredAxesSplitByDecoderVersion`) — the filter accepts a value it then ignores, which
    /// is the trap this repository's read-back discipline exists to catch.
    func testEachPropertyReadsBackWhatWasAssigned() throws {
        let url = try fixtureURL()
        let filter = try XCTUnwrap(CIRAWFilter(imageURL: url))
        let baseline = RAWDecoder.detailBaseline(of: filter)
        print("detail baseline: nr=\(baseline.luminanceNR) c=\(baseline.colorNR) " +
              "sh=\(baseline.sharpness) d=\(baseline.detail)")

        for target: Float in [0, 0.3, 1.0] {
            filter.luminanceNoiseReductionAmount = target
            XCTAssertEqual(filter.luminanceNoiseReductionAmount, target, accuracy: 1e-6,
                           "luminanceNoiseReductionAmount did not read back")
            filter.colorNoiseReductionAmount = target
            XCTAssertEqual(filter.colorNoiseReductionAmount, target, accuracy: 1e-6,
                           "colorNoiseReductionAmount did not read back")
            filter.sharpnessAmount = target
            XCTAssertEqual(filter.sharpnessAmount, target, accuracy: 1e-6,
                           "sharpnessAmount did not read back")
            filter.detailAmount = target
            XCTAssertEqual(filter.detailAmount, target, accuracy: 1e-6,
                           "detailAmount did not read back")
        }
    }

    /// …and the production path lands on `DetailSettings.decodeValues(baseline:)` exactly — the
    /// slider → filter translation is one function, not a second opinion in the decoder.
    func testApplyDetailAssignsExactlyTheMappedValues() throws {
        let url = try fixtureURL()
        let filter = try XCTUnwrap(CIRAWFilter(imageURL: url))
        let baseline = RAWDecoder.detailBaseline(of: filter)

        let settings = DetailSettings(luminanceNR: 30, colorNR: -40, sharpness: 20, detail: 55)
        let expected = settings.quantized().decodeValues(baseline: baseline)

        // A default document assigns nothing at all: every property keeps the value Apple reported.
        let untouched = try RAWDecoder.applyDetail(.identity, to: filter, baseline: baseline)
        XCTAssertTrue(untouched.isEmpty)
        XCTAssertEqual(Double(filter.colorNoiseReductionAmount), baseline.colorNR, accuracy: 1e-6,
                       "a parked slider must not replace Apple's 0.5 colour NR with 0")

        // …and an explicit one lands on exactly the mapped value, read back from the filter.
        let applied = try RAWDecoder.applyDetail(settings, to: filter, baseline: baseline)

        XCTAssertEqual(applied, expected)
        XCTAssertEqual(Double(filter.luminanceNoiseReductionAmount),
                       try XCTUnwrap(expected.luminanceNR), accuracy: 1e-4)
        XCTAssertEqual(Double(filter.colorNoiseReductionAmount),
                       try XCTUnwrap(expected.colorNR), accuracy: 1e-4)
        XCTAssertEqual(Double(filter.sharpnessAmount),
                       try XCTUnwrap(expected.sharpness), accuracy: 1e-4)
        XCTAssertEqual(Double(filter.detailAmount),
                       try XCTUnwrap(expected.detail), accuracy: 1e-4)
    }

    /// Requirement 4: the mapping clamps because the filter does not. This is the measurement that
    /// makes the clamp *ours* rather than Apple's good manners.
    func testTheFilterDoesNotClampSoTheMappingMust() throws {
        let url = try fixtureURL()
        let filter = try XCTUnwrap(CIRAWFilter(imageURL: url))

        filter.luminanceNoiseReductionAmount = 2
        XCTAssertEqual(Double(filter.luminanceNoiseReductionAmount), 2, accuracy: 1e-6,
                       "the filter kept 2.0 verbatim: nothing but our clamp keeps us in range")
        filter.luminanceNoiseReductionAmount = -0.5
        XCTAssertEqual(Double(filter.luminanceNoiseReductionAmount), -0.5, accuracy: 1e-6)

        // …and what the production path does with a document that carries an out-of-travel value.
        let extremes = DetailSettings(luminanceNR: 500, colorNR: -500, sharpness: 500, detail: -500)
        _ = try RAWDecoder.applyDetail(extremes, to: filter)
        XCTAssertEqual(Double(filter.luminanceNoiseReductionAmount), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(filter.colorNoiseReductionAmount), 0, accuracy: 1e-6)
        XCTAssertEqual(Double(filter.detailAmount), 0, accuracy: 1e-6)
    }

    // MARK: - 4. the pixels

    /// Requirement 2 (the default half): an untouched panel changes **nothing**.
    ///
    /// Two claims, both in bytes: the develop assigns none of the four properties (so it cannot
    /// differ from the pre-031 decode path, which never mentioned them), and two independent decodes
    /// — one with the field omitted, one with `.identity` spelled out — are the same buffer.
    func testDefaultDetailIsByteIdenticalAndAssignsNothing() throws {
        let url = try fixtureURL()
        let bare = try decoder().decodeDetailed(url, options: DecodeOptions(scale: probeScale))
        let identity = try decoder().decodeDetailed(url, options: DecodeOptions(scale: probeScale,
                                                                                detail: .identity))
        XCTAssertTrue(identity.detailApplied.isEmpty,
                      "a default document must not touch the four properties: \(identity.detailApplied.summary)")
        XCTAssertEqual(identity.image.sha256(), bare.image.sha256(),
                       "the untouched document is not byte-identical to the plain decode")
        XCTAssertEqual(identity.image.sha256(), identity.image.sha256())

        // The document-level spelling of the same claim.
        XCTAssertEqual(EditModel.neutral.decodeInputs.detail, .identity)
        print("default decode sha256 \(identity.image.sha256()) " +
              "\(identity.image.width)x\(identity.image.height) baseline \(identity.detailBaseline)")
    }

    /// Requirement 2 (the visible half): at least one axis moves pixels, so the wiring is live rather
    /// than merely accepted. Which axis moves depends on the decoder version — see
    /// `testTheHonouredAxesSplitByDecoderVersion`, which prints all four.
    func testAtLeastOneAxisMovesPixels() throws {
        let url = try fixtureURL()
        let base = try decoder().decodeDetailed(url, options: DecodeOptions(scale: probeScale))
        var moved: [String] = []
        var report: [String] = []
        for (name, settings) in [("luminanceNR", DetailSettings(luminanceNR: 100)),
                                 ("colorNR", DetailSettings(colorNR: 100)),
                                 ("sharpness", DetailSettings(sharpness: 100)),
                                 ("detail", DetailSettings(detail: 100))] {
            let image = try decoder().decodeDetailed(url,
                                                     options: DecodeOptions(scale: probeScale,
                                                                            detail: settings)).image
            let diff = Self.differingSamples(base.image.rgba, image.rgba)
            report.append("\(name)=\(diff)")
            if diff > 0 { moved.append(name) }
        }
        print("decoder v\(base.capabilities.effectiveVersion): samples moved by +100 — "
              + report.joined(separator: " "))
        XCTAssertFalse(moved.isEmpty,
                       "none of the four detail properties moved a single sample; the sliders are dead "
                       + "(\(report.joined(separator: " ")))")
        // Whatever the body honours, the assignment itself must have landed.
        let l = try decoder().decodeDetailed(url, options: DecodeOptions(scale: probeScale,
                                                                        detail: DetailSettings(luminanceNR: 50)))
        XCTAssertNotNil(l.detailApplied.luminanceNR)
    }

    /// The measurement this task rests on, printed for the report: at the default decoder (v8) only
    /// *some* axes are honoured; a v9 request honours others. Pinned as a test so a macOS update that
    /// changes it is visible instead of mysterious.
    func testTheHonouredAxesSplitByDecoderVersion() throws {
        let url = try fixtureURL()
        let offered = try RAWDecoder.availableVersions(for: url)
        // At most two variants: the D2′ default (v8) and one v9 spelling. Each decode of a 60 MP file
        // at v9 costs seconds, and the point of the test is the *split*, not a matrix.
        let wanted = ["8", "9.dng", "9"].filter { offered.contains($0) }
        let versions = Array(wanted.prefix(2))
        guard !versions.isEmpty else { throw XCTSkip("no v8/v9 variant offered by this file") }

        for version in versions {
            let base = try decoder().decodeDetailed(url, options: DecodeOptions(decoderVersion: version,
                                                                               scale: probeScale))
            var line = "v\(version) (read back \(base.capabilities.effectiveVersion)):"
            for (name, settings) in [("nr", DetailSettings(luminanceNR: 100)),
                                     ("c", DetailSettings(colorNR: 100)),
                                     ("sh", DetailSettings(sharpness: 100)),
                                     ("d", DetailSettings(detail: 100))] {
                let image = try decoder().decodeDetailed(url,
                                                         options: DecodeOptions(decoderVersion: version,
                                                                                scale: probeScale,
                                                                                detail: settings)).image
                let diff = Self.differingSamples(base.image.rgba, image.rgba)
                line += " \(name)=\(diff)"
            }
            print(line)
        }

        // The invariant that survives every body and both versions: the assignment lands and reads
        // back (`detailApplied`), and the develop does not throw.
        let v8 = try decoder().decodeDetailed(url, options: DecodeOptions(scale: probeScale,
                                                                         detail: DetailSettings(luminanceNR: 100)))
        XCTAssertEqual(v8.detailApplied.luminanceNR ?? -1, 1, accuracy: 1e-6)
    }

    /// The cache contract, on the real store: a new detail value writes a new buffer, and going back
    /// to the old value hits the old one — no second development.
    func testCacheKeyHitsTheOldBufferAfterReturningHome() throws {
        let url = try fixtureURL()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-detail-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LinearImageStore(directory: dir)

        func key(_ detail: DetailSettings) -> DecodeCacheKey {
            DecodeCacheKey(fileSHA256: "sha", decoderVersion: "8", scale: probeScale, detail: detail)
        }

        let first = DetailSettings(luminanceNR: 40)
        let second = DetailSettings(luminanceNR: 60)
        let image = try decoder().decode(url, options: DecodeOptions(scale: probeScale, detail: first))

        XCTAssertNil(try store.load(key(first)), "nothing written yet")
        try store.save(image, key: key(first))
        XCTAssertEqual(try store.load(key(first))?.sha256(), image.sha256(),
                       "the same document did not hit the buffer it just wrote")
        XCTAssertNil(try store.load(key(second)), "a different detail value must not hit it")
        XCTAssertNil(try store.load(key(.identity)), "nor must the untouched panel")

        // Back home: the very same bytes, with the pixel hash of the first development.
        let home = try store.load(key(first))
        XCTAssertEqual(home?.sha256(), image.sha256())
        XCTAssertEqual(key(first).digest, DecodeCacheKey(fileSHA256: "sha", decoderVersion: "8",
                                                         scale: probeScale,
                                                         detail: first).digest)
    }

    // MARK: - helpers

    private static func differingSamples(_ a: [Float16], _ b: [Float16]) -> Int {
        guard a.count == b.count else { return max(a.count, b.count) }
        var n = 0
        for i in 0..<a.count where a[i] != b[i] { n += 1 }
        return n
    }
}
