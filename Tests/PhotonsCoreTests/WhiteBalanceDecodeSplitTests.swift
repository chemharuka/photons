import XCTest
import CryptoKit
@testable import PhotonsCore

/// 派单 011 A: the two parameter streams, asserted on the keys the pipeline actually uses.
///
/// The architecture is only worth anything if it is *checkable*: "changing the exposure must not
/// develop again" and "changing the temperature must" are two questions about one function pair
/// (`EditModel.decodeKey` / `EditModel.renderInputs`), and both are decided here without a GPU, a
/// file or a window. The decode-count half of the same claim runs against the real decoder in
/// `PhotonsUITests/WhiteBalanceSectionTests`.
///
/// What is pinned:
///
///   · **decodeKey ignores everything after the decode.** Exposure, contrast, highlights, shadows,
///     whites, blacks, highlight recovery, curve, colour, geometry, masks — none of them may move it,
///     because none of them can change a decoded pixel.
///   · **decodeKey moves on any white-balance change**, including the three-valued cases
///     (`nil` → a value, a value → `nil`, temperature-only, tint-only). `nil` is a state, not 0 K.
///   · **as shot is the historical key**, byte for byte: no component is appended, so the pre-006
///     `DecodeCacheKey` digest and the pre-009 rung identity are unchanged and every buffer already
///     on disk keeps hitting.
///   · **`RenderInputs` is insensitive to the white balance** and sensitive to the rest — the mirror
///     image of the first two rules.
final class WhiteBalanceDecodeSplitTests: XCTestCase {

    // MARK: - fixtures

    /// A document with something in every group, so a "nothing moved" assertion is not vacuous.
    private func busyDocument() -> EditModel {
        var e = EditModel()
        e.light.exposure = 0.75
        e.light.contrast = 20
        e.light.highlights = -30
        e.light.shadows = 15
        e.light.whites = 10
        e.light.blacks = -5
        e.light.highlightRecovery = 0.4
        e.curve.white = [CurvePoint(0, 0), CurvePoint(0.3, 0.25), CurvePoint(1, 1)]
        e.color.vibrance = 15
        e.color.saturation = -10
        e.geometry.rotationDegrees = 1.5
        e.geometry.crop = NormalizedRect(x: 0.1, y: 0.05, width: 0.8, height: 0.75)
        e.masks = [Mask(id: "m1", name: "m1")]
        return e
    }

    // MARK: - 1. the render half must not move the decode key

