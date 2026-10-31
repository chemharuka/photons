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
              + " sections=\(EditSnapshotSection.panelOrder.filter { snapshot.sections.contains($0) }.map(\.title))"
              + " masks=\(snapshot.maskCount)")
        // temperature, tint, exposure, contrast, curve.white, vibrance, crop ×4, vignetteAmount = 11.
        XCTAssertEqual(snapshot.fieldCount, 11)
        // 蒙版 is a section since P1-5: A has one mask, so the payload carries one — but a mask is a
        // nested document, not a leaf, and does not enter that count.
        XCTAssertEqual(snapshot.sections,
                       [.whiteBalance, .light, .curve, .color, .geometry, .correction, .masks])
        XCTAssertEqual(snapshot.maskCount, 1)
        XCTAssertEqual(snapshot.masks?.masks.map(\.id), ["A-mask"])

        let empty = EditSnapshot.capture(.neutral)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.sections.isEmpty)
        XCTAssertEqual(empty.maskCount, 0, "no masks in, no masks out")
        XCTAssertFalse(empty.requiresDecode)
    }

    /// 090: 中间调 is one leaf — a copy of a midtones-only edit carries `midtones` and nothing else,
    /// and pasting it moves only that leaf on the destination.
    func testCopyingOnlyMidtonesCarriesOneLeafAndPastesOnlyIt() {
        var a = EditModel.neutral
        a.light.midtones = 40

        let payload = EditSnapshot.capture(a)
        XCTAssertEqual(payload.fieldCount, 1, "只有中间调这一叶")
        XCTAssertEqual(payload.sections, [.light])
        XCTAssertEqual(payload.light?.midtones, 40)
        for leaf in [payload.light?.exposure, payload.light?.contrast, payload.light?.highlights,
                     payload.light?.shadows, payload.light?.whites, payload.light?.blacks,
                     payload.light?.highlightRecovery, payload.light?.temperature, payload.light?.tint,
                     payload.light?.blackOffset] {
            XCTAssertNil(leaf, "其余中间调以外的字段必须保持 nil")
        }
        XCTAssertNil(payload.curve)
        XCTAssertNil(payload.color)
        XCTAssertNil(payload.colorGrading)
        XCTAssertNil(payload.detail)
        XCTAssertNil(payload.effects)
        XCTAssertNil(payload.geometry)
        XCTAssertNil(payload.masks)

        var b = documentB()
        b.light.midtones = -12
        let merged = payload.applied(to: b)
        XCTAssertEqual(merged.light.midtones, 40, "粘贴写上中间调")
        XCTAssertEqual(changedKeys(b, merged), [], "除了中间调，别的字段一个也没动")
        XCTAssertEqual(merged.light.exposure, b.light.exposure, "曝光不动")
        XCTAssertEqual(merged.light.contrast, b.light.contrast, "对比不动")
        XCTAssertEqual(merged.light.temperature, b.light.temperature, "白平衡不动")
    }

    /// 090: an old envelope has no `midtones` key. It must decode as "not set" (nil) and a paste must
    /// therefore leave the destination's own middle tone untouched — not zero it.
    func testLegacyEnvelopeWithoutMidtonesDecodesNilAndPastesWithoutClearingTheTarget() throws {
        let legacy = #"{"schemaVersion":2,"light":{"exposure":1.2,"contrast":15}}"#
        let payload = try JSONDecoder().decode(EditSnapshot.self, from: Data(legacy.utf8))

        XCTAssertNil(payload.light?.midtones, "旧信封没有 midtones 键 = 未设置")
        XCTAssertEqual(payload.schemaVersion, 2, "不 bump 版本；旧信封原样解码")
        XCTAssertEqual(payload.light?.fieldCount, 2)

        var target = documentB()
        target.light.midtones = -12
        let merged = payload.applied(to: target)
        XCTAssertEqual(merged.light.midtones, -12, "旧载荷不许把目标文档的中间调清零")
        XCTAssertEqual(merged.light.exposure, 1.2, "旧载荷里的字段照常粘贴")
        XCTAssertEqual(merged.light.contrast, 15)
        XCTAssertEqual(changedKeys(target, merged), ["light.exposure", "light.contrast"])
    }

    func testAWhiteBalancePayloadIsARenderChange() {
        XCTAssertFalse(EditSnapshot.capture(documentA()).requiresDecode,
                       "since 143 the balance is an S1 gain, not a development")

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
        // Mask keys are id-keyed (`masks.<id>.added`), so they are folded out of the panel table and
        // asserted on their own below — otherwise this test would pin a random UUID.
        let maskKeys = keys.filter { $0.hasPrefix("masks.") }
        XCTAssertEqual(panels(keys.subtracting(maskKeys)),
                       ["light.temperature", "light.tint", "light.exposure", "light.contrast",
                        "curve.white", "color.vibrance",
                        "geometry.crop.x", "geometry.crop.y",
                        "geometry.crop.width", "geometry.crop.height",
                        "effects.vignetteAmount"],
                       "exactly the source's non-default leaves; got \(keys.sorted())")
        XCTAssertFalse(maskKeys.isEmpty, "蒙版 was checked in, so the mask list moved too")

        // The destination's own values in every group the source did **not** change.
        XCTAssertEqual(merged.color.saturation, 30, "B's saturation is B's: A never touched it")
        XCTAssertEqual(merged.detail.sharpening, 40, "B's sharpening is B's")
        XCTAssertEqual(merged.light.whites, 0)
        XCTAssertEqual(merged.light.blacks, 0)

        // Masks since P1-5: appended, never substituted. B's own mask survives; A's arrives as a
        // new mask (new id, same shape — the aspect ratios are both unknown here, so the normalised
        // coordinates are copied as-is by design).
        print("PASTE  masks: \(b.masks.map(\.id)) → \(merged.masks.map(\.id))")
        XCTAssertEqual(merged.masks.count, 2)
        XCTAssertEqual(merged.masks.first?.id, "B-mask", "the destination's own mask is not replaced")
        XCTAssertEqual(merged.masks.first?.feather, 0.6)
        XCTAssertEqual(Set(merged.masks.map(\.id)).count, 2)
        XCTAssertEqual(merged.masks[1].feather, 0.2, "the carried mask's own feather")
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
    }

    /// The mirror image: checking **only** 「蒙版」 writes the mask list and nothing else.
    func testPastingOnlyMasksLeavesEveryOtherLeafOfTheDestinationAlone() {
        let a = documentA()
        let b = documentB()
        let payload = EditSnapshot.capture(a).filtered(to: [.masks])
        XCTAssertFalse(payload.isEmpty, "a mask list is content, even with no scalar leaf in it")
        XCTAssertEqual(payload.fieldCount, 0)
        XCTAssertEqual(payload.sections, [.masks])

        let merged = payload.applied(to: b)
        let keys = changedKeys(b, merged)
        print("SECTION masks-only → B: \(keys.count) keys, all masks: \(keys.allSatisfy { $0.hasPrefix("masks.") })")
        XCTAssertTrue(keys.allSatisfy { $0.hasPrefix("masks.") },
                      "只粘蒙版 moved nothing outside the list; got \(keys.sorted())")
        XCTAssertEqual(merged.light, b.light)
        XCTAssertEqual(merged.color, b.color)
        XCTAssertEqual(merged.curve, b.curve)
        XCTAssertEqual(merged.geometry, b.geometry)
        XCTAssertEqual(merged.effects, b.effects)
        XCTAssertEqual(merged.masks.count, 2)
        XCTAssertEqual(merged.masks.first?.id, "B-mask")
    }

    // MARK: - the checklist model (全选 / 全不选 / 预设组合)

    func testTheChecklistHasTheThreeAnswersAndCountsMasksIn() {
        var selection = CopySettingsSelection.all
        XCTAssertEqual(selection.sections, Set(EditSnapshotSection.copyable))
        XCTAssertEqual(selection.matchingPreset, .all)
        // P1-5: 蒙版 is a row like any other — 全部 carries it, and the summary says so.
        XCTAssertTrue(selection.contains(.masks))
        // 081: the summary names the **cards**, in the panel's order (164 added 细节/开发).
        XCTAssertEqual(selection.summary,
                       "将复制：白平衡 · 黑电平 · Light · Color · 黑白 · HSL · 色彩分级 · 校准 · 曲线 · 开发 · 校正 · 细节 · 效果 · 裁切 · 蒙版")

        selection.selectNone()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.matchingPreset, .none)
        XCTAssertEqual(selection.summary, "未选任何组：粘贴什么也不会发生")

        // 081: 黑电平 joined 基本 (see `CopySettingsSelection.Preset.basic`).
        selection.select(.basic)
        XCTAssertEqual(selection.sections, [.whiteBalance, .blackLevel, .light, .curve])
        XCTAssertEqual(selection.matchingPreset, .basic)

        // 蒙版 can be switched on, by a checkbox or by hand, and off again.
        selection.set(.masks, true)
        XCTAssertTrue(selection.contains(.masks))
        XCTAssertNil(selection.matchingPreset, "白平衡 + 曝光 + 曲线 + 蒙版 is 自定义")
        selection.toggle(.masks)
        XCTAssertFalse(selection.contains(.masks))
        XCTAssertEqual(selection.matchingPreset, .basic)

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
        XCTAssertEqual(merged.color.saturation, 30)
        // The mask list is the one place the merge **adds** rather than replaces (P1-5): replacing it
        // — what `naive` does — would delete B's own mask, which the user never named.
        XCTAssertEqual(merged.masks.count, 2)
        XCTAssertEqual(merged.masks.first?.id, b.masks.first?.id)
        XCTAssertEqual(naive.masks.count, 1, "反证: a whole-document paste has one mask, not two")
    }

    // MARK: - 兼容 (081): a pre-081 payload still decodes and pastes the same document

    /// A payload written by the **previous** build: `light` holds balance + tone in one patch, `color`
    /// holds the HSL bands and the 黑白 switch, and neither `colorGrading` nor `light.blackOffset`
    /// exists. 081 kept every key name, so this decodes into the new struct untouched and the twelve
    /// cards fall out of the *fields*: 白平衡 + Light out of `light`, Color + 黑白 + HSL out of `color`.
    func testALegacySchema2PayloadExpandsToTheCardsAndPastesTheSameDocument() throws {
        let legacy = """
        {"schemaVersion":2,
         "light":{"temperature":5500,"tint":10,"exposure":1.2,"contrast":15},
         "color":{"vibrance":20,"saturation":25,"blackAndWhite":true,
                  "bands":[{"index":2,"hue":12,"saturation":-8,"luminance":4,"mix":30}]}}
        """
        let payload = try JSONDecoder().decode(EditSnapshot.self, from: Data(legacy.utf8))
        print("COMPAT v2 → sections \(EditSnapshotSection.panelOrder.filter { payload.sections.contains($0) }.map(\.title))"
              + " fields=\(payload.fieldCount) version=\(payload.schemaVersion)")
        XCTAssertEqual(payload.schemaVersion, 2, "旧信封的版本号原样保留，不被改写")
        XCTAssertEqual(payload.sections,
                       [.whiteBalance, .light, .color, .blackAndWhite, .hsl],
                       "light → 白平衡 + Light；color → Color + 黑白 + HSL（等价展开）")

        // The same values written by today's code paste the **same document**.
        var equivalent = EditModel.neutral
        equivalent.light.temperature = 5500
        equivalent.light.tint = 10
        equivalent.light.exposure = 1.2
        equivalent.light.contrast = 15
        equivalent.color.vibrance = 20
        equivalent.color.saturation = 25
        equivalent.color.blackAndWhite = true
        equivalent.color.bands[2] = HSLBand(hue: 12, saturation: -8, luminance: 4, mix: 30)

        let b = documentB()
        let viaLegacy = payload.applied(to: b)
        let viaToday = EditSnapshot.capture(equivalent).filtered(to: payload.sections).applied(to: b)
        XCTAssertEqual(viaLegacy, viaToday, "旧载荷与今天的等价载荷粘贴出逐字节相同的文档")
        XCTAssertEqual(viaLegacy.color.bands[2].mix, 30)
        XCTAssertEqual(viaLegacy.light.exposure, 1.2)
        XCTAssertEqual(viaLegacy.effects, b.effects, "旧载荷里没有的卡一个字段都没动")

        // 不写空段: re-encoding the old payload invents neither new key.
        let text = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        XCTAssertFalse(text.contains("colorGrading"), "旧载荷重新编码不写空段：\(text)")
        XCTAssertFalse(text.contains("blackOffset"), "旧载荷重新编码不写空段：\(text)")
    }

    /// The golden shape of 「今天的载荷减去 081 的两个新键」: strip them from a real capture, re-read it
    /// as v2, and the paste is field-for-field the one the unstripped capture produces.
    func testStrippingTheTwoNewKeysGivesAPayloadThatStillPastesIdentically() throws {
        // No masks: a pasted mask is re-identified with a fresh id on purpose (P1-5), so two pastes of
        // the same payload differ by exactly that UUID — an identity, not a develop value.
        var a = documentA()
        a.masks = []
        var b = documentB()
        b.masks = []
        let today = EditSnapshot.capture(a)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(today))
            as? [String: Any])
        object["schemaVersion"] = 2
        object.removeValue(forKey: "colorGrading")
        if var light = object["light"] as? [String: Any] {
            light.removeValue(forKey: "blackOffset")
            object["light"] = light
        }
        let stripped = try JSONDecoder().decode(EditSnapshot.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(stripped.fieldCount, today.fieldCount, "documentA 没有这两项，删掉不掉字段")
        XCTAssertEqual(stripped.applied(to: b), today.applied(to: b),
                       "golden: 旧载荷的粘贴结果与今天逐字节相同")
        XCTAssertEqual(stripped.sections, today.sections)
    }
}
