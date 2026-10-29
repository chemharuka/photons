import XCTest
import CoreImage
@testable import PhotonsCore

/// 派单 031 / 040 / 042 — 降噪 / 色彩降噪 / 细节 / 锐化 是**解码**参数（`CIRAWFilter`），不是后处理。
///
/// 040 改的是**单位**：滑杆显示位置，默认位置 = 该机身在那一根轴上的基线换算出来的位置
/// （Leica L1030433 → `0 / 50 / 0 / 50`，R5 锐化 → 100，Sony ARW 降噪 → 38），而**停在默认位置
/// = 不赋值**（031 的纪律：写 0 进色彩降噪会关掉 Apple 的一半降噪）。
///
/// 042 改的是**量程**，按 Apple 头文件的 amount 上限分裂（`CIRAWFilter.h`）：
///
///   · 降噪 / 色彩降噪 / 锐化：位置 0…100 → amount 0…1（`h:115-138`），`位置 / 100`；
///   · 细节：位置 **0…30** → amount **0…3**（`h:148-154`），`位置 / 10`——042 之前四根共用
///     0…100，细节只用到文档上限的 1/3。
///
/// The tests here are the contract of that sentence, in five groups:
///
///  1. **The mapping.** Each axis has its own travel and its own position → amount divisor; the
///     default position is the body's, not a constant; a position at the default assigns nothing.
///  2. **The migration.** A schema-5 document's `detail` position (0…100) is divided by 10, which
///     keeps the amount — and therefore the look — and touches no other axis.
///  3. **The decode key.** All four are decode inputs, so every one of them moves `DecodeInputs`,
///     the rung identity and `DecodeCacheKey`; putting the slider back on its default must hit the
///     old key again. A document that never touched the panel must produce the **byte-identical**
///     keys of 030.
///  4. **The pixels.** The four properties are assigned before `CIRAWFilter` produces an image, and
///     the untouched document — and one parked on its default positions — is byte-for-byte the
///     pre-031 decode. The 细节 axis at its new right end (3.0) must move the picture more than the
///     old right end (1.0) did, measured in 8-bit codes.
///  5. **The measurement.** What this machine's decoder actually honours, printed and pinned — see
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

    /// Requirement 2 (042): **each axis has its own travel** — 细节 0…30 (amount 0…3), the other
    /// three 0…100 (amount 0…1) — both ends are reachable, and anything outside is clamped rather
    /// than stored.
    func testEachAxisTravelsItsOwnRangeAndClamps() {
        XCTAssertEqual(DetailAxis.detail.range, 0...30, "细节 0…30 → amount 0…3 (CIRAWFilter.h:148-154)")
        for axis in [DetailAxis.luminanceNR, .colorNR, .sharpness] {
            XCTAssertEqual(axis.range, 0...100, "\(axis) keeps the 0…100 → 0…1 travel")
            XCTAssertEqual(axis.maxAmount, 1)
            XCTAssertEqual(axis.positionPerAmount, 100)
        }
        XCTAssertEqual(DetailAxis.detail.maxAmount, 3, "Apple's header: 3 is maximum detail enhancement")
        XCTAssertEqual(DetailAxis.detail.positionPerAmount, 10, "position / 10 = detailAmount")
        for axis in DetailAxis.allCases {
            XCTAssertEqual(axis.step, 1, "\(axis) quantizes to whole position units")
            XCTAssertEqual(axis.format, "%.0f", "整数，没有百分号")
        }

        for axis in DetailAxis.allCases {
            var s = DetailSettings.identity
            let top = axis.range.upperBound

            s.setPosition(0, axis, in: leica)
            XCTAssertEqual(s.position(axis, in: leica), 0, "\(axis) left end")
            s.setPosition(top, axis, in: leica)
            XCTAssertEqual(s.position(axis, in: leica), top, "\(axis) right end")

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
            XCTAssertEqual(s[axis], top, "\(axis) above its right end")

            // Quantized to the step, and back on the default clears the field instead of storing it.
            s.setPosition(30.4, axis, in: leica)
            XCTAssertEqual(s[axis], min(30, top), "\(axis) is not quantized")
            s.setPosition(axis.defaultPosition(in: leica), axis, in: leica)
            XCTAssertNil(s[axis], "\(axis) on its default must be nil, not a number")
        }
    }

    /// 042's three acceptance assertions, verbatim: 30 is the new right end and assigns 3.0, 100 is
    /// clamped to 30, and the Leica's detail baseline sits at position 0 — so 15 is *not* its default
    /// but 0 is; on a body whose baseline is 0.5 the default position is 15 and 15 clears the field.
    func testTheDetailTravelOfThirtyMapsToThreeAndClampsAtThirty() {
        var s = DetailSettings.identity
        s.setPosition(30, .detail, in: leica)
        XCTAssertEqual(s.detail, 30, "30 is inside the travel and is not the Leica's default")
        XCTAssertEqual(s.decodeValues(baseline: leica).detail ?? -1, 3.0, accuracy: 1e-9,
                       "position 30 must assign detailAmount 3.0")

        s.setPosition(100, .detail, in: leica)
        XCTAssertEqual(s.detail, 30, "100 is out of the 0…30 travel: clamped to 30, not stored")

        // A body whose detail baseline is 0.5 (its own value is half of Apple's range) opens at 15.
        let half = DetailBaseline(luminanceNR: 0, colorNR: 0.5, sharpness: 0.5, detail: 0.5)
        XCTAssertEqual(DetailAxis.detail.defaultPosition(in: half), 15)
        var parked = DetailSettings.identity
        parked.setPosition(15, .detail, in: half)
        XCTAssertNil(parked.detail, "15 IS the default position on that body, so it must write nil")
        XCTAssertNil(parked.decodeValues(baseline: half).detail, "…and assign nothing")
        // …and the Leica's own default is 0, so 15 is a real assignment there (amount 1.5).
        var onLeica = DetailSettings.identity
        onLeica.setPosition(15, .detail, in: leica)
        XCTAssertEqual(onLeica.detail, 15)
        XCTAssertEqual(onLeica.decodeValues(baseline: leica).detail ?? -1, 1.5, accuracy: 1e-9)
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

    /// Requirement 2 (the mapping half): `position / positionPerAmount` — `/100` on the three 0…1
    /// axes, `/10` on 细节 — and a position **at the default** assigns nothing at all. 031's rule
    /// survives the renormalisation: it is now "don't write the baseline", not "don't write 0".
    func testPositionMapsToThePropertyAndTheDefaultAssignsNothing() {
        func amount(_ slider: Double?, _ axis: DetailAxis = .luminanceNR,
                    _ baseline: Double = 0.5) -> Double? {
            DetailSettings.decodeAmount(slider: slider, axis: axis, baseline: baseline)
        }

        // Straight division: 0 → 0.0 is a real assignment when the body's own value is 0.5.
        XCTAssertEqual(amount(0), 0)
        XCTAssertEqual(amount(30)!, 0.30, accuracy: 1e-9)
        XCTAssertEqual(amount(55)!, 0.55, accuracy: 1e-9)
        XCTAssertEqual(amount(100), 1)
        XCTAssertEqual(amount(100, .luminanceNR, 0), 1)

        // 042: the 细节 axis divides by 10, because Apple's `detailAmount` tops out at 3.
        XCTAssertEqual(amount(30, .detail, 0), 3)
        XCTAssertEqual(amount(15, .detail, 0)!, 1.5, accuracy: 1e-9)
        XCTAssertEqual(amount(10, .detail, 0), 1, "the old right end (0…100's 100 → amount 1.0) is 10 now")
        XCTAssertEqual(amount(1_000, .detail, 0), 3, "clamped to 30 → 3.0, not 10.0")

        // The default positions of all three bodies assign nothing.
        for (name, baseline) in [("leica", leica), ("r5", canonR5), ("sony", sonyARW)] {
            for axis in DetailAxis.allCases {
                let position = axis.defaultPosition(in: baseline)
                let value = DetailSettings.decodeAmount(slider: position, axis: axis,
                                                        baseline: baseline[keyPath: baselineKeyPath(axis)])
                XCTAssertNil(value, "\(name) \(axis) at its default position \(position) assigned \(value ?? 0)")
            }
        }
        XCTAssertNil(amount(50))
        XCTAssertNil(amount(0, .luminanceNR, 0))
        XCTAssertNil(amount(0, .detail, 0))
        XCTAssertNil(amount(nil), "nil = untouched")

        // A default that does not land on an integer (Sony 0.377 → 38) assigns nothing either, while
        // one step below it is a real 0.37.
        XCTAssertNil(amount(38, .luminanceNR, 0.377))
        XCTAssertEqual(amount(37, .luminanceNR, 0.377)!, 0.37, accuracy: 1e-9)

        // Clamped, not overflowed: the filter itself accepts 2.0 and −0.5 verbatim
        // (`testTheFilterDoesNotClampSoTheMappingMust`), so an out-of-travel position must not leak.
        XCTAssertEqual(amount(1_000), 1)
        XCTAssertEqual(amount(-1_000), 0)
        XCTAssertEqual(amount(1_000, .detail, 0), 3)
        XCTAssertEqual(amount(-1_000, .detail, 0.5), 0, "clamped to 0, which is not 0.5's default position")

        // Exhaustive, per axis: every position, five plausible baselines, always inside the axis'
        // own amount range, and `nil` exactly on the default position (baseline × travel).
        for axis in DetailAxis.allCases {
            let per = axis.positionPerAmount
            let top = axis.range.upperBound
            for baseline in [0.0, 0.004, 0.377, 0.5, 1.0] {
                let defaultPosition = (baseline * top).rounded()
                for slider in stride(from: 0.0, through: top, by: top / 20) {
                    let v = DetailSettings.decodeAmount(slider: slider, axis: axis, baseline: baseline)
                    if abs(slider - baseline * top) < 0.5 {
                        XCTAssertNil(v, "\(axis) slider \(slider) baseline \(baseline) is the default position")
                        continue
                    }
                    let unwrapped = v ?? -1
                    XCTAssertEqual(unwrapped, slider / per, accuracy: 1e-9,
                                   "\(axis) slider \(slider) baseline \(baseline)")
                    XCTAssertGreaterThanOrEqual(unwrapped, 0)
                    XCTAssertLessThanOrEqual(unwrapped, axis.maxAmount)
                }
                XCTAssertEqual(DetailSettings.decodeAmount(slider: defaultPosition, axis: axis,
                                                           baseline: baseline), nil,
                               "\(axis) baseline \(baseline): the default position assigned something")
            }
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

        // 042: each axis has its own ceiling — 200 on 细节 is 30 (amount 3.0), not 100.
        XCTAssertEqual(DetailSettings(detail: 200).quantized().detail, 30)
        XCTAssertEqual(DetailSettings(detail: 29.6).quantized().detail, 30)
        XCTAssertEqual(DetailSettings(detail: 12.4).quantized().detail, 12, "细节 quantizes to whole units")
        XCTAssertEqual(DetailSettings(detail: 12).decodeValues(baseline: leica).detail ?? -1, 1.2,
                       accuracy: 1e-9, "one 细节 unit is 0.1 of detailAmount")
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
                       KeyBuilder.digest(of: "abc|8|0.0000|1.0000|full|extendedLinearSRGB|v3-lens"),
                       "the digest of the current (103) decode recipe key text")
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
            for value in [axis.range.upperBound * 0.3, axis.range.upperBound] {
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
                       DetailSettings(sharpness: 40), DetailSettings(detail: 20)] {
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

    /// 031's −100…+100 documents: negatives cannot exist in the new semantics, and reading one as "a
    /// little less NR than Apple chose" would silently switch the body's noise reduction off, so they
    /// fall back to the axis' default.
    ///
    /// 042: `DetailSettings` on its own has **no version** — the document's is one level up — so its
    /// decode admits the legacy 0…100 envelope on 细节 (`DetailAxis.decodeCeiling`) instead of
    /// clamping to 0…30. Clamping to 30 here would turn a schema-5 `detail: 100` (amount 1.0) into
    /// amount 0.3 before the migration ever ran. `EditModel` is where the value is normalised —
    /// see `testASchemaFiveDetailPositionIsDividedByTen`.
    func testOldDocumentsAreClampedAndNegativesFallBackToTheDefault() throws {
        let old = try JSONDecoder().decode(DetailSettings.self, from: Data(
            #"{"luminanceNR":-40,"colorNR":-20,"sharpness":150,"detail":30}"#.utf8))
        XCTAssertNil(old.luminanceNR, "a negative position is a pre-040 document, not an instruction")
        XCTAssertNil(old.colorNR)
        XCTAssertEqual(old.sharpness, 100, "clamped to the new travel")
        XCTAssertEqual(old.detail, 30, "kept as decoded: the migration needs the old spelling")

        // …and the legacy envelope is exactly the old travel: 100 survives the decode untouched,
        // 500 does not.
        let legacy = try JSONDecoder().decode(DetailSettings.self, from: Data(
            #"{"detail":100}"#.utf8))
        XCTAssertEqual(legacy.detail, 100)
        let wild = try JSONDecoder().decode(DetailSettings.self, from: Data(
            #"{"detail":500}"#.utf8))
        XCTAssertEqual(wild.detail, 100, "clamped to the legacy ceiling, not to 0…30 and not to 500")
    }

    /// 042's migration, at the document level (the only level that knows the version): the 细节
    /// position is divided by 10, which preserves the **amount** — and therefore the look — while
    /// the other three axes are left exactly as they were.
    func testASchemaFiveDetailPositionIsDividedByTen() throws {
        func migrate(_ json: String) throws -> EditModel {
            try JSONDecoder().decode(EditModel.self, from: Data(json.utf8))
        }

        // Old 100 → amount 1.0 → new position 10 (which still means amount 1.0).
        let old = try migrate(#"""
        {"schemaVersion":5,"processVersion":2,
         "detailSettings":{"luminanceNR":30,"colorNR":40,"sharpness":60,"detail":100}}
        """#)
        XCTAssertEqual(old.detailSettings.detail, 10, "old 100 → new 10")
        XCTAssertEqual(old.detailSettings.decodeValues(baseline: leica).detail ?? -1, 1.0, accuracy: 1e-9,
                       "the amount — the look — is what the migration preserves")
        // The other three axes are untouched, byte for byte.
        XCTAssertEqual(old.detailSettings.luminanceNR, 30)
        XCTAssertEqual(old.detailSettings.colorNR, 40)
        XCTAssertEqual(old.detailSettings.sharpness, 60)
        // 2026-10-28: the current version is 9 (色彩分级's nine numbers, on top of 黑白's switch and
        // mixes); the migration still divides a schema-5 position by ten and stamps the **current**
        // version.
        // 2026-10-28: the current version is 9 (纹理/清晰度/去雾); the migration still divides a
        // schema-5 position by ten and stamps the **current** version.
        // 2026-10-28: the current version is 10 (黑白 的 switch 与八段 mix 是 8，90° 旋转的
        // `geometry.quarterTurns` 是 9，修复画笔的 `healSpots` 是 10); the migration still divides a
        // schema-5 position by ten and stamps the **current** version.
        XCTAssertEqual(EditModel.currentSchemaVersion, 10)

        // Old 50 → amount 0.5 → new position 5.
        let half = try migrate(#"""
        {"schemaVersion":5,"processVersion":2,"detailSettings":{"detail":50}}
        """#)
        XCTAssertEqual(half.detailSettings.detail, 5, "old 50 → new 5")
        XCTAssertEqual(half.detailSettings.decodeValues(baseline: leica).detail ?? -1, 0.5, accuracy: 1e-9)

        // A default document stays a default document (no detail key at all).
        let untouched = try migrate(#"{"schemaVersion":5,"processVersion":2}"#)
        XCTAssertTrue(untouched.detailSettings.isIdentity)

        // A schema-6 document is **not** divided again: 10 means 10 (amount 1.0), and an
        // out-of-travel 100 written by hand lands on the axis' own ceiling.
        let current = try migrate(#"""
        {"schemaVersion":6,"processVersion":2,"detailSettings":{"detail":10}}
        """#)
        XCTAssertEqual(current.detailSettings.detail, 10, "a schema-6 position must not be migrated twice")
        let handEdited = try migrate(#"""
        {"schemaVersion":6,"processVersion":2,"detailSettings":{"detail":100}}
        """#)
        XCTAssertEqual(handEdited.detailSettings.detail, 30, "clamped to 0…30, amount 3.0")

        // **The migration must not run twice.** `/10` is not idempotent, so a converted document is
        // stamped with the new version; re-encoding and decoding it again must keep position 10.
        XCTAssertEqual(old.schemaVersion, EditModel.currentSchemaVersion,
                       "a document whose 细节 position was converted is now a current-schema document")
        let roundTripped = try JSONDecoder().decode(EditModel.self,
                                                    from: try JSONEncoder().encode(old))
        XCTAssertEqual(roundTripped.detailSettings.detail, 10, "10 must not be divided again on reload")
        XCTAssertEqual(roundTripped.detailSettings, old.detailSettings)

        // …and a schema-5 document with **no** detail position keeps its version, so the
        // `BlackLevelTests` discipline (a doc keeps its own version) still holds where nothing was
        // converted.
        XCTAssertEqual(untouched.schemaVersion, 5, "nothing was converted, so the version is untouched")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(untouched), as: UTF8.self)
        XCTAssertTrue(text.contains("\"schemaVersion\":5"), "still written back as schema 5")

        print("042 migration: schema-5 detail 100 → \(old.detailSettings.detail ?? -1)"
              + " (amount \(old.detailSettings.decodeValues(baseline: leica).detail ?? -1)) · "
              + "50 → \(half.detailSettings.detail ?? -1)"
              + " (amount \(half.detailSettings.decodeValues(baseline: leica).detail ?? -1))"
              + " · version stamped \(old.schemaVersion)")
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
        let settings = DetailSettings(luminanceNR: 30, colorNR: 40, sharpness: 20, detail: 12)
        let expected = settings.quantized().decodeValues(baseline: baseline)
        XCTAssertEqual(try XCTUnwrap(expected.luminanceNR), 0.30, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(expected.colorNR), 0.40, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(expected.sharpness), 0.20, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(expected.detail), 1.20, accuracy: 1e-9,
                       "042: 细节 divides by 10, so 12 is amount 1.2")

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
        // 500 is clamped to the top of each axis' own travel (100 → 1.0 for the three 0…1 axes,
        // 30 → 3.0 for 细节), not handed to the filter as 5.0 or 50.0.
        let extremes = DetailSettings(luminanceNR: 500, colorNR: 500, sharpness: 500, detail: 500)
        let applied = try RAWDecoder.applyDetail(extremes, to: filter)
        XCTAssertEqual(Double(filter.luminanceNoiseReductionAmount), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(filter.colorNoiseReductionAmount), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(filter.sharpnessAmount), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(filter.detailAmount), 3, accuracy: 1e-6,
                       "042: 细节 tops out at Apple's 3.0, not at 1.0")
        XCTAssertEqual(applied.summary, "nr=1.00 c=1.00 sh=1.00 d=3.00")
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
            settings[axis] = axis.range.upperBound
            let image = try decoder().decodeDetailed(url,
                                                     options: DecodeOptions(scale: probeScale,
                                                                            detail: settings)).image
            let diff = Self.differingSamples(base.image.rgba, image.rgba)
            report.append("\(axis.rawValue)=\(diff)")
            if diff > 0 { moved.append(axis.rawValue) }
        }
        print("decoder v\(base.capabilities.effectiveVersion): samples moved at each axis' right end — "
              + report.joined(separator: " "))
        XCTAssertFalse(moved.isEmpty,
                       "none of the four detail properties moved a single sample; the sliders are dead "
                       + "(\(report.joined(separator: " ")))")
        // Whatever the body honours, the assignment itself must have landed.
        let l = try decoder().decodeDetailed(url, options: DecodeOptions(scale: probeScale,
                                                                        detail: DetailSettings(luminanceNR: 50)))
        XCTAssertNotNil(l.detailApplied.luminanceNR)
    }

    /// 042's pixel acceptance: the 细节 slider's **new** right end is really three times the old one.
    ///
    /// Three full-size decodes of the fixture at the default decoder version — untouched, the old
    /// ceiling (_amount 1.0_, i.e. what position `100` meant before 042 and what position `10` means
    /// now) and the new ceiling (position `30`, amount 3.0). The frame hash must move, and the largest
    /// 8-bit channel move at the new end must be **larger** than at the old one: that is what "the
    /// extra travel reaches the pixels, not only the label" means.
    func testTheDetailTravelOfThreeMovesThePixelsMoreThanTheOldCeilingDid() throws {
        let url = try fixtureURL()
        let untouched = try decoder().decodeDetailed(url, options: DecodeOptions())
        func frame(_ position: Double) throws -> RAWDecoder.DecodeOutcome {
            try decoder().decodeDetailed(url, options: DecodeOptions(
                detail: DetailSettings(detail: position)))
        }
        let old = try frame(10)     // amount 1.0 — the pre-042 right end, in today's spelling
        let new = try frame(30)     // amount 3.0 — Apple's documented maximum

        XCTAssertNil(untouched.detailApplied.detail, "0 is this body's baseline: nothing assigned")
        XCTAssertEqual(try XCTUnwrap(old.detailApplied.detail), 1.0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(new.detailApplied.detail), 3.0, accuracy: 1e-6)

        let oldDelta = Self.maxCodeDelta(untouched.image.rgba, old.image.rgba)
        let newDelta = Self.maxCodeDelta(untouched.image.rgba, new.image.rgba)
        let oldMoved = Self.differingSamples(untouched.image.rgba, old.image.rgba)
        let newMoved = Self.differingSamples(untouched.image.rgba, new.image.rgba)
        print("042 细节 pixels (full size, v\(untouched.capabilities.effectiveVersion)): "
              + "\(untouched.image.width)×\(untouched.image.height) · amount 1.0 → maxΔ "
              + String(format: "%.2f", oldDelta) + " codes / \(oldMoved) samples · amount 3.0 → maxΔ "
              + String(format: "%.2f", newDelta) + " codes / \(newMoved) samples · sha "
              + "\(untouched.image.sha256().prefix(12))/\(old.image.sha256().prefix(12))"
              + "/\(new.image.sha256().prefix(12))")

        XCTAssertNotEqual(new.image.sha256(), untouched.image.sha256(),
                          "细节 30 must not render as the untouched frame")
        XCTAssertNotEqual(new.image.sha256(), old.image.sha256(),
                          "细节 30 must not render as the old ceiling either")
        XCTAssertGreaterThan(newDelta, oldDelta,
                             "the new right end (3.0) must move the picture more than the old one (1.0) "
                             + "did — otherwise the extra travel is only on the slider")
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
                settings[axis] = axis.range.upperBound
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

    /// The largest 8-bit sRGB channel move between two linear frames, over the samples that differ.
    ///
    /// `code` is `BwLevelsTests`' yardstick (sRGB code 0…255 of a scene-linear value), and the encode
    /// is evaluated **only** where the frames differ — a 60 MP pair shares essentially all of its
    /// samples, and 240 M `pow` calls would make this the slowest test in the suite.
    private static func maxCodeDelta(_ a: [Float16], _ b: [Float16]) -> Double {
        guard a.count == b.count else { return 255 }
        var worst = 0.0
        for i in 0..<a.count where a[i] != b[i] {
            let d = abs(code(a[i]) - code(b[i]))
            if d > worst { worst = d }
        }
        return worst
    }

    /// sRGB code 0…255 of a linear value (the same 8-bit yardstick `BwLevelsTests` uses).
    private static func code(_ v: Float16) -> Double {
        let x = max(Double(v), 0)
        let e = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return e * 255
    }
}
