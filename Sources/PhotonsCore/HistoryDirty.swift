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
        // 2026-10-28 (078 B8): **色差**. 029 put the two ratios in `optics` and the cache key
        // (`;car=`, `;cab=`) and the history's field table, but never here — and this is the list
        // `applyEdit` short-circuits on (`isSemanticallyIdentical`). Without this line a CA write was
        // *silently dropped*: the document stayed at 0, `commitEdit` found nothing to commit, and the
        // panel's two sliders moved a knob that changed no pixel and left no history row. Nothing
        // noticed for a month because the sliders had no UI (`ChromaticAberrationCardTests` is the
        // test that would have caught it — it fails at `optics.caRed == 0.00025` on exactly this).
        //
        // `.geometry`, not a group of its own: CA *is* S0 (`RenderStage.geometry`), the stage the crop
        // and the turn live on, and `RenderGroup.stages` is what turns this bool into "re-render from
        // S0 down" — the same treatment `;car=` gets in `keyMaterial(.geometry)`.
        if !EditParameters.areEqual(before.optics, after.optics) { dirty.insert(.geometry) }
        if !EditParameters.renderMaterialEqual(before.masks, after.masks) { dirty.insert(.masks) }
        // 2026-10-28 (078 P0-1): 修复画笔. One group, one stage (S1.9): a spot's centre, radius,
        // source offset, mode, feather or opacity all move it, and adding/removing a spot moves it
        // too — the list *is* the material. `HealSpot.keyString` is the resolution (the same 1e-5 the
        // canonical formatter writes), so a JSON round trip is not an edit and a slider step is.
        if !EditParameters.areEqual(before.healSpots, after.healSpots) { dirty.insert(.heal) }
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

/// One group's compared fields, **named**.
///
/// The name is the struct's own stored-property label, and `FieldCoverageTests` reflects over the
/// group to assert that this list and the struct agree in both directions. That is the point: the
/// bug this replaces was a hand-written `&&` chain that silently omitted 纹理 / 清晰度 / 去雾 for a
/// month, so every `applyEdit` on those sliders returned on `isSemanticallyIdentical` and the drag
/// snapped back to 0. A field cannot be forgotten now without a red test.
struct FieldTable<G> {
    private(set) var names: [String] = []
    private var checks: [(G, G) -> Bool] = []

    init() {}

    mutating func field(_ name: String, _ check: @escaping (G, G) -> Bool) {
        names.append(name)
        checks.append(check)
    }

