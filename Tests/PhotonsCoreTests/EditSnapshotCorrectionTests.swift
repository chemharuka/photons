import XCTest
@testable import PhotonsCore

/// 156 §3 — **校正** is a copy/paste section now (色差 R / 色差 B).
///
/// It was a card of the inspector since 096/116 but had no `EditSnapshotSection`, so checking it was
/// impossible and a paste could never move the two CA ratios. These tests pin the three properties
/// that make the new section safe:
///
///   ① 只勾校正 → the payload carries exactly the two `optics` leaves.
///   ② pasting it onto a CA-neutral document moves those two fields and **nothing else** (key-string
///      comparison, so a whole-group write would show up as extra keys).
///   ③ an old payload with no `optics` key decodes to `nil` and leaves the destination's CA at 0 —
///      no schema-version change is needed for an additive, defaulted key.
final class EditSnapshotCorrectionTests: XCTestCase {

    private func changeKeys(_ before: EditModel, _ after: EditModel) -> Set<String> {
        Set(EditHistory.changedFields(between: before, and: after).map { $0.field.key })
    }

    // MARK: ① the section itself

    func testCorrectionSitsBetweenDetailAndEffectsAndHasThePanelsTwoRows() throws {
        let order = EditSnapshotSection.panelOrder
        let detail = try XCTUnwrap(order.firstIndex(of: .detail))
        let correction = try XCTUnwrap(order.firstIndex(of: .correction))
        let effects = try XCTUnwrap(order.firstIndex(of: .effects))
        XCTAssertEqual(correction, detail + 1, "校正紧跟在细节之后：\(order)")
        XCTAssertEqual(effects, correction + 1, "效果紧跟在校正之后：\(order)")

        XCTAssertEqual(EditSnapshotSection.correction.title, "校正")
        XCTAssertEqual(EditSnapshotSection.correction.children.map(\.title), ["色差 R", "色差 B"])
        XCTAssertEqual(EditSnapshotSection.correction.children, [.caRed, .caBlue])
        XCTAssertTrue(EditSnapshotSection.correction.isCopyable)

        // The key is additive and defaulted; bumping this number would change what an old payload
        // means, which the ticket explicitly forbids (156 §3).
        XCTAssertEqual(EditSnapshot.currentSchemaVersion, 3,
                       "校正 key 是加法，不改 schemaVersion 的语义")
    }

    // MARK: ② only 校正 moves the two ratios

    func testCopyingOnlyCorrectionPastesBothRatiosAndNothingElse() {
        var source = EditModel.neutral
        source.optics.caRed = 0.0012
        source.optics.caBlue = -0.0008
        // Other cards are non-default too, so a whole-group write would be visible in the key set.
        source.light.exposure = 1.3
        source.light.temperature = 5200
        source.detail.sharpening = 40
        source.effects.grain = 12
        source.color.saturation = 25

        let selection = CopySettingsSelection(sections: [.correction],
                                              children: [.caRed, .caBlue])
        let payload = EditSnapshot.capture(source).filtered(to: selection)
        print("156 校正 payload: \(payload.fieldCount) fields sections=\(payload.sections.map(\.rawValue))")
        XCTAssertEqual(payload.sections, [.correction])
        XCTAssertEqual(payload.fieldCount, 2)
        XCTAssertEqual(payload.optics?.caRed, 0.0012)
        XCTAssertEqual(payload.optics?.caBlue, -0.0008)
        XCTAssertNil(payload.light, "校正 copy carries no tone leaf")
        XCTAssertNil(payload.detail)
        XCTAssertNil(payload.effects)
        XCTAssertNil(payload.color)

        var target = EditModel.neutral
        target.light.exposure = -0.4
        target.light.temperature = 4800
        target.detail.sharpening = 5
        target.effects.grain = 3
        target.color.saturation = 30
        XCTAssertEqual(target.optics, .identity, "目标照片的 CA 是 0")

        let merged = payload.applied(to: target)
        XCTAssertEqual(merged.optics.caRed, 0.0012, accuracy: 1e-12)
        XCTAssertEqual(merged.optics.caBlue, -0.0008, accuracy: 1e-12)
        XCTAssertEqual(changeKeys(target, merged), ["optics.caRed", "optics.caBlue"],
                       "只有色差两项变；实际 \(changeKeys(target, merged).sorted())")
        XCTAssertEqual(merged.light, target.light, "曝光/白平衡一项不动")
        XCTAssertEqual(merged.detail, target.detail)
        XCTAssertEqual(merged.effects, target.effects)
        XCTAssertEqual(merged.color, target.color)
        XCTAssertEqual(merged.geometry, target.geometry)
        XCTAssertEqual(merged.curve, target.curve)
    }

    func testOneChildNarrowsToOneRatio() {
        var source = EditModel.neutral
        source.optics.caRed = 0.002
        source.optics.caBlue = 0.001
        let selection = CopySettingsSelection(sections: [.correction], children: [.caRed])
        let payload = EditSnapshot.capture(source).filtered(to: selection)
        XCTAssertEqual(payload.fieldCount, 1)
        XCTAssertEqual(payload.optics?.caRed, 0.002)
        XCTAssertNil(payload.optics?.caBlue, "只勾色差 R，B 不许跟着走")
        XCTAssertEqual(payload.sections, [.correction])
    }

    // MARK: ③ an old payload has no optics key

    func testAnOlderPayloadDecodesWithoutCorrectionAndLeavesTheTargetAlone() throws {
        let legacy = #"{"schemaVersion":3,"light":{"exposure":0.5}}"#
        let payload = try JSONDecoder().decode(EditSnapshot.self, from: Data(legacy.utf8))
        XCTAssertNil(payload.optics, "老文档没有这个 section → nil，按目标自己的 0 处理")
        XCTAssertFalse(payload.sections.contains(.correction))

        var target = EditModel.neutral
        target.optics.caRed = 0.0004
        target.optics.caBlue = -0.0002
        let merged = payload.applied(to: target)
        XCTAssertEqual(merged.optics, target.optics, "老 payload 的 CA 一个字段都不动")
        XCTAssertEqual(merged.light.exposure, 0.5, "它带的曝光照常写入")
    }
}
