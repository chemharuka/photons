import XCTest
import CryptoKit
@testable import PhotonsCore

/// 011 A's two parameter streams, **as re-cut by 194's two-stage white balance**.
///
/// The split still exists and is still the whole pipeline decision: a change is either a new
/// **decode** (a different buffer) or a new **render** (the same buffer drawn differently). The white
/// balance straddles the two halves of one gesture and this file is where the boundary is pinned:
/// **settled** values are decode inputs again (143 had moved them out; 194 puts them back, because the
/// settled frame must be `CIRAWFilter`'s answer rather than our estimate), while the **drag** never
/// reaches `EditModel` at all — it is view state in the loupe, an S1 gain on the resident buffer.
///
/// The historical assertions that made the split checkable survive: as shot adds nothing to any key,
/// render-side edits never develop, and `splitFrom` is the one decision function.
final class WhiteBalanceDecodeSplitTests: XCTestCase {

    // MARK: - fixtures

    private func busyDocument() -> EditModel {
        var e = EditModel()
        e.light.exposure = 0.75
        e.light.contrast = 20
        e.light.highlights = -30
        e.light.shadows = 15
        e.light.whites = 10
        e.light.blacks = -5
        e.light.highlightRecovery = 0.4
        e.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.3, v: 0.25), CurvePoint(u: 1, v: 1)]
        e.color.vibrance = 15
        e.color.saturation = -10
        e.geometry.rotationDegrees = 1.5
        e.geometry.crop = NormalizedRect(x: 0.1, y: 0.05, width: 0.8, height: 0.75)
        e.masks = [Mask(id: "m1", name: "m1")]
        return e
    }

    // MARK: - 1. render-side changes never develop

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
        toneCurve.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.62), CurvePoint(u: 1, v: 1)]
        var channelCurve = base
        channelCurve.curve.red = [CurvePoint(u: 0, v: 0.02), CurvePoint(u: 1, v: 0.98)]
        var colour = base; colour.color.vibrance = -35
        var bands = base; bands.color.bands[3].hue = 20
        var geometry = base; geometry.geometry.rotationDegrees = 3
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
            XCTAssertNotEqual(edited.renderInputs, base.renderInputs,
                              "\(name) did not reach RenderInputs — the fixture edit did nothing")
        }
    }

    func testManyRenderEditsDoNotAccumulateIntoADecode() {
        let base = busyDocument()
        var edited = base
        edited.light.exposure = -2
        edited.light.contrast = 60
        edited.light.blacks = -50
        edited.curve.blue = [CurvePoint(u: 0, v: 0.1), CurvePoint(u: 1, v: 0.9)]
        edited.color.saturation = 40
        edited.effects.vignetteAmount = 25
        edited.geometry.flipHorizontal = true
        XCTAssertEqual(edited.decodeKey, base.decodeKey)
        XCTAssertEqual(edited.splitFrom(base), .render)
    }

    // MARK: - 2. a settled white balance is a development again

    /// Every transition of the three-valued pair — including `nil` → a value and a value → `nil` — is a
    /// **decode** change now: the settled frame is the decoder's, so a different pair is a different
    /// buffer (`wb=…`) and a new development. `RenderInputs` moves too, because the *drag* is still
    /// this same pair drawn as an S1 gain on a buffer that does not carry it yet.
    func testAnyWhiteBalanceChangeMovesTheDecodeKeyAndTheRenderInputs() {
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

        let asShotKey = sequence[0].1.decodeKey
        for i in 1..<sequence.count {
            let (name, doc) = sequence[i]
            let (previousName, previous) = sequence[i - 1]
            XCTAssertNotEqual(doc.decodeKey, previous.decodeKey,
                              "“\(previousName)” → “\(name)” did not move the decode key — the "
                              + "settled frame would be drawn from the previous balance's buffer")
            XCTAssertEqual(doc.splitFrom(previous), .decode,
                           "“\(previousName)” → “\(name)” must be a development")
            XCTAssertNotEqual(doc.renderInputs, previous.renderInputs,
                              "“\(name)” did not reach RenderInputs")
        }
        // A document that walks to another pair and comes back names the first buffer again — the key
        // is a name, not a history, so the round trip hits the development it already paid for.
        var there = EditModel.neutral
        there.light.temperature = 4200
        var back = there
        back.light.temperature = nil
        XCTAssertNotEqual(there.decodeKey, asShotKey)
        XCTAssertEqual(back.decodeKey, asShotKey)
    }

    // MARK: - 3. as shot is still the historical key

    func testAsShotDecodeKeyIsTheHistoricalValue() {
        let shot = EditModel.neutral
        XCTAssertTrue(shot.light.whiteBalance.isAsShot)
        XCTAssertEqual(shot.decodeInputs, DecodeInputs.asShot)
        XCTAssertEqual(shot.decodeKey, DecodeInputs.asShot.key, "as shot is the neutral development")

        XCTAssertNil(shot.decodeInputs.whiteBalanceComponent)
        let photo = "248063fdc8786acc7fdac7362853bc7f46cd050927d3ed66fabe0e81991f33bb|A1B2"
        XCTAssertEqual(shot.decodeInputs.appending(to: photo), photo,
                       "as shot appended something to the rung identity — every resident rung's key moved")

        // An explicit white balance **does** name a second buffer since 194 — that buffer is the
        // settled frame. The as-shot identity above is what must not move; this is the opposite gate.
        var warm = shot
        warm.light.temperature = 5500
        warm.light.tint = 0
        XCTAssertEqual(warm.decodeInputs.appending(to: photo), "\(photo)|wb=5500K/+0",
                       "a settled white balance must develop its own buffer")
        XCTAssertNotEqual(warm.decodeKey, shot.decodeKey)

        // The on-disk key: as shot is still the pinned pre-006 digest.
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
        // The store still keeps two *keys* apart (a caller may name a legacy buffer), but the document
        // never produces the second one any more.
        XCTAssertNotEqual(DecodeCacheKey(fileSHA256: file, decoderVersion: decoderVersion,
                                         whiteBalance: WhiteBalance(temperature: 5500, tint: 0)).digest,
                          key.digest)
    }

    // MARK: - 3b. the one entry point for a rung identity

    func testTheRungIdentityHasOneEntryPointAndOnlyDecodeInputsMoveIt() {
        let photo = "L1030433|A1B2-C3D4"
        let asShot = EditModel.neutral
        XCTAssertEqual(asShot.decodeInputs.appending(to: photo), photo,
                       "as shot appended a suffix — the historical rung identity moved")

        var render = asShot
        render.light.exposure = 1.2
        render.light.contrast = 40
        render.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.6), CurvePoint(u: 1, v: 1)]
        render.color.vibrance = 30
        XCTAssertEqual(render.decodeInputs.appending(to: photo), photo,
                       "exposure/contrast/curve/colour moved the rung identity")
        // 194: the settled white balance is a decode input again, so it *does* move the identity — and
        // it must, or a 5500 K document would be answered with the as-shot buffer.
        var warm = render
        warm.light.temperature = 5500
        warm.light.tint = 0
        XCTAssertEqual(warm.decodeInputs.appending(to: photo), "\(photo)|wb=5500K/+0")

        // A decode-side change: the decoder version. It moves the identity, once, and appears in the
        // on-disk key too — the one remaining document-side decode input.
        var v9 = render
        v9.decoderVersion = "9"
        XCTAssertEqual(v9.decodeInputs.appending(to: photo), "\(photo)|ver=9")
        XCTAssertNotEqual(v9.decodeInputs.appending(to: photo),
                          render.decodeInputs.appending(to: photo))
        XCTAssertTrue(DecodeCacheKey(fileSHA256: "abc", decoderVersion: "9").keyText.contains("|"))
    }

    // MARK: - 4. RenderInputs sees the balance, and everything else

    func testRenderInputsSeeTheWhiteBalanceAndEverythingElse() {
        var a = busyDocument()
        var b = a
        b.light.temperature = 2850
        b.light.tint = -12
        XCTAssertNotEqual(a.renderInputs, b.renderInputs,
                          "the render half does not see the white balance — the drag would render the old pair")
        XCTAssertNotEqual(a.renderInputs.key, b.renderInputs.key)
        XCTAssertNotEqual(a.decodeKey, b.decodeKey,
                          "a settled white-balance change did not move the decode key")

        let warmKey = b.decodeKey
        b.light.exposure += 0.5
        XCTAssertNotEqual(a.renderInputs, b.renderInputs)
        XCTAssertEqual(b.decodeKey, warmKey,
                       "an exposure change is still the same development")
    }

    // MARK: - 5. one decision function

    func testSplitClassifiesTheThreeCases() {
        let base = busyDocument()
        XCTAssertEqual(base.splitFrom(base), EditSplit.none)
        var render = base; render.light.whites += 1
        XCTAssertEqual(render.splitFrom(base), EditSplit.render)
        // 194: a white balance is a development again — the settled frame is the decoder's.
        var warm = base; warm.light.tint = 3
        XCTAssertEqual(warm.splitFrom(base), EditSplit.decode)
        // A decoder-version change is the other development.
        var decode = base; decode.decoderVersion = "9"
        XCTAssertEqual(decode.splitFrom(base), EditSplit.decode)
        var both = base; both.light.exposure += 1; both.decoderVersion = "9"
        XCTAssertEqual(both.splitFrom(base), EditSplit.decode)
    }

    // MARK: - 6. the stage dirty set agrees

    func testChangedStagesFollowsTheSameDecision() {
        let base = busyDocument()
        var warm = base; warm.light.temperature = 3200
        XCTAssertEqual(warm.changedStages(from: base), Set(RenderStage.allCases),
                       "a settled white-balance change is a new development — every stage re-runs")

        var exposure = base; exposure.light.exposure += 1
        XCTAssertEqual(exposure.changedStages(from: base), [.sceneLinear],
                       "exposure is an S1 gain, nothing upstream of it moved")

        var version = base; version.decoderVersion = "9"
        XCTAssertEqual(version.changedStages(from: base), Set(RenderStage.allCases),
                       "a new development invalidates every stage")
    }
}
