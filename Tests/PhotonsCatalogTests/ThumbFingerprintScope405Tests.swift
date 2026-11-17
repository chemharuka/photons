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

    func testTheNeutralDocumentFingerprintIsByteIdenticalToToday() {
        XCTAssertEqual(ThumbRecipe.editFingerprint(.neutral),
                       "d70642ef60809c9c3b9412c9de46cd7d3bb77beab2adcba52eeb0fc07079a5c8")
    }

    func testACroppedAndRotatedDocumentFingerprintIsByteIdenticalToToday() {
        XCTAssertEqual(ThumbRecipe.editFingerprint(cropped),
                       "3befa1a35dadd9b05a423700118231aef22978f0c842f1b7a7b8bfca38e76c78")
    }

    /// ③ today's key of a document that **runs** dehaze. 417 re-recorded it: `dehaze` moved 11 → 12
    /// (the verdict 「天空先压暗试试看」 changes the pixels of every `dehaze > 0` document), and
    /// `ThumbRecipe.editFingerprint` spells a *used* stage's live version — so this key must move, while
    /// ① and ② (documents that do not run S1.9, which read `ThumbFingerprintBaseline`) stay byte-identical.
    /// The baseline table itself is untouched: its `.dehaze: 11` entry is the neutral placeholder for
    /// non-dehaze documents and never follows a bump.
    func testADehazeOnlyEditChangesTheFingerprint() {
        XCTAssertEqual(ThumbRecipe.editFingerprint(dehazed),
                       "0d7c9794b1ec56d05c6d0401a086eda8905cdfd1b8e58f1626afa4e1ed6dc271")
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
}