    func allEqual(_ a: G, _ b: G) -> Bool {
        for check in checks where !check(a, b) { return false }
        return true
    }
}

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

    /// 101 — one HSL triplet. Load-bearing for the same reason the fields above are: `applyEdit`
    /// short-circuits on `isSemanticallyIdentical`, so a global slider missing here would write
    /// nothing at all (and the ninth selector would be invisible to the document).
    static func areEqual(_ a: HSLBand, _ b: HSLBand) -> Bool {
        areEqual(a.hue, b.hue) && areEqual(a.saturation, b.saturation)
            && areEqual(a.luminance, b.luminance) && areEqual(a.mix, b.mix)
    }

    static func areEqual(_ a: GeometryGroup, _ b: GeometryGroup) -> Bool {
        geometryFields.allEqual(a, b)
    }

    static let geometryFields: FieldTable<GeometryGroup> = {
        var t = FieldTable<GeometryGroup>()
        t.field("crop") { areEqual($0.crop, $1.crop) }
        t.field("rotationDegrees") { areEqual($0.rotationDegrees, $1.rotationDegrees) }
        t.field("flipHorizontal") { areEqual($0.flipHorizontal, $1.flipHorizontal) }
        t.field("flipVertical") { areEqual($0.flipVertical, $1.flipVertical) }
        // The ratio lock is document state the crop tool writes on its own (toggling 🔒 ↔ free moves
        // no pixels), and `applyEdit` drops anything it cannot see — so it is compared even though it
        // is not render material: without this the lock would refuse to toggle.
        t.field("aspectLock") { $0.aspectLock == $1.aspectLock }
        t.field("quarterTurns") { $0.quarterTurns == $1.quarterTurns }
        return t
    }()

    static func areEqual(_ a: LightGroup, _ b: LightGroup) -> Bool {
        lightFields.allEqual(a, b)
    }

    static let lightFields: FieldTable<LightGroup> = {
        var t = FieldTable<LightGroup>()
        t.field("exposure") { areEqual($0.exposure, $1.exposure) }
        t.field("contrast") { areEqual($0.contrast, $1.contrast) }
        t.field("highlights") { areEqual($0.highlights, $1.highlights) }
        t.field("midtones") { areEqual($0.midtones, $1.midtones) }
        t.field("shadows") { areEqual($0.shadows, $1.shadows) }
        t.field("whites") { areEqual($0.whites, $1.whites) }
        t.field("blacks") { areEqual($0.blacks, $1.blacks) }
        t.field("temperature") { areEqual($0.temperature, $1.temperature) }
        t.field("tint") { areEqual($0.tint, $1.tint) }
        t.field("highlightRecovery") { areEqual($0.highlightRecovery, $1.highlightRecovery) }
        // 071: blackOffset missing here meant the 黑电平 slider moved, `applyEdit` returned silently
        // and the document stayed at 0. A step is 0.001 — a thousand tolerances.
        t.field("blackOffset") { areEqual($0.blackOffset, $1.blackOffset) }
        return t
    }()

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
        curveFields.allEqual(a, b)
    }

    static let curveFields: FieldTable<CurveGroup> = {
        var t = FieldTable<CurveGroup>()
        // `white` is the stored master curve; `rgb` is a computed view of it (`tables` =
        // [white, red, green, blue]), so the stored field is what the comparison must name.
        t.field("white") { areEqual($0.white, $1.white) }
        t.field("red") { areEqual($0.red, $1.red) }
        t.field("green") { areEqual($0.green, $1.green) }
        t.field("blue") { areEqual($0.blue, $1.blue) }
        return t
    }()

    static func areEqual(_ a: ColorGroup, _ b: ColorGroup) -> Bool {
        colorFields.allEqual(a, b)
    }

    static let colorFields: FieldTable<ColorGroup> = {
        var t = FieldTable<ColorGroup>()
        t.field("blackAndWhite") { $0.blackAndWhite == $1.blackAndWhite }
        t.field("vibrance") { areEqual($0.vibrance, $1.vibrance) }
        t.field("saturation") { areEqual($0.saturation, $1.saturation) }
        t.field("bands") { areEqual($0.bands, $1.bands) }
        t.field("global") { areEqual($0.global, $1.global) }
        // 140: S3.6b's optional object. Compared at the same tolerance as every other colour field,
        // so a sample/drag is a real document change (and a JSON round trip is not).
        t.field("point") { p0, p1 in
            switch (p0.point, p1.point) {
            case (nil, nil): return true
            case let (a?, b?):
                return areEqual(a.sampleHue, b.sampleHue) && areEqual(a.sampleChroma, b.sampleChroma)
                    && areEqual(a.range, b.range) && areEqual(a.feather, b.feather)
                    && areEqual(a.hue, b.hue) && areEqual(a.saturation, b.saturation)
                    && areEqual(a.luminance, b.luminance)
            default: return false
            }
        }
        return t
    }()

    /// 2026-10-28 (P0 色彩分级): the nine numbers. **Load-bearing** for the same reason
    /// `blackOffset` and the three grain fields are: `CatalogSession.applyEdit` short-circuits on
    /// `isSemanticallyIdentical`, so a group missing from here is a slider that writes nothing at all
    /// (and `commitEdit` then finds nothing to commit, so the drag leaves no history row either).
    static func areEqual(_ a: ColorGradingGroup, _ b: ColorGradingGroup) -> Bool {
        colorGradingFields.allEqual(a, b)
    }

    static let colorGradingFields: FieldTable<ColorGradingGroup> = {
        var t = FieldTable<ColorGradingGroup>()
        let wheel: (GradeWheel, GradeWheel) -> Bool = { x, y in
            areEqual(x.hue, y.hue) && areEqual(x.saturation, y.saturation)
                && areEqual(x.lightness, y.lightness)
        }
        // Three stored wheels; `wheels` is their computed array.
        t.field("shadows") { wheel($0.shadows, $1.shadows) }
        t.field("midtones") { wheel($0.midtones, $1.midtones) }
        t.field("highlights") { wheel($0.highlights, $1.highlights) }
        return t
    }()

    static func areEqual(_ a: DetailGroup, _ b: DetailGroup) -> Bool {
        detailFields.allEqual(a, b)
    }

    static let detailFields: FieldTable<DetailGroup> = {
        var t = FieldTable<DetailGroup>()
        t.field("sharpening") { areEqual($0.sharpening, $1.sharpening) }
        t.field("sharpeningRadius") { areEqual($0.sharpeningRadius, $1.sharpeningRadius) }
        t.field("noiseLuminance") { areEqual($0.noiseLuminance, $1.noiseLuminance) }
        t.field("noiseColor") { areEqual($0.noiseColor, $1.noiseColor) }
        t.field("lensCorrections") { areEqual($0.lensCorrections, $1.lensCorrections) }
        return t
    }()

    /// 派单 031: the decoder-side amounts. One unit of slider travel is 0.01 of a filter value (040's
    /// 0…100 scale), so the 1e-6 tolerance is far below a step and far above JSON round-trip noise.
    static func areEqual(_ a: DetailSettings, _ b: DetailSettings) -> Bool {
        detailSettingsFields.allEqual(a, b)
    }

    static let detailSettingsFields: FieldTable<DetailSettings> = {
        var t = FieldTable<DetailSettings>()
        t.field("luminanceNR") { areEqual($0.luminanceNR, $1.luminanceNR) }
        t.field("colorNR") { areEqual($0.colorNR, $1.colorNR) }
        t.field("sharpness") { areEqual($0.sharpness, $1.sharpness) }
        t.field("detail") { areEqual($0.detail, $1.detail) }
        return t
    }()

    static func areEqual(_ a: EffectsGroup, _ b: EffectsGroup) -> Bool {
        effectsFields.allEqual(a, b)
    }

    static let effectsFields: FieldTable<EffectsGroup> = {
        var t = FieldTable<EffectsGroup>()
        t.field("vignetteAmount") { areEqual($0.vignetteAmount, $1.vignetteAmount) }
        t.field("vignetteMidpoint") { areEqual($0.vignetteMidpoint, $1.vignetteMidpoint) }
        t.field("vignetteFeather") { areEqual($0.vignetteFeather, $1.vignetteFeather) }
        t.field("grain") { areEqual($0.grain, $1.grain) }
        t.field("grainSize") { areEqual($0.grainSize, $1.grainSize) }
        t.field("grainRoughness") { areEqual($0.grainRoughness, $1.grainRoughness) }
        // The seed compares as the integer the kernel hashes: 3.7 and 4 are the same noise.
        t.field("grainSeed") { $0.grainSeedValue == $1.grainSeedValue }
        // 2026-10-29 — 纹理 / 清晰度 / 去雾 were the missing three; the drag snapped back to 0 because
        // `applyEdit` short-circuited. `EffectsCardTests.testDetailFXRowsWriteTheDocument` holds them.
        t.field("texture") { areEqual($0.texture, $1.texture) }
        t.field("clarity") { areEqual($0.clarity, $1.clarity) }
        // 164 — the two non-Bayer denoises. Load-bearing exactly like the three above: without them
        // `applyEdit` short-circuits and the new sliders write nothing.
        t.field("nonBayerLuminanceNR") {
            areEqual($0.nonBayerLuminanceNR, $1.nonBayerLuminanceNR)
        }
        t.field("nonBayerColorNR") { areEqual($0.nonBayerColorNR, $1.nonBayerColorNR) }
        t.field("dehaze") { areEqual($0.dehaze, $1.dehaze) }
        // 120b — the depth-assisted dehaze strength. Without this line `applyEdit` sees the group as
        // unchanged and a drag of the new row writes nothing (the EffectsCardTests' 2026-10-29 bug).
        t.field("dehazeDepth") { areEqual($0.dehazeDepth, $1.dehazeDepth) }
        return t
    }()

    /// 2026-10-28 (078 B8): the two CA ratios. Same load-bearing rule as the grain lines above —
    /// `dirtyGroups` reads this, `applyEdit` reads `dirtyGroups`, so a value this leaves out is a
    /// slider that writes nothing.
    ///
    /// Compared at `dirtyTolerance` (1e-6), which is 1/50 of one slider unit (5 × 10⁻⁵ of α): every
    /// position the panel can express is dirty against its neighbour, and a JSON round-trip is not.
    static func areEqual(_ a: OpticsGroup, _ b: OpticsGroup) -> Bool {
        opticsFields.allEqual(a, b)
    }

    static let opticsFields: FieldTable<OpticsGroup> = {
        var t = FieldTable<OpticsGroup>()
        t.field("caRed") { areEqual($0.caRed, $1.caRed) }
        t.field("caBlue") { areEqual($0.caBlue, $1.caBlue) }
        return t
    }()

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

    /// Do two spot lists contribute the same render material?
    ///
    /// Empty and absent are the same thing (an absent `healSpots` key decodes to `[]`), array order is
    /// composition order so it is part of the answer, and a spot is compared at its `keyString` — the
    /// quantised text S1.9 is keyed by, so "the document moved" and "the key moved" cannot disagree.
    /// The `id` is deliberately absent from that text: a spot has no atlas slice, so its id is a
    /// document handle and not arithmetic (the same distinction `Mask.selectionKey` makes the other
    /// way round, because a mask's id *does* name a slice).
    static func areEqual(_ a: [HealSpot], _ b: [HealSpot]) -> Bool {
        guard !a.isEmpty || !b.isEmpty else { return true }
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { $0.keyString == $1.keyString }
    }
}