    /// Every render-side control, one at a time, on top of a document that already has a white
    /// balance — so "unchanged" cannot be an accident of both keys being the as-shot default.
    func testRenderSideChangesLeaveTheDecodeKeyAlone() {
        var base = busyDocument()
        base.light.temperature = 5200
        base.light.tint = 12
        let key = base.decodeKey
        let inputs = base.decodeInputs

        var exposure = base; exposure.light.exposure += 1.0
        var contrast = base; contrast.light.contrast -= 25
        var highlights = base; highlights.light.highlights = 40
        var shadows = base; shadows.light.shadows = -40
        var whites = base; whites.light.whites = 30
        var blacks = base; blacks.light.blacks = 30
        var recovery = base; recovery.light.highlightRecovery = 0.1
        var toneCurve = base
        toneCurve.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, 0.62), CurvePoint(1, 1)]
        var channelCurve = base
        channelCurve.curve.red = [CurvePoint(0, 0.02), CurvePoint(1, 0.98)]
        var colour = base; colour.color.vibrance = -35
        var bands = base; bands.color.bands[3].hue = 20
        var geometry = base; geometry.geometry.rotationDegrees = 3   // straighten is a render input
        var crop = base; crop.geometry.crop = NormalizedRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        var masks = base; masks.masks.append(Mask(id: "m2", name: "m2"))
        var vignette = base; vignette.effects.vignetteAmount = -40

        let cases: [(String, EditModel)] = [
            ("exposure", exposure), ("contrast", contrast), ("highlights", highlights),
            ("shadows", shadows), ("whites", whites), ("blacks", blacks),
            ("highlight recovery", recovery), ("RGB curve", toneCurve),
            ("channel curve", channelCurve), ("saturation/vibrance", colour),
            ("HSL band", bands), ("geometry", geometry), ("crop", crop), ("masks", masks),
            ("vignette", vignette),
        ]
        for (name, edited) in cases {
            XCTAssertEqual(edited.decodeKey, key, "\(name) moved the decode key — it would develop again")
            XCTAssertEqual(edited.decodeInputs, inputs, "\(name) moved decodeInputs")
            XCTAssertEqual(edited.splitFrom(base), .render,
                           "\(name) must classify as a render change")
            // …and the render half *did* see it, or the test is checking a no-op.
            XCTAssertNotEqual(edited.renderInputs, base.renderInputs,
                              "\(name) did not reach RenderInputs — the fixture edit did nothing")
        }
    }

    /// A whole document full of render-side edits is still one render, not one development.
    func testManyRenderEditsDoNotAccumulateIntoADecode() {
        let base = busyDocument()
        var edited = base
        edited.light.exposure = -2
        edited.light.contrast = 60
        edited.light.blacks = -50
        edited.curve.blue = [CurvePoint(0, 0.1), CurvePoint(1, 0.9)]
        edited.color.saturation = 40
        edited.effects.vignetteAmount = 25
        edited.geometry.flipHorizontal = true
        XCTAssertEqual(edited.decodeKey, base.decodeKey)
        XCTAssertEqual(edited.splitFrom(base), .render)
    }

    // MARK: - 2. the decode half always moves the decode key

    /// White balance is three-valued per axis, and every transition is a development: `nil` is "the
    /// file's own balance", not a number, and assigning the number the file reports is measured *not*
    /// to be a no-op (派单 006: 0.15–0.40 % of samples move).
    ///
    /// The transitions are walked **one at a time** (each compared with its predecessor). An
    /// all-distinct sweep over a list would fail on two documents that are legitimately the same
    /// document — `3500 K` → `nil` K with tint +30 is exactly "tint +30", and it must share that key.
    func testAnyWhiteBalanceChangeMovesTheDecodeKey() {
        var state = EditModel.neutral
        var sequence: [(String, EditModel)] = [("as shot", state)]

        var v = state; v.light.temperature = 3500
        sequence.append(("3500 K (nil tint)", v)); state = v
        var w = state; w.light.tint = 30
        sequence.append(("3500 K/+30", w)); state = w
        var x = state; x.light.tint = nil
        sequence.append(("3500 K (tint back to as shot)", x)); state = x
        var y = state; y.light.temperature = 3525
        sequence.append(("3525 K (one 25 K quantum)", y)); state = y
        var z = state; z.light.temperature = nil; z.light.tint = 31
        sequence.append(("as-shot K, tint +31", z)); state = z
        var p = state; p.light.tint = nil
        sequence.append(("back to as shot", p)); state = p
        var pinned = state
        pinned.light.temperature = 5871.6      // the file's own balance, pinned
        pinned.light.tint = 20.35
        sequence.append(("pinned to the as-shot numbers", pinned))

        for i in 1..<sequence.count {
            let (name, doc) = sequence[i]
            let (previousName, previous) = sequence[i - 1]
            XCTAssertNotEqual(doc.decodeKey, previous.decodeKey,
                              "“\(name)” shares a decode key with “\(previousName)”: one of them "
                              + "would be served the other's buffer")
            XCTAssertEqual(doc.splitFrom(previous), .decode,
                           "“\(previousName)” → “\(name)” must be a development")
            XCTAssertEqual(doc.renderInputs, previous.renderInputs,
                           "“\(name)” also moved RenderInputs — the test is measuring two things")
        }
        // The two directions the task names explicitly, on their own: nil → value and value → nil.
        XCTAssertEqual(sequence[1].1.decodeKey == sequence[0].1.decodeKey, false)
        XCTAssertEqual(sequence[6].1.decodeKey == sequence[0].1.decodeKey, true,
                       "the last step returns to the as-shot document, and must return to its key")
        XCTAssertNotEqual(sequence[1].1.decodeKey, sequence[2].1.decodeKey,
                          "explicit tint vs as-shot tint must not share a buffer")
    }

    // MARK: - 3. as shot is the historical key

    /// The compatibility promise, in one place: as shot appends **nothing**, so `decodeKey` is the
    /// neutral development's key, the rung identity is the bare photo identity, and the on-disk
    /// `DecodeCacheKey` digest is the exact SHA-256 the pre-006 code produced.
    func testAsShotDecodeKeyIsTheHistoricalValue() {
        let shot = EditModel.neutral
        XCTAssertTrue(shot.light.whiteBalance.isAsShot)
        XCTAssertEqual(shot.decodeInputs, DecodeInputs.asShot)
        XCTAssertEqual(shot.decodeKey, DecodeInputs.asShot.key, "as shot is the neutral development")

        // No component, so the rung identity is the pre-009 string — byte for byte.
        XCTAssertNil(shot.decodeInputs.whiteBalanceComponent)
        let photo = "248063fdc8786acc7fdac7362853bc7f46cd050927d3ed66fabe0e81991f33bb|A1B2"
        XCTAssertEqual(shot.decodeInputs.appending(to: photo), photo,
                       "as shot appended something to the rung identity — every resident rung's key moved")
        // …and a real document does append, in the one spelling both keys use.
        var warm = shot
        warm.light.temperature = 5500
        warm.light.tint = 0
        XCTAssertEqual(warm.decodeInputs.appending(to: photo), "\(photo)|wb=5500K/+0")

        // The on-disk key: the as-shot digest of a given file must equal the pinned pre-006 digest,
        // which is computed here from the historical component list rather than from the new code.
        let decoderVersion = "8"
        let file = "abc"
        let historical = ["abc", "8", String(format: "%.4f", Float(0)),
                          String(format: "%.4f", Float(1)), "full", "extendedLinearSRGB",
                          DecodeRecipe.current].joined(separator: "|")
        let historicalDigest = SHA256.hash(data: Data(historical.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let key = DecodeCacheKey(fileSHA256: file, decoderVersion: decoderVersion)
        XCTAssertEqual(key.digest, historicalDigest,
                       "the as-shot linear buffer key moved — every buffer on disk is orphaned")
        XCTAssertNotEqual(DecodeCacheKey(fileSHA256: file, decoderVersion: decoderVersion,
                                        whiteBalance: WhiteBalance(temperature: 5500, tint: 0)).digest,
                          key.digest,
                          "an explicit 5500 K document would be served the as-shot buffer")
    }

    // MARK: - 3b. the one entry point for a rung identity

    /// 派单 011 A's hard rule, as three assertions:
    ///
    ///   · **one entry point.** `DecodeInputs.appending(to:)` is the only function that may build a
    ///     rung identity, and as shot returns the photo identity **unchanged** — no suffix, so every
    ///     resident rung and every histogram cache key that predates the white balance still hits.
    ///   · **a render change does not touch it.** Exposure/contrast/curve/colour leave the rung
    ///     identity *and* the on-disk `DecodeCacheKey` text byte-identical — the second is the one
    ///     that would otherwise develop again on a cold start.
    ///   · **a white-balance change always does.** Any temperature/tint transition, including the
    ///     `nil` ones, is a different identity (and therefore a different development).
    ///
    /// It also pins where `wb=` is allowed to appear: in the rung identity and in the decode cache
    /// key, and **nowhere** in a stage material or a render key.
    func testTheRungIdentityHasOneEntryPointAndOnlyTheDecodeHalfMovesIt() {
        let photo = "L1030433|A1B2-C3D4"
        let asShot = EditModel.neutral
        XCTAssertEqual(asShot.decodeInputs.appending(to: photo), photo,
                       "as shot appended a suffix — the historical rung identity moved")

        // A render-side change: the identity and the decode cache key are the same text, byte for byte.
        var render = asShot
        render.light.exposure = 1.2
        render.light.contrast = 40
        render.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]
        render.color.vibrance = 30
        XCTAssertEqual(render.decodeInputs.appending(to: photo), photo,
                       "exposure/contrast/curve/colour moved the rung identity")
        func cacheKey(_ model: EditModel, file: String = "abc") -> DecodeCacheKey {
            DecodeCacheKey(fileSHA256: file, decoderVersion: "8", exposureEV: 0,
                           scale: 0.5, whiteBalance: model.light.whiteBalance)
        }
        XCTAssertEqual(cacheKey(render).keyText, cacheKey(asShot).keyText,
                       "a render-side change moved the on-disk decode cache key")
        XCTAssertFalse(cacheKey(asShot).keyText.contains("wb="),
                       "as shot put a white balance in the decode cache key")

        // A decode-side change: the identity moves, once, in the one spelling.
        var warm = render
        warm.light.temperature = 5500
        warm.light.tint = 0
        XCTAssertEqual(warm.decodeInputs.appending(to: photo), "\(photo)|wb=5500K/+0")
        XCTAssertNotEqual(warm.decodeInputs.appending(to: photo),
                          render.decodeInputs.appending(to: photo))
        XCTAssertTrue(cacheKey(warm).keyText.hasSuffix("|wb=5500K/+0"),
                      "the white balance is not the last (and only) component of the decode key")
        XCTAssertEqual(cacheKey(warm).keyText.components(separatedBy: "wb=").count, 2,
                       "``wb=`` appears more than once in the decode cache key")

        // `wb=` nowhere else: no stage material, and no render key, carries it.
        for stage in RenderStage.order {
            XCTAssertFalse(warm.keyMaterial(stage).contains("wb="),
                           "stage \(stage.rawValue)'s key material carries the white balance")
        }
        XCTAssertFalse(warm.renderInputs.key.contains("wb="),
                       "the render key carries the white balance")
    }

    // MARK: - 4. the render half is the mirror image

    /// `RenderInputs` answers "would the same buffer render differently?" — so it must not see the
    /// white balance at all (the buffer already absorbed it) and must see everything else.
    func testRenderInputsIgnoreTheWhiteBalanceAndSeeEverythingElse() {
        var a = busyDocument()
        var b = a
        b.light.temperature = 2850
        b.light.tint = -12
        XCTAssertEqual(a.renderInputs, b.renderInputs,
                       "the render half still depends on the white balance")
        XCTAssertEqual(a.renderInputs.key, b.renderInputs.key)
        XCTAssertNotEqual(a.decodeKey, b.decodeKey)

        let warmKey = b.decodeKey
        b.light.exposure += 0.5
        XCTAssertNotEqual(a.renderInputs, b.renderInputs)
        XCTAssertEqual(b.decodeKey, warmKey,
                       "an exposure change is still the same development (it compared against the "
                       + "as-shot key before — the fixture, not the code, was wrong)")
    }

    // MARK: - 5. one decision function

    /// `splitFrom` is the whole contract in one call, and `.none` has to be reachable or the
    /// no-op detection in the session's `applyEdit` would be lying.
    func testSplitClassifiesTheThreeCases() {
        let base = busyDocument()
        XCTAssertEqual(base.splitFrom(base), EditSplit.none)
        var render = base; render.light.whites += 1
        XCTAssertEqual(render.splitFrom(base), EditSplit.render)
        var decode = base; decode.light.tint = 3
        XCTAssertEqual(decode.splitFrom(base), EditSplit.decode)
        // A document that changes both is a development — the render half re-runs anyway.
        var both = base; both.light.exposure += 1; both.light.temperature = 4000
        XCTAssertEqual(both.splitFrom(base), EditSplit.decode)
    }

    // MARK: - 6. the stage dirty set agrees

    /// The pre-existing `changedStages` question and the new split must not disagree: a white-balance
    /// change invalidates every stage (new source pixels), an exposure change only S1.
    func testChangedStagesFollowsTheSameDecision() {
        let base = busyDocument()
        var warm = base; warm.light.temperature = 3200
        XCTAssertEqual(warm.changedStages(from: base), Set(RenderStage.allCases),
                       "a white-balance change must invalidate every stage, not one")

        var exposure = base; exposure.light.exposure += 1
        let stages = exposure.changedStages(from: base)
        XCTAssertEqual(stages, [.sceneLinear], "exposure is an S1 gain, nothing upstream of it moved")
    }
}
