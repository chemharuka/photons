import XCTest
import CryptoKit
@testable import PhotonsCore

/// 011 A's two parameter streams, **as re-cut by 143**.
///
/// The split still exists and is still the whole pipeline decision: a change is either a new
/// **decode** (a different buffer) or a new **render** (the same buffer drawn differently). What moved
/// is white balance. Since 143 the decoder never receives a Kelvin/tint; the document's pair is an S1
/// gain computed by `WhiteBalanceEstimate`, so it is a **render** input. The file keeps the historical
/// assertions that made the split checkable — as shot adds nothing to any key, render-side edits never
/// develop, and `splitFrom` is the one decision function — and pins the new placement of the balance.
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
        var whiteBalance = base
        whiteBalance.light.temperature = 3000
        whiteBalance.light.tint = -20

        let cases: [(String, EditModel)] = [
            ("exposure", exposure), ("contrast", contrast), ("highlights", highlights),
            ("shadows", shadows), ("whites", whites), ("blacks", blacks),
            ("highlight recovery", recovery), ("RGB curve", toneCurve),
            ("channel curve", channelCurve), ("saturation/vibrance", colour),
            ("HSL band", bands), ("geometry", geometry), ("crop", crop), ("masks", masks),
            ("vignette", vignette), ("white balance", whiteBalance),
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
        edited.light.temperature = 3600
        edited.light.tint = 18
        edited.curve.blue = [CurvePoint(u: 0, v: 0.1), CurvePoint(u: 1, v: 0.9)]
        edited.color.saturation = 40
        edited.effects.vignetteAmount = 25
        edited.geometry.flipHorizontal = true
        XCTAssertEqual(edited.decodeKey, base.decodeKey)
        XCTAssertEqual(edited.splitFrom(base), .render)
    }

    // MARK: - 2. white balance is render-side now

    /// Every transition of the three-valued pair — including `nil` → a value and a value → `nil` —
    /// is a **render** change. The decode key stays byte-identical; `RenderInputs` moves each time,
    /// because the S1 gain reads the pair.
    func testAnyWhiteBalanceChangeMovesTheRenderInputsNotTheDecodeKey() {
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
        pinned.light.temperature = 5871.6
        pinned.light.tint = 20.35
        sequence.append(("pinned to the as-shot numbers", pinned))

        let asShotKey = sequence[0].1.decodeKey
        for i in 1..<sequence.count {
            let (name, doc) = sequence[i]
            let (previousName, previous) = sequence[i - 1]
            XCTAssertEqual(doc.decodeKey, asShotKey,
                           "“\(name)” moved the decode key — the decoder no longer takes a balance")
            XCTAssertEqual(previous.decodeKey, asShotKey)
            XCTAssertEqual(doc.splitFrom(previous), .render,
                           "“\(previousName)” → “\(name)” must be a render, not a development")
            XCTAssertNotEqual(doc.renderInputs, previous.renderInputs,
                              "“\(name)” did not reach RenderInputs")
        }
        // The last step returns to the as-shot document, and must return to its render key too.
        XCTAssertEqual(sequence[6].1.renderInputs, sequence[0].1.renderInputs)
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

        // An explicit white balance no longer appends anything either: the pixels are the as-shot
        // buffer, and the balance is an S1 gain.
        var warm = shot
        warm.light.temperature = 5500
        warm.light.tint = 0
        XCTAssertEqual(warm.decodeInputs.appending(to: photo), photo,
                       "a white balance reached the rung identity — it would develop a second buffer")
        XCTAssertEqual(warm.decodeKey, shot.decodeKey)

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
        render.light.temperature = 5500
        render.light.tint = 0
        render.light.contrast = 40
        render.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.6), CurvePoint(u: 1, v: 1)]
        render.color.vibrance = 30
        XCTAssertEqual(render.decodeInputs.appending(to: photo), photo,
                       "exposure/contrast/curve/colour/white-balance moved the rung identity")

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
                          "the render half does not see the white balance — S1 would render the old pair")
        XCTAssertNotEqual(a.renderInputs.key, b.renderInputs.key)
        XCTAssertEqual(a.decodeKey, b.decodeKey,
                       "a white-balance change moved the decode key")

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
        var warm = base; warm.light.tint = 3
        XCTAssertEqual(warm.splitFrom(base), EditSplit.render)
        // A decoder-version change is the remaining development.
        var decode = base; decode.decoderVersion = "9"
        XCTAssertEqual(decode.splitFrom(base), EditSplit.decode)
        var both = base; both.light.exposure += 1; both.decoderVersion = "9"
        XCTAssertEqual(both.splitFrom(base), EditSplit.decode)
    }

    // MARK: - 6. the stage dirty set agrees

    func testChangedStagesFollowsTheSameDecision() {
        let base = busyDocument()
        var warm = base; warm.light.temperature = 3200
        XCTAssertEqual(warm.changedStages(from: base), [.sceneLinear],
                       "a white-balance change is S1's gain slot and nothing above it")

        var exposure = base; exposure.light.exposure += 1
        XCTAssertEqual(exposure.changedStages(from: base), [.sceneLinear],
                       "exposure is an S1 gain, nothing upstream of it moved")

        var version = base; version.decoderVersion = "9"
        XCTAssertEqual(version.changedStages(from: base), Set(RenderStage.allCases),
                       "a new development invalidates every stage")
    }
}
