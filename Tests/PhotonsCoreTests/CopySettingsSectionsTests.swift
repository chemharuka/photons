import XCTest
@testable import PhotonsCore

/// 派单 078 P0-7 — 复制/粘贴设置：the payload rules, section by section.
///
/// The three properties this file exists to pin, each measured field-by-field rather than as a
/// whole-document comparison (a whole-document assert cannot say *which* leaf moved, and the ticket
/// is precisely about which leaves may move):
///
///   ① **sparse**: what ⌘C captures is the source's non-default leaves, nothing else;
///   ② **只带非默认字段 for the destination too**: pasting writes those leaves and no others, so a
///      photo that has its own white balance keeps it whenever the source did not pin one;
///   ③ **选组**: narrowing to a section drops its leaves *only* — 曝光 + 曲线 cannot touch 白平衡,
///      colour, crop or masks.
///
/// `testAWholeDocumentPasteWouldClobberTheDestination` is the 反证: it shows what the naive
/// implementation would do, so the assertions above are visibly about the sparse path and not about
/// two documents that happened to agree.
final class CopySettingsSectionsTests: XCTestCase {

    // MARK: - fixtures

    private func mask(_ id: String, feather: Double = 0.2) -> Mask {
        Mask(id: id, name: id, feather: feather)
    }

    /// The source photo: a Kelvin pin, two tone leaves, a curve, vibrance, a crop, a vignette, a mask.
    private func documentA() -> EditModel {
        var a = EditModel.neutral
        a.light.temperature = 5500
        a.light.tint = 10
        a.light.exposure = 1.2
        a.light.contrast = 15
        // 0…2 card coordinates, 1 = display white (069). Three points, so the leaf count differs
        // from `CurvePoint.linear`'s two — the payload carries the whole LUT either way.
        a.curve.white = [CurvePoint(0, 0), CurvePoint(1, 1.15), CurvePoint(2, 2)]
        a.color.vibrance = 20
        a.geometry.crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        a.effects.vignetteAmount = -20
        a.masks = [mask("A-mask")]
        return a
    }

    /// The destination photo: its **own** balance, its own exposure, its own saturation, a full crop,
    /// its own sharpening, a different mask. Nothing here is an accident — every field is one the
    /// paste must leave alone unless the source names it.
    private func documentB() -> EditModel {
        var b = EditModel.neutral
        b.light.temperature = 4800
        b.light.tint = 5
        b.light.exposure = -0.4
        b.color.saturation = 30
        b.geometry.crop = .full
        b.detail.sharpening = 40
        b.masks = [mask("B-mask", feather: 0.6)]
        return b
    }

    private func changedKeys(_ before: EditModel, _ after: EditModel) -> Set<String> {
        Set(EditHistory.changedFields(between: before, and: after).map(\.field.key))
    }

    /// Curve leaves are one LUT each but the **diff** (077's panel) is per point — or one `count` key
    /// when the point counts differ. Those keys are folded into one marker here so the assertions
    /// name the panels instead of the LUT indices.
    private func panels(_ keys: Set<String>) -> Set<String> {
        var out: Set<String> = []
        for key in keys { out.insert(key.hasPrefix("curve.") ? "curve.white" : key) }
        return out
    }

    // MARK: - ① sparse capture

