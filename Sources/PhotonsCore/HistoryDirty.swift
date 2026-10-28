import Foundation

// MARK: - Semantic parameter diff (group level, D10)

/// Says *which panels* differ between two documents — never which parameter.
///
/// Everything here is a **semantic** comparison, not `==`:
///
/// - floats compare within `EditHistory.dirtyTolerance` (1e-6), because a document that has been
///   through JSON, or a slider value reconstructed by the UI, is not bit-identical to the one that
///   produced the pixels on screen. Reporting that as dirty means recomputing a stage for nothing;
///   at 1e-6 the worst case is a sub-quantum change no eye and no 8-bit encode can see.
/// - `masks` empty and absent are the same thing (an absent key decodes to `[]` in `EditModel`),
///   and a mask param that is absent counts as 0, so `params: ["a": 0]` and `params: [:]` agree.
/// - a `schemaVersion` / `processVersion` bump dirties **every** group: the parameters did not
///   change meaning, their interpretation did.
extension EditHistory {

    /// Groups whose parameters differ between two documents.
    ///
    /// This is the whole dirty-marking contract: caller redraws the union of `stages` for the
    /// returned set, and downstream stages are handled by the cache-key chain (D6), not listed here.
    public static func dirtyGroups(from before: EditModel, to after: EditModel) -> Set<RenderGroup> {
        guard before.schemaVersion == after.schemaVersion,
              before.processVersion == after.processVersion else {
            return Set(RenderGroup.allCases)
        }
        var dirty: Set<RenderGroup> = []
        if !EditParameters.areEqual(before.light, after.light) { dirty.insert(.light) }
        if !EditParameters.areEqual(before.curve, after.curve) { dirty.insert(.curve) }
        if !EditParameters.areEqual(before.color, after.color) { dirty.insert(.color) }
        // 2026-10-28 (P0 色彩分级): the nine numbers are a group of their own, so a grade drag reports
        // 色彩分级 — not Color, whose card does not read them, and not HSL, whose bands it does not read.
        if !EditParameters.areEqual(before.colorGrading, after.colorGrading) {
            dirty.insert(.colorGrading)
        }
        if !EditParameters.areEqual(before.detail, after.detail) { dirty.insert(.detail) }
        // 派单 031: the decoder-side detail amounts share the panel with `detail`, so they share the
        // group. They dirty no *stage* (`.detail.stages` is empty and stays empty: a new
        // development is not a stage), but a document whose sliders moved is a document that
        // changed, and `commit` has to see it to keep an undo step.
        if !EditParameters.areEqual(before.detailSettings, after.detailSettings) { dirty.insert(.detail) }
        // 解码模型 (owner, 2026-10-27): the decoder version lives on the same card and is the coarsest
        // decode input there is — a switch must be one committable edit (and the loupe re-develops,
        // because `decodeInputs` moves). It dirties no *stage*: a new development is not a render stage.
        if before.decoderVersion != after.decoderVersion { dirty.insert(.detail) }
        if !EditParameters.areEqual(before.effects, after.effects) { dirty.insert(.effects) }
        if !EditParameters.areEqual(before.geometry, after.geometry) { dirty.insert(.geometry) }
        if !EditParameters.renderMaterialEqual(before.masks, after.masks) { dirty.insert(.masks) }
        return dirty
    }

    /// Instance spelling of the same question, for call sites that already hold a history.
    public func dirtyGroups(from before: EditModel, to after: EditModel) -> Set<RenderGroup> {
        EditHistory.dirtyGroups(from: before, to: after)
    }

    /// True when the two documents are **the same document**: no group is dirty *and* nothing
    /// invisible-to-the-renderer changed either. Used by `commit` to drop no-op snapshots.
    ///
    /// Deliberately stricter than `dirtyGroups(...).isEmpty`. A mask rename changes no pixels, so
    /// it is not dirty — but it is still an edit the user must be able to undo, so it must be
    /// committable. Two different questions, two different answers.
    public static func isSemanticallyIdentical(_ a: EditModel, _ b: EditModel) -> Bool {
        dirtyGroups(from: a, to: b).isEmpty && a.masks == b.masks
    }

    /// Stages a dirty set invalidates directly (union of `RenderGroup.stages`).
    public static func dirtyStages(for groups: Set<RenderGroup>) -> Set<RenderStage> {
        groups.reduce(into: Set<RenderStage>()) { $0.formUnion($1.stages) }
    }
}

