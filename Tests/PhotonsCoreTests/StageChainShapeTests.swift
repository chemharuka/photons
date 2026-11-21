import XCTest
import PhotonsCore

/// 481 — **the one place a stage-order literal lives.**
///
/// Seven suites assert "this document's chain is …". They used to spell the chain out (or compare it
/// against `RenderStage.allCases` as an array), which is how two product moves left seven stale
/// expectations behind:
///
///   · **116** (`69160eb`) moved the vignette from S3c into the linear chain — before `toneMap`;
///   · **314** (`44d56f3`) made 锐化's resting amount 50, so S3.10 is in **every** document's chain.
///
/// `RenderStage.order` is the execution order (`RenderGraph` renders `keys.pipeline`), so it is the
/// truth. This type is the test-side mirror of it; the suites reference `resting()` / `chain(adding:)`
/// instead of writing a chain again, so the next stage is one literal here instead of seven.
///
/// `RenderStage.allCases` is **not** the order to compare against: its membership is the
/// unconditional stages, but its spelling predates 116 (vignette after colour) and it cannot gain
/// `sharpen`, which is conditional. Compare chains here, never against `allCases` as an array.
enum StageChainShape {
    /// `RenderStage.order`, verbatim, in execution order.
    static let full: [RenderStage] = [
        .heal, .geometry, .sceneLinear, .maskAtlas, .localApply, .curve, .dehaze,
        .vignette, .toneMap, .contrast, .color, .bw, .localColor, .hsl,
        .pointColour, .grade, .detailFX, .sharpen, .grain, .display,
    ]

    /// Stages that exist only when a document value says so — `RenderStage.pipeline`'s switch.
    static let conditional: Set<RenderStage> = [
        .maskAtlas, .localApply, .heal, .contrast, .dehaze, .bw, .localColor,
        .hsl, .pointColour, .grade, .detailFX, .sharpen, .grain,
    ]

    /// The passes every document runs, in execution order. 116: `vignette` is before S2, not S3c.
    static let unconditional: [RenderStage] = [
        .geometry, .sceneLinear, .curve, .vignette, .toneMap, .color, .display,
    ]

    /// `full` restricted to `stages`: what a render with exactly those stages visits, in order.
    static func chain(_ stages: Set<RenderStage>) -> [RenderStage] {
        full.filter { stages.contains($0) }
    }

    /// The chain of a document whose only conditional work is `stages` — the unconditional passes
    /// plus those stage(s), in `full`'s order.
    static func chain(adding stages: Set<RenderStage>) -> [RenderStage] {
        chain(Set(unconditional).union(stages))
    }

    /// 314 — a document that never opened a card still visits S3.10 (`sharpen.amount == 50`).
    static func resting(_ extra: Set<RenderStage> = []) -> [RenderStage] {
        chain(adding: extra.union([.sharpen]))
    }
}

final class StageChainShapeTests: XCTestCase {

    // MARK: - the one order

    /// The execution order is the literal above, nothing added, nothing moved.
    ///
    /// This is the assertion that turns red when a stage is appended to `RenderStage.order` (or its
    /// neighbours are swapped) without the shape being updated — the point of the file.
    func testTheExecutionOrderIsTheSingleLiteral() {
        XCTAssertEqual(RenderStage.order, StageChainShape.full)
        XCTAssertEqual(StageChainShape.full.filter { !StageChainShape.conditional.contains($0) },
                       StageChainShape.unconditional,
                       "无条件链 = 执行顺序去掉条件 stage")
    }

    /// `allCases` still names exactly the unconditional passes; only its **order** is legacy.
    ///
    /// `RenderStage.pipeline` falls back to it when every conditional flag is false, which is the one
    /// path (explicit `sharpAmount = 0` plus nothing else set) where the array order is not
    /// `order`'s. 481 deliberately does not change product code; the suites therefore compare full
    /// chains against `StageChainShape`, not `allCases`.
    func testNeutralFallbackNamesTheUnconditionalStages() {
        XCTAssertEqual(Set(RenderStage.allCases), Set(StageChainShape.unconditional))
        XCTAssertEqual(Set(RenderStage.pipeline(hasMasks: false)),
                       Set(StageChainShape.unconditional))
        XCTAssertEqual(RenderStage.pipeline(hasMasks: false)
            .filter { StageChainShape.conditional.contains($0) }, [],
            "all flags false: no conditional stage may appear")
    }

    /// 314 — the resting document's chain, so the seven suites do not each spell it out.
    func testTheRestingDocumentVisitsSharpen() {
        XCTAssertEqual(StageChainShape.resting(),
                       [.geometry, .sceneLinear, .curve, .vignette, .toneMap, .color,
                        .sharpen, .display],
                       "314: 锐化默认 50，S3.10 在每份新文档的链里")
    }

    // MARK: - each conditional stage, once

    /// Every conditional stage enters the chain at its own position — asserted here once.
    ///
    /// The order itself is `StageChainShape.full`; this test proves `RenderStage.pipeline`'s predicate
    /// selects the right members, and the `full == order` test above proves the positions.
    func testEachConditionalStageEntersAtItsOwnPosition() {
        let cases: [(name: String, visited: [RenderStage], expected: [RenderStage])] = [
            ("maskAtlas + localApply (S1.5/S1.6)",
             RenderStage.pipeline(hasMasks: true),
             StageChainShape.chain(adding: [.maskAtlas, .localApply])),
            ("heal (249: before S0)",
             RenderStage.pipeline(hasMasks: false, hasHeal: true),
             StageChainShape.chain(adding: [.heal])),
            ("contrast (S2.5: after S2, before S3)",
             RenderStage.pipeline(hasMasks: false, hasContrast: true),
             StageChainShape.chain(adding: [.contrast])),
            ("dehaze (S1.9: before vignette/S2)",
             RenderStage.pipeline(hasMasks: false, hasDehaze: true),
             StageChainShape.chain(adding: [.dehaze])),
            ("bw (S3.4: after S3)",
             RenderStage.pipeline(hasMasks: false, hasBW: true),
             StageChainShape.chain(adding: [.bw])),
            ("localColor (S3.5: needs masks)",
             RenderStage.pipeline(hasMasks: true, hasLocalColor: true),
             StageChainShape.chain(adding: [.maskAtlas, .localApply, .localColor])),
            ("hsl (S3.6: after S3.5)",
             RenderStage.pipeline(hasMasks: false, hasHSL: true),
             StageChainShape.chain(adding: [.hsl])),
            ("pointColour (S3.6b: after S3.6)",
             RenderStage.pipeline(hasMasks: false, hasPointColor: true),
             StageChainShape.chain(adding: [.pointColour])),
            ("grade (S3.8: after S3.6b)",
             RenderStage.pipeline(hasMasks: false, hasGrade: true),
             StageChainShape.chain(adding: [.grade])),
            ("detailFX (S3.9: after S3.8)",
             RenderStage.pipeline(hasMasks: false, hasDetailFX: true),
             StageChainShape.chain(adding: [.detailFX])),
            ("sharpen (S3.10: after S3.9, before vignette/S4)",
             RenderStage.pipeline(hasMasks: false, hasSharpen: true),
             StageChainShape.chain(adding: [.sharpen])),
            ("grain (S3.7 spelling: after vignette, before S4)",
             RenderStage.pipeline(hasMasks: false, hasGrain: true),
             StageChainShape.chain(adding: [.grain])),
        ]
        for c in cases {
            XCTAssertEqual(c.visited, c.expected, c.name)
        }
    }
}