    func testCaptureCarriesOnlyTheNonDefaultLeaves() {
        let snapshot = EditSnapshot.capture(documentA())
        print("COPY  A: \(snapshot.fieldCount) fields of \(EditSnapshot.fullDocumentFieldCount)"
              + " sections=\(EditSnapshotSection.panelOrder.filter { snapshot.sections.contains($0) }.map(\.title))")
        // temperature, tint, exposure, contrast, curve.white, vibrance, crop ×4, vignetteAmount = 11.
        XCTAssertEqual(snapshot.fieldCount, 11)
        XCTAssertEqual(snapshot.sections, [.whiteBalance, .light, .curve, .color, .geometry, .effects])
        XCTAssertFalse(snapshot.sections.contains(.masks), "蒙版 is never part of a payload")

        let empty = EditSnapshot.capture(.neutral)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.sections.isEmpty)
        XCTAssertFalse(empty.requiresDecode)
    }

    func testOnlyAWhiteBalancePayloadAsksForANewDecode() {
        XCTAssertTrue(EditSnapshot.capture(documentA()).requiresDecode, "the payload pins Kelvin")

        var toneOnly = EditModel.neutral
        toneOnly.light.exposure = 1
        toneOnly.color.saturation = 10
        toneOnly.geometry.crop = NormalizedRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        toneOnly.detail.sharpening = 20
        XCTAssertFalse(EditSnapshot.capture(toneOnly).requiresDecode,
                       "exposure / alignment / crop / stored detail are not decode inputs")
    }

    // MARK: - ② paste writes only what it carries

    func testPastingTheWholePayloadOntoBMovesExactlyTheSourcesLeaves() {
        let a = documentA()
        let b = documentB()
        let merged = EditSnapshot.capture(a).applied(to: b)

        let keys = changedKeys(b, merged)
        print("PASTE  A → B: \(keys.sorted())")
        XCTAssertEqual(panels(keys), ["light.temperature", "light.tint", "light.exposure", "light.contrast",
                                      "curve.white", "color.vibrance",
                                      "geometry.crop.x", "geometry.crop.y",
                                      "geometry.crop.width", "geometry.crop.height",
                                      "effects.vignetteAmount"],
                       "exactly the source's non-default leaves; got \(keys.sorted())")

        // The destination's own values in every group the source did **not** change.
        XCTAssertEqual(merged.color.saturation, 30, "B's saturation is B's: A never touched it")
        XCTAssertEqual(merged.detail.sharpening, 40, "B's sharpening is B's")
        XCTAssertEqual(merged.light.whites, 0)
        XCTAssertEqual(merged.light.blacks, 0)

        // Masks are structurally out of reach: not in the payload, not written.
        XCTAssertEqual(merged.masks.map(\.id), ["B-mask"])
        XCTAssertEqual(merged.masks.first?.feather, 0.6)
    }

    /// A source photo that left its balance at as-shot carries **no** Kelvin leaf, so pasting it
    /// cannot reset the destination's pinned balance. This is the 「粘贴把别人的白平衡冲掉」 case.
    func testAnAsShotSourceLeavesTheDestinationsWhiteBalanceAlone() {
        var a = EditModel.neutral
        a.light.exposure = 1.2                     // A changed tone, not balance
        XCTAssertNil(a.light.temperature)
        let b = documentB()
        let merged = EditSnapshot.capture(a).applied(to: b)

        XCTAssertEqual(merged.light.temperature, 4800, "B kept its own Kelvin")
        XCTAssertEqual(merged.light.tint, 5)
        XCTAssertEqual(changedKeys(b, merged), ["light.exposure"])
        XCTAssertFalse(EditSnapshot.capture(a).requiresDecode)
    }

    // MARK: - ③ 选组

    func testPastingOnlyExposureAndCurveLeavesWhiteBalanceColourCropAndMasksUntouched() {
        let a = documentA()
        let b = documentB()
        let payload = EditSnapshot.capture(a).filtered(to: [.light, .curve])

        print("SECTION  payload sections: "
              + "\(EditSnapshotSection.panelOrder.filter { payload.sections.contains($0) }.map(\.title))"
              + " fields=\(payload.fieldCount)")
        XCTAssertEqual(payload.sections, [.light, .curve])
        XCTAssertNil(payload.light?.temperature, "白平衡 was not checked: the leaf is not in the payload")
        XCTAssertNil(payload.light?.tint)

        let merged = payload.applied(to: b)
        let keys = changedKeys(b, merged)
        print("SECTION  A(.light,.curve) → B: \(keys.sorted())")
        XCTAssertEqual(panels(keys), ["light.exposure", "light.contrast", "curve.white"])

        // Field by field: 白平衡 / 颜色 / 裁切 / 蒙版 are all still B's.
        XCTAssertEqual(merged.light.temperature, 4800)
        XCTAssertEqual(merged.light.tint, 5)
        XCTAssertEqual(merged.color.vibrance, 0)
        XCTAssertEqual(merged.color.saturation, 30)
        XCTAssertEqual(merged.geometry.crop, NormalizedRect.full)
        XCTAssertEqual(merged.effects.vignetteAmount, 0)
        XCTAssertEqual(merged.masks.map(\.id), ["B-mask"])
        XCTAssertFalse(payload.requiresDecode, "no white balance in the payload = no development")

        // And the other narrowing keeps what this one dropped.
        let wbOnly = EditSnapshot.capture(a).filtered(to: [.whiteBalance]).applied(to: b)
        XCTAssertEqual(changedKeys(b, wbOnly), ["light.temperature", "light.tint"])
    }

    func testEmptyNarrowingPastesNothing() {
        let b = documentB()
        let payload = EditSnapshot.capture(documentA()).filtered(to: [])
        XCTAssertTrue(payload.isEmpty)
        XCTAssertTrue(changedKeys(b, payload.applied(to: b)).isEmpty)
        // 蒙版 can be asked for explicitly and is still dropped: it is not a payload section.
        XCTAssertTrue(EditSnapshot.capture(documentA()).filtered(to: [.masks]).isEmpty)
    }

    // MARK: - the checklist model (全选 / 全不选 / 预设组合)

    func testTheChecklistHasTheThreeAnswersAndNeverCountsMasksIn() {
        var selection = CopySettingsSelection.all
        XCTAssertEqual(selection.sections, Set(EditSnapshotSection.copyable))
        XCTAssertEqual(selection.matchingPreset, .all)
        XCTAssertFalse(selection.contains(.masks))
        XCTAssertEqual(selection.summary, "将复制：白平衡 · 曝光 · 曲线 · 颜色 · 细节 · 效果 · 裁切")

        selection.selectNone()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.matchingPreset, .none)
        XCTAssertEqual(selection.summary, "未选任何组：粘贴什么也不会发生")

        selection.select(.basic)
        XCTAssertEqual(selection.sections, [.whiteBalance, .light, .curve])
        XCTAssertEqual(selection.matchingPreset, .basic)

        // 蒙版 cannot be switched on, by the popup or by a checkbox.
        selection.set(.masks, true)
        XCTAssertFalse(selection.contains(.masks))
        selection.toggle(.masks)
        XCTAssertFalse(selection.contains(.masks))

        // A hand-made set is 自定义, and the popup must say so rather than the nearest preset.
        selection = CopySettingsSelection(sections: [.light, .effects])
        XCTAssertNil(selection.matchingPreset)

        // Every preset is reachable and distinct: two presets naming one set would be ambiguous.
        let sets = CopySettingsSelection.Preset.allCases.map { $0.sections.map(\.rawValue).sorted().joined(separator: ",") }
        XCTAssertEqual(sets.count, Set(sets).count)
    }

    func testSelectionNarrowingIsTheSameAsSectionNarrowing() {
        let viaSelection = EditSnapshot.capture(documentA()).filtered(to: CopySettingsSelection(.geometry))
        XCTAssertEqual(viaSelection.sections, [.geometry])
        XCTAssertEqual(viaSelection.geometry?.cropWidth, 0.8)
        XCTAssertNil(viaSelection.light)
    }

    // MARK: - 反证 (what the naive implementation would have done)

    /// Replacing the document wholesale — the "paste everything" implementation this ticket rejects —
    /// overwrites B's balance with A's and re-installs every value A never set. Kept as a test so the
    /// difference is a measurement: the assertions above are about the *sparse* merge, and this one
    /// shows the number they would have been without it.
    func testAWholeDocumentPasteWouldClobberTheDestination() {
        let a = documentA()
        let b = documentB()
        let naive = a                              // "paste = copy the document"
        XCTAssertEqual(naive.light.temperature, 5500)
        XCTAssertNotEqual(naive.light.temperature, b.light.temperature,
                          "反证: a whole-document paste moves B's white balance — sparseness is what prevents it")
        XCTAssertNotEqual(naive.masks.map(\.id), b.masks.map(\.id),
                          "反证: a whole-document paste would also replace the destination's masks")
        XCTAssertEqual(naive.color.saturation, 0,
                       "反证: and it would zero B's saturation, which A never touched")

        let merged = EditSnapshot.capture(a).applied(to: b)
        // A pinned its balance, so the sparse paste carries it — that IS a setting (派单 006: assigning
        // 5500 K on a 4803 K shot is a decision). What sparseness prevents is the *rest*: 30 → 0 on
        // saturation, the mask list replaced, the effects invented. The as-shot variant of this case
        // is `testAnAsShotSourceLeavesTheDestinationsWhiteBalanceAlone`.
        XCTAssertEqual(merged.light.temperature, 5500)
        XCTAssertEqual(merged.masks.map(\.id), b.masks.map(\.id))
        XCTAssertEqual(merged.color.saturation, 30)
    }
}