// MARK: - the comparisons

/// Tolerant equality for every value type in `EditModel`. Internal: the public surface is the
/// group question, not "is this double close enough".
enum EditParameters {

    static func areEqual(_ a: Double, _ b: Double) -> Bool {
        let tol = EditHistory.dirtyTolerance
        if a == b { return true }                    // covers ±inf and ±0
        if a.isNaN && b.isNaN { return true }        // a poisoned value stays "the same" value
        return abs(a - b) <= tol
    }

    static func areEqual(_ a: Bool, _ b: Bool) -> Bool { a == b }

    static func areEqual(_ a: NormalizedRect, _ b: NormalizedRect) -> Bool {
        areEqual(a.x, b.x) && areEqual(a.y, b.y)
            && areEqual(a.width, b.width) && areEqual(a.height, b.height)
    }

    static func areEqual(_ a: [CurvePoint], _ b: [CurvePoint]) -> Bool {
        // Same window as every other double in this file, and **not** `==`: a curve point is a
        // continuous coordinate, not a grid cell. 069 briefly compared the pair exactly ("a point is
        // a pair of grid cells") while the same commit shipped `CurvePoint.x/y` as continuous doubles
        // (`EditModel.swift:989-991`) — so a document whose curve had been through JSON was marked
        // dirty against itself, and the user got a phantom undo step and a full S1.7 → S4 recompute
        // for a sub-quantum move. In the engine's units the window is 5e-7 of the `0…1` axis — 1/488
        // of one `CurveLUT` entry (4096 over `0…1`), i.e. nothing a table, a pixel or an eye can see.
        // `HistoryTests.testFloatToleranceDecidesDirtiness` pins both sides of the boundary.
        a.count == b.count && zip(a, b).allSatisfy { areEqual($0.x, $1.x) && areEqual($0.y, $1.y) }
    }

