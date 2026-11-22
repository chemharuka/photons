import XCTest
import PhotonsCore
@testable import PhotonsCatalog

/// 405 — **the thumbnail fingerprint versions only the stages a document actually runs.**
///
/// The user's question: 「修改函数后需要重新生成一次预览图，能否做到只有应用了的图片才生成，比如去雾算法
/// 修改了，只有应用了去雾的才重跑」.
///
/// Two claims have to hold **at the same time**, and they pull in opposite directions:
///   (a) today's keys are byte-identical — no one-time full-library rebuild;
///   (b) bumping a conditional stage moves only the documents that carry it.
///
/// The mechanism is `ThumbFingerprintBaseline`: a captured literal table. A stage the document does
/// not run contributes the baseline number (so the string does not move when the live number does);
/// a stage it does run contributes `StageAlgorithmVersion.version(of:)` (so a bump is a miss).
///
/// ①–③ pin the three today-fingerprints; ④ is the core claim; ⑤ is the refutation — a *global* stage
/// must still move every document, so "filter out everything" cannot pass as a solution; ⑥ keeps the
/// baseline table honest when a `RenderStage` is added; ⑦ pins the version segment per stage.
final class ThumbFingerprintScope405Tests: XCTestCase {

    // MARK: - fixtures

    private var neutral: EditModel { .neutral }

    private var cropped: EditModel {
        var e = EditModel.neutral
        e.geometry.crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        e.geometry.rotationDegrees = 3
        e.geometry.quarterTurns = 1
        return e
    }

    private var dehazed: EditModel {
        var e = EditModel.neutral
        e.effects.dehaze = 50
        return e
    }

