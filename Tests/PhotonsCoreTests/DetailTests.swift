import XCTest
import CoreImage
@testable import PhotonsCore

/// 派单 031 / 040 — 降噪 / 色彩降噪 / 细节 / 锐化 是**解码**参数（`CIRAWFilter`），不是后处理。
///
/// 040 改的是**单位**：滑杆显示 0…100，默认位置 = 该机身在那一根轴上的基线 × 100
/// （Leica L1030433 → `0 / 50 / 0 / 50`，R5 锐化 → 100，Sony ARW 降噪 → 38），映射是
/// `位置 / 100`，而**停在默认位置 = 不赋值**（031 的纪律：写 0 进色彩降噪会关掉 Apple 的一半降噪）。
///
/// The tests here are the contract of that sentence, in four groups:
///
///  1. **The mapping.** 0…100 is the only travel; the default position is the body's, not a constant;
///     a position at the default assigns nothing, everything else assigns `position / 100`.
///  2. **The decode key.** All four are decode inputs, so every one of them moves `DecodeInputs`,
///     the rung identity and `DecodeCacheKey`; putting the slider back on its default must hit the
///     old key again. A document that never touched the panel must produce the **byte-identical**
///     keys of 030.
///  3. **The pixels.** The four properties are assigned before `CIRAWFilter` produces an image, and
///     the untouched document — and one parked on its default positions — is byte-for-byte the
///     pre-031 decode.
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

    /// The three bodies 040 has numbers for. Only the Leica is a real fixture on this machine; the
    /// other two are the baselines 031 measured elsewhere (`detail.swift`'s header), simulated here.
    private let leica = DetailBaseline.measured
    private let canonR5 = DetailBaseline(luminanceNR: 0, colorNR: 0.5, sharpness: 1, detail: 0)
    private let sonyARW = DetailBaseline(luminanceNR: 0.377, colorNR: 0.5, sharpness: 0.5, detail: 0)

    // MARK: - 1. positions: the default is the body's, and the travel is 0…100

    /// Requirement 1: the four default positions, from the body — not a hard-coded 50.
    func testDefaultPositionsComeFromTheBody() {
        // Leica L1030433, the fixture on this machine: 0 / 50 / 0 / 50.
        let untouched = DetailSettings.identity
        XCTAssertEqual(DetailAxis.panelOrder, [.luminanceNR, .colorNR, .detail, .sharpness])
        XCTAssertEqual(DetailAxis.panelOrder.map { untouched.position($0, in: leica) },
                       [0, 50, 0, 50], "Leica defaults")

        // R5 reports sharpness 1.0: its default position is 100, and resetting there must not
        // silently halve the sharpening the body chose.
        XCTAssertEqual(untouched.position(.sharpness, in: canonR5), 100)
        XCTAssertEqual(DetailAxis.panelOrder.map { untouched.position($0, in: canonR5) },
                       [0, 50, 0, 100], "R5 defaults")

        // Sony ARW luminance NR is 0.377 → 38 (rounded to the slider's step, not truncated to 37).
        XCTAssertEqual(untouched.position(.luminanceNR, in: sonyARW), 38)
        XCTAssertEqual(DetailAxis.panelOrder.map { untouched.position($0, in: sonyARW) },
                       [38, 50, 0, 50], "Sony defaults")

        // …and the same positions come back out of the baseline itself, for the CLI probe.
        XCTAssertEqual(leica.defaultPositions[.colorNR], 50)
        XCTAssertEqual(canonR5.defaultPositions[.sharpness], 100)
    }

    /// Requirement 2: **every** slider travels 0…100 (细节 too — the user's 2026-10-27 correction),
    /// both ends are reachable, and anything outside is clamped rather than stored.
    func testEverySliderTravelsZeroToHundredAndClamps() {
        XCTAssertEqual(DetailSettings.range, 0...100, "one travel for all four axes")
        XCTAssertEqual(DetailSettings.step, 1)
        XCTAssertEqual(DetailSettings.format, "%.0f", "整数，没有百分号")

        for axis in DetailAxis.allCases {
            var s = DetailSettings.identity

            s.setPosition(0, axis, in: leica)
            XCTAssertEqual(s.position(axis, in: leica), 0, "\(axis) left end")
            s.setPosition(100, axis, in: leica)
            XCTAssertEqual(s.position(axis, in: leica), 100, "\(axis) right end")

            // Out of travel: clamped, and stored as the end — unless the end *is* the default position,
            // in which case "the left end" is the untouched state (`nil`), not a stored 0.
            s.setPosition(-40, axis, in: leica)
            XCTAssertEqual(s.position(axis, in: leica), 0, "\(axis) below zero is the left end")
            if axis.defaultPosition(in: leica) == 0 {
                XCTAssertNil(s[axis], "\(axis): its default is 0, so the left end is 'untouched'")
            } else {
                XCTAssertEqual(s[axis], 0, "\(axis) below zero stores the left end")
            }
            s.setPosition(1_000, axis, in: leica)
            XCTAssertEqual(s[axis], 100, "\(axis) above one hundred")

            // Quantized to the step, and back on the default clears the field instead of storing it.
            s.setPosition(30.4, axis, in: leica)
            XCTAssertEqual(s[axis], 30, "\(axis) is not quantized")
            s.setPosition(axis.defaultPosition(in: leica), axis, in: leica)
            XCTAssertNil(s[axis], "\(axis) on its default must be nil, not a number")
        }
    }

    /// The Sonys of the world: a default position that is neither 0 nor 50 must still round-trip.
    func testAnOffRoundDefaultSurvivesADragAwayAndBack() {
        var s = DetailSettings.identity
        s.setPosition(38, .luminanceNR, in: sonyARW)
        XCTAssertNil(s[.luminanceNR], "38 is the Sony default position")
        s.setPosition(60, .luminanceNR, in: sonyARW)
        XCTAssertEqual(s[.luminanceNR], 60)
        s.setPosition(38, .luminanceNR, in: sonyARW)
        XCTAssertNil(s[.luminanceNR])
    }

    /// Requirement 2 (the mapping half): `position / 100`, and a position **at the default** assigns
    /// nothing at all. 031's rule survives the renormalisation — it is now "don't write the baseline",
    /// not "don't write 0".
    func testPositionMapsToThePropertyAndTheDefaultAssignsNothing() {
        // Straight division: 0 → 0.0 is a real assignment when the body's own value is 0.5.
        XCTAssertEqual(DetailSettings.decodeAmount(slider: 0, baseline: 0.5), 0)
        XCTAssertEqual(DetailSettings.decodeAmount(slider: 30, baseline: 0.5)!, 0.30, accuracy: 1e-9)
        XCTAssertEqual(DetailSettings.decodeAmount(slider: 55, baseline: 0.5)!, 0.55, accuracy: 1e-9)
        XCTAssertEqual(DetailSettings.decodeAmount(slider: 100, baseline: 0.5), 1)
        XCTAssertEqual(DetailSettings.decodeAmount(slider: 100, baseline: 0), 1)

        // The default positions of all three bodies assign nothing.
        for (name, baseline) in [("leica", leica), ("r5", canonR5), ("sony", sonyARW)] {
            for axis in DetailAxis.allCases {
                let position = axis.defaultPosition(in: baseline)
                let value = DetailSettings.decodeAmount(slider: position,
                                                        baseline: baseline[keyPath: baselineKeyPath(axis)])
                XCTAssertNil(value, "\(name) \(axis) at its default position \(position) assigned \(value ?? 0)")
            }
        }
        XCTAssertNil(DetailSettings.decodeAmount(slider: 50, baseline: 0.5))
        XCTAssertNil(DetailSettings.decodeAmount(slider: 0, baseline: 0))
        XCTAssertNil(DetailSettings.decodeAmount(slider: nil, baseline: 0.5), "nil = untouched")

        // A default that does not land on an integer (Sony 0.377 → 38) assigns nothing either, while
        // one step below it is a real 0.37.
        XCTAssertNil(DetailSettings.decodeAmount(slider: 38, baseline: 0.377))
        XCTAssertEqual(DetailSettings.decodeAmount(slider: 37, baseline: 0.377)!, 0.37, accuracy: 1e-9)

        // Clamped, not overflowed: the filter itself accepts 2.0 and −0.5 verbatim
        // (`testTheFilterDoesNotClampSoTheMappingMust`), so an out-of-travel position must not leak.
        XCTAssertEqual(DetailSettings.decodeAmount(slider: 1_000, baseline: 0.5), 1)
        XCTAssertEqual(DetailSettings.decodeAmount(slider: -1_000, baseline: 0.5), 0)

        // Exhaustive: every position, five plausible baselines, always inside 0…1, and `nil` exactly
        // on the default position.
        for baseline in [0.0, 0.004, 0.377, 0.5, 1.0] {
            let defaultPosition = (baseline * 100).rounded()
            for slider in stride(from: 0.0, through: 100.0, by: 5) {
                let v = DetailSettings.decodeAmount(slider: slider, baseline: baseline)
                if abs(slider - baseline * 100) < 0.5 {
                    XCTAssertNil(v, "slider \(slider) baseline \(baseline) is the default position")
                    continue
                }
                let unwrapped = v ?? -1
                XCTAssertEqual(unwrapped, slider / 100, accuracy: 1e-9,
                               "slider \(slider) baseline \(baseline)")
                XCTAssertGreaterThanOrEqual(unwrapped, 0)
                XCTAssertLessThanOrEqual(unwrapped, 1)
            }
            XCTAssertEqual(DetailSettings.decodeAmount(slider: defaultPosition, baseline: baseline), nil,
                           "baseline \(baseline): the default position assigned something")
        }
    }

    /// Every axis is independent, and `.identity` asks for no assignment at all.
    func testIdentityAssignsNothingAndEachAxisResolvesOnItsOwn() {
        XCTAssertTrue(DetailSettings.identity.decodeValues(baseline: .measured).isEmpty)

        var one = DetailSettings.identity
        one[.luminanceNR] = 100
        let values = one.decodeValues(baseline: leica)
        XCTAssertEqual(values.luminanceNR, 1)
        XCTAssertNil(values.colorNR)
        XCTAssertNil(values.sharpness)
        XCTAssertNil(values.detail)

        // A document that *stores* the default positions still assigns nothing: the guard is on the
        // value, not on the way it got there.
        let parked = DetailSettings(luminanceNR: 0, colorNR: 50, sharpness: 50, detail: 0)
        XCTAssertFalse(parked.isIdentity, "it carries four positions…")
        XCTAssertTrue(parked.decodeValues(baseline: leica).isEmpty, "…and none of them is an assignment")

        // The measured baseline is per body and per axis: colour NR and sharpness are **not** 0.
        XCTAssertEqual(DetailBaseline.measured.colorNR, 0.5)
        XCTAssertEqual(DetailBaseline.measured.sharpness, 0.5)
        XCTAssertEqual(DetailBaseline.measured.luminanceNR, 0)
        XCTAssertEqual(DetailBaseline.measured.detail, 0)
    }

    /// Requirement "out of travel is clamped, not leaked", and non-finite values never reach a filter.
    func testQuantizedAndClamped() {
        let q = DetailSettings(luminanceNR: 30.4, colorNR: 12.6, sharpness: 200, detail: .infinity).quantized()
        XCTAssertEqual(q.luminanceNR, 30)
        XCTAssertEqual(q.colorNR, 13)
        XCTAssertEqual(q.sharpness, 100, "clamped to the slider travel, not to the filter range")
        XCTAssertNil(q.detail, "infinity is not a slider position")
        XCTAssertNil(DetailSettings(luminanceNR: .nan).clamped().luminanceNR)
        XCTAssertTrue(DetailSettings(luminanceNR: .nan).quantized().isIdentity)
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

    /// Requirement 3 (the key half): a document parked on the default positions carries **no** "已改"
    /// marker for the four fields — the untouched panel is the only state with no `dt=` at all, and
    /// `nil` (not 0, not 50) is how a document spells that.
    func testDefaultDocumentCarriesNoDetailMarker() {
        XCTAssertNil(DetailSettings.identity.decodeComponent)
        XCTAssertEqual(DetailSettings.identity.summary, "NR 默认 · 色彩 默认 · 细节 默认 · 锐化 默认")

        // Back to the default from a real value: the marker disappears again.
        var s = DetailSettings.identity
        s.setPosition(30, .colorNR, in: leica)
        XCTAssertEqual(s.decodeComponent, "dt=nr·,c30,s·,d·")
        s.setPosition(50, .colorNR, in: leica)
        XCTAssertNil(s.decodeComponent, "a slider back on its default must stop marking the key")
    }

    /// Each of the four axes is a decode input: it moves the document's decode key, the rung
    /// identity **and** the on-disk cache key, and putting the value back restores all three.
    func testEachAxisMovesEveryDecodeKeyAndReturnsHome() {
        let base = EditModel.neutral
        let homeInputs = base.decodeInputs
        let homeDocumentKey = base.decodeKey
        let homeRung = base.decodeInputs.appending(to: "photo")
        let homeCache = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8").digest

        for axis in DetailAxis.allCases {
            for value in [30.0, 100.0] {
                var doc = base
                doc.detailSettings[axis] = value
                XCTAssertNotEqual(doc.decodeInputs, homeInputs, "\(axis) did not move decodeInputs")
                XCTAssertNotEqual(doc.decodeKey, homeDocumentKey, "\(axis) did not move decodeKey")
                XCTAssertNotEqual(doc.decodeInputs.appending(to: "photo"), homeRung,
                                  "\(axis) did not move the rung identity")
                let cache = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8",
                                           detail: doc.detailSettings)
                XCTAssertNotEqual(cache.digest, homeCache, "\(axis) did not move DecodeCacheKey.digest")

                // …and back home hits the old key again — the whole point of a value-based key.
                doc.detailSettings[axis] = nil
                XCTAssertEqual(doc.decodeKey, homeDocumentKey)
                XCTAssertEqual(doc.decodeInputs.appending(to: "photo"), homeRung)
                XCTAssertEqual(DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8",
                                              detail: doc.detailSettings).digest, homeCache)
            }
        }
    }

    /// The key text itself, so a human can read what a buffer was developed with. 040's positions are
    /// unsigned 0…100; `·` is "this slider is on the body's default".
    func testDetailKeyTextIsStableAndReadable() {
        let doc = EditModel(detailSettings: DetailSettings(luminanceNR: 30, colorNR: 40,
                                                          sharpness: 60, detail: 10))
        XCTAssertEqual(doc.decodeInputs.detailComponent, "dt=nr30,c40,s60,d10")
        XCTAssertEqual(doc.decodeKey,
                       "recipe=\(DecodeRecipe.current);ver=auto;scale=1.0000;dt=nr30,c40,s60,d10")
        XCTAssertEqual(doc.decodeInputs.appending(to: "photo"), "photo|dt=nr30,c40,s60,d10")

        // Both decode inputs, in the one spelling: the white balance first (派单 011), then detail.
        var both = doc
        both.light.temperature = 5500
        both.light.tint = 0
        XCTAssertEqual(both.decodeInputs.appending(to: "photo"),
                       "photo|wb=5500K/+0|dt=nr30,c40,s60,d10")
    }

    /// A detail change is a **new development**, and it must be classified as one by the one decision
    /// function — not as a render, and not as nothing.
    func testDetailSplitIsDecodeNotRender() {
        let old = EditModel.neutral
        for detail in [DetailSettings(luminanceNR: 30), DetailSettings(colorNR: 20),
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
    /// is not — and "on the default" (`nil`) is not the same document as "stored 0".
    func testDetailIsADirtyGroupForHistory() {
        var after = EditModel.neutral
        after.detailSettings.detail = 25
        XCTAssertTrue(EditHistory.dirtyGroups(from: .neutral, to: after).contains(.detail))
        XCTAssertFalse(EditHistory.isSemanticallyIdentical(.neutral, after))
        XCTAssertTrue(EditHistory.isSemanticallyIdentical(after, after))

        var cleared = EditModel.neutral
        cleared.detailSettings.colorNR = nil
        XCTAssertTrue(EditHistory.isSemanticallyIdentical(.neutral, cleared))
    }

    /// Documents: a missing key is the default, a present one round-trips, and an old document (no
    /// `detailSettings` at all) decodes to "untouched panel".
    func testDocumentCodingDefaultsAndRoundTrip() throws {
        let legacy = Data(#"{"schemaVersion":3,"processVersion":1}"#.utf8)
        let old = try JSONDecoder().decode(EditModel.self, from: legacy)
        XCTAssertEqual(old.detailSettings, .identity)
        XCTAssertEqual(old.decodeKey, EditModel.neutral.decodeKey)

        let doc = EditModel(detailSettings: DetailSettings(luminanceNR: 30, colorNR: 40,
                                                          sharpness: 20, detail: 10))
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(EditModel.self, from: data)
        XCTAssertEqual(back.detailSettings, doc.detailSettings)
        XCTAssertEqual(back.decodeKey, doc.decodeKey)

        // A partial object: missing axes are "on the default", not a decode failure.
        let partial = try JSONDecoder().decode(DetailSettings.self,
                                              from: Data(#"{"colorNR":40}"#.utf8))
        XCTAssertEqual(partial, DetailSettings(colorNR: 40))
        XCTAssertNil(partial.luminanceNR)

        // The default document writes no detail keys at all.
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(DetailSettings.identity), as: UTF8.self),
                       "{}")
    }

    /// 031's −100…+100 documents: the format is unreleased (`processVersion` is 2), so there is no
    /// migration — but a negative position cannot exist in the new semantics, and reading it as "a
    /// little less NR than Apple chose" would silently switch the body's noise reduction off. It
    /// therefore falls back to the axis' default; positive values are simply clamped to 0…100.
    func testOldDocumentsAreClampedAndNegativesFallBackToTheDefault() throws {
        let old = try JSONDecoder().decode(DetailSettings.self, from: Data(
            #"{"luminanceNR":-40,"colorNR":-20,"sharpness":150,"detail":30}"#.utf8))
        XCTAssertNil(old.luminanceNR, "a negative position is a pre-040 document, not an instruction")
        XCTAssertNil(old.colorNR)
        XCTAssertEqual(old.sharpness, 100, "clamped to the new travel")
        XCTAssertEqual(old.detail, 30)
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
              "sh=\(baseline.sharpness) d=\(baseline.detail) " +
              "defaults=\(DetailAxis.panelOrder.map { "\($0.rawValue):\($0.defaultPosition(in: baseline))" })")

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

        // Positions chosen away from this body's defaults (0/50/0/50), so all four are assignments.
        let settings = DetailSettings(luminanceNR: 30, colorNR: 40, sharpness: 20, detail: 55)
        let expected = settings.quantized().decodeValues(baseline: baseline)
        XCTAssertEqual(try XCTUnwrap(expected.luminanceNR), 0.30, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(expected.colorNR), 0.40, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(expected.sharpness), 0.20, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(expected.detail), 0.55, accuracy: 1e-9)

        // A default document assigns nothing at all: every property keeps the value Apple reported.
        let untouched = try RAWDecoder.applyDetail(.identity, to: filter, baseline: baseline)
        XCTAssertTrue(untouched.isEmpty)
        XCTAssertEqual(Double(filter.colorNoiseReductionAmount), baseline.colorNR, accuracy: 1e-6,
                       "a parked slider must not replace Apple's 0.5 colour NR with 0")
        XCTAssertEqual(Double(filter.sharpnessAmount), baseline.sharpness, accuracy: 1e-6)

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

    /// The default position of the live body assigns nothing to the live filter either — the claim
    /// "the panel opens on the body's own numbers, and touching nothing costs nothing" in one test.
    func testTheLiveDefaultPositionsAssignNothing() throws {
        let url = try fixtureURL()
        let filter = try XCTUnwrap(CIRAWFilter(imageURL: url))
        let baseline = RAWDecoder.detailBaseline(of: filter)

        var parked = DetailSettings.identity
        for axis in DetailAxis.allCases {
            parked[axis] = axis.defaultPosition(in: baseline)
        }
        let applied = try RAWDecoder.applyDetail(parked, to: filter, baseline: baseline)
        XCTAssertTrue(applied.isEmpty, "default positions assigned something: \(applied.summary)")
        XCTAssertEqual(Double(filter.colorNoiseReductionAmount), baseline.colorNR, accuracy: 1e-6)
        XCTAssertEqual(Double(filter.sharpnessAmount), baseline.sharpness, accuracy: 1e-6)
        XCTAssertEqual(Double(filter.detailAmount), baseline.detail, accuracy: 1e-6)
        XCTAssertEqual(Double(filter.luminanceNoiseReductionAmount), baseline.luminanceNR, accuracy: 1e-6)
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

        // …and what the production path does with a document that carries an out-of-travel value:
        // 1000 is clamped to the top of the travel (100 → 1.0), not handed to the filter as 10.0.
        let extremes = DetailSettings(luminanceNR: 500, colorNR: 500, sharpness: 500, detail: 500)
        let applied = try RAWDecoder.applyDetail(extremes, to: filter)
        XCTAssertEqual(Double(filter.luminanceNoiseReductionAmount), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(filter.colorNoiseReductionAmount), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(filter.sharpnessAmount), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(filter.detailAmount), 1, accuracy: 1e-6)
        XCTAssertEqual(applied.summary, "nr=1.00 c=1.00 sh=1.00 d=1.00")
    }

    // MARK: - 4. the pixels

    /// Requirement 3: an untouched panel changes **nothing** — and neither does a document that spells
    /// the default positions out. Both are byte claims, against a decode that never mentioned the four
    /// properties.
    func testDefaultDetailIsByteIdenticalAndAssignsNothing() throws {
        let url = try fixtureURL()
        let bare = try decoder().decodeDetailed(url, options: DecodeOptions(scale: probeScale))
        let identity = try decoder().decodeDetailed(url, options: DecodeOptions(scale: probeScale,
                                                                                detail: .identity))
        XCTAssertTrue(identity.detailApplied.isEmpty,
                      "a default document must not touch the four properties: \(identity.detailApplied.summary)")
        XCTAssertEqual(identity.image.sha256(), bare.image.sha256(),
                       "the untouched document is not byte-identical to the plain decode")

        // The panel opens on the body's default positions: spelling all four of them out is still
        // "assign nothing", so the pixels cannot move (this is the 040 regression that matters).
        var parked = DetailSettings.identity
        for axis in DetailAxis.allCases { parked[axis] = axis.defaultPosition(in: identity.detailBaseline) }
        let parkedDecode = try decoder().decodeDetailed(url, options: DecodeOptions(scale: probeScale,
                                                                                   detail: parked))
        XCTAssertTrue(parkedDecode.detailApplied.isEmpty,
                      "the default positions assigned: \(parkedDecode.detailApplied.summary)")
        XCTAssertEqual(parkedDecode.image.sha256(), bare.image.sha256(),
                       "a document parked on the default positions moved the pixels")

        // The document-level spelling of the same claim.
        XCTAssertEqual(EditModel.neutral.decodeInputs.detail, .identity)
        print("default decode sha256 bare=\(bare.image.sha256()) " +
              "identity=\(identity.image.sha256()) parked=\(parkedDecode.image.sha256()) " +
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
        for axis in DetailAxis.allCases {
            var settings = DetailSettings.identity
            settings[axis] = 100
            let image = try decoder().decodeDetailed(url,
                                                     options: DecodeOptions(scale: probeScale,
                                                                            detail: settings)).image
            let diff = Self.differingSamples(base.image.rgba, image.rgba)
            report.append("\(axis.rawValue)=\(diff)")
            if diff > 0 { moved.append(axis.rawValue) }
        }
        print("decoder v\(base.capabilities.effectiveVersion): samples moved by 100 — "
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
            for axis in DetailAxis.allCases {
                var settings = DetailSettings.identity
                settings[axis] = 100
                let image = try decoder().decodeDetailed(url,
                                                         options: DecodeOptions(decoderVersion: version,
                                                                                scale: probeScale,
                                                                                detail: settings)).image
                let diff = Self.differingSamples(base.image.rgba, image.rgba)
                line += " \(axis.rawValue)=\(diff)"
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
    /// to the old value hits the old one — no second development. 040: "back to the old value" is now
    /// "back to the default position", i.e. the field is cleared.
    func testCacheKeyHitsTheOldBufferAfterReturningHome() throws {
        let url = try fixtureURL()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-detail-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LinearImageStore(directory: dir)

        func key(_ detail: DetailSettings) -> DecodeCacheKey {
            DecodeCacheKey(fileSHA256: "sha", decoderVersion: "8", scale: probeScale, detail: detail)
        }

        let base = try decoder().decodeDetailed(url, options: DecodeOptions(scale: probeScale))
        // 040: the panel clears the field when a slider comes back to its default, so "home" is the
        // untouched document — and that is the key a returning drag must hit.
        XCTAssertNil(DetailSettings.identity.decodeComponent)
        XCTAssertTrue(base.detailApplied.isEmpty)

        let first = DetailSettings(luminanceNR: 40)
        let second = DetailSettings(luminanceNR: 60)
        let image = try decoder().decode(url, options: DecodeOptions(scale: probeScale, detail: first))

        XCTAssertNil(try store.load(key(first)), "nothing written yet")
        try store.save(image, key: key(first))
        XCTAssertEqual(try store.load(key(first))?.sha256(), image.sha256(),
                       "the same document did not hit the buffer it just wrote")
        XCTAssertNil(try store.load(key(second)), "a different detail value must not hit it")

        // Back home: the very same bytes, with the pixel hash of the first development.
        let home = try store.load(key(first))
        XCTAssertEqual(home?.sha256(), image.sha256())
        XCTAssertEqual(key(first).digest, DecodeCacheKey(fileSHA256: "sha", decoderVersion: "8",
                                                         scale: probeScale,
                                                         detail: first).digest)
    }

    // MARK: - helpers

    private func baselineKeyPath(_ axis: DetailAxis) -> KeyPath<DetailBaseline, Double> {
        switch axis {
        case .luminanceNR: return \.luminanceNR
        case .colorNR: return \.colorNR
        case .detail: return \.detail
        case .sharpness: return \.sharpness
        }
    }

    private static func differingSamples(_ a: [Float16], _ b: [Float16]) -> Int {
        guard a.count == b.count else { return max(a.count, b.count) }
        var n = 0
        for i in 0..<a.count where a[i] != b[i] { n += 1 }
        return n
    }
}