    static func areEqual(_ a: [HSLBand], _ b: [HSLBand]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            areEqual($0.hue, $1.hue) && areEqual($0.saturation, $1.saturation)
                && areEqual($0.luminance, $1.luminance) && areEqual($0.mix, $1.mix)
        }
    }

    static func areEqual(_ a: GeometryGroup, _ b: GeometryGroup) -> Bool {
        areEqual(a.crop, b.crop)
            && areEqual(a.rotationDegrees, b.rotationDegrees)
            && areEqual(a.flipHorizontal, b.flipHorizontal)
            && areEqual(a.flipVertical, b.flipVertical)
    }

    static func areEqual(_ a: LightGroup, _ b: LightGroup) -> Bool {
        areEqual(a.exposure, b.exposure)
            && areEqual(a.contrast, b.contrast)
            && areEqual(a.highlights, b.highlights)
            && areEqual(a.shadows, b.shadows)
            && areEqual(a.whites, b.whites)
            && areEqual(a.blacks, b.blacks)
            && areEqual(a.temperature, b.temperature)
            && areEqual(a.tint, b.tint)
            && areEqual(a.highlightRecovery, b.highlightRecovery)
            // 071: **this line is load-bearing, not bookkeeping.** `CatalogSession.applyEdit`
            // short-circuits on `isSemanticallyIdentical`, so a field that is missing here is a field
            // whose slider writes nothing at all — measured: before this line the 黑电平 slider moved,
            // `applyEdit` returned silently, and the document stayed at 0. A step is 0.001, i.e. a
            // thousand `dirtyTolerance`s, so no tolerance can hide one.
            && areEqual(a.blackOffset, b.blackOffset)
    }

    /// As shot (`nil`) is a *state*, not a number: a document that follows the file and one that
    /// pins 6500 K are different documents, so the comparison has to be three-valued (派单 006).
    static func areEqual(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return areEqual(x, y)
        default: return false
        }
    }

    static func areEqual(_ a: CurveGroup, _ b: CurveGroup) -> Bool {
        areEqual(a.rgb, b.rgb) && areEqual(a.red, b.red)
            && areEqual(a.green, b.green) && areEqual(a.blue, b.blue)
    }

    static func areEqual(_ a: ColorGroup, _ b: ColorGroup) -> Bool {
        a.blackAndWhite == b.blackAndWhite
            && areEqual(a.vibrance, b.vibrance) && areEqual(a.saturation, b.saturation)
            && areEqual(a.bands, b.bands)
    }

    /// 2026-10-28 (P0 色彩分级): the nine numbers. **Load-bearing** for the same reason
    /// `blackOffset` and the three grain fields are: `CatalogSession.applyEdit` short-circuits on
    /// `isSemanticallyIdentical`, so a group missing from here is a slider that writes nothing at all
    /// (and `commitEdit` then finds nothing to commit, so the drag leaves no history row either).
    static func areEqual(_ a: ColorGradingGroup, _ b: ColorGradingGroup) -> Bool {
        zip(a.wheels, b.wheels).allSatisfy { x, y in
            areEqual(x.hue, y.hue) && areEqual(x.saturation, y.saturation)
                && areEqual(x.lightness, y.lightness)
        }
    }

    static func areEqual(_ a: DetailGroup, _ b: DetailGroup) -> Bool {
        areEqual(a.sharpening, b.sharpening)
            && areEqual(a.sharpeningRadius, b.sharpeningRadius)
            && areEqual(a.noiseLuminance, b.noiseLuminance)
            && areEqual(a.noiseColor, b.noiseColor)
            && areEqual(a.lensCorrections, b.lensCorrections)
    }

    /// 派单 031: the decoder-side amounts. One unit of slider travel is 0.01 of a filter value (040's
    /// 0…100 scale), so the 1e-6 tolerance is far below a step and far above JSON round-trip noise.
    static func areEqual(_ a: DetailSettings, _ b: DetailSettings) -> Bool {
        areEqual(a.luminanceNR, b.luminanceNR)
            && areEqual(a.colorNR, b.colorNR)
            && areEqual(a.sharpness, b.sharpness)
            && areEqual(a.detail, b.detail)
    }

    static func areEqual(_ a: EffectsGroup, _ b: EffectsGroup) -> Bool {
        areEqual(a.vignetteAmount, b.vignetteAmount)
            && areEqual(a.vignetteMidpoint, b.vignetteMidpoint)
            && areEqual(a.vignetteFeather, b.vignetteFeather)
            && areEqual(a.vignetteRoundness, b.vignetteRoundness)
            && areEqual(a.grain, b.grain)
            // 2026-10-28 — and the same load-bearing rule as `blackOffset` above: `applyEdit`
            // short-circuits on `isSemanticallyIdentical`, so a field missing from here is a slider
            // that writes nothing at all. Measured the hard way when 颗粒大小/粗糙度/种子 were added:
            // without these three lines `applyEdit { grainRoughness = 90 }` returned silently, the
            // document stayed at 50 and `commitEdit` found nothing to commit — `EffectsCardTests`
            // (`testOneRowsResetUsesItsOwnDefault`) was the test that caught it.
            //
            // The seed compares as `grainSeedValue`, the integer the kernel hashes: a document holding
            // 3.7 and one holding 4 are the same noise, so they must not mint an undo step either.
            && areEqual(a.grainSize, b.grainSize)
            && areEqual(a.grainRoughness, b.grainRoughness)
            && a.grainSeedValue == b.grainSeedValue
    }

    /// Do two mask stacks contribute the same render material?
    ///
    /// Empty and absent are the same thing: `EditModel` decodes a missing or null `masks` key to
    /// `[]`, so a document that never used a mask must not look dirty against one that explicitly
    /// has none. Array order is combination order, so it is part of the answer.
    static func renderMaterialEqual(_ a: [Mask], _ b: [Mask]) -> Bool {
        guard !a.isEmpty || !b.isEmpty else { return true }
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { areEqual($0, $1) }
    }

    /// A mask is *semantically* identified by its two key materials: exactly the resolution at which
    /// the renderer and the cache can tell two masks apart (quantised to 1e-5 — 0.6 px on a 60 MP
    /// frame, which is the resolution the key material is written at).
    /// `name` is absent on purpose — renaming a mask dirties nothing, and adjustments live in
    /// `applyKey` while geometry lives in `selectionKey`, so the two stages stay separable (§3.2).
    ///
    /// This is why the masks group is the one group whose tolerance is not `dirtyTolerance`: the
    /// canonical key formatter quantises at 1e-5, which is coarser than 1e-6 but still far below
    /// anything a mask handle can express or a pixel can show. A rename is *not* invisible to
    /// history, only to the renderer — see `isSemanticallyIdentical`.
    static func areEqual(_ a: Mask, _ b: Mask) -> Bool {
        a.selectionKey == b.selectionKey && a.applyKey == b.applyKey
    }
}