    /// One document per conditional stage plus the unconditional ones, so ⑦ can walk the enum.
    private func document(running stage: RenderStage) -> EditModel {
        var e = EditModel.neutral
        switch stage {
        case .geometry:
            e.geometry.rotationDegrees = 2
        case .sceneLinear:
            e.light.exposure = 0.5
        case .maskAtlas, .localApply:
            e.masks = [Mask(id: "m-1")]
        case .heal:
            e.healSpots = [HealSpot(id: "h-1")]
        case .curve:
            e.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]
        case .contrast:
            e.light.contrast = 20
        case .dehaze:
            e.effects.dehaze = 50
        case .toneMap:
            e.light.highlights = -20
        case .color:
            e.color.saturation = 20
        case .bw:
            e.color.blackAndWhite = true
        case .localColor:
            var adjustments = LocalAdjustments()
            adjustments.hue = 10
            e.masks = [Mask(id: "m-1", adjustments: adjustments)]
        case .hsl:
            e.color.bands[0].hue = 10
        case .pointColour:
            e.color.point = PointColorSet(
                swatches: [PointColor(sampleHue: 30, sampleChroma: 0.1, hue: 10)], active: 0)
        case .grade:
            e.colorGrading.shadows.hue = 10
        case .detailFX:
            e.effects.texture = 10
        case .sharpen:
            e.sharpen.amount = 80
        case .grain:
            e.effects.grain = 20
        case .vignette:
            e.effects.vignetteAmount = -30
        case .display:
            break
        }
        return e
    }

    private func fingerprint(_ document: EditModel,
                             bumping stage: RenderStage? = nil,
                             to value: Int = 0) -> String {
        guard let stage else { return ThumbRecipe.editFingerprint(document) }
        return ThumbRecipe.editFingerprint(document) { s in
            s == stage ? value : StageAlgorithmVersion.version(of: s)
        }
    }

    // MARK: - ①–③ today's keys, frozen
    //
    // ①–③ were **re-recorded by 506-C** (2026-11-22). Every HD key moves exactly once, on purpose:
    // the fingerprint now spells the grid's own decoder policy (`tdec=classic` — the grid never goes
    // through the ML/v9 stage, docs/tasks/506-raw-decode-ane-concurrency.md) instead of the
    // document's `ver=` request. So the pixels of every high-ISO file genuinely change, and a
    // thumbnail rendered by the crashing v9 path must not stay servable. Cost: one background
    // rebuild of the HD cache; the legacy/preview families are untouched (their keys carry no
    // document and no policy).

    func testTheNeutralDocumentFingerprintIsByteIdenticalToToday() {
        XCTAssertEqual(ThumbRecipe.editFingerprint(.neutral),
                       "983169dd351aceef37e774ca948240a04d304f812d2f9112249f0434fe3d7e89")
    }

    func testACroppedAndRotatedDocumentFingerprintIsByteIdenticalToToday() {
        XCTAssertEqual(ThumbRecipe.editFingerprint(cropped),
                       "2b0e2ec89fea216a046246cc36b739adce043bbd852f104724168e190d7eca61")
    }

    /// ③ today's key of a document that **runs** dehaze. 417 re-recorded it: `dehaze` moved 11 → 12
    /// (the verdict 「天空先压暗试试看」 changes the pixels of every `dehaze > 0` document), and
    /// `ThumbRecipe.editFingerprint` spells a *used* stage's live version — so this key must move, while
    /// ① and ② (documents that do not run S1.9, which read `ThumbFingerprintBaseline`) stay byte-identical.
    /// The baseline table itself is untouched: its `.dehaze: 11` entry is the neutral placeholder for
    /// non-dehaze documents and never follows a bump. 506-C re-recorded it once more, for the key's
    /// decoder-policy token (see ①–③ above).
    func testADehazeOnlyEditChangesTheFingerprint() {
        XCTAssertEqual(ThumbRecipe.editFingerprint(dehazed),
                       "8127d2d5c1cd9283b1fe7987cc76ec67e4c78f042fcf5f1fb6890318a98d54f5")
        // …and it is genuinely a different key from neutral, i.e. ① is not passing by accident.
        XCTAssertNotEqual(ThumbRecipe.editFingerprint(dehazed),
                          ThumbRecipe.editFingerprint(.neutral))
    }

    // MARK: - ④ the core claim

    func testABumpOfAStageTheDocumentDoesNotRunDoesNotChangeItsFingerprint() {
        let bumpedDehaze = { (s: RenderStage) -> Int in
            s == .dehaze ? StageAlgorithmVersion.dehaze + 1 : StageAlgorithmVersion.version(of: s)
        }
        // Neutral and cropped/rotated do **not** run S1.9, so the dehaze bump must not reach them.
        XCTAssertEqual(ThumbRecipe.editFingerprint(.neutral, versions: bumpedDehaze),
                       ThumbRecipe.editFingerprint(.neutral))
        XCTAssertEqual(ThumbRecipe.editFingerprint(cropped, versions: bumpedDehaze),
                       ThumbRecipe.editFingerprint(cropped))
        // The document that *does* run dehaze must miss.
        XCTAssertNotEqual(ThumbRecipe.editFingerprint(dehazed, versions: bumpedDehaze),
                          ThumbRecipe.editFingerprint(dehazed))
    }

    // MARK: - ⑤ the refutation

    func testABumpOfAnUnconditionalStageStillMovesEveryDocument() {
        // `geometry` runs for every document; freezing it too would be "filter out everything".
        let moved = fingerprint(.neutral, bumping: .geometry, to: 6)
        XCTAssertNotEqual(moved, ThumbRecipe.editFingerprint(.neutral))
        XCTAssertNotEqual(fingerprint(cropped, bumping: .geometry, to: 6),
                          ThumbRecipe.editFingerprint(cropped))
        XCTAssertNotEqual(fingerprint(dehazed, bumping: .geometry, to: 6),
                          ThumbRecipe.editFingerprint(dehazed))
    }

    // MARK: - ⑥ the table stays total

    func testTheBaselineTableCoversEveryStage() {
        // **Not** "baseline == live": that would go red on the next legitimate bump, which is the
        // opposite of what the table is for. The only invariant is that no stage is missing.
        for stage in RenderStage.order {
            XCTAssertNotNil(ThumbFingerprintBaseline.version[stage],
                            "ThumbFingerprintBaseline has no entry for \(stage.rawValue)")
        }
    }

    // MARK: - ⑦ the version segment names every stage the document runs

    func testEveryStageAppearsInTheVersionSegmentWhenTheDocumentUsesIt() {
        for stage in RenderStage.order {
            let document = self.document(running: stage)
            guard document.renderStages.contains(stage) else {
                XCTFail("fixture for \(stage.rawValue) does not make the stage run")
                continue
            }
            let material = ThumbRecipe.fingerprintMaterial(document)
            // The segment comes after the stage keys; assert on the raw-value spelling itself.
            XCTAssertTrue(material.contains("\(stage.rawValue)=\(StageAlgorithmVersion.version(of: stage))"),
                          "version segment lost \(stage.rawValue)")
        }
    }

    // MARK: - ⑧ 506-C: the HD key names the thumbnail's decode policy, not the document's request

    /// The grid never decodes through Apple's ML (v9) stage, so a document that asks for `9.dng`
    /// must produce the **same** HD key as a neutral one — and every key carries the policy token.
    ///
    /// Both halves matter: if the key still spelled `ver=9.dng`, a v9 document would re-render
    /// thumbnails that cannot differ (and each rebuild is another pass through the decoder), and the
    /// key would claim pixels the pipeline never produced.
    func testTheHDKeySpellsTheThumbnailDecoderPolicyNotTheDocumentsVersion() {
        var neural = EditModel.neutral
        neural.decoderVersion = "9.dng"
        XCTAssertEqual(neural.decodeInputs.versionComponent, "ver=9.dng",
                       "fixture must actually ask for v9, or this test proves nothing")
        XCTAssertEqual(ThumbRecipe.editFingerprint(neural),
                       ThumbRecipe.editFingerprint(.neutral))
        XCTAssertTrue(ThumbRecipe.fingerprintMaterial(.neutral)
                        .contains("|\(ThumbDecoderProfile.token)"),
                      "every HD key must name the policy that produced its pixels")
        // …and the policy token is the *only* version spelling in it: no `ver=` may survive.
        XCTAssertFalse(ThumbRecipe.fingerprintMaterial(neural).contains("ver="),
                       "the document's decoder request must not reach the HD key any more")
    }
}
